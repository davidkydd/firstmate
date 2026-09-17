#!/usr/bin/env bash
# Static watcher program for a validated Azure DevOps PR poll sidecar.
#
# This is the ADO counterpart to bin/fm-pr-poll.sh. It replaces the older
# generated state/<id>.check.sh (which interpolated task and PR data straight
# into shell source) with a byte-static program that reads all of its inputs from
# a private sidecar and validates them with pure pattern-matching before any side
# effect, so task/PR data is never interpolated into executable shell.
#
# On each poll it does exactly what the fork's generated ADO check did, but from
# the sidecar rather than from interpolated source:
#   1. Re-queue any expired content gate (a build-backed policy whose
#      validDuration lapsed after its build was green) via the durable
#      bin/fm-scm-lib.sh `ado-requeue-expired` verb. Routine re-queues stay
#      silent so the watcher is not woken every poll.
#   2. Surface a genuinely-stuck content gate (rejected, or re-queue cap
#      exhausted) once per distinct stuck signature, de-duped via a private
#      state/<id>.ado-stuck-seen marker; config/ado-requeue.env's
#      FM_ADO_STUCK_GATE_RENOTIFY forces re-notify-every-poll.
#   3. Poll the PR merge state and emit exactly one `merged` line iff MERGED.
#
# GitHub PRs use bin/fm-pr-poll.sh instead; this variant is armed only for an ADO
# PR URL. See docs/ado-backend.md for the content-vs-human gate taxonomy.
#
# The sidecar (state/<id>.ado-pr-poll) holds, one field per line and nothing
# else:
#   line 1: pr url        (a canonical ADO PR URL)
#   line 2: worktree path (empty allowed; used for `az ... --detect` org lookup)
#   line 3: fm root       (the tracked code root that owns fm-scm-lib.sh)
#   line 4: state dir     (where the ledger, stuck-seen, and config live-scope)
#   line 5: config dir    (where ado-requeue.env is sourced from; empty allowed)
#
# The task id is not stored in the sidecar: under --validated it is passed as the
# 7th argument (from fm_scm_ado_poll_valid), and in the argless sidecar-driven
# path it is derived from this program's own <id>.check.sh name. It scopes the
# per-task ledger and stuck-seen markers (state/<id>.ado-requeue.ledger,
# state/<id>.ado-stuck-seen) so concurrent gates never share dedup state and
# fm-teardown.sh's id-prefixed cleanup reaches them.
set -u
LC_ALL=C
export LC_ALL

if [ "$#" -eq 7 ] && [ "$1" = --validated ]; then
  url=$2
  worktree=$3
  fm_root=$4
  state=$5
  config=$6
  id=$7
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.ado-pr-poll; id=$(basename "${0%.check.sh}") ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r worktree <&3 || exit 0
  IFS= read -r fm_root <&3 || exit 0
  IFS= read -r state <&3 || exit 0
  IFS= read -r config <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

# Validate the PR URL is a canonical ADO PR URL (dev.azure.com or
# *.visualstudio.com), with pure pattern-matching, before any side effect.
case "$url" in
  https://dev.azure.com/*/_git/*/pullrequest/*) ;;
  https://*.visualstudio.com/*/_git/*/pullrequest/*) ;;
  *) exit 0 ;;
esac
# Reject any shell metacharacter or whitespace that has no place in a URL, so a
# malformed sidecar can never smuggle a token past the coarse case globs above.
case "$url" in
  *[!A-Za-z0-9:/._~%-]*) exit 0 ;;
esac
# The trailing PR id must be all digits (no query string, no fragment).
number=${url##*/pullrequest/}
case "$number" in
  ''|*[!0-9]*) exit 0 ;;
esac

# The scm library must be the tracked one under the recorded fm root, and the
# state and (optional) config dirs must be ordinary directories. worktree may be
# empty (az --detect is skipped) or must be an existing directory.
[ -n "$fm_root" ] || exit 0
scm="$fm_root/bin/fm-scm-lib.sh"
[ -f "$scm" ] && [ ! -L "$scm" ] || exit 0
[ -n "$state" ] && [ -d "$state" ] && [ ! -L "$state" ] || exit 0
if [ -n "$worktree" ]; then
  [ -d "$worktree" ] || worktree=
fi
# The task id scopes the per-task marker paths below; guard it with the same
# charset discipline the URL uses (reject empty, a leading dot, or anything
# outside [A-Za-z0-9._-]) so it can never traverse out of $state.
case "$id" in
  ''|.*|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
ledger="$state/$id.ado-requeue.ledger"
seen="$state/$id.ado-stuck-seen"

decisions=$("$scm" ado-requeue-expired ado "$worktree" "$url" "$ledger" 2>/dev/null)
stuck=$(printf '%s\n' "$decisions" | grep -E '^(rejected|capped):' || true)

renotify=
if [ -n "$config" ] && [ -f "$config/ado-requeue.env" ] && [ ! -L "$config/ado-requeue.env" ]; then
  # Source only to read FM_ADO_STUCK_GATE_RENOTIFY; the env file is captain-owned
  # local config, not task/PR data, so it is not part of the no-interpolation
  # boundary this program protects.
  # shellcheck disable=SC1091
  . "$config/ado-requeue.env" 2>/dev/null || true
  renotify=${FM_ADO_STUCK_GATE_RENOTIFY:-}
fi

if [ -n "$stuck" ]; then
  if [ -n "$renotify" ]; then
    printf 'content gate needs attention on %s\n%s\n' "$url" "$stuck"
  else
    sig=$(printf '%s' "$stuck" | cksum)
    if [ "$sig" != "$(cat "$seen" 2>/dev/null || true)" ]; then
      printf '%s' "$sig" > "$seen"
      printf 'content gate needs attention on %s\n%s\n' "$url" "$stuck"
    fi
  fi
else
  rm -f "$seen" 2>/dev/null || true
fi

state_result=$("$scm" pr-state ado "$worktree" "$url" 2>/dev/null)
[ "$state_result" = MERGED ] && printf '%s\n' merged
exit 0
