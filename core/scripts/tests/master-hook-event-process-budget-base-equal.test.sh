#!/usr/bin/env bash
# Keep no-regression coverage independent from the strict proof of #878.
set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUDGET_TEST="$SCRIPT_DIR/master-hook-event-process-budget.test.sh"
PRE_READ_BUILTIN_SHA=9d6a18898bc6a4725549d7a90c5180881cbe11b3
POST_READ_BUILTIN_BASE_SHA=995eb53409b81eee827b3e340ce33f8829cbe8e4
FIXTURE_ROOT="$SCRIPT_DIR/fixtures/hook-process-budgets"
PRE_READ_FIXTURE="$FIXTURE_ROOT/$PRE_READ_BUILTIN_SHA"
POST_READ_FIXTURE="$FIXTURE_ROOT/$POST_READ_BUILTIN_BASE_SHA"
POST_READ_BUDGET_TEST="$POST_READ_FIXTURE/core/scripts/tests/master-hook-event-process-budget.test.sh"
SOURCE_PATHS=(
  .claude/hooks/master-hook.sh
  .claude/hooks/hook-timeout-probe.sh
  .claude/hooks/hook-timeout-watchdog.sh
  .claude/hooks/hook-gate.sh
  core/scripts/lib/hook-adapter-core.sh
)

fail() { echo "FAIL: $*" >&2; exit 1; }

for fixture_root in "$PRE_READ_FIXTURE" "$POST_READ_FIXTURE"; do
  for relative in "${SOURCE_PATHS[@]}"; do
    [ -f "$fixture_root/$relative" ] || fail "missing hook baseline fixture: $fixture_root/$relative"
  done
done
[ -f "$POST_READ_BUDGET_TEST" ] || fail "missing base budget test fixture: $POST_READ_BUDGET_TEST"

TMP_DIR="$(mktemp -d)"
BASE_BUDGET_TEST=""
cleanup() {
  rm -rf "$TMP_DIR"
  [ -z "$BASE_BUDGET_TEST" ] || rm -f "$BASE_BUDGET_TEST"
}
trap cleanup EXIT

run_budget() {
  local base_sha="$1" source_root="${2:-$ROOT}" base_source_root="${3:-}" output
  if ! output="$(HQ_HOOK_PERF_BASE_SHA="$base_sha" \
    HQ_HOOK_PERF_BASE_SOURCE_ROOT="$base_source_root" \
    HQ_HOOK_PERF_SOURCE_ROOT="$source_root" timeout 240s bash "$BUDGET_TEST" 2>&1)"; then
    printf '%s\n' "$output"
    fail "process-budget test failed with base $base_sha and source $source_root"
  fi
  printf '%s\n' "$output"
}

run_budget_expect_rejection() {
  local base_sha="$1" source_root="$2" expected_text="$3" budget_test="${4:-$BUDGET_TEST}"
  local path_prefix="${5:-}" output
  if output="$(PATH="${path_prefix:+$path_prefix:}$PATH" \
    HQ_HOOK_PERF_BASE_SHA="$base_sha" \
    HQ_HOOK_PERF_SOURCE_ROOT="$source_root" \
    HQ_HOOK_PERF_FIXTURE_GIT_ROOT="$ROOT" \
    HQ_HOOK_PERF_FIXTURE_BASE_SHA="$POST_READ_BUILTIN_BASE_SHA" \
    HQ_HOOK_PERF_FIXTURE_BASE_ROOT="$POST_READ_FIXTURE" \
    HQ_HOOK_PERF_REAL_GIT="$REAL_GIT" timeout 240s bash "$budget_test" 2>&1)"; then
    printf '%s\n' "$output"
    fail "expected process-budget rejection with base $base_sha and source $source_root"
  fi
  case "$output" in
    *"$expected_text"*) ;;
    *) printf '%s\n' "$output"; fail "budget rejection did not contain '$expected_text'" ;;
  esac
  printf '%s\n' "$output"
}

budget_line() {
  local output="$1" event="$2" line
  line="$(printf '%s\n' "$output" | awk -v event="$event" \
    'index($0, event ": execve base=") == 1 { line = $0 } END { print line }')"
  [ -n "$line" ] || fail "missing measured $event process counts in output"
  printf '%s\n' "$line"
}

