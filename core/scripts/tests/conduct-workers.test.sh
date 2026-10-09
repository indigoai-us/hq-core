#!/usr/bin/env bash
# conduct-workers.test.sh — coverage for `/conduct --workers`: the lane launcher
# and waiter (lane-dispatch protocol §3-§5 as scripts) and the role helper
# (role list, slot ids, templates, the QA trigger, the bounded CI check and the
# three-round cap).
#
# Everything runs in a scratch HQ root with a stub workflow runner and a stub
# gh, so no real engine starts and no network is touched.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$T"' EXIT

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok — $1"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }
assert_contains() { case "$1" in *"$2"*) : ;; *) fail "$3: missing '$2' in: $1" ;; esac; }

mkdir -p "$T/core/scripts/lib" "$T/workspace/sessions" "$T/.claude/skills/conduct/roles" "$T/work" "$T/bin"
for f in conduct-lane-launch.sh conduct-lane-wait.sh conduct-workers.sh conduct-pool.sh hq-session.sh hq-detach.sh; do
  cp "$ROOT/core/scripts/$f" "$T/core/scripts/"
done
cp "$ROOT/core/scripts/lib/"*.sh "$T/core/scripts/lib/" 2>/dev/null || true
cp "$ROOT/.claude/skills/conduct/roles/"*.md "$T/.claude/skills/conduct/roles/"

# Stub runner: records the pins it was given, then exits with STUB_EXIT after
# STUB_SLEEP seconds.
cat > "$T/core/scripts/workflow-runner.mjs" <<'JS'
import fs from "node:fs";
const i = process.argv.indexOf("--run-dir");
const dir = process.argv[i + 1];
const keys = ["HQ_WORKFLOW_CLAUDE_PLAN_MODEL", "HQ_WORKFLOW_CLAUDE_EXEC_MODEL", "HQ_WORKFLOW_CLAUDE_EFFORT",
  "HQ_WORKFLOW_MODEL", "HQ_WORKFLOW_EFFORT", "HQ_CONDUCT_ENGINE", "HQ_SPAWN_COMPANY", "HQ_SPAWN_TASK", "HQ_SESSION_ID"];
const env = {};
for (const k of keys) if (process.env[k] !== undefined) env[k] = process.env[k];
env.eval = process.argv[process.argv.indexOf("--eval") + 1];
fs.writeFileSync(dir + "/stub-env.json", JSON.stringify(env));
const sleep = Number(process.env.STUB_SLEEP || 0);
setTimeout(() => { console.log("stub lane done"); process.exit(Number(process.env.STUB_EXIT || 0)); }, sleep * 1000);
JS

export HQ_ROOT="$T"
unset CLAUDE_PROJECT_DIR HQ_SPAWN_COMPANY HQ_SPAWN_PROJECT HQ_WORKFLOW_MODEL HQ_WORKFLOW_EFFORT \
  HQ_WORKFLOW_CLAUDE_PLAN_MODEL HQ_WORKFLOW_CLAUDE_EXEC_MODEL HQ_WORKFLOW_CLAUDE_EFFORT
export HQ_SPAWN_TASK="inherited-task-must-not-leak"
SID="test-cw-session"
export HQ_SESSION_ID="$SID"
mkdir -p "$T/workspace/sessions/$SID"
printf 'session_id: %s\n' "$SID" > "$T/workspace/sessions/$SID/meta.yaml"

L() { bash "$T/core/scripts/conduct-lane-launch.sh" "$@"; }
W() { bash "$T/core/scripts/conduct-lane-wait.sh" "$@"; }
CW() { bash "$T/core/scripts/conduct-workers.sh" "$@"; }
S() { bash "$T/core/scripts/hq-session.sh" --session-id "$SID" "$@"; }

