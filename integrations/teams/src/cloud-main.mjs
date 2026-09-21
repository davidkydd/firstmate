#!/usr/bin/env node
import express from "express";
import { unlink } from "node:fs/promises";
import { CloudAdapter, authorizeJWT } from "@microsoft/agents-hosting";
import { ManagedIdentityCredential } from "@azure/identity";
import { ServiceBusClient } from "@azure/service-bus";
import { TableClient } from "@azure/data-tables";
import { SecretClient } from "@azure/keyvault-secrets";
import { loadBotCertificate, materializeBotCertificate } from "./certificate.mjs";
import { requireChannelServiceActivity } from "./channel-auth.mjs";
import { cloudConfig } from "./config.mjs";
import { AzureTableRequestStore } from "./cloud-store.mjs";
import {
  deliveryFailureReply,
  reconcilePendingEnqueues,
  shouldSendFailureReply,
  SlidingWindowRateLimiter,
  TeamsIngress,
} from "./ingress.mjs";
import { TeamsResultWorker } from "./result-worker.mjs";
import { ServiceBusJsonSender, processPeekLockMessage, purgeDeadLetters } from "./service-bus.mjs";

function closeServer(server) {
  return new Promise((resolve) => {
    if (!server?.listening) resolve();
    else server.close(() => resolve());
  });
}

