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

echo "conduct-lane-inbox: registered on the events that can reach a model"
# Gated hooks are dispatched by master-hook.sh from hook-registry.json (one
# settings.json master-hook line per event); registration lives there.
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
for ev in PostToolUse Stop; do
  jq -e --arg ev "$ev" '
    .hooks[$ev][]?.hooks[]? | select(.id == "conduct-lane-inbox")' \
    "$REGISTRY" >/dev/null \
    || fail "no $ev registration in hook-registry.json"
  jq -e --arg ev "$ev" '
    .hooks[$ev][]?.hooks[]? | select(.command | test("master-hook.sh"))' \
    "$ROOT/.claude/settings.json" >/dev/null \
    || fail "no $ev master-hook registration in settings.json"
done
# PostToolUse carries the message on every engine, so the matcher must be the
# wildcard: a per-tool list would silently skip whatever tool it forgot.
jq -e '
  .hooks.PostToolUse[] | select(.matcher == "*") | .hooks[]
  | select(.id == "conduct-lane-inbox")' \
  "$REGISTRY" >/dev/null \
  || fail "PostToolUse registration is not on matcher '*' — some tools would never deliver"
# The PreToolUse registrations existed only to deny a grok lane's tool call.
# That route is gone, so the registrations are too; leaving them would spawn a
# hook process per tool call in every session on the machine for nothing.
if jq -e '.hooks.PreToolUse[]?.hooks[]? | select(.id == "conduct-lane-inbox")' \
  "$REGISTRY" >/dev/null 2>&1; then
  fail "conduct-lane-inbox is still registered on PreToolUse, where it can no longer deliver"
fi
ok "hook-registry.json covers PostToolUse (matcher *) and Stop, and not PreToolUse"

# A conductor's message is for the lane, not for a subagent the lane spawned,
# so there is deliberately no SubagentStop registration. The docs used to
# promise one. Both halves are asserted here so they cannot drift apart again.
if jq -e '.hooks.SubagentStop[]?.hooks[]? | select(.id == "conduct-lane-inbox")' \
  "$REGISTRY" >/dev/null 2>&1; then
  fail "conduct-lane-inbox gained a SubagentStop registration; update the conduct skill and .grok/README.md to match"
fi
grep -q 'no `SubagentStop` registration' "$ROOT/.claude/skills/conduct/SKILL.md" \
  || fail "the conduct skill no longer records that SubagentStop delivery is absent"
ok "no SubagentStop backstop is registered, and the conduct skill says so"

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

# --- grok lanes take the same route as every other engine -------------------
#
# Grok used to be delivered on PreToolUse, by denying the tool call so the
# message could ride the deny reason. That cost the lane a call every time, and
# it rested on a claim about Grok that is not true: its adapter passes a hook's
# additionalContext through on PostToolUse, and its Stop gate blocks. The checks
# below are the guard against the branch coming back.
export HQ_CONDUCT_ENGINE=grok
inbox send --run-dir "$RUN" --text "grok-must-receive-this" >/dev/null

echo "grok lane: PostToolUse delivers as additionalContext, costing no tool call"
out="$(gate PostToolUse)"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')"
assert_eq "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" "PostToolUse" "event name echoed"
assert_contains "$ctx" "grok-must-receive-this" "the message text"
assert_contains "$ctx" "taking precedence over your brief" "framing so the lane can tell this from its orders"
assert_lacks "$out" '"decision"' "PostToolUse must not block or deny anything"
assert_eq "$(pending_count)" "0" "delivery consumes the queue"
ok "grok PostToolUse delivers as context, like codex and claude"

echo "grok lane: Stop still backstops a late message"
inbox send --run-dir "$RUN" --text "grok-late-message" >/dev/null
out="$(gate Stop)"
assert_eq "$(printf '%s' "$out" | jq -r '.decision')" "block" "Stop blocks"
assert_contains "$(printf '%s' "$out" | jq -r '.reason')" "grok-late-message" "reason carries the message"
assert_eq "$(pending_count)" "0" "delivery consumes the queue"
ok "grok Stop delivers by blocking the turn end"

echo "grok lane: PreToolUse is inert — the deny path is gone"
inbox send --run-dir "$RUN" --text "grok-must-not-be-denied" >/dev/null
err="$TMP/grok.err"
rc=0
out="$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"s1"}' \
  | bash "$GATE" conduct-lane-inbox "$HOOK" 2>"$err")" || rc=$?
assert_eq "$rc" "0" "PreToolUse must not deny a lane's tool call to deliver"
assert_eq "$out" "" "no stdout"
assert_lacks "$(cat "$err")" "grok-must-not-be-denied" "nothing rides on stderr any more"
assert_eq "$(pending_count)" "1" "the message stays queued for PostToolUse"
ok "grok PreToolUse costs the lane nothing and preserves the message"

out="$(gate PostToolUse)"
assert_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')" "grok-must-not-be-denied" "the preserved message lands on the next PostToolUse"
assert_eq "$(pending_count)" "0" "and is consumed there"
ok "a message skipped by PreToolUse is delivered, not destroyed"

echo "grok lane: a Stop whose decision is discarded must not consume the queue"
# Grok fires a second, observe-only Stop at session close and throws its
# decision away. Draining there does not deliver late, it destroys the message
# while the operator believes a correction landed. The adapter flags that fire.
inbox send --run-dir "$RUN" --text "grok-session-close-message" >/dev/null
out="$(HQ_STOP_DECISION_DELIVERABLE=0 gate Stop)"
assert_eq "$out" "" "no block is emitted for a decision nobody reads"
assert_eq "$(pending_count)" "1" "the message is preserved, not consumed"
ok "a non-deliverable Stop leaves the queue intact"

out="$(HQ_STOP_DECISION_DELIVERABLE=1 gate Stop)"
assert_eq "$(printf '%s' "$out" | jq -r '.decision')" "block" "a deliverable Stop still blocks"
assert_contains "$(printf '%s' "$out" | jq -r '.reason')" "grok-session-close-message" "carrying the preserved message"
assert_eq "$(pending_count)" "0" "which is when it is finally consumed"
ok "the preserved message lands on the next deliverable Stop"

echo "an engine that sets no deliverability flag keeps draining on Stop"
inbox send --run-dir "$RUN" --text "unflagged-engine-message" >/dev/null
out="$(gate Stop)"
assert_eq "$(printf '%s' "$out" | jq -r '.decision')" "block" "an unset flag means deliverable"
assert_eq "$(pending_count)" "0" "claude and codex are unchanged"
ok "the guard defaults to deliverable"

unset HQ_CONDUCT_ENGINE

# --- the engine no longer changes the route ---------------------------------
echo "every engine drains on the same three events"
for engine in claude codex grok ""; do
  export HQ_CONDUCT_ENGINE="$engine"
  inbox send --run-dir "$RUN" --text "uniform-$engine" >/dev/null
  out="$(gate PostToolUse)"
  assert_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')" "uniform-$engine" "PostToolUse delivers for engine $engine"
  assert_eq "$(pending_count)" "0" "queue consumed for engine $engine"
done
unset HQ_CONDUCT_ENGINE
ok "delivery is engine-uniform, including for a lane that exports no engine"

echo
echo "conduct-inbox.test.sh: $PASS checks passed"
