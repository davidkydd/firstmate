const CLAIM_TIMEOUT_MS = 5 * 60_000;
const ENQUEUE_RETRY_BASE_MS = 10_000;
const ENQUEUE_RETRY_MAX_MS = 15 * 60_000;

export { CLAIM_TIMEOUT_MS };

function claimIsExpired(value, nowMilliseconds) {
  return !value || Number.isNaN(Date.parse(value)) || nowMilliseconds - Date.parse(value) > CLAIM_TIMEOUT_MS;
}

function serializedError(error) {
  return String(error?.message || error || "unknown error").slice(0, 500);
}

export function requestEnqueueStatus(current) {
  return current.enqueueStatus;
}

export function requestEnqueueClaim(current, claimToken, claimedAt) {
  const enqueueStatus = requestEnqueueStatus(current);
  const claimedAtMilliseconds = Date.parse(claimedAt);
  if (enqueueStatus === "queue-error"
      && !Number.isNaN(Date.parse(current.enqueueNextAttemptAt))
      && Date.parse(current.enqueueNextAttemptAt) > claimedAtMilliseconds) return null;
  if (enqueueStatus !== "queue-error"
      && enqueueStatus !== "pending"
      && !(enqueueStatus === "enqueueing" && claimIsExpired(current.enqueueClaimedAt, claimedAtMilliseconds))) return null;
  return {
    enqueueStatus: "enqueueing",
    enqueueClaimToken: claimToken,
    enqueueClaimedAt: claimedAt,
    enqueueNextAttemptAt: "",
    queueError: "",
  };
}

export function requestEnqueued(current, claimToken) {
  if (current.enqueueClaimToken !== claimToken || current.enqueueStatus !== "enqueueing") return null;
  return {
    status: ["result-posting", "result-terminal"].includes(current.status) ? current.status : "enqueued",
    enqueueStatus: "enqueued",
    enqueueClaimToken: "",
    enqueueNextAttemptAt: "",
    queueError: "",
  };
}

export function requestQueueError(current, claimToken, error, nowMilliseconds = Date.now()) {
  if (current.enqueueClaimToken !== claimToken || current.enqueueStatus !== "enqueueing") return null;
  const retryCount = (Number.isSafeInteger(current.enqueueRetryCount) ? current.enqueueRetryCount : 0) + 1;
  const exponentialDelay = Math.min(
    ENQUEUE_RETRY_MAX_MS,
    ENQUEUE_RETRY_BASE_MS * (2 ** Math.min(retryCount - 1, 16)),
  );
  const retryDelay = Math.floor(exponentialDelay * (0.75 + Math.random() * 0.25));
  return {
    status: ["result-posting", "result-terminal"].includes(current.status) ? current.status : "queue-error",
    enqueueStatus: "queue-error",
    enqueueClaimToken: "",
    enqueueRetryCount: retryCount,
    enqueueNextAttemptAt: new Date(nowMilliseconds + retryDelay).toISOString(),
    queueError: serializedError(error),
  };
}

export function acknowledgementClaim(current, claimToken, claimedAt) {
  const acknowledgementStatus = current.acknowledgementStatus;
  if (current.enqueueStatus !== "enqueued"
      || !["pending", "ack-error"].includes(acknowledgementStatus)) return null;
  return {
    acknowledgementStatus: "acknowledging",
    acknowledgementClaimToken: claimToken,
    acknowledgementClaimedAt: claimedAt,
    acknowledgementError: "",
  };
}

export function requestAcknowledged(current, claimToken, activityId) {
  if (current.acknowledgementClaimToken !== claimToken || current.acknowledgementStatus !== "acknowledging") return null;
  return {
    status: ["result-posting", "result-terminal"].includes(current.status) ? current.status : "acknowledged",
    acknowledgementStatus: "acknowledged",
    acknowledgementClaimToken: "",
    acknowledgementActivityId: activityId,
  };
}

export function requestAcknowledgementError(current, claimToken, error) {
  if (current.acknowledgementClaimToken !== claimToken || current.acknowledgementStatus !== "acknowledging") return null;
  return {
    acknowledgementStatus: "ack-error",
    acknowledgementClaimToken: "",
    acknowledgementError: serializedError(error),
  };
}

export function requestAcknowledgementUncertain(current, claimToken, error) {
  if (current.acknowledgementClaimToken !== claimToken || current.acknowledgementStatus !== "acknowledging") return null;
  return {
    acknowledgementStatus: "ack-uncertain",
    acknowledgementClaimToken: "",
    acknowledgementError: serializedError(error),
    acknowledgementReconciliationAt: new Date().toISOString(),
  };
}

export function resultStateError(message, permanent) {
  const error = new Error(message);
  error.permanent = permanent;
  return error;
}

function laterTimestamp(left, right) {
  if (!left || Number.isNaN(Date.parse(left))) return right;
  return Date.parse(left) >= Date.parse(right) ? left : right;
}

export function reserveResult(current, result, resultEnqueuedAt) {
  const retentionAt = laterTimestamp(current.retentionAt, resultEnqueuedAt);
  if (current.status === "result-terminal") {
    if (current.latestResultId === result.resultId) return { retentionAt };
    throw resultStateError("the Teams request already has a terminal result", true);
  }
  if (current.status === "result-posting") {
    if (current.postingResultId === result.resultId) return { retentionAt };
    if (current.postingTerminal || !result.terminal) {
      throw resultStateError("the Teams request already has a conflicting result", true);
    }
    throw resultStateError("an earlier Teams result is still being posted", false);
  }
  return {
    status: "result-posting",
    postingResultId: result.resultId,
    postingOutcome: result.outcome,
    postingTerminal: result.terminal,
    retentionAt,
  };
}

export function finalizedResult(current, result) {
  if (current.status === "result-terminal") {
    if (current.latestResultId === result.resultId) return null;
    throw resultStateError("the Teams request already has a different terminal result", true);
  }
  if (current.status === "result-posting" && current.postingResultId !== result.resultId) {
    throw resultStateError("a different Teams result owns the posting claim", true);
  }
  return {
    status: result.terminal ? "result-terminal" : "acknowledged",
    latestOutcome: result.outcome,
    latestResultId: result.resultId,
    postingResultId: "",
    postingOutcome: "",
    postingTerminal: false,
  };
}
