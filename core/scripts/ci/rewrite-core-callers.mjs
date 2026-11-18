#!/usr/bin/env node
// US-043: move callers of scaffold helpers that have a TypeScript twin in
// hq-cli from `bash core/scripts/<name>.sh` to `hq core <command>`.
//
//   node core/scripts/ci/rewrite-core-callers.mjs --list  [--root <hq>]
//   node core/scripts/ci/rewrite-core-callers.mjs --apply [--root <hq>]
//   node core/scripts/ci/rewrite-core-callers.mjs --check [--root <hq>]
//
// --list prints one TSV row per caller line: file, line, helper, command, form
// (rewrite = the script rewrites it, manual = it needs a hand fix).
// --apply rewrites every `rewrite` row in place. --check exits 1 when a
// `rewrite` row is left, so the rewrite stays done.
//
// The script only touches invocations: a `bash`/`sh`/`exec` prefix, or the
// helper path in command position. Prose that names a helper is not a call
// and is left alone. Test files, the helpers themselves and the forwarder
// machinery are out of scope; the helpers stay on disk until US-044.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Helper -> hq core command and the command's root mode. Source: the
// registered `hq core` leaves on hq-cli main (registeredCoreCommandListing,
// execution native), core/scripts/cli-hosted.yaml and the `hq core ...`
// owners in core/functions.yaml. `live` commands take --hq-root; `cwd`
// commands run against the working directory. `minCli` is the oldest hq-cli
// a direct `hq core` call needs: the first npm release with the command
// (checked against the hq-cli release tags for every command a caller here
// now runs), or the cli-hosted.yaml floor where that is higher for a
// behaviour fix. --check requires each one to be at or below core/core.yaml
// requiresHqCli, the install floor setup, doctor and /update-hq enforce, so
// a skill that runs `hq core <command>` never meets an hq-cli without it.
export const TWINS = Object.freeze({
  "archive-old-threads.sh": { command: "archive-old-threads", root: "live", minCli: "5.78.0" },
  "audit-log.sh": { command: "audit-log", root: "live", minCli: "5.307.0" },
  "clean-worktree-reconcile-handoff.sh": { command: "clean-worktree-reconcile-handoff", root: "cwd", minCli: "5.287.0" },
  "codex-skill-bridge.sh": { command: "codex-skill-bridge", root: "live", minCli: "5.78.0" },
  "derive-trigger-facts.sh": { command: "derive-trigger-facts", root: "live", minCli: "5.342.5" },
  "detect-stale-core-policy-mirror.sh": { command: "detect-stale-core-policy-mirror", root: "live", minCli: "5.78.0" },
  "detect-stale-review-base.sh": { command: "detect-stale-review-base", root: "live" },
  "eval-trigger.sh": { command: "eval-trigger", root: "cwd", minCli: "5.341.3" },
  "generate-workers-registry.sh": { command: "generate-workers-registry", root: "live", minCli: "5.89.0" },
  "git-pack-extension-check.sh": { command: "git-pack-extension-check", root: "cwd", minCli: "5.307.0" },
  "handoff-finalize.sh": { command: "handoff finalize", root: "live" },
  "handoff-open-steps.sh": { command: "handoff open-steps", root: "live", minCli: "5.290.0" },
  "handoff-post.sh": { command: "handoff post", root: "live", minCli: "5.290.0" },
  "hq-delegate-bundle.sh": { command: "delegate bundle", root: "live", minCli: "5.292.0" },
  "hq-delegate-grant.sh": { command: "delegate grant", root: "live", minCli: "5.292.0" },
  "hq-delegate-pickup.sh": { command: "delegate pickup", root: "cwd", minCli: "5.277.0" },
  "hq-delegate-publish.sh": { command: "delegate publish", root: "live" },
  "hq-delegate-repo.sh": { command: "delegate repo", root: "live", minCli: "5.277.0" },
  "hq-delegate-resolve.sh": { command: "delegate resolve", root: "live", minCli: "5.277.0" },
  "hq-delegate-secrets.sh": { command: "delegate secrets", root: "live", minCli: "5.277.0" },
  "hq-delegate-send.sh": { command: "delegate send", root: "live", minCli: "5.292.0" },
  "hq-delegate-transfer.sh": { command: "delegate transfer", root: "live", minCli: "5.277.0" },
  "hq-delegate-verify.sh": { command: "delegate verify", root: "live", minCli: "5.292.0" },
  "hq-dm-bind.sh": { command: "dm-bind", root: "live", minCli: "5.310.0" },
  "hq-job-notify.sh": { command: "job notify", root: "live", minCli: "5.342.14" },
  "hq-job-probe.sh": { command: "job probe", root: "live" },
  "hq-job-remediate.sh": { command: "job remediate", root: "live" },
  "hq-job-run.sh": { command: "job run", root: "live", minCli: "5.296.0" },
  "hq-pin.sh": { command: "pin", root: "live", minCli: "5.307.0" },
  "hq-status-summary.sh": { command: "hq-status-summary", root: "cwd", minCli: "5.78.0" },
  "jobs-schedule-parse.sh": { command: "jobs schedule-parse", root: "live", minCli: "5.291.0" },
  "jobs-validate.sh": { command: "jobs validate", root: "live", minCli: "5.291.0" },
  "knowledge-prefs.sh": { command: "knowledge-prefs", root: "live", minCli: "5.283.0" },
  "migrate-policy-triggers.sh": { command: "migrate-policy-triggers", root: "live", minCli: "5.341.3" },
  "ontology-audience-grant.sh": { command: "ontology audience-grant", root: "live" },
  "ontology-candidate.sh": { command: "ontology candidate", root: "live", minCli: "5.281.0" },
  "ontology-readme-drift.sh": { command: "ontology-readme-drift", root: "live", minCli: "5.78.0" },
  "ontology-source-worklist.sh": { command: "ontology source-worklist", root: "live", minCli: "5.281.0" },
  "outpost-jobs-reconcile.sh": { command: "jobs reconcile", root: "live", minCli: "5.292.0" },
  "pipeline-conductor.sh": { command: "pipeline conductor", root: "live", minCli: "5.345.119" },
  "pipeline-driver.sh": { command: "pipeline driver", root: "live", minCli: "5.345.119" },
  "pipeline-worker-table.sh": { command: "pipeline workers", root: "live", minCli: "5.345.107" },
  "policy-age-report.sh": { command: "policy age-report", root: "live", minCli: "5.341.3" },
  "policy-retire.sh": { command: "policy retire", root: "live", minCli: "5.341.3" },
  "qmd-reindex-after-sync.sh": { command: "qmd-reindex-after-sync", root: "cwd", minCli: "5.78.0" },
  "read-policy-frontmatter.sh": { command: "policy frontmatter", root: "cwd", minCli: "5.345.63" },
  "rebuild-all-indexes.sh": { command: "rebuild-index all", root: "live", minCli: "5.345.188" },
  "rebuild-companies-index.sh": { command: "rebuild-index companies", root: "live", minCli: "5.345.188" },
  "rebuild-company-knowledge-index.sh": { command: "rebuild-index company-knowledge", root: "live", minCli: "5.345.188" },
  "rebuild-orchestrator-index.sh": { command: "rebuild-index orchestrator", root: "live", minCli: "5.78.0" },
  "rebuild-projects-index.sh": { command: "rebuild-index projects", root: "live", minCli: "5.345.188" },
  "rebuild-public-knowledge-index.sh": { command: "rebuild-index public-knowledge", root: "live", minCli: "5.78.0" },
  "rebuild-reports-index.sh": { command: "rebuild-index reports", root: "live", minCli: "5.78.0" },
  "rebuild-social-drafts-index.sh": { command: "rebuild-index social-drafts", root: "live", minCli: "5.78.0" },
  "rebuild-threads-index.sh": { command: "rebuild-index threads", root: "live", minCli: "5.78.0" },
  "rebuild-workers-index.sh": { command: "rebuild-index workers", root: "live", minCli: "5.78.0" },
  "refresh-vault-access.sh": { command: "refresh-vault-access", root: "cwd", minCli: "5.307.0" },
  "register-project.sh": { command: "register-project", root: "live", minCli: "5.312.1" },
  "repo-run-registry.sh": { command: "repo-run-registry", root: "live", minCli: "5.316.0" },
  "resize-screenshot.sh": { command: "resize-screenshot", root: "cwd", minCli: "5.78.0" },
  "resolve-company.sh": { command: "resolve-company", root: "live", minCli: "5.308.0" },
  "resume-thread-lock.sh": { command: "resume-thread-lock", root: "live", minCli: "5.287.0" },
  "scan-packages.sh": { command: "scan-packages", root: "live", minCli: "5.78.0" },
  "session-journal.sh": { command: "session-journal", root: "live" },
  "session-project.sh": { command: "session-project", root: "live" },
  "session-title-config.sh": { command: "session-title-config", root: "live" },
  "session-title.sh": { command: "session-title", root: "live" },
  "share-suggestion-state.sh": { command: "share-suggestion-state", root: "live" },
  "token-usage-report.sh": { command: "token-usage-report", root: "cwd", minCli: "5.78.0" },
  "verify-story-deliverables.sh": { command: "verify-story-deliverables", root: "live", minCli: "5.287.0" },
  "work-mesh-live-bind-trusted.sh": { command: "work-mesh-bind-trusted", root: "live", minCli: "5.310.0" },
  "work-mesh-live-rebind.sh": { command: "work-mesh-live-rebind", root: "live" },
  "worktree-gc.sh": { command: "worktree-gc", root: "live" },
  "worktree.sh": { command: "worktree", root: "live", minCli: "5.78.0" },
});

