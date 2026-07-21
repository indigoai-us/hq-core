#!/usr/bin/env bash
# hq-core: public
# US-402 / US-405: codex + grok adapter argv fixtures

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

# shellcheck source=/dev/null
. "$SRC_ROOT/core/scripts/lib/provider-adapter-claude.sh"  # for _provider_write_argv
# shellcheck source=/dev/null
. "$SRC_ROOT/core/scripts/lib/provider-adapter-codex.sh"
# shellcheck source=/dev/null
. "$SRC_ROOT/core/scripts/lib/provider-adapter-grok.sh"

read_args() {
  local f="$1"
  ARGS=()
  while IFS= read -r line || [ -n "$line" ]; do
    ARGS+=("$line")
  done < "$f"
}

RUN="$TMP/run"
mkdir -p "$RUN" "$TMP/company"
printf 'SYSTEM_CANARY_TEXT\n' > "$RUN/system.txt"
printf 'USER_PROMPT_TEXT\n' > "$RUN/user.txt"
export HQ_AGENT_SESSION_RENDER_ONLY=1

# ── codex ───────────────────────────────────────────────────────────────────
SESSION_SYSTEM_PROMPT_MODE=""
provider_adapter_codex "$RUN" "$TMP/company" || fail "codex render failed"
read_args "$RUN/provider.argv.lines"
[ "${ARGS[0]}" = "codex" ] || fail "codex argv0=${ARGS[0]}"
printf '%s\n' "${ARGS[@]}" | grep -qx -- 'exec' || fail "missing exec"
printf '%s\n' "${ARGS[@]}" | grep -qx -- '--skip-git-repo-check' || fail "missing skip-git"
printf '%s\n' "${ARGS[@]}" | grep -qx -- '--dangerously-bypass-hook-trust' || fail "missing bypass-hook-trust"
# Mechanism is none → prepended; positional prompt contains system+user but
# matrix documents this. systemPromptMode must be prepended.
[ "$SESSION_SYSTEM_PROMPT_MODE" = "prepended" ] || fail "codex mode=$SESSION_SYSTEM_PROMPT_MODE"
# Multiline prompt is split across provider.argv.lines rows; assert both appear
# somewhere in the argv payload (and that -- separates flags from prompt).
grep -q 'SYSTEM_CANARY_TEXT' "$RUN/provider.argv.lines" || fail "codex prepend missing system"
grep -q 'USER_PROMPT_TEXT' "$RUN/provider.argv.lines" || fail "codex prepend missing user"
# Ensure system is not a separate leading argv token before `exec` (must be in prompt)
[ "${ARGS[0]}" = "codex" ] && [ "${ARGS[1]}" = "exec" ] || fail "codex head"
# Skeleton fixture
CODX_SKEL="$(printf '%s\n' "${ARGS[@]}" | awk '
  $0=="codex"{print}
  $0=="exec"{print}
  $0=="--skip-git-repo-check"{print}
  $0=="--dangerously-bypass-hook-trust"{print}
  $0=="--"{print}
')"
EXPECTED_CODX=$'codex\nexec\n--skip-git-repo-check\n--dangerously-bypass-hook-trust\n--'
[ "$CODX_SKEL" = "$EXPECTED_CODX" ] || fail "codex skeleton:
$CODX_SKEL"
FIXTURE_DIR="$SRC_ROOT/core/scripts/tests/fixtures"
mkdir -p "$FIXTURE_DIR"
printf '%s\n' "$EXPECTED_CODX" > "$FIXTURE_DIR/codex-argv-skeleton.txt"
printf '%s\n' "$CODX_SKEL" | cmp -s - "$FIXTURE_DIR/codex-argv-skeleton.txt" || fail "codex fixture"
pass "codex argv"

# ── grok ────────────────────────────────────────────────────────────────────
: > "$RUN/provider.argv.lines"
SESSION_SYSTEM_PROMPT_MODE=""
provider_adapter_grok "$RUN" "$TMP/company" || fail "grok render failed"
read_args "$RUN/provider.argv.lines"
[ "${ARGS[0]}" = "grok" ] || fail "grok argv0=${ARGS[0]}"
printf '%s\n' "${ARGS[@]}" | grep -qx -- '--yolo' || fail "missing --yolo"
printf '%s\n' "${ARGS[@]}" | grep -qx -- '-p' || fail "missing -p"
printf '%s\n' "${ARGS[@]}" | grep -qx -- '--system-prompt-override' || fail "missing system-prompt-override"
[ "$SESSION_SYSTEM_PROMPT_MODE" = "native" ] || fail "grok mode=$SESSION_SYSTEM_PROMPT_MODE"
# system text is arg after --system-prompt-override
idx=-1
i=0
for a in "${ARGS[@]}"; do
  if [ "$a" = "--system-prompt-override" ]; then idx=$i; break; fi
  i=$((i+1))
done
[ "$idx" -ge 0 ] || fail "no override index"
sys_arg="${ARGS[$((idx+1))]}"
echo "$sys_arg" | grep -q 'SYSTEM_CANARY_TEXT' || fail "grok system not in override"
# -p user text should not contain system
idx=-1
i=0
for a in "${ARGS[@]}"; do
  if [ "$a" = "-p" ]; then idx=$i; break; fi
  i=$((i+1))
done
user_arg="${ARGS[$((idx+1))]}"
echo "$user_arg" | grep -q 'USER_PROMPT_TEXT' || fail "grok -p user missing"
echo "$user_arg" | grep -q 'SYSTEM_CANARY_TEXT' && fail "grok system leaked into -p"
GROK_SKEL="$(printf '%s\n' "${ARGS[@]}" | awk '
  $0=="grok"{print}
  $0=="-p"{print}
  $0=="--yolo"{print}
  $0=="--no-auto-update"{print}
  $0=="--system-prompt-override"{print}
')"
EXPECTED_GROK=$'grok\n-p\n--yolo\n--no-auto-update\n--system-prompt-override'
[ "$GROK_SKEL" = "$EXPECTED_GROK" ] || fail "grok skeleton:
$GROK_SKEL"
printf '%s\n' "$EXPECTED_GROK" > "$FIXTURE_DIR/grok-argv-skeleton.txt"
printf '%s\n' "$GROK_SKEL" | cmp -s - "$FIXTURE_DIR/grok-argv-skeleton.txt" || fail "grok fixture"
pass "grok argv"

# Matrix doc present with required fields
MATRIX="$SRC_ROOT/core/knowledge/public/hq-core/agent-session-provider-matrix.md"
[ -f "$MATRIX" ] || fail "missing provider matrix"
grep -qi 'codex' "$MATRIX" || fail "matrix missing codex"
grep -qi 'grok' "$MATRIX" || fail "matrix missing grok"
grep -qi 'mechanism' "$MATRIX" || fail "matrix missing mechanism"
grep -qi '0.144.6\|codex-cli' "$MATRIX" || fail "matrix missing codex version"
grep -qi 'system-prompt-override\|none' "$MATRIX" || fail "matrix missing mechanisms"
pass "provider matrix doc"

echo "PASS: hq-agent-session-adapters-codex-grok.test.sh"
