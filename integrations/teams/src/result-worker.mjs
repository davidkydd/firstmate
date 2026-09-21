import { ContractError, sameSource, validateRequest, validateResult } from "./contracts.mjs";
import { redactReply } from "./policy.mjs";

const RESULT_CLOCK_SKEW_MILLISECONDS = 5 * 60_000;

function trustedEnqueuedTime(metadata) {
  if (!(metadata?.enqueuedTimeUtc instanceof Date)
      || Number.isNaN(metadata.enqueuedTimeUtc.getTime())) {
    throw new ContractError("malformed", "result message is missing its trusted enqueue timestamp");
  }
  return new Date(metadata.enqueuedTimeUtc);
}

function validateResultTiming(result, request, enqueuedAt) {
  const createdAt = Date.parse(result.createdAt);
  const receivedAt = Date.parse(request.receivedAt);
  const deadline = Date.parse(request.resultDeadline);
  if (enqueuedAt.getTime() >= deadline) {
    throw new ContractError("expired", "the Teams result was enqueued after its publication deadline");
  }
  if (createdAt >= deadline
      || createdAt < receivedAt - RESULT_CLOCK_SKEW_MILLISECONDS
      || createdAt > enqueuedAt.getTime() + RESULT_CLOCK_SKEW_MILLISECONDS) {
    throw new ContractError("expired", "the Teams result timestamp is outside its trusted publication window");
  }
}

export function conversationReference(source) {
  return {
    activityId: source.activityId,
    bot: { id: source.botId },
    user: { id: source.senderId, aadObjectId: source.senderAadObjectId },
    conversation: {
      id: source.conversationId,
      conversationType: source.conversationType,
      tenantId: source.tenantId,
    },
    channelId: source.channelId,
    serviceUrl: source.serviceUrl,
  };
}

export class TeamsResultWorker {
  constructor({ store, poster, allowedSenderObjectIds, allowedConversationIds, maxReplyBytes = 2500 }) {
    this.store = store;
    this.poster = poster;
    this.allowedSenderObjectIds = allowedSenderObjectIds;
    this.allowedConversationIds = allowedConversationIds;
    this.maxReplyBytes = maxReplyBytes;
    this.requestRuns = new Map();
  }

  async process(rawResult, metadata) {
    const validated = validateResult(rawResult);
    const result = validateResult({ ...validated, text: redactReply(validated.text, this.maxReplyBytes) });
    const enqueuedAt = trustedEnqueuedTime(metadata);
    const previous = this.requestRuns.get(result.requestId) || Promise.resolve();
    const run = previous.catch(() => {}).then(() => this.processResult(result, enqueuedAt));
    this.requestRuns.set(result.requestId, run);
    try {
      return await run;
    } finally {
      if (this.requestRuns.get(result.requestId) === run) this.requestRuns.delete(result.requestId);
    }
  }

  async processResult(result, enqueuedAt) {
    const requestRecord = await this.store.requestById(result.requestId, result.source.tenantId, result.source);
    const request = validateRequest(requestRecord.request);
    validateResultTiming(result, request, enqueuedAt);
    if (!sameSource(request.source, result.source)) {
      throw new Error("result source does not match the stored Teams request");
    }
    if (!(this.allowedSenderObjectIds instanceof Set) || !this.allowedSenderObjectIds.has(result.source.senderAadObjectId)) {
      throw new Error("result sender is no longer authorized");
    }
    if (!(this.allowedConversationIds instanceof Set) || !this.allowedConversationIds.has(result.source.conversationId)) {
      throw new Error("result conversation is no longer authorized");
    }
    const claim = await this.store.claimResult(result, enqueuedAt);
    if (!claim.created) {
      if (claim.status === "posted") {
        await this.store.markRequestOutcome(result);
        return { disposition: "duplicate", replyActivityId: claim.replyActivityId };
      }
      throw new Error("a previous Teams reply attempt has an uncertain outcome; refusing an automatic duplicate post");
    }
    const replyActivityId = await this.poster.post({
      reference: conversationReference(result.source),
      activity: {
        type: "message",
        text: result.text,
        replyToId: result.source.activityId,
      },
    });
    if (!replyActivityId) {
      throw new Error("Teams did not return a reply activity id");
    }
    await this.store.markResultPosted(result, replyActivityId);
    await this.store.markRequestOutcome(result);
    return { disposition: "posted", replyActivityId };
  }
}
