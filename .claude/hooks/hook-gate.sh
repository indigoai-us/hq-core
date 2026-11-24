#!/bin/bash
# Hosts like Claude Code export BASH_ENV to a user profile; each non-interactive
# bash on the hook path then pays nvm (~1-11s). Measured 2026-09-21 macOS:
# adapter 18-32s, bridge 28s, master-hook 4.5s; with BASH_ENV=/dev/null: 4.0s / 3.5s.
export BASH_ENV=/dev/null
# Hook Profile Gate - Controls hook execution based on HQ_HOOK_PROFILE and HQ_DISABLED_HOOKS.
#
# Usage: hook-gate.sh <hook-id> <actual-hook-script>
#
# Environment:
#   HQ_HOOK_PROFILE - Profile name (minimal|standard|strict), default: standard
#                     (an unknown name warns and runs as strict)
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
#
# Library mode: `. hook-gate.sh --lib` defines the three profile lists,
# hq_hook_profile_allows, and hq_augment_path, then returns without running
# the gate. master-hook.sh uses this to gate many registry hooks in one
# process (the per-registration gate+watchdog+body startup is ~1 s on
# Windows Git Bash). Definitions stay in this file so a copied hook-gate.sh
# is always self-contained.

# ---------------------------------------------------------------------------
# Definitions (shared with master-hook.sh via `. hook-gate.sh --lib`)
# ---------------------------------------------------------------------------

# Define hook membership per profile (using case statements for POSIX compatibility)
# Minimal: critical safety hooks
is_in_minimal_profile() {
  case "$1" in
    refresh-vault-access|block-hq-glob|block-hq-grep|warn-cross-company-settings|mandatory-scope-authorizer|detect-secrets|block-agent-secrets-reveal|lanes-repo-merge-hold|super-conductor-merge-gate|block-env-dump|protect-core|block-core-writes|block-core-writes-bash|block-policy-writes-bash|enforce-vault-write-access|route-company-skill-creation|validate-policy-frontmatter|cleanup-mcp-processes|lanes-senior-monitor-stop-gate|block-on-active-run|block-unsafe-package-install|block-hq-root-git-mutation|block-company-repo-creation|block-company-git-metadata|block-foreground-timeout-over-harness-ceiling|hq-monitor-guard|hq-monitor-session-hook|hq-monitor-session-start|block-qmd-model-download|block-raw-temp-home|block-hq-unbounded-search|block-hq-worktree-session|spawn-company-handoff|enforce-capability-link-render|enforce-humanize-before-send|policy-enforcement-gate|inject-policy-on-trigger|session-title|surface-company-infra-policy|conduct-lanes-link-deliver|conduct-link-inherit|image-context-guard|env-file-no-trailing-newline|block-credential-file-read|redact-credential-output)
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
    refresh-vault-access|block-hq-glob|block-hq-grep|warn-cross-company-settings|mandatory-scope-authorizer|detect-secrets|block-agent-secrets-reveal|lanes-repo-merge-hold|super-conductor-merge-gate|block-env-dump|auto-checkpoint-trigger|auto-checkpoint-precompact|hq-autocommit|hq-autocommit-bash-sweep|capture-estimates|precompact-thrashing-detector|observe-patterns|block-inline-story-impl|screenshot-resize-trigger|protect-core|block-core-writes|block-core-writes-bash|block-policy-writes-bash|enforce-vault-write-access|route-company-skill-creation|validate-policy-frontmatter|cleanup-mcp-processes|desktop-memory-leak-check|check-repo-active-runs|block-on-active-run|checkpoint-stop-gate|enforce-final-message-link-placement|lanes-senior-monitor-stop-gate|inject-codex-checkpoint-reprompt|inject-local-context|auto-startwork|welcome-brief-ready|conduct-lanes-session-start|auto-session-project|native-plan-project-sync|rewrite-resume-sentinel|mirror-thread-to-company|inject-policy-on-trigger|natural-language-router|intent-hint|route-deep-plan-to-skill|block-builtin-plan-mode-during-deep-plan|block-plans-dir-during-deep-plan|journal-autocapture|journal-due|journal-precompact|purge-policy-ledger-precompact|record-policy-retrieval|load-journal-index-on-start|block-unsafe-package-install|check-hq-update|check-stale-model-pin|check-client-health|repair-stale-review-base|block-hq-root-git-mutation|block-company-repo-creation|block-company-git-metadata|block-foreground-timeout-over-harness-ceiling|block-qmd-model-download|block-raw-temp-home|block-hq-unbounded-search|block-hq-worktree-session|spawn-company-handoff|enforce-capability-link-render|enforce-humanize-before-send|policy-enforcement-gate|session-title|surface-company-infra-policy|migrate-policy-triggers|hq-auto-acl-suggest|work-mesh-live|conduct-lanes-link-deliver|conduct-link-inherit|hq-monitor-guard|hq-monitor-session-hook|hq-monitor-session-start|merged-write-guard-shadow|merged-write-guard-shadow-refresh|usable-integrations|pr-fingerprint-footer|image-context-guard|env-file-no-trailing-newline|check-core-yaml-parity|block-credential-file-read|redact-credential-output)
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
    refresh-vault-access|block-hq-glob|block-hq-grep|warn-cross-company-settings|mandatory-scope-authorizer|detect-secrets|block-agent-secrets-reveal|lanes-repo-merge-hold|super-conductor-merge-gate|block-env-dump|auto-checkpoint-trigger|auto-checkpoint-precompact|hq-autocommit|hq-autocommit-bash-sweep|capture-estimates|precompact-thrashing-detector|observe-patterns|block-inline-story-impl|screenshot-resize-trigger|protect-core|block-core-writes|block-core-writes-bash|block-policy-writes-bash|enforce-vault-write-access|route-company-skill-creation|validate-policy-frontmatter|cleanup-mcp-processes|desktop-memory-leak-check|check-repo-active-runs|block-on-active-run|checkpoint-stop-gate|enforce-final-message-link-placement|lanes-senior-monitor-stop-gate|inject-codex-checkpoint-reprompt|inject-local-context|auto-startwork|welcome-brief-ready|conduct-lanes-session-start|auto-session-project|native-plan-project-sync|rewrite-resume-sentinel|mirror-thread-to-company|inject-policy-on-trigger|natural-language-router|intent-hint|route-deep-plan-to-skill|block-builtin-plan-mode-during-deep-plan|block-plans-dir-during-deep-plan|journal-autocapture|journal-due|journal-precompact|purge-policy-ledger-precompact|record-policy-retrieval|load-journal-index-on-start|block-unsafe-package-install|check-hq-update|check-stale-model-pin|check-client-health|repair-stale-review-base|block-hq-root-git-mutation|block-company-repo-creation|block-company-git-metadata|block-foreground-timeout-over-harness-ceiling|block-qmd-model-download|block-raw-temp-home|block-hq-unbounded-search|block-hq-worktree-session|spawn-company-handoff|enforce-capability-link-render|enforce-humanize-before-send|policy-enforcement-gate|session-title|surface-company-infra-policy|migrate-policy-triggers|hq-auto-acl-suggest|work-mesh-live|conduct-lanes-link-deliver|conduct-link-inherit|hq-monitor-guard|hq-monitor-session-hook|hq-monitor-session-start|merged-write-guard-shadow|merged-write-guard-shadow-refresh|usable-integrations|pr-fingerprint-footer|image-context-guard|env-file-no-trailing-newline|check-core-yaml-parity|block-credential-file-read|redact-credential-output)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}


