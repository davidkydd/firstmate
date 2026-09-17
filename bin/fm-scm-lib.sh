#!/usr/bin/env bash
# Provider abstraction for the source-control host a firstmate project ships to.
#
# firstmate's lifecycle scripts (fm-pr-check, fm-pr-merge, fm-review-diff,
# fm-teardown) do a handful of PR read/act operations themselves: read a PR's
# state and head sha, find a merged PR for a branch, and make a PR head commit
# resolvable locally. This library is the single owner of "how do we talk to the
# PR host" so those scripts never branch on provider individually.
#
# Provider is detected from a URL (fm_scm_provider_of_url) or from a worktree's
# origin remote (fm_scm_provider_of_remote), using the same host tokens
# no-mistakes uses: github.com -> github; dev.azure.com / ssh.dev.azure.com /
# *.visualstudio.com -> ado; anything else -> unknown.
#
# Routing rule (regression-safe): only a provably-ADO provider takes the `az`
# path. github AND unknown both take the exact `gh`/`gh-axi`/git path firstmate
# used before this library existed, so GitHub behaviour is byte-for-byte
# preserved and a non-github, non-ado remote keeps today's fallthrough.
#
# This library also owns the ADO stale-content-gate re-queue: driving a PR to
# content-readiness sometimes means re-evaluating a build-backed policy whose
# pinned build lapsed (ADO marks it isExpired) or is no longer the current merge
# (buildIsNotCurrent), even though its build was green. A stale eval can sit at
# status=queued/running against the old build, so it is re-queued regardless of
# status. fm_scm_ado_requeue_expired_gates does that PR-native re-eval, bounded so
# a gate that keeps coming back not-green stops being requeued at the cap; a stuck
# gate is then surfaced (de-duped per state change by fm-pr-check.sh, not every
# poll). The content-vs-human gate taxonomy it reuses is described for humans in
# docs/ado-backend.md; fm_scm_ado_gate_kind is its single implementation.
#
# See docs/ado-backend.md for the az command shapes, JSON field names, and the
# fork-PR-for-ADO limitation.
#
# Sourceable and runnable as a CLI shim; the
# generated merge-poll state/<id>.check.sh calls back into the CLI form:
#   fm-scm-lib.sh pr-state <provider> <worktree> <pr-url>
#   fm-scm-lib.sh ado-requeue-expired <provider> <worktree> <pr-url> <ledger>
#   fm-scm-lib.sh build-pr-url github <owner> <repo> <number>
#   fm-scm-lib.sh build-pr-url ado <org> <project> <repo> <number>

# GitHub reads here go through fm_gh_retry. In this public single-identity fork
# there is no EMU/second gh account to fall back to, so it is a thin pass-through
# that simply runs the command and returns its status. (Upstream's dual-identity
# retry machinery is intentionally not carried into the public fork.)
fm_gh_retry() { "$@"; }

# --- provider detection -----------------------------------------------------

fm_scm_provider_of_url() {
  case "$1" in
    *dev.azure.com*|*.visualstudio.com*) echo ado ;;
    # GitHub Enterprise Cloud (any *.ghe.com instance) is GitHub.
    *github.com*|*.ghe.com*) echo github ;;
    *) echo unknown ;;
  esac
}

fm_scm_provider_of_remote() {
  local wt=$1 url
  url=$(git -C "$wt" remote get-url origin 2>/dev/null) || { echo unknown; return 0; }
  [ -n "$url" ] || { echo unknown; return 0; }
  fm_scm_provider_of_url "$url"
}

# --- remote URL slug --------------------------------------------------------
#
# owner/repo slug of a git remote URL, from either git@host:owner/repo(.git) or
# https://host/owner/repo(.git), keeping only the last two path segments. Empty
# for an empty input. The single owner of this normalization; fm-nm-rebuild.sh
# and fm-pr-merge.sh both call it instead of open-coding the same case blocks.
fm_scm_slug_of_url() {
  local url=$1 slug
  [ -n "$url" ] || return 0
  slug=${url%.git}
  case "$slug" in
    *://*) slug=${slug#*://}; slug=${slug#*/} ;;      # https://host/owner/repo
    *:*) slug=${slug#*:} ;;                            # git@host:owner/repo
  esac
  case "$slug" in
    */*/*) slug=${slug#"${slug%/*/*}/"} ;;             # keep last two segments
  esac
  printf '%s' "$slug"
}

