#!/usr/bin/env bash
# check-skill-edit.test.sh — check-skill-edit.sh runs every CI skill-edit step
# and reports failures. Static contract: each CI command is wired in.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/../check-skill-edit.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
bash -n "$S" || fail "syntax"
for needle in lint-skill-command-refs.sh "skill-inventory.sh --check" build-intent-index.sh \
  lint-skill-script-refs.sh skill-body-positional-placeholders.test.sh \
  validate-agent-runtime-contracts.mjs validate-permissions agent-runtime-skill-metadata.test.sh; do
  grep -qF -- "$needle" "$S" || fail "missing step: $needle"
done
# every lint-skill-script-refs skill CI runs is covered
for s in $(grep -oE 'lint-skill-script-refs\.sh [a-z-]+' "$HERE/../../../.github/workflows/pr-checks.yml" | awk '{print $2}'); do
  grep -qE "\\b$s\\b" "$S" || fail "CI skill not covered: $s"
done
echo "PASS check-skill-edit"
