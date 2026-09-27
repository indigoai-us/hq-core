#!/usr/bin/env bash
# The Bash write guard must not start processes per token or command segment.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
. "$ROOT/core/scripts/tests/hook-process-budget-common.sh"
c138c_init_process_budget

packages_twenty=''
for i in $(seq 1 20); do packages_twenty+=" pkg$i"; done
packages_twenty="${packages_twenty# }"
pnpm_flags="pnpm add --prefix /home/runner/.local --registry https://registry.npmjs.org --cache /home/runner/.npm --node-linker hoisted --config.minimumReleaseAge=1440 $packages_twenty"

heredoc="cat <<'EOF'"
token=1
for segment in $(seq 1 4); do
  line="echo core/docs/item-$segment"
  for _ in $(seq 1 10); do
    line+=" token$token"
    token=$((token + 1))
  done
  heredoc+=$'\n'"$line && echo done"
done
heredoc+=$'\nEOF'

protected_one="touch $C138C_TMP/fixture/core/protected.txt"
protected_forty='touch'
for i in $(seq 1 39); do protected_forty+=" /tmp/c138c-target-$i"; done
protected_forty+=" $C138C_TMP/fixture/core/protected.txt"

segments_one='echo core/docs/example-1'
segments_twelve=''
for i in $(seq 1 12); do
  if [ "$i" -gt 1 ]; then segments_twelve+=' && '; fi
  segments_twelve+="echo core/docs/example-$i"
done

c138c_measure_pair core short 'echo ok' 0 plain
c138c_measure_pair core heredoc_40_tokens_4_segments "$heredoc" 0 plain
c138c_measure_pair core npm_install_20 "npm install $packages_twenty" 0 plain
c138c_measure_pair core pnpm_flags_20 "$pnpm_flags" 0 plain
c138c_measure_pair core protected_target_1_token "$protected_one" 2 plain
protected_one_candidate="$C138C_PAIR_CANDIDATE_FORKS"
c138c_measure_pair core protected_target_40_tokens "$protected_forty" 2 plain
protected_forty_candidate="$C138C_PAIR_CANDIDATE_FORKS"
c138c_measure_pair core echo_segments_1 "$segments_one" 0 plain
segments_one_base="$C138C_PAIR_BASE_FORKS"; segments_one_candidate="$C138C_PAIR_CANDIDATE_FORKS"
c138c_measure_pair core echo_segments_12 "$segments_twelve" 0 plain
segments_twelve_base="$C138C_PAIR_BASE_FORKS"; segments_twelve_candidate="$C138C_PAIR_CANDIDATE_FORKS"

[ "$protected_forty_candidate" -le "$((protected_one_candidate + 2))" ] \
  || { echo "FAIL: fork count grows with protected-path target tokens ($protected_one_candidate -> $protected_forty_candidate)" >&2; exit 1; }
[ "$segments_twelve_base" -gt "$((segments_one_base + 10))" ] \
  || { echo "FAIL: pinned source did not expose per-segment process growth ($segments_one_base -> $segments_twelve_base)" >&2; exit 1; }
[ "$segments_twelve_candidate" -le "$((segments_one_candidate + 2))" ] \
  || { echo "FAIL: candidate still forks per shell segment ($segments_one_candidate -> $segments_twelve_candidate)" >&2; exit 1; }
[ "$segments_twelve_candidate" -lt "$segments_twelve_base" ] \
  || { echo 'FAIL: candidate did not reduce the pinned 12-segment process count' >&2; exit 1; }

echo 'block-core-writes-bash-process-budget: PASS'
