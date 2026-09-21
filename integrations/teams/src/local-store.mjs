import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { chmod, link, mkdir, open, opendir, readFile, readdir, rename, rmdir, stat, unlink } from "node:fs/promises";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { promisify } from "node:util";
import { sameSource, validateRequest, validateResult } from "./contracts.mjs";

function safeId(value, name) {
  if (typeof value !== "string" || !/^[a-z0-9_]{10,100}$/.test(value)) {
    throw new Error(`${name} is not a safe local record id`);
  }
  return value;
}

function retentionTimestamp(value) {
  const timestamp = value.updatedAt || value.queuedAt || value.publishingAt || value.capturedAt;
  return typeof timestamp === "string" && !Number.isNaN(Date.parse(timestamp)) ? timestamp : null;
}

function retentionBucket(timestamp) {
  return new Date(timestamp).toISOString().slice(0, 13);
}

async function runConcurrent(items, concurrency, operation, shouldContinue = () => true) {
  let next = 0;
  const workers = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (shouldContinue()) {
      const index = next;
      next += 1;
      if (index >= items.length) return;
      await operation(items[index]);
    }
  });
  await Promise.all(workers);
}

async function syncDirectory(directory) {
  const handle = await open(directory, fsConstants.O_RDONLY);
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function stagedJson(file, value) {
  const directory = path.dirname(file);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await chmod(directory, 0o700);
  const temporary = `${file}.tmp-${process.pid}-${randomUUID()}`;
  const handle = await open(temporary, fsConstants.O_CREAT | fsConstants.O_EXCL | fsConstants.O_WRONLY, 0o600);
  try {
    await handle.writeFile(`${JSON.stringify(value)}\n`, "utf8");
    await handle.sync();
  } catch (error) {
    await unlink(temporary).catch(() => {});
    throw error;
  } finally {
    await handle.close();
  }
  return temporary;
}

async function atomicJson(file, value) {
  const directory = path.dirname(file);
  const temporary = await stagedJson(file, value);
  try {
    await rename(temporary, file);
    await syncDirectory(directory);
  } finally {
    await unlink(temporary).catch(() => {});
  }
}

async function createJson(file, value) {
  const directory = path.dirname(file);
  const temporary = await stagedJson(file, value);
  try {
    await link(temporary, file);
    await syncDirectory(directory);
    return true;
  } catch (error) {
    if (error?.code === "EEXIST") return false;
    throw error;
  } finally {
    await unlink(temporary).catch(() => {});
  }
}

async function unlinkOwned(file, handle) {
  try {
    const [owned, current] = await Promise.all([handle.stat(), stat(file)]);
    if (owned.dev === current.dev && owned.ino === current.ino) await unlink(file);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

function processIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code !== "ESRCH";
  }
}

const execFileAsync = promisify(execFile);
const MALFORMED_LOCK_STALE_MILLISECONDS = 30_000;

async function processIdentity(pid) {
  try {
    const contents = await readFile(`/proc/${pid}/stat`, "utf8");
    const commandEnd = contents.lastIndexOf(")");
    const fields = commandEnd >= 0 ? contents.slice(commandEnd + 1).trim().split(/\s+/) : [];
    if (/^\d+$/.test(fields[19] || "")) return `proc-start:${fields[19]}`;
  } catch {}
  try {
    const { stdout } = await execFileAsync("ps", ["-p", String(pid), "-o", "lstart="], {
      encoding: "utf8",
      env: { ...process.env, LC_ALL: "C" },
    });
    const startedAt = stdout.trim().replace(/\s+/g, " ");
    return startedAt ? `ps-start:${startedAt}` : null;
  } catch {
    return null;
  }
}

let currentProcessIdentityPromise;

async function lockOwner() {
  const identityPromise = currentProcessIdentityPromise ||= processIdentity(process.pid);
  const identity = await identityPromise;
  if (!identity) {
    if (currentProcessIdentityPromise === identityPromise) currentProcessIdentityPromise = undefined;
    throw new Error("could not determine the local Teams lock owner identity");
  }
  return {
    schema: "firstmate.teams.lock-owner.v2",
    pid: process.pid,
    processIdentity: identity,
    token: randomUUID(),
    createdAt: new Date().toISOString(),
  };
}

function parseLockOwner(value) {
  try {
    const owner = JSON.parse(value);
    if (owner?.schema === "firstmate.teams.lock-owner.v2"
        && Number.isSafeInteger(owner.pid)
        && owner.pid > 0
        && typeof owner.processIdentity === "string"
        && owner.processIdentity.length > 0
        && typeof owner.token === "string"
        && /^[a-f0-9-]{36}$/.test(owner.token)
        && typeof owner.createdAt === "string"
        && !Number.isNaN(Date.parse(owner.createdAt))) {
      return owner;
    }
  } catch {}
  return null;
}

async function ownerIsLive(owner) {
  if (!processIsAlive(owner.pid)) return false;
  const identity = await processIdentity(owner.pid);
  return identity === null || identity === owner.processIdentity;
}

async function createOwnershipFile(file) {
  if (!(await createJson(file, await lockOwner()))) return null;
  return open(file, fsConstants.O_RDONLY);
}

async function ownershipState(file, nowMilliseconds = Date.now()) {
  let handle;
  try {
    handle = await open(file, fsConstants.O_RDONLY);
    const [contents, info] = await Promise.all([handle.readFile("utf8"), handle.stat()]);
    const owner = parseLockOwner(contents);
    if (owner) return await ownerIsLive(owner) ? "live" : "abandoned";
    return nowMilliseconds - info.mtimeMs >= MALFORMED_LOCK_STALE_MILLISECONDS ? "abandoned" : "live";
  } catch (error) {
    if (error?.code === "ENOENT") return "missing";
    throw error;
  } finally {
    await handle?.close().catch(() => {});
  }
}

async function removeAbandonedOwnership(file, nowMilliseconds = Date.now()) {
  let handle;
  try {
    handle = await open(file, fsConstants.O_RDONLY);
    const [contents, info] = await Promise.all([handle.readFile("utf8"), handle.stat()]);
    const owner = parseLockOwner(contents);
    if ((owner && !(await ownerIsLive(owner)))
        || (!owner && nowMilliseconds - info.mtimeMs >= MALFORMED_LOCK_STALE_MILLISECONDS)) {
      await unlinkOwned(file, handle);
    }
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  } finally {
    await handle?.close().catch(() => {});
  }
}

async function removeAbandonedLock(lock) {
  const cleanup = `${lock}.cleanup`;
  const cleanupHandle = await createOwnershipFile(cleanup);
  if (!cleanupHandle) {
    await removeAbandonedOwnership(cleanup);
    return;
  }
  try {
    await removeAbandonedOwnership(lock);
  } finally {
    try {
      await unlinkOwned(cleanup, cleanupHandle);
    } finally {
      await cleanupHandle.close().catch(() => {});
    }
  }
}

export class LocalRequestStore {
  constructor(home) {
    this.root = path.join(home, "state", "teams");
    this.requests = path.join(this.root, "requests");
    this.results = path.join(this.root, "results");
    this.expiry = path.join(this.root, "expiry");
    this.expiryRequests = path.join(this.expiry, "requests");
    this.expiryResults = path.join(this.expiry, "results");
    this.purgeDirectories = new Map();
  }

  requestPath(requestId) {
    return path.join(this.requests, `${safeId(requestId, "request id")}.json`);
  }

  resultPath(resultId) {
    return path.join(this.results, `${safeId(resultId, "result id")}.json`);
  }

  lockPath(requestId) {
    return path.join(this.requests, `${safeId(requestId, "request id")}.lock`);
  }

  async withRequestLock(requestId, operation) {
    const lock = this.lockPath(requestId);
    const deadline = Date.now() + 5000;
    let retryDelay = 10;
    while (Date.now() < deadline) {
      const handle = await createOwnershipFile(lock);
      if (handle) {
        try {
          return await operation();
        } finally {
          try {
            await unlinkOwned(lock, handle);
          } finally {
            await handle.close().catch(() => {});
          }
        }
      }
      while (Date.now() < deadline) {
        const state = await ownershipState(lock);
        if (state === "missing") break;
        if (state === "abandoned") {
          await removeAbandonedLock(lock);
          break;
        }
        const remaining = deadline - Date.now();
        if (remaining <= 0) break;
        await delay(Math.min(retryDelay, remaining));
        retryDelay = Math.min(retryDelay * 2, 250);
      }
    }
    throw new Error("timed out waiting to update the local Teams request record");
  }

  async ensure() {
    await mkdir(this.requests, { recursive: true, mode: 0o700 });
    await mkdir(this.results, { recursive: true, mode: 0o700 });
    await mkdir(this.expiryRequests, { recursive: true, mode: 0o700 });
    await mkdir(this.expiryResults, { recursive: true, mode: 0o700 });
    await Promise.all([
      this.root,
      this.requests,
      this.results,
      this.expiry,
      this.expiryRequests,
      this.expiryResults,
    ].map((directory) => chmod(directory, 0o700)));
  }

  expiryPath(kind, id, timestamp) {
    const root = kind === "request" ? this.expiryRequests : this.expiryResults;
    return path.join(root, retentionBucket(timestamp), `${safeId(id, `${kind} id`)}.json`);
  }

  async indexRecord(kind, id, value) {
    const timestamp = retentionTimestamp(value);
    if (!timestamp) return null;
    const marker = this.expiryPath(kind, id, timestamp);
    await createJson(marker, {
      schema: "firstmate.teams.local-expiry.v1",
      indexedAt: timestamp,
    });
    return marker;
  }

  async writeRecord(kind, id, value) {
    await this.indexRecord(kind, id, value);
    const file = kind === "request" ? this.requestPath(id) : this.resultPath(id);
    await atomicJson(file, value);
  }

  async get(requestId) {
    try {
      return JSON.parse(await readFile(this.requestPath(requestId), "utf8"));
    } catch (error) {
      if (error?.code === "ENOENT") return null;
      throw error;
    }
  }

  async capture(request) {
    validateRequest(request);
    await this.ensure();
    const file = this.requestPath(request.requestId);
    const record = {
      schema: "firstmate.teams.local-request.v1",
      request,
      state: "received",
      capturedAt: new Date().toISOString(),
    };
    for (let attempt = 0; attempt < 3; attempt += 1) {
      let existing;
      try {
        existing = await this.get(request.requestId);
      } catch (error) {
        if (!(error instanceof SyntaxError)) throw error;
        await unlink(file).catch((unlinkError) => {
          if (unlinkError?.code !== "ENOENT") throw unlinkError;
        });
        await syncDirectory(this.requests);
        continue;
      }
      if (existing) {
        if (JSON.stringify(existing.request) !== JSON.stringify(request)) {
          throw new Error("stored Teams request identity has different content");
        }
        return { created: false, record: existing };
      }
      await this.indexRecord("request", request.requestId, record);
      if (await createJson(file, record)) return { created: true, record };
    }
    throw new Error("could not reconcile the local Teams request record");
  }

  async update(requestId, fields) {
    await this.ensure();
    return this.withRequestLock(requestId, async () => {
      const record = await this.get(requestId);
      if (!record) throw new Error("cannot update a missing Teams request record");
      const terminal = record.terminalResultId
        || (record.state === "result-queued" && record.outcome && record.outcome !== "accepted");
      const nextFields = terminal
        ? {
            ...fields,
            state: record.state,
            outcome: record.outcome,
            ...(record.terminalResultId ? { terminalResultId: record.terminalResultId } : {}),
          }
        : fields;
      const updated = { ...record, ...nextFields, updatedAt: new Date().toISOString() };
      await this.writeRecord("request", requestId, updated);
      return updated;
    });
  }

  async queueResult(candidate, send) {
    validateResult(candidate);
    await this.ensure();
    return this.withRequestLock(candidate.requestId, async () => {
      let requestRecord = await this.get(candidate.requestId);
      if (!requestRecord?.request || !sameSource(requestRecord.request.source, candidate.source)) {
        throw new Error("result does not match its local Teams request");
      }
      const hasTerminalResult = requestRecord.terminalResultId
        || (requestRecord.state === "result-queued" && requestRecord.outcome !== "accepted");
      if (!candidate.terminal && hasTerminalResult) {
        return { queued: false, result: candidate, superseded: true };
      }
      if (requestRecord.terminalResultId && requestRecord.terminalResultId !== candidate.resultId) {
        throw new Error("the Teams request already has a conflicting terminal result");
      }
      if (requestRecord.state === "result-queued"
          && requestRecord.outcome !== "accepted"
          && requestRecord.outcome !== candidate.outcome) {
        throw new Error("the Teams request already has a conflicting terminal result");
      }
      if (candidate.terminal && !requestRecord.terminalResultId) {
        requestRecord = {
          ...requestRecord,
          state: "result-publishing",
          outcome: candidate.outcome,
          terminalResultId: candidate.resultId,
          updatedAt: new Date().toISOString(),
        };
        await this.writeRecord("request", candidate.requestId, requestRecord);
      }
      const file = this.resultPath(candidate.resultId);
      let resultRecord;
      try {
        resultRecord = JSON.parse(await readFile(file, "utf8"));
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
      }
      if (resultRecord) {
        const stored = validateResult(resultRecord.result);
        if (stored.requestId !== candidate.requestId
            || stored.outcome !== candidate.outcome
            || stored.text !== candidate.text
            || !sameSource(stored.source, candidate.source)) {
          throw new Error("result id was reused with different content");
        }
        if (resultRecord.state === "queued") {
          const updated = {
            ...requestRecord,
            state: "result-queued",
            outcome: stored.outcome,
            ...(stored.terminal ? { terminalResultId: stored.resultId } : {}),
            updatedAt: new Date().toISOString(),
          };
          await this.writeRecord("request", candidate.requestId, updated);
          return { queued: false, result: stored };
        }
        candidate = stored;
      } else {
        await this.writeRecord("result", candidate.resultId, {
          schema: "firstmate.teams.local-result.v1",
          state: "publishing",
          result: candidate,
          publishingAt: new Date().toISOString(),
        });
      }
      await send(candidate);
      await this.writeRecord("result", candidate.resultId, {
        schema: "firstmate.teams.local-result.v1",
        state: "queued",
        result: candidate,
        queuedAt: new Date().toISOString(),
      });
      const updated = {
        ...requestRecord,
        state: "result-queued",
        outcome: candidate.outcome,
        ...(candidate.terminal ? { terminalResultId: candidate.resultId } : {}),
        updatedAt: new Date().toISOString(),
      };
      await this.writeRecord("request", candidate.requestId, updated);
      return { queued: true, result: candidate };
    });
  }

  async nextPurgeEntries(directory, scanLimit, deadline = Infinity) {
    let handle = this.purgeDirectories.get(directory);
    if (!handle) {
      try {
        handle = await opendir(directory);
      } catch (error) {
        if (error?.code === "ENOENT") return { names: [], exhausted: true, inspected: 0 };
        throw error;
      }
      this.purgeDirectories.set(directory, handle);
    }
    const names = [];
    let exhausted = false;
    let inspected = 0;
    for (; inspected < scanLimit && Date.now() < deadline; inspected += 1) {
      const entry = await handle.read();
      if (!entry) {
        await handle.close().catch(() => {});
        this.purgeDirectories.delete(directory);
        exhausted = true;
        break;
      }
      if (entry.isFile() && /^[a-z0-9_]{10,100}\.json$/.test(entry.name)) names.push(entry.name);
    }
    return { names, exhausted, inspected };
  }

  async readRecord(file) {
    try {
      return JSON.parse(await readFile(file, "utf8"));
    } catch (error) {
      if (error?.code !== "ENOENT" && !(error instanceof SyntaxError)) throw error;
      return null;
    }
  }

  async migrateExpiryIndex(kind, scanLimit, concurrency, deadline) {
    const directory = kind === "request" ? this.requests : this.results;
    const complete = path.join(this.expiry, `.${kind}s-indexed`);
    try {
      await stat(complete);
      return;
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    let exhausted = false;
    let inspected = 0;
    while (!exhausted && inspected < scanLimit && Date.now() < deadline) {
      const batchLimit = Math.min(scanLimit - inspected, concurrency * 4);
      const entries = await this.nextPurgeEntries(directory, batchLimit, deadline);
      inspected += entries.inspected;
      exhausted = entries.exhausted;
      await runConcurrent(entries.names, concurrency, async (name) => {
        const value = await this.readRecord(path.join(directory, name));
        if (value) await this.indexRecord(kind, name.slice(0, -5), value);
      });
      if (entries.inspected === 0) break;
    }
    if (exhausted) {
      await atomicJson(complete, {
        schema: "firstmate.teams.local-expiry-migration.v1",
        completedAt: new Date().toISOString(),
      });
    }
  }

  async expiryPartitions(root, cutoffBucket) {
    try {
      return (await readdir(root, { withFileTypes: true }))
        .filter((entry) => entry.isDirectory() && /^\d{4}-\d{2}-\d{2}T\d{2}$/.test(entry.name)
          && entry.name <= cutoffBucket)
        .map((entry) => entry.name)
        .sort();
    } catch (error) {
      if (error?.code === "ENOENT") return [];
      throw error;
    }
  }

  async purgeIndexedKind(kind, cutoffMilliseconds, limit, scanLimit, concurrency, deadline) {
    const indexRoot = kind === "request" ? this.expiryRequests : this.expiryResults;
    const recordRoot = kind === "request" ? this.requests : this.results;
    const partitions = await this.expiryPartitions(indexRoot, retentionBucket(cutoffMilliseconds));
    const beforeDeadline = () => Date.now() < deadline;
    let inspected = 0;
    let removed = 0;
    for (const partition of partitions) {
      if (!beforeDeadline() || inspected >= scanLimit || removed >= limit) break;
      const directory = path.join(indexRoot, partition);
      const entries = await this.nextPurgeEntries(directory, scanLimit - inspected, deadline);
      inspected += entries.inspected;
      const candidates = [];
      await runConcurrent(entries.names, concurrency, async (name) => {
        const id = name.slice(0, -5);
        const initial = kind === "result" ? await this.readRecord(path.join(recordRoot, name)) : null;
        candidates.push({
          id,
          name,
          requestId: kind === "request" ? id : initial?.result?.requestId,
        });
      }, beforeDeadline);
      const groups = new Map();
      for (const candidate of candidates) {
        const groupKey = candidate.requestId || `unowned:${candidate.name}`;
        const group = groups.get(groupKey) || [];
        group.push(candidate);
        groups.set(groupKey, group);
      }
      await runConcurrent([...groups.values()], concurrency, async (group) => {
        for (const { id, name, requestId } of group) {
          if (!beforeDeadline() || removed >= limit) break;
          const marker = path.join(directory, name);
          const file = path.join(recordRoot, name);
          const removeMarker = () => unlink(marker).catch((error) => {
            if (error?.code !== "ENOENT") throw error;
          });
          const reconcile = async () => {
            if (!beforeDeadline()) return;
            const current = await this.readRecord(file);
            if (!current) {
              await removeMarker();
              return;
            }
            const timestamp = retentionTimestamp(current);
            if (!timestamp || Date.parse(timestamp) >= cutoffMilliseconds) {
              const currentMarker = timestamp ? await this.indexRecord(kind, id, current) : null;
              if (currentMarker !== marker) await removeMarker();
              return;
            }
            if (removed >= limit || !beforeDeadline()) return;
            removed += 1;
            try {
              await unlink(file);
              await removeMarker();
            } catch (error) {
              removed -= 1;
              throw error;
            }
          };
          if (requestId) await this.withRequestLock(requestId, reconcile);
          else await reconcile();
        }
      }, () => beforeDeadline() && removed < limit);
      if (entries.exhausted) await rmdir(directory).catch((error) => {
        if (error?.code !== "ENOENT" && error?.code !== "ENOTEMPTY") throw error;
      });
    }
    return removed;
  }

  async purgeBefore(cutoff, limit = 1000, scanLimit = 5000, { concurrency = 8, deadline = Infinity } = {}) {
    const cutoffMilliseconds = cutoff.getTime();
    if (!Number.isFinite(cutoffMilliseconds)) throw new Error("retention cutoff must be a valid date");
    if (!Number.isInteger(concurrency) || concurrency < 1) throw new Error("retention concurrency must be a positive integer");
    await this.ensure();
    await Promise.all([
      this.migrateExpiryIndex("request", scanLimit, concurrency, deadline),
      this.migrateExpiryIndex("result", scanLimit, concurrency, deadline),
    ]);
    let removed = 0;
    for (const [index, kind] of ["request", "result"].entries()) {
      if (Date.now() >= deadline) break;
      const kindLimit = Math.floor(limit / 2) + (index < limit % 2 ? 1 : 0);
      removed += await this.purgeIndexedKind(
        kind,
        cutoffMilliseconds,
        kindLimit,
        scanLimit,
        concurrency,
        deadline,
      );
    }
    return removed;
  }

  async assertPrivate() {
    for (const directory of [
      this.root,
      this.requests,
      this.results,
      this.expiry,
      this.expiryRequests,
      this.expiryResults,
    ]) {
      try {
        const info = await stat(directory);
        if (!info.isDirectory() || (info.mode & 0o077) !== 0) {
          throw new Error(`${directory} must be an owner-only directory`);
        }
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
      }
    }
  }
}
