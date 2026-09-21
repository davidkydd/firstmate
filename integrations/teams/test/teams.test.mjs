import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, readdir, rename, rm, stat, utimes, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

import { parseTeamsActivity, IgnoredActivity } from "../src/activity.mjs";
import { materializeBotCertificate } from "../src/certificate.mjs";
import { isChannelServiceActivity } from "../src/channel-auth.mjs";
import { cloudConfig, connectorConfig } from "../src/config.mjs";
import { ConnectorCore } from "../src/connector-core.mjs";
import { ContractError, makeResult, validateRequest, validateResult } from "../src/contracts.mjs";
import { AzureTableRequestStore, MemoryRequestStore } from "../src/cloud-store.mjs";
import {
  deliveryFailureReply,
  reconcilePendingEnqueues,
  shouldSendFailureReply,
  SlidingWindowRateLimiter,
  TeamsIngress,
} from "../src/ingress.mjs";
import { FirstmateInboxAdapter } from "../src/local-adapters.mjs";
import { LocalRequestStore } from "../src/local-store.mjs";
import { classifyAuthority, redactReply } from "../src/policy.mjs";
import { parsePublishArgs } from "../src/publish-args.mjs";
import { TeamsResultWorker } from "../src/result-worker.mjs";
import { closeResources, processPeekLockMessage, purgeDeadLetters } from "../src/service-bus.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const FIXTURES = path.join(ROOT, "tests/fixtures/teams");
const NOW = new Date("2026-09-21T05:00:10.000Z");
const TENANT = "aaaaaaaa-2222-4222-8222-222222222222";
const SENDER = "bbbbbbbb-1111-4111-8111-111111111111";
const BOT = "28:bot-channel-id";
const execFileAsync = promisify(execFile);

const config = {
  tenantId: TENANT,
  botId: BOT,
  allowedSenderObjectIds: new Set([SENDER]),
  allowedConversationIds: new Set(["a:personal-conversation", "19:group-conversation@thread.v2"]),
  maxActivityBytes: 8192,
  maxRequestBytes: 4096,
  maxActivityAgeSeconds: 900,
  maxClockSkewSeconds: 300,
};

async function fixture(name) {
  return JSON.parse(await readFile(path.join(FIXTURES, name), "utf8"));
}

function context(activity, events = []) {
  return {
    activity,
    async sendActivity(reply) {
      events.push({ kind: "reply", reply });
      return { id: `reply-${events.length}` };
    },
  };
}

class ArraySender {
  constructor(events = [], failures = 0) {
    this.events = events;
    this.failures = failures;
    this.sent = [];
  }

  async send(value) {
    this.events.push({ kind: "queue", requestId: value.requestId, resultId: value.resultId });
    if (this.failures > 0) {
      this.failures -= 1;
      throw new Error("queue unavailable");
    }
    this.sent.push(value);
  }
}

class MemoryLocalStore {
  constructor(records = new Map(), results = new Map()) {
    this.records = records;
    this.results = results;
  }

  async capture(request) {
    const current = this.records.get(request.requestId);
    if (current) return { created: false, record: current };
    const record = { request, state: "received" };
    this.records.set(request.requestId, record);
    return { created: true, record };
  }

  async update(requestId, fields) {
    const record = { ...this.records.get(requestId), ...fields };
    this.records.set(requestId, record);
    return record;
  }

  async queueResult(result, send) {
    const record = this.records.get(result.requestId);
    if (record.terminalResultId && record.terminalResultId !== result.resultId) {
      throw new Error("the Teams request already has a conflicting terminal result");
    }
    const existing = this.results.get(result.resultId);
    if (existing) {
      this.records.set(result.requestId, {
        ...record,
        state: "result-queued",
        outcome: existing.outcome,
        ...(existing.terminal ? { terminalResultId: existing.resultId } : {}),
      });
      return { queued: false, result: existing };
    }
    if (result.terminal) {
      this.records.set(result.requestId, {
        ...record,
        state: "result-publishing",
        outcome: result.outcome,
        terminalResultId: result.resultId,
      });
    }
    await send(result);
    this.results.set(result.resultId, result);
    this.records.set(result.requestId, {
      ...this.records.get(result.requestId),
      state: "result-queued",
      outcome: result.outcome,
    });
    return { queued: true, result };
  }
}

test("fixture identities and command forms are bound and normalized", async () => {
  const personal = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  assert.equal(personal.command.text, "summarize the open work");
  assert.equal(personal.command.kind, "work");
  assert.equal(personal.source.tenantId, TENANT);
  assert.equal(personal.source.senderAadObjectId, SENDER);
  assert.equal(personal.source.conversationType, "personal");

  const group = parseTeamsActivity(await fixture("group-request.json"), config, NOW);
  assert.equal(group.command.text, "status");
  assert.equal(group.command.kind, "status");
  assert.equal(group.source.activityId, "activity-group-001");
  assert.match(group.requestId, /^tm_[a-f0-9]{64}$/);

  const uppercaseIdentity = await fixture("personal-request.json");
  uppercaseIdentity.conversation.tenantId = TENANT.toUpperCase();
  uppercaseIdentity.channelData.tenant.id = TENANT.toUpperCase();
  uppercaseIdentity.from.aadObjectId = SENDER.toUpperCase();
  const normalized = parseTeamsActivity(uppercaseIdentity, config, NOW);
  assert.equal(normalized.source.tenantId, TENANT);
  assert.equal(normalized.source.senderAadObjectId, SENDER);
});

test("channel authentication binds Teams activities to the token service origin", async () => {
  const activity = await fixture("personal-request.json");
  assert.equal(isChannelServiceActivity({ serviceurl: activity.serviceUrl }, activity), true);
  assert.equal(isChannelServiceActivity({}, activity), false);
  assert.equal(isChannelServiceActivity({ serviceurl: "https://attacker.example/" }, activity), false);
  assert.equal(isChannelServiceActivity({ serviceurl: activity.serviceUrl }, { ...activity, channelId: "webchat" }), false);
  assert.equal(isChannelServiceActivity(
    { serviceurl: "https://smba.trafficmanager.net:444/amer/" },
    activity,
  ), false);
});

test("group messages require this bot's structured leading mention", async () => {
  const missing = await fixture("group-request.json");
  missing.entities = [];
  missing.text = "/firstmate status";
  assert.throws(() => parseTeamsActivity(missing, config, NOW), IgnoredActivity);

  const wrong = await fixture("group-request.json");
  wrong.entities[0].mentioned.id = "28:some-other-bot";
  assert.throws(() => parseTeamsActivity(wrong, config, NOW), /only one mention of this bot/);

  const trailing = await fixture("group-request.json");
  trailing.text = "/firstmate status <at>Firstmate</at>";
  assert.throws(() => parseTeamsActivity(trailing, config, NOW), /first message element/);
});

test("identity mismatches, rich payloads, oversized text, and bot replies are refused or ignored", async () => {
  const otherTenant = await fixture("personal-request.json");
  otherTenant.conversation.tenantId = "33333333-3333-3333-3333-333333333333";
  otherTenant.channelData.tenant.id = otherTenant.conversation.tenantId;
  assert.throws(() => parseTeamsActivity(otherTenant, config, NOW), (error) => error.code === "identity");

  const otherSender = await fixture("personal-request.json");
  otherSender.from.aadObjectId = "44444444-4444-4444-4444-444444444444";
  assert.throws(() => parseTeamsActivity(otherSender, config, NOW), (error) => error.code === "identity");

  const otherConversation = await fixture("personal-request.json");
  otherConversation.conversation.id = "a:unapproved-conversation";
  assert.throws(() => parseTeamsActivity(otherConversation, config, NOW), (error) => error.code === "identity");

  const attachment = await fixture("personal-request.json");
  attachment.attachments = [{ contentType: "application/vnd.microsoft.card.adaptive", content: {} }];
  assert.throws(() => parseTeamsActivity(attachment, config, NOW), (error) => error.code === "rich-content");

  const markup = await fixture("personal-request.json");
  markup.text = "/firstmate <b>run this</b>";
  assert.throws(() => parseTeamsActivity(markup, config, NOW), (error) => error.code === "rich-content");

  const large = await fixture("personal-request.json");
  large.text = `/firstmate ${"x".repeat(9000)}`;
  assert.throws(() => parseTeamsActivity(large, config, NOW), (error) => error.code === "too-large");

  const self = await fixture("personal-request.json");
  self.from.id = BOT;
  assert.throws(() => parseTeamsActivity(self, config, NOW), IgnoredActivity);
});

test("unauthorized rich-content activity is refused silently", async () => {
  const activity = await fixture("personal-request.json");
  activity.from.aadObjectId = "44444444-4444-4444-4444-444444444444";
  activity.attachments = [{ contentType: "application/vnd.microsoft.card.adaptive", content: {} }];
  const replies = [];
  const ingress = new TeamsIngress({
    config,
    store: new MemoryRequestStore(),
    requestSender: new ArraySender(),
    rateLimiter: new SlidingWindowRateLimiter({ limit: 1 }),
  });
  assert.deepEqual(await ingress.handle(context(activity, replies), NOW), {
    disposition: "refused",
    reason: "identity",
  });
  assert.equal(replies.length, 0);
});

test("authorized malformed traffic is rate limited before refusal replies", async () => {
  const activity = await fixture("personal-request.json");
  activity.conversation.tenantId = TENANT.toUpperCase();
  activity.channelData.tenant.id = TENANT.toUpperCase();
  activity.from.aadObjectId = SENDER.toUpperCase();
  activity.attachments = [{ contentType: "application/vnd.microsoft.card.adaptive", content: {} }];
  const replies = [];
  const ingress = new TeamsIngress({
    config,
    store: new MemoryRequestStore(),
    requestSender: new ArraySender(),
    rateLimiter: new SlidingWindowRateLimiter({ limit: 1, duplicateLimit: 1 }),
  });
  assert.equal((await ingress.handle(context(activity, replies), NOW)).disposition, "refused");
  assert.equal((await ingress.handle(context(activity, replies), NOW)).disposition, "refused");
  assert.equal((await ingress.handle(context(activity, replies), NOW)).disposition, "throttled");
  assert.equal(replies.length, 3);
  assert.match(replies[2].reply.text, /rate limit/);
});

