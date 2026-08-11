#!/usr/bin/env bash
# Regression tests for the opt-in soft story-timeout wiring in
# .claude/scripts/run-project.sh (finding §2.1 / hq-soft-timeouts-warn-dont-kill).
#
# The soft-timeout primitive now lives in the hq CLI (`hq core soft-timeout`),
# tested in hq-cli. run-project.sh only RESOLVES and WIRES it, so this suite
# locks the wiring: the runner prefers `hq core soft-timeout`, both story-launch
# paths gate on HQ_SOFT_STORY_TIMEOUT=1 and a resolved runner, and the default
# stays hard-kill.
#
# Run: bash core/scripts/tests/run-project-soft-timeout.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RP="$ROOT/.claude/scripts/run-project.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# --- 1. run-project.sh still parses ---
bash -n "$RP" && ok "run-project.sh syntax OK" || bad "run-project.sh syntax error"

# --- 2. the runner resolves to the hq CLI command (no bundled shell helper) ---
grep -q 'SOFT_TIMEOUT_RUNNER=(hq core soft-timeout)' "$RP" \
  && ok "runner resolves to 'hq core soft-timeout'" \
  || bad "runner does not resolve to the hq CLI command"
grep -q 'core/scripts/lib/soft-timeout.sh' "$RP" \
  && bad "run-project still references the removed shell helper" \
  || ok "no reference to the removed shell soft-timeout helper"

# --- 3. wiring present in BOTH story-launch paths, guarded and default-off ---
n_guard="$(grep -c 'HQ_SOFT_STORY_TIMEOUT:-.*==.*"1".*SOFT_TIMEOUT_RUNNER\[@\]} -gt 0' "$RP")"
[[ "$n_guard" -eq 2 ]] && ok "both paths gate soft mode on HQ_SOFT_STORY_TIMEOUT=1 + a resolved runner" \
  || bad "expected 2 guarded soft branches, found $n_guard"
n_call="$(grep -c 'SOFT_TIMEOUT_RUNNER\[@\]}" "${TIMEOUT}m"' "$RP")"
[[ "$n_call" -eq 2 ]] && ok "both paths invoke the resolved soft runner with the TIMEOUT window" \
  || bad "expected 2 soft-runner calls, found $n_call"

# --- 4. default-off invariant: the hard timeout/perl fallbacks must remain ---
grep -q 'perl -e "alarm(${TIMEOUT}\*60)' "$RP" && ok "hard-kill fallback retained (default behavior)" \
  || bad "hard-kill fallback was removed — default must stay hard"

# --- 5. the cap grammar the runner supplies is honored (3x default, override, none) ---
grep -q 'HQ_SOFT_STORY_TIMEOUT_CAP' "$RP" && ok "hard-cap override env is wired" \
  || bad "HQ_SOFT_STORY_TIMEOUT_CAP wiring missing"
grep -q 'TIMEOUT \* 3' "$RP" && ok "default hard cap is 3x the window" \
  || bad "default 3x hard cap missing"

echo "----"
echo "pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
