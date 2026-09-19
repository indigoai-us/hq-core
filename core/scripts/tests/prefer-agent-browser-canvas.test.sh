#!/usr/bin/env bash
# prefer-agent-browser-canvas.test.sh — feedback 2297
#
# Browser MCP coordinate clicks miss the Google Docs canvas and unscoped type
# can write into the live document body. HQ cannot fix Claude-in-Chrome's
# coordinate space; the owned follow-up is policy + knowledge + the MCP
# fallback nudge so sessions stop aiming clicks from screenshots.
#
# Invoked from prefer-native-capabilities-trigger.test.sh so pr-checks runs
# it without a workflow-file edit (GitHub App has no workflows permission).
# Tests here are NOT auto-discovered (indigo-hq-core-staging-pr-mechanics rule 3).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
POLICY="$ROOT/core/policies/hq-prefer-agent-browser.md"
README="$ROOT/core/knowledge/public/agent-browser/README.md"
AUTH="$ROOT/core/knowledge/public/agent-browser/auth-profiles.md"
PRE="$ROOT/core/hooks/PreToolUse/50-prefer-agent-browser.sh"
START="$ROOT/core/hooks/SessionStart/50-agent-browser-presence-check.sh"
VALIDATOR="$ROOT/.claude/hooks/validate-policy-frontmatter.sh"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "ok   [$1]"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]: $2"; }

need() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then
    ok "$label"
  else
    fail "$label" "missing in ${file#$ROOT/}: $needle"
  fi
}

echo "== 1. Policy pins canvas refs/keyboard, type-into-body, Google auth =="
need "$POLICY" "Do **not** click from screenshot-measured coordinates." \
  "policy forbids screenshot-coordinate clicks"
need "$POLICY" "find-box type can silently insert into a live" \
  "policy warns type can hit the document body"
need "$POLICY" "agent-browser cannot reuse" \
  "policy says agent-browser cannot reuse Chrome Google login"
need "$POLICY" "(google && docs)" \
  "policy when: includes google+docs"

echo "== 2. Knowledge README + auth-profiles carry the same three facts =="
need "$README" "Do not aim clicks from the screenshot." \
  "README forbids screenshot-aimed clicks"
need "$README" "text meant for the find box can land in a live" \
  "README warns type can hit the document body"
need "$README" "cannot reuse" \
  "README says agent-browser cannot reuse Chrome Google login"
need "$AUTH" "cannot reuse a logged-in Google Chrome session" \
  "auth-profiles documents Google headed sign-in"

echo "== 3. MCP fallback hook warns even when agent-browser is missing =="
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required"; exit 1; }
PAYLOAD='{"tool_name":"mcp__Claude_in_Chrome__computer","tool_input":{"action":"left_click"}}'
BARE_PATH="/usr/bin:/bin"
run_pre() {
  local extra_path="${1-}"
  local env_nudge="${2-}"
  local path="$BARE_PATH"
  [ -n "$extra_path" ] && path="$extra_path:$path"
  printf '%s' "$PAYLOAD" | env -u HQ_NO_AGENT_BROWSER_NUDGE \
    ${env_nudge:+HQ_NO_AGENT_BROWSER_NUDGE="$env_nudge"} \
    PATH="$path" bash "$PRE" 2>/dev/null
}

MISSING_OUT="$(run_pre)"
if printf '%s' "$MISSING_OUT" | grep -Fq 'do not click from screenshot coordinates' \
  && printf '%s' "$MISSING_OUT" | grep -Fq 'silently write into the live document body' \
  && printf '%s' "$MISSING_OUT" | grep -Fq 'cannot reuse a logged-in Chrome Google session'; then
  ok "missing-binary PreToolUse still warns canvas/type/Google-auth"
else
  fail "missing-binary PreToolUse still warns canvas/type/Google-auth" \
    "got: $(printf '%s' "$MISSING_OUT" | tr '\n' ' ' | cut -c1-400)"
fi
if printf '%s' "$MISSING_OUT" | grep -Fq 'agent-browser is not on PATH'; then
  ok "missing-binary PreToolUse tells the session to install"
else
  fail "missing-binary PreToolUse tells the session to install" \
    "install reminder missing"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/agent-browser" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP/bin/agent-browser"
HAVE_OUT="$(run_pre "$TMP/bin")"
if printf '%s' "$HAVE_OUT" | grep -Fq 'do not click from screenshot coordinates' \
  && printf '%s' "$HAVE_OUT" | grep -Fq 'silently write into the live document body' \
  && printf '%s' "$HAVE_OUT" | grep -Fq 'cannot reuse a logged-in Chrome Google session' \
  && printf '%s' "$HAVE_OUT" | grep -Fq 'agent-browser snapshot -i'; then
  ok "installed-binary PreToolUse keeps CLI redirect plus canvas warning"
