#!/usr/bin/env bash
# Regression: git spellings that block-hq-root-git-mutation classifies must
# also reach it through master-hook's registry prefilter.
#
# The guard removes quotes inside a word and unwraps eval, sh -c, and bash -c
# before it classifies a command. The registry prefilter ran first and only
# matched a bare `git` or `gh` word, so `g''it commit` and `"g"it commit` at the
# HQ root skipped the guard ("skip block-hq-root-git-mutation (prefilter)")
# and exited 0. Runs under PATH bash and /bin/bash when they differ.
set -euo pipefail
TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(git -C "$TEST_DIR/../../.." rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/hq"

mkdir -p "$FIXTURE/.claude/hooks" "$FIXTURE/core/scripts/lib" \
  "$FIXTURE/companies/example-co" "$FIXTURE/workspace/sessions"
cp "$ROOT/.claude/hooks/master-hook.sh" "$FIXTURE/.claude/hooks/"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$FIXTURE/.claude/hooks/"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIXTURE/.claude/hooks/"
cp "$ROOT/.claude/hooks/block-hq-root-git-mutation.sh" "$FIXTURE/.claude/hooks/"
cp "$ROOT/.claude/hooks/block-hq-root-git-mutation-flag.cjs" "$FIXTURE/.claude/hooks/"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIXTURE/core/scripts/"
cp "$ROOT/core/scripts/resolve-hq-root.sh" "$FIXTURE/core/scripts/"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIXTURE/core/scripts/lib/"
jq '(.hooks.PreToolUse) |= map(.hooks |= map(select(.id == "block-hq-root-git-mutation")) | select(.hooks | length > 0))' \
  "$ROOT/.claude/hooks/hook-registry.json" > "$FIXTURE/.claude/hooks/hook-registry.json"
git -C "$FIXTURE" init -q

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

BASHES=(bash)
if [[ -x /bin/bash && "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" != "$(bash -c 'echo "${BASH_VERSINFO[0]}"')" ]]; then
  BASHES+=(/bin/bash)
fi

payload_for() {
  jq -cn --arg cwd "$FIXTURE" --arg command "$1" \
    '{session_id:"git-spellings-prefilter",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$command}}'
}

run_master() { # <tag> <label> <command>; runs under $BASH_BIN
  local label="$2" rc=0
  payload_for "$3" | (
    cd "$FIXTURE"
    env -u HQ_HOOK_EVENT -u HQ_HOOK_TOOL_NAME -u HQ_HOOK_COMMAND \
      -u HQ_HOOK_CWD -u HQ_HOOK_SESSION_ID -u HQ_HOOK_AGENT_ID \
      CLAUDE_PROJECT_DIR="$FIXTURE" HQ_HOOK_DEDUPE=0 HQ_HOOK_TIMEOUT_SENTRY=0 \
      HQ_HOOK_TRACE=1 HQ_ALLOW_HQ_ROOT_GIT= HQ_CLI_BIN="$TMP/no-hq-cli" \
      "$BASH_BIN" "$FIXTURE/.claude/hooks/master-hook.sh" PreToolUse \
      > "$TMP/$label.out" 2> "$TMP/$label.err"
  ) || rc=$?
  printf '%s\n' "$rc" > "$TMP/$label.rc"
}

expect_deny() { # <bash> <label> <command>
  local rc
  run_master "$@"
  rc="$(<"$TMP/$2.rc")"
  if [[ "$rc" == 2 ]] && grep -q 'BLOCKED' "$TMP/$2.err" \
    && ! grep -q 'skip block-hq-root-git-mutation (prefilter)' "$TMP/$2.err"; then
    pass "$1: $2 denied"
  else
    fail "$1: $2 expected exit 2 from the guard; got exit $rc, stderr=$(<"$TMP/$2.err")"
  fi
}

# The guard sends a command to its parser when it has a $ or backtick and a
# mutation word. The registry prefilter (re, or every regex in re_all) must
# match every such command, including when the $ or backtick is the only
# character between the word and its neighbours. Probes go through the shared
# matcher that master-hook and the Codex and Grok adapters call.
PF_RE="$(jq -r '.hooks.PreToolUse[].hooks[] | select(.id == "block-hq-root-git-mutation") | .prefilter.re' \
  "$FIXTURE/.claude/hooks/hook-registry.json")"
PF_RE_ALL="$(jq -r '.hooks.PreToolUse[].hooks[] | select(.id == "block-hq-root-git-mutation") | .prefilter.re_all // [] | join("\u001e")' \
  "$FIXTURE/.claude/hooks/hook-registry.json")"
prefilter_runs() { # <bash> <text> [re] [re_all]; exit 0 when the guard would run
  "$1" -c 'source "$1/core/scripts/lib/hook-adapter-core.sh"
    hqad_registry_prefilter_match PreToolUse "$1" "" "$1" probe "$2" "$3" "" "" "" block-hq-root-git-mutation "$4"' \
    _ "$FIXTURE" "$2" "${3-$PF_RE}" "${4-$PF_RE_ALL}" 2>"$TMP/probe.err"
}
for BASH_BIN in "${BASHES[@]}"; do
  v="$("$BASH_BIN" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
  for probe in '$commit' 'commit$' '`push`' 'x$add' 'a=gi; b=t; $a$b commit' \
    '${G:-git} commit' 'g${X}it commit'; do
    if prefilter_runs "$BASH_BIN" "$probe"; then pass "bash $v: prefilter matches $probe"; else fail "bash $v: prefilter misses $probe"; fi
  done
  for probe in 'echo commit' 'echo $HOME' 'ls `pwd`' 'echo $committed'; do
    if prefilter_runs "$BASH_BIN" "$probe"; then fail "bash $v: prefilter matches $probe"; else pass "bash $v: prefilter skips $probe"; fi
  done
  # A malformed regex in re_all keeps the guard in the dispatch set, even
  # when an earlier regex in the list already missed.
  if prefilter_runs "$BASH_BIN" 'echo x' 'zzz' $'[$`]\x1e(unclosed' \
    && grep -q 'malformed regex prefilter' "$TMP/probe.err"; then
    pass "bash $v: malformed re_all regex fails closed after a miss"
  else
    fail "bash $v: malformed re_all regex after a miss skipped the guard"
  fi
done

expect_allow() { # <bash> <label> <command>
  local rc
  run_master "$@"
  rc="$(<"$TMP/$2.rc")"
  if [[ "$rc" == 0 ]]; then
    pass "$1: $2 allowed"
  else
    fail "$1: $2 expected exit 0; got exit $rc, stderr=$(<"$TMP/$2.err")"
  fi
}

expect_skipped() { # <bash> <label> <command>
  run_master "$@"
  if [[ "$(<"$TMP/$2.rc")" == 0 ]] \
    && grep -q 'skip block-hq-root-git-mutation (prefilter)' "$TMP/$2.err"; then
    pass "$1: $2 skipped by the prefilter"
  else
    fail "$1: $2 expected a prefilter skip; stderr=$(<"$TMP/$2.err")"
  fi
}

for BASH_BIN in "${BASHES[@]}"; do
  v="$("$BASH_BIN" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
  tag="bash $v"
  expect_deny "$tag" empty-single-quotes "g''it commit -m x"
  expect_deny "$tag" double-quoted-prefix '"g"it commit -m x'
  expect_deny "$tag" single-quoted-word "'git' commit -m x"
  expect_deny "$tag" quote-split-tail "gi''t push origin main"
  expect_deny "$tag" backslash-split 'g\it commit -m x'
  expect_deny "$tag" eval-quote-split "eval \"g''it commit -m x\""
  expect_deny "$tag" bash-c-quote-split "bash -c \"g''it push\""
  expect_deny "$tag" sh-c-quote-split "sh -c 'g\"\"it commit -m x'"
  expect_deny "$tag" var-quote-split "G=g''it; \$G commit -m x"
  expect_deny "$tag" plain-git "git commit -m x"
  # A command name built from expansions leaves no git text for the regex to
  # find. The guard sends any $ or backtick plus a mutation word to its
  # parser, so the prefilter has to let those commands through too.
  expect_deny "$tag" var-concat-name 'a=gi; b=t; $a$b commit -m x'
  expect_deny "$tag" default-expansion-name '${G:-git} commit -m x'
  expect_deny "$tag" empty-var-inside-name 'g${X}it commit -m x'
  # Commands with no git word in any spelling still skip the guard, so the
  # wider prefilter does not run it on every Bash call.
  expect_skipped "$tag" no-git "ls -la"
  expect_skipped "$tag" git-inside-word "echo digital gitignore"
  expect_allow "$tag" readonly-quote-split "g''it status"
done

# re_all is the last column of master-hook's registry rows. A jq that ends
# rows with CRLF (jq.exe on Windows) must not leave the CR on its last regex,
# or the expansion spellings above skip the guard again.
REAL_JQ="$(command -v jq)"
mkdir -p "$TMP/crlf-jq"
cat > "$TMP/crlf-jq/jq" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *prefilter.re_all*) "$REAL_JQ" "\$@" | sed 's/\$/\r/' ;;
  *) exec "$REAL_JQ" "\$@" ;;
esac
EOF
chmod +x "$TMP/crlf-jq/jq"
for BASH_BIN in "${BASHES[@]}"; do
  v="$("$BASH_BIN" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
  rm -rf "$FIXTURE/workspace/orchestrator/hook-state/registry-rows"
  PATH="$TMP/crlf-jq:$PATH" expect_deny "bash $v crlf-jq" var-concat-name-crlf 'a=gi; b=t; $a$b commit -m x'
done

printf 'master-hook-git-spellings-prefilter: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
