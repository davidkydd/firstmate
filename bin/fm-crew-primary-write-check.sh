#!/usr/bin/env bash
# Stable PreToolUse transport for the crew-to-primary write-guard.
#
# A crewmate runs in a disposable linked worktree and must write ONLY inside it.
# Both observed catastrophic isolation slips came from a crew addressing the repo
# by the primary firstmate checkout's absolute path after a correct one-time
# isolation check - an absolute-path Write into the primary, or a
# `cd <primary> && git commit`. This seatbelt denies a crew write whose target
# resolves inside the primary checkout before it runs.
# bin/fm-crew-primary-write-policy.mjs is the sole owner of the block/allow
# decision; it reuses the shell classifier owned by bin/fm-arm-command-policy.mjs.
# This wrapper only detects the crew context, acquires the harness payload,
# invokes that policy, and renders the established harness responses. It never
# executes, sources, evaluates, or expands the command or path.
# See docs/crew-primary-write-guard.md for the complete contract.
#
# Crew context is the firing signal, the inverse of the cd-guard's scope.
# bin/fm-spawn.sh writes a private task binding and exports its path plus a random
# token before launching a ship or scout.
# This transport validates that binding and derives the source checkout,
# assigned worktree, and task id from it instead of trusting three independent
# path variables.
# A primary or secondmate launch carries no binding and remains inert.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-crew-primary-write-check.sh [--claude|--cursor]
#   bin/fm-crew-primary-write-check.sh --command '<cmd>'
#   bin/fm-crew-primary-write-check.sh --file-path '<path>'
#
# Stdin mode reads the tool name from .tool_name (Claude, Codex, Cursor) or
# .toolName (Grok), then extracts .tool_input.command for a Bash tool, or
# .tool_input.file_path / .tool_input.notebook_path for a write tool
# (Write/Edit/MultiEdit/NotebookEdit). CLI mode is used by adapters that extract
# the exact string themselves.
#
# Exit/output contract (identical shape to bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   DENY, --cursor - exit 0 and Cursor's own decision object on stdout. Cursor
#          reads the returned object rather than the exit status.
#   INERT - no valid private crew binding, an untargeted tool, or an empty
#           target: exit 0 with no output.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing Node or policy owner, or an invalid policy response.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
# Cursor consumes the stdout decision object.
set -u

MODE=""
VALUE=""
VALUE_SET=0
CLAUDE_MODE=0
CURSOR_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-crew-primary-write-check.sh [--command <cmd> | --file-path <path>] [--claude|--cursor]

With neither --command nor --file-path, reads a PreToolUse-style JSON payload on
stdin and dispatches on the tool name: a Bash tool uses tool_input.command, a
write tool (Write/Edit/MultiEdit/NotebookEdit) uses tool_input.file_path or
tool_input.notebook_path.
Fires only in a spawned crew/scout shell carrying the private
FM_CREW_WRITE_BOUNDARY_RECORD and FM_CREW_WRITE_BOUNDARY_TOKEN binding; it is a
silent no-op in a primary or secondmate session.
Exits 0 to allow and 2 to deny a write whose target resolves inside the source checkout.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
With --cursor, a deny is Cursor's own decision object on stdout and exit 0,
because Cursor reads the returned object rather than the exit status.
Malformed transport and an unavailable classifier runtime fail open.
EOF
}

set_mode() {
  if [ -n "$MODE" ]; then
    echo "error: only one of --command or --file-path may be given" >&2
    exit 2
  fi
  MODE=$1
  VALUE=$2
  VALUE_SET=1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      set_mode command "$2"
      shift 2
      ;;
    --command=*)
      set_mode command "${1#--command=}"
      shift
      ;;
    --file-path)
      [ "$#" -gt 1 ] || { echo "error: --file-path requires a value" >&2; exit 2; }
      set_mode path "$2"
      shift 2
      ;;
    --file-path=*)
      set_mode path "${1#--file-path=}"
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    --cursor)
      CURSOR_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Authenticated crew-context gate.
