#!/usr/bin/env bash
# conduct-inbox.test.sh — coverage for the /conduct lane drop box and the hook
# that delivers from it.
#
# Two things have to hold for this channel to be trustworthy. A queued message
# must never be lost — a dropped instruction to a running lane is invisible, the
# lane simply carries on doing the wrong thing. And the hook must stay inert in
# every session that is not a lane, because it is registered on PostToolUse with
# matcher `*` and therefore runs on every tool call on the machine.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok — $1"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }
assert_contains() {
  case "$1" in *"$2"*) : ;; *) fail "$3: missing '$2' in: $1" ;; esac
}
assert_lacks() {
  case "$1" in *"$2"*) fail "$3: unexpected '$2' in: $1" ;; *) : ;; esac
}

mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts"
cp "$ROOT/core/scripts/conduct-inbox.sh" "$TMP/core/scripts/"
cp "$ROOT/.claude/hooks/conduct-lane-inbox.sh" "$TMP/.claude/hooks/"
chmod +x "$TMP/core/scripts/conduct-inbox.sh" "$TMP/.claude/hooks/conduct-lane-inbox.sh"

RUN="$TMP/run"
mkdir -p "$RUN"
inbox() { bash "$TMP/core/scripts/conduct-inbox.sh" "$@"; }
hook() {
  local event="$1" payload
  payload="$(printf '{"hook_event_name":"%s","session_id":"s1"}' "$event")"
  printf '%s' "$payload" | bash "$TMP/.claude/hooks/conduct-lane-inbox.sh" 2>/dev/null
}
pending_count() { inbox list --run-dir "$RUN" | sed -e 's/.*"pending":\([0-9]*\).*/\1/'; }
delivered_count() { inbox list --run-dir "$RUN" | sed -e 's/.*"delivered":\([0-9]*\).*/\1/'; }

echo "conduct-inbox: send then drain"
inbox send --run-dir "$RUN" --text "first instruction" >/dev/null
assert_eq "$(pending_count)" "1" "queued"
out="$(inbox drain --run-dir "$RUN")"
assert_contains "$out" "first instruction" "drained text"
assert_eq "$(pending_count)" "0" "queue emptied"
assert_eq "$(delivered_count)" "1" "claimed snapshot retained as an audit record"
ok "a message round-trips and the delivered copy is kept"

echo "conduct-inbox: draining an empty box is free and silent"
out="$(inbox drain --run-dir "$RUN")"
assert_eq "$out" "" "no output"
inbox drain --run-dir "$RUN" >/dev/null || fail "empty drain must exit 0"
ok "empty drain prints nothing and exits 0"

echo "conduct-inbox: messages are delivered oldest first"
inbox send --run-dir "$RUN" --text "AAA-one" >/dev/null
sleep 1
inbox send --run-dir "$RUN" --text "ZZZ-two" >/dev/null
out="$(inbox drain --run-dir "$RUN")"
first="$(printf '%s' "$out" | grep -n 'AAA-one' | cut -d: -f1)"
second="$(printf '%s' "$out" | grep -n 'ZZZ-two' | cut -d: -f1)"
[ "$first" -lt "$second" ] || fail "ordering: expected AAA-one before ZZZ-two, got: $out"
ok "ordering is oldest first"

echo "conduct-inbox: a send during a drain is not lost"
# The claim renames pending/ aside and recreates it. A read-then-delete drain
# would drop anything that landed in between; this proves the fresh queue exists
# and accepts a message immediately, and that the claimed copy is untouched.
inbox send --run-dir "$RUN" --text "in-flight-A" >/dev/null
out="$(inbox drain --run-dir "$RUN")"
inbox send --run-dir "$RUN" --text "in-flight-B" >/dev/null
assert_contains "$out" "in-flight-A" "first drained"
assert_eq "$(pending_count)" "1" "the later message is queued, not lost"
out="$(inbox drain --run-dir "$RUN")"
assert_contains "$out" "in-flight-B" "second delivered on the next drain"
ok "claim-by-rename keeps a concurrent send"

echo "conduct-inbox: bad input is refused"
if inbox send --run-dir "$RUN" --text "" >/dev/null 2>&1; then fail "empty message should be refused"; fi
if inbox send --run-dir "$TMP/no-such-run" --text "hi" >/dev/null 2>&1; then fail "missing run dir should be refused"; fi
ok "empty messages and unknown run dirs are refused"

# ---------------------------------------------------------------------------
# Hook tests run through .claude/hooks/hook-gate.sh — the real dispatch path.
#
# An earlier version of this file invoked the hook script directly and passed
# while the feature was completely dead in production: the gate refuses any hook
# id absent from its three profile allowlists, so nothing ever ran. Testing the
# hook without the gate tests a path no engine uses.
GATE="$ROOT/.claude/hooks/hook-gate.sh"
HOOK="$ROOT/.claude/hooks/conduct-lane-inbox.sh"

gate() {
  local event="$1" tool="${2:-Bash}"
  printf '{"hook_event_name":"%s","tool_name":"%s","session_id":"s1"}' "$event" "$tool" \
    | bash "$GATE" conduct-lane-inbox "$HOOK" 2>/dev/null
}

