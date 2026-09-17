#!/usr/bin/env bash
# fm-secondmate-rename.sh - rename a persistent secondmate's id in place.
#
# Renames <old-id> to <new-id> across every surface the id is load-bearing in, so a
# live secondmate can be renamed without the coupled, error-prone hand-edit that was the
# only path before this primitive existed. The herdr pane label is a pure function of the
# id (bin/backends/herdr.sh reorder("2ndmate-<id>"); bin/fm-backend.sh window label
# sm-<id>), so the label only re-derives once the id itself changes - which is exactly
# what this does.
#
# WHAT IT REBINDS (in the parent/main home selected by FM_HOME):
#   - data/secondmates.md         the registry line's id (locked, via fm-secondmates-lib.sh);
#                                 all other fields (summary, home, scope, projects, added,
#                                 and host/root for a remote route) are preserved verbatim.
#   - <home>/.fm-secondmate-home  the home identity marker that drives the herdr label.
#   - state/<old-id>.*            every id-keyed task sidecar (.meta/.status/.control-*),
#                                 renamed to state/<new-id>.*, with window=sm-<new-id>
#                                 rewritten inside the .meta.
#
# WHAT IT DOES NOT DO:
#   - It does NOT rename the home DIRECTORY (the registry home: path is unchanged): the
#     directory name is not load-bearing for the label or routing, and renaming a
#     treehouse-leased home would risk the lease. Only the id-derived surfaces move.
#   - It does NOT relaunch the running agent by default. The label is read fresh from the
#     marker on every backend call, but the ALREADY-RUNNING workspace/pane was created
#     under the old label, so a relaunch is what re-homes it into 2ndmate-<new-id>. A
#     relaunch is disruptive and belongs to the supervising firstmate, so this tool prints
#     the exact relaunch command instead of stopping a live agent itself. Pass --relaunch
#     (with --harness) to run it here.
#
# Idempotent: each rebind step is individually guarded, so re-running after a partial
# rebind completes the rest. Fails closed - it refuses when <old-id> is absent, <new-id>
# already exists, or <new-id> is not a valid slug - rather than half-creating a second
# identity.
#
# Usage:
#   fm-secondmate-rename.sh <old-id> <new-id> [--relaunch --harness <name>]
#   fm-secondmate-rename.sh --help
#
# Exit codes: 0 success; 2 usage/validation; 3 old-id absent; 4 new-id already exists;
# 1 a rebind step failed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-secondmates-lib.sh
. "$SCRIPT_DIR/fm-secondmates-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/secondmates.md"

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"
}

# fm_window_label-equivalent: the window label strips a single leading "fm-" from the id
# (bin/fm-backend.sh fm_window_label), so fm-pr-watch -> sm-pr-watch, deckhand -> sm-deckhand.
window_label_for() {
  local id=$1
  printf 'sm-%s' "${id#fm-}"
}

is_slug() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

OLD_ID=
NEW_ID=
DO_RELAUNCH=0
RELAUNCH_HARNESS=

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --relaunch) DO_RELAUNCH=1 ;;
    --harness) shift; RELAUNCH_HARNESS=${1-} ;;
    --) shift; break ;;
    -*) echo "error: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -z "$OLD_ID" ]; then OLD_ID=$1
      elif [ -z "$NEW_ID" ]; then NEW_ID=$1
      else echo "error: unexpected argument: $1" >&2; exit 2
      fi
      ;;
  esac
  shift || true
done

[ -n "$OLD_ID" ] && [ -n "$NEW_ID" ] || { echo "error: need <old-id> <new-id>" >&2; usage >&2; exit 2; }
if ! is_slug "$OLD_ID"; then echo "error: <old-id> is not a valid slug: $OLD_ID" >&2; exit 2; fi
if ! is_slug "$NEW_ID"; then echo "error: <new-id> is not a valid slug: $NEW_ID" >&2; exit 2; fi
[ "$OLD_ID" != "$NEW_ID" ] || { echo "error: <old-id> and <new-id> are the same: $OLD_ID" >&2; exit 2; }
if [ "$DO_RELAUNCH" -eq 1 ] && [ -z "$RELAUNCH_HARNESS" ]; then
  echo "error: --relaunch requires --harness <name>" >&2; exit 2
fi

# Resolve the current line and the home path BEFORE any mutation. Prefer the old id, but
# tolerate a re-run where the registry step already renamed to <new-id> (idempotency).
OLD_LINE=$(secondmates_get "$REG" "$OLD_ID" 2>/dev/null || true)
NEW_LINE_EXISTING=$(secondmates_get "$REG" "$NEW_ID" 2>/dev/null || true)
if [ -z "$OLD_LINE" ] && [ -z "$NEW_LINE_EXISTING" ]; then
  echo "error: no registry entry for '$OLD_ID' (nor an already-renamed '$NEW_ID') in $REG" >&2
  exit 3
fi

