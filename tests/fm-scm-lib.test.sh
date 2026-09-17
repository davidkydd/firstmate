#!/usr/bin/env bash
# Tests for bin/fm-scm-lib.sh: the SCM provider abstraction firstmate's PR
# lifecycle scripts share. Covers provider detection from a URL and an origin
# remote, PR URL parsing for GitHub and Azure DevOps, and the normalized PR
# helpers (state, head, state+head, number-for-branch) against gh and az mocks.
#
# The routing contract under test: only a provably-ADO provider takes the az
# path; github AND unknown take the gh/gh-axi/git path, so GitHub behaviour is
# byte-for-byte preserved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-scm-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-scm-lib-tests)

# --- provider detection from a URL ------------------------------------------

test_provider_of_url_table() {
  local got
  # each row: url|expected
  local rows=(
    "https://github.com/owner/repo/pull/5|github"
    "git@github.com:owner/repo.git|github"
    "https://example.ghe.com/example-org/example-repo/pull/5|github"
    "git@example.ghe.com:owner/repo.git|github"
    "https://dev.azure.com/org/proj/_git/repo/pullrequest/7|ado"
    "git@ssh.dev.azure.com:v3/org/proj/repo|ado"
    "https://org.visualstudio.com/proj/_git/repo/pullrequest/9|ado"
    "https://gitlab.com/owner/repo|unknown"
    "|unknown"
  )
  local row url want
  for row in "${rows[@]}"; do
    url=${row%%|*}
    want=${row#*|}
    got=$("$LIB" provider-of-url "$url")
    [ "$got" = "$want" ] || fail "provider-of-url '$url': expected $want, got $got"
  done
  pass "fm-scm-lib provider-of-url classifies github/ghe/ado/unknown across host forms"
}

test_provider_of_remote_reads_origin() {
  local dir
  dir="$TMP_ROOT/remote-detect"
  fm_git_init_commit "$dir/gh"
  git -C "$dir/gh" remote add origin https://github.com/owner/repo
  [ "$("$LIB" provider-of-remote "$dir/gh")" = github ] \
    || fail "provider-of-remote: github origin not detected"

  fm_git_init_commit "$dir/ado"
  git -C "$dir/ado" remote add origin https://dev.azure.com/org/proj/_git/repo
  [ "$("$LIB" provider-of-remote "$dir/ado")" = ado ] \
    || fail "provider-of-remote: ado origin not detected"

  fm_git_init_commit "$dir/local"
  [ "$("$LIB" provider-of-remote "$dir/local")" = unknown ] \
    || fail "provider-of-remote: no-origin repo should be unknown"
  pass "fm-scm-lib provider-of-remote classifies from the origin remote (unknown when absent)"
}

test_provider_of_url_table
test_provider_of_remote_reads_origin

# --- GHE-vs-ADO git delivery freeze contract --------------------------------
#
# A repo can migrate from a legacy ADO git host to a GHE (GitHub Enterprise
# Cloud, *.ghe.com) host that becomes authoritative, freezing the ADO git side:
# no fleet path may merge/complete a PR there. This pins that at the provider
# seam every merge/delivery script shares: the GHE host form resolves to github
# (the delivery provider fm-pr-merge.sh merges), and the legacy ADO host form
# resolves to ado (the provider fm-pr-merge.sh REFUSES), so the fleet cannot
# re-merge on the frozen side and the two mains cannot re-diverge through
# firstmate tooling. The ado-refusal itself is owned by
# tests/fm-pr-merge.test.sh; this test owns the repo-specific routing.
test_ghe_ado_git_delivery_freeze() {
  local ghe ado
  ghe="https://example.ghe.com/example-org/example-repo/pull/5"
  ado="https://example-org.visualstudio.com/ExampleProject/_git/example-repo/pullrequest/16674651"
  [ "$("$LIB" provider-of-url "$ghe")" = github ] \
    || fail "ghe-freeze: GHE delivery URL must resolve to github (the delivery provider)"
  [ "$("$LIB" provider-of-url "$ado")" = ado ] \
    || fail "ghe-freeze: legacy ADO host URL must resolve to ado (the frozen provider fm-pr-merge refuses)"
  pass "fm-scm-lib routes GHE delivery to github and a legacy ADO host to the frozen ado provider"
}

test_ghe_ado_git_delivery_freeze

# --- remote URL slug (fm_scm_slug_of_url / fm_scm_slug_of_remote) ------------

test_slug_of_url_table() {
  local got
  # each row: url|expected
  local rows=(
    "git@github.com:owner/repo.git|owner/repo"
    "git@github.com:owner/repo|owner/repo"
    "https://github.com/owner/repo.git|owner/repo"
    "https://github.com/owner/repo|owner/repo"
    "https://dev.azure.com/org/proj/_git/repo|_git/repo"
    "|"
  )
  local row url want
  for row in "${rows[@]}"; do
    url=${row%%|*}
    want=${row#*|}
    got=$("$LIB" slug-of-url "$url")
    [ "$got" = "$want" ] || fail "slug-of-url '$url': expected '$want', got '$got'"
  done
  pass "fm-scm-lib slug-of-url normalizes ssh/https remotes to owner/repo"
}

test_slug_of_remote_reads_origin() {
  local dir
  dir="$TMP_ROOT/slug-remote"
  fm_git_init_commit "$dir/gh"
  git -C "$dir/gh" remote add origin git@github.com:acme/widgets.git
  [ "$("$LIB" slug-of-remote "$dir/gh")" = acme/widgets ] \
    || fail "slug-of-remote: git@ origin not normalized to acme/widgets"

  fm_git_init_commit "$dir/local"
  [ -z "$("$LIB" slug-of-remote "$dir/local")" ] \
    || fail "slug-of-remote: no-origin repo should be empty"
  pass "fm-scm-lib slug-of-remote reads and normalizes the origin remote"
}

test_slug_of_url_table
test_slug_of_remote_reads_origin

# --- PR URL parsing (via a sourcing harness that reads the FM_SCM_* globals) --

# Parse a URL in a subshell that sources the library, print the resolved fields
# as "provider|number|owner|repo|orgurl|project|adorepo" (rc mirrors parse).
parse_fields() {
  local url=$1
  bash -c '
    . "'"$LIB"'"
    if fm_scm_parse_pr_url "'"$url"'" 2>/dev/null; then
      printf "%s|%s|%s|%s|%s|%s|%s" \
        "$FM_SCM_PROVIDER" "$FM_SCM_PR_NUMBER" "$FM_SCM_PR_OWNER" "$FM_SCM_PR_REPO" \
        "$FM_SCM_ADO_ORG_URL" "$FM_SCM_ADO_PROJECT" "$FM_SCM_ADO_REPO"
    else
      printf "RC1|%s" "$FM_SCM_PROVIDER"
      exit 1
    fi
  '
}

test_parse_github_url() {
  local got
  got=$(parse_fields "https://github.com/my-org/my-repo/pull/126/") \
    || fail "parse github: unexpected non-zero"
  [ "$got" = "github|126|my-org|my-repo|||" ] \
    || fail "parse github fields wrong: $got"
  pass "fm-scm-lib parses a GitHub PR URL into owner/repo/number"
}

test_parse_github_url_emu_underscore_owner() {
  local got
  # EMU owners carry an underscore (e.g. example_org); the owner segment
  # must accept the full legal GitHub owner charset, not just [A-Za-z0-9-].
  got=$(parse_fields "https://github.com/example_org/firstmate/pull/7") \
    || fail "parse github emu owner: unexpected non-zero"
  [ "$got" = "github|7|example_org|firstmate|||" ] \
    || fail "parse github emu owner fields wrong: $got"
  pass "fm-scm-lib parses a GitHub PR URL with an underscore EMU owner"
}

test_parse_ghe_url() {
  local got
  # GitHub Enterprise Cloud (any *.ghe.com host), same owner/repo/pull/n shape,
  # classified as the github provider so the shared PR helpers treat a migrated
  # GHE repo as GitHub.
  got=$(parse_fields "https://example.ghe.com/example-org/example-repo/pull/126") \
    || fail "parse ghe: unexpected non-zero"
  [ "$got" = "github|126|example-org|example-repo|||" ] \
    || fail "parse ghe fields wrong: $got"
  pass "fm-scm-lib parses a *.ghe.com PR URL as github (owner/repo/number)"
}

test_parse_ado_devazure_url() {
  local got
  got=$(parse_fields "https://dev.azure.com/contoso/Platform/_git/api/pullrequest/42") \
    || fail "parse ado dev.azure: unexpected non-zero"
  [ "$got" = "ado|42|||https://dev.azure.com/contoso|Platform|api" ] \
    || fail "parse ado dev.azure fields wrong: $got"
  pass "fm-scm-lib parses a dev.azure.com PR URL into org-url/project/repo/number"
}

test_parse_ado_visualstudio_url() {
  local got
  got=$(parse_fields "https://contoso.visualstudio.com/Platform/_git/api/pullrequest/9") \
    || fail "parse ado visualstudio: unexpected non-zero"
  [ "$got" = "ado|9|||https://contoso.visualstudio.com|Platform|api" ] \
    || fail "parse ado visualstudio fields wrong: $got"
  pass "fm-scm-lib parses a *.visualstudio.com PR URL into org-url/project/repo/number"
}

test_parse_unrecognized_url_fails() {
  local got rc
  set +e
  got=$(parse_fields "https://gitlab.com/o/r/merge_requests/3" 2>/dev/null)
  rc=$?
  set -e
  [ "$rc" = 1 ] || fail "parse unrecognized: expected rc 1, got $rc"
  case "$got" in RC1*) : ;; *) fail "parse unrecognized: expected RC1 marker, got $got" ;; esac
  pass "fm-scm-lib refuses an unrecognized PR URL"
}

