#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const DESCRIPTION_MAX_LENGTH = 140;
const YAML_PARSER_PACKAGE = "js-yaml";
const YAML_PARSER_VERSION = "4.1.0";
const YAML_PARSER_ROOT_ENV = "HQ_AGENT_RUNTIME_PARSER_ROOT";
const REQUIRE = createRequire(import.meta.url);
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const VALIDATOR_SCRIPT = path.join(SCRIPT_DIR, "validate-agent-runtime-contracts.mjs");
const SHELL_FENCE_PATTERN = /^```(?:bash|sh|shell|zsh)\s*$/i;
const SCRIPT_COMMAND_PATTERN = /^(?:(nohup)\s+)?(?:(bash|sh)\s+)?((?:\.\/)?(?:core|\.claude)\/[^\s'"\\]+\.sh)(?=\s|$)/;
const EMBEDDED_SCRIPT_PATH_PATTERN = /(?:\.\/)?(?:core|\.claude)\/[^\s'"\\)]+\.sh/;
let YAML_PARSER = null;

// These commands are examples, diagnostics, or user-approved mutations rather
// than unattended skill automation. Keep entries exact and explain why widening
// the skill's Bash permissions would be less safe than preserving the prompt.
const INTENTIONALLY_APPROVAL_GATED_COMMANDS = new Map([
  [
    ".claude/skills/brainstorm/SKILL.md::.claude/skills/_shared/journal.sh",
    "The runtime-selected project journal remains approval-gated.",
  ],
  [
    ".claude/skills/checkpoint/SKILL.md::.claude/skills/_shared/journal.sh",
    "The runtime-selected project journal remains approval-gated.",
  ],
  [
    ".claude/skills/cleanup/SKILL.md::bash core/scripts/generate-workers-registry.sh",
    "Cleanup regeneration is an operator-selected maintenance action.",
  ],
  [
    ".claude/skills/cleanup/SKILL.md::bash core/scripts/rebuild-all-indexes.sh",
    "Cleanup regeneration is an operator-selected maintenance action.",
  ],
  [
    ".claude/skills/convert-codex/SKILL.md::bash core/scripts/convert-codex.sh",
    "The same entry point can apply runtime configuration changes, so it keeps an approval prompt.",
  ],
  [
    ".claude/skills/idea/SKILL.md::bash core/scripts/work-mesh.sh",
    "Work Mesh writes are best-effort cloud updates and remain approval-gated.",
  ],
  [
    ".claude/skills/import-claude/SKILL.md::bash .claude/skills/import-claude/scan.sh",
    "Import scanning traverses user-selected external Claude data.",
  ],
  [
    ".claude/skills/import-claude/SKILL.md::bash .claude/skills/import-claude/redact.sh",
    "Import redaction handles user-selected external Claude data.",
  ],
  [
    ".claude/skills/journal/SKILL.md::core/scripts/session-journal.sh",
    "Session journal writes target runtime-selected company and project state.",
  ],
  [
    ".claude/skills/plan/SKILL.md::.claude/skills/_shared/journal.sh",
    "The runtime-selected project journal remains approval-gated.",
  ],
  [
    ".claude/skills/plan/SKILL.md::bash core/scripts/work-mesh.sh",
    "Work Mesh writes are best-effort cloud updates and remain approval-gated.",
  ],
  [
    ".claude/skills/project-summary/SKILL.md::bash .claude/skills/project-summary/scripts/deploy-summary.sh",
    "Summary deployment is an external publish action with its own approval boundary.",
  ],
  [
    ".claude/skills/resumework/SKILL.md::bash core/scripts/hq-session.sh",
    "Session context mutation remains visible and approval-gated.",
  ],
  [
    ".claude/skills/run/SKILL.md::bash core/scripts/work-mesh.sh",
    "Work Mesh reads and writes remain approval-gated at the network boundary.",
  ],
  [
    ".claude/skills/startwork/SKILL.md::bash core/scripts/hq-session.sh",
    "Session context mutation remains visible and approval-gated.",
  ],
  [
    "core/packages/hq-pack-cowork/skills/hq-cowork-install/SKILL.md::core/packages/hq-pack-cowork/scripts/install-cowork-plugin.sh",
    "Installing a host plugin is intentionally an approval-gated machine mutation.",
  ],
  [
    ".claude/skills/deploy/SKILL.md::path:.claude/skills/deploy/scripts/resolve-deploy-api.sh",
    "The command is embedded in assignment syntax, which cannot use a path-only literal prefix.",
  ],
  [
    ".claude/skills/deploy/SKILL.md::path:core/scripts/hook-lib.sh",
    "Sourcing a shared library changes the current shell and remains approval-gated.",
  ],
  [
    ".claude/skills/deploy/SKILL.md::path:.claude/skills/deploy/scripts/resolve-deploy-org.sh",
    "The command is embedded in eval and a pipeline, which cannot use a path-only literal prefix.",
  ],
  [
    ".claude/skills/deploy/SKILL.md::path:.claude/skills/deploy/scripts/password-helper.sh",
    "Command-substitution password handling remains approval-gated.",
  ],
  [
    ".claude/skills/deploy/SKILL.md::path:.claude/skills/deploy/scripts/deploy-api-request.sh",
    "The invocation begins with a runtime credential assignment and remains approval-gated.",
  ],
  [
    ".claude/skills/deploy/SKILL.md::path:.claude/skills/deploy/scripts/og-inject.sh",
    "The command is embedded in assignment syntax, which cannot use a path-only literal prefix.",
  ],
  [
    ".claude/skills/hq-sync/SKILL.md::path:core/scripts/qmd-reindex-after-sync.sh",
    "The script path is rooted through a runtime variable and cannot have a fixed literal prefix.",
  ],
  [
    ".claude/skills/registry/SKILL.md::path:core/scripts/generate-index.sh",
    "The command follows a runtime-selected directory change and remains approval-gated.",
  ],
]);

class YamlSyntaxError extends Error {
  constructor(message, details) {
    super(message);
    this.name = "YamlSyntaxError";
    this.filePath = details.filePath;
    this.field = details.field || null;
    this.line = details.line;
    this.column = details.column;
    this.remediation = details.remediation || null;
  }
}

class ValidationError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = "ValidationError";
    this.filePath = details.filePath || null;
    this.field = details.field || null;
    this.gaps = details.gaps || null;
  }
}

function normalizeNewlines(value) {
  return value.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

function displayPath(filePath) {
  return String(filePath).replace(/\\/g, "/");
}

function readFile(filePath) {
  return fs.readFileSync(filePath, "utf8");
}

function fileExists(filePath) {
  try {
    fs.accessSync(filePath);
    return true;
  } catch {
    return false;
  }
}

function isDirectory(filePath) {
  try {
    return fs.statSync(filePath).isDirectory();
  } catch {
    return false;
  }
}

function listChildDirectories(dirPath) {
  if (!isDirectory(dirPath)) {
    return [];
  }

  try {
    return fs
      .readdirSync(dirPath)
      .map((entry) => path.join(dirPath, entry))
      .filter((entryPath) => isDirectory(entryPath))
      .sort();
  } catch {
    return [];
  }
}

function deterministicParserRoots(_rootPath, parserRoot) {
  const roots = [parserRoot || "", parserRoot ? path.join(parserRoot, "node_modules") : ""];

  return [...new Set(roots.filter((candidate) => candidate !== "").map((candidate) => path.resolve(candidate)))]
    .filter((candidate) => fileExists(candidate));
}

function installParserHelp() {
  return [
    `Install it explicitly with: node core/scripts/validate-agent-runtime-contracts.mjs install-parser --install-dir <dir>`,
    `Then rerun with ${YAML_PARSER_ROOT_ENV}=<dir>.`,
  ].join(" ");
}

function resolveNpmCliCandidates() {
  const nodeDir = path.dirname(process.execPath);
  return [
    path.join(nodeDir, "node_modules", "npm", "bin", "npm-cli.js"),
    path.join(nodeDir, "..", "lib", "node_modules", "npm", "bin", "npm-cli.js"),
    path.join(nodeDir, "..", "node_modules", "npm", "bin", "npm-cli.js"),
  ]
    .map((candidate) => path.resolve(candidate))
    .filter((candidate, index, values) => values.indexOf(candidate) === index);
}

function resolveNpmInstallInvocation() {
  for (const npmCliPath of resolveNpmCliCandidates()) {
    if (!fileExists(npmCliPath)) {
      continue;
    }

    return {
      command: process.execPath,
      args: [npmCliPath],
      label: `${process.execPath} ${npmCliPath}`,
    };
  }

  if (process.platform === "win32") {
    throw new ValidationError(
      `unable to locate npm-cli.js next to ${process.execPath}; cannot bootstrap ${YAML_PARSER_PACKAGE}@${YAML_PARSER_VERSION} safely on Windows`,
      {
        filePath: process.execPath,
      },
    );
  }

  return {
    command: "npm",
    args: [],
    label: "npm",
  };
}

function loadYamlParser(rootPath, parserRoot) {
  const attempted = [];
  const candidates = deterministicParserRoots(rootPath, parserRoot);

  for (const candidate of candidates) {
    try {
      const resolved = REQUIRE.resolve(YAML_PARSER_PACKAGE, { paths: [candidate] });
      return REQUIRE(resolved);
    } catch (error) {
      attempted.push(`${candidate}: ${error.code || error.message}`);
    }
  }

  throw new ValidationError(
    `unable to resolve maintained YAML parser "${YAML_PARSER_PACKAGE}@${YAML_PARSER_VERSION}" from deterministic roots (${attempted.join("; ") || "none"}). ${installParserHelp()}`,
  );
}

function installYamlParser(installDir) {
  if (!installDir) {
    throw new Error("install-parser requires --install-dir");
  }

  const resolvedInstallDir = path.resolve(installDir);
  const npmInvocation = resolveNpmInstallInvocation();
  fs.mkdirSync(resolvedInstallDir, { recursive: true });

  try {
    execFileSync(
      npmInvocation.command,
      [
        ...npmInvocation.args,
        "install",
        "--ignore-scripts",
        "--no-audit",
        "--no-fund",
        "--no-package-lock",
        "--no-save",
        "--prefix",
        resolvedInstallDir,
        `${YAML_PARSER_PACKAGE}@${YAML_PARSER_VERSION}`,
      ],
      {
        stdio: "inherit",
      },
    );
  } catch (error) {
    throw new ValidationError(
      `failed to install ${YAML_PARSER_PACKAGE}@${YAML_PARSER_VERSION} into ${resolvedInstallDir} using ${npmInvocation.label}: ${error.message}`,
      {
        filePath: resolvedInstallDir,
      },
    );
  }

  loadYamlParser(resolvedInstallDir, resolvedInstallDir);
  return resolvedInstallDir;
}

function parseYaml(source, filePath, options = {}) {
  const normalized = normalizeNewlines(source);
  const lineOffset = Number.isInteger(options.lineOffset) ? options.lineOffset : 0;

  try {
    return YAML_PARSER.load(normalized, {
      filename: filePath,
      json: false,
    });
  } catch (error) {
    throw toYamlSyntaxError(error, normalized, filePath, lineOffset);
  }
}

function toYamlSyntaxError(error, source, filePath, lineOffset = 0) {
  const markLine = typeof error?.mark?.line === "number" ? error.mark.line : 0;
  const markColumn =
    typeof error?.mark?.column === "number" ? error.mark.column : 0;
  const plainScalarProblem = detectPlainScalarColonSpace(source, markLine);
  let field =
    plainScalarProblem?.field || inferFieldFromLine(source, markLine) || null;
  let message = error?.reason || error?.message || "invalid YAML";
  let remediation = null;
  let column = markColumn + 1;

  if (plainScalarProblem) {
    message = 'plain scalars cannot contain ": " without quotes';
    remediation =
      'quote the value or use a block scalar, for example description: "foo: bar" or description: |-';
    column = plainScalarProblem.column;
    field = plainScalarProblem.field;
  } else if (message === "duplicated mapping key") {
    message = "duplicate YAML key";
  }

  return new YamlSyntaxError(message, {
    filePath,
    field,
    line: markLine + 1 + lineOffset,
    column,
    remediation,
  });
}

function inferFieldFromLine(source, zeroBasedLine) {
  const lines = source.split("\n");

  for (let index = Math.min(zeroBasedLine, lines.length - 1); index >= 0; index -= 1) {
    const trimmed = lines[index].trim();
    if (trimmed === "" || trimmed.startsWith("#")) {
      continue;
    }

    const match = /^\s*([A-Za-z0-9_-]+):/.exec(lines[index]);
    if (match) {
      return match[1];
    }
  }

  return null;
}

function detectPlainScalarColonSpace(source, zeroBasedLine) {
  const lines = source.split("\n");
  const rawLine = lines[zeroBasedLine] || "";
  const match = /^\s*([A-Za-z0-9_-]+):\s*(.+?)\s*$/.exec(rawLine);
  if (!match) {
    return null;
  }

  const value = match[2];
  if (
    value.startsWith('"') ||
    value.startsWith("'") ||
    value.startsWith("|") ||
    value.startsWith(">") ||
    value.startsWith("[") ||
    value.startsWith("{") ||
    value.startsWith("&") ||
    value.startsWith("*") ||
    value.startsWith("!")
  ) {
    return null;
  }

  const colonOffset = value.search(/:\s/);
  if (colonOffset === -1) {
    return null;
  }

  const keyOffset = rawLine.indexOf(`${match[1]}:`);
  const valueOffset = rawLine.indexOf(value, keyOffset + match[1].length + 1);
  return {
    field: match[1],
    column: valueOffset + colonOffset + 1,
  };
}

function extractFrontmatter(skillPath) {
  const source = normalizeNewlines(readFile(skillPath));
  if (!source.startsWith("---\n")) {
    throw new ValidationError("missing YAML frontmatter opening fence", {
      filePath: skillPath,
    });
  }

  const endOffset = source.indexOf("\n---\n", 4);
  if (endOffset === -1) {
    throw new ValidationError("missing YAML frontmatter closing fence", {
      filePath: skillPath,
    });
  }

  return {
    source: source.slice(4, endOffset),
    lineOffset: 1,
  };
}

function normalizeAllowedTools(value, skillPath) {
  if (value === undefined || value === null) {
    return [];
  }

  if (typeof value === "string") {
    const tools = value
      .split(",")
      .map((tool) => tool.trim())
      .filter((tool) => tool !== "");
    if (tools.length === 0) {
      throw new ValidationError("allowed-tools must not be empty", {
        filePath: skillPath,
        field: "allowed-tools",
      });
    }
    return tools;
  }

  if (Array.isArray(value)) {
    const tools = value.map((tool) => {
      if (typeof tool !== "string") {
        throw new ValidationError("allowed-tools list items must be strings", {
          filePath: skillPath,
          field: "allowed-tools",
        });
      }

      const trimmed = tool.trim();
      if (trimmed === "") {
        throw new ValidationError("allowed-tools list items must not be empty", {
          filePath: skillPath,
          field: "allowed-tools",
        });
      }
      return trimmed;
    });

    if (tools.length === 0) {
      throw new ValidationError("allowed-tools must not be empty", {
        filePath: skillPath,
        field: "allowed-tools",
      });
    }

    return tools;
  }

  throw new ValidationError("allowed-tools must be a string or a YAML list", {
    filePath: skillPath,
    field: "allowed-tools",
  });
}

function trimSentence(text) {
  const normalized = text.replace(/\s+/g, " ").trim();
  if (normalized === "") {
    return "";
  }

  const sentenceMatch = normalized.match(/^.*?[.!?](?=\s|$)/);
  let sentence = sentenceMatch ? sentenceMatch[0] : normalized;
  if (sentence.length <= DESCRIPTION_MAX_LENGTH) {
    return sentence;
  }

  const sliced = sentence.slice(0, DESCRIPTION_MAX_LENGTH);
  const lastSpace = sliced.lastIndexOf(" ");
  sentence = lastSpace > 20 ? sliced.slice(0, lastSpace) : sliced;
  return sentence.trimEnd();
}

function toDisplayName(skillName) {
  return skillName.replace(/-/g, " ");
}

function parseSkillMetadata(skillPath) {
  const frontmatter = extractFrontmatter(skillPath);
  const data = parseYaml(frontmatter.source, skillPath, {
    lineOffset: frontmatter.lineOffset,
  });

  if (!data || Array.isArray(data) || typeof data !== "object") {
    throw new ValidationError("frontmatter must be a YAML mapping", {
      filePath: skillPath,
    });
  }

  const name = typeof data.name === "string" ? data.name.trim() : "";
  const description =
    typeof data.description === "string" ? data.description.trim() : "";

  if (name === "") {
    throw new ValidationError("name must be a non-empty string", {
      filePath: skillPath,
      field: "name",
    });
  }

  if (description === "") {
    throw new ValidationError("description must be a non-empty string", {
      filePath: skillPath,
      field: "description",
    });
  }

  return {
    filePath: skillPath,
    name,
    description,
    allowedTools: normalizeAllowedTools(data["allowed-tools"], skillPath),
    displayName: toDisplayName(name),
    shortDescription: trimSentence(description),
  };
}

function joinShellContinuation(lines, startIndex) {
  let command = lines[startIndex].trim();
  let index = startIndex;

  while (command.endsWith("\\") && index + 1 < lines.length) {
    command = `${command.slice(0, -1).trimEnd()} ${lines[index + 1].trim()}`;
    index += 1;
  }

  return { command, endIndex: index };
}

function normalizeScriptCommand(command) {
  let candidate = command.trim().replace(/^\$\s+/, "");
  candidate = candidate.replace(/^\(\s*/, "");

  const match = SCRIPT_COMMAND_PATTERN.exec(candidate);
  if (match) {
    const prefix = [match[1], match[2], match[3]].filter(Boolean).join(" ");
    return {
      command: candidate,
      path: match[3],
      prefix,
      suggestedRule: `Bash(${prefix}:*)`,
      complex: false,
    };
  }

  if (/^(?:echo|printf|cp|chmod|test|\[)\b/.test(candidate)) {
    return null;
  }

  const embeddedMatch = EMBEDDED_SCRIPT_PATH_PATTERN.exec(candidate);
  if (!embeddedMatch) {
    return null;
  }

  const scriptPath = embeddedMatch[0];
  const prefix = candidate.slice(0, embeddedMatch.index + scriptPath.length);
  return {
    command: candidate,
    path: scriptPath,
    prefix,
    suggestedRule: `Bash(${prefix}:*)`,
    complex: true,
  };
}

function collectPermissionCommands(skillPath) {
  const lines = normalizeNewlines(readFile(skillPath)).split("\n");
  const commands = [];
  let inShellFence = false;

  for (let index = 0; index < lines.length; index += 1) {
    const trimmed = lines[index].trim();
    if (!inShellFence && SHELL_FENCE_PATTERN.test(trimmed)) {
      inShellFence = true;
      continue;
    }
    if (inShellFence && trimmed.startsWith("```")) {
      inShellFence = false;
      continue;
    }
    if (!inShellFence || trimmed === "" || trimmed.startsWith("#")) {
      continue;
    }

    const startLine = index + 1;
    const logical = joinShellContinuation(lines, index);
    index = logical.endIndex;
    const normalized = normalizeScriptCommand(logical.command);
    if (normalized) {
      commands.push({ ...normalized, line: startLine });
    }
  }

  return commands;
}