// Where callers live: skills, hooks and scripts.
const SCOPES = [
  ".claude/skills/", ".claude/hooks/", ".claude/scripts/", ".claude/commands/",
  ".codex/hooks/", ".grok/hooks/",
  "core/skills/", "core/hooks/", "core/scripts/", "core/workers/",
];

// Callers this script lists but does not rewrite, with the reason. They are
// reported as `held` so the inventory stays complete.
const HELD_PREFIXES = [
  {
    prefixes: [".claude/hooks/", "core/hooks/", ".codex/hooks/", ".grok/hooks/"],
    reason: "hook: hook text and helper calls are held byte-for-byte by the native hook engine parity tests and the check-hq-hooks.sh hook/helper contract; they move with the hook ports (US-027)",
  },
];
// Files that name a helper path as data, not to run it.
const NOT_A_CALL = {
  "core/scripts/check-hq-hooks.sh": "the doctor's hook/helper contract table names the helper a hook runs; it changes with the hook (held above)",
  "core/scripts/company-jobs-install.sh": "release check only: asserts the released helper files exist and are root-owned; company jobs run lib/company-jobs.mjs, which has no hq-cli twin; dropping the entries is US-044",
  "core/scripts/ci/check-cli-hosted-catalog.mjs": "allow-list of files that may call hq core themselves",
};
// Calls left on purpose after review, with the reason.
const LEFT = {
  "core/scripts/codex-preflight.sh": "dead path: HQ_ROOT there is core/, so the helper path never exists and the repo check always skips; moving it to hq core would switch on a check that has never run",
};
const HELD_HELPERS = {
  "handoff-finalize.sh": "the PreToolUse scope guard (core/scripts/hook-lib.sh hd_text_arg) reads --summary/--title as data only for the shipped relative path; moving callers needs a PreToolUse change during the native PreToolUse hold",
};

