#!/usr/bin/env bash
# token-usage-report.sh — Daily effective-token totals + top burners from Claude Code session JSONLs.
# Usage:
#   core/scripts/token-usage-report.sh                # last 7 days, table
#   core/scripts/token-usage-report.sh --last 14      # last 14 days
#   core/scripts/token-usage-report.sh --since 2026-05-01
#   core/scripts/token-usage-report.sh --json         # machine-readable
#
# Effective tokens weighting (matches weekly rate-limit volume):
#   input + 5×output + 1.25×cache_creation + 0.1×cache_read

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [[ -n "${CLAUDE_PROJECTS_DIR:-}" ]]; then
  PROJECT_DIR="$CLAUDE_PROJECTS_DIR"
else
  PROJECT_SLUG="$(python3 - "$HQ_ROOT" <<'PY'
import sys
print(sys.argv[1].rstrip("/").replace("/", "-"))
PY
)"
  PROJECT_DIR="$HOME/.claude/projects/$PROJECT_SLUG"
fi
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

# --- Compare-windows mode (US-011) ---
# Format: --before YYYY-MM-DD:YYYY-MM-DD --after YYYY-MM-DD:YYYY-MM-DD
if [ -n "$COMPARE_BEFORE" ] && [ -n "$COMPARE_AFTER" ]; then
  python3 - "$PROJECT_DIR" "$COMPARE_BEFORE" "$COMPARE_AFTER" "$MIN_HOURS" "$JSON_MODE" <<'PY'
import json, os, sys, glob, datetime, statistics
proj, before, after, min_hours, json_mode = sys.argv[1:6]
min_hours = float(min_hours); json_mode = int(json_mode) == 1
def parse_range(s):
    a,b = s.split(":")
    return datetime.date.fromisoformat(a), datetime.date.fromisoformat(b)
b_start, b_end = parse_range(before)
a_start, a_end = parse_range(after)

def collect(window_start, window_end):
    rows = []
    for f in sorted(glob.glob(os.path.join(proj, "*.jsonl"))):
        cr = 0
        first_ts = last_ts = None
        sid = os.path.basename(f).replace(".jsonl","")
        try:
            with open(f) as fh:
                for line in fh:
                    try: rec = json.loads(line)
                    except: continue
                    u = (rec.get("message") or {}).get("usage") or {}
                    cr += u.get("cache_read_input_tokens",0) or 0
                    ts = rec.get("timestamp")
                    if ts:
                        if not first_ts: first_ts = ts
                        last_ts = ts
        except: continue
        if not first_ts or not last_ts: continue
        try:
            ft = datetime.datetime.fromisoformat(first_ts.replace("Z","+00:00"))
            lt = datetime.datetime.fromisoformat(last_ts.replace("Z","+00:00"))
        except: continue
        d = ft.date()
        if d < window_start or d > window_end: continue
        hours = max((lt-ft).total_seconds()/3600, 0.01)
        if hours < min_hours: continue
        rows.append({"sid": sid[:8], "hours": round(hours,1), "cr": cr,
                     "cr_per_hour": int(cr/hours)})
    return rows

b_rows = collect(b_start, b_end)
a_rows = collect(a_start, a_end)

def median(rows):
    if not rows: return 0
    return int(statistics.median(r["cr_per_hour"] for r in rows))

b_med, a_med = median(b_rows), median(a_rows)
delta_pct = ((b_med - a_med) / b_med * 100) if b_med else 0

if json_mode:
    print(json.dumps({
        "before": {"window": before, "sessions": len(b_rows), "median_cr_per_hour": b_med, "rows": b_rows},
        "after":  {"window": after,  "sessions": len(a_rows), "median_cr_per_hour": a_med, "rows": a_rows},
        "delta_pct": round(delta_pct, 1),
    }, indent=2))
else:
    print(f"\nCache_read/hour comparison (min {min_hours}h session duration)")
    print(f"\n  BEFORE  {before}  — {len(b_rows)} sessions")
    for r in b_rows: print(f"    {r['sid']}  {r['hours']:>5.1f}h  cr_per_hour={r['cr_per_hour']:>12,}")
    print(f"    median: {b_med:,}/h")
    print(f"\n  AFTER   {after}   — {len(a_rows)} sessions")
    for r in a_rows: print(f"    {r['sid']}  {r['hours']:>5.1f}h  cr_per_hour={r['cr_per_hour']:>12,}")
    print(f"    median: {a_med:,}/h")
    print(f"\n  Δ:  {delta_pct:+.1f}%  ({'IMPROVED' if delta_pct > 0 else 'WORSE' if delta_pct < 0 else 'unchanged'})")
PY
  exit 0
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Project dir not found: $PROJECT_DIR" >&2
  exit 1
fi

python3 - "$PROJECT_DIR" "$LAST_DAYS" "$SINCE" "$JSON_MODE" <<'PY'
import json, os, sys, glob, datetime, collections

