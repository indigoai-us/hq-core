#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pack="$tmp/pack"

if bash "$repo_root/core/scripts/build-codex-pack.sh" "$repo_root/core/plugin" >"$tmp/source-output.out" 2>&1; then
  echo 'builder accepted an output directory that contains its source package' >&2
  exit 1
fi
grep -q 'output directory must not contain the Codex pack source' "$tmp/source-output.out"
test -f "$repo_root/core/plugin/codex/package.yaml"

unmarked="$tmp/unmarked"
mkdir -p "$unmarked"
printf '%s\n' 'keep this user file' > "$unmarked/keep.txt"
if bash "$repo_root/core/scripts/build-codex-pack.sh" "$unmarked" >"$tmp/unmarked.out" 2>&1; then
  echo 'builder accepted a non-empty output directory without its marker' >&2
  exit 1
fi
grep -q 'refusing to clean non-empty output without a valid .hq-codex-pack-build marker' "$tmp/unmarked.out"
grep -q 'keep this user file' "$unmarked/keep.txt"

bash "$repo_root/core/scripts/build-codex-pack.sh" "$pack"
node "$repo_root/core/scripts/validate-agent-runtime-contracts.mjs" --root "$repo_root" --skill-dir "$pack"
test -f "$pack/.hq-codex-pack-build"
test ! -e "$pack/scripts/hq"

mkdir -p "$tmp/malformed/skills/missing-metadata" "$tmp/no-skills"
if node "$repo_root/core/scripts/validate-agent-runtime-contracts.mjs" --root "$repo_root" --skill-dir "$tmp/no-skills" >"$tmp/no-skills.out" 2>&1; then
  echo 'validator accepted an external payload without a skills directory' >&2
  exit 1
fi
grep -q 'must contain a skills/ directory' "$tmp/no-skills.out"
if node "$repo_root/core/scripts/validate-agent-runtime-contracts.mjs" --root "$repo_root" --skill-dir "$tmp/malformed" >"$tmp/malformed.out" 2>&1; then
  echo 'validator accepted an external skill missing SKILL.md' >&2
  exit 1
fi
grep -q 'missing SKILL.md' "$tmp/malformed.out"

node - "$pack" "$repo_root" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const [pack, repo] = process.argv.slice(2);
const manifest = fs.readFileSync(path.join(pack, 'package.yaml'), 'utf8');
assert.match(manifest, /^name: hq-anywhere$/m);
for (const contribution of ['skills:', 'hooks:', 'mcp:']) assert.ok(manifest.includes(contribution));
assert.match(manifest, /- codex/);
assert.match(manifest, /- hq-anywhere/);

const hookFile = path.join(pack, 'hooks/codex.sh');
const shimFile = path.join(pack, 'hooks/codex-hook-shim.sh');
assert.ok(fs.statSync(hookFile).mode & 0o111, 'installer-visible Codex hook entry point is executable');
const hookSource = fs.readFileSync(hookFile, 'utf8');
assert.match(hookSource, /exec \/bin\/sh "\$hook_dir\/codex-hook-shim\.sh" --runtime codex/u);
const shimSource = fs.readFileSync(shimFile, 'utf8');
assert.equal(shimSource, fs.readFileSync(path.join(repo, 'core/scripts/hqd-hook-shim.sh'), 'utf8'), 'pack uses the shared flag-aware shim');

const hooks = JSON.parse(fs.readFileSync(path.join(pack, 'hooks/codex-hooks.json'), 'utf8')).hooks;
for (const event of ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop', 'SessionEnd']) {
  const registrations = hooks[event].flatMap(group => group.hooks);
  assert.equal(registrations.length, 1, `one ${event} registration`);
  assert.equal(registrations[0].timeout, event === 'SessionEnd' ? 3 : 300, `${event} timeout matches Codex`);
  const target = path.resolve(pack, registrations[0].command);
  assert.equal(registrations[0].command, 'hooks/codex.sh');
  assert.equal(target, hookFile);
  assert.ok(fs.existsSync(target), `${event} hook target exists`);
}

