#!/usr/bin/env bash
# fm-captain-surface.sh - durable, provenance-aware transport for replaceable
# captain-facing clients such as the GitHub Copilot app extension.
#
# This script owns the `firstmate.captain-surface-*.v1` store formats and their
# mutation mechanics. It does not replace the backlog, worker records, captain
# holds, lifecycle controls, or supervision. Typed decisions and controls are
# dispatched only through bin/fm-captain-hold.sh and bin/fm-control.sh.
#
# Store: $STATE/captain-surfaces/{inputs.jsonl,outputs.jsonl} are append-only,
# gap-free JSONL sequences. Every mutation validates the complete relevant
# store under one home-local lock. Correlation ids are unique per direction;
# an exact retry returns the original sequence and a conflicting retry refuses.
# Input and output are committed before any notification or presentation.
#
# Input acknowledgement: .input-cursor is the highest contiguous input handled
# by Firstmate. Typed records must have a completed application receipt before
# the cursor can cross them. A request is handled conversationally and is
# advanced explicitly after that handling. Agent/system records can be retained
# as non-authoritative observations, but `apply` can only record them ignored. A
# typed decision whose offer is stale at apply is likewise recorded ignored so
# the input cursor can still advance past it.
#
# Output acknowledgement: each registered client has an independent cursor in
# clients/<client>.ack. An extension may acknowledge only the highest contiguous
# sequence it has presented. `outcomes` returns at most a bounded batch of unread
# output per call so a large replay backlog drains incrementally. Re-registering
# a client replaces its endpoint generation without changing that cursor, so
# /clear, restart, and app closure replay only unread output. Calls from an older
# generation are refused.
#
# Typed authority: only a direct-user decision bound to an offered task id and
# exact open-call revision can reach fm-captain-hold.sh. Only direct-user
# interrupt/relaunch controls can reach fm-control.sh. Free text and every
# agent, system, or extension-originated record have no sensitive authority.
# Merge, discard, cleanup, arbitrary shell, and generic command execution are
# not operations in this protocol.
#
# Application receipts are claimed before an owner command runs. A process loss
# after the claim is an explicit uncertain result and is never retried
# automatically, preserving at-most-once side effects. Owner failures are
# retained for reconciliation rather than silently retried.
#
# Usage:
#   fm-captain-surface.sh register --client <id> --generation <id> \
#     --sdk-version <version> --canvas-capable true|false
#   fm-captain-surface.sh ingress --client <id> --generation <id> \
#     --correlation-id <id> --provenance direct-user|agent|system|extension \
#     --kind request|decision|control --payload-file <path|-> \
#     [--session-id <id>] [--message-id <id>]
#   fm-captain-surface.sh inputs
#   fm-captain-surface.sh mark-input-handled --through <seq>
#   fm-captain-surface.sh apply --seq <seq>
#   fm-captain-surface.sh publish --kind outcome|error|notice \
#     --correlation-id <id> --body-file <path|-> [--task-ref <id>]
#   fm-captain-surface.sh offer-decision --task <id> \
#     --correlation-id <id> --body-file <path|->
#   fm-captain-surface.sh outcomes --client <id> --generation <id>
#   fm-captain-surface.sh ack-output --client <id> --generation <id> --through <seq>
#   fm-captain-surface.sh view --client <id> --generation <id>
#   fm-captain-surface.sh client-state --client <id>
#
# Payload schemas:
#   request:  {"text":"..."}
#   decision: {"decision_seq":N,"task_id":"...","revision":"...",
#              "answer":"...","mode":"done"|"release"}
#   control:  {"task_id":"...","verb":"interrupt"|"relaunch","note":"..."}
#
# `view` is read-only except for the observational cache behavior already owned
# by fm-fleet-snapshot.sh. No command writes Copilot state or uses a private app
# API. FM_HOME must be explicit for every mutating or client-bound operation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  printf 'fm-captain-surface: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

[ -n "${FM_HOME:-}" ] || die "FM_HOME must be set explicitly"
[ -d "$FM_HOME" ] || die "FM_HOME is not a directory: $FM_HOME"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || die "state directory is missing: $STATE"
command -v jq >/dev/null 2>&1 || die "jq is required"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

ROOT="$STATE/captain-surfaces"
INPUTS="$ROOT/inputs.jsonl"
OUTPUTS="$ROOT/outputs.jsonl"
INPUT_CURSOR="$ROOT/.input-cursor"
INPUTS_VALIDATED="$ROOT/.inputs-validated"
OUTPUTS_VALIDATED="$ROOT/.outputs-validated"
CLIENTS="$ROOT/clients"
RECEIPTS="$ROOT/receipts"
LOCK="$ROOT/.lock"
MAX_SAFE_SEQ=9007199254740991
MAX_PAYLOAD_BYTES=16384
MAX_BODY_BYTES=16384
OUTCOME_BATCH=100
LOCK_HELD=0

cleanup() {
  if [ "$LOCK_HELD" = 1 ]; then
    LOCK_HELD=0
    fm_lock_release "$LOCK" || true
  fi
}
trap cleanup EXIT

