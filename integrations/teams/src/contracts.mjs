import { createHash } from "node:crypto";

export const REQUEST_SCHEMA = "firstmate.teams.request.v1";
export const RESULT_SCHEMA = "firstmate.teams.result.v1";
export const MAX_REQUEST_BYTES = 8192;
export const MAX_RESULT_BYTES = 4096;
export const RESULT_DELIVERY_MARGIN_DAYS = 1;

const SOURCE_KEYS = [
  "tenantId",
  "senderId",
  "senderAadObjectId",
  "conversationId",
  "conversationType",
  "activityId",
  "activityTimestamp",
  "serviceUrl",
  "botId",
  "channelId",
];

const CONVERSATION_TYPES = new Set(["personal", "groupChat", "channel"]);
const REQUEST_KINDS = new Set(["status", "work"]);
const RESULT_OUTCOMES = new Set(["accepted", "status", "completed", "refused", "failed"]);

export class ContractError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "ContractError";
    this.code = code;
  }
}

function requireObject(value, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ContractError("malformed", `${name} must be an object`);
  }
  return value;
}

function requireString(value, name, maxLength = 2048) {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) {
    throw new ContractError("malformed", `${name} must be a non-empty bounded string`);
  }
  if (/\u0000/.test(value)) {
    throw new ContractError("malformed", `${name} contains a NUL byte`);
  }
  return value;
}

function requireExactKeys(value, allowed, name) {
  const extras = Object.keys(value).filter((key) => !allowed.includes(key));
  if (extras.length > 0) {
    throw new ContractError("malformed", `${name} contains unsupported fields: ${extras.join(", ")}`);
  }
}

function requireIsoDate(value, name) {
  requireString(value, name, 64);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/.test(value) || Number.isNaN(Date.parse(value))) {
    throw new ContractError("malformed", `${name} must be an RFC 3339 UTC timestamp`);
  }
  return value;
}

function requireId(value, name) {
  requireString(value, name, 1024);
  if (/[\x00-\x1f\x7f]/.test(value)) {
    throw new ContractError("malformed", `${name} contains a control character`);
  }
  return value;
}

function byteLength(value) {
  return Buffer.byteLength(value, "utf8");
}

function deriveRequestId(source) {
  const identity = [
    source?.tenantId,
    source?.senderAadObjectId,
    source?.conversationId,
    source?.activityId,
  ].join("\u001f");
  return `tm_${createHash("sha256").update(identity, "utf8").digest("hex")}`;
}

function deriveResultId(requestId, outcome) {
  return `tr_${createHash("sha256").update(`${requestId}\u001f${outcome}`, "utf8").digest("hex")}`;
}

export function requestIdFor(source) {
  validateSource(source);
  return deriveRequestId(source);
}

export function resultIdFor(requestId, outcome) {
  requireId(requestId, "requestId");
  if (!RESULT_OUTCOMES.has(outcome)) {
    throw new ContractError("malformed", "unsupported result outcome");
  }
  return deriveResultId(requestId, outcome);
}

export function bodySha256(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

export function validateSource(source) {
  requireObject(source, "source");
  requireExactKeys(source, SOURCE_KEYS, "source");
  for (const key of SOURCE_KEYS) {
    requireId(source[key], `source.${key}`);
  }
  if (!CONVERSATION_TYPES.has(source.conversationType)) {
    throw new ContractError("malformed", "source.conversationType is unsupported");
  }
  if (source.channelId !== "msteams") {
    throw new ContractError("identity", "source.channelId must be msteams");
  }
  requireIsoDate(source.activityTimestamp, "source.activityTimestamp");
  let url;
  try {
    url = new URL(source.serviceUrl);
  } catch {
    throw new ContractError("malformed", "source.serviceUrl must be an HTTPS URL");
  }
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) {
    throw new ContractError("malformed", "source.serviceUrl must be an HTTPS origin or path without credentials or query data");
  }
  return source;
}