# hq_hook_profile_warn_unknown <profile>
#   Print one stderr line per process tree for an unknown profile name. The
#   exported flag keeps child hook-gate.sh runs from repeating it.
hq_hook_profile_warn_unknown() {
  [ -z "${HQ_HOOK_PROFILE_WARNED:-}" ] || return 0
  printf "WARNING: unknown HQ_HOOK_PROFILE '%s'; running hooks as strict. Use minimal|standard|strict.\n" "$1" >&2
  HQ_HOOK_PROFILE_WARNED=1
  export HQ_HOOK_PROFILE_WARNED
}

# hq_hook_profile_allows <hook-id> [profile]
#   Return 0 when the hook id is enabled under the profile (default
#   HQ_HOOK_PROFILE, else standard) and not listed in HQ_DISABLED_HOOKS.
#   An unknown or misspelled profile fails closed: it is treated as strict,
#   the superset tier, so a typo can never switch a gated guard off.
hq_hook_profile_allows() {
  local id="$1" profile="${2:-${HQ_HOOK_PROFILE:-standard}}"
  case "$profile" in
    minimal|standard|strict) ;;
    *) hq_hook_profile_warn_unknown "$profile"; profile=strict ;;
  esac
  case "$profile" in
    minimal) is_in_minimal_profile "$id" || return 1 ;;
    standard) is_in_standard_profile "$id" || return 1 ;;
    *) is_in_strict_profile "$id" || return 1 ;;
  esac
  local entry remaining="${HQ_DISABLED_HOOKS:-}"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      *,*) entry="${remaining%%,*}"; remaining="${remaining#*,}" ;;
      *) entry="$remaining"; remaining="" ;;
    esac
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ "$entry" = "$id" ] && return 1
  done
  if [ "$id" = "$HQ_HOOK_LEGACY_ALIAS_TARGET" ] && hq_hook_legacy_alias_disabled; then
    return 1
  fi
  return 0
}