private_mode() { # <path>
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

link_count() { # <path>
  stat -f '%l' "$1" 2>/dev/null || stat -c '%h' "$1" 2>/dev/null
}

file_size() { # <path>
  stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1" 2>/dev/null
}

assert_private_dir() { # <path>
  local path=$1 mode
  [ -d "$path" ] && [ ! -L "$path" ] || die "unsafe captain-surface directory: $path"
  mode=$(private_mode "$path") || die "cannot inspect captain-surface directory: $path"
  [ "$mode" = 700 ] || die "captain-surface directory must have mode 0700: $path (mode $mode)"
}

assert_private_file() { # <path>
  local path=$1 mode links
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || die "unsafe captain-surface file: $path"
  mode=$(private_mode "$path") || die "cannot inspect captain-surface file: $path"
  [ "$mode" = 600 ] || die "captain-surface file must have mode 0600: $path (mode $mode)"
  links=$(link_count "$path") || die "cannot inspect captain-surface file links: $path"
  [ "$links" = 1 ] || die "captain-surface file must not be hard linked: $path"
}

ensure_root() {
  umask 077
  if [ ! -e "$ROOT" ]; then
    mkdir "$ROOT" || die "cannot create $ROOT"
    chmod 0700 "$ROOT"
  fi
  assert_private_dir "$ROOT"
  for path in "$CLIENTS" "$RECEIPTS"; do
    if [ ! -e "$path" ]; then
      mkdir "$path" || die "cannot create $path"
      chmod 0700 "$path"
    fi
    assert_private_dir "$path"
  done
  for path in "$INPUTS" "$OUTPUTS" "$INPUT_CURSOR" "$INPUTS_VALIDATED" "$OUTPUTS_VALIDATED"; do
    assert_private_file "$path"
  done
}

acquire() {
  fm_lock_acquire_wait "$LOCK"
  LOCK_HELD=1
}

release() {
  [ "$LOCK_HELD" = 1 ] || return 0
  LOCK_HELD=0
  fm_lock_release "$LOCK"
}

bounded_uint() {
  local value=$1
  case "$value" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#value}" -le "${#MAX_SAFE_SEQ}" ] && [ "$value" -le "$MAX_SAFE_SEQ" ]
}

validate_slug() { # <label> <value> [max]
  local label=$1 value=$2 max=${3:-128}
  case "$value" in ''|*[!A-Za-z0-9._:-]*) die "$label must be a privacy-safe identifier" ;; esac
  [ "${#value}" -le "$max" ] || die "$label exceeds $max characters"
}

validate_task_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) die "task id must be a privacy-safe slug" ;; esac
  [ "${#1}" -le 128 ] || die "task id exceeds 128 characters"
}

validate_one_line() { # <label> <value> [max]
  local label=$1 value=$2 max=${3:-512}
  case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) die "$label must be one line" ;; esac
  [ "${#value}" -le "$max" ] || die "$label exceeds $max characters"
}

now() {
  local value=${FM_CAPTAIN_SURFACE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  case "$value" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) printf '%s\n' "$value" ;;
    *) die "FM_CAPTAIN_SURFACE_NOW must be a UTC YYYY-MM-DDTHH:MM:SSZ timestamp" ;;
  esac
}

assert_jsonl_terminated() { # <path>
  [ -s "$1" ] || return 0
  perl -e 'open my $f, "<:raw", $ARGV[0] or exit 2; seek $f, -1, 2 or exit 2; read $f, my $b, 1; exit($b eq "\n" ? 0 : 1)' "$1" \
    || die "refusing operation because the store has an unterminated record: $1"
}

validation_cache_fresh() { # <store> <cache>
  local store=$1 cache=$2 cached current
  [ -e "$cache" ] || return 1
  assert_private_file "$cache"
  cached=$(cat "$cache" 2>/dev/null) || return 1
  case "$cached" in ''|*[!0-9]*) return 1 ;; esac
  current=$(file_size "$store") || return 1
  [ "$cached" = "$current" ]
}

validation_cache_store() { # <store> <cache>
  local store=$1 cache=$2 size tmp
  size=$(file_size "$store") || return 0
  tmp=$(mktemp "$ROOT/.vcache.XXXXXX") || return 0
  chmod 0600 "$tmp"
  printf '%s\n' "$size" > "$tmp"
  mv -f -- "$tmp" "$cache"
}

