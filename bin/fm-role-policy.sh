#!/usr/bin/env bash
# Enforce tracked external-write boundaries for a named persistent role.
# Usage: fm-role-policy.sh check <role-id> <post-review|vote|merge-ado> [--explicit]
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}
export FM_ROOT

# shellcheck source=bin/fm-fleet-lib.sh
. "$SCRIPT_DIR/fm-fleet-lib.sh"

[ "${1:-}" = check ] || {
  printf 'usage: fm-role-policy.sh check <role-id> <post-review|vote|merge-ado> [--explicit]\n' >&2
  exit 2
}
[ "$#" -eq 3 ] || [ "$#" -eq 4 ] || {
  printf 'usage: fm-role-policy.sh check <role-id> <post-review|vote|merge-ado> [--explicit]\n' >&2
  exit 2
}
role=$2
action=$3
explicit=0
if [ "$#" -eq 4 ]; then
  [ "$4" = --explicit ] || { printf 'error: unknown role-policy option: %s\n' "$4" >&2; exit 2; }
  explicit=1
fi

case "$action" in
  post-review) field=reviewPost ;;
  vote) field=vote ;;
  merge-ado) field=mergeAdo ;;
  *) printf 'error: unknown role action: %s\n' "$action" >&2; exit 2 ;;
esac
policy=$(fm_fleet_action_policy "$role" "$field") || {
  printf 'error: no valid action policy for role %s action %s\n' "$role" "$action" >&2
  exit 1
}
case "$policy" in
  explicit-only)
    if [ "$explicit" -eq 1 ]; then
      printf 'allowed: %s %s by explicit routed request\n' "$role" "$action"
      exit 0
    fi
    printf 'denied: %s %s requires an explicit routed request\n' "$role" "$action" >&2
    exit 3
    ;;
  not-applicable|never)
    printf 'denied: %s %s is not authorized\n' "$role" "$action" >&2
    exit 3
    ;;
  *)
    printf 'error: unsupported action policy for %s %s: %s\n' "$role" "$action" "$policy" >&2
    exit 1
    ;;
esac
