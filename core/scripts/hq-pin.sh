#!/usr/bin/env bash
# hq-pin.sh — anchor the current session to one goal (the "pin").
#
# A pin is the message, goal, or target the session keeps working toward
# across loops, wakeups, compactions, and hand-offs. It is stored per session
# and re-read at every checkpoint so the session cannot drift.
#
# Usage:
#   core/scripts/hq-pin.sh set  "<goal>" [--done "<criterion>"]... [--owner <name>] [--channel <dm-channel>]
#   core/scripts/hq-pin.sh show                # print the pin (goal, done criteria, owner, channel, set-at)
#   core/scripts/hq-pin.sh check               # print a one-line reminder for loop ticks; exit 3 if no pin
#   core/scripts/hq-pin.sh note "<progress>"   # append a dated progress line under the pin
#   core/scripts/hq-pin.sh clear               # remove the pin (the goal is met or withdrawn)
#
# Storage: workspace/sessions/<sid>/pin.md plus `pin: <goal>` in the session's
# meta.yaml (via hq-session.sh) so other tooling can see it.
set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SESSION_SH="$HQ_ROOT/core/scripts/hq-session.sh"

die() { echo "hq-pin: $*" >&2; exit 2; }

session_id() { bash "$SESSION_SH" current 2>/dev/null || true; }
pin_file() {
  local sid; sid="$(session_id)"
  [ -n "$sid" ] || die "no current session (hq-session.sh current is empty)"
  local d="$HQ_ROOT/workspace/sessions/$sid"; mkdir -p "$d"; echo "$d/pin.md"
}

cmd_set() {
  local goal="${1:-}"; [ -n "$goal" ] || die "set needs the goal text"; shift
  local owner="" channel=""; local -a done=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --done)    done+=("$2"); shift 2 ;;
      --owner)   owner="$2"; shift 2 ;;
      --channel) channel="$2"; shift 2 ;;
      *) die "set: unknown arg $1" ;;
    esac
  done
  local f; f="$(pin_file)"
  {
    echo "# Pin"
    echo
    echo "Goal: $goal"
    echo
    echo "Set: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ -n "$owner" ]   && echo "Owner: $owner"
    [ -n "$channel" ] && echo "Channel: $channel"
    if [ ${#done[@]} -gt 0 ]; then
      echo
      echo "## Done when"
      for c in "${done[@]}"; do echo "- [ ] $c"; done
    fi
    echo
    echo "## Progress"
  } > "$f"
  bash "$SESSION_SH" set pin "$goal" >/dev/null
  echo "pinned session $(session_id): $goal"
}

cmd_show() {
  local f; f="$(pin_file)"
  [ -f "$f" ] || { echo "no pin for session $(session_id)"; return 3; }
  cat "$f"
}

cmd_check() {
  local f; f="$(pin_file)"
  [ -f "$f" ] || { echo "no pin"; return 3; }
  local goal; goal="$(sed -n 's/^Goal: //p' "$f" | head -1)"
  local open; open="$(grep -c '^- \[ \]' "$f" 2>/dev/null || true)"
  local closed; closed="$(grep -c '^- \[x\]' "$f" 2>/dev/null || true)"
  echo "PIN: $goal (done criteria: ${closed:-0} met, ${open:-0} open)"
}

cmd_note() {
  local text="${1:-}"; [ -n "$text" ] || die "note needs text"
  local f; f="$(pin_file)"
  [ -f "$f" ] || die "no pin to note against"
  printf -- '- %s %s\n' "$(date -u +%H:%MZ)" "$text" >> "$f"
  echo "noted"
}

cmd_done() {
  # Mark a done-criterion met by substring match.
  local needle="${1:-}"; [ -n "$needle" ] || die "done needs a criterion substring"
  local f; f="$(pin_file)"
  [ -f "$f" ] || die "no pin"
  local tmp; tmp="$(mktemp)"
  local hit=0
  while IFS= read -r line; do
    case "$line" in
      "- [ ] "*"$needle"*) echo "- [x] ${line#- [ ] }"; hit=1 ;;
      *) echo "$line" ;;
    esac
  done < "$f" > "$tmp"
  mv "$tmp" "$f"
  [ "$hit" = 1 ] && echo "marked done: $needle" || die "no open criterion matches: $needle"
}

cmd_clear() {
  local f; f="$(pin_file)"
  rm -f "$f"
  bash "$SESSION_SH" set pin "" >/dev/null
  echo "pin cleared"
}

case "${1:-}" in
  set)   shift; cmd_set "$@" ;;
  show)  cmd_show ;;
  check) cmd_check ;;
  note)  shift; cmd_note "$@" ;;
  done)  shift; cmd_done "$@" ;;
  clear) cmd_clear ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
