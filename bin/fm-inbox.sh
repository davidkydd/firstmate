#!/usr/bin/env bash
# fm-inbox.sh - the captain's out-of-band capture surface.
#
# Solves four DIFFERENT problems with four different mechanisms, because they
# are not the same problem:
#
#   note    Queue an idea for firstmate while firstmate is mid-turn and cannot
#           answer. Writes a durable record and appends ONE `check` wake, so the
#           note survives a crash and is presented at firstmate's next drain.
#   external-note
#           Idempotently publish one item from a trusted external-transport
#           adapter. The adapter owns source and payload validation; this command
#           binds its source and opaque deduplication key to one deterministic
#           note while still writing and waking only through this inbox owner.
#           `note` (including `say`) and `external-note` are the only paths that
#           append to firstmate's wake queue.
#   say     Same as `note`, but the body comes from spoken audio on stdin.
#           Speech is an INPUT METHOD here, not an architecture: it transcribes
#           and then takes exactly the `note` path.
#   status  Answer "what is happening" from durable records ONLY. Reads no
#           network and appends NO wake, so it never interrupts work and is safe
#           to run in a loop.
#   ask     Answer a side question with a one-shot model call that never touches
#           firstmate, the backlog, or the wake queue. A side question is not
#           fleet work and must not become fleet work.
#
# Usage:
#   fm-inbox.sh note <text>...          | fm-inbox.sh note -   (body from stdin)
#   fm-inbox.sh external-note <source> <dedupe-key> -           (body from stdin)
#   fm-inbox.sh purge-external-handled <source> <retention-days> [limit]
#   fm-inbox.sh say  [<file.wav>]       (default: audio on stdin)
#   fm-inbox.sh status
#   fm-inbox.sh ask  <question>...
#   fm-inbox.sh list
#   fm-inbox.sh drain [--ack <id>...]
#
# Configuration. A region, a model id and an AWS profile name somebody's account
# and somebody's choices, so this file carries no default for any of them. Each is
# read from the home's gitignored config/ directory, or from the matching
# environment variable, and the model-backed subcommands refuse with the path to
# write rather than reaching for a value that belongs to another home. That
# configuration is also the opt-in: `say` and `ask` are off until it exists.
#
#   config/inbox-region     FM_INBOX_REGION     AWS region.            required
#   config/inbox-stt-model  FM_INBOX_STT_MODEL  speech-to-text model.  required by say
#   config/inbox-ask-model  FM_INBOX_ASK_MODEL  side-question model.   required by ask
#   config/inbox-profile    FM_INBOX_PROFILE    AWS profile.           optional
#
# An absent profile means the call uses whatever credentials are already in the
# environment, which is also what FM_INBOX_PROFILE= (empty) forces.
#
# `note`, `external-note`, `purge-external-handled`, `status`, `list`, and
# `drain` need NO configuration at all, because they make no model call. The
# voice handover depends on `note`, so it keeps working in a home that has
# configured nothing.
#
# Environment:
#   FM_HOME              operational home whose state/ and data/ are used.
#
# PRIVACY: `say` sends your audio and `ask` sends your question to Bedrock.
# `note`, `external-note`, `purge-external-handled`, `status`, `list`, and
# `drain` make no network call at all.
#
# `note` is also the queueing half of the spoken interface: when the voice agent
# in bin/fm-voice-relay.py hands real work over to firstmate, it runs this
# subcommand rather than carrying a second queue of its own. Keep the `note`
# contract stable for that caller. `status` is the HUMAN view of the records;
# bin/fm_voice_records.py owns the scope-controlled machine view the voice agent
# reads, because the voice agent must be able to answer without record free text
# ever reaching a model.
set -euo pipefail

