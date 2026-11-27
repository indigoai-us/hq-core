#!/usr/bin/env bash
# Nightly only: this waits out a real 1 s perl alarm on a master-hook child and checks the measured elapsed time in the timeout event, so it does not run on pull requests.
#
# Runs section 17 of hook-timeout-sentry.test.sh: a folder hook cut at
# HQ_MASTER_CHILD_TIMEOUT=1 emits one hook_timeout_exceeded event with exit
# code 124, the declared 1000 ms limit and a final elapsed time of at least
# 900 ms.
set -euo pipefail
exec env HQ_SENTRY_CHILD_TIMEOUT_REAL_TIME=1 bash "$(cd "$(dirname "$0")" && pwd)/hook-timeout-sentry.test.sh" "$@"
