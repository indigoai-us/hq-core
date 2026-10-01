#!/bin/bash
# Deliver hq monitor events from Claude, Codex, and Grok hooks.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/hq-monitor-hook-lib.sh"

action="${1:-drain}"
event="${2:-}"
payload="$(cat)" || payload='{}'
root="$(hq_monitor_root)"
[ -n "$root" ] || exit 0
if [ -f "$root/.claude/hooks/hook-timeout-probe.sh" ]; then
  . "$root/.claude/hooks/hook-timeout-probe.sh"
else
  hook_timeout_child_phase_start() { :; }
  hook_timeout_child_phase_finish() { :; }
fi
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

if [ "$action" = "wait" ]; then
  # The Stop waiter is the only path that wakes an idle Claude session, so it
  # must not end on a transient CLI failure. When hq is missing, lacks the
  # monitor command, or exits with anything but 0 (nothing to deliver) or 2
  # (wake), retry: hq replaces itself during self-update, and one failed start
  # otherwise leaves every later event queued until the user's next message.
  retry_secs="${HQ_MONITOR_WAIT_RETRY_SECS:-15}"
  retry_max="${HQ_MONITOR_WAIT_RETRY_MAX:-240}"
  # A malformed override must not disable the retry budget.
  case "$retry_max" in ''|*[!0-9]*|0) retry_max=240 ;; esac
  case "$retry_secs" in ''|*[!0-9.]*|*.*.*|.) retry_secs=15 ;; esac
  out_file="$(mktemp 2>/dev/null)" || out_file="${TMPDIR:-/tmp}/hq-monitor-wait.$$"
  trap 'rm -f "$out_file"' EXIT
  tries=0
  while :; do
    rc=1
    if ! command -v hq >/dev/null 2>&1; then
      hq_monitor_log_once "$root" "$payload" wait-cli-unavailable "hq is unavailable; the Stop waiter is retrying"
    elif ! HQ_NO_UPDATE_CHECK=1 hq --help 2>/dev/null | grep -Eq '^[[:space:]]+monitor([[:space:]]|$)'; then
      hq_monitor_log_once "$root" "$payload" wait-cli-not-ready "installed hq CLI has no monitor command yet; the Stop waiter is retrying"
    else
      rc=0
      # Buffer each attempt: only a terminal attempt's stdout reaches the
      # async-rewake consumer, so a failed attempt cannot corrupt the payload.
      HQ_NO_UPDATE_CHECK=1 hq monitor wait --provider claude <<<"$payload" >"$out_file" || rc=$?
      case "$rc" in
        0|2) cat "$out_file"; exit "$rc" ;;
      esac
      hq_monitor_log_once "$root" "$payload" wait-failed "hq monitor wait exited $rc; the Stop waiter is retrying"
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge "$retry_max" ]; then
      hq_monitor_log_once "$root" "$payload" wait-gave-up "the Stop waiter gave up after $tries failed attempts; events wait for the next prompt"
      exit 0
    fi
    sleep "$retry_secs"
  done
fi

if ! command -v hq >/dev/null 2>&1; then
  hq_monitor_log_once "$root" "$payload" cli-unavailable "hq is unavailable; monitor delivery is disabled"
  exit 0
fi
hook_timeout_child_phase_start probe
if ! hq_monitor_cli_ready "$root" "$payload" "$provider-$session_id"; then
  hook_timeout_child_phase_finish probe
  exit 0
fi
hook_timeout_child_phase_finish probe
hook_timeout_child_phase_start child_wait
exec env HQ_NO_UPDATE_CHECK=1 hq monitor drain --provider "$provider" --event "$event" <<<"$payload"
