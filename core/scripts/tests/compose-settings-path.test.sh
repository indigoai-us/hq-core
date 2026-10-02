#!/usr/bin/env bash
# hq-core: public
# Regression test for compose-settings-path.sh + setup's PATH configuration
# helper and the template settings.json.
#
# Covers the installer→Claude PATH gap: the native installer provisions
# qmd/hq/node into a managed toolchain wired into PATH only via an
# interactive-shell profile block, while .claude/settings.json's env.PATH is
# applied LITERALLY to every hook/subagent shell. Two regressions guarded:
#   1. The shipped template must not hardcode a machine-specific env.PATH
#      (it used to ship homebrew+system dirs with no toolchain — hooks in
#      fresh installs couldn't find qmd until setup.sh re-snapshotted).
#   2. The setup.sh snapshot must include the managed toolchain dirs even
#      when the current session's PATH is missing them (GUI-launched Claude
#      never sources the profile block).

set -euo pipefail

SRC_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$SRC_ROOT/core/scripts/compose-settings-path.sh"
TMP="$(mktemp -d)"
TOOLCHAIN="$TMP/toolchain"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# ── 1. Template ships no hardcoded env.PATH ─────────────────────────────────

if command -v jq >/dev/null 2>&1; then
  TEMPLATE_PATH="$(jq -r '.env.PATH // empty' "$SRC_ROOT/.claude/settings.json")"
  [[ -z "$TEMPLATE_PATH" ]] ||
    fail "template .claude/settings.json hardcodes env.PATH ($TEMPLATE_PATH) — it must be machine-agnostic; setup.sh/the installer write the real snapshot"
else
  echo "  • template env.PATH check skipped (jq missing)"
fi

# ── 2. User directories named tmp/temp are not temporary roots ──────────────

USER_PATH="/home/u/tmp/bin:/opt/temp/bin:/usr/bin:/bin"
OUT="$(TMPDIR="$TMP" HQ_TOOLCHAIN_DIR="$TMP/no-toolchain" bash "$SCRIPT" "$USER_PATH")"
[[ "$OUT" == "$USER_PATH" ]] ||
  fail "user PATH entries with tmp/temp names were filtered — got: $OUT"

# ── 3. Toolchain dirs on disk but missing from PATH → prepended ─────────────

mkdir -p "$TOOLCHAIN/node/bin" "$TOOLCHAIN/npm-global/bin" "$TOOLCHAIN/git/bin"

BASE="/usr/bin:/bin"
OUT="$(HQ_TOOLCHAIN_DIR="$TOOLCHAIN" bash "$SCRIPT" "$BASE")"

[[ "$OUT" == "$TOOLCHAIN/node/bin:$TOOLCHAIN/npm-global/bin:$TOOLCHAIN/git/bin:$BASE" ]] ||
  fail "toolchain dirs not prepended in installer order — got: $OUT"

# ── 4. Toolchain dirs already on PATH → no duplicates ───────────────────────

OUT="$(HQ_TOOLCHAIN_DIR="$TOOLCHAIN" bash "$SCRIPT" "$OUT")"
NODE_COUNT="$(tr ':' '\n' <<<"$OUT" | grep -cx "$TOOLCHAIN/node/bin")"
[[ "$NODE_COUNT" == "1" ]] || fail "toolchain dir duplicated on re-run — got: $OUT"

# ── 5. Existing order is kept; duplicates and temporary paths are removed ──

NOISY="/user/bin:/usr/bin:/user/bin:$TMP/cache/_npx/abc/bin:/user/run:/bin"
EXPECTED="$TOOLCHAIN/node/bin:$TOOLCHAIN/npm-global/bin:$TOOLCHAIN/git/bin:/user/bin:/usr/bin:/user/run:/bin"
OUT="$(TMPDIR="$TMP" HQ_TOOLCHAIN_DIR="$TOOLCHAIN" bash "$SCRIPT" "$NOISY")"
[[ "$OUT" == "$EXPECTED" ]] ||
  fail "toolchain priority, PATH order, dedupe, and temporary filtering — got: $OUT"

# ── 6. No toolchain on disk → base passes through untouched ─────────────────

OUT="$(HQ_TOOLCHAIN_DIR="$TMP/does-not-exist" bash "$SCRIPT" "$BASE")"
[[ "$OUT" == "$BASE" ]] || fail "base PATH altered without a toolchain on disk — got: $OUT"

# ── 7. setup.sh delegates PATH configuration to the tested helper ──────────

grep -q 'configure-settings-path.sh' "$SRC_ROOT/core/scripts/setup.sh" ||
  fail "setup.sh no longer delegates PATH setup to configure-settings-path.sh"
grep -q 'compose-settings-path.sh' "$SRC_ROOT/core/scripts/configure-settings-path.sh" ||
  fail "PATH configuration helper no longer composes the PATH snapshot"

echo "PASS: compose-settings-path regression suite"