const mcp = JSON.parse(fs.readFileSync(path.join(pack, 'mcp/hq-anywhere.json'), 'utf8'));
assert.equal(mcp.type, 'stdio');
assert.equal(mcp.command, 'hq');
assert.deepEqual(mcp.args, ['mcp', 'serve']);
for (const helper of ['hqd-hook-flag-cache-lib.sh', 'hq-anywhere-runtime-flag.cjs']) {
  assert.ok(fs.existsSync(path.join(pack, 'hooks', helper)), `missing flag-aware shim dependency ${helper}`);
}

const sourceSkills = fs.readdirSync(path.join(repo, '.claude/skills'), { withFileTypes: true })
  .filter(entry => entry.isDirectory()).map(entry => entry.name);
const builtSkills = fs.readdirSync(path.join(pack, 'skills'));
assert.ok(builtSkills.length > 0, 'at least one portable skill is packaged');
for (const skill of builtSkills) {
  const agentYaml = path.join(pack, 'skills', skill, 'agents/openai.yaml');
  if (!fs.existsSync(agentYaml)) continue;
  const yaml = fs.readFileSync(agentYaml, 'utf8');
  const lines = yaml.split(/\r?\n/);
  const index = lines.findIndex(line => /^\s*short_description\s*:/u.test(line));
  assert.notEqual(index, -1, `${skill} Codex metadata declares interface.short_description`);
  const indent = lines[index].match(/^\s*/u)[0].length;
  const value = lines[index].replace(/^\s*short_description\s*:\s*/u, '').trim();
  const quoted = value.match(/^(?:"([^"]*)"|'([^']*)')$/u);
  let description = quoted ? (quoted[1] ?? quoted[2]) : value;
  if (!quoted && /^[>|][+-]?$/u.test(value)) {
    const folded = [];
    for (let i = index + 1; i < lines.length; i++) {
      if (!lines[i].trim()) continue;
      if (lines[i].match(/^\s*/u)[0].length <= indent) break;
      folded.push(lines[i].trim());
    }
    description = folded.join(' ').replace(/\s+/gu, ' ').trim();
  }
  const length = [...description].length;
  assert.ok(length >= 25 && length <= 64,
    `${skill} Codex interface.short_description is ${length} characters (expected 25-64)`);
}
const declaredSkills = manifest.match(/  skills:\n([\s\S]*?)\n  hooks:/)?.[1]
  .split('\n').map(line => line.trim().replace(/^-\s+/, '')).filter(Boolean) ?? [];
assert.deepEqual(declaredSkills.sort(), [...builtSkills].sort(), 'manifest exactly declares packaged skills');
for (const skill of builtSkills) assert.ok(sourceSkills.includes(skill), `${skill} came from source skills`);
for (const skill of ['architect', 'recover-session', 'quality-gate']) {
  assert.ok(builtSkills.includes(skill), `${skill} is portable and packaged`);
}
assert.ok(!builtSkills.includes('garden'), 'garden requires workers not bundled in the pack');
assert.ok(!builtSkills.includes('commit-main'), 'commit-main reads a checkout command not bundled in the pack');
NODE

