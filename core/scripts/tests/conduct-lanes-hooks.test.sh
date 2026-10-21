#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/root/workspace/lanes-links/by-session"
export PATH="$BIN:/usr/bin:/bin"
export CLAUDE_PROJECT_DIR="$TMP/root"
export FAKE_CALLS="$TMP/calls" FAKE_INPUT="$TMP/input" FAKE_NO_SELF_UPDATE="$TMP/no-self-update" FAKE_DISABLED_HOOKS="$TMP/disabled-hooks" FAKE_MODE=ok
export FAKE_VERSION=5.345.63 FAKE_STDOUT=$'linked output\nsecond line\n'

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

cat > "$BIN/hq" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_CALLS"
if [ "${1:-}" = --version ]; then printf '%s\n' "$FAKE_VERSION"; exit 0; fi
printf '%s' "${HQ_NO_SELF_UPDATE:-}" > "$FAKE_NO_SELF_UPDATE"
printf '%s' "${HQ_DISABLED_HOOKS:-}" > "$FAKE_DISABLED_HOOKS"
cat > "$FAKE_INPUT"
case "$FAKE_MODE" in
  fail) echo fake-error >&2; printf 'discard this\n'; exit 7 ;;
  timeout) exec sleep 10 ;;
esac
printf '%s' "$FAKE_STDOUT"
FAKE
chmod +x "$BIN/hq"

SESSION="$ROOT/.claude/hooks/conduct-lanes-session-start.sh"
LINK="$ROOT/.claude/hooks/conduct-lanes-link-deliver.sh"
PAYLOAD="$TMP/payload.json"
printf '%s' '{"hookEventName":"SessionStart","source":"startup","session_id":"sid-1"}' > "$PAYLOAD"

: > "$FAKE_CALLS"
"$SESSION" < "$PAYLOAD" > "$TMP/out" 2> "$TMP/err"
cmp -s <(printf '%s' "$FAKE_STDOUT") "$TMP/out" || fail 'SessionStart output was not passed through byte for byte'
cmp -s "$PAYLOAD" "$FAKE_INPUT" || fail 'SessionStart payload was not passed through'
grep -Fxq 'lanes session-start' "$FAKE_CALLS" || fail 'SessionStart did not call hq lanes session-start'
[ "$(cat "$FAKE_NO_SELF_UPDATE")" = 1 ] || fail 'SessionStart did not disable hq self-update'
[ ! -s "$TMP/err" ] || fail 'SessionStart emitted stderr on success'
HQ_DISABLED_HOOKS=auto-conduct "$SESSION" < "$PAYLOAD" > /dev/null 2> "$TMP/err"
[ "$(cat "$FAKE_DISABLED_HOOKS")" = auto-conduct ] || fail 'SessionStart did not pass the existing off switch to hq-cli'
pass 'SessionStart passes payload and stdout through and disables self-update'

for mode in fail timeout; do
  : > "$FAKE_CALLS"
  FAKE_MODE="$mode" "$SESSION" < "$PAYLOAD" > "$TMP/out" 2> "$TMP/err"
  [ ! -s "$TMP/out" ] || fail "SessionStart $mode leaked stdout"
  [ ! -s "$TMP/err" ] || fail "SessionStart $mode leaked stderr"
  pass "SessionStart fails open on $mode with no output"
done

: > "$FAKE_CALLS"
FAKE_MODE=ok FAKE_VERSION=5.345.62 "$SESSION" < "$PAYLOAD" > "$TMP/out" 2> "$TMP/err"
[ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] || fail 'old hq CLI did not fail open silently'
! grep -q 'lanes session-start' "$FAKE_CALLS" || fail 'old hq CLI reached the new command'
pass 'SessionStart fails open below the CLI floor'

mkdir -p "$TMP/no-hq"
: > "$FAKE_CALLS"
PATH="$TMP/no-hq:/usr/bin:/bin" "$SESSION" < "$PAYLOAD" > "$TMP/out" 2> "$TMP/err"
[ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] || fail 'missing hq did not fail open silently'
pass 'SessionStart fails open when hq is missing'

: > "$FAKE_CALLS"
PAYLOAD_LINK='{"hookEventName":"PostToolUse","session_id":"sid-1"}'
printf '%s' "$PAYLOAD_LINK" > "$PAYLOAD"
"$LINK" PostToolUse < "$PAYLOAD" > "$TMP/out" 2> "$TMP/err"
[ ! -s "$FAKE_CALLS" ] && [ ! -s "$TMP/out" ] || fail 'unlinked session called hq or emitted output'
printf x > "$TMP/root/workspace/lanes-links/by-session/sid-1"

for event in PostToolUse Stop; do
  : > "$FAKE_CALLS"
  PAYLOAD_LINK="{\"hookEventName\":\"$event\",\"sessionId\":\"sid-1\",\"marker\":\"$event payload\"}"
  printf '%s' "$PAYLOAD_LINK" > "$PAYLOAD"
  FAKE_MODE=ok "$LINK" "$event" < "$PAYLOAD" > "$TMP/out" 2> "$TMP/err"
  cmp -s <(printf '%s' "$FAKE_STDOUT") "$TMP/out" || fail "$event output was not passed through byte for byte"
  cmp -s "$PAYLOAD" "$FAKE_INPUT" || fail "$event payload was not passed through"
  grep -Fxq "lanes link _deliver --event $event" "$FAKE_CALLS" || fail "$event did not call the expected hq command"
  pass "linked $event delegates payload and output to hq lanes link _deliver"
done

: > "$FAKE_CALLS"
printf '%s' '{"hookEventName":"SubagentStop","session_id":"sid-1","agent_id":"a1"}' > "$PAYLOAD"
"$LINK" SubagentStop < "$PAYLOAD" > "$TMP/out" 2> "$TMP/err"
[ ! -s "$FAKE_CALLS" ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] || fail 'SubagentStop reached hq or emitted output'
pass 'SubagentStop does not deliver the root message to the subagent'

