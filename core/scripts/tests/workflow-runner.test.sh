#!/bin/bash
# Regression test for core/scripts/workflow-runner.mjs — the multi-engine
# workflow orchestrator (Codex + Grok + Claude) with human gates.
#
# Uses FAKE engine binaries (HQ_WORKFLOW_CODEX_BIN / HQ_WORKFLOW_GROK_BIN /
# HQ_WORKFLOW_CLAUDE_BIN) so no real agents run, and a synthetic HQ root
# (HQ_ROOT) so the suite is hermetic in CI. Covered behaviors:
#   1. codex engine (default): every spawn carries the three unattended-run
#      flags, stdin at /dev/null, `--` before the prompt, -C <hq-root>; result
#      read from the --output-last-message file; --output-schema parsed
#   1b. codex strict output schema: --output-schema is written in the provider's
#      STRICT dialect (additionalProperties:false on every object node, `required`
#      listing every property), an optional property is widened to nullable and
#      the null it invites is stripped back out of the result, and the stdout
#      engines still get the script's own schema verbatim in-prompt
#   2. grok engine: spawns the grok bin with --single <prompt>,
#      --permission-mode bypassPermissions --always-approve, NO codex flags;
#      the reply is captured from stdout; a schema instruction is appended to
#      the prompt and the JSON reply parsed; the process runs with its cwd at
#      the HQ root (grok's anchor is cwd, not -C)
#   2d. claude engine: spawns the claude bin with -p <prompt>,
#      --permission-mode bypassPermissions --output-format json, NO codex flags
#      and NO --always-approve; the reply is unwrapped from the result envelope
#      ({subtype,is_error,result,permission_denials}) on stdout; an errored
#      envelope (is_error/subtype error) or empty result throws loudly; a schema
#      instruction is appended and the JSON reply parsed; cwd anchored at the
#      HQ root. For the stdout engines a parsed reply that violates opts.schema
#      (wrong type / missing required / bad enum) is rejected with a schema
#      error rather than passed downstream
#   1c. spawned agents run with HQ's end-of-turn checkpoint gate suppressed
#      (HQ_DISABLED_HOOKS), on every engine, without clobbering a suppression
#      the operator set: the gate demands a turn AFTER the answer, which ends a
#      headless run on a tool call and returns an empty result
#   3. tiers are engine-neutral: "plan"/"exec" required; codex maps to
#      gpt-5.6-sol / gpt-5.6-terra, grok to grok-4.6, claude to opus/sonnet; the
#      HQ_WORKFLOW_{CODEX,GROK,CLAUDE}_{PLAN,EXEC}_MODEL envs re-point them; an
#      unknown engine or tier throws
#   4. parallel(): a failing thunk resolves to null, siblings survive
#   5. soft timeout: a slow agent is NOT killed — repeating TIMEOUT WARNING
#   6. HQ root: HQ_ROOT env wins; without it an HQ-shaped cwd is detected;
#      opts.cd is injected as a prompt preamble and must stay inside the root
#   7. gate(): pause in place (pending file, GATE OPEN on stdout, no agents
#      while gated), resume on an answer with the value flowing onward,
#      instant GATE CACHED for pre-answered ids, journal events, and the
#      legacy CODEX_WORKFLOW_GATES_DIR env still honored

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RUNNER="$REPO_ROOT/core/scripts/workflow-runner.mjs"

pass=0
fail=0
check() { # check <name> <condition-exit-code>
  if [ "$2" -eq 0 ]; then
    printf 'ok   - %s\n' "$1"; pass=$((pass + 1))
  else
    printf 'FAIL - %s\n' "$1"; fail=$((fail + 1))
  fi
}

TMP="$(mktemp -d /tmp/workflow-runner-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
# canonicalize: on macOS /tmp symlinks to /private/tmp and the runner resolves
# real paths — compare like with like
TMP="$(cd "$TMP" && pwd -P)"
mkdir -p "$TMP/bin" "$TMP/rec"

HQROOT="$TMP/hqroot"
mkdir -p "$HQROOT/.claude" "$HQROOT/workspace"
printf '{}\n' > "$HQROOT/.claude/settings.json"
cd "$HQROOT" || exit 1

# ---- fake codex (result via --output-last-message file) ----------------------
cat > "$TMP/bin/codex" <<'FAKE'
#!/usr/bin/env bash
rec="${FAKE_REC_DIR:?}"
n="$$-$RANDOM"
printf '%s\n' "$@" > "$rec/codex-argv.$n"
printenv HQ_DISABLED_HOOKS > "$rec/codex-hooksenv.$n" 2>/dev/null || : > "$rec/codex-hooksenv.$n"
{ readlink /proc/self/fd/0 2>/dev/null || lsof -a -p $$ -d 0 -Fn 2>/dev/null | sed -n 's/^n//p'; } > "$rec/codex-stdin.$n"
[ -s "$rec/codex-stdin.$n" ] || echo "unknown" > "$rec/codex-stdin.$n"
last=""; schema=""; prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output-last-message) last="$2"; shift 2 ;;
    --output-schema) schema="$2"; shift 2; mkdir -p "$rec/schemas"; cp "$schema" "$rec/schemas/schema.$n.json" ;;
    -C|-c|-m|--color) shift 2 ;;
    exec) shift ;;
    --*) shift ;;
    *) prompt="$1"; shift ;;
  esac