test_parse_github_url
test_parse_github_url_emu_underscore_owner
test_parse_ghe_url
test_parse_ado_devazure_url
test_parse_ado_visualstudio_url
test_parse_unrecognized_url_fails

# --- PR URL construction (fm_scm_build_pr_url) ------------------------------

# Build a URL by sourcing the lib and calling the builder; no host mocks needed
# (pure string logic). Prints the URL, or "RC<n>" on non-zero exit.
build_url() {
  local out rc
  set +e
  out=$(bash -c '. "'"$LIB"'"; fm_scm_build_pr_url "$@"' _ "$@" 2>/dev/null)
  rc=$?
  set -e
  [ "$rc" = 0 ] && printf '%s' "$out" || printf 'RC%s' "$rc"
}

test_build_pr_url_github() {
  local got
  got=$(build_url github owner repo 5)
  [ "$got" = "https://github.com/owner/repo/pull/5" ] \
    || fail "build github: got '$got'"
  pass "fm-scm-lib build-pr-url builds a canonical GitHub PR URL"
}

test_build_pr_url_ado_bare_org() {
  local got
  got=$(build_url ado example-org ExampleProject example-repo 16422327)
  [ "$got" = "https://example-org.visualstudio.com/ExampleProject/_git/example-repo/pullrequest/16422327" ] \
    || fail "build ado bare org: got '$got'"
  pass "fm-scm-lib build-pr-url maps a bare ADO org to the visualstudio.com PR URL"
}