// Helper modes that the hq-cli twin on main does not accept yet. A call that
// uses one stays on the helper: `hq core` would exit 1 with a usage or
// unknown-argument error where the helper works.
const HELD_MODES = [
  {
    helper: "register-project.sh",
    regex: /\s--board(?=\s|$)/,
    reason: "hq core register-project on hq-cli main has no --board mode (it accepts only the older --brainstorm spelling and exits 1 with its usage)",
  },
  {
    helper: "hq-delegate-send.sh",
    regex: /\s--reconcile(?=\s|$)/,
    reason: "hq core delegate send on hq-cli main rejects --reconcile (unknown argument, exit 1)",
  },
];

// In a skill or doc an agent runs the line through the Bash tool, so the
// PreToolUse credential guard sees it. That guard blocks an `hq` call whose
// operand is a variable it cannot evaluate (one set from a substitution, such
// as thread_id="$(basename ...)"), and accepts the helper path. A call with a
// variable operand stays on the helper until the guard learns `hq core`,
// which is a PreToolUse change.
const SUBST_REASON = "PreToolUse credential guard (block-credential-file-read.sh) blocks an hq call with a variable operand it cannot evaluate; moving the call needs a PreToolUse change during the native PreToolUse hold";

function agentCallWithVariable(file, after) {
  return /\.md$/.test(file) && /\$[A-Za-z_{(]/.test(after);
}

const TWIN_PATHS = new Set(Object.keys(TWINS).map((name) => `core/scripts/${name}`));

// Files that handle the helpers themselves rather than call them.
function outOfScope(file) {
  if (!SCOPES.some((scope) => file.startsWith(scope))) return true;
  if (/(^|\/)(tests?|hook-tests|fixtures|__fixtures__)\//.test(file)) return true;
  if (/\.test\.[a-z]+$/.test(file)) return true;
  if (TWIN_PATHS.has(file)) return true;
  if (file === "core/scripts/ci/rewrite-core-callers.mjs") return true;
  if (file === "core/scripts/generate-forwarders.sh" || file === "core/scripts/lib/forwarder.sh") return true;
  return !/\.(sh|bash|mjs|cjs|js|md|ya?ml)$/.test(file);
}

// A script that prefers `hq core` and falls back to the shell helper when the
// installed hq-cli is missing or below the twin's floor marks the fallback
// call with this comment.
const FALLBACK_MARK = /#\s*hq-core-fallback(?:\s|$)/;
const FALLBACK_REASON = "shell fallback for a missing or older hq-cli, next to an hq core call in the same script; it goes with the helper in US-044";

function heldReason(file, helper, line = "") {
  for (const held of HELD_PREFIXES) {
    if (held.prefixes.some((prefix) => file.startsWith(prefix))) return held.reason;
  }
  if (isShell(file) && FALLBACK_MARK.test(line)) return FALLBACK_REASON;
  const mode = HELD_MODES.find((held) => held.helper === helper && held.regex.test(line));
  if (mode) return mode.reason;
  return HELD_HELPERS[helper];
}

const NAME = `(${Object.keys(TWINS).map((name) => name.replace(/[.]/g, "\\.")).join("|")})`;
const END = String.raw`(?=$|[\s;&|)\x60:])`;

// Each form: regex (global) and a builder returning the replacement or
// undefined to leave the text as it is.
const FORMS = [
  {
    // bash "$ROOT/core/scripts/x.sh"   bash "$ROOT"/core/scripts/x.sh
    // bash $ROOT/core/scripts/x.sh     exec "${ROOT}/core/scripts/x.sh"
    name: "root-var",
    regex: new RegExp(String.raw`(?<lead>^|[\s;&|(\x60])(?<runner>(?:bash|sh|exec)\s+)(?<open>"?)\$\{?(?<variable>[A-Za-z_][A-Za-z0-9_]*)\}?(?<mid>"?)/core/scripts/${NAME}(?<close>"?)${END}`, "g"),
    build(groups, twin) {
      const { lead, runner, open, variable, mid, close } = groups;
      // Quotes must balance: "$R/..." or "$R"/... or none.
      if (open ? !(mid === "" ? close === '"' : close === "") : (mid || close)) return undefined;
      const exec = /^exec\s/.test(runner) ? "exec " : "";
      const root = twin.root === "live" ? ` --hq-root "$${variable}"` : "";
      return `${lead}${exec}hq core${root} ${twin.command}`;
    },
  },
  {
    // bash core/scripts/x.sh   sh ./core/scripts/x.sh   exec core/scripts/x.sh
    name: "relative",
    regex: new RegExp(String.raw`(?<lead>^|[\s;&|(\x60])(?<runner>(?:bash|sh|exec)\s+)(?:\./)?core/scripts/${NAME}${END}`, "g"),
    build(groups, twin) {
      const exec = /^exec\s/.test(groups.runner) ? "exec " : "";
      return `${groups.lead}${exec}hq core ${twin.command}`;
    },
  },
  {
    // A bare helper path as the first word of a line (a command in a code
    // block or script): core/scripts/x.sh --flag   ./core/scripts/x.sh \
    name: "bare",
    regex: new RegExp(String.raw`^(?<lead>\s*)(?:\./)?core/scripts/${NAME}(?=$|\s)`, "g"),
    build(groups, twin) {
      return `${groups.lead}hq core ${twin.command}`;
    },
  },
  {
    // An allowed-tools pattern for the bare path: Bash(core/scripts/x.sh:*)
    name: "permission",
    regex: new RegExp(String.raw`(?<lead>Bash\()(?:\./)?core/scripts/${NAME}(?=:)`, "g"),
    build(groups, twin) {
      return `${groups.lead}hq core ${twin.command}`;
    },
  },
];

// Lines that still name a helper in a way that runs it but that this script
// cannot rewrite safely: a helper path kept in a variable, a sibling path from
// the script directory, or a path built in JavaScript.
const MANUAL = [
  { name: "helper-variable", regex: new RegExp(String.raw`^\s*(?:local\s+)?[A-Za-z_][A-Za-z0-9_]*="?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?(?:/\.\.)*/(?:\.\./)*core/scripts/${NAME}"?\s*$`) },
  { name: "script-dir", regex: new RegExp(String.raw`\$\{?(?:SCRIPT_DIR|SCRIPTS_DIR|DIR|HERE|here)\}?"?/${NAME}`) },
  { name: "js-path", regex: new RegExp(String.raw`["'\x60]\s*(?:\+\s*)?/?core/scripts/${NAME}["'\x60]`) },
];

function isShell(file) {
  return /\.(sh|bash)$/.test(file);
}

function trackedFiles(root) {
  const out = execFileSync("git", ["-C", root, "ls-files", "-z"], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  return out.split("\0").filter(Boolean).filter((file) => !outOfScope(file));
}

/** Rewrite one line. Returns { line, hits: [{helper, command, form, action}] }. */
export function rewriteLine(input, { file = "", shell = false, keepPermission = new Set() } = {}) {
  // Shell comments are not calls.
  if (shell && /^\s*#/.test(input)) return { line: input, hits: [] };
  let line = input;
  const hits = [];
  for (const form of FORMS) {
    line = line.replace(form.regex, (...args) => {
      const groups = args.at(-1);
      const offset = args.at(-3);
      const current = args.at(-2);
      const helper = Object.keys(TWINS).find((name) => args.includes(name));
      const twin = TWINS[helper];
      if (!twin) return args[0];
      // An allowed-tools entry for a helper whose call in the same file is
      // held must stay, or the held call loses its permission.
      const before = current.slice(0, offset + (groups?.lead?.length ?? 0));
      const after = current.slice(offset + args[0].length);
      // Bash(core/scripts/x.sh:*), Bash(bash core/...:*), or a prefix such as
      // Bash(if bash core/...:*) or Bash(lock_json="$(bash core/...:*).
      const inPermission = /Bash\([^()]*(?:\$\()?$/.test(before);
      const held = heldReason(file, helper, input)
        ?? (!inPermission && agentCallWithVariable(file, after) ? SUBST_REASON : undefined)
        ?? (inPermission && keepPermission.has(helper) ? "allowed-tools entry kept for a held call of this helper in the same file" : undefined);
      if (held) {
        hits.push({ helper, command: twin.command, form: form.name, action: "held", reason: held });
        return args[0];
      }
      const replacement = form.build(groups, twin);
      if (replacement === undefined) return args[0];
      hits.push({ helper, command: twin.command, form: form.name, action: "rewrite" });
      return replacement;
    });
  }
  return { line, hits };
}

export function scanFile(text, file = "") {
  const shell = isShell(file);
  const rows = [];
  const lines = text.split("\n");
  // Helpers with a call held for its own line (a mode the twin lacks, or a
  // guarded substitution) keep their allowed-tools entry in this file.
  const keepPermission = new Set();
  for (const source of lines) {
    for (const hit of rewriteLine(source, { file, shell }).hits) {
      if (hit.action === "held" && (hit.reason === SUBST_REASON || HELD_MODES.some((held) => held.reason === hit.reason))) {
        keepPermission.add(hit.helper);
      }
    }
  }
  const output = lines.map((source, index) => {
    const { line, hits } = rewriteLine(source, { file, shell, keepPermission });
    for (const hit of hits) rows.push({ line: index + 1, ...hit });
    // Markdown and YAML name helpers in prose; only runnable forms count there.
    if (!(shell && /^\s*#/.test(line)) && !/\.(md|ya?ml)$/.test(file)) {
      for (const manual of MANUAL) {
        const found = line.match(manual.regex);
        if (!found) continue;
        const helper = found.slice(1).find((value) => value && Object.hasOwn(TWINS, value));
        const held = heldReason(file, helper, line);
        const data = NOT_A_CALL[file];
        const left = LEFT[file];
        const action = held ? "held" : data ? "not-a-call" : left ? "left" : "manual";
        rows.push({ line: index + 1, helper, command: TWINS[helper].command, form: manual.name, action, reason: held ?? data ?? left ?? "" });
        break;
      }
    }
    return line;
  });
  return { rows, text: output.join("\n") };
}

function main(argv) {
  const mode = argv.find((arg) => ["--list", "--apply", "--check"].includes(arg));
  if (!mode) {
    process.stderr.write("usage: rewrite-core-callers.mjs --list|--apply|--check [--root <hq>]\n");
    return 64;
  }
  const rootIndex = argv.indexOf("--root");
  const root = resolve(rootIndex >= 0 ? argv[rootIndex + 1] : fileURLToPath(new URL("../../..", import.meta.url)));
  let left = 0;
  for (const file of trackedFiles(root)) {
    const path = join(root, file);
    let text;
    try { text = readFileSync(path, "utf8"); } catch { continue; }
    const result = scanFile(text, file);
    for (const row of result.rows) {
      if (mode === "--list") {
        process.stdout.write(`${file}\t${row.line}\t${row.helper}\t${row.command}\t${row.form}\t${row.action}\t${row.reason ?? ""}\n`);
      }
      if (row.action === "rewrite") left += 1;
    }
    if (mode === "--apply" && result.text !== text) writeFileSync(path, result.text);
  }
  if (mode === "--check" && left > 0) {
    process.stderr.write(`rewrite-core-callers: ${left} caller line(s) still run a twinned helper by path; run --apply\n`);
    return 1;
  }
  if (mode === "--check") {
    const floor = installFloor(root);
    if (floor) {
      const above = Object.values(TWINS).filter((twin) => twin.minCli && compareVersions(twin.minCli, floor) > 0);
      for (const twin of above) {
        process.stderr.write(`rewrite-core-callers: hq core ${twin.command} needs hq-cli ${twin.minCli}, above requiresHqCli ${floor}\n`);
      }
      if (above.length) return 1;
    }
  }
  return 0;
}

/** core/core.yaml requiresHqCli without the >= prefix, or "" when absent. */
export function installFloor(root) {
  let text;
  try { text = readFileSync(join(root, "core/core.yaml"), "utf8"); } catch { return ""; }
  const match = /^requiresHqCli:\s*["']?>=\s*([0-9]+\.[0-9]+\.[0-9]+)["']?\s*$/m.exec(text);
  return match ? match[1] : "";
}

export function compareVersions(left, right) {
  const a = left.split(".").map(Number);
  const b = right.split(".").map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] < b[index] ? -1 : 1;
  }
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}
