#!/usr/bin/env bash
# hq-core: public
# Thin shim: master-hook discovers only core/hooks/<event>/*.sh, so this file
# re-execs the real logic in core/hooks/work-mesh-register.sh. Stdin (the event
# JSON) and args (the event name) pass through unchanged via exec.
# `exec bash <target>` (not `exec <target>`) so a sync-stripped exec bit on the
# real hook doesn't break dispatch.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/work-mesh-register.sh" "$@"
