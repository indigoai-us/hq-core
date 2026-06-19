#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

assert_not_file() {
  [ ! -e "$1" ] || fail "unexpected file: $1"
}

assert_empty() {
  local value="$1" label="$2"
  [ -z "$value" ] || fail "$label: expected empty output, got: $value"
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

queue_file() {
  local root="$1" session_id="$2" safe
  safe="$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9_-' '_')"
  [ -n "$safe" ] || safe="unknown"
  printf '%s/workspace/orchestrator/share-suggestions/%s.json' "$root" "$safe"
}

write_default_global_prefs() {
  local root="$1"
  mkdir -p "$root/personal/settings"
  cat > "$root/personal/settings/auto-share-preferences.yaml" <<'YAML'
version: 1
defaults:
  enabled: true
artifact_classes:
  deployable: true
  vault_data: true
  checkpoint: false
  handoff: false
surfaces:
  in_session_picker: true
  dm: false
YAML
}

make_root() {
  local name="$1"
  local root="$TMP/$name"
  mkdir -p \
    "$root/.claude/hooks" \
    "$root/core/scripts" \
    "$root/workspace/sessions" \
    "$root/companies/acme/data/reports" \
    "$root/companies/acme/projects/demo/deliverables" \
    "$root/companies/acme/settings" \
    "$root/companies/acme/signals/notes" \
    "$root/companies/acme/sources/meetings" \
    "$root/companies/acme/people/jane-smith"
  cp "$ROOT/.claude/hooks/hq-auto-acl-suggest.sh" "$root/.claude/hooks/hq-auto-acl-suggest.sh"
  cp "$ROOT/core/scripts/share-suggestion-state.sh" "$root/core/scripts/share-suggestion-state.sh"
  chmod +x "$root/.claude/hooks/hq-auto-acl-suggest.sh" "$root/core/scripts/share-suggestion-state.sh"
  write_default_global_prefs "$root"
  cat > "$root/companies/acme/people/jane-smith/meta.yaml" <<'YAML'
name: Jane Example
role: Engineering Lead
handles:
  cognito_sub: "person-123"
YAML
  printf '%s' "$root"
}

set_company() {
  local root="$1" session_id="$2" company="$3"
  mkdir -p "$root/workspace/sessions/$session_id"
  cat > "$root/workspace/sessions/$session_id/meta.yaml" <<YAML
session_id: $session_id
company_slug: $company
YAML
}

run_hook() {
  local root="$1" payload="$2"
  CLAUDE_PROJECT_DIR="$root" "$root/.claude/hooks/hq-auto-acl-suggest.sh" <<<"$payload"
}

# [a] qualifying Write enqueues one sanitized item
HQ_A="$(make_root a)"
set_company "$HQ_A" "sess-write" "acme"
payload_write="$(python3 - <<PY
import json
root = ${HQ_A@Q}
print(json.dumps({
  "hook_event_name": "PostToolUse",
  "session_id": "sess-write",
  "cwd": root,
  "tool_name": "Write",
  "tool_input": {"file_path": f"{root}/companies/acme/data/reports/demo-report.md"},
  "tool_response": {"stdout": ""}
}))
PY
)"
out="$(run_hook "$HQ_A" "$payload_write")"
assert_empty "$out" "detector stays quiet"
queue_a="$(queue_file "$HQ_A" "sess-write")"
assert_file "$queue_a"
assert_eq "$(find "$HQ_A/workspace/orchestrator/share-suggestions" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')" "1" "one pending queue file"
assert_eq "$(jq -r '.company' "$queue_a")" "acme" "queue company"
assert_eq "$(jq -r '.artifact.path' "$queue_a")" "companies/acme/data/reports/demo-report.md" "queue artifact path"
assert_eq "$(jq -r '.artifact.class' "$queue_a")" "vault_data" "queue artifact class"
assert_eq "$(jq -r '.artifact.surface' "$queue_a")" "vault" "queue artifact surface"
assert_eq "$(jq -r '.suggested_permission' "$queue_a")" "read" "queue permission"
assert_eq "$(jq -r '.recipients[0].id' "$queue_a")" "person-123" "local roster recipient id"
if grep -E '"(url|token|password|secret)"' "$queue_a" >/dev/null; then
  fail "queue file stored a sensitive key"
fi

