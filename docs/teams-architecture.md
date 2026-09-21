# Microsoft Teams integration architecture

This document owns the maintainer architecture for the optional single-tenant Teams integration.
The operator and rollout contract is in [`teams-integration.md`](teams-integration.md).

## Components and trust boundaries

The cloud service under `integrations/teams/src/` uses the Microsoft 365 Agents SDK over the supported Bot Framework activity protocol.
Before application processing, the authentication path applies the token and channel-origin checks in the inbound state machine below.
The ingress then binds the configured tenant, Entra sender object ID, Bot Framework sender ID, conversation ID and type, activity ID and timestamp, service URL, and bot ID into an immutable request envelope.
[`integrations/teams/protocol/request.schema.json`](../integrations/teams/protocol/request.schema.json) and [`integrations/teams/protocol/result.schema.json`](../integrations/teams/protocol/result.schema.json) are the wire-format owners.

The cloud service writes a request identity record and an exclusive enqueue claim to Azure Table Storage before sending the request to Azure Service Bus and before acknowledging it in Teams.
The request queue uses its deterministic request ID as the Service Bus message ID and enables duplicate detection.
The table record remains the long-lived duplicate and identity binding after the queue duplicate-detection window passes.
A send interrupted between queue acceptance and the table update is retried with the same message ID after its bounded claim expires.
A separate acknowledgement claim prevents concurrent receipts; a definite posting failure releases that claim for retry, while an interrupted posting remains in its durable claim state for operator reconciliation to avoid an uncertain duplicate.

The connector on the Mac opens only outbound TLS connections to Azure Service Bus.
It validates the envelope and the tenant, sender, and conversation allowlists again and stores an owner-only local capture.
For a general request it first invokes `bin/fm-inbox.sh external-note teams-review <request-id> -` with a fixed notification that contains no request text.
Only the explicit local `approve-request` command, supplied with text that exactly matches the capture, records approval and invokes `bin/fm-inbox.sh external-note teams <request-id> -` with the request text.
`fm-inbox.sh` is the only owner that writes either Firstmate inbox note and notification.
Their deterministic external note IDs make replay after a connector crash idempotent.

Counts-only status is rendered locally by `bin/fm_voice_records.py status --scope counts` and never reads task note bodies or completed history.
A general request that does not match a known privileged category receives a typed `accepted` result and creates an `external-teams-review-` note whose fixed body asks for trusted-local approval without exposing the request text to the agent.
After exact local approval, a separate `external-teams-` note whose `source=teams` header preserves its untrusted provenance carries the request into normal intake.
Later completion, refusal, or failure summaries are emitted with `bin/fm-teams-connector.sh publish-result`, which obtains the reply destination only from an approved original local request record.

The result queue carries the original immutable source identity.
The cloud service compares that identity with the stored request before posting a reply with `replyToId` set to the original Teams activity ID.
A deterministic result ID suppresses duplicate queue delivery.
The cloud service records a posting claim before calling Teams, so an ambiguous crash after the external post is quarantined in the dead-letter queue instead of risking a duplicate reply.
An operator must reconcile that rare uncertain result against the Teams conversation before replaying it.

The cloud endpoint is public because Azure Bot Service must call it.
There is no public or inbound route from the cloud service to the Mac.
The Container App pulls only a digest-pinned image from the configured repository in an ABAC-enabled existing Azure Container Registry through its user-assigned identity and a repository-conditioned `Container Registry Repository Reader` assignment.
The Azure templates do not create a tunnel, listener, NAT rule, SSH service, or browser-token path.

## Inbound state machine

1. The Agents SDK verifies the Bot Framework token, issuer, and audience; route middleware then requires the Teams channel and an exact HTTPS-origin match between the activity service URL and the token's `serviceurl` claim.
2. The ingress accepts only a Teams message activity from the configured tenant, an allowed Entra sender object ID, and an approved conversation ID.
3. The parser ignores bot-authored messages, requires an explicit bot mention outside personal scope, and removes only the structured mention bound to the configured bot ID.
4. The parser rejects attachments, cards, submitted values, unsupported entities, unsupported markup, malformed timestamps, and oversized content.
5. The cloud store creates a `pending` identity row with an exclusive enqueue claim before the queue send.
6. Service Bus stores the typed request with its deterministic request ID as `MessageId`.
7. The cloud row advances to `enqueued`; an exclusive acknowledgement claim then owns the bounded reply to the source activity.
8. A repeated activity with the same identity and body either repairs a definitely failed acknowledgement or converges on the existing row, while identity reuse with different content is rejected.
9. A rejected asynchronous acknowledgement receipt advances to `ack-uncertain` for operator reconciliation rather than remaining indistinguishable from an active acknowledgement attempt.

