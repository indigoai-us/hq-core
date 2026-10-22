#!/usr/bin/env bash
# handoff-finalize-logical-root.test.sh — absolute changeset paths spelled
# through a symlinked HQ root still count toward the handoff's company scope
# (feedback_7a3e83c2-ac00-4f5d-af13-8a756c0aaeb9).
#
# The finalizer resolves HQ_ROOT with `pwd -P`. A caller whose HQ root is a
# symlink (macOS /var -> /private/var, or an alias checkout) passes absolute
# paths with the logical prefix. Those never matched the physical prefix, so a
# second company reached that way was invisible to the scope check and the
# handoff was mirrored to the first company alone. Adapted from the reporter's
# regression (sofia-lakehouse/hq-core@6550602).

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REAL_ROOT="$TMP/physical/repo"
ALIAS_ROOT="$TMP/checkout-alias"
mkdir -p "$REAL_ROOT/core/scripts/lib" "$REAL_ROOT/.claude/hooks" "$REAL_ROOT/workspace/baseline" \
  "$REAL_ROOT/workspace/threads" "$REAL_ROOT/workspace/orchestrator" "$REAL_ROOT/workspace/sessions/fixture" \
  "$REAL_ROOT/companies/tenant-a" "$REAL_ROOT/companies/tenant-b" "$TMP/bin" "$TMP/home"
ln -s "$REAL_ROOT" "$ALIAS_ROOT"
cp "$SRC_ROOT/scripts/handoff-finalize.sh" "$REAL_ROOT/core/scripts/handoff-finalize.sh"
cp "$SRC_ROOT/scripts/lib/session-id.sh" "$REAL_ROOT/core/scripts/lib/session-id.sh"
cp "$SRC_ROOT/scripts/hq-status-summary.sh" "$REAL_ROOT/core/scripts/hq-status-summary.sh"
cp "$SRC_ROOT/scripts/lib/forwarder.sh" "$REAL_ROOT/core/scripts/lib/forwarder.sh"
cp "$SRC_ROOT/scripts/lib/hq-cli-floor.sh" "$REAL_ROOT/core/scripts/lib/hq-cli-floor.sh"
cp "$SRC_ROOT/../.claude/hooks/mirror-thread-to-company.sh" "$REAL_ROOT/.claude/hooks/mirror-thread-to-company.sh"
printf 'company_slug: tenant-a\n' > "$REAL_ROOT/workspace/sessions/fixture/meta.yaml"
printf 'synthetic a\n' > "$REAL_ROOT/companies/tenant-a/note.md"
printf 'synthetic b\n' > "$REAL_ROOT/companies/tenant-b/note.md"
cat > "$REAL_ROOT/core/scripts/rebuild-threads-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/threads
echo "# Threads" > workspace/threads/INDEX.md
echo "- recent" > workspace/threads/recent.md
SH
cat > "$REAL_ROOT/core/scripts/rebuild-orchestrator-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/orchestrator
echo "# Orchestrator" > workspace/orchestrator/INDEX.md
SH
cat > "$REAL_ROOT/core/scripts/qmd-reindex-bg.sh" <<'SH'
#!/bin/sh
printf 'skipped-fixture\n'
SH
cat > "$TMP/bin/hq" <<'SH'
#!/bin/sh
printf '{}\n'
SH
chmod +x "$REAL_ROOT/core/scripts/"*.sh "$TMP/bin/hq"
cat > "$REAL_ROOT/workspace/baseline/hq-local-baseline.json" <<'JSON'
{"categories":[{"name":"baseline","patterns":["workspace/*","repos/*","core/settings/*",".hq/*"]}]}
JSON
for command in jq git bash; do
  ln -s "$(command -v "$command")" "$TMP/bin/$command"
done
fixture_run() {
  env -i HOME="$TMP/home" HQ_ROOT="$ALIAS_ROOT" HQ_SESSION_ID=fixture \
    PATH="$TMP/bin:/usr/bin:/bin" LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null "$@"
}
fixture_run git -C "$REAL_ROOT" init -q
fixture_run git -C "$REAL_ROOT" config user.name Fixture
fixture_run git -C "$REAL_ROOT" config user.email fixture@example.invalid
fixture_run git -C "$REAL_ROOT" config core.hooksPath /dev/null

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. A relative tenant-a path plus an alias-absolute tenant-b path: two
#    companies, so the handoff gets no owner and is mirrored nowhere.
mixed_paths="$(jq -cn --arg root "$ALIAS_ROOT" \
  '["./companies/tenant-a/note.md", ($root + "/companies/tenant-b/note.md")]')"
mixed="$(fixture_run bash "$ALIAS_ROOT/core/scripts/handoff-finalize.sh" \
  --company tenant-a --files-touched-json "$mixed_paths" --slug mixed-alias --next-command '' 2>"$TMP/mixed.err")" \
  || fail "mixed finalize exited $? : $(cat "$TMP/mixed.err")"
thread="$(jq -r .thread_path <<<"$mixed")"
jq -e '.metadata.company == [] and (.files_touched | length) == 2' "$REAL_ROOT/$thread" >/dev/null \
  || fail "mixed-company alias changeset must carry no owner company and both paths: $(jq -c '.metadata.company, .files_touched' "$REAL_ROOT/$thread")"
jq -e '.mirror_companies == []' <<<"$mixed" >/dev/null || fail "mixed-company alias changeset must not be mirrored"
if find "$REAL_ROOT/companies" -path '*/workspace/sessions/*.json' | grep -q .; then
  fail "mixed-company alias changeset was mirrored into a company workspace"
fi
echo "ok: mixed relative and alias-absolute paths stay unowned"

# 2. A single alias-absolute tenant-a path keeps its owner mirror.
single_paths="$(jq -cn --arg root "$ALIAS_ROOT" '[($root + "/companies/tenant-a/note.md")]')"
single="$(fixture_run bash "$ALIAS_ROOT/core/scripts/handoff-finalize.sh" \
  --company tenant-a --files-touched-json "$single_paths" --slug single-alias --next-command '' 2>"$TMP/single.err")" \
  || fail "single finalize exited $? : $(cat "$TMP/single.err")"
thread_id="$(jq -r .thread_id <<<"$single")"
thread="$(jq -r .thread_path <<<"$single")"
jq -e '.metadata.company == ["tenant-a"] and (.files_touched | length) == 1' "$REAL_ROOT/$thread" >/dev/null \
  || fail "single alias path must keep tenant-a as owner: $(jq -c '.metadata.company, .files_touched' "$REAL_ROOT/$thread")"
jq -e '.mirror_companies == ["tenant-a"]' <<<"$single" >/dev/null || fail "single alias changeset must mirror to tenant-a"
test -f "$REAL_ROOT/companies/tenant-a/workspace/sessions/$thread_id.json" || fail "tenant-a mirror missing"
test ! -d "$REAL_ROOT/companies/tenant-b/workspace" || fail "tenant-b must not receive a mirror"
echo "ok: single-company alias changeset keeps its owner mirror"

echo "PASS: handoff-finalize relativizes alias-root paths for company scope"
