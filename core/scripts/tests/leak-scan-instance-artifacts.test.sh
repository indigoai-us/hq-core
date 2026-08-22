#!/usr/bin/env bash
# Regression coverage for the `instance-artifacts` leak-scan mode: operator and
# session instance state must never ship in hq-core. The scan must pass a clean
# scaffold (only .gitkeep under workspace/ and personal/, plus personal/CLAUDE.md)
# and reject any other tracked file under those trees.
#
# Context: user-specific threads, checkpoints, insights, and personal policies/
# settings had leaked into workspace/ and personal/ in hq-core-staging. This
# mode is the tripwire that blocks a recurrence on every PR.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCAN="$ROOT/.leak-scan/scan.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$SCAN" ]] || fail "scan.sh missing: $SCAN"

# Build an isolated git repo fixture — the scan reads `git ls-files`.
FX="$TMP/repo"
mkdir -p "$FX/.leak-scan" "$FX/workspace/threads" "$FX/workspace/insights" \
         "$FX/personal/policies" "$FX/personal/settings"
cp "$SCAN" "$FX/.leak-scan/scan.sh"

git -C "$FX" init -q
git -C "$FX" config user.email t@t.t
git -C "$FX" config user.name t

# Clean scaffold: only .gitkeep placeholders + the personal/CLAUDE.md scaffold.
touch "$FX/workspace/threads/.gitkeep" \
      "$FX/workspace/insights/.gitkeep" \
      "$FX/personal/policies/.gitkeep" \
      "$FX/personal/settings/.gitkeep"
printf '# personal scaffold\n' > "$FX/personal/CLAUDE.md"
git -C "$FX" add -A
git -C "$FX" commit -qm scaffold

# Case A: clean scaffold passes.
out="$( ( cd "$FX" && bash .leak-scan/scan.sh instance-artifacts ) 2>&1 )" \
  || fail "Case A: clean scaffold should pass; got:\n${out}"
printf '%s\n' "$out" | grep -q 'instance-artifacts: clean' \
  || fail "Case A: expected clean output; got:\n${out}"

# Case B: a leaked session thread under workspace/ must fail and be named.
printf '{}' > "$FX/workspace/threads/T-20260101-leak.json"
git -C "$FX" add -A && git -C "$FX" commit -qm thread-leak
if out="$( ( cd "$FX" && bash .leak-scan/scan.sh instance-artifacts ) 2>&1 )"; then
  fail "Case B: leaked workspace thread should fail, but passed:\n${out}"
fi
printf '%s\n' "$out" | grep -q 'workspace/threads/T-20260101-leak.json' \
  || fail "Case B: failure must name the leaked thread; got:\n${out}"
git -C "$FX" rm -q "workspace/threads/T-20260101-leak.json"
git -C "$FX" commit -qm drop-thread

# Case C: a leaked personal policy under personal/ must fail and be named.
printf '# owner policy\n' > "$FX/personal/policies/my-owner-rule.md"
git -C "$FX" add -A && git -C "$FX" commit -qm personal-leak
if out="$( ( cd "$FX" && bash .leak-scan/scan.sh instance-artifacts ) 2>&1 )"; then
  fail "Case C: leaked personal policy should fail, but passed:\n${out}"
fi
printf '%s\n' "$out" | grep -q 'personal/policies/my-owner-rule.md' \
  || fail "Case C: failure must name the leaked personal file; got:\n${out}"
git -C "$FX" rm -q "personal/policies/my-owner-rule.md"
git -C "$FX" commit -qm drop-personal

# Case D: back to clean once the leaks are removed.
out="$( ( cd "$FX" && bash .leak-scan/scan.sh instance-artifacts ) 2>&1 )" \
  || fail "Case D: scaffold should be clean again after removing leaks; got:\n${out}"

# Case E: the live release tree must be clean.
out="$( ( cd "$ROOT" && bash .leak-scan/scan.sh instance-artifacts ) 2>&1 )" \
  || fail "Case E: live tree carries instance leakage under workspace/ or personal/:\n${out}"

echo "OK: leak-scan instance-artifacts guard passes clean and rejects leaks"
