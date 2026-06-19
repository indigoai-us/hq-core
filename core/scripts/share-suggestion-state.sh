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
  python3 - <<'PY'
import json
import os
import pathlib
import re
import sys
from datetime import datetime, timezone


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_json(path: pathlib.Path, default):
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text())
    except Exception:
        return default


def write_json(path: pathlib.Path, payload) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def append_jsonl(path: pathlib.Path, payload) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True) + "\n")


def load_payload():
    raw = os.environ.get("SHARE_SUGGESTION_PAYLOAD", "")
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except Exception:
        return {}


def sanitize_value(value):
    if isinstance(value, str):
        return value.strip()
    return value


def sanitize_person(person):
    if not isinstance(person, dict):
        return None
    person_id = sanitize_value(person.get("id") or person.get("slug") or "")
    name = sanitize_value(person.get("name") or "")
    role = sanitize_value(person.get("role") or "")
    cleaned = {}
    if person_id:
        cleaned["id"] = person_id
    if name:
        cleaned["name"] = name
    if role:
        cleaned["role"] = role
    return cleaned or None


def unique_people(items):
    seen = set()
    result = []
    for item in items or []:
        cleaned = sanitize_person(item)
        if not cleaned:
            continue
        key = (cleaned.get("id", ""), cleaned.get("name", ""))
        if key in seen:
            continue
        seen.add(key)
        result.append(cleaned)
    return result


def sanitize_sources(items):
    allowed = []
    seen = set()
    for item in items or []:
        if not isinstance(item, str):
            continue
        value = item.strip()
        if not value or value in seen:
            continue
        seen.add(value)
        allowed.append(value)
    return allowed


def sanitize_artifact(payload):
    if not isinstance(payload, dict):
        payload = {}
    artifact = payload.get("artifact")
    if not isinstance(artifact, dict):
        artifact = payload
    cleaned = {}
    for key in ("path", "fingerprint", "class", "surface", "permission", "app_id", "label"):
        value = sanitize_value(artifact.get(key))
        if isinstance(value, str) and value:
            cleaned[key] = value
    if "permission" not in cleaned:
        cleaned["permission"] = "read"
    return cleaned


def sanitize_candidate_hints(payload):
    hints = payload.get("candidate_hints")
    if not isinstance(hints, dict):
        hints = {}
    cleaned = {
        "sources": sanitize_sources(hints.get("sources") or payload.get("candidate_sources") or []),
        "local_people": unique_people(hints.get("local_people") or payload.get("local_people") or []),
        "needs_assistant_resolution": bool(
            hints.get("needs_assistant_resolution")
            if "needs_assistant_resolution" in hints
            else payload.get("needs_assistant_resolution")
        ),
    }
    project_hints = hints.get("project_recipient_hints") or payload.get("project_recipient_hints") or []
    project_cleaned = sanitize_sources(project_hints)
    if project_cleaned:
        cleaned["project_recipient_hints"] = project_cleaned
    return cleaned


def sanitize_suggestion(payload, session_id):
    artifact = sanitize_artifact(payload)
    fingerprint = artifact.get("fingerprint", "")
    company = sanitize_value(payload.get("company") or "")
    project = sanitize_value(payload.get("project") or "")
    suggestion = {
        "session_id": session_id,
        "company": company,
        "project": project,
        "artifact": artifact,
        "trigger": sanitize_value(payload.get("trigger") or ""),
        "action_kind": sanitize_value(payload.get("action_kind") or "share-suggestion"),
        "suggested_permission": sanitize_value(payload.get("suggested_permission") or artifact.get("permission") or "read"),
        "recommended_surface": sanitize_value(payload.get("recommended_surface") or artifact.get("surface") or ""),
        "recipients": unique_people(payload.get("recipients") or []),
        "candidate_hints": sanitize_candidate_hints(payload),
        "created_at": payload.get("created_at") or now_iso(),
        "updated_at": now_iso(),
        "shown_at": payload.get("shown_at"),
    }
    if not company or not fingerprint:
        return None
    return suggestion


def sanitize_history_entry(payload, session_id):
    artifact = sanitize_artifact(payload)
    entry = {
        "session_id": session_id,
        "company": sanitize_value(payload.get("company") or ""),
        "project": sanitize_value(payload.get("project") or ""),
        "trigger": sanitize_value(payload.get("trigger") or ""),
        "action_kind": sanitize_value(payload.get("action_kind") or "share-suggestion"),
        "decision": sanitize_value(payload.get("decision") or ""),
        "event": sanitize_value(payload.get("event") or ""),
        "artifact": artifact,
        "recipients": unique_people(payload.get("recipients") or []),
        "recorded_at": now_iso(),
    }
    if not entry["artifact"].get("fingerprint"):
        return None
    return entry


