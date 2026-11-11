#!/usr/bin/env bash
# hq-core: public
# Regression coverage for the fail-open repo merge-hold PreToolUse shim.

set -uo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/lanes-repo-merge-hold.sh"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
MASTER="$ROOT/.claude/hooks/master-hook.sh"
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
CODEX_ADAPTER="$ROOT/.codex/hooks/hq-codex-hook-adapter.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lanes-hold-check-shim.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

for tool in bash jq mktemp perl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: required test tool missing: $tool" >&2; exit 1; }
done

BIN="$TMP/bin"
mkdir -p "$BIN"
TEST_PATH="$BIN:$PATH"
# HQ_HOLD_TEST_BASH forces the hook, and any bash master or gate spawn from
# this PATH, onto one interpreter. Unset keeps the bash on PATH.
if [ -n "${HQ_HOLD_TEST_BASH:-}" ]; then
  case "$HQ_HOLD_TEST_BASH" in
    /*) ln -sf "$HQ_HOLD_TEST_BASH" "$BIN/bash" ;;
    *) ln -sf "$(command -v "$HQ_HOLD_TEST_BASH")" "$BIN/bash" ;;
  esac
fi
pass=0
fail=0
LAST_RC=0
LAST_OUT=""
LAST_ERR=""

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1" >&2; }

cat > "$BIN/hq" <<'SH'
#!/usr/bin/env bash
if [ "${HQ_NO_UPDATE_CHECK:-}" != "1" ]; then
  printf 'HQ_NO_UPDATE_CHECK missing\n' >&2
  exit 97
fi
printf 'called\n' >> "$HQ_HOLD_TEST_CALL_FILE"
printf '%s\0' "$@" >> "$HQ_HOLD_TEST_ARGV_FILE"
if [ -n "${HQ_HOLD_TEST_SLEEP:-}" ]; then
  exec sleep "$HQ_HOLD_TEST_SLEEP"
fi
printf '%s' "${HQ_HOLD_TEST_STDOUT:-}"
printf '%s' "${HQ_HOLD_TEST_STDERR:-}" >&2
exit "${HQ_HOLD_TEST_EXIT:-0}"
SH
chmod +x "$BIN/hq"

clear_stub_receipts() {
  : > "$TMP/calls"
  : > "$TMP/argv"
}

payload() {
  local root="${2:-$ROOT}"
  jq -nc --arg cmd "$1" --arg root "$root" \
    '{session_id:"lanes-hold-check-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,tool_input:{command:$cmd}}'
}

# invoke_direct <command> [ENV=value ...]
invoke_direct() {
  local command_text="$1" rc=0 input
  shift
  clear_stub_receipts
  input="$(payload "$command_text")"
  printf '%s' "$input" \
    | env "PATH=$TEST_PATH" \
        "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
        "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" \
        "$@" bash "$HOOK" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  LAST_RC="$rc"
  LAST_OUT="$(cat "$TMP/stdout")"
  LAST_ERR="$(cat "$TMP/stderr")"
}

invoke_raw() {
  local input="$1" rc=0
  shift
  clear_stub_receipts
  printf '%s' "$input" \
    | env "PATH=$TEST_PATH" \
        "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
        "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" \
        "$@" bash "$HOOK" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  LAST_RC="$rc"
  LAST_OUT="$(cat "$TMP/stdout")"
  LAST_ERR="$(cat "$TMP/stderr")"
}

has_one_named_diagnostic() {
  local lines
  [ -n "$LAST_ERR" ] || return 1
  lines="$(printf '%s\n' "$LAST_ERR" | wc -l | tr -d '[:space:]')"
  [ "$lines" = 1 ] && [[ "$LAST_ERR" == lanes-repo-merge-hold:* ]]
}

HOLD_JSON='{"ok":false,"error":"repo_merge_held","repo":"acme/widgets","reason":"incident freeze","until":"2026-10-01T12:00:00Z"}'

echo '[1] non-merge commands pass without invoking hq'
invoke_direct 'git status'
if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && [ -z "$LAST_ERR" ] && [ ! -s "$TMP/calls" ]; then
  ok 'non-merge command is silent and does not call hq'
else
  bad "non-merge command is silent and does not call hq (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

echo '[1b] shell-quoted merge tokens still reach hq-cli'
invoke_direct 'gh pr m"erge" 5 -R acme/widgets --squash' \
  'HQ_HOLD_TEST_EXIT=3' "HQ_HOLD_TEST_STDOUT=$HOLD_JSON"
if [ "$LAST_RC" = 0 ] && [ -s "$TMP/calls" ] \
  && jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$LAST_OUT" >/dev/null 2>&1; then
  ok 'double-quoted token concatenation reaches hq and denies'
else
  bad "double-quoted token concatenation reaches hq and denies (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

for quoted_command in \
  "gh pr m'er'ge 5 -R acme/widgets --squash" \
  'gh pr me\rge 5 -R acme/widgets --squash'; do
  invoke_direct "$quoted_command" \
    'HQ_HOLD_TEST_EXIT=3' "HQ_HOLD_TEST_STDOUT=$HOLD_JSON"
  if [ "$LAST_RC" = 0 ] && [ -s "$TMP/calls" ] \
    && jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$LAST_OUT" >/dev/null 2>&1; then
    ok "shell-escaped token reaches hq and denies ($quoted_command)"
  else
    bad "shell-escaped token reaches hq and denies ($quoted_command; rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
  fi
done

invoke_direct 'mkdir -p /tmp/every/rg/e'
if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && [ -z "$LAST_ERR" ] && [ ! -s "$TMP/calls" ]; then
  ok 'ordered letters spread across words do not start hq'
else
  bad "ordered letters spread across words do not start hq (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

echo '[1d] merge-word prefilter: real merges reach hq, field names and prose skip it'
# hq-cli counts a command as a merge only when a shell word is exactly
# "merge", a word ends in "/merge", or a word contains "mergePullRequest".
# Every form below must still reach hq. Most are merges to hq-cli; a few
# (uppercase, $(...), backticks, hq lanes merge) are deliberately wider than
# its parser. The skip list holds "merge" inside a longer word (mergeable,
# mergeStateStatus, merged, --merges, unmerged), which hq-cli never treats as
# a merge.
NBSP="$(printf '\302\240')"
LSEP="$(printf '\342\200\250')"
IDSP="$(printf '\343\200\200')"
TAB="$(printf '\t')"
CR="$(printf '\r')"
LF='
'
merge_reach_corpus=(
  'gh pr merge 5 -R acme/widgets --squash'
  'gh pr merge https://github.com/acme/widgets/pull/9'
  'gh -R acme/widgets pr merge 5'
  'gh pr --repo acme/widgets merge 5 --admin'
  'git merge topic'
  'git -C /tmp/x merge --ff-only origin/main'
  'hq lanes merge acme/widgets 5'
  'gh api -X PUT repos/acme/widgets/pulls/5/merge'
  'gh api --method PUT /repos/acme/widgets/pulls/5/merge -f sha=abc'
  'gh api -X PUT https://api.github.com/repos/acme/widgets/pulls/5/merge/'
  "gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
  'gh api graphql -f query=mutation{MergePullRequest}'
  'gh pr m"erge" 5 -R acme/widgets'
  "gh pr m'er'ge 5 -R acme/widgets"
  'gh pr me\rge 5 -R acme/widgets'
  'gh pr "merge" 5'
  "gh pr 'merge' 5"
  'gh pr mer""ge 5'
  'gh pr \merge 5'
  'gh pr merg"e" 5'
  "gh pr m''e''r''g''e 5"
  'gh api -X PUT repos/acme/widgets/pulls/5/"merge"'
  'gh api graphql -f query=merge"PullRequest"'
  'gh pr"merge 5'
  "gh pr'merge 5"
  'cd /tmp && gh pr merge 5'
  'true; gh pr merge 5'
  'true;gh pr merge 5'
  'echo hi | gh pr merge 5'
  'echo hi|git merge topic'
  'false || gh pr merge 5'
  'x=$(gh pr merge 5)'
  'x=$(git merge topic)'
  'echo `gh pr merge 5`'
  'echo `git merge`'
  "ls${LF}gh pr merge 5"
  "ls${CR}${LF}git merge topic"
  "gh${TAB}pr${TAB}merge 5"
  "git${NBSP}merge topic"
  "git${LSEP}merge topic"
  "git${IDSP}merge topic"
  'gh pr merge 5 -R acme/widgets "unterminated'
  "gh api -X PUT repos/acme/widgets/pulls/5/MERGE '"
  'gh api graphql -f query=MERGEPULLREQUEST "'
  "gh pr \\${LF} merge 5 -R acme/widgets"
  "bash -c 'gh pr merge 5'"
  "bash -lc 'gh pr merge 5'"
  'sh -c "git merge topic"'
  "sh -c 'gh pr m\"erge\" 5'"
  "bash -c \"bash -c 'gh pr merge 5'\""
  'env -i PATH=/usr/bin gh pr merge 5'
  'timeout 30 gh pr merge 5'
  'nice -n 5 gh pr merge 5'
  'sudo -u bot gh pr merge 5'
  'command gh pr merge 5'
  'nohup git merge topic'
  'FOO=1 gh pr merge 5'
  'gh pr merge 5 && echo done'
  'gh pr merge 5;echo done'
  'gh pr merge 5|cat'
  'gh pr merge'
  'git MERGE topic'
  'GH PR Merge 5'
  "g'it' merge topic"
  'g\it merge topic'
)
merge_skip_corpus=(
  'gh pr list --json number,mergeable,mergeStateStatus'
  'gh pr list -R acme/widgets --state open --limit 20 --json number,title,mergeable'
  'gh pr view 5 --json mergeable'
  'gh pr view 5 --json mergeStateStatus -q .mergeStateStatus'
  'gh pr view 5 --json mergedAt,mergedBy -q .mergedAt'
  "gh pr view 5 --json \"mergeable\""
  'gh pr list --search is:merged'
  'git log --merges --oneline'
  'git branch --no-merged main'
  'git branch --merged'
  'echo merged into main'
  "cat <<'EOF'${LF}The branch was merged and is mergeable.${LF}EOF"
  "jq '.mergeable' pr.json"
  'grep -n mergeStateStatus file.ts'
  'echo unmerged mergers emerge'
  'ls /tmp/submerged'
  'git status'
)
reach_ok=0
for merge_command in "${merge_reach_corpus[@]}"; do
  invoke_direct "$merge_command" 'HQ_HOLD_TEST_EXIT=0' 'HQ_HOLD_TEST_STDOUT={"ok":true}'
  if [ "$LAST_RC" = 0 ] && [ -s "$TMP/calls" ]; then
    reach_ok=$((reach_ok + 1))
  else
    bad "merge form reaches hq: $merge_command (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
  fi
done
if [ "$reach_ok" -eq "${#merge_reach_corpus[@]}" ]; then
  ok "all ${#merge_reach_corpus[@]} merge forms reach hq"
fi
skip_ok=0
for other_command in "${merge_skip_corpus[@]}"; do
  invoke_direct "$other_command"
  if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && [ -z "$LAST_ERR" ] && [ ! -s "$TMP/calls" ]; then
    skip_ok=$((skip_ok + 1))
  else
    bad "non-merge mention skips hq: $other_command (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
  fi
done
if [ "$skip_ok" -eq "${#merge_skip_corpus[@]}" ]; then
  ok "all ${#merge_skip_corpus[@]} non-merge mentions skip hq"
fi

# A grep that cannot run must not turn into a skip: the full check still runs.
NO_GREP="$TMP/no-grep-bin"
mkdir -p "$NO_GREP"
for tool in bash jq mktemp rm cat timeout gtimeout perl tr hq; do
  path="$(PATH="$TEST_PATH" command -v "$tool" 2>/dev/null || true)"
  [ -n "$path" ] && ln -sf "$path" "$NO_GREP/$tool"
done
invoke_direct 'gh pr list --json mergeable' "PATH=$NO_GREP" 'HQ_HOLD_TEST_EXIT=0' 'HQ_HOLD_TEST_STDOUT={"ok":true}'
if [ "$LAST_RC" = 0 ] && [ -s "$TMP/calls" ]; then
  ok 'missing grep runs the full check instead of skipping it'
else
  bad "missing grep runs the full check instead of skipping it (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

# BSD grep and older GNU grep apply GREP_OPTIONS; an inherited -v, -x or -w
# must not turn a merge into a skip.
for grep_opts in -v -x -w; do
  invoke_direct 'gh pr merge 5 -R acme/widgets' "GREP_OPTIONS=$grep_opts" 'HQ_HOLD_TEST_EXIT=0' 'HQ_HOLD_TEST_STDOUT={"ok":true}'
  if [ "$LAST_RC" = 0 ] && [ -s "$TMP/calls" ]; then
    ok "GREP_OPTIONS=$grep_opts does not skip a merge"
  else
    bad "GREP_OPTIONS=$grep_opts does not skip a merge (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
  fi
done

# An exported shell function named grep must not decide the skip either.
clear_stub_receipts
payload 'git merge topic' > "$TMP/func-grep.json"
env "PATH=$TEST_PATH" "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" \
  'HQ_HOLD_TEST_EXIT=0' 'HQ_HOLD_TEST_STDOUT={"ok":true}' \
  bash -c 'grep() { return 1; }; export -f grep; bash "$1" < "$2"' _ "$HOOK" "$TMP/func-grep.json" \
  >"$TMP/stdout" 2>"$TMP/stderr" || true
if [ -s "$TMP/calls" ]; then
  ok 'an exported grep function does not skip a merge'
else
  bad "an exported grep function does not skip a merge (out=$(cat "$TMP/stdout"), err=$(cat "$TMP/stderr"))"
fi

# A host that starts the hook with SIGPIPE ignored: a merge on the first line
# of a multi-line command larger than the pipe buffer must still reach hq.
# (grep -q exits at the first match, printf then fails with EPIPE and exit 1,
# and pipefail would report that as "no match".)
clear_stub_receipts
awk 'BEGIN { print "gh pr merge 5 -R acme/widgets"; for (i = 0; i < 2500; i++) print "echo filler-line-abcdefghij-abcdefghij-abcdefghij" }' \
  > "$TMP/sigpipe-command.txt"
jq -nc --rawfile cmd "$TMP/sigpipe-command.txt" --arg root "$ROOT" \
  '{session_id:"lanes-hold-check-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,tool_input:{command:$cmd}}' \
  > "$TMP/sigpipe.json"
env "PATH=$TEST_PATH" "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" \
  'HQ_HOLD_TEST_EXIT=0' 'HQ_HOLD_TEST_STDOUT={"ok":true}' \
  bash -c 'trap "" PIPE; exec bash "$1" < "$2"' _ "$HOOK" "$TMP/sigpipe.json" \
  >"$TMP/stdout" 2>"$TMP/stderr" || true
if [ -s "$TMP/calls" ]; then
  ok 'SIGPIPE ignored: a merge at the start of a 120 KB multi-line command reaches hq'
else
  bad "SIGPIPE ignored: a merge at the start of a 120 KB multi-line command reaches hq (out=$(cat "$TMP/stdout"), err=$(cat "$TMP/stderr"))"
fi
# The same command with no merge word still skips hq when SIGPIPE is ignored.
clear_stub_receipts
awk 'BEGIN { print "gh pr list --json mergeable"; for (i = 0; i < 2500; i++) print "echo filler-line-abcdefghij-abcdefghij-abcdefghij" }' \
  > "$TMP/sigpipe-command.txt"
jq -nc --rawfile cmd "$TMP/sigpipe-command.txt" --arg root "$ROOT" \
  '{session_id:"lanes-hold-check-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,tool_input:{command:$cmd}}' \
  > "$TMP/sigpipe.json"
env "PATH=$TEST_PATH" "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" \
  'HQ_HOLD_TEST_EXIT=0' 'HQ_HOLD_TEST_STDOUT={"ok":true}' \
  bash -c 'trap "" PIPE; exec bash "$1" < "$2"' _ "$HOOK" "$TMP/sigpipe.json" \
  >"$TMP/stdout" 2>"$TMP/stderr" || true
if [ ! -s "$TMP/calls" ]; then
  ok 'SIGPIPE ignored: a large multi-line command with no merge word skips hq'
else
  bad "SIGPIPE ignored: a large multi-line command with no merge word skips hq (out=$(cat "$TMP/stdout"), err=$(cat "$TMP/stderr"))"
fi

echo '[1c] malformed PreToolUse payloads allow with one diagnostic'
for malformed in \
  'not-json' \
  '{"tool_name":"Bash"}' \
  '{"tool_name":"Bash","tool_input":{"command":42}}'; do
  invoke_raw "$malformed"
  if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && has_one_named_diagnostic \
    && [ ! -s "$TMP/calls" ]; then
    ok "malformed payload allows with one diagnostic (input=$malformed)"
  else
    bad "malformed payload allows with one diagnostic (input=$malformed, rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
  fi
done

echo '[2] hq exit 3 becomes a structured Claude deny'
invoke_direct 'gh pr merge 5 -R acme/widgets --squash' \
  "HQ_HOLD_TEST_EXIT=3" "HQ_HOLD_TEST_STDOUT=$HOLD_JSON"
if [ "$LAST_RC" = 0 ] \
  && jq -e --arg repo 'acme/widgets' --arg reason 'incident freeze' --arg until '2026-10-01T12:00:00Z' '
    .hookSpecificOutput.hookEventName == "PreToolUse"
    and .hookSpecificOutput.permissionDecision == "deny"
    and (.hookSpecificOutput.permissionDecisionReason | contains($repo))
    and (.hookSpecificOutput.permissionDecisionReason | contains($reason))
    and (.hookSpecificOutput.permissionDecisionReason | contains($until))
    and (.hookSpecificOutput.permissionDecisionReason | contains("hq lanes hold show acme/widgets"))
  ' <<<"$LAST_OUT" >/dev/null; then
  ok 'exit 3 denies with repo, hold reason, until, and details command'
else
  bad "exit 3 denies with repo, hold reason, until, and details command (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

echo '[2b] any valid exit-3 error denies'
REVIEW_MISSING_JSON='{"ok":false,"error":"review_record_missing","message":"review record is missing"}'
invoke_direct 'gh pr merge 5 -R acme/widgets --squash' \
  'HQ_HOLD_TEST_EXIT=3' "HQ_HOLD_TEST_STDOUT=$REVIEW_MISSING_JSON"
if [ "$LAST_RC" = 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("lanes-repo-merge-hold: review record is missing"))' <<<"$LAST_OUT" >/dev/null 2>&1; then
  ok 'review_record_missing exit 3 denies with its message'
else
  bad "review_record_missing exit 3 denies with its message (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

UNKNOWN_ERROR_JSON='{"ok":false,"error":"review_head_mismatch"}'
invoke_direct 'gh pr merge 5 -R acme/widgets --squash' \
  'HQ_HOLD_TEST_EXIT=3' "HQ_HOLD_TEST_STDOUT=$UNKNOWN_ERROR_JSON"
if [ "$LAST_RC" = 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("review_head_mismatch for unknown repo"))' <<<"$LAST_OUT" >/dev/null 2>&1; then
  ok 'exit 3 without a message denies with the error and unknown-repo fallback'
else
  bad "exit 3 without a message denies with the error and unknown-repo fallback (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

for invalid_exit3 in '{"ok":true,"error":"repo_merge_held"}' 'not-json'; do
  invoke_direct 'gh pr merge 5 -R acme/widgets --squash' \
    'HQ_HOLD_TEST_EXIT=3' "HQ_HOLD_TEST_STDOUT=$invalid_exit3"
  if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && has_one_named_diagnostic \
    && [ -s "$TMP/calls" ]; then
    ok "non-conforming exit-3 output allows with one diagnostic (output=$invalid_exit3)"
  else
    bad "non-conforming exit-3 output allows with one diagnostic (output=$invalid_exit3, rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
  fi
done

echo '[3] hq exit 0 allows silently'
invoke_direct 'gh pr merge 5 -R acme/widgets --squash' \
  'HQ_HOLD_TEST_EXIT=0' 'HQ_HOLD_TEST_STDOUT={"ok":true}'
if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && [ -z "$LAST_ERR" ] && [ -s "$TMP/calls" ]; then
  ok 'exit 0 allows silently'
else
  bad "exit 0 allows silently (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

echo '[4] unexpected hq results fail open with one named diagnostic'
for code in 1 2; do
  invoke_direct 'gh pr merge 5 -R acme/widgets' "HQ_HOLD_TEST_EXIT=$code" \
    'HQ_HOLD_TEST_STDERR=simulated hq failure'
  if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && has_one_named_diagnostic; then
    ok "exit $code allows with one named diagnostic"
  else
    bad "exit $code allows with one named diagnostic (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
  fi
done

invoke_direct 'gh pr merge 5 -R acme/widgets' 'HQ_HOLD_TEST_EXIT=1' \
  "HQ_HOLD_TEST_STDERR=unknown command: lanes hold"
if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && has_one_named_diagnostic; then
  ok 'older hq without lanes hold allows with one named diagnostic'
else
  bad "older hq without lanes hold allows with one named diagnostic (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

echo '[5] timeout and missing hq fail open'
start="$SECONDS"
invoke_direct 'gh pr merge 5 -R acme/widgets' 'HQ_HOLD_TEST_SLEEP=8'
elapsed=$((SECONDS - start))
if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && has_one_named_diagnostic && [ "$elapsed" -lt 8 ]; then
  ok "timed-out hq allows with one named diagnostic (elapsed=${elapsed}s)"
else
  bad "timed-out hq allows within the short bound (elapsed=${elapsed}s, rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

MISSING_HQ_BIN="$TMP/no-hq-bin"
mkdir -p "$MISSING_HQ_BIN"
for tool in bash jq mktemp rm cat timeout gtimeout perl; do
  path="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$path" ] && ln -sf "$path" "$MISSING_HQ_BIN/$tool"
done
invoke_direct 'gh pr merge 5 -R acme/widgets' "PATH=$MISSING_HQ_BIN"
if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && has_one_named_diagnostic && [ ! -s "$TMP/calls" ]; then
  ok 'missing hq allows with one named diagnostic without invoking a stub'
else
  bad "missing hq allows with one named diagnostic (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

echo '[6] command text reaches hq unchanged'
exact_command=$'FOO="quoted value" gh pr merge 7 -R acme/widgets --squash &&\nprintf "%s\\n" two-lines\n\n'
invoke_direct "$exact_command" 'HQ_HOLD_TEST_EXIT=0' 'HQ_HOLD_TEST_STDOUT={"ok":true}'
printf '%s\0' lanes hold check --command "$exact_command" --json > "$TMP/expected-argv"
if [ "$LAST_RC" = 0 ] && cmp -s "$TMP/expected-argv" "$TMP/argv"; then
  ok 'quoted, compound, multiline command argument is byte-for-byte unchanged'
else
  bad 'quoted, compound, multiline command argument is byte-for-byte unchanged'
fi

echo '[7] all three hook-gate profiles enable the deny'
for profile in minimal standard strict; do
  rc=0
  clear_stub_receipts
  printf '%s' "$(payload 'gh pr m\"erge\" 5 -R acme/widgets')" \
    | env "PATH=$TEST_PATH" "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
        "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" "HQ_HOLD_TEST_EXIT=3" \
        "HQ_HOLD_TEST_STDOUT=$HOLD_JSON" "HQ_HOOK_PROFILE=$profile" \
        "CLAUDE_PROJECT_DIR=$ROOT" HQ_HOOK_TIMEOUT_SENTRY=0 \
        bash "$GATE" lanes-repo-merge-hold "$HOOK" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  if [ "$rc" = 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/stdout" >/dev/null 2>&1 \
    && [ -s "$TMP/calls" ]; then
    ok "hook-gate profile=$profile dispatches the deny"
  else
    bad "hook-gate profile=$profile dispatches the deny (rc=$rc, out=$(cat "$TMP/stdout"))"
  fi
done

echo '[8] master-hook dispatches the registered Bash guard and Codex preserves its deny'
OTHER_IDS="$(jq -r '.hooks.PreToolUse[].hooks[].id | select(. != "lanes-repo-merge-hold")' "$REGISTRY" 2>/dev/null | sort -u | paste -sd, -)"
invoke_master() {
  local command_text="$1" rc=0 input
  clear_stub_receipts
  input="$(payload "$command_text")"
  printf '%s' "$input" \
    | env "PATH=$TEST_PATH" "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
        "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" "HQ_HOLD_TEST_EXIT=0" \
        "HQ_HOLD_TEST_STDOUT={\"ok\":true}" "HQ_ROOT=$ROOT" \
        "CLAUDE_PROJECT_DIR=$ROOT" HQ_HOOK_TIMEOUT_SENTRY=0 \
        HQ_HOOK_PROFILE=minimal "HQ_DISABLED_HOOKS=$OTHER_IDS" \
        bash "$MASTER" PreToolUse >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  LAST_RC="$rc"
  LAST_OUT="$(cat "$TMP/stdout")"
  LAST_ERR="$(cat "$TMP/stderr")"
}

# Exercise the real master dispatcher and registry prefilter with a recording
# target script. This proves whether the registry dispatched the shim slot even
# when the production shim's own substring check would skip hq.
PREFILTER_ROOT="$TMP/prefilter-root"
mkdir -p "$PREFILTER_ROOT/.claude" "$PREFILTER_ROOT/core/scripts/lib"
cp -R "$ROOT/.claude/hooks" "$PREFILTER_ROOT/.claude/hooks"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$PREFILTER_ROOT/core/scripts/lib/hook-adapter-core.sh"
jq '(.hooks.PreToolUse[].hooks[] | select(.id == "lanes-repo-merge-hold").script) = ".claude/hooks/lanes-repo-merge-hold-probe.sh"' \
  "$REGISTRY" > "$PREFILTER_ROOT/.claude/hooks/hook-registry.json"
cat > "$PREFILTER_ROOT/.claude/hooks/lanes-repo-merge-hold-probe.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'called\n' >> "$HQ_HOLD_DISPATCH_CALL_FILE"
SH
chmod +x "$PREFILTER_ROOT/.claude/hooks/lanes-repo-merge-hold-probe.sh"

invoke_prefilter_probe() {
  local command_text="$1" rc=0 input
  : > "$TMP/prefilter-dispatch-calls"
  input="$(payload "$command_text" "$PREFILTER_ROOT")"
  printf '%s' "$input" \
    | env "PATH=$TEST_PATH" "HQ_HOLD_DISPATCH_CALL_FILE=$TMP/prefilter-dispatch-calls" \
        "HQ_ROOT=$PREFILTER_ROOT" "CLAUDE_PROJECT_DIR=$PREFILTER_ROOT" \
        HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_PROFILE=minimal \
        "HQ_DISABLED_HOOKS=$OTHER_IDS" \
        bash "$PREFILTER_ROOT/.claude/hooks/master-hook.sh" PreToolUse \
        >"$TMP/probe-stdout" 2>"$TMP/probe-stderr" || rc=$?
  LAST_RC="$rc"
  LAST_OUT="$(cat "$TMP/probe-stdout")"
  LAST_ERR="$(cat "$TMP/probe-stderr")"
}

for quoted_command in \
  "gh pr m'er'ge 5 -R acme/widgets" \
  'gh pr me\rge 5 -R acme/widgets'; do
  rc=0
  clear_stub_receipts
  printf '%s' "$(payload "$quoted_command")" \
    | env "PATH=$TEST_PATH" "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
        "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" "HQ_HOLD_TEST_EXIT=3" \
        "HQ_HOLD_TEST_STDOUT=$HOLD_JSON" "HQ_ROOT=$ROOT" \
        "CLAUDE_PROJECT_DIR=$ROOT" HQ_HOOK_TIMEOUT_SENTRY=0 \
        HQ_HOOK_PROFILE=minimal "HQ_DISABLED_HOOKS=$OTHER_IDS" \
        bash "$MASTER" PreToolUse >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  if [ "$rc" = 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/stdout" >/dev/null 2>&1 \
    && [ -s "$TMP/calls" ]; then
    ok "master-hook raw-JSON prefilter dispatches $quoted_command"
  else
    bad "master-hook raw-JSON prefilter dispatches $quoted_command (rc=$rc, out=$(cat "$TMP/stdout"), err=$(cat "$TMP/stderr"))"
  fi
done

rc=0
clear_stub_receipts
printf '%s' "$(payload 'mkdir -p /tmp/every/rg/e')" \
  | env "PATH=$TEST_PATH" "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
      "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" "HQ_ROOT=$ROOT" \
      "CLAUDE_PROJECT_DIR=$ROOT" HQ_HOOK_TIMEOUT_SENTRY=0 \
      HQ_HOOK_PROFILE=minimal "HQ_DISABLED_HOOKS=$OTHER_IDS" \
      bash "$MASTER" PreToolUse >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/calls" ]; then
  ok 'master-hook raw-JSON prefilter skips ordered letters spread across words'
else
  bad "master-hook raw-JSON prefilter skips ordered letters spread across words (rc=$rc, out=$(cat "$TMP/stdout"), err=$(cat "$TMP/stderr"))"
fi

echo '[8a] master-hook registry prefilter skips commands the original regex skipped'
for unrelated_command in \
  'mkdir -p /tmp/every/rg/e' \
  'echo m e r g e'; do
  invoke_prefilter_probe "$unrelated_command"
  if [ "$LAST_RC" = 0 ] && [ ! -s "$TMP/prefilter-dispatch-calls" ]; then
    ok "master-hook does not dispatch the shim for: $unrelated_command"
  else
    bad "master-hook does not dispatch the shim for: $unrelated_command (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
  fi
done

echo '[8b] master-hook registry prefilter dispatches merge commands through common wrappers'
for merge_command in \
  'gh pr merge 5 -R o/r' \
  "bash -lc 'gh pr merge 5'" \
  'env -i gh pr merge 5' \
  'git merge topic' \
  'gh pr "merge" 5 -R o/r' \
  "gh 'pr' merge 5" \
  $'gh\tpr\tmerge 5' \
  $'gh pr \\\n merge 5 -R o/r' \
  'gh api -X PUT repos/o/r/pulls/5/merge' \
  "g'it' merge topic" \
  'g\it merge topic' \
  "g'h' pr merge 5"; do
  invoke_master "$merge_command"
  if [ "$LAST_RC" = 0 ] && [ -s "$TMP/calls" ]; then
    ok "master-hook invokes hq for: $merge_command"
  else
    bad "master-hook invokes hq for: $merge_command (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
  fi
done

rc=0
clear_stub_receipts
printf '%s' "$(payload 'gh pr m\"erge\" 5 -R acme/widgets')" \
  | env "PATH=$TEST_PATH" "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
      "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" "HQ_HOLD_TEST_EXIT=3" \
      "HQ_HOLD_TEST_STDOUT=$HOLD_JSON" "HQ_ROOT=$ROOT" \
      "CLAUDE_PROJECT_DIR=$ROOT" HQ_HOOK_TIMEOUT_SENTRY=0 \
      HQ_HOOK_PROFILE=minimal "HQ_DISABLED_HOOKS=$OTHER_IDS" \
      bash "$MASTER" PreToolUse >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if [ "$rc" = 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/stdout" >/dev/null 2>&1 \
  && [ -s "$TMP/calls" ]; then
  ok 'Claude master-hook returns the registered structured deny'
else
  bad "Claude master-hook returns the registered structured deny (rc=$rc, out=$(cat "$TMP/stdout"))"
fi

CODEX_ROOT="$TMP/codex-root"
mkdir -p "$CODEX_ROOT/.codex/hooks" "$CODEX_ROOT/.claude/hooks" "$CODEX_ROOT/core/scripts/lib"
cp "$CODEX_ADAPTER" "$CODEX_ROOT/.codex/hooks/hq-codex-hook-adapter.sh"
cp "$ROOT/.claude/settings.json" "$CODEX_ROOT/.claude/settings.json"
cp "$REGISTRY" "$CODEX_ROOT/.claude/hooks/hook-registry.json"
cp "$GATE" "$CODEX_ROOT/.claude/hooks/hook-gate.sh"
cp "$HOOK" "$CODEX_ROOT/.claude/hooks/lanes-repo-merge-hold.sh"
cp "$ROOT/core/scripts/hook-lib.sh" "$CODEX_ROOT/core/scripts/hook-lib.sh"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$CODEX_ROOT/core/scripts/lib/hook-adapter-core.sh"
cat > "$CODEX_ROOT/.claude/hooks/master-hook.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
chmod +x "$CODEX_ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$CODEX_ROOT/.claude/hooks/lanes-repo-merge-hold.sh" "$CODEX_ROOT/.claude/hooks/master-hook.sh"
codex_input="$(jq -nc --arg cmd 'gh pr m"erge" 5 -R acme/widgets' --arg root "$CODEX_ROOT" \
  '{session_id:"lanes-hold-check-codex-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,tool_input:{command:$cmd}}')"
rc=0
clear_stub_receipts
printf '%s' "$codex_input" \
  | env "PATH=$TEST_PATH" "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
      "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" "HQ_HOLD_TEST_EXIT=3" \
      "HQ_HOLD_TEST_STDOUT=$HOLD_JSON" HQ_HOOK_TIMEOUT_SENTRY=0 \
      HQ_HOOK_PROFILE=minimal "HQ_DISABLED_HOOKS=$OTHER_IDS" \
      bash "$CODEX_ROOT/.codex/hooks/hq-codex-hook-adapter.sh" \
      >"$TMP/codex.json" 2>"$TMP/codex.stderr" || rc=$?
if [ "$rc" = 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny" and .decision == "block"' "$TMP/codex.json" >/dev/null 2>&1 \
  && [ -s "$TMP/calls" ]; then
  ok 'Codex adapter translates the same registered shim into a block'
else
  bad "Codex adapter translates the same registered shim into a block (rc=$rc, out=$(cat "$TMP/codex.json"), err=$(cat "$TMP/codex.stderr"))"
fi

echo '[9] a 100 KB quoted command with no merge stays under 2s on bash 3.2 and bash 5'
# x and quotes only: thousands of quotes, no merge letters before or after
# the strip. The second payload hides merge behind a quote inside the same
# bulk so the linear strip still has to run.
awk 'BEGIN { for (i = 0; i < 5000; i++) printf "xxxxxxxxxxxxxxxx\"xxxxxxxxxxxxxxxx" }' \
  > "$TMP/large-nomerge.cmd"
cp "$TMP/large-nomerge.cmd" "$TMP/large-quoted-merge.cmd"
printf ' m"erge"' >> "$TMP/large-quoted-merge.cmd"
large_bytes="$(wc -c < "$TMP/large-nomerge.cmd" | tr -d '[:space:]')"
large_quotes="$(tr -cd '"' < "$TMP/large-nomerge.cmd" | wc -c | tr -d '[:space:]')"
jq -n --rawfile c "$TMP/large-nomerge.cmd" \
  '{session_id:"lanes-hold-large",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:"/tmp",tool_input:{command:$c}}' \
  > "$TMP/large-nomerge.json"
jq -n --rawfile c "$TMP/large-quoted-merge.cmd" \
  '{session_id:"lanes-hold-large",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:"/tmp",tool_input:{command:$c}}' \
  > "$TMP/large-quoted-merge.json"

cat > "$TMP/run-bounded.pl" <<'PL'
use Time::HiRes qw(time);
my $limit = shift @ARGV;
my $status_path = shift @ARGV;
my $start = time;
my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
  setpgrp(0, 0);
  exec @ARGV or die "exec: $!";
}
local $SIG{ALRM} = sub {
  kill "TERM", -$pid;
  select(undef, undef, undef, 0.2);
  kill "KILL", -$pid;
  waitpid($pid, 0);
  if (open my $fh, ">", $status_path) {
    printf $fh "124 %.3f\n", time - $start;
  }
  exit 124;
};
alarm($limit);
waitpid($pid, 0);
my $rc = $?;
my $code = ($rc & 127) ? 128 + ($rc & 127) : ($rc >> 8);
open my $fh, ">", $status_path or die $!;
printf $fh "%d %.3f\n", $code, time - $start;
PL

run_hook_bounded() {
  local bash_bin="$1" payload="$2" limit_s="$3"
  : > "$TMP/stdout"
  : > "$TMP/stderr"
  : > "$TMP/large-status"
  clear_stub_receipts
  perl "$TMP/run-bounded.pl" "$limit_s" "$TMP/large-status" \
    env "PATH=$TEST_PATH" \
      "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
      "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" \
      "$bash_bin" "$HOOK" <"$payload" >"$TMP/stdout" 2>"$TMP/stderr" || true
  read -r LARGE_RC LARGE_SECS < "$TMP/large-status"
}

large_bash_list="$TMP/large-bashes"
: > "$large_bash_list"
add_large_bash() {
  local candidate="$1" seen
  [ -n "$candidate" ] && [ -x "$candidate" ] || return 0
  while IFS= read -r seen; do
    [ "$seen" = "$candidate" ] && return 0
    [ -n "$seen" ] && [ "$candidate" -ef "$seen" ] && return 0
  done < "$large_bash_list"
  printf '%s\n' "$candidate" >> "$large_bash_list"
}
add_large_bash "$(command -v bash)"
add_large_bash /bin/bash
add_large_bash /opt/homebrew/bin/bash
add_large_bash /usr/local/bin/bash

saw_bash5=0
saw_bash32=0
while IFS= read -r large_bash; do
  [ -n "$large_bash" ] || continue
  large_major="$("$large_bash" -c 'printf "%s\n" "${BASH_VERSINFO[0]}"')"
  [ "$large_major" -ge 5 ] && saw_bash5=1
  [ "$large_major" -eq 3 ] && saw_bash32=1
  if [ "$large_bytes" -lt 100000 ] || [ "$large_quotes" -lt 1000 ]; then
    bad "large command is 100 KB with thousands of quotes (bytes=$large_bytes quotes=$large_quotes)"
    continue
  fi
  run_hook_bounded "$large_bash" "$TMP/large-nomerge.json" 2
  if [ "$LARGE_RC" = 0 ] && [ ! -s "$TMP/stdout" ] && [ ! -s "$TMP/stderr" ] && [ ! -s "$TMP/calls" ] \
    && awk -v s="$LARGE_SECS" 'BEGIN { exit !(s < 2) }'; then
    ok "no-merge ${large_bytes}-byte command under ${large_bash} (bash ${large_major}) in ${LARGE_SECS}s"
  else
    bad "no-merge large command under ${large_bash} (rc=$LARGE_RC secs=$LARGE_SECS out=$(cat "$TMP/stdout") err=$(cat "$TMP/stderr"))"
  fi
  run_hook_bounded "$large_bash" "$TMP/large-quoted-merge.json" 2
  if [ "$LARGE_RC" = 0 ] && [ -s "$TMP/calls" ] \
    && awk -v s="$LARGE_SECS" 'BEGIN { exit !(s < 2) }'; then
    ok "quote-split merge inside the large command reaches hq under ${large_bash} in ${LARGE_SECS}s"
  else
    bad "quote-split merge inside the large command reaches hq under ${large_bash} (rc=$LARGE_RC secs=$LARGE_SECS)"
  fi
done < "$large_bash_list"

if [ "$saw_bash5" -eq 1 ]; then
  ok 'bash 5 ran the large-command prefilter'
else
  bad 'bash 5 ran the large-command prefilter'
fi
if [ "$(uname)" = Darwin ]; then
  if [ "$saw_bash32" -eq 1 ]; then
    ok 'macOS /bin/bash 3.2 ran the large-command prefilter'
  else
    bad 'macOS /bin/bash 3.2 ran the large-command prefilter'
  fi
fi

echo '[9c] a missing tr fails open on a quote-split merge'
NO_TR="$TMP/no-tr-bin"
mkdir -p "$NO_TR"
for tool in bash jq mktemp rm cat timeout gtimeout perl; do
  path="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$path" ] && ln -sf "$path" "$NO_TR/$tool"
done
invoke_direct 'gh pr m"erge" 5 -R acme/widgets' "PATH=$NO_TR"
if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && has_one_named_diagnostic && [ ! -s "$TMP/calls" ]; then
  ok 'missing tr allows a quote-split merge with one diagnostic and does not call hq'
else
  bad "missing tr allows a quote-split merge with one diagnostic (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

echo '[9b] uppercase merge still reaches hq'
invoke_direct 'git MERGE topic' 'HQ_HOLD_TEST_EXIT=0' 'HQ_HOLD_TEST_STDOUT={"ok":true}'
if [ "$LAST_RC" = 0 ] && [ -s "$TMP/calls" ]; then
  ok 'uppercase MERGE reaches hq'
else
  bad "uppercase MERGE reaches hq (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

echo '[10] a command over the 131071-byte Linux argument limit still reaches the hold check'
# Linux refuses any one exec argument over MAX_ARG_STRLEN, so the shim must
# never hand hq a --command value over 131071 bytes. These payloads go through
# files: a jq --arg of this size would hit the same limit.
invoke_file() {
  local cmd_file="$1" rc=0
  shift
  clear_stub_receipts
  jq -n --rawfile c "$cmd_file" \
    '{session_id:"lanes-hold-huge",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:"/tmp",tool_input:{command:$c}}' \
    > "$TMP/huge.json"
  env "PATH=$TEST_PATH" \
    "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
    "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" \
    "$@" bash "$HOOK" <"$TMP/huge.json" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  LAST_RC="$rc"
  LAST_OUT="$(cat "$TMP/stdout")"
  LAST_ERR="$(cat "$TMP/stderr")"
}
# Writes the --command value hq received to $TMP/hold-command.
hq_command_arg() {
  perl -0 -ne 'chomp; if ($want) { print; exit } $want = 1 if $_ eq "--command"' "$TMP/argv" > "$TMP/hold-command"
}
denied_with() {
  jq -e --arg want "$1" '.hookSpecificOutput.permissionDecision == "deny"
    and (.hookSpecificOutput.permissionDecisionReason | contains($want))' <<<"$LAST_OUT" >/dev/null 2>&1
}
file_bytes() { wc -c < "$1" | tr -d '[:space:]'; }

# 70,000 two-byte characters per line: 140 KB of bytes but only 70,000
# characters, so a character count would wrongly pass it whole.
awk 'BEGIN { for (i = 0; i < 70000; i++) printf "\303\251"; printf "\n" }' > "$TMP/pad-line"
{ printf 'echo '; cat "$TMP/pad-line"; printf 'gh pr merge 5 -R acme/widgets --squash\n'; } > "$TMP/huge-multi.cmd"
invoke_file "$TMP/huge-multi.cmd" 'HQ_HOLD_TEST_EXIT=3' "HQ_HOLD_TEST_STDOUT=$HOLD_JSON"
hq_command_arg
if [ "$(file_bytes "$TMP/huge-multi.cmd")" -gt 131071 ] && [ "$LAST_RC" = 0 ] && [ -s "$TMP/calls" ] \
  && [ "$(cat "$TMP/hold-command")" = 'gh pr merge 5 -R acme/widgets --squash' ] \
  && denied_with 'Repo merge hold for acme/widgets'; then
  ok 'oversized multi-line command sends only its merge segment to hq and the hold denies'
else
  bad "oversized multi-line command sends only its merge segment (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR, arg=$(head -c 200 "$TMP/hold-command"))"
fi

# Exactly at the limit the command passes byte for byte; one byte over, the
# non-merge segment is dropped.
build_at_size() {
  local size="$1" head='gh pr merge 5 -R acme/widgets; echo ' pad
  pad=$((size - ${#head}))
  { printf '%s' "$head"; awk -v n="$pad" 'BEGIN { for (i = 0; i < n; i++) printf "x" }'; } > "$TMP/at-size.cmd"
}
build_at_size 131071
invoke_file "$TMP/at-size.cmd" 'HQ_HOLD_TEST_EXIT=0' 'HQ_HOLD_TEST_STDOUT={"ok":true}'
hq_command_arg
if [ "$(file_bytes "$TMP/at-size.cmd")" = 131071 ] && [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] \
  && cmp -s "$TMP/at-size.cmd" "$TMP/hold-command"; then
  ok 'a 131071-byte merge command reaches hq unchanged'
else
  bad "a 131071-byte merge command reaches hq unchanged (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR, arg_bytes=$(file_bytes "$TMP/hold-command"))"
fi
build_at_size 131072
invoke_file "$TMP/at-size.cmd" 'HQ_HOLD_TEST_EXIT=3' "HQ_HOLD_TEST_STDOUT=$HOLD_JSON"
hq_command_arg
if [ "$LAST_RC" = 0 ] && [ "$(cat "$TMP/hold-command")" = 'gh pr merge 5 -R acme/widgets' ] \
  && denied_with 'Repo merge hold for acme/widgets'; then
  ok 'a 131072-byte merge command sends only its merge segment and the hold denies'
else
  bad "a 131072-byte merge command sends only its merge segment (rc=$LAST_RC, out=$LAST_OUT, arg=$(head -c 200 "$TMP/hold-command"))"
fi

# A long plain word inside the merge segment is shortened; every other word,
# quote, and option stays as written.
{ printf 'gh pr m"erge" 5 -R acme/widgets --subject '; awk 'BEGIN { for (i = 0; i < 9000; i++) printf "abcdefghij\047\047klmnopqrst" }'; printf ' --squash'; } > "$TMP/huge-word.cmd"
expected_word="$(awk 'BEGIN { s = ""; for (i = 0; i < 7; i++) s = s "abcdefghijklmnopqrst"; print substr(s, 1, 128) }')"
invoke_file "$TMP/huge-word.cmd" 'HQ_HOLD_TEST_EXIT=3' "HQ_HOLD_TEST_STDOUT=$HOLD_JSON"
hq_command_arg
if [ "$LAST_RC" = 0 ] && [ "$(cat "$TMP/hold-command")" = "gh pr m\"erge\" 5 -R acme/widgets --subject $expected_word --squash" ] \
  && denied_with 'Repo merge hold for acme/widgets'; then
  ok 'an oversized plain word in the merge segment is shortened and the hold denies'
else
  bad "an oversized plain word in the merge segment is shortened (rc=$LAST_RC, out=$LAST_OUT, arg=$(head -c 300 "$TMP/hold-command"))"
fi

# Digit-first words are never shortened: 000...05 is PR 5 and 000...1e3 is an
# invalid duration, and a 128-digit prefix would read as PR 0 or a valid one.
zeros="$(awk 'BEGIN { for (i = 0; i < 4100; i++) printf "0" }')"
for digit_word in "${zeros}5" "${zeros}1e3"; do
  { printf 'gh pr merge %s -R acme/widgets; echo ' "$digit_word"; cat "$TMP/pad-line"; } > "$TMP/huge-digits.cmd"
  invoke_file "$TMP/huge-digits.cmd" 'HQ_HOLD_TEST_EXIT=3' "HQ_HOLD_TEST_STDOUT=$HOLD_JSON"
  hq_command_arg
  if [ "$LAST_RC" = 0 ] && [ "$(cat "$TMP/hold-command")" = "gh pr merge $digit_word -R acme/widgets" ] \
    && denied_with 'Repo merge hold for acme/widgets'; then
    ok "a ${#digit_word}-character digit-first word reaches hq unshortened"
  else
    bad "a ${#digit_word}-character digit-first word reaches hq unshortened (rc=$LAST_RC, arg_bytes=$(file_bytes "$TMP/hold-command"))"
  fi
done

# Segments split exactly where hq-cli splits them: || && ; CRLF and LF, but
# not a quoted ; or an escaped newline.
{
  printf 'true || gh pr merge 5 -R acme/widgets && echo "a;b"\r\n'
  printf 'echo one \\\n'
  printf 'gh pr merge 6 -R acme/widgets; echo '
  cat "$TMP/pad-line"
} > "$TMP/huge-split.cmd"
invoke_file "$TMP/huge-split.cmd" 'HQ_HOLD_TEST_EXIT=3' "HQ_HOLD_TEST_STDOUT=$HOLD_JSON"
hq_command_arg
printf ' gh pr merge 5 -R acme/widgets \necho one \\\ngh pr merge 6 -R acme/widgets' > "$TMP/split-want"
if [ "$LAST_RC" = 0 ] && cmp -s "$TMP/split-want" "$TMP/hold-command" \
  && denied_with 'Repo merge hold for acme/widgets'; then
  ok 'oversized command keeps the merge segments hq-cli would split out'
else
  bad "oversized command keeps the merge segments hq-cli would split out (rc=$LAST_RC, arg=$(od -c "$TMP/hold-command" | head -5))"
fi

# A merge segment that stays over the limit, or cannot be split, fails closed
# without calling hq.
{ printf 'gh pr merge 5 -R acme/widgets --body "'; awk 'BEGIN { for (i = 0; i < 30000; i++) printf "word " }'; printf '"'; } > "$TMP/huge-body.cmd"
invoke_file "$TMP/huge-body.cmd"
if [ "$LAST_RC" = 0 ] && [ ! -s "$TMP/calls" ] && denied_with 'merge-hold check cannot run'; then
  ok 'an irreducible oversized merge segment is denied without calling hq'
else
  bad "an irreducible oversized merge segment is denied (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi
{ printf 'gh pr merge 5 -R acme/widgets; echo "'; cat "$TMP/pad-line"; } > "$TMP/huge-unclosed.cmd"
invoke_file "$TMP/huge-unclosed.cmd"
if [ "$LAST_RC" = 0 ] && [ ! -s "$TMP/calls" ] && denied_with 'could not be isolated'; then
  ok 'an oversized merge command with an unclosed quote is denied without calling hq'
else
  bad "an oversized merge command with an unclosed quote is denied (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi
{ cat "$TMP/huge-multi.cmd"; printf 'echo \001\n'; } > "$TMP/huge-soh.cmd"
invoke_file "$TMP/huge-soh.cmd"
if [ "$LAST_RC" = 0 ] && [ ! -s "$TMP/calls" ] && denied_with 'contains a \001 byte'; then
  ok 'an oversized merge command with a \001 byte is denied without calling hq'
else
  bad "an oversized merge command with a \\001 byte is denied (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

# Over the limit with no merge anywhere: silent allow, hq not called.
{ printf 'echo '; cat "$TMP/pad-line"; } > "$TMP/huge-plain.cmd"
invoke_file "$TMP/huge-plain.cmd"
if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && [ -z "$LAST_ERR" ] && [ ! -s "$TMP/calls" ]; then
  ok 'an oversized command without merge is allowed silently'
else
  bad "an oversized command without merge is allowed silently (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

echo "lanes-hold-check-shim: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
