#!/usr/bin/env bash
# fm-claude-config-seed.sh - seed a per-home, reproducible Claude Code config
# store and prove it carries a usable credential (the launch-path auth test).
#
# WHY: by default every fleet claude agent reads the operator's personal
# machine-level ~/.claude at runtime, which both leaks personal config (hooks,
# skills, plugins, model) into fleet behaviour and makes that behaviour
# non-reproducible across machines (see the config-isolation audit). Option 1 of
# that audit pins a per-home CLAUDE_CONFIG_DIR and SEEDS it from committed
# doctrine, so the store is reproducible-from-repo instead of inherited. This
# script builds that store. bin/fm-spawn.sh calls it before pinning
# CLAUDE_CONFIG_DIR onto the claude launch.
#
# The store is built from two sources with a strict split:
#   - COMMITTED doctrine: home-seed/claude-config/settings.json (autoMemory off,
#     permission mode, and any behaviour env the fleet pins, including the
#     sub-128k CLAUDE_CODE_AUTO_COMPACT_WINDOW compaction cap - see
#     docs/compaction-hygiene.md). Reproducible; in the repo. This is the
#     reproducible half.
#   - PER-MACHINE credential: the Anthropic token/endpoint (and model routing
#     coupled to that endpoint) read from the operator's resolved Claude store.
#     NEVER committed; injected at seed time. This is the secret half.
# The result settings.json = doctrine with .env = (source env) + (doctrine env),
# so the working token/endpoint/model vars are preserved verbatim (auth cannot
# break from a dropped credential - the audit's flagged risk) while doctrine env
# keys, when set, still win. A source top-level apiKeyHelper (the command-based
# credential form the auth test also accepts) is carried forward the same way, so
# a helper-authenticated operator is not stranded credential-less. Personal
# hooks/skills/plugins/statusLine are NOT copied, so the leak is closed while the
# fleet's own hooks keep coming from the project scope
# (firstmate/.claude/settings.json).
#
# PRESERVE-EXISTING: an already-seeded store is never clobbered - a live home's
# curated settings.json/.credentials.json/.claude.json survive re-seeding
# untouched (the gc init --preserve-existing analogue).
#
# AUTH TEST (fail-closed): after building, the store is checked for a resolvable
# credential (store env token, store .credentials.json, store apiKeyHelper, or an
# ambient ANTHROPIC_* key). With FM_CLAUDE_CONFIG_REQUIRE_CREDENTIAL=1 (default),
# an unresolvable credential exits 3 so a spawn refuses rather than launching a
# crew that will certainly fail auth. Set it to 0 (or pass --soft) to downgrade a
# missing credential to a warning - used by the hydrate/CI paths, which seed the
# reproducible doctrine on a box that legitimately has no fleet credential.
#
# Usage:
#   fm-claude-config-seed.sh <store-dir>            build + auth test; print store
#   fm-claude-config-seed.sh --check <store-dir>    auth test only (no build)
#   fm-claude-config-seed.sh --soft <store-dir>     build; warn (never fail) on no credential
#   fm-claude-config-seed.sh --help
#
# Environment:
#   FM_CLAUDE_CREDENTIAL_FILE   override the per-machine source settings.json
#                               (default ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json)
#   FM_CLAUDE_CONFIG_REQUIRE_CREDENTIAL   1 (default) fail-closed, 0 soft
#   FM_ROOT                     firstmate root holding home-seed/ (self-located if unset)
#
# Exit codes: 0 success (store seeded and credential resolvable, or soft); 2
# usage/validation error; 3 fail-closed: no credential resolvable; 1 a build step
# failed.
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FM_ROOT="${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { printf 'fm-claude-config-seed.sh: %s\n' "$*" >&2; exit 2; }
fail() { printf 'fm-claude-config-seed.sh: %s\n' "$*" >&2; exit 1; }
warn() { printf 'fm-claude-config-seed.sh: %s\n' "$*" >&2; }

MODE=seed
STORE=
REQUIRE_CREDENTIAL="${FM_CLAUDE_CONFIG_REQUIRE_CREDENTIAL:-1}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --check) MODE=check; shift ;;
    --soft) REQUIRE_CREDENTIAL=0; shift ;;
    --) shift; break ;;
    -*) die "unknown argument: $1" ;;
    *) [ -z "$STORE" ] || die "unexpected extra argument: $1"; STORE=$1; shift ;;
  esac
done
[ -n "${STORE:-}" ] || { [ "$#" -gt 0 ] && STORE=$1; }
[ -n "${STORE:-}" ] || die "missing required <store-dir>"

command -v jq >/dev/null 2>&1 || fail "jq is required"

DOCTRINE="$FM_ROOT/home-seed/claude-config/settings.json"
SRC_SETTINGS="${FM_CLAUDE_CREDENTIAL_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"
SRC_DIR=$(dirname "$SRC_SETTINGS")