# owner/repo slug of a worktree's origin remote, empty when unreadable.
fm_scm_slug_of_remote() {
  local wt=$1 url
  url=$(git -C "$wt" remote get-url origin 2>/dev/null) || return 0
  fm_scm_slug_of_url "$url"
}

# --- PR URL parsing ---------------------------------------------------------
#
# Sets FM_SCM_PROVIDER and, per provider:
#   github: FM_SCM_PR_OWNER, FM_SCM_PR_REPO, FM_SCM_PR_NUMBER
#   ado:    FM_SCM_ADO_ORG_URL, FM_SCM_ADO_PROJECT, FM_SCM_ADO_REPO, FM_SCM_PR_NUMBER
# Returns 0 for a recognized github or ado PR URL, 1 otherwise (and prints the
# legacy error naming both accepted shapes).
# shellcheck disable=SC2034  # FM_SCM_* are outputs consumed by sourcing callers.
fm_scm_parse_pr_url() {
  local url=$1
  FM_SCM_PROVIDER=
  FM_SCM_PR_OWNER=
  FM_SCM_PR_REPO=
  FM_SCM_PR_NUMBER=
  FM_SCM_ADO_ORG_URL=
  FM_SCM_ADO_PROJECT=
  FM_SCM_ADO_REPO=
  # github.com and GitHub Enterprise Cloud (any *.ghe.com instance) share the
  # same <owner>/<repo>/pull/<n> shape and both classify as the github provider.
  if [[ "$url" =~ ^https://(github\.com|[A-Za-z0-9.-]+\.ghe\.com)/([A-Za-z0-9][A-Za-z0-9_.-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    FM_SCM_PR_OWNER="${BASH_REMATCH[2]}"
    FM_SCM_PR_REPO="${BASH_REMATCH[3]}"
    FM_SCM_PR_NUMBER="${BASH_REMATCH[4]}"
    if [[ "$FM_SCM_PR_OWNER" != *- ]]; then
      FM_SCM_PROVIDER=github
      return 0
    fi
  fi
  if [[ "$url" =~ ^https://dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/]+)/pullrequest/([0-9]+)/?$ ]]; then
    FM_SCM_ADO_ORG_URL="https://dev.azure.com/${BASH_REMATCH[1]}"
    FM_SCM_ADO_PROJECT="${BASH_REMATCH[2]}"
    FM_SCM_ADO_REPO="${BASH_REMATCH[3]}"
    FM_SCM_PR_NUMBER="${BASH_REMATCH[4]}"
    FM_SCM_PROVIDER=ado
    return 0
  fi
  if [[ "$url" =~ ^https://([A-Za-z0-9][A-Za-z0-9-]*)\.visualstudio\.com/([^/]+)/_git/([^/]+)/pullrequest/([0-9]+)/?$ ]]; then
    FM_SCM_ADO_ORG_URL="https://${BASH_REMATCH[1]}.visualstudio.com"
    FM_SCM_ADO_PROJECT="${BASH_REMATCH[2]}"
    FM_SCM_ADO_REPO="${BASH_REMATCH[3]}"
    FM_SCM_PR_NUMBER="${BASH_REMATCH[4]}"
    FM_SCM_PROVIDER=ado
    return 0
  fi
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> or an Azure DevOps https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<number> (got: $url)" >&2
  FM_SCM_PROVIDER=unknown
  return 1
}

_fm_scm_pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '') return 1 ;;
    *"/pull/"*) n=${target##*/pull/}; n=${n%%[!0-9]*} ;;
    *"/pullrequest/"*) n=${target##*/pullrequest/}; n=${n%%[!0-9]*} ;;
    [0-9]*) n=${target%%[!0-9]*} ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# --- PR URL construction ----------------------------------------------------
#
# The single canonical builder for a human-clickable PR URL on the shell side
# (the python panel has its own in cli/ado_pr_cli.py). Callers that render a PR
# reference for the captain build it here so a bare id can never leak.
#   github: build-pr-url github <owner> <repo> <number>
#   ado:    build-pr-url ado <org> <project> <repo> <number>
# <org> may be a bare name (mapped to the visualstudio.com host form, the
# captain's canonical form) or a full org base URL (either host form, preserved).
fm_scm_build_pr_url() {
  local provider=$1
  case "$provider" in
    github)
      local owner=$2 repo=$3 number=$4
      [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$number" ] || return 1
      printf 'https://github.com/%s/%s/pull/%s' "$owner" "$repo" "$number"
      ;;
    ado)
      local org=$2 project=$3 repo=$4 number=$5 base
      [ -n "$org" ] && [ -n "$project" ] && [ -n "$repo" ] && [ -n "$number" ] || return 1
      case "$org" in
        http://*|https://*) base=${org%/} ;;
        *) base="https://${org}.visualstudio.com" ;;
      esac
      printf '%s/%s/_git/%s/pullrequest/%s' "$base" "$project" "$repo" "$number"
      ;;
    *) return 1 ;;
  esac
}

# --- state normalizers ------------------------------------------------------

_fm_scm_norm_gh_state() {
  case "$1" in
    MERGED|merged) echo MERGED ;;
    OPEN|open) echo OPEN ;;
    CLOSED|closed) echo CLOSED ;;
    *) echo UNKNOWN ;;
  esac
}

