#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; s="$here/../source-yaml-validate.sh"; root="$here/../../.."
fail=0; pass=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "FAIL: $1 — want '$3' got '$2'"; fail=$((fail+1)); fi; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
bash "$s" "$root/companies/_template/sources/meetings/source.yaml" >/dev/null; check "template valid" "$?" 0
mk() { mkdir -p "$t/$1"; printf '%b' "$2" > "$t/$1/source.yaml"; echo "$t/$1/source.yaml"; }
base='kind: doc\narrives: drop\nprocessor: ontology/process-source\nrun: local\nschedule: on-close\n'
f="$(mk docs "channel: docs\n$base")"
out="$(bash "$s" "$f")"; check "missing audience_rule fails" "$?" 1
check "message names audience_rule" "$(printf '%s' "$out" | grep -c audience_rule)" 1
f="$(mk crm "channel: crm\nkind: custom\narrives: pull\naudience_rule: explicit\nprocessor: ontology/process-source\nrun: cloud\nschedule: '0 * * * *'\n")"
out="$(bash "$s" "$f")"; check "pull without pull_command fails" "$?" 1
check "message names pull_command" "$(printf '%s' "$out" | grep -c pull_command)" 1
f="$(mk fax "channel: fax\nkind: fax\narrives: drop\naudience_rule: company\nprocessor: ontology/process-source\nrun: local\nschedule: on-close\n")"
bash "$s" "$f" >/dev/null; check "unknown kind fails" "$?" 1
f="$(mk wrong "channel: other\n${base}audience_rule: company\n")"
bash "$s" "$f" >/dev/null; check "channel/folder mismatch fails" "$?" 1
bash "$s" "$t/nope.yaml" >/dev/null 2>&1; check "missing file exits 2" "$?" 2
echo "source-yaml-validate: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
