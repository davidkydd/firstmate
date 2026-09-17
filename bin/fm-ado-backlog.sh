#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq filter bodies use single quotes so $vars are jq --arg refs, not shell expansions
# fm-ado-backlog.sh - Azure DevOps work-item backlog operations for the `ado`
# value of config/backlog-backend. ADO work items are the source of truth; a
# local cache under data/ (data/ado-cache.json) keeps reads fast and
# offline-tolerant. Writes go to ADO (write-through), then update the cache.
#
# This is firstmate's ADO analogue of the tasks-axi verb surface (AGENTS.md
# section 10). See docs/ado-task-backend.md for field mappings, WIQL, cache
# schema, and the dated verification record.
#
# Verbs:
#   add <id> "<summary>" --kind <ship|scout|review> --repo <project>
#                      [--start] [--blocked-by <id> ...]
#                      [--prompt-file <p>] [--brief-file <p>]
#                      [--mode <m>] [--context <text>]
#        Create-or-reuse the KIND-AWARE primary work item under the standing
#        davidkydd-firstmate Epic (tags fm-managed, fm-repo:<project>, fm-id:<id>,
#        fm-kind:<kind>):
#          ship          -> a User Story seeded with per-stage child Tasks.
#          scout, review -> a single Task (no User Story).
#        "<summary>" is the firstmate-generated concise title; the full content
#        (verbatim prompt via --prompt-file, generated brief via --brief-file,
#        plus --mode/--context) goes into the Description, the durable record.
#        A FRESH create REQUIRES a non-empty --prompt-file (the captain's verbatim
#        request): add fails loudly with no ADO write rather than recording a
#        "(no prompt recorded)" placeholder. Reuse is exempt (the original prompt
#        is durable): a bare re-add is a no-op, a re-add with a new prompt
#        accumulates it as a dated follow-up.
#        area = configured area path, iteration = @currentIteration. --start
#        places the item In flight (Active); default New.
#   add-child <id> "<title>" [--stage <slug>]
#        Add a discovered-work child Task under a ship item's User Story. With
#        --stage the add is idempotent (reuse by the fm-stage tag); without it the
#        task is treated as genuinely new discovered work and always created.
#   start <id>         Queued -> In flight (System.State New -> Active).
#   done <id> [--pr <url> | --report <path> | --note <text>]
#        Close the WI and record the PR URL / report path / note as a comment.
#   block <id> --by <other>       Add blocked-by dependency (Predecessor link).
#   unblock <id> --by <other>     Remove that dependency link.
#   show <id> [--full]            Print the WI's firstmate-relevant fields.
#   update <id> --body-file <path>   Replace the WI description from a file.
#   ready                         List queued (New) Stories with no open blocker.
#   render                        Reconcile the cache from ADO (bounded refresh).
#   migrate [--us <wi>] [--task <wi>] [--repo <name>]
#                                 Reconcile the old per-project-model work items
#                                 into the new Epic/Story shape (idempotent).
#                                 Opt-in: a no-op unless the legacy ids are given
#                                 via flags or config (FM_ADO_LEGACY_US/TASK/REPO).
#   resolve-id <id>               Print the WI id for a firstmate id (cache).
#   resolve-wi <wi>               Print the firstmate id for a WI (cache).
#   bulk-set <field> <value> (--tree <root-wi> | <id...>)
#        Apply the SAME field=value change to many work items CONCURRENTLY
#        (bounded parallelism + retry-on-throttle + batched verify-after-write).
#        --tree <root-wi> targets a whole Epic subtree (Epic + all descendants);
#        otherwise the trailing args are literal WI ids. Concurrency defaults to
#        FM_ADO_BULK_CONCURRENCY (16). Fails loudly if any item does not land.
#   bulk-set-iteration (--tree <root-wi> | <id...>) <iteration-path>
#        bulk-set specialized to System.IterationPath; the path is the LAST arg.
#        Built for the mass Epic-tree iteration migration (193 items in 10.4s vs a
#        sequential loop that timed out at 2 minutes; see docs/ado-task-backend.md).
#
# az calls route through fm_ado_az (mockable via FM_ADO_AZ) so this script's
# command construction is unit-testable without a live ADO.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-ado-lib.sh
. "$SCRIPT_DIR/fm-ado-lib.sh"

die() {
  echo "fm-ado-backlog: $*" >&2
  exit 1
}

require_jq() {
  fm_ado_has_jq || die "jq is required for the ado backlog backend"
}

