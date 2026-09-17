#!/usr/bin/env bash
# Tests for bin/fm-review-watch-triage.sh, the deterministic triage behind the
# fm-pr-review secondmate's self-clearing review-followup watch
# (.agents/skills/prreview/workflows/watch.md).
#
# Two contracts are exercised, both pure and network-free:
#   parse   the durable "## Reviewed / watching" list -> one machine line per PR,
#           ignoring the pending "## Queue" section and prose.
#   rearm   the durable list -> restart re-arm plan: one directive per REVIEWED PR
#           (any tip-pinned entry, in any section), deduped by URL. This is the
#           track-until-merge durable default - a reviewed PR's watch is
#           re-established on restart with no human step, even a reviewed PR whose
#           entry was never moved out of "## Queue".
#   decide  a watched PR's current live facts -> drop | re-review | silent, the
#           three self-clearing outcomes: drop on merge/abandon, re-review on new
#           commits or explicit re-request, silent while open-and-unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TRIAGE="$ROOT/bin/fm-review-watch-triage.sh"

# Run decide and echo just the decision= value (the load-bearing field).
decision_of() {
  "$TRIAGE" decide "$@" | sed -n 's/^decision=//p'
}

# --- parse ------------------------------------------------------------------

test_parse_extracts_watching_entries_only() {
  local tmp out
  tmp=$(fm_test_tmproot fm-watch-parse)
  mkdir -p "$tmp"
  cat > "$tmp/list.md" <<'EOF'
# prreview review list

## Queue
- https://scm.example.com/org/repo/pullrequest/999 (pending first review)

## Reviewed / watching
- https://scm.example.com/org/repo/pullrequest/16422327 tip=abc123 reviewed=2026-07-15
- https://scm.example.com/org/repo/pullrequest/16500000 tip=def456 reviewed=2026-07-16

## Notes
prose that must be ignored, even a - dash bullet here
EOF
  out=$("$TRIAGE" parse "$tmp/list.md")
  assert_contains "$out" \
    "url=https://scm.example.com/org/repo/pullrequest/16422327 tip=abc123 reviewed=2026-07-15" \
    "parse emits the first watching entry"
  assert_contains "$out" \
    "url=https://scm.example.com/org/repo/pullrequest/16500000 tip=def456 reviewed=2026-07-16" \
    "parse emits the second watching entry"
  # The Queue PR (999) and Notes prose must NOT appear.
  assert_not_contains "$out" "pullrequest/999" "parse ignores the ## Queue section"
  assert_not_contains "$out" "prose that must be ignored" "parse ignores prose sections"
  [ "$(printf '%s\n' "$out" | grep -c .)" = 2 ] || fail "parse emitted more than the 2 watching entries"
  pass "parse extracts only the ## Reviewed / watching entries"
}

test_parse_skips_entries_missing_tip() {
  local tmp out
  tmp=$(fm_test_tmproot fm-watch-parse-notip)
  mkdir -p "$tmp"
  cat > "$tmp/list.md" <<'EOF'
## Reviewed / watching
- https://example/pullrequest/1 reviewed=2026-07-16
- https://example/pullrequest/2 tip=good reviewed=2026-07-16
EOF
  out=$("$TRIAGE" parse "$tmp/list.md")
  assert_not_contains "$out" "pullrequest/1" "parse skips a watching entry with no tip= (not triageable)"
  assert_contains "$out" "url=https://example/pullrequest/2 tip=good" "parse keeps a well-formed entry"
  pass "parse skips watching entries missing the load-bearing tip="
}

test_parse_missing_file_errors() {
  local rc
  "$TRIAGE" parse /no/such/watch/list.md >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "parse on a missing file"
  pass "parse exits 2 on a missing watch-list file"
}

# --- rearm: restart re-establishes every reviewed PR's watch ----------------

# The durable-default proof: after a simulated restart (a fresh process with no
# live context, given only the durable home file), rearm reconstitutes the
# track-until-merge watch for every reviewed PR - including one stranded in the
# "## Queue" section because a crash prevented its move - so a reviewed PR can
# never fall off the watch across a restart. A pending-first-review Queue entry
# (no tip=) is correctly NOT re-armed.
test_rearm_reestablishes_watch_across_restart() {
  local tmp out
  tmp=$(fm_test_tmproot fm-watch-rearm)
  mkdir -p "$tmp"
  cat > "$tmp/list.md" <<'EOF'
# prreview review list

## Queue
- https://scm.example.com/org/repo/pullrequest/999 (pending first review)
- https://scm.example.com/org/repo/pullrequest/777 tip=stranded reviewed=2026-08-01

## Reviewed / watching
- https://scm.example.com/org/repo/pullrequest/123 tip=abc reviewed=2026-08-10
- https://scm.example.com/org/repo/pullrequest/456 tip=def reviewed=2026-08-11

## Notes
- prose bullet that must be ignored
EOF
  # A fresh invocation stands in for a restarted session: it reads only the
  # durable file, exactly as restart/recovery does.
  out=$("$TRIAGE" rearm "$tmp/list.md")
  assert_contains "$out" \
    "rearm=https://scm.example.com/org/repo/pullrequest/123 tip=abc" \
    "rearm re-establishes a normally-watched reviewed PR"
  assert_contains "$out" \
    "rearm=https://scm.example.com/org/repo/pullrequest/456 tip=def" \
    "rearm re-establishes the second reviewed PR"
  assert_contains "$out" \
    "rearm=https://scm.example.com/org/repo/pullrequest/777 tip=stranded" \
    "rearm rescues a reviewed PR stranded in ## Queue (missed move), not just the watching section"
  assert_not_contains "$out" "pullrequest/999" \
    "rearm skips a pending-first-review Queue entry (no tip=, not yet reviewed)"
  assert_not_contains "$out" "prose bullet" "rearm ignores prose bullets"
  [ "$(printf '%s\n' "$out" | grep -c .)" = 3 ] || fail "rearm emitted other than the 3 reviewed PRs"
  pass "rearm reconstitutes the track-until-merge watch for every reviewed PR after a restart"
}