done
case "$prompt" in
  *SLEEP=*)
    secs="$(printf '%s' "$prompt" | sed -n 's/.*SLEEP=\([0-9]*\).*/\1/p')"
    sleep "${secs:-0}"
    ;;
esac
case "$prompt" in
  *FAIL*) echo "fake codex: failing on purpose" >&2; exit 3 ;;
esac
if [ -n "$schema" ]; then
  case "$prompt" in
    *STRICTNULLS*)
      # what a STRICT structured-output run actually returns: every key present,
      # the optional ones answered null
      printf '{"pong": 1, "note": null, "rows": [{"id": "a", "hint": null}]}\n' > "$last" ;;
    *)
      printf '{"pong": 1, "sawSchema": true}\n' > "$last" ;;
  esac
else
  printf 'echo:%s\n' "$prompt" > "$last"
fi
exit 0
FAKE
chmod +x "$TMP/bin/codex"

# ---- fake grok (JSON envelope on STDOUT, as the real CLI emits) -------------
# Real shape (grok --output-format json):
#   {"text":"...","stopReason":"EndTurn","sessionId":"...","requestId":"...","thought":"..."}
# A denied tool call ends the run with stopReason "Cancelled", a preamble-only
# text, and exit code 0 — the CANCEL directive reproduces that exactly.
cat > "$TMP/bin/grok" <<'FAKE'
#!/usr/bin/env bash
rec="${FAKE_REC_DIR:?}"
n="$$-$RANDOM"
printf '%s\n' "$@" > "$rec/grok-argv.$n"
printenv HQ_DISABLED_HOOKS > "$rec/grok-hooksenv.$n" 2>/dev/null || : > "$rec/grok-hooksenv.$n"
pwd > "$rec/grok-cwd.$n"
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    --single) prompt="$2"; shift 2 ;;
    -m|--reasoning-effort|--output-format|--permission-mode) shift 2 ;;
    *) shift ;;
  esac
done
case "$prompt" in
  *CANCEL*)
    printf '{"text":"Listing the directory.","stopReason":"Cancelled","sessionId":"s1","requestId":"r1"}\n' ;;
  *EMPTYREPLY*)
    printf '{"text":"","stopReason":"EndTurn","sessionId":"s1","requestId":"r1"}\n' ;;
  *PROSEJSON*)
    # observed live: grok prefixes narration straight onto the JSON answer, and
    # may quote an earlier draft object mid-thought — the LAST block wins
    printf '{"text":"Reading the file.{\\"pong\\": 99, \\"draft\\": true}Re-checking.{\\"pong\\": 2, \\"viaStdout\\": true}","stopReason":"EndTurn","sessionId":"s1"}\n' ;;
  *"Return ONLY JSON matching this JSON Schema"*)
    printf '{"text":"{\\"pong\\": 2, \\"viaStdout\\": true}","stopReason":"EndTurn","sessionId":"s1","requestId":"r1"}\n' ;;
  *)
    printf '{"text":"grokecho:%s","stopReason":"EndTurn","sessionId":"s1","requestId":"r1"}\n' "$prompt" ;;
esac
exit 0
FAKE
chmod +x "$TMP/bin/grok"

# ---- fake claude (JSON result envelope on STDOUT, as `claude -p` emits) ------
# Real shape (claude -p --output-format json):
#   {"type":"result","subtype":"success","is_error":false,"result":"...",
#    "stop_reason":"end_turn","permission_denials":[], ...}
# An errored run still exits 0 with a JSON envelope but subtype/is_error flag
# the failure — the ERRORRUN directive reproduces that.
cat > "$TMP/bin/claude" <<'FAKE'
#!/usr/bin/env bash
rec="${FAKE_REC_DIR:?}"
n="$$-$RANDOM"
printf '%s\n' "$@" > "$rec/claude-argv.$n"
printenv HQ_DISABLED_HOOKS > "$rec/claude-hooksenv.$n" 2>/dev/null || : > "$rec/claude-hooksenv.$n"
pwd > "$rec/claude-cwd.$n"
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--print) prompt="$2"; shift 2 ;;
    --model|--output-format|--permission-mode) shift 2 ;;
    *) shift ;;
  esac
done
case "$prompt" in
  *ERRORRUN*)
    printf '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Ran out of turns.","permission_denials":[{"tool_name":"Glob"}]}\n' ;;
  *EMPTYREPLY*)
    printf '{"type":"result","subtype":"success","is_error":false,"result":"","permission_denials":[]}\n' ;;
  *BADSCHEMA*)
    # syntactically valid JSON, but pong is a string where the schema wants a number
    printf '{"type":"result","subtype":"success","is_error":false,"result":"{\\"pong\\": \\"not-a-number\\"}","permission_denials":[]}\n' ;;
  *PROSEJSON*)
    printf '{"type":"result","subtype":"success","is_error":false,"result":"Reading the file.{\\"pong\\": 99, \\"draft\\": true}Re-checking.{\\"pong\\": 2, \\"viaStdout\\": true}","permission_denials":[]}\n' ;;
  *"Return ONLY JSON matching this JSON Schema"*)
    printf '{"type":"result","subtype":"success","is_error":false,"result":"{\\"pong\\": 2, \\"viaStdout\\": true}","permission_denials":[]}\n' ;;
  *)
    printf '{"type":"result","subtype":"success","is_error":false,"result":"claudeecho:%s","permission_denials":[]}\n' "$prompt" ;;
esac
exit 0
FAKE
chmod +x "$TMP/bin/claude"

