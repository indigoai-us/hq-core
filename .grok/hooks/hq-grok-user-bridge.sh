#!/bin/bash
# hq-core: public
# hq-grok-user-bridge.sh — user-global Grok hook bridge for HQ trees.
#
# Installed by core/scripts/grok-trust.sh into ~/.grok/hooks/ so HQ guards
# enforce even when Grok fails to load project-scoped `.grok/hooks/*.json`
# (observed on Grok Build 0.2.93: project hooks never appear in `grok inspect`,
# while ~/.grok/hooks/ always does).
#
# Behavior:
#   1. Prefer GROK_WORKSPACE_ROOT / CLAUDE_PROJECT_DIR if they contain an HQ tree.
#   2. Else walk up from cwd looking for .grok/hooks/hq-grok-hook-adapter.sh
#      next to a .claude/hooks/hook-gate.sh (HQ root signature).
#   3. If found, exec the project adapter with the original stdin payload.
#   4. If not found, fail-open (allow for PreToolUse; no-op for other events).
set -uo pipefail

INPUT_RAW="$(cat 2>/dev/null || echo '{}')"

find_adapter() {
  local cand walk base
  for base in "${GROK_WORKSPACE_ROOT:-}" "${CLAUDE_PROJECT_DIR:-}"; do
    [ -n "$base" ] || continue
    cand="$base/.grok/hooks/hq-grok-hook-adapter.sh"
    if [ -x "$cand" ] && [ -x "$base/.claude/hooks/hook-gate.sh" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done

  walk="$(pwd -P 2>/dev/null || pwd)"
  while [ -n "$walk" ] && [ "$walk" != "/" ]; do
    cand="$walk/.grok/hooks/hq-grok-hook-adapter.sh"
    if [ -x "$cand" ] && [ -x "$walk/.claude/hooks/hook-gate.sh" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
    walk="$(dirname "$walk")"
  done
  return 1
}

ADAPTER="$(find_adapter || true)"
if [ -n "${ADAPTER:-}" ] && [ -x "$ADAPTER" ]; then
  # Propagate a STABLE session key to the adapter. Grok spawns a fresh
  # `bash hq-hq-bridge.sh` per hook call, so THIS bridge process is short-lived
  # and its own PID changes every call — but its PARENT ($PPID) is the
  # long-lived Grok CLI process, stable for the whole session. The adapter's
  # last-resort session id is `grok-${GROK_SESSION_ID:-$PPID}`; on the bridge
  # path the adapter's $PPID is THIS bridge (per-call, unstable), which would
  # give every call a different per-session debounce/dedupe key and defeat the
  # policy-scan debounce on exactly the global-bridge path that carries the
  # latency. Export the Grok parent PID as the fallback so consecutive bridge
  # calls in one session share a key. A real session id in the payload/env
  # still wins (adapter checks those first; we only set the fallback if unset).
  export GROK_SESSION_ID="${GROK_SESSION_ID:-bridge-$PPID}"
  # Do NOT use `exec` on the RHS of a pipeline — it does not replace this shell,
  # so fall-through would emit a second allow after a deny.
  set +e
  printf '%s' "$INPUT_RAW" | "$ADAPTER"
  st=$?
  set -e
  exit "$st"
fi

# Outside HQ: allow PreToolUse, ignore everything else.
EVENT="$(printf '%s' "$INPUT_RAW" | jq -r '.hookEventName // .hook_event_name // empty' 2>/dev/null || true)"
case "$EVENT" in
  PreToolUse|pre_tool_use|"")
    # Empty event + tool payload still treated as PreToolUse by the adapter;
    # outside HQ we only need a safe allow for blocking events.
    echo '{"decision":"allow"}'
    ;;
esac
exit 0
