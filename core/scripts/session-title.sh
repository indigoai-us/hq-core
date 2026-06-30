#!/usr/bin/env bash
# session-title.sh — compute an HQ session-title string for the Claude Code
# sidebar ("Recents") / terminal tab title / `/resume` picker.
#
# Pure compute: reads existing session + orchestrator state and prints ONE
# title line to stdout. It does NOT emit hook JSON — the SessionStart /
# UserPromptSubmit wrapper (.claude/hooks/session-title.sh) wraps this output
# in the hookSpecificOutput.sessionTitle envelope.
#
# Title convention:  {status-emoji }{company} · {project} · {command}
#   - emoji is a STATUS flag only (▶️ running, ✅ recently completed); it is
#     omitted otherwise — the command word already conveys the mode.
#   - company  : slug from the active project path, or "hq-core" for builder
#                work, or the sole company on a single-company HQ; else dropped.
#   - project  : active project slug; dropped when there is no project.
#   - command  : active slash command / mode word (e.g. brainstorm, plan,
#                run-project), defaulting to "chat".
#
# Usage: session-title.sh --session-id <id> [--command <word>]
set -uo pipefail

HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"

SESSION_ID="default"
COMMAND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-default}"; shift 2 ;;
    --command)    COMMAND="${2:-}"; shift 2 ;;
    *)            shift ;;
  esac
done

HQ_ROOT="$HQ_ROOT" SESSION_ID="$SESSION_ID" CMD="$COMMAND" python3 - <<'PY'
import json, os, re, pathlib, datetime

hq = pathlib.Path(os.environ["HQ_ROOT"])
sid = os.environ.get("SESSION_ID", "default") or "default"
command = (os.environ.get("CMD", "") or "").strip().lstrip("/")

key = re.sub(r"[^A-Za-z0-9._-]", "_", sid) or "default"
state = hq / ".claude" / "state"

def first_line(p):
    try:
        for line in p.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line:
                return line
    except Exception:
        pass
    return ""

# --- resolve active project path (session-scoped, then global fallback) ---
proj_path = first_line(state / f"auto-session-project-{key}")
if not proj_path:
    proj_path = first_line(state / "active-session-project")

company = ""
project = ""
if proj_path:
    rel = proj_path
    try:
        rel = str(pathlib.Path(proj_path).resolve().relative_to(hq.resolve()))
    except Exception:
        rel = proj_path.replace(str(hq).rstrip("/") + "/", "")
    parts = [p for p in rel.strip("/").split("/") if p]
    if len(parts) >= 2 and parts[0] == "companies":
        company = parts[1]
        project = parts[-1]
    elif parts and parts[0] == "personal":
        company = ""          # personal scope → no company segment
        project = parts[-1]
    elif parts:
        project = parts[-1]

# --- company fallbacks when no project resolved ---
if not company and command == "hqwork":
    company = "hq-core"

if not company and not project:
    manifest = hq / "companies" / "manifest.yaml"
    slugs = []
    if manifest.exists():
        in_companies = False
        for line in manifest.read_text(encoding="utf-8", errors="ignore").splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if in_companies and re.match(r"^[^\s#]", line):
                break
            if re.match(r"^companies:\s*$", line):
                in_companies = True
                continue
            if in_companies:
                m = re.match(r"^  ([a-z][a-z0-9_-]*):\s*$", line)
                if m and m.group(1) != "_template":
                    slugs.append(m.group(1))
    if len(slugs) == 1:
        company = slugs[0]

# --- status emoji from the orchestrator ---
emoji = ""
orch = hq / "workspace" / "orchestrator" / "state.json"
if project and orch.exists():
    try:
        data = json.loads(orch.read_text(encoding="utf-8"))
        for p in data.get("projects", []):
            nm = p.get("name", "")
            prd = "/" + (p.get("prdPath", "") or "")
            if nm == project or ("/" + project + "/") in prd:
                st = p.get("state", "")
                if st == "IN_PROGRESS":
                    emoji = "▶️"
                elif st == "COMPLETED":
                    ts = p.get("updatedAt") or p.get("updated_at") or ""
                    try:
                        t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
                        now = datetime.datetime.now(datetime.timezone.utc)
                        if (now - t).total_seconds() < 86400:   # only recent completions
                            emoji = "✅"
                    except Exception:
                        pass
                break
    except Exception:
        pass

# --- compose ---
if not command:
    command = "chat"

core = [x for x in [project, command] if x]
full = ([company] + core) if company else core

def compose(parts):
    s = " · ".join(parts)
    return (emoji + " " + s) if emoji else s

MAX = 44
title = compose(full)
if len(title) > MAX:
    title = compose(core)          # drop company first (project implies it)
if len(title) > MAX:
    title = title[:MAX - 1].rstrip() + "…"

print(title)
PY
