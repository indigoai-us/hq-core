#!/usr/bin/env bash
# Accepted structured questions must have a visible text fallback unless rendering is confirmed.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
POLICY="$ROOT/core/policies/hq-codex-decision-gate-fallback.md"
EVALUATOR="$ROOT/core/scripts/eval-trigger.sh"
FACT_DERIVER="$ROOT/core/scripts/derive-trigger-facts.sh"
WHEN="$(sed -n 's/^when:[[:space:]]*//p' "$POLICY")"
EVENTS="$(sed -n 's/^on:[[:space:]]*//p' "$POLICY")"
case "$EVENTS" in
  *PreToolUse*) ;;
  *) echo "FAIL: policy must subscribe to PreToolUse for tool-call facts (on: $EVENTS)" >&2; exit 1 ;;
esac
MATCHING_FACTS="$(printf '%s\n' '{"tool_name":"request_user_input"}' | bash "$FACT_DERIVER" PreToolUse)"
[ -n "$WHEN" ] || { echo 'FAIL: policy has no when expression' >&2; exit 1; }

set +e
bash "$EVALUATOR" "$WHEN" "$MATCHING_FACTS" >/dev/null
matching_rc=$?
bash "$EVALUATOR" "$WHEN" 'unrelated_trigger_fact' >/dev/null
unrelated_rc=$?
set -e
if [ "$matching_rc" -ne 0 ]; then
  echo "FAIL: when expression must match derived facts ($MATCHING_FACTS) with exit 0; got exit $matching_rc" >&2
  exit 1
fi
if [ "$unrelated_rc" -ne 1 ]; then
  echo "FAIL: when expression must reject an unrelated fact with exit 1; got exit $unrelated_rc" >&2
  exit 1
fi

python3 - "$POLICY" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
required = {
    "accepted without render confirmation is treated as unconfirmed":
        "When a structured question tool returns an accepted result without an explicit render confirmation, treat visibility as unconfirmed.",
    "fallback preserves the exact question and choices":
        "Immediately print the same question and every choice in plain text, then wait for the user's answer.",
    "confirmed rendering suppresses duplicate fallback":
        "If the tool explicitly confirms that the question and choices were rendered to the user, do not print the text fallback.",
}
missing = [description for description, phrase in required.items() if phrase not in text]
if missing:
    raise SystemExit("missing required decision-prompt fallback guidance: " + "; ".join(missing))
print("PASS: accepted structured questions have a render-aware plain-text fallback")
PY
printf 'PASS: trigger outcomes matching=%s unrelated=%s\n' "$matching_rc" "$unrelated_rc"
