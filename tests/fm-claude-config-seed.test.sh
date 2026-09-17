#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-config-seed.sh: the per-home Claude config
# store seeder and its fail-closed launch-path auth test (config-isolation audit,
# Option 1). These drive the script through its CLI and assert on the store it
# builds and its exit codes; nothing inspects the script's own source bytes.
#
# The seeder's contract:
#   - build a store settings.json from committed home-seed/ doctrine plus the
#     per-machine credential env injected from a source settings.json,
#   - keep the credential/endpoint env verbatim (auth cannot break) while the
#     fleet-pinned default model (env.ANTHROPIC_MODEL) wins over the source model
#     and the operator's personal hooks/skills/plugins are dropped (leak closed),
#   - let doctrine env keys win over source env keys,
#   - preserve an already-seeded store (never clobber),
#   - fail closed (exit 3) when no credential is resolvable, unless --soft.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEED="$ROOT/bin/fm-claude-config-seed.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-config-seed)

# write_source <path> <env-json> [extra-top-json]: a fake per-machine source
# settings.json with an env block and optional extra personal keys.
write_source() {
  local path=$1 env_json=$2 extra=${3:-'{}'}
  mkdir -p "$(dirname "$path")"
  jq -n --argjson env "$env_json" --argjson extra "$extra" \
    '$extra + {env: $env}' > "$path"
}

# run_seed [args...]: run the seeder with a controlled, credential-free ambient
# env (so a test's own box key never masks a fail-closed case). FM_ROOT points at
# the repo so the committed doctrine resolves. The credential source is CRED_FILE
# (default a nonexistent path -> no source credential).
run_seed() {
  env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
    FM_ROOT="$ROOT" FM_CLAUDE_CREDENTIAL_FILE="${CRED_FILE:-$TMP_ROOT/no-such-cred.json}" \
    "$SEED" "$@" 2>&1
}

# --- build injects the credential env and drops personal keys ----------------
test_build_injects_credential_and_drops_personal() {
  local src store out settings
  src="$TMP_ROOT/inj/src/settings.json"
  store="$TMP_ROOT/inj/store"
  write_source "$src" \
    '{"ANTHROPIC_AUTH_TOKEN":"TOK","ANTHROPIC_BASE_URL":"https://proxy","ANTHROPIC_MODEL":"m1"}' \
    '{"hooks":{"UserPromptSubmit":[1]},"enabledPlugins":{"p":true},"statusLine":{"x":1}}'
  CRED_FILE="$src" out=$(run_seed "$store"); rc=$?
  expect_code 0 "$rc" "seed with a credential should exit 0"$'\n'"$out"
  settings=$(cat "$store/settings.json")
  assert_contains "$settings" "TOK" "the source token must be injected into the store"
  assert_contains "$settings" "https://proxy" "the source endpoint must be injected"
  jq -e '.env.ANTHROPIC_MODEL == "github-copilot/gpt-5"' "$store/settings.json" >/dev/null \
    || fail "the fleet-pinned default model (github-copilot/gpt-5) must win over the source ANTHROPIC_MODEL"
  assert_not_contains "$settings" "UserPromptSubmit" "personal hooks must NOT be copied into the store"
  assert_not_contains "$settings" "enabledPlugins" "personal plugins must NOT be copied into the store"
  assert_not_contains "$settings" "statusLine" "personal statusLine must NOT be copied into the store"
  # doctrine behaviour is present
  jq -e '.autoMemoryEnabled == false' "$store/settings.json" >/dev/null \
    || fail "seeded store must carry autoMemoryEnabled:false from doctrine"
  jq -e '.permissions.defaultMode == "bypassPermissions"' "$store/settings.json" >/dev/null \
    || fail "seeded store must carry the doctrine permission mode"
  assert_present "$store/.claude.json" "an onboarding marker must be written to avoid first-run prompts"
  jq -e '.hasCompletedOnboarding == true' "$store/.claude.json" >/dev/null \
    || fail "onboarding marker must mark onboarding complete"
  pass "build injects credential/endpoint, pins the doctrine model, and drops personal hooks/plugins/statusLine"
}

