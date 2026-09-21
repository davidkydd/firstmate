# Microsoft Teams integration

This integration provides a production-shaped single-tenant Teams bot and an outbound-only Mac connector.
It is disabled by default and this repository does not create an app registration, issue a certificate, provision Azure resources, publish a Teams package, or send a Teams message by itself.
The rollout steps in this document require separate approval before they are run.

## Supported experience

In a personal bot chat, send `/firstmate <request>`.
In a group chat or channel, mention the bot first and send `@Firstmate /firstmate <request>`.
The group and channel forms are accepted only when the Teams activity contains a structured mention of the configured bot.

The integration permits counts-only status and an explicit allowlist of read-only work-summary requests that can be handed to the trusted local Firstmate session.
It never treats authentication as approval for a privileged action.
It refuses every unknown or effectful request, including merge or release approval, destructive or irreversible operations, security-sensitive changes, credentials or MFA, consent, role or tenant changes, network changes, infrastructure creation, and discarding local work.
Those requests must be confirmed in the trusted local Firstmate session.

Attachments, cards, submitted values, unsupported entities, unsupported markup, oversized bodies, messages from another tenant or sender, and messages outside the configured replay window are rejected before queueing.
The bot's own sender identity is ignored.
The message body is data and is never used as a shell command, process argument, terminal key sequence, or direct fleet-state mutation.

## Architecture and trust boundaries

The complete component, protocol, durability, idempotence, authority, and reply-correlation design is owned by [`teams-architecture.md`](teams-architecture.md).
The cloud endpoint is public because Azure Bot Service must call it, while the Mac opens only outbound Azure Service Bus connections.

## Local connector configuration

Install the pinned runtime dependencies without running package lifecycle scripts.

```sh
(cd integrations/teams && npm ci --omit=dev --ignore-scripts)
```

Copy the example into the Firstmate home, replace every placeholder with an approved value, change `enabled` to `true`, and make the file owner-only.

```sh
install -m 0600 integrations/teams/config.example.json "$FM_HOME/config/teams.json"
```

The local schema is `firstmate.teams.config.v1`.
`tenantId` is the one approved Entra tenant.
`allowedSenderObjectIds` must contain at least one immutable Entra object ID.
`allowedConversationIds` must contain every personal chat, group chat, or channel conversation ID approved to send requests and receive replies.
`serviceBusNamespace` is the namespace name without the DNS suffix.
`requestQueue` and `resultQueue` must name the provisioned queues.
`credential` is deliberately limited to `azure-cli` in this increment.
`retentionDays` controls automatic removal of queued local correlation records, including accepted work without a later completion, and must be from 3 through 365.
`messageRetentionDays` controls request dead-letter removal, must be from 1 through 14, and must match the deployed queue retention.
`retentionDays` must exceed `messageRetentionDays` by more than one day.
Each cloud-created request carries a result-publication deadline that reserves the full deployed result-queue lifetime and a one-day delivery margin before its correlation row expires, so the connector refuses results that can no longer arrive safely.

Authenticate Azure CLI to the exact configured tenant with the approved Mac user or service principal before starting the connector.
The selected principal must hold only Azure Service Bus Data Receiver on the request queue path and Azure Service Bus Data Sender on the result queue path.
Azure RBAC remains authoritative if local configuration points at the wrong account.
The connector does not enable interactive authentication, password fallback, connection strings, SAS keys, browser-cookie reuse, or token extraction.

Inspect the effective non-secret connection metadata without contacting Azure.

```sh
FM_HOME=/path/to/firstmate-home bin/fm-teams-connector.sh status
```

Start the outbound consumer under the approved workstation service manager.

```sh
FM_HOME=/path/to/firstmate-home bin/fm-teams-connector.sh serve
```

Publish a bounded typed result only for a request already captured by this home.
The text enters on stdin or through a named file and never appears in process arguments.

