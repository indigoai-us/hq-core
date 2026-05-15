#!/usr/bin/env bash
# Smoke tests for the single-company auto-startwork SessionStart hook.

set -euo pipefail

HQ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$HQ_ROOT/.claude/hooks/auto-startwork.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if ! printf '%s' "$haystack" | grep -qF "$needle"; then
    fail "$label: missing '$needle'"
  fi
}

assert_empty() {
  local value="$1"
  local label="$2"
  if [ -n "$value" ]; then
    fail "$label: expected empty output, got: $value"
  fi
}

[ -x "$HOOK" ] || fail "hook is not executable: $HOOK"

mkdir -p "$TMP_ROOT/companies"

cat > "$TMP_ROOT/companies/manifest.yaml" <<'YAML'
companies:
  acme:
    name: Acme
    path: companies/acme
YAML

payload='{"hook_event_name":"SessionStart","source":"startup","session_id":"s-test"}'
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_contains "$out" "<auto-startwork>" "single-company wrapper"
assert_contains "$out" "/startwork acme" "single-company command"

out_resume=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<'{"source":"resume"}')
assert_empty "$out_resume" "resume source does not auto-start"

out_disabled_env=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_AUTO_STARTWORK=0 bash "$HOOK" <<<"$payload")
assert_empty "$out_disabled_env" "HQ_AUTO_STARTWORK=0 disables hook"

out_disabled_hook=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_DISABLED_HOOKS=auto-startwork bash "$HOOK" <<<"$payload")
assert_empty "$out_disabled_hook" "HQ_DISABLED_HOOKS disables hook"

cat > "$TMP_ROOT/companies/manifest.yaml" <<'YAML'
companies:
  acme:
    name: Acme
  beta:
    name: Beta
YAML

out_multi=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_empty "$out_multi" "multi-company manifest stays explicit"

cat > "$TMP_ROOT/companies/manifest.yaml" <<'YAML'
acme:
  name: Acme
YAML

out_legacy=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_contains "$out_legacy" "/startwork acme" "legacy manifest command"

echo "auto-startwork smoke: ok"
