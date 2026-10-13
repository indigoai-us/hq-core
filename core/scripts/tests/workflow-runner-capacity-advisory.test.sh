#!/bin/bash
# hq-core: public
# US-010: workflow-runner prints one capacity advisory before spawning an
# engine, and a missing, failing, slow, stale, disabled, or malformed ledger
# prints nothing and still dispatches. Uses a stub `hq` and a fake codex binary.
# Does not read or write ~/.hq/capacity. The runner calls `hq capacity --json`;
# it does not read now.json.

set -uo pipefail
# These cases cover the opt-in codex engine; the claude default and the codex
# gate are covered in workflow-runner-engine-default.test.sh.
export HQ_ALLOW_CODEX=1 HQ_WORKFLOW_ENGINE=codex

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RUNNER="$REPO_ROOT/core/scripts/workflow-runner.mjs"
NODE="$(command -v node)"

pass=0
fail=0
check() {
  if [ "$2" -eq 0 ]; then
    printf 'ok   - %s\n' "$1"; pass=$((pass + 1))
  else
    printf 'FAIL - %s\n' "$1"; fail=$((fail + 1))
  fi
}

TMP="$(mktemp -d /tmp/workflow-runner-capacity-advisory.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
mkdir -p "$TMP/bin" "$TMP/scratch-bin" "$TMP/rec" "$TMP/capacity" "$TMP/hqroot/.claude" "$TMP/hqroot/workspace"
printf '{}\n' > "$TMP/hqroot/.claude/settings.json"
# Missing-hq PATH is only these three. /usr/bin can contain a real hq.
ln -sf "$(command -v node)" "$TMP/scratch-bin/node"
ln -sf "$(command -v bash)" "$TMP/scratch-bin/bash"
ln -sf "$(command -v env)" "$TMP/scratch-bin/env"

cat > "$TMP/bin/codex" <<'FAKE'
#!/usr/bin/env bash
rec="${FAKE_REC_DIR:?}"
n="$$-$RANDOM"
printf '%s\n' "$@" > "$rec/codex-argv.$n"
last=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output-last-message) last="$2"; shift 2 ;;
    -C|-c|-m|--color|--sandbox) shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$last" ]; then printf 'echo:ok\n' > "$last"; fi
exit 0
FAKE
chmod +x "$TMP/bin/codex"

cat > "$TMP/bin/hq" <<'FAKE'
#!/usr/bin/env bash
rec="${FAKE_REC_DIR:?}"
printf '%s\n' "$@" >> "$rec/hq-argv"
# Mesh bookkeeping also calls hq. Only the capacity read is under test.
if [ "${1:-}" != "capacity" ]; then
  exit 0
fi
fresh_view() {
  local now obs
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  obs="$(date -u -v-90S +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "{\"stale\":false,\"collectorEnabled\":null,\"generatedAt\":\"${now}\",\"providers\":[{\"provider\":\"claude\",\"state\":\"ok\",\"limits\":[{\"kind\":\"weekly_all\",\"usedPercent\":8,\"secondsToReset\":100,\"observedAt\":\"${obs}\"}]},{\"provider\":\"codex\",\"state\":\"ok\",\"limits\":[{\"kind\":\"weekly_all\",\"usedPercent\":61,\"secondsToReset\":583200,\"observedAt\":\"${obs}\"}]},{\"provider\":\"grok\",\"state\":\"ok\",\"limits\":[{\"kind\":\"weekly_all\",\"usedPercent\":40,\"secondsToReset\":50,\"observedAt\":\"${obs}\"}]}]}"
}

mode="${HQ_STUB_MODE:-ok}"
case "$mode" in
  fail) exit 1 ;;
  slow)
    sleep 8
    fresh_view
    exit 0
    ;;
  stale)
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "{\"stale\":true,\"collectorEnabled\":null,\"generatedAt\":\"${now}\",\"providers\":[]}"
    exit 0
    ;;
  disabled)
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    obs="$(date -u -v-90S +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "{\"stale\":false,\"collectorEnabled\":false,\"generatedAt\":\"${now}\",\"providers\":[{\"provider\":\"codex\",\"state\":\"ok\",\"limits\":[{\"kind\":\"weekly_all\",\"usedPercent\":61,\"secondsToReset\":583200,\"observedAt\":\"${obs}\"}]}]}"
    exit 0
    ;;
  garbage)
    printf '%s\n' 'this is not json'
    exit 0
    ;;
  bad-providers)
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "{\"stale\":false,\"collectorEnabled\":null,\"generatedAt\":\"${now}\",\"providers\":{\"codex\":61}}"
    exit 0
    ;;
  old)
    printf '%s\n' '{"stale":false,"collectorEnabled":null,"generatedAt":"2020-01-01T00:00:00.000Z","providers":[{"provider":"codex","state":"ok","limits":[{"kind":"weekly_all","usedPercent":61,"secondsToReset":583200,"observedAt":"2020-01-01T00:00:00.000Z"}]}]}'
    exit 0
    ;;
  help)
    printf '%s\n' 'Usage: hq <command>'
    printf '%s\n' 'Commands:'
    printf '%s\n' '  sync'
    exit 0
    ;;
  *)
    fresh_view
    exit 0
    ;;
