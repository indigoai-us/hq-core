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

# Resolve the active HQ root regardless of install path or session cwd:
# explicit HQ_ROOT env → CLAUDE_PROJECT_DIR (set by Claude Code) → the hook's
# own location (always <HQ>/.claude/hooks/, matching master-hook.sh) → legacy
# default. Never hardcode ~/Documents/HQ as the sole source.
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)}}"
HQ_ROOT="${HQ_ROOT:-${HOME}/Documents/HQ}"
. "$HQ_ROOT/core/scripts/hook-lib.sh" 2>/dev/null || true
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
    # Inspect actual simple-command executables, not quoted argument text.
    # This keeps grep patterns and checkpoint summaries from impersonating a
    # destructive operation while retaining all real write classifications.
    bash_write=0
    while IFS= read -r shell_record; do
      [ -n "$shell_record" ] || continue
      shell_exe="$(hq_shell_command_executable "$shell_record" 2>/dev/null || true)"
      shell_text="${shell_record//$'\037'/ }"
      case "$shell_exe" in
        rm|rmdir|mv|tee|dd|rsync|mkdir|touch|chmod|chown|chgrp|ln)
          bash_write=1
          ;;
        sed)
          echo "$shell_text" | grep -Eq '(^|[[:space:]])(-i|--in-place)([[:space:]]|$)' && bash_write=1
          ;;
        awk)
          echo "$shell_text" | grep -Eq '(^|[[:space:]])-i[[:space:]]+inplace([[:space:]]|$)' && bash_write=1
          ;;
        git)
          git_sub="$(printf '%s' "$shell_text" | awk '{for(i=2;i<=NF;i++){if($i=="-C"||$i=="-c"||$i=="--git-dir"||$i=="--work-tree"){i++;continue} if($i !~ /^-/){print $i; exit}}}')"
          case "$git_sub" in
            reset|checkout|restore|clean|rebase|merge|push|commit|apply|add|rm|mv|switch|cherry-pick|revert|am|fetch|pull|clone)
              bash_write=1
              ;;
          esac
          ;;
      esac
      if [ "$bash_write" -eq 1 ]; then
        # The registry is repo-root scoped. `git -C` changes Git's target,
        # whereas shell write tools name their own targets. Preserve those
        # targets so `rm -rf repos/private/x` is checked against that repo,
        # not merely the caller's ambient cwd.
        git_cwd="$(printf '%s' "$shell_text" | sed -nE 's/.*[[:space:]]-C[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)"
        if [ "$shell_exe" = "git" ]; then
          TARGETS+=("${git_cwd:-$(pwd)}")
        else
          IFS=$'\037' read -r -a shell_argv <<< "$shell_record"
          write_args=()
          case "$shell_exe" in
            mv)
              for ((j=1; j<${#shell_argv[@]}; j++)); do
                [[ "${shell_argv[$j]}" == -* ]] || write_args+=("${shell_argv[$j]}")
              done
              [ "${#write_args[@]}" -gt 0 ] && TARGETS+=("${write_args[$((${#write_args[@]}-1))]}")
              ;;
            chmod|chown|chgrp)
              seen_mode=0
              for ((j=1; j<${#shell_argv[@]}; j++)); do
                [[ "${shell_argv[$j]}" == -* ]] && continue
                if [ "$seen_mode" -eq 0 ]; then seen_mode=1; continue; fi
                TARGETS+=("${shell_argv[$j]}")
              done
              ;;
            sed|awk)
              # The final non-option argument is the in-place target.
              for ((j=1; j<${#shell_argv[@]}; j++)); do
                [[ "${shell_argv[$j]}" == -* ]] || write_args+=("${shell_argv[$j]}")
              done
              [ "${#write_args[@]}" -gt 1 ] && TARGETS+=("${write_args[$((${#write_args[@]}-1))]}")
              ;;
            *)
              for ((j=1; j<${#shell_argv[@]}; j++)); do
                [[ "${shell_argv[$j]}" == -* ]] && continue
                TARGETS+=("${shell_argv[$j]}")
              done
              ;;
          esac
          [ "${#TARGETS[@]}" -gt 0 ] || TARGETS+=("$(pwd)")
        fi
        break
      fi
    done < <(hq_shell_simple_commands "$cmd")
    [ "$bash_write" -eq 1 ] || exit 0
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
       bash core/scripts/worktree.sh --name <kebab-slug> --source <repo>
     It creates workspace/worktrees/<repo>/<name>/ and prints the path — cd
     there and continue. Worktrees must live under workspace/worktrees/; the
     Edit/Write guard blocks every path under repos/, including a worktree
     created there.
  2. Wait for the owning session to finish. Stale owners auto-clear after
     heartbeat timeout or when the owning PID dies.
  3. Emergency bypass (logged to workspace/learnings/active-run-bypasses.jsonl):
       HQ_IGNORE_ACTIVE_RUNS=1  (as env var on the command)

Policy:   core/policies/repo-run-coordination.md
Registry: workspace/orchestrator/active-runs.json
BLOCK_EOF
  exit 2
fi

exit 0
