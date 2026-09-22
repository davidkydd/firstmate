#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the crew-to-primary write-guard (docs/crew-primary-write-guard.md).
#
# bin/fm-crew-primary-write-policy.mjs is the single owner of the block/allow
# decision; it reuses the shell classifier owned by bin/fm-arm-command-policy.mjs.
# bin/fm-crew-primary-write-check.sh is the stable transport: it gates on the
# crew-context env markers, dispatches on the tool name, drives the harness entry
# forms, and shapes the harness responses. This suite proves the decision matrix
# for both the write-tool arm and the Bash arm, the under-primary whitelist, the
# crew-context scoping (inert without the markers, i.e. the primary session), the
# harness-output shaping, the fail-open transport behavior, and the home
# expansion that catches the observed ~-prefixed absolute Write. No harness is
# spawned.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-crew-primary-write-check)
TASK_ID=mytask

# A primary-shaped checkout and a disjoint crew worktree. The guard keys off the
# exported markers, not git shape, so neither needs to be a git repo; state/ and
# data/<id>/ exist so the under-primary whitelist paths resolve.
PRIMARY="$TMP_ROOT/primary"
WORKTREE="$TMP_ROOT/wt"
mkdir -p "$PRIMARY/bin" "$PRIMARY/state" "$PRIMARY/data/$TASK_ID" "$WORKTREE/bin" "$WORKTREE/sub"
: > "$PRIMARY/AGENTS.md"
for f in fm-crew-primary-write-check.sh fm-hook-host-lib.sh fm-crew-primary-write-policy.mjs fm-arm-command-policy.mjs; do
  cp "$ROOT/bin/$f" "$PRIMARY/bin/$f"
done
chmod +x "$PRIMARY/bin/fm-crew-primary-write-check.sh" "$PRIMARY/bin/fm-crew-primary-write-policy.mjs"
CHECK="$PRIMARY/bin/fm-crew-primary-write-check.sh"

# Every guarded case uses the same private binding shape spawn writes.
BOUNDARY="$PRIMARY/state/$TASK_ID.write-boundary"
TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
cat > "$BOUNDARY" <<EOF
schema=fm-crew-write-boundary.v1
task=$TASK_ID
source=$PRIMARY
worktree=$WORKTREE
token=$TOKEN
EOF
chmod 0600 "$BOUNDARY"
export FM_TASK_ID="$TASK_ID"
export FM_CREW_WRITE_BOUNDARY_RECORD="$BOUNDARY"
export FM_CREW_WRITE_BOUNDARY_TOKEN="$TOKEN"

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-write-matrix.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")

# --- full decision matrix over write-tool and Bash arms --------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_MODES=()
MATRIX_VALUES=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_MODES+=("$3")
  MATRIX_VALUES+=("$4")
}

# DENY: a write tool targeting a path inside the primary checkout.
matrix_case P01 deny path "$PRIMARY/bin/new.sh"
matrix_case P02 deny path "$PRIMARY/AGENTS.md"
matrix_case P03 deny path "$PRIMARY/state/othertask.status"
matrix_case P04 deny path "$PRIMARY/data/othertask/report.md"
matrix_case P05 deny path "$PRIMARY"

# ALLOW: a write tool inside the crew's own worktree, or the whitelisted own
# status / scout report under the primary.
matrix_case P10 allow path "$WORKTREE/bin/new.sh"
matrix_case P11 allow path "$WORKTREE/sub/deep/file.txt"
matrix_case P12 allow path "$PRIMARY/state/$TASK_ID.status"
matrix_case P13 allow path "$PRIMARY/data/$TASK_ID/report.md"
matrix_case P14 allow path "relative/inside/worktree.txt"