export function makeRequest({ source, kind, text, receivedAt = new Date().toISOString(), resultDeadline }) {
  return validateRequest({
    schema: REQUEST_SCHEMA,
    requestId: deriveRequestId(source),
    receivedAt,
    resultDeadline,
    source: { ...source },
    command: { kind, text },
    bodySha256: bodySha256(typeof text === "string" ? text : ""),
  });
}

export function validateRequest(value) {
  const request = requireObject(value, "request");
  requireExactKeys(request, ["schema", "requestId", "receivedAt", "resultDeadline", "source", "command", "bodySha256"], "request");
  if (request.schema !== REQUEST_SCHEMA) {
    throw new ContractError("schema", "unsupported request schema");
  }
  requireId(request.requestId, "requestId");
  requireIsoDate(request.receivedAt, "receivedAt");
  requireIsoDate(request.resultDeadline, "resultDeadline");
  if (Date.parse(request.resultDeadline) <= Date.parse(request.receivedAt)) {
    throw new ContractError("malformed", "resultDeadline must be later than receivedAt");
  }
  validateSource(request.source);
  const command = requireObject(request.command, "command");
  requireExactKeys(command, ["kind", "text"], "command");
  if (!REQUEST_KINDS.has(command.kind)) {
    throw new ContractError("malformed", "unsupported request command kind");
  }
  requireString(command.text, "command.text", MAX_REQUEST_BYTES);
  if (byteLength(command.text) > MAX_REQUEST_BYTES) {
    throw new ContractError("too-large", "request text exceeds the protocol limit");
  }
  if (!/^[a-f0-9]{64}$/.test(request.bodySha256) || request.bodySha256 !== bodySha256(command.text)) {
    throw new ContractError("integrity", "request body hash does not match its text");
  }
  if (request.requestId !== deriveRequestId(request.source)) {
    throw new ContractError("identity", "request id does not match its immutable Teams identity");
  }
  return request;
}

export function makeResult(request, outcome, text, { createdAt = new Date().toISOString() } = {}) {
  validateRequest(request);
  requireIsoDate(createdAt, "createdAt");
  if (Date.parse(createdAt) >= Date.parse(request.resultDeadline)) {
    throw new ContractError("expired", "the Teams request result publication deadline has passed");
  }
  return validateResult({
    schema: RESULT_SCHEMA,
    resultId: deriveResultId(request?.requestId, outcome),
    requestId: request?.requestId,
    createdAt,
    outcome,
    terminal: ["status", "completed", "refused", "failed"].includes(outcome),
    source: { ...request?.source },
    text,
  });
}

export function validateResult(value) {
  const result = requireObject(value, "result");
  requireExactKeys(result, ["schema", "resultId", "requestId", "createdAt", "outcome", "terminal", "source", "text"], "result");
  if (result.schema !== RESULT_SCHEMA) {
    throw new ContractError("schema", "unsupported result schema");
  }
  requireId(result.requestId, "requestId");
  requireId(result.resultId, "resultId");
  requireIsoDate(result.createdAt, "createdAt");
  validateSource(result.source);
  if (!RESULT_OUTCOMES.has(result.outcome)) {
    throw new ContractError("malformed", "unsupported result outcome");
  }
  if (typeof result.terminal !== "boolean" || result.terminal !== ["status", "completed", "refused", "failed"].includes(result.outcome)) {
    throw new ContractError("malformed", "result terminal flag does not match its outcome");
  }
  requireString(result.text, "result.text", MAX_RESULT_BYTES);
  if (byteLength(result.text) > MAX_RESULT_BYTES) {
    throw new ContractError("too-large", "result text exceeds the protocol limit");
  }
  if (result.requestId !== deriveRequestId(result.source)) {
    throw new ContractError("identity", "result request id does not match its immutable Teams identity");
  }
  if (result.resultId !== deriveResultId(result.requestId, result.outcome)) {
    throw new ContractError("identity", "result id is not the deterministic id for this outcome");
  }
  return result;
}

export function sameSource(left, right) {
  try {
    validateSource(left);
    validateSource(right);
  } catch {
    return false;
  }
  return SOURCE_KEYS.every((key) => left[key] === right[key]);
}