```sh
printf '%s\n' 'The requested report is ready.' | \
  FM_HOME=/path/to/firstmate-home bin/fm-teams-connector.sh publish-result \
    --request-id tm_RECORDED_ID \
    --outcome completed \
    --text-file -
```

Local request and result records live under `state/teams/` with owner-only permissions.
They intentionally retain the request body and correlation identity until the approved retention job removes them.
Do not include secrets, customer data, raw logs, environment values, terminal scrollback, private keys, tokens, or unrestricted file contents in a Teams result.
The Mac publisher withholds a result before Service Bus when its bounded secret detector finds common credential material, and the cloud service repeats the check before posting.

## Cloud configuration

The cloud process starts only when `FM_TEAMS_ENABLED=1` and every required value is present.
It uses a user-assigned managed identity for Service Bus, Table Storage, Key Vault, and image pulls from one approved existing Azure Container Registry.
The deployment constructs the image reference from that registry, a repository path, and an immutable SHA-256 digest; arbitrary registries and mutable tags are not accepted.
It accepts no storage keys, Service Bus connection strings, registry credentials, bot client secrets, or certificate bytes through application settings.

| Setting | Purpose |
| --- | --- |
| `FM_TEAMS_TENANT_ID` | Approved single tenant. |
| `FM_TEAMS_BOT_APP_ID` | Existing approved bot application ID used for authentication. |
| `FM_TEAMS_BOT_RECIPIENT_ID` | Exact Bot Framework recipient ID accepted in Teams activities. |
| `FM_TEAMS_ALLOWED_SENDER_IDS` | Comma-separated Entra object ID allowlist. |
| `FM_TEAMS_ALLOWED_CONVERSATION_IDS` | Comma-separated approved Teams conversation ID allowlist. |
| `FM_TEAMS_SERVICE_BUS_NAMESPACE` | Namespace name without the DNS suffix. |
| `FM_TEAMS_REQUEST_QUEUE` | Request queue name. |
| `FM_TEAMS_RESULT_QUEUE` | Result queue name. |
| `FM_TEAMS_TABLE_ENDPOINT` | Azure Table service endpoint. |
| `FM_TEAMS_TABLE_NAME` | Durable deduplication table. |
| `FM_TEAMS_KEY_VAULT_URL` | Vault containing the bot certificate secret. |
| `FM_TEAMS_CERTIFICATE_NAME` | Certificate secret name. |
| `FM_TEAMS_MANAGED_IDENTITY_CLIENT_ID` | User-assigned managed identity client ID. |
| `FM_TEAMS_MAX_ACTIVITY_BYTES` | Raw activity text cap, default 8192. |
| `FM_TEAMS_MAX_REQUEST_BYTES` | Normalized request cap, default 4096. |
| `FM_TEAMS_MAX_REPLY_BYTES` | Teams-safe reply cap, default 2500. |
| `FM_TEAMS_MAX_ACTIVITY_AGE_SECONDS` | Accepted Teams delivery age, default 900. |
| `FM_TEAMS_MAX_CLOCK_SKEW_SECONDS` | Future clock tolerance, default 300. |
| `FM_TEAMS_RATE_LIMIT_PER_MINUTE` | Per-tenant and sender intake limit, default 10. |
| `FM_TEAMS_AUTH_RATE_LIMIT_PER_MINUTE` | Global authenticated Bot Framework delivery limit, default 120; at most 16 authentication requests may be in flight. |
| `FM_TEAMS_RETENTION_DAYS` | Azure Table correlation retention, including abandoned requests, default 30 and valid from 3 through 365; it must exceed the message retention by more than one day. |
| `FM_TEAMS_MESSAGE_RETENTION_DAYS` | Active and dead-letter queue delivery window, default 7 and valid from 1 through 14; this full window plus a one-day delivery margin is reserved after the last permitted local result publication. |

