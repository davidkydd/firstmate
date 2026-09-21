import { randomUUID } from "node:crypto";
import { bodySha256, sameSource } from "../../src/contracts.mjs";
import {
  acknowledgementClaim,
  finalizedResult,
  requestAcknowledged,
  requestAcknowledgementError,
  requestAcknowledgementUncertain,
  requestEnqueueClaim,
  requestEnqueued,
  requestEnqueueStatus,
  requestQueueError,
  reserveResult,
  resultStateError,
} from "../../src/request-state.mjs";

export class MemoryRequestStore {
  constructor(records = new Map(), results = new Map()) {
    this.records = records;
    this.results = results;
  }

  async claimRequest(request) {
    const enqueueClaimToken = randomUUID();
    const existing = this.records.get(request.requestId);
    if (existing) {
      if (existing.request.bodySha256 !== request.bodySha256 || !sameSource(existing.request.source, request.source)) {
        throw new Error("immutable Teams activity identity was reused with different content");
      }
      const fields = requestEnqueueClaim(existing, enqueueClaimToken, new Date().toISOString());
      if (fields) Object.assign(existing, fields);
      return {
        created: false,
        status: existing.status,
        enqueueStatus: requestEnqueueStatus(existing),
        enqueueClaimed: Boolean(fields),
        enqueueClaimToken,
        request: existing.request,
      };
    }
    this.records.set(request.requestId, {
      status: "pending",
      enqueueStatus: "enqueueing",
      enqueueClaimToken,
      enqueueClaimedAt: new Date().toISOString(),
      enqueueRetryCount: 0,
      enqueueNextAttemptAt: "",
      acknowledgementStatus: "pending",
      retentionAt: request.receivedAt,
      request,
    });
    return {
      created: true,
      status: "pending",
      enqueueStatus: "enqueueing",
      enqueueClaimed: true,
      enqueueClaimToken,
      request,
    };
  }

  async claimPendingEnqueues(tenantId, limit = 500, _concurrency = 8, now = new Date()) {
    const claims = [];
    for (const value of this.records.values()) {
      if (claims.length >= limit) break;
      if (value.request.source.tenantId !== tenantId) continue;
      const enqueueClaimToken = randomUUID();
      const fields = requestEnqueueClaim(value, enqueueClaimToken, new Date(now).toISOString());
      if (!fields) continue;
      Object.assign(value, fields);
      claims.push({ request: value.request, enqueueClaimToken });
    }
    return { claims, failures: [] };
  }

  async markRequestEnqueued(requestId, _source, claimToken) {
    const value = this.records.get(requestId);
    Object.assign(value, requestEnqueued(value, claimToken) || {});
  }

  async markRequestQueueError(requestId, error, _source, claimToken) {
    const value = this.records.get(requestId);
    Object.assign(value, requestQueueError(value, claimToken, error) || {});
  }

  async claimRequestAcknowledgement(requestId) {
    const value = this.records.get(requestId);
    const acknowledgementClaimToken = randomUUID();
    const fields = acknowledgementClaim(value, acknowledgementClaimToken, new Date().toISOString());
    if (fields) Object.assign(value, fields);
    return { claimed: Boolean(fields), acknowledgementClaimToken, status: value.acknowledgementStatus };
  }

  async markRequestAcknowledged(requestId, activityId, _source, claimToken) {
    const value = this.records.get(requestId);
    Object.assign(value, requestAcknowledged(value, claimToken, activityId) || {});
  }

  async markRequestAcknowledgementError(requestId, _source, error, claimToken) {
    const value = this.records.get(requestId);
    Object.assign(value, requestAcknowledgementError(value, claimToken, error) || {});
  }

  async markRequestAcknowledgementUncertain(requestId, _source, error, claimToken) {
    const value = this.records.get(requestId);
    Object.assign(value, requestAcknowledgementUncertain(value, claimToken, error) || {});
  }

  async requestById(requestId) {
    const value = this.records.get(requestId);
    if (!value) throw new Error("request not found");
    return value;
  }

  async claimResult(result, enqueuedAt) {
    if (!(enqueuedAt instanceof Date) || Number.isNaN(enqueuedAt.getTime())) {
      throw new Error("trusted Teams result enqueue timestamp is required");
    }
    const request = this.records.get(result.requestId);
    if (!request) throw new Error("request not found");
    Object.assign(request, reserveResult(request, result, enqueuedAt.toISOString()) || {});
    const existing = this.results.get(result.resultId);
    const hash = bodySha256(JSON.stringify(result));
    if (existing) {
      if (existing.hash !== hash) throw resultStateError("result id was reused with different content", true);
      return { created: false, status: existing.status, replyActivityId: existing.replyActivityId };
    }
    this.results.set(result.resultId, { status: "posting", hash, result });
    return { created: true, status: "posting" };
  }

  async markRequestOutcome(result) {
    const value = this.records.get(result.requestId);
    if (!value) throw new Error("request not found");
    Object.assign(value, finalizedResult(value, result) || {});
  }

  async markResultPosted(result, replyActivityId) {
    const value = this.results.get(result.resultId);
    value.status = "posted";
    value.replyActivityId = replyActivityId;
  }
}
