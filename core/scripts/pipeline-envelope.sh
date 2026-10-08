#!/usr/bin/env bash
# pipeline-envelope.sh - validate the HQ phase envelope / phase handoff shape,
# and normalize raw engine replies into a single JSON object.
#
# Usage:
#   pipeline-envelope.sh validate [--kind envelope|handoff] <file|->
#   pipeline-envelope.sh normalize <file|->
#
# validate: exit 0 when valid; otherwise exit 1 and print each problem to
#   stderr as "missing field: <name>" or "wrong type: <name> (want <type>)".
#   Unparseable JSON, empty input, a missing file, or a non-object top level
#   always exit non-zero.
# normalize: extract one JSON object from a reply that may be wrapped in a
#   ```json fence or surrounded by prose; print it compactly to stdout.
#
# Shapes are documented in .claude/skills/_shared/lane-dispatch-protocol.md §8.
# Portable to bash 3.2; parsing is done by node.

set -u

usage() {
  echo "usage: pipeline-envelope.sh validate [--kind envelope|handoff] <file|->" >&2
  echo "       pipeline-envelope.sh normalize <file|->" >&2
  exit 2
}

command -v node >/dev/null 2>&1 || { echo "pipeline-envelope: node required" >&2; exit 2; }

[ $# -ge 1 ] || usage
cmd="$1"; shift
kind=""
case "$cmd" in
  validate)
    if [ "${1:-}" = "--kind" ]; then
      [ $# -ge 2 ] || usage
      kind="$2"; shift 2
      case "$kind" in envelope|handoff) ;; *) echo "pipeline-envelope: bad --kind: $kind" >&2; exit 2 ;; esac
    fi
    ;;
  normalize) ;;
  -h|--help) usage ;;
  *) usage ;;