# Retired hook id alias. indigoai-us/hq-core-staging#1495 renamed one hook id
# to desktop-memory-leak-check. The retired id must not appear in the repo, so
# a HQ_DISABLED_HOOKS entry is matched against it by the sha256 of the
# trimmed, lowercased entry. Only entries of the retired length made of
# [a-z0-9-] are hashed, so ordinary lists never start a hash process.
HQ_HOOK_LEGACY_ALIAS_TARGET=desktop-memory-leak-check
HQ_HOOK_LEGACY_ALIAS_SHA256=bbd31c49a5cded814da89ad3ee84a89a3995e2cb33b06610a06c4a362afe1710
HQ_HOOK_LEGACY_ALIAS_LEN=19
_hq_hook_alias_cache_key=""
_hq_hook_alias_cache_hit=""
_hq_hook_alias_noted=""

# Print the sha256 hex of stdin. Return 1 when no hash tool exists.
hq_hook_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null
  else
    cat >/dev/null
    return 1
  fi
}

# hq_hook_legacy_alias_disabled
#   Return 0 when HQ_DISABLED_HOOKS names the retired id of
#   desktop-memory-leak-check. The result is cached per process for the
#   current HQ_DISABLED_HOOKS value. Fail safe: when no hash tool exists the
#   match cannot be proven, so this returns 1 and the hook runs.
hq_hook_legacy_alias_disabled() {
  local list="${HQ_DISABLED_HOOKS:-}"
  [ -n "$list" ] || return 1
  if [ -n "$_hq_hook_alias_cache_hit" ] && [ "$_hq_hook_alias_cache_key" = "$list" ]; then
    [ "$_hq_hook_alias_cache_hit" = 1 ]
    return
  fi
  local entry digest hit=0 remaining="$list"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      *,*) entry="${remaining%%,*}"; remaining="${remaining#*,}" ;;
      *) entry="$remaining"; remaining="" ;;
    esac
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ "${#entry}" -eq "$HQ_HOOK_LEGACY_ALIAS_LEN" ] || continue
    case "$entry" in *[!A-Za-z0-9-]*) continue ;; esac
    digest="$(printf '%s' "$entry" | LC_ALL=C tr '[:upper:]' '[:lower:]' | hq_hook_sha256_stdin)" || digest=""
    digest="${digest%% *}"
    if [ "$digest" = "$HQ_HOOK_LEGACY_ALIAS_SHA256" ]; then
      hit=1
      break
    fi
  done
  _hq_hook_alias_cache_key="$list"
  _hq_hook_alias_cache_hit="$hit"
  if [ "$hit" = 1 ] && [ -z "$_hq_hook_alias_noted" ]; then
    _hq_hook_alias_noted=1
    echo "hq: HQ_DISABLED_HOOKS uses a retired hook id; rename it to $HQ_HOOK_LEGACY_ALIAS_TARGET" >&2
  fi
  [ "$hit" = 1 ]
}