function permissionAllowlistKey(rootPath, skillPath, commandPrefix) {
  return `${path.relative(rootPath, skillPath).replace(/\\/g, "/")}::${commandPrefix}`;
}

function validateSkillPermissions(rootPath, metadata) {
  let commandCount = 0;
  const gaps = [];

  for (const command of collectPermissionCommands(metadata.filePath)) {
    commandCount += 1;
    if (metadata.allowedTools.includes(command.suggestedRule)) {
      continue;
    }

    const allowlistKey = permissionAllowlistKey(
      rootPath,
      metadata.filePath,
      command.prefix,
    );
    const rationale = INTENTIONALLY_APPROVAL_GATED_COMMANDS.get(allowlistKey);
    const pathRationale = command.complex
      ? INTENTIONALLY_APPROVAL_GATED_COMMANDS.get(
          permissionAllowlistKey(
            rootPath,
            metadata.filePath,
            `path:${command.path}`,
          ),
        )
      : null;
    if (
      (typeof rationale === "string" && rationale.trim() !== "") ||
      (typeof pathRationale === "string" && pathRationale.trim() !== "")
    ) {
      continue;
    }

    const unrestrictedBash = metadata.allowedTools.includes("Bash")
      ? " Unrestricted Bash does not satisfy concrete command coverage."
      : "";
    gaps.push({
      filePath: metadata.filePath,
      line: command.line,
      command: command.command,
      suggestedRule: command.suggestedRule,
      unrestrictedBash,
    });
  }

  return { commandCount, gaps };
}

