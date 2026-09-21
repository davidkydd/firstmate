import { sourceAuthorizationFailure } from "./authorization.mjs";
import {
  ContractError,
  makeRequest,
  MAX_REQUEST_BYTES,
  RESULT_DELIVERY_MARGIN_DAYS,
} from "./contracts.mjs";

export class IgnoredActivity extends Error {
  constructor(reason) {
    super(reason);
    this.name = "IgnoredActivity";
  }
}

const ALLOWED_ENTITIES = new Set(["mention"]);
const SAFE_ENTITIES = new Map([
  ["&amp;", "&"],
  ["&lt;", "<"],
  ["&gt;", ">"],
  ["&quot;", '"'],
  ["&#39;", "'"],
  ["&nbsp;", " "],
]);

function requiredString(value, name, max = 2048) {
  if (typeof value !== "string" || value.length === 0 || value.length > max) {
    throw new ContractError("malformed", `${name} is missing or too long`);
  }
  if (/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value)) {
    throw new ContractError("malformed", `${name} contains a control character`);
  }
  return value;
}

export function canonicalGuid(value) {
  if (typeof value !== "string") return null;
  const normalized = value.toLowerCase();
  return /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(normalized) ? normalized : null;
}

function requiredGuid(value, name) {
  const normalized = canonicalGuid(requiredString(value, name, 128));
  if (!normalized) throw new ContractError("identity", `${name} is not a valid GUID`);
  return normalized;
}

function normalizeConversationType(activity) {
  const raw = activity?.conversation?.conversationType;
  if (raw === "personal") return "personal";
  if (raw === "groupChat") return "groupChat";
  if (raw === "channel") return "channel";
  if (raw === "groupchat") return "groupChat";
  if (raw === "Channel") return "channel";
  throw new ContractError("unsupported-conversation", "Teams conversation type is unsupported");
}

function tenantId(activity) {
  const conversationTenant = activity?.conversation?.tenantId;
  const channelTenant = activity?.channelData?.tenant?.id;
  const normalizedConversationTenant = conversationTenant === undefined
    ? undefined
    : requiredGuid(conversationTenant, "conversation tenant id");
  const normalizedChannelTenant = channelTenant === undefined
    ? undefined
    : requiredGuid(channelTenant, "channel tenant id");
  const value = normalizedConversationTenant || normalizedChannelTenant;
  if (!value) throw new ContractError("identity", "tenant id is missing");
  if (normalizedConversationTenant && normalizedChannelTenant
      && normalizedConversationTenant !== normalizedChannelTenant) {
    throw new ContractError("identity", "Teams tenant identity is inconsistent");
  }
  return value;
}

