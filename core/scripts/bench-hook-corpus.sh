#!/bin/bash
# bench-hook-corpus.sh — HQ hook latency and context benchmark over a prompt corpus.
# Sibling of bench-hooks.sh (per-registration profiler for one synthetic tool call):
# this one measures whole-event cost and what context actually reaches the model.
#
# Replays SessionStart, one UserPromptSubmit per corpus prompt, and one Bash
# PostToolUse per corpus command through .claude/hooks/master-hook.sh, each
# under a fresh session id, and records per item:
#   wall seconds, injected bytes, policy lines, HARD policy ids, which
#   expected routing hints appeared, which unwanted blocks appeared.
#
# Usage:
#   bench-hook-corpus.sh run   [--corpus <json>] [--out <report.json>] [--runtime claude]
#   bench-hook-corpus.sh compare <baseline.json> <candidate.json>
#
# compare exits non-zero when any prompt loses an expected hint it had at
# baseline, gains an unwanted block, or loses a HARD policy whose trigger
# still matches (approximated as: HARD id present at baseline, absent now,
# and the prompt text is unchanged).
#
# Runtime deps: bash, jq, node (report assembly), perl (millisecond clock).
# No python (see core/scripts/tests/hooks-no-python.test.sh).
set -uo pipefail

HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
cd "$HQ_ROOT" || exit 1
export CLAUDE_PROJECT_DIR="$HQ_ROOT" HQ_ROOT

for dep in jq node perl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "bench-hook-corpus: $dep is required" >&2; exit 2; }
done

MODE="${1:-run}"; shift || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORPUS="$SCRIPT_DIR/bench-hook-corpus-default.json"
OUT=""
RUNTIME="claude"

if [ "$MODE" = "compare" ]; then
  [ $# -ge 2 ] || { echo "usage: bench-hook-corpus.sh compare <baseline.json> <candidate.json>" >&2; exit 2; }
  node - "$1" "$2" <<'JS'
const fs = require('fs');
const [a, b] = process.argv.slice(2).map(p => JSON.parse(fs.readFileSync(p, 'utf8')));
const byId = r => Object.fromEntries(r.items.map(x => [x.id, x]));
const A = byId(a), B = byId(b);
const fail = [];
const pad = (s, n) => String(s).padEnd(n);
const num = (v, w, d = 2) => Number(v).toFixed(d).padStart(w);
console.log(`${pad('item', 28)} ${'secs'.padStart(14)} ${'bytes'.padStart(16)} ${'policies'.padStart(12)}  notes`);
for (const [k, x] of Object.entries(A)) {
  const y = B[k];
  if (!y) { fail.push(`${k}: missing in candidate`); continue; }
  const notes = [];
  const lost = (x.hints_hit || []).filter(h => !(y.hints_hit || []).includes(h));
  if (lost.length) { fail.push(`${k}: lost routing hints ${JSON.stringify(lost)}`); notes.push('HINT LOST'); }
  const gained = (y.unwanted_hit || []).filter(u => !(x.unwanted_hit || []).includes(u));
  if (gained.length) { fail.push(`${k}: gained unwanted blocks ${JSON.stringify(gained)}`); notes.push('UNWANTED'); }
  const lostHard = (x.hard_ids || []).filter(h => !(y.hard_ids || []).includes(h));
  if (lostHard.length && x.text === y.text) { fail.push(`${k}: lost HARD policies ${JSON.stringify(lostHard)}`); notes.push('HARD LOST'); }
  console.log(`${pad(k, 28)} ${num(x.secs, 6)}->${num(y.secs, 6)} ${String(x.bytes).padStart(7)}->${String(y.bytes).padStart(7)} ${String(x.policy_lines).padStart(5)}->${String(y.policy_lines).padStart(5)}  ${notes.join(' ')}`);
}
console.log(`\ntotal secs ${a.totals.secs.toFixed(2)} -> ${b.totals.secs.toFixed(2)}   total bytes ${a.totals.bytes} -> ${b.totals.bytes}`);
if (fail.length) { console.log('\nREGRESSIONS:'); fail.forEach(f => console.log(' -', f)); process.exit(1); }
console.log('\nno regressions');
JS
  exit $?
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --corpus) CORPUS="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --runtime) RUNTIME="$2"; shift 2;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac
done
[ -f "$CORPUS" ] || { echo "bench-hook-corpus: corpus not found: $CORPUS" >&2; exit 2; }
[ -n "$OUT" ] || OUT="$HQ_ROOT/workspace/reports/bench-hook-corpus/$(date -u +%Y%m%dT%H%M%SZ)-$RUNTIME.json"
mkdir -p "$(dirname "$OUT")"
[ "$RUNTIME" = "claude" ] || { echo "runtime $RUNTIME not implemented yet (HP-11)" >&2; exit 2; }

TMP="$(mktemp -d -t bench-hook-corpus.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }

run_event() { # $1 event, $2 payload json, $3 outfile -> prints secs
  local s e
  s=$(now_ms)
  printf '%s' "$2" | env BASH_ENV=/dev/null bash .claude/hooks/master-hook.sh "$1" > "$3" 2>/dev/null
  e=$(now_ms)
  perl -e 'printf "%.3f\n", ($ARGV[1]-$ARGV[0])/1000' "$s" "$e"
}

SID_BASE="bench-$(date +%s)"

