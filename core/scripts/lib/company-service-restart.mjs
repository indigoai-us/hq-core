// hq-core: public
// Called under flock by the installer and the retry timer. Never reads login output.
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';

export const SERVICE = 'hq-company-signin.service';
// Root-only, no URL, code, or credential. `awaiting_person <ms>` or `code_entry <ms>`.
export const SIGNIN_PHASE_FILE = '/var/lib/hq-job-runner/state/signin-phase';
// A posted link with no code yet is idle once it is this old. Code entry is not aged out.
export const IDLE_SIGNIN_BOUND_MS = 10 * 60 * 1000;
const PHASE_LINE = /^(awaiting_person|code_entry) (\d+)\n$/;

export function releaseDigest(root, unitDir) {
  const hash = createHash('sha256');
  const add = file => {
    const stat = fs.lstatSync(file);
    if (stat.isDirectory()) {
      for (const name of fs.readdirSync(file).sort()) add(path.join(file, name));
    } else if (stat.isFile()) {
      hash.update(file).update('\0').update(fs.readFileSync(file)).update('\0');
    } else throw Error('unsafe_release_file');
  };
  // Include the release version, unit, watcher and all local imports (including
  // transitive imports). Same-version repairs therefore also refresh the watcher.
  add(path.join(root, 'core/core.yaml'));
  add(path.join(root, 'core/scripts/lib'));
  add(path.join(unitDir, SERVICE));
  return hash.digest('hex');
}

/**
 * A waiting sign-in always has a login child, so the child alone is not code
 * entry. Defer only while a code has been delivered (`code_entry`) or the
 * posted link is still inside the idle bound. A legacy watcher writes no phase
 * file; its login-child start time is the idle clock. Unknown age fails closed.
 * Stop only the Node parent while inspecting, so it cannot change phase or
 * start a login between the check and restart. The login child keeps running
 * until a restart actually happens.
 */
export function signinRestartDeferred({children, phase, childAgeMs, now, idleBoundMs = IDLE_SIGNIN_BOUND_MS}) {
  if (children.length === 0) return false;
  const status = phase();
  if (status?.phase === 'code_entry') return true;
  if (status?.phase === 'awaiting_person') {
    if (!Number.isSafeInteger(status.since) || status.since < 0) throw Error('invalid_signin_phase');
    return now() - status.since < idleBoundMs;
  }
  if (status != null) throw Error('invalid_signin_phase');
  for (const child of children) {
    const age = childAgeMs(child);
    if (!Number.isFinite(age) || age < idleBoundMs) return true;
  }
  return false;
}

export async function applyRestart({
  digest, previous, save, mainPid, pause, children, resume, restart,
  phase = () => null, childAgeMs = () => null, now = Date.now, idleBoundMs = IDLE_SIGNIN_BOUND_MS,
}) {
  if (digest === previous) return 'unchanged';
  const pid = mainPid();
  if (pid === 0) { save(digest); return 'inactive'; }
  let paused = false;
  try {
    // pause must either stop this PID or fail; finally always resumes it.
    paused = true;
    await pause(pid);
    if (mainPid() !== pid) return 'deferred';
    if (signinRestartDeferred({children: children(pid), phase, childAgeMs, now, idleBoundMs})) return 'deferred';
    restart();
    save(digest);
    return 'restarted';
  } finally {
    if (paused) resume(pid);
  }
}

export function writeSigninPhase(status, file = SIGNIN_PHASE_FILE) {
  if (status == null) {
    try { fs.unlinkSync(file); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    return;
  }
  if ((status.phase !== 'awaiting_person' && status.phase !== 'code_entry') || !Number.isSafeInteger(status.since) || status.since < 0) {
    throw Error('invalid_signin_phase');
  }
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, `${status.phase} ${status.since}\n`, {mode: 0o600});
  fs.renameSync(tmp, file);
}

