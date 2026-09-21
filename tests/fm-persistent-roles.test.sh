#!/usr/bin/env bash
# Behavior tests for tracked persistent-role definitions, generated charters,
# policy boundaries, periodic idle behavior, and restart reconstruction.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-persistent-roles)

assert_role_charter() { # <id> <required-text>
  local id=$1 required=$2 home brief
  home="$TMP_ROOT/brief-$id"
  mkdir -p "$home/data" "$home/state"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null \
    || fail "could not generate the $id charter"
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "$id charter was not generated"
  assert_grep "$required" "$brief" "$id charter omitted its domain owner"
  assert_grep "$home/state/$id.status" "$brief" "$id charter did not derive the current parent channel"
  assert_grep "$home/state/$id.inbox" "$brief" "$id charter did not derive the current instruction inbox"
  assert_no_grep 'fm-ado-pr-review.status' "$brief" "$id charter retained the legacy review status id"
  assert_no_grep 'fm-ado-pr-watch.status' "$brief" "$id charter retained the legacy babysit status id"
  assert_no_grep '/Users/davidkydd/code/ghe/aks-veritas-dev' "$brief" "$id charter retained the retired source path"
  assert_no_grep '{TASK}' "$brief" "$id charter retained a placeholder"
}

test_definitions_and_generated_charters() {
  local out
  out=$("$ROOT/bin/fm-fleet-validate.sh" 2>&1) || fail "tracked role validation failed: $out"
  assert_contains "$out" 'valid: tracked persistent-role definitions' "role validator did not report success"
  assert_role_charter prreview "load the internal \`prreview\` skill"
  assert_role_charter prbabysit "load the internal \`prbabysit\` skill"
  assert_role_charter prdeveloper 'Drive only implementation work routed by the main firstmate'
  pass "persistent roles: all required current ids generate current-format charters with derived parent routes"
}

test_validator_rejects_duplicate_ids_stale_renames_and_missing_assets() {
  local fixture out rc
  fixture="$TMP_ROOT/invalid-fleet"
  cp -R "$ROOT/fleet" "$fixture"
  cp "$fixture/agents/prreview.json" "$fixture/agents/duplicate.json"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_FLEET_OVERRIDE="$fixture" "$ROOT/bin/fm-fleet-validate.sh" 2>&1); rc=$?
  expect_code 1 "$rc" "duplicate current ids must fail validation"
  assert_contains "$out" 'duplicate current role id: prreview' "duplicate-id refusal was not specific"

  rm -f "$fixture/agents/duplicate.json"
  jq '.rename="fm-ado-pr-review"' "$fixture/agents/prreview.json" > "$fixture/agents/prreview.next"
  mv "$fixture/agents/prreview.next" "$fixture/agents/prreview.json"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_FLEET_OVERRIDE="$fixture" "$ROOT/bin/fm-fleet-validate.sh" prreview 2>&1); rc=$?
  expect_code 1 "$rc" "a stale rename target must fail validation"
  assert_contains "$out" 'invalid persistent-role definition' "stale rename refusal was not specific"

  cp "$ROOT/fleet/agents/prreview.json" "$fixture/agents/prreview.json"
  jq '.assets += ["bin/does-not-exist.sh"]' "$fixture/agents/prreview.json" > "$fixture/agents/prreview.next"
  mv "$fixture/agents/prreview.next" "$fixture/agents/prreview.json"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_FLEET_OVERRIDE="$fixture" "$ROOT/bin/fm-fleet-validate.sh" prreview 2>&1); rc=$?
  expect_code 1 "$rc" "a missing role asset must fail validation"
  assert_contains "$out" 'missing role asset for prreview' "missing-asset refusal was not specific"
  pass "persistent roles: validation rejects duplicate ids, stale renames, and missing assets"
}

test_referenced_assets_exist() {
  local id asset
  for id in prreview prbabysit prdeveloper; do
    while IFS= read -r asset; do
      [ -f "$ROOT/$asset" ] && [ ! -L "$ROOT/$asset" ] \
        || fail "$id references missing or indirect asset $asset"
    done < <(jq -r '.assets[]' "$ROOT/fleet/agents/$id.json")
  done
  pass "persistent roles: every declared runtime asset resolves in the authoritative source"
}

test_registry_projection_covers_all_current_roles() {
  local home reg out rc id
  home="$TMP_ROOT/projection"
  mkdir -p "$home/data" "$home/state"
  reg="$home/data/secondmates.md"
  : > "$reg"
  for id in prreview prbabysit prdeveloper; do
    printf -- '- %s - stale (home: %s/%s; scope: stale; projects: none; added 2026-09-21)\n' \
      "$id" "$home" "$id" >> "$reg"
  done
  out=$(FM_HOME="$home" "$ROOT/bin/fm-secondmates-projection.sh" check "$reg" 2>&1); rc=$?
  expect_code 3 "$rc" "stale role projection must report drift"
  assert_no_grep 'no-entry:' <(printf '%s\n' "$out") "a required current role had no tracked definition"
  FM_HOME="$home" "$ROOT/bin/fm-secondmates-projection.sh" regenerate "$reg" >/dev/null \
    || fail "could not regenerate all current role projections"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-secondmates-projection.sh" check "$reg" 2>&1); rc=$?
  expect_code 0 "$rc" "regenerated role projection must be current"
  for id in prreview prbabysit prdeveloper; do
    assert_contains "$out" "unchanged: $id" "$id was absent from the current projection"
  done
  pass "persistent roles: private registry projection covers all three current ids"
}

