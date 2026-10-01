#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { pathToFileURL } = require("node:url");

const FLAG_KEY = "guards.merged-write-guard-shadow";
const DEFAULT_VALUE = false;
const REQUEST_TIMEOUT_MS = 150;
const CACHE_TTL_MS = 5000;
const RULE_ID = "merged-write-guard-shadow-v1";
const CACHE_NAME = "flag.cache";

function safeErrorClass(error) {
  const name = error instanceof Error ? error.name : "UnknownError";
  return /^[A-Za-z][A-Za-z0-9]{0,63}$/.test(name) ? name : "UnknownError";
}

function reportFailure(error) {
  process.stderr.write(
    `HQ merged write guard shadow flag lookup failed (${safeErrorClass(error)}); using default-off behavior.\n`,
  );
}

function findCliPackageRoot(cliBin) {
  if (!cliBin) {
    const candidates = (process.env.PATH || "").split(path.delimiter).map((dir) => path.join(dir, process.platform === "win32" ? "hq.cmd" : "hq"));
    cliBin = candidates.find((candidate) => {
      try { return fs.statSync(candidate).isFile(); } catch { return false; }
    });
  }
  if (!cliBin) throw new Error("hq CLI binary was not found on PATH");
  let current = fs.realpathSync(cliBin);
  if (!fs.statSync(current).isDirectory()) current = path.dirname(current);
  for (let depth = 0; depth < 16; depth += 1) {
    const manifest = path.join(current, "package.json");
    if (fs.existsSync(manifest)) {
      const packageJson = JSON.parse(fs.readFileSync(manifest, "utf8"));
      if (packageJson.name === "@indigoai-us/hq-cli") return current;
    }
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  throw new Error("installed hq CLI package could not be resolved");
}

function packageImportPath(cliRoot, packageName) {
  let current = cliRoot;
  const packageParts = packageName.split("/");
  for (let depth = 0; depth < 16; depth += 1) {
    const packageDir = path.join(current, "node_modules", ...packageParts);
    const manifest = path.join(packageDir, "package.json");
    if (fs.existsSync(manifest)) {
      const packageJson = JSON.parse(fs.readFileSync(manifest, "utf8"));
      const rootExport = typeof packageJson.exports === "string"
        ? packageJson.exports
        : packageJson.exports?.["."];
      const entry = typeof rootExport === "string"
        ? rootExport
        : rootExport?.import ?? rootExport?.default ?? packageJson.module ?? packageJson.main;
      if (typeof entry !== "string") throw new Error(`${packageName} has no import entry`);
      return path.resolve(packageDir, entry);
    }
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  throw new Error(`${packageName} could not be resolved from the installed hq CLI`);
}

function combineSignals(first, second) {
  return first ? AbortSignal.any([first, second]) : second;
}

function cachePath(projectDir) {
  return path.join(projectDir, "workspace", "orchestrator", "hook-state", "merged-write-guard-shadow", CACHE_NAME);
}

function readCachedFlag(projectDir, companyUid) {
  const file = cachePath(projectDir);
  try {
    const [cachedUid, cachedValue, expiresAt] = fs.readFileSync(file, "utf8").trim().split(" ");
    if (cachedUid === companyUid && (cachedValue === "true" || cachedValue === "false") &&
        Number.isFinite(Number(expiresAt)) && Number(expiresAt) * 1000 > Date.now()) {
      return cachedValue === "true";
    }
  } catch (error) {
    if (error?.code !== "ENOENT") reportFailure(error);
  }
  return undefined;
}

function writeCachedFlag(projectDir, companyUid, value) {
  const file = cachePath(projectDir);
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    const expiresAt = Math.ceil((Date.now() + CACHE_TTL_MS) / 1000);
    const serialized = `${companyUid} ${value ? "true" : "false"} ${expiresAt}\n`;
    const temporary = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, serialized, { mode: 0o600 });
    fs.renameSync(temporary, file);
  } catch (error) {
    reportFailure(error);
  }
}