async function main() {
  const config = cloudConfig();
  const credential = new ManagedIdentityCredential(config.managedIdentityClientId);
  const secretClient = new SecretClient(config.keyVaultUrl, credential);
  const certificate = await loadBotCertificate(secretClient, config.certificateName);
  const certificateFiles = await materializeBotCertificate(certificate);
  let serviceBus;
  let resultReceiver;
  let deadLetterReceiver;
  let resultSubscription;
  let server;
  let retentionStart;
  let retentionTimer;
  let deadLetterStart;
  let deadLetterTimer;
  let enqueueRetryTimer;
  let enqueueRetryRun;
  let enqueueRetryStopped = false;
  try {
    const authConfig = {
      tenantId: config.tenantId,
      clientId: config.appId,
      authType: "CertificateSubjectName",
      certPemFile: certificateFiles.certificatePath,
      certKeyFile: certificateFiles.privateKeyPath,
      sendX5C: true,
      validateIssuer: true,
    };
    const adapter = new CloudAdapter(authConfig, undefined, undefined, { validateServiceUrl: true });
    adapter.onTurnError = async (context, error) => {
      console.error("teams-bot turn failed", {
        name: error?.name,
        code: error?.code,
        queueState: error?.queueState,
      });
      if (context?.activity?.id && shouldSendFailureReply(error)) {
        await context.sendActivity({
          type: "message",
          text: deliveryFailureReply(error),
          replyToId: context.activity.id,
        });
      }
    };

    const namespace = `${config.serviceBusNamespace}.servicebus.windows.net`;
    serviceBus = new ServiceBusClient(namespace, credential);
    const requestSender = new ServiceBusJsonSender(serviceBus.createSender(config.requestQueue), "firstmate.teams.request.v1");
    resultReceiver = serviceBus.createReceiver(config.resultQueue, { receiveMode: "peekLock" });
    deadLetterReceiver = serviceBus.createReceiver(config.resultQueue, {
      receiveMode: "peekLock",
      subQueueType: "deadLetter",
    });
    const table = new TableClient(config.tableEndpoint, config.tableName, credential);
    const store = new AzureTableRequestStore(table);
    const purgeExpiredRecords = async () => {
      const cutoff = new Date(Date.now() - config.retentionDays * 86_400_000);
      const deadline = Date.now() + 5 * 60_000;
      let removed = 0;
      let batch;
      do {
        batch = await store.purgeBefore(cutoff, 1000, 8, { deadline });
        removed += batch;
      } while (batch === 1000 && Date.now() < deadline);
      if (removed > 0) console.log("Firstmate Teams retention removed records", { count: removed });
    };
    const purgeExpiredDeadLetters = async () => {
      const cutoff = new Date(Date.now() - config.messageRetentionDays * 86_400_000);
      const removed = await purgeDeadLetters(deadLetterReceiver, cutoff, 50_000, {
        batchSize: 500,
        concurrency: 16,
        maxDurationMilliseconds: 5 * 60_000,
      });
      if (removed > 0) console.log("Firstmate Teams retention removed dead letters", { count: removed });
    };
    const ingress = new TeamsIngress({
      config,
      store,
      requestSender,
      rateLimiter: new SlidingWindowRateLimiter({ limit: config.rateLimitPerMinute }),
    });
    const scheduleEnqueueRetry = (delayMilliseconds) => {
      enqueueRetryTimer = setTimeout(() => {
        enqueueRetryRun = reconcilePendingEnqueues({
          store,
          requestSender,
          tenantId: config.tenantId,
          limit: 500,
          concurrency: 8,
        }).then(({ enqueued, failed }) => {
          if (enqueued > 0 || failed > 0) {
            console.log("Firstmate Teams request queue reconciliation completed", { enqueued, failed });
          }
        }).catch(
          (error) => console.error("Firstmate Teams request queue reconciliation failed", { message: error?.message }),
        ).finally(() => {
          enqueueRetryRun = undefined;
          if (!enqueueRetryStopped) scheduleEnqueueRetry(10_000);
        });
      }, delayMilliseconds);
      enqueueRetryTimer.unref();
    };
    scheduleEnqueueRetry(0);
    const resultWorker = new TeamsResultWorker({
      store,
      allowedSenderObjectIds: config.allowedSenderObjectIds,
      allowedConversationIds: config.allowedConversationIds,
      maxReplyBytes: config.maxReplyBytes,
      poster: {
        async post({ reference, activity }) {
          let replyId = "";
          await adapter.continueConversation(config.appId, reference, async (context) => {
            const receipt = await context.sendActivity(activity);
            replyId = receipt?.id || "";
          });
          return replyId;
        },
      },
    });

    resultSubscription = resultReceiver.subscribe({
      async processMessage(message) {
        await processPeekLockMessage(resultReceiver, message, (body, metadata) => resultWorker.process(body, metadata));
      },
      async processError(args) {
        console.error("teams-result receiver failed", {
          error: args.error?.message,
          entityPath: args.entityPath,
          errorSource: args.errorSource,
        });
      },
    }, { autoCompleteMessages: false, maxConcurrentCalls: 8 });

    const app = express();
    app.disable("x-powered-by");
    app.get("/healthz", (_request, response) => response.status(200).json({ status: "ok" }));
    app.use(authorizeJWT(authConfig));
    app.use(express.json({ limit: "64kb", type: "application/json" }));
    app.post("/api/messages", requireChannelServiceActivity, async (request, response) => {
      await adapter.process(request, response, (context) => ingress.handle(context));
    });
    server = app.listen(config.port, "0.0.0.0", () => {
      console.log("Firstmate Teams bot listening", {
        port: config.port,
        tenantId: config.tenantId,
        certificateVersion: certificate.version,
      });
    });
    const reportRetention = () => purgeExpiredRecords().catch(
      (error) => console.error("Firstmate Teams retention failed", { message: error?.message }),
    );
    const reportDeadLetterRetention = () => purgeExpiredDeadLetters().catch(
      (error) => console.error("Firstmate Teams dead-letter retention failed", { message: error?.message }),
    );
    retentionStart = setTimeout(reportRetention, 0);
    retentionTimer = setInterval(reportRetention, 3_600_000);
    deadLetterStart = setTimeout(reportDeadLetterRetention, 0);
    deadLetterTimer = setInterval(reportDeadLetterRetention, 600_000);
    retentionStart.unref();
    retentionTimer.unref();
    deadLetterStart.unref();
    deadLetterTimer.unref();

    await new Promise((resolve, reject) => {
      process.once("SIGTERM", () => {
        console.log("Firstmate Teams bot stopping", { signal: "SIGTERM" });
        resolve();
      });
      process.once("SIGINT", () => {
        console.log("Firstmate Teams bot stopping", { signal: "SIGINT" });
        resolve();
      });
      server.once("error", reject);
    });
  } finally {
    enqueueRetryStopped = true;
    clearTimeout(enqueueRetryTimer);
    clearTimeout(retentionStart);
    clearInterval(retentionTimer);
    clearTimeout(deadLetterStart);
    clearInterval(deadLetterTimer);
    await enqueueRetryRun;
    await resultSubscription?.close().catch(() => {});
    await Promise.allSettled([
      closeServer(server),
      resultReceiver?.close(),
      deadLetterReceiver?.close(),
      serviceBus?.close(),
    ]);
    await Promise.allSettled([
      unlink(certificateFiles.certificatePath),
      unlink(certificateFiles.privateKeyPath),
    ]);
  }
}

main().catch((error) => {
  console.error("Firstmate Teams bot failed to start", { name: error?.name, message: error?.message });
  process.exitCode = 1;
});