_fm_scm_norm_ado_state() {
  case "$1" in
    completed) echo MERGED ;;
    active) echo OPEN ;;
    abandoned) echo CLOSED ;;
    *) echo UNKNOWN ;;
  esac
}

# --- host queries -----------------------------------------------------------

# gh pr view, run inside the worktree when it exists (a bare PR number needs the
# repo cwd; a full URL does not). Prints the -q selection, empty on any failure.
# Routed through fm_gh_retry so a wrong-active-identity failure retries under the
# other logged-in account; the outer 2>/dev/null keeps the "empty on failure"
# contract while fm_gh_retry still sees gh's stderr internally to classify it.
_fm_scm_gh_view() {
  local wt=$1 target=$2 fields=$3 q=$4
  command -v gh >/dev/null 2>&1 || return 0
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    ( cd "$wt" && fm_gh_retry gh pr view "$target" --json "$fields" -q "$q" 2>/dev/null )
  else
    fm_gh_retry gh pr view "$target" --json "$fields" -q "$q" 2>/dev/null
  fi
}

# az repos pr show -o json for a PR URL (org from the URL) or a bare number
# (org auto-detected from the worktree's remote via --detect). Empty on failure.
_fm_scm_ado_show() {
  local wt=$1 target=$2 n
  command -v az >/dev/null 2>&1 || return 1
  case "$target" in
    http*://*)
      fm_scm_parse_pr_url "$target" >/dev/null 2>&1 || return 1
      [ "$FM_SCM_PROVIDER" = ado ] || return 1
      az repos pr show --id "$FM_SCM_PR_NUMBER" --org "$FM_SCM_ADO_ORG_URL" --output json 2>/dev/null
      ;;
    *)
      n=$(_fm_scm_pr_number_from_target "$target") || return 1
      ( cd "$wt" 2>/dev/null && az repos pr show --id "$n" --detect true --output json 2>/dev/null )
      ;;
  esac
}

# --- normalized PR operations -----------------------------------------------

# Normalized PR state: MERGED|OPEN|CLOSED|UNKNOWN. <target> is a PR URL or,
# for github/unknown, a bare number resolved from the worktree cwd.
fm_scm_pr_state() {
  local provider=$1 wt=$2 target=$3 json status raw
  case "$provider" in
    ado)
      command -v jq >/dev/null 2>&1 || { echo UNKNOWN; return 0; }
      json=$(_fm_scm_ado_show "$wt" "$target") || { echo UNKNOWN; return 0; }
      status=$(printf '%s' "$json" | jq -r '.status // empty' 2>/dev/null)
      _fm_scm_norm_ado_state "$status"
      ;;
    *)
      raw=$(_fm_scm_gh_view "$wt" "$target" state '.state')
      _fm_scm_norm_gh_state "$raw"
      ;;
  esac
}

# PR head commit sha, or empty when unavailable.
fm_scm_pr_head() {
  local provider=$1 wt=$2 target=$3 json
  case "$provider" in
    ado)
      command -v jq >/dev/null 2>&1 || return 0
      json=$(_fm_scm_ado_show "$wt" "$target") || return 0
      printf '%s' "$json" | jq -r '.lastMergeSourceCommit.commitId // empty' 2>/dev/null
      ;;
    *)
      _fm_scm_gh_view "$wt" "$target" headRefOid '.headRefOid'
      ;;
  esac
}

