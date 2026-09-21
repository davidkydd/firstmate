function normalizedServiceOrigin(value) {
  if (typeof value !== "string" || !value) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password) return null;
    return url.origin.toLowerCase();
  } catch {
    return null;
  }
}

export function isChannelServiceActivity(identity, activity) {
  const claimOrigin = normalizedServiceOrigin(identity?.serviceurl);
  const activityOrigin = normalizedServiceOrigin(activity?.serviceUrl);
  return activity?.channelId === "msteams"
    && claimOrigin !== null
    && claimOrigin === activityOrigin;
}

export function requireChannelServiceActivity(request, response, next) {
  if (!isChannelServiceActivity(request.user, request.body)) {
    response.status(403).json({ error: "forbidden" });
    return;
  }
  next();
}
