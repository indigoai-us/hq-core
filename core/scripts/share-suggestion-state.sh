#!/usr/bin/env bash

set -uo pipefail

log_error() {
  printf 'share-suggestion-state: %s\n' "$*" >&2
}

is_hq_root() {
  [ -n "${1:-}" ] && [ -d "$1/core" ] && [ -d "$1/.claude" ]
}

walk_up_to_hq_root() {
  local dir="${1:-}"
  while [ -n "$dir" ]; do
    if is_hq_root "$dir"; then
      printf '%s\n' "$dir"
      return 0
    fi
    [ "$dir" = "/" ] && break
    dir="$(dirname "$dir")"
  done
  return 1
}

resolve_hq_root() {
  local script_dir root
  if is_hq_root "${CLAUDE_PROJECT_DIR:-}"; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR"
    return 0
  fi
  if root="$(walk_up_to_hq_root "$PWD")"; then
    printf '%s\n' "$root"
    return 0
  fi
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  if root="$(walk_up_to_hq_root "$script_dir")"; then
    printf '%s\n' "$root"
    return 0
  fi
  return 1
}

sanitize_session_id() {
  local raw="${1:-}" cleaned
  cleaned="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9_-' '_')"
  if [ -z "$cleaned" ]; then
    cleaned="unknown"
  fi
  printf '%s\n' "$cleaned"
}

main() {
  local cmd="${1:-}"
  local raw_session_id="${2:-}"
  local decision="${3:-}"
  local session_id payload hq_root state_home pending_path history_path suppressions_path

  [ -n "$cmd" ] || {
    log_error "missing subcommand"
    return 1
  }

  hq_root="$(resolve_hq_root)" || {
    log_error "unable to resolve HQ root"
    return 1
  }

  state_home="$hq_root/workspace/orchestrator/share-suggestions"
  history_path="$state_home/history.jsonl"
  suppressions_path="$state_home/suppressions.jsonl"
  mkdir -p "$state_home" || {
    log_error "unable to create state directory"
    return 1
  }

  session_id="$(sanitize_session_id "$raw_session_id")"
  pending_path="$state_home/$session_id.json"

  if [ ! -t 0 ]; then
    payload="$(cat 2>/dev/null || true)"
  else
    payload=""
  fi

  SHARE_SUGGESTION_CMD="$cmd" \
  SHARE_SUGGESTION_HQ_ROOT="$hq_root" \
  SHARE_SUGGESTION_STATE_HOME="$state_home" \
  SHARE_SUGGESTION_PENDING_PATH="$pending_path" \
  SHARE_SUGGESTION_HISTORY_PATH="$history_path" \
  SHARE_SUGGESTION_SUPPRESSIONS_PATH="$suppressions_path" \
  SHARE_SUGGESTION_SESSION_ID="$session_id" \
  SHARE_SUGGESTION_DECISION="$decision" \
  SHARE_SUGGESTION_PAYLOAD="$payload" \
  node - <<'JS'
const fs = require("fs");
const path = require("path");

const pad = (x) => String(x).padStart(2, "0");
function nowIso() {
  const d = new Date();
  return d.getUTCFullYear() + "-" + pad(d.getUTCMonth() + 1) + "-" + pad(d.getUTCDate()) +
    "T" + pad(d.getUTCHours()) + ":" + pad(d.getUTCMinutes()) + ":" + pad(d.getUTCSeconds()) + "Z";
}

const sortKeys = (v) =>
  Array.isArray(v) ? v.map(sortKeys)
  : (v && typeof v === "object")
    ? Object.keys(v).sort().reduce((o, k) => { o[k] = sortKeys(v[k]); return o; }, {})
    : v;

function readJson(p, dflt) {
  if (!fs.existsSync(p)) return dflt;
  try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { return dflt; }
}

function writeJson(p, payload) {
  const tmp = p + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(sortKeys(payload), null, 2) + "\n");
  fs.renameSync(tmp, p);
}

