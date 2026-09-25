#!/usr/bin/env bash
# Regression for policy reminder trimming process churn and byte-accurate sizing.
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HOOK="${HQ_POLICY_HOOK_UNDER_TEST:-$HQ_SRC/.claude/hooks/inject-policy-on-trigger.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -f "$HOOK" ] || fail "injector is missing: $HOOK"

ROOT="$TMP/hq"
SHIMS="$TMP/shims"
TAIL_COUNT="$TMP/tail-count"
REAL_TAIL="$(command -v tail)"
mkdir -p "$ROOT/.claude/hooks" "$ROOT/core/scripts" "$ROOT/core/policies" \
  "$ROOT/personal/policies" "$ROOT/workspace/orchestrator/policy-trigger-state" "$SHIMS"
mkdir -p "$ROOT/core/scripts/lib"
cp "$HOOK" "$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
cp "$HQ_SRC/core/scripts/hook-lib.sh" "$ROOT/core/scripts/hook-lib.sh"
cp "$HQ_SRC/core/scripts/eval-trigger.sh" "$ROOT/core/scripts/eval-trigger.sh"
cp "$HQ_SRC/core/scripts/derive-trigger-facts.sh" "$ROOT/core/scripts/derive-trigger-facts.sh"
cp "$HQ_SRC/core/scripts/lib/trigger-fact-text.awk" "$ROOT/core/scripts/lib/trigger-fact-text.awk"
chmod +x "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" "$ROOT/core/scripts/"*.sh

cat > "$SHIMS/tail" <<'SH'
#!/usr/bin/env bash
printf x >> "$HQ_TEST_TAIL_COUNT"
exec "$HQ_TEST_REAL_TAIL" "$@"
SH
chmod +x "$SHIMS/tail"

write_policy() {
  local path="$1" slug="$2" rule="$3" enforcement="${4:-soft}"
  cat > "$path" <<EOF
---
id: $slug
title: "$slug"
scope: test
when: always
on: [UserPromptSubmit]
enforcement: $enforcement
---

## Rule

$rule
EOF
}

run_hook() {
  local sid="$1" output="$2" error="$3" ceiling="$4" input
  input="$(jq -cn --arg sid "$sid" --arg cwd "$ROOT" \
    '{session_id:$sid,hook_event_name:"UserPromptSubmit",cwd:$cwd,prompt:"synthetic user prompt"}')"
  BASH_ENV=/dev/null LC_ALL=C.UTF-8 env \
    HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" \
    HQ_POLICY_HARD_FULL_TEXT="${HQ_TEST_HARD_FULL_TEXT:-0}" \
    HQ_POLICY_OUTPUT_CEILING_BYTES="$ceiling" \
    HQ_TEST_TAIL_COUNT="$TAIL_COUNT" HQ_TEST_REAL_TAIL="$REAL_TAIL" \
    PATH="$SHIMS:$PATH" bash "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" \
    <<<"$input" >"$output" 2>"$error"
}

echo "[1] overflowing reminders do not launch one tail process per cut line"
padding="$(printf '%120s' '')"
padding="${padding// /r}"
i=1
while [ "$i" -le 250 ]; do
  printf -v slug 'trim-fixture-%04d' "$i"
  write_policy "$ROOT/core/policies/$slug.md" "$slug" "Rule $i $padding"
  i=$((i + 1))
done

: > "$TAIL_COUNT"
run_hook "trim-count-$$-${RANDOM}" "$TMP/trim.out" "$TMP/trim.err" 1000
tail_calls="$(wc -c < "$TAIL_COUNT" | tr -d '[:space:]')"
printf 'trim tail process launches: %s\n' "$tail_calls"
[ "$tail_calls" -le 1 ] \
  || fail "overflow trim launched $tail_calls tail processes; expected at most one"
grep -q '^> Output ceiling of 1000 bytes: [1-9][0-9]* lower-ranked policy line(s) cut from this reminder\.' "$TMP/trim.out" \
  || fail "overflow trim omitted its named cut notice"
grep -q '</policy-reminder>' "$TMP/trim.out" || fail "overflow trim did not close the reminder"

echo "[2] Unicode policy text is bounded and stats count UTF-8 bytes"
rm -f "$ROOT/core/policies/"*.md
unicode_rule=""
i=0
while [ "$i" -lt 130 ]; do
  unicode_rule="${unicode_rule}é"
  i=$((i + 1))
done
write_policy "$ROOT/core/policies/unicode-byte-size.md" unicode-byte-size "$unicode_rule" hard
unicode_sid="trim-unicode-$$-${RANDOM}"
HQ_TEST_HARD_FULL_TEXT=1 run_hook "$unicode_sid" "$TMP/unicode.out" "$TMP/unicode.err" 1024
unicode_bytes="$(wc -c < "$TMP/unicode.out" | tr -d '[:space:]')"
[ "$unicode_bytes" -le 1024 ] \
  || fail "Unicode reminder emitted $unicode_bytes bytes over its 1024-byte ceiling"
grep -q 'é' "$TMP/unicode.out" || fail "Unicode reminder omitted its multi-byte policy body"
stats_file="$ROOT/workspace/orchestrator/policy-emit-stats/$unicode_sid.txt"
[ -f "$stats_file" ] || fail "missing emission stats for Unicode reminder"
stats_bytes="$(awk -F '\t' 'END { print $3 }' "$stats_file")"
[ "$stats_bytes" = "$unicode_bytes" ] \
  || fail "stats recorded $stats_bytes bytes but Unicode stdout emitted $unicode_bytes"
printf 'Unicode reminder: stdout=%s bytes, stats=%s bytes\n' "$unicode_bytes" "$stats_bytes"

echo "PASS: inject-policy-output-trim-performance"
