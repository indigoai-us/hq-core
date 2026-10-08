#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { performance } from 'node:perf_hooks';
import { createHash } from 'node:crypto';

const rootNative = process.cwd();
const runId = `resumework-benchmark-${Date.now()}`;
const threadDir = path.join(rootNative, 'workspace/threads/archive', runId);
const projectDir = path.join(rootNative, 'companies/indigo/projects', runId);
const crossCompanyProbeDir = path.join(rootNative, 'companies/companyx');
const companyKnowledgeDir = path.join(rootNative, 'companies/indigo/knowledge', runId);
const coreKnowledgeDir = path.join(rootNative, 'core/knowledge/public', runId);
const sessionDataDir = path.join(rootNative, 'workspace/sessions/archive', runId);
const runtimeSessionDir = path.join(rootNative, 'workspace/sessions', runId);
const policyPrefix = `${runId}-`;
const generatedPolicyFiles = [];
const generatedDirectories = [threadDir, projectDir, companyKnowledgeDir, coreKnowledgeDir, sessionDataDir, crossCompanyProbeDir];
// Twenty Windows samples exceeded the hosted job limit; five still supports p50/p95.
const sampleCount = 5;
const expectedGeneratedFileCount = 6000;
const policyFileCount = 178;
const policyBytes = 7000;
const threadId = 'T-20261008-resumework-benchmark-target';

function fail(message) {
  throw new Error(message);
}

function childEnv(extra = {}) {
  const env = {};
  for (const key of ['PATH', 'PATHEXT', 'SYSTEMROOT', 'WINDIR', 'TMP', 'TEMP', 'TMPDIR', 'RUNNER_TEMP', 'RUNNER_OS', 'RUNNER_ARCH', 'MSYSTEM', 'CI', 'HQ_NO_UPDATE_CHECK']) {
    if (process.env[key] !== undefined) env[key] = process.env[key];
  }
  env.HQ_ROOT = rootPosix;
  env.CLAUDE_PROJECT_DIR = rootPosix;
  env.CLAUDE_CODE_SESSION_ID = runId;
  env.HQ_HOOK_TIMEOUT_SENTRY = '0';
  if (process.env.RESUMEWORK_BENCHMARK_ALLOW_HQ_WORKTREE === '1') env.HQ_ALLOW_HQ_WORKTREE = '1';
  env.HQ_HOOK_TRACE = '1';
  env.HOME = homePosix;
  return { ...env, ...extra };
}

function runBash(args, { input, env = {}, timeout = 60000, capture = true } = {}) {
  const result = spawnSync('bash', args, {
    cwd: rootNative,
    input,
    encoding: 'utf8',
    env: childEnv(env),
    timeout,
    maxBuffer: 12 * 1024 * 1024,
  });
  if (result.error) fail(`bash ${args.join(' ')} could not run: ${result.error.message}`);
  const stdout = result.stdout ?? '';
  const stderr = result.stderr ?? '';
  if (!capture && stdout) process.stdout.write(stdout);
  return { status: result.status, stdout, stderr };
}

function runBashStreaming(args, { env = {}, timeout = 60000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn('bash', args, {
      cwd: rootNative,
      env: childEnv(env),
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout,
      killSignal: 'SIGTERM',
    });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      process.stdout.write(chunk);
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
      process.stderr.write(chunk);
    });
    child.on('error', (error) => reject(new Error(`bash ${args.join(' ')} could not run: ${error.message}`)));
    child.on('close', (status) => resolve({ status: status ?? 1, stdout, stderr }));
  });
}

function measure(fn) {
  const start = performance.now();
  const value = fn();
  return { ms: Math.max(0, Math.round(performance.now() - start)), value };
}

function percentile(values, p) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(sorted.length * p) - 1)];
}

function emitPhase(name, values, details = '') {
  const line = `phase=${name} p50_ms=${percentile(values, 0.5)} p95_ms=${percentile(values, 0.95)}${details ? ` ${details}` : ''}`;
  phaseLines.push(line);
}