function emitOpenAiYaml(metadata) {
  return [
    "interface:",
    "  display_name: >-",
    `    ${metadata.displayName}`,
    "  short_description: >-",
    `    ${metadata.shortDescription}`,
    "",
  ].join("\n");
}

function validateOpenAiYaml(skillDir, metadata) {
  const generated = emitOpenAiYaml(metadata);
  const generatedPath = path.join(skillDir, "agents", "openai.yaml");
  const parsedGenerated = parseYaml(generated, generatedPath);
  if (
    !parsedGenerated ||
    typeof parsedGenerated !== "object" ||
    Array.isArray(parsedGenerated) ||
    !parsedGenerated.interface ||
    typeof parsedGenerated.interface !== "object"
  ) {
    throw new ValidationError(
      "generated agents/openai.yaml must contain interface mapping",
      { filePath: generatedPath },
    );
  }

  if (!fileExists(generatedPath)) {
    return;
  }

  const existing = parseYaml(readFile(generatedPath), generatedPath);
  if (
    !existing ||
    typeof existing !== "object" ||
    Array.isArray(existing) ||
    !existing.interface ||
    typeof existing.interface !== "object"
  ) {
    throw new ValidationError(
      "agents/openai.yaml must contain interface mapping",
      { filePath: generatedPath },
    );
  }

  for (const field of ["display_name", "short_description"]) {
    if (
      typeof existing.interface[field] !== "string" ||
      existing.interface[field].trim() === ""
    ) {
      throw new ValidationError(
        `agents/openai.yaml interface.${field} must be a non-empty string`,
        {
          filePath: generatedPath,
          field: `interface.${field}`,
        },
      );
    }
  }
}

