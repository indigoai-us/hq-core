#!/usr/bin/env bash
# token-usage-report.sh — Daily effective-token totals + top burners from Claude Code session JSONLs.
# Usage:
#   scripts/token-usage-report.sh                # last 7 days, table
#   scripts/token-usage-report.sh --last 14      # last 14 days
#   scripts/token-usage-report.sh --since 2026-05-01
#   scripts/token-usage-report.sh --json         # machine-readable
#
# Effective tokens weighting (matches weekly rate-limit volume):
#   input + 5×output + 1.25×cache_creation + 0.1×cache_read

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects/-Users-{your-name}-Documents-HQ}"
LAST_DAYS=7
SINCE=""
JSON_MODE=0
COMPARE_BEFORE=""
COMPARE_AFTER=""
MIN_HOURS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --last) LAST_DAYS="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    --compare-windows) shift ;;   # flag, presence triggers compare mode via --before/--after
    --before) COMPARE_BEFORE="$2"; shift 2 ;;
    --after)  COMPARE_AFTER="$2"; shift 2 ;;
    --min-hours) MIN_HOURS="$2"; shift 2 ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# //'
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

command -v node >/dev/null 2>&1 || { echo "token-usage-report: node is required" >&2; exit 1; }

# --- Compare-windows mode (US-011) ---
# Format: --before YYYY-MM-DD:YYYY-MM-DD --after YYYY-MM-DD:YYYY-MM-DD
if [ -n "$COMPARE_BEFORE" ] && [ -n "$COMPARE_AFTER" ]; then
  node - "$PROJECT_DIR" "$COMPARE_BEFORE" "$COMPARE_AFTER" "$MIN_HOURS" "$JSON_MODE" <<'JS'
const fs = require("fs");
const path = require("path");

const [proj, before, after, minHoursS, jsonModeS] = process.argv.slice(2);
const minHours = parseFloat(minHoursS);
const jsonMode = parseInt(jsonModeS, 10) === 1;

const parseRange = (s) => s.split(":").map((d) => new Date(d + "T00:00:00Z"));
const [bStart, bEnd] = parseRange(before);
const [aStart, aEnd] = parseRange(after);

const fmt = (n) => n.toLocaleString("en-US");
const listJsonl = () => {
  try { return fs.readdirSync(proj).filter((f) => f.endsWith(".jsonl")).sort(); } catch (e) { return []; }
};

function collect(windowStart, windowEnd) {
  const rows = [];
  for (const name of listJsonl()) {
    const f = path.join(proj, name);
    let cr = 0, firstTs = null, lastTs = null;
    const sid = name.replace(/\.jsonl$/, "");
    let content;
    try { content = fs.readFileSync(f, "utf8"); } catch (e) { continue; }
    for (const line of content.split(/\r?\n/)) {
      let rec;
      try { rec = JSON.parse(line); } catch (e) { continue; }
      const u = ((rec.message || {}).usage) || {};
      cr += u.cache_read_input_tokens || 0;
      const ts = rec.timestamp;
      if (ts) { if (!firstTs) firstTs = ts; lastTs = ts; }
    }
    if (!firstTs || !lastTs) continue;
    const ft = new Date(firstTs), lt = new Date(lastTs);
    if (isNaN(ft.getTime()) || isNaN(lt.getTime())) continue;
    const d = new Date(firstTs.slice(0, 10) + "T00:00:00Z");
    if (d < windowStart || d > windowEnd) continue;
    const hours = Math.max((lt - ft) / 3600000, 0.01);
    if (hours < minHours) continue;
    rows.push({ sid: sid.slice(0, 8), hours: Math.round(hours * 10) / 10, cr: cr,
      cr_per_hour: Math.trunc(cr / hours) });
  }
  return rows;
}

const bRows = collect(bStart, bEnd);
const aRows = collect(aStart, aEnd);

