#!/usr/bin/env bash
# The release-age guard must not start processes per package or command segment.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
. "$ROOT/core/scripts/tests/hook-process-budget-common.sh"
c138c_init_process_budget

packages_one='pkg1'
packages_twenty=''
for i in $(seq 1 20); do packages_twenty+=" pkg$i"; done
packages_twenty="${packages_twenty# }"

heredoc="cat <<'EOF'"
token=1
for _ in $(seq 1 4); do
  line='echo'
  for _ in $(seq 1 12); do
    line+=" token$token"
    token=$((token + 1))
  done
  heredoc+=$'\n'"$line && echo done"
done
heredoc+=$'\nEOF'

pnpm_flags_one="pnpm add --prefix /home/runner/.local --registry https://registry.npmjs.org --cache /home/runner/.npm --userconfig /home/runner/.npmrc --node-linker hoisted --config.minimumReleaseAge=1440 $packages_one"
pnpm_flags_twenty="pnpm add --prefix /home/runner/.local --registry https://registry.npmjs.org --cache /home/runner/.npm --userconfig /home/runner/.npmrc --node-linker hoisted --config.minimumReleaseAge=1440 $packages_twenty"
pnpm_age_one='pnpm add pkg1'
pnpm_age_twelve=''
for i in $(seq 1 12); do
  if [ "$i" -gt 1 ]; then pnpm_age_twelve+=' && '; fi
  pnpm_age_twelve+="pnpm add pkg$i"
done

c138c_measure_pair unsafe short 'echo ok' 0 plain
c138c_measure_pair unsafe heredoc_48_tokens_4_segments "$heredoc" 0 plain
c138c_measure_pair unsafe npm_install_1 'npm install pkg1' 2 plain
npm_one_candidate="$C138C_PAIR_CANDIDATE_FORKS"
c138c_measure_pair unsafe npm_install_20 "npm install $packages_twenty" 2 plain
npm_twenty_candidate="$C138C_PAIR_CANDIDATE_FORKS"
c138c_measure_pair unsafe pnpm_flags_1 "$pnpm_flags_one" 0 plain
pnpm_flags_one_candidate="$C138C_PAIR_CANDIDATE_FORKS"
c138c_measure_pair unsafe pnpm_flags_20 "$pnpm_flags_twenty" 0 plain
pnpm_flags_twenty_candidate="$C138C_PAIR_CANDIDATE_FORKS"
c138c_measure_pair unsafe pnpm_age_1 "$pnpm_age_one" 0 age
pnpm_age_one_base="$C138C_PAIR_BASE_FORKS"; pnpm_age_one_candidate="$C138C_PAIR_CANDIDATE_FORKS"
if ! c138c_measure_pair unsafe pnpm_age_12_segments "$pnpm_age_twelve" 0 age; then
  cat "$C138C_TMP/unsafe-pnpm_age_12_segments-candidate.err" >&2 || true
  exit 1
fi
pnpm_age_twelve_base="$C138C_PAIR_BASE_FORKS"; pnpm_age_twelve_candidate="$C138C_PAIR_CANDIDATE_FORKS"
c138c_measure_pair unsafe pnpm_unconfigured 'pnpm add pkg1' 2 plain

# A large, ordinary command payload must stay under the hook's registered
# 30-second budget. The old per-character Bash string rebuild exceeded it.
printf -v large_padding '%*s' 35000 ''
large_padding="${large_padding// /x}"
large_node_body="/* npm $large_padding */"
large_command="cd /tmp && node -e '$large_node_body'"
c138c_measure_pair unsafe large_non_heredoc_payload "$large_command" 0 plain 15

[ "$npm_twenty_candidate" -le "$((npm_one_candidate + 2))" ] \
  || { echo "FAIL: fork count grows with npm package tokens ($npm_one_candidate -> $npm_twenty_candidate)" >&2; exit 1; }
[ "$pnpm_flags_twenty_candidate" -le "$((pnpm_flags_one_candidate + 2))" ] \
  || { echo "FAIL: fork count grows with pnpm package tokens ($pnpm_flags_one_candidate -> $pnpm_flags_twenty_candidate)" >&2; exit 1; }
[ "$pnpm_age_twelve_base" -gt "$((pnpm_age_one_base + 10))" ] \
  || { echo "FAIL: pinned source did not expose per-segment process growth ($pnpm_age_one_base -> $pnpm_age_twelve_base)" >&2; exit 1; }
[ "$pnpm_age_twelve_candidate" -le "$((pnpm_age_one_candidate + 2))" ] \
  || { echo "FAIL: candidate still forks per pnpm segment ($pnpm_age_one_candidate -> $pnpm_age_twelve_candidate)" >&2; exit 1; }
[ "$pnpm_age_twelve_candidate" -lt "$pnpm_age_twelve_base" ] \
  || { echo 'FAIL: candidate did not reduce the pinned 12-segment process count' >&2; exit 1; }

# A slow config filesystem is represented by delaying each config-line read.
# The repo lookup is invariant for this session and cwd, so a chained Bash
# command must read the age file once and reuse the answer for later segments
# and later hook calls. The old guard rereads it for every pnpm segment.
slow_read_stub="$C138C_TMP/slow-config-read.sh"
cat > "$slow_read_stub" <<'SH'
read() {
  if [ "${2:-}" = line ]; then sleep 0.18; fi
  builtin read "$@"
}
SH
slow_root="$C138C_TMP/slow-config-hq"
slow_cwd="$C138C_TMP/cwd/age/a/b/c/d/e/f"
slow_root="$C138C_TMP/fixture"
mkdir -p "$slow_root/workspace/orchestrator/hook-state"
printf 'minimum-release-age=1440\n' > "$C138C_TMP/cwd/age/a/.npmrc"
slow_payload="$(jq -cn --arg cmd "$pnpm_age_twelve" '{session_id:"c207-slow-config",tool_name:"Bash",tool_input:{command:$cmd}}')"
slow_run() {
  (cd "$slow_cwd" && printf '%s' "$slow_payload" \
    | timeout 2s env BASH_ENV="$slow_read_stub" HQ_ROOT="$slow_root" CLAUDE_PROJECT_DIR="$slow_root" \
        bash "$ROOT/.claude/hooks/block-unsafe-package-install.sh" >"$C138C_TMP/slow.out" 2>"$C138C_TMP/slow.err")
}
slow_rc=0
slow_run || slow_rc=$?
[ "$slow_rc" -eq 0 ] \
  || { echo "FAIL: release-age config lookup exceeded the 2-second stubbed-read budget (first run rc=$slow_rc)" >&2; exit 1; }
slow_rc=0
slow_run || slow_rc=$?
[ "$slow_rc" -eq 0 ] \
  || { echo "FAIL: cached release-age config lookup exceeded the 2-second budget (second run rc=$slow_rc)" >&2; exit 1; }
printf 'minimum-release-age=1200\n' > "$C138C_TMP/cwd/age/a/.npmrc"
slow_payload="$(jq -cn '{session_id:"c207-slow-config",tool_name:"Bash",tool_input:{command:"pnpm add invalid"}}')"
slow_rc=0
slow_run || slow_rc=$?
[ "$slow_rc" -eq 2 ] \
  || { echo "FAIL: changed .npmrc did not invalidate the cached release-age decision (rc=$slow_rc)" >&2; exit 1; }
echo 'block-unsafe-package-install: PASS (slow config read stub, repeated session/cwd)'

echo 'block-unsafe-package-install-process-budget: PASS'
