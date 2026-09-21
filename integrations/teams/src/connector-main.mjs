#!/usr/bin/env node
import { constants as fsConstants, read as readDescriptor } from "node:fs";
import { open } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { AzureCliCredential } from "@azure/identity";
import { ServiceBusClient } from "@azure/service-bus";
import { sourceAuthorizationFailure } from "./authorization.mjs";
import { connectorConfig } from "./config.mjs";
import { ConnectorCore } from "./connector-core.mjs";
import { makeResult, MAX_REQUEST_BYTES, MAX_RESULT_BYTES } from "./contracts.mjs";
import { FirstmateInboxAdapter, CountsStatusReader } from "./local-adapters.mjs";
import { LocalRequestStore } from "./local-store.mjs";
import { startPeriodicTask } from "./periodic-task.mjs";
import { redactReply } from "./policy.mjs";
import { parsePublishArgs } from "./publish-args.mjs";
import { closeResources, ServiceBusJsonSender, processPeekLockMessage, purgeDeadLetters } from "./service-bus.mjs";

const SOURCE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");

function usage() {
  console.error("usage: fm-teams-connector.sh serve | status | approve-request --request-id <id> --text-file <owner-only-path> | publish-result --request-id <id> --outcome completed|refused|failed --text-file <path|->");
}

function parseApprovalArgs(args) {
  const parsed = {};
  for (let index = 0; index < args.length; index += 2) {
    const option = args[index];
    const value = args[index + 1];
    if (!["--request-id", "--text-file"].includes(option) || value === undefined) {
      throw new Error("approve-request requires --request-id <id> and --text-file <owner-only-path>");
    }
    if (parsed[option.slice(2)] !== undefined) throw new Error(`${option} may be specified only once`);
    parsed[option.slice(2)] = value;
  }
  if (!/^tm_[a-f0-9]{64}$/.test(parsed["request-id"] || "")) throw new Error("invalid request id");
  if (!parsed["text-file"] || parsed["text-file"] === "-") {
    throw new Error("approve-request requires --text-file <owner-only-path>");
  }
  return parsed;
}

async function configured(home) {
  const config = await connectorConfig(home, process.env.FM_TEAMS_CONFIG);
  const credential = new AzureCliCredential({ tenantId: config.tenantId });
  const serviceBus = new ServiceBusClient(`${config.serviceBusNamespace}.servicebus.windows.net`, credential);
  return { config, serviceBus };
}

function readInto(fd, buffer, offset, length) {
  return new Promise((resolve, reject) => {
    readDescriptor(fd, buffer, offset, length, null, (error, bytesRead) => {
      if (error) reject(error);
      else resolve(bytesRead);
    });
  });
}

async function readBoundedText(file, maxBytes = MAX_RESULT_BYTES, { requirePrivate = false } = {}) {
  const handle = file === "-"
    ? null
    : await open(file, requirePrivate ? fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW : "r");
  const fd = handle?.fd ?? 0;
  const buffer = Buffer.alloc(maxBytes + 1);
  let used = 0;
  try {
    if (requirePrivate) {
      const info = await handle.stat();
      const wrongOwner = typeof process.getuid === "function" && info.uid !== process.getuid();
      if (!info.isFile() || wrongOwner || (info.mode & 0o077) !== 0) {
        throw new Error("approval text must be an owner-only regular file owned by the current user");
      }
    }
    while (used < buffer.length) {
      const bytesRead = await readInto(fd, buffer, used, buffer.length - used);
      if (bytesRead === 0) break;
      used += bytesRead;
    }
  } finally {
    await handle?.close();
  }
  if (used > maxBytes) throw new Error(`result text exceeds the ${maxBytes}-byte protocol limit`);
  return buffer.subarray(0, used).toString("utf8");
}

