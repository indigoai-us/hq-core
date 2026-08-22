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
#   3. The "hq" server launches through the system shell and a bundled bootstrap
#      anchored to ${CLAUDE_PLUGIN_ROOT} (resolves to the installed plugin dir).
#   4. The referenced bootstrap and server files exist and parse.
#   5. The built artifact starts with a GUI-style stripped PATH and resolves
#      node, hq, and qmd from HQ Desktop's managed macOS toolchain.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PLUGIN="${ROOT}/core/packages/hq-pack-cowork"
MCP_JSON="${PLUGIN}/.mcp.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

# 3. The "hq" server is shell-bootstrapped from the plugin root. `/bin/sh` is
# available to a macOS GUI process even when no interactive-shell PATH exists.
jq -e '.mcpServers.hq' "$MCP_JSON" >/dev/null 2>&1 \
  || fail ".mcp.json has no \"hq\" server entry"
cmd="$(jq -r '.mcpServers.hq.command' "$MCP_JSON")"
[[ "$cmd" == "/bin/sh" ]] \
  || fail "expected mcpServers.hq.command == /bin/sh, got: ${cmd}"
arg="$(jq -r '.mcpServers.hq.args[0]' "$MCP_JSON")"
[[ "$arg" == *'${CLAUDE_PLUGIN_ROOT}'* ]] \
  || fail "server arg must be anchored to \${CLAUDE_PLUGIN_ROOT}; got: ${arg}"
[[ "$arg" == *'mcp-server/launch.sh' ]] \
  || fail "server arg must point at mcp-server/launch.sh; got: ${arg}"

# 4. The referenced bootstrap and server files exist in the package, the
# bootstrap parses as POSIX shell, and the server parses as JavaScript.
rel="${arg#*\}/}"                       # strip ${CLAUDE_PLUGIN_ROOT}/ prefix
launcher_file="${PLUGIN}/${rel}"
server_file="${PLUGIN}/mcp-server/index.mjs"
[[ -f "$launcher_file" ]] \
  || fail ".mcp.json points at a bootstrap that is not shipped: ${launcher_file}"
[[ -f "$server_file" ]] \
  || fail "bundled MCP server is not shipped: ${server_file}"
/bin/sh -n "$launcher_file" \
  || fail "bundled MCP bootstrap does not parse: ${launcher_file}"
if command -v node >/dev/null 2>&1; then
  node --check "$server_file" \
    || fail "bundled MCP server does not parse: ${server_file}"
fi

# 5. Build the distributable and exercise its public MCP interface with the
# environment shape Cowork inherits from a macOS GUI launch. The fake HOME and
# managed toolchain paths intentionally contain spaces.
for required in node npm rsync unzip zip; do
  command -v "$required" >/dev/null 2>&1 \
    || fail "$required is required for the packaged-plugin smoke test"
done

REAL_NODE="$(command -v node)"
ARTIFACT="$TMP/hq-pack-cowork.plugin"
PACKAGED="$TMP/Packaged Plugin"
GUI_HOME="$TMP/GUI Home"
HQ_ROOT="$TMP/HQ Root"
TOOLCHAIN="$GUI_HOME/Library/Application Support/Indigo HQ/toolchain"
SYSTEM_BIN="$TMP/system-bin"
mkdir -p \
  "$PACKAGED" \
  "$HQ_ROOT" \
  "$TOOLCHAIN/node/bin" \
  "$TOOLCHAIN/npm-global/bin" \
  "$SYSTEM_BIN"

ln -s "$REAL_NODE" "$TOOLCHAIN/node/bin/node"
ln -s /bin/sh "$SYSTEM_BIN/sh"

cat >"$TOOLCHAIN/npm-global/bin/hq" <<'EOF'
#!/bin/sh
printf '%s\n' 'identity-managed-ok'
EOF
cat >"$TOOLCHAIN/npm-global/bin/qmd" <<'EOF'
#!/bin/sh
printf '%s\n' 'search-managed-ok'
EOF
chmod +x "$TOOLCHAIN/npm-global/bin/hq" "$TOOLCHAIN/npm-global/bin/qmd"

if ! npm_config_cache="$TMP/npm-cache" \
  "$PLUGIN/scripts/build-plugin.sh" "$ARTIFACT" >"$TMP/build.out" 2>"$TMP/build.err"; then
  sed -n '1,160p' "$TMP/build.err" >&2
  fail "failed to build packaged Cowork plugin"
fi
unzip -q "$ARTIFACT" -d "$PACKAGED"

cat >"$TMP/mcp-smoke.mjs" <<'EOF'
import { readFile } from "node:fs/promises";
import { spawn } from "node:child_process";

const [pluginRoot, home, path, hqRoot, expectedIdentity, expectedSearch] = process.argv.slice(2);
const manifest = JSON.parse(await readFile(`${pluginRoot}/.mcp.json`, "utf8"));
const config = manifest.mcpServers.hq;
const expand = (value) => value.replaceAll("${CLAUDE_PLUGIN_ROOT}", pluginRoot);
const childEnv = { HOME: home, PATH: path, HQ_ROOT: hqRoot };
for (const key of ["HQ_BIN", "QMD_BIN", "NODE_BIN"]) {
  if (process.env[key]) childEnv[key] = process.env[key];
}

