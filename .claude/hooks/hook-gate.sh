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
#   standard - All minimal + checkpoint/handoff/session-start hooks (DEFAULT)
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

self_src="${BASH_SOURCE[0]:-$0}"
self_dir="$(cd "$(dirname "$self_src")" 2>/dev/null && pwd -P || true)"
HQ_ROOT_RESOLVED=""
if [ -n "$self_dir" ]; then
  cand="$(cd "$self_dir/../.." 2>/dev/null && pwd -P || true)"
  if [ -n "$cand" ] && [ -f "$cand/core/scripts/hook-lib.sh" ]; then
    HQ_ROOT_RESOLVED="$cand"
  fi
fi
[ -z "$HQ_ROOT_RESOLVED" ] && HQ_ROOT_RESOLVED="${CLAUDE_PROJECT_DIR:-${HQ_ROOT:-}}"
if [ -n "$HQ_ROOT_RESOLVED" ] && [ -f "$HQ_ROOT_RESOLVED/core/scripts/hook-lib.sh" ]; then
  # Shared HQ-owned launch helpers: bounded warnings, safe chmod repair, bash fallback.
  . "$HQ_ROOT_RESOLVED/core/scripts/hook-lib.sh"
fi

# Determine profile (default: standard)
PROFILE="${HQ_HOOK_PROFILE:-standard}"

# Parse disabled hooks (comma-separated)
DISABLED_HOOKS="${HQ_DISABLED_HOOKS:-}"

# Define hook membership per profile (using case statements for POSIX compatibility)
# Minimal: critical safety hooks
is_in_minimal_profile() {
  case "$1" in
    block-hq-glob|block-hq-grep|warn-cross-company-settings|detect-secrets|protect-core|block-core-writes|block-core-writes-bash|validate-policy-frontmatter|cleanup-mcp-processes|block-unsafe-package-install|block-hq-root-git-mutation|enforce-capability-link-render|enforce-humanize-before-send|surface-company-infra-policy)
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
    block-hq-glob|block-hq-grep|warn-cross-company-settings|detect-secrets|auto-checkpoint-trigger|auto-checkpoint-precompact|hq-autocommit|precompact-thrashing-detector|observe-patterns|block-inline-story-impl|screenshot-resize-trigger|protect-core|block-core-writes|block-core-writes-bash|validate-policy-frontmatter|cleanup-mcp-processes|check-bridge-health|check-repo-active-runs|block-on-active-run|context-warning-50|inject-local-context|auto-startwork|auto-session-project|native-plan-project-sync|rewrite-resume-sentinel|mirror-thread-to-company|inject-policy-on-trigger|route-deep-plan-to-skill|block-builtin-plan-mode-during-deep-plan|block-plans-dir-during-deep-plan|journal-autocapture|journal-due|journal-precompact|load-journal-index-on-start|block-unsafe-package-install|check-hq-update|block-hq-root-git-mutation|enforce-capability-link-render|enforce-humanize-before-send|session-title|surface-company-infra-policy|migrate-policy-triggers|hq-auto-acl-suggest)
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
    block-hq-glob|block-hq-grep|warn-cross-company-settings|detect-secrets|auto-checkpoint-trigger|auto-checkpoint-precompact|hq-autocommit|precompact-thrashing-detector|observe-patterns|block-inline-story-impl|screenshot-resize-trigger|protect-core|block-core-writes|block-core-writes-bash|validate-policy-frontmatter|cleanup-mcp-processes|check-bridge-health|check-repo-active-runs|block-on-active-run|context-warning-50|inject-local-context|auto-startwork|auto-session-project|native-plan-project-sync|rewrite-resume-sentinel|mirror-thread-to-company|inject-policy-on-trigger|route-deep-plan-to-skill|block-builtin-plan-mode-during-deep-plan|block-plans-dir-during-deep-plan|journal-autocapture|journal-due|journal-precompact|load-journal-index-on-start|block-unsafe-package-install|check-hq-update|block-hq-root-git-mutation|enforce-capability-link-render|enforce-humanize-before-send|session-title|surface-company-infra-policy|migrate-policy-triggers|hq-auto-acl-suggest)
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
HOOK_PAYLOAD="$(cat 2>/dev/null || true)"
if [ $should_run -eq 0 ]; then
  exit 0
