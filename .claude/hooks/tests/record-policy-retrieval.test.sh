#!/bin/bash
# record-policy-retrieval.test.sh — the retrieval ledger records and is read.
#
# Covers:
#   - hook-gate.sh lets the gated registry hook `record-policy-retrieval` run
#     under the standard and strict profiles (it was missing from both lists,
#     so master-hook skipped it and the ledger was never written).
#   - record-policy-retrieval.sh with fake Read, Bash cat, and qmd get payloads:
#     per-session state lines and the durable JSONL ledger line format.
#   - policy-retrieval-report.sh: last_retrieved, retrieval_count,
#     `never` for unretrieved policies, stale-first order.
#   - lint-policy-triggers.sh --usage: zero recent retrievals plus >= N matches.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/record-policy-retrieval.sh"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
AGE="$ROOT/core/scripts/policy-retrieval-report.sh"
LINT="$ROOT/core/scripts/lint-policy-triggers.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*"; }

TMP="$(mktemp -d "${HQ_TEST_TMPDIR:-${TMPDIR:-/tmp}}/record-policy-retrieval.XXXXXX")" || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/hq"
mkdir -p "$FAKE/workspace/orchestrator" "$FAKE/core/policies" "$FAKE/personal/policies"
STATE="$FAKE/workspace/orchestrator/policy-retrieval-state/sess-1.txt"
DURABLE="$FAKE/workspace/orchestrator/policy-retrieval-ledger.jsonl"

fire() {  # $1 = JSON payload
  printf '%s' "$1" | HQ_ROOT="$FAKE" bash "$HOOK"
}

# ── profile gate ────────────────────────────────────────────────────────────
# shellcheck disable=SC1090
. "$GATE" --lib
for prof in standard strict; do
  if hq_hook_profile_allows record-policy-retrieval "$prof"; then ok; else bad "profile $prof does not allow record-policy-retrieval"; fi
done

# ── hook: Read, Bash cat, qmd get ───────────────────────────────────────────
fire '{"session_id":"sess-1","tool_name":"Read","tool_input":{"file_path":"/h/core/policies/alpha-rule.md"}}'
fire '{"session_id":"sess-1","tool_name":"Bash","tool_input":{"command":"cat personal/policies/beta-rule.md"}}'
fire '{"session_id":"sess-1","tool_name":"Bash","tool_input":{"command":"qmd get gamma-rule"}}'
# duplicate and non-policy reads add nothing
fire '{"session_id":"sess-1","tool_name":"Read","tool_input":{"file_path":"/h/core/policies/alpha-rule.md"}}'
fire '{"session_id":"sess-1","tool_name":"Read","tool_input":{"file_path":"/h/core/scripts/x.sh"}}'

if [ "$(cat "$STATE" 2>/dev/null)" = "$(printf 'alpha-rule\nbeta-rule\ngamma-rule')" ]; then ok; else bad "state file: $(cat "$STATE" 2>/dev/null)"; fi
if [ "$(wc -l < "$DURABLE" 2>/dev/null | tr -d ' ')" = "3" ]; then ok; else bad "durable ledger line count: $(wc -l < "$DURABLE" 2>/dev/null)"; fi

LINE_RE='^\{"policy":"[a-z0-9-]+","session":"sess-1","ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z","via":"(read|bash|qmd)"\}$'
if [ -f "$DURABLE" ] && ! grep -vEq "$LINE_RE" "$DURABLE"; then ok; else bad "durable line format"; cat "$DURABLE" 2>/dev/null; fi
got="$(jq -r '"\(.policy):\(.via)"' "$DURABLE" 2>/dev/null | tr '\n' ' ')"
if [ "$got" = "alpha-rule:read beta-rule:bash gamma-rule:qmd " ]; then ok; else bad "durable rows: $got"; fi

# no session id: nothing written
fire '{"tool_name":"Read","tool_input":{"file_path":"/h/core/policies/delta-rule.md"}}'
if ! grep -q delta-rule "$DURABLE"; then ok; else bad "recorded without a session id"; fi

# ── age report ──────────────────────────────────────────────────────────────
for s in alpha-rule beta-rule never-rule; do
  printf -- '---\nid: %s\nwhen: git\non: [PreToolUse]\n---\n\n## Rule\n\nx\n' "$s" > "$FAKE/core/policies/$s.md"
done
cat > "$DURABLE" <<'EOF'
{"policy":"alpha-rule","session":"s1","ts":"2026-09-01T00:00:00Z","via":"read"}
{"policy":"alpha-rule","session":"s2","ts":"2026-10-01T00:00:00Z","via":"qmd"}
{"policy":"beta-rule","session":"s1","ts":"2026-08-01T00:00:00Z","via":"bash"}
EOF
report="$(HQ_ROOT="$FAKE" bash "$AGE" 2>&1)"
want="$(printf 'last_retrieved\tretrieval_count\tpolicy\nnever\t0\tcore/policies/never-rule.md\n2026-08-01T00:00:00Z\t1\tcore/policies/beta-rule.md\n2026-10-01T00:00:00Z\t2\tcore/policies/alpha-rule.md')"
if [ "$report" = "$want" ]; then ok; else bad "age report:"; printf '%s\n' "$report"; fi

# ── lint --usage ────────────────────────────────────────────────────────────
TS="$FAKE/workspace/orchestrator/policy-trigger-state"; mkdir -p "$TS"
i=0
while [ "$i" -lt 60 ]; do
  printf 'never-rule\nalpha-rule\n' > "$TS/s$i.txt"
  printf 'beta-rule\n' > "$TS/s$i.turn.txt"
  i=$((i + 1))
done
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"policy":"alpha-rule","session":"s9","ts":"%s","via":"read"}\n' "$now" >> "$DURABLE"
usage="$(HQ_ROOT="$FAKE" bash "$LINT" --usage "$FAKE/core/policies" 2>&1)"
if printf '%s\n' "$usage" | grep -q 'UNUSED .* 60 matches  core/policies/never-rule.md'; then ok; else bad "usage misses never-rule"; printf '%s\n' "$usage"; fi
if ! printf '%s\n' "$usage" | grep -q 'alpha-rule\|beta-rule'; then ok; else bad "usage lists a retrieved or under-threshold policy"; printf '%s\n' "$usage"; fi
if printf '%s\n' "$usage" | grep -q 'dead-or-unmatchable .*: 1$'; then ok; else bad "usage summary"; printf '%s\n' "$usage"; fi

echo "record-policy-retrieval: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