count_from_line() {
  local line="$1" field="$2" value
  if [ "$field" = base ]; then
    value="$(printf '%s\n' "$line" | sed -E 's/.*execve base=([0-9]+) candidate=([0-9]+);.*/\1/')"
  else
    value="$(printf '%s\n' "$line" | sed -E 's/.*execve base=([0-9]+) candidate=([0-9]+);.*/\2/')"
  fi
  [[ "$value" =~ ^[0-9]+$ ]] || fail "could not parse measured process counts: $line"
  printf '%s\n' "$value"
}

strict_session_reduction_passes() {
  local line="$1" base_execs candidate_execs
  base_execs="$(count_from_line "$line" base)"
  candidate_execs="$(count_from_line "$line" candidate)"
  [ "$candidate_execs" -lt "$base_execs" ]
}

copy_hook_sources() {
  local source_root="$1" relative
  mkdir -p "$source_root"
  for relative in "${SOURCE_PATHS[@]}"; do
    mkdir -p "$source_root/${relative%/*}"
    cp "$ROOT/$relative" "$source_root/$relative"
  done
}

replace_stdin_read_with_cat() {
  local source_file="$1" replacement_file="$1.c194-mutant" line replaced=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "IFS= read -r -d '' INPUT || true" ]; then
      printf '%s\n' 'INPUT="$(cat)"' >> "$replacement_file"
      replaced=$((replaced + 1))
    else
      printf '%s\n' "$line" >> "$replacement_file"
    fi
  done < "$source_file"
  [ "$replaced" -eq 1 ] || fail "stdin-read mutant changed $replaced source lines in $source_file"
  mv "$replacement_file" "$source_file"
}

candidate_sha="$(timeout 20s git -C "$ROOT" rev-parse HEAD)"

# The base-equal run uses the general no-regression budget, with the strict
# SessionStart reduction asserted independently below for the pre-#878 base.
same_base_output="$(run_budget "$candidate_sha")"
printf '%s\n' "$same_base_output"
case "$same_base_output" in
  *'PreToolUse: hook sources unchanged from base; requiring no regression'*) ;;
  *) fail 'base-equal PreToolUse run did not exercise no-regression with measured counts' ;;
esac
case "$same_base_output" in
  *'SessionStart: hook sources unchanged from base; requiring no regression'*) ;;
  *) fail 'base-equal SessionStart run did not exercise no-regression with measured counts' ;;
esac

# A comment-only change proves that changed sources may keep equal counts. The
# old 995eb534 gate must reject this same measured case; the candidate must pass.
comment_source="$TMP_DIR/comment-source"
copy_hook_sources "$comment_source"
printf '\n# c194 no-op source change fixture\n' >> "$comment_source/.claude/hooks/master-hook.sh"
changed_equal_output="$(run_budget "$candidate_sha" "$comment_source")"
case "$changed_equal_output" in
  *'PreToolUse: hook sources changed from base; requiring no regression'*) ;;
  *) fail 'comment-only PreToolUse fixture did not exercise changed-source no-regression' ;;
esac
case "$changed_equal_output" in
  *'SessionStart: hook sources changed from base; requiring no regression'*) ;;
  *) fail 'comment-only SessionStart fixture did not exercise changed-source no-regression' ;;
esac
for event in PreToolUse SessionStart; do
  line="$(budget_line "$changed_equal_output" "$event")"
  base_execs="$(count_from_line "$line" base)"
  candidate_execs="$(count_from_line "$line" candidate)"
  [ "$candidate_execs" -eq "$base_execs" ] \
    || fail "comment-only $event fixture did not keep execve counts equal ($line)"
  echo "PASS: comment-only changed-source $event counts are equal ($line)"
done

BASE_BUDGET_TEST="$SCRIPT_DIR/.master-hook-event-process-budget.base-$$.test.sh"
LEGACY_GIT_SHIM_DIR="$TMP_DIR/legacy-git-bin"
REAL_GIT="$(type -P git || true)"
[ -n "$REAL_GIT" ] || fail 'git is required for the legacy budget-test fixture adapter'
mkdir -p "$LEGACY_GIT_SHIM_DIR"
cp "$POST_READ_BUDGET_TEST" "$BASE_BUDGET_TEST"
# The historical test expects its 995eb534 git object to exist. Route only
# that baseline's cat-file/show calls to the checked-in fixture, preserving
# the original strict-threshold assertions while remaining history-independent.
cat > "$LEGACY_GIT_SHIM_DIR/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "$HQ_HOOK_PERF_FIXTURE_GIT_ROOT" ]; then
  if [ "${3:-}" = cat-file ] && [ "${4:-}" = -e ] \
    && [ "${5:-}" = "$HQ_HOOK_PERF_FIXTURE_BASE_SHA^{commit}" ]; then
    [ -d "$HQ_HOOK_PERF_FIXTURE_BASE_ROOT" ] && exit 0
    exit 1
  fi
  if [ "${3:-}" = show ] && [[ "${4:-}" == "$HQ_HOOK_PERF_FIXTURE_BASE_SHA:"* ]]; then
    relative="${4#*:}"
    [ -f "$HQ_HOOK_PERF_FIXTURE_BASE_ROOT/$relative" ] \
      || { echo "missing fixture baseline path: $relative" >&2; exit 128; }
    cat "$HQ_HOOK_PERF_FIXTURE_BASE_ROOT/$relative"
    exit $?
  fi