function parsePackageManifest(packagePath) {
  const manifestPath = path.join(packagePath, "package.yaml");
  const manifest = parseYaml(readFile(manifestPath), manifestPath);
  const contributes =
    manifest && typeof manifest === "object" && !Array.isArray(manifest)
      ? manifest.contributes
      : null;

  if (!contributes || typeof contributes !== "object" || Array.isArray(contributes)) {
    return [];
  }

  const skills = contributes.skills;
  if (skills == null) {
    return [];
  }

  if (!Array.isArray(skills)) {
    throw new ValidationError("contributes.skills must be a YAML list", {
      filePath: manifestPath,
      field: "contributes.skills",
    });
  }

  return skills.map((skillName, index) => {
    if (typeof skillName !== "string" || skillName.trim() === "") {
      throw new ValidationError(
        `contributes.skills[${index}] must be a non-empty string`,
        {
          filePath: manifestPath,
          field: "contributes.skills",
        },
      );
    }
    return skillName.trim();
  });
}

function collectRootSurface(rootPath) {
  const skillsRoot = path.join(rootPath, ".claude", "skills");
  const skillFiles = listChildDirectories(skillsRoot)
    .map((skillDir) => path.join(skillDir, "SKILL.md"))
    .filter((skillPath) => fileExists(skillPath));

  return [
    {
      id: "root",
      label: path.relative(rootPath, skillsRoot) || ".claude/skills",
      skillFiles,
    },
  ];
}

