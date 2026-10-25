#!/usr/bin/env bash
# hq-core: public
# handoff-archive-decision.sh — decide whether /handoff archives its own
# Claude Code desktop session after the report.
#
# Prints one line to stdout:
#   archive: yes
#   archive: no (<reason>)
#
# The handoff message is read from --args-file (a path, or - for stdin), never
# from argv, and is only split on whitespace. Nothing in it is evaluated.
#
# Precedence, first match wins:
#   1. --no-archive as a token anywhere in the message   -> no
#   2. --archive anywhere except as a leading flag token -> no (ambiguous)
#   3. --archive as a leading flag token                 -> wanted
#   4. env HQ_HANDOFF_ARCHIVE=1|0                        -> wanted / no
#   5. auto_archive in personal/settings/handoff.yaml    -> wanted / no
#   6. auto_archive in core/settings/handoff.yaml        -> wanted / no
#   7. built-in default                                  -> no
# Leading flag tokens are the tokens before the first one that does not start
# with "-". So "--archive wrap up" archives and "don't --archive" does not.
#
# A wanted archive is still refused, in this order, when:
#   - --recovery-pending is passed (the user must read the recovery warning);
#   - the handoff is not on disk: --thread <path> must name a thread JSON file
#     with a matching <id>.changeset.json beside it, and
#     workspace/threads/handoff.json must exist. The pointer is one shared
#     last-writer-wins file, so when another session handed off in the same
#     window (or a vault pull replayed an older copy) it names a different
#     thread. That is still this session's handoff when the pointer carries
#     this session id or the thread file is committed unchanged in the HQ
#     root; an uncommitted thread behind a foreign pointer refuses;
#   - --cwd is inside a linked git worktree with uncommitted changes (the app
#     deletes the session's worktree on archive, which would lose them);
#   - an open PR exists for the current branch of --cwd or any --repo-dir
#     (gh pr list --head <branch> --state open). Checkouts with no git remote
#     and the default branch (main, master, origin/HEAD) are not checked;
#   - the session has background work: --background-running is passed (the
#     agent has background tasks or subagents still running), an active
#     hq lane has this session as its senior (hq lanes list --senior
#     session:<id> --active), or a running hq monitor targets this session
#     (hq monitor list --json);
#   - the session has an ask waiting on the owner: an entry for this session
#     with status queued in workspace/reports/conduct/*-asks.json, or an
#     open or answered (not yet relayed) decision-queue row with source ask
#     and ref <session>:<ask id> in workspace/reports/conduct/*-decisions.jsonl.
# A check that cannot run (gh or hq fails, unreadable records, no session id,
# no jq) refuses with "could not verify ...".
#
# The session id comes from --session-id, then HQ_SESSION_ID,
# CLAUDE_CODE_SESSION_ID, CLAUDE_SESSION_ID, then hq-session.sh current.
# gh and hq are looked up on PATH, so tests can put fakes there.
#
# Usage: handoff-archive-decision.sh [--root <hq-root>] [--args-file <path>|-]
#          [--cwd <dir>] [--repo-dir <dir>]... [--thread <thread path>]
#          [--session-id <id>] [--recovery-pending] [--background-running]
set -uo pipefail

HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
ARGS_FILE=""
CWD="$PWD"
REPO_DIRS=()
THREAD=""
SID=""
RECOVERY_PENDING=0
BACKGROUND_RUNNING=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root)               HQ_ROOT="${2:-$HQ_ROOT}"; shift 2 ;;
    --args-file)          ARGS_FILE="${2:-}"; shift 2 ;;
    --cwd)                CWD="${2:-$CWD}"; shift 2 ;;
    --repo-dir)           [ -n "${2:-}" ] && REPO_DIRS+=("$2"); shift 2 ;;
    --thread)             THREAD="${2:-}"; shift 2 ;;
    --session-id)         SID="${2:-}"; shift 2 ;;
    --recovery-pending)   RECOVERY_PENDING=1; shift ;;
    --background-running) BACKGROUND_RUNNING=1; shift ;;
    *)                    shift ;;
  esac
done

no() { echo "archive: no ($1)"; exit 0; }

# ---- handoff message -------------------------------------------------------
ARGS=""
if [ "$ARGS_FILE" = "-" ]; then
  ARGS="$(cat)" || no "could not read the handoff message"
elif [ -n "$ARGS_FILE" ]; then
  [ -f "$ARGS_FILE" ] && [ -r "$ARGS_FILE" ] || no "could not read the handoff message"
  ARGS="$(cat "$ARGS_FILE")" || no "could not read the handoff message"
fi

