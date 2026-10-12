#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/hq-sync/SKILL.md"
LIB="$ROOT/.claude/skills/hq-sync/scripts/hq-sync-events.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); printf '  ok %s\n' "$1"; }
grep -Fq 'hq_sync_count_tombstoned_files "$output_file"' "$SKILL" || fail "the skill must read tombstones from complete events"
ok "the skill reads tombstone counts from company complete events"
grep -Fq 'hq_sync_post_pull_reindex "$hq_root" "${files_d:-0}" "${files_t:-0}"' "$SKILL" || fail "the skill must pass both changed-file counts"
ok "the skill passes download and tombstone counts to post-pull surfacing"
if grep -q 'hq-sync.post-pull-reindex' "$SKILL" "$LIB"; then
  fail "post-pull reindex must not stay behind a feature flag"
fi
ok "skill and helper are not flag-gated"
# shellcheck source=/dev/null
. "$LIB"
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
printf '%s\n' "${HQ_NO_UPDATE_CHECK:-}" >> "${REINDEX_ENV_LOG:?missing reindex env log}"
printf '%s\n' "$root" >> "${REINDEX_LOG:?missing reindex log}"
code="${REINDEX_EXIT:-0}"
[ "$code" = 0 ] || exit "$code"
wrapper="$root/.claude/skills/indigo:new-skill"
mkdir -p "$wrapper"
ln -s ../../../companies/indigo/skills/new-skill/SKILL.md "$wrapper/SKILL.md"
HQ
chmod +x "$fake_bin/hq"
root="$TMP/hq root"
mkdir -p "$root/companies/indigo/skills/new-skill"
printf '# Synthetic skill\n' > "$root/companies/indigo/skills/new-skill/SKILL.md"
export PATH="$fake_bin:$PATH" REINDEX_LOG="$TMP/reindex.log" REINDEX_ENV_LOG="$TMP/reindex-env.log"
: > "$REINDEX_LOG"; : > "$REINDEX_ENV_LOG"
hq_sync_post_pull_reindex "$root" 1 0
[ "$(cat "$REINDEX_LOG")" = "$root" ] || fail "downloaded-file path must reindex exactly once"
[ "$(cat "$REINDEX_ENV_LOG")" = 1 ] || fail "reindex must set HQ_NO_UPDATE_CHECK=1"
ok "pull with downloaded files reindexes once without a CLI update check"
: > "$REINDEX_LOG"; : > "$REINDEX_ENV_LOG"
hq_sync_post_pull_reindex "$root" 0 0
[ ! -s "$REINDEX_LOG" ] || fail "zero changes must skip reindex"
ok "zero changes skip reindex"
: > "$REINDEX_LOG"; : > "$REINDEX_ENV_LOG"
rm -rf "$root/.claude/skills/indigo:new-skill"
hq_sync_post_pull_reindex "$root" 0 1
wrapper="$root/.claude/skills/indigo:new-skill/SKILL.md"
[ -f "$wrapper" ] || fail "tombstone-only pull must surface skill wrapper"
[ "$(cat "$REINDEX_LOG")" = "$root" ] || fail "tombstone-only pull must reindex resolved root"
ok "tombstone-only pull surfaces skill wrapper"
: > "$REINDEX_LOG"
invalid_output="$(hq_sync_post_pull_reindex "$root" 0 invalid 2>&1)"
[ ! -s "$REINDEX_LOG" ] || fail "invalid count must skip reindex"
grep -q 'file-change count was invalid' <<< "$invalid_output" || fail "invalid count must be warned about"
ok "invalid tombstone counter is rejected with a warning"
: > "$REINDEX_LOG"
failure_output="$(REINDEX_EXIT=7 hq_sync_post_pull_reindex "$root" 1 2>&1)" || fail "reindex failure must not change sync exit code"
grep -q 'Warning: company-skill reindex failed' <<< "$failure_output" || fail "reindex failure must warn"
[ "$(cat "$REINDEX_LOG")" = "$root" ] || fail "failed reindex must be attempted"
ok "reindex failure warns without changing sync exit code"
echo
echo "PASS ($pass assertions)"
