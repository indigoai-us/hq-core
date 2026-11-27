#!/usr/bin/env bash
# Regression: the MSYS jq wrapper must probe `jq --binary` at most once per
# script run, not once per jq call, and its output must stay identical to a
# run without the wrapper.
#
# Tests the remaining wrapped helpers (`jobs-validate.sh` and `hq-job-probe.sh`)
# behind a jq shim that logs probe calls separately from real calls.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC_DIR="${HQ_JQ_PROBE_TEST_SOURCE_DIR:-$ROOT/core/scripts}"
REAL_JQ="$(command -v jq)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v perl >/dev/null 2>&1 || fail "perl is required to emulate sed -b on this host"

# --- jq shim: logs PROBE vs CALL, emulates legacy jq.exe text mode ----------
SHIM_DIR="$TMP/bin"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/jq" <<'SHIM'
#!/usr/bin/env bash
binary=no
if [ "${1:-}" = "--binary" ]; then
  binary=yes
  shift
  if [ "$TEST_JQ_MODE" = legacy ]; then
    echo PROBE-REJECTED >> "$JQ_COUNT_LOG"
    echo 'jq: Unknown arguments: --binary' >&2
    exit 2
  fi
  if [ "${1:-}" = "-n" ] && [ "${2:-}" = "null" ] && [ $# -eq 2 ]; then
    echo PROBE >> "$JQ_COUNT_LOG"
    exec "$REAL_JQ" -n null
  fi
fi
echo "CALL binary=$binary" >> "$JQ_COUNT_LOG"
if [ "$TEST_JQ_MODE" = legacy ]; then
  set +e
  "$REAL_JQ" "$@" | sed 's/$/\r/'
  rc=${PIPESTATUS[0]}
  exit "$rc"
fi
exec "$REAL_JQ" "$@"
SHIM
chmod +x "$SHIM_DIR/jq"

msys_copy() { # src dest
  sed 's/\${OSTYPE:-}/${TEST_OSTYPE:-}/g; s/\${MSYSTEM:-}/${TEST_MSYSTEM:-}/g' "$1" \
    | perl -pe 's/command sed -b .s\/\\r\$\/\/./command perl -pe "s\/\\r\\n\\z\/\\n\/"/' > "$2"
  if grep -q 'sed -b' "$2"; then fail "sed -b substitution did not apply to $1"; fi
}

count() { grep -c "$1" "$2" || true; }

for asset in jobs-validate.sh hq-job-probe.sh; do
  msys_copy "$SRC_DIR/$asset" "$TMP/full-$asset"
  awk 'index($0, "case \"${TEST_OSTYPE:-}") { c = 1 } c { print; if ($0 == "esac") exit }' \
    "$TMP/full-$asset" > "$TMP/wrapper.sh"
  grep -q 'jq()' "$TMP/wrapper.sh" || fail "$asset: wrapper not found"
  for mode in modern legacy; do
    : > "$TMP/count.log"
    PATH="$SHIM_DIR:$PATH" REAL_JQ="$REAL_JQ" TEST_JQ_MODE="$mode" JQ_COUNT_LOG="$TMP/count.log" \
      TEST_OSTYPE=msys TEST_MSYSTEM=MINGW64 bash -c '
        set -euo pipefail
        source "$1"
        a="$(jq -r .a <<<"{\"a\":\"x\"}")"; b="$(jq -r .b <<<"{\"b\":\"y\"}")"; c="$(jq -n 1)"
        [ "$a$b$c" = xy1 ]' _ "$TMP/wrapper.sh" || fail "$asset ($mode): wrapper output changed"
    probes="$(count '^PROBE' "$TMP/count.log")"
    [ "$probes" -eq 1 ] || fail "$asset ($mode): expected 1 probe for 3 calls, got $probes"
  done
  echo "$asset: one probe for three jq calls (modern and legacy)"
done