# Combined normalized state and head in one host round-trip: "STATE\tHEAD".
# Returns non-zero when the host lookup fails, so a caller can fall back.
fm_scm_pr_state_head() {
  local provider=$1 wt=$2 target=$3 json status head raw state
  case "$provider" in
    ado)
      command -v jq >/dev/null 2>&1 || return 1
      json=$(_fm_scm_ado_show "$wt" "$target") || return 1
      [ -n "$json" ] || return 1
      status=$(printf '%s' "$json" | jq -r '.status // empty' 2>/dev/null)
      head=$(printf '%s' "$json" | jq -r '.lastMergeSourceCommit.commitId // empty' 2>/dev/null)
      printf '%s\t%s\n' "$(_fm_scm_norm_ado_state "$status")" "$head"
      ;;
    *)
      raw=$(_fm_scm_gh_view "$wt" "$target" state,headRefOid '.state + "\t" + .headRefOid') || return 1
      [ -n "$raw" ] || return 1
      state=${raw%%$'\t'*}
      head=${raw#*$'\t'}
      [ "$state" != "$raw" ] || return 1
      printf '%s\t%s\n' "$(_fm_scm_norm_gh_state "$state")" "$head"
      ;;
  esac
}

# Merged PR number whose source branch is <branch>, or non-zero when none is
# found or any lookup fails (fail-safe: caller treats it as "no PR").
fm_scm_pr_number_for_branch() {
  local provider=$1 wt=$2 branch=$3 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  case "$provider" in
    ado)
      command -v az >/dev/null 2>&1 || return 1
      command -v jq >/dev/null 2>&1 || return 1
      out=$( cd "$wt" 2>/dev/null && az repos pr list --source-branch "refs/heads/$branch" --status completed --detect true --output json 2>/dev/null ) || return 1
      n=$(printf '%s' "$out" | jq -r '.[0].pullRequestId // empty' 2>/dev/null)
      [ -n "$n" ] || return 1
      printf '%s' "$n"
      ;;
    *)
      out=$( cd "$wt" 2>/dev/null && fm_gh_retry gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
      n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
      [ -n "$n" ] || return 1
      printf '%s' "$n"
      ;;
  esac
}

# Ensure <commit> exists locally in <wt>, fetching by the provider's mechanism
# (github refs/pull/<n>/head; ado the PR source branch). Returns 0 iff the
# object is present afterwards.
fm_scm_ensure_commit_object() {
  local provider=$1 wt=$2 target=$3 commit=$4 n json ref
  git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || return 1
  case "$provider" in
    ado)
      json=$(_fm_scm_ado_show "$wt" "$target") || return 1
      command -v jq >/dev/null 2>&1 || return 1
      ref=$(printf '%s' "$json" | jq -r '.sourceRefName // empty' 2>/dev/null)
      [ -n "$ref" ] || return 1
      git -C "$wt" fetch --quiet origin "$ref" >/dev/null 2>&1 || return 1
      git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null
      ;;
    *)
      n=$(_fm_scm_pr_number_from_target "$target") || return 1
      git -C "$wt" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
      git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null
      ;;
  esac
}

# Resolve the PR head to a locally-resolvable commit sha for diffing. A freshly
# fetched remote PR head always wins so review stays current after no-mistakes fix
# rounds push to the PR; a recorded pr_head= is only an offline fallback when the
# remote head cannot be fetched (a stale recorded SHA must never beat a reachable
# remote head). Non-zero when the head cannot be resolved at all (caller warns and
# falls back to the local branch).
fm_scm_resolve_pr_head_commit() {
  local provider=$1 wt=$2 target=$3 recorded=$4 n resolved json head ref
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || {
    # No remote at all: the recorded head is the only thing we can offer.
    if [ -n "$recorded" ] && git -C "$wt" cat-file -e "$recorded^{commit}" 2>/dev/null; then
      printf '%s' "$recorded"
      return 0
    fi
    return 1
  }
  case "$provider" in
    ado)
      if command -v jq >/dev/null 2>&1 && json=$(_fm_scm_ado_show "$wt" "$target"); then
        head=$(printf '%s' "$json" | jq -r '.lastMergeSourceCommit.commitId // empty' 2>/dev/null)
        ref=$(printf '%s' "$json" | jq -r '.sourceRefName // empty' 2>/dev/null)
        if [ -n "$head" ]; then
          if git -C "$wt" cat-file -e "$head^{commit}" 2>/dev/null; then
            printf '%s' "$head"
            return 0
          fi
          if [ -n "$ref" ] && git -C "$wt" fetch --quiet origin "$ref" >/dev/null 2>&1 \
            && git -C "$wt" cat-file -e "$head^{commit}" 2>/dev/null; then
            printf '%s' "$head"
            return 0
          fi
        fi
      fi
      ;;
    *)
      if n=$(_fm_scm_pr_number_from_target "$target") \
        && git -C "$wt" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 \
        && resolved=$(git -C "$wt" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null) \
        && [ -n "$resolved" ]; then
        printf '%s' "$resolved"
        return 0
      fi
      ;;
  esac
  # Fetch failed / unreachable: fall back to the recorded head if it resolves.
  if [ -n "$recorded" ] && git -C "$wt" cat-file -e "$recorded^{commit}" 2>/dev/null; then
    printf '%s' "$recorded"
    return 0
  fi
  return 1
}

