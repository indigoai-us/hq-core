#!/usr/bin/env bash
# skill-inventory.sh — read-only inventory of HQ skills and slash commands.
#
# Generates the command reference page (core/docs/hq/COMMANDS.md) and the
# command palette data (core/docs/hq/commands.json) from one source, and
# reports exact duplicates, drifted copies, and near-duplicate descriptions.
# Implementation: core/scripts/skill-inventory.mjs. Run with --help for modes.
#
# Usage:
#   bash core/scripts/skill-inventory.sh --root <hq> --findings
#   bash core/scripts/skill-inventory.sh --json --scope shipped --out core/docs/hq/commands.json
#   bash core/scripts/skill-inventory.sh --markdown --scope shipped --out core/docs/hq/COMMANDS.md
#   bash core/scripts/skill-inventory.sh --check

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
command -v node >/dev/null 2>&1 || { echo "skill-inventory: node is required" >&2; exit 69; }
exec node "$SCRIPT_DIR/skill-inventory.mjs" "$@"