async function lookupFlag(env, options = {}) {
  const endpoint = env.HQ_FLAGS_API_URL?.trim() || "";
  const companyUid = env.HQ_COMPANY_UID?.trim() || "";
  if (!endpoint || !/^cmp_[A-Za-z0-9]{3,128}$/.test(companyUid)) return DEFAULT_VALUE;

  const projectDir = env.CLAUDE_PROJECT_DIR || process.cwd();
  const cached = options.skipCache ? undefined : readCachedFlag(projectDir, companyUid);
  if (cached !== undefined) return cached;

  let cliRoot;
  let client;
  let failed = false;
  let failureReported = false;
  const reportFailureOnce = (error) => {
    failed = true;
    if (failureReported) return;
    failureReported = true;
    reportFailure(error);
  };
  const deadline = AbortSignal.timeout(REQUEST_TIMEOUT_MS);
  try {
    cliRoot = findCliPackageRoot(env.HQ_CLI_BIN);
    const flagsPath = packageImportPath(cliRoot, "@indigoai-us/hq-flags-client");
    const cloudPath = packageImportPath(cliRoot, "@indigoai-us/hq-cloud");
    const [{ createFlagClient }, { loadCachedTokens }] = await Promise.all([
      import(pathToFileURL(flagsPath).href),
      import(pathToFileURL(cloudPath).href),
    ]);
    const clientEnv = env.HQ_COMPANY_SLUG?.trim() || "";
    client = createFlagClient({
      endpoint,
      companyUid,
      ...(clientEnv && /^[A-Za-z0-9][A-Za-z0-9-]{0,63}$/.test(clientEnv)
        ? { companyIdentifiers: [clientEnv] }
        : {}),
      env: {},
      getToken: () => loadCachedTokens()?.idToken ?? "",
      fetch: (input, init) => globalThis.fetch(input, {
        ...init,
        signal: combineSignals(init?.signal ?? undefined, deadline),
      }),
      refreshIntervalMs: 0,
      requestTimeoutMs: REQUEST_TIMEOUT_MS,
      onError: reportFailureOnce,
    });
    let timeoutId;
    const timeout = new Promise((resolve, reject) => {
      timeoutId = setTimeout(() => reject(new DOMException("flag lookup timed out", "TimeoutError")), REQUEST_TIMEOUT_MS);
    });
    try {
      await Promise.race([client.ready(), timeout]);
    } finally {
      clearTimeout(timeoutId);
    }
    const snapshot = client.snapshot();
    const flags = snapshot?.flags && typeof snapshot.flags === "object" ? snapshot.flags : {};
    const enabled = !failed && Object.prototype.hasOwnProperty.call(flags, FLAG_KEY) && flags[FLAG_KEY] === true;
    writeCachedFlag(projectDir, companyUid, enabled);
    return enabled;
  } catch (error) {
    reportFailureOnce(error);
    writeCachedFlag(projectDir, companyUid, DEFAULT_VALUE);
    return DEFAULT_VALUE;
  } finally {
    try {
      client?.close();
    } catch (error) {
      reportFailureOnce(error);
      writeCachedFlag(projectDir, companyUid, DEFAULT_VALUE);
    }
  }
}

function normalizeToolInput(tool, toolInput) {
  const paths = [];
  if (typeof toolInput?.file_path === "string") paths.push(toolInput.file_path);
  if (Array.isArray(toolInput?.edits)) {
    for (const edit of toolInput.edits) {
      if (typeof edit?.file_path === "string") paths.push(edit.file_path);
    }
  }
  if (Array.isArray(toolInput?.files)) {
    for (const file of toolInput.files) {
      if (typeof file === "string") paths.push(file);
      else if (typeof file?.file_path === "string") paths.push(file.file_path);
    }
  }
  if (tool === "apply_patch") {
    const patch = typeof toolInput?.patch === "string" ? toolInput.patch :
      typeof toolInput?.input === "string" ? toolInput.input : "";
    const lines = patch.split(/\r?\n/);
    let current = "";
    for (const line of lines) {
      const fileLine = line.match(/^\*\*\* (?:Add|Update|Delete) File: (.+)$/);
      if (fileLine) {
        current = fileLine[1];
        paths.push(current);
      } else {
        const moveLine = line.match(/^\*\*\* Move to: (.+)$/);
        if (moveLine && current) paths.push(moveLine[1]);
      }
    }
  }
  return [...new Set(paths)];
}

function invokeGuard(script, payload, projectDir) {
  const result = spawnSync("bash", [script], {
    cwd: projectDir,
    env: { ...process.env, CLAUDE_PROJECT_DIR: projectDir, BASH_ENV: "/dev/null" },
    input: `${JSON.stringify(payload)}\n`,
    encoding: "utf8",
    timeout: 20000,
    maxBuffer: 1024 * 1024,
    stdio: ["pipe", "ignore", "ignore"],
  });
  if (result.error) return { decision: "allow", error: safeErrorClass(result.error) };
  if (result.status === 2) return { decision: "deny" };
  if (result.status !== 0) return { decision: "allow", error: `Exit${result.status ?? "Unknown"}` };
  return { decision: "allow" };
}

function isHookDisabled(...ids) {
  const disabled = new Set((process.env.HQ_DISABLED_HOOKS || "").split(",").map((entry) => entry.trim()));
  return ids.some((id) => disabled.has(id));
}

function splitSimpleCommands(command) {
  return command.split(/(?:&&|\|\||[;|\n])/).map((part) => part.trim()).filter(Boolean);
}

function hasRepoPath(value) {
  return /(?:^|\/)repos\/(?:private|public)\//.test(String(value).replace(/^['"]|['"]$/g, ""));
}

