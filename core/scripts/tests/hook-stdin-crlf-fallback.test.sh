#!/usr/bin/env bash
# The three Bash guards that read HQ_HOOK_COMMAND fall back to parsing the
# stdin payload when it is unset: master-hook leaves it unset for commands over
# HQ_HOOK_COMMAND_ENV_MAX, and the adapters never set it. Native Windows jq.exe
# writes stdout in text mode, so every LF inside the command comes back as
# CRLF. Before hq_crlf_to_lf, `cd "<HQ>"` + newline + `git commit` reached the
# guards as `cd "<HQ>"\r` and matched nothing, while bash ran the LF command.
#
# On macOS and Linux a jq wrapper turns LF into CRLF to reproduce jq.exe. On
# Windows the real jq.exe already does, and the wrapper is not used.
set -euo pipefail
TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="${HOOK_ROOT_OVERRIDE:-$(git -C "$TEST_DIR/../../.." rev-parse --show-toplevel)}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

REAL_JQ="$(command -v jq)"
NATIVE_CRLF=0
if [[ "$(printf '"a\\nb"' | jq -j . | od -An -c | tr -d ' \n')" == 'a\r\nb' ]]; then
  NATIVE_CRLF=1
fi
mkdir -p "$TMP/crlf-jq-bin"
cat > "$TMP/crlf-jq-bin/jq" <<'JQ'
#!/usr/bin/env bash
set -o pipefail
"${HQ_TEST_REAL_JQ:?}" "$@" | perl -pe 's/\n/\r\n/g'
JQ
chmod +x "$TMP/crlf-jq-bin/jq"
if (( NATIVE_CRLF )); then
  CRLF_PATH="$PATH"
  printf 'jq writes CRLF natively; using the real jq\n'
else
  CRLF_PATH="$TMP/crlf-jq-bin:$PATH"
fi

# The wrapper (or jq.exe) must really produce CRLF, or the cases below prove
# nothing.
sample="$(printf '%s' '{"tool_input":{"command":"a\nb"}}' \
  | HQ_TEST_REAL_JQ="$REAL_JQ" PATH="$CRLF_PATH" jq -j '.tool_input.command' | od -An -c | tr -d ' \n')"
if [[ "$sample" == 'a\r\nb' ]]; then
  pass "simulated jq output turns LF into CRLF"
else
  fail "simulated jq output is not CRLF ($sample)"
fi

# hq_crlf_to_lf collapses CRLF pairs only and keeps a lone CR.
# shellcheck source=/dev/null
. "$ROOT/core/scripts/hook-lib.sh"
probe=$'cd /x\r\n git init\r\r\nlone\rcr'
probe_cwd=$'/tmp/a\r\nb'
hq_crlf_to_lf probe probe_cwd
if [[ "$probe" == $'cd /x\n git init\r\nlone\rcr' && "$probe_cwd" == $'/tmp/a\nb' ]]; then
  pass "hq_crlf_to_lf collapses CRLF pairs and keeps a lone CR"
else
  fail "hq_crlf_to_lf produced $(printf '%s' "$probe" | od -An -c | tr -d '\n')"
fi

# hq_crlf_to_lf must match ${s//$'\r\n'/$'\n'} exactly and stay linear. The
# ${//} form took over a minute for 5,000 CRLF lines on bash 3.2, and a guard
# that passes its hook timeout does not block. Bash 4+ and bash 3.2 take
# different branches, so run the check under each bash this machine has.
cat > "$TMP/crlf-equiv.sh" <<'EQUIV'
set -u
. "$1"
fails=0
check() {
  local v="$1" want="${1//$'\r\n'/$'\n'}"
  hq_crlf_to_lf v
  if [[ "$v" != "$want" ]]; then
    fails=$((fails + 1))
    printf 'mismatch in=%q got=%q want=%q\n' "$1" "$v" "$want" >&2
  fi
}
for s in '' a $'\r' $'\n' $'\r\n' $'\r\r\n' $'\r\n\r\n' $'a\r' $'a\r\n' $'\ra' \
  $'\r\nb' $'a\rb\r\nc' $'a\r\r\r\nb\r' $'x\n\r\n\r\r' $'\\\r\n\\' $'a\r\n\n' \
  $'a\r\nx\r' $'x\r\nx' $'\n\n\r\n' $'  lead\r\n  trail  ' $'a\tb\r\nc\td'; do
  check "$s"
