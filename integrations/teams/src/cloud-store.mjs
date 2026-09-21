import { randomUUID } from "node:crypto";
import { bodySha256, sameSource } from "./contracts.mjs";

const CLAIM_TIMEOUT_MS = 5 * 60_000;
const ENQUEUE_RETRY_BASE_MS = 10_000;
const ENQUEUE_RETRY_MAX_MS = 15 * 60_000;

function claimIsExpired(value, nowMilliseconds) {
  return !value || Number.isNaN(Date.parse(value)) || nowMilliseconds - Date.parse(value) > CLAIM_TIMEOUT_MS;
}

function serializedError(error) {
  return String(error?.message || error || "unknown error").slice(0, 500);
}

async function runConcurrent(items, concurrency, worker, shouldContinue = () => true) {
  let next = 0;
  const failures = [];
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (next < items.length && shouldContinue()) {
      const item = items[next];
      next += 1;
      try {
        await worker(item);
      } catch (error) {
        failures.push({ item, error });
      }
    }
  }));
  return failures;
}

function retentionBucket(timestamp) {
  if (!timestamp || Number.isNaN(Date.parse(timestamp))) {
    throw new Error("Teams record is missing its retention timestamp");
  }
  return timestamp.replace(/[-:T]/g, "").slice(0, 10);
}

function requestPartition(tenantId) {
  return `request_${tenantId}`;
}

function enqueueTimestamp(timestamp) {
  const milliseconds = new Date(timestamp).getTime();
  if (!Number.isSafeInteger(milliseconds) || milliseconds < 0) return "000000000000000";
  return String(milliseconds).padStart(15, "0");
}

function enqueueIndex(requestId, tenantId, nextAttemptAt) {
  const candidate = new Date(nextAttemptAt);
  const dueAt = Number.isSafeInteger(candidate.getTime()) && candidate.getTime() >= 0 ? candidate : new Date(0);
  return {
    partitionKey: requestPartition(tenantId),
    rowKey: `enqueue_${enqueueTimestamp(dueAt)}_${requestId}`,
    targetRow: requestId,
    nextAttemptAt: dueAt,
  };
}

function enqueueIndexForRecord(current, requestId, tenantId) {
  const status = requestEnqueueStatus(current);
  if (status === "queue-error") {
    return enqueueIndex(requestId, tenantId, current.enqueueNextAttemptAt);
  }
  if (status === "pending") return enqueueIndex(requestId, tenantId, 0);
  if (status === "enqueueing") {
    return enqueueIndex(requestId, tenantId, Date.parse(current.enqueueClaimedAt || 0) + CLAIM_TIMEOUT_MS);
  }
  return null;
}

function resultPartition(tenantId) {
  return `result_${tenantId}`;
}

function retentionIndex(timestamp, targetRow, targetPartition) {
  return {
    partitionKey: `expiry_${retentionBucket(timestamp)}`,
    rowKey: `${targetRow}_${Date.parse(timestamp)}`,
    targetPartition,
    targetRow,
    activityAt: new Date(timestamp),
  };
}

function requestEnqueueStatus(current) {
  return current.enqueueStatus;
}

