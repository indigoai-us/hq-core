#!/usr/bin/env bash
# Regression: a Codex / ChatGPT desktop app sandbox blocking outbound HTTPS
# surfaces as `fetch failed` with `connect EPERM …:443` underneath. hq-heal must
# classify that ahead of `sync`, never propose a retry, and name the two real
# fixes (Full access in the app, or sync outside the sandbox).
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
expect_not_grep() {
  local pattern="$1" input="$2" message="$3"
  if grep -Fiq "$pattern" <<<"$input"; then
    failures+=("$message")
  else
    checks=$((checks + 1))
  fi
}

# Row exists and sits above the sync row (first match wins).
sandbox_line="$(grep -n '^| `sandbox-network` |' "$SKILL" | head -1 | cut -d: -f1 || true)"
sync_line="$(grep -n '^| `sync` |' "$SKILL" | head -1 | cut -d: -f1 || true)"
if [[ -n "$sandbox_line" && -n "$sync_line" && "$sandbox_line" -lt "$sync_line" ]]; then
  checks=$((checks + 1))
else
  failures+=('sandbox-network classifier row must exist and precede the sync row')
fi

sandbox_row="$(awk -F'|' '/^\| `sandbox-network` \|/ { print; exit }' "$SKILL")"
for trigger in 'connect EPERM' 'EPERM .*:443' CODEX_SANDBOX_NETWORK_DISABLED; do
  expect_grep "$trigger" "$sandbox_row" "sandbox-network row is missing trigger $trigger"
done

expect_grep '`sandbox-network`' "$(sed -n '/--class <name>/p' "$SKILL")" '--class must accept sandbox-network'

# Negative: a plain offline "fetch failed" (ENOTFOUND / ECONNREFUSED / ETIMEDOUT, no
# EPERM) must NOT be a sandbox-network trigger. The row may mention the phrase only
# to exclude it, so check the trigger list (text before the em dash) specifically.
trigger_list="${sandbox_row%%—*}"
expect_not_grep 'fetch failed' "$trigger_list" 'bare fetch failed must not trigger sandbox-network (offline sync would be misclassified)'
expect_not_grep 'network_access' "$trigger_list" 'network_access config key must not trigger sandbox-network'
for code in ENOTFOUND ECONNREFUSED ETIMEDOUT; do
  expect_not_grep "$code" "$trigger_list" "$code must not trigger sandbox-network"
done

last_session_extract="$(sed -n '/If `--last-session`/,/Store the resulting text/p' "$SKILL")"
for trigger in 'fetch failed' 'connect EPERM' 'EPERM'; do
  expect_grep "$trigger" "$last_session_extract" "--last-session extraction is missing $trigger"
done

recipe="$(sed -n '/^#### `sandbox-network`/,/^#### `sync`/p' "$SKILL")"
expect_grep 'Full access' "$recipe" 'recipe must point ChatGPT app users at Full access'
expect_grep 'hq sync' "$recipe" 'recipe must offer running hq sync outside the sandbox'
expect_grep 'HQ Sync' "$recipe" 'recipe must offer the HQ Sync app as the unsandboxed path'
expect_grep 'detect-codex.sh' "$recipe" 'recipe must confirm the Codex host before blaming the sandbox'
expect_grep 'do not propose a retry' "$recipe" 'recipe must not retry once EPERM is confirmed'
expect_grep 'reclassify as `sync`' "$recipe" 'recipe must fall through to sync for a real outage'
for code in ENOTFOUND ECONNREFUSED ETIMEDOUT; do
  expect_grep "$code" "$recipe" "recipe must name $code as a non-sandbox outage"
done

expect_grep 'bash core/scripts/tests/hq-heal-sandbox-network-classifier.test.sh' \
  "$(cat "$WORKFLOW")" 'pr-checks.yml must execute this regression test'

if ((${#failures[@]})); then
  for failure in "${failures[@]}"; do printf 'FAIL: %s\n' "$failure" >&2; done
  exit 1
fi
printf 'PASS: %s hq-heal sandbox-network classifier assertions\n' "$checks"
