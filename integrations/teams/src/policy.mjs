const LOCAL_CONFIRMATION =
  "This request cannot be authorized from Teams. Confirm the exact action in the trusted local Firstmate session.";

const RESTRICTED = [
  ["merge or pull-request approval", /\b(?:merge|approve|complete|land)\b[\s\S]{0,80}\b(?:pr|pull request|change)\b|\b(?:pr|pull request)\b[\s\S]{0,80}\bmerge\b/i],
  ["release or production deployment", /\b(?:release|publish|deploy|rollout|ship)\b[\s\S]{0,80}\b(?:production|prod|release|package|app)\b|^(?:release|publish|deploy|rollout)\b/i],
  ["destructive or irreversible operation", /\b(?:delete|destroy|wipe|purge|drop|erase|decommission|terminate)\b|\brm\s+(?:-[a-z]*r[a-z]*f?|-[a-z]*f[a-z]*r)\b|\bgit\s+push\b[^\r\n]{0,80}\s--force(?:-with-lease)?\b|\b(?:reset\s+--hard|force[- ]?push|overwrite history)\b/i],
  ["discarding local work", /\b(?:discard|throw away|remove)\b[\s\S]{0,80}\b(?:local|uncommitted|unlanded|changes?|work)\b/i],
  ["credential, MFA, or consent operation", /\b(?:password|credential|client secret|access token|refresh token|private key|certificate private|mfa|multi-factor|admin consent|oauth consent)\b/i],
  ["role, permission, or tenant operation", /\b(?:role assignment|grant (?:me |us |them )?(?:access|permission)|revoke (?:access|permission)|tenant change|switch tenant|directory role|access package)\b|\b(?:assign|give|make)\b[\s\S]{0,80}\b(?:owner|contributor|administrator|admin|role)\b/i],
  ["network operation", /\b(?:firewall|network security group|\bnsg\b|vpn|ssh|public endpoint|inbound port|dns change|route table|private endpoint)\b/i],
  ["infrastructure creation", /\b(?:terraform apply|az deployment|create|provision)\b[\s\S]{0,100}\b(?:infrastructure|azure resource|resource group|subscription|service bus|queue|bot registration|app registration|key vault|container app)\b/i],
  ["security-sensitive operation", /\b(?:disable|bypass|weaken|change|update|rotate)\b[\s\S]{0,80}\b(?:security|policy|conditional access|encryption|retention|dlp|certificate)\b/i],
];

export function classifyAuthority(text) {
  const normalized = String(text || "").replace(/\s+/g, " ").trim();
  for (const [category, pattern] of RESTRICTED) {
    if (pattern.test(normalized)) {
      return { allowed: false, category, response: LOCAL_CONFIRMATION };
    }
  }
  return { allowed: true, category: "untrusted Teams intent" };
}

export function redactReply(text, maxBytes = 2500) {
  let value = String(text || "")
    .replace(/\r\n?/g, "\n")
    .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "")
    .trim();
  const sensitive = [
    /-----BEGIN [A-Z0-9 ]*(?:PRIVATE KEY|CERTIFICATE)-----/i,
    /\bBearer\s+[A-Za-z0-9._~+\/-]+=*/i,
    /(?:["']?(?:password|passwd|secret|token|access[_ -]?token|refresh[_ -]?token|api[_ -]?key|client[_ -]?secret)["']?)\s*[:=]\s*(?:"[^"\r\n]+"|'[^'\r\n]+'|[^\s,;}]+)/i,
    /\b(?:AccountKey|SharedAccessKey|SharedAccessSignature)\s*=/i,
    /\b(?:AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|AZURE_CLIENT_SECRET|GOOGLE_API_KEY)\s*[:=]\s*\S+/i,
    /\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,})\b/i,
    /\b(?:xox[a-z]-[A-Za-z0-9-]{10,}|glpat-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{20,})\b/i,
    /\b[A-Za-z0-9]{76}AZDO[A-Za-z0-9]{4}\b/,
    /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/,
    /\b[a-z][a-z0-9+.-]*:\/\/[^\s\/:@]+:[^\s\/@]+@[^\s]+/i,
    /https?:\/\/\S*[?&](?:sig|signature)=[^&\s]+/i,
    /(?:^|[\s"'=:])(?=[^\s"'<>]{0,2048}(?:sig=|&sig=))(?=[^\s"'<>]{0,2048}(?:(?:sv|se|sp)=|&(?:sv|se|sp)=))[^\s"'<>]{1,2048}/i,
    /\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\b/,
  ];
  if (sensitive.some((pattern) => pattern.test(value))) {
    return "A result is available in the trusted local Firstmate session. Teams delivery was withheld because the result may contain sensitive data.";
  }
  if (!value) {
    return "The request finished without a Teams-safe summary. Review it in the trusted local Firstmate session.";
  }
  const suffix = "\n\n[Reply truncated. Review the trusted local Firstmate session for the rest.]";
  if (Buffer.byteLength(value, "utf8") <= maxBytes) return value;
  let end = Math.max(0, maxBytes - Buffer.byteLength(suffix, "utf8"));
  while (Buffer.byteLength(value.slice(0, end), "utf8") > maxBytes - Buffer.byteLength(suffix, "utf8")) end -= 1;
  return value.slice(0, end).trimEnd() + suffix;
}
