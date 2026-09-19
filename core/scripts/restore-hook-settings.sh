#!/bin/bash
# hq-core: public
# restore-hook-settings.sh — put release hook wiring back in settings.json.
#
# `hq rescue` three-way-merges .claude/settings.json and relocates "drift"
# into .claude/settings.local.json. When the pre-rescue hook objects are not
# byte-identical to the floor (timeout, extra doctor registrations, key
# order), that relocate:
#   1. treats the shipped master-hook.sh lines as user deletions and writes
#      empty event arrays into settings.json, and
#   2. copies those lines (plus any stray hook-gate entries) into
#      settings.local.json.
# Deleting the local hooks key then silently disables every hook.
# (feedback 2282 / update-hq v15.0.117 → v15.0.137)
#
# This healer:
#   - writes the nine canonical master-hook.sh registrations into
#     settings.json (other keys, including env.PATH, are preserved)
#   - deletes the hooks key from settings.local.json (permissions/env stay)
# Idempotent. python-free. Always exits 0 unless a rewrite could not be saved.
#
# Usage: restore-hook-settings.sh [HQ_ROOT]

HQ_ROOT="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
CLAUDE_DIR="$HQ_ROOT/.claude"
BASE="$CLAUDE_DIR/settings.json"
LOCAL="$CLAUDE_DIR/settings.local.json"

[ -f "$BASE" ] || exit 0

if [ -f "$HQ_ROOT/core/scripts/hook-lib.sh" ]; then
  . "$HQ_ROOT/core/scripts/hook-lib.sh" 2>/dev/null
else
  HQ_LIB_JQ="$(command -v jq 2>/dev/null || true)"
  HQ_LIB_NODE="$(command -v node 2>/dev/null || true)"
fi

EVENTS='["PreToolUse","PostToolUse","PreCompact","Stop","SessionStart","UserPromptSubmit","Notification","SubagentStop","SessionEnd"]'

JQ_CANON='
def canonical_hooks:
  reduce $events[] as $e ({};
    .[$e] = [{hooks:[{
      type: "command",
      command: ("bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/master-hook.sh\" " + $e),
      timeout: 300
    }]}]);
def restore:
  .hooks = canonical_hooks;
'

NODE_PROG='
const fs = require("fs");
const [file, mode] = process.argv.slice(1);
const EVENTS = ["PreToolUse","PostToolUse","PreCompact","Stop","SessionStart","UserPromptSubmit","Notification","SubagentStop","SessionEnd"];
const canonicalHooks = () => {
  const h = {};
  for (const e of EVENTS) {
    h[e] = [{hooks:[{
      type: "command",
      command: "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/master-hook.sh\" " + e,
      timeout: 300
    }]}];
  }
  return h;
};
let d; try { d = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { process.exit(1); }
if (!d || typeof d !== "object" || Array.isArray(d)) process.exit(1);
if (mode === "local") {
  if (!Object.prototype.hasOwnProperty.call(d, "hooks")) { process.stdout.write("unchanged"); process.exit(0); }
  delete d.hooks;
  process.stdout.write(JSON.stringify(d, null, 2) + "\n");
  process.exit(0);
}
const before = JSON.stringify(d);
d.hooks = canonicalHooks();
if (JSON.stringify(d) === before) { process.stdout.write("unchanged"); process.exit(0); }
process.stdout.write(JSON.stringify(d, null, 2) + "\n");
'

rewrite_base() {
  if [ -n "${HQ_LIB_JQ:-}" ] && [ "${HQ_HOOK_ENGINE:-}" != "node" ]; then
    "$HQ_LIB_JQ" -r --argjson events "$EVENTS" "$JQ_CANON"'
      restore as $next
      | if . == $next then "unchanged" else $next end
    ' "$BASE" 2>/dev/null
  elif [ -n "${HQ_LIB_NODE:-}" ]; then
    "$HQ_LIB_NODE" -e "$NODE_PROG" "$BASE" base 2>/dev/null
  fi
}

rewrite_local() {
  if [ -n "${HQ_LIB_JQ:-}" ] && [ "${HQ_HOOK_ENGINE:-}" != "node" ]; then
    "$HQ_LIB_JQ" -r '
      if has("hooks") then del(.hooks) else "unchanged" end
    ' "$LOCAL" 2>/dev/null
  elif [ -n "${HQ_LIB_NODE:-}" ]; then
    "$HQ_LIB_NODE" -e "$NODE_PROG" "$LOCAL" local 2>/dev/null
  fi
}

write_atomic() {
  local dest="$1" body="$2"
  local tmp="$dest.hq-restore-tmp.$$"
  if printf '%s\n' "$body" > "$tmp" 2>/dev/null && mv "$tmp" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

CHANGED=0
STAMP="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo now)"
BACKUP_DIR="$HQ_ROOT/workspace/.hq-update-check/settings-backups/$STAMP"

BASE_OUT="$(rewrite_base)"
[ -n "$BASE_OUT" ] || { echo "restore-hook-settings: could not parse .claude/settings.json" >&2; exit 1; }
if [ "$BASE_OUT" != "unchanged" ]; then
  mkdir -p "$BACKUP_DIR" 2>/dev/null || true
  cp -p "$BASE" "$BACKUP_DIR/settings.json" 2>/dev/null || true
  if write_atomic "$BASE" "$BASE_OUT"; then
    echo "restored canonical master-hook.sh registrations in .claude/settings.json"
    CHANGED=1
  else
    echo "restore-hook-settings: could not write .claude/settings.json" >&2
    exit 1
  fi
fi

if [ -f "$LOCAL" ]; then
  LOCAL_OUT="$(rewrite_local)"
  [ -n "$LOCAL_OUT" ] || { echo "restore-hook-settings: could not parse .claude/settings.local.json" >&2; exit 1; }
  if [ "$LOCAL_OUT" != "unchanged" ]; then
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    cp -p "$LOCAL" "$BACKUP_DIR/settings.local.json" 2>/dev/null || true
    if write_atomic "$LOCAL" "$LOCAL_OUT"; then
      echo "removed hooks key from .claude/settings.local.json (permissions and env preserved)"
      CHANGED=1
    else
      echo "restore-hook-settings: could not write .claude/settings.local.json" >&2
      exit 1
    fi
  fi
fi

[ "$CHANGED" -eq 1 ] || true
exit 0