export function readSigninPhase(file = SIGNIN_PHASE_FILE) {
  let raw;
  try { raw = fs.readFileSync(file, 'utf8'); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  const match = PHASE_LINE.exec(raw);
  if (!match) throw Error('invalid_signin_phase');
  const since = Number(match[2]);
  if (!Number.isSafeInteger(since)) throw Error('invalid_signin_phase');
  return {phase: match[1], since};
}

export function processStartAgeMs(pid, {procRoot = '/proc', clockTicks = 100, uptimeSeconds} = {}) {
  if (!Number.isInteger(pid) || pid <= 1) throw Error('invalid_process_status');
  const stat = fs.readFileSync(`${procRoot}/${pid}/stat`, 'utf8');
  const end = stat.lastIndexOf(')');
  if (end < 0) throw Error('invalid_process_status');
  const fields = stat.slice(end + 2).trim().split(/\s+/);
  const startTicks = Number(fields[19]);
  if (!Number.isInteger(clockTicks) || clockTicks <= 0 || !Number.isFinite(startTicks) || startTicks < 0) throw Error('invalid_process_status');
  const uptime = uptimeSeconds ?? Number(String(fs.readFileSync(`${procRoot}/uptime`, 'utf8')).split(/\s+/)[0]);
  if (!Number.isFinite(uptime) || uptime < 0) throw Error('invalid_process_status');
  return Math.max(0, (uptime - startTicks / clockTicks) * 1000);
}

const systemctl = (...args) => execFileSync('systemctl', args, {encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 15000}).trim();

export function processChildren(pid, procRoot = '/proc') {
  // Include every thread: child_process normally spawns on the main thread,
  // but a future imported module may use a worker thread.
  return fs.readdirSync(`${procRoot}/${pid}/task`).flatMap(tid => {
    const raw = fs.readFileSync(`${procRoot}/${pid}/task/${tid}/children`, 'utf8').trim();
    if (!raw) return [];
    if (!/^\d+(?:\s+\d+)*$/.test(raw)) throw Error('invalid_process_status');
    return raw.split(/\s+/).map(Number);
  });
}

async function pause(pid) {
  process.kill(pid, 'SIGSTOP');
  for (let attempt = 0; attempt < 100; attempt++) {
    const tasks = fs.readdirSync(`/proc/${pid}/task`);
    if (tasks.every(tid => /^State:\s+T\b/m.test(fs.readFileSync(`/proc/${pid}/task/${tid}/status`, 'utf8')))) return;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  throw Error('watcher_stop_timeout');
}

export async function run(configPath) {
  const stat = fs.lstatSync(configPath);
  if (!stat.isFile() || stat.uid !== 0 || (stat.mode & 0o022)) throw Error('unsafe_config');
  if (process.getuid() !== 0) throw Error('root_required');
  const c = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  if (c.provider !== 'claude' || c.providerSecret != null) return 'disabled';
  // This private directory is provisioned and checked by the installer.
  const stateDir = '/var/lib/hq-job-runner/state';
  const state = fs.lstatSync(stateDir);
  if (!state.isDirectory() || state.uid !== 0 || (state.mode & 0o077)) throw Error('unsafe_state_directory');
  const marker = path.join(stateDir, 'signin-installed-digest');
  let previous = null;
  try { previous = fs.readFileSync(marker, 'utf8').trim(); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  return applyRestart({
    digest: releaseDigest(c.hqRoot, '/etc/systemd/system'), previous,
    save: digest => {
      fs.writeFileSync(`${marker}.tmp`, `${digest}\n`, {mode: 0o600});
      fs.renameSync(`${marker}.tmp`, marker);
    },
    mainPid: () => {
      const raw = systemctl('show', '--property=MainPID', '--value', SERVICE);
      if (!/^\d+$/.test(raw)) throw Error('invalid_main_pid');
      const pid = Number(raw);
      if (!Number.isSafeInteger(pid) || pid === 1) throw Error('invalid_main_pid');
      return pid;
    },
    pause, children: processChildren,
    resume: pid => { try { process.kill(pid, 'SIGCONT'); } catch (error) { if (error.code !== 'ESRCH') throw error; } },
    restart: () => systemctl('try-restart', SERVICE),
    phase: () => readSigninPhase(SIGNIN_PHASE_FILE),
    childAgeMs: child => processStartAgeMs(child),
    now: () => Date.now(),
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  run(process.argv[2]).then(result => {
    console.log(JSON.stringify({service: SERVICE, update: result}));
  }).catch(() => {
    // Never include config, terminal output, URLs, or credentials in diagnostics.
    console.error(JSON.stringify({service: SERVICE, update: 'failed_retry_pending'}));
    process.exitCode = 1;
  });
}