# DENY: a Bash command whose cd / git -C / redirection target is the primary.
matrix_case C01 deny command "cd $PRIMARY && git commit -am x"
matrix_case C02 deny command "cd $PRIMARY"
matrix_case C03 deny command "pushd $PRIMARY"
matrix_case C04 deny command "git -C $PRIMARY commit -am x"
matrix_case C05 deny command "git --git-dir $PRIMARY/.git --work-tree $PRIMARY status"
matrix_case C06 deny command "echo hi >> $PRIMARY/bin/new.sh"
matrix_case C07 deny command "printf x > $PRIMARY/AGENTS.md"
matrix_case C08 deny command "(cd $PRIMARY && touch marker)"
matrix_case C09 deny command "cd $WORKTREE && echo x; cd $PRIMARY && git commit -am y"
matrix_case C10 deny command "chmod +x foo && echo done >> $PRIMARY/state/othertask.status"
matrix_case C11 deny command "touch $PRIMARY/bin/direct-write"
matrix_case C12 deny command "mkdir $PRIMARY/generated"
matrix_case C13 deny command "cp local-file $PRIMARY/bin/copied"
matrix_case C14 deny command "mv local-file $PRIMARY/bin/moved"
matrix_case C15 deny command "rm $PRIMARY/bin/old"

# ALLOW: a Bash command that stays inside the worktree, only reads the primary,
# or writes the whitelisted own status file.
matrix_case C20 allow command "cd $WORKTREE && git commit -am x"
matrix_case C21 allow command "git -C $WORKTREE status"
matrix_case C22 allow command "echo hi >> $WORKTREE/bin/new.sh"
matrix_case C23 allow command "echo working: x >> $PRIMARY/state/$TASK_ID.status"
matrix_case C24 allow command "cat $PRIMARY/AGENTS.md"
matrix_case C25 allow command "cat $WORKTREE/AGENTS.md | grep -q foo && ls"
matrix_case C26 allow command "ls -la"
matrix_case C27 allow command "cd $PRIMARY-sibling && touch f"
matrix_case C28 allow command "touch $PRIMARY/state/$TASK_ID.status"
matrix_case C29 allow command "mkdir -p $PRIMARY/state/$TASK_ID.inbox/handled"
matrix_case C30 allow command "mv $PRIMARY/state/$TASK_ID.inbox/001.msg $PRIMARY/state/$TASK_ID.inbox/handled/001.msg"

run_matrix_entry() {
  local id=$1 expected=$2 mode=$3 value=$4 entry=$5 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"

  case "$entry" in
    claude)
      if [ "$mode" = path ]; then
        payload=$(jq -cn --arg p "$value" '{tool_name:"Write",tool_input:{file_path:$p}}')
      else
        payload=$(jq -cn --arg c "$value" '{tool_name:"Bash",tool_input:{command:$c}}')
      fi
      printf '%s' "$payload" | "$CHECK" --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    cli)
      if [ "$mode" = path ]; then
        "$CHECK" --file-path "$value" >"$out_file" 2>"$err_file"
      else
        "$CHECK" --command "$value" >"$out_file" 2>"$err_file"
      fi
      rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\[crew-primary-write\\]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry the crew-primary-write reason code on stderr: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  fi
}

test_full_decision_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in claude cli; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "${MATRIX_MODES[$i]}" "${MATRIX_VALUES[$i]}" "$entry"
    done
  done
  pass "crew-primary-write decision matrix: ${#MATRIX_IDS[@]} cases x 2 entry forms, block/allow all correct"
}

# --- write-tool field coverage ---------------------------------------------

