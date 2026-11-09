#!/usr/bin/env bash
# identity-resolve-expiry-shapes.test.sh — expiry parsing for every
# cognito-tokens.json shape (feedback_24c3ce48).
#
# hq CLI 5.345.x writes expiresAt as an ISO string when it falls back from the
# Keychain to the JSON file; older/other writers use epoch-ms numbers, epoch
# seconds, expires_at, or nest the fields. The resolver only understood
# epoch-ms, so an ISO file gave EXP=0 and /deploy always answered
# login_required.
#
# For each shape, with a valid (1h left) and an expired (2h ago) token:
#   valid   -> cache hit (status ok, source cache)
#   expired -> never served from cache
# Run under both JSON engines (jq present, and node only).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$SCRIPT_DIR/identity-resolve.sh"
FAIL=0

pass() { printf '  ok   %s\n' -- "$1"; }
fail() { printf '  FAIL %s\n' -- "$1"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v jq >/dev/null 2>&1 || { echo "SKIP: host needs jq to assert results"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP: host needs node for the node-engine pass"; exit 0; }

# ISO / epoch helpers computed with node so BSD and GNU date do not matter.
iso_at()  { node -e 'process.stdout.write(new Date(Date.now()+Number(process.argv[1])*1000).toISOString())' -- "$1"; }
ms_at()   { node -e 'process.stdout.write(String(Date.now()+Number(process.argv[1])*1000))' -- "$1"; }
sec_at()  { node -e 'process.stdout.write(String(Math.floor(Date.now()/1000)+Number(process.argv[1])))' -- "$1"; }
iso_off() { # +05:00 offset form of the same instant
  node -e 'const t=Date.now()+Number(process.argv[1])*1000;const d=new Date(t+5*3600000);process.stdout.write(d.toISOString().replace("Z","+05:00"))' -- "$1"
}
iso_nofrac() { node -e 'process.stdout.write(new Date(Date.now()+Number(process.argv[1])*1000).toISOString().replace(/\.[0-9]+Z$/,"Z"))' -- "$1"; }

# write_token <home> <shape> <offset_seconds>
write_token() {
  local home=$1 shape=$2 off=$3 v
  mkdir -p "$home/.hq"
  local f="$home/.hq/cognito-tokens.json"
  case "$shape" in
    epoch-ms)      v=$(ms_at "$off");  printf '{"accessToken":"a.jwt","idToken":"i.jwt","refreshToken":"r","expiresAt":%s}\n' "$v" > "$f" ;;
    epoch-sec)     v=$(sec_at "$off"); printf '{"accessToken":"a.jwt","idToken":"i.jwt","refreshToken":"r","expiresAt":%s}\n' "$v" > "$f" ;;
    iso-ms)        v=$(iso_at "$off"); printf '{"accessToken":"a.jwt","idToken":"i.jwt","refreshToken":"r","expiresAt":"%s"}\n' "$v" > "$f" ;;
    iso-nofrac)    v=$(iso_nofrac "$off"); printf '{"accessToken":"a.jwt","idToken":"i.jwt","refreshToken":"r","expiresAt":"%s"}\n' "$v" > "$f" ;;
    iso-offset)    v=$(iso_off "$off"); printf '{"accessToken":"a.jwt","idToken":"i.jwt","refreshToken":"r","expiresAt":"%s"}\n' "$v" > "$f" ;;
    numeric-str)   v=$(ms_at "$off");  printf '{"accessToken":"a.jwt","idToken":"i.jwt","refreshToken":"r","expiresAt":"%s"}\n' "$v" > "$f" ;;
    snake-ms)      v=$(ms_at "$off");  printf '{"accessToken":"a.jwt","idToken":"i.jwt","refreshToken":"r","expires_at":%s}\n' "$v" > "$f" ;;
    snake-sec)     v=$(sec_at "$off"); printf '{"accessToken":"a.jwt","idToken":"i.jwt","refreshToken":"r","expires_at":%s}\n' "$v" > "$f" ;;
    snake-iso)     v=$(iso_at "$off"); printf '{"accessToken":"a.jwt","idToken":"i.jwt","refreshToken":"r","expires_at":"%s"}\n' "$v" > "$f" ;;
  esac
}

