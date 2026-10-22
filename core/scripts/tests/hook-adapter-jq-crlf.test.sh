#!/usr/bin/env bash
# hq-core: public
# hook-adapter-jq-crlf.test.sh — the Codex/Grok dispatch library must give the
# same records when jq writes CRLF line ends.
#
# Native Windows jq.exe (for example jq 1.8.2 from winget) writes stdout in
# text mode, so every `jq -r` line ends in CR LF. hook-adapter-core.sh decodes
# jq's @sh records with eval; a trailing CR became part of the last word, so
# every settings command arrived as `<command>\r` and no master-hook.sh fan-out
# ran under Codex or Grok on Windows (feedback ec9435cd, defect 3).
#
# This test puts a jq shim on PATH that turns LF into CR LF and keeps jq's own
# exit status, then checks that hqad_iter_settings, hqad_iter_registry and
# hqad_prefilter_payload_fields give byte-identical output to plain jq.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
FAIL=0
pass() { echo "  ok: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

REAL_JQ="$(command -v jq 2>/dev/null || true)"
[ -n "$REAL_JQ" ] || { echo "SKIP: jq unavailable" >&2; exit 0; }

TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_TMP="$(cd "$TASK_TMP" && pwd -P)"

# CRLF jq: the same output as jq.exe in text mode, with jq's exit status.
# It drops a CR first, so a real jq.exe (Windows CI) does not give CR CR LF.
export REAL_JQ
mkdir -p "$TASK_TMP/crlf-bin"
cat > "$TASK_TMP/crlf-bin/jq" <<'SHIM'
#!/usr/bin/env bash
cr=$'\r'
"$REAL_JQ" "$@" | sed "s/${cr}\$//; s/\$/${cr}/"
exit "${PIPESTATUS[0]}"
SHIM
chmod +x "$TASK_TMP/crlf-bin/jq"

# The shim itself must behave like jq.exe, or this test proves nothing.
# Compare bytes through files: Git for Windows Bash drops a trailing CR in
# $(...), so a substitution-based check fails there although the shim writes
# CR LF (Windows CI job 119678951819 dumped B a s h \r \n for real jq.exe,
# this shim, and a read/printf variant alike).
printf '{"m":"Bash"}' | PATH="$TASK_TMP/crlf-bin:$PATH" jq -r .m > "$TASK_TMP/shim.out"
printf 'Bash\r\n' > "$TASK_TMP/shim.want"
if cmp -s "$TASK_TMP/shim.out" "$TASK_TMP/shim.want"; then
  pass "shim writes CRLF"
else
  fail "shim did not write CRLF"
  od -c "$TASK_TMP/shim.out" >&2
fi
printf 'null' | PATH="$TASK_TMP/crlf-bin:$PATH" jq -e . >/dev/null 2>&1
[ "$?" -eq 1 ] && pass "shim keeps jq -e exit status" || fail "shim lost jq -e exit status"

FIX="$TASK_TMP/hq"
mkdir -p "$FIX/.claude" "$FIX/core/scripts/lib"
cp "$ROOT/.claude/settings.json" "$FIX/.claude/settings.json"
cp -R "$ROOT/.claude/hooks" "$FIX/.claude/hooks"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIX/core/scripts/hook-lib.sh"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIX/core/scripts/lib/hook-adapter-core.sh"

cat > "$TASK_TMP/probe.sh" <<'PROBE'
#!/usr/bin/env bash
export HQ_ROOT="$1"
. "$HQ_ROOT/core/scripts/hook-lib.sh" 2>/dev/null || true
. "$HQ_ROOT/core/scripts/lib/hook-adapter-core.sh"
payload='{"tool_name":"Bash","tool_input":{"command":"git status"},"session_id":"s1","cwd":"/tmp","prompt":"hi"}'
for spec in SessionStart:Bash UserPromptSubmit:Bash PreToolUse:Bash PreToolUse:Read \
  PreToolUse:Edit PostToolUse:Bash Stop:Bash PreCompact:Bash SubagentStop:Agent; do
  ev="${spec%%:*}"; tool="${spec#*:}"
  printf '== settings %s %s\n' "$ev" "$tool"
  hqad_iter_settings "$ev" "$tool" "$payload" 2>&1
  printf '== registry %s %s\n' "$ev" "$tool"
  hqad_iter_registry "$ev" "$tool" "$payload" 2>&1
  printf '== fields %s\n' "$ev"
  fields="$(hqad_prefilter_payload_fields "$ev" "$payload")" || printf 'fields-failed\n'
  eval "set -- $fields"
  printf '[%s]\n' "$@"
done
PROBE

run_probe() { # $1 = extra PATH entry or empty
  local home="$TASK_TMP/home-$2"
  mkdir -p "$home"
  rm -rf "$FIX/workspace"
  HOME="$home" USERPROFILE="$home" PATH="${1:+$1:}$PATH" HQ_HOOK_TRACE='' \
    bash "$TASK_TMP/probe.sh" "$FIX"
}

lf_out="$(run_probe '' lf)"
crlf_out="$(run_probe "$TASK_TMP/crlf-bin" crlf)"

case "$lf_out" in
  *"master	PreToolUse"*) pass "plain jq dispatches the PreToolUse master fan-out" ;;
  *) fail "plain jq run dispatched no PreToolUse master record (fixture broken)" ;;
esac
if [ "$crlf_out" = "$lf_out" ]; then
  pass "CRLF jq gives the same dispatch records as plain jq"
else
  fail "CRLF jq changed the dispatch records"
  diff <(printf '%s\n' "$lf_out") <(printf '%s\n' "$crlf_out" | sed "s/$(printf '\r')/<CR>/g") | head -20 >&2
fi
case "$crlf_out" in
  *$'\r'*) fail "a CR reached the dispatch records" ;;
  *) pass "no CR reaches the dispatch records" ;;
esac

if [ "$FAIL" -eq 0 ]; then
  echo "hook-adapter-jq-crlf: all passed"
  exit 0
fi
echo "hook-adapter-jq-crlf: $FAIL failed" >&2
exit 1