function appendJsonl(p, payload) {
  fs.appendFileSync(p, JSON.stringify(sortKeys(payload)) + "\n");
}

function loadPayload() {
  const raw = process.env.SHARE_SUGGESTION_PAYLOAD || "";
  if (!raw) return {};
  try { return JSON.parse(raw); } catch (e) { return {}; }
}

const isObj = (v) => v && typeof v === "object" && !Array.isArray(v);
const sanitizeValue = (v) => (typeof v === "string" ? v.trim() : v);

function sanitizePerson(person) {
  if (!isObj(person)) return null;
  const personId = sanitizeValue(person.id || person.slug || "");
  const name = sanitizeValue(person.name || "");
  const role = sanitizeValue(person.role || "");
  const cleaned = {};
  if (personId) cleaned.id = personId;
  if (name) cleaned.name = name;
  if (role) cleaned.role = role;
  return Object.keys(cleaned).length ? cleaned : null;
}

function uniquePeople(items) {
  const seen = new Set();
  const result = [];
  for (const item of items || []) {
    const cleaned = sanitizePerson(item);
    if (!cleaned) continue;
    const key = (cleaned.id || "") + "|" + (cleaned.name || "");
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(cleaned);
  }
  return result;
}

function sanitizeSources(items) {
  const allowed = [];
  const seen = new Set();
  for (const item of items || []) {
    if (typeof item !== "string") continue;
    const value = item.trim();
    if (!value || seen.has(value)) continue;
    seen.add(value);
    allowed.push(value);
  }
  return allowed;
}

function sanitizeArtifact(payload) {
  if (!isObj(payload)) payload = {};
  let artifact = payload.artifact;
  if (!isObj(artifact)) artifact = payload;
  const cleaned = {};
  for (const key of ["path", "fingerprint", "class", "surface", "permission", "app_id", "label"]) {
    const value = sanitizeValue(artifact[key]);
    if (typeof value === "string" && value) cleaned[key] = value;
  }
  if (!("permission" in cleaned)) cleaned.permission = "read";
  return cleaned;
}

function sanitizeCandidateHints(payload) {
  let hints = payload.candidate_hints;
  if (!isObj(hints)) hints = {};
  const cleaned = {
    sources: sanitizeSources(hints.sources || payload.candidate_sources || []),
    local_people: uniquePeople(hints.local_people || payload.local_people || []),
    needs_assistant_resolution: Boolean(
      "needs_assistant_resolution" in hints
        ? hints.needs_assistant_resolution
        : payload.needs_assistant_resolution
    ),
  };
  const projectHints = hints.project_recipient_hints || payload.project_recipient_hints || [];
  const projectCleaned = sanitizeSources(projectHints);
  if (projectCleaned.length) cleaned.project_recipient_hints = projectCleaned;
  return cleaned;
}

function sanitizeSuggestion(payload, sessionId) {
  const artifact = sanitizeArtifact(payload);
  const fingerprint = artifact.fingerprint || "";
  const company = sanitizeValue(payload.company || "");
  const project = sanitizeValue(payload.project || "");
  const suggestion = {
    session_id: sessionId,
    company: company,
    project: project,
    artifact: artifact,
    trigger: sanitizeValue(payload.trigger || ""),
    action_kind: sanitizeValue(payload.action_kind || "share-suggestion"),
    suggested_permission: sanitizeValue(payload.suggested_permission || artifact.permission || "read"),
    recommended_surface: sanitizeValue(payload.recommended_surface || artifact.surface || ""),
    recipients: uniquePeople(payload.recipients || []),
    candidate_hints: sanitizeCandidateHints(payload),
    created_at: payload.created_at || nowIso(),
    updated_at: nowIso(),
    shown_at: payload.shown_at === undefined ? null : payload.shown_at,
  };
  if (!company || !fingerprint) return null;
  return suggestion;
}

