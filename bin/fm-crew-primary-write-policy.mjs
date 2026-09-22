#!/usr/bin/env node
// Semantic policy for the crew-to-primary write-guard: does a crew's write tool
// or shell command target a path inside the PRIMARY firstmate checkout instead
// of the crew's own task worktree?
//
// A crewmate runs in a disposable linked worktree. Both observed catastrophic
// slips came from a crew addressing the repo by the primary's ABSOLUTE path for
// the rest of the task - an absolute-path Write into the primary, or a
// `cd <primary> && git commit` - after a correct one-time isolation check at
// t=0. See data/isolation-slip-rootcause-scout/report.md (Option A) and
// docs/crew-primary-write-guard.md for the full contract.
//
// This policy is the single owner of the block/allow decision. The environmental
// crew-context scoping (which env markers make it fire, and the harness response
// shaping) lives in the bin/fm-crew-primary-write-check.sh transport, not here.
// The shell tokenizer and command-position analysis (Lexer, splitProgram,
// commandPosition) are imported from bin/fm-arm-command-policy.mjs, the sole
// owner of firstmate's shell classification, so this guard never duplicates
// shell lexing. This policy never evaluates, expands, sources, or runs any byte
// of the submitted command; it inspects lexical command positions only.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import path from "node:path";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REASONS = {
  "crew-primary-write":
    "a crew must never write into the primary firstmate checkout; this target resolves inside the primary, not your own task worktree. Do all edits, commits, and redirections inside your worktree (use paths under $PWD), and never cd, git -C, redirect, or Write/Edit into the primary checkout. Only your own state/<id>.status and data/<id>/ under the primary are exempt.",
};

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

// Expand a leading ~ or $HOME so a home-relative absolute target (the exact form
// the devbox slip used: Write(~/code/.../firstmate/...)) is resolved rather than
// silently skipped as non-absolute.
function expandHome(value, home) {
  if (!value || !home) return value;
  if (value === "~") return home;
  if (value.startsWith("~/")) return home + value.slice(1);
  if (value === "$HOME" || value === "${HOME}") return home;
  if (value.startsWith("$HOME/")) return home + value.slice(5);
  if (value.startsWith("${HOME}/")) return home + value.slice(7);
  return value;
}

// Resolve symlinks on the longest existing prefix of an absolute path, then
// re-append the non-existent tail. A brand-new file under an existing directory
// (a first Write) still canonicalizes, and a symlinked ancestor (macOS
// /tmp -> /private/tmp) cannot hide a primary-checkout target behind an
// unresolved path component.
function canonical(target) {
  let current = path.normalize(target);
  const tail = [];
  for (let i = 0; i < 64; i += 1) {
    try {
      const real = realpathSync(current);
      return tail.length ? path.join(real, ...tail) : real;
    } catch {
      const parent = path.dirname(current);
      if (parent === current) return path.normalize(target);
      tail.unshift(path.basename(current));
      current = parent;
    }
  }
  return path.normalize(target);
}

function isUnder(target, base) {
  return target === base || target.startsWith(base + path.sep);
}

// The only legitimate worker writes under the source checkout are its exact
// parent-channel status file, its durable instruction inbox, and its own data
// report directory. No task id means no exception.
function isWhitelisted(target, primary, id) {
  if (!id) return false;
  const status = path.join(primary, "state", `${id}.status`);
  const inbox = path.join(primary, "state", `${id}.inbox`);
  const data = path.join(primary, "data", id);
  return target === status || isUnder(target, inbox) || isUnder(target, data);
}

function decidePath(rawTarget, context) {
  const expanded = expandHome(rawTarget, context.home);
  // Resolve relative targets from the assigned worktree root as a conservative
  // approximation of the worker tool cwd. This also catches an accidental
  // ../../ escape that reaches the source checkout.
  const absolute = path.isAbsolute(expanded) ? expanded : path.resolve(context.worktree, expanded);
  const target = canonical(absolute);
  if (isUnder(target, context.worktree)) return { decision: "allow" };
  if (!isUnder(target, context.primary)) return { decision: "allow" };
  if (isWhitelisted(target, context.primary, context.id)) return { decision: "allow" };
  return deny("crew-primary-write");
}

