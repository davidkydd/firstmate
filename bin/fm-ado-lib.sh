# shellcheck shell=bash
# shellcheck disable=SC2016  # jq filter bodies use single quotes so $vars are jq --arg refs, not shell expansions
# Shared Azure DevOps (ADO) backlog-backend library for the `ado` value of
# config/backlog-backend. ADO work items are the source of truth for the backlog
# when this backend is active; a local cache under data/ keeps reads fast and
# offline-tolerant. See docs/ado-task-backend.md for the full contract, field
# mappings, WIQL, and az commands. This file owns the mechanics; keep the
# AGENTS.md pointer one line.
#
# Usage: . bin/fm-ado-lib.sh   (needs FM_HOME resolved by the caller, or pass
# dirs explicitly to the helpers that take them)
#
# Design (the kind-aware shape and title/description split are the 2026-07-15
# redesign):
#   - One standing Epic per fleet, titled davidkydd-firstmate, tagged fm-managed.
#     All firstmate work nests under it. Create-or-reused idempotently and cached.
#   - Work-item shape is KIND-AWARE:
#       * ship  -> a User Story directly under the Epic, with child Tasks per
#         lifecycle STAGE (initial-development, test, review, fix-review-findings,
#         open-and-babysit-pr). As a dev crew discovers more work, NEW child Tasks
#         are added under the same Story (fm_ado_add_child_task).
#       * scout / review -> a single Task directly under the Epic (no User Story).
#         These are single-deliverable investigations, not multi-stage dev.
#     The old per-project fm-<project> User Story layer is REMOVED; the project is
#     the flat tag fm-repo:<name> on the primary work item, not a level.
#   - Title is a firstmate-generated concise SUMMARY, supplied at add time. The
#     shell backend cannot summarize, so firstmate passes both the short title and
#     the full content (the captain's verbatim prompt and the generated brief) via
#     files; fm_ado_compose_description folds them into the Description, which is
#     the durable full record. The backend clamps the title to a word-boundary
#     ceiling (FM_ADO_TITLE_MAX_CHARS) as a backstop so a verbose title never slips
#     through; the full text is in the Description regardless.
#   - The Description is HTML (System.Description is an HTML long-text field; the
#     az CLI has no markdown-format flag, so the backend composes semantic HTML).
#     The in-budget prompt/brief HEAD renders as human-readable HTML (paragraphs,
#     lists, headings, fenced code) via fm_ado_emit_rich; the spill/comment payloads
#     keep <pre> for their byte-exact reconstruction contract. Content is NEVER
#     truncated: the Description holds as much of each section as fits a byte budget
#     (FM_ADO_DESC_MAX_CHARS), and any remainder spills to ordered work-item
#     COMMENTS (FM_ADO_COMMENT_MAX_CHARS each), so Description + comments
#     reconstruct the full prompt and brief exactly.
#   - firstmate id (the fix-login-k3-style slug) is recorded durably on the primary
#     work item as the tag fm-id:<slug>, so it round-trips even if the cache is
#     lost. The kind is the tag fm-kind:<ship|scout|review>.
#   - firstmate state maps to System.State: Queued -> New, In flight -> Active,
#     Done -> Closed (applied to the primary work item).
#   - blocked-by maps to a Predecessor/Successor dependency link
#     (System.LinkTypes.Dependency-*): blocker is Predecessor of the blocked.
#   - Iteration defaults to the configured team's @currentIteration macro, resolved
#     live at create time to a concrete path so work tracks the rolling MMM sprint
#     without a hardcoded sprint.
#   - System.Rev is cached per item for cheap change detection on refresh.
#
# All az calls route through fm_ado_az so tests can inject a mock via FM_ADO_AZ.

# --- az invocation seam (mockable) -----------------------------------------

fm_ado_az() {
  "${FM_ADO_AZ:-az}" "$@"
}

# --- config ----------------------------------------------------------------
# config/ado-backend.env is a LOCAL (gitignored) shell-sourceable file with the
# verified defaults baked in below, so an absent or partial file still works.
# It is one of the inheritable config items (see fm-config-inherit-lib.sh), so a
# secondmate home inherits the primary's ADO target.

# ADO target defaults. These are NEUTRAL/empty on purpose: the ADO backend is
# organization-agnostic and inert until an operator points it at their OWN Azure
# DevOps org/project/team/area path, either via config/ado-backend.env (see
# fm_ado_load_config) or by exporting the corresponding FM_ADO_DEFAULT_* /
# FM_ADO_* variables. No organization is baked into the shared library.
#   FM_ADO_DEFAULT_ORG        e.g. https://dev.azure.com/<your-org>
#   FM_ADO_DEFAULT_PROJECT    e.g. <your-project>
#   FM_ADO_DEFAULT_TEAM       e.g. <your-team>
#   FM_ADO_DEFAULT_AREA_PATH  e.g. <Project>\<Area>\<SubArea>
FM_ADO_DEFAULT_ORG="${FM_ADO_DEFAULT_ORG:-}"
FM_ADO_DEFAULT_PROJECT="${FM_ADO_DEFAULT_PROJECT:-}"
FM_ADO_DEFAULT_TEAM="${FM_ADO_DEFAULT_TEAM:-}"
FM_ADO_DEFAULT_AREA_PATH="${FM_ADO_DEFAULT_AREA_PATH:-}"
FM_ADO_DEFAULT_ITERATION="@currentIteration"
# One standing Epic per fleet; every primary work item parents to it.
FM_ADO_DEFAULT_EPIC_TITLE="davidkydd-firstmate"
# The default lifecycle stages a ship (dev) User Story is seeded with, as child
# Tasks in this order. A dev crew adds MORE child Tasks for discovered work via
# add-child; these are just the pre-planned starting set. Space-separated slugs.
FM_ADO_DEFAULT_STAGES="initial-development test review fix-review-findings open-and-babysit-pr"
# The Description carries at most this many characters of composed content; any
# remainder spills to ordered work-item COMMENTS so the full prompt and brief are
# always recoverable from ADO itself (never truncated). Chosen conservatively to
# stay well under BOTH ADO's HTML long-text field limit (~1MB) AND the OS argv
# length limit (the Description is passed as `az --description "$(cat file)"`),
# with generous headroom for HTML-escape expansion. Override in config.
FM_ADO_DEFAULT_DESC_MAX_CHARS=20000
# Each spillover comment carries at most this many characters of content, under
# the same argv/field-limit reasoning applied per `az ... --discussion`. Override
# in config.
FM_ADO_DEFAULT_COMMENT_MAX_CHARS=20000
# A work-item title (System.Title) is a firstmate-generated concise SUMMARY. This
# is a BACKSTOP ceiling only: the primary fix is that firstmate passes a short
# title; the backend clamps here so a verbose title can never slip through. ADO's
# own System.Title hard limit is 255 chars, but the captain wants SHORT titles, so
# the default is a soft ~110 (well under 255, roomy enough for a real summary). The
# clamp cuts on a word boundary and appends a single ellipsis; the full untruncated
# text always lives in the Description, so no information is lost. Override in config.
FM_ADO_DEFAULT_TITLE_MAX_CHARS=110
# Old-model work items to reconcile into the new shape (see fm_ado_migrate_legacy).
# Blank by default: concrete work-item ids are captain-fleet-specific data and are
# not shipped in the shared template. Supply them explicitly to opt into the
# one-off migration, via config/ado-backend.env (FM_ADO_LEGACY_US/TASK/REPO) or
# the migrate verb's --us/--task/--repo flags. With no ids configured, migrate is
# a no-op.
FM_ADO_DEFAULT_LEGACY_US=""
FM_ADO_DEFAULT_LEGACY_TASK=""
FM_ADO_DEFAULT_LEGACY_REPO=""

# fm_ado_config_file <config-dir>
fm_ado_config_file() {
  printf '%s\n' "$1/ado-backend.env"
}

