#!/usr/bin/env bash
# hq-core: public
# Disposable GitHub runner only: exercise the actual installer-generated units.
set -euo pipefail

# Installed-digest helpers. company-service-restart.mjs writes the sha256 hex
# digest plus a newline. Only a file holding exactly that counts as a digest.
# A missing, empty or malformed file never reads as "changed".
DIGEST_FILE=/var/lib/hq-job-runner/state/signin-installed-digest
read_digest() { # read_digest [file]: print the digest, or fail when invalid
  local f="${1:-$DIGEST_FILE}" d
  [[ -s "$f" ]] || return 1
  d=$(cat "$f") || return 1
  [[ "$d" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$d"
}
digest_changed() { # digest_changed <old> [file]: true only for a valid, different digest
  local d
  d=$(read_digest "${2:-}") || return 1
  [[ "$d" != "$1" ]]
}
# Self-check (runs anywhere, before the runner guard): invalid files are not a change.
selfcheck=$(mktemp -d "${TMPDIR:-/tmp}/digest-selfcheck.XXXXXX")
old=$(printf '%064d' 0 | tr 0 a)
new=$(printf '%064d' 0 | tr 0 b)
: >"$selfcheck/empty"
printf '<missing>\n' >"$selfcheck/literal"
printf 'not-a-digest\n' >"$selfcheck/garbage"
printf '%s\n' "${new:0:63}" >"$selfcheck/short"
printf '%s\n' "$old" >"$selfcheck/same"
printf '%s\n' "$new" >"$selfcheck/new"
for case in missing empty literal garbage short same; do
  if digest_changed "$old" "$selfcheck/$case"; then
    echo "FAIL: digest self-check: a $case digest file counted as changed" >&2; rm -rf "$selfcheck"; exit 1
  fi
done
digest_changed "$old" "$selfcheck/new" \
  || { echo 'FAIL: digest self-check: a valid new digest did not count as changed' >&2; rm -rf "$selfcheck"; exit 1; }
rm -rf "$selfcheck"
echo 'ok: digest self-check (missing, empty, malformed and unchanged files are not a change)'
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
# Diagnostics only: never compare this value.
digest_now() { cat "$DIGEST_FILE" 2>/dev/null || echo "<missing>"; }
# Print what the runner saw before failing, so a CI failure names its cause.
die() {
  echo "FAIL: $*" >&2
  echo "  MainPID=$(pid) before=${before:-?} digest=$(digest_now) marker=${marker:-?}" >&2
  systemctl status --no-pager hq-company-signin.service hq-company-signin-restart.service hq-company-signin-restart.timer >&2 || true
  journalctl --no-pager -n 40 -u hq-company-signin.service -u hq-company-signin-restart.service >&2 || true
  exit 1
}
trap 'echo "FAIL: line $LINENO exited $?: $BASH_COMMAND" >&2' ERR
apply_update() { systemctl start hq-company-signin-restart.service; }
systemctl start hq-company-signin.service
before=$(pid)
apply_update
[[ "$(pid)" != "$before" && "$(pid)" != 0 ]] || die "first update did not restart the watcher"
before=$(pid)
apply_update
[[ "$(pid)" = "$before" ]] || die "unchanged code restarted the watcher"
touch "$fixture/code-entry"
for ((i=0; i<100; i++)); do
  [[ ! -s "$fixture/login-child" ]] || break
  sleep 0.05
done
[[ -s "$fixture/login-child" ]] || die "watcher never started the login child"
child=$(cat "$fixture/login-child")
marker=$(read_digest) || die "no valid installed digest after the first update"
printf 'version: 2\n' >"$fixture/core/core.yaml"
apply_update
[[ "$(pid)" = "$before" ]] || die "update restarted the watcher during an active login"
kill -0 "$child" || die "active login child $child was killed"
[[ "$(read_digest || true)" = "$marker" ]] || die "deferred update rewrote the installed digest"
# Removing code-entry models completion/timeout. The timer must retry unaided.
systemctl enable --now hq-company-signin-restart.timer
rm "$fixture/code-entry"
# Wait for the whole retry, not its first visible step. MainPID reads 0 while
# try-restart runs, and the digest is saved only after the restart returns, so
# breaking on the first PID change raced both (company-jobs on #1602,
# a9a71bed, first attempt). The timer fires up to OnUnitInactiveSec=30s
# after the last restart run.
for ((i=0; i<60; i++)); do
  now_pid=$(pid)
  if [[ "$now_pid" != "$before" && "$now_pid" != 0 ]] && digest_changed "$marker" \
    && ! systemctl is-active --quiet hq-company-signin-restart.service; then
    break
  fi
  sleep 1
done
[[ "$(pid)" != "$before" && "$(pid)" != 0 ]] || die "timer retry did not restart the watcher within 60s"
digest_changed "$marker" || die "timer retry restarted the watcher but did not save a valid new digest"
echo 'PASS: real systemd restarts changed code, preserves active login, and retries automatically'
