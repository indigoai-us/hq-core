#!/usr/bin/env bash
# Regression: the MSYS jq wrapper must probe `jq --binary` at most once per
# script run, not once per jq call, and its output must stay identical to a
# run without the wrapper.
#
# Runs the real hq-delegate-send.sh --send preflight through its MSYS wrapper
# on any host, behind a jq shim that logs probe calls separately from real
# calls. Modes:
#   modern - jq supports --binary (wrapper passes output through)
#   legacy - jq rejects --binary and writes CRLF (wrapper strips CR)
#   native - no wrapper (macOS/Linux path); baseline output
# The other three wrapped helpers must also probe once, not per call.
#
# HQ_JQ_PROBE_TEST_SOURCE_DIR overrides the scripts directory (used to measure
# the pre-change helper). HQ_JQ_PROBE_TEST_REPORT=1 prints counts only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC_DIR="${HQ_JQ_PROBE_TEST_SOURCE_DIR:-$ROOT/core/scripts}"
REAL_JQ="$(command -v jq)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v perl >/dev/null 2>&1 || fail "perl is required to emulate sed -b on this host"

hash_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f1; else shasum -a 256 "$1" | cut -d ' ' -f1; fi
}

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
cat > "$SHIM_DIR/hq" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$HQ_STUB_LOG"
[ "$1" = dm ] && echo "DM sent to $2 (eventId evt_stub123)"
exit 0
STUB
chmod +x "$SHIM_DIR/hq"

# Run a helper as if under Git Bash: substitute only the OSTYPE/MSYSTEM
# selectors, and swap GNU `sed -b 's/\r$//'` for an equivalent per-line CR
# strip that also works with BSD sed hosts.
msys_copy() { # src dest
  sed 's/\${OSTYPE:-}/${TEST_OSTYPE:-}/g; s/\${MSYSTEM:-}/${TEST_MSYSTEM:-}/g' "$1" \
    | perl -pe 's/command sed -b .s\/\\r\$\/\/./command perl -pe "s\/\\r\\n\\z\/\\n\/"/' > "$2"
  if grep -q 'sed -b' "$2"; then fail "sed -b substitution did not apply to $1"; fi
}

# --- hq-delegate-send fixture (mirrors hq-delegate-send.test.sh) -------------
mkdir -p "$TMP/scripts/lib"
cp "$SRC_DIR"/lib/secret-patterns.sh "$SRC_DIR"/lib/delegate-brainstorm.sh "$TMP/scripts/lib/"
msys_copy "$SRC_DIR/hq-delegate-send.sh" "$TMP/scripts/hq-delegate-send.sh"

setup_fixture() { # fixture_root
  local fix="$1" proj bundle rel
  proj="$fix/companies/acme/projects/widget"
  bundle="$fix/workspace/delegations/dlg-test-widget"
  rel="companies/acme/projects/widget/delegation/dlg-test-widget"
  mkdir -p "$proj" "$bundle" "$fix/$rel"
  cat > "$proj/prd.json" <<'JSON'
{"name":"widget","description":"Build the widget.","metadata":{"goal":"Widgets ship."},
 "userStories":[{"id":"US-001","title":"Frame","description":"Build the frame.","priority":1,"passes":true},
                {"id":"US-002","title":"Spin","description":"Make it spin.","priority":1,"passes":false}]}
JSON
  echo "# Delegation brief - widget" > "$bundle/BRIEF.md"
  cat > "$bundle/manifest.json" <<'JSON'
{"schemaVersion":1,"delegationId":"dlg-test-widget","mode":"transfer","company":"acme",
 "from":{"email":"owner@acme.test","personUid":null},
 "to":{"kind":"person","principal":"alice@acme.test","displayName":"Alice"},
 "project":{"name":"widget","prdPath":"companies/acme/projects/widget/prd.json","boardId":null},
 "vaultPrefixes":[{"prefix":"projects/widget/","permission":"write","reason":"dossier"},
                  {"prefix":"knowledge/eng/","permission":"read","reason":"knowledge"}],
 "repo":{"path":"repos/public/widget-repo","remote":"git@github.test:acme/widget-repo.git","branch":"feature/widget",
         "baseBranch":"main","headSha":"abc1234","dirtyFiles":[],"accessVerified":true,"accessNote":""},
 "secrets":["DATABASE_URL","WIDGET_API_KEY"],"status":"verified"}
JSON
  cp "$bundle/BRIEF.md" "$fix/$rel/BRIEF.md"
  "$REAL_JQ" '.status="granted" | .recipientAccess="unconfirmed"' "$bundle/manifest.json" > "$fix/$rel/manifest.json"
  "$REAL_JQ" --arg mp "$rel/manifest.json" --arg mh "$(hash_of "$fix/$rel/manifest.json")" \
    --arg bp "$rel/BRIEF.md" --arg bh "$(hash_of "$fix/$rel/BRIEF.md")" \
    --arg ph "$(hash_of "$proj/prd.json")" \
    '.publication={verifiedAt:"now",manifestPath:$mp,files:{($mp):$mh,($bp):$bh,"companies/acme/projects/widget/prd.json":$ph}}' \
    "$bundle/manifest.json" > "$TMP/m.tmp"
  mv "$TMP/m.tmp" "$bundle/manifest.json"
}

