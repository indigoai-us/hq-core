#!/usr/bin/env bash
# hq-core: public
# Regression test: a vault pull that lands an OLDER handoff.json (by
# created_at) over a newer local pointer must not win. Observed 2026-10-25:
# two desktop sessions handed off minutes apart; a later `hq sync pull
# --personal` (run by /startwork via handoff-sync-prefetch.sh) replayed an
# 11:46 copy of the pointer over the 22:06 one, and the newer session's
# archive check then refused. The prefetch helper keeps the newer pointer.
# Uses a mock hq CLI on PATH; no network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PREFETCH_SH="$REPO_ROOT/core/scripts/handoff-sync-prefetch.sh"
[[ -f "$PREFETCH_SH" ]] || { echo "FAIL: $PREFETCH_SH not found" >&2; exit 1; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

HQ="$WORKDIR/hq"
mkdir -p "$HQ/workspace/threads"
VAULT_POINTER="$WORKDIR/vault-pointer.json"

# Mock hq: `hq sync pull` copies VAULT_POINTER over the local pointer, the way
# a real pull lands the vault's copy (with the vault's older mtime).
# Everything else succeeds silently.
MOCK_BIN="$WORKDIR/bin"; mkdir -p "$MOCK_BIN"
cat >"$MOCK_BIN/hq" <<MOCK_EOF
#!/bin/bash
set -euo pipefail
hq_root=""
if [[ "\${1:-}" == "sync" ]]; then shift 2; fi
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --hq-root) hq_root="\$2"; shift 2 ;;
    --lock-timeout|--message) shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "\$hq_root" && -f "$VAULT_POINTER" ]]; then
  cp "$VAULT_POINTER" "\$hq_root/workspace/threads/handoff.json"
  touch -t 202610241146 "\$hq_root/workspace/threads/handoff.json"
fi
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/hq"
export PATH="$MOCK_BIN:$PATH"

pointer() { # <created_at> <thread> [<session_id>]
  jq -nc --arg ts "$1" --arg t "$2" --arg sid "${3:-}" \
    '{created_at:$ts,last_thread:$t,thread_path:("workspace/threads/"+$t+".json"),message:"m",context_notes:"c",companies:[]}
     + (if $sid == "" then {} else {session_id:$sid} end)'
}

NEWER="T-20261024-220611-banner-owner-groups-3"
OLDER="T-20261024-114613-hq-message-visibility-closed"

# 1. The vault holds an older pointer than the local one: the local wins.
pointer 20261025T040611Z "$NEWER" sess-a > "$HQ/workspace/threads/handoff.json"
pointer 20261024T174613Z "$OLDER" sess-b > "$VAULT_POINTER"
status="$(bash "$PREFETCH_SH" --hq-root "$HQ" --log "$WORKDIR/prefetch.log")"
[[ "$status" == "ok" ]] || fail "prefetch status '$status' (want ok): $(cat "$WORKDIR/prefetch.log")"
[[ "$(jq -r .last_thread "$HQ/workspace/threads/handoff.json")" == "$NEWER" ]] \
  || fail "older vault pointer replaced the newer local one: $(cat "$HQ/workspace/threads/handoff.json")"
[[ "$(jq -r .session_id "$HQ/workspace/threads/handoff.json")" == "sess-a" ]] || fail "restored pointer lost its fields"
grep -q 'kept newer local handoff pointer' "$WORKDIR/prefetch.log" || fail "prefetch log does not record the kept pointer"
pass "an older pulled pointer does not replace the newer local pointer"

# 2. The vault holds a newer pointer: the pull wins, as before.
pointer 20261025T112523Z "T-20261025-052523-signals-local-revival" sess-c > "$VAULT_POINTER"
status="$(bash "$PREFETCH_SH" --hq-root "$HQ" --log "$WORKDIR/prefetch.log")"
[[ "$status" == "ok" ]] || fail "prefetch status '$status' (want ok)"
[[ "$(jq -r .last_thread "$HQ/workspace/threads/handoff.json")" == "T-20261025-052523-signals-local-revival" ]] \
  || fail "newer vault pointer did not land"
pass "a newer pulled pointer lands"

# 3. No local pointer yet (fresh machine): the pull lands whatever it has.
rm -f "$HQ/workspace/threads/handoff.json"
pointer 20261024T174613Z "$OLDER" > "$VAULT_POINTER"
status="$(bash "$PREFETCH_SH" --hq-root "$HQ" --log "$WORKDIR/prefetch.log")"
[[ "$status" == "ok" ]] || fail "prefetch status '$status' (want ok)"
[[ "$(jq -r .last_thread "$HQ/workspace/threads/handoff.json")" == "$OLDER" ]] || fail "fresh machine did not receive the pointer"
pass "a fresh machine takes the pulled pointer"

# 4. A pulled pointer that is not JSON never replaces a valid local one.
pointer 20261025T040611Z "$NEWER" > "$HQ/workspace/threads/handoff.json"
printf 'not json' > "$VAULT_POINTER"
status="$(bash "$PREFETCH_SH" --hq-root "$HQ" --log "$WORKDIR/prefetch.log")"
[[ "$status" == "ok" ]] || fail "prefetch status '$status' (want ok)"
[[ "$(jq -r .last_thread "$HQ/workspace/threads/handoff.json")" == "$NEWER" ]] || fail "invalid pulled pointer replaced the local one"
pass "an invalid pulled pointer does not replace a valid local one"

echo "PASS: handoff-sync-prefetch-pointer-regress"