echo "conduct-workers: setup validates and persists roles and pins"
out="$(CW setup --session-id "$SID" --workers "frontend, designer,qa,frontend,orchestrator" --engine claude --model claude-test-model --effort low)"
assert_eq "$(S get conduct_lane_roles)" "frontend,designer,qa,orchestrator" "roles deduped and trimmed"
assert_eq "$(S get conduct_engine)" "claude" "engine"
assert_eq "$(S get conduct_child_model)" "claude-test-model" "model"
assert_eq "$(S get conduct_child_effort)" "low" "effort"
assert_contains "$out" '"roles":["frontend","designer","qa","orchestrator"]' "printed roles"
CW setup --session-id "$SID" --workers "Front End" >/dev/null 2>&1 && fail "a role with spaces/capitals must be rejected"
CW setup --session-id "$SID" --workers "qa" --engine gpt >/dev/null 2>&1 && fail "unknown engine must be rejected"
CW setup --session-id "$SID" >/dev/null 2>&1 && fail "--workers is required"
assert_eq "$(S get conduct_lane_roles)" "frontend,designer,qa,orchestrator" "a rejected setup changes nothing"
ok "setup: roles validated, deduped and persisted with engine/model/effort"

echo "conduct-workers: role routing to pool slot ids"
assert_eq "$(CW lane-id --session-id "$SID" --role frontend)" "conduct:frontend" "base slot"
assert_eq "$(CW lane-id --session-id "$SID" --role frontend --slug link-cards)" "conduct:frontend-link-cards" "second slot"
CW lane-id --session-id "$SID" --role backend >/dev/null 2>&1 && fail "a role outside the session's list must be rejected"
CW lane-id --session-id "$SID" --role frontend --slug 'a b' >/dev/null 2>&1 && fail "a bad slug must be rejected"
ok "lane-id: conduct:<role>, conduct:<role>-<slug>, unknown roles refused"

echo "conduct-workers: templates resolve per role with a generic fallback"
assert_eq "$(CW template --role qa)" ".claude/skills/conduct/roles/qa.md" "qa template"
assert_eq "$(CW template --role data)" ".claude/skills/conduct/roles/generic.md" "fallback"
for r in frontend designer backend qa orchestrator generic; do
  f="$ROOT/.claude/skills/conduct/roles/$r.md"
  [ -f "$f" ] || fail "missing template $r"
  grep -q '^Execute this now' "$f" || fail "$r template must open with the execute line"
done
for r in frontend designer backend generic; do
  f="$ROOT/.claude/skills/conduct/roles/$r.md"
  for m in 'origin/main' 'workspace/worktrees/{repo_name}/{slug}' 'git -C' "credential.helper='!gh auth git-credential'" 'unset GH_TOKEN GITHUB_TOKEN' 'changelog' 'Never skip' 'Do not merge' 'do not edit its title or body' '{avoid}' '{goal}' '{done_criteria}'; do
    grep -qF -- "$m" "$f" || fail "$r template lacks: $m"
  done
done
for r in frontend designer; do
  grep -qF '{run_dir}/shots/' "$ROOT/.claude/skills/conduct/roles/$r.md" || fail "$r template must ask for harness screenshots"
done
grep -qi 'do not merge, tag, release' "$ROOT/.claude/skills/conduct/roles/orchestrator.md" || fail "orchestrator must stop before merge/release"
grep -qi "owner's explicit approval" "$ROOT/.claude/skills/conduct/roles/orchestrator.md" || fail "orchestrator must name the owner approval gate"
grep -qi 'full CI' "$ROOT/.claude/skills/conduct/roles/orchestrator.md" || fail "orchestrator must dispatch full CI"
if grep -rIl -e '/Users/' "$ROOT/.claude/skills/conduct/roles/"; then fail "templates must not carry absolute user paths"; fi
ok "templates: execute opener, worktree, gh push, changelog, tests, screenshots, no merge"

