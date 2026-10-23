#!/usr/bin/env bash
# check-skill-edit.sh — run the skill-edit CI checks locally before pushing.
#
# Mirrors the skill-script-refs, skill-command-refs and agent-runtime-skill-metadata
# jobs in .github/workflows/pr-checks.yml so allowed-tools gaps, stale
# commands.json / COMMANDS.md, and fenced $ARGUMENTS surface before CI.
#
# Usage: bash core/scripts/check-skill-edit.sh
# The YAML parser used by the metadata validator is installed into a temp dir
# unless HQ_AGENT_RUNTIME_PARSER_ROOT already points at one (needs network once).
# Exit 0 when every check passes, 1 when any fails (all checks still run).
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root" || exit 2

failed=()
run() { # run <label> <cmd...>
  local label="$1"; shift
  echo "==> $label"
  if "$@"; then :; else failed+=("$label"); echo "FAIL: $label" >&2; fi
}

# skill-command-refs job
run "skill command refs" bash core/scripts/lint-skill-command-refs.sh

# skill-script-refs job
run "intent index current" bash core/scripts/build-intent-index.sh --check
run "commands.json / COMMANDS.md current" bash core/scripts/skill-inventory.sh --check
for s in handoff checkpoint learn resumework startwork conduct retro delegate; do
  run "skill script refs: $s" bash core/scripts/lint-skill-script-refs.sh "$s"
done
run "skill-script-refs regression" bash core/scripts/tests/skill-script-refs.test.sh
run "skill core script references" bash core/scripts/tests/skill-core-script-references.test.sh
run "no positional/fenced \$ARGUMENTS in skill bodies" bash core/scripts/tests/skill-body-positional-placeholders.test.sh
run "skill company bind before read" bash core/scripts/tests/skill-company-bind-before-read.test.sh

# agent-runtime-skill-metadata job
if [[ -z "${HQ_AGENT_RUNTIME_PARSER_ROOT:-}" ]]; then
  parser_dir="$(mktemp -d)"
  trap 'rm -rf "$parser_dir"' EXIT
  if node core/scripts/validate-agent-runtime-contracts.mjs install-parser --install-dir "$parser_dir" >/dev/null; then
    export HQ_AGENT_RUNTIME_PARSER_ROOT="$parser_dir"
  else
    failed+=("install YAML parser"); echo "FAIL: install YAML parser" >&2
  fi
fi
if [[ -n "${HQ_AGENT_RUNTIME_PARSER_ROOT:-}" ]]; then
  run "skill metadata + openai.yaml" node core/scripts/validate-agent-runtime-contracts.mjs
  run "skill command permissions (allowed-tools)" node core/scripts/validate-agent-runtime-contracts.mjs validate-permissions
fi
run "skill metadata regression" bash core/scripts/tests/agent-runtime-skill-metadata.test.sh
run "skill permission regression" bash core/scripts/tests/agent-runtime-permissions.test.sh

if (( ${#failed[@]} )); then
  echo "check-skill-edit: ${#failed[@]} failed:" >&2
  printf '  - %s\n' "${failed[@]}" >&2
  exit 1
fi
echo "check-skill-edit: all checks passed"