# PATH augmentation so hooks can find node/hq/qmd under version managers and
# on Windows Git Bash. Never sources rc/profile files (sensitive-path policy);
# probes well-known directories only.
# Print the highest vMAJOR.MINOR.PATCH directory name without GNU sort -V.
# macOS ships BSD sort; awk numeric comparison works on all supported shells.
hq_highest_node_version() {
  local versions_dir="${1:-}"
  [ -d "$versions_dir" ] || return 0
  # shellcheck disable=SC2012 # We intentionally need only immediate entries.
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
  # Fast path: if node, hq, qmd and jq already resolve, do nothing (Homebrew
  # and correctly-configured setups pay ~zero). jq is part of the check because
  # master-hook.sh fails closed on PreToolUse when jq is missing after this
  # recovery: a jq installed outside the inherited PATH (winget, scoop,
  # ~/.local/bin) must still be found, or every tool call is blocked.
  # Directories found only because they hold jq are appended to the END of
  # PATH, so the inherited node/hq/qmd keep their priority and nothing the
  # user chose is shadowed.
  local jq_only=0 need_jq=0
  command -v jq >/dev/null 2>&1 || need_jq=1
  if command -v node >/dev/null 2>&1 \
    && command -v hq >/dev/null 2>&1 \
    && command -v qmd >/dev/null 2>&1; then
    [ "$need_jq" = 1 ] || return 0
    jq_only=1
  fi

  local home="${HOME:-}"
  [ -n "$home" ] || return 0

  # Candidate tool dirs, HIGHEST priority first (the user's chosen version
  # manager should win over a stray system binary). Version managers that expose
  # a stable shim/bin dir are listed directly; nvm/fnm keep versioned dirs, so we
  # resolve the highest installed version. Homebrew + system come last.
  local candidates=()
  # The HQ installer's managed toolchain (node, hq, qmd) comes first, in the
  # same order compose-settings-path.sh uses, so the installer-managed hq wins
  # over a stale copy in ~/.local/bin or a version manager. The path contains
  # spaces; candidates are always quoted below.
  local toolchain="${HQ_TOOLCHAIN_DIR:-$home/Library/Application Support/Indigo HQ/toolchain}"
  candidates+=("$toolchain/node/bin" "$toolchain/npm-global/bin")
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

  # npm's user-prefix global bin (npm config set prefix ~/.npm-global), the
  # layout `hq doctor` self-updates into. Probed before ~/.local/bin so a
  # wrapper there that points at a stale pnpm copy does not shadow a current
  # npm-global hq (feedback e49ce279). Same list as the lanes monitor probe.
  candidates+=("$home/.npm-global/bin")
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
      # winget, which the master-hook missing-jq message recommends. Portable
      # packages such as jqlang.jq are linked into WinGet\Links; when winget
      # cannot create that link it puts the package folder itself on the user
      # PATH. Either change reaches only shells started after the install, so
      # a Claude Code session that was already open never sees jq.
      if [ -n "${LOCALAPPDATA:-}" ]; then
        local _lad _lad_drive _wg_pkg
        _lad="${LOCALAPPDATA//\\//}"
        case "$_lad" in
          [A-Za-z]:*)
            # Git Bash spells drives in lowercase (/c/...). Matching that keeps
            # the "already on PATH" check below from adding a second copy.
            _lad_drive="${_lad:0:1}"
            [ "${BASH_VERSINFO[0]:-3}" -ge 4 ] && _lad_drive="${_lad_drive,,}"
            _lad="/${_lad_drive}${_lad:2}"
            ;;
        esac
        candidates+=("$_lad/Microsoft/WinGet/Links")
        # Checked first so a shell with failglob set does not abort on a
        # machine that has no winget packages folder.
        if [ -d "$_lad/Microsoft/WinGet/Packages" ]; then
          for _wg_pkg in "$_lad"/Microsoft/WinGet/Packages/jqlang.jq_*; do
            [ -d "$_wg_pkg" ] && candidates+=("$_wg_pkg")
          done
        fi
      fi
      candidates+=("/c/ProgramData/chocolatey/bin" "/c/ProgramData/scoop/shims")
      ;;
  esac

  candidates+=("/opt/homebrew/bin" "/usr/local/bin")

  # Accumulate a prefix of dirs that (a) aren't already on PATH and (b) actually
  # contain one of our tools, preserving priority order.
  local prefix="" suffix="" dir
  for dir in "${candidates[@]}"; do
    [ -n "$dir" ] || continue
    case ":$PATH:" in
      *":$dir:"*) continue ;;
    esac
    [ -d "$dir" ] || continue
    # node/hq/qmd folders go in front so the user's version manager wins. A
    # folder admitted only for jq goes at the END, and only while jq is
    # missing, so a jq-only folder such as /usr/local/bin never shadows
    # binaries the user already has on PATH.
    if [ "$jq_only" != 1 ] \
      && { [ -x "$dir/node" ] || [ -x "$dir/hq" ] || [ -x "$dir/qmd" ] \
        || [ -x "$dir/node.exe" ] || [ -x "$dir/hq.exe" ] || [ -x "$dir/qmd.exe" ]; }; then
      prefix="${prefix:+$prefix:}$dir"
    elif [ "$need_jq" = 1 ] && { [ -x "$dir/jq" ] || [ -x "$dir/jq.exe" ]; }; then
      suffix="${suffix:+$suffix:}$dir"
    fi
  done
  [ -n "$prefix" ] && export PATH="$prefix:$PATH"
  [ -n "$suffix" ] && export PATH="$PATH:$suffix"
  return 0
}

