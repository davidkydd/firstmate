#!/usr/bin/env bash
# Deterministic triage for the prreview secondmate's review-followup watch.
# The role keeps a durable "## Reviewed / watching" list in its home
# (data/prreview.md), one entry per already-reviewed PR pinned to the
# source tip it was reviewed against. This script does three side-effect-free things:
#
#   parse <file>   Emit one machine-readable line per "## Reviewed / watching"
#                  entry, so a caller can read that section's durable state.
#   rearm <file>   Reconstitute the full track-until-merge watch on restart/
#                  recovery: emit one re-arm directive per REVIEWED PR (any entry
#                  pinned with tip=, in ANY section), deduped by URL. This is the
#                  durable default - track-until-merge is not an opt-in a session
#                  can forget: once a PR is reviewed (recorded with a tip=), its
#                  watch is re-established automatically on every restart with no
#                  human step, even if its entry was never moved out of "## Queue".
#   decide ...     Given the recorded tip plus the PR's CURRENT live facts (status,
#                  current tip, optional explicit re-request), emit the triage
#                  decision: drop | re-review | silent. See
#                  .agents/skills/prreview/workflows/watch.md.
#
# It never touches the network and never calls az/ADO: the reviewing agent gathers
# the live facts (via ado-pr-cli.sh status) and feeds them in, exactly as
# fm-review-classify.sh takes a diff the agent already fetched. This keeps the
# triage decision deterministic, unit-testable, and safe to run anywhere.
#
# Watch-entry line format (one PR per line, in the "## Reviewed / watching" section):
#   - <full-PR-URL> tip=<source-commit-sha> reviewed=<YYYY-MM-DD>
# Only the URL and tip= are load-bearing for triage; reviewed= is a human note.
# Blank lines, non-list lines, and other Markdown sections are ignored, so the file
# can also carry a pending-review "## Queue" section and prose without confusing the
# parser.
set -eu

usage() {
  sed -n '2,31p' "$0" >&2
}

# --- parse: watch-list file -> machine lines --------------------------------

# Extract watch entries from the "## Reviewed / watching" section only. A list
# item is `- <url> tip=<sha> reviewed=<date>`; url and tip are required, reviewed
# is optional. Emits `url=<url> tip=<sha> reviewed=<date>` per valid entry.
cmd_parse() {
  local file=${1:-}
  [ -n "$file" ] || { echo "error: parse needs a watch-list file path" >&2; exit 2; }
  [ -f "$file" ] || { echo "error: watch-list file not found: $file" >&2; exit 2; }

  local line in_section=0 url tip reviewed
  while IFS= read -r line || [ -n "$line" ]; do
    # Section tracking: enter on the watching heading, leave on any other heading.
    case "$line" in
      '## Reviewed / watching'*) in_section=1; continue ;;
      '#'*) in_section=0; continue ;;
    esac
    [ "$in_section" -eq 1 ] || continue

    # Only list items concern us.
    case "$line" in
      '- '*) : ;;
      *) continue ;;
    esac

    # First whitespace-delimited token after the dash is the URL.
    url=$(printf '%s\n' "$line" | sed -n 's/^- *\([^ ]*\).*/\1/p')
    [ -n "$url" ] || continue
    tip=$(printf '%s\n' "$line" | sed -n 's/.*[[:space:]]tip=\([^ ]*\).*/\1/p')
    [ -n "$tip" ] || continue
    reviewed=$(printf '%s\n' "$line" | sed -n 's/.*[[:space:]]reviewed=\([^ ]*\).*/\1/p')

    printf 'url=%s tip=%s reviewed=%s\n' "$url" "$tip" "${reviewed:-unknown}"
  done < "$file"
}

# --- rearm: durable list -> restart re-arm plan -----------------------------

