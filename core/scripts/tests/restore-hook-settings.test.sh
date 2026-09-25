#!/usr/bin/env bash
# restore-hook-settings.test.sh — regression for feedback 2282.
#
# hq rescue relocated master-hook.sh wiring from settings.json into
# settings.local.json and left empty event arrays. Deleting the local hooks
# key then disabled every hook. This suite pins the healer that undoes that.
#
# Explicitly wired into .github/workflows/pr-checks.yml.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/restore-hook-settings.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   [$1]"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]: $2"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required for this suite"; exit 0; }

make_broken() {
  local dir="$1"
  mkdir -p "$dir/.claude" "$dir/core/scripts"
  cp "$ROOT/core/scripts/hook-lib.sh" "$dir/core/scripts/hook-lib.sh"
  cat > "$dir/.claude/settings.json" <<'JSON'
{
  "model": "opus",
  "permissions": {"defaultMode": "auto", "deny": ["EnterWorktree"]},
  "env": {"PATH": "/machine/bin:/usr/bin", "MAX_THINKING_TOKENS": "31999"},
  "hooks": {
    "SessionStart": [],
    "PreToolUse": [],
    "PostToolUse": [],
    "PreCompact": [],
    "Stop": [],
    "UserPromptSubmit": [],
    "Notification": [],
    "SubagentStop": [],
    "SessionEnd": []
  }
}
JSON
  cat > "$dir/.claude/settings.local.json" <<'JSON'
{
  "permissions": {"allow": ["Bash(git:*)"]},
  "env": {"HQ_FOO": "1"},
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/master-hook.sh\" SessionStart", "timeout": 300}]}],
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/master-hook.sh\" PreToolUse", "timeout": 300}]},
      {"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/detect-secrets.sh\"", "timeout": 5}]}
    ]
  }
}
JSON
}

has_master() {
  jq -e --arg e "$2" '
    [.hooks[$e][]?.hooks[]?
      | select(.type == "command"
               and (.command | type == "string")
               and (.command | contains("master-hook.sh"))
               and (.command | endswith($e)))] | length == 1
  ' "$1/.claude/settings.json" >/dev/null
}

for ENGINE in jq node; do
  if [ "$ENGINE" = node ] && ! command -v node >/dev/null 2>&1; then
    echo "skip [node engine: node not installed]"; continue
  fi
  TMP="$(mktemp -d)"

  T="$TMP/broken"; make_broken "$T"
  OUT="$(HQ_HOOK_ENGINE=$ENGINE bash "$SCRIPT" "$T")"
  if printf '%s' "$OUT" | grep -q "restored canonical master-hook.sh" \
     && printf '%s' "$OUT" | grep -q "removed hooks key"; then
    ok "$ENGINE: reports restore + local hooks removal"
  else
    fail "$ENGINE: reports restore + local hooks removal" "$OUT"
  fi

  if has_master "$T" SessionStart && has_master "$T" PreToolUse; then
    ok "$ENGINE: settings.json has SessionStart + PreToolUse master-hook"
  else
    fail "$ENGINE: settings.json has SessionStart + PreToolUse master-hook" "$(jq -c '.hooks' "$T/.claude/settings.json")"
  fi

  EMPTY=0
  for e in PostToolUse PreCompact Stop UserPromptSubmit Notification SubagentStop SessionEnd; do
    has_master "$T" "$e" || EMPTY=1
  done
  [ "$EMPTY" -eq 0 ] && ok "$ENGINE: all nine events have master-hook" \
    || fail "$ENGINE: all nine events have master-hook" "$(jq -c '.hooks | keys' "$T/.claude/settings.json")"

  [ "$(jq -r '.env.PATH' "$T/.claude/settings.json")" = "/machine/bin:/usr/bin" ] \
    && ok "$ENGINE: machine PATH preserved" \
    || fail "$ENGINE: machine PATH preserved" "$(jq -c '.env' "$T/.claude/settings.json")"
  [ "$(jq -r '.permissions.defaultMode' "$T/.claude/settings.json")" = "auto" ] \
    && ok "$ENGINE: defaultMode preserved (not rewritten)" \
    || fail "$ENGINE: defaultMode preserved (not rewritten)" "$(jq -c '.permissions' "$T/.claude/settings.json")"
  [ "$(jq -c '.permissions.deny' "$T/.claude/settings.json")" = '["EnterWorktree"]' ] \
    && ok "$ENGINE: other permissions preserved" \
    || fail "$ENGINE: other permissions preserved" "$(jq -c '.permissions' "$T/.claude/settings.json")"

  if jq -e 'has("hooks") | not' "$T/.claude/settings.local.json" >/dev/null \
     && [ "$(jq -r '.env.HQ_FOO' "$T/.claude/settings.local.json")" = "1" ] \
     && [ "$(jq -c '.permissions.allow' "$T/.claude/settings.local.json")" = '["Bash(git:*)"]' ]; then
    ok "$ENGINE: local hooks removed, permissions and env kept"
  else
    fail "$ENGINE: local hooks removed, permissions and env kept" "$(cat "$T/.claude/settings.local.json")"
  fi

  BK_JSON="$(find "$T/workspace/.hq-update-check/settings-backups" -name settings.json 2>/dev/null | head -1)"
  BK_LOCAL="$(find "$T/workspace/.hq-update-check/settings-backups" -name settings.local.json 2>/dev/null | head -1)"
  if [ -n "$BK_JSON" ] && [ -n "$BK_LOCAL" ]; then
    ok "$ENGINE: backups written"
  else
    fail "$ENGINE: backups written" "$(find "$T/workspace" -type f 2>/dev/null | tr '\n' ' ')"
  fi

  # Idempotent on a healed tree.
  OUT2="$(HQ_HOOK_ENGINE=$ENGINE bash "$SCRIPT" "$T")"
  if [ -z "$OUT2" ]; then
    ok "$ENGINE: healed tree is a silent no-op"
  else
    fail "$ENGINE: healed tree is a silent no-op" "$OUT2"
  fi

  # Missing settings.json is a silent no-op (caller still runs rescue).
  M="$TMP/missing"; mkdir -p "$M/.claude" "$M/core/scripts"
  cp "$ROOT/core/scripts/hook-lib.sh" "$M/core/scripts/hook-lib.sh"
  OUT3="$(HQ_HOOK_ENGINE=$ENGINE bash "$SCRIPT" "$M")"
  RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT3" ]; then
    ok "$ENGINE: missing settings.json is a silent no-op"
  else
    fail "$ENGINE: missing settings.json is a silent no-op" "rc=$RC out=$OUT3"
  fi

  rm -rf "$TMP"
done

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
