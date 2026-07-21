#!/usr/bin/env bash
# Regression test: handoff-post.sh must not launch hidden Claude CLI jobs.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TMP_ROOT/repo/core/scripts" "$TMP_ROOT/repo/workspace/threads" "$TMP_ROOT/repo/companies/acme/workspace" "$TMP_ROOT/bin" "$TMP_ROOT/logs"
cp "$SRC_ROOT/scripts/handoff-post.sh" "$TMP_ROOT/repo/core/scripts/handoff-post.sh"
chmod +x "$TMP_ROOT/repo/core/scripts/handoff-post.sh"

cat > "$TMP_ROOT/repo/core/scripts/archive-old-threads.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$TMP_ROOT/repo/core/scripts/rebuild-threads-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/threads
echo "# Threads" > workspace/threads/INDEX.md
SH
cat > "$TMP_ROOT/repo/core/scripts/rebuild-orchestrator-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/orchestrator
echo "# Orchestrator" > workspace/orchestrator/INDEX.md
SH
chmod +x "$TMP_ROOT/repo/core/scripts/"*.sh

cat > "$TMP_ROOT/bin/claude" <<'SH'
#!/usr/bin/env bash
echo "claude invoked" > "$CLAUDE_SENTINEL"
exit 42
SH
chmod +x "$TMP_ROOT/bin/claude"

cat > "$TMP_ROOT/bin/hq" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HQ_SYNC_SENTINEL"
SH
chmod +x "$TMP_ROOT/bin/hq"

cat > "$TMP_ROOT/repo/workspace/threads/T-test.json" <<'JSON'
{
  "files_touched": [
    "companies/acme/knowledge/release-note.md"
  ],
  "metadata": {"company": ["acme"]}
}
JSON
cat > "$TMP_ROOT/learnings.json" <<'JSON'
[
  {"type":"rule","content":"ALWAYS: test handoff-post without hidden CLI","scope":"global","source":"test"}
]
JSON

(
  cd "$TMP_ROOT/repo"
  CLAUDE_SENTINEL="$TMP_ROOT/claude-called" \
  HQ_SYNC_SENTINEL="$TMP_ROOT/hq-sync-called" \
  HANDOFF_LOG_DIR="$TMP_ROOT/logs" \
  PATH="$TMP_ROOT/bin:/usr/bin:/bin" \
    bash core/scripts/handoff-post.sh workspace/threads/T-test.json "$TMP_ROOT/learnings.json"
)

[[ ! -e "$TMP_ROOT/claude-called" ]] || fail "handoff-post invoked claude"
grep -qx 'sync push companies/acme/workspace' "$TMP_ROOT/hq-sync-called" \
  || fail "handoff-post did not push the mirrored company workspace"
grep -q "learn: eligible and pending runtime dispatch" "$TMP_ROOT/logs/handoff-post.log" \
  || fail "eligible learnings were not logged as pending"
grep -q "document-release: eligible and pending runtime dispatch" "$TMP_ROOT/logs/handoff-post.log" \
  || fail "eligible document-release work was not logged as pending"
if grep -qi "delegated" "$TMP_ROOT/logs/handoff-post.log"; then
  fail "handoff-post claimed delegation without dispatch proof"
fi