# fm_ado_load_config <config-dir>
# Populate FM_ADO_ORG/PROJECT/TEAM/AREA_PATH/ITERATION from the env file when
# present, falling back to the verified defaults for any unset value. Safe to
# call repeatedly. Sourcing an untrusted file is out of scope: config/ is
# LOCAL, gitignored, and captain-owned.
fm_ado_load_config() {
  local config_dir=$1 env_file
  env_file=$(fm_ado_config_file "$config_dir")
  # Reset so a re-load with a changed/absent file does not keep stale values.
  FM_ADO_ORG=""
  FM_ADO_PROJECT=""
  FM_ADO_TEAM=""
  FM_ADO_AREA_PATH=""
  FM_ADO_ITERATION=""
  FM_ADO_EPIC_TITLE=""
  FM_ADO_STAGES=""
  FM_ADO_DESC_MAX_CHARS=""
  FM_ADO_COMMENT_MAX_CHARS=""
  FM_ADO_TITLE_MAX_CHARS=""
  FM_ADO_LEGACY_US=""
  FM_ADO_LEGACY_TASK=""
  FM_ADO_LEGACY_REPO=""
  if [ -f "$env_file" ]; then
    # shellcheck disable=SC1090
    . "$env_file"
  fi
  : "${FM_ADO_ORG:=$FM_ADO_DEFAULT_ORG}"
  : "${FM_ADO_PROJECT:=$FM_ADO_DEFAULT_PROJECT}"
  : "${FM_ADO_TEAM:=$FM_ADO_DEFAULT_TEAM}"
  : "${FM_ADO_AREA_PATH:=$FM_ADO_DEFAULT_AREA_PATH}"
  : "${FM_ADO_ITERATION:=$FM_ADO_DEFAULT_ITERATION}"
  : "${FM_ADO_EPIC_TITLE:=$FM_ADO_DEFAULT_EPIC_TITLE}"
  : "${FM_ADO_STAGES:=$FM_ADO_DEFAULT_STAGES}"
  : "${FM_ADO_DESC_MAX_CHARS:=$FM_ADO_DEFAULT_DESC_MAX_CHARS}"
  : "${FM_ADO_COMMENT_MAX_CHARS:=$FM_ADO_DEFAULT_COMMENT_MAX_CHARS}"
  : "${FM_ADO_TITLE_MAX_CHARS:=$FM_ADO_DEFAULT_TITLE_MAX_CHARS}"
  : "${FM_ADO_LEGACY_US:=$FM_ADO_DEFAULT_LEGACY_US}"
  : "${FM_ADO_LEGACY_TASK:=$FM_ADO_DEFAULT_LEGACY_TASK}"
  : "${FM_ADO_LEGACY_REPO:=$FM_ADO_DEFAULT_LEGACY_REPO}"
}

# --- readiness probe -------------------------------------------------------
# Reuse the same tooling gate the ADO-origin SCM path uses (see fm-bootstrap.sh
# NEEDS_AZ_AUTH): az present, azure-devops extension installed, account authed.
# Returns 0 when ADO is reachable, non-zero otherwise; the caller decides how to
# degrade (serve cache read-only, surface a diagnostic) - never hard-block.

fm_ado_tooling_state() {
  if ! command -v "${FM_ADO_AZ:-az}" >/dev/null 2>&1; then
    printf '%s\n' missing-az
    return 1
  fi
  if ! fm_ado_az extension show --name azure-devops >/dev/null 2>&1; then
    printf '%s\n' missing-extension
    return 1
  fi
  if ! fm_ado_az account show >/dev/null 2>&1; then
    printf '%s\n' needs-auth
    return 1
  fi
  printf '%s\n' ready
  return 0
}

fm_ado_ready() {
  [ "$(fm_ado_tooling_state)" = ready ]
}

# --- iteration resolution --------------------------------------------------
# Resolve FM_ADO_ITERATION to a concrete iteration path. The @currentIteration
# macro is resolved LIVE from the team's current-timeframe iteration, so tasks
# always land in the rolling MMM sprint. A literal path in config is returned
# verbatim (an explicit override). Echoes the path; non-zero on failure.
#
# `az boards iteration team list --timeframe current` intermittently returns an
# EMPTY list under rapid, back-to-back az invocations (verified 2026-07-14): the
# same second, a raw az call yields valid JSON while the in-function read comes
# back empty, and a retry a moment later succeeds. An empty iteration then makes
# `az boards work-item create` fail TF401347 (Invalid tree name,
# System.IterationPath). Two defenses cover this: (1) a bounded retry-with-backoff
# around the live read, returning the first non-empty path; and (2) a
# process-lifetime cache, FM_ADO_ITER_CACHE, so the primary create and every
# per-stage Task create reuse ONE good
# read instead of each re-resolving through a separately flaky call. A caller
# that resolves once up front and exports FM_ADO_ITER_CACHE (see cmd_add) makes
# every downstream subshell read hit the cache. FM_ADO_ITER_RETRY_ATTEMPTS and
# FM_ADO_ITER_RETRY_SLEEP override the attempt count and per-attempt sleep (tests
# set sleep to 0).

# fm_ado_iter_backoff_sleep <attempt>  -> sleep between retries (best-effort).
fm_ado_iter_backoff_sleep() {
  local attempt=$1 dur
  if [ -n "${FM_ADO_ITER_RETRY_SLEEP:-}" ]; then
    dur=$FM_ADO_ITER_RETRY_SLEEP
  else
    case "$attempt" in
      1) dur=0.2 ;;
      2) dur=0.5 ;;
      *) dur=1 ;;
    esac
  fi
  [ "$dur" = 0 ] && return 0
  sleep "$dur" 2>/dev/null || true
  return 0
}

fm_ado_resolve_iteration() {
  local out path attempt attempts
  # Process-lifetime cache: reuse one good read across the primary and stage creates.
  if [ -n "${FM_ADO_ITER_CACHE:-}" ]; then
    printf '%s\n' "$FM_ADO_ITER_CACHE"
    return 0
  fi
  case "$FM_ADO_ITERATION" in
    @currentIteration|@CurrentIteration|"")
      attempts=${FM_ADO_ITER_RETRY_ATTEMPTS:-4}
      attempt=1
      while [ "$attempt" -le "$attempts" ]; do
        out=$(fm_ado_az boards iteration team list \
          --team "$FM_ADO_TEAM" --project "$FM_ADO_PROJECT" \
          --timeframe current --org "$FM_ADO_ORG" -o json 2>/dev/null) || out=""
        path=$(printf '%s' "$out" | fm_ado_jq -r '.[0].path // empty' 2>/dev/null || true)
        if [ -n "$path" ]; then
          FM_ADO_ITER_CACHE=$path
          printf '%s\n' "$path"
          return 0
        fi
        if [ "$attempt" -lt "$attempts" ]; then
          fm_ado_iter_backoff_sleep "$attempt"
        fi
        attempt=$((attempt + 1))
      done
      return 1
      ;;
    *)
      FM_ADO_ITER_CACHE=$FM_ADO_ITERATION
      printf '%s\n' "$FM_ADO_ITERATION"
      ;;
  esac
}

# The WIQL @currentIteration macro form: '[project]\team'.
fm_ado_current_iteration_macro() {
  printf "@currentIteration('[%s]\\\\%s')" "$FM_ADO_PROJECT" "$FM_ADO_TEAM"
}

# --- submitter identity ----------------------------------------------------
# fm_ado_current_user  -> echo the signed-in submitter's identity (email), or empty.
# `az account show --query user.name` returns exactly the string System.AssignedTo
# accepts, so a fresh work item can be OWNED by whoever created it. Process-lifetime
# cached like FM_ADO_ITER_CACHE (FM_ADO_USER_RESOLVED marks that the one az read has
# happened, so a degraded-auth miss is not re-probed or re-warned per create).
# Returns 0 with a non-empty identity on success. On a degraded-auth miss it warns
# ONCE to stderr and returns 1 with empty output, so the caller creates the work
# item UNASSIGNED rather than failing: assignment is an enhancement, never a gate.
fm_ado_current_user() {
  if [ -n "${FM_ADO_USER_RESOLVED:-}" ]; then
    [ -n "${FM_ADO_USER_CACHE:-}" ] || return 1
    printf '%s\n' "$FM_ADO_USER_CACHE"
    return 0
  fi
  local user
  user=$(fm_ado_az account show --query user.name -o tsv 2>/dev/null | tr -d '[:space:]') || user=""
  FM_ADO_USER_RESOLVED=1
  FM_ADO_USER_CACHE=$user
  if [ -z "$user" ]; then
    echo "fm-ado-lib: warning: could not resolve submitter identity (az account show); creating work item unassigned" >&2
    return 1
  fi
  printf '%s\n' "$user"
}

# fm_ado_assign_args  -> echo the --assigned-to flag pair (one arg per line) for the
# current submitter, or nothing on a soft-fail miss. Callers read it into an array
# and splice it into `az boards work-item create` so a resolved submitter owns the
# new item and an unresolved one leaves it unassigned. Kept as a helper so every
# create path composes the assignee identically.
fm_ado_assign_args() {
  local user
  user=$(fm_ado_current_user) || return 0
  printf '%s\n%s\n' --assigned-to "$user"
}

# --- jq seam ---------------------------------------------------------------
fm_ado_jq() {
  "${FM_ADO_JQ:-jq}" "$@"
}

fm_ado_has_jq() {
  command -v "${FM_ADO_JQ:-jq}" >/dev/null 2>&1
}