The deployment enables the Agents SDK outbound host validator with the SDK's Microsoft host allowlist.
[`teams-architecture.md`](teams-architecture.md) owns the inbound token and service-origin checks.
A pre-authentication concurrency bound limits simultaneous JWT verification and signing-key lookups without letting unauthenticated traffic consume the authenticated delivery quota.
The authenticated global limit applies only after JWT validation, before the per-sender intake limit.
The container is fixed at one replica because the in-process rate windows are abuse bounds rather than the durable deduplication authority.
Azure Table Storage and Service Bus remain the restart-safe authorities.

## Formal Torus rollout

Do not run this section until the approvers name all of the following concrete values.

- Tenant ID, Bot Framework recipient ID, allowed sender object IDs, and allowed conversation IDs.
- First-party app and Teams app names.
- Torus subscription, resource group, and Azure region.
- Azure Service Bus as the approved durable queue choice.
- Certificate owner, issuing policy, Key Vault, subject name, issuer, rotation interval, and incident contact.
- Bot and Graph or resource-specific scopes.
- Request, result, audit, dead-letter, and Teams-message retention periods.
- Service owner, privacy owner, security owner, on-call rotation, cost center, and rollback owner.

The rollout must follow the first-party Teams and Torus registration process.
Do not let Teams Toolkit create a client secret.
Create a single-tenant application and configure Subject Name + Issuer authentication for an approved certificate chain.
The Key Vault certificate secret must use PEM content containing one private key and its certificate chain.
The cloud service retrieves the latest secret version with managed identity, writes it only to owner-only ephemeral container files, and configures `CertificateSubjectName` authentication with `sendX5C=true`.

Use overlap rotation.
Add and validate the new Subject Name + Issuer trust before issuing the new certificate, create a new cloud revision that reads the latest Key Vault version, verify authenticated Bot Framework traffic, move traffic to the new revision, and only then retire the old certificate and trust entry.
Never replace the only trusted certificate in place.

The Bicep template defaults `enableCloudService` to `false`.
A reviewed deployment may first create the queue, table, vault, managed identity, monitoring, and role assignments while leaving the bot endpoint absent.
After app registration, certificate issuance, immutable image publication, and approval are complete, deploy with `enableCloudService=true`.
Set `containerRegistryName`, `containerImageRepository`, and the 64-character `containerImageDigest`; the approved existing ACR must be in the deployment resource group and use the `rbac-abac` role-assignment mode.
The template grants its user-assigned workload identity only `Container Registry Repository Reader`, with an ABAC condition restricted to `containerImageRepository`, and configures the Container App to use that identity.
The template creates the Azure Bot resource and Teams channel but does not publish or install the Teams app package.

Build the image from the repository root so the Dockerfile can retain a narrow copy set.
Pin the approved image by digest in the deployment parameters.

```sh
docker build -f integrations/teams/Dockerfile -t APPROVED_REGISTRY/firstmate-teams:VERSION .
az bicep build --file integrations/teams/infra/main.bicep
az deployment group what-if \
  --resource-group APPROVED_RESOURCE_GROUP \
  --parameters integrations/teams/infra/main.bicepparam \
  --parameters enableCloudService=false
```

The example parameter file is intentionally non-deployable until every placeholder is replaced.
A real `main.bicepparam` must remain outside version control if it contains organization-specific identifiers.
The deployment itself is not authorized by this implementation increment.

## Teams package preparation

The committed manifest enables personal, group chat, and team bot scopes and disables file support, calling, and video.
Its zero GUIDs and `.invalid` owner URLs are safe placeholders rather than an app registration.
Before packaging, replace both manifest GUIDs with the approved IDs, replace every developer URL with the approved service-owned page, review the permissions, and validate the package with the current Teams developer tooling.
Do not add broad Graph read permissions merely to observe conversations.
The bot should receive only conversations where it is installed and messages where Teams routes the bot command or mention.

Package `manifest.json`, `color.png`, and `outline.png` at the ZIP root.
Publishing or installing that package remains a separate explicit approval.

## Monitoring and incident response

