#!/usr/bin/env bash
# hq-core: public
# session-timing.sh — pre-dispatch assembly phase timing (US-411).
#
# Records monotonic elapsed-ms per phase, reports assemblyMs on the response
# envelope, and flags assemblyBudgetExceeded when total exceeds
# HQ_SESSION_ASSEMBLY_BUDGET_MS (default 20000). Exceeding the budget never
# aborts the turn — report-and-continue only.
#
# Phases (fixed keys): system-prompt, hooks, policy, rehydrate,
# skill-catalog, worker-catalog.
#
# Test hooks:
#   HQ_SESSION_TIMING_STUB_PHASE   — phase name to inflate
#   HQ_SESSION_TIMING_STUB_SLEEP_MS — sleep that many ms inside the stub phase
#   HQ_SESSION_TIMING_STUB_ADD_MS   — add this many ms to the stub phase (no sleep)

# shellcheck shell=bash

HQ_SESSION_ASSEMBLY_BUDGET_MS="${HQ_SESSION_ASSEMBLY_BUDGET_MS:-20000}"

# Ordered phase names (assemblyMs keys minus total).
SESSION_TIMING_PHASE_NAMES=(
  system-prompt
  hooks
  policy
  rehydrate
  skill-catalog
  worker-catalog
)

# Elapsed ms per phase (parallel array; bash 3.2 safe).
SESSION_TIMING_PHASE_MS=()
SESSION_TIMING_CURRENT_PHASE=""
SESSION_TIMING_CURRENT_START_MS=""
SESSION_TIMING_TOTAL_MS=0
SESSION_ASSEMBLY_BUDGET_EXCEEDED=0
SESSION_ASSEMBLY_MS_JSON="{}"
SESSION_TIMING_BUDGET_REPORTED=0

# session_timing_now_ms
#   Monotonic-ish wall clock in milliseconds. Prefers python3, then perl,
#   then second-resolution date fallback.
session_timing_now_ms() {
  local ms
  ms="$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null)" || ms=""
  case "$ms" in
    ''|*[!0-9]*) ;;
    *) printf '%s' "$ms"; return 0 ;;
  esac
  ms="$(perl -MTime::HiRes=time -e 'printf \"%d\", time()*1000' 2>/dev/null)" || ms=""
  case "$ms" in
    ''|*[!0-9]*) ;;
    *) printf '%s' "$ms"; return 0 ;;
  esac
  # Second resolution only — adequate when python/perl unavailable.
  ms="$(date +%s 2>/dev/null || echo 0)"
  case "$ms" in
    ''|*[!0-9]*) ms=0 ;;
  esac
  printf '%s' "$((ms * 1000))"
}

# session_timing_init
#   Zero all phase counters and flags for a new turn.
session_timing_init() {
  local i n
  n="${#SESSION_TIMING_PHASE_NAMES[@]}"
  SESSION_TIMING_PHASE_MS=()
  i=0
  while [ "$i" -lt "$n" ]; do
    SESSION_TIMING_PHASE_MS+=("0")
    i=$((i + 1))
  done
  SESSION_TIMING_CURRENT_PHASE=""
  SESSION_TIMING_CURRENT_START_MS=""
  SESSION_TIMING_TOTAL_MS=0
  SESSION_ASSEMBLY_BUDGET_EXCEEDED=0
  SESSION_ASSEMBLY_MS_JSON="{}"
  SESSION_TIMING_BUDGET_REPORTED=0
  case "${HQ_SESSION_ASSEMBLY_BUDGET_MS:-}" in
    ''|*[!0-9]*) HQ_SESSION_ASSEMBLY_BUDGET_MS=20000 ;;
  esac
}

# session_timing_phase_index <name> -> prints index or returns 1
session_timing_phase_index() {
  local name="${1:-}" i=0
  for p in "${SESSION_TIMING_PHASE_NAMES[@]}"; do
    if [ "$p" = "$name" ]; then
      printf '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# session_timing_begin <phase>
session_timing_begin() {
  local phase="${1:-}"
  SESSION_TIMING_CURRENT_PHASE="$phase"
  SESSION_TIMING_CURRENT_START_MS="$(session_timing_now_ms)"
  # Optional deliberate slowdown for budget tests.
  if [ -n "${HQ_SESSION_TIMING_STUB_PHASE:-}" ] \
    && [ "$phase" = "${HQ_SESSION_TIMING_STUB_PHASE}" ]; then
    local sleep_ms="${HQ_SESSION_TIMING_STUB_SLEEP_MS:-0}"
    case "$sleep_ms" in
      ''|*[!0-9]*) sleep_ms=0 ;;
    esac
    if [ "$sleep_ms" -gt 0 ]; then
      # Prefer python sleep for sub-second precision; fall back to sleep 1.
      python3 -c "import time; time.sleep(${sleep_ms}/1000.0)" 2>/dev/null \
        || sleep 1
    fi
  fi
}

