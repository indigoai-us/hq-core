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
#   bench-hook-corpus.sh replay <corpus.json> <report.json> <prompt-id>...
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
source "$SCRIPT_DIR/lib/bench-runtime.sh"
CORPUS="$SCRIPT_DIR/bench-hook-corpus-default.json"
OUT=""
RUNTIME="claude"

if [ "$MODE" = "compare" ]; then
  [ $# -ge 2 ] || { echo "usage: bench-hook-corpus.sh compare <baseline.json> <candidate.json>" >&2; exit 2; }
  node - "$1" "$2" <<'JS'
const fs = require('fs');
const [a, b] = process.argv.slice(2).map(p => JSON.parse(fs.readFileSync(p, 'utf8')));
if ((a.runtime || 'claude') !== (b.runtime || 'claude')) {
  console.error(`cannot compare different runtimes: ${a.runtime || 'claude'} vs ${b.runtime || 'claude'}`);
  process.exit(2);
}
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
  const xStatus = x.status || 'completed', yStatus = y.status || 'completed';
  if (['failed', 'timeout'].includes(xStatus) || ['failed', 'timeout'].includes(yStatus)) {
    fail.push(`${k}: execution status ${xStatus} -> ${yStatus}`);
    notes.push(yStatus === 'timeout' ? 'TIMEOUT' : 'EXECUTION FAILED');
  }
  if ((x.supported === false) !== (y.supported === false)) {
    fail.push(`${k}: support changed (${x.supported === false ? 'unsupported' : 'supported'} -> ${y.supported === false ? 'unsupported' : 'supported'})`);
    notes.push('SUPPORT CHANGED');
  }
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

REPLAY_CORPUS=""
REPLAY_OUT=""
REPLAY_IDS=()
if [ "$MODE" = "replay" ]; then
  REPLAY_CORPUS="${1:-}"
  REPLAY_OUT="${2:-}"
  [ $# -ge 2 ] && shift 2 || set --
  REPLAY_IDS=("$@")
else
  while [ $# -gt 0 ]; do
    case "$1" in
    --corpus) CORPUS="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --runtime) RUNTIME="$2"; shift 2;;
      *) echo "unknown arg $1" >&2; exit 2;;
    esac
  done
fi
[ -f "$CORPUS" ] || { echo "bench-hook-corpus: corpus not found: $CORPUS" >&2; exit 2; }
bench_runtime_valid "$RUNTIME" || { echo "bench-hook-corpus: unsupported runtime: $RUNTIME" >&2; exit 2; }
if [ "$RUNTIME" = "grok" ]; then
  echo "bench-hook-corpus: --runtime grok is unsupported: the adapter does not expose benchmark-visible output" >&2
  exit 2
fi
[ -n "$OUT" ] || OUT="$HQ_ROOT/workspace/reports/bench-hook-corpus/$(date -u +%Y%m%dT%H%M%SZ)-$RUNTIME.json"
mkdir -p "$(dirname "$OUT")"

TMP="$(mktemp -d -t bench-hook-corpus.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }

run_event() { # $1 event, $2 payload json, $3 outfile -> prints secs
  local event="$1" output="$3" error="$3.stderr" s e root="$HQ_ROOT" rc=0 runtime_home="${HOME:-/tmp}"
  if [ "$RUNTIME" = "hq-agent" ]; then
    root="$TMP/agent-root"
    runtime_home="$TMP/home"
    mkdir -p "$runtime_home"
    if [ ! -d "$root" ]; then bench_runtime_agent_root "$HQ_ROOT" "$root" || rc=125; fi
  fi
  local payload
  if [ "$rc" -eq 0 ]; then
    payload="$(bench_runtime_payload "$RUNTIME" "$event" "$root" "${SID:-bench-session}" "Bash" "${COMMAND_TEXT:-echo bench}" "${PROMPT_TEXT:-bench prompt}")" || rc=125
  fi
  s=$(now_ms)
  if [ "$rc" -eq 0 ]; then
    bench_runtime_dispatch "$RUNTIME" "$root" "$event" "$payload" "$output" "$error" "$runtime_home" "${BENCH_RUNTIME_TIMEOUT_SEC:-30}" || rc=$?
  fi
  e=$(now_ms)
  printf '%s\n' "$rc" > "$output.rc"
  perl -e 'printf "%.3f\n", ($ARGV[1]-$ARGV[0])/1000' "$s" "$e"
}

if [ "$MODE" = "replay" ]; then
  [ "$REPLAY_CORPUS" ] && [ "$REPLAY_OUT" ] && [ "${#REPLAY_IDS[@]}" -gt 0 ] || {
    echo "usage: bench-hook-corpus.sh replay <corpus.json> <report.json> <prompt-id>..." >&2
    exit 2
  }
  [ -f "$REPLAY_CORPUS" ] || { echo "bench-hook-corpus: corpus not found: $REPLAY_CORPUS" >&2; exit 2; }
  bench_runtime_valid "$RUNTIME" || { echo "bench-hook-corpus: unsupported runtime: $RUNTIME" >&2; exit 2; }
  [ "$RUNTIME" != "grok" ] || {
    echo "bench-hook-corpus: --runtime grok is unsupported: the adapter does not expose benchmark-visible output" >&2
    exit 2
  }
  seen_ids=" "
  for id in "${REPLAY_IDS[@]}"; do
    case "$id" in *[!A-Za-z0-9._-]*|'') echo "bench-hook-corpus: invalid prompt id: $id" >&2; exit 2;; esac
    case "$seen_ids" in *" $id "*) echo "bench-hook-corpus: duplicate prompt id: $id" >&2; exit 2;; esac
    seen_ids="$seen_ids$id "
    jq -e --arg id "$id" 'any(.prompts[]?; .id == $id)' "$REPLAY_CORPUS" >/dev/null || {
      echo "bench-hook-corpus: prompt id not found: $id" >&2; exit 2;
    }
  done
  mkdir -p "$(dirname "$REPLAY_OUT")"
  SID="bench-replay-$(date +%s)-$$"
  # Replayed payloads are intentional measurements, not duplicate dispatches.
  export HQ_HOOK_DEDUPE=0
  PROMPT_TEXT="session start"
  run_event SessionStart '' "$TMP/session-start.out" >/dev/null
  warmup_rc="$(cat "$TMP/session-start.out.rc")"
  [ "$warmup_rc" -eq 0 ] || { echo "bench-hook-corpus: SessionStart warm-up failed with exit $warmup_rc" >&2; exit 1; }
  for pass in first repeat; do
    for id in "${REPLAY_IDS[@]}"; do
      PROMPT_TEXT="$(jq -r --arg id "$id" '.prompts[] | select(.id == $id) | .prompt' "$REPLAY_CORPUS")"
      secs="$(run_event UserPromptSubmit '' "$TMP/$pass-$id.out")"
      printf '%s\n' "$secs" > "$TMP/$pass-$id.secs"
      printf '%s\n' "$(cat "$TMP/$pass-$id.out.rc")" > "$TMP/$pass-$id.rc"
    done
  done
  node - "$REPLAY_CORPUS" "$TMP" "$REPLAY_OUT" "$RUNTIME" "$SID" "$HQ_ROOT" "${REPLAY_IDS[@]}" <<'JS'
