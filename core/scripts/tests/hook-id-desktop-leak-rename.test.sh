#!/usr/bin/env bash
# Regression: the SessionStart desktop memory-leak detector hook used to ship
# under an id that embedded a company slug. It was renamed to
# desktop-memory-leak-check. This test asserts that the retired id appears
# nowhere in tracked files and that the new id is wired the same way in
# hook-gate.sh, the hook registry and the synthetic hook corpus. The retired id
# is compared only by its sha256 so the string itself never re-enters the repo.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
command -v node >/dev/null 2>&1 || fail "node is required"

RETIRED_SHA256=bbd31c49a5cded814da89ad3ee84a89a3995e2cb33b06610a06c4a362afe1710
RETIRED_LEN=19
NEW_ID=desktop-memory-leak-check

# 1. The retired id must not appear in any tracked file's contents or path.
TOKENS="$(mktemp)"; trap 'rm -f "$TOKENS"' EXIT
git -C "$ROOT" grep -I -h -o -i -E "[a-z0-9-]{$RETIRED_LEN,}" -- . >"$TOKENS" || true
git -C "$ROOT" ls-files >>"$TOKENS"
node - "$TOKENS" "$RETIRED_SHA256" "$RETIRED_LEN" <<'NODE' || fail "retired hook id still appears in tracked files"
const { readFileSync } = require('node:fs');
const { createHash } = require('node:crypto');
const [file, want, lenText] = process.argv.slice(2);
const len = Number(lenText);
const seen = new Set();
for (const raw of readFileSync(file, 'utf8').split(/[\n/._ ]+/)) {
  const tok = raw.toLowerCase();
  // Check every window of the retired length so the id is caught inside longer tokens.
  for (let i = 0; i + len <= tok.length; i++) {
    const w = tok.slice(i, i + len);
    if (seen.has(w)) continue;
    seen.add(w);
    if (createHash('sha256').update(w).digest('hex') === want) process.exit(1);
  }
}
NODE
pass "retired hook id absent from tracked contents and paths"

# 2. The new id is wired consistently across the profile lists, registry and corpus.
node - "$ROOT" "$NEW_ID" <<'NODE'
const { readFileSync, existsSync } = require('node:fs');
const { join } = require('node:path');
const [root, id] = process.argv.slice(2);
const die = m => { console.error('FAIL: ' + m); process.exit(1); };
const gate = readFileSync(join(root, '.claude/hooks/hook-gate.sh'), 'utf8');
const list = name => {
  const m = gate.match(new RegExp(name + '\\(\\) \\{\\n\\s*case "\\$1" in\\n\\s*([^)]+)\\)'));
  if (!m) die(`cannot parse ${name}`);
  return m[1].trim().split('|');
};
const minimal = list('is_in_minimal_profile');
const standard = list('is_in_standard_profile');
const strict = list('is_in_strict_profile');
for (const [name, ids] of [['standard', standard], ['strict', strict]]) {
  const n = ids.filter(x => x === id).length;
  if (n !== 1) die(`${id} must appear once in the ${name} profile list, found ${n}`);
}
if (minimal.includes(id)) die(`${id} is a SessionStart diagnostic and must stay out of the minimal profile`);
if (standard.indexOf(id) !== strict.indexOf(id)) die(`${id} sits at different positions in standard and strict`);
console.log('  ok: profile lists wire ' + id + ' consistently');

const registry = JSON.parse(readFileSync(join(root, '.claude/hooks/hook-registry.json'), 'utf8'));
const entries = [];
for (const [event, groups] of Object.entries(registry.hooks || {}))
  for (const g of groups) for (const h of g.hooks || []) if (h.id === id) entries.push({ event, ...h });
if (entries.length !== 1) die(`expected one registry entry for ${id}, found ${entries.length}`);
const { event, script } = entries[0];
if (event !== 'SessionStart') die(`${id} must be registered on SessionStart, found ${event}`);
if (!script || !existsSync(join(root, script))) die(`hook script missing for ${id}`);
let scriptUses = 0;
for (const groups of Object.values(registry.hooks || {}))
  for (const g of groups) for (const h of g.hooks || []) if (h.script === script) scriptUses++;
if (scriptUses !== 1) die(`the ${id} script is registered ${scriptUses} times`);
console.log('  ok: registry entry for ' + id + ' points at an existing script');

const corpus = JSON.parse(readFileSync(join(root, 'core/scripts/hook-corpus/corpus.json'), 'utf8'));
const rows = corpus.cases.filter(c => JSON.stringify(c.registry || {}).includes(JSON.stringify(script)));
if (rows.length === 0) die(`corpus has no cases for ${id}`);
for (const r of rows) if (r.hook_id !== id) die(`a corpus case for the ${id} script uses a different hook_id`);
console.log('  ok: corpus cases use ' + id);
NODE
echo "PASS: hook-id-desktop-leak-rename"
