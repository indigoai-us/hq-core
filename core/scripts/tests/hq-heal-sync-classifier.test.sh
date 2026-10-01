#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/hq-heal/SKILL.md"
WORKFLOW="$ROOT/.github/workflows/pr-checks.yml"
checks=0
failures=()
expect_grep() {
  local pattern="$1" input="$2" message="$3"
  if grep -Fq "$pattern" <<<"$input"; then
    checks=$((checks + 1))
  else
    failures+=("$message")
  fi
}

sync_row="$(awk -F'|' '/^\| `sync` \|/ { print; exit }' "$SKILL")"
case "$sync_row" in
  *FILES_PRESIGN_STALE_UPLOAD_FORBIDDEN*resend_full_scheduled*'manifest.*throttled'*) checks=$((checks + 1)) ;;
  *) failures+=('new sync triggers must stay in the sync classifier row and in order') ;;
esac

last_session_extract="$(sed -n '/If `--last-session`/,/Store the resulting text/p' "$SKILL")"
for trigger in FILES_PRESIGN_STALE_UPLOAD_FORBIDDEN resend_full_scheduled 'manifest.*throttled'; do
  expect_grep "$trigger" "$last_session_extract" "--last-session extraction is missing $trigger"
done

sync_recipe="$(sed -n '/^#### `sync`/,/^#### `access`/p' "$SKILL")"
expect_grep '/hq-sync' "$sync_recipe" 'non-conflict sync failures need the /hq-sync recovery path'
expect_grep 'partial' "$sync_recipe" 'sync recovery must inspect partial status'
expect_grep 'transient' "$sync_recipe" 'sync recovery must report retryable transient diagnostics'
expect_grep 'resolve-conflicts' "$sync_recipe" 'sync conflicts must retain the /resolve-conflicts path'
expect_grep 'without any conflict-ledger row' "$sync_recipe" 'sync recipe must distinguish failures without conflict rows'

expect_grep 'bash core/scripts/tests/hq-heal-sync-classifier.test.sh' \
  "$(cat "$WORKFLOW")" 'pr-checks.yml must execute this regression test'

if ((${#failures[@]})); then
  for failure in "${failures[@]}"; do printf 'FAIL: %s\n' "$failure" >&2; done
  exit 1
fi
printf 'PASS: %s hq-heal sync classifier, recovery, extraction, and CI assertions\n' "$checks"