# A non-interactive `ssh host fm-inbox.sh ...` does NOT get a login shell, so it
# does not get ~/.toolbox/bin on PATH. The AWS profile's credential_process is
# the bare word `ada`, so without this the model-backed subcommands fail with
# "[Errno 2] No such file or directory: 'ada'" while note/status still work.
# Verified: this is exactly what happens over SSH without the fix.
for _extra in "$HOME/.toolbox/bin" "$HOME/.local/bin"; do
  case ":$PATH:" in
    *":$_extra:"*) ;;
    *) [ -d "$_extra" ] && PATH="$_extra:$PATH" ;;
  esac
done
unset _extra
export PATH

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
INBOX="$STATE/inbox"
INBOX_LOCK="$INBOX/.mutation.lock"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

die() { printf 'fm-inbox: %s\n' "$*" >&2; exit 1; }

# First non-comment, non-blank line of a config file, or nothing.
read_setting() {  # <file-name>
  local path="$CONFIG/$1" line
  [ -r "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    printf '%s' "$line"
    return 0
  done < "$path"
}

# Refuse by naming the file to write. A model call that guessed at a region or an
# account would either fail confusingly or, worse, succeed against a stranger's.
require_setting() {  # <file-name> <env-var> <what>
  local value
  value=$(read_setting "$1")
  [ -n "$value" ] || die "no $3 is configured: write one line into $CONFIG/$1 or set $2"
  printf '%s' "$value"
}

REGION="${FM_INBOX_REGION:-}"
STT_MODEL="${FM_INBOX_STT_MODEL:-}"
ASK_MODEL="${FM_INBOX_ASK_MODEL:-}"
# Unset falls through to config; explicitly empty means "use ambient credentials".
PROFILE="${FM_INBOX_PROFILE-$(read_setting inbox-profile)}"

# Resolved only by the subcommands that make a model call, so note, status, list
# and drain keep working in a home that has configured nothing.
need_region() {
  [ -n "$REGION" ] || REGION=$(require_setting inbox-region FM_INBOX_REGION "AWS region")
}

need_stt_model() {
  need_region
  [ -n "$STT_MODEL" ] || STT_MODEL=$(require_setting inbox-stt-model \
    FM_INBOX_STT_MODEL "speech-to-text model")
}

need_ask_model() {
  need_region
  [ -n "$ASK_MODEL" ] || ASK_MODEL=$(require_setting inbox-ask-model \
    FM_INBOX_ASK_MODEL "side-question model")
}

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# The profile's credential_process (`ada`) costs a MEASURED ~1030ms on every
# single call, which is about half the wall time of `say` and `ask`. If real
# credentials are already in the environment, skip --profile entirely and let the
# ambient ones win. Set FM_INBOX_PROFILE= (empty) to force that even without env
# credentials present.
aws_call() {
  if [ -z "$PROFILE" ] || [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
    aws --region "$REGION" "$@"
  else
    aws --profile "$PROFILE" --region "$REGION" "$@"
  fi
}

# ---------------------------------------------------------------- note

# Append exactly one wake so firstmate picks the note up at its next drain.
# Failure to wake is NOT allowed to lose the note: the record is already on
# disk, so we report the wake failure and still exit non-zero loudly.
wake_payload() {
  printf 'check: captain inbox note %s - %s' "$1" "$2"
}

wake_for() {
  local id=$1 summary=$2 lib="$FM_ROOT/bin/fm-wake-lib.sh"
  if [ ! -r "$lib" ]; then
    printf 'fm-inbox: note saved but NOT announced (missing %s)\n' "$lib" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" . "$lib"
  fm_wake_append check "inbox:$id" "$(wake_payload "$id" "$summary")"
}

note_summary() {
  printf '%s' "$1" | tr '\n\t' '  ' | cut -c1-100
}

handled_external_note() {
  local source=$1 id=$2 indexed
  indexed="$INBOX/handled/external-$source/by-id/$id.note"
  if [ -f "$indexed" ] && [ ! -L "$indexed" ]; then
    printf '%s\n' "$indexed"
    return 0
  fi
  return 1
}

write_note_record() {  # <file> <id> <source> <body> [extra-header]
  local file=$1 id=$2 source=$3 body=$4 extra=${5:-}
  {
    printf 'id=%s\n' "$id"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'source=%s\n' "$source"
    [ -z "$extra" ] || printf '%s\n' "$extra"
    printf -- '--\n'
    printf '%s\n' "$body"
  } >"$file"
}

queue_note() {
  local source=$1 body=$2 extra=${3:-}
  [ -n "${body//[[:space:]]/}" ] || die "refusing to queue an empty note"
  mkdir -p "$INBOX"

  local tmp id summary staging_name
  tmp=$(mktemp "$INBOX/.staging-XXXXXX")
  staging_name=$(basename "$tmp")
  id="$(date +%s)-${staging_name#.staging-}"
  write_note_record "$tmp" "$id" "$source" "$body" "$extra"

  # Publish the completed note atomically.
  mv "$tmp" "$INBOX/$id.note"

  # One-line summary for the wake payload; the full body stays in the file.
  summary=$(note_summary "$body")
  printf 'queued %s\n' "$id"
  printf '  %s\n' "$summary"
  if wake_for "$id" "$summary"; then
    printf '  firstmate will pick this up at its next check.\n'
  else
    die "note $id is saved at $INBOX/$id.note but firstmate was NOT woken"
  fi
}

cmd_note() {
  local body
  if [ "$#" -eq 0 ]; then
    die "usage: fm-inbox.sh note <text>...   (or: note - to read stdin)"
  elif [ "$1" = "-" ]; then
    body=$(cat)
  else
    body="$*"
  fi
  queue_note text "$body"
}

external_wake_queued_locked() {
  local kind=$1 key=$2 queued_key
  while IFS= read -r queued_key; do
    [ "$queued_key" != "$key" ] || return 0
  done < <(fm_wake_queued_keys_locked "$kind")
  return 1
}

external_note_mutate_locked() {
  local source=$1 dedupe_key=$2 body=$3 id=$4 note=$5 wake_key=$6 summary=$7
  local handled_note status=0 release_status=0 tmp='' created=0 wake_locked=0
  EXTERNAL_NOTE_OUTCOME=queued
  EXTERNAL_NOTE_ERROR=durable
  if ! fm_lock_acquire_wait "$INBOX_LOCK"; then
    EXTERNAL_NOTE_ERROR=inbox-lock
    return 1
  fi

  if handled_note=$(handled_external_note "$source" "$id"); then
    if [ "$(sed -n '/^--$/,$p' "$handled_note" | tail -n +2)" != "$body" ]; then
      EXTERNAL_NOTE_ERROR=reused
      status=1
    else
      EXTERNAL_NOTE_OUTCOME=already-queued
    fi
  elif [ -f "$note" ] \
      && [ "$(sed -n '/^--$/,$p' "$note" | tail -n +2)" != "$body" ]; then
    EXTERNAL_NOTE_ERROR=reused
    status=1
  else
    if [ ! -f "$note" ]; then
      tmp=$(mktemp "$INBOX/.staging-XXXXXX") || status=$?
      [ "$status" -ne 0 ] \
        || write_note_record "$tmp" "$id" "$source" "$body" "external_id=$dedupe_key" || status=$?
      if [ "$status" -eq 0 ]; then
        if mv "$tmp" "$note"; then
          created=1
        else
          status=$?
          rm -f "$tmp" 2>/dev/null || true
        fi
      else
        rm -f "$tmp" 2>/dev/null || true
      fi
    fi
    if [ "$status" -eq 0 ]; then
      if fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"; then
        wake_locked=1
      else
        status=$?
      fi
    fi
    if [ "$status" -eq 0 ]; then
      { : >> "$FM_WAKE_QUEUE" && chmod 0600 "$FM_WAKE_QUEUE"; } || status=$?
    fi
    if [ "$status" -eq 0 ] && { [ "$created" -eq 1 ] \
        || ! external_wake_queued_locked check "$wake_key"; }; then
      fm_wake_append_locked check "$wake_key" "$(wake_payload "$id" "$summary")" || status=$?
    fi
  fi

  if [ "$wake_locked" -eq 1 ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || release_status=$?
    [ "$status" -ne 0 ] || status=$release_status
  fi
  release_status=0
  fm_lock_release "$INBOX_LOCK" || release_status=$?
  [ "$status" -ne 0 ] || status=$release_status
  return "$status"
}

cmd_external_note() {
  local source=${1:-} dedupe_key=${2:-} input=${3:-} body id note wake_key summary lib status
  [ "$#" -eq 3 ] && [ "$input" = "-" ] \
    || die "usage: fm-inbox.sh external-note <source> <dedupe-key> -"
  case "$source" in ''|*[!a-z0-9-]*|?????????????????????????????????*) die "invalid external-note source" ;; esac
  case "$dedupe_key" in ''|*[!a-z0-9_]*|?????????????????????????????????????????????????????????????????????????????????????????????????????*)
    die "invalid external-note dedupe key" ;;
  esac
  body=$(cat)
  [ -n "${body//[[:space:]]/}" ] || die "refusing to queue an empty note"
  umask 077

  id="external-$source-$dedupe_key"
  note="$INBOX/$id.note"
  wake_key="inbox:$id"
  summary=$(note_summary "$body")
  mkdir -p "$INBOX/handled/external-$source/by-id"
  chmod 0700 "$INBOX" "$INBOX/handled" "$INBOX/handled/external-$source" \
    "$INBOX/handled/external-$source/by-id"
  lib="$FM_ROOT/bin/fm-wake-lib.sh"
  [ -r "$lib" ] || die "missing $lib"
  # shellcheck source=/dev/null
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" . "$lib"

  if external_note_mutate_locked "$source" "$dedupe_key" "$body" "$id" "$note" "$wake_key" "$summary"; then
    printf '%s %s\n' "$EXTERNAL_NOTE_OUTCOME" "$id"
    return 0
  else
    status=$?
  fi
  case "$EXTERNAL_NOTE_ERROR" in
    reused) die "external note key was reused with different content: $dedupe_key" ;;
    inbox-lock) die "could not lock the inbox" ;;
    *) die "external note $id was not durably announced" ;;
  esac
}

