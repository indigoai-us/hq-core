#!/usr/bin/env bash
# Trust this HQ tree for Grok project hooks so HQ's .grok/ PreToolUse guards run
# in headless `grok -p`. Grok silently SKIPS project hooks until the project's
# canonical absolute path is listed in ~/.grok/trusted-hook-projects (a
# supply-chain guard). Idempotent; safe to re-run. Pair with the .codex hooks
# (auto-trusted via ~/.codex/config.toml) so Codex + Grok enforce at parity with
# Claude Code's settings.json hooks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TP="$HOME/.grok/trusted-hook-projects"
mkdir -p "$HOME/.grok"; touch "$TP"
if grep -qxF "$ROOT" "$TP" 2>/dev/null; then
  echo "grok-trust: already trusted -> $ROOT"
else
  printf '%s\n' "$ROOT" >> "$TP"
  echo "grok-trust: added -> $ROOT"
fi
if [ -d "$ROOT/.grok/hooks" ]; then
  echo "grok-trust: .grok/hooks present — HQ guards will enforce for headless grok -p."
else
  echo "grok-trust: WARNING — $ROOT/.grok/hooks not found; ship the .grok/ dir into this tree." >&2
fi
