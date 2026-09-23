#!/bin/bash
# hq-core: public
# Codex and Grok lanes enqueue Work Mesh presence. Claude lanes do not.
# A failing hq binary must not change the lane exit code.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RUNNER="$REPO_ROOT/core/scripts/workflow-runner.mjs"

pass=0
fail=0
check() {
  if [ "$2" -eq 0 ]; then
    printf 'ok   - %s\n' "$1"; pass=$((pass + 1))
  else
    printf 'FAIL - %s\n' "$1"; fail=$((fail + 1))
  fi
}

TMP="$(mktemp -d /tmp/workflow-runner-mesh.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
mkdir -p "$TMP/bin" "$TMP/hqroot/.claude" "$TMP/hqroot/workspace"
printf '{}\n' > "$TMP/hqroot/.claude/settings.json"

cat > "$TMP/bin/grok" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'grok-test-9\n'
  exit 0
fi
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    --single) prompt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$prompt" in
  *WITHPR*)
    text='Opened https://github.com/indigoai-us/hq-core-staging/pull/4242'
    ;;
  *)
    text="grokecho:${prompt}"
    ;;
esac
printf '{"text":"%s","stopReason":"EndTurn","sessionId":"s1","requestId":"r1"}\n' "$text"
exit 0
FAKE

cat > "$TMP/bin/claude" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'claude-test\n'
  exit 0
fi
printf '{"type":"result","subtype":"success","is_error":false,"result":"claude-ok","permission_denials":[]}\n'
exit 0
FAKE

cat > "$TMP/bin/hq" <<'FAKE'
#!/usr/bin/env bash
rec="${FAKE_REC_DIR:?}"
mkdir -p "$rec"
n="$(ls "$rec"/hq-argv.* 2>/dev/null | wc -l | tr -d ' ')"
printf '%s\n' "$@" > "$rec/hq-argv.$n"
if [ "${HQ_MESH_FAIL:-}" = 1 ]; then
  echo "fake hq failing" >&2
  exit 1
fi
exit 0
FAKE
chmod +x "$TMP/bin/grok" "$TMP/bin/claude" "$TMP/bin/hq"

run_lane() { # <engine> <prompt> <run-name>
  local engine="$1" prompt="$2" name="$3"
  RUN="$TMP/$name"
  rm -rf "$RUN" "$TMP/hqrec-$name"
  mkdir -p "$TMP/hqrec-$name"
  cat > "$TMP/wf-$name.mjs" <<WF
export const meta = { name: '$name', description: 'mesh' }
return await agent('$prompt', { engine: '$engine', tier: 'exec', timeoutSecs: 30, label: 'lane' })
WF
  OUT="$(PATH="$TMP/bin:$PATH" \
    FAKE_REC_DIR="$TMP/hqrec-$name" \
    HQ_WORKFLOW_GROK_BIN="$TMP/bin/grok" \
    HQ_WORKFLOW_CLAUDE_BIN="$TMP/bin/claude" \
    HQ_WORKFLOW_CPU_CHECK=0 \
    HQ_ROOT="$TMP/hqroot" \
    HQ_WORKFLOW_GROK_JSON_SCHEMA=0 \
    node "$RUNNER" "$TMP/wf-$name.mjs" --quiet --run-dir "$RUN" 2>"$TMP/stderr-$name")"
  RC=$?
}

kinds_of() {
  node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").filter(Boolean);
    const kinds = lines.map(l => JSON.parse(l)).filter(e => e.event === "mesh-emit").map(e => e.kind + ":" + e.ok);
    process.stdout.write(kinds.join(",") + "\n");
  ' "$1"
}