function sanitizeHistoryEntry(payload, sessionId) {
  const artifact = sanitizeArtifact(payload);
  const entry = {
    session_id: sessionId,
    company: sanitizeValue(payload.company || ""),
    project: sanitizeValue(payload.project || ""),
    trigger: sanitizeValue(payload.trigger || ""),
    action_kind: sanitizeValue(payload.action_kind || "share-suggestion"),
    decision: sanitizeValue(payload.decision || ""),
    event: sanitizeValue(payload.event || ""),
    artifact: artifact,
    recipients: uniquePeople(payload.recipients || []),
    recorded_at: nowIso(),
  };
  if (!entry.artifact.fingerprint) return null;
  return entry;
}

function sanitizeSuppression(payload) {
  const artifact = sanitizeArtifact(payload);
  const scope = sanitizeValue(payload.scope || "");
  const record = {
    kind: scope ? "scope" : "artifact",
    scope: scope,
    company: sanitizeValue(payload.company || ""),
    project: sanitizeValue(payload.project || ""),
    artifact_class: sanitizeValue(payload.artifact_class || artifact.class || ""),
    artifact: {},
    reason: sanitizeValue(payload.reason || "suppressed"),
    created_at: nowIso(),
  };
  if (artifact.fingerprint) record.artifact.fingerprint = artifact.fingerprint;
  if (artifact.path) record.artifact.path = artifact.path;
  if (scope) {
    if (!["global", "company", "project"].includes(scope)) return null;
    return record;
  }
  if (!record.artifact.fingerprint) return null;
  return record;
}

// --- tiny YAML subset parser (ported 1:1 from the python original) ---
function stripComments(line) {
  let inSingle = false, inDouble = false;
  const chars = [];
  for (const ch of line) {
    if (ch === "'" && !inDouble) inSingle = !inSingle;
    else if (ch === '"' && !inSingle) inDouble = !inDouble;
    else if (ch === "#" && !inSingle && !inDouble) break;
    chars.push(ch);
  }
  return chars.join("").replace(/\s+$/, "");
}

function parseScalar(value) {
  value = value.trim();
  if (value === "") return "";
  const lowered = value.toLowerCase();
  if (lowered === "true") return true;
  if (lowered === "false") return false;
  if (lowered === "null" || lowered === "~") return null;
  if (value === "{}") return {};
  if (value === "[]") return [];
  if (value.startsWith("[") && value.endsWith("]")) {
    const inner = value.slice(1, -1).trim();
    if (!inner) return [];
    return inner.split(",").map((part) => parseScalar(part.trim()));
  }
  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
    return value.slice(1, -1);
  }
  if (/^-?\d+$/.test(value)) {
    const n = parseInt(value, 10);
    return Number.isNaN(n) ? value : n;
  }
  return value;
}

function tokenizeYaml(text) {
  const tokens = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = stripComments(raw);
    if (!line.trim()) continue;
    const content = line.replace(/^ +/, "");
    const indent = line.length - content.length;
    tokens.push([indent, content]);
  }
  return tokens;
}

function parseYamlBlock(tokens, index = 0, indent = null) {
  if (index >= tokens.length) return [{}, index];
  if (indent === null) indent = tokens[index][0];
  const firstContent = tokens[index][1];
  if (firstContent.startsWith("- ")) {
    const result = [];
    while (index < tokens.length) {
      const [currentIndent, content] = tokens[index];
      if (currentIndent !== indent || !content.startsWith("- ")) break;
      const value = content.slice(2).trim();
      if (value === "") {
        const [child, next] = parseYamlBlock(tokens, index + 1);
        result.push(child);
        index = next;
      } else {
        result.push(parseScalar(value));
        index += 1;
      }
    }
    return [result, index];
  }

  const result = {};
  while (index < tokens.length) {
    const [currentIndent, content] = tokens[index];
    if (currentIndent !== indent || content.startsWith("- ")) break;
    const sep = content.indexOf(":");
    const key = (sep === -1 ? content : content.slice(0, sep)).trim();
    const remainder = (sep === -1 ? "" : content.slice(sep + 1)).trim();
    if (remainder === "") {
      if (index + 1 < tokens.length && tokens[index + 1][0] > currentIndent) {
        const [child, next] = parseYamlBlock(tokens, index + 1, tokens[index + 1][0]);
        result[key] = child;
        index = next;
      } else {
        result[key] = {};
        index += 1;
      }
    } else {
      result[key] = parseScalar(remainder);
      index += 1;
    }
  }
  return [result, index];
}