function unescapeSafeEntities(value) {
  return value.replace(/&(?:amp|lt|gt|quot|#39|nbsp);/g, (entity) => SAFE_ENTITIES.get(entity));
}

function stripBotMention(text, entities, botId) {
  const mentions = entities.filter((entity) => entity?.type === "mention");
  const botMentions = mentions.filter((entity) => entity?.mentioned?.id === botId);
  if (botMentions.length > 1 || mentions.length !== botMentions.length) {
    throw new ContractError("rich-content", "only one mention of this bot is supported");
  }
  if (botMentions.length === 0) {
    return { text, mentioned: false };
  }
  const mentionText = requiredString(botMentions[0].text, "mention text", 256);
  const trimmed = text.trimStart();
  if (!trimmed.startsWith(mentionText)) {
    throw new ContractError("malformed-mention", "the bot mention must be the first message element");
  }
  return { text: trimmed.slice(mentionText.length).trimStart(), mentioned: true };
}

export function parseTeamsActivity(activity, config, now = new Date()) {
  if (!activity || typeof activity !== "object" || Array.isArray(activity)) {
    throw new ContractError("malformed", "activity must be an object");
  }
  if (activity.type !== "message" || activity.channelId !== "msteams") {
    throw new IgnoredActivity("not a Teams message activity");
  }
  const botId = requiredString(config.botId, "configured bot id", 256);
  const fromId = requiredString(activity?.from?.id, "sender id", 1024);
  if (fromId === botId || fromId === activity?.recipient?.id) {
    throw new IgnoredActivity("bot-authored activity");
  }
  if (activity?.recipient?.id !== botId) {
    throw new ContractError("identity", "activity recipient does not match this bot");
  }

  const sourceTenant = tenantId(activity);
  const senderAadObjectId = requiredGuid(activity?.from?.aadObjectId, "sender Entra object id");
  const conversationType = normalizeConversationType(activity);
  const conversationId = requiredString(activity?.conversation?.id, "conversation id", 1024);
  const authorizationFailure = sourceAuthorizationFailure({
    tenantId: sourceTenant,
    senderAadObjectId,
    conversationId,
  }, config);
  if (authorizationFailure) {
    throw new ContractError("identity", `activity ${authorizationFailure} is not authorized`);
  }
  if (activity.attachments?.length || activity.value !== undefined || activity.suggestedActions) {
    throw new ContractError("rich-content", "attachments, cards, and submitted values are not accepted");
  }
  const entities = activity.entities || [];
  if (!Array.isArray(entities) || entities.some((entity) => !ALLOWED_ENTITIES.has(entity?.type))) {
    throw new ContractError("rich-content", "unsupported message entities are not accepted");
  }
  let text = requiredString(activity.text, "activity text", Math.max(MAX_REQUEST_BYTES * 2, 16384));
  if (Buffer.byteLength(text, "utf8") > config.maxActivityBytes) {
    throw new ContractError("too-large", "activity text exceeds the configured size limit");
  }
  const mention = stripBotMention(text, entities, botId);
  text = mention.text;
  if (conversationType !== "personal" && !mention.mentioned) {
    throw new IgnoredActivity("group and channel messages must mention the bot");
  }
  if (/<[^>]*>|[<>]/.test(text)) {
    throw new ContractError("rich-content", "message markup other than the bot mention is not accepted");
  }
  if (/&[^;\s]{1,20};/.test(text.replace(/&(?:amp|lt|gt|quot|#39|nbsp);/g, ""))) {
    throw new ContractError("rich-content", "unsupported encoded markup is not accepted");
  }
  text = unescapeSafeEntities(text).replace(/\r\n?/g, "\n").trim();
  const match = /^\/firstmate(?:[ \t\n]+([\s\S]+))?$/.exec(text);
  if (!match || !match[1]?.trim()) {
    throw new ContractError("command", "use /firstmate followed by a request");
  }
  const commandText = match[1].trim();
  if (Buffer.byteLength(commandText, "utf8") > Math.min(config.maxRequestBytes, MAX_REQUEST_BYTES)) {
    throw new ContractError("too-large", "request exceeds the configured size limit");
  }

  const timestamp = requiredString(activity.timestamp, "activity timestamp", 64);
  const parsedTimestamp = Date.parse(timestamp);
  if (Number.isNaN(parsedTimestamp)) {
    throw new ContractError("malformed", "activity timestamp is invalid");
  }
  const ageMilliseconds = now.getTime() - parsedTimestamp;
  if (ageMilliseconds < -config.maxClockSkewSeconds * 1000 || ageMilliseconds > config.maxActivityAgeSeconds * 1000) {
    throw new ContractError("replay-window", "activity timestamp is outside the accepted replay window");
  }

  const source = {
    tenantId: sourceTenant,
    senderId: fromId,
    senderAadObjectId,
    conversationId,
    conversationType,
    activityId: requiredString(activity.id, "activity id", 1024),
    activityTimestamp: new Date(parsedTimestamp).toISOString(),
    serviceUrl: requiredString(activity.serviceUrl, "service URL", 2048),
    botId,
    channelId: "msteams",
  };
  const kind = /^status\s*$/i.test(commandText) ? "status" : "work";
  const retentionDays = config.retentionDays ?? 30;
  const messageRetentionDays = config.messageRetentionDays ?? 7;
  const resultDeadline = new Date(
    now.getTime() + (retentionDays - messageRetentionDays - RESULT_DELIVERY_MARGIN_DAYS) * 86_400_000,
  ).toISOString();
  return makeRequest({
    source,
    kind,
    text: commandText,
    receivedAt: now.toISOString(),
    resultDeadline,
  });
}

export function replyActivity(activityId, text) {
  return {
    type: "message",
    text,
    replyToId: activityId,
  };
}
