#!/usr/bin/env bash
# hq-core: public
# The Codex and Grok adapters share hqad_iter_settings(). A missing or corrupt
# settings file must retain the critical policy Bash guard, not fail open.
set -euo pipefail

ROOT="${HQ_TEST_ROOT:-$(git rev-parse --show-toplevel)}"
SRC="$ROOT/core/scripts/lib/hook-adapter-core.sh"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts/lib"
cp "$SRC" "$FIX/core/scripts/lib/hook-adapter-core.sh"
: > "$FIX/.claude/hooks/block-policy-writes-bash.sh"

assert_fallback() { # <label>
  local label="$1" records
  records="$(
    set +u
    HQ_ROOT="$FIX"
    . "$FIX/core/scripts/lib/hook-adapter-core.sh"
    hqad_iter_settings PreToolUse Bash
  )"
  if printf '%s\n' "$records" | grep -q $'^gate\tblock-policy-writes-bash\t'; then
    pass "$label retains block-policy-writes-bash"
  else
    fail "$label dropped block-policy-writes-bash: $records"
  fi
}

echo "[1] missing settings uses the policy Bash fallback"
assert_fallback "missing settings"

echo "[2] corrupt settings uses the policy Bash fallback"
printf '{\n' > "$FIX/.claude/settings.json"
assert_fallback "corrupt settings"

echo "hook-adapter-policy-fallback: ok"