function ensureAbsent(target) {
  if (fs.existsSync(target)) fail(`refusing to overwrite existing fixture path: ${target}`);
}

function writeCounted(file, content) {
  ensureAbsent(file);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content, 'utf8');
  generatedFiles.push(file);
}

function makePolicy(index) {
  const id = String(index).padStart(4, '0');
  const frontmatter = [
    '---',
    `id: ${policyPrefix}${id}`,
    `title: "Resumework benchmark fixture ${id}"`,
    'scope: global',
    'when: always',
    'on: [SessionStart]',
    'enforcement: soft',
    '---',
    '',
    'Synthetic benchmark policy text. It contains no user, company, or reporter data.',
    '',
  ].join('\n');
  const bodyLine = 'This generated policy measures the real policy-loading path with stable fixture bytes.\n';
  let body = frontmatter;
  while (Buffer.byteLength(body) + Buffer.byteLength(bodyLine) <= policyBytes) body += bodyLine;
  body += 'x'.repeat(policyBytes - Buffer.byteLength(body));
  return body;
}

function buildFixture() {
  const started = performance.now();
  fs.mkdirSync(crossCompanyProbeDir, { recursive: true });
  for (let i = 0; i < 2400; i += 1) {
    const target = i === 2399;
    const name = target ? `${threadId}.json` : `T-benchmark-${String(i).padStart(5, '0')}.json`;
    const file = path.join(threadDir, `year-${String(i % 10).padStart(2, '0')}`, `month-${String(i % 12).padStart(2, '0')}`, `bucket-${String(i % 20).padStart(2, '0')}`, name);
    writeCounted(file, JSON.stringify({ metadata: { title: 'Benchmark handoff fixture' }, conversation_summary: 'Synthetic history for a resumework timing run.', next_steps: [], git: {}, files_touched: [] }));
  }
  for (let i = 0; i < 1500; i += 1) {
    const project = `project-${String(Math.floor(i / 10)).padStart(3, '0')}`;
    writeCounted(path.join(projectDir, project, `document-${String(i % 10).padStart(2, '0')}.md`), `# Synthetic project document ${i}\n\nBenchmark data only.\n`);
  }
  for (let i = 0; i < 500; i += 1) {
    writeCounted(path.join(companyKnowledgeDir, `knowledge-${String(i).padStart(3, '0')}.md`), `# Company knowledge fixture ${i}\n\nSynthetic HQ knowledge text.\n`);
    writeCounted(path.join(coreKnowledgeDir, `knowledge-${String(i).padStart(3, '0')}.md`), `# Core knowledge fixture ${i}\n\nSynthetic HQ knowledge text.\n`);
  }
  for (let i = 0; i < policyFileCount; i += 1) {
    const file = path.join(rootNative, 'core/policies', `${policyPrefix}${String(i).padStart(4, '0')}.md`);
    writeCounted(file, makePolicy(i));
    generatedPolicyFiles.push(file);
  }
  for (let i = 0; i < 922; i += 1) {
    writeCounted(path.join(sessionDataDir, `session-${String(i).padStart(3, '0')}.yaml`), `session_id: benchmark-${i}\ncompany_slug: indigo\n`);
  }
  const ms = Math.max(0, Math.round(performance.now() - started));
  if (generatedFiles.length !== expectedGeneratedFileCount) {
    fail(`fixture generator wrote ${generatedFiles.length} files; expected ${expectedGeneratedFileCount}`);
  }
  return ms;
}

