#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/root"
mkdir -p "$FIXTURE/.claude/hooks" "$FIXTURE/.codex/hooks" \
  "$FIXTURE/.grok/hooks" "$FIXTURE/core/scripts" \
  "$FIXTURE/companies/hp11-benchmark" "$FIXTURE/workspace"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

assert_report_shape() {
  local runtime="$1" report="$2"
  jq -e --arg runtime "$runtime" '
    .runtime == $runtime and (.events | type == "string") and
    (.runs | type == "number") and (.registrations | type == "array") and
    all(.registrations[]; has("event") and has("registration") and
      has("median_ms") and has("min_ms") and has("max_ms"))
  ' "$report" >/dev/null || fail "$runtime report does not preserve the Claude JSON shape"
}

cat > "$FIXTURE/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/capture.sh\""}]}],
    "PostToolUse": [{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/capture.sh\""}]}],
    "UserPromptSubmit": [{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/capture.sh\""}]}]
  }
}
JSON
cat > "$FIXTURE/.claude/hooks/capture.sh" <<'HOOK'
#!/usr/bin/env bash
cat >> "$BENCH_CAPTURE"
printf '%s\n' 'fixture context'
HOOK
cat > "$FIXTURE/.claude/hooks/master-hook.sh" <<'HOOK'
#!/usr/bin/env bash
cat > "$BENCH_CAPTURE"
printf '%s\n' 'fixture context'
HOOK

for runtime in codex grok; do
  case "$runtime" in
    codex) adapter="$FIXTURE/.codex/hooks/hq-codex-hook-adapter.sh" ;;
    grok) adapter="$FIXTURE/.grok/hooks/hq-grok-hook-adapter.sh" ;;
  esac
  cat > "$adapter" <<'HOOK'
#!/usr/bin/env bash
cat >> "$BENCH_CAPTURE"
printf '%s\n' '{"hookSpecificOutput":{"additionalContext":"fixture adapter context"}}'
HOOK
  chmod +x "$adapter"
done

cat > "$FIXTURE/core/scripts/hq-agent-session.sh" <<'AGENT'
#!/usr/bin/env bash
request="$(cat)"
printf '%s\n' "$request" >> "$BENCH_CAPTURE"
run_dir="$HOME/.hq/agent-session/hp11-fixture"
mkdir -p "$run_dir"
printf '%s\n' 'fixture agent context' > "$run_dir/system.txt"
printf '%s\n' "$HOME" > "$BENCH_HOME_CAPTURE"
jq -nc --arg run_dir "$run_dir" '{runDir:$run_dir,disposition:"reply",text:"fixture"}'
AGENT
chmod +x "$FIXTURE/.claude/hooks/capture.sh" "$FIXTURE/.claude/hooks/master-hook.sh" \
  "$FIXTURE/core/scripts/hq-agent-session.sh"

export CLAUDE_PROJECT_DIR="$FIXTURE" BASH_ENV=/dev/null

# Grok's adapter output is not benchmark-visible for these events. The bench
# must reject it explicitly instead of publishing a successful zero-byte row.
if BENCH_CAPTURE="$TMP/grok-unsupported.in" bash "$ROOT/core/scripts/bench-hooks.sh" \
  --runtime grok --events UserPromptSubmit --quiet --json "$TMP/grok-unsupported.json" \
  >"$TMP/grok-unsupported.out" 2>&1; then
  fail "Grok benchmark unexpectedly accepted unobservable adapter output"
fi
grep -Fq 'unsupported: the adapter does not expose benchmark-visible output' \
  "$TMP/grok-unsupported.out" || fail "Grok rejection did not explain missing benchmark-visible output"

# Existing callers remain on Claude by default, and JSON names that runtime.
BENCH_CAPTURE="$TMP/claude.in" bash "$ROOT/core/scripts/bench-hooks.sh" \
  --events UserPromptSubmit --quiet --json "$TMP/claude.json" >/dev/null \
  || fail "default Claude benchmark invocation failed"
jq -e '.runtime == "claude"' "$TMP/claude.json" >/dev/null \
  || fail "default JSON report did not identify Claude runtime"
assert_report_shape claude "$TMP/claude.json"
pass "default Claude path remains available and JSON reports runtime"

# Codex receives the snake_case hook payload used by its real adapter.
BENCH_CAPTURE="$TMP/codex.in" bash "$ROOT/core/scripts/bench-hooks.sh" \
  --runtime codex --events PreToolUse --quiet --json "$TMP/codex.json" >/dev/null \
  || fail "Codex runtime benchmark invocation failed"
