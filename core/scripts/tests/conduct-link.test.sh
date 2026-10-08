#!/usr/bin/env bash
# conduct-link.test.sh — coverage for the two-way link between a /conduct
# session and the live sessions it adopts, and for the hook path that delivers
# across it.
#
# What has to hold: an instruction reaches exactly the child it was addressed
# to, a report reaches the conductor labelled with the child it came from, and a
# session on neither end of a link is never handed someone else's message.

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

export HQ_CONDUCT_LINKS_DIR="$TMP/links"
export HQ_HQ_SESSION_NO_CLI=1
unset HQ_CONDUCT_RUN_DIR HQ_CONDUCT_ENGINE
link() { bash "$ROOT/core/scripts/conduct-link.sh" "$@"; }
hook() { # hook <event> <session-id>
  printf '{"hook_event_name":"%s","tool_name":"Bash","session_id":"%s"}' "$1" "$2" \
    | bash "$ROOT/.claude/hooks/conduct-lane-inbox.sh" 2>"$TMP/hook.err"
}

echo "conduct-link: open is idempotent for the conductor session"
LINK="$(link open --session-id cond-1 --host-session host-cond | jq -r '.link')"
[ -n "$LINK" ] && [ "$LINK" != "null" ] || fail "open printed no link id"
again="$(link open --session-id cond-1 | jq -r '.link')"
assert_eq "$again" "$LINK" "second open"
ok "a conductor session owns one link"

echo "conduct-link: children join and the conductor hears about it"
out="$(link join --link "$LINK" --session-id child-a --name api --engine claude --title "API work")"
assert_eq "$(printf '%s' "$out" | jq -r '.conductor_host_session')" "host-cond" "join returns the conductor's host session"
link join --link "$LINK" --session-id child-b --name web --engine grok --title "Web work" >/dev/null
link join --link "$LINK" --session-id child-c --name api >/dev/null 2>&1 && fail "duplicate child name accepted"
link join --link "$LINK" --session-id child-a --name other >/dev/null 2>&1 && fail "a session joined twice"
link join --link "$LINK" --session-id child-d --name all >/dev/null 2>&1 && fail "reserved name accepted"
link join --link "../x" --session-id child-e >/dev/null 2>&1 && fail "path traversal in --link accepted"
out="$(link read --session-id cond-1)"
assert_contains "$out" "[api joined]" "join notice"
assert_contains "$out" "[web joined]" "second join notice"
ok "joins are unique per name and per session, and are announced upstream"

echo "conduct-link: an instruction reaches only the addressed child"
link send --session-id cond-1 --child api --text "rebase onto main first" >/dev/null
out="$(hook PostToolUse child-b)"
assert_eq "$out" "" "the other child receives nothing"
out="$(hook PostToolUse child-a)"
assert_contains "$out" "rebase onto main first" "addressed child receives"
assert_contains "$out" "conduct-link.sh report" "child is told how to answer"
out="$(hook PostToolUse child-a)"
assert_eq "$out" "" "delivered exactly once"
ok "delivery is addressed and happens once"

echo "conduct-link: a grok child is reached on the same events as every engine"
# The hook no longer picks the delivery event by engine: the Grok adapter
# delivers PostToolUse context itself and marks the one Stop whose decision it
# throws away with HQ_STOP_DECISION_DELIVERABLE=0. PreToolUse carries nothing.
link send --session-id cond-1 --child web --text "use the staging API" >/dev/null
hook PreToolUse child-b >/dev/null; rc=$?
assert_eq "$rc" "0" "PreToolUse is not a delivery event"
out="$(hook PostToolUse child-b)"
assert_contains "$out" "use the staging API" "grok child receives on PostToolUse"
out="$(HQ_STOP_DECISION_DELIVERABLE=0 hook Stop child-b)"
assert_eq "$out" "" "a Stop whose decision is discarded does not drain"
ok "delivery events are the same for every engine"

echo "conduct-link: broadcast reaches every child"
link send --session-id cond-1 --child all --text "freeze: release in progress" >/dev/null
assert_contains "$(link inbox --session-id child-a)" "freeze" "child a, drained by hand"
assert_contains "$(link inbox --session-id child-b)" "freeze" "child b, drained by hand"
ok "--child all queues one copy per child, and inbox drains without a hook"