echo "conduct-workers: UI heuristic for the QA lane"
CW needs-qa --role frontend >/dev/null || fail "frontend role needs QA"
CW needs-qa --role designer >/dev/null || fail "designer role needs QA"
CW needs-qa --role backend --file src/App.svelte >/dev/null || fail "svelte file needs QA"
CW needs-qa --role backend --file web/x.TSX.bak --file styles/a.css >/dev/null || fail "css file needs QA"
CW needs-qa --role backend --file api/handler.ts --file README.md >/dev/null && fail "ts and md alone do not need QA"
cat > "$T/bin/gh" <<'SH'
#!/bin/sh
case "$*" in
  "pr view"*"--json files"*) printf 'src/server.ts\nsrc/ui/Card.tsx\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/gh"
out="$(PATH="$T/bin:$PATH" CW needs-qa --role backend --pr https://github.com/o/r/pull/1)"; code=$?
assert_eq "$code" "0" "tsx in the PR's files"
assert_eq "$out" "yes" "printed yes"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/gh"
PATH="$T/bin:$PATH" CW needs-qa --role backend --pr 1 >/dev/null 2>&1; code=$?
assert_eq "$code" "2" "gh failure is an error, not a no"
ok "needs-qa: roles, UI file types, PR files, gh failure"

echo "conduct-workers: CI check is bounded and fails closed"
mkgh() { printf '#!/bin/sh\nprintf %%s %s\nexit %s\n' "'$1'" "$2" > "$T/bin/gh"; chmod +x "$T/bin/gh"; }
mkgh '[{"name":"lint","bucket":"pass"},{"name":"test","bucket":"pass"},{"name":"e2e","bucket":"skipping"}]' 0
out="$(PATH="$T/bin:$PATH" CW ci --pr 5 --timeout 10 --interval 1 --settle 0)"; code=$?
assert_eq "$code" "0" "all pass"; assert_contains "$out" '"state":"pass"' "pass state"
out="$(PATH="$T/bin:$PATH" CW ci --pr 5 --timeout 0 --interval 1)"; code=$?
assert_eq "$code" "2" "a pass inside the settle window is not final"
# Regression: right after a push only the first check suites are registered.
# The first poll sees one passing check, the next sees the main suite pending
# and then failing. An early "pass" here would send a broken PR to QA.
cat > "$T/bin/gh" <<SH
#!/bin/sh
n=\$(cat "$T/gh-calls" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$T/gh-calls"
case "\$n" in
  1) printf '%s' '[{"name":"early","bucket":"pass"}]' ;;
  2) printf '%s' '[{"name":"early","bucket":"pass"},{"name":"pr-checks","bucket":"pending"}]'; exit 8 ;;
  *) printf '%s' '[{"name":"early","bucket":"pass"},{"name":"pr-checks","bucket":"fail"}]'; exit 1 ;;
esac
SH
chmod +x "$T/bin/gh"
out="$(PATH="$T/bin:$PATH" CW ci --pr 5 --timeout 20 --interval 1 --settle 0)"; code=$?
assert_eq "$code" "1" "late-registered failing suite is caught"
assert_contains "$out" '"failing":["pr-checks"]' "late suite named"
mkgh '[{"name":"lint","bucket":"pass"},{"name":"test","bucket":"fail"},{"name":"build","bucket":"pending"}]' 1
out="$(PATH="$T/bin:$PATH" CW ci --pr 5 --timeout 0 --interval 1)"; code=$?
assert_eq "$code" "1" "a failure wins over pending"; assert_contains "$out" '"failing":["test"]' "failing names"
mkgh '[{"name":"build","bucket":"pending"}]' 8
started=$(date +%s)
out="$(PATH="$T/bin:$PATH" CW ci --pr 5 --timeout 2 --interval 1)"; code=$?
assert_eq "$code" "2" "pending at the timeout"
[ $(( $(date +%s) - started )) -le 6 ] || fail "ci wait was not bounded"
mkgh 'HTTP 401: Bad credentials' 1
out="$(PATH="$T/bin:$PATH" CW ci --pr 5 --timeout 0 --interval 1)"; code=$?
assert_eq "$code" "3" "gh error"; assert_contains "$out" '"state":"error"' "never a pass on error"
mkgh '[]' 0
PATH="$T/bin:$PATH" CW ci --pr 5 --timeout 10 --interval 1 --settle 0 >/dev/null; code=$?
assert_eq "$code" "4" "no checks reported"
ok "ci: settled pass, late-registered suite, fail, bounded pending, fail-closed error, none"

