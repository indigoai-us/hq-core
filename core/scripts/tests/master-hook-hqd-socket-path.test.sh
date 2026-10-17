#!/usr/bin/env bash
# hq-core: public
# windows-hook-parity US-001: master-hook.sh must look for the hqd socket at
# the same path hqd listens on and core/scripts/hqd-hook-shim.sh connects to:
# HQ_HQD_SOCKET, else $HQ_REGISTRY_DIR/daemon/hqd.sock, else
# ~/.hq/daemon/hqd.sock. Before the fix it checked $HQ_REGISTRY_DIR/hqd.sock
# and ~/.hq/hqd.sock, so a running hqd was never routed to from the HQ root.
#
# Each case runs the in-root project registration of master-hook.sh with a
# stub shim that logs one line per call, and a child hook that logs the local
# fan-out. The shim log is the routing signal.
#
# On Windows, hqd listens on a named pipe, not daemon/hqd.sock, so neither
# master-hook nor hqd-hook-shim.sh routes to hqd there. In shell-smoke-windows
# this test checks only the shell path resolution under Git Bash.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASTER="${HQ_MASTER_HOOK_TEST_HOOK:-$ROOT/.claude/hooks/master-hook.sh}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$MASTER" ] || fail "master-hook.sh not found at $MASTER"

# Unix socket paths are capped near 104 bytes, so keep the fixture under /tmp
# rather than a long per-user TMPDIR.
TMP="$(cd "$(mktemp -d /tmp/mhsock.XXXXXX)" && pwd)"
trap 'rm -rf "$TMP"' EXIT INT TERM

FIX="$TMP/hq"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/hooks/PreToolUse" "$FIX/core/scripts" "$FIX/workspace/sessions"
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIX/.claude/hooks/"
cp "$ROOT/core/scripts/resolve-hq-root.sh" "$ROOT/core/scripts/hq-anywhere-runtime-flag.cjs" \
  "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$FIX/core/scripts/"

SHIM_LOG="$TMP/shim-calls.log"
FANOUT_LOG="$TMP/fanout.log"
: > "$SHIM_LOG"
: > "$FANOUT_LOG"
cat > "$FIX/core/scripts/hqd-hook-shim.sh" <<'SHIM'
#!/bin/sh
payload=$(cat)
case "$payload" in
  *'"tool_use_id":"'*) id=${payload#*'"tool_use_id":"'}; id=${id%%'"'*} ;;
  *) id=unknown ;;
esac
printf '%s\n' "$id" >> "$HQ_TEST_SHIM_LOG"
SHIM
chmod +x "$FIX/core/scripts/hqd-hook-shim.sh"
cat > "$FIX/core/hooks/PreToolUse/50-fanout.sh" <<'HOOK'
#!/bin/bash
payload="$(cat)"
id="${payload#*\"tool_use_id\":\"}"; id="${id%%\"*}"
printf '%s\n' "$id" >> "$HQ_TEST_FANOUT_LOG"
HOOK
chmod +x "$FIX/core/hooks/PreToolUse/50-fanout.sh"

# A socket file is enough: master-hook gates on [ -S path ] and the stub shim
# never connects. Perl's IO::Socket::UNIX makes the socket; under Git Bash it
# is the MSYS perl, whose emulated socket file Git Bash's [ -S ] should
# recognise. make_socket fails rather than skips if it does not.
make_socket() { # <path>
  mkdir -p "$(dirname "$1")"
  rm -f "$1"
  perl -MIO::Socket::UNIX -e \
    'IO::Socket::UNIX->new(Type => IO::Socket::UNIX::SOCK_STREAM(), Local => $ARGV[0], Listen => 1) or die "listen: $!\n"' \
    "$1" || fail "could not create fixture socket at $1"
  [ -S "$1" ] || fail "fixture socket at $1 is not a socket to [ -S ]"
}

