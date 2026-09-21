# Workflow: Review-followup watch (self-clearing, standing re-review)

After a PR's first review is parked (see [review.md](review.md)), the panel does not
drop it and forget it. It keeps the PR on a durable **review-followup watch**: a
self-clearing standing watch that re-reviews the PR automatically when the author
pushes new commits, and clears itself when the PR merges or is abandoned. This is
the standing re-review mode that [review.md](review.md) "Follow-ups" previously
listed as future - it is built now, and it is the panel's default posture once a
first review exists.

This watch is durable state, reconstituted from the home on restart/recovery - not
from live context. A fresh launch reads the watch list and resumes the watch.

## Separate from `prbabysit`

This review-followup watch is separate from the `prbabysit` role.
`prbabysit` maintains explicitly watched pull requests' content gates and review readiness.
This watch only re-reviews changed source tips and never touches gates, votes, merge, or completion.

## The watch list (durable state, in the home)

The watch list lives at `data/prreview.md` in the role home.
It carries two sections:

```markdown
## Queue
- <full-PR-URL> (pending first review)

## Reviewed / watching
- <full-PR-URL> tip=<source-commit-sha> reviewed=<YYYY-MM-DD>
```

- **`## Queue`** - PRs routed but not yet reviewed the first time. Run
  [review.md](review.md), then MOVE the entry into `## Reviewed / watching`.
- **`## Reviewed / watching`** - one line per already-reviewed PR, pinned via
  `tip=<sha>` to the exact source commit it was last reviewed against. `tip=` and
  the full PR URL are the load-bearing fields; `reviewed=` is a human date note.

The pinned tip is the source-branch head at review time:
`ado-pr-cli.sh status <pr>` reports it (the PR's `lastMergeSourceCommit.commitId`;
`sourceBranch` names the branch). Record that sha as `tip=` when you first add the
entry, and re-pin it to the new tip after every re-review.

`bin/fm-review-watch-triage.sh parse <file>` extracts the `## Reviewed / watching`
entries as machine lines, ignoring the `## Queue` section, blank lines, and prose -
so a caller can read that section's durable state deterministically. Restart/recovery
re-establishes the watch with `rearm` (next section), not `parse`.

## Track-until-merge is the durable default (restart re-arm)

Track-until-merge is the DEFAULT posture, not an opt-in a session can forget: the
moment a PR is reviewed - recorded in `data/prreview.md` with a `tip=`
pin - it is on the watch and stays there until it merges or is abandoned. This
survives restart/recovery with no human re-arming it.

On restart, reconstitute the watch deterministically with
`bin/fm-review-watch-triage.sh rearm <file>`. It emits one `rearm=<url> tip=<sha>`
directive per REVIEWED PR and differs from `parse` in one load-bearing way: it is
scoped to CONTENT, not section, so it re-arms every entry pinned with a `tip=` in
ANY section, deduped by URL. That closes the one gap where a reviewed PR could
fall off the watch across a restart: if a session parked and delivered a first review
but crashed before moving the entry from `## Queue` into `## Reviewed / watching`,
that PR is still a reviewed PR (it has a `tip=`), so `rearm` rescues it onto the
watch rather than losing it. A pending-first-review `## Queue` entry carries no
`tip=`, so it is correctly not yet watched. Moving a reviewed entry into
`## Reviewed / watching` remains the right bookkeeping, but it is not what arms the
watch - the `tip=` pin is - so a missed move never drops a reviewed PR's watch.

The first triage pass after re-arm restores the self-clearing behavior: a PR that
merged or was abandoned while the session was down is `drop`ped, exactly as below.

## Triage each watched PR (the self-clearing loop)

The watch is bursty, not a tight poll - your own supervision watcher handles timing,
exactly as for the first review. On each pass, for each entry in `## Reviewed /
watching`, gather the PR's current live facts and let
`bin/fm-review-watch-triage.sh` decide. The script is deterministic and does no
network: you fetch the facts (as you already fetch a diff), it decides.

```bash
# Current status + tip for the watched PR (status also names the source branch).
"$SKILL_DIR/ado-pr-cli.sh" status <pr-url> > /tmp/watch-status.txt
# Read: status ("completed"/"abandoned"/"active") and the current source tip sha.

bin/fm-review-watch-triage.sh decide \
  --status <active|completed|abandoned> \
  --recorded-tip <tip-from-the-list> \
  --current-tip <current-source-tip-sha> \
  [--rerequest]     # add when the author explicitly re-requested review
```

The decision is one of:

- **`drop`** - the PR merged (`completed`) or was abandoned. The followup is over.
  Remove the entry from `## Reviewed / watching` SILENTLY. No escalation - a merged
  or closed PR is not a supervisor event.
- **`re-review`** - the author pushed new commits since the last review (the current
  tip differs from the recorded tip), or explicitly re-requested review.
  Automatically spawn a fresh review worker against the current tip and run [review.md](review.md) again.
  Changed-tip re-review is standing work and needs no additional round trip, but the new report remains park-only.
  Re-pin the watch entry's `tip=` to the reviewed source tip and return the updated report through the generated parent channel.
- **`silent`** - the PR is still open and unchanged since the last review (or the
  current tip could not be resolved, so no change is proven). Stay silent inside the
  home. Routine polling and queued<->running gate churn never wake the main
  firstmate.

Re-reviewing reads existing PR threads first
(`"$SKILL_DIR/ado-pr-cli.sh" threads <pr-id> --json`) via the Human Comments
reviewer, so a re-review builds on the prior discussion rather than repeating it.

## What still holds

- **Park every re-review.** A changed-tip review returns a new report and does not post findings without a separate explicit request.
- **Never vote, merge, or complete.** The watch only re-reviews.
- **Use full pull-request URLs.** Watch-list entries and every returned outcome name the full URL.