FLAG_NO=0; FLAG_ARCHIVE=0; FLAG_STRAY=0
set -f
leading=1
# shellcheck disable=SC2086  # split on whitespace on purpose; globbing is off.
for tok in $ARGS; do
  if [ "$leading" = 1 ]; then
    case "$tok" in -*) ;; *) leading=0 ;; esac
  fi
  case "$tok" in
    --no-archive) FLAG_NO=1 ;;
    --archive)    if [ "$leading" = 1 ]; then FLAG_ARCHIVE=1; else FLAG_STRAY=1; fi ;;
    *--archive*)  FLAG_STRAY=1 ;;
  esac
done
set +f

# ---- settings --------------------------------------------------------------
yaml_scalar() {
  local file="$1" key="$2" line=""
  [ -f "$file" ] || return 1
  line="$(grep -E "^${key}:[[:space:]]*" "$file" 2>/dev/null | head -n 1)" || return 1
  [ -n "$line" ] || return 1
  line="${line#*:}"
  line="$(printf '%s' "$line" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^["'"'"']//; s/["'"'"']$//')"
  [ -n "$line" ] || return 1
  printf '%s' "$line"
}

truthy() {
  case "$1" in
    1|true|TRUE|True|on|ON|yes|YES) return 0 ;;
    *)                              return 1 ;;
  esac
}

WANT=""
SOURCE=""
if [ "$FLAG_NO" = 1 ]; then
  no "--no-archive"
elif [ "$FLAG_STRAY" = 1 ]; then
  no "--archive is not a leading flag"
elif [ "$FLAG_ARCHIVE" = 1 ]; then
  WANT=1; SOURCE="flag"
elif [ -n "${HQ_HANDOFF_ARCHIVE:-}" ]; then
  truthy "$HQ_HANDOFF_ARCHIVE" && WANT=1 || WANT=0
  SOURCE="env"
else
  for f in "$HQ_ROOT/personal/settings/handoff.yaml" \
           "$HQ_ROOT/core/settings/handoff.yaml"; do
    if v="$(yaml_scalar "$f" auto_archive)"; then
      truthy "$v" && WANT=1 || WANT=0
      SOURCE="setting"
      break
    fi
  done
fi

if [ "${WANT:-0}" != "1" ]; then
  no "off${SOURCE:+ by $SOURCE}"
fi

# ---- refusals --------------------------------------------------------------
[ "$RECOVERY_PENDING" = "1" ] && no "follow-up recovery pending"

command -v jq >/dev/null 2>&1 || no "could not verify the handoff: jq not found"

