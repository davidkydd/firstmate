#!/usr/bin/env bash
# Colocated tests for bin/fm-pr-poll-ado.sh: the byte-static watcher program that
# replaces the fork's old generated state/<id>.check.sh ADO requeue shim.
#
# The whole point of this variant is that task/PR data is read from a PRIVATE
# sidecar (state/<id>.ado-pr-poll) and pattern-validated before any side effect,
# instead of being interpolated into executable shell. These tests drive the REAL
# script two ways - via `--validated` args and via the sidecar+$0 rename path -
# and assert the three behaviors it owns end-to-end against az mocks:
#   1. An expired content gate is silently re-queued from the sidecar (Option B:
#      the fork's ADO content-gate re-queue survives the #556 static-poll port).
#   2. A genuinely-stuck (rejected, non-expired) content gate is surfaced once and
#      de-duped via the private state/<id>.ado-stuck-seen marker.
#   3. Exactly one `merged` line is emitted iff the PR is MERGED.
#   4. A malformed sidecar (bad URL, symlinked sidecar, extra trailing line) is
#      rejected with no side effect, preserving the no-interpolation boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

POLL="$ROOT/bin/fm-pr-poll-ado.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-poll-ado-tests)

ADO_URL="https://dev.azure.com/o/p/_git/r/pullrequest/1"

# One policy evaluation JSON object. Args: evalId status isExpired name [build_backed]
policy_obj() {
  local ev=$1 status=$2 expired=$3 name=$4 backed=${5:-true} settings tid
  tid=Microsoft.BuildPolicy
  if [ "$backed" = true ]; then
    settings=$(printf '{"displayName":"%s","buildDefinitionId":"bd-%s"}' "$name" "$ev")
  else
    settings=$(printf '{"displayName":"%s"}' "$name")
    tid=Microsoft.MinimumReviewersPolicy
  fi
  printf '{"evaluationId":"%s","status":"%s","configuration":{"isBlocking":true,"type":{"displayName":"%s","id":"%s"},"settings":%s},"context":{"isExpired":%s}}' \
    "$ev" "$status" "$name" "$tid" "$settings" "$expired"
}

# A fakebin whose `az repos pr policy list` prints <case_dir>/policies.json, whose
# `az repos pr policy queue` appends each --evaluation-id to <case_dir>/queued.log,
# and whose `az repos pr show` reports the merge status in <case_dir>/pr-status
# (default "active"). Echoes the fakebin dir.
make_az_mock() {
  local case_dir=$1 policies_json=$2 pr_status=${3:-active}
  local fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$policies_json" > "$case_dir/policies.json"
  printf '%s\n' "$pr_status" > "$case_dir/pr-status"
  : > "$case_dir/queued.log"
  cat > "$fakebin/az" <<SH
#!/usr/bin/env bash
case " \$* " in
  *"repos pr policy list"*)
    cat "$case_dir/policies.json" ;;
  *"repos pr policy queue"*)
    ev=
    while [ \$# -gt 0 ]; do
      [ "\$1" = "--evaluation-id" ] && { ev=\$2; shift; }
      shift
    done
    printf '%s\n' "\$ev" >> "$case_dir/queued.log"
    printf '{"status":"queued"}\n' ;;
  *"repos pr show"*)
    printf '{"status":"%s","lastMergeSourceCommit":{"commitId":"aaa"}}\n' "\$(cat "$case_dir/pr-status")" ;;
esac
exit 0
SH
  chmod +x "$fakebin/az"
  printf '%s\n' "$fakebin"
}

# Build a case dir with a state/ dir and a valid sidecar pointing at the real
# fm root. Echoes "<case_dir>|<state_dir>|<sidecar>".
make_case() {
  local name=$1 case_dir state sidecar
  case_dir="$TMP_ROOT/$name"
  state="$case_dir/state"
  mkdir -p "$state"
  sidecar="$state/task.ado-pr-poll"
  {
    printf '%s\n' "$ADO_URL"   # line 1: pr url
    printf '\n'                # line 2: worktree (empty -> az --detect skipped)
    printf '%s\n' "$ROOT"      # line 3: fm root (owns fm-scm-lib.sh)
    printf '%s\n' "$state"     # line 4: state dir
    printf '\n'                # line 5: config dir (empty)
  } > "$sidecar"
  printf '%s|%s|%s\n' "$case_dir" "$state" "$sidecar"
}

