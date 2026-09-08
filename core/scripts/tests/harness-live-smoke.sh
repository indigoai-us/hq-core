#!/usr/bin/env bash
# hq-core: public
# harness-live-smoke.sh — drive ONE real headless turn per runtime against this
# HQ tree and prove the hook harness actually fired and stayed deliverable
# (2026-09-07). Unit suites simulate dispatch; this is the live check that a
# core change works in Claude Code, Codex, and Grok Build before release.
#
# Per runtime it asserts:
#   1. the turn completed (exit 0) and echoed the sentinel
#   2. hooks fired: a NEW policy-trigger ledger with >= 1 slug appeared
#   3. every policy reminder emitted during the turn stayed under the host
#      ceiling (workspace/orchestrator/policy-emit-stats: max bytes < 10000,
#      and <= HQ_POLICY_OUTPUT_CEILING_BYTES, default 8000)
#   4. (claude only) no persisted hook output for the session, i.e. nothing the
#      host truncated (~/.claude/projects/*/<session>/tool-results/hook-*.txt)
#
# Usage:
#   harness-live-smoke.sh [--runtimes claude,codex,grok] [--timeout 240] [--require] [--fleet]
#   Runs each runtime whose CLI is on PATH; missing CLIs are SKIPPED (exit 0)
#   unless --require. --fleet prints the agents-v2 fleet canary steps (a live
#   box drill cannot run from a laptop) and, when HQ_FLEET_LEDGER_CHECK=1, runs
#   core/scripts/check-hq-hooks.sh --require-ledger on this box.
# Cost: one short model turn per runtime. Needs the runtimes to be logged in.
# Env: HQ_LIVE_SMOKE_CODEX_MODEL=<model> if the installed Codex CLI cannot run
#      the configured default model; HQ_LIVE_SMOKE_TIMEOUT seconds per turn.
set -uo pipefail
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}}"
RUNTIMES="claude,codex,grok"; TIMEOUT="${HQ_LIVE_SMOKE_TIMEOUT:-240}"; REQUIRE=0; FLEET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --runtimes) RUNTIMES="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --require) REQUIRE=1; shift ;;
    --fleet) FLEET=1; shift ;;
    -h|--help) sed -n 2,24p "$0"; exit 0 ;;
    *) echo "harness-live-smoke: unknown arg $1" >&2; exit 2 ;;
  esac
done
CEIL="${HQ_POLICY_OUTPUT_CEILING_BYTES:-8000}"; HOST_LIMIT=10000
LED="$HQ_ROOT/workspace/orchestrator/policy-trigger-state"; STATS="$HQ_ROOT/workspace/orchestrator/policy-emit-stats"
mkdir -p "$LED" "$STATS"
PROMPT='Reply with exactly the text HQ-SMOKE-OK and nothing else. Do not run tools.'
pass=0; fail=0; skipped=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1" >&2; }
new_files() { find "$1" -name '*.txt' -newer "$REF" 2>/dev/null; }
newest_of() { # <newline list of files> -> the most recently modified one
  local f best="" bm=0 m
  while IFS= read -r f; do [ -n "$f" ] || continue; m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")"; [ "${m:-0}" -gt "$bm" ] && { bm="$m"; best="$f"; }; done <<<"$1"
  printf '%s' "$best"
}
run_with_timeout() { # <seconds> <cmd...>
  if command -v timeout >/dev/null 2>&1; then timeout "$1" "${@:2}"; elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$1" "${@:2}"; else "${@:2}"; fi
}
check_common() { # <runtime> <sid-or-empty>
  local rt="$1" sid="$2" f led_new stats_new max
  # Without a known session id, take it from the newest emit-stats file the
  # loader wrote during the turn (Codex/Grok reuse stable ids, so their trigger
  # ledger may not change mtime on a repeat turn while the stats always append).
  if [ -z "$sid" ]; then
    f="$(newest_of "$(new_files "$STATS" | grep -v "${HQ_SESSION_ID:-__none__}")")"
    [ -n "$f" ] && sid="$(basename "$f" .txt)"
  fi
  led_new=""; [ -n "$sid" ] && [ -f "$LED/$sid.txt" ] && led_new="$LED/$sid.txt"
  if [ -n "$led_new" ] && [ -n "$(cat $led_new 2>/dev/null | grep -c . | head -1)" ] && [ "$(cat $led_new 2>/dev/null | grep -c .)" -gt 0 ]; then ok "$rt: hooks fired ($(cat $led_new | grep -c .) policies recorded in the trigger ledger)"; else bad "$rt: no new policy-trigger ledger — hooks did not fire"; fi
  if [ -n "$sid" ] && [ -f "$STATS/$sid.txt" ]; then stats_new="$STATS/$sid.txt"; else stats_new="$(new_files "$STATS" | grep -v "${HQ_SESSION_ID:-__none__}" | head -20)"; fi
  if [ -n "$stats_new" ]; then
    max="$(cat $stats_new | awk -F'\t' '{ if ($3+0 > m) m=$3+0 } END { print m+0 }')"
    if [ "$max" -lt "$HOST_LIMIT" ] && [ "$max" -le "$CEIL" ]; then ok "$rt: largest policy reminder ${max} bytes (ceiling $CEIL, host limit $HOST_LIMIT)"; else bad "$rt: a policy reminder was ${max} bytes — over the ceiling; the host would truncate it"; fi
  else bad "$rt: no emit stats for the turn — the policy loader did not run"; fi
}