async function serve(home) {
  const { config, serviceBus } = await configured(home);
  const store = new LocalRequestStore(home);
  await store.ensure();
  await store.assertPrivate();
  const inbox = new FirstmateInboxAdapter({ home, root: SOURCE_ROOT });
  const deadLetterReceiver = serviceBus.createReceiver(config.requestQueue, {
    receiveMode: "peekLock",
    subQueueType: "deadLetter",
  });
  const runCorrelationRetention = async () => {
    const cutoff = new Date(Date.now() - config.retentionDays * 86_400_000);
    const deadline = Date.now() + 5 * 60_000;
    let removed;
    do {
      removed = await store.purgeBefore(cutoff, 5000, 10000, { concurrency: 8, deadline });
    } while (removed > 0 && Date.now() < deadline);
  };
  const runHandledRetention = async () => {
    const deadline = Date.now() + 5 * 60_000;
    let removed;
    do {
      removed = await inbox.purgeHandled(config.retentionDays, 5000);
    } while (removed === 5000 && Date.now() < deadline);
  };
  const runDeadLetterRetention = () => purgeDeadLetters(
    deadLetterReceiver,
    new Date(Date.now() - config.messageRetentionDays * 86_400_000),
    50_000,
    {
      batchSize: 500,
      concurrency: 16,
      maxDurationMilliseconds: 5 * 60_000,
    },
  );
  const retentionTasks = [
    ["correlation", runCorrelationRetention],
    ["handled-note", runHandledRetention],
    ["dead-letter", runDeadLetterRetention],
  ].map(([name, operation]) => startPeriodicTask({
    operation,
    intervalMilliseconds: 600_000,
    onError: (error) => console.error(
      `Firstmate Teams ${name} retention failed`,
      { message: error?.message },
    ),
  }));
  const receiver = serviceBus.createReceiver(config.requestQueue, { receiveMode: "peekLock" });
  const resultSender = new ServiceBusJsonSender(serviceBus.createSender(config.resultQueue), "firstmate.teams.result.v1");
  const core = new ConnectorCore({
    config,
    store,
    inbox,
    statusReader: new CountsStatusReader({ home, root: SOURCE_ROOT }),
    resultSender,
  });
  const subscription = receiver.subscribe({
    async processMessage(message) {
      await processPeekLockMessage(receiver, message, (body) => core.process(body));
    },
    async processError(args) {
      console.error("Firstmate Teams connector receive failed", {
        error: args.error?.message,
        entityPath: args.entityPath,
        errorSource: args.errorSource,
      });
    },
  }, { autoCompleteMessages: false, maxConcurrentCalls: 1 });
  console.log("Firstmate Teams connector is consuming requests", {
    tenantId: config.tenantId,
    requestQueue: config.requestQueue,
  });
  const signal = await new Promise((resolve) => {
    process.once("SIGTERM", () => resolve("SIGTERM"));
    process.once("SIGINT", () => resolve("SIGINT"));
  });
  console.log("Firstmate Teams connector stopping", { signal });
  for (const task of retentionTasks) task.stop();
  await Promise.all(retentionTasks.map((task) => task.join()));
  await closeResources([subscription, receiver, deadLetterReceiver, serviceBus]);
}

async function status(home) {
  const config = await connectorConfig(home, process.env.FM_TEAMS_CONFIG);
  const store = new LocalRequestStore(home);
  await store.assertPrivate();
  console.log(JSON.stringify({
    enabled: config.enabled,
    tenantId: config.tenantId,
    allowedSenderCount: config.allowedSenderObjectIds.size,
    allowedConversationCount: config.allowedConversationIds.size,
    serviceBusNamespace: config.serviceBusNamespace,
    requestQueue: config.requestQueue,
    resultQueue: config.resultQueue,
    messageRetentionDays: config.messageRetentionDays,
    stateDirectory: store.root,
  }, null, 2));
}

async function approveRequest(home, args) {
  const parsed = parseApprovalArgs(args);
  const config = await connectorConfig(home, process.env.FM_TEAMS_CONFIG);
  const store = new LocalRequestStore(home);
  await store.ensure();
  await store.assertPrivate();
  const record = await store.get(parsed["request-id"]);
  if (!record?.request) throw new Error("no local Teams request has that request id");
  if (sourceAuthorizationFailure(record.request.source, config)) {
    throw new Error("local Teams request identity is no longer authorized by configuration");
  }
  if (Date.now() >= Date.parse(record.request.resultDeadline)) {
    throw new Error("the Teams request result publication deadline has passed");
  }
  const approvedText = await readBoundedText(parsed["text-file"], MAX_REQUEST_BYTES, { requirePrivate: true });
  const approval = await store.beginApproval(record.request.requestId, approvedText);
  if (!approval.approved) {
    console.log(`already approved ${record.request.requestId} ${approval.record.approvedInboxId}`);
    return;
  }
  const inbox = new FirstmateInboxAdapter({ home, root: SOURCE_ROOT });
  const inboxId = await inbox.deliverApproved(record.request);
  await store.finishApproval(record.request.requestId, inboxId);
  console.log(`approved ${record.request.requestId} ${inboxId}`);
}

async function publishResult(home, args) {
  const parsed = parsePublishArgs(args);
  const { config, serviceBus } = await configured(home);
  try {
    const store = new LocalRequestStore(home);
    await store.ensure();
    await store.assertPrivate();
    const record = await store.get(parsed["request-id"]);
    if (!record?.request) throw new Error("no local Teams request has that request id");
    if (sourceAuthorizationFailure(record.request.source, config)) {
      throw new Error("local Teams request identity is no longer authorized by configuration");
    }
    if (record.request.command.kind === "work" && record.approvalStatus !== "approved") {
      throw new Error("Teams request requires trusted-local approval before result publication");
    }
    const text = await readBoundedText(parsed["text-file"]);
    const result = makeResult(record.request, parsed.outcome, redactReply(text, MAX_RESULT_BYTES));
    const sender = new ServiceBusJsonSender(serviceBus.createSender(config.resultQueue), "firstmate.teams.result.v1");
    const publication = await store.queueResult(result, (value) => sender.send(value));
    console.log(`${publication.queued ? "queued" : "already queued"} ${publication.result.resultId}`);
  } finally {
    await serviceBus.close();
  }
}

async function main() {
  const [command, ...args] = process.argv.slice(2);
  const home = path.resolve(process.env.FM_HOME || SOURCE_ROOT);
  if (command === "serve") return serve(home);
  if (command === "status") return status(home);
  if (command === "approve-request") return approveRequest(home, args);
  if (command === "publish-result") return publishResult(home, args);
  usage();
  process.exitCode = 2;
}

main().catch((error) => {
  console.error(`fm-teams-connector: ${error?.message || error}`);
  process.exitCode = 1;
});
