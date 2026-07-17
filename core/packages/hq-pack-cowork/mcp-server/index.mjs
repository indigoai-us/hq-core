#!/usr/bin/env node
/**
 * hq-pack-cowork MCP server.
 *
 * A stdio MCP server that wraps the host `hq` CLI and `qmd` so Cowork (and any
 * other Claude Code plugin host whose bash runs in a sandbox) gets native HQ
 * tool calls.
 *
 * Runs on the HOST — not inside the sandbox — so it has access to:
 *   - the real `hq` binary on PATH
 *   - the real `qmd` binary on PATH
 *   - `~/.hq/cognito-tokens.json` (auth)
 *   - the user's home directory and Documents/HQ tree
 *
 * Auth artifacts (tokens, cognito session) stay on the host. The server never
 * RETURNS a secret value itself — it surfaces command output or sanitized error
 * text. But note the honest caveat below: the secret-injecting tools run host
 * commands with the user's privileges, so they are host-trusted, not a
 * cryptographic boundary.
 *
 * Tools exposed (all best-effort wrappers — see README for the exact `hq` /
 * `qmd` subcommand each one shells out to):
 *
 *   Identity / sync / search
 *     hq_whoami        — show current HQ identity + session expiry
 *     hq_sync          — bidirectional sync (mirrors HQ Desktop App "Sync Now")
 *     hq_team_sync     — pull latest team content for joined teams
 *     hq_search        — qmd hybrid search across HQ content
 *   Secrets (server never returns values; injecting tools are host-trusted)
 *     hq_secrets_exec  — run a command with named secrets injected as env vars
 *     hq_secrets_list  — list secret NAMES/metadata only (no values)
 *   Vault files
 *     hq_share         — mint a share-session URL or grant access on a vault path
 *     hq_files         — browse / cat / acl / search / shared-with-me / get
 *   Team & membership
 *     hq_members       — list / invite / revoke company memberships
 *     hq_groups        — list / members / create / delete / add / remove
 *     hq_dm            — send a direct message to a teammate
 *   Packages & modules
 *     hq_packages      — list / install / remove / update HQ packages
 *     hq_modules       — list / add / sync / update knowledge modules
 *   Meeting intelligence (read-only)
 *     hq_meetings      — list / get / search / transcript / notes
 *     hq_sources       — list / get / channels / entities
 *     hq_signals       — list / get / types / entities
 *   Feedback
 *     hq_feedback      — file a bug report or feature request
 *
 * Security envelope (honest framing — these tools are host-trusted, not an
 * airtight boundary):
 *   - The server never RETURNS secret values itself. `hq_secrets_exec` and
 *     `hq_run` inject secrets into a child process env; `hq_secrets_list` shows
 *     names only; the value-revealing path (`hq secrets get --reveal`) is NOT
 *     exposed, and the hq_cli escape hatch is a strict read-only allowlist that
 *     rejects `secrets`/`run`/`install`/etc.
 *   - Defense-in-depth: the secret-injecting tools REFUSE to launch a shell or
 *     a raw value-printing binary (printenv/echo/cat/node/base64/…), so an
 *     injected one-liner can't trivially echo an injected secret back.
 *   - HONEST CAVEAT: these tools run host commands with the user's full
 *     privileges. A determined or prompt-injected caller that runs a custom
 *     consumer binary it controls could still observe a secret it was given.
 *     Treat hq_secrets_exec / hq_run as HOST-TRUSTED capabilities, not a
 *     cryptographic guarantee. The binary denylist + escape-hatch allowlist +
 *     trusted-source install gate raise the bar; they do not make exfiltration
 *     impossible.
 *   - Cross-company isolation: `company` is always passed through verbatim
 *     when supplied; the server never guesses or falls back to another
 *     company's scope.
 *   - Share-session URLs are single-use capabilities — `hq_share` returns the
 *     minted URL once; callers must redact it in all later turns.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { isAbsolute, join, relative, resolve } from "node:path";
import { homedir } from "node:os";

// Throw a clear validation error when a required tool argument is missing.
function requireArg(value, name, ctx) {
  if (value === undefined || value === null || value === "") {
    throw new Error(`${ctx} requires "${name}".`);
  }
}

function requireStringArray(value, name, ctx) {
  if (!Array.isArray(value) || value.length === 0) {
    throw new Error(`${ctx} requires "${name}" as a non-empty string array.`);
  }
  for (const item of value) {
    if (typeof item !== "string" || item.length === 0) {
      throw new Error(`${ctx} "${name}" entries must be non-empty strings.`);
    }
  }
}

// ─── HQ root resolution ──────────────────────────────────────────────────────
// Same 4-tier resolver the HQ Desktop App / /hq-sync skill use, in order:
//   1. $HQ_ROOT env override
//   2. ~/.hq/menubar.json `hqPath` (canonical, hq-installer ≥ 0.1.28)
//   3. ~/.hq/config.json `hqFolderPath` (legacy)
//   4. Discovery via core/core.yaml signature in common paths
//   5. ~/Documents/HQ (last-resort default — matches this repo layout)
function resolveHqRoot() {
  if (process.env.HQ_ROOT && existsSync(process.env.HQ_ROOT)) {
    return process.env.HQ_ROOT;
  }
  const home = homedir();
  const tryJson = (path, key) => {
    try {
      const v = JSON.parse(readFileSync(path, "utf8"))[key];
      if (v && existsSync(v)) return v;
    } catch { /* fall through */ }
    return null;
  };
  return (
    tryJson(join(home, ".hq", "menubar.json"), "hqPath") ||
    tryJson(join(home, ".hq", "config.json"), "hqFolderPath") ||
    [
      "Documents/HQ", "Documents/hq", "HQ", "hq", "Desktop/HQ", "Desktop/hq",
    ]
      .map((rel) => join(home, rel))
      .find((p) => existsSync(join(p, "core", "core.yaml"))) ||
    join(home, "Documents", "HQ")
  );
}

const HQ_ROOT = resolveHqRoot();

function resolveHostCwd(cwd) {
  if (!cwd) return HQ_ROOT;
  const candidate = isAbsolute(cwd) ? resolve(cwd) : resolve(HQ_ROOT, cwd);
  const rel = relative(HQ_ROOT, candidate);
  if (rel === "" || (!rel.startsWith("..") && !isAbsolute(rel))) {
    return candidate;
  }
  throw new Error(`cwd must stay inside HQ_ROOT (${HQ_ROOT}). Got: ${cwd}`);
}