# fm_ado_extract_id  -> read a work-item-create/show JSON blob on stdin and echo
# its numeric .id, robustly. This is the CREATE-GLITCH root-cause fix: the create
# `az` call reliably CREATES the work item, but its stdout is occasionally
# contaminated (an az preview/warning banner prepended to the JSON, or a slow
# flush) so a plain `jq -r '.id'` parse fails NON-zero even though the WI exists.
# The old code let that parse failure propagate as "create-or-reuse failed", the
# caller retried, and the retry created a DUPLICATE. Here we (1) try strict jq on
# the whole blob, then (2) a last-resort regex for the first `"id": <n>` field - so
# a real, created WI's id is recovered from banner-contaminated output instead of
# being dropped. (A per-line jq pass is deliberately NOT used: jq errors on the
# first non-JSON banner token and never reaches the trailing JSON, so it fails in
# exactly the cases strict jq already fails; the regex covers those instead.)
fm_ado_extract_id() {
  local blob id
  blob=$(cat)
  id=$(printf '%s' "$blob" | fm_ado_jq -r '.id // empty' 2>/dev/null || true)
  if [ -z "$id" ]; then
    # Last resort: pull the first "id": <digits> out of the raw text.
    id=$(printf '%s' "$blob" | grep -oE '"id"[[:space:]]*:[[:space:]]*[0-9]+' | head -n1 \
      | grep -oE '[0-9]+' | head -n1 || true)
  fi
  printf '%s' "$id"
}

# --- sourced sub-libraries -------------------------------------------------
# The homegrown work-item cache layer and the HTML/description/comment
# composition layer are split into sibling libraries to keep each cohesive and
# shrink the merge-conflict surface as ADO work continues. Both are sourced here
# so every existing caller that sources ONLY fm-ado-lib.sh gets the full set of
# fm_ado_* helpers with no change. Function names and signatures are unchanged;
# this is a pure structural split. The core below still owns the az/config/jq
# plumbing and the Epic/primary/stage-task hierarchy state machine those helpers
# and callers depend on (all resolved at call time, so load order is safe).
_fm_ado_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-ado-cache-lib.sh disable=SC1091
. "$_fm_ado_lib_dir/fm-ado-cache-lib.sh"
# shellcheck source=bin/fm-ado-compose-lib.sh disable=SC1091
. "$_fm_ado_lib_dir/fm-ado-compose-lib.sh"
unset _fm_ado_lib_dir


# --- work-item field helpers ----------------------------------------------
# fm_ado_wi_field <wi> <field>  -> echo field value (live read)
fm_ado_wi_field() {
  local wi=$1 field=$2 out
  out=$(fm_ado_az boards work-item show --id "$wi" --org "$FM_ADO_ORG" -o json 2>/dev/null) || return 1
  printf '%s' "$out" | fm_ado_jq -r --arg f "$field" '.fields[$f] // empty' 2>/dev/null
}

# fm_ado_wi_rev <wi>  -> echo System.Rev
fm_ado_wi_rev() {
  fm_ado_wi_field "$1" System.Rev
}

# fm_ado_set_iteration <wi> <iteration-path>  -> reparent a WI to an iteration.
# Idempotent: setting the path a WI already has is a no-op on ADO's side.
fm_ado_set_iteration() {
  fm_ado_az boards work-item update --id "$1" --iteration "$2" \
    --org "$FM_ADO_ORG" -o json >/dev/null 2>&1
}

# fm_ado_team_iterations  -> echo the team's full iteration list JSON (all
# timeframes, each with attributes.startDate/finishDate). Used to establish
# whether one iteration ends before another begins.
fm_ado_team_iterations() {
  fm_ado_az boards iteration team list \
    --team "$FM_ADO_TEAM" --project "$FM_ADO_PROJECT" \
    --org "$FM_ADO_ORG" -o json 2>/dev/null
}

# fm_ado_iteration_is_older <task-iterpath> <current-iterpath> [<iterations-json>]
# 0 iff the task's iteration ends strictly before the current iteration begins,
# i.e. the task sits in a genuinely PAST sprint. Conservative: identical paths,
# a list read failure, or a missing start/finish date all yield non-zero (not
# older), so a current or future-placed work item is never pulled forward.
# <iterations-json>, when given, is a prior fm_ado_team_iterations read reused in
# place of another list call, so a caller looping over many candidates fetches the
# loop-invariant iteration list once instead of once per candidate.
fm_ado_iteration_is_older() {
  local task=$1 cur=$2 iters=${3:-} out finish start
  [ "$task" != "$cur" ] || return 1
  if [ -n "$iters" ]; then
    out=$iters
  else
    out=$(fm_ado_team_iterations) || return 1
  fi
  finish=$(printf '%s' "$out" | fm_ado_jq -r --arg p "$task" \
    'first(.[] | select(.path == $p)) | .attributes.finishDate // empty' 2>/dev/null) || return 1
  start=$(printf '%s' "$out" | fm_ado_jq -r --arg p "$cur" \
    'first(.[] | select(.path == $p)) | .attributes.startDate // empty' 2>/dev/null) || return 1
  [ -n "$finish" ] && [ -n "$start" ] || return 1
  # ISO 8601 UTC timestamps compare correctly as strings.
  [[ "$finish" < "$start" ]]
}

# --- verify-after-write (read-back validation) -----------------------------
# CAPTAIN POLICY: after EVERY ADO write, a follow-up GET must confirm the write
# persisted as intended before it is treated as done. ADO is the backlog source
# of truth; losing state is unacceptable. A write that "succeeded" on the CLI but
# did not persist (the known intermittent create glitch), or a retry that
# duplicated, MUST be caught here and surfaced as a HARD error the caller sees -
# never a silent pass. Read-back is authoritative: every check below compares
# against what ADO actually returns from a fresh work-item show, NOT the local
# cache, and the caller refreshes the cache from this verified read.
#
# Efficiency: a verb does ONE read-back GET (fm_ado_read_back_rel returns fields
# AND relations in a single show) and runs several pure checks against that one
# JSON blob, so verify adds at most one round-trip per write op.

# fm_ado_read_back <wi>  -> echo the live show JSON (fields only). Non-zero when
# the WI is unreadable or absent - itself a verification failure the caller
# treats as "the write did not persist".
fm_ado_read_back() {
  fm_ado_az boards work-item show --id "$1" --org "$FM_ADO_ORG" -o json 2>/dev/null
}

# fm_ado_read_back_rel <wi>  -> echo the live show JSON WITH relations expanded
# (fields AND relations), so a verb needing both parent/predecessor links and
# field values reads back in one GET.
fm_ado_read_back_rel() {
  fm_ado_az boards work-item show --id "$1" --expand relations --org "$FM_ADO_ORG" -o json 2>/dev/null
}

# fm_ado_check_exists <json>  -> 0 iff the read-back JSON carries a numeric id
# (the WI genuinely exists in ADO). An empty/garbage read-back fails.
fm_ado_check_exists() {
  local id
  id=$(printf '%s' "$1" | fm_ado_jq -r '.id // empty' 2>/dev/null)
  [ -n "$id" ]
}

# fm_ado_check_field <json> <field> <expected>  -> 0 iff .fields[field] == expected.
fm_ado_check_field() {
  local got
  got=$(printf '%s' "$1" | fm_ado_jq -r --arg f "$2" '.fields[$f] // empty' 2>/dev/null)
  [ "$got" = "$3" ]
}

# fm_ado_check_state <json> <expected-state>  -> 0 iff System.State == expected.
fm_ado_check_state() {
  fm_ado_check_field "$1" System.State "$2"
}