require_ready() {
  local state
  state=$(fm_ado_tooling_state) || die "ADO not reachable ($state); reads serve from cache, writes are blocked until resolved"
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# --- verb: add -------------------------------------------------------------
cmd_add() {
  local id="" title="" kind="ship" repo="" start=0
  local prompt_file="" brief_file="" mode="" context=""
  local -a blocked_by=()
  id=${1:-}; shift || true
  title=${1:-}; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind=$2; shift 2 ;;
      --repo) repo=$2; shift 2 ;;
      --start) start=1; shift ;;
      --blocked-by) blocked_by+=("$2"); shift 2 ;;
      --prompt-file) prompt_file=$2; shift 2 ;;
      --brief-file) brief_file=$2; shift 2 ;;
      --mode) mode=$2; shift 2 ;;
      --context) context=$2; shift 2 ;;
      *) die "add: unknown flag $1" ;;
    esac
  done
  [ -n "$id" ] || die "add: missing <id>"
  [ -n "$title" ] || die "add: missing <summary> title"
  [ -n "$repo" ] || die "add: --repo <project> is required"
  fm_ado_kind_is_valid "$kind" || die "add: --kind must be ship, scout, or review"
  require_jq
  require_ready

  # Fail closed on a promptless FRESH create. The captain's verbatim request is
  # the most valuable provenance on a work item, and the composer renders
  # "(no prompt recorded)" when no usable prompt reaches it, permanently losing
  # that request. A missing OR empty --prompt-file is treated the same. Only a
  # FRESH create is blocked: reusing an existing item is legitimate with no
  # prompt (a bare re-add is a documented no-op; a re-add carrying a new prompt
  # accumulates it via the follow-up path below), so the existence check runs
  # only on the prompt-absent path and the proven --prompt-file path pays nothing.
  if [ -z "$prompt_file" ] || [ ! -s "$prompt_file" ]; then
    local existing_primary
    if ! existing_primary=$(fm_ado_find_primary "$DATA" "$id" "$(fm_ado_primary_type "$kind")" 2>/dev/null); then
      die "add: could not determine whether $id already exists (primary lookup failed); retry once ADO is reachable"
    fi
    [ -n "$existing_primary" ] \
      || die "add: refusing to create work item $id with no captain prompt (would record '(no prompt recorded)' and lose the request); pass --prompt-file <p> with the captain's verbatim request (see docs/ado-task-backend.md 'initial-prompt')"
  fi

  local state primary rev
  if [ "$start" -eq 1 ]; then
    state=$(fm_ado_state_for_placement start)
  else
    state=$(fm_ado_state_for_placement queued)
  fi

  # Resolve the iteration ONCE up front and export it for the process lifetime,
  # so the primary create and every stage-Task create reuse one good read instead
  # of each re-resolving through a separately flaky iteration-list call. This is
  # also where an iteration-resolution failure is reported accurately: an empty
  # iteration path is the real cause of the downstream TF401347 create failure,
  # not a create-or-reuse fault, so distinguish the two.
  local iter
  iter=$(fm_ado_resolve_iteration) \
    || die "add: could not resolve the current iteration for team '$FM_ADO_TEAM' (transient empty @currentIteration read after retries); retry, or set FM_ADO_ITERATION to a literal path"
  export FM_ADO_ITER_CACHE="$iter"

  # Resolve the submitter identity ONCE and export the process-lifetime cache, so
  # the primary create and every per-stage Task create (each a separate subshell)
  # reuse one `az account show` read and warn at most once. A degraded-auth miss
  # exports an empty cache with the resolved flag set, so downstream creates fall
  # back to unassigned silently instead of each re-probing and re-warning.
  FM_ADO_USER_CACHE=$(fm_ado_current_user || true)
  export FM_ADO_USER_CACHE FM_ADO_USER_RESOLVED=1

  # Compose the durable Description (initial-prompt + brief + context) into a temp
  # HTML file, so a prompt/brief containing shell-special chars is written through
  # a file, never re-quoted on a command line. Content that does not fit the
  # Description byte budget is NOT truncated: it spills to ordered work-item
  # comments posted after the WI exists (fm_ado_write_spill_comments ->
  # fm_ado_post_spill_comments), so Description + comments reconstruct the full
  # prompt and brief exactly.
  local desc_file spill_dir
  desc_file=$(mktemp "${TMPDIR:-/tmp}/fm-ado-desc.XXXXXX") || die "add: could not create temp description file"
  spill_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-ado-spill.XXXXXX") || die "add: could not create temp spill dir"
  # shellcheck disable=SC2064  # expand paths now for the EXIT trap
  trap "rm -rf '$desc_file' '$spill_dir'" EXIT
  fm_ado_compose_description "$id" "$kind" "$repo" \
    ${prompt_file:+--prompt-file "$prompt_file"} \
    ${brief_file:+--brief-file "$brief_file"} \
    ${mode:+--mode "$mode"} \
    ${context:+--context "$context"} > "$desc_file" \
    || echo "fm-ado-backlog: warning: could not compose description for $id" >&2
  # Guard the Description write against an oversized argv/field (surface a clearer
  # diagnostic than the generic create failure). The composer already caps the
  # Description at FM_ADO_DESC_MAX_CHARS, so this only fires on a misconfiguration.
  local desc_bytes
  desc_bytes=$(wc -c < "$desc_file" | tr -d ' ')
  if [ "${desc_bytes:-0}" -gt "$(( $(fm_ado_desc_budget) * 4 + 4096 ))" ]; then
    die "add: composed Description for $id is ${desc_bytes} bytes, far over the FM_ADO_DESC_MAX_CHARS budget; lower the budget or check the prompt/brief encoding"
  fi
  # Create-or-reuse the KIND-AWARE primary work item under the standing Epic,
  # tagged fm-managed, fm-repo:<repo>, fm-id:<id>, fm-kind:<kind>. ship -> a User
  # Story; scout/review -> a single Task. The reuse path NEVER rewrites the
  # existing Description: the original prompt is durable. A follow-up prompt on a
  # re-add accumulates instead (see the follow-up block below).
  local created_file
  created_file=$(mktemp "${TMPDIR:-/tmp}/fm-ado-created.XXXXXX") || die "add: could not create temp marker file"
  # shellcheck disable=SC2064  # expand paths now for the EXIT trap
  trap "rm -rf '$desc_file' '$spill_dir' '$created_file'" EXIT
  primary=$(fm_ado_ensure_primary "$DATA" "$id" "$title" "$repo" "$kind" "$desc_file" "$created_file") \
    || die "add: could not create-or-reuse the primary work item for $id"
  [ -n "$primary" ] || die "add: primary work item id empty"
  local primary_fresh
  primary_fresh=$(cat "$created_file" 2>/dev/null || echo 0)

  if [ "$primary_fresh" = 1 ]; then
    # Fresh create: post the create-path spillover comments (the full prompt/brief
    # remainder that did not fit the Description) now the WI exists, in order, so
    # Description + comments reconstruct the full content exactly.
    local spill_count
    spill_count=$(fm_ado_write_spill_comments "$id" "$spill_dir" \
      ${prompt_file:+--prompt-file "$prompt_file"} \
      ${brief_file:+--brief-file "$brief_file"} 2>/dev/null || echo 0)
    if [ "${spill_count:-0}" -gt 0 ]; then
      fm_ado_post_spill_comments "$primary" "$spill_dir" \
        || echo "fm-ado-backlog: warning: one or more overflow comments for $id failed to post; the work item may hold only part of the prompt/brief" >&2
    fi
  elif [ -s "$prompt_file" ]; then
    # Re-add of an existing work item WITH a new prompt: ACCUMULATE it. The
    # original prompt stays in the Description untouched; this follow-up prompt is
    # appended to the existing Description under a dated header when it fits the
    # Description budget, else it lands in ordered work-item comment(s) instead
    # (never truncated). Read the live Description first; only mutate on a
    # successful write, so a failed append or comment post leaves the stored
    # Description - and every prior prompt - intact.
    local followup_date existing_file existing_ok=0
    followup_date=$(date -u +%Y-%m-%d)
    existing_file=$(mktemp "${TMPDIR:-/tmp}/fm-ado-desc-existing.XXXXXX") || die "add: could not create temp file"
    # shellcheck disable=SC2064  # expand paths now for the EXIT trap
    trap "rm -rf '$desc_file' '$spill_dir' '$created_file' '$existing_file'" EXIT
    if fm_ado_wi_field "$primary" System.Description > "$existing_file" 2>/dev/null \
        && [ -s "$existing_file" ]; then
      existing_ok=1
    fi
    # Append in-Description ONLY when the existing Description was read successfully
    # and fits: appending onto an empty base after a failed/empty read would drop
    # the original prompt, so on any read doubt fall back to the comment path,
    # which never rewrites the Description.
    if [ "$existing_ok" = 1 ] && fm_ado_followup_fits "$existing_file" "$prompt_file" "$followup_date"; then
      fm_ado_append_followup "$primary" "$existing_file" "$prompt_file" "$followup_date" \
        || echo "fm-ado-backlog: warning: could not append the follow-up prompt for $id; the stored Description is unchanged" >&2
    else
      local followup_count
      followup_count=$(fm_ado_write_followup_comments "$id" "$spill_dir" "$prompt_file" "$followup_date" 2>/dev/null || echo 0)
      if [ "${followup_count:-0}" -gt 0 ]; then
        fm_ado_post_spill_comments "$primary" "$spill_dir" \
          || echo "fm-ado-backlog: warning: one or more follow-up comments for $id failed to post; the follow-up prompt may be incomplete" >&2
      fi
    fi
  fi

  # For ship (dev) work, seed the User Story with the per-stage child Tasks.
  # scout/review are single-deliverable Tasks with no children.
  if [ "$kind" = ship ]; then
    fm_ado_ensure_stage_tasks "$id" "$primary" "$primary_fresh" >/dev/null \
      || echo "fm-ado-backlog: warning: could not seed stage Tasks under Story $primary" >&2
  fi

  # Transition to Active if starting (create lands in New).
  if [ "$start" -eq 1 ]; then
    fm_ado_az boards work-item update --id "$primary" --state Active \
      --org "$FM_ADO_ORG" -o json >/dev/null 2>&1 \
      || echo "fm-ado-backlog: warning: could not set $primary Active" >&2
  fi

  # Dependencies: blocker is Predecessor of this work item.
  local b bwi
  for b in ${blocked_by[@]+"${blocked_by[@]}"}; do
    bwi=$(fm_ado_cache_get_wi "$DATA" "$b" 2>/dev/null || true)
    [ -n "$bwi" ] || { echo "fm-ado-backlog: warning: blocker $b not in cache; skipping link" >&2; continue; }
    fm_ado_az boards work-item relation add \
      --id "$primary" --relation-type predecessor --target-id "$bwi" \
      --org "$FM_ADO_ORG" -o json >/dev/null 2>&1 \
      || echo "fm-ado-backlog: warning: could not add blocked-by $b" >&2
  done

  # Verify-after-write: ONE relations-expanded read-back GET, then validate what
  # was written against what ADO actually returns (authoritative, not the local
  # cache), so no ADO state is ever silently lost. Existence is verified on every
  # path. The create-time invariants (fm-id/fm-kind tags, Epic parent, --start
  # state, blocked-by links, no duplicate) are asserted on a FRESH create - the
  # path where the intermittent glitch, silent-loss, and duplicate risk actually
  # live. A reuse's only write is the follow-up description/comment accumulation,
  # which owns its own read-before-write, non-fatal-on-failure preservation
  # contract above; re-asserting tags/parent there would both duplicate that owner
  # and wrongly hard-fail the intentionally non-fatal follow-up path. The settled
  # rev from this same GET refreshes the cache (no extra round-trip).
  local rb epic
  rb=$(fm_ado_read_back_rel "$primary") \
    || die "add: read-back GET failed for WI $primary; cannot confirm the work item persisted"
  fm_ado_check_exists "$rb" \
    || die "add: verify failed - WI $primary does not exist in ADO after the write"
  epic=$(fm_ado_cache_get_epic "$DATA" 2>/dev/null || echo 0)
  if [ "$primary_fresh" = 1 ]; then
    fm_ado_check_tags_contain "$rb" "fm-id:$id" \
      || die "add: verify failed - WI $primary is missing the fm-id:$id tag"
    fm_ado_check_tags_contain "$rb" "fm-kind:$kind" \
      || die "add: verify failed - WI $primary is missing the fm-kind:$kind tag"
    if [ -n "$epic" ] && [ "$epic" != 0 ]; then
      fm_ado_check_parent "$rb" "$epic" \
        || die "add: verify failed - WI $primary is not parented under the Epic $epic"
    fi
    # Only the --start path WRITES a state transition (to Active); verify exactly
    # what was written. Without --start the create lands New implicitly.
    if [ "$start" -eq 1 ]; then
      fm_ado_check_state "$rb" Active \
        || die "add: verify failed - WI $primary System.State is '$(printf '%s' "$rb" | fm_ado_jq -r '.fields."System.State" // "empty"')', expected Active after --start"
    fi
    for b in ${blocked_by[@]+"${blocked_by[@]}"}; do
      bwi=$(fm_ado_cache_get_wi "$DATA" "$b" 2>/dev/null || true)
      [ -n "$bwi" ] || continue
      fm_ado_check_predecessor "$rb" "$bwi" \
        || die "add: verify failed - WI $primary is missing the blocked-by Predecessor link to $b (WI $bwi)"
    done
    # Duplicate detection (glitch symptom): a partial/retried create can leave more
    # than one primary WI carrying this fm-id. Best-effort - the tag query is
    # eventually consistent so a just-created single WI never false-alarms (a query
    # failure or a not-yet-indexed create counts as <=1), but a duplicate that HAS
    # become visible fails loudly so orphans are caught instead of silently kept.
    local dupes wtype
    wtype=$(fm_ado_primary_type "$kind")
    dupes=$(fm_ado_count_primary "$id" "$wtype")
    if [ "${dupes:-0}" -gt 1 ]; then
      die "add: verify failed - $dupes primary work items carry fm-id:$id (duplicate create detected); clean up the extra WI(s) before retrying"
    fi
  fi

  rev=$(printf '%s' "$rb" | fm_ado_jq -r '.fields."System.Rev" // 0')
  fm_ado_cache_put "$DATA" "$id" "$primary" "$rev" "$state" "$kind" "$repo" "${epic:-0}" "$title" "$(now_iso)" \
    || echo "fm-ado-backlog: warning: cache update failed for $id" >&2
  printf '%s\t%s\n' "$primary" "$(fm_ado_wi_url "$primary")"
}