echo "conduct-workers: three CI fix rounds, then the owner"
PR=https://github.com/o/r/pull/9
for n in 1 2 3; do
  out="$(CW ci-round --session-id "$SID" --pr "$PR")" || fail "round $n should be allowed"
  assert_eq "$out" "$n" "round count"
done
CW ci-round --session-id "$SID" --pr "$PR" >/dev/null 2>&1; code=$?
assert_eq "$code" "4" "fourth round is refused"
assert_eq "$(CW ci-round --session-id "$SID" --pr https://github.com/o/r/pull/10)" "1" "rounds are per PR"
ok "ci-round: max 3 per PR"

echo "conduct-lane-launch: mint makes a fresh dir under the session base"
RD="$(L mint --session-id "$SID" --lane frontend)"
case "$RD" in "workspace/tmp/workflow-runner/$SID/conduct-frontend-"*) : ;; *) fail "run dir not under session base: $RD" ;; esac
[ -d "$T/$RD" ] || fail "run dir not created"
RD2="$(L mint --session-id "$SID" --lane frontend)"
[ "$RD" != "$RD2" ] || fail "two mints must not collide"
L mint --session-id "$SID" --lane '../x' >/dev/null 2>&1 && fail "path-like lane names must be rejected"
ok "mint: session-scoped, unique, validated"

echo "conduct-lane-launch: start validates its arguments"
start() { L start --session-id "$SID" "$@" >/dev/null 2>&1; }
start --run-dir "$RD" --worker frontend --tier exec --timeout 60 --cd "$T/work" && fail "missing brief.md must be refused"
printf 'Execute this now.\n' > "$T/$RD/brief.md"
start --run-dir "$RD" --worker frontend --tier fast --timeout 60 --cd "$T/work" && fail "bad tier"
start --run-dir "$RD" --worker frontend --tier exec --timeout 0 --cd "$T/work" && fail "zero timeout"
start --run-dir "$RD" --worker frontend --tier exec --timeout 1m --cd "$T/work" && fail "non-numeric timeout"
start --run-dir "$RD" --worker frontend --tier exec --timeout 60 --cd work && fail "relative cd"
start --run-dir "$RD" --worker frontend --tier exec --timeout 60 --cd "$T/missing" && fail "missing cd"
start --run-dir "$RD" --worker 'Front End' --tier exec --timeout 60 --cd "$T/work" && fail "bad worker"
start --run-dir "/tmp/elsewhere" --worker frontend --tier exec --timeout 60 --cd "$T/work" && fail "run dir outside root"
mkdir -p "$T/workspace/tmp/workflow-runner/other-session/x"
printf 'b\n' > "$T/workspace/tmp/workflow-runner/other-session/x/brief.md"
start --run-dir "workspace/tmp/workflow-runner/other-session/x" --worker frontend --tier exec --timeout 60 --cd "$T/work" && fail "another session's run dir"
start --run-dir "$RD" --worker frontend --tier exec --timeout 60 --cd "$T/work" --engine gpt && fail "unknown engine"
L start --run-dir "$RD" --worker frontend --tier exec --timeout 60 --cd "$T/work" >/dev/null 2>&1; code=$?
assert_eq "$code" "2" "no company bound is refused with exit 2"
[ ! -e "$T/$RD/deadline" ] || fail "a refused launch must not write a deadline"
ok "start: tier, timeout, cd, worker, run dir scope, engine and company all checked"

S set company_slug acme 2>/dev/null || { mkdir -p "$T/companies/acme"; S set company_slug acme; }
mkdir -p "$T/companies/acme"
S set company_slug acme