function collectPackageSurfaces(rootPath) {
  const packagesRoot = path.join(rootPath, "core", "packages");
  if (!isDirectory(packagesRoot)) {
    return [];
  }

  const surfaces = [];
  for (const packageDir of listChildDirectories(packagesRoot)) {
    const manifestPath = path.join(packageDir, "package.yaml");
    if (!fileExists(manifestPath)) {
      continue;
    }

    const packageName = path.basename(packageDir);
    const skillNames = parsePackageManifest(packageDir);
    const skillFiles = [];

    for (const skillName of skillNames) {
      const skillPath = path.join(packageDir, "skills", skillName, "SKILL.md");
      if (!fileExists(skillPath)) {
        throw new ValidationError(
          `package declares contributed skill "${skillName}" but ${path.relative(rootPath, skillPath)} is missing`,
          {
            filePath: manifestPath,
            field: "contributes.skills",
          },
        );
      }
      skillFiles.push(skillPath);
    }

    surfaces.push({
      id: `package:${packageName}`,
      label: path.relative(rootPath, packageDir),
      skillFiles,
    });
  }

  return surfaces;
}

function formatError(error) {
  if (error instanceof YamlSyntaxError) {
    const lines = [
      `ERROR ${displayPath(error.filePath)}`,
      `  field: ${error.field || "frontmatter"}`,
      `  parser: line ${error.line}, column ${error.column}: ${error.message}`,
    ];
    if (error.remediation) {
      lines.push(`  remediation: ${error.remediation}`);
    }
    return lines.join("\n");
  }

  if (error instanceof ValidationError) {
    if (Array.isArray(error.gaps)) {
      return error.gaps
        .map(
          (gap) =>
            `ERROR ${displayPath(gap.filePath)}\n  field: allowed-tools\n  permission gap for command at line ${gap.line}: ${gap.command}\n  missing rule: ${gap.suggestedRule}\n  suggested narrow allow entry: ${gap.suggestedRule}.${gap.unrestrictedBash}`,
        )
        .join("\n");
    }
    const lines = [
      `ERROR ${error.filePath ? displayPath(error.filePath) : "(unknown file)"}`,
    ];
    if (error.field) {
      lines.push(`  field: ${error.field}`);
    }
    lines.push(`  validation: ${error.message}`);
    return lines.join("\n");
  }

  if (error instanceof Error) {
    return `ERROR ${error.message}`;
  }

  return `ERROR ${String(error)}`;
}