# SessionStart
SID="$SID_BASE-start"
PAYLOAD=$(jq -cn --arg sid "$SID" --arg cwd "$HQ_ROOT" '{session_id:$sid,hook_event_name:"SessionStart",source:"startup",cwd:$cwd}')
SECS=$(run_event SessionStart "$PAYLOAD" "$TMP/start.out")
printf 'session-start\t%s\n' "$SECS" > "$TMP/start.meta"

# Prompts
: > "$TMP/prompts.meta"
jq -r '.prompts[] | [.id, .prompt] | @tsv' "$CORPUS" | while IFS=$'\t' read -r pid prompt; do
  SID="$SID_BASE-$pid"
  PAYLOAD=$(jq -cn --arg sid "$SID" --arg p "$prompt" --arg cwd "$HQ_ROOT" '{session_id:$sid,hook_event_name:"UserPromptSubmit",prompt:$p,cwd:$cwd}')
  SECS=$(run_event UserPromptSubmit "$PAYLOAD" "$TMP/$pid.out")
  printf '%s\t%s\n' "$pid" "$SECS" >> "$TMP/prompts.meta"
done

# Commands (Bash PostToolUse)
: > "$TMP/commands.meta"
jq -r '.commands[] | [.id, .command] | @tsv' "$CORPUS" | while IFS=$'\t' read -r cid cmd; do
  SID="$SID_BASE-$cid"
  PAYLOAD=$(jq -cn --arg sid "$SID" --arg c "$cmd" --arg cwd "$HQ_ROOT" '{session_id:$sid,hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:"x"},cwd:$cwd}')
  SECS=$(run_event PostToolUse "$PAYLOAD" "$TMP/$cid.out")
  printf '%s\t%s\n' "$cid" "$SECS" >> "$TMP/commands.meta"
done

node - "$CORPUS" "$TMP" "$OUT" "$RUNTIME" <<'JS'
const fs = require('fs'), path = require('path');
const [corpusPath, tmp, out, runtime] = process.argv.slice(2);
const corpus = JSON.parse(fs.readFileSync(corpusPath, 'utf8'));
const readMeta = f => {
  const p = path.join(tmp, f);
  if (!fs.existsSync(p)) return {};
  return Object.fromEntries(fs.readFileSync(p, 'utf8').split('\n').filter(Boolean).map(l => { const [k, v] = l.split('\t'); return [k, Number(v)]; }));
};
function analyze(file, hints = [], unwanted = []) {
  const p = path.join(tmp, file);
  let s = fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '';
  // PostToolUse hooks answer with a JSON envelope; unwrap additionalContext.
  if (s.trimStart().startsWith('{')) {
    s = s.split('\n').map(line => {
      try { const o = JSON.parse(line); return (o.hookSpecificOutput && o.hookSpecificOutput.additionalContext) || o.additionalContext || ''; }
      catch { return line; }
    }).join('\n');
  }
  const lines = [...s.matchAll(/^> Policy `([^`]+)`(.*)$/gm)];
  const hard = [...new Set(lines.filter(m => /HARD/.test(m[2])).map(m => m[1]))].sort();
  const low = s.toLowerCase();
  const blocks = [...new Set([...s.matchAll(/^<([a-z][a-z0-9-]*)>/gm)].map(m => m[1]))].sort();
  return {
    bytes: Buffer.byteLength(s), policy_lines: lines.length, hard_ids: hard, blocks,
    hints_hit: hints.filter(h => low.includes(h.toLowerCase())),
    hints_missed: hints.filter(h => !low.includes(h.toLowerCase())),
    unwanted_hit: unwanted.filter(u => low.includes(`<${u}`)),
  };
}
const items = [];
const start = readMeta('start.meta');
items.push({ ...analyze('start.out'), id: 'session-start', event: 'SessionStart', secs: start['session-start'] || 0 });
const pm = readMeta('prompts.meta');
for (const p of corpus.prompts || []) {
  items.push({ ...analyze(`${p.id}.out`, p.expect_hints || [], p.expect_no_blocks || []), id: p.id, event: 'UserPromptSubmit', secs: pm[p.id] || 0, text: p.prompt, kind: p.kind });
}
const cm = readMeta('commands.meta');
for (const c of corpus.commands || []) {
  items.push({ ...analyze(`${c.id}.out`), id: c.id, event: 'PostToolUse', secs: cm[c.id] || 0, text: c.command });
}
const totals = {
  secs: Math.round(items.reduce((a, i) => a + i.secs, 0) * 100) / 100,
  bytes: items.reduce((a, i) => a + i.bytes, 0),
  policy_lines: items.reduce((a, i) => a + i.policy_lines, 0),
};
const rep = { version: 1, runtime, created: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'), hq_root: process.cwd(), corpus: path.relative(process.cwd(), corpusPath), items, totals };
fs.writeFileSync(out, JSON.stringify(rep, null, 2) + '\n');
const pad = (s, n) => String(s).padEnd(n);
console.log(`${pad('item', 28)} ${pad('event', 16)} ${'secs'.padStart(6)} ${'bytes'.padStart(7)} ${'pol'.padStart(4)}  hints hit/missed · unwanted`);
for (const i of items) {
  console.log(`${pad(i.id, 28)} ${pad(i.event, 16)} ${i.secs.toFixed(2).padStart(6)} ${String(i.bytes).padStart(7)} ${String(i.policy_lines).padStart(4)}  ${(i.hints_hit || []).join(',') || '-'} / ${(i.hints_missed || []).join(',') || '-'} · ${(i.unwanted_hit || []).join(',') || '-'}`);
}
console.log(`\nTOTAL secs ${totals.secs}  bytes ${totals.bytes}  policy lines ${totals.policy_lines}\nreport: ${out}`);
JS
