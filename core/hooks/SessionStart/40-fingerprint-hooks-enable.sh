#!/usr/bin/env bash
# hq-core: public
# SessionStart: wire the HQ-Fingerprint commit trailer once a day while
# core/settings/fingerprint.yaml (or the personal override) says enabled: true.
# When the setting says false, clear the hq.hooks.fingerprint flag at the next
# session start; the commit secret scan stays on, and the dispatcher stays
# while the secret scan uses it and is put back otherwise. Setting it back to
# true turns the trailer on again at the next start, even on a day already
# stamped.
# Exit code: always 0. Silent and fail-open; the stamped path is one settings
# read and one git config read.
# Skipped on fleet and Outpost agent boxes: they must not rewrite the agent's
# global git config every day. Markers: HQ_AGENT_WORKDIR, HQ_AGENT_COMPANY_DIR,
# HQ_AGENT_IDENTITY_FILE or OUTPOST_INSTANCE_TOKEN set, or any of the agent
# identity, machine-creds and Outpost runner files below. HQ_AGENT_ROOT_PREFIX
# (tests) is put in front of every file path.

set -uo pipefail

{
  [ "${CI+x}" = "x" ] && exit 0
  [ -n "${HQ_AGENT_WORKDIR:-}" ] && exit 0
  [ -n "${HQ_AGENT_COMPANY_DIR:-}" ] && exit 0
  [ -n "${HQ_AGENT_IDENTITY_FILE:-}" ] && exit 0
  [ -n "${OUTPOST_INSTANCE_TOKEN:-}" ] && exit 0
  P="${HQ_AGENT_ROOT_PREFIX:-}"
  for f in /etc/hq-agent/identity.json /etc/hq-agent/machine-creds.json \
           /var/lib/hq-agent/identity.json /var/lib/hq-agent/machine-creds.json \
           /etc/outpost/codex-identity.env /usr/local/bin/outpost-runner.sh; do
    [ -e "$P$f" ] && exit 0
  done
  [ -d "$P/etc/outpost" ] && exit 0
  STAMP="${HOME:-/tmp}/.hq/fingerprint-hooks-enable.$(date +%Y%m%d 2>/dev/null)"

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || exit 0
  ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../../.." 2>/dev/null && pwd -P)}"
  [ -f "$ROOT/core/core.yaml" ] || exit 0
  # A checkout under repos/ or a worktree is not an HQ folder: hook stubs
  # pointing into it would break once it is removed.
  case "$ROOT/" in */repos/*|*/workspace/worktrees/*) exit 0 ;; esac
  SCRIPT="$ROOT/core/scripts/hq-fingerprint-hooks.sh"
  [ -f "$SCRIPT" ] || exit 0

  enabled_in() { # file
    [ -f "$1" ] || return 1
    grep -E '^enabled:' "$1" 2>/dev/null | head -n 1 | sed -E 's/^enabled:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]+$//'
  }
  EN="$(enabled_in "$ROOT/personal/settings/fingerprint.yaml")"
  [ -n "$EN" ] || EN="$(enabled_in "$ROOT/core/settings/fingerprint.yaml")"
  MARK="$(git config --global --get hq.hooks.fingerprint 2>/dev/null)"
  if [ "$EN" != "true" ]; then
    # Turned off by hand: clear the trailer flag so the commit-msg stub stops
    # starting bash. The secret scan, and the dispatcher while the secret
    # scan is on, stay wired.
    if [ "$MARK" = "true" ]; then
      HQ_ROOT="$ROOT" bash "$SCRIPT" disable --keep-setting >/dev/null 2>&1 </dev/null
    fi
    rm -f "$STAMP" 2>/dev/null
    exit 0
  fi
  # Stamped today and still on: nothing to do.
  [ -f "$STAMP" ] && [ "$MARK" = "true" ] && exit 0

  HQ_ROOT="$ROOT" bash "$SCRIPT" enable >/dev/null 2>&1 </dev/null || exit 0
  mkdir -p "$(dirname "$STAMP")" 2>/dev/null || exit 0
  rm -f "$(dirname "$STAMP")"/fingerprint-hooks-enable.[0-9]* 2>/dev/null
  : >"$STAMP" 2>/dev/null
  exit 0
} 2>/dev/null