# --- ADO stale-content-gate re-queue ----------------------------------------
#
# firstmate gates an ADO PR on its content-influenced automation gates (build /
# test / e2e pipelines, coverage, Component Governance) and ignores human-review
# and attestation gates; docs/ado-backend.md is the human reference for that
# taxonomy. fm_scm_ado_gate_kind is its single code implementation, classifying
# one gate from its policy type displayName (stable and human-readable) with a
# genre/id fallback for the compliance policy the doc names explicitly.
#
# A content gate is a re-queue candidate when ADO has marked its pinned build
# expired (context.isExpired=true, the build was green and the validDuration then
# lapsed) or no longer the current merge (context.buildIsNotCurrent=true, a newer
# merge superseded it): ADO can leave such a stale eval sitting at
# status=queued/running against the old build, so it is re-queued regardless of
# status. A genuinely-rejected content gate (a red build, or an infra flake like
# ACR-unauthorized that never went green) is NOT stale, so it is surfaced and
# never requeued. The re-queue ACTION is bounded per gate by
# a ledger that counts CONSECUTIVE failed requeues: a gate that keeps coming back
# not-green stops being retried at the cap (the infra-flake / ACR-unauthorized
# case), while every observation of that gate green/approved resets its count to
# zero, so a healthy gate that legitimately expires many times over a long-lived
# PR - each requeue succeeding - never false-trips the cap. The SURFACING of a
# stuck gate is de-duped by fm-pr-check.sh's stuck-seen marker (default) so
# firstmate is woken once per state change rather than every poll, unless
# FM_ADO_STUCK_GATE_RENOTIFY forces re-notify-every-poll.

FM_ADO_REQUEUE_MAX=${FM_ADO_REQUEUE_MAX:-3}

# content | human | other, from a policy type displayName, type id, and whether
# the policy is build-backed. A build-backed policy (its settings carry a
# buildDefinitionId) is a content gate regardless of how a human named it - that
# is the durable signal, since an "AKS RP Unit Tests V4" build gate and a flaky
# infra build gate are both build-backed. Falls back to the displayName/id
# taxonomy in docs/ado-backend.md for non-build content (coverage, governance)
# and the human-review set.
fm_scm_ado_gate_kind() {
  local name=$1 id=$2 build_backed=${3:-false} lname
  case "$id" in
    *CodeReviewCompliancePolicy*) echo human; return 0 ;;
  esac
  if [ "$build_backed" = true ]; then
    echo content; return 0
  fi
  lname=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  case "$lname" in
    *"minimum number of reviewers"*|*"required reviewers"*|*"comment requirements"*|\
    *"merge strategy"*|*"code review compliance"*|*"ownership enforcer"*|\
    *"proof of presence"*)
      echo human ;;
    *build*|*test*|*e2e*|*coverage*|*"component governance"*|*governance*)
      echo content ;;
    *)
      echo other ;;
  esac
}

# az repos pr policy list -o json for a PR URL (org from the URL) or a bare
# number (org auto-detected via --detect). Empty on failure.
_fm_scm_ado_policy_list() {
  local wt=$1 target=$2 n
  command -v az >/dev/null 2>&1 || return 1
  case "$target" in
    http*://*)
      fm_scm_parse_pr_url "$target" >/dev/null 2>&1 || return 1
      [ "$FM_SCM_PROVIDER" = ado ] || return 1
      az repos pr policy list --id "$FM_SCM_PR_NUMBER" --org "$FM_SCM_ADO_ORG_URL" --output json 2>/dev/null
      ;;
    *)
      n=$(_fm_scm_pr_number_from_target "$target") || return 1
      ( cd "$wt" 2>/dev/null && az repos pr policy list --id "$n" --detect true --output json 2>/dev/null )
      ;;
  esac
}

