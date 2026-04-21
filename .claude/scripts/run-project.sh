#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# run-project.sh — Externalized Self-Healing Project Orchestrator
#
# Runs each story as an independent `claude -p` headless invocation.
# No context ceiling. Git validation after each story. Retry queue.
# Regression gates every N stories.
#
# Usage:
#   scripts/run-project.sh <project> [flags]
#   scripts/run-project.sh --status
#
# Flags:
#   --resume            Resume from next incomplete story (auto-detected)
#   --status            Show all project statuses, exit
#   --dry-run           Show story order without executing
#   --model MODEL       Override model for all stories
#   --no-permissions    Pass --dangerously-skip-permissions to claude
#   --retry-failed      Re-run previously failed stories only
#   --timeout N         Per-story wall-clock timeout in minutes (default: none)
#   --verbose           Show full claude output
#   --tmux              Launch in tmux session with Remote Control
# =============================================================================

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export PATH="/opt/homebrew/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
ORCH_DIR="$HQ_ROOT/workspace/orchestrator"
REGRESSION_INTERVAL=3
SESSION_ID="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
RUN_START_EPOCH=$(date +%s)
AUDIT_SCRIPT="$HQ_ROOT/scripts/audit-log.sh"

# --- Git helpers (worktree-compatible) ---
is_git_repo() {
  local dir="${1:-.}"
  [[ -d "$dir/.git" || -f "$dir/.git" ]]
}

USING_WORKTREE=false
WORKTREE_PATH=""
ORIGINAL_REPO_PATH=""

# Create or reuse a git worktree for isolated branch work.
# Sets REPO_PATH to the worktree and USING_WORKTREE=true.
ensure_worktree() {
  local repo_path="$1"
  local branch_name="$2"
  local base_branch="${3:-main}"

  # Check if ANY existing worktree already has this branch checked out
  local existing_wt
  existing_wt=$(git -C "$repo_path" worktree list --porcelain 2>/dev/null \
    | awk -v branch="$branch_name" '
      /^worktree / { wt=$2 }
      /^branch refs\/heads\// {
        b = substr($0, length("branch refs/heads/") + 1)
        if (b == branch) print wt
      }
    ' | head -1)

  if [[ -n "$existing_wt" && -d "$existing_wt" ]]; then
    # If the found worktree IS the main repo itself, skip worktree setup — just use in-place
    local resolved_wt resolved_repo
    resolved_wt=$(cd "$existing_wt" && pwd -P)
    resolved_repo=$(cd "$repo_path" && pwd -P)
    if [[ "$resolved_wt" == "$resolved_repo" ]]; then
      log_info "Branch $branch_name already checked out in main repo — using in-place"
      return 0
    fi
    log_info "Reusing existing worktree: $existing_wt (branch: $branch_name)"
    WORKTREE_PATH="$existing_wt"
    ORIGINAL_REPO_PATH="$REPO_PATH"
    REPO_PATH="$existing_wt"
    USING_WORKTREE=true
    return 0
  fi

  # Slugify branch for new worktree directory name
  local branch_slug="${branch_name//\//-}"
  local wt_path="${repo_path}-wt-${branch_slug}"

  # Heal orphan worktree directories left from prior failed runs.
  # git worktree add refuses to reuse a pre-existing path, even an empty one.
  # Prune stale metadata, then remove the dir only if it's a safe orphan
  # (no .git entry AND contents limited to regenerable artifacts). Anything
  # else → bail so we never destroy real work.
  if [[ -e "$wt_path" ]]; then
    git -C "$repo_path" worktree prune 2>/dev/null || true
    if [[ -e "$wt_path/.git" ]]; then
      log_err "Worktree path $wt_path still registered after prune — manual cleanup required"
      log_err "  git -C $repo_path worktree remove --force $wt_path"
      return 1
    fi
    local _orphan_contents
    _orphan_contents=$(cd "$wt_path" && ls -A 2>/dev/null | grep -v -E '^(node_modules|\.expo|\.next|\.turbo|dist|build|\.DS_Store)$' || true)
    if [[ -n "$_orphan_contents" ]]; then
      log_err "Worktree path $wt_path exists with unexpected contents — refusing to overwrite"
      log_err "  Contents: $(echo "$_orphan_contents" | tr '\n' ' ')"
      log_err "  Manual cleanup: rm -rf $wt_path  (verify first!)"
      return 1
    fi
    log_warn "Removing orphan worktree directory (regenerable artifacts only): $wt_path"
    rm -rf "$wt_path"
  fi

  # Create the worktree
  log_info "Creating worktree: $wt_path (branch: $branch_name)"
  if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
    git -C "$repo_path" worktree add "$wt_path" "$branch_name" 2>&1 || {
      log_err "Failed to create worktree"
      return 1
    }
  else
    git -C "$repo_path" worktree add -b "$branch_name" "$wt_path" "$base_branch" 2>&1 || {
      log_err "Failed to create worktree with new branch"
      return 1
    }
  fi

  # Install dependencies (monorepo needs node_modules)
  if [[ -f "$wt_path/bun.lock" || -f "$wt_path/bun.lockb" ]]; then
    log_info "Installing dependencies in worktree..."
    (cd "$wt_path" && bun install --frozen-lockfile 2>/dev/null || bun install 2>/dev/null) || true
  elif [[ -f "$wt_path/package-lock.json" ]]; then
    (cd "$wt_path" && npm ci 2>/dev/null || npm install 2>/dev/null) || true
  fi

  WORKTREE_PATH="$wt_path"
  ORIGINAL_REPO_PATH="$REPO_PATH"
  REPO_PATH="$wt_path"
  USING_WORKTREE=true
  log_ok "Worktree ready: $wt_path"
}

# Clean up worktree on project completion
cleanup_worktree() {
  if [[ "$USING_WORKTREE" != true || -z "$WORKTREE_PATH" || -z "$ORIGINAL_REPO_PATH" ]]; then
    return 0
  fi

  # Safety: never remove the main repo itself (happens when branchName matches current checkout)
  local resolved_wt resolved_orig
  resolved_wt=$(cd "$WORKTREE_PATH" 2>/dev/null && pwd -P) || return 0
  resolved_orig=$(cd "$ORIGINAL_REPO_PATH" 2>/dev/null && pwd -P) || return 0
  if [[ "$resolved_wt" == "$resolved_orig" ]]; then
    return 0
  fi

  log_info "Cleaning up worktree: $WORKTREE_PATH"

  # Ensure all changes are committed/pushed before removing
  local dirty
  dirty=$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null) || true
  if [[ -n "$dirty" ]]; then
    log_warn "Worktree has uncommitted changes — skipping cleanup"
    log_warn "  Manual cleanup: git -C $ORIGINAL_REPO_PATH worktree remove $WORKTREE_PATH"
    return 0
  fi

  git -C "$ORIGINAL_REPO_PATH" worktree remove "$WORKTREE_PATH" 2>/dev/null || {
    log_warn "Failed to remove worktree — manual cleanup needed"
    log_warn "  git -C $ORIGINAL_REPO_PATH worktree remove $WORKTREE_PATH"
  }
}

# Signal-safe cleanup: release checkouts, kill swarm children, then cleanup worktree
cleanup_on_signal() {
  local sig="$1"
  log_warn "Caught signal $sig — cleaning up..."

  # Kill background check-in timer if running
  [[ -n "${CHECKIN_PID:-}" ]] && kill "$CHECKIN_PID" 2>/dev/null || true
  [[ -n "${HEARTBEAT_PID:-}" ]] && kill "$HEARTBEAT_PID" 2>/dev/null || true

  # Kill swarm background processes
  if [[ ${#SWARM_PIDS[@]:-0} -gt 0 ]]; then
    local i=0
    while [[ $i -lt ${#SWARM_PIDS[@]} ]]; do
      local pid="${SWARM_PIDS[$i]}"
      local sid="${SWARM_STORY_IDS[$i]}"
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        log_warn "Killed swarm process $sid (PID $pid)"
      fi
      # Release checkout for this story
      if [[ -n "${STATE_FILE:-}" && -f "${STATE_FILE:-}" ]]; then
        release_checkout "$sid" 2>/dev/null || true
      fi
      # Release file locks
      release_swarm_locks "$sid" 2>/dev/null || true
      i=$((i + 1))
    done
  fi

  # Release current sequential story checkout
  if [[ -n "${STORY_ID:-}" && -n "${STATE_FILE:-}" && -f "${STATE_FILE:-}" ]]; then
    release_checkout "$STORY_ID" 2>/dev/null || true
  fi

  # Update state to paused (not in_progress with stale PID)
  if [[ -n "${STATE_FILE:-}" && -f "${STATE_FILE:-}" ]]; then
    jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      '.status = "paused" | .updated_at = $ts | .current_tasks = []' \
      "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null \
      && mv "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null || true
  fi

  cleanup_worktree
  exit 130
}

# --- repo-run-registry integration (added by HQ repo-run-coordination) ---
REPO_RUN_REGISTRY="$HQ_ROOT/scripts/repo-run-registry.sh"
REPO_RUN_ID=""
HEARTBEAT_PID=""

_repo_run_parent_pid() {
  local pid=$PPID
  local max=15
  while [[ -n "$pid" && "$pid" != "1" && $max -gt 0 ]]; do
    if ps -p "$pid" -o comm= 2>/dev/null | grep -qi 'claude'; then
      echo "$pid"
      return
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' \n')
    max=$((max - 1))
  done
  # Fallback: immediate parent
  echo "$PPID"
}

repo_run_register_for_repo() {
  local repo="$1"
  [[ -z "$repo" || ! -x "$REPO_RUN_REGISTRY" ]] && return 0
  local parent_pid
  parent_pid=$(_repo_run_parent_pid)
  REPO_RUN_ID=$("$REPO_RUN_REGISTRY" register \
    --pid "$parent_pid" \
    --session-id "$SESSION_ID" \
    --command "/run-project" \
    --project "$PROJECT" \
    --repo "$repo" \
    --scope "repo" 2>/dev/null) || return 0
  [[ -n "$REPO_RUN_ID" ]] || return 0

  # Background heartbeat every 60s — auto-exits if registry deregisters the entry
  (
    while true; do
      sleep 60
      "$REPO_RUN_REGISTRY" heartbeat --run-id "$REPO_RUN_ID" >/dev/null 2>&1 || break
    done
  ) &
  HEARTBEAT_PID=$!
  log_info "repo-run-registry: registered $REPO_RUN_ID (pid=$parent_pid scope=repo) → $repo"
}

repo_run_cleanup_registry() {
  [[ -n "${HEARTBEAT_PID:-}" ]] && kill "$HEARTBEAT_PID" 2>/dev/null || true
  if [[ -n "${REPO_RUN_ID:-}" && -x "${REPO_RUN_REGISTRY:-}" ]]; then
    "$REPO_RUN_REGISTRY" deregister --run-id "$REPO_RUN_ID" >/dev/null 2>&1 || true
  fi
}
# --- end repo-run-registry integration ---

trap 'cleanup_on_signal INT' INT
trap 'cleanup_on_signal TERM' TERM
trap 'repo_run_cleanup_registry; cleanup_worktree' EXIT

# --- Defaults ---
PROJECT=""
RESUME=false
STATUS=false
DRY_RUN=false
MODEL=""
BUILDER=""  # "" = claude (default), "codex" = use `codex exec` for build phase
NO_PERMISSIONS=false
RETRY_FAILED=false
TIMEOUT=""
VERBOSE=false
TMUX_MODE=false
HEADLESS=false
IN_PLACE=false
SWARM_MODE=false
SWARM_MAX=4
CHECKIN_INTERVAL=180  # seconds between check-in status prints
CODEX_AUTOFIX=false
MONITOR=true  # auto-spawn cmux monitor workspace (disable with --no-monitor)

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# =============================================================================
# Capture raw args for --tmux passthrough (before parsing consumes them)
# =============================================================================
PASSTHROUGH_ARGS=""
for arg in "$@"; do
  [[ "$arg" != "--tmux" ]] && PASSTHROUGH_ARGS="$PASSTHROUGH_ARGS $arg"
done
PASSTHROUGH_ARGS="${PASSTHROUGH_ARGS# }"

# =============================================================================
# Argument Parsing
# =============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume)       RESUME=true; shift ;;
    --status)       STATUS=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --model)        MODEL="$2"; shift 2 ;;
    --builder)      BUILDER="$2"; shift 2 ;;
    --no-permissions) NO_PERMISSIONS=true; shift ;;
    --retry-failed) RETRY_FAILED=true; shift ;;
    --timeout)      TIMEOUT="$2"; shift 2 ;;
    --verbose)      VERBOSE=true; shift ;;
    --tmux)         TMUX_MODE=true; shift ;;
    --in-place)     IN_PLACE=true; shift ;;
    --swarm)
      SWARM_MODE=true
      # Optional: --swarm 3 sets max concurrency
      if [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]]; then
        SWARM_MAX="$2"; shift
      fi
      shift ;;
    --checkin-interval) CHECKIN_INTERVAL="$2"; shift 2 ;;
    --codex-autofix)  CODEX_AUTOFIX=true; shift ;;
    --no-monitor)     MONITOR=false; shift ;;
    --help|-h)
      cat <<'HELP'
Usage: scripts/run-project.sh <project> [flags]
       scripts/run-project.sh --status

Flags:
  --resume            Resume from next incomplete story (auto-detected)
  --status            Show all project statuses, exit
  --dry-run           Show story order without executing
  --model MODEL       Override model for all stories (claude builder only)
  --builder BUILDER   Build agent: "claude" (default) or "codex" — when "codex",
                      each story is executed via `codex exec` instead of `claude -p`.
                      Completion is detected via the same 3-layer parser (termination
                      JSON on any line → git commit heuristic fallback).
  --no-permissions    Pass --dangerously-skip-permissions to claude
  --retry-failed      Re-run previously failed stories only
  --timeout N         Per-story wall-clock timeout in minutes
  --verbose           Show full claude output
  --tmux              Launch in tmux session with Remote Control
  --in-place          Skip worktree creation, work directly on repo checkout
  --swarm [N]         Run eligible stories in parallel (max N concurrent, default 4)
  --checkin-interval N  Seconds between check-in status prints (default: 180)
  --codex-autofix     Auto-fix P1/P2 codex review findings (opt-in)
  --no-monitor        Skip auto-spawning the cmux monitor workspace
HELP
      exit 0
      ;;
    -*)
      echo -e "${RED}Unknown flag: $1${NC}" >&2
      exit 1
      ;;
    *)
      PROJECT="$1"; shift ;;
  esac
done

# Headless detection: non-interactive when permissions bypassed (pipeline mode)
if [[ "$NO_PERMISSIONS" == true ]]; then
  HEADLESS=true
fi

# =============================================================================
# --tmux: Launch in tmux session with Remote Control
# =============================================================================

if [[ "$TMUX_MODE" == true ]]; then
  command -v tmux >/dev/null 2>&1 || { echo -e "${RED}tmux not installed${NC}"; exit 1; }
  [[ -z "$PROJECT" ]] && { echo -e "${RED}--tmux requires a project name${NC}"; exit 1; }

  SESSION_NAME="rp-${PROJECT}"

  # Kill existing session if present (re-launch)
  tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true

  # Launch tmux → interactive claude → /run-project with passthrough flags
  tmux new-session -d -s "$SESSION_NAME" \
    "cd $HQ_ROOT && claude"

  sleep 3  # wait for claude to initialize

  tmux send-keys -t "$SESSION_NAME" \
    "/run-project ${PASSTHROUGH_ARGS}" Enter

  echo -e "\n${GREEN}${BOLD}Launched in tmux: ${SESSION_NAME}${NC}"
  echo -e "  ${BLUE}Attach:${NC}  tmux attach -t ${SESSION_NAME}"
  echo -e "  ${BLUE}RC:${NC}      connect from claude.ai/code or Claude mobile app"
  echo -e "  ${BLUE}Kill:${NC}    tmux kill-session -t ${SESSION_NAME}\n"
  exit 0
fi

# =============================================================================
# Utilities
# =============================================================================

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()      { echo -e "${DIM}[$(date +%H:%M:%S)]${NC} $*"; }
log_info()  { echo -e "${DIM}[$(date +%H:%M:%S)]${NC} ${BLUE}INFO${NC}  $*"; }
log_ok()    { echo -e "${DIM}[$(date +%H:%M:%S)]${NC} ${GREEN}DONE${NC}  $*"; }
log_warn()  { echo -e "${DIM}[$(date +%H:%M:%S)]${NC} ${YELLOW}WARN${NC}  $*"; }
log_err()   { echo -e "${DIM}[$(date +%H:%M:%S)]${NC} ${RED}FAIL${NC}  $*"; }

# =============================================================================
# --status: Show all project statuses
# =============================================================================

