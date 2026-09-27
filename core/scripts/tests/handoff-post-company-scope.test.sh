#!/usr/bin/env bash
# Regression coverage for handoff-post company selection and files_touched shapes.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

mkdir -p "$TMP_ROOT/repo/core/scripts" \
  "$TMP_ROOT/repo/companies/indigo/workspace" \
  "$TMP_ROOT/bin" \
  "$TMP_ROOT/logs"
cp "$SRC_ROOT/scripts/handoff-post.sh" "$TMP_ROOT/repo/core/scripts/handoff-post.sh"
chmod +x "$TMP_ROOT/repo/core/scripts/handoff-post.sh"
cat > "$TMP_ROOT/repo/core/scripts/qmd-reindex-bg.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP_ROOT/repo/core/scripts/qmd-reindex-bg.sh"
source "$SRC_ROOT/scripts/tests/lib/handoff-post-test-helpers.sh"

cat > "$TMP_ROOT/bin/hq" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == "sync push" ]]; then
  printf '%s\n' "$*" >> "$HQ_SYNC_CALLS"
fi
exit 0
SH
chmod +x "$TMP_ROOT/bin/hq"

run_post() {
  local thread_path="$1"
  handoff_post_test_run "$TMP_ROOT/repo" "$thread_path" "" \
    HQ_ACTIVE_COMPANY=acme \
    HQ_SYNC_CALLS="$TMP_ROOT/hq-sync-calls" \
    HANDOFF_LOG_DIR="$TMP_ROOT/logs" \
    PATH="$TMP_ROOT/bin:/usr/bin:/bin"
}

# The active company is acme, while this thread belongs to indigo.
cat > "$TMP_ROOT/repo/workspace-thread-company.json" <<'JSON'
{
  "files_touched": [],
  "metadata": {"company": ["indigo"]}
}
JSON
run_post "$TMP_ROOT/repo/workspace-thread-company.json"
if ! grep -Fxq 'sync push --company indigo companies/indigo/workspace' "$TMP_ROOT/hq-sync-calls"; then
  fail "company sync did not pass --company indigo for a thread whose company differs from the active company"
fi

cat > "$TMP_ROOT/repo/workspace-thread-files.json" <<'JSON'
{
  "files_touched": [
    {"path": "companies/indigo/knowledge/release-note.md"},
    "repos/private/example/src/change.sh",
    {"path": 42},
    null,
    false,
    {"other": "value"},
    "README.md"
  ],
  "metadata": {"company": []}
}
JSON
run_post "$TMP_ROOT/repo/workspace-thread-files.json"
if ! grep -Fq 'document-release: eligible and pending runtime dispatch by handoff skill (2 scoped files; no dispatch proof)' "$TMP_ROOT/logs/handoff-post.log"; then
  fail "object-form files_touched path did not count as scoped"
fi
skipped_count=$(grep -Fc 'document-release: skipped unsupported files_touched entry' "$TMP_ROOT/logs/handoff-post.log" || true)
if [[ "$skipped_count" -ne 4 ]]; then
  fail "expected one skip log line for each of 4 unsupported entries; found $skipped_count"
fi

if [[ "$failures" -gt 0 ]]; then
  echo "Failed $failures handoff-post regression assertions" >&2
  exit 1
fi

echo "Passed 3 handoff-post regression assertions"
