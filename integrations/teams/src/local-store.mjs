import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { chmod, link, mkdir, open, opendir, readFile, rename, stat, unlink } from "node:fs/promises";
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
    await chmod(this.root, 0o700);
    await chmod(this.requests, 0o700);
    await chmod(this.results, 0o700);
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
      await atomicJson(this.requestPath(requestId), updated);
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
        await atomicJson(this.requestPath(candidate.requestId), requestRecord);
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
          await atomicJson(this.requestPath(candidate.requestId), updated);
          return { queued: false, result: stored };
        }
        candidate = stored;
      } else {
        await atomicJson(file, {
          schema: "firstmate.teams.local-result.v1",
          state: "publishing",
          result: candidate,
          publishingAt: new Date().toISOString(),
        });
      }
      await send(candidate);
      await atomicJson(file, {
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
      await atomicJson(this.requestPath(candidate.requestId), updated);
      return { queued: true, result: candidate };
    });
  }

  async nextPurgeEntries(directory, scanLimit) {
    let handle = this.purgeDirectories.get(directory);
    if (!handle) {
      try {
        handle = await opendir(directory);
      } catch (error) {
        if (error?.code === "ENOENT") return [];
        throw error;
      }
      this.purgeDirectories.set(directory, handle);
    }
    const entries = [];
    for (let inspected = 0; inspected < scanLimit; inspected += 1) {
      const entry = await handle.read();
      if (!entry) {
        await handle.close().catch(() => {});
        this.purgeDirectories.delete(directory);
        break;
      }
      if (entry.isFile() && /^[a-z0-9_]{10,100}\.json$/.test(entry.name)) entries.push(entry.name);
    }
    return entries;
  }

  async purgeBefore(cutoff, limit = 1000, scanLimit = 5000) {
    const cutoffMilliseconds = cutoff.getTime();
    const expired = (value) => {
      const timestamp = value.updatedAt || value.queuedAt || value.publishingAt || value.capturedAt;
      return typeof timestamp === "string" && Date.parse(timestamp) < cutoffMilliseconds;
    };
    const readRecord = async (file) => {
      try {
        return JSON.parse(await readFile(file, "utf8"));
      } catch (error) {
        if (error?.code !== "ENOENT" && !(error instanceof SyntaxError)) throw error;
        return null;
      }
    };
    let removed = 0;
    const directories = [this.requests, this.results];
    for (let directoryIndex = 0; directoryIndex < directories.length; directoryIndex += 1) {
      const directory = directories[directoryIndex];
      const directoryLimit = Math.floor(limit / directories.length)
        + (directoryIndex < limit % directories.length ? 1 : 0);
      let directoryRemoved = 0;
      const names = await this.nextPurgeEntries(directory, scanLimit);
      for (let offset = 0; offset < names.length && directoryRemoved < directoryLimit; offset += 32) {
        const batch = names.slice(offset, offset + Math.min(32, directoryLimit - directoryRemoved));
        directoryRemoved += (await Promise.all(batch.map(async (name) => {
          const file = path.join(directory, name);
          const initial = await readRecord(file);
          if (!initial || !expired(initial)) return 0;
          const removeIfStillExpired = async () => {
            const current = await readRecord(file);
            if (!current || !expired(current)) return 0;
            await unlink(file);
            return 1;
          };
          if (directory === this.requests) {
            return this.withRequestLock(name.slice(0, -5), removeIfStillExpired);
          }
          if (initial.state === "publishing" && initial.result?.requestId) {
            return this.withRequestLock(initial.result.requestId, removeIfStillExpired);
          }
          return removeIfStillExpired();
        }))).reduce((sum, value) => sum + value, 0);
      }
      removed += directoryRemoved;
    }
    return removed;
  }

  async assertPrivate() {
    for (const directory of [this.root, this.requests, this.results]) {
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