# Library mode ends here. The only side effect above is BASH_ENV=/dev/null.
if [ "${1:-}" = "--lib" ]; then
  return 0 2>/dev/null || exit 0
fi

set -euo pipefail

# Validate arguments
if [ $# -lt 2 ]; then
  echo "USAGE: hook-gate.sh <hook-id> <actual-hook-script> [args...]" >&2
  # Drain first so a misregistered gate reports THIS usage error (1) rather than
  # SIGPIPE-killing its payload writer and surfacing as 141 under pipefail.
  cat >/dev/null 2>&1 || true
  exit 1
fi

HOOK_ID="$1"
HOOK_SCRIPT="$2"
shift 2
# Remaining args passed to actual hook script (if any)

hook_gate_report_block_reason() {
  local hook_name="${HOOK_ID##*/}"
  hook_name="${hook_name%.sh}"
  case "$hook_name" in
    ''|*[!A-Za-z0-9._-]*) hook_name="registered hook" ;;
  esac
  printf '\nBlocked by hook %s.\n' "$hook_name" >&2 || true
}

self_src="${BASH_SOURCE[0]:-$0}"
self_dir="$(cd "$(dirname "$self_src")" 2>/dev/null && pwd -P || true)"
HQ_ROOT_RESOLVED=""
if [ -n "$self_dir" ]; then
  cand="$(cd "$self_dir/../.." 2>/dev/null && pwd -P || true)"
  if [ -n "$cand" ] && [ -f "$cand/core/scripts/hook-lib.sh" ]; then
    HQ_ROOT_RESOLVED="$cand"
  fi
fi
# Keep the main-branch fallback when hq-anywhere is disabled. The shared
# resolver defaults on for GA; only an explicit false disables it.
if [ -z "$HQ_ROOT_RESOLVED" ]; then
  HQ_ROOT_RESOLVED="${CLAUDE_PROJECT_DIR:-${HQ_ROOT:-}}"
  anywhere_enabled=true
  if [ -n "$self_dir" ] && command -v node >/dev/null 2>&1 \
    && [ -f "$self_dir/../../core/scripts/hq-anywhere-runtime-flag.cjs" ]; then
    if [ -f "$self_dir/../../core/scripts/hqd-hook-flag-cache-lib.sh" ]; then
      # Live, bounded read in a subshell; see hq_anywhere_flag_live_read
      # (feedback_a5c390e9).
      anywhere_enabled="$(
        # shellcheck disable=SC1091
        . "$self_dir/../../core/scripts/hqd-hook-flag-cache-lib.sh" 2>/dev/null \
          && hq_anywhere_flag_live_read "$self_dir/../../core/scripts/hq-anywhere-runtime-flag.cjs"
      )" || anywhere_enabled=true
      [ -n "$anywhere_enabled" ] || anywhere_enabled=true
    else
      anywhere_enabled="$(node "$self_dir/../../core/scripts/hq-anywhere-runtime-flag.cjs" || printf true)"
    fi
  fi
  case "${HQ_FLAG_HQ_ANYWHERE_RUNTIME:-}" in false|0) anywhere_enabled=false;; esac
  if [ "$anywhere_enabled" != "false" ] && [ -n "$self_dir" ] \
    && [ -f "$self_dir/../../core/scripts/resolve-hq-root.sh" ]; then
    HQ_ROOT_RESULT=""
    # Anchor on this gate's own install. Unanchored, the cwd's nearest HQ
    # root wins, so a root planted below the cwd would supply hook-lib.sh.
    # shellcheck source=../../core/scripts/resolve-hq-root.sh
    if . "$self_dir/../../core/scripts/resolve-hq-root.sh" --lib \
      && hq_resolve_root "$self_dir/../.." "$PWD"; then
      HQ_ROOT_RESOLVED="$HQ_ROOT_RESULT"
    fi
  fi
