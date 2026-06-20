#!/usr/bin/env bash
# Regression coverage for feedback_ce873c1f: the hq-pack-cowork Claude Code /
# Cowork plugin shipped WITHOUT its `.mcp.json` manifest. A Claude Code plugin
# registers its MCP server(s) from a `.mcp.json` at the plugin root; with the
# file missing the host launches no server, so Cowork registered ZERO tools and
# the plugin was fully broken for users — even though the bundled
# mcp-server/index.mjs was present and the README documented the manifest.
#
# Guards that the plugin ships a valid, launchable MCP manifest:
#   1. .mcp.json exists at the plugin root and is valid JSON.
#   2. It declares at least one server under mcpServers.
#   3. The "hq" server launches `node` against the bundled stdio server, and the
#      arg path is anchored to ${CLAUDE_PLUGIN_ROOT} (resolves to the installed
#      plugin dir) so it works regardless of where the host unpacks the plugin.
#   4. The referenced server file actually exists in the package and parses
#      under node --check — i.e. the manifest points at a real, runnable server.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PLUGIN="${ROOT}/core/packages/hq-pack-cowork"
MCP_JSON="${PLUGIN}/.mcp.json"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Manifest present and valid JSON.
[[ -f "$MCP_JSON" ]] \
  || fail ".mcp.json missing at ${MCP_JSON} — plugin registers no MCP tools"
jq -e . "$MCP_JSON" >/dev/null 2>&1 \
  || fail ".mcp.json is not valid JSON: ${MCP_JSON}"

# 2. At least one MCP server declared.
servers="$(jq -r '.mcpServers | keys[]?' "$MCP_JSON")"
[[ -n "$servers" ]] \
  || fail ".mcp.json declares no servers under .mcpServers"

# 3. The "hq" server is a node-launched stdio server anchored to the plugin root.
jq -e '.mcpServers.hq' "$MCP_JSON" >/dev/null 2>&1 \
  || fail ".mcp.json has no \"hq\" server entry"
cmd="$(jq -r '.mcpServers.hq.command' "$MCP_JSON")"
[[ "$cmd" == "node" ]] \
  || fail "expected mcpServers.hq.command == node, got: ${cmd}"
arg="$(jq -r '.mcpServers.hq.args[0]' "$MCP_JSON")"
[[ "$arg" == *'${CLAUDE_PLUGIN_ROOT}'* ]] \
  || fail "server arg must be anchored to \${CLAUDE_PLUGIN_ROOT}; got: ${arg}"
[[ "$arg" == *'mcp-server/index.mjs' ]] \
  || fail "server arg must point at mcp-server/index.mjs; got: ${arg}"

# 4. The referenced server file exists in the package and parses.
rel="${arg#*\}/}"                       # strip ${CLAUDE_PLUGIN_ROOT}/ prefix
server_file="${PLUGIN}/${rel}"
[[ -f "$server_file" ]] \
  || fail ".mcp.json points at a server that is not shipped: ${server_file}"
if command -v node >/dev/null 2>&1; then
  node --check "$server_file" \
    || fail "bundled MCP server does not parse: ${server_file}"
fi

echo "PASS: cowork-plugin-mcp-json (.mcp.json valid + registers node stdio server + server present & parses)"
