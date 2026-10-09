#!/usr/bin/env bash
# hq-core: public
# conduct-lane-launch.sh — mint a /conduct lane run dir, then launch the lane
# detached, exactly as .claude/skills/_shared/lane-dispatch-protocol.md §3-§5
# describe. The protocol stays the source of truth; this script is its launch
# block with the arguments validated and the engine pins applied.
#
# Two steps, because the brief is written with the file tool between them
# (hooks reject heredoc writes into run dirs and unexpanded $VAR paths):
#
#   1. bash core/scripts/conduct-lane-launch.sh mint --lane <name>
#        prints the fresh run dir, relative to the HQ root. Write brief.md there.
#   2. bash core/scripts/conduct-lane-launch.sh start --run-dir <dir> \
#        --worker <role-or-worker> --tier exec|plan --timeout <secs> --cd <abs dir>
#        writes args.json and deadline, launches through hq-detach.sh, checks the
#        lane escaped the turn, and records the pool slot running.
#
# Options (both steps):
#   --session-id <id>   owning session (default: hq-session.sh current)
# mint:
#   --lane <name>       lane label used in the dir name ([a-z0-9._-])
#   --caller <name>     caller prefix (default: conduct)
# start:
#   --run-dir <dir>     a dir printed by mint (relative to the HQ root, or absolute)
#   --worker <id>       pool worker; "conduct:" is prepended when missing
#   --tier exec|plan    model tier; never implicit
#   --timeout <secs>    soft timeoutSecs and the waiter's deadline
#   --cd <abs dir>      the lane's working directory (must exist)
#   --label <name>      runner label (default: the worker id without "conduct:")
#   --engine <e>        claude|codex|grok (default: session conduct_engine)
#   --model <m>         default: session conduct_child_model (unset: engine default)
#   --effort <f>        default: session conduct_child_effort (unset: engine default)
#   --dry-run           validate and print the launch plan as JSON; launch nothing
#
# Engine pins: claude exports HQ_WORKFLOW_CLAUDE_PLAN_MODEL,
# HQ_WORKFLOW_CLAUDE_EXEC_MODEL and HQ_WORKFLOW_CLAUDE_EFFORT; codex and grok
# export HQ_WORKFLOW_MODEL and HQ_WORKFLOW_EFFORT.
#
# Exit codes: 0 ok, 1 usage or validation error, 2 no company bound,
# 3 launch failed. Output never includes environment values other than the
# engine, model and effort names.

set -euo pipefail

ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

usage() { sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "conduct-lane-launch: $*" >&2; exit 1; }
need_val() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }

session_get() {
  bash "$ROOT/core/scripts/hq-session.sh" --session-id "$SID" get "$1" 2>/dev/null || true
}

resolve_sid() {
  if [ -z "$SID" ]; then
    SID="$(bash "$ROOT/core/scripts/hq-session.sh" current 2>/dev/null || true)"
  fi
  [ -n "$SID" ] || die "no session id: pass --session-id or start an HQ session"
  case "$SID" in *[!A-Za-z0-9._-]*|.*) die "invalid session id: $SID" ;; esac
}

cmd_mint() {
  local lane="" caller="conduct"
  while [ $# -gt 0 ]; do
    case "$1" in
      --lane) need_val "$@"; lane="$2"; shift 2 ;;
      --caller) need_val "$@"; caller="$2"; shift 2 ;;
      --session-id) need_val "$@"; SID="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "mint: unknown option: $1" ;;
    esac
  done
  [ -n "$lane" ] || die "mint: --lane is required"
  case "$lane" in *[!a-z0-9._-]*|.*) die "mint: invalid lane name: $lane" ;; esac
  case "$caller" in *[!a-z0-9_-]*|"") die "mint: invalid caller: $caller" ;; esac
  resolve_sid
  local base="workspace/tmp/workflow-runner/$SID" dir
  mkdir -p "$ROOT/$base"
  dir="$(cd "$ROOT" && mktemp -d "$base/$caller-$lane-XXXXXX")"
  printf '%s\n' "$dir"
}