validate_inputs() {
  [ -e "$INPUTS" ] || return 0
  assert_private_file "$INPUTS"
  assert_jsonl_terminated "$INPUTS"
  validation_cache_fresh "$INPUTS" "$INPUTS_VALIDATED" && return 0
  jq -e -s '
    (to_entries | all(
      (.value | keys) == ["authority","client","correlation_id","created_at","generation","kind","payload","provenance","schema","seq"]
      and .value.schema == "firstmate.captain-surface-input.v1"
      and (.value.seq == (.key + 1))
      and (.value.seq <= 9007199254740991)
      and (.value.created_at | type == "string")
      and (.value.client | type == "string" and test("^[A-Za-z0-9._:-]{1,64}$"))
      and (.value.generation | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$"))
      and (.value.correlation_id | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$"))
      and (.value.provenance | keys) == ["class","message_id","session_id"]
      and (.value.provenance.class == "direct-user" or .value.provenance.class == "agent" or .value.provenance.class == "system" or .value.provenance.class == "extension")
      and (.value.provenance.message_id | type == "string" and length <= 256 and (test("[\\t\\r\\n]") | not))
      and (.value.provenance.session_id | type == "string" and length <= 256 and (test("[\\t\\r\\n]") | not))
      and (.value.kind == "request" or .value.kind == "decision" or .value.kind == "control")
      and (.value.authority | keys) == ["can_authorize_sensitive","class","scope"]
      and (.value.authority.can_authorize_sensitive | type == "boolean")
      and (.value.authority.class | type == "string")
      and (.value.authority.scope | type == "string")
      and (.value.payload | type == "object")
      and (if .value.kind == "request" then
             (.value.payload | keys) == ["text"]
             and (.value.payload.text | type == "string" and length <= 8192 and test("[^[:space:]]"))
           elif .value.kind == "decision" then
             (.value.payload | keys) == ["answer","decision_seq","mode","revision","task_id"]
             and (.value.payload.decision_seq | type == "number" and . >= 1 and . <= 9007199254740991 and . == floor)
             and (.value.payload.task_id | type == "string" and test("^[A-Za-z0-9._-]{1,128}$"))
             and (.value.payload.revision | type == "string" and length > 0 and length <= 256 and (test("[\\t\\r\\n]") | not))
             and (.value.payload.answer | type == "string" and length <= 8192 and test("[^[:space:]]"))
             and (.value.payload.mode == "done" or .value.payload.mode == "release")
           else
             (.value.payload | keys) == ["note","task_id","verb"]
             and (.value.payload.task_id | type == "string" and test("^[A-Za-z0-9._-]{1,128}$"))
             and (.value.payload.verb == "interrupt" or .value.payload.verb == "relaunch")
             and (.value.payload.note | type == "string" and length <= 4096)
             and (if .value.payload.verb == "relaunch" then (.value.payload.note | length > 0) else (.value.payload.note == "") end)
           end)
      and (if .value.provenance.class != "direct-user" then
             .value.authority == {can_authorize_sensitive:false,class:"non-authoritative-observation",scope:"none"}
           elif .value.kind == "request" then
             .value.authority == {can_authorize_sensitive:false,class:"ordinary-request",scope:"conversation"}
           elif .value.kind == "decision" then
             .value.authority.can_authorize_sensitive == true and .value.authority.class == "typed-decision"
             and .value.authority.scope == ("decision:" + .value.payload.task_id + "@" + .value.payload.revision)
           else
             .value.authority.can_authorize_sensitive == false and .value.authority.class == "typed-control"
             and .value.authority.scope == ("control:" + .value.payload.verb + ":" + .value.payload.task_id)
           end)
    ))
    and ((map(.correlation_id) | length) == (map(.correlation_id) | unique | length))
  ' "$INPUTS" >/dev/null 2>&1 || die "refusing operation because the input store is malformed or non-sequential"
  validation_cache_store "$INPUTS" "$INPUTS_VALIDATED"
}

validate_outputs() {
  [ -e "$OUTPUTS" ] || return 0
  assert_private_file "$OUTPUTS"
  assert_jsonl_terminated "$OUTPUTS"
  validation_cache_fresh "$OUTPUTS" "$OUTPUTS_VALIDATED" && return 0
  jq -e -s '
    (to_entries | all(
      (.value | keys) == ["correlation_id","created_at","kind","payload","schema","seq","task_ref"]
      and .value.schema == "firstmate.captain-surface-output.v1"
      and (.value.seq == (.key + 1))
      and (.value.seq <= 9007199254740991)
      and (.value.created_at | type == "string")
      and (.value.correlation_id | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$"))
      and (.value.kind == "outcome" or .value.kind == "decision" or .value.kind == "error" or .value.kind == "notice")
      and (.value.task_ref | type == "string" and (length == 0 or test("^[A-Za-z0-9._-]{1,128}$")))
      and (.value.payload | type == "object")
      and (if .value.kind == "decision" then
             (.value.payload | keys) == ["body","mode_options","revision","task_id"]
             and (.value.payload.body | type == "string" and length > 0 and length <= 16384)
             and (.value.payload.task_id | type == "string" and test("^[A-Za-z0-9._-]{1,128}$"))
             and (.value.payload.revision | type == "string" and length > 0 and length <= 256 and (test("[\\t\\r\\n]") | not))
             and (.value.payload.mode_options == ["done","release"])
           else
             (.value.payload | keys) == ["body"] and (.value.payload.body | type == "string" and length > 0 and length <= 16384)
           end)
    ))
    and ((map(.correlation_id) | length) == (map(.correlation_id) | unique | length))
  ' "$OUTPUTS" >/dev/null 2>&1 || die "refusing operation because the output store is malformed or non-sequential"
  validation_cache_store "$OUTPUTS" "$OUTPUTS_VALIDATED"
}

last_seq() { # <store>
  [ -s "$1" ] || { printf '0\n'; return; }
  tail -n 1 "$1" | jq -r '.seq'
}

read_marker() { # <path>
  local path=$1 value
  [ -e "$path" ] || { printf '0\n'; return; }
  assert_private_file "$path"
  value=$(cat "$path") || die "cannot read marker $path"
  bounded_uint "$value" || die "malformed sequence marker: $path"
  printf '%s\n' "$value"
}

write_marker() { # <path> <value>
  local path=$1 value=$2 tmp
  tmp=$(mktemp "$ROOT/.marker.XXXXXX") || die "cannot stage sequence marker"
  chmod 0600 "$tmp"
  printf '%s\n' "$value" > "$tmp"
  mv -f -- "$tmp" "$path"
}

client_path() { printf '%s/%s.json\n' "$CLIENTS" "$1"; }
client_ack_path() { printf '%s/%s.ack\n' "$CLIENTS" "$1"; }

validate_client_record() { # <path>
  assert_private_file "$1"
  jq -e '
    keys == ["canvas_capable","client","generation","registered_at","schema","sdk_version"]
    and .schema == "firstmate.captain-surface-client.v1"
    and (.client | type == "string")
    and (.generation | type == "string")
    and (.registered_at | type == "string")
    and (.sdk_version | type == "string")
    and (.canvas_capable | type == "boolean")
  ' "$1" >/dev/null 2>&1 || die "malformed captain-surface client record: $1"
}

require_generation() { # <client> <generation>
  local client=$1 generation=$2 path recorded
  validate_slug client "$client" 64
  validate_slug generation "$generation" 128
  path=$(client_path "$client")
  [ -e "$path" ] || die "captain-surface client is not registered: $client"
  validate_client_record "$path"
  recorded=$(jq -r '.generation' "$path")
  [ "$recorded" = "$generation" ] \
    || die "captain-surface client generation was replaced (current $recorded, received $generation)"
}

read_bounded_file() { # <path|-> <max> <destination>
  local source=$1 max=$2 destination=$3 size
  if [ "$source" = - ]; then
    cat > "$destination"
  else
    [ -f "$source" ] && [ ! -L "$source" ] || die "input is not a regular file: $source"
    cat -- "$source" > "$destination"
  fi
  size=$(LC_ALL=C wc -c < "$destination" | tr -d ' ')
  [ "$size" -gt 0 ] || die "input must not be empty"
  [ "$size" -le "$max" ] || die "input exceeds $max bytes"
}

canonical_payload() { # <kind> <path>
  local kind=$1 path=$2
  case "$kind" in
    request)
      jq -ceS '
        keys == ["text"]
        and (.text | type == "string" and length <= 8192 and test("[^[:space:]]"))
      ' "$path" >/dev/null || die "request payload must contain only non-empty text of at most 8192 characters"
      ;;
    decision)
      jq -ceS '
        keys == ["answer","decision_seq","mode","revision","task_id"]
        and (.decision_seq | type == "number" and . >= 1 and . <= 9007199254740991 and . == floor)
        and (.task_id | type == "string" and test("^[A-Za-z0-9._-]{1,128}$"))
        and (.revision | type == "string" and length > 0 and length <= 256 and (test("[\\t\\r\\n]") | not))
        and (.answer | type == "string" and length <= 8192 and test("[^[:space:]]"))
        and (.mode == "done" or .mode == "release")
      ' "$path" >/dev/null || die "decision payload does not match the typed decision schema"
      ;;
    control)
      jq -ceS '
        keys == ["note","task_id","verb"]
        and (.task_id | type == "string" and test("^[A-Za-z0-9._-]{1,128}$"))
        and (.verb == "interrupt" or .verb == "relaunch")
        and (.note | type == "string" and length <= 4096)
        and (if .verb == "relaunch" then (.note | length > 0) else (.note == "") end)
      ' "$path" >/dev/null || die "control payload does not match the typed interrupt/relaunch schema"
      ;;
    *) die "unknown input kind: $kind" ;;
  esac
  jq -cS . "$path"
}