# ---- grok + company + task: five emits, review because the reply has a PR URL
export HQ_SPAWN_COMPANY=indigo
export HQ_SPAWN_PROJECT=work-mesh
export HQ_SPAWN_TASK=work-mesh/US-033
run_lane grok 'please WITHPR' with-task
check "grok lane with company exits 0" "$RC"
KINDS="$(kinds_of "$RUN/journal.jsonl")"
[ "$KINDS" = "session_start:true,task_status:true,turn_end:true,task_status:true,session_end:true" ]
check "grok lane emits five mesh kinds in order" "$?"
SID="$(basename "$RUN")"
node -e '
  const fs = require("fs");
  const path = require("path");
  const dir = process.argv[1];
  const files = fs.readdirSync(dir).filter(f => f.startsWith("hq-argv.")).sort((a,b) => Number(a.split(".")[1]) - Number(b.split(".")[1]));
  const argvs = files.map(f => fs.readFileSync(path.join(dir, f), "utf8").trim().split("\n"));
  const sub = argvs.map(a => a[2]);
  if (sub.join(",") !== "start,task-status,turn-end,task-status,end") process.exit(2);
  const want = [["--harness", "grok"], ["--adapter-version", "workflow-runner-1"], ["--runtime-version", "grok-test-9"], ["--session-id", process.argv[2]], ["--company-slug", "indigo"], ["--project", "work-mesh"], ["--task", "work-mesh/US-033"]];
  for (const argv of argvs) {
    if (!argv.includes("--enqueue")) process.exit(3);
    for (const [flag, value] of want) {
      const at = argv.indexOf(flag);
      if (at < 0 || argv[at + 1] !== value) process.exit(3);
    }
  }
  if (!argvs[0].includes("--task-id") || argvs[0][argvs[0].indexOf("--task-id") + 1] !== "work-mesh/US-033") process.exit(4);
  const seqs = argvs.map(a => a[a.indexOf("--seq") + 1]);
  if (seqs.join(",") !== "1,2,3,4,5") process.exit(5);
  if (argvs[1][argvs[1].indexOf("--status") + 1] !== "in_progress") process.exit(6);
  if (argvs[3][argvs[3].indexOf("--status") + 1] !== "review") process.exit(7);
  process.exit(0);
' "$TMP/hqrec-with-task" "$SID"
check "grok lane mesh argv has session, task, company, and seq" "$?"

# ---- no pull request: note instead of review --------------------------------
run_lane grok 'say hi only' note-path
check "grok lane without a PR url exits 0" "$RC"
KINDS="$(kinds_of "$RUN/journal.jsonl")"
[ "$KINDS" = "session_start:true,task_status:true,turn_end:true,note:true,session_end:true" ]
check "grok lane without a PR url emits a note" "$?"
node -e '
  const fs = require("fs");
  const path = require("path");
  const dir = process.argv[1];
  const note = fs.readdirSync(dir).filter(f => f.startsWith("hq-argv.")).map(f => fs.readFileSync(path.join(dir, f), "utf8")).find(t => t.split("\n")[2] === "note");
  if (!note) process.exit(1);
  const argv = note.trim().split("\n");
  const at = argv.indexOf("--summary");
  if (at < 0 || !argv[at + 1].startsWith("grokecho:")) process.exit(2);
  if (argv[at + 1].length > 200) process.exit(3);
' "$TMP/hqrec-note-path"
check "note summary is the reply prefix" "$?"

# ---- grok without a company emits nothing ------------------------------------
unset HQ_SPAWN_COMPANY HQ_SPAWN_PROJECT HQ_SPAWN_TASK
run_lane grok 'say hi only' no-company
check "grok lane without company exits 0" "$RC"
KINDS="$(kinds_of "$RUN/journal.jsonl")"
[ -z "$KINDS" ]
check "grok lane without company emits nothing" "$?"
[ -z "$(ls "$TMP/hqrec-no-company"/hq-argv.* 2>/dev/null)" ]
check "grok lane without company does not call hq" "$?"

# ---- claude lane emits nothing from the runner -------------------------------
export HQ_SPAWN_COMPANY=indigo
export HQ_SPAWN_PROJECT=work-mesh
export HQ_SPAWN_TASK=work-mesh/US-033
run_lane claude 'say hi claude' claude-lane
check "claude lane exits 0" "$RC"
KINDS="$(kinds_of "$RUN/journal.jsonl")"
[ -z "$KINDS" ]
check "claude lane emits nothing from the runner" "$?"
[ -z "$(ls "$TMP/hqrec-claude-lane"/hq-argv.* 2>/dev/null)" ]
check "claude lane does not call hq" "$?"

# ---- failing hq does not change the lane exit code --------------------------
export HQ_MESH_FAIL=1
run_lane grok 'say hi only' hq-fails
fail_rc="$RC"
unset HQ_MESH_FAIL
check "failing hq leaves the lane exit code 0" "$fail_rc"
KINDS="$(kinds_of "$RUN/journal.jsonl")"
[ "$KINDS" = "session_start:false,task_status:false,turn_end:false,note:false,session_end:false" ]
check "failing hq is journalled ok:false and does not abort the lane" "$?"

unset HQ_SPAWN_COMPANY HQ_SPAWN_PROJECT HQ_SPAWN_TASK

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
