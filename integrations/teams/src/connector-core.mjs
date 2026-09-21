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
    if (authority.decision === "refuse") {
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

    if (authority.decision !== "require-local-approval") {
      throw new Error("Teams authority classifier returned an unsupported decision");
    }

    if (!record.reviewInboxId) {
      const reviewInboxId = await this.inbox.requestApproval(request.requestId);
      record = await this.store.update(request.requestId, {
        state: "awaiting-local-approval",
        approvalStatus: "pending",
        reviewInboxId,
      });
    }
    if (!record.reviewInboxId || !["pending", "delivering", "approved"].includes(record.approvalStatus)) {
      throw new Error("Teams request is missing its durable local approval gate");
    }
    const response = "The request reached this Mac and entered the trusted local Firstmate approval flow.";
    await this.sendResult(record, "accepted", response);
    return {
      disposition: record.approvalStatus === "approved" ? "approved" : "pending-approval",
      requestId: request.requestId,
      inboxId: record.approvedInboxId || record.reviewInboxId,
    };
  }
}
