#!/usr/bin/env bash
# fm-teams-link.sh - bind a Teams request to Firstmate work and publish its terminal result.
#
# Usage:
#   fm-teams-link.sh link <request-id> <task-id>
#   fm-teams-link.sh request-for-task <task-id>
#   fm-teams-link.sh complete <task-id> --outcome completed|refused|failed --text-file <path|->
#
# `link` appends one `teams_request=` field to existing task metadata under the
# metadata lock. It never creates a task, guesses a request, or rewrites another
# metadata field. `complete` resolves only that recorded request and delegates
# the typed result and durable queue send to fm-teams-connector.sh.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
FM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
FM_HOME=${FM_HOME:-$FM_ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

die() { printf 'fm-teams-link: %s\n' "$*" >&2; exit 1; }
valid_request() {
  local value=$1 hash
  case "$value" in tm_*) ;; *) return 1 ;; esac
  hash=${value#tm_}
  [ "${#hash}" -eq 64 ] || return 1
  case "$hash" in *[!a-f0-9]*) return 1 ;; esac
}
valid_task() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

request_for_task() {
  local task=$1 meta="$STATE/$1.meta" request
  valid_task "$task" || die "invalid task id"
  [ -f "$meta" ] || die "task metadata not found: $task"
  request=$(fm_meta_get "$meta" teams_request)
  [ -n "$request" ] || return 1
  valid_request "$request" || die "task has a malformed Teams request binding"
  printf '%s\n' "$request"
}

cmd_link() {
  local request=${1:-} task=${2:-} meta lock existing
  [ "$#" -eq 2 ] || die "usage: fm-teams-link.sh link <request-id> <task-id>"
  valid_request "$request" || die "invalid Teams request id"
  valid_task "$task" || die "invalid task id"
  [ -f "$STATE/teams/requests/$request.json" ] || die "Teams request is not captured in this home: $request"
  node -e '
    const fs = require("node:fs");
    const record = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (record?.approvalStatus !== "approved") process.exit(1);
  ' "$STATE/teams/requests/$request.json" \
    || die "Teams request requires trusted-local approval before task binding: $request"
  meta="$STATE/$task.meta"
  [ -f "$meta" ] || die "task metadata not found: $task"
  lock=$(fm_meta_lock_path "$meta") || die "could not resolve the task metadata lock"
  fm_lock_acquire_wait "$lock" || die "could not lock task metadata"
  if [ ! -f "$meta" ]; then
    fm_lock_release "$lock"
    die "task metadata not found: $task"
  fi
  existing=$(fm_meta_get "$meta" teams_request)
  if [ -n "$existing" ] && [ "$existing" != "$request" ]; then
    fm_lock_release "$lock"
    die "task is already bound to a different Teams request"
  fi
  if [ -z "$existing" ]; then
    printf 'teams_request=%s\n' "$request" >> "$meta" || {
      fm_lock_release "$lock"
      die "could not record the Teams request binding"
    }
  fi
  fm_lock_release "$lock"
  printf 'linked %s %s\n' "$request" "$task"
}

cmd_complete() {
  local task=${1:-} request arg
  [ -n "$task" ] || die "usage: fm-teams-link.sh complete <task-id> --outcome <outcome> --text-file <path|->"
  shift
  for arg in "$@"; do
    [ "$arg" != "--request-id" ] || die "complete does not accept --request-id"
  done
  request=$(request_for_task "$task") || die "task has no Teams request binding: $task"
  exec "$SCRIPT_DIR/fm-teams-connector.sh" publish-result --request-id "$request" "$@"
}

case "${1:-}" in
  link) shift; cmd_link "$@" ;;
  request-for-task) shift; [ "$#" -eq 1 ] || die "usage: fm-teams-link.sh request-for-task <task-id>"; request_for_task "$1" ;;
  complete) shift; cmd_complete "$@" ;;
  -h|--help|help|'') awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" ;;
  *) die "unknown subcommand: $1" ;;
esac
