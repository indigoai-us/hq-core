#!/usr/bin/env bash

set -uo pipefail

log_error() {
  printf 'auto-acl-share-suggestion: %s\n' "$*" >&2
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

main() {
  local input session_id hq_root helper pending reminder

  input="$(cat 2>/dev/null || echo '{}')"
  session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
  [ -n "$session_id" ] || exit 0

  hq_root="$(resolve_hq_root)" || {
    log_error "unable to resolve HQ root"
    exit 0
  }

  helper="$hq_root/core/scripts/share-suggestion-state.sh"
  [ -f "$helper" ] || exit 0

  pending="$("$helper" peek "$session_id" || true)"
  [ -n "$pending" ] || exit 0

  reminder="$(
    PENDING_JSON="$pending" python3 - <<'PY'
import json
import os

try:
    pending = json.loads(os.environ.get("PENDING_JSON", ""))
except Exception:
    pending = {}

if not pending or pending.get("shown_at"):
    raise SystemExit(0)

artifact = pending.get("artifact") if isinstance(pending.get("artifact"), dict) else {}
candidate_hints = pending.get("candidate_hints") if isinstance(pending.get("candidate_hints"), dict) else {}
recipients = pending.get("recipients") if isinstance(pending.get("recipients"), list) else []
local_people = candidate_hints.get("local_people") if isinstance(candidate_hints.get("local_people"), list) else []
display_people = recipients or local_people
names = []
for person in display_people[:3]:
    if isinstance(person, dict):
        label = person.get("name") or person.get("id") or ""
        if label:
            names.append(label)

recipients_text = ", ".join(names) if names else "no exact recipients yet"
artifact_ref = artifact.get("path") or artifact.get("label") or artifact.get("fingerprint", "")[:12]
fingerprint = artifact.get("fingerprint", "")
surface = pending.get("recommended_surface") or artifact.get("surface") or "vault"
permission = pending.get("suggested_permission") or artifact.get("permission") or "read"

print("<hq-share-suggestion>")
print("A share suggestion is pending.")
print(f"Artifact: {artifact_ref}")
print(f"Fingerprint: {fingerprint}")
print(f"Recommended surface: {surface}")
print(f"Top candidate recipients: {recipients_text}")
print(f"Suggested permission: {permission}")
print("Next turn: ask exactly one structured decision with these options:")
print("- Approve (recommended)")
print("- Edit recipients")
print("- Not now")
print("- Never suggest this again")
print("If approved, execute only with existing primitives: use `hq files share --permission read` for vault artifacts, or deploy access-policy/access-mode for deploy surfaces.")
print("Do not persist any resulting capability URL.")
print("</hq-share-suggestion>")
PY
  )"

  [ -n "$reminder" ] || exit 0
  printf '%s\n' "$reminder"
  "$helper" mark-shown "$session_id" >/dev/null || true
}

main "$@" || {
  log_error "internal error"
  exit 0
}
exit 0
