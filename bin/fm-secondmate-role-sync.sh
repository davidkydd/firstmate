#!/usr/bin/env bash
# Regenerate one local tracked-role charter from the authoritative Firstmate tree.
# Usage: fm-secondmate-role-sync.sh <current-role-id>
# The command preserves private backlog, project, report, learning, and watch data.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
FM_HOME=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || { printf 'error: cannot resolve Firstmate home: %s\n' "$FM_HOME" >&2; exit 1; }
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
REG="$DATA/secondmates.md"

# shellcheck source=bin/fm-fleet-lib.sh
. "$SCRIPT_DIR/fm-fleet-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-secondmate-charter-lib.sh
. "$SCRIPT_DIR/fm-secondmate-charter-lib.sh"
# shellcheck source=bin/fm-secondmates-lib.sh
. "$SCRIPT_DIR/fm-secondmates-lib.sh"

[ "$#" -eq 1 ] || { printf 'usage: fm-secondmate-role-sync.sh <current-role-id>\n' >&2; exit 2; }
id=$1
"$SCRIPT_DIR/fm-fleet-validate.sh" "$id" >/dev/null
secondmate_registry_line_for_id "$REG" "$id" || { printf 'error: no registered secondmate %s\n' "$id" >&2; exit 1; }
[ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || {
  printf 'error: role charter sync currently requires a local secondmate home: %s\n' "$id" >&2
  exit 1
}
home=$SECONDMATE_REGISTRY_HOME
[ -d "$home" ] && [ ! -L "$home" ] || { printf 'error: unsafe secondmate home: %s\n' "$home" >&2; exit 1; }
[ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] \
  && [ "$(cat "$home/.fm-secondmate-home")" = "$id" ] \
  || { printf 'error: secondmate identity mismatch for %s\n' "$home" >&2; exit 1; }

origin=$(git -C "$home" remote get-url origin 2>/dev/null || true)
case "$origin" in file://*) origin=${origin#file://} ;; esac
case "$origin" in /*) origin=$(cd "$origin" 2>/dev/null && pwd -P || true) ;; esac
[ "$origin" = "$FM_ROOT" ] || {
  printf 'error: secondmate %s origin is %s, expected authoritative source %s\n' "$id" "${origin:-unset}" "$FM_ROOT" >&2
  exit 1
}
legacy_watch=
current_watch=
case "$id" in
  prreview) legacy_watch="$home/data/fm-ado-pr-review.md"; current_watch="$home/data/prreview.md" ;;
  prbabysit) legacy_watch="$home/data/ado-pr-watch.md"; current_watch="$home/data/prbabysit.md" ;;
esac
if [ -n "$legacy_watch" ] && [ -e "$legacy_watch" ] && [ -e "$current_watch" ]; then
  printf 'error: both legacy and current durable watch files exist for %s; reconcile them before role sync\n' "$id" >&2
  exit 1
fi

mkdir -p "$DATA/$id" "$STATE"
parent_brief="$DATA/$id/brief.md"
home_charter="$home/data/charter.md"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-role-charter.XXXXXX")
committed=0
parent_existed=0
home_existed=0
registry_existed=0
watch_migrated=0
cleanup() {
  if [ "$committed" -eq 0 ]; then
    if [ "$parent_existed" -eq 1 ]; then cp "$tmp/parent.before" "$parent_brief" 2>/dev/null || true; else rm -f -- "$parent_brief" 2>/dev/null || true; fi
    if [ "$home_existed" -eq 1 ]; then cp "$tmp/home.before" "$home_charter" 2>/dev/null || true; else rm -f -- "$home_charter" 2>/dev/null || true; fi
    if [ "$registry_existed" -eq 1 ]; then cp "$tmp/registry.before" "$REG" 2>/dev/null || true; fi
    if [ "$watch_migrated" -eq 1 ] && [ -e "$current_watch" ] && [ ! -e "$legacy_watch" ]; then mv "$current_watch" "$legacy_watch" 2>/dev/null || true; fi
  fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT HUP INT TERM
if [ -f "$parent_brief" ]; then parent_existed=1; cp "$parent_brief" "$tmp/parent.before"; fi
if [ -f "$home_charter" ]; then home_existed=1; cp "$home_charter" "$tmp/home.before"; fi
if [ -f "$REG" ]; then registry_existed=1; cp "$REG" "$tmp/registry.before"; fi
mkdir -p "$tmp/data" "$tmp/state"
FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$tmp/data" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null
generated="$tmp/data/$id/brief.md"
[ -s "$generated" ] || { printf 'error: role charter generation produced no content for %s\n' "$id" >&2; exit 1; }

parent_tmp="$DATA/$id/.brief.md.role-sync.$$"
home_tmp="$home/data/.charter.md.role-sync.$$"
cp "$generated" "$parent_tmp"
cp "$generated" "$home_tmp"
mv -f -- "$parent_tmp" "$parent_brief"
mv -f -- "$home_tmp" "$home_charter"

summary=$(fm_fleet_charter_summary "$id" | normalize_registry_text)
scope=$(fm_fleet_routing_scope "$id" | normalize_registry_text)
line=$(printf -- '- %s - %s (home: %s; scope: %s; projects: %s; added %s)' \
  "$id" "$summary" "$home" "$scope" "$SECONDMATE_REGISTRY_PROJECTS" "$SECONDMATE_REGISTRY_ADDED")
secondmates_add "$REG" "$id" "$line"

if [ -n "$legacy_watch" ] && [ -e "$legacy_watch" ]; then
  [ -f "$legacy_watch" ] && [ ! -L "$legacy_watch" ] || { printf 'error: legacy watch file is unsafe: %s\n' "$legacy_watch" >&2; exit 1; }
  mv "$legacy_watch" "$current_watch"
  watch_migrated=1
fi
"$SCRIPT_DIR/fm-fleet-validate.sh" home "$id" "$home" "$FM_HOME" >/dev/null
FM_HOME="$home" "$home/bin/fm-role-periodic-check.sh" sync "$id" >/dev/null
committed=1
printf 'synchronized: %s charter and periodic role state from %s\n' "$id" "$FM_ROOT"
