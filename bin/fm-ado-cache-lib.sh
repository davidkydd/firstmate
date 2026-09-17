# shellcheck shell=bash
# shellcheck disable=SC2016  # jq filter bodies use single quotes so $vars are jq --arg refs, not shell expansions
# Local work-item cache layer for the ADO backlog backend. Split out of
# fm-ado-lib.sh (which sources this file) so the homegrown cache mechanics live
# in one cohesive unit; every function name and signature is unchanged, so
# callers that source fm-ado-lib.sh keep working with no change. See
# docs/ado-task-backend.md for the full backend contract.
#
# Depends on fm_ado_jq (defined in the core fm-ado-lib.sh, resolved at call
# time). This file defines the fm_ado_cache_* helpers.

# --- local cache -----------------------------------------------------------
# data/ado-cache.json maps firstmate id <-> ADO work item (the primary WI: the
# User Story for a ship item, or the Task for a scout/review item), plus the one
# standing Epic id. Reads hit this cache; a bounded refresh reconciles from ADO
# using System.Rev. It lives under data/ (NOT state/, which teardown wipes).
# Schema:
#   { "version": 1,
#     "items": { "<fm-id>": {wi,rev,state,kind,repo,parent,title,updated} },
#     "epic":  <wi> }
# wi is the primary work item; parent is the Epic WI. A ship item's per-stage and
# discovered-work child Tasks are not cached individually: they are children of
# the cached User Story (wi), discoverable live by their fm-id/fm-stage tags, so
# the id<->wi round-trip needs only the primary WI.

fm_ado_cache_path() {
  printf '%s\n' "${FM_ADO_CACHE:-$1/ado-cache.json}"
}

# fm_ado_cache_init <data-dir>
fm_ado_cache_init() {
  local data_dir=$1 cache
  cache=$(fm_ado_cache_path "$data_dir")
  if [ ! -f "$cache" ]; then
    mkdir -p "$(dirname "$cache")" 2>/dev/null || return 1
    printf '%s\n' '{"version":1,"items":{},"epic":null}' > "$cache" || return 1
  fi
  printf '%s\n' "$cache"
}

# fm_ado_cache_write <cache> <json>   (atomic replace)
fm_ado_cache_write() {
  local cache=$1 json=$2 tmp
  tmp=$(mktemp "$(dirname "$cache")/.ado-cache.XXXXXX") || return 1
  if printf '%s\n' "$json" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$cache" 2>/dev/null && return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# fm_ado_cache_get_wi <data-dir> <fm-id>  -> echo WI id or empty
fm_ado_cache_get_wi() {
  local cache
  cache=$(fm_ado_cache_path "$1")
  [ -f "$cache" ] || return 1
  fm_ado_jq -r --arg id "$2" '.items[$id].wi // empty' "$cache" 2>/dev/null
}

# fm_ado_cache_get_id <data-dir> <wi>  -> echo fm-id or empty (reverse lookup)
fm_ado_cache_get_id() {
  local cache
  cache=$(fm_ado_cache_path "$1")
  [ -f "$cache" ] || return 1
  fm_ado_jq -r --arg wi "$2" \
    'first((.items | to_entries[] | select(.value.wi == ($wi|tonumber)) | .key)) // empty' \
    "$cache" 2>/dev/null
}

# fm_ado_cache_get_epic <data-dir>  -> echo Epic WI id or empty
fm_ado_cache_get_epic() {
  local cache
  cache=$(fm_ado_cache_path "$1")
  [ -f "$cache" ] || return 1
  fm_ado_jq -r '.epic // empty' "$cache" 2>/dev/null
}

# fm_ado_cache_put_epic <data-dir> <wi>
fm_ado_cache_put_epic() {
  local data_dir=$1 wi=$2 cache json
  cache=$(fm_ado_cache_init "$data_dir") || return 1
  json=$(fm_ado_jq --argjson wi "$wi" '.epic = $wi' "$cache" 2>/dev/null) || return 1
  fm_ado_cache_write "$cache" "$json"
}

# fm_ado_cache_put <data-dir> <fm-id> <wi> <rev> <state> <kind> <repo> <parent> <title> <updated>
# wi is the primary work item (Story for ship, Task for scout/review); parent is
# the Epic WI. Merges into any existing item row rather than replacing it, so
# fields set separately (via fm_ado_cache_set_field / fm_ado_cache_set_rev)
# survive a re-add's item-row rewrite.
fm_ado_cache_put() {
  local data_dir=$1 id=$2 wi=$3 rev=$4 state=$5 kind=$6 repo=$7 parent=$8 title=$9 updated=${10}
  local cache json
  cache=$(fm_ado_cache_init "$data_dir") || return 1
  json=$(fm_ado_jq \
    --arg id "$id" --argjson wi "$wi" --argjson rev "${rev:-0}" \
    --arg state "$state" --arg kind "$kind" --arg repo "$repo" \
    --argjson parent "${parent:-0}" \
    --arg title "$title" --arg updated "$updated" \
    '.items[$id] = ((.items[$id] // {}) + {wi:$wi, rev:$rev, state:$state, kind:$kind, repo:$repo, parent:$parent, title:$title, updated:$updated})' \
    "$cache" 2>/dev/null) || return 1
  fm_ado_cache_write "$cache" "$json"
}

# fm_ado_cache_set_field <data-dir> <fm-id> <field> <value-string>
fm_ado_cache_set_field() {
  local data_dir=$1 id=$2 field=$3 value=$4 cache json
  cache=$(fm_ado_cache_path "$data_dir")
  [ -f "$cache" ] || return 1
  json=$(fm_ado_jq --arg id "$id" --arg f "$field" --arg v "$value" \
    'if .items[$id] then .items[$id][$f] = $v else . end' "$cache" 2>/dev/null) || return 1
  fm_ado_cache_write "$cache" "$json"
}

# fm_ado_cache_set_rev <data-dir> <fm-id> <rev>
# Store System.Rev as a JSON number (not a string) so change detection compares
# revs numerically, matching how fm_ado_cache_put writes rev.
fm_ado_cache_set_rev() {
  local data_dir=$1 id=$2 rev=$3 cache json
  cache=$(fm_ado_cache_path "$data_dir")
  [ -f "$cache" ] || return 1
  json=$(fm_ado_jq --arg id "$id" --argjson rev "${rev:-0}" \
    'if .items[$id] then .items[$id].rev = $rev else . end' "$cache" 2>/dev/null) || return 1
  fm_ado_cache_write "$cache" "$json"
}

# fm_ado_cache_remove <data-dir> <fm-id>
fm_ado_cache_remove() {
  local data_dir=$1 id=$2 cache json
  cache=$(fm_ado_cache_path "$data_dir")
  [ -f "$cache" ] || return 0
  json=$(fm_ado_jq --arg id "$id" 'del(.items[$id])' "$cache" 2>/dev/null) || return 1
  fm_ado_cache_write "$cache" "$json"
}