fi
exec "$HQ_HOOK_PERF_REAL_GIT" "$@"
SH
chmod +x "$LEGACY_GIT_SHIM_DIR/git"
legacy_output="$(run_budget_expect_rejection "$POST_READ_BUILTIN_BASE_SHA" \
  "$comment_source" 'did not reduce execve count' "$BASE_BUDGET_TEST" \
  "$LEGACY_GIT_SHIM_DIR" 2>&1)"
legacy_line="$(budget_line "$legacy_output" PreToolUse)"
legacy_base_execs="$(count_from_line "$legacy_line" base)"
legacy_candidate_execs="$(count_from_line "$legacy_line" candidate)"
[ "$legacy_candidate_execs" -eq "$legacy_base_execs" ] \
  || fail "995eb534 did not reject an equal-count changed-source case ($legacy_line)"
echo "PASS: 995eb534 rejects equal-count changed sources ($legacy_line)"

# The pre-#878 case proves the optimization with a strict SessionStart budget,
# independently of the general changed-source no-regression rule.
pre_change_output="$(run_budget "$PRE_READ_BUILTIN_SHA" "$ROOT" "$PRE_READ_FIXTURE")"
printf '%s\n' "$pre_change_output"
pre_change_line="$(budget_line "$pre_change_output" SessionStart)"
if ! strict_session_reduction_passes "$pre_change_line"; then
  fail "pre-#878 base did not observe strict SessionStart reduction ($pre_change_line)"
fi
pre_base_execs="$(count_from_line "$pre_change_line" base)"
pre_candidate_execs="$(count_from_line "$pre_change_line" candidate)"
echo "PASS: pre-#878 strict SessionStart reduction (execve base=$pre_base_execs candidate=$pre_candidate_execs)"

# Kill the stdin-read revert under both independent budgets: no-regression at
# base=HEAD and the pre-#878 strict SessionStart assertion above.
stdin_mutant_source="$TMP_DIR/stdin-mutant-source"
copy_hook_sources "$stdin_mutant_source"
replace_stdin_read_with_cat "$stdin_mutant_source/.claude/hooks/master-hook.sh"
mutant_head_output="$(run_budget_expect_rejection "$candidate_sha" "$stdin_mutant_source" \
  'PreToolUse increased execve count')"
mutant_head_line="$(budget_line "$mutant_head_output" PreToolUse)"
mutant_head_base_execs="$(count_from_line "$mutant_head_line" base)"
mutant_head_candidate_execs="$(count_from_line "$mutant_head_line" candidate)"
[ "$mutant_head_candidate_execs" -gt "$mutant_head_base_execs" ] \
  || fail "base=HEAD did not expose the stdin-read regression ($mutant_head_line)"
echo "PASS: stdin-read revert fails base=HEAD no-regression ($mutant_head_line)"

mutant_pre_output="$(run_budget "$PRE_READ_BUILTIN_SHA" "$stdin_mutant_source" "$PRE_READ_FIXTURE")"
printf '%s\n' "$mutant_pre_output"
mutant_pre_line="$(budget_line "$mutant_pre_output" SessionStart)"
if strict_session_reduction_passes "$mutant_pre_line"; then
  fail "stdin-read revert survived the pre-#878 strict assertion ($mutant_pre_line)"
fi
mutant_pre_base_execs="$(count_from_line "$mutant_pre_line" base)"
mutant_pre_candidate_execs="$(count_from_line "$mutant_pre_line" candidate)"
echo "PASS: stdin-read revert fails pre-#878 strict SessionStart (execve base=$mutant_pre_base_execs candidate=$mutant_pre_candidate_execs)"
