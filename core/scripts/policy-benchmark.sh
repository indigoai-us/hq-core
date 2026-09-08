#!/usr/bin/env bash
# hq-core: public
# policy-benchmark.sh — measure whether the rules layer delivers (2026-09-07).
#
# Two modes. Both print a compact report; --json for machines.
#
# 1. LIVE — this install, last N days (default 7), from artefacts the host and
#    HQ already write:
#      truncated_hook_outputs   hook stdout files the host persisted (>~10 KB)
#                               under ~/.claude/projects/*/tool-results/
#      sessions                 policy-trigger ledgers touched in the window
#      fired_per_session        median distinct policies emitted per session
#      retrieved_per_session    median distinct policies pulled in full
#      retrieval_rate           retrieved / fired (the number index-mode has to move)
#    Usage: policy-benchmark.sh live [--days N] [--json]
#
# 2. SCENARIOS — run the loader against a scenario file in a scratch copy of a
#    policy corpus and score delivery, not behaviour:
#      recall     expected slugs present in the emission (index line or full text)
#      bytes      emission size per scenario (must stay under the host ceiling)
#      hard_full  expected HARD slugs that carried full text
#    Scenario file (JSON): [{"name":"…","event":"UserPromptSubmit","prompt":"…",
#      "expect":["slug",…], "expect_full":["hard-slug",…]}]
#    Usage: policy-benchmark.sh scenarios --file <scenarios.json> [--corpus <dir>]... [--json]
#    Default corpus: personal/policies + core/policies of HQ_ROOT.
#
# Behavioural compliance (did the agent OBEY a delivered rule) needs a live
# agent run per scenario and is out of scope here; this benchmark answers the
# prerequisite question — was the rule deliverable and delivered — and gives
# retirement its usage denominator.
set -uo pipefail
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
MODE="${1:-}"; shift || true
JSON=0; DAYS=7; FILE=""; CORPUS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --days) DAYS="$2"; shift 2 ;;
    --file) FILE="$2"; shift 2 ;;
    --corpus) CORPUS+=("$2"); shift 2 ;;
    *) echo "policy-benchmark: unknown arg $1" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "policy-benchmark: jq required" >&2; exit 2; }
median() { sort -n | awk '{a[NR]=$1} END { if (NR==0) print 0; else if (NR%2) print a[(NR+1)/2]; else print int((a[NR/2]+a[NR/2+1])/2) }'; }