esac
FAKE
chmod +x "$TMP/bin/hq"

cat > "$TMP/wf.mjs" <<'EOF'
const text = await agent("ping-capacity", { label: "ping", tier: "exec", timeoutSecs: 30 });
return { text };
EOF

cat > "$TMP/wf-two.mjs" <<'EOF'
const a = await agent("ping-capacity", { label: "ping", tier: "exec", timeoutSecs: 30 });
const b = await agent("ping-capacity-2", { label: "ping2", tier: "exec", timeoutSecs: 30 });
return { a, b };
EOF

cat > "$TMP/wf-repair.mjs" <<'EOF'
const text = await agent("ping-capacity", {
  label: "ping",
  tier: "exec",
  timeoutSecs: 30,
  schema: { type: "object", required: ["pong"], properties: { pong: { type: "number" } } },
});
return { text };
EOF

capacity_calls() {
  local n=0
  if [ -f "$TMP/rec/hq-argv" ]; then
    n="$(grep -c '^capacity$' "$TMP/rec/hq-argv" || true)"
  fi
  printf '%s\n' "${n:-0}"
}

codex_execs() {
  local n=0 f
  for f in "$TMP/rec"/codex-argv.*; do
    [ -e "$f" ] || continue
    if grep -q '^exec$' "$f"; then n=$((n + 1)); fi
  done
  printf '%s\n' "$n"
}

run_case() { # name, path, stub mode, [noise], [script], [prep], [root]
  local name="$1" path_value="$2" mode="$3"
  local noise="${4:-loud}"
  local script="${5:-$TMP/wf.mjs}"
  local prep="${6:-}"
  local root="${7:-$TMP/capacity}"
  local run="$TMP/run-$RANDOM"
  local err="$TMP/err-$RANDOM"
  rm -rf "$TMP/rec/hq-argv" "$TMP/capacity/advisories.jsonl"
  find "$TMP/rec" -name 'codex-argv.*' -delete
  if [ "$prep" = "block-jsonl" ]; then
    mkdir -p "$TMP/capacity/advisories.jsonl"
  fi
  local -a runner_args
  if [ "$noise" = "quiet" ]; then
    runner_args=(--quiet --run-dir "$run")
  else
    runner_args=(--run-dir "$run")
  fi
  env -u HQ_SPAWN_COMPANY -u HQ_SPAWN_COMPANIES -u HQ_SPAWN_PROJECT \
  -u HQ_PARENT_SESSION_ID -u HQ_SESSION_ID \
  HQ_STUB_MODE="$mode" \
  HQ_CAPACITY_ROOT="$root" \
  HQ_SPAWN_TASK="US-010" \
  FAKE_REC_DIR="$TMP/rec" \
  HQ_WORKFLOW_CODEX_BIN="$TMP/bin/codex" \
  HQ_WORKFLOW_CPU_CHECK=0 \
  HQ_ROOT="$TMP/hqroot" \
  PATH="$path_value" \
  "$NODE" "$RUNNER" "$script" "${runner_args[@]}" >"$TMP/out-$RANDOM" 2>"$err"
  local code=$?
  printf '%s\n' "$code" > "$TMP/last-code"
  cp "$err" "$TMP/last-err"
  cp "$err" "$TMP/err-$name"
}

