#!/usr/bin/env bash
# Tests for core/scripts/pipeline-envelope.sh (bash 3.2 portable).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PE="${PE_UNDER_TEST:-$HERE/../pipeline-envelope.sh}"
T="$(mktemp -d "${TMPDIR:-/tmp}/pe-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0

ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

# expect_rc <name> <want: 0|nonzero> <stderr-substring or ""> -- cmd...
expect() {
  name="$1"; want="$2"; needle="$3"; shift 4
  "$@" >"$T/out" 2>"$T/err"; rc=$?
  if [ "$want" = 0 ] && [ $rc -ne 0 ]; then bad "$name (rc=$rc: $(cat "$T/err"))"; return; fi
  if [ "$want" != 0 ] && [ $rc -eq 0 ]; then bad "$name (expected non-zero)"; return; fi
  if [ -n "$needle" ] && ! grep -qF -- "$needle" "$T/err"; then bad "$name (stderr lacks '$needle': $(cat "$T/err"))"; return; fi
  ok "$name"
}

ENV='{"schema":"hq-phase-envelope/v1","story_id":"US-005","phase":"backend","worker_id":"backend-dev","worktree":"/tmp/wt","incoming_handoff":null,"acceptance_criteria":["a","b"],"deadline":"2026-10-03T12:00:00Z","fresh_call":true}'
HO='{"schema":"hq-phase-handoff/v1","story_id":"US-005","phase":"backend","worker_id":"backend-dev","status":"passed","summary":"ok","files_changed":[],"commits":[],"back_pressure":{"tests":"pass","lint":"skip","typecheck":"skip","build":"skip"},"context_for_next":"none"}'

mk() { printf '%s' "$2" > "$T/$1"; }
# mutate <json> <python-expr on d>
mut() { printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); $2; print(json.dumps(d))"; }

mk env.json "$ENV"; mk ho.json "$HO"
expect "valid envelope exits 0" 0 "" -- "$PE" validate "$T/env.json"
expect "valid envelope with --kind" 0 "" -- "$PE" validate --kind envelope "$T/env.json"
expect "valid handoff exits 0" 0 "" -- "$PE" validate "$T/ho.json"
expect "envelope with string incoming_handoff" 0 "" -- sh -c "printf '%s' '$(mut "$ENV" "d['incoming_handoff']='/tmp/h.json'")' > '$T/e2.json' && '$PE' validate '$T/e2.json'"
expect "stdin input" 0 "" -- sh -c "'$PE' validate - < '$T/ho.json'"
mk o1.json "$(mut "$ENV" "d['constraints']=['no push','no deploy']; d['story_title']='T'; d['story_description']='D'")"
expect "envelope with optional constraints, story_title, story_description" 0 "" -- "$PE" validate --kind envelope "$T/o1.json"
mk o2.json "$(mut "$ENV" "d['constraints']='no push'")"
expect "constraints as string" 1 "wrong type: constraints (want array of strings)" -- "$PE" validate "$T/o2.json"
mk o3.json "$(mut "$ENV" "d['story_title']=7")"
expect "story_title as number" 1 "wrong type: story_title" -- "$PE" validate "$T/o3.json"

mk m1.json "$(mut "$HO" "del d['status']")"
expect "handoff missing status names status" 1 "missing field: status" -- "$PE" validate "$T/m1.json"
mk m2.json "$(mut "$ENV" "del d['deadline']")"
expect "envelope missing deadline" 1 "missing field: deadline" -- "$PE" validate "$T/m2.json"
mk m3.json "$(mut "$HO" "del d['back_pressure']['lint']")"
expect "handoff missing back_pressure.lint" 1 "missing field: back_pressure.lint" -- "$PE" validate "$T/m3.json"
mk m4.json "$(mut "$HO" "del d['schema']")"
expect "no schema, no --kind" 1 "missing field: schema" -- "$PE" validate "$T/m4.json"