project_dir, last_days_s, since_s, json_mode_s = sys.argv[1:5]
last_days = int(last_days_s)
json_mode = int(json_mode_s) == 1

today = datetime.date.today()
if since_s:
    cutoff = datetime.date.fromisoformat(since_s)
else:
    cutoff = today - datetime.timedelta(days=last_days - 1)

day_totals = collections.defaultdict(lambda: {"sessions": set(), "inp": 0, "out": 0, "cc": 0, "cr": 0})
session_totals = {}

def sess_id(p):
    return os.path.basename(p).replace(".jsonl", "")

# Parent sessions only (top-level *.jsonl)
for f in sorted(glob.glob(os.path.join(project_dir, "*.jsonl"))):
    mt = datetime.date.fromtimestamp(os.path.getmtime(f))
    if mt < cutoff:
        continue
    inp = out = cc = cr = 0
    first_ts = last_ts = None
    first_user = ""
    sub_count = 0
    sid = sess_id(f)
    try:
        with open(f) as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                u = (rec.get("message") or {}).get("usage") or {}
                inp += u.get("input_tokens", 0) or 0
                out += u.get("output_tokens", 0) or 0
                cc += u.get("cache_creation_input_tokens", 0) or 0
                cr += u.get("cache_read_input_tokens", 0) or 0
                ts = rec.get("timestamp")
                if ts:
                    if not first_ts:
                        first_ts = ts
                    last_ts = ts
                if not first_user and rec.get("type") == "user":
                    c = (rec.get("message") or {}).get("content")
                    if isinstance(c, str):
                        first_user = c[:120]
                    elif isinstance(c, list) and c:
                        first_user = (c[0].get("text") or "")[:120]
    except Exception:
        continue
    sub_dir = os.path.join(project_dir, sid, "subagents")
    if os.path.isdir(sub_dir):
        sub_count = len([x for x in os.listdir(sub_dir) if x.endswith(".jsonl")])

    eff = inp + 5 * out + 1.25 * cc + 0.1 * cr
    day = (first_ts or last_ts or "")[:10]
    if not day:
        day = mt.isoformat()
    if datetime.date.fromisoformat(day) < cutoff:
        continue
    day_totals[day]["sessions"].add(sid)
    day_totals[day]["inp"] += inp
    day_totals[day]["out"] += out
    day_totals[day]["cc"] += cc
    day_totals[day]["cr"] += cr
    session_totals[sid] = {
        "day": day, "inp": inp, "out": out, "cc": cc, "cr": cr,
        "eff": int(eff), "subagents": sub_count, "first_user": first_user.replace("\n", " "),
    }

if json_mode:
    days_out = []
    for d in sorted(day_totals):
        v = day_totals[d]
        eff = v["inp"] + 5 * v["out"] + 1.25 * v["cc"] + 0.1 * v["cr"]
        days_out.append({
            "date": d, "sessions": len(v["sessions"]),
            "input": v["inp"], "output": v["out"],
            "cache_create": v["cc"], "cache_read": v["cr"],
            "effective": int(eff),
        })
    most_recent_day = max(day_totals) if day_totals else None
    if most_recent_day:
        top3 = sorted(
            (s for s in session_totals.values() if s["day"] == most_recent_day),
            key=lambda s: -s["eff"],
        )[:3]
    else:
        top3 = []
    print(json.dumps({"days": days_out, "top_sessions_recent_day": top3}, indent=2))
else:
    # Pretty table
    print(f"\nToken usage (last {len(day_totals)} day(s), cutoff {cutoff})")
    print(f"  Effective = input + 5×output + 1.25×cache_create + 0.1×cache_read\n")
    print(f"  {'date':12} {'sessions':>8} {'output':>12} {'cache_read':>14} {'effective':>14}")
    print(f"  {'-'*12:12} {'-'*8:>8} {'-'*12:>12} {'-'*14:>14} {'-'*14:>14}")
    total_eff = 0
    for d in sorted(day_totals):
        v = day_totals[d]
        eff = v["inp"] + 5 * v["out"] + 1.25 * v["cc"] + 0.1 * v["cr"]
        total_eff += int(eff)
        print(f"  {d:12} {len(v['sessions']):>8} {v['out']:>12,} {v['cr']:>14,} {int(eff):>14,}")
    print(f"\n  total effective: {total_eff:,}")

    most_recent_day = max(day_totals) if day_totals else None
    if most_recent_day:
        top3 = sorted(
            (s for s in session_totals.items() if s[1]["day"] == most_recent_day),
            key=lambda kv: -kv[1]["eff"],
        )[:3]
        if top3:
            print(f"\nTop sessions on {most_recent_day}:")
            for sid, s in top3:
                prompt = s["first_user"][:80]
                print(f"  {sid[:8]}  eff={s['eff']:>11,}  subagents={s['subagents']:>3}  {prompt}")
    print()
PY
