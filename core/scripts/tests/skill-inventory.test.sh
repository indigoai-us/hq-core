#!/usr/bin/env bash
# skill-inventory.test.sh — fixture coverage for core/scripts/skill-inventory.sh:
# exact duplicates, drifted copies, near-duplicate descriptions, mirror
# collapse, scopes, shipped filtering, --out isolation, and --check freshness.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
GEN="$HERE/../skill-inventory.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/hq"

fail() { echo "FAIL: $*" >&2; exit 1; }

skill() { # skill <path-to-dir> <name> <description> [extra body]
  mkdir -p "$1"
  printf '%s\n' '---' "name: $2" "description: $3" 'triggers: [first phrase, second phrase]' \
    'tags:' '  - alpha-tag' '---' '' "${4:-Body.}" > "$1/SKILL.md"
}

mkdir -p "$ROOT/companies" "$ROOT/.claude/commands"
printf '%s\n' 'companies:' '  acme:' '    repos: []' > "$ROOT/companies/manifest.yaml"

# (1) exact duplicate: same name, identical bytes, two sources.
skill "$ROOT/.claude/skills/dupe" dupe 'Exact duplicate fixture for the inventory.'
skill "$ROOT/core/packages/hq-pack-demo/skills/dupe" dupe 'Exact duplicate fixture for the inventory.'
# (2) drifted copy: same name, different bytes.
skill "$ROOT/.claude/skills/drift" drift 'Drifted copy fixture.' 'Version one.'
skill "$ROOT/companies/acme/skills/drift" drift 'Drifted copy fixture.' 'Version two.'
# (3) near-duplicate descriptions under different names.
skill "$ROOT/.claude/skills/share-files" share-files 'Share vault files with teammates through single-use links and grants.'
skill "$ROOT/.claude/skills/send-files" send-files 'Share vault files with teammates through single-use links and direct grants.'
# Unrelated description: must not pair with anything.
skill "$ROOT/.claude/skills/handoff" handoff 'Preserve session state for a follow-up agent.'
# Mirror: personal source plus identical .claude/skills mirror collapses.
skill "$ROOT/personal/skills/notes" notes 'Personal notes helper skill.'
mkdir -p "$ROOT/.claude/skills/personal:notes"
cp "$ROOT/personal/skills/notes/SKILL.md" "$ROOT/.claude/skills/personal:notes/SKILL.md"
# Company mirror inside .claude/skills and a package skill.
skill "$ROOT/.claude/skills/acme:report" report 'Acme monthly report.'
skill "$ROOT/.claude/skills/hq-pack-demo:chart" chart 'Render a chart.'
# Folded description and fallback-to-body description.
mkdir -p "$ROOT/.claude/skills/folded" "$ROOT/.claude/skills/bare"
printf '%s\n' '---' 'name: folded' 'description: >-' '  Folded line one' '  line two.' '---' > "$ROOT/.claude/skills/folded/SKILL.md"
printf '%s\n' '# Bare' '' 'Bare first paragraph.' > "$ROOT/.claude/skills/bare/SKILL.md"
printf '%s\n' '---' 'description: Legacy command.' '---' 'Body' > "$ROOT/.claude/commands/legacy.md"

before="$(cd "$ROOT" && find . | LC_ALL=C sort)"
bash "$GEN" --root "$ROOT" --json --out "$TMP/all.json"
bash "$GEN" --root "$ROOT" --findings > "$TMP/findings.txt"
after="$(cd "$ROOT" && find . | LC_ALL=C sort)"
[ "$before" = "$after" ] || fail "inventory wrote inside --root"

node - "$TMP/all.json" <<'JS'
const d = require(process.argv[2]);
const assert = require('node:assert/strict');
const by = (inv) => d.skills.find((s) => s.invoke === inv);
assert.equal(d.version, 1);
assert.equal(d.generatedBy, 'core/scripts/skill-inventory.sh');
assert.deepEqual(d.findings.counts, { exactDuplicates: 1, driftedCopies: 1, nearDuplicates: 1 });
assert.equal(d.findings.exactDuplicates[0].name, 'dupe');
assert.deepEqual(d.findings.exactDuplicates[0].entries.map((e) => e.source).sort(),
  ['.claude/skills/dupe/SKILL.md', 'core/packages/hq-pack-demo/skills/dupe/SKILL.md']);
