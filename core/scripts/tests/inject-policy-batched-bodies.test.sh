#!/usr/bin/env bash
# Regression for matched hard-policy body extraction process churn.
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HOOK="$HQ_SRC/.claude/hooks/inject-policy-on-trigger.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -f "$HOOK" ] || fail "injector is missing"

ROOT="$TMP/hq"
SHIMS="$TMP/shims"
COUNT="$TMP/awk-count"
REAL_AWK="$(command -v awk)"
mkdir -p "$ROOT/.claude/hooks" "$ROOT/core/scripts" "$ROOT/core/policies" \
  "$ROOT/workspace/orchestrator/policy-trigger-state" "$SHIMS"
cp "$HOOK" "$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
cp "$HQ_SRC/core/scripts/hook-lib.sh" "$ROOT/core/scripts/hook-lib.sh"
cp "$HQ_SRC/core/scripts/eval-trigger.sh" "$ROOT/core/scripts/eval-trigger.sh"
cp "$HQ_SRC/core/scripts/derive-trigger-facts.sh" "$ROOT/core/scripts/derive-trigger-facts.sh"
chmod +x "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" "$ROOT/core/scripts/"*.sh

cat > "$SHIMS/awk" <<'SH'
#!/usr/bin/env bash
printf x >> "$HQ_TEST_AWK_COUNT"
exec "$HQ_TEST_REAL_AWK" "$@"
SH
chmod +x "$SHIMS/awk"

# The fixture is over 1,000 files, while 60 matching hard policies expose the
# body parsing cost without turning unrelated slug-ledger writes into the
# measured budget. Output limits are raised only inside this isolated test root
# so every matching slug is visible.
i=1
while [ "$i" -le 1001 ]; do
  printf -v slug 'latency-hard-%04d' "$i"
  trigger=unseen_fixture_word
  [ "$i" -le 60 ] && trigger=monitor
  cat > "$ROOT/core/policies/$slug.md" <<EOF
---
id: $slug
when: $trigger
on: [UserPromptSubmit]
enforcement: hard
---
## Rule
Binding fixture rule $i.
EOF
  i=$((i + 1))
done

SESSION="latency-batch-$$"
PAYLOAD="$(jq -cn --arg sid "$SESSION" --arg cwd "$ROOT" \
  '{session_id:$sid,hook_event_name:"UserPromptSubmit",cwd:$cwd,prompt:"[Monitor timed out — re-arm if needed.]"}')"

: > "$COUNT"
OUTPUT="$(printf '%s' "$PAYLOAD" | env \
  HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" HOME="$TMP/home" \
  HQ_POLICY_HARD_BUDGET_BYTES=0 HQ_POLICY_HARD_MAX_BYTES=128 \
  HQ_POLICY_OUTPUT_CEILING_BYTES=1000000 \
  HQ_TEST_AWK_COUNT="$COUNT" HQ_TEST_REAL_AWK="$REAL_AWK" PATH="$SHIMS:$PATH" \
  bash "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" 2>"$TMP/hook.err")"

for number in 0001 0030 0060; do
  grep -Fq "latency-hard-$number" <<<"$OUTPUT" \
    || fail "matched policy latency-hard-$number was omitted"
done
SLUG_COUNT="$(grep -c '^> Policy `latency-hard-' <<<"$OUTPUT" || true)"
[ "$SLUG_COUNT" -eq 60 ] || fail "expected 60 emitted matching policy IDs, got $SLUG_COUNT"
if grep -Fq 'latency-hard-0061' <<<"$OUTPUT"; then
  fail "non-matching policy latency-hard-0061 was emitted"
fi

AWK_COUNT="$(wc -c < "$COUNT" | tr -d '[:space:]')"
[ "$AWK_COUNT" -le 60 ] \
  || fail "1001-policy fixture with 60 matches launched $AWK_COUNT awk processes (budget: 60)"

printf 'PASS: 1001-policy fixture emitted 60 matching hard policies; awk process count=%s (budget 60)\n' "$AWK_COUNT"
