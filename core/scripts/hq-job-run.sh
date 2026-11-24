#!/usr/bin/env bash
# hq-core: public
# hq-job-run.sh — one-release forwarder (US-044). Remove in the release after
# the one that ships it.
#
# systemd units written by older reconciles start
#   <root>/core/scripts/hq-job-run.sh --hq-root <root> --job-id <id>
# /update-hq replaces core/ but does not rerun the jobs reconcile, so those
# units keep naming this path until the next reconcile rewrites them to
# `hq core --hq-root <root> job run --job-id <id>`. This stub keeps them
# working in between by handing every argument to the native runner.
set -euo pipefail

if ! command -v hq >/dev/null 2>&1; then
  echo "hq-job-run.sh: the hq CLI is not on PATH; scheduled jobs now run through 'hq core job run'. Install it with: npm install -g @indigoai-us/hq-cli" >&2
  exit 2
fi
export HQ_NO_UPDATE_CHECK=1
exec hq core job run "$@"
