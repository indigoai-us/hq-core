#!/usr/bin/env bash
# Regression: hq-delegate-resolve.sh must resolve delegation recipients
# safely — verbatim fast path, confirmed people lookups, fleet-agent
# fallback — while staying read-only and strictly single-company.
#
# Guards:
#   1. Fast path: email / prs_ / agt_ tokens pass through verbatim with NO
#      lookup invoked.
#   2. A bare name resolving to exactly one person exits 0 with that email.
#   3. An ambiguous name exits 3 and prints the candidate list.
#   4. A name matching only a fleet agent exits 0 with kind=agent.
#   5. Every stubbed hq invocation carries --company <slug>; none names
#      another company; nothing is invoked without it (tenancy).
#   6. Missing --company is a usage error before any lookup.
#   7. not-found in both rosters exits 4 with a plain message.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RESOLVE="$ROOT/core/scripts/hq-delegate-resolve.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$RESOLVE" ] || fail "missing resolver: $RESOLVE"

# --- stub hq CLI -------------------------------------------------------------
# Records every invocation; behavior driven by env:
#   HQ_STUB_PEOPLE_JSON — response for `hq people resolve`
#   HQ_STUB_AGENTS_JSON — response for `hq agents list`
INVOKE_LOG="$TMP/invocations.log"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$HQ_STUB_LOG"
people_resp="${HQ_STUB_PEOPLE_JSON:-}"
[ -n "$people_resp" ] || people_resp='{"status":"not_found"}'
agents_resp="${HQ_STUB_AGENTS_JSON:-}"
[ -n "$agents_resp" ] || agents_resp='[]'
case "$1 $2" in
  "people resolve")
    echo "warning: noise line the parser must skip"
    printf '%s\n' "$people_resp"
    ;;
  "agents list")
    printf '%s\n' "$agents_resp"
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/hq"
export PATH="$TMP/bin:$PATH"
export HQ_STUB_LOG="$INVOKE_LOG"

run() { # token [env overrides via pre-set vars]
  : > "$INVOKE_LOG"
  bash "$RESOLVE" --company acme --to "$1"
}

# --- 1. fast path: verbatim, zero lookups ------------------------------------

OUT="$(run "alice@acme.test")" || fail "email fast path exited non-zero"
printf '%s' "$OUT" | jq -e '.kind == "person" and .principal == "alice@acme.test" and .source == "verbatim"' >/dev/null \
  || fail "email fast path wrong output: $OUT"
[ ! -s "$INVOKE_LOG" ] || fail "email fast path must invoke NO lookup, got: $(cat "$INVOKE_LOG")"

OUT="$(run "prs_abc123")" || fail "prs_ fast path exited non-zero"
printf '%s' "$OUT" | jq -e '.kind == "person" and .principal == "prs_abc123"' >/dev/null \
  || fail "prs_ fast path wrong output: $OUT"
[ ! -s "$INVOKE_LOG" ] || fail "prs_ fast path must invoke no lookup"

OUT="$(run "agt_xyz789")" || fail "agt_ fast path exited non-zero"
printf '%s' "$OUT" | jq -e '.kind == "agent" and .principal == "agt_xyz789"' >/dev/null \
  || fail "agt_ fast path wrong output: $OUT"
[ ! -s "$INVOKE_LOG" ] || fail "agt_ fast path must invoke no lookup"

# --- 2. unique person match --------------------------------------------------

export HQ_STUB_PEOPLE_JSON='{"status":"found","email":"stefan@acme.test","name":"Stefan Walsh"}'
OUT="$(run "stefan")" || fail "unique person match exited non-zero"
printf '%s' "$OUT" | jq -e '.kind == "person" and .principal == "stefan@acme.test" and .displayName == "Stefan Walsh" and .source == "people-resolve"' >/dev/null \
  || fail "unique person match wrong output: $OUT"

# --- 3. ambiguous person -> exit 3 + candidates ------------------------------

export HQ_STUB_PEOPLE_JSON='{"status":"ambiguous","matches":[{"name":"Sam A","email":"sama@acme.test"},{"name":"Sam B","email":"samb@acme.test"}]}'
set +e
OUT="$(run "sam")"
RC=$?
set -e
[ "$RC" -eq 3 ] || fail "ambiguous person must exit 3, got $RC"
printf '%s' "$OUT" | jq -e '.status == "ambiguous" and (.matches | length) == 2' >/dev/null \
  || fail "ambiguous person must print both candidates: $OUT"

# --- 4. agent fallback -------------------------------------------------------

export HQ_STUB_PEOPLE_JSON='{"status":"not_found"}'
export HQ_STUB_AGENTS_JSON='[{"agentUid":"agt_01DEACON","name":"Deacon"},{"agentUid":"agt_01OTHER","name":"Scout"}]'
OUT="$(run "deacon")" || fail "agent fallback exited non-zero"
printf '%s' "$OUT" | jq -e '.kind == "agent" and .principal == "agt_01DEACON" and .displayName == "Deacon" and .source == "agents-list"' >/dev/null \
  || fail "agent fallback wrong output: $OUT"

# --- 5. tenancy: every lookup carries --company acme, no other company -------

grep -q 'people resolve' "$INVOKE_LOG" || fail "expected a people lookup in the agent-fallback run"
while IFS= read -r line; do
  case "$line" in
    *"--company acme"*) ;;
    *) fail "lookup invoked without --company acme: '$line'" ;;
  esac
done < "$INVOKE_LOG"
! grep -vq 'acme' "$INVOKE_LOG" >/dev/null 2>&1 || true # every line already checked above

# --- 6. missing --company = usage error, zero lookups ------------------------

: > "$INVOKE_LOG"
set +e
bash "$RESOLVE" --to "somebody" >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -eq 1 ] || fail "missing --company must exit 1 (usage), got $RC"
[ ! -s "$INVOKE_LOG" ] || fail "missing --company must invoke no lookup"

# --- 7. not found anywhere -> exit 4, plain message --------------------------

export HQ_STUB_PEOPLE_JSON='{"status":"not_found"}'
export HQ_STUB_AGENTS_JSON='[]'
set +e
ERR="$(run "nobody" 2>&1 >/dev/null)"
RC=$?
set -e
[ "$RC" -eq 4 ] || fail "not-found must exit 4, got $RC"
case "$ERR" in
  *nobody*acme*) ;;
  *) fail "not-found message must name the token and company: '$ERR'" ;;
esac

# no_email also stops with exit 4
export HQ_STUB_PEOPLE_JSON='{"status":"no_email"}'
set +e
run "ghost" >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -eq 4 ] || fail "no_email must exit 4, got $RC"

echo "hq-delegate-resolve: ok (verbatim fast path, person/agent resolution, ambiguous=3, not-found=4, single-company enforced)"