# az repos pr policy queue for one evaluation, org/pr resolved the same way.
_fm_scm_ado_policy_queue() {
  local wt=$1 target=$2 eval_id=$3 n
  command -v az >/dev/null 2>&1 || return 1
  case "$target" in
    http*://*)
      fm_scm_parse_pr_url "$target" >/dev/null 2>&1 || return 1
      [ "$FM_SCM_PROVIDER" = ado ] || return 1
      az repos pr policy queue --id "$FM_SCM_PR_NUMBER" --evaluation-id "$eval_id" \
        --org "$FM_SCM_ADO_ORG_URL" --output json >/dev/null 2>&1
      ;;
    *)
      n=$(_fm_scm_pr_number_from_target "$target") || return 1
      ( cd "$wt" 2>/dev/null && az repos pr policy queue --id "$n" --evaluation-id "$eval_id" \
        --detect true --output json >/dev/null 2>&1 )
      ;;
  esac
}

# Ledger helpers: a per-gate attempt count in "key<TAB>count" lines. The key is a
# stable gate identity (buildDefinitionId, else displayName) because each requeue
# mints a fresh evaluationId, so evaluationId cannot dedupe across attempts.
_fm_scm_ledger_count() {
  local ledger=$1 key=$2
  [ -f "$ledger" ] || { echo 0; return 0; }
  awk -F'\t' -v k="$key" '$1 == k { print $2; found=1 } END { if (!found) print 0 }' "$ledger" | tail -1
}

_fm_scm_ledger_bump() {
  local ledger=$1 key=$2 new=$3 tmp
  tmp="$ledger.tmp.$$"
  { [ -f "$ledger" ] && awk -F'\t' -v k="$key" '$1 != k' "$ledger" 2>/dev/null; printf '%s\t%s\n' "$key" "$new"; } > "$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$ledger"
}

_fm_scm_ledger_clear() {
  local ledger=$1 key=$2 tmp
  [ -f "$ledger" ] || return 0
  tmp="$ledger.tmp.$$"
  awk -F'\t' -v k="$key" '$1 != k' "$ledger" 2>/dev/null > "$tmp" || return 1
  mv -f "$tmp" "$ledger"
}

