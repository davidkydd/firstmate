# Crew source-checkout write guard

This document is the maintainer architecture owner for the worker-to-source-checkout write boundary.
`bin/fm-crew-primary-write-policy.mjs` owns path and shell-command classification.
`bin/fm-crew-primary-write-check.sh` owns binding validation, hook payload decoding, and per-harness denial rendering.
`bin/fm-spawn.sh` owns binding creation and worker-hook installation.

## Purpose

A ship or scout starts in an isolated worktree, but a later absolute path can still target the source checkout from which that worktree was created.
The launch-time isolation assertion does not stop a later native write tool, shell redirection, `cd`, or `git -C` from changing the source checkout.
The guard denies that later write before execution while leaving source reads available.

This is an agent-mistake seatbelt rather than a same-user security sandbox.
It never executes or expands submitted shell text.
Unknown shell syntax and unavailable hook runtimes step aside rather than turning one broken classifier into a universal write denial.

## Private task binding

Every ship and scout launch creates `state/<id>.write-boundary` as a mode-0600 record with:

```text
schema=fm-crew-write-boundary.v1
task=<id>
source=<absolute source checkout>
worktree=<absolute assigned worktree>
token=<64 lowercase hexadecimal characters>
```

The pane receives `FM_TASK_ID`, `FM_CREW_WRITE_BOUNDARY_RECORD`, `FM_CREW_WRITE_BOUNDARY_TOKEN`, and `FM_CREW_WRITE_GUARD_CHECKER` before the worker starts.
The transport accepts a binding only when the record is ordinary, its schema is current, its random token matches, and its task matches `FM_TASK_ID` when that marker is present.
A primary or secondmate launch has no binding and is inert.
Cleanup removes the record and any generated project-hook marker with the rest of the task's runtime state.

The token prevents one task from accidentally adopting another task's record.
It does not claim protection against a deliberately malicious process running as the same operating-system user.

## Decision boundary

The policy canonicalizes the source checkout, assigned worktree, and target through the longest existing path prefix, so a symlinked ancestor and a not-yet-created file do not bypass containment.
Leading `~`, `$HOME`, and `${HOME}` are resolved.
A relative target is resolved from the assigned worktree root, which also catches a straightforward `../` escape.

A target under the assigned worktree is allowed.
A target outside the source checkout is allowed.
A target inside the source checkout is denied except for exactly:

- `state/<id>.status`;
- descendants of `state/<id>.inbox/`, which the worker must acknowledge;
- descendants of `data/<id>/`, which hold the task report and review artifacts.

No task id means no exception.
Reads such as `cat <source>/AGENTS.md` remain allowed.

The native-write arm recognizes the write and edit tool names and path fields used by the current hook adapters.
The shell arm reuses the lexer and command-position owner in `bin/fm-arm-command-policy.mjs`.
It checks write redirections, `cd` and `pushd`, git directory overrides, and common direct filesystem mutation commands such as `touch`, `mkdir`, `rm`, `cp`, `mv`, `install`, `ln`, `chmod`, `chown`, `truncate`, and `tee`.
Command substitutions and arbitrary interpreter programs remain outside the bounded agent-mistake classifier.

Every denial carries stable reason code `crew-primary-write` and directs the worker back to its assigned worktree.

## Harness integration

Worker-local integration is generated at launch rather than relying on every target repository to carry Firstmate hooks.

| Worker runtime | Integration |
| --- | --- |
| Claude | Generated `.claude/settings.local.json` checks Bash and native write/edit tools. |
| Codex | A project `PreToolUse` Bash hook is used; a minimal ignored hook is generated when the project has none, while an existing incompatible project hook is refused rather than overwritten. |
| OpenCode | The generated worker plugin checks Bash and native write/edit calls in `tool.execute.before`. |
| Pi and Pi-signed | The generated per-task extension checks Bash and native write/edit calls in `tool_call`. |
| omp | The generated per-task extension checks Bash and native write/edit calls in `tool_call`. |
| Cursor | A project `preToolUse` Shell hook is used; a minimal ignored hook is generated when the project has none, while an existing incompatible project hook is refused rather than overwritten. |
| Grok, Gemini, Kimi, Muse, Rovo, and AGY | No complete verified blocking surface covers both shell and native writes in the current adapters, so these runtimes do not claim the full seatbelt. |

The tracked `prreview`, `prbabysit`, and `prdeveloper` homes refuse to dispatch workers on the final-row runtimes, while other homes retain their existing verified worker support.
That is a documented capability boundary, not permission to infer a hook from another tool.
A new blocking integration requires real-runtime evidence under `firstmate-coding-guidelines` before the table can change.

## Failure behavior

The checker returns exit 0 with no output for an absent or invalid binding, malformed hook payload, missing `jq` on stdin mode, unavailable Node runtime, unknown tool, empty target, or invalid policy response.
This prevents a broken hook from blocking every worker write.
Spawn itself refuses when it cannot create the original binding or an applicable worker hook cannot be installed safely.

Claude denial uses exit 2 with an empty stdout and a Claude decision object on stderr.
Grok receives its decision object on stdout.
Cursor receives its permission object on stdout and exit 0.
Codex, OpenCode, Pi, and omp use their verified blocking surfaces and the checker's exit-2 reason.

## Verification

`tests/fm-crew-primary-write-check.test.sh` exercises canonical path handling, exact task-owned exceptions, shell mutation forms, alternate tool payloads, output shapes, and binding mismatch behavior.
The spawn and harness suites exercise generated hook installation and cleanup.
[`docs/verification/runtime-backends.md`](verification/runtime-backends.md) records the dated cross-runtime evidence and explicit live-test boundary.
Run the focused checks with:

```sh
bin/fm-test-run.sh tests/fm-crew-primary-write-check.test.sh tests/fm-persistent-roles.test.sh
bin/fm-lint.sh
```
