#!/usr/bin/env bash
# master-hook-empty-json-outputs.test.sh
#
# Pins that master-hook.sh keeps a layered PreToolUse exit 2 when no child
# emits JSON. On bash 3.2 + set -u (stock macOS), an unguarded
# "${json_outputs[@]}" abort after the blocker has already set exit_code=2
# returns 1 — a non-blocking error — and silently weakens
# hq-write-tool-blocked-on-repos.
#
# Linux CI runs bash 4.4+/5, which does not abort on empty assigned arrays, so
# the behavioural cases would pass even with the old loop. The source assertion
# is the CI-proof gate: every json_outputs / json_sources list expansion must
# use the same ${arr[@]+"${arr[@]}"} idiom the hooks dispatch loop already uses.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"
BLOCKER="$ROOT/core/hooks/PreToolUse/10-Edit,Write,MultiEdit--block-repo-edits-use-worktree.sh"
NUDGE="$ROOT/core/hooks/PreToolUse/50-prefer-agent-browser.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$MASTER" ] || fail "missing $MASTER"
[ -f "$BLOCKER" ] || fail "missing $BLOCKER"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

# ── 1. Portable empty-array iteration must not abort under set -u ───────────
(
  set -u
  json_outputs=()
  count=0
  for jo in ${json_outputs[@]+"${json_outputs[@]}"}; do
    count=$((count + 1))
  done
  [ "$count" -eq 0 ] || fail "empty +guard iter produced $count items"
)
pass "portable +guard skips an empty assigned array under set -u"

# ── 2. Source: no leftover unguarded json_outputs / json_sources [@] lists ──
# Every quoted "${name[@]}" on an executable line must be the inner half of
# ${name[@]+"${name[@]}"}. Comments may name the broken form.
assert_list_expansions_guarded() {
  local name="$1" line n=0
  local quoted='"${'"$name"'[@]}"'
  local guarded='${'"$name"'[@]+"${'"$name"'[@]}"}'
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "${line#"${line%%[![:space:]]*}"}" in \#*) continue ;; esac
    case "$line" in
      *"$quoted"*)
        case "$line" in
          *"$guarded"*) ;;
          *) fail "$MASTER:$n unguarded $quoted: $line" ;;
        esac
        ;;
    esac
  done < "$MASTER"
}
assert_list_expansions_guarded json_outputs
assert_list_expansions_guarded json_sources

# The has_blocking_json scan (the abort site that downgrades exit 2) must use
# the +guard, not a bare quoted [@] expansion.
scan="$(awk '/has_blocking_json=0/{flag=1} flag && /for jo in/{print; exit}' "$MASTER")"
case "$scan" in
  *'${json_outputs[@]+"${json_outputs[@]}"}'*) ;;
  *) fail "has_blocking_json scan is not +guarded: $scan" ;;
esac
pass "master-hook json_outputs/json_sources list expansions are +guarded"

# ── 3. Fixture: plain-text exit 2 + silent sibling keeps process exit 2 ─────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/hooks/PreToolUse" \
  "$FIX/core/scripts" "$FIX/workspace/sessions" "$FIX/repos/private/app"
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
chmod +x "$FIX/.claude/hooks/master-hook.sh"

cat > "$FIX/core/hooks/PreToolUse/10-Edit,Write,MultiEdit--block.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "blocked: repos/ writes require a worktree" >&2
exit 2
EOF
cat > "$FIX/core/hooks/PreToolUse/50-prefer-agent-browser.sh" <<'EOF'
#!/usr/bin/env bash
# hq-hook-match: mcp__Claude_in_Chrome__*,mcp__playwright__*,mcp__Playwright__*
cat >/dev/null
exit 0
EOF
chmod +x "$FIX/core/hooks/PreToolUse/"*.sh

run_master() {
  local event="$1" payload="$2" out="$3" err="$4" rc=0
  printf '%s' "$payload" \
    | env HQ_HOOK_TIMEOUT_SENTRY=0 CLAUDE_PROJECT_DIR="$FIX" \
      bash "$FIX/.claude/hooks/master-hook.sh" "$event" >"$out" 2>"$err" || rc=$?
  printf '%s' "$rc"
}

WRITE_PAYLOAD="$(jq -nc --arg p "$FIX/repos/private/app/src.ts" \
  '{tool_name:"Write",tool_input:{file_path:$p},session_id:"s-empty-json"}')"

rc="$(run_master PreToolUse "$WRITE_PAYLOAD" "$TMP/plain.out" "$TMP/plain.err")"
[ "$rc" = "2" ] || fail "plain-text blocker: expected exit 2, got $rc stderr=$(cat "$TMP/plain.err")"
grep -q 'blocked: repos/ writes require a worktree' "$TMP/plain.err" \
  || fail "plain-text blocker did not emit stderr: $(cat "$TMP/plain.err")"
[ ! -s "$TMP/plain.out" ] || fail "plain-text blocker leaked stdout: $(cat "$TMP/plain.out")"
pass "plain-text exit 2 with empty json_outputs stays 2"

# ── 4. No children: empty json_outputs must still exit 0 ────────────────────
rm -f "$FIX/core/hooks/PreToolUse/"*.sh
SESSION_PAYLOAD="$(jq -nc '{session_id:"s-no-children",hook_event_name:"SessionStart"}')"
rc="$(run_master SessionStart "$SESSION_PAYLOAD" "$TMP/none.out" "$TMP/none.err")"
[ "$rc" = "0" ] || fail "no children: expected exit 0, got $rc stderr=$(cat "$TMP/none.err")"
pass "no children exits 0 with empty json_outputs"

# ── 5. JSON block still wins (does not regress aggregation) ─────────────────
mkdir -p "$FIX/core/hooks/PreToolUse"
cat > "$FIX/core/hooks/PreToolUse/10-json-block.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"decision":"block","reason":"json-block"}'
exit 0
EOF
chmod +x "$FIX/core/hooks/PreToolUse/10-json-block.sh"
rc="$(run_master PreToolUse "$WRITE_PAYLOAD" "$TMP/json.out" "$TMP/json.err")"
[ "$rc" = "0" ] || fail "JSON block: expected child exit 0, got $rc"
jq -e '.decision == "block" and (.hookSpecificOutput.hqSessionBlockedBy | endswith("10-json-block.sh"))' \
  "$TMP/json.out" >/dev/null || fail "JSON block aggregation: $(cat "$TMP/json.out")"
pass "JSON block still aggregates with provenance"

# ── 6. Shipped repo-edit blocker through master-hook (no live Write) ────────
rm -f "$FIX/core/hooks/PreToolUse/"*.sh
cp "$BLOCKER" "$FIX/core/hooks/PreToolUse/"
[ -f "$NUDGE" ] && cp "$NUDGE" "$FIX/core/hooks/PreToolUse/"
[ -f "$ROOT/core/scripts/hook-lib.sh" ] && cp "$ROOT/core/scripts/hook-lib.sh" "$FIX/core/scripts/"
chmod +x "$FIX/core/hooks/PreToolUse/"*.sh
rc="$(run_master PreToolUse "$WRITE_PAYLOAD" "$TMP/live.out" "$TMP/live.err")"
[ "$rc" = "2" ] || fail "shipped blocker via master-hook: expected exit 2, got $rc stderr=$(cat "$TMP/live.err")"
grep -q 'BLOCKED: direct edits inside repos/ are not allowed' "$TMP/live.err" \
  || fail "shipped blocker stderr missing: $(cat "$TMP/live.err")"
pass "shipped repos/ blocker via master-hook still exits 2"

echo "ALL PASS: master-hook-empty-json-outputs"
exit 0
