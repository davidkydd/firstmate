#!/usr/bin/env bash
# fm-secondmates-projection.sh - project tracked fleet/agents/<id>.json definitions onto
# the private secondmate registry (data/secondmates.md).
#
# The registry stays the PRIVATE instantiation: it keeps each home's own home: path, added
# date, and cloned projects list. The DEFINITION half - the summary and routing scope - is
# projected from the tracked fleet entry, so those two fields have one source of truth
# (fleet/) instead of drifting in a hand-maintained registry line. Lines whose id has no
# fleet entry are left exactly as-is (additive: an un-migrated secondmate is untouched).
#
# The on-disk FORMAT is unchanged, so every reader (session-start digest, routing,
# liveness) that greps "^- <id>( |$)" keeps working with no change. Writes go through the
# same locked read-modify-write primitive as add/remove (bin/fm-secondmates-lib.sh), so a
# regenerate can never race a concurrent spawn or teardown.
#
# Registry line format (owned by secondmate-provisioning; consumed here unchanged):
#   - <id> - <summary> (home: <home>; scope: <scope>; projects: <csv>; added <date>)
#
# Usage:
#   fm-secondmates-projection.sh line <id> <home> <added> <projects-csv>
#       Print the projected registry line for <id> from its fleet entry + the given
#       private fields. Exit 1 (print nothing) when <id> has no fleet entry.
#   fm-secondmates-projection.sh regenerate [<reg>]
#       Rewrite every line in <reg> (default: this home's data/secondmates.md) whose id
#       has a fleet entry, re-projecting summary/scope while preserving home/added/projects.
#       Prints one "reprojected: <id>" / "unchanged: <id>" / "no-entry: <id>" line each.
#   fm-secondmates-projection.sh check [<reg>]
#       Dry-run: report drift (exit 3 if any line would change) without writing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_ROOT
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-secondmate-charter-lib.sh
. "$SCRIPT_DIR/fm-secondmate-charter-lib.sh"
# shellcheck source=bin/fm-secondmates-lib.sh
. "$SCRIPT_DIR/fm-secondmates-lib.sh"
# The fleet definition reader (fm_fleet_charter_summary / fm_fleet_routing_scope) is
# sourced explicitly here: on this fork the charter lib does not pull it in transitively.
# shellcheck source=bin/fm-fleet-lib.sh
. "$SCRIPT_DIR/fm-fleet-lib.sh"

# projected_line <id> <home> <added> <projects_csv>: compose the registry line with
# summary/scope taken from the fleet entry, normalized identically to write_registry
# (fleet value | normalize_registry_text). Return 1 when there is no entry for <id>.
projected_line() {
  local id=$1 home=$2 added=$3 projects=$4 summary scope
  summary=$(fm_fleet_charter_summary "$id") || return 1
  scope=$(fm_fleet_routing_scope "$id") || return 1
  summary=$(printf '%s\n' "$summary" | normalize_registry_text)
  scope=$(printf '%s\n' "$scope" | normalize_registry_text)
  printf -- '- %s - %s (home: %s; scope: %s; projects: %s; added %s)\n' \
    "$id" "$summary" "$home" "$scope" "$projects" "$added"
}

# parse_line <line>: split a registry line into id/home/projects/added via the fixed
# "(home: … ; scope: … ; projects: … ; added …)" delimiters, using only parameter
# expansion (no external tools). Sets PARSE_ID/PARSE_HOME/PARSE_PROJECTS/PARSE_ADDED.
# Returns 1 when the line is not a registry entry line.
parse_line() {
  local line=$1 rest after meta rest3
  case "$line" in
    '- '*' (home: '*'; scope: '*'; projects: '*'; added '*')') : ;;
    *) return 1 ;;
  esac
  rest=${line#- }
  PARSE_ID=${rest%% - *}
  after=${rest#* - }
  meta=${after##*(home: }
  meta=${meta%)}
  PARSE_HOME=${meta%%; scope: *}
  rest3=${meta#*; projects: }
  PARSE_PROJECTS=${rest3%%; added *}
  PARSE_ADDED=${rest3#*; added }
  [ -n "$PARSE_ID" ] || return 1
}

# process <reg> <write>: walk <reg>, re-project each line whose id has a fleet entry.
# With <write>=1, update changed lines through the locked primitive; with <write>=0,
# report only. Returns 3 when at least one line would change (used by `check`).
process() {
  local reg=$1 write=$2 line drift=0 new
  local lines=()
  [ -f "$reg" ] || { echo "no registry at $reg"; return 0; }
  # Snapshot every line first, so the locked rewrites below never read and write the
  # same file in one pipeline (each secondmates_add mv's a fresh inode into place).
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
  done < "$reg"
  for line in "${lines[@]+"${lines[@]}"}"; do
    parse_line "$line" || continue
    if ! new=$(projected_line "$PARSE_ID" "$PARSE_HOME" "$PARSE_ADDED" "$PARSE_PROJECTS"); then
      echo "no-entry: $PARSE_ID"
      continue
    fi
    if [ "$new" = "$line" ]; then
      echo "unchanged: $PARSE_ID"
      continue
    fi
    drift=1
    if [ "$write" -eq 1 ]; then
      secondmates_add "$reg" "$PARSE_ID" "$new" || { echo "error: could not rewrite $PARSE_ID" >&2; return 1; }
      echo "reprojected: $PARSE_ID"
    else
      echo "would-reproject: $PARSE_ID"
    fi
  done
  [ "$drift" -eq 0 ] || return 3
  return 0
}

cmd=${1:-}
case "$cmd" in
  -h|--help)
    sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  line)
    [ $# -eq 5 ] || { echo "usage: fm-secondmates-projection.sh line <id> <home> <added> <projects-csv>" >&2; exit 2; }
    projected_line "$2" "$3" "$4" "$5" || exit 1
    ;;
  regenerate)
    reg=${2:-$DATA/secondmates.md}
    process "$reg" 1
    rc=$?
    [ "$rc" -eq 3 ] && rc=0
    exit "$rc"
    ;;
  check)
    reg=${2:-$DATA/secondmates.md}
    process "$reg" 0
    exit $?
    ;;
  *)
    echo "usage: fm-secondmates-projection.sh {line <id> <home> <added> <projects-csv>|regenerate [<reg>]|check [<reg>]}" >&2
    exit 2
    ;;
esac