if [[ "$STATUS" == true ]]; then
  echo -e "\n${BOLD}Project Status${NC}\n"

  active="" paused="" completed=""
  for state_file in "$ORCH_DIR"/*/state.json; do
    [[ -f "$state_file" ]] || continue
    name=$(jq -r '.project // "unknown"' "$state_file")
    status=$(jq -r '.status // "unknown"' "$state_file")
    total=$(jq -r '(.progress.total // 0) | tonumber' "$state_file" 2>/dev/null || echo 0)
    done_count=$(jq -r '(.progress.completed // 0) | tonumber' "$state_file" 2>/dev/null || echo 0)
    [[ "$total" =~ ^[0-9]+$ ]] || total=0
    [[ "$done_count" =~ ^[0-9]+$ ]] || done_count=0
    if (( total > 0 )); then pct=$(( done_count * 100 / total )); else pct=0; fi

    line="  $name — $done_count/$total ($pct%)"
    case "$status" in
      in_progress) active+="$line\n" ;;
      paused)      paused+="$line\n" ;;
      completed)   completed+="$line\n" ;;
    esac
  done

  echo -e "${GREEN}ACTIVE:${NC}"
  [[ -n "$active" ]] && echo -e "$active" || echo "  (none)"
  echo -e "${YELLOW}PAUSED:${NC}"
  [[ -n "$paused" ]] && echo -e "$paused" || echo "  (none)"
  echo -e "${DIM}COMPLETED:${NC}"
  [[ -n "$completed" ]] && echo -e "$completed" || echo "  (none)"
  echo
  exit 0
fi

# =============================================================================
# Validate project argument
# =============================================================================

if [[ -z "$PROJECT" ]]; then
  echo "Usage: scripts/run-project.sh <project> [flags]"
  echo "       scripts/run-project.sh --status"
  echo ""
  echo "Run scripts/run-project.sh --help for all options."
  exit 1
fi

# =============================================================================
# Resolve PRD Path
# =============================================================================

resolve_prd_path() {
  local project="$1"

  # 1. Known path from existing state.json
  local state_path="$ORCH_DIR/$project/state.json"
  if [[ -f "$state_path" ]]; then
    local known
    known=$(jq -r '.prd_path // empty' "$state_path")
    if [[ -n "$known" && -f "$HQ_ROOT/$known" ]]; then
      echo "$HQ_ROOT/$known"
      return 0
    fi
  fi

  # 2. Direct scan: companies/*/projects/$project/prd.json
  for prd in "$HQ_ROOT"/companies/*/projects/"$project"/prd.json; do
    if [[ -f "$prd" ]]; then
      echo "$prd"
      return 0
    fi
  done

  # 3. HQ-level: projects/$project/prd.json
  if [[ -f "$HQ_ROOT/projects/$project/prd.json" ]]; then
    echo "$HQ_ROOT/projects/$project/prd.json"
    return 0
  fi

  # 4. qmd fallback
  local qmd_result
  qmd_result=$(qmd search "$project prd.json" --json -n 5 2>/dev/null \
    | jq -r '.[].file // empty' 2>/dev/null \
    | grep "/$project/prd.json" \
    | head -1) || true
  if [[ -n "$qmd_result" && -f "$qmd_result" ]]; then
    echo "$qmd_result"
    return 0
  fi

  return 1
}

PRD_PATH=""
PRD_PATH=$(resolve_prd_path "$PROJECT") || true

if [[ -z "$PRD_PATH" || ! -f "$PRD_PATH" ]]; then
  echo -e "${RED}ERROR: prd.json not found for '$PROJECT'.${NC}"
  echo "Run /plan $PROJECT to generate one."
  exit 1
fi

# Relative path for state files
PRD_REL="${PRD_PATH#"$HQ_ROOT/"}"

# Company slug (for audit logging)
COMPANY=$(jq -r '.metadata.company // empty' "$PRD_PATH")

log_info "PRD: $PRD_REL"

# =============================================================================
# Validate PRD
# =============================================================================

validate_prd() {
  local prd_path="$1"

  if ! jq -e '.userStories | type == "array" and length > 0' "$prd_path" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: prd.json has no userStories array (or it's empty).${NC}"
    exit 1
  fi

  local invalid
  invalid=$(jq -r '
    .userStories[] |
    select(
      (.id | not) or
      (.title | not) or
      (.description | not) or
      (has("passes") | not)
    ) | .id // "unknown"
  ' "$prd_path")

  if [[ -n "$invalid" ]]; then
    echo -e "${RED}ERROR: Stories missing required fields (id, title, description, passes):${NC}"
    echo "$invalid"
    exit 1
  fi
}

validate_prd "$PRD_PATH"

# =============================================================================
# Read PRD stats
# =============================================================================

read_prd_stats() {
  TOTAL=$(jq '.userStories | length' "$PRD_PATH")
  COMPLETED=$(jq '[.userStories[] | select(.passes == true)] | length' "$PRD_PATH")
  REMAINING=$((TOTAL - COMPLETED))
}

read_prd_stats

# Resolve repo path for git operations
REPO_PATH=$(jq -r '.metadata.repoPath // empty' "$PRD_PATH")
if [[ -n "$REPO_PATH" && ! "$REPO_PATH" = /* ]]; then
  REPO_PATH="$HQ_ROOT/$REPO_PATH"
fi

# =============================================================================
# Branch Setup (always-worktree for isolation)
# =============================================================================

WORKTREE_ENABLED=$(yq e '.worktree.enabled // true' "$HQ_ROOT/settings/orchestrator.yaml" 2>/dev/null || echo "true")
BRANCH_NAME=$(jq -r '.branchName // empty' "$PRD_PATH")
BASE_BRANCH=$(jq -r '.metadata.baseBranch // "main"' "$PRD_PATH")

# Auto-create worktree when metadata.repoPath points to a path that does not
# exist yet. Derive the source repo by stripping the trailing `-suffix` from
# basename(REPO_PATH). Example: repos/private/{product}-sms-guardrails -> repos/private/{product}.
if [[ -n "$BRANCH_NAME" && -n "$REPO_PATH" ]] && ! is_git_repo "$REPO_PATH"; then
  _source_repo=""
  _candidate="$REPO_PATH"
  while [[ -n "$_candidate" && "$_candidate" != "$(dirname "$_candidate")" ]]; do
    _base=$(basename "$_candidate")
    _parent=$(dirname "$_candidate")
    if [[ "$_base" == *-* ]]; then
      _candidate="$_parent/${_base%-*}"
      if is_git_repo "$_candidate"; then
        _source_repo="$_candidate"
        break
      fi
    else
      break
    fi
  done
  unset _candidate _base _parent
  if [[ -n "$_source_repo" ]]; then
    log_info "Target repoPath ${REPO_PATH} does not exist — creating worktree from ${_source_repo}"
    if git -C "$_source_repo" show-ref --verify --quiet "refs/heads/$BRANCH_NAME" 2>/dev/null; then
      git -C "$_source_repo" worktree add "$REPO_PATH" "$BRANCH_NAME" 2>&1 || {
        log_err "Failed to create worktree at $REPO_PATH"
        exit 1
      }
    else
      git -C "$_source_repo" worktree add -b "$BRANCH_NAME" "$REPO_PATH" "$BASE_BRANCH" 2>&1 || {
        log_err "Failed to create worktree at $REPO_PATH with new branch $BRANCH_NAME"
        exit 1
      }
    fi
    if [[ -f "$REPO_PATH/bun.lock" || -f "$REPO_PATH/bun.lockb" ]]; then
      log_info "Installing dependencies in worktree (frozen lockfile)..."
      (cd "$REPO_PATH" && bun install --frozen-lockfile 2>/dev/null || bun install 2>/dev/null) || true
    fi
    USING_WORKTREE=true
    WORKTREE_PATH="$REPO_PATH"
    ORIGINAL_REPO_PATH="$_source_repo"
    log_ok "Worktree ready: $REPO_PATH"
  else
    log_warn "Target repoPath '${REPO_PATH}' does not exist and no source repo could be derived — builder will run from HQ_ROOT"
  fi
  unset _source_repo
fi

if [[ -n "$BRANCH_NAME" && -n "$REPO_PATH" ]] && is_git_repo "$REPO_PATH"; then
  if [[ "$IN_PLACE" == true || "$WORKTREE_ENABLED" != true ]]; then
    # Opt-out: legacy checkout behavior (no worktree)
    current_branch=$(git -C "$REPO_PATH" branch --show-current 2>/dev/null)
    if [[ "$current_branch" != "$BRANCH_NAME" ]]; then
      if git -C "$REPO_PATH" show-ref --verify --quiet "refs/heads/$BRANCH_NAME" 2>/dev/null; then
        log_info "In-place: checking out existing branch: $BRANCH_NAME"
        git -C "$REPO_PATH" checkout "$BRANCH_NAME"
      else
        log_info "In-place: creating branch: $BRANCH_NAME from $BASE_BRANCH"
        git -C "$REPO_PATH" checkout -b "$BRANCH_NAME" "$BASE_BRANCH"
      fi
    fi
  else
    # Default: always use worktree for isolation
    log_info "Creating/reusing worktree for branch: $BRANCH_NAME"
    ensure_worktree "$REPO_PATH" "$BRANCH_NAME" "$BASE_BRANCH" || {
      log_err "Failed to create worktree — aborting"
      exit 1
    }
  fi

  # If REPO_PATH was already a worktree (e.g., prd.json points to one), detect it
  if [[ -f "$REPO_PATH/.git" ]] && [[ "$USING_WORKTREE" != true ]]; then
    USING_WORKTREE=true
    WORKTREE_PATH="$REPO_PATH"
    # Resolve original repo from gitdir
    _gitdir_content=$(cat "$REPO_PATH/.git" 2>/dev/null)
    if [[ "$_gitdir_content" == gitdir:* ]]; then
      _resolved="${_gitdir_content#gitdir: }"
      if [[ "$_resolved" == *"/.git/worktrees/"* ]]; then
        ORIGINAL_REPO_PATH="${_resolved%%/.git/worktrees/*}"
      fi
    fi
    log_info "Detected existing worktree at $REPO_PATH"
  fi
fi

# =============================================================================
# Register with repo-run-registry (after worktree setup so REPO_PATH is final)
if [[ -n "${REPO_PATH:-}" ]]; then
  repo_run_register_for_repo "$REPO_PATH"
fi

# =============================================================================
# Display Status
# =============================================================================

echo ""
echo -e "${BOLD}=== run-project: $PROJECT ===${NC}"
echo -e "Progress: ${GREEN}$COMPLETED${NC}/$TOTAL ($((TOTAL > 0 ? COMPLETED * 100 / TOTAL : 0))%)"
echo ""

if [[ "$REMAINING" -eq 0 && "$RETRY_FAILED" != true ]]; then
  echo -e "${GREEN}All stories complete.${NC}"
  exit 0
fi

# Show remaining stories
echo -e "${DIM}Remaining:${NC}"
jq -r '.userStories[] | select(.passes != true) | "  \(.id): \(.title)"' "$PRD_PATH"
echo ""

# =============================================================================
# Initialize / Load State
# =============================================================================

PROJECT_DIR="$ORCH_DIR/$PROJECT"
STATE_FILE="$PROJECT_DIR/state.json"
PROGRESS_FILE="$PROJECT_DIR/progress.txt"
EXEC_DIR="$PROJECT_DIR/executions"

mkdir -p "$EXEC_DIR"

if [[ -f "$STATE_FILE" ]]; then
  existing_status=$(jq -r '.status // "unknown"' "$STATE_FILE")
  if [[ "$existing_status" == "completed" && "$RETRY_FAILED" != true ]]; then
    echo -e "${YELLOW}Project already completed. Use --retry-failed to re-run failures.${NC}"
    exit 0
  fi
  # Update status for resume
  jq --arg ts "$(ts)" '.status = "in_progress" | .updated_at = $ts' "$STATE_FILE" > "$STATE_FILE.tmp" \
    && mv "$STATE_FILE.tmp" "$STATE_FILE"
  log_info "Resuming from state.json"

  # Clean stale current_tasks from prior crashed runs (dead PIDs)
  if [[ -f "$STATE_FILE" ]]; then
    _stale_count=0
    while IFS= read -r _pid; do
      if [[ -n "$_pid" && "$_pid" != "null" ]] && ! kill -0 "$_pid" 2>/dev/null; then
        jq --argjson pid "$_pid" \
          '.current_tasks = [.current_tasks[] | select((.pid // .checkedOutBy.pid) != $pid)]' \
          "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
        ((_stale_count++)) || true
      fi
    done < <(jq -r '.current_tasks[]? | (.pid // .checkedOutBy.pid // empty) | tostring' "$STATE_FILE" 2>/dev/null)
    [[ $_stale_count -gt 0 ]] && log_info "Cleaned $_stale_count stale current_tasks entries from prior run"
  fi

  "$AUDIT_SCRIPT" append --event project_started --project "$PROJECT" \
    ${COMPANY:+--company "$COMPANY"} \
    --action "Resuming project: $TOTAL stories, $COMPLETED completed (resume=true)" \
    --result success \
    --session-id "$SESSION_ID" || true
else
  # Initialize new state
  cat > "$STATE_FILE" <<EOF
{
  "project": "$PROJECT",
  "prd_path": "$PRD_REL",
  "status": "in_progress",
  "started_at": "$(ts)",
  "updated_at": "$(ts)",
  "progress": { "total": $TOTAL, "completed": $COMPLETED, "failed": 0, "in_progress": 0 },
  "current_tasks": [],
  "completed_tasks": [],
  "failed_tasks": [],
  "retry_queue": [],
  "regression_gates": [],
  "orchestrator": "bash-v2"
}
EOF
  echo "[$(ts)] Project started: $PROJECT ($TOTAL stories, $COMPLETED already completed)" >> "$PROGRESS_FILE"
  log_info "Initialized new project state"
  "$AUDIT_SCRIPT" append --event project_started --project "$PROJECT" \
    ${COMPANY:+--company "$COMPANY"} \
    --action "Project started: $TOTAL stories total, resume=false" \
    --result success \
    --session-id "$SESSION_ID" || true
fi

# =============================================================================
# State Schema Migration (current_task → current_tasks[])
# =============================================================================

migrate_state_schema() {
  [[ ! -f "$STATE_FILE" ]] && return 0

  local has_old
  has_old=$(jq 'has("current_task") and (has("current_tasks") | not)' "$STATE_FILE" 2>/dev/null) || return 0

  if [[ "$has_old" == "true" ]]; then
    jq '
      .current_tasks = (if .current_task != null then [.current_task] else [] end) |
      del(.current_task) |
      .orchestrator = "bash-v2"
    ' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    log_info "Migrated state.json: current_task → current_tasks[]"
  fi
}

migrate_state_schema

# =============================================================================
# Checkout Config (from orchestrator.yaml)
# =============================================================================

CHECKOUT_ENABLED=$(yq e '.checkout.enabled // true' "$HQ_ROOT/settings/orchestrator.yaml" 2>/dev/null || echo "true")
CHECKOUT_STALE_MINUTES=$(yq e '.checkout.stale_timeout_minutes // 30' "$HQ_ROOT/settings/orchestrator.yaml" 2>/dev/null || echo "30")

# Swarm config (CLI flags override yaml)
if [[ "$SWARM_MAX" -eq 4 ]]; then
  SWARM_MAX=$(yq e '.swarm.max_concurrency // 4' "$HQ_ROOT/settings/orchestrator.yaml" 2>/dev/null || echo "4")
fi
if [[ "$CHECKIN_INTERVAL" -eq 180 ]]; then
  CHECKIN_INTERVAL=$(yq e '.swarm.checkin_interval_seconds // 180' "$HQ_ROOT/settings/orchestrator.yaml" 2>/dev/null || echo "180")
fi

# =============================================================================
# Checkout Functions
# =============================================================================

# Clean up stale checkout entries — PID is dead AND older than stale_timeout_minutes
clean_stale_checkouts() {
  [[ "$CHECKOUT_ENABLED" != "true" ]] && return 0
  [[ ! -f "$STATE_FILE" ]] && return 0

  local stale_seconds
  stale_seconds=$(( CHECKOUT_STALE_MINUTES * 60 ))

  # Iterate current_tasks[] and remove entries with dead PIDs past stale timeout
  local task_count
  task_count=$(jq '.current_tasks // [] | length' "$STATE_FILE" 2>/dev/null) || return 0
  [[ "$task_count" -eq 0 ]] && return 0

  local i=0
  while [[ $i -lt $task_count ]]; do
    local checkout_pid checkout_started story_id
    checkout_pid=$(jq -r --argjson idx "$i" '.current_tasks[$idx].checkedOutBy.pid // empty' "$STATE_FILE" 2>/dev/null) || true
    [[ -z "$checkout_pid" ]] && { i=$((i + 1)); continue; }

    # Check if PID is still alive
    if kill -0 "$checkout_pid" 2>/dev/null; then
      i=$((i + 1)); continue  # Still running — leave it
    fi

    # PID is dead — check age
    checkout_started=$(jq -r --argjson idx "$i" '.current_tasks[$idx].checkedOutBy.startedAt // empty' "$STATE_FILE" 2>/dev/null) || true
    story_id=$(jq -r --argjson idx "$i" '.current_tasks[$idx].id // "unknown"' "$STATE_FILE" 2>/dev/null) || true

    if [[ -z "$checkout_started" ]]; then
      # No timestamp — release unconditionally
      jq --arg sid "$story_id" --arg ts "$(ts)" '
        .current_tasks = [.current_tasks[] | select(.id != $sid)] |
        .progress.in_progress = (.current_tasks | length) |
        .updated_at = $ts
      ' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
      log_warn "Released stale checkout (dead PID $checkout_pid, $story_id, no timestamp)"
      task_count=$((task_count - 1))
      continue  # Don't increment — array shifted
    fi

    # Compute age in seconds (macOS-compatible)
    local started_epoch now_epoch pid_age_seconds
    started_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$checkout_started" "+%s" 2>/dev/null) || { i=$((i + 1)); continue; }
    now_epoch=$(date -u +%s)
    pid_age_seconds=$(( now_epoch - started_epoch ))

    if (( pid_age_seconds >= stale_seconds )); then
      jq --arg sid "$story_id" --arg ts "$(ts)" '
        .current_tasks = [.current_tasks[] | select(.id != $sid)] |
        .progress.in_progress = (.current_tasks | length) |
        .updated_at = $ts
      ' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
      log_warn "Released stale checkout: $story_id (dead PID $checkout_pid, ${pid_age_seconds}s old)"
      task_count=$((task_count - 1))
      continue  # Don't increment — array shifted
    fi

    i=$((i + 1))
  done
}

# Attempt to checkout a story. Returns 0 if acquired, 1 if another live PID holds it.
checkout_story() {
  local story_id="$1"
  [[ "$CHECKOUT_ENABLED" != "true" ]] && return 0

  # Check if this specific story is already checked out in current_tasks[]
  local existing_pid
  existing_pid=$(jq -r --arg sid "$story_id" '
    (.current_tasks // [])[] | select(.id == $sid) | .checkedOutBy.pid // empty
  ' "$STATE_FILE" 2>/dev/null) || true

  if [[ -n "$existing_pid" ]]; then
    if kill -0 "$existing_pid" 2>/dev/null; then
      local holder_session
      holder_session=$(jq -r --arg sid "$story_id" '
        (.current_tasks // [])[] | select(.id == $sid) | .checkedOutBy.sessionId // "unknown"
      ' "$STATE_FILE" 2>/dev/null)
      log_warn "Story $story_id is checked out by live PID $existing_pid (session: $holder_session) — skipping"
      return 1
    fi
    # Dead PID — remove stale entry before re-adding
    log_warn "Overriding dead PID $existing_pid checkout for $story_id"
    jq --arg sid "$story_id" --arg ts "$(ts)" '
      .current_tasks = [(.current_tasks // [])[] | select(.id != $sid)] |
      .updated_at = $ts
    ' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi

  # Add checkout entry to current_tasks[]
  jq --arg id "$story_id" --arg pid "$$" --arg ts "$(ts)" --arg sid "$SESSION_ID" '
    .current_tasks = ((.current_tasks // []) + [{
      "id": $id,
      "started_at": $ts,
      "checkedOutBy": {"pid": ($pid | tonumber), "startedAt": $ts, "sessionId": $sid}
    }]) |
    .progress.in_progress = (.current_tasks | length) |
    .updated_at = $ts
  ' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

  return 0
}

# Release checkout after story completion or failure.
# In sequential mode: release by PID match. In swarm: release by story ID.
release_checkout() {
  local story_id="${1:-}"
  [[ "$CHECKOUT_ENABLED" != "true" ]] && return 0
  [[ ! -f "$STATE_FILE" ]] && return 0

  if [[ -n "$story_id" ]]; then
    # Remove specific story from current_tasks[]
    jq --arg sid "$story_id" --arg ts "$(ts)" '
      .current_tasks = [(.current_tasks // [])[] | select(.id != $sid)] |
      .progress.in_progress = (.current_tasks | length) |
      .updated_at = $ts
    ' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  else
    # Legacy: remove all entries owned by our PID
    jq --arg pid "$$" --arg ts "$(ts)" '
      .current_tasks = [(.current_tasks // [])[] | select(.checkedOutBy.pid != ($pid | tonumber))] |
      .progress.in_progress = (.current_tasks | length) |
      .updated_at = $ts
    ' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi
}

# =============================================================================
# Board Sync → in_progress (best-effort)
# =============================================================================

sync_board() {
  local target_status="$1"
  local company
  company=$(jq -r '.metadata.company // empty' "$PRD_PATH") || return 0
  [[ -z "$company" ]] && return 0

  local board_path
  board_path=$(yq -r --arg co "$company" '.[$co].board_path // empty' "$HQ_ROOT/companies/manifest.yaml" 2>/dev/null) || return 0
  [[ -z "$board_path" || "$board_path" == "null" ]] && return 0

  local board_file="$HQ_ROOT/$board_path"
  [[ -f "$board_file" ]] || return 0

  jq --arg prd "$PRD_REL" --arg st "$target_status" --arg ts "$(ts)" '
    (.projects // []) |= map(
      if .prd_path == $prd then .status = $st | .updated_at = $ts else . end
    )
  ' "$board_file" > "$board_file.tmp" && mv "$board_file.tmp" "$board_file" 2>/dev/null || true
}

clean_stale_checkouts

sync_board "in_progress"

# =============================================================================
# Story Selection (Ralph method: deps → file locks → priority → array order)
# =============================================================================

# Check if a story has file lock conflicts
has_file_conflict() {
  local story_id="$1"
  [[ -z "$REPO_PATH" || ! -d "$REPO_PATH" ]] && return 1  # no repo = no conflicts

  local lock_file="$REPO_PATH/.file-locks.json"
  [[ -f "$lock_file" ]] || return 1  # no locks file = no conflicts

  # Get story's declared files
  local story_files
  story_files=$(jq -r --arg id "$story_id" '
    .userStories[] | select(.id == $id) | .files // [] | .[]
  ' "$PRD_PATH" 2>/dev/null) || return 1
  [[ -z "$story_files" ]] && return 1  # no files declared = no conflicts

  # Check each file against active locks (array schema: {version, locks: [{file, owner, acquired_at}]})
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local locked_by owner_pid
    locked_by=$(jq -r --arg file "$f" --arg self "$story_id" '
      .locks // [] | map(select(.file == $file and .owner.story != $self)) | .[0].owner.story // empty
    ' "$lock_file" 2>/dev/null) || continue
    if [[ -n "$locked_by" ]]; then
      # Verify the owning PID is still alive (stale lock = ignore)
      owner_pid=$(jq -r --arg file "$f" --arg self "$story_id" '
        .locks // [] | map(select(.file == $file and .owner.story != $self)) | .[0].owner.pid // empty
      ' "$lock_file" 2>/dev/null) || true
      if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
        continue  # stale lock — owner PID is dead
      fi
      log_warn "  File conflict: $f locked by $locked_by"
      return 0  # has conflict
    fi
  done <<< "$story_files"

  return 1  # no conflicts
}

# Get next incomplete, unblocked, non-conflicting story (priority-aware)
get_next_story() {
  # Re-read PRD each time (execute-task may have updated passes)
  # Selection: unblocked deps → no file conflicts → lowest priority number → array order
  # Optional arg: newline-separated list of IDs to skip
  local skip_list="${1:-}"

  local candidates
  candidates=$(jq -r '
    .userStories as $all |
    [.userStories[] | select(.passes != true)] |
    [.[] | select(
      (.dependsOn // []) | all(. as $dep | $all[] | select(.id == $dep) | .passes == true)
    )] |
    sort_by(.priority // 99) |
    .[].id
  ' "$PRD_PATH") || true

  # Check file locks for each candidate, skip IDs in skip_list
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    # Skip if in skip list
    if [[ -n "$skip_list" ]] && echo "$skip_list" | grep -qx "$cid"; then
      continue
    fi
    if ! has_file_conflict "$cid"; then
      echo "$cid"
      return 0
    fi
  done <<< "$candidates"

  # All candidates have conflicts or are skipped — return empty
  echo ""
}

get_story_title() {
  jq -r --arg id "$1" '.userStories[] | select(.id == $id) | .title' "$PRD_PATH"
}

# =============================================================================
# Swarm Helpers
# =============================================================================

# Check if a story has non-empty files[] declared in prd.json
story_has_files_declared() {
  local story_id="$1"
  local count
  count=$(jq -r --arg id "$story_id" '
    .userStories[] | select(.id == $id) | .files // [] | length
  ' "$PRD_PATH" 2>/dev/null) || true
  [[ -n "$count" && "$count" -gt 0 ]] && return 0
  return 1
}

# Check if two stories share any declared files (returns 0=overlap, 1=no overlap)
# Empty files[] on either side = overlap (conservative — can't verify safety)
stories_have_file_overlap() {
  local id_a="$1" id_b="$2"

  local files_a files_b
  files_a=$(jq -r --arg id "$id_a" '
    .userStories[] | select(.id == $id) | .files // [] | .[]
  ' "$PRD_PATH" 2>/dev/null) || true
  files_b=$(jq -r --arg id "$id_b" '
    .userStories[] | select(.id == $id) | .files // [] | .[]
  ' "$PRD_PATH" 2>/dev/null) || true

  # Empty files = treat as overlap (unknown surface, can't safely swarm)
  [[ -z "$files_a" || -z "$files_b" ]] && return 0

  # Check intersection
  while IFS= read -r fa; do
    [[ -z "$fa" ]] && continue
    while IFS= read -r fb; do
      [[ -z "$fb" ]] && continue
      [[ "$fa" == "$fb" ]] && return 0  # overlap found
    done <<< "$files_b"
  done <<< "$files_a"

  return 1  # no overlap
}

# Get all stories eligible for concurrent swarm execution.
# Returns story IDs one per line (empty = nothing eligible).
# Selection: deps resolved → has files[] → no active lock conflicts → pairwise no file overlap
get_swarm_candidates() {
  # 1. Get all dep-resolved, incomplete stories (same jq as get_next_story)
  local candidates
  candidates=$(jq -r '
    .userStories as $all |
    [.userStories[] | select(.passes != true)] |
    [.[] | select(
      (.dependsOn // []) | all(. as $dep | $all[] | select(.id == $dep) | .passes == true)
    )] |
    sort_by(.priority // 99) |
    .[].id
  ' "$PRD_PATH") || true

  [[ -z "$candidates" ]] && return 0

  # 2. Filter: must have files[] declared AND no existing lock conflicts
  local eligible_list=""
  local eligible_count=0
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    if story_has_files_declared "$cid" && ! has_file_conflict "$cid"; then
      eligible_list="${eligible_list}${cid}"$'\n'
      eligible_count=$((eligible_count + 1))
    fi
  done <<< "$candidates"

  [[ "$eligible_count" -eq 0 ]] && return 0

  # 3. Pairwise overlap elimination — greedy selection
  local selected_list=""
  local selected_count=0
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    local conflict=false
    # Check against all already-selected stories
    while IFS= read -r sel; do
      [[ -z "$sel" ]] && continue
      if stories_have_file_overlap "$cid" "$sel"; then
        conflict=true
        break
      fi
    done <<< "$selected_list"

    if [[ "$conflict" == false ]]; then
      selected_list="${selected_list}${cid}"$'\n'
      selected_count=$((selected_count + 1))
    fi
    # Respect max concurrency cap
    [[ "$selected_count" -ge "$SWARM_MAX" ]] && break
  done <<< "$eligible_list"

  # Output selected candidates
  echo -n "$selected_list" | sed '/^$/d'
}

# =============================================================================
# Dry Run
# =============================================================================

if [[ "$DRY_RUN" == true ]]; then
  echo -e "${BOLD}Dry Run — Story Execution Order:${NC}\n"
  idx=1
  batch_num=0

  # Simulate the selection loop
  temp_prd=$(mktemp)
  cp "$PRD_PATH" "$temp_prd"

  while true; do
    # Get all candidates with resolved deps
    candidates=$(jq -r '
      .userStories as $all |
      [.userStories[] | select(.passes != true)] |
      [.[] | select(
        (.dependsOn // []) | all(. as $dep | $all[] | select(.id == $dep) | .passes == true)
      )] |
      .[].id // empty
    ' "$temp_prd")

    [[ -z "$candidates" ]] && break

    # In swarm mode, show parallel batches
    if [[ "$SWARM_MODE" == true ]]; then
      # Collect candidates that can run in parallel (no file overlap)
      parallel_batch=()
      sequential_fallback=()

      while IFS= read -r cand_id; do
        [[ -z "$cand_id" ]] && continue
        cand_files=$(jq -r --arg id "$cand_id" '.userStories[] | select(.id == $id) | .files // [] | .[]' "$temp_prd" 2>/dev/null)

        # Check overlap with existing batch members
        has_overlap=false
        if [[ -z "$cand_files" ]]; then
          # No files declared — conservative: can't parallelize
          sequential_fallback+=("$cand_id")
          continue
        fi

        if [[ ${#parallel_batch[@]} -gt 0 ]]; then
          for batch_id in "${parallel_batch[@]}"; do
            batch_files=$(jq -r --arg id "$batch_id" '.userStories[] | select(.id == $id) | .files // [] | .[]' "$temp_prd" 2>/dev/null)
            for cf in $cand_files; do
              for bf in $batch_files; do
                if [[ "$cf" == "$bf" ]]; then
                  has_overlap=true; break 3
                fi
              done
            done
          done
        fi

        if [[ "$has_overlap" == false && ${#parallel_batch[@]} -lt "$SWARM_MAX" ]]; then
          parallel_batch+=("$cand_id")
        else
          sequential_fallback+=("$cand_id")
        fi
      done <<< "$candidates"

      if [[ ${#parallel_batch[@]} -gt 1 ]]; then
        batch_num=$((batch_num + 1))
        echo -e "  ${GREEN}── Parallel Batch $batch_num (${#parallel_batch[@]} stories) ──${NC}"
        for pid_story in "${parallel_batch[@]}"; do
          title=$(jq -r --arg id "$pid_story" '.userStories[] | select(.id == $id) | .title' "$temp_prd")
          deps=$(jq -r --arg id "$pid_story" '.userStories[] | select(.id == $id) | .dependsOn // [] | join(", ")' "$temp_prd")
          dep_note=""
          [[ -n "$deps" ]] && dep_note=" ${DIM}(after: $deps)${NC}"
          echo -e "    ${BOLD}$idx.${NC} $pid_story: $title$dep_note"
          jq --arg id "$pid_story" '(.userStories[] | select(.id == $id)).passes = true' "$temp_prd" > "$temp_prd.tmp" \
            && mv "$temp_prd.tmp" "$temp_prd"
          idx=$((idx + 1))
        done
      else
        # Single candidate or all in sequential fallback
        first_cand="${parallel_batch[0]:-${sequential_fallback[0]:-}}"
        [[ -z "$first_cand" ]] && break

        title=$(jq -r --arg id "$first_cand" '.userStories[] | select(.id == $id) | .title' "$temp_prd")
        deps=$(jq -r --arg id "$first_cand" '.userStories[] | select(.id == $id) | .dependsOn // [] | join(", ")' "$temp_prd")
        dep_note=""
        [[ -n "$deps" ]] && dep_note=" ${DIM}(after: $deps)${NC}"
        echo -e "  ${BOLD}$idx.${NC} $first_cand: $title$dep_note"
        jq --arg id "$first_cand" '(.userStories[] | select(.id == $id)).passes = true' "$temp_prd" > "$temp_prd.tmp" \
          && mv "$temp_prd.tmp" "$temp_prd"
        idx=$((idx + 1))
      fi
    else
      # Sequential mode — pick first candidate only
      next=$(echo "$candidates" | head -1)
      [[ -z "$next" ]] && break

      title=$(jq -r --arg id "$next" '.userStories[] | select(.id == $id) | .title' "$temp_prd")
      deps=$(jq -r --arg id "$next" '.userStories[] | select(.id == $id) | .dependsOn // [] | join(", ")' "$temp_prd")

      dep_note=""
      [[ -n "$deps" ]] && dep_note=" ${DIM}(after: $deps)${NC}"
      echo -e "  ${BOLD}$idx.${NC} $next: $title$dep_note"

      # Mark as passed for next iteration
      jq --arg id "$next" '(.userStories[] | select(.id == $id)).passes = true' "$temp_prd" > "$temp_prd.tmp" \
        && mv "$temp_prd.tmp" "$temp_prd"
      idx=$((idx + 1))
    fi
  done

  # Check for blocked stories
  blocked=$(jq -r '[.userStories[] | select(.passes != true)] | length' "$temp_prd")
  if [[ "$blocked" -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}Blocked (unresolvable deps):${NC}"
    jq -r '.userStories[] | select(.passes != true) | "  \(.id): \(.title) (needs: \(.dependsOn | join(", ")))"' "$temp_prd"
  fi

  if [[ "$SWARM_MODE" == true && "$batch_num" -gt 0 ]]; then
    echo ""
    echo -e "${DIM}Swarm mode: $batch_num parallel batch(es) detected${NC}"
  fi

  rm -f "$temp_prd" "$temp_prd.tmp"
  echo ""
  exit 0
fi

# =============================================================================
# Run a Single Story
# =============================================================================

run_story() {
  local story_id="$1"
  local project="$2"
  local prd_path="$3"

  # Read model_hint from story (story-level override)
  local model_hint
  model_hint=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .model_hint // empty' "$HQ_ROOT/$prd_path" 2>/dev/null) || true

  # Read codex_model_hint from story (Codex CLI model override)
  local codex_model_hint
  codex_model_hint=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .codex_model_hint // empty' "$HQ_ROOT/$prd_path" 2>/dev/null) || true

  # Read story metadata for enriched prompt
  local story_title story_labels story_files
  story_title=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .title' "$HQ_ROOT/$prd_path" 2>/dev/null) || true
  story_labels=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .labels // [] | join(", ")' "$HQ_ROOT/$prd_path" 2>/dev/null) || true
  story_files=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .files // [] | join(", ")' "$HQ_ROOT/$prd_path" 2>/dev/null) || true

  local worktree_note=""
  if [[ -n "${REPO_PATH:-}" && -d "$REPO_PATH" ]] && is_git_repo "$REPO_PATH"; then
    worktree_note="
WORKTREE: ${REPO_PATH}
Use this worktree as the working directory for all file operations."
  fi

  local prompt="Execute /execute-task ${project}/${story_id}.

CRITICAL — Follow the FULL Ralph worker pipeline:
1. Classify task type (schema_change, api_development, ui_component, full_stack, enhancement)
2. Select the correct worker sequence from execute-task step 4
3. Load each worker's worker.yaml (instructions, context, verification)
4. Spawn sub-agents PER WORKER with proper handoffs between phases
5. Run back pressure checks (typecheck, lint, tests) per worker.yaml
6. MANDATORY: Include at least one Codex CLI step for any code/dev/deploy task:
   - Use 'codex review --uncommitted' for review (after code-reviewer, before QA)
   - OR use 'codex exec' to delegate implementation to Codex for dev work
   - If codex CLI is unavailable, log warning and continue — never block
7. Commit ALL changes before completing
8. Set passes: true in prd.json only after all workers complete successfully

Story: ${story_id} — ${story_title}
Labels: ${story_labels}
Files: ${story_files}
PRD: ${prd_path}
Codex model hint: ${codex_model_hint:-none}
${worktree_note}

Do NOT skip worker phases. Do NOT use EnterPlanMode or TodoWrite.
Do NOT implement directly — delegate to workers via the execute-task pipeline.
ISOLATION: Only modify files within your assigned repo and this project's PRD. Do NOT read, modify, pause, or interfere with other projects' state files in workspace/orchestrator/. Other orchestrators may be running concurrently — ignore them.

=== MANDATORY TERMINATION PROTOCOL ===
Your ABSOLUTE FINAL message must be ONLY this JSON on its own line, with nothing after it:
{\"task_id\": \"${story_id}\", \"status\": \"completed|failed|blocked\", \"summary\": \"1-sentence\", \"workers_used\": [\"list\"]}
RULES:
- This JSON must be your LAST output. No prose before or after.
- Do NOT answer questions about this JSON.
- Do NOT include this JSON mid-task and then continue talking.
- Wrong format = task marked FAILED by orchestrator."

  local output_file="$EXEC_DIR/${story_id}.output.json"
  local stderr_file="$EXEC_DIR/${story_id}.stderr"
  local exit_code=0

  local cmd=()
  if [[ "$BUILDER" == "codex" ]]; then
    # Codex CLI builder — invokes `codex exec` with the same prompt payload.
    # Completion detection: Layer 2 (grep for task_id+status on the raw file)
    # and Layer 3 (git heuristic) both work on codex's plain-text output.
    local codex_flags=(exec --skip-git-repo-check)
    if [[ "$NO_PERMISSIONS" == true ]]; then
      codex_flags+=(--dangerously-bypass-approvals-and-sandbox)
    else
      codex_flags+=(--full-auto)
    fi
    # Codex ignores claude's --model hints; only pass --model if explicitly set.
    if [[ -n "$MODEL" ]]; then
      codex_flags+=(-m "$MODEL")
    fi
    log_info "Builder: codex exec (story $story_id)"
    cmd=(codex "${codex_flags[@]}" "$prompt")
  else
    # Default: claude -p headless invocation
    local flags=(-p --output-format json)

    if [[ "$NO_PERMISSIONS" == true ]]; then
      flags+=(--dangerously-skip-permissions --permission-mode bypassPermissions)
    fi

    # Model resolution: CLI flag > story model_hint > default
    if [[ -n "$MODEL" ]]; then
      flags+=(--model "$MODEL")
    elif [[ -n "$model_hint" ]]; then
      flags+=(--model "$model_hint")
      log_info "Using model hint: $model_hint (from story $story_id)"
    fi

    cmd=(claude "${flags[@]}" "$prompt")
  fi

  if [[ -n "$TIMEOUT" ]]; then
    # macOS doesn't ship GNU timeout — try gtimeout (coreutils), then perl fallback
    if command -v timeout &>/dev/null; then
      cmd=(timeout "${TIMEOUT}m" "${cmd[@]}")
    elif command -v gtimeout &>/dev/null; then
      cmd=(gtimeout "${TIMEOUT}m" "${cmd[@]}")
    else
      # perl-based timeout fallback for macOS
      cmd=(perl -e "alarm(${TIMEOUT}*60); exec @ARGV" "${cmd[@]}")
    fi
  fi

  # Clear orchestrator's checkout lock for this story before subprocess — execute-task will acquire its own.
  # Prevents self-locking: parent PID is alive so execute-task's AskUserQuestion fires
  # but can't resolve in headless (-p) mode.
  if [[ -f "$STATE_FILE" ]]; then
    jq --arg sid "$story_id" --arg ts "$(ts)" '
      .current_tasks = [(.current_tasks // [])[] |
        if .id == $sid then .checkedOutBy = null else . end
      ] |
      .updated_at = $ts
    ' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi

  # Execute (unset CLAUDECODE to allow nested claude sessions)
  # HQ_EXECUTING_STORY=1 signals to block-inline-story-impl hook that this is a legitimate sub-agent context
  # Run the builder from REPO_PATH (worktree) so codex/claude edit the right tree.
  # Fall back to HQ_ROOT only when REPO_PATH is missing or not a git repo.
  local _build_cwd="$HQ_ROOT"
  if [[ -n "${REPO_PATH:-}" && -d "$REPO_PATH" ]] && is_git_repo "$REPO_PATH"; then
    _build_cwd="$REPO_PATH"
  fi

  # Codex builder has no /execute-task skill writeback — seed phase file
  # and spawn a background poller so monitor-project.sh sees liveness.
  local _hb_pid=""
  if [[ "$BUILDER" == "codex" ]]; then
    codex_heartbeat_init "$story_id" "$PROJECT"
    codex_heartbeat_loop "$story_id" "${REPO_PATH:-}" "$$" &
    _hb_pid=$!
  fi

  if [[ "$VERBOSE" == true ]]; then
    cd "$_build_cwd" && env -u CLAUDECODE HQ_ROOT="$HQ_ROOT" HQ_WORKSPACE_DIR="$HQ_ROOT/workspace" HQ_EXECUTING_STORY=1 "${cmd[@]}" 2>"$stderr_file" | tee "$output_file" || exit_code=$?
  else
    cd "$_build_cwd" && env -u CLAUDECODE HQ_ROOT="$HQ_ROOT" HQ_WORKSPACE_DIR="$HQ_ROOT/workspace" HQ_EXECUTING_STORY=1 "${cmd[@]}" >"$output_file" 2>"$stderr_file" || exit_code=$?
  fi

  # Stop the heartbeat and write a terminal status before the orchestrator
  # moves on. Order matters: kill loop first so finalize owns the last write.
  if [[ "$BUILDER" == "codex" && -n "$_hb_pid" ]]; then
    kill "$_hb_pid" 2>/dev/null || true
    wait "$_hb_pid" 2>/dev/null || true
    codex_heartbeat_finalize "$story_id" "$exit_code"
  fi

  # Sweep any stray workspace/ or companies/ dirs the builder created at the
  # worktree root via relative-path writes. Defense-in-depth for skills that
  # ignore the HQ_ROOT / HQ_WORKSPACE_DIR env vars we exported above.
  cleanup_builder_contamination "${REPO_PATH:-}" || true

  return $exit_code
}

# =============================================================================
# Builder contamination cleanup
# =============================================================================
# Downstream builders (codex/claude) are spawned with cwd=REPO_PATH so their
# edits land in the worktree. But some skill prompts tell workers to append to
# relative paths like `workspace/metrics/model-usage.jsonl` or write task state
# under `workspace/orchestrator/<project>/`. Those relative writes land inside
# the worktree instead of HQ_ROOT, contaminating the feature branch. We now
# export HQ_ROOT / HQ_WORKSPACE_DIR so well-behaved skills resolve to HQ, but
# we also defensively sweep any stray `workspace/` or `companies/` trees that
# a misbehaving skill may have created at the worktree root. Tracked paths
# (the {product} repo legitimately has `apps/...`, never top-level `workspace/`) are
# left alone. Append-only `.jsonl` metric files are merged into HQ_ROOT before
# the stray tree is removed so we don't lose model-usage telemetry.
cleanup_builder_contamination() {
  local repo="${1:-$REPO_PATH}"
  [[ -z "$repo" || ! -d "$repo" ]] && return 0
  local dirname stray cleaned=0
  for dirname in workspace companies; do
    stray="$repo/$dirname"
    [[ ! -d "$stray" ]] && continue
    # Skip if the repo legitimately tracks this top-level dir.
    if (cd "$repo" && git ls-files --error-unmatch "$dirname" >/dev/null 2>&1); then
      continue
    fi
    # Rescue append-only metric files before deletion.
    if [[ -d "$stray/metrics" ]]; then
      mkdir -p "$HQ_ROOT/workspace/metrics"
      local f
      for f in "$stray"/metrics/*.jsonl; do
        [[ -f "$f" ]] || continue
        cat "$f" >> "$HQ_ROOT/workspace/metrics/$(basename "$f")" 2>/dev/null || true
      done
    fi
    rm -rf "$stray"
    cleaned=$((cleaned + 1))
    log_warn "Cleaned stray '${dirname}/' from worktree (relative-path write by builder); merged any metrics into HQ workspace"
  done
  return 0
}

# =============================================================================
# Codex builder heartbeat (observability parity with Claude builder)
# =============================================================================
# The Claude builder delegates stories to /execute-task, whose SKILL.md
# instructs sub-agents to write phase state to executions/{story}.json at
# each worker handoff. The Codex builder bypasses that skill entirely —
# `codex exec <prompt>` is one opaque LLM call that never learns the HQ
# writeback protocol. Without intervention, monitor-project.sh reads a
# missing phase file and renders `starting → pending` for the full run
# even though codex is actively committing work in the worktree.
#
# Fix: the orchestrator writes a lightweight heartbeat file while codex
# runs, polling the worktree's git log and mapping each new commit to a
# completed pseudo-phase. Restores observability parity without coupling
# codex's internal prompt structure to HQ internals.
#
# Lifecycle:
#   codex_heartbeat_init   — seed executions/{story}.json before codex starts
#   codex_heartbeat_loop   — background poller (killed after codex exits)
#   codex_heartbeat_finalize — mark terminal status from codex's exit code

codex_heartbeat_init() {
  local story_id="$1"
  local project="$2"
  local exec_file="$EXEC_DIR/${story_id}.json"
  local now
  now=$(ts)

  # If some other writer already owns the phase file (legacy runs, leftover
  # from a Claude retry, etc.) leave it alone — never clobber foreign state.
  [[ -f "$exec_file" ]] && return 0

  cat > "$exec_file" <<EOF
{
  "task_id": "${story_id}",
  "project": "${project}",
  "builder": "codex",
  "started_at": "${now}",
  "updated_at": "${now}",
  "status": "in_progress",
  "current_phase": 1,
  "phases": [
    {"worker": "codex-exec", "status": "in_progress", "started_at": "${now}"}
  ],
  "commits": []
}
EOF
}

codex_heartbeat_loop() {
  # Background poller. Tails git log in the worktree and appends each new
  # commit as a completed pseudo-phase on executions/{story}.json. Exits
  # when parent_pid (the orchestrator) dies, or when receiving SIGTERM from
  # the caller after codex exits. Failures are non-fatal — this is purely
  # an observability feed.
  local story_id="$1"
  local repo="$2"
  local parent_pid="$3"
  local exec_file="$EXEC_DIR/${story_id}.json"

  # Detach from the controlling terminal so the poller does not interfere
  # with codex's stdio.
  exec </dev/null >/dev/null 2>&1

  local last_sha=""
  if [[ -n "$repo" && -d "$repo" ]] && is_git_repo "$repo"; then
    last_sha=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo "")
  fi

  # Poll interval: 20s is frequent enough to feel live in the monitor
  # (5s refresh) without burning CPU on idle codex runs.
  while kill -0 "$parent_pid" 2>/dev/null; do
    sleep 20
    [[ ! -f "$exec_file" ]] && continue
    [[ -z "$repo" || ! -d "$repo" ]] && continue
    is_git_repo "$repo" || continue

    local cur_sha
    cur_sha=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo "")
    [[ -z "$cur_sha" ]] && continue

    local now_ts
    now_ts=$(ts)

    if [[ -n "$last_sha" && "$cur_sha" != "$last_sha" ]]; then
      # New commits detected — append each as a completed pseudo-phase.
      # Worker name derived from the commit subject's conventional prefix
      # (feat, fix, refactor, test, chore, ...) so the monitor surfaces
      # meaningful labels instead of opaque commit SHAs.
      local commit_lines
      commit_lines=$(git -C "$repo" log --format="%h %s" "${last_sha}..${cur_sha}" --reverse 2>/dev/null || echo "")
      local line sha_short subject worker
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        sha_short="${line%% *}"
        subject="${line#* }"
        worker=$(printf '%s' "$subject" | sed -E 's/^([a-zA-Z][a-zA-Z0-9_-]*)(\(.*\))?:.*/\1/' | tr '[:upper:]' '[:lower:]')
        # Fallback if the subject wasn't conventional-commits shaped.
        if [[ -z "$worker" || "$worker" == "$subject" ]]; then
          worker="commit"
        fi
        jq --arg now "$now_ts" \
           --arg sha "$sha_short" \
           --arg subj "$subject" \
           --arg worker "codex:${worker}" '
          .updated_at = $now |
          .commits += [{sha: $sha, subject: $subj, at: $now}] |
          .phases = ((.phases // []) | map(
            if .status == "in_progress" then
              .status = "completed" | .completed_at = $now
            else . end
          ) + [{worker: $worker, status: "in_progress", started_at: $now, sha: $sha, subject: $subj}]) |
          .current_phase = (.phases | length)
        ' "$exec_file" > "$exec_file.tmp" 2>/dev/null && mv "$exec_file.tmp" "$exec_file" 2>/dev/null || true
      done <<< "$commit_lines"
      last_sha="$cur_sha"
    else
      # No new commits — just bump updated_at so the monitor reads liveness.
      jq --arg now "$now_ts" '.updated_at = $now' "$exec_file" > "$exec_file.tmp" 2>/dev/null && mv "$exec_file.tmp" "$exec_file" 2>/dev/null || true
    fi
  done
}