fi

# Harden PATH so the delegated hook can find node/hq/qmd even when the user
# installed Node via a version manager (nvm/volta/fnm/asdf) or into ~/.local/bin
# rather than Homebrew. Claude Code runs hooks with the minimal PATH the GUI
# inherited; an old HQ install pins the stock Homebrew-only PATH
# (/opt/homebrew/bin:/usr/local/bin:...). If node/hq/qmd live outside that PATH,
# EVERY hook fails to find them, errors, and Claude appears dead in the HQ root
# (real incident: a non-Homebrew Node user, DEV task-198633788). We probe a set
# of well-known install dirs and prepend the ones that actually hold a tool.
#
# We DELIBERATELY never source shell rc/profile files (~/.bashrc, ~/.zshrc,
# ~/.profile) to discover PATH — that is a denied sensitive-path read and could
# execute arbitrary user startup code. Directory probing is sufficient and safe.
# Print the highest vMAJOR.MINOR.PATCH directory name without GNU sort -V.
# macOS ships BSD sort; awk numeric comparison works on all supported shells.
hq_highest_node_version() {
  local versions_dir="${1:-}"
  [ -d "$versions_dir" ] || return 0
  ls -1 "$versions_dir" 2>/dev/null | awk -F. '
    {
      major=$1; sub(/^[^0-9]*/, "", major); major+=0
      minor=$2+0; patch=$3; sub(/[^0-9].*$/, "", patch); patch+=0
      if (!seen || major>best_major ||
          (major==best_major && minor>best_minor) ||
          (major==best_major && minor==best_minor && patch>best_patch)) {
        seen=1; best_major=major; best_minor=minor; best_patch=patch; best=$0
      }
    }
    END { if (seen) print best }
  '
}