echo "conduct-link: a report reaches the conductor, labelled"
out="$(link report --session-id child-a --state blocked --text "need the prod DB password")"
assert_eq "$(printf '%s' "$out" | jq -r '.conductor_host_session')" "host-cond" "report names the session to wake"
assert_eq "$(link list --link "$LINK" | jq -r '.unread_reports')" "1" "unread count"
assert_eq "$(link list --link "$LINK" | jq -r '.children[] | select(.name=="api") | .state')" "blocked" "state recorded"
out="$(hook PostToolUse cond-1)"
assert_contains "$out" "[from api · blocked]" "report carries its source"
assert_contains "$out" "need the prod DB password" "report text"
assert_eq "$(link list --link "$LINK" | jq -r '.unread_reports')" "0" "consumed"
ok "the conductor's own hook delivers child reports"

echo "conduct-link: wait wakes on a report and times out without one"
link wait --session-id cond-1 --timeout 0 >/dev/null; rc=$?
assert_eq "$rc" "3" "timeout exit"
link report --session-id child-b --text "done" --state done >/dev/null
link wait --session-id cond-1 --timeout 5 >/dev/null; rc=$?
assert_eq "$rc" "0" "pending report"
ok "wait exits 0 on a pending report, 3 on timeout"

echo "conduct-link: roles are enforced"
link send --session-id child-a --child web --text "x" >/dev/null 2>&1 && fail "a child sent as conductor"
link report --session-id cond-1 --text "x" >/dev/null 2>&1 && fail "the conductor reported as a child"
link report --session-id stranger --text "x" >/dev/null 2>&1 && fail "an unlinked session reported"
ok "only the conductor sends, only a child reports"

echo "conduct-link: an unlinked session is never handed a message"
link send --session-id cond-1 --child api --text "for api only" >/dev/null
out="$(hook PostToolUse stranger)"
assert_eq "$out" "" "unlinked session"
out="$(hook PostToolUse '../child-a')"
assert_eq "$out" "" "malformed session id"
assert_eq "$(link list --link "$LINK" | jq -r '.children[] | select(.name=="api") | .undelivered')" "1" "message still queued"
ok "the hook stays inert for sessions outside the link"

echo "conduct-link: leave and close stop delivery and keep the record"
link leave --session-id child-a >/dev/null
out="$(hook PostToolUse child-a)"
assert_eq "$out" "" "no delivery after leave"
[ -d "$HQ_CONDUCT_LINKS_DIR/$LINK/children/api" ] || fail "child record removed on leave"
link close --session-id cond-1 >/dev/null
[ -z "$(ls -A "$HQ_CONDUCT_LINKS_DIR/by-session" 2>/dev/null)" ] || fail "close left session pointers behind"
[ -f "$HQ_CONDUCT_LINKS_DIR/$LINK/meta.json" ] || fail "close removed the link record"
ok "pointers go, records stay"

echo "conduct-link: the dispatcher runs the hook for a linked session"
# master-hook.sh ANDs an entry's prefilters, and the lane entry is gated on an
# env var a linked session never has. Without a second entry gated on the
# by-session directory the hook passes every direct test above and never runs.
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
for ev in PostToolUse Stop; do
  jq -e --arg ev "$ev" '
    .hooks[$ev][]?.hooks[]?
    | select(.id == "conduct-lane-inbox" and (.args // []) == ["--link"]
             and .prefilter.file == "workspace/conduct-links/by-session"
             and (.prefilter.env // "") == "")' "$REGISTRY" >/dev/null \
    || fail "no --link registration for $ev in hook-registry.json"
done
link open --session-id cond-2 >/dev/null
L2="$(link list --session-id cond-2 | jq -r '.link')"
link join --link "$L2" --session-id child-z --name z >/dev/null
link send --session-id cond-2 --child z --text "lane must not take this" >/dev/null
out="$(printf '{"hook_event_name":"PostToolUse","session_id":"child-z"}' \
  | HQ_CONDUCT_RUN_DIR="$TMP/some-lane" bash "$ROOT/.claude/hooks/conduct-lane-inbox.sh" --link 2>/dev/null)"
assert_eq "$out" "" "--link entry stands down inside a lane"
out="$(printf '{"hook_event_name":"PostToolUse","session_id":"child-z"}' \
  | bash "$ROOT/.claude/hooks/conduct-lane-inbox.sh" --link 2>/dev/null)"
assert_contains "$out" "lane must not take this" "--link entry delivers"
ok "registered per event, and inert inside a lane"

echo "conduct-link: $PASS checks passed"
