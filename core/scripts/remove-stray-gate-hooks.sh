#!/bin/bash
# hq-core: public
# remove-stray-gate-hooks.sh — heal settings broken by an old `hq doctor --fix`.
#
# hq-cli v5.99.0 through v5.117.2 "re-registered" every hook script it thought
# was orphaned. On an HQ tree that routes hooks through master-hook.sh, every
# script looks orphaned, so doctor appended one matcher-less PreToolUse entry
# per script:
#
#   {"hooks":[{"type":"command","timeout":5,
#     "command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh\" <id> \"$CLAUDE_PROJECT_DIR/.claude/hooks/<id>.sh\""}]}
#
# With no matcher Claude Code runs every guard on every tool call, so
# block-hq-glob and protect-core block Bash, Skill, ToolSearch and Read. An HQ
# update then carries the entries into settings.local.json, where a release
# reset never clears them.
#
# Usage: remove-stray-gate-hooks.sh [HQ_ROOT]
#   Removes ONLY entries of that exact shape (no matcher, one hook, timeout 5,
#   same id in both positions) from .claude/settings.json and
#   .claude/settings.local.json. Everything else (permissions, hand-written
#   hooks) is preserved. Runs only when settings.json routes through
#   master-hook.sh. Each rewritten file is backed up first to
#   workspace/.hq-update-check/settings-backups/<timestamp>/.
#   Prints one line per file it cleaned. Always exits 0. python-free.

HQ_ROOT="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
CLAUDE_DIR="$HQ_ROOT/.claude"
BASE="$CLAUDE_DIR/settings.json"

[ -f "$BASE" ] || exit 0
grep -q 'master-hook\.sh' "$BASE" 2>/dev/null || exit 0

if [ -f "$HQ_ROOT/core/scripts/hook-lib.sh" ]; then
  . "$HQ_ROOT/core/scripts/hook-lib.sh" 2>/dev/null
else
  HQ_LIB_JQ="$(command -v jq 2>/dev/null || true)"
  HQ_LIB_NODE="$(command -v node 2>/dev/null || true)"
fi

# One regex for both engines: hook-gate.sh "<a>" ... hooks/<b>.sh, a == b.
JQ_DEF='
def stray:
  type == "object"
  and (has("matcher") | not)
  and (keys == ["hooks"])
  and (.hooks | type == "array" and length == 1)
  and (.hooks[0] | type == "object"
       and .type == "command" and .timeout == 5
       and (.command | type == "string")
       and ((.command
             | capture("^bash \"\\$CLAUDE_PROJECT_DIR/\\.claude/hooks/hook-gate\\.sh\" (?<a>[A-Za-z0-9._-]+) \"\\$CLAUDE_PROJECT_DIR/\\.claude/hooks/(?<b>[A-Za-z0-9._-]+)\\.sh\"$")
             | .a == .b) // false));
'

NODE_PROG='
const fs = require("fs");
const [file, mode] = process.argv.slice(1);
const RE = /^bash "\$CLAUDE_PROJECT_DIR\/\.claude\/hooks\/hook-gate\.sh" ([A-Za-z0-9._-]+) "\$CLAUDE_PROJECT_DIR\/\.claude\/hooks\/([A-Za-z0-9._-]+)\.sh"$/;
const stray = (e) => {
  if (!e || typeof e !== "object" || Array.isArray(e) || "matcher" in e) return false;
  const k = Object.keys(e); if (k.length !== 1 || k[0] !== "hooks") return false;
  if (!Array.isArray(e.hooks) || e.hooks.length !== 1) return false;
  const h = e.hooks[0];
  if (!h || h.type !== "command" || h.timeout !== 5 || typeof h.command !== "string") return false;
  const m = RE.exec(h.command); return !!m && m[1] === m[2];
};
let d; try { d = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { if (mode === "count") process.stdout.write("0"); process.exit(0); }
const hooks = d && typeof d === "object" && !Array.isArray(d) ? d.hooks : null;
let n = 0;
if (hooks && typeof hooks === "object" && !Array.isArray(hooks)) {
  const next = {};
  for (const [ev, arr] of Object.entries(hooks)) {
    if (!Array.isArray(arr)) { next[ev] = arr; continue; }
    const kept = arr.filter((e) => !stray(e)); n += arr.length - kept.length;
    if (kept.length > 0 || arr.length === 0) next[ev] = kept;
  }
  if (Object.keys(next).length) d.hooks = next; else delete d.hooks;
}
if (mode === "count") process.stdout.write(String(n));
else process.stdout.write(JSON.stringify(d, null, 2) + "\n");
'

count_stray() {
  if [ -n "${HQ_LIB_JQ:-}" ]; then
    "$HQ_LIB_JQ" -r "$JQ_DEF"'
      [ (.hooks // {}) | if type == "object" then .[] else empty end
        | if type == "array" then .[] else empty end | select(stray) ] | length
    ' "$1" 2>/dev/null || echo 0
  elif [ -n "${HQ_LIB_NODE:-}" ]; then
    "$HQ_LIB_NODE" -e "$NODE_PROG" "$1" count 2>/dev/null || echo 0
  else
    echo 0
  fi
}

cleaned_json() {
  if [ -n "${HQ_LIB_JQ:-}" ]; then
    "$HQ_LIB_JQ" "$JQ_DEF"'
      if (.hooks | type) == "object" then
        .hooks |= with_entries(
          if (.value | type) == "array" then
            (.value | length) as $n
            | .value |= map(select(stray | not))
            | select((.value | length) > 0 or $n == 0)
          else . end)
        | if (.hooks | length) == 0 then del(.hooks) else . end
      else . end
    ' "$1" 2>/dev/null
  elif [ -n "${HQ_LIB_NODE:-}" ]; then
    "$HQ_LIB_NODE" -e "$NODE_PROG" "$1" clean 2>/dev/null
  fi
}

STAMP="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo now)"
for FILE in "$BASE" "$CLAUDE_DIR/settings.local.json"; do
  [ -f "$FILE" ] || continue
  N="$(count_stray "$FILE" | tr -dc '0-9')"
  [ -n "$N" ] || continue
  [ "$N" -gt 0 ] 2>/dev/null || continue
  OUT="$(cleaned_json "$FILE")"
  [ -n "$OUT" ] || continue
  BACKUP_DIR="$HQ_ROOT/workspace/.hq-update-check/settings-backups/$STAMP"
  mkdir -p "$BACKUP_DIR" 2>/dev/null || continue
  cp -p "$FILE" "$BACKUP_DIR/$(basename "$FILE")" 2>/dev/null || continue
  TMP="$FILE.hq-stray-tmp.$$"
  if printf '%s\n' "$OUT" > "$TMP" 2>/dev/null && mv "$TMP" "$FILE" 2>/dev/null; then
    echo "removed $N stray hook-gate registration(s) from .claude/$(basename "$FILE") (backup: workspace/.hq-update-check/settings-backups/$STAMP/)"
  else
    rm -f "$TMP" 2>/dev/null
  fi
done
exit 0