fi
# hook-lib.sh can exist but be unreadable on Windows when Git Bash chmod
# left NTFS DENY ACEs. Sourcing it then aborts this gate (set -e) and every
# registered hook silently fails to dispatch. Repair, then source only if
# readable; the inline fallback below still launches the hook.
hq_gate_repair_windows_acl() {
  local path="${1:-}" native user
  [ -n "$path" ] && [ -e "$path" ] || return 1
  [ -r "$path" ] && return 0
  case "${OSTYPE:-}" in msys*|cygwin*|win32*) ;; *)
    case "$(uname -s 2>/dev/null || true)" in MINGW*|MSYS*|CYGWIN*) ;; *) return 1 ;; esac
    ;;
  esac
  command -v icacls >/dev/null 2>&1 || return 1
  if command -v cygpath >/dev/null 2>&1; then
    native="$(cygpath -w "$path" 2>/dev/null || printf '%s' "$path")"
  else
    native="$path"
  fi
  user="${USERNAME:-${USER:-}}"
  icacls "$native" /reset >/dev/null 2>&1 || true
  if [ -n "$user" ]; then
    icacls "$native" /remove:d "$user" >/dev/null 2>&1 || true
    icacls "$native" /grant:r "${user}:(RX)" >/dev/null 2>&1 || true
  fi
  [ -r "$path" ]
}
HOOK_LIB="$HQ_ROOT_RESOLVED/core/scripts/hook-lib.sh"
if [ -n "$HQ_ROOT_RESOLVED" ] && [ -f "$HOOK_LIB" ]; then
  [ -r "$HOOK_LIB" ] || hq_gate_repair_windows_acl "$HOOK_LIB" || true
  if [ -r "$HOOK_LIB" ]; then
    # Shared HQ-owned launch helpers: bounded warnings, bash fallback.
    # shellcheck disable=SC1091
    . "$HOOK_LIB" || true
  fi
fi

# Determine profile (default: standard). An unknown name fails closed to
# strict; see hq_hook_profile_allows.
PROFILE="${HQ_HOOK_PROFILE:-standard}"
case "$PROFILE" in
  minimal|standard|strict) ;;
  *) hq_hook_profile_warn_unknown "$PROFILE"; PROFILE=strict ;;
esac

# Parse disabled hooks (comma-separated)
DISABLED_HOOKS="${HQ_DISABLED_HOOKS:-}"


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
  *)
    if is_in_strict_profile "$HOOK_ID"; then
      should_run=1
    fi
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
  if [ "$should_run" -eq 1 ] && [ "$HOOK_ID" = "$HQ_HOOK_LEGACY_ALIAS_TARGET" ] \
    && hq_hook_legacy_alias_disabled; then
    should_run=0
  fi
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
hq_augment_path

# The watchdog is deliberately armed only after the gate has decided this hook
# will run. It is a background sleeper and is reaped by the EXIT trap, so it
# never changes the delegated hook's stdout, stderr, exit status, or blocking
# decision. The helper reads the registration timeout from settings itself,
# keeping configuration work off this hot path.
HOOK_TIMEOUT_WATCHDOG="$HQ_ROOT_RESOLVED/.claude/hooks/hook-timeout-watchdog.sh"
hook_timeout_watchdog_pid=""
hook_timeout_watchdog_session=0

hook_timeout_watchdog_disabled() {
  local entry remaining
  remaining="${HQ_DISABLED_HOOKS:-}"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      *,*) entry="${remaining%%,*}"; remaining="${remaining#*,}" ;;
      *) entry="$remaining"; remaining="" ;;
    esac
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ "$entry" = "hook-timeout-sentry" ] && return 0
  done
  return 1
}

hook_timeout_watchdog_enabled() {
  case "${HQ_HOOK_TIMEOUT_SENTRY:-1}" in
    0|false|FALSE|no|NO|off|OFF) return 1 ;;
  esac
  hook_timeout_watchdog_disabled && return 1
  [ -f "$HOOK_TIMEOUT_WATCHDOG" ]
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
stop_hook_timeout_watchdog() {
  [ -n "$hook_timeout_watchdog_pid" ] || return 0
  if [ "$hook_timeout_watchdog_session" -eq 1 ]; then
    # Signal the setsid launcher as well as its group. The direct signal closes
    # the short race before setsid has created that group; once it has, the
    # group signal also interrupts the helper's sleep immediately.
    kill -TERM "$hook_timeout_watchdog_pid" >/dev/null 2>&1 || true
    kill -TERM -- "-$hook_timeout_watchdog_pid" >/dev/null 2>&1 || true
  else
    kill "$hook_timeout_watchdog_pid" >/dev/null 2>&1 || true
  fi
  # Reap only the session leader. The helper begins with an interruptible sleep,
  # so this is a cheap synchronization point that makes the no-orphan guarantee
  # deterministic without putting configuration parsing on the fast path.
  wait "$hook_timeout_watchdog_pid" >/dev/null 2>&1 || true
  hook_timeout_watchdog_pid=""
  hook_timeout_watchdog_session=0
}