cmd_purge_external_handled() {
  local source=${1:-} days=${2:-} limit=${3:-1000} file directory partition cutoff count=0 status=0
  local candidate_count=0 offset batch_size=100 source_root index_root index lib
  local candidates=() batch=() validated=() delete_paths=() expired_directories=()
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] \
    || die "usage: fm-inbox.sh purge-external-handled <source> <retention-days> [limit]"
  case "$source" in ''|*[!a-z0-9-]*|?????????????????????????????????*) die "invalid external-note source" ;; esac
  case "$days" in ''|*[!0-9]*|????*) die "retention days must be an integer from 1 through 365" ;; esac
  case "$limit" in ''|*[!0-9]*|??????*) die "purge limit must be an integer from 1 through 10000" ;; esac
  days=$((10#$days))
  limit=$((10#$limit))
  [ "$days" -ge 1 ] && [ "$days" -le 365 ] \
    || die "retention days must be an integer from 1 through 365"
  [ "$limit" -ge 1 ] && [ "$limit" -le 10000 ] \
    || die "purge limit must be an integer from 1 through 10000"
  source_root="$INBOX/handled/external-$source"
  index_root="$source_root/by-id"
  [ -d "$source_root" ] && [ ! -L "$source_root" ] || { printf 'purged 0\n'; return 0; }
  [ ! -e "$index_root" ] || { [ -d "$index_root" ] && [ ! -L "$index_root" ]; } \
    || die "invalid handled-note index"
  if ! cutoff=$(date -u -v-"${days}"d +%Y-%m-%d 2>/dev/null); then
    cutoff=$(date -u -d "$days days ago" +%Y-%m-%d 2>/dev/null) \
      || die "could not calculate the handled-note retention cutoff"
  fi

  lib="$FM_ROOT/bin/fm-wake-lib.sh"
  [ -r "$lib" ] || die "missing $lib"
  # shellcheck source=/dev/null
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" . "$lib"
  for directory in "$source_root"/????-??-??; do
    [ -d "$directory" ] && [ ! -L "$directory" ] || continue
    partition=${directory##*/}
    [[ "$partition" < "$cutoff" ]] || continue
    expired_directories+=("$directory")
  done
  while IFS= read -r -d '' file; do
    [ "$candidate_count" -lt "$limit" ] || break
    candidates[candidate_count]="$file"
    candidate_count=$((candidate_count + 1))
  done < <(
    for directory in "${expired_directories[@]}"; do
      find "$directory" -mindepth 1 -maxdepth 1 -type f \
        -name "external-$source-*.note" -mtime "+$((days - 1))" -print0
    done
  )
  for ((offset = 0; offset < candidate_count; offset += batch_size)); do
    batch=("${candidates[@]:offset:batch_size}")
    validated=()
    fm_lock_acquire_wait "$INBOX_LOCK" || die "could not lock the inbox"
    while IFS= read -r -d '' file; do
      validated+=("$file")
    done < <(find "${batch[@]}" -maxdepth 0 -type f \
      -name "external-$source-*.note" -mtime "+$((days - 1))" -print0 2>/dev/null)
    if [ "${#validated[@]}" -gt 0 ]; then
      delete_paths=()
      for file in "${validated[@]}"; do
        index="$index_root/${file##*/}"
        delete_paths+=("$file" "$index")
      done
      if rm -f -- "${delete_paths[@]}"; then
        count=$((count + ${#validated[@]}))
      else
        status=$?
      fi
    fi
    fm_lock_release "$INBOX_LOCK" || status=$?
    [ "$status" -eq 0 ] || break
  done
  [ "$status" -eq 0 ] || die "could not purge handled external notes"
  [ "${#expired_directories[@]}" -eq 0 ] \
    || rmdir -- "${expired_directories[@]}" 2>/dev/null || true
  printf 'purged %s\n' "$count"
}

# ---------------------------------------------------------------- say

cmd_say() {
  # Before the tool checks, so an unconfigured home is told what to configure
  # rather than what to install for a call it is not yet allowed to make.
  need_stt_model
  need aws
  need python3
  need base64

  local src wav raw transcript
  raw=$(mktemp /tmp/fm-inbox-audio-XXXXXX)
  wav=$(mktemp /tmp/fm-inbox-wav-XXXXXX.wav)
  # shellcheck disable=SC2064
  trap "rm -f '$raw' '$wav' '$wav.json'" EXIT

  if [ "$#" -ge 1 ] && [ "$1" != "-" ]; then
    src=$1
    [ -r "$src" ] || die "cannot read audio file: $src"
    cat "$src" >"$raw"
  else
    cat >"$raw"
  fi
  [ -s "$raw" ] || die "no audio received on stdin"

  # Accept a real WAV as-is; wrap headerless 16kHz mono s16le PCM if that is
  # what arrived. Anything else is rejected rather than silently mistranscribed.
  python3 - "$raw" "$wav" <<'PY'
import sys, wave
src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
if data[:4] == b'RIFF':
    open(dst, 'wb').write(data)
    sys.stderr.write("fm-inbox: input is WAV, passing through\n")
elif data[:4] in (b'OggS', b'fLaC') or data[:3] == b'ID3':
    sys.exit("fm-inbox: got Ogg/FLAC/MP3; re-encode to WAV first")
else:
    if len(data) % 2:
        data = data[:-1]
    w = wave.open(dst, 'wb')
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(data); w.close()
    sys.stderr.write("fm-inbox: input looked like raw PCM, wrapped as 16kHz mono WAV\n")
PY

  local secs
  secs=$(python3 -c "
import wave,sys
w=wave.open('$wav'); print(round(w.getnframes()/w.getframerate(),2))")
  printf 'fm-inbox: %ss of audio, transcribing with %s in %s\n' "$secs" "$STT_MODEL" "$REGION" >&2

  python3 - "$wav" "$wav.json" <<'PY'
import base64, json, sys
b = base64.b64encode(open(sys.argv[1], 'rb').read()).decode()
json.dump([{"role": "user", "content": [
    {"audio": {"format": "wav", "source": {"bytes": b}}},
    {"text": "Transcribe the speech exactly. Output only the transcript, nothing else."},
]}], open(sys.argv[2], 'w'))
PY

  transcript=$(aws_call bedrock-runtime converse \
    --model-id "$STT_MODEL" \
    --messages "file://$wav.json" \
    --inference-config '{"maxTokens":600,"temperature":0}' \
    --query 'output.message.content[0].text' --output text) \
    || die "transcription failed"

  [ -n "${transcript//[[:space:]]/}" ] || die "transcription came back empty"
  printf 'fm-inbox: heard: %s\n' "$transcript" >&2
  queue_note voice "$transcript" "transcript_model=$STT_MODEL
audio_seconds=$secs"
}

# ---------------------------------------------------------------- status

cmd_status() {
  local pending=0
  [ -d "$INBOX" ] && pending=$(find "$INBOX" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')

  printf '=== firstmate status (read-only, no wake sent) ===\n'
  printf 'home     %s\n' "$FM_HOME"
  printf 'time     %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'inbox    %s note(s) waiting for firstmate\n' "$pending"

  if [ -f "$DATA/backlog.md" ]; then
    printf '\n--- in flight ---\n'
    awk '/^## In flight/{f=1;next} /^## /{f=0} f && /^- \[/{print}' \
      "$DATA/backlog.md" | sed 's/^- \[ \] /  /' | cut -c1-150
  else
    printf '\n(no backlog at %s)\n' "$DATA/backlog.md"
  fi

  local any=0
  for m in "$STATE"/*.meta; do
    [ -e "$m" ] || break
    if [ "$any" -eq 0 ]; then printf '\n--- workers ---\n'; any=1; fi
    local id kind mode last
    id=$(basename "$m" .meta)
    kind=$(sed -n 's/^kind=//p' "$m" | head -1)
    mode=$(sed -n 's/^mode=//p' "$m" | head -1)
    last=""
    [ -f "$STATE/$id.status" ] && last=$(tail -1 "$STATE/$id.status" 2>/dev/null | cut -c1-100)
    printf '  %-42s %-6s %-10s %s\n' "$id" "${kind:-?}" "${mode:--}" "${last:-(no events yet)}"
  done
  [ "$any" -eq 1 ] || printf '\n(no workers on deck)\n'

  printf '\nNote: the last event line is history, not current state.\n'
}

# ---------------------------------------------------------------- ask

cmd_ask() {
  [ "$#" -gt 0 ] || die "usage: fm-inbox.sh ask <question>..."
  need_ask_model
  need aws
  need python3
  local q="$*" msg
  msg=$(mktemp /tmp/fm-inbox-ask-XXXXXX.json)
  # shellcheck disable=SC2064
  trap "rm -f '$msg'" EXIT

  Q="$q" python3 - "$msg" <<'PY'
import json, os, sys
json.dump([{"role": "user", "content": [{"text": os.environ["Q"]}]}],
          open(sys.argv[1], 'w'))
PY

  aws_call bedrock-runtime converse \
    --model-id "$ASK_MODEL" \
    --messages "file://$msg" \
    --system '[{"text":"You are a terse engineering assistant answering a side question. Be direct and concrete. No preamble. If you are not sure, say so."}]' \
    --inference-config '{"maxTokens":700,"temperature":0.2}' \
    --query 'output.message.content[0].text' --output text \
    || die "ask failed"
}

# ---------------------------------------------------------------- list / drain

cmd_list() {
  [ -d "$INBOX" ] || { printf '(inbox empty)\n'; return 0; }
  local any=0
  for f in "$INBOX"/*.note; do
    [ -e "$f" ] || break
    any=1
    printf '%s\n' "$(basename "$f" .note)"
    sed -n '/^--$/,$p' "$f" | tail -n +2 | sed 's/^/    /'
  done
  [ "$any" -eq 1 ] || printf '(inbox empty)\n'
}

cmd_drain() {
  if [ "${1:-}" = "--ack" ]; then
    shift
    [ "$#" -gt 0 ] || die "usage: fm-inbox.sh drain --ack <id>..."
    umask 077
    mkdir -p "$INBOX/handled"
    local id lib="$FM_ROOT/bin/fm-wake-lib.sh" status=0 note_source handled_dir handled_index
    [ -r "$lib" ] || die "missing $lib"
    # shellcheck source=/dev/null
    FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" . "$lib"
    fm_lock_acquire_wait "$INBOX_LOCK" || die "could not lock the inbox"
    for id in "$@"; do
      if [ -f "$INBOX/$id.note" ]; then
        handled_dir="$INBOX/handled"
        handled_index=""
        case "$id" in
          external-*)
            note_source=$(sed -n 's/^source=//p' "$INBOX/$id.note" | head -1)
            case "$note_source" in
              ''|*[!a-z0-9-]*|?????????????????????????????????*) status=1 ;;
              *)
                handled_dir="$INBOX/handled/external-$note_source/$(date -u +%Y-%m-%d)"
                handled_index="$INBOX/handled/external-$note_source/by-id/$id.note"
                mkdir -p "$handled_dir" "${handled_index%/*}" && chmod 0700 \
                  "$INBOX/handled/external-$note_source" "$handled_dir" "${handled_index%/*}" || status=$?
                ;;
            esac
            ;;
        esac
        if [ "$status" -eq 0 ] && [ -n "$handled_index" ]; then
          if [ -L "$handled_index" ] || { [ -e "$handled_index" ] && [ ! "$INBOX/$id.note" -ef "$handled_index" ]; }; then
            status=1
          elif [ ! -e "$handled_index" ]; then
            ln "$INBOX/$id.note" "$handled_index" || status=$?
          fi
        fi
        [ "$status" -ne 0 ] || mv "$INBOX/$id.note" "$handled_dir/$id.note" || status=$?
        [ "$status" -ne 0 ] || printf 'acked %s\n' "$id"
      else
        printf 'already-acked %s\n' "$id"
      fi
    done
    fm_lock_release "$INBOX_LOCK" || status=$?
    [ "$status" -eq 0 ] || die "could not acknowledge every inbox note"
    return 0
  fi
  cmd_list
  printf '\nAck with: fm-inbox.sh drain --ack <id>...\n'
}

# ---------------------------------------------------------------- dispatch

case "${1:-}" in
  note)          shift; cmd_note "$@" ;;
  external-note) shift; cmd_external_note "$@" ;;
  purge-external-handled) shift; cmd_purge_external_handled "$@" ;;
  say)           shift; cmd_say "$@" ;;
  status) shift; cmd_status ;;
  ask)    shift; cmd_ask "$@" ;;
  list)   shift; cmd_list ;;
  drain)  shift; cmd_drain "$@" ;;
  ''|-h|--help|help)
    # The whole header block, found rather than counted: everything after the
    # shebang up to the first line that is not a comment. A fixed line range
    # silently truncates this help the next time the header grows, and the last
    # thing to fall off the end is the PRIVACY paragraph, which is the one place
    # a new operator is told which subcommands send anything off this host.
    awk 'NR == 1 { next }
         /^#/ { sub(/^# ?/, ""); print; next }
         { exit }' "${BASH_SOURCE[0]}" ;;
  *) die "unknown subcommand: $1 (try --help)" ;;
esac
