#!/bin/bash
# Explain monitor delivery to interactive runtimes without a native Monitor tool.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/hq-monitor-hook-lib.sh"

payload="$(</dev/stdin)" || payload='{}'
root="$(hq_monitor_root)"
[ -n "$root" ] || exit 0
provider="${HQ_CHECKPOINT_RUNTIME:-claude}"
case "$provider" in codex|grok) ;; *) exit 0 ;; esac
if ! hq_monitor_enabled "$root" "$payload"; then
  exit 0
fi
printf '%s\n' 'For long waits, use `hq monitor start`; it checks in every 55 minutes to keep prompt caching within the one-hour window.'
