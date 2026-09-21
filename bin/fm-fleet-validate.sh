#!/usr/bin/env bash
# Validate tracked persistent secondmate role definitions and referenced assets.
# Usage: fm-fleet-validate.sh [<current-role-id>]
#        fm-fleet-validate.sh home <current-role-id> <home> <parent-home>
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}
export FM_ROOT

# shellcheck source=bin/fm-fleet-lib.sh
. "$SCRIPT_DIR/fm-fleet-lib.sh"

if [ "${1:-}" = home ]; then
  [ "$#" -eq 4 ] || { printf 'usage: fm-fleet-validate.sh home <current-role-id> <home> <parent-home>\n' >&2; exit 2; }
  id=$2
  home=$3
  parent=$4
  path=$(fm_fleet_entry_path "$id") || {
    printf 'error: %s\n' "${FM_FLEET_ERROR:-no valid persistent-role definition for $id}" >&2
    exit 1
  }
  [ -d "$home" ] && [ ! -L "$home" ] || { printf 'error: unsafe persistent-role home: %s\n' "$home" >&2; exit 1; }
  [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] \
    && [ "$(cat "$home/.fm-secondmate-home")" = "$id" ] \
    || { printf 'error: persistent-role identity mismatch for %s\n' "$home" >&2; exit 1; }
  charter="$home/data/charter.md"
  [ -f "$charter" ] && [ ! -L "$charter" ] || { printf 'error: persistent-role charter is unavailable: %s\n' "$charter" >&2; exit 1; }
  role_text=$(jq -r '.charter' "$path") || exit 1
  grep -Fqx "$role_text" "$charter" || { printf 'error: persistent-role charter is not generated from the current %s definition\n' "$id" >&2; exit 1; }
  grep -Fq "$parent/state/$id.status" "$charter" || { printf 'error: persistent-role charter has the wrong parent status channel for %s\n' "$id" >&2; exit 1; }
  grep -Fq "$parent/state/$id.inbox" "$charter" || { printf 'error: persistent-role charter has the wrong parent instruction inbox for %s\n' "$id" >&2; exit 1; }
  if grep -Eq 'fm-ado-pr-review\.status|fm-ado-pr-watch\.status|/aks-veritas-dev(/|$)' "$charter"; then
    printf 'error: persistent-role charter contains a retired id or source path for %s\n' "$id" >&2
    exit 1
  fi
  case "$id" in
    prreview) legacy_watch="$home/data/fm-ado-pr-review.md" ;;
    prbabysit) legacy_watch="$home/data/ado-pr-watch.md" ;;
    *) legacy_watch= ;;
  esac
  [ -z "$legacy_watch" ] || [ ! -e "$legacy_watch" ] || {
    printf 'error: persistent-role home retains a legacy durable watch path: %s\n' "$legacy_watch" >&2
    exit 1
  }
  printf 'valid: %s home\n' "$id"
  exit 0
fi

case "$#" in
  0)
    if ! fm_fleet_validate_all; then
      printf 'error: %s\n' "${FM_FLEET_ERROR:-fleet role validation failed}" >&2
      exit 1
    fi
    printf 'valid: tracked persistent-role definitions\n'
    ;;
  1)
    if ! path=$(fm_fleet_entry_path_unchecked "$1"); then
      printf 'error: no persistent-role definition for %s\n' "$1" >&2
      exit 1
    fi
    if ! fm_fleet_entry_valid "$path" "$1"; then
      printf 'error: %s\n' "${FM_FLEET_ERROR:-fleet role validation failed}" >&2
      exit 1
    fi
    printf 'valid: %s\n' "$1"
    ;;
  *)
    printf 'usage: fm-fleet-validate.sh [<current-role-id>] | home <current-role-id> <home> <parent-home>\n' >&2
    exit 2
    ;;
esac
