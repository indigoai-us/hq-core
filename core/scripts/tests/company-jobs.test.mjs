// hq-core: public
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { CompanyRunner, Ledger, calendars, occurrencesSince, contentDigest, acceptedJob, options, bounded, machineEnvironment, serviceTimeoutSeconds, transientCommand, runLockTtlMs, refreshMachineTokens, processStatus, jobRunUnitsActive, writeServiceEnvironment, secretRuntimeDirectory, prepareServiceMaterial, releaseSecretsAfterActive, runnerUnitAlive, serviceUnitActive, secretSourcesReady, sweepStaleSecretDirs, MACHINE_TOKEN_BUDGET_MS, COMPANY_API_BUDGET_MS } from '../lib/company-jobs.mjs';
const require = createRequire(import.meta.url);
function fixture(t){
 const dir=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'company-jobs-')));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
 const c={companyUid:'cmp_test',companySlug:'test',machineUid:'out_test',outpostId:'outpost_cmp_test',instanceId:'i-test',attemptId:'attempt1',hqRoot:dir,stateDir:path.join(dir,'state'),unitDir:path.join(dir,'units'),configPath:path.join(dir,'config.json'),machineCredsFile:'/not-read',provider:'codex'};
 const j={ownerKind:'company-outpost',companyUid:c.companyUid,agentUid:c.outpostId,jobId:'job_abc',acceptedRevision:'revision1',status:'active',prompt:'do work',target:{machineUid:c.machineUid,outpostId:c.outpostId,instanceId:c.instanceId,attemptId:c.attemptId},acceptedAt:'2026-01-01T00:00:00Z',schedule:{kind:'recurring',cron:'cron(0 9,17 * * ? *)',timezone:'America/Los_Angeles'}};
 j.contentDigest=contentDigest(j);
 const delivery=(runId='run1',firedAt='2026-01-02T01:00:00Z')=>({companyUid:c.companyUid,agentUid:c.machineUid,jobId:j.jobId,acceptedRevision:j.acceptedRevision,contentDigest:j.contentDigest,prompt:j.prompt,context:j.context,script:j.script,target:j.target,runId,firedAt});
 const calls=[];let executed=0,active=true;
 const api=async(op,body)=>{calls.push({op,...body});if(op==='secret')return {value:'SENTINEL_SECRET'};if(body.action==='reconcile')return {jobs:active?[j]:[],pending:[],recoverable:[]};return delivery();};
 const units=[];const r=new CompanyRunner(c,api,{systemctl:args=>units.push(args),execute:async()=>{executed++;return {code:0,text:'{"disposition":"reply"}'};}});t.after(()=>r.close());
 return {dir,c,j,r,delivery,calls,units,executed:()=>executed,disable:()=>{active=false;}};
}
test('twice daily accepted job installs two timezone timers; disable removes only owned units',async t=>{
 const f=fixture(t);await f.r.reconcile();const files=fs.readdirSync(f.c.unitDir);assert.equal(files.filter(s=>s.endsWith('.timer')).length,2);
 assert.match(fs.readFileSync(path.join(f.c.unitDir,'hq-company-job-job_abc-0.timer'),'utf8'),/09:00:00 America\/Los_Angeles/);
 assert.match(fs.readFileSync(path.join(f.c.unitDir,'hq-company-job-job_abc-1.timer'),'utf8'),/17:00:00 America\/Los_Angeles/);
 fs.writeFileSync(path.join(f.c.unitDir,'hq-job-personal.timer'),'keep');f.disable();await f.r.reconcile();assert.deepEqual(fs.readdirSync(f.c.unitDir),['hq-job-personal.timer']);assert(f.units.some(a=>a[0]==='disable'));
});
test('duplicate delivery executes once across ledger restart and after expiry',async t=>{const f=fixture(t);assert.equal((await f.r.runDelivery(f.j,f.delivery())).outcome,'succeeded');assert.equal((await f.r.runDelivery(f.j,f.delivery())).outcome,'duplicate');const l=new Ledger(f.c.stateDir);assert.equal(l.claim(f.delivery(),1,Date.now()+99999999),null);l.close();assert.equal(f.executed(),1);});
test('SECOND02 producer-accepted cron whitespace reconciles and coalesces consistently',async t=>{
 const f=fixture(t);for(const cron of ['cron( 0 9 * * ? * )','  cron(0 9 * * ? *)  ','cron(\t0\t9 * * ? *\t)']){
  f.j.schedule={kind:'recurring',cron,timezone:'UTC'};f.j.contentDigest=contentDigest(f.j);
  assert.deepEqual(calendars(f.j.schedule),['*-*-* 09:00:00 UTC']);
  assert.equal(occurrencesSince(f.j,Date.parse('2026-01-01T00:00:00Z'),Date.parse('2026-01-02T09:00:00Z')),2);
  assert.equal((await f.r.reconcile()).timers,1);
 }
});
test('producer-accepted rate whitespace and unit casing retain interval',async t=>{
 const f=fixture(t);f.j.schedule={kind:'recurring',cron:'rate( 2\tHOURS )',timezone:'UTC'};f.j.contentDigest=contentDigest(f.j);
 assert.deepEqual(calendars(f.j.schedule),['*-*-* *:*:00 UTC']);
 assert.equal(occurrencesSince(f.j,Date.parse(f.j.acceptedAt),Date.parse('2026-01-01T06:00:00Z')),3);
 assert.equal((await f.r.reconcile()).timers,1);
});
test('missed occurrences coalesce and historical scheduled recoverables do not replay',async t=>{const f=fixture(t);await f.r.runDelivery(f.j,f.delivery());const d=f.delivery('latest','2026-01-04T01:00:00Z');f.r.api=async(op,b)=>b.action==='reconcile'?{jobs:[f.j],pending:[],recoverable:[{jobId:f.j.jobId,revision:f.j.acceptedRevision,runId:'old1'}]}:b.action==='recover'?f.delivery('old1','2026-01-03T01:00:00Z'):d;await f.r.reconcile();await f.r.run(f.j.jobId,f.j.acceptedRevision);assert.equal(f.executed(),2);const row=f.r.ledger.db.prepare('SELECT receipt FROM runs WHERE run_id=?').get('latest');assert.equal(JSON.parse(row.receipt).coalesced,true);await f.r.reconcile();await f.r.run(f.j.jobId,f.j.acceptedRevision);assert.equal(f.executed(),2);});
test('distinct manual runs at same instant do not collapse',async t=>{const f=fixture(t);for(const id of ['manual1','manual2'])await f.r.runDelivery(f.j,{...f.delivery(id),requestedAt:'2026-01-02T01:00:00Z',requestedBy:'prs_admin'});assert.equal(f.executed(),2);});
for(const key of ['companyUid','machineUid','outpostId','instanceId','attemptId'])test(`rejects wrong ${key}`,async t=>{const f=fixture(t);const d=f.delivery();if(key==='companyUid')d[key]='cmp_foreign';else d.target={...d.target,[key]:'foreign'};await assert.rejects(()=>f.r.runDelivery(f.j,d));assert.equal(f.executed(),0);});
test('modified accepted content never executes',async t=>{const f=fixture(t);await assert.rejects(()=>f.r.runDelivery(f.j,{...f.delivery(),prompt:'tampered'}));assert.equal(f.executed(),0);});
test('unaccepted proposal and disabled definition cannot arm',t=>{const f=fixture(t);assert.throws(()=>acceptedJob(f.c,{...f.j,status:'paused'}));assert.throws(()=>acceptedJob(f.c,{...f.j,contentDigest:'bad'}));});
test('runtime secrets company scope, rotation, no persisted values and denial',async t=>{const f=fixture(t);f.j.context={companyJob:{secrets:['API_KEY']}};f.j.contentDigest=contentDigest(f.j);let value='ROTATED_ONE',seen=[];f.r.api=async(op,b)=>{assert.equal(op,'secret');assert.equal(b.secretName,'API_KEY');return {value};};f.r.execute=async(cmd,args,o)=>{seen.push(o.env.API_KEY);assert.equal(o.env.HQ_MACHINE_CREDS_FILE,undefined);assert.equal(o.env.HQ_MACHINE_TOKEN_STATE_DIR,undefined);assert.equal(o.env.HQ_MACHINE_AUTH_REQUIRED,undefined);assert.equal(JSON.stringify(o.env).includes(f.c.stateDir),false);return {code:0,text:'{"disposition":"reply"}'};};await f.r.runDelivery(f.j,f.delivery());value='ROTATED_TWO';await f.r.runDelivery(f.j,f.delivery('run2','2026-01-03T01:00:00Z'));assert.deepEqual(seen,['ROTATED_ONE','ROTATED_TWO']);f.r.api=async()=>{throw new Error('private backend error');};const result=await f.r.runDelivery(f.j,f.delivery('run3','2026-01-04T01:00:00Z'));assert.equal(result.outcome,'blocked');assert.equal(result.blockedSecret,'API_KEY');assert.equal(seen.length,2);for(const file of fs.readdirSync(f.c.stateDir)){assert(!fs.readFileSync(path.join(f.c.stateDir,file)).includes(Buffer.from('ROTATED_')));}});
test('claims reclaim abandoned admission with TTL, completed receipts persist',t=>{const f=fixture(t),d=f.delivery();const key=f.r.ledger.claim(d,100,100);assert(key);f.r.ledger.db.prepare('UPDATE runs SET owner=?').run(2147483647);assert.equal(f.r.ledger.claim(d,100,199),null);assert(f.r.ledger.claim(d,100,200));});
test('expired live owner does not overlap; interrupted execution is uncertain, not retried',t=>{const f=fixture(t),d=f.delivery();const key=f.r.ledger.claim(d,100,100);assert.throws(()=>f.r.ledger.claim(d,100,200),/owner_alive/);f.r.ledger.executing(key);f.r.ledger.db.prepare('UPDATE runs SET owner=?').run(2147483647);assert.equal(f.r.ledger.claim(d,100,200).uncertain,true);});
test('complete fingerprint emitted on failure',async t=>{const f=fixture(t);f.r.execute=async()=>({code:124,text:''});const r=await f.r.runDelivery(f.j,f.delivery());for(const k of ['jobId','revision','runId','scheduledAt','startedAt','endedAt','executionPrincipal','machine','outcome','outputLocation'])assert(r[k],k);assert.equal(r.outcome,'timeout');assert.match(fs.readFileSync(r.outputLocation,'utf8'),/executionFingerprint/);});
test('portable bounded process group kills grandchild ignoring TERM',{timeout:20000},async()=>{let text='';const start=Date.now();const r=await bounded('/bin/bash',['-c',"trap '' TERM; sleep 30 & echo $!; wait"],{timeout:150,output:s=>text+=s});assert.equal(r.code,124);assert(Date.now()-start<3000);const pid=Number(text.trim());assert(pid>0);try{process.kill(pid,0); const proc=fs.readFileSync(`/proc/${pid}/stat`,'utf8');assert.match(proc,/\) Z /);}catch(e){assert(['ESRCH','ENOENT'].includes(e.code));}});
test('secret chunks are redacted from captured output',async()=>{const r=await bounded(process.execPath,['-e',"process.stdout.write('ABC');setTimeout(()=>process.stdout.write('DEFG'),20)"],{timeout:1000,redactions:['ABCDEFG']});assert.equal(r.text,'[REDACTED]');});
test('wildcard minutes remain every minute and weekly/rate/once render',()=>{assert.match(calendars({kind:'recurring',cron:'cron(* * * * ? *)',timezone:'UTC'})[0],/00,01,02/);const hour9=calendars({kind:'recurring',cron:'cron(* 9 * * ? *)',timezone:'UTC'});assert.equal(hour9.length,1);assert.deepEqual(hour9[0].split(' ')[1].split(':')[1].split(',').map(Number),Array.from({length:60},(_,i)=>i));assert.doesNotMatch(hour9[0],/09:00:00/);assert.match(calendars({kind:'recurring',cron:'cron(0 9 ? * MON-FRI *)',timezone:'UTC'})[0],/^Mon,Tue,Wed,Thu,Fri/);assert.equal(calendars({kind:'recurring',cron:'rate(12 hours)',timezone:'UTC'}).length,1);assert.match(calendars({kind:'once',at:'2026-01-01T00:00:00Z',timezone:'UTC'})[0],/UTC$/);});
test('unsafe run ids cannot escape the unit directory; a real pending id still arms',async t=>{
  const f=fixture(t);const runId='11111111-1111-4111-8111-111111111111';const escape='x/../../outside';
  f.r.api=async(_op,body)=>body.action==='reconcile'?{jobs:[f.j],pending:[{runId:escape,jobId:f.j.jobId,revision:f.j.acceptedRevision},{runId,jobId:f.j.jobId,revision:f.j.acceptedRevision}],recoverable:[{runId:'not a uuid',jobId:f.j.jobId,revision:f.j.acceptedRevision}]}:f.delivery();
  const outside=path.join(f.dir,'outside.service');
  assert.equal(path.normalize(path.join(f.c.unitDir,`hq-company-job-${f.j.jobId}-${escape}.service`)),outside);
  assert.equal(outside.startsWith(f.c.unitDir+path.sep),false);
  await f.r.reconcile();
  assert.equal(fs.existsSync(outside),false);
  const unit=path.join(f.c.unitDir,`hq-company-job-${f.j.jobId}-${runId}.service`);
  assert.match(fs.readFileSync(unit,'utf8'),new RegExp(runId));
  assert.equal(fs.readdirSync(f.c.unitDir).some(name=>name.includes('..')||name.includes('outside')),false);
});
test('unknown orphan units are removed and a dead user bus is not treated as removal',async t=>{
  const f=fixture(t);fs.mkdirSync(f.c.unitDir,{recursive:true,mode:0o700});const orphan=path.join(f.c.unitDir,'hq-company-job-old.timer');fs.writeFileSync(orphan,'stale');f.disable();
  f.r.systemctl=args=>{if(args[0]==='disable')throw new Error('Failed to disable unit: Unit file hq-company-job-old.timer does not exist.');};
  await f.r.reconcile();assert.equal(fs.existsSync(orphan),false);
  fs.writeFileSync(orphan,'stale');f.r.systemctl=()=>{throw new Error('Failed to connect to bus: No such file or directory');};
  await assert.rejects(()=>f.r.reconcile(),/bus/);assert.equal(fs.readFileSync(orphan,'utf8'),'stale');
});
test('invalid timeout and reserved secret env rejected',()=>{for(const timeoutSeconds of [0,-1,14401,'600'])assert.throws(()=>options({context:{companyJob:{timeoutSeconds}}}));assert.throws(()=>options({context:{companyJob:{secrets:['NODE_OPTIONS']}}}));});
test('API failure preserves timers and cannot execute cached content',async t=>{const f=fixture(t);await f.r.reconcile();const before=fs.readdirSync(f.c.unitDir);f.r.api=async()=>{throw new Error('offline');};await assert.rejects(()=>f.r.reconcile());assert.deepEqual(fs.readdirSync(f.c.unitDir),before);});
test('human auth is not inherited into the company process',t=>{const f=fixture(t);process.env.HQ_ACCESS_TOKEN='poison';const env=machineEnvironment(f.c);assert.equal(env.HQ_ACCESS_TOKEN,undefined);assert.equal(env.HQ_MACHINE_AUTH_REQUIRED,'1');delete process.env.HQ_ACCESS_TOKEN;});
test('configured API provider key is resolved through company broker for each run',async t=>{const f=fixture(t);f.c.providerSecret='CODEX_API_KEY';let key;f.r.execute=async(_c,_a,o)=>{key=o.env.CODEX_API_KEY;return {code:0,text:'{"disposition":"reply"}'};};assert.equal((await f.r.runDelivery(f.j,f.delivery())).outcome,'succeeded');assert.equal(key,'SENTINEL_SECRET');assert(f.calls.some(c=>c.op==='secret'&&c.secretName==='CODEX_API_KEY'));f.r.api=async()=>{throw Error('denied');};assert.equal((await f.r.runDelivery(f.j,f.delivery('second','2026-01-03T01:00:00Z'))).outcome,'blocked');});
test('timer enable failure is surfaced',async t=>{const f=fixture(t);f.r.systemctl=()=>{throw new Error('no user manager');};await assert.rejects(()=>f.r.reconcile(),/user manager/);assert.equal(f.executed(),0);});
test('SEC01 log symlink cannot overwrite sentinel',async t=>{const f=fixture(t);const sentinel=path.join(f.dir,'sentinel');fs.writeFileSync(sentinel,'preserve');fs.symlinkSync(sentinel,path.join(f.c.stateDir,crypto.createHash('sha256').update('run1').digest('hex')+'.log'));await assert.rejects(()=>f.r.runDelivery(f.j,f.delivery()));assert.equal(fs.readFileSync(sentinel,'utf8'),'preserve');assert.equal(f.executed(),0);});
test('SEC01 state and SQLite symlinks are rejected',t=>{const f=fixture(t);const other=path.join(f.dir,'other');fs.mkdirSync(other,{mode:0o700});const link=path.join(f.dir,'link');fs.symlinkSync(other,link);assert.throws(()=>new Ledger(link),/symlink/);const sentinel=path.join(f.dir,'sentinel');fs.writeFileSync(sentinel,'preserve');fs.symlinkSync(sentinel,path.join(other,'runs.sqlite'));assert.throws(()=>new Ledger(other),/unsafe_ledger/);assert.equal(fs.readFileSync(sentinel,'utf8'),'preserve');});
test('SEC02 recycled live PID is reclaimable and old acquisition is fenced',t=>{const f=fixture(t),d=f.delivery();const old=f.r.ledger.claim(d,100,100);f.r.ledger.db.prepare('UPDATE runs SET owner_identity=?').run('old-boot:old-start');const current=f.r.ledger.claim(d,100,200);assert(current);assert.throws(()=>f.r.ledger.finish(old,{outcome:'bad'}),/fenced/);f.r.ledger.finish(current,{outcome:'succeeded'});});
test('SEC03 uncertain crash emits complete report and never repeats effect',async t=>{const f=fixture(t),d=f.delivery();const claim=f.r.ledger.claim(d,100,1);f.r.ledger.executing(claim);f.r.ledger.db.prepare('UPDATE runs SET owner_identity=?').run('old-boot:start');const result=await f.r.runDelivery(f.j,d);assert.equal(result.outcome,'uncertain');assert.equal(f.executed(),0);for(const k of ['jobId','revision','runId','scheduledAt','startedAt','endedAt','executionPrincipal','machine','outputLocation'])assert(result[k],k);assert.match(fs.readFileSync(result.outputLocation,'utf8'),/supervisor_lost_after_admission/);assert.equal(JSON.parse(f.r.ledger.db.prepare('SELECT receipt FROM runs').get().receipt).outcome,'uncertain');});
test('FINAL02 repeated recovery crashes preserve execution admission and never repeat effects',async t=>{
 const f=fixture(t),d=f.delivery(),claim=f.r.ledger.claim(d,1,1);f.r.ledger.executing(claim);
 for(let now=2;now<=4;now++){
  f.r.ledger.db.prepare('UPDATE runs SET owner_identity=?').run('dead-owner');
  const recovery=f.r.ledger.claim(d,1,now);assert.equal(recovery.uncertain,true);
  assert.equal(f.r.ledger.db.prepare('SELECT state FROM runs').get().state,'executing');
 }
 f.r.ledger.db.prepare('UPDATE runs SET owner_identity=?').run('dead-owner');
 const result=await f.r.runDelivery(f.j,d);assert.equal(result.outcome,'uncertain');assert.equal(f.executed(),0);
 assert(result.startedAt&&result.endedAt&&result.outputLocation);assert.equal((await f.r.runDelivery(f.j,d)).outcome,'duplicate');
});
test('FINAL03 successful session JSON stays valid with redacted stderr diagnostics',async t=>{
 const f=fixture(t);f.j.context={companyJob:{secrets:['API_KEY']}};f.j.contentDigest=contentDigest(f.j);
 let captured;f.r.execute=async(_command,_args,o)=>captured=await bounded(process.execPath,['-e',`process.stdout.write(JSON.stringify({disposition:'reply',text:'complete'}));process.stderr.write('recoverable hook diagnostic SENTINEL_');setTimeout(()=>process.stderr.write('SECRET'),20);`],{...o,scope:undefined,enterScope:false,enterService:false,systemctl:undefined});
 const result=await f.r.runDelivery(f.j,f.delivery());assert.equal(result.outcome,'succeeded');
 assert.equal(captured.stderr,'recoverable hook diagnostic [REDACTED]');assert.equal(JSON.parse(captured.text).disposition,'reply');
 const log=fs.readFileSync(result.outputLocation,'utf8');assert.match(log,/\[REDACTED\]/);assert(!log.includes('SENTINEL_SECRET'));
});
test('SEC04/05 reconcile supervises jobs separately and reports launch errors',async t=>{const f=fixture(t);f.j.context={companyJob:{timeoutSeconds:14400}};f.j.contentDigest=contentDigest(f.j);await f.r.reconcile();assert.equal(f.executed(),0);assert(f.units.some(a=>a.join(' ')==='start --no-block hq-company-job-job_abc.service'));const unit=fs.readFileSync(path.join(f.c.unitDir,'hq-company-job-job_abc.service'),'utf8');const callSeconds=(MACHINE_TOKEN_BUDGET_MS+COMPANY_API_BUDGET_MS)/1000;
assert.match(unit,new RegExp(`TimeoutStartSec=${14400*2+3*callSeconds+30}`));assert.match(unit,/User=root/);assert.match(unit,/Environment=HQ_RUNNER_UNIT=%n/);assert.match(unit,/KillMode=control-group/);assert.doesNotMatch(unit,/NoNewPrivileges/);assert.equal(serviceTimeoutSeconds(14400,0),14400*2+3*callSeconds+30);assert.equal(serviceTimeoutSeconds(600,3),600*2+6*callSeconds+30);f.r.systemctl=args=>{if(args[0]==='start')throw new Error('launch failed');};await assert.rejects(()=>f.r.reconcile(),/launch failed/);});
test('job launch passes only allowlisted secrets and refuses to run as the runner',async t=>{
  const f=fixture(t);const other=process.getuid()===65534?65533:65534;
  f.c.jobUid=other;f.c.jobGid=other;f.j.context={companyJob:{secrets:['API_KEY']}};f.j.contentDigest=contentDigest(f.j);
  let seen,secretCalls=0;
  f.r.api=async(op,b)=>{assert.equal(op,'secret');assert.deepEqual(b,{secretName:'API_KEY'});secretCalls++;return {value:'SENTINEL_SECRET'};};
  f.r.execute=async(_c,_a,o)=>{seen=o;return {code:0,text:'{"disposition":"reply"}'};};
  const ok=await f.r.runDelivery(f.j,f.delivery());
  assert.equal(ok.outcome,'succeeded');assert.equal(seen.uid,other);assert.equal(seen.gid,other);
  assert.equal(seen.env.API_KEY,'SENTINEL_SECRET');
  assert.equal(seen.env.HQ_MACHINE_CREDS_FILE,undefined);assert.equal(seen.env.HQ_MACHINE_TOKEN_STATE_DIR,undefined);
  assert.equal(seen.env.HQ_MACHINE_AUTH_REQUIRED,undefined);assert.equal(JSON.stringify(seen.env).includes(f.c.stateDir),false);
  f.c.jobUid=process.getuid();f.c.jobGid=process.getgid();let called=false;
  f.r.api=async()=>{throw new Error('secret fetch must not run when the job is not isolated');};
  f.r.execute=async()=>{called=true;return {code:0,text:'{}'};};
  const blocked=await f.r.runDelivery(f.j,f.delivery('run-same-uid','2026-01-05T01:00:00Z'));
  assert.equal(blocked.outcome,'failed');assert.equal(blocked.errorCode,'job_not_isolated');assert.equal(called,false);assert.equal(secretCalls,1);
});
test('optional broker scope adds the job and run only when enabled',async t=>{
  const f=fixture(t);f.c.brokerSecretScope=true;f.j.context={companyJob:{secrets:['API_KEY']}};f.j.contentDigest=contentDigest(f.j);
  f.r.api=async(_op,b)=>{assert.deepEqual(b,{secretName:'API_KEY',jobId:f.j.jobId,runId:'run1'});return {value:'SENTINEL_SECRET'};};
  f.r.execute=async()=>({code:0,text:'{"disposition":"reply"}'});
  assert.equal((await f.r.runDelivery(f.j,f.delivery())).outcome,'succeeded');
});
test('a refused privilege drop never starts a process that can read credentials or the ledger',{timeout:20000},async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'company-jobs-drop-'));
  try{
    const creds=path.join(dir,'creds'),ledger=path.join(dir,'ledger'),marker=path.join(dir,'marker');
    fs.writeFileSync(creds,'SECRET',{mode:0o600});fs.mkdirSync(ledger,{mode:0o700});fs.writeFileSync(path.join(ledger,'runs.sqlite'),'ledger',{mode:0o600});
    const uid=process.getuid()===65534?65533:65534;
    let dropped=false;
    try{
      const result=await bounded('/bin/bash',['-c','cat "$1" >"$2"; ls "$3" >>"$2"','bash',creds,marker,ledger],{uid,gid:uid,timeout:2000});
      dropped=true;const text=fs.existsSync(marker)?fs.readFileSync(marker,'utf8'):'';
      assert.equal(text.includes('SECRET'),false);assert.notEqual(result.code,0);
    }catch(error){
      assert.equal(dropped,false);assert.equal(error.code,'EPERM');assert.equal(fs.existsSync(marker),false);
    }
    assert.equal(fs.readFileSync(path.join(ledger,'runs.sqlite'),'utf8'),'ledger');
  }finally{fs.rmSync(dir,{recursive:true,force:true});}
});
test('a long-lived unrelated process with a recycled-looking PID survives a job timeout',{timeout:20000},async()=>{
  const unrelated=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{detached:true,stdio:'ignore'});
  unrelated.unref();
  const born=spawn(process.execPath,['-e','process.exit(0)'],{stdio:'ignore'});
  const recycled=born.pid;
  if (born.exitCode === null && born.signalCode === null) {
    await new Promise(resolve => born.once('exit', resolve));
  }
  const signaled=[];
  const original=process.kill.bind(process);
  process.kill=(target,signal)=>{signaled.push(target);return original(target,signal);};
  const stopped=[];
  try{
    const result=await bounded('/bin/bash',['-c','sleep 30'],{timeout:300,unit:'hq-company-job-run-recycle.service',enterService:false,systemctl:args=>stopped.push(args.slice())});
    assert.equal(result.code,124);
    assert.equal(signaled.includes(unrelated.pid),false);
    assert.equal(signaled.includes(-unrelated.pid),false);
    assert.equal(signaled.includes(recycled),false);
    original(unrelated.pid,0);
    assert.equal(stopped.some(args=>args[0]==='kill'&&args.includes('hq-company-job-run-recycle.service')),true);
    assert.equal(stopped.some(args=>args[0]==='stop'&&args.includes('hq-company-job-run-recycle.service')),true);
    assert.equal(signaled.every(target=>target<0),true);
  }finally{
    process.kill=original;
    try{original(unrelated.pid,'SIGKILL');}catch{/* already dead */}
  }
});
test('numeric weekday and minute ranges render; an unknown weekday is reported per job',async t=>{
  const rendered=calendars({kind:'recurring',cron:'cron(0-30/15 9 * * 2-6 *)',timezone:'UTC'});
  assert.equal(rendered.length,1);assert.match(rendered[0],/^Mon,Tue,Wed,Thu,Fri /);assert.match(rendered[0],/09:00,15,30:00 UTC$/);
  assert.throws(()=>calendars({kind:'recurring',cron:'cron(0 9 * * 8 *)',timezone:'UTC'}),/unsupported_weekday/);
  const f=fixture(t);const bad={...f.j,jobId:'job_bad',schedule:{kind:'recurring',cron:'cron(0 9 * * 8 *)',timezone:'UTC'}};
  bad.contentDigest=contentDigest(bad);
  f.r.api=async(_op,body)=>body.action==='reconcile'?{jobs:[bad,f.j],pending:[],recoverable:[]}:f.delivery();
  const result=await f.r.reconcile();
  assert.equal(result.jobs,1);assert.equal(result.errors,1);assert.deepEqual(result.rejected,[{jobId:'job_bad',code:'unsupported_weekday'}]);
  assert.equal(processStatus('reconcile',result),1);
  assert.equal(processStatus('reconcile',{jobs:1,errors:0}),0);
  assert.equal(processStatus('run',{outcome:'succeeded'}),0);
  assert.equal(processStatus('run',{outcome:'skipped_lock_busy'}),0);
  for (const outcome of ['failed','blocked','timeout','uncertain']) assert.equal(processStatus('run',{outcome}),1);
  assert.equal(['failed','blocked','timeout','uncertain'].includes(result.outcome),false);
  assert.equal(fs.existsSync(path.join(f.c.unitDir,'hq-company-job-job_abc.service')),true);
  assert.equal(fs.existsSync(path.join(f.c.unitDir,'hq-company-job-job_bad.service')),false);
});
test('systemd ExecStart stores a dollar as $$',async t=>{
  const f=fixture(t);f.c.hqRoot='/tmp/company$jobs';await f.r.reconcile();
  const unit=fs.readFileSync(path.join(f.c.unitDir,'hq-company-job-job_abc.service'),'utf8');
  assert.match(unit,/\/tmp\/company\$\$jobs/);assert.equal(unit.includes('/tmp/company$jobs'),false);
});
test('job termination does not poll the process table',()=>{
  const source=fs.readFileSync(new URL('../lib/company-jobs.mjs',import.meta.url),'utf8');
  assert.equal(source.includes("'-ax'"),false);
  assert.equal(source.includes('function descendants'),false);
  assert.equal(source.includes('setInterval('),false);
  assert.equal(source.includes('fs.chmodSync'),false);
  assert.equal(source.includes('fs.chownSync'),false);
  assert.equal(source.includes('--scope'),false);
  assert.equal(source.includes('SetCredential='),false);
  assert.match(source,/workingDirectory: cwd/);
  assert.match(source,/--property=Type=exec/);
  assert.match(source,/secretSourcesReady\(unit\)/);
  assert.match(source,/sweepStaleSecretDirs\(secretRuntimeDirectory\(c\)\)/);
  assert.equal(source.includes('dropServiceEnvironment'),false);
});
test('a transient service binds the job to the runner cgroup',()=>{
  const wrapped=transientCommand('/bin/bash',['script'],{unit:'hq-company-job-run-run_1.service',user:'hq-jobs',runtimeSec:600,runnerUnit:'hq-company-job-job_abc.service',envFile:'/var/lib/hq-job-runner/state/env-run_1',workingDirectory:'/opt/hq'});
  assert.equal(wrapped.command,'systemd-run');
  assert.equal(wrapped.args.includes('--property=KillMode=control-group'),true);
  assert.equal(wrapped.args.includes('--property=SendSIGKILL=yes'),true);
  assert.equal(wrapped.args.includes('--unit=hq-company-job-run-run_1.service'),true);
  assert.equal(wrapped.args.includes('--property=Type=exec'),true);
  assert.ok(wrapped.args.indexOf('--property=Type=exec')<wrapped.args.indexOf('--'));
  assert.equal(wrapped.args.includes('--property=User=hq-jobs'),true);
  assert.equal(wrapped.args.includes('--property=RuntimeMaxSec=600'),true);
  assert.equal(wrapped.args.includes('--property=PartOf=hq-company-job-job_abc.service'),true);
  assert.equal(wrapped.args.includes('--property=BindsTo=hq-company-job-job_abc.service'),true);
  assert.equal(wrapped.args.includes('--property=EnvironmentFile=/var/lib/hq-job-runner/state/env-run_1'),true);
  assert.equal(wrapped.args.includes('--working-directory=/opt/hq'),true);
  assert.ok(wrapped.args.indexOf('--working-directory=/opt/hq')<wrapped.args.indexOf('--'));
  assert.equal(wrapped.args.includes('--scope'),false);
  assert.equal(wrapped.args.some(arg=>arg.includes('SetCredential=')),false);
  assert.equal(wrapped.args.at(-1),'script');
  const spaced=transientCommand('/bin/bash',['script'],{unit:'hq-company-job-run-run_1.service',user:'hq-jobs',runtimeSec:600,runnerUnit:'hq-company-job-job_abc.service',workingDirectory:'/opt/hq root'});
  assert.equal(spaced.args.includes('--working-directory=/opt/hq root'),true);
});
test('a fresh company job lock blocks overlap and a stale lock is reclaimed',t=>{
  const f=fixture(t);
  const held=f.r.ledger.acquireRunLock({runId:'run1',ttlMs:1000,now:5000});
  assert.ok(held);
  assert.equal(f.r.ledger.acquireRunLock({runId:'run2',ttlMs:1000,now:5999}),null);
  const reclaimed=f.r.ledger.acquireRunLock({runId:'run2',ttlMs:1000,now:6000,unitsActive:false});
  assert.ok(reclaimed);
  assert.equal(f.r.ledger.acquireRunLock({runId:'run3',ttlMs:1000,now:999999,unitsActive:true}),null);
  assert.notEqual(reclaimed.token,held.token);
  assert.equal(f.r.ledger.releaseRunLock(held),false);
  assert.equal(f.r.ledger.releaseRunLock(reclaimed),true);
  assert.equal(runLockTtlMs({}),21600000);
  assert.equal(runLockTtlMs({},{HQ_COMPANY_JOBS_LOCK_TTL_SECONDS:'90'}),90000);
});
test('two company jobs never execute at the same time',async t=>{
  const f=fixture(t);
  f.c.lockPollMs=30;
  let entered=0;
  let release;
  const gate=new Promise(resolve=>{release=resolve;});
  f.r.execute=async()=>{entered+=1;await gate;return {code:0,text:'{"disposition":"reply"}'};};
  const first=f.r.runDelivery(f.j,f.delivery('run-lock-1','2026-01-02T01:00:00Z'));
  for(let i=0;i<50&&entered<1;i++)await new Promise(resolve=>setTimeout(resolve,10));
  assert.equal(entered,1);
  const second=f.r.runDelivery(f.j,f.delivery('run-lock-2','2026-01-03T01:00:00Z'));
  await new Promise(resolve=>setTimeout(resolve,40));
  assert.equal(entered,1);
  release();
  await Promise.all([first,second]);
  assert.equal(entered,2);
});
test('losing the run lock is recorded and not swallowed',async t=>{
  const f=fixture(t);
  f.r.execute=async()=>{f.r.ledger.db.prepare('UPDATE run_lock SET token=?').run('stolen');return {code:0,text:'{"disposition":"reply"}'};};
  await assert.rejects(()=>f.r.runDelivery(f.j,f.delivery()),/run_lock_lost/);
  const receipt=JSON.parse(f.r.ledger.db.prepare('SELECT receipt FROM runs').get().receipt);
  assert.equal(receipt.lockRelease,'lost');
  assert.equal(receipt.outcome,'succeeded');
});
test('a later run cannot read the previous run transcript',async t=>{
  const f=fixture(t);
  f.c.jobHome=path.join(f.dir,'jobhome');
  fs.mkdirSync(f.c.jobHome,{mode:0o700});
  const homes=[];
  f.r.execute=async(_command,_args,options)=>{
    homes.push(options.env.HOME);
    fs.writeFileSync(path.join(options.env.HOME,'transcript'),'SENTINEL_SECRET');
    return {code:0,text:'{"disposition":"reply"}'};
  };
  await f.r.runDelivery(f.j,f.delivery('run-home-1','2026-01-02T01:00:00Z'));
  assert.equal(fs.existsSync(homes[0]),false);
  await f.r.runDelivery(f.j,f.delivery('run-home-2','2026-01-03T01:00:00Z'));
  assert.notEqual(homes[0],homes[1]);
  assert.equal(fs.existsSync(homes[1]),false);
  const texts=[];
  const walk=dir=>{for(const name of fs.readdirSync(dir)){const full=path.join(dir,name);if(fs.statSync(full).isDirectory())walk(full);else texts.push(fs.readFileSync(full,'utf8'));}};
  walk(f.c.jobHome);
  assert.equal(texts.some(text=>text.includes('SENTINEL_SECRET')),false);
});
test('a hung machine-token refresh is rejected inside its budget',async()=>{
  const started=Date.now();
  await assert.rejects(refreshMachineTokens({getValidMachineTokens:()=>new Promise(()=>{})},{region:'r',clientId:'c'},300),/machine_token_timeout/);
  const elapsed=Date.now()-started;
  assert.ok(elapsed>=250&&elapsed<2000,String(elapsed));
  const source=fs.readFileSync(new URL('../lib/company-jobs.mjs',import.meta.url),'utf8');
  assert.match(source,/refreshMachineTokens\(cloud, creds\)/);
  assert.match(source,/budgetMs = MACHINE_TOKEN_BUDGET_MS/);
  assert.equal(serviceTimeoutSeconds(14400,0),14400*2+3*((MACHINE_TOKEN_BUDGET_MS+COMPANY_API_BUDGET_MS)/1000)+30);
});
test('an ec2-user owned core/scripts/lib is refused',()=>{
  const {assertReleasedCode}=require('../lib/released-code-owner.cjs');
  const ec2User=1000;
  const node=(uid,mode,symlink=false)=>({uid,mode,isSymbolicLink:()=>symlink});
  const entries=new Map([
    ['/',node(0,0o755)],
    ['/opt',node(0,0o755)],
    ['/opt/hq',node(0,0o755)],
    ['/opt/hq/core',node(0,0o755)],
    ['/opt/hq/core/scripts',node(0,0o755)],
    ['/opt/hq/core/scripts/lib',node(ec2User,0o755)],
    ['/opt/hq/core/scripts/lib/company-jobs.mjs',node(0,0o644)],
    ['/opt/company-cloud.mjs',node(0,0o644)],
    ['/usr',node(0,0o755)],
    ['/usr/bin',node(0,0o755)],
    ['/usr/bin/node',node(0,0o755)],
  ]);
  const lstat=target=>{const stat=entries.get(target);if(!stat)throw Object.assign(new Error('missing '+target),{code:'ENOENT'});return stat;};
  const paths=['/opt/hq','/opt/hq/core','/opt/hq/core/scripts','/opt/hq/core/scripts/lib','/opt/hq/core/scripts/lib/company-jobs.mjs','/opt/company-cloud.mjs','/usr/bin/node'];
  assert.throws(()=>assertReleasedCode(paths,lstat),/Released code must be root owned/);
  entries.set('/opt/hq/core/scripts/lib',node(0,0o755));
  assert.doesNotThrow(()=>assertReleasedCode(paths,lstat));
  entries.set('/opt/hq/core/scripts/lib/company-jobs.mjs',node(ec2User,0o644));
  assert.throws(()=>assertReleasedCode(paths,lstat),/Released code must be root owned/);
  entries.set('/opt/hq/core/scripts/lib/company-jobs.mjs',node(0,0o644));
  entries.set('/usr/bin',node(0,0o777));
  assert.throws(()=>assertReleasedCode(paths,lstat),/Released code must be root owned/);
  entries.set('/usr/bin',node(0,0o755));
  entries.set('/opt/hq/core/scripts/lib',node(0,0o755,true));
  assert.throws(()=>assertReleasedCode(paths,lstat),/Symlink refused/);
  const installer=fs.readFileSync(new URL('../company-jobs-install.sh',import.meta.url),'utf8');
  const helper=fs.readFileSync(new URL('../lib/released-code-owner.cjs',import.meta.url),'utf8');
  assert.equal(helper.includes('function assertReleasedCode'),true);
  assert.equal(installer.includes("require(process.argv[2]+'/core/scripts/lib/released-code-owner.cjs')"),true);
  assert.equal(installer.includes("root+'/core/scripts/lib/company-jobs.mjs'"),true);
  assert.equal(installer.includes("root+'/core/scripts/hq-agent-session.sh'"),true);
  assert.equal(installer.includes("root+'/core/scripts/outpost-jobs-reconcile.sh'"),true);
  assert.equal(installer.includes("root+'/core/scripts/hq-job-run.sh'"),true);
  assert.equal(installer.includes("root+'/core/scripts/company-job-with-credentials.sh'"),true);
  assert.match(installer,/config\.secretRuntimeDir = '\/run\/hq-company-jobs'/);
  assert.equal(installer.includes('fs.realpathSync(nodeBinary)'),true);
  assert.match(installer,/install -d -m 755 -o root -g root \/var\/lib\/hq-company-jobs \/var\/lib\/hq-company-jobs\/runs/);
  assert.match(installer,/install -d -m 700 -o hq-jobs -g hq-jobs "\$PROJECTS"/);
});
test('a symlink where the run home or its parent would be is refused and the outside target is unchanged',async t=>{
  const f=fixture(t);
  const outside=path.join(f.dir,'outside');
  fs.mkdirSync(outside,{mode:0o755});
  const sentinel=path.join(outside,'keep');
  fs.writeFileSync(sentinel,'preserve',{mode:0o644});
  const before=fs.lstatSync(sentinel);
  f.c.jobHome=path.join(f.dir,'jobhome');
  fs.mkdirSync(f.c.jobHome,{mode:0o755});
  fs.symlinkSync(outside,path.join(f.c.jobHome,'runs'));
  assert.throws(()=>f.r.prepareRunHome('run1',{uid:1,gid:1,user:'hq-jobs'}),/run_home_symlink/);
  assert.equal(fs.readFileSync(sentinel,'utf8'),'preserve');
  assert.equal(fs.lstatSync(sentinel).ino,before.ino);
  assert.equal(fs.lstatSync(sentinel).mode,before.mode);
  assert.deepEqual(fs.readdirSync(outside),['keep']);
  fs.unlinkSync(path.join(f.c.jobHome,'runs'));
  fs.mkdirSync(path.join(f.c.jobHome,'runs'),{mode:0o755});
  fs.symlinkSync(sentinel,path.join(f.c.jobHome,'runs','run-link'));
  const refused=await f.r.runDelivery(f.j,f.delivery('run-link','2026-01-02T01:00:00Z'));
  assert.equal(refused.outcome,'failed');
  assert.equal(refused.errorCode,'run_home_symlink');
  assert.equal(f.executed(),0);
  assert.equal(fs.readFileSync(sentinel,'utf8'),'preserve');
  assert.equal(fs.lstatSync(sentinel).ino,before.ino);
  assert.equal(fs.lstatSync(path.join(f.c.jobHome,'runs','run-link')).isSymbolicLink(),true);
});
test('cleanup removes a run-home symlink entry and leaves its outside target',async t=>{
  const f=fixture(t);
  const sentinel=path.join(f.dir,'root-owned-target');
  fs.writeFileSync(sentinel,'preserve-root',{mode:0o444});
  const before=fs.lstatSync(sentinel);
  f.c.jobHome=path.join(f.dir,'jobhome');
  fs.mkdirSync(f.c.jobHome,{mode:0o755});
  let home;
  let goneBeforeRelease=false;
  const release=f.r.ledger.releaseRunLock.bind(f.r.ledger);
  f.r.ledger.releaseRunLock=lock=>{goneBeforeRelease=Boolean(home)&&!fs.existsSync(home);return release(lock);};
  f.r.execute=async(_command,_args,options)=>{
    home=options.env.HOME;
    fs.symlinkSync(sentinel,path.join(home,'planted'));
    return {code:0,text:'{"disposition":"reply"}'};
  };
  const result=await f.r.runDelivery(f.j,f.delivery('run-clean','2026-01-02T01:00:00Z'));
  assert.equal(result.outcome,'succeeded');
  assert.equal(goneBeforeRelease,true);
  assert.equal(fs.existsSync(home),false);
  assert.equal(fs.readFileSync(sentinel,'utf8'),'preserve-root');
  assert.equal(fs.lstatSync(sentinel).ino,before.ino);
  const source=fs.readFileSync(new URL('../lib/company-jobs.mjs',import.meta.url),'utf8');
  const body=source.slice(source.indexOf('async runDelivery'),source.indexOf('function lstatOrNull'));
  const fin=body.slice(body.indexOf('finally{'));
  assert.ok(fin.indexOf('removeRunHome(')>=0&&fin.indexOf('removeRunHome(')<fin.indexOf('release()'));
  assert.match(source,/runuser/);
  assert.match(source,/fs\.rmdirSync\(target\)/);
});
test('an active job-run unit blocks lock reclaim and the service stops with the runner',async t=>{
  const f=fixture(t);
  f.r.unitsActive=()=>true;
  f.c.lockWaitMs=20;
  f.c.lockPollMs=10;
  const held=f.r.ledger.acquireRunLock({runId:'live',ttlMs:1000,now:1000,unitsActive:false});
  f.r.clock=()=>999999;
  assert.equal(await f.r.waitForRunLock('next',1),null);
  f.r.unitsActive=()=>false;
  const took=await f.r.waitForRunLock('next',1);
  assert.ok(took);
  assert.equal(took.reclaimed,true);
  assert.equal(f.r.ledger.releaseRunLock(held),false);
  assert.equal(f.r.ledger.releaseRunLock(took),true);
  assert.equal(jobRunUnitsActive(()=>({error:{code:'ENOENT'}})),false);
  assert.equal(jobRunUnitsActive(()=>({status:1,stdout:''})),true);
  assert.equal(jobRunUnitsActive(()=>({status:0,stdout:''})),false);
  assert.equal(jobRunUnitsActive(()=>({status:0,stdout:'hq-company-job-run-abc.service loaded active running\n'})),true);
  let seen;
  f.r.execute=async(_c,_a,o)=>{seen=o;return {code:0,text:'{"disposition":"reply"}'};};
  assert.equal((await f.r.runDelivery(f.j,f.delivery('run-svc','2026-01-06T01:00:00Z'))).outcome,'succeeded');
  assert.equal(seen.enterService,true);
  assert.equal(seen.unit,'hq-company-job-run-run-svc.service');
  assert.equal(seen.runnerUnit,'hq-company-job-job_abc.service');
  assert.equal(seen.serviceUser,'hq-jobs');
  assert.equal(seen.cwd,f.c.hqRoot);
  assert.equal(seen.envFileDir,'/run/hq-company-jobs');
  assert.notEqual(path.resolve(seen.envFileDir),path.resolve(f.c.stateDir));
  assert.deepEqual(seen.secretNames,[]);
});
test('lock wait does not shrink the job budget and a busy lock stays recoverable',async t=>{
  const f=fixture(t);
  f.r.unitsActive=()=>false;
  f.j.context={companyJob:{timeoutSeconds:10}};
  f.j.contentDigest=contentDigest(f.j);
  let now=1000000;
  f.r.clock=()=>now;
  f.c.lockPollMs=5;
  f.c.lockWaitMs=20000;
  let attempts=0;
  const orig=f.r.ledger.acquireRunLock.bind(f.r.ledger);
  f.r.ledger.acquireRunLock=opts=>{attempts+=1;if(attempts===1){now+=4000;return null;}return orig(opts);};
  let seen;
  f.r.execute=async(_c,_a,o)=>{seen=o.timeout;return {code:0,text:'{"disposition":"reply"}'};};
  const ran=await f.r.runDelivery(f.j,f.delivery('run-budget','2026-01-02T01:00:00Z'));
  assert.equal(ran.outcome,'succeeded');
  assert.equal(seen,10000);
  assert.ok(attempts>=2);
  f.r.ledger.acquireRunLock=orig;
  const held=f.r.ledger.acquireRunLock({runId:'holder',ttlMs:600000,now,unitsActive:false});
  f.c.lockWaitMs=30;
  f.c.lockPollMs=10;
  const skipped=await f.r.runDelivery(f.j,f.delivery('run-busy','2026-01-03T01:00:00Z'));
  assert.equal(skipped.outcome,'skipped_lock_busy');
  assert.equal(f.r.ledger.completed('run-busy'),false);
  assert.equal(f.r.ledger.db.prepare('SELECT state FROM runs WHERE run_id=?').get('run-busy'),undefined);
  const receipt=path.join(f.c.stateDir,crypto.createHash('sha256').update('run-busy').digest('hex')+'.json');
  assert.equal(JSON.parse(fs.readFileSync(receipt,'utf8')).outcome,'skipped_lock_busy');
  assert.equal(f.r.ledger.releaseRunLock(held),true);
  const recovered=await f.r.runDelivery(f.j,f.delivery('run-busy','2026-01-03T01:00:00Z'));
  assert.equal(recovered.outcome,'succeeded');
});
test('service secrets are written to a mode 0600 env file and never placed on argv',t=>{
  const f=fixture(t);
  const file=writeServiceEnvironment(f.c.stateDir,'run1',{API_KEY:'SENTINEL_SECRET',PATH:'/usr/bin'});
  assert.equal(fs.statSync(file).mode&0o777,0o600);
  assert.match(fs.readFileSync(file,'utf8'),/API_KEY="SENTINEL_SECRET"/);
  const wrapped=transientCommand('/bin/bash',['script'],{unit:'hq-company-job-run-run1.service',user:'hq-jobs',runtimeSec:10,runnerUnit:'hq-company-job-job_abc.service',envFile:file});
  assert.equal(wrapped.args.some(arg=>arg.includes('SENTINEL_SECRET')),false);
  assert.equal(wrapped.args.some(arg=>arg.includes('SetCredential=')),false);
  fs.unlinkSync(file);
  assert.equal(fs.existsSync(file),false);
  assert.throws(()=>writeServiceEnvironment(f.c.stateDir,'run1',{API_KEY:'line\nTWO'}));
});
test('a dead runner lock is reclaimed while its ttl remains and a live job-run unit still blocks',t=>{
  const f=fixture(t);
  const held=f.r.ledger.acquireRunLock({runId:'run1',ttlMs:21600000,now:5000,runnerUnit:'hq-company-job-job_abc.service',holderAlive:true});
  assert.ok(held);
  assert.equal(f.r.ledger.db.prepare('SELECT runner_unit FROM run_lock WHERE id=1').get().runner_unit,'hq-company-job-job_abc.service');
  assert.equal(f.r.ledger.acquireRunLock({runId:'run2',ttlMs:21600000,now:6000,holderAlive:true}),null);
  const reclaimed=f.r.ledger.acquireRunLock({runId:'run2',ttlMs:21600000,now:6000,holderAlive:false,unitsActive:false});
  assert.ok(reclaimed);
  assert.equal(reclaimed.reclaimed,true);
  assert.equal(f.r.ledger.acquireRunLock({runId:'run3',ttlMs:1000,now:999999,unitsActive:true,holderAlive:false}),null);
  assert.equal(f.r.ledger.releaseRunLock(held),false);
  assert.equal(runnerUnitAlive(null,()=>({status:0,stdout:'inactive\n'})),true);
  assert.equal(runnerUnitAlive('hq-company-job-job_abc.service',()=>({status:0,stdout:'inactive\n'})),false);
  assert.equal(runnerUnitAlive('hq-company-job-job_abc.service',()=>({status:0,stdout:'failed\n'})),false);
  assert.equal(runnerUnitAlive('hq-company-job-job_abc.service',()=>({status:0,stdout:'dead\n'})),false);
  assert.equal(runnerUnitAlive('hq-company-job-job_abc.service',()=>({status:0,stdout:'active\n'})),true);
  assert.equal(runnerUnitAlive('hq-company-job-job_abc.service',()=>({status:0,stdout:'activating\n'})),true);
  assert.equal(runnerUnitAlive('hq-company-job-job_abc.service',()=>({error:{code:'ENOENT'}})),true);
  assert.equal(runnerUnitAlive('hq-company-job-job_abc.service',()=>({status:1,stdout:''})),true);
  assert.equal(runnerUnitAlive('hq-company-job-job_abc.service',()=>({status:0,stdout:''})),true);
  assert.equal(runnerUnitAlive('hq-company-job-job_abc.service',()=>({status:0,stdout:'ActiveState=inactive\nLoadState=not-found\n'})),true);
  assert.equal(runnerUnitAlive('hq-company-job-job_abc.service',()=>({status:0,stdout:'ActiveState=inactive\nLoadState=loaded\n'})),false);
  assert.equal(runnerUnitAlive('hq-company-job-job_abc.service',()=>({status:0,stdout:'inactive\nnot-found\n'})),true);
  assert.equal(serviceUnitActive('hq-company-job-run-run1.service',()=>({error:{code:'ENOENT'}})),false);
  assert.equal(serviceUnitActive('hq-company-job-run-run1.service',()=>({status:0,stdout:'active\n'})),true);
  assert.equal(serviceUnitActive('hq-company-job-run-run1.service',()=>({status:3,stdout:'activating\n'})),false);
  assert.equal(serviceUnitActive('hq-company-job-run-run1.service',()=>({status:0,stdout:'inactive\n'})),false);
  assert.equal(secretSourcesReady('hq-company-job-run-run1.service',()=>({status:0,stdout:'ActiveState=active\nType=exec\n'})),true);
  assert.equal(secretSourcesReady('hq-company-job-run-run1.service',()=>({status:0,stdout:'ActiveState=active\nType=simple\n'})),false);
  assert.equal(secretSourcesReady('hq-company-job-run-run1.service',()=>({status:0,stdout:'ActiveState=activating\nType=exec\n'})),false);
  assert.equal(secretSourcesReady('hq-company-job-run-run1.service',()=>({error:{code:'ENOENT'}})),false);
});
test('a crashed holder of the same job is reclaimed on the next tick',async t=>{
  const f=fixture(t);
  const now=5000000;
  f.r.clock=()=>now;
  f.r.unitsActive=()=>false;
  f.c.lockWaitMs=40;
  f.c.lockPollMs=10;
  const crashed='run-dead';
  const held=f.r.ledger.acquireRunLock({runId:crashed,ttlMs:21600000,now,runnerUnit:`hq-company-job-run-${crashed}.service`,holderAlive:true});
  assert.equal(f.r.ledger.db.prepare('SELECT runner_unit FROM run_lock').get().runner_unit,`hq-company-job-run-${crashed}.service`);
  const probed=[];
  f.r.runnerAlive=unit=>{probed.push(unit);return unit==='hq-company-job-job_abc.service';};
  const orig=f.r.ledger.acquireRunLock.bind(f.r.ledger);
  let recorded;
  f.r.ledger.acquireRunLock=opts=>{recorded=opts.runnerUnit;return orig(opts);};
  const next=await f.r.runDelivery(f.j,f.delivery('run-next','2026-01-03T01:00:00Z'));
  assert.equal(next.outcome,'succeeded');
  assert.equal(recorded,'hq-company-job-run-run-next.service');
  assert.equal(probed.includes(`hq-company-job-run-${crashed}.service`),true);
  assert.equal(probed.includes('hq-company-job-job_abc.service'),false);
  assert.equal(f.r.ledger.releaseRunLock(held),false);
});
test('a collected per-run unit is reclaimed only after its owner exits',async t=>{
  const f=fixture(t);
  const child=spawn(process.execPath,['-e','process.exit(0)'],{stdio:'ignore'});
  const dead=child.pid;
  await new Promise(resolve=>{child.once('exit',resolve);if(child.exitCode!==null)resolve();});
  const missing={alive:true,missing:true};
  const held=f.r.ledger.acquireRunLock({runId:'run-dead',ttlMs:21600000,now:5000,owner:dead,runnerUnit:'hq-company-job-run-run-dead.service'});
  assert.ok(held);
  const reclaimed=f.r.ledger.acquireRunLock({runId:'run-next',ttlMs:21600000,now:6000,unitProbe:missing});
  assert.ok(reclaimed);
  assert.equal(reclaimed.reclaimed,true);
  assert.equal(f.r.ledger.acquireRunLock({runId:'run-wait',ttlMs:21600000,now:7000,unitProbe:missing}),null);
});
test('the lock unit probe does not hold the sqlite write transaction',t=>{
  const f=fixture(t);
  f.r.ledger.acquireRunLock({runId:'held',ttlMs:1000,now:1000,runnerUnit:'hq-company-job-run-held.service',holderAlive:true});
  let wroteDuringProbe=false;
  const result=f.r.ledger.acquireRunLock({runId:'next',ttlMs:1000,now:1001,unitAlive:()=>{
    const other=new Ledger(f.c.stateDir);
    try{
      other.db.exec('PRAGMA busy_timeout=200');
      other.db.exec('BEGIN IMMEDIATE');
      wroteDuringProbe=true;
      other.db.exec('ROLLBACK');
    }finally{other.close();}
    return false;
  }});
  assert.equal(wroteDuringProbe,true);
  assert.ok(result);
  assert.equal(f.r.ledger.db.prepare('SELECT run_id FROM run_lock WHERE id=1').get().run_id,'next');
});
test('runner start removes stale secret dirs and keeps an active run',t=>{
  const f=fixture(t);
  const runtime=path.join(f.dir,'run');
  fs.mkdirSync(runtime,{mode:0o700});
  const outside=path.join(f.dir,'outside');
  fs.writeFileSync(outside,'preserve');
  const stale=path.join(runtime,'run-stale');
  fs.mkdirSync(stale,{mode:0o700});
  fs.writeFileSync(path.join(stale,'API_KEY'),'SECRET',{mode:0o600});
  fs.symlinkSync(outside,path.join(stale,'planted'));
  const live=path.join(runtime,'run-live');
  fs.mkdirSync(live,{mode:0o700});
  fs.writeFileSync(path.join(live,'API_KEY'),'LIVE',{mode:0o600});
  const pre=path.join(runtime,'run-pre');
  fs.mkdirSync(pre,{mode:0o700});
  fs.writeFileSync(path.join(pre,'API_KEY'),'PRE',{mode:0o600});
  fs.mkdirSync(path.join(runtime,'tokens'),{mode:0o700});
  fs.writeFileSync(path.join(runtime,'tokens','machine'),'token',{mode:0o600});
  fs.symlinkSync(outside,path.join(runtime,'run-link'));
  assert.deepEqual(sweepStaleSecretDirs(runtime,unit=>runnerUnitAlive(unit,()=>({error:{code:'ENOENT'}}))),[]);
  assert.equal(fs.existsSync(stale),true);
  const removed=sweepStaleSecretDirs(runtime,unit=>unit==='hq-company-job-run-run-live.service'||unit==='hq-company-job-run-run-pre-pre.service');
  assert.deepEqual(removed,['run-stale']);
  assert.equal(fs.existsSync(stale),false);
  assert.equal(fs.readFileSync(outside,'utf8'),'preserve');
  assert.equal(fs.readFileSync(path.join(live,'API_KEY'),'utf8'),'LIVE');
  assert.equal(fs.readFileSync(path.join(pre,'API_KEY'),'utf8'),'PRE');
  assert.equal(fs.readFileSync(path.join(runtime,'tokens','machine'),'utf8'),'token');
  assert.equal(fs.lstatSync(path.join(runtime,'run-link')).isSymbolicLink(),true);
});
test('a busy lock does not advance last and the next scheduled run coalesces',async t=>{
  const f=fixture(t);
  f.r.unitsActive=()=>false;
  const first=await f.r.runDelivery(f.j,f.delivery('run-first','2026-01-02T01:00:00Z'));
  assert.equal(first.outcome,'succeeded');
  assert.equal(f.r.ledger.last(f.j.jobId),'2026-01-02T01:00:00Z');
  const held=f.r.ledger.acquireRunLock({runId:'holder',ttlMs:600000,now:Date.now()});
  f.c.lockWaitMs=30;
  f.c.lockPollMs=10;
  const skipped=await f.r.runDelivery(f.j,f.delivery('run-busy','2026-01-03T01:00:00Z'));
  assert.equal(skipped.outcome,'skipped_lock_busy');
  assert.equal(f.r.ledger.last(f.j.jobId),'2026-01-02T01:00:00Z');
  assert.equal(f.r.ledger.completed('run-busy'),false);
  assert.equal(f.r.ledger.db.prepare('SELECT state FROM runs WHERE run_id=?').get('run-busy'),undefined);
  assert.equal(f.r.ledger.releaseRunLock(held),true);
  const later=await f.r.runDelivery(f.j,f.delivery('run-later','2026-01-04T01:00:00Z'));
  assert.equal(later.outcome,'succeeded');
  assert.equal(later.coalesced,true);
});
test('multiline secrets are credential files on the runtime dir and never reach argv',t=>{
  const f=fixture(t);
  const runtime=path.join(f.dir,'runtime');
  fs.mkdirSync(runtime,{mode:0o700});
  const pem='-----BEGIN-----\nline two\n-----END-----\n';
  const material=prepareServiceMaterial(runtime,'run1',{API_KEY:pem,PATH:'/usr/bin',HOME:'/var/lib/hq-company-jobs'},['API_KEY']);
  assert.equal(fs.readFileSync(path.join(material.dir,'API_KEY'),'utf8'),pem);
  assert.equal(fs.readFileSync(material.envFile,'utf8').includes('BEGIN'),false);
  assert.equal(fs.statSync(material.dir).mode&0o777,0o700);
  assert.equal(fs.statSync(path.join(material.dir,'API_KEY')).mode&0o777,0o600);
  const wrapped=transientCommand('/bin/bash',['script'],{unit:'hq-company-job-run-run1.service',user:'hq-jobs',runtimeSec:10,runnerUnit:'hq-company-job-job_abc.service',envFile:material.envFile,workingDirectory:'/opt/hq',credentials:material.credentials,wrapper:'/opt/hq/core/scripts/company-job-with-credentials.sh'});
  const joined=wrapped.args.join('\n');
  assert.equal(joined.includes(pem),false);
  assert.equal(joined.includes('BEGIN'),false);
  assert.equal(wrapped.args.some(arg=>arg.startsWith('--property=LoadCredential=API_KEY:')),true);
  assert.equal(wrapped.args.includes('--working-directory=/opt/hq'),true);
  assert.equal(wrapped.args.some(arg=>arg.includes('SetCredential=')),false);
  assert.ok(wrapped.args.indexOf('--working-directory=/opt/hq')<wrapped.args.indexOf('--'));
  assert.equal(wrapped.args[wrapped.args.indexOf('--')+1],'/opt/hq/core/scripts/company-job-with-credentials.sh');
  fs.rmSync(material.dir,{recursive:true,force:true});
  assert.throws(()=>prepareServiceMaterial(runtime,'run-nul',{API_KEY:'a\0b'},['API_KEY']),/invalid_env_value/);
  assert.equal(secretRuntimeDirectory(f.c),'/run/hq-company-jobs');
  assert.throws(()=>secretRuntimeDirectory({...f.c,secretRuntimeDir:f.c.stateDir}),/secret_runtime_persistent/);
});
test('a symlink secret runtime dir is refused and the outside dir stays empty',t=>{
  const f=fixture(t);
  const outside=path.join(f.dir,'outside-secrets');
  fs.mkdirSync(outside,{mode:0o700});
  const runtime=path.join(f.dir,'runtime');
  fs.mkdirSync(runtime,{mode:0o700});
  fs.symlinkSync(outside,path.join(runtime,'run1'));
  assert.throws(()=>prepareServiceMaterial(runtime,'run1',{API_KEY:'pem\nline'},['API_KEY']),/secret_runtime_symlink/);
  assert.deepEqual(fs.readdirSync(outside),[]);
  assert.equal(fs.lstatSync(path.join(runtime,'run1')).isSymbolicLink(),true);
});
test('credential loader preserves multiline secret bytes',async t=>{
  const f=fixture(t);
  const pem='-----BEGIN-----\nline two\n-----END-----\n';
  const dir=path.join(f.dir,'creds');
  fs.mkdirSync(dir,{mode:0o700});
  fs.writeFileSync(path.join(dir,'names'),'API_KEY\n',{mode:0o600});
  fs.writeFileSync(path.join(dir,'API_KEY'),pem,{mode:0o600});
  const script=new URL('../company-job-with-credentials.sh',import.meta.url);
  const result=await new Promise((resolve,reject)=>{
    const child=spawn('/bin/sh',[script.pathname,process.execPath,'-e','process.stdout.write(process.env.API_KEY ?? "")'],{env:{PATH:process.env.PATH,CREDENTIALS_DIRECTORY:dir}});
    let out='',err='';
    child.stdout.on('data',chunk=>out+=chunk);
    child.stderr.on('data',chunk=>err+=chunk);
    child.on('error',reject);
    child.on('close',code=>resolve({code,out,err}));
  });
  assert.equal(result.err,'');
  assert.equal(result.code,0);
  assert.equal(result.out,pem);
});
test('secrets stay on disk until the job unit is active and then the directory is removed',async t=>{
  const f=fixture(t);
  const home=path.join(f.dir,'secret-home');
  fs.mkdirSync(home,{mode:0o700});
  fs.writeFileSync(path.join(home,'API_KEY'),'secret',{mode:0o600});
  const pending=await releaseSecretsAfterActive(home,()=>false,{intervalMs:10,budgetMs:40});
  assert.equal(pending,'pending');
  assert.equal(fs.readFileSync(path.join(home,'API_KEY'),'utf8'),'secret');
  let active=false;
  const waiting=releaseSecretsAfterActive(home,()=>active,{intervalMs:10,budgetMs:500});
  await new Promise(resolve=>setTimeout(resolve,30));
  assert.equal(fs.existsSync(path.join(home,'API_KEY')),true);
  active=true;
  assert.equal(await waiting,'released');
  assert.equal(fs.existsSync(home),false);
});

