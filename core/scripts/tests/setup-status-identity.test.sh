#!/usr/bin/env bash
# Exercise the JSON identity contract without a real account or network.
set -euo pipefail
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/root"
cat > "$TMP/bin/timeout" <<'STUB'
#!/bin/sh
shift
exec "$@"
STUB
cat > "$TMP/bin/hq" <<'STUB'
#!/bin/sh
[ "$*" = 'whoami --json' ] || exit 22
printf '%s\n' "$IDENTITY_REPLY"
exit "$IDENTITY_EXIT"
STUB
chmod +x "$TMP/bin/timeout" "$TMP/bin/hq"
check() {
  local reply="$1" rc="$2" expected="$3" output probe_rc=0
  output="$(PATH="$TMP/bin:$PATH" IDENTITY_REPLY="$reply" IDENTITY_EXIT="$rc" \
    bash "$SRC_ROOT/scripts/setup-status.sh" --root "$TMP/root" --json)" || probe_rc=$?
  [ "$probe_rc" = 1 ] # Required scaffold is absent, independent of identity.
  printf '%s' "$output" | jq -e --argjson expected "$expected" \
    '.checks[] | select(.id == "cloud-login") | .done == $expected' >/dev/null
}
check '{"authenticated":true}' 0 true
check '{"authenticated":false}' 0 false
check '{"authenticated":true}' 1 false
check '{}' 0 false
check 'invalid JSON' 0 false
echo 'PASS: setup-status checks identity JSON and command success'
