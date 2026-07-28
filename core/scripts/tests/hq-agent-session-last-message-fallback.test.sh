#!/usr/bin/env bash
# hq-agent-session last-message fallback (codex empty-stdout, AE incident 2026-07-28).
#
# codex-cli 0.145.0 can stream the final agent message to stderr and leave
# stdout EMPTY under `codex exec`; the engine then read "no reply" and the
# watcher posted a task-failed message over a completed run. The adapter now
# passes --output-last-message and the engine falls back to that file whenever
# provider.stdout is empty. These tests pin: (1) the fallback helper prefers
# stdout, falls back to last-message.txt, and stays empty when neither exists;
# (2) the codex adapter argv carries --output-last-message on BOTH the fresh
# and the resume invocation.
set -u

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
SESSION_SH="$SCRIPT_DIR/../hq-agent-session.sh"
ADAPTER_SH="$SCRIPT_DIR/../lib/provider-adapter-codex.sh"

FAILED=0
pass() { printf '  ok  — %s\n' "$1"; }
fail() { printf '  FAIL — %s\n' "$1"; FAILED=1; }

# ── session_read_provider_out ───────────────────────────────────────────────
(
  # Extract just the helper so sourcing does not execute the entrypoint.
  eval "$(sed -n '/^session_read_provider_out() {/,/^}/p' "$SESSION_SH")"
  command -v session_read_provider_out >/dev/null 2>&1 \
    || { echo "  FAIL — helper session_read_provider_out not found in hq-agent-session.sh"; exit 1; }

  RD="$(mktemp -d)"
  trap 'rm -rf "$RD"' EXIT

  printf 'stdout answer' > "$RD/provider.stdout"
  printf 'last message'  > "$RD/last-message.txt"
  [ "$(session_read_provider_out "$RD")" = "stdout answer" ] \
    && pass "non-empty stdout wins over last-message.txt" \
    || fail "non-empty stdout must win"

  : > "$RD/provider.stdout"
  [ "$(session_read_provider_out "$RD")" = "last message" ] \
    && pass "empty stdout falls back to last-message.txt" \
    || fail "empty stdout must fall back to last-message.txt (THE regression)"

  rm -f "$RD/last-message.txt"
  [ -z "$(session_read_provider_out "$RD")" ] \
    && pass "empty stdout with no last-message stays empty (fault path preserved)" \
    || fail "no fabrication when neither file has content"

  # Second AE shape: answer only in stderr as the LAST codex block, run ends
  # on hook/auto-checkpoint noise with no final message.
  printf 'hook: PreToolUse\ncodex\nintermediate thought\nhook: PostToolUse\ncodex\nFALLBACK-SMOKE-OK\nline two\nhook: Stop\ndiff --git a/x b/x\n' > "$RD/provider.stderr"
  got="$(session_read_provider_out "$RD" codex)"
  [ "$got" = "FALLBACK-SMOKE-OK
line two" ] \
    && pass "codex: empty stdout+last-message falls back to LAST stderr codex block" \
    || fail "stderr codex-block fallback wrong (got: $got)"

  [ -z "$(session_read_provider_out "$RD" grok)" ] \
    && pass "stderr fallback is codex-only (grok stays empty)" \
    || fail "stderr fallback must not apply to non-codex providers"
  exit "$FAILED"
) || FAILED=1

# ── codex adapter argv ──────────────────────────────────────────────────────
(
  # shellcheck disable=SC1090
  . "$ADAPTER_SH"
  RD="$(mktemp -d)"
  trap 'rm -rf "$RD"' EXIT
  printf 'sys' > "$RD/system.txt"
  printf 'usr' > "$RD/user.txt"

  HQ_AGENT_SESSION_RENDER_ONLY=1 HQ_AGENT_SESSION_RESUME_ID="" \
    provider_adapter_codex "$RD" "$RD" >/dev/null 2>&1 || true
  grep -qx -- '--output-last-message' "$RD/provider.argv.lines" \
    && grep -qx -- "$RD/last-message.txt" "$RD/provider.argv.lines" \
    && pass "fresh exec argv carries --output-last-message <run_dir>/last-message.txt" \
    || fail "fresh exec argv missing --output-last-message"

  HQ_AGENT_SESSION_RENDER_ONLY=1 HQ_AGENT_SESSION_RESUME_ID="0123456789abcdef" \
    provider_adapter_codex "$RD" "$RD" >/dev/null 2>&1 || true
  grep -qx -- '--output-last-message' "$RD/provider.argv.lines" \
    && grep -qx -- 'resume' "$RD/provider.argv.lines" \
    && pass "resume argv carries --output-last-message too" \
    || fail "resume argv missing --output-last-message"
  exit "$FAILED"
) || FAILED=1

exit "$FAILED"
