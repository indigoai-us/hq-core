#!/usr/bin/env bash
# hq-core: public
# Install from the released HQ tree; config contains no secret values.
set -euo pipefail
CONFIG="${1:-/etc/hq/company-jobs.json}"
[ "$(id -u)" = 0 ] || { echo 'company jobs install requires root' >&2; exit 2; }
[ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || { echo 'company job config missing' >&2; exit 2; }
for prerequisite in node jq systemctl loginctl useradd getent runuser; do
  command -v "$prerequisite" >/dev/null || { echo "missing prerequisite: $prerequisite" >&2; exit 2; }
done
node --input-type=module -e 'import { DatabaseSync } from "node:sqlite"; new DatabaseSync(":memory:").close()'
node -e 'const fs=require("node:fs"),s=fs.lstatSync(process.argv[1]);if(!s.isFile()||s.uid!==0||(s.mode&0o022))process.exit(2)' "$CONFIG"
ROOT="$(jq -er '.hqRoot' "$CONFIG")"
CREDS="$(jq -er '.machineCredsFile' "$CONFIG")"
CLOUD="$(jq -er '.cloudModule' "$CONFIG")"
SLUG="$(jq -er '.companySlug' "$CONFIG")"
[[ "$SLUG" =~ ^[A-Za-z0-9_-]+$ ]] || exit 2
PROJECTS="$ROOT/companies/$SLUG/projects"
NODE="$(node -p 'process.execPath')"
for value in "$ROOT" "$CONFIG" "$CREDS" "$CLOUD" "$NODE"; do
  [[ "$value" = /* && "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *%* && "$value" != *\"* && "$value" != *\\* ]] || exit 2
done
node - "$ROOT" "$CREDS" "$CONFIG" "$PROJECTS" "$CLOUD" "$NODE" <<'PATHS'
const fs=require('node:fs'),path=require('node:path');
const check=p=>{for(let q=path.resolve(p);;q=path.dirname(q)){try{if(fs.lstatSync(q).isSymbolicLink())throw Error('Symlink refused');}catch(e){if(e.code!=='ENOENT')throw e;}if(q===path.dirname(q))break;}};
for(const p of [process.argv[2],process.argv[3],process.argv[4],process.argv[5],process.argv[6],'/var/lib/hq-job-runner/state','/run/hq-company-jobs/tokens'])check(p);
const {assertReleasedCode}=require(process.argv[2]+'/core/scripts/lib/released-code-owner.cjs');
const nodeBinary = process.argv[7];
const root = process.argv[2];
assertReleasedCode([
  root,
  root+'/core',
  root+'/core/scripts',
  root+'/core/scripts/lib',
  root+'/core/scripts/lib/company-jobs.mjs',
  root+'/core/scripts/lib/released-code-owner.cjs',
  root+'/core/scripts/hq-agent-session.sh',
  root+'/core/scripts/outpost-jobs-reconcile.sh',
  root+'/core/scripts/hq-job-run.sh',
  root+'/core/scripts/company-job-with-credentials.sh',
  root+'/core/scripts/lib/company-signin.mjs',
  process.argv[6],
  fs.realpathSync(nodeBinary),
]);
PATHS
for script in lib/company-jobs.mjs lib/company-signin.mjs hq-agent-session.sh outpost-jobs-reconcile.sh hq-job-run.sh company-job-with-credentials.sh; do
  [ -s "$ROOT/core/scripts/$script" ] || { echo "release missing $script" >&2; exit 2; }
done
[ -r "$CREDS" ] || { echo 'company machine credentials not provisioned' >&2; exit 2; }
jq -e '.entityType == "company-outpost"' "$CREDS" >/dev/null
# An existing job account must already be a locked-down system user. Refuse a
# shell or an extra group instead of trusting whatever useradd left behind.
ensure_system_account() {
  local name="$1" home="$2" current shell extra
  if getent passwd "$name" >/dev/null; then
    current="$(getent passwd "$name")"
    shell="${current##*:}"
    case "$shell" in
      */nologin|*/false) ;;
      *) echo "$name shell is not nologin" >&2; exit 2 ;;
    esac
    if [ "$(id -gn "$name")" != "$name" ]; then
      echo "$name primary group is not $name" >&2
      exit 2
    fi
    extra="$(id -nG "$name" | tr ' ' '\n' | grep -vx "$name" || true)"
    if [ -n "$extra" ]; then
      echo "$name has unexpected groups" >&2
      exit 2
    fi
  else
    useradd --system --create-home --home-dir "$home" --shell /usr/sbin/nologin "$name"
  fi
  [ "$(id -u "$name")" != 0 ] || exit 2
}
ensure_system_account hq-jobs /var/lib/hq-company-jobs
# Box sign-in mode (no broker provider secret): a separate account owns the
# Claude sign-in. hq-jobs never reads its home; the root runner passes only a
# short-lived access token to the claude session unit.
SIGNIN_MODE=0
if jq -e '(.providerSecret == null) and (.provider == "claude")' "$CONFIG" >/dev/null; then
  SIGNIN_MODE=1
  command -v script >/dev/null || { echo 'missing prerequisite: script' >&2; exit 2; }
  ensure_system_account hq-claude-auth /var/lib/hq-claude-auth
  [ "$(id -u hq-claude-auth)" != "$(id -u hq-jobs)" ] || exit 2
  for p in /var/lib/hq-claude-auth /var/lib/hq-claude-auth/.claude /var/lib/hq-claude-auth/.claude.json; do
    [ ! -L "$p" ] || { echo "symlink refused: $p" >&2; exit 2; }
  done
  install -d -m 700 -o hq-claude-auth -g hq-claude-auth /var/lib/hq-claude-auth /var/lib/hq-claude-auth/.claude
  if [ ! -e /var/lib/hq-claude-auth/.claude.json ]; then
    printf '%s\n' '{"theme":"dark","hasCompletedOnboarding":true}' >/var/lib/hq-claude-auth/.claude.json
    chown hq-claude-auth:hq-claude-auth /var/lib/hq-claude-auth/.claude.json
    chmod 600 /var/lib/hq-claude-auth/.claude.json
  fi
  if runuser -u hq-jobs -- test -r /var/lib/hq-claude-auth/.claude || runuser -u hq-jobs -- test -x /var/lib/hq-claude-auth; then
    echo 'hq-jobs can reach the Claude sign-in' >&2
    exit 2
  fi
