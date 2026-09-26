#!/bin/bash
# Deliver hq monitor events from Claude, Codex, and Grok hooks.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/hq-monitor-hook-lib.sh"

action="${1:-drain}"
event="${2:-}"
payload="$(cat)" || payload='{}'
root="$(hq_monitor_root)"
[ -n "$root" ] || exit 0
read_session_id() {
  local HQ_LIB_WINSEP=0
  . "$root/core/scripts/hook-lib.sh" 2>/dev/null || return 1
  printf '%s' "$payload" | hq_json_get session_id
}

provider="${HQ_CHECKPOINT_RUNTIME:-claude}"
case "$provider" in claude|codex|grok) ;; *) exit 0 ;; esac
session_id="$(read_session_id)" || exit 0
case "$session_id" in ''|*[!A-Za-z0-9_-]*) exit 0 ;; esac
[ "${#session_id}" -le 128 ] || exit 0

session_dir="$root/workspace/monitors/sessions/$provider-$session_id"
active=0
for marker in "$session_dir"/active/*; do
  if [ -e "$marker" ]; then active=1; break; fi
done
inbox="$session_dir/dropbox/inbox.jsonl"
if [ "$active" -eq 0 ] && [ ! -s "$inbox" ]; then
  exit 0
fi

case "$action" in
  drain)
    case "$event" in PreToolUse|UserPromptSubmit) ;; *) exit 0 ;; esac
    # Grok discards UserPromptSubmit output, so draining there would remove
    # events from the inbox without the model seeing them. Grok gets them on
    # the next PreToolUse instead.
    if [ "$provider" = "grok" ] && [ "$event" = "UserPromptSubmit" ]; then
      exit 0
    fi
    ;;
  wait)
    [ "$provider" = "claude" ] || exit 0
    ;;
  *) exit 0 ;;
esac

if ! command -v hq >/dev/null 2>&1; then
  hq_monitor_log_once "$root" "$payload" cli-unavailable "hq is unavailable; monitor delivery is disabled"
  exit 0
fi
if ! hq_monitor_cli_ready "$root" "$payload"; then
  exit 0
fi

if [ "$action" = "wait" ]; then
  exec env HQ_NO_UPDATE_CHECK=1 hq monitor wait --provider claude <<<"$payload"
fi
exec env HQ_NO_UPDATE_CHECK=1 hq monitor drain --provider "$provider" --event "$event" <<<"$payload"
