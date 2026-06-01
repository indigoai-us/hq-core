#!/usr/bin/env bash
# Regression tests for run-project after the engine-selection retirement.
#
# Covers two entry points:
#   1. Wrapper:       core/scripts/run-project.sh   (thin forwarder)
#   2. Direct invoke: .claude/scripts/run-project.sh (the orchestrator)
#
# New contract (2026-05 inline-ralph re-engine):
#   - There is NO engine selection. `--ralph-mode` runs the inline worker loop
#     in-session (see .claude/skills/run-project/SKILL.md).
#   - The wrapper forwards the live surface (--status/--dry-run/--help/<project>)
#     verbatim to the orchestrator — it injects no default builder.
#   - Explicit --engine/--builder are REJECTED at both entry points with a
#     pointer to in-session ralph (no cryptic "Unknown builder").

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
# Wrapper tests — copy the real wrapper, mock the orchestrator with an echoer.
# Minimal PATH because the wrapper only needs bash + dirname.
# ----------------------------------------------------------------------------
mkdir -p "$TMP/core/scripts" "$TMP/.claude/scripts"
cp "$ROOT/core/scripts/run-project.sh" "$TMP/core/scripts/run-project.sh"
chmod +x "$TMP/core/scripts/run-project.sh"

mkdir -p "$TMP/bin"
ln -s /bin/bash "$TMP/bin/bash"
ln -s /usr/bin/dirname "$TMP/bin/dirname"
WRAPPER_ENV=(/usr/bin/env PATH="$TMP/bin")

cat > "$TMP/.claude/scripts/run-project.sh" <<'SH'
#!/usr/bin/env bash
printf '<%s>\n' "$@"
SH
chmod +x "$TMP/.claude/scripts/run-project.sh"

# Live surface forwards verbatim — NO default builder injected.
out=$(cd "$TMP" && "${WRAPPER_ENV[@]}" /bin/bash core/scripts/run-project.sh demo --dry-run)
assert_eq "$out" $'<demo>\n<--dry-run>' "wrapper: forwards live surface verbatim"

out=$(cd "$TMP" && "${WRAPPER_ENV[@]}" /bin/bash core/scripts/run-project.sh --status)
assert_eq "$out" $'<--status>' "wrapper: forwards --status verbatim"

# Explicit --engine is rejected before exec'ing the orchestrator.
if cd "$TMP" && "${WRAPPER_ENV[@]}" /bin/bash core/scripts/run-project.sh demo --engine claude --dry-run >/tmp/run-project-wrap-engine.out 2>&1; then
  fail "wrapper: explicit --engine should be rejected"
fi
assert_contains "$(cat /tmp/run-project-wrap-engine.out)" "no longer selects a build engine" "wrapper: --engine rejection message"
assert_contains "$(cat /tmp/run-project-wrap-engine.out)" "--ralph-mode" "wrapper: --engine rejection points to in-session ralph"

# Equals-form --engine is rejected too.
if cd "$TMP" && "${WRAPPER_ENV[@]}" /bin/bash core/scripts/run-project.sh demo --engine=claude >/tmp/run-project-wrap-engine-eq.out 2>&1; then
  fail "wrapper: --engine=claude should be rejected"
fi
assert_contains "$(cat /tmp/run-project-wrap-engine-eq.out)" "no longer selects a build engine" "wrapper: --engine=claude rejection"

# Explicit --builder (any value, even codex) is rejected.
if cd "$TMP" && "${WRAPPER_ENV[@]}" /bin/bash core/scripts/run-project.sh demo --builder codex >/tmp/run-project-wrap-builder.out 2>&1; then
  fail "wrapper: explicit --builder should be rejected"
fi
assert_contains "$(cat /tmp/run-project-wrap-builder.out)" "no longer selects a build engine" "wrapper: --builder rejection"

# ----------------------------------------------------------------------------
# Direct-script tests — exercise the real orchestrator.
# Scrub Codex env vars so detection only fires when explicitly set.
# ----------------------------------------------------------------------------
MAIN_ENV=(/usr/bin/env -u CODEX_SESSION_ID -u CODEX_SANDBOX -u CODEX_EXECUTION_ID -u CODEX_AGENT_ID -u OPENAI_CODEX)

# Help documents the live surface and the engine retirement; no --builder flag.
help_out=$("${MAIN_ENV[@]}" bash "$ROOT/.claude/scripts/run-project.sh" --help 2>&1 || true)
assert_contains "$help_out" '--dry-run' "main: --help documents live surface"
assert_contains "$help_out" 'engine selection (--engine/--builder) is retired' "main: --help documents retirement"

# Syntax check.
bash -n "$ROOT/.claude/scripts/run-project.sh" || fail "main: syntax check"

# Explicit --builder is rejected with the retirement pointer, not "Unknown builder".
if "${MAIN_ENV[@]}" bash "$ROOT/.claude/scripts/run-project.sh" demo --builder claude --dry-run >/tmp/run-project-main-builder.out 2>&1; then
  fail "main: explicit --builder should be rejected"
fi
assert_contains "$(cat /tmp/run-project-main-builder.out)" "no longer selects a build engine" "main: --builder rejection message"

# Explicit --engine (alias) is rejected too — even with a 'codex' value.
if "${MAIN_ENV[@]}" bash "$ROOT/.claude/scripts/run-project.sh" demo --engine codex --dry-run >/tmp/run-project-main-engine.out 2>&1; then
  fail "main: explicit --engine should be rejected"
fi
assert_contains "$(cat /tmp/run-project-main-engine.out)" "no longer selects a build engine" "main: --engine rejection message"

# Shared lib sourceable in isolation and correctly detects env var presence.
(
  unset CODEX_SESSION_ID CODEX_SANDBOX CODEX_EXECUTION_ID CODEX_AGENT_ID OPENAI_CODEX
  source "$ROOT/core/scripts/lib/detect-codex.sh"
  CODEX_SESSION_ID=stub running_from_codex || fail "lib: missed CODEX_SESSION_ID detection"
  CODEX_SANDBOX=stub running_from_codex || fail "lib: missed CODEX_SANDBOX detection"
  OPENAI_CODEX=1 running_from_codex || fail "lib: missed OPENAI_CODEX detection"
)

echo "run-project engine-retirement tests passed (wrapper + main + lib)"
