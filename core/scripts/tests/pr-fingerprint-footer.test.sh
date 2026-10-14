#!/usr/bin/env bash
# hq-core: public
# Tests for .claude/hooks/pr-fingerprint-footer.sh with stub gh and hq on PATH.
# shellcheck disable=SC2015 # `ok` always returns 0, so `A && ok || no` is safe.
set -uo pipefail

for v in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HOOK="$ROOT/.claude/hooks/pr-fingerprint-footer.sh"
BASH_BIN="$(command -v bash)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pr-fp-footer-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/tmpd" "$TMP/home"
# shellcheck source=../hook-lib.sh
. "$ROOT/core/scripts/hook-lib.sh"

cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_GH_LOG:-}" ] || printf "%s\n" "$*" >>"$STUB_DIR/gh-calls"
case "$1 $2" in
  "pr view") cat "$STUB_DIR/current" ;;
  "pr edit")
    if [ "${STUB_GH_HANG:-}" = 1 ]; then
      while :; do sleep 1; done
    fi
    printf '%s\n' "$*" >>"$STUB_DIR/edits"; cat "$5" >"$STUB_DIR/edited" ;;
esac
STUB
cat >"$TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
printf x >>"$STUB_DIR/hq-calls"
printf '{"fingerprint":"hqfp1:abc123"}\n'
STUB
chmod 755 "$TMP/bin/gh" "$TMP/bin/hq"
export STUB_DIR="$TMP" PATH="$TMP/bin:$PATH" CLAUDE_PROJECT_DIR="$ROOT" HQ_ROOT="$ROOT" HQ_FINGERPRINT_CACHE_DIR="$TMP/cache"
unset HQ_FINGERPRINT_BIN STUB_GH_HANG

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
reset() { rm -f "$TMP/edits" "$TMP/edited"; printf '%s\n' "$1" >"$TMP/current"; }
js() { printf '%s' "$1" | hq_json_encode | tr -d '\n'; }
payload() { # command stdout [stderr]
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"tool_response":{"stdout":%s,"stderr":%s}}' \
    "$(js "$1")" "$(js "$2")" "$(js "${3:-}")"
}
no_edit() { [ ! -f "$TMP/edits" ] && ok "$1" || no "$1"; }

reset "Body text"
payload "gh pr create -R o/r --title t --body x" "https://github.com/o/r/pull/9" | bash "$HOOK" >"$TMP/out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$TMP/out" ] && ok "silent exit 0" || no "silent exit 0"
grep -q 'pr edit https://github.com/o/r/pull/9 --body-file' "$TMP/edits" 2>/dev/null && ok "raw gh pr create gets edited" || no "raw gh pr create gets edited"
[ "$(cat "$TMP/edited" 2>/dev/null)" = $'Body text\n\n---\nHQ-Fingerprint: hqfp1:abc123' ] && ok "footer appended" || no "footer appended"

reset $'Body\n\n---\nHQ-Fingerprint: hqfp1:abc123'
payload "gh pr create -R o/r" "https://github.com/o/r/pull/9" | bash "$HOOK"
no_edit "existing footer left alone"

reset "Body"
payload "bash core/scripts/hq-pr-create.sh -R o/r --title t" "https://github.com/o/r/pull/9" | bash "$HOOK"
no_edit "wrapper call skipped (relative path)"

reset "Body"
payload "bash \"\$HQ_ROOT/core/scripts/hq-pr-create.sh\" -R o/r --title t" "https://github.com/o/r/pull/9" | bash "$HOOK"
no_edit "wrapper call skipped (absolute path)"

reset "Body"
payload "gh pr create -R o/r" "error: no commits" | bash "$HOOK"
no_edit "no PR URL skipped"

reset "Body"
payload "git status" "https://github.com/o/r/pull/9" | bash "$HOOK"
no_edit "other commands skipped"

reset "Body"
HQ_FINGERPRINT_BIN="$TMP/missing" payload "gh pr create -R o/r" "https://github.com/o/r/pull/9" | HQ_FINGERPRINT_BIN="$TMP/missing" bash "$HOOK"
no_edit "no fingerprint skipped"

# Review regressions: none of these opened a PR, so none may edit one.
reset "Body"
payload "gh pr view 9 -R o/r" $'Title\nrun gh pr create next time\nhttps://github.com/o/r/pull/9' | bash "$HOOK"
no_edit "gh pr view output mentioning gh pr create skipped"

reset "Body"
payload "gh pr list --search \"gh pr create\" -R o/r" $'https://github.com/o/r/pull/5' | bash "$HOOK"
no_edit "gh pr create inside a quoted argument skipped"

reset "Body"
payload "gh pr create -R o/r --body \"see https://github.com/o/r/pull/5\"" "error: nothing to compare" | bash "$HOOK"
no_edit "URL only in the command text skipped"

reset "Body"
payload $'cat <<EOF > notes.md\ngh pr create -R o/r\nhttps://github.com/o/r/pull/3\nEOF\ncat notes.md' $'gh pr create -R o/r\nhttps://github.com/o/r/pull/3' | bash "$HOOK"
no_edit "gh pr create inside a heredoc skipped"

reset "Body"
payload "gh pr create -R o/r --title t" "" $'a pull request for branch "x" into branch "main" already exists:\nhttps://github.com/o/r/pull/4' | bash "$HOOK"
no_edit "URL only on stderr (already exists) skipped"

reset "Body"
payload "echo gh pr create" "https://github.com/o/r/pull/6" | bash "$HOOK"
no_edit "echo of gh pr create skipped"

