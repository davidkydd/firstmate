export function parsePublishArgs(args) {
  const parsed = {};
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    const value = args[index + 1];
    if (!value || !["--request-id", "--outcome", "--text-file"].includes(key)) {
      throw new Error("publish-result requires --request-id, --outcome, and --text-file");
    }
    const name = key.slice(2);
    if (Object.hasOwn(parsed, name)) {
      throw new Error(`publish-result option ${key} may be specified only once`);
    }
    parsed[name] = value;
  }
  if (!parsed["request-id"] || !["completed", "refused", "failed"].includes(parsed.outcome) || !parsed["text-file"]) {
    throw new Error("publish-result requires --request-id, --outcome completed|refused|failed, and --text-file");
  }
  return parsed;
}
