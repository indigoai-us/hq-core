#!/bin/bash
# PreCompact hook: detect autocompact thrashing and warn loudly.
#
# Autocompact fires when transcript size crosses CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
# (default 75% in hq-core-staging). If the model immediately re-fills the freed
# window with more megabyte-scale tool output (e.g. Paper get_jsx, large MCP
# reads, broad multi-file reads), the next compaction fires again — and the
# Claude API's autocompact-thrashing guard kills the session after 3 consecutive
# thrashes within ~3 turns.
#
# This hook tracks per-session compaction history. On each fire:
#   - First or sparse compaction → quiet pass-through (companion hook
#     auto-checkpoint-precompact.sh prints its own advisory banner).
#   - >=3 compactions in the last ~6 minutes (a proxy for "within a few turns")
#     AND post-compaction byte size did NOT drop meaningfully → print a louder
#     banner recommending /handoff and warning the next large tool call will
#     re-trigger compaction.
#
# Non-blocking by design — Claude Code does not allow blocking autocompact.
# This is purely advisory: the goal is to tell the model/user to take a
# different path (delegate to a sub-agent, /handoff, /clear) instead of
# retrying the same heavy read that caused the spiral.
#
# State: workspace/.compact-history/{session_id}.jsonl
#   One line per compaction: {"ts": <epoch>, "bytes": <transcript_bytes>}

set -uo pipefail

HQ="${HOME}/Documents/HQ"
STATE_DIR="$HQ/workspace/.compact-history"

# Always succeed — PreCompact hooks must never bubble errors that distract
# from the compaction itself.
{
  INPUT="$(cat 2>/dev/null || echo '{}')"

  TRANSCRIPT_PATH="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
  SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"

  if [ -z "$SESSION_ID" ]; then
    exit 0
  fi

  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
  HISTORY_FILE="$STATE_DIR/$SESSION_ID.jsonl"

  NOW="$(date +%s)"
  BYTES=0
  if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
    BYTES="$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ' || echo 0)"
  fi

  # Append this compaction event.
  printf '{"ts":%s,"bytes":%s}\n' "$NOW" "$BYTES" >> "$HISTORY_FILE" 2>/dev/null || true

  # Test override: HQ_TEST_FORCE_PRECOMPACT_WINDOW lets fixtures override the window.
  WINDOW_SECS="${HQ_TEST_FORCE_PRECOMPACT_WINDOW:-360}"   # 6 minutes
  COUNT_THRESHOLD="${HQ_TEST_FORCE_PRECOMPACT_THRESHOLD:-3}"

  # Count compactions within the window (this one included).
  CUTOFF=$(( NOW - WINDOW_SECS ))
  RECENT_COUNT="$(awk -v cutoff="$CUTOFF" '
    {
      # Extract ts via simple regex; avoids requiring jq for the hot path.
      if (match($0, /"ts":[0-9]+/)) {
        s = substr($0, RSTART+5, RLENGTH-5)
        if (s+0 >= cutoff) c++
      }
    }
    END { print c+0 }
  ' "$HISTORY_FILE" 2>/dev/null || echo 1)"

  # Compute byte trajectory across recent compactions: are sizes staying high?
  # If the last two recorded byte counts are both within 25% of each other,
  # compaction isn't winning — same payload class is refilling immediately.
  STAGNANT=0
  LAST_TWO_BYTES="$(awk '
    {
      if (match($0, /"bytes":[0-9]+/)) {
        s = substr($0, RSTART+8, RLENGTH-8)
        prev2 = prev1; prev1 = s+0
      }
    }
    END { if (prev2 > 0) printf "%d %d\n", prev2, prev1 }
  ' "$HISTORY_FILE" 2>/dev/null || echo "")"

  # Absolute floor — only consider "stagnant" if the current transcript is
  # still LARGE. After a healthy compaction the bytes drop a lot, and small
  # relative deltas between two small files (e.g. 200k→250k) shouldn't trip
  # the alarm. Pick a floor tied to the configured autocompact threshold.
  CONTEXT_WINDOW="${CLAUDE_CONTEXT_WINDOW:-1000000}"
  AUTOCOMPACT_PCT="${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-75}"
  # Bytes-vs-tokens heuristic: ~3.5 chars/token. Floor = 40% of the autocompact
  # byte equivalent — "still uncomfortably full right after compacting."
  FLOOR_BYTES="${HQ_TEST_FORCE_PRECOMPACT_FLOOR:-$(( CONTEXT_WINDOW * AUTOCOMPACT_PCT * 35 / 1000 * 2 / 5 ))}"

  if [ -n "$LAST_TWO_BYTES" ]; then
    PREV="$(echo "$LAST_TWO_BYTES" | awk '{print $1}')"
    CURR="$(echo "$LAST_TWO_BYTES" | awk '{print $2}')"
    if [ "$PREV" -gt 0 ] && [ "$CURR" -ge "$FLOOR_BYTES" ]; then
      # |curr - prev| <= prev / 4  =>  stagnant
      DIFF=$(( CURR > PREV ? CURR - PREV : PREV - CURR ))
      QUARTER=$(( PREV / 4 ))
      if [ "$DIFF" -le "$QUARTER" ]; then
        STAGNANT=1
      fi
    fi
  fi

  # Fire the loud banner only if both signals agree.
  if [ "$RECENT_COUNT" -ge "$COUNT_THRESHOLD" ] && [ "$STAGNANT" -eq 1 ]; then
    cat <<'BANNER_EOF'
╔══════════════════════════════════════════════════════════════════════╗
║  ⚠  AUTOCOMPACT THRASHING DETECTED                                   ║
╠══════════════════════════════════════════════════════════════════════╣
║  Context has refilled at least twice within a few turns of           ║
║  compaction, and the freed space is NOT staying free.                ║
║                                                                      ║
║  The next large tool call (Paper get_jsx, multi-file Read, broad     ║
║  Grep, deep MCP query) will likely re-trigger compaction and may     ║
║  crash the session via the Claude API thrashing guard.               ║
║                                                                      ║
║  STRONGLY recommended — do NOT retry the same heavy read:            ║
║    • /handoff  — wrap this session and resume fresh                  ║
║    • /clear    — start a new conversation in this terminal           ║
║    • Delegate  — spawn an Explore sub-agent and return text only     ║
║                                                                      ║
║  See: core/policies/paper-mcp-context-isolation.md for the           ║
║  delegation pattern.                                                 ║
╚══════════════════════════════════════════════════════════════════════╝
BANNER_EOF
  fi
} 2>/dev/null || true

exit 0