function cleanup() {
  const sessionIds = [runId, ...Array.from({ length: sampleCount }, (_, i) => `${runId}-policy-${i}`)];
  for (const file of generatedPolicyFiles) fs.rmSync(file, { force: true });
  for (const dir of generatedDirectories) fs.rmSync(dir, { recursive: true, force: true });
  fs.rmSync(runtimeSessionDir, { recursive: true, force: true });
  for (const sessionId of sessionIds) {
    const sessionHash = createHash('sha256').update(`${sessionId}\0`).digest('hex');
    for (const file of [
      path.join(rootNative, 'workspace/orchestrator/policy-trigger-state', `${sessionId}.txt`),
      path.join(rootNative, 'workspace/orchestrator/policy-trigger-state', `${sessionId}.turn.txt`),
      path.join(rootNative, 'workspace/orchestrator/policy-emit-stats', `${sessionId}.txt`),
      path.join(rootNative, 'workspace/.hook-timeout-journal', `${sessionHash}.tsv`),
    ]) fs.rmSync(file, { force: true });
  }
  if (currentPointerExisted) fs.copyFileSync(currentBackup, currentPointer);
  else fs.rmSync(currentPointer, { force: true });
  fs.rmSync(homeNative, { recursive: true, force: true });
}

const generatedFiles = [];
const phaseLines = [];
const rootPosixResult = spawnSync('bash', ['-c', 'pwd -P'], { cwd: rootNative, encoding: 'utf8' });
if (rootPosixResult.status !== 0) fail(`cannot resolve the fixture root through Bash: ${rootPosixResult.stderr}`);
const rootPosix = rootPosixResult.stdout.trim();
const runnerTempNative = process.env.RUNNER_TEMP || os.tmpdir();
const homeNative = path.join(runnerTempNative, runId, 'home');
const cygpath = spawnSync('bash', ['-c', 'command -v cygpath >/dev/null 2>&1 && cygpath -u "$1" || printf "%s" "$1"', 'bash', homeNative], { encoding: 'utf8' });
if (cygpath.status !== 0) fail(`cannot resolve an isolated HOME: ${cygpath.stderr}`);
const homePosix = cygpath.stdout.trim();
fs.mkdirSync(homeNative, { recursive: true });
const currentPointer = path.join(rootNative, 'workspace/sessions/.current');
const currentBackup = path.join(homeNative, 'current-pointer-backup');
const currentPointerExisted = fs.existsSync(currentPointer);
if (currentPointerExisted) fs.copyFileSync(currentPointer, currentBackup);
for (const dir of generatedDirectories) {
  if (fs.existsSync(dir)) fail(`fixture directory already exists: ${dir}`);
}
if (fs.existsSync(runtimeSessionDir)) fail(`session path already exists: ${runtimeSessionDir}`);