Alert on request and result dead-letter counts, queue age, active messages, throttled requests, cloud authentication failures, certificate expiry and Key Vault retrieval failures, connector disconnect duration, and ambiguous Teams post records.
The Bicep template wires a dead-letter metric alert when `alertActionGroupId` names the approved on-call action group and otherwise leaves alert delivery explicitly unconfigured.
Do not log activity bodies, result text, authorization headers, access tokens, certificate material, Service Bus payloads, or local Firstmate note content.
Logs may include schema version, deterministic request or result ID, tenant ID, disposition, bounded error class, queue name, and latency.
Restrict access to logs because correlation identifiers and tenant metadata are still operational data.

A malformed or unauthorized queue envelope is dead-lettered immediately.
A transient queue outage abandons the peek-locked message and leaves the request durable for retry.
A connector restart replays the local request record and the deterministic inbox note rather than creating new work.
A result whose Teams post may have succeeded before a crash is dead-lettered as uncertain and requires conversation-level reconciliation.
The cloud worker and Mac connector drain multiple bounded dead-letter batches with bounded settlement concurrency every ten minutes and delete messages older than the configured message-retention window.

## Privacy and retention

Teams retains source and reply messages according to tenant policy.
Azure Table Storage retains the full validated request envelope for durable retry and identity comparison, including request text.
Service Bus retains full active request or result payloads for the approved queue lifetime; the application explicitly settles expired dead-letter messages because Service Bus does not apply queue TTL inside a dead-letter queue.
Treat both stores as sensitive even though the channel contract forbids credentials and secrets.
The Mac retains the accepted text and identity under `state/teams/`.

The cloud service drains the date-bucketed Azure Table retention index in bounded concurrent batches for up to five minutes per hourly sweep to remove correlation rows older than `FM_TEAMS_RETENTION_DAYS`.
The connector removes queued local records and acknowledged Teams inbox notes older than `retentionDays` in independent bounded sweeps every ten minutes; acknowledged external notes are partitioned by source and UTC handling date so cleanup never traverses the retained note population.
Both policies expire accepted work that never receives a terminal result.
The cloud service and connector also delete bounded batches of dead-letter messages older than `messageRetentionDays`.
The Bicep `messageRetentionDays`, `resultPublicationDays`, and `diagnosticRetentionDays` parameters make the queue, local publication, and log windows explicit; the deployment derives cloud correlation retention by adding the full queue lifetime and a one-day delivery margin to the publication window.
Set all three to no longer than the approved business need.
Deletion must preserve enough identity evidence to avoid replay during the Teams retry and queue retention windows.
Privacy and service owners must approve what work summaries may enter Teams before rollout.

## Rollback

Stop intake first by disabling or removing the Teams app for its assigned users, without changing the Mac.
Stop the Mac connector and verify that no request lock remains in flight.
Drain or retain the request and result queues according to the incident decision, without deleting messages merely to make metrics green.
Route cloud traffic back to the last known-good immutable container revision if the problem is code-only.
Disable the Azure Bot Teams channel if authenticated ingress must stop immediately.
Keep the table, queues, dead-letter queues, logs, and local correlation records until the rollback owner completes reconciliation.
Revoke the bot certificate and role assignments only after evidence preservation and service-owner approval.
No rollback step discards Firstmate work, changes the local Firstmate session, or opens an inbound path to the Mac.

## Verification

Run the integration behavior suite and the repository documentation and lint checks.

```sh
bin/fm-test-run.sh tests/fm-teams-integration.test.sh
bin/fm-doc-audience-check.sh
bin/fm-lint.sh
az bicep build --file integrations/teams/infra/main.bicep
cd integrations/teams && npm audit --omit=dev
```

The fixture suite covers tenant and sender binding, mention parsing, duplicate and reordered delivery, restart replay, queue outage recovery, throttling, malformed envelopes, self-reply suppression, allowlisted read-only request delivery, deny-by-default authority refusal, secret withholding, and exact `replyToId` correlation.
No test provisions Azure resources, registers an app, obtains consent, issues a certificate, publishes a Teams package, or sends a Teams message.
