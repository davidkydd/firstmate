---
name: prbabysit
description: >-
  Internal operating procedure for the prbabysit persistent secondmate.
  Load when the main firstmate routes an Azure DevOps pull request for ongoing
  content-gate, reviewer-state, or active-thread maintenance, and on that role's
  periodic maintenance reminder.
user-invocable: false
metadata:
  internal: true
---

# Azure DevOps pull-request maintenance

This skill is the single owner of the `prbabysit` role's domain procedure.
The generated secondmate charter owns the normal parent-channel, delegation, escalation, and idle framework.

## Durable watch

The durable watch lives at `data/prbabysit.md` in the role home.
Its active entries are one Markdown item per full Azure DevOps pull-request URL under an exact `## Watched` heading:

```markdown
## Watched
- https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<id>
```

Historical notes may remain elsewhere in the file, but they are not active work.
A request from the main firstmate adds or removes an entry.
An empty `## Watched` section is healthy and creates no work.
On restart, reconstruct the maintenance set only from that section, reconcile any already-owned workers, and otherwise wait silently.

The trusted periodic role check emits a reminder only while this section contains an active URL.
Treat the reminder as permission to run one bounded full pass over the recorded entries, not as permission to add a pull request or invent adjacent work.

## Maintenance pass

For each recorded pull request:

1. Resolve the repository and current source tip from the full URL, then read the live pull-request status and current policy evaluations through Azure CLI read operations.
2. Drop a completed or abandoned pull request from `## Watched` without reporting routine cleanup.
3. Classify required build, test, coverage, component-governance, and comparable code-derived policies as content gates.
4. Treat reviewer votes, minimum-reviewer policies, comment requirements, proof-of-presence checks, ownership checks, work-item links, and merge-strategy selection as human gates.
5. Report content readiness separately from human approval, and never describe a pull request as merge-ready while a required reviewer or unresolved blocking thread is missing.
6. Requeue an expired, not-current, or never-run required content evaluation only through `bin/fm-scm-lib.sh ado-requeue-expired` or the exact Azure CLI policy-queue operation that helper documents, using the bounded role-local ledger.
7. Do not requeue a current genuine failure merely to make it run again.
8. Read the failed build logs, confirm the tested source tip, and separate transient infrastructure, target-branch failure, and pull-request-caused failure before deciding what to do.
9. Route a small mechanical pull-request fix to one isolated worker through the ordinary Firstmate lifecycle; route a substantial product change or an unresolved product, destructive, irreversible, or security-sensitive choice back to the main firstmate.
10. Read active review threads on every pass, route determinable fixes to a worker, and escalate only the residual question that cannot be settled from the repository and evidence.

A target-branch failure stays an external dependency with a concrete recheck predicate.
When that predicate clears, refresh the affected evaluation and close the external wait without asking again.

Current Firstmate does not yet register Azure DevOps pull requests through `bin/fm-pr-check.sh`.
Do not route an Azure DevOps URL into that GitHub-only registration path or claim that normal Firstmate merge monitoring owns it.
The role's periodic check and this bounded Azure CLI procedure are the supported maintenance path until observation-only ADO registration lands separately.

## External-write boundary

Never cast a reviewer vote, approve a pull request, merge it, or complete it.
Run `bin/fm-role-policy.sh check prbabysit vote` or `bin/fm-role-policy.sh check prbabysit merge-ado` before either class of action; both must refuse.
Never bypass that refusal with a direct Azure CLI or REST call.

Resolving a thread is allowed only after the underlying concern is actually addressed and the role has verified that result.
A description or branch change is performed through the narrow current owner for that write, never as an improvised substitute for a worker.
Every delegated worker instruction repeats the no-vote and no-completion boundaries.

Report only a new content-ready outcome, a log-grounded failure that needs main-firstmate action, an unavailable required credential, an exhausted bounded retry, or a genuine decision.
Routine polling, successful requeues, running gates, unchanged approval state, and an empty watch stay silent.
