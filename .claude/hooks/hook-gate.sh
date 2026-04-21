#!/bin/bash
# Hook Profile Gate - Controls hook execution based on HQ_HOOK_PROFILE and HQ_DISABLED_HOOKS.
#
# Usage: hook-gate.sh <hook-id> <actual-hook-script>
#
# Environment:
#   HQ_HOOK_PROFILE - Profile name (minimal|standard|strict), default: standard
#   HQ_DISABLED_HOOKS - Comma-separated hook IDs to disable
#
# Profiles:
#   minimal - Critical safety hooks only (block-hq-glob, block-hq-grep, warn-cross-company-settings, detect-secrets, protect-core)
#   standard - All minimal + checkpoint/handoff hooks (DEFAULT)
#   strict - All standard + future quality/format hooks (not yet defined)
#
# Exit codes:
#   0 - Hook skipped (not in profile or disabled), pass-through to Claude Code
#   Other - Delegated hook's exit code (2 = blocked, etc.)

set -euo pipefail

# Validate arguments
if [ $# -lt 2 ]; then
  echo "USAGE: hook-gate.sh <hook-id> <actual-hook-script> [args...]" >&2
  exit 1
fi

HOOK_ID="$1"
HOOK_SCRIPT="$2"
shift 2
# Remaining args passed to actual hook script (if any)

# Determine profile (default: standard)
PROFILE="${HQ_HOOK_PROFILE:-standard}"

# Parse disabled hooks (comma-separated)
DISABLED_HOOKS="${HQ_DISABLED_HOOKS:-}"

# Define hook membership per profile (using case statements for POSIX compatibility)
# Minimal: critical safety hooks
is_in_minimal_profile() {
  case "$1" in
    block-hq-glob|block-hq-grep|warn-cross-company-settings|detect-secrets|protect-core|cleanup-mcp-processes)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Standard: minimal + checkpoint/handoff + pattern learning + core governance + policy loading
is_in_standard_profile() {
  case "$1" in
    block-hq-glob|block-hq-grep|warn-cross-company-settings|detect-secrets|auto-checkpoint-trigger|auto-checkpoint-precompact|observe-patterns|block-inline-story-impl|screenshot-resize-trigger|protect-core|cleanup-mcp-processes|load-policies|check-bridge-health|check-repo-active-runs|block-on-active-run|context-warning-60|inject-local-context|rewrite-resume-sentinel)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Strict: standard + future quality hooks (reserved for expansion)
is_in_strict_profile() {
  case "$1" in
    block-hq-glob|block-hq-grep|warn-cross-company-settings|detect-secrets|auto-checkpoint-trigger|auto-checkpoint-precompact|observe-patterns|block-inline-story-impl|screenshot-resize-trigger|protect-core|cleanup-mcp-processes|load-policies|check-bridge-health|check-repo-active-runs|block-on-active-run|context-warning-60|inject-local-context|rewrite-resume-sentinel)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Determine if hook should run based on profile
should_run=0
case "$PROFILE" in
  minimal)
    if is_in_minimal_profile "$HOOK_ID"; then
      should_run=1
    fi
    ;;
  standard)
    if is_in_standard_profile "$HOOK_ID"; then
      should_run=1
    fi
    ;;
  strict)
    if is_in_strict_profile "$HOOK_ID"; then
      should_run=1
    fi
    ;;
  *)
    echo "ERROR: Unknown profile '$PROFILE'. Use minimal|standard|strict" >&2
    exit 1
    ;;
esac

# Check if hook is explicitly disabled
if [ -n "$DISABLED_HOOKS" ]; then
  # Parse comma-separated list
  IFS=',' read -ra DISABLED_ARRAY <<<"$DISABLED_HOOKS"
  for disabled_id in "${DISABLED_ARRAY[@]}"; do
    # Trim whitespace
    disabled_id="$(echo "$disabled_id" | xargs)"
    if [ "$disabled_id" = "$HOOK_ID" ]; then
      should_run=0
      break
    fi
  done
fi

# If hook should not run, pass-through (exit 0)
if [ $should_run -eq 0 ]; then
  # Read stdin and discard (hooks expect to consume stdin)
  cat >/dev/null
  exit 0
fi

# Hook should run: pipe stdin to the actual hook script and delegate exit code
"$HOOK_SCRIPT" "$@"
