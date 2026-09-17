#!/usr/bin/env bash
# hq-dm-bind.sh — bind the current session to one HQ DM channel, post
# structured updates to it, and listen for replies (feedback / requests).
#
# Usage:
#   core/scripts/hq-dm-bind.sh bind <channel>                 # bind + set the read cursor to "now"
#   core/scripts/hq-dm-bind.sh status                         # show the binding and cursor
#   core/scripts/hq-dm-bind.sh post --title <t> [--state <s>] [--line <l>]... [--next <l>]... [--ask <l>]...
#   core/scripts/hq-dm-bind.sh post --title <t> - < body.md    # body from stdin (already structured)
#   core/scripts/hq-dm-bind.sh poll                           # print new messages since the cursor, advance it
#   core/scripts/hq-dm-bind.sh listen [--interval 60] [--timeout 1800]
#                                                             # block until a new message arrives (or timeout)
#   core/scripts/hq-dm-bind.sh unbind
#
# The binding lives in the session's meta.yaml (`dm_channel`) via hq-session.sh;
# the cursor is `workspace/sessions/<sid>/dm-bind.cursor` (the last seen sort
# key from `hq dm channel --json`). `listen` is meant to run detached
# (Bash run_in_background): it exits 0 and prints the new messages the moment
# one lands, exits 3 on timeout with nothing new.
#
# Post format (kept deliberately plain — see .claude/skills/dm-bind/SKILL.md):
#   <title> — <state>
#
#   • line
#   • line
#
#   Next: line
#   Need from you: line
set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SESSION_SH="$HQ_ROOT/core/scripts/hq-session.sh"