current_decision_revision() { # <task-id>
  local revision rc=0
  revision=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$1" --identity 2>/dev/null) || rc=$?
  case "$rc" in
    0) [ -n "$revision" ] || die "captain decision $1 has an empty revision" ;;
    1|3) die "captain decision $1 is no longer open" ;;
    *) die "captain decision $1 could not be read safely" ;;
  esac
  printf '%s\n' "$revision"
}

validate_decision_offer() { # <payload-json>
  local payload=$1 decision_seq task revision offered current
  decision_seq=$(printf '%s' "$payload" | jq -r '.decision_seq')
  task=$(printf '%s' "$payload" | jq -r '.task_id')
  revision=$(printf '%s' "$payload" | jq -r '.revision')
  [ -s "$OUTPUTS" ] || die "typed decision references an absent offer"
  offered=$(jq -c --argjson seq "$decision_seq" 'select(.seq == $seq and .kind == "decision")' "$OUTPUTS")
  [ -n "$offered" ] || die "typed decision references an absent offer sequence"
  [ "$(printf '%s' "$offered" | jq -r '.payload.task_id')" = "$task" ] \
    || die "typed decision task does not match its offered task"
  [ "$(printf '%s' "$offered" | jq -r '.payload.revision')" = "$revision" ] \
    || die "typed decision revision does not match its offered revision"
  if jq -e --arg task "$task" --arg revision "$revision" --argjson seq "$decision_seq" \
      'select(.kind == "decision" and .payload.task_id == $task and .seq > $seq and .payload.revision != $revision)' \
      "$OUTPUTS" >/dev/null; then
    die "typed decision offer has been superseded"
  fi
  current=$(current_decision_revision "$task")
  [ "$current" = "$revision" ] || die "typed decision revision is stale"
}

notify_input() { # <seq>
  local seq=$1
  fm_wake_append check "captain-surface:$seq" \
    "check: captain surface input $seq; inspect with bin/fm-captain-surface.sh inputs"
}

append_output_locked() { # <kind> <correlation> <task-ref> <payload-json>
  local kind=$1 correlation=$2 task_ref=$3 payload=$4 existing comparable last seq record
  existing=''
  if [ -s "$OUTPUTS" ]; then
    existing=$(jq -c --arg correlation "$correlation" 'select(.correlation_id == $correlation)' "$OUTPUTS")
  fi
  comparable=$(jq -cnS --arg kind "$kind" --arg task_ref "$task_ref" --argjson payload "$payload" \
    '{kind:$kind,task_ref:$task_ref,payload:$payload}')
  if [ -n "$existing" ]; then
    if [ "$(printf '%s' "$existing" | jq -cS '{kind,task_ref,payload}')" = "$comparable" ]; then
      printf '%s\n' "$existing" | jq -r '.seq'
      return 0
    fi
    die "output correlation id already names different content"
  fi
  last=$(last_seq "$OUTPUTS")
  [ "$last" -lt "$MAX_SAFE_SEQ" ] || die "output sequence space is exhausted"
  seq=$((last + 1))
  record=$(jq -cn \
    --arg schema firstmate.captain-surface-output.v1 \
    --argjson seq "$seq" --arg created_at "$(now)" --arg correlation_id "$correlation" \
    --arg kind "$kind" --arg task_ref "$task_ref" --argjson payload "$payload" \
    '{schema:$schema,seq:$seq,created_at:$created_at,correlation_id:$correlation_id,kind:$kind,task_ref:$task_ref,payload:$payload}')
  printf '%s\n' "$record" >> "$OUTPUTS"
  chmod 0600 "$OUTPUTS"
  validate_outputs
  printf '%s\n' "$seq"
}

