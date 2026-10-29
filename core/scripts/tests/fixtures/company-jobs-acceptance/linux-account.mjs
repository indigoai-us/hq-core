// hq-core: public
// Run only in a disposable Linux container as root. No network or systemd needed.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { main, contentDigest } from '../../../lib/company-jobs.mjs';

const dir='/tmp/us005-account';
const c={companyUid:'cmp_acceptance',companySlug:'indigo',machineUid:'out_machine',outpostId:'outpost_cmp_acceptance',instanceId:'i-test',attemptId:'attempt1',hqRoot:dir,stateDir:path.join(dir,'state'),unitDir:path.join(dir,'units'),configPath:path.join(dir,'config.json'),machineCredsFile:path.join(dir,'machine.json'),cloudModule:path.join(dir,'cloud.mjs'),apiUrl:'https://unused.invalid',provider:'codex'};
const j={ownerKind:'company-outpost',companyUid:c.companyUid,agentUid:c.outpostId,jobId:'job_Account',acceptedRevision:'93f90d54-1e8f-4a7a-90bd-9601397479be',status:'active',prompt:'uid probe',acceptedAt:'2026-01-01T00:00:00Z',schedule:{kind:'recurring',cron:'cron(0 9 * * ? *)',timezone:'UTC'},target:{machineUid:c.machineUid,outpostId:c.outpostId,instanceId:c.instanceId,attemptId:c.attemptId}};
j.contentDigest=contentDigest(j);
const firedAt='2026-01-02T09:00:00Z';
const d={companyUid:c.companyUid,agentUid:c.machineUid,jobId:j.jobId,acceptedRevision:j.acceptedRevision,contentDigest:j.contentDigest,prompt:j.prompt,target:j.target,firedAt,runId:crypto.createHash('sha256').update(`${j.companyUid}:${j.jobId}:${j.acceptedRevision}:${firedAt}`).digest('hex')};
if(process.argv[2]==='child'){
  assert.equal(process.platform,'linux');assert.notEqual(process.getuid(),0);
  globalThis.fetch=async(_url,options)=>{const body=JSON.parse(options.body);assert.equal(body.companyUid,c.companyUid);return {ok:true,json:async()=>body.action==='reconcile'?{jobs:[j],pending:[],recoverable:[]}:d};};
  await main(['run',c.configPath,j.jobId,j.acceptedRevision]);
}else{
  assert.equal(process.platform,'linux','disposable Linux only');assert.equal(process.getuid(),0,'container root required');
  const added=spawnSync('useradd',['--system','--create-home','--home-dir','/tmp/hq-jobs-home','hq-jobs'],{encoding:'utf8'});assert.equal(added.status,0,added.stderr);
  const uid=Number(spawnSync('id',['-u','hq-jobs'],{encoding:'utf8'}).stdout);assert(uid>0);
  fs.mkdirSync(path.join(dir,'core/scripts'),{recursive:true,mode:0o755});fs.chmodSync(dir,0o755);
  for(const p of [c.stateDir,c.unitDir]){fs.mkdirSync(p,{mode:0o700});fs.chownSync(p,uid,uid);}
  fs.writeFileSync(c.configPath,JSON.stringify(c),{mode:0o644});
  fs.writeFileSync(c.cloudModule,"export const loadMachineCreds=()=>({entityType:'company-outpost',entityUid:'out_machine',region:'test',clientId:'test'}); export const getValidMachineTokens=async()=>({idToken:'fake-test-token'});",{mode:0o644});
  fs.writeFileSync(path.join(dir,'probe.mjs'),`import fs from 'node:fs';fs.writeFileSync('${c.stateDir}/uid',String(process.getuid()));console.log(JSON.stringify({disposition:'reply',outcome:'complete'}));`,{mode:0o644});
  fs.writeFileSync(path.join(dir,'core/scripts/hq-agent-session.sh'),`#!/bin/bash\nexec /usr/local/bin/node ${dir}/probe.mjs\n`,{mode:0o755});
  const result=spawnSync('runuser',['-u','hq-jobs','--',process.execPath,fileURLToPath(import.meta.url),'child'],{encoding:'utf8',timeout:15000});
  assert.equal(result.status,0,result.stderr);const receipt=JSON.parse(result.stdout.trim());assert.equal(receipt.outcome,'succeeded');
  assert.equal(Number(fs.readFileSync(path.join(c.stateDir,'uid'),'utf8')),uid);assert.equal(fs.statSync(receipt.outputLocation).uid,uid);
  assert.equal(receipt.executionPrincipal,c.machineUid);assert.equal(receipt.machine,c.instanceId);
  console.log(JSON.stringify({check:'linux-effective-account',passed:true,uid,checks:5,systemd:false}));
}