# fm_ado_check_tags_contain <json> <substr>  -> 0 iff System.Tags contains substr.
fm_ado_check_tags_contain() {
  local tags
  tags=$(printf '%s' "$1" | fm_ado_jq -r '.fields["System.Tags"] // empty' 2>/dev/null)
  case "$tags" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_ado_check_parent <json> <parent-wi>  -> 0 iff the WI's Hierarchy-Reverse
# (parent) relation points at <parent-wi>. Requires a relations-expanded read-back.
fm_ado_check_parent() {
  local got
  got=$(printf '%s' "$1" | fm_ado_jq -r \
    'first(.relations[]? | select(.rel=="System.LinkTypes.Hierarchy-Reverse") | .url | split("/") | last) // empty' \
    2>/dev/null)
  [ "$got" = "$2" ]
}

# fm_ado_check_predecessor <json> <blocker-wi>  -> 0 iff a Dependency-Reverse
# (Predecessor) relation to <blocker-wi> is present. Requires a rel read-back.
fm_ado_check_predecessor() {
  local hit
  hit=$(printf '%s' "$1" | fm_ado_jq -r --arg b "$2" \
    'any(.relations[]? | select(.rel=="System.LinkTypes.Dependency-Reverse") | (.url | split("/") | last); . == $b)' \
    2>/dev/null)
  [ "$hit" = true ]
}

# fm_ado_check_no_predecessor <json> <blocker-wi>  -> 0 iff NO Dependency-Reverse
# (Predecessor) relation to <blocker-wi> remains (the unblock read-back invariant).
fm_ado_check_no_predecessor() {
  fm_ado_check_predecessor "$1" "$2" && return 1
  return 0
}

# fm_ado_check_desc_nonempty <json>  -> 0 iff the read-back System.Description is
# non-empty. The update read-back gate is rev-not-regress (in cmd_update) PLUS a
# non-empty Description: ADO normalizes stored HTML (entity re-encoding, attribute
# reordering, whitespace reflow), so a byte/whitespace containment check against the
# written body produces false "did not persist" failures even when the write landed.
# What genuine data loss looks like instead is an EMPTY Description, which this
# catches. An idempotent re-run with an identical body is a no-op on ADO's side that
# leaves the Description present and System.Rev unchanged - it must PASS.
fm_ado_check_desc_nonempty() {
  local got
  got=$(printf '%s' "$1" | fm_ado_jq -r '.fields["System.Description"] // empty' 2>/dev/null)
  [ -n "$got" ]
}

# fm_ado_primary_ids_exact <fm-id> <wi-type>  -> echo the WI id (one per line) of
# every <wi-type> under the configured area path whose System.Tags carries the
# EXACT `fm-id:<id>` tag element. Returns non-zero on a query FAILURE (so callers
# can distinguish "no match" from "could not ask ADO"). The WIQL keeps the cheap
# `CONTAINS 'fm-id:$id'` as a coarse pre-filter, but that is a substring match that
# aliases prefix-sibling ids (`fm-id:fix-login` matches `fm-id:fix-login-k3`), so
# the result is post-filtered in jq for an EXACT tag-element match: split
# System.Tags on ';', trim whitespace, keep only rows with an element equal to
# `fm-id:<id>`. Selecting [System.Tags] alongside [System.Id] is what makes the
# post-filter possible (real ADO returns the selected columns under .fields).
fm_ado_primary_ids_exact() {
  local id=$1 wtype=$2 out
  out=$(fm_ado_az boards query --org "$FM_ADO_ORG" --project "$FM_ADO_PROJECT" --wiql \
    "SELECT [System.Id], [System.Tags] FROM WorkItems WHERE [System.TeamProject]='$FM_ADO_PROJECT' AND [System.WorkItemType]='$wtype' AND [System.Tags] CONTAINS 'fm-id:$id' AND [System.AreaPath] UNDER '$FM_ADO_AREA_PATH'" \
    -o json 2>/dev/null) || return 1
  printf '%s' "$out" | fm_ado_jq -r --arg id "$id" '
    .[]
    | select(
        ((.fields["System.Tags"] // "") | split(";") | map(gsub("^\\s+|\\s+$";"")))
        | any(. == "fm-id:\($id)")
      )
    | .id
  ' 2>/dev/null
}

# fm_ado_count_primary <fm-id> <wi-type>  -> echo how many work items of <wi-type>
# under the configured area path carry the EXACT fm-id:<id> tag. Used to detect the
# duplicate-WI symptom of the create glitch: a partial/retried create leaves >1.
# WIQL is eventually consistent, so a just-created duplicate may not both show up
# instantly; this catches duplicates that HAVE become visible (best-effort, never
# a false alarm). Echoes 0 on a query failure (cannot prove a duplicate).
fm_ado_count_primary() {
  local id=$1 wtype=$2 ids
  ids=$(fm_ado_primary_ids_exact "$id" "$wtype") || { printf '0\n'; return 0; }
  printf '%s\n' "$(printf '%s' "$ids" | grep -c '[0-9]')"
}

# --- state mapping ---------------------------------------------------------
# firstmate placement -> ADO System.State.
fm_ado_state_for_placement() {
  case "$1" in
    inflight|in-flight|active|start) printf '%s\n' Active ;;
    done|closed) printf '%s\n' Closed ;;
    *) printf '%s\n' New ;;   # queued
  esac
}


# --- Epic create-or-reuse --------------------------------------------------
# One standing Epic per fleet, titled by FM_ADO_EPIC_TITLE (default
# davidkydd-firstmate), tagged fm-managed, under the configured area path and
# iteration. Every primary work item parents to it.

# fm_ado_find_epic <data-dir>  -> echo existing Epic WI id or empty
# Cache first, then a live WIQL title match under the configured area path.
fm_ado_find_epic() {
  local data_dir=$1 cached out
  cached=$(fm_ado_cache_get_epic "$data_dir" 2>/dev/null || true)
  if [ -n "$cached" ]; then
    printf '%s\n' "$cached"
    return 0
  fi
  out=$(fm_ado_az boards query --org "$FM_ADO_ORG" --project "$FM_ADO_PROJECT" --wiql \
    "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject]='$FM_ADO_PROJECT' AND [System.WorkItemType]='Epic' AND [System.Title]='$FM_ADO_EPIC_TITLE' AND [System.AreaPath] UNDER '$FM_ADO_AREA_PATH'" \
    -o json 2>/dev/null) || return 1
  printf '%s' "$out" | fm_ado_jq -r 'first(.[].id) // empty' 2>/dev/null
}

# fm_ado_create_epic  -> echo new Epic WI id
fm_ado_create_epic() {
  local iter out
  iter=$(fm_ado_resolve_iteration) || return 1
  out=$(fm_ado_az boards work-item create \
    --title "$FM_ADO_EPIC_TITLE" --type "Epic" \
    --project "$FM_ADO_PROJECT" --org "$FM_ADO_ORG" \
    --area "$FM_ADO_AREA_PATH" --iteration "$iter" \
    --fields "System.Tags=fm-managed" \
    -o json 2>/dev/null) || return 1
  printf '%s' "$out" | fm_ado_extract_id
}

# fm_ado_ensure_epic <data-dir>  -> echo Epic WI id (create-or-reuse, cached)
fm_ado_ensure_epic() {
  local data_dir=$1 wi
  wi=$(fm_ado_find_epic "$data_dir" 2>/dev/null || true)
  if [ -z "$wi" ]; then
    wi=$(fm_ado_create_epic) || return 1
  fi
  [ -n "$wi" ] || return 1
  fm_ado_cache_put_epic "$data_dir" "$wi" 2>/dev/null || true
  printf '%s\n' "$wi"
}

# fm_ado_wi_parent <wi>  -> echo the WI id of the work item's parent, or empty.
# Reads the Hierarchy-Reverse relation from an expanded work-item show.
fm_ado_wi_parent() {
  local wi=$1 out
  out=$(fm_ado_az boards work-item show --id "$wi" --expand relations \
    --org "$FM_ADO_ORG" -o json 2>/dev/null) || return 1
  printf '%s' "$out" | fm_ado_jq -r \
    'first(.relations[]? | select(.rel=="System.LinkTypes.Hierarchy-Reverse") | .url | split("/") | last) // empty' \
    2>/dev/null
}

# fm_ado_link_parent <child-wi> <parent-wi>
# Add the parent link directly, without the fm_ado_wi_parent read. Use only on a
# just-created child, which provably has no parent yet, so the read would always
# miss and fall through to this same link add; setting a parent is a harmless
# no-op on ADO's side when it already matches.
fm_ado_link_parent() {
  local child=$1 parent=$2
  fm_ado_az boards work-item relation add \
    --id "$child" --relation-type parent --target-id "$parent" \
    --org "$FM_ADO_ORG" -o json >/dev/null 2>&1
}

# fm_ado_ensure_parent <child-wi> <parent-wi>
# Ensure the child work item's parent is <parent-wi>. Idempotent: an
# already-correctly-parented child is left untouched (no relation write); an
# unparented child gets a parent link added, and setting the same parent again is
# a harmless no-op on ADO's side, so an unreadable parent read falls through to a
# link add. Only the unparented case actually heals: ADO enforces a single
# parent, so `relation add` would fail (silently, via the swallowed error) for a
# child that already has a DIFFERENT parent. firstmate never mis-parents. Reserve
# this for reuse paths; a freshly created child should call fm_ado_link_parent to
# skip the guaranteed-miss parent read.
fm_ado_ensure_parent() {
  local child=$1 parent=$2 current
  current=$(fm_ado_wi_parent "$child" 2>/dev/null || true)
  [ "$current" != "$parent" ] || return 0
  fm_ado_link_parent "$child" "$parent"
}