def sanitize_suppression(payload):
    artifact = sanitize_artifact(payload)
    scope = sanitize_value(payload.get("scope") or "")
    record = {
        "kind": "scope" if scope else "artifact",
        "scope": scope,
        "company": sanitize_value(payload.get("company") or ""),
        "project": sanitize_value(payload.get("project") or ""),
        "artifact_class": sanitize_value(payload.get("artifact_class") or artifact.get("class") or ""),
        "artifact": {},
        "reason": sanitize_value(payload.get("reason") or "suppressed"),
        "created_at": now_iso(),
    }
    if artifact.get("fingerprint"):
        record["artifact"]["fingerprint"] = artifact["fingerprint"]
    if artifact.get("path"):
        record["artifact"]["path"] = artifact["path"]
    if scope:
        if scope not in {"global", "company", "project"}:
            return None
        return record
    if not record["artifact"].get("fingerprint"):
        return None
    return record


def strip_comments(line: str) -> str:
    in_single = False
    in_double = False
    chars = []
    for ch in line:
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            break
        chars.append(ch)
    return "".join(chars).rstrip()


def parse_scalar(value: str):
    value = value.strip()
    if value == "":
        return ""
    lowered = value.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if lowered in {"null", "~"}:
        return None
    if value == "{}":
        return {}
    if value == "[]":
        return []
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        return [parse_scalar(part.strip()) for part in inner.split(",")]
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        return value[1:-1]
    if re.fullmatch(r"-?\d+", value):
        try:
            return int(value)
        except Exception:
            return value
    return value


def tokenize_yaml(text: str):
    tokens = []
    for raw in text.splitlines():
        line = strip_comments(raw)
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        content = line.lstrip(" ")
        tokens.append((indent, content))
    return tokens


def parse_yaml_block(tokens, index=0, indent=None):
    if index >= len(tokens):
        return {}, index
    if indent is None:
        indent = tokens[index][0]
    first_content = tokens[index][1]
    if first_content.startswith("- "):
        result = []
        while index < len(tokens):
            current_indent, content = tokens[index]
            if current_indent != indent or not content.startswith("- "):
                break
            value = content[2:].strip()
            if value == "":
                child, index = parse_yaml_block(tokens, index + 1)
                result.append(child)
            else:
                result.append(parse_scalar(value))
                index += 1
        return result, index

    result = {}
    while index < len(tokens):
        current_indent, content = tokens[index]
        if current_indent != indent or content.startswith("- "):
            break
        key, _, remainder = content.partition(":")
        key = key.strip()
        remainder = remainder.strip()
        if remainder == "":
            if index + 1 < len(tokens) and tokens[index + 1][0] > current_indent:
                child, index = parse_yaml_block(tokens, index + 1, tokens[index + 1][0])
                result[key] = child
            else:
                result[key] = {}
                index += 1
        else:
            result[key] = parse_scalar(remainder)
            index += 1
    return result, index


def load_yaml(path: pathlib.Path):
    if not path.exists():
        return {}
    try:
        tokens = tokenize_yaml(path.read_text())
        if not tokens:
            return {}
        parsed, _ = parse_yaml_block(tokens)
        return parsed if isinstance(parsed, dict) else {}
    except Exception:
        return {}


def lookup_nested(data, dotted_key):
    current = data
    for part in dotted_key.split("."):
        if not isinstance(current, dict) or part not in current:
            return None
        current = current[part]
    return current


def bool_setting(value):
    if isinstance(value, bool):
        return value
    return None


def config_paths(hq_root: pathlib.Path, company: str, project: str):
    return {
        "global": hq_root / "personal" / "settings" / "auto-share-preferences.yaml",
        "company": hq_root / "companies" / company / "settings" / "auto-share.yaml" if company else None,
        "project": hq_root / "companies" / company / "projects" / project / "share-policy.yaml" if company and project else None,
    }


def class_disabled_from_config(hq_root: pathlib.Path, company: str, project: str, artifact_class: str):
    paths = config_paths(hq_root, company, project)
    project_cfg = load_yaml(paths["project"]) if paths["project"] else {}
    company_cfg = load_yaml(paths["company"]) if paths["company"] else {}
    global_cfg = load_yaml(paths["global"])

    enabled = (
        bool_setting(lookup_nested(project_cfg, "enabled"))
        if project_cfg
        else None
    )
    if enabled is None:
        enabled = bool_setting(lookup_nested(company_cfg, "defaults.enabled")) if company_cfg else None
    if enabled is None:
        enabled = bool_setting(lookup_nested(global_cfg, "defaults.enabled"))
    if enabled is False:
        return True

    class_key = f"artifact_classes.{artifact_class}"
    class_enabled = (
        bool_setting(lookup_nested(project_cfg, class_key))
        if project_cfg
        else None
    )
    if class_enabled is None:
        class_enabled = bool_setting(lookup_nested(company_cfg, class_key)) if company_cfg else None
    if class_enabled is None:
        class_enabled = bool_setting(lookup_nested(global_cfg, class_key))
    return class_enabled is False