function writeCommandTargetsRepo(part) {
  const tokens = (part.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) || [])
    .map((token) => token.replace(/^['"]|['"]$/g, ""));
  const commandIndex = tokens.findIndex((token) => /^(?:tee|cp|mv|rsync|dd|install|touch|truncate|sed)$/.test(token));
  if (commandIndex < 0) return false;
  const command = tokens[commandIndex];
  const args = tokens.slice(commandIndex + 1);
  if (command === "dd") return args.some((arg) => arg.startsWith("of=") && hasRepoPath(arg.slice(3)));
  if (command === "cp" || command === "mv" || command === "rsync" || command === "install") {
    const targetFlag = args.indexOf("-t");
    if (targetFlag >= 0) return hasRepoPath(args[targetFlag + 1] || "");
    const positional = args.filter((arg) => !arg.startsWith("-") && !/^--/.test(arg));
    return positional.length > 0 && hasRepoPath(positional[positional.length - 1]);
  }
  if (command === "tee" || command === "touch" || command === "truncate") {
    return args.filter((arg) => !arg.startsWith("-")).some(hasRepoPath);
  }
  if (command === "sed" && /(?:^|\s)-[A-Za-z]*i(?:\s|$)/.test(part)) {
    const positional = args.filter((arg) => !arg.startsWith("-"));
    return positional.length > 1 && hasRepoPath(positional[positional.length - 1]);
  }
  return false;
}

function gitWriteWithRepoTarget(part) {
  const tokens = part.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) || [];
  const git = tokens.findIndex((token) => token === "git");
  if (git < 0) return false;
  let i = git + 1;
  let rootedInRepo = false;
  while (i < tokens.length && tokens[i].startsWith("-")) {
    const option = tokens[i++];
    if (option === "-C" || option === "--git-dir" || option === "--work-tree") {
      const value = (tokens[i++] || "").replace(/^['"]|['"]$/g, "");
      if (/(?:^|\/)repos\/(?:private|public)\//.test(value)) rootedInRepo = true;
    }
  }
  const verb = (tokens[i] || "").toLowerCase();
  return rootedInRepo && /^(?:add|commit|checkout|reset|rm|clean|merge|rebase|switch|restore|branch)$/.test(verb);
}

function proposalIds(tool, toolInput, paths) {
  const command = tool === "Bash" && typeof toolInput?.command === "string" ? toolInput.command : "";
  const searchable = tool === "apply_patch" ? String(toolInput?.patch ?? "") : paths.join(" ");
  const ids = [];
  if (tool === "Bash") {
    for (const part of splitSimpleCommands(command)) {
      const writesRepoRedirection = [...part.matchAll(/(?:>>|>|\d+>)[ \t]*([^\s;&|]+)/g)]
        .some((match) => /(?:^|\/)repos\//.test(match[1].replace(/^['"]|['"]$/g, "")));
      const sanctioned = /(?:^|\s)(?:git\s+fetch\b|git\s+worktree\s+add\b|hq\s+repos\s+sync\b)/i.test(part) || /workspace\/worktrees\//.test(part);
      if (!sanctioned && (writesRepoRedirection || writeCommandTargetsRepo(part) || gitWriteWithRepoTarget(part))) {
        ids.push("bash-repo-write");
        break;
      }
    }
    const interpreterWrite = /\b(?:python[0-9]*|node)\b/i.test(command) &&
      /(?:open\s*\(|\.write\s*\(|writeFile(?:Sync)?\s*\(|createWriteStream\s*\(|unlink(?:Sync)?\s*\(|mkdir(?:Sync)?\s*\()/i.test(command) &&
      /(?:core\/|\.claude\/|\.agents\/|\.codex\/|\.obsidian\/|\/repos\/)/i.test(command);
    if (interpreterWrite && !ids.includes("bash-repo-write")) ids.push("interpreter-write-resolution");
  }
  return ids;
}

function evaluate(input, hookRoot, projectDir) {
  const tool = typeof input?.tool_name === "string" ? input.tool_name : "unknown";
  const toolInput = input?.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const paths = normalizeToolInput(tool, toolInput);
  const old = {
    core_bash: "allow",
    core_native: "allow",
    repo_worktree: "allow",
  };
  const guardErrors = [];
  if (tool === "Bash") {
    const result = isHookDisabled("block-core-writes-bash")
      ? { decision: "allow", disabled: true }
      : invokeGuard(path.join(hookRoot, ".claude/hooks/block-core-writes-bash.sh"), input, projectDir);
    old.core_bash = result.decision;
    if (result.error) guardErrors.push({ guard: "core_bash", error_class: result.error });
  } else if (["Edit", "Write", "MultiEdit", "apply_patch"].includes(tool)) {
    for (const filePath of paths) {
      const nativePayload = { ...input, tool_name: "Write", tool_input: { file_path: filePath } };
      const native = isHookDisabled("block-core-writes")
        ? { decision: "allow", disabled: true }
        : invokeGuard(path.join(hookRoot, ".claude/hooks/block-core-writes.sh"), nativePayload, projectDir);
      const repo = isHookDisabled("block-repo-edits-use-worktree", "10-Edit,Write,MultiEdit--block-repo-edits-use-worktree")
        ? { decision: "allow", disabled: true }
        : invokeGuard(path.join(hookRoot, "core/hooks/PreToolUse/10-Edit,Write,MultiEdit--block-repo-edits-use-worktree.sh"), nativePayload, projectDir);
      if (native.decision === "deny") old.core_native = "deny";
      if (repo.decision === "deny") old.repo_worktree = "deny";
      if (native.error) guardErrors.push({ guard: "core_native", error_class: native.error });
      if (repo.error) guardErrors.push({ guard: "repo_worktree", error_class: repo.error });
    }
  }
  const legacyDecision = Object.values(old).some((decision) => decision === "deny") ? "deny" : "allow";
  const proposed = proposalIds(tool, toolInput, paths);
  const merged = legacyDecision === "deny" || proposed.length > 0 ? "deny" : "allow";
  return {
    schema_version: "hq-merged-write-guard-shadow.v1",
    timestamp: new Date().toISOString(),
    tool,
    merged_decision: merged,
    legacy_decision: legacyDecision,
    old_guards: old,
    rule_id: RULE_ID,
    proposed_rule_ids: proposed,
    ...(guardErrors.length ? { guard_errors: guardErrors } : {}),
  };
}

function enabledMarkerPath(projectDir, sessionId) {
  if (typeof sessionId !== "string" || !/^[A-Za-z0-9._-]{1,128}$/.test(sessionId) || sessionId === "." || sessionId === "..") return "";
  return path.join(projectDir, "workspace", "orchestrator", "hook-state", "merged-write-guard-shadow", `${sessionId}.enabled`);
}

function sessionEnabled(projectDir, sessionId) {
  const marker = enabledMarkerPath(projectDir, sessionId);
  return Boolean(marker && fs.existsSync(marker));
}

function setEnabledMarker(projectDir, sessionId, enabled) {
  const marker = enabledMarkerPath(projectDir, sessionId);
  if (!marker) return;
  try {
    if (enabled) {
      fs.mkdirSync(path.dirname(marker), { recursive: true, mode: 0o700 });
      fs.writeFileSync(marker, "enabled\n", { mode: 0o600 });
    } else {
      fs.unlinkSync(marker);
    }
  } catch (error) {
    if (!enabled && error?.code === "ENOENT") return;
    reportFailure(error);
  }
}

async function refreshSessionFlag(env, sessionId) {
  const projectDir = path.resolve(env.CLAUDE_PROJECT_DIR || process.cwd());
  if (!sessionId) return;
  const enabled = await lookupFlag(env, { skipCache: true });
  setEnabledMarker(projectDir, sessionId, enabled);
}

function appendRecord(projectDir, record) {
  const file = path.join(projectDir, "workspace", "orchestrator", "hook-state", "merged-write-guard-shadow.jsonl");
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    fs.appendFileSync(file, `${JSON.stringify(record)}\n`, { mode: 0o600 });
  } catch (error) {
    process.stderr.write(`HQ merged write guard shadow log write failed (${safeErrorClass(error)}).\n`);
  }
}

async function main() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  let input;
  try {
    input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch (error) {
    process.stderr.write(`HQ merged write guard shadow input invalid (${safeErrorClass(error)}).\n`);
    return;
  }
  const env = process.env;
  const projectDir = path.resolve(env.CLAUDE_PROJECT_DIR || process.cwd());
  if (process.argv[2] === "--refresh") {
    await refreshSessionFlag(env, input.session_id);
    return;
  }
  if (!sessionEnabled(projectDir, input.session_id)) return;
  const hookRoot = path.resolve(__dirname, "../..");
  const record = evaluate(input, hookRoot, projectDir);
  appendRecord(projectDir, record);
}

module.exports = {
  FLAG_KEY,
  DEFAULT_VALUE,
  REQUEST_TIMEOUT_MS,
  CACHE_TTL_MS,
  safeErrorClass,
  findCliPackageRoot,
  packageImportPath,
  readCachedFlag,
  writeCachedFlag,
  lookupFlag,
  enabledMarkerPath,
  setEnabledMarker,
  sessionEnabled,
  refreshSessionFlag,
  normalizeToolInput,
  invokeGuard,
  proposalIds,
  evaluate,
  appendRecord,
};

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`HQ merged write guard shadow failed (${safeErrorClass(error)}); tool behavior unchanged.\n`);
    process.exitCode = 0;
  });
}
