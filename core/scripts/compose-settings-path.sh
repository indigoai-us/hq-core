#!/usr/bin/env bash
# hq-core: public
# core/scripts/compose-settings-path.sh — compose the env.PATH value written
# into a Claude settings file by setup.sh.
#
# Claude Code's env block does LITERAL assignment (no $PATH expansion) and it
# overrides the inherited environment for every hook and subagent shell, so
# the snapshot must already contain every directory those shells need.
#
# The base is the caller's PATH. But when HQ was installed by the native
# installer, the managed toolchain (node, qmd, hq, git) lives under
# "~/Library/Application Support/Indigo HQ/toolchain" and is wired into PATH
# only via an interactive-shell profile block — which a GUI-launched Claude
# (Dock, Spotlight, deep link) never sources. Without this correction the
# snapshot taken from such a session omits the toolchain and hooks fail with
# "qmd: command not found" until someone re-runs setup from a terminal.
# Prepend each toolchain bin dir in installer order whenever it exists on disk.
# This is deliberate: the bundled toolchain ABI must win over older user-shell
# tools. User and caller entries follow it in first-seen order.
#
# Usage: compose-settings-path.sh [BASE_PATH]
#   BASE_PATH defaults to $PATH. Prints the composed PATH on stdout.
#   HQ_TOOLCHAIN_DIR overrides the toolchain root (tests).
set -euo pipefail

BASE="${1:-$PATH}"
TOOLCHAIN="${HQ_TOOLCHAIN_DIR:-$HOME/Library/Application Support/Indigo HQ/toolchain}"

is_temporary_path() {
  local entry="$1" tmp_root
  [[ "/$entry/" == *"/_npx/"* ]] && return 0
  for tmp_root in "${TMPDIR:-}" /tmp /var/tmp /private/tmp /private/var/folders; do
    [[ -n "$tmp_root" ]] || continue
    tmp_root="${tmp_root%/}"
    case "$entry/" in "$tmp_root/"*) return 0 ;; esac
  done
  return 1
}

COMPOSED=""
append_path() {
  local entry="$1"
  [[ -n "$entry" ]] || return 0
  is_temporary_path "$entry" && return 0
  case ":$COMPOSED:" in *":$entry:"*) return 0 ;; esac
  COMPOSED="${COMPOSED:+$COMPOSED:}$entry"
}

IFS=: read -r -a BASE_ENTRIES <<< "$BASE"
# Explicit installer toolchain entries are trusted and bypass temp filtering:
# tests and real installations may keep them below a temporary-looking root.
for dir in "$TOOLCHAIN/node/bin" "$TOOLCHAIN/npm-global/bin" "$TOOLCHAIN/git/bin"; do
  [[ -d "$dir" ]] || continue
  case ":$COMPOSED:" in *":$dir:"*) ;; *) COMPOSED="${COMPOSED:+$COMPOSED:}$dir" ;; esac
done
for dir in "${BASE_ENTRIES[@]}"; do
  append_path "$dir"
done

printf '%s\n' "$COMPOSED"