# store_has_own_credential <store-dir>: succeed when the store ITSELF carries a
# credential that reaches a pane - a store .credentials.json (OAuth login), an
# env token in the store settings, or a store apiKeyHelper. Excludes the ambient
# key, which a pane inherits independently of the store.
store_has_own_credential() {
  local store=$1 settings="$1/settings.json"
  [ -f "$store/.credentials.json" ] && return 0
  if [ -f "$settings" ]; then
    jq -e '
      ((.env.ANTHROPIC_AUTH_TOKEN // "") | length > 0)
      or ((.env.ANTHROPIC_API_KEY // "") | length > 0)
      or (has("apiKeyHelper") and ((.apiKeyHelper // "") | length > 0))
    ' "$settings" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# source_has_env_credential: the per-machine source settings carries an env
# token/key that can be injected into the store.
source_has_env_credential() {
  [ -f "$SRC_SETTINGS" ] || return 1
  jq -e '
    ((.env.ANTHROPIC_AUTH_TOKEN // "") | length > 0)
    or ((.env.ANTHROPIC_API_KEY // "") | length > 0)
  ' "$SRC_SETTINGS" >/dev/null 2>&1
}

# source_has_apikeyhelper: the per-machine source settings carries a top-level
# apiKeyHelper credential command that can be propagated into the store. This is
# a first-class store credential (store_has_own_credential recognizes it), so a
# source that authenticates via apiKeyHelper alone must still yield a resolvable
# store or auth would break on the very form the auth test accepts.
source_has_apikeyhelper() {
  [ -f "$SRC_SETTINGS" ] || return 1
  jq -e '(.apiKeyHelper // "") | length > 0' "$SRC_SETTINGS" >/dev/null 2>&1
}

# credential_resolvable <store-dir>: succeed when a credential will reach a crew
# launched under CLAUDE_CONFIG_DIR=<store-dir> - the store's own credential, or
# an ambient ANTHROPIC_* key in THIS process's env.
credential_resolvable() {
  local store=$1
  if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    return 0
  fi
  store_has_own_credential "$store"
}

report_credential() {
  local store=$1
  if credential_resolvable "$store"; then
    printf '%s\n' "$store"
    return 0
  fi
  if [ "$REQUIRE_CREDENTIAL" = 0 ]; then
    warn "no Anthropic credential resolvable for store $store; seeded doctrine only (soft mode)"
    printf '%s\n' "$store"
    return 0
  fi
  warn "no Anthropic credential resolvable for the claude config store $store."
  warn "A crew launched under CLAUDE_CONFIG_DIR=$store would fail auth. Store the fleet"
  warn "credential in the source settings env ($SRC_SETTINGS: env.ANTHROPIC_AUTH_TOKEN or"
  warn "env.ANTHROPIC_API_KEY), log in with 'claude' so $SRC_DIR/.credentials.json exists,"
  warn "or export ANTHROPIC_API_KEY. The secret is never copied into the launch command."
  exit 3
}

if [ "$MODE" = check ]; then
  report_credential "$STORE"
  exit 0
fi

[ -f "$DOCTRINE" ] || fail "committed doctrine not found at $DOCTRINE"
jq -e . "$DOCTRINE" >/dev/null 2>&1 || fail "committed doctrine is not valid JSON: $DOCTRINE"

mkdir -p "$STORE" || fail "could not create store dir $STORE"
chmod 700 "$STORE" 2>/dev/null || warn "could not restrict permissions on store dir $STORE"

# settings.json - preserve-existing. The first seed builds doctrine + injected
# source env. An already-seeded store is left untouched, EXCEPT a store carrying
# no credential of its own (a soft hydrate/CI seed, or a spawn on a box that then
# had no credential) has the source credential env re-injected once the source
# can supply one, so preserve-existing never strands the store credential-less.
seed_base=
if [ ! -f "$STORE/settings.json" ]; then
  seed_base="$DOCTRINE"
elif ! store_has_own_credential "$STORE" && { source_has_env_credential || source_has_apikeyhelper; }; then
  seed_base="$STORE/settings.json"
fi
if [ -n "$seed_base" ]; then
  src_env='{}'
  src_helper=
  if [ -f "$SRC_SETTINGS" ]; then
    src_env=$(jq -c '.env // {}' "$SRC_SETTINGS" 2>/dev/null) || src_env='{}'
    src_helper=$(jq -r '.apiKeyHelper // empty' "$SRC_SETTINGS" 2>/dev/null) || src_helper=
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-cc-seed.XXXXXX") || fail "mktemp failed"
  if jq --argjson src_env "$src_env" --arg src_helper "$src_helper" '
      .env = ($src_env + (.env // {}))
      | if ($src_helper != "") and (((.apiKeyHelper // "") | length) == 0)
        then .apiKeyHelper = $src_helper else . end
    ' "$seed_base" > "$tmp"; then
    mv -f "$tmp" "$STORE/settings.json" || { rm -f "$tmp"; fail "could not write $STORE/settings.json"; }
  else
    rm -f "$tmp"
    fail "could not compose settings.json for $STORE"
  fi
fi

# .credentials.json - preserve-existing. Copy an OAuth-login credential forward
# if the source has one and the store does not, so a login-based fleet keeps auth.
if [ ! -f "$STORE/.credentials.json" ] && [ -f "$SRC_DIR/.credentials.json" ]; then
  if cp "$SRC_DIR/.credentials.json" "$STORE/.credentials.json" 2>/dev/null; then
    chmod 600 "$STORE/.credentials.json" 2>/dev/null \
      || warn "could not restrict permissions on $STORE/.credentials.json"
  else
    warn "could not copy $SRC_DIR/.credentials.json into the store (continuing)"
  fi
fi

# .claude.json onboarding marker - preserve-existing. A brand-new config store
# would otherwise trigger Claude Code's first-run onboarding, which stalls the
# unattended pane. Seed only the onboarding-complete flag; never copy the
# operator's personal .claude.json (it holds their whole project history).
if [ ! -f "$STORE/.claude.json" ]; then
  printf '{"hasCompletedOnboarding": true}\n' > "$STORE/.claude.json" \
    || warn "could not write onboarding marker $STORE/.claude.json (continuing)"
fi

report_credential "$STORE"
