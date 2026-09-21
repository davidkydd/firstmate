# GitHub Copilot app surface

## Status and scope

The GitHub Copilot app integration is a production-shaped proof for a replaceable captain-facing client.
It does not make the app, My Copilot, an extension process, or a canvas an orchestrator.
External Firstmate remains the sole owner of the backlog, workers, captain holds, merge authority, delivery state, and lifecycle safety.

The proof provides five bounded capabilities:

1. A read-only projection of `fm-fleet-snapshot.v1` in a Firstmate canvas.
2. Explicit `/firstmate <request>` ingress and a clearly labelled canvas composer.
3. Durable output replay after extension failure, `/clear`, session restart, and app closure.
4. Provenance classes that prevent agent, system, extension, and free-text records from authorizing sensitive actions.
5. Typed decisions and `interrupt` or `relaunch` controls routed through the existing guarded Firstmate owners.

The integration does not add a worker runtime, duplicate fleet store, app-session authority, generic shell tool, direct merge action, or direct cleanup action.
It never writes GitHub Copilot SQLite, calls a private WebSocket or Tauri API, or puts a credential in a URL.

## Compatibility

The extension uses only the public user-extension surfaces supplied by `@github/copilot-sdk/extension`.
The canvas protocol is experimental in the current SDK, so installation requires explicit acknowledgement and the extension checks both a minimum Copilot CLI version of 1.0.84 and the runtime canvas capability.
If the canvas API is unavailable, the extension reports that presentation limitation and leaves external Firstmate supervision untouched.
The explicit `/firstmate` command remains available when the host can load extensions but cannot render canvases.

Check the local package and installed CLI without installing anything:

```sh
bin/fm-copilot-app.sh check
```

Build a standalone package in a new directory without installing it:

```sh
bin/fm-copilot-app.sh package --output /tmp/firstmate-copilot-app
bin/fm-copilot-app.sh verify-package /tmp/firstmate-copilot-app
```

Building and testing never writes `~/.copilot` and never enables the extension.

## Explicit installation

Installation is user-scoped and deliberately separate from package creation:

```sh
bin/fm-copilot-app.sh install \
  --fm-home /absolute/path/to/firstmate-home \
  --accept-experimental-canvas
```

The default destination is `${COPILOT_HOME:-$HOME/.copilot}/extensions/firstmate`.
Pass `--target /absolute/path` to use another user-extension directory.
The installer refuses an existing destination rather than replacing it.
Reload or restart the GitHub Copilot app after installation so extension discovery runs again.

The generated `config.json` contains only the Firstmate code root, selected `FM_HOME`, client id, protocol version, and CLI version observed at installation.
The extension requests no secret environment variable.

Uninstall only an unchanged installation whose files still match its generated receipt:

```sh
bin/fm-copilot-app.sh uninstall
```

A modified or unrecognized installation is left in place for manual inspection.
Uninstall does not alter Firstmate state or Copilot app databases.

## Using the surface

Run `/firstmate <request>` for explicit ingress.
The command handler is a public SDK user-command callback, and it stores the request in Firstmate before reporting success.
Ordinary Copilot chat is not intercepted.
An agent- or system-originated message that imitates `/firstmate` is retained only as a non-authoritative observation.

Open the canvas named **Firstmate** from the app's canvas surface.
Its fleet panel renders the canonical `bin/fm-fleet-snapshot.sh --json` result rather than parsing raw task files.
Its outcome panel shows the exact durable output bodies.
Its composer submits ordinary requests, and its decision and control forms create typed records bound to explicit identifiers.

Canvas HTTP binds to an ephemeral `127.0.0.1` port.
The URL carries no token or credential.
State-changing requests require a per-process capability held in page memory, an exact loopback Host, a same-origin Origin, JSON content type, and a bounded body.
The extension is trusted same-user code rather than an operating-system sandbox.

## Durability and authority

`bin/fm-captain-surface.sh` owns the transport mechanics and its command help is the exact operational reference.
The private store lives under `state/captain-surfaces/` in the selected Firstmate home.
Inputs and outputs are append-only, gap-free JSONL sequences with unique correlation identifiers.
The complete store is validated before every mutation.

Each app generation registers a fresh generation id.
Replacing a generation invalidates calls from the old extension without changing that client's output cursor.
Each client acknowledges only the highest contiguous output sequence it has presented.
Multiple clients keep independent cursors while reading one canonical output log.
Outputs emitted while the app is closed remain unread and replay in order after the next registration.

Direct-user free text is an ordinary request, not sensitive authority.
Agent, system, and extension provenance is always non-authoritative regardless of message text.
Typed decisions must name an offered decision sequence, exact captain-held task, and current open-call revision.
The revision is checked at ingress and again under the captain-hold owner's task lock when the decision is applied.
Typed control allows only `interrupt` and `relaunch`, and application invokes `bin/fm-control.sh` with an exact task id.
No bridge schema can express merge, discard, cleanup, arbitrary shell, or a generic lifecycle command.

Application is claimed durably before an owner command runs.
A crash across that boundary leaves an explicit uncertain receipt and never retries the action automatically.
This favors at-most-once action over guessing after an ambiguous side effect.

## Maintainer verification

Run the deterministic transport and packaging suite with:

```sh
bin/fm-test-run.sh tests/fm-captain-surface.test.sh
```

The suite covers input and output sequencing, correlation deduplication, independent client acknowledgements, replay after disconnection, generation replacement, provenance classes, stale decision revisions, malformed records and payloads, typed owner routing, capability checks, package creation, explicit installation, and exact uninstall refusal after drift.
It uses temporary Firstmate homes and a fake Copilot executable, and it never installs into the operator's real Copilot home.