const fs = require('fs'), path = require('path');
const [corpusPath, tmp, out, runtime, sessionId, workspace, ...ids] = process.argv.slice(2);
const corpus = JSON.parse(fs.readFileSync(corpusPath, 'utf8'));
const additionalContext = value => {
  if (typeof value === 'string') return value;
  if (!value || typeof value !== 'object') return '';
  return (value.hookSpecificOutput && value.hookSpecificOutput.additionalContext) || value.additionalContext || '';
};
const visibleContext = text => {
  try { return additionalContext(JSON.parse(text)); }
  catch {
    const lines = text.split('\n').filter(Boolean);
    const parsed = [];
    for (const line of lines) {
      try { parsed.push(additionalContext(JSON.parse(line))); }
      catch { return text; }
    }
    return parsed.length ? parsed.join('\n') : text;
  }
};
const measure = (pass, id) => {
  const text = visibleContext(fs.readFileSync(path.join(tmp, `${pass}-${id}.out`), 'utf8'));
  return {
    bytes: Buffer.byteLength(text),
    wall_seconds: Number(fs.readFileSync(path.join(tmp, `${pass}-${id}.secs`), 'utf8').trim()),
    exit_code: Number(fs.readFileSync(path.join(tmp, `${pass}-${id}.rc`), 'utf8').trim()),
  };
};
const items = ids.map(id => ({
  id,
  event: 'UserPromptSubmit',
  session_id: sessionId,
  workspace,
  first_run: measure('first', id),
  repeat_run: measure('repeat', id),
}));
const totals = {
  first_run: { bytes: items.reduce((n, item) => n + item.first_run.bytes, 0), wall_seconds: Number(items.reduce((n, item) => n + item.first_run.wall_seconds, 0).toFixed(3)) },
  repeat_run: { bytes: items.reduce((n, item) => n + item.repeat_run.bytes, 0), wall_seconds: Number(items.reduce((n, item) => n + item.repeat_run.wall_seconds, 0).toFixed(3)) },
};
const report = { version: 1, mode: 'same-session-replay', runtime, created: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'), session_id: sessionId, workspace, corpus: path.relative(process.cwd(), corpusPath), items, totals };
fs.writeFileSync(out, JSON.stringify(report, null, 2) + '\n');
const pad = (s, n) => String(s).padEnd(n);
console.log(`${pad('event', 24)} ${'first bytes'.padStart(12)} ${'repeat bytes'.padStart(13)} ${'first wall s'.padStart(14)} ${'repeat wall s'.padStart(15)}`);
for (const item of items) console.log(`${pad(item.id, 24)} ${String(item.first_run.bytes).padStart(12)} ${String(item.repeat_run.bytes).padStart(13)} ${item.first_run.wall_seconds.toFixed(3).padStart(14)} ${item.repeat_run.wall_seconds.toFixed(3).padStart(15)}`);
console.log(`${pad('TOTAL', 24)} ${String(totals.first_run.bytes).padStart(12)} ${String(totals.repeat_run.bytes).padStart(13)} ${totals.first_run.wall_seconds.toFixed(3).padStart(14)} ${totals.repeat_run.wall_seconds.toFixed(3).padStart(15)}`);
console.log(`session ${sessionId}\nworkspace ${workspace}\nreport: ${out}`);
if (items.some(item => item.first_run.exit_code !== 0 || item.repeat_run.exit_code !== 0)) process.exitCode = 1;
JS
  exit $?
fi

SID_BASE="bench-$(date +%s)"

# SessionStart
SID="$SID_BASE-start"
PROMPT_TEXT="session start"
SECS=$(run_event SessionStart '' "$TMP/start.out")
printf 'session-start\t%s\n' "$SECS" > "$TMP/start.meta"

# Prompts
: > "$TMP/prompts.meta"
jq -r '.prompts[] | [.id, .prompt] | @tsv' "$CORPUS" | while IFS=$'\t' read -r pid prompt; do
  SID="$SID_BASE-$pid"
  PROMPT_TEXT="$prompt"
  SECS=$(run_event UserPromptSubmit '' "$TMP/$pid.out")
  printf '%s\t%s\n' "$pid" "$SECS" >> "$TMP/prompts.meta"
done

# Commands (Bash PostToolUse)
: > "$TMP/commands.meta"
jq -r '.commands[] | [.id, .command] | @tsv' "$CORPUS" | while IFS=$'\t' read -r cid cmd; do
  SID="$SID_BASE-$cid"
  if [ "$RUNTIME" = "hq-agent" ]; then
    : > "$TMP/$cid.out"
    printf '%s\t0\n' "$cid" >> "$TMP/commands.meta"
    continue
  fi
  COMMAND_TEXT="$cmd"
  SECS=$(run_event PostToolUse '' "$TMP/$cid.out")
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
const agentCommandUnsupported = runtime === 'hq-agent';
const eventStatus = id => {
  const rcPath = path.join(tmp, `${id}.out.rc`);
  const rc = fs.existsSync(rcPath) ? Number(fs.readFileSync(rcPath, 'utf8').trim()) : 1;
  return { status: rc === 142 ? 'timeout' : (rc === 125 ? 'failed' : 'completed'), exit_code: rc };
};
const start = readMeta('start.meta');
items.push({ ...analyze('start.out'), ...eventStatus('start'), id: 'session-start', event: 'SessionStart', secs: start['session-start'] || 0, supported: true });
const pm = readMeta('prompts.meta');
for (const p of corpus.prompts || []) {
  items.push({ ...analyze(`${p.id}.out`, p.expect_hints || [], p.expect_no_blocks || []), ...eventStatus(p.id), id: p.id, event: 'UserPromptSubmit', secs: pm[p.id] || 0, text: p.prompt, kind: p.kind, supported: true });
}
const cm = readMeta('commands.meta');
for (const c of corpus.commands || []) {
  const item = { ...analyze(`${c.id}.out`), ...(agentCommandUnsupported ? { status: 'unsupported' } : eventStatus(c.id)), id: c.id, event: 'PostToolUse', secs: cm[c.id] || 0, text: c.command, supported: !agentCommandUnsupported };
  if (agentCommandUnsupported) item.unsupported_reason = 'hq-agent-session.sh accepts session requests and has no PostToolUse entrypoint';
  items.push(item);
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