REF="$(mktemp)"; FX_ERR="$(mktemp)"; sleep 1
for rt in $(tr ',' ' ' <<<"$RUNTIMES"); do
  echo "[$rt]"
  if ! command -v "$rt" >/dev/null 2>&1; then
    if [ "$REQUIRE" = 1 ]; then bad "$rt: CLI not on PATH"; else skipped=$((skipped+1)); echo "  skip $rt: CLI not on PATH"; fi
    continue
  fi
  touch "$REF"; sleep 1
  out=""; rc=0; sid=""
  case "$rt" in
    claude)
      sid="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z' || python3 -c 'import uuid;print(uuid.uuid4())')"
      out="$(cd "$HQ_ROOT" && CLAUDE_HEADLESS=1 run_with_timeout "$TIMEOUT" claude -p "$PROMPT" --session-id "$sid" --output-format text 2>/dev/null)" || rc=$? ;;
    codex)
      # HQ_LIVE_SMOKE_CODEX_MODEL overrides the configured model when the installed
      # CLI cannot run it (e.g. "requires a newer version of Codex").
      out="$(cd "$HQ_ROOT" && CLAUDE_HEADLESS=1 run_with_timeout "$TIMEOUT" codex exec ${HQ_LIVE_SMOKE_CODEX_MODEL:+-m "$HQ_LIVE_SMOKE_CODEX_MODEL"} --skip-git-repo-check --dangerously-bypass-hook-trust "$PROMPT" 2>"$FX_ERR" </dev/null)" || rc=$?
      [ "$rc" = 0 ] || out="$out $(grep -m1 -oE 'requires a newer version of Codex|unauthorized|model [^ ]+ not found' "$FX_ERR" 2>/dev/null)" ;;
    grok)
      out="$(cd "$HQ_ROOT" && CLAUDE_HEADLESS=1 run_with_timeout "$TIMEOUT" grok -p "$PROMPT" 2>/dev/null)" || rc=$? ;;
  esac
  if [ "$rc" = 0 ] && grep -q 'HQ-SMOKE-OK' <<<"$out"; then ok "$rt: turn completed and echoed the sentinel"; else bad "$rt: turn failed (rc=$rc) or sentinel missing: $(printf '%s' "$out" | tail -c 200 | tr '\n' ' ')"; fi
  check_common "$rt" "$sid"
  if [ "$rt" = claude ] && [ -n "$sid" ]; then
    persisted="$(find "$HOME/.claude/projects" -path "*/$sid/tool-results/hook-*.txt" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$persisted" = 0 ]; then ok "claude: no hook output was persisted/truncated by the host for this session"; else bad "claude: $persisted hook output(s) were persisted by the host (over ~10 KB) — the model saw a 2 KB preview"; fi
  fi
done
rm -f "$REF" "$FX_ERR"

if [ "$FLEET" = 1 ]; then
  echo "[fleet]"
  cat <<'TXT'
  Fleet (agents-v2 / hermes) boxes run the SAME .claude hooks through the on-box
  adapter, but only during a live turn, so they cannot be smoked from a laptop:
    1. pick a canary box (hq-pro: `hq agents list`), deploy this release to it
    2. drive one live turn (Slack mention or `hq dm`), then on the box:
         bash core/scripts/check-hq-hooks.sh --require-ledger --session-id <sid>
       expect: HQ runtime enforcement: OBSERVED
    3. confirm workspace/orchestrator/policy-emit-stats/<sid>.txt max bytes < 8000
  (hook-health-check.test.sh cases [18]/[19] cover the attestation logic offline.)
TXT
  if [ "${HQ_FLEET_LEDGER_CHECK:-0}" = 1 ]; then bash "$HQ_ROOT/core/scripts/check-hq-hooks.sh" --require-ledger && ok "fleet: ledger observed on this box" || bad "fleet: ledger not observed"; fi
fi

echo "harness-live-smoke: $pass passed, $fail failed, $skipped skipped"
[ "$fail" = 0 ]
