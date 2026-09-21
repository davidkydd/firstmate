import { lstat, readFile } from "node:fs/promises";
import path from "node:path";
import { RESULT_DELIVERY_MARGIN_DAYS } from "./contracts.mjs";

function requiredString(value, name) {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${name} is required`);
  return value.trim();
}

function guid(value, name) {
  const normalized = requiredString(value, name).toLowerCase();
  if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(normalized)) {
    throw new Error(`${name} must be a canonical GUID`);
  }
  return normalized;
}

function serviceBusNamespace(value, name) {
  const normalized = requiredString(value, name);
  if (!/^[a-z0-9][a-z0-9-]{4,48}[a-z0-9]$/.test(normalized)) {
    throw new Error(`${name} must be an Azure Service Bus namespace name without a DNS suffix`);
  }
  return normalized;
}

function queueName(value, name) {
  const normalized = requiredString(value, name);
  if (!/^[A-Za-z0-9][A-Za-z0-9._~-]{0,258}[A-Za-z0-9]$/.test(normalized)) {
    throw new Error(`${name} is not a supported Service Bus queue name`);
  }
  return normalized;
}

function httpsUrl(value, name) {
  const normalized = requiredString(value, name);
  let url;
  try {
    url = new URL(normalized);
  } catch {
    throw new Error(`${name} must be an HTTPS URL`);
  }
  if (url.protocol !== "https:" || url.username || url.password) throw new Error(`${name} must be an HTTPS URL without credentials`);
  return url.toString();
}

function integer(value, fallback, min, max, name) {
  const number = value === undefined || value === "" ? fallback : Number(value);
  if (!Number.isInteger(number) || number < min || number > max) {
    throw new Error(`${name} must be an integer from ${min} through ${max}`);
  }
  return number;
}

function retentionSettings(retentionValue, messageRetentionValue, retentionName, messageRetentionName) {
  const retentionDays = integer(retentionValue, 30, 3, 365, retentionName);
  const messageRetentionDays = integer(messageRetentionValue, 7, 1, 14, messageRetentionName);
  if (retentionDays <= messageRetentionDays + RESULT_DELIVERY_MARGIN_DAYS) {
    throw new Error(`${retentionName} must exceed ${messageRetentionName} by more than one day`);
  }
  return { retentionDays, messageRetentionDays };
}

function validateReplayRetention(retention, maxActivityAgeSeconds, maxClockSkewSeconds) {
  const resultPublicationSeconds = (
    retention.retentionDays - retention.messageRetentionDays - RESULT_DELIVERY_MARGIN_DAYS
  ) * 86_400;
  if (resultPublicationSeconds <= maxActivityAgeSeconds + maxClockSkewSeconds) {
    throw new Error("FM_TEAMS_RETENTION_DAYS must cover the activity replay window, queue retention, and delivery margin");
  }
}

function allowedSenders(value, name) {
  const entries = Array.isArray(value) ? value : String(value || "").split(",");
  const normalized = entries.map((entry) => String(entry).trim()).filter(Boolean);
  if (normalized.length === 0) throw new Error(`${name} must name at least one sender object id`);
  return new Set(normalized.map((entry) => guid(entry, name)));
}

function allowedConversations(value, name) {
  const entries = Array.isArray(value) ? value : String(value || "").split(",");
  const normalized = entries.map((entry) => String(entry).trim()).filter(Boolean);
  if (normalized.length === 0 || normalized.some((entry) => entry.length > 1024 || /[\x00-\x1f\x7f]/.test(entry))) {
    throw new Error(`${name} must name at least one bounded conversation id`);
  }
  return new Set(normalized);
}

export function cloudConfig(env = process.env) {
  if (env.FM_TEAMS_ENABLED !== "1") throw new Error("Teams integration is disabled; set FM_TEAMS_ENABLED=1 explicitly");
  const retention = retentionSettings(
    env.FM_TEAMS_RETENTION_DAYS,
    env.FM_TEAMS_MESSAGE_RETENTION_DAYS,
    "FM_TEAMS_RETENTION_DAYS",
    "FM_TEAMS_MESSAGE_RETENTION_DAYS",
  );
  const maxActivityAgeSeconds = integer(env.FM_TEAMS_MAX_ACTIVITY_AGE_SECONDS, 900, 60, 604800, "FM_TEAMS_MAX_ACTIVITY_AGE_SECONDS");
  const maxClockSkewSeconds = integer(env.FM_TEAMS_MAX_CLOCK_SKEW_SECONDS, 300, 0, 3600, "FM_TEAMS_MAX_CLOCK_SKEW_SECONDS");
  validateReplayRetention(retention, maxActivityAgeSeconds, maxClockSkewSeconds);
  return {
    enabled: true,
    tenantId: guid(env.FM_TEAMS_TENANT_ID, "FM_TEAMS_TENANT_ID"),
    appId: guid(env.FM_TEAMS_BOT_APP_ID, "FM_TEAMS_BOT_APP_ID"),
    botId: requiredString(env.FM_TEAMS_BOT_RECIPIENT_ID, "FM_TEAMS_BOT_RECIPIENT_ID"),
    allowedSenderObjectIds: allowedSenders(env.FM_TEAMS_ALLOWED_SENDER_IDS, "FM_TEAMS_ALLOWED_SENDER_IDS"),
    allowedConversationIds: allowedConversations(env.FM_TEAMS_ALLOWED_CONVERSATION_IDS, "FM_TEAMS_ALLOWED_CONVERSATION_IDS"),
    serviceBusNamespace: serviceBusNamespace(env.FM_TEAMS_SERVICE_BUS_NAMESPACE, "FM_TEAMS_SERVICE_BUS_NAMESPACE"),
    requestQueue: queueName(env.FM_TEAMS_REQUEST_QUEUE, "FM_TEAMS_REQUEST_QUEUE"),
    resultQueue: queueName(env.FM_TEAMS_RESULT_QUEUE, "FM_TEAMS_RESULT_QUEUE"),
    tableEndpoint: httpsUrl(env.FM_TEAMS_TABLE_ENDPOINT, "FM_TEAMS_TABLE_ENDPOINT"),
    tableName: requiredString(env.FM_TEAMS_TABLE_NAME, "FM_TEAMS_TABLE_NAME"),
    keyVaultUrl: httpsUrl(env.FM_TEAMS_KEY_VAULT_URL, "FM_TEAMS_KEY_VAULT_URL"),
    certificateName: queueName(env.FM_TEAMS_CERTIFICATE_NAME, "FM_TEAMS_CERTIFICATE_NAME"),
    managedIdentityClientId: guid(env.FM_TEAMS_MANAGED_IDENTITY_CLIENT_ID, "FM_TEAMS_MANAGED_IDENTITY_CLIENT_ID"),
    maxActivityBytes: integer(env.FM_TEAMS_MAX_ACTIVITY_BYTES, 8192, 256, 16384, "FM_TEAMS_MAX_ACTIVITY_BYTES"),
    maxRequestBytes: integer(env.FM_TEAMS_MAX_REQUEST_BYTES, 4096, 128, 8192, "FM_TEAMS_MAX_REQUEST_BYTES"),
    maxReplyBytes: integer(env.FM_TEAMS_MAX_REPLY_BYTES, 2500, 128, 4096, "FM_TEAMS_MAX_REPLY_BYTES"),
    maxActivityAgeSeconds,
    maxClockSkewSeconds,
    rateLimitPerMinute: integer(env.FM_TEAMS_RATE_LIMIT_PER_MINUTE, 10, 1, 120, "FM_TEAMS_RATE_LIMIT_PER_MINUTE"),
    ...retention,
    port: integer(env.PORT, 8080, 1, 65535, "PORT"),
  };
}

export async function connectorConfig(home, overridePath) {
  const file = overridePath || path.join(home, "config", "teams.json");
  const info = await lstat(file);
  if (!info.isFile() || info.isSymbolicLink()) throw new Error(`${file} must be a regular file, not a symlink`);
  if ((info.mode & 0o077) !== 0) throw new Error(`${file} must not be readable or writable by group or others`);
  const raw = JSON.parse(await readFile(file, "utf8"));
  const allowed = new Set(["schema", "enabled", "tenantId", "allowedSenderObjectIds", "allowedConversationIds", "serviceBusNamespace", "requestQueue", "resultQueue", "credential", "retentionDays", "messageRetentionDays"]);
  const extras = Object.keys(raw).filter((key) => !allowed.has(key));
  if (extras.length) throw new Error(`${file} contains unsupported fields: ${extras.join(", ")}`);
  if (raw.schema !== "firstmate.teams.config.v1") throw new Error(`${file} has an unsupported schema`);
  if (raw.enabled !== true) throw new Error(`Teams integration is disabled in ${file}`);
  if (raw.credential !== "azure-cli") throw new Error(`${file} credential must be azure-cli`);
  const retention = retentionSettings(raw.retentionDays, raw.messageRetentionDays, "retentionDays", "messageRetentionDays");
  return {
    enabled: true,
    tenantId: guid(raw.tenantId, "tenantId"),
    allowedSenderObjectIds: allowedSenders(raw.allowedSenderObjectIds, "allowedSenderObjectIds"),
    allowedConversationIds: allowedConversations(raw.allowedConversationIds, "allowedConversationIds"),
    serviceBusNamespace: serviceBusNamespace(raw.serviceBusNamespace, "serviceBusNamespace"),
    requestQueue: queueName(raw.requestQueue, "requestQueue"),
    resultQueue: queueName(raw.resultQueue, "resultQueue"),
    credential: raw.credential,
    ...retention,
    file,
  };
}
