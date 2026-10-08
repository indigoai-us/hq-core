#!/usr/bin/env bash

set -uo pipefail

# NOTE: bash 3.2 portable (macOS system bash). Do NOT use `mapfile`/`readarray`
# (bash 4+), and do NOT nest a heredoc inside `$( … )` / `< <( … )` — bash 3.2's
# parser mishandles that (phantom "unexpected EOF / unmatched quote"). The two
# embedded node program is slurped into a variable via a standalone heredoc and
# run with `node -e "$var"`, which sidesteps both problems.

log_error() {
  printf 'hq-auto-acl-suggest: %s\n' "$*" >&2
}

is_hq_root() {
  # Strip trailing slash before appending to prevent "//core" on Windows (MSYS2 SMB stall).
  [ -n "${1:-}" ] && [ -d "${1%/}/core" ] && [ -d "${1%/}/.claude" ]
}

walk_up_to_hq_root() {
  local dir="${1:-}"
  while [ -n "$dir" ]; do
    # Stop before testing "/" so we never form "//core" on Windows.
    [ "$dir" = "/" ] && break
    if is_hq_root "$dir"; then
      printf '%s\n' "$dir"
      return 0
    fi
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
  [ -n "$cleaned" ] || cleaned="unknown"
  printf '%s\n' "$cleaned"
}

read_company_slug() {
  local hq_root="$1" session_id="$2" safe_session_id meta_file company
  safe_session_id="$(sanitize_session_id "$session_id")"
  meta_file="$hq_root/workspace/sessions/$safe_session_id/meta.yaml"
  [ -f "$meta_file" ] || return 1
  company="$(sed -nE 's/^company_slug:[[:space:]]*"?([A-Za-z0-9_-]+)"?[[:space:]]*$/\1/p' "$meta_file" | head -1)"
  [ -n "$company" ] || return 1
  printf '%s\n' "$company"
}