case "$MODE" in
  live)
    since="$(( $(date +%s) - DAYS*86400 ))"
    # Portable "newer than <epoch>": a reference file (GNU touch -d, BSD touch -t).
    REF="$(mktemp)"; touch -d "@$since" "$REF" 2>/dev/null || touch -t "$(date -r "$since" +%Y%m%d%H%M.%S)" "$REF"
    # Claude Code persists oversize hook output under
    # ~/.claude/projects/<project>/<session>/tool-results/hook-*.txt (and, in
    # older layouts, one level up).
    TR="${HQ_HOST_TOOL_RESULTS_GLOB:-$HOME/.claude/projects/*/*/tool-results $HOME/.claude/projects/*/tool-results}"
    trunc=0; for d in $TR; do [ -d "$d" ] || continue; trunc=$((trunc + $(find "$d" -name 'hook-*.txt' -newer "$REF" 2>/dev/null | wc -l | tr -d ' '))); done
    LED="$HQ_ROOT/workspace/orchestrator/policy-trigger-state"; RET="$HQ_ROOT/workspace/orchestrator/policy-retrieval-state"
    sessions=0; fired_list=""; ret_list=""
    if [ -d "$LED" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue; sessions=$((sessions+1)); sid="$(basename "$f" .txt)"
        fired="$(grep -c . "$f" 2>/dev/null || echo 0)"; fired_list="$fired_list$fired
"
        r=0; [ -f "$RET/$sid.txt" ] && r="$(grep -c . "$RET/$sid.txt" 2>/dev/null || echo 0)"; ret_list="$ret_list$r
"
      done < <(find "$LED" -name '*.txt' -newer "$REF" 2>/dev/null)
    rm -f "$REF"
    fi
    fired_med="$(printf '%s' "$fired_list" | grep . | median)"; ret_med="$(printf '%s' "$ret_list" | grep . | median)"
    fired_sum="$(printf '%s' "$fired_list" | grep . | awk '{s+=$1} END{print s+0}')"; ret_sum="$(printf '%s' "$ret_list" | grep . | awk '{s+=$1} END{print s+0}')"
    rate="0"; [ "$fired_sum" -gt 0 ] && rate="$(awk -v a="$ret_sum" -v b="$fired_sum" 'BEGIN{printf "%.3f", a/b}')"
    if [ "$JSON" = 1 ]; then
      jq -cn --argjson d "$DAYS" --argjson t "$trunc" --argjson s "$sessions" --argjson fm "$fired_med" --argjson rm "$ret_med" --argjson r "$rate" \
        '{mode:"live", days:$d, truncated_hook_outputs:$t, sessions:$s, fired_per_session_median:$fm, retrieved_per_session_median:$rm, retrieval_rate:$r}'
    else
      echo "policy-benchmark live (last ${DAYS}d): truncated_hook_outputs=$trunc sessions=$sessions fired/session(median)=$fired_med retrieved/session(median)=$ret_med retrieval_rate=$rate"
    fi ;;
  scenarios)
    [ -n "$FILE" ] && [ -r "$FILE" ] || { echo "policy-benchmark scenarios: --file <scenarios.json> required" >&2; exit 2; }
    [ "${#CORPUS[@]}" -gt 0 ] || CORPUS=("$HQ_ROOT/personal/policies" "$HQ_ROOT/core/policies")
    HOOK="$HQ_ROOT/.claude/hooks/inject-policy-on-trigger.sh"; [ -r "$HOOK" ] || { echo "loader not found at $HOOK" >&2; exit 2; }
    FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
    mkdir -p "$FX/core/policies" "$FX/core/scripts" "$FX/.claude/hooks" "$FX/workspace/orchestrator/policy-trigger-state"
    for c in "${CORPUS[@]}"; do [ -d "$c" ] && cp "$c"/*.md "$FX/core/policies/" 2>/dev/null; done
    cp "$HOOK" "$FX/.claude/hooks/"; cp "$HQ_ROOT/core/scripts/hook-lib.sh" "$HQ_ROOT/core/scripts/derive-trigger-facts.sh" "$HQ_ROOT/core/scripts/eval-trigger.sh" "$FX/core/scripts/" 2>/dev/null
    n=0; total_recall_hit=0; total_recall_n=0; rows=""
    while IFS= read -r sc; do
      n=$((n+1))
      name="$(jq -r '.name // ("scenario-" + (env.n // "0"))' <<<"$sc")"; ev="$(jq -r '.event // "UserPromptSubmit"' <<<"$sc")"; prompt="$(jq -r '.prompt // ""' <<<"$sc")"
      input="$(jq -cn --arg sid "bench-$$-$n" --arg cwd "$FX" --arg p "$prompt" --arg e "$ev" '{session_id:$sid,hook_event_name:$e,cwd:$cwd,prompt:$p,tool_input:{command:$p}}')"
      out="$(env HQ_ROOT="$FX" CLAUDE_PROJECT_DIR="$FX" bash "$FX/.claude/hooks/inject-policy-on-trigger.sh" <<<"$input" 2>/dev/null || true)"
      bytes="$(printf '%s' "$out" | wc -c | tr -d ' ')"
      hit=0; miss=""; exp_n=0
      while IFS= read -r slug; do [ -n "$slug" ] || continue; exp_n=$((exp_n+1)); if grep -q "^> Policy \`$slug\`" <<<"$out"; then hit=$((hit+1)); else miss="${miss:+$miss,}$slug"; fi; done < <(jq -r '.expect[]?' <<<"$sc")
      full=0; full_n=0
      while IFS= read -r slug; do [ -n "$slug" ] || continue; full_n=$((full_n+1)); grep -q "^> Policy \`$slug\` (HARD — binding rule" <<<"$out" && full=$((full+1)); done < <(jq -r '.expect_full[]?' <<<"$sc")
      total_recall_hit=$((total_recall_hit+hit)); total_recall_n=$((total_recall_n+exp_n))
      rows="$rows$(jq -cn --arg name "$name" --argjson b "$bytes" --argjson h "$hit" --argjson e "$exp_n" --arg m "$miss" --argjson f "$full" --argjson fn "$full_n" '{scenario:$name, bytes:$b, expected:$e, delivered:$h, missing:(if $m=="" then [] else ($m|split(",")) end), hard_full:$f, hard_expected:$fn, under_ceiling:($b <= 8000)}')
"
    done < <(jq -c '.[]' "$FILE")
    recall="0"; [ "$total_recall_n" -gt 0 ] && recall="$(awk -v a="$total_recall_hit" -v b="$total_recall_n" 'BEGIN{printf "%.3f", a/b}')"
    if [ "$JSON" = 1 ]; then printf '%s' "$rows" | jq -s --argjson r "$recall" '{mode:"scenarios", recall:$r, scenarios:.}'
    else
      echo "policy-benchmark scenarios: $n scenarios, recall=$recall (expected slugs delivered)"
      printf '%s' "$rows" | jq -r '"  \(.scenario): \(.delivered)/\(.expected) delivered, \(.hard_full)/\(.hard_expected) hard in full, \(.bytes) bytes\(if .under_ceiling then "" else " OVER CEILING" end)\(if (.missing|length)>0 then " missing: " + (.missing|join(",")) else "" end)"'
    fi
    [ "$total_recall_hit" = "$total_recall_n" ] ;;
  *) sed -n 2,30p "$0"; exit 2 ;;
esac
