import { canonicalGuid, IgnoredActivity, parseTeamsActivity, replyActivity } from "./activity.mjs";
import { sourceAuthorizationFailure } from "./authorization.mjs";
import { bodySha256, ContractError } from "./contracts.mjs";

export class TeamsDeliveryError extends Error {
  constructor(error, queueState, { suppressFallbackReply = false } = {}) {
    super(String(error?.message || error || "Teams delivery failed"), { cause: error });
    this.name = "TeamsDeliveryError";
    this.queueState = queueState;
    this.suppressFallbackReply = suppressFallbackReply;
  }
}

export function shouldSendFailureReply(error) {
  return error?.suppressFallbackReply !== true;
}

export function deliveryFailureReply(error) {
  if (error?.queueState === "not-queued") {
    return "The request was not queued. Retrying the same request is safe.";
  }
  if (error?.queueState === "accepted") {
    return "The request was queued, but its confirmation failed. Do not resend it; await the result.";
  }
  if (error?.queueState === "uncertain") {
    return "The request's queue status could not be confirmed. Do not resend it; await reconciliation or contact the Firstmate operator.";
  }
  return "The request could not be processed. Try again later.";
}

export class AuthenticationConcurrencyLimiter {
  constructor({ concurrency = 16 }) {
    this.concurrency = concurrency;
    this.active = 0;
  }

  acquire() {
    if (this.active >= this.concurrency) return null;
    this.active += 1;
    let active = true;
    return () => {
      if (!active) return;
      active = false;
      this.active -= 1;
    };
  }
}

export class AuthorizedTrafficRateLimiter {
  constructor({ limit, windowMilliseconds = 60_000 }) {
    this.limit = limit;
    this.windowMilliseconds = windowMilliseconds;
    this.events = [];
    this.eventHead = 0;
  }

  take(nowMilliseconds = Date.now()) {
    const cutoff = nowMilliseconds - this.windowMilliseconds;
    while (this.eventHead < this.events.length && this.events[this.eventHead] <= cutoff) {
      this.eventHead += 1;
    }
    if (this.events.length - this.eventHead >= this.limit) return false;
    this.events.push(nowMilliseconds);
    if (this.eventHead > 64 && this.eventHead * 2 >= this.events.length) {
      this.events = this.events.slice(this.eventHead);
      this.eventHead = 0;
    }
    return true;
  }
}

export class SlidingWindowRateLimiter {
  constructor({ limit, windowMilliseconds = 60_000, duplicateLimit = Math.max(3, limit) }) {
    this.limit = limit;
    this.duplicateLimit = duplicateLimit;
    this.windowMilliseconds = windowMilliseconds;
    this.events = new Map();
    this.duplicateEvents = new Map();
    this.notifications = new Map();
  }

  take(key, itemId, nowMilliseconds = Date.now()) {
    const cutoff = nowMilliseconds - this.windowMilliseconds;
    const recent = (this.events.get(key) || []).filter((event) => event.at > cutoff);
    if (recent.some((event) => event.itemId === itemId)) {
      const duplicates = (this.duplicateEvents.get(key) || []).filter((event) => event.at > cutoff);
      if (duplicates.length >= this.duplicateLimit) {
        this.events.set(key, recent);
        this.duplicateEvents.set(key, duplicates);
        return false;
      }
      duplicates.push({ at: nowMilliseconds, itemId });
      this.events.set(key, recent);
      this.duplicateEvents.set(key, duplicates);
      return true;
    }
    if (recent.length >= this.limit) {
      this.events.set(key, recent);
      return false;
    }
    recent.push({ at: nowMilliseconds, itemId });
    this.events.set(key, recent);
    return true;
  }

  shouldNotify(key, nowMilliseconds = Date.now()) {
    const lastNotification = this.notifications.get(key);
    if (lastNotification !== undefined && lastNotification > nowMilliseconds - this.windowMilliseconds) return false;
    this.notifications.set(key, nowMilliseconds);
    return true;
  }
}

export async function reconcilePendingEnqueues({
  store,
  requestSender,
  tenantId,
  limit = 500,
  concurrency = 8,
  now = new Date(),
}) {
  const claimResult = await store.claimPendingEnqueues(tenantId, limit, concurrency, now);
  const claims = claimResult.claims;
  let next = 0;
  let enqueued = 0;
  let failed = claimResult.failures.length;
  const workers = Array.from({ length: Math.min(concurrency, claims.length) }, async () => {
    while (next < claims.length) {
      const claim = claims[next];
      next += 1;
      const { request, enqueueClaimToken } = claim;
      try {
        await requestSender.send(request);
      } catch (error) {
        failed += 1;
        await store.markRequestQueueError(
          request.requestId,
          request.source.tenantId,
          error,
          request.source,
          enqueueClaimToken,
        ).catch(() => {});
        continue;
      }
      try {
        await store.markRequestEnqueued(
          request.requestId,
          request.source.tenantId,
          request.source,
          enqueueClaimToken,
        );
        enqueued += 1;
      } catch {
        failed += 1;
      }
    }
  });
  const workerResults = await Promise.allSettled(workers);
  failed += workerResults.filter((result) => result.status === "rejected").length;
  return { claimed: claims.length, enqueued, failed };
}

export class TeamsIngress {
  constructor({ config, store, requestSender, rateLimiter, authorizedRateLimiter }) {
    this.config = config;
    this.store = store;
    this.requestSender = requestSender;
    this.rateLimiter = rateLimiter;
    this.authorizedRateLimiter = authorizedRateLimiter;
  }

