#!/usr/bin/env bash
# Install or run the trusted periodic reminder for a tracked persistent role.
# Usage: fm-role-periodic-check.sh sync <role-id>
#        fm-role-periodic-check.sh arm <role-id>
#        fm-role-periodic-check.sh check <role-id>
#        fm-role-periodic-check.sh disarm
# The check remains registered across restarts, but prints one line only when a
# configured durable watch section contains an active URL item and the role's
# cadence has elapsed. An absent or empty watch is silent and resets the cadence.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
export FM_ROOT

# shellcheck source=bin/fm-fleet-lib.sh
. "$SCRIPT_DIR/fm-fleet-lib.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

home_valid_for_role() { # <id>
  local id=$1 marker
  [ -d "$FM_HOME" ] && [ ! -L "$FM_HOME" ] || return 1
  marker="$FM_HOME/.fm-secondmate-home"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  [ "$(cat "$marker" 2>/dev/null)" = "$id" ] || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
}

watch_has_active_item() { # <file> <newline-separated-sections>
  local file=$1 sections=$2
  awk -v sections="$sections" '
    BEGIN {
      n=split(sections, values, "|")
      for (i=1; i<=n; i++) wanted["## " values[i]]=1
    }
    /^## / { active=($0 in wanted); next }
    active && /^[[:space:]]*-[[:space:]]+https?:\/\// { found=1; exit }
    active && /^https?:\/\// { found=1; exit }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

role_disarm() {
  if [ -e "$STATE/role-periodic.check.sh" ] || [ -L "$STATE/role-periodic.check.sh" ] \
    || [ -e "$STATE/role-periodic.check-trust" ] || [ -L "$STATE/role-periodic.check-trust" ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" role-periodic >/dev/null || return 1
  fi
  rm -f -- "$STATE"/.role-periodic-last-* 2>/dev/null || true
  printf 'disarmed: role periodic check\n'
}

role_arm() { # <id>
  local id=$1 cadence watch_file sections shim tmp
  home_valid_for_role "$id" || {
    printf 'error: %s is not a validated secondmate home for %s\n' "$FM_HOME" "$id" >&2
    return 1
  }
  cadence=$(fm_fleet_periodic_cadence "$id") || {
    printf 'error: role %s has no valid periodic definition\n' "$id" >&2
    return 1
  }
  watch_file=$(fm_fleet_periodic_watch_file "$id") || return 1
  sections=$(fm_fleet_periodic_watch_sections "$id" | paste -sd '|' -) || return 1
  [ -n "$cadence" ] && [ -n "$watch_file" ] && [ -n "$sections" ] || return 1
  shim="$STATE/role-periodic.check.sh"
  if [ -e "$shim" ] || [ -L "$shim" ] || [ -e "$STATE/role-periodic.check-trust" ] || [ -L "$STATE/role-periodic.check-trust" ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" role-periodic >/dev/null || return 1
  fi
  umask 077
  tmp=$(mktemp "$STATE/.role-periodic-check.XXXXXX") || return 1
  trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export FM_HOME=%s\n' "$(shell_quote "$FM_HOME")"
    printf 'exec %s check %s\n' "$(shell_quote "$FM_HOME/bin/fm-role-periodic-check.sh")" "$(shell_quote "$id")"
  } > "$tmp" || return 1
  chmod 0700 "$tmp" || return 1
  mv -f -- "$tmp" "$shim" || return 1
  tmp=
  trap - EXIT HUP INT TERM
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" role-periodic >/dev/null || {
    rm -f -- "$shim"
    return 1
  }
  printf 'armed: role periodic check for %s every %s seconds\n' "$id" "$cadence"
}

role_check() { # <id>
  local id=$1 cadence watch_rel watch sections marker now last lock ttl age reclaim
  home_valid_for_role "$id" || exit 0
  cadence=$(fm_fleet_periodic_cadence "$id" 2>/dev/null) || exit 0
  watch_rel=$(fm_fleet_periodic_watch_file "$id" 2>/dev/null) || exit 0
  sections=$(fm_fleet_periodic_watch_sections "$id" 2>/dev/null | paste -sd '|' -) || exit 0
  case "$watch_rel" in data/*) ;; *) printf 'role-periodic-error: invalid watch path for %s\n' "$id"; exit 0 ;; esac
  case "$watch_rel" in *..*) printf 'role-periodic-error: invalid watch path for %s\n' "$id"; exit 0 ;; esac
  watch="$FM_HOME/$watch_rel"
  marker="$STATE/.role-periodic-last-$id"
  lock="$STATE/.role-periodic-check.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    # A live owner's lock dir is sub-second old; only reclaim one whose mtime
    # age proves its owner died (SIGKILL/power loss) without releasing it.
    ttl=${FM_ROLE_PERIODIC_LOCK_TTL:-900}
    case "$ttl" in '' | *[!0-9]*) exit 0 ;; esac
    age=$(fm_lock_age "$lock" 2>/dev/null) || exit 0
    [ "$age" -ge "$ttl" ] || exit 0
    reclaim="$lock.stale.$$"
    mv -- "$lock" "$reclaim" 2>/dev/null || exit 0
    rm -rf -- "$reclaim" 2>/dev/null || true
    mkdir "$lock" 2>/dev/null || exit 0
  fi
  ROLE_PERIODIC_LOCK=$lock
  trap 'rmdir "$ROLE_PERIODIC_LOCK" 2>/dev/null || true' EXIT HUP INT TERM
  if [ ! -e "$watch" ] && [ ! -L "$watch" ]; then
    rm -f -- "$marker" 2>/dev/null || true
    exit 0
  fi
  if [ ! -f "$watch" ] || [ -L "$watch" ]; then
    printf 'role-periodic-error: unsafe durable watch for %s\n' "$id"
    exit 0
  fi
  if ! watch_has_active_item "$watch" "$sections"; then
    rm -f -- "$marker" 2>/dev/null || true
    exit 0
  fi
  now=${FM_ROLE_PERIODIC_NOW:-$(date +%s)}
  case "$now" in '' | *[!0-9]*) exit 0 ;; esac
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    last=$(cat "$marker" 2>/dev/null || true)
    case "$last" in '' | *[!0-9]*) last=0 ;; esac
    [ "$now" -ge "$last" ] || exit 0
    [ "$((now - last))" -ge "$cadence" ] || exit 0
  fi
  printf '%s\n' "$now" > "$marker" || {
    printf 'role-periodic-error: cannot record cadence for %s\n' "$id"
    exit 0
  }
  chmod 0600 "$marker" 2>/dev/null || true
  printf 'role-maintenance: %s has recorded watch work due for a maintenance pass at=%s\n' "$id" "$now"
}

case "${1:-}" in
  sync)
    [ "$#" -eq 2 ] || { printf 'usage: fm-role-periodic-check.sh sync <role-id>\n' >&2; exit 2; }
    if fm_fleet_periodic_cadence "$2" >/dev/null 2>&1; then
      role_arm "$2"
    else
      role_disarm
    fi
    ;;
  arm)
    [ "$#" -eq 2 ] || { printf 'usage: fm-role-periodic-check.sh arm <role-id>\n' >&2; exit 2; }
    role_arm "$2"
    ;;
  check)
    [ "$#" -eq 2 ] || exit 0
    role_check "$2"
    ;;
  disarm)
    [ "$#" -eq 1 ] || { printf 'usage: fm-role-periodic-check.sh disarm\n' >&2; exit 2; }
    role_disarm
    ;;
  -h|--help|'')
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    printf 'usage: fm-role-periodic-check.sh {sync <role-id>|arm <role-id>|check <role-id>|disarm}\n' >&2
    exit 2
    ;;
esac
