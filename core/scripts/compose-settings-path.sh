#!/usr/bin/env bash
# hq-core: public
# core/scripts/compose-settings-path.sh — compose the env.PATH value written
# into .claude/settings.json by setup.sh.
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
# Prepend each toolchain bin dir whenever it exists on disk and is missing
# from the base, matching the installer's PATH ordering (node, npm-global,
# git first so the toolchain ABI wins over older user-shell tools).
#
# Usage: compose-settings-path.sh [BASE_PATH]
#   BASE_PATH defaults to $PATH. Prints the composed PATH on stdout.
#   HQ_TOOLCHAIN_DIR overrides the toolchain root (tests).
set -euo pipefail

BASE="${1:-$PATH}"
TOOLCHAIN="${HQ_TOOLCHAIN_DIR:-$HOME/Library/Application Support/Indigo HQ/toolchain}"

path_contains() {
  case ":$1:" in
    *":$2:"*) return 0 ;;
    *) return 1 ;;
  esac
}

COMPOSED="$BASE"
# Reverse priority order — each existing-but-missing dir is prepended, so the
# last one prepended ends up first. Final order: node, npm-global, git, base.
for dir in "$TOOLCHAIN/git/bin" "$TOOLCHAIN/npm-global/bin" "$TOOLCHAIN/node/bin"; do
  if [[ -d "$dir" ]] && ! path_contains "$COMPOSED" "$dir"; then
    COMPOSED="$dir:$COMPOSED"
  fi
done

printf '%s\n' "$COMPOSED"
