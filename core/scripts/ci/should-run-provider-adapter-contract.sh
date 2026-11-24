#!/usr/bin/env bash
# Decide whether a PR or push changed an input of the provider-adapter-contract
# suites. Prints run=true or run=false.
#
# Fails closed: when the change set cannot be computed (missing or unknown
# base, no merge-base, git diff error), it prints run=true so the suites run
# instead of being skipped silently.
set -uo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "usage: should-run-provider-adapter-contract.sh <base-ref-or-sha> <head-ref-or-sha> <repo-root>" >&2
  exit 2
fi

base="$1"
head="$2"
repo_root="$3"

run_all() {
  echo "provider-adapter-contract filter: $1; running every suite" >&2
  echo "run=true"
  exit 0
}

[[ -n "$base" ]] || run_all "no base revision"
git -C "$repo_root" rev-parse --verify --quiet "${base}^{commit}" >/dev/null \
  || run_all "base $base is not an available commit"
git -C "$repo_root" rev-parse --verify --quiet "${head}^{commit}" >/dev/null \
  || run_all "head $head is not an available commit"

# Three-dot: changes on the head side since the merge-base, as GitHub shows a PR.
if ! changed="$(git -C "$repo_root" diff --name-only "$base...$head")"; then
  run_all "git diff $base...$head failed"
fi

# provider-adapter-version.sh is included on purpose: a contract-version bump
# changes the snapshot's contractVersion without touching any adapter file.
pattern='^core/scripts/lib/provider-adapter\.sh$|^core/scripts/lib/provider-adapters/|^core/scripts/lib/provider-adapter-version\.sh$|^core/scripts/generate-adapter-capabilities\.sh$|^core/scripts/tests/provider-adapter-|^core/scripts/tests/probes/|^core/scripts/codex-preflight\.sh$|^core/scripts/convert-codex\.sh$|^core/scripts/tests/codex-sandbox-danger-full-access\.test\.sh$|^core/workers/public/dev-team/|^\.claude/scripts/run-project\.sh$|^\.claude/skills/execute-task/SKILL\.md$|^\.codex/config\.toml$|^\.codex/hooks/hq-codex-hook|^core/scripts/tests/codex-windows-hook-launcher'

if grep -qE "$pattern" <<< "$changed"; then
  echo "run=true"
else
  echo "run=false"
fi
