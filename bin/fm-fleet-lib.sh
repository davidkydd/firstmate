#!/usr/bin/env bash
# shellcheck disable=SC2034 # FM_FLEET_ERROR is an output for callers that source this library.
# Read-only access to tracked persistent-role definitions in fleet/agents/.
# Source only. fleet/README.md owns the definition/instance boundary and
# fleet/schema/agent.schema.json documents the accepted record shape.

fm_fleet_root() {
  if [ -n "${FM_FLEET_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_FLEET_OVERRIDE"
    return 0
  fi
  if [ -n "${FM_ROOT:-}" ]; then
    printf '%s/fleet\n' "$FM_ROOT"
    return 0
  fi
  printf '%s/fleet\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
}

fm_fleet_code_root() {
  if [ -n "${FM_ROOT:-}" ]; then
    printf '%s\n' "$FM_ROOT"
  elif [ -n "${FM_FLEET_OVERRIDE:-}" ]; then
    printf '%s\n' "$(cd "$FM_FLEET_OVERRIDE/.." 2>/dev/null && pwd -P)"
  else
    printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
}

fm_fleet_id_valid() {
  case "${1:-}" in
    '' | *[!a-z0-9._-]* | [._-]*) return 1 ;;
  esac
  return 0
}

fm_fleet_entry_path_unchecked() {
  local id=$1 root path
  fm_fleet_id_valid "$id" || return 1
  root=$(fm_fleet_root) || return 1
  path="$root/agents/$id.json"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  printf '%s\n' "$path"
}