# [b] missing company_slug fails closed
HQ_B="$(make_root b)"
payload_no_company="$(python3 - <<PY
import json
root = ${HQ_B@Q}
print(json.dumps({
  "hook_event_name": "PostToolUse",
  "session_id": "sess-no-company",
  "cwd": root,
  "tool_name": "Write",
  "tool_input": {"file_path": f"{root}/companies/acme/data/reports/demo-report.md"},
  "tool_response": {"stdout": ""}
}))
PY
)"
out="$(run_hook "$HQ_B" "$payload_no_company")"
assert_empty "$out" "missing company stays quiet"
assert_not_file "$(queue_file "$HQ_B" "sess-no-company")"

# [c] exclusions stay quiet
HQ_C="$(make_root c)"
set_company "$HQ_C" "sess-settings" "acme"
for rel_path in \
  "companies/acme/settings/prefs.yaml" \
  "companies/acme/signals/notes/summary.md" \
  "companies/acme/sources/meetings/raw.md" \
  "companies/acme/data/reports/salary-forecast.md"
do
  payload="$(python3 - <<PY
import json
root = ${HQ_C@Q}
rel_path = ${rel_path@Q}
print(json.dumps({
  "hook_event_name": "PostToolUse",
  "session_id": "sess-settings",
  "cwd": root,
  "tool_name": "Write",
  "tool_input": {"file_path": f"{root}/{rel_path}"},
  "tool_response": {"stdout": ""}
}))
PY
)"
  out="$(run_hook "$HQ_C" "$payload")"
  assert_empty "$out" "excluded write stays quiet"
  assert_not_file "$(queue_file "$HQ_C" "sess-settings")"
done

payload_secrets="$(python3 - <<PY
import json
print(json.dumps({
  "hook_event_name": "PostToolUse",
  "session_id": "sess-settings",
  "cwd": ${HQ_C@Q},
  "tool_name": "Bash",
  "tool_input": {"command": "hq secrets exec -- env"},
  "tool_response": {"stdout": "ok"}
}))
PY
)"
out="$(run_hook "$HQ_C" "$payload_secrets")"
assert_empty "$out" "secrets flow stays quiet"
assert_not_file "$(queue_file "$HQ_C" "sess-settings")"

# [d] queue and history never persist urls or secret-bearing fields
HQ_D="$(make_root d)"
set_company "$HQ_D" "sess-deploy" "acme"
payload_deploy="$(python3 - <<PY
import json
print(json.dumps({
  "hook_event_name": "PostToolUse",
  "session_id": "sess-deploy",
  "cwd": ${HQ_D@Q},
  "tool_name": "Bash",
  "tool_input": {"command": "/deploy workspace/reports/demo"},
  "tool_response": {"stdout": "deploy complete appId=app-123 URL=https://deploy.example.com/demo"}
}))
PY
)"
out="$(run_hook "$HQ_D" "$payload_deploy")"
assert_empty "$out" "deploy trigger stays quiet"
queue_d="$(queue_file "$HQ_D" "sess-deploy")"
assert_file "$queue_d"
history_d="$HQ_D/workspace/orchestrator/share-suggestions/history.jsonl"
assert_file "$history_d"
if grep -RIE 'https?://|share-session/|"url"|"token"|"password"|"secret"' "$HQ_D/workspace/orchestrator/share-suggestions" >/dev/null; then
  fail "state files persisted sensitive strings"
fi
assert_eq "$(jq -r '.artifact.app_id' "$queue_d")" "app-123" "deploy app id stored without url"

# [e] session_id traversal chars are sanitized for queue state
HQ_E="$(make_root e)"
mkdir -p "$HQ_E/workspace/sessions/___escape"
cat > "$HQ_E/workspace/sessions/___escape/meta.yaml" <<'YAML'
company_slug: acme
YAML
payload_traversal="$(python3 - <<PY
import json
root = ${HQ_E@Q}
print(json.dumps({
  "hook_event_name": "PostToolUse",
  "session_id": "../escape",
  "cwd": root,
  "tool_name": "Write",
  "tool_input": {"file_path": f"{root}/companies/acme/data/reports/path-safe.md"},
  "tool_response": {"stdout": ""}
}))
PY
)"
out="$(run_hook "$HQ_E" "$payload_traversal")"
assert_empty "$out" "traversal session stays quiet"
assert_file "$(queue_file "$HQ_E" "../escape")"
assert_not_file "$HQ_E/workspace/orchestrator/share-suggestions/../escape.json"

