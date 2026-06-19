#!/usr/bin/env bash

set -uo pipefail

# NOTE: bash 3.2 portable (macOS system bash). Do NOT use `mapfile`/`readarray`
# (bash 4+), and do NOT nest a heredoc inside `$( … )` / `< <( … )` — bash 3.2's
# parser mishandles that (phantom "unexpected EOF / unmatched quote"). The two
# embedded Python programs are slurped into variables via standalone heredocs and
# run with `python3 -c "$var"`, which sidesteps both problems.

log_error() {
  printf 'hq-auto-acl-suggest: %s\n' "$*" >&2
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
  local fields_py payload_py field

  input="$(cat 2>/dev/null || echo '{}')"

  # Slurp the field-extractor Python into a variable (standalone heredoc), then
  # run it with `python3 -c` so no heredoc is nested in the process substitution.
  fields_py=""
  IFS= read -r -d '' fields_py <<'PY' || true
import json
import os
import sys

try:
    payload = json.loads(os.environ.get("HOOK_INPUT_JSON", ""))
except Exception:
    payload = {}

tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
tool_response = payload.get("tool_response") if isinstance(payload.get("tool_response"), dict) else {}
values = [
    payload.get("hook_event_name", ""),
    payload.get("session_id", ""),
    payload.get("cwd", ""),
    payload.get("tool_name", ""),
    tool_input.get("command", ""),
    tool_input.get("file_path", ""),
    tool_response.get("stdout", ""),
]
for value in values:
    sys.stdout.write(value if isinstance(value, str) else "")
    sys.stdout.write("\0")
PY

  fields=()
  while IFS= read -r -d '' field; do
    fields+=("$field")
  done < <(HOOK_INPUT_JSON="$input" python3 -c "$fields_py" 2>/dev/null)

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

  # Slurp the payload-builder Python into a variable, then run with `python3 -c`.
  payload_py=""
  IFS= read -r -d '' payload_py <<'PY' || true
import hashlib
import json
import os
import pathlib
import re


root = os.environ["HQ_ROOT"]
company = os.environ["ACTIVE_COMPANY"]
tool_name = os.environ["TOOL_NAME"]
cwd_value = os.environ.get("CWD_VALUE", "")
command_text = os.environ.get("COMMAND_TEXT", "")
file_path = os.environ.get("FILE_PATH", "")
stdout_text = os.environ.get("STDOUT_TEXT", "")
combined = "\n".join(part for part in (command_text, stdout_text) if part)
combined_lower = combined.lower()
root_posix = root.replace("\\", "/")


def normalize_path(raw: str) -> str:
    token = raw.strip().strip('"').strip("'")
    token = re.sub(r'[,.;:)\]]+$', "", token)
    if not token:
        return ""
    if token.startswith(root_posix + "/"):
        token = token[len(root_posix) + 1 :]
    elif os.path.isabs(token) and os.path.commonpath([root, token]) == root:
        token = os.path.relpath(token, root)
    elif not os.path.isabs(token) and cwd_value and os.path.isabs(cwd_value):
        joined = os.path.normpath(os.path.join(cwd_value, token))
        try:
            if os.path.commonpath([root, joined]) == root:
                token = os.path.relpath(joined, root)
        except Exception:
            pass
    return token.replace("\\", "/").lstrip("./")


def extract_paths(text: str):
    search = text.replace(root_posix + "/", "")
    patterns = [
        r'companies/[A-Za-z0-9_-]+/data/[^\s"\'<>]+',
        r'companies/[A-Za-z0-9_-]+/projects/[A-Za-z0-9_-]+/deliverables/[^\s"\'<>]+',
        r'workspace/threads/[^\s"\'<>]+',
        r'workspace/checkpoints/[^\s"\'<>]+',
    ]
    found = []
    for pattern in patterns:
        for match in re.findall(pattern, search):
            cleaned = normalize_path(match)
            if cleaned and cleaned not in found:
                found.append(cleaned)
    return found


def is_sensitive(path: str) -> bool:
    return re.search(r'(revenue|mrr|salary|forecast|payroll|ssn)', pathlib.PurePosixPath(path).name, re.IGNORECASE) is not None


def is_excluded_path(path: str) -> bool:
    if not path:
        return False
    if re.search(rf'^companies/{re.escape(company)}/settings/', path):
        return True
    if re.search(rf'^companies/{re.escape(company)}/signals/', path):
        return True
    if re.search(rf'^companies/{re.escape(company)}/sources/meetings/', path):
        return True
    return is_sensitive(path)


def is_secrets_flow() -> bool:
    return any(
        needle in combined_lower
        for needle in (
            "/hq-secrets",
            "hq secrets",
            "secrets/",
            "credential",
            "credentials",
            "password",
        )
    )


def has_capability_url() -> bool:
    return re.search(r'(share-session|secrets-input)/[A-Za-z0-9_-]+', combined) is not None


def collect_local_people():
    people_root = pathlib.Path(root) / "companies" / company / "people"
    if not people_root.is_dir():
        return []
    people = []
    for meta_path in sorted(people_root.glob("*/meta.yaml")):
        text = meta_path.read_text(encoding="utf-8")
        slug = meta_path.parent.name
        name_match = re.search(r'^name:\s*(.+)$', text, re.MULTILINE)
        role_match = re.search(r'^role:\s*(.+)$', text, re.MULTILINE)
        email_match = re.search(r'^email:\s*(.+)$', text, re.MULTILINE)
        cognito_match = re.search(r'^\s*cognito_sub:\s*"?(.*?)"?\s*$', text, re.MULTILINE)
        _email = email_match.group(1).strip() if email_match else ""
        person = {
            "id": cognito_match.group(1).strip() if cognito_match and cognito_match.group(1).strip() else slug,
            "name": name_match.group(1).strip().strip('"') if name_match else slug,
            "role": role_match.group(1).strip().strip('"') if role_match else "",
        }
        if _email:
            people.append(person)
        else:
            people.append(person)
    return people


def build_path_payload(path: str, trigger: str):
    project = ""
    artifact_class = "vault_data"
    surface = "vault"
    if match := re.match(rf'^companies/{re.escape(company)}/projects/([A-Za-z0-9_-]+)/deliverables/(.+)$', path):
        project = match.group(1)
    elif re.match(rf'^companies/{re.escape(company)}/data/.+', path):
        project = ""
    elif path.startswith("workspace/threads/"):
        artifact_class = "handoff" if "handoff" in combined_lower else "checkpoint"
    elif path.startswith("workspace/checkpoints/"):
        artifact_class = "checkpoint"
    else:
        return None

    fingerprint = hashlib.sha256(f"{company}|{artifact_class}|{path}".encode("utf-8")).hexdigest()
    people = collect_local_people()
    candidate_sources = ["owners", "participants", "recent collaborators"]
    if people:
        candidate_sources = ["local roster", "owners", "participants", "recent collaborators"]
    return {
        "company": company,
        "project": project,
        "trigger": trigger,
        "action_kind": "share-suggestion",
        "suggested_permission": "read",
        "recommended_surface": surface,
        "artifact": {
            "path": path,
            "fingerprint": fingerprint,
            "class": artifact_class,
            "surface": surface,
            "permission": "read",
            "label": pathlib.PurePosixPath(path).name,
        },
        "candidate_hints": {
            "sources": candidate_sources,
            "local_people": people,
            "needs_assistant_resolution": True,
        },
        "recipients": people[:3],
    }


def build_deploy_payload(app_id: str, trigger: str):
    if not app_id:
        return None
    fingerprint = hashlib.sha256(f"{company}|deployable|{app_id}".encode("utf-8")).hexdigest()
    people = collect_local_people()
    candidate_sources = ["owners", "participants", "recent collaborators"]
    if people:
        candidate_sources = ["local roster", "owners", "participants", "recent collaborators"]
    return {
        "company": company,
        "project": "",
        "trigger": trigger,
        "action_kind": "share-suggestion",
        "suggested_permission": "read",
        "recommended_surface": "deploy",
        "artifact": {
            "fingerprint": fingerprint,
            "class": "deployable",
            "surface": "deploy",
            "permission": "read",
            "app_id": app_id,
            "label": f"deploy:{app_id}",
        },
        "candidate_hints": {
            "sources": candidate_sources,
            "local_people": people,
            "needs_assistant_resolution": True,
        },
        "recipients": people[:3],
    }


if has_capability_url() or is_secrets_flow():
    raise SystemExit(0)

payload = None

if tool_name in {"Write", "Edit", "MultiEdit"}:
    candidate = normalize_path(file_path)
    if candidate and not is_excluded_path(candidate):
        if re.match(rf'^companies/{re.escape(company)}/data/.+', candidate):
            payload = build_path_payload(candidate, tool_name.lower())
        elif re.match(rf'^companies/{re.escape(company)}/projects/[A-Za-z0-9_-]+/deliverables/.+', candidate):
            payload = build_path_payload(candidate, tool_name.lower())
elif tool_name == "Bash":
    deploy_signal = bool(re.search(r'https?://\S+', stdout_text)) and ("appid" in combined_lower or "/deploy" in combined_lower or "deploy" in combined_lower)
    if deploy_signal:
        app_id_match = re.search(r'app[_ ]?id["=: ]+([A-Za-z0-9_-]+)', combined, re.IGNORECASE)
        app_id = app_id_match.group(1) if app_id_match else ""
        payload = build_deploy_payload(app_id, "deploy")
    if payload is None:
        paths = extract_paths(combined)
        for candidate in paths:
            if is_excluded_path(candidate):
                continue
            if candidate.startswith("companies/") and not candidate.startswith(f"companies/{company}/"):
                continue
            trigger = "explicit-share"
            if "run-project" in combined_lower and re.search(r'(complete|completed|passed|success|done)', combined_lower):
                trigger = "run-project-complete"
            elif "execute-task" in combined_lower and re.search(r'(complete|completed|passed|success|done)', combined_lower):
                trigger = "execute-task-complete"
            elif "handoff" in combined_lower:
                trigger = "handoff"
            elif "checkpoint" in combined_lower:
                trigger = "checkpoint"
            elif "deploy" in combined_lower:
                trigger = "deploy"
            payload = build_path_payload(candidate, trigger)
            if payload is not None:
                break

if not payload:
    raise SystemExit(0)

artifact_path = payload.get("artifact", {}).get("path", "")
if artifact_path and artifact_path.startswith("companies/") and not artifact_path.startswith(f"companies/{company}/"):
    raise SystemExit(0)

print(json.dumps(payload, sort_keys=True))
PY

  payload="$(
    HQ_ROOT="$hq_root" \
    ACTIVE_COMPANY="$company" \
    TOOL_NAME="$tool_name" \
    CWD_VALUE="$cwd_value" \
    COMMAND_TEXT="$command_text" \
    FILE_PATH="$file_path" \
    STDOUT_TEXT="$stdout_text" \
    python3 -c "$payload_py" 2>/dev/null
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