// Shell redirections that create or grow a file (a write vector). Input
// redirections (<, <<, <<-, <<<, <&) never write and are ignored.
const WRITE_REDIR = new Set([">", ">>", "<>", ">&"]);

// A target word is resolvable when it carries no command or process
// substitution (a $(...) / `...` / <(...) whose value this policy cannot know).
// A word holding an unexpanded ordinary variable ($PRIMARY) is still accepted:
// expandHome resolves the ~ and $HOME forms, and decidePath drops anything that
// is not absolute afterward, so an unknown variable simply fails open.
function resolvableWord(word) {
  return Boolean(word) && word.type === "word" && word.subs.length === 0;
}

function collectRedirectionTargets(tokens, out) {
  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (token.type !== "redir" || !WRITE_REDIR.has(token.value) || token.inlineTarget) continue;
    const target = tokens[i + 1];
    if (resolvableWord(target)) out.push(target.value);
  }
}

// The `>|` clobber-override redirect lexes as a `>` redir followed by a bare
// pipe, so splitProgram leaves the redir as this node's last token and the
// destination as the next node's leading word (never a target word in-node).
// Recover that destination so a clobber write into the primary is still caught.
function collectClobberTarget(tokens, nextNode, out) {
  if (!nextNode || nextNode.length === 0) return;
  const last = tokens[tokens.length - 1];
  if (!last || last.type !== "redir" || last.inlineTarget || !WRITE_REDIR.has(last.value)) return;
  const target = nextNode[0];
  if (resolvableWord(target)) out.push(target.value);
}

function collectCdTargets(position, out) {
  if (!position.command) return;
  const name = basename(position.command.value);
  if (name !== "cd" && name !== "pushd") return;
  for (let i = position.index + 1; i < position.words.length; i += 1) {
    const word = position.words[i];
    if (word.value.startsWith("-")) continue;
    if (resolvableWord(word)) out.push(word.value);
    return;
  }
}

// Pre-subcommand git global options that consume the following word as their
// value. Skipping that value word keeps the scan from mistaking it for the git
// subcommand and stopping early (which would hide a later `-C <primary>`).
const GIT_VALUE_GLOBALS = new Set([
  "-c",
  "--namespace",
  "--exec-path",
  "--config-env",
  "--super-prefix",
  "--attr-source",
]);

// `git -C <dir>`, `git --git-dir <dir>`, and `git --work-tree <dir>` all point
// git at another tree; a crew pointing them at the primary is the commit vector.
// Only the pre-subcommand global options are inspected; scanning stops at the
// git subcommand so a subcommand-specific -C is not misread.
function collectGitDirTargets(position, out) {
  if (!position.command || basename(position.command.value) !== "git") return;
  const words = position.words;
  for (let i = position.index + 1; i < words.length; i += 1) {
    const word = words[i];
    const value = word.value;
    if (value === "-C" || value === "--git-dir" || value === "--work-tree") {
      const target = words[i + 1];
      if (resolvableWord(target)) out.push(target.value);
      i += 1;
      continue;
    }
    if (value.startsWith("--git-dir=")) {
      if (resolvableWord(word)) out.push(value.slice("--git-dir=".length));
      continue;
    }
    if (value.startsWith("--work-tree=")) {
      if (resolvableWord(word)) out.push(value.slice("--work-tree=".length));
      continue;
    }
    if (GIT_VALUE_GLOBALS.has(value)) {
      i += 1;
      continue;
    }
    if (value.startsWith("-")) continue;
    break;
  }
}

function plainOperands(position) {
  return position.words
    .slice(position.index + 1)
    .filter((word) => resolvableWord(word) && word.value !== "--" && !word.value.startsWith("-"));
}

// GNU cp/mv/install/ln accept `-t DEST` / `--target-directory[=]DEST`, where the
// destination is the flag value and every trailing operand is a SOURCE. Without
// this, `.at(-1)` would pick a source under the worktree and miss the write INTO
// DEST. Returns { value } when the flag is present (value may be null for an
// unresolvable destination, which then fails open), or null when it is absent.
function targetDirectoryFlag(position) {
  const words = position.words;
  for (let i = position.index + 1; i < words.length; i += 1) {
    const word = words[i];
    const value = word.value;
    if (value === "--") break;
    if (value === "-t" || value === "--target-directory" || /^-[a-zA-Z]*t$/.test(value)) {
      const dest = words[i + 1];
      return { value: resolvableWord(dest) ? dest.value : null };
    }
    if (value.startsWith("--target-directory=")) {
      return { value: resolvableWord(word) ? value.slice("--target-directory=".length) : null };
    }
  }
  return null;
}