// Same HQ_ROOT-containment check as resolveHostCwd, but resolves a path
// relative to a caller-supplied base (e.g. the validated cwd for a --schema
// argument). Returns true iff `p` resolves to HQ_ROOT itself or a subpath of
// it. Used for SECURITY (CRITICAL-2) schema-path containment and the local
// install-source allowlist branch (HIGH-2).
function isInsideHqRoot(p, base = HQ_ROOT) {
  const candidate = isAbsolute(p) ? resolve(p) : resolve(base, p);
  const rel = relative(HQ_ROOT, candidate);
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

function boundedTimeoutMs(value) {
  if (value === undefined) return undefined;
  const n = Number(value);
  if (!Number.isFinite(n) || n < 1000 || n > 300000) {
    throw new Error("timeoutMs must be between 1000 and 300000.");
  }
  return n;
}

// Map a caller-supplied qmd output format to qmd's bare format flags. qmd has
// NO `--format <x>` flag — the formats are bare flags: --json --md --csv --xml
// --files (default = human snippet, no flag). Unknown / "cli" / "snippet" →
// no flag → human snippet (qmd's default).
function qmdFormatArgs(fmt) {
  const ok = new Set(["json", "md", "csv", "xml", "files"]);
  return ok.has(String(fmt || "").toLowerCase()) ? ["--" + String(fmt).toLowerCase()] : [];
}

function resolveBin(bin) {
  const envKey = `${bin.toUpperCase().replace(/[^A-Z0-9]/g, "_")}_BIN`;
  // SECURITY (MEDIUM-2): only honor the ${BIN}_BIN override when it is an
  // ABSOLUTE path that exists on disk. A relative override would be resolved
  // against an attacker-influenced cwd and could shadow the real binary with a
  // planted executable; require an absolute, existing path before trusting it.
  if (
    process.env[envKey] &&
    isAbsolute(process.env[envKey]) &&
    existsSync(process.env[envKey])
  ) {
    return process.env[envKey];
  }
  const home = homedir();
  const candidates = [
    ...new Set([
      ...(process.env.PATH || "").split(":").filter(Boolean).map((p) => join(p, bin)),
      join(home, ".cargo", "bin", bin),
      join(home, ".local", "bin", bin),
      join(home, "bin", bin),
      join("/opt/homebrew/bin", bin),
      join("/usr/local/bin", bin),
      join("/usr/bin", bin),
    ]),
  ];
  return candidates.find((p) => existsSync(p)) || bin;
}

// SECURITY (HIGH-1): the hq_cli escape hatch is a strict ALLOWLIST, not a
// denylist. A denylist is unsound here — every `hq` subcommand we forget to
// block (and every future subcommand) would otherwise be reachable by an
// injected caller. We only permit known read-only / low-risk subcommands
// through this generic hatch; anything that consumes secrets, mutates auth,
// installs code, or shares data must go through its dedicated, individually
// guarded typed tool (hq_secrets_exec, hq_run, hq_packages, hq_modules,
// hq_share, …). Gated at the (top, sub) pair level so sub-subcommand parsing
// stays simple and auditable.
//
//   value `null`  → top-level command allowed with no subcommand requirement
//                   (any/no sub token is fine; the command itself is read-only)
//   value Set(…)  → top-level command allowed ONLY when the first sub token is
//                   a member of the set
const HQ_CLI_ALLOWED = new Map([
  ["whoami", null],
  ["version", null],
  ["--version", null],
  ["help", null],
  ["--help", null],
  ["feedback", null],
  ["auth", new Set(["status", "refresh"])],
  ["sync", new Set(["status"])],
  ["files", new Set(["list", "acl", "browse", "search", "shared-with-me"])],
  ["packages", new Set(["list"])],
  ["modules", new Set(["list"])],
  ["members", new Set(["list"])],
  ["groups", new Set(["list", "members"])],
]);

function validateHqCliArgs(args) {
  requireStringArray(args, "args", "hq_cli");
  // args[0] is the top-level subcommand. It must be a bare token (the bare
  // `--version` / `--help` forms are handled as top-level tokens by the
  // allowlist below) — a leading passthrough global flag is rejected so it
  // can't shift the real subcommand to args[1] and slip past the cmd gate.
  const cmd = args[0];
  if (typeof cmd === "string" && cmd.startsWith("-") &&
      cmd !== "--version" && cmd !== "--help") {
    throw new Error(
      `hq_cli expects the subcommand first; a leading flag ("${cmd}") is not allowed.`,
    );
  }
  if (!HQ_CLI_ALLOWED.has(cmd)) {
    throw new Error(
      `hq_cli only permits a fixed allowlist of read-only HQ subcommands; "${cmd}" is not allowed. ` +
      `Use the dedicated typed tool instead — secrets → hq_secrets_exec, run → hq_run, ` +
      `install/packages → hq_packages, modules → hq_modules, share/files → hq_share / hq_files, ` +
      `login/logout/onboard/deploy are host-side operations.`,
    );
  }
  const allowedSubs = HQ_CLI_ALLOWED.get(cmd);
  if (allowedSubs) {
    // For a sub-gated command the subcommand MUST be the very next token
    // (`args[1]`) — natural form `hq <cmd> <sub> [flags...]`. We deliberately
    // do NOT walk past leading flags: a flag before the subcommand is
    // ambiguous and is rejected so the caller can't smuggle the real sub past
    // the gate (e.g. `["files","--json","list"]`).
    const sub = args[1];
    if (typeof sub !== "string" || sub.startsWith("-")) {
      throw new Error(
        `hq_cli requires the subcommand immediately after "${cmd}" ` +
        `(natural form: \`hq ${cmd} <sub> [flags...]\`, sub ∈ ${[...allowedSubs].join(", ")}). ` +
        `Put the subcommand first — a leading flag${typeof sub === "string" ? ` ("${sub}")` : ""} is not allowed before it.`,
      );
    }
    if (!allowedSubs.has(sub)) {
      throw new Error(
        `hq_cli allows \`hq ${cmd}\` only with subcommand(s): ${[...allowedSubs].join(", ")}. ` +
        `Got: ${sub}. Use the dedicated typed tool for other operations.`,
      );
    }
  }
}

// SECURITY (CRITICAL-1, defense-in-depth): basenames of binaries that are
// either a shell or a raw value-printing utility. The secret-injecting tools
// (hq_secrets_exec / hq_run) put secret values into the child env, so if an
// injected instruction could run `printenv` / `bash -c 'echo $SECRET'` /
// `node -e ...` the value would be trivially echoed back to the model. We
// refuse to launch any of these as cmd[0] so a single forwarded argv can't
// turn a secret-injecting tool into a secret-exfiltration primitive.
//
// Scope of the denylist: block only binaries that can read an env var and PRINT
// it back WITHOUT a shell — i.e. shells, pure value-printers, and scripting
// interpreters that read the process env directly. We deliberately ALLOW normal
// consumer tools (git, ssh, curl, make, find, …): they can't trivially
// exfiltrate a *named* secret without a shell (which is already blocked) and
// they have real deploy uses (e.g. `git` with an injected token).
//
// NOTE: this is DEFENSE-IN-DEPTH, not airtight. These tools run host commands
// with the user's privileges; a determined/injected caller can still invoke a
// custom consumer binary (or a wrapper) that prints what it was given. The
// denylist raises the bar against the trivial one-liner exfil, not against an
// arbitrary purpose-built binary. Treat these tools as host-trusted.
const SECRET_EXEC_BLOCKED_BINS = new Set([
  // shells
  "sh", "bash", "zsh", "dash", "ksh", "fish",
  // pure value-printers (read an env var and echo it back)
  "printenv", "env", "echo", "printf", "cat", "tee",
  "set", "declare", "export",
  "base64", "xxd", "od", "hexdump", "strings",
  // scripting interpreters that read the process env directly
  "node", "deno", "bun", "python", "python3", "perl", "ruby", "php",
  "awk", "gawk", "mawk", "nawk", "lua", "tclsh", "expect",
  "rscript", "osascript",
]);

// Strip any directory component and a trailing platform separator so the
// denylist matches on `/bin/bash`, `bash`, `./bash` alike.
function commandBasename(cmd0) {
  return String(cmd0).split(/[\\/]/).pop();
}

// Reject when cmd[0]'s basename is a shell / value-printing binary. Shared by
// hq_secrets_exec and hq_run.
function assertSecretSafeCommand(cmd, ctx) {
  // Case-fold the basename so `BASH`/`Bash`/`Rscript` are caught on
  // case-insensitive filesystems. (Denylist entries are stored lowercased.)
  const base = commandBasename(cmd[0]).toLowerCase();
  if (SECRET_EXEC_BLOCKED_BINS.has(base)) {
    throw new Error(
      `${ctx} refuses to run "${base}": secret-injecting tools cannot launch a shell or a raw ` +
      `value-printing binary, so an injected instruction can't trivially exfiltrate an injected ` +
      `secret. Invoke the actual consumer binary directly instead (e.g. vercel, aws, gh, or a deploy script).`,
    );
  }
}

// SECURITY (HIGH-2): install-source allowlist for hq_packages install /
// hq_modules add. Only first-party indigoai-us sources (npm-style, github:
// shorthand, bare org/repo, or full github.com URL) — OR a local filesystem
// path that resolves inside HQ_ROOT — may be installed. Arbitrary git URLs and
// other orgs are rejected so an injected caller can't install attacker code.
const TRUSTED_INSTALL_PREFIXES = [
  "@indigoai-us/",
  "github:indigoai-us/",
  "indigoai-us/",
];

// Parse an http(s) source and accept it only when it is a clean github.com URL
// owned by the indigoai-us org. Proper URL parsing (vs. a string prefix check)
// closes both the path-naive residual (`https://github.com/indigoai-us/../evil`)
// and the over-strict casing issue (`https://GitHub.com/...`). Returns true if
// the URL is a trusted github.com/indigoai-us source, false otherwise.
function isTrustedGithubUrl(source) {
  let url;
  try {
    url = new URL(source);
  } catch {
    return false; // malformed → reject
  }
  if (url.protocol !== "https:") return false;
  if (url.hostname.toLowerCase() !== "github.com") return false;
  // Reject traversal / userinfo smuggling anywhere in the path.
  if (url.pathname.includes("..") || url.pathname.includes("@")) return false;
  const segments = url.pathname.split("/").filter(Boolean);
  return segments[0] === "indigoai-us";
}

function validateInstallSource(source, ctx) {
  if (typeof source !== "string" || source.length === 0) {
    throw new Error(`${ctx} requires a non-empty source.`);
  }
  const isHttp = /^https?:\/\//i.test(source);
  const trusted = isHttp
    ? isTrustedGithubUrl(source)
    : TRUSTED_INSTALL_PREFIXES.some((p) => source.startsWith(p));
  // A local path is allowed only when it (resolved relative to HQ_ROOT, or as
  // an absolute path) stays inside HQ_ROOT. Reject `..` traversal / outside.
  const localInside =
    // A bare colon (`:`) disqualifies the "local path" branch: it would
    // otherwise admit SCP-style git refs (`git@host:org/repo.git`) and
    // `scheme:` shorthands, which resolve() treats as innocent relative
    // filenames and would wrongly pass the HQ_ROOT containment check.
    !source.includes(":") &&
    !source.startsWith("@") &&
    isInsideHqRoot(source);
  if (!trusted && !localInside) {
    throw new Error(
      `${ctx} only installs first-party indigoai-us sources ` +
      `(@indigoai-us/…, github:indigoai-us/…, indigoai-us/…, https://github.com/indigoai-us/…) ` +
      `or a local path inside HQ_ROOT. Refusing untrusted source: ${source}`,
    );
  }
}

// ─── Shell wrappers ──────────────────────────────────────────────────────────
// `hq` and `qmd` may be launched from a plugin host with a reduced PATH, so
// resolve common host install locations before falling back to execFile's PATH.
async function runBin(bin, args, opts = {}) {
  const { input, ...execOpts } = opts;
  const resolvedBin = resolveBin(bin);
  try {
    const exec = () =>
      new Promise((resolve, reject) => {
        const child = execFile(
          resolvedBin,
          args,
          { cwd: HQ_ROOT, maxBuffer: 1 << 24, ...execOpts },
          (err, stdout, stderr) => {
            if (err) {
              err.stdout = stdout;
              err.stderr = stderr;
              reject(err);
            } else {
              resolve({ stdout, stderr });
            }
          },
        );
        // Pipe `input` to the child's stdin (used by `--body-file -` etc.).
        if (input !== undefined && child.stdin) {
          child.stdin.end(input);
        }
      });
    const { stdout, stderr } = await exec();
    const out = (stdout || "").trim();
    const err = (stderr || "").trim();
    if (out && err) return `${out}\n[stderr]\n${err}`;
    return out || err || "(no output)";
  } catch (e) {
    if (e.code === "ENOENT") {
      throw new Error(
        `\`${bin}\` not found on the plugin host PATH or common install paths. Install it on the host machine before ` +
        `running this MCP server (hq: \`npm i -g @indigoai-us/hq-cli\`; qmd: ` +
        `\`npm install -g @tobilu/qmd\`, plus \`brew install sqlite\` on macOS). You can also set ${bin.toUpperCase()}_BIN to an absolute path.`,
      );
    }
    // execFile rejects with an Error whose .stdout / .stderr hold the child's output.
    const detail = [e.stdout, e.stderr].filter(Boolean).join("\n").trim();
    throw new Error(detail ? `${e.message}\n${detail}` : e.message);
  }
}

const hq = (args, opts) => runBin("hq", args, opts);
const qmd = (args, opts) => runBin("qmd", args, opts);

// ─── Tool definitions ────────────────────────────────────────────────────────
const TOOLS = [
  {
    name: "hq_whoami",
    description:
      "Show the currently-authenticated HQ identity (email, session expiry). " +
      "Use to confirm the host MCP server is wired to a logged-in HQ session.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "hq_sync",
    description:
      "Bidirectional sync against the HQ vault — mirrors the HQ Desktop App " +
      "'Sync Now' button. By default syncs every cloud-backed " +
      "company you're a member of plus your personal vault. Use `company` to " +
      "scope to one company, or `personal: true` to sync only your personal " +
      "vault. Wraps `hq sync now`.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        company: {
          type: "string",
          description: "Company slug to scope sync to. Omit + omit `personal` to sync all memberships + personal.",
        },
        personal: {
          type: "boolean",
          description: "Sync only the caller's canonical personal vault.",
        },
        onConflict: {
          type: "string",
          enum: ["overwrite", "keep", "abort"],
          description: "Conflict strategy. Default: keep (writes conflict mirrors instead of overwriting).",
        },
        message: {
          type: "string",
          description: "Optional human-readable message attached to push-leg journal entries.",
        },
      },
    },
  },
  {
    name: "hq_share",
    description:
      "Share a vault path. Without `with`, mints a single-use encrypted share-" +
      "session URL (default 15-min expiry, max 24h) and prints it. With `with`, " +
      "grants direct access to a person (email), group id, or `@all` (every " +
      "active company member). Wraps `hq files share`.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["path"],
      properties: {
        path: {
          type: "string",
          description: "Vault path or prefix to share (e.g. companies/foo/knowledge/x.md).",
        },
        with: {
          type: "string",
          description: "Email address, group id, or '@all'. Omit to mint a share-session URL instead.",
        },
        permission: {
          type: "string",
          enum: ["read", "write"],
          description: "Permission level (only meaningful with `with`).",
        },
        expires: {
          type: "string",
          description: "Token expiry duration for share-session URL (e.g. 15m, 1h, 24h). Default 15m.",
        },
      },
    },
  },
  {
    name: "hq_secrets_exec",
    description:
      "Run a command on the host with one or more named HQ secrets injected " +
      "as environment variables. Secret values are NEVER returned to the " +
      "model — only the command's stdout/stderr. Wraps `hq secrets exec --only`.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["keys", "cmd"],
      properties: {
        keys: {
          type: "array",
          items: { type: "string" },
          description: "Secret names to inject (will become env vars of the same name).",
          minItems: 1,
        },
        cmd: {
          type: "array",
          items: { type: "string" },
          description: "Command + args to run (argv0 + arguments — not a shell string).",
          minItems: 1,
        },
        company: {
          type: "string",
          description: "Company slug. Omit to use the active company in ~/.hq/config.json.",
        },
        personal: {
          type: "boolean",
          description: "Pull from the caller's personal vault instead of a company vault.",
        },
      },
    },
  },
  {
    name: "hq_search",
    description:
      "Hybrid full-text + semantic search across indexed HQ content (policies, " +
      "skills, knowledge, workers, projects, and per-company collections). " +
      "Uses `qmd query` (hybrid: expansion + RRF + rerank — the recommended " +
      "search mode). Scope with `collection`.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["query"],
      properties: {
        query: { type: "string", description: "Natural-language search query." },
        collection: {
          type: "string",
          description: "qmd collection to scope to (e.g. hq-infra, hq-knowledge, indigo). Omit to search all.",
        },
        limit: {
          type: "integer",
          minimum: 1,
          maximum: 50,
          description: "Number of results. Default 10.",
        },
        format: {
          type: "string",
          enum: ["cli", "json", "md", "files"],
          description: "Output format. Default cli (human-readable).",
        },
      },
    },
  },
  {
    name: "hq_qmd",
    description:
      "Host-side qmd adapter for Cowork. Mirrors the same qmd-first HQ " +
      "workflow used in Claude Code/Codex: list collections, inspect index " +
      "status, list/read documents, multi-get, keyword/semantic/hybrid search, " +
      "ask questions over indexed context, or refresh the index after sync.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: {
          type: "string",
          enum: [
            "collections",
            "status",
            "list",
            "get",
            "multi_get",
            "search",
            "semantic_search",
            "hybrid_search",
            "ask",
            "refresh_index",
          ],
          description: "qmd operation to run.",
        },
        target: { type: "string", description: "Collection/path/docid target for list/get." },
        pattern: { type: "string", description: "Glob pattern or comma-separated files for multi_get." },
        query: { type: "string", description: "Search query or question." },
        collection: { type: "string", description: "qmd collection to scope search/ask." },
        limit: { type: "integer", minimum: 1, maximum: 100, description: "Result/context limit." },
        format: {
          type: "string",
          enum: ["cli", "json", "md", "files"],
          description: "Output format for search/multi_get. Default cli.",
        },
        fromLine: { type: "integer", minimum: 1, description: "get only: starting line." },
        maxLines: { type: "integer", minimum: 1, maximum: 2000, description: "get/multi_get only: max lines." },
        lineNumbers: { type: "boolean", description: "get only: include line numbers." },
        maxBytes: { type: "integer", minimum: 100, maximum: 1048576, description: "multi_get only: skip files larger than this." },
        maxTokens: { type: "integer", minimum: 100, maximum: 8000, description: "ask only: answer token cap." },
      },
    },
  },
  {
    name: "hq_team_sync",
    description:
      "Pull the latest team content for every team you've joined (one-way " +
      "down-sync of shared team material). Use `team` to scope to a single " +
      "team slug, or `dryRun` to preview without writing. Wraps `hq team-sync`.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        team: { type: "string", description: "Sync only this team slug. Omit for all joined teams." },
        dryRun: { type: "boolean", description: "Show what would be synced without making changes." },
      },
    },
  },
  {
    name: "hq_secrets_list",
    description:
      "List secret NAMES (and path-based nested names) for a company or the " +
      "caller's personal vault. Returns metadata only — secret VALUES are " +
      "never returned (use hq_secrets_exec to consume a value). Wraps " +
      "`hq secrets list`.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        company: { type: "string", description: "Company slug. Omit to use the active company." },
        personal: { type: "boolean", description: "List the caller's personal-vault secrets instead." },
        prefix: { type: "string", description: "Filter by path prefix (e.g. DEV or DEV/SUB)." },
      },
    },
  },
  {
    name: "hq_files",
    description:
      "Read / inspect HQ vault objects without a full sync. Actions: " +
      "`browse` (list objects under a path), `cat` (stream one object to text), " +
      "`acl` (show the access-control list for a prefix), `search` (match vault " +
      "object keys by path/name — content search unsupported), `shared-with-me` " +
      "(list grants made to you), `get` (materialize a file/prefix into local " +
      "HQ on the host). Wraps `hq files <action>`.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: {
          type: "string",
          enum: ["browse", "cat", "acl", "search", "shared-with-me", "get"],
          description: "Which files subcommand to run.",
        },
        path: {
          type: "string",
          description: "Vault path/prefix. Required for cat/acl/get; optional for browse; ignored by shared-with-me. For search this is the query.",
        },
        query: { type: "string", description: "Search query (action=search). Alias for `path`." },
        company: { type: "string", description: "Company slug (defaults to the slug parsed from the path)." },
        personal: { type: "boolean", description: "Operate on the caller's personal vault instead of a company vault." },
        into: { type: "string", description: "action=get only: write into this dir instead of in-place under companies/<slug>/." },
      },
    },
  },
  {
    name: "hq_members",
    description:
      "Manage company memberships. Actions: `list` (pending invites), " +
      "`invite` (invite by email or personUid — sends an email by default), " +
      "`revoke` (cancel a pending invite). Wraps `hq members <action>`.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: { type: "string", enum: ["list", "invite", "revoke"], description: "Which members subcommand." },
        target: { type: "string", description: "Email or personUid. Required for invite/revoke." },
        company: { type: "string", description: "Company slug." },
        role: { type: "string", enum: ["owner", "admin", "member", "guest"], description: "invite only: role for the invitee (default member)." },
        paths: { type: "string", description: "invite+guest only: comma-separated allowed prefixes." },
        noSendEmail: { type: "boolean", description: "invite only: skip the server-side invitation email." },
      },
    },
  },
  {
    name: "hq_groups",
    description:
      "Manage secret/permission groups. Actions: `list`, `members` (list a " +
      "group's members), `create`, `delete`, `add` (add a principal), `remove` " +
      "(remove a principal). Wraps `hq groups <action>`.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: { type: "string", enum: ["list", "members", "create", "delete", "add", "remove"], description: "Which groups subcommand." },
        groupId: { type: "string", description: "Group id. Required for all actions except list." },
        principal: { type: "string", description: "Email or personUid. Required for add/remove." },
        name: { type: "string", description: "create only: human-readable group name." },
        description: { type: "string", description: "create only: optional description." },
        company: { type: "string", description: "Company slug." },
      },
    },
  },
  {
    name: "hq_dm",
    description:
      "Send a direct message to a teammate (by email or personUid). They " +
      "receive it as an HQ Desktop App notification. Optionally attach an " +
      "agent `prompt` they can one-click copy, longer `details`, or schedule " +
      "delivery with `at` (ISO8601) or `in` (e.g. 30s, 10m, 2h, 1d). Only " +
      "reaches people you share an active company with. Wraps `hq dm`.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["recipient", "message"],
      properties: {
        recipient: { type: "string", description: "Email address or personUid of the teammate." },
        message: { type: "string", description: "The message body." },
        prompt: { type: "string", description: "Agent-context prompt the recipient can one-click copy into their agent." },
        details: { type: "string", description: "Longer detail shown in the recipient's DM detail window." },
        at: { type: "string", description: "Schedule delivery at an ISO8601 time (store-and-forward)." },
        in: { type: "string", description: "Schedule delivery after a relative delay: 30s, 10m, 2h, 1d." },
      },
    },
  },
  {
    name: "hq_packages",
    description:
      "Manage HQ packages. Actions: `list` (installed + available), `install` " +
      "(source = bare slug, @scope/name[@ver], git URL[#ref], or local path), " +
      "`remove` (archives first), `update` (check/apply updates, optionally one " +
      "slug). Wraps `hq packages <action>` / `hq install` / `hq remove`.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: { type: "string", enum: ["list", "install", "remove", "update"], description: "Which packages subcommand." },
        source: { type: "string", description: "install only: package source (slug, @scope/name, git URL, or path)." },
        slug: { type: "string", description: "remove (required) / update (optional) target slug." },
      },
    },
  },
  {
    name: "hq_modules",
    description:
      "Manage knowledge modules declared in the HQ manifest. Actions: `list`, " +
      "`add` (by repo URL), `sync` (pull all from manifest), `update` (refresh " +
      "lock for one module or all). Wraps `hq modules <action>`.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: { type: "string", enum: ["list", "add", "sync", "update"], description: "Which modules subcommand." },
        repoUrl: { type: "string", description: "add only: git repo URL of the module." },
        moduleName: { type: "string", description: "update only: module name to refresh (omit for all)." },
      },
    },
  },
  {
    name: "hq_meetings",
    description:
      "Read recorded meetings. Actions: `list` (newest first), `get` (details " +
      "for one meetingId), `search` (by title/participant), `transcript`, " +
      "`notes` (AI-generated). Wraps `hq meetings <action>`.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: { type: "string", enum: ["list", "get", "search", "transcript", "notes"], description: "Which meetings subcommand." },
        meetingId: { type: "string", description: "Required for get/transcript/notes." },
        query: { type: "string", description: "search only: title or participant query." },
        limit: { type: "integer", minimum: 1, maximum: 200, description: "list only: number of meetings (default 20)." },
        company: { type: "string", description: "Company slug (for multi-company users)." },
        json: { type: "boolean", description: "Return raw JSON instead of formatted text." },
      },
    },
  },
  {
    name: "hq_sources",
    description:
      "Read sources (meeting / email / slack / linear / notion) attached to a " +
      "vault entity. Actions: `list` (by channel), `get` (one by id), " +
      "`channels` (enumerate canonical channels), `entities` (entities you can " +
      "access). Wraps `hq sources <action>`.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: { type: "string", enum: ["list", "get", "channels", "entities"], description: "Which sources subcommand." },
        entity: { type: "string", description: "Entity slug (defaults to active company)." },
        type: { type: "string", enum: ["meeting", "email", "slack", "linear", "notion"], description: "Source channel (list/get)." },
        id: { type: "string", description: "get only: source id (filename minus .md)." },
        limit: { type: "integer", minimum: 1, maximum: 200, description: "list only: max entries per page (default 50)." },
        json: { type: "boolean", description: "Return JSON instead of a table." },
      },
    },
  },
  {
    name: "hq_signals",
    description:
      "Read extracted signals (action_item / commitment / decision / key_point " +
      "/ risk / summary) for a vault entity. Actions: `list` (by type), `get` " +
      "(one by id), `types` (enumerate canonical types), `entities`. Wraps " +
      "`hq signals <action>`.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: { type: "string", enum: ["list", "get", "types", "entities"], description: "Which signals subcommand." },
        entity: { type: "string", description: "Entity slug (defaults to active company)." },
        type: { type: "string", enum: ["action_item", "commitment", "decision", "key_point", "risk", "summary"], description: "Signal type (list/get)." },
        id: { type: "string", description: "get only: signal id (filename minus .md)." },
        limit: { type: "integer", minimum: 1, maximum: 200, description: "list only: max entries per page (default 50)." },
        json: { type: "boolean", description: "Return JSON instead of a table." },
      },
    },
  },
  {
    name: "hq_feedback",
    description:
      "File a bug report or feature request to the HQ team. Actions: `bug`, " +
      "`feature`. Provide a `title` and `body` (markdown). Wraps `hq feedback " +
      "<action>` (body piped via --body-file -).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["action", "title", "body"],
      properties: {
        action: { type: "string", enum: ["bug", "feature"], description: "Report kind." },
        title: { type: "string", description: "Short title for the report." },
        body: { type: "string", description: "Markdown body (piped to the CLI via stdin)." },
        company: { type: "string", description: "Company slug to associate with the report." },
      },
    },
  },
  {
    name: "hq_run",
    description:
      "Run a host command through `hq run`, resolving .env.schema and injecting " +
      "HQ secrets as environment variables without returning secret values. " +
      "Use for repo workflows that need company-scoped secrets from Cowork.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        cmd: {
          type: "array",
          items: { type: "string" },
          description: "Command + args to run after `hq run --`. Omit when check=true.",
        },
        cwd: {
          type: "string",
          description: "Working directory inside HQ_ROOT. Defaults to HQ_ROOT.",
        },
        company: { type: "string", description: "Company slug override." },
        schema: { type: "string", description: "Explicit .env.schema path, relative to cwd or absolute inside HQ_ROOT." },
        check: { type: "boolean", description: "Validate env resolution without executing cmd." },
        timeoutMs: { type: "integer", minimum: 1000, maximum: 300000, description: "Optional process timeout." },
      },
    },
  },
  {
    name: "hq_cli",
    description:
      "Guarded escape hatch for HQ CLI capabilities not yet modeled as " +
      "dedicated MCP tools. Runs `hq <args...>` on the host inside HQ_ROOT. " +
      "Blocks browser/session flows and secret-value output; prefer dedicated " +
      "tools when they exist.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["args"],
      properties: {
        args: {
          type: "array",
          items: { type: "string" },
          minItems: 1,
          description: "Arguments after `hq`, e.g. [\"sync\", \"status\"]. Not a shell string.",
        },
        stdin: { type: "string", description: "Optional stdin for commands that safely read non-secret body text." },
        cwd: { type: "string", description: "Working directory inside HQ_ROOT. Defaults to HQ_ROOT." },
        timeoutMs: { type: "integer", minimum: 1000, maximum: 300000, description: "Optional process timeout." },
      },
    },
  },
];

