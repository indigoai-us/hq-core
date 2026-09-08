#!/usr/bin/env bash
# hq-core: public
# Regression tests for .claude/hooks/record-policy-retrieval.sh (2026-09-07).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"; H="$ROOT/.claude/hooks/record-policy-retrieval.sh"
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
L="$FX/workspace/orchestrator/policy-retrieval-state/s1.txt"
run() { printf '%s' "$1" | HQ_ROOT="$FX" CLAUDE_PROJECT_DIR="$FX" bash "$H"; }
echo "[1] Read of a policy file records its slug once"
run '{"session_id":"s1","tool_name":"Read","tool_input":{"file_path":"/x/companies/acme/policies/acme-deploy-rule.md"}}'
run '{"session_id":"s1","tool_name":"Read","tool_input":{"file_path":"/x/companies/acme/policies/acme-deploy-rule.md"}}'
[ "$(grep -c '^acme-deploy-rule$' "$L")" = 1 ] || fail "read not recorded once: $(cat "$L")"
echo "[2] Read of a non-policy file is ignored"
run '{"session_id":"s1","tool_name":"Read","tool_input":{"file_path":"/x/core/docs/README.md"}}'
[ "$(wc -l < "$L" | tr -d ' ')" = 1 ] || fail "non-policy recorded"
echo "[3] Bash: qmd get and a cat of a policy path both record"
run '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"qmd get -c acme acme-other-rule && cat personal/policies/hq-some-rule.md | head"}}'
grep -qx 'acme-other-rule' "$L" && grep -qx 'hq-some-rule' "$L" || fail "bash refs: $(cat "$L")"
echo "[4] conflict twins / digests are not recorded; other tools ignored; no session id is a no-op"
run '{"session_id":"s1","tool_name":"Read","tool_input":{"file_path":"/x/companies/acme/policies/_digest.md"}}'
run '{"session_id":"s1","tool_name":"Write","tool_input":{"file_path":"/x/companies/acme/policies/new.md"}}'
run '{"tool_name":"Read","tool_input":{"file_path":"/x/core/policies/z.md"}}'
[ "$(wc -l < "$L" | tr -d ' ')" = 3 ] || fail "unexpected records: $(cat "$L")"
echo "[5] age report exposes retrieved counts"
mkdir -p "$FX/core/policies"; printf -- '---\nid: acme-deploy-rule\nenforcement: hard\ncreated: 2026-01-01\nwhen: always\n---\n\n## Rule\n\nr\n' > "$FX/core/policies/acme-deploy-rule.md"
r="$(HQ_ROOT="$FX" HQ_POLICY_REPORT_NOW_EPOCH=1800000000 bash "$ROOT/core/scripts/policy-age-report.sh" --dir "$FX/core/policies" --json)"
[ "$(jq -r '.[0].retrieved' <<<"$r")" = 1 ] || fail "retrieved count: $r"
echo "record-policy-retrieval: ok"
