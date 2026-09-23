#!/usr/bin/env bash
# Session-close capture wiring: /handoff, /checkpoint, /learn must gate on the
# capture switches and route through the shared doc + candidate writer.
set -uo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
fail=0; pass=0
ok() { pass=$((pass+1)); }; no() { echo "FAIL: $1"; fail=$((fail+1)); }
for s in handoff checkpoint learn; do
  f="$root/.claude/skills/$s/SKILL.md"
  grep -q 'knowledge-prefs.sh get' "$f" && ok || no "$s does not gate on knowledge-prefs.sh"
  grep -q '_shared/session-close-capture.md' "$f" && ok || no "$s does not reference the shared capture doc"
  grep -q 'ontology-candidate.sh' "$f" && ok || no "$s does not name the candidate writer"
done
doc="$root/.claude/skills/_shared/session-close-capture.md"
grep -q 'If both are `false`, stop here' "$doc" && ok || no "shared doc lacks the both-off stop"
grep -q 'Never widen an audience to `company`' "$doc" && ok || no "shared doc lacks the audience guard"

# Switches off: following the documented flow creates no _candidates dir.
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/companies/acme" "$t/personal/settings" "$t/core/scripts"
cp "$root/core/scripts/knowledge-prefs.sh" "$root/core/scripts/ontology-candidate.sh" "$t/core/scripts/"
HQ_ROOT="$t" bash "$t/core/scripts/ontology-candidate.sh" write --company acme --kind signal --type decision \
  --audience company --source-ref handoff:T-x --body "anything" >/dev/null
[ ! -d "$t/companies/acme/signals/_candidates" ] && ok || no "switches off still created _candidates"

echo "session-close-capture: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
