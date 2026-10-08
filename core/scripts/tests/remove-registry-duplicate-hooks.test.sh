#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${HP16_CLEANUP_SCRIPT:-$ROOT/core/scripts/remove-stray-gate-hooks.sh}"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "ok   [$1]"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL [$1]: $2"; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_fixture() {
  local dir="$1"
  mkdir -p "$dir/.claude/hooks" "$dir/core/scripts" "$dir/workspace"
  cp "$ROOT/core/scripts/hook-lib.sh" "$dir/core/scripts/hook-lib.sh"
  cat > "$dir/.claude/hooks/hook-registry.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"","hooks":[{"id":"registry-a","script":".claude/hooks/registry-a.sh"},{"id":"hq-monitor-session-hook","script":".claude/hooks/hq-monitor-session-hook.sh"}]}],"PostToolUse":[{"matcher":"Bash","hooks":[{"id":"registry-b","script":".claude/hooks/registry-b.sh"}]}]}}
JSON
  cat > "$dir/.claude/settings.json" <<JSON
{"hooks":{"PreToolUse":[{"matcher":"","hooks":[{"type":"command","command":"bash \"\$CLAUDE_PROJECT_DIR/.claude/hooks/master-hook.sh\" PreToolUse","timeout":300}]}]}}
JSON
  cat > "$dir/.claude/settings.local.json" <<JSON
{
  "env": {"KEEP_ME": "yes"},
  "permissions": {"allow": ["Bash(git status:*)"]},
  "hooks": {
    "PreToolUse": [
      {"hooks":[{"type":"command","timeout":5,"command":"bash \"\$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh\" registry-a \"\$CLAUDE_PROJECT_DIR/.claude/hooks/registry-a.sh\""}]},
      {"matcher":"Bash","hooks":[{"type":"command","timeout":19,"command":"bash \"\$CLAUDE_PROJECT_DIR/.claude/hooks/registry-a.sh\""}]},
      {"matcher":"Read","hooks":[{"type":"command","timeout":22,"command":"bash \$CLAUDE_PROJECT_DIR/.claude/hooks/registry-a.sh"}]},
      {"matcher":"Write","hooks":[{"type":"command","timeout":23,"command":"bash \"$dir/.claude/hooks/registry-a.sh\""}]},
      {"matcher":"Edit","hooks":[{"type":"command","timeout":5,"command":"bash \"\$CLAUDE_PROJECT_DIR/.claude/hooks/custom-user-hook.sh\""}]}
    ],
    "Stop": [
      {"matcher":"Bash","hooks":[{"type":"command","timeout":30,"command":"bash \"\$CLAUDE_PROJECT_DIR/.claude/hooks/hq-monitor-session-hook.sh\" wait"}]}
    ],
    "PostToolUse": [
      {"matcher":"Bash","hooks":[{"type":"command","timeout":47,"command":"bash .claude/hooks/registry-b.sh"}]}
    ]
  }
}
JSON
}

for engine in jq node; do
  command -v "$engine" >/dev/null 2>&1 || { echo "skip [$engine unavailable]"; continue; }
  dir="$TMP/$engine"
  make_fixture "$dir"
  HQ_HOOK_ENGINE="$engine" bash "$SCRIPT" "$dir"
  local_file="$dir/.claude/settings.local.json"
  jq -e '.hooks.PreToolUse as $p | (($p | length) == 1) and ($p[0].hooks[0].command | contains("custom-user-hook.sh"))' "$local_file" >/dev/null \
    && ok "$engine: registry registrations removed and user hook kept" \
    || bad "$engine: registry registrations removed and user hook kept" "$(jq -c '.hooks' "$local_file")"
  jq -e '[.hooks // {} | .. | objects | .command? | select(type == "string") | select(contains("registry-a.sh") or contains("registry-b.sh"))] | length == 0' "$local_file" >/dev/null \
    && ok "$engine: all registry scripts removed across events and timeouts" \
    || bad "$engine: all registry scripts removed across events and timeouts" "$(jq -c '.hooks' "$local_file")"
  jq -e '.hooks.Stop[0].hooks[0].command | contains("hq-monitor-session-hook.sh") and endswith(" wait")' "$local_file" >/dev/null \
    && ok "$engine: intentional Stop waiter survives a registry hook in another event" \
    || bad "$engine: intentional Stop waiter survives a registry hook in another event" "$(jq -c '.hooks.Stop' "$local_file")"
  jq -e '.env.KEEP_ME == "yes" and .permissions.allow == ["Bash(git status:*)"]' "$local_file" >/dev/null \
    && ok "$engine: env and permissions preserved" || bad "$engine: env and permissions preserved" "$(jq -c '{env,permissions}' "$local_file")"
  cp "$local_file" "$TMP/$engine.once"
  HQ_HOOK_ENGINE="$engine" bash "$SCRIPT" "$dir" >/dev/null
  cmp -s "$TMP/$engine.once" "$local_file" && ok "$engine: second run is byte-identical" \
    || bad "$engine: second run is byte-identical" "file changed on second run"
done

echo "remove-registry-duplicate-hooks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
