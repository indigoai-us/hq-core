#!/usr/bin/env bash
# hq-core: public
# Regression tests for core/scripts/verify-story-deliverables.sh (2026-09-07).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
S="$ROOT/core/scripts/verify-story-deliverables.sh"
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$FX/repo/src" "$FX/out"; git -C "$FX/repo" init -q; git -C "$FX/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$FX/repo" branch feature/done
: > "$FX/repo/src/exists.ts"
sha="$(git -C "$FX/repo" rev-parse --short HEAD)"
: > "$FX/out/exists.md"
cat > "$FX/prd.json" <<JSON
{"metadata":{"repoPath":"$FX/repo"},"userStories":[
 {"id":"US-001","title":"legacy","passes":false},
 {"id":"US-002","title":"present","deliverables":["path:$FX/out/exists.md","branch:feature/done","commit:$sha"]},
 {"id":"US-003","title":"missing","deliverables":["path:$FX/out/nope.md","branch:feature/never","repo-path:src/absent.ts"]},
 {"id":"US-004","title":"mixed","deliverables":["$FX/out/exists.md","path:$FX/out/nope.md"]}
]}
JSON
echo "[1] legacy story with no deliverables and no evidence passes (non-strict, \"unverified\") and fails under --strict"
HQ_ROOT="$FX" bash "$S" --prd "$FX/prd.json" --story US-001 >/dev/null || fail "undeclared should exit 0"
rc=0; HQ_ROOT="$FX" bash "$S" --prd "$FX/prd.json" --story US-001 --strict >/dev/null 2>&1 || rc=$?; [ "$rc" = 3 ] || fail "strict undeclared should exit 3, got $rc"
echo "[2] all present -> exit 0"
HQ_ROOT="$FX" bash "$S" --prd "$FX/prd.json" --story US-002 >/dev/null || fail "present should exit 0"
out="$(HQ_ROOT="$FX" bash "$S" --prd "$FX/prd.json" --story US-002 --json)"; [ "$(jq -r .status <<<"$out")" = present ] || fail "json status: $out"
echo "[3] missing -> exit 3, each named"
rc=0; err="$(HQ_ROOT="$FX" bash "$S" --prd "$FX/prd.json" --story US-003 2>&1 >/dev/null)" || rc=$?
[ "$rc" = 3 ] || fail "missing should exit 3, got $rc"
grep -q 'nope.md' <<<"$err" && grep -q 'feature/never' <<<"$err" && grep -q 'src/absent.ts' <<<"$err" || fail "missing items not named: $err"
grep -q 'Do not write passes:true' <<<"$err" || fail "must instruct not to pass"
echo "[4] mixed -> exit 3 and json lists both sides"
out="$(HQ_ROOT="$FX" bash "$S" --prd "$FX/prd.json" --story US-004 --json 2>/dev/null || true)"
[ "$(jq -r '.missing|length' <<<"$out")" = 1 ] && [ "$(jq -r '.present|length' <<<"$out")" = 1 ] || fail "mixed json: $out"
echo "[5a] worker evidence verified: present passes, claimed-but-missing fails"
HQ_ROOT="$FX" bash "$S" --prd "$FX/prd.json" --story US-001 --evidence-json "[\"path:$FX/out/exists.md\"]" --commits-json "[\"$sha\"]" >/dev/null || fail "evidence present should exit 0"
rc=0; err="$(HQ_ROOT="$FX" bash "$S" --prd "$FX/prd.json" --story US-001 --evidence-json "[\"path:$FX/out/ghost.md\"]" 2>&1 >/dev/null)" || rc=$?
[ "$rc" = 3 ] || fail "claimed-but-missing evidence should exit 3, got $rc"; grep -q 'ghost.md' <<<"$err" || fail "missing evidence not named"
rc=0; HQ_ROOT="$FX" bash "$S" --prd "$FX/prd.json" --story US-001 --commits-json '["deadbeef"]' >/dev/null 2>&1 || rc=$?; [ "$rc" = 3 ] || fail "unknown commit should exit 3, got $rc"
echo "[5b] --write records verified evidence on the story, nothing else changes"
before="$(jq -c 'del(.userStories[0].evidence)' "$FX/prd.json")"
HQ_ROOT="$FX" bash "$S" --prd "$FX/prd.json" --story US-001 --evidence-json "[\"path:$FX/out/exists.md\"]" --commits-json "[\"$sha\"]" --write >/dev/null || fail "write rc"
[ "$(jq -r '.userStories[0].evidence|length' "$FX/prd.json")" = 2 ] || fail "evidence not written: $(jq -c '.userStories[0]' "$FX/prd.json")"
jq -e '.userStories[0].evidence[0].verifiedAt' "$FX/prd.json" >/dev/null || fail "verifiedAt missing"
[ "$(jq -c 'del(.userStories[0].evidence)' "$FX/prd.json")" = "$before" ] || fail "--write touched more than the evidence field"
echo "[5c] declared deliverables and evidence are combined and de-duplicated"
out="$(HQ_ROOT="$FX" bash "$S" --prd "$FX/prd.json" --story US-002 --evidence-json "[\"path:$FX/out/exists.md\"]" --json)"; [ "$(jq -r '.present|length' <<<"$out")" = 3 ] || fail "dedup: $out"
echo "[5d] bad --evidence-json -> exit 2"
rc=0; HQ_ROOT="$FX" bash "$S" --prd "$FX/prd.json" --story US-001 --evidence-json 'nope' >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "bad json rc $rc"
echo "[5] unknown story -> exit 2"
rc=0; HQ_ROOT="$FX" bash "$S" --prd "$FX/prd.json" --story US-999 >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "unknown story should exit 2, got $rc"