# Reconstitute the full track-until-merge watch on restart/recovery. Where parse
# is scoped to the "## Reviewed / watching" section, rearm is scoped to CONTENT:
# a reviewed PR is any list item pinned with a tip=, in ANY Markdown section. So
# a reviewed PR whose entry was never moved out of "## Queue" (e.g. a session
# that crashed after parking and delivering its report but before the move) is still re-armed
# here rather than silently dropped - track-until-merge is the durable default,
# not an opt-in a session can forget. A pending-first-review Queue entry carries
# no tip=, so it is correctly not yet on the watch. Terminal PRs (merged/
# abandoned) are cleared by the first `decide` pass after re-arm, preserving the
# self-clearing behavior. Emits `rearm=<url> tip=<sha> reviewed=<date>` per
# reviewed PR, deduped by URL (first pin wins).
cmd_rearm() {
  local file=${1:-}
  [ -n "$file" ] || { echo "error: rearm needs a watch-list file path" >&2; exit 2; }
  [ -f "$file" ] || { echo "error: watch-list file not found: $file" >&2; exit 2; }

  local line url tip reviewed seen=' '
  while IFS= read -r line || [ -n "$line" ]; do
    # Any Markdown list item, in any section, is a candidate.
    case "$line" in
      '- '*) : ;;
      *) continue ;;
    esac

    # tip= is what marks an entry as reviewed (and thus watched); require it.
    tip=$(printf '%s\n' "$line" | sed -n 's/.*[[:space:]]tip=\([^ ]*\).*/\1/p')
    [ -n "$tip" ] || continue
    url=$(printf '%s\n' "$line" | sed -n 's/^- *\([^ ]*\).*/\1/p')
    [ -n "$url" ] || continue

    # Dedup by URL so the same PR listed twice re-arms exactly once.
    case "$seen" in
      *" $url "*) continue ;;
    esac
    seen="$seen$url "

    reviewed=$(printf '%s\n' "$line" | sed -n 's/.*[[:space:]]reviewed=\([^ ]*\).*/\1/p')
    printf 'rearm=%s tip=%s reviewed=%s\n' "$url" "$tip" "${reviewed:-unknown}"
  done < "$file"
}

# --- decide: live facts -> triage decision ----------------------------------

# Normalize an ADO PR status to one of: open | terminal | unknown.
#   completed / abandoned -> terminal (merged or closed; drop it silently)
#   active                -> open
#   anything else / empty -> unknown (treat conservatively as open)
normalize_status() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    completed|abandoned) echo terminal ;;
    active) echo open ;;
    *) echo unknown ;;
  esac
}

cmd_decide() {
  local status='' recorded_tip='' current_tip='' rerequest=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --status) status=${2:-}; shift 2 ;;
      --recorded-tip) recorded_tip=${2:-}; shift 2 ;;
      --current-tip) current_tip=${2:-}; shift 2 ;;
      --rerequest) rerequest=1; shift ;;
      *) echo "error: unknown decide arg: $1" >&2; exit 2 ;;
    esac
  done

  local norm decision reason
  norm=$(normalize_status "$status")

  if [ "$norm" = terminal ]; then
    # Merged or abandoned/completed: the review followup is over. Drop silently.
    decision=drop
    reason="pr $status - merged or closed, followup complete"
  elif [ "$rerequest" -eq 1 ]; then
    # Author explicitly re-requested review: always re-review, even if the tip
    # reads unchanged (a force-push or amend can reuse a sha in edge cases).
    decision=re-review
    reason="explicit re-review request"
  elif [ -n "$current_tip" ] && [ -n "$recorded_tip" ] && [ "$current_tip" != "$recorded_tip" ]; then
    # New commits since the last review: re-review against the current tip.
    decision=re-review
    reason="source tip advanced $recorded_tip -> $current_tip"
  else
    # Still open, unchanged (or the current tip is unknown, so we cannot prove a
    # change): stay silent. Routine polling and gate churn never wake anyone.
    decision=silent
    reason="open and unchanged since last review"
  fi

  printf 'decision=%s\nreason=%s\n' "$decision" "$reason"
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
  parse) shift; cmd_parse "$@" ;;
  rearm) shift; cmd_rearm "$@" ;;
  decide) shift; cmd_decide "$@" ;;
  *) echo "error: unknown command: $1 (expected: parse | rearm | decide)" >&2; usage; exit 2 ;;
esac