function validateSurface(rootPath, surface, seenSummaries) {
  const names = new Map();
  let validatedCount = 0;

  for (const skillPath of surface.skillFiles) {
    const metadata = parseSkillMetadata(skillPath);
    const duplicatePath = names.get(metadata.name);
    if (duplicatePath) {
      throw new ValidationError(
        `duplicate skill name "${metadata.name}" within shipped surface ${surface.label}; already declared in ${path.relative(rootPath, duplicatePath)}`,
        {
          filePath: skillPath,
          field: "name",
        },
      );
    }

    names.set(metadata.name, skillPath);
    validateOpenAiYaml(path.dirname(skillPath), metadata);
    validatedCount += 1;
  }

  seenSummaries.push(`${surface.label}: ${validatedCount} skill(s)`);
  return validatedCount;
}

function validatePermissionSurface(rootPath, surface, seenSummaries) {
  let skillCount = 0;
  let commandCount = 0;
  const gaps = [];

  for (const skillPath of surface.skillFiles) {
    const metadata = parseSkillMetadata(skillPath);
    const result = validateSkillPermissions(rootPath, metadata);
    commandCount += result.commandCount;
    gaps.push(...result.gaps);
    skillCount += 1;
  }

  seenSummaries.push(
    `${surface.label}: ${commandCount} concrete command(s) across ${skillCount} skill(s)`,
  );
  return { skillCount, commandCount, gaps };
}

