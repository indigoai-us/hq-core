#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { performance } from 'node:perf_hooks';

const rootNative = process.cwd();
const rootPosixResult = spawnSync('bash', ['-c', 'pwd -P'], { cwd: rootNative, encoding: 'utf8' });
if (rootPosixResult.status !== 0) throw new Error(`cannot resolve repo root: ${rootPosixResult.stderr}`);
const rootPosix = rootPosixResult.stdout.trim();
const runId = `resumework-lock-scale-${Date.now()}`;
const threadId = `T-${runId}`;
const sampleCount = 3;
const sizes = [6000, 18000];
const fixtureRoot = path.join(rootNative, 'workspace/threads/archive', runId);
const projectRoot = path.join(rootNative, 'companies/indigo/projects', runId);
const companyKnowledgeRoot = path.join(rootNative, 'companies/indigo/knowledge', runId);
const coreKnowledgeRoot = path.join(rootNative, 'core/knowledge/public', runId);
const policyPrefix = `${runId}-`;
const generatedPolicies = [];
const generatedDirs = [fixtureRoot, projectRoot, companyKnowledgeRoot, coreKnowledgeRoot, path.join(rootNative, 'workspace/sessions/archive', runId)];
const runnerTemp = process.env.RUNNER_TEMP || os.tmpdir();
const timingsFile = path.join(runnerTemp, `${runId}-open-steps-ms.txt`);
const statTraceFile = path.join(runnerTemp, `${runId}-stat-call-us.txt`);
const bashEnvFile = path.join(runnerTemp, `${runId}-bash-env.sh`);
fs.writeFileSync(bashEnvFile, [
  'stat() {',
  '  if [[ "${RESUMEWORK_TRACE_OPEN_STEPS:-}" == "1" && -n "${RESUMEWORK_STAT_TRACE:-}" ]]; then',
  '    local started="${EPOCHREALTIME/./}"',
  '    command stat "$@"',
  '    local result=$?',
  '    local ended="${EPOCHREALTIME/./}"',
  '    printf "%s\\n" "$((ended - started))" >> "$RESUMEWORK_STAT_TRACE"',
  '    return "$result"',
  '  fi',
  '  command stat "$@"',
  '}',
].join('\n') + '\n', 'utf8');

function fail(message) { throw new Error(message); }
function percentile(values, p) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(sorted.length * p) - 1)];
}
function childEnv(extra = {}) {
  const env = {};
  for (const key of ['PATH', 'PATHEXT', 'SYSTEMROOT', 'WINDIR', 'TMP', 'TEMP', 'TMPDIR', 'RUNNER_TEMP', 'RUNNER_OS', 'RUNNER_ARCH', 'MSYSTEM', 'CI', 'HQ_NO_UPDATE_CHECK']) {
    if (process.env[key] !== undefined) env[key] = process.env[key];
  }
  return { ...env, HQ_ROOT: rootPosix, CLAUDE_PROJECT_DIR: rootPosix, CLAUDE_CODE_SESSION_ID: runId, HQ_HOOK_TIMEOUT_SENTRY: '0', HOME: process.env.HOME, ...extra };
}
function write(file, content) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content, 'utf8');
}
function counts(total) {
  const scale = total / 6000;
  return {
    threads: 2400 * scale,
    projects: 1500 * scale,
    companyKnowledge: 500 * scale,
    coreKnowledge: 500 * scale,
    policies: 178 * scale,
    sessions: 922 * scale,
  };
}
function buildFixture(total) {
  const c = counts(total);
  const started = performance.now();
  for (let i = 0; i < c.threads; i += 1) {
    const fileName = i === 0 ? `${threadId}.json` : `T-scale-${String(i).padStart(5, '0')}.json`;
    const base = i === 0 ? path.join(rootNative, 'workspace/threads') : fixtureRoot;
    write(path.join(base, fileName), JSON.stringify({ thread_id: fileName.slice(0, -5), metadata: { title: 'Synthetic scale fixture' }, next_steps: [] }));
  }
  for (let i = 0; i < c.projects; i += 1) write(path.join(projectRoot, `project-${String(Math.floor(i / 10)).padStart(4, '0')}`, `document-${String(i % 10).padStart(2, '0')}.md`), '# Synthetic project fixture\n');
  for (let i = 0; i < c.companyKnowledge; i += 1) write(path.join(companyKnowledgeRoot, `knowledge-${String(i).padStart(4, '0')}.md`), '# Synthetic company knowledge\n');
  for (let i = 0; i < c.coreKnowledge; i += 1) write(path.join(coreKnowledgeRoot, `knowledge-${String(i).padStart(4, '0')}.md`), '# Synthetic core knowledge\n');
  for (let i = 0; i < c.policies; i += 1) {
    const file = path.join(rootNative, 'core/policies', `${policyPrefix}${String(i).padStart(4, '0')}.md`);
    write(file, `---\nid: ${policyPrefix}${i}\ntitle: "Synthetic scale policy"\nscope: global\nwhen: always\nenforcement: soft\n---\nFixture only.\n`);
    generatedPolicies.push(file);
  }
  const sessionRoot = path.join(rootNative, 'workspace/sessions/archive', runId);
  for (let i = 0; i < c.sessions; i += 1) write(path.join(sessionRoot, `session-${String(i).padStart(4, '0')}.yaml`), `session_id: synthetic-${i}\ncompany_slug: indigo\n`);
  return Math.round(performance.now() - started);
}
function shellLockCommand() {
  const skillPath = path.join(rootNative, '.claude/skills/resumework/SKILL.md');
  const skill = fs.readFileSync(skillPath, 'utf8');
  const blocks = [...skill.matchAll(/```bash\r?\n([\s\S]*?)```/g)].map((match) => match[1]);
  let block = blocks.find((candidate) => candidate.includes('thread_file="<resolved-thread-file>"'));
  if (!block) fail('could not extract the resumework lock-inspect/open-steps block');
  block = block.replace('thread_file="<resolved-thread-file>"', 'thread_file="$ROOT/workspace/threads/$RESUMEWORK_THREAD_ID.json"');
  const command = 'bash core/scripts/handoff-open-steps.sh list --limit 10';
  const instrumented = `export RESUMEWORK_TRACE_OPEN_STEPS=1\n__open_start="$(perl -MTime::HiRes=time -e 'printf("%d\\n", time()*1000)')"\n${command}\n__open_end="$(perl -MTime::HiRes=time -e 'printf("%d\\n", time()*1000)')"\nprintf '%s\\n' "$((__open_end - __open_start))" >> "$RESUMEWORK_OPEN_STEPS_TIMINGS"\nunset RESUMEWORK_TRACE_OPEN_STEPS`;
  if (!block.includes(command)) fail('lock block did not contain the measured open-steps call');
  return block.replace(command, instrumented);
}
function runCommand(command, env) {
  const started = performance.now();
  const result = spawnSync('bash', ['-c', command], { cwd: rootNative, encoding: 'utf8', env: childEnv(env), timeout: 35 * 60 * 1000, maxBuffer: 4 * 1024 * 1024 });
  const elapsed = Math.round(performance.now() - started);
  if (result.error) fail(`lock step failed to run: ${result.error.message}`);
  if (result.status !== 0) fail(`lock step exited ${result.status}: ${result.stderr}`);
  return elapsed;
}

