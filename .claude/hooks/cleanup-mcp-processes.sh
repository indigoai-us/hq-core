#!/bin/bash
# Session Cleanup Hook: at session exit, stop leaked MCP helper processes that
# THIS session started.
#
# Problem: Claude Code spawns MCP servers as stdio child processes (via npx/tsx).
# When a session ends or crashes, the Node.js grandchildren are not always
# killed, because tsx/npx do not forward SIGHUP. Over many sessions this leaks
# node processes of 200 MB+ each.
#
# SAFETY CONTRACT. Read before changing anything here.
#
# HQ runs a shared multi-agent fleet: Agency workers, other sessions under the
# same desktop app or terminal, other operators' Claude and Codex sessions and
# their workflow runners all live on the same box. Rules:
#
#   1. Event. Registered for SessionEnd, not Stop. Stop fires at the end of
#      every assistant turn, so a Stop registration reaped the live session's
#      own helpers mid-session (feedback_1f67ad54). Only the exit reasons
#      logout, prompt_input_exit and other clean up. "clear" keeps the same
#      process and its helpers running, so it is skipped; a missing or unknown
#      reason is treated as not-an-exit (fail closed).
#   2. Ownership. The owner is the NEAREST ancestor whose executable basename
#      is a session host (claude or codex). Matching any ancestor, up to the
#      desktop app or terminal, made every sibling session's helpers "ours".
#      The hook signals nothing when no owner is found, when the owner runs in
#      server mode (app-server, exec-server, mcp-server: one process serves
#      several sessions), or when another host process sits below the owner
#      off this hook's own chain (the owner is shared).
#   3. Agent workloads are never killed. A candidate whose chain up to the
#      owner passes through a workflow runner, codex exec, an agency worker or
#      a nested host is left alone.
#   4. Identity. Each candidate's start time and full command line come from
#      the same process-table row used to select it and judge its ownership.
#      TERM and KILL are each sent only after re-checking that identity, so a
#      recycled or re-exec'd PID is not signalled. A race remains between the
#      check and the signal.
#   5. Patterns are anchored to the executable or script path, so a worker
#      whose prompt merely names "agent-browser" is not mistaken for it.
#   6. Every run reports what it signalled and skipped.
#
# Do not reintroduce a bare `pgrep -f`/`pkill -f` sweep here. See policy
# `no-machine-wide-process-pattern-kills` (core/policies/mcp-process-cleanup.md)
# and the 2026-07-28 incident.
#
# Test seams (tests only): HQ_CLEANUP_HOST_NAMES (space-separated executable
# basenames that count as a session host; default "claude codex"),
# HQ_CLEANUP_GRACE_SECONDS (TERM to KILL wait; default 1), HQ_CLEANUP_TMP_DIR
# (temp sweep directory), HQ_CLEANUP_TEST_PAUSE_SECONDS and
# HQ_CLEANUP_TEST_COLLECTED_FILE (hold between collection and signalling).
# Regression: core/scripts/tests/cleanup-mcp-session-scope.test.sh
#
# Design and the original replacement script: reported and reviewed by the
# feedback_1f67ad54 reporter.

set -uo pipefail

PAYLOAD="$(cat 2>/dev/null || true)"

HOST_NAMES=" ${HQ_CLEANUP_HOST_NAMES:-claude codex} "
GRACE="${HQ_CLEANUP_GRACE_SECONDS:-1}"
case "$GRACE" in ''|*[!0-9]*) GRACE=1 ;; esac
TMP_SWEEP_DIR="${HQ_CLEANUP_TMP_DIR:-/tmp}"

say() { printf 'cleanup-mcp-processes: %s\n' "$*" >&2; }