function validateRuntimeContracts(rootPath) {
  const surfaces = [...collectRootSurface(rootPath), ...collectPackageSurfaces(rootPath)];
  const summaries = [];
  let total = 0;

  for (const surface of surfaces) {
    total += validateSurface(rootPath, surface, summaries);
  }

  return { total, summaries };
}

function validatePermissionContracts(rootPath) {
  const surfaces = [...collectRootSurface(rootPath), ...collectPackageSurfaces(rootPath)];
  const summaries = [];
  let skillCount = 0;
  let commandCount = 0;
  const gaps = [];

  for (const surface of surfaces) {
    const result = validatePermissionSurface(rootPath, surface, summaries);
    skillCount += result.skillCount;
    commandCount += result.commandCount;
    gaps.push(...result.gaps);
  }

  if (gaps.length > 0) {
    throw new ValidationError(
      `${gaps.length} concrete shipped command permission gap(s)`,
      { gaps },
    );
  }

  return { skillCount, commandCount, summaries };
}

function parseCli(argv) {
  const args = [...argv];
  let command = "validate";
  if (args[0] && !args[0].startsWith("--")) {
    command = args.shift();
  }

  let rootPath = process.cwd();
  let skillPath = null;
  let parserRoot = process.env[YAML_PARSER_ROOT_ENV]
    ? path.resolve(process.env[YAML_PARSER_ROOT_ENV])
    : null;
  let installDir = null;

  while (args.length > 0) {
    const arg = args.shift();
    if (arg === "--root") {
      if (args.length === 0) {
        throw new Error("--root requires a path");
      }
      rootPath = path.resolve(args.shift());
      continue;
    }

    if (arg.startsWith("--root=")) {
      rootPath = path.resolve(arg.slice("--root=".length));
      continue;
    }

    if (arg === "--parser-root") {
      if (args.length === 0) {
        throw new Error("--parser-root requires a path");
      }
      parserRoot = path.resolve(args.shift());
      continue;
    }

    if (arg.startsWith("--parser-root=")) {
      parserRoot = path.resolve(arg.slice("--parser-root=".length));
      continue;
    }

    if (arg === "--install-dir") {
      if (args.length === 0) {
        throw new Error("--install-dir requires a path");
      }
      installDir = path.resolve(args.shift());
      continue;
    }

    if (arg.startsWith("--install-dir=")) {
      installDir = path.resolve(arg.slice("--install-dir=".length));
      continue;
    }

    if (command === "emit-openai-yaml" && skillPath === null) {
      skillPath = path.resolve(arg);
      continue;
    }

    throw new Error(`unknown argument: ${arg}`);
  }

  return { command, rootPath, skillPath, parserRoot, installDir };
}

