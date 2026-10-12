#!/usr/bin/env bash
# Run only in a disposable Linux container as root; systemd calls are recorded.
set -euo pipefail
[[ -f /.dockerenv && $(id -u) = 0 ]] || exit 2
install -d -m 755 /opt/hq-company-jobs/core /etc/hq
cp -R /release/core/scripts /opt/hq-company-jobs/core/
useradd --system --create-home --home-dir /var/lib/hq-company-jobs --shell /usr/sbin/nologin hq-jobs
install -d -m 700 -o hq-jobs -g hq-jobs /opt/hq-company-jobs/workspace
install -d -m 755 /opt/hq-company-jobs/companies/test
printf '%s\n' '{"uid":"cmp_test","slug":"test"}' >/opt/hq-company-jobs/companies/test/manifest.json
cat >/opt/company-cloud.mjs <<'MODULE'
export function loadMachineCreds() {}
export async function getValidMachineTokens() {}
MODULE
cat >/usr/local/bin/claude <<'PROVIDER'
#!/bin/sh
test "$1" = --version
PROVIDER
for cmd in systemctl loginctl; do
  cat >"/usr/local/bin/$cmd" <<'SYSTEMD'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> /tmp/systemd-calls
SYSTEMD
  chmod 755 "/usr/local/bin/$cmd"
done
chmod 755 /usr/local/bin/claude
cat >/etc/hq/company-jobs.json <<'CONFIG'
{"companyUid":"cmp_test","companySlug":"test","machineUid":"out_test","outpostId":"outpost_cmp_test","instanceId":"i-test","attemptId":"attempt1","hqRoot":"/opt/hq-company-jobs","stateDir":"/var/lib/hq-company-jobs/state","unitDir":"/var/lib/hq-company-jobs/.config/systemd/user","machineCredsFile":"/etc/hq/company-machine.json","cloudModule":"/opt/company-cloud.mjs","provider":"claude","providerSecret":"ANTHROPIC_API_KEY","apiUrl":"https://example.test"}
CONFIG
printf '%s\n' '{"entityType":"company-outpost","entityUid":"out_test"}' >/etc/hq/company-machine.json
bash /release/core/scripts/company-jobs-install.sh
rg_expected='systemctl enable --now hq-company-jobs.timer'
grep -Fx "$rg_expected" /tmp/systemd-calls
grep -Fx 'loginctl disable-linger hq-jobs' /tmp/systemd-calls
if grep -Fx 'loginctl enable-linger hq-jobs' /tmp/systemd-calls; then exit 1; fi
grep -Fx 'User=root' /etc/systemd/system/hq-company-jobs.service
if runuser -u hq-jobs -- test -r /etc/hq/company-machine.json; then echo 'hq-jobs read credentials' >&2; exit 1; fi
if runuser -u hq-jobs -- test -r /var/lib/hq-job-runner/state; then echo 'hq-jobs read the ledger' >&2; exit 1; fi
runuser -u hq-jobs -- env -i HOME=/var/lib/hq-company-jobs PATH=/usr/local/bin:/usr/bin:/bin HQ_AGENT_WORKDIR=/opt/hq-company-jobs bash -c '
  set -euo pipefail
  source /opt/hq-company-jobs/core/scripts/lib/session-authz.sh
  source /opt/hq-company-jobs/core/scripts/lib/session-durable-writes.sh
  root=$(session_resolve_root)
  session_resolve_company_dir "$root" test >/dev/null
  project=$(session_resolve_project_dir "$root" test "" company-job:fixture)
  printf admitted > "$project/proof.txt"
  test "$(cat "$project/proof.txt")" = admitted
  test ! -w "$root/companies/test/manifest.json"
'
echo 'PASS: actual session root/company/project admission and durable project write as hq-jobs'
if runuser -u hq-jobs -- test -w /opt/hq-company-jobs/core/scripts/company-jobs-install.sh; then exit 1; fi
chmod 777 /opt/hq-company-jobs/core
if bash /release/core/scripts/company-jobs-install.sh >/tmp/refusal 2>&1; then exit 1; fi
grep -F 'Released code must be root owned' /tmp/refusal
chmod 755 /opt/hq-company-jobs/core
if ! id ec2-user >/dev/null 2>&1; then
  useradd --system --shell /usr/sbin/nologin ec2-user
fi
chown ec2-user:ec2-user /opt/hq-company-jobs/core/scripts/lib
if bash /release/core/scripts/company-jobs-install.sh >/tmp/refusal 2>&1; then
  echo 'ec2-user owned core/scripts/lib was installed' >&2
  exit 1
fi
grep -F 'Released code must be root owned' /tmp/refusal
chown root:root /opt/hq-company-jobs/core/scripts/lib
chown ec2-user:ec2-user /opt/hq-company-jobs/core/scripts/lib/company-jobs.mjs
if bash /release/core/scripts/company-jobs-install.sh >/tmp/refusal 2>&1; then
  echo 'ec2-user owned company-jobs.mjs was installed' >&2
  exit 1
fi
grep -F 'Released code must be root owned' /tmp/refusal
chown root:root /opt/hq-company-jobs/core/scripts/lib/company-jobs.mjs
rm /usr/local/bin/claude
if bash /release/core/scripts/company-jobs-install.sh >/tmp/refusal 2>&1; then exit 1; fi
grep -F 'Provider unavailable' /tmp/refusal
echo 'PASS: installed account, launch wiring, permissions, unsafe-code refusal and missing-provider refusal'
