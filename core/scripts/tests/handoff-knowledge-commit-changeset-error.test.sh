#!/usr/bin/env bash
# handoff-knowledge-commit.sh must reject a changeset that lists a folder, and
# the error must name the offending entry so /handoff can fix it without guessing.
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT
HELPER="$SRC_ROOT/core/scripts/handoff-knowledge-commit.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$TMP_ROOT/workspace/threads"

# 1. folder entry (trailing slash) is rejected and named
printf '%s' '["workspace/reports/a.md","workspace/reports/dir/"]' > "$TMP_ROOT/bad.json"
set +e
OUT="$(bash "$HELPER" --root "$TMP_ROOT" --files-touched-json-file "$TMP_ROOT/bad.json" 2>&1)"; RC=$?
set -e
[ "$RC" -eq 1 ] || fail "folder entry should exit 1, got $RC: $OUT"
case "$OUT" in *"files, not folders"*) ;; *) fail "error should say files, not folders: $OUT" ;; esac
case "$OUT" in *'offending entry: "workspace/reports/dir/"'*) ;; *) fail "error should name the folder entry: $OUT" ;; esac
case "$OUT" in *'offending entry: "workspace/reports/a.md"'*) fail "valid entry must not be named: $OUT" ;; esac

# 2. absolute path and parent segment are named too
printf '%s' '["/etc/passwd","a/../b.md",{"path":"ok/file.md"}]' > "$TMP_ROOT/bad2.json"
set +e
OUT="$(bash "$HELPER" --root "$TMP_ROOT" --files-touched-json-file "$TMP_ROOT/bad2.json" 2>&1)"; RC=$?
set -e
[ "$RC" -eq 1 ] || fail "unsafe entries should exit 1, got $RC"
case "$OUT" in *'"/etc/passwd"'*) ;; *) fail "absolute path not named: $OUT" ;; esac
case "$OUT" in *'"a/../b.md"'*) ;; *) fail "parent segment not named: $OUT" ;; esac

# 3. a clean changeset still passes validation (no knowledge repos in the fixture root, so it is a no-op)
printf '%s' '["workspace/reports/a.md"]' > "$TMP_ROOT/good.json"
bash "$HELPER" --root "$TMP_ROOT" --files-touched-json-file "$TMP_ROOT/good.json" >/dev/null 2>&1 || fail "clean changeset must pass"

echo "handoff-knowledge-commit changeset error tests passed"