# --- verb: add-child -------------------------------------------------------
# Add a discovered-work child Task under a ship item's User Story. The item must
# resolve to a cached primary WI, and it must be a ship (its primary is a User
# Story). --stage makes the add idempotent (reuse by the fm-stage tag).
cmd_add_child() {
  local id="" title="" stage=""
  id=${1:-}; shift || true
  title=${1:-}; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) stage=$2; shift 2 ;;
      *) die "add-child: unknown flag $1" ;;
    esac
  done
  [ -n "$id" ] || die "add-child: missing <id>"
  [ -n "$title" ] || die "add-child: missing <title>"
  require_jq
  require_ready
  local story kind wi
  story=$(fm_ado_cache_get_wi "$DATA" "$id") || die "add-child: $id not in cache"
  [ -n "$story" ] || die "add-child: $id not in cache"
  kind=$(fm_ado_jq -r --arg id "$id" '.items[$id].kind // empty' "$(fm_ado_cache_path "$DATA")" 2>/dev/null || true)
  [ "$kind" = ship ] || die "add-child: $id is kind '$kind'; child Tasks are only added under a ship User Story"
  wi=$(fm_ado_add_child_task "$id" "$story" "$title" "$stage") \
    || die "add-child: could not create child Task under Story $story"
  # Verify-after-write: read the child Task back and confirm it exists and is
  # parented under the ship Story before reporting it. The read-back is authoritative.
  local rb
  rb=$(fm_ado_read_back_rel "$wi") \
    || die "add-child: read-back GET failed for child Task $wi; cannot confirm it persisted"
  fm_ado_check_exists "$rb" \
    || die "add-child: verify failed - child Task $wi does not exist in ADO after create"
  fm_ado_check_parent "$rb" "$story" \
    || die "add-child: verify failed - child Task $wi is not parented under Story $story"
  printf '%s\t%s\n' "$wi" "$(fm_ado_wi_url "$wi")"
}