command_register() {
  local client='' generation='' sdk_version='' canvas_capable='' path tmp client_count
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --client) client=${2:-}; shift 2 ;;
      --generation) generation=${2:-}; shift 2 ;;
      --sdk-version) sdk_version=${2:-}; shift 2 ;;
      --canvas-capable) canvas_capable=${2:-}; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  validate_slug client "$client" 64
  validate_slug generation "$generation" 128
  validate_one_line sdk-version "$sdk_version" 128
  case "$canvas_capable" in true|false) ;; *) die "--canvas-capable must be true or false" ;; esac
  ensure_root
  acquire
  validate_inputs
  validate_outputs
  path=$(client_path "$client")
  if [ ! -e "$path" ]; then
    client_count=$(find "$CLIENTS" -mindepth 1 -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
    [ "$client_count" -lt 32 ] || die "captain-surface client limit reached"
  fi
  tmp=$(mktemp "$CLIENTS/.client.XXXXXX") || die "cannot stage client record"
  jq -cn --arg schema firstmate.captain-surface-client.v1 --arg client "$client" \
    --arg generation "$generation" --arg registered_at "$(now)" --arg sdk_version "$sdk_version" \
    --argjson canvas_capable "$canvas_capable" \
    '{schema:$schema,client:$client,generation:$generation,registered_at:$registered_at,sdk_version:$sdk_version,canvas_capable:$canvas_capable}' > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$path"
  release
  jq -c . "$path"
}

command_ingress() {
  local client='' generation='' correlation='' provenance='' kind='' payload_file=''
  local session_id='' message_id='' tmp payload authority_class authority_scope can_sensitive=false
  local existing comparable last seq record decision_task decision_revision notify_rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --client) client=${2:-}; shift 2 ;;
      --generation) generation=${2:-}; shift 2 ;;
      --correlation-id) correlation=${2:-}; shift 2 ;;
      --provenance) provenance=${2:-}; shift 2 ;;
      --kind) kind=${2:-}; shift 2 ;;
      --payload-file) payload_file=${2:-}; shift 2 ;;
      --session-id) session_id=${2:-}; shift 2 ;;
      --message-id) message_id=${2:-}; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  validate_slug client "$client" 64
  validate_slug generation "$generation" 128
  validate_slug correlation "$correlation" 128
  case "$provenance" in direct-user|agent|system|extension) ;; *) die "unknown provenance class" ;; esac
  validate_one_line session-id "$session_id" 256
  validate_one_line message-id "$message_id" 256
  [ -n "$payload_file" ] || die "--payload-file is required"
  ensure_root
  tmp=$(mktemp "$ROOT/.payload.XXXXXX") || die "cannot stage payload"
  trap 'rm -f -- "$tmp"; cleanup' EXIT
  read_bounded_file "$payload_file" "$MAX_PAYLOAD_BYTES" "$tmp"
  payload=$(canonical_payload "$kind" "$tmp")
  rm -f -- "$tmp"
  trap cleanup EXIT

  authority_class=non-authoritative-observation
  authority_scope=none
  if [ "$provenance" = direct-user ]; then
    case "$kind" in
      request)
        authority_class=ordinary-request
        authority_scope=conversation
        ;;
      decision)
        decision_task=$(printf '%s' "$payload" | jq -r '.task_id')
        decision_revision=$(printf '%s' "$payload" | jq -r '.revision')
        authority_class=typed-decision
        authority_scope="decision:$decision_task@$decision_revision"
        can_sensitive=true
        ;;
      control)
        authority_class=typed-control
        authority_scope=$(printf '%s' "$payload" | jq -r '"control:" + .verb + ":" + .task_id')
        ;;
    esac
  fi

  acquire
  validate_inputs
  validate_outputs
  require_generation "$client" "$generation"
  existing=''
  if [ -s "$INPUTS" ]; then
    existing=$(jq -c --arg correlation "$correlation" 'select(.correlation_id == $correlation)' "$INPUTS")
  fi
  comparable=$(jq -cnS --arg client "$client" --arg generation "$generation" \
    --arg correlation_id "$correlation" --arg provenance "$provenance" \
    --arg session_id "$session_id" --arg message_id "$message_id" --arg kind "$kind" \
    --arg authority_class "$authority_class" --arg authority_scope "$authority_scope" \
    --argjson can_sensitive "$can_sensitive" --argjson payload "$payload" \
    '{client:$client,generation:$generation,correlation_id:$correlation_id,provenance:{class:$provenance,session_id:$session_id,message_id:$message_id},kind:$kind,authority:{class:$authority_class,scope:$authority_scope,can_authorize_sensitive:$can_sensitive},payload:$payload}')
  if [ -n "$existing" ]; then
    if [ "$(printf '%s' "$existing" | jq -cS 'del(.schema,.seq,.created_at)')" != "$comparable" ]; then
      die "input correlation id already names different content"
    fi
    seq=$(printf '%s' "$existing" | jq -r '.seq')
    release
    notify_input "$seq" || notify_rc=$?
    printf '%s\n' "$seq"
    [ "$notify_rc" -eq 0 ] || die "input $seq was already stored but could not notify Firstmate"
    return 0
  fi
  if [ "$authority_class" = typed-decision ]; then
    validate_decision_offer "$payload"
  fi
  last=$(last_seq "$INPUTS")
  [ "$last" -lt "$MAX_SAFE_SEQ" ] || die "input sequence space is exhausted"
  seq=$((last + 1))
  record=$(printf '%s' "$comparable" | jq -c --arg schema firstmate.captain-surface-input.v1 \
    --argjson seq "$seq" --arg created_at "$(now)" '. + {schema:$schema,seq:$seq,created_at:$created_at}')
  printf '%s\n' "$record" >> "$INPUTS"
  chmod 0600 "$INPUTS"
  validate_inputs
  release
  notify_input "$seq" || notify_rc=$?
  printf '%s\n' "$seq"
  [ "$notify_rc" -eq 0 ] || die "input $seq was stored but could not notify Firstmate"
}