codex_heartbeat_finalize() {
  local story_id="$1"
  local exit_code="$2"
  local exec_file="$EXEC_DIR/${story_id}.json"
  [[ ! -f "$exec_file" ]] && return 0

  # Only finalize if we own this file (builder: codex). Leave foreign
  # phase files written by /execute-task sub-agents alone.
  local owner
  owner=$(jq -r '.builder // ""' "$exec_file" 2>/dev/null || echo "")
  [[ "$owner" != "codex" ]] && return 0

  local now final_status
  now=$(ts)
  if (( exit_code == 0 )); then
    final_status="completed"
  else
    final_status="failed"
  fi

  jq --arg now "$now" --arg status "$final_status" '
    .updated_at = $now |
    .status = $status |
    .completed_at = $now |
    .phases = ((.phases // []) | map(
      if .status == "in_progress" then
        .status = $status | .completed_at = $now
      else . end
    ))
  ' "$exec_file" > "$exec_file.tmp" 2>/dev/null && mv "$exec_file.tmp" "$exec_file" 2>/dev/null || true
}

# =============================================================================
# Git State Validation (self-healing)
# =============================================================================

validate_git_state() {
  local story_id="$1"

  { [[ -z "$REPO_PATH" ]] || ! is_git_repo "$REPO_PATH"; } && return 0

  local dirty
  dirty=$(git -C "$REPO_PATH" status --porcelain 2>/dev/null) || return 0

  if [[ -n "$dirty" ]]; then
    log_warn "Sub-agent left uncommitted changes. Auto-committing..."
    git -C "$REPO_PATH" add -A
    # Guard (policy: run-project-conflict-marker-guard): refuse to commit if any
    # staged file contains unresolved merge-conflict markers. Pre-existing
    # garbage in the worktree must never be swept into the branch — doing so
    # broke the moonflow-redesign run on 2026-04-16 (94 tsc TS1185 errors).
    local _marker_files
    _marker_files=$(git -C "$REPO_PATH" diff --cached --name-only 2>/dev/null | while IFS= read -r _f; do
      [[ -f "$REPO_PATH/$_f" ]] && grep -lE '^(<{7}|={7}|>{7})([^<=>]|$)' "$REPO_PATH/$_f" 2>/dev/null
    done)
    if [[ -n "$_marker_files" ]]; then
      log_err "REFUSING auto-commit for ${story_id}: conflict markers detected in:"
      while IFS= read -r _f; do [[ -n "$_f" ]] && log_err "  $_f"; done <<< "$_marker_files"
      log_err "  Resetting index — manual cleanup required before run can continue."
      git -C "$REPO_PATH" reset -q 2>/dev/null || true
      return 1
    fi
    git -C "$REPO_PATH" commit -m "[orchestrator] ${story_id}: auto-commit uncommitted work" --no-verify 2>/dev/null || true
  fi
}