cmd_start() {
  local run_dir="" worker="" tier="" timeout="" cd_dir="" label="" engine="" model="" effort=""
  local dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-dir) need_val "$@"; run_dir="$2"; shift 2 ;;
      --worker) need_val "$@"; worker="$2"; shift 2 ;;
      --tier) need_val "$@"; tier="$2"; shift 2 ;;
      --timeout) need_val "$@"; timeout="$2"; shift 2 ;;
      --cd) need_val "$@"; cd_dir="$2"; shift 2 ;;
      --label) need_val "$@"; label="$2"; shift 2 ;;
      --engine) need_val "$@"; engine="$2"; shift 2 ;;
      --model) need_val "$@"; model="$2"; shift 2 ;;
      --effort) need_val "$@"; effort="$2"; shift 2 ;;
      --session-id) need_val "$@"; SID="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "start: unknown option: $1" ;;
    esac
  done
  [ -n "$run_dir" ] || die "start: --run-dir is required"
  [ -n "$worker" ] || die "start: --worker is required"
  [ -n "$tier" ] || die "start: --tier is required (exec or plan)"
  [ -n "$timeout" ] || die "start: --timeout is required"
  [ -n "$cd_dir" ] || die "start: --cd is required"
  case "$tier" in exec|plan) ;; *) die "start: --tier must be exec or plan, got: $tier" ;; esac
  case "$timeout" in ''|*[!0-9]*) die "start: --timeout must be a positive integer of seconds" ;; esac
  [ "$timeout" -gt 0 ] || die "start: --timeout must be greater than 0"
  case "$worker" in conduct:*) ;; *) worker="conduct:$worker" ;; esac
  case "${worker#conduct:}" in ''|*[!a-z0-9._-]*) die "start: invalid worker id: $worker" ;; esac
  [ -n "$label" ] || label="${worker#conduct:}"
  case "$label" in *[!a-z0-9._-]*) die "start: invalid label: $label" ;; esac
  case "$cd_dir" in /*) ;; *) die "start: --cd must be an absolute path" ;; esac
  [ -d "$cd_dir" ] || die "start: --cd does not exist: $cd_dir"

  resolve_sid
  local base="workspace/tmp/workflow-runner/$SID" rel
  case "$run_dir" in
    "$ROOT"/*) rel="${run_dir#"$ROOT"/}" ;;
    /*) die "start: --run-dir is outside the HQ root: $run_dir" ;;
    *) rel="${run_dir#./}" ;;
  esac
  rel="${rel%/}"
  case "$rel" in
    "$base"/*) ;;
    *) die "start: --run-dir must be a dir minted under $base (run: conduct-lane-launch.sh mint)" ;;
  esac
  case "${rel#"$base"/}" in */*|*..*) die "start: --run-dir must be a direct child of $base" ;; esac
  local abs="$ROOT/$rel"
  [ -d "$abs" ] || die "start: run dir does not exist: $rel"
  [ -s "$abs/brief.md" ] || die "start: $rel/brief.md is missing or empty; write the brief first"
  # Protocol §3: every dispatch mints a fresh run dir. A dir that already ran
  # holds a CONDUCT_EXIT marker that a new waiter would read as this lane's.
  if [ -e "$abs/lane.log" ] || [ -e "$abs/lane.pid" ] || [ -e "$abs/deadline" ]; then
    die "start: $rel was already launched; mint a fresh run dir"
  fi

  [ -n "$engine" ] || engine="$(session_get conduct_engine)"
  [ -n "$engine" ] || die "start: no engine: pass --engine or set conduct_engine for the session"
  case "$engine" in claude|codex|grok) ;; *) die "start: unknown engine: $engine (claude, codex or grok)" ;; esac
  [ -n "$model" ] || model="$(session_get conduct_child_model)"
  [ -n "$effort" ] || effort="$(session_get conduct_child_effort)"
  # The model only travels through the environment, never through shell text,
  # so whitespace is the one thing that can make it ambiguous.
  case "$model" in *[[:space:]]*) die "start: invalid model name: $model" ;; esac
  case "$effort" in *[!a-z]*) die "start: invalid effort: $effort" ;; esac

  # Protocol §4: company comes from trusted session state, never the cwd.
  local company="${HQ_SPAWN_COMPANY:-}"
  [ -n "$company" ] || company="$(session_get company_slug)"
  if [ -z "$company" ]; then
    echo "conduct-lane-launch: refusing detached lane without a company; bind one with hq-session.sh set company_slug" >&2
    exit 2
  fi
  local project="${HQ_SPAWN_PROJECT:-}"
  [ -n "$project" ] || project="$(session_get project)"

  local pin_keys
  if [ "$engine" = claude ]; then
    pin_keys="HQ_WORKFLOW_CLAUDE_PLAN_MODEL HQ_WORKFLOW_CLAUDE_EXEC_MODEL HQ_WORKFLOW_CLAUDE_EFFORT"
  else
    pin_keys="HQ_WORKFLOW_MODEL HQ_WORKFLOW_EFFORT"
  fi

  if [ "$dry" = 1 ]; then
    jq -cn --arg run_dir "$rel" --arg worker "$worker" --arg engine "$engine" \
      --arg model "$model" --arg effort "$effort" --arg tier "$tier" \
      --arg timeout "$timeout" --arg cd "$cd_dir" --arg company "$company" \
      --arg session "$SID" --arg pins "$pin_keys" \
      '{dry_run:true, run_dir:$run_dir, worker_id:$worker, engine:$engine,
        model:(if $model=="" then null else $model end),
        effort:(if $effort=="" then null else $effort end),
        tier:$tier, timeout:($timeout|tonumber), cd:$cd, company:$company,
        session_id:$session, pins:($pins|split(" "))}'
    return 0
  fi

  jq -n --arg brief "$abs/brief.md" --arg cd "$cd_dir" '{brief:$brief, cd:$cd}' > "$abs/args.json"
  echo $(( $(date +%s) + timeout )) > "$abs/deadline"
  printf '%s\n' "$worker" > "$abs/worker_id"
  printf '%s\n' "$SID" > "$abs/session_id"
  printf '%s\n' "$engine" > "$abs/engine"

  cd "$ROOT"
  # The parent's task binding is never inherited by a /conduct lane (protocol §4).
  unset HQ_SPAWN_TASK
  export HQ_SPAWN_COMPANY="$company"
  if [ -n "$project" ]; then export HQ_SPAWN_PROJECT="$project"; else unset HQ_SPAWN_PROJECT; fi
  export LANE_RUN_DIR="$rel" LANE_RUN_DIR_ABS="$abs" LANE_TIMEOUT="$timeout"
  export HQ_SESSION_ID="$SID"
  export HQ_PARENT_SESSION_ID="${HQ_PARENT_SESSION_ID:-$SID}"
  export HQ_CONDUCT_ENGINE="$engine" LANE_WORKER_ID="$worker" LANE_TIER="$tier" LANE_LABEL="$label"
  unset HQ_WORKFLOW_CLAUDE_PLAN_MODEL HQ_WORKFLOW_CLAUDE_EXEC_MODEL HQ_WORKFLOW_CLAUDE_EFFORT \
    HQ_WORKFLOW_MODEL HQ_WORKFLOW_EFFORT
  if [ "$engine" = claude ]; then
    if [ -n "$model" ]; then
      export HQ_WORKFLOW_CLAUDE_PLAN_MODEL="$model" HQ_WORKFLOW_CLAUDE_EXEC_MODEL="$model"
    fi
    [ -z "$effort" ] || export HQ_WORKFLOW_CLAUDE_EFFORT="$effort"
  else
    [ -z "$model" ] || export HQ_WORKFLOW_MODEL="$model"
    [ -z "$effort" ] || export HQ_WORKFLOW_EFFORT="$effort"
  fi

  bash core/scripts/hq-detach.sh --owner-pidfile "$abs/owner.pid" -- bash -c '
    echo $$ > "$LANE_RUN_DIR/lane.pid"
    export HQ_CONDUCT_RUN_DIR="$LANE_RUN_DIR_ABS"
    node core/scripts/workflow-runner.mjs --eval \
      "return await agent(\"Read your brief at \" + args.brief + \" and carry it out now.\", { engine: \"$HQ_CONDUCT_ENGINE\", tier: \"$LANE_TIER\", cd: args.cd, label: \"$LANE_LABEL\", timeoutSecs: $LANE_TIMEOUT })" \
      --args "$(cat "$LANE_RUN_DIR/args.json")" --run-dir "$LANE_RUN_DIR" > "$LANE_RUN_DIR/lane.log" 2>&1 &
    echo $! > "$LANE_RUN_DIR/runner.pid"
    wait $(cat "$LANE_RUN_DIR/runner.pid")
    echo "CONDUCT_EXIT=$?" >> "$LANE_RUN_DIR/lane.log"
    bash core/scripts/conduct-pool.sh --session-id "$HQ_SESSION_ID" record --worker-id "$LANE_WORKER_ID" \
      --subagent-id "$(basename "$LANE_RUN_DIR")" --status idle >/dev/null 2>&1 || true
  ' || { echo "conduct-lane-launch: hq-detach failed" >&2; exit 3; }

  # Proof of escape: the wrapper leads its own process group.
  local lane_pid="" pgid="" detached=false i=0
  while [ "$i" -lt 50 ]; do
    [ -s "$abs/lane.pid" ] && break
    sleep 0.1; i=$((i + 1))
  done
  lane_pid="$(cat "$abs/lane.pid" 2>/dev/null || true)"
  if [ -n "$lane_pid" ]; then
    pgid="$(ps -o pgid= -p "$lane_pid" 2>/dev/null | tr -d ' ' || true)"
    [ "$pgid" = "$lane_pid" ] && detached=true
    # A lane that already finished has no process to inspect; its marker is the proof.
    if [ -z "$pgid" ] && grep -q 'CONDUCT_EXIT=' "$abs/lane.log" 2>/dev/null; then detached=true; fi
  fi

  bash core/scripts/conduct-pool.sh --session-id "$SID" record --worker-id "$worker" \
    --subagent-id "$(basename "$rel")" --status running >/dev/null 2>&1 \
    || echo "conduct-lane-launch: warning: could not record $worker running in the pool" >&2
  # A lane fast enough to exit before the record above would be left running.
  if grep -q 'CONDUCT_EXIT=' "$abs/lane.log" 2>/dev/null; then
    bash core/scripts/conduct-pool.sh --session-id "$SID" record --worker-id "$worker" \
      --subagent-id "$(basename "$rel")" --status idle >/dev/null 2>&1 || true
  fi

  jq -cn --arg run_dir "$rel" --arg run_dir_abs "$abs" --arg worker "$worker" \
    --arg engine "$engine" --arg model "$model" --arg effort "$effort" --arg tier "$tier" \
    --arg deadline "$(cat "$abs/deadline")" --arg lane_pid "$lane_pid" \
    --argjson detached "$detached" \
    '{run_dir:$run_dir, run_dir_abs:$run_dir_abs, run_id:($run_dir|split("/")|last),
      worker_id:$worker, engine:$engine,
      model:(if $model=="" then null else $model end),
      effort:(if $effort=="" then null else $effort end),
      tier:$tier, deadline:($deadline|tonumber),
      lane_pid:(if $lane_pid=="" then null else ($lane_pid|tonumber) end),
      detached:$detached}'
  if [ "$detached" != true ]; then
    echo "conduct-lane-launch: lane did not prove it escaped the turn (lane.pid=${lane_pid:-none}); check $rel/lane.log" >&2
    exit 3
  fi
}

SID=""
sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  mint) cmd_mint "$@" ;;
  start) cmd_start "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "conduct-lane-launch: unknown subcommand: $sub" >&2; usage >&2; exit 1 ;;
esac