command_inputs() {
  local cursor last
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  ensure_root
  acquire
  validate_inputs
  cursor=$(read_marker "$INPUT_CURSOR")
  last=$(last_seq "$INPUTS")
  [ "$cursor" -le "$last" ] || die "input cursor is ahead of the store"
  [ -s "$INPUTS" ] && jq -c --argjson cursor "$cursor" 'select(.seq > $cursor)' "$INPUTS"
  release
}

receipt_path() { printf '%s/%s.json\n' "$RECEIPTS" "$1"; }

validate_receipt() { # <path> <seq>
  assert_private_file "$1"
  jq -e --argjson seq "$2" '
    keys == ["diagnostic","finished_at","phase","schema","seq","started_at"]
    and .schema == "firstmate.captain-surface-application.v1"
    and .seq == $seq
    and (.phase == "claimed" or .phase == "complete" or .phase == "failed" or .phase == "ignored")
    and (.started_at | type == "string")
    and (.finished_at | type == "string")
    and (.diagnostic | type == "string")
  ' "$1" >/dev/null 2>&1 || die "malformed application receipt: $1"
}

write_receipt() { # <seq> <phase> <started> <diagnostic>
  local seq=$1 phase=$2 started=$3 diagnostic=$4 path tmp finished=''
  path=$(receipt_path "$seq")
  [ "$phase" = claimed ] || finished=$(now)
  tmp=$(mktemp "$RECEIPTS/.receipt.XXXXXX") || die "cannot stage application receipt"
  jq -cn --arg schema firstmate.captain-surface-application.v1 --argjson seq "$seq" \
    --arg phase "$phase" --arg started_at "$started" --arg finished_at "$finished" \
    --arg diagnostic "$diagnostic" \
    '{schema:$schema,seq:$seq,phase:$phase,started_at:$started_at,finished_at:$finished_at,diagnostic:$diagnostic}' > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$path"
}

publish_apply_outcome() { # <seq> <authority> <payload>
  local seq=$1 authority=$2 payload=$3 task verb body
  task=$(printf '%s' "$payload" | jq -r '.task_id')
  if [ "$authority" = typed-decision ]; then
    body="Typed decision for $task was applied through the captain-hold owner."
  else
    verb=$(printf '%s' "$payload" | jq -r '.verb')
    body="Typed $verb control for $task was applied through the lifecycle owner."
  fi
  printf '%s\n' "$body" | FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$0" publish --kind outcome --correlation-id "application:$seq" --body-file - --task-ref "$task" >/dev/null \
    || die "action completed but its captain-surface outcome could not be stored"
}

