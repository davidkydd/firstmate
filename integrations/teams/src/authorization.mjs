export function sourceAuthorizationFailure(source, policy) {
  if (source?.tenantId !== policy?.tenantId) return "tenant";
  if (!(policy?.allowedSenderObjectIds instanceof Set)
      || !policy.allowedSenderObjectIds.has(source?.senderAadObjectId)) {
    return "sender";
  }
  if (!(policy?.allowedConversationIds instanceof Set)
      || !policy.allowedConversationIds.has(source?.conversationId)) {
    return "conversation";
  }
  return null;
}