run_send() { # mode -> $TMP/out-<mode>/
  local mode="$1" out="$TMP/out-$1" fix="$TMP/fix-$1" ostype=msys msystem=MINGW64
  if [ "$mode" = native ]; then ostype=darwin; msystem=""; fi
  mkdir -p "$out"
  setup_fixture "$fix"
  : > "$out/count.log"; : > "$out/hq.log"
  PATH="$SHIM_DIR:$PATH" REAL_JQ="$REAL_JQ" TEST_JQ_MODE="$mode" JQ_COUNT_LOG="$out/count.log" \
    HQ_STUB_LOG="$out/hq.log" TEST_OSTYPE="$ostype" TEST_MSYSTEM="$msystem" HQ_ROOT="$fix" \
    bash "$TMP/scripts/hq-delegate-send.sh" --manifest "$fix/workspace/delegations/dlg-test-widget/manifest.json" --send \
    > "$out/stdout" 2> "$out/stderr" || fail "send preflight failed in $mode mode: $(cat "$out/stderr")"
  cp "$fix/workspace/delegations/dlg-test-widget/PICKUP-PROMPT.md" "$out/prompt"
  "$REAL_JQ" -S 'del(.sentAt)' "$fix/workspace/delegations/dlg-test-widget/manifest.json" > "$out/manifest"
  for f in stdout stderr prompt manifest hq.log; do
    sed "s#$fix#FIX#g" "$out/$f" > "$out/$f.norm"
  done
}

count() { grep -c "$1" "$2" || true; }

for mode in native modern legacy; do run_send "$mode"; done

if [ "${HQ_JQ_PROBE_TEST_REPORT:-0}" = 1 ]; then
  for mode in native modern legacy; do
    printf '%s: probes=%s jq-calls=%s\n' "$mode" \
      "$(count '^PROBE' "$TMP/out-$mode/count.log")" "$(count '^CALL' "$TMP/out-$mode/count.log")"
  done
  exit 0
fi

# 1. probe counts: native never probes; wrapped modes probe exactly once.
[ "$(count '^PROBE' "$TMP/out-native/count.log")" -eq 0 ] || fail "native run must not probe --binary"
for mode in modern legacy; do
  probes="$(count '^PROBE' "$TMP/out-$mode/count.log")"
  calls="$(count '^CALL' "$TMP/out-$mode/count.log")"
  [ "$probes" -eq 1 ] || fail "$mode: expected exactly 1 --binary probe per run, got $probes (calls=$calls)"
  [ "$calls" -ge 20 ] || fail "$mode: preflight ran too few jq calls ($calls); fixture did not reach --send"
done
grep -q '^PROBE-REJECTED$' "$TMP/out-legacy/count.log" || fail "legacy: probe was not rejected"
if grep -q 'binary=yes' "$TMP/out-legacy/count.log"; then fail "legacy: real calls must not pass --binary"; fi
if grep -q 'binary=no' "$TMP/out-modern/count.log"; then fail "modern: every real call must pass --binary"; fi
grep -q '^dm alice@acme.test ' "$TMP/out-native/hq.log" || fail "native run did not reach hq dm"
echo "probe ran once per send run (modern and no---binary legacy), never on native"

# 2. outputs identical across native, modern, and CRLF legacy runs.
for mode in modern legacy; do
  for f in stdout stderr prompt manifest hq.log; do
    cmp -s "$TMP/out-native/$f.norm" "$TMP/out-$mode/$f.norm" \
      || { diff "$TMP/out-native/$f.norm" "$TMP/out-$mode/$f.norm" >&2 || true; fail "$mode: $f differs from native"; }
  done
  if grep -q $'\r' "$TMP/out-$mode/prompt" "$TMP/out-$mode/manifest" "$TMP/out-$mode/stdout"; then
    fail "$mode: CR leaked into output"
  fi
done
echo "send outputs identical across native, --binary, and CRLF-stripping runs"

# 3. the other wrapped helpers probe once, not per call.
for asset in hq-delegate-grant.sh jobs-validate.sh hq-job-probe.sh; do
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
