#!/usr/bin/env bash
# Regression test: handoff-post must ignore HQ_ROOT inherited from its caller.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

FIXTURE_ROOT="$TMP_ROOT/fixture"
CALLER_ROOT="$TMP_ROOT/caller-root"
LOG_DIR="$TMP_ROOT/logs"
mkdir -p "$FIXTURE_ROOT/core/scripts/lib" "$CALLER_ROOT" "$TMP_ROOT/bin" "$LOG_DIR"
cp "$SRC_ROOT/scripts/handoff-post.sh" "$FIXTURE_ROOT/core/scripts/handoff-post.sh"
cp "$SRC_ROOT/scripts/lib/session-id.sh" "$FIXTURE_ROOT/core/scripts/lib/session-id.sh"
chmod +x "$FIXTURE_ROOT/core/scripts/handoff-post.sh"
source "$SRC_ROOT/scripts/tests/lib/handoff-post-test-helpers.sh"

cat > "$FIXTURE_ROOT/core/scripts/qmd-reindex-bg.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$HQ_ROOT" > "$HQ_ROOT/qmd-reindex-ran"
SH
chmod +x "$FIXTURE_ROOT/core/scripts/qmd-reindex-bg.sh"

cat > "$TMP_ROOT/bin/hq" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == "core rebuild-index" ]]; then
  printf '%s\n' "$*" > "$PWD/rebuild-index-${3}.ran"
fi
exit 0
SH
chmod +x "$TMP_ROOT/bin/hq"

# Simulate a lane shell exporting a different HQ root from the fixture.
export HQ_ROOT="$CALLER_ROOT"
handoff_post_test_run "$FIXTURE_ROOT" "" "" \
  HANDOFF_LOG_DIR="$LOG_DIR" \
  PATH="$TMP_ROOT/bin:/usr/bin:/bin"

failures=0
if [[ ! -f "$FIXTURE_ROOT/rebuild-index-threads.ran" ]]; then
  echo "FAIL: handoff-post did not run against the fixture HQ root" >&2
  failures=$((failures + 1))
fi
if [[ ! -f "$FIXTURE_ROOT/qmd-reindex-ran" ]]; then
  echo "FAIL: handoff-post did not use the fixture qmd helper" >&2
  failures=$((failures + 1))
fi
if [[ -n "$(find "$CALLER_ROOT" -mindepth 1 -print -quit)" ]]; then
  echo "FAIL: handoff-post wrote into the caller's HQ_ROOT" >&2
  failures=$((failures + 1))
fi
if [[ "$failures" -gt 0 ]]; then
  exit 1
fi

echo "Passed handoff-post HQ_ROOT isolation assertion"