test_build_pr_url_ado_full_org_base_preserved() {
  local got
  got=$(build_url ado https://dev.azure.com/example-org ExampleProject example-repo 7)
  [ "$got" = "https://dev.azure.com/example-org/ExampleProject/_git/example-repo/pullrequest/7" ] \
    || fail "build ado full org base: got '$got'"
  pass "fm-scm-lib build-pr-url preserves a full dev.azure.com org base"
}

test_build_pr_url_roundtrips_parsed_fields() {
  # Parse a full ADO URL, then rebuild from the parsed fields: same URL back.
  local got
  got=$(bash -c '
    . "'"$LIB"'"
    fm_scm_parse_pr_url "https://example-org.visualstudio.com/ExampleProject/_git/example-repo/pullrequest/16422327" >/dev/null
    fm_scm_build_pr_url ado "$FM_SCM_ADO_ORG_URL" "$FM_SCM_ADO_PROJECT" "$FM_SCM_ADO_REPO" "$FM_SCM_PR_NUMBER"
  ')
  [ "$got" = "https://example-org.visualstudio.com/ExampleProject/_git/example-repo/pullrequest/16422327" ] \
    || fail "build ado roundtrip: got '$got'"
  pass "fm-scm-lib build-pr-url round-trips parsed ADO PR-URL fields"
}

test_build_pr_url_missing_fields_fail() {
  [ "$(build_url github owner repo)" = RC1 ] \
    || fail "build github missing number: expected RC1"
  [ "$(build_url ado example-org ExampleProject example-repo)" = RC1 ] \
    || fail "build ado missing number: expected RC1"
  [ "$(build_url gitlab o r 1)" = RC1 ] \
    || fail "build unknown provider: expected RC1"
  pass "fm-scm-lib build-pr-url fails on missing fields or unknown provider"
}

test_build_pr_url_github
test_build_pr_url_ado_bare_org
test_build_pr_url_ado_full_org_base_preserved
test_build_pr_url_roundtrips_parsed_fields
test_build_pr_url_missing_fields_fail

# --- normalized PR operations against gh and az mocks -----------------------

# A fakebin providing a `gh` that answers state/headRefOid and an `az` that
# answers `repos pr show`/`repos pr list` from JSON. Echoes the fakebin dir.
# Args: case_dir gh_state gh_head ado_status ado_head
make_host_mocks() {
  local case_dir=$1 gh_state=$2 gh_head=$3 ado_status=$4 ado_head=$5
  local fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *"state,headRefOid"*) printf '%s\t%s\n' '$gh_state' '$gh_head' ;;
  *"headRefOid"*) printf '%s\n' '$gh_head' ;;
  *state*) printf '%s\n' '$gh_state' ;;
