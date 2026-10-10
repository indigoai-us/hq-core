#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
if [[ $# -ne 1 ]]; then
  echo "usage: build-claude-plugin.sh <output-plugin-directory>" >&2
  exit 2
fi
output=$(mkdir -p "$1" && cd "$1" && pwd)
source="$repo_root/core/plugin/claude"
skill_path_filter="$repo_root/core/scripts/lib/skill-has-unshipped-hq-path.sh"

rm -rf "$output/.claude-plugin" "$output/hooks" "$output/skills" "$output/scripts" "$output/.mcp.json"
mkdir -p "$output/.claude-plugin" "$output/hooks" "$output/skills" "$output/scripts/hq"
install -m 0644 "$source/plugin.json" "$output/.claude-plugin/plugin.json"
while IFS= read -r skill_dir; do
  skill_file="$skill_dir/SKILL.md"
  [[ -f "$skill_file" ]] || continue
  # Plugin skills run from the consumer's repository. Omit only paths rooted
  # in the HQ checkout that are not shipped in the plugin.
  if bash "$skill_path_filter" "$skill_file"; then
    continue
  fi
  cp -R "$skill_dir" "$output/skills/"
done < <(find "$repo_root/.claude/skills" -mindepth 1 -maxdepth 1 -type d -print | sort)
for file in hqd-hook-shim.sh hqd-hook-flag-cache-lib.sh hq-anywhere-runtime-flag.cjs; do
  install -m 0755 "$repo_root/core/scripts/$file" "$output/scripts/hq/$file"
done
install -m 0755 "$repo_root/core/scripts/hq-claude-plugin-launch.sh" "$output/scripts/hq-claude-plugin-launch.sh"

node - "$output" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
const events = ['PreToolUse','PostToolUse','PreCompact','Stop','SessionStart','UserPromptSubmit','Notification','SubagentStart','SubagentStop','SessionEnd'];
const hooks = Object.fromEntries(events.map(event => [event, [{ hooks: [{
  type: 'command',
  command: `"\u0024{CLAUDE_PLUGIN_ROOT}/scripts/hq-claude-plugin-launch.sh" hook ${event} --runtime claude`,
  timeout: 300,
}] }]]));
fs.writeFileSync(path.join(root, 'hooks/hooks.json'), `${JSON.stringify({ hooks }, null, 2)}\n`);
fs.writeFileSync(path.join(root, '.mcp.json'), `${JSON.stringify({ mcpServers: { hq: { command: '/bin/sh', args: ['\u0024{CLAUDE_PLUGIN_ROOT}/scripts/hq-claude-plugin-launch.sh', 'mcp', 'serve'] } } }, null, 2)}\n`);
NODE

echo "Built Claude Code plugin at $output"