# --- title clamp (backstop) ------------------------------------------------
# firstmate (the caller) is expected to pass a genuinely concise SUMMARY as the
# title. This is a deterministic BACKSTOP so a verbose title can never slip
# through to System.Title: it clamps the title to FM_ADO_TITLE_MAX_CHARS
# characters on a WORD boundary (never mid-word) and appends a single ellipsis
# when it clamped. The full untruncated text always lives in the Description, so
# no information is lost. The shell cannot summarize; it only enforces the ceiling.

# fm_ado_title_budget  -> the title character ceiling.
fm_ado_title_budget() {
  printf '%s\n' "${FM_ADO_TITLE_MAX_CHARS:-$FM_ADO_DEFAULT_TITLE_MAX_CHARS}"
}

# fm_ado_clamp_title <title>  -> echo the title, clamped to the ceiling.
# A title at or under the ceiling is echoed verbatim. A longer one is cut to the
# ceiling, backed off to the last word boundary (the trailing partial word is
# dropped; a single unbreakable word longer than the ceiling is hard-cut at it),
# and a single ellipsis char is appended to mark the truncation.
fm_ado_clamp_title() {
  local title=$1 budget head clamped
  budget=$(fm_ado_title_budget)
  # Non-positive budget disables the clamp (defensive; config never sets this).
  if [ "$budget" -le 0 ] || [ "${#title}" -le "$budget" ]; then
    printf '%s\n' "$title"
    return 0
  fi
  head=${title:0:budget}
  # Drop the last (partial) word at a space boundary. `${head% *}` removes the
  # last space and everything after it; when the head has no space (one giant
  # word) it is unchanged, so a lone oversized token is hard-cut at the ceiling.
  clamped=${head% *}
  [ -n "$clamped" ] || clamped=$head
  printf '%s…\n' "$clamped"
}


# The primary work item for a firstmate backlog item is KIND-AWARE:
#   ship          -> a User Story directly under the Epic, seeded with per-stage
#                    child Tasks; a dev crew adds more child Tasks for discovered
#                    work via fm_ado_add_child_task.
#   scout, review -> a single Task directly under the Epic (no User Story).
# In both cases the primary WI carries fm-managed, fm-repo:<repo>, fm-id:<fm-id>,
# fm-kind:<kind>, so the fm-id tag round-trips to the firstmate id even if the
# cache is lost, and the Description (composed by fm_ado_compose_description) is
# the durable full record.

# The valid firstmate kinds, and the single owner of that set. Both the `add`
# validator and the `ready` WIQL kind filter derive from this so they can never
# drift (a new kind here reaches both at once).
FM_ADO_KINDS="ship scout review"

# fm_ado_item_tags <fm-id> <repo> <kind>  -> the semicolon-separated tag string.
fm_ado_item_tags() {
  printf 'fm-managed; fm-repo:%s; fm-id:%s; fm-kind:%s\n' "$2" "$1" "$3"
}

# fm_ado_kind_is_valid <kind>  -> 0 if <kind> is one of FM_ADO_KINDS.
fm_ado_kind_is_valid() {
  local k
  for k in $FM_ADO_KINDS; do [ "$1" = "$k" ] && return 0; done
  return 1
}

# fm_ado_ready_kind_clause  -> a parenthesized WIQL predicate matching any primary
# by its fm-kind:<kind> tag, e.g.
#   ([System.Tags] CONTAINS 'fm-kind:ship' OR ... CONTAINS 'fm-kind:review')
# ADO's [System.Tags] CONTAINS matches a WHOLE tag value, not a substring, so a
# bare `CONTAINS 'fm-kind:'` (no value) matches ZERO items - that was the
# always-empty `ready` bug. Every primary carries exactly one concrete fm-kind:
# tag, so the disjunction over the known kinds is the correct whole-value match.
fm_ado_ready_kind_clause() {
  local k out=""
  for k in $FM_ADO_KINDS; do
    if [ -n "$out" ]; then
      out="$out OR [System.Tags] CONTAINS 'fm-kind:$k'"
    else
      out="[System.Tags] CONTAINS 'fm-kind:$k'"
    fi
  done
  printf '(%s)\n' "$out"
}

# fm_ado_primary_type <kind>  -> the ADO work-item type for a kind's primary WI.
fm_ado_primary_type() {
  case "$1" in
    ship) printf '%s\n' "User Story" ;;
    *) printf '%s\n' "Task" ;;   # scout, review: a single Task
  esac
}

# fm_ado_find_primary <data-dir> <fm-id> <wi-type>  -> echo existing primary WI id
# Cache first (items[fm-id].wi), then a live WIQL match on the fm-id tag for the
# given work-item type under the configured area path. The tag match lets a lost
# cache recover.
fm_ado_find_primary() {
  local data_dir=$1 id=$2 wtype=$3 cached
  cached=$(fm_ado_cache_get_wi "$data_dir" "$id" 2>/dev/null || true)
  if [ -n "$cached" ]; then
    printf '%s\n' "$cached"
    return 0
  fi
  fm_ado_find_primary_live "$id" "$wtype"
}

# fm_ado_create_primary <fm-id> <title> <repo> <kind> [<desc-file>]  -> echo new WI id
# Creates the kind-appropriate primary WI with the summary title, tags, and (when
# a non-empty description file is given) the composed HTML Description.
fm_ado_create_primary() {
  local id=$1 title=$2 repo=$3 kind=$4 desc_file=${5:-} iter tags wtype out
  iter=$(fm_ado_resolve_iteration) || return 1
  tags=$(fm_ado_item_tags "$id" "$repo" "$kind")
  wtype=$(fm_ado_primary_type "$kind")
  title=$(fm_ado_clamp_title "$title")   # backstop: a verbose title can never slip through
  local desc_args=()
  if [ -n "$desc_file" ] && [ -f "$desc_file" ]; then
    desc_args=(--description "$(cat "$desc_file")")
  fi
  # Auto-assign the new item to the signed-in submitter; a soft-fail miss leaves
  # assign_args empty so the create still succeeds unassigned (see fm_ado_current_user).
  local assign_args=() line
  while IFS= read -r line; do assign_args+=("$line"); done < <(fm_ado_assign_args)
  out=$(fm_ado_az boards work-item create \
    --title "$title" --type "$wtype" \
    --project "$FM_ADO_PROJECT" --org "$FM_ADO_ORG" \
    --area "$FM_ADO_AREA_PATH" --iteration "$iter" \
    ${assign_args[@]+"${assign_args[@]}"} \
    ${desc_args[@]+"${desc_args[@]}"} \
    --fields "System.Tags=$tags" \
    -o json 2>/dev/null) || return 1
  printf '%s' "$out" | fm_ado_extract_id
}

# fm_ado_ensure_primary <data-dir> <fm-id> <title> <repo> <kind> [<desc-file>] [<created-flag-file>]
#   -> echo primary WI id
# Create-or-reuse the kind-appropriate primary WI, ensure the standing Epic
# exists, and parent the WI to it. Idempotent and self-healing: a newly created
# WI and an existing-but-unparented WI alike end up under the Epic, while an
# already-correctly-parented WI is left untouched. A fresh create gets the
# composed Description; the reuse path NEVER rewrites the existing Description -
# the original prompt is durable, and a follow-up prompt accumulates via
# cmd_add's append-or-comment path, so ensure_primary itself is Description-safe.
# When <created-flag-file> is given, "1" is written to it if the WI was created
# fresh this call and "0" otherwise, so a command-substitution caller can learn
# whether the primary is brand new (its per-stage find can then be skipped).
# fm_ado_recover_primary <fm-id> <wi-type>  -> echo a recovered primary WI id or
# empty. Used only when a create returned no id but may have created the WI (the
# glitch): a bounded retry-with-backoff WIQL match on the fm-id tag lets ADO's
# eventually-consistent index catch up before we conclude the create truly failed.
# Reuses the iteration resolver's backoff schedule and its retry knobs.
fm_ado_recover_primary() {
  local id=$1 wtype=$2 attempt attempts wi
  attempts=${FM_ADO_ITER_RETRY_ATTEMPTS:-4}
  attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    wi=$(fm_ado_find_primary_live "$id" "$wtype" 2>/dev/null || true)
    if [ -n "$wi" ]; then
      printf '%s\n' "$wi"
      return 0
    fi
    [ "$attempt" -lt "$attempts" ] && fm_ado_iter_backoff_sleep "$attempt"
    attempt=$((attempt + 1))
  done
  return 1
}