# A malformed, replaced, or incomplete binding is inert rather than a universal
# write denial, while spawn refuses if it cannot create the original binding.
# The random token prevents one task from accidentally adopting another task's
# record; this is a same-user agent-mistake guard, not an adversarial sandbox.
RECORD=${FM_CREW_WRITE_BOUNDARY_RECORD:-}
TOKEN=${FM_CREW_WRITE_BOUNDARY_TOKEN:-}
[ -n "$RECORD" ] && [ -n "$TOKEN" ] || exit 0
[ -f "$RECORD" ] && [ ! -L "$RECORD" ] || exit 0
RECORD_MODE=$(stat -f %Lp "$RECORD" 2>/dev/null || stat -c %a "$RECORD" 2>/dev/null || true)
RECORD_LINKS=$(stat -f %l "$RECORD" 2>/dev/null || stat -c %h "$RECORD" 2>/dev/null || true)
[ "$RECORD_MODE" = 600 ] && [ "$RECORD_LINKS" = 1 ] || exit 0
case "$TOKEN" in *[!0-9a-f]*|'') exit 0 ;; esac
[ "${#TOKEN}" -eq 64 ] || exit 0
B_SCHEMA=''
B_TASK=''
B_SOURCE=''
B_WORKTREE=''
B_TOKEN=''
while IFS='=' read -r key value || [ -n "$key$value" ]; do
  case "$key" in
    schema) B_SCHEMA=$value ;;
    task) B_TASK=$value ;;
    source) B_SOURCE=$value ;;
    worktree) B_WORKTREE=$value ;;
    token) B_TOKEN=$value ;;
    *) exit 0 ;;
  esac
done < "$RECORD"
[ "$B_SCHEMA" = fm-crew-write-boundary.v1 ] || exit 0
case "$B_TASK" in '' | *[!A-Za-z0-9._-]*) exit 0 ;; esac
case "$B_SOURCE" in /*) ;; *) exit 0 ;; esac
case "$B_WORKTREE" in /*) ;; *) exit 0 ;; esac
[ "$B_TOKEN" = "$TOKEN" ] || exit 0
[ -z "${FM_TASK_ID:-}" ] || [ "$FM_TASK_ID" = "$B_TASK" ] || exit 0
FM_PRIMARY_CHECKOUT=$B_SOURCE
FM_CREW_WORKTREE=$B_WORKTREE
FM_CREW_TASK_ID=$B_TASK

if [ "$VALUE_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fm-hook-host-lib.sh"
  # Cursor's own registration passes --cursor. Without it a Cursor-delivered
  # payload is the Claude-settings duplicate Cursor also loads, already
  # evaluated by that registration, so this copy allows without re-classifying.
  if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_name // .toolName // empty)' 2>/dev/null) || exit 0
  [ -n "$TOOL" ] || exit 0
  case "$TOOL" in
    Bash|bash|shell|Shell|run_terminal_command|run_shell_command)
      MODE="command"
      VALUE=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.command // .toolInput.command // empty)' 2>/dev/null) || exit 0
      ;;
    Write|Edit|MultiEdit|NotebookEdit|write|edit|write_file|replace)
      MODE="path"
      VALUE=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.file_path // .tool_input.notebook_path // .tool_input.filePath // .tool_input.path // .toolInput.file_path // .toolInput.notebook_path // .toolInput.filePath // .toolInput.path // empty)' 2>/dev/null) || exit 0
      ;;
    *)
      exit 0
      ;;
  esac
fi

# An untargeted or empty tool call has nothing to classify.
[ -n "$MODE" ] || exit 0
[ -n "$VALUE" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
POLICY="$SCRIPT_DIR/fm-crew-primary-write-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

if [ "$MODE" = path ]; then
  POLICY_OUTPUT=$(node "$POLICY" --primary "$FM_PRIMARY_CHECKOUT" --worktree "$FM_CREW_WORKTREE" --id "${FM_CREW_TASK_ID:-}" --file-path "$VALUE" 2>/dev/null) || exit 0
else
  POLICY_OUTPUT=$(node "$POLICY" --primary "$FM_PRIMARY_CHECKOUT" --worktree "$FM_CREW_WORKTREE" --id "${FM_CREW_TASK_ID:-}" --command "$VALUE" 2>/dev/null) || exit 0
fi
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
if [ "$CURSOR_MODE" -eq 1 ]; then
  printf '{"permission":"deny","user_message":"%s"}\n' "$ESCAPED"
  exit 0
fi
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
