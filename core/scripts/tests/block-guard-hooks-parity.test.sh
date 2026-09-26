#!/usr/bin/env bash
# Replay every existing fixture suite and hook YAML case against pinned and
# candidate guard sources, comparing each invocation's input, exit, stdout, and
# stderr. The source test files remain unchanged.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
REAL_BASH="$(command -v bash)"
ORIGINAL_PATH="$PATH"
. "$ROOT/core/scripts/tests/hook-process-budget-common.sh"
c138c_init_process_budget

ln -s "$C138C_TMP/cwd/age" "$C138C_TMP/cwd/age-symlink"
ln -s "$C138C_TMP/cwd/plain" "$C138C_TMP/cwd/plain-symlink"

for variant in base candidate; do
  mkdir -p "$C138C_TMP/source/$variant/core/scripts"
  cp "$C138C_TMP/fixture/core/scripts/hook-lib.sh" \
    "$C138C_TMP/source/$variant/core/scripts/hook-lib.sh"
  cp "$C138C_TMP/fixture/core/scripts/install-deps.allow" \
    "$C138C_TMP/source/$variant/core/scripts/install-deps.allow"
done

mkdir -p "$C138C_TMP/wrapper"
cat > "$C138C_TMP/wrapper/bash" <<'WRAPPER'
#!/bin/bash
set -uo pipefail
real_bash="${HQ_PARITY_REAL_BASH:-/bin/bash}"
args=("$@")
target_index=-1
target_kind=""
for i in "${!args[@]}"; do
  case "${args[$i]##*/}" in
    block-unsafe-package-install.sh) target_index="$i"; target_kind=unsafe; break ;;
    block-core-writes-bash.sh) target_index="$i"; target_kind=core; break ;;
  esac
done
if [ "$target_index" -lt 0 ]; then
  exec "$real_bash" "$@"
fi

count_file="$HQ_PARITY_RECORD_ROOT/count"
count=0
if [ -f "$count_file" ]; then read -r count < "$count_file"; fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
record="$HQ_PARITY_RECORD_ROOT/$count"
mkdir -p "$record/base" "$record/candidate"
printf '%s\n' "$target_kind" > "$record/hook"
cat > "$record/input"
base_args=("${args[@]}")
candidate_args=("${args[@]}")
case "$target_kind" in
  unsafe)
    base_args[$target_index]="$HQ_PARITY_UNSAFE_BASE_HOOK"
    candidate_args[$target_index]="$HQ_PARITY_UNSAFE_CANDIDATE_HOOK"
    ;;
  core)
    base_args[$target_index]="$HQ_PARITY_CORE_BASE_HOOK"
    candidate_args[$target_index]="$HQ_PARITY_CORE_CANDIDATE_HOOK"
    ;;
esac
env HQ_TEST_OPERATION_LOG=/dev/null HQ_TEST_GREP_CALLS=/dev/null HQ_TEST_SED_CALLS=/dev/null \
  "$real_bash" "${base_args[@]}" < "$record/input" \
  > "$record/base/stdout" 2> "$record/base/stderr"
base_rc=$?
printf '%s\n' "$base_rc" > "$record/base/exit"
"$real_bash" "${candidate_args[@]}" < "$record/input" > "$record/candidate/stdout" 2> "$record/candidate/stderr"
candidate_rc=$?
printf '%s\n' "$candidate_rc" > "$record/candidate/exit"
for field in stdout stderr exit; do
  cmp -s "$record/base/$field" "$record/candidate/$field" || {
    printf 'FAIL: %s guard differs on fixture invocation %s (%s)\n' "$target_kind" "$count" "$field" >&2
    exit 1
  }
done
cat "$record/candidate/stdout"
cat "$record/candidate/stderr" >&2
exit "$candidate_rc"
WRAPPER
chmod +x "$C138C_TMP/wrapper/bash"