function requestEnqueueClaim(current, claimToken, claimedAt) {
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

function requestEnqueued(current, claimToken) {
  if (current.enqueueClaimToken !== claimToken || current.enqueueStatus !== "enqueueing") return null;
  return {
    status: ["result-posting", "result-terminal"].includes(current.status) ? current.status : "enqueued",
    enqueueStatus: "enqueued",
    enqueueClaimToken: "",
    enqueueNextAttemptAt: "",
    queueError: "",
  };
}

function requestQueueError(current, claimToken, error, nowMilliseconds = Date.now()) {
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

function acknowledgementClaim(current, claimToken, claimedAt) {
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

function requestAcknowledged(current, claimToken, activityId) {
  if (current.acknowledgementClaimToken !== claimToken || current.acknowledgementStatus !== "acknowledging") return null;
  return {
    status: ["result-posting", "result-terminal"].includes(current.status) ? current.status : "acknowledged",
    acknowledgementStatus: "acknowledged",
    acknowledgementClaimToken: "",
    acknowledgementActivityId: activityId,
  };
}

function requestAcknowledgementError(current, claimToken, error) {
  if (current.acknowledgementClaimToken !== claimToken || current.acknowledgementStatus !== "acknowledging") return null;
  return {
    acknowledgementStatus: "ack-error",
    acknowledgementClaimToken: "",
    acknowledgementError: serializedError(error),
  };
}

function requestAcknowledgementUncertain(current, claimToken, error) {
  if (current.acknowledgementClaimToken !== claimToken || current.acknowledgementStatus !== "acknowledging") return null;
  return {
    acknowledgementStatus: "ack-uncertain",
    acknowledgementClaimToken: "",
    acknowledgementError: serializedError(error),
    acknowledgementReconciliationAt: new Date().toISOString(),
  };
}

function resultStateError(message, permanent) {
  const error = new Error(message);
  error.permanent = permanent;
  return error;
}

function laterTimestamp(left, right) {
  if (!left || Number.isNaN(Date.parse(left))) return right;
  return Date.parse(left) >= Date.parse(right) ? left : right;
}

function reserveResult(current, result, resultEnqueuedAt) {
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

function finalizedResult(current, result) {
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

export class AzureTableRequestStore {
  constructor(tableClient) {
    this.table = tableClient;
  }

  async ensureRetentionIndex(timestamp, rowKey, targetPartition) {
    const entity = retentionIndex(timestamp, rowKey, targetPartition);
    try {
      await this.table.createEntity(entity);
      return { created: true, entity };
    } catch (error) {
      if (error?.statusCode !== 409) throw error;
      return { created: false, entity };
    }
  }

  async claimRequest(request) {
    const partitionKey = requestPartition(request.source.tenantId);
    const retention = await this.ensureRetentionIndex(request.receivedAt, request.requestId, partitionKey);
    const enqueueClaimToken = randomUUID();
    const entity = {
      partitionKey,
      rowKey: request.requestId,
      status: "pending",
      enqueueStatus: "enqueueing",
      enqueueClaimToken,
      enqueueClaimedAt: new Date().toISOString(),
      enqueueRetryCount: 0,
      enqueueNextAttemptAt: "",
      acknowledgementStatus: "pending",
      retentionAt: request.receivedAt,
      requestJson: JSON.stringify(request),
      bodySha256: request.bodySha256,
      activityAt: new Date(request.source.activityTimestamp),
      updatedAt: new Date().toISOString(),
    };
    const retryIndex = enqueueIndex(
      request.requestId,
      request.source.tenantId,
      Date.parse(entity.enqueueClaimedAt) + CLAIM_TIMEOUT_MS,
    );
    try {
      await this.table.submitTransaction([
        ["create", entity],
        ["create", retryIndex],
      ]);
      return {
        created: true,
        status: entity.status,
        enqueueStatus: entity.enqueueStatus,
        enqueueClaimed: true,
        enqueueClaimToken,
        request,
      };
    } catch (error) {
      if (error?.statusCode !== 409) throw error;
      const existing = await this.table.getEntity(entity.partitionKey, entity.rowKey);
      const stored = JSON.parse(existing.requestJson);
      const storedRetention = retentionIndex(stored.receivedAt, request.requestId, partitionKey);
      if (retention.created
          && (storedRetention.partitionKey !== retention.entity.partitionKey
            || storedRetention.rowKey !== retention.entity.rowKey)) {
        await this.table.deleteEntity(retention.entity.partitionKey, retention.entity.rowKey).catch(() => {});
      }
      if (stored.bodySha256 !== request.bodySha256 || !sameSource(stored.source, request.source)) {
        throw new Error("immutable Teams activity identity was reused with different content");
      }
      let claimed = existing;
      if (requestEnqueueStatus(existing) !== "enqueued") {
        const existingRetryIndex = enqueueIndexForRecord(existing, request.requestId, request.source.tenantId);
        try {
          await this.table.createEntity(existingRetryIndex);
        } catch (indexError) {
          if (indexError?.statusCode !== 409) throw indexError;
        }
        claimed = await this.transitionEnqueueRequest(request.requestId, request.source, (current) => (
          requestEnqueueClaim(current, enqueueClaimToken, new Date().toISOString())
        ));
      }
      return {
        created: false,
        status: claimed.status,
        enqueueStatus: requestEnqueueStatus(claimed),
        enqueueClaimed: claimed.enqueueClaimToken === enqueueClaimToken,
        enqueueClaimToken,
        request: stored,
      };
    }
  }

  async transitionRequest(requestId, source, transition) {
    const partitionKey = requestPartition(source.tenantId);
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const current = await this.table.getEntity(partitionKey, requestId);
      if (current.retentionDeleteToken) throw Object.assign(new Error("Teams request is being expired"), { statusCode: 404 });
      const fields = transition(current);
      if (!fields) return current;
      try {
        const updated = {
          partitionKey,
          rowKey: requestId,
          ...fields,
          updatedAt: new Date().toISOString(),
        };
        await this.table.updateEntity(updated, "Merge", { etag: current.etag });
        return { ...current, ...updated };
      } catch (error) {
        if (error?.statusCode !== 412 || attempt === 4) throw error;
      }
    }
    throw new Error("could not update the Teams request state");
  }

  async transitionEnqueueRequest(requestId, source, transition) {
    const tenantId = source.tenantId;
    const partitionKey = requestPartition(tenantId);
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const current = await this.table.getEntity(partitionKey, requestId);
      if (current.retentionDeleteToken) throw Object.assign(new Error("Teams request is being expired"), { statusCode: 404 });
      const fields = transition(current);
      if (!fields) return current;
      const updated = {
        partitionKey,
        rowKey: requestId,
        ...fields,
        updatedAt: new Date().toISOString(),
      };
      const previousIndex = enqueueIndexForRecord(current, requestId, tenantId);
      const next = { ...current, ...updated };
      const nextIndex = enqueueIndexForRecord(next, requestId, tenantId);
      const actions = [["update", updated, "Merge", { etag: current.etag }]];
      if (previousIndex && previousIndex.rowKey !== nextIndex?.rowKey) {
        actions.push(["delete", previousIndex]);
      }
      if (nextIndex && previousIndex?.rowKey !== nextIndex.rowKey) {
        actions.push(["upsert", nextIndex, "Merge"]);
      }
      try {
        await this.table.submitTransaction(actions);
        return next;
      } catch (error) {
        if (error?.statusCode === 404 && previousIndex) {
          try {
            await this.table.createEntity(previousIndex);
          } catch (createError) {
            if (createError?.statusCode !== 409) throw createError;
          }
          continue;
        }
        if (error?.statusCode !== 412 || attempt === 4) throw error;
      }
    }
    throw new Error("could not update the Teams enqueue state");
  }

  async requestById(requestId, tenantId) {
    const entity = await this.table.getEntity(requestPartition(tenantId), requestId);
    return { ...entity, request: JSON.parse(entity.requestJson) };
  }

  async claimPendingEnqueues(tenantId, limit = 500, concurrency = 8, now = new Date()) {
    const partitionKey = requestPartition(tenantId);
    const claimedAt = new Date(now);
    const dueUpperBound = enqueueTimestamp(claimedAt.getTime() + 1);
    const candidates = [];
    const candidateKeys = new Set();
    const collect = async (filter) => {
      for await (const entity of this.table.listEntities({
        queryOptions: {
          filter,
          select: ["PartitionKey", "RowKey", "targetRow"],
        },
      })) {
        const key = `${entity.partitionKey}\u0000${entity.rowKey}`;
        if (!candidateKeys.has(key)) {
          candidateKeys.add(key);
          candidates.push(entity);
        }
        if (candidates.length >= limit) break;
      }
    };
    await collect(`PartitionKey eq '${partitionKey}' and RowKey ge 'enqueue_000000000000000_' and RowKey lt 'enqueue_${dueUpperBound}_'`);
    const claims = [];
    const failures = await runConcurrent(candidates, concurrency, async (candidate) => {
      const enqueueClaimToken = randomUUID();
      let claimed;
      try {
        claimed = await this.transitionEnqueueRequest(candidate.targetRow, { tenantId }, (current) => (
          requestEnqueueClaim(current, enqueueClaimToken, claimedAt.toISOString())
        ));
      } catch (error) {
        if (error?.statusCode !== 404) throw error;
        await this.table.deleteEntity(candidate.partitionKey, candidate.rowKey).catch((deleteError) => {
          if (deleteError?.statusCode !== 404) throw deleteError;
        });
        return;
      }
      if (claimed.enqueueClaimToken === enqueueClaimToken) {
        claims.push({
          request: JSON.parse(claimed.requestJson),
          enqueueClaimToken,
        });
      }
      const activeIndex = enqueueIndexForRecord(claimed, candidate.targetRow, tenantId);
      if (candidate.rowKey !== activeIndex?.rowKey) {
        if (activeIndex) {
          await this.table.createEntity(activeIndex).catch((error) => {
            if (error?.statusCode !== 409) throw error;
          });
        }
        await this.table.deleteEntity(candidate.partitionKey, candidate.rowKey).catch((error) => {
          if (error?.statusCode !== 404) throw error;
        });
      }
    });
    return { claims, failures };
  }

  async markRequestEnqueued(requestId, _tenantId, source, claimToken) {
    await this.transitionEnqueueRequest(requestId, source, (current) => requestEnqueued(current, claimToken));
  }

  async markRequestQueueError(requestId, _tenantId, error, source, claimToken) {
    await this.transitionEnqueueRequest(
      requestId,
      source,
      (current) => requestQueueError(current, claimToken, error),
    );
  }

  async claimRequestAcknowledgement(requestId, source) {
    const acknowledgementClaimToken = randomUUID();
    const claimed = await this.transitionRequest(requestId, source, (current) => (
      acknowledgementClaim(current, acknowledgementClaimToken, new Date().toISOString())
    ));
    return {
      claimed: claimed.acknowledgementClaimToken === acknowledgementClaimToken,
      acknowledgementClaimToken,
      status: claimed.acknowledgementStatus,
    };
  }

  async markRequestAcknowledged(requestId, _tenantId, activityId, source, claimToken) {
    await this.transitionRequest(requestId, source, (current) => requestAcknowledged(current, claimToken, activityId));
  }

  async markRequestAcknowledgementError(requestId, source, error, claimToken) {
    await this.transitionRequest(requestId, source, (current) => requestAcknowledgementError(current, claimToken, error));
  }

  async markRequestAcknowledgementUncertain(requestId, source, error, claimToken) {
    await this.transitionRequest(requestId, source, (current) => requestAcknowledgementUncertain(current, claimToken, error));
  }

  async claimResult(result, enqueuedAt) {
    if (!(enqueuedAt instanceof Date) || Number.isNaN(enqueuedAt.getTime())) {
      throw new Error("trusted Teams result enqueue timestamp is required");
    }
    const resultEnqueuedAt = enqueuedAt.toISOString();
    const requestPartitionKey = requestPartition(result.source.tenantId);
    await this.ensureRetentionIndex(resultEnqueuedAt, result.requestId, requestPartitionKey);
    const request = await this.transitionRequest(
      result.requestId,
      result.source,
      (current) => reserveResult(current, result, resultEnqueuedAt),
    );
    if (request.retentionAt !== resultEnqueuedAt) {
      await this.ensureRetentionIndex(request.retentionAt, result.requestId, requestPartitionKey);
    }
    const partitionKey = resultPartition(result.source.tenantId);
    await this.ensureRetentionIndex(resultEnqueuedAt, result.resultId, partitionKey);
    const entity = {
      partitionKey,
      rowKey: result.resultId,
      status: "posting",
      requestId: result.requestId,
      resultHash: bodySha256(JSON.stringify(result)),
      resultJson: JSON.stringify(result),
      retentionAt: resultEnqueuedAt,
      activityAt: enqueuedAt,
      updatedAt: new Date().toISOString(),
    };
    try {
      await this.table.createEntity(entity);
      return { created: true, status: "posting" };
    } catch (error) {
      if (error?.statusCode !== 409) throw error;
      const existing = await this.table.getEntity(entity.partitionKey, entity.rowKey);
      if (existing.resultHash !== entity.resultHash) {
        throw resultStateError("result id was reused with different content", true);
      }
      return { created: false, status: existing.status, replyActivityId: existing.replyActivityId };
    }
  }

  async markRequestOutcome(result) {
    await this.transitionRequest(result.requestId, result.source, (current) => finalizedResult(current, result));
  }

  async markResultPosted(result, replyActivityId) {
    const partitionKey = resultPartition(result.source.tenantId);
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const current = await this.table.getEntity(partitionKey, result.resultId);
      if (current.retentionDeleteToken) throw Object.assign(new Error("Teams result is being expired"), { statusCode: 404 });
      try {
        await this.table.updateEntity(
          {
            partitionKey,
            rowKey: result.resultId,
            status: "posted",
            replyActivityId,
            updatedAt: new Date().toISOString(),
          },
          "Merge",
          { etag: current.etag },
        );
        return;
      } catch (error) {
        if (error?.statusCode !== 412 || attempt === 4) throw error;
      }
    }
  }

  async purgeBefore(cutoff, limit = 50_000, concurrency = 8, { deadline = Infinity } = {}) {
    const beforeDeadline = () => Date.now() < deadline;
    const bucket = `expiry_${cutoff.toISOString().replace(/[-:T]/g, "").slice(0, 10)}`;
    const filter = `PartitionKey ge 'expiry_' and (PartitionKey lt '${bucket}' or (PartitionKey eq '${bucket}' and activityAt lt datetime'${cutoff.toISOString()}'))`;
    const indexes = [];
    if (beforeDeadline()) {
      for await (const entity of this.table.listEntities({
        queryOptions: {
          filter,
          select: ["PartitionKey", "RowKey", "targetPartition", "targetRow", "activityAt"],
        },
      })) {
        if (!beforeDeadline()) break;
        indexes.push(entity);
        if (indexes.length >= limit) break;
      }
    }
    const batchesFor = (items, keyFor) => {
      const grouped = new Map();
      const batches = [];
      for (const item of items) {
        const entity = keyFor(item);
        const batch = grouped.get(entity.partitionKey) || [];
        batch.push({ item, entity });
        grouped.set(entity.partitionKey, batch);
        if (batch.length === 100) {
          batches.push(batch);
          grouped.set(entity.partitionKey, []);
        }
      }
      for (const batch of grouped.values()) {
        if (batch.length) batches.push(batch);
      }
      return batches;
    };
    const indexesByTarget = new Map();
    for (const index of indexes) {
      const targetKey = `${index.targetPartition}\u0000${index.targetRow}`;
      const group = indexesByTarget.get(targetKey) || [];
      group.push(index);
      indexesByTarget.set(targetKey, group);
    }

    const activeByTarget = new Map();
    const indexesToDelete = [];
    const failures = [];
    const targetGroups = [...indexesByTarget.entries()];
    failures.push(...await runConcurrent(targetGroups, concurrency, async ([targetKey, targetIndexes]) => {
      let target;
      try {
        const [{ targetPartition, targetRow }] = targetIndexes;
        target = await this.table.getEntity(targetPartition, targetRow);
      } catch (error) {
        if (error?.statusCode !== 404) throw error;
        indexesToDelete.push(...targetIndexes);
        return;
      }
      const activeIndexes = [];
      for (const index of targetIndexes) {
        const indexedAt = new Date(index.activityAt).getTime();
        const retainedAt = Date.parse(target.retentionAt);
        if (target.retentionAt && retainedAt !== indexedAt) indexesToDelete.push(index);
        else activeIndexes.push(index);
      }
      if (activeIndexes.length) activeByTarget.set(targetKey, { indexes: activeIndexes, target });
    }, beforeDeadline));

    const targetBatches = batchesFor([...activeByTarget.values()], ({ target }) => ({
      partitionKey: target.partitionKey,
      rowKey: target.rowKey,
    }));
    failures.push(...await runConcurrent(targetBatches, concurrency, async (batch) => {
      for (const { item: { target } } of batch) {
        if (!target.etag) throw new Error("Teams retention target is missing an etag");
      }
      const deleteToken = randomUUID();
      try {
        await this.table.submitTransaction(batch.map(({ item: { target } }) => [
          "update",
          {
            partitionKey: target.partitionKey,
            rowKey: target.rowKey,
            retentionDeleteToken: deleteToken,
          },
          "Merge",
          { etag: target.etag },
        ]));
      } catch (error) {
        if (![404, 412].includes(error?.statusCode)) throw error;
        for (const { item: { indexes: targetIndexes, target } } of batch) {
          try {
            await this.table.deleteEntity(target.partitionKey, target.rowKey, { etag: target.etag });
            indexesToDelete.push(...targetIndexes);
          } catch (deleteError) {
            if (deleteError?.statusCode === 404) indexesToDelete.push(...targetIndexes);
            else if (deleteError?.statusCode !== 412) throw deleteError;
          }
        }
        return;
      }
      try {
        await this.table.submitTransaction(batch.map(({ item: { target } }) => [
          "delete",
          { partitionKey: target.partitionKey, rowKey: target.rowKey },
        ]));
      } catch (error) {
        if (error?.statusCode !== 404) throw error;
        await Promise.all(batch.map(({ item: { target } }) => (
          this.table.deleteEntity(target.partitionKey, target.rowKey).catch((deleteError) => {
            if (deleteError?.statusCode !== 404) throw deleteError;
          })
        )));
      }
      for (const { item: { indexes: targetIndexes } } of batch) indexesToDelete.push(...targetIndexes);
    }, beforeDeadline));

    const indexBatches = batchesFor(indexesToDelete, (index) => ({
      partitionKey: index.partitionKey,
      rowKey: index.rowKey,
    }));
    failures.push(...await runConcurrent(indexBatches, concurrency, async (batch) => {
      try {
        await this.table.submitTransaction(batch.map(({ entity }) => ["delete", entity]));
      } catch (error) {
        if (error?.statusCode !== 404) throw error;
        for (const { entity } of batch) {
          try {
            await this.table.deleteEntity(entity.partitionKey, entity.rowKey);
          } catch (deleteError) {
            if (deleteError?.statusCode !== 404) throw deleteError;
          }
        }
      }
    }, beforeDeadline));
    if (failures.length) {
      throw new AggregateError(failures.map(({ error }) => error), "Teams retention operations failed");
    }
    return indexes.length;
  }
}

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

  async markRequestEnqueued(requestId, _tenantId, _source, claimToken) {
    const value = this.records.get(requestId);
    Object.assign(value, requestEnqueued(value, claimToken) || {});
  }

  async markRequestQueueError(requestId, _tenantId, error, _source, claimToken) {
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

  async markRequestAcknowledged(requestId, _tenantId, activityId, _source, claimToken) {
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
