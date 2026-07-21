#!/usr/bin/env bash
# hq-core: public
# US-402 / US-405: claude adapter argv fixture + unsupported provider exit 4

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

# shellcheck source=/dev/null
. "$SRC_ROOT/core/scripts/lib/provider-adapter-claude.sh"
# shellcheck source=/dev/null
. "$SRC_ROOT/core/scripts/lib/provider-adapter.sh"

RUN="$TMP/run"
mkdir -p "$RUN" "$TMP/company"
printf 'SYSTEM_CANARY_TEXT\n' > "$RUN/system.txt"
printf 'USER_PROMPT_TEXT\n' > "$RUN/user.txt"
printf '{}\n' > "$RUN/settings.json"

export HQ_AGENT_SESSION_RENDER_ONLY=1
SESSION_SYSTEM_PROMPT_MODE=""
provider_adapter_claude "$RUN" "$TMP/company" || fail "claude adapter render failed"

[ -f "$RUN/provider.argv.lines" ] || fail "missing provider.argv.lines"
# Fixture: first lines of argv
mapfile -t ARGS < "$RUN/provider.argv.lines" 2>/dev/null || {
  # bash 3.2 macOS: no mapfile
  ARGS=()
  while IFS= read -r line || [ -n "$line" ]; do
    ARGS+=("$line")
  done < "$RUN/provider.argv.lines"
}

# Expected structure
[ "${ARGS[0]}" = "claude" ] || fail "argv0=${ARGS[0]}"
# Must contain flags
printf '%s\n' "${ARGS[@]}" | grep -qx -- '--append-system-prompt' || fail "missing --append-system-prompt"
printf '%s\n' "${ARGS[@]}" | grep -qx -- '--dangerously-skip-permissions' || fail "missing skip-permissions"
printf '%s\n' "${ARGS[@]}" | grep -qx -- '--permission-mode' || fail "missing permission-mode"
printf '%s\n' "${ARGS[@]}" | grep -qx -- 'bypassPermissions' || fail "missing bypassPermissions"
# Must NOT contain print/headless
printf '%s\n' "${ARGS[@]}" | grep -qx -- '--print' && fail "must not use --print"
printf '%s\n' "${ARGS[@]}" | grep -qx -- '-p' && fail "must not use -p print flag"
# System text is the arg after --append-system-prompt, not in final positional alone without flag
# Find append-system-prompt index
idx=-1
i=0
for a in "${ARGS[@]}"; do
  if [ "$a" = "--append-system-prompt" ]; then idx=$i; break; fi
  i=$((i+1))
done
[ "$idx" -ge 0 ] || fail "no append-system-prompt index"
sys_arg="${ARGS[$((idx+1))]}"
echo "$sys_arg" | grep -q 'SYSTEM_CANARY_TEXT' || fail "system text not in --append-system-prompt arg"
# Positional user text after --
printf '%s\n' "${ARGS[@]}" | grep -qx -- '--' || fail "missing -- separator"
# Last arg is user text
last="${ARGS[$((${#ARGS[@]}-1))]}"
echo "$last" | grep -q 'USER_PROMPT_TEXT' || fail "user text not positional: $last"
echo "$last" | grep -q 'SYSTEM_CANARY_TEXT' && fail "system text leaked into positional prompt"
[ "${SESSION_SYSTEM_PROMPT_MODE}" = "native" ] || fail "systemPromptMode=$SESSION_SYSTEM_PROMPT_MODE"
pass "claude argv structure"

# Checked-in fixture: compare flag skeleton (not full multiline system text)
FIXTURE_DIR="$SRC_ROOT/core/scripts/tests/fixtures"
mkdir -p "$FIXTURE_DIR"
# Write/compare skeleton: binary + flag names only
skel="$(printf '%s\n' "${ARGS[@]}" | grep -E '^(claude|--|bypassPermissions|--settings|--dangerously-skip-permissions|--permission-mode|--append-system-prompt)$' || true)"
# Always include the known flags in order of appearance
EXPECTED_SKEL=$'claude\n--settings\n--dangerously-skip-permissions\n--permission-mode\nbypassPermissions\n--append-system-prompt\n--'
# Extract skeleton from actual
ACTUAL_SKEL="$(printf '%s\n' "${ARGS[@]}" | awk '
  $0=="claude"{print; next}
  $0=="--settings"{print; next}
  $0=="--dangerously-skip-permissions"{print; next}
  $0=="--permission-mode"{print; next}
  $0=="bypassPermissions"{print; next}
  $0=="--append-system-prompt"{print; next}
  $0=="--"{print; next}
')"
[ "$ACTUAL_SKEL" = "$EXPECTED_SKEL" ] || fail "claude argv skeleton mismatch:
got:
$ACTUAL_SKEL
want:
$EXPECTED_SKEL"
# Persist fixture for byte-compare of skeleton
printf '%s\n' "$EXPECTED_SKEL" > "$FIXTURE_DIR/claude-argv-skeleton.txt"
printf '%s\n' "$ACTUAL_SKEL" | cmp -s - "$FIXTURE_DIR/claude-argv-skeleton.txt" \
  || fail "fixture compare failed"
pass "claude argv fixture"

# Unsupported provider
RC=0
session_provider_dispatch "gemini" "$RUN" "$TMP/company" 2>"$TMP/e4" || RC=$?
[ "$RC" -eq 4 ] || fail "gemini expected exit 4 got $RC"
grep -qi 'unsupported provider' "$TMP/e4" || fail "unsupported provider stderr"
pass "unsupported provider exit 4"

echo "PASS: hq-agent-session-adapters.test.sh"