fi
STATE=/var/lib/hq-job-runner/state
UNITS=/etc/systemd/system
install -d -m 700 -o root -g root /var/lib/hq-job-runner "$STATE" /run/hq-company-jobs /run/hq-company-jobs/tokens
# The account home is the parent of runs/. hq-jobs must not be able to replace that parent.
install -d -m 755 -o root -g root /var/lib/hq-company-jobs /var/lib/hq-company-jobs/runs
install -d -m 700 -o hq-jobs -g hq-jobs "$PROJECTS"
# Root owns credentials, the ledger and the config. The job account gets neither.
chown root:root "$CREDS" "$CONFIG"
chmod 600 "$CREDS" "$CONFIG"
AUTH_UID=0
[ "$SIGNIN_MODE" != 1 ] || AUTH_UID="$(id -u hq-claude-auth)"
node - "$CONFIG" "$STATE" "$UNITS" "$SIGNIN_MODE" "$AUTH_UID" <<'LAYOUT'
const fs = require('node:fs');
const [configPath, stateDir, unitDir] = process.argv.slice(2, 5);
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
config.stateDir = stateDir;
config.unitDir = unitDir;
config.jobUser = 'hq-jobs';
config.jobHome = '/var/lib/hq-company-jobs';
config.runnerHome = '/var/lib/hq-job-runner';
config.secretRuntimeDir = '/run/hq-company-jobs';
if (process.argv[5] === '1') {
  config.providerAuthFile = '/var/lib/hq-claude-auth/.claude/.credentials.json';
  config.providerAuthUid = Number(process.argv[6]);
  if (!Number.isInteger(config.providerAuthUid) || config.providerAuthUid <= 0) throw Error('Invalid sign-in account');
}
fs.writeFileSync(configPath, JSON.stringify(config));
LAYOUT
chown root:root "$CONFIG"
chmod 600 "$CONFIG"
if runuser -u hq-jobs -- test -r "$CREDS"; then
  echo 'hq-jobs can read machine credentials' >&2
  exit 2
fi
if runuser -u hq-jobs -- test -r "$STATE" || runuser -u hq-jobs -- test -w "$STATE"; then
  echo 'hq-jobs can access the ledger' >&2
  exit 2
