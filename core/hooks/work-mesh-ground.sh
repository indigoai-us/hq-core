#!/usr/bin/env bash
# hq-core: public
# UserPromptSubmit: ground against the mesh and inject the live Board so
# sessions do not orient from local prd.json. Never genesis here. Fail-soft.
set -uo pipefail
[ "${HQ_WORK_MESH_DISABLED:-}" = "1" ] && exit 0
case ",${HQ_DISABLED_HOOKS:-}," in
  *,work-mesh-ground,*) exit 0 ;;
esac
STDIN_JSON="$(cat 2>/dev/null || echo '{}')"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
HQ_ROOT="${HQ_ROOT:-$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd)}"
HELPER="$HQ_ROOT/core/scripts/work-mesh-session.sh"
[ -x "$HELPER" ] || HELPER="$HQ_ROOT/core/scripts/work-mesh.sh"
[ -x "$HELPER" ] || exit 0
[ -f "$HQ_ROOT/core/scripts/hook-lib.sh" ] || exit 0
# shellcheck source=core/scripts/hook-lib.sh
. "$HQ_ROOT/core/scripts/hook-lib.sh"
command -v jq >/dev/null 2>&1 || exit 0

extract() {
  printf '%s' "$STDIN_JSON" | hq_json_get "$1"
}

PROMPT="$(extract prompt)"
EVENT="$(extract hook_event_name)"
[ -n "$EVENT" ] || EVENT="UserPromptSubmit"
[ "${#PROMPT}" -lt 12 ] && exit 0
case "$PROMPT" in
  /*) exit 0 ;;
esac

CO="$(bash "$HQ_ROOT/core/scripts/hq-session.sh" get company_slug 2>/dev/null || true)"
CO="$(printf '%s' "$CO" | tr -d '[:space:]"')"
PROJ="$(bash "$HQ_ROOT/core/scripts/hq-session.sh" get project 2>/dev/null || true)"
PROJ="$(printf '%s' "$PROJ" | tr -d '[:space:]"')"

if [ -z "$CO" ] && [ -x "$HQ_ROOT/core/scripts/resolve-company.sh" ]; then
  resolved="$("$HQ_ROOT/core/scripts/resolve-company.sh" --root "$HQ_ROOT" --prompt "$PROMPT" 2>/dev/null || true)"
  CO="$(printf '%s' "$resolved" | hq_json_get company)"
fi

# Unique existing companies/<manifest-slug>/projects/<name> match from the
# prompt. Disk folders that are not in the manifest are ignored.
if [ -z "$PROJ" ] || [ -z "$CO" ]; then
  infer_js=""
  IFS= read -r -d '' infer_js <<'JS' || true
const fs = require("fs");
const path = require("path");
const hq = process.argv[1] || "";
const prompt = (process.env.WM_GROUND_PROMPT || "").toLowerCase();
const needle = prompt.replace(/[^a-z0-9]+/g, "-");
let text = "";
try { text = fs.readFileSync(path.join(hq, "companies", "manifest.yaml"), "utf8"); } catch (e) { console.log("{}"); process.exit(0); }
const slugs = new Set();
let wrapped = false;
for (const raw of text.split("\n")) {
  if (/^companies:\s*$/.test(raw)) { wrapped = true; continue; }
  if (wrapped && /^\S/.test(raw)) wrapped = false;
  const m = wrapped ? raw.match(/^  ([a-z][a-z0-9_-]*):/) : raw.match(/^([a-z][a-z0-9_-]*):/);
  if (!m) continue;
  const slug = m[1];
  if (slug === "_template" || slug === "companies" || slug === "unaffiliated_repos") continue;
  slugs.add(slug);
}
const hits = [];
for (const co of slugs) {
  let names = [];
  try { names = fs.readdirSync(path.join(hq, "companies", co, "projects")); } catch (e) { continue; }
  for (const name of names) {
    if (!name || name.startsWith("_")) continue;
    const n = name.toLowerCase();
    const parts = n.split("-").filter((p) => p.length > 1);
    if (needle.includes(n) || (parts.length && parts.every((p) => needle.includes(p)))) {
      hits.push({ company: co, project: name });
    }
  }
}
if (hits.length === 1) console.log(JSON.stringify(hits[0]));
else console.log("{}");
JS
  inferred="$(WM_GROUND_PROMPT="$PROMPT" node -e "$infer_js" "$HQ_ROOT" 2>/dev/null || echo '{}')"
  [ -n "$CO" ] || CO="$(printf '%s' "$inferred" | hq_json_get company)"
  [ -n "$PROJ" ] || PROJ="$(printf '%s' "$inferred" | hq_json_get project)"
fi

[ -n "$CO" ] || exit 0

if [ -n "$PROJ" ]; then
  mesh_json="$(bash "$HELPER" ground --company "$CO" --project "$PROJ" --json 2>/dev/null || true)"
else
  mesh_json="$(bash "$HELPER" ground --company "$CO" --prompt "$PROMPT" --json 2>/dev/null || true)"
fi
[ -n "$mesh_json" ] || exit 0

skipped="$(printf '%s' "$mesh_json" | hq_json_get skipped)"
[ "$skipped" = "true" ] && exit 0

board="$(printf '%s' "$mesh_json" | jq -r --arg co "$CO" --arg proj "$PROJ" '
  "LIVE WORK MESH BOARD (task status source of truth)",
  ("Company: " + $co),
  (if $proj != "" then "Project: " + $proj elif .projectId then "Project: " + (.projectId|tostring) else empty end),
  (if (.stories|type)=="array" and (.stories|length)>0 then
      .stories[:12][] | "- \(.status // "queued") \(.id // "?") \(.title // "")"
    elif (.candidates|type)=="array" and (.candidates|length)>0 then
      (.candidates[:6][] | "- candidate \(.projectId // .name // "?")")
    else empty end),
  "Do not use local prd.json for Board columns (prd.passes is not status).",
  "Local prd is spec/acceptance fallback only when this Board block is absent."
' 2>/dev/null || true)"

case "$board" in
  *"LIVE WORK MESH BOARD"*) ;;
  *) exit 0 ;;
esac
# Need at least one story or candidate line.
printf '%s' "$board" | grep -q '^[-] ' || exit 0

# Durable snapshot for runtimes that cannot inject UserPromptSubmit context
# (Grok). Claude/Codex also get additionalContext below.
mkdir -p "$HQ_ROOT/.claude/state" 2>/dev/null || true
printf '%s\n' "$board" > "$HQ_ROOT/.claude/state/work-mesh-board" 2>/dev/null || true

jq -n --arg ctx "$board" --arg ev "$EVENT" '{
  hookSpecificOutput: {
    hookEventName: $ev,
    additionalContext: $ctx
  }
}' 2>/dev/null || true
exit 0
