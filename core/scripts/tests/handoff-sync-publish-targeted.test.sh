#!/bin/bash
# Regression: handoff-sync-publish.sh must push only the continuity pointer and
# its thread file, so the push finishes inside its timebox instead of walking
# thousands of workspace/.session-logs files first. When the CLI refuses
# `--personal` with explicit paths, it falls back to the full personal push.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PUBLISH_SH="$REPO_ROOT/core/scripts/handoff-sync-publish.sh"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

HQ="$WORKDIR/hq"
mkdir -p "$HQ/workspace/threads" "$HQ/workspace/.session-logs/claude"
THREAD_REL="workspace/threads/T-20261025-test.json"
echo '{"thread_id":"T-20261025-test"}' >"$HQ/$THREAD_REL"
echo "{\"created_at\":\"20261025T090000Z\",\"last_thread\":\"T-20261025-test\",\"thread_path\":\"$THREAD_REL\"}" \
  >"$HQ/workspace/threads/handoff.json"
echo '{}' >"$HQ/workspace/.session-logs/claude/log.jsonl"

MOCK_BIN="$WORKDIR/bin"
ARGS_LOG="$WORKDIR/args.log"
mkdir -p "$MOCK_BIN"
make_mock() {
  # $1 = refuse|accept : how the mock treats --personal with explicit paths.
  cat >"$MOCK_BIN/hq" <<MOCK_EOF
#!/bin/bash
echo "\$*" >>"$ARGS_LOG"
npos=0
skip=0
for a in "\$@"; do
  if [[ \$skip -eq 1 ]]; then skip=0; continue; fi
  case "\$a" in
    sync|push|--personal) ;;
    --hq-root|--lock-timeout|--message) skip=1 ;;
    *) npos=\$((npos + 1)) ;;
  esac
done
if [[ "$1" == "refuse" && \$npos -gt 0 ]]; then
  echo "error: \\\`--personal\\\` cannot be combined with explicit [paths]" >&2
  exit 1
fi
exit 0
MOCK_EOF
  chmod +x "$MOCK_BIN/hq"
}
export PATH="$MOCK_BIN:$PATH"

# 1. Targeted push carries exactly the pointer and the thread file.
make_mock accept
: >"$ARGS_LOG"
bash "$PUBLISH_SH" --hq-root "$HQ" --sync --timeout 5 --log "$WORKDIR/p1.log"
calls=$(wc -l <"$ARGS_LOG" | tr -d ' ')
[[ "$calls" == "1" ]] || { echo "FAIL: expected one push, got $calls" >&2; cat "$ARGS_LOG" >&2; exit 1; }
grep -q "$HQ/workspace/threads/handoff.json" "$ARGS_LOG" \
  || { echo "FAIL: push did not name the pointer" >&2; exit 1; }
grep -q "$HQ/$THREAD_REL" "$ARGS_LOG" \
  || { echo "FAIL: push did not name the thread file" >&2; exit 1; }
if grep -q "session-logs" "$ARGS_LOG"; then
  echo "FAIL: push named session logs" >&2; exit 1
fi

# 2. A thread_path outside workspace/threads/ is never pushed.
echo '{"created_at":"20261025T090000Z","thread_path":"workspace/threads/../../etc/passwd"}' \
  >"$HQ/workspace/threads/handoff.json"
: >"$ARGS_LOG"
bash "$PUBLISH_SH" --hq-root "$HQ" --sync --timeout 5 --log "$WORKDIR/p2.log"
if grep -q "passwd" "$ARGS_LOG"; then
  echo "FAIL: escaping thread_path was pushed" >&2; exit 1
fi
echo "{\"created_at\":\"20261025T090000Z\",\"last_thread\":\"T-20261025-test\",\"thread_path\":\"$THREAD_REL\"}" \
  >"$HQ/workspace/threads/handoff.json"

# 3. CLI refuses explicit personal paths: fall back to one full push.
make_mock refuse
: >"$ARGS_LOG"
rc=0
bash "$PUBLISH_SH" --hq-root "$HQ" --sync --timeout 5 --log "$WORKDIR/p3.log" || rc=$?
[[ "$rc" == "0" ]] || { echo "FAIL: fallback push should succeed, rc=$rc" >&2; exit 1; }
calls=$(wc -l <"$ARGS_LOG" | tr -d ' ')
[[ "$calls" == "2" ]] || { echo "FAIL: expected targeted + fallback push, got $calls" >&2; cat "$ARGS_LOG" >&2; exit 1; }
tail -n1 "$ARGS_LOG" | grep -q "handoff.json" \
  && { echo "FAIL: fallback push should carry no explicit paths" >&2; exit 1; }

echo "PASS: handoff-sync-publish pushes only the continuity pointer"