HOME_PATH=
if [ -n "$OLD_LINE" ]; then
  if ! secondmate_registry_parse_line "$OLD_LINE"; then
    echo "error: could not parse registry line for '$OLD_ID': $OLD_LINE" >&2
    exit 1
  fi
  HOME_PATH=$SECONDMATE_REGISTRY_HOME
  # Recompose the line with the new id, preserving every other field verbatim.
  if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
    NEW_LINE=$(printf -- '- %s - %s (host: %s; root: %s; home: %s; scope: %s; projects: %s; added %s)' \
      "$NEW_ID" "$SECONDMATE_REGISTRY_SUMMARY" "$SECONDMATE_REGISTRY_HOST" "$SECONDMATE_REGISTRY_ROOT" \
      "$SECONDMATE_REGISTRY_HOME" "$SECONDMATE_REGISTRY_SCOPE" "$SECONDMATE_REGISTRY_PROJECTS" "$SECONDMATE_REGISTRY_ADDED")
  else
    NEW_LINE=$(printf -- '- %s - %s (home: %s; scope: %s; projects: %s; added %s)' \
      "$NEW_ID" "$SECONDMATE_REGISTRY_SUMMARY" "$SECONDMATE_REGISTRY_HOME" \
      "$SECONDMATE_REGISTRY_SCOPE" "$SECONDMATE_REGISTRY_PROJECTS" "$SECONDMATE_REGISTRY_ADDED")
  fi
  # Registry rename under the shared lock. secondmates_rename returns 4 if <new-id>
  # already has its own (different) entry, which is a genuine collision, not this rename.
  if ! secondmates_rename "$REG" "$OLD_ID" "$NEW_ID" "$NEW_LINE"; then
    rc=$?
    if [ "$rc" -eq 4 ]; then
      echo "error: '$NEW_ID' already has a registry entry; refusing to collide" >&2
      exit 4
    fi
    echo "error: registry rename failed ($rc)" >&2
    exit 1
  fi
  echo "renamed registry entry: $OLD_ID -> $NEW_ID"
else
  # Registry already renamed on a prior run; recover the home from the new line.
  if ! secondmate_registry_parse_line "$NEW_LINE_EXISTING"; then
    echo "error: could not parse existing registry line for '$NEW_ID'" >&2
    exit 1
  fi
  HOME_PATH=$SECONDMATE_REGISTRY_HOME
  echo "registry entry already named '$NEW_ID'; reconciling marker and state"
fi

# Rebind the home identity marker (drives the herdr label). Guarded/idempotent: only
# rewrite when it currently reads the old id.
MARKER="$HOME_PATH/.fm-secondmate-home"
if [ -f "$MARKER" ]; then
  marker_id=$(tr -d '[:space:]' < "$MARKER" 2>/dev/null || true)
  if [ "$marker_id" = "$OLD_ID" ]; then
    printf '%s\n' "$NEW_ID" > "$MARKER" || { echo "error: could not rewrite marker $MARKER" >&2; exit 1; }
    echo "rebound home marker: $MARKER ($OLD_ID -> $NEW_ID)"
  elif [ "$marker_id" = "$NEW_ID" ]; then
    echo "home marker already reads '$NEW_ID'; skipping"
  else
    echo "warning: home marker $MARKER reads '$marker_id' (neither old nor new id); left unchanged" >&2
  fi
else
  echo "warning: no home marker at $MARKER; skipping (a remote route keeps its marker on the remote host)" >&2
fi

# Move every id-keyed state sidecar in the parent home's state/, then fix window= in .meta.
moved=0
if [ -d "$STATE" ]; then
  shopt -s nullglob
  for src in "$STATE/$OLD_ID".*; do
    suffix=${src#"$STATE/$OLD_ID"}   # includes the leading dot, e.g. ".meta"
    dst="$STATE/$NEW_ID$suffix"
    if [ -e "$dst" ]; then
      echo "warning: $dst already exists; leaving $src in place" >&2
      continue
    fi
    mv "$src" "$dst" || { echo "error: could not move $src -> $dst" >&2; exit 1; }
    moved=$((moved + 1))
  done
  shopt -u nullglob
fi
[ "$moved" -eq 0 ] || echo "moved $moved state sidecar(s): state/$OLD_ID.* -> state/$NEW_ID.*"

META="$STATE/$NEW_ID.meta"
if [ -f "$META" ]; then
  new_window=$(window_label_for "$NEW_ID")
  if grep -q '^window=' "$META" 2>/dev/null; then
    tmp="$META.rename.$$"
    if sed "s|^window=.*|window=$new_window|" "$META" > "$tmp" 2>/dev/null && mv "$tmp" "$META"; then
      echo "updated meta window=: $META ($new_window)"
    else
      rm -f "$tmp" 2>/dev/null || true
      echo "warning: could not rewrite window= in $META" >&2
    fi
  fi
fi

echo "done: secondmate '$OLD_ID' renamed to '$NEW_ID' (home unchanged: $HOME_PATH)"

RELAUNCH_CMD="bin/fm-control.sh $NEW_ID relaunch --harness <name>"
if [ "$DO_RELAUNCH" -eq 1 ]; then
  echo "relaunching to re-home the running agent under the new label..."
  "$SCRIPT_DIR/fm-control.sh" "$NEW_ID" relaunch --harness "$RELAUNCH_HARNESS"
else
  echo "next: relaunch the running agent so its herdr pane re-homes to 2ndmate-$NEW_ID:"
  echo "  $RELAUNCH_CMD"
fi