# [f] opt-out and suppression prevent queueing
HQ_FG="$(make_root fg)"
set_company "$HQ_FG" "sess-global" "acme"
cat > "$HQ_FG/personal/settings/auto-share-preferences.yaml" <<'YAML'
version: 1
defaults:
  enabled: true
artifact_classes:
  deployable: true
  vault_data: false
  checkpoint: false
  handoff: false
surfaces:
  in_session_picker: true
  dm: false
YAML
payload_global="$(python3 - <<PY
import json
root = ${HQ_FG@Q}
print(json.dumps({
  "hook_event_name": "PostToolUse",
  "session_id": "sess-global",
  "cwd": root,
  "tool_name": "Write",
  "tool_input": {"file_path": f"{root}/companies/acme/data/reports/global-blocked.md"},
  "tool_response": {"stdout": ""}
}))
PY
)"
out="$(run_hook "$HQ_FG" "$payload_global")"
assert_empty "$out" "global opt-out stays quiet"
assert_not_file "$(queue_file "$HQ_FG" "sess-global")"

HQ_FC="$(make_root fc)"
set_company "$HQ_FC" "sess-company" "acme"
mkdir -p "$HQ_FC/companies/acme/settings"
cat > "$HQ_FC/companies/acme/settings/auto-share.yaml" <<'YAML'
version: 1
defaults:
  enabled: false
artifact_classes:
  deployable: true
  vault_data: true
  checkpoint: false
  handoff: false
surfaces:
  in_session_picker: true
  dm: false
YAML
payload_company="$(python3 - <<PY
import json
root = ${HQ_FC@Q}
print(json.dumps({
  "hook_event_name": "PostToolUse",
  "session_id": "sess-company",
  "cwd": root,
  "tool_name": "Write",
  "tool_input": {"file_path": f"{root}/companies/acme/data/reports/company-blocked.md"},
  "tool_response": {"stdout": ""}
}))
PY
)"
out="$(run_hook "$HQ_FC" "$payload_company")"
assert_empty "$out" "company opt-out stays quiet"
assert_not_file "$(queue_file "$HQ_FC" "sess-company")"

HQ_FP="$(make_root fp)"
set_company "$HQ_FP" "sess-project" "acme"
mkdir -p "$HQ_FP/companies/acme/projects/demo"
cat > "$HQ_FP/companies/acme/projects/demo/share-policy.yaml" <<'YAML'
version: 1
enabled: false
artifact_classes: {}
recipient_hints: []
YAML
payload_project="$(python3 - <<PY
import json
root = ${HQ_FP@Q}
print(json.dumps({
  "hook_event_name": "PostToolUse",
  "session_id": "sess-project",
  "cwd": root,
  "tool_name": "Write",
  "tool_input": {"file_path": f"{root}/companies/acme/projects/demo/deliverables/demo.html"},
  "tool_response": {"stdout": ""}
}))
PY
)"
out="$(run_hook "$HQ_FP" "$payload_project")"
assert_empty "$out" "project opt-out stays quiet"
assert_not_file "$(queue_file "$HQ_FP" "sess-project")"

HQ_FS="$(make_root fs)"
set_company "$HQ_FS" "sess-suppress" "acme"
payload_suppressed="$(python3 - <<PY
import json
root = ${HQ_FS@Q}
print(json.dumps({
  "hook_event_name": "PostToolUse",
  "session_id": "sess-suppress",
  "cwd": root,
  "tool_name": "Write",
  "tool_input": {"file_path": f"{root}/companies/acme/data/reports/repeat.md"},
  "tool_response": {"stdout": ""}
}))
PY
)"
run_hook "$HQ_FS" "$payload_suppressed" >/dev/null
queue_fs="$(queue_file "$HQ_FS" "sess-suppress")"
assert_file "$queue_fs"
fp="$(jq -r '.artifact.fingerprint' "$queue_fs")"
CLAUDE_PROJECT_DIR="$HQ_FS" "$HQ_FS/core/scripts/share-suggestion-state.sh" record-decision "sess-suppress" "not-now" >/dev/null
printf '%s' "$(jq -n --arg company acme --arg fp "$fp" '{company:$company, artifact:{fingerprint:$fp}, reason:"never-again"}')" \
  | CLAUDE_PROJECT_DIR="$HQ_FS" "$HQ_FS/core/scripts/share-suggestion-state.sh" suppress "sess-suppress" >/dev/null
run_hook "$HQ_FS" "$payload_suppressed" >/dev/null
assert_not_file "$queue_fs"

echo "auto-acl-suggest smoke: ok"
