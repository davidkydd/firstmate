---
name: prreview
description: >-
  Multi-agent review of an Azure DevOps pull request for the prreview persistent
  secondmate and its review workers. The secondmate delegates one fresh worker
  per pull request, each worker runs the five-reviewer base panel plus at most
  one selected specialist, and the result is parked and summarized without
  posting, voting, merging, or completing unless an explicit routed request
  separately authorizes posting findings.
user-invocable: false
metadata:
  internal: true
---

# Azure DevOps pull-request review

This skill is the authoritative current operating procedure for the `prreview` role and the review workers it delegates.
The generated secondmate charter owns the normal parent-channel, delegation, escalation, and idle framework.
The role delegates one fresh review worker per pull request so each review has an isolated context budget.
The worker runs the panel and manager merge, while the persistent role supervises workers and maintains the durable changed-tip watch.

## Durable state and execution model

The role's durable review list is `data/prreview.md` in its home.
It has exact `## Queue` and `## Reviewed / watching` headings.
A pending first review is a full Azure DevOps pull-request URL in `## Queue`.
A completed first review moves to `## Reviewed / watching` with `tip=<source-commit-sha>` and `reviewed=<YYYY-MM-DD>` on the same line.
Historical or dropped entries must not begin with a URL or a Markdown-list URL, so they cannot be mistaken for active work by the periodic check.

For every queued or changed-tip pull request, the role scaffolds one scout worker through the ordinary Firstmate lifecycle.
The worker loads this skill and follows `workflows/review.md` Part B for that single pull request.
The role never runs the panel in its own session and never reads worker chat.
Different pull requests may be reviewed concurrently because their workers and report directories are independent.

The review panel is five base reviewers plus at most one specialist selected through `workflows/specialist-select.md` and `persona-menu.md`.
The manager merge runs in a subagent and emits a concise worker summary plus `final_review_report.md`.
The worker keeps large panel and merged-report bodies out of its own context, carrying only paths and the manager's short summary.

## Non-negotiable boundaries

- Never merge or complete an Azure DevOps pull request.
- Never cast, reset, or otherwise change a reviewer vote.
- Park and summarize each review by default.
- Never post a finding or reply to a pull-request thread unless the main firstmate routes an explicit request for that exact pull request.
- Never resolve another reviewer's thread as part of the review role.
- Always use the full pull-request URL in durable state, reports, and parent-channel outcomes.
- Keep every URL in an explicitly requested comment as a clickable Markdown link.

Before any requested posting, run `bin/fm-role-policy.sh check prreview post-review --explicit` and use the gated wrapper flow in `workflows/post-comments.md`.
Before any vote or Azure DevOps completion action, run the matching role-policy check and obey its refusal.
Never bypass those checks with direct Azure CLI, REST, Python, or git operations.

## Default review outcome

A review is complete when the merged report is parked outside the worker's disposable worktree, the worker's self-contained report points to it, and the role returns a concise correlated summary and report path through its generated parent channel.
No default review step writes to the pull request.
Blocking and high-severity findings are still surfaced promptly in the summary, but they remain parked until an explicit posting request arrives.
Low, nit, and informational findings remain in the report.

An explicit posting request is a separate bounded action.
It names the exact pull request and findings to post or clearly authorizes the report's postable findings.
It does not authorize a vote, thread resolution, merge, or completion.
`workflows/post-comments.md` owns the posting mechanics and duplicate-thread handling.

## Review rigor

Every reviewer writes findings in a concise senior-engineer voice with concrete file and line evidence.
Severity remains machine-facing gating metadata rather than prose decoration.
The manager verifies each finding against the changed code and collapses overlap before it reaches the final report.

A finding whose truth depends on runtime Kusto, KQL, or metrics behavior must be checked empirically through the `aks-kusto` skill when access permits.
If it cannot be checked, label it unverified conjecture and lower its confidence instead of presenting it as fact.
A security reviewer loads `security-context-axi` when the pull request names a resolvable Azure service and correlates live posture only to the changed surface.

## Changed-tip watch and restart

After the first report is delivered, keep the pull request in `## Reviewed / watching` until it is completed or abandoned.
`workflows/watch.md` and `bin/fm-review-watch-triage.sh` own deterministic drop, re-review, and silent decisions.
A changed source tip or explicit re-review request launches one fresh review worker and parks a new report without requiring another round trip.
An unchanged active pull request and a terminal pull request remain silent; a terminal entry is removed.

On restart, reconstruct pending work and watched tips from `data/prreview.md`, not conversation memory.
The trusted periodic role check only reminds the role while an active URL remains in `## Queue` or `## Reviewed / watching`.
An empty list creates no work and stays silent.

## Contents

- `workflows/review.md` owns secondmate orchestration and the worker panel.
- `workflows/specialist-select.md` owns zero-or-one specialist selection.
- `workflows/watch.md` owns durable changed-tip re-review.
- `workflows/post-comments.md` owns the explicit-only posting path.
- `persona-menu.md` is the specialist catalog.
- `ado-pr-cli.sh` and `cli/ado_pr_cli.py` provide the vendored read and comment primitives.

## Prerequisites

Azure CLI must already be authenticated with read access to the target Azure DevOps pull request.
`uv` runs the vendored CLI.
A full URL is self-describing, while a bare numeric id is not accepted as durable or reported identity.
A full line-level review uses a bare repository cache under `~/.aks/ado-pr-review/data/bare-repos/`; the CLI reports the exact missing-cache requirement rather than silently degrading.