esac
exit 0
SH
  cat > "$fakebin/az" <<SH
#!/usr/bin/env bash
case " \$* " in
  *"repos pr show"*)
    printf '%s\n' '{"status":"$ado_status","lastMergeSourceCommit":{"commitId":"$ado_head"},"sourceRefName":"refs/heads/feature"}'
    ;;
  *"repos pr list"*)
    printf '%s\n' '[{"pullRequestId":77}]'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh" "$fakebin/az"
  printf '%s\n' "$fakebin"
}

# Call a library function with the mock fakebin on PATH. Args: fakebin fn args...
call_lib() {
  local fakebin=$1; shift
  PATH="$fakebin:$PATH" bash -c '. "'"$LIB"'"; "$@"' _ "$@"
}

test_pr_state_github_and_ado() {
  local case_dir fakebin
  case_dir="$TMP_ROOT/state-both"; mkdir -p "$case_dir"
  fakebin=$(make_host_mocks "$case_dir" MERGED aaa completed bbb)

  [ "$(call_lib "$fakebin" fm_scm_pr_state github '' https://github.com/o/r/pull/1)" = MERGED ] \
    || fail "pr_state github: expected MERGED"
  [ "$(call_lib "$fakebin" fm_scm_pr_state ado '' https://dev.azure.com/org/proj/_git/r/pullrequest/1)" = MERGED ] \
    || fail "pr_state ado: completed should normalize to MERGED"
  pass "fm-scm-lib pr_state normalizes github MERGED and ado completed to MERGED"
}

test_pr_state_ado_non_merged() {
  local case_dir fakebin
  case_dir="$TMP_ROOT/state-active"; mkdir -p "$case_dir"
  fakebin=$(make_host_mocks "$case_dir" OPEN aaa active bbb)
  [ "$(call_lib "$fakebin" fm_scm_pr_state ado '' https://dev.azure.com/org/proj/_git/r/pullrequest/1)" = OPEN ] \
    || fail "pr_state ado: active should normalize to OPEN"
  pass "fm-scm-lib pr_state normalizes ado active to OPEN"
}

test_pr_head_github_and_ado() {
  local case_dir fakebin
  case_dir="$TMP_ROOT/head-both"; mkdir -p "$case_dir"
  fakebin=$(make_host_mocks "$case_dir" MERGED ghhead completed adohead)
  [ "$(call_lib "$fakebin" fm_scm_pr_head github '' https://github.com/o/r/pull/1)" = ghhead ] \
    || fail "pr_head github: expected ghhead"
  [ "$(call_lib "$fakebin" fm_scm_pr_head ado '' https://dev.azure.com/org/proj/_git/r/pullrequest/1)" = adohead ] \
    || fail "pr_head ado: expected adohead from lastMergeSourceCommit.commitId"
  pass "fm-scm-lib pr_head returns the head sha for github and ado"
}

