#!/usr/bin/env bash
# Read-only lookup over the tracked declarative fleet definitions in fleet/agents/.
# Source only. Every function fails soft: with jq absent, the fleet dir absent, or
# no matching entry, it prints nothing and returns non-zero so callers fall back to
# today's path (the charter brief, the env override, the hand-maintained value).
# This keeps fleet/ an additive source: an un-migrated home with no entry behaves
# exactly as before. The definition schema is owned by fleet/schema/agent.schema.json
# and the folder contract by fleet/README.md; this lib never writes.
#
# An agent is matched by its live id OR its pending rename target, because the file
# name in fleet/agents/ tracks the eventual name while the .id field tracks the live
# id (e.g. deckhand.json carries id=fm-maintainer, rename=deckhand). Matching both
# means a lookup by either the current or the renamed id resolves the same entry.

# Resolve the tracked fleet root. FM_FLEET_OVERRIDE wins (tests), else $FM_ROOT/fleet,
# else derive from this script's location so the lib works when sourced standalone.
fm_fleet_dir() {
  if [ -n "${FM_FLEET_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_FLEET_OVERRIDE"
    return 0
  fi
  local root
  if [ -n "${FM_ROOT:-}" ]; then
    root=$FM_ROOT
  else
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  fi
  printf '%s\n' "$root/fleet"
}

fm_fleet_have_jq() {
  command -v jq >/dev/null 2>&1
}

# fm_fleet_entry_path <id>: print the path of the agents/*.json whose .id or .rename
# equals <id>. Return 1 (print nothing) when jq is absent, the dir is absent, or no
# entry matches. First match wins, in shell glob (lexical) order for determinism.
fm_fleet_entry_path() {
  local id=$1 dir f matched
  [ -n "$id" ] || return 1
  fm_fleet_have_jq || return 1
  dir="$(fm_fleet_dir)/agents"
  [ -d "$dir" ] || return 1
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    matched=$(jq -r --arg id "$id" \
      'if (.id == $id or .rename == $id) then "1" else empty end' "$f" 2>/dev/null) || continue
    if [ "$matched" = "1" ]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

# fm_fleet_entry_field <id> <jq-filter>: print the given field of the matched entry,
# or return 1 printing nothing when there is no entry or the field is null/absent.
fm_fleet_entry_field() {
  local id=$1 filter=$2 path value
  path=$(fm_fleet_entry_path "$id") || return 1
  value=$(jq -r "($filter) // empty" "$path" 2>/dev/null) || return 1
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# fm_fleet_charter_summary <id>: the entry's charterSummary, or 1/empty.
fm_fleet_charter_summary() {
  fm_fleet_entry_field "$1" '.charterSummary'
}

# fm_fleet_routing_scope <id>: the entry's routingScope, or 1/empty.
fm_fleet_routing_scope() {
  fm_fleet_entry_field "$1" '.routingScope'
}
