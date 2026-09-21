#!/usr/bin/env bash
# Dependency-free local behavior tests for the optional Microsoft Teams integration.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-teams-link)
HOME_DIR="$TMP_ROOT/home"
REQUEST="tm_$(printf '%064d' 0)"
OTHER="tm_$(printf '%064d' 1)"
mkdir -p "$HOME_DIR/state/teams/requests"
printf '%s\n' '{"captured":true,"approvalStatus":"approved"}' > "$HOME_DIR/state/teams/requests/$REQUEST.json"
printf '%s\n' '{"captured":true,"approvalStatus":"pending"}' > "$HOME_DIR/state/teams/requests/$OTHER.json"
printf '%s\n' 'kind=ship' 'mode=no-mistakes' > "$HOME_DIR/state/work.meta"
printf '%s\n' 'kind=ship' 'mode=no-mistakes' > "$HOME_DIR/state/pending.meta"

if FM_HOME="$HOME_DIR" "$ROOT/bin/fm-teams-link.sh" link "$OTHER" pending >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  fail "a task must not bind an unapproved Teams request"
fi
assert_contains "$(cat "$TMP_ROOT/err")" "requires trusted-local approval" \
  "task binding enforces the local approval gate"
printf '%s\n' '{"captured":true,"approvalStatus":"approved"}' > "$HOME_DIR/state/teams/requests/$OTHER.json"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-teams-link.sh" link "$REQUEST" work >/dev/null
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-teams-link.sh" link "$REQUEST" work >/dev/null
expect_code 1 "$(grep -c "^teams_request=$REQUEST$" "$HOME_DIR/state/work.meta")" \
  "replayed task linking records one binding"
[ "$REQUEST" = "$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-teams-link.sh" request-for-task work)" ] \
  || fail "task binding must resolve the exact Teams request"
if FM_HOME="$HOME_DIR" "$ROOT/bin/fm-teams-link.sh" link "$OTHER" work >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  fail "a task must reject a second Teams request binding"
fi
assert_contains "$(cat "$TMP_ROOT/err")" "different Teams request" \
  "conflicting task binding fails visibly"
if printf '%s\n' 'done' | FM_HOME="$HOME_DIR" "$ROOT/bin/fm-teams-link.sh" complete work \
    --outcome completed --text-file - --request-id "$OTHER" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  fail "task completion must not accept a caller-supplied Teams request id"
fi
assert_contains "$(cat "$TMP_ROOT/err")" "complete does not accept --request-id" \
  "task completion rejects request-id overrides before publication"

printf '%s\n' 'kind=ship' > "$HOME_DIR/state/racing.meta"
READY="$TMP_ROOT/lock-ready"
RELEASE="$TMP_ROOT/lock-release"
FM_HOME="$HOME_DIR" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  lock=$(fm_meta_lock_path "$2/state/racing.meta")
  fm_lock_acquire_wait "$lock"
  : > "$3"
  while [ ! -f "$4" ]; do sleep 0.01; done
  rm -f "$2/state/racing.meta"
  fm_lock_release "$lock"
' _ "$ROOT" "$HOME_DIR" "$READY" "$RELEASE" &
LOCK_PID=$!
while [ ! -f "$READY" ]; do sleep 0.01; done
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-teams-link.sh" link "$REQUEST" racing >"$TMP_ROOT/race-out" 2>"$TMP_ROOT/race-err" &
LINK_PID=$!
sleep 0.1
: > "$RELEASE"
wait "$LOCK_PID"
if wait "$LINK_PID"; then
  fail "link recreated task metadata removed while waiting for its lock"
fi
[ ! -e "$HOME_DIR/state/racing.meta" ] || fail "link recreated removed task metadata"
assert_contains "$(cat "$TMP_ROOT/race-err")" "task metadata not found" \
  "link revalidates task metadata after locking"

pass "fm-teams-integration: local task-binding contracts"
