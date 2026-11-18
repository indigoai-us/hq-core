#!/usr/bin/env bash
# setup-worker-app-first-connectors.test.sh - guards the setup worker's rule
# that it already knows which tools need a private app.
#
# Owner run on a fresh test VM (2026-11-13): the person answered "Shopify" and
# the setup bot planned an "Open the Shopify sign-in" step, ran
# `hq integrations connect shopify.com`, was refused ("doesn't accept new
# client registrations"), searched the web and read Shopify's docs, and only
# then told the person to create a private app. It took about two minutes and
# never mentioned systems that already hold the data. The business skill said
# to discover every connection from scratch and to suggest an aggregator only
# when the direct route was impossible.
#
# The worker instructions are prose, so this pins the rules that stop it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BUSINESS="$ROOT/core/workers/public/setup/skills/your-business.md"

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok - $1"; }

[ -f "$BUSINESS" ] || fail "missing $BUSINESS"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# Flatten line breaks so a phrase wrapped across lines still matches.
tr '\n' ' ' < "$BUSINESS" | tr -s ' ' > "$TMPD/business.txt"
has() { grep -qF -- "$1" "$TMPD/business.txt"; }

echo "business skill: knows which tools need a private app"
has '### Tools that only let approved AI apps sign in' || fail "no section for tools that only let approved AI apps sign in"
has '**Shopify.**' || fail "Shopify is not listed as a private-app tool"
has '**Meta** (Facebook and Instagram ads).' || fail "Meta is not listed as a private-app tool"
has 'Do not try `hq integrations connect`, do not search the web, and do not plan an "Open the sign-in" step for them' \
  || fail "the skill must stop the bot from rediscovering the private-app route"
has "doesn't accept new client registrations" || fail "the skill must say how to recognise another tool like this"
ok "Shopify and Meta go straight to the private app"

echo "business skill: the first reply also offers systems that already hold the data"
has 'your very first reply says both of these things' || fail "the first reply must carry both points"
for name in 'BigQuery' 'Snowflake' 'Triple Whale' 'Northbeam' 'Polar' 'vyg'; do
  has "$name" || fail "the data-source recommendation must name $name"
done
has 'If they have one, recommend connecting it first' || fail "an existing data source must be recommended first"
ok "data warehouse, Triple Whale, Northbeam, Polar and vyg are offered up front"

echo "business skill: the old last-resort aggregator rule is gone"
if has 'Only suggest a substitute (for example a commerce aggregator instead of Shopify itself)'; then
  fail "your-business.md still treats a commerce aggregator for Shopify as a last resort"
fi
ok "aggregators are no longer a last resort for Shopify"

echo "PASS: $PASS checks"
