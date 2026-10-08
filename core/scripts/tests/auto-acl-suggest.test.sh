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

# The state reader distinguishes an absent pending item from an unreadable one.
HQ_STATE_READ="$(make_root state-read)"
STATE_HELPER="$HQ_STATE_READ/core/scripts/share-suggestion-state.sh"
STATE_FILE="$(queue_file "$HQ_STATE_READ" "state-read")"
state_out="$(CLAUDE_PROJECT_DIR="$HQ_STATE_READ" "$STATE_HELPER" peek state-read)"
assert_empty "$state_out" "missing state file returns the default pending map"

mkdir -p "$(dirname "$STATE_FILE")"
printf '%s\n' '{"company":"acme","artifact":{"path":"companies/acme/reports/normal.md"}}' > "$STATE_FILE"
expected_state='{"artifact":{"path":"companies/acme/reports/normal.md"},"company":"acme"}'
state_out="$(CLAUDE_PROJECT_DIR="$HQ_STATE_READ" "$STATE_HELPER" peek state-read)"
assert_eq "$state_out" "$expected_state" "normal state output remains unchanged"

printf '%s\n' '{not-json' > "$STATE_FILE"
if CLAUDE_PROJECT_DIR="$HQ_STATE_READ" "$STATE_HELPER" peek state-read >"$TMP/state-corrupt.out" 2>"$TMP/state-corrupt.err"; then
  state_status=0
else
  state_status=$?
fi
[ "$state_status" -ne 0 ] || fail "corrupt state file should fail non-zero"
assert_empty "$(cat "$TMP/state-corrupt.out")" "corrupt state file stdout"
assert_eq "$(cat "$TMP/state-corrupt.err")" "share-suggestion-state: unable to read $STATE_FILE (SyntaxError)" "corrupt state diagnostic"

# [a] qualifying Write enqueues one sanitized item
HQ_A="$(make_root a)"
set_company "$HQ_A" "sess-write" "acme"
payload_write="$(HQ_A="$HQ_A" python3 - <<'PY'
import json, os
root = os.environ["HQ_A"]
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
payload_no_company="$(HQ_B="$HQ_B" python3 - <<'PY'
import json, os
root = os.environ["HQ_B"]
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
  payload="$(HQ_C="$HQ_C" REL_PATH="$rel_path" python3 - <<'PY'
import json, os
root = os.environ["HQ_C"]
rel_path = os.environ["REL_PATH"]
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