done
alpha=($'\r' $'\n' a x ' ' '\' $'\t')
RANDOM=1421
for ((i = 0; i < 2000; i++)); do
  s=""
  for ((j = RANDOM % 12; j > 0; j--)); do s+="${alpha[RANDOM % 7]}"; done
  check "$s"
done
# Build the input with printf -v: Git Bash drops the CR from CRLF in $(...)
# output, which would leave no CRLF to collapse.
printf -v long 'echo %d\r\n' {1..10000}
[[ "$long" == *$'echo 9999\r\necho 10000\r\n' ]] || fails=$((fails + 1))
# Time in this shell, not a $(...) subshell, so the collapse is checked too.
TIMEFORMAT=%R
{ time hq_crlf_to_lf long; } 2> "$2"
[[ "$long" == *$'\r'* || "$long" != *$'echo 9999\necho 10000\n' ]] && fails=$((fails + 1))
printf '%s %s %s\n' "$fails" "$(<"$2")" "${BASH_VERSINFO[0]}"
EQUIV
CRLF_BASHES=(bash)
if [[ -x /bin/bash && "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" != "$(bash -c 'echo "${BASH_VERSINFO[0]}"')" ]]; then
  CRLF_BASHES+=(/bin/bash)
fi
for crlf_bash in "${CRLF_BASHES[@]}"; do
  read -r equiv_fails equiv_secs equiv_major < <("$crlf_bash" "$TMP/crlf-equiv.sh" "$ROOT/core/scripts/hook-lib.sh" "$TMP/crlf-equiv.time")
  if [[ "$equiv_fails" == 0 ]] && awk -v t="$equiv_secs" 'BEGIN { exit !(t + 0 < 1) }'; then
    pass "hq_crlf_to_lf on bash $equiv_major matches \${s//CRLF/LF} and collapses 10,000 CRLF lines in ${equiv_secs}s (< 1s)"
  else
    fail "hq_crlf_to_lf on bash $equiv_major: $equiv_fails mismatches, 10,000 CRLF lines took ${equiv_secs}s (limit 1s)"
  fi
done

FIXTURE="$TMP/hq-root"
COMPANY_COMPONENT=com
COMPANY_COMPONENT+=panies
POLICY_COMPONENT=polic
POLICY_COMPONENT+=ies
mkdir -p "$FIXTURE/$COMPANY_COMPONENT/example-co" "$FIXTURE/personal/$POLICY_COMPONENT" \
  "$FIXTURE/core/scripts" "$TMP/elsewhere"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIXTURE/core/scripts/hook-lib.sh"
git -C "$FIXTURE" init -q
git -C "$TMP/elsewhere" init -q
PADDING="$(printf '%020000d' 0)"

# run_guard <crlf|lf> <hook> <label> <command>
# Direct guard call with HQ_HOOK_COMMAND unset, as master-hook leaves it for
# an oversized command. The payload cwd is a separate repo, so only the `cd`
# on the first line can point the guard at HQ.
run_guard() {
  local mode="$1" hook="$2" label="$3" command_text="$4" payload rc=0 path="$PATH"
  [[ "$mode" == crlf ]] && path="$CRLF_PATH"
  printf '%s' "$command_text" > "$TMP/$label.command"
  payload="$(jq -cn --rawfile cmd "$TMP/$label.command" --arg cwd "$TMP/elsewhere" \
    '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}')"
  printf '%s' "$payload" | (
    cd "$TMP/elsewhere"
    env -u HQ_HOOK_COMMAND -u HQ_HOOK_CWD -u HQ_HOOK_TOOL_NAME -u HQ_ALLOW_HQ_ROOT_GIT \
      HQ_TEST_REAL_JQ="$REAL_JQ" PATH="$path" CLAUDE_PROJECT_DIR="$FIXTURE" \
      bash "$ROOT/.claude/hooks/$hook" > "$TMP/$label.out" 2> "$TMP/$label.err"
  ) || rc=$?
  printf '%s\n' "$rc" > "$TMP/$label.rc"
}
assert_deny() {
  local label="$1" marker="$2" rc
  rc="$(<"$TMP/$label.rc")"
  if [[ "$rc" == 2 ]] && grep -Fq "$marker" "$TMP/$label.err"; then
    pass "$label denied"
  else
    fail "$label expected exit 2 and '$marker'; got exit $rc, stderr=$(head -c 400 "$TMP/$label.err")"
  fi
}

ROOT_COMMIT="cd \"$FIXTURE\""$'\n'" git commit -m x"
COMPANY_INIT="cd \"$FIXTURE/$COMPANY_COMPONENT/example-co\""$'\n'" git init"
POLICY_WRITE="cd \"$FIXTURE/personal/$POLICY_COMPONENT\""$'\n'" echo x > new.md"
LARGE_PREFIX="printf '%s' $PADDING >/dev/null"$'\n'

for mode in lf crlf; do
  for size in small large; do
    prefix=""
    [[ "$size" == large ]] && prefix="$LARGE_PREFIX"
    run_guard "$mode" block-hq-root-git-mutation.sh "root-commit-$size-$mode" "$prefix$ROOT_COMMIT"
    assert_deny "root-commit-$size-$mode" "BLOCKED"
    run_guard "$mode" block-company-repo-creation.sh "company-init-$size-$mode" "$prefix$COMPANY_INIT"
    assert_deny "company-init-$size-$mode" "Git repositories cannot be created or populated under $COMPANY_COMPONENT/"
    run_guard "$mode" block-policy-writes-bash.sh "policy-write-$size-$mode" "$prefix$POLICY_WRITE"
    assert_deny "policy-write-$size-$mode" "BLOCKED"
  done
done

if (( FAIL )); then
  printf 'hook-stdin-crlf-fallback: %s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf 'hook-stdin-crlf-fallback: %s passed, 0 failed\n' "$PASS"
