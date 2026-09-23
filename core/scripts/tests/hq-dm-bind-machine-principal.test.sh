#!/usr/bin/env bash
# Machine-principal regression coverage: use hq-cli for roster and posts when
# Cognito session files are absent, preserve topic roots, and filter own posts
# by senderMachineUid while polling.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/root/core/scripts" "$SANDBOX/bin" "$SANDBOX/home"
cp "$ROOT/core/scripts/hq-dm-bind.sh" "$SANDBOX/root/core/scripts/"

cat > "$SANDBOX/root/core/scripts/hq-session.sh" <<'S'
#!/usr/bin/env bash
case "$1" in current) printf 'sess-test' ;; get) echo '"room"' ;; *) : ;; esac
S

HISTORY="$SANDBOX/history.json"
CALLS="$SANDBOX/hq-calls"
POST_BODY="$SANDBOX/post-body"
printf '[]\n' > "$HISTORY"

cat > "$SANDBOX/bin/hq" <<'S'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CALLS"

if [ "${1:-}" = --version ]; then
  printf 'CLI %s\n' "${HQ_VERSION:-5.137.0}"
  exit 0
fi

if [ "${1:-}" = whoami ]; then
  if [ "${2:-}" = --json ]; then
    printf '%s\n' '{"schemaVersion":1,"authenticated":true,"tokenSource":"machine","agentUid":null,"personUid":null,"username":"machine-123","email":null}'
  fi
  exit 0
fi

if [ "${1:-}" = channels ] && [ "${2:-}" = members ]; then
  printf 'Ada Lovelace\tprs_ada\nGrace Hopper\tprs_grace\nwatcher\tagt_watcher\n'
  exit 0
fi

if [ "${1:-}" = dm ] && [ "${2:-}" = channel ]; then
  cat "$HISTORY"
  exit 0
fi

if [ "${1:-}" = dm ]; then
  channel="$2"
  shift 2
  root=""
  body=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --thread) root="$2"; shift 2 ;;
      *) body="$1"; shift ;;
    esac
  done
  printf '%s' "$body" > "$POST_BODY"
  count="$(jq 'length' "$HISTORY")"
  event="evt-$((count + 1))"
  sk="2026-09-23T00:00:$(printf '%02d' "$((count + 1))")Z"
  jq --arg event "$event" --arg sk "$sk" --arg body "$body" --arg root "$root" \
    '. + [{eventId:$event, sk:$sk, senderMachineUid:"machine-123", fromDisplayName:"Machine", body:$body, rootEventId:(if $root == "" then null else $root end)}]' \
    "$HISTORY" > "$HISTORY.tmp"
  mv "$HISTORY.tmp" "$HISTORY"
  printf 'posted %s to %s\n' "$event" "$channel"
  exit 0
fi

echo "unexpected hq invocation: $*" >&2
exit 1
S
chmod +x "$SANDBOX/bin/hq" "$SANDBOX/root/core/scripts/hq-session.sh"

export PATH="$SANDBOX/bin:$PATH" HOME="$SANDBOX/home" HQ_ROOT="$SANDBOX/root"
export HISTORY CALLS POST_BODY
BIND="$SANDBOX/root/core/scripts/hq-dm-bind.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# No ~/.hq/config.json or ~/.hq/cognito-tokens.json: roster must come from the
# CLI and the body must retain quoted mention syntax for hq dm to resolve.
bash "$BIND" post --title "Machine update" --line "one" >/dev/null
grep -q '^channels members room$' "$CALLS" || fail "machine roster must use hq channels members"
grep -q '^dm room @' "$CALLS" || fail "machine post must use hq dm"
[ "$(head -1 "$POST_BODY")" = '@"Ada Lovelace" @"Grace Hopper"' ] || fail "CLI post must receive quoted mention tokens: $(head -1 "$POST_BODY")"
grep -q $'^machine-update\tevt-1$' "$SANDBOX/root/workspace/sessions/sess-test/dm-bind.threads" || fail "first CLI post must record its event id"
echo "PASS: machine principal reads the roster and posts through hq-cli"

bash "$BIND" post --title "Machine update" --line "two" >/dev/null
grep -q -- 'dm room --thread evt-1' "$CALLS" || fail "second CLI post must pass the topic root to hq dm"
[ "$(jq -r '.[-1].rootEventId' "$HISTORY")" = evt-1 ] || fail "second CLI post must be a reply under the first root"
echo "PASS: machine principal preserves topic thread roots"

# Poll must discard the machine's own senderMachineUid while retaining an
# inbound message from another machine.
jq -n '[
  {eventId:"evt-own-1",sk:"2026-09-23T00:00:01Z",senderMachineUid:"machine-123",fromDisplayName:"Machine",body:"own one"},
  {eventId:"evt-inbound",sk:"2026-09-23T00:00:02Z",senderMachineUid:"other-machine",fromDisplayName:"Other",body:"inbound request"},
  {eventId:"evt-own-2",sk:"2026-09-23T00:00:03Z",senderMachineUid:"machine-123",fromDisplayName:"Machine",body:"own two"}
]' > "$HISTORY"
rm -f "$SANDBOX/root/workspace/sessions/sess-test/dm-bind.cursor"
rc=0
bash "$BIND" poll > "$SANDBOX/poll.out" || rc=$?
[ "$rc" = 0 ] || fail "poll with an inbound message must succeed (rc=$rc)"
grep -q 'inbound request' "$SANDBOX/poll.out" || fail "poll must print the inbound message"
! grep -q 'own one\|own two' "$SANDBOX/poll.out" || fail "poll must filter own machine posts"
echo "PASS: machine principal polling filters senderMachineUid"

# An older CLI must refuse before a post is attempted.
before="$(grep -c '^dm room ' "$CALLS" || true)"
rc=0
HQ_VERSION=5.136.0 bash "$BIND" post --title "Too old" >/dev/null 2>"$SANDBOX/old.err" || rc=$?
[ "$rc" = 2 ] || fail "old hq-cli must be rejected (rc=$rc)"
grep -q 'hq-cli >= 5.137.0' "$SANDBOX/old.err" || fail "old CLI rejection must name the required version"
after="$(grep -c '^dm room ' "$CALLS" || true)"
[ "$before" = "$after" ] || fail "old hq-cli must not attempt a post"
echo "PASS: machine principal refuses an older hq-cli before posting"
