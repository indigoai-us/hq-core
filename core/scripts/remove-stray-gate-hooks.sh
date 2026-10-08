#!/bin/bash
# Remove duplicate per-hook registrations that master-hook.sh already runs.
# Match by resolved registry script path; preserve user hooks and other settings.
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

REGISTRY="$CLAUDE_DIR/hooks/hook-registry.json"
[ -f "$REGISTRY" ] || REGISTRY=/dev/null

# Shell tokenization is intentionally limited to whitespace and single/double
# quoted tokens. Hook commands are simple command lines; no command is eval'd.
JQ_PROG='
def stray:
  type == "object"
  and (has("matcher") | not)
  and (keys == ["hooks"])
  and (.hooks | type == "array" and length == 1)
  and (.hooks[0] | type == "object" and .type == "command" and .timeout == 5
       and (.command | type == "string")
       and ((.command | capture("^bash \\\"\\$CLAUDE_PROJECT_DIR/\\.claude/hooks/hook-gate\\.sh\\\" (?<a>[A-Za-z0-9._-]+) \\\"\\$CLAUDE_PROJECT_DIR/\\.claude/hooks/(?<b>[A-Za-z0-9._-]+)\\.sh\\\"$") | .a == .b) // false));
def normpath:
  . as $p | ($p | startswith("/")) as $abs
  | ($p | split("/") | reduce .[] as $part ([];
      if $part == "" or $part == "." then . elif $part == ".." then .[:-1] else . + [$part] end) | join("/")) as $joined
  | if $abs then "/" + $joined else $joined end;
def script_paths($event_registry; $root):
  [$event_registry // [] | .. | objects | .script? | select(type == "string")
   | sub("^\\./"; "") as $s | ([$s, ($root + "/" + $s)][]) | normpath] | unique;
def command_tokens:
  [scan("\\\"[^\\\"]*\\\"|\u0027[^\u0027]*\u0027|[^[:space:]]+")
   | gsub("^\\\"|\\\"$"; "") | gsub("^\u0027|\u0027$"; "")];
def resolved_token($root):
  if startswith("${CLAUDE_PROJECT_DIR}/") then sub("^\\$\\{CLAUDE_PROJECT_DIR\\}"; $root)
  elif startswith("$CLAUDE_PROJECT_DIR/") then sub("^\\$CLAUDE_PROJECT_DIR"; $root)
  else . end | normpath;
def duplicate_hook($hook; $event_registry; $root):
  ($hook.command | select(type == "string") | command_tokens | map(resolved_token($root))) as $tokens
  | any($tokens[]; . as $token | script_paths($event_registry; $root) | index($token) != null);
def remove_dupes($registry; $root):
  if type != "object" or (.hooks | type) != "object" then .
  else .hooks |= with_entries(.key as $event | if (.value | type) != "array" then . else
    .value |= map(if type != "object" then . elif (stray) then empty else
      if (.hooks | type) == "array" then .hooks |= map(select((duplicate_hook(.; $registry.hooks[$event]; $root)) | not)) else . end
      | if (.hooks | type) == "array" and (.hooks | length) == 0 then empty else . end
    end) end)
    | if (.hooks | length) == 0 then del(.hooks) else . end
  end;
def count_dupes($registry; $root):
  [ (.hooks // {} | if type == "object" then to_entries[] else empty end) as $event_entry
    | $event_entry.value[]?
    | if (stray) then 1
      elif (.hooks | type) == "array" then [.hooks[] | select(duplicate_hook(.; $registry.hooks[$event_entry.key]; $root))] | length
      else 0 end ] | add // 0;
'

NODE_PROG='
const fs = require("fs");
const path = require("path");
const [file, mode, root, registryFile] = process.argv.slice(1);
const tokens = (s) => s.match(/"[^"]*"|\u0027[^\u0027]*\u0027|\S+/g) || [];
const oldStray = (e) => {
  if (!e || typeof e !== "object" || Array.isArray(e) || "matcher" in e) return false;
  const keys = Object.keys(e);
  if (keys.length !== 1 || keys[0] !== "hooks" || !Array.isArray(e.hooks) || e.hooks.length !== 1) return false;
  const h = e.hooks[0];
  if (!h || h.type !== "command" || h.timeout !== 5 || typeof h.command !== "string") return false;
  const t = tokens(h.command).map((v) => v.replace(/^"|"$/g, "").replace(/^\u0027|\u0027$/g, ""));
  return t.length === 4 && t[0] === "bash" && t[1] === "$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh"
    && /^[A-Za-z0-9._-]+$/.test(t[2])
    && t[3] === `$CLAUDE_PROJECT_DIR/.claude/hooks/${t[2]}.sh`;
};
const norm = (p) => path.posix.normalize(p.replace(/^\.\//, ""));
let registry = {};
try { registry = JSON.parse(fs.readFileSync(registryFile, "utf8")); } catch (_) { /* optional registry */ }
let d;
try { d = JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) { if (mode === "count") process.stdout.write("0"); process.exit(0); }
const walk = (v, scripts) => {
  if (Array.isArray(v)) return v.forEach((child) => walk(child, scripts));
  if (!v || typeof v !== "object") return;
  if (typeof v.script === "string") {
    const s = norm(v.script);
    scripts.push(s, norm(path.posix.join(root, s)));
  }
  Object.values(v).forEach((child) => walk(child, scripts));
};
const scriptsFor = (event) => {
  const scripts = [];
  walk((registry.hooks || {})[event] || [], scripts);
  return new Set(scripts);
};
const duplicate = (event, e) => {
  const scriptSet = scriptsFor(event);
  return Array.isArray(e && e.hooks) && e.hooks.some((h) => {
  if (!h || typeof h.command !== "string") return false;
  return tokens(h.command).some((raw) => {
    let p = raw.replace(/^"|"$/g, "").replace(/^\u0027|\u0027$/g, "");
    p = p.replace(/^\$\{CLAUDE_PROJECT_DIR\}/, root).replace(/^\$CLAUDE_PROJECT_DIR/, root);
    p = norm(p);
    return scriptSet.has(p);
  });
  });
};
const count = (obj) => Object.entries(obj.hooks || {}).reduce((n, [event, entries]) => n + (Array.isArray(entries) ? entries.reduce((m, e) => m + (oldStray(e) ? 1 : (Array.isArray(e && e.hooks) ? e.hooks.filter((h) => duplicate(event, {...e, hooks:[h]})).length : 0)), 0) : 0), 0);
if (mode === "count") { process.stdout.write(String(count(d))); process.exit(0); }
if (d && typeof d === "object" && !Array.isArray(d) && d.hooks && typeof d.hooks === "object" && !Array.isArray(d.hooks)) {
  for (const [event, entries] of Object.entries(d.hooks)) {
    if (!Array.isArray(entries)) continue;
    d.hooks[event] = entries.flatMap((e) => {
      if (oldStray(e)) return [];
      if (!duplicate(event, e)) return [e];
      const scriptSet = scriptsFor(event);
      const hooks = e.hooks.filter((h) => {
        if (!h || typeof h.command !== "string") return true;
        return !tokens(h.command).some((raw) => {
          let p = raw.replace(/^"|"$/g, "").replace(/^\u0027|\u0027$/g, "");
          p = p.replace(/^\$\{CLAUDE_PROJECT_DIR\}/, root).replace(/^\$CLAUDE_PROJECT_DIR/, root);
          return scriptSet.has(norm(p));
        });
      });
      return hooks.length ? [{...e, hooks}] : [];
    });
  }
  if (Object.keys(d.hooks).length === 0) delete d.hooks;
}
process.stdout.write(JSON.stringify(d, null, 2) + "\n");
'

count_stray() {
  if [ -n "${HQ_LIB_JQ:-}" ]; then
    "$HQ_LIB_JQ" -r --arg root "$HQ_ROOT" --slurpfile registry "$REGISTRY" "$JQ_PROG"' count_dupes($registry[0] // {}; $root)' "$1" || echo 0
  elif [ -n "${HQ_LIB_NODE:-}" ]; then
    "$HQ_LIB_NODE" -e "$NODE_PROG" "$1" count "$HQ_ROOT" "$REGISTRY" || echo 0
  else echo 0
  fi
}
cleaned_json() {
  if [ -n "${HQ_LIB_JQ:-}" ]; then
    "$HQ_LIB_JQ" --arg root "$HQ_ROOT" --slurpfile registry "$REGISTRY" "$JQ_PROG"' remove_dupes($registry[0] // {}; $root)' "$1"
  elif [ -n "${HQ_LIB_NODE:-}" ]; then
    "$HQ_LIB_NODE" -e "$NODE_PROG" "$1" clean "$HQ_ROOT" "$REGISTRY" 2>/dev/null
  fi
}

STAMP="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo now)"
for FILE in "$BASE" "$CLAUDE_DIR/settings.local.json"; do
  [ -f "$FILE" ] || continue
  N="$(count_stray "$FILE" | tr -dc '0-9')"
  [ -n "$N" ] && [ "$N" -gt 0 ] 2>/dev/null || continue
  OUT="$(cleaned_json "$FILE")"
  [ -n "$OUT" ] || continue
  BACKUP_DIR="$HQ_ROOT/workspace/.hq-update-check/settings-backups/$STAMP"
  mkdir -p "$BACKUP_DIR" 2>/dev/null || continue
  cp -p "$FILE" "$BACKUP_DIR/$(basename "$FILE")" 2>/dev/null || continue
  TMP="$FILE.hq-stray-tmp.$$"
  if printf '%s\n' "$OUT" > "$TMP" 2>/dev/null && mv "$TMP" "$FILE" 2>/dev/null; then
    echo "removed $N stray/duplicate hook registration(s) from .claude/$(basename "$FILE") (backup: workspace/.hq-update-check/settings-backups/$STAMP/)"
  else rm -f "$TMP" 2>/dev/null; fi
done
exit 0
