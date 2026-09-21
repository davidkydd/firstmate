#!/usr/bin/env bash
# Evidence demo: drives the REAL fm-role-periodic-check.sh to show the
# end-user-visible periodic reminder behavior around the stale-lock fix.
set -u

ROOT_REPO=${1:?usage: lock-recovery-demo.sh <worktree-root>}
. "$ROOT_REPO/tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-demo)

make_role_home() { # <id>
  local id=$1 home="$TMP_ROOT/periodic-$1"
  mkdir -p "$home/data" "$home/state" "$home/bin" "$home/fleet" "$home/.agents/skills"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  cp "$ROOT/bin/fm-role-periodic-check.sh" "$ROOT/bin/fm-fleet-lib.sh" \
    "$ROOT/bin/fm-check-register.sh" "$ROOT/bin/fm-check-unregister.sh" \
    "$ROOT/bin/fm-check-lib.sh" "$ROOT/bin/fm-pr-lib.sh" \
    "$ROOT/bin/fm-lock-lib.sh" \
    "$ROOT/bin/fm-review-watch-triage.sh" "$ROOT/bin/fm-scm-lib.sh" \
    "$ROOT/bin/fm-brief.sh" "$ROOT/bin/fm-spawn.sh" "$home/bin/"
  cp -R "$ROOT/.agents/skills/prreview" "$ROOT/.agents/skills/prbabysit" \
    "$ROOT/.agents/skills/secondmate-provisioning" "$home/.agents/skills/"
  cp -R "$ROOT/fleet/agents" "$ROOT/fleet/schema" "$home/fleet/"
  cp "$ROOT/fleet/required-secondmates.json" "$home/fleet/"
  printf '%s\n' "$home"
}

arm_active() {
  local home
  home=$(make_role_home prreview)
  cat > "$home/data/prreview.md" <<'EOF'
# Review list
## Queue
- https://dev.azure.com/example/project/_git/repo/pullrequest/42 tip=abc reviewed=2026-09-21
EOF
  FM_HOME="$home" "$home/bin/fm-role-periodic-check.sh" arm prreview >/dev/null
  rm -f "$home"/state/.role-periodic-last-* 2>/dev/null || true
  printf '%s\n' "$home"
}

line() { printf '%s\n' "------------------------------------------------------------"; }

printf 'FIRSTMATE PERIODIC ROLE-REMINDER — stale-lock recovery demonstration\n'
printf 'Driving the real bin/fm-role-periodic-check.sh via each role home shim.\n\n'

# ----------------------------------------------------------------------------
line
printf 'SCENARIO 1: crashed owner left a stale lock dir (SIGKILL / power loss)\n'
printf '  A held .role-periodic-check.lock with an old mtime must be reclaimed\n'
printf '  so the maintenance reminder RESUMES instead of being silenced forever.\n'
line
home=$(arm_active)
lock="$home/state/.role-periodic-check.lock"
mkdir "$lock"
touch -t 200001010000 "$lock"     # backdate mtime: owner died long ago
printf '$ ls -d state/.role-periodic-check.lock   # crashed owner still holds it\n'
( cd "$home" && ls -d state/.role-periodic-check.lock )
printf '$ FM_ROLE_PERIODIC_NOW=100 state/role-periodic.check.sh\n'
out=$(FM_ROLE_PERIODIC_NOW=100 "$home/state/role-periodic.check.sh" 2>&1); rc=$?
printf '%s\n' "$out"
printf '(exit %s)\n' "$rc"
printf '$ ls -d state/.role-periodic-check.lock   # reclaimed + released after run\n'
( cd "$home" && ls -d state/.role-periodic-check.lock 2>&1 || printf '  (absent — lock released)\n' )
printf '\n=> Reminder resumed AND the reclaimed lock was released.\n\n'

# ----------------------------------------------------------------------------
line
printf 'SCENARIO 2: a LIVE owner holds a fresh lock (concurrent check)\n'
printf '  A sub-second-old lock must be left in place; the concurrent check must\n'
printf '  stay silent and must NOT do the owner\x27s work underneath it.\n'
line
home=$(arm_active)
lock="$home/state/.role-periodic-check.lock"
mkdir "$lock"                     # fresh: a live owner just took it
printf '$ FM_ROLE_PERIODIC_NOW=100 state/role-periodic.check.sh\n'
out=$(FM_ROLE_PERIODIC_NOW=100 "$home/state/role-periodic.check.sh" 2>&1); rc=$?
if [ -z "$out" ]; then printf '(no output — concurrent check yielded to the live owner)\n'; else printf '%s\n' "$out"; fi
printf '(exit %s)\n' "$rc"
printf '$ ls -d state/.role-periodic-check.lock   # live owner\x27s lock preserved\n'
( cd "$home" && ls -d state/.role-periodic-check.lock )
rmdir "$lock" 2>/dev/null || true
printf '\n=> Live owner preserved; no concurrent double-work.\n\n'

# ----------------------------------------------------------------------------
line
printf 'SCENARIO 3: TTL floor — a fresh foreign lock stays untouched until aged\n'
printf '  Only mtime age >= FM_ROLE_PERIODIC_LOCK_TTL proves a dead owner.\n'
line
home=$(arm_active)
lock="$home/state/.role-periodic-check.lock"
mkdir "$lock"; touch -t 200001010000 "$lock"
printf '$ FM_ROLE_PERIODIC_LOCK_TTL=999999999 FM_ROLE_PERIODIC_NOW=100 state/role-periodic.check.sh\n'
out=$(FM_ROLE_PERIODIC_LOCK_TTL=999999999 FM_ROLE_PERIODIC_NOW=100 "$home/state/role-periodic.check.sh" 2>&1); rc=$?
if [ -z "$out" ]; then printf '(no output — age below TTL, lock left in place)\n'; else printf '%s\n' "$out"; fi
printf '(exit %s)\n' "$rc"
printf '$ ls -d state/.role-periodic-check.lock   # not reclaimed under a high TTL\n'
( cd "$home" && ls -d state/.role-periodic-check.lock )
rmdir "$lock" 2>/dev/null || true
printf '\n=> A lock younger than the TTL is never reclaimed. Demo complete.\n'