# --- 1. expired content gate re-queued silently from the sidecar --------------

test_expired_gate_requeued_from_sidecar() {
  local parsed case_dir state fakebin out
  parsed=$(make_case requeue-expired)
  case_dir=${parsed%%|*}; state=$(printf '%s' "$parsed" | cut -d'|' -f2)
  fakebin=$(make_az_mock "$case_dir" "[$(policy_obj e1 broken true 'AKS RP Unit Tests V4')]" active)

  out=$(PATH="$fakebin:$PATH" "$POLL" --validated "$ADO_URL" "" "$ROOT" "$state" "" task)

  # Routine re-queue is silent (the watcher must not wake every poll)...
  [ -z "$out" ] || fail "routine expired-gate requeue should be silent, got: $out"
  # ...but the gate was actually re-queued through the durable scm verb.
  [ "$(cat "$case_dir/queued.log")" = e1 ] \
    || fail "expired content gate not requeued from sidecar (queued.log='$(cat "$case_dir/queued.log")')"
  pass "fm-pr-poll-ado silently re-queues an expired content gate from the static sidecar"
}

# --- 2. stuck gate surfaced once, then de-duped -------------------------------

test_stuck_gate_surfaced_once_then_deduped() {
  local parsed case_dir state fakebin out1 out2 seen
  parsed=$(make_case stuck-dedup)
  case_dir=${parsed%%|*}; state=$(printf '%s' "$parsed" | cut -d'|' -f2)
  # rejected + NOT expired: a genuine red build the poll cannot fix -> surface it.
  fakebin=$(make_az_mock "$case_dir" "[$(policy_obj e2 rejected false 'E2E Build Only')]" active)

  out1=$(PATH="$fakebin:$PATH" "$POLL" --validated "$ADO_URL" "" "$ROOT" "$state" "" task)
  assert_contains "$out1" "content gate needs attention on $ADO_URL" \
    "a stuck content gate should be surfaced on first poll"
  assert_contains "$out1" "rejected:" "stuck surfacing should name the rejected gate"
  seen="$state/task.ado-stuck-seen"
  assert_present "$seen" "a surfaced stuck gate should record its de-dup signature"

  # Same stuck signature on the next poll -> silent (no re-wake).
  out2=$(PATH="$fakebin:$PATH" "$POLL" --validated "$ADO_URL" "" "$ROOT" "$state" "" task)
  [ -z "$out2" ] || fail "an unchanged stuck gate should be de-duped silent on the second poll, got: $out2"
  pass "fm-pr-poll-ado surfaces a stuck content gate once and de-dupes via the private marker"
}

# --- 3. merged line emitted iff MERGED ----------------------------------------

test_merged_line_only_when_merged() {
  local parsed case_dir state fakebin out
  parsed=$(make_case merged-state)
  case_dir=${parsed%%|*}; state=$(printf '%s' "$parsed" | cut -d'|' -f2)
  # No stuck gate; PR still open -> no merged line.
  fakebin=$(make_az_mock "$case_dir" "[$(policy_obj e4 approved false 'AKS RP Unit Tests V4')]" active)
  out=$(PATH="$fakebin:$PATH" "$POLL" --validated "$ADO_URL" "" "$ROOT" "$state" "" task)
  assert_not_contains "$out" "merged" "an open ADO PR must not emit a merged line"

  # Flip the PR to completed -> exactly one merged line.
  printf 'completed\n' > "$case_dir/pr-status"
  out=$(PATH="$fakebin:$PATH" "$POLL" --validated "$ADO_URL" "" "$ROOT" "$state" "" task)
  [ "$out" = merged ] || fail "a completed ADO PR should emit exactly one 'merged' line, got: '$out'"
  pass "fm-pr-poll-ado emits a merged line iff the ADO PR is MERGED"
}

# --- 4. the sidecar+\$0 path reads and validates the private file ------------