run_wf() { # run_wf <script-file> [extra runner args...] -> $OUT, $RC
  local script="$1"; shift
  OUT="$(HQ_WORKFLOW_CODEX_BIN="$TMP/bin/codex" HQ_WORKFLOW_GROK_BIN="$TMP/bin/grok" \
    HQ_WORKFLOW_CLAUDE_BIN="$TMP/bin/claude" \
    FAKE_REC_DIR="$TMP/rec" HQ_WORKFLOW_CPU_CHECK=0 HQ_ROOT="$HQROOT" \
    HQ_WORKFLOW_GATES_DIR="$TMP/gates-default" \
    node "$RUNNER" "$script" --quiet --run-dir "$TMP/run-$RANDOM" "$@" 2>"$TMP/stderr.last")"
  RC=$?
}

wait_for() { # wait_for <timeout-secs> '<condition>' — re-evaluated each tick
  local budget=$(( $1 * 5 ))
  local cond="$2"
  while [ "$budget" -gt 0 ]; do
    eval "$cond" >/dev/null 2>&1 && return 0
    sleep 0.2
    budget=$((budget - 1))
  done
  return 1
}

# ---- 1: codex engine defaults ------------------------------------------------
cat > "$TMP/wf-basic.mjs" <<'WF'
export const meta = { name: 'basic', description: 'basic' }
phase('Basic')
const text = await agent('say hi', { label: 'hi', tier: 'plan', timeoutSecs: 30 })
const structured = await agent('SCHEMA please', {
  label: 'schema', tier: 'plan', timeoutSecs: 30,
  schema: { type: 'object', properties: { pong: { type: 'number' } } },
})
return { text, structured, argsEcho: args }
WF
run_wf "$TMP/wf-basic.mjs" --args '{"k":"v"}'
check "codex workflow exits 0" "$RC"
echo "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.text === "echo:say hi" && r.structured.pong === 1
    && r.structured.sawSchema === true && r.argsEcho.k === "v" ? 0 : 1);
'
check "codex: return JSON (text + parsed schema + args)" "$?"

flags_ok=0
for f in "$TMP/rec"/codex-argv.*; do
  for flag in --dangerously-bypass-hook-trust --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox; do
    grep -qx -- "$flag" "$f" || flags_ok=1
  done
  grep -qx '/dev/null' "${f/argv/stdin}" || flags_ok=1
  tail -2 "$f" | head -1 | grep -qx -- '--' || flags_ok=1
  grep -qx -- '-C' "$f" || flags_ok=1
  grep -A1 -x -- '-C' "$f" | tail -1 | grep -qx -- "$HQROOT" || flags_ok=1
done
check "codex: unattended flags + stdin /dev/null + -- + -C <hq-root> on every spawn" "$flags_ok"

# ---- 1b: codex strict output-schema dialect ---------------------------------
# codex forwards --output-schema to its provider as a STRICT structured-output
# schema: every object node must carry additionalProperties:false AND list every
# property in `required`, or the request is rejected (HTTP 400
# invalid_json_schema) before the agent does any work — verified live against
# codex-cli 0.144.5 on 2026-08-19, which is what killed the first agent of every
# /orchestrate run. The runner rewrites the script's ordinary JSON Schema on the
# wire and maps the answer back, so a script keeps declaring optional properties
# the normal way (absent from `required`) and gets them back absent, not null.
rm -rf "$TMP/rec/schemas"
cat > "$TMP/wf-strict.mjs" <<'WF'
export const meta = { name: 'strict', description: 'strict output schema' }
const r = await agent('STRICTNULLS please', {
  label: 'strict', tier: 'exec', timeoutSecs: 30,
  schema: { type: 'object', required: ['pong'],
    properties: {
      pong: { type: 'number' },
      note: { type: 'string' },
      rows: { type: 'array', items: { type: 'object', required: ['id'],
        properties: { id: { type: 'string' }, hint: { type: 'string' } } } },
    } },
})
return r
WF
run_wf "$TMP/wf-strict.mjs"
check "codex strict-schema workflow exits 0" "$RC"