# Handoff written: thread file, its changeset, and the handoff.json pointer.
[ -n "$THREAD" ] || no "handoff not verified: no --thread given"
case "$THREAD" in
  /*) thread_abs="$THREAD" ;;
  *)  thread_abs="$HQ_ROOT/$THREAD" ;;
esac
[ -f "$thread_abs" ] || no "handoff not verified: thread file missing"
jq -e 'type == "object"' "$thread_abs" >/dev/null 2>&1 || no "handoff not verified: thread file is not valid JSON"
thread_id="$(basename "$thread_abs" .json)"
[ -f "$(dirname "$thread_abs")/$thread_id.changeset.json" ] || no "handoff not verified: changeset file missing"
pointer="$HQ_ROOT/workspace/threads/handoff.json"
[ -f "$pointer" ] || no "handoff not verified: handoff.json missing"

# Session id (also used by the background-work and pending-ask checks below).
if [ -z "$SID" ]; then
  SID="${HQ_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}}"
fi
if [ -z "$SID" ] && [ -f "$HQ_ROOT/core/scripts/hq-session.sh" ]; then
  SID="$(bash "$HQ_ROOT/core/scripts/hq-session.sh" current 2>/dev/null || true)"
fi

# The pointer names this thread, or this session wrote the pointer, or the
# thread file is committed unchanged in the HQ root. Any one of these proves
# the handoff is durable; the shared pointer alone cannot, since a later
# handoff from another session (or a replayed older copy) overwrites it.
thread_is_committed() {
  local rel root_abs
  root_abs="$(cd "$HQ_ROOT" 2>/dev/null && pwd -P)" || return 1
  rel="$(cd "$(dirname "$thread_abs")" 2>/dev/null && pwd -P)/$(basename "$thread_abs")"
  case "$rel" in "$root_abs"/*) rel="${rel#"$root_abs"/}" ;; *) return 1 ;; esac
  git -C "$HQ_ROOT" rev-parse --git-dir >/dev/null 2>&1 || return 1
  git -C "$HQ_ROOT" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 || return 1
  [ -n "$(git -C "$HQ_ROOT" log -1 --format=%H -- "$rel" 2>/dev/null)" ] || return 1
  [ -z "$(git -C "$HQ_ROOT" status --porcelain -- "$rel" 2>/dev/null)" ] || return 1
  return 0
}
if ! jq -e --arg id "$thread_id" '.last_thread == $id' "$pointer" >/dev/null 2>&1; then
  if [ -n "$SID" ] && jq -e --arg sid "$SID" '(.session_id // "") == $sid' "$pointer" >/dev/null 2>&1; then
    :
  elif thread_is_committed; then
    :
  else
    no "handoff not verified: handoff.json points at another thread and this thread is not committed"
  fi
fi

# Linked worktree = git dir differs from the common git dir.
real_git_path() {
  local d
  d="$(cd "$CWD" 2>/dev/null && git rev-parse "$1" 2>/dev/null)" || return 1
  [ -n "$d" ] || return 1
  (cd "$CWD" && cd "$d" && pwd -P)
}
if git_dir="$(real_git_path --git-dir)"; then
  common="$(real_git_path --git-common-dir || true)"
  if [ -n "$common" ] && [ "$git_dir" != "$common" ]; then
    if [ -n "$(git -C "$CWD" status --porcelain 2>/dev/null)" ]; then
      no "uncommitted changes in this session's worktree"
    fi
  fi
fi

# Open PRs on the session's branches.
check_open_prs() {
  local dir="$1" branch default prs url
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
  [ -n "$(git -C "$dir" remote 2>/dev/null)" ] || return 0
  branch="$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null)" || return 0
  [ -n "$branch" ] || return 0
  default="$(git -C "$dir" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)"
  default="${default#origin/}"
  case "$branch" in main|master) return 0 ;; esac
  [ -n "$default" ] && [ "$branch" = "$default" ] && return 0
  prs="$(cd "$dir" && gh pr list --head "$branch" --state open --json number,url 2>/dev/null)" \
    || no "could not verify open PRs for branch $branch"
  printf '%s' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || no "could not verify open PRs for branch $branch"
  url="$(printf '%s' "$prs" | jq -r '.[0].url // empty')"
  [ -n "$url" ] && no "open PR on branch $branch: $url"
  return 0
}
check_open_prs "$CWD"
for d in "${REPO_DIRS[@]+"${REPO_DIRS[@]}"}"; do
  check_open_prs "$d"
done

# Background work.
[ "$BACKGROUND_RUNNING" = "1" ] && no "background work running in this session"
[ -n "$SID" ] || no "could not verify background work: no session id"
case "$SID" in *[!A-Za-z0-9._-]*|.*) no "could not verify background work: invalid session id" ;; esac

lanes="$(HQ_NO_UPDATE_CHECK=1 hq lanes list --senior "session:$SID" --active --json 2>/dev/null)" \
  || no "could not verify background work: hq lanes list failed"
n="$(printf '%s' "$lanes" | jq -e 'select(.ok == true) | .lanes | length' 2>/dev/null)" \
  || no "could not verify background work: hq lanes list failed"
[ "$n" -gt 0 ] && no "background work running: $n active lane(s)"

monitors="$(HQ_NO_UPDATE_CHECK=1 hq monitor list --json 2>/dev/null)" \
  || no "could not verify background work: hq monitor list failed"
mon="$(printf '%s' "$monitors" | jq -er --arg sid "$SID" '
  [.monitors[]?
   | select((.target.sessionId // .target.session_id // "") == $sid)
   | select((.state.status // "running") as $s
            | ["stopped","exited","failed","completed","done","killed","cancelled"] | index($s) | not)
   | .monitor_id] | first // ""' 2>/dev/null)" \
  || no "could not verify background work: hq monitor list failed"
[ -n "$mon" ] && no "background work running: monitor $mon"

# Asks waiting on the owner.
conduct="$HQ_ROOT/workspace/reports/conduct"
if [ -d "$conduct" ]; then
  for f in "$conduct"/*-asks.json; do
    [ -f "$f" ] || continue
    ask="$(jq -er --arg sid "$SID" '
      [(.asks // {}) | to_entries[] | .value
       | select(.session == $sid and .status == "queued") | .ask_id] | first // ""' "$f" 2>/dev/null)" \
      || no "could not verify pending asks: $(basename "$f")"
    [ -n "$ask" ] && no "pending ask waiting on the owner: $ask"
  done
  for f in "$conduct"/*-decisions.jsonl; do
    [ -f "$f" ] || continue
    ask="$(jq -ers --arg sid "$SID" '
      [group_by(.id)[] | reduce .[] as $r ({}; . + $r)
       | select(.source == "ask" and (.status == "open" or .status == "answered"))
       | select((.ref // "") | startswith($sid + ":"))
       | .ref | sub("^[^:]*:"; "")] | first // ""' "$f" 2>/dev/null)" \
      || no "could not verify pending asks: $(basename "$f")"
    [ -n "$ask" ] && no "pending ask waiting on the owner: $ask"
  done
fi

echo "archive: yes"