try {
  if (generatedDirs.some((dir) => fs.existsSync(dir))) fail('refusing to overwrite an existing scale fixture path');
  if (fs.existsSync(path.join(rootNative, 'workspace/threads', `${threadId}.json`))) fail('target thread already exists');
  process.stdout.write(`resumework lock scale run=${runId} samples=${sampleCount}\n`);
  for (const total of sizes) {
    const buildMs = buildFixture(total);
    const expectedThreads = counts(total).threads;
    const commandSamples = [];
    const openStepsSamples = [];
    const statCallsSamples = [];
    const statElapsedSamples = [];
    fs.writeFileSync(timingsFile, '', 'utf8');
    const command = shellLockCommand();
    for (let i = 0; i < sampleCount; i += 1) {
      const elapsed = runCommand(command, {
        RESUMEWORK_THREAD_ID: threadId,
        RESUMEWORK_OPEN_STEPS_TIMINGS: timingsFile,
        RESUMEWORK_STAT_TRACE: statTraceFile,
        RESUMEWORK_SESSION_ID: runId,
        BASH_ENV: bashEnvFile,
      });
      commandSamples.push(elapsed);
      const timings = fs.readFileSync(timingsFile, 'utf8').trim().split(/\r?\n/).filter(Boolean).map(Number);
      if (timings.length !== i + 1) fail(`open-steps instrumentation recorded ${timings.length} samples after ${i + 1} lock commands`);
      openStepsSamples.push(timings.at(-1));
      const statTimings = fs.readFileSync(statTraceFile, 'utf8').trim().split(/\r?\n/).filter(Boolean).map(Number);
      if (statTimings.length === 0 || statTimings.some((timing) => !Number.isFinite(timing))) fail('stat-call instrumentation recorded no valid samples');
      statCallsSamples.push(statTimings.length);
      statElapsedSamples.push(Math.round(statTimings.reduce((sum, timing) => sum + timing, 0) / 1000));
      fs.writeFileSync(statTraceFile, '', 'utf8');
      fs.rmSync(path.join(rootNative, 'workspace/threads/resume-locks', `${threadId}.lock`), { recursive: true, force: true });
    }
    process.stdout.write(`fixture generated_files=${total} thread_files=${expectedThreads} build_ms=${buildMs}\n`);
    process.stdout.write(`scale lock_inspect_acquire_open_steps files=${total} thread_files=${expectedThreads} samples=${sampleCount} command_p50_ms=${percentile(commandSamples, 0.5)} command_p95_ms=${percentile(commandSamples, 0.95)} open_steps_p50_ms=${percentile(openStepsSamples, 0.5)} open_steps_p95_ms=${percentile(openStepsSamples, 0.95)} stat_calls_p50=${percentile(statCallsSamples, 0.5)} stat_call_elapsed_p50_ms=${percentile(statElapsedSamples, 0.5)} stat_call_elapsed_p95_ms=${percentile(statElapsedSamples, 0.95)}\n`);
    for (const file of generatedPolicies) fs.rmSync(file, { force: true });
    generatedPolicies.length = 0;
    for (const dir of generatedDirs) fs.rmSync(dir, { recursive: true, force: true });
  }
} finally {
  fs.rmSync(path.join(rootNative, 'workspace/threads/resume-locks', `${threadId}.lock`), { recursive: true, force: true });
  fs.rmSync(path.join(rootNative, 'workspace/threads', `${threadId}.json`), { force: true });
  for (const file of generatedPolicies) fs.rmSync(file, { force: true });
  for (const dir of generatedDirs) fs.rmSync(dir, { recursive: true, force: true });
  fs.rmSync(timingsFile, { force: true });
}