node "$REPO_ROOT/core/scripts/tests/assert-strict-output-schema.mjs" "$TMP/rec/schemas"/*.json 2>"$TMP/strict.err"
check "codex: the schema written to --output-schema is strict-valid at every object node" "$?"

node -e '
  const fs = require("fs");
  const files = fs.readdirSync(process.argv[1]).filter((f) => f.endsWith(".json"));
  if (files.length !== 1) process.exit(1);
  const s = JSON.parse(fs.readFileSync(`${process.argv[1]}/${files[0]}`, "utf8"));
  const rows = s.properties.rows.items;
  const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  process.exit(
    s.additionalProperties === false
    && eq(s.required, ["pong", "note", "rows"])
    && eq(s.properties.pong.type, "number")          // required: untouched
    && eq(s.properties.note.type, ["string", "null"]) // optional: nullable
    && rows.additionalProperties === false
    && eq(rows.required, ["id", "hint"])
    && eq(rows.properties.hint.type, ["string", "null"]) ? 0 : 1);
' "$TMP/rec/schemas"
check "codex: optional properties become required+nullable, required ones are untouched" "$?"

echo "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.pong === 1 && !("note" in r)
    && r.rows.length === 1 && r.rows[0].id === "a" && !("hint" in r.rows[0]) ? 0 : 1);
'
check "codex: nulls invited by the widening are stripped back out of the result" "$?"

# The adaptation is codex-only: the stdout engines get the script's schema
# verbatim in-prompt, so their local validation keeps matching what it asked for.
cat > "$TMP/wf-strict-grok.mjs" <<'WF'
export const meta = { name: 'strict-grok', description: 'strict schema, grok engine' }
return await agent('STRICTNULLS please', {
  label: 'strict-grok', tier: 'exec', engine: 'grok', timeoutSecs: 30,
  schema: { type: 'object', required: ['pong'],
    properties: { pong: { type: 'number' }, note: { type: 'string' } } },
})
WF
run_wf "$TMP/wf-strict-grok.mjs"
check "grok strict-schema workflow exits 0" "$RC"
gargv="$(grep -l 'STRICTNULLS' "$TMP/rec"/grok-argv.* 2>/dev/null | head -1)"
[ -n "$gargv" ] && grep -q '"required":\["pong"\]' "$gargv" && ! grep -q 'additionalProperties' "$gargv"
check "grok: prompt carries the script's own schema, not the codex strict rewrite" "$?"

# ---- 1c: the checkpoint stop gate never fires inside a spawned agent --------
# A spawned agent's whole contract is that its FINAL TEXT is the return value.
# HQ's Stop gate fires mechanically and demands one more turn AFTER the answer
# is already written — observed 2026-08-19 ending a finished claude stage on a
# `hq core checkpoint` tool call, so the envelope came back `result: ""` and the
# runner failed a stage that had actually done its work. Checkpointing is the
# launching session's job.
rm -f "$TMP/rec"/*-hooksenv.* 2>/dev/null
cat > "$TMP/wf-hookenv.mjs" <<'WF'
export const meta = { name: 'hookenv', description: 'hook suppression' }
await agent('say hi', { label: 'c', tier: 'exec', timeoutSecs: 30 })
await agent('say hi', { label: 'g', tier: 'exec', engine: 'grok', timeoutSecs: 30 })
await agent('say hi', { label: 'a', tier: 'exec', engine: 'claude', timeoutSecs: 30 })
return 'ok'
WF
run_wf "$TMP/wf-hookenv.mjs"
check "hook-suppression workflow exits 0" "$RC"

env_ok=0
for e in codex grok claude; do
  f="$(ls "$TMP/rec"/$e-hooksenv.* 2>/dev/null | head -1)"
  [ -n "$f" ] && grep -q 'checkpoint-stop-gate' "$f" || env_ok=1
done
check "every engine's child is spawned with the checkpoint stop gate disabled" "$env_ok"

# An operator suppression must survive — the runner adds to it, never replaces it.
rm -f "$TMP/rec"/*-hooksenv.* 2>/dev/null
export HQ_DISABLED_HOOKS=operator-chosen-hook
run_wf "$TMP/wf-hookenv.mjs"
unset HQ_DISABLED_HOOKS
check "hook-suppression workflow exits 0 (operator env set)" "$RC"
f="$(ls "$TMP/rec"/codex-hooksenv.* 2>/dev/null | head -1)"
[ -n "$f" ] && grep -q 'operator-chosen-hook' "$f" && grep -q 'checkpoint-stop-gate' "$f"
check "an operator's HQ_DISABLED_HOOKS is preserved, not clobbered" "$?"

# ---- 2: grok engine ----------------------------------------------------------
cat > "$TMP/wf-grok.mjs" <<'WF'
const text = await agent('say hi grok', { engine: 'grok', tier: 'exec', timeoutSecs: 30 })
const structured = await agent('shape this', {
  engine: 'grok', tier: 'exec', timeoutSecs: 30,
  schema: { type: 'object', properties: { pong: { type: 'number' } } },
})
return { text, structured }
WF
run_wf "$TMP/wf-grok.mjs"
check "grok workflow exits 0" "$RC"
echo "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.text === "grokecho:say hi grok" && r.structured.pong === 2
    && r.structured.viaStdout === true ? 0 : 1);
'
check "grok: reply captured from stdout; schema JSON parsed from the reply" "$?"

grok_ok=0
gf="$(grep -l -- 'say hi grok' "$TMP/rec"/grok-argv.* 2>/dev/null | head -1)"
[ -n "$gf" ] || grok_ok=1
if [ -n "$gf" ]; then
  grep -qx -- '--single' "$gf" || grok_ok=1
  grep -qx -- 'bypassPermissions' "$gf" || grok_ok=1
  grep -qx -- '--always-approve' "$gf" || grok_ok=1
  grep -qx -- 'grok-4.6' "$gf" || grok_ok=1
  grep -q -- '--dangerously-bypass' "$gf" && grok_ok=1
fi
check "grok: --single + bypassPermissions + --always-approve + grok-4.6, no codex flags" "$grok_ok"

# the JSON envelope is mandatory: plain mode prints nothing on a cancelled run
env_fmt=1
if [ -n "$gf" ]; then
  grep -A1 -x -- '--output-format' "$gf" | tail -1 | grep -qx -- 'json' && env_fmt=0
fi
check "grok: always requested with --output-format json (envelope, not plain)" "$env_fmt"

# ---- 2b: grok envelope failure modes ----------------------------------------
# A denied tool call (HQ hooks deny e.g. Glob-from-root) ends the run with
# stopReason "Cancelled" and exit 0. That must surface as a clear error naming
# the stop reason — NOT as a downstream "not valid JSON" parse failure.
cat > "$TMP/wf-grok-cancel.mjs" <<'WF'
const r = await (async () => {
  try {
    await agent('please CANCEL this one', { engine: 'grok', tier: 'exec', timeoutSecs: 30 })
    return { threw: false }
  } catch (e) {
    return {
      threw: true,
      namesStop: e.message.includes('stopReason=Cancelled'),
      keepsText: e.message.includes('Listing the directory'),
      notParseError: !e.message.includes('not valid JSON'),
    }
  }
})()
const empty = await (async () => {
  try {
    await agent('EMPTYREPLY please', { engine: 'grok', tier: 'exec', timeoutSecs: 30 })
    return { threw: false }
  } catch (e) { return { threw: true, marker: e.message.includes('empty reply') } }
})()
return { r, empty }
WF
run_wf "$TMP/wf-grok-cancel.mjs"
check "grok-cancel workflow exits 0 (errors are catchable in-script)" "$RC"
echo "$OUT" | node -e '
  const x = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(x.r.threw && x.r.namesStop && x.r.keepsText && x.r.notParseError
    && x.empty.threw && x.empty.marker ? 0 : 1);
'
check "cancelled run throws naming stopReason + last text; empty reply throws too" "$?"

# An engine with no schema flag narrates before answering, so the JSON arrives
# glued to prose (and sometimes after a discarded draft object). The schema
# result must still parse, taking the LAST balanced block.
cat > "$TMP/wf-grok-prose.mjs" <<'WF'
const r = await agent('PROSEJSON please', {
  engine: 'grok', tier: 'exec', timeoutSecs: 30,
  schema: { type: 'object', properties: { pong: { type: 'number' } } },
})
return r
WF
run_wf "$TMP/wf-grok-prose.mjs"
check "prose-wrapped JSON workflow exits 0" "$RC"
echo "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.pong === 2 && r.viaStdout === true ? 0 : 1);
'
check "JSON extracted from narration, last block wins over the earlier draft" "$?"

gc="$(ls "$TMP/rec"/grok-cwd.* 2>/dev/null | head -1)"
[ -n "$gc" ] && grep -qx -- "$HQROOT" "$gc"
check "grok: process anchored at the HQ root via cwd" "$?"

sf="$(grep -l -- 'shape this' "$TMP/rec"/grok-argv.* 2>/dev/null | head -1)"
[ -n "$sf" ] && grep -q 'Return ONLY JSON matching this JSON Schema' "$sf"
check "grok: schema instruction appended to the prompt" "$?"

# ---- 2d: claude engine -------------------------------------------------------
cat > "$TMP/wf-claude.mjs" <<'WF'
const text = await agent('say hi claude', { engine: 'claude', tier: 'exec', timeoutSecs: 30 })
const structured = await agent('shape this claude', {
  engine: 'claude', tier: 'exec', timeoutSecs: 30,
  schema: { type: 'object', properties: { pong: { type: 'number' } } },
})
return { text, structured }
WF
run_wf "$TMP/wf-claude.mjs"
check "claude workflow exits 0" "$RC"
echo "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.text === "claudeecho:say hi claude" && r.structured.pong === 2
    && r.structured.viaStdout === true ? 0 : 1);
'
check "claude: reply unwrapped from result envelope; schema JSON parsed from the reply" "$?"

claude_ok=0
cf="$(grep -l -- 'say hi claude' "$TMP/rec"/claude-argv.* 2>/dev/null | head -1)"
[ -n "$cf" ] || claude_ok=1
if [ -n "$cf" ]; then
  grep -qx -- '-p' "$cf" || claude_ok=1
  grep -qx -- 'bypassPermissions' "$cf" || claude_ok=1
  grep -qx -- 'sonnet' "$cf" || claude_ok=1
  grep -q -- '--always-approve' "$cf" && claude_ok=1
  grep -q -- '--dangerously-bypass' "$cf" && claude_ok=1
fi
check "claude: -p + bypassPermissions + sonnet (exec), no codex flags, no --always-approve" "$claude_ok"

env_fmt_c=1
if [ -n "$cf" ]; then
  grep -A1 -x -- '--output-format' "$cf" | tail -1 | grep -qx -- 'json' && env_fmt_c=0
fi
check "claude: always requested with --output-format json (envelope, not text)" "$env_fmt_c"

cc="$(ls "$TMP/rec"/claude-cwd.* 2>/dev/null | head -1)"
[ -n "$cc" ] && grep -qx -- "$HQROOT" "$cc"
check "claude: process anchored at the HQ root via cwd" "$?"

scf="$(grep -l -- 'shape this claude' "$TMP/rec"/claude-argv.* 2>/dev/null | head -1)"
[ -n "$scf" ] && grep -q 'Return ONLY JSON matching this JSON Schema' "$scf"
check "claude: schema instruction appended to the prompt" "$?"

# An errored envelope (subtype error / is_error) or an empty result still exits
# 0 — that must surface as a clear error naming the subtype, NOT a downstream
# "not valid JSON" parse failure. permission_denials are surfaced in the error.
cat > "$TMP/wf-claude-error.mjs" <<'WF'
const r = await (async () => {
  try {
    await agent('please ERRORRUN this one', { engine: 'claude', tier: 'exec', timeoutSecs: 30 })
    return { threw: false }
  } catch (e) {
    return {
      threw: true,
      namesSubtype: e.message.includes('subtype=error_during_execution'),
      notParseError: !e.message.includes('not valid JSON'),
      namesDenial: e.message.includes('denied'),
    }
  }
})()
const empty = await (async () => {
  try {
    await agent('EMPTYREPLY please', { engine: 'claude', tier: 'exec', timeoutSecs: 30 })
    return { threw: false }
  } catch (e) { return { threw: true, marker: e.message.includes('empty reply') } }
})()
return { r, empty }
WF
run_wf "$TMP/wf-claude-error.mjs"
check "claude-error workflow exits 0 (errors are catchable in-script)" "$RC"
echo "$OUT" | node -e '
  const x = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(x.r.threw && x.r.namesSubtype && x.r.notParseError && x.r.namesDenial
    && x.empty.threw && x.empty.marker ? 0 : 1);
'
check "errored envelope throws naming subtype + denials; empty result throws too" "$?"

# Prose-wrapped JSON (a discarded draft object then the real answer) still parses
# the LAST balanced block from the unwrapped result text.
cat > "$TMP/wf-claude-prose.mjs" <<'WF'
const r = await agent('PROSEJSON please', {
  engine: 'claude', tier: 'exec', timeoutSecs: 30,
  schema: { type: 'object', properties: { pong: { type: 'number' } } },
})
return r
WF
run_wf "$TMP/wf-claude-prose.mjs"
check "claude prose-wrapped JSON workflow exits 0" "$RC"
echo "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.pong === 2 && r.viaStdout === true ? 0 : 1);
'
check "claude: JSON extracted from narration, last block wins over earlier draft" "$?"

# The stdout engines only ask for opts.schema in-prompt (no server-side schema
# flag), so a valid-JSON-but-wrong-shape reply must be rejected here — not passed
# downstream where it crashes a later phase or misreports a result.
cat > "$TMP/wf-claude-badschema.mjs" <<'WF'
const r = await (async () => {
  try {
    await agent('BADSCHEMA please', {
      engine: 'claude', tier: 'exec', timeoutSecs: 30,
      schema: { type: 'object', required: ['pong'], properties: { pong: { type: 'number' } } },
    })
    return { threw: false }
  } catch (e) {
    return {
      threw: true,
      namesSchema: e.message.includes('violates the requested schema'),
      namesField: e.message.includes('pong'),
      notParseError: !e.message.includes('is not valid JSON'),
    }
  }
})()
return r
WF
run_wf "$TMP/wf-claude-badschema.mjs"
check "claude-badschema workflow exits 0 (schema error is catchable in-script)" "$RC"
echo "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.threw && r.namesSchema && r.namesField && r.notParseError ? 0 : 1);
'
check "schema-violating JSON (wrong type) rejected with a schema error, not passed through" "$?"

# ---- 3: tiers + models + validation ------------------------------------------
cat > "$TMP/wf-tier.mjs" <<'WF'
const badTier = await (async () => {
  try { await agent('x', { tier: 'sol', timeoutSecs: 30 }); return false }
  catch (e) { return e.message.includes('opts.tier') }
})()
const badEngine = await (async () => {
  try { await agent('x', { engine: 'gemini', tier: 'plan', timeoutSecs: 30 }); return false }
  catch (e) { return e.message.includes('opts.engine') }
})()
await agent('planner-prompt', { tier: 'plan', timeoutSecs: 30 })
await agent('doer-prompt', { tier: 'exec', timeoutSecs: 30 })
await agent('claude-planner-prompt', { engine: 'claude', tier: 'plan', timeoutSecs: 30 })
await agent('claude-doer-prompt', { engine: 'claude', tier: 'exec', timeoutSecs: 30 })
return { badTier, badEngine }
WF
run_wf "$TMP/wf-tier.mjs"
check "tier/engine validation workflow exits 0" "$RC"
echo "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.badTier === true && r.badEngine === true ? 0 : 1);
'
check "legacy tier name and unknown engine both throw" "$?"
plan_ok=1; exec_ok=1
for f in "$TMP/rec"/codex-argv.*; do
  if grep -qx -- 'planner-prompt' "$f"; then grep -qx -- 'gpt-5.6-sol' "$f" && plan_ok=0; fi
  if grep -qx -- 'doer-prompt' "$f"; then grep -qx -- 'gpt-5.6-terra' "$f" && exec_ok=0; fi
done
check "codex tiers: plan -> gpt-5.6-sol, exec -> gpt-5.6-terra" "$(( plan_ok + exec_ok ))"
cplan_ok=1; cexec_ok=1
for f in "$TMP/rec"/claude-argv.*; do
  if grep -qx -- 'claude-planner-prompt' "$f"; then grep -qx -- 'opus' "$f" && cplan_ok=0; fi
  if grep -qx -- 'claude-doer-prompt' "$f"; then grep -qx -- 'sonnet' "$f" && cexec_ok=0; fi
done
check "claude tiers: plan -> opus, exec -> sonnet" "$(( cplan_ok + cexec_ok ))"

cat > "$TMP/wf-tier-env.mjs" <<'WF'
await agent('env-codex-plan', { tier: 'plan', timeoutSecs: 30 })
await agent('env-grok-exec', { engine: 'grok', tier: 'exec', timeoutSecs: 30 })
await agent('env-claude-plan', { engine: 'claude', tier: 'plan', timeoutSecs: 30 })
return 'ok'
WF
export HQ_WORKFLOW_CODEX_PLAN_MODEL="custom-codex-plan"
export HQ_WORKFLOW_GROK_EXEC_MODEL="custom-grok-exec"
export HQ_WORKFLOW_CLAUDE_PLAN_MODEL="custom-claude-plan"
run_wf "$TMP/wf-tier-env.mjs"
unset HQ_WORKFLOW_CODEX_PLAN_MODEL HQ_WORKFLOW_GROK_EXEC_MODEL HQ_WORKFLOW_CLAUDE_PLAN_MODEL
env_c=1; env_g=1; env_cl=1
for f in "$TMP/rec"/codex-argv.*; do
  if grep -qx -- 'env-codex-plan' "$f"; then grep -qx -- 'custom-codex-plan' "$f" && env_c=0; fi
done
for f in "$TMP/rec"/grok-argv.*; do
  if grep -qx -- 'env-grok-exec' "$f"; then grep -qx -- 'custom-grok-exec' "$f" && env_g=0; fi
done
for f in "$TMP/rec"/claude-argv.*; do
  if grep -qx -- 'env-claude-plan' "$f"; then grep -qx -- 'custom-claude-plan' "$f" && env_cl=0; fi
done
check "model envs re-point tier models per engine" "$(( env_c + env_g + env_cl ))"

# ---- 4: parallel errors -> null ----------------------------------------------
cat > "$TMP/wf-parallel.mjs" <<'WF'
const r = await parallel([
  () => agent('p-one', { tier: 'exec', timeoutSecs: 30 }),
  () => agent('p-FAIL', { tier: 'exec', timeoutSecs: 30 }),
  () => { throw 'plain-string-throw' },
])
return r
WF
run_wf "$TMP/wf-parallel.mjs"
check "parallel workflow exits 0 despite failures" "$RC"
echo "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.length === 3 && r[0] === "echo:p-one" && r[1] === null && r[2] === null ? 0 : 1);
'
check "failing thunks resolved to null, sibling survived" "$?"

# ---- 5: soft timeout never kills ---------------------------------------------
cat > "$TMP/wf-timeout.mjs" <<'WF'
const r = await agent('hang SLEEP=3', { tier: 'exec', timeoutSecs: 1 })
return { result: r }
WF
run_wf "$TMP/wf-timeout.mjs"
check "timed-out agent workflow exits 0" "$RC"
printf '%s\n' "$OUT" | grep -v 'TIMEOUT WARNING' | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.result === "echo:hang SLEEP=3" ? 0 : 1);
'
check "slow agent NOT killed — result intact" "$?"
warns="$(printf '%s\n' "$OUT" | grep -c 'TIMEOUT WARNING')"
[ "$warns" -ge 2 ]
check "TIMEOUT WARNING repeated on stdout (${warns} >= 2)" "$?"

# ---- 6: HQ root + opts.cd ----------------------------------------------------
cat > "$TMP/wf-anchor.mjs" <<WF
await agent('anchor-worktree', {
  tier: 'exec', timeoutSecs: 30,
  cd: '$HQROOT/workspace/worktrees/demo',
})
return 'ok'
WF
run_wf "$TMP/wf-anchor.mjs"
check "anchor workflow exits 0" "$RC"
wt="$(grep -l -x -- 'anchor-worktree' "$TMP/rec"/codex-argv.* 2>/dev/null | head -1)"
if [ -z "$wt" ]; then wt="$(grep -l -- 'anchor-worktree' "$TMP/rec"/codex-argv.* 2>/dev/null | head -1)"; fi
[ -n "$wt" ] && grep -q "Working directory for this task: $HQROOT/workspace/worktrees/demo" "$wt"
check "opts.cd injected as a prompt preamble" "$?"

cat > "$TMP/wf-anchor-escape.mjs" <<WF
await agent('anchor-escape', { tier: 'exec', timeoutSecs: 30, cd: '$TMP/elsewhere' })
return 'ok'
WF
run_wf "$TMP/wf-anchor-escape.mjs"
[ "$RC" -ne 0 ] && grep -q 'must resolve inside the HQ root' "$TMP/stderr.last"
check "opts.cd outside the HQ root throws" "$?"

# Without HQ_ROOT env the runner anchors to ITS OWN install's HQ root (walking
# up from the script location — here, this checkout) no matter the cwd. That is
# the production contract: an installed runner never follows the caller's cwd.
cat > "$TMP/wf-detect.mjs" <<'WF'
return await agent('detect-root', { tier: 'plan', timeoutSecs: 30 })
WF
OUT="$(cd "$HQROOT" && HQ_WORKFLOW_CODEX_BIN="$TMP/bin/codex" FAKE_REC_DIR="$TMP/rec" \
  HQ_WORKFLOW_CPU_CHECK=0 HQ_WORKFLOW_GATES_DIR="$TMP/gates-default" \
  node "$RUNNER" "$TMP/wf-detect.mjs" --quiet --run-dir "$TMP/run-detect" 2>/dev/null)"
RC=$?
check "runner works without HQ_ROOT env" "$RC"
df="$(grep -l -x -- 'detect-root' "$TMP/rec"/codex-argv.* 2>/dev/null | head -1)"
[ -n "$df" ] && grep -A1 -x -- '-C' "$df" | tail -1 | grep -qx -- "$REPO_ROOT"
check "auto-detection anchors to the runner's own HQ root (script-dir walk)" "$?"

# ---- 7: gate() pause / resume / cache / legacy env ---------------------------
GATES="$TMP/gates1"; REC2="$TMP/rec2"; mkdir -p "$REC2"
cat > "$TMP/wf-gate.mjs" <<'WF'
const a = await gate('core-gate', 'Proceed how?', {
  options: [{ label: 'fast', description: 'ship it' }, { label: 'careful', description: 'slow lane' }],
  recommended: 'careful', pollSecs: 1,
})
const r = await agent('after:' + a.choice, { tier: 'exec', timeoutSecs: 30 })
return { choice: a.choice, r }
WF
OUTF="$TMP/gate-out"
HQ_WORKFLOW_CODEX_BIN="$TMP/bin/codex" FAKE_REC_DIR="$REC2" \
  HQ_WORKFLOW_CPU_CHECK=0 HQ_ROOT="$HQROOT" HQ_WORKFLOW_GATES_DIR="$GATES" \
  node "$RUNNER" "$TMP/wf-gate.mjs" --quiet --run-dir "$TMP/run-gate" >"$OUTF" 2>/dev/null &
BGPID=$!
wait_for 15 'test -f "$GATES/pending/core-gate.json"'
check "gate() wrote a pending file and paused" "$?"
node -e '
  const g = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.exit(g.question === "Proceed how?" && g.options.length === 2
    && g.recommended === "careful" && g.status === "pending"
    && typeof g.answer_path === "string" ? 0 : 1);
' "$GATES/pending/core-gate.json"
check "pending gate is self-contained" "$?"
grep -q 'GATE OPEN' "$OUTF" && grep -q 'workflow-gate.sh answer core-gate' "$OUTF"
check "GATE OPEN on stdout with the answer-command hint" "$?"

# The hinted CLI path must be one that EXISTS on this install — printing an
# absent path (core/ on a pre-release install) makes the gate unanswerable for
# whoever picks it up. The synthetic HQ root here has only personal/.
mkdir -p "$HQROOT/personal/scripts"
printf '#!/bin/bash\nexit 0\n' > "$HQROOT/personal/scripts/workflow-gate.sh"
GATESH="$TMP/gates-hint"; RECH="$TMP/rec-hint"; mkdir -p "$RECH"
OUTH="$TMP/hint-out"
HQ_WORKFLOW_CODEX_BIN="$TMP/bin/codex" FAKE_REC_DIR="$RECH" \
  HQ_WORKFLOW_CPU_CHECK=0 HQ_ROOT="$HQROOT" HQ_WORKFLOW_GATES_DIR="$GATESH" \
  node "$RUNNER" "$TMP/wf-gate.mjs" --quiet --run-dir "$TMP/run-hint" >"$OUTH" 2>/dev/null &
HPID=$!
wait_for 15 'test -f "$GATESH/pending/core-gate.json"'
grep -q 'personal/scripts/workflow-gate.sh answer core-gate' "$OUTH"
check "answer hint resolves to the CLI copy that exists (personal when core is absent)" "$?"
node -e '
  const g = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.exit(g.answer_hint.includes("personal/scripts/workflow-gate.sh") ? 0 : 1);
' "$GATESH/pending/core-gate.json"
check "pending payload answer_hint carries the resolved path too" "$?"
CODEX_WORKFLOW_GATES_DIR="$GATESH" bash "$REPO_ROOT/core/scripts/workflow-gate.sh" answer core-gate fast >/dev/null 2>&1
wait "$HPID" 2>/dev/null
rm -rf "$HQROOT/personal"
[ -z "$(ls "$REC2"/codex-argv.* 2>/dev/null)" ] && kill -0 "$BGPID" 2>/dev/null
check "no agents spawned while gated; process alive" "$?"
CODEX_WORKFLOW_GATES_DIR="$GATES" bash "$REPO_ROOT/core/scripts/workflow-gate.sh" answer core-gate fast >/dev/null 2>&1
wait "$BGPID"; RC=$?
check "answer via the shipped CLI resumed the same process (exit 0)" "$RC"
grep -v 'GATE ' "$OUTF" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.choice === "fast" && r.r === "echo:after:fast" ? 0 : 1);
'
check "answer flowed into the post-gate agent" "$?"
grep -q '"event":"gate-open"' "$TMP/run-gate/journal.jsonl" && grep -q '"event":"gate-answered"' "$TMP/run-gate/journal.jsonl"
check "journal has gate-open + gate-answered" "$?"

# legacy env fallback: only CODEX_WORKFLOW_GATES_DIR set
GATES2="$TMP/gates2"; REC3="$TMP/rec3"; mkdir -p "$REC3" "$GATES2/answered"
node -e 'require("fs").writeFileSync(process.argv[1] + "/answered/core-gate.json",
  JSON.stringify({id: "core-gate", choice: "careful", answered_at: new Date().toISOString()}))' "$GATES2"
OUT="$(HQ_WORKFLOW_CODEX_BIN="$TMP/bin/codex" FAKE_REC_DIR="$REC3" \
  HQ_WORKFLOW_CPU_CHECK=0 HQ_ROOT="$HQROOT" CODEX_WORKFLOW_GATES_DIR="$GATES2" \
  node "$RUNNER" "$TMP/wf-gate.mjs" --quiet --run-dir "$TMP/run-gate2" 2>/dev/null)"
RC=$?
[ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'GATE CACHED'
check "legacy CODEX_WORKFLOW_GATES_DIR honored (cached answer found there)" "$?"

# ---- 8: every schema this suite handed codex is strict-valid ----------------
# A sweep over the schema files the runner wrote across ALL the codex runs
# above, not just the one the strict section aimed at — a schema shape a future
# test introduces gets checked for free.
node "$REPO_ROOT/core/scripts/tests/assert-strict-output-schema.mjs" "$TMP/rec/schemas"/*.json 2>"$TMP/strict-all.err"
check "every schema handed to the codex engine in this suite is strict-valid" "$?"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