# --- verb: start -----------------------------------------------------------
cmd_start() {
  local id=${1:-}
  [ -n "$id" ] || die "start: missing <id>"
  require_jq
  require_ready
  local wi rev
  wi=$(fm_ado_cache_get_wi "$DATA" "$id") || die "start: $id not found in cache"
  [ -n "$wi" ] || die "start: $id not found in cache"
  fm_ado_az boards work-item update --id "$wi" --state Active \
    --org "$FM_ADO_ORG" -o json >/dev/null 2>&1 || die "start: state update failed"
  # Verify-after-write: read the WI back and confirm the state actually persisted
  # as Active before treating start as done. The read-back is authoritative; the
  # cache is refreshed from it (one GET, reused for the rev too).
  local rb
  rb=$(fm_ado_read_back "$wi") \
    || die "start: read-back GET failed for WI $wi; cannot confirm the Active transition persisted"
  fm_ado_check_state "$rb" Active \
    || die "start: verify failed - WI $wi System.State did not persist as Active (ADO returned '$(printf '%s' "$rb" | fm_ado_jq -r '.fields."System.State" // "empty"')')"
  rev=$(printf '%s' "$rb" | fm_ado_jq -r '.fields."System.Rev" // 0')
  fm_ado_cache_set_field "$DATA" "$id" state Active || true
  fm_ado_cache_set_rev "$DATA" "$id" "$rev" || true
  fm_ado_cache_set_field "$DATA" "$id" updated "$(now_iso)" || true
  echo "started $id -> WI $wi (Active, verified)"
}