hq_augment_path() {
  # Fast path: if node, hq, and qmd already resolve, do nothing (Homebrew and
  # correctly-configured setups pay ~zero).
  if command -v node >/dev/null 2>&1 \
    && command -v hq >/dev/null 2>&1 \
    && command -v qmd >/dev/null 2>&1; then
    return 0
  fi

  local home="${HOME:-}"
  [ -n "$home" ] || return 0

  # Candidate tool dirs, HIGHEST priority first (the user's chosen version
  # manager should win over a stray system binary). Version managers that expose
  # a stable shim/bin dir are listed directly; nvm/fnm keep versioned dirs, so we
  # resolve the highest installed version. Homebrew + system come last.
  local candidates=()
  [ -n "${VOLTA_HOME:-}" ] && candidates+=("$VOLTA_HOME/bin")
  candidates+=("$home/.volta/bin")
  [ -n "${ASDF_DATA_DIR:-}" ] && candidates+=("$ASDF_DATA_DIR/shims")
  candidates+=("$home/.asdf/shims")

  # nvm: <NVM_DIR>/versions/node/<vX.Y.Z>/bin — pick the highest version present.
  local nvm_root="${NVM_DIR:-$home/.nvm}"
  if [ -d "$nvm_root/versions/node" ]; then
    local nvm_ver
    nvm_ver="$(hq_highest_node_version "$nvm_root/versions/node")"
    [ -n "$nvm_ver" ] && candidates+=("$nvm_root/versions/node/$nvm_ver/bin")
  fi

  # fnm: <FNM_DIR>/node-versions/<vX.Y.Z>/installation/bin — highest present.
  local fnm_root="${FNM_DIR:-$home/.fnm}"
  if [ -d "$fnm_root/node-versions" ]; then
    local fnm_ver
    fnm_ver="$(hq_highest_node_version "$fnm_root/node-versions")"
    [ -n "$fnm_ver" ] && candidates+=("$fnm_root/node-versions/$fnm_ver/installation/bin")
  fi

  candidates+=("$home/.local/bin")

  # Windows Git Bash / MSYS: official Node installer, npm global, scoop, chocolatey.
  # Inserted BEFORE Homebrew/system bins so real Windows Node wins over MSYS paths.
  # Guarded so Linux/macOS skip these probes. Paths may contain spaces — always
  # quote when testing -d/-x and when prepending to PATH.
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*)
      candidates+=("/c/Program Files/nodejs")
      if [ -n "${APPDATA:-}" ]; then
        # APPDATA is typically C:\Users\...\AppData\Roaming — convert if needed.
        _appdata_unix="${APPDATA//\\//}"
        case "$_appdata_unix" in
          [A-Za-z]:*) _appdata_unix="/${_appdata_unix:0:1}${_appdata_unix:2}" ;;
        esac
        candidates+=("$_appdata_unix/npm")
      fi
      if [ -n "${USERPROFILE:-}" ]; then
        _up="${USERPROFILE//\\//}"
        case "$_up" in
          [A-Za-z]:*) _up="/${_up:0:1}${_up:2}" ;;
        esac
        candidates+=("$_up/scoop/shims")
      fi
      candidates+=("/c/ProgramData/chocolatey/bin" "/c/ProgramData/scoop/shims")
      ;;
  esac

  candidates+=("/opt/homebrew/bin" "/usr/local/bin")

  # Accumulate a prefix of dirs that (a) aren't already on PATH and (b) actually
  # contain one of our tools, preserving priority order.
  local prefix="" dir
  for dir in "${candidates[@]}"; do
    [ -n "$dir" ] || continue
    case ":$PATH:" in
      *":$dir:"*) continue ;;
    esac
    [ -d "$dir" ] || continue
    if [ -x "$dir/node" ] || [ -x "$dir/hq" ] || [ -x "$dir/qmd" ] \
      || [ -x "$dir/node.exe" ] || [ -x "$dir/hq.exe" ] || [ -x "$dir/qmd.exe" ]; then
      prefix="${prefix:+$prefix:}$dir"
    fi
  done
  [ -n "$prefix" ] && export PATH="$prefix:$PATH"
  return 0
}
hq_augment_path

# Hook should run: delegate through the shared launch contract. It only mutates
# files under the resolved HQ root, preserves delegated exit codes, and emits
# one bounded warning per failed hook/path/session when chmod+bash fallback
# still cannot launch the hook.
if command -v hq_launch_shell_path >/dev/null 2>&1 \
  && command -v hq_hook_launch_warning_text >/dev/null 2>&1; then
  status=0
  hq_launch_shell_path "$HQ_ROOT_RESOLVED" "$HOOK_SCRIPT" "$HOOK_PAYLOAD" "$@" || status=$?
  if [ -n "${HQ_HOOK_LAST_CAUSE:-}" ]; then
    warning="$(hq_hook_launch_warning_text \
      "$HOOK_PAYLOAD" \
      "$HQ_ROOT_RESOLVED" \
      "runtime" \
      "hook" \
      "$HOOK_ID" \
      "$HOOK_SCRIPT" \
      "$HQ_HOOK_LAST_CAUSE")"
    [ -n "$warning" ] && printf '%s\n' "$warning" >&2
  fi
  exit "$status"
fi

chmod u+x "$HOOK_SCRIPT" 2>/dev/null || true
if [ -x "$HOOK_SCRIPT" ]; then
  printf '%s' "$HOOK_PAYLOAD" | "$HOOK_SCRIPT" "$@"
  exit $?
fi
printf '%s' "$HOOK_PAYLOAD" | bash "$HOOK_SCRIPT" "$@"
exit $?
