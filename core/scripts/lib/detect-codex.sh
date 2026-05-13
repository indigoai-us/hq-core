# shellcheck shell=bash
# detect-codex.sh — shared runtime detection for Codex sessions.
#
# Source this file (do not execute) to expose:
#   running_from_codex   — returns 0 if invoked from inside a Codex session, 1 otherwise.
#
# Detection order:
#   1. Codex/OpenAI runtime env vars (fast path, set by the Codex agent runtime
#      and Codex Desktop).
#   2. Walk ancestor processes via `ps`, matching `Codex*`, `codex`, or `codex-*`
#      in either the executable name or full args. Bounded to 15 hops to avoid
#      runaway in deep process trees (tmux -> shell -> shell -> ...).
#
# Fails closed (returns 1) when `ps`/`tr` are unavailable.

running_from_codex() {
  if [[ -n "${CODEX_SANDBOX:-}" \
     || -n "${CODEX_SESSION_ID:-}" \
     || -n "${CODEX_EXECUTION_ID:-}" \
     || -n "${CODEX_AGENT_ID:-}" \
     || -n "${CODEX_THREAD_ID:-}" \
     || -n "${CODEX_SHELL:-}" \
     || -n "${CODEX_CI:-}" \
     || -n "${CODEX_INTERNAL_ORIGINATOR_OVERRIDE:-}" \
     || -n "${OPENAI_CODEX:-}" ]]; then
    return 0
  fi

  if [[ "${__CFBundleIdentifier:-}" == "com.openai.codex" ]]; then
    return 0
  fi

  command -v ps >/dev/null 2>&1 || return 1
  command -v tr >/dev/null 2>&1 || return 1

  local pid="${PPID:-}"
  local max=15
  while [[ -n "$pid" && "$pid" != "1" && $max -gt 0 ]]; do
    local comm args first exe
    comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
    exe="${comm##*/}"
    case "$exe" in
      Codex*|codex|codex-*) return 0 ;;
    esac

    args=$(ps -p "$pid" -o args= 2>/dev/null || true)
    first="${args%% *}"
    exe="${first##*/}"
    case "$exe" in
      Codex*|codex|codex-*) return 0 ;;
    esac

    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
    max=$((max - 1))
  done

  return 1
}
