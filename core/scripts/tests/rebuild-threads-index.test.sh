#!/usr/bin/env bash
# Regression test: changeset sidecars must not be indexed as thread records.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/rebuild-threads-index.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() {
  [ "$2" = "$3" ] || fail "$1: expected $2, got $3"
  echo "  ok: $1"
}

THREADS="$TMP/workspace/threads"
mkdir -p "$THREADS"

# Sixteen primary records exercise both the full index and recent.md's 15-row
# limit. Every primary deliberately has a matching T-*.changeset.json sidecar.
for n in $(seq -w 1 16); do
  printf '{"thread_id":"T-%s","type":"task","updated_at":"2026-07-20T12:00:00Z","metadata":{"title":"Thread %s"}}\n' "$n" "$n" \
    > "$THREADS/T-$n.json"
  printf '{"thread_id":"T-%s","staged_paths":[]}\n' "$n" \
    > "$THREADS/T-$n.changeset.json"
done

HQ_ROOT="$TMP" bash "$SCRIPT" --both >/dev/null
INDEX="$THREADS/INDEX.md"
RECENT="$THREADS/recent.md"

assert_eq "index active-thread count" "16" "$(sed -n 's/^Active threads: \([0-9][0-9]*\).*/\1/p' "$INDEX")"
assert_eq "recent active-thread count" "16" "$(sed -n 's/^Active threads: \([0-9][0-9]*\).*/\1/p' "$RECENT")"
assert_eq "one index row per primary thread" "16" "$(grep -c '^| T-' "$INDEX" || true)"
assert_eq "recent rows capped at 15 primary threads" "15" "$(grep -c '^| T-' "$RECENT" || true)"

if grep -Fq '| - | - | - |' "$INDEX" "$RECENT"; then
  fail "changeset sidecar rendered as a placeholder thread row"
fi

# The rows passed through the recent-index limiter must be materially larger
# than a pipe buffer. `head -n` can close that pipe early, causing bash's
# builtin printf to receive SIGPIPE under `set -o pipefail` before recent.md is
# written. Long real titles make this a deterministic regression fixture.
LARGE_ROOT="$TMP/large"
LARGE_THREADS="$LARGE_ROOT/workspace/threads"
mkdir -p "$LARGE_THREADS"
LONG_TITLE="$(printf '%*s' 1024 '' | tr ' ' x)"

for n in $(seq -w 1 200); do
  printf '{"thread_id":"T-large-%s","type":"task","updated_at":"2026-07-20T12:00:00Z","metadata":{"title":"%s"}}\n' \
    "$n" "$LONG_TITLE" > "$LARGE_THREADS/T-large-$n.json"
done

# A non-zero status here is the regression: the forwarder/CLI path must finish
# --both and leave a complete 15-row recent index behind.
HQ_ROOT="$LARGE_ROOT" bash "$SCRIPT" --both >/dev/null
LARGE_RECENT="$LARGE_THREADS/recent.md"
[[ -f "$LARGE_RECENT" ]] || fail "large recent.md was not written"
assert_eq "large recent rows capped at 15" "15" "$(grep -c '^| T-large-' "$LARGE_RECENT" || true)"

echo "rebuild-threads-index: 5 passed, 0 failed"
