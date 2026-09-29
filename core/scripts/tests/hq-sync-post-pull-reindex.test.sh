#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/hq-sync/SKILL.md"
LIB="$ROOT/.claude/skills/hq-sync/scripts/hq-sync-events.sh"
FLAG_READER="$ROOT/.claude/skills/hq-sync/scripts/hq-sync-post-pull-reindex-flag.cjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); printf '  ok %s\n' "$1"; }
grep -Fq 'hq_sync_count_tombstoned_files "$output_file"' "$SKILL" || fail "the skill must read tombstones from complete events"
ok "the skill reads tombstone counts from company complete events"
grep -Fq 'hq_sync_post_pull_reindex "$hq_root" "${files_d:-0}" "${files_t:-0}"' "$SKILL" || fail "the skill must pass both changed-file counts"
ok "the skill passes download and tombstone counts to post-pull surfacing"
# shellcheck source=/dev/null
. "$LIB"
# Exercise the hq-flags reader with synthetic dependencies only; this never fetches.
node - "$FLAG_READER" <<'NODE'
const assert = require('node:assert/strict');
const reader = require(process.argv[2]);
const env = { HQ_FLAGS_API_URL: 'https://flags.invalid', HQ_COMPANY_UID: 'cmp_Synthetic123' };
(async () => {
  let clients = 0;
  const dependencies = {
    env,
    loadCachedTokens: () => ({ idToken: 'synthetic' }),
    fetch: async () => { throw new Error('unexpected fetch'); },
    createClient: (options) => {
      clients += 1;
      assert.equal(options.endpoint, env.HQ_FLAGS_API_URL);
      assert.equal(options.companyUid, env.HQ_COMPANY_UID);
      return { ready: async () => {}, snapshot: () => ({ flags: {} }), close() {} };
    },
  };
  assert.equal(await reader.postPullReindexEnabled({ ...dependencies, env: {} }), false, 'missing configuration defaults off');
  assert.equal(clients, 0, 'missing configuration creates no client');
  assert.equal(reader.validConfig({ ...env, HQ_FLAGS_API_URL: 'not a URL' }), false, 'malformed endpoint is rejected');
  assert.equal(reader.validConfig({ ...env, HQ_COMPANY_UID: 'not-a-company-uid' }), false, 'malformed company uid is rejected');
  const clientWithFlag = (value) => (options) => ({
    ...dependencies.createClient(options),
    snapshot: () => ({ flags: { [reader.FLAG_KEY]: value } }),
  });
  assert.equal(await reader.postPullReindexEnabled({ ...dependencies, createClient: clientWithFlag(false) }), false, 'flag false skips');
  assert.equal(await reader.postPullReindexEnabled({ ...dependencies, createClient: clientWithFlag(true) }), true, 'flag true enables');
  assert.equal(await reader.postPullReindexEnabled({ ...dependencies, createClient: () => { throw new Error('synthetic failure'); }, reportError() {} }), false, 'lookup errors fail closed');
})().catch((error) => { console.error(error); process.exitCode = 1; });
NODE
[ "$?" -eq 0 ] || fail "flag reader must honor default-off semantics with isolated clients"
ok "hq-flags reader validates config, defaults off, and fails closed"
events="$TMP/events.ndjson"
printf '%s\n' '{"type":"complete","company":"indigo","filesTombstoned":1}' '{"type":"all-complete","filesDownloaded":0}' > "$events"
[ "$(hq_sync_count_tombstoned_files "$events")" = 1 ] || fail "tombstone count must sum company complete events"
ok "tombstone counter reads company complete events"
fake_bin="$TMP/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/hq" <<'HQ'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = reindex ] && [ "${2:-}" = --repo-root ] || exit 64
root="${3:?missing HQ root}"
printf '%s\n' "$root" >> "${REINDEX_LOG:?missing reindex log}"
code="${REINDEX_EXIT:-0}"
[ "$code" = 0 ] || exit "$code"
wrapper="$root/.claude/skills/indigo:new-skill"
mkdir -p "$wrapper"
ln -s ../../../companies/indigo/skills/new-skill/SKILL.md "$wrapper/SKILL.md"
HQ
cat > "$fake_bin/node" <<'NODE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FLAG_NODE_LOG:?missing flag node log}"
printf '%s\n' "${FLAG_VALUE:-false}"
NODE
chmod +x "$fake_bin/hq" "$fake_bin/node"
root="$TMP/hq root"
mkdir -p "$root/companies/indigo/skills/new-skill"
printf '# Synthetic skill\n' > "$root/companies/indigo/skills/new-skill/SKILL.md"
export PATH="$fake_bin:$PATH" REINDEX_LOG="$TMP/reindex.log" FLAG_NODE_LOG="$TMP/flag-node.log"
export HQ_FLAGS_API_URL="https://flags.invalid" HQ_COMPANY_UID="cmp_Synthetic123" HQ_CLI_BIN="$fake_bin/hq"
: > "$FLAG_NODE_LOG"; : > "$REINDEX_LOG"
FLAG_VALUE=true hq_sync_post_pull_reindex "$root" 1 0
[ "$(wc -l < "$FLAG_NODE_LOG" | tr -d ' ')" = 1 ] || fail "flag-on downloaded-file path must consult the flag reader once"
[ "$(cat "$REINDEX_LOG")" = "$root" ] || fail "flag-on downloaded-file path must reindex exactly once"
ok "flag-on pull with downloaded files consults flag and reindexes once"
: > "$FLAG_NODE_LOG"; : > "$REINDEX_LOG"
FLAG_VALUE=false hq_sync_post_pull_reindex "$root" 1 0
[ "$(wc -l < "$FLAG_NODE_LOG" | tr -d ' ')" = 1 ] || fail "flag-off changed pull must consult flag reader"
[ ! -s "$REINDEX_LOG" ] || fail "flag off must skip reindex"
ok "flag-off changed pull does not reindex"
: > "$FLAG_NODE_LOG"; : > "$REINDEX_LOG"
unset HQ_FLAGS_API_URL
hq_sync_post_pull_reindex "$root" 1 0
[ ! -s "$FLAG_NODE_LOG" ] || fail "missing config must not start Node.js"
[ ! -s "$REINDEX_LOG" ] || fail "missing config must skip reindex"
ok "missing flag configuration starts no Node.js and skips reindex"
export HQ_FLAGS_API_URL="https://flags.invalid"
: > "$FLAG_NODE_LOG"; : > "$REINDEX_LOG"
FLAG_VALUE=true hq_sync_post_pull_reindex "$root" 0 0
[ ! -s "$FLAG_NODE_LOG" ] || fail "zero changes must skip flag lookup"
[ ! -s "$REINDEX_LOG" ] || fail "zero changes must skip reindex"
ok "zero changes skip flag lookup and reindex"
: > "$FLAG_NODE_LOG"; : > "$REINDEX_LOG"
rm -rf "$root/.claude/skills/indigo:new-skill"
FLAG_VALUE=true hq_sync_post_pull_reindex "$root" 0 1
wrapper="$root/.claude/skills/indigo:new-skill/SKILL.md"
[ -f "$wrapper" ] || fail "tombstone-only pull must surface skill wrapper"
[ "$(cat "$REINDEX_LOG")" = "$root" ] || fail "tombstone-only pull must reindex resolved root"
ok "flag-on tombstone-only pull surfaces skill wrapper"
: > "$FLAG_NODE_LOG"; : > "$REINDEX_LOG"
invalid_output="$(hq_sync_post_pull_reindex "$root" 0 invalid 2>&1)"
[ ! -s "$FLAG_NODE_LOG" ] || fail "invalid count must skip flag lookup"
[ ! -s "$REINDEX_LOG" ] || fail "invalid count must skip reindex"
grep -q 'file-change count was invalid' <<< "$invalid_output" || fail "invalid count must be warned about"
ok "invalid tombstone counter is rejected with a warning"
: > "$FLAG_NODE_LOG"; : > "$REINDEX_LOG"
failure_output="$(FLAG_VALUE=true REINDEX_EXIT=7 hq_sync_post_pull_reindex "$root" 1 2>&1)" || fail "reindex failure must not change sync exit code"
grep -q 'Warning: company-skill reindex failed' <<< "$failure_output" || fail "reindex failure must warn"
[ "$(cat "$REINDEX_LOG")" = "$root" ] || fail "failed reindex must be attempted"
ok "reindex failure warns without changing sync exit code"
echo
echo "PASS ($pass assertions)"