function loadYaml(p) {
  if (!p || !fs.existsSync(p)) return {};
  try {
    const tokens = tokenizeYaml(fs.readFileSync(p, "utf8"));
    if (!tokens.length) return {};
    const [parsed] = parseYamlBlock(tokens);
    return isObj(parsed) ? parsed : {};
  } catch (e) {
    return {};
  }
}

function lookupNested(data, dottedKey) {
  let current = data;
  for (const part of dottedKey.split(".")) {
    if (!isObj(current) || !(part in current)) return null;
    current = current[part];
  }
  return current;
}

const boolSetting = (value) => (typeof value === "boolean" ? value : null);

function configPaths(hqRoot, company, project) {
  return {
    global: path.join(hqRoot, "personal", "settings", "auto-share-preferences.yaml"),
    company: company ? path.join(hqRoot, "companies", company, "settings", "auto-share.yaml") : null,
    project: company && project ? path.join(hqRoot, "companies", company, "projects", project, "share-policy.yaml") : null,
  };
}

function classDisabledFromConfig(hqRoot, company, project, artifactClass) {
  const paths = configPaths(hqRoot, company, project);
  const projectCfg = paths.project ? loadYaml(paths.project) : {};
  const companyCfg = paths.company ? loadYaml(paths.company) : {};
  const globalCfg = loadYaml(paths.global);
  const hasKeys = (o) => Object.keys(o).length > 0;

  let enabled = hasKeys(projectCfg) ? boolSetting(lookupNested(projectCfg, "enabled")) : null;
  if (enabled === null) enabled = hasKeys(companyCfg) ? boolSetting(lookupNested(companyCfg, "defaults.enabled")) : null;
  if (enabled === null) enabled = boolSetting(lookupNested(globalCfg, "defaults.enabled"));
  if (enabled === false) return true;

  const classKey = "artifact_classes." + artifactClass;
  let classEnabled = hasKeys(projectCfg) ? boolSetting(lookupNested(projectCfg, classKey)) : null;
  if (classEnabled === null) classEnabled = hasKeys(companyCfg) ? boolSetting(lookupNested(companyCfg, classKey)) : null;
  if (classEnabled === null) classEnabled = boolSetting(lookupNested(globalCfg, classKey));
  return classEnabled === false;
}

function suppressionMatch(record, company, project, artifactClass, fingerprint) {
  if (!isObj(record)) return false;
  const artifact = isObj(record.artifact) ? record.artifact : {};
  if (fingerprint && artifact.fingerprint === fingerprint) return true;
  if (record.kind !== "scope") return false;
  const scope = record.scope;
  const scopeClass = record.artifact_class;
  if (scopeClass && artifactClass && scopeClass !== artifactClass) return false;
  if (scope === "global") return true;
  if (scope === "company") return Boolean(company) && record.company === company;
  if (scope === "project") return Boolean(company && project) && record.company === company && record.project === project;
  return false;
}

// --- dispatch ---
const cmd = process.env.SHARE_SUGGESTION_CMD;
const hqRoot = process.env.SHARE_SUGGESTION_HQ_ROOT;
const pendingPath = process.env.SHARE_SUGGESTION_PENDING_PATH;
const historyPath = process.env.SHARE_SUGGESTION_HISTORY_PATH;
const suppressionsPath = process.env.SHARE_SUGGESTION_SUPPRESSIONS_PATH;
const sessionId = process.env.SHARE_SUGGESTION_SESSION_ID;
const payload = loadPayload();