main() {
  local input fields event_name session_id cwd_value tool_name command_text file_path stdout_text
  local lower_signal hq_root helper company payload suppressed
  local field payload_js

  input="$(cat 2>/dev/null || echo '{}')"

  # Extract the seven fields in one jq pass. Each field is base64-encoded onto
  # its own line so multi-line values (commands, stdout) survive the transport;
  # non-string values surface as "".
  fields=()
  while IFS= read -r field; do
    fields+=("$(printf '%s' "$field" | base64 -d 2>/dev/null || true)")
  done < <(printf '%s' "$input" | jq -r '
    def str(v): if (v | type) == "string" then v else "" end;
    def fld(o; k): if (o | type) == "object" then str(o[k]) else "" end;
    [ str(.hook_event_name), str(.session_id), str(.cwd), str(.tool_name),
      fld(.tool_input; "command"), fld(.tool_input; "file_path"),
      fld(.tool_response; "stdout") ]
    | .[] | @base64' 2>/dev/null)

  event_name="${fields[0]:-}"
  session_id="${fields[1]:-}"
  cwd_value="${fields[2]:-}"
  tool_name="${fields[3]:-}"
  command_text="${fields[4]:-}"
  file_path="${fields[5]:-}"
  stdout_text="${fields[6]:-}"

  [ "$event_name" = "PostToolUse" ] || exit 0
  case "$tool_name" in
    Bash|Write|Edit|MultiEdit) ;;
    *) exit 0 ;;
  esac

  case "$tool_name" in
    Write|Edit|MultiEdit)
      case "$file_path" in
        *"/companies/"*"/data/"*|companies/*/data/*|*"/companies/"*"/projects/"*"/deliverables/"*|companies/*/projects/*/deliverables/*) ;;
        *) exit 0 ;;
      esac
      ;;
    Bash)
      lower_signal="$(printf '%s\n%s' "$command_text" "$stdout_text" | tr '[:upper:]' '[:lower:]')"
      case "$lower_signal" in
        *deploy*|*appid*|*run-project*|*execute-task*|*checkpoint*|*handoff*|*hq-share*|*hq-files*|*"hq files "*|*"/deploy"*|*"/hq-share"*|*"/hq-files"*|*companies/*/data/*|*deliverables/*|*workspace/threads/*|*workspace/checkpoints/*) ;;
        *) exit 0 ;;
      esac
      ;;
  esac

  [ -n "$session_id" ] || exit 0

  hq_root="$(resolve_hq_root)" || {
    log_error "unable to resolve HQ root"
    exit 0
  }

  helper="$hq_root/core/scripts/share-suggestion-state.sh"
  [ -f "$helper" ] || {
    log_error "missing state helper"
    exit 0
  }

  company="$(read_company_slug "$hq_root" "$session_id")" || exit 0
  LOCKED_COMPANIES="$company"
  if [ -f "$hq_root/core/scripts/lib/session-scope-capability.sh" ]; then
    # shellcheck source=core/scripts/lib/session-scope-capability.sh
    . "$hq_root/core/scripts/lib/session-scope-capability.sh" 2>/dev/null || true
    if command -v session_scope_read_companies >/dev/null 2>&1; then
      LOCKED_COMPANIES="$(session_scope_read_companies "$hq_root" "$session_id" 2>/dev/null || true)"
    fi
  fi
  [ -n "$LOCKED_COMPANIES" ] || LOCKED_COMPANIES="$company"
  LOCKED_COMPANIES="$(printf '%s\n' "$LOCKED_COMPANIES" | paste -sd, -)"

  # Slurp the payload-builder program (node) into a variable, then run with
  # `node -e` — no heredoc nested in the process substitution.
  payload_js=""
  IFS= read -r -d '' payload_js <<'JS' || true
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const root = process.env.HQ_ROOT || "";
const company = process.env.ACTIVE_COMPANY || "";
const companySlugs = [...new Set(String(process.env.ACTIVE_COMPANIES || company).split(",").filter(Boolean))];
const toolName = process.env.TOOL_NAME || "";
const cwdValue = process.env.CWD_VALUE || "";
const commandText = process.env.COMMAND_TEXT || "";
const filePath = process.env.FILE_PATH || "";
const stdoutText = process.env.STDOUT_TEXT || "";
const combined = [commandText, stdoutText].filter(Boolean).join("\n");
const combinedLower = combined.toLowerCase();
const rootPosix = root.replace(/\\/g, "/");

// rel inside base (lexical best-effort, mirrors commonpath/relpath usage)
function relInside(base, target) {
  try {
    const rel = path.relative(base, target);
    if (rel && !rel.startsWith("..") && !path.isAbsolute(rel)) return rel;
  } catch (e) {}
  return null;
}

function normalizePath(raw) {
  let token = String(raw == null ? "" : raw).trim().replace(/^["']+|["']+$/g, "");
  token = token.replace(/[,.;:)\]]+$/, "");
  if (!token) return "";
  if (token.startsWith(rootPosix + "/")) {
    token = token.slice(rootPosix.length + 1);
  } else if (path.isAbsolute(token)) {
    const rel = relInside(root, token);
    if (rel !== null) token = rel;
  } else if (cwdValue && path.isAbsolute(cwdValue)) {
    const joined = path.normalize(path.join(cwdValue, token));
    const rel = relInside(root, joined);
    if (rel !== null) token = rel;
  }
  return token.replace(/\\/g, "/").replace(/^[./]+/, "");
}

function extractPaths(text) {
  const search = text.split(rootPosix + "/").join("");
  const patterns = [
    /companies\/[A-Za-z0-9_-]+\/data\/[^\s"'<>]+/g,
    /companies\/[A-Za-z0-9_-]+\/projects\/[A-Za-z0-9_-]+\/deliverables\/[^\s"'<>]+/g,
    /workspace\/threads\/[^\s"'<>]+/g,
    /workspace\/checkpoints\/[^\s"'<>]+/g,
  ];
  const found = [];
  for (const pattern of patterns) {
    for (const match of search.match(pattern) || []) {
      const cleaned = normalizePath(match);
      if (cleaned && !found.includes(cleaned)) found.push(cleaned);
    }
  }
  return found;
}

const isSensitive = (p) =>
  /(revenue|mrr|salary|forecast|payroll|ssn)/i.test(path.posix.basename(p));

function isExcludedPath(p) {
  if (!p) return false;
  const pathCompany = (p.match(/^companies\/([a-z][a-z0-9_-]*)\//) || [])[1] || company;
  if (p.startsWith("companies/" + pathCompany + "/settings/")) return true;
  if (p.startsWith("companies/" + pathCompany + "/signals/")) return true;
  if (p.startsWith("companies/" + pathCompany + "/sources/meetings/")) return true;
  return isSensitive(p);
}

const isSecretsFlow = () =>
  ["/hq-secrets", "hq secrets", "secrets/", "credential", "credentials", "password"]
    .some((needle) => combinedLower.includes(needle));

const hasCapabilityUrl = () =>
  /(share-session|secrets-input)\/[A-Za-z0-9_-]+/.test(combined);

function collectLocalPeople(ownerCompany = company) {
  const peopleRoot = path.join(root, "companies", ownerCompany, "people");
  let dirs;
  try { dirs = fs.readdirSync(peopleRoot).sort(); } catch (e) { return []; }
  const people = [];
  for (const slug of dirs) {
    const metaPath = path.join(peopleRoot, slug, "meta.yaml");
    let text;
    try { text = fs.readFileSync(metaPath, "utf8"); } catch (e) { continue; }
    const nameMatch = text.match(/^name:\s*(.+)$/m);
    const roleMatch = text.match(/^role:\s*(.+)$/m);
    const cognitoMatch = text.match(/^\s*cognito_sub:\s*"?(.*?)"?\s*$/m);
    people.push({
      id: (cognitoMatch && cognitoMatch[1].trim()) ? cognitoMatch[1].trim() : slug,
      name: nameMatch ? nameMatch[1].trim().replace(/^"|"$/g, "") : slug,
      role: roleMatch ? roleMatch[1].trim().replace(/^"|"$/g, "") : "",
    });
  }
  return people;
}

const sha256 = (s) => crypto.createHash("sha256").update(s, "utf8").digest("hex");

function buildPathPayload(p, trigger) {
  const pathCompany = (p.match(/^companies\/([a-z][a-z0-9_-]*)\//) || [])[1] || company;
  if (!companySlugs.includes(pathCompany)) return null;
  let project = "";
  let artifactClass = "vault_data";
  const surface = "vault";
  const delivMatch = p.match(new RegExp("^companies/" + pathCompany + "/projects/([A-Za-z0-9_-]+)/deliverables/(.+)$"));
  if (delivMatch) {
    project = delivMatch[1];
  } else if (p.startsWith("companies/" + pathCompany + "/data/") && p.length > ("companies/" + pathCompany + "/data/").length) {
    project = "";
  } else if (p.startsWith("workspace/threads/")) {
    artifactClass = combinedLower.includes("handoff") ? "handoff" : "checkpoint";
  } else if (p.startsWith("workspace/checkpoints/")) {
    artifactClass = "checkpoint";
  } else {
    return null;
  }

  const fingerprint = sha256(pathCompany + "|" + artifactClass + "|" + p);
  const people = collectLocalPeople(pathCompany);
  let candidateSources = ["owners", "participants", "recent collaborators"];
  if (people.length) candidateSources = ["local roster", "owners", "participants", "recent collaborators"];
  return {
    company: pathCompany,
    project: project,
    trigger: trigger,
    action_kind: "share-suggestion",
    suggested_permission: "read",
    recommended_surface: surface,
    artifact: {
      path: p,
      fingerprint: fingerprint,
      class: artifactClass,
      surface: surface,
      permission: "read",
      label: path.posix.basename(p),
    },
    candidate_hints: {
      sources: candidateSources,
      local_people: people,
      needs_assistant_resolution: true,
    },
    recipients: people.slice(0, 3),
  };
}

function deployCompanyForTrigger() {
  const targets = [];
  for (const value of [cwdValue, commandText]) {
    const matches = value.matchAll(/companies\/([A-Za-z0-9_-]+)(?:\/|\b)/g);
    for (const match of matches) if (companySlugs.includes(match[1])) targets.push(match[1]);
  }
  const unique = [...new Set(targets)];
  if (unique.length === 1) return unique[0];
  return unique.length === 0 && companySlugs.length === 1 ? companySlugs[0] : "";
}

function buildDeployPayload(appId, trigger) {
  if (!appId) return null;
  const deployCompany = deployCompanyForTrigger();
  if (!deployCompany) return null;
  const fingerprint = sha256(deployCompany + "|deployable|" + appId);
  const people = collectLocalPeople(deployCompany);
  let candidateSources = ["owners", "participants", "recent collaborators"];
  if (people.length) candidateSources = ["local roster", "owners", "participants", "recent collaborators"];
  return {
    company: deployCompany,
    project: "",
    trigger: trigger,
    action_kind: "share-suggestion",
    suggested_permission: "read",
    recommended_surface: "deploy",
    artifact: {
      fingerprint: fingerprint,
      class: "deployable",
      surface: "deploy",
      permission: "read",
      app_id: appId,
      label: "deploy:" + appId,
    },
    candidate_hints: {
      sources: candidateSources,
      local_people: people,
      needs_assistant_resolution: true,
    },
    recipients: people.slice(0, 3),
  };
}

if (hasCapabilityUrl() || isSecretsFlow()) process.exit(0);

let payload = null;

if (["Write", "Edit", "MultiEdit"].includes(toolName)) {
  const candidate = normalizePath(filePath);
  const pathCompany = (candidate.match(/^companies\/([a-z][a-z0-9_-]*)\//) || [])[1] || "";
  if (candidate && companySlugs.includes(pathCompany) && !isExcludedPath(candidate)) {
    if (candidate.startsWith("companies/" + pathCompany + "/data/") && candidate.length > ("companies/" + pathCompany + "/data/").length) {
      payload = buildPathPayload(candidate, toolName.toLowerCase());
    } else if (candidate.startsWith("companies/" + pathCompany + "/projects/") && /\/deliverables\//.test(candidate)) {
      payload = buildPathPayload(candidate, toolName.toLowerCase());
    }
  }
} else if (toolName === "Bash") {
  const deploySignal = /https?:\/\/\S+/.test(stdoutText) &&
    (combinedLower.includes("appid") || combinedLower.includes("/deploy") || combinedLower.includes("deploy"));
  if (deploySignal) {
    const appIdMatch = combined.match(/app[_ ]?id["=: ]+([A-Za-z0-9_-]+)/i);
    const appId = appIdMatch ? appIdMatch[1] : "";
    payload = buildDeployPayload(appId, "deploy");
  }
  if (payload == null) {
    for (const candidate of extractPaths(combined)) {
      if (isExcludedPath(candidate)) continue;
      const pathCompany = (candidate.match(/^companies\/([a-z][a-z0-9_-]*)\//) || [])[1];
      if (pathCompany && !companySlugs.includes(pathCompany)) continue;
      let trigger = "explicit-share";
      if (combinedLower.includes("run-project") && /(complete|completed|passed|success|done)/.test(combinedLower)) {
        trigger = "run-project-complete";
      } else if (combinedLower.includes("execute-task") && /(complete|completed|passed|success|done)/.test(combinedLower)) {
        trigger = "execute-task-complete";
      } else if (combinedLower.includes("handoff")) {
        trigger = "handoff";
      } else if (combinedLower.includes("checkpoint")) {
        trigger = "checkpoint";
      } else if (combinedLower.includes("deploy")) {
        trigger = "deploy";
      }
      payload = buildPathPayload(candidate, trigger);
      if (payload != null) break;
    }
  }
}

if (!payload) process.exit(0);

const artifactPath = (payload.artifact && payload.artifact.path) || "";
if (artifactPath && artifactPath.startsWith("companies/") && !companySlugs.some((slug) => artifactPath.startsWith("companies/" + slug + "/"))) {
  process.exit(0);
}

// deterministic key order (mirrors json.dumps sort_keys=True)
const sortKeys = (v) =>
  Array.isArray(v) ? v.map(sortKeys)
  : (v && typeof v === "object")
    ? Object.keys(v).sort().reduce((o, k) => { o[k] = sortKeys(v[k]); return o; }, {})
    : v;
console.log(JSON.stringify(sortKeys(payload)));
JS

  command -v node >/dev/null 2>&1 || exit 0

  payload="$(
    HQ_ROOT="$hq_root" \
    ACTIVE_COMPANY="$company" \
    ACTIVE_COMPANIES="${LOCKED_COMPANIES:-$company}" \
    TOOL_NAME="$tool_name" \
    CWD_VALUE="$cwd_value" \
    COMMAND_TEXT="$command_text" \
    FILE_PATH="$file_path" \
    STDOUT_TEXT="$stdout_text" \
    node -e "$payload_js" 2>/dev/null
  )"

  [ -n "$payload" ] || exit 0

  suppressed="$(printf '%s' "$payload" | "$helper" is-suppressed "$session_id" || true)"
  [ "$suppressed" = "true" ] && exit 0

  printf '%s' "$payload" | "$helper" enqueue "$session_id" >/dev/null || {
    log_error "unable to enqueue suggestion"
    exit 0
  }
}

main "$@" || {
  log_error "internal error"
  exit 0
}
exit 0
