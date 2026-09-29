#!/usr/bin/env bash
set -euo pipefail

ROOT="${US091_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
failures=0

policy_docs=(
  core/policies/hq-bash-discipline.md
  core/policies/prd-validation.md
  core/policies/work-broadcast-jq-inline-recipe-fails-bash-harness.md
  .claude/skills/execute-task/SKILL.md
)

for rel in "${policy_docs[@]}"; do
  file="$ROOT/$rel"
  if [ ! -f "$file" ]; then
    echo "FAIL: missing contract document: $rel" >&2
    failures=$((failures + 1))
    continue
  fi
  hits="$(grep -n 'python3' "$file" || true)"
  if [ -n "$hits" ]; then
    printf 'FAIL: %s still contains a python3 instruction:\n%s\n' "$rel" "$hits" >&2
    failures=$((failures + 1))
  else
    echo "ok: $rel has no python3 invocation"
  fi
done

for required in \
  'core/policies/hq-bash-discipline.md|realpathSync' \
  'core/policies/hq-bash-discipline.md|statSync' \
  'core/policies/prd-validation.md|JSON.parse' \
  'core/policies/work-broadcast-jq-inline-recipe-fails-bash-harness.md|writeFileSync' \
  'core/policies/work-broadcast-jq-inline-recipe-fails-bash-harness.md|JSON.stringify' \
  '.claude/skills/execute-task/SKILL.md|JSON.parse'; do
  rel="${required%%|*}"
  fragment="${required#*|}"
  if grep -Fq "$fragment" "$ROOT/$rel"; then
    echo "ok: $rel retains its Node equivalent ($fragment)"
  else
    echo "FAIL: $rel is missing its Node equivalent ($fragment)" >&2
    failures=$((failures + 1))
  fi
done

extract_node_program() {
  node - "$ROOT/$1" "$2" <<'NODE'
const fs = require('node:fs');
const [file, marker] = process.argv.slice(2);
const source = fs.readFileSync(file, 'utf8');
const candidates = [...source.matchAll(/node -e '([^']+)'/g)].map(match => match[1]);
const program = candidates.find(candidate => candidate.includes(marker));
if (!program) process.exit(2);
process.stdout.write(program);
NODE
}

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
fixture_file="$fixture_dir/sample.json"
printf '%s\n' '{"userStories":[{},{}],"apiKey":"synthetic-fixture"}' > "$fixture_file"

realpath_program="$(extract_node_program core/policies/hq-bash-discipline.md 'realpathSync(process.argv[1])')" || realpath_program=''
expected_realpath="$(cd "$fixture_dir" && pwd -P)/sample.json"
if [ -n "$realpath_program" ] && actual="$(node -e "$realpath_program" "$fixture_file")" && [ "$actual" = "$expected_realpath" ]; then
  echo "ok: documented realpathSync command resolves a fixture path"
else
  echo "FAIL: documented realpathSync command did not resolve the fixture path" >&2
  failures=$((failures + 1))
fi

mtime_program="$(extract_node_program core/policies/hq-bash-discipline.md 'statSync(process.argv[1]).mtimeMs')" || mtime_program=''
mtime_result=''
if [ -n "$mtime_program" ]; then
  mtime_result="$(node -e "$mtime_program" "$fixture_file")" || mtime_result=''
fi
case "$mtime_result" in
  ''|*[!0-9]*)
    echo "FAIL: documented statSync command did not return an integer timestamp" >&2
    failures=$((failures + 1))
    ;;
  *) echo "ok: documented statSync command returns an integer timestamp" ;;
esac

prd_program="$(extract_node_program core/policies/prd-validation.md 'JSON.parse(require("node:fs").readFileSync(0, "utf8"))')" || prd_program=''
if [ -n "$prd_program" ] && printf '%s\n' '{"userStories":[]}' | node -e "$prd_program" >/dev/null 2>&1; then
  echo "ok: documented PRD parser accepts valid JSON from stdin"
else
  echo "FAIL: documented PRD parser rejected valid fixture JSON" >&2
  failures=$((failures + 1))
fi
if [ -n "$prd_program" ] && printf '%s\n' '{invalid' | node -e "$prd_program" >/dev/null 2>&1; then
  echo "FAIL: documented PRD parser accepted invalid JSON" >&2
  failures=$((failures + 1))
else
  echo "ok: documented PRD parser rejects invalid JSON"
fi

linear_program="$(extract_node_program .claude/skills/execute-task/SKILL.md '.apiKey')" || linear_program=''
linear_result=''
if [ -n "$linear_program" ]; then
  linear_result="$(printf '%s\n' '{"apiKey":"synthetic-fixture"}' | node -e "$linear_program")" || linear_result=''
fi
if [ "$linear_result" = 'synthetic-fixture' ]; then
  echo "ok: documented Linear credential parser extracts the fixture field"
else
  echo "FAIL: documented Linear credential parser did not extract its fixture field" >&2
  failures=$((failures + 1))
fi

story_total_program="$(extract_node_program .claude/skills/execute-task/SKILL.md 'userStories.length')" || story_total_program=''
story_total=''
if [ -n "$story_total_program" ]; then
  story_total="$(printf '%s\n' '{"userStories":[{},{}]}' | node -e "$story_total_program")" || story_total=''
fi
if [ "$story_total" = '2' ]; then
  echo "ok: documented story-count parser returns the fixture count"
else
  echo "FAIL: documented story-count parser did not return the fixture count" >&2
  failures=$((failures + 1))
fi

broadcast_program="$(extract_node_program core/policies/work-broadcast-jq-inline-recipe-fails-bash-harness.md 'process.argv[1]')" || broadcast_program=''
broadcast_file="$fixture_dir/slack-body.json"
if [ -n "$broadcast_program" ] && node -e "$broadcast_program" "$broadcast_file" 'fixture-channel' 'fixture message'; then
  if node -e 'const fs=require("node:fs"); const body=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); if (body.channel!=="fixture-channel" || body.text!=="fixture message") process.exit(1)' "$broadcast_file"; then
    echo "ok: documented work-broadcast command writes valid fixture JSON"
  else
    echo "FAIL: documented work-broadcast command wrote unexpected fixture JSON" >&2
    failures=$((failures + 1))
  fi
else
  echo "FAIL: documented work-broadcast command did not run" >&2
  failures=$((failures + 1))
fi

skill="$ROOT/.claude/skills/knowledge-pulse/SKILL.md"
if [ ! -f "$skill" ]; then
  echo "FAIL: missing knowledge-pulse skill" >&2
  failures=$((failures + 1))
else
  step4="$(sed -n '/^### Step 4: Record Changes for Company Vault Sync$/,/^### Step 5:/p' "$skill")"
  if printf '%s\n' "$step4" | grep -Eq 'git([[:space:]]+-C|[[:space:]]+(add|commit|init|log))|/\.git'; then
    echo "FAIL: company knowledge Step 4 inspects or changes Git metadata" >&2
    failures=$((failures + 1))
  else
    echo "ok: Step 4 does not inspect or change Git metadata"
  fi
  if ! grep -Fq 'Record the changed' "$skill" || ! grep -Fq 'paths in the pulse report for company vault sync' "$skill"; then
    echo 'FAIL: company knowledge changes must be recorded for vault sync' >&2
    failures=$((failures + 1))
  else
    echo "ok: Step 4 records changed paths for company vault sync"
  fi
fi

if [ "$failures" -ne 0 ]; then
  echo "US-091 contract failures: $failures" >&2
  exit 1
fi
echo "US-091 policy and skill contracts passed"
