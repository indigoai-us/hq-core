#!/usr/bin/env bash
# setup-worker-infers-before-asking.test.sh - guards the setup worker's rule
# that it does not ask what the person already told it.
#
# Owner run rc-run-1011-1449 (2026-10-11): the person wrote "I run an
# independent software engineering company" and the setup bot asked "Do you
# mostly build software for clients, or your own product?". The business skill
# allowed "at most one follow-up if it changes the recommendations", and its
# "Agency or services firm" profile (which listed "development") overlapped
# with "Software or product company", so the bot asked the person to pick.
#
# The worker instructions are prose, so this pins the rules that stop it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKER="$ROOT/core/workers/public/setup/worker.yaml"
BUSINESS="$ROOT/core/workers/public/setup/skills/your-business.md"

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok - $1"; }

[ -f "$WORKER" ] || fail "missing $WORKER"
[ -f "$BUSINESS" ] || fail "missing $BUSINESS"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# Flatten line breaks so a phrase wrapped across lines still matches.
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }
flat "$WORKER" > "$TMPD/worker.txt"
flat "$BUSINESS" > "$TMPD/business.txt"

echo "setup worker: a standing rule not to ask what it can already tell"
grep -q 'Never ask what you can already tell' "$TMPD/worker.txt" || fail "How you talk has no never-ask-what-you-can-tell rule"
grep -q "check whether the person's own words, a handoff from the app, the import report or this HQ already answer it" "$TMPD/worker.txt" \
  || fail "the rule must name what to check before asking"
grep -q 'do not ask whether it is for clients or their own product' "$TMPD/worker.txt" \
  || fail "the rule must carry the owner run's example"
grep -q 'It never replaces the explicit yes that "Confirm before anything leaves this Mac" requires' "$TMPD/worker.txt" \
  || fail "the no-ask rule must not override the explicit yes for outward-facing actions"
ok "never ask what you can tell, and never skip a required yes"

echo "setup worker: step 4 decides the business instead of asking the person to pick"
grep -q 'never ask them to choose between two kinds of business' "$TMPD/worker.txt" \
  || fail "step 4 must forbid asking the person to choose between kinds of business"
ok "step 4 decides"

echo "business skill: the open-ended follow-up licence is gone"
if grep -q 'Ask at most one follow-up if it changes the recommendations' "$TMPD/business.txt"; then
  fail "your-business.md still allows a follow-up whenever it changes the recommendations"
fi
grep -q 'never ask them to choose between two profiles' "$TMPD/business.txt" \
  || fail "your-business.md must say not to ask the person to choose between profiles"
grep -q 'Never ask a follow-up whose answer is already in what they told you' "$TMPD/business.txt" \
  || fail "your-business.md must forbid a follow-up the person already answered"
if grep -q 'Is that right?' "$TMPD/business.txt"; then
  fail "your-business.md still confirms its reading as a separate question"
fi
ok "follow-ups only for what is unknown"

echo "business skill: the owner run's words map to services, and the profiles no longer overlap"
grep -q '"I run an independent software engineering company" is a software services firm' "$TMPD/business.txt" \
  || fail "the owner run's sentence must map to the services profile"
for word in consultancy agency 'dev shop' contractor 'for clients'; do
  grep -qi "$word" "$TMPD/business.txt" || fail "client-work signal '$word' is not named"
done
# "Independent" alone is not client work: an independent bookshop is not.
grep -q 'An independent bookshop or a game studio that sells its own games is not' "$TMPD/business.txt" \
  || fail "the signals must say a bare 'independent' or 'studio' does not make client work"
# The freelancer profile and the services profile must say which one wins.
grep -q 'A freelancer is one person doing client work' "$TMPD/business.txt" \
  || fail "the signals must say how a freelancer maps between the two profiles"
grep -q 'software development for clients' "$TMPD/business.txt" \
  || fail "the services profile must name software development for clients"
grep -q 'Someone who builds software for clients is the agency or services profile above' "$TMPD/business.txt" \
  || fail "the product profile must send client software work to the services profile"
ok "profiles disjoint, signals named"

echo "business skill: the reading is stated inside the recommendation, and both means both"
grep -q 'Say your reading back inside the message that makes your recommendations' "$TMPD/business.txt" \
  || fail "the reading must be stated with the recommendations, not asked"
grep -q 'When they plainly do both, recommend for both' "$TMPD/business.txt" \
  || fail "someone who does both must get both, not a question"
ok "state, do not ask"

echo "setup worker: no em dashes in the changed files"
if grep -n '—' "$BUSINESS" >/dev/null; then
  fail "your-business.md contains an em dash"
fi
# worker.yaml names the em dash once, in its own no-em-dash rule.
if grep -n '—' "$WORKER" | grep -v 'Check every message for' >/dev/null; then
  fail "worker.yaml contains an em dash outside its no-em-dash rule"
fi
ok "no em dashes"

echo
echo "setup-worker-infers-before-asking: $PASS checks passed"
