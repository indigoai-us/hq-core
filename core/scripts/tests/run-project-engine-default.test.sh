#!/usr/bin/env bash
# Focused regression tests for run-project engine forwarding.
#
# Covers two entry points:
#   1. Wrapper:       core/scripts/run-project.sh   (translates --engine, then exec's main)
#   2. Direct invoke: .claude/scripts/run-project.sh (parses --builder/--engine itself)
#
# Both must default to --builder=codex. Claude builder requests are blocked.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label: expected to contain '$needle', got '$haystack'"
}

# ----------------------------------------------------------------------------
# Wrapper tests — copy real wrapper + lib, mock the main script with an echoer.
# Minimal PATH because the wrapper only needs bash+dirname.
# ----------------------------------------------------------------------------
mkdir -p "$TMP/core/scripts/lib" "$TMP/.claude/scripts"
cp "$ROOT/core/scripts/run-project.sh" "$TMP/core/scripts/run-project.sh"
cp "$ROOT/core/scripts/lib/detect-codex.sh" "$TMP/core/scripts/lib/detect-codex.sh"
chmod +x "$TMP/core/scripts/run-project.sh"

mkdir -p "$TMP/bin"
ln -s /bin/bash "$TMP/bin/bash"
ln -s /usr/bin/dirname "$TMP/bin/dirname"
WRAPPER_ENV=(/usr/bin/env -u CODEX_SESSION_ID -u CODEX_SANDBOX -u CODEX_EXECUTION_ID -u CODEX_AGENT_ID -u OPENAI_CODEX PATH="$TMP/bin")

cat > "$TMP/.claude/scripts/run-project.sh" <<'SH'
#!/usr/bin/env bash
printf '<%s>\n' "$@"
SH
chmod +x "$TMP/.claude/scripts/run-project.sh"

out=$(cd "$TMP" && "${WRAPPER_ENV[@]}" /bin/bash core/scripts/run-project.sh demo --dry-run)
assert_eq "$out" $'<demo>\n<--dry-run>\n<--builder>\n<codex>' "wrapper: defaults to codex builder"

out=$(cd "$TMP" && "${WRAPPER_ENV[@]}" CODEX_SESSION_ID=test /bin/bash core/scripts/run-project.sh demo --dry-run)
assert_eq "$out" $'<demo>\n<--dry-run>\n<--builder>\n<codex>' "wrapper: codex session defaults to codex builder"

if cd "$TMP" && "${WRAPPER_ENV[@]}" CODEX_SESSION_ID=test /bin/bash core/scripts/run-project.sh demo --engine claude --dry-run >/tmp/run-project-claude-engine.out 2>&1; then
  fail "wrapper: explicit claude engine should be blocked"
fi
assert_contains "$(cat /tmp/run-project-claude-engine.out)" "Claude builder is not supported" "wrapper: explicit claude engine error"

if cd "$TMP" && "${WRAPPER_ENV[@]}" CODEX_SESSION_ID=test /bin/bash core/scripts/run-project.sh demo --builder claude --dry-run >/tmp/run-project-claude-builder.out 2>&1; then
  fail "wrapper: explicit claude builder should be blocked"
fi
assert_contains "$(cat /tmp/run-project-claude-builder.out)" "Claude builder is not supported" "wrapper: explicit claude builder error"

out=$(cd "$TMP" && "${WRAPPER_ENV[@]}" CODEX_SESSION_ID=test /bin/bash core/scripts/run-project.sh demo --engine=codex --dry-run)
assert_eq "$out" $'<demo>\n<--builder>\n<codex>\n<--dry-run>' "wrapper: equals-form engine is normalized"

# ----------------------------------------------------------------------------
# Direct-script tests — exercise the real main script's own --help output.
# Use real PATH (script needs date, mkdir, etc.) but scrub Codex env vars so
# detection only fires when we explicitly set them.
# ----------------------------------------------------------------------------
MAIN_ENV=(/usr/bin/env -u CODEX_SESSION_ID -u CODEX_SANDBOX -u CODEX_EXECUTION_ID -u CODEX_AGENT_ID -u OPENAI_CODEX)

# Help text contains the new default-behavior documentation.
help_out=$("${MAIN_ENV[@]}" bash "$ROOT/.claude/scripts/run-project.sh" --help 2>&1 || true)
assert_contains "$help_out" 'Auto uses codex' "main: --help documents codex default"
assert_contains "$help_out" '--engine ENGINE' "main: --help documents --engine alias"

# Direct-script syntax check.
bash -n "$ROOT/.claude/scripts/run-project.sh" || fail "main: syntax check"

if "${MAIN_ENV[@]}" bash "$ROOT/.claude/scripts/run-project.sh" demo --builder claude --dry-run >/tmp/run-project-main-claude.out 2>&1; then
  fail "main: explicit claude builder should be blocked"
fi
assert_contains "$(cat /tmp/run-project-main-claude.out)" "Unknown builder: claude" "main: explicit claude builder error"

# Shared lib sourceable in isolation and correctly detects env var presence.
(
  unset CODEX_SESSION_ID CODEX_SANDBOX CODEX_EXECUTION_ID CODEX_AGENT_ID OPENAI_CODEX
  source "$ROOT/core/scripts/lib/detect-codex.sh"
  CODEX_SESSION_ID=stub running_from_codex || fail "lib: missed CODEX_SESSION_ID detection"
  CODEX_SANDBOX=stub running_from_codex || fail "lib: missed CODEX_SANDBOX detection"
  OPENAI_CODEX=1 running_from_codex || fail "lib: missed OPENAI_CODEX detection"
)

echo "run-project engine default tests passed (wrapper + main + lib)"
