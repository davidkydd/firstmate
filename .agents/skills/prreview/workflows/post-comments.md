# Workflow: Explicitly requested review comments

This workflow is not part of the default review.
Use it only when the main firstmate routes an explicit request to post findings for one exact Azure DevOps pull request.
The request authorizes only the named findings or, when stated, the postable findings in that review's prepared batch.
It never authorizes a reviewer vote, thread resolution, merge, or completion.

## Authorization check

Run the tracked role-policy guard before any write:

```bash
bin/fm-role-policy.sh check prreview post-review --explicit
```

The review wrapper also requires `FM_PRREVIEW_EXPLICIT_POST=1` before it will execute `post-comment`, `reply-thread`, or `resolve-thread`.
Set that variable only for the exact explicitly routed posting action.
A routine review worker, changed-tip re-review, periodic reminder, or parked report does not supply it.

Never invoke the Python implementation directly to bypass the wrapper.
Before any vote or completion attempt, run the corresponding role-policy check and obey its permanent refusal.

## Input

Use the parked review's `post_batch.json` or an explicit instruction that names comments and locations.
Do not infer authorization from the existence of a batch file.
If a finding changed after the report was produced, verify the current source tip and line location before posting.

Each inline comment record has:

- `file`: a repository-relative path beginning with `/`.
- `startLine` and `endLine`: lines on the right side of the reviewed diff.
- `severity`: internal gating metadata.
- `content`: standalone Markdown prose.

The comment body leads with the concrete issue and consequence, gives the file and line evidence naturally, and suggests the bounded fix inline.
Strip internal finding ids, severity labels, report-structure language, and specialist-source tags.
Write every URL as a clickable Markdown link.

## Duplicate handling

Read the current active threads before posting.
When the exact concern already has a thread and the explicit request authorizes a reply, reinforce that thread rather than opening a duplicate.
Do not resolve the thread.
If the request does not authorize a reply, leave the prepared finding parked and report the ambiguity rather than guessing.

## Execute and verify

For one prepared batch:

```bash
FM_PRREVIEW_EXPLICIT_POST=1 \
  "$SKILL_DIR/ado-pr-cli.sh" post-comment <full-pr-url> "$REPORT_DIR/post_batch.json"
```

For one explicitly authorized reply:

```bash
FM_PRREVIEW_EXPLICIT_POST=1 \
  "$SKILL_DIR/ado-pr-cli.sh" reply-thread <full-pr-url> <thread-id> "<message>"
```

Use one merged batch rather than letting reviewers or specialists post independently.
Verify the returned thread ids and report the full pull-request URL, count, and any failure through the generated parent channel.
Leave low, nit, and informational findings parked unless the explicit request names them.