echo "conduct-lane-launch: dry run shows the per-engine pins"
out="$(L start --session-id "$SID" --run-dir "$RD" --worker frontend --tier exec --timeout 60 --cd "$T/work" --dry-run)"
assert_contains "$out" '"pins":["HQ_WORKFLOW_CLAUDE_PLAN_MODEL","HQ_WORKFLOW_CLAUDE_EXEC_MODEL","HQ_WORKFLOW_CLAUDE_EFFORT"]' "claude pins"
assert_contains "$out" '"model":"claude-test-model"' "model from session"
assert_contains "$out" '"worker_id":"conduct:frontend"' "conduct: prefix"
out="$(L start --session-id "$SID" --run-dir "$RD" --worker frontend --tier exec --timeout 60 --cd "$T/work" --dry-run --engine codex --model gpt-test --effort medium)"
assert_contains "$out" '"pins":["HQ_WORKFLOW_MODEL","HQ_WORKFLOW_EFFORT"]' "codex pins"
[ ! -e "$T/$RD/deadline" ] || fail "dry run must not write files"
ok "dry run: claude vs codex/grok pin sets"

echo "conduct-lane-launch: a real launch detaches, pins the engine, writes the deadline and records the slot"
bash "$T/core/scripts/conduct-pool.sh" --session-id "$SID" assign --worker-id conduct:frontend --task t >/dev/null
before=$(date +%s)
out="$(STUB_SLEEP=8 L start --session-id "$SID" --run-dir "$RD" --worker frontend --tier exec --timeout 60 --cd "$T/work")" || fail "launch failed: $out"
assert_contains "$out" '"detached":true' "proof of escape"
dl="$(cat "$T/$RD/deadline")"
[ "$dl" -ge $((before + 60)) ] && [ "$dl" -le $(( $(date +%s) + 60 )) ] || fail "deadline is not now+timeout: $dl"
assert_eq "$(cat "$T/$RD/worker_id")" "conduct:frontend" "worker id file"
jq -e --arg b "$T/$RD/brief.md" --arg c "$T/work" '.brief==$b and .cd==$c' "$T/$RD/args.json" >/dev/null || fail "args.json"
st="$(bash "$T/core/scripts/conduct-pool.sh" --session-id "$SID" list | jq -r '.[]|select(.worker_id=="conduct:frontend")|.status')"
[ "$st" = running ] || { cat "$T/$RD/lane.log"; ls "$T/$RD"; cat "$T/workspace/sessions/$SID/meta.yaml"; }; assert_eq "$st" "running" "slot recorded running"
L start --session-id "$SID" --run-dir "$RD" --worker frontend --tier exec --timeout 60 --cd "$T/work" >/dev/null 2>&1 && fail "relaunching a used run dir must be refused"
ok "launch: detached, deadline=now+timeout, args.json, slot running, no reuse"

echo "conduct-lane-wait: exits on the marker and frees the slot"
out="$(W --run-dir "$RD" --interval 1)"; code=$?
assert_eq "$code" "0" "clean exit"
assert_contains "$out" "outcome=exited engine_gone=yes" "outcome line"
env_json="$(cat "$T/$RD/stub-env.json")"
assert_eq "$(printf '%s' "$env_json" | jq -r .HQ_WORKFLOW_CLAUDE_EXEC_MODEL)" "claude-test-model" "exec model pin"
assert_eq "$(printf '%s' "$env_json" | jq -r .HQ_WORKFLOW_CLAUDE_PLAN_MODEL)" "claude-test-model" "plan model pin"
assert_eq "$(printf '%s' "$env_json" | jq -r .HQ_WORKFLOW_CLAUDE_EFFORT)" "low" "effort pin"
assert_eq "$(printf '%s' "$env_json" | jq -r '.HQ_WORKFLOW_MODEL // "unset"')" "unset" "no codex pin on claude"
assert_eq "$(printf '%s' "$env_json" | jq -r .HQ_SPAWN_COMPANY)" "acme" "company carried"
assert_eq "$(printf '%s' "$env_json" | jq -r '.HQ_SPAWN_TASK // "unset"')" "unset" "inherited task never leaks"
assert_contains "$(printf '%s' "$env_json" | jq -r .eval)" 'tier: "exec"' "tier in the runner call"
st="$(bash "$T/core/scripts/conduct-pool.sh" --session-id "$SID" list | jq -r '.[]|select(.worker_id=="conduct:frontend")|.status')"
assert_eq "$st" "idle" "slot idle after exit"
ok "wait: marker -> exited, slot idle; claude pins reached the runner"