mk w1.json "$(mut "$ENV" "d['fresh_call']='true'")"
expect "fresh_call as string" 1 "wrong type: fresh_call (want boolean)" -- "$PE" validate "$T/w1.json"
mk w2.json "$(mut "$HO" "d['files_changed']='a.sh'")"
expect "files_changed as string" 1 "wrong type: files_changed" -- "$PE" validate "$T/w2.json"
mk w3.json "$(mut "$HO" "d['status']='done'")"
expect "bad status enum" 1 "wrong type: status" -- "$PE" validate "$T/w3.json"
mk w4.json "$(mut "$HO" "d['back_pressure']['tests']='passed'")"
expect "bad back_pressure enum" 1 "wrong type: back_pressure.tests" -- "$PE" validate "$T/w4.json"
mk w5.json "$(mut "$ENV" "d['deadline']='tomorrow'")"
expect "non-ISO deadline" 1 "wrong type: deadline" -- "$PE" validate "$T/w5.json"
mk w6.json "$(mut "$ENV" "d['acceptance_criteria']=[1]")"
expect "acceptance_criteria non-string items" 1 "wrong type: acceptance_criteria" -- "$PE" validate "$T/w6.json"
expect "--kind handoff on an envelope" 1 "wrong type: schema" -- "$PE" validate --kind handoff "$T/env.json"

mk nj.txt "this is not json {"
expect "non-JSON file" 1 "unparseable" -- "$PE" validate "$T/nj.txt"
: > "$T/empty.json"
expect "empty file" 1 "empty" -- "$PE" validate "$T/empty.json"
mk arr.json "[$HO]"
expect "array top level" 1 "top level" -- "$PE" validate "$T/arr.json"
expect "missing file" 1 "not found" -- "$PE" validate "$T/nope.json"
mk trunc.json '{"schema":"hq-phase-handoff/v1",'
expect "truncated JSON" 1 "unparseable" -- "$PE" validate "$T/trunc.json"

mk nan.json "${HO%\}},\"x\":NaN}"
expect "NaN constant is rejected as non-JSON" 1 "unparseable" -- "$PE" validate "$T/nan.json"
mk inf.json "${ENV%\}},\"y\":-Infinity}"
expect "Infinity constant is rejected as non-JSON" 1 "unparseable" -- "$PE" validate "$T/inf.json"
printf 'reply: {"schema":"hq-phase-handoff/v1","x":NaN}\n' > "$T/nan.txt"
expect "normalize rejects NaN object" 1 "no JSON object" -- "$PE" normalize "$T/nan.txt"

# normalize
printf 'Here is the handoff:\n```json\n%s\n```\nDone.\n' "$HO" > "$T/fenced.txt"
expect "normalize fenced reply" 0 "" -- sh -c "'$PE' normalize '$T/fenced.txt' > '$T/n1.json' && '$PE' validate '$T/n1.json'"
printf 'Sure. %s That is all.\n' "$HO" > "$T/prose.txt"
expect "normalize prose-wrapped reply" 0 "" -- sh -c "'$PE' normalize '$T/prose.txt' > '$T/n2.json' && '$PE' validate '$T/n2.json'"
printf '%s\n' "$HO" > "$T/bare.txt"
expect "normalize bare JSON" 0 "" -- sh -c "'$PE' normalize '$T/bare.txt' > '$T/n3.json' && '$PE' validate '$T/n3.json'"
printf '```\n%s\n```\n' "$HO" > "$T/plainfence.txt"
expect "normalize untagged fence" 0 "" -- sh -c "'$PE' normalize '$T/plainfence.txt' > '$T/n4.json' && '$PE' validate '$T/n4.json'"
printf 'no json here at all\n' > "$T/none.txt"
expect "normalize with no object fails" 1 "no JSON object" -- "$PE" normalize "$T/none.txt"
printf '{"a":1} and {"b":2}\n' > "$T/two.txt"
expect "normalize with two untagged objects fails" 1 "expected exactly one" -- "$PE" normalize "$T/two.txt"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ $fail -eq 0 ]
