#!/usr/bin/env bash
# Regression tests: /retro SESSION mode merges thread deficiencies[] from the
# last 24h with its own items, dedupes by lever + summary, drops items without
# evidence, and writes a thread file the handoff autofile script accepts.
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/var/tmp}/retro-merge-test.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

SCRIPT="$SRC_ROOT/scripts/retro-merge-deficiencies.sh"
root="$TMP_ROOT/hq"
threads="$root/workspace/threads"
mkdir -p "$threads"

cat > "$threads/T-old.json" <<'JSON'
{"thread_id":"T-old","system_info":{"os":"old"},
 "deficiencies":[{"lever":"navigation","kind":"hq-core","severity":"low","summary":"stale","evidence":"e"}]}
JSON
touch -t 202001010000 "$threads/T-old.json"

cat > "$threads/T-a.json" <<'JSON'
{"thread_id":"T-a","system_info":{"os":"a"},
 "deficiencies":[
  {"lever":"no-ops","kind":"hq-core","severity":"medium","summary":"hook did nothing","evidence":"ran twice"},
  {"lever":"tool-economy","kind":"repo","severity":"low","summary":"no evidence","evidence":""}]}
JSON
touch -t 202501010000 "$threads/T-a.json"
touch "$threads/T-a.json"

cat > "$threads/T-b.json" <<'JSON'
{"thread_id":"T-b","deficiencies":[
  {"lever":"no-ops","kind":"hq-core","severity":"medium","summary":"hook did nothing","evidence":"dup"},
  {"lever":"steering-bloat","kind":"hq-core","severity":"high","summary":"policies truncated","evidence":"cut"}]}
JSON
printf 'not json' > "$threads/broken.json"

retro="$TMP_ROOT/retro.json"
cat > "$retro" <<'JSON'
[{"lever":"steering-bloat","kind":"hq-core","severity":"high","summary":"policies truncated","evidence":"retro saw it"},
 {"lever":"information-access","kind":"local-setup","severity":"low","summary":"no token","evidence":"401"}]
JSON

echo "retro-merge-deficiencies"

out="$(bash "$SCRIPT" --root "$root" --retro-json "$retro")"
n="$(jq 'length' <<<"$out")"
[ "$n" -eq 3 ] || fail "expected 3 merged items, got $n: $out"
pass "merges retro and recent thread items, dedupes, drops empty evidence"

jq -e 'map(select(.summary == "stale")) | length == 0' <<<"$out" >/dev/null || fail "item older than 24h was merged"
pass "ignores threads older than the window"

ev="$(jq -r '.[] | select(.summary == "policies truncated") | .evidence' <<<"$out")"
[ "$ev" = "retro saw it" ] || fail "retro item should win duplicates, got: $ev"
pass "retro item wins a duplicate lever + summary"

src="$(jq -r '.[] | select(.summary == "hook did nothing") | .source' <<<"$out")"
case "$src" in T-a.json|T-b.json) ;; *) fail "thread source missing: $src" ;; esac
pass "thread items carry their source file"

thread_out="$TMP_ROOT/retro-thread.json"
line="$(bash "$SCRIPT" --root "$root" --retro-json "$retro" --out "$thread_out")"
case "$line" in "merged: 3 item(s) -> $thread_out") ;; *) fail "unexpected --out line: $line" ;; esac
jq -e '.thread_id == "retro-session" and (.deficiencies | length) == 3 and (.system_info | type) == "object"' "$thread_out" >/dev/null \
  || fail "synthetic thread has wrong shape"
pass "--out writes a thread file with deficiencies and system_info"

hq_items="$(jq -c '[(.deficiencies // [])[] | select(.kind == "hq-core")] | length' "$thread_out")"
[ "$hq_items" -eq 2 ] || fail "expected 2 hq-core items for autofile, got $hq_items"
pass "synthetic thread exposes hq-core items the autofile script selects"

empty="$(bash "$SCRIPT" --root "$TMP_ROOT/none")"
[ "$empty" = "[]" ] || fail "missing threads dir should yield [], got $empty"
pass "no threads and no retro items yields []"

if bash "$SCRIPT" --root "$root" --retro-json "$TMP_ROOT/missing.json" >/dev/null 2>&1; then
  fail "missing --retro-json file should fail"
fi
pass "missing retro json is an error"

co_root="$TMP_ROOT/co"
mkdir -p "$co_root/workspace/threads"
cat > "$co_root/workspace/threads/T-x.json" <<'JSON'
{"thread_id":"T-x","metadata":{"company":["acme"]},
 "deficiencies":[{"lever":"no-ops","kind":"hq-core","severity":"low","summary":"acme item","evidence":"e"}]}
JSON
cat > "$co_root/workspace/threads/T-y.json" <<'JSON'
{"thread_id":"T-y","metadata":{"company":"other"},
 "deficiencies":[{"lever":"no-ops","kind":"hq-core","severity":"low","summary":"other item","evidence":"e"}]}
JSON
scoped="$(bash "$SCRIPT" --root "$co_root" --company acme)"
jq -e 'length == 1 and .[0].summary == "acme item"' <<<"$scoped" >/dev/null \
  || fail "--company should keep only that company's threads, got $scoped"
pass "--company keeps other companies' threads out of the merge"

echo "all retro-merge-deficiencies tests passed"
