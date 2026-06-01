#!/usr/bin/env bash
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$HOME/Downloads/hq-pack-cowork.plugin"
INSTALL_CLAUDE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install|--claude-install)
      INSTALL_CLAUDE=1
      shift
      ;;
    --out)
      if [[ $# -lt 2 ]]; then
        echo "Error: --out requires a path."
        exit 2
      fi
      OUT="$2"
      shift 2
      ;;
    -*)
      echo "Error: unknown option: $1"
      exit 2
      ;;
    *)
      OUT="$1"
      shift
      ;;
  esac
done

status_line() {
  local label="$1"
  local value="$2"
  printf '  %-12s %s\n' "$label:" "$value"
}

find_bin() {
  local bin="$1"
  command -v "$bin" 2>/dev/null || true
}

NODE_BIN="$(find_bin node)"
HQ_BIN="$(find_bin hq)"
QMD_BIN="$(find_bin qmd)"
CLAUDE_BIN="$(find_bin claude)"

echo "HQ Cowork plugin installer"
echo

if [[ -z "$NODE_BIN" ]]; then
  echo "Error: node is required to build and run the plugin."
  echo "Install Node.js 18+ and retry."
  exit 1
fi

status_line "node" "$("$NODE_BIN" --version 2>/dev/null || echo "$NODE_BIN")"
if [[ -n "$HQ_BIN" ]]; then
  status_line "hq" "$HQ_BIN"
else
  status_line "hq" "missing (install @indigoai-us/hq-cli before using HQ tools)"
fi
if [[ -n "$QMD_BIN" ]]; then
  status_line "qmd" "$QMD_BIN"
else
  status_line "qmd" "missing (install qmd for search/read support)"
fi
if [[ "$INSTALL_CLAUDE" == "1" ]]; then
  if [[ -n "$CLAUDE_BIN" ]]; then
    status_line "claude" "$CLAUDE_BIN"
  else
    status_line "claude" "missing (required for --install)"
  fi
fi

echo
echo "Building Cowork upload artifact..."
PLUGIN_PATH="$("$PACK_ROOT/scripts/build-plugin.sh" "$OUT")"

echo
echo "Built:"
echo "  $PLUGIN_PATH"
echo

if [[ "$INSTALL_CLAUDE" == "1" ]]; then
  if [[ -z "$CLAUDE_BIN" ]]; then
    echo "Error: claude is required for --install."
    exit 1
  fi

  echo "Installing for Claude Code / Cowork plugin hosts..."
  # Idempotent: `|| true` so a re-run doesn't abort under `set -euo pipefail`
  # when the marketplace/plugin already exists (the skill tells users to re-run).
  "$CLAUDE_BIN" plugin marketplace add "$PACK_ROOT" || true
  "$CLAUDE_BIN" plugin install hq-cowork@hq --scope user || true
  "$CLAUDE_BIN" plugin enable hq-cowork@hq --scope user >/dev/null 2>&1 || true
  echo "Installed and enabled:"
  echo "  hq-cowork@hq"
  echo
fi

echo "Install in Cowork:"
echo "  1. Open Cowork."
echo "  2. Go to Customize > Plugins."
echo "  3. Upload a custom plugin file."
echo "  4. Choose: $PLUGIN_PATH"
echo "  5. Enable the plugin and restart the Cowork session."
echo
echo "Smoke test in Cowork:"
echo "  /mcp"
echo "  Ask: \"Can you call hq_whoami?\""
echo "  Ask: \"Search HQ for cowork plugin.\""
echo

if [[ -z "$HQ_BIN" || -z "$QMD_BIN" ]]; then
  echo "Note: the plugin was built, but missing host binaries above should be installed before full use."
fi