# session_timing_end
#   Close the open phase and accumulate elapsed ms.
session_timing_end() {
  local phase start now elapsed idx add_ms
  phase="${SESSION_TIMING_CURRENT_PHASE:-}"
  start="${SESSION_TIMING_CURRENT_START_MS:-}"
  SESSION_TIMING_CURRENT_PHASE=""
  SESSION_TIMING_CURRENT_START_MS=""
  [ -n "$phase" ] || return 0
  case "$start" in
    ''|*[!0-9]*) start=0 ;;
  esac
  now="$(session_timing_now_ms)"
  case "$now" in
    ''|*[!0-9]*) now=0 ;;
  esac
  elapsed=$((now - start))
  if [ "$elapsed" -lt 0 ]; then
    elapsed=0
  fi
  # Synthetic add for tests (avoids real sleep).
  if [ -n "${HQ_SESSION_TIMING_STUB_PHASE:-}" ] \
    && [ "$phase" = "${HQ_SESSION_TIMING_STUB_PHASE}" ]; then
    add_ms="${HQ_SESSION_TIMING_STUB_ADD_MS:-0}"
    case "$add_ms" in
      ''|*[!0-9]*) add_ms=0 ;;
    esac
    elapsed=$((elapsed + add_ms))
  fi
  idx="$(session_timing_phase_index "$phase" 2>/dev/null || true)"
  case "$idx" in
    ''|*[!0-9]*) return 0 ;;
  esac
  SESSION_TIMING_PHASE_MS[$idx]="$elapsed"
}

# session_timing_get <phase> -> ms
session_timing_get() {
  local phase="${1:-}" idx
  idx="$(session_timing_phase_index "$phase" 2>/dev/null || true)"
  case "$idx" in
    ''|*[!0-9]*) printf '0'; return 0 ;;
  esac
  printf '%s' "${SESSION_TIMING_PHASE_MS[$idx]:-0}"
}

# session_timing_finalize
#   Sum phases into total, evaluate budget, build assemblyMs JSON, emit stderr
#   once when over budget.
session_timing_finalize() {
  local i n sum=0 name ms budget
  n="${#SESSION_TIMING_PHASE_NAMES[@]}"
  i=0
  while [ "$i" -lt "$n" ]; do
    ms="${SESSION_TIMING_PHASE_MS[$i]:-0}"
    case "$ms" in
      ''|*[!0-9]*) ms=0 ;;
    esac
    sum=$((sum + ms))
    i=$((i + 1))
  done
  SESSION_TIMING_TOTAL_MS="$sum"

  budget="${HQ_SESSION_ASSEMBLY_BUDGET_MS:-20000}"
  case "$budget" in
    ''|*[!0-9]*) budget=20000 ;;
  esac
  if [ "$sum" -gt "$budget" ]; then
    SESSION_ASSEMBLY_BUDGET_EXCEEDED=1
    if [ "${SESSION_TIMING_BUDGET_REPORTED:-0}" != "1" ]; then
      SESSION_TIMING_BUDGET_REPORTED=1
      i=0
      while [ "$i" -lt "$n" ]; do
        name="${SESSION_TIMING_PHASE_NAMES[$i]}"
        ms="${SESSION_TIMING_PHASE_MS[$i]:-0}"
        echo "hq-agent-session: assembly phase ${name}=${ms}ms (budget ${budget}ms exceeded)" >&2
        i=$((i + 1))
      done
    fi
  else
    SESSION_ASSEMBLY_BUDGET_EXCEEDED=0
  fi

  # Hand-rolled JSON (phase names are fixed/safe integers only).
  SESSION_ASSEMBLY_MS_JSON="$(printf \
    '{"system-prompt":%s,"hooks":%s,"policy":%s,"rehydrate":%s,"skill-catalog":%s,"worker-catalog":%s,"total":%s}' \
    "$(session_timing_get system-prompt)" \
    "$(session_timing_get hooks)" \
    "$(session_timing_get policy)" \
    "$(session_timing_get rehydrate)" \
    "$(session_timing_get skill-catalog)" \
    "$(session_timing_get worker-catalog)" \
    "$sum")"
}

# session_timing_phase_sum
#   Sum of the six phase values (excludes total key).
session_timing_phase_sum() {
  local i n sum=0 ms
  n="${#SESSION_TIMING_PHASE_NAMES[@]}"
  i=0
  while [ "$i" -lt "$n" ]; do
    ms="${SESSION_TIMING_PHASE_MS[$i]:-0}"
    case "$ms" in ''|*[!0-9]*) ms=0 ;; esac
    sum=$((sum + ms))
    i=$((i + 1))
  done
  printf '%s' "$sum"
}