try {
  process.stdout.write(`building ${expectedGeneratedFileCount}-file synthetic HQ fixture\n`);
  const buildMs = buildFixture();
  const countResult = spawnSync('bash', ['-c', "find . -type f -not -path './.git/*' -not -path './.git/**' | wc -l"], { cwd: rootNative, encoding: 'utf8', env: childEnv() });
  if (countResult.status !== 0) fail(`could not count fixture files: ${countResult.stderr}`);
  const totalTreeFiles = Number(countResult.stdout.trim());

  if (generatedFiles.length !== expectedGeneratedFileCount) fail('fixture file count changed during build');
  phaseLines.push(`fixture generated files=${generatedFiles.length} categories=threads:2400,projects:1500,company_knowledge:500,core_knowledge:500,policies:178,sessions:922 total_repo_tree_files=${totalTreeFiles} synthetic_policy_files=${policyFileCount} synthetic_policy_bytes=${policyFileCount * policyBytes}`);
  phaseLines.push(`phase=fixture_build elapsed_ms=${buildMs}`);

  const treeSamples = [];
  const scanSamples = [];
  const threadRootRelative = path.relative(rootNative, path.join(rootNative, 'workspace/threads')).split(path.sep).join('/');
  for (let i = 0; i < sampleCount; i += 1) {
    const tree = measure(() => runBash(['--noprofile', '--norc', '-c', 'find workspace/threads -type f -print >/dev/null'], { timeout: 30000 }));
    if (tree.value.status !== 0) fail(`tree walk failed: ${tree.value.stderr}`);
    treeSamples.push(tree.ms);
    const scan = measure(() => runBash(['--noprofile', '--norc', '-c', `find '${threadRootRelative}' -path '${threadRootRelative}/resume-locks' -prune -o -name '*.json' ! -name '*.changeset.json' -path '*${threadId}*' -print`], { timeout: 30000 }));
    if (scan.value.status !== 0 || scan.value.stdout.trim().split(/\r?\n/).filter(Boolean).length !== 1) {
      fail(`thread glob/scan did not resolve exactly one archived thread: ${scan.value.stderr || scan.value.stdout}`);
    }
    scanSamples.push(scan.ms);
  }
  emitPhase('tree_walk', treeSamples, 'files=2400');
  emitPhase('glob_scan', scanSamples, 'matches=1 target=archived_partial_id');

  process.stdout.write(`measuring policy loading against ${policyFileCount} generated 7 KB policies\n`);
  const bind = runBash(['core/scripts/hq-session.sh', 'set', 'company_slug', 'indigo'], { env: { CLAUDE_CODE_SESSION_ID: runId }, timeout: 30000 });
  if (bind.status !== 0) fail(`could not bind isolated fixture session: ${bind.stderr}`);
  const mode = runBash(['core/scripts/hq-session.sh', 'set', 'mode', 'Resume'], { env: { CLAUDE_CODE_SESSION_ID: runId }, timeout: 30000 });
  if (mode.status !== 0) fail(`could not set isolated fixture mode: ${mode.stderr}`);

  const policySamples = [];
  for (let i = 0; i < sampleCount; i += 1) {
    const policySessionId = `${runId}-policy-${i}`;
    const samplePayload = JSON.stringify({ hook_event_name: 'SessionStart', session_id: policySessionId, source: 'startup', cwd: rootPosix });
    const sample = measure(() => runBash([path.posix.join(rootPosix, '.claude/hooks/inject-policy-on-trigger.sh')], { input: samplePayload, timeout: 30000 }));
    if (sample.value.status !== 0) fail(`policy loading failed: ${sample.value.stderr}`);
    policySamples.push(sample.ms);
  }
  emitPhase('policy_loading', policySamples, `files=${policyFileCount} bytes=${policyFileCount * policyBytes}`);

  const prefetchSamples = [];
  const prefetchStatuses = [];
  const prefetchLog = path.posix.join(homePosix, 'handoff-sync-prefetch.log');
  process.stdout.write(`measuring the skill's network prefetch helper (${sampleCount} samples)\n`);
  for (let i = 0; i < sampleCount; i += 1) {
    const sample = measure(() => runBash(['core/scripts/handoff-sync-prefetch.sh', '--hq-root', rootPosix, '--timeout', '2', '--log', prefetchLog], { timeout: 10000 }));
    if (sample.value.status !== 0) fail(`prefetch returned nonzero: ${sample.value.stderr}`);
    const status = (sample.value.stdout.trim() || 'no-status').replace(/[\r\n\t ]+/g, '_');
    prefetchStatuses.push(status);
    if (status === 'ok') prefetchSamples.push(sample.ms);
  }
  const distinctPrefetchStatuses = [...new Set(prefetchStatuses)];
  const prefetchStatus = distinctPrefetchStatuses.join(',');
  const networkMeasured = prefetchStatuses.length === sampleCount && prefetchStatuses.every((status) => status === 'ok');
  if (networkMeasured) {
    emitPhase('network_calls', prefetchSamples, 'prefetch_status=ok');
  } else {
    phaseLines.push(`phase=network_calls status=not_measured prefetch_status=${prefetchStatus} reason=helper_did_not_confirm_completed_sync excluded_from_total=yes`);
  }

  const timingEnv = {
    RESUMEWORK_TIMING_RUNS: String(sampleCount),
    RESUMEWORK_TIMING_MIN_RUNS: String(sampleCount),
    RESUMEWORK_TIMING_SESSION_ID: runId,
  };
  process.stdout.write(`measuring the exact skill command blocks and master-hook chain (${sampleCount} samples)\n`);
  const timing = await runBashStreaming(['core/scripts/tests/resumework-timing.test.sh'], { env: timingEnv, timeout: 35 * 60 * 1000 });
  if (timing.status !== 0) fail(`resumework command/hook timing failed (${timing.status}):\n${timing.stdout}\n${timing.stderr}`);
  const hookP50 = timing.stdout.match(/^hook_chain_cycle_p50_ms=(\d+)$/m)?.[1];
  const hookP95 = timing.stdout.match(/^hook_chain_cycle_p95_ms=(\d+)$/m)?.[1];
  if (!hookP50 || !hookP95) fail('timing test did not emit hook-chain percentiles');
  const measuredSteps = [
    { label: 'thread-resolution-prefetch', phase: 'thread_resolution_prefetch' },
    { label: 'lock-inspect-acquire-open-steps', phase: 'lock_inspect_acquire_open_steps' },
    { label: 'git-session-metadata', phase: 'git_session_metadata' },
  ];
  const timingRows = new Map();
  for (const match of timing.stdout.matchAll(/^([a-z][a-z-]+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)$/gm)) {
    timingRows.set(match[1], { hookP50: Number(match[2]), hookP95: Number(match[3]), commandP50: Number(match[4]), commandP95: Number(match[5]) });
  }
  const missingSteps = measuredSteps.filter(({ label }) => !timingRows.has(label));
  if (missingSteps.length) fail(`timing test omitted measured steps: ${missingSteps.map(({ label }) => label).join(', ')}`);
  const commandPhases = [];
  for (const step of measuredSteps) {
    const row = timingRows.get(step.label);
    const phaseLine = `phase=command_${step.phase} p50_ms=${row.commandP50} p95_ms=${row.commandP95} source=${step.label}`;
    phaseLines.push(phaseLine);
    commandPhases.push({ p50: row.commandP50, p95: row.commandP95 });
  }
  phaseLines.push(`phase=hook_chain p50_ms=${hookP50} p95_ms=${hookP95} measured=${sampleCount * 3}_actual_PreToolUse_dispatches`);
  const includedPhases = [
    { p50: percentile(treeSamples, 0.5), p95: percentile(treeSamples, 0.95) },
    { p50: percentile(scanSamples, 0.5), p95: percentile(scanSamples, 0.95) },
    { p50: percentile(policySamples, 0.5), p95: percentile(policySamples, 0.95) },
    { p50: Number(hookP50), p95: Number(hookP95) },
    ...commandPhases,
  ];
  if (networkMeasured) includedPhases.push({ p50: percentile(prefetchSamples, 0.5), p95: percentile(prefetchSamples, 0.95) });
  const totalP50 = includedPhases.reduce((sum, phase) => sum + phase.p50, 0);
  const totalPhaseP95 = includedPhases.reduce((sum, phase) => sum + phase.p95, 0);
  const totalIncludes = `tree_walk,glob_scan,policy_loading,hook_chain,all_resumework_commands${networkMeasured ? ',network_calls' : ''}`;
  const totalExcludes = `${networkMeasured ? '' : 'network_unconfirmed,'}index_reads_not_invoked,fixture_build`;
  phaseLines.push(`phase=estimated_run_total p50_ms=${totalP50} sum_phase_p95_ms=${totalPhaseP95} basis=sum_of_non_overlapping_phase_percentiles includes=${totalIncludes} excludes=${totalExcludes}`);

  const qmdCalls = 0;
  phaseLines.push(`phase=index_reads elapsed_ms=0 status=not_invoked_by_headless_resumework_steps qmd_calls=${qmdCalls}`);

  const guardPath = `${rootPosix}/companies/companyx/projects/benchmark/README.md`;
  const guardPayload = JSON.stringify({
    hook_event_name: 'PreToolUse',
    session_id: runId,
    tool_name: 'Read',
    cwd: rootPosix,
    tool_input: { file_path: guardPath },
  });
  process.stdout.write('reproducing the cross-company scope guard\n');
  const guard = runBash([path.posix.join(rootPosix, '.claude/hooks/mandatory-scope-authorizer.sh')], { input: guardPayload, timeout: 30000 });
  const guardMessage = guard.stderr.trim() || guard.stdout.trim();
  const guardPassed = guard.status === 2 && guardMessage.startsWith('BLOCKED: Cross-company scope violation');

  const osName = process.env.RUNNER_OS || os.platform();
  const lines = [
    `resumework benchmark os=${osName} generated_fixture_files=${generatedFiles.length} total_repo_tree_files=${totalTreeFiles} samples=${sampleCount}`,
    ...phaseLines,
    `scope_guard_reproduced=${guardPassed ? 'yes' : 'no'}`,
    'scope_guard_message_begin',
    guardMessage || '(no denial message)',
    'scope_guard_message_end',
    'fixture_limitations=No Windows Defender real-time scan or OneDrive/synced folder; authenticated cross-device sync was not confirmed; QMD index reads are not part of the headless resumework path; real customer file count, depth, content, and cold-index state are not reproduced.',
    'hook_timing_detail_begin',
    timing.stdout.trim(),
    'hook_timing_detail_end',
  ];
  const report = `${lines.join('\n')}\n`;
  process.stdout.write(report);
  if (process.env.GITHUB_STEP_SUMMARY) {
    const table = [
      '### `/resumework` phase timing',
      '',
      `OS: ${osName}; generated files: ${generatedFiles.length}; total checkout tree files: ${totalTreeFiles}; samples: ${sampleCount}.`,
      '',
      '| Phase | p50 ms | p95 ms | Notes |',
      '|---|---:|---:|---|',
      `| Fixture build | n/a | ${buildMs} | ${generatedFiles.length} generated files |`,
      `| Tree walk | ${percentile(treeSamples, 0.5)} | ${percentile(treeSamples, 0.95)} | 2,400 archived threads |`,
      `| Glob/scan | ${percentile(scanSamples, 0.5)} | ${percentile(scanSamples, 0.95)} | one archived partial-id match |`,
      `| Policy loading | ${percentile(policySamples, 0.5)} | ${percentile(policySamples, 0.95)} | ${policyFileCount} files; ${policyFileCount * policyBytes} bytes |`,
      `| Hook chain | ${hookP50} | ${hookP95} | ${sampleCount * 3} actual PreToolUse dispatches over ${sampleCount} cycles |`,
      `| Thread-resolution command | ${timingRows.get('thread-resolution-prefetch').commandP50} | ${timingRows.get('thread-resolution-prefetch').commandP95} | measured command, hook excluded |`,
      `| Lock inspect/open-steps command | ${timingRows.get('lock-inspect-acquire-open-steps').commandP50} | ${timingRows.get('lock-inspect-acquire-open-steps').commandP95} | measured command, hook excluded |`,
      `| Git session-metadata command | ${timingRows.get('git-session-metadata').commandP50} | ${timingRows.get('git-session-metadata').commandP95} | measured command, hook excluded |`,
      `| Estimated run total | ${totalP50} | sum of phase p95s: ${totalPhaseP95} | excludes unconfirmed network, index reads, and fixture build |`,
      `| Network/prefetch | ${networkMeasured ? percentile(prefetchSamples, 0.5) : 'not measured'} | ${networkMeasured ? percentile(prefetchSamples, 0.95) : 'not measured'} | ${prefetchStatus}; only completed sync samples count |`,
      '| Index reads | 0 | 0 | not invoked by headless resumework steps |',
      '',
      `Cross-company scope guard reproduced: **${guardPassed ? 'yes' : 'no'}**.`,
      '',
      '```text',
      guardMessage || '(no denial message)',
      '```',
      '',
      'CI limitations: no Windows Defender real-time scan, OneDrive or another synced folder, authenticated cross-device sync, or QMD index access. The customer machine’s exact file count, directory depth, file contents, and cold-index state are not represented.',
    ].join('\n') + '\n';
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, table, 'utf8');
  }
  if (!guardPassed) fail(`cross-company guard did not reproduce; exit=${guard.status}; message=${guardMessage}`);
} finally {
  cleanup();
}