echo "[6] Windows jq.exe CRLF lines preserve reference checks"
regression_failures=0
regression_fail() {
  echo "REGRESSION FAIL [$1]: $2" >&2
  regression_failures=$((regression_failures + 1))
}
mkdir -p "$FX/jq-bin"
real_jq="$(command -v jq)"
cat > "$FX/jq-bin/jq" <<'JQ'
#!/usr/bin/env bash
set -o pipefail
"$JQ_REAL" "$@" | sed 's/$/\r/'
JQ
chmod +x "$FX/jq-bin/jq"
crlf_rc=0
crlf_out="$(JQ_REAL="$real_jq" PATH="$FX/jq-bin:$PATH" HQ_ROOT="$FX" bash "$S" \
  --prd "$FX/prd.json" --story US-001 --evidence-json "[\"path:$FX/out/exists.md\",\"repo-path:src/exists.ts\",\"branch:feature/done\",\"commit:$sha\"]" --json \
  2>"$FX/crlf.err")" || crlf_rc=$?
crlf_status="$(jq -r '.status' <<<"$crlf_out")"
crlf_present="$(jq -r '.present | length' <<<"$crlf_out")"
if [ "$crlf_rc" != "0" ] || [ "$crlf_status" != "present" ] || [ "$crlf_present" != "4" ]; then
  regression_fail "crlf-reference-output" "expected present/4 references/exit 0; got $crlf_status/$crlf_present/exit $crlf_rc"
fi

echo "[7] recorded summary suffix is reserved for --write"
summary_without_write_rc=0
summary_without_write="$(JQ_REAL="$real_jq" PATH="$FX/jq-bin:$PATH" HQ_ROOT="$FX" bash "$S" --prd "$FX/prd.json" --story US-001 \
  --evidence-json "[\"path:$FX/out/exists.md\"]")" || summary_without_write_rc=$?
summary_with_write_rc=0
summary_with_write="$(JQ_REAL="$real_jq" PATH="$FX/jq-bin:$PATH" HQ_ROOT="$FX" bash "$S" --prd "$FX/prd.json" --story US-001 \
  --evidence-json "[\"path:$FX/out/exists.md\"]" --write)" || summary_with_write_rc=$?
if [ "$summary_without_write_rc" != "0" ] || [ "$summary_with_write_rc" != "0" ] || \
  [[ "$summary_without_write" == *"recorded on the story"* ]] || [[ "$summary_with_write" != *"recorded on the story"* ]]; then
  regression_fail "recorded-suffix-requires-write" "without --write (exit $summary_without_write_rc): $summary_without_write; with --write (exit $summary_with_write_rc): $summary_with_write"
fi
[ "$regression_failures" = "0" ] || fail "$regression_failures US-133 regression assertion(s) failed"
echo "verify-story-deliverables: ok"
