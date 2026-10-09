#!/usr/bin/env bash
# hq-core: public
# Exercise add-company followed by the production SessionStart hook in a fixture HQ root.

set -euo pipefail

SOURCE_ROOT="${HQ_CORE_SOURCE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
assert_eq() {
  if [ "$1" = "$2" ]; then
    echo "PASS: $3"
  else
    fail "$3: expected '$2', got '$1'"
  fi
}

FIX="$TMP/hq"
HOME="$TMP/home"
mkdir -p "$FIX/core/scripts/lib" "$FIX/core/hooks/SessionStart" "$FIX/.codex/hooks" \
  "$FIX/workspace/sessions" "$FIX/companies/indigo" "$FIX/companies/beta" \
  "$FIX/companies/gamma" "$FIX/companies/unrelated" "$HOME/.hq"
cp "$SOURCE_ROOT/core/scripts/hq-session.sh" "$FIX/core/scripts/"
cp "$SOURCE_ROOT/core/scripts/lib/session-id.sh" "$SOURCE_ROOT/core/scripts/lib/session-scope-capability.sh" \
  "$SOURCE_ROOT/core/scripts/lib/session-auto-bind.sh" "$SOURCE_ROOT/core/scripts/lib/work-mesh-enqueue.sh" \
  "$FIX/core/scripts/lib/"
cp "$SOURCE_ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$FIX/core/scripts/"
cp "$SOURCE_ROOT/.codex/hooks/codex-explicit-path-flag.cjs" "$FIX/.codex/hooks/"

export HOME HQ_HQ_SESSION_NO_CLI=1 HQ_ROOT="$FIX" HQ_SESSION_ID=multi-company-session
export WORK_MESH_SEQ_DIR="$TMP/mesh-seq" HQ_WORK_MESH_RECONCILE_LOG="$TMP/reconcile.log"

set_flag() {
  local value="$1" now
  now="$(cut -d. -f1 /proc/uptime)"
  printf '%s %s\n' "$value" "$now" >"$HOME/.hq/hook-flag.multi-company-session-lock.indigo"
}

run_add() {
  HQ_HQ_SESSION_NO_CLI=1 HQ_ROOT="$FIX" HQ_SESSION_ID="$HQ_SESSION_ID" \
    bash "$FIX/core/scripts/hq-session.sh" add company "$1" >/dev/null
}

run_sessionstart() {
  HQ_ROOT="$FIX" HQ_SESSION_ID="$HQ_SESSION_ID" CLAUDE_CODE_SESSION_ID="$HQ_SESSION_ID" \
    HQ_WORK_MESH_RECONCILE_STUB=1 bash "$FIX/core/hooks/SessionStart/35-work-mesh-session-start.sh" SessionStart \
    <<<"{\"session_id\":\"$HQ_SESSION_ID\",\"cwd\":\"$FIX\"}"
}

cap="$FIX/workspace/sessions/$HQ_SESSION_ID/scope-capability.json"
mkdir -p "$(dirname "$cap")"
printf 'session_id: %s\ncompany_slug: indigo\nsenior: user\n' "$HQ_SESSION_ID" \
  >"$FIX/workspace/sessions/$HQ_SESSION_ID/meta.yaml"
set_flag true
bash "$FIX/core/scripts/hq-session.sh" set company_slug indigo >/dev/null

# Keep the hook absent while exercising the two synchronous add calls. Then run
# the production SessionStart entrypoint in the foreground. Its documented
# reconcile stub avoids detached CLI work in this fixture.
run_add beta
run_add gamma
cp "$SOURCE_ROOT/core/hooks/SessionStart/35-work-mesh-session-start.sh" "$FIX/core/hooks/SessionStart/"
run_sessionstart
assert_eq "$(jq -c '.company_slugs' "$cap")" '["indigo","beta","gamma"]' \
  "add twice then production SessionStart preserves the full ordered lock"

# Re-adding an already-listed company repairs capability drift from meta.yaml.
hook="$FIX/core/hooks/SessionStart/35-work-mesh-session-start.sh"
mv "$hook" "$TMP/sessionstart-hook.sh"
jq 'del(.company_slugs)' "$cap" >"$TMP/cap-primary-only.json"
cp "$TMP/cap-primary-only.json" "$cap"
run_add gamma
assert_eq "$(jq -c '.company_slugs' "$cap")" '["indigo","beta","gamma"]' \
  "adding an already-listed company repairs the complete capability set"

bash -c '. "$1/core/scripts/lib/session-scope-capability.sh"; . "$1/core/scripts/lib/session-auto-bind.sh"; session_auto_bind_apply_validated_default "$1" "$2" indigo test-company-uid 0 false' \
  _ "$FIX" "$HQ_SESSION_ID"