if (cmd === "enqueue") {
  const suggestion = sanitizeSuggestion(payload, sessionId);
  if (suggestion === null) process.exit(0);
  const existing = readJson(pendingPath, {});
  if (isObj(existing) && Object.keys(existing).length && !existing.resolved_at) {
    process.exit(0);   // one pending suggestion at a time (same as the original)
  }
  writeJson(pendingPath, suggestion);
  const entry = sanitizeHistoryEntry(Object.assign({}, suggestion, { event: "enqueued" }), sessionId);
  if (entry) appendJsonl(historyPath, entry);
  process.exit(0);
}

if (cmd === "peek") {
  const pending = readJson(pendingPath, {});
  if (isObj(pending) && Object.keys(pending).length && !pending.resolved_at) {
    process.stdout.write(JSON.stringify(sortKeys(pending)));
  }
  process.exit(0);
}

if (cmd === "mark-shown") {
  const pending = readJson(pendingPath, {});
  if (isObj(pending) && Object.keys(pending).length && !pending.resolved_at && !pending.shown_at) {
    pending.shown_at = nowIso();
    pending.updated_at = nowIso();
    writeJson(pendingPath, pending);
    const entry = sanitizeHistoryEntry(Object.assign({}, pending, { event: "shown" }), sessionId);
    if (entry) appendJsonl(historyPath, entry);
  }
  process.exit(0);
}

if (cmd === "record-decision") {
  const pending = readJson(pendingPath, {});
  const decision = process.env.SHARE_SUGGESTION_DECISION || sanitizeValue(payload.decision || "");
  if (!isObj(pending) || !Object.keys(pending).length || pending.resolved_at || !decision) process.exit(0);
  pending.decision = decision;
  pending.decision_at = nowIso();
  pending.resolved_at = nowIso();
  pending.updated_at = nowIso();
  if (payload.recipients) pending.recipients = uniquePeople(payload.recipients);
  const entry = sanitizeHistoryEntry(Object.assign({}, pending, { event: "decision", decision: decision }), sessionId);
  if (entry) appendJsonl(historyPath, entry);
  if (["never", "never-again", "never_again"].includes(decision)) {
    const suppression = sanitizeSuppression({
      company: pending.company,
      project: pending.project,
      artifact_class: (pending.artifact || {}).class,
      artifact: pending.artifact,
      reason: "never-again",
    });
    if (suppression) appendJsonl(suppressionsPath, suppression);
  }
  try { fs.unlinkSync(pendingPath); } catch (e) {}
  process.exit(0);
}

if (cmd === "append-history") {
  const entry = sanitizeHistoryEntry(payload, sessionId);
  if (entry) appendJsonl(historyPath, entry);
  process.exit(0);
}

if (cmd === "suppress") {
  const record = sanitizeSuppression(payload);
  if (record) appendJsonl(suppressionsPath, record);
  process.exit(0);
}

if (cmd === "is-suppressed") {
  const artifact = sanitizeArtifact(payload);
  const company = sanitizeValue(payload.company || "");
  const project = sanitizeValue(payload.project || "");
  const artifactClass = sanitizeValue(payload.artifact_class || artifact.class || "");
  const fingerprint = sanitizeValue(artifact.fingerprint || "");
  if (classDisabledFromConfig(hqRoot, company, project, artifactClass)) {
    process.stdout.write("true");
    process.exit(0);
  }
  if (fs.existsSync(suppressionsPath)) {
    for (let raw of fs.readFileSync(suppressionsPath, "utf8").split(/\r?\n/)) {
      raw = raw.trim();
      if (!raw) continue;
      let record;
      try { record = JSON.parse(raw); } catch (e) { continue; }
      if (suppressionMatch(record, company, project, artifactClass, fingerprint)) {
        process.stdout.write("true");
        process.exit(0);
      }
    }
  }
  process.exit(0);
}

process.exit(0);
JS
}

main "$@" || log_error "internal error"
exit 0
