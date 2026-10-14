#!/usr/bin/env bash
# Regression tests: /handoff builder route. The builder test passes only when
# repos/private/hq-core-staging is a git repo whose push --dry-run succeeds;
# otherwise the public route applies. On the builder route the script writes
# a fix brief for the visible agent from the thread's hq-core deficiencies.
# Uses a fixture HQ tree and a local bare remote; no network.
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/var/tmp}/handoff-builder-route-test.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

root="$TMP_ROOT/hq"
mkdir -p "$root/core/scripts" "$root/workspace"
cp "$SRC_ROOT/scripts/handoff-builder-route.sh" "$root/core/scripts/"
run() { bash "$root/core/scripts/handoff-builder-route.sh" --root "$root" "$@"; }

thread="$TMP_ROOT/thread.json"
cat > "$thread" <<'JSON'
{"thread_id":"T-20261008-120000-abc123",
 "deficiencies":[
  {"lever":"navigation","kind":"hq-core","severity":"low","summary":"nav thing","evidence":"log line 4","proposed_fix":"fix nav"},
  {"lever":"no-ops","kind":"hq-core","severity":"high","summary":"no evidence thing","evidence":"","proposed_fix":"fix it"},
  {"lever":"tool-economy","kind":"repo","severity":"high","summary":"repo thing","evidence":"e3","proposed_fix":"f3"}]}
JSON

# 1. Absent staging repo: public route.
out="$(run)"
[ "$out" = "route: public (no hq-core-staging repo)" ] || fail "absent: got '$out'"
out="$(run --thread "$thread")"
[ "$out" = "route: public (no hq-core-staging repo)" ] || fail "absent+thread: got '$out'"
[ ! -d "$root/workspace/handoff-builder" ] || fail "absent: brief written on public route"
pass "absent staging repo takes the public route"

# 2. Directory that is not a git repo: public route.
staging="$root/repos/private/hq-core-staging"
mkdir -p "$staging"
out="$(run)"
[ "$out" = "route: public (hq-core-staging is not a git repo)" ] || fail "non-git: got '$out'"
pass "non-git staging directory takes the public route"

# 3. Git repo whose push --dry-run fails: public route.
git init -q "$staging"
git -C "$staging" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$staging" remote add origin "$TMP_ROOT/missing-remote.git"
out="$(run)"
[ "$out" = "route: public (git push --dry-run to hq-core-staging failed)" ] || fail "unpushable: got '$out'"
pass "unpushable staging repo takes the public route"

# 4. Pushable staging repo: builder route, and the dry run pushes nothing.
git init -q --bare "$TMP_ROOT/remote.git"
git -C "$staging" remote set-url origin "$TMP_ROOT/remote.git"
out="$(run)"
[ "$out" = "route: builder" ] || fail "present: got '$out'"
[ -z "$(git -C "$TMP_ROOT/remote.git" for-each-ref)" ] || fail "present: dry run created a ref"
pass "pushable staging repo takes the builder route"

# 4b. A stale, diverged probe branch on the remote must not fail the test.
other="$TMP_ROOT/other"
git init -q "$other"
git -C "$other" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m other
git -C "$other" push -q "$TMP_ROOT/remote.git" HEAD:refs/heads/handoff-fix/route-probe
out="$(run)"
[ "$out" = "route: builder" ] || fail "stale probe branch: got '$out'"
[ "$(git -C "$TMP_ROOT/remote.git" rev-parse refs/heads/handoff-fix/route-probe)" = "$(git -C "$other" rev-parse HEAD)" ] \
  || fail "stale probe branch: dry run moved the ref"
git -C "$TMP_ROOT/remote.git" update-ref -d refs/heads/handoff-fix/route-probe
pass "stale probe branch on the remote still takes the builder route"

# 5. Env opt-out forces the public route.
out="$(HQ_HANDOFF_BUILDER_ROUTE=0 run)"
[ "$out" = "route: public (builder route disabled (HQ_HANDOFF_BUILDER_ROUTE=0))" ] || fail "opt-out: got '$out'"
pass "HQ_HANDOFF_BUILDER_ROUTE=0 forces the public route"

# 6. Builder route with hq-core items writes the brief.
out="$(run --thread "$thread")"
brief="$root/workspace/handoff-builder/abc123.md"
expected="$(printf 'route: builder\nbrief: %s' "$brief")"
[ "$out" = "$expected" ] || fail "brief: got '$out'"
[ -f "$brief" ] || fail "brief: file missing"
grep -q '^Branch: handoff-fix/abc123 (create off origin/main)$' "$brief" || fail "brief: branch line"
grep -q 'T-20261008-120000-abc123' "$brief" || fail "brief: thread id"
grep -q '^### Lever: navigation$' "$brief" || fail "brief: navigation lever"
grep -q '^### Lever: no-ops$' "$brief" || fail "brief: no-ops lever"
grep -q 'Evidence: log line 4' "$brief" || fail "brief: evidence"
grep -q 'Evidence: NONE (do not apply; list under Not applied)' "$brief" || fail "brief: missing evidence flag"
grep -q 'repo thing' "$brief" && fail "brief: included a non hq-core item"
grep -q 'manual-copy' "$brief" || fail "brief: manual-copy rule"
grep -q 'Never merge' "$brief" || fail "brief: never-merge rule"
grep -q -- '--admin' "$brief" || fail "brief: no-admin rule"
grep -q "Not applied" "$brief" || fail "brief: Not applied section rule"
grep -q "pr: <url>" "$brief" || fail "brief: result line rule"
pass "builder route writes a lever-grouped brief with evidence"

# 7. Builder route with zero hq-core items writes no brief.
printf '{"thread_id":"T-x-zero1","deficiencies":[]}\n' > "$TMP_ROOT/zero.json"
out="$(run --thread "$TMP_ROOT/zero.json")"
expected="$(printf 'route: builder\nbrief: none (no hq-core deficiencies)')"
[ "$out" = "$expected" ] || fail "zero: got '$out'"
[ ! -f "$root/workspace/handoff-builder/zero1.md" ] || fail "zero: brief written"
pass "zero hq-core items write no brief"

# 8. Bad arguments exit 2.
set +e
run --thread "$TMP_ROOT/nope.json" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = "2" ] || fail "missing thread: rc $rc"
pass "missing thread file exits 2"

echo "PASS: handoff-builder-route"