# --- verb: done ------------------------------------------------------------
cmd_done() {
  local id="" pr="" report="" note=""
  id=${1:-}; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) pr=$2; shift 2 ;;
      --report) report=$2; shift 2 ;;
      --note) note=$2; shift 2 ;;
      *) die "done: unknown flag $1" ;;
    esac
  done
  [ -n "$id" ] || die "done: missing <id>"
  require_jq
  require_ready
  local wi comment rev
  wi=$(fm_ado_cache_get_wi "$DATA" "$id") || die "done: $id not found in cache"
  [ -n "$wi" ] || die "done: $id not found in cache"
  if [ -n "$pr" ]; then
    comment="firstmate: done - PR $pr"
  elif [ -n "$report" ]; then
    comment="firstmate: done - report $report"
  elif [ -n "$note" ]; then
    comment="firstmate: done - $note"
  else
    comment="firstmate: done"
  fi
  fm_ado_az boards work-item update --id "$wi" --state Closed \
    --discussion "$comment" --org "$FM_ADO_ORG" -o json >/dev/null 2>&1 \
    || die "done: close failed"
  # Verify-after-write: read the WI back and confirm it actually closed before
  # reporting done. The read-back is authoritative; refresh the cache from it.
  local rb
  rb=$(fm_ado_read_back "$wi") \
    || die "done: read-back GET failed for WI $wi; cannot confirm the close persisted"
  fm_ado_check_state "$rb" Closed \
    || die "done: verify failed - WI $wi System.State did not persist as Closed (ADO returned '$(printf '%s' "$rb" | fm_ado_jq -r '.fields."System.State" // "empty"')')"
  rev=$(printf '%s' "$rb" | fm_ado_jq -r '.fields."System.Rev" // 0')
  fm_ado_cache_set_field "$DATA" "$id" state Closed || true
  fm_ado_cache_set_rev "$DATA" "$id" "$rev" || true
  fm_ado_cache_set_field "$DATA" "$id" updated "$(now_iso)" || true
  echo "closed $id -> WI $wi (verified)"
}

# --- verb: block / unblock -------------------------------------------------
cmd_block() {
  local id="" by=""
  id=${1:-}; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) by=$2; shift 2 ;;
      *) die "block: unknown flag $1" ;;
    esac
  done
  [ -n "$id" ] || die "block: missing <id>"
  [ -n "$by" ] || die "block: --by <other> is required"
  require_jq
  require_ready
  local wi bwi
  wi=$(fm_ado_cache_get_wi "$DATA" "$id") || die "block: $id not in cache"
  bwi=$(fm_ado_cache_get_wi "$DATA" "$by") || die "block: blocker $by not in cache"
  if [ -z "$wi" ] || [ -z "$bwi" ]; then die "block: unresolved ids"; fi
  fm_ado_az boards work-item relation add \
    --id "$wi" --relation-type predecessor --target-id "$bwi" \
    --org "$FM_ADO_ORG" -o json >/dev/null 2>&1 || die "block: link add failed"
  # Verify-after-write: read the WI's relations back and confirm the Predecessor
  # link to the blocker actually persisted before reporting the block.
  local rb
  rb=$(fm_ado_read_back_rel "$wi") \
    || die "block: read-back GET failed for WI $wi; cannot confirm the blocked-by link persisted"
  fm_ado_check_predecessor "$rb" "$bwi" \
    || die "block: verify failed - WI $wi has no persisted Predecessor link to blocker WI $bwi"
  echo "blocked $id by $by (WI $wi predecessor WI $bwi, verified)"
}

cmd_unblock() {
  local id="" by=""
  id=${1:-}; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) by=$2; shift 2 ;;
      *) die "unblock: unknown flag $1" ;;
    esac
  done
  [ -n "$id" ] || die "unblock: missing <id>"
  [ -n "$by" ] || die "unblock: --by <other> is required"
  require_jq
  require_ready
  local wi bwi
  wi=$(fm_ado_cache_get_wi "$DATA" "$id") || die "unblock: $id not in cache"
  bwi=$(fm_ado_cache_get_wi "$DATA" "$by") || die "unblock: blocker $by not in cache"
  fm_ado_az boards work-item relation remove \
    --id "$wi" --relation-type predecessor --target-id "$bwi" \
    --org "$FM_ADO_ORG" --yes -o json >/dev/null 2>&1 || die "unblock: link remove failed"
  # Verify-after-write: read the WI's relations back and confirm the Predecessor
  # link to the blocker is actually gone before reporting the unblock.
  local rb
  rb=$(fm_ado_read_back_rel "$wi") \
    || die "unblock: read-back GET failed for WI $wi; cannot confirm the blocked-by link was removed"
  fm_ado_check_no_predecessor "$rb" "$bwi" \
    || die "unblock: verify failed - WI $wi still has a Predecessor link to blocker WI $bwi after remove"
  echo "unblocked $id from $by (verified)"
}

