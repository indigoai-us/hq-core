#!/usr/bin/env bash
# hq-core: public
# hook-adapter-crlf-jq.test.sh — the Codex/Grok hook adapter dispatches the
# same records when jq writes CRLF line endings (Windows jq.exe from winget).
#
# feedback_ec9435cd: jq 1.8.x on Windows ends every output line with \r\n.
# hook-adapter-core.sh reads settings and registry frames from `jq -r`, so the
# trailing \r was glued to the last field of each frame (the hook command,
# the last exec arg, or the policy_vocab flag) and tool-scoped hooks silently
# failed to dispatch. The fix strips one trailing CR per frame line inside the
# adapter and keeps jq's own exit status (a shim like `jq "$@" | tr -d '\r'`
# would swallow `jq -e` failures and turn fail-closed checks into passes).
#
# This test runs the adapter with the real jq and with a CRLF-emitting jq shim
# that preserves jq's exit status, and requires identical dispatch output.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
FAIL=0
pass() { echo "  ok: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }
REAL_JQ="$(command -v jq)"

TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_TMP="$(cd "$TASK_TMP" && pwd -P)"
export HOME="$TASK_TMP/home" USERPROFILE="$TASK_TMP/home"
mkdir -p "$HOME" "$TASK_TMP/crlf-bin"

# CRLF jq shim: real jq output with \r before every \n; jq's exit status kept.
cat > "$TASK_TMP/crlf-bin/jq" <<SHIM
#!/usr/bin/env bash
out_file="\$(mktemp)" || exit 2
"$REAL_JQ" "\$@" > "\$out_file"
rc=\$?
awk '{ printf "%s\\r\\n", \$0 }' "\$out_file"
rm -f "\$out_file"
exit "\$rc"
SHIM
chmod +x "$TASK_TMP/crlf-bin/jq"

# Sanity: the shim really emits CR and keeps jq -e's failure exit.
printf '{"a":"Bash"}' > "$TASK_TMP/probe.json"
if PATH="$TASK_TMP/crlf-bin:$PATH" jq -r .a < "$TASK_TMP/probe.json" | od -c | grep -q '\\r'; then
  pass "shim emits CRLF"
else
  fail "shim does not emit CR; test would prove nothing"
fi
PATH="$TASK_TMP/crlf-bin:$PATH" jq -e .missing < "$TASK_TMP/probe.json" >/dev/null 2>&1
[ "$?" -ne 0 ] && pass "shim preserves jq -e exit status" || fail "shim swallowed jq -e exit status"

FIX="$TASK_TMP/hq"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts/lib"
cp "$ROOT/.claude/settings.json" "$FIX/.claude/settings.json"
cp "$ROOT/.claude/hooks/hook-registry.json" "$FIX/.claude/hooks/hook-registry.json"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIX/core/scripts/lib/hook-adapter-core.sh"

# Fixture registry hook with an end-anchored prefilter regex. The prefilter
# text is the last field of the payload frame, so a CR left on that frame
# (the strip in hqad_prefilter_payload_fields) makes `status$` stop matching
# and the hook drops out of the CRLF dispatch set.
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/.claude/hooks/fixture-end-anchored.sh"
reg_tmp="$TASK_TMP/registry.json"
jq '.hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{"matcher":"Bash","hooks":[{"id":"fixture-end-anchored","script":".claude/hooks/fixture-end-anchored.sh","prefilter":{"re":"git status$"}}]}])' \
  "$FIX/.claude/hooks/hook-registry.json" > "$reg_tmp" && mv "$reg_tmp" "$FIX/.claude/hooks/hook-registry.json"
# An empty policy-trigger ledger lets the policy_vocab prefilter decide from
# the tool text instead of always keeping the injector.
mkdir -p "$FIX/workspace/orchestrator/policy-trigger-state"
: > "$FIX/workspace/orchestrator/policy-trigger-state/s1.txt"

run_iter() { # <path-prefix> <event> <tool> <payload>
  local prefix="$1" event="$2" tool="$3" payload="$4"
  # HQ_HOOK_TRACE=1 prints every registry frame's decoded fields (policy_vocab
  # is the last one), so a CR left on a registry frame shows up as a diff.
  PATH="$prefix$PATH" HQ_ROOT="$FIX" HQ_HARNESS=codex HQ_HOOK_TRACE=1 bash -c '
    # shellcheck disable=SC1091
    . "$HQ_ROOT/core/scripts/lib/hook-adapter-core.sh"
    hqad_iter_settings "$1" "$2" "$3"
  ' _ "$event" "$tool" "$payload" 2>&1
}

check_event() { # <event> <tool> <payload>
  local event="$1" tool="$2" payload="$3" lf crlf
  lf="$(run_iter "" "$event" "$tool" "$payload")"
  crlf="$(run_iter "$TASK_TMP/crlf-bin:" "$event" "$tool" "$payload")"
  if [ -z "$lf" ]; then
    fail "$event/$tool: adapter emitted no records with LF jq (fixture broken)"
    return
  fi
  case "$crlf" in
    *$'\r'*) fail "$event/$tool: a CR leaked into dispatch records" ;;
  esac
  if [ "$lf" = "$crlf" ]; then
    pass "$event/$tool: CRLF jq dispatches the same records as LF jq"
  else
    fail "$event/$tool: CRLF jq changed dispatch records"
    diff <(printf '%s\n' "$lf") <(printf '%s\n' "$crlf") | head -20 >&2
  fi
}

check_event PreToolUse Bash '{"session_id":"s1","cwd":"/x","tool_name":"Bash","tool_input":{"command":"git status"}}'

# The fixture hook must dispatch for `git status`, or the prefilter-strip
# coverage above proves nothing.
case "$(run_iter "$TASK_TMP/crlf-bin:" PreToolUse Bash '{"session_id":"s1","cwd":"/x","tool_name":"Bash","tool_input":{"command":"git status"}}')" in
  *fixture-end-anchored.sh*) pass "end-anchored registry prefilter matches under CRLF jq" ;;
  *) fail "end-anchored registry prefilter did not match under CRLF jq" ;;
esac
check_event PreToolUse Edit '{"session_id":"s1","cwd":"/x","tool_name":"Edit","tool_input":{"file_path":"/x/a.md"}}'
check_event PostToolUse Bash '{"session_id":"s1","cwd":"/x","tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{}}'
check_event SessionStart "" '{"session_id":"s1","cwd":"/x"}'
check_event UserPromptSubmit "" '{"session_id":"s1","cwd":"/x","prompt":"hello"}'

[ "$FAIL" -eq 0 ] && echo "PASS: hook-adapter-crlf-jq" || { echo "FAIL: $FAIL case(s)" >&2; exit 1; }
