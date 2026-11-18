#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: build-claude-marketplace.sh <built-plugin-directory> <output-marketplace-directory>" >&2
  exit 2
fi
plugin=$(cd "$1" && pwd -P)
marketplace=$(mkdir -p "$2" && cd "$2" && pwd -P)
mkdir -p "$marketplace/.claude-plugin" "$marketplace/plugins"
target="$marketplace/plugins/hq"
case "$plugin/" in
  "$target/"*)
    echo "error: plugin input must not be the marketplace target or inside it: $plugin" >&2
    exit 1
    ;;
esac
rm -rf "$target"
cp -R "$plugin" "$marketplace/plugins/hq"
cat > "$marketplace/.claude-plugin/marketplace.json" <<'JSON'
{
  "name": "hq-marketplace",
  "owner": {
    "name": "Indigo"
  },
  "plugins": [
    {
      "name": "hq",
      "source": "./plugins/hq",
      "description": "HQ runtime hooks, skills, and MCP server for Claude Code"
    }
  ]
}
JSON
echo "Built Claude Code marketplace at $marketplace"
