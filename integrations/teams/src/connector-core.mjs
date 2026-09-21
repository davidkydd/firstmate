import { sourceAuthorizationFailure } from "./authorization.mjs";
import { ContractError, makeResult, MAX_RESULT_BYTES, sameSource, validateRequest } from "./contracts.mjs";
import { classifyAuthority, redactReply } from "./policy.mjs";

export class ConnectorPolicyError extends Error {
  constructor(message) {
    super(message);
    this.name = "ConnectorPolicyError";
    this.permanent = true;
  }
}

function validateConnectorIdentity(request, config) {
  const authorizationFailure = sourceAuthorizationFailure(request.source, config);
  if (authorizationFailure) {
    throw new ConnectorPolicyError(`queued request ${authorizationFailure} is not authorized`);
  }
}

export class ConnectorCore {
  constructor({ config, store, inbox, statusReader, resultSender, now = () => new Date() }) {
    this.config = config;
    this.store = store;
    this.inbox = inbox;
    this.statusReader = statusReader;
    this.resultSender = resultSender;
    this.now = now;
  }

  async sendResult(record, outcome, text) {
    const result = makeResult(record.request, outcome, redactReply(text, MAX_RESULT_BYTES), { createdAt: this.now().toISOString() });
    return (await this.store.queueResult(result, (value) => this.resultSender.send(value))).result;
  }

  async process(rawRequest) {
    const request = validateRequest(rawRequest);
    validateConnectorIdentity(request, this.config);
    if (this.now().getTime() >= Date.parse(request.resultDeadline)) {
      throw new ContractError("expired", "the Teams request result publication deadline has passed");
    }
    const capture = await this.store.capture(request);
    let record = capture.record;
    if (!sameSource(record.request.source, request.source)) {
      throw new Error("local request source does not match the queued request");
    }

    if (record.state === "result-queued") {
      return { disposition: "duplicate", requestId: request.requestId };
    }

    if (request.command.kind === "status") {
      if (record.state === "received") {
        const text = await this.statusReader.counts();
        record = await this.store.update(request.requestId, { state: "status-ready", responseText: text });
      }
      await this.sendResult(record, "status", record.responseText);
      return { disposition: "status", requestId: request.requestId };
    }

    const authority = classifyAuthority(request.command.text);
    if (!authority.allowed) {
      if (record.state === "received") {
        record = await this.store.update(request.requestId, {
          state: "refused",
          authorityCategory: authority.category,
          responseText: authority.response,
        });
      }
      await this.sendResult(record, "refused", record.responseText);
      return { disposition: "refused", requestId: request.requestId, category: authority.category };
    }

    if (record.state === "received") {
      const inboxId = await this.inbox.deliver(request);
      record = await this.store.update(request.requestId, { state: "accepted", inboxId });
    }
    if (!record.inboxId) {
      throw new Error("accepted Teams request is missing its durable Firstmate inbox id");
    }
    const response = "The request is in the trusted local Firstmate session.";
    await this.sendResult(record, "accepted", response);
    return { disposition: "accepted", requestId: request.requestId, inboxId: record.inboxId };
  }
}