# --- verb: show ------------------------------------------------------------
cmd_show() {
  local id="" full=0
  id=${1:-}; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --full) full=1; shift ;;
      *) die "show: unknown flag $1" ;;
    esac
  done
  [ -n "$id" ] || die "show: missing <id>"
  require_jq
  local wi out
  wi=$(fm_ado_cache_get_wi "$DATA" "$id") || die "show: $id not in cache"
  [ -n "$wi" ] || die "show: $id not in cache"
  if ! fm_ado_ready; then
    echo "fm-ado-backlog: ADO unreachable; showing cached fields for $id" >&2
    fm_ado_jq -r --arg id "$id" '.items[$id]' "$(fm_ado_cache_path "$DATA")"
    return 0
  fi
  out=$(fm_ado_az boards work-item show --id "$wi" --org "$FM_ADO_ORG" -o json 2>/dev/null) \
    || die "show: WI read failed"
  if [ "$full" -eq 1 ]; then
    printf '%s\n' "$out" | fm_ado_jq '{id:.id, fields:{title:.fields."System.Title", state:.fields."System.State", rev:.fields."System.Rev", area:.fields."System.AreaPath", iteration:.fields."System.IterationPath", tags:.fields."System.Tags", description:.fields."System.Description"}}'
  else
    printf '%s\n' "$out" | fm_ado_jq -r '"WI \(.id): \(.fields."System.Title") [\(.fields."System.State")] rev=\(.fields."System.Rev")"'
  fi
}

# --- verb: update ----------------------------------------------------------
cmd_update() {
  local id="" body_file=""
  id=${1:-}; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --body-file) body_file=$2; shift 2 ;;
      *) die "update: unknown flag $1" ;;
    esac
  done
  [ -n "$id" ] || die "update: missing <id>"
  [ -n "$body_file" ] || die "update: --body-file <path> is required"
  [ -f "$body_file" ] || die "update: body file not found: $body_file"
  require_jq
  require_ready
  local wi body rev pre_rev
  wi=$(fm_ado_cache_get_wi "$DATA" "$id") || die "update: $id not in cache"
  [ -n "$wi" ] || die "update: $id not in cache"
  # Capture the pre-write System.Rev (cached rev, else a pre-read) so the read-back
  # can prove the write was NOT rejected/rolled back. A rev regression means ADO
  # rolled the write back; an unchanged rev is a legitimate idempotent no-op.
  pre_rev=$(fm_ado_jq -r --arg id "$id" '.items[$id].rev // empty' "$(fm_ado_cache_path "$DATA")" 2>/dev/null || true)
  [ -n "$pre_rev" ] || pre_rev=$(fm_ado_wi_rev "$wi" 2>/dev/null || true)
  [ -n "$pre_rev" ] || pre_rev=0
  body=$(cat "$body_file")
  fm_ado_az boards work-item update --id "$wi" --description "$body" \
    --org "$FM_ADO_ORG" -o json >/dev/null 2>&1 || die "update: description write failed"
  # Verify-after-write: read the WI back and confirm the write persisted. ADO
  # normalizes stored HTML (entity re-encoding, whitespace reflow), so a byte or
  # whitespace containment check against the body produces false failures; instead
  # detect GENUINE data loss - a rev that regressed (rejected/rolled-back write) or
  # an EMPTY Description. An idempotent re-run with an identical body leaves the rev
  # UNCHANGED (ADO does not bump System.Rev on a no-op) and the Description present,
  # so it PASSES - exactly the retry path this feature hardens.
  local rb rb_rev
  rb=$(fm_ado_read_back "$wi") \
    || die "update: read-back GET failed for WI $wi; cannot confirm the Description persisted"
  rb_rev=$(printf '%s' "$rb" | fm_ado_jq -r '.fields."System.Rev" // 0')
  [ "${rb_rev:-0}" -ge "${pre_rev:-0}" ] \
    || die "update: verify failed - WI $wi System.Rev regressed ($rb_rev < $pre_rev); the description write was rejected or rolled back"
  fm_ado_check_desc_nonempty "$rb" \
    || die "update: verify failed - WI $wi System.Description came back empty after the write"
  rev=$rb_rev
  fm_ado_cache_set_rev "$DATA" "$id" "$rev" || true
  fm_ado_cache_set_field "$DATA" "$id" updated "$(now_iso)" || true
  echo "updated $id (WI $wi) description (verified)"
}

