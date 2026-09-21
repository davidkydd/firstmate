// Starts the real Firstmate canvas server wired to the real fm-captain-surface
// bridge over a populated store, prints the tokenized URL, and stays alive so a
// headless browser can render it. Faithful to production: view() and ingress()
// shell out to bin/fm-captain-surface.sh exactly as the installed extension does.
import { writeFileSync } from "node:fs";

const ROOT = process.env.ROOT;
const { BridgeClient } = await import(`file://${ROOT}/bin/copilot-app-extension/bridge-client.mjs`);
const { startCanvasServer } = await import(`file://${ROOT}/bin/copilot-app-extension/canvas-server.mjs`);

const config = {
    schema: "firstmate.copilot-app-extension.v1",
    protocol_version: 1,
    client_id: "evidence-app",
    firstmate_root: ROOT,
    fm_home: process.env.FM_HOME,
    installed_copilot_version: "GitHub Copilot CLI 1.0.84-5",
};

const bridge = new BridgeClient(config, "generation-evidence");
const server = await startCanvasServer({
    bridge,
    sessionId: "evidence-session",
    log: (message, level) => console.error(`[canvas ${level}] ${message}`),
});
writeFileSync(process.env.URL_FILE, server.url);
console.error(`canvas listening: ${server.url}`);

process.on("SIGTERM", async () => {
    await server.close();
    process.exit(0);
});
setTimeout(() => server.close().then(() => process.exit(0)), 60_000).unref();