# Success: exact line, one JSONL record, mode 0600, engine still ran.
# Loud on purpose: --quiet must hide the line, so the happy path cannot use it.
run_case success "$TMP/bin:/usr/bin:/bin" ok loud
check "success exits 0" "$( [ "$(cat "$TMP/last-code")" -eq 0 ] && echo 0 || echo 1 )"
check "success advisory line" "$(grep -F 'capacity: codex weekly 61% used, resets in 6d 18h (observed 1m ago); claude weekly 8%; grok weekly 40%' "$TMP/last-err" >/dev/null && echo 0 || echo 1)"
check "success one advisory line" "$( [ "$(grep -c 'capacity:' "$TMP/last-err")" -eq 1 ] && echo 0 || echo 1 )"
check "success advisory has no em dash" "$( "$NODE" -e 'const fs=require("fs"); const line=fs.readFileSync(process.argv[1],"utf8").split("\n").find((row)=>row.includes("capacity:"))||""; process.exit(line && !line.includes("\u2014") ? 0 : 1)' "$TMP/last-err" && echo 0 || echo 1 )"
check "success engine spawned" "$( find "$TMP/rec" -name 'codex-argv.*' | grep -q . && echo 0 || echo 1 )"
check "success hq was called once" "$( [ "$(capacity_calls)" -eq 1 ] && echo 0 || echo 1 )"
"$NODE" -e '
const fs = require("fs");
const file = process.argv[1];
const lines = fs.readFileSync(file, "utf8").trim().split("\n");
if (lines.length !== 1) process.exit(1);
const row = JSON.parse(lines[0]);
const ok = row.caller === "workflow-runner"
  && row.story === "US-010"
  && row.chosenEngine === "codex"
  && row.naiveEngine === "claude"
  && row.agree === false
  && Array.isArray(row.providers)
  && row.providers[0].weeklyUsedPercent === 8
  && row.providers[1].weeklyUsedPercent === 61
  && row.providers[2].weeklyUsedPercent === 40
  && typeof row.at === "string"
  && (fs.statSync(file).mode & 0o777) === 0o600;
process.exit(ok ? 0 : 1);
' "$TMP/capacity/advisories.jsonl"
check "success jsonl shape and mode" "$?"

# Missing hq on PATH: scratch bin has node, bash, and env only.
run_case missing "$TMP/scratch-bin" ok
check "scratch path has no hq" "$( PATH="$TMP/scratch-bin" command -v hq >/dev/null 2>&1 && echo 1 || echo 0 )"
check "missing hq exits 0" "$( [ "$(cat "$TMP/last-code")" -eq 0 ] && echo 0 || echo 1 )"
check "missing hq is silent" "$( grep -q 'capacity:' "$TMP/last-err" && echo 1 || echo 0 )"
check "missing hq writes nothing" "$( [ ! -e "$TMP/capacity/advisories.jsonl" ] && echo 0 || echo 1 )"
check "missing hq still spawns" "$( find "$TMP/rec" -name 'codex-argv.*' | grep -q . && echo 0 || echo 1 )"

# hq exits 1.
run_case fail "$TMP/bin:/usr/bin:/bin" fail
check "hq exit 1 is silent" "$( [ "$(cat "$TMP/last-code")" -eq 0 ] && ! grep -q 'capacity:' "$TMP/last-err" && [ ! -e "$TMP/capacity/advisories.jsonl" ] && echo 0 || echo 1 )"
check "hq exit 1 still spawns" "$( find "$TMP/rec" -name 'codex-argv.*' | grep -q . && echo 0 || echo 1 )"

# Timeout. The stub sleeps 8s and would then print an advisory. The runner's
# limit is 2s, so a missed timeout shows up as a capacity line.
slow_started=$(date +%s)
run_case slow "$TMP/bin:/usr/bin:/bin" slow
slow_elapsed=$(( $(date +%s) - slow_started ))
check "timeout returned before the stub finished" "$( [ "$slow_elapsed" -lt 10 ] && echo 0 || echo 1 )"
check "timeout is silent and still spawns" "$( [ "$(cat "$TMP/last-code")" -eq 0 ] && ! grep -q 'capacity:' "$TMP/last-err" && [ ! -e "$TMP/capacity/advisories.jsonl" ] && find "$TMP/rec" -name 'codex-argv.*' | grep -q . && echo 0 || echo 1 )"

# stale:true
run_case stale "$TMP/bin:/usr/bin:/bin" stale
check "stale ledger is silent" "$( [ "$(cat "$TMP/last-code")" -eq 0 ] && ! grep -q 'capacity:' "$TMP/last-err" && [ ! -e "$TMP/capacity/advisories.jsonl" ] && echo 0 || echo 1 )"

# collectorEnabled:false
run_case disabled "$TMP/bin:/usr/bin:/bin" disabled
check "disabled collector is silent" "$( [ "$(cat "$TMP/last-code")" -eq 0 ] && ! grep -q 'capacity:' "$TMP/last-err" && [ ! -e "$TMP/capacity/advisories.jsonl" ] && echo 0 || echo 1 )"

