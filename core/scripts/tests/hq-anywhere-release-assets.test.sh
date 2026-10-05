#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
if [[ $# -gt 1 ]]; then
  echo "usage: hq-anywhere-release-assets.test.sh [output-directory]" >&2
  exit 2
fi

tmp=''
if [[ $# -eq 1 ]]; then
  output=$(mkdir -p "$1" && cd "$1" && pwd -P)
else
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  output="$tmp/assets"
  mkdir -p "$output"
fi

plugin="$output/claude-plugin"
marketplace="$output/claude-marketplace"
pack="$output/codex-pack"

bash "$repo_root/core/scripts/build-claude-plugin.sh" "$plugin"
bash "$repo_root/core/scripts/build-claude-marketplace.sh" "$plugin" "$marketplace"
bash "$repo_root/core/scripts/build-codex-pack.sh" "$pack"

node "$repo_root/core/scripts/validate-agent-runtime-contracts.mjs" --root "$repo_root" --plugin-dir "$plugin"
node "$repo_root/core/scripts/validate-agent-runtime-contracts.mjs" --root "$repo_root" --skill-dir "$pack"

node - "$plugin" "$marketplace" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const [plugin, marketplace] = process.argv.slice(2);
const pluginManifestPath = path.join(plugin, '.claude-plugin/plugin.json');
const pluginManifest = JSON.parse(fs.readFileSync(pluginManifestPath, 'utf8'));
assert.equal(pluginManifest.name, 'hq');
assert.ok(fs.existsSync(path.join(plugin, 'hooks/hooks.json')));
assert.ok(fs.existsSync(path.join(plugin, '.mcp.json')));

const marketplaceManifestPath = path.join(marketplace, '.claude-plugin/marketplace.json');
const marketplaceManifest = JSON.parse(fs.readFileSync(marketplaceManifestPath, 'utf8'));
assert.ok(Array.isArray(marketplaceManifest.plugins));
assert.ok(marketplaceManifest.plugins.some((entry) => entry.name === 'hq' && entry.source === './plugins/hq'));
assert.ok(fs.existsSync(path.join(marketplace, 'plugins/hq/.claude-plugin/plugin.json')));
NODE

node - "$pack/package.yaml" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const parserRoot = process.env.HQ_AGENT_RUNTIME_PARSER_ROOT;
assert.ok(parserRoot, 'HQ_AGENT_RUNTIME_PARSER_ROOT must point to the pinned js-yaml installation');
const requireFromParser = createRequire(path.join(parserRoot, 'hq-anywhere-release-assets.cjs'));
const yaml = requireFromParser('js-yaml');
const manifest = yaml.load(fs.readFileSync(process.argv[2], 'utf8'));
assert.equal(manifest.name, 'hq-anywhere');
for (const contribution of ['skills', 'hooks', 'mcp']) {
  assert.ok(Array.isArray(manifest.contributes?.[contribution]), `package.yaml contributes.${contribution} must be an array`);
  assert.ok(manifest.contributes[contribution].length > 0, `package.yaml contributes.${contribution} must not be empty`);
}
NODE

tar -czf "$output/hq-anywhere-claude-plugin.tar.gz" -C "$output" claude-plugin
tar -czf "$output/hq-anywhere-claude-marketplace.tar.gz" -C "$output" claude-marketplace
tar -czf "$output/hq-anywhere-codex-pack.tar.gz" -C "$output" codex-pack

for asset in \
  "$output/hq-anywhere-claude-plugin.tar.gz" \
  "$output/hq-anywhere-claude-marketplace.tar.gz" \
  "$output/hq-anywhere-codex-pack.tar.gz"; do
  test -s "$asset"
done

echo "hq-anywhere release artifacts built and validated at $output"