# Windows Git Bash/MSYS/Cygwin: setsid() drops the hidden console that the
# desktop host gave this hook, so every native program the detached child runs
# (node, powershell, curl) opens a visible console window. Only use setsid on
# real POSIX hosts; on MSYS a plain background child keeps the hidden console.
hq_setsid_available() {
  # OSTYPE (set by bash itself) avoids forking uname on the hook hot path.
  case "${OSTYPE:-}" in msys*|cygwin*) return 1 ;; esac
  command -v setsid >/dev/null 2>&1
}

# One watchdog per hook event. An adapter that sourced hook-adapter-core.sh
# exports HQAD_DISPATCHER_PID and starts one gate per registry hook, so a
# watchdog per gate multiplied the processes of every adapter tool call. Gates
# whose parent is that live dispatcher share one watchdog: the first gate arms
# it against the dispatcher's pid and records its pid in a claim file, and
# later gates arm nothing while that watchdog is alive. Each gate writes its
# hook, pid and start time to "<claim>.active", so the shared watchdog warns
# about the gate that runs long, at that gate's own warning point, as a
# per-gate watchdog did. The watchdog only reports; it never changes a hook's
# output, exit status or decision, and it ends on its own once the dispatcher
# has exited. Any other gate (started by a harness registration, by a subshell
# of the adapter, or with no writable claim) keeps its own watchdog.
hook_timeout_event_dispatcher=""
case "${HQAD_DISPATCHER_PID:-}" in
  ''|0|*[!0-9]*) ;;
  *)
    if [ "$HQAD_DISPATCHER_PID" = "${PPID:-}" ] \
      && kill -0 "$HQAD_DISPATCHER_PID" >/dev/null 2>&1; then
      hook_timeout_event_dispatcher="$HQAD_DISPATCHER_PID"
    fi
    ;;
esac

# Return 0 when the claim file names a live watchdog process. Every redirection
# sits inside the braces, so a claim removed mid-read prints nothing.
hook_timeout_event_claim_live() {
  local claim_pid=""
  [ -r "$1" ] || return 1
  { IFS= read -r claim_pid < "$1"; } 2>/dev/null || true
  case "$claim_pid" in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$claim_pid" >/dev/null 2>&1
}

hook_timeout_event_claim=""
hook_timeout_event_covered=0
hook_timeout_tab=$'\t'
hook_timeout_newline='
'
if [ -n "$hook_timeout_event_dispatcher" ] && hook_timeout_watchdog_enabled; then
  hook_timeout_event_dir="$HQ_ROOT_RESOLVED/workspace/.hook-timeout-sentry"
  [ -d "$hook_timeout_event_dir" ] \
    || mkdir -p "$hook_timeout_event_dir" >/dev/null 2>&1 || true
  hook_timeout_event_claim="$hook_timeout_event_dir/gate-event-$hook_timeout_event_dispatcher.pid"
  # Record this gate first. A gate the shared watchdog cannot follow (a tab or
  # newline in its id or path, or no writable active file) keeps its own
  # watchdog. EPOCHSECONDS is trusted only from Bash 5, where it is the live
  # clock; older Bash would take a stale value from the environment.
  hook_timeout_event_epoch=""
  [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] || hook_timeout_event_epoch="${EPOCHSECONDS:-}"
  case "$HOOK_ID$HOOK_SCRIPT" in
    *"$hook_timeout_tab"*|*"$hook_timeout_newline"*) hook_timeout_event_claim="" ;;
    *)
      { printf '%s\t%s\t%s\t%s\n' "$HOOK_ID" "$HOOK_SCRIPT" "$$" "$hook_timeout_event_epoch" \
          > "$hook_timeout_event_claim.active"; } 2>/dev/null || hook_timeout_event_claim=""
      ;;
  esac
  if [ -z "$hook_timeout_event_claim" ]; then
    :
  elif hook_timeout_event_claim_live "$hook_timeout_event_claim"; then
    hook_timeout_event_covered=1
  elif ! { printf '' > "$hook_timeout_event_claim"; } 2>/dev/null; then
    # No writable claim: later gates could not see a shared watchdog, so this
    # gate keeps the per-gate watchdog it reaps on exit. printf, not the
    # special builtin ':', so a failed redirection cannot end the gate when
    # bash runs in POSIX mode.
    hook_timeout_event_claim=""
  fi
fi