# --- verb: ready -----------------------------------------------------------
# Queued (New) fm-managed primary work items under the fm area path whose
# blockers are all closed. Primaries are ship User Stories and scout/review
# Tasks; only primaries carry an fm-kind:<kind> tag, so matching on any concrete
# kind (see fm_ado_ready_kind_clause) includes all primary types while excluding
# a ship item's child stage/discovered Tasks (which carry fm-id/fm-stage but no
# fm-kind). Primaries are pinned to a
# concrete iteration at create time, so one that outlives its sprint no longer
# sits in @currentIteration; rather than let it silently vanish from the
# dispatch list, we reparent every still-queued, unblocked primary in a
# genuinely PAST sprint forward to the current sprint before listing it. The
# migration is bounded to firstmate-owned (fm-managed) New primaries under the
# fm area path, and to iterations that ended before the current one began, so a
# current or deliberately future-placed primary is never pulled forward.
cmd_ready() {
  require_jq
  require_ready
  local out curiter kindclause
  kindclause=$(fm_ado_ready_kind_clause)
  out=$(fm_ado_az boards query --org "$FM_ADO_ORG" --project "$FM_ADO_PROJECT" --wiql \
    "SELECT [System.Id],[System.Title],[System.State],[System.IterationPath] FROM WorkItems WHERE [System.TeamProject]='$FM_ADO_PROJECT' AND ([System.WorkItemType]='User Story' OR [System.WorkItemType]='Task') AND [System.State]='New' AND [System.Tags] CONTAINS 'fm-managed' AND $kindclause AND [System.AreaPath] UNDER '$FM_ADO_AREA_PATH'" \
    -o json 2>/dev/null) || die "ready: WIQL query failed"
  # Resolve the current sprint once so stale tasks can be reparented forward.
  curiter=$(fm_ado_resolve_iteration 2>/dev/null || true)
  # The team-iteration list is loop-invariant; read it once up front and reuse it
  # for every candidate's older-than check instead of one list round-trip per
  # queued primary.
  local iterjson=""
  [ -n "$curiter" ] && iterjson=$(fm_ado_team_iterations 2>/dev/null || true)
  # For each candidate, print only when it has no open predecessor.
  local ids id title iterpath
  ids=$(printf '%s' "$out" | fm_ado_jq -r '.[].id')
  for id in $ids; do
    if fm_ado_has_open_predecessor "$id"; then
      continue
    fi
    # Reparent forward only if it drifted into a genuinely PAST sprint
    # (idempotent; a current or future-placed WI is never pulled forward).
    if [ -n "$curiter" ]; then
      iterpath=$(printf '%s' "$out" | fm_ado_jq -r --argjson wi "$id" \
        'first(.[] | select(.id == $wi)) | .fields."System.IterationPath" // ""')
      if [ -n "$iterpath" ] && fm_ado_iteration_is_older "$iterpath" "$curiter" "$iterjson"; then
        fm_ado_set_iteration "$id" "$curiter" \
          || echo "fm-ado-backlog: warning: could not reparent WI $id to $curiter" >&2
      fi
    fi
    title=$(printf '%s' "$out" | fm_ado_jq -r --argjson wi "$id" \
      'first(.[] | select(.id == $wi)) | .fields."System.Title" // ""')
    printf '%s\t%s\n' "$id" "$title"
  done
}

# fm_ado_has_open_predecessor <wi>  -> 0 if any Predecessor link is not Closed.
# Fail-safe: on a read error we cannot prove the blockers are closed, so treat
# the task as blocked (return 0) rather than risk dispatching still-blocked work.
fm_ado_has_open_predecessor() {
  local wi=$1 out preds pid pstate
  out=$(fm_ado_az boards work-item show --id "$wi" --org "$FM_ADO_ORG" \
    --expand relations -o json 2>/dev/null) || return 0
  preds=$(printf '%s' "$out" | fm_ado_jq -r \
    '[.relations[]? | select(.rel=="System.LinkTypes.Dependency-Reverse") | .url | split("/") | last] | .[]' 2>/dev/null || true)
  [ -n "$preds" ] || return 1
  for pid in $preds; do
    pstate=$(fm_ado_wi_field "$pid" System.State 2>/dev/null || echo "")
    [ "$pstate" = Closed ] || return 0
  done
  return 1
}

# --- verb: render / refresh ------------------------------------------------
# Bounded reconcile: for each cached item, read its live System.Rev; when it
# changed, refresh the cached state/rev/title. Cheap change detection - no full
# field diff. A missing WI (deleted) is dropped from the cache.
cmd_render() {
  require_jq
  local cache ids id wi out rev state title
  cache=$(fm_ado_cache_path "$DATA")
  [ -f "$cache" ] || { echo "no cache to render"; return 0; }
  if ! fm_ado_ready; then
    echo "fm-ado-backlog: ADO unreachable; cache left as-is (read-only)" >&2
    return 0
  fi
  ids=$(fm_ado_jq -r '.items | keys[]' "$cache" 2>/dev/null || true)
  for id in $ids; do
    wi=$(fm_ado_cache_get_wi "$DATA" "$id" 2>/dev/null || true)
    [ -n "$wi" ] || continue
    out=$(fm_ado_az boards work-item show --id "$wi" --org "$FM_ADO_ORG" -o json 2>/dev/null) || {
      echo "fm-ado-backlog: WI $wi (=$id) unreadable; dropping from cache" >&2
      fm_ado_cache_remove "$DATA" "$id" || true
      continue
    }
    rev=$(printf '%s' "$out" | fm_ado_jq -r '.fields."System.Rev" // 0')
    state=$(printf '%s' "$out" | fm_ado_jq -r '.fields."System.State" // ""')
    title=$(printf '%s' "$out" | fm_ado_jq -r '.fields."System.Title" // ""')
    fm_ado_cache_set_rev "$DATA" "$id" "$rev" || true
    fm_ado_cache_set_field "$DATA" "$id" state "$state" || true
    fm_ado_cache_set_field "$DATA" "$id" title "$title" || true
    fm_ado_cache_set_field "$DATA" "$id" updated "$(now_iso)" || true
  done
  echo "render: reconciled $(printf '%s\n' "$ids" | grep -c . || true) item(s) from ADO"
}

# --- verb: resolve ---------------------------------------------------------
cmd_resolve_id() {
  local id=${1:-}
  [ -n "$id" ] || die "resolve-id: missing <id>"
  require_jq
  fm_ado_cache_get_wi "$DATA" "$id"
}
cmd_resolve_wi() {
  local wi=${1:-}
  [ -n "$wi" ] || die "resolve-wi: missing <wi>"
  require_jq
  fm_ado_cache_get_id "$DATA" "$wi"
}

