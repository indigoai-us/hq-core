#!/usr/bin/env bash
# hq-core: public
# Thin shim: master-hook discovers only core/hooks/<event>/*.sh.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/work-mesh-ground.sh" "$@"
