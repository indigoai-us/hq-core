#!/usr/bin/env bash
# conduct-lane-status.sh — one JSON object per /conduct lane for the end-of-turn
# lane cards. Reads the session pool (conduct-pool.sh list) and each lane's run
# directory; never reads the agent transcript into the parent beyond the last
# meaningful line, so rendering cards costs almost no context.
#
# Usage:
#   bash core/scripts/conduct-lane-status.sh [--session-id <id>] [--all]
#
# Default prints only slots whose status is running. --all includes idle and
# recycled slots (the most recent finished lanes), for a wrap-up card.
#
# Output: a JSON array; each item:
#   worker, task, status, run_id, run_dir, started_at, elapsed_s,
#   last_line (last non-empty, non-JSON-noise line of agent-1.log, or the last
#              assistant text / tool call from the lane's live transcript; ≤160 chars),
#   inbox_pending (messages queued for the lane, not yet delivered),
#   exit (CONDUCT_EXIT value when finished, else null),
#   pr (last GitHub PR URL seen, else null),
#   transcript, last_activity_s, tool_calls_recent (only when read from the live transcript)
set -euo pipefail

ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SID=""
ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id) SID="${2:-}"; shift 2 ;;
    --all) ALL=1; shift ;;
    *) echo "conduct-lane-status: unknown option: $1" >&2; exit 1 ;;
  esac
done
[ -n "$SID" ] || SID="$(bash "$ROOT/core/scripts/hq-session.sh" current 2>/dev/null || true)"
[ -n "$SID" ] || { echo "[]"; exit 0; }

BASE="$ROOT/workspace/tmp/workflow-runner/$SID"
pool="$(bash "$ROOT/core/scripts/conduct-pool.sh" --session-id "$SID" list 2>/dev/null || echo '[]')"

export LANE_POOL_JSON="$pool" LANE_BASE="$BASE" LANE_SHOW_ALL="$ALL" HQ_ROOT_ABS="$ROOT"
node - <<'JS'
const fs = require("fs");
const os = require("os");
const path = require("path");

const base = process.env.LANE_BASE;
const showAll = process.env.LANE_SHOW_ALL === "1";
const root = process.env.HQ_ROOT_ABS;
const now = Math.floor(Date.now() / 1000);
let pool = [];
try { pool = JSON.parse(process.env.LANE_POOL_JSON || "[]"); } catch { pool = []; }
const prRe = /https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+/g;
const clip = (s) => (s.length > 160 ? s.slice(0, 157) + "…" : s);
const lastPr = (text) => { const m = text.match(prRe); return m ? m[m.length - 1] : null; };
const mtimeS = (p) => Math.floor(fs.statSync(p).mtimeMs / 1000);
function readTail(p, bytes) {
  try {
    const fd = fs.openSync(p, "r");
    const size = fs.fstatSync(fd).size;
    const start = Math.max(0, size - bytes);
    const buf = Buffer.alloc(size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    fs.closeSync(fd);
    return buf.toString("utf8");
  } catch { return ""; }
}
function readHead(p, bytes) {
  try {
    const fd = fs.openSync(p, "r");
    const buf = Buffer.alloc(bytes);
    const n = fs.readSync(fd, buf, 0, bytes, 0);
    fs.closeSync(fd);
    return buf.toString("utf8", 0, n);
  } catch { return ""; }
}

const out = [];
for (const slot of pool) {
  const status = slot.status || "";
  if (!showAll && status !== "running") continue;
  const runId = slot.subagent_id || "";
  const runDir = runId ? path.join(base, runId) : "";
  const item = {
    worker: (slot.worker_id || "").replace(/^conduct:/, ""),
    task: slot.last_task || "",
    status,
    run_id: runId,
    run_dir: runId ? `workspace/tmp/workflow-runner/${path.basename(base)}/${runId}` : null,
    started_at: null, elapsed_s: null, last_line: null,
    inbox_pending: 0, exit: null, pr: null,
  };
  if (runDir && fs.existsSync(runDir) && fs.statSync(runDir).isDirectory()) {
    const brief = path.join(runDir, "brief.md");
    if (fs.existsSync(brief)) {
      item.started_at = mtimeS(brief);
      item.elapsed_s = Math.max(0, now - item.started_at);
    }
    const laneLog = path.join(runDir, "lane.log");
    if (fs.existsSync(laneLog)) {
      const m = fs.readFileSync(laneLog, "utf8").match(/CONDUCT_EXIT=(\d+)/g);
      if (m) item.exit = parseInt(m[m.length - 1].split("=")[1], 10);
    }
    const alog = path.join(runDir, "agent-1.log");
    if (fs.existsSync(alog)) {
      const tail = readTail(alog, 65536);
      item.pr = lastPr(tail);
      const lines = tail.split("\n");
      for (let i = lines.length - 1; i >= 0; i--) {
        let s = lines[i].trim();
        if (!s || s.startsWith("{") || s.startsWith("[") || s.includes("cache_read_input_tokens")) continue;
        s = s.replace(/\x1b\[[0-9;]*m/g, "");
        item.last_line = clip(s);
        break;
      }
    }
    // While a claude lane runs, agent-1.log stays empty (claude -p buffers
    // until exit). The live signal is the lane's own Claude Code transcript,
    // which cites the run id in its first prompt. Claude Code keys project
    // transcripts by the HQ root path with every "/" turned into "-".
    if (item.last_line === null && runId) {
      const tdir = path.join(os.homedir(), ".claude", "projects", root.replace(/\//g, "-"));
      const parentSid = path.basename(base);
      const cands = [];
      let names = [];
      try { names = fs.readdirSync(tdir).filter((n) => n.endsWith(".jsonl")); } catch { names = []; }
      for (const n of names) {
        if (n.startsWith(parentSid)) continue;
        const p = path.join(tdir, n);
        let mt;
        try { mt = mtimeS(p); } catch { continue; }
        if (now - mt > 2 * 86400) continue;
        if (readHead(p, 65536).includes(runId)) cands.push([mt, p]);
      }
      if (cands.length) {
        cands.sort((a, b) => a[0] - b[0]);
        const [mt, tpath] = cands[cands.length - 1];
        item.transcript = path.basename(tpath);
        item.last_activity_s = Math.max(0, now - mt);
        const ttail = readTail(tpath, 200000);
        let tools = 0, last = null, lastText = null;
        for (const line of ttail.split("\n")) {
          let j;
          try { j = JSON.parse(line); } catch { continue; }
          if (j.type !== "assistant") continue;
          const content = (j.message && j.message.content) || [];
          for (const c of content) {
            if (!c || typeof c !== "object") continue;
            if (c.type === "tool_use") {
              tools++;
              const inp = c.input || {};
              const desc = inp.description || inp.command || inp.file_path || inp.pattern || "";
              last = `${c.name}: ${String(desc).slice(0, 120)}`;
            } else if (c.type === "text" && (c.text || "").trim()) {
              lastText = c.text.trim().split("\n")[0].slice(0, 160);
            }
          }
        }
        item.last_line = lastText || last;
        item.tool_calls_recent = tools;
        if (!item.pr) item.pr = lastPr(ttail);
      }
    }
    const pend = path.join(runDir, "inbox", "pending");
    try { item.inbox_pending = fs.readdirSync(pend).filter((n) => n.endsWith(".msg")).length; } catch { /* no inbox */ }
  }
  out.push(item);
}
process.stdout.write(JSON.stringify(out, null, 2) + "\n");
JS