# fm_ado_find_primary_live <fm-id> <wi-type>  -> echo the primary WI id from a LIVE
# WIQL tag match (no cache), or empty. The cache-bypassing half of fm_ado_find_primary,
# so recovery always hits ADO even when the cache is populated with a stale/missing row.
# Delegates to fm_ado_primary_ids_exact (exact fm-id tag-element match, not a
# substring alias) and returns the first match; a query FAILURE propagates as a
# non-zero exit so fm_ado_ensure_primary skips create on a lookup failure.
fm_ado_find_primary_live() {
  local id=$1 wtype=$2 ids
  ids=$(fm_ado_primary_ids_exact "$id" "$wtype") || return 1
  printf '%s' "$ids" | grep -m1 '[0-9]' || true
}

fm_ado_ensure_primary() {
  local data_dir=$1 id=$2 title=$3 repo=$4 kind=$5 desc_file=${6:-} created_file=${7:-} wi epic wtype created=0
  wtype=$(fm_ado_primary_type "$kind")
  if ! wi=$(fm_ado_find_primary "$data_dir" "$id" "$wtype" 2>/dev/null); then
    echo "fm-ado-lib: warning: primary lookup for $id failed; skipping create to avoid duplicate primary" >&2
    return 1
  fi
  if [ -z "$wi" ]; then
    wi=$(fm_ado_create_primary "$id" "$title" "$repo" "$kind" "$desc_file") || wi=""
    if [ -z "$wi" ]; then
      # CREATE GLITCH RECOVERY: the create `az` call may have CREATED the WI in
      # ADO yet returned an unparseable/empty id (contaminated stdout). Rather than
      # fail here - which makes the caller retry and create a DUPLICATE - try to
      # recover the just-created WI by its fm-id tag (bounded retry for WIQL's
      # eventual consistency). Only give up when recovery also finds nothing.
      wi=$(fm_ado_recover_primary "$id" "$wtype")
      [ -n "$wi" ] || return 1
    fi
    created=1
  fi
  [ -n "$created_file" ] && printf '%s' "$created" > "$created_file" 2>/dev/null
  [ -n "$wi" ] || return 1
  epic=$(fm_ado_ensure_epic "$data_dir" 2>/dev/null || true)
  if [ -n "$epic" ]; then
    if [ "$created" = 1 ]; then
      fm_ado_link_parent "$wi" "$epic" || true
    else
      fm_ado_ensure_parent "$wi" "$epic" || true
    fi
  fi
  printf '%s\n' "$wi"
}

# --- ship per-stage child Tasks --------------------------------------------
# A ship User Story is seeded with one child Task per lifecycle STAGE (the
# FM_ADO_STAGES list, in order). Each stage Task is tagged fm-managed, fm-id:<id>,
# fm-stage:<stage>, so it round-trips and is reused (never duplicated) on re-add.
# A dev crew adds MORE child Tasks for work it discovers via fm_ado_add_child_task.

# fm_ado_stage_tags <fm-id> <stage>  -> the semicolon-separated tag string.
fm_ado_stage_tags() {
  printf 'fm-managed; fm-id:%s; fm-stage:%s\n' "$1" "$2"
}

