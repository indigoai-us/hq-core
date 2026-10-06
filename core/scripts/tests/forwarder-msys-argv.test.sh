#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-forwarder-argv.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
mkdir -p "$TMP/bin" "$TMP/fixture/real-path"
printf 'synthetic path fixture\n' > "$TMP/fixture/real-path/file.txt"

# Keep the manifest as the generated path table's source of truth. A missing
# path_operands rule regenerates a different forwarder and fails this check.
generated_root="$TMP/generated"
bash "$ROOT/core/scripts/generate-forwarders.sh" --output-root "$generated_root"
while IFS="$(printf '\t')" read -r path command kind root interpreter min_cli state path_operands; do
  [ "$kind" = "generated" ] && [ "$state" = "forwarded" ] || continue
  if ! cmp -s "$ROOT/$path" "$generated_root/$path"; then
    fail "generated forwarder differs from manifest output: $path ($path_operands)"
  fi
done < <(awk -F '\t' -f "$ROOT/core/scripts/lib/cli-hosted-manifest.awk" "$ROOT/core/scripts/cli-hosted.yaml")

cat > "$TMP/capture.cjs" <<'NODE'
const fs = require('node:fs');
const args = process.argv.slice(2);
if (args.length === 1 && args[0] === '--version') {
  process.stdout.write('5.400.0\n');
  process.exit(0);
}
const record = process.env.HQ_STUB_RECORD;
const exists = (value) => fs.existsSync(value.startsWith('WIN_PATH:') ? value.slice('WIN_PATH:'.length) : value);
if (process.env.MSYS2_ARG_CONV_EXCL !== '*') throw new Error(`MSYS2_ARG_CONV_EXCL was not scoped to hq: ${process.env.MSYS2_ARG_CONV_EXCL}`);
fs.appendFileSync(record, JSON.stringify(args) + '\n');
const commandAt = args.indexOf('archive-old-threads');
const policyAt = args.indexOf('age-report');
const retireAt = args.indexOf('retire');
const frontmatterAt = args.indexOf('frontmatter');
const bridgeAt = args.indexOf('codex-skill-bridge');
const gitPackAt = args.indexOf('git-pack-extension-check');
const resizeAt = args.indexOf('resize-screenshot');
const qmdAt = args.indexOf('qmd-reindex-after-sync');
const backgroundAt = args.indexOf('background');
const worktreeAt = args.indexOf('worktree');
const rootAt = args.indexOf('--hq-root');
const dirAt = args.indexOf('--dir');
const slashOk = commandAt >= 0 && args[commandAt + 1] === '/handoff';
const pathOk = policyAt >= 0 && dirAt >= 0 && exists(args[dirAt + 1]);
const retirePathOk = retireAt >= 0 && dirAt >= 0 && exists(args[dirAt + 1]);
const retireSlashTargetOk = retireAt >= 0 && args[retireAt + 1] === '/handoff';
const logAt = args.indexOf('--log');
const backgroundPathOk = backgroundAt >= 0 && logAt >= 0 && exists(args[logAt + 1]);
const sourceAt = args.indexOf('--source');
const worktreePathOk = worktreeAt >= 0 && sourceAt >= 0 && exists(args[sourceAt + 1]);
const bridgeRootAt = args.indexOf('--root');
const oldRootAt = args.indexOf('--old-root');
const bridgePathOk = bridgeAt >= 0 && ((bridgeRootAt >= 0 && oldRootAt >= 0 && exists(args[bridgeRootAt + 1]) && exists(args[oldRootAt + 1])) || args.some((value) => (value.startsWith('--root=') || value.startsWith('--old-root=')) && exists(value.slice(value.indexOf('=') + 1)) ));
const gitPackRootAt = gitPackAt >= 0 ? args.indexOf('--root', gitPackAt) : -1;
const gitPackPathOk = gitPackAt >= 0 && gitPackRootAt >= 0 && exists(args[gitPackRootAt + 1]);
const screenshotPathOk = resizeAt >= 0 && exists(args[resizeAt + 1]);
const frontmatterPathOk = frontmatterAt >= 0 && exists(args[frontmatterAt + 1]);
const qmdPathOk = qmdAt >= 0 && exists(args[qmdAt + 1]);
const pathFlagOk = (commandIndex, option) => { const at = args.indexOf(option, commandIndex); return at >= 0 && exists(args[at + 1]); };
const statusAt = args.indexOf('hq-status-summary');
const notifyAt = args.indexOf('notify');
const auditAt = args.indexOf('audit-log');
const ontologyAt = args.indexOf('ontology-readme-drift');
const refreshAt = args.indexOf('refresh-vault-access');
const tokenAt = args.indexOf('token-usage-report');
const statusPathOk = statusAt >= 0 && pathFlagOk(statusAt, '--porcelain-file') && pathFlagOk(statusAt, '--session-files-file');
const notifyPathOk = notifyAt >= 0 && pathFlagOk(notifyAt, '--log-path') && pathFlagOk(notifyAt, '--hq-root');
const auditAtFlag = args.indexOf('--files', auditAt);
const auditPathOk = auditAt >= 0 && auditAtFlag >= 0 && args[auditAtFlag + 1].split(',').every((value) => exists(value));
const ontologyPathOk = ontologyAt >= 0 && pathFlagOk(ontologyAt, '--root');
const refreshPathOk = refreshAt >= 0 && pathFlagOk(refreshAt, '--root');
const tokenPathOk = tokenAt >= 0 && pathFlagOk(tokenAt, '--project-dir');
if ((!slashOk && !pathOk && !retirePathOk && !retireSlashTargetOk && !backgroundPathOk && !worktreePathOk && !bridgePathOk && !gitPackPathOk && !screenshotPathOk && !frontmatterPathOk && !qmdPathOk && !statusPathOk && !notifyPathOk && !auditPathOk && !ontologyPathOk && !refreshPathOk && !tokenPathOk) || (rootAt >= 0 && !exists(args[rootAt + 1]))) {
  process.stderr.write(`unexpected forwarded argv: ${JSON.stringify(args)}\n`);
  process.exit(42);
}
process.stdout.write('path-ok\n');
NODE

