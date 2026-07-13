#!/usr/bin/env bash
# hq-core: public
# Thin shim: master-hook discovers only core/hooks/<event>/*.sh, so this leaf
# re-execs the SessionStart late-reconcile sweep in the `sweep` mode. Stdin (the
# SessionStart event JSON) passes through via exec; the mode arg is fixed to
# `sweep` (the event name from master-hook is ignored). Ordered AFTER
# 35-work-mesh-register.sh so registration for the NEW session runs first.
# `exec bash <target>` (not `exec <target>`) so a sync-stripped exec bit on the
# real hook doesn't break dispatch.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/work-mesh-close.sh" sweep
