#!/usr/bin/env bash
# Session gate fact CLI and hook-lib read API contract.
set -euo pipefail

ROOT="$(git -C "$(dirname "$0")/../../.." rev-parse --show-toplevel)"
if [ ! -x "$ROOT/core/scripts/hq-gate-fact.sh" ]; then
  printf '%s\n' 'FAIL shipped hq-gate-fact.sh is not executable' >&2
  exit 1
fi
printf '%s\n' 'PASS shipped hq-gate-fact.sh is executable'
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-gate-fact.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/hq"
mkdir -p "$FIXTURE/core/scripts/lib" "$FIXTURE/.claude/hooks/tests"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIXTURE/core/scripts/hook-lib.sh"
cp "$ROOT/core/scripts/lib/session-id.sh" "$FIXTURE/core/scripts/lib/session-id.sh"
cp "$ROOT/.claude/hooks/policy-enforcement-gate.sh" "$FIXTURE/.claude/hooks/policy-enforcement-gate.sh"
cp -p "$ROOT/core/scripts/hq-gate-fact.sh" "$FIXTURE/core/scripts/hq-gate-fact.sh"
export HQ_ROOT="$FIXTURE" HQ_SESSION_ID="gate-fact-test-session"
CLI="$FIXTURE/core/scripts/hq-gate-fact.sh"
CLI_SOURCE="${HQ_TEST_GATE_FACT_HELPER:-$ROOT/core/scripts/hq-gate-fact.sh}"
cp -p "$CLI_SOURCE" "$CLI"

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

[ "$("$CLI" list)" = '[]' ] && pass 'list is empty initially' || fail 'list is empty initially'
if "$CLI" check sending_account_confirmed 2>"$TMP/absent.err"; then fail 'absent check exits 1'; else rc=$?; [ "$rc" -eq 1 ] || fail 'absent check exits 1'; fi
[ -s "$TMP/absent.err" ] && [ "$(wc -l < "$TMP/absent.err" | tr -d ' ')" -eq 1 ] && pass 'absent check explains failure on one stderr line' || fail 'absent check explains failure on one stderr line'

if "$CLI" confirm sending_account_confirmed --note 'Selected account: hello@example.com' 2>"$TMP/no-proof.err"; then
  fail 'confirmation fact requires AskUserQuestion proof'
else rc=$?; [ "$rc" -eq 2 ] || fail 'confirmation fact requires AskUserQuestion proof'; fi
printf '%s' "$(jq -nc --arg sid "$HQ_SESSION_ID" '{session_id:$sid,prompt:"Confirm sending account."}')" \
  | HQ_ROOT="$FIXTURE" CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/hooks/policy-enforcement-gate.sh" UserPromptSubmit >/dev/null
printf '%s' "$(jq -nc --arg sid "$HQ_SESSION_ID" '{session_id:$sid,tool_name:"AskUserQuestion",tool_input:{questions:[{header:"gate-fact:sending_account_confirmed",question:"Confirm the selected sending account?"}]},tool_response:{answers:[{answer:"Confirmed"}]}}')" \
  | HQ_ROOT="$FIXTURE" CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/hooks/policy-enforcement-gate.sh" PostToolUse >/dev/null
"$CLI" confirm sending_account_confirmed --note 'ignored caller note'
FACT_DIR="$FIXTURE/workspace/orchestrator/hook-state/gate-facts/$HQ_SESSION_ID"
[ "$(jq -r '.fact' "$FACT_DIR/sending_account_confirmed.json")" = sending_account_confirmed ] || fail 'record stores fact'
[ "$(jq -r '.confirmed_at | type' "$FACT_DIR/sending_account_confirmed.json")" = string ] || fail 'record stores timestamp'
[ "$(jq -r '.note' "$FACT_DIR/sending_account_confirmed.json")" = 'Confirmed' ] || fail 'record stores proof answer as note'
[ "$(jq -r '.source' "$FACT_DIR/sending_account_confirmed.json")" = askuserquestion ] || fail 'record stores source'
[ "$(jq -r 'keys | sort | join(",")' "$FACT_DIR/sending_account_confirmed.json")" = 'confirmed_at,fact,note,source' ] || fail 'record has exactly the documented fields'
"$CLI" check sending_account_confirmed && pass 'fresh check exits 0' || fail 'fresh check exits 0'
"$CLI" check sending_account_confirmed --within 30 && pass 'fresh within-window check exits 0' || fail 'fresh within-window check exits 0'

if "$CLI" confirm recipients_confirmed --note 'literal helper confirmation' 2>"$TMP/recipient-proof.err"; then
  fail 'recipient confirmation cannot be minted without proof'
else rc=$?; [ "$rc" -eq 2 ] || fail 'recipient confirmation cannot be minted without proof'; fi
pass 'human confirmation facts require a matching AskUserQuestion proof'
LIST="$("$CLI" list)"
[ "$(printf '%s' "$LIST" | jq 'length')" -eq 1 ] && pass 'list returns every record as JSON array' || fail 'list returns every record as JSON array'

jq '.confirmed_at = "2000-01-01T00:00:00Z"' "$FACT_DIR/sending_account_confirmed.json" > "$TMP/stale.json"
mv "$TMP/stale.json" "$FACT_DIR/sending_account_confirmed.json"
if "$CLI" check sending_account_confirmed --within 30 2>"$TMP/stale.err"; then fail 'stale check exits 1'; else rc=$?; [ "$rc" -eq 1 ] || fail 'stale check exits 1'; fi
[ -s "$TMP/stale.err" ] && [ "$(wc -l < "$TMP/stale.err" | tr -d ' ')" -eq 1 ] && pass 'stale check explains failure on one stderr line' || fail 'stale check explains failure on one stderr line'

if "$CLI" confirm unknown_fact 2>"$TMP/unknown.err"; then fail 'unknown fact exits 2'; else rc=$?; [ "$rc" -eq 2 ] || fail 'unknown fact exits 2'; fi
if "$CLI" confirm draft_approved --source override 2>"$TMP/override.err"; then fail 'helper cannot mint override source'; else rc=$?; [ "$rc" -eq 2 ] || fail 'helper cannot mint override source'; fi
if "$CLI" check draft_approved --within nope 2>"$TMP/usage.err"; then fail 'invalid window exits 2'; else rc=$?; [ "$rc" -eq 2 ] || fail 'invalid window exits 2'; fi

"$CLI" revoke recipients_confirmed && pass 'revoke exits 0' || fail 'revoke exits 0'
if "$CLI" check recipients_confirmed 2>"$TMP/revoked.err"; then fail 'revoked fact is absent'; else rc=$?; [ "$rc" -eq 1 ] || fail 'revoked fact is absent'; fi

. "$FIXTURE/core/scripts/hook-lib.sh"
hq_gate_fact_present sending_account_confirmed 30 && fail 'hook-lib rejects stale fact' || pass 'hook-lib rejects stale fact'
"$CLI" confirm humanize_passed
hq_gate_fact_present humanize_passed 30 && pass 'hook-lib accepts fresh fact' || fail 'hook-lib accepts fresh fact'
printf 'hq-gate-fact: all checks passed\n'