if [ "${FORWARDER_TEST_FORCE_CYG_PATH:-}" = "1" ]; then
  cat > "$TMP/bin/cygpath" <<'SH'
#!/usr/bin/env bash
printf 'WIN_PATH:%s\n' "$2"
SH
  chmod +x "$TMP/bin/cygpath"
  cat > "$TMP/bin/hq" <<'SH'
#!/usr/bin/env bash
exec node "$HQ_STUB_SCRIPT" "$@"
SH
  chmod +x "$TMP/bin/hq"
  real_path="$TMP/fixture/real-path"
  expected_path="WIN_PATH:$real_path"
elif [ "${OS:-}" = "Windows_NT" ] || [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
  cat > "$TMP/bin/hq.cmd" <<'CMD'
@echo off
node "%HQ_STUB_SCRIPT%" %*
CMD
  # Bash resolves the extensionless entry; route it through the local cmd stub.
  cat > "$TMP/bin/hq" <<'SH'
#!/usr/bin/env bash
exec cmd.exe /c hq.cmd "$@"
SH
  chmod +x "$TMP/bin/hq"
  real_path="$TMP/fixture/real-path"
  expected_path="$(cygpath -m "$real_path")"
else
  cat > "$TMP/bin/hq" <<'SH'
#!/usr/bin/env bash
exec node "$HQ_STUB_SCRIPT" "$@"
SH
  chmod +x "$TMP/bin/hq"
  real_path="$TMP/fixture/real-path"
  expected_path="$real_path"
fi

unset MSYS2_ARG_CONV_EXCL MSYS_NO_PATHCONV || true
forwarder_status=0
HQ_STUB_SCRIPT="$TMP/capture.cjs" \
HQ_STUB_RECORD="$TMP/argv.json" \
PATH="$TMP/bin:$PATH" \
bash "$ROOT/core/scripts/archive-old-threads.sh" /handoff > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?

if [ "$forwarder_status" -ne 0 ]; then
  printf 'FAIL: hq stub rejected forwarded argv (exit %s)\n' "$forwarder_status" >&2
  cat "$TMP/stderr" >&2
  exit 1
fi

[ "$(cat "$TMP/stdout")" = "path-ok" ] || {
  printf 'FAIL: forwarded path did not resolve; stdout=%s stderr=%s\n' "$(cat "$TMP/stdout")" "$(cat "$TMP/stderr")" >&2
  exit 1
}
HQ_STUB_SCRIPT="$TMP/capture.cjs" \
HQ_STUB_RECORD="$TMP/argv.json" \
PATH="$TMP/bin:$PATH" \
bash "$ROOT/core/scripts/policy-age-report.sh" --dir "$real_path" > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || {
  printf 'FAIL: policy path argument did not resolve (exit %s)\n' "$forwarder_status" >&2
  cat "$TMP/stderr" >&2
  exit 1
}
HQ_STUB_SCRIPT="$TMP/capture.cjs" \
HQ_STUB_RECORD="$TMP/argv.json" \
PATH="$TMP/bin:$PATH" \
bash "$ROOT/core/scripts/qmd-reindex-bg.sh" --log "$real_path/file.txt" > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || { cat "$TMP/stderr" >&2; fail "qmd log path argument did not resolve (exit $forwarder_status)"; }
HQ_STUB_SCRIPT="$TMP/capture.cjs" \
HQ_STUB_RECORD="$TMP/argv.json" \
PATH="$TMP/bin:$PATH" \
bash "$ROOT/core/scripts/worktree.sh" --name synthetic --source "$real_path" --branch synthetic --base main --no-pull > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || { cat "$TMP/stderr" >&2; fail "worktree source path argument did not resolve (exit $forwarder_status)"; }
HQ_STUB_SCRIPT="$TMP/capture.cjs" HQ_STUB_RECORD="$TMP/argv.json" PATH="$TMP/bin:$PATH" bash "$ROOT/core/scripts/codex-skill-bridge.sh" status --root "$real_path" --old-root "$real_path" > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || { cat "$TMP/stderr" >&2; fail "bridge root paths did not resolve (exit $forwarder_status)"; }
HQ_STUB_SCRIPT="$TMP/capture.cjs" HQ_STUB_RECORD="$TMP/argv.json" PATH="$TMP/bin:$PATH" bash "$ROOT/core/scripts/git-pack-extension-check.sh" --root "$real_path" > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || { cat "$TMP/stderr" >&2; fail "git pack root path did not resolve (exit $forwarder_status)"; }
HQ_STUB_SCRIPT="$TMP/capture.cjs" HQ_STUB_RECORD="$TMP/argv.json" PATH="$TMP/bin:$PATH" bash "$ROOT/core/scripts/resize-screenshot.sh" "$real_path/file.txt" > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || { cat "$TMP/stderr" >&2; fail "screenshot path did not resolve (exit $forwarder_status)"; }
HQ_STUB_SCRIPT="$TMP/capture.cjs" HQ_STUB_RECORD="$TMP/argv.json" PATH="$TMP/bin:$PATH" bash "$ROOT/core/scripts/read-policy-frontmatter.sh" "$real_path/file.txt" "$real_path" > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || { cat "$TMP/stderr" >&2; fail "frontmatter file path did not resolve (exit $forwarder_status)"; }
HQ_STUB_SCRIPT="$TMP/capture.cjs" HQ_STUB_RECORD="$TMP/argv.json" PATH="$TMP/bin:$PATH" bash "$ROOT/core/scripts/policy-retire.sh" --dir "$real_path" --report-dir "$real_path" > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || { cat "$TMP/stderr" >&2; fail "policy retire paths did not resolve (exit $forwarder_status)"; }
HQ_STUB_SCRIPT="$TMP/capture.cjs" HQ_STUB_RECORD="$TMP/argv.json" PATH="$TMP/bin:$PATH" bash "$ROOT/core/scripts/qmd-reindex-after-sync.sh" "$real_path" > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || { cat "$TMP/stderr" >&2; fail "qmd root path did not resolve (exit $forwarder_status)"; }
HQ_STUB_SCRIPT="$TMP/capture.cjs" HQ_STUB_RECORD="$TMP/argv.json" PATH="$TMP/bin:$PATH" bash "$ROOT/core/scripts/hq-job-notify.sh" --hq-root "$real_path" --log-path "$real_path/file.txt" > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || { cat "$TMP/stderr" >&2; fail "job notify log path did not resolve (exit $forwarder_status)"; }
HQ_STUB_SCRIPT="$TMP/capture.cjs" HQ_STUB_RECORD="$TMP/argv.json" PATH="$TMP/bin:$PATH" bash "$ROOT/core/scripts/hq-status-summary.sh" --porcelain-file "$real_path/file.txt" --session-files-file "$real_path/file.txt" > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || { cat "$TMP/stderr" >&2; fail "status summary paths did not resolve (exit $forwarder_status)"; }
HQ_STUB_SCRIPT="$TMP/capture.cjs" HQ_STUB_RECORD="$TMP/argv.json" PATH="$TMP/bin:$PATH" bash "$ROOT/core/scripts/audit-log.sh" append --files "$real_path/file.txt,$real_path" > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || { cat "$TMP/stderr" >&2; fail "audit log file list did not resolve (exit $forwarder_status)"; }
HQ_STUB_SCRIPT="$TMP/capture.cjs" HQ_STUB_RECORD="$TMP/argv.json" PATH="$TMP/bin:$PATH" bash "$ROOT/core/scripts/ontology-readme-drift.sh" --root "$real_path" indigo > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || { cat "$TMP/stderr" >&2; fail "ontology root path did not resolve (exit $forwarder_status)"; }
HQ_STUB_SCRIPT="$TMP/capture.cjs" HQ_STUB_RECORD="$TMP/argv.json" PATH="$TMP/bin:$PATH" bash "$ROOT/core/scripts/refresh-vault-access.sh" --root "$real_path" > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || { cat "$TMP/stderr" >&2; fail "refresh root path did not resolve (exit $forwarder_status)"; }
HQ_STUB_SCRIPT="$TMP/capture.cjs" HQ_STUB_RECORD="$TMP/argv.json" PATH="$TMP/bin:$PATH" bash "$ROOT/core/scripts/token-usage-report.sh" --project-dir "$real_path" > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || { cat "$TMP/stderr" >&2; fail "token project-dir path did not resolve (exit $forwarder_status)"; }
HQ_STUB_SCRIPT="$TMP/capture.cjs" HQ_STUB_RECORD="$TMP/argv.json" PATH="$TMP/bin:$PATH" bash "$ROOT/core/scripts/policy-retire.sh" /handoff --reason synthetic > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || { cat "$TMP/stderr" >&2; fail "policy retire slash-bearing target changed (exit $forwarder_status)"; }
HQ_STUB_SCRIPT="$TMP/capture.cjs" HQ_STUB_RECORD="$TMP/argv.json" PATH="$TMP/bin:$PATH" bash "$ROOT/core/scripts/codex-skill-bridge.sh" status "--root=$real_path" "--old-root=$real_path" > "$TMP/stdout" 2> "$TMP/stderr" || forwarder_status=$?
[ "$forwarder_status" -eq 0 ] || { cat "$TMP/stderr" >&2; fail "equals-form path options did not resolve (exit $forwarder_status)"; }
node - "$TMP/argv.json" "$expected_path" "$expected_path/file.txt" <<'NODE'
const fs = require('node:fs');
const [recordFile, realPath, logPath] = process.argv.slice(2);
const calls = fs.readFileSync(recordFile, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
const handoff = calls.find((args) => args.includes('archive-old-threads'));
const policy = calls.find((args) => args.includes('age-report'));
const background = calls.find((args) => args.includes('background'));
const worktree = calls.find((args) => args.includes('worktree'));
const bridge = calls.find((args) => args.includes('codex-skill-bridge'));
const gitPack = calls.find((args) => args.includes('git-pack-extension-check'));
const screenshot = calls.find((args) => args.includes('resize-screenshot'));
const frontmatter = calls.find((args) => args.includes('frontmatter'));
const qmd = calls.find((args) => args.includes('qmd-reindex-after-sync'));
const retire = calls.find((args) => args.includes('retire'));
if (!handoff || handoff[handoff.indexOf('archive-old-threads') + 1] !== '/handoff') throw new Error(`slash argument changed: ${JSON.stringify(handoff)}`);
if (!policy || policy[policy.indexOf('--dir') + 1] !== realPath) throw new Error(`policy path argument changed: ${JSON.stringify(policy)}`);
if (!background || background[background.indexOf('--log') + 1] !== logPath) throw new Error(`background log path changed: ${JSON.stringify(background)}`);
if (!worktree || worktree[worktree.indexOf('--source') + 1] !== realPath) throw new Error(`worktree source path changed: ${JSON.stringify(worktree)}`);
if (!bridge || bridge[bridge.indexOf('--root') + 1] !== realPath || bridge[bridge.indexOf('--old-root') + 1] !== realPath) throw new Error(`bridge root path changed: ${JSON.stringify(bridge)}`);
if (!gitPack || gitPack[gitPack.indexOf('--root') + 1] !== realPath) throw new Error(`git pack root path changed: ${JSON.stringify(gitPack)}`);
if (!screenshot || screenshot[screenshot.indexOf('resize-screenshot') + 1] !== `${realPath}/file.txt`) throw new Error(`screenshot path changed: ${JSON.stringify(screenshot)}`);
if (!frontmatter || frontmatter[frontmatter.indexOf('frontmatter') + 1] !== `${realPath}/file.txt` || frontmatter[frontmatter.indexOf('frontmatter') + 2] !== realPath) throw new Error(`frontmatter paths changed: ${JSON.stringify(frontmatter)}`);
if (!qmd || qmd[qmd.indexOf('qmd-reindex-after-sync') + 1] !== realPath) throw new Error(`qmd root path changed: ${JSON.stringify(qmd)}`);
if (!retire || retire[retire.indexOf('--dir') + 1] !== realPath || retire[retire.indexOf('--report-dir') + 1] !== realPath) throw new Error(`policy retire paths changed: ${JSON.stringify(retire)}`);
const status = calls.find((args) => args.includes('hq-status-summary'));
const notify = calls.find((args) => args.includes('notify'));
const audit = calls.find((args) => args.includes('audit-log'));
const ontology = calls.find((args) => args.includes('ontology-readme-drift'));
const refresh = calls.find((args) => args.includes('refresh-vault-access'));
const token = calls.find((args) => args.includes('token-usage-report'));
const retireSlashTarget = calls.find((args) => args.includes('retire') && args.includes('/handoff'));
const bridgeEquals = calls.find((args) => args.includes('codex-skill-bridge') && args.includes(`--root=${realPath}`));
if (!status || status[status.indexOf('--porcelain-file') + 1] !== logPath || status[status.indexOf('--session-files-file') + 1] !== logPath) throw new Error(`status summary paths changed: ${JSON.stringify(status)}`);
if (!notify || notify[notify.indexOf('--log-path') + 1] !== logPath || notify[notify.indexOf('--hq-root', notify.indexOf('notify')) + 1] !== realPath) throw new Error(`job notify paths changed: ${JSON.stringify(notify)}`);
if (!audit || audit[audit.indexOf('--files') + 1] !== `${logPath},${realPath}`) throw new Error(`audit file list changed: ${JSON.stringify(audit)}`);
if (!ontology || ontology[ontology.indexOf('--root') + 1] !== realPath) throw new Error(`ontology root changed: ${JSON.stringify(ontology)}`);
if (!refresh || refresh[refresh.indexOf('--root') + 1] !== realPath) throw new Error(`refresh root changed: ${JSON.stringify(refresh)}`);
if (!token || token[token.indexOf('--project-dir') + 1] !== realPath) throw new Error(`token project-dir changed: ${JSON.stringify(token)}`);
if (!retireSlashTarget || retireSlashTarget[retireSlashTarget.indexOf('retire') + 1] !== '/handoff') throw new Error(`policy retire slash-bearing target changed: ${JSON.stringify(retireSlashTarget)}`);
if (!bridgeEquals || !bridgeEquals.includes(`--old-root=${realPath}`)) throw new Error(`equals-form path options changed: ${JSON.stringify(bridgeEquals)}`);
console.log('PASS: /handoff stays unchanged and all declared path operands resolve through their hq callers');
NODE
