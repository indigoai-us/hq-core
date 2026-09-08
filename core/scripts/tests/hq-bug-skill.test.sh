#!/usr/bin/env bash
# Prompt contract regression. This checks released instructions, not model quality.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="${HQ_BUG_SKILL_UNDER_TEST:-$ROOT/.claude/skills/hq-bug/SKILL.md}"

node - "$SKILL" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const skill = fs.readFileSync(process.argv[2], 'utf8');
const parse = skill.split('### 1. Parse input')[1].split('### 2.')[0];
const body = skill.split('### 6. Assemble four-section body')[1].split('### 7.')[0];
const submit = skill.split('### 8. Submit')[1].split('### 9.')[0];
assert.match(parse, /TITLE.*concise one-line summary.*--title.*under 120 characters/);
assert.match(parse, /Preserve a short, clear supplied title/);
assert.match(parse, /summarize long input without inventing a cause/);
assert.match(parse, /neither `bug` nor `feature`.*ENTIRE.*default TYPE to `bug`.*do not consume the first token/);
assert.match(parse, /User Message.*full `\$ARGUMENTS` text verbatim.*independently of TITLE/);
assert.match(body, /## User Message\n<User Message verbatim from Step 1.*full \$ARGUMENTS text>/);
assert.match(submit, /hq feedback "<type>" --title "<title>" --body-file "<body-path>"/);
assert.match(parse, /missing or empty.*AskUserQuestion/);
console.log('hq-bug prompt contract: concise title, independent verbatim body, typed/untyped input, explicit CLI flags');
JS