fm_fleet_entry_valid() { # <path> [expected-id]
  local file=$1 expected=${2:-} root code_root id asset resolved
  command -v jq >/dev/null 2>&1 || {
    FM_FLEET_ERROR="jq is required to validate fleet role definitions"
    return 1
  }
  [ -f "$file" ] && [ ! -L "$file" ] || {
    FM_FLEET_ERROR="role definition is unavailable or unsafe: $file"
    return 1
  }
  if ! jq -e '
    type == "object" and
    ((keys_unsorted - ["id","rename","archetype","charterSummary","routingScope","charter","projects","assets","actions","periodic"]) | length == 0) and
    (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]*$")) and
    (.rename == null) and
    (.archetype == "secondmate") and
    (.charterSummary | type == "string" and length > 0) and
    (.routingScope | type == "string" and length > 0) and
    (.charter | type == "string" and length > 0) and
    (.projects == "none" or .projects == "dynamic") and
    (.assets | type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z0-9._/-]+$") and (startswith("/") | not) and (contains("..") | not))) and
    (.actions | type == "object" and
      ((keys_unsorted - ["reviewPost","vote","mergeAdo"]) | length == 0) and
      (.reviewPost == "explicit-only" or .reviewPost == "not-applicable") and
      .vote == "never" and .mergeAdo == "never") and
    ((has("periodic") | not) or
      (.periodic | type == "object" and
       ((keys_unsorted - ["cadenceSeconds","watchFile","watchSections"]) | length == 0) and
       (.cadenceSeconds | type == "number" and floor == . and . >= 60) and
       (.watchFile | type == "string" and startswith("data/") and (contains("..") | not)) and
       (.watchSections | type == "array" and length > 0 and all(.[]; type == "string" and test("^[^|\\r\\n]+$")))))
  ' "$file" >/dev/null 2>&1; then
    FM_FLEET_ERROR="invalid persistent-role definition: $file"
    return 1
  fi
  id=$(jq -r '.id' "$file") || return 1
  if [ -n "$expected" ] && [ "$id" != "$expected" ]; then
    FM_FLEET_ERROR="role definition id $id does not match requested id $expected"
    return 1
  fi
  if [ -n "$expected" ]; then
    case "${file##*/}" in
      "$id.json") ;;
      *) FM_FLEET_ERROR="role definition filename does not match current id $id: $file"; return 1 ;;
    esac
  fi
  code_root=$(fm_fleet_code_root) || return 1
  while IFS= read -r asset; do
    case "$asset" in '' | /* | *..*) FM_FLEET_ERROR="unsafe role asset for $id: $asset"; return 1 ;; esac
    [ -f "$code_root/$asset" ] && [ ! -L "$code_root/$asset" ] || {
      FM_FLEET_ERROR="missing role asset for $id: $asset"
      return 1
    }
    resolved=$(cd "$(dirname "$code_root/$asset")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$asset")") || {
      FM_FLEET_ERROR="unresolvable role asset for $id: $asset"
      return 1
    }
    case "$resolved" in "$code_root"/*) ;; *) FM_FLEET_ERROR="role asset escapes the code root for $id: $asset"; return 1 ;; esac
  done < <(jq -r '.assets[]' "$file")
  return 0
}

fm_fleet_entry_path() { # <current-id>
  local id=$1 path
  path=$(fm_fleet_entry_path_unchecked "$id") || return 1
  fm_fleet_entry_valid "$path" "$id" || return 1
  printf '%s\n' "$path"
}

fm_fleet_entry_field() { # <current-id> <jq-filter>
  local id=$1 filter=$2 path value
  path=$(fm_fleet_entry_path "$id") || return 1
  value=$(jq -r "($filter) // empty" "$path" 2>/dev/null) || return 1
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

fm_fleet_charter_summary() { fm_fleet_entry_field "$1" '.charterSummary'; }
fm_fleet_routing_scope() { fm_fleet_entry_field "$1" '.routingScope'; }
fm_fleet_charter() { fm_fleet_entry_field "$1" '.charter'; }
fm_fleet_project_policy() { fm_fleet_entry_field "$1" '.projects'; }
fm_fleet_action_policy() { fm_fleet_entry_field "$1" ".actions.$2"; }
fm_fleet_periodic_cadence() { fm_fleet_entry_field "$1" '.periodic.cadenceSeconds'; }
fm_fleet_periodic_watch_file() { fm_fleet_entry_field "$1" '.periodic.watchFile'; }
fm_fleet_periodic_watch_sections() { fm_fleet_entry_field "$1" '.periodic.watchSections[]'; }

fm_fleet_validate_all() {
  local root required file id duplicate ids_file
  root=$(fm_fleet_root) || return 1
  [ -d "$root/agents" ] && [ ! -L "$root/agents" ] || {
    FM_FLEET_ERROR="fleet role directory is unavailable or unsafe: $root/agents"
    return 1
  }
  [ -f "$root/required-secondmates.json" ] && [ ! -L "$root/required-secondmates.json" ] || {
    FM_FLEET_ERROR="required role inventory is unavailable or unsafe: $root/required-secondmates.json"
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    FM_FLEET_ERROR="jq is required to validate fleet role definitions"
    return 1
  }
  jq -e 'type == "object" and .version == 1 and (.ids | type == "array" and length > 0 and all(.[]; type == "string" and test("^[a-z0-9][a-z0-9._-]*$")))' \
    "$root/required-secondmates.json" >/dev/null 2>&1 || {
      FM_FLEET_ERROR="invalid required role inventory: $root/required-secondmates.json"
      return 1
    }
  ids_file=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-ids.XXXXXX") || return 1
  : > "$ids_file"
  for file in "$root"/agents/*.json; do
    [ -e "$file" ] || continue
    fm_fleet_entry_valid "$file" || { rm -f -- "$ids_file"; return 1; }
    jq -r '.id' "$file" >> "$ids_file" || { rm -f -- "$ids_file"; return 1; }
  done
  duplicate=$(sort "$ids_file" | uniq -d | head -1)
  if [ -n "$duplicate" ]; then
    rm -f -- "$ids_file"
    FM_FLEET_ERROR="duplicate current role id: $duplicate"
    return 1
  fi
  for file in "$root"/agents/*.json; do
    [ -e "$file" ] || continue
    id=$(jq -r '.id' "$file") || { rm -f -- "$ids_file"; return 1; }
    case "${file##*/}" in
      "$id.json") ;;
      *)
        rm -f -- "$ids_file"
        FM_FLEET_ERROR="role definition filename does not match current id $id: $file"
        return 1
        ;;
    esac
  done
  while IFS= read -r required; do
    grep -qxF "$required" "$ids_file" || {
      rm -f -- "$ids_file"
      FM_FLEET_ERROR="missing required persistent-role definition: $required"
      return 1
    }
  done < <(jq -r '.ids[]' "$root/required-secondmates.json")
  rm -f -- "$ids_file"
  return 0
}