assert.equal(d.findings.driftedCopies[0].name, 'drift');
assert.deepEqual(d.findings.driftedCopies[0].entries.map((e) => e.invoke).sort(), ['/acme:drift', '/drift']);
const near = d.findings.nearDuplicates[0];
assert.deepEqual([near.a, near.b].sort(), ['/send-files', '/share-files']);
assert.ok(near.score >= 0.5 && near.score < 1);
// SkillEntry shape (desktop field names) plus inventory extras.
const keys = ['name', 'description', 'scope', 'tags', 'searchTerms', 'invoke', 'skillUid',
  'group', 'source', 'hash', 'duplicates'];
for (const s of [...d.skills, ...d.commands]) assert.deepEqual(Object.keys(s), keys);
assert.equal(by('/dupe').scope, 'core');
assert.equal(by('/personal:notes').scope, 'personal');
assert.equal(by('/acme:report').scope, 'company:acme');
assert.equal(by('/acme:drift').scope, 'company:acme');
assert.equal(by('/hq-pack-demo:chart').scope, 'package');
assert.deepEqual(by('/dupe').searchTerms, ['first phrase', 'second phrase']);
assert.deepEqual(by('/dupe').tags, ['alpha-tag']);
assert.equal(by('/dupe').skillUid, null);
assert.match(by('/dupe').hash, /^sha256:[0-9a-f]{64}$/);
assert.deepEqual(by('/dupe').duplicates.exact, ['core/packages/hq-pack-demo/skills/dupe/SKILL.md']);
assert.deepEqual(by('/drift').duplicates.drifted, ['companies/acme/skills/drift/SKILL.md']);
assert.equal(by('/share-files').duplicates.near[0].invoke, '/send-files');
assert.equal(by('/folded').description, 'Folded line one line two.');
assert.equal(by('/bare').description, 'Bare first paragraph.');
assert.equal(by('/handoff').group, 'session state');
assert.equal(by('/share-files').group, 'share');
// Mirror pair is listed twice but never flagged.
assert.equal(d.skills.filter((s) => s.invoke === '/personal:notes').length, 2);
assert.deepEqual(by('/personal:notes').duplicates, { exact: [], drifted: [], near: [] });
assert.equal(d.commands.length, 1);
assert.equal(d.commands[0].invoke, '/legacy');
assert.equal(d.commands[0].description, 'Legacy command.');
JS
grep -Fq 'Exact duplicates: 1' "$TMP/findings.txt" || fail "findings exact count"
grep -Fq 'Drifted copies: 1' "$TMP/findings.txt" || fail "findings drifted count"
grep -Fq 'Near-duplicate descriptions: 1' "$TMP/findings.txt" || fail "findings near count"

# A mirror that drifted from its source is reported.
printf '%s\n' 'edited' >> "$ROOT/.claude/skills/personal:notes/SKILL.md"
bash "$GEN" --root "$ROOT" --findings | grep -Fq 'notes: ' || fail "drifted mirror not reported"
cp "$ROOT/personal/skills/notes/SKILL.md" "$ROOT/.claude/skills/personal:notes/SKILL.md"

# Shipped scope drops personal and company skills.
bash "$GEN" --root "$ROOT" --scope shipped --json > "$TMP/shipped.json"
node -e '
const d = require(process.argv[1]);
const bad = d.skills.filter((s) => s.scope === "personal" || s.scope.startsWith("company:"));
if (bad.length || d.scope !== "shipped") { console.error(bad); process.exit(1); }
if (d.findings.counts.driftedCopies !== 0) process.exit(1);
' "$TMP/shipped.json" || fail "shipped scope leaked personal/company skills"

# --check: missing, then current, then stale.
if bash "$GEN" --root "$ROOT" --check 2>/dev/null; then fail "--check passed with no generated files"; fi
mkdir -p "$ROOT/core/docs/hq"
bash "$GEN" --root "$ROOT" --json --scope shipped --out "$ROOT/core/docs/hq/commands.json"
bash "$GEN" --root "$ROOT" --markdown --scope shipped --out "$ROOT/core/docs/hq/COMMANDS.md"
bash "$GEN" --root "$ROOT" --check >/dev/null || fail "--check failed on fresh output"
# shellcheck disable=SC2016 # literal backticks
grep -Fq '`/dupe`' "$ROOT/core/docs/hq/COMMANDS.md" || fail "markdown missing /dupe"
skill "$ROOT/.claude/skills/newcomer" newcomer 'A new skill that makes the docs stale.'
if bash "$GEN" --root "$ROOT" --check 2>/dev/null; then fail "--check passed on stale output"; fi

# Bad arguments exit 64.
set +e
bash "$GEN" --root "$ROOT" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 64 ] || fail "missing mode should exit 64, got $rc"

# The checked-in generated files in this repo are current.
bash "$GEN" --root "$REPO" --check

echo 'skill-inventory.test.sh: passed'