# --- doctrine env wins over source env for an overlapping key ----------------
test_doctrine_env_wins() {
  local src store
  src="$TMP_ROOT/win/src/settings.json"
  store="$TMP_ROOT/win/store"
  # A source key the doctrine does not own survives the merge; a key the doctrine
  # DOES own (ANTHROPIC_MODEL, the fleet-pinned default model) is won by the
  # doctrine. The committed-cap case is also covered by test_compaction_cap_seeded
  # and the model case by test_default_model_seeded.
  write_source "$src" '{"ANTHROPIC_AUTH_TOKEN":"TOK","FM_SOURCE_ONLY_KEY":"src-only","ANTHROPIC_MODEL":"src-model"}'
  CRED_FILE="$src" run_seed "$store" >/dev/null
  jq -e '.env.FM_SOURCE_ONLY_KEY == "src-only"' "$store/settings.json" >/dev/null \
    || fail "source env keys the doctrine does not set must survive"
  jq -e '.env.ANTHROPIC_MODEL == "github-copilot/gpt-5"' "$store/settings.json" >/dev/null \
    || fail "doctrine env (the fleet-pinned ANTHROPIC_MODEL) must win over a source ANTHROPIC_MODEL"
  # Prove the precedence rule directly against the seeder's own merge expression
  # (.env = source_env + doctrine_env -> doctrine wins the overlap).
  merged=$(jq -n --argjson src '{"ANTHROPIC_MODEL":"src"}' \
    '{"env":{"ANTHROPIC_MODEL":"doc"}} | .env = ($src + (.env // {})) | .env.ANTHROPIC_MODEL')
  [ "$merged" = '"doc"' ] || fail "doctrine env must win over source env on an overlapping key (got $merged)"
  pass "source env survives and doctrine env wins overlapping keys"
}

