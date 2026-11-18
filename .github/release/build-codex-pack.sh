#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
if [[ $# -ne 1 ]]; then
  echo "usage: build-codex-pack.sh <output-pack-directory>" >&2
  exit 2
fi
output=$(mkdir -p "$1" && cd "$1" && pwd -P)
source="$repo_root/core/plugin/codex"
skill_path_filter="$repo_root/core/scripts/lib/skill-has-unshipped-hq-path.sh"

node - "$output" "$source" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [output, source] = process.argv.slice(2);
if (source === output || source.startsWith(`${output}${path.sep}`)) {
  throw new Error('output directory must not contain the Codex pack source');
}
const markerName = '.hq-codex-pack-build';
const markerPath = path.join(output, markerName);
const markerContents = 'hq-anywhere Codex pack build directory v1\n';
const entries = fs.readdirSync(output);
if (entries.length > 0) {
  let ownsOutput = false;
  try {
    const markerStat = fs.lstatSync(markerPath);
    ownsOutput = markerStat.isFile()
      && !markerStat.isSymbolicLink()
      && fs.readFileSync(markerPath, 'utf8') === markerContents;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  if (!ownsOutput) {
    throw new Error(`refusing to clean non-empty output without a valid ${markerName} marker`);
  }
}
for (const entry of fs.readdirSync(output)) {
  fs.rmSync(path.join(output, entry), { recursive: true, force: true });
}
fs.writeFileSync(markerPath, markerContents, { mode: 0o644 });
NODE

mkdir -p "$output/skills" "$output/hooks" "$output/mcp"
install -m 0644 "$source/package.yaml" "$output/package.yaml"

# Codex skills execute from the consumer repository. Match the Claude plugin
# filter: omit skills that still depend on HQ checkout paths.
while IFS= read -r skill_dir; do
  skill_file="$skill_dir/SKILL.md"
  [[ -f "$skill_file" ]] || continue
  if bash "$skill_path_filter" "$skill_file"; then
    continue
  fi
  cp -R "$skill_dir" "$output/skills/"
done < <(find "$repo_root/.claude/skills" -mindepth 1 -maxdepth 1 -type d -print | sort)

node - "$output/skills" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const skillsRoot = process.argv[2];
function shortDescription(yaml) {
  const lines = yaml.split(/\r?\n/);
  const index = lines.findIndex(line => /^\s*short_description\s*:/u.test(line));
  if (index < 0) return null;
  const indent = lines[index].match(/^\s*/u)[0].length;
  const value = lines[index].replace(/^\s*short_description\s*:\s*/u, '').trim();
  const quoted = value.match(/^(?:"([^"]*)"|'([^']*)')$/u);
  if (quoted) return quoted[1] ?? quoted[2];
  if (/^[>|][+-]?$/u.test(value)) {
    const folded = [];
    for (let i = index + 1; i < lines.length; i++) {
      if (!lines[i].trim()) continue;
      if (lines[i].match(/^\s*/u)[0].length <= indent) break;
      folded.push(lines[i].trim());
    }
    return folded.join(' ').replace(/\s+/gu, ' ').trim();
  }
  return value;
}
for (const skill of fs.readdirSync(skillsRoot, { withFileTypes: true }).filter(entry => entry.isDirectory())) {
  const metadata = path.join(skillsRoot, skill.name, 'agents/openai.yaml');
  if (!fs.existsSync(metadata)) continue;
  const yaml = fs.readFileSync(metadata, 'utf8');
  const description = shortDescription(yaml);
  if (description === null) throw new Error(`${skill.name}: missing interface.short_description in agents/openai.yaml`);
  const length = [...description].length;
  if (length < 25 || length > 64) {
    throw new Error(`${skill.name}: interface.short_description is ${length} characters; expected 25-64`);
  }
}
NODE

for file in hqd-hook-flag-cache-lib.sh hq-anywhere-runtime-flag.cjs; do
  install -m 0755 "$repo_root/core/scripts/$file" "$output/hooks/$file"
done
install -m 0755 "$repo_root/core/scripts/hqd-hook-shim.sh" "$output/hooks/codex-hook-shim.sh"
cat > "$output/hooks/codex.sh" <<'HOOK'
#!/bin/sh
# Installer-visible Codex hook entry point. Keep gate and dispatch behavior in the shared shim.
case "$0" in
  */*) hook_dir=${0%/*} ;;
  *) hook_dir=. ;;
esac
exec /bin/sh "$hook_dir/codex-hook-shim.sh" --runtime codex "$@"
HOOK
chmod 0755 "$output/hooks/codex.sh"

node - "$output" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
const events = ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop', 'SessionEnd'];
const hooks = Object.fromEntries(events.map(event => [event, [{ hooks: [{
  type: 'command',
  command: 'hooks/codex.sh',
  timeout: event === 'SessionEnd' ? 3 : 300,
}] }]]));
fs.writeFileSync(path.join(root, 'hooks/codex-hooks.json'), `${JSON.stringify({ hooks }, null, 2)}\n`);
fs.writeFileSync(path.join(root, 'mcp/hq-anywhere.json'), `${JSON.stringify({
  type: 'stdio',
  command: 'hq',
  args: ['mcp', 'serve'],
}, null, 2)}\n`);
NODE

echo "Built Codex pack at $output"