## Local delivery state machine

1. The connector receives through Service Bus peek-lock and validates the complete request envelope.
2. The connector rechecks the configured tenant, sender, and conversation allowlists.
3. The connector atomically captures the request under `state/teams/requests/` before any Firstmate handoff.
4. A status request runs the counts-only reader and creates a typed status result.
5. A request that matches a known privileged category creates a typed refusal and never reaches the Firstmate inbox.
6. Every other general request creates a deterministic review note containing only safe fixed text and its request ID; the connector records the note and pending approval state before sending a typed accepted result.
7. The local captain reviews the original Teams message and repeats its exact request in the trusted local session; `approve-request` rejects any text mismatch and records the approval transition.
8. The approval command sends the matched request through stdin to a second deterministic `source=teams` note, then marks approval complete.
9. Task binding and terminal result publication reject a work request until that approval is complete.
10. Only after the result queue accepts the deterministic accepted result does the connector complete the request message.

A queue outage before local delivery leaves the Service Bus message locked or available for redelivery.
A queue outage after local delivery replays the deterministic review note and cannot create a second approval request.
A process interruption during approval replays the deterministic approved note and cannot create a second Firstmate request.
A process interruption after result queue acceptance reuses the same Service Bus message ID, so queue duplicate detection converges.

## Result state machine

1. The local publisher resolves the source only from a captured request record.
2. The result envelope repeats the immutable source identity and derives its result ID from the request ID and outcome.
3. The cloud worker verifies the schema, matches the full source against the request table row, and rechecks the sender and conversation allowlists before posting.
4. The worker conditionally reserves the request's result state and creates a durable `posting` result row before the external Teams call; terminal reservations reject late accepted or conflicting terminal results.
5. The worker posts a bounded, redacted message with `replyToId` equal to the source activity ID.
6. A successful receipt changes the row to `posted` and records the Teams reply activity ID.
7. A duplicate result with `posted` state completes without another post.
8. A duplicate result with `posting` state is dead-lettered because the previous external outcome is uncertain.

This state machine chooses at-most-once Teams posting over a possible duplicate when the Bot Framework call succeeded but its receipt was lost.
The dead-letter queue and original correlation record preserve the evidence needed for manual reconciliation.

## Authority and data boundaries

The deterministic authority classifier is independent of authentication and applies again on the Mac.
Status has a dedicated counts-only path, known privileged requests are refused, and other general requests initially create only a payload-free local approval notification.
The request text reaches the mutation-capable Firstmate intake only after the local approval command verifies text repeated in the trusted local session against the captured request.
Authentication and delivery never grant action authority, and source allowlists do not bypass this approval state.

Message text enters `fm-inbox.sh` on stdin.
It never enters a shell command line, a generated script, a process lifecycle operation, or a terminal input path.
Queue and local filenames use only deterministic hashes of the immutable Teams identity.

The cloud request table and its date-bucketed retention index, Service Bus queues, Teams conversation, and locked local request record all retain message content according to their separately approved retention periods.
Bounded dead-letter consumers explicitly settle expired messages, and stale accepted correlation records expire after the configured replay window.
Application logs deliberately exclude request and result bodies.
The Mac result publisher withholds the entire result before Service Bus when it detects common credential material instead of attempting partial redaction.
The cloud worker repeats the filter as defense in depth before posting to Teams.

## Repository ownership

- `integrations/teams/src/contracts.mjs` owns runtime envelope validation and deterministic IDs.
- `integrations/teams/src/activity.mjs` owns Teams activity and mention normalization.
- `integrations/teams/src/policy.mjs` owns the deterministic mobile authority ceiling and outbound secret filter.
- `integrations/teams/src/cloud-store.mjs` owns cloud deduplication and reply claims.
- `integrations/teams/src/local-store.mjs` owns private Mac correlation records.
- `integrations/teams/src/connector-core.mjs` owns the local delivery sequence.
- `integrations/teams/src/result-worker.mjs` owns exact reply correlation.
- `bin/fm-inbox.sh` owns durable Firstmate inbox mutation and notification.
- `integrations/teams/infra/main.bicep` owns the deployable Azure resource shape and RBAC assignments.
- [`teams-integration.md`](teams-integration.md) owns operator configuration, rollout, monitoring, privacy, retention, and rollback.