# --- Temp sweep ----------------------------------------------------------------
# /tmp/hq-checkpoint-last-<pid> and hq-screenshot-count-<pid>: remove only files
# older than 60 minutes whose <pid> is no longer running. The previous sweep
# removed every such file older than 60 minutes regardless of owner.
sweep_tmp() {
  local f suffix
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    suffix="${f##*-}"
    case "$suffix" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$suffix" 2>/dev/null && continue
    ps -p "$suffix" >/dev/null 2>&1 && continue
    rm -f -- "$f" 2>/dev/null || true
  done < <(find "$TMP_SWEEP_DIR" -maxdepth 1 \( -name 'hq-checkpoint-last-*' -o -name 'hq-screenshot-count-*' \) -mmin +60 2>/dev/null)
}

# --- Only exit reasons clean up ------------------------------------------------
REASON_IN="$(printf '%s' "$PAYLOAD" | jq -r '.reason // empty' 2>/dev/null || true)"
case "$REASON_IN" in
  logout|prompt_input_exit|other) ;;
  *)
    say "reason=${REASON_IN:-none}; not a session exit, no processes signalled"
    sweep_tmp
    exit 0
    ;;
esac

# --- One pass over the process table -------------------------------------------
TREE_FILE="$(mktemp "${TMPDIR:-/tmp}/hqcleanup-tree.XXXXXX")" || exit 0
ARGS_FILE="$(mktemp "${TMPDIR:-/tmp}/hqcleanup-args.XXXXXX")" || { rm -f "$TREE_FILE"; exit 0; }
trap 'rm -f "$TREE_FILE" "$ARGS_FILE"' EXIT
# comm gives the executable (full path on macOS, name on Linux) for host
# detection. The second snapshot carries ppid, start time and args together:
# candidates are selected, owned and baselined from that one row, so the
# identity compared before each signal is the identity that was classified.
ps -A -o pid=,ppid=,comm= >"$TREE_FILE" 2>/dev/null
ps -A -o pid=,ppid=,lstart=,args= >"$ARGS_FILE" 2>/dev/null

PLAN="$(awk -v self="$$" -v hosts="$HOST_NAMES" '
  function is_host(x,   c, b) {
    c = comm[x]
    if (c == "") return 0
    b = c; sub(/.*\//, "", b)
    return index(hosts, " " b " ") > 0
  }
  function descends(x, o,   g) {
    g = 0
    while (x > 1 && g < 64) { if (x == o) return 1; x = pp[x]; g++ }
    return 0
  }
  function protected_chain(x, o,   g) {
    g = 0
    while (x > 1 && x != o && g < 64) {
      if (args[x] ~ prot) return 1
      if (is_host(x)) return 1
      x = pp[x]; g++
    }
    return 0
  }
  BEGIN {
    pat[1] = "(^|[[:space:]][^[:space:]]*/)slack-mcp/src/server\\.ts([[:space:]]|$)"
    pat[2] = "(^|[[:space:]][^[:space:]]*/)advanced-gmail-mcp/src/server\\.ts([[:space:]]|$)"
    pat[3] = "(^|[[:space:]][^[:space:]]*/)agent-browser([[:space:]]|$)"
    pat[4] = "(^|[[:space:]][^[:space:]]*/)detached-flush\\.js([[:space:]]|$)"
    prot = "codex exec|codex-workflow\\.mjs|ultracode-workflow\\.mjs|workflow-runner\\.mjs|codex-code-mode-host|agency-worker|agency-spawn-guardian|(^|/)claude( |$)|(^|/)codex( |$)|(^|/)grok( |$)"
  }
  FNR == NR {
    p = $1; pp[p] = $2
    c = $0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]*/, "", c); comm[p] = c
    next
  }
  {
    # pid ppid lstart(5 fields) args...; this ppid overrides the tree snapshot
    # so ownership is judged from the same row as the identity.
    p = $1; pp[p] = $2
    lst = $3 " " $4 " " $5 " " $6 " " $7
    a = ""
    for (k = 8; k <= NF; k++) a = (a == "" ? $k : a " " $k)
    args[p] = a
    ident[p] = lst " " a
  }
  END {
    own = " "; owner = ""; x = self; g = 0
    while (x > 1 && g < 64) {
      if (x != self && is_host(x)) { owner = x; break }
      own = own x " "; x = pp[x]; g++
    }
    if (owner == "") { print "STOP owner not identified"; exit }
    if (args[owner] ~ /(^|[[:space:]])(app-server|exec-server|mcp-server)([[:space:]]|$)/) {
      print "STOP owner " owner " is a server-mode host that may serve several sessions"; exit
    }
    for (h in pp) {
      if (h == owner || index(own, " " h " ") > 0) continue
      if (is_host(h) && descends(h, owner)) { print "STOP owner " owner " is shared with another session host (" h ")"; exit }
    }
    print "OWNER " owner
    foreign = 0; protected = 0
    for (q in args) {
      if (q == self) continue
      m = 0
      for (i = 1; i <= 4; i++) if (args[q] ~ pat[i]) { m = 1; break }
      if (!m) continue
      if (!descends(q, owner)) { foreign++; continue }
      if (protected_chain(q, owner)) { protected++; continue }
      print "CAND " q " " ident[q]
    }
    print "COUNT " foreign " " protected
  }
