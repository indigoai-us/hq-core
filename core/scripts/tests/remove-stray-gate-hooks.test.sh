#!/usr/bin/env bash
# remove-stray-gate-hooks.test.sh — regression for the matcher-less hook-gate
# registrations written by hq-cli 5.99.0–5.117.2 `hq doctor --fix`.
#
# Asserts, under both hook-lib engines (jq and node):
#   - exact-shape strays are removed from settings.json and settings.local.json
#   - permissions, hand-written hooks, and near-miss entries are preserved
#   - a backup of each rewritten file is written
#   - a legacy tree without master-hook.sh is left untouched
#   - a clean tree is a silent no-op
#
# Explicitly wired into .github/workflows/pr-checks.yml (tests here are not
# auto-discovered).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/remove-stray-gate-hooks.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   [$1]"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]: $2"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required for this suite"; exit 0; }

stray() {
  printf '{"hooks":[{"type":"command","command":"bash \\"$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh\\" %s \\"$CLAUDE_PROJECT_DIR/.claude/hooks/%s.sh\\"","timeout":5}]}' "$1" "$1"
}

make_tree() {
  local dir="$1" master="$2"
  mkdir -p "$dir/.claude" "$dir/core/scripts"
  cp "$ROOT/core/scripts/hook-lib.sh" "$dir/core/scripts/hook-lib.sh"
  if [ "$master" = "yes" ]; then
    printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash \\"$CLAUDE_PROJECT_DIR/.claude/hooks/master-hook.sh\\" PreToolUse","timeout":300}]},%s]}}\n' "$(stray detect-secrets)" > "$dir/.claude/settings.json"
  else
    printf '{"hooks":{"PreToolUse":[%s]}}\n' "$(stray detect-secrets)" > "$dir/.claude/settings.json"
  fi
  # settings.local.json: permissions, 2 strays (incl. a .yaml twin), one real
  # hook with a matcher, and three near-misses that must survive.
  cat > "$dir/.claude/settings.local.json" <<JSON
{
  "permissions": {"deny": ["Read(~/.ssh/**)"]},
  "hooks": {
    "PreToolUse": [
      $(stray block-hq-glob),
      $(stray block-hq-glob.yaml),
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash mine.sh", "timeout": 5}]},
      {"matcher": "Glob", "hooks": [{"type": "command", "command": "bash \"\$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh\" block-hq-glob \"\$CLAUDE_PROJECT_DIR/.claude/hooks/block-hq-glob.sh\"", "timeout": 5}]},
      {"hooks": [{"type": "command", "command": "bash \"\$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh\" a \"\$CLAUDE_PROJECT_DIR/.claude/hooks/b.sh\"", "timeout": 5}]},
      {"hooks": [{"type": "command", "command": "bash \"\$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh\" x \"\$CLAUDE_PROJECT_DIR/.claude/hooks/x.sh\"", "timeout": 30}]}
    ]
  }
}
JSON
}

for ENGINE in jq node; do
  if [ "$ENGINE" = node ] && ! command -v node >/dev/null 2>&1; then
    echo "skip [node engine: node not installed]"; continue
  fi
  TMP="$(mktemp -d)"

  # --- master-hook tree: strays removed, everything else kept ---
  T="$TMP/master"; make_tree "$T" yes
  OUT="$(HQ_HOOK_ENGINE=$ENGINE bash "$SCRIPT" "$T")"
  L="$T/.claude/settings.local.json"; S="$T/.claude/settings.json"

  if printf '%s' "$OUT" | grep -q "removed 2 stray.*settings.local.json" \
     && printf '%s' "$OUT" | grep -q "removed 1 stray.*settings.json"; then
    ok "$ENGINE: reports removals per file"
  else
    fail "$ENGINE: reports removals per file" "$OUT"
  fi
  [ "$(jq '.hooks.PreToolUse | length' "$L")" = "4" ] && ok "$ENGINE: local keeps 4 non-stray entries" \
    || fail "$ENGINE: local keeps 4 non-stray entries" "$(jq -c '.hooks' "$L")"
  [ "$(jq -c '.permissions' "$L")" = '{"deny":["Read(~/.ssh/**)"]}' ] && ok "$ENGINE: permissions preserved" \
    || fail "$ENGINE: permissions preserved" "$(jq -c '.permissions' "$L")"
  if jq -e '[.hooks.PreToolUse[] | select(.matcher == null and .hooks[0].timeout == 5 and (.hooks[0].command | test("block-hq-glob")))] | length == 0' "$L" >/dev/null; then
    ok "$ENGINE: block-hq-glob strays gone"
  else
    fail "$ENGINE: block-hq-glob strays gone" "$(jq -c '.hooks' "$L")"
  fi
  [ "$(jq '.hooks.PreToolUse | length' "$S")" = "1" ] && grep -q master-hook "$S" && ok "$ENGINE: settings.json keeps master-hook only" \
    || fail "$ENGINE: settings.json keeps master-hook only" "$(cat "$S")"
  BK="$(ls -d "$T"/workspace/.hq-update-check/settings-backups/*/ 2>/dev/null | head -1)"
  if [ -n "$BK" ] && [ "$(jq '.hooks.PreToolUse | length' "$BK/settings.local.json")" = "6" ]; then
    ok "$ENGINE: original backed up"
  else
    fail "$ENGINE: original backed up" "backup dir: ${BK:-none}"
  fi
  OUT2="$(HQ_HOOK_ENGINE=$ENGINE bash "$SCRIPT" "$T")"
  [ -z "$OUT2" ] && ok "$ENGINE: second run is a silent no-op" || fail "$ENGINE: second run is a silent no-op" "$OUT2"

  # --- legacy tree (no master-hook): untouched ---
  T="$TMP/legacy"; make_tree "$T" no
  BEFORE="$(cat "$T/.claude/settings.local.json" "$T/.claude/settings.json")"
  OUT3="$(HQ_HOOK_ENGINE=$ENGINE bash "$SCRIPT" "$T")"
  AFTER="$(cat "$T/.claude/settings.local.json" "$T/.claude/settings.json")"
  [ -z "$OUT3" ] && [ "$BEFORE" = "$AFTER" ] && ok "$ENGINE: legacy tree untouched" \
    || fail "$ENGINE: legacy tree untouched" "$OUT3"

  rm -rf "$TMP"
done

echo "remove-stray-gate-hooks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