test_policy_negative_paths() {
  local out rc
  out=$("$ROOT/bin/fm-role-policy.sh" check prreview post-review 2>&1); rc=$?
  expect_code 3 "$rc" "default prreview posting must be denied"
  assert_contains "$out" 'requires an explicit routed request' "posting refusal omitted its authority boundary"
  "$ROOT/bin/fm-role-policy.sh" check prreview post-review --explicit >/dev/null \
    || fail "explicit prreview posting did not pass its bounded policy"
  for pair in 'prreview vote' 'prreview merge-ado' 'prbabysit vote' 'prbabysit merge-ado' 'prdeveloper vote' 'prdeveloper merge-ado'; do
    # shellcheck disable=SC2086
    out=$($ROOT/bin/fm-role-policy.sh check $pair 2>&1); rc=$?
    expect_code 3 "$rc" "$pair must be denied"
  done
  out=$("$ROOT/.agents/skills/prreview/ado-pr-cli.sh" post-comment \
    https://dev.azure.com/example/project/_git/repo/pullrequest/42 /missing.json 2>&1); rc=$?
  expect_code 3 "$rc" "review CLI must reject a posting command before transport without explicit authority"
  assert_contains "$out" 'requires an explicit routed request' "review CLI did not expose the role-policy refusal"
  pass "persistent roles: default posting, voting, and Azure DevOps completion negative paths refuse"
}

make_role_home() { # <id>
  local id=$1 home="$TMP_ROOT/periodic-$1"
  mkdir -p "$home/data" "$home/state" "$home/bin" "$home/fleet" "$home/.agents/skills"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  cp "$ROOT/bin/fm-role-periodic-check.sh" "$ROOT/bin/fm-fleet-lib.sh" \
    "$ROOT/bin/fm-check-register.sh" "$ROOT/bin/fm-check-unregister.sh" \
    "$ROOT/bin/fm-check-lib.sh" "$ROOT/bin/fm-pr-lib.sh" \
    "$ROOT/bin/fm-review-watch-triage.sh" "$ROOT/bin/fm-scm-lib.sh" \
    "$ROOT/bin/fm-brief.sh" "$ROOT/bin/fm-spawn.sh" "$home/bin/"
  cp -R "$ROOT/.agents/skills/prreview" "$ROOT/.agents/skills/prbabysit" \
    "$ROOT/.agents/skills/secondmate-provisioning" "$home/.agents/skills/"
  cp -R "$ROOT/fleet/agents" "$ROOT/fleet/schema" "$home/fleet/"
  cp "$ROOT/fleet/required-secondmates.json" "$home/fleet/"
  printf '%s\n' "$home"
}

test_periodic_check_is_silent_when_empty_and_due_when_active() {
  local home out rc
  home=$(make_role_home prreview)
  cat > "$home/data/prreview.md" <<'EOF'
# Review list
## Queue
## Reviewed / watching
EOF
  FM_HOME="$home" "$home/bin/fm-role-periodic-check.sh" arm prreview >/dev/null \
    || fail "could not arm the prreview periodic check"
  assert_present "$home/state/role-periodic.check.sh" "periodic check was not installed"
  assert_present "$home/state/role-periodic.check-trust" "periodic check was not trust-bound"
  out=$(FM_ROLE_PERIODIC_NOW=100 "$home/state/role-periodic.check.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "empty review list check"
  [ -z "$out" ] || fail "empty review list produced work: $out"
  cat >> "$home/data/prreview.md" <<'EOF'
- https://dev.azure.com/example/project/_git/repo/pullrequest/42 tip=abc reviewed=2026-09-21
EOF
  out=$(FM_ROLE_PERIODIC_NOW=100 "$home/state/role-periodic.check.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "active review list check"
  assert_contains "$out" 'role-maintenance: prreview' "active review list did not produce a maintenance reminder"
  out=$(FM_ROLE_PERIODIC_NOW=101 "$home/state/role-periodic.check.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "within-cadence review check"
  [ -z "$out" ] || fail "periodic check repeated before its cadence elapsed: $out"
  out=$(FM_ROLE_PERIODIC_NOW=1900 "$home/state/role-periodic.check.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "elapsed-cadence review check"
  assert_contains "$out" 'role-maintenance: prreview' "elapsed cadence did not remind the role"
  pass "persistent roles: periodic review reminder stays silent when empty and is cadence-bounded when active"
}

test_prbabysit_empty_and_active_watch() {
  local home out
  home=$(make_role_home prbabysit)
  cat > "$home/data/prbabysit.md" <<'EOF'
# ADO PR watch list
Historical prose and https://dev.azure.com/example/project/_git/repo/pullrequest/old are not live entries.
## Watched
EOF
  FM_HOME="$home" "$home/bin/fm-role-periodic-check.sh" arm prbabysit >/dev/null \
    || fail "could not arm the prbabysit periodic check"
  out=$(FM_ROLE_PERIODIC_NOW=100 "$home/state/role-periodic.check.sh" 2>&1)
  [ -z "$out" ] || fail "empty babysit watch produced work: $out"
  printf '%s\n' '- https://dev.azure.com/example/project/_git/repo/pullrequest/84' >> "$home/data/prbabysit.md"
  out=$(FM_ROLE_PERIODIC_NOW=100 "$home/state/role-periodic.check.sh" 2>&1)
  assert_contains "$out" 'role-maintenance: prbabysit' "active babysit watch did not produce a maintenance reminder"
  pass "persistent roles: babysit periodic work is reconstructed only from the explicit active section"
}

test_role_reprovision_uses_authoritative_source() {
  local parent home out
  parent="$TMP_ROOT/parent"
  home=$(make_role_home prreview)
  mkdir -p "$parent/data/prreview" "$parent/state"
  git -C "$home" init -q
  git -C "$home" remote add origin "$ROOT"
  cat > "$parent/data/secondmates.md" <<EOF
- prreview - stale summary (home: $home; scope: stale scope; projects: none; added 2026-09-21)
EOF
  printf 'legacy charter\n' > "$parent/data/prreview/brief.md"
  printf 'legacy charter\n' > "$home/data/charter.md"
  rm -f "$home/data/prreview.md"
  printf 'durable review bytes\n' > "$home/data/fm-ado-pr-review.md"
  out=$(FM_HOME="$parent" "$ROOT/bin/fm-secondmate-role-sync.sh" prreview 2>&1) \
    || fail "tracked-role reprovision failed: $out"
  cmp -s "$parent/data/prreview/brief.md" "$home/data/charter.md" \
    || fail "reprovision did not publish the same generated charter to parent and role home"
  assert_grep "$parent/state/prreview.status" "$home/data/charter.md" \
    "reprovisioned charter did not bind the current parent channel"
  assert_no_grep 'legacy charter' "$home/data/charter.md" \
    "reprovisioned charter retained legacy prose"
  assert_grep 'Standing Azure DevOps pull-request review service' "$parent/data/secondmates.md" \
    "reprovision did not project the current tracked role summary"
  assert_present "$home/state/role-periodic.check-trust" \
    "reprovision did not arm the current periodic role check"
  assert_present "$home/data/prreview.md" "reprovision did not migrate the legacy durable review-list path"
  assert_absent "$home/data/fm-ado-pr-review.md" "reprovision retained the legacy durable review-list path"
  assert_grep 'durable review bytes' "$home/data/prreview.md" "reprovision changed migrated durable review bytes"
  FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-validate.sh" home prreview "$home" "$parent" >/dev/null \
    || fail "reprovisioned role home did not pass current charter validation"
  git -C "$home" remote set-url origin "$TMP_ROOT/retired-source"
  if out=$(FM_HOME="$parent" "$ROOT/bin/fm-secondmate-role-sync.sh" prreview 2>&1); then
    fail "role reprovision accepted a home sourced from a retired repository"
  fi
  assert_contains "$out" "expected authoritative source $ROOT" \
    "source-repository refusal did not name the authoritative root"
  pass "persistent roles: reprovision regenerates charter and periodic state only from the authoritative source"
}

test_review_restart_reconstruction() {
  local watch out
  watch="$TMP_ROOT/restart-watch.md"
  cat > "$watch" <<'EOF'
# Review list
## Queue
- https://dev.azure.com/example/project/_git/repo/pullrequest/11
- https://dev.azure.com/example/project/_git/repo/pullrequest/12 tip=abc123 reviewed=2026-09-21
## Reviewed / watching
- https://dev.azure.com/example/project/_git/repo/pullrequest/13 tip=def456 reviewed=2026-09-20
EOF
  out=$("$ROOT/bin/fm-review-watch-triage.sh" rearm "$watch") \
    || fail "review restart reconstruction failed"
  assert_no_grep 'pullrequest/11' <(printf '%s\n' "$out") "pending first review was incorrectly treated as reviewed"
  assert_contains "$out" 'rearm=https://dev.azure.com/example/project/_git/repo/pullrequest/12 tip=abc123' "crash-window reviewed entry was not reconstructed"
  assert_contains "$out" 'rearm=https://dev.azure.com/example/project/_git/repo/pullrequest/13 tip=def456' "watched entry was not reconstructed"
  pass "persistent roles: restart reconstructs the changed-tip watch from durable pins"
}

test_definitions_and_generated_charters
test_validator_rejects_duplicate_ids_stale_renames_and_missing_assets
test_referenced_assets_exist
test_registry_projection_covers_all_current_roles
test_policy_negative_paths
test_periodic_check_is_silent_when_empty_and_due_when_active
test_prbabysit_empty_and_active_watch
test_role_reprovision_uses_authoritative_source
test_review_restart_reconstruction
