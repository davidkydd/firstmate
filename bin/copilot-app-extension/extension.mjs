import { randomUUID } from "node:crypto";

import { BridgeClient, classifyMessageSource, loadConfig, supportsCanvasVersion } from "./bridge-client.mjs";
import { startCanvasServer } from "./canvas-server.mjs";

const config = await loadConfig(import.meta.url);
const generation = `extension-${randomUUID()}`;
const bridge = new BridgeClient(config, generation);
const extensionSdk = await import("@github/copilot-sdk/extension");
let sdkVersion = config.installed_copilot_version || "unknown";
try {
    const sdk = await import("@github/copilot-sdk");
    if (typeof sdk.COPILOT_CLI_VERSION === "string") sdkVersion = sdk.COPILOT_CLI_VERSION;
} catch {
    // The extension module is the supported minimum. A host that does not
    // expose the package root still gets the configured install-time version.
}

let session;
let canvasServer;
const openInstances = new Set();
let lastBridgeError = "";
let pollRunning = false;

function log(message, level = "info", ephemeral = false) {
    void session?.log(message, { level, ephemeral }).catch(() => {});
}

async function ensureCanvasServer(sessionId) {
    if (!canvasServer) canvasServer = await startCanvasServer({ bridge, sessionId, log });
    return canvasServer;
}

const canvases = [];
const canvasApiPresent =
    typeof extensionSdk.createCanvas === "function" && supportsCanvasVersion(sdkVersion || config.installed_copilot_version);
if (canvasApiPresent) {
    canvases.push(
        extensionSdk.createCanvas({
            id: "firstmate",
            displayName: "Firstmate",
            description:
                "Read the authoritative external Firstmate fleet and exact outcomes, then submit explicit typed requests through its guarded transport.",
            actions: [],
            open: async (context) => {
                if (context.host?.capabilities?.canvases === false) {
                    throw new extensionSdk.CanvasError(
                        "firstmate_canvas_unavailable",
                        "This Copilot host does not advertise the experimental canvas capability.",
                    );
                }
                openInstances.add(context.instanceId);
                const server = await ensureCanvasServer(context.sessionId);
                return {
                    url: server.url,
                    title: "Firstmate",
                    status: "External Firstmate projection",
                };
            },
            onClose: async (context) => {
                openInstances.delete(context.instanceId);
                if (openInstances.size === 0 && canvasServer) {
                    const closing = canvasServer;
                    canvasServer = undefined;
                    await closing.close().catch(() => {});
                }
            },
        }),
    );
}

const firstmateCommand = {
    name: "firstmate",
    description: "Send an explicit request to external Firstmate.",
    handler: async (context) => {
        const text = String(context.args ?? "").trim();
        if (!text) {
            await session.log("Usage: /firstmate <request>. Open the Firstmate canvas for fleet status and typed decisions.");
            return;
        }
        const correlationId = `command:${randomUUID()}`;
        try {
            const seq = await bridge.ingress({
                correlationId,
                provenance: "direct-user",
                kind: "request",
                payload: { text },
                sessionId: String(context.sessionId ?? ""),
                messageId: correlationId,
            });
            await session.log(`Stored for external Firstmate before notification as input #${seq}.`);
        } catch (error) {
            await session.log(`Firstmate bridge unavailable; external supervision is unaffected. ${error.message}`, {
                level: "error",
            });
        }
    },
};

session = await extensionSdk.joinSession({
    canvases,
    commands: [firstmateCommand],
    extensionInfo: { source: "user", name: "firstmate" },
});

const hostCanvasCapable = session.capabilities?.ui?.canvases === true;
try {
    await bridge.register({ sdkVersion, canvasCapable: canvasApiPresent && hostCanvasCapable });
    if (!canvasApiPresent || !hostCanvasCapable) {
        log(
            `Firstmate canvas disabled: Copilot ${sdkVersion} does not expose the required experimental canvas capability. /firstmate remains available.`,
            "warning",
        );
    }
} catch (error) {
    lastBridgeError = error.message;
    log(`Firstmate bridge unavailable; external supervision is unaffected. ${error.message}`, "error");
}

// An app-generated or system-generated /firstmate-shaped message is retained as
// a non-authoritative observation. It never enters the direct-user command path
// and therefore cannot become a typed decision or lifecycle control.
session.on("user.message", (event) => {
    const rawSource = event.data?.source;
    if (rawSource === undefined || rawSource === null || rawSource === "user") return;
    const provenance = classifyMessageSource(rawSource);
    const content = String(event.data?.content ?? "");
    if (!/^\/firstmate(?:\s|$)/.test(content)) return;
    const text = content.replace(/^\/firstmate(?:\s+|$)/, "").trim() || "(empty agent-generated /firstmate message)";
    const correlationId = `observation:${randomUUID()}`;
    void bridge
        .ingress({
            correlationId,
            provenance,
            kind: "request",
            payload: { text },
            sessionId: String(event.data?.sessionId ?? ""),
            messageId: String(event.id ?? correlationId),
        })
        .then((seq) => log(`Recorded non-authoritative ${provenance} /firstmate attempt as input #${seq}.`, "warning"))
        .catch((error) => log(`Could not retain non-authoritative /firstmate observation: ${error.message}`, "warning"));
});

async function pollOutcomes() {
    if (pollRunning) return;
    pollRunning = true;
    try {
        const outcomes = await bridge.outcomes();
        let through = 0;
        for (const outcome of outcomes) {
            const level = outcome.kind === "error" ? "error" : outcome.kind === "decision" ? "warning" : "info";
            // The body is deliberately logged byte-for-byte rather than passed
            // through a model or prefixed with extension prose.
            await session.log(outcome.payload.body, { level, ephemeral: false });
            through = outcome.seq;
        }
        if (through > 0) await bridge.acknowledge(through);
        if (lastBridgeError) {
            log("Firstmate bridge reconnected.", "info");
            lastBridgeError = "";
        }
    } catch (error) {
        if (error.message !== lastBridgeError) {
            lastBridgeError = error.message;
            log(`Firstmate bridge unavailable; external supervision is unaffected. ${error.message}`, "warning", true);
        }
    } finally {
        pollRunning = false;
    }
}

const pollTimer = setInterval(() => void pollOutcomes(), 2000);
pollTimer.unref();
void pollOutcomes();

async function shutdown() {
    clearInterval(pollTimer);
    if (canvasServer) {
        const closing = canvasServer;
        canvasServer = undefined;
        await closing.close().catch(() => {});
    }
}

process.once("SIGTERM", () => void shutdown().finally(() => process.exit(0)));
process.once("SIGINT", () => void shutdown().finally(() => process.exit(0)));
