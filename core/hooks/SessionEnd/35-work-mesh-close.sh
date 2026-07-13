#!/usr/bin/env bash
# hq-core: public
# Thin shim: master-hook discovers only core/hooks/<event>/*.sh, so this leaf
# re-execs the real close-time reconcile+copy logic in the `close` mode. Stdin
# (the SessionEnd event JSON, incl. transcript_path) passes through via exec;
# the mode arg is fixed to `close` (the event name from master-hook is ignored).
# `exec bash <target>` (not `exec <target>`) so a sync-stripped exec bit on the
# real hook doesn't break dispatch.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/work-mesh-close.sh" close