# Positive: a real command after a heredoc and an env prefix still fires.
reset "Body two"
payload $'cat <<\'EOF\' > b.md\nbody\nEOF\nGH_PROMPT_DISABLED=1 gh pr create -R o/r -F b.md' $'Creating pull request\nhttps://github.com/o/r/pull/12\n' | bash "$HOOK"
grep -q 'pr edit https://github.com/o/r/pull/12 --body-file' "$TMP/edits" 2>/dev/null && ok "real gh pr create after heredoc gets edited" || no "real gh pr create after heredoc gets edited"

# --dry-run and --web open no PR: never edit, even with a URL as the last line.
reset "Body"
payload "gh pr create -R o/r --dry-run --title t --body x" $'would create\nhttps://github.com/o/r/pull/9\n' | bash "$HOOK"
no_edit "--dry-run with URL last line skipped"
reset "Body"
payload "gh pr create -R o/r --web" "https://github.com/o/r/pull/9" | bash "$HOOK"
no_edit "--web skipped"
reset "Body"
payload "gh pr create -R o/r --title --dry-run --body x" "https://github.com/o/r/pull/9" | bash "$HOOK"
grep -q 'pr edit https://github.com/o/r/pull/9' "$TMP/edits" 2>/dev/null && ok "--dry-run as a flag value still fires" || no "--dry-run as a flag value still fires"

# Session id: with no payload session id the hook reads the same ordered list as
# the wrapper, so a Codex thread or Grok session reuses the wrapper's cache.
nosid=(env -u HQ_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID
  -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID)
for pair in CODEX_THREAD_ID=thr-1 GROK_SESSION_ID=grok-1; do
  rm -rf "$TMP/cache"; rm -f "$TMP/hq-calls"
  "${nosid[@]}" "$pair" HQ_PR_CREATE_FINGERPRINT_ONLY=1 bash "$ROOT/core/scripts/hq-pr-create.sh" </dev/null >/dev/null
  reset "Body"
  payload "gh pr create -R o/r" "https://github.com/o/r/pull/9" | "${nosid[@]}" "$pair" bash "$HOOK"
  if [ "$(cat "$TMP/hq-calls")" = x ] && grep -q 'pr edit https://github.com/o/r/pull/9' "$TMP/edits" 2>/dev/null; then
    ok "${pair%%=*}: hook reuses the wrapper cache"
  else
    no "${pair%%=*}: hook reuses the wrapper cache"
  fi
done
# The payload session id outranks the environment.
reset "Body"
payload "gh pr create -R o/r" "https://github.com/o/r/pull/9" | sed 's/^{/{"session_id":"pay-1",/' \
  | "${nosid[@]}" GROK_SESSION_ID=grok-1 bash "$HOOK"
[ "$(cat "$TMP/hq-calls")" = xx ] && ok "payload session id outranks the environment" || no "payload session id outranks the environment"

# Kill switch: the setting is read before gh is called, so gh never runs.
mkdir -p "$TMP/fproot/core/scripts" "$TMP/fproot/personal/settings"
cp "$ROOT/core/scripts/hq-pr-create.sh" "$TMP/fproot/core/scripts/"
printf 'enabled: false\n' >"$TMP/fproot/personal/settings/fingerprint.yaml"
reset "Body"
rm -f "$TMP/gh-calls"
payload "gh pr create -R o/r" "https://github.com/o/r/pull/9" | STUB_GH_LOG=1 CLAUDE_PROJECT_DIR="$TMP/fproot" bash "$HOOK"
[ ! -f "$TMP/gh-calls" ] && ok "setting off: zero gh calls" || no "setting off: zero gh calls"
no_edit "setting off: no edit"


# Timeout: a hanging gh is killed with its worker, and the temp file is removed.
reset "Body"
start=$(date +%s)
payload "gh pr create -R o/r" "https://github.com/o/r/pull/9" | STUB_GH_HANG=1 TMPDIR="$TMP/tmpd" bash "$HOOK"
elapsed=$(( $(date +%s) - start ))
sleep 0.5
[ "$elapsed" -le 13 ] && ok "hook returns at the 10 s cap ($elapsed s)" || no "hook returns at the 10 s cap ($elapsed s)"
pgrep -f "$TMP/bin/gh" >/dev/null 2>&1 && no "hung gh killed" || ok "hung gh killed"
left="$(find "$TMP/tmpd" -name 'hq-pr-fp-edit.*' | wc -l | tr -d ' ')"
[ "$left" = 0 ] && ok "edit temp file removed after timeout" || no "edit temp file removed after timeout ($left left)"

# No jq and no node: exit 0, no edit, one log line.
mkdir -p "$TMP/nojson"
for t in cat dirname mkdir date sed tr uname; do
  p="$(command -v "$t")" && ln -sf "$p" "$TMP/nojson/$t"
done
reset "Body"
payload "gh pr create -R o/r" "https://github.com/o/r/pull/9" | HOME="$TMP/home" PATH="$TMP/nojson" "$BASH_BIN" "$HOOK" >"$TMP/out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$TMP/out" ] && ok "no JSON reader: silent exit 0" || no "no JSON reader: silent exit 0"
no_edit "no JSON reader: no edit"
[ "$(grep -c 'pr-fingerprint-footer: skipped, neither jq nor node' "$TMP/home/.hq/fingerprint-hook.log" 2>/dev/null)" = 1 ] && ok "no JSON reader: skip logged once" || no "no JSON reader: skip logged once"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
