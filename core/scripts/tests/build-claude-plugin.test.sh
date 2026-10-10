#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
plugin="$tmp/plugin"
marketplace="$tmp/marketplace"

path_fixtures="$tmp/path-fixtures"
mkdir -p "$path_fixtures"
filter="$repo_root/core/scripts/lib/skill-has-unshipped-hq-path.sh"
for path in 'core/scripts/example.sh' './.claude/hooks/example.sh' '$HQ_ROOT/core/policies/example.md'; do
  printf '%s\n' "$path" > "$path_fixtures/path.md"
  bash "$filter" "$path_fixtures/path.md"
done
for path in '$HOME/.claude/projects/session.jsonl' '<repo>/.claude/policies/rule.md' 'libs/core/auth'; do
  printf '%s\n' "$path" > "$path_fixtures/path.md"
  if bash "$filter" "$path_fixtures/path.md"; then
    echo "shared path filter misclassified portable reference: $path" >&2
    exit 1
  fi
done

bash "$repo_root/core/scripts/build-claude-plugin.sh" "$plugin"
node "$repo_root/core/scripts/validate-agent-runtime-contracts.mjs" --root "$repo_root" --plugin-dir "$plugin"

bad_plugin="$tmp/bad-plugin"
cp -R "$plugin" "$bad_plugin"
mkdir -p "$bad_plugin/skills/bad-metadata"
cat > "$bad_plugin/skills/bad-metadata/SKILL.md" <<'SKILL'
---
name: ""
description: malformed plugin metadata fixture
---
SKILL
if node "$repo_root/core/scripts/validate-agent-runtime-contracts.mjs" --root "$repo_root" --plugin-dir "$bad_plugin" >"$tmp/validator.out" 2>&1; then
  echo 'validator accepted malformed plugin skill metadata' >&2
  exit 1
fi
grep -q 'name must be a non-empty string' "$tmp/validator.out"

node - "$plugin" "$repo_root" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const [plugin, repo] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(path.join(plugin, '.claude-plugin/plugin.json'), 'utf8'));
assert.equal(manifest.name, 'hq');
const hooks = JSON.parse(fs.readFileSync(path.join(plugin, 'hooks/hooks.json'), 'utf8')).hooks;
for (const event of ['PreToolUse','PostToolUse','PreCompact','Stop','SessionStart','UserPromptSubmit','Notification','SubagentStart','SubagentStop','SessionEnd']) {
  const eventHooks = hooks[event].flatMap(group => group.hooks);
  const commands = eventHooks.map(hook => hook.command);
  assert.ok(commands.length, `missing ${event} hook`);
  for (const hook of eventHooks) {
    assert.equal(hook.timeout, 300, `${event} hook timeout`);
    const command = hook.command;
    assert.match(command, /\$\{CLAUDE_PLUGIN_ROOT\}/);
    assert.ok(command.includes('/scripts/hq-claude-plugin-launch.sh'));
    const rel = command.match(/\$\{CLAUDE_PLUGIN_ROOT\}\/([^" ]+)/)[1];
    assert.ok(fs.existsSync(path.join(plugin, rel)), `missing target ${rel}`);
  }
}
const mcp = JSON.parse(fs.readFileSync(path.join(plugin, '.mcp.json'), 'utf8'));
assert.deepEqual(mcp.mcpServers.hq.command, '/bin/sh');
assert.deepEqual(mcp.mcpServers.hq.args.slice(1), ['mcp', 'serve']);
assert.match(mcp.mcpServers.hq.args[0], /^\$\{CLAUDE_PLUGIN_ROOT\}\/scripts\/hq-claude-plugin-launch\.sh$/);
assert.ok(fs.existsSync(path.join(plugin, 'skills')));
assert.ok(fs.existsSync(path.join(plugin, 'scripts/hq/hq-anywhere-runtime-flag.cjs')));
NODE

while IFS= read -r skill_file; do
  if bash "$filter" "$skill_file"; then
    echo "plugin contains an unshipped HQ-root path: $skill_file" >&2
    exit 1
  fi
done < <(find "$plugin/skills" -name SKILL.md -type f)

for skill in architect recover-session quality-gate; do
  test -f "$plugin/skills/$skill/SKILL.md" || { echo "portable skill missing from plugin: $skill" >&2; exit 1; }
done
for skill in garden commit-main; do
  test ! -e "$plugin/skills/$skill" || { echo "HQ-root-dependent skill unexpectedly bundled: $skill" >&2; exit 1; }
done

toolchain="$tmp/toolchain"
empty_path="$tmp/empty-path"
mkdir -p "$toolchain/node/bin" "$toolchain/npm-global/bin" "$empty_path"
cat > "$toolchain/node/bin/node" <<'NODE'
#!/bin/sh
printf 'node found via plugin resolver\n' > "$NODE_MARKER"
printf 'false\n'
NODE
cat > "$toolchain/npm-global/bin/hq" <<'HQ'
#!/bin/sh
printf '%s\n' "$*" > "$HQ_MARKER"
HQ
chmod +x "$toolchain/node/bin/node" "$toolchain/npm-global/bin/hq"
NODE_MARKER="$tmp/node.marker" HQ_TOOLCHAIN_DIR="$toolchain" HOME="$tmp/home" PATH="$empty_path" \
  /bin/sh "$plugin/scripts/hq-claude-plugin-launch.sh" hook SessionStart --runtime claude <<<'{}'
grep -q 'node found via plugin resolver' "$tmp/node.marker"
HQ_MARKER="$tmp/hq.marker" HQ_TOOLCHAIN_DIR="$toolchain" HOME="$tmp/home" PATH="$empty_path" \
  /bin/sh "$plugin/scripts/hq-claude-plugin-launch.sh" mcp serve
grep -qx 'mcp serve' "$tmp/hq.marker"

bash "$repo_root/core/scripts/build-claude-marketplace.sh" "$plugin" "$marketplace"
node - "$marketplace" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = process.argv[2];
const data = JSON.parse(fs.readFileSync(path.join(root, '.claude-plugin/marketplace.json'), 'utf8'));
assert.equal(data.plugins[0].name, 'hq');
assert.equal(data.plugins[0].source, './plugins/hq');
assert.ok(fs.existsSync(path.join(root, 'plugins/hq/.claude-plugin/plugin.json')));
NODE

nested_plugin="$marketplace/plugins/hq/nested-input"
mkdir -p "$nested_plugin"
printf 'preserve input\n' > "$nested_plugin/marker"
if bash "$repo_root/core/scripts/build-claude-marketplace.sh" "$nested_plugin" "$marketplace" >"$tmp/overlap.out" 2>&1; then
  echo 'marketplace builder accepted an input nested inside its deletion target' >&2
  exit 1
fi
grep -q 'plugin input must not be the marketplace target or inside it' "$tmp/overlap.out"
test -f "$nested_plugin/marker"

echo 'Claude plugin build and marketplace regression checks passed.'