run_fixture_suites() {
  local test_file rc
  local record_root="$C138C_TMP/records"
  local bin="$C138C_TMP/bin"
  local tmp="$C138C_TMP/suite-tmp"
  mkdir -p "$bin" "$record_root" "$tmp"
  PATH="$bin:$PATH"
  ln -sf "$C138C_TMP/wrapper/bash" "$bin/bash"
  export PATH
  export BASH_ENV=/dev/null
  export HQ_PARITY_REAL_BASH="$REAL_BASH"
  export HQ_PARITY_RECORD_ROOT="$record_root"
  export HQ_PARITY_UNSAFE_BASE_HOOK="$C138C_TMP/source/base/.claude/hooks/block-unsafe-package-install.sh"
  export HQ_PARITY_UNSAFE_CANDIDATE_HOOK="$C138C_TMP/source/candidate/.claude/hooks/block-unsafe-package-install.sh"
  export HQ_PARITY_CORE_BASE_HOOK="$C138C_TMP/source/base/.claude/hooks/block-core-writes-bash.sh"
  export HQ_PARITY_CORE_CANDIDATE_HOOK="$C138C_TMP/source/candidate/.claude/hooks/block-core-writes-bash.sh"
  export TMPDIR="$tmp"

  for test_file in \
    .claude/hooks/tests/block-unsafe-package-install.test.sh \
    core/scripts/tests/block-unsafe-package-install.test.sh \
    core/scripts/tests/block-core-writes-bash.test.sh \
    core/scripts/tests/block-core-writes-bash-fast-path.test.sh \
    core/scripts/tests/block-core-writes-bash-fanout.test.sh; do
    if timeout 180s "$REAL_BASH" "$ROOT/$test_file" \
        > "$C138C_TMP/${test_file##*/}.out" \
        2> "$C138C_TMP/${test_file##*/}.err"; then
      rc=0
    else
      rc=$?
    fi
    [ "$rc" -eq 0 ] || {
      printf 'FAIL: %s fixture suite exited %s\n' "$test_file" "$rc" >&2
      cat "$C138C_TMP/${test_file##*/}.err" >&2
      cat "$C138C_TMP/${test_file##*/}.out" >&2
      return 1
    }
  done
}

run_fixture_suites
PATH="$ORIGINAL_PATH"
export PATH
unset HQ_PARITY_REAL_BASH HQ_PARITY_RECORD_ROOT HQ_PARITY_UNSAFE_BASE_HOOK \
  HQ_PARITY_UNSAFE_CANDIDATE_HOOK HQ_PARITY_CORE_BASE_HOOK HQ_PARITY_CORE_CANDIDATE_HOOK

fixture_count="$(cat "$C138C_TMP/records/count")"

# Check adversarial command shapes against the same pinned/candidate pair. The
# helper compares exit, stdout, and stderr for every pair; cases with an
# explicit exit also prove the expected deny or allow remains in place.
adversarial_count=0
run_adversarial_pair() {
  c138c_measure_pair "$@"
  adversarial_count=$((adversarial_count + 1))
}

prefix_quoted="$C138C_TMP/prefix with space/\"quoted\""
prefix_real="$C138C_TMP/prefix-real"
prefix_symlink="$C138C_TMP/prefix symlink with space/\"target\""
env_prefix="$C138C_TMP/env prefix with space/\"quoted\""
mkdir -p "$prefix_quoted" "$prefix_real"
mkdir -p "${prefix_symlink%/*}"
ln -s "$prefix_real" "$prefix_symlink"

run_adversarial_pair unsafe adversarial_prefix_quoted_space_and_quote \
  "npm install -g --prefix '$prefix_quoted' left-pad" 2 plain
run_adversarial_pair unsafe adversarial_prefix_equals_quoted_space_and_quote \
  "npm install -g --prefix='$prefix_quoted' left-pad" 2 plain
run_adversarial_pair unsafe adversarial_prefix_symlink \
  "pnpm add --dir '$prefix_symlink' left-pad" 2 plain
run_adversarial_pair unsafe adversarial_env_assignment_untrusted \
  'FOO=bar npm install left-pad' 2 plain
run_adversarial_pair unsafe adversarial_env_assignment_quoted_prefix \
  "NPM_CONFIG_PREFIX='$env_prefix' npm install left-pad" parity plain