test_notebook_edit_path_field() {
  local payload out rc
  payload=$(jq -cn --arg p "$PRIMARY/notebooks/x.ipynb" '{tool_name:"NotebookEdit",tool_input:{notebook_path:$p}}')
  out=$(printf '%s' "$payload" | "$CHECK" --claude 2>&1); rc=$?
  expect_code 2 "$rc" "NotebookEdit into the primary must be denied via notebook_path"
  assert_contains "$out" '[crew-primary-write]' "NotebookEdit deny must carry the reason code"
  payload=$(jq -cn --arg p "$WORKTREE/notebooks/x.ipynb" '{tool_name:"NotebookEdit",tool_input:{notebook_path:$p}}')
  out=$(printf '%s' "$payload" | "$CHECK" --claude 2>&1); rc=$?
  expect_code 0 "$rc" "NotebookEdit inside the worktree must be allowed"
  [ -z "$out" ] || fail "NotebookEdit worktree allow must be silent: $out"
  pass "crew-primary-write: NotebookEdit notebook_path is inspected"
}

test_multi_harness_write_fields() {
  local payload out rc
  payload=$(jq -cn --arg p "$PRIMARY/bin/pi-write" '{toolName:"write_file",toolInput:{path:$p}}')
  out=$(printf '%s' "$payload" | "$CHECK" 2>&1); rc=$?
  expect_code 2 "$rc" "write_file path into the source checkout must be denied"
  assert_contains "$out" '[crew-primary-write]' "write_file deny must carry the reason code"
  payload=$(jq -cn --arg p "$WORKTREE/bin/pi-write" '{toolName:"replace",toolInput:{filePath:$p}}')
  out=$(printf '%s' "$payload" | "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "replace filePath inside the worktree must be allowed"
  [ -z "$out" ] || fail "replace worktree allow must be silent: $out"
  pass "crew-primary-write: alternate write tool names and path fields are inspected"
}

test_untargeted_tool_is_inert() {
  local payload out rc
  payload=$(jq -cn '{tool_name:"Read",tool_input:{file_path:"'"$PRIMARY"'/AGENTS.md"}}')
  out=$(printf '%s' "$payload" | "$CHECK" --claude 2>&1); rc=$?
  expect_code 0 "$rc" "a non-write, non-Bash tool (Read) must be inert"
  [ -z "$out" ] || fail "untargeted tool must be silent: $out"
  pass "crew-primary-write: an untargeted tool is inert"
}

# --- crew-context scoping (the inverse of the cd-guard) --------------------

test_inert_without_markers_is_primary_session() {
  local payload out rc
  payload=$(jq -cn --arg p "$PRIMARY/bin/new.sh" '{tool_name:"Write",tool_input:{file_path:$p}}')
  out=$(env -u FM_CREW_WRITE_BOUNDARY_RECORD -u FM_CREW_WRITE_BOUNDARY_TOKEN -u FM_TASK_ID \
    bash -c 'printf "%s" "$1" | "$2" --claude' _ "$payload" "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "without crew markers the guard must be inert (the primary session)"
  [ -z "$out" ] || fail "primary session must be silent: $out"
  pass "crew-primary-write: inert in the primary session (no crew markers exported)"
}

test_inert_with_only_one_marker() {
  local payload out rc
  payload=$(jq -cn --arg p "$PRIMARY/bin/new.sh" '{tool_name:"Write",tool_input:{file_path:$p}}')
  out=$(env -u FM_CREW_WRITE_BOUNDARY_TOKEN \
    bash -c 'printf "%s" "$1" | "$2" --claude' _ "$payload" "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "a half-set marker environment must be inert, never a block"
  [ -z "$out" ] || fail "half-marker environment must be silent: $out"
  pass "crew-primary-write: inert when only one marker is present"
}

test_binding_token_and_task_are_authenticated() {
  local payload out rc
  payload=$(jq -cn --arg p "$PRIMARY/bin/new.sh" '{tool_name:"Write",tool_input:{file_path:$p}}')
  out=$(FM_CREW_WRITE_BOUNDARY_TOKEN=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
    bash -c 'printf "%s" "$1" | "$2" --claude' _ "$payload" "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "a mismatched binding token must not adopt the record"
  [ -z "$out" ] || fail "mismatched binding token must be silent: $out"
  out=$(FM_TASK_ID=other-task bash -c 'printf "%s" "$1" | "$2" --claude' _ "$payload" "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "a mismatched task id must not adopt the record"
  [ -z "$out" ] || fail "mismatched binding task must be silent: $out"
  pass "crew-primary-write: the private record is bound to its random token and task id"
}

# --- home expansion (the devbox ~-prefixed absolute Write) ------------------

test_home_prefixed_absolute_write_is_resolved() {
  local home primary wt out rc
  home="$TMP_ROOT/home"
  primary="$home/code/firstmate"
  wt="$TMP_ROOT/home-wt"
  mkdir -p "$primary/bin" "$primary/state" "$wt"
  # The literal ~ is intentional: the policy, not the shell, must expand it.
  # shellcheck disable=SC2088
  local binding="$primary/state/$TASK_ID.write-boundary"
  cat > "$binding" <<EOF
schema=fm-crew-write-boundary.v1
task=$TASK_ID
source=$primary
worktree=$wt
token=$TOKEN
EOF
  chmod 0600 "$binding"
  # shellcheck disable=SC2088 # The guard, not this test shell, must expand the literal tilde.
  out=$(HOME="$home" FM_TASK_ID="$TASK_ID" FM_CREW_WRITE_BOUNDARY_RECORD="$binding" FM_CREW_WRITE_BOUNDARY_TOKEN="$TOKEN" \
    "$CHECK" --file-path '~/code/firstmate/bin/remote.sh' 2>&1); rc=$?
  expect_code 2 "$rc" "a ~-prefixed absolute Write into the primary must be denied"
  assert_contains "$out" '[crew-primary-write]' "home-prefixed deny must carry the reason code"
  out=$(HOME="$home" FM_TASK_ID="$TASK_ID" FM_CREW_WRITE_BOUNDARY_RECORD="$binding" FM_CREW_WRITE_BOUNDARY_TOKEN="$TOKEN" \
    "$CHECK" --command 'cd $HOME/code/firstmate && git commit -am x' 2>&1); rc=$?
  expect_code 2 "$rc" "a \$HOME-prefixed cd into the primary must be denied"
  pass "crew-primary-write: ~ and \$HOME prefixed absolute targets are resolved"
}

test_denial_precedes_source_mutation() {
  local target before out rc
  target="$PRIMARY/bin/protected.sh"
  printf 'original\n' > "$target"
  before=$(shasum -a 256 "$target")
  out=$("$CHECK" --command "printf changed > $target" 2>&1); rc=$?
  expect_code 2 "$rc" "source-checkout mutation must be denied before execution"
  [ "$(shasum -a 256 "$target")" = "$before" ] || fail "denied command changed the source checkout"
  assert_contains "$out" '[crew-primary-write]' "pre-mutation denial omitted its reason code"
  pass "crew-primary-write: a denied absolute-path vector changes no source-checkout bytes"
}

test_symlinked_ancestor_is_canonicalized() {
  local link out rc
  link="$TMP_ROOT/source-link"
  ln -s "$PRIMARY" "$link"
  out=$("$CHECK" --file-path "$link/bin/through-link.sh" 2>&1); rc=$?
  expect_code 2 "$rc" "a symlinked ancestor into the source checkout must be denied"
  assert_contains "$out" '[crew-primary-write]' "symlinked target deny must carry the reason code"
  pass "crew-primary-write: symlinked source-checkout ancestors are canonicalized"
}

# --- harness output shaping -------------------------------------------------

test_grok_stdin_shaping() {
  local payload out rc
  payload=$(jq -cn --arg c "cd $PRIMARY && git commit -am x" '{toolName:"run_terminal_command",toolInput:{command:$c}}')
  out=$(printf '%s' "$payload" | "$CHECK" 2>/dev/null); rc=$?
  expect_code 2 "$rc" "grok Bash stdin deny must exit 2"
  jq -e '.decision == "deny" and (.reason | test("\\[crew-primary-write\\]"))' <<<"$out" >/dev/null 2>&1 \
    || fail "grok deny must carry decision=deny on stdout: $out"
  pass "crew-primary-write: grok stdin (.toolName/.toolInput) yields the grok decision object"
}

test_cursor_shaping() {
  local payload out rc
  payload=$(jq -cn --arg p "$PRIMARY/bin/new.sh" '{tool_name:"Write",tool_input:{file_path:$p},cursor_version:"1.0"}')
  out=$(printf '%s' "$payload" | "$CHECK" --cursor 2>/dev/null); rc=$?
  expect_code 0 "$rc" "cursor deny returns exit 0 with its own decision object"
  jq -e '.permission == "deny" and (.user_message | test("\\[crew-primary-write\\]"))' <<<"$out" >/dev/null 2>&1 \
    || fail "cursor deny must return its permission object: $out"
  pass "crew-primary-write: cursor --cursor deny returns the cursor permission object"
}

test_foreign_host_payload_stands_down() {
  local payload out rc
  # A cursor_version-stamped payload without --cursor is the Claude-settings
  # duplicate cursor also loads; the shared predicate must stand it down.
  payload=$(jq -cn --arg p "$PRIMARY/bin/new.sh" '{tool_name:"Write",tool_input:{file_path:$p},cursor_version:"1.0"}')
  out=$(printf '%s' "$payload" | "$CHECK" --claude 2>&1); rc=$?
  expect_code 0 "$rc" "a foreign-host (cursor_version) payload without --cursor must stand down"
  [ -z "$out" ] || fail "foreign-host stand-down must be silent: $out"
  pass "crew-primary-write: a foreign-host payload stands down without re-classifying"
}

test_supported_hook_surface_shapes() {
  local payload out rc
  payload=$(jq -cn --arg c "touch $PRIMARY/bin/from-codex" '{tool_name:"Bash",tool_input:{command:$c}}')
  out=$(printf '%s' "$payload" | "$CHECK" 2>&1); rc=$?
  expect_code 2 "$rc" "Codex Bash-shaped payload must be denied"
  payload=$(jq -cn --arg c "touch $PRIMARY/bin/from-gemini" '{tool_name:"run_shell_command",tool_input:{command:$c}}')
  out=$(printf '%s' "$payload" | "$CHECK" 2>&1); rc=$?
  expect_code 2 "$rc" "Gemini shell-shaped payload must be denied"
  payload=$(jq -cn --arg p "$PRIMARY/bin/from-gemini-write" '{tool_name:"write_file",tool_input:{file_path:$p}}')
  out=$(printf '%s' "$payload" | "$CHECK" 2>&1); rc=$?
  expect_code 2 "$rc" "Gemini write-shaped payload must be denied"
  for entry in opencode pi omp; do
    out=$("$CHECK" --command "touch $PRIMARY/bin/from-$entry" 2>&1); rc=$?
    expect_code 2 "$rc" "$entry extracted command must be denied"
    out=$("$CHECK" --file-path "$PRIMARY/bin/from-$entry-write" 2>&1); rc=$?
    expect_code 2 "$rc" "$entry extracted write path must be denied"
  done
  pass "crew-primary-write: supported hook adapters converge on the same shell and native-write decisions"
}

# --- fail-open transport ----------------------------------------------------

test_fail_open_empty_stdin() {
  local out rc
  out=$(printf '' | "$CHECK" --claude 2>&1); rc=$?
  expect_code 0 "$rc" "empty stdin must fail open"
  [ -z "$out" ] || fail "empty stdin must be silent: $out"
  pass "crew-primary-write: empty stdin fails open"
}

test_fail_open_unparseable_json() {
  local out rc
  out=$(printf 'not json {' | "$CHECK" --claude 2>&1); rc=$?
  expect_code 0 "$rc" "unparseable JSON must fail open"
  [ -z "$out" ] || fail "unparseable JSON must be silent: $out"
  pass "crew-primary-write: unparseable JSON fails open"
}

test_fail_open_missing_node() {
  local payload out rc stub
  stub="$MATRIX_TMP/nonode"
  mkdir -p "$stub"
  for tool in jq bash sed cat dirname printf; do
    p=$(command -v "$tool" 2>/dev/null) && ln -sf "$p" "$stub/$tool" 2>/dev/null || true
  done
  payload=$(jq -cn --arg p "$PRIMARY/bin/new.sh" '{tool_name:"Write",tool_input:{file_path:$p}}')
  out=$(printf '%s' "$payload" | PATH="$stub" "$CHECK" --claude 2>&1); rc=$?
  expect_code 0 "$rc" "missing node must fail open"
  [ -z "$out" ] || fail "missing node must be silent: $out"
  pass "crew-primary-write: missing node fails open"
}

test_fail_open_missing_jq_on_stdin() {
  local payload out rc stub p
  stub="$MATRIX_TMP/nojq"
  mkdir -p "$stub"
  for tool in node bash sed cat dirname printf env; do
    p=$(command -v "$tool" 2>/dev/null) && ln -sf "$p" "$stub/$tool" 2>/dev/null || true
  done
  payload='{"tool_name":"Write","tool_input":{"file_path":"'"$PRIMARY"'/bin/new.sh"}}'
  out=$(printf '%s' "$payload" | PATH="$stub" "$CHECK" --claude 2>&1); rc=$?
  expect_code 0 "$rc" "missing jq on the stdin path must fail open"
  [ -z "$out" ] || fail "missing jq must be silent: $out"
  pass "crew-primary-write: missing jq on stdin fails open"
}

# --- policy CLI output contract --------------------------------------------

test_policy_cli_direct() {
  local pol out
  pol="$PRIMARY/bin/fm-crew-primary-write-policy.mjs"
  out=$(node "$pol" --primary "$PRIMARY" --worktree "$WORKTREE" --id "$TASK_ID" --file-path "$PRIMARY/bin/x.sh")
  case "$out" in
    "deny	crew-primary-write	"*) : ;;
    *) fail "policy CLI deny must be tab-separated deny<TAB>code<TAB>reason: $out" ;;
  esac
  out=$(node "$pol" --primary "$PRIMARY" --worktree "$WORKTREE" --id "$TASK_ID" --file-path "$WORKTREE/x.sh")
  [ "$out" = allow ] || fail "policy CLI allow must print exactly 'allow': $out"
  out=$(node "$pol" --primary "$PRIMARY" --worktree "$WORKTREE" --id "$TASK_ID")
  [ "$out" = allow ] || fail "policy CLI with no target must allow: $out"
  pass "crew-primary-write: policy CLI output contract (deny<TAB>code<TAB>reason / allow)"
}

# --- lint -------------------------------------------------------------------

test_scripts_are_lint_clean() {
  local out
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  out=$("$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-crew-primary-write-check.sh" 2>&1) \
    || fail "bin/fm-crew-primary-write-check.sh is not lint-clean: $out"
  pass "crew-primary-write: transport is clean under bin/fm-lint.sh"
}

test_full_decision_matrix
test_notebook_edit_path_field
test_multi_harness_write_fields
test_untargeted_tool_is_inert
test_inert_without_markers_is_primary_session
test_inert_with_only_one_marker
test_binding_token_and_task_are_authenticated
test_home_prefixed_absolute_write_is_resolved
test_denial_precedes_source_mutation
test_symlinked_ancestor_is_canonicalized
test_grok_stdin_shaping
test_cursor_shaping
test_foreign_host_payload_stands_down
test_supported_hook_surface_shapes
test_fail_open_empty_stdin
test_fail_open_unparseable_json
test_fail_open_missing_node
test_fail_open_missing_jq_on_stdin
test_policy_cli_direct
test_scripts_are_lint_clean