const child = spawn(expand(config.command), config.args.map(expand), {
  env: childEnv,
  stdio: ["pipe", "pipe", "pipe"],
});
let stdoutBuffer = "";
let stderr = "";
let nextId = 1;
const pending = new Map();

function rejectPending(error) {
  for (const { reject, timer } of pending.values()) {
    clearTimeout(timer);
    reject(error);
  }
  pending.clear();
}

child.on("error", (error) => rejectPending(error));
child.on("exit", (code, signal) => {
  if (pending.size > 0) {
    rejectPending(new Error(`MCP server exited before replying (code=${code}, signal=${signal}): ${stderr}`));
  }
});
child.stderr.on("data", (chunk) => { stderr += chunk; });
child.stdout.on("data", (chunk) => {
  stdoutBuffer += chunk;
  while (stdoutBuffer.includes("\n")) {
    const newline = stdoutBuffer.indexOf("\n");
    const line = stdoutBuffer.slice(0, newline);
    stdoutBuffer = stdoutBuffer.slice(newline + 1);
    if (!line.trim()) continue;
    const message = JSON.parse(line);
    if (message.id === undefined || !pending.has(message.id)) continue;
    const { resolve, reject, timer } = pending.get(message.id);
    pending.delete(message.id);
    clearTimeout(timer);
    if (message.error) reject(new Error(JSON.stringify(message.error)));
    else resolve(message.result);
  }
});

function send(message) {
  child.stdin.write(`${JSON.stringify(message)}\n`);
}

function request(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Timed out waiting for ${method}: ${stderr}`));
    }, 10000);
    pending.set(id, { resolve, reject, timer });
    send({ jsonrpc: "2.0", id, method, params });
  });
}

try {
  await request("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "cowork-packaged-smoke", version: "1.0.0" },
  });
  send({ jsonrpc: "2.0", method: "notifications/initialized", params: {} });
  const identity = await request("tools/call", {
    name: "hq_whoami",
    arguments: {},
  });
  const search = await request("tools/call", {
    name: "hq_search",
    arguments: { query: "cowork plugin" },
  });
  const identityText = identity.content?.map((part) => part.text || "").join("\n") || "";
  const searchText = search.content?.map((part) => part.text || "").join("\n") || "";
  if (identity.isError || !identityText.includes(expectedIdentity)) {
    throw new Error(`identity tool did not use expected binary: ${JSON.stringify(identity)}`);
  }
  if (search.isError || !searchText.includes(expectedSearch)) {
    throw new Error(`search tool did not use expected binary: ${JSON.stringify(search)}`);
  }
} finally {
  child.kill();
}
EOF

"$REAL_NODE" "$TMP/mcp-smoke.mjs" \
  "$PACKAGED" "$GUI_HOME" "$SYSTEM_BIN" "$HQ_ROOT" \
  identity-managed-ok search-managed-ok \
  || fail "packaged plugin could not use HQ Desktop's managed toolchain with a stripped PATH"

# Existing absolute overrides must still win, including when their paths have
# spaces. Relative overrides are intentionally invalid and must be ignored.
OVERRIDE_BIN="$TMP/Absolute Overrides"
mkdir -p "$OVERRIDE_BIN"
cat >"$OVERRIDE_BIN/hq" <<'EOF'
#!/bin/sh
printf '%s\n' 'identity-override-ok'
EOF
cat >"$OVERRIDE_BIN/qmd" <<'EOF'
#!/bin/sh
printf '%s\n' 'search-override-ok'
EOF
chmod +x "$OVERRIDE_BIN/hq" "$OVERRIDE_BIN/qmd"
ln -s "$REAL_NODE" "$OVERRIDE_BIN/node"

mv "$TOOLCHAIN/node/bin/node" "$TOOLCHAIN/node/bin/node.managed"
NODE_BIN="$OVERRIDE_BIN/node" HQ_BIN="$OVERRIDE_BIN/hq" QMD_BIN="$OVERRIDE_BIN/qmd" \
  "$REAL_NODE" "$TMP/mcp-smoke.mjs" \
  "$PACKAGED" "$GUI_HOME" "$SYSTEM_BIN" "$HQ_ROOT" \
  identity-override-ok search-override-ok \
  || fail "packaged plugin did not honor validated absolute binary overrides"
mv "$TOOLCHAIN/node/bin/node.managed" "$TOOLCHAIN/node/bin/node"

NODE_BIN="relative-node" HQ_BIN="relative-hq" QMD_BIN="relative-qmd" \
  "$REAL_NODE" "$TMP/mcp-smoke.mjs" \
  "$PACKAGED" "$GUI_HOME" "$SYSTEM_BIN" "$HQ_ROOT" \
  identity-managed-ok search-managed-ok \
  || fail "packaged plugin accepted invalid relative binary overrides"

echo "PASS: cowork packaged plugin launches and resolves managed/overridden tools with stripped PATH"
