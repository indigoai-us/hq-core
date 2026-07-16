#!/usr/bin/env bash
# Regression coverage for durable, cross-runtime handoff follow-ups.
#
# Agent/Task/Skill dispatch is an instruction-surface contract, so the runtime
# selection and failure warning are verified structurally. The durable handoff
# and detached post-script behavior are exercised in an isolated repository.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/handoff/SKILL.md"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$SKILL" ]] || fail "handoff skill missing"

# Cross-runtime dispatch must not stop at Codex, and the last fallback must be
# synchronous only after the finalizer has written the durable learning array.
grep -q 'Codex:.*`spawn_agent`' "$SKILL" \
  || fail "Codex spawn_agent dispatch route missing"
grep -q 'Claude Code:.*`Task` or `Agent`' "$SKILL" \
  || fail "Claude Task/Agent dispatch route missing"
grep -q 'Skill.*synchronously' "$SKILL" \
  || fail "synchronous Skill fallback missing"
grep -q -- '--learnings-json.*{learnings_json from Step 2}' "$SKILL" \
  || fail "handoff-finalize does not receive collected learnings"
grep -q 'WARN: Follow-up recovery required' "$SKILL" \
  || fail "forced-dispatch-failure recovery warning missing"
grep -q 'Run exactly: /learn {learnings_json}' "$SKILL" \
  || fail "manual learning recovery command missing"
grep -q 'Run exactly: /document-release {thread_path}' "$SKILL" \
  || fail "manual document-release recovery command missing"

mkdir -p "$TMP_ROOT/repo/core/scripts" "$TMP_ROOT/repo/workspace/baseline" \
  "$TMP_ROOT/repo/workspace/threads" "$TMP_ROOT/repo/workspace/orchestrator" \
  "$TMP_ROOT/logs"
cp "$ROOT/core/scripts/handoff-finalize.sh" "$TMP_ROOT/repo/core/scripts/handoff-finalize.sh"
cp "$ROOT/core/scripts/handoff-post.sh" "$TMP_ROOT/repo/core/scripts/handoff-post.sh"
cp "$ROOT/core/scripts/hq-status-summary.sh" "$TMP_ROOT/repo/core/scripts/hq-status-summary.sh"

cat > "$TMP_ROOT/repo/core/scripts/archive-old-threads.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$TMP_ROOT/repo/core/scripts/rebuild-threads-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/threads
echo "# Threads" > workspace/threads/INDEX.md
echo "- recent" > workspace/threads/recent.md
SH
cat > "$TMP_ROOT/repo/core/scripts/rebuild-orchestrator-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/orchestrator
echo "# Orchestrator" > workspace/orchestrator/INDEX.md
SH
chmod +x "$TMP_ROOT/repo/core/scripts/"*.sh

cat > "$TMP_ROOT/repo/workspace/baseline/hq-local-baseline.json" <<'JSON'
{"categories":[{"name":"baseline","patterns":["workspace/*"]}]}
JSON

(
  cd "$TMP_ROOT/repo"
  git init -q
  git config user.email test@example.com
  git config user.name "Handoff Follow-ups Test"
  mkdir -p companies/acme/knowledge
  echo "release candidate" > companies/acme/knowledge/release-note.md
  git add core/scripts workspace/baseline companies
  git commit -qm "base"

  learnings='[{"type":"rule","content":"ALWAYS: retain handoff learnings before dispatch","scope":"global","source":"test"}]'
  printf '%s\n' "$learnings" > "$TMP_ROOT/learnings.json"
  out=$(PATH=/usr/bin:/bin bash core/scripts/handoff-finalize.sh \
    --title "Handoff: runtime follow-ups" \
    --summary "Exercise durable pending follow-ups" \
    --message "runtime follow-ups" \
    --next-steps-json '[]' \
    --files-touched-json '["companies/acme/knowledge/release-note.md"]' \
    --learnings-json "$learnings" \
    --tags-json '["test"]' \
    --slug "runtime-followups")

  thread_path=$(jq -r '.thread_path' <<<"$out")
  [[ -f "$thread_path" ]] || fail "finalizer did not write a durable thread"
  jq -e --argjson expected "$learnings" '.learnings == $expected' "$thread_path" >/dev/null \
    || fail "collected learnings were not made durable before dispatch"

  HANDOFF_LOG_DIR="$TMP_ROOT/logs" PATH=/usr/bin:/bin \
    bash core/scripts/handoff-post.sh "$thread_path" "$TMP_ROOT/learnings.json"
)

grep -q 'learn: eligible and pending runtime dispatch.*no dispatch proof' "$TMP_ROOT/logs/handoff-post.log" \
  || fail "unproved learn dispatch was not marked pending"
grep -q 'document-release: eligible and pending runtime dispatch.*no dispatch proof' "$TMP_ROOT/logs/handoff-post.log" \
  || fail "unproved document-release dispatch was not marked pending"
if grep -qi 'delegated' "$TMP_ROOT/logs/handoff-post.log"; then
  fail "post-script falsely claimed delegation after forced no-dispatch runtime"
fi

echo "handoff follow-ups runtime: ok"
