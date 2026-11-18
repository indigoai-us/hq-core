#!/usr/bin/env bash
# hq-core: public
# US-043: startwork-context.sh orient binds through `hq core
# work-mesh-bind-trusted` when the installed hq-cli is at or above the floor,
# and runs the shell binder when hq is missing, older, or
# HQ_STARTWORK_BIND_SHELL=1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/startwork-context.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/startwork-bind-route.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
BIN="$TMP/bin"
mkdir -p "$FIX/core/scripts/lib" "$BIN" "$TMP/home"
cp "$ROOT/core/scripts/lib/hq-cli-floor.sh" "$FIX/core/scripts/lib/"
# The shell binder records that it ran.
printf '#!/usr/bin/env bash\nprintf "shell %%s\\n" "$*" >"$CALLS"\n' >"$FIX/core/scripts/work-mesh-live-bind-trusted.sh"
cat >"$BIN/hq" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then printf '%s\n' "$STUB_HQ_VERSION"; exit 0; fi
printf 'native %s\n' "$*" >"$CALLS"
STUB
chmod +x "$BIN/hq"

MIN="$(sed -n 's/^STARTWORK_BIND_NATIVE_MIN_CLI=//p' "$SCRIPT")"
[ -n "$MIN" ] || fail "startwork-context.sh declares no STARTWORK_BIND_NATIVE_MIN_CLI"
FUNC="$(sed -n '/^bind_trusted() {$/,/^}$/p' "$SCRIPT")"
[ -n "$FUNC" ] || fail "startwork-context.sh has no bind_trusted function"

route() {
  local version="$1" path="$2" shell="${3:-0}"
  rm -f "$TMP/calls"
  env -u HQ_ROOT HOME="$TMP/home" XDG_CACHE_HOME="$TMP/cache-$version-$shell" PATH="$path" \
    STUB_HQ_VERSION="$version" CALLS="$TMP/calls" HQ_STARTWORK_BIND_SHELL="$shell" \
    ROOT="$FIX" STARTWORK_BIND_NATIVE_MIN_CLI="$MIN" FUNC="$FUNC" \
    bash -c 'eval "$FUNC"; bind_trusted --company acme --session-id s1 --root "$ROOT"'
  cat "$TMP/calls"
}

out="$(route "$MIN" "$BIN:/usr/bin:/bin")"
[ "$out" = "native core --hq-root $FIX work-mesh-bind-trusted --company acme --session-id s1 --root $FIX" ] \
  || fail "hq at the floor did not bind natively: $out"
pass "hq $MIN binds through hq core work-mesh-bind-trusted"

out="$(route 5.300.0 "$BIN:/usr/bin:/bin")"
[ "$out" = "shell --company acme --session-id s1 --root $FIX" ] || fail "older hq did not use the shell binder: $out"
pass "hq 5.300.0 runs the shell binder"

out="$(route "$MIN" "/usr/bin:/bin")"
[ "$out" = "shell --company acme --session-id s1 --root $FIX" ] || fail "missing hq did not use the shell binder: $out"
pass "no hq runs the shell binder"

out="$(route "$MIN" "$BIN:/usr/bin:/bin" 1)"
[ "$out" = "shell --company acme --session-id s1 --root $FIX" ] || fail "HQ_STARTWORK_BIND_SHELL=1 did not force the shell binder: $out"
pass "HQ_STARTWORK_BIND_SHELL=1 runs the shell binder"

echo "PASS: startwork-bind-route"
