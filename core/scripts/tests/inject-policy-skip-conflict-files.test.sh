#!/usr/bin/env bash
# hq-core: public
# Regression: .claude/hooks/inject-policy-on-trigger.sh must SKIP sync
# conflict/drift copies when collecting policy files.
#
# Cross-machine sync (iCloud/Dropbox/Syncthing/hq-sync) mints conflict copies
# like `foo 2.md`, `foo 100.md`, `foo.sync-conflict-<host>.md`. A runaway can
# leave tens of thousands of them in one policies dir (observed live: 23,413
# files in one core/policies, a single slug at 1000+ copies). Because the hook
# awks EVERY matched *.md on every prompt and every Bash call, that bloat pushed
# the scan past the 60s hook timeout — UserPromptSubmit output was discarded and
# every request stalled a full minute.
#
# Contract: a canonical `<slug>.md` still injects; any *.md whose basename
# contains a space, or matches `*.sync-conflict-*.md`, is never scanned or
# emitted. No legitimate policy slug contains a space, so this can never drop a
# real policy.
#
# Each case builds a throwaway HQ_ROOT so the real policy tree is never read.

set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$HQ_SRC/.claude/hooks/inject-policy-on-trigger.sh"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { pass=$((pass+1)); printf '  ok %s\n' "$1"; }

[ -f "$HOOK" ] || fail "hook not found at $HOOK"

# write_policy <file> <id> <rule-text>  (always-on baseline: fires on any event)
write_policy() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
---
id: $2
title: "$2"
scope: test
when: always
on: [SessionStart]
enforcement: soft
---

## Rule

$3
EOF
}

# run_hook <hq_root> <cwd> <event> <prompt>
run_hook() {
  printf '{"hook_event_name":"%s","cwd":"%s","prompt":"%s"}' "$3" "$2" "$4" \
    | HQ_ROOT="$1" \
      CLAUDE_SESSION_ID="skipconf-test-$$-${RANDOM}" \
      SESSION_ID="skipconf-test-$$-${RANDOM}" \
      bash "$HOOK" 2>/dev/null || true
}

# ── Case 1: canonical injects; conflict/drift copies are skipped ──────────────
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/core/policies" "$ROOT/.claude/hooks"
cp -R "$HQ_SRC/.claude/hooks/_helpers" "$ROOT/.claude/hooks/_helpers" 2>/dev/null || true

write_policy "$ROOT/core/policies/real-slug.md"            "real-slug"       "REAL_MARKER canonical rule."
write_policy "$ROOT/core/policies/real-slug 2.md"          "conflict-two"    "CONFLICT2_MARKER should be skipped."
write_policy "$ROOT/core/policies/bogus 100.md"            "conflict-hundred" "CONFLICT100_MARKER should be skipped."
write_policy "$ROOT/core/policies/weird.sync-conflict-hostA.md" "conflict-sync" "SYNCCONFLICT_MARKER should be skipped."

OUT="$(run_hook "$ROOT" "$ROOT" "UserPromptSubmit" "anything at all")"

echo "$OUT" | grep -q "REAL_MARKER" \
  || fail "case1: canonical policy was NOT emitted. Output was:
$OUT"
ok "canonical <slug>.md still injects"

for marker in CONFLICT2_MARKER CONFLICT100_MARKER SYNCCONFLICT_MARKER; do
  echo "$OUT" | grep -q "$marker" \
    && fail "case1: conflict/drift copy WAS scanned ($marker present). Output was:
$OUT"
  ok "conflict/drift copy skipped ($marker absent)"
done

# ── Case 2: a same-slug conflict copy does not double-inject and does not
#            suppress the canonical (space-name copy of a real slug) ───────────
ROOT2="$(mktemp -d)"; trap 'rm -rf "$ROOT" "$ROOT2"' EXIT
mkdir -p "$ROOT2/core/policies" "$ROOT2/.claude/hooks"
cp -R "$HQ_SRC/.claude/hooks/_helpers" "$ROOT2/.claude/hooks/_helpers" 2>/dev/null || true

write_policy "$ROOT2/core/policies/dupe-me.md"   "dupe-me" "DUPE_CANON only-canonical."
# 25 conflict copies carrying the SAME id — must all be skipped, slug emitted once.
for n in $(seq 2 26); do
  write_policy "$ROOT2/core/policies/dupe-me $n.md" "dupe-me" "DUPE_CONFLICT_$n from a conflict copy."
done

OUT2="$(run_hook "$ROOT2" "$ROOT2" "UserPromptSubmit" "anything")"
echo "$OUT2" | grep -q "DUPE_CANON" \
  || fail "case2: canonical dupe-me was dropped. Output was:
$OUT2"
ok "canonical survives amid many same-slug conflict copies"

echo "$OUT2" | grep -q "DUPE_CONFLICT_" \
  && fail "case2: a conflict-copy body leaked into output. Output was:
$OUT2"
ok "no conflict-copy body leaked"

n="$(printf '%s' "$OUT2" | grep -c 'Policy `dupe-me`' || true)"
[ "$n" = "1" ] || fail "case2: expected slug dupe-me exactly once, got $n"
ok "slug emitted exactly once despite 25 conflict copies"

echo
echo "PASS ($pass assertions)"
