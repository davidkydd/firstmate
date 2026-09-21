# Workflow: Specialist selection (the novel part)

Pick the **zero-or-one** specialist reviewer that runs as the review panel's 6th panelist.
This is the genuinely new logic in prreview - it fires per-PR, from the PR's actual
contents, at review time. Called from [review.md](review.md) Step 2, before the panel
launches.

## Why this is NOT a crew-dispatch rule

`config/crew-dispatch.json` and this picker are orthogonal, not competitors - do not try to
express the specialist as a dispatch rule:

- crew-dispatch selects **harness / model / effort** (the engine a crew runs on). Its `use`
 schema has no notion of a reviewer *persona / brief*; it literally cannot express "you
 are the architecture reviewer".
- crew-dispatch fires **at spawn/intake**, keyed on the *task's* natural-language
 description - not on *PR content*, which does not exist until after `fetch`.
- The specialist must be chosen **inside the secondmate, per-PR, after fetch**, from the
 diff.

What IS reused is crew-dispatch's *design pattern*: natural-language rules a firstmate
picks among by judgment, with a tiny script resolving the deterministic bits. Here the
natural-language catalog is [persona-menu.md](../persona-menu.md) and the deterministic helper
is `bin/fm-review-classify.sh`. The panel now runs inside a spawned review crew rather than
the secondmate's own session, but the specialist is still chosen the same way - inside that
crew, per-PR, after fetch - and crew-dispatch still only chooses the harness that crew runs
on, orthogonal to which persona the specialist panelist wears.

## Step 1: Gather cheap diff facts

Run the classifier on the fetched diff to ground the pick in signal, not vibes:

```bash
"$ROOT/bin/fm-review-classify.sh" ~/.aks/ado-pr-review/data/pr-data/<repo>-<pr-id>/diff.patch
```

It prints `KEY=VALUE` facts: file counts and extensions, `dep_manifest_changed`,
`lockfile_changed`, `defines_struct`, `defines_interface`, `concurrency_hits`,
`security_path_hits`, `hot_path_hits`, and a `trivial` flag. These INFORM the pick; they do
not decide it. (With only the clone-less `diff` command you have the changed-file list but
no line-level hunks, so the content-keyword facts will be weak - lean more on file paths,
title, and labels then.)

## Step 2: Decide zero-or-one

- If `trivial=yes` (test-only, or a pure dependency/lock bump), pick **no specialist** -
 the base 5 cover it, and a forced specialist is just noise. Stop here.
- Otherwise, weigh the facts, the PR title/description, and the ADO labels against
 [persona-menu.md](../persona-menu.md) and pick the **single** best-fit persona. This is a
 judgment call, explicitly not a first-match on the fact table - the facts are evidence,
 the menu is the option set, you choose. If nothing clears a specialty bar (the change is
 broad but ordinary), it is fine to pick **no specialist**.
- Never pick more than one. The panel adds at most one 6th seat.

Rough fact-to-persona hints (guidance, not a lookup):

| Dominant signal | Likely persona |
|---|---|
| `defines_struct` / `defines_interface` high, new files/packages, large structural diff | architecture |
| `hot_path_hits` high, loops/allocations/serialization/cache, perf in title/labels | performance |
| `dep_manifest_changed` with some code, config-heavy, renames, dead-code removal | maintenance |
| `security_path_hits` high, auth/crypto/secrets/RBAC/IAM paths | security-deep |
| `concurrency_hits` high, goroutines/channels/locks | concurrency |
| `test_files` dominant but NOT trivial (tests plus a real change) | test-quality |

## Step 3: Hand the persona to the panel

If a persona was picked, take its block verbatim from [persona-menu.md](../persona-menu.md) and
prepend it to the specialist sub-agent's prompt (layered on the base Bug-Hunter charter),
launched in the SAME parallel batch as the base 5. The specialist writes
`review_report_specialist_<name>.md` into the same timestamped run dir, and every finding
carries its `source: <name>-specialist` tag so the manager merge can recognize and prefer
the deeper specialist framing on overlap. The tag is manager-only; it is stripped before
any (future) posting.

If no persona was picked, note "no specialist (base panel suffices)" in the run and proceed
with the base 5.