// Cover the common direct filesystem mutations an agent naturally emits.
// This is intentionally a bounded command-position policy rather than a shell
// evaluator; scripts and deliberately hidden targets remain outside the
// agent-mistake threat model.
function collectMutationTargets(position, out) {
  if (!position.command) return;
  const name = basename(position.command.value);
  const operands = plainOperands(position);
  if (operands.length === 0) return;
  if (["rm", "rmdir", "touch", "mkdir", "truncate", "tee"].includes(name)) {
    for (const operand of operands) out.push(operand.value);
    return;
  }
  if (["cp", "mv", "install", "ln"].includes(name)) {
    const dest = targetDirectoryFlag(position);
    if (dest) {
      if (dest.value !== null) out.push(dest.value);
      return;
    }
    out.push(operands.at(-1).value);
    return;
  }
  if (["chmod", "chown", "chgrp"].includes(name)) {
    for (const operand of operands.slice(1)) out.push(operand.value);
    return;
  }
  if ((name === "sed" || name === "perl") && position.words.some((word) => /^-.*i/.test(word.value))) {
    for (const operand of operands) out.push(operand.value);
  }
}

// Walk every top-level command node plus the contents of subshell/brace groups
// and command substitutions, collecting targets from every bounded write arm.
// Only the TOP-LEVEL tokenizer error fails the whole command open (allow); a
// nested untokenizable fragment merely loses coverage for that fragment, exactly
// the agent-mistake threat model the sibling guards use.
function collectFromProgram(command, out, depth) {
  if (depth > 12) return;
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) {
    if (depth === 0) out.error = true;
    return;
  }
  const { nodes } = splitProgram(lexed.tokens);
  for (let n = 0; n < nodes.length; n += 1) {
    const tokens = nodes[n];
    collectRedirectionTargets(tokens, out.targets);
    collectClobberTarget(tokens, nodes[n + 1], out.targets);
    const position = commandPosition(tokens);
    collectCdTargets(position, out.targets);
    collectGitDirTargets(position, out.targets);
    collectMutationTargets(position, out.targets);
    for (const token of tokens) {
      if (token.type === "group") collectFromProgram(token.content, out, depth + 1);
      if (token.type === "word") {
        for (const substitution of token.subs) collectFromProgram(substitution.content, out, depth + 1);
      }
    }
  }
}

function decide(input) {
  // No crew-context markers means this is not a guarded crew (the primary
  // session, or a broken environment): allow. Fail open on an uncanonicalizable
  // primary or worktree marker.
  if (!input.primary || !input.worktree) return { decision: "allow" };
  let primary;
  let worktree;
  try {
    primary = canonical(input.primary);
    worktree = canonical(input.worktree);
  } catch {
    return { decision: "allow" };
  }
  const context = { primary, worktree, id: input.id || "", home: input.home || "" };

  if (input.mode === "path") {
    if (!input.value) return { decision: "allow" };
    return decidePath(input.value, context);
  }

  const out = { targets: [], error: false };
  collectFromProgram(input.value || "", out, 0);
  if (out.error) return { decision: "allow" };
  for (const rawTarget of out.targets) {
    const result = decidePath(rawTarget, context);
    if (result.decision === "deny") return result;
  }
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { primary: "", worktree: "", id: "", home: "", mode: "", value: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--primary" || name === "--worktree" || name === "--id" || name === "--home") {
      if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
      result[name.slice(2)] = argv[i + 1];
      i += 1;
      continue;
    }
    if (name === "--file-path" || name === "--command") {
      if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
      if (result.mode) throw new Error("only one of --file-path or --command may be given");
      result.mode = name === "--file-path" ? "path" : "command";
      result.value = argv[i + 1];
      i += 1;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.home) args.home = process.env.HOME || "";
    if (!args.mode) {
      process.stdout.write("allow\n");
    } else {
      const result = decide(args);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decide };
