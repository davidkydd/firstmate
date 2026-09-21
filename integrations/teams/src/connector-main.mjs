#!/usr/bin/env node
import { read as readDescriptor } from "node:fs";
import { open } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { AzureCliCredential } from "@azure/identity";
import { ServiceBusClient } from "@azure/service-bus";
import { sourceAuthorizationFailure } from "./authorization.mjs";
import { connectorConfig } from "./config.mjs";
import { ConnectorCore } from "./connector-core.mjs";
import { makeResult, MAX_RESULT_BYTES } from "./contracts.mjs";
import { FirstmateInboxAdapter, CountsStatusReader } from "./local-adapters.mjs";
import { LocalRequestStore } from "./local-store.mjs";
import { redactReply } from "./policy.mjs";
import { parsePublishArgs } from "./publish-args.mjs";
import { closeResources, ServiceBusJsonSender, processPeekLockMessage, purgeDeadLetters } from "./service-bus.mjs";

const SOURCE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");

function usage() {
  console.error("usage: fm-teams-connector.sh serve | status | publish-result --request-id <id> --outcome completed|refused|failed --text-file <path|->");
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

async function readBoundedText(file, maxBytes = MAX_RESULT_BYTES) {
  const handle = file === "-" ? null : await open(file, "r");
  const fd = handle?.fd ?? 0;
  const buffer = Buffer.alloc(maxBytes + 1);
  let used = 0;
  try {
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
  let retentionStopped = false;
  const retentionTasks = [];
  const scheduleRetention = (name, operation) => {
    const task = { timer: undefined, run: undefined };
    const schedule = (delayMilliseconds) => {
      task.timer = setTimeout(() => {
        task.run = operation().catch(
          (error) => console.error(`Firstmate Teams ${name} retention failed`, { message: error?.message }),
        ).finally(() => {
          task.run = undefined;
          if (!retentionStopped) schedule(600_000);
        });
      }, delayMilliseconds);
      task.timer.unref();
    };
    retentionTasks.push(task);
    schedule(0);
  };
  scheduleRetention("correlation", runCorrelationRetention);
  scheduleRetention("handled-note", runHandledRetention);
  scheduleRetention("dead-letter", runDeadLetterRetention);
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
  retentionStopped = true;
  for (const task of retentionTasks) clearTimeout(task.timer);
  await Promise.all(retentionTasks.map((task) => task.run));
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
  if (command === "publish-result") return publishResult(home, args);
  usage();
  process.exitCode = 2;
}

main().catch((error) => {
  console.error(`fm-teams-connector: ${error?.message || error}`);
  process.exitCode = 1;
});