echo "conduct-lane-launch: codex lanes get HQ_WORKFLOW_MODEL/EFFORT"
RD3="$(L mint --session-id "$SID" --lane backend)"
printf 'Execute this now.\n' > "$T/$RD3/brief.md"
L start --session-id "$SID" --run-dir "$RD3" --worker backend --tier plan --timeout 60 --cd "$T/work" --engine codex --model gpt-test --effort medium >/dev/null || fail "codex launch"
W --run-dir "$RD3" --interval 1 >/dev/null || fail "codex wait"
env_json="$(cat "$T/$RD3/stub-env.json")"
assert_eq "$(printf '%s' "$env_json" | jq -r .HQ_WORKFLOW_MODEL)" "gpt-test" "codex model"
assert_eq "$(printf '%s' "$env_json" | jq -r .HQ_WORKFLOW_EFFORT)" "medium" "codex effort"
assert_eq "$(printf '%s' "$env_json" | jq -r '.HQ_WORKFLOW_CLAUDE_EXEC_MODEL // "unset"')" "unset" "no claude pin on codex"
ok "codex pins"

echo "conduct-lane-wait: refuses without a deadline, stops at the deadline, reports a death"
RD4="$(L mint --session-id "$SID" --lane qa)"
W --run-dir "$RD4" --interval 1 >/dev/null 2>&1; code=$?
assert_eq "$code" "1" "no deadline file is a usage error"
printf 'Execute this now.\n' > "$T/$RD4/brief.md"
STUB_SLEEP=120 L start --session-id "$SID" --run-dir "$RD4" --worker qa --tier exec --timeout 2 --cd "$T/work" >/dev/null || fail "qa launch"
out="$(W --run-dir "$RD4" --interval 1 --grace 10)"; code=$?
assert_eq "$code" "12" "deadline exit code"
assert_contains "$out" "outcome=deadline" "deadline outcome"
grep -q 'CONDUCT_EXIT=' "$T/$RD4/lane.log" || fail "the runner was not stopped through runner.pid"
RD5="$(L mint --session-id "$SID" --lane designer)"
printf 'Execute this now.\n' > "$T/$RD5/brief.md"
STUB_SLEEP=120 L start --session-id "$SID" --run-dir "$RD5" --worker designer --tier exec --timeout 120 --cd "$T/work" >/dev/null || fail "designer launch"
kill -KILL -- -"$(cat "$T/$RD5/lane.pid")" 2>/dev/null
kill -KILL "$(cat "$T/$RD5/runner.pid")" 2>/dev/null
out="$(W --run-dir "$RD5" --interval 1)"; code=$?
assert_eq "$code" "10" "died exit code"
assert_contains "$out" "outcome=died" "died outcome"
ok "wait: refuses unbounded, deadline stop via the runner, died"

echo "skill docs point at the scripts"
grep -q 'conduct-lane-launch.sh' "$ROOT/.claude/skills/_shared/lane-dispatch-protocol.md" || fail "protocol must name the launcher"
grep -q 'conduct-lane-wait.sh' "$ROOT/.claude/skills/_shared/lane-dispatch-protocol.md" || fail "protocol must name the waiter"
grep -q -- '--workers' "$ROOT/.claude/skills/conduct/SKILL.md" || fail "SKILL.md must parse --workers"
for m in 'conduct-workers.sh ci ' 'ci-round' 'needs-qa' 'roles/orchestrator.md' 'conduct-lane-launch.sh mint'; do
  grep -qF -- "$m" "$ROOT/.claude/skills/conduct/dispatch.md" || fail "dispatch.md must cover: $m"
done
ok "SKILL.md, dispatch.md and the protocol reference the new pieces"

echo
echo "conduct-workers.test.sh: $PASS checks passed"
