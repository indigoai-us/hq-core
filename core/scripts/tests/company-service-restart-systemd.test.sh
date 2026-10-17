#!/usr/bin/env bash
# hq-core: public
# Disposable GitHub runner only: exercise the actual installer-generated units.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" = true && "$(id -u)" = 0 && "$(uname -s)" = Linux ]] || {
  echo 'requires a disposable Linux GitHub Actions runner and root' >&2; exit 2;
}
scripts=$(cd "$(dirname "$0")/.." && pwd)
for unit in hq-company-signin.service hq-company-signin-restart.service hq-company-signin-restart.timer; do
  [[ ! -e "/etc/systemd/system/$unit" ]] || { echo 'refusing existing unit' >&2; exit 2; }
done
[[ ! -e /var/lib/hq-job-runner/state/signin-installed-digest ]] || exit 2
# The real watcher uses PrivateTmp=yes, so its fixture must live outside /tmp.
fixture=$(mktemp -d /var/lib/company-service-restart.XXXXXX)
cleanup() {
  systemctl disable --now hq-company-signin-restart.timer >/dev/null 2>&1 || true
  systemctl stop hq-company-signin-restart.service hq-company-signin.service || true
  rm -f /etc/systemd/system/hq-company-signin{,-restart}.service /etc/systemd/system/hq-company-signin-restart.timer
  rm -f /var/lib/hq-job-runner/state/signin-installed-digest
  rm -rf "$fixture"
  systemctl daemon-reload
}
trap cleanup EXIT
mkdir -p "$fixture/core/scripts/lib" /var/lib/hq-job-runner/state /run/hq-company-jobs
chmod 700 /var/lib/hq-job-runner/state
cp "$scripts/lib/company-service-restart.mjs" "$fixture/core/scripts/lib/"
printf 'version: 1\n' >"$fixture/core/core.yaml"
node - "$scripts/company-jobs-install.sh" "$fixture" <<'NODE'
const fs = require('node:fs');
const [installer, root] = process.argv.slice(2);
const source = fs.readFileSync(installer, 'utf8');
const config = root + '/config.json';
fs.writeFileSync(config, JSON.stringify({hqRoot: root, provider: 'claude'}), {mode: 0o600});
for (const name of ['hq-company-signin.service', 'hq-company-signin-restart.service', 'hq-company-signin-restart.timer']) {
  const escaped = name.replaceAll('.', '\\.');
  const match = source.match(new RegExp('cat >[^\\n]*' + escaped + '[^\\n]* <<[\'\"]?UNIT[\'\"]?\\n([\\s\\S]*?)\\nUNIT'));
  if (!match) throw Error('missing installer unit: ' + name);
  let unit = match[1].replaceAll('${NODE}', process.execPath).replaceAll('${ROOT}', root).replaceAll('${CONFIG}', config).replaceAll('${FLOCK}', '/usr/bin/flock');
  if (name === 'hq-company-signin.service') unit = unit.replace(/^ExecStart=.*$/m, `ExecStart="${process.execPath}" "${root}/watcher.cjs" "${root}"`);
  fs.writeFileSync('/etc/systemd/system/' + name, unit + '\n');
}
// A legacy watcher: no phase file, one young login child. A child younger than
// the 10-minute idle bound still defers. An idle child past that bound is
// covered by the node tests; this script must not wait that long.
fs.writeFileSync(root + '/watcher.cjs', `
const fs = require('node:fs');
const {spawn} = require('node:child_process');
const root = process.argv[2];
let child;
setInterval(() => {
  if (fs.existsSync(root + '/code-entry') && !child) {
    child = spawn('/bin/sleep', ['120']);
    fs.writeFileSync(root + '/login-child', String(child.pid));
    child.on('exit', () => { child = null; });
  } else if (!fs.existsSync(root + '/code-entry') && child) child.kill();
}, 50);
`);
NODE
systemctl daemon-reload
pid() { systemctl show --property=MainPID --value hq-company-signin.service; }
apply_update() { systemctl start hq-company-signin-restart.service; }
systemctl start hq-company-signin.service
before=$(pid)
apply_update
[[ "$(pid)" != "$before" && "$(pid)" != 0 ]]
before=$(pid)
apply_update
[[ "$(pid)" = "$before" ]]
touch "$fixture/code-entry"
for ((i=0; i<100; i++)); do
  [[ ! -s "$fixture/login-child" ]] || break
  sleep 0.05
done
[[ -s "$fixture/login-child" ]]
child=$(cat "$fixture/login-child")
marker=$(cat /var/lib/hq-job-runner/state/signin-installed-digest)
printf 'version: 2\n' >"$fixture/core/core.yaml"
apply_update
[[ "$(pid)" = "$before" ]]
kill -0 "$child"
[[ "$(cat /var/lib/hq-job-runner/state/signin-installed-digest)" = "$marker" ]]
# Removing code-entry models completion/timeout. The timer must retry unaided.
systemctl enable --now hq-company-signin-restart.timer
rm "$fixture/code-entry"
for ((i=0; i<45; i++)); do
  [[ "$(pid)" = "$before" ]] || break
  sleep 1
done
[[ "$(pid)" != "$before" && "$(pid)" != 0 ]]
[[ "$(cat /var/lib/hq-job-runner/state/signin-installed-digest)" != "$marker" ]]
echo 'PASS: real systemd restarts changed code, preserves active login, and retries automatically'
