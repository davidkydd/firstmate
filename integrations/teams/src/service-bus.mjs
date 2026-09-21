import Long from "long";
import { ContractError } from "./contracts.mjs";

export async function closeResources(resources) {
  const settled = await Promise.allSettled(
    resources.filter(Boolean).map((resource) => Promise.resolve().then(() => resource.close())),
  );
  const failures = settled.filter((result) => result.status === "rejected").map((result) => result.reason);
  if (failures.length) throw new AggregateError(failures, "one or more Teams connector resources failed to close");
}

export class ServiceBusJsonSender {
  constructor(sender, subject) {
    this.sender = sender;
    this.subject = subject;
  }

  async send(value) {
    const id = value.requestId && value.resultId ? value.resultId : value.requestId;
    await this.sender.sendMessages({
      body: value,
      messageId: id,
      correlationId: value.requestId,
      subject: this.subject,
      contentType: "application/json",
      applicationProperties: {
        schema: value.schema,
        tenantId: value.source.tenantId,
      },
    });
  }
}

export async function purgeDeadLetters(receiver, cutoff, limit = 5000, {
  batchSize = 500,
  concurrency = 16,
  maxDurationMilliseconds = 60_000,
} = {}) {
  const deadline = Date.now() + maxDurationMilliseconds;
  let inspected = 0;
  let removed = 0;
  while (inspected < limit && Date.now() < deadline) {
    const requested = Math.min(batchSize, limit - inspected);
    const peeked = await receiver.peekMessages(requested, { fromSequenceNumber: Long.ZERO });
    if (peeked.length === 0) break;
    inspected += peeked.length;
    let expiredCount = 0;
    for (const message of peeked) {
      const enqueuedAt = new Date(message.enqueuedTimeUtc || 0);
      if (Number.isNaN(enqueuedAt.getTime()) || enqueuedAt >= cutoff) break;
      expiredCount += 1;
    }
    if (expiredCount === 0) break;
    const messages = await receiver.receiveMessages(expiredCount, { maxWaitTimeInMs: 1000 });
    if (messages.length === 0) break;
    let next = 0;
    let batchRemoved = 0;
    await Promise.all(Array.from({ length: Math.min(concurrency, messages.length) }, async () => {
      while (next < messages.length) {
        const message = messages[next];
        next += 1;
        const enqueuedAt = new Date(message.enqueuedTimeUtc || 0);
        if (!Number.isNaN(enqueuedAt.getTime()) && enqueuedAt < cutoff) {
          await receiver.completeMessage(message);
          batchRemoved += 1;
        } else {
          await receiver.abandonMessage(message);
        }
      }
    }));
    removed += batchRemoved;
    if (messages.length < expiredCount || batchRemoved === 0) break;
  }
  return removed;
}

export async function processPeekLockMessage(receiver, message, handler) {
  try {
    await handler(message.body, { enqueuedTimeUtc: message.enqueuedTimeUtc });
    await receiver.completeMessage(message);
  } catch (error) {
    const reason = String(error?.message || error || "processing failed").slice(0, 4000);
    if (reason.includes("uncertain outcome") || error instanceof ContractError || error?.permanent) {
      await receiver.deadLetterMessage(message, {
        deadLetterReason: reason.includes("uncertain outcome") ? "UncertainTeamsPost" : "InvalidTeamsEnvelope",
        deadLetterErrorDescription: reason,
      });
      return;
    }
    await receiver.abandonMessage(message);
    throw error;
  }
}
