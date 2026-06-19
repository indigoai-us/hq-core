#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label: missing '$needle'"
}

assert_empty() {
  local value="$1" label="$2"
  [ -z "$value" ] || fail "$label: expected empty output, got: $value"
}

make_root() {
  local name="$1"
  local root="$TMP/$name"
  mkdir -p \
    "$root/.claude/hooks" \
    "$root/core/hooks/Stop" \
    "$root/core/scripts" \
    "$root/.claude/state" \
    "$root/workspace/sessions" \
    "$root/projects/demo/journal"
  cp "$ROOT/core/scripts/share-suggestion-state.sh" "$root/core/scripts/share-suggestion-state.sh"
  cp "$ROOT/core/hooks/Stop/40-auto-acl-share-suggestion.sh" "$root/core/hooks/Stop/40-auto-acl-share-suggestion.sh"
  cp "$ROOT/core/hooks/Stop/50-after-turn-suggestions.sh" "$root/core/hooks/Stop/50-after-turn-suggestions.sh"
  chmod +x \
    "$root/core/scripts/share-suggestion-state.sh" \
    "$root/core/hooks/Stop/40-auto-acl-share-suggestion.sh" \
    "$root/core/hooks/Stop/50-after-turn-suggestions.sh"
  cat > "$root/projects/demo/journal/active.md" <<'EOF'
---
project: projects/demo
---
EOF
  printf '%s' "$root/projects/demo/journal/active.md" > "$root/.claude/state/active-journal"
  cat > "$root/projects/demo/prd.json" <<'EOF'
{
  "name": "demo",
  "userStories": [
    { "id": "US-001", "passes": false }
  ]
}
EOF
  printf '%s' "$root"
}

enqueue_pending() {
  local root="$1" session_id="$2"
  printf '%s' "$(jq -n \
    --arg company acme \
    --arg path "companies/acme/data/reports/demo-report.md" \
    --arg fingerprint "fp-demo-123" \
    --arg class vault_data \
    --arg surface vault \
    --arg trigger write \
    --arg permission read \
    '{company:$company, trigger:$trigger, suggested_permission:$permission, recommended_surface:$surface, artifact:{path:$path,fingerprint:$fingerprint,class:$class,surface:$surface,permission:$permission}, recipients:[{id:"person-123",name:"Jane Example",role:"Engineering Lead"}], candidate_hints:{sources:["owners","participants"],local_people:[{id:"person-123",name:"Jane Example",role:"Engineering Lead"}],needs_assistant_resolution:true}}')" \
    | CLAUDE_PROJECT_DIR="$root" "$root/core/scripts/share-suggestion-state.sh" enqueue "$session_id" >/dev/null
}

# pending suggestion emits once, then stays quiet
HQ_A="$(make_root a)"
enqueue_pending "$HQ_A" "sess-reminder"
payload='{"session_id":"sess-reminder"}'
out="$(CLAUDE_PROJECT_DIR="$HQ_A" "$HQ_A/core/hooks/Stop/40-auto-acl-share-suggestion.sh" <<<"$payload")"
assert_contains "$out" "<hq-share-suggestion>" "wrapper"
assert_contains "$out" "Approve (recommended)" "approve option"
assert_contains "$out" "Edit recipients" "edit option"
assert_contains "$out" "hq files share --permission read" "vault primitive"
assert_contains "$out" "fp-demo-123" "fingerprint surfaced"

out_second="$(CLAUDE_PROJECT_DIR="$HQ_A" "$HQ_A/core/hooks/Stop/40-auto-acl-share-suggestion.sh" <<<"$payload")"
assert_empty "$out_second" "shown reminder does not repeat"

# suppression from a never-again decision blocks future reminders
HQ_B="$(make_root b)"
enqueue_pending "$HQ_B" "sess-suppressed"
CLAUDE_PROJECT_DIR="$HQ_B" "$HQ_B/core/scripts/share-suggestion-state.sh" record-decision "sess-suppressed" "never" >/dev/null
assert_contains "$(cat "$HQ_B/workspace/orchestrator/share-suggestions/suppressions.jsonl")" "fp-demo-123" "never-again suppression written"
out_suppressed="$(CLAUDE_PROJECT_DIR="$HQ_B" "$HQ_B/core/hooks/Stop/40-auto-acl-share-suggestion.sh" <<<'{"session_id":"sess-suppressed"}')"
assert_empty "$out_suppressed" "no pending suggestion means no reminder"

# pending share suggestion suppresses generic after-turn nudges
HQ_C="$(make_root c)"
enqueue_pending "$HQ_C" "sess-after-turn"
transcript="$HQ_C/transcript.jsonl"
cat > "$transcript" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Project created with user stories."}]}}
EOF
out_after_turn="$(CLAUDE_PROJECT_DIR="$HQ_C" "$HQ_C/core/hooks/Stop/50-after-turn-suggestions.sh" <<<"{\"session_id\":\"sess-after-turn\",\"transcript_path\":\"$transcript\"}")"
assert_empty "$out_after_turn" "generic nudge is suppressed while share suggestion is pending"

echo "auto-acl-share-reminder smoke: ok"
