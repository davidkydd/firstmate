#!/usr/bin/env bash
# Shared extraction of secondmate registry summary and scope from a charter.
# Source only. Explicit FM_SECONDMATE_* values win, then a valid tracked role
# definition for the current id, then the filled charter sections.

# shellcheck source=bin/fm-fleet-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-fleet-lib.sh"

normalize_registry_text() {
  awk '
    {
      gsub(/[;()]/, " ")
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, "")
      sub(/ $/, "")
      if ($0 != "") out = out (out == "" ? "" : " ") $0
    }
    END { print out }
  '
}

brief_section_text() {
  local brief=$1 heading=$2
  awk -v heading="# $heading" '
    $0 == heading { in_section=1; next }
    in_section && /^# / { exit }
    in_section { print }
  ' "$brief"
}

registry_summary_for_brief() { # <brief> [current-role-id]
  local brief=$1 id=${2:-} value
  if [ -n "${FM_SECONDMATE_CHARTER:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_CHARTER" | normalize_registry_text
  elif [ -n "$id" ] && value=$(fm_fleet_charter_summary "$id"); then
    printf '%s\n' "$value" | normalize_registry_text
  else
    brief_section_text "$brief" "Charter" | normalize_registry_text
  fi
}

registry_scope_for_brief() { # <brief> [current-role-id]
  local brief=$1 id=${2:-} value
  if [ -n "${FM_SECONDMATE_SCOPE:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_SCOPE" | normalize_registry_text
  elif [ -n "$id" ] && value=$(fm_fleet_routing_scope "$id"); then
    printf '%s\n' "$value" | normalize_registry_text
  else
    brief_section_text "$brief" "Routing scope" | normalize_registry_text
  fi
}