# --- the sub-128k auto-compaction cap is seeded and wins over a source override
# The wedge-prevention fix (docs/compaction-hygiene.md): the doctrine pins
# CLAUDE_CODE_AUTO_COMPACT_WINDOW below the copilot-api ~128k effective ceiling
# so native compaction fires before an agent runs out of context. This proves
# the seeder carries that cap into every store (additively when the source is
# silent, and winning when the source pins a larger, unsafe window).
test_compaction_cap_seeded() {
  local src store cap
  # a) source silent -> the store gains the doctrine cap additively.
  src="$TMP_ROOT/cap-add/src/settings.json"
  store="$TMP_ROOT/cap-add/store"
  write_source "$src" '{"ANTHROPIC_AUTH_TOKEN":"TOK"}'
  CRED_FILE="$src" run_seed "$store" >/dev/null
  cap=$(jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW // ""' "$store/settings.json")
  [ -n "$cap" ] || fail "the seeded store must carry the doctrine auto-compaction cap"
  [ "$cap" -lt 128000 ] 2>/dev/null \
    || fail "seeded auto-compaction window must be below the 128k backend ceiling (got '$cap')"
  # b) source pins a LARGER (unsafe) window -> the sub-128k doctrine cap wins.
  src="$TMP_ROOT/cap-win/src/settings.json"
  store="$TMP_ROOT/cap-win/store"
  write_source "$src" '{"ANTHROPIC_AUTH_TOKEN":"TOK","CLAUDE_CODE_AUTO_COMPACT_WINDOW":"500000"}'
  CRED_FILE="$src" run_seed "$store" >/dev/null
  cap=$(jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW // ""' "$store/settings.json")
  [ "$cap" -lt 128000 ] 2>/dev/null \
    || fail "the doctrine sub-128k cap must win over a larger source window (got '$cap')"
  pass "the sub-128k auto-compaction cap is seeded and wins over a larger source window"
}

# --- the fleet default model is seeded and wins over a source model override ---
# The default-model change: the doctrine pins env.ANTHROPIC_MODEL=github-copilot/gpt-5 so
# every seeded store (the primary and every fm-spawn'd claude agent) defaults to
# it when no explicit --model overrides. ANTHROPIC_MODEL wins over the top-level
# `model` setting, so this env key is the effective default lever. This proves
# the seeder carries the committed default into every store additively (source
# silent) and winning over a per-machine source model (e.g. the old opus-4.8).
test_default_model_seeded() {
  local src store model
  # a) source silent -> the store gains the doctrine default model additively.
  src="$TMP_ROOT/model-add/src/settings.json"
  store="$TMP_ROOT/model-add/store"
  write_source "$src" '{"ANTHROPIC_AUTH_TOKEN":"TOK"}'
  CRED_FILE="$src" run_seed "$store" >/dev/null
  model=$(jq -r '.env.ANTHROPIC_MODEL // ""' "$store/settings.json")
  [ "$model" = "github-copilot/gpt-5" ] \
    || fail "the seeded store must carry the doctrine default model github-copilot/gpt-5 (got '$model')"
  # b) source pins a different model -> the doctrine default wins.
  src="$TMP_ROOT/model-win/src/settings.json"
  store="$TMP_ROOT/model-win/store"
  write_source "$src" '{"ANTHROPIC_AUTH_TOKEN":"TOK","ANTHROPIC_MODEL":"claude-opus-4.8"}'
  CRED_FILE="$src" run_seed "$store" >/dev/null
  model=$(jq -r '.env.ANTHROPIC_MODEL // ""' "$store/settings.json")
  [ "$model" = "github-copilot/gpt-5" ] \
    || fail "the doctrine default model must win over a per-machine source model (got '$model')"
  pass "the fleet default model github-copilot/gpt-5 is seeded and wins over a source model override"
}

# --- preserve-existing: an existing store is never clobbered ------------------
test_preserve_existing() {
  local src store
  src="$TMP_ROOT/pre/src/settings.json"
  store="$TMP_ROOT/pre/store"
  write_source "$src" '{"ANTHROPIC_AUTH_TOKEN":"TOK"}'
  mkdir -p "$store"
  printf '{"CURATED":true,"env":{"ANTHROPIC_AUTH_TOKEN":"OWN"}}\n' > "$store/settings.json"
  printf '{"curatedMarker":true}\n' > "$store/.claude.json"
  CRED_FILE="$src" run_seed "$store" >/dev/null
  assert_contains "$(cat "$store/settings.json")" "CURATED" "an existing store settings.json must not be clobbered"
  jq -e '.env.ANTHROPIC_AUTH_TOKEN == "OWN"' "$store/settings.json" >/dev/null \
    || fail "an existing store credential must not be overwritten by the source"
  assert_contains "$(cat "$store/.claude.json")" "curatedMarker" "an existing onboarding marker must not be clobbered"
  pass "preserve-existing: a curated store with its own credential survives re-seeding untouched"
}

# --- a credential-less store is healed once the source gains a credential -----
test_reinject_into_credential_less_store() {
  local src store out
  src="$TMP_ROOT/heal/src/settings.json"
  store="$TMP_ROOT/heal/store"
  # 1) first seed with no source credential (soft) -> a credential-less store.
  write_source "$src" '{}'
  CRED_FILE="$src" run_seed --soft "$store" >/dev/null
  if jq -e '((.env.ANTHROPIC_AUTH_TOKEN // "") | length > 0)' "$store/settings.json" >/dev/null 2>&1; then
    fail "precondition: the first soft seed must leave a credential-less store"
  fi
  # 2) the source later gains a token; preserve-existing must not strand the
  # store - the re-seed injects the newly available credential.
  write_source "$src" '{"ANTHROPIC_AUTH_TOKEN":"TOK2"}'
  CRED_FILE="$src" out=$(run_seed "$store"); rc=$?
  expect_code 0 "$rc" "re-seed after the source gains a credential must resolve (exit 0)"$'\n'"$out"
  jq -e '.env.ANTHROPIC_AUTH_TOKEN == "TOK2"' "$store/settings.json" >/dev/null \
    || fail "re-seed must inject the newly available token into the credential-less store"
  jq -e '.autoMemoryEnabled == false' "$store/settings.json" >/dev/null \
    || fail "the healed store must still carry the doctrine"
  pass "a credential-less store is healed once the source gains a credential"
}

# --- fail-closed: no resolvable credential exits 3 ---------------------------
test_fail_closed_no_credential() {
  local src store out
  src="$TMP_ROOT/fc/src/settings.json"
  store="$TMP_ROOT/fc/store"
  write_source "$src" '{}'
  CRED_FILE="$src" out=$(run_seed "$store"); rc=$?
  expect_code 3 "$rc" "a store with no resolvable credential must fail closed (exit 3)"
  assert_contains "$out" "no Anthropic credential resolvable" "the fail-closed message must name the missing credential"
  pass "fail-closed: an unresolvable credential exits 3 with a clear message"
}

# --- soft mode downgrades a missing credential to a warning ------------------
test_soft_mode() {
  local src store out
  src="$TMP_ROOT/soft/src/settings.json"
  store="$TMP_ROOT/soft/store"
  write_source "$src" '{}'
  CRED_FILE="$src" out=$(run_seed --soft "$store"); rc=$?
  expect_code 0 "$rc" "--soft must not fail on a missing credential"$'\n'"$out"
  assert_present "$store/settings.json" "--soft must still seed the doctrine"
  jq -e '.autoMemoryEnabled == false' "$store/settings.json" >/dev/null \
    || fail "--soft must still carry the doctrine"
  pass "soft mode seeds doctrine and warns instead of failing on a missing credential"
}

# --- ambient key alone satisfies the auth test -------------------------------
test_ambient_key_resolves() {
  local src store out
  src="$TMP_ROOT/amb/src/settings.json"
  store="$TMP_ROOT/amb/store"
  write_source "$src" '{}'
  out=$(env -u ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY=sk-fake \
    FM_ROOT="$ROOT" FM_CLAUDE_CREDENTIAL_FILE="$src" "$SEED" "$store" 2>&1); rc=$?
  expect_code 0 "$rc" "an ambient ANTHROPIC_API_KEY must satisfy the auth test"$'\n'"$out"
  # ...and the secret must NOT be written into the store (it stays ambient).
  assert_not_contains "$(cat "$store/settings.json")" "sk-fake" "an ambient key must never be copied into the store"
  pass "an ambient ANTHROPIC_API_KEY resolves the credential without being written to the store"
}

# --- a source apiKeyHelper credential is propagated into the store -----------
test_apikeyhelper_propagated() {
  local src store out
  src="$TMP_ROOT/akh/src/settings.json"
  store="$TMP_ROOT/akh/store"
  # source authenticates via apiKeyHelper alone: no env token, no .credentials.json.
  mkdir -p "$(dirname "$src")"
  printf '{"apiKeyHelper":"/usr/bin/echo sk-helper","env":{}}\n' > "$src"
  CRED_FILE="$src" out=$(run_seed "$store"); rc=$?
  expect_code 0 "$rc" "a source apiKeyHelper must satisfy the auth test"$'\n'"$out"
  jq -e '.apiKeyHelper == "/usr/bin/echo sk-helper"' "$store/settings.json" >/dev/null \
    || fail "the source apiKeyHelper must be propagated into the store"
  jq -e '.autoMemoryEnabled == false' "$store/settings.json" >/dev/null \
    || fail "the store must still carry the doctrine after apiKeyHelper propagation"
  pass "a source apiKeyHelper is propagated into the store and satisfies the auth test"
}

# --- --check runs the auth test only (no build) ------------------------------
test_check_mode() {
  local store out
  store="$TMP_ROOT/chk/store"
  mkdir -p "$store"
  printf '{"env":{"ANTHROPIC_AUTH_TOKEN":"TOK"}}\n' > "$store/settings.json"
  out=$(run_seed --check "$store"); rc=$?
  expect_code 0 "$rc" "--check on a store with a token must pass"$'\n'"$out"
  # a store with no token fails closed under --check, and builds nothing
  local empty="$TMP_ROOT/chk/empty"
  mkdir -p "$empty"; printf '{"env":{}}\n' > "$empty/settings.json"
  run_seed --check "$empty" >/dev/null; rc=$?
  expect_code 3 "$rc" "--check on a credential-less store must fail closed"
  pass "--check runs the auth test only and honors fail-closed"
}

# --- OAuth .credentials.json is copied forward -------------------------------
test_credentials_file_copied() {
  local src_dir store
  src_dir="$TMP_ROOT/oauth/src"
  store="$TMP_ROOT/oauth/store"
  mkdir -p "$src_dir"
  printf '{"env":{}}\n' > "$src_dir/settings.json"
  printf '{"claudeAiOauth":{"accessToken":"oauth"}}\n' > "$src_dir/.credentials.json"
  CRED_FILE="$src_dir/settings.json" run_seed "$store" >/dev/null; rc=$?
  expect_code 0 "$rc" "an OAuth .credentials.json must satisfy the auth test"
  assert_present "$store/.credentials.json" "the source .credentials.json must be copied into the store"
  pass "an OAuth login credential is copied forward and satisfies the auth test"
}

test_build_injects_credential_and_drops_personal
test_doctrine_env_wins
test_compaction_cap_seeded
test_default_model_seeded
test_preserve_existing
test_reinject_into_credential_less_store
test_fail_closed_no_credential
test_soft_mode
test_ambient_key_resolves
test_apikeyhelper_propagated
test_check_mode
test_credentials_file_copied

echo "# all fm-claude-config-seed tests passed"