get_commit_sha() {
  # Defect B fix: attribution must be anchored to the story's own work.
  # Accepts an optional $1 = pre_story_sha (the HEAD captured before the
  # sub-agent ran). If HEAD has not moved relative to that anchor, the
  # sub-agent did not commit on this branch — return "no-commit" instead of
  # silently re-attributing the previous story's SHA.
  # Accepts an optional $2 = repo path to read from (defaults to REPO_PATH).
  local pre_sha="${1:-}"
  local repo="${2:-$REPO_PATH}"
  { [[ -z "$repo" ]] || ! is_git_repo "$repo"; } && echo "n/a" && return
  local cur_sha
  cur_sha=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null) || { echo "n/a"; return; }
  if [[ -n "$pre_sha" ]]; then
    local pre_short="${pre_sha:0:${#cur_sha}}"
    if [[ "$cur_sha" == "$pre_short" ]]; then
      # HEAD did not advance — do not attribute the unchanged SHA to this story.
      echo "no-commit"
      return
    fi
  fi
  echo "$cur_sha"
}

get_changed_files() {
  local story_id="$1"
  # Defect B fix: when a pre_story_sha is provided, return the union of files
  # touched by commits since that anchor (scoped to the story's own commits)
  # instead of blindly returning the tip commit's file list.
  local pre_sha="${2:-}"
  local repo="${3:-$REPO_PATH}"
  { [[ -z "$repo" ]] || ! is_git_repo "$repo"; } && echo "[]" && return
  local _result=""
  if [[ -n "$pre_sha" ]] && git -C "$repo" cat-file -e "$pre_sha" 2>/dev/null; then
    _result=$(git -C "$repo" diff --name-only "$pre_sha" HEAD 2>/dev/null \
      | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null) || true
  else
    _result=$(git -C "$repo" diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null \
      | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null) || true
  fi
  # Validate JSON before returning — protects --argjson in update_state_completed
  if [[ -z "$_result" ]] || ! jq -e . <<< "$_result" &>/dev/null; then
    echo "[]"
  else
    echo "$_result"
  fi
}

# Capture the current HEAD as an anchor for later attribution. Returns empty
# string (not "n/a") when there's no git repo, so callers can use -n checks.
get_pre_story_sha() {
  local repo="${1:-$REPO_PATH}"
  { [[ -z "$repo" ]] || ! is_git_repo "$repo"; } && echo "" && return
  git -C "$repo" rev-parse HEAD 2>/dev/null || echo ""
}

# =============================================================================
# Cross-Repo Commit Attribution (US-019/US-020 fix)
# =============================================================================
# Problem: orchestrator previously only inspected $REPO_PATH for post-story
# commits. When a sub-agent committed in a sibling repo, it was recorded as
# "no-commit" (US-019). Combined with .completed_tasks being append-only
# by id, a retry-path "no-commit" could also shadow a correct earlier SHA
# (US-020, "duplicate overwrote it").
#
# Fix: capture a pre-story HEAD anchor in every candidate repo, inspect all
# of them after the story runs, write an immutable per-story sidecar, and
# upsert-by-id into state.json with "prefer real SHA over no-commit" merge.

# Parallel indexed arrays (macOS bash 3.2 has no declare -A)
CANDIDATE_REPOS=()
CANDIDATE_PRE_SHAS=()

# Story attribution output — set by resolve_story_attribution(), read by
# update_state_completed() and the call sites.
ATTR_PRIMARY_SHA=""
ATTR_PRIMARY_REPO=""
ATTR_FILES_CHANGED_JSON="[]"
ATTR_CROSS_REPO="false"
ATTR_SIDECAR_REL=""

