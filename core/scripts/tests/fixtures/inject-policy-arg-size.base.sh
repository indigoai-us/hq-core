#!/usr/bin/env bash
# Frozen RED fixture for the former evaluator handoff. Keep this checked in so
# the regression does not depend on a moving branch ref or on the repository's
# current implementation of inject-policy-on-trigger.sh.

set -euo pipefail

FACTS_FILE="${1:?facts file required}"
LEDGER_FILE="${2:?ledger file required}"
FACTS="$(<"$FACTS_FILE")"
LEDGER="$(<"$LEDGER_FILE")"

# This is the retired argv handoff: Linux rejects the exec before a policy can
# be evaluated once either value exceeds its per-string argument limit.
awk -v EVFACTS="$FACTS" -v ALREADY="$LEDGER" 'BEGIN { print "large-fact-policy" }'