# run_case <tool_use_id> [env assignments...]
run_case() {
  local id="$1" home="$TMP/home-$1"
  shift
  mkdir -p "$home"
  printf '{"session_id":"sock-path-sid","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"true"},"tool_use_id":"%s"}' "$id" \
    | (cd "$FIX" && env -u HQ_HQD_SOCKET -u HQ_REGISTRY_DIR -u HQ_FLAG_HQ_ANYWHERE_RUNTIME \
        -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID \
        HOME="$home" CLAUDE_PROJECT_DIR="$FIX" HQ_HOOK_TIMEOUT_SENTRY=0 \
        HQ_TEST_SHIM_LOG="$SHIM_LOG" HQ_TEST_FANOUT_LOG="$FANOUT_LOG" "$@" \
        bash "$FIX/.claude/hooks/master-hook.sh" PreToolUse >/dev/null 2>"$TMP/stderr-$id") \
    || fail "master-hook exited non-zero for $id: $(cat "$TMP/stderr-$id")"
}
calls() { grep -cx "$1" "$2" || true; }

# 1. Default path: hqd listening on ~/.hq/daemon/hqd.sock is routed to.
make_socket "$TMP/home-toolu_home_daemon/.hq/daemon/hqd.sock"
run_case toolu_home_daemon
[ "$(calls toolu_home_daemon "$SHIM_LOG")" = "1" ] \
  || fail "hqd on ~/.hq/daemon/hqd.sock was not routed to (shim calls: $(calls toolu_home_daemon "$SHIM_LOG"))"
[ "$(calls toolu_home_daemon "$FANOUT_LOG")" = "1" ] || fail "default-path route skipped the local fan-out"
pass "\$HOME/.hq/daemon/hqd.sock routes through the hqd shim and keeps the local fan-out"

# 2. HQ_REGISTRY_DIR moves the runtime directory: $HQ_REGISTRY_DIR/daemon/hqd.sock.
make_socket "$TMP/registry/daemon/hqd.sock"
run_case toolu_registry_daemon HQ_REGISTRY_DIR="$TMP/registry"
[ "$(calls toolu_registry_daemon "$SHIM_LOG")" = "1" ] \
  || fail "hqd on \$HQ_REGISTRY_DIR/daemon/hqd.sock was not routed to"
pass "\$HQ_REGISTRY_DIR/daemon/hqd.sock routes through the hqd shim"

# 3. HQ_HQD_SOCKET still wins over both defaults.
make_socket "$TMP/explicit/custom.sock"
run_case toolu_explicit HQ_HQD_SOCKET="$TMP/explicit/custom.sock" HQ_REGISTRY_DIR="$TMP/empty-registry"
[ "$(calls toolu_explicit "$SHIM_LOG")" = "1" ] || fail "HQ_HQD_SOCKET was not honoured"
pass "HQ_HQD_SOCKET overrides the default socket path"

# 4. The old paths are not hqd's. A socket file there alone must not route,
# because the shim would connect to daemon/hqd.sock and find nothing.
make_socket "$TMP/home-toolu_legacy_home/.hq/hqd.sock"
run_case toolu_legacy_home
[ "$(calls toolu_legacy_home "$SHIM_LOG")" = "0" ] || fail "legacy ~/.hq/hqd.sock was treated as the hqd socket"
[ "$(calls toolu_legacy_home "$FANOUT_LOG")" = "1" ] || fail "legacy-path case did not run direct dispatch"
make_socket "$TMP/legacy-registry/hqd.sock"
run_case toolu_legacy_registry HQ_REGISTRY_DIR="$TMP/legacy-registry"
[ "$(calls toolu_legacy_registry "$SHIM_LOG")" = "0" ] || fail "legacy \$HQ_REGISTRY_DIR/hqd.sock was treated as the hqd socket"
pass "legacy ~/.hq/hqd.sock and \$HQ_REGISTRY_DIR/hqd.sock stay on direct dispatch"

# 5. The master-hook and the shim resolve the same path for each input.
SHIM_SRC="$ROOT/core/scripts/hqd-hook-shim.sh"
grep -Fq 'sock="$HQ_REGISTRY_DIR/daemon/hqd.sock"' "$SHIM_SRC" || fail "hqd-hook-shim.sh registry socket path changed; update master-hook.sh to match"
grep -Fq 'sock="${HOME:-}/.hq/daemon/hqd.sock"' "$SHIM_SRC" || fail "hqd-hook-shim.sh default socket path changed; update master-hook.sh to match"
pass "hqd-hook-shim.sh resolves the same socket paths"

echo "ALL PASS: master-hook-hqd-socket-path"
