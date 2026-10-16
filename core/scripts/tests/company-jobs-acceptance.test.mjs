// hq-core: public
// US-005 independent acceptance. Transport fixtures follow US-004 e54b379d.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { CompanyRunner, Ledger, apiClient, bounded, main, machineEnvironment } from '../lib/company-jobs.mjs';

const scripts = fileURLToPath(new URL('../', import.meta.url));
const revision = '93f90d54-1e8f-4a7a-90bd-9601397479be';
const canonical = v => Array.isArray(v) ? `[${v.map(canonical).join(',')}]` : v && typeof v === 'object'
  ? `{${Object.entries(v).filter(([,x]) => x !== undefined).sort(([a],[b]) => a.localeCompare(b)).map(([k,x]) => `${JSON.stringify(k)}:${canonical(x)}`).join(',')}}` : JSON.stringify(v);
const hash = s => crypto.createHash('sha256').update(s).digest('hex');
function seal(j) { j.contentDigest = hash(canonical({prompt:j.prompt, script:j.script, context:j.context, schedule:j.schedule})); return j; }
function harness(t) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'us005-acceptance-')));
  const config = {companyUid:'cmp_acceptance',companySlug:'indigo',machineUid:'out_machine1',outpostId:'outpost_cmp_acceptance',instanceId:'i-acceptance',attemptId:'attempt1',hqRoot:dir,stateDir:path.join(dir,'state'),unitDir:path.join(dir,'units'),configPath:path.join(dir,'config.json'),machineCredsFile:path.join(dir,'machine.json'),cloudModule:path.join(dir,'cloud.mjs'),apiUrl:'https://test.invalid',provider:'codex'};
  const job = seal({ownerKind:'company-outpost',companyUid:config.companyUid,agentUid:config.outpostId,jobId:'job_Acceptance',acceptedRevision:revision,status:'active',prompt:'Write the harmless acceptance marker.',registeredBy:'prs_registering',registeredAt:'2026-01-01T00:00:00Z',latestEditor:'prs_editor',sessionFingerprint:'registration-session',latestEditorSessionFingerprint:'editor-session',acceptedAt:'2026-01-01T00:00:00Z',schedule:{kind:'recurring',cron:'cron(0 9,17 * * ? *)',timezone:'America/Los_Angeles'},target:{outpostId:config.outpostId,instanceId:config.instanceId,machineUid:config.machineUid,attemptId:config.attemptId}});
  let now = Date.parse('2026-01-01T17:00:05Z');
  const transport = [], system = [], executions = [];
  let discovery = {jobs:[job],pending:[],recoverable:[]};
  let response;
  function delivery(firedAt='2026-01-01T17:00:00Z', extra={}) {
    return {messageId:`jobrun-job-Acceptance-${Date.parse(firedAt)}`,channel:'job',receivedAt:firedAt,requestId:'req_acceptance',companyUid:config.companyUid,agentUid:config.machineUid,jobId:job.jobId,prompt:job.prompt,...(job.script===undefined?{}:{script:job.script}),...(job.context===undefined?{}:{context:job.context}),firedAt,staleAfter:new Date(Date.parse(firedAt)+3600000).toISOString(),acceptedRevision:job.acceptedRevision,contentDigest:job.contentDigest,runId:hash(`${job.companyUid}:${job.jobId}:${job.acceptedRevision}:${firedAt}`),target:{...job.target},latestEditor:job.latestEditor,...extra};
  }
  response=delivery();
  const api=async(operation,body)=>{transport.push({operation,...body});assert.equal(operation,'jobs','unexpected transport operation');return structuredClone(body.action==='reconcile'?discovery:response);};
  const execute=async(command,args,options)=>{executions.push({command,args,options});return {code:0,text:JSON.stringify({disposition:'reply',outcome:'succeeded'})};};
  let runner=new CompanyRunner(config,api,{clock:()=>now,systemctl:args=>system.push(args),execute});
  t.after(()=>{runner.close();fs.rmSync(dir,{recursive:true,force:true});});
  return {dir,config,job,delivery,transport,system,executions,get runner(){return runner;},setDiscovery:d=>{discovery=d;},setDelivery:d=>{response=d;},setNow:n=>{now=Date.parse(n);},restart(){runner.close();runner=new CompanyRunner(config,api,{clock:()=>now,systemctl:a=>system.push(a),execute});},files:()=>fs.readdirSync(config.unitDir),receipt:id=>JSON.parse(runner.ledger.db.prepare('SELECT receipt FROM runs WHERE run_id=?').get(id).receipt)};
}

