#!/usr/bin/env bash
# Serialized read-modify-write for the secondmate registry (data/secondmates.md).
#
# ONE owner for every mutation of the shared secondmate registry, so concurrent
# spawn and teardown paths cannot lost-update each other. The registry is a single
# shared file edited in place: an add or a remove reads the whole file, filters it,
# and mv's a rewritten copy back. Two such rewrites racing each other each read the
# same old file and the second mv clobbers the first's change, silently dropping a
# secondmate entry. At ~10 crews that race is a matter of when, not if.
#
# The fix is to serialize the read-modify-write behind a home-scoped mutex. Every
# add and remove runs under a lock adjacent to the registry ("<reg>.lock"), reusing
# the same portable lock primitive the wake queue uses (fm_lock_acquire_wait /
# fm_lock_release from fm-wake-lib.sh). The lock is a DISTINCT path from the
# wake-queue lock and no path ever holds both, so the two cannot deadlock. Because
# the lock lives beside the registry and each FM_HOME has its own data/ directory,
# it is home-scoped by construction: a mutation in one home never blocks another.
#
# The on-disk FORMAT is unchanged. A mutation still ends in an atomic mv of a fully
# written temp file, so readers (session-start digest, routing, liveness) that grep
# "^- <id>( |$)" lock-free continue to see either the whole old file or the whole
# new file, never a partial one. Reads therefore need no lock; only the writer race
# does. secondmates_get stays a lock-free grep to match those existing readers.
#
# Registry line format (one per persistent secondmate), owned by
# secondmate-provisioning and consumed unchanged here:
#   - <id> - <summary> (home: <home>; scope: <scope>; projects: <csv>; added <date>)

FM_SECONDMATES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_SECONDMATES_LIB_DIR/fm-wake-lib.sh"

# _secondmates_rmw <reg> <id> [<line>]: locked read-modify-write. Drops every
# existing "^- <id>( |$)" line, then appends <line> when one is given (add) or
# nothing (remove), and mv's the result into place atomically. The id match is the
# same unescaped pattern every reader uses; secondmate ids are kebab slugs with a
# random suffix ([a-z0-9-]) so they carry no regex metacharacters. The lock is
# always released, even when a filter or mv fails.
_secondmates_rmw() {
  local reg=$1 id=$2 add_line=${3-} lock tmp rc=0
  lock="$reg.lock"
  mkdir -p "$(dirname "$reg")" 2>/dev/null || true
  fm_lock_acquire_wait "$lock"
  tmp="$reg.tmp.$$"
  if [ -f "$reg" ]; then
    grep -vE "^- $id( |$)" "$reg" > "$tmp" 2>/dev/null || true
  else
    : > "$tmp" || rc=1
  fi
  if [ "$rc" -eq 0 ] && [ -n "$add_line" ]; then
    printf '%s\n' "$add_line" >> "$tmp" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    mv "$tmp" "$reg" || rc=1
  fi
  [ "$rc" -eq 0 ] || rm -f "$tmp" 2>/dev/null || true
  fm_lock_release "$lock"
  return "$rc"
}

# secondmates_add <reg> <id> <line>: atomically replace <id>'s entry (or add it if
# absent) with the caller-composed <line>. The caller owns the line's content and
# format; this owns only that the write cannot race another mutation.
secondmates_add() {
  local reg=$1 id=$2 line=$3
  _secondmates_rmw "$reg" "$id" "$line"
}

# secondmates_remove <reg> <id>: atomically drop <id>'s entry. A no-op (success)
# when the registry file does not exist yet.
secondmates_remove() {
  local reg=$1 id=$2
  [ -f "$reg" ] || return 0
  _secondmates_rmw "$reg" "$id"
}

# secondmates_rename <reg> <old-id> <new-id> <new-line>: atomically replace <old-id>'s
# entry with the caller-composed <new-line> (which already carries <new-id>), under the
# same single lock as add/remove so a concurrent spawn or teardown cannot lost-update it.
# The drop-old-then-append-new must be ONE locked read-modify-write, not a remove()
# followed by an add(), because two separate lock acquisitions would let a racing
# mutation interleave between them. Refuses (return 3) when <old-id> is absent and
# (return 4) when <new-id> already has an entry, so a rename cannot silently drop a live
# secondmate or collide two ids onto one line. The caller owns the line's content and
# format (fm-secondmate-rename.sh recomposes it from the parsed old line).
secondmates_rename() {
  local reg=$1 old_id=$2 new_id=$3 new_line=$4 lock tmp rc=0
  lock="$reg.lock"
  mkdir -p "$(dirname "$reg")" 2>/dev/null || true
  fm_lock_acquire_wait "$lock"
  if [ ! -f "$reg" ] || ! grep -qE "^- $old_id( |$)" "$reg"; then
    fm_lock_release "$lock"
    return 3
  fi
  if grep -qE "^- $new_id( |$)" "$reg"; then
    fm_lock_release "$lock"
    return 4
  fi
  tmp="$reg.tmp.$$"
  grep -vE "^- $old_id( |$)" "$reg" > "$tmp" 2>/dev/null || true
  printf '%s\n' "$new_line" >> "$tmp" || rc=1
  if [ "$rc" -eq 0 ]; then
    mv "$tmp" "$reg" || rc=1
  fi
  [ "$rc" -eq 0 ] || rm -f "$tmp" 2>/dev/null || true
  fm_lock_release "$lock"
  return "$rc"
}

# secondmates_get <reg> <id>: print <id>'s registry line, or return non-zero when
# absent. Lock-free by design: mutations mv atomically, so a lock-free read is
# always consistent, matching the existing lock-free readers.
secondmates_get() {
  local reg=$1 id=$2 line
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

# CLI dispatch, so the LLM-driven add path can mutate the registry through the
# locked primitive instead of hand-editing the shared file.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -eu
  cmd=${1-}
  case "$cmd" in
    add)
      [ "$#" -eq 4 ] || { echo "usage: fm-secondmates-lib.sh add <reg> <id> <line>" >&2; exit 2; }
      secondmates_add "$2" "$3" "$4"
      ;;
    remove)
      [ "$#" -eq 3 ] || { echo "usage: fm-secondmates-lib.sh remove <reg> <id>" >&2; exit 2; }
      secondmates_remove "$2" "$3"
      ;;
    get)
      [ "$#" -eq 3 ] || { echo "usage: fm-secondmates-lib.sh get <reg> <id>" >&2; exit 2; }
      secondmates_get "$2" "$3"
      ;;
    rename)
      [ "$#" -eq 5 ] || { echo "usage: fm-secondmates-lib.sh rename <reg> <old-id> <new-id> <new-line>" >&2; exit 2; }
      secondmates_rename "$2" "$3" "$4" "$5"
      ;;
    *)
      echo "usage: fm-secondmates-lib.sh {add <reg> <id> <line>|remove <reg> <id>|get <reg> <id>|rename <reg> <old-id> <new-id> <new-line>}" >&2
      exit 2
      ;;
  esac
fi
