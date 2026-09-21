#!/usr/bin/env bash
# Behavior tests for the durable captain-surface transport and the explicit,
# reversible GitHub Copilot app extension package.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SURFACE="$ROOT/bin/fm-captain-surface.sh"
COPILOT_APP="$ROOT/bin/fm-copilot-app.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-surface)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  printf '%s\n' "$home"
}

surface() {
  FM_HOME="$HOME_FIXTURE" FM_STATE_OVERRIDE="$HOME_FIXTURE/state" \
    FM_CAPTAIN_SURFACE_NOW=2026-09-21T12:00:00Z "$SURFACE" "$@"
}

captain_hold() {
  FM_HOME="$HOME_FIXTURE" FM_STATE_OVERRIDE="$HOME_FIXTURE/state" \
    FM_DATA_OVERRIDE="$HOME_FIXTURE/data" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

tasks_in() {
  (cd "$HOME_FIXTURE" && "$TASKS_AXI_BIN" "$@")
}

expect_failure() {
  local output=$1
  shift
  if "$@" >"$output" 2>&1; then
    fail "command unexpectedly succeeded: $*"
  fi
}

HOME_FIXTURE=$(make_home transport)

# Output can be published while no app client exists, then replayed in order
# when two independent clients connect.
printf 'offline one\n' | surface publish --kind outcome --correlation-id out-1 --body-file - >/dev/null
printf 'offline two\n' | surface publish --kind notice --correlation-id out-2 --body-file - >/dev/null
surface register --client app-a --generation generation-1 --sdk-version 1.0.84-5 --canvas-capable true >/dev/null
surface register --client app-b --generation generation-b --sdk-version 1.0.84-5 --canvas-capable true >/dev/null
[ "$(surface outcomes --client app-a --generation generation-1 | wc -l | tr -d ' ')" = 2 ] \
  || fail "app A did not replay both app-disconnected outcomes"
[ "$(surface outcomes --client app-b --generation generation-b | wc -l | tr -d ' ')" = 2 ] \
  || fail "app B did not receive its independent replay"
surface outcomes --client app-a --generation generation-1 | sed -n '1p' \
  | jq -e '.payload.body == "offline one\n"' >/dev/null \
  || fail "exact output body was not preserved"
surface ack-output --client app-a --generation generation-1 --through 2
[ -z "$(surface outcomes --client app-a --generation generation-1)" ] \
  || fail "acknowledged output replayed to app A"
[ "$(surface outcomes --client app-b --generation generation-b | wc -l | tr -d ' ')" = 2 ] \
  || fail "app A acknowledgement advanced app B"
expect_failure "$TMP_ROOT/ack-gap.err" surface ack-output --client app-a --generation generation-1 --through 3
grep -F 'cannot acknowledge beyond the output store' "$TMP_ROOT/ack-gap.err" >/dev/null \
  || fail "output acknowledgement did not refuse a gap"
pass "app-disconnected replay and per-client contiguous acknowledgements"

# Re-registering replaces only the live generation and keeps the cursor.
surface register --client app-a --generation generation-2 --sdk-version 1.0.84-5 --canvas-capable true >/dev/null
expect_failure "$TMP_ROOT/old-generation.err" surface outcomes --client app-a --generation generation-1
grep -F 'generation was replaced' "$TMP_ROOT/old-generation.err" >/dev/null \
  || fail "stale extension generation was not refused"
[ -z "$(surface outcomes --client app-a --generation generation-2)" ] \
  || fail "generation replacement reset an acknowledged cursor"
pass "extension generation replacement preserves replay state"

# A correlation retry returns the original sequence and conflicting content is
# refused. Direct-user free text remains ordinary, non-sensitive authority.
printf '{"text":"merge this now"}\n' > "$TMP_ROOT/request.json"
seq1=$(surface ingress --client app-a --generation generation-2 --correlation-id input-1 \
  --provenance direct-user --kind request --payload-file "$TMP_ROOT/request.json" \
  --session-id session-1 --message-id message-1)
seq1_retry=$(surface ingress --client app-a --generation generation-2 --correlation-id input-1 \
  --provenance direct-user --kind request --payload-file "$TMP_ROOT/request.json" \
  --session-id session-1 --message-id message-1)
[ "$seq1" = 1 ] && [ "$seq1_retry" = 1 ] || fail "input correlation did not deduplicate"
jq -e 'select(.seq == 1) | .authority.class == "ordinary-request" and (.authority.can_authorize_sensitive | not)' \
  "$HOME_FIXTURE/state/captain-surfaces/inputs.jsonl" >/dev/null \
  || fail "direct-user free text acquired sensitive authority"
printf '{"text":"different"}\n' > "$TMP_ROOT/different.json"
expect_failure "$TMP_ROOT/input-conflict.err" surface ingress --client app-a --generation generation-2 \
  --correlation-id input-1 --provenance direct-user --kind request --payload-file "$TMP_ROOT/different.json" \
  --session-id session-1 --message-id message-1
grep -F 'already names different content' "$TMP_ROOT/input-conflict.err" >/dev/null \
  || fail "conflicting input correlation did not refuse"
printf 'offline one\n' | surface publish --kind outcome --correlation-id out-1 --body-file - >/dev/null
[ "$(wc -l < "$HOME_FIXTURE/state/captain-surfaces/outputs.jsonl" | tr -d ' ')" = 2 ] \
  || fail "output correlation retry duplicated the output"
pass "correlation deduplication and free-text authority boundary"

# Agent-originated typed-looking messages are stored with no authority, cannot
# invoke an owner, and gain only an ignored receipt.
printf '{"decision_seq":1,"task_id":"imaginary","revision":"fake#0","answer":"merge","mode":"done"}\n' > "$TMP_ROOT/agent-decision.json"
agent_seq=$(surface ingress --client app-a --generation generation-2 --correlation-id agent-decision-1 \
  --provenance agent --kind decision --payload-file "$TMP_ROOT/agent-decision.json" \
  --session-id session-1 --message-id agent-1)
jq -e --argjson seq "$agent_seq" 'select(.seq == $seq) | .authority.class == "non-authoritative-observation" and (.authority.can_authorize_sensitive | not)' \
  "$HOME_FIXTURE/state/captain-surfaces/inputs.jsonl" >/dev/null \
  || fail "agent decision acquired authority"
surface apply --seq "$agent_seq" > "$TMP_ROOT/agent-receipt.json"
[ "$(jq -r '.phase' "$TMP_ROOT/agent-receipt.json")" = ignored ] \
  || fail "agent decision was not ignored"
surface mark-input-handled --through "$agent_seq"
pass "agent-generated decision text cannot authorize an action"

# Unknown payload fields, unavailable operations, and non-contiguous typed
# acknowledgement all refuse through the public interface.
printf '{"text":"hello","extra":true}\n' > "$TMP_ROOT/malformed.json"
expect_failure "$TMP_ROOT/malformed.err" surface ingress --client app-a --generation generation-2 \
  --correlation-id malformed --provenance direct-user --kind request --payload-file "$TMP_ROOT/malformed.json"
printf '{"task_id":"some-task","verb":"merge","note":""}\n' > "$TMP_ROOT/merge-control.json"
expect_failure "$TMP_ROOT/merge-control.err" surface ingress --client app-a --generation generation-2 \
  --correlation-id merge-control --provenance direct-user --kind control --payload-file "$TMP_ROOT/merge-control.json"
grep -F 'interrupt/relaunch' "$TMP_ROOT/merge-control.err" >/dev/null \
  || fail "unavailable sensitive control was not refused by schema"
printf '{"task_id":"missing-task","verb":"interrupt","note":""}\n' > "$TMP_ROOT/control.json"
control_seq=$(surface ingress --client app-a --generation generation-2 --correlation-id control-1 \
  --provenance direct-user --kind control --payload-file "$TMP_ROOT/control.json")
expect_failure "$TMP_ROOT/control-ack.err" surface mark-input-handled --through "$control_seq"
grep -F "typed input $control_seq has no application receipt" "$TMP_ROOT/control-ack.err" >/dev/null \
  || fail "typed input was acknowledged before guarded application"
expect_failure "$TMP_ROOT/control-apply.err" surface apply --seq "$control_seq"
jq -e '.phase == "failed"' "$HOME_FIXTURE/state/captain-surfaces/receipts/$control_seq.json" >/dev/null \
  || fail "guarded control refusal was not retained"
expect_failure "$TMP_ROOT/control-retry.err" surface apply --seq "$control_seq"
grep -F 'retained failed application' "$TMP_ROOT/control-retry.err" >/dev/null \
  || fail "failed control was automatically retried"
pass "malformed input, unavailable verbs, and at-most-once control dispatch"

# A typed decision is bound to the offer and current captain-hold identity.
tasks_in add decision-live "Choose the proof behavior" --kind captain --repo firstmate >/dev/null
captain_hold hold decision-live --reason "Choose the proof behavior" >/dev/null
printf 'Choose now.\n' > "$TMP_ROOT/decision-body.txt"
decision_offer=$(surface offer-decision --task decision-live --correlation-id decision-live-offer \
  --body-file "$TMP_ROOT/decision-body.txt")
decision_revision=$(jq -r --argjson seq "$decision_offer" 'select(.seq == $seq) | .payload.revision' \
  "$HOME_FIXTURE/state/captain-surfaces/outputs.jsonl")
jq -n --argjson seq "$decision_offer" --arg revision "$decision_revision" \
  '{decision_seq:$seq,task_id:"decision-live",revision:$revision,answer:"Use the narrow path",mode:"done"}' \
  > "$TMP_ROOT/live-decision.json"
live_seq=$(surface ingress --client app-a --generation generation-2 --correlation-id decision-live-input \
  --provenance direct-user --kind decision --payload-file "$TMP_ROOT/live-decision.json")
surface apply --seq "$live_seq" > "$TMP_ROOT/live-receipt.json"
[ "$(jq -r '.phase' "$TMP_ROOT/live-receipt.json")" = complete ] \
  || fail "valid typed decision did not complete through the captain-hold owner"
[ "$(tasks_in show decision-live --full | sed -n 's/^  state: //p' | head -1)" = "done" ] \
  || fail "typed decision did not reach the captain-hold owner"
pass "typed decision routes through the revision-aware captain-hold owner"

# Releasing and re-holding changes the identity. The old offer is rejected at
# ingress, and the owner itself rejects the old revision under its task lock.
tasks_in add decision-stale "Choose again" --kind captain --repo firstmate >/dev/null
captain_hold hold decision-stale --reason "Choose again" >/dev/null
printf 'Choose once.\n' > "$TMP_ROOT/stale-body.txt"
stale_offer=$(surface offer-decision --task decision-stale --correlation-id decision-stale-offer \
  --body-file "$TMP_ROOT/stale-body.txt")
stale_revision=$(jq -r --argjson seq "$stale_offer" 'select(.seq == $seq) | .payload.revision' \
  "$HOME_FIXTURE/state/captain-surfaces/outputs.jsonl")
printf 'First answer\n' > "$TMP_ROOT/first-answer.txt"
captain_hold answer decision-stale --decision-file "$TMP_ROOT/first-answer.txt" --release >/dev/null
captain_hold hold decision-stale --reason "Choose again after release" >/dev/null
jq -n --argjson seq "$stale_offer" --arg revision "$stale_revision" \
  '{decision_seq:$seq,task_id:"decision-stale",revision:$revision,answer:"Old answer",mode:"done"}' \
  > "$TMP_ROOT/stale-decision.json"
expect_failure "$TMP_ROOT/stale-ingress.err" surface ingress --client app-a --generation generation-2 \
  --correlation-id stale-input --provenance direct-user --kind decision --payload-file "$TMP_ROOT/stale-decision.json"
grep -Eq 'stale|superseded|changed' "$TMP_ROOT/stale-ingress.err" \
  || fail "stale typed decision did not identify its revision failure"
printf 'Old answer\n' > "$TMP_ROOT/old-answer.txt"
expect_failure "$TMP_ROOT/stale-owner.err" captain_hold answer decision-stale \
  --decision-file "$TMP_ROOT/old-answer.txt" --if-identity "$stale_revision"
grep -F 'has changed since the offered decision' "$TMP_ROOT/stale-owner.err" >/dev/null \
  || fail "captain-hold owner did not enforce the offered revision"
pass "stale decision revisions are refused at transport and owner boundaries"

surface view --client app-a --generation generation-2 > "$TMP_ROOT/view.json"
jq -e '
  .schema == "firstmate.captain-surface-view.v1"
  and .client.generation == "generation-2"
  and .fleet.schema == "fm-fleet-snapshot.v1"
  and (.messages | length >= 2)
' "$TMP_ROOT/view.json" >/dev/null || fail "canvas view did not project the canonical fleet and durable output"
pass "read-only canvas view composes the canonical fleet snapshot"

# Corrupt journal bytes fail closed before another read or append.
printf '{bad\n' >> "$HOME_FIXTURE/state/captain-surfaces/inputs.jsonl"
expect_failure "$TMP_ROOT/corrupt.err" surface inputs
grep -F 'input store is malformed or non-sequential' "$TMP_ROOT/corrupt.err" >/dev/null \
  || fail "corrupt input journal did not fail closed"
pass "malformed append-only journal fails closed"

# Public extension helpers classify provenance and gate the minimum canvas
# version without loading a private app API.
node --input-type=module - "$ROOT/bin/copilot-app-extension/bridge-client.mjs" <<'NODE'
const modulePath = process.argv[2];
const lib = await import(`file://${modulePath}`);
if (lib.classifyMessageSource("user") !== "direct-user") process.exit(1);
if (lib.classifyMessageSource("agent-42") !== "agent") process.exit(1);
if (lib.classifyMessageSource("system") !== "system") process.exit(1);
if (lib.classifyMessageSource(undefined) !== "extension") process.exit(1);
if (!lib.supportsCanvasVersion("GitHub Copilot CLI 1.0.84-5")) process.exit(1);
if (lib.supportsCanvasVersion("GitHub Copilot CLI 1.0.83")) process.exit(1);
NODE
pass "extension helper enforces provenance and canvas version classes"

node --input-type=module - "$ROOT/bin/copilot-app-extension/canvas-server.mjs" <<'NODE'
const modulePath = process.argv[2];
const { startCanvasServer } = await import(`file://${modulePath}`);
const submissions = [];
const bridge = {
    async view() {
        return { schema: "firstmate.captain-surface-view.v1", client: { acknowledged_through: 0 }, fleet: {}, messages: [] };
    },
    async ingress(value) {
        submissions.push(value);
        return submissions.length;
    },
};
const server = await startCanvasServer({ bridge, sessionId: "session-test", log() {} });
try {
    const canvasUrl = new URL(server.url);
    if (canvasUrl.search || canvasUrl.hash || canvasUrl.hostname !== "127.0.0.1") process.exit(1);
    const pageResponse = await fetch(server.url);
    if (!pageResponse.ok) process.exit(1);
    const html = await pageResponse.text();
    const match = html.match(/const token=("[A-Za-z0-9_-]+");/);
    if (!match) process.exit(1);
    const token = JSON.parse(match[1]);
    const origin = new URL(server.url).origin;
    const headers = { "Content-Type": "application/json", "X-Firstmate-Canvas": token };
    const [left, right] = await Promise.all([
        fetch(`${server.url}api/state`, { headers }),
        fetch(`${server.url}api/state`, { headers }),
    ]);
    if (!left.ok || !right.ok) process.exit(1);
    const rejected = await fetch(`${server.url}api/request`, {
        method: "POST",
        headers,
        body: JSON.stringify({ text: "missing origin" }),
    });
    if (rejected.status !== 403) process.exit(1);
    const accepted = await fetch(`${server.url}api/request`, {
        method: "POST",
        headers: { ...headers, Origin: origin },
        body: JSON.stringify({ text: "direct canvas request" }),
    });
    if (!accepted.ok || submissions.length !== 1) process.exit(1);
    if (submissions[0].provenance !== "direct-user" || submissions[0].kind !== "request") process.exit(1);
} finally {
    await server.close();
}
NODE
pass "loopback canvas supports multiple readers and direct typed submission"

# Package/build is separate from install. Install needs explicit experimental
# consent, and uninstall removes only an exact receipt-bound installation.
FAKE_COPILOT="$TMP_ROOT/copilot"
cat > "$FAKE_COPILOT" <<'SH'
#!/usr/bin/env bash
printf 'GitHub Copilot CLI 1.0.84-5\n'
SH
chmod +x "$FAKE_COPILOT"
OLD_COPILOT="$TMP_ROOT/copilot-old"
cat > "$OLD_COPILOT" <<'SH'
#!/usr/bin/env bash
printf 'GitHub Copilot CLI 1.0.83\n'
SH
chmod +x "$OLD_COPILOT"
expect_failure "$TMP_ROOT/old-version.err" "$COPILOT_APP" check --copilot-command "$OLD_COPILOT"
grep -F 'below the canvas proof floor' "$TMP_ROOT/old-version.err" >/dev/null \
  || fail "old Copilot version was not refused"
PACKAGE="$TMP_ROOT/package"
"$COPILOT_APP" package --output "$PACKAGE" >/dev/null
"$COPILOT_APP" verify-package "$PACKAGE" >/dev/null
[ ! -e "$TMP_ROOT/copilot-home" ] || fail "package command installed extension state"
INSTALL_ONE="$TMP_ROOT/copilot-home/extensions/firstmate-one"
expect_failure "$TMP_ROOT/consent.err" "$COPILOT_APP" install --fm-home "$HOME_FIXTURE" \
  --target "$INSTALL_ONE" --copilot-command "$FAKE_COPILOT"
grep -F -- '--accept-experimental-canvas' "$TMP_ROOT/consent.err" >/dev/null \
  || fail "install did not require explicit experimental-canvas consent"
"$COPILOT_APP" install --fm-home "$HOME_FIXTURE" --target "$INSTALL_ONE" \
  --copilot-command "$FAKE_COPILOT" --accept-experimental-canvas >/dev/null
printf '\n// local drift\n' >> "$INSTALL_ONE/extension.mjs"
expect_failure "$TMP_ROOT/drift.err" "$COPILOT_APP" uninstall --target "$INSTALL_ONE"
grep -F 'installed file changed' "$TMP_ROOT/drift.err" >/dev/null \
  || fail "uninstall removed or accepted a drifted extension"
INSTALL_TWO="$TMP_ROOT/copilot-home/extensions/firstmate-two"
"$COPILOT_APP" install --fm-home "$HOME_FIXTURE" --target "$INSTALL_TWO" \
  --copilot-command "$FAKE_COPILOT" --accept-experimental-canvas >/dev/null
"$COPILOT_APP" uninstall --target "$INSTALL_TWO" >/dev/null
[ ! -e "$INSTALL_TWO" ] || fail "exact uninstall left the extension installed"
pass "package, explicit install, drift refusal, and exact uninstall"

printf 'all captain-surface tests passed\n'