test_pr_state_head_combined() {
  local case_dir fakebin got
  case_dir="$TMP_ROOT/state-head"; mkdir -p "$case_dir"
  fakebin=$(make_host_mocks "$case_dir" MERGED ghhead completed adohead)
  got=$(call_lib "$fakebin" fm_scm_pr_state_head ado '' https://dev.azure.com/org/proj/_git/r/pullrequest/1)
  [ "$got" = "$(printf 'MERGED\tadohead')" ] \
    || fail "pr_state_head ado: expected 'MERGED<tab>adohead', got '$got'"
  pass "fm-scm-lib pr_state_head returns normalized STATE and head in one call"
}

test_pr_number_for_branch_ado() {
  local case_dir fakebin
  case_dir="$TMP_ROOT/branch-ado"; mkdir -p "$case_dir/wt"
  fakebin=$(make_host_mocks "$case_dir" MERGED aaa completed bbb)
  [ "$(call_lib "$fakebin" fm_scm_pr_number_for_branch ado "$case_dir/wt" fm/x)" = 77 ] \
    || fail "pr_number_for_branch ado: expected 77 from az repos pr list"
  pass "fm-scm-lib pr_number_for_branch reads the ado pullRequestId"
}

test_pr_state_github_and_ado
test_pr_state_ado_non_merged
test_pr_head_github_and_ado
test_pr_state_head_combined
test_pr_number_for_branch_ado

# --- ADO expired-content-gate re-queue --------------------------------------
#
# The provider seam that replaces the throwaway per-task state/<id>.check.sh
# requeue shim: enumerate a PR's policy evaluations, classify content vs human,
# and re-queue only an *expired* content gate (isExpired=true, meaning its build
# was green and the validDuration then lapsed), bounded per gate so an infra
# flake is surfaced once at the cap instead of retried forever.

# --- gate classification (the single code owner of the doc's taxonomy) -------

test_gate_kind_classification() {
  # rows: displayName | typeId | build_backed | expected
  local rows=(
    "AKS RP Unit Tests V4|Microsoft.BuildPolicy|true|content"
    "E2E Build Only|Microsoft.BuildPolicy|true|content"
    "Flaky Infra Gate|Microsoft.BuildPolicy|true|content"
    "Build validation||false|content"
    "Code coverage||false|content"
    "Component Governance||false|content"
    "Minimum number of reviewers||false|human"
    "Required reviewers||false|human"
    "Comment requirements||false|human"
    "Require a merge strategy||false|human"
    "Ownership Enforcer||false|human"
    "Proof Of Presence||false|human"
    "some vendor policy|Microsoft.CodeReviewCompliancePolicy|false|human"
    "Status||false|other"
  )
  local row name id backed want got
  for row in "${rows[@]}"; do
    name=${row%%|*}
    id=${row#*|}; id=${id%%|*}
    backed=${row%|*}; backed=${backed##*|}
    want=${row##*|}
    got=$(bash -c '. "'"$LIB"'"; fm_scm_ado_gate_kind "$1" "$2" "$3"' _ "$name" "$id" "$backed")
    [ "$got" = "$want" ] || fail "gate_kind '$name'/'$id'/backed=$backed: expected $want, got $got"
  done
  pass "fm-scm-lib gate_kind classifies build-backed and build/test/coverage/governance as content, reviewer/attestation as human"
}

test_gate_kind_classification

# A fakebin whose `az repos pr policy list` prints the JSON in
# <case_dir>/policies.json and whose `az repos pr policy queue` appends each
# --evaluation-id it is asked to re-queue to <case_dir>/queued.log (so a test can
# assert exactly which evaluations were requeued). `pr show` answers MERGED/OPEN
# from args so the same fakebin can also drive pr-state. Echoes the fakebin dir.
make_policy_mocks() {
  local case_dir=$1 policies_json=$2
  local fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$policies_json" > "$case_dir/policies.json"
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
    printf '%s\n' '{"status":"active","lastMergeSourceCommit":{"commitId":"aaa"}}' ;;
esac
exit 0
SH
  chmod +x "$fakebin/az"
  printf '%s\n' "$fakebin"
}

# One policy evaluation JSON object. Args: evalId status isBlocking isExpired name [typeId] [build_backed] [buildIsNotCurrent]
# build_backed defaults to true (emits a buildDefinitionId); pass false for a
# non-build policy such as a human-review gate. buildIsNotCurrent defaults to
# false; pass true to model a gate pinned to a build that is no longer the
# current merge.
policy_obj() {
  local ev=$1 status=$2 blocking=$3 expired=$4 name=$5 tid=${6:-Microsoft.BuildPolicy} backed=${7:-true} not_current=${8:-false} settings
  if [ "$backed" = true ]; then
    settings=$(printf '{"displayName":"%s","buildDefinitionId":"bd-%s"}' "$name" "$ev")
  else
    settings=$(printf '{"displayName":"%s"}' "$name")
  fi
  printf '{"evaluationId":"%s","status":"%s","configuration":{"isBlocking":%s,"type":{"displayName":"%s","id":"%s"},"settings":%s},"context":{"isExpired":%s,"buildIsNotCurrent":%s}}' \
    "$ev" "$status" "$blocking" "$name" "$tid" "$settings" "$expired" "$not_current"
}

# Run the requeue verb with the policy fakebin on PATH against an ado PR URL.
run_requeue() {
  local fakebin=$1 ledger=$2
  PATH="$fakebin:$PATH" bash -c '. "'"$LIB"'"; fm_scm_ado_requeue_expired_gates ado "" "https://dev.azure.com/o/p/_git/r/pullrequest/1" "'"$ledger"'"'
}

test_expired_content_gate_is_requeued() {
  local case_dir fakebin out queued
  case_dir="$TMP_ROOT/requeue-expired"; mkdir -p "$case_dir"
  fakebin=$(make_policy_mocks "$case_dir" \
    "[$(policy_obj e1 broken true true 'AKS RP Unit Tests V4')]")
  out=$(run_requeue "$fakebin" "$case_dir/ledger")
  assert_contains "$out" "requeued:" "expired content gate should report a requeue"
  assert_contains "$out" "AKS RP Unit Tests V4" "requeue line should name the gate"
  queued=$(cat "$case_dir/queued.log")
  [ "$queued" = e1 ] || fail "expired gate: expected evaluation e1 requeued, got '$queued'"
  pass "fm-scm-lib requeues an expired content gate via az repos pr policy queue"
}

test_rejected_content_gate_not_requeued() {
  local case_dir fakebin out queued
  case_dir="$TMP_ROOT/requeue-rejected"; mkdir -p "$case_dir"
  # rejected/broken but NOT expired: a genuine red build or infra flake.
  fakebin=$(make_policy_mocks "$case_dir" \
    "[$(policy_obj e2 rejected true false 'E2E Build Only')]")
  out=$(run_requeue "$fakebin" "$case_dir/ledger")
  assert_contains "$out" "rejected:" "a rejected non-expired content gate should be surfaced"
  assert_not_contains "$out" "requeued:" "a rejected non-expired content gate must NOT be requeued"
  queued=$(cat "$case_dir/queued.log")
  [ -z "$queued" ] || fail "rejected gate: expected no requeue, got '$queued'"
  pass "fm-scm-lib surfaces a rejected content gate and does not requeue it"
}

test_human_gate_ignored() {
  local case_dir fakebin out queued
  case_dir="$TMP_ROOT/requeue-human"; mkdir -p "$case_dir"
  # An expired human gate must be ignored entirely - never requeued, never surfaced.
  fakebin=$(make_policy_mocks "$case_dir" \
    "[$(policy_obj e3 rejected true true 'Minimum number of reviewers' Microsoft.MinimumReviewersPolicy false)]")
  out=$(run_requeue "$fakebin" "$case_dir/ledger")
  assert_not_contains "$out" "requeued:" "human gate must not be requeued"
  assert_not_contains "$out" "rejected:" "human gate must not be surfaced by the content-gate path"
  queued=$(cat "$case_dir/queued.log")
  [ -z "$queued" ] || fail "human gate: expected no requeue, got '$queued'"
  pass "fm-scm-lib ignores human-review gates entirely"
}

test_requeue_cap_respected() {
  local case_dir fakebin out queued lines
  case_dir="$TMP_ROOT/requeue-cap"; mkdir -p "$case_dir"
  fakebin=$(make_policy_mocks "$case_dir" \
    "[$(policy_obj e4 broken true true 'Flaky Infra Gate')]")
  # Each poll re-reads the same still-expired gate (an infra flake that never goes
  # green). With FM_ADO_REQUEUE_MAX=2, poll 1 and 2 requeue, poll 3 caps.
  out=$(FM_ADO_REQUEUE_MAX=2 run_requeue "$fakebin" "$case_dir/ledger")
  out=$(FM_ADO_REQUEUE_MAX=2 run_requeue "$fakebin" "$case_dir/ledger")
  out=$(FM_ADO_REQUEUE_MAX=2 run_requeue "$fakebin" "$case_dir/ledger")
  assert_contains "$out" "capped:" "third poll should cap the flaky gate instead of requeuing forever"
  lines=$(wc -l < "$case_dir/queued.log" | tr -d ' ')
  [ "$lines" = 2 ] || fail "cap: expected exactly 2 requeues before cap, got $lines"
  pass "fm-scm-lib bounds requeues per gate (infra flake surfaced at the cap, not retried forever)"
}

test_requeue_idempotent_when_reeval_in_flight() {
  local case_dir fakebin out queued
  case_dir="$TMP_ROOT/requeue-inflight"; mkdir -p "$case_dir"
  # A genuinely current re-eval already queued (neither expired nor not-current):
  # the requeue must be a no-op (idempotent), so a good in-flight build is never
  # cancelled and restarted.
  fakebin=$(make_policy_mocks "$case_dir" \
    "[$(policy_obj e5 queued true false 'AKS RP Unit Tests V4' Microsoft.BuildPolicy true false)]")
  out=$(run_requeue "$fakebin" "$case_dir/ledger")
  assert_not_contains "$out" "requeued:" "a current re-eval already queued must not be requeued again"
  queued=$(cat "$case_dir/queued.log")
  [ -z "$queued" ] || fail "in-flight gate: expected no duplicate requeue, got '$queued'"
  pass "fm-scm-lib is idempotent: a current in-flight re-eval is not re-queued"
}

test_stale_queued_gate_is_requeued() {
  local case_dir fakebin out queued
  case_dir="$TMP_ROOT/requeue-stale-queued"; mkdir -p "$case_dir"
  # The bug case: a gate sitting at status=queued whose pinned build is expired
  # AND not-current is STUCK, not in flight, and must be re-queued onto the
  # current merge despite the queued status.
  fakebin=$(make_policy_mocks "$case_dir" \
    "[$(policy_obj e7 queued true true 'AKS RP Unit Tests V4' Microsoft.BuildPolicy true true)]")
  out=$(run_requeue "$fakebin" "$case_dir/ledger")
  assert_contains "$out" "requeued:" "a stale (expired + not-current) queued gate must be requeued"
  queued=$(cat "$case_dir/queued.log")
  [ "$queued" = e7 ] || fail "stale queued gate: expected evaluation e7 requeued, got '$queued'"
  pass "fm-scm-lib requeues a stale gate stuck at status=queued (the captain-reported bug)"
}

test_not_current_only_queued_gate_is_requeued() {
  local case_dir fakebin out queued
  case_dir="$TMP_ROOT/requeue-notcurrent-only"; mkdir -p "$case_dir"
  # buildIsNotCurrent alone (not yet flagged expired) is enough to owe a re-queue:
  # the pinned build no longer matches the current merge.
  fakebin=$(make_policy_mocks "$case_dir" \
    "[$(policy_obj e8 queued true false 'E2E Build Only' Microsoft.BuildPolicy true true)]")
  out=$(run_requeue "$fakebin" "$case_dir/ledger")
  assert_contains "$out" "requeued:" "a not-current queued gate must be requeued even when not yet expired"
  queued=$(cat "$case_dir/queued.log")
  [ "$queued" = e8 ] || fail "not-current gate: expected evaluation e8 requeued, got '$queued'"
  pass "fm-scm-lib requeues a not-current queued gate (buildIsNotCurrent alone is sufficient)"
}

test_non_ado_provider_is_noop() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/requeue-github"; mkdir -p "$case_dir"
  fakebin=$(make_policy_mocks "$case_dir" \
    "[$(policy_obj e6 broken true true 'AKS RP Unit Tests V4')]")
  out=$(PATH="$fakebin:$PATH" bash -c '. "'"$LIB"'"; fm_scm_ado_requeue_expired_gates github "" "https://github.com/o/r/pull/1" "'"$case_dir/ledger"'"')
  [ -z "$out" ] || fail "github provider: expected silent no-op, got '$out'"
  [ ! -s "$case_dir/queued.log" ] || fail "github provider: must never call az policy queue"
  pass "fm-scm-lib requeue is a no-op for the GitHub provider (GitHub path untouched)"
}

test_ledger_keys_do_not_collide() {
  local case_dir ledger c42 c442
  case_dir="$TMP_ROOT/ledger-collision"; mkdir -p "$case_dir"
  ledger="$case_dir/ledger"
  # Bumping key 42 must not disturb key 442 (which ends in the same digits). A
  # substring write-side match would delete 442's line and reset its count.
  bash -c '. "'"$LIB"'"; _fm_scm_ledger_bump "'"$ledger"'" 42 1'
  bash -c '. "'"$LIB"'"; _fm_scm_ledger_bump "'"$ledger"'" 442 1'
  bash -c '. "'"$LIB"'"; _fm_scm_ledger_bump "'"$ledger"'" 42 2'
  c42=$(bash -c '. "'"$LIB"'"; _fm_scm_ledger_count "'"$ledger"'" 42')
  c442=$(bash -c '. "'"$LIB"'"; _fm_scm_ledger_count "'"$ledger"'" 442')
  [ "$c42" = 2 ] || fail "ledger collision: expected key 42 count 2, got '$c42'"
  [ "$c442" = 1 ] || fail "ledger collision: expected key 442 count 1, got '$c442'"
  pass "fm-scm-lib ledger keys 42 and 442 keep independent counts (exact field match, no substring collision)"
}

test_ledger_reset_on_green() {
  local case_dir fakebin out lines
  case_dir="$TMP_ROOT/requeue-reset-green"; mkdir -p "$case_dir"
  # Poll 1: expired -> requeue (count 1). Poll 2: the SAME gate observed
  # approved & not expired -> its ledger line is cleared (count back to 0), no
  # requeue. Poll 3: expired again -> requeued again, proving the cap did not
  # carry the earlier failure across the green observation.
  fakebin=$(make_policy_mocks "$case_dir" \
    "[$(policy_obj g1 broken true true 'AKS RP Unit Tests V4')]")
  out=$(FM_ADO_REQUEUE_MAX=2 run_requeue "$fakebin" "$case_dir/ledger")
  assert_contains "$out" "requeued:" "poll 1 should requeue the expired gate"
  [ "$(bash -c '. "'"$LIB"'"; _fm_scm_ledger_count "'"$case_dir/ledger"'" bd-g1')" = 1 ] \
    || fail "reset-on-green: expected count 1 after first requeue"

  printf '%s\n' "[$(policy_obj g1 approved true false 'AKS RP Unit Tests V4')]" > "$case_dir/policies.json"
  out=$(FM_ADO_REQUEUE_MAX=2 run_requeue "$fakebin" "$case_dir/ledger")
  assert_not_contains "$out" "requeued:" "an approved & not expired gate must not be requeued"
  [ "$(bash -c '. "'"$LIB"'"; _fm_scm_ledger_count "'"$case_dir/ledger"'" bd-g1')" = 0 ] \
    || fail "reset-on-green: expected ledger cleared to 0 on green observation"

  printf '%s\n' "[$(policy_obj g1 broken true true 'AKS RP Unit Tests V4')]" > "$case_dir/policies.json"
  out=$(FM_ADO_REQUEUE_MAX=2 run_requeue "$fakebin" "$case_dir/ledger")
  assert_contains "$out" "requeued:" "after a green reset, a re-expired gate should requeue again"
  lines=$(wc -l < "$case_dir/queued.log" | tr -d ' ')
  [ "$lines" = 2 ] || fail "reset-on-green: expected 2 total requeues across the green reset, got $lines"
  pass "fm-scm-lib resets a gate's ledger on green so the cap counts consecutive failures, not cumulative"
}

test_expired_content_gate_is_requeued
test_rejected_content_gate_not_requeued
test_human_gate_ignored
test_requeue_cap_respected
test_requeue_idempotent_when_reeval_in_flight
test_stale_queued_gate_is_requeued
test_not_current_only_queued_gate_is_requeued
test_non_ado_provider_is_noop
test_ledger_keys_do_not_collide
test_ledger_reset_on_green


