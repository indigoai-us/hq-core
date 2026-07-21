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

echo "rebuild-threads-index: 4 passed, 0 failed"
