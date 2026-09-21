# Persistent role definitions

`fleet/agents/` is the tracked source of reusable definitions for named persistent secondmate roles.
A private secondmate home remains the source of instance-specific paths, project registrations, credentials, backlog, watch lists, reports, and history.

Each `fleet/agents/<id>.json` file uses the current role id as both its filename and `id` value.
Aliases and pending rename targets are not accepted.
`fleet/required-secondmates.json` names the definitions that must be present in this distribution.
`fleet/schema/agent.schema.json` documents the supported fields, while `bin/fm-fleet-validate.sh` is the executable validator.

The definition supplies the registry summary and routing scope, the concise domain text inserted into a freshly scaffolded charter, the tracked assets that role requires, and its non-negotiable external-write policy.
The normal charter scaffold remains the only owner of parent-channel, instruction-inbox, idle, delegation, and escalation framework prose.
Detailed domain procedures belong in the internal skill named by the role's assets rather than being copied into the charter.

`bin/fm-brief.sh <id> --secondmate ...` consumes a valid matching definition when no explicit `FM_SECONDMATE_CHARTER` or `FM_SECONDMATE_SCOPE` override is supplied.
Local and remote home seeding pass the current id through to the same definition lookup.
A local tracked-role launch validates that the live charter contains the current role text and current parent status/inbox paths, so an old copied charter must be regenerated before the role can run.
Role sync also moves the two known legacy watch files to `data/prreview.md` and `data/prbabysit.md` byte-for-byte, refusing when both old and current files exist.
`bin/fm-secondmates-projection.sh` can update the summary and scope in a private registry without changing its home, project list, or added date.

A role may declare a `periodic` block with one durable watch file, one or more Markdown section names, and a cadence.
`bin/fm-role-periodic-check.sh sync <id>` installs the current trusted watcher check during secondmate launch.
The check emits one maintenance reminder only when one of those sections contains an active URL item and its cadence has elapsed.
An absent or empty list remains silent, so a persistent secondmate still creates no work on its own.

Use `bin/fm-role-policy.sh check <id> <post-review|vote|merge-ado> [--explicit]` at role-owned external-write boundaries.
The shipped review wrapper calls it before a posting command, and all three definitions permanently deny voting and Azure DevOps completion.
