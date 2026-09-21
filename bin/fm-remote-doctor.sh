#!/usr/bin/env bash
# Check, and optionally repair, one remote account's second-mate readiness.
#
# Usage:
#   bin/fm-on.sh <secondmate-id|ssh-alias> fm-remote-doctor.sh [--fix]
#
# fm-on.sh automatically adds `--transport-profile devbox-wsl --subscription
# <uuid>` when the route's primary-local config/remote-transports record selects
# that profile. The options are internal diagnostic selectors, not a second way
# to configure a route.
#
# Run it through fm-on.sh so the fixed entrypoint invokes this readiness owner
# over its plain SSH bootstrap. The command reports the same filesystem-composed
# PATH used by worker jobs while retaining authority to inspect and repair the
# worker itself.
#
# A remote second mate always runs on the Herdr backend in the dedicated
# fm-remote session. Its account therefore needs the Firstmate-owned Aqua Herdr
# agent plus the sibling dev.firstmate.remote-job worker that runs normal fm-on
# commands through the Aqua or Linux job-worker path. On darwin, that Herdr
# agent runs bin/fm-remote-herdr-guard.sh through the remote account's login
# shell (`-l -c`) so the server inherits the account's own environment; the
# gui/<uid> launchd domain it is bootstrapped into, not the shell, is what
# gives the server and its panes the Aqua audit session and login-keychain
# access. The guard execs the server in the foreground under launchd, leaves an
# Aqua-born server alone, and takes the session over from a server born
# outside that session (an SSH remote attach wins the socket at boot), because
# such a server's panes cannot read the login keychain;
# bin/fm-remote-herdr-owner-lib.sh owns that birth test. Doctor remains
# invokable over the plain-SSH bootstrap path to inspect and repair that worker.
# SSH cannot create an Aqua session, so a host with no GUI login is a human
# gap rather than something --fix attempts to bypass.
#
# Line protocol, one fact per line, stable for script consumers:
#   mode=check|fix
#   path=<the child PATH this command inherited>
#   entrypoint=yes|no
#   platform=darwin|linux|<uname -s>|unknown
#   transport-profile=devbox-wsl                 (selected profile only)
#   subscription=<azure-subscription-uuid>        (selected profile only)
#   required <tool>=<path>|MISSING
#   optional <tool>=<path>|absent
#   fix <check>=applied: <what changed>       (--fix only)
#   fix <check>=failed: <why the repair did not land>   (--fix only)
#   check <check>=ok: <evidence>
#   check <check>=skip: <why this host is exempt>
#   check <check>=fixable: <gap --fix can close>
#   check <check>=human: <gap only a person at that machine can close>
#   action: <check>: <the exact step to take>
# Every check line is authoritative for the moment it printed: under --fix it is
# the state after the repair attempt, so a human gap is never presented as
# fixed. Any remaining fixable or human gap, and any missing required tool,
# exits non-zero.
#
# --fix is idempotent and closes only automatable gaps: it writes and reloads
# both Firstmate-owned Aqua agents, starts the Linux workers where no Aqua agent
# applies, recreates the entrypoint symlink, and may add an owned ~/.local/bin
# wrapper for a required tool it can discover under nvm, asdf, or mise. It never
# installs packages, creates a login session, writes an auto-login password,
# changes FileVault, stores an account password, or replaces a non-Firstmate
# wrapper; those remain reported gaps.
set -eu