if [ "$hook_timeout_event_covered" -eq 0 ] && [ -n "$hook_timeout_event_claim" ]; then
  [ -z "${HQ_HOOK_TIMEOUT_SENTRY_TEST_ARMED_FILE:-}" ] \
    || { printf '' > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_ARMED_FILE}"; } 2>/dev/null || true
  # Watches the dispatcher, not this gate, and is not reaped by this gate's
  # EXIT trap. Its stdio and fds 3-9 are detached so a caller that reads this
  # gate's output to EOF never waits on it.
  # --hook-path and --hook-id name this first gate; the watchdog re-reads the
  # active file and reports whichever gate actually ran long.
  if hq_setsid_available; then
    setsid bash "$HOOK_TIMEOUT_WATCHDOG" \
      --root "$HQ_ROOT_RESOLVED" \
      --source hook-gate \
      --hook-path "$HOOK_SCRIPT" \
      --hook-id "$HOOK_ID" \
      --parent-pid "$hook_timeout_event_dispatcher" \
      --claim-file "$hook_timeout_event_claim" \
      >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- <<<"$HOOK_PAYLOAD" &
  else
    bash "$HOOK_TIMEOUT_WATCHDOG" \
      --root "$HQ_ROOT_RESOLVED" \
      --source hook-gate \
      --hook-path "$HOOK_SCRIPT" \
      --hook-id "$HOOK_ID" \
      --parent-pid "$hook_timeout_event_dispatcher" \
      --claim-file "$hook_timeout_event_claim" \
      >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- <<<"$HOOK_PAYLOAD" &
  fi
  { printf '%s\n' "$!" > "$hook_timeout_event_claim"; } 2>/dev/null || true
elif [ "$hook_timeout_event_covered" -eq 0 ] && hook_timeout_watchdog_enabled; then
  # Test-only arming receipt. It is deliberately written by the foreground
  # gate, rather than the asynchronous helper, so disable coverage does not
  # depend on scheduler timing.
  [ -z "${HQ_HOOK_TIMEOUT_SENTRY_TEST_ARMED_FILE:-}" ] \
    || : > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_ARMED_FILE}" 2>/dev/null || true
  if hq_setsid_available; then
    setsid bash "$HOOK_TIMEOUT_WATCHDOG" \
      --root "$HQ_ROOT_RESOLVED" \
      --source hook-gate \
      --hook-path "$HOOK_SCRIPT" \
      --hook-id "$HOOK_ID" \
      --parent-pid "$$" \
      >/dev/null 2>&1 <<<"$HOOK_PAYLOAD" &
    hook_timeout_watchdog_session=1
  else
    bash "$HOOK_TIMEOUT_WATCHDOG" \
      --root "$HQ_ROOT_RESOLVED" \
      --source hook-gate \
      --hook-path "$HOOK_SCRIPT" \
      --hook-id "$HOOK_ID" \
      --parent-pid "$$" \
      >/dev/null 2>&1 <<<"$HOOK_PAYLOAD" &
  fi
  hook_timeout_watchdog_pid=$!
  trap stop_hook_timeout_watchdog EXIT
fi

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
  [ "$status" -ne 2 ] || hook_gate_report_block_reason
  exit "$status"
fi

# Inline fallback for an install whose hook-lib.sh could not be sourced. Same
# PIPESTATUS[1] contract as hq_launch_shell_path: a hook that exits before
# reading stdin kills the payload writer with SIGPIPE, and `pipefail` (set
# above) would otherwise report that writer's 141 as the hook's status.
# Do not chmod on Windows Git Bash: that writes NTFS DENY ACEs.
hq_gate_win=0
case "${OSTYPE:-}" in msys*|cygwin*|win32*) hq_gate_win=1 ;; esac
if [ "$hq_gate_win" -eq 0 ]; then
  case "$(uname -s 2>/dev/null || true)" in MINGW*|MSYS*|CYGWIN*) hq_gate_win=1 ;; esac
fi
if [ "$hq_gate_win" -eq 1 ]; then
  [ -r "$HOOK_SCRIPT" ] || hq_gate_repair_windows_acl "$HOOK_SCRIPT" || true
else
  chmod u+x "$HOOK_SCRIPT" 2>/dev/null || true
fi
if [ "$hq_gate_win" -eq 0 ] && [ -x "$HOOK_SCRIPT" ]; then
  status=0
  set +e
  printf '%s' "$HOOK_PAYLOAD" | "$HOOK_SCRIPT" "$@"
  status="${PIPESTATUS[1]}"
  set -e
  [ "$status" -ne 2 ] || hook_gate_report_block_reason
  exit "$status"
fi
status=0
set +e
printf '%s' "$HOOK_PAYLOAD" | bash "$HOOK_SCRIPT" "$@"
status="${PIPESTATUS[1]}"
set -e
[ "$status" -ne 2 ] || hook_gate_report_block_reason
exit "$status"