payload_secrets="$(HQ_C="$HQ_C" python3 - <<'PY'
import json, os
print(json.dumps({
  "hook_event_name": "PostToolUse",
  "session_id": "sess-settings",
  "cwd": os.environ["HQ_C"],
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
mkdir -p "$HQ_D/companies/beta"
mkdir -p "$HQ_D/core/scripts/lib"
cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$HQ_D/core/scripts/lib/session-scope-capability.sh"
cp "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$HQ_D/core/scripts/hqd-hook-flag-cache-lib.sh"
mkdir -p "$HQ_D/.codex/hooks"
printf '%s\n' 'process.stdout.write("true")' > "$HQ_D/.codex/hooks/codex-explicit-path-flag.cjs"
printf '{"session_id":"sess-deploy","company_slug":"acme","company_slugs":["acme","beta"]}\n' \
  > "$HQ_D/workspace/sessions/sess-deploy/scope-capability.json"
payload_deploy="$(HQ_D="$HQ_D" python3 - <<'PY'
import json, os
print(json.dumps({
  "hook_event_name": "PostToolUse",
  "session_id": "sess-deploy",
  "cwd": os.environ["HQ_D"] + "/companies/beta",
  "tool_name": "Bash",
  "tool_input": {"command": "/deploy companies/beta/workspace/reports/demo"},
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
assert_eq "$(jq -r '.company' "$queue_d")" "beta" "deploy suggestion uses deployment company instead of primary"

# [e] session_id traversal chars are sanitized for queue state
HQ_E="$(make_root e)"
mkdir -p "$HQ_E/workspace/sessions/___escape"
cat > "$HQ_E/workspace/sessions/___escape/meta.yaml" <<'YAML'
company_slug: acme
YAML
payload_traversal="$(HQ_E="$HQ_E" python3 - <<'PY'
import json, os
root = os.environ["HQ_E"]
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
payload_global="$(HQ_FG="$HQ_FG" python3 - <<'PY'
import json, os
root = os.environ["HQ_FG"]
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
payload_company="$(HQ_FC="$HQ_FC" python3 - <<'PY'
import json, os
root = os.environ["HQ_FC"]
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
payload_project="$(HQ_FP="$HQ_FP" python3 - <<'PY'
import json, os
root = os.environ["HQ_FP"]
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
payload_suppressed="$(HQ_FS="$HQ_FS" python3 - <<'PY'
import json, os
root = os.environ["HQ_FS"]
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

# [g] a moved-helper forwarder failure stays advisory and preserves the hook's
# exact stderr contract. The failed suppression probe and enqueue each surface
# the forwarder's message; enqueue then adds its own diagnostic. An absent
# helper reports only the existing missing-helper diagnostic.
HQ_FFAIL="$(make_root f-fail)"
set_company "$HQ_FFAIL" "sess-forwarder" "acme"
payload_forwarder="$(HQ_FFAIL="$HQ_FFAIL" python3 - <<'PY'
import json, os
root = os.environ["HQ_FFAIL"]
print(json.dumps({
  "hook_event_name": "PostToolUse",
  "session_id": "sess-forwarder",
  "cwd": root,
  "tool_name": "Write",
  "tool_input": {"file_path": f"{root}/companies/acme/data/reports/forwarder.md"},
  "tool_response": {"stdout": ""}
}))
PY
)"
FAIL_HELPER="$HQ_FFAIL/core/scripts/share-suggestion-state.sh"
FAIL_LOG="$TMP/share-forwarder.calls"
FORWARDER_MESSAGE='share-suggestion-state.sh: this script needs hq-cli >= 5.78.0 (found 5.77.0); upgrade with: npm install -g @indigoai-us/hq-cli@latest'
cat > "$FAIL_HELPER" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '$FORWARDER_MESSAGE' >&2
printf 'called\\n' >> '$FAIL_LOG'
exit 127
EOF
chmod +x "$FAIL_HELPER"
if printf '%s' "$payload_forwarder" | CLAUDE_PROJECT_DIR="$HQ_FFAIL" \
  "$HQ_FFAIL/.claude/hooks/hq-auto-acl-suggest.sh" >"$TMP/forwarder.out" 2>"$TMP/forwarder.err"; then
  got=0
else
  got=$?
fi
[ "$got" = 0 ] || fail "forwarder status should stay advisory, got $got"
[ ! -s "$TMP/forwarder.out" ] || fail "forwarder unexpectedly wrote stdout: $(cat "$TMP/forwarder.out")"
printf '%s\n%s\nhq-auto-acl-suggest: unable to enqueue suggestion\n' \
  "$FORWARDER_MESSAGE" "$FORWARDER_MESSAGE" > "$TMP/forwarder.expected"
cmp -s "$TMP/forwarder.expected" "$TMP/forwarder.err" \
  || { diff -u "$TMP/forwarder.expected" "$TMP/forwarder.err" >&2 || true; fail "forwarder stderr differs"; }
[ "$(wc -l < "$FAIL_LOG" | tr -d ' ')" = 2 ] || fail "forwarder should be called twice"
rm -f "$FAIL_HELPER"
if printf '%s' "$payload_forwarder" | CLAUDE_PROJECT_DIR="$HQ_FFAIL" \
  "$HQ_FFAIL/.claude/hooks/hq-auto-acl-suggest.sh" >"$TMP/absent.out" 2>"$TMP/absent.err"; then
  got=0
else
  got=$?
fi
[ "$got" = 0 ] && [ ! -s "$TMP/absent.out" ] || fail "absent helper changed hook status/stdout"
[ "$(cat "$TMP/absent.err")" = 'hq-auto-acl-suggest: missing state helper' ] \
  || fail "absent helper stderr differs: $(cat "$TMP/absent.err")"

echo "auto-acl-suggest smoke: ok"
