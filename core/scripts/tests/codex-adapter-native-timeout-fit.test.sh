#!/usr/bin/env bash
# hq-core: public
# Nightly only: this measures real elapsed time against each Codex hook timeout
# in .codex/config.toml (about a minute of waiting), so it does not run on pull
# requests.
#
# Runs section 4 of codex-adapter-native-steps-aside.test.sh: for every event,
# an engine that answered before but writes no mark now, with the longest wait
# asked for, still leaves the Codex adapter answering at least 1 s inside the
# event's timeout. The pull-request test covers the adapter's behaviour with a
# short wait; this covers the wait caps against the real timeouts.

set -euo pipefail
exec env CNSA_TIMEOUT_FIT=1 bash "$(cd "$(dirname "$0")" && pwd)/codex-adapter-native-steps-aside.test.sh" "$@"