fi
PROVIDER="$(jq -er '.provider' "$CONFIG")"
# Root validates the binding. The job account never opens the config or credentials.
"$NODE" --input-type=module - "$CONFIG" <<'ROOTCHECK'
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
const c=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const runtime=await import(pathToFileURL(c.hqRoot+'/core/scripts/lib/company-jobs.mjs'));
runtime.validateConfig(c);
const creds=JSON.parse(fs.readFileSync(c.machineCredsFile,'utf8'));
if(creds.entityType!=='company-outpost'||creds.entityUid!==c.machineUid)throw Error('Wrong machine credentials');
if(c.jobUser!=='hq-jobs'||(!c.providerSecret&&c.provider!=='claude'))throw Error('Company provider binding missing');
const cloud=await import(pathToFileURL(c.cloudModule));
if(typeof cloud.loadMachineCreds!=='function'||typeof cloud.getValidMachineTokens!=='function')throw Error('Machine client capability missing');
ROOTCHECK
# Test traversal and executable availability as the account which actually runs jobs.
runuser -u hq-jobs -- env -i HOME=/var/lib/hq-company-jobs PATH=/usr/local/bin:/usr/bin:/bin "$NODE" --input-type=module - "$ROOT" "$SLUG" "$PROVIDER" "$CREDS" "$STATE" <<'CHECK'
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
const [root,slug,provider,creds,stateDir]=process.argv.slice(2);
fs.accessSync(root,fs.constants.R_OK|fs.constants.X_OK);
fs.accessSync(root+'/workspace',fs.constants.W_OK|fs.constants.X_OK);
fs.accessSync(root+'/companies/'+slug+'/projects',fs.constants.W_OK|fs.constants.X_OK);
fs.accessSync(root+'/core/scripts/hq-agent-session.sh',fs.constants.R_OK);
try{fs.readFileSync(creds);throw Error('hq-jobs read machine credentials');}catch(e){if(e.code!=='EACCES')throw e;}
try{fs.readdirSync(stateDir);throw Error('hq-jobs read the ledger');}catch(e){if(e.code!=='EACCES')throw e;}
const result=spawnSync(provider,['--version'],{timeout:10000,stdio:'ignore'});
if(result.status!==0)throw Error('Provider unavailable to hq-jobs');
CHECK
# Exercise the same admission functions that precede provider execution.
runuser -u hq-jobs -- env -i HOME=/var/lib/hq-company-jobs PATH=/usr/local/bin:/usr/bin:/bin HQ_AGENT_WORKDIR="$ROOT" bash -c '
  set -euo pipefail
  source "$1/core/scripts/lib/session-authz.sh"
  source "$1/core/scripts/lib/session-durable-writes.sh"
  root=$(session_resolve_root)
  session_resolve_company_dir "$root" "$2" >/dev/null
  session_resolve_project_dir "$root" "$2" company-jobs-readiness company-jobs-readiness >/dev/null
' -- "$ROOT" "$SLUG"
cat >/etc/systemd/system/hq-company-jobs.service <<UNIT
[Unit]
Description=Reconcile accepted company jobs
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
User=root
Group=root
Environment=HOME=/var/lib/hq-job-runner
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RuntimeDirectory=hq-company-jobs
RuntimeDirectoryMode=0700
RuntimeDirectoryPreserve=yes
ExecStart="${NODE}" "${ROOT}/core/scripts/lib/company-jobs.mjs" reconcile "${CONFIG}"
TimeoutStartSec=5min
TimeoutStopSec=5s
KillMode=control-group
UMask=0077
UNIT
cat >/etc/systemd/system/hq-company-jobs.timer <<'UNIT'
[Unit]
Description=Poll accepted company jobs
[Timer]
OnBootSec=30s
OnUnitInactiveSec=60s
Unit=hq-company-jobs.service
[Install]
WantedBy=timers.target
UNIT
# One system timer reconciles every job. The job account gets no user manager.
loginctl disable-linger hq-jobs
systemctl daemon-reload
systemctl enable --now hq-company-jobs.timer
systemctl is-active --quiet hq-company-jobs.timer
if [ "$SIGNIN_MODE" != 1 ]; then
  systemctl disable --now hq-company-signin.service 2>/dev/null || true
else
  cat >/etc/systemd/system/hq-company-signin.service <<UNIT
[Unit]
Description=Company Outpost Claude sign-in watcher
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
Group=root
Environment=HOME=/var/lib/hq-job-runner
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart="${NODE}" "${ROOT}/core/scripts/lib/company-signin.mjs" watch "${CONFIG}"
Restart=always
RestartSec=10
UMask=0077
PrivateTmp=yes
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now hq-company-signin.service
fi