run_adversarial_pair unsafe adversarial_env_wrapper_untrusted \
  'env FOO=bar pnpm add left-pad' 0 plain
run_adversarial_pair unsafe adversarial_env_assignment_first_party \
  'FOO=bar npm install -g @indigoai-us/hq-cli@5.109.8' 0 plain
run_adversarial_pair unsafe adversarial_and_chain \
  'npm install left-pad && echo complete' 2 plain
# Use true/false first segments so the text-wrapper fast path does not bypass
# separator parsing before the later install is checked.
run_adversarial_pair unsafe adversarial_later_segment_and \
  'true && npm install left-pad' 2 plain
run_adversarial_pair unsafe adversarial_semicolon_chain \
  'npm install left-pad; echo complete' 2 plain
run_adversarial_pair unsafe adversarial_later_segment_semicolon \
  'true; npm install left-pad' 2 plain
run_adversarial_pair unsafe adversarial_leading_semicolon \
  ';npm install left-pad' 2 plain
run_adversarial_pair unsafe adversarial_or_chain \
  'npm install left-pad || echo complete' 2 plain
run_adversarial_pair unsafe adversarial_later_segment_or \
  'false || npm install left-pad' 2 plain
run_adversarial_pair unsafe adversarial_pipe_chain \
  'npm install left-pad | cat' 2 plain
run_adversarial_pair unsafe adversarial_subshell \
  '( npm install left-pad )' parity plain
run_adversarial_pair unsafe adversarial_command_substitution \
  'echo "$(npm install left-pad)"' parity plain
run_adversarial_pair unsafe adversarial_heredoc_literal \
  $'cat <<\'EOF\'\nnpm install left-pad\nEOF' parity plain
run_adversarial_pair unsafe adversarial_symlink_cwd_age_gate \
  'pnpm add left-pad' 0 age-symlink
run_adversarial_pair unsafe adversarial_symlink_cwd_without_age_gate \
  'pnpm add left-pad' 2 plain-symlink

core_target_single_quote="$C138C_TMP/fixture/core/adversarial space/'single'.txt"
core_target_double_quote="$C138C_TMP/fixture/core/adversarial space/\"double\".txt"
core_target="$C138C_TMP/fixture/core/adversarial-target.txt"
outside_target="$C138C_TMP/fixture/outside-target"
mkdir -p "$outside_target"
ln -s "$outside_target" "$C138C_TMP/fixture/core/linked-outside"
ln -s "$C138C_TMP/fixture/core" "$C138C_TMP/fixture/core-via-symlink"
core_linked_outside="$C138C_TMP/fixture/core/linked-outside/file.txt"
core_linked_inside="$C138C_TMP/fixture/core-via-symlink/file.txt"

run_adversarial_pair core adversarial_quoted_space_and_single_quote \
  "touch \"$core_target_single_quote\"" 2 plain
run_adversarial_pair core adversarial_quoted_space_and_double_quote \
  "touch '$core_target_double_quote'" 2 plain
run_adversarial_pair core adversarial_symlink_inside_core_to_outside \
  "touch '$core_linked_outside'" 2 plain
run_adversarial_pair core adversarial_symlink_outside_to_core \
  "touch '$core_linked_inside'" parity plain
run_adversarial_pair core adversarial_env_assignment_prefix \
  "FOO=bar touch '$core_target'" 2 plain
run_adversarial_pair core adversarial_env_wrapper_prefix \
  "env FOO=bar touch '$core_target'" 2 plain
run_adversarial_pair core adversarial_env_empty_environment \
  'env -i rm core/adversarial-target.txt' 2 fixture
run_adversarial_pair core adversarial_and_chain \
  "echo before && touch '$core_target'" 2 plain
run_adversarial_pair core adversarial_semicolon_chain \
  "echo before; touch '$core_target'" 2 plain
run_adversarial_pair core adversarial_or_chain \
  "false || touch '$core_target'" 2 plain
run_adversarial_pair core adversarial_sudo_prefix \
  "sudo touch '$core_target'" 2 plain