  async handle(context, now = new Date()) {
    const rawConversationTenant = context.activity?.conversation?.tenantId;
    const rawChannelTenant = context.activity?.channelData?.tenant?.id;
    const conversationTenant = canonicalGuid(rawConversationTenant);
    const channelTenant = canonicalGuid(rawChannelTenant);
    const candidateTenant = conversationTenant || channelTenant;
    const candidateSender = canonicalGuid(context.activity?.from?.aadObjectId);
    const candidateConversation = context.activity?.conversation?.id;
    const sourceAuthorized = context.activity?.type === "message"
      && context.activity?.channelId === "msteams"
      && context.activity?.recipient?.id === this.config.botId
      && typeof context.activity?.from?.id === "string"
      && context.activity.from.id !== this.config.botId
      && context.activity.from.id !== context.activity.recipient.id
      && (rawConversationTenant === undefined || conversationTenant === candidateTenant)
      && (rawChannelTenant === undefined || channelTenant === candidateTenant)
      && sourceAuthorizationFailure({
        tenantId: candidateTenant,
        senderAadObjectId: candidateSender,
        conversationId: candidateConversation,
      }, this.config) === null;
    if (sourceAuthorized) {
      const rateKey = `${candidateTenant}:${candidateSender}`;
      const itemId = String(context.activity?.id || `missing_${bodySha256(String(context.activity?.text || ""))}`);
      const senderAllowed = this.rateLimiter.take(rateKey, itemId, now.getTime());
      const globallyAllowed = senderAllowed
        && (!this.authorizedRateLimiter || this.authorizedRateLimiter.take(now.getTime()));
      if (!senderAllowed || !globallyAllowed) {
        if (this.rateLimiter.shouldNotify(rateKey, now.getTime())) {
          await context.sendActivity(replyActivity(context.activity?.id, "Request refused: the Teams intake rate limit was reached. Try again later."));
        }
        return { disposition: "throttled" };
      }
    }

    let request;
    try {
      request = parseTeamsActivity(context.activity, this.config, now);
    } catch (error) {
      if (error instanceof IgnoredActivity) return { disposition: "ignored", reason: error.message };
      if (error instanceof ContractError) {
        if (sourceAuthorized && error.code !== "identity") {
          await context.sendActivity(replyActivity(context.activity?.id, `Request refused: ${error.message}.`));
        }
        return { disposition: "refused", reason: error.code };
      }
      throw error;
    }

    let claim;
    try {
      claim = await this.store.claimRequest(request);
    } catch (error) {
      throw new TeamsDeliveryError(error, "not-queued");
    }
    request = claim.request;
    let enqueueStatus = claim.enqueueStatus;
    if (claim.enqueueClaimed) {
      try {
        await this.requestSender.send(request);
      } catch (error) {
        await this.store.markRequestQueueError(
          request.requestId,
          request.source.tenantId,
          error,
          request.source,
          claim.enqueueClaimToken,
        ).catch(() => {});
        throw new TeamsDeliveryError(error, "uncertain");
      }
      try {
        await this.store.markRequestEnqueued(
          request.requestId,
          request.source.tenantId,
          request.source,
          claim.enqueueClaimToken,
        );
      } catch (error) {
        throw new TeamsDeliveryError(error, "accepted");
      }
      enqueueStatus = "enqueued";
    } else if (enqueueStatus !== "enqueued") {
      try {
        for (const delay of [10, 25, 50, 100]) {
          await new Promise((resolve) => setTimeout(resolve, delay));
          const current = await this.store.requestById(request.requestId, request.source.tenantId, request.source);
          enqueueStatus = current.enqueueStatus
            || (["pending", "queue-error", "enqueueing"].includes(current.status) ? current.status : "enqueued");
          if (enqueueStatus === "enqueued" || enqueueStatus === "queue-error") break;
        }
      } catch (error) {
        throw new TeamsDeliveryError(error, "uncertain");
      }
      if (enqueueStatus !== "enqueued") {
        throw new TeamsDeliveryError(
          new Error("the Teams request is not yet durably queued; retry delivery"),
          "uncertain",
        );
      }
    }
    let acknowledgement;
    try {
      acknowledgement = await this.store.claimRequestAcknowledgement(request.requestId, request.source);
    } catch (error) {
      throw new TeamsDeliveryError(error, "accepted");
    }
    if (!acknowledgement.claimed) {
      return {
        disposition: acknowledgement.status === "ack-uncertain" ? "acknowledgement-uncertain" : "duplicate",
        requestId: request.requestId,
      };
    }
    let pendingReceipt;
    try {
      pendingReceipt = context.sendActivity(
        replyActivity(request.source.activityId, `Request ${request.requestId.slice(0, 11)} was stored for Firstmate.`),
      );
    } catch (error) {
      await this.store.markRequestAcknowledgementError(
        request.requestId,
        request.source,
        error,
        acknowledgement.acknowledgementClaimToken,
      ).catch(() => {});
      throw new TeamsDeliveryError(error, "accepted");
    }
    let receipt;
    try {
      receipt = await pendingReceipt;
    } catch (error) {
      await this.store.markRequestAcknowledgementUncertain(
        request.requestId,
        request.source,
        error,
        acknowledgement.acknowledgementClaimToken,
      ).catch(() => {});
      throw new TeamsDeliveryError(error, "accepted", { suppressFallbackReply: true });
    }
    try {
      await this.store.markRequestAcknowledged(
        request.requestId,
        request.source.tenantId,
        receipt?.id || "unrecorded",
        request.source,
        acknowledgement.acknowledgementClaimToken,
      );
    } catch {
      return { disposition: "acknowledgement-uncertain", requestId: request.requestId };
    }
    return { disposition: claim.enqueueClaimed ? "enqueued" : "acknowledged", requestId: request.requestId };
  }
}