echo "conduct-lane-inbox: registered in every hook-gate profile"
for profile in minimal standard strict; do
  sed -n "/is_in_${profile}_profile()/,/^}/p" "$ROOT/.claude/hooks/hook-gate.sh" \
    | grep -q "conduct-lane-inbox" \
    || fail "hook id missing from the $profile profile allowlist — the gate will never run it"
done
ok "the hook id is allowlisted in minimal, standard and strict"

echo "conduct-lane-inbox: registered on the events each engine can receive on"
for ev in PreToolUse PostToolUse Stop; do
  jq -e --arg ev "$ev" '
    .hooks[$ev][]?.hooks[]? | select(.command | test("conduct-lane-inbox"))' \
    "$ROOT/.claude/settings.json" >/dev/null \
    || fail "no $ev registration in settings.json"
done
# Grok only dispatches PreToolUse under these six tool matchers.
for tool in Bash Read Write Edit Grep Glob; do
  jq -e --arg t "$tool" '
    .hooks.PreToolUse[] | select(.matcher == $t) | .hooks[]
    | select(.command | test("conduct-lane-inbox"))' \
    "$ROOT/.claude/settings.json" >/dev/null \
    || fail "PreToolUse/$tool has no registration — a grok lane using that tool never receives"
done
ok "settings.json covers PreToolUse (six tools), PostToolUse and Stop"

echo "conduct-lane-inbox: inert outside a lane"
inbox send --run-dir "$RUN" --text "should-not-be-delivered" >/dev/null
unset HQ_CONDUCT_RUN_DIR
out="$(gate PostToolUse)"
assert_eq "$out" "" "no output without HQ_CONDUCT_RUN_DIR"
assert_eq "$(pending_count)" "1" "an ordinary session must not consume a lane's queue"
ok "hook is a no-op in every session that is not a lane"

export HQ_CONDUCT_RUN_DIR="$RUN"

# --- codex / claude lanes: additionalContext on PostToolUse, block on Stop ----
export HQ_CONDUCT_ENGINE=codex

echo "codex lane: PreToolUse is not a delivery event and must not consume"
out="$(gate PreToolUse)"
assert_eq "$out" "" "PreToolUse produces no output on codex"
assert_eq "$(pending_count)" "1" "and leaves the queue alone"
ok "codex lanes are never interrupted mid tool call"

echo "codex lane: PostToolUse injects as additional context"
out="$(gate PostToolUse)"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')"
assert_eq "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" "PostToolUse" "event name echoed"
assert_contains "$ctx" "should-not-be-delivered" "the message text"
assert_contains "$ctx" "taking precedence over your brief" "framing so the lane can tell this from its orders"
assert_lacks "$out" '"decision"' "PostToolUse must not block anything"
assert_eq "$(pending_count)" "0" "delivery consumes the queue"
ok "PostToolUse delivers as additionalContext"

echo "codex lane: Stop blocks the finish so late messages still land"
inbox send --run-dir "$RUN" --text "one more thing" >/dev/null
out="$(gate Stop)"
assert_eq "$(printf '%s' "$out" | jq -r '.decision')" "block" "Stop blocks"
assert_contains "$(printf '%s' "$out" | jq -r '.reason')" "one more thing" "reason carries the message"
ok "Stop delivers by blocking the turn end"

echo "codex lane: an empty queue never blocks a finishing lane"
out="$(gate Stop)"
assert_eq "$out" "" "no output when there is nothing to deliver"
ok "the Stop backstop is self-limiting"

# --- grok lanes: PreToolUse only -------------------------------------------
#
# .grok/hooks/hq-grok-hook-adapter.sh states it plainly: "Grok cannot inject
# context on any event", and it routes passive-hook stdout to stderr
# diagnostics. So draining on PostToolUse or Stop under grok does not deliver
# late — it DESTROYS the message, silently, while the operator believes a
# correction landed. These three checks are the guard against that.
export HQ_CONDUCT_ENGINE=grok
inbox send --run-dir "$RUN" --text "grok-must-receive-this" >/dev/null

echo "grok lane: PostToolUse must not consume — it cannot reach the model"
out="$(gate PostToolUse)"
assert_eq "$out" "" "no output"
assert_eq "$(pending_count)" "1" "message preserved for a delivery event that works"
ok "grok PostToolUse leaves the message queued instead of destroying it"

echo "grok lane: Stop must not consume — grok cannot block a Stop"
out="$(gate Stop)"
assert_eq "$out" "" "no output"
assert_eq "$(pending_count)" "1" "message still preserved"
ok "grok Stop leaves the message queued"

echo "grok lane: PreToolUse delivers via a deny reason on stderr"
err="$TMP/grok.err"
out="$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"s1"}' \
  | bash "$GATE" conduct-lane-inbox "$HOOK" 2>"$err")"
rc=$?
assert_eq "$rc" "2" "non-zero exit is what the grok adapter turns into a deny"
assert_contains "$(cat "$err")" "grok-must-receive-this" "the message rides on stderr, which becomes the deny reason"
assert_contains "$(cat "$err")" "not blocked on its merits" "the lane is told to retry rather than abandon the step"
assert_eq "$(pending_count)" "0" "delivery consumes the queue"
ok "grok receives on PreToolUse, the one event its adapter feeds back"

unset HQ_CONDUCT_ENGINE

echo
echo "conduct-inbox.test.sh: $PASS checks passed"
