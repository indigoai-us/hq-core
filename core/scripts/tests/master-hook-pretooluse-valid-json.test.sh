#!/usr/bin/env bash
# master-hook-pretooluse-valid-json.test.sh
#
# Hosts parse PreToolUse stdout as one JSON object. Mixed plain-text plus JSON
# (or bare advisory text) is reported as "Hook master-hook.sh PreToolUse
# returned invalid JSON" and the tool call is blocked for safety.
set -euo pipefail
export HQ_HOOK_DEDUPE=0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$MASTER" ] || fail "missing $MASTER"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/hooks/PreToolUse" \
  "$FIX/core/scripts" "$FIX/workspace/sessions"
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIX/.claude/hooks/"
chmod +x "$FIX/.claude/hooks/master-hook.sh"

run_master() {
  local payload="$1" out="$2" err="$3" rc=0
  printf '%s' "$payload" \
    | env HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_DEDUPE=0 CLAUDE_PROJECT_DIR="$FIX" \
      bash "$FIX/.claude/hooks/master-hook.sh" PreToolUse >"$out" 2>"$err" || rc=$?
  printf '%s' "$rc"
}

assert_stdout_json_object() {
  local out="$1" label="$2"
  [ -s "$out" ] || fail "$label: empty stdout"
  jq -e 'type == "object"' "$out" >/dev/null \
    || fail "$label: stdout is not a JSON object: $(head -c 200 "$out" | tr '\n' ' ')"
}

PAYLOAD="$(jq -nc '{tool_name:"Glob",tool_input:{pattern:"*"},session_id:"s-valid-json"}')"

# ── 1. Plain advisory + JSON sibling: one JSON object, not mixed ───────────
cat > "$FIX/core/hooks/PreToolUse/10-plain.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'advisory: use the Write tool\n'
exit 0
EOF
cat > "$FIX/core/hooks/PreToolUse/20-json.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"ok"}}'
exit 0
EOF
chmod +x "$FIX/core/hooks/PreToolUse/10-plain.sh" "$FIX/core/hooks/PreToolUse/20-json.sh"

rc="$(run_master "$PAYLOAD" "$TMP/mixed.out" "$TMP/mixed.err")"
[ "$rc" = "0" ] || fail "mixed: expected exit 0, got $rc stderr=$(head -c 200 "$TMP/mixed.err" | tr '\n' ' ')"
assert_stdout_json_object "$TMP/mixed.out" "mixed"
jq -e '.hookSpecificOutput.additionalContext | test("advisory: use the Write tool")' "$TMP/mixed.out" >/dev/null \
  || fail "mixed: plain advisory was dropped: $(cat "$TMP/mixed.out")"
jq -e '.hookSpecificOutput.additionalContext | test("ok")' "$TMP/mixed.out" >/dev/null \
  || fail "mixed: JSON context was dropped: $(cat "$TMP/mixed.out")"
pass "plain plus JSON sibling emits one JSON object"

# ── 2. Plain-only PreToolUse stays plain (policy reminders, contract) ──────
rm -f "$FIX/core/hooks/PreToolUse/"*.sh
cat > "$FIX/core/hooks/PreToolUse/10-plain-only.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'advisory: prefer Glob over a shell find\n'
exit 0
EOF
chmod +x "$FIX/core/hooks/PreToolUse/10-plain-only.sh"

rc="$(run_master "$PAYLOAD" "$TMP/plain.out" "$TMP/plain.err")"
[ "$rc" = "0" ] || fail "plain-only: expected exit 0, got $rc stderr=$(head -c 200 "$TMP/plain.err" | tr '\n' ' ')"
grep -q 'prefer Glob' "$TMP/plain.out" \
  || fail "plain-only: advisory missing: $(cat "$TMP/plain.out")"
if jq -e 'type == "object"' "$TMP/plain.out" >/dev/null 2>&1; then
  fail "plain-only: must stay plain text, not JSON: $(cat "$TMP/plain.out")"
fi
pass "plain-only PreToolUse stays plain text"

# ── 3. JSON-only still a single object ─────────────────────────────────────
rm -f "$FIX/core/hooks/PreToolUse/"*.sh
cat > "$FIX/core/hooks/PreToolUse/20-json-only.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"solo"}}'
exit 0
EOF
chmod +x "$FIX/core/hooks/PreToolUse/20-json-only.sh"

rc="$(run_master "$PAYLOAD" "$TMP/json.out" "$TMP/json.err")"
[ "$rc" = "0" ] || fail "json-only: expected exit 0, got $rc"
assert_stdout_json_object "$TMP/json.out" "json-only"
jq -e '.hookSpecificOutput.additionalContext == "solo"' "$TMP/json.out" >/dev/null \
  || fail "json-only: context lost: $(cat "$TMP/json.out")"
pass "json-only PreToolUse stays a JSON object"

# ── 4. Other events keep plain text next to a JSON sibling ─────────────────
# Only PreToolUse folds. PostToolUse, UserPromptSubmit and SessionStart must
# still emit a plain hook's text (first) and the merged JSON (after it).
for ev in PostToolUse UserPromptSubmit SessionStart; do
  mkdir -p "$FIX/core/hooks/$ev"
  rm -f "$FIX/core/hooks/$ev/"*.sh
  cat > "$FIX/core/hooks/$ev/10-plain.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'advisory: plain sibling text\n'
exit 0
EOF
  printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf %%s %s\nexit 0\n' \
    "'{\"hookSpecificOutput\":{\"hookEventName\":\"$ev\",\"additionalContext\":\"json-sibling\"}}'" \
    > "$FIX/core/hooks/$ev/20-json.sh"
  chmod +x "$FIX/core/hooks/$ev/10-plain.sh" "$FIX/core/hooks/$ev/20-json.sh"
  rc=0
  printf '%s' "$PAYLOAD" \
    | env HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_DEDUPE=0 CLAUDE_PROJECT_DIR="$FIX" \
      bash "$FIX/.claude/hooks/master-hook.sh" "$ev" >"$TMP/$ev.out" 2>"$TMP/$ev.err" || rc=$?
  [ "$rc" = "0" ] || fail "$ev: expected exit 0, got $rc stderr=$(head -c 200 "$TMP/$ev.err" | tr '\n' ' ')"
  [ "$(head -n 1 "$TMP/$ev.out")" = "advisory: plain sibling text" ] \
    || fail "$ev: plain sibling text dropped or not first: $(head -c 300 "$TMP/$ev.out" | tr '\n' '|')"
  tail -n 1 "$TMP/$ev.out" | jq -e '.hookSpecificOutput.additionalContext == "json-sibling"' >/dev/null \
    || fail "$ev: JSON sibling missing after the plain text: $(head -c 300 "$TMP/$ev.out" | tr '\n' '|')"
  pass "$ev keeps plain sibling text before the JSON"
done

echo "ALL PASS: master-hook-pretooluse-valid-json"
exit 0
