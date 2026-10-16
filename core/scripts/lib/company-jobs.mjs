// hq-core: public
// Accepted company jobs. Node >=22.13 (built-in SQLite); no npm dependencies.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import { pathToFileURL } from 'node:url';
import { StringDecoder } from 'node:string_decoder';

const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const iso = ms => new Date(ms).toISOString();
const safe = (s, pattern = /^[A-Za-z0-9_-]+$/) => typeof s === 'string' && pattern.test(s);
const canonical = value => Array.isArray(value) ? `[${value.map(canonical).join(',')}]` :
  value && typeof value === 'object' ? `{${Object.entries(value).filter(([,v]) => v !== undefined).sort(([a],[b]) => a.localeCompare(b)).map(([k,v]) => `${JSON.stringify(k)}:${canonical(v)}`).join(',')}}` : JSON.stringify(value);
export const contentDigest = j => digest(canonical({prompt:j.prompt, script:j.script, context:j.context, schedule:j.schedule}));
export class Refusal extends Error { constructor(code) { super(code); this.code = code; } }
function requireThat(condition, code) { if (!condition) throw new Refusal(code); }
export function validateConfig(c) {
  requireThat(safe(c.companyUid, /^cmp_[A-Za-z0-9]+$/) && safe(c.companySlug) && safe(c.machineUid, /^out_[A-Za-z0-9]+$/), 'invalid_company_binding');
  requireThat(c.outpostId === `outpost_${c.companyUid}` && safe(c.instanceId) && safe(c.attemptId), 'invalid_host_binding');
  for (const key of ['hqRoot', 'stateDir', 'unitDir', 'machineCredsFile', 'cloudModule']) requireThat(typeof c[key] === 'string' && path.isAbsolute(c[key]) && !/[\r\n]/.test(c[key]), `invalid_${key}`);
  requireThat(new URL(c.apiUrl).protocol === 'https:', 'https_required');
  requireThat(['claude','codex','grok'].includes(c.provider), 'invalid_provider');
  requireThat(c.providerSecret === undefined || ({claude:'ANTHROPIC_API_KEY',codex:'CODEX_API_KEY',grok:'XAI_API_KEY'})[c.provider] === c.providerSecret, 'invalid_provider_secret');
  return c;
}
export function machineEnvironment(c) {
  // Runner only. Do not inherit human tokens, AWS credentials, provider overrides or NODE_OPTIONS.
  return { PATH: '/usr/local/bin:/usr/bin:/bin', HOME: c.runnerHome ?? os.homedir(), LANG:'C.UTF-8',
    HQ_ROOT:c.hqRoot, HQ_AGENT_WORKDIR:c.hqRoot, HQ_MACHINE_AUTH_REQUIRED:'1', HQ_REQUIRE_MACHINE_IDENTITY:'1',
    HQ_COMPANY_UID:c.companyUid, HQ_COMPANY_OUTPOST_ID:c.outpostId, HQ_COMPANY_OUTPOST_ATTEMPT:c.attemptId,
    HQ_MACHINE_CREDS_FILE:c.machineCredsFile, HQ_MACHINE_TOKEN_STATE_DIR:'/run/hq-company-jobs/tokens' };
}
// The job process gets allowlisted secret values and nothing that locates credentials or the ledger.
export function jobEnvironment(c, secrets = {}) {
  const env = { PATH: '/usr/local/bin:/usr/bin:/bin', HOME: c.jobHome ?? '/var/lib/hq-company-jobs', LANG:'C.UTF-8',
    HQ_ROOT:c.hqRoot, HQ_AGENT_WORKDIR:c.hqRoot,
    HQ_COMPANY_UID:c.companyUid, HQ_COMPANY_OUTPOST_ID:c.outpostId, HQ_COMPANY_OUTPOST_ATTEMPT:c.attemptId };
  for (const [name, value] of Object.entries(secrets)) env[name] = value;
  return env;
}
export function resolveJobAccount(c = {}) {
  const user = c.jobUser ?? 'hq-jobs';
  if (Number.isInteger(c.jobUid)) {
    requireThat(c.jobUid > 0, 'job_account_required');
    return {uid:c.jobUid, gid:Number.isInteger(c.jobGid) ? c.jobGid : c.jobUid, user};
  }
  const id = spawnSync('/usr/bin/id', ['-u', user], {encoding:'utf8', timeout:1000});
  if (id.status !== 0) return null;
  const uid = Number(id.stdout.trim());
  const group = spawnSync('/usr/bin/id', ['-g', user], {encoding:'utf8', timeout:1000});
  const gid = group.status === 0 ? Number(group.stdout.trim()) : uid;
  requireThat(Number.isInteger(uid) && uid > 0 && Number.isInteger(gid) && gid >= 0, 'job_account_required');
  return {uid, gid, user};
}
// Each company API call refreshes the machine token, then makes one HTTP request.
export const MACHINE_TOKEN_BUDGET_MS = 15000;
export const COMPANY_API_BUDGET_MS = 15000;
const CALL_BUDGET_MS = MACHINE_TOKEN_BUDGET_MS + COMPANY_API_BUDGET_MS;
// Above the 14400s job cap plus per-call token and HTTP budgets. Env-tunable.
export function runLockTtlMs(c = {}, env = process.env) {
  if (Number.isInteger(c.lockTtlMs) && c.lockTtlMs > 0) return c.lockTtlMs;
  const configured = Number(env.HQ_COMPANY_JOBS_LOCK_TTL_SECONDS);
  if (Number.isInteger(configured) && configured > 0) return configured * 1000;
  return 21600 * 1000;
}
export function serviceTimeoutSeconds(timeoutSeconds, secretCount = 0) {
  const secrets = Number.isInteger(secretCount) && secretCount > 0 ? secretCount : 0;
  const callSeconds = CALL_BUDGET_MS / 1000;
  // Lock wait has its own copy of the job timeout so waiting does not shrink RuntimeMaxSec.
  // Then reconcile, the delivery call, one call per secret, 30s to write the receipt, and the freshness report call.
  return timeoutSeconds + timeoutSeconds + (3 + secrets) * callSeconds + 30;
}
export function processStatus(action, result) {
  if (action === 'reconcile' && Number(result?.errors) > 0) return 1;
  if (['failed', 'blocked', 'timeout', 'uncertain'].includes(result?.outcome)) return 1;
  return 0;
}
function withDeadline(promise, budgetMs, code) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Refusal(code)), budgetMs);
    Promise.resolve(promise).then(value => { clearTimeout(timer); resolve(value); }, error => { clearTimeout(timer); reject(error); });
  });
}
export function refreshMachineTokens(cloud, creds, budgetMs = MACHINE_TOKEN_BUDGET_MS) {
  return withDeadline(cloud.getValidMachineTokens({region:creds.region, clientId:creds.clientId, userPoolDomain:''}), budgetMs, 'machine_token_timeout');
}
export async function apiClient(c) {
  Object.assign(process.env, machineEnvironment(c));
  const cloud = await import(pathToFileURL(c.cloudModule).href);
  const creds = cloud.loadMachineCreds();
  requireThat(creds?.entityType === 'company-outpost' && creds.entityUid === c.machineUid, 'company_machine_required');
  return async (operation, body = {}) => {
    const tokens = await refreshMachineTokens(cloud, creds);
    const response = await fetch(`${c.apiUrl.replace(/\/$/,'')}/outpost/company/${operation}`, {
      method:'POST', redirect:'error', signal:AbortSignal.timeout(15000),
      headers:{authorization:`Bearer ${tokens.idToken}`, 'content-type':'application/json'},
      body:JSON.stringify({...body, companyUid:c.companyUid}),
    });
    if (!response.ok) { const error = new Refusal(`company_api_${response.status}`); error.status = response.status; throw error; }
    return response.json();
  };
}
export function acceptedJob(c, j) {
  requireThat(j?.ownerKind === 'company-outpost' && j.companyUid === c.companyUid && j.agentUid === `outpost_${c.companyUid}` && j.status === 'active' && !j.deleted, 'not_accepted');
  requireThat(safe(j.jobId, /^job_[A-Za-z0-9]+$/) && safe(j.acceptedRevision) && j.contentDigest === contentDigest(j), 'invalid_revision');
  for (const k of ['machineUid','outpostId','instanceId','attemptId']) requireThat(j.target?.[k] === c[k], 'wrong_target');
  requireThat(Number.isFinite(Date.parse(j.acceptedAt)), 'invalid_acceptance_time');
  calendars(j.schedule); // reject unsupported schedules before writing units
  options(j);
  return j;
}
export function options(j) {
  const o = j.context?.companyJob ?? {};
  requireThat(o && typeof o === 'object' && !Array.isArray(o), 'invalid_execution_options');
  const timeout = o.timeoutSeconds ?? 600;
  requireThat(Number.isInteger(timeout) && timeout >= 1 && timeout <= 14400, 'invalid_timeout');
  const secrets = o.secrets ?? [];
  requireThat(Array.isArray(secrets) && secrets.length <= 50 && secrets.every(s => safe(s, /^[A-Z][A-Z0-9_]*$/)) && new Set(secrets).size === secrets.length, 'invalid_secret_names');
  requireThat(secrets.every(s => !/^(HQ_|AWS_|NODE_|HOME$|PATH$|LD_|BASH_|ENV$)/.test(s)), 'reserved_secret_name');
  return {timeout, secrets};
}
function numeric(field, min, max) {
  const values = [];
  const expand = part => {
    if (part === '*') { for (let n = min; n <= max; n++) values.push(n); return; }
    const stepped = /^(\*|\d+-\d+)\/(\d+)$/.exec(part);
    if (stepped) {
      const every = Number(stepped[2]);
      requireThat(every > 0, 'unsupported_cron');
      let start = min, end = max;
      if (stepped[1] !== '*') { const pair = stepped[1].split('-').map(Number); start = pair[0]; end = pair[1]; }
      requireThat(start >= min && end <= max && start <= end, 'unsupported_cron');
      for (let n = start; n <= end; n += every) values.push(n);
      return;
    }
    const range = /^(\d+)-(\d+)$/.exec(part);
    if (range) {
      const start = Number(range[1]), end = Number(range[2]);
      requireThat(start >= min && end <= max && start <= end, 'unsupported_cron');
      for (let n = start; n <= end; n++) values.push(n);
      return;
    }
    requireThat(/^\d+$/.test(part), 'unsupported_cron');
    const n = Number(part);
    requireThat(n >= min && n <= max, 'unsupported_cron');
    values.push(n);
  };
  requireThat(typeof field === 'string' && field.length > 0, 'unsupported_cron');
  for (const part of field.split(',')) expand(part);
  requireThat(values.length > 0, 'unsupported_cron');
  return [...new Set(values)];
}
const WEEKDAYS = ['SUN','MON','TUE','WED','THU','FRI','SAT'];
function weekdaySet(dow) {
  const days = new Set();
  if (dow === '*' || dow === '?') { WEEKDAYS.forEach(name => days.add(name)); return days; }
  for (const part of String(dow).toUpperCase().split(',')) {
    const named = /^([A-Z]{3})(?:-([A-Z]{3}))?$/.exec(part);
    if (named) {
      const start = WEEKDAYS.indexOf(named[1]), end = WEEKDAYS.indexOf(named[2] ?? named[1]);
      requireThat(start >= 0 && end >= start, 'unsupported_weekday');
      WEEKDAYS.slice(start, end + 1).forEach(name => days.add(name));
      continue;
    }
    // EventBridge numbers: 1=SUN … 7=SAT. The server's name form stays accepted.
    const numbered = /^([1-7])(?:-([1-7]))?$/.exec(part);
    requireThat(numbered, 'unsupported_weekday');
    const start = Number(numbered[1]) - 1, end = Number(numbered[2] ?? numbered[1]) - 1;
    requireThat(end >= start, 'unsupported_weekday');
    WEEKDAYS.slice(start, end + 1).forEach(name => days.add(name));
  }
  requireThat(days.size > 0, 'unsupported_weekday');
  return days;
}
function cronFields(expression) {
  const match=/^cron\((.+)\)$/.exec((expression??'').trim());
  requireThat(match,'unsupported_cron');
  return match[1].trim().split(/\s+/);
}
function rateInterval(expression) {
  const rate=/^rate\(\s*(\d+)\s+(minute|hour|day)s?\s*\)$/i.exec((expression??'').trim());
  if(!rate)return null;
  const every=Number(rate[1])*({minute:60000,hour:3600000,day:86400000}[rate[2].toLowerCase()]);
  requireThat(Number.isFinite(every)&&every>0,'invalid_rate');return every;
}
export function calendars(s) {
  requireThat(s && typeof s.timezone === 'string' && /^[A-Za-z0-9_+/-]+$/.test(s.timezone), 'invalid_timezone');
  new Intl.DateTimeFormat('en-US',{timeZone:s.timezone}).format();
  if (s.kind === 'once') { requireThat(Number.isFinite(Date.parse(s.at)), 'invalid_once'); return [iso(Date.parse(s.at)).replace('T',' ').replace(/\.\d+Z$/,' UTC')]; }
  requireThat(s.kind === 'recurring', 'invalid_schedule');
  if (rateInterval(s.cron)!==null) return ['*-*-* *:*:00 UTC'];
  const [m,h,dom,month,dow,year,...extra] = cronFields(s.cron);
  requireThat(!extra.length && ['*','?'].includes(dom) && month==='*' && year==='*', 'unsupported_cron');
  const days = weekdaySet(dow);
  const prefix = days.size===7 ? '' : [...days].map(n=>n[0]+n.slice(1).toLowerCase()).join(',')+' ';
  // Split fixed hour lists so twice-daily jobs have two independent timers.
  return numeric(h,0,23).map(hour=>`${prefix}*-*-* ${String(hour).padStart(2,'0')}:${numeric(m,0,59).map(n=>String(n).padStart(2,'0')).join(',')}:00 ${s.timezone}`);
}
export function occurrencesSince(j, after, through) {
  const s=j.schedule;
  if (s.kind==='once') return Date.parse(s.at)>after && Date.parse(s.at)<=through ? 1 : 0;
  const every=rateInterval(s.cron);
  if (every!==null) { const anchor=Date.parse(j.acceptedAt); return Math.max(0,Math.floor((through-anchor)/every)-Math.max(0,Math.floor((after-anchor)/every))); }
  const [m,h,,,dow]=cronFields(s.cron), mins=numeric(m,0,59), hours=numeric(h,0,23), days=weekdaySet(dow);
  const format=new Intl.DateTimeFormat('en-US',{timeZone:s.timezone,hourCycle:'h23',hour:'numeric',minute:'numeric',weekday:'short'});
  let count=0;
  // Only the distinction 0 / 1 / multiple is needed; bound scan to eight days.
  for(let t=Math.max(Math.floor(after/60000)*60000+60000,through-8*86400000);t<=through;t+=60000){
    const parts=Object.fromEntries(format.formatToParts(t).map(p=>[p.type,p.value]));
    const day=parts.weekday.toUpperCase();
    if(days.has(day)&&mins.includes(Number(parts.minute))&&hours.includes(Number(parts.hour))&&++count>=2)return count;
  }
  return count;
}
// systemd expands % specifiers and $$ to a single dollar in ExecStart.
const quote = s => '"'+String(s).replace(/\\/g,'\\\\').replace(/%/g,'%%').replace(/"/g,'\\"').replace(/\$/g,'$$$$')+'"';
function missingUnit(error){return /Unit( file)? [\s\S]*(does not exist|not found)|not loaded/i.test(`${error?.detail??''}\n${error?.message??''}`);}
function atomic(file, value) { const tmp=`${file}.${crypto.randomUUID()}`; fs.writeFileSync(tmp,value,{mode:0o600}); fs.renameSync(tmp,file); }
export function privateDirectory(dir) {
  requireThat(path.isAbsolute(dir),'absolute_directory_required');
  let current=path.parse(dir).root;
  for(const part of dir.slice(current.length).split(path.sep).filter(Boolean)){
    current=path.join(current,part);
    if(fs.existsSync(current))requireThat(!fs.lstatSync(current).isSymbolicLink(),'symlink_directory');
  }
  fs.mkdirSync(dir,{recursive:true,mode:0o700});
  const stat=fs.statSync(dir);
  requireThat(stat.uid===process.getuid()&&(stat.mode&0o077)===0,'unsafe_private_directory');
}
export function processIdentity(pid) {
  if(process.platform==='linux'){
    try {const stat=fs.readFileSync(`/proc/${pid}/stat`,'utf8');return fs.readFileSync('/proc/sys/kernel/random/boot_id','utf8').trim()+':'+stat.slice(stat.lastIndexOf(')')+2).split(' ')[19];}
    catch(e){if(e.code==='ENOENT')return null;throw e;}
  }
  const result=spawnSync('/bin/ps',['-p',String(pid),'-o','lstart='],{encoding:'utf8',timeout:1000});
  if(result.status===1&&!result.stdout.trim())return null;
  requireThat(result.status===0,'process_identity_unavailable');return result.stdout.trim();
}
export class Ledger {
  constructor(dir) {
    privateDirectory(dir);
    const dbPath=path.join(dir,'runs.sqlite');
    for(const suffix of ['', '-wal','-shm'])if(fs.existsSync(dbPath+suffix))requireThat(!fs.lstatSync(dbPath+suffix).isSymbolicLink(),'unsafe_ledger');
    const fd=fs.openSync(dbPath,fs.constants.O_CREAT|fs.constants.O_RDWR|fs.constants.O_NOFOLLOW,0o600);fs.closeSync(fd);
    this.db=new DatabaseSync(dbPath);
    this.db.exec('PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS runs (key TEXT PRIMARY KEY, run_id TEXT UNIQUE, job TEXT, revision TEXT, scheduled TEXT, state TEXT, since INTEGER, expires INTEGER, owner INTEGER, receipt TEXT);');
    const columns=this.db.prepare('PRAGMA table_info(runs)').all().map(c=>c.name);
    for(const col of ['owner_identity','token'])if(!columns.includes(col))this.db.exec(`ALTER TABLE runs ADD COLUMN ${col} TEXT`);
    this.db.exec('CREATE TABLE IF NOT EXISTS run_lock (id INTEGER PRIMARY KEY CHECK (id = 1), since INTEGER NOT NULL, ttl INTEGER NOT NULL, token TEXT NOT NULL, run_id TEXT NOT NULL, owner INTEGER NOT NULL)');
    const lockColumns=this.db.prepare('PRAGMA table_info(run_lock)').all().map(c=>c.name);
    if(!lockColumns.includes('runner_unit'))this.db.exec('ALTER TABLE run_lock ADD COLUMN runner_unit TEXT');
  }
  close(){this.db.close();}
  completed(runId){return this.db.prepare("SELECT 1 FROM runs WHERE run_id=? AND state='done'").get(runId)!==undefined;}
  pending(){return this.db.prepare("SELECT run_id AS runId,job AS jobId,revision FROM runs WHERE state!='done'").all();}
  last(job){return this.db.prepare("SELECT scheduled FROM runs WHERE job=? AND state='done' AND json_extract(receipt,'$.requestedAt') IS NULL ORDER BY scheduled DESC LIMIT 1").get(job)?.scheduled;}
  claim(d,ttl,now=Date.now()) {
    const key=digest(`${d.companyUid}:${d.jobId}:${d.requestedAt ? 'manual:'+d.runId : d.firedAt}`),token=crypto.randomUUID();
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const row=this.db.prepare('SELECT * FROM runs WHERE key=? OR run_id=?').get(key,d.runId);
      if(row && (row.state==='done'||row.expires>now)){this.db.exec('COMMIT');return null;}
      if(row && row.owner_identity && processIdentity(row.owner)===row.owner_identity)throw new Refusal('expired_claim_owner_alive');
      const uncertain=row?.state==='executing';
      // Execution admission is monotonic, including a crash during recovery.
      this.db.prepare('INSERT OR REPLACE INTO runs VALUES (?,?,?,?,?,?,?,?,?,?,?,?)').run(key,d.runId,d.jobId,d.acceptedRevision,d.firedAt,uncertain?'executing':'running',row?.since??now,now+ttl,process.pid,row?.receipt??null,processIdentity(process.pid),token);
      this.db.exec('COMMIT'); return {key,token,uncertain,since:row?.since??now};
    } catch(e){this.db.exec('ROLLBACK');throw e;}
  }
  executing(claim){const result=this.db.prepare("UPDATE runs SET state='executing' WHERE key=? AND token=? AND state='running'").run(claim.key,claim.token);requireThat(result.changes===1,'claim_fenced');}
  finish(claim,receipt){const result=this.db.prepare("UPDATE runs SET state='done',receipt=? WHERE key=? AND token=?").run(JSON.stringify(receipt),claim.key,claim.token);requireThat(result.changes===1,'claim_fenced');}
  // A dead holder is reclaimed immediately when no job-run unit is active.
  // An unknown holder stays alive and keeps the ttl. A live job-run unit blocks reclaim even after ttl.
  // The unit probe stays outside the write transaction so systemctl cannot pin the ledger.
  acquireRunLock({runId, ttlMs, now = Date.now(), owner = process.pid, unitsActive = false, runnerUnit = null, holderAlive, unitAlive, unitProbe} = {}) {
    requireThat(Number.isInteger(ttlMs) && ttlMs > 0, 'invalid_lock_ttl');
    const peek = this.db.prepare('SELECT since, ttl, runner_unit, owner FROM run_lock WHERE id=1').get();
    let probedAlive = true;
    if (peek) probedAlive = holderAliveNow(peek.runner_unit, holderAlive, unitAlive, peek.owner, unitProbe);
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const row = this.db.prepare('SELECT since, ttl, runner_unit, owner FROM run_lock WHERE id=1').get();
      if (row) {
        const same = peek && row.since === peek.since && row.ttl === peek.ttl && row.runner_unit === peek.runner_unit && row.owner === peek.owner;
        const alive = same ? probedAlive : true;
        if (unitsActive || (alive && now < row.since + row.ttl)) { this.db.exec('COMMIT'); return null; }
      }
      const token = crypto.randomUUID();
      this.db.prepare('INSERT OR REPLACE INTO run_lock (id, since, ttl, token, run_id, owner, runner_unit) VALUES (1,?,?,?,?,?,?)').run(now, ttlMs, token, runId, owner, runnerUnit ?? null);
      this.db.exec('COMMIT');
      return {token, since: now, reclaimed: Boolean(row)};
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  releaseRunLock(lock) {
    if (!lock?.token) return false;
    return this.db.prepare('DELETE FROM run_lock WHERE id=1 AND token=?').run(lock.token).changes === 1;
  }
}
let systemdRunCached;
function canEnterScope() {
  if (systemdRunCached !== undefined) return systemdRunCached;
  const result = spawnSync('systemd-run', ['--version'], {timeout: 2000, stdio: 'ignore'});
  systemdRunCached = result.status === 0;
  return systemdRunCached;
}
export function jobRunUnitsActive(run = spawnSync) {
  const result = run('systemctl', ['list-units', 'hq-company-job-run-*.service', '--state=active,activating', '--no-legend', '--plain'], {encoding:'utf8', timeout:5000});
  if (result?.error?.code === 'ENOENT') return false;
  if (!result || result.status !== 0) return true;
  return result.stdout.trim().length > 0;
}
const RUNNER_ALIVE = new Set(['active', 'activating', 'deactivating', 'reloading']);
// No unit, or systemctl we cannot trust, is alive. Only a loaded inactive unit is dead.
// LoadState=not-found is not a confirmed stop: systemd reports that for a unit that
// was never started and for one --collect already dropped.
export function probeRunnerUnit(unit, run = spawnSync) {
  if (!unit) return {alive: true, missing: false};
  const result = run('systemctl', ['show', '-p', 'ActiveState', '-p', 'LoadState', unit], {encoding:'utf8', timeout:5000});
  if (!result || result.error?.code === 'ENOENT' || result.status !== 0) return {alive: true, missing: false};
  const text = String(result.stdout ?? '');
  let state = /^ActiveState=(.*)$/m.exec(text)?.[1]?.trim();
  let load = /^LoadState=(.*)$/m.exec(text)?.[1]?.trim() ?? '';
  if (state === undefined && !text.includes('=')) {
    const lines = text.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
    state = lines[0] ?? '';
    load = lines[1] ?? '';
  }
  if (!state) return {alive: true, missing: false};
  if (load === 'not-found') return {alive: true, missing: true};
  return {alive: RUNNER_ALIVE.has(state), missing: false};
}
export function runnerUnitAlive(unit, run = spawnSync) {
  return probeRunnerUnit(unit, run).alive;
}
// is-active is false while activating. show would report that state as alive; this must not.
export function serviceUnitActive(unit, run = spawnSync) {
  if (!unit) return false;
  const result = run('systemctl', ['is-active', unit], {encoding:'utf8', timeout:5000});
  if (result?.error?.code === 'ENOENT') return false;
  return result?.status === 0 && String(result.stdout ?? '').trim() === 'active';
}
// Type=simple is active at fork, before LoadCredential copies the source files.
// Type=exec is active only after execve, which is after that copy.
export function secretSourcesReady(unit, run = spawnSync) {
  if (!unit) return false;
  const result = run('systemctl', ['show', '-p', 'ActiveState', '-p', 'Type', unit], {encoding:'utf8', timeout:5000});
  if (!result || result.error?.code === 'ENOENT' || result.status !== 0) return false;
  const text = String(result.stdout ?? '');
  const state = /^ActiveState=(.*)$/m.exec(text)?.[1]?.trim();
  const type = /^Type=(.*)$/m.exec(text)?.[1]?.trim();
  return state === 'active' && type === 'exec';
}
function processAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return true;
  try { return processIdentity(pid) !== null; }
  catch { return true; }
}
function holderAliveNow(unit, holderAlive, unitAlive, owner, probe) {
  if (typeof holderAlive === 'boolean') return holderAlive;
  if (typeof unitAlive === 'function') return unitAlive(unit) !== false;
  const seen = probe ?? probeRunnerUnit(unit);
  if (!seen.alive) return false;
  // --collect removes the per-run unit after a crash. The owner pid distinguishes that from a live holder whose unit has not started.
  if (seen.missing && !processAlive(owner)) return false;
  return true;
}
// A transient service stays in the runner's stop set. A scope would not.
export function transientCommand(command, args, {unit, user = 'hq-jobs', runtimeSec, runnerUnit, envFile, workingDirectory, credentials = [], wrapper} = {}) {
  const prefix = [
    `--unit=${unit}`,
    `--property=Type=exec`,
    `--property=User=${user}`,
    `--property=RuntimeMaxSec=${runtimeSec}`,
    '--property=KillMode=control-group',
    '--property=SendSIGKILL=yes',
    `--property=PartOf=${runnerUnit}`,
    `--property=BindsTo=${runnerUnit}`,
    '--collect', '--pipe', '--wait', '--quiet',
  ];
  if (envFile) prefix.push(`--property=EnvironmentFile=${envFile}`);
  for (const cred of credentials) {
    requireThat(safe(cred?.id, /^[A-Za-z0-9_]+$/), 'invalid_credential_id');
    requireThat(typeof cred.path === 'string' && path.isAbsolute(cred.path) && !/[\r\n]/.test(cred.path), 'invalid_credential_path');
    prefix.push(`--property=LoadCredential=${cred.id}:${cred.path}`);
  }
  if (workingDirectory) {
    requireThat(typeof workingDirectory === 'string' && path.isAbsolute(workingDirectory) && !/[\r\n]/.test(workingDirectory), 'invalid_working_directory');
    prefix.push(`--working-directory=${workingDirectory}`);
  }
  const commandArgs = credentials.length ? [wrapper, command, ...args] : [command, ...args];
  if (credentials.length) requireThat(typeof wrapper === 'string' && wrapper.length > 0 && !/[\r\n]/.test(wrapper), 'credential_wrapper_required');
  return {command: 'systemd-run', args: [...prefix, '--', ...commandArgs]};
}
export function writeServiceEnvironment(dir, runId, env) {
  requireThat(safe(runId), 'invalid_env_file');
  const file = path.join(dir, `env-${runId}`);
  const lines = [];
  for (const [key, value] of Object.entries(env)) {
    requireThat(/^[A-Za-z_][A-Za-z0-9_]*$/.test(key), 'invalid_env_name');
    requireThat(typeof value === 'string' && !/[\0\n\r]/.test(value), 'invalid_env_value');
    const escaped = value.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\$/g, '\\$').replace(/`/g, '\\`');
    lines.push(`${key}="${escaped}"`);
  }
  const fd = fs.openSync(file, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW, 0o600);
  try { fs.writeFileSync(fd, `${lines.join('\n')}\n`); }
  finally { fs.closeSync(fd); }
  return file;
}
export function secretRuntimeDirectory(c = {}) {
  const dir = c.secretRuntimeDir || '/run/hq-company-jobs';
  requireThat(typeof dir === 'string' && path.isAbsolute(dir) && !/[\r\n]/.test(dir), 'invalid_secret_runtime');
  if (typeof c.stateDir === 'string' && path.resolve(dir) === path.resolve(c.stateDir)) throw new Refusal('secret_runtime_persistent');
  return dir;
}
const liveSecretDirs = new Set();
let secretExitHook = false;
function trackSecretDir(dir) {
  liveSecretDirs.add(dir);
  if (secretExitHook) return;
  secretExitHook = true;
  process.on('exit', () => {
    for (const live of [...liveSecretDirs]) {
      try { dropSecretDir(live); } catch { /* exit still removes the rest */ }
    }
  });
}
function dropSecretDir(dir) {
  if (!dir) return;
  liveSecretDirs.delete(dir);
  let stat;
  try { stat = fs.lstatSync(dir); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  if (stat.isSymbolicLink()) { fs.unlinkSync(dir); return; }
  if (stat.isDirectory()) fs.rmSync(dir, {recursive: true, force: true});
}
function writeCredentialFile(dir, name, value) {
  const file = path.join(dir, name);
  const fd = fs.openSync(file, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW, 0o600);
  try { fs.writeFileSync(fd, value); }
  finally { fs.closeSync(fd); }
  return file;
}
// Non-secret values stay in an EnvironmentFile. Secrets are raw credential files so PEM and JSON keep their newlines.
export function prepareServiceMaterial(envFileDir, leaf, env, secretNames = []) {
  const id = String(leaf ?? '').replace(/\.service$/, '');
  requireThat(safe(id), 'invalid_env_file');
  requireThat(typeof envFileDir === 'string' && path.isAbsolute(envFileDir) && !/[\r\n]/.test(envFileDir), 'invalid_secret_runtime');
  const secrets = new Set(secretNames);
  for (const name of secrets) requireThat(safe(name, /^[A-Z][A-Z0-9_]*$/), 'invalid_secret_names');
  const base = {};
  const secretValues = [];
  for (const [key, value] of Object.entries(env ?? {})) {
    requireThat(typeof value === 'string' && !value.includes('\0'), 'invalid_env_value');
    if (secrets.has(key)) secretValues.push([key, value]);
    else base[key] = value;
  }
  privateDirectory(envFileDir);
  const dir = path.join(envFileDir, id);
  const existing = lstatOrNull(dir);
  if (existing?.isSymbolicLink()) throw new Refusal('secret_runtime_symlink');
  if (existing) throw new Refusal('secret_runtime_exists');
  fs.mkdirSync(dir, {mode: 0o700});
  trackSecretDir(dir);
  try {
    const dirFd = fs.openSync(dir, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
    try { fs.fchmodSync(dirFd, 0o700); }
    finally { fs.closeSync(dirFd); }
    const credentials = secretValues.map(([key, value]) => ({id: key, path: writeCredentialFile(dir, key, value)}));
    const envFile = writeServiceEnvironment(dir, 'base', base);
    if (credentials.length) {
      credentials.push({id: 'names', path: writeCredentialFile(dir, 'names', `${credentials.map(item => item.id).join('\n')}\n`)});
    }
    return {dir, envFile, credentials};
  } catch (error) {
    dropSecretDir(dir);
    throw error;
  }
}
export function sweepStaleSecretDirs(dir, unitAlive = runnerUnitAlive) {
  if (typeof dir !== 'string' || !path.isAbsolute(dir) || /[\r\n]/.test(dir)) return [];
  const root = lstatOrNull(dir);
  if (!root) return [];
  if (root.isSymbolicLink() || !root.isDirectory()) throw new Refusal('secret_runtime_symlink');
  const removed = [];
  for (const name of fs.readdirSync(dir)) {
    if (name === 'tokens' || !safe(name)) continue;
    const child = path.join(dir, name);
    const stat = lstatOrNull(child);
    if (!stat || stat.isSymbolicLink() || !stat.isDirectory()) continue;
    const live = [`hq-company-job-run-${name}.service`, `hq-company-job-run-${name}-pre.service`].some(unit => {
      try { return unitAlive(unit) !== false; }
      catch { return true; }
    });
    if (live) continue;
    dropSecretDir(child);
    removed.push(name);
  }
  return removed;
}
export async function releaseSecretsAfterActive(dir, isActive, {intervalMs = 50, budgetMs = 10000} = {}) {
  const started = Date.now();
  for (;;) {
    let active = false;
    try { active = isActive() === true; }
    catch { active = false; }
    if (active) { dropSecretDir(dir); return 'released'; }
    if (Date.now() - started >= budgetMs) return 'pending';
    await new Promise(resolve => setTimeout(resolve, intervalMs));
  }
}
function stopJobUnit(scope, systemctl) {
  if (!scope) return;
  const ctl = systemctl ?? (ctlArgs => {
    const result = spawnSync('systemctl', ctlArgs, {encoding: 'utf8', timeout: 15000});
    if (result.error) throw result.error;
    if (result.status !== 0) {
      const error = new Error(`${result.stderr ?? ''}\n${result.stdout ?? ''}`.trim());
      error.detail = error.message;
      throw error;
    }
  });
  for (const ctlArgs of [['kill', scope, '--kill-whom=all', '--signal=SIGKILL'], ['stop', scope]]) {
    try { ctl(ctlArgs); }
    catch (error) { if (error?.code !== 'ENOENT' && !missingUnit(error)) continue; }
  }
}
export function bounded(command,args,{env,cwd,input='',timeout=600000,output,redactions=[],uid,gid,scope,unit,systemctl,enterScope,enterService,serviceUser,runnerUnit,envFileDir,runId,runtimeSec,secretNames}={}) {
  return new Promise((resolve,reject)=>{
    let settled = false, timedOut = false, drain, timer, releaseTimer, child, reaped = false, secretDir;
    const finish = value => { if (settled) return; settled = true; clearTimeout(timer); clearTimeout(drain); clearTimeout(releaseTimer); dropSecretDir(secretDir); resolve(value); };
    const fail = error => { if (settled) return; settled = true; clearTimeout(timer); clearTimeout(drain); clearTimeout(releaseTimer); dropSecretDir(secretDir); reject(error); };
    let cmd = command, cmdArgs = args, dropUid = uid, dropGid = gid, spawnEnv = env;
    const useService = enterService === true && unit && canEnterScope();
    if (enterService === true && !canEnterScope()) { fail(new Refusal('job_not_isolated')); return; }
    if (useService) {
      try {
        const material = prepareServiceMaterial(envFileDir, runId || unit, env ?? {}, secretNames ?? []);
        secretDir = material.dir;
        const wrapped = transientCommand(command, args, {
          unit,
          user: serviceUser || 'hq-jobs',
          runtimeSec: runtimeSec ?? Math.max(1, Math.ceil(timeout / 1000)),
          runnerUnit,
          envFile: material.envFile,
          workingDirectory: cwd,
          credentials: material.credentials,
          wrapper: material.credentials.length ? path.join(cwd, 'core/scripts/company-job-with-credentials.sh') : undefined,
        });
        cmd = wrapped.command; cmdArgs = wrapped.args; dropUid = undefined; dropGid = undefined;
        spawnEnv = {PATH:'/usr/local/bin:/usr/bin:/bin', LANG:'C.UTF-8'};
      } catch (error) { fail(error); return; }
    }
    const spawnOptions = {env: spawnEnv, cwd, detached: !useService, stdio:['pipe','pipe','pipe']};
    if (Number.isInteger(dropUid)) spawnOptions.uid = dropUid;
    if (Number.isInteger(dropGid)) spawnOptions.gid = dropGid;
    try { child = spawn(cmd, cmdArgs, spawnOptions); }
    catch (error) { fail(error); return; }
    // Delete sources only once Type=exec is active. Simple is active before the credential copy.
    if (secretDir) {
      const started = Date.now();
      const poll = () => {
        if (settled) return;
        let ready = false;
        try { ready = secretSourcesReady(unit); }
        catch { ready = false; }
        if (ready) { try { dropSecretDir(secretDir); } catch (error) { fail(error); } return; }
        if (Date.now() - started >= 10000) return;
        releaseTimer = setTimeout(poll, 50);
      };
      releaseTimer = setTimeout(poll, 50);
    }
    // Hold a tail so secrets split across pipe chunks cannot leak.
    const retain=Math.max(1,...redactions.map(s=>s.length));
    const capture=()=>{
      const decoder=new StringDecoder('utf8');let pending='',text='',bytes=0;
      const emit=s=>{for(const secret of redactions)s=s.split(secret).join('[REDACTED]');bytes+=Buffer.byteLength(s);if(bytes<=1024*1024){text+=s;output?.(s);}};
      return {consume(chunk){pending+=decoder.write(chunk);if(pending.length>retain*2){const end=pending.length-retain;let cut=end;for(const s of redactions){const i=pending.lastIndexOf(s,end);if(i>=0&&i+s.length>end)cut=Math.min(cut,i);}emit(pending.slice(0,cut));pending=pending.slice(cut);}},finish(){emit(pending+decoder.end());return text;}};
    };
    // The session reply is a stdout protocol. Diagnostics must never corrupt it.
    const stdout=capture(),stderr=capture();
    // Stop the transient service. Never signal a stored PID, and never signal after reap.
    // The direct process group is only the macOS fallback, where no service exists.
    const endUnit = () => stopJobUnit(unit || scope, systemctl);
    const killLiveGroup = () => {
      if (useService || reaped || !child.pid) return;
      try { process.kill(-child.pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') fail(error); }
    };
    timer=setTimeout(()=>{timedOut=true;endUnit();killLiveGroup();},timeout);
    child.stdout.on('data',chunk=>stdout.consume(chunk));child.stderr.on('data',chunk=>stderr.consume(chunk));
    child.on('error',error=>{fail(error);});
    // A grandchild can hold the pipes after the direct child exits. Drain; do not signal.
    child.on('exit',()=>{ reaped = true; endUnit(); drain=setTimeout(()=>{ child.stdout.destroy(); child.stderr.destroy(); }, 500); });
    child.on('close',code=>{ clearTimeout(drain); finish({code:timedOut?124:(code??1),text:stdout.finish(),stderr:stderr.finish()}); });
    child.stdin.on('error',error=>{if(error.code!=='EPIPE')fail(error);}); child.stdin.end(input);
  });
}
function ensureUnitDirectory(dir) {
  if (fs.existsSync(dir) && fs.realpathSync(dir) === '/etc/systemd/system') {
    const stat = fs.statSync(dir);
    requireThat(stat.isDirectory() && !fs.lstatSync(dir).isSymbolicLink() && stat.uid === 0 && (stat.mode & 0o022) === 0, 'unsafe_unit_directory');
    return;
  }
  privateDirectory(dir);
}
export class CompanyRunner {
  constructor(config,api,{systemctl,execute,clock=Date.now,warn}={}){this.c=config;this.api=api;this.clock=clock;this.warn=warn??(line=>console.error(line));this.ledger=new Ledger(config.stateDir);this.systemctl=systemctl??(args=>{const r=spawnSync('systemctl',args,{encoding:'utf8',timeout:15000});if(r.status!==0){const error=new Refusal('systemctl_failed');error.detail=`${r.stderr??''}\n${r.stdout??''}`.trim();throw error;}});this.execute=execute??bounded;}
  close(){this.ledger.close();}
  // Freshness signals feed `hq outposts status` and missed-run alerts. A failed post is
  // logged to stderr (journald) and never changes the run or reconcile result.
  async heartbeat(){
    try{await this.api('jobs',{action:'heartbeat'});return true;}
    catch(error){this.warn(JSON.stringify({service:'company-jobs',event:'heartbeat_post_failed',code:error instanceof Refusal?error.code:'heartbeat_error',status:error?.status??null}));return false;}
  }
  async report(receipt){
    const body={action:'report',jobId:receipt.jobId,revision:receipt.revision,runId:receipt.runId,scheduledAt:receipt.scheduledAt,endedAt:receipt.endedAt,outcome:receipt.outcome};
    if(Number.isFinite(receipt.exitCode))body.exitCode=receipt.exitCode;
    if(typeof receipt.coalesced==='boolean')body.coalesced=receipt.coalesced;
    if(typeof receipt.errorCode==='string')body.errorCode=receipt.errorCode;
    try{await this.api('jobs',body);return true;}
    catch(error){this.warn(JSON.stringify({service:'company-jobs',event:'report_post_failed',jobId:receipt.jobId,runId:receipt.runId,outcome:receipt.outcome,code:error instanceof Refusal?error.code:'report_error',status:error?.status??null}));return false;}
  }
  async reconcile(){
    await this.heartbeat();
    const data=await this.api('jobs',{action:'reconcile'});
    requireThat(Array.isArray(data.jobs)&&Array.isArray(data.pending)&&Array.isArray(data.recoverable),'invalid_reconcile');
    const jobs=[], rejected=[];
    for (const raw of data.jobs) {
      try { jobs.push(acceptedJob(this.c, raw)); }
      catch (error) { rejected.push({jobId: typeof raw?.jobId === 'string' ? raw.jobId : null, code: error instanceof Refusal ? error.code : 'invalid_job'}); }
    }
    ensureUnitDirectory(this.c.unitDir);
    const desired=new Map();
    for(const j of jobs){
      const base=`hq-company-job-${j.jobId}`;
      const opt=options(j);
      const cmd=[process.execPath,path.join(this.c.hqRoot,'core/scripts/lib/company-jobs.mjs'),'run',this.c.configPath,j.jobId,j.acceptedRevision].map(quote).join(' ');
      const limit=serviceTimeoutSeconds(opt.timeout, opt.secrets.length + this.providerCallSlots());
      desired.set(`${base}.service`,`[Unit]\nDescription=Accepted company job ${j.jobId}\n[Service]\nType=oneshot\nUser=root\nEnvironment=HQ_RUNNER_UNIT=%n\nExecStart=${cmd}\nTimeoutStartSec=${limit}\nTimeoutStopSec=5\nKillMode=control-group\nSendSIGKILL=yes\nUMask=0077\n`);
      calendars(j.schedule).forEach((cal,i)=>desired.set(`${base}-${i}.timer`,`[Unit]\nDescription=Company job ${j.jobId}\n[Timer]\nOnCalendar=${cal}\nPersistent=true\nAccuracySec=1s\nUnit=${base}.service\n[Install]\nWantedBy=timers.target\n`));
    }
    // Manual runs use separate service instances, including recovery after queue expiry.
    // US-004 uses UUIDs for manual run IDs, SHA-256 for scheduled IDs.
    const manual = new Map([...data.pending,...data.recoverable.filter(r=>/^[0-9a-f]{8}-[0-9a-f-]{27}$/i.test(r.runId)),...this.ledger.pending()].map(r=>[r.runId,r]));
    for(const r of manual.values()){
      // Run ids become unit filenames. Reject anything that can leave unitDir.
      if(!safe(r?.runId))continue;
      if(this.ledger.completed(r.runId))continue;
      const j=jobs.find(j=>j.jobId===r.jobId&&j.acceptedRevision===r.revision);if(!j)continue;
      const body=desired.get(`hq-company-job-${j.jobId}.service`);
      desired.set(`hq-company-job-${j.jobId}-${r.runId}.service`,body.replace('\nTimeoutStartSec=',` ${quote(r.runId)}\nTimeoutStartSec=`));
    }
    for(const file of fs.readdirSync(this.c.unitDir).filter(f=>/^hq-company-job-.*\.(timer|service)$/.test(f))){
      if(!desired.has(file)){try{this.systemctl(['disable','--now',file]);}catch(error){if(!missingUnit(error))throw error;}fs.unlinkSync(path.join(this.c.unitDir,file));}
    }
    for(const [file,body]of desired)atomic(path.join(this.c.unitDir,file),body);
    this.systemctl(['daemon-reload']);
    for(const file of desired.keys())if(file.endsWith('.timer'))this.systemctl(['enable','--now',file]);
    // Workers have independent bounded cgroups; reconciliation never waits for model work.
    for(const file of desired.keys())if(file.endsWith('.service'))this.systemctl(['start','--no-block',file]);
    const errors = rejected.length;
    return {jobs:jobs.length,timers:[...desired.keys()].filter(f=>f.endsWith('.timer')).length,rejected,errors};
  }
  async waitForRunLock(runId, timeoutSeconds) {
    // One hq-jobs uid can read another job's /proc environ. Hold one run at a time.
    // DynamicUser is not used: provider CLI auth and the mode-700 workspace belong to hq-jobs.
    const ttlMs = runLockTtlMs(this.c);
    const poll = Number.isInteger(this.c.lockPollMs) && this.c.lockPollMs > 0 ? this.c.lockPollMs : 1000;
    const waitMs = Number.isInteger(this.c.lockWaitMs) && this.c.lockWaitMs > 0 ? this.c.lockWaitMs : timeoutSeconds * 1000;
    const waitUntil = this.clock() + waitMs;
    const spins = Math.max(1, Math.ceil(waitMs / poll));
    for (let attempt = 0; ; attempt++) {
      const unitsActive = this.unitsActive ? this.unitsActive() : jobRunUnitsActive();
      // The scheduled unit is shared and reconcile restarts it, so it looks alive to the next tick.
      // The per-run unit is unique; a crash leaves that unit inactive.
      const lock = this.ledger.acquireRunLock({runId, ttlMs, now: this.clock(), unitsActive, runnerUnit: safe(runId) ? `hq-company-job-run-${runId}.service` : null, holderAlive: this.holderAlive, unitAlive: this.runnerAlive});
      if (lock) return lock;
      if (this.clock() >= waitUntil || attempt >= spins) return null;
      await new Promise(resolve => setTimeout(resolve, poll));
    }
  }
  prepareRunHome(runId, account) {
    requireThat(safe(runId), 'invalid_run_home');
    const parent = path.resolve(this.c.jobHome ? path.join(this.c.jobHome, 'runs') : path.join(this.c.hqRoot, 'job-homes'));
    const runHome = path.join(parent, runId);
    requireThat(runHome === path.join(parent, runId), 'invalid_run_home');
    ensureRootOwnedChain(parent, process.getuid());
    const existing = lstatOrNull(runHome);
    if (existing) {
      if (existing.isSymbolicLink()) throw new Refusal('run_home_symlink');
      throw new Refusal('run_home_exists');
    }
    fs.mkdirSync(runHome, {mode: 0o700});
    ownNoFollow(runHome, 0o700, process.getuid() === 0 && account ? account : null);
    return {parent, runHome};
  }
  async scheduled(j){
    let d;
    try{d=await this.api('jobs',{action:'scheduled',jobId:j.jobId,revision:j.acceptedRevision});}
    catch(e){if(e.status===409)return {outcome:'not_due_or_changed'};throw e;}
    return this.runDelivery(j,d);
  }
  /** Budget slots for provider auth: one broker call, or a sign-in read plus a bounded CLI refresh. */
  providerCallSlots(){return this.c.providerSecret?1:this.c.provider==='claude'?3:0;}
  /** Box sign-in token env for the session unit, or null when a broker provider secret is configured. */
  async providerSignIn(jobMs){
    const signin=this.signin??await import('./company-signin.mjs');
    if(!signin.usesBoxSignIn(this.c))return null;
    const token=signin.claudeAccessToken({file:this.c.providerAuthFile??signin.credentialFile(),uid:this.c.providerAuthUid,needUntil:this.clock()+jobMs,now:this.clock});
    return {env:{[signin.TOKEN_ENV]:token}};
  }
  async run(jobId,revision,runId){
    const data=await this.api('jobs',{action:'reconcile'});
    const j=data.jobs.find(j=>j.jobId===jobId&&j.acceptedRevision===revision);
    requireThat(j,'revision_not_current');acceptedJob(this.c,j);
    const opt=options(j);
    this.deadlineAt=this.clock()+(1+opt.secrets.length+this.providerCallSlots())*CALL_BUDGET_MS+opt.timeout*1000;
    if(runId){
      const action=data.pending.some(r=>r.runId===runId&&r.jobId===jobId&&r.revision===revision)?'dispatch':'recover';
      const d=await this.api('jobs',{action,jobId,revision,runId});
      requireThat(d.runId===runId && (typeof d.requestedAt==='string'||this.ledger.pending().some(r=>r.runId===runId)),'recovery_delivery_required');
      return this.runDelivery(j,d);
    }
    return this.scheduled(j);
  }
  async runDelivery(j,d){
    acceptedJob(this.c,j);
    requireThat(d.companyUid===this.c.companyUid&&d.jobId===j.jobId&&d.acceptedRevision===j.acceptedRevision&&d.agentUid===this.c.machineUid&&safe(d.runId)&&d.contentDigest===j.contentDigest&&Number.isFinite(Date.parse(d.firedAt)), 'invalid_delivery');
    for(const k of ['machineUid','outpostId','instanceId','attemptId'])requireThat(d.target?.[k]===this.c[k],'wrong_delivery_target');
    requireThat(contentDigest({...d,schedule:j.schedule})===j.contentDigest,'delivery_content_changed');
    const {timeout,secrets}=options(d);
    const ttl=Math.max(timeout*1000+120000,Number(this.c.claimTtlMs??0));
    requireThat(Number.isFinite(ttl),'invalid_claim_ttl');
    const lock=await this.waitForRunLock(d.runId, timeout);
    if(!lock){
      const skipped={companyUid:this.c.companyUid,jobId:j.jobId,revision:d.acceptedRevision,runId:d.runId,scheduledAt:d.firedAt,outcome:'skipped_lock_busy',endedAt:iso(this.clock())};
      atomic(path.join(this.c.stateDir,`${digest(d.runId)}.json`),JSON.stringify(skipped,null,2)+'\n');
      await this.report(skipped);
      return skipped;
    }
    let releaseResult=null;
    const release=()=>{if(releaseResult!==null)return releaseResult;releaseResult=this.ledger.releaseRunLock(lock);return releaseResult;};
    try {
    const key=this.ledger.claim(d,ttl,this.clock());
    if(!key){if(!release())throw new Refusal('run_lock_lost');return {outcome:'duplicate'};}
    const previous=this.ledger.last(j.jobId)??j.acceptedAt;
    const coalesced=!d.requestedAt&&occurrencesSince(j,Date.parse(previous),Date.parse(d.firedAt))>1;
    const fingerprint={companyUid:this.c.companyUid,jobId:j.jobId,revision:d.acceptedRevision,runId:d.runId,scheduledAt:d.firedAt,executionPrincipal:this.c.machineUid,machine:this.c.instanceId,outpostId:this.c.outpostId,attemptId:this.c.attemptId,contentDigest:d.contentDigest,registeredBy:j.registeredBy,registeredAt:j.registeredAt,latestEditor:j.latestEditor,sessionFingerprint:j.sessionFingerprint,latestEditorSessionFingerprint:j.latestEditorSessionFingerprint,requestedBy:d.requestedBy,requestedAt:d.requestedAt};
    const outputLocation=path.join(this.c.stateDir,`${digest(d.runId)}.log`);
    const receipt={...fingerprint,startedAt:iso(key.since),endedAt:null,coalesced,outcome:'failed',outputLocation};
    const outputFd=fs.openSync(outputLocation,fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_APPEND|fs.constants.O_NOFOLLOW,0o600);
    const outputStat=fs.fstatSync(outputFd);
    requireThat(outputStat.isFile()&&outputStat.uid===process.getuid()&&outputStat.nlink===1,'unsafe_output_file');
    const log=s=>fs.writeSync(outputFd,s);
    log(JSON.stringify({executionFingerprint:fingerprint})+'\n');
    const values=[], granted={};
    const account=Number.isInteger(this.c.jobUid)?resolveJobAccount(this.c):null;
    let homes;
    try{
      if(account)requireThat(account.uid!==process.getuid(),'job_not_isolated');
      if(key.uncertain){receipt.outcome='uncertain';receipt.errorCode='supervisor_lost_after_admission';return receipt;}
      homes=this.prepareRunHome(d.runId,account);
      const budgetAnchor=this.clock();
      for(const name of new Set([...secrets,...(this.c.providerSecret?[this.c.providerSecret]:[])])){
        const request={secretName:name};
        // The live broker accepts only companyUid and secretName. Scope further only when it says it can.
        if(this.c.brokerSecretScope===true){request.jobId=j.jobId;request.runId=d.runId;}
        let result;try{result=await this.api('secret',request);}catch{receipt.blockedSecret=name;throw new Refusal('secret_denied');}
        requireThat(typeof result.value==='string'&&result.value.length>0,'invalid_secret');granted[name]=result.value;values.push(result.value);
      }
      const env=jobEnvironment({...this.c,jobHome:homes.runHome},granted);
      const jobMs=Math.max(1,timeout*1000-Math.max(0,this.clock()-budgetAnchor));
      const runnerUnit=process.env.HQ_RUNNER_UNIT||`hq-company-job-${j.jobId}.service`;
      // Box sign-in: resolved before any job code runs. Only the claude session unit receives the token.
      const signin=await this.providerSignIn(jobMs);
      const launch=extra=>({env,cwd:this.c.hqRoot,redactions:values,output:log,enterService:true,systemctl:ctlArgs=>this.systemctl(ctlArgs),serviceUser:account?.user||this.c.jobUser||'hq-jobs',runnerUnit,envFileDir:secretRuntimeDirectory(this.c),secretNames:Object.keys(granted),runId:d.runId,runtimeSec:Math.max(1,Math.ceil(jobMs/1000)),...extra,...(account?{uid:account.uid,gid:account.gid}:{})});
      this.ledger.executing(key);
      const request={contractVersion:1,agentUid:this.c.machineUid,companySlug:this.c.companySlug,companySlugs:[this.c.companySlug],channel:'job',convKey:`company-job:${d.runId}`,messageText:d.prompt,provider:this.c.provider,sender:{verified:true}};
      if(d.script){
        const preBudget=Math.max(1,Math.min(240000,jobMs));
        const pre=await this.execute('/bin/bash',['-c',d.script],launch({unit:`hq-company-job-run-${d.runId}-pre.service`,timeout:preBudget,runtimeSec:Math.max(1,Math.ceil(preBudget/1000))}));
        if(pre.code!==0)throw new Refusal(pre.code===124?'timeout':'precondition_failed');
        if(!pre.text.trim()){receipt.outcome='skipped-precondition';return receipt;}
        request.messageText+='\n\nPrecondition output:\n'+pre.text;
      }
      request.messageText+='\n\nExecution fingerprint:\n'+JSON.stringify(fingerprint);
      const result=await this.execute('/bin/bash',[path.join(this.c.hqRoot,'core/scripts/hq-agent-session.sh')],launch({unit:`hq-company-job-run-${d.runId}.service`,input:JSON.stringify(request),timeout:jobMs,runtimeSec:Math.max(1,Math.ceil(jobMs/1000)),...(signin?{env:{...env,...signin.env},secretNames:[...Object.keys(granted),...Object.keys(signin.env)],redactions:[...values,...Object.values(signin.env)]}:{})}));
      receipt.exitCode=result.code;receipt.outcome=result.code===0?'succeeded':result.code===124?'timeout':'failed';
      if(result.code===0){let response;try{response=JSON.parse(result.text);}catch{throw new Refusal('invalid_session_response');}requireThat(response.disposition==='reply' && !['failed','blocked'].includes(response.outcome),'session_not_successful');}
    }catch(e){receipt.outcome=['secret_denied','provider_not_signed_in','provider_token_expiring','provider_credential_unsafe'].includes(e.code)?'blocked':e.code==='timeout'?'timeout':'failed';receipt.errorCode=e instanceof Refusal?e.code:'execution_error';}
    finally{
      if(homes)removeRunHome(homes.parent,homes.runHome,account);
      const released=release();
      if(!released)receipt.lockRelease='lost';
      receipt.endedAt=iso(this.clock());log('\n'+JSON.stringify(receipt)+'\n');fs.closeSync(outputFd);this.ledger.finish(key,receipt);atomic(path.join(this.c.stateDir,`${digest(d.runId)}.json`),JSON.stringify(receipt,null,2)+'\n');
      await this.report(receipt);
      if(!released)throw new Refusal('run_lock_lost');
    }
    return receipt;
    } finally { if(releaseResult===null&&!release())throw new Refusal('run_lock_lost'); }
  }
}
function lstatOrNull(target) {
  try { return fs.lstatSync(target); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
function ownNoFollow(target, mode, owner) {
  let fd;
  try { fd = fs.openSync(target, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW); }
  catch (error) { if (error.code === 'ELOOP' || error.code === 'ENOTDIR') throw new Refusal('run_home_symlink'); throw error; }
  try {
    fs.fchmodSync(fd, mode);
    if (owner) fs.fchownSync(fd, owner.uid, owner.gid);
  } finally { fs.closeSync(fd); }
}
function ensureRootOwnedChain(dir, uid) {
  // Refuse a symlink at the run-home parent or the directory we would create it in.
  // Do not walk host prefixes such as /var: on macOS those are symlinks, and the job cannot replace them.
  const missing = [];
  let current = path.resolve(dir);
  while (!lstatOrNull(current)) {
    missing.push(current);
    const up = path.dirname(current);
    if (up === current) throw new Refusal('run_home_not_directory');
    current = up;
  }
  const stat = fs.lstatSync(current);
  if (stat.isSymbolicLink()) throw new Refusal('run_home_symlink');
  if (!stat.isDirectory()) throw new Refusal('run_home_not_directory');
  if (uid === 0 && (stat.uid !== 0 || (stat.mode & 0o022) !== 0)) throw new Refusal('run_home_not_root_owned');
  for (const created of missing.reverse()) {
    fs.mkdirSync(created, {mode: 0o755});
    ownNoFollow(created, 0o755, uid === 0 ? {uid: 0, gid: 0} : null);
  }
}
function removeRunHome(parent, runHome, account) {
  const dir = path.resolve(parent);
  const target = path.resolve(runHome);
  if (target !== path.join(dir, path.basename(target)) || !target.startsWith(dir + path.sep)) throw new Refusal('invalid_run_home');
  const stat = lstatOrNull(target);
  if (!stat) return;
  if (stat.isSymbolicLink()) throw new Refusal('run_home_symlink');
  if (!stat.isDirectory()) throw new Refusal('run_home_not_directory');
  const rmArgv = ['-rf', '--', target];
  if (process.getuid() === 0 && account) {
    const runuser = spawnSync('runuser', ['-u', account.user || 'hq-jobs', '--', 'rm', ...rmArgv], {timeout: 20000});
    if (runuser.error?.code === 'ENOENT') {
      const direct = spawnSync('/bin/rm', rmArgv, {uid: account.uid, gid: account.gid, timeout: 20000});
      if (direct.error) throw direct.error;
    }
  } else {
    const direct = spawnSync('/bin/rm', rmArgv, {timeout: 20000});
    if (direct.error) throw direct.error;
  }
  const after = lstatOrNull(target);
  if (!after) return;
  if (after.isSymbolicLink() || !after.isDirectory()) throw new Refusal('run_home_symlink');
  try { fs.rmdirSync(target); }
  catch (error) { if (!['ENOENT', 'ENOTEMPTY', 'EEXIST'].includes(error.code)) throw error; }
}
export async function main(args){
  const [action,configPath,jobId,revision,runId]=args;
  requireThat(['reconcile','run'].includes(action),'invalid_action');
  const stat=fs.statSync(configPath);requireThat(stat.uid===0&&(stat.mode&0o022)===0,'config_must_be_root_owned');
  requireThat(process.getuid()===0,'runner_must_be_root');
  const c=validateConfig({...JSON.parse(fs.readFileSync(configPath,'utf8')),configPath});
  const account=resolveJobAccount(c);
  requireThat(account&&account.uid>0,'job_account_required');
  c.jobUid=account.uid;c.jobGid=account.gid;
  sweepStaleSecretDirs(secretRuntimeDirectory(c));
  const runner=new CompanyRunner(c,await apiClient(c));
  try{
    const result=action==='reconcile'?await runner.reconcile():await runner.run(jobId,revision,runId);
    console.log(JSON.stringify(result));
    if(action==='reconcile'&&result.errors>0)console.error(`company jobs reconcile rejected ${result.errors}`);
    const status=processStatus(action,result);
    if(status!==0)process.exitCode=status;
  }finally{runner.close();}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)main(process.argv.slice(2)).catch(e=>{console.error(JSON.stringify({outcome:'blocked',code:e instanceof Refusal?e.code:'company_runner_error'}));process.exitCode=1;});