assert_eq "$(jq -c '.company_slugs' "$cap")" '["indigo","beta","gamma"]' \
  "validated-default auto-bind preserves the existing set for the same primary"
mv "$TMP/sessionstart-hook.sh" "$hook"

# A real primary change deliberately resets the set to the new primary.
mv "$hook" "$TMP/sessionstart-hook.sh"
bash "$FIX/core/scripts/hq-session.sh" set company_slug beta >/dev/null
assert_eq "$(jq -c '.company_slugs' "$cap")" '["beta"]' "primary change resets the lock set"
bash "$FIX/core/scripts/hq-session.sh" set company_slug indigo >/dev/null
mv "$TMP/sessionstart-hook.sh" "$hook"

# The explicit false kill switch retains primary-only behavior through SessionStart.
mv "$hook" "$TMP/sessionstart-hook.sh"
run_add beta
set_flag false
mv "$TMP/sessionstart-hook.sh" "$hook"
run_sessionstart
assert_eq "$(jq -c '.company_slugs // [.company_slug]' "$cap")" '["indigo"]' \
  "explicit false kill switch keeps primary-only capability"

# A same-primary rebind must not repair a malformed capability from metadata.
set_flag true
jq '.company_slugs = ["indigo", 7]' "$cap" >"$TMP/cap-malformed.json"
cp "$TMP/cap-malformed.json" "$cap"
run_sessionstart
assert_eq "$(jq -c '.company_slugs' "$cap")" '["indigo",7]' \
  "SessionStart leaves a malformed lock set fail-closed"
assert_eq "$(bash -c '. "$1/core/scripts/lib/session-scope-capability.sh"; session_scope_read_companies "$1" "$2" | paste -sd, -' _ "$FIX" "$HQ_SESSION_ID")" "" \
  "malformed lock set does not authorize any company"

# An explicit set replaces a malformed same-primary record instead of failing.
if bash -c '. "$1/core/scripts/lib/session-scope-capability.sh"; session_scope_mint_set "$1" "$2" indigo,beta' \
  _ "$FIX" "$HQ_SESSION_ID"; then
  echo "PASS: explicit set over a malformed record succeeds"
else
  fail "explicit set over a malformed record returned non-zero"
fi
assert_eq "$(jq -c '.company_slugs' "$cap")" '["indigo","beta"]' \
  "explicit set replaces a malformed same-primary lock set"

# Repair never normalizes a malformed metadata entry into a real company slug.
mv "$hook" "$TMP/sessionstart-hook.sh"
bash -c '. "$1/core/scripts/lib/session-scope-capability.sh"; session_scope_mint_set "$1" "$2" indigo' _ "$FIX" "$HQ_SESSION_ID"
meta_file="$FIX/workspace/sessions/$HQ_SESSION_ID/meta.yaml"
awk '$1 == "company_slugs:" { print "company_slugs: indigo,beta,gam ma"; next } { print }' "$meta_file" >"$TMP/meta.yaml"
cp "$TMP/meta.yaml" "$meta_file"
run_add beta
assert_eq "$(jq -c '.company_slugs' "$cap")" '["indigo","beta"]' \
  "repair rejects a metadata entry with inner whitespace instead of authorizing gamma"
mv "$TMP/sessionstart-hook.sh" "$hook"

# An automatic re-mint waits for an in-flight lock-set update and then keeps
# the set that update wrote, instead of writing back a stale snapshot.
lock_dir="$FIX/workspace/sessions/$HQ_SESSION_ID/.company-lock-set.lock"
mkdir "$lock_dir"
printf '%s\n' "$$" >"$lock_dir/pid"
# A sentinel minted_at makes any write during the hold visible, even within
# the same second as the previous mint.
jq -c '.minted_at = "held-sentinel"' "$cap" >"$TMP/cap-held.json"
cp "$TMP/cap-held.json" "$cap"
before="$(jq -c . "$cap")"
bash -c '. "$1/core/scripts/lib/session-scope-capability.sh"; session_scope_mint "$1" "$2" indigo' \
  _ "$FIX" "$HQ_SESSION_ID" &
remint_pid=$!
sleep 1
assert_eq "$(jq -c . "$cap")" "$before" "re-mint does not write while a lock-set update holds the lock"
jq -c '.company_slugs = ["indigo","beta","gamma"]' "$cap" >"$TMP/cap-new.json"
cp "$TMP/cap-new.json" "$cap"
rm -rf "$lock_dir"
wait "$remint_pid" || fail "re-mint after lock release returned non-zero"
assert_eq "$(jq -c '.company_slugs' "$cap")" '["indigo","beta","gamma"]' \
  "re-mint after the update keeps the newly written lock set"

[ "$FAILURES" -eq 0 ] || exit 1
echo "PASS: session-auto-bind-multicompany-sessionstart.test.sh"