run_adversarial_pair core adversarial_command_prefix \
  "command touch '$core_target'" 2 plain
run_adversarial_pair core adversarial_pipe_chain \
  "printf x | tee '$core_target'" 2 plain
run_adversarial_pair core adversarial_subshell \
  "( touch '$core_target' )" parity plain
run_adversarial_pair core adversarial_command_substitution \
  "echo \"\$(touch '$core_target')\"" parity plain
run_adversarial_pair core adversarial_heredoc_literal \
  $'cat <<\'EOF\'\ntouch core/adversarial-target.txt\nEOF' parity plain
run_adversarial_pair core adversarial_heredoc_then_write \
  $'cat <<\'EOF\'\nbody\nEOF\ntouch core/adversarial-target.txt' parity plain
run_adversarial_pair core adversarial_prefix_spaced_value_chain \
  "npm install --prefix '$prefix_quoted' left-pad && touch '$core_target'" 2 plain
run_adversarial_pair core adversarial_prefix_equals_value_chain \
  "npm install --prefix='$prefix_quoted' left-pad; touch '$core_target'" 2 plain

# Replay each declarative YAML hook case too. These are the complete current
# case sets in core/hook-tests for the two guards.
c138c_measure_pair unsafe yaml_blocks_npm_package 'npm install lodash' 2 plain
c138c_measure_pair unsafe yaml_allows_hydration 'npm install' 0 plain
c138c_measure_pair unsafe yaml_allows_npm_ci 'npm ci' 0 plain
c138c_measure_pair core yaml_blocks_agents_redirect 'echo pwned > AGENTS.md' 2 plain
c138c_measure_pair core yaml_blocks_core_redirect 'echo pwned > core/FAILOPEN-PROBE.txt' 2 plain
c138c_measure_pair core yaml_allows_benign 'echo hello world' 0 plain

# The manager-owned c138e cases are parity-only against current main. All
# preceding denial expectations use the pinned pre-optimization baseline.
# Compare only the c138e known-gap cases with the current PR base; keep
# process-budget suites on their pinned c138c baseline.
C138D_BASE_SHA="$(git -C "$ROOT" rev-parse refs/remotes/origin/main)"
timeout 20s git -C "$ROOT" cat-file -e "$C138D_BASE_SHA^{commit}" \
  || { echo "FAIL: current PR base is unavailable: $C138D_BASE_SHA" >&2; exit 1; }
for relative in \
  .claude/hooks/block-unsafe-package-install.sh \
  .claude/hooks/block-core-writes-bash.sh; do
  timeout 20s git -C "$ROOT" show "$C138D_BASE_SHA:$relative" \
    > "$C138C_TMP/source/base/$relative" \
    || { echo "FAIL: current PR base is missing $relative" >&2; exit 1; }
done
timeout 20s git -C "$ROOT" show "$C138D_BASE_SHA:core/scripts/hook-lib.sh" \
  > "$C138C_TMP/fixture/core/scripts/hook-lib.sh" \
  || { echo 'FAIL: current PR base is missing core/scripts/hook-lib.sh' >&2; exit 1; }
timeout 20s git -C "$ROOT" show "$C138D_BASE_SHA:core/scripts/install-deps.allow" \
  > "$C138C_TMP/fixture/core/scripts/install-deps.allow" \
  || { echo 'FAIL: current PR base is missing core/scripts/install-deps.allow' >&2; exit 1; }

# Manager-owned c138e gap: preserve and record current-main parity for these
# env-unset forms. They intentionally carry no base-deny expectation here.
run_adversarial_pair core KNOWN_GAP_c138e_env_u_FOO \
  'env -u FOO rm core/adversarial-target.txt' parity fixture
run_adversarial_pair core KNOWN_GAP_c138e_env_assignment_then_u_BAR \
  'env FOO=1 -u BAR rm core/adversarial-target.txt' parity fixture

printf 'block-guard-hooks-parity: PASS (%s existing hook invocations, %s adversarial cases, and six YAML cases)\n' \
  "$fixture_count" "$adversarial_count"