# fm_ado_find_stage_tasks <fm-id>  -> echo one "stage<TAB>wi<TAB>parent" line per
# existing stage Task, in a SINGLE WIQL round-trip. Selecting Tags and Parent
# lets the plural reconcile decide reuse-vs-create AND parent drift in-memory,
# so a fully-existing Story costs one query instead of one find + one parent read
# per stage. Tasks with no fm-stage: tag (discovered work) are skipped.
fm_ado_find_stage_tasks() {
  local id=$1 out
  out=$(fm_ado_az boards query --org "$FM_ADO_ORG" --project "$FM_ADO_PROJECT" --wiql \
    "SELECT [System.Id], [System.Tags], [System.Parent] FROM WorkItems WHERE [System.TeamProject]='$FM_ADO_PROJECT' AND [System.WorkItemType]='Task' AND [System.Tags] CONTAINS 'fm-id:$id' AND [System.Tags] CONTAINS 'fm-stage:' AND [System.AreaPath] UNDER '$FM_ADO_AREA_PATH'" \
    -o json 2>/dev/null) || return 1
  printf '%s' "$out" | fm_ado_jq -r '
    .[] | [ (.fields["System.Tags"] // ""), (.id|tostring), (.fields["System.Parent"] // "" | tostring) ] | @tsv
  ' 2>/dev/null
}

# fm_ado_find_stage_task <fm-id> <stage>  -> echo existing stage Task WI or empty
# WIQL match on the fm-id + fm-stage tags under the area path (recovers after a
# cache loss so re-dispatch never adds a duplicate stage Task).
fm_ado_find_stage_task() {
  local id=$1 stage=$2 out
  out=$(fm_ado_az boards query --org "$FM_ADO_ORG" --project "$FM_ADO_PROJECT" --wiql \
    "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject]='$FM_ADO_PROJECT' AND [System.WorkItemType]='Task' AND [System.Tags] CONTAINS 'fm-id:$id' AND [System.Tags] CONTAINS 'fm-stage:$stage' AND [System.AreaPath] UNDER '$FM_ADO_AREA_PATH'" \
    -o json 2>/dev/null) || return 1
  printf '%s' "$out" | fm_ado_jq -r 'first(.[].id) // empty' 2>/dev/null
}

# fm_ado_create_task_wi <title> <tags> <parent-wi>  -> echo new Task WI
# Create a Task under the configured area/iteration with the given title and tag
# string, then link it directly to <parent-wi> (a just-created child provably has
# no parent yet, so the guaranteed-miss parent read is skipped).
fm_ado_create_task_wi() {
  local title=$1 tags=$2 parent=$3 iter out wi
  iter=$(fm_ado_resolve_iteration) || return 1
  title=$(fm_ado_clamp_title "$title")   # backstop: same ceiling as the primary WI
  # Auto-assign the new Task to the signed-in submitter; a soft-fail miss leaves
  # assign_args empty so the create still succeeds unassigned (see fm_ado_current_user).
  local assign_args=() line
  while IFS= read -r line; do assign_args+=("$line"); done < <(fm_ado_assign_args)
  out=$(fm_ado_az boards work-item create \
    --title "$title" --type "Task" \
    --project "$FM_ADO_PROJECT" --org "$FM_ADO_ORG" \
    --area "$FM_ADO_AREA_PATH" --iteration "$iter" \
    ${assign_args[@]+"${assign_args[@]}"} \
    --fields "System.Tags=$tags" \
    -o json 2>/dev/null) || return 1
  wi=$(printf '%s' "$out" | fm_ado_extract_id)
  [ -n "$wi" ] || return 1
  fm_ado_link_parent "$wi" "$parent" || true
  printf '%s\n' "$wi"
}

# fm_ado_create_stage_task <fm-id> <story-wi> <stage> [<title>]  -> echo new stage Task WI
# The Task title defaults to the stage slug; pass <title> to label a discovered
# stage-keyed Task with descriptive text instead. Always a fresh create, so it
# links the parent directly (no guaranteed-miss parent read).
fm_ado_create_stage_task() {
  local id=$1 story=$2 stage=$3 title=${4:-$3}
  fm_ado_create_task_wi "$title" "$(fm_ado_stage_tags "$id" "$stage")" "$story"
}

# fm_ado_ensure_stage_task <fm-id> <story-wi> <stage> [<story-fresh>] [<title>]  -> echo stage Task WI
# Idempotent: a stage Task discoverable by its fm-id + fm-stage tags is reused
# (re-parented if it drifted); only a genuinely absent one is created. When
# <story-fresh> is 1 the Story was just created this invocation, so no stage Task
# can pre-exist and the WIQL find is skipped straight to create. <title> labels a
# freshly created Task; it defaults to the stage slug.
fm_ado_ensure_stage_task() {
  local id=$1 story=$2 stage=$3 fresh=${4:-0} title=${5:-$3} wi
  if [ "$fresh" = 1 ]; then
    wi=""
  else
    wi=$(fm_ado_find_stage_task "$id" "$stage") || return 1
  fi
  if [ -z "$wi" ]; then
    wi=$(fm_ado_create_stage_task "$id" "$story" "$stage" "$title") || return 1
  else
    fm_ado_ensure_parent "$wi" "$story" || true
  fi
  [ -n "$wi" ] || return 1
  printf '%s\n' "$wi"
}

# fm_ado_ensure_stage_tasks <fm-id> <story-wi> [<story-fresh>]  -> create-or-reuse
# each configured stage Task under the Story, in FM_ADO_STAGES order. Echoes each
# stage's WI id. When <story-fresh> is 1 the Story was just created this
# invocation, so each stage is created directly with no pre-existence lookup. On
# the reuse path a SINGLE batch WIQL (fm_ado_find_stage_tasks) maps every existing
# stage Task and its parent, so reconciliation is one round-trip for the whole
# Story instead of a per-stage find plus a per-stage parent read.
fm_ado_ensure_stage_tasks() {
  local id=$1 story=$2 fresh=${3:-0} stage s_stage s_wi s_parent existing="" parents="" found
  if [ "$fresh" != 1 ]; then
    if ! found=$(fm_ado_find_stage_tasks "$id" 2>/dev/null); then
      echo "fm-ado-lib: warning: stage-Task lookup for $id failed; skipping seed to avoid duplicate stage Tasks" >&2
      return 1
    fi
    while IFS=$'\t' read -r s_stage s_wi s_parent; do
      [ -n "$s_wi" ] || continue
      s_stage=$(printf '%s' "$s_stage" | sed -n 's/.*fm-stage:\([A-Za-z0-9._-]*\).*/\1/p')
      [ -n "$s_stage" ] || continue
      existing="$existing$s_stage=$s_wi
"
      parents="$parents$s_wi=$s_parent
"
    done <<EOF
$found
EOF
  fi
  for stage in $FM_ADO_STAGES; do
    local wi=""
    if [ "$fresh" != 1 ]; then
      wi=$(printf '%s' "$existing" | sed -n "s/^$stage=//p" | head -n1)
    fi
    if [ -z "$wi" ]; then
      wi=$(fm_ado_create_stage_task "$id" "$story" "$stage") \
        || { echo "fm-ado-lib: warning: could not ensure stage Task '$stage' for $id" >&2; continue; }
    else
      local cur
      cur=$(printf '%s' "$parents" | sed -n "s/^$wi=//p" | head -n1)
      [ "$cur" = "$story" ] || fm_ado_link_parent "$wi" "$story" || true
    fi
    printf '%s\n' "$wi"
  done
}

# fm_ado_add_child_task <fm-id> <story-wi> <title> [<stage>]  -> echo child Task WI
# Add a discovered-work child Task under a ship User Story. Tagged fm-managed and
# fm-id:<id>, plus fm-stage:<stage> when a stage slug is given. With a stage the
# add is idempotent (reuse by the fm-id + fm-stage tags); a stageless discovered
# task is genuinely new work and is always created.
fm_ado_add_child_task() {
  local id=$1 story=$2 title=$3 stage=${4:-}
  if [ -n "$stage" ]; then
    fm_ado_ensure_stage_task "$id" "$story" "$stage" 0 "$title"
    return
  fi
  fm_ado_create_task_wi "$title" "fm-managed; fm-id:$id" "$story"
}

# --- tag union -------------------------------------------------------------
# fm_ado_tag_union <wi> <tag>...  -> ensure each tag is present on the WI.
# Idempotent: reads the WI's current System.Tags, and writes back only when at
# least one requested tag is missing, so a re-run on an already-tagged WI makes
# no ADO write. ADO stores tags semicolon-separated; comparison is exact.
fm_ado_tag_union() {
  local wi=$1; shift
  local current add=() t new
  current=$(fm_ado_wi_field "$wi" System.Tags 2>/dev/null || echo "")
  for t in "$@"; do
    case "; $current ;" in
      *"; $t ;"*) : ;;                 # already present (normalized boundaries)
      *)
        # Fall back to a substring check for the un-normalized raw form too.
        case "$current" in
          *"$t"*) : ;;
          *) add+=("$t") ;;
        esac ;;
    esac
  done
  [ ${#add[@]} -gt 0 ] || return 0
  if [ -n "$current" ]; then
    new="$current"
    for t in "${add[@]}"; do new="$new; $t"; done
  else
    new=$(printf '%s; ' "${add[@]}"); new=${new%; }
  fi
  fm_ado_az boards work-item update --id "$wi" \
    --fields "System.Tags=$new" --org "$FM_ADO_ORG" -o json >/dev/null 2>&1
}

# --- legacy migration ------------------------------------------------------
# fm_ado_migrate_legacy <data-dir>  -> reconcile the two old per-project-model
# work items into the new shape. Idempotent and self-healing: it parents the
# legacy User Story under the standing Epic (the old per-project US floated at
# the top of the area path), unions the fm-repo:<repo> and fm-kind:ship tags onto
# it (legacy items were dev work, so fm-kind:ship keeps them in the clean
# fm-kind-filtered `ready` dispatch list), and ensures the legacy Task stays a
# child of that US carrying fm-managed. Re-running after the shape is already
# correct performs no ADO writes. A blank legacy id (config cleared the default)
# is a no-op, so the migration self-disables once retired.
fm_ado_migrate_legacy() {
  local data_dir=$1 epic us_wi task_wi repo
  us_wi=$FM_ADO_LEGACY_US
  task_wi=$FM_ADO_LEGACY_TASK
  repo=$FM_ADO_LEGACY_REPO
  [ -n "$us_wi" ] || return 0
  epic=$(fm_ado_ensure_epic "$data_dir" 2>/dev/null || true)
  [ -n "$epic" ] || return 1
  # Legacy US: parent under the Epic and carry fm-managed + fm-repo:<repo> +
  # fm-kind:ship so it keeps appearing in the fm-kind-filtered ready list.
  fm_ado_ensure_parent "$us_wi" "$epic" || true
  fm_ado_tag_union "$us_wi" "fm-managed" "fm-repo:$repo" "fm-kind:ship" || true
  # Legacy Task: keep it a child of the US, carrying fm-managed.
  if [ -n "$task_wi" ]; then
    fm_ado_ensure_parent "$task_wi" "$us_wi" || true
    fm_ado_tag_union "$task_wi" "fm-managed" || true
  fi
  printf '%s\n' "$us_wi"
}

# --- work-item URL ---------------------------------------------------------
# fm_ado_wi_url <wi>  -> browser URL for a work item.
fm_ado_wi_url() {
  printf '%s/%s/_workitems/edit/%s\n' "$FM_ADO_ORG" "$FM_ADO_PROJECT" "$1"
}

# --- bulk parallel update --------------------------------------------------
# Mass work-item operations (re-parenting a whole Epic tree to a new iteration or
# area, bulk state/field changes) applied CONCURRENTLY with bounded parallelism,
# retry-on-throttle, and a batched verify-after-write.
#
# Why parallel (verified live 2026-07-17, davidkydd-firstmate Epic, 193 items):
# a sequential per-item update loop (`az boards work-item update` one id at a time)
# TIMED OUT at 2 minutes without finishing, because the binding cost is the per-item
# network round-trip. A bounded 16-worker fan-out finished 192/193 in 10.4s
# (~54ms/item effective), a >10x win. One transient HTTP 503 (ADO throttle) appeared
# under load and succeeded on retry. Verify-after-write stayed ON in the fast run and
# cost almost nothing, because it is a BATCHED read (workitemsbatch reads up to 200
# ids per call), not N per-item reads. So the durable design is: fan out concurrent
# writes with a worker cap + retry-on-throttle, then verify with one or two batch GETs.
#
# Concurrency primitive: a rolling background-job pool throttled by `jobs -r -p`,
# NOT `wait -n`. `wait -n` is bash 4.3+ and the fleet's stock macOS system bash is
# 3.2 (verified 2026-07-17: `bash --version` -> 3.2.57), so `wait -n` is unavailable.
# `jobs -r -p | wc -l` counts running background jobs and works on 3.2; we spin a
# short sleep while the pool is full, then launch the next worker. `xargs -P` was
# the alternative but it cannot call the mockable `fm_ado_az` shell function inside
# a child process without re-sourcing the whole library per item, so the job pool
# keeps every request routed through `fm_ado_az` and unit-testable via FM_ADO_AZ.

# Default bounded worker cap. 16 matched the verified 10.4s run and stayed under
# ADO's throttle threshold (only one transient 503 across 193 items). Override via
# FM_ADO_BULK_CONCURRENCY.
FM_ADO_DEFAULT_BULK_CONCURRENCY=16
# Per-request retry attempts on a transient failure (HTTP 429/503 or a network
# error). Reuses the fm_ado_iter_backoff_sleep backoff curve. Override via
# FM_ADO_BULK_RETRY_ATTEMPTS.
FM_ADO_DEFAULT_BULK_RETRY_ATTEMPTS=4

# The Azure DevOps AAD resource id, needed by `az rest` to acquire a token for the
# wiql / workitemsbatch endpoints (az boards query does NOT support WorkItemLinks
# recursive queries, so those go through az rest). This is Azure DevOps's public,
# well-known first-party application id -- identical for EVERY ADO organization,
# not a tenant id and not a secret. Overridable via FM_ADO_REST_RESOURCE for
# sovereign/air-gapped clouds.
FM_ADO_REST_RESOURCE="${FM_ADO_REST_RESOURCE:-499b84ac-1321-427f-aa17-267ca6975798}"

# fm_ado_rest <method> <uri-path> [<body-file>]
# Thin wrapper over `az rest` routed through fm_ado_az so it stays mockable. The
# uri-path is appended to "<org>/<project>/_apis/"; api-version 7.0 is pinned.
# Echoes the response JSON; non-zero on transport failure.
fm_ado_rest() {
  local method=$1 path=$2 body=${3:-}
  local uri="$FM_ADO_ORG/$FM_ADO_PROJECT/_apis/$path"
  if [ -n "$body" ]; then
    fm_ado_az rest --method "$method" --resource "$FM_ADO_REST_RESOURCE" \
      --uri "$uri" --headers "Content-Type=application/json" \
      --body "@$body" -o json 2>/dev/null
  else
    fm_ado_az rest --method "$method" --resource "$FM_ADO_REST_RESOURCE" \
      --uri "$uri" -o json 2>/dev/null
  fi
}

# fm_ado_subtree_ids <epic-or-root-wi>  -> echo every descendant WI id (one per
# line), INCLUDING the root itself, via a recursive Hierarchy-Forward WorkItemLinks
# WIQL. This is the enumeration the 193-item migration needed: "everything under
# Epic <id>", not a hand-listed set. Non-zero on query failure.
fm_ado_subtree_ids() {
  local root=$1 body out
  body=$(mktemp "${TMPDIR:-/tmp}/fm-ado-wiql.XXXXXX") || return 1
  # WorkItemLinks recursive query: Source is the root, links are parent->child
  # Hierarchy-Forward, MODE (Recursive) walks the full subtree. workItemRelations[]
  # lists every node as a .target.id (the root appears with rel=null).
  printf '{"query":"SELECT [System.Id] FROM WorkItemLinks WHERE ([Source].[System.Id] = %s) AND ([System.Links.LinkType] = %s) MODE (Recursive)"}' \
    "$root" "'System.LinkTypes.Hierarchy-Forward'" > "$body"
  out=$(fm_ado_rest post "wit/wiql?api-version=7.0" "$body")
  local rc=$?
  rm -f "$body"
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$out" | fm_ado_jq -r '.workItemRelations[]?.target.id // empty' 2>/dev/null | awk 'NF' | sort -un
}

# fm_ado_batch_read_chunk <field> <id...>  -> echo "<id>\t<field-value>" per line
# for a SINGLE chunk of ids (caller keeps chunks <= 200). One workitemsbatch GET.
fm_ado_batch_read_chunk() {
  local field=$1; shift
  [ "$#" -gt 0 ] || return 0
  local body out ids_chunk
  ids_chunk=$(printf '%s,' "$@"); ids_chunk=${ids_chunk%,}
  body=$(mktemp "${TMPDIR:-/tmp}/fm-ado-batch.XXXXXX") || return 1
  printf '{"ids":[%s],"fields":["System.Id","%s"]}' "$ids_chunk" "$field" > "$body"
  out=$(fm_ado_rest post "wit/workitemsbatch?api-version=7.0" "$body")
  local rc=$?
  rm -f "$body"
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$out" | fm_ado_jq -r --arg f "$field" \
    '.value[]? | "\(.id)\t\(.fields[$f] // "")"' 2>/dev/null
}

# fm_ado_batch_field <field> <id...>  -> echo "<id>\t<field-value>" per line for
# the given ids, read in batches of 200 via the workitemsbatch endpoint (one or
# two GETs for the whole tree, not N reads). Used by verify-after-write. A value
# that is empty/absent is echoed as an empty second column. Non-zero on read
# failure. 200 is the workitemsbatch per-call id ceiling.
fm_ado_batch_field() {
  local field=$1; shift
  local n=0
  local -a chunk=()
  local id
  for id in "$@"; do
    chunk+=("$id")
    n=$((n + 1))
    if [ "$n" -ge 200 ]; then
      fm_ado_batch_read_chunk "$field" "${chunk[@]}" || return 1
      chunk=(); n=0
    fi
  done
  if [ "${#chunk[@]}" -gt 0 ]; then
    fm_ado_batch_read_chunk "$field" "${chunk[@]}" || return 1
  fi
  return 0
}

# fm_ado_bulk_set_one <field> <value> <wi>
# Apply ONE field=value change to ONE work item, retrying on a transient failure
# (HTTP 429/503 or a network/transport error) with the fm_ado_iter_backoff_sleep
# backoff curve. A genuine non-transient failure (400/404/permission) is NOT
# retried: it fails loudly after the first attempt. Returns 0 on success, non-zero
# on give-up. This is the unit a worker runs; it is a plain function so every call
# routes through fm_ado_az and is mockable.
fm_ado_bulk_set_one() {
  local field=$1 value=$2 wi=$3
  local attempts=${FM_ADO_BULK_RETRY_ATTEMPTS:-$FM_ADO_DEFAULT_BULK_RETRY_ATTEMPTS}
  local attempt=1 out rc
  while [ "$attempt" -le "$attempts" ]; do
    out=$(fm_ado_az boards work-item update --id "$wi" \
      --fields "$field=$value" --org "$FM_ADO_ORG" -o json 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    # Classify: retry only transient throttle/network errors. A 429/503 or an
    # explicit connection/timeout error is transient; anything else (400/404/401/
    # 403, "does not exist", permission) is a hard failure that will not clear on
    # retry, so stop immediately and let the caller report it loudly.
    if printf '%s' "$out" | grep -Eq '429|503|Too Many Requests|Service Unavailable|Temporarily|timed out|timeout|Connection|ConnectionError|Max retries'; then
      if [ "$attempt" -lt "$attempts" ]; then
        fm_ado_iter_backoff_sleep "$attempt"
        attempt=$((attempt + 1))
        continue
      fi
    fi
    return 1
  done
  return 1
}

# fm_ado_bulk_set <field> <value> <id...>
# Apply the SAME field=value change to a LIST of work items CONCURRENTLY, bounded
# by FM_ADO_BULK_CONCURRENCY workers, each retrying on throttle. After the write
# wave completes, VERIFY-AFTER-WRITE reads the field back for every id in one or
# two batch GETs and confirms each landed; any straggler is reported loudly and
# makes the function return non-zero.
#
# The captain's standing instruction (reaffirmed 2026-07-17) is that verify stays
# ON: it is cheap under this design (batched, concurrent-independent), so it is
# never dropped to gain speed.
#
# Output (stdout): a per-id result line "<wi>\t<ok|write-failed|mismatch:<got>>".
# Return: 0 iff every id both wrote and verified; non-zero if any failed.
fm_ado_bulk_set() {
  local field=$1 value=$2; shift 2
  [ "$#" -gt 0 ] || return 0
  local cap=${FM_ADO_BULK_CONCURRENCY:-$FM_ADO_DEFAULT_BULK_CONCURRENCY}
  [ "$cap" -ge 1 ] 2>/dev/null || cap=1
  local rdir
  rdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-ado-bulk.XXXXXX") || return 1
  # --- concurrent write wave (bounded rolling job pool, bash-3.2-safe) ---
  local wi
  for wi in "$@"; do
    # Throttle: block while the running-job pool is at the cap. `jobs -r -p` lists
    # PIDs of RUNNING background jobs; this is the bash-3.2 substitute for wait -n.
    while [ "$(jobs -r -p | wc -l | tr -d ' ')" -ge "$cap" ]; do
      sleep 0.02
    done
    (
      if fm_ado_bulk_set_one "$field" "$value" "$wi"; then
        printf 'ok' > "$rdir/$wi"
      else
        printf 'write-failed' > "$rdir/$wi"
      fi
    ) &
  done
  wait
  # --- batched verify-after-write ---
  local verify rc=0
  verify=$(fm_ado_batch_field "$field" "$@") || {
    echo "fm-ado bulk: verify read failed; cannot confirm writes landed" >&2
    rm -rf "$rdir"
    return 1
  }
  # Write the verified <id>\t<value> pairs to a file so each id's landed value
  # can be looked up by an exact first-column match.
  local vfile
  vfile=$(mktemp "${TMPDIR:-/tmp}/fm-ado-verify.XXXXXX") || { rm -rf "$rdir"; return 1; }
  printf '%s\n' "$verify" > "$vfile"
  for wi in "$@"; do
    local wstate got
    wstate=$(cat "$rdir/$wi" 2>/dev/null || echo "write-failed")
    got=$(awk -F'\t' -v id="$wi" '$1==id {print $2; exit}' "$vfile")
    if [ "$wstate" != ok ]; then
      printf '%s\twrite-failed\n' "$wi"
      rc=1
    elif [ "$got" = "$value" ]; then
      printf '%s\tok\n' "$wi"
    else
      printf '%s\tmismatch:%s\n' "$wi" "$got"
      rc=1
    fi
  done
  rm -f "$vfile"
  rm -rf "$rdir"
  return "$rc"
}