// Mirrors hq-pro-agents src/outpost/company-job-freshness.ts parseCompanyJobReport, the server's report contract.
function serverAcceptsReport(b){
 return b.action==='report'&&/^job_[A-Za-z0-9]+$/.test(b.jobId)&&typeof b.revision==='string'&&b.revision.length>=1&&b.revision.length<=80
  &&/^(?:[a-f0-9-]{36}|[a-f0-9]{64})$/.test(b.runId)&&Number.isFinite(Date.parse(b.scheduledAt))&&Number.isFinite(Date.parse(b.endedAt))
  &&typeof b.outcome==='string'&&/^[a-z0-9_-]{1,64}$/.test(b.outcome)&&(!('exitCode' in b)||Number.isFinite(b.exitCode))&&(!('coalesced' in b)||typeof b.coalesced==='boolean');
}
const RUN_A='a'.repeat(64), RUN_B='b'.repeat(64);
test('reconcile posts a jobs heartbeat on every tick before reconciling',async t=>{const f=fixture(t);await f.r.reconcile();await f.r.reconcile();const beats=f.calls.filter(c=>c.op==='jobs'&&c.action==='heartbeat');assert.equal(beats.length,2);assert.deepEqual(beats[0],{op:'jobs',action:'heartbeat'});const first=f.calls.findIndex(c=>c.action==='heartbeat');assert(first<f.calls.findIndex(c=>c.action==='reconcile'));});
test('heartbeat failure is logged and does not break reconcile',async t=>{const f=fixture(t);const warnings=[];f.r.warn=l=>warnings.push(l);const inner=f.r.api;f.r.api=async(op,b)=>{if(b.action==='heartbeat'){const e=new Error('x');e.status=503;throw e;}return inner(op,b);};const result=await f.r.reconcile();assert.equal(result.jobs,1);assert.equal(warnings.length,1);assert.equal(JSON.parse(warnings[0]).event,'heartbeat_post_failed');assert.equal(JSON.parse(warnings[0]).status,503);});
test('successful run posts a report in the server contract shape',async t=>{const f=fixture(t);const receipt=await f.r.runDelivery(f.j,f.delivery(RUN_A));assert.equal(receipt.outcome,'succeeded');const reports=f.calls.filter(c=>c.action==='report');assert.equal(reports.length,1);const {op,...body}=reports[0];assert.equal(op,'jobs');assert(serverAcceptsReport(body),JSON.stringify(body));assert.equal(body.scheduledAt,'2026-01-02T01:00:00Z');assert.equal(body.runId,RUN_A);assert.equal(body.revision,'revision1');assert.equal(body.outcome,'succeeded');assert.equal(body.exitCode,0);assert.equal(body.endedAt,receipt.endedAt);});
test('secret_denied run reports outcome blocked with its error code',async t=>{const f=fixture(t);f.j.context={companyJob:{secrets:['API_KEY']}};f.j.contentDigest=contentDigest(f.j);const sent=[];f.r.api=async(op,b)=>{if(op==='secret')throw new Error('denied');sent.push({op,...b});return {ok:true};};const receipt=await f.r.runDelivery(f.j,f.delivery(RUN_B));assert.equal(receipt.outcome,'blocked');assert.equal(f.executed(),0);assert.equal(sent.length,1);const {op,...body}=sent[0];assert.equal(op,'jobs');assert(serverAcceptsReport(body));assert.equal(body.outcome,'blocked');assert.equal(body.errorCode,'secret_denied');assert.equal(body.scheduledAt,'2026-01-02T01:00:00Z');});
test('failed and timed-out runs post reports with outcome and error code',async t=>{const f=fixture(t);let code=1;f.r.execute=async()=>({code,text:''});assert.equal((await f.r.runDelivery(f.j,f.delivery(RUN_A))).outcome,'failed');code=124;assert.equal((await f.r.runDelivery(f.j,f.delivery(RUN_B,'2026-01-02T17:00:00Z'))).outcome,'timeout');const reports=f.calls.filter(c=>c.action==='report');assert.deepEqual(reports.map(r=>[r.outcome,r.exitCode]),[['failed',1],['timeout',124]]);for(const r of reports){const {op,...b}=r;assert(serverAcceptsReport(b));}});
test('report failure is logged and does not change the receipt',async t=>{const f=fixture(t);const warnings=[];f.r.warn=l=>warnings.push(l);f.r.api=async(op,b)=>{if(b.action==='report')throw new Error('offline');return {};};const receipt=await f.r.runDelivery(f.j,f.delivery(RUN_A));assert.equal(receipt.outcome,'succeeded');assert.equal(warnings.length,1);const w=JSON.parse(warnings[0]);assert.equal(w.event,'report_post_failed');assert.equal(w.runId,RUN_A);assert.equal(w.outcome,'succeeded');const stored=JSON.parse(fs.readFileSync(fs.readdirSync(f.c.stateDir).filter(n=>n.endsWith('.json')).map(n=>path.join(f.c.stateDir,n))[0],'utf8'));assert.equal(stored.outcome,'succeeded');});