test_rearm_dedupes_by_url() {
  local tmp out
  tmp=$(fm_test_tmproot fm-watch-rearm-dedup)
  mkdir -p "$tmp"
  cat > "$tmp/list.md" <<'EOF'
## Reviewed / watching
- https://example/pullrequest/5 tip=first reviewed=2026-08-10
- https://example/pullrequest/5 tip=second reviewed=2026-08-12
EOF
  out=$("$TRIAGE" rearm "$tmp/list.md")
  assert_contains "$out" "rearm=https://example/pullrequest/5 tip=first" "rearm keeps the first pin for a duplicated URL"
  [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] || fail "rearm should re-arm a duplicated URL exactly once"
  pass "rearm dedupes a URL listed twice (re-arms once, first pin wins)"
}

test_rearm_missing_file_errors() {
  local rc
  "$TRIAGE" rearm /no/such/watch/list.md >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "rearm on a missing file"
  pass "rearm exits 2 on a missing watch-list file"
}

# The durable default's self-clearing half: a PR re-armed after restart is then
# dropped by the first decide pass once it merges or is abandoned, so the watch
# clears itself without a human step.
test_rearm_then_decide_clears_on_merge_and_abandon() {
  local tmp rearmed got
  tmp=$(fm_test_tmproot fm-watch-rearm-clear)
  mkdir -p "$tmp"
  cat > "$tmp/list.md" <<'EOF'
## Reviewed / watching
- https://example/pullrequest/8 tip=live reviewed=2026-08-10
EOF
  rearmed=$("$TRIAGE" rearm "$tmp/list.md")
  assert_contains "$rearmed" "rearm=https://example/pullrequest/8 tip=live" "PR is re-armed after restart"
  # It merged while the session was down: the first triage pass drops it.
  got=$(decision_of --status completed --recorded-tip live --current-tip live)
  [ "$got" = drop ] || fail "a merged re-armed PR should drop, got '$got'"
  # An abandoned re-armed PR drops the same way.
  got=$(decision_of --status abandoned --recorded-tip live --current-tip live)
  [ "$got" = drop ] || fail "an abandoned re-armed PR should drop, got '$got'"
  pass "a re-armed PR self-clears from the watch on merge/abandon (first decide pass drops it)"
}

# --- decide: drop on merge / abandon ----------------------------------------

test_decide_drop_on_merged() {
  local got
  got=$(decision_of --status completed --recorded-tip abc123 --current-tip abc123)
  [ "$got" = drop ] || fail "merged PR should drop, got '$got'"
  pass "decide drops a completed (merged) PR"
}

test_decide_drop_on_abandoned() {
  local got
  # Even with an advanced tip, an abandoned PR drops silently - terminal wins.
  got=$(decision_of --status abandoned --recorded-tip abc123 --current-tip zzz999)
  [ "$got" = drop ] || fail "abandoned PR should drop, got '$got'"
  pass "decide drops an abandoned PR regardless of tip movement"
}

# --- decide: re-review on new commits / re-request --------------------------

test_decide_re_review_on_new_commits() {
  local got
  got=$(decision_of --status active --recorded-tip abc123 --current-tip xyz789)
  [ "$got" = re-review ] || fail "new commits should re-review, got '$got'"
  pass "decide re-reviews an open PR whose source tip advanced"
}

test_decide_re_review_on_explicit_request() {
  local got
  # Same tip, but the author re-requested review -> re-review anyway.
  got=$(decision_of --status active --recorded-tip abc123 --current-tip abc123 --rerequest)
  [ "$got" = re-review ] || fail "explicit re-request should re-review, got '$got'"
  pass "decide re-reviews on an explicit re-review request even when the tip is unchanged"
}

# --- decide: silent while open and unchanged --------------------------------

test_decide_silent_on_unchanged() {
  local got
  got=$(decision_of --status active --recorded-tip abc123 --current-tip abc123)
  [ "$got" = silent ] || fail "open+unchanged should be silent, got '$got'"
  pass "decide stays silent on an open, unchanged PR (routine polling)"
}

test_decide_silent_when_current_tip_unknown() {
  local got
  # Cannot resolve the current tip -> cannot prove a change -> stay silent, never
  # a spurious re-review.
  got=$(decision_of --status active --recorded-tip abc123 --current-tip "")
  [ "$got" = silent ] || fail "unknown current tip should be silent, got '$got'"
  pass "decide stays silent when the current tip cannot be resolved (no spurious re-review)"
}

test_decide_unknown_status_treated_as_open() {
  local got
  # An unrecognized status is conservatively open, so an unchanged tip is silent
  # (never a false drop that abandons a live review).
  got=$(decision_of --status weird --recorded-tip abc123 --current-tip abc123)
  [ "$got" = silent ] || fail "unknown status unchanged should be silent, got '$got'"
  pass "decide treats an unknown status as open, not a false drop"
}

test_parse_extracts_watching_entries_only
test_parse_skips_entries_missing_tip
test_parse_missing_file_errors
test_rearm_reestablishes_watch_across_restart
test_rearm_dedupes_by_url
test_rearm_missing_file_errors
test_rearm_then_decide_clears_on_merge_and_abandon
test_decide_drop_on_merged
test_decide_drop_on_abandoned
test_decide_re_review_on_new_commits
test_decide_re_review_on_explicit_request
test_decide_silent_on_unchanged
test_decide_silent_when_current_tip_unknown
test_decide_unknown_status_treated_as_open