' "$TREE_FILE" "$ARGS_FILE" 2>/dev/null)"

OWNER=""; STOP_REASON=""; FOREIGN=0; PROTECTED=0
CAND_PIDS=(); CAND_IDS=()
while read -r kind rest; do
  case "$kind" in
    STOP) STOP_REASON="$rest" ;;
    OWNER) OWNER="$rest" ;;
    CAND) CAND_PIDS+=("${rest%% *}"); CAND_IDS+=("${rest#* }") ;;
    COUNT) FOREIGN="${rest%% *}"; PROTECTED="${rest##* }" ;;
  esac
done <<EOF_PLAN
$PLAN
EOF_PLAN

# Same normalization as the snapshot: single spaces between fields.
identity_of() { ps -o lstart=,args= -p "$1" 2>/dev/null | awk '{ $1 = $1; print }'; }
still_same() { local now; now="$(identity_of "$1")"; [ -n "$now" ] && [ -n "$2" ] && [ "$now" = "$2" ]; }

case "${HQ_CLEANUP_TEST_PAUSE_SECONDS:-}" in
  ''|*[!0-9.]*) ;;
  *)
    [ -n "${HQ_CLEANUP_TEST_COLLECTED_FILE:-}" ] && : > "$HQ_CLEANUP_TEST_COLLECTED_FILE"
    sleep "$HQ_CLEANUP_TEST_PAUSE_SECONDS"
    ;;
esac

SIGNALLED=0; REUSED=0
SIG_PIDS=(); SIG_IDS=()
for i in ${CAND_PIDS[@]+"${!CAND_PIDS[@]}"}; do
  p="${CAND_PIDS[$i]}"
  if still_same "$p" "${CAND_IDS[$i]}"; then
    if kill -TERM "$p" 2>/dev/null; then SIG_PIDS+=("$p"); SIG_IDS+=("${CAND_IDS[$i]}"); fi
  else
    REUSED=$((REUSED + 1))
  fi
done
if [ "${#SIG_PIDS[@]}" -gt 0 ]; then
  sleep "$GRACE"
  for i in "${!SIG_PIDS[@]}"; do
    still_same "${SIG_PIDS[$i]}" "${SIG_IDS[$i]}" && kill -KILL "${SIG_PIDS[$i]}" 2>/dev/null
  done
  SIGNALLED="${#SIG_PIDS[@]}"
fi

say "reason=$REASON_IN owner=${OWNER:-none} signalled=$SIGNALLED foreign=$FOREIGN protected=$PROTECTED reused=$REUSED${STOP_REASON:+ ($STOP_REASON; no processes signalled)}"
sweep_tmp
exit 0
