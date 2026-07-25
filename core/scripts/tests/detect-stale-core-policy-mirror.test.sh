#!/usr/bin/env bash
# hq-core: public
# Regression test for core/scripts/detect-stale-core-policy-mirror.sh — the
# drift detector for leftover core/policies copies of a personal/policies twin
# left behind when the personal→core policy mirror was retired.
#
# Locks the load-bearing safety properties:
#   • byte-identical + leftover-symlink twins are classified as prunable orphans
#   • a DIVERGED twin is flagged, never pruned (drift can run either direction)
#   • a release-shipped core policy with NO personal twin is never touched
#   • --prune-identical removes only the orphans and leaves diverged + core-only
#   • --check exit codes: 0 clean, 1 when any twin exists
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/detect-stale-core-policy-mirror.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/personal/policies" "$FIX/core/policies"

policy() { # <dir> <slug> <body>
  cat > "$1/$2.md" <<MD
---
id: $2
title: $2
when: always
on: [SessionStart]
enforcement: soft
public: true
---
$3
MD
}

# 1) identical twin — same bytes in personal and core.
policy "$FIX/personal/policies" identical-twin "same body"
policy "$FIX/core/policies"     identical-twin "same body"

# 2) diverged twin — different bodies (the direction-of-drift hazard).
policy "$FIX/personal/policies" diverged-twin "personal body (has trigger)"
policy "$FIX/core/policies"     diverged-twin "stale core body"

# 3) leftover mirror symlink twin — core points back at personal.
policy "$FIX/personal/policies" symlink-twin "linked body"
ln -s ../../personal/policies/symlink-twin.md "$FIX/core/policies/symlink-twin.md"

# 4) release-shipped core policy with NO personal twin — must never be touched.
policy "$FIX/core/policies" core-only-shipped "release-shipped rule"

# 5) personal-only policy with NO core twin — must never appear.
policy "$FIX/personal/policies" personal-only "operator rule"

run() { HQ_ROOT="$FIX" bash "$SCRIPT" "$@"; }

# --- JSON classification -----------------------------------------------------
JSON="$(run --json)"
case "$JSON" in
  *'"policy":"identical-twin.md","status":"identical"'*) ok "identical twin classified identical" ;;
  *) bad "identical twin not classified identical; got: $JSON" ;;
esac
case "$JSON" in
  *'"policy":"diverged-twin.md","status":"diverged"'*) ok "diverged twin classified diverged" ;;
  *) bad "diverged twin not classified diverged; got: $JSON" ;;
esac
case "$JSON" in
  *'"policy":"symlink-twin.md","status":"symlink"'*) ok "symlink twin classified symlink" ;;
  *) bad "symlink twin not classified symlink; got: $JSON" ;;
esac
case "$JSON" in
  *core-only-shipped*) bad "core-only shipped policy leaked into report" ;;
  *) ok "core-only shipped policy is not reported (never a twin)" ;;
esac
case "$JSON" in
  *personal-only*) bad "personal-only policy leaked into report" ;;
  *) ok "personal-only policy is not reported (no core twin)" ;;
esac

# --- --check exit code on a dirty tree --------------------------------------
if run --check >/dev/null 2>&1; then
  bad "--check returned 0 on a tree with twins"
else
  rc=$?
  [ "$rc" -eq 1 ] && ok "--check exits 1 when twins exist" || bad "--check exit was $rc, want 1"
fi

# --- --prune-identical removes only orphans ---------------------------------
run --prune-identical >/dev/null
[ -e "$FIX/core/policies/identical-twin.md" ] && bad "identical orphan not pruned" || ok "identical orphan pruned"
if [ -e "$FIX/core/policies/symlink-twin.md" ] || [ -L "$FIX/core/policies/symlink-twin.md" ]; then
  bad "symlink orphan not pruned"
else
  ok "symlink orphan pruned"
fi
[ -f "$FIX/core/policies/diverged-twin.md" ] && ok "diverged twin preserved (needs human classification)" || bad "diverged twin was removed"
[ -f "$FIX/core/policies/core-only-shipped.md" ] && ok "core-only shipped policy preserved" || bad "core-only shipped policy was removed"
[ -f "$FIX/personal/policies/identical-twin.md" ] && ok "personal twin never touched" || bad "personal twin was removed"

# --- --check is now clean-but-for-diverged (still a twin) → exit 1 -----------
# The diverged twin remains, so drift is still present.
if run --check >/dev/null 2>&1; then
  bad "--check returned 0 while a diverged twin remains"
else
  ok "--check still reports drift while diverged twin awaits classification"
fi

# --- fully clean tree exits 0 -----------------------------------------------
rm -f "$FIX/core/policies/diverged-twin.md"
if run --check >/dev/null 2>&1; then
  ok "--check exits 0 on a clean tree"
else
  bad "--check nonzero on a clean tree"
fi

echo "detect-stale-core-policy-mirror: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