SHAPES="epoch-ms epoch-sec iso-ms iso-nofrac iso-offset numeric-str snake-ms snake-sec snake-iso"

run_resolver() { # <home> <path>
  local tmpd="$TMP/tmpdir"; mkdir -p "$tmpd"
  touch "$tmpd/hq-deploy-login-attempted-shapetest"
  env -u USERNAME -u HQ_MACHINE_CREDS_FILE -u HQ_MACHINE_TOKEN_STATE_DIR -u HQ_WORK_MESH_ROOT \
    USER=shapetest HOME="$1" TMPDIR="$tmpd" PATH="$2" /bin/bash "$RESOLVER" 2>/dev/null
}

# Minimal PATH: no hq-auth-refresh / npx / hq, so the refresh and login paths
# no-op and only a true cache hit can return ok.
mkbin() { # <dir> <tools...>
  local d=$1; shift; mkdir -p "$d"
  local t p
  for t in "$@"; do p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$d/$t"; done
}
mkbin "$TMP/bin-jq"   jq node date mktemp find
mkbin "$TMP/bin-node" node date mktemp find

for engine in jq node; do
  for shape in $SHAPES; do
    H="$TMP/h-$engine-$shape-valid"
    write_token "$H" "$shape" 3600
    OUT=$(run_resolver "$H" "$TMP/bin-$engine")
    if printf '%s\n' "$OUT" | jq -e '.status == "ok" and .source == "cache" and .jwt == "a.jwt"' >/dev/null 2>&1; then
      pass "[$engine] $shape valid -> cache hit"
    else
      fail "[$engine] $shape valid should be a cache hit (got: $(printf '%s' "$OUT" | head -c 120))"
    fi
    H="$TMP/h-$engine-$shape-expired"
    write_token "$H" "$shape" -7200
    OUT=$(run_resolver "$H" "$TMP/bin-$engine")
    if printf '%s\n' "$OUT" | jq -e '.status == "ok"' >/dev/null 2>&1; then
      fail "[$engine] $shape expired was served (got: $(printf '%s' "$OUT" | head -c 120))"
    else
      pass "[$engine] $shape expired -> not served from cache"
    fi
  done
done

# raw_case <label> <expect: served|refused> <expiry-json-fragment>
# Strict-parse policy (both engines agree): only epoch numbers, numeric
# strings, and full ISO-8601 with a time AND an explicit zone (Z or +hh:mm)
# are accepted. Zone-less ISO, date-only, and free text are refused.
raw_case() {
  local label=$1 expect=$2 frag=$3 engine H OUT
  for engine in jq node; do
    H="$TMP/h-raw-$engine-$label"; mkdir -p "$H/.hq"
    printf '{"accessToken":"a.jwt","idToken":"i.jwt","refreshToken":"r",%s}\n' "$frag" > "$H/.hq/cognito-tokens.json"
    OUT=$(run_resolver "$H" "$TMP/bin-$engine")
    if printf '%s\n' "$OUT" | jq -e '.status == "ok" and .source == "cache"' >/dev/null 2>&1; then
      if [ "$expect" = served ]; then pass "[$engine] $label served"; else fail "[$engine] $label was served"; fi
    else
      if [ "$expect" = refused ]; then pass "[$engine] $label refused"; else fail "[$engine] $label should be served (got: $(printf '%s' "$OUT" | head -c 100))"; fi
    fi
  done
}
raw_case garbage        refused '"expiresAt":"not-a-date"'
raw_case zoneless-iso   refused '"expiresAt":"2099-01-01T00:00:00"'
raw_case free-text-year refused '"expiresAt":"foo 2099"'
raw_case date-only      refused '"expiresAt":"2099-01-01"'
raw_case malformed-sibling served '"expiresAt":4102444800000,"tokens":"x","session":7'
# Conflicting candidates: the most conservative (earliest) one wins.
raw_case conflict-expired-first refused '"expiresAt":4102444800000,"expires_at":1000000000000'
raw_case conflict-expired-last  refused '"expiresAt":1000000000000,"expires_at":4102444800000'
raw_case conflict-both-valid    served  '"expiresAt":4102444800000,"expires_at":4102444900000'

if [ "$FAIL" = "0" ]; then echo "ALL PASS"; exit 0; else echo "FAILURES"; exit 1; fi