test('E2E1 accepted twice-daily API revision installs two timezone timers idempotently',async t=>{
  const f=harness(t);const result=await f.runner.reconcile();assert.equal(result.timers,2);
  const timers=f.files().filter(x=>x.endsWith('.timer')).sort();assert.equal(timers.length,2);
  assert.deepEqual(timers.map(x=>fs.readFileSync(path.join(f.config.unitDir,x),'utf8').match(/^OnCalendar=(.*)$/m)[1]),['*-*-* 09:00:00 America/Los_Angeles','*-*-* 17:00:00 America/Los_Angeles']);
  const before=timers.map(x=>fs.readFileSync(path.join(f.config.unitDir,x),'utf8'));
  await f.runner.reconcile();assert.deepEqual(f.files().filter(x=>x.endsWith('.timer')).sort(),timers);
  assert.deepEqual(timers.map(x=>fs.readFileSync(path.join(f.config.unitDir,x),'utf8')),before);
  for(const timer of timers)assert(f.system.some(a=>a.join(' ')===`enable --now ${timer}`));
  assert.equal(f.executions.length,0,'reconcile must leave execution to independent services');
});
test('E2E2 repeated scheduled issuance executes once across process-ledger restart',async t=>{
  const f=harness(t),d=f.delivery();await f.runner.run(f.job.jobId,revision);f.restart();await f.runner.run(f.job.jobId,revision);
  assert.equal(f.executions.length,1);assert.equal(f.receipt(d.runId).outcome,'succeeded');
  assert.deepEqual(f.transport.map(x=>x.action),['reconcile','scheduled','report','reconcile','scheduled']);
  // The duplicate second delivery returns before a receipt exists, so only the first run reports.
});
test('E2E3 two missed occurrences produce one latest-due coalesced execution',async t=>{
  const f=harness(t);await f.runner.run(f.job.jobId,revision);
  f.setNow('2026-01-02T17:00:10Z');const latest=f.delivery('2026-01-02T17:00:00Z');f.setDelivery(latest);
  f.setDiscovery({jobs:[f.job],pending:[],recoverable:[{jobId:f.job.jobId,revision,runId:f.delivery('2026-01-02T01:00:00Z').runId}]});
  await f.runner.reconcile();await f.runner.run(f.job.jobId,revision);await f.runner.run(f.job.jobId,revision);
  assert.equal(f.executions.length,2);assert.equal(f.receipt(latest.runId).coalesced,true);assert.equal(f.receipt(latest.runId).scheduledAt,latest.firedAt);
  assert.equal(f.runner.ledger.db.prepare('SELECT count(*) AS n FROM runs').get().n,2);
  assert(!f.transport.some(x=>x.action==='recover'),'old scheduled backlog must not be replayed');
});
test('E2E4 disable removes armed timers and rejects a stale service invocation',async t=>{
  const f=harness(t);await f.runner.reconcile();fs.writeFileSync(path.join(f.config.unitDir,'hq-job-personal.timer'),'preserve');
  f.setDiscovery({jobs:[],pending:[],recoverable:[]});await f.runner.reconcile();
  assert.deepEqual(f.files(),['hq-job-personal.timer']);assert.equal(f.system.filter(x=>x[0]==='disable'&&x[2].endsWith('.timer')).length,2);
  await assert.rejects(()=>f.runner.run(f.job.jobId,revision),/revision_not_current/);assert.equal(f.executions.length,0);
});
for(const mutation of ['proposal','paused','deleted','digest','instance'])test(`acceptance denies ${mutation} before timer installation`,async t=>{
  const f=harness(t),j=structuredClone(f.job);
  if(mutation==='proposal')delete j.acceptedRevision;
  if(mutation==='paused')j.status='paused';if(mutation==='deleted')j.deleted=true;
  if(mutation==='digest')j.prompt='unaccepted edit';if(mutation==='instance')j.target.instanceId='i-other';
  f.setDiscovery({jobs:[j],pending:[],recoverable:[]});
  const result=await f.runner.reconcile();
  assert.equal(result.jobs,0);assert.equal(result.rejected.length,1);assert.equal(result.errors,1);
  assert.equal(f.files().some(name=>name.startsWith('hq-company-job')),false);
  assert.equal(f.system.some(a=>a[0]==='enable'||a[0]==='start'),false);assert.equal(f.executions.length,0);
});
for(const status of [401,403,409,503])test(`scheduled HTTP ${status} never executes cached accepted content`,async t=>{
  const f=harness(t);f.runner.api=async(_op,b)=>{if(b.action==='reconcile')return {jobs:[f.job],pending:[],recoverable:[]};throw Object.assign(new Error('transport refusal'),{status});};
  if(status===409)assert.equal((await f.runner.run(f.job.jobId,revision)).outcome,'not_due_or_changed');else await assert.rejects(()=>f.runner.run(f.job.jobId,revision));
  assert.equal(f.executions.length,0);assert.equal(f.runner.ledger.db.prepare('SELECT count(*) AS n FROM runs').get().n,0);
});
test('malformed discovery cannot remove prior valid timers',async t=>{
  const f=harness(t);await f.runner.reconcile();const files=f.files();f.setDiscovery({jobs:[]});await assert.rejects(()=>f.runner.reconcile(),/invalid_reconcile/);assert.deepEqual(f.files(),files);
});
test('TTL boundary reclaims dead admission and fences the old owner',t=>{
  const f=harness(t),d=f.delivery(),old=f.runner.ledger.claim(d,100,1000);
  f.runner.ledger.db.prepare('UPDATE runs SET owner_identity=?').run('previous-process');
  assert.equal(f.runner.ledger.claim(d,100,1099),null);const next=f.runner.ledger.claim(d,100,1100);assert(next);
  assert.throws(()=>f.runner.ledger.finish(old,{outcome:'succeeded'}),/claim_fenced/);f.runner.ledger.finish(next,{outcome:'succeeded'});
  const other=new Ledger(f.config.stateDir);try{assert.equal(other.claim(d,100,999999),null);}finally{other.close();}
});
test('crash after admission records uncertain fingerprint without repeating effects',async t=>{
  const f=harness(t),d=f.delivery(),claim=f.runner.ledger.claim(d,100,1);f.runner.ledger.executing(claim);
  f.runner.ledger.db.prepare('UPDATE runs SET owner_identity=?').run('previous-process');
  const result=await f.runner.run(f.job.jobId,revision);assert.equal(result.outcome,'uncertain');assert.equal(result.errorCode,'supervisor_lost_after_admission');assert.equal(f.executions.length,0);
  assert.equal(f.receipt(d.runId).outcome,'uncertain');assert.equal(result.scheduledAt,d.firedAt);assert.equal(result.executionPrincipal,f.config.machineUid);assert(fs.readFileSync(result.outputLocation,'utf8').includes(d.runId));
});
test('same-instant manual UUIDs remain distinct and preserve requesting admin',async t=>{
  const f=harness(t);for(const runId of ['11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222']){
    const d=f.delivery(undefined,{runId,requestedBy:'prs_requester',requestedAt:'2026-01-01T16:59:00Z'});f.setDelivery(d);f.setDiscovery({jobs:[f.job],pending:[{jobId:f.job.jobId,revision,runId}],recoverable:[]});
    await f.runner.run(f.job.jobId,revision,runId);assert.equal(f.receipt(runId).requestedBy,'prs_requester');assert.equal(f.receipt(runId).latestEditor,'prs_editor');
  }assert.equal(f.executions.length,2);
});
test('runtime secret rotation uses company environment without persisted secret bytes',async t=>{
  const f=harness(t);f.job.context={companyJob:{secrets:['ACCEPTANCE_SECRET']}};seal(f.job);
  let value='SENTINEL_ONE';const seen=[];f.runner.api=async(op,b)=>{assert.equal(op,'secret');assert.deepEqual(b,{secretName:'ACCEPTANCE_SECRET'});return {value};};
  f.runner.execute=async(_cmd,_args,o)=>{seen.push(o.env.ACCEPTANCE_SECRET);assert.equal(o.env.HQ_MACHINE_AUTH_REQUIRED,undefined);assert.equal(o.env.HQ_MACHINE_CREDS_FILE,undefined);assert.equal(o.env.HQ_MACHINE_TOKEN_STATE_DIR,undefined);assert.equal(JSON.stringify(o.env).includes(f.config.stateDir),false);assert.equal(JSON.stringify(o.env).includes(f.config.machineCredsFile),false);assert.equal(o.env.HQ_COMPANY_UID,f.config.companyUid);return {code:0,text:'{"disposition":"reply"}'};};
  await f.runner.runDelivery(f.job,f.delivery());value='SENTINEL_TWO';await f.runner.runDelivery(f.job,f.delivery('2026-01-02T01:00:00Z'));assert.deepEqual(seen,['SENTINEL_ONE','SENTINEL_TWO']);
  for(const name of fs.readdirSync(f.config.stateDir))assert(!fs.readFileSync(path.join(f.config.stateDir,name)).includes(Buffer.from('SENTINEL_')),name);
  f.runner.api=async()=>{throw new Error('denied');};const denied=await f.runner.runDelivery(f.job,f.delivery('2026-01-02T17:00:00Z'));assert.equal(denied.outcome,'blocked');assert.equal(seen.length,2);
});
test('session timeout persists complete matching execution fingerprint',async t=>{
  const f=harness(t);f.job.context={companyJob:{timeoutSeconds:7}};seal(f.job);const d=f.delivery();f.setDelivery(d);
  f.runner.execute=async(_c,_a,o)=>{assert(o.timeout>0&&o.timeout<=7000);return {code:124,text:''};};
  const r=await f.runner.run(f.job.jobId,revision);assert.equal(r.outcome,'timeout');assert.equal(r.exitCode,124);
  const fingerprint=JSON.parse(fs.readFileSync(r.outputLocation,'utf8').split('\n')[0]).executionFingerprint;
  for(const [key,value]of Object.entries({jobId:f.job.jobId,revision,runId:d.runId,scheduledAt:d.firedAt,executionPrincipal:f.config.machineUid,machine:f.config.instanceId,contentDigest:d.contentDigest,registeredBy:'prs_registering',latestEditor:'prs_editor'})){assert.equal(r[key],value);assert.equal(fingerprint[key],value);}
  assert(Number.isFinite(Date.parse(r.startedAt)));assert(Number.isFinite(Date.parse(r.endedAt)));assert.deepEqual(f.receipt(d.runId),JSON.parse(JSON.stringify(r)));
});
test('bounded real child terminates on injected timer without GNU timeout',async t=>{
  t.mock.timers.enable({apis:['setTimeout']});let ready;const started=new Promise(r=>{ready=r;});
  const result=bounded(process.execPath,['-e',"process.stdout.write('READY\\n');setInterval(()=>{},1000)"],{timeout:5000,output:s=>{if(s.includes('READY'))ready();}});
  await started;t.mock.timers.tick(5000);assert.equal((await result).code,124);
});
test('wildcard minute schedules retain every minute in generated timers',async t=>{
  const f=harness(t);f.job.schedule={kind:'recurring',cron:'cron(* * * * ? *)',timezone:'UTC'};seal(f.job);await f.runner.reconcile();
  const timers=f.files().filter(x=>x.endsWith('.timer'));assert.equal(timers.length,24);
  for(const file of timers){const value=fs.readFileSync(path.join(f.config.unitDir,file),'utf8').match(/^OnCalendar=(.*)$/m)[1];assert.deepEqual(value.split(' ')[1].split(':')[1].split(',').map(Number),Array.from({length:60},(_,i)=>i));}
});
test('invalid timeout and reserved secret cannot arm accepted revision',async t=>{
  const f=harness(t);const codes=[];
  for(const companyJob of [{timeoutSeconds:0},{timeoutSeconds:14401},{secrets:['NODE_OPTIONS']},{secrets:['HQ_ACCESS_TOKEN']}]){
    f.job.context={companyJob};seal(f.job);const result=await f.runner.reconcile();
    assert.equal(result.jobs,0);codes.push(result.rejected[0].code);
  }
  assert.deepEqual(codes,['invalid_timeout','invalid_timeout','reserved_secret_name','reserved_secret_name']);
  assert.equal(f.files().some(name=>name.startsWith('hq-company-job')),false);assert.equal(f.executions.length,0);
});
test('entrypoint refuses invoking interactive account before cloud authentication',async t=>{
  const f=harness(t);fs.writeFileSync(f.config.configPath,JSON.stringify(f.config));
  await assert.rejects(()=>main(['reconcile',f.config.configPath]),/config_must_be_root_owned|dedicated_job_account_required/);
  assert(!fs.existsSync(f.config.cloudModule),'no cloud provider should have been loaded');
});
test('installation refuses non-root execution without changing supplied files',t=>{
  const f=harness(t);fs.writeFileSync(f.config.configPath,'{}');const before=fs.readFileSync(f.config.configPath);
  const bin=path.join(f.dir,'bin');fs.mkdirSync(bin);fs.writeFileSync(path.join(bin,'id'),'#!/bin/sh\necho 501\n',{mode:0o700});
  const r=spawnSync('/bin/bash',[path.join(scripts,'company-jobs-install.sh'),f.config.configPath],{env:{PATH:bin},encoding:'utf8',timeout:5000});assert.equal(r.status,2);assert.match(r.stderr,/requires root/);assert.deepEqual(fs.readFileSync(f.config.configPath),before);
});
test('auth adapter rejects human credentials before token refresh or fetch',async t=>{
  const f=harness(t),prior={...process.env};t.after(()=>{for(const k of Object.keys(process.env))if(!(k in prior))delete process.env[k];Object.assign(process.env,prior);});
  fs.writeFileSync(f.config.cloudModule,"export const loadMachineCreds=()=>({entityType:'human',entityUid:'prs_human'}); export const getValidMachineTokens=()=>{throw new Error('must not refresh')};");
  await assert.rejects(()=>apiClient(f.config),/company_machine_required/);
  const env=machineEnvironment(f.config);assert.equal(env.HQ_MACHINE_AUTH_REQUIRED,'1');assert.equal(env.HQ_REQUIRE_MACHINE_IDENTITY,'1');assert.equal(env.HQ_ACCESS_TOKEN,undefined);
});
test('log symlink refusal leaves unrelated sentinel and child untouched',async t=>{
  const f=harness(t),d=f.delivery(),sentinel=path.join(f.dir,'sentinel');fs.writeFileSync(sentinel,'unchanged');fs.symlinkSync(sentinel,path.join(f.config.stateDir,hash(d.runId)+'.log'));
  await assert.rejects(()=>f.runner.run(f.job.jobId,revision));assert.equal(fs.readFileSync(sentinel,'utf8'),'unchanged');assert.equal(f.executions.length,0);
});
