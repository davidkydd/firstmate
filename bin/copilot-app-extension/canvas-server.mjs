import { createServer } from "node:http";
import { randomBytes, randomUUID, timingSafeEqual } from "node:crypto";

const MAX_REQUEST_BYTES = 16 * 1024;

function json(response, status, value) {
    const body = `${JSON.stringify(value)}\n`;
    response.writeHead(status, {
        "Cache-Control": "no-store",
        "Content-Length": Buffer.byteLength(body),
        "Content-Type": "application/json; charset=utf-8",
        "X-Content-Type-Options": "nosniff",
    });
    response.end(body);
}

function constantTimeEqual(left, right) {
    const a = Buffer.from(String(left ?? ""));
    const b = Buffer.from(String(right ?? ""));
    return a.length === b.length && timingSafeEqual(a, b);
}

async function readJson(request) {
    const chunks = [];
    let size = 0;
    for await (const chunk of request) {
        size += chunk.length;
        if (size > MAX_REQUEST_BYTES) throw new Error("request exceeds 16384 bytes");
        chunks.push(chunk);
    }
    const raw = Buffer.concat(chunks).toString("utf8");
    const value = JSON.parse(raw);
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("JSON object required");
    return value;
}

function page(token) {
    const tokenJson = JSON.stringify(token).replaceAll("<", "\\u003c");
    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>Firstmate</title>
<style>
:root{color-scheme:light dark;font:14px/1.45 system-ui,sans-serif}body{margin:0;padding:16px;background:#0d1117;color:#e6edf3}h1,h2{margin:.2rem 0 .7rem}h1{font-size:1.25rem}h2{font-size:1rem;color:#8fb8ff}.card{border:1px solid #30363d;border-radius:8px;padding:12px;margin:0 0 12px;background:#161b22}.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}.muted{color:#8b949e}.ok{color:#7ee787}.bad{color:#ff7b72}textarea,input,select,button{font:inherit}textarea,input,select{box-sizing:border-box;width:100%;padding:7px;background:#0d1117;color:#e6edf3;border:1px solid #484f58;border-radius:6px}textarea{min-height:72px}button{padding:7px 12px;border:0;border-radius:6px;background:#238636;color:white;cursor:pointer}button:disabled{opacity:.5;cursor:not-allowed}pre{white-space:pre-wrap;overflow-wrap:anywhere;margin:0;max-height:22rem;overflow:auto}.message{border-left:3px solid #388bfd;padding:6px 9px;margin:6px 0;white-space:pre-wrap}.decision{border-left-color:#d29922}.grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}@media(max-width:720px){.grid{grid-template-columns:1fr}}label{display:block;margin:.5rem 0 .2rem}.status{font-weight:600}
</style>
</head>
<body>
<div class="row"><h1>Firstmate</h1><span id="connection" class="status muted">connecting</span></div>
<p class="muted">Read-only fleet projection. Requests, decisions, and controls are durably handed to external Firstmate; this panel never mutates fleet files directly.</p>
<div class="grid">
<section class="card"><h2>Fleet</h2><pre id="fleet">Loading…</pre></section>
<section class="card"><h2>Exact outcomes</h2><div id="messages"></div></section>
</div>
<section class="card"><h2>Send to Firstmate</h2><textarea id="request" maxlength="8192" placeholder="Request or question"></textarea><p><button id="send">Send to Firstmate</button></p><div id="request-result" class="muted"></div></section>
<section class="card"><h2>Pending typed decisions</h2><div id="decisions" class="muted">No offered decisions.</div></section>
<section class="card"><h2>Guarded worker control</h2><label for="control-task">Exact task id</label><input id="control-task" maxlength="128"><label for="control-verb">Action</label><select id="control-verb"><option value="interrupt">Interrupt</option><option value="relaunch">Relaunch</option></select><label for="control-note">Relaunch progress note (required for relaunch)</label><textarea id="control-note" maxlength="4096"></textarea><p><button id="control-send">Request guarded control</button></p><div id="control-result" class="muted"></div></section>
<script nonce="${token}">
const token=${tokenJson};
const headers={"Content-Type":"application/json","X-Firstmate-Canvas":token};
const byId=id=>document.getElementById(id);
const text=(el,value)=>{el.textContent=value};
async function api(path,body){const response=await fetch(path,{method:body?"POST":"GET",headers,body:body?JSON.stringify(body):undefined,cache:"no-store"});const value=await response.json();if(!response.ok)throw new Error(value.error||("HTTP "+response.status));return value;}
function renderFleet(fleet){const compact={generated:fleet.generated,backlog:fleet.backlog?.records??[],tasks:(fleet.tasks??[]).map(task=>({id:task.id,kind:task.kind,project:task.project,current_state:task.current_state?.state,pr:task.pr?.url,open_decisions:task.hints?.open_decisions??[]})),secondmates:fleet.secondmate_current?.records??[]};text(byId("fleet"),JSON.stringify(compact,null,2));}
function renderMessages(messages){const root=byId("messages");root.replaceChildren();for(const message of messages){const item=document.createElement("div");item.className="message"+(message.kind==="decision"?" decision":"");item.textContent=message.payload.body;item.dataset.seq=String(message.seq);root.append(item);}if(!messages.length)text(root,"No outcomes have been published.");}
function renderDecisions(messages){const root=byId("decisions");root.replaceChildren();const decisions=messages.filter(item=>item.kind==="decision");if(!decisions.length){text(root,"No offered decisions.");return;}for(const item of decisions){const wrap=document.createElement("div");wrap.className="message decision";const title=document.createElement("div");title.textContent=item.payload.body;wrap.append(title);const answer=document.createElement("textarea");answer.maxLength=8192;answer.placeholder="Exact answer";wrap.append(answer);const mode=document.createElement("select");for(const name of item.payload.mode_options){const option=document.createElement("option");option.value=name;option.textContent=name==="done"?"Answer and complete":"Answer and release held work";mode.append(option);}wrap.append(mode);const button=document.createElement("button");button.textContent="Submit typed decision";button.addEventListener("click",async()=>{button.disabled=true;try{const result=await api("/api/decision",{decision_seq:item.seq,task_id:item.payload.task_id,revision:item.payload.revision,answer:answer.value,mode:mode.value});text(title,"Stored typed decision input #"+result.seq);}catch(error){text(title,error.message);}finally{button.disabled=false;}});wrap.append(button);root.append(wrap);}}
async function refresh(){try{const state=await api("/api/state");text(byId("connection"),"Firstmate active · bridge connected · acknowledged through "+state.client.acknowledged_through);byId("connection").className="status ok";renderFleet(state.fleet);renderMessages(state.messages);renderDecisions(state.messages);}catch(error){text(byId("connection"),"Bridge unavailable · external Firstmate is unaffected: "+error.message);byId("connection").className="status bad";}}
byId("send").addEventListener("click",async()=>{const button=byId("send");button.disabled=true;try{const value=await api("/api/request",{text:byId("request").value});text(byId("request-result"),"Stored before notification as input #"+value.seq);byId("request").value="";}catch(error){text(byId("request-result"),error.message);}finally{button.disabled=false;}});
byId("control-send").addEventListener("click",async()=>{const button=byId("control-send");button.disabled=true;try{const value=await api("/api/control",{task_id:byId("control-task").value,verb:byId("control-verb").value,note:byId("control-note").value});text(byId("control-result"),"Stored guarded control input #"+value.seq);}catch(error){text(byId("control-result"),error.message);}finally{button.disabled=false;}});
refresh();setInterval(refresh,2500);
</script>
</body>
</html>`;
}

export async function startCanvasServer({ bridge, sessionId, log }) {
    const token = randomBytes(32).toString("base64url");
    let expectedHost = "";
    const server = createServer(async (request, response) => {
        try {
            if (request.headers.host !== expectedHost) {
                json(response, 400, { error: "invalid Host header" });
                return;
            }
            const url = new URL(request.url ?? "/", `http://${expectedHost}`);
            if (request.method === "GET" && url.pathname === "/") {
                if (!constantTimeEqual(url.searchParams.get("t"), token)) {
                    json(response, 403, { error: "invalid canvas capability" });
                    return;
                }
                const body = page(token);
                response.writeHead(200, {
                    "Cache-Control": "no-store",
                    "Content-Length": Buffer.byteLength(body),
                    "Content-Security-Policy": `default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${token}'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'`,
                    "Content-Type": "text/html; charset=utf-8",
                    "Referrer-Policy": "no-referrer",
                    "X-Content-Type-Options": "nosniff",
                });
                response.end(body);
                return;
            }
            const supplied = request.headers["x-firstmate-canvas"];
            if (!constantTimeEqual(supplied, token)) {
                json(response, 403, { error: "invalid canvas capability" });
                return;
            }
            if (request.method === "POST" && request.headers.origin !== `http://${expectedHost}`) {
                json(response, 403, { error: "invalid Origin header" });
                return;
            }
            if (request.method === "GET" && url.pathname === "/api/state") {
                json(response, 200, await bridge.view());
                return;
            }
            if (request.method !== "POST" || request.headers["content-type"]?.split(";", 1)[0] !== "application/json") {
                json(response, 404, { error: "not found" });
                return;
            }
            const body = await readJson(request);
            let kind;
            let payload;
            if (url.pathname === "/api/request") {
                kind = "request";
                payload = { text: body.text };
            } else if (url.pathname === "/api/decision") {
                kind = "decision";
                payload = body;
            } else if (url.pathname === "/api/control") {
                kind = "control";
                payload = body;
            } else {
                json(response, 404, { error: "not found" });
                return;
            }
            const correlationId = `canvas:${randomUUID()}`;
            const seq = await bridge.ingress({
                correlationId,
                provenance: "direct-user",
                kind,
                payload,
                sessionId,
                messageId: correlationId,
            });
            json(response, 200, { schema: "firstmate.copilot-app-submit.v1", seq });
        } catch (error) {
            log(`Canvas request refused: ${error.message}`, "warning");
            json(response, 400, { error: error.message });
        }
    });
    server.maxHeadersCount = 32;
    server.requestTimeout = 10_000;
    server.headersTimeout = 10_000;
    await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen({ host: "127.0.0.1", port: 0, exclusive: true }, resolve);
    });
    const address = server.address();
    if (!address || typeof address === "string" || address.address !== "127.0.0.1") {
        await new Promise((resolve) => server.close(resolve));
        throw new Error("canvas server did not bind an IPv4 loopback address");
    }
    expectedHost = `127.0.0.1:${address.port}`;
    return {
        url: `http://${expectedHost}/?t=${token}`,
        close: () => new Promise((resolve) => server.close(resolve)),
    };
}