for bad in '{bad json' '{"session_id":"../sid-1"}' '{"session_id":"."}' '{"session_id":".."}' '{"session_id":42}'; do
  : > "$FAKE_CALLS"
  printf '%s' "$bad" | "$LINK" PostToolUse > "$TMP/out" 2> "$TMP/err"
  [ ! -s "$FAKE_CALLS" ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] || fail "malformed or invalid payload was not inert: $bad"
done
pass 'malformed payloads and unsafe session ids are inert'

: > "$FAKE_CALLS"
printf '%s' "$PAYLOAD_LINK" > "$PAYLOAD"
"$LINK" PreToolUse < "$PAYLOAD" > "$TMP/out" 2> "$TMP/err"
[ ! -s "$FAKE_CALLS" ] && [ ! -s "$TMP/out" ] || fail 'PreToolUse reached hq or emitted output'
pass 'PreToolUse does not deliver'

jq -e '[.hooks.SessionStart[]?.hooks[]? | select(.id == "conduct-lanes-session-start")] | length == 1' "$ROOT/.claude/hooks/hook-registry.json" >/dev/null || fail 'new SessionStart hook is not registered once'
jq -e '[.hooks.SessionStart[]?.hooks[]? | select(.id == "auto-conduct")] | length == 0' "$ROOT/.claude/hooks/hook-registry.json" >/dev/null || fail 'old and new SessionStart hooks are both registered'
for event in PostToolUse Stop; do
  jq -e --arg event "$event" '[.hooks[$event][]?.hooks[]? | select(.id == "conduct-lanes-link-deliver")] | length == 1' "$ROOT/.claude/hooks/hook-registry.json" >/dev/null || fail "$event linked-session guard is not registered exactly once"
done
jq -e '[.hooks.SubagentStop[]?.hooks[]? | select(.id == "conduct-lanes-link-deliver")] | length == 0' "$ROOT/.claude/hooks/hook-registry.json" >/dev/null || fail 'SubagentStop still registers linked-session delivery'
pass 'registry has one SessionStart conductor and the PostToolUse and Stop delivery events'

# CI must run the root-only delivery suite and the Grok adapter suite on Linux
# and under stock macOS Bash 3.2. Without these steps a later edit can drop the
# agent_id child check, or reintroduce an unguarded empty-array expansion in the
# Grok adapter, and every check stays green.
WORKFLOW="$ROOT/.github/workflows/pr-checks.yml"
job_block() { awk -v job="  $1:" '$0 == job { on = 1; print; next } on && /^  [A-Za-z0-9_-]+:$/ { exit } on { print }' "$WORKFLOW"; }
# A grouped runner job (linux-checks-N) runs a former job as steps named
# "[former-job] step name". Print only that member's steps, so another
# member's step never satisfies the check.
member_steps() { awk -v tag="    - name: \"[$1] " 'index($0, tag) == 1 { on = 1; print; next } /^    - / || /^  [A-Za-z0-9_-]+:$/ { on = 0 } on { print }' "$WORKFLOW"; }
linux_job="$(job_block skill-script-refs)"
linux_member="$(member_steps skill-script-refs)"
macos_job="$(job_block shell-smoke-macos)"
for suite in conduct-lanes-hooks conduct-lanes-link-deliver-root-only hq-grok-hook-adapter; do
  grep -Fxq "        run: bash core/scripts/tests/$suite.test.sh" <<<"$linux_job" \
    || grep -Fxq "      run: bash core/scripts/tests/$suite.test.sh" <<<"$linux_member" \
    || fail "skill-script-refs CI job does not run $suite.test.sh"
done
for suite in conduct-lanes-link-deliver-root-only hq-grok-hook-adapter; do
  grep -Fxq "        run: /bin/bash core/scripts/tests/$suite.test.sh" <<<"$macos_job" || fail "shell-smoke-macos CI job does not run $suite.test.sh under /bin/bash"
done
grep -Fq "':(glob).claude/hooks/**'" "$ROOT/core/scripts/ci/should-run-macos-shell-smoke.sh" \
  && grep -Fq "':(glob).grok/hooks/**'" "$ROOT/core/scripts/ci/should-run-macos-shell-smoke.sh" \
  || fail 'shell-smoke-macos no longer triggers on .claude/hooks or .grok/hooks changes'
pass 'CI runs the root-only delivery and Grok adapter suites on Linux and under macOS /bin/bash'

legacy_calls='conduct-pool\.sh|conduct-inbox\.sh|conduct-link\.sh|conduct-reap\.sh|conduct-lane-status\.sh|conduct-lane-launch\.sh|conduct-lane-wait\.sh'
if grep -En "$legacy_calls" \
  "$ROOT/.claude/hooks/conduct-lanes-session-start.sh" \
  "$ROOT/.claude/hooks/conduct-lanes-link-deliver.sh" \
  "$ROOT/.grok/hooks/hq-grok-hook-adapter.sh"; then
  fail 'conduct hook migration source calls a legacy conduct script'
fi
pass 'migrated hook source calls no legacy conduct scripts'

TIMEFORMAT='%3R'
session_seconds="$({ time "$SESSION" < "$PAYLOAD" > /dev/null 2> /dev/null; } 2>&1)"
link_seconds="$({ time "$LINK" PostToolUse < "$PAYLOAD" > /dev/null 2> /dev/null; } 2>&1)"
printf 'MEASURE unlinked hook wall time SessionStart=%ss PostToolUse=%ss\n' "$session_seconds" "$link_seconds"

echo 'conduct-lanes-hooks: all checks passed'