def suppression_match(record, company: str, project: str, artifact_class: str, fingerprint: str) -> bool:
    if not isinstance(record, dict):
        return False
    artifact = record.get("artifact") if isinstance(record.get("artifact"), dict) else {}
    if fingerprint and artifact.get("fingerprint") == fingerprint:
        return True
    if record.get("kind") != "scope":
        return False
    scope = record.get("scope")
    scope_class = record.get("artifact_class")
    if scope_class and artifact_class and scope_class != artifact_class:
        return False
    if scope == "global":
        return True
    if scope == "company":
        return bool(company) and record.get("company") == company
    if scope == "project":
        return bool(company and project) and record.get("company") == company and record.get("project") == project
    return False


cmd = os.environ["SHARE_SUGGESTION_CMD"]
hq_root = pathlib.Path(os.environ["SHARE_SUGGESTION_HQ_ROOT"])
pending_path = pathlib.Path(os.environ["SHARE_SUGGESTION_PENDING_PATH"])
history_path = pathlib.Path(os.environ["SHARE_SUGGESTION_HISTORY_PATH"])
suppressions_path = pathlib.Path(os.environ["SHARE_SUGGESTION_SUPPRESSIONS_PATH"])
session_id = os.environ["SHARE_SUGGESTION_SESSION_ID"]
payload = load_payload()

if cmd == "enqueue":
    suggestion = sanitize_suggestion(payload, session_id)
    if suggestion is None:
        sys.exit(0)
    existing = read_json(pending_path, {})
    if existing and not existing.get("resolved_at"):
        existing_fp = ((existing.get("artifact") or {}).get("fingerprint") or "")
        if existing_fp == suggestion["artifact"]["fingerprint"]:
            sys.exit(0)
        sys.exit(0)
    write_json(pending_path, suggestion)
    entry = sanitize_history_entry({**suggestion, "event": "enqueued"}, session_id)
    if entry:
        append_jsonl(history_path, entry)
    sys.exit(0)

if cmd == "peek":
    pending = read_json(pending_path, {})
    if pending and not pending.get("resolved_at"):
        sys.stdout.write(json.dumps(pending, sort_keys=True))
    sys.exit(0)

if cmd == "mark-shown":
    pending = read_json(pending_path, {})
    if pending and not pending.get("resolved_at") and not pending.get("shown_at"):
        pending["shown_at"] = now_iso()
        pending["updated_at"] = now_iso()
        write_json(pending_path, pending)
        entry = sanitize_history_entry({**pending, "event": "shown"}, session_id)
        if entry:
            append_jsonl(history_path, entry)
    sys.exit(0)

if cmd == "record-decision":
    pending = read_json(pending_path, {})
    decision = os.environ.get("SHARE_SUGGESTION_DECISION", "") or sanitize_value(payload.get("decision") or "")
    if not pending or pending.get("resolved_at") or not decision:
        sys.exit(0)
    pending["decision"] = decision
    pending["decision_at"] = now_iso()
    pending["resolved_at"] = now_iso()
    pending["updated_at"] = now_iso()
    if payload.get("recipients"):
        pending["recipients"] = unique_people(payload.get("recipients"))
    entry = sanitize_history_entry({**pending, "event": "decision", "decision": decision}, session_id)
    if entry:
        append_jsonl(history_path, entry)
    if decision in {"never", "never-again", "never_again"}:
        suppression = sanitize_suppression(
            {
                "company": pending.get("company"),
                "project": pending.get("project"),
                "artifact_class": (pending.get("artifact") or {}).get("class"),
                "artifact": pending.get("artifact"),
                "reason": "never-again",
            }
        )
        if suppression:
            append_jsonl(suppressions_path, suppression)
    pending_path.unlink(missing_ok=True)
    sys.exit(0)

if cmd == "append-history":
    entry = sanitize_history_entry(payload, session_id)
    if entry:
        append_jsonl(history_path, entry)
    sys.exit(0)

if cmd == "suppress":
    record = sanitize_suppression(payload)
    if record:
        append_jsonl(suppressions_path, record)
    sys.exit(0)

if cmd == "is-suppressed":
    artifact = sanitize_artifact(payload)
    company = sanitize_value(payload.get("company") or "")
    project = sanitize_value(payload.get("project") or "")
    artifact_class = sanitize_value(payload.get("artifact_class") or artifact.get("class") or "")
    fingerprint = sanitize_value(artifact.get("fingerprint") or "")
    if class_disabled_from_config(hq_root, company, project, artifact_class):
        sys.stdout.write("true")
        sys.exit(0)
    if suppressions_path.exists():
        for raw in suppressions_path.read_text().splitlines():
            raw = raw.strip()
            if not raw:
                continue
            try:
                record = json.loads(raw)
            except Exception:
                continue
            if suppression_match(record, company, project, artifact_class, fingerprint):
                sys.stdout.write("true")
                sys.exit(0)
    sys.exit(0)

raise SystemExit(0)
PY
}

main "$@" || log_error "internal error"
exit 0