# Discover candidate repos for a story. Precedence:
#   1. Story's .repos array in prd.json (verbatim — absolute or HQ-root-relative)
#   2. PRD top-level .crossRepoCandidates
#   3. Auto: scan $HQ_ROOT/repos/{public,private}/* for git repos
# Output: newline-separated absolute paths, $REPO_PATH first (always present).
discover_candidate_repos() {
  local story_id="$1"
  local -a out=()

  if [[ -n "$REPO_PATH" ]] && is_git_repo "$REPO_PATH"; then
    out+=("$REPO_PATH")
  fi

  local story_repos=""
  if [[ -n "${PRD_PATH:-}" && -f "$PRD_PATH" ]]; then
    story_repos=$(jq -r --arg id "$story_id" \
      '(.userStories[]? | select(.id == $id) | .repos // [])[]?' \
      "$PRD_PATH" 2>/dev/null || true)
    if [[ -z "$story_repos" ]]; then
      story_repos=$(jq -r '(.crossRepoCandidates // [])[]?' "$PRD_PATH" 2>/dev/null || true)
    fi
  fi

  if [[ -n "$story_repos" ]]; then
    local r resolved
    while IFS= read -r r; do
      [[ -z "$r" ]] && continue
      resolved="$r"
      [[ "$resolved" != /* ]] && resolved="$HQ_ROOT/$resolved"
      if is_git_repo "$resolved" && [[ "$resolved" != "$REPO_PATH" ]]; then
        out+=("$resolved")
      fi
    done <<< "$story_repos"
  else
    # Auto-discover. Tolerate missing dirs (nullglob not portable to bash 3.2).
    local d repo
    for d in "$HQ_ROOT"/repos/public/*/ "$HQ_ROOT"/repos/private/*/; do
      [[ -d "$d" ]] || continue
      repo="${d%/}"
      [[ "$repo" == "$REPO_PATH" ]] && continue
      if is_git_repo "$repo"; then
        out+=("$repo")
      fi
    done
  fi

  printf '%s\n' "${out[@]}"
}

# Populate CANDIDATE_REPOS and CANDIDATE_PRE_SHAS arrays with the candidate
# repos' pre-story HEAD anchors. Call immediately before run_story().
capture_pre_story_anchors() {
  local story_id="$1"
  CANDIDATE_REPOS=()
  CANDIDATE_PRE_SHAS=()
  local repo
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    CANDIDATE_REPOS+=("$repo")
    CANDIDATE_PRE_SHAS+=("$(get_pre_story_sha "$repo")")
  done < <(discover_candidate_repos "$story_id")
}

# Inspect every candidate repo post-story, determine the primary attribution,
# write an immutable sidecar, and populate the ATTR_* globals. Call once per
# story (or per retry attempt) after run_story() returns.
#
# Sets:
#   ATTR_PRIMARY_SHA       — primary repo's short SHA if advanced, else first
#                            advanced sibling's short SHA, else "no-commit"
#   ATTR_PRIMARY_REPO      — absolute path of whichever repo supplied the SHA
#   ATTR_CROSS_REPO        — "true" if any non-primary repo advanced
#   ATTR_FILES_CHANGED_JSON — repo-relative when single-repo, HQ-root-relative
#                            when cross-repo (so dashboards get unambiguous paths)
#   ATTR_SIDECAR_REL       — HQ-root-relative path to the attribution sidecar
resolve_story_attribution() {
  local story_id="$1"
  local started_iso="${2:-}"
  ATTR_PRIMARY_SHA="no-commit"
  ATTR_PRIMARY_REPO=""
  ATTR_CROSS_REPO="false"
  ATTR_SIDECAR_REL=""
  ATTR_FILES_CHANGED_JSON="[]"

  local advanced_count=0
  local primary_advanced="false"
  local per_repo_entries=""

  local i
  for i in "${!CANDIDATE_REPOS[@]}"; do
    local repo="${CANDIDATE_REPOS[i]}"
    local pre="${CANDIDATE_PRE_SHAS[i]}"
    local post=""
    post=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo "")
    local advanced="false"
    local commits_json="[]"
    local files_json="[]"

    if [[ -n "$pre" && -n "$post" ]]; then
      local pre_short="${pre:0:${#post}}"
      if [[ "$post" != "$pre_short" ]]; then
        advanced="true"
        advanced_count=$((advanced_count + 1))
        commits_json=$(git -C "$repo" log --format=%h "$pre"..HEAD 2>/dev/null \
          | jq -R -s 'split("\n")|map(select(length>0))' 2>/dev/null || echo "[]")
        files_json=$(git -C "$repo" diff --name-only "$pre"..HEAD 2>/dev/null \
          | jq -R -s 'split("\n")|map(select(length>0))' 2>/dev/null || echo "[]")
        if ! jq -e . <<< "$commits_json" &>/dev/null; then commits_json="[]"; fi
        if ! jq -e . <<< "$files_json" &>/dev/null; then files_json="[]"; fi

        # Prefer REPO_PATH as primary when it advanced; otherwise first advanced sibling
        if [[ "$repo" == "$REPO_PATH" ]]; then
          ATTR_PRIMARY_SHA="$post"
          ATTR_PRIMARY_REPO="$repo"
          primary_advanced="true"
        elif [[ "$primary_advanced" == "false" && "$ATTR_PRIMARY_SHA" == "no-commit" ]]; then
          ATTR_PRIMARY_SHA="$post"
          ATTR_PRIMARY_REPO="$repo"
        fi
      fi
    fi

    local rel="${repo#$HQ_ROOT/}"
    local entry
    entry=$(jq -n \
      --arg path "$rel" \
      --arg pre "$pre" \
      --arg post "$post" \
      --argjson advanced "$advanced" \
      --argjson commits "$commits_json" \
      --argjson files "$files_json" \
      '{path:$path, pre_sha:$pre, post_sha:$post, advanced:$advanced, commits:$commits, files_changed:$files}')
    per_repo_entries+="$entry"$'\n'
  done

  local candidate_repos_json="[]"
  if [[ -n "$per_repo_entries" ]]; then
    candidate_repos_json=$(printf '%s' "$per_repo_entries" | jq -s '.' 2>/dev/null || echo "[]")
  fi

  # cross_repo iff more than one repo advanced, or the single advanced repo is a sibling
  if (( advanced_count > 1 )); then
    ATTR_CROSS_REPO="true"
  elif (( advanced_count == 1 )) && [[ "$primary_advanced" == "false" ]]; then
    ATTR_CROSS_REPO="true"
  fi

  # Aggregate files_changed. Cross-repo → HQ-root-relative; single-repo → repo-relative.
  if [[ "$ATTR_CROSS_REPO" == "true" ]]; then
    ATTR_FILES_CHANGED_JSON=$(printf '%s' "$candidate_repos_json" \
      | jq '[ .[] | select(.advanced) | .path as $p | .files_changed[] | ($p + "/" + .) ]' 2>/dev/null || echo "[]")
  elif [[ "$primary_advanced" == "true" ]]; then
    local primary_rel="${REPO_PATH#$HQ_ROOT/}"
    ATTR_FILES_CHANGED_JSON=$(printf '%s' "$candidate_repos_json" \
      | jq --arg p "$primary_rel" '[ .[] | select(.path == $p and .advanced) | .files_changed[] ]' 2>/dev/null || echo "[]")
  else
    ATTR_FILES_CHANGED_JSON="[]"
  fi

  if ! jq -e . <<< "$ATTR_FILES_CHANGED_JSON" &>/dev/null; then
    ATTR_FILES_CHANGED_JSON="[]"
  fi

  # Write immutable sidecar; rotate on retry
  local sidecar_dir="$HQ_ROOT/workspace/orchestrator/$PROJECT/executions"
  mkdir -p "$sidecar_dir"
  local sidecar_path="$sidecar_dir/$story_id.attribution.json"
  ATTR_SIDECAR_REL="workspace/orchestrator/$PROJECT/executions/$story_id.attribution.json"
  if [[ -f "$sidecar_path" ]]; then
    mv "$sidecar_path" "$sidecar_path.prev-$(date +%s)" 2>/dev/null || true
  fi

  jq -n \
    --arg story_id "$story_id" \
    --arg project "$PROJECT" \
    --arg session_id "${SESSION_ID:-}" \
    --arg started_at "$started_iso" \
    --arg completed_at "$(ts)" \
    --arg primary_repo "${ATTR_PRIMARY_REPO#$HQ_ROOT/}" \
    --arg summary_sha "$ATTR_PRIMARY_SHA" \
    --argjson cross_repo "$ATTR_CROSS_REPO" \
    --argjson candidate_repos "$candidate_repos_json" \
    '{
      story_id: $story_id, project: $project, session_id: $session_id,
      started_at: $started_at, completed_at: $completed_at,
      primary_repo: $primary_repo, summary_sha: $summary_sha,
      cross_repo: $cross_repo, candidate_repos: $candidate_repos
    }' > "$sidecar_path.tmp" 2>/dev/null && mv "$sidecar_path.tmp" "$sidecar_path"

  # Diagnostic — one structured line, plus a per-repo warn on cross-repo commits
  local total="${#CANDIDATE_REPOS[@]}"
  log_info "[attribution] story=$story_id primary_repo=${ATTR_PRIMARY_REPO#$HQ_ROOT/} primary_sha=$ATTR_PRIMARY_SHA advanced=$advanced_count/$total sidecar=$ATTR_SIDECAR_REL"
  if (( advanced_count > 1 )); then
    log_warn "[attribution] $story_id: cross-repo commits detected across $advanced_count repos"
    local j r p q ps cc
    for j in "${!CANDIDATE_REPOS[@]}"; do
      r="${CANDIDATE_REPOS[j]}"
      p="${CANDIDATE_PRE_SHAS[j]}"
      q=$(git -C "$r" rev-parse --short HEAD 2>/dev/null || echo "")
      ps="${p:0:${#q}}"
      if [[ -n "$q" && "$q" != "$ps" ]]; then
        cc=$(git -C "$r" rev-list --count "$p"..HEAD 2>/dev/null || echo "?")
        log_warn "  ${r#$HQ_ROOT/}: $ps..$q ($cc commits)"
      fi
    done
  fi
}

# =============================================================================
# Codex CLI Review (post-task safety net)
# =============================================================================

run_codex_review() {
  local story_id="$1"

  # Only run for repos with code changes
  { [[ -z "$REPO_PATH" ]] || ! is_git_repo "$REPO_PATH"; } && return 0

  # Check if codex CLI is available
  if ! command -v codex >/dev/null 2>&1; then
    log_warn "Codex CLI not found — skipping post-task review for $story_id"
    return 0
  fi

  # Check if there are recent changes to review (last commit by this story)
  local last_commit_msg
  last_commit_msg=$(git -C "$REPO_PATH" log -1 --format=%s 2>/dev/null) || return 0

  # Only review if the last commit looks like it's from this story
  if ! echo "$last_commit_msg" | grep -qi "$story_id\|orchestrator"; then
    # No obvious story commit — review uncommitted changes if any
    local uncommitted
    uncommitted=$(git -C "$REPO_PATH" diff --stat HEAD 2>/dev/null) || return 0
    [[ -z "$uncommitted" ]] && return 0
  fi

  local story_title
  story_title=$(get_story_title "$story_id")
  local review_file="$EXEC_DIR/${story_id}.codex-review.md"

  log_info "Codex review: $story_id — $story_title"

  # Run codex review on the last commit's changes
  (cd "$REPO_PATH" && codex review \
    "Review the latest changes for $story_id ($story_title). Check for: correctness, security, performance, style consistency. Flag any issues but do not modify files." \
    2>&1) > "$review_file" || true

  if [[ -s "$review_file" ]]; then
    local findings
    findings=$(wc -l < "$review_file" | tr -d ' ')
    log_ok "Codex review saved: $review_file ($findings lines)"

    # Check for critical findings
    if grep -qi "critical\|high.*severity\|security.*vuln\|injection" "$review_file" 2>/dev/null; then
      log_warn "Codex found potentially critical issues — see $review_file"
    fi
    # Return severity for autofix integration
    CODEX_REVIEW_SEVERITY=0
    if grep -qi "P1\|critical\|high.*severity\|security.*vuln\|injection" "$review_file" 2>/dev/null; then
      CODEX_REVIEW_SEVERITY=4
    elif grep -qi "P2\|medium.*severity\|potential.*bug\|missing.*validation" "$review_file" 2>/dev/null; then
      CODEX_REVIEW_SEVERITY=3
    fi

    # Codex autofix: if enabled and severity >= 3, spawn fix agent
    if [[ "$CODEX_AUTOFIX" == "true" && "$CODEX_REVIEW_SEVERITY" -ge 3 ]]; then
      run_codex_fix_agent "$story_id" "$review_file"
    fi
  else
    log_info "Codex review: no findings for $story_id"
    rm -f "$review_file"
    CODEX_REVIEW_SEVERITY=0
  fi
}

# =============================================================================
# Codex Autofix (opt-in: --codex-autofix)
# =============================================================================

run_codex_fix_agent() {
  local story_id="$1"
  local review_file="$2"

  log_info "Codex autofix: spawning fix agent for $story_id (severity=$CODEX_REVIEW_SEVERITY)"

  local fix_prompt
  fix_prompt="You are a targeted code fix agent. A codex review found P1/P2 issues in story $story_id.

Review file contents:
$(cat "$review_file" 2>/dev/null)

Repository path: $REPO_PATH

Instructions:
1. Read each P1/P2 finding from the review
2. Fix ONLY the specific issues flagged — do not refactor, do not add features
3. After fixing, run the project's quality gates if available
4. Commit fixes with message: [codex-autofix] $story_id: fix P1/P2 findings

Do NOT modify the PRD. Do NOT run unrelated changes."

  local fix_output="$EXEC_DIR/${story_id}.codex-fix.json"

  timeout 300 claude -p "$fix_prompt" \
    --output-format json \
    --max-turns 15 \
    ${NO_PERMISSIONS:+--dangerously-skip-permissions --permission-mode bypassPermissions} \
    > "$fix_output" 2>&1 || {
    log_warn "Codex fix agent failed or timed out for $story_id (non-blocking)"
    return 0
  }

  log_ok "Codex autofix completed for $story_id — see $fix_output"

  # Re-run codex review to verify fixes (one pass only, no recursion)
  local old_autofix="$CODEX_AUTOFIX"
  CODEX_AUTOFIX=false  # prevent recursion
  run_codex_review "$story_id"
  CODEX_AUTOFIX="$old_autofix"

  return 0
}

# =============================================================================
# Story Acceptance Tests (cumulative regression guard)
# =============================================================================

run_story_tests() {
  local current_story="$1"

  # Only run for repos with code changes
  { [[ -z "$REPO_PATH" ]] || ! is_git_repo "$REPO_PATH"; } && return 0

  # Detect story test directory — convention: __tests__/stories/ or tests/stories/
  local test_dir=""
  if [[ -d "$REPO_PATH/__tests__/stories" ]]; then
    test_dir="__tests__/stories"
  elif [[ -d "$REPO_PATH/tests/stories" ]]; then
    test_dir="tests/stories"
  else
    # No story tests exist yet — skip silently
    return 0
  fi

  # Count test files
  local test_count
  test_count=$(find "$REPO_PATH/$test_dir" -name "*.test.*" -o -name "*.spec.*" 2>/dev/null | wc -l | tr -d ' ')
  [[ "$test_count" -eq 0 ]] && return 0

  log_info "Running $test_count story acceptance test(s) after $current_story..."

  # Detect test runner from qualityGates or package.json
  local test_cmd=""
  local gates
  gates=$(jq -r '.metadata.qualityGates // [] | .[]' "$PRD_PATH" 2>/dev/null) || true
  if echo "$gates" | grep -q "bun test\|bun run test"; then
    test_cmd="bun test $test_dir/"
  elif echo "$gates" | grep -q "vitest"; then
    test_cmd="npx vitest run $test_dir/"
  elif echo "$gates" | grep -q "jest"; then
    test_cmd="npx jest $test_dir/"
  elif [[ -f "$REPO_PATH/bun.lock" || -f "$REPO_PATH/bun.lockb" ]]; then
    test_cmd="bun test $test_dir/"
  elif [[ -f "$REPO_PATH/package.json" ]]; then
    # Check for vitest or jest in devDependencies
    if jq -e '.devDependencies.vitest // .dependencies.vitest' "$REPO_PATH/package.json" &>/dev/null; then
      test_cmd="npx vitest run $test_dir/"
    elif jq -e '.devDependencies.jest // .dependencies.jest' "$REPO_PATH/package.json" &>/dev/null; then
      test_cmd="npx jest $test_dir/"
    else
      test_cmd="bun test $test_dir/"
    fi
  else
    test_cmd="bun test $test_dir/"
  fi

  local output
  local exit_code=0
  output=$(cd "$REPO_PATH" && eval "$test_cmd" 2>&1) || exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    log_ok "All $test_count story acceptance test(s) pass after $current_story"
    return 0
  fi

  log_err "Story acceptance tests FAILED after $current_story"
  log_err "A prior story's behavior may have been regressed."
  log_err "Output (last 30 lines):"
  echo "$output" | tail -30

  # Record failure
  jq --arg story "$current_story" --arg ts "$(ts)" '
    .story_test_failures = ((.story_test_failures // []) + [{"after_story": $story, "timestamp": $ts}])
  ' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

  # Handle like regression gate failure
  if [[ "$HEADLESS" == true ]]; then
    log_warn "Story test regression detected (headless) — pausing project"
    jq --arg ts "$(ts)" '.status = "paused" | .updated_at = $ts | .pause_reason = "story_test_regression"' \
      "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    return 1
  else
    log_warn "Story test regression detected. Options:"
    echo "  1) Retry (re-run story to fix regression)"
    echo "  2) Continue (accept regression, proceed)"
    echo "  3) Pause (stop orchestrator)"
    read -r -p "Choice [1-3]: " choice
    case "$choice" in
      1) return 1 ;;  # caller will retry
      2) return 0 ;;  # continue despite failure
      3)
        jq --arg ts "$(ts)" '.status = "paused" | .updated_at = $ts' "$STATE_FILE" > "$STATE_FILE.tmp" \
          && mv "$STATE_FILE.tmp" "$STATE_FILE"
        log_warn "Paused. Resume: scripts/run-project.sh --resume $PROJECT"
        exit 0
        ;;
    esac
  fi

  return 1
}

# =============================================================================
# Doc Sweep (post-project: update 4 documentation layers)
# =============================================================================

run_doc_sweep() {
  local project="$1"
  local prd_path="$2"

  log_info "Doc sweep: scanning 4 layers for $project"

  # Build story summary from completed tasks
  local story_summary
  story_summary=$(jq -r '.userStories[] | select(.passes == true) | "- \(.id): \(.title)"' "$HQ_ROOT/$prd_path" 2>/dev/null) || true
  [[ -z "$story_summary" ]] && { log_warn "Doc sweep: no completed stories found"; return 0; }

  local repo_path="$REPO_PATH"
  local company="$COMPANY"
  local branch="${BRANCH_NAME:-main}"

  local prompt
  prompt="You are running a post-project documentation sweep for project '$project'.

The following stories were completed:
$story_summary

PRD: $prd_path
Repo: $repo_path
Company: $company

Update 4 documentation layers based on what changed:

1. INTERNAL DOCS (team-facing: tech guides, SOPs, manuals, ontology, taxonomy)
   - Path: ${repo_path}/docs/ or similar MDX dirs
   - Check if completed stories introduced new APIs, services, patterns, config not documented
   - Create/update MDX files as needed
   - Only document what actually changed — no boilerplate

2. EXTERNAL DOCS (customer/vendor-facing documentation)
   - Path: ${repo_path}/docs/ or published doc site
   - Check if user-facing features need documentation updates
   - Skip if project has no external surface

3. REPO KNOWLEDGE (agent context)
   - Path: ${repo_path}/.claude/CLAUDE.md and ${repo_path}/.claude/policies/
   - Update CLAUDE.md with new patterns, gotchas, file locations discovered during project
   - Add policies for recurring issues found during execution

4. COMPANY KNOWLEDGE (business knowledge)
   - Path: $HQ_ROOT/companies/${company}/knowledge/
   - This is a SEPARATE git repo — commit here independently
   - cd companies/${company}/knowledge/ && git add -A && git commit -m 'docs: update from $project completion'
   - Update architecture docs, integration docs, process docs as needed

Rules:
- Commit repo docs to the repo branch ($branch)
- Commit company knowledge to the knowledge repo (separate git)
- Do NOT create boilerplate — only document what actually changed
- Do NOT use EnterPlanMode or TodoWrite
- Output JSON: {\"layers_updated\": [\"internal\",\"external\",\"repo_knowledge\",\"company_knowledge\"], \"files_touched\": [], \"summary\": \"1-sentence\"}"

  local flags=(-p --output-format json)

  if [[ "$NO_PERMISSIONS" == true ]]; then
    flags+=(--dangerously-skip-permissions --permission-mode bypassPermissions)
  fi

  if [[ -n "$MODEL" ]]; then
    flags+=(--model "$MODEL")
  fi

  local output_file="$EXEC_DIR/doc-sweep.output.json"
  local stderr_file="$EXEC_DIR/doc-sweep.stderr"

  local cmd=(claude "${flags[@]}" "$prompt")
  local exit_code=0

  cd "$HQ_ROOT" && env -u CLAUDECODE "${cmd[@]}" >"$output_file" 2>"$stderr_file" || exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    log_ok "Doc sweep completed — see $output_file"
    "$AUDIT_SCRIPT" append --event doc_sweep_completed --project "$project" \
      ${company:+--company "$company"} \
      --action "Doc sweep: 4 layers scanned" \
      --result success \
      --session-id "$SESSION_ID" || true
  else
    log_warn "Doc sweep failed (exit=$exit_code) — non-blocking, see $stderr_file"
    "$AUDIT_SCRIPT" append --event doc_sweep_failed --project "$project" \
      ${company:+--company "$company"} \
      --action "Doc sweep failed" \
      --result fail \
      --error "exit=$exit_code" \
      --session-id "$SESSION_ID" || true
  fi

  # Remove legacy flag file
  rm -f "$PROJECT_DIR/doc-sweep-flag.json" 2>/dev/null || true
}

# =============================================================================
# Regression Gate
# =============================================================================

run_regression_gate() {
  local after_story="$1"
  local gates
  gates=$(jq -r '.metadata.qualityGates // [] | .[]' "$PRD_PATH" 2>/dev/null) || return 0
  [[ -z "$gates" ]] && return 0
  [[ -z "$REPO_PATH" || ! -d "$REPO_PATH" ]] && return 0

  log_info "Running regression gates after $after_story..."

  # Baseline file captures pre-existing error counts at project start
  local baseline_file="$PROJECT_DIR/regression-baseline.json"

  local gate_passed=true
  while IFS= read -r gate; do
    [[ -z "$gate" ]] && continue
    log "  Gate: $gate"
    local output
    local exit_code=0
    output=$(cd "$REPO_PATH" && eval "$gate" 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
      log_ok "  Passed: $gate"
      continue
    fi

    # Gate failed — check if errors are pre-existing (baseline comparison)
    # Count error lines (heuristic: lines containing "error" case-insensitive)
    local err_count
    err_count=$(echo "$output" | grep -ci "error" 2>/dev/null) || err_count=0
    local gate_key
    gate_key=$(echo "$gate" | tr ' ' '_')

    # Capture baseline per-gate (lazy: only when this gate first fails).
    # Defect A fix: the outer guard used to check "file does not exist", which
    # meant only the FIRST gate to fail ever got a baseline — every later gate
    # silently fell back to `// 0` and reported phantom regressions.
    if ! jq -e --arg key "$gate_key" 'has($key)' "$baseline_file" >/dev/null 2>&1; then
      [[ -f "$baseline_file" ]] || echo "{}" > "$baseline_file"
      log "  Capturing baseline error count for $gate..."
      # Run gate against baseBranch to get pre-existing error count.
      # When using a worktree, ORIGINAL_REPO_PATH stays on baseBranch — no checkout needed.
      # When in-place, fall back to stash/checkout on REPO_PATH.
      local baseline_repo="${ORIGINAL_REPO_PATH:-$REPO_PATH}"
      local base_err_count=0
      local base_exit=0
      local base_output=""
      if [[ -n "$ORIGINAL_REPO_PATH" ]]; then
        # Worktree mode: original repo is already on baseBranch
        base_output=$(cd "$baseline_repo" && eval "$gate" 2>&1) || base_exit=$?
      else
        # In-place mode: stash, checkout baseBranch, measure, restore
        local base_branch
        base_branch=$(jq -r '.metadata.baseBranch // "main"' "$PRD_PATH" 2>/dev/null || echo "main")
        local current_branch
        current_branch=$(cd "$REPO_PATH" && git branch --show-current)
        local stashed=false
        if (cd "$REPO_PATH" && ! git diff --quiet HEAD 2>/dev/null); then
          (cd "$REPO_PATH" && git stash push -q 2>/dev/null) && stashed=true
        fi
        base_output=$(cd "$REPO_PATH" && git checkout "$base_branch" -q 2>/dev/null && eval "$gate" 2>&1) || base_exit=$?
        (cd "$REPO_PATH" && git checkout "$current_branch" -q 2>/dev/null) || log_warn "  Failed to checkout back to $current_branch"
        [[ "$stashed" == true ]] && (cd "$REPO_PATH" && git stash pop -q 2>/dev/null) || true
      fi
      if [[ $base_exit -ne 0 ]]; then
        base_err_count=$(echo "$base_output" | grep -ci "error" 2>/dev/null) || base_err_count=0
      fi
      # Merge new key into existing baseline object (do NOT overwrite the file,
      # or we wipe previously-captured keys for other gates).
      jq --arg key "$gate_key" --argjson count "$base_err_count" \
        '. + {($key): $count}' "$baseline_file" > "$baseline_file.tmp" \
        && mv "$baseline_file.tmp" "$baseline_file"
    fi

    # Defense-in-depth: if the capture block above didn't write our key for any
    # reason, refuse to compare rather than silently fall back to phantom-zero.
    if ! jq -e --arg key "$gate_key" 'has($key)' "$baseline_file" >/dev/null 2>&1; then
      log_err "  No baseline for $gate_key — refusing to compare (would produce phantom-zero regression)"
      gate_passed=false
      continue
    fi
    local baseline_count
    baseline_count=$(jq -r --arg key "$gate_key" '.[$key]' "$baseline_file")

    if [[ "$err_count" -le "$baseline_count" ]]; then
      log_warn "  $gate: $err_count errors (≤ baseline $baseline_count — pre-existing, not a regression)"
    else
      log_err "  REGRESSION: $gate — $err_count errors (baseline: $baseline_count, +$((err_count - baseline_count)) new)"
      gate_passed=false
    fi
  done <<< "$gates"

  # Record gate result
  jq --arg story "$after_story" --arg ts "$(ts)" --argjson pass "$([[ "$gate_passed" == true ]] && echo true || echo false)" '
    .regression_gates += [{"after_story": $story, "passed": $pass, "timestamp": $ts}]
  ' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

  if [[ "$gate_passed" == false ]]; then
    echo ""
    echo -e "${RED}Regression gate failed after $after_story.${NC}"
    if [[ -t 0 ]]; then
      echo "Options:"
      echo "  1) Continue anyway"
      echo "  2) Pause (resume later with --resume)"
      echo "  3) Abort"
      read -rp "Choice [1-3]: " choice
      case "$choice" in
        1) return 0 ;;
        2) jq --arg ts "$(ts)" '.status = "paused" | .updated_at = $ts' "$STATE_FILE" > "$STATE_FILE.tmp" \
             && mv "$STATE_FILE.tmp" "$STATE_FILE"
           log_warn "Paused. Resume with: scripts/run-project.sh --resume $PROJECT"
           exit 0 ;;
        *) exit 1 ;;
      esac
    else
      log_warn "Non-interactive: auto-pausing after regression failure."
      jq --arg ts "$(ts)" '.status = "paused" | .updated_at = $ts' "$STATE_FILE" > "$STATE_FILE.tmp" \
        && mv "$STATE_FILE.tmp" "$STATE_FILE"
      exit 1
    fi
  fi
}

# =============================================================================
# Project Reanchor
# =============================================================================

run_project_reanchor() {
  local project_name="$1"
  local completed_count="$2"
  local reanchor_num=$((completed_count / 3))
  local reanchor_file="$EXEC_DIR/reanchor-${reanchor_num}.md"

  log_info "Project reanchor #${reanchor_num}: evaluating remaining stories after ${completed_count} completions"

  # Build context: recent outputs + codex reviews
  local recent_outputs=""
  local recent_reviews=""
  for f in "$EXEC_DIR"/*.output.json; do
    [[ -f "$f" ]] && recent_outputs="$recent_outputs $(basename "$f")"
  done
  for f in "$EXEC_DIR"/*.codex-review.md; do
    [[ -f "$f" ]] && recent_reviews="$recent_reviews $(basename "$f")"
  done

  local reanchor_prompt="You are a project reanchor agent. Your job is to evaluate whether remaining story specs are still valid after ${completed_count} stories have been completed.

Read the PRD at: ${PRD_PATH}
Read progress at: ${EXEC_DIR}/../../progress.txt (if exists)

For each remaining story (passes != true), evaluate:
1. Are acceptance criteria still accurate given what was implemented?
2. Did a completed story partially address this story's work?
3. Any new required work discovered from execution?
4. Is this story now unnecessary?

Output a markdown report with:
- Summary of findings
- Per-story assessment (keep/modify/remove recommendation)
- Specific AC changes needed (if any)
- New work discovered (if any)

IMPORTANT: Do NOT modify the PRD. Only write your analysis report.
Write your report to: ${reanchor_file}"

  # Best-effort, non-blocking — don't fail the loop
  timeout 300 claude -p "$reanchor_prompt" \
    --output-format json \
    --max-turns 10 \
    > "$EXEC_DIR/reanchor-${reanchor_num}.output.json" 2>&1 || {
    log_warn "Project reanchor #${reanchor_num} failed or timed out (non-blocking)"
    return 0
  }

  if [[ -f "$reanchor_file" ]]; then
    log_ok "Reanchor report written: $reanchor_file"
  else
    log_warn "Reanchor agent completed but no report file found"
  fi

  return 0
}

# =============================================================================
# Failure Handling
# =============================================================================

handle_failure() {
  local story_id="$1"
  local attempt="$2"

  if [[ -t 0 ]]; then
    echo ""
    echo -e "${RED}FAILED: $story_id (attempt $attempt)${NC}"
    echo -e "${DIM}Logs: $EXEC_DIR/${story_id}.stderr${NC}"
    echo ""
    echo "Options:"
    echo "  1) Retry this story"
    echo "  2) Skip and continue"
    echo "  3) Pause (resume with --resume)"
    echo "  4) Abort"
    read -rp "Choice [1-4]: " choice
    case "$choice" in
      1) return 0 ;;  # retry
      2) return 2 ;;  # skip
      3) return 3 ;;  # pause
      *) exit 1 ;;
    esac
  else
    # Non-interactive: auto-retry once, then skip
    if [[ "$attempt" -lt 2 ]]; then
      log_warn "Auto-retrying $story_id (attempt $((attempt+1)))..."
      return 0  # retry
    else
      log_warn "Auto-skipping $story_id after $attempt attempts."
      return 2  # skip
    fi
  fi
}

# =============================================================================
# Update State After Story
# =============================================================================

update_state_completed() {
  local story_id="$1"
  local commit_sha="$2"
  local files_changed="$3"
  # Cross-repo metadata pulled from globals set by resolve_story_attribution().
  # Defaults keep this function safe to call from legacy/test contexts that
  # haven't run the attribution resolver.
  local cross_repo="${ATTR_CROSS_REPO:-false}"
  local sidecar_rel="${ATTR_SIDECAR_REL:-}"

  read_prd_stats

  # Defect B/C fix (US-019/US-020): upsert-by-id with "prefer real SHA over
  # no-commit" merge. Two legitimate write sites exist (sequential + retry);
  # append-only produced duplicate entries where the later "no-commit" write
  # shadowed an earlier real SHA for tail-reading audits. Upsert collapses
  # duplicates; the merge rule protects against an unlucky write order.
  jq \
    --arg id "$story_id" \
    --arg ts "$(ts)" \
    --arg sha "$commit_sha" \
    --argjson files "$files_changed" \
    --argjson cross_repo "$cross_repo" \
    --arg sidecar_rel "$sidecar_rel" \
    --argjson total "$TOTAL" \
    --argjson completed "$COMPLETED" \
  '
    .completed_tasks = (
      (.completed_tasks // []) as $ct
      | (($ct | map(select(.id == $id)))[0] // {}) as $prev
      | ($ct | map(select(.id != $id))) as $rest
      | $rest + [{
          id: $id,
          completed_at: $ts,
          commit_sha: (
            if $sha == "no-commit"
               and (($prev.commit_sha // "") != "")
               and ($prev.commit_sha != "no-commit")
            then $prev.commit_sha
            else $sha
            end
          ),
          files_changed: $files,
          cross_repo: $cross_repo,
          attribution_sidecar: $sidecar_rel
        }]
    ) |
    .current_tasks = [(.current_tasks // [])[] | select(.id != $id)] |
    .progress.total = $total |
    .progress.completed = $completed |
    .progress.failed = (.failed_tasks | length) |
    .progress.in_progress = (.current_tasks | length) |
    .updated_at = $ts
  ' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

update_state_failed() {
  local story_id="$1"
  local error="$2"

  jq \
    --arg id "$story_id" \
    --arg ts "$(ts)" \
    --arg err "$error" \
  '
    .failed_tasks += [{"id": $id, "error": $err, "timestamp": $ts}] |
    .retry_queue += [$id] |
    .current_tasks = [(.current_tasks // [])[] | select(.id != $id)] |
    .progress.failed = (.failed_tasks | length) |
    .progress.in_progress = (.current_tasks | length) |
    .updated_at = $ts
  ' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# Add a task to current_tasks[] with PID and worktree info (for swarm mode)
update_state_add_task() {
  local story_id="$1"
  local pid="$2"
  local worktree_path="${3:-}"

  jq --arg id "$story_id" \
     --arg pid "$pid" \
     --arg wt "$worktree_path" \
     --arg ts "$(ts)" \
     --arg sid "$SESSION_ID" \
  '
    .current_tasks = ((.current_tasks // []) | map(select(.id != $id))) + [{
      "id": $id,
      "started_at": $ts,
      "pid": (if $pid == "" then null else ($pid | tonumber) end),
      "worktree_path": $wt,
      "checkedOutBy": {"pid": (if $pid == "" then null else ($pid | tonumber) end), "startedAt": $ts, "sessionId": $sid}
    }] |
    .progress.in_progress = (.current_tasks | length) |
    .updated_at = $ts
  ' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# Remove a task from current_tasks[] (on completion or failure)
update_state_remove_task() {
  local story_id="$1"
  jq --arg id "$story_id" --arg ts "$(ts)" '
    .current_tasks = [(.current_tasks // [])[] | select(.id != $id)] |
    .progress.in_progress = (.current_tasks | length) |
    .updated_at = $ts
  ' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

update_state_current() {
  local story_id="$1"
  # In sequential mode, checkout_story already added to current_tasks[].
  # Refresh started_at + PID on every call so retries don't leave stale data.
  # Defect C fix: previously this only touched started_at, so the check-in
  # printer would keep reading a stale .pid from a prior run/session (the
  # "PID 91542 (exited)" sticky-display bug). Now we actively stamp the
  # orchestrator PID + clear the legacy .pid slot on each attempt.
  jq --arg id "$story_id" --arg ts "$(ts)" --arg pid "$$" --arg sid "$SESSION_ID" '
    .current_tasks = [(.current_tasks // [])[] |
      if .id == $id then
        .started_at = $ts
        | .pid = ($pid | tonumber)
        | .checkedOutBy = {"pid": ($pid | tonumber), "startedAt": $ts, "sessionId": $sid}
      else . end
    ] |
    .progress.in_progress = (.current_tasks | length) |
    .updated_at = $ts
  ' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# =============================================================================
# Linear Sync (best-effort, never blocks execution)
# =============================================================================

sync_linear_start() {
  local story_id="$1"

  # Get Linear issue ID from story
  local linear_issue_id
  linear_issue_id=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .linearIssueId // empty' "$PRD_PATH" 2>/dev/null) || return 0
  [[ -z "$linear_issue_id" ]] && return 0

  # Get Linear credentials path from metadata
  local creds_path
  creds_path=$(jq -r '.metadata.linearCredentials // empty' "$PRD_PATH" 2>/dev/null) || return 0
  [[ -z "$creds_path" ]] && return 0

  local creds_file="$HQ_ROOT/$creds_path"
  [[ -f "$creds_file" ]] || return 0

  # Cross-company guard: verify creds match company
  local company
  company=$(jq -r '.metadata.company // empty' "$PRD_PATH" 2>/dev/null) || return 0
  if [[ -n "$company" ]] && ! echo "$creds_path" | grep -q "companies/$company/"; then
    log_warn "Linear creds path doesn't match company '$company' — skipping Linear sync"
    return 0
  fi

  local api_key
  api_key=$(jq -r '.apiKey // empty' "$creds_file" 2>/dev/null) || return 0
  [[ -z "$api_key" ]] && return 0

  # Get In Progress state ID from config
  local config_dir
  config_dir=$(dirname "$creds_file")
  local config_file="$config_dir/config.json"
  [[ -f "$config_file" ]] || return 0

  local in_progress_id
  in_progress_id=$(jq -r '.states.in_progress // .states.InProgress // empty' "$config_file" 2>/dev/null) || return 0
  [[ -z "$in_progress_id" ]] && return 0

  # Set issue to In Progress
  curl -sf -X POST https://api.linear.app/graphql \
    -H "Content-Type: application/json" \
    -H "Authorization: $api_key" \
    -d "{\"query\": \"mutation { issueUpdate(id: \\\"$linear_issue_id\\\", input: { stateId: \\\"$in_progress_id\\\" }) { success } }\"}" \
    >/dev/null 2>&1 || true

  # Comment on issue
  curl -sf -X POST https://api.linear.app/graphql \
    -H "Content-Type: application/json" \
    -H "Authorization: $api_key" \
    -d "{\"query\": \"mutation { commentCreate(input: { issueId: \\\"$linear_issue_id\\\", body: \\\"Started by HQ orchestrator — task in progress.\\\" }) { success } }\"}" \
    >/dev/null 2>&1 || true

  log_info "Linear: $story_id → In Progress"
}

sync_linear_done() {
  local story_id="$1"

  local linear_issue_id
  linear_issue_id=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .linearIssueId // empty' "$PRD_PATH" 2>/dev/null) || return 0
  [[ -z "$linear_issue_id" ]] && return 0

  local creds_path
  creds_path=$(jq -r '.metadata.linearCredentials // empty' "$PRD_PATH" 2>/dev/null) || return 0
  [[ -z "$creds_path" ]] && return 0

  local creds_file="$HQ_ROOT/$creds_path"
  [[ -f "$creds_file" ]] || return 0

  local api_key
  api_key=$(jq -r '.apiKey // empty' "$creds_file" 2>/dev/null) || return 0
  [[ -z "$api_key" ]] && return 0

  local config_dir
  config_dir=$(dirname "$creds_file")
  local config_file="$config_dir/config.json"
  [[ -f "$config_file" ]] || return 0

  local done_id
  done_id=$(jq -r '.states.done // .states.Done // empty' "$config_file" 2>/dev/null) || return 0
  [[ -z "$done_id" ]] && return 0

  curl -sf -X POST https://api.linear.app/graphql \
    -H "Content-Type: application/json" \
    -H "Authorization: $api_key" \
    -d "{\"query\": \"mutation { issueUpdate(id: \\\"$linear_issue_id\\\", input: { stateId: \\\"$done_id\\\" }) { success } }\"}" \
    >/dev/null 2>&1 || true

  curl -sf -X POST https://api.linear.app/graphql \
    -H "Content-Type: application/json" \
    -H "Authorization: $api_key" \
    -d "{\"query\": \"mutation { commentCreate(input: { issueId: \\\"$linear_issue_id\\\", body: \\\"Completed by HQ orchestrator.\\\" }) { success } }\"}" \
    >/dev/null 2>&1 || true
}

# =============================================================================
# Orchestrator Writes Passes (replaces execute-task's prd.json write)
# =============================================================================

# Parse the claude -p output JSON to determine pass/fail, then write passes: true
orchestrator_write_passes() {
  local story_id="$1"
  local checkout_started_at="${2:-}"  # ISO8601 timestamp when story execution began
  local output_file="$EXEC_DIR/${story_id}.output.json"

  # Early exit: already passed (execute-task may have written it directly)
  local already_passed
  already_passed=$(jq -r --arg id "$story_id" '
    .userStories[] | select(.id == $id) | .passes
  ' "$PRD_PATH" 2>/dev/null) || true

  if [[ "$already_passed" == "true" ]]; then
    return 0
  fi

  local status_from_output=""
  local detection_layer=""

  # --- Layer 1: Parse structured JSON from claude -p output ---
  # claude --output-format json puts the final response text in .result
  if [[ -f "$output_file" ]]; then
    status_from_output=$(jq -r '
      if .status then .status
      elif .result then (.result | if type == "string" then (fromjson? // {}) else . end | .status // empty)
      else empty end
    ' "$output_file" 2>/dev/null) || true
    [[ -n "$status_from_output" ]] && detection_layer="Layer 1 (.result JSON parse)"
  fi

  # --- Layer 2: Full-file scan for task_id + status pair ---
  # The structured JSON may have been emitted mid-conversation inside a content[].text block
  # but not in the final .result field. Search the raw file for both markers.
  # Note: claude -p --output-format json produces an array of conversation messages, and
  # the task completion JSON is often inside escaped text within a message content block.
  if [[ -z "$status_from_output" && -f "$output_file" ]]; then
    # Search for task_id matching this story paired with completed status anywhere in the file
    # The JSON may be inside escaped strings (e.g. \"task_id\": \"US-003\")
    if grep -q "task_id.*${story_id}" "$output_file" 2>/dev/null \
       && grep -q "\"status\".*\"completed\"\|status.*completed" "$output_file" 2>/dev/null; then
      # Verify the pair appears in the same text block (within 500 chars)
      # Extract all text content and look for the JSON object
      local found_pair
      found_pair=$(jq -r '
        [.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text] |
        .[] | select(test("task_id.*'"$story_id"'")) | select(test("\"status\".*\"completed\""))
      ' "$output_file" 2>/dev/null | head -1) || true
      if [[ -n "$found_pair" ]]; then
        status_from_output="completed"
        detection_layer="Layer 2 (full-file scan: task_id + status in assistant message text)"
      fi
    fi
  fi

  # --- Layer 3: Git heuristic — commits + declared files touched ---
  # If the sub-agent committed work touching declared files, the story likely completed
  if [[ -z "$status_from_output" && -n "$checkout_started_at" && -n "$REPO_PATH" ]] && is_git_repo "$REPO_PATH"; then
    local recent_commits=0
    recent_commits=$(git -C "$REPO_PATH" log --oneline --after="$checkout_started_at" 2>/dev/null | wc -l | tr -d ' ') || true

    if [[ "${recent_commits:-0}" -gt 0 ]]; then
      local story_files_json
      story_files_json=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .files // []' "$PRD_PATH" 2>/dev/null) || true
      local story_files_count
      story_files_count=$(echo "$story_files_json" | jq 'length' 2>/dev/null) || true

      if [[ "${story_files_count:-0}" -gt 0 ]]; then
        local touched_count=0
        while IFS= read -r f; do
          [[ -z "$f" ]] && continue
          if git -C "$REPO_PATH" log --oneline --after="$checkout_started_at" -- "$f" 2>/dev/null | grep -q .; then
            touched_count=$((touched_count + 1))
          fi
        done < <(echo "$story_files_json" | jq -r '.[]' 2>/dev/null)

        if [[ "$touched_count" -gt 0 ]]; then
          status_from_output="completed"
          detection_layer="Layer 3 (git heuristic: $recent_commits commits, $touched_count/${story_files_count} declared files touched)"
        fi
      elif [[ "${recent_commits:-0}" -ge 2 ]]; then
        # No declared files but multiple commits — likely real work
        status_from_output="completed"
        detection_layer="Layer 3 (git heuristic: $recent_commits commits, no declared files)"
      fi
    fi
  fi

  # --- Write passes if any layer detected completion ---
  if [[ "$status_from_output" == "completed" ]]; then
    jq --arg id "$story_id" '
      (.userStories[] | select(.id == $id)).passes = true
    ' "$PRD_PATH" > "$PRD_PATH.tmp" && mv "$PRD_PATH.tmp" "$PRD_PATH"
    log_ok "Orchestrator set passes=true for $story_id [$detection_layer]"
  else
    log_warn "passes detection: no completion signal found for $story_id (all 3 layers failed)"
  fi
}

# =============================================================================
# Check-In Status (periodic monitoring for both sequential and swarm modes)
# =============================================================================

# Print current execution status — story IDs, PIDs, elapsed times, output sizes
print_checkin_status() {
  local now
  now=$(date +%s)

  echo ""
  echo -e "${BOLD}--- Check-In [$(date +%H:%M:%S)] ---${NC}"

  # Read current_tasks from state
  local task_count
  task_count=$(jq '.current_tasks // [] | length' "$STATE_FILE" 2>/dev/null) || task_count=0

  if [[ "$task_count" -eq 0 ]]; then
    echo -e "  ${DIM}No active tasks${NC}"
  else
    read_prd_stats 2>/dev/null || true
    echo -e "Active: ${BLUE}${task_count}${NC} | Completed: ${GREEN}${COMPLETED}${NC}/${TOTAL}"
    echo ""

    local i=0
    while [[ $i -lt $task_count ]]; do
      local sid pid start_ts
      sid=$(jq -r --argjson idx "$i" '.current_tasks[$idx].id // "?"' "$STATE_FILE" 2>/dev/null) || true
      pid=$(jq -r --argjson idx "$i" '.current_tasks[$idx].pid // .current_tasks[$idx].checkedOutBy.pid // "?"' "$STATE_FILE" 2>/dev/null) || true
      start_ts=$(jq -r --argjson idx "$i" '.current_tasks[$idx].started_at // empty' "$STATE_FILE" 2>/dev/null) || true

      local elapsed_str="?"
      if [[ -n "$start_ts" ]]; then
        local start_epoch
        start_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$start_ts" "+%s" 2>/dev/null) || true
        if [[ -n "$start_epoch" ]]; then
          local elapsed=$(( now - start_epoch ))
          elapsed_str="$((elapsed / 60))m$((elapsed % 60))s"
        fi
      fi

      local title
      title=$(get_story_title "$sid" 2>/dev/null) || title="?"

      # Output file sizes (proxy for progress)
      local out_size=0 err_size=0
      [[ -f "$EXEC_DIR/${sid}.output.json" ]] && out_size=$(wc -c < "$EXEC_DIR/${sid}.output.json" 2>/dev/null | tr -d ' ') || true
      [[ -f "$EXEC_DIR/${sid}.stderr" ]] && err_size=$(wc -c < "$EXEC_DIR/${sid}.stderr" 2>/dev/null | tr -d ' ') || true

      local pid_status=""
      if [[ "$pid" != "?" ]] && kill -0 "$pid" 2>/dev/null; then
        pid_status="${GREEN}alive${NC}"
      elif [[ "$pid" != "?" ]]; then
        pid_status="${RED}exited${NC}"
      fi

      echo -e "  ${BOLD}${sid}${NC} — ${title}"
      echo -e "    PID: ${pid} (${pid_status}) | Elapsed: ${elapsed_str} | Output: ${out_size}b | Stderr: ${err_size}b"

      i=$((i + 1))
    done
  fi

  echo -e "${DIM}──────────────────────────────────${NC}"
  echo ""
}

# =============================================================================
# Swarm Functions
# =============================================================================

# Parallel indexed arrays for tracking swarm members (bash 3.2 compat — no associative arrays)
SWARM_STORY_IDS=()
SWARM_PIDS=()
SWARM_WORKTREES=()
SWARM_START_TIMES=()
SWARM_DONE=()
PENDING_REGRESSION_GATE=""

# Launch a story as a background process. Sets LAST_BG_PID.
run_story_background() {
  local story_id="$1"
  local story_worktree="${2:-}"

  local story_title story_labels story_files model_hint
  story_title=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .title' "$PRD_PATH" 2>/dev/null) || true
  story_labels=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .labels // [] | join(", ")' "$PRD_PATH" 2>/dev/null) || true
  story_files=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .files // [] | join(", ")' "$PRD_PATH" 2>/dev/null) || true
  model_hint=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .model_hint // empty' "$PRD_PATH" 2>/dev/null) || true

  local worktree_note=""
  [[ -n "$story_worktree" ]] && worktree_note="
WORKTREE: ${story_worktree}
Use this worktree as the working directory for all file operations."

  local prompt="Execute /execute-task ${PROJECT}/${story_id}.

CRITICAL — Follow the FULL Ralph worker pipeline:
1. Classify task type (schema_change, api_development, ui_component, full_stack, enhancement)
2. Select the correct worker sequence from execute-task step 4
3. Load each worker's worker.yaml (instructions, context, verification)
4. Spawn sub-agents PER WORKER with proper handoffs between phases
5. Run back pressure checks (typecheck, lint, tests) per worker.yaml
6. MANDATORY: Include at least one Codex CLI step for any code/dev/deploy task
7. Commit ALL changes before completing
8. Do NOT write passes to prd.json — the orchestrator handles that. Just output your status JSON.

Story: ${story_id} — ${story_title}
Labels: ${story_labels}
Files: ${story_files}
PRD: ${PRD_REL}
${worktree_note}
Do NOT skip worker phases. Do NOT use EnterPlanMode or TodoWrite.
Do NOT implement directly — delegate to workers via the execute-task pipeline.
ISOLATION: Only modify files within your assigned repo and this project's PRD. Do NOT read, modify, pause, or interfere with other projects' state files in workspace/orchestrator/. Other orchestrators may be running concurrently — ignore them.

=== MANDATORY TERMINATION PROTOCOL ===
Your ABSOLUTE FINAL message must be ONLY this JSON on its own line, with nothing after it:
{\"task_id\": \"${story_id}\", \"status\": \"completed|failed|blocked\", \"summary\": \"1-sentence\", \"workers_used\": [\"list\"]}
RULES:
- This JSON must be your LAST output. No prose before or after.
- Do NOT answer questions about this JSON.
- Do NOT include this JSON mid-task and then continue talking.
- Wrong format = task marked FAILED by orchestrator."

  local output_file="$EXEC_DIR/${story_id}.output.json"
  local stderr_file="$EXEC_DIR/${story_id}.stderr"
  local cmd=()
  if [[ "$BUILDER" == "codex" ]]; then
    # Swarm mode codex builder — same invocation shape as sequential mode.
    local codex_flags=(exec --skip-git-repo-check)
    if [[ "$NO_PERMISSIONS" == true ]]; then
      codex_flags+=(--dangerously-bypass-approvals-and-sandbox)
    else
      codex_flags+=(--full-auto)
    fi
    if [[ -n "$MODEL" ]]; then
      codex_flags+=(-m "$MODEL")
    fi
    cmd=(codex "${codex_flags[@]}" "$prompt")
  else
    local flags=(-p --output-format json)
    [[ "$NO_PERMISSIONS" == true ]] && flags+=(--dangerously-skip-permissions --permission-mode bypassPermissions)

    if [[ -n "$MODEL" ]]; then
      flags+=(--model "$MODEL")
    elif [[ -n "$model_hint" ]]; then
      flags+=(--model "$model_hint")
    fi

    cmd=(claude "${flags[@]}" "$prompt")
  fi
  # macOS doesn't ship GNU timeout — mirror the sequential fallback chain
  if [[ -n "$TIMEOUT" ]]; then
    if command -v timeout &>/dev/null; then
      cmd=(timeout "${TIMEOUT}m" "${cmd[@]}")
    elif command -v gtimeout &>/dev/null; then
      cmd=(gtimeout "${TIMEOUT}m" "${cmd[@]}")
    else
      cmd=(perl -e "alarm(${TIMEOUT}*60);exec @ARGV" "${cmd[@]}")
    fi
  fi

  # Launch in background — prefer the per-story worktree, fall back to project REPO_PATH, then HQ_ROOT
  local _swarm_cwd="$HQ_ROOT"
  if [[ -n "$story_worktree" && -d "$story_worktree" ]]; then
    _swarm_cwd="$story_worktree"
  elif [[ -n "${REPO_PATH:-}" && -d "$REPO_PATH" ]]; then
    _swarm_cwd="$REPO_PATH"
  fi

  # Seed codex phase file before launch so monitor-project.sh has something
  # to read from the first refresh.
  if [[ "$BUILDER" == "codex" ]]; then
    codex_heartbeat_init "$story_id" "$PROJECT"
  fi

  (cd "$_swarm_cwd" && env -u CLAUDECODE HQ_ROOT="$HQ_ROOT" HQ_WORKSPACE_DIR="$HQ_ROOT/workspace" "${cmd[@]}" >"$output_file" 2>"$stderr_file") &
  LAST_BG_PID=$!

  # Spawn a heartbeat poller tied to the codex PID. Exits when codex dies,
  # so monitor_swarm_loop doesn't need to clean it up explicitly —
  # process_swarm_completion still calls codex_heartbeat_finalize for the
  # terminal status write.
  if [[ "$BUILDER" == "codex" ]]; then
    codex_heartbeat_loop "$story_id" "$_swarm_cwd" "$LAST_BG_PID" &
  fi
}

# Create a per-story worktree for swarm isolation. Sets STORY_WORKTREE_PATH.
# Each story gets its own unique branch (project-branch/story-slug) to avoid
# git's "branch already checked out" error when the project worktree exists.
ensure_story_worktree() {
  local story_id="$1"
  local project_branch="${BRANCH_NAME:-main}"

  local story_slug
  story_slug=$(echo "$story_id" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
  local branch_slug="${project_branch//\//-}"
  local base_repo="${ORIGINAL_REPO_PATH:-$REPO_PATH}"
  local wt_path="${base_repo}-wt-${branch_slug}-${story_slug}"
  # Each story worktree gets its own branch to avoid "already checked out" conflicts
  # Use -- separator (not /) to avoid git ref tree conflict with the project branch
  local story_branch="${project_branch}--${story_slug}"

  STORY_WORKTREE_PATH=""

  # Check if already exists
  if [[ -d "$wt_path" ]]; then
    STORY_WORKTREE_PATH="$wt_path"
    return 0
  fi

  [[ -z "$base_repo" || ! -d "$base_repo" ]] && return 1

  # Determine the commit to branch from: project branch if it exists, else base branch
  local start_point="${BASE_BRANCH:-main}"
  if git -C "$base_repo" show-ref --verify --quiet "refs/heads/${project_branch}" 2>/dev/null; then
    start_point="$project_branch"
  fi

  # Delete stale story branch if it exists (from a previous failed run)
  git -C "$base_repo" branch -D "$story_branch" 2>/dev/null || true

  # Create worktree with unique per-story branch
  git -C "$base_repo" worktree add -b "$story_branch" "$wt_path" "$start_point" 2>/dev/null || {
    log_err "Failed to create story worktree for $story_id at $wt_path"
    return 1
  }

  # Install deps if needed
  if [[ -f "$wt_path/bun.lockb" || -f "$wt_path/bun.lock" ]] && command -v bun >/dev/null 2>&1; then
    (cd "$wt_path" && bun install --frozen-lockfile 2>/dev/null) || true
  elif [[ -f "$wt_path/package-lock.json" ]]; then
    (cd "$wt_path" && npm ci 2>/dev/null) || true
  fi

  STORY_WORKTREE_PATH="$wt_path"
  log_ok "Story worktree ready: $wt_path ($story_id)"
}

# Pre-acquire file locks for a story BEFORE launching background process
preacquire_swarm_locks() {
  local story_id="$1"
  local pid="$2"

  [[ -z "$REPO_PATH" || ! -d "$REPO_PATH" ]] && return 0

  local lock_file="$REPO_PATH/.file-locks.json"
  [[ -f "$lock_file" ]] || echo '{"version":1,"locks":[]}' > "$lock_file"

  local story_files
  story_files=$(jq -r --arg id "$story_id" '
    .userStories[] | select(.id == $id) | .files // [] | .[]
  ' "$PRD_PATH" 2>/dev/null) || return 0
  [[ -z "$story_files" ]] && return 0

  local now_ts
  now_ts=$(ts)

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    jq --arg file "$f" \
       --arg project "$PROJECT" \
       --arg story "$story_id" \
       --arg pid "$pid" \
       --arg ts "$now_ts" \
    '
      .locks = ((.locks // []) | map(select(.file != $file or .owner.story != $story))) + [{
        "file": $file,
        "owner": {"project": $project, "story": $story, "pid": ($pid | tonumber)},
        "acquired_at": $ts
      }]
    ' "$lock_file" > "$lock_file.tmp" && mv "$lock_file.tmp" "$lock_file"
  done <<< "$story_files"
}

# Release file locks for a story
release_swarm_locks() {
  local story_id="$1"

  [[ -z "$REPO_PATH" || ! -d "$REPO_PATH" ]] && return 0

  local lock_file="$REPO_PATH/.file-locks.json"
  [[ -f "$lock_file" ]] || return 0

  jq --arg story "$story_id" '
    .locks = [(.locks // [])[] | select(.owner.story != $story)]
  ' "$lock_file" > "$lock_file.tmp" && mv "$lock_file.tmp" "$lock_file"
}

# Process a completed swarm member — validate git, check passes, update state
process_swarm_completion() {
  local story_id="$1"
  local exit_code="$2"
  local duration="$3"
  local worktree_path="${4:-}"
  local start_epoch="${5:-}"

  local saved_repo="$REPO_PATH"
  [[ -n "$worktree_path" && -d "$worktree_path" ]] && REPO_PATH="$worktree_path"

  # Finalize codex phase file if this story was run under the codex builder.
  # No-op for Claude builder (owner check guards the file).
  codex_heartbeat_finalize "$story_id" "$exit_code"

  validate_git_state "$story_id"
  run_codex_review "$story_id"

  # Orchestrator writes passes based on output JSON — pass checkout timestamp for Layer 3 git heuristic
  local checkout_ts_iso=""
  [[ -n "$start_epoch" ]] && checkout_ts_iso=$(date -u -r "$start_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || true
  orchestrator_write_passes "$story_id" "$checkout_ts_iso"

  # Check source of truth
  local passes
  passes=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .passes' "$PRD_PATH")

  REPO_PATH="$saved_repo"

  if [[ "$passes" == "true" ]]; then
    local commit_sha files_changed
    local check_repo="$saved_repo"
    [[ -n "$worktree_path" && -d "$worktree_path" ]] && check_repo="$worktree_path"
    commit_sha=$(git -C "$check_repo" rev-parse --short HEAD 2>/dev/null || echo "n/a")
    files_changed=$(git -C "$check_repo" diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null \
      | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null) || true
    # Validate JSON — protects --argjson in update_state_completed from crash
    if [[ -z "$files_changed" ]] || ! jq -e . <<< "$files_changed" &>/dev/null; then
      files_changed="[]"
    fi

    update_state_completed "$story_id" "$commit_sha" "$files_changed"
    release_checkout "$story_id"
    release_swarm_locks "$story_id"
    run_story_tests "$story_id" || true  # non-blocking in swarm — logged + state recorded

    local story_title
    story_title=$(get_story_title "$story_id")
    echo "[$(ts)] $story_id: $story_title — completed in swarm (${duration}s) [$commit_sha]" >> "$PROGRESS_FILE"

    "$AUDIT_SCRIPT" append --event story_completed --project "$PROJECT" \
      ${COMPANY:+--company "$COMPANY"} \
      --story-id "$story_id" \
      --action "$(get_story_title "$story_id") (swarm)" \
      --result success \
      --duration-ms $(( duration * 1000 )) \
      --session-id "$SESSION_ID" || true

    sync_linear_done "$story_id"
    log_ok "$story_id completed in swarm (${duration}s) [$commit_sha]"

    completed_this_run=$((completed_this_run + 1))

    # Check if regression gate is due
    if (( completed_this_run % REGRESSION_INTERVAL == 0 && completed_this_run > 0 )); then
      PENDING_REGRESSION_GATE="$story_id"
    fi
  else
    log_err "$story_id: passes still false in swarm (exit=$exit_code, ${duration}s)"
    update_state_failed "$story_id" "passes not set in swarm (exit=$exit_code)"
    release_checkout "$story_id"
    release_swarm_locks "$story_id"
    _swarm_retry_inc "$story_id"
    local retry_count
    retry_count=$(_swarm_retry_get "$story_id")
    if (( retry_count >= 2 )); then
      retry_queue+=("$story_id")
      echo "[$(ts)] $story_id: FAILED in swarm (max retries) — queued for end-of-run retry" >> "$PROGRESS_FILE"
    else
      echo "[$(ts)] $story_id: FAILED in swarm (attempt ${retry_count}) — will retry next batch" >> "$PROGRESS_FILE"
    fi

    "$AUDIT_SCRIPT" append --event story_failed --project "$PROJECT" \
      ${COMPANY:+--company "$COMPANY"} \
      --story-id "$story_id" \
      --result fail \
      --duration-ms $(( duration * 1000 )) \
      --error "passes not set in swarm (exit=$exit_code)" \
      --session-id "$SESSION_ID" || true
  fi
}

# Monitor swarm until all members complete. Polls PIDs, prints check-in status.
monitor_swarm_loop() {
  local poll_interval=15
  local last_checkin
  last_checkin=$(date +%s)

  while true; do
    local now
    now=$(date +%s)

    # Check-in print
    if (( now - last_checkin >= CHECKIN_INTERVAL )); then
      print_checkin_status
      last_checkin=$now
    fi

    # Check each PID for completion
    local all_done=true
    local i=0
    while [[ $i -lt ${#SWARM_PIDS[@]} ]]; do
      if [[ "${SWARM_DONE[$i]}" == "true" ]]; then
        i=$((i + 1)); continue
      fi

      local pid="${SWARM_PIDS[$i]}"
      local sid="${SWARM_STORY_IDS[$i]}"
      local wt="${SWARM_WORKTREES[$i]}"
      local start="${SWARM_START_TIMES[$i]}"

      if ! kill -0 "$pid" 2>/dev/null; then
        # Process exited — collect
        local ec=0
        wait "$pid" 2>/dev/null || ec=$?
        SWARM_DONE[$i]="true"
        local dur=$(( now - start ))

        log_info "Swarm member $sid exited (PID $pid, exit=$ec, ${dur}s)"
        process_swarm_completion "$sid" "$ec" "$dur" "$wt" "$start"
      else
        all_done=false
      fi

      i=$((i + 1))
    done

    [[ "$all_done" == "true" ]] && break

    sleep "$poll_interval"
  done
}

# Cherry-pick commits from each story worktree into the main project worktree
merge_swarm_commits() {
  local base_repo="${ORIGINAL_REPO_PATH:-$REPO_PATH}"
  [[ -z "$base_repo" || ! -d "$base_repo" ]] && return 0
  is_git_repo "$base_repo" || return 0

  local i=0
  while [[ $i -lt ${#SWARM_STORY_IDS[@]} ]]; do
    local sid="${SWARM_STORY_IDS[$i]}"
    local wt="${SWARM_WORKTREES[$i]}"
    i=$((i + 1))

    [[ -z "$wt" || ! -d "$wt" || "$wt" == "$base_repo" ]] && continue
    [[ "${SWARM_DONE[$((i - 1))]}" != "true" ]] && continue

    # Check if story actually passed
    local passed
    passed=$(jq -r --arg id "$sid" '.userStories[] | select(.id == $id) | .passes' "$PRD_PATH" 2>/dev/null) || true
    [[ "$passed" != "true" ]] && continue

    # Get the commit SHA from the story worktree
    local wt_sha
    wt_sha=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || continue
    local base_sha
    base_sha=$(git -C "$base_repo" rev-parse HEAD 2>/dev/null) || continue

    # Skip if same commit (worktree was on the same branch tip)
    [[ "$wt_sha" == "$base_sha" ]] && continue

    # Cherry-pick the full commit range from the story worktree (not just HEAD)
    local merge_base
    merge_base=$(git -C "$base_repo" merge-base HEAD "$wt_sha" 2>/dev/null) || true
    if [[ -n "$merge_base" && "$merge_base" != "$wt_sha" ]]; then
      local commit_count
      commit_count=$(git -C "$wt" rev-list --count "${merge_base}..HEAD" 2>/dev/null) || commit_count=1
      log_info "Merging swarm commits from $sid ($commit_count commits: ${merge_base:0:7}..${wt_sha:0:7}) into main worktree"
      git -C "$base_repo" cherry-pick "${merge_base}..${wt_sha}" --no-verify 2>/dev/null || {
        log_warn "Cherry-pick range failed for $sid — attempting merge"
        git -C "$base_repo" cherry-pick --abort 2>/dev/null || true
        git -C "$base_repo" merge "$wt_sha" --no-edit --no-verify -m "[orchestrator] merge swarm: $sid" 2>/dev/null || {
          log_err "Could not merge swarm commits for $sid — manual resolution needed"
          log_err "  Worktree: $wt (commit: $wt_sha)"
        }
      }
    else
      # Fallback: single commit or can't find merge-base
      log_info "Merging swarm commit from $sid ($wt_sha) into main worktree"
      git -C "$base_repo" cherry-pick "$wt_sha" --no-verify 2>/dev/null || {
        log_warn "Cherry-pick failed for $sid — attempting merge"
        git -C "$base_repo" cherry-pick --abort 2>/dev/null || true
        git -C "$base_repo" merge "$wt_sha" --no-edit --no-verify -m "[orchestrator] merge swarm: $sid" 2>/dev/null || {
          log_err "Could not merge swarm commits for $sid — manual resolution needed"
          log_err "  Worktree: $wt (commit: $wt_sha)"
        }
      }
    fi
  done
}

# Clean up per-story worktrees after swarm batch
cleanup_swarm_worktrees() {
  local base_repo="${ORIGINAL_REPO_PATH:-$REPO_PATH}"
  [[ -z "$base_repo" || ! -d "$base_repo" ]] && return 0

  local i=0
  while [[ $i -lt ${#SWARM_WORKTREES[@]} ]]; do
    local wt="${SWARM_WORKTREES[$i]}"
    local sid="${SWARM_STORY_IDS[$i]}"
    i=$((i + 1))

    [[ -z "$wt" || ! -d "$wt" ]] && continue

    local dirty
    dirty=$(git -C "$wt" status --porcelain 2>/dev/null) || true
    if [[ -n "$dirty" ]]; then
      log_warn "Swarm worktree $sid has uncommitted changes — skipping cleanup"
      continue
    fi

    git -C "$base_repo" worktree remove "$wt" --force 2>/dev/null || {
      log_warn "Could not auto-remove swarm worktree $wt"
    }

    # Clean up the per-story branch (e.g., feature/branch/us-001)
    local story_slug
    story_slug=$(echo "$sid" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    local story_branch="${BRANCH_NAME:-main}--${story_slug}"
    git -C "$base_repo" branch -D "$story_branch" 2>/dev/null || true
  done
}

# =============================================================================
# Main Orchestration Loop
# =============================================================================

completed_this_run=0
retry_queue=()
checkout_skipped=()
# Bash 3.2 compat: track swarm retry counts as "id:count" entries (no assoc arrays)
SWARM_RETRY_ENTRIES=()

_swarm_retry_get() {
  local id="$1"
  for entry in ${SWARM_RETRY_ENTRIES[@]+"${SWARM_RETRY_ENTRIES[@]}"}; do
    [[ "$entry" == "$id:"* ]] && echo "${entry#*:}" && return
  done
  echo "0"
}

_swarm_retry_inc() {
  local id="$1"
  local new_entries=()
  local found=false
  for entry in ${SWARM_RETRY_ENTRIES[@]+"${SWARM_RETRY_ENTRIES[@]}"}; do
    if [[ "$entry" == "$id:"* ]]; then
      local count="${entry#*:}"
      new_entries+=("$id:$(( count + 1 ))")
      found=true
    else
      new_entries+=("$entry")
    fi
  done
  [[ "$found" == false ]] && new_entries+=("$id:1")
  SWARM_RETRY_ENTRIES=("${new_entries[@]}")
}

# =============================================================================
# Auto-spawn cmux monitor workspace for live progress viewing
# =============================================================================
spawn_cmux_monitor() {
  [[ "$MONITOR" != true ]] && return 0
  [[ -z "$PROJECT" ]] && return 0

  local monitor_script="$HQ_ROOT/workspace/orchestrator/monitor-project.sh"
  if [[ ! -x "$monitor_script" ]]; then
    echo -e "${DIM}(monitor script not found at $monitor_script — skipping monitor spawn)${NC}"
    return 0
  fi

  # Launch the monitor dashboard in a new Terminal.app window.
  # We write a .command file and `open` it with Terminal — this avoids the
  # AppleScript `do script` keystroke-injection race where a frontmost
  # Terminal window's input buffer can corrupt the first characters of the
  # injected command (observed: "cd ..." → "kcd ..." → command not found).
  # A .command file is invoked via exec rather than keystrokes, so the first
  # line of the script always runs verbatim.
  local monitor_launcher="$HQ_ROOT/workspace/orchestrator/${PROJECT}/.monitor-launcher.command"
  mkdir -p "$(dirname "$monitor_launcher")"
  cat > "$monitor_launcher" <<LAUNCHER
#!/usr/bin/env bash
cd '$HQ_ROOT' || exit 1
clear
exec bash workspace/orchestrator/monitor-project.sh '$PROJECT' --watch
LAUNCHER
  chmod +x "$monitor_launcher"

  if open -a Terminal "$monitor_launcher" 2>/dev/null; then
    echo -e "${DIM}Spawned monitor window for ${PROJECT} (Terminal.app)${NC}"
  else
    echo -e "${DIM}(monitor spawn failed — run manually: bash workspace/orchestrator/monitor-project.sh $PROJECT --watch)${NC}"
  fi
}

spawn_cmux_monitor

if [[ "$SWARM_MODE" == true ]]; then
  echo -e "${BOLD}Starting execution loop (swarm mode, max $SWARM_MAX concurrent)...${NC}\n"
else
  echo -e "${BOLD}Starting execution loop...${NC}\n"
fi

if [[ "$SWARM_MODE" == true ]]; then
  # =========================================================================
  # Swarm Mode Loop
  # =========================================================================
  while true; do
    read_prd_stats
    [[ "$REMAINING" -eq 0 ]] && break

    # Get all eligible stories that can run in parallel
    local_candidates=""
    local_candidates=$(get_swarm_candidates) || true

    # Filter out stories that exhausted swarm retries (already in retry_queue)
    if [[ -n "$local_candidates" && ${#retry_queue[@]} -gt 0 ]]; then
      local filtered_candidates=""
      while IFS= read -r _cand; do
        [[ -z "$_cand" ]] && continue
        local _in_retry=false
        for _rq in "${retry_queue[@]}"; do
          [[ "$_rq" == "$_cand" ]] && _in_retry=true && break
        done
        $_in_retry || filtered_candidates+="$_cand"$'\n'
      done <<< "$local_candidates"
      local_candidates="${filtered_candidates%$'\n'}"
    fi

    if [[ -z "$local_candidates" ]]; then
      # No candidates at all — check if blocked or truly done
      STORY_ID=$(get_next_story) || true
      if [[ -z "$STORY_ID" ]]; then
        log_warn "All remaining stories are blocked by dependencies."
        jq -r '.userStories[] | select(.passes != true) | "  \(.id): needs \(.dependsOn | join(", "))"' "$PRD_PATH"
        break
      fi
      # Single story without files[] declared — fall through to sequential
      local_candidates="$STORY_ID"
    fi

    # Count candidates
    local_count=0
    local_first=""
    while IFS= read -r cand; do
      [[ -z "$cand" ]] && continue
      local_count=$((local_count + 1))
      [[ -z "$local_first" ]] && local_first="$cand"
    done <<< "$local_candidates"

    if [[ "$local_count" -le 1 ]]; then
      # Single candidate — run sequentially with check-in timer
      STORY_ID="$local_first"
      STORY_TITLE=$(get_story_title "$STORY_ID")

      echo -e "${BOLD}=== $STORY_ID: $STORY_TITLE === ($COMPLETED/$TOTAL)${NC}"

      if ! checkout_story "$STORY_ID"; then
        log_warn "$STORY_ID checked out by another process — skipping"
        checkout_skipped+=("$STORY_ID")
        # Avoid infinite loop on checkout-blocked
        if [[ ${#checkout_skipped[@]} -ge "$REMAINING" ]]; then break; fi
        continue
      fi

      update_state_current "$STORY_ID"
      sync_linear_start "$STORY_ID"

      log_info "Running story $STORY_ID..."
      story_start=$(date +%s)
      # Defect B: anchor attribution to HEAD-before-story so we can't latch
      # onto a stale commit from an earlier story.
      # US-019 fix: also anchor every candidate sibling repo so cross-repo
      # commits get attributed correctly by resolve_story_attribution().
      pre_story_sha=$(get_pre_story_sha)
      capture_pre_story_anchors "$STORY_ID"

      "$AUDIT_SCRIPT" append --event story_dispatched --project "$PROJECT" \
        ${COMPANY:+--company "$COMPANY"} \
        --story-id "$STORY_ID" \
        --action "Dispatching $STORY_ID: $STORY_TITLE" \
        --session-id "$SESSION_ID" || true

      # Background check-in timer
      ( while true; do sleep "$CHECKIN_INTERVAL"; print_checkin_status; done ) &
      CHECKIN_PID=$!

      exit_code=0
      run_story "$STORY_ID" "$PROJECT" "$PRD_REL" || exit_code=$?

      kill "$CHECKIN_PID" 2>/dev/null; wait "$CHECKIN_PID" 2>/dev/null || true

      story_end=$(date +%s)
      duration=$(( story_end - story_start ))

      validate_git_state "$STORY_ID"
      run_story_tests "$STORY_ID" || true  # non-blocking in sequential — logged + state recorded
      run_codex_review "$STORY_ID"

      # Orchestrator writes passes (source of truth) — pass checkout timestamp for Layer 3 git heuristic
      checkout_ts_iso=""
      checkout_ts_iso=$(date -u -r "$story_start" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || checkout_ts_iso=""
      orchestrator_write_passes "$STORY_ID" "$checkout_ts_iso"

      passes=$(jq -r --arg id "$STORY_ID" '.userStories[] | select(.id == $id) | .passes' "$PRD_PATH")

      if [[ "$passes" == "true" ]]; then
        # US-019/US-020 fix: multi-repo attribution + immutable sidecar.
        # ATTR_* globals are consumed by update_state_completed below.
        resolve_story_attribution "$STORY_ID" "$checkout_ts_iso"
        commit_sha="$ATTR_PRIMARY_SHA"
        files_changed="$ATTR_FILES_CHANGED_JSON"
        if [[ "$commit_sha" == "no-commit" ]]; then
          log_warn "$STORY_ID: HEAD did not advance in any candidate repo — sub-agent committed nothing"
        fi
        update_state_completed "$STORY_ID" "$commit_sha" "$files_changed"
        release_checkout "$STORY_ID"
        echo "[$(ts)] $STORY_ID: $STORY_TITLE — completed (${duration}s) [$commit_sha] ($COMPLETED/$TOTAL)" >> "$PROGRESS_FILE"

        "$AUDIT_SCRIPT" append --event story_completed --project "$PROJECT" \
          ${COMPANY:+--company "$COMPANY"} \
          --story-id "$STORY_ID" --action "$STORY_TITLE" \
          --result success --duration-ms $(( duration * 1000 )) \
          --session-id "$SESSION_ID" || true

        sync_linear_done "$STORY_ID"
        log_ok "$STORY_ID completed in ${duration}s [$commit_sha] ($COMPLETED/$TOTAL)"
        completed_this_run=$((completed_this_run + 1))

        if (( completed_this_run % REGRESSION_INTERVAL == 0 && completed_this_run > 0 )); then
          run_regression_gate "$STORY_ID"
          run_project_reanchor "$PROJECT" "$completed_this_run"
        fi
      else
        log_err "$STORY_ID: passes still false (exit=$exit_code, ${duration}s)"
        retry_queue+=("$STORY_ID")
        update_state_failed "$STORY_ID" "passes not set (exit=$exit_code)"
        release_checkout "$STORY_ID"
        echo "[$(ts)] $STORY_ID: FAILED — queued for retry ($COMPLETED/$TOTAL)" >> "$PROGRESS_FILE"

        "$AUDIT_SCRIPT" append --event story_failed --project "$PROJECT" \
          ${COMPANY:+--company "$COMPANY"} \
          --story-id "$STORY_ID" --action "$STORY_TITLE" \
          --result fail --duration-ms $(( duration * 1000 )) \
          --error "passes not set (exit=$exit_code)" \
          --session-id "$SESSION_ID" || true
      fi

      qmd update 2>/dev/null || true
      echo ""
      continue
    fi

    # Multiple candidates — dispatch swarm batch
    echo -e "${BOLD}=== Swarm Batch: $local_count stories in parallel ===${NC}"

    # Reset swarm arrays
    SWARM_STORY_IDS=()
    SWARM_PIDS=()
    SWARM_WORKTREES=()
    SWARM_START_TIMES=()
    SWARM_DONE=()
    PENDING_REGRESSION_GATE=""

    while IFS= read -r cand_id; do
      [[ -z "$cand_id" ]] && continue

      cand_title=$(get_story_title "$cand_id")
      echo -e "  ${BLUE}Dispatching:${NC} $cand_id — $cand_title"

      # Checkout lock
      if ! checkout_story "$cand_id"; then
        log_warn "$cand_id checked out by another process — skipping in swarm"
        continue
      fi

      # Pre-acquire file locks
      preacquire_swarm_locks "$cand_id" "$$"

      # Create per-story worktree
      ensure_story_worktree "$cand_id"
      wt_path="${STORY_WORKTREE_PATH:-}"

      # Linear sync
      sync_linear_start "$cand_id"

      # Add to state
      update_state_add_task "$cand_id" "" "$wt_path"

      "$AUDIT_SCRIPT" append --event story_dispatched --project "$PROJECT" \
        ${COMPANY:+--company "$COMPANY"} \
        --story-id "$cand_id" \
        --action "Dispatching $cand_id (swarm): $cand_title" \
        --session-id "$SESSION_ID" || true

      # Launch background
      batch_start=""
      batch_start=$(date +%s)

      run_story_background "$cand_id" "$wt_path"

      SWARM_STORY_IDS+=("$cand_id")
      SWARM_PIDS+=("$LAST_BG_PID")
      SWARM_WORKTREES+=("$wt_path")
      SWARM_START_TIMES+=("$batch_start")
      SWARM_DONE+=("false")

      # Update state with PID
      update_state_add_task "$cand_id" "$LAST_BG_PID" "$wt_path"

      log_info "$cand_id dispatched (PID $LAST_BG_PID, worktree: ${wt_path:-none})"
    done <<< "$local_candidates"

    if [[ ${#SWARM_PIDS[@]} -eq 0 ]]; then
      log_warn "No stories could be dispatched in swarm batch — all checkout-blocked"
      break
    fi

    echo -e "\n${BOLD}Monitoring ${#SWARM_PIDS[@]} stories...${NC}\n"

    # Block until all complete
    monitor_swarm_loop

    # Merge worktree commits into main branch
    merge_swarm_commits

    # Clean up worktrees
    cleanup_swarm_worktrees

    # Run pending regression gate if any
    if [[ -n "$PENDING_REGRESSION_GATE" ]]; then
      run_regression_gate "$PENDING_REGRESSION_GATE"
      run_project_reanchor "$PROJECT" "$completed_this_run"
      PENDING_REGRESSION_GATE=""
    fi

    # Reindex
    qmd update 2>/dev/null || true

    echo ""
  done

else
  # =========================================================================
  # Sequential Mode Loop (with check-in timer)
  # =========================================================================
  while true; do
    # Re-read PRD each iteration (execute-task may have updated passes)
    read_prd_stats

    if [[ "$REMAINING" -eq 0 ]]; then
      break
    fi

    # Build skip list from retry queue + checkout-skipped
    skip_ids=""
    if [[ ${#retry_queue[@]} -gt 0 ]]; then
      skip_ids=$(printf '%s\n' "${retry_queue[@]}")
    fi
    if [[ ${#checkout_skipped[@]} -gt 0 ]]; then
      more_skips=$(printf '%s\n' "${checkout_skipped[@]}")
      if [[ -n "$skip_ids" ]]; then
        skip_ids="$skip_ids"$'\n'"$more_skips"
      else
        skip_ids="$more_skips"
      fi
    fi

    # Get next unblocked story (skipping retry queue + checkout-blocked)
    STORY_ID=$(get_next_story "$skip_ids")

    if [[ -z "$STORY_ID" ]]; then
      # All remaining stories are blocked or skipped
      if [[ ${#retry_queue[@]} -gt 0 || ${#checkout_skipped[@]} -gt 0 ]]; then
        log_warn "All remaining stories are either blocked, in retry queue, or checkout-locked."
      else
        log_warn "All remaining stories are blocked by dependencies."
        jq -r '.userStories[] | select(.passes != true) | "  \(.id): needs \(.dependsOn | join(", "))"' "$PRD_PATH"
      fi
      break
    fi

    STORY_TITLE=$(get_story_title "$STORY_ID")

    echo -e "${BOLD}=== $STORY_ID: $STORY_TITLE === ($COMPLETED/$TOTAL)${NC}"

    # Checkout: acquire story-level lock before dispatch
    if ! checkout_story "$STORY_ID"; then
      checkout_skipped+=("$STORY_ID")
      continue  # Another live PID holds this story — try next
    fi

    # Update state: current task
    update_state_current "$STORY_ID"

    # PRE-TASK: Linear sync — set issue In Progress + comment (best-effort)
    sync_linear_start "$STORY_ID"

    # Execute story
    attempt=1
    story_passed=false

    while [[ "$attempt" -le 2 ]]; do
      log_info "Running story $STORY_ID (attempt $attempt)..."
      story_start=$(date +%s)
      # Defect B: anchor attribution to HEAD-before-story so we can't latch
      # onto a stale commit from an earlier story.
      # US-019 fix: also anchor every candidate sibling repo.
      pre_story_sha=$(get_pre_story_sha)
      capture_pre_story_anchors "$STORY_ID"
      # Defect C: refresh state.json PID/timestamp on every attempt so the
      # check-in printer shows the current attempt's orchestrator PID rather
      # than stale data from a previous run/session.
      update_state_current "$STORY_ID"

      "$AUDIT_SCRIPT" append --event story_dispatched --project "$PROJECT" \
        ${COMPANY:+--company "$COMPANY"} \
        --story-id "$STORY_ID" \
        --action "Dispatching $STORY_ID (attempt $attempt): $STORY_TITLE" \
        --session-id "$SESSION_ID" || true

      # Background check-in timer
      ( while true; do sleep "$CHECKIN_INTERVAL"; print_checkin_status; done ) &
      CHECKIN_PID=$!

      exit_code=0
      run_story "$STORY_ID" "$PROJECT" "$PRD_REL" || exit_code=$?

      # Stop check-in timer
      kill "$CHECKIN_PID" 2>/dev/null; wait "$CHECKIN_PID" 2>/dev/null || true

      story_end=$(date +%s)
      duration=$(( story_end - story_start ))

      # POST-INVOCATION: Validate git state (self-healing)
      validate_git_state "$STORY_ID"

      # POST-INVOCATION: Codex review safety net (best-effort)
      run_codex_review "$STORY_ID"

      # Orchestrator writes passes (source of truth) — pass checkout timestamp for Layer 3 git heuristic
      checkout_ts_iso=""
      checkout_ts_iso=$(date -u -r "$story_start" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || checkout_ts_iso=""
      orchestrator_write_passes "$STORY_ID" "$checkout_ts_iso"

      # Check source of truth: did passes get set to true?
      passes=$(jq -r --arg id "$STORY_ID" '.userStories[] | select(.id == $id) | .passes' "$PRD_PATH")

      if [[ "$passes" == "true" ]]; then
        # US-019/US-020 fix: multi-repo attribution + immutable sidecar.
        resolve_story_attribution "$STORY_ID" "$checkout_ts_iso"
        commit_sha="$ATTR_PRIMARY_SHA"
        files_changed="$ATTR_FILES_CHANGED_JSON"
        if [[ "$commit_sha" == "no-commit" ]]; then
          log_warn "$STORY_ID: HEAD did not advance in any candidate repo — sub-agent committed nothing"
        fi

        update_state_completed "$STORY_ID" "$commit_sha" "$files_changed"
        release_checkout "$STORY_ID"
        echo "[$(ts)] $STORY_ID: $STORY_TITLE — completed (${duration}s) [$commit_sha] ($COMPLETED/$TOTAL)" >> "$PROGRESS_FILE"

        "$AUDIT_SCRIPT" append --event story_completed --project "$PROJECT" \
          ${COMPANY:+--company "$COMPANY"} \
          --story-id "$STORY_ID" \
          --action "$STORY_TITLE" \
          --result success \
          --duration-ms $(( duration * 1000 )) \
          --session-id "$SESSION_ID" || true

        # POST-TASK: Linear sync → Done (best-effort)
        sync_linear_done "$STORY_ID"

        log_ok "$STORY_ID completed in ${duration}s [$commit_sha] ($COMPLETED/$TOTAL)"
        story_passed=true
        completed_this_run=$((completed_this_run + 1))
        break
      else
        log_err "$STORY_ID: passes still false after invocation (exit=$exit_code, ${duration}s)"

        result=0
        handle_failure "$STORY_ID" "$attempt" || result=$?

        case $result in
          0) attempt=$((attempt + 1)); continue ;;  # retry
          2) # skip
            retry_queue+=("$STORY_ID")
            update_state_failed "$STORY_ID" "passes not set after attempt $attempt"
            release_checkout "$STORY_ID"
            echo "[$(ts)] $STORY_ID: FAILED — queued for retry ($COMPLETED/$TOTAL)" >> "$PROGRESS_FILE"
            "$AUDIT_SCRIPT" append --event story_failed --project "$PROJECT" \
              ${COMPANY:+--company "$COMPANY"} \
              --story-id "$STORY_ID" \
              --action "$STORY_TITLE" \
              --result fail \
              --duration-ms $(( duration * 1000 )) \
              --error "passes not set after attempt $attempt (exit=$exit_code)" \
              --session-id "$SESSION_ID" || true
            break
            ;;
          3) # pause
            release_checkout "$STORY_ID"
            jq --arg ts "$(ts)" '.status = "paused" | .updated_at = $ts' "$STATE_FILE" > "$STATE_FILE.tmp" \
              && mv "$STATE_FILE.tmp" "$STATE_FILE"
            "$AUDIT_SCRIPT" append --event story_failed --project "$PROJECT" \
              ${COMPANY:+--company "$COMPANY"} \
              --story-id "$STORY_ID" \
              --action "$STORY_TITLE" \
              --result fail \
              --duration-ms $(( duration * 1000 )) \
              --error "paused by user after attempt $attempt (exit=$exit_code)" \
              --session-id "$SESSION_ID" || true
            log_warn "Paused. Resume: scripts/run-project.sh --resume $PROJECT"
            exit 0
            ;;
        esac
      fi
    done

    # STORY ACCEPTANCE TESTS: after every completed story (cumulative regression guard)
    if [[ "$story_passed" == true ]]; then
      run_story_tests "$STORY_ID" || true  # non-blocking — logged + state recorded
    fi

    # REGRESSION GATE: every N completed stories
    if [[ "$story_passed" == true && $((completed_this_run % REGRESSION_INTERVAL)) -eq 0 && "$completed_this_run" -gt 0 ]]; then
      run_regression_gate "$STORY_ID"
      run_project_reanchor "$PROJECT" "$completed_this_run"
    fi

    # Reindex
    qmd update 2>/dev/null || true

    echo ""
  done
fi

# =============================================================================
# Retry Pass
# =============================================================================

if [[ ${#retry_queue[@]} -gt 0 ]]; then
  echo -e "\n${BOLD}=== Retry Pass ===${NC}"
  echo -e "Retrying ${#retry_queue[@]} failed stories...\n"

  for story_id in "${retry_queue[@]}"; do
    # Check if it's still incomplete (might have been fixed by a later story)
    passes=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .passes' "$PRD_PATH")
    if [[ "$passes" == "true" ]]; then
      log_ok "$story_id already passing (fixed by later story)"
      continue
    fi

    title=$(get_story_title "$story_id")
    echo -e "${BOLD}=== RETRY: $story_id: $title ===${NC}"

    retry_start=$(date +%s)
    # Defect B: anchor attribution to HEAD-before-story so retries can't latch
    # onto a previous story's SHA.
    # US-019 fix: also anchor every candidate sibling repo.
    pre_story_sha=$(get_pre_story_sha)
    capture_pre_story_anchors "$story_id"

    "$AUDIT_SCRIPT" append --event story_dispatched --project "$PROJECT" \
      ${COMPANY:+--company "$COMPANY"} \
      --story-id "$story_id" \
      --action "Dispatching $story_id (retry): $title" \
      --session-id "$SESSION_ID" || true

    exit_code=0
    run_story "$story_id" "$PROJECT" "$PRD_REL" || exit_code=$?

    validate_git_state "$story_id"

    retry_end=$(date +%s)
    retry_duration=$(( retry_end - retry_start ))

    passes=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .passes' "$PRD_PATH")
    if [[ "$passes" == "true" ]]; then
      # US-019/US-020 fix: multi-repo attribution + immutable sidecar.
      retry_start_iso=""
      retry_start_iso=$(date -u -r "$retry_start" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || retry_start_iso=""
      resolve_story_attribution "$story_id" "$retry_start_iso"
      commit_sha="$ATTR_PRIMARY_SHA"
      files_changed="$ATTR_FILES_CHANGED_JSON"
      if [[ "$commit_sha" == "no-commit" ]]; then
        log_warn "$story_id: HEAD did not advance in any candidate repo on retry — sub-agent committed nothing"
      fi
      update_state_completed "$story_id" "$commit_sha" "$files_changed"
      echo "[$(ts)] $story_id: $title — completed on retry [$commit_sha] ($COMPLETED/$TOTAL)" >> "$PROGRESS_FILE"
      log_ok "$story_id completed on retry [$commit_sha]"
      completed_this_run=$((completed_this_run + 1))
      "$AUDIT_SCRIPT" append --event story_completed --project "$PROJECT" \
        ${COMPANY:+--company "$COMPANY"} \
        --story-id "$story_id" \
        --action "$title (retry)" \
        --result success \
        --duration-ms $(( retry_duration * 1000 )) \
        --session-id "$SESSION_ID" || true
    else
      log_err "$story_id failed on retry"
      echo "[$(ts)] $story_id: FAILED on retry" >> "$PROGRESS_FILE"
      "$AUDIT_SCRIPT" append --event story_failed --project "$PROJECT" \
        ${COMPANY:+--company "$COMPANY"} \
        --story-id "$story_id" \
        --action "$title (retry)" \
        --result fail \
        --duration-ms $(( retry_duration * 1000 )) \
        --error "passes not set after retry (exit=$exit_code)" \
        --session-id "$SESSION_ID" || true
    fi
  done
fi

# =============================================================================
# Attribution Audit (US-019/US-020 defect regression guard)
# =============================================================================
# After all stories have run, sweep state.json for entries that look like the
# old defect: a completed story with commit_sha="no-commit" and cross_repo=false.
# Those are only legitimate when the sub-agent genuinely committed nothing
# (e.g. a pure-docs story that was auto-committed by the orchestrator). Emit a
# warning so the defect can't silently regress. Set HQ_ATTRIBUTION_STRICT=1 to
# fail the run instead of warning.

if [[ -f "$STATE_FILE" ]]; then
  suspicious_count=$(jq -r '
    [.completed_tasks[]?
     | select(.commit_sha == "no-commit")
     | select((.cross_repo // false) == false)
     | .id
    ] | length
  ' "$STATE_FILE" 2>/dev/null || echo 0)

  if [[ "${suspicious_count:-0}" -gt 0 ]]; then
    suspicious_ids=$(jq -r '
      [.completed_tasks[]?
       | select(.commit_sha == "no-commit")
       | select((.cross_repo // false) == false)
       | .id
      ] | join(", ")
    ' "$STATE_FILE" 2>/dev/null || echo "")
    log_warn "[attribution-audit] $suspicious_count completed story/stories recorded \"no-commit\" with cross_repo=false: $suspicious_ids"
    log_warn "[attribution-audit] This may indicate US-019/US-020 defect regression. Inspect sidecars under workspace/orchestrator/$PROJECT/executions/*.attribution.json"
    if [[ "${HQ_ATTRIBUTION_STRICT:-0}" == "1" ]]; then
      log_err "[attribution-audit] HQ_ATTRIBUTION_STRICT=1 — failing run"
      exit 1
    fi
  else
    log_info "[attribution-audit] OK — no suspicious no-commit/single-repo entries"
  fi
fi

# =============================================================================
# Completion
# =============================================================================

read_prd_stats
echo ""
echo -e "${BOLD}=== Summary ===${NC}"
echo -e "Project:   $PROJECT"
echo -e "Completed: ${GREEN}$COMPLETED${NC}/$TOTAL"
echo -e "This run:  $completed_this_run stories"

failed_count=$(jq '.failed_tasks | length' "$STATE_FILE")
if [[ "$failed_count" -gt 0 ]]; then
  echo -e "Failed:    ${RED}$failed_count${NC}"
fi

if [[ "$REMAINING" -eq 0 ]]; then
  echo -e "\n${GREEN}${BOLD}All stories complete!${NC}"

  # Mark project done
  jq --arg ts "$(ts)" '.status = "completed" | .completed_at = $ts | .updated_at = $ts' \
    "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

  echo "[$(ts)] PROJECT COMPLETE: $PROJECT — $TOTAL/$TOTAL stories" >> "$PROGRESS_FILE"

  run_end_epoch=$(date +%s)
  run_duration=$(( run_end_epoch - RUN_START_EPOCH ))
  "$AUDIT_SCRIPT" append --event project_completed --project "$PROJECT" \
    ${COMPANY:+--company "$COMPANY"} \
    --action "Project completed: $TOTAL total, $COMPLETED completed, $failed_count failed" \
    --result success \
    --duration-ms $(( run_duration * 1000 )) \
    --session-id "$SESSION_ID" || true

  # Board sync → done
  sync_board "done"

  # ---- Full Ralph Completion Flow ----

  # 1. Generate project summary report
  REPORT_DIR="$HQ_ROOT/workspace/reports"
  mkdir -p "$REPORT_DIR"
  REPORT_FILE="$REPORT_DIR/${PROJECT}-summary.md"

  {
    echo "# $PROJECT — Project Summary"
    echo ""
    echo "**Completed:** $(ts)"
    echo "**Stories:** $TOTAL/$TOTAL"
    echo "**Branch:** ${BRANCH_NAME:-main}"
    echo ""
    echo "## Completed Tasks"
    echo ""
    jq -r '.completed_tasks[] | "- **\(.id)** — \(.completed_at) [\(.commit_sha)]"' "$STATE_FILE"
    echo ""

    if [[ $(jq '.failed_tasks | length' "$STATE_FILE") -gt 0 ]]; then
      echo "## Failed Tasks (resolved on retry)"
      echo ""
      jq -r '.failed_tasks[] | "- **\(.id)** — \(.error)"' "$STATE_FILE"
      echo ""
    fi

    if [[ $(jq '.regression_gates | length' "$STATE_FILE") -gt 0 ]]; then
      echo "## Regression Gates"
      echo ""
      jq -r '.regression_gates[] | "- After \(.after_story): \(if .passed then "✅ passed" else "❌ failed" end)"' "$STATE_FILE"
      echo ""
    fi

    if [[ $(jq '(.story_test_failures // []) | length' "$STATE_FILE") -gt 0 ]]; then
      echo "## Story Acceptance Test Failures"
      echo ""
      jq -r '(.story_test_failures // [])[] | "- After \(.after_story): ❌ regression detected (\(.timestamp))"' "$STATE_FILE"
      echo ""
    fi
  } > "$REPORT_FILE"
  log_ok "Report: $REPORT_FILE"

  # 2. Update INDEX.md files (company projects + orchestrator)
  company=$(jq -r '.metadata.company // empty' "$PRD_PATH" 2>/dev/null) || true
  if [[ -n "$company" ]]; then
    co_projects_index="$HQ_ROOT/companies/$company/projects/INDEX.md"
    if [[ -f "$co_projects_index" ]]; then
      # Touch updated_at — full rebuild deferred to /cleanup
      log_info "INDEX: $co_projects_index needs rebuild (deferred)"
    fi
  fi

  orch_index="$HQ_ROOT/workspace/orchestrator/INDEX.md"
  if [[ -f "$orch_index" ]]; then
    log_info "INDEX: $orch_index needs rebuild (deferred)"
  fi

  # 3. Doc sweep — headless update of all 4 doc layers
  run_doc_sweep "$PROJECT" "$PRD_REL"

  # 4. Final reindex
  qmd update 2>/dev/null || true
  log_ok "qmd reindexed"

  # 5. Verify manifest (repos/workers created during project are registered)
  if [[ -n "$REPO_PATH" && -f "$HQ_ROOT/companies/manifest.yaml" ]]; then
    repo_rel="${REPO_PATH#"$HQ_ROOT/"}"
    if ! grep -q "$repo_rel" "$HQ_ROOT/companies/manifest.yaml" 2>/dev/null; then
      log_warn "Repo $repo_rel not found in manifest.yaml — verify registration"
    fi
  fi

  # 6. Worktree cleanup (if used)
  cleanup_worktree

else
  echo -e "\n${YELLOW}$REMAINING stories remaining.${NC}"
  echo -e "Resume: ${DIM}scripts/run-project.sh --resume $PROJECT${NC}"
fi

echo ""