test_sidecar_path_drives_poll() {
  local parsed case_dir state sidecar fakebin check out
  parsed=$(make_case sidecar-path)
  case_dir=${parsed%%|*}
  state=$(printf '%s' "$parsed" | cut -d'|' -f2)
  sidecar=$(printf '%s' "$parsed" | cut -d'|' -f3)
  fakebin=$(make_az_mock "$case_dir" "[$(policy_obj e5 broken true 'AKS RP Unit Tests V4')]" completed)

  # The watcher invokes the poll as state/<id>.check.sh with no args; the script
  # derives the sidecar name by swapping .check.sh -> .ado-pr-poll. Mirror that by
  # symlinking a .check.sh name next to the sidecar's base and running it argless.
  check="$state/task.check.sh"
  ln -s "$POLL" "$check"
  out=$(cd "$state" && PATH="$fakebin:$PATH" "$check")
  [ "$out" = merged ] || fail "sidecar path should drive the poll and emit merged, got: '$out'"
  [ "$(cat "$case_dir/queued.log")" = e5 ] \
    || fail "sidecar path should also requeue the expired gate (queued.log='$(cat "$case_dir/queued.log")')"
  pass "fm-pr-poll-ado reads its private sidecar via the .check.sh rename and drives the poll"
}

# --- 5. malformed sidecars are rejected with no side effect -------------------

test_malformed_sidecar_rejected() {
  local parsed case_dir state fakebin out
  parsed=$(make_case malformed)
  case_dir=${parsed%%|*}; state=$(printf '%s' "$parsed" | cut -d'|' -f2)
  fakebin=$(make_az_mock "$case_dir" "[$(policy_obj e6 broken true 'AKS RP Unit Tests V4')]" completed)

  # A non-ADO URL must be refused before any az call (no requeue, no merged line).
  out=$(PATH="$fakebin:$PATH" "$POLL" --validated \
    "https://github.com/o/r/pull/1" "" "$ROOT" "$state" "" task)
  [ -z "$out" ] || fail "a non-ADO URL must produce no output, got: $out"
  [ ! -s "$case_dir/queued.log" ] \
    || fail "a non-ADO URL must trigger no requeue (queued.log='$(cat "$case_dir/queued.log")')"

  # A URL carrying a shell metacharacter must be refused by the charset guard.
  out=$(PATH="$fakebin:$PATH" "$POLL" --validated \
    "https://dev.azure.com/o/p/_git/r/pullrequest/1;rm" "" "$ROOT" "$state" "" task)
  [ -z "$out" ] || fail "a URL with a shell metacharacter must be refused, got: $out"

  # A symlinked sidecar must be refused by the argless path (private-file guard).
  local realfile link
  realfile="$state/real.ado-pr-poll"
  cp "$state/task.ado-pr-poll" "$realfile"
  link="$state/link.check.sh"
  # link.check.sh -> the poll script; link.ado-pr-poll -> a symlink to realfile.
  ln -s "$POLL" "$link"
  ln -s "$realfile" "$state/link.ado-pr-poll"
  out=$(cd "$state" && PATH="$fakebin:$PATH" "$link")
  [ -z "$out" ] || fail "a symlinked sidecar must be refused with no output, got: $out"

  pass "fm-pr-poll-ado rejects a non-ADO URL, a metacharacter URL, and a symlinked sidecar with no side effect"
}

# --- 6. two task ids in one state dir keep separate marker files --------------

test_distinct_task_ids_isolate_markers() {
  local parsed case_dir state fakebin
  parsed=$(make_case two-tasks)
  case_dir=${parsed%%|*}; state=$(printf '%s' "$parsed" | cut -d'|' -f2)
  # rejected + NOT expired: a stuck gate so each task writes a stuck-seen marker,
  # and the requeue verb writes each task's ledger.
  fakebin=$(make_az_mock "$case_dir" "[$(policy_obj e7 rejected false 'E2E Build Only')]" active)

  PATH="$fakebin:$PATH" "$POLL" --validated "$ADO_URL" "" "$ROOT" "$state" "" alpha >/dev/null
  PATH="$fakebin:$PATH" "$POLL" --validated "$ADO_URL" "" "$ROOT" "$state" "" beta >/dev/null

  assert_present "$state/alpha.ado-stuck-seen" "task alpha must own an id-prefixed stuck-seen marker"
  assert_present "$state/beta.ado-stuck-seen" "task beta must own an id-prefixed stuck-seen marker"
  [ ! -e "$state/ado-stuck-seen" ] \
    || fail "no shared (non-id-prefixed) stuck-seen marker may exist"
  pass "fm-pr-poll-ado keeps per-task marker files separate for distinct ids in one state dir"
}

test_expired_gate_requeued_from_sidecar
test_stuck_gate_surfaced_once_then_deduped
test_merged_line_only_when_merged
test_sidecar_path_drives_poll
test_malformed_sidecar_rejected
test_distinct_task_ids_isolate_markers