# Garbage stdout, exit 0.
run_case garbage "$TMP/bin:/usr/bin:/bin" garbage
check "garbage stdout is silent" "$( [ "$(cat "$TMP/last-code")" -eq 0 ] && ! grep -q 'capacity:' "$TMP/last-err" && [ ! -e "$TMP/capacity/advisories.jsonl" ] && find "$TMP/rec" -name 'codex-argv.*' | grep -q . && echo 0 || echo 1 )"

# providers is not an array.
run_case bad-providers "$TMP/bin:/usr/bin:/bin" bad-providers
check "providers not an array is silent" "$( [ "$(cat "$TMP/last-code")" -eq 0 ] && ! grep -q 'capacity:' "$TMP/last-err" && [ ! -e "$TMP/capacity/advisories.jsonl" ] && find "$TMP/rec" -name 'codex-argv.*' | grep -q . && echo 0 || echo 1 )"

# Ledger root does not exist: do not spawn hq.
run_case missing-root "$TMP/bin:/usr/bin:/bin" ok loud "$TMP/wf.mjs" "" "$TMP/does-not-exist"
check "missing root is silent and does not call hq" "$( [ "$(cat "$TMP/last-code")" -eq 0 ] && ! grep -q 'capacity:' "$TMP/last-err" && [ ! -e "$TMP/does-not-exist" ] && [ "$(capacity_calls)" -eq 0 ] && find "$TMP/rec" -name 'codex-argv.*' | grep -q . && echo 0 || echo 1 )"

# Old hq prints help and exits 0.
run_case help "$TMP/bin:/usr/bin:/bin" help
check "hq help text is silent" "$( [ "$(cat "$TMP/last-code")" -eq 0 ] && ! grep -q 'capacity:' "$TMP/last-err" && [ ! -e "$TMP/capacity/advisories.jsonl" ] && find "$TMP/rec" -name 'codex-argv.*' | grep -q . && echo 0 || echo 1 )"

# generatedAt older than five minutes, even when stale is false.
run_case old "$TMP/bin:/usr/bin:/bin" old
check "old generatedAt is silent" "$( [ "$(cat "$TMP/last-code")" -eq 0 ] && ! grep -q 'capacity:' "$TMP/last-err" && [ ! -e "$TMP/capacity/advisories.jsonl" ] && find "$TMP/rec" -name 'codex-argv.*' | grep -q . && echo 0 || echo 1 )"

# --quiet hides the line. The JSONL record is still written.
run_case quiet "$TMP/bin:/usr/bin:/bin" ok quiet
check "quiet hides the advisory" "$( [ "$(cat "$TMP/last-code")" -eq 0 ] && ! grep -q 'capacity:' "$TMP/last-err" && [ -f "$TMP/capacity/advisories.jsonl" ] && echo 0 || echo 1 )"

# A failed append must not swallow the line.
run_case append-fail "$TMP/bin:/usr/bin:/bin" ok loud "$TMP/wf.mjs" block-jsonl
check "append failure still prints" "$( [ "$(cat "$TMP/last-code")" -eq 0 ] && grep -q 'capacity: codex weekly 61%' "$TMP/last-err" && [ -d "$TMP/capacity/advisories.jsonl" ] && find "$TMP/rec" -name 'codex-argv.*' | grep -q . && echo 0 || echo 1 )"

# Two agents, one engine: one hq read and one line.
run_case two "$TMP/bin:/usr/bin:/bin" ok loud "$TMP/wf-two.mjs"
check "two agents call hq once" "$( [ "$(cat "$TMP/last-code")" -eq 0 ] && [ "$(capacity_calls)" -eq 1 ] && [ "$(grep -c 'capacity:' "$TMP/last-err")" -eq 1 ] && [ "$(codex_execs)" -eq 2 ] && echo 0 || echo 1 )"

# Repair is a second spawn. It must not read capacity again.
run_case repair "$TMP/bin:/usr/bin:/bin" ok loud "$TMP/wf-repair.mjs"
check "repair does not read capacity again" "$( [ "$(capacity_calls)" -eq 1 ] && [ "$(codex_execs)" -ge 2 ] && echo 0 || echo 1 )"

printf 'passed %s, failed %s\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  echo '--- success stderr ---'
  cat "$TMP/err-success" 2>/dev/null || true
  echo '--- missing stderr ---'
  cat "$TMP/err-missing" 2>/dev/null || true
fi
[ "$fail" -eq 0 ]