die() { echo "hq-dm-bind: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need hq; need jq

session_id() { bash "$SESSION_SH" current 2>/dev/null || true; }
session_dir() {
  local sid; sid="$(session_id)"
  [ -n "$sid" ] || die "no current session (hq-session.sh current is empty)"
  local d="$HQ_ROOT/workspace/sessions/$sid"; mkdir -p "$d"; echo "$d"
}
cursor_file() { echo "$(session_dir)/dm-bind.cursor"; }
channel() { bash "$SESSION_SH" get dm_channel 2>/dev/null | tr -d '"' || true; }
require_channel() {
  local ch; ch="$(channel)"
  [ -n "$ch" ] && [ "$ch" != "null" ] || die "session is not bound — run: core/scripts/hq-dm-bind.sh bind <channel>"
  echo "$ch"
}

# Own address, used to skip our own posts when polling. Best effort.
self_email() {
  hq whoami 2>/dev/null | grep -oE '[[:alnum:]._+-]+@[[:alnum:].-]+\.[[:alpha:]]+' | head -1 || true
}

# Normalise `hq dm channel --json` to a JSON array of messages.
fetch_items() {
  local ch="$1" limit="${2:-30}"
  hq dm channel "$ch" --limit "$limit" --json 2>/dev/null \
    | jq -c 'if type=="array" then . else (.messages // .items // []) end' 2>/dev/null \
    || echo '[]'
}

latest_sk() { fetch_items "$1" 5 | jq -r 'last // empty | .sk // empty'; }

cmd_bind() {
  local ch="${1:-}"; [ -n "$ch" ] || die "bind needs a channel name (see: hq channels)"
  ch="${ch#\#}"
  hq channels 2>/dev/null | grep -q -- "hq dm $ch " || die "no channel named '$ch' (see: hq channels)"
  bash "$SESSION_SH" set dm_channel "$ch" >/dev/null
  local sk; sk="$(latest_sk "$ch")"
  printf '%s\n' "$sk" > "$(cursor_file)"
  echo "bound session $(session_id) to #$ch (cursor: ${sk:-<empty>})"
}

cmd_unbind() {
  bash "$SESSION_SH" set dm_channel "" >/dev/null
  rm -f "$(cursor_file)"
  echo "unbound"
}

cmd_status() {
  local ch; ch="$(channel)"
  echo "session:  $(session_id)"
  echo "channel:  ${ch:-<none>}"
  echo "cursor:   $(cat "$(cursor_file)" 2>/dev/null || echo '<none>')"
}

cmd_post() {
  local ch; ch="$(require_channel)"
  local title="" state="" body_from_stdin=0
  local -a lines=() nexts=() asks=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --state) state="$2"; shift 2 ;;
      --line)  lines+=("$2"); shift 2 ;;
      --next)  nexts+=("$2"); shift 2 ;;
      --ask)   asks+=("$2"); shift 2 ;;
      -)       body_from_stdin=1; shift ;;
      *) die "post: unknown arg $1" ;;
    esac
  done
  [ -n "$title" ] || die "post needs --title"
  local msg="$title"; [ -n "$state" ] && msg="$title — $state"
  if [ "$body_from_stdin" = 1 ]; then
    msg="$msg"$'\n\n'"$(cat)"
  else
    if [ ${#lines[@]} -gt 0 ]; then
      msg="$msg"$'\n'
      for l in "${lines[@]}"; do msg="$msg"$'\n'"• $l"; done
    fi
    if [ ${#nexts[@]} -gt 0 ]; then
      msg="$msg"$'\n'
      for l in "${nexts[@]}"; do msg="$msg"$'\n'"Next: $l"; done
    fi
    if [ ${#asks[@]} -gt 0 ]; then
      msg="$msg"$'\n'
      for l in "${asks[@]}"; do msg="$msg"$'\n'"Need from you: $l"; done
    fi
  fi
  hq dm "$ch" "$msg" >/dev/null
  # Our own post must not come back as "new" on the next poll.
  latest_sk "$ch" > "$(cursor_file)"
  echo "posted to #$ch ($(printf '%s' "$msg" | wc -c | tr -d ' ') chars)"
}

# Prints new messages (not ours) since the cursor as "<time> <name>: <body>",
# advances the cursor. Exit 0 if any printed, 3 if none.
cmd_poll() {
  local ch; ch="$(require_channel)"
  local cf; cf="$(cursor_file)"
  local cursor; cursor="$(cat "$cf" 2>/dev/null || true)"
  local me; me="$(self_email)"
  local items; items="$(fetch_items "$ch" 50)"
  local last; last="$(printf '%s' "$items" | jq -r 'last // empty | .sk // empty')"
  local msgs
  msgs="$(printf '%s' "$items" | jq -r --arg cur "$cursor" --arg me "$me" '
    map(select((.sk // "") > $cur and ($me == "" or .fromEmail != $me)))
    | .[]
    | ((.sk // "")[0:16] | sub("T"; " ")) + "Z " + (.fromDisplayName // .fromEmail // "?") + ": " + ((.body // "") | gsub("^\\s+|\\s+$"; ""))')"
  [ -n "$last" ] && printf '%s\n' "$last" > "$cf"
  if [ -n "$(printf '%s' "$msgs" | tr -d '[:space:]')" ]; then printf '%s\n' "$msgs"; return 0; fi
  return 3
}

cmd_listen() {
  local interval=60 timeout=1800
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval) interval="$2"; shift 2 ;;
      --timeout)  timeout="$2"; shift 2 ;;
      *) die "listen: unknown arg $1" ;;
    esac
  done
  local ch; ch="$(require_channel)"
  local deadline=$(( $(date +%s) + timeout ))
  echo "listening on #$ch every ${interval}s (timeout ${timeout}s)"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if cmd_poll; then echo "--- new message(s) on #$ch; handle them, then re-run listen"; return 0; fi
    sleep "$interval"
  done
  echo "no new messages on #$ch within ${timeout}s"; return 3
}

case "${1:-}" in
  bind)   shift; cmd_bind "$@" ;;
  unbind) cmd_unbind ;;
  status) cmd_status ;;
  post)   shift; cmd_post "$@" ;;
  poll)   cmd_poll ;;
  listen) shift; cmd_listen "$@" ;;
  *) sed -n '2,25p' "$0"; exit 2 ;;
esac