command_apply() {
  local seq='' row kind authority payload receipt started task revision answer mode verb note
  local decision_file stdout_file stderr_file rc=0 diagnostic phase offer_reason offer_rc stale_offer=0
  local -a owner_args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in --seq) seq=${2:-}; shift 2 ;; *) usage >&2; exit 2 ;; esac
  done
  bounded_uint "$seq" || die "--seq must be a positive safe integer"
  ensure_root
  acquire
  validate_inputs
  row=$([ -s "$INPUTS" ] && jq -c --argjson seq "$seq" 'select(.seq == $seq)' "$INPUTS" || true)
  [ -n "$row" ] || die "input sequence does not exist: $seq"
  kind=$(printf '%s' "$row" | jq -r '.kind')
  authority=$(printf '%s' "$row" | jq -r '.authority.class')
  payload=$(printf '%s' "$row" | jq -cS '.payload')
  receipt=$(receipt_path "$seq")
  if [ -e "$receipt" ]; then
    validate_receipt "$receipt" "$seq"
    phase=$(jq -r '.phase' "$receipt")
    case "$phase" in
      complete)
        jq -c . "$receipt"
        release
        publish_apply_outcome "$seq" "$authority" "$payload"
        return 0
        ;;
      ignored) jq -c . "$receipt"; release; return 0 ;;
      claimed) die "input $seq has an uncertain claimed application; reconcile it before any retry" ;;
      failed) die "input $seq has a retained failed application; reconcile it before any retry" ;;
    esac
  fi
  if [ "$kind" = request ]; then
    die "ordinary requests are handled conversationally, not by the typed application path"
  fi
  started=$(now)
  if [ "$authority" != typed-decision ] && [ "$authority" != typed-control ]; then
    write_receipt "$seq" ignored "$started" "non-authoritative provenance cannot dispatch an action"
    jq -c . "$receipt"
    release
    return 0
  fi
  if [ "$authority" = typed-decision ]; then
    offer_rc=0
    offer_reason=$( (validate_decision_offer "$payload") 2>&1 ) || offer_rc=$?
    if [ "$offer_rc" -ne 0 ]; then
      write_receipt "$seq" ignored "$started" "${offer_reason#fm-captain-surface: }"
      jq -c . "$receipt"
      release
      return 0
    fi
  fi
  write_receipt "$seq" claimed "$started" ""
  release

  stdout_file=$(mktemp "$ROOT/.apply-out.XXXXXX") || die "cannot stage owner output"
  stderr_file=$(mktemp "$ROOT/.apply-err.XXXXXX") || { rm -f -- "$stdout_file"; die "cannot stage owner diagnostics"; }
  chmod 0600 "$stdout_file" "$stderr_file"
  if [ "$authority" = typed-decision ]; then
    task=$(printf '%s' "$payload" | jq -r '.task_id')
    revision=$(printf '%s' "$payload" | jq -r '.revision')
    answer=$(printf '%s' "$payload" | jq -r '.answer')
    mode=$(printf '%s' "$payload" | jq -r '.mode')
    decision_file=$(mktemp "$ROOT/.decision.XXXXXX") || die "cannot stage typed decision"
    chmod 0600 "$decision_file"
    printf '%s\n' "$answer" > "$decision_file"
    owner_args=(answer "$task" --decision-file "$decision_file" --if-identity "$revision")
    [ "$mode" != release ] || owner_args+=(--release)
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-captain-hold.sh" "${owner_args[@]}" \
      >"$stdout_file" 2>"$stderr_file" || rc=$?
    rm -f -- "$decision_file"
  else
    task=$(printf '%s' "$payload" | jq -r '.task_id')
    verb=$(printf '%s' "$payload" | jq -r '.verb')
    note=$(printf '%s' "$payload" | jq -r '.note')
    owner_args=("$task" "$verb")
    [ "$verb" != relaunch ] || owner_args+=(--note "$note")
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-control.sh" "${owner_args[@]}" \
      >"$stdout_file" 2>"$stderr_file" || rc=$?
  fi
  diagnostic=$(cat "$stderr_file" "$stdout_file" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-1000)
  if [ "$rc" -ne 0 ] && [ "$authority" = typed-decision ] \
    && grep -qF -e 'no longer has the offered open-call identity' \
                -e 'has changed since the offered decision' "$stderr_file"; then
    stale_offer=1
  fi
  rm -f -- "$stdout_file" "$stderr_file"

  acquire
  if [ "$rc" -eq 0 ]; then
    write_receipt "$seq" complete "$started" "$diagnostic"
  elif [ "$stale_offer" -eq 1 ]; then
    write_receipt "$seq" ignored "$started" "typed decision offer became stale before dispatch: ${diagnostic#fm-captain-hold: }"
    jq -c . "$receipt"
    release
    return 0
  else
    write_receipt "$seq" failed "$started" "${diagnostic:-owner command failed with status $rc}"
    jq -c . "$receipt"
    release
    return "$rc"
  fi
  jq -c . "$receipt"
  release

  publish_apply_outcome "$seq" "$authority" "$payload"
}

command_mark_input_handled() {
  local through='' cursor last seq receipt phase typed_seqs
  while [ "$#" -gt 0 ]; do
    case "$1" in --through) through=${2:-}; shift 2 ;; *) usage >&2; exit 2 ;; esac
  done
  bounded_uint "$through" || die "--through must be a positive safe integer"
  ensure_root
  acquire
  validate_inputs
  cursor=$(read_marker "$INPUT_CURSOR")
  last=$(last_seq "$INPUTS")
  [ "$cursor" -le "$last" ] || die "input cursor is ahead of the store"
  [ "$through" -le "$last" ] || die "cannot acknowledge beyond the input store"
  [ "$through" -gt "$cursor" ] || { release; return 0; }
  typed_seqs=$(jq -r --argjson lo "$cursor" --argjson hi "$through" \
    'select(.seq > $lo and .seq <= $hi and (.kind == "decision" or .kind == "control")) | .seq' "$INPUTS")
  for seq in $typed_seqs; do
    receipt=$(receipt_path "$seq")
    [ -e "$receipt" ] || die "typed input $seq has no application receipt"
    validate_receipt "$receipt" "$seq"
    phase=$(jq -r '.phase' "$receipt")
    case "$phase" in complete|ignored) ;; *) die "typed input $seq is not completed or ignored" ;; esac
  done
  write_marker "$INPUT_CURSOR" "$through"
  release
}

command_publish() {
  local kind='' correlation='' body_file='' task_ref='' tmp payload seq
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind) kind=${2:-}; shift 2 ;;
      --correlation-id) correlation=${2:-}; shift 2 ;;
      --body-file) body_file=${2:-}; shift 2 ;;
      --task-ref) task_ref=${2:-}; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  case "$kind" in outcome|error|notice) ;; *) die "publish kind must be outcome, error, or notice" ;; esac
  validate_slug correlation-id "$correlation" 128
  [ -z "$task_ref" ] || validate_task_id "$task_ref"
  [ -n "$body_file" ] || die "--body-file is required"
  ensure_root
  tmp=$(mktemp "$ROOT/.body.XXXXXX") || die "cannot stage output body"
  trap 'rm -f -- "$tmp"; cleanup' EXIT
  read_bounded_file "$body_file" "$MAX_BODY_BYTES" "$tmp"
  payload=$(jq -Rs '{body:.}' "$tmp")
  rm -f -- "$tmp"
  trap cleanup EXIT
  acquire
  validate_outputs
  seq=$(append_output_locked "$kind" "$correlation" "$task_ref" "$payload")
  release
  printf '%s\n' "$seq"
}