function median(rows) {
  if (!rows.length) return 0;
  const vals = rows.map((r) => r.cr_per_hour).sort((a, b) => a - b);
  const mid = Math.floor(vals.length / 2);
  return Math.trunc(vals.length % 2 ? vals[mid] : (vals[mid - 1] + vals[mid]) / 2);
}

const bMed = median(bRows), aMed = median(aRows);
const deltaPct = bMed ? ((bMed - aMed) / bMed) * 100 : 0;

if (jsonMode) {
  console.log(JSON.stringify({
    before: { window: before, sessions: bRows.length, median_cr_per_hour: bMed, rows: bRows },
    after: { window: after, sessions: aRows.length, median_cr_per_hour: aMed, rows: aRows },
    delta_pct: Math.round(deltaPct * 10) / 10,
  }, null, 2));
} else {
  console.log("\nCache_read/hour comparison (min " + minHours + "h session duration)");
  console.log("\n  BEFORE  " + before + "  — " + bRows.length + " sessions");
  for (const r of bRows) console.log("    " + r.sid + "  " + String(r.hours.toFixed(1)).padStart(5) + "h  cr_per_hour=" + fmt(r.cr_per_hour).padStart(12));
  console.log("    median: " + fmt(bMed) + "/h");
  console.log("\n  AFTER   " + after + "   — " + aRows.length + " sessions");
  for (const r of aRows) console.log("    " + r.sid + "  " + String(r.hours.toFixed(1)).padStart(5) + "h  cr_per_hour=" + fmt(r.cr_per_hour).padStart(12));
  console.log("    median: " + fmt(aMed) + "/h");
  const verdict = deltaPct > 0 ? "IMPROVED" : deltaPct < 0 ? "WORSE" : "unchanged";
  console.log("\n  Δ:  " + (deltaPct >= 0 ? "+" : "") + deltaPct.toFixed(1) + "%  (" + verdict + ")");
}
JS
  exit 0
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Project dir not found: $PROJECT_DIR" >&2
  exit 1
fi

node - "$PROJECT_DIR" "$LAST_DAYS" "$SINCE" "$JSON_MODE" <<'JS'
const fs = require("fs");
const path = require("path");

const [projectDir, lastDaysS, sinceS, jsonModeS] = process.argv.slice(2);
const lastDays = parseInt(lastDaysS, 10);
const jsonMode = parseInt(jsonModeS, 10) === 1;

const dayOf = (d) => d.toISOString().slice(0, 10);
const today = new Date();
let cutoff;
if (sinceS) cutoff = sinceS;
else {
  const c = new Date(today.getTime() - (lastDays - 1) * 86400000);
  cutoff = dayOf(c);
}

const fmt = (n) => n.toLocaleString("en-US");
const dayTotals = {};
const sessionTotals = {};

let names;
try { names = fs.readdirSync(projectDir).filter((f) => f.endsWith(".jsonl")).sort(); } catch (e) { names = []; }

// Parent sessions only (top-level *.jsonl)
for (const name of names) {
  const f = path.join(projectDir, name);
  let mtime;
  try { mtime = fs.statSync(f).mtime; } catch (e) { continue; }
  const mt = dayOf(mtime);
  if (mt < cutoff) continue;
  let inp = 0, out = 0, cc = 0, cr = 0;
  let firstTs = null, lastTs = null, firstUser = "";
  let subCount = 0;
  const sid = name.replace(/\.jsonl$/, "");
  let content;
  try { content = fs.readFileSync(f, "utf8"); } catch (e) { continue; }
  for (const line of content.split(/\r?\n/)) {
    let rec;
    try { rec = JSON.parse(line); } catch (e) { continue; }
    const u = ((rec.message || {}).usage) || {};
    inp += u.input_tokens || 0;
    out += u.output_tokens || 0;
    cc += u.cache_creation_input_tokens || 0;
    cr += u.cache_read_input_tokens || 0;
    const ts = rec.timestamp;
    if (ts) { if (!firstTs) firstTs = ts; lastTs = ts; }
    if (!firstUser && rec.type === "user") {
      const c = (rec.message || {}).content;
      if (typeof c === "string") firstUser = c.slice(0, 120);
      else if (Array.isArray(c) && c.length) firstUser = ((c[0] && c[0].text) || "").slice(0, 120);
    }
  }
  const subDir = path.join(projectDir, sid, "subagents");
  try { subCount = fs.readdirSync(subDir).filter((x) => x.endsWith(".jsonl")).length; } catch (e) {}

  const eff = inp + 5 * out + 1.25 * cc + 0.1 * cr;
  let day = (firstTs || lastTs || "").slice(0, 10);
  if (!day) day = mt;
  if (day < cutoff) continue;
  if (!dayTotals[day]) dayTotals[day] = { sessions: new Set(), inp: 0, out: 0, cc: 0, cr: 0 };
  dayTotals[day].sessions.add(sid);
  dayTotals[day].inp += inp;
  dayTotals[day].out += out;
  dayTotals[day].cc += cc;
  dayTotals[day].cr += cr;
  sessionTotals[sid] = {
    day: day, inp: inp, out: out, cc: cc, cr: cr,
    eff: Math.trunc(eff), subagents: subCount, first_user: firstUser.split("\n").join(" "),
  };
}