else
  fail "installed-binary PreToolUse keeps CLI redirect plus canvas warning" \
    "got: $(printf '%s' "$HAVE_OUT" | tr '\n' ' ' | cut -c1-400)"
fi

SILENT_OUT="$(run_pre "" 1)"
if [ -z "$SILENT_OUT" ]; then
  ok "HQ_NO_AGENT_BROWSER_NUDGE=1 silences PreToolUse"
else
  fail "HQ_NO_AGENT_BROWSER_NUDGE=1 silences PreToolUse" \
    "got: $(printf '%s' "$SILENT_OUT" | tr '\n' ' ' | cut -c1-200)"
fi

echo "== 4. SessionStart missing-binary nudge names canvas/type/Google-auth =="
START_OUT="$(printf '{}' | PATH="$BARE_PATH" env -u HQ_NO_AGENT_BROWSER_NUDGE bash "$START" 2>/dev/null)"
if printf '%s' "$START_OUT" | grep -Fq 'screenshot-coordinate clicks miss' \
  && printf '%s' "$START_OUT" | grep -Fq 'type can write into the document body' \
  && printf '%s' "$START_OUT" | grep -Fq 'cannot reuse a logged-in Chrome Google session'; then
  ok "SessionStart fallback names canvas/type/Google-auth"
else
  fail "SessionStart fallback names canvas/type/Google-auth" \
    "got: $(printf '%s' "$START_OUT" | tr '\n' ' ' | cut -c1-400)"
fi

echo "== 5. Policy passes validate-policy-frontmatter.sh =="
if [ -x "$VALIDATOR" ]; then
  VJSON="$(jq -n --arg fp "$POLICY" --rawfile c "$POLICY" \
    '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
  if printf '%s' "$VJSON" | CLAUDE_PROJECT_DIR="$ROOT" bash "$VALIDATOR" >/dev/null 2>&1; then
    ok "validate-policy-frontmatter.sh allows the policy"
  else
    fail "validate-policy-frontmatter.sh allows the policy" "validator blocked"
  fi
else
  fail "validate-policy-frontmatter.sh allows the policy" "validator missing"
fi

echo "== 5b. UserPromptSubmit 'Google Docs' injects hq-prefer-agent-browser =="
INJECT="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
LEDGER_DIR="$ROOT/workspace/orchestrator/policy-trigger-state"
RUN="abcanvas-$$-$RANDOM"
mkdir -p "$LEDGER_DIR"
trap 'rm -rf "$TMP"; rm -f "$LEDGER_DIR"/abcanvas-*'"$RUN"'*.txt 2>/dev/null || true' EXIT
INJECT_OUT="$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"abcanvas-up-%s","prompt":"edit this Google Docs heading","cwd":"%s"}' "$RUN" "$ROOT" \
  | HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$INJECT" 2>/dev/null)"
if printf '%s' "$INJECT_OUT" | grep -Fq '`hq-prefer-agent-browser`'; then
  ok "Google Docs prompt injects hq-prefer-agent-browser"
else
  fail "Google Docs prompt injects hq-prefer-agent-browser" \
    "got: $(printf '%s' "$INJECT_OUT" | tr '\n' ' ' | cut -c1-400)"
fi
NOISE_OUT="$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"abcanvas-noise-%s","prompt":"summarize yesterday standup","cwd":"%s"}' "$RUN" "$ROOT" \
  | HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$INJECT" 2>/dev/null)"
if printf '%s' "$NOISE_OUT" | grep -Fq '`hq-prefer-agent-browser`'; then
  fail "unrelated prompt does not inject hq-prefer-agent-browser" \
    "slug fired on standup prompt"
else
  ok "unrelated prompt does not inject hq-prefer-agent-browser"
fi

echo "== 6. PreToolUse hook drains stdin before the nudge bypass =="
# 1 MiB payload; pipeline status under pipefail is 141 if the writer dies.
head -c 1048576 /dev/zero | tr '\0' 'x' > "$TMP/filler"
jq -n --rawfile p "$TMP/filler" \
  '{tool_name:"mcp__Claude_in_Chrome__computer",tool_input:{action:$p}}' \
  > "$TMP/payload.json"
st="$(PATH="$BARE_PATH" HQ_NO_AGENT_BROWSER_NUDGE=1 bash -c '
  set -o pipefail
  cat "$1" | bash "$2" >/dev/null 2>&1
' _ "$TMP/payload.json" "$PRE" && echo 0 || echo $?)"
if [ "$st" = "0" ]; then
  ok "PreToolUse drains stdin under HQ_NO_AGENT_BROWSER_NUDGE=1"
else
  fail "PreToolUse drains stdin under HQ_NO_AGENT_BROWSER_NUDGE=1" \
    "pipeline status $st"
fi

echo
echo "==== prefer-agent-browser-canvas: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ] || exit 1