# Detect stale content gates on an ADO PR and re-queue each once per poll, up to
# FM_ADO_REQUEUE_MAX times per gate. A gate is stale when its pinned build has
# expired (context.isExpired) or is no longer the current merge
# (context.buildIsNotCurrent); ADO can leave such an eval sitting at
# status=queued/running against the old build, so status alone does not mean a
# fresh re-eval is in flight. Prints one decision line per acted-on or surfaced
# gate ("requeued:"/"rejected:"/"capped:"), silent for green/pending/human/other
# gates. Non-ADO providers are a no-op (GitHub path untouched).
# Args: provider worktree target ledger-path
fm_scm_ado_requeue_expired_gates() {
  local provider=$1 wt=$2 target=$3 ledger=$4 json
  local eval_id status blocking expired not_current tname tid build_backed key label kind count
  [ "$provider" = ado ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  json=$(_fm_scm_ado_policy_list "$wt" "$target") || return 0
  [ -n "$json" ] || return 0
  while IFS=$'\t' read -r eval_id status blocking expired not_current tname tid build_backed key label; do
    [ -n "$eval_id" ] || continue
    [ "$blocking" = true ] || continue
    kind=$(fm_scm_ado_gate_kind "$tname" "$tid" "$build_backed")
    [ "$kind" = content ] || continue
    # A gate is stale when its pinned build has expired or is no longer the
    # current merge; ADO leaves such an eval sitting at status=queued/running
    # against the old build instead of re-running it, so a stale eval is owed a
    # re-queue onto the current merge regardless of status. Only a queued/running
    # eval with neither flag is a fresh re-eval genuinely in flight to leave alone.
    if [ "$expired" = true ] || [ "$not_current" = true ]; then
      count=$(_fm_scm_ledger_count "$ledger" "$key")
      if [ "$count" -ge "$FM_ADO_REQUEUE_MAX" ]; then
        printf 'capped: %s (stale, %s requeues exhausted - surfacing)\n' "$label" "$count"
        continue
      fi
      if _fm_scm_ado_policy_queue "$wt" "$target" "$eval_id"; then
        _fm_scm_ledger_bump "$ledger" "$key" "$((count + 1))"
        printf 'requeued: %s (stale content gate, attempt %s)\n' "$label" "$((count + 1))"
      else
        printf 'capped: %s (stale, requeue call failed)\n' "$label"
      fi
      continue
    fi
    case "$status" in
      queued|running) continue ;;  # a fresh re-eval is genuinely in flight: idempotent
    esac
    if [ "$status" = approved ]; then
      _fm_scm_ledger_clear "$ledger" "$key"  # recovered to green: reset its consecutive-failure count
      continue
    fi
    if [ "$status" = rejected ] || [ "$status" = broken ]; then
      printf 'rejected: %s (content gate failing, not stale - not requeued)\n' "$label"
    fi
  done <<EOF
$(printf '%s' "$json" | jq -r '
  .[] | [
    (.evaluationId // ""),
    (.status // ""),
    (.configuration.isBlocking // false | tostring),
    (.context.isExpired // false | tostring),
    (.context.buildIsNotCurrent // false | tostring),
    (.configuration.type.displayName // ""),
    (.configuration.type.id // ""),
    (.configuration.settings.buildDefinitionId != null | tostring),
    ((.configuration.settings.buildDefinitionId // .configuration.settings.displayName // .configuration.type.displayName) | tostring),
    (.configuration.settings.displayName // .configuration.type.displayName // "gate")
  ] | @tsv' 2>/dev/null)
EOF
}

# --- ADO static poll arming (#556 no-interpolation model) --------------------
#
# Arm the ADO merge/content-gate poll for a task as byte-static artifacts, the
# ADO counterpart to fm-pr-lib.sh's GitHub arming. Instead of generating a
# state/<id>.check.sh with task/PR data interpolated into shell source, this
# writes a private sidecar state/<id>.ado-pr-poll (one field per line) and copies
# bin/fm-pr-poll-ado.sh byte-for-byte to state/<id>.check.sh, so the watcher
# executes only trusted repository source and reads all task/PR data from the
# validated sidecar. Uses the private-file discipline from fm-pr-lib.sh, which
# the caller (fm-pr-check.sh) has already sourced.
# Args: state id url worktree fm_root config template
# Returns 0 on a fully-verified arm, non-zero (leaving no partial artifacts)
# otherwise.
fm_scm_ado_poll_arm() {
  local state=$1 id=$2 url=$3 worktree=$4 fm_root=$5 config=$6 template=$7
  local data_dest check_dest data_tmp check_tmp state_device

  fm_pr_task_id_valid "$id" || return 1
  case "$url" in
    https://dev.azure.com/*/_git/*/pullrequest/*) ;;
    https://*.visualstudio.com/*/_git/*/pullrequest/*) ;;
    *) return 1 ;;
  esac
  case "$url" in
    *[!A-Za-z0-9:/._~%-]*) return 1 ;;
  esac
  [ -f "$template" ] && [ ! -L "$template" ] || return 1
  [ -n "$fm_root" ] && [ -f "$fm_root/bin/fm-scm-lib.sh" ] || return 1
  [ ! -L "$state" ] && [ -d "$state" ] || return 1

  state_device=$(fm_pr_file_device "$state") || return 1
  [ -n "$state_device" ] || return 1
  data_dest="$state/$id.ado-pr-poll"
  check_dest="$state/$id.check.sh"

  umask 077
  data_tmp=$(mktemp "$state/.fm-ado-pr-poll.XXXXXX") || return 1
  check_tmp=$(mktemp "$state/.fm-ado-pr-check.XXXXXX") || { rm -f -- "$data_tmp"; return 1; }

  # Field order MUST match fm-pr-poll-ado.sh's reader: url, worktree, fm_root,
  # state, config.
  if ! printf '%s\n%s\n%s\n%s\n%s\n' "$url" "$worktree" "$fm_root" "$state" "$config" > "$data_tmp" \
    || ! chmod 0600 "$data_tmp" \
    || ! fm_pr_private_file_valid "$data_tmp" 600 "$state_device" \
    || ! cp "$template" "$check_tmp" \
    || ! chmod 0600 "$check_tmp" \
    || ! fm_pr_private_file_valid "$check_tmp" 600 "$state_device" \
    || ! cmp -s "$template" "$check_tmp"; then
    rm -f -- "$data_tmp" "$check_tmp"
    return 1
  fi

  if ! fm_pr_regular_destination_on_device_or_absent "$data_dest" "$state_device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$check_dest" "$state_device" \
    || ! mv -f -- "$data_tmp" "$data_dest"; then
    rm -f -- "$data_tmp" "$check_tmp"
    return 1
  fi
  data_tmp=
  if ! fm_pr_private_file_valid "$data_dest" 600 "$state_device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$check_dest" "$state_device" \
    || ! mv -f -- "$check_tmp" "$check_dest"; then
    rm -f -- "$check_tmp"
    rm -f -- "$data_dest"
    return 1
  fi
  check_tmp=
  if ! fm_pr_private_file_valid "$check_dest" 600 "$state_device" \
    || ! cmp -s "$template" "$check_dest"; then
    rm -f -- "$check_dest" "$data_dest"
    return 1
  fi
}

# Validate that a task's ADO poll artifacts are authentic before the watcher
# executes them: the check.sh must be a byte-for-byte copy of the trusted ADO
# poll template, both it and the sidecar must be private single-link files on the
# state device, and the sidecar's URL field must be a canonical ADO PR URL. On
# success sets FM_SCM_ADO_POLL_URL / _WORKTREE / _FMROOT / _STATE / _CONFIG from
# the validated sidecar. Mirrors fm_pr_poll_artifacts_valid's posture for the
# GitHub static poll. Uses fm-pr-lib.sh's private-file helpers, which the caller
# (fm-watch.sh) has already sourced.
# shellcheck disable=SC2034  # FM_SCM_ADO_POLL_* are outputs consumed by sourcing callers.
fm_scm_ado_poll_valid() {
  local state=$1 id=$2 template=$3 state_device check data url worktree fm_root sc_state config
  FM_SCM_ADO_POLL_URL=
  FM_SCM_ADO_POLL_WORKTREE=
  FM_SCM_ADO_POLL_FMROOT=
  FM_SCM_ADO_POLL_STATE=
  FM_SCM_ADO_POLL_CONFIG=
  FM_SCM_ADO_POLL_ID=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  [ -f "$template" ] && [ ! -L "$template" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.ado-pr-poll"
  fm_pr_private_file_valid "$check" 600 "$state_device" || return 1
  fm_pr_private_file_valid "$data" 600 "$state_device" || return 1
  cmp -s "$template" "$check" || return 1
  # Sidecar fields (one per line): url, worktree, fm_root, state, config. Validate
  # the URL shape without executing anything.
  { exec 9< "$data"; } 2>/dev/null || return 1
  IFS= read -r url <&9 || { exec 9<&-; return 1; }
  IFS= read -r worktree <&9 || { exec 9<&-; return 1; }
  IFS= read -r fm_root <&9 || { exec 9<&-; return 1; }
  IFS= read -r sc_state <&9 || { exec 9<&-; return 1; }
  IFS= read -r config <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  case "$url" in
    https://dev.azure.com/*/_git/*/pullrequest/*) ;;
    https://*.visualstudio.com/*/_git/*/pullrequest/*) ;;
    *) return 1 ;;
  esac
  case "$url" in
    *[!A-Za-z0-9:/._~%-]*) return 1 ;;
  esac
  FM_SCM_ADO_POLL_URL=$url
  FM_SCM_ADO_POLL_WORKTREE=$worktree
  FM_SCM_ADO_POLL_FMROOT=$fm_root
  FM_SCM_ADO_POLL_STATE=$sc_state
  FM_SCM_ADO_POLL_CONFIG=$config
  FM_SCM_ADO_POLL_ID=$id
}

# --- CLI shim ---------------------------------------------------------------

fm_scm_main() {
  local cmd=${1:-}
  [ "$#" -gt 0 ] && shift
  case "$cmd" in
    provider-of-url) fm_scm_provider_of_url "${1:-}" ;;
    provider-of-remote) fm_scm_provider_of_remote "${1:-}" ;;
    slug-of-url) fm_scm_slug_of_url "${1:-}" ;;
    slug-of-remote) fm_scm_slug_of_remote "${1:-}" ;;
    build-pr-url) fm_scm_build_pr_url "$@" ;;
    pr-state) fm_scm_pr_state "${1:-}" "${2:-}" "${3:-}" ;;
    pr-head) fm_scm_pr_head "${1:-}" "${2:-}" "${3:-}" ;;
    pr-number-for-branch) fm_scm_pr_number_for_branch "${1:-}" "${2:-}" "${3:-}" ;;
    ado-requeue-expired) fm_scm_ado_requeue_expired_gates "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
    *)
      echo "usage: fm-scm-lib.sh {provider-of-url|provider-of-remote|slug-of-url|slug-of-remote|build-pr-url|pr-state|pr-head|pr-number-for-branch|ado-requeue-expired} ..." >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_scm_main "$@"
fi
