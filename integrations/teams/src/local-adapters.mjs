import { spawn } from "node:child_process";
import path from "node:path";

function runFile(file, args, { env, stdin = "", timeoutMilliseconds = 30_000, maxOutputBytes = 64 * 1024 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(file, args, {
      env,
      stdio: ["pipe", "pipe", "pipe"],
      shell: false,
    });
    const stdout = [];
    const stderr = [];
    let outputBytes = 0;
    let finished = false;
    const timer = setTimeout(() => {
      if (finished) return;
      finished = true;
      child.kill("SIGKILL");
      reject(new Error(`${path.basename(file)} exceeded its execution timeout`));
    }, timeoutMilliseconds);
    function capture(chunks, chunk) {
      outputBytes += chunk.length;
      if (outputBytes > maxOutputBytes) {
        if (!finished) {
          finished = true;
          child.kill("SIGKILL");
          reject(new Error(`${path.basename(file)} produced too much output`));
        }
        return;
      }
      chunks.push(chunk);
    }
    child.stdout.on("data", (chunk) => capture(stdout, chunk));
    child.stderr.on("data", (chunk) => capture(stderr, chunk));
    child.once("error", (error) => {
      clearTimeout(timer);
      if (!finished) {
        finished = true;
        reject(error);
      }
    });
    child.once("close", (code) => {
      clearTimeout(timer);
      if (finished) return;
      finished = true;
      const out = Buffer.concat(stdout).toString("utf8");
      const err = Buffer.concat(stderr).toString("utf8");
      if (code !== 0) reject(new Error(`${path.basename(file)} failed: ${(err || out).trim()}`));
      else resolve(out);
    });
    child.stdin.end(stdin, "utf8");
  });
}

export class FirstmateInboxAdapter {
  constructor({ home, root }) {
    this.home = home;
    this.command = path.join(root, "bin", "fm-inbox.sh");
  }

  async deliver(source, requestId, body) {
    const output = await runFile(
      this.command,
      ["external-note", source, requestId, "-"],
      { env: { ...process.env, FM_HOME: this.home }, stdin: body },
    );
    const match = /^(?:already-)?queued\s+(\S+)$/m.exec(output);
    if (!match) throw new Error("fm-inbox.sh did not return a durable note id");
    return match[1];
  }

  async requestApproval(requestId) {
    return this.deliver(
      "teams-review",
      requestId,
      `Teams request ${requestId} is awaiting trusted-local approval. Review the original Teams message and repeat its exact request in this local session to approve it.`,
    );
  }

  async deliverApproved(request) {
    return this.deliver("teams", request.requestId, request.command.text);
  }

  async purgeHandled(retentionDays, limit = 1000) {
    let removed = 0;
    for (const source of ["teams", "teams-review"]) {
      if (removed >= limit) break;
      const output = await runFile(
        this.command,
        ["purge-external-handled", source, String(retentionDays), String(limit - removed)],
        { env: { ...process.env, FM_HOME: this.home }, timeoutMilliseconds: 5 * 60_000 },
      );
      const match = /^purged\s+(\d+)$/m.exec(output);
      if (!match) throw new Error("fm-inbox.sh did not return a handled-note purge count");
      removed += Number(match[1]);
    }
    return removed;
  }
}

export class CountsStatusReader {
  constructor({ home, root }) {
    this.home = home;
    this.command = path.join(root, "bin", "fm_voice_records.py");
  }

  async counts() {
    const output = await runFile(
      this.command,
      ["status", "--home", this.home, "--scope", "counts"],
      { env: { ...process.env, FM_HOME: this.home } },
    );
    const status = JSON.parse(output);
    const states = Object.entries(status.worker_states || {})
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([name, count]) => `${name}: ${count}`)
      .join(", ");
    return [
      `Workers on deck: ${status.workers_on_deck}.`,
      `In flight: ${status.in_flight}.`,
      `Queued: ${status.queued}.`,
      `Awaiting local confirmation: ${status.awaiting_captain}.`,
      `Open pull requests: ${status.open_pull_requests}.`,
      `Inbox notes waiting: ${status.captain_notes_waiting}.`,
      states ? `Last recorded worker events: ${states}.` : "Last recorded worker events: none.",
      status.basis,
    ].join("\n");
  }
}