command_offer_decision() {
  local task='' correlation='' body_file='' tmp revision payload seq
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift 2 ;;
      --correlation-id) correlation=${2:-}; shift 2 ;;
      --body-file) body_file=${2:-}; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  validate_task_id "$task"
  validate_slug correlation-id "$correlation" 128
  [ -n "$body_file" ] || die "--body-file is required"
  ensure_root
  tmp=$(mktemp "$ROOT/.body.XXXXXX") || die "cannot stage decision body"
  trap 'rm -f -- "$tmp"; cleanup' EXIT
  read_bounded_file "$body_file" "$MAX_BODY_BYTES" "$tmp"
  revision=$(current_decision_revision "$task")
  payload=$(jq -Rs --arg task_id "$task" --arg revision "$revision" \
    '{body:.,task_id:$task_id,revision:$revision,mode_options:["done","release"]}' "$tmp")
  rm -f -- "$tmp"
  trap cleanup EXIT
  acquire
  validate_outputs
  seq=$(append_output_locked decision "$correlation" "$task" "$payload")
  release
  printf '%s\n' "$seq"
}

command_outcomes() {
  local client='' generation='' ack last
  while [ "$#" -gt 0 ]; do
    case "$1" in --client) client=${2:-}; shift 2 ;; --generation) generation=${2:-}; shift 2 ;; *) usage >&2; exit 2 ;; esac
  done
  ensure_root
  acquire
  validate_outputs
  require_generation "$client" "$generation"
  ack=$(read_marker "$(client_ack_path "$client")")
  last=$(last_seq "$OUTPUTS")
  [ "$ack" -le "$last" ] || die "client output cursor is ahead of the store"
  [ -s "$OUTPUTS" ] && jq -c --argjson ack "$ack" 'select(.seq > $ack)' "$OUTPUTS" | awk "NR <= $OUTCOME_BATCH"
  release
}

command_ack_output() {
  local client='' generation='' through='' ack last
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --client) client=${2:-}; shift 2 ;;
      --generation) generation=${2:-}; shift 2 ;;
      --through) through=${2:-}; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  bounded_uint "$through" || die "--through must be a positive safe integer"
  ensure_root
  acquire
  validate_outputs
  require_generation "$client" "$generation"
  ack=$(read_marker "$(client_ack_path "$client")")
  last=$(last_seq "$OUTPUTS")
  [ "$ack" -le "$last" ] || die "client output cursor is ahead of the store"
  [ "$through" -le "$last" ] || die "cannot acknowledge beyond the output store"
  if [ "$through" -gt "$ack" ]; then
    write_marker "$(client_ack_path "$client")" "$through"
  fi
  release
}

command_client_state() {
  local client='' path ack=0
  while [ "$#" -gt 0 ]; do
    case "$1" in --client) client=${2:-}; shift 2 ;; *) usage >&2; exit 2 ;; esac
  done
  validate_slug client "$client" 64
  ensure_root
  acquire
  path=$(client_path "$client")
  [ -e "$path" ] || die "captain-surface client is not registered: $client"
  validate_client_record "$path"
  ack=$(read_marker "$(client_ack_path "$client")")
  jq -c --argjson acknowledged_through "$ack" '. + {acknowledged_through:$acknowledged_through}' "$path"
  release
}

command_view() {
  local client='' generation='' snapshot tmp ack input_cursor output_tail pending_count client_json
  while [ "$#" -gt 0 ]; do
    case "$1" in --client) client=${2:-}; shift 2 ;; --generation) generation=${2:-}; shift 2 ;; *) usage >&2; exit 2 ;; esac
  done
  ensure_root
  acquire
  require_generation "$client" "$generation"
  release
  tmp=$(mktemp "$ROOT/.snapshot.XXXXXX") || die "cannot stage fleet snapshot"
  trap 'rm -f -- "$tmp"; cleanup' EXIT
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$tmp" \
    || die "fleet snapshot is unavailable"
  snapshot=$(cat "$tmp")
  rm -f -- "$tmp"
  trap cleanup EXIT
  acquire
  validate_inputs
  validate_outputs
  require_generation "$client" "$generation"
  ack=$(read_marker "$(client_ack_path "$client")")
  input_cursor=$(read_marker "$INPUT_CURSOR")
  output_tail=$([ -s "$OUTPUTS" ] && tail -n 100 "$OUTPUTS" | jq -s '.' || printf '[]')
  pending_count=$([ -s "$INPUTS" ] && jq -s --argjson cursor "$input_cursor" '[.[] | select(.seq > $cursor)] | length' "$INPUTS" || printf '0')
  client_json=$(cat "$(client_path "$client")")
  jq -cn --arg schema firstmate.captain-surface-view.v1 --argjson client "$client_json" \
    --argjson acknowledged_through "$ack" --argjson pending_input_count "$pending_count" \
    --argjson fleet "$snapshot" --argjson messages "$output_tail" \
    '{schema:$schema,client:($client + {acknowledged_through:$acknowledged_through}),pending_input_count:$pending_input_count,fleet:$fleet,messages:$messages}'
  release
}

COMMAND=${1:-}
shift 2>/dev/null || true
case "$COMMAND" in
  register) command_register "$@" ;;
  ingress) command_ingress "$@" ;;
  inputs) command_inputs "$@" ;;
  apply) command_apply "$@" ;;
  mark-input-handled) command_mark_input_handled "$@" ;;
  publish) command_publish "$@" ;;
  offer-decision) command_offer_decision "$@" ;;
  outcomes) command_outcomes "$@" ;;
  ack-output) command_ack_output "$@" ;;
  client-state) command_client_state "$@" ;;
  view) command_view "$@" ;;
  *) usage >&2; exit 2 ;;
esac