test("ingress stores before queueing and acknowledges only after durable queue acceptance", async () => {
  const events = [];
  const base = new MemoryRequestStore();
  const store = {
    async claimRequest(request) {
      events.push({ kind: "store" });
      return base.claimRequest(request);
    },
    async markRequestEnqueued(...args) { return base.markRequestEnqueued(...args); },
    async markRequestQueueError(...args) { return base.markRequestQueueError(...args); },
    async claimRequestAcknowledgement(...args) { return base.claimRequestAcknowledgement(...args); },
    async markRequestAcknowledged(...args) { return base.markRequestAcknowledged(...args); },
    async markRequestAcknowledgementError(...args) { return base.markRequestAcknowledgementError(...args); },
  };
  const sender = new ArraySender(events);
  const ingress = new TeamsIngress({
    config,
    store,
    requestSender: sender,
    rateLimiter: new SlidingWindowRateLimiter({ limit: 10 }),
  });
  const outcome = await ingress.handle(context(await fixture("personal-request.json"), events), NOW);
  assert.equal(outcome.disposition, "enqueued");
  assert.deepEqual(events.map((entry) => entry.kind), ["store", "queue", "reply"]);
  assert.equal(events[2].reply.replyToId, "activity-personal-001");
});

test("duplicate, reordered, and restart delivery enqueue each immutable activity once", async () => {
  const records = new Map();
  const store = new MemoryRequestStore(records);
  const sender = new ArraySender();
  const buildIngress = () => new TeamsIngress({
    config,
    store: new MemoryRequestStore(records),
    requestSender: sender,
    rateLimiter: new SlidingWindowRateLimiter({ limit: 20 }),
  });
  const later = await fixture("group-request.json");
  const earlier = await fixture("personal-request.json");
  await buildIngress().handle(context(later), NOW);
  await buildIngress().handle(context(earlier), NOW);
  const duplicate = await buildIngress().handle(context(earlier), NOW);
  assert.equal(duplicate.disposition, "duplicate");
  assert.deepEqual(sender.sent.map((entry) => entry.source.activityId), ["activity-group-001", "activity-personal-001"]);
});

test("retry enqueue publishes the canonical stored request", async () => {
  const records = new Map();
  const store = new MemoryRequestStore(records);
  const activity = await fixture("personal-request.json");
  const storedRequest = parseTeamsActivity(activity, config, NOW);
  await store.claimRequest(storedRequest);
  const record = records.get(storedRequest.requestId);
  record.enqueueStatus = "queue-error";
  record.enqueueClaimToken = "";
  record.enqueueNextAttemptAt = new Date(0).toISOString();

  const sender = new ArraySender();
  const ingress = new TeamsIngress({
    config,
    store,
    requestSender: sender,
    rateLimiter: new SlidingWindowRateLimiter({ limit: 10 }),
  });
  const retryNow = new Date(NOW.getTime() + 60_000);
  const outcome = await ingress.handle(context(activity), retryNow);

  assert.equal(outcome.disposition, "enqueued");
  assert.equal(sender.sent.length, 1);
  assert.deepEqual(sender.sent[0], storedRequest);
  assert.notEqual(sender.sent[0].receivedAt, retryNow.toISOString());
});

test("concurrent ingress delivery has one queue and acknowledgement owner", async () => {
  const store = new MemoryRequestStore();
  const sender = new ArraySender();
  const activity = await fixture("personal-request.json");
  const replies = [];
  const makeIngress = () => new TeamsIngress({
    config,
    store,
    requestSender: sender,
    rateLimiter: new SlidingWindowRateLimiter({ limit: 10 }),
  });
  const outcomes = await Promise.all([
    makeIngress().handle(context(activity, replies), NOW),
    makeIngress().handle(context(activity, replies), NOW),
  ]);
  assert.equal(sender.sent.length, 1);
  assert.equal(replies.filter((entry) => entry.kind === "reply").length, 1);
  assert.deepEqual(outcomes.map((value) => value.disposition).sort(), ["duplicate", "enqueued"]);
});

test("an overlapping delivery is retried if the enqueue owner has not committed", async () => {
  const store = new MemoryRequestStore();
  const activity = await fixture("personal-request.json");
  let releaseSend;
  let sendStarted;
  const started = new Promise((resolve) => { sendStarted = resolve; });
  const sender = {
    async send() {
      sendStarted();
      await new Promise((resolve, reject) => { releaseSend = { resolve, reject }; });
    },
  };
  const ingress = new TeamsIngress({
    config,
    store,
    requestSender: sender,
    rateLimiter: new SlidingWindowRateLimiter({ limit: 10 }),
  });
  const owner = ingress.handle(context(activity), NOW);
  await started;
  await assert.rejects(ingress.handle(context(activity), NOW), /not yet durably queued/);
  releaseSend.reject(new Error("owner stopped"));
  await assert.rejects(owner, /owner stopped/);
});

test("a definite pre-send acknowledgement failure is retried without requeueing", async () => {
  const store = new MemoryRequestStore();
  const sender = new ArraySender();
  const activity = await fixture("personal-request.json");
  const ingress = new TeamsIngress({
    config,
    store,
    requestSender: sender,
    rateLimiter: new SlidingWindowRateLimiter({ limit: 10 }),
  });
  await assert.rejects(ingress.handle({
    activity,
    sendActivity() { throw new Error("reply unavailable"); },
  }, NOW), (error) => {
    assert.equal(shouldSendFailureReply(error), true);
    return /reply unavailable/.test(error.message);
  });
  const retried = await ingress.handle(context(activity), NOW);
  assert.equal(retried.disposition, "acknowledged");
  assert.equal(sender.sent.length, 1);
});

test("an ambiguous acknowledgement rejection requires explicit reconciliation", async () => {
  const store = new MemoryRequestStore();
  const sender = new ArraySender();
  const activity = await fixture("personal-request.json");
  let attempts = 0;
  const ingress = new TeamsIngress({
    config,
    store,
    requestSender: sender,
    rateLimiter: new SlidingWindowRateLimiter({ limit: 10 }),
  });
  await assert.rejects(ingress.handle({
    activity,
    async sendActivity() {
      attempts += 1;
      throw new Error("reply receipt unavailable");
    },
  }, NOW), (error) => {
    assert.equal(shouldSendFailureReply(error), false);
    return /reply receipt unavailable/.test(error.message);
  });
  const retried = await ingress.handle(context(activity), NOW);
  assert.equal(retried.disposition, "acknowledgement-uncertain");
  assert.equal(attempts, 1);
  assert.equal(sender.sent.length, 1);
  const request = parseTeamsActivity(activity, config, NOW);
  const record = await store.requestById(request.requestId);
  assert.equal(record.acknowledgementStatus, "ack-uncertain");
  assert.match(record.acknowledgementError, /reply receipt unavailable/);
  assert.ok(record.acknowledgementReconciliationAt);
});

test("a post-send acknowledgement persistence failure does not send an error reply", async () => {
  const base = new MemoryRequestStore();
  const store = {
    async claimRequest(...args) { return base.claimRequest(...args); },
    async requestById(...args) { return base.requestById(...args); },
    async markRequestEnqueued(...args) { return base.markRequestEnqueued(...args); },
    async markRequestQueueError(...args) { return base.markRequestQueueError(...args); },
    async claimRequestAcknowledgement(...args) { return base.claimRequestAcknowledgement(...args); },
    async markRequestAcknowledged() { throw new Error("table unavailable after reply"); },
    async markRequestAcknowledgementError(...args) { return base.markRequestAcknowledgementError(...args); },
  };
  const replies = [];
  const ingress = new TeamsIngress({
    config,
    store,
    requestSender: new ArraySender(),
    rateLimiter: new SlidingWindowRateLimiter({ limit: 10 }),
  });
  const outcome = await ingress.handle(context(await fixture("personal-request.json"), replies), NOW);
  assert.equal(outcome.disposition, "acknowledgement-uncertain");
  assert.equal(replies.length, 1);
});

test("queue outage is retried from durable state without another inbound delivery", async () => {
  const records = new Map();
  const store = new MemoryRequestStore(records);
  const failing = new ArraySender([], 1);
  const activity = await fixture("personal-request.json");
  const first = new TeamsIngress({ config, store, requestSender: failing, rateLimiter: new SlidingWindowRateLimiter({ limit: 10 }) });
  await assert.rejects(first.handle(context(activity), NOW), /queue unavailable/);
  const request = parseTeamsActivity(activity, config, NOW);
  assert.equal(records.get(request.requestId).status, "queue-error");

  const retryAt = Date.parse(records.get(request.requestId).enqueueNextAttemptAt);
  assert.equal(records.get(request.requestId).enqueueRetryCount, 1);
  assert.ok(retryAt > Date.now());
  const recovered = new ArraySender();
  assert.deepEqual(await reconcilePendingEnqueues({
    store,
    requestSender: recovered,
    tenantId: TENANT,
    now: new Date(retryAt - 1),
  }), { claimed: 0, enqueued: 0, failed: 0 });
  assert.deepEqual(await reconcilePendingEnqueues({
    store,
    requestSender: recovered,
    tenantId: TENANT,
    now: new Date(retryAt),
  }), { claimed: 1, enqueued: 1, failed: 0 });
  assert.equal(records.get(request.requestId).status, "enqueued");
  assert.equal(recovered.sent.length, 1);
  assert.deepEqual(await reconcilePendingEnqueues({
    store,
    requestSender: recovered,
    tenantId: TENANT,
  }), { claimed: 0, enqueued: 0, failed: 0 });
});

