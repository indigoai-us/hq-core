#!/usr/bin/env bash
# hq-core: public
# Regression tests for core/scripts/policy-benchmark.sh (2026-09-07).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"; S="$ROOT/core/scripts/policy-benchmark.sh"
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$FX/corpus" "$FX/workspace/orchestrator/policy-trigger-state" "$FX/workspace/orchestrator/policy-retrieval-state" "$FX/host/p1/tool-results"
pol() { printf -- '---\nid: %s\ntitle: t\nscope: test\nwhen: %s\non: [UserPromptSubmit]\nenforcement: %s\n---\n\n## Rule\n\n%s\n\nDetail for %s.\n' "$2" "$3" "$4" "$2 summary" "$2" > "$1"; }
pol "$FX/corpus/deploy-guard.md" deploy-guard "deploy" hard
pol "$FX/corpus/vercel-note.md"  vercel-note  "vercel" soft
pol "$FX/corpus/unrelated.md"    unrelated    "kubernetes" soft
cat > "$FX/scenarios.json" <<JSON
[{"name":"deploy prompt","event":"UserPromptSubmit","prompt":"please deploy the vercel site","expect":["deploy-guard","vercel-note"],"expect_full":["deploy-guard"]},
 {"name":"off-topic","event":"UserPromptSubmit","prompt":"write a poem","expect":[],"expect_full":[]}]
JSON
echo "[1] scenarios: recall, full-text for reactive hard, bytes under ceiling"
out="$(HQ_ROOT="$ROOT" bash "$S" scenarios --file "$FX/scenarios.json" --corpus "$FX/corpus" --json)" || fail "scenarios rc: $out"
[ "$(jq -r .recall <<<"$out")" = "1.000" ] || fail "recall: $out"
[ "$(jq -r '.scenarios[0].hard_full' <<<"$out")" = 1 ] || fail "hard full: $out"
jq -e '.scenarios[] | .under_ceiling' <<<"$out" >/dev/null || fail "ceiling"
echo "[2] scenarios: a missing expectation is named and the run exits non-zero"
printf '[{"name":"x","prompt":"deploy","expect":["deploy-guard","nope-rule"]}]' > "$FX/s2.json"
rc=0; out="$(HQ_ROOT="$ROOT" bash "$S" scenarios --file "$FX/s2.json" --corpus "$FX/corpus" --json)" || rc=$?
[ "$rc" != 0 ] || fail "should fail on missing"; jq -e '.scenarios[0].missing | index("nope-rule")' <<<"$out" >/dev/null || fail "missing not named: $out"
echo "[3] live: counts truncated outputs, sessions, retrieval rate"
: > "$FX/host/p1/tool-results/hook-aaa-stdout.txt"; : > "$FX/host/p1/tool-results/hook-bbb-stdout.txt"
printf 'a\nb\nc\nd\n' > "$FX/workspace/orchestrator/policy-trigger-state/s1.txt"; printf 'a\nb\n' > "$FX/workspace/orchestrator/policy-trigger-state/s2.txt"
printf 'a\n' > "$FX/workspace/orchestrator/policy-retrieval-state/s1.txt"
out="$(HQ_ROOT="$FX" HQ_HOST_TOOL_RESULTS_GLOB="$FX/host/*/tool-results" bash "$S" live --days 1 --json)"
[ "$(jq -r .truncated_hook_outputs <<<"$out")" = 2 ] || fail "trunc: $out"
[ "$(jq -r .sessions <<<"$out")" = 2 ] || fail "sessions: $out"
[ "$(jq -r .fired_per_session_median <<<"$out")" = 3 ] || fail "fired median: $out"
[ "$(jq -r .retrieval_rate <<<"$out")" = "0.167" ] || fail "rate: $out"
echo "[4] live: injector sibling files are not sessions, and an empty ledger counts once as 0 (feedback_7ff5406c)"
L2="$FX/live2/workspace/orchestrator/policy-trigger-state"; R2="$FX/live2/workspace/orchestrator/policy-retrieval-state"
mkdir -p "$L2" "$R2" "$FX/live2/host"
printf 'a\nb\nc\nd\n' > "$L2/s1.txt"; printf 'a\nb\n' > "$L2/s2.txt"; : > "$L2/s3.txt"
printf 'x\n' > "$L2/s1.turn.txt"; : > "$L2/s1.footer.txt"; printf 'x\n' > "$L2/s1.full.txt"; : > "$L2/s2.deferred-soft.txt"
printf 'a\n' > "$R2/s1.txt"; : > "$R2/s3.txt"
out="$(HQ_ROOT="$FX/live2" HQ_HOST_TOOL_RESULTS_GLOB="$FX/live2/host/*/tool-results" bash "$S" live --days 1 --json)"
[ "$(jq -r .sessions <<<"$out")" = 3 ] || fail "sibling files counted as sessions: $out"
[ "$(jq -r .fired_per_session_median <<<"$out")" = 2 ] || fail "fired median (4,2,0): $out"
[ "$(jq -r .retrieved_per_session_median <<<"$out")" = 0 ] || fail "retrieved median (1,0,0): $out"
[ "$(jq -r .retrieval_rate <<<"$out")" = "0.167" ] || fail "rate: $out"
txt="$(HQ_ROOT="$FX/live2" HQ_HOST_TOOL_RESULTS_GLOB="$FX/live2/host/*/tool-results" bash "$S" live --days 1)"
case "$txt" in *"sessions=3 fired/session(median)=2 retrieved/session(median)=0 "*) ;; *) fail "text report: $txt" ;; esac
echo "policy-benchmark: ok"