esac
[ $# -eq 1 ] || usage
src="$1"

# node reads its program from a heredoc, so stdin must be spooled first.
if [ "$src" = "-" ]; then
  spool="$(mktemp "${TMPDIR:-/tmp}/pe-stdin.XXXXXX")" || exit 1
  trap 'rm -f "$spool"' EXIT
  cat > "$spool"
  src="$spool"
fi

if [ ! -f "$src" ]; then
  echo "pipeline-envelope: file not found: $src" >&2
  exit 1
fi

PE_CMD="$cmd" PE_KIND="$kind" PE_SRC="$src" node - <<'JS'
'use strict';
const fs = require('fs');
const cmd = process.env.PE_CMD; let kind = process.env.PE_KIND; const src = process.env.PE_SRC;
const err = (m) => process.stderr.write(m + '\n');
let text;
try {
  text = new TextDecoder('utf-8', { fatal: true }).decode(fs.readFileSync(src));
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  text = text.replace(/\r\n?/g, '\n');
} catch (e) {
  err('pipeline-envelope: cannot read input: ' + (e && e.message ? e.message : e)); process.exit(1);
}
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

// Python json.dumps default output: ", " and ": " separators.
function dumpStr(s, ascii) {
  let o = JSON.stringify(s);
  if (ascii) o = o.replace(/[\u0080-￿]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
  return o;
}
function dumpNum(n) {
  if (!Number.isFinite(n)) return n > 0 ? 'Infinity' : n < 0 ? '-Infinity' : 'NaN';
  if (Number.isInteger(n) && Math.abs(n) < 1e16) return String(n);
  let s = String(n);
  const m = /^(-?)(\d)(?:\.(\d+))?e([+-])(\d+)$/.exec(s);
  if (m) s = m[1] + m[2] + (m[3] ? '.' + m[3] : '') + 'e' + m[4] + m[5].padStart(2, '0');
  return s;
}
function dumps(v, ascii) {
  if (v === null) return 'null';
  if (v === true) return 'true';
  if (v === false) return 'false';
  if (typeof v === 'number') return dumpNum(v);
  if (typeof v === 'string') return dumpStr(v, ascii);
  if (Array.isArray(v)) return '[' + v.map((x) => dumps(x, ascii)).join(', ') + ']';
  return '{' + Object.keys(v).map((k) => dumpStr(k, ascii) + ': ' + dumps(v[k], ascii)).join(', ') + '}';
}
// end index (exclusive) of the balanced {...} starting at j, string-aware; -1 when unbalanced
function balancedEnd(t, j) {
  let depth = 0, inStr = false;
  for (let i = j; i < t.length; i++) {
    const c = t[i];
    if (inStr) {
      if (c === '\\') i++;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') inStr = true;
    else if (c === '{' || c === '[') depth++;
    else if (c === '}' || c === ']') { depth--; if (depth === 0) return i + 1; if (depth < 0) return -1; }
  }
  return -1;
}

if (cmd === 'normalize') {
  let cands = [];
  // 1. fenced blocks first (```json ... ``` or ``` ... ```)
  const fence = /```[A-Za-z0-9_-]*\s*\n([\s\S]*?)```/g;
  let m;
  while ((m = fence.exec(text)) !== null) {
    try { const v = JSON.parse(m[1].trim()); if (isObj(v)) cands.push(v); } catch (e) { /* skip */ }
  }
  // 2. otherwise scan for top-level JSON objects in the prose
  if (!cands.length) {
    let i = 0;
    while (i < text.length) {
      const j = text.indexOf('{', i);
      if (j < 0) break;
      const end = balancedEnd(text, j);
      let v, ok = false;
      if (end > 0) { try { v = JSON.parse(text.slice(j, end)); ok = true; } catch (e) { ok = false; } }
      if (ok) { if (isObj(v)) cands.push(v); i = end; } else i = j + 1;
    }
  }
  if (!cands.length) { err('normalize: no JSON object found'); process.exit(1); }
  if (cands.length > 1) {
    // prefer the one carrying a known schema, if exactly one does
    const tagged = cands.filter((c) => c.schema === 'hq-phase-handoff/v1' || c.schema === 'hq-phase-envelope/v1');
    if (tagged.length !== 1) { err('normalize: ' + cands.length + ' JSON objects found, expected exactly one'); process.exit(1); }
    cands = tagged;
  }
  process.stdout.write(dumps(cands[0], false) + '\n');
  process.exit(0);
}

// ---- validate ----
if (!text.trim()) { err('invalid: empty input'); process.exit(1); }
let doc;
try { doc = JSON.parse(text); } catch (e) { err('invalid: unparseable JSON (' + e.message + ')'); process.exit(1); }
if (!isObj(doc)) {
  const tn = doc === null ? 'NoneType' : Array.isArray(doc) ? 'list' : typeof doc === 'string' ? 'str'
    : typeof doc === 'boolean' ? 'bool' : Number.isInteger(doc) ? 'int' : 'float';
  err('invalid: top level must be a JSON object, got ' + tn); process.exit(1);
}
const has = (k) => Object.prototype.hasOwnProperty.call(doc, k);
const SCHEMAS = { envelope: 'hq-phase-envelope/v1', handoff: 'hq-phase-handoff/v1' };
if (!kind) {
  for (const k of Object.keys(SCHEMAS)) if (doc.schema === SCHEMAS[k]) kind = k;
  if (!kind) {
    if (!has('schema')) err('missing field: schema');
    else err('wrong type: schema (want ' + SCHEMAS.envelope + ' or ' + SCHEMAS.handoff + ')');
    process.exit(1);
  }
}
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]00:?00)\n?$/;
const problems = [];
const isStr = (v) => typeof v === 'string';
const isBool = (v) => typeof v === 'boolean';
const strList = (v) => Array.isArray(v) && v.every(isStr);
function check(name, ok, want, required = true) {
  if (!has(name)) { if (required) problems.push('missing field: ' + name); return; }
  if (!ok(doc[name])) problems.push('wrong type: ' + name + ' (want ' + want + ')');
}
const sch = has('schema') ? doc.schema : null;
if (sch !== null && sch !== SCHEMAS[kind]) problems.push('wrong type: schema (want ' + SCHEMAS[kind] + ')');
else if (!has('schema')) problems.push('missing field: schema');

const nonEmpty = (v) => isStr(v) && v !== '';
if (kind === 'envelope') {
  for (const f of ['story_id', 'phase', 'worker_id']) check(f, nonEmpty, 'non-empty string');
  check('worktree', nonEmpty, 'string path');
  check('incoming_handoff', (v) => v === null || nonEmpty(v), 'string path or null');
  check('acceptance_criteria', strList, 'array of strings');
  check('deadline', (v) => isStr(v) && ISO.test(v), 'ISO8601 UTC string');
  check('fresh_call', isBool, 'boolean');
  for (const f of ['project', 'engine', 'result_path', 'story_title', 'story_description', 'reopen_note', 'repo', 'branch',
    'prior_handoff']) check(f, isStr, 'string', false);
  check('resumed_after_interrupt', isBool, 'boolean', false);
  check('constraints', strList, 'array of strings', false);
} else {
  for (const f of ['story_id', 'phase', 'worker_id']) check(f, nonEmpty, 'non-empty string');
  check('status', (v) => v === 'passed' || v === 'failed' || v === 'blocked', 'one of passed|failed|blocked');
  check('summary', isStr, 'string');
  check('files_changed', strList, 'array of strings');
  check('commits', strList, 'array of strings');
  if (!has('back_pressure')) problems.push('missing field: back_pressure');
  else if (!isObj(doc.back_pressure)) problems.push('wrong type: back_pressure (want object)');
  else {
    const bp = doc.back_pressure;
    for (const g of ['tests', 'lint', 'typecheck', 'build']) {
      if (!Object.prototype.hasOwnProperty.call(bp, g)) problems.push('missing field: back_pressure.' + g);
      else if (!['pass', 'fail', 'skip'].includes(bp[g])) problems.push('wrong type: back_pressure.' + g + ' (want one of pass|fail|skip)');
    }
  }
  check('context_for_next', isStr, 'string');
  for (const f of ['engine', 'notes']) check(f, isStr, 'string', false);
}
if (problems.length) { for (const p of problems) err(p); process.exit(1); }
process.stdout.write('valid ' + kind + '\n');
process.exit(0);
JS
