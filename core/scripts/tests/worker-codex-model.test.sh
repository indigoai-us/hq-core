#!/usr/bin/env bash
# Regression test for feedback_9ab94d56-ff59-45ab-b6a4-538f3f847c36:
# company and personal overrides of a core worker's codex_model apply without
# editing core/, without a feature flag, and never touch codex_flags.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/worker-codex-model.sh"
SKILL="$ROOT/.claude/skills/execute-task/SKILL.md"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

H="$TMP/hq"
mkdir -p "$H/core/workers/public/dev-team/codex-reviewer" "$H/core/workers/public/solo-core" \
  "$H/companies/acme/workers/codex-reviewer" "$H/personal/workers/codex-reviewer" \
  "$H/personal/workers/my-own" "$H/core/workers/public/no-model"
printf 'worker:\n  id: codex-reviewer\nexecution:\n  codex_model: "gpt-5.4"   # pinned\n  codex_flags: --reasoning high --fast\n' \
  >"$H/core/workers/public/dev-team/codex-reviewer/worker.yaml"
printf 'execution:\n  codex_model: gpt-5.4\n' >"$H/core/workers/public/solo-core/worker.yaml"
printf 'execution:\n  model: opus\n' >"$H/core/workers/public/no-model/worker.yaml"
printf 'execution:\n  codex_model: gpt-6-astra\n  codex_flags: --dangerous\n' >"$H/personal/workers/codex-reviewer/overrides.yaml"
printf 'execution:\n  codex_model: gpt-6-company\n' >"$H/companies/acme/workers/codex-reviewer/overrides.yaml"
printf 'execution:\n  codex_model: gpt-mine\n' >"$H/personal/workers/my-own/worker.yaml"

run() { bash "$SCRIPT" --hq-root "$H" "$@"; }
tab=$'\t'

[ "$(run codex-reviewer)" = "gpt-6-astra${tab}personal-override" ] || fail "personal override must beat the core pin: $(run codex-reviewer)"
[ "$(run --company acme codex-reviewer)" = "gpt-6-company${tab}company-override" ] || fail "company override must beat personal"
[ "$(run --company other codex-reviewer)" = "gpt-6-astra${tab}personal-override" ] || fail "another company's override must not apply"
[ "$(run --company acme --story-hint gpt-hint codex-reviewer)" = "gpt-hint${tab}story-hint" ] || fail "story hint must win"
[ "$(run solo-core)" = "gpt-5.4${tab}worker" ] || fail "core pin applies with no override"
[ "$(run my-own)" = "gpt-mine${tab}worker" ] || fail "a personal-only worker reads its own profile"

# A personal worker.yaml overlay (same id as core) also works as an override.
rm "$H/personal/workers/codex-reviewer/overrides.yaml"
printf 'execution:\n  codex_model: gpt-overlay\n' >"$H/personal/workers/codex-reviewer/worker.yaml"
[ "$(run codex-reviewer)" = "gpt-overlay${tab}personal-override" ] || fail "same-id personal worker.yaml overlays the model"

if run no-model >/dev/null 2>&1; then fail "missing codex_model must be a configuration error"; fi
if run ../x >/dev/null 2>&1; then fail "path traversal in worker id must be refused"; fi
if run --company ../x codex-reviewer >/dev/null 2>&1; then fail "path traversal in company must be refused"; fi

# execute-task uses the resolver, keeps codex_flags pinned, and is not flag gated.
grep -Fq 'core/scripts/worker-codex-model.sh' "$SKILL" || fail "execute-task must resolve codex_model through worker-codex-model.sh"
# shellcheck disable=SC2016 # literal backticks
grep -Fq 'Do not read or merge override `execution.codex_flags`' "$SKILL" || fail "codex_flags must stay pinned"
if grep -Fq 'workers.codex-model-overrides' "$SKILL"; then fail "overrides must not depend on the default-off flag"; fi

echo "PASS: worker codex_model company/personal overrides"
