#!/usr/bin/env bash
# Regression for large policy vocabularies without a giant Bash regexp.

set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/root"
mkdir -p "$ROOT/core/scripts/lib" "$ROOT/core/policies" \
  "$ROOT/personal/policies" "$ROOT/workspace/orchestrator/policy-trigger-state" \
  "$ROOT/workspace/orchestrator/hook-state/policy-prefilter" "$TMP/cwd"
cp "$SOURCE_ROOT/core/scripts/lib/hook-adapter-core.sh" "$ROOT/core/scripts/lib/"
cp "$SOURCE_ROOT/core/scripts/lib/trigger-fact-text.awk" "$ROOT/core/scripts/lib/"

awk -v dir="$ROOT/core/policies" '
  BEGIN {
    for (i = 1; i <= 6000; i++) {
      token = sprintf("policy_scale_token_%04d", i)
      if (i == 6000) token = "apikey"
      path = dir "/scale-" sprintf("%04d", i) ".md"
      print "---" > path
      print "on: PreToolUse" > path
      print "when: " token > path
      print "---" > path
      print "Synthetic scale policy." > path
      close(path)
    }
  }
'
for token in '.sh' 'hook-lib.sh' 'scripts' '/deploy' 'force-push' 'shared_branch'; do
  slug="fact-token-${token//[^A-Za-z0-9]/_}"
  cat > "$ROOT/core/policies/$slug.md" <<POLICY
---
on: PreToolUse
when: $token
---
Synthetic tokenizer parity policy.
POLICY
done
printf '%s\n' existing-session-marker \
  > "$ROOT/workspace/orchestrator/policy-trigger-state/scale-session.txt"

# Exercise the same policy prefilter used by a Bash PreToolUse registry entry.
source "$ROOT/core/scripts/lib/hook-adapter-core.sh"
check_prefilter() {
  local text="$1" expected="$2" label="$3" status=0
  if hqad_registry_prefilter_match PreToolUse "$ROOT" "" "$TMP/cwd" \
    scale-session "$text" "" "" "" 1 inject-policy-on-trigger \
    2>"$TMP/stderr"; then
    status=run
  else
    status=skip
  fi
  if [ "$status" != "$expected" ]; then
    printf 'FAIL: %s: expected %s, got %s\n' "$label" "$expected" "$status" >&2
    return 1
  fi
  if [ -s "$TMP/stderr" ]; then
    printf 'FAIL: %s emitted stderr:\n' "$label" >&2
    cat "$TMP/stderr" >&2
    return 1
  fi
}

export HQ_POLICY_PREFILTER_TTL=3600
check_prefilter 'bash -lc "printf POLICY_SCALE_TOKEN_5999"' run \
  '5,999th policy token, case insensitive' || exit 1
check_prefilter 'bash -lc "printf no_policy_token_here"' skip \
  'payload without a vocabulary token' || exit 1
check_prefilter 'bash -lc "printf sk-fakekey123"' run \
  'derived apikey fact' || exit 1
check_prefilter 'bash core/scripts/hook-lib.sh' run \
  'word, basename, and extension facts match the evaluator' || exit 1
check_prefilter 'run /deploy now' run \
  'slash-command facts match the evaluator' || exit 1
check_prefilter 'echo hello' skip \
  'unrelated tokenized text still skips' || exit 1
check_prefilter 'git push --force-push' run \
  'hyphenated token facts match the evaluator' || exit 1
check_prefilter 'git push origin main' run \
  'shared branch special fact matches the evaluator' || exit 1

printf 'PASS: 6,000-policy token-set prefilter scale and derived-fact coverage\n'