const sortedDays = Object.keys(dayTotals).sort();
if (jsonMode) {
  const daysOut = [];
  for (const d of sortedDays) {
    const v = dayTotals[d];
    const eff = v.inp + 5 * v.out + 1.25 * v.cc + 0.1 * v.cr;
    daysOut.push({
      date: d, sessions: v.sessions.size,
      input: v.inp, output: v.out,
      cache_create: v.cc, cache_read: v.cr,
      effective: Math.trunc(eff),
    });
  }
  const mostRecentDay = sortedDays.length ? sortedDays[sortedDays.length - 1] : null;
  let top3 = [];
  if (mostRecentDay) {
    top3 = Object.values(sessionTotals)
      .filter((s) => s.day === mostRecentDay)
      .sort((a, b) => b.eff - a.eff)
      .slice(0, 3);
  }
  console.log(JSON.stringify({ days: daysOut, top_sessions_recent_day: top3 }, null, 2));
} else {
  // Pretty table
  console.log("\nToken usage (last " + sortedDays.length + " day(s), cutoff " + cutoff + ")");
  console.log("  Effective = input + 5×output + 1.25×cache_create + 0.1×cache_read\n");
  console.log("  " + "date".padEnd(12) + " " + "sessions".padStart(8) + " " + "output".padStart(12) + " " + "cache_read".padStart(14) + " " + "effective".padStart(14));
  console.log("  " + "-".repeat(12) + " " + "-".repeat(8) + " " + "-".repeat(12) + " " + "-".repeat(14) + " " + "-".repeat(14));
  let totalEff = 0;
  for (const d of sortedDays) {
    const v = dayTotals[d];
    const eff = v.inp + 5 * v.out + 1.25 * v.cc + 0.1 * v.cr;
    totalEff += Math.trunc(eff);
    console.log("  " + d.padEnd(12) + " " + String(v.sessions.size).padStart(8) + " " + fmt(v.out).padStart(12) + " " + fmt(v.cr).padStart(14) + " " + fmt(Math.trunc(eff)).padStart(14));
  }
  console.log("\n  total effective: " + fmt(totalEff));

  const mostRecentDay = sortedDays.length ? sortedDays[sortedDays.length - 1] : null;
  if (mostRecentDay) {
    const top3 = Object.entries(sessionTotals)
      .filter(([, s]) => s.day === mostRecentDay)
      .sort((a, b) => b[1].eff - a[1].eff)
      .slice(0, 3);
    if (top3.length) {
      console.log("\nTop sessions on " + mostRecentDay + ":");
      for (const [sid, s] of top3) {
        const prompt = s.first_user.slice(0, 80);
        console.log("  " + sid.slice(0, 8) + "  eff=" + fmt(s.eff).padStart(11) + "  subagents=" + String(s.subagents).padStart(3) + "  " + prompt);
      }
    }
  }
  console.log("");
}
JS