// ─── Tool dispatch ───────────────────────────────────────────────────────────
const server = new Server(
  { name: "hq", version: "0.1.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: a = {} } = req.params;
  try {
    let out;
    switch (name) {
      case "hq_whoami":
        out = await hq(["whoami"]);
        break;

      case "hq_sync": {
        const args = ["sync", "now"];
        if (a.personal) {
          args.push("--personal");
        } else if (a.company) {
          args.push("--company", a.company);
        } else {
          args.push("--all");
        }
        if (a.onConflict) args.push("--on-conflict", a.onConflict);
        else args.push("--on-conflict", "keep");
        if (a.message) args.push("--message", a.message);
        args.push("--hq-root", HQ_ROOT);
        out = await hq(args);
        break;
      }

      case "hq_share": {
        const args = ["files", "share", a.path];
        if (a.with) args.push("--with", a.with);
        if (a.permission) args.push("--permission", a.permission);
        if (a.expires) args.push("--expires", a.expires);
        // Never auto-open a browser from a sandboxed-agent call site.
        if (!a.with) args.push("--no-open");
        out = await hq(args);
        break;
      }

      case "hq_secrets_exec": {
        // SECURITY (CRITICAL-1, defense-in-depth): refuse shells / value-printing
        // binaries so an injected argv can't echo the injected secret back.
        assertSecretSafeCommand(a.cmd, "hq_secrets_exec");
        const args = ["secrets", "exec", "--only", a.keys.join(",")];
        if (a.company) args.push("--company", a.company);
        if (a.personal) args.push("--personal");
        args.push("--", ...a.cmd);
        out = await hq(args);
        break;
      }

      case "hq_search": {
        const args = ["query"];
        if (a.collection) args.push("-c", a.collection);
        if (a.limit) args.push("-n", String(a.limit));
        args.push(...qmdFormatArgs(a.format));
        args.push(a.query);
        out = await qmd(args);
        break;
      }

      case "hq_qmd": {
        let args;
        switch (a.action) {
          case "collections":
            args = ["collection", "list"];
            break;
          case "status":
            args = ["status"];
            break;
          case "list":
            args = ["ls"];
            if (a.target) args.push(a.target);
            break;
          case "get":
            requireArg(a.target, "target", "qmd get");
            args = ["get"];
            if (a.fromLine) args.push("--from-line", String(a.fromLine));
            if (a.maxLines) args.push("--max-lines", String(a.maxLines));
            if (a.lineNumbers) args.push("--line-numbers");
            args.push(a.target);
            break;
          case "multi_get":
            requireArg(a.pattern, "pattern", "qmd multi_get");
            args = ["multi-get"];
            if (a.maxLines) args.push("--max-lines", String(a.maxLines));
            if (a.maxBytes) args.push("--max-bytes", String(a.maxBytes));
            args.push(...qmdFormatArgs(a.format));
            args.push(a.pattern);
            break;
          case "search":
          case "semantic_search":
          case "hybrid_search": {
            requireArg(a.query, "query", `qmd ${a.action}`);
            const cmd = a.action === "semantic_search" ? "vsearch" : a.action === "search" ? "search" : "query";
            args = [cmd];
            if (a.collection) args.push("-c", a.collection);
            if (a.limit) args.push("-n", String(a.limit));
            args.push(...qmdFormatArgs(a.format));
            args.push(a.query);
            break;
          }
          case "ask":
            requireArg(a.query, "query", "qmd ask");
            args = ["ask"];
            if (a.collection) args.push("-c", a.collection);
            if (a.limit) args.push("-n", String(a.limit));
            if (a.maxTokens) args.push("--max-tokens", String(a.maxTokens));
            args.push(a.query);
            break;
          case "refresh_index":
            args = ["update"];
            break;
          default:
            throw new Error(`Unknown hq_qmd action: ${a.action}`);
        }
        out = await qmd(args);
        break;
      }

      case "hq_team_sync": {
        const args = ["team-sync"];
        if (a.team) args.push("--team", a.team);
        if (a.dryRun) args.push("--dry-run");
        out = await hq(args);
        break;
      }

      case "hq_secrets_list": {
        const args = ["secrets", "list"];
        if (a.company) args.push("--company", a.company);
        if (a.personal) args.push("--personal");
        if (a.prefix) args.push("--prefix", a.prefix);
        out = await hq(args);
        break;
      }

      case "hq_files": {
        const sub = a.action;
        const target = a.query ?? a.path;
        let args;
        switch (sub) {
          case "browse":
            args = ["files", "browse"];
            if (target) args.push(target);
            break;
          case "cat":
            requireArg(target, "path", "files cat");
            args = ["files", "cat", target];
            break;
          case "acl":
            requireArg(target, "path", "files acl");
            args = ["files", "acl", target];
            break;
          case "search":
            requireArg(target, "query", "files search");
            args = ["files", "search", target];
            break;
          case "shared-with-me":
            args = ["files", "shared-with-me"];
            break;
          case "get":
            requireArg(target, "path", "files get");
            args = ["files", "get", target];
            if (a.into) args.push("--into", a.into);
            break;
          default:
            throw new Error(`Unknown hq_files action: ${sub}`);
        }
        if (a.company) args.push("--company", a.company);
        if (a.personal) args.push("--personal");
        if (["browse", "cat", "get"].includes(sub)) args.push("--hq-root", HQ_ROOT);
        out = await hq(args);
        break;
      }

      case "hq_members": {
        let args;
        switch (a.action) {
          case "list":
            args = ["members", "list"];
            break;
          case "invite":
            requireArg(a.target, "target", "members invite");
            args = ["members", "invite", a.target];
            if (a.role) args.push("--role", a.role);
            if (a.paths) args.push("--paths", a.paths);
            if (a.noSendEmail) args.push("--no-send-email");
            break;
          case "revoke":
            requireArg(a.target, "target", "members revoke");
            args = ["members", "revoke", a.target];
            break;
          default:
            throw new Error(`Unknown hq_members action: ${a.action}`);
        }
        if (a.company) args.push("--company", a.company);
        out = await hq(args);
        break;
      }

      case "hq_groups": {
        let args;
        switch (a.action) {
          case "list":
            args = ["groups", "list"];
            break;
          case "members":
            requireArg(a.groupId, "groupId", "groups members");
            args = ["groups", "members", a.groupId];
            break;
          case "create":
            requireArg(a.groupId, "groupId", "groups create");
            args = ["groups", "create", a.groupId];
            if (a.name) args.push("--name", a.name);
            if (a.description) args.push("--description", a.description);
            break;
          case "delete":
            requireArg(a.groupId, "groupId", "groups delete");
            args = ["groups", "delete", a.groupId];
            break;
          case "add":
            requireArg(a.groupId, "groupId", "groups add");
            requireArg(a.principal, "principal", "groups add");
            args = ["groups", "add", a.groupId, a.principal];
            break;
          case "remove":
            requireArg(a.groupId, "groupId", "groups remove");
            requireArg(a.principal, "principal", "groups remove");
            args = ["groups", "remove", a.groupId, a.principal];
            break;
          default:
            throw new Error(`Unknown hq_groups action: ${a.action}`);
        }
        if (a.company) args.push("--company", a.company);
        out = await hq(args);
        break;
      }

      case "hq_dm": {
        const args = ["dm"];
        if (a.prompt) args.push("--prompt", a.prompt);
        if (a.details) args.push("--details", a.details);
        if (a.at) args.push("--at", a.at);
        if (a.in) args.push("--in", a.in);
        args.push(a.recipient, a.message);
        out = await hq(args);
        break;
      }

      case "hq_packages": {
        let args;
        switch (a.action) {
          case "list":
            args = ["packages", "list"];
            break;
          case "install":
            requireArg(a.source, "source", "packages install");
            // SECURITY (HIGH-2): only first-party indigoai-us sources or local
            // HQ_ROOT paths may be installed via this tool.
            validateInstallSource(a.source, "hq_packages install");
            args = ["install", a.source];
            break;
          case "remove":
            requireArg(a.slug, "slug", "packages remove");
            args = ["remove", a.slug];
            break;
          case "update":
            args = ["packages", "update"];
            if (a.slug) args.push(a.slug);
            break;
          default:
            throw new Error(`Unknown hq_packages action: ${a.action}`);
        }
        out = await hq(args);
        break;
      }

      case "hq_modules": {
        let args;
        switch (a.action) {
          case "list":
            args = ["modules", "list"];
            break;
          case "add":
            requireArg(a.repoUrl, "repoUrl", "modules add");
            // SECURITY (HIGH-2): only first-party indigoai-us sources or local
            // HQ_ROOT paths may be added as modules.
            validateInstallSource(a.repoUrl, "hq_modules add");
            args = ["modules", "add", a.repoUrl];
            break;
          case "sync":
            args = ["modules", "sync"];
            break;
          case "update":
            args = ["modules", "update"];
            if (a.moduleName) args.push(a.moduleName);
            break;
          default:
            throw new Error(`Unknown hq_modules action: ${a.action}`);
        }
        out = await hq(args);
        break;
      }

      case "hq_meetings": {
        const pre = ["meetings"];
        if (a.company) pre.push("--company", a.company);
        if (a.json) pre.push("--json");
        let args;
        switch (a.action) {
          case "list":
            args = [...pre, "list"];
            if (a.limit) args.push("--limit", String(a.limit));
            break;
          case "get":
            requireArg(a.meetingId, "meetingId", "meetings get");
            args = [...pre, "get", a.meetingId];
            break;
          case "search":
            requireArg(a.query, "query", "meetings search");
            args = [...pre, "search", a.query];
            break;
          case "transcript":
            requireArg(a.meetingId, "meetingId", "meetings transcript");
            args = [...pre, "transcript", a.meetingId];
            break;
          case "notes":
            requireArg(a.meetingId, "meetingId", "meetings notes");
            args = [...pre, "notes", a.meetingId];
            break;
          default:
            throw new Error(`Unknown hq_meetings action: ${a.action}`);
        }
        out = await hq(args);
        break;
      }

      case "hq_sources": {
        let args;
        switch (a.action) {
          case "channels":
            args = ["sources", "channels"];
            break;
          case "entities":
            args = ["sources", "entities"];
            if (a.json) args.push("--format", "json");
            break;
          case "list":
            args = ["sources", "list"];
            if (a.entity) args.push("--entity", a.entity);
            if (a.type) args.push("--type", a.type);
            if (a.limit) args.push("--limit", String(a.limit));
            if (a.json) args.push("--format", "json");
            args.push("--hq-root", HQ_ROOT);
            break;
          case "get":
            requireArg(a.id, "id", "sources get");
            args = ["sources", "get", "--id", a.id];
            if (a.entity) args.push("--entity", a.entity);
            if (a.type) args.push("--type", a.type);
            if (a.json) args.push("--format", "json");
            args.push("--hq-root", HQ_ROOT);
            break;
          default:
            throw new Error(`Unknown hq_sources action: ${a.action}`);
        }
        out = await hq(args);
        break;
      }

      case "hq_signals": {
        let args;
        switch (a.action) {
          case "types":
            args = ["signals", "types"];
            break;
          case "entities":
            args = ["signals", "entities"];
            if (a.json) args.push("--format", "json");
            break;
          case "list":
            args = ["signals", "list"];
            if (a.entity) args.push("--entity", a.entity);
            if (a.type) args.push("--type", a.type);
            if (a.limit) args.push("--limit", String(a.limit));
            if (a.json) args.push("--format", "json");
            args.push("--hq-root", HQ_ROOT);
            break;
          case "get":
            requireArg(a.id, "id", "signals get");
            args = ["signals", "get", "--id", a.id];
            if (a.entity) args.push("--entity", a.entity);
            if (a.type) args.push("--type", a.type);
            if (a.json) args.push("--format", "json");
            args.push("--hq-root", HQ_ROOT);
            break;
          default:
            throw new Error(`Unknown hq_signals action: ${a.action}`);
        }
        out = await hq(args);
        break;
      }

      case "hq_feedback": {
        if (a.action !== "bug" && a.action !== "feature") {
          throw new Error(`Unknown hq_feedback action: ${a.action}`);
        }
        const args = ["feedback", a.action, "--title", a.title, "--body-file", "-"];
        if (a.company) args.push("--company", a.company);
        out = await hq(args, { input: a.body });
        break;
      }

      case "hq_run": {
        const cwd = resolveHostCwd(a.cwd);
        const args = ["run"];
        if (a.company) args.push("--company", a.company);
        if (a.schema) {
          // SECURITY (CRITICAL-2): the --schema path must resolve inside
          // HQ_ROOT, mirroring the cwd containment check. Resolve relative to
          // the already-validated cwd; reject `..` traversal or absolute paths
          // pointing outside HQ_ROOT so a caller can't read an arbitrary
          // .env.schema from elsewhere on the host.
          if (!isInsideHqRoot(a.schema, cwd)) {
            throw new Error(
              `hq_run schema must resolve inside HQ_ROOT (${HQ_ROOT}). Got: ${a.schema}`,
            );
          }
          args.push("--schema", a.schema);
        }
        if (a.check) {
          args.push("--check");
        }
        // Validate cmd whenever it is present — `--check` does NOT suppress the
        // appended `-- ...cmd`, so the secret-safe gate must run regardless of
        // the check flag (otherwise check:true disarms the guard while still
        // launching the command with injected secrets).
        if (a.cmd?.length) {
          requireStringArray(a.cmd, "cmd", "hq_run");
          // SECURITY (CRITICAL-1, defense-in-depth): same shell / value-printing
          // binary refusal as hq_secrets_exec — hq_run also injects secrets.
          assertSecretSafeCommand(a.cmd, "hq_run");
          args.push("--", ...a.cmd);
        }
        out = await hq(args, { cwd, timeout: boundedTimeoutMs(a.timeoutMs) });
        break;
      }

      case "hq_cli": {
        validateHqCliArgs(a.args);
        out = await hq(a.args, {
          cwd: resolveHostCwd(a.cwd),
          input: a.stdin,
          timeout: boundedTimeoutMs(a.timeoutMs),
        });
        break;
      }

      default:
        throw new Error(`Unknown tool: ${name}`);
    }
    return { content: [{ type: "text", text: out || "(no output)" }] };
  } catch (e) {
    return {
      isError: true,
      content: [{ type: "text", text: `hq MCP error: ${e.message}` }],
    };
  }
});

await server.connect(new StdioServerTransport());