# --- verb: migrate ---------------------------------------------------------
# Reconcile the old per-project-model work items into the new Epic/Story shape.
# Opt-in and explicit: supply the legacy ids via --us/--task/--repo flags or
# config/ado-backend.env (FM_ADO_LEGACY_US/TASK/REPO). With no ids configured and
# no flags, this makes no ADO writes. Idempotent: safe to run repeatedly;
# re-running once the shape is correct makes no ADO writes.
cmd_migrate() {
  local us
  while [ $# -gt 0 ]; do
    case "$1" in
      --us) FM_ADO_LEGACY_US=$2; shift 2 ;;
      --task) FM_ADO_LEGACY_TASK=$2; shift 2 ;;
      --repo) FM_ADO_LEGACY_REPO=$2; shift 2 ;;
      *) die "migrate: unknown flag $1" ;;
    esac
  done
  if [ -z "$FM_ADO_LEGACY_US" ]; then
    echo "migrate: nothing to reconcile (no legacy work items configured)"
    return 0
  fi
  require_jq
  require_ready
  us=$(fm_ado_migrate_legacy "$DATA") || die "migrate: legacy reconcile failed"
  if [ -n "$us" ]; then
    echo "migrate: reconciled legacy User Story $us under the Epic"
  else
    echo "migrate: nothing to reconcile (no legacy work items configured)"
  fi
}

# --- verb: bulk-set / bulk-set-iteration -----------------------------------
# Mass field change applied CONCURRENTLY across many work items (bounded
# parallelism + retry-on-throttle + batched verify-after-write). See the
# fm_ado_bulk_* helpers in fm-ado-lib.sh for the design and the 2026-07-17
# verification (sequential loop timed out at 2min; 16-worker fan-out did 192/193
# in 10.4s). The target id set is either an explicit id list or --tree <root> to
# target an Epic's whole subtree (Epic + all descendants).
#
# cmd_bulk_set <field> <value> [--tree <root-wi> | <id...>]
# cmd_bulk_set_iteration [--tree <root-wi> | <id...>] <iteration-path>  (thin
#   wrapper fixing field = System.IterationPath)
cmd_bulk_set() {
  local field=${1:-}; local value=${2:-}
  [ -n "$field" ] || die "bulk-set: missing <field>"
  [ -n "$value" ] || die "bulk-set: missing <value>"
  shift 2
  cmd_bulk_apply "$field" "$value" "$@"
}

cmd_bulk_set_iteration() {
  # Accept either: bulk-set-iteration --tree <root> <iteration-path>
  #            or: bulk-set-iteration <id...> <iteration-path>
  # The iteration path is always the LAST argument.
  [ "$#" -ge 1 ] || die "bulk-set-iteration: missing <iteration-path>"
  local -a rest=("$@")
  local last_idx=$(( ${#rest[@]} - 1 ))
  local iter=${rest[$last_idx]}
  unset 'rest[$last_idx]'
  [ -n "$iter" ] || die "bulk-set-iteration: empty <iteration-path>"
  cmd_bulk_apply "System.IterationPath" "$iter" "${rest[@]}"
}

# Shared bulk driver: resolve the target id set (--tree <root> expands the
# subtree; otherwise the remaining args are literal ids), fan out the concurrent
# write+verify, and report. Fails loudly (non-zero) if any id did not land.
cmd_bulk_apply() {
  require_jq
  require_ready
  local field=$1 value=$2; shift 2
  local -a ids=()
  if [ "${1:-}" = "--tree" ]; then
    local root=${2:-}
    [ -n "$root" ] || die "bulk-set: --tree needs a <root-wi>"
    local tree
    tree=$(fm_ado_subtree_ids "$root") || die "bulk-set: could not enumerate subtree under $root"
    [ -n "$tree" ] || die "bulk-set: subtree under $root is empty"
    local id
    while IFS= read -r id; do
      [ -n "$id" ] && ids+=("$id")
    done <<< "$tree"
  else
    [ "$#" -ge 1 ] || die "bulk-set: no target ids (pass ids or --tree <root>)"
    ids=("$@")
  fi
  local cap=${FM_ADO_BULK_CONCURRENCY:-$FM_ADO_DEFAULT_BULK_CONCURRENCY}
  echo "bulk-set: applying $field=$value to ${#ids[@]} item(s) with up to $cap concurrent workers (verify-after-write ON)" >&2
  local result rc=0
  result=$(fm_ado_bulk_set "$field" "$value" "${ids[@]}") || rc=$?
  # Surface every result line; count and report stragglers loudly.
  printf '%s\n' "$result"
  local failed
  failed=$(printf '%s\n' "$result" | awk -F'\t' '$2!="ok"{c++} END{print c+0}')
  if [ "$rc" -ne 0 ] || [ "$failed" -gt 0 ]; then
    echo "bulk-set: FAILED - $failed of ${#ids[@]} item(s) did not land (see mismatch/write-failed lines above)" >&2
    return 1
  fi
  echo "bulk-set: OK - all ${#ids[@]} item(s) set and verified" >&2
  return 0
}

main() {
  [ $# -ge 1 ] || die "usage: fm-ado-backlog.sh <verb> [args]; see the header"
  fm_ado_load_config "$CONFIG"
  local verb=$1; shift
  case "$verb" in
    add) cmd_add "$@" ;;
    add-child) cmd_add_child "$@" ;;
    start) cmd_start "$@" ;;
    done) cmd_done "$@" ;;
    block) cmd_block "$@" ;;
    unblock) cmd_unblock "$@" ;;
    show) cmd_show "$@" ;;
    update) cmd_update "$@" ;;
    ready) cmd_ready "$@" ;;
    render) cmd_render "$@" ;;
    migrate) cmd_migrate "$@" ;;
    resolve-id) cmd_resolve_id "$@" ;;
    resolve-wi) cmd_resolve_wi "$@" ;;
    bulk-set) cmd_bulk_set "$@" ;;
    bulk-set-iteration) cmd_bulk_set_iteration "$@" ;;
    ready-state) fm_ado_tooling_state ;;
    *) die "unknown verb: $verb" ;;
  esac
}

main "$@"
