#!/usr/bin/env bash
# setup-worker-assistant-wording.test.sh - guards the name people see for the
# bot the setup worker runs.
#
# Owner ask 2026-10-19: "setup bot" becomes "your assistant" everywhere a
# person sees it (hq-desktop-app PR 1713 did the app). The setup worker's
# prompt and skills are text the bot may repeat to people, and the user guide
# is read by people, so none of them may call it the setup bot again. The
# worker id, the bot name `setup` and file paths are code names and stay.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SETUP="$ROOT/core/workers/public/setup"
WORKER="$SETUP/worker.yaml"
GUIDE="$ROOT/core/docs/hq/USER-GUIDE.md"

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok - $1"; }

[ -f "$WORKER" ] || fail "missing $WORKER"
[ -d "$SETUP/skills" ] || fail "missing $SETUP/skills"
[ -f "$GUIDE" ] || fail "missing $GUIDE"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# Flatten line breaks so a phrase wrapped across lines still matches.
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

echo "setup worker: no person-facing 'setup bot' wording"
for f in "$WORKER" "$SETUP"/skills/*.md "$GUIDE"; do
  flat "$f" > "$TMPD/flat.txt"
  if grep -qiE 'setup[ -]bot|setup agent' "$TMPD/flat.txt"; then
    fail "${f#"$ROOT"/} still says setup bot or setup agent"
  fi
done
ok "worker.yaml, every setup skill and the user guide are free of 'setup bot'"

flat "$WORKER" > "$TMPD/worker.txt"
grep -q 'You are their HQ assistant, the first bot a person meets in HQ' "$TMPD/worker.txt" \
  || fail "worker.yaml must tell the bot it is the person's HQ assistant"
ok "the worker introduces itself as their HQ assistant"
if grep -q 'You are Setup' "$TMPD/worker.txt"; then
  fail "worker.yaml still names the bot Setup"
fi
ok "the worker no longer calls itself Setup"

grep -q 'like you, their assistant' "$SETUP/skills/pricing.md" \
  || fail "pricing.md must describe the bot as their assistant"
ok "the pricing line the bot may repeat says their assistant"

grep -q 'knowledge and its own bot' "$SETUP/skills/add-a-pack.md" \
  || fail "add-a-pack.md must say a pack brings its own bot, not the person's assistant"
ok "a pack brings its own bot"

flat "$GUIDE" > "$TMPD/guide.txt"
grep -q 'First run creates \*\*your assistant\*\*' "$TMPD/guide.txt" \
  || fail "USER-GUIDE.md must say first run creates your assistant"
ok "the user guide says first run creates your assistant"

# Code names stay as they are.
[ "$(yq -r '.worker.id' "$WORKER" 2>/dev/null || grep -m1 -E '^  id:' "$WORKER" | awk '{print $2}')" = "setup" ] \
  || fail "worker id must stay setup"
ok "worker id stays setup"

echo "setup-worker-assistant-wording: $PASS checks passed"
