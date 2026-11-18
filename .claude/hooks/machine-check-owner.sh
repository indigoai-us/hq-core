#!/bin/bash
# Sourced by master-hook. Only the twelve advisory machine checks may move to
# the daemon. An unavailable, slow, old or malformed CLI keeps the legacy path.
MASTER_MACHINE_CHECK_OWNER=unknown

# Seconds a non-daemon answer is reused before `hq` is asked again.
MASTER_MACHINE_CHECK_LEGACY_TTL=60
# Same window the CLI uses for its results file: two hourly intervals plus the
# one-minute first delay (hq-cli MACHINE_CHECK_RESULTS_FRESH_MS).
MASTER_MACHINE_CHECK_RESULTS_FRESH_S=7260

# Cheap necessary conditions for a daemon answer, read from files only. The CLI
# answers "daemon" only when the daemon wrote a fresh machine-checks.json and a
# native (`hq ... run --host`) SessionStart hook is registered. If either is
# missing here, the CLI would answer "legacy", so do not start it. The CLI also
# reads the retired project-level Codex hook file; HQ no longer ships it, and
# leaving it out can only keep the legacy checks.
master_machine_check_daemon_possible() {
  local dir results mtime now age file
  [ -n "${HOME:-}" ] || return 1
  dir="${HQ_DAEMON_DIR:-$HOME/.hq/daemon}"
  results="$dir/machine-checks.json"
  [ -f "$results" ] || return 1
  # GNU form first: BSD stat rejects -c without output, while GNU stat given
  # the BSD form prints file-system data before failing.
  mtime="$(stat -c %Y "$results" 2>/dev/null || stat -f %m "$results" 2>/dev/null)" || return 1
  now="$(date +%s 2>/dev/null)" || return 1
  case "$mtime:$now" in *[!0-9:]*|:*|*:) return 1 ;; esac
  age=$((now - mtime))
  [ "$age" -le "$MASTER_MACHINE_CHECK_RESULTS_FRESH_S" ] || return 1
  for file in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" \
    "$REPO_ROOT/.claude/settings.json" "$REPO_ROOT/.claude/settings.local.json" \
    "${CODEX_HOME:-$HOME/.codex}/hooks.json" "$REPO_ROOT/.codex/config.toml"; do
    [ -f "$file" ] && grep -qF -- '--host' "$file" 2>/dev/null && return 0
  done
  return 1
}

master_machine_check_legacy_stamp() {
  local key
  [ -n "${HOME:-}" ] || return 1
  key="$(printf '%s' "$REPO_ROOT" | cksum | awk '{print $1}')" || return 1
  printf '%s/.hq/machine-check-owner.legacy.%s\n' "$HOME" "$key"
}

# True while a recent non-daemon answer for this HQ root is still cached.
master_machine_check_legacy_cached() {
  local stamp at='' now
  stamp="$(master_machine_check_legacy_stamp)" || return 1
  [ -f "$stamp" ] || return 1
  IFS= read -r at < "$stamp" 2>/dev/null || return 1
  now="$(date +%s 2>/dev/null)" || return 1
  case "$at:$now" in *[!0-9:]*|:*|*:) return 1 ;; esac
  [ "$now" -ge "$at" ] && [ $((now - at)) -lt "$MASTER_MACHINE_CHECK_LEGACY_TTL" ]
}

master_machine_check_remember_legacy() {
  local stamp
  stamp="$(master_machine_check_legacy_stamp)" || return 0
  (umask 077; mkdir -p "${stamp%/*}" && date +%s > "$stamp") 2>/dev/null || true
}

master_machine_check_owned_by_daemon() {
  local event="$1" relative="$2" reply='' cli='' helper=''
  case "$event:$relative" in
    SessionStart:.claude/hooks/check-hq-update.sh|SessionStart:.claude/hooks/check-client-health.sh|SessionStart:.claude/hooks/check-stale-model-pin.sh|SessionStart:.claude/hooks/check-claude-desktop-bridge-health.sh|SessionStart:.claude/hooks/repair-stale-review-base.sh|SessionStart:.claude/hooks/welcome-brief-ready.sh|SessionStart:core/scripts/refresh-vault-access-session-start.sh|SessionStart:core/hooks/SessionStart/20-setup-completeness-nag.sh|SessionStart:core/hooks/SessionStart/40-fingerprint-hooks-enable.sh|SessionStart:core/hooks/SessionStart/50-agent-browser-presence-check.sh|UserPromptSubmit:core/hooks/UserPromptSubmit/30-ensure-hq-cli.sh|UserPromptSubmit:core/hooks/UserPromptSubmit/31-ensure-hq-desktop.sh) ;;
    *) return 1 ;;
  esac
  if [ "$MASTER_MACHINE_CHECK_OWNER" = unknown ]; then
    MASTER_MACHINE_CHECK_OWNER=legacy
    master_machine_check_daemon_possible || return 1
    master_machine_check_legacy_cached && return 1
    cli="$(command -v hq 2>/dev/null)" || return 1
    helper="$REPO_ROOT/core/scripts/hqd-hook-flag-cache-lib.sh"
    [ -f "$helper" ] || return 1
    # The existing runner's final fallback is unbounded. Do not query without
    # a timeout implementation; keeping the old check is safe in that case.
    command -v perl >/dev/null 2>&1 || command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || return 1
    reply="$(
      . "$helper"
      HQ_FLAG_READER_TIMEOUT_MS=2000 HQ_ROOT="$REPO_ROOT" HQ_COMPANY_SLUG="${ACTIVE_COMPANY:-${HQ_COMPANY_SLUG:-}}" \
        hq_flag_reader_run "$cli" core machine-check-owner </dev/null 2>/dev/null
    )" || reply=''
    if printf '%s' "$reply" | jq -e -s 'length == 1 and (.[0] | type == "object" and .schema == "hq-machine-check-owner.v1" and .owner == "daemon")' >/dev/null 2>&1; then
      MASTER_MACHINE_CHECK_OWNER=daemon
    else
      master_machine_check_remember_legacy
    fi
  fi
  [ "$MASTER_MACHINE_CHECK_OWNER" = daemon ] || return 1
  # Test hook: record that the dispatcher reached the skip decision.
  if [ -n "${HQ_MACHINE_CHECK_OWNER_TRACE:-}" ]; then
    printf 'skip %s:%s\n' "$event" "$relative" >> "$HQ_MACHINE_CHECK_OWNER_TRACE" 2>/dev/null || true
  fi
  return 0
}
