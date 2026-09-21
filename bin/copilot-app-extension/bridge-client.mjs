import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import path from "node:path";

const MAX_OUTPUT_BYTES = 4 * 1024 * 1024;
const CALL_TIMEOUT_MS = 30_000;
const CONFIG_KEYS = [
    "client_id",
    "firstmate_root",
    "fm_home",
    "installed_copilot_version",
    "protocol_version",
    "schema",
];

function exactKeys(value, keys) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    const actual = Object.keys(value).sort();
    const expected = [...keys].sort();
    return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}

export function parseCopilotVersion(value) {
    const match = String(value ?? "").match(/(?:^|\s)(\d+)\.(\d+)\.(\d+)(?:[-+][^\s]+)?(?:\.|\s|$)/);
    if (!match) return null;
    return match.slice(1, 4).map(Number);
}

export function supportsCanvasVersion(value, minimum = [1, 0, 84]) {
    const parsed = parseCopilotVersion(value);
    if (!parsed) return false;
    for (let index = 0; index < minimum.length; index += 1) {
        if (parsed[index] > minimum[index]) return true;
        if (parsed[index] < minimum[index]) return false;
    }
    return true;
}

export function classifyMessageSource(source) {
    if (source === "user") return "direct-user";
    if (typeof source === "string" && source.startsWith("agent-")) return "agent";
    if (source === "system") return "system";
    return "extension";
}

export function validateConfig(value) {
    if (!exactKeys(value, CONFIG_KEYS)) throw new Error("config.json has unknown or missing fields");
    if (value.schema !== "firstmate.copilot-app-extension.v1" || value.protocol_version !== 1) {
        throw new Error("config.json has an incompatible schema or protocol");
    }
    for (const key of ["firstmate_root", "fm_home"]) {
        if (typeof value[key] !== "string" || !path.isAbsolute(value[key])) {
            throw new Error(`${key} must be an absolute path`);
        }
    }
    if (!/^[A-Za-z0-9._:-]{1,64}$/.test(value.client_id)) {
        throw new Error("client_id must be a privacy-safe identifier");
    }
    if (typeof value.installed_copilot_version !== "string" || value.installed_copilot_version.length > 128) {
        throw new Error("installed_copilot_version is invalid");
    }
    return Object.freeze({ ...value });
}

export async function loadConfig(url) {
    const raw = await readFile(new URL("./config.json", url), "utf8");
    return validateConfig(JSON.parse(raw));
}

function childEnvironment(config) {
    const env = {
        FM_HOME: config.fm_home,
        HOME: process.env.HOME ?? "",
        LANG: process.env.LANG ?? "C.UTF-8",
        PATH: process.env.PATH ?? "/usr/bin:/bin",
    };
    if (process.env.LC_ALL) env.LC_ALL = process.env.LC_ALL;
    if (process.env.TMPDIR) env.TMPDIR = process.env.TMPDIR;
    return env;
}

function run(config, args, input = "") {
    const command = path.join(config.firstmate_root, "bin", "fm-captain-surface.sh");
    return new Promise((resolve, reject) => {
        const child = spawn(command, args, {
            env: childEnvironment(config),
            stdio: ["pipe", "pipe", "pipe"],
        });
        let stdout = Buffer.alloc(0);
        let stderr = Buffer.alloc(0);
        let settled = false;
        const timer = setTimeout(() => {
            if (settled) return;
            settled = true;
            child.kill("SIGTERM");
            setTimeout(() => child.kill("SIGKILL"), 1000).unref();
            reject(new Error(`Firstmate bridge call exceeded ${CALL_TIMEOUT_MS}ms`));
        }, CALL_TIMEOUT_MS);
        timer.unref();
        const collect = (current, chunk) => {
            const next = Buffer.concat([current, chunk]);
            if (next.length > MAX_OUTPUT_BYTES) {
                child.kill("SIGTERM");
                throw new Error("Firstmate bridge response exceeded its byte bound");
            }
            return next;
        };
        child.stdout.on("data", (chunk) => {
            try {
                stdout = collect(stdout, chunk);
            } catch (error) {
                if (!settled) {
                    settled = true;
                    clearTimeout(timer);
                    reject(error);
                }
            }
        });
        child.stderr.on("data", (chunk) => {
            try {
                stderr = collect(stderr, chunk);
            } catch (error) {
                if (!settled) {
                    settled = true;
                    clearTimeout(timer);
                    reject(error);
                }
            }
        });
        child.on("error", (error) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            reject(error);
        });
        child.on("close", (code, signal) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            const out = stdout.toString("utf8");
            const err = stderr.toString("utf8").trim();
            if (code !== 0) {
                reject(new Error(err || `Firstmate bridge exited ${code ?? signal ?? "unknown"}`));
                return;
            }
            resolve(out);
        });
        child.stdin.end(input);
    });
}

function parseDocument(raw, label) {
    const trimmed = raw.trim();
    if (!trimmed) throw new Error(`${label} returned no JSON`);
    try {
        return JSON.parse(trimmed);
    } catch {
        throw new Error(`${label} returned malformed JSON`);
    }
}

function parseJsonLines(raw) {
    if (!raw.trim()) return [];
    return raw
        .trimEnd()
        .split("\n")
        .map((line) => JSON.parse(line));
}

export class BridgeClient {
    constructor(config, generation) {
        this.config = validateConfig(config);
        this.generation = generation;
        if (!/^[A-Za-z0-9._:-]{1,128}$/.test(generation)) throw new Error("generation is invalid");
    }

    async register({ sdkVersion, canvasCapable }) {
        const raw = await run(this.config, [
            "register",
            "--client",
            this.config.client_id,
            "--generation",
            this.generation,
            "--sdk-version",
            sdkVersion || "unknown",
            "--canvas-capable",
            canvasCapable ? "true" : "false",
        ]);
        return parseDocument(raw, "register");
    }

    async ingress({ correlationId, provenance, kind, payload, sessionId = "", messageId = "" }) {
        const raw = await run(
            this.config,
            [
                "ingress",
                "--client",
                this.config.client_id,
                "--generation",
                this.generation,
                "--correlation-id",
                correlationId,
                "--provenance",
                provenance,
                "--kind",
                kind,
                "--payload-file",
                "-",
                "--session-id",
                sessionId,
                "--message-id",
                messageId,
            ],
            `${JSON.stringify(payload)}\n`,
        );
        const seq = Number(raw.trim());
        if (!Number.isSafeInteger(seq) || seq < 1) throw new Error("ingress returned an invalid sequence");
        return seq;
    }

    async outcomes() {
        const raw = await run(this.config, [
            "outcomes",
            "--client",
            this.config.client_id,
            "--generation",
            this.generation,
        ]);
        return parseJsonLines(raw);
    }

    async acknowledge(through) {
        await run(this.config, [
            "ack-output",
            "--client",
            this.config.client_id,
            "--generation",
            this.generation,
            "--through",
            String(through),
        ]);
    }

    async view() {
        const raw = await run(this.config, [
            "view",
            "--client",
            this.config.client_id,
            "--generation",
            this.generation,
        ]);
        return parseDocument(raw, "view");
    }
}