while IFS= read -r skill_file; do
  if bash "$repo_root/core/scripts/lib/skill-has-unshipped-hq-path.sh" "$skill_file"; then
    skill=${skill_file%/SKILL.md}
    skill=${skill##*/}
    test ! -e "$pack/skills/$skill" || { echo "Codex pack contains an unshipped HQ-root path: $skill" >&2; exit 1; }
  fi
done < <(find "$repo_root/.claude/skills" -mindepth 2 -maxdepth 2 -name SKILL.md -type f | sort)

mkdir -p "$tmp/home/.hq/packs"
installed="$tmp/home/.hq/packs/hq-anywhere"
mkdir -p "$installed"
cp -R "$pack/." "$installed/"
test -f "$installed/package.yaml"
test -d "$installed/skills"
test -f "$installed/hooks/codex-hooks.json"
test -f "$installed/hooks/codex.sh" || { echo 'builder omitted declared hook payload hooks/codex.sh' >&2; exit 1; }
hook_command=$(node -e 'process.stdout.write(JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).hooks.SessionStart[0].hooks[0].command)' "$installed/hooks/codex-hooks.json")
test "$hook_command" = 'hooks/codex.sh' || { echo "Codex hook config must run hooks/codex.sh, got $hook_command" >&2; exit 1; }
hook_target=$(realpath "$installed/$hook_command")
test "$hook_target" = "$installed/hooks/codex.sh"
test -x "$hook_target"

printf '%s\n' '{"hook_event_name":"SessionStart","cwd":"/tmp/foreign-repo"}' |
  env -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID -u HQ_TEST_FLAG HOME="$tmp/home" /bin/sh "$hook_target" >"$tmp/flag-off.out"
test ! -s "$tmp/flag-off.out"

export HQ_COMPANY_UID=cmp_123456
cache_timestamp=$(. "$repo_root/core/scripts/hqd-hook-flag-cache-lib.sh"; now_seconds)
mkdir -p "$tmp/home/.hq"
printf 'true %s\n' "$cache_timestamp" > "$tmp/home/.hq/hq-anywhere-runtime.flag.cmp_123456"
chmod 600 "$tmp/home/.hq/hq-anywhere-runtime.flag.cmp_123456"
server_socket="$tmp/home/.hq/hqd.sock"
server_trace="$tmp/server-request.json"
node - "$hook_target" "$tmp/home" "$server_socket" "$server_trace" <<'NODE'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const net = require('node:net');
const { spawn } = require('node:child_process');
const [hook, home, socketPath, tracePath] = process.argv.slice(2);
const server = net.createServer((connection) => {
  let requestText = '';
  let replied = false;
  connection.setEncoding('utf8');
  connection.on('data', (chunk) => {
    requestText += chunk;
    if (replied || !requestText.includes('\n')) return;
    replied = true;
    fs.writeFileSync(tracePath, requestText);
    connection.end('{"ok":true,"result":{"decision":"allow"}}\n');
  });
});
server.listen(socketPath, () => {
  const child = spawn('/bin/sh', [hook], {
    env: { ...process.env, HOME: home, HQ_HQD_SOCKET: socketPath, HQ_HQD_SHIM_TIMEOUT_MS: '5000', HQ_HQD_SHIM_REPORT_UNREACHABLE: '1' },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8').on('data', (chunk) => { stdout += chunk; });
  child.stderr.setEncoding('utf8').on('data', (chunk) => { stderr += chunk; });
  child.stdin.end('{"hook_event_name":"PreToolUse","session_id":"pack-install-test","cwd":"/tmp/foreign-repo","tool_name":"Read","tool_input":{"file_path":"/tmp/foreign-repo/README.md"}}\n');
  const timeout = setTimeout(() => child.kill('SIGKILL'), 5000);
  child.on('close', (code) => {
    clearTimeout(timeout);
    try {
      assert.ok(fs.existsSync(tracePath), `installed Codex hook contacted the daemon (stderr: ${stderr}, code: ${code})`);
      assert.equal(code, 0, `installed Codex hook exited successfully (stderr: ${stderr})`);
      assert.equal(stdout, '');
      const request = JSON.parse(fs.readFileSync(tracePath, 'utf8'));
      assert.equal(request.op, 'policy.check', 'Codex PreToolUse reaches the daemon policy operation');
      assert.equal(request.args.runtime, 'codex', 'the directly installed pack hook identifies the Codex runtime');
      assert.equal(request.args.sessionId, 'pack-install-test');
    } catch (error) {
      console.error(error);
      process.exitCode = 1;
    } finally {
      server.close();
    }
  });
});
NODE

mkdir -p "$pack/workers/stale"
printf '%s\n' 'stale build output' > "$pack/workers/stale/worker.yaml"
printf '%s\n' 'stale hidden file' > "$pack/.stale"
bash "$repo_root/core/scripts/build-codex-pack.sh" "$pack"
test ! -e "$pack/workers"
test ! -e "$pack/.stale"
test -f "$pack/.hq-codex-pack-build"

echo 'Codex pack build regression checks passed.'
