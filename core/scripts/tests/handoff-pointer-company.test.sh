#!/usr/bin/env bash
# Regression tests for handoff-pointer-company.sh, the reader /discover uses to
# resolve company context from workspace/threads/handoff.json (Shepherd issue 2).
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
READER="$SRC_ROOT/scripts/handoff-pointer-company.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/var/tmp}/handoff-pointer-company.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

mkdir -p "$TMP_ROOT/workspace/threads"
POINTER="$TMP_ROOT/workspace/threads/handoff.json"
THREAD="$TMP_ROOT/workspace/threads/T-test.json"

expect() {
  local want="$1" label="$2" got
  got="$(HQ_ROOT="$TMP_ROOT" bash "$READER")"
  [[ "$got" == "$want" ]] || fail "$label: expected '$want', got '$got'"
  pass "$label"
}

printf '%s\n' '{"last_thread":"T-test","company":"acme"}' > "$POINTER"
expect acme "scalar company"

printf '%s\n' '{"last_thread":"T-test","company":["acme"]}' > "$POINTER"
expect acme "one-element company array"

printf '%s\n' '{"last_thread":"T-test","companies":["acme"]}' > "$POINTER"
expect acme "one-element companies array"

printf '%s\n' '{"last_thread":"T-test","company":["acme","beta"]}' > "$POINTER"
expect "" "ambiguous company array resolves to nothing"

printf '%s\n' '{"metadata":{"company":["acme"]}}' > "$THREAD"
printf '%s\n' '{"last_thread":"T-test","thread_path":"workspace/threads/T-test.json"}' > "$POINTER"
expect acme "legacy pointer falls back to thread metadata.company"

printf '%s\n' '{"metadata":{"company":[]}}' > "$THREAD"
expect "" "legacy pointer with no thread company resolves to nothing"

printf '%s\n' '{"last_thread":"T-test","company":"../evil"}' > "$POINTER"
expect "" "invalid slug is rejected"

rm -f "$POINTER"
expect "" "missing pointer resolves to nothing"

echo "handoff-pointer-company: all tests passed"