test("ingress reports queue acceptance separately from retry-safe failures", async () => {
  const activity = await fixture("personal-request.json");
  const base = new MemoryRequestStore();
  const acceptedStore = {
    async claimRequest(...args) { return base.claimRequest(...args); },
    async markRequestEnqueued() { throw new Error("table update unavailable"); },
    async markRequestQueueError(...args) { return base.markRequestQueueError(...args); },
  };
  const acceptedIngress = new TeamsIngress({
    config,
    store: acceptedStore,
    requestSender: new ArraySender(),
    rateLimiter: new SlidingWindowRateLimiter({ limit: 10 }),
  });
  await assert.rejects(
    acceptedIngress.handle(context(activity), NOW),
    (error) => error.queueState === "accepted"
      && /Do not resend/.test(deliveryFailureReply(error)),
  );

  const unqueuedIngress = new TeamsIngress({
    config,
    store: { async claimRequest() { throw new Error("table unavailable"); } },
    requestSender: new ArraySender(),
    rateLimiter: new SlidingWindowRateLimiter({ limit: 10 }),
  });
  await assert.rejects(
    unqueuedIngress.handle(context(activity), NOW),
    (error) => error.queueState === "not-queued"
      && /Retrying the same request is safe/.test(deliveryFailureReply(error)),
  );
  assert.match(deliveryFailureReply({ queueState: "uncertain" }), /Do not resend/);
});

test("duplicate activity retries have a separate bounded allowance", () => {
  const limiter = new SlidingWindowRateLimiter({ limit: 1, duplicateLimit: 2 });
  assert.equal(limiter.take("tenant:sender", "activity-1", NOW.getTime()), true);
  assert.equal(limiter.take("tenant:sender", "activity-1", NOW.getTime()), true);
  assert.equal(limiter.take("tenant:sender", "activity-1", NOW.getTime()), true);
  assert.equal(limiter.take("tenant:sender", "activity-1", NOW.getTime()), false);
  assert.equal(limiter.take("tenant:sender", "activity-2", NOW.getTime()), false);
  assert.equal(limiter.take("tenant:sender", "activity-1", NOW.getTime() + 60_001), true);
});

test("per-sender rate limiting rejects excess activities with one throttle notice", async () => {
  const sender = new ArraySender();
  const ingress = new TeamsIngress({
    config,
    store: new MemoryRequestStore(),
    requestSender: sender,
    rateLimiter: new SlidingWindowRateLimiter({ limit: 1 }),
  });
  const replies = [];
  const first = await fixture("personal-request.json");
  const second = await fixture("personal-request.json");
  second.id = "activity-personal-002";
  const third = await fixture("personal-request.json");
  third.id = "activity-personal-003";
  await ingress.handle(context(first, replies), NOW);
  assert.equal((await ingress.handle(context(second, replies), NOW)).disposition, "throttled");
  assert.equal((await ingress.handle(context(third, replies), NOW)).disposition, "throttled");
  assert.equal(sender.sent.length, 1);
  assert.equal(replies.length, 2);
  assert.match(replies[1].reply.text, /rate limit/);
});

test("publish arguments reject duplicate options", () => {
  assert.throws(
    () => parsePublishArgs([
      "--request-id", `tm_${"0".repeat(64)}`,
      "--outcome", "completed",
      "--text-file", "-",
      "--request-id", `tm_${"1".repeat(64)}`,
    ]),
    /may be specified only once/,
  );
});

test("malformed request and result envelopes fail closed", async () => {
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  assert.throws(() => validateRequest({ ...request, bodySha256: "0".repeat(64) }), ContractError);
  assert.throws(() => validateRequest({ ...request, unexpected: true }), ContractError);
  const result = makeResult(request, "accepted", "accepted");
  assert.throws(() => validateResult({ ...result, requestId: "tm_" + "0".repeat(64) }), ContractError);
  assert.throws(() => validateResult({ ...result, terminal: true }), ContractError);
});