jq -e '.runtime == "codex"' "$TMP/codex.json" >/dev/null \
  || fail "Codex JSON report did not identify runtime"
assert_report_shape codex "$TMP/codex.json"
jq -e 'select(.hook_event_name == "PreToolUse" and .tool_name == "Bash" and (.tool_input.command | type == "string"))' \
  "$TMP/codex.in" >/dev/null || fail "Codex adapter did not receive its expected payload"
pass "Codex dispatch uses its adapter entrypoint and payload"

# The hq-agent runtime goes through the request-envelope entrypoint, not hooks
# invoked directly; the fixture provider is skipped by the benchmark.
BENCH_CAPTURE="$TMP/agent.in" BENCH_HOME_CAPTURE="$TMP/agent.home" HOME="$TMP/home" bash "$ROOT/core/scripts/bench-hooks.sh" \
  --runtime hq-agent --quiet --json "$TMP/agent.json" >/dev/null \
  || fail "hq-agent runtime benchmark invocation failed"
jq -e '.runtime == "hq-agent"' "$TMP/agent.json" >/dev/null \
  || fail "hq-agent JSON report did not identify runtime"
assert_report_shape hq-agent "$TMP/agent.json"
jq -e '.contractVersion == 1 and .companySlug == "hp11-benchmark" and .messageText != "" and .sender.verified == true' \
  "$TMP/agent.in" >/dev/null || fail "hq-agent entrypoint did not receive a request envelope"
grep -Eq '^/tmp/bench-hooks\.[^/]+/home$' "$TMP/agent.home" \
  || fail "hq-agent benchmark did not isolate HOME under its temporary directory"
pass "hq-agent dispatch uses a request envelope"

# Corpus captures preserve the HP-5 item set; the session entrypoint has no
# PostToolUse event, which must be represented explicitly rather than passed.
cat > "$TMP/corpus.json" <<'JSON'
{"version":1,"prompts":[{"id":"p1","prompt":"bench prompt","expect_hints":[]}],"commands":[{"id":"c1","command":"echo bench"}]}
JSON
for runtime in claude codex hq-agent; do
  BENCH_CAPTURE="$TMP/corpus-$runtime.in" BENCH_HOME_CAPTURE="$TMP/corpus-$runtime.home" HQ_ROOT="$FIXTURE" \
    HOME="$TMP/home-$runtime" bash "$ROOT/core/scripts/bench-hook-corpus.sh" run \
      --runtime "$runtime" --corpus "$TMP/corpus.json" --out "$TMP/corpus-$runtime.json" \
      >/dev/null || fail "corpus benchmark failed for $runtime"
  jq -e --arg runtime "$runtime" '.runtime == $runtime' "$TMP/corpus-$runtime.json" >/dev/null \
    || fail "corpus report did not identify $runtime"
done
if HQ_ROOT="$FIXTURE" HOME="$TMP/home-grok" bash "$ROOT/core/scripts/bench-hook-corpus.sh" run \
  --runtime grok --corpus "$TMP/corpus.json" --out "$TMP/corpus-grok.json" \
  >"$TMP/corpus-grok.out" 2>&1; then
  fail "Grok corpus benchmark unexpectedly accepted unobservable adapter output"
fi
grep -Fq 'unsupported: the adapter does not expose benchmark-visible output' \
  "$TMP/corpus-grok.out" || fail "Grok corpus rejection did not explain missing benchmark-visible output"
jq -e '.items[] | select(.id == "c1") | .supported == false and (.unsupported_reason | length > 0)' \
  "$TMP/corpus-hq-agent.json" >/dev/null \
  || fail "hq-agent PostToolUse item was not marked unsupported"
grep -Eq '^/tmp/bench-hook-corpus\.[^/]+/home$' "$TMP/corpus-hq-agent.home" \
  || fail "hq-agent corpus benchmark did not isolate HOME under its temporary directory"
pass "corpus runtime reports identify each runtime and mark hq-agent PostToolUse unsupported"

jq '.items[0].status = "failed" | .items[0].exit_code = 125' \
  "$TMP/corpus-claude.json" > "$TMP/corpus-failed.json"
if bash "$ROOT/core/scripts/bench-hook-corpus.sh" compare \
  "$TMP/corpus-claude.json" "$TMP/corpus-failed.json" > "$TMP/failed-compare.out" 2>&1; then
  fail "corpus compare accepted a failed candidate execution"
fi
grep -Fq 'execution status completed -> failed' "$TMP/failed-compare.out" \
  || fail "corpus compare did not report the failed candidate status transition"
pass "corpus compare rejects candidate event execution failures"

echo "ALL PASS: bench-hooks-runtime"