# Resolve this script's directory with builtins only: a host missing a required
# tool must still reach the report that names it, not die on a bare PATH.
SCRIPT_SELF=${BASH_SOURCE[0]}
SCRIPT_DIR=${SCRIPT_SELF%/*}
[ "$SCRIPT_DIR" != "$SCRIPT_SELF" ] || SCRIPT_DIR=.
SCRIPT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR" && pwd -P)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd -P)}"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$SCRIPT_DIR/fm-remote-job-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$SCRIPT_DIR/fm-remote-herdr-owner-lib.sh"
REQUIRED_TOOLS=(git jq herdr tasks-axi treehouse)
HARNESS_TOOLS=(claude codex opencode pi pi-signed grok kimi)
OPTIONAL_TOOLS=(tmux no-mistakes gh)
LAUNCH_AGENT_LABEL=dev.firstmate.herdr.fm-remote
# The dedicated remote-secondmate session. The user's interactive Herdr work
# remains in the separate default session, which this readiness check never
# requires or changes.
HERDR_SESSION_NAME=fm-remote
LAUNCH_AGENT_DIR="${HOME:-}/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/$LAUNCH_AGENT_LABEL.plist"
LAUNCH_AGENT_LOG_DIR="${HOME:-}/Library/Logs"
LAUNCH_AGENT_LOG="$LAUNCH_AGENT_LOG_DIR/$LAUNCH_AGENT_LABEL.log"
ENTRYPOINT_LINK="${HOME:-}/.local/bin/fm-remote-entrypoint.sh"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

MODE=check
TRANSPORT_PROFILE=ssh
SUBSCRIPTION=
PROFILE_SEEN=0
SUBSCRIPTION_SEEN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fix)
      [ "$MODE" = check ] || usage
      MODE=fix
      shift
      ;;
    --transport-profile)
      [ "$PROFILE_SEEN" -eq 0 ] && [ "$#" -ge 2 ] || usage
      [ "$2" = devbox-wsl ] || usage
      TRANSPORT_PROFILE=$2
      PROFILE_SEEN=1
      shift 2
      ;;
    --subscription)
      [ "$SUBSCRIPTION_SEEN" -eq 0 ] && [ "$#" -ge 2 ] || usage
      SUBSCRIPTION=$2
      SUBSCRIPTION_SEEN=1
      shift 2
      ;;
    --worker-tool-probe)
      [ "$MODE" = check ] && [ "$PROFILE_SEEN" -eq 0 ] && [ "$SUBSCRIPTION_SEEN" -eq 0 ] && [ "$#" -eq 1 ] || usage
      [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] || { printf 'error: worker tool probe requires the remote job worker\n' >&2; exit 64; }
      MODE='worker-tool-probe'
      shift
      ;;
    *) usage ;;
  esac
done
if [ "$TRANSPORT_PROFILE" = devbox-wsl ]; then
  [[ "$SUBSCRIPTION" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || usage
  SUBSCRIPTION=$(printf '%s' "$SUBSCRIPTION" | tr 'A-F' 'a-f')
else
  [ -z "$SUBSCRIPTION" ] || usage
fi

PLATFORM=$(fm_remote_job_platform)
UID_NUM=$(id -u 2>/dev/null) || UID_NUM=

CHECK_NAMES=()
CHECK_VALUES=()
CHECK_ACTIONS=()

record() { # <name> <value> [operator-action]
  CHECK_NAMES+=("$1")
  CHECK_VALUES+=("$2")
  CHECK_ACTIONS+=("${3:-}")
}

check_value() { # <name>; prints the recorded value, empty when unrecorded
  local i=0
  while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
    if [ "${CHECK_NAMES[$i]}" = "$1" ]; then
      printf '%s' "${CHECK_VALUES[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

check_is_ok() { # <name>
  case "$(check_value "$1" 2>/dev/null || true)" in ok:*) return 0 ;; esac
  return 1
}

set_check() { # <name> <value> [operator-action]
  local i=0
  while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
    if [ "${CHECK_NAMES[$i]}" = "$1" ]; then
      CHECK_VALUES[i]=$2
      CHECK_ACTIONS[i]=${3:-}
      return 0
    fi
    i=$((i + 1))
  done
  record "$@"
}

herdr_cli_available() {
  local herdr_bin jq_bin
  herdr_bin=$(command -v herdr 2>/dev/null || true)
  jq_bin=$(command -v jq 2>/dev/null || true)
  [ -n "$herdr_bin" ] && [ -x "$herdr_bin" ] && [ -n "$jq_bin" ] && [ -x "$jq_bin" ]
}

# The herdr adapter is the single owner of session-scoped herdr invocation and
# of starting a server, so read and start through it rather than restating
# either here. Sourced only when both tools resolve, so a bare host still
# reports its gaps instead of failing to load.
herdr_adapter_load() {
  [ -z "${FM_REMOTE_DOCTOR_HERDR_LOADED:-}" ] || return 0
  herdr_cli_available || return 1
  [ -f "$SCRIPT_DIR/fm-backend.sh" ] && [ -f "$SCRIPT_DIR/backends/herdr.sh" ] || return 1
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" || return 1
  fm_backend_source herdr || return 1
  FM_REMOTE_DOCTOR_HERDR_LOADED=1
}

herdr_server_status_json() {
  herdr_adapter_load || return 1
  fm_backend_herdr_cli "$HERDR_SESSION_NAME" status --json 2>/dev/null
}

herdr_server_running() {
  local running
  running=$(herdr_server_status_json | jq -r '.server.running // false' 2>/dev/null) || return 1
  [ "$running" = true ]
}

# Birth of the process serving the session, as the guard classifies it:
# prints "<birth> <pid>" (launchd, worker, ssh, or unknown), "unproven" when
# no herdr process can be shown to hold the socket, or "nolsof" when lsof does
# not resolve. bin/fm-remote-herdr-owner-lib.sh owns the markers.
herdr_server_birth() {
  local socket owner rc birth
  socket=$(herdr_server_status_json | jq -r '.server.socket // empty' 2>/dev/null) || socket=
  owner=$(fm_remote_herdr_socket_owner "$socket"); rc=$?
  if [ "$rc" -eq 2 ]; then
    printf 'nolsof\n'
    return 0
  fi
  if [ -z "$owner" ]; then
    printf 'unproven\n'
    return 0
  fi
  birth=$(fm_remote_herdr_owner_birth "$owner")
  printf '%s %s\n' "$birth" "$owner"
}

# On darwin the session is ready only when its server was born in the Aqua
# login session; elsewhere any running server is.
herdr_server_aqua_owned() {
  local birth
  herdr_server_running || return 1
  [ "$PLATFORM" = darwin ] || return 0
  birth=$(herdr_server_birth)
  fm_remote_herdr_birth_is_aqua "${birth%% *}"
}

launch_agent_is_aqua() {
  local stripped
  [ -f "$LAUNCH_AGENT_PLIST" ] && [ ! -L "$LAUNCH_AGENT_PLIST" ] || return 1
  stripped=$(tr -d ' \t\r\n' < "$LAUNCH_AGENT_PLIST" 2>/dev/null) || return 1
  case "$stripped" in
    *'<key>LimitLoadToSessionType</key><string>Aqua</string>'*) return 0 ;;
  esac
  return 1
}

launch_agent_shell_quote() { # <value>
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

launch_agent_xml_escape() { # <value>
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# Directory Services UserShell is the account's real login shell on darwin
# (bash, fish, zsh, ...). Fall back without failing the render: $SHELL, then
# /bin/sh. Separate -l and -c so fish accepts the flags.
resolve_launch_agent_shell() {
  local user raw shell
  if [ -n "${FM_LAUNCH_AGENT_SHELL:-}" ] && [ -x "$FM_LAUNCH_AGENT_SHELL" ]; then
    printf '%s' "$FM_LAUNCH_AGENT_SHELL"
    return 0
  fi
  user=$(id -un 2>/dev/null || true)
  if [ -n "$user" ] && command -v dscl >/dev/null 2>&1 && command -v perl >/dev/null 2>&1; then
    raw=$(perl -e '$SIG{ALRM} = sub { exit 124 }; alarm 2; exec @ARGV' \
      dscl . -read "/Users/$user" UserShell 2>/dev/null || true)
    shell=$(printf '%s\n' "$raw" | awk '
      /^UserShell:[[:space:]]+/ {
        sub(/^UserShell:[[:space:]]+/, "")
        if (length) { print; exit }
      }
    ')
    if [ -n "$shell" ] && [ -x "$shell" ]; then
      printf '%s' "$shell"
      return 0
    fi
  fi
  if [ -n "${SHELL:-}" ] && [ -x "$SHELL" ]; then
    printf '%s' "$SHELL"
    return 0
  fi
  printf '%s' /bin/sh
}

# Login-shell command that execs the Firstmate-owned guard, which in turn execs
# the resolved herdr so launchd keeps one foreground process in the Aqua
# session, or exits 0 when an Aqua-born server already owns the session.
# KeepAlive={SuccessfulExit=false} is load-bearing for that exit: an
# unconditional KeepAlive would respawn the job every throttle interval
# forever while a foreign server holds the socket, exactly the loop this guard
# replaces, and would never let the guard's "nothing to do" verdict rest.
launch_agent_guard_path() {
  printf '%s/bin/fm-remote-herdr-guard.sh' "$FM_ROOT"
}

launch_agent_exec_command() { # <resolved-herdr-path>
  printf 'exec %s %s %s' \
    "$(launch_agent_shell_quote "$(launch_agent_guard_path)")" \
    "$(launch_agent_shell_quote "$1")" \
    "$(launch_agent_shell_quote "$HERDR_SESSION_NAME")"
}

render_launch_agent() { # <resolved-herdr-path> <resolved-login-shell>
  local herdr_bin=$1 shell=$2 exec_cmd shell_xml
  shell_xml=$(launch_agent_xml_escape "$shell")
  exec_cmd=$(launch_agent_exec_command "$herdr_bin")
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LAUNCH_AGENT_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$shell_xml</string>
		<string>-l</string>
		<string>-c</string>
		<string>$exec_cmd</string>
	</array>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>StandardOutPath</key>
	<string>$LAUNCH_AGENT_LOG</string>
	<key>StandardErrorPath</key>
	<string>$LAUNCH_AGENT_LOG</string>
</dict>
</plist>
XML
}

launch_agent_contract_matches() { # <resolved-login-shell>
  local shell=$1 herdr_bin actual expected
  [ -f "$LAUNCH_AGENT_PLIST" ] && [ ! -L "$LAUNCH_AGENT_PLIST" ] || return 1
  herdr_bin=$(command -v herdr 2>/dev/null) || return 1
  actual=$(tr -d ' \t\r\n' < "$LAUNCH_AGENT_PLIST" 2>/dev/null) || return 1
  expected=$(render_launch_agent "$herdr_bin" "$shell" | tr -d ' \t\r\n') || return 1
  [ "$actual" = "$expected" ]
}

launch_agent_loaded_contract_matches() { # <resolved-login-shell>
  local shell=$1 loaded herdr_bin exec_compact shell_compact plist_compact log_compact args
  herdr_bin=$(command -v herdr 2>/dev/null) || return 1
  loaded=$(launchctl print "gui/$UID_NUM/$LAUNCH_AGENT_LABEL" 2>/dev/null) || return 1
  loaded=$(printf '%s' "$loaded" | tr -d ' \t\r\n') || return 1
  exec_compact=$(launch_agent_exec_command "$herdr_bin" | tr -d ' \t\r\n') || return 1
  shell_compact=$(printf '%s' "$shell" | tr -d ' \t\r\n') || return 1
  plist_compact=$(printf '%s' "$LAUNCH_AGENT_PLIST" | tr -d ' \t\r\n') || return 1
  log_compact=$(printf '%s' "$LAUNCH_AGENT_LOG" | tr -d ' \t\r\n') || return 1
  args="arguments={${shell_compact}-l-c${exec_compact}}"
  [[ "$loaded" == *"path=$plist_compact"* ]] || return 1
  [[ "$loaded" == *"program=$shell_compact"* ]] || return 1
  [[ "$loaded" == *"$args"* ]] || return 1
  [[ "$loaded" == *"stdoutpath=$log_compact"* ]] || return 1
  [[ "$loaded" == *"stderrpath=$log_compact"* ]] || return 1
  # launchd renders KeepAlive={SuccessfulExit=false} as a successful-exit
  # semaphore rather than a keepalive property.
  [[ "$loaded" == *'successfulexit=>0'* ]] || return 1
  [[ "$loaded" == *'properties=runatload'* ]] || return 1
}

# --- remote job and tool checks ---------------------------------------------

remote_job_existing_state() {
  local root
  root=${FM_REMOTE_JOB_STATE_ROOT:-${HOME:-}/.firstmate/remote-job}
  root=$(fm_remote_job_canonical_existing_dir "$root") || return 1
  fm_remote_job_canonical_existing_dir "$root/jobs" >/dev/null || return 1
  # shellcheck disable=SC2034 # The sourceable worker helpers consume the validated state root.
  FM_REMOTE_JOB_STATE=$root
}

remote_job_probe_ok() {
  local ready mtime now
  [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] && return 0
  remote_job_existing_state || return 1
  ready="$FM_REMOTE_JOB_STATE/worker.ready"
  [ -f "$ready" ] && [ ! -L "$ready" ] || return 1
  mtime=$(fm_remote_job_path_mtime "$ready" 2>/dev/null || true)
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ $((now - mtime)) -le 10 ]
}

remote_job_identity_ok() {
  [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] && return 0
  remote_job_probe_ok || return 1
  fm_remote_job_worker_identity_matches "$FM_ROOT" "${HOME:-}"
}

check_remote_job_worker() {
  local worker
  worker="$FM_ROOT/bin/fm-remote-job-worker.sh"
  if [ ! -f "$worker" ] || [ -L "$worker" ] || [ ! -x "$worker" ]; then
    record remote-job-worker "human: the configured Firstmate code root has no safe remote job worker" \
      "update the remote Firstmate checkout, then rerun this command with --fix"
    record remote-job-worker-loaded "skip: no worker executable is available"
    record remote-job-probe "skip: no worker executable is available"
    return 0
  fi
  if [ "$PLATFORM" = darwin ]; then
    fm_remote_job_launchagent_paths "${HOME:-}"
    if fm_remote_job_launchagent_contract_matches "$FM_ROOT" "${HOME:-}"; then
      record remote-job-worker "ok: $FM_REMOTE_JOB_LAUNCH_AGENT_PLIST matches the Firstmate-owned Aqua worker contract"
    else
      record remote-job-worker "fixable: $FM_REMOTE_JOB_LAUNCH_AGENT_PLIST does not match the Firstmate-owned Aqua worker contract" \
        "rerun this command with --fix to write dev.firstmate.remote-job"
    fi
    if [ -z "$UID_NUM" ] || ! command -v launchctl >/dev/null 2>&1; then
      record remote-job-worker-loaded "human: the remote job worker cannot be inspected without launchctl and an account uid" \
        "restore launchctl and a readable account uid, then rerun this command"
    elif fm_remote_job_launchagent_loaded "$FM_ROOT" "${HOME:-}" "$UID_NUM"; then
      record remote-job-worker-loaded "ok: $FM_REMOTE_JOB_LABEL is loaded in gui/$UID_NUM"
    elif check_is_ok gui-session; then
      record remote-job-worker-loaded "fixable: $FM_REMOTE_JOB_LABEL is not loaded in gui/$UID_NUM" \
        "rerun this command with --fix to bootstrap the worker"
    else
      record remote-job-worker-loaded "human: $FM_REMOTE_JOB_LABEL cannot be loaded because gui/$UID_NUM has no login session" \
        "close the login-session gap first; SSH cannot create an Aqua session"
    fi
  else
    local pid
    pid=$(cat "${FM_REMOTE_JOB_STATE_ROOT:-${HOME:-}/.firstmate/remote-job}/worker.pid" 2>/dev/null || true)
    if [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] ||
      { remote_job_existing_state && case "$pid" in ''|*[!0-9]*) false ;; *) kill -0 "$pid" 2>/dev/null ;; esac; }; then
      record remote-job-worker "ok: the Linux remote job worker is running"
      record remote-job-worker-loaded "skip: Aqua launch agents do not apply on $PLATFORM"
    else
      record remote-job-worker "fixable: the Linux remote job worker is not running" \
        "rerun this command with --fix to start it"
      record remote-job-worker-loaded "skip: Aqua launch agents do not apply on $PLATFORM"
    fi
  fi
  if ! remote_job_probe_ok; then
    record remote-job-probe "fixable: the remote job worker has not reported a fresh probe" \
      "rerun this command with --fix to restart the worker, then rerun through fm-on.sh"
  elif ! remote_job_identity_ok; then
    set_check remote-job-worker "fixable: the running remote job worker does not match the current Firstmate code" \
      "rerun this command with --fix to reload the current worker"
    record remote-job-probe "fixable: the remote job worker identity is stale, so its runtime cannot be probed" \
      "rerun this command with --fix to reload the current worker"
  else
    record remote-job-probe "ok: the remote job worker published a fresh heartbeat"
  fi
}

report_required_tools() {
  local tool resolved harness
  MISSING=()
  for tool in "${REQUIRED_TOOLS[@]}"; do
    resolved=$(command -v "$tool" 2>/dev/null || true)
    if [ -n "$resolved" ] && [ -x "$resolved" ]; then
      if [ "$tool" = tasks-axi ] && ! fm_tasks_axi_compatible; then
        printf 'required tasks-axi=MISSING (incompatible)\n'
        MISSING+=(tasks-axi)
      else
        printf 'required %s=%s\n' "$tool" "$resolved"
      fi
    else
      printf 'required %s=MISSING\n' "$tool"
      MISSING+=("$tool")
    fi
  done
  for harness in "${HARNESS_TOOLS[@]}"; do
    resolved=$(command -v "$harness" 2>/dev/null || true)
    if [ -n "$resolved" ] && [ -x "$resolved" ]; then
      printf 'required harness=%s:%s\n' "$harness" "$resolved"
      return 0
    fi
  done
  printf 'required harness=MISSING\n'
  MISSING+=(harness)
}

report_required_tools_from_worker() {
  local job_id probe_stdout probe_stderr probe_exit line fact name value
  local expected=6 count=0 valid=1 seen=' '
  if ! job_id=$(fm_remote_job_stage "${HOME:-}" "$FM_ROOT" "${FM_HOME:-}" \
    fm-remote-doctor.sh --worker-tool-probe </dev/null); then
    set_check remote-job-probe "fixable: the remote job worker could not accept the required-tool probe" \
      "rerun this command with --fix to restart the worker"
    report_required_tools
    return 0
  fi
  if ! fm_remote_job_wait "${HOME:-}" "$job_id"; then
    fm_remote_job_reap "${HOME:-}" "$job_id" 2>/dev/null || true
    set_check remote-job-probe "fixable: the remote job worker did not complete the required-tool probe" \
      "rerun this command with --fix to restart the worker"
    report_required_tools
    return 0
  fi
  probe_stdout=$FM_REMOTE_JOB_STDOUT
  probe_stderr=$FM_REMOTE_JOB_STDERR
  probe_exit=$FM_REMOTE_JOB_EXIT
  MISSING=()
  while IFS= read -r line; do
    case "$line" in required\ *=*) ;; *) valid=0; continue ;; esac
    fact=${line#required }
    name=${fact%%=*}
    value=${fact#*=}
    case "$name" in git|jq|herdr|tasks-axi|treehouse|harness) ;; *) valid=0; continue ;; esac
    case "$seen" in *" $name "*) valid=0; continue ;; esac
    seen="$seen$name "
    count=$((count + 1))
    case "$value" in MISSING*) MISSING+=("$name") ;; '') valid=0 ;; esac
  done < "$probe_stdout"
  [ "$count" -eq "$expected" ] || valid=0
  [ ! -s "$probe_stderr" ] || valid=0
  case "$probe_exit:${#MISSING[@]}" in 0:0|1:[1-9]*) ;; *) valid=0 ;; esac
  if [ "$valid" -eq 1 ]; then
    cat "$probe_stdout"
    set_check remote-job-probe "ok: the remote job worker completed the required-tool probe"
  else
    set_check remote-job-probe "fixable: the remote job worker returned an invalid required-tool probe result" \
      "rerun this command with --fix to restart the worker"
    report_required_tools
  fi
  fm_remote_job_reap "${HOME:-}" "$job_id" 2>/dev/null || true
}

wrapper_is_firstmate_owned() { # <path>
  local path=$1 first second
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS= read -r first < "$path" || return 1
  IFS= read -r second < <(tail -n +2 "$path") || return 1
  [ "$first" = '#!/usr/bin/env bash' ] && [ "$second" = '# Firstmate remote tool wrapper v1' ]
}

repair_tool_wrapper() { # <tool>
  local tool=$1 target wrapper tmp
  local resolved
  resolved=$(command -v "$tool" 2>/dev/null || true)
  [ -n "$resolved" ] && [ -x "$resolved" ] && return 0
  target=$(fm_remote_job_manager_tool "${HOME:-}" "$tool" 2>/dev/null || true)
  [ -n "$target" ] || return 1
  wrapper="${HOME:-}/.local/bin/$tool"
  if [ -e "$wrapper" ] || [ -L "$wrapper" ]; then
    if ! wrapper_is_firstmate_owned "$wrapper"; then
      fix_report "required-$tool" failed "$wrapper exists and is not Firstmate-owned"
      return 1
    fi
  else
    if ! mkdir -p "${HOME:-}/.local/bin" 2>/dev/null || [ -L "${HOME:-}/.local/bin" ]; then
      fix_report "required-$tool" failed "cannot create ${HOME:-}/.local/bin"
      return 1
    fi
  fi
  tmp="${HOME:-}/.local/bin/.$tool.tmp.$$"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# Firstmate remote tool wrapper v1'
    printf 'exec %q "$@"\n' "$target"
  } > "$tmp" || { rm -f -- "$tmp"; fix_report "required-$tool" failed "cannot write $wrapper"; return 1; }
  if ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$wrapper"; then
    rm -f -- "$tmp"
    fix_report "required-$tool" failed "cannot publish $wrapper"
    return 1
  fi
  fix_report "required-$tool" applied "linked the discoverable version-manager tool at $wrapper"
}

repair_required_wrappers() {
  local tool resolved
  for tool in "${REQUIRED_TOOLS[@]}"; do
    repair_tool_wrapper "$tool" || true
  done
  for tool in "${HARNESS_TOOLS[@]}"; do
    resolved=$(command -v "$tool" 2>/dev/null || true)
    [ -z "$resolved" ] || [ ! -x "$resolved" ] || return 0
  done
  for tool in "${HARNESS_TOOLS[@]}"; do
    fm_remote_job_manager_tool "${HOME:-}" "$tool" >/dev/null 2>&1 || continue
    repair_tool_wrapper "$tool" && return 0
  done
}

fix_remote_job_worker() {
  if fm_remote_job_ensure_worker "$FM_ROOT" "${HOME:-}"; then
    [ "$FM_REMOTE_JOB_REPAIRED" -eq 0 ] || fix_report remote-job-worker applied "installed or reloaded $FM_REMOTE_JOB_LABEL"
    return 0
  fi
  fix_report remote-job-worker failed "${FM_REMOTE_JOB_ERROR:-the remote job worker could not start}"
  return 1
}

# --- checks -----------------------------------------------------------------

check_herdr() {
  local resolved selected
  if resolved=$(command -v herdr 2>/dev/null) && [ -x "$resolved" ]; then
    if herdr_adapter_load; then
      fm_backend_herdr_client_select "$HERDR_SESSION_NAME"
      selected=$(fm_backend_herdr_bin)
      if [ "$selected" != herdr ] && [ "$selected" != "$resolved" ]; then
        record herdr "ok: $selected (bypassing $resolved)"
        return 0
      fi
    fi
    record herdr "ok: $resolved"
    return 0
  fi
  record herdr "human: the herdr CLI does not resolve on the remote runtime PATH" \
    "install herdr from https://herdr.dev on that account, or add a ~/.local/bin wrapper for it; a remote second mate always runs on the Herdr backend"
}

check_gui_session() {
  if [ "$PLATFORM" != darwin ]; then
    record gui-session "skip: no Aqua login session applies on $PLATFORM"
    return 0
  fi
  if [ -z "$UID_NUM" ]; then
    record gui-session "human: the account uid could not be read, so its login session cannot be inspected" \
      "run 'id -u' on that account and report the failure; Firstmate cannot address gui/<uid> without it"
    return 0
  fi
  if ! command -v launchctl >/dev/null 2>&1; then
    record gui-session "human: launchctl does not resolve, so the login session cannot be inspected" \
      "restore /bin/launchctl on that macOS account; without it no launch agent can be inspected or loaded"
    return 0
  fi
  if launchctl print "gui/$UID_NUM" >/dev/null 2>&1; then
    record gui-session "ok: gui/$UID_NUM"
    return 0
  fi
  record gui-session "human: no Aqua login session exists for uid $UID_NUM" \
    "log that account in once at the console, and enable automatic login in System Settings > Users & Groups if the machine runs headless; SSH cannot create a GUI session, and Firstmate never writes an auto-login password or changes FileVault"
}

check_launch_agent() { # <resolved-login-shell>
  local shell=$1
  if [ "$PLATFORM" != darwin ]; then
    record launchagent "skip: launch agents apply only on darwin"
    record launchagent-scope "skip: launch agents apply only on darwin"
    record launchagent-loaded "skip: launch agents apply only on darwin"
    return 0
  fi
  if [ -f "$LAUNCH_AGENT_PLIST" ] && [ ! -L "$LAUNCH_AGENT_PLIST" ]; then
    if launch_agent_contract_matches "$shell"; then
      record launchagent "ok: $LAUNCH_AGENT_PLIST matches the Firstmate-owned contract"
    else
      record launchagent "fixable: $LAUNCH_AGENT_PLIST does not match the current Firstmate-owned contract" \
        "rerun this command with --fix to rewrite its label, program arguments, session scope, restart policy, and log paths"
    fi
    if launch_agent_is_aqua; then
      record launchagent-scope "ok: LimitLoadToSessionType=Aqua"
    else
      record launchagent-scope "fixable: $LAUNCH_AGENT_PLIST is not scoped to the Aqua login session" \
        "rerun this command with --fix to rewrite it with LimitLoadToSessionType=Aqua"
    fi
  else
    record launchagent "fixable: no Firstmate herdr launch agent at $LAUNCH_AGENT_PLIST" \
      "rerun this command with --fix to install it"
    record launchagent-scope "skip: no launch agent is installed yet"
  fi
  check_launch_agent_loaded "$shell"
}

check_launch_agent_loaded() { # <resolved-login-shell>
  local shell=$1
  if [ -z "$UID_NUM" ] || ! command -v launchctl >/dev/null 2>&1; then
    record launchagent-loaded "human: the launch agent domain gui/<uid> cannot be inspected on this account" \
      "restore launchctl and a readable account uid, then rerun this command"
    return 0
  fi
  if launchctl print "gui/$UID_NUM/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1; then
    if launch_agent_loaded_contract_matches "$shell"; then
      record launchagent-loaded "ok: gui/$UID_NUM/$LAUNCH_AGENT_LABEL matches the effective contract"
    else
      record launchagent-loaded "fixable: gui/$UID_NUM/$LAUNCH_AGENT_LABEL does not match the effective Firstmate-owned contract" \
        "rerun this command with --fix to replace the loaded job with the current launch-agent contract"
    fi
    return 0
  fi
  if check_is_ok gui-session; then
    record launchagent-loaded "fixable: $LAUNCH_AGENT_LABEL is not loaded into gui/$UID_NUM" \
      "rerun this command with --fix to bootstrap and start it"
    return 0
  fi
  record launchagent-loaded "human: $LAUNCH_AGENT_LABEL cannot be loaded because gui/$UID_NUM has no login session" \
    "close the login-session gap first; a launch agent can only be bootstrapped into an existing GUI session"
}

check_herdr_server() {
  if ! herdr_cli_available; then
    record herdr-server "human: herdr server status cannot be read without both herdr and jq on the runtime PATH" \
      "install the missing tool reported above, then rerun this command"
    return 0
  fi
  if herdr_server_running; then
    if [ "$PLATFORM" != darwin ]; then
      record herdr-server "ok: session $HERDR_SESSION_NAME is running"
      return 0
    fi
    local birth
    birth=$(herdr_server_birth)
    case "$birth" in
      launchd\ *|worker\ *)
        record herdr-server "ok: session $HERDR_SESSION_NAME is running in the Aqua login session (pid ${birth#* }, ${birth%% *})"
        ;;
      nolsof)
        record herdr-server "human: session $HERDR_SESSION_NAME is running but lsof does not resolve, so its server's birth cannot be proven" \
          "install lsof on that account so the launch agent and this check can tell an Aqua-born server from one started over SSH"
        ;;
      unproven)
        record herdr-server "fixable: session $HERDR_SESSION_NAME is running but no herdr process can be shown to own its socket, so its birth cannot be proven" \
          "rerun this command with --fix so the launch agent takes the session over (its current panes close and the parent firstmate relaunches its mates)"
        ;;
      *)
        record herdr-server "fixable: session $HERDR_SESSION_NAME is served by pid ${birth#* } born outside the Aqua login session (${birth%% *}), so its panes cannot reach the login keychain" \
          "rerun this command with --fix so the launch agent takes the session over (its current panes close and the parent firstmate relaunches its mates)"
        ;;
    esac
    return 0
  fi
  if [ "$PLATFORM" = darwin ] && ! check_is_ok gui-session; then
    record herdr-server "human: the herdr server for session $HERDR_SESSION_NAME is not running and there is no GUI login session to start it in" \
      "close the login-session gap first; a server started over SSH would not belong to an Aqua session"
    return 0
  fi
  record herdr-server "fixable: the herdr server for session $HERDR_SESSION_NAME is not running" \
    "rerun this command with --fix to start it"
}

check_entrypoint_link() {
  local want
  if [ -z "${FM_ROOT_OVERRIDE:-}" ]; then
    record entrypoint-link "skip: this run did not come through the fixed remote entrypoint"
    return 0
  fi
  want="$FM_ROOT_OVERRIDE/bin/fm-remote-entrypoint.sh"
  if [ -L "$ENTRYPOINT_LINK" ] && [ "$(readlink "$ENTRYPOINT_LINK")" = "$want" ]; then
    record entrypoint-link "ok: $ENTRYPOINT_LINK"
    return 0
  fi
  if [ -e "$ENTRYPOINT_LINK" ] || [ -L "$ENTRYPOINT_LINK" ]; then
    record entrypoint-link "human: $ENTRYPOINT_LINK exists but is not the symlink to $want" \
      "inspect that path yourself and replace it with 'ln -sfn $want $ENTRYPOINT_LINK' if it is stale; Firstmate never overwrites a file it did not create there"
    return 0
  fi
  record entrypoint-link "fixable: no entrypoint symlink at $ENTRYPOINT_LINK" \
    "rerun this command with --fix to create it"
}

# The route itself proves only prerequisites observable after its SSH stream has
# landed in Linux. Pool schedules, the Windows Scheduled Task, Hyper-V firewall
# policy, and the dev-tunnel host process remain operator-owned checks documented
# in docs/remote-secondmates.md and are deliberately never guessed from here.
devbox_auth_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

check_devbox_wsl() {
  local release release_lower pid1 unit='' load_state active enabled
  [ "$TRANSPORT_PROFILE" = devbox-wsl ] || return 0

  if [ "$PLATFORM" != linux ]; then
    record devbox-wsl-platform "human: the configured Dev Box route landed on $PLATFORM instead of WSL2 Linux" \
      "configure the SSH alias to terminate at WSL2's sshd, never at a Windows OpenSSH shell"
    record devbox-wsl-systemd "skip: WSL2 Linux was not reached"
    record devbox-wsl-sshd "skip: WSL2 Linux was not reached"
  else
    release=$(uname -r 2>/dev/null || true)
    release_lower=$(printf '%s' "$release" | tr '[:upper:]' '[:lower:]')
    case "$release_lower" in
      *microsoft-standard*wsl2*|*microsoft-standard*)
        record devbox-wsl-platform "ok: WSL2 kernel $release"
        ;;
      *microsoft*)
        record devbox-wsl-platform "human: the Linux endpoint reports Microsoft kernel '$release' but not WSL2" \
          "install or select a WSL2 distribution and point the SSH alias at that distribution's sshd"
        record devbox-wsl-systemd "skip: WSL2 was not confirmed"
        record devbox-wsl-sshd "skip: WSL2 was not confirmed"
        ;;
      *)
        record devbox-wsl-platform "human: the configured Dev Box profile reached Linux kernel '$release', not a confirmed WSL2 endpoint" \
          "remove the profile for a normal Linux host, or point this Dev Box alias at WSL2's sshd"
        record devbox-wsl-systemd "skip: WSL2 was not confirmed"
        record devbox-wsl-sshd "skip: WSL2 was not confirmed"
        ;;
    esac

    if check_is_ok devbox-wsl-platform; then
      pid1=$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]' || true)
      if [ "$pid1" = systemd ] && command -v systemctl >/dev/null 2>&1; then
        record devbox-wsl-systemd "ok: PID 1 is systemd"
      else
        record devbox-wsl-systemd "human: WSL2 is not running systemd as PID 1" \
          "set [boot] systemd=true in /etc/wsl.conf, run 'wsl.exe --shutdown' from Windows, then restart the distribution"
      fi

      if check_is_ok devbox-wsl-systemd; then
        for unit in ssh.service sshd.service; do
          load_state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null || true)
          if [ "$load_state" = loaded ]; then
            break
          fi
          unit=
        done
        if [ -z "$unit" ]; then
          record devbox-wsl-sshd "human: no loaded ssh.service or sshd.service unit is visible in WSL2" \
            "install the distribution's OpenSSH server package, then enable and start its systemd service"
        else
          active=$(systemctl is-active "$unit" 2>/dev/null || true)
          enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
          if [ "$active" = active ] && [ "$enabled" = enabled ]; then
            record devbox-wsl-sshd "ok: $unit is active and enabled"
          else
            record devbox-wsl-sshd "human: $unit is active=$active and enabled=$enabled" \
              "enable and start $unit in WSL2 so the endpoint returns after a Dev Box restart"
          fi
        fi
      else
        record devbox-wsl-sshd "skip: systemd readiness was not confirmed"
      fi
    fi
  fi

  if [ "${FM_REMOTE_DOCTOR_BOOTSTRAP:-}" = 1 ]; then
    record devbox-wsl-route "ok: the configured SSH route reached Firstmate's fixed entrypoint inside Linux"
  else
    record devbox-wsl-route "human: this diagnostic did not arrive through Firstmate's fixed SSH entrypoint" \
      "run it through 'bin/fm-on.sh <route> fm-remote-doctor.sh' from the primary home"
  fi
}

devbox_auth_skip() { # <reason>
  record devbox-auth-matrix "skip: $1"
  record devbox-auth-interactive "skip: $1"
  record devbox-auth-workload "skip: $1"
  record devbox-auth-rbac "skip: $1"
  record devbox-auth-app-permissions "skip: $1"
}

check_devbox_auth() {
  local matrix_dir matrix links bytes valid account azure_dir tenant principal project_scope workload_scope
  local account_id account_tenant account_type assignments devbox_auth_skip_after_matrix
  [ "$TRANSPORT_PROFILE" = devbox-wsl ] || return 0
  if ! check_is_ok devbox-wsl-platform; then
    devbox_auth_skip "WSL2 was not confirmed"
    return 0
  fi

  matrix_dir="${HOME:-}/.config/firstmate"
  matrix="$matrix_dir/devbox-auth-matrix.json"
  if [ -L "${HOME:-}/.config" ] || [ -L "$matrix_dir" ] || [ -L "$matrix" ] \
    || [ ! -d "$matrix_dir" ] || [ ! -f "$matrix" ]; then
    record devbox-auth-matrix "human: no safe host-local authentication matrix exists at $matrix" \
      "create the credential-free matrix documented in docs/remote-secondmates.md on the WSL2 host"
    devbox_auth_skip_after_matrix=1
  else
    devbox_auth_skip_after_matrix=0
  fi
  if [ "$devbox_auth_skip_after_matrix" -eq 0 ]; then
    links=$(if [ "$(uname -s)" = Darwin ]; then /usr/bin/stat -f %l "$matrix" 2>/dev/null; else stat -c %h "$matrix" 2>/dev/null; fi) || links=
    bytes=$(LC_ALL=C wc -c < "$matrix" 2>/dev/null | tr -d ' ' || true)
    if [ "$links" != 1 ]; then
      record devbox-auth-matrix "human: $matrix is hardlinked or its link count is unreadable" \
        "replace it with one regular single-linked host-local file"
      devbox_auth_skip_after_matrix=1
    elif case "$bytes" in ''|*[!0-9]*) true ;; *) [ "$bytes" -gt 16384 ] ;; esac; then
      record devbox-auth-matrix "human: $matrix is unreadable or exceeds the 16384-byte bound" \
        "replace it with the bounded credential-free matrix documented in docs/remote-secondmates.md"
      devbox_auth_skip_after_matrix=1
    fi
  fi
  if [ "$devbox_auth_skip_after_matrix" -eq 0 ]; then
    valid=$(jq -e '
      type == "object"
      and (keys | sort) == ["interactive", "schema", "subscription", "workload"]
      and .schema == "fm-devbox-auth-matrix.v1"
      and (.subscription | type == "string")
      and (.interactive | type == "object")
      and (.interactive | keys | sort) == ["delegatedAppPermissions", "principalType", "rbac", "uiProfile"]
      and .interactive.principalType == "staff-user"
      and .interactive.delegatedAppPermissions == "dev-tunnels-service-sign-in-only"
      and .interactive.uiProfile == "windows-host-local"
      and (.interactive.rbac | type == "object")
      and (.interactive.rbac | keys | sort) == ["role", "scope"]
      and .interactive.rbac.role == "Dev Box User"
      and (.interactive.rbac.scope | type == "string")
      and (.workload | type == "object")
      and (.workload | keys | sort) == ["applicationPermissions", "principalObjectId", "principalType", "rbac", "tenantId"]
      and .workload.principalType == "managed-or-workload-identity"
      and .workload.applicationPermissions == "none"
      and (.workload.principalObjectId | type == "string")
      and (.workload.tenantId | type == "string")
      and (.workload.rbac | type == "object")
      and (.workload.rbac | keys | sort) == ["role", "scope"]
      and .workload.rbac.role == "Reader"
      and (.workload.rbac.scope | type == "string")
    ' "$matrix" 2>/dev/null || true)
    if [ "$valid" != true ]; then
      record devbox-auth-matrix "human: $matrix does not match schema fm-devbox-auth-matrix.v1" \
        "replace it with the exact credential-free matrix documented in docs/remote-secondmates.md"
      devbox_auth_skip_after_matrix=1
    fi
  fi
  if [ "$devbox_auth_skip_after_matrix" -ne 0 ]; then
    record devbox-auth-interactive "skip: the authentication matrix is not valid"
    record devbox-auth-workload "skip: the authentication matrix is not valid"
    record devbox-auth-rbac "skip: the authentication matrix is not valid"
    record devbox-auth-app-permissions "skip: the authentication matrix is not valid"
    return 0
  fi

  tenant=$(jq -r '.workload.tenantId' "$matrix")
  principal=$(jq -r '.workload.principalObjectId' "$matrix")
  project_scope=$(jq -r '.interactive.rbac.scope' "$matrix")
  workload_scope=$(jq -r '.workload.rbac.scope' "$matrix")
  if [ "$(jq -r '.subscription' "$matrix" | tr 'A-F' 'a-f')" != "$SUBSCRIPTION" ] \
    || ! devbox_auth_uuid "$tenant" || ! devbox_auth_uuid "$principal" \
    || [ "$workload_scope" != "/subscriptions/$SUBSCRIPTION" ]; then
    record devbox-auth-matrix "human: $matrix does not bind its tenant, workload principal, Reader scope, and configured subscription safely" \
      "correct the UUIDs and bind workload Reader to /subscriptions/$SUBSCRIPTION"
    record devbox-auth-interactive "skip: the authentication matrix binding is invalid"
    record devbox-auth-workload "skip: the authentication matrix binding is invalid"
    record devbox-auth-rbac "skip: the authentication matrix binding is invalid"
    record devbox-auth-app-permissions "skip: the authentication matrix binding is invalid"
    return 0
  fi
  case "$project_scope" in
    "/subscriptions/$SUBSCRIPTION/resourceGroups/"?*"/providers/Microsoft.DevCenter/projects/"?*) ;;
    *)
      record devbox-auth-matrix "human: the interactive Dev Box User scope is not a project in subscription $SUBSCRIPTION" \
        "set interactive.rbac.scope to the exact Microsoft.DevCenter project resource ID"
      record devbox-auth-interactive "skip: the authentication matrix binding is invalid"
      record devbox-auth-workload "skip: the authentication matrix binding is invalid"
      record devbox-auth-rbac "skip: the authentication matrix binding is invalid"
      record devbox-auth-app-permissions "skip: the authentication matrix binding is invalid"
      return 0
      ;;
  esac
  case "$project_scope" in *$'\t'*|*$'\n'*|*$'\r'*|*'//'*|*'/../'*|*'/./'*)
    record devbox-auth-matrix "human: the interactive Dev Box project scope contains unsafe delimiters" \
      "set interactive.rbac.scope to one normalized Azure resource ID"
    record devbox-auth-interactive "skip: the authentication matrix binding is invalid"
    record devbox-auth-workload "skip: the authentication matrix binding is invalid"
    record devbox-auth-rbac "skip: the authentication matrix binding is invalid"
    record devbox-auth-app-permissions "skip: the authentication matrix binding is invalid"
    return 0
    ;;
  esac
  record devbox-auth-matrix "ok: the host-local identity and permission matrix is valid for subscription $SUBSCRIPTION"
  record devbox-auth-interactive "ok: staff sign-in is limited to Dev Box User on $project_scope with a Windows-host-local UI profile"
  record devbox-auth-app-permissions "ok: interactive consent is Dev Tunnels service sign-in only and the workload identity has no application permissions"

  azure_dir="$matrix_dir/azure-workload"
  if [ -L "$azure_dir" ] || [ ! -d "$azure_dir" ] || ! command -v az >/dev/null 2>&1; then
    record devbox-auth-workload "human: the isolated workload Azure CLI profile or az is unavailable" \
      "authenticate a managed or federated workload identity in $azure_dir without copying a staff profile or credential"
    record devbox-auth-rbac "skip: the workload identity could not be authenticated"
    return 0
  fi
  account=$(AZURE_CONFIG_DIR="$azure_dir" az account show --subscription "$SUBSCRIPTION" --only-show-errors --output json 2>/dev/null || true)
  account_id=$(printf '%s' "$account" | jq -r '.id // ""' 2>/dev/null | tr 'A-F' 'a-f')
  account_tenant=$(printf '%s' "$account" | jq -r '.tenantId // ""' 2>/dev/null | tr 'A-F' 'a-f')
  account_type=$(printf '%s' "$account" | jq -r '.user.type // ""' 2>/dev/null)
  if [ "$account_id" != "$SUBSCRIPTION" ] || [ "$account_tenant" != "$(printf '%s' "$tenant" | tr 'A-F' 'a-f')" ] \
    || [ "$account_type" != servicePrincipal ]; then
    record devbox-auth-workload "human: the isolated Azure CLI profile is not the declared managed or workload identity on subscription $SUBSCRIPTION" \
      "authenticate the declared identity in $azure_dir; never copy or reuse the interactive staff profile"
    record devbox-auth-rbac "skip: the workload identity could not be authenticated"
    return 0
  fi
  record devbox-auth-workload "ok: isolated service-principal context targets subscription $SUBSCRIPTION and tenant $account_tenant"

  assignments=$(AZURE_CONFIG_DIR="$azure_dir" az role assignment list --assignee-object-id "$principal" \
    --scope "$workload_scope" --include-inherited --all --only-show-errors --output json 2>/dev/null || true)
  if printf '%s' "$assignments" | jq -e --arg scope "$workload_scope" \
    'type == "array" and any(.[]; .roleDefinitionName == "Reader" and .scope == $scope)' >/dev/null 2>&1; then
    record devbox-auth-rbac "ok: workload principal $principal has Reader at $workload_scope"
  else
    record devbox-auth-rbac "human: workload principal $principal does not have the declared Reader assignment at $workload_scope" \
      "grant only the documented Reader role at that subscription scope, then rerun the doctor"
  fi
}

run_checks() { # <resolved-login-shell>
  local shell=$1
  CHECK_NAMES=()
  CHECK_VALUES=()
  CHECK_ACTIONS=()
  check_devbox_wsl
  check_devbox_auth
  check_herdr
  check_gui_session
  check_remote_job_worker
  check_launch_agent "$shell"
  check_herdr_server
  check_entrypoint_link
}

# --- repairs ----------------------------------------------------------------

fix_report() { # <check> applied|failed <text>
  printf 'fix %s=%s: %s\n' "$1" "$2" "$3"
}

write_launch_agent() { # <resolved-login-shell>
  local shell=$1 herdr_bin tmp
  if ! herdr_bin=$(command -v herdr 2>/dev/null); then
    fix_report launchagent failed "herdr does not resolve, so no launch agent was written"
    return 1
  fi
  case "$herdr_bin" in
    *'&'*|*'<'*|*'>'*|*'"'*|*"'"*)
      fix_report launchagent failed "the resolved herdr path contains characters that cannot be embedded in a property list: $herdr_bin"
      return 1
      ;;
  esac
  if ! mkdir -p "$LAUNCH_AGENT_DIR" 2>/dev/null; then
    fix_report launchagent failed "cannot create $LAUNCH_AGENT_DIR"
    return 1
  fi
  mkdir -p "$LAUNCH_AGENT_LOG_DIR" 2>/dev/null || true
  tmp="$LAUNCH_AGENT_DIR/.$LAUNCH_AGENT_LABEL.plist.tmp.$$"
  render_launch_agent "$herdr_bin" "$shell" > "$tmp"
  chmod 0644 "$tmp" 2>/dev/null || true
  if ! mv -f -- "$tmp" "$LAUNCH_AGENT_PLIST" 2>/dev/null; then
    rm -f -- "$tmp"
    fix_report launchagent failed "cannot publish $LAUNCH_AGENT_PLIST"
    return 1
  fi
  fix_report launchagent applied "wrote the Aqua-scoped $LAUNCH_AGENT_LABEL launch agent running $(launch_agent_guard_path) for $herdr_bin via $shell -l -c"
}

# Reload rather than plain bootstrap so a rewritten plist replaces a stale
# in-memory copy, and kickstart so the server is running now rather than at the
# next login. Both are safe to repeat.
reload_launch_agent() { # <check-to-report-under>
  local report=$1 out
  [ -f "$LAUNCH_AGENT_PLIST" ] || {
    fix_report "$report" failed "there is no launch agent to load at $LAUNCH_AGENT_PLIST"
    return 1
  }
  if [ -z "$UID_NUM" ] || ! command -v launchctl >/dev/null 2>&1; then
    fix_report "$report" failed "launchctl or the account uid is unavailable"
    return 1
  fi
  launchctl bootout "gui/$UID_NUM/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
  if ! out=$(launchctl bootstrap "gui/$UID_NUM" "$LAUNCH_AGENT_PLIST" 2>&1); then
    fix_report "$report" failed "launchctl bootstrap gui/$UID_NUM refused: ${out:-no diagnostic}"
    return 1
  fi
  if ! out=$(launchctl kickstart -k "gui/$UID_NUM/$LAUNCH_AGENT_LABEL" 2>&1); then
    fix_report "$report" failed "launchctl kickstart gui/$UID_NUM/$LAUNCH_AGENT_LABEL refused: ${out:-no diagnostic}"
    return 1
  fi
  if ! wait_for_herdr_server; then
    fix_report "$report" failed "the herdr server for session $HERDR_SESSION_NAME did not come up inside the Aqua launch agent within 10s"
    return 1
  fi
  fix_report "$report" applied "bootstrapped and started $LAUNCH_AGENT_LABEL in gui/$UID_NUM"
}

wait_for_herdr_server() {
  local i=0
  while [ "$i" -lt 20 ]; do
    herdr_server_aqua_owned && return 0
    i=$((i + 1))
    sleep 0.5
  done
  return 1
}

start_herdr_server() {
  if ! herdr_adapter_load; then
    fix_report herdr-server failed "herdr and jq must both resolve before the server can be started"
    return 1
  fi
  if fm_backend_herdr_server_ensure "$HERDR_SESSION_NAME" >/dev/null 2>&1; then
    fix_report herdr-server applied "started the herdr server for session $HERDR_SESSION_NAME"
    return 0
  fi
  fix_report herdr-server failed "the herdr server for session $HERDR_SESSION_NAME did not come up"
  return 1
}

link_entrypoint() {
  local want="${FM_ROOT_OVERRIDE:-}/bin/fm-remote-entrypoint.sh"
  if ! mkdir -p "$(dirname "$ENTRYPOINT_LINK")" 2>/dev/null; then
    fix_report entrypoint-link failed "cannot create $(dirname "$ENTRYPOINT_LINK")"
    return 1
  fi
  if ! ln -s "$want" "$ENTRYPOINT_LINK" 2>/dev/null; then
    fix_report entrypoint-link failed "cannot create the symlink at $ENTRYPOINT_LINK"
    return 1
  fi
  fix_report entrypoint-link applied "linked $ENTRYPOINT_LINK to $want"
}

apply_fixes() { # <resolved-login-shell>
  local shell=$1 i name value launch_agent_written=0 launch_agent_reloaded=0 remote_job_fixed=0
  repair_required_wrappers
  i=0
  while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
    name=${CHECK_NAMES[$i]}
    value=${CHECK_VALUES[$i]}
    i=$((i + 1))
    case "$value" in fixable:*) ;; *) continue ;; esac
    case "$name" in
      remote-job-worker|remote-job-worker-loaded|remote-job-probe)
        [ "$remote_job_fixed" -eq 0 ] || continue
        remote_job_fixed=1
        fix_remote_job_worker || true
        ;;
      launchagent|launchagent-scope)
        [ "$launch_agent_written" -eq 0 ] || continue
        launch_agent_written=1
        write_launch_agent "$shell" || continue
        # A freshly written plist runs nothing until it is (re)loaded, and only
        # an existing GUI session can hold it.
        check_is_ok gui-session || continue
        launch_agent_reloaded=1
        reload_launch_agent launchagent-loaded || true
        ;;
      launchagent-loaded)
        [ "$launch_agent_reloaded" -eq 0 ] || continue
        launch_agent_reloaded=1
        reload_launch_agent launchagent-loaded || true
        ;;
      herdr-server)
        # On darwin the launch agent owns the server, so restart it through
        # launchd rather than starting a stray one outside the Aqua session. A
        # reload earlier in this same pass has already done that.
        if [ "$PLATFORM" = darwin ] && [ -f "$LAUNCH_AGENT_PLIST" ] && check_is_ok gui-session; then
          [ "$launch_agent_reloaded" -eq 0 ] || continue
          launch_agent_reloaded=1
          reload_launch_agent herdr-server || true
          continue
        fi
        start_herdr_server || true
        ;;
      entrypoint-link) link_entrypoint || true ;;
    esac
  done
}

# --- report -----------------------------------------------------------------

if [ "$MODE" = worker-tool-probe ]; then
  report_required_tools
  [ "${#MISSING[@]}" -eq 0 ]
  exit
fi

printf 'mode=%s\n' "$MODE"
printf 'path=%s\n' "${PATH:-}"
if [ -n "${FM_ROOT_OVERRIDE:-}" ] && [ "${PATH%%:*}" = "$FM_ROOT_OVERRIDE/bin" ]; then
  printf 'entrypoint=yes\n'
else
  printf 'entrypoint=no\n'
  printf 'note: not launched through the fixed remote entrypoint; the reported PATH is this caller environment.\n' >&2
fi
printf 'platform=%s\n' "$PLATFORM"
if [ "$TRANSPORT_PROFILE" != ssh ]; then
  printf 'transport-profile=%s\n' "$TRANSPORT_PROFILE"
  printf 'subscription=%s\n' "$SUBSCRIPTION"
fi

LAUNCH_AGENT_SHELL=
if [ "$PLATFORM" = darwin ]; then
  LAUNCH_AGENT_SHELL=$(resolve_launch_agent_shell)
fi
run_checks "$LAUNCH_AGENT_SHELL"
if [ "$MODE" = fix ]; then
  apply_fixes "$LAUNCH_AGENT_SHELL"
  # Re-derive every check from the host itself, so what prints below is the
  # state after repair rather than the intent of a repair.
  run_checks "$LAUNCH_AGENT_SHELL"
fi

if [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] || ! remote_job_identity_ok; then
  report_required_tools
else
  report_required_tools_from_worker
fi
for tool in "${OPTIONAL_TOOLS[@]}"; do
  if resolved=$(command -v "$tool" 2>/dev/null); then
    printf 'optional %s=%s\n' "$tool" "$resolved"
  else
    printf 'optional %s=absent\n' "$tool"
  fi
done

GAPS=()
i=0
while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
  printf 'check %s=%s\n' "${CHECK_NAMES[$i]}" "${CHECK_VALUES[$i]}"
  case "${CHECK_VALUES[$i]}" in
    fixable:*|human:*) GAPS+=("$i") ;;
  esac
  i=$((i + 1))
done
for i in ${GAPS[@]+"${GAPS[@]}"}; do
  [ -z "${CHECK_ACTIONS[$i]}" ] || printf 'action: %s: %s\n' "${CHECK_NAMES[$i]}" "${CHECK_ACTIONS[$i]}"
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  printf 'error: required tools do not resolve on the remote runtime PATH: %s\n' "${MISSING[*]}" >&2
  printf 'fix: install each one where it resolves on the path reported above, or put a wrapper script for it in %s/.local/bin, which is always on that PATH.\n' "${HOME:-~}" >&2
  printf 'fix: tools in an unselected nvm version or outside the discovered asdf or mise paths need an absolute wrapper; see docs/remote-secondmates.md for the wrapper recipe.\n' >&2
fi
if [ "${#MISSING[@]}" -gt 0 ] || [ "${#GAPS[@]}" -gt 0 ]; then
  NAMES=
  for i in ${GAPS[@]+"${GAPS[@]}"}; do
    NAMES="${NAMES:+$NAMES }${CHECK_NAMES[$i]}"
  done
  printf 'error: this host is not ready for a remote second mate%s\n' "${NAMES:+; unresolved: $NAMES}" >&2
  exit 1
fi
printf 'ok: remote second-mate readiness confirmed on this host\n'