test("correlation retention reserves delivery margin beyond message retention", async (t) => {
  const cloudEnvironment = {
    FM_TEAMS_ENABLED: "1",
    FM_TEAMS_TENANT_ID: TENANT,
    FM_TEAMS_BOT_APP_ID: "33333333-3333-3333-3333-333333333333",
    FM_TEAMS_BOT_RECIPIENT_ID: BOT,
    FM_TEAMS_ALLOWED_SENDER_IDS: SENDER,
    FM_TEAMS_ALLOWED_CONVERSATION_IDS: "a:personal-conversation",
    FM_TEAMS_SERVICE_BUS_NAMESPACE: "firstmate-test",
    FM_TEAMS_REQUEST_QUEUE: "requests-v1",
    FM_TEAMS_RESULT_QUEUE: "results-v1",
    FM_TEAMS_TABLE_ENDPOINT: "https://firstmate.table.core.windows.net",
    FM_TEAMS_TABLE_NAME: "teamsrequests",
    FM_TEAMS_KEY_VAULT_URL: "https://firstmate.vault.azure.net",
    FM_TEAMS_CERTIFICATE_NAME: "bot-certificate",
    FM_TEAMS_MANAGED_IDENTITY_CLIENT_ID: "44444444-4444-4444-4444-444444444444",
    FM_TEAMS_RETENTION_DAYS: "7",
    FM_TEAMS_MESSAGE_RETENTION_DAYS: "14",
  };
  assert.throws(() => cloudConfig(cloudEnvironment), /must exceed/);

  const home = await mkdtemp(path.join(os.tmpdir(), "fm-teams-config-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const file = path.join(home, "teams.json");
  await writeFile(file, `${JSON.stringify({
    schema: "firstmate.teams.config.v1",
    enabled: true,
    tenantId: TENANT,
    allowedSenderObjectIds: [SENDER],
    allowedConversationIds: ["a:personal-conversation"],
    serviceBusNamespace: "firstmate-test",
    requestQueue: "requests-v1",
    resultQueue: "results-v1",
    credential: "azure-cli",
    retentionDays: 7,
    messageRetentionDays: 14,
  })}\n`);
  await chmod(file, 0o600);
  await assert.rejects(connectorConfig(home, file), /must exceed/);

  cloudEnvironment.FM_TEAMS_RETENTION_DAYS = "15";
  assert.throws(() => cloudConfig(cloudEnvironment), /must exceed/);
  cloudEnvironment.FM_TEAMS_RETENTION_DAYS = "3";
  cloudEnvironment.FM_TEAMS_MESSAGE_RETENTION_DAYS = "1";
  assert.equal(cloudConfig(cloudEnvironment).retentionDays, 3);

  cloudEnvironment.FM_TEAMS_MAX_ACTIVITY_AGE_SECONDS = "604800";
  cloudEnvironment.FM_TEAMS_MAX_CLOCK_SKEW_SECONDS = "3600";
  assert.throws(() => cloudConfig(cloudEnvironment), /must cover the activity replay window/);
  cloudEnvironment.FM_TEAMS_RETENTION_DAYS = "10";
  assert.equal(cloudConfig(cloudEnvironment).retentionDays, 10);
});

test("request envelopes reserve queue time before correlation expiry", async () => {
  const request = parseTeamsActivity(await fixture("personal-request.json"), {
    ...config,
    retentionDays: 30,
    messageRetentionDays: 7,
  }, NOW);
  assert.equal(
    request.resultDeadline,
    new Date(NOW.getTime() + 22 * 86_400_000).toISOString(),
  );
  assert.throws(
    () => makeResult(request, "completed", "late", { createdAt: request.resultDeadline }),
    (error) => error instanceof ContractError && error.code === "expired",
  );
});

test("local connector rejects expired requests before durable processing", async () => {
  const work = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const status = parseTeamsActivity(await fixture("group-request.json"), config, NOW);
  const calls = [];
  const core = new ConnectorCore({
    config,
    store: { async capture() { calls.push("capture"); } },
    inbox: { async deliver() { calls.push("deliver"); } },
    statusReader: { async counts() { calls.push("status"); } },
    resultSender: { async send() { calls.push("result"); } },
    now: () => new Date(work.resultDeadline),
  });
  for (const request of [work, status]) {
    await assert.rejects(
      core.process(request),
      (error) => error instanceof ContractError && error.code === "expired",
    );
  }
  assert.deepEqual(calls, []);
});

test("local connector delivers allowlisted read-only work and preserves idempotence across restart and result outage", async () => {
  const activity = await fixture("personal-request.json");
  activity.text = "/firstmate summarize the open work";
  const request = parseTeamsActivity(activity, config, NOW);
  const records = new Map();
  const results = new Map();
  const store = new MemoryLocalStore(records, results);
  let inboxCalls = 0;
  const inbox = { async deliver(value) { inboxCalls += 1; return `external-teams-${value.requestId}`; } };
  const sender = new ArraySender([], 1);
  const core = new ConnectorCore({
    config,
    store,
    inbox,
    statusReader: { async counts() { return "counts"; } },
    resultSender: sender,
    now: () => NOW,
  });
  await assert.rejects(core.process(request), /queue unavailable/);
  assert.equal(inboxCalls, 1);
  assert.equal(records.get(request.requestId).state, "accepted");

  const recoveredSender = new ArraySender();
  const restarted = new ConnectorCore({
    config,
    store: new MemoryLocalStore(records, results),
    inbox,
    statusReader: { async counts() { return "counts"; } },
    resultSender: recoveredSender,
    now: () => NOW,
  });
  assert.equal((await restarted.process(request)).disposition, "accepted");
  assert.equal(inboxCalls, 1);
  assert.equal(recoveredSender.sent.length, 1);
  assert.equal((await restarted.process(request)).disposition, "duplicate");
  assert.equal(inboxCalls, 1);
});

test("mobile authority ceiling refuses privileged operations without inbox delivery", async () => {
  for (const text of [
    "merge pull request 42",
    "deploy this app to production",
    "delete the resource group",
    "discard my uncommitted work",
    "enter this client secret",
    "grant me a directory role",
    "open an inbound firewall port",
    "terraform apply the infrastructure",
    "disable the security policy",
  ]) {
    const activity = await fixture("personal-request.json");
    activity.id = `restricted-${Buffer.from(text).toString("hex").slice(0, 24)}`;
    activity.text = `/firstmate ${text}`;
    const request = parseTeamsActivity(activity, config, NOW);
    let delivered = false;
    const sender = new ArraySender();
    const core = new ConnectorCore({
      config,
      store: new MemoryLocalStore(),
      inbox: { async deliver() { delivered = true; } },
      statusReader: { async counts() { return "counts"; } },
      resultSender: sender,
      now: () => NOW,
    });
    const outcome = await core.process(request);
    assert.equal(outcome.disposition, "refused", text);
    assert.equal(delivered, false, text);
    assert.equal(sender.sent[0].outcome, "refused", text);
  }
  assert.equal(classifyAuthority("summarize the open work").allowed, true);
  assert.equal(classifyAuthority("list the backlog").allowed, true);
  assert.equal(classifyAuthority("show pending tasks?").allowed, true);
  assert.equal(classifyAuthority("fix issue 42 and add a regression test").allowed, false);
  assert.equal(classifyAuthority("explain how pull request merges work").allowed, false);
  assert.equal(classifyAuthority("land PR 42").allowed, false);
  assert.equal(classifyAuthority("git push --force origin main").allowed, false);
  assert.equal(classifyAuthority("give Alice Owner on the subscription").allowed, false);
  assert.equal(classifyAuthority("assign Alice the Owner role").allowed, false);
  assert.equal(classifyAuthority("run rm -rf ~/important-data").allowed, false);
  assert.equal(classifyAuthority("summarize the open work; then delete it").allowed, false);
  assert.equal(classifyAuthority("what is my access token").allowed, false);
});

test("result text is redacted before it reaches the transport", async () => {
  const request = parseTeamsActivity(await fixture("group-request.json"), config, NOW);
  const sender = new ArraySender();
  const core = new ConnectorCore({
    config,
    store: new MemoryLocalStore(),
    inbox: { async deliver() { throw new Error("unexpected inbox delivery"); } },
    statusReader: { async counts() { return "password=hunter2"; } },
    resultSender: sender,
    now: () => NOW,
  });
  await core.process(request);
  assert.equal(sender.sent.length, 1);
  assert.match(sender.sent[0].text, /delivery was withheld/);
  assert.doesNotMatch(sender.sent[0].text, /hunter2/);
});

test("status uses only the injected counts reader and bypasses inbox", async () => {
  const request = parseTeamsActivity(await fixture("group-request.json"), config, NOW);
  let delivered = false;
  const sender = new ArraySender();
  const core = new ConnectorCore({
    config,
    store: new MemoryLocalStore(),
    inbox: { async deliver() { delivered = true; } },
    statusReader: { async counts() { return "Workers on deck: 2.\nQueued: 1."; } },
    resultSender: sender,
    now: () => NOW,
  });
  assert.equal((await core.process(request)).disposition, "status");
  assert.equal(delivered, false);
  assert.equal(sender.sent[0].outcome, "status");
  assert.equal(sender.sent[0].text, "Workers on deck: 2.\nQueued: 1.");
});

test("secret-bearing replies are withheld and bounded replies are truncated", () => {
  for (const secret of [
    "password=hunter2",
    "{\"password\":\"hunter2\"}",
    "{\"access_token\":\"opaque-value\"}",
    "Bearer eyJsecretvalue",
    "ghp_abcdefghijklmnopqrstuvwxyz123456",
    "sk-proj-abcdefghijklmnopqrstuvwxyz123456",
    "AWS_SECRET_ACCESS_KEY=abcdefghijklmnopqrstuvwxyz1234567890",
    "xoxb-" + "123456789012-123456789012-" + "abcdefghijklmnopqrstuvwxyz",
    "glpat-abcdefghijklmnopqrstuvwxyz123456",
    "npm_abcdefghijklmnopqrstuvwxyz123456",
    "https://alice:super-secret@example.test/private",
    "https://storage.example/blob?sv=1&sig=secret-signature",
    "sv=2023-11-03&se=2027-01-01T00%3A00%3A00Z&sp=rw&sig=secret-signature",
    "sp=r&sig=secret-signature&sv=2023-11-03",
  ]) {
    assert.equal(redactReply(secret).includes(secret), false);
    assert.match(redactReply(secret), /delivery was withheld/);
  }
  const bounded = redactReply("x".repeat(5000), 300);
  assert.ok(Buffer.byteLength(bounded, "utf8") <= 300);
  assert.match(bounded, /Reply truncated/);
});

test("result worker redacts before cloud persistence", async () => {
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const base = new MemoryRequestStore();
  await base.claimRequest(request);
  let persisted;
  let posted;
  const worker = new TeamsResultWorker({
    store: {
      requestById: (...args) => base.requestById(...args),
      async claimResult(result, enqueuedAt) { persisted = result; return base.claimResult(result, enqueuedAt); },
      markResultPosted: (...args) => base.markResultPosted(...args),
      markRequestOutcome: (...args) => base.markRequestOutcome(...args),
    },
    allowedSenderObjectIds: config.allowedSenderObjectIds,
    allowedConversationIds: config.allowedConversationIds,
    poster: { async post(value) { posted = value; return "safe-reply"; } },
  });
  await worker.process(
    makeResult(request, "completed", "password=hunter2", { createdAt: NOW.toISOString() }),
    { enqueuedTimeUtc: NOW },
  );
  assert.match(persisted.text, /delivery was withheld/);
  assert.doesNotMatch(persisted.text, /hunter2/);
  assert.equal(posted.activity.text, persisted.text);
});

test("result worker enforces trusted queue timing before posting", async () => {
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const store = new MemoryRequestStore();
  await store.claimRequest(request);
  let posts = 0;
  const worker = new TeamsResultWorker({
    store,
    allowedSenderObjectIds: config.allowedSenderObjectIds,
    allowedConversationIds: config.allowedConversationIds,
    poster: { async post() { posts += 1; return "unexpected"; } },
  });
  const result = makeResult(request, "completed", "done", { createdAt: NOW.toISOString() });
  await assert.rejects(
    worker.process(result, { enqueuedTimeUtc: new Date(request.resultDeadline) }),
    (error) => error instanceof ContractError && error.code === "expired",
  );
  const futureDated = makeResult(request, "completed", "done", {
    createdAt: new Date(NOW.getTime() + 86_400_000).toISOString(),
  });
  await assert.rejects(
    worker.process(futureDated, { enqueuedTimeUtc: NOW }),
    (error) => error instanceof ContractError && error.code === "expired",
  );
  await assert.rejects(
    worker.process(result),
    (error) => error instanceof ContractError && error.code === "malformed",
  );
  assert.equal(posts, 0);
  assert.equal(store.results.size, 0);
});

test("result worker binds the stored request and exact source activity thread", async () => {
  const request = parseTeamsActivity(await fixture("group-request.json"), config, NOW);
  const store = new MemoryRequestStore();
  await store.claimRequest(request);
  await store.markRequestEnqueued(request.requestId);
  const calls = [];
  const result = makeResult(request, "completed", "Finished safely.", { createdAt: NOW.toISOString() });
  const deniedWorker = new TeamsResultWorker({
    store,
    allowedSenderObjectIds: config.allowedSenderObjectIds,
    allowedConversationIds: new Set(["a:personal-conversation"]),
    poster: { async post(value) { calls.push(value); return "unexpected"; } },
  });
  await assert.rejects(deniedWorker.process(result, { enqueuedTimeUtc: NOW }), /conversation is no longer authorized/);
  assert.equal(calls.length, 0);
  const revokedWorker = new TeamsResultWorker({
    store,
    allowedSenderObjectIds: new Set(),
    allowedConversationIds: config.allowedConversationIds,
    poster: { async post(value) { calls.push(value); return "unexpected"; } },
  });
  await assert.rejects(revokedWorker.process(result, { enqueuedTimeUtc: NOW }), /sender is no longer authorized/);
  assert.equal(calls.length, 0);
  const worker = new TeamsResultWorker({
    store,
    allowedSenderObjectIds: config.allowedSenderObjectIds,
    allowedConversationIds: config.allowedConversationIds,
    poster: { async post(value) { calls.push(value); return "teams-reply-123"; } },
  });
  const posted = await worker.process(result, { enqueuedTimeUtc: NOW });
  assert.equal(posted.replyActivityId, "teams-reply-123");
  assert.equal(calls[0].activity.replyToId, request.source.activityId);
  assert.equal(calls[0].reference.conversation.id, request.source.conversationId);
  assert.equal(calls[0].reference.conversation.tenantId, request.source.tenantId);
  assert.equal((await worker.process(result, { enqueuedTimeUtc: NOW })).disposition, "duplicate");
  assert.equal(calls.length, 1);
  await assert.rejects(
    worker.process(
      makeResult(request, "accepted", "accepted", { createdAt: NOW.toISOString() }),
      { enqueuedTimeUtc: NOW },
    ),
    /already has a terminal result/,
  );
  await assert.rejects(
    worker.process(
      makeResult(request, "failed", "failed", { createdAt: NOW.toISOString() }),
      { enqueuedTimeUtc: NOW },
    ),
    /already has a terminal result/,
  );
  assert.equal(calls.length, 1);

  const wrong = structuredClone(result);
  wrong.source.conversationId = "other-conversation";
  assert.throws(() => validateResult(wrong), /request id does not match/);
});

test("result worker serializes one request while posting unrelated requests concurrently", async () => {
  const firstRequest = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const secondActivity = await fixture("personal-request.json");
  secondActivity.id = "activity-personal-002";
  const secondRequest = parseTeamsActivity(secondActivity, config, NOW);
  const store = new MemoryRequestStore();
  await store.claimRequest(firstRequest);
  await store.claimRequest(secondRequest);

  let activePosts = 0;
  let maximumActivePosts = 0;
  let startedPosts = 0;
  let releasePosts;
  let announceStarted;
  const postsStarted = new Promise((resolve) => { announceStarted = resolve; });
  const postsReleased = new Promise((resolve) => { releasePosts = resolve; });
  const worker = new TeamsResultWorker({
    store,
    allowedSenderObjectIds: config.allowedSenderObjectIds,
    allowedConversationIds: config.allowedConversationIds,
    poster: {
      async post({ activity }) {
        activePosts += 1;
        maximumActivePosts = Math.max(maximumActivePosts, activePosts);
        startedPosts += 1;
        if (startedPosts === 2) announceStarted();
        await postsReleased;
        activePosts -= 1;
        return `reply-${activity.replyToId}`;
      },
    },
  });
  const firstResult = makeResult(firstRequest, "completed", "first", { createdAt: NOW.toISOString() });
  const secondResult = makeResult(secondRequest, "completed", "second", { createdAt: NOW.toISOString() });
  const firstPost = worker.process(firstResult, { enqueuedTimeUtc: NOW });
  const duplicatePost = worker.process(firstResult, { enqueuedTimeUtc: NOW });
  const unrelatedPost = worker.process(secondResult, { enqueuedTimeUtc: NOW });
  await postsStarted;
  assert.equal(maximumActivePosts, 2);
  releasePosts();
  const outcomes = await Promise.all([firstPost, duplicatePost, unrelatedPost]);
  assert.deepEqual(outcomes.map(({ disposition }) => disposition), ["posted", "duplicate", "posted"]);
  assert.equal(startedPosts, 2);
});

test("posted result redelivery repairs its request outcome without reposting", async () => {
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const base = new MemoryRequestStore();
  await base.claimRequest(request);
  let failOutcome = true;
  const store = {
    requestById: (...args) => base.requestById(...args),
    claimResult: (...args) => base.claimResult(...args),
    markResultPosted: (...args) => base.markResultPosted(...args),
    async markRequestOutcome(...args) {
      if (failOutcome) {
        failOutcome = false;
        throw new Error("table update unavailable");
      }
      return base.markRequestOutcome(...args);
    },
  };
  let posts = 0;
  const worker = new TeamsResultWorker({
    store,
    allowedSenderObjectIds: config.allowedSenderObjectIds,
    allowedConversationIds: config.allowedConversationIds,
    poster: { async post() { posts += 1; return "teams-reply-recovery"; } },
  });
  const result = makeResult(request, "completed", "done", { createdAt: NOW.toISOString() });
  await assert.rejects(worker.process(result, { enqueuedTimeUtc: NOW }), /table update unavailable/);
  assert.equal((await worker.process(result, { enqueuedTimeUtc: NOW })).disposition, "duplicate");
  assert.equal(posts, 1);
  assert.equal((await base.requestById(request.requestId)).status, "result-terminal");
});

test("terminal request state is not regressed by a late acknowledgement", async () => {
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const store = new MemoryRequestStore();
  const enqueue = await store.claimRequest(request);
  await store.markRequestEnqueued(request.requestId, request.source.tenantId, request.source, enqueue.enqueueClaimToken);
  await store.markRequestOutcome(makeResult(request, "completed", "done", { createdAt: NOW.toISOString() }));
  const acknowledgement = await store.claimRequestAcknowledgement(request.requestId);
  await store.markRequestAcknowledged(
    request.requestId,
    request.source.tenantId,
    "late-ack",
    request.source,
    acknowledgement.acknowledgementClaimToken,
  );
  const record = await store.requestById(request.requestId);
  assert.equal(record.status, "result-terminal");
  assert.equal(record.acknowledgementActivityId, "late-ack");
});

test("real inbox owner stores shell metacharacters as inert stdin and deduplicates the external identity", async (t) => {
  const home = await mkdtemp(path.join(os.tmpdir(), "fm-teams-test-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  request.command.text = "review $(touch SHOULD_NOT_EXIST); `uname`; && echo safe";
  request.bodySha256 = (await import("../src/contracts.mjs")).bodySha256(request.command.text);
  const adapter = new FirstmateInboxAdapter({ home, root: ROOT });
  const first = await adapter.deliver(request);
  const second = await adapter.deliver(request);
  assert.equal(first, second);
  const notes = (await readdir(path.join(home, "state", "inbox"))).filter((name) => name.endsWith(".note"));
  assert.deepEqual(notes, [`${first}.note`]);
  const body = await readFile(path.join(home, "state", "inbox", notes[0]), "utf8");
  assert.match(body, /review \$\(touch SHOULD_NOT_EXIST\); `uname`; && echo safe/);
  await assert.rejects(stat(path.join(ROOT, "SHOULD_NOT_EXIST")), (error) => error.code === "ENOENT");
  const wakePath = path.join(home, "state", ".wake-queue");
  const wake = await readFile(wakePath, "utf8");
  assert.equal(wake.trim().split("\n").length, 1);
  assert.match(wake, new RegExp(`inbox:${first}`));
  assert.equal((await stat(wakePath)).mode & 0o077, 0);
  assert.equal((await stat(path.join(home, "state", "inbox"))).mode & 0o077, 0);
  const handled = path.join(home, "state", "inbox", "handled");
  assert.equal((await stat(handled)).mode & 0o077, 0);
  const sourceHandled = path.join(handled, "external-teams");
  const currentHandledPartition = path.join(sourceHandled, new Date().toISOString().slice(0, 10));
  await execFileAsync(path.join(ROOT, "bin", "fm-inbox.sh"), ["drain", "--ack", first], {
    env: { ...process.env, FM_HOME: home },
  });
  const handledNoteIndex = path.join(sourceHandled, "by-id", `${first}.note`);
  assert.equal(
    (await stat(handledNoteIndex)).ino,
    (await stat(path.join(currentHandledPartition, `${first}.note`))).ino,
  );
  const originalText = request.command.text;
  const originalHash = request.bodySha256;
  request.command.text = "different content for the same immutable identity";
  await assert.rejects(adapter.deliver(request), /reused with different content/);
  request.command.text = originalText;
  request.bodySha256 = originalHash;
  assert.equal(await adapter.deliver(request), first);
  const oldPartition = path.join(sourceHandled, "2000-01-01");
  await rename(currentHandledPartition, oldPartition);
  const handledNote = path.join(oldPartition, `${first}.note`);
  const old = new Date(Date.now() - 8 * 86_400_000);
  await utimes(handledNote, old, old);
  const currentPartition = path.join(sourceHandled, "2999-01-01");
  await mkdir(currentPartition, { recursive: true, mode: 0o700 });
  const currentNote = path.join(currentPartition, `external-teams-tm_${"b".repeat(64)}.note`);
  await writeFile(currentNote, "current\n");
  assert.equal(await adapter.purgeHandled(7, 1), 1);
  await assert.rejects(stat(handledNote), (error) => error.code === "ENOENT");
  await assert.rejects(stat(handledNoteIndex), (error) => error.code === "ENOENT");
  assert.equal((await stat(currentNote)).isFile(), true);
  assert.equal(await adapter.purgeHandled(7, 1), 0);

  const wakeLock = path.join(home, "state", ".wake-queue.lock");
  await mkdir(wakeLock);
  await writeFile(path.join(wakeLock, "pid"), `${process.pid}\n`);
  const purgeWhileWakeLocked = adapter.purgeHandled(7, 1);
  let timeout;
  let outcome;
  try {
    outcome = await Promise.race([
      purgeWhileWakeLocked.then((count) => ({ count })),
      new Promise((resolve) => { timeout = setTimeout(() => resolve({ blocked: true }), 6_000); }),
    ]);
  } finally {
    clearTimeout(timeout);
    await rm(wakeLock, { recursive: true, force: true });
  }
  if (outcome.blocked) await purgeWhileWakeLocked;
  assert.deepEqual(outcome, { count: 0 });
});

test("Teams manifest exposes only the supported bot scopes with file handling disabled", async () => {
  const manifest = JSON.parse(await readFile(path.join(ROOT, "integrations", "teams", "manifest", "manifest.json"), "utf8"));
  assert.equal(manifest.manifestVersion, "1.19");
  assert.deepEqual(manifest.bots[0].scopes, ["personal", "groupChat", "team"]);
  assert.equal(manifest.bots[0].supportsFiles, false);
  assert.deepEqual(manifest.permissions, ["identity"]);
  assert.equal(manifest.webApplicationInfo, undefined);
});

test("configured retention removes terminal and stranded local records", async (t) => {
  const home = await mkdtemp(path.join(os.tmpdir(), "fm-teams-retention-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const store = new LocalRequestStore(home);
  await store.capture(request);
  const active = await store.get(request.requestId);
  await writeFile(store.requestPath(request.requestId), `${JSON.stringify({ ...active, capturedAt: "2020-01-01T00:00:00.000Z" })}\n`);
  await writeFile(store.lockPath(request.requestId), "incomplete");
  assert.equal(await store.purgeBefore(new Date("2019-01-01T00:00:00.000Z")), 0);
  await rm(store.lockPath(request.requestId));

  const result = makeResult(request, "completed", "complete", { createdAt: NOW.toISOString() });
  await store.queueResult(result, async () => {});
  const queued = await store.get(request.requestId);
  await writeFile(store.requestPath(request.requestId), `${JSON.stringify({ ...queued, updatedAt: "2020-01-01T00:00:00.000Z" })}\n`);
  const resultRecord = JSON.parse(await readFile(store.resultPath(result.resultId), "utf8"));
  await writeFile(store.resultPath(result.resultId), `${JSON.stringify({ ...resultRecord, queuedAt: "2020-01-01T00:00:00.000Z" })}\n`);

  const abandonedActivity = await fixture("personal-request.json");
  abandonedActivity.id = "activity-personal-abandoned";
  const abandoned = parseTeamsActivity(abandonedActivity, config, NOW);
  await store.capture(abandoned);
  await store.update(abandoned.requestId, { state: "accepted", inboxId: "inbox-id" });
  const abandonedRecord = await store.get(abandoned.requestId);
  await writeFile(store.requestPath(abandoned.requestId), `${JSON.stringify({ ...abandonedRecord, updatedAt: "2020-01-01T00:00:00.000Z" })}\n`);

  const publishingActivity = await fixture("personal-request.json");
  publishingActivity.id = "activity-personal-publishing";
  const publishingRequest = parseTeamsActivity(publishingActivity, config, NOW);
  await store.capture(publishingRequest);
  const publishingResult = makeResult(publishingRequest, "failed", "failed", { createdAt: NOW.toISOString() });
  await assert.rejects(store.queueResult(publishingResult, async () => { throw new Error("queue unavailable"); }), /queue unavailable/);
  const publishingRequestRecord = await store.get(publishingRequest.requestId);
  await writeFile(store.requestPath(publishingRequest.requestId), `${JSON.stringify({ ...publishingRequestRecord, updatedAt: "2020-01-01T00:00:00.000Z" })}\n`);
  const publishingResultRecord = JSON.parse(await readFile(store.resultPath(publishingResult.resultId), "utf8"));
  await writeFile(store.resultPath(publishingResult.resultId), `${JSON.stringify({ ...publishingResultRecord, publishingAt: "2020-01-01T00:00:00.000Z" })}\n`);

  assert.equal(await store.purgeBefore(NOW), 5);
  assert.equal(await store.get(request.requestId), null);
  assert.equal(await store.get(abandoned.requestId), null);
  assert.equal(await store.get(publishingRequest.requestId), null);
  await assert.rejects(readFile(store.resultPath(publishingResult.resultId)), (error) => error.code === "ENOENT");
});

test("local retention reserves deletion capacity for results", async (t) => {
  const home = await mkdtemp(path.join(os.tmpdir(), "fm-teams-retention-fair-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const store = new LocalRequestStore(home);
  await store.ensure();
  await writeFile(store.requestPath("request_0001"), '{"updatedAt":"2020-01-01T00:00:00.000Z"}\n');
  await writeFile(store.requestPath("request_0002"), '{"updatedAt":"2020-01-01T00:00:00.000Z"}\n');
  await writeFile(store.resultPath("result_00001"), '{"queuedAt":"2020-01-01T00:00:00.000Z"}\n');
  assert.equal(await store.purgeBefore(NOW, 2, 10), 2);
  await assert.rejects(readFile(store.resultPath("result_00001")), (error) => error.code === "ENOENT");
  assert.equal((await readdir(store.requests)).filter((name) => name.endsWith(".json")).length, 1);
});

test("concurrent local updates preserve a terminal outcome", async (t) => {
  const home = await mkdtemp(path.join(os.tmpdir(), "fm-teams-lock-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const first = new LocalRequestStore(home);
  const second = new LocalRequestStore(home);
  await first.capture(request);
  await first.update(request.requestId, { state: "accepted", inboxId: "inbox-id" });
  await Promise.all([
    first.update(request.requestId, { state: "result-queued", outcome: "completed" }),
    second.update(request.requestId, { state: "result-queued", outcome: "accepted" }),
  ]);
  const record = await first.get(request.requestId);
  assert.equal(record.state, "result-queued");
  assert.equal(record.outcome, "completed");
});

test("local result publication serializes and rejects conflicting claims", async (t) => {
  const home = await mkdtemp(path.join(os.tmpdir(), "fm-teams-results-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const store = new LocalRequestStore(home);
  await store.capture(request);
  let sends = 0;
  let signalStarted;
  let releaseSend;
  const started = new Promise((resolve) => { signalStarted = resolve; });
  const release = new Promise((resolve) => { releaseSend = resolve; });
  const first = makeResult(request, "completed", "first", { createdAt: NOW.toISOString() });
  const conflicting = makeResult(request, "completed", "different", { createdAt: new Date(NOW.getTime() + 1000).toISOString() });
  const publication = store.queueResult(first, async () => {
    sends += 1;
    signalStarted();
    await release;
  });
  await started;
  const conflict = store.queueResult(conflicting, async () => { sends += 1; });
  releaseSend();
  assert.equal((await publication).queued, true);
  await assert.rejects(conflict, /different content/);
  assert.equal(sends, 1);
  await assert.rejects(
    store.queueResult(makeResult(request, "failed", "failed", { createdAt: NOW.toISOString() }), async () => {}),
    /conflicting terminal result/,
  );
});

test("failed terminal publication reserves its exact result", async (t) => {
  const home = await mkdtemp(path.join(os.tmpdir(), "fm-teams-result-reservation-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const store = new LocalRequestStore(home);
  await store.capture(request);
  const completed = makeResult(request, "completed", "done", { createdAt: NOW.toISOString() });
  await assert.rejects(store.queueResult(completed, async () => { throw new Error("ambiguous send"); }), /ambiguous send/);
  const reserved = await store.get(request.requestId);
  assert.equal(reserved.state, "result-publishing");
  assert.equal(reserved.outcome, "completed");
  assert.equal(reserved.terminalResultId, completed.resultId);
  await assert.rejects(
    store.queueResult(makeResult(request, "failed", "failed", { createdAt: NOW.toISOString() }), async () => {}),
    /conflicting terminal result/,
  );
  let retried = 0;
  assert.equal((await store.queueResult(completed, async () => { retried += 1; })).queued, true);
  assert.equal(retried, 1);
  assert.equal((await store.get(request.requestId)).state, "result-queued");
});

test("a terminal result supersedes the automatic accepted result", async (t) => {
  const home = await mkdtemp(path.join(os.tmpdir(), "fm-teams-terminal-race-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const store = new LocalRequestStore(home);
  let acceptedSends = 0;
  const core = new ConnectorCore({
    config,
    store,
    inbox: {
      async deliver() {
        const completed = makeResult(request, "completed", "done", { createdAt: NOW.toISOString() });
        await store.queueResult(completed, async () => {});
        return "inbox-id";
      },
    },
    statusReader: { async counts() { return "counts"; } },
    resultSender: { async send() { acceptedSends += 1; } },
    now: () => NOW,
  });
  assert.equal((await core.process(request)).disposition, "accepted");
  assert.equal(acceptedSends, 0);
  const record = await store.get(request.requestId);
  assert.equal(record.state, "result-queued");
  assert.equal(record.outcome, "completed");
  assert.equal(record.inboxId, "inbox-id");
});

test("request lock rejects a reused live pid with a different process identity", async (t) => {
  const home = await mkdtemp(path.join(os.tmpdir(), "fm-teams-reused-pid-lock-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const store = new LocalRequestStore(home);
  await store.ensure();
  await writeFile(store.lockPath(request.requestId), `${JSON.stringify({
    schema: "firstmate.teams.lock-owner.v2",
    pid: process.pid,
    processIdentity: "different-process-start",
    token: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    createdAt: new Date().toISOString(),
  })}\n`);
  let called = false;
  await store.withRequestLock(request.requestId, async () => { called = true; });
  assert.equal(called, true);
  await assert.rejects(stat(store.lockPath(request.requestId)), (error) => error.code === "ENOENT");
});

test("request lock recovers stale malformed lock and cleanup records", async (t) => {
  const home = await mkdtemp(path.join(os.tmpdir(), "fm-teams-malformed-lock-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const store = new LocalRequestStore(home);
  await store.ensure();
  const lock = store.lockPath(request.requestId);
  await writeFile(lock, "");
  await writeFile(`${lock}.cleanup`, "incomplete");
  const stale = new Date(Date.now() - 60_000);
  await utimes(lock, stale, stale);
  await utimes(`${lock}.cleanup`, stale, stale);
  let called = false;
  await store.withRequestLock(request.requestId, async () => { called = true; });
  assert.equal(called, true);
  await assert.rejects(stat(lock), (error) => error.code === "ENOENT");
  await assert.rejects(stat(`${lock}.cleanup`), (error) => error.code === "ENOENT");
});

test("request lock release preserves a replacement lock owner", async (t) => {
  const home = await mkdtemp(path.join(os.tmpdir(), "fm-teams-lock-owner-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const store = new LocalRequestStore(home);
  await store.ensure();
  await store.withRequestLock(request.requestId, async () => {
    await rm(store.lockPath(request.requestId));
    await writeFile(store.lockPath(request.requestId), "replacement\n");
  });
  assert.equal(await readFile(store.lockPath(request.requestId), "utf8"), "replacement\n");
});

test("local request files are owner-only and recover incomplete captures", async (t) => {
  const home = await mkdtemp(path.join(os.tmpdir(), "fm-teams-store-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const first = new LocalRequestStore(home);
  await first.ensure();
  await writeFile(first.requestPath(request.requestId), "{\"schema\":");
  assert.equal((await first.capture(request)).created, true);
  const second = new LocalRequestStore(home);
  const record = await second.get(request.requestId);
  assert.equal(record.request.source.activityId, request.source.activityId);
  const info = await stat(second.requestPath(request.requestId));
  assert.equal(info.mode & 0o077, 0);
});

test("cloud retention is anchored to receipt and trusted result enqueue time", async () => {
  const entities = new Map();
  const key = (entity) => `${entity.partitionKey}:${entity.rowKey}`;
  const table = {
    async createEntity(entity) {
      if (entities.has(key(entity))) {
        const error = new Error("conflict");
        error.statusCode = 409;
        throw error;
      }
      entities.set(key(entity), { ...entity, etag: 'W/"1"' });
    },
    async getEntity(partitionKey, rowKey) { return entities.get(`${partitionKey}:${rowKey}`); },
    async updateEntity(entity) {
      const current = entities.get(key(entity));
      entities.set(key(entity), { ...current, ...entity, etag: 'W/"2"' });
    },
    async deleteEntity(partitionKey, rowKey) { entities.delete(`${partitionKey}:${rowKey}`); },
    listEntities() {
      return (async function* expiredIndexes() {
        for (const entity of entities.values()) {
          if (entity.targetPartition?.startsWith("request_")
              && entity.activityAt < new Date("2026-09-22T06:15:00.000Z")) yield entity;
        }
      })();
    },
    async submitTransaction(actions) {
      if (actions.some(([operation, entity]) => operation === "create" && entities.has(key(entity)))) {
        const error = new Error("conflict");
        error.statusCode = 409;
        throw error;
      }
      for (const [operation, entity] of actions) {
        if (operation === "create") entities.set(key(entity), { ...entity, etag: 'W/"1"' });
        else entities.delete(key(entity));
      }
    },
  };
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  request.receivedAt = "2026-09-22T06:00:00.000Z";
  const store = new AzureTableRequestStore(table);
  await store.claimRequest(request);
  await store.claimRequest({ ...request, receivedAt: "2026-09-24T08:00:00.000Z" });
  assert.equal([...entities.values()].some((entity) => (
    entity.partitionKey === "expiry_2026092408" && entity.targetRow === request.requestId
  )), false);
  const result = makeResult(request, "completed", "done", { createdAt: "2026-09-22T06:30:00.000Z" });
  await store.claimResult(result, new Date("2026-09-22T07:00:00.000Z"));
  const indexes = [...entities.values()].filter((entity) => entity.targetPartition);
  const requestIndexes = indexes.filter((entity) => entity.targetPartition.startsWith("request_"));
  const resultIndex = indexes.find((entity) => entity.targetPartition.startsWith("result_"));
  assert.deepEqual(requestIndexes.map((entity) => entity.partitionKey), ["expiry_2026092206", "expiry_2026092207"]);
  assert.notEqual(requestIndexes[0].rowKey, requestIndexes[1].rowKey);
  assert.equal(resultIndex.partitionKey, "expiry_2026092207");
  assert.equal(resultIndex.activityAt.toISOString(), "2026-09-22T07:00:00.000Z");

  await store.purgeBefore(new Date("2026-09-22T06:15:00.000Z"));
  assert.equal(entities.has(`request_${TENANT}:${request.requestId}`), true);
  assert.equal([...entities.values()].some((entity) => (
    entity.targetRow === request.requestId && entity.activityAt?.toISOString() === request.receivedAt
  )), false);
  assert.equal([...entities.values()].some((entity) => (
    entity.targetRow === request.requestId && entity.activityAt?.toISOString() === "2026-09-22T07:00:00.000Z"
  )), true);
});

test("cloud result retention index is durable before request retention advances", async () => {
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const result = makeResult(request, "completed", "done", {
    createdAt: new Date(NOW.getTime() + 60_000).toISOString(),
  });
  let updates = 0;
  const table = {
    async createEntity(entity) {
      if (entity.targetPartition?.startsWith("request_")) {
        const error = new Error("index unavailable");
        error.statusCode = 503;
        throw error;
      }
    },
    async getEntity() {
      return {
        status: "acknowledged",
        retentionAt: request.receivedAt,
        etag: 'W/"1"',
      };
    },
    async updateEntity() { updates += 1; },
  };
  await assert.rejects(new AzureTableRequestStore(table).claimResult(result, NOW), /index unavailable/);
  assert.equal(updates, 0);
});

test("cloud queue reconciliation conditionally claims and republishes failed requests", async () => {
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const partitionKey = `request_${TENANT}`;
  const retryAt = new Date(NOW.getTime() - 1);
  const retryRowKey = `enqueue_${String(retryAt.getTime()).padStart(15, "0")}_${request.requestId}`;
  let entity = {
    partitionKey,
    rowKey: request.requestId,
    status: "queue-error",
    enqueueStatus: "queue-error",
    enqueueClaimToken: "",
    enqueueNextAttemptAt: retryAt.toISOString(),
    requestJson: JSON.stringify(request),
    etag: 'W/"1"',
  };
  const indexes = new Map([[retryRowKey, { partitionKey, rowKey: retryRowKey, targetRow: request.requestId }]]);
  const listOptions = [];
  let version = 1;
  const conditionalEtags = [];
  const table = {
    listEntities(options) {
      listOptions.push(options);
      return (async function* pending() {
        const lower = options.queryOptions.filter.match(/RowKey ge '([^']+)'/)?.[1];
        const upper = options.queryOptions.filter.match(/RowKey lt '([^']+)'/)?.[1];
        for (const index of [...indexes.values()].sort((left, right) => left.rowKey.localeCompare(right.rowKey))) {
          if (index.rowKey >= lower && index.rowKey < upper) yield index;
        }
      })();
    },
    async getEntity() { return entity; },
    async createEntity(index) { indexes.set(index.rowKey, index); },
    async submitTransaction(actions) {
      const update = actions.find(([operation]) => operation === "update");
      assert.ok(update);
      conditionalEtags.push(update[3].etag);
      assert.equal(update[3].etag, entity.etag);
      for (const [operation, value] of actions) {
        if (operation === "update") {
          version += 1;
          entity = { ...entity, ...value, etag: `W/"${version}"` };
        } else if (operation === "delete") indexes.delete(value.rowKey);
        else if (operation === "upsert" || operation === "create") indexes.set(value.rowKey, value);
      }
    },
    async deleteEntity(_partitionKey, rowKey) { indexes.delete(rowKey); },
  };
  const store = new AzureTableRequestStore(table);
  const failingSender = new ArraySender([], 1);
  const failed = await reconcilePendingEnqueues({
    store,
    requestSender: failingSender,
    tenantId: TENANT,
    now: NOW,
  });
  assert.deepEqual(failed, { claimed: 1, enqueued: 0, failed: 1 });
  assert.equal(entity.enqueueStatus, "queue-error");
  assert.equal(indexes.size, 1);
  const scheduledIndex = [...indexes.values()][0];
  const scheduledAt = scheduledIndex.nextAttemptAt;
  assert.ok(scheduledIndex.rowKey.startsWith(`enqueue_${String(scheduledAt.getTime()).padStart(15, "0")}_`));

  const sender = new ArraySender();
  assert.deepEqual(await reconcilePendingEnqueues({
    store,
    requestSender: sender,
    tenantId: TENANT,
    now: new Date(scheduledAt.getTime() - 1),
  }), { claimed: 0, enqueued: 0, failed: 0 });
  const recovered = await reconcilePendingEnqueues({
    store,
    requestSender: sender,
    tenantId: TENANT,
    now: scheduledAt,
  });
  assert.deepEqual(recovered, { claimed: 1, enqueued: 1, failed: 0 });
  assert.equal(entity.enqueueStatus, "enqueued");
  assert.equal(indexes.size, 0);
  assert.equal(sender.sent[0].requestId, request.requestId);
  assert.equal(conditionalEtags.length, 4);
  assert.match(listOptions[0].queryOptions.filter, /RowKey ge 'enqueue_000000000000000_'/);
  assert.match(listOptions[0].queryOptions.filter, /RowKey lt 'enqueue_\d{15}_'/);
  assert.doesNotMatch(listOptions[0].queryOptions.filter, /nextAttemptAt/);
  assert.deepEqual(listOptions[0].queryOptions.select, ["PartitionKey", "RowKey", "targetRow"]);
});

test("cloud enqueue claiming preserves sibling claims when one candidate fails", async () => {
  const request = parseTeamsActivity(await fixture("personal-request.json"), config, NOW);
  const dueAt = new Date(NOW.getTime() + 5 * 60_000);
  const candidates = ["failed-request", request.requestId].map((targetRow) => ({
    partitionKey: `request_${TENANT}`,
    rowKey: `enqueue_${String(dueAt.getTime()).padStart(15, "0")}_${targetRow}`,
    targetRow,
  }));
  let successfulClaimFinished = false;
  const table = {
    listEntities() { return (async function* listedCandidates() { yield* candidates; })(); },
    async createEntity() {},
    async deleteEntity() {},
  };
  const store = new AzureTableRequestStore(table);
  store.transitionEnqueueRequest = async (requestId, _source, transition) => {
    if (requestId === "failed-request") throw new Error("claim failed");
    await new Promise((resolve) => setTimeout(resolve, 10));
    const current = {
      enqueueStatus: "queue-error",
      enqueueNextAttemptAt: new Date(NOW.getTime() - 1).toISOString(),
      requestJson: JSON.stringify(request),
    };
    successfulClaimFinished = true;
    return { ...current, ...transition(current) };
  };
  const result = await store.claimPendingEnqueues(TENANT, 500, 2, NOW);
  assert.equal(successfulClaimFinished, true);
  assert.equal(result.claims.length, 1);
  assert.equal(result.claims[0].request.requestId, request.requestId);
  assert.equal(result.failures.length, 1);
  assert.match(result.failures[0].error.message, /claim failed/);
});

test("cloud request transitions use etags and preserve terminal status", async () => {
  const updates = [];
  let entity = {
    status: "result-terminal",
    enqueueStatus: "enqueued",
    acknowledgementStatus: "pending",
    etag: 'W/"version"',
  };
  const table = {
    async getEntity() { return entity; },
    async updateEntity(updated, mode, options) {
      updates.push({ entity: updated, mode, options });
      entity = { ...entity, ...updated };
    },
  };
  const store = new AzureTableRequestStore(table);
  const source = (await fixture("personal-request.json"));
  const request = parseTeamsActivity(source, config, NOW);
  const acknowledgement = await store.claimRequestAcknowledgement("tm_" + "a".repeat(64), request.source);
  await store.markRequestAcknowledged(
    "tm_" + "a".repeat(64),
    TENANT,
    "late-ack",
    request.source,
    acknowledgement.acknowledgementClaimToken,
  );
  assert.equal(updates[1].entity.status, "result-terminal");
  assert.equal(updates[1].entity.etag, undefined);
  assert.equal(updates[1].entity.acknowledgementActivityId, "late-ack");
  assert.equal(updates[1].mode, "Merge");
  assert.equal(updates[1].options.etag, 'W/"version"');
});

test("certificate materialization cannot collide with leftovers from an earlier process", async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "fm-teams-certificates-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const material = { x5c: "certificate\n", privateKey: "private-key\n" };
  const first = await materializeBotCertificate(material, directory);
  const second = await materializeBotCertificate(material, directory);
  assert.notEqual(first.certificatePath, second.certificatePath);
  assert.notEqual(first.privateKeyPath, second.privateKeyPath);
  assert.equal((await stat(first.certificatePath)).mode & 0o077, 0);
  assert.equal((await stat(first.privateKeyPath)).mode & 0o077, 0);
});

test("resource shutdown attempts every close before reporting failures", async () => {
  const closed = [];
  await assert.rejects(
    closeResources([
      { close() { closed.push("subscription"); throw new Error("subscription close failed"); } },
      { async close() { closed.push("receiver"); } },
      { async close() { closed.push("client"); throw new Error("client close failed"); } },
    ]),
    (error) => error instanceof AggregateError && error.errors.length === 2,
  );
  assert.deepEqual(closed.sort(), ["client", "receiver", "subscription"]);
});

test("peek-lock processing passes trusted queue metadata to handlers", async () => {
  const message = { body: { value: "result" }, enqueuedTimeUtc: NOW };
  let received;
  let completed;
  const receiver = {
    async completeMessage(value) { completed = value; },
  };
  await processPeekLockMessage(receiver, message, async (body, metadata) => {
    received = { body, metadata };
  });
  assert.deepEqual(received, {
    body: message.body,
    metadata: { enqueuedTimeUtc: NOW },
  });
  assert.equal(completed, message);
});

test("dead-letter retention settles only expired messages in bounded batches", async () => {
  const expired = { enqueuedTimeUtc: new Date("2020-01-01T00:00:00.000Z") };
  const current = { enqueuedTimeUtc: NOW };
  const completed = [];
  const abandoned = [];
  const queued = [expired, current];
  const receiver = {
    async peekMessages(limit, options) {
      assert.equal(limit, 2);
      assert.equal(options.fromSequenceNumber.toString(), "0");
      assert.equal(typeof options.fromSequenceNumber.toBytesBE, "function");
      return queued.slice(0, limit);
    },
    async receiveMessages(limit) {
      assert.equal(limit, 1);
      return queued.splice(0, limit);
    },
    async completeMessage(message) { completed.push(message); },
    async abandonMessage(message) { abandoned.push(message); },
  };
  assert.equal(await purgeDeadLetters(receiver, new Date("2025-01-01T00:00:00.000Z"), 2), 1);
  assert.deepEqual(completed, [expired]);
  assert.deepEqual(abandoned, []);
});

test("dead-letter retention only peeks when no message is expired", async () => {
  let receives = 0;
  let settlements = 0;
  const receiver = {
    async peekMessages() { return [{ enqueuedTimeUtc: NOW }]; },
    async receiveMessages() { receives += 1; return []; },
    async completeMessage() { settlements += 1; },
    async abandonMessage() { settlements += 1; },
  };
  assert.equal(await purgeDeadLetters(receiver, new Date("2025-01-01T00:00:00.000Z")), 0);
  assert.equal(receives, 0);
  assert.equal(settlements, 0);
});

test("dead-letter retention revisits messages retained by an earlier sweep", async () => {
  const queued = [
    { sequenceNumber: 1, enqueuedTimeUtc: new Date("2020-01-01T00:00:00.000Z") },
    { sequenceNumber: 2, enqueuedTimeUtc: new Date("2026-01-01T00:00:00.000Z") },
  ];
  let peekCursor = 0;
  const receiver = {
    async peekMessages(limit, options = {}) {
      const from = options.fromSequenceNumber ?? peekCursor;
      const messages = queued.filter((message) => message.sequenceNumber >= from).slice(0, limit);
      if (messages.length) peekCursor = messages.at(-1).sequenceNumber + 1;
      return messages;
    },
    async receiveMessages(limit) { return queued.splice(0, limit); },
    async completeMessage() {},
    async abandonMessage() {},
  };
  assert.equal(await purgeDeadLetters(receiver, new Date("2025-01-01T00:00:00.000Z")), 1);
  assert.equal(await purgeDeadLetters(receiver, new Date("2027-01-01T00:00:00.000Z")), 1);
  assert.deepEqual(queued, []);
});

test("dead-letter retention drains multiple batches", async () => {
  const batches = [
    Array.from({ length: 3 }, () => ({ enqueuedTimeUtc: new Date("2020-01-01T00:00:00.000Z") })),
    Array.from({ length: 2 }, () => ({ enqueuedTimeUtc: new Date("2020-01-01T00:00:00.000Z") })),
  ];
  const queued = batches.flat();
  let calls = 0;
  let active = 0;
  let maxActive = 0;
  const receiver = {
    async peekMessages(limit) { return queued.slice(0, limit); },
    async receiveMessages(limit) { calls += 1; return queued.splice(0, limit); },
    async completeMessage() {
      active += 1;
      maxActive = Math.max(maxActive, active);
      await new Promise((resolve) => setTimeout(resolve, 5));
      active -= 1;
    },
    async abandonMessage() {},
  };
  assert.equal(await purgeDeadLetters(receiver, NOW, 6, { batchSize: 3, concurrency: 2 }), 5);
  assert.equal(calls, 2);
  assert.equal(maxActive, 2);
});

test("cloud retention reads each indexed target once", async () => {
  let reads = 0;
  const indexes = ["2020-01-01T00:00:00.000Z", "2020-01-02T00:00:00.000Z"].map((timestamp, index) => ({
    partitionKey: `expiry_2020010${index + 1}00`,
    rowKey: `request-1_${Date.parse(timestamp)}`,
    targetPartition: "request_tenant",
    targetRow: "request-1",
    activityAt: new Date(timestamp),
  }));
  const table = {
    listEntities() {
      return (async function* listedIndexes() { yield* indexes; })();
    },
    async getEntity() {
      reads += 1;
      return {
        partitionKey: "request_tenant",
        rowKey: "request-1",
        retentionAt: indexes[1].activityAt.toISOString(),
        etag: 'W/"1"',
      };
    },
    async deleteEntity() {},
    async submitTransaction() {},
  };
  await new AzureTableRequestStore(table).purgeBefore(NOW);
  assert.equal(reads, 1);
});

test("cloud retention batches conditional target deletes", async () => {
  const targetBatches = [];
  const indexes = Array.from({ length: 120 }, (_, index) => ({
    partitionKey: "expiry_2020010100",
    rowKey: `request-${index}_${Date.parse("2020-01-01T00:00:00.000Z")}`,
    targetPartition: "request_tenant",
    targetRow: `request-${index}`,
    activityAt: new Date("2020-01-01T00:00:00.000Z"),
  }));
  const table = {
    listEntities() {
      return (async function* listedIndexes() { yield* indexes; })();
    },
    async getEntity(partitionKey, rowKey) {
      return {
        partitionKey,
        rowKey,
        retentionAt: "2020-01-01T00:00:00.000Z",
        etag: 'W/"1"',
      };
    },
    async submitTransaction(actions) {
      if (actions[0][1].partitionKey === "request_tenant") targetBatches.push(actions);
    },
    async deleteEntity() { throw new Error("unexpected individual delete"); },
  };
  await new AzureTableRequestStore(table).purgeBefore(NOW, 50_000, 2);
  const updateBatches = targetBatches.filter((actions) => actions[0][0] === "update");
  const deleteBatches = targetBatches.filter((actions) => actions[0][0] === "delete");
  assert.deepEqual(updateBatches.map((actions) => actions.length).sort((a, b) => a - b), [20, 100]);
  assert.deepEqual(deleteBatches.map((actions) => actions.length).sort((a, b) => a - b), [20, 100]);
  assert.ok(updateBatches.flat().every((action) => action[3].etag === 'W/"1"'));
});

test("cloud retention preserves a target and its index after an etag race", async () => {
  const index = {
    partitionKey: "expiry_2020010100",
    rowKey: "request-1_1577836800000",
    targetPartition: "request_tenant",
    targetRow: "request-1",
    activityAt: new Date("2020-01-01T00:00:00.000Z"),
  };
  let target = {
    partitionKey: "request_tenant",
    rowKey: "request-1",
    retentionAt: index.activityAt.toISOString(),
    etag: 'W/"1"',
  };
  let indexDeleted = false;
  const table = {
    listEntities() { return (async function* listedIndexes() { yield index; })(); },
    async getEntity() { return { ...target }; },
    async deleteEntity(partitionKey, _rowKey, options) {
      if (partitionKey === "request_tenant") {
        target = { ...target, retentionAt: NOW.toISOString(), etag: 'W/"2"' };
        if (options?.etag !== target.etag) {
          const error = new Error("condition not met");
          error.statusCode = 412;
          throw error;
        }
        target = null;
      } else {
        indexDeleted = true;
      }
    },
    async submitTransaction(actions) {
      if (actions[0][0] === "update" && actions[0][1].partitionKey === "request_tenant") {
        target = { ...target, retentionAt: NOW.toISOString(), etag: 'W/"2"' };
        const error = new Error("condition not met");
        error.statusCode = 412;
        throw error;
      }
      for (const [, entity] of actions) {
        if (entity.partitionKey !== "request_tenant") indexDeleted = true;
      }
    },
  };
  await new AzureTableRequestStore(table).purgeBefore(NOW);
  assert.equal(target.retentionAt, NOW.toISOString());
  assert.equal(indexDeleted, false);
});

test("cloud retention scans only expired date partitions and batches deletes", async () => {
  const calls = [];
  const table = {
    async getEntity(partitionKey, rowKey) { return { partitionKey, rowKey, etag: 'W/"1"' }; },
    listEntities(options) {
      calls.push({ kind: "list", options });
      return (async function* entities() {
        for (let index = 0; index < 205; index += 1) {
          yield {
            partitionKey: index < 150 ? "expiry_2020010100" : "expiry_2020010101",
            rowKey: `row-${index}`,
            targetPartition: index < 150 ? "request_tenant" : "result_tenant",
            targetRow: `row-${index}`,
          };
        }
      })();
    },
    async deleteEntity(partitionKey, rowKey, options) {
      calls.push({ kind: "target", partitionKey, rowKey, options });
    },
    async submitTransaction(actions) { calls.push({ kind: "batch", actions }); },
  };
  const removed = await new AzureTableRequestStore(table).purgeBefore(NOW);
  assert.equal(removed, 205);
  const list = calls.find((call) => call.kind === "list");
  assert.match(list.options.queryOptions.filter, /PartitionKey lt/);
  assert.deepEqual(list.options.queryOptions.select, ["PartitionKey", "RowKey", "targetPartition", "targetRow", "activityAt"]);
  const batches = calls.filter((call) => call.kind === "batch");
  const targetUpdates = batches.filter((call) => call.actions[0][0] === "update");
  const targetDeletes = batches.filter((call) => (
    call.actions[0][0] === "delete" && !call.actions[0][1].partitionKey.startsWith("expiry_")
  ));
  const indexDeletes = batches.filter((call) => call.actions[0][1].partitionKey.startsWith("expiry_"));
  for (const group of [targetUpdates, targetDeletes, indexDeletes]) {
    assert.deepEqual(group.map((call) => call.actions.length).sort((a, b) => a - b), [50, 55, 100]);
    assert.ok(group.every((call) => new Set(call.actions.map((action) => action[1].partitionKey)).size === 1));
  }
  assert.ok(targetUpdates.flatMap((call) => call.actions).every((action) => action[3].etag === 'W/"1"'));
  assert.equal(calls.some((call) => call.kind === "target"), false);
});

test("cloud retention does not start work after its deadline", async () => {
  let listed = false;
  let deleted = false;
  const table = {
    listEntities() {
      listed = true;
      return (async function* listedIndexes() {})();
    },
    async deleteEntity() { deleted = true; },
    async submitTransaction() { deleted = true; },
  };
  const removed = await new AzureTableRequestStore(table).purgeBefore(
    NOW,
    1000,
    8,
    { deadline: Date.now() - 1 },
  );
  assert.equal(removed, 0);
  assert.equal(listed, false);
  assert.equal(deleted, false);
});
