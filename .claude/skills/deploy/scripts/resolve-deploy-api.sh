#!/usr/bin/env bash
# resolve-deploy-api.sh — print the hq-deploy API base URL for the /deploy engine.
#
# Resolution order (first non-empty wins):
#   1. $HQ_DEPLOY_API                                       explicit per-shell override
#   2. companies/manifest.yaml services.hq-deploy.endpoint  tenant config (nearest, walking up from cwd)
#   3. https://api.indigo-hq.com                            ALWAYS-ON public default (Hassaan directive)
#
# The public default is the load-bearing part. Without it, a fresh install (no
# companies/manifest.yaml and no $HQ_DEPLOY_API in the environment) resolves the
# deploy API base to the EMPTY string, and the /deploy skill then stalls at
# Phase C — its upload curls hit "$API/api/apps" == "/api/apps", an empty host.
# This resolver GUARANTEES a non-empty base so Phase C can always proceed, and
# uses the same public default as project-summary/scripts/deploy-summary.sh so
# the two stay reconciled.
#
# nounset-safe (guards $HQ_DEPLOY_API) and always exits 0 with a non-empty line.
set -euo pipefail

API="${HQ_DEPLOY_API:-}"

# Optional tenant override: nearest companies/manifest.yaml walking up from cwd.
if [ -z "$API" ]; then
  d="$(pwd -P)"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/companies/manifest.yaml" ]; then
      API="$(awk -F'endpoint:[ \t]*' '/hq-deploy/{f=1} f&&/endpoint:/{gsub(/[ \t\r]+$/,"",$2); print $2; exit}' "$d/companies/manifest.yaml" 2>/dev/null || true)"
      break
    fi
    d="$(dirname "$d")"
  done
fi

# Always-on public default — never emit an empty base.
API="${API:-https://api.indigo-hq.com}"

printf '%s\n' "$API"