function main() {
  const { command, rootPath, skillPath, parserRoot, installDir } = parseCli(
    process.argv.slice(2),
  );

  if (command === "install-parser") {
    const resolvedInstallDir = installYamlParser(installDir);
    process.stdout.write(
      `Installed ${YAML_PARSER_PACKAGE}@${YAML_PARSER_VERSION} into ${resolvedInstallDir}\nSet ${YAML_PARSER_ROOT_ENV}=${resolvedInstallDir} when running ${path.relative(process.cwd(), VALIDATOR_SCRIPT) || VALIDATOR_SCRIPT} or core/scripts/convert-codex.sh.\n`,
    );
    return;
  }

  if (YAML_PARSER === null) {
    YAML_PARSER = loadYamlParser(rootPath, parserRoot);
  }

  if (command === "emit-openai-yaml") {
    if (!skillPath) {
      throw new Error("emit-openai-yaml requires a SKILL.md path");
    }

    const metadata = parseSkillMetadata(skillPath);
    process.stdout.write(emitOpenAiYaml(metadata));
    return;
  }

  if (command === "validate-permissions") {
    const result = validatePermissionContracts(rootPath);
    process.stdout.write(
      `Validated ${result.commandCount} concrete shipped command permission contract(s) across ${result.skillCount} skill(s).\n${result.summaries
        .map((summary) => `  ${summary}`)
        .join("\n")}\n`,
    );
    return;
  }

  if (command !== "validate") {
    throw new Error(`unknown command: ${command}`);
  }

  const result = validateRuntimeContracts(rootPath);
  process.stdout.write(
    `Validated ${result.total} shipped skill metadata contract(s).\n${result.summaries
      .map((summary) => `  ${summary}`)
      .join("\n")}\n`,
  );
}

try {
  main();
} catch (error) {
  process.stderr.write(`${formatError(error)}\n`);
  process.exitCode = 1;
}
