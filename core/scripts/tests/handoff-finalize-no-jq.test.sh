#!/usr/bin/env bash
# handoff-finalize-no-jq.test.sh — handoff-finalize.sh must check for jq before
# it writes anything (feedback_8b7e7fc6).
#
# Without the check, a host with no jq got a half-written handoff: the script
# created workspace/threads/.handoff-tmp and temp files, then died later with
# "jq: command not found" (rc 127). The finalizer must now exit 6 with a
# message that names jq, and leave the HQ tree exactly as it found it.
#
# jq is hidden by running the script with a PATH made of symlinks to every
# executable on the real PATH except jq (macOS 15+ ships /usr/bin/jq, so
# dropping one directory from PATH is not enough).
#
# Explicitly wired into .github/workflows/pr-checks.yml.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# A minimal HQ-shaped git repo holding the finalizer and the library it sources.
REPO="$TMP_ROOT/hq"
mkdir -p "$REPO/core/scripts/lib"
cp "$SRC_ROOT/scripts/handoff-finalize.sh" "$REPO/core/scripts/handoff-finalize.sh"
cp "$SRC_ROOT/scripts/lib/session-id.sh" "$REPO/core/scripts/lib/session-id.sh"
chmod +x "$REPO/core/scripts/handoff-finalize.sh"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Handoff No-jq Test"
git -C "$REPO" add core
git -C "$REPO" commit -q -m init

# PATH without jq.
NOJQ_BIN="$TMP_ROOT/bin-nojq"
mkdir -p "$NOJQ_BIN"
IFS=':' read -r -a path_dirs <<<"$PATH"
for dir in "${path_dirs[@]}"; do
  [[ -d "$dir" ]] || continue
  for exe in "$dir"/*; do
    name="${exe##*/}"
    [[ "$name" == jq || "$name" == jq.exe ]] && continue
    [[ -x "$exe" && ! -d "$exe" ]] || continue
    [[ -e "$NOJQ_BIN/$name" ]] && continue
    ln -s "$exe" "$NOJQ_BIN/$name"
  done
done
if PATH="$NOJQ_BIN" command -v jq >/dev/null 2>&1; then
  fail "test setup: jq is still reachable on the stripped PATH"
fi
BASH_BIN="$(command -v bash)"

snapshot() {
  (cd "$REPO" && find . -path ./.git -prune -o -print | LC_ALL=C sort)
  git -C "$REPO" status --porcelain --untracked-files=all
}
before="$(snapshot)"

rc=0
PATH="$NOJQ_BIN" HQ_ROOT="$REPO" HQ_SESSION_ID="handoff-nojq-test" \
  "$BASH_BIN" "$REPO/core/scripts/handoff-finalize.sh" \
  --title "Handoff: no jq" --summary "should not be written" \
  >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || rc=$?

[[ "$rc" -eq 6 ]] || fail "expected exit 6 without jq, got $rc; stderr: $(cat "$TMP_ROOT/err")"
grep -q 'handoff-finalize: jq is required' "$TMP_ROOT/err" \
  || fail "stderr does not name the missing jq: $(cat "$TMP_ROOT/err")"
grep -q 'Nothing was written' "$TMP_ROOT/err" \
  || fail "stderr does not say nothing was written: $(cat "$TMP_ROOT/err")"
grep -q 'command not found' "$TMP_ROOT/err" \
  && fail "the script reached a jq call before the check: $(cat "$TMP_ROOT/err")"
[[ ! -s "$TMP_ROOT/out" ]] || fail "expected no stdout payload, got: $(cat "$TMP_ROOT/out")"
echo "ok 1 exits 6 with a jq message"

after="$(snapshot)"
[[ "$before" == "$after" ]] || fail "the HQ tree changed without jq:
--- before
$before
--- after
$after"
[[ ! -e "$REPO/workspace" ]] || fail "workspace/ was created without jq"
echo "ok 2 nothing written"

echo "handoff-finalize-no-jq.test.sh: 2/2 passed"
