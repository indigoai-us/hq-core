#!/bin/bash
# block-on-active-run.sh — PreToolUse hook (hard enforcement)
#
# Blocks Edit / Write / NotebookEdit / dangerous Bash patterns when the
# target path is inside a repo currently owned by another Claude session
# running /run-project or /execute-task.
#
# Self-match: the hook walks its own $PPID ancestry. Because run-project.sh
# and this hook are spawned as siblings under the Claude Code parent, the
# Claude Code PID appears in both ancestor chains. The /run-project script
# registers using that shared ancestor PID so this hook can recognize its
# own session's registration and let it through.
#
# Bypass: export HQ_IGNORE_ACTIVE_RUNS=1
#
# Exit codes: 0 = allow, 2 = block

set -euo pipefail

# ---- stdin first (hooks must always drain stdin) ----
INPUT=$(cat 2>/dev/null || echo "{}")

# ---- bypass ----
if [[ "${HQ_IGNORE_ACTIVE_RUNS:-}" == "1" ]]; then
  exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")

HQ_ROOT="${HQ_ROOT:-${HOME}/Documents/HQ}"
REG="$HQ_ROOT/scripts/repo-run-registry.sh"
[[ ! -x "$REG" ]] && exit 0

# ---- ancestor pid chain (for self-match) ----
_ancestor_pids() {
  local pid=$$
  local chain=""
  local max=20
  while [[ -n "$pid" && "$pid" != "1" && $max -gt 0 ]]; do
    chain="$chain $pid"
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' \n' || echo "")
    [[ -z "$pid" ]] && break
    max=$((max - 1))
  done
  echo "$chain"
}
ANCESTORS=$(_ancestor_pids)

# ---- determine which targets to check based on tool ----
TARGETS=()
case "$TOOL_NAME" in
  Edit|Write|NotebookEdit|MultiEdit)
    fp=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
    [[ -n "$fp" ]] && TARGETS+=("$fp")
    ;;
  Bash)
    cmd=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    # Denylist of destructive bash patterns. Read-only commands pass through.
    if echo "$cmd" | grep -qE '(\brm[[:space:]]|\brm$|\bgit[[:space:]]+(reset[[:space:]]+--hard|clean[[:space:]]+-|checkout[[:space:]]+--|rebase([[:space:]]|$)|merge([[:space:]]|$)|push([[:space:]]|$)|commit([[:space:]]|$)|apply([[:space:]]|$))|\bsed[[:space:]]+-i|\bawk[[:space:]]+-i|\bmv[[:space:]]|\btee[[:space:]]|[^&>|]>[[:space:]]*[^&]|>>[[:space:]])'; then
      # Use cwd as the target — shell commands run in the cwd.
      TARGETS+=("$(pwd)")
    else
      exit 0
    fi
    ;;
  *)
    exit 0
    ;;
esac

[[ ${#TARGETS[@]} -eq 0 ]] && exit 0

# ---- check each target for foreign ownership ----
BLOCKER_LINES=""
SEEN_RUN_IDS=""
for target in "${TARGETS[@]}"; do
  owners=$("$REG" owner-of --path "$target" 2>/dev/null || echo "[]")
  [[ -z "$owners" || "$owners" == "[]" || "$owners" == "null" ]] && continue

  n=$(echo "$owners" | jq 'length' 2>/dev/null || echo 0)
  [[ "$n" -eq 0 ]] && continue

  for i in $(seq 0 $((n - 1))); do
    entry=$(echo "$owners" | jq -c ".[$i]" 2>/dev/null)
    epid=$(echo "$entry" | jq -r '.pid' 2>/dev/null)
    esid=$(echo "$entry" | jq -r '.session_id // empty' 2>/dev/null)
    erid=$(echo "$entry" | jq -r '.run_id' 2>/dev/null)

    # Dedupe if the same run_id covers multiple targets
    case " $SEEN_RUN_IDS " in *" $erid "*) continue ;; esac

    # Self check 1: entry PID appears in our ancestor chain
    is_self=0
    for p in $ANCESTORS; do
      if [[ "$p" == "$epid" ]]; then is_self=1; break; fi
    done

    # Self check 2: session id match
    if [[ -n "$SESSION_ID" && -n "$esid" && "$esid" == "$SESSION_ID" ]]; then
      is_self=1
    fi

    if [[ $is_self -eq 0 ]]; then
      ecmd=$(echo "$entry" | jq -r '.command')
      eproj=$(echo "$entry" | jq -r '.project')
      escope=$(echo "$entry" | jq -r '.scope')
      estart=$(echo "$entry" | jq -r '.started_at')
      BLOCKER_LINES="${BLOCKER_LINES}  run_id=${erid} pid=${epid} command=${ecmd} project=${eproj} scope=${escope} started=${estart}"$'\n'
      SEEN_RUN_IDS="$SEEN_RUN_IDS $erid"
    fi
  done
done

if [[ -n "$BLOCKER_LINES" ]]; then
  cat >&2 <<BLOCK_EOF
BLOCKED: Cannot $TOOL_NAME — this repo is owned by another Claude session.
  Tool: $TOOL_NAME
  Target(s): ${TARGETS[*]}

Active run(s):
$BLOCKER_LINES
Options:
  1. Branch into a git worktree and work there (not owned):
       git -C <repo> worktree add ../<repo>-wt-<branch> <branch>
     Then cd ../<repo>-wt-<branch> and continue.
  2. Wait for the owning session to finish. Stale owners auto-clear after
     heartbeat timeout or when the owning PID dies.
  3. Emergency bypass (logged to workspace/learnings/active-run-bypasses.jsonl):
       HQ_IGNORE_ACTIVE_RUNS=1  (as env var on the command)

Policy:   .claude/policies/repo-run-coordination.md
Registry: workspace/orchestrator/active-runs.json
BLOCK_EOF
  exit 2
fi

exit 0
