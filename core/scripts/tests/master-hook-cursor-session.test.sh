#!/usr/bin/env bash
# hq-core: public
# master-hook-cursor-session.test.sh
#
# Cursor runs .claude/settings.json hooks through its Claude Code compatibility
# layer (cursor.com/docs/reference/third-party-hooks). Its payloads carry
# conversation_id on every event and session_id only on sessionStart, its
# shell tool is named Shell, and shell commands it runs export no chat id.
#
#   1. A Cursor shell call gets hookSpecificOutput.updatedInput: the same
#      tool_input with the command prefixed by `export HQ_SESSION_ID=<id>;`.
#   2. Running that rewritten command in a shell with no session environment
#      binds the company in the record the scope hook reads for that chat;
#      another chat stays unbound.
#   3. A Cursor command that opens with the in-tree bind is bound on the
#      payload id by the hook itself (fallback for hosts that ignore
#      updated_input, and for Windows, where the prefix is not added).
#   4. Claude Code payloads get no updatedInput.
#   5. A directory Stop hook that hangs is cut at the short Stop timeout, and
#      several share one Stop budget.
#   6. Claude-only Stop gates do not run on a Cursor Stop payload (Cursor sends
#      no stop_hook_active, so their block would loop); they still run for
#      Claude Code.
#   7. The Stop budget covers registry and directory Stop hooks alike, except
#      the conduct link delivery, the lanes monitor gate and the blocking Stop
#      gates (checkpoint-stop-gate and the three enforce-* gates): those run
#      past the budget, and the time they take is not charged to it.
set -euo pipefail
export HQ_HOOK_DEDUPE=0
# The Stop budget asserts below describe sequential dispatch.
export HQ_HOOK_PARALLEL=0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
# The dot in the root name lets case 3 check that the root is matched as a
# literal path, not as a pattern.
FIX="$TMP/hq.root"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/hooks" "$FIX/core/scripts/lib" \
  "$FIX/workspace/sessions" "$FIX/companies/acme/settings" "$FIX/companies/otherco/settings" \
  "$FIX/personal" "$FIX/fixture" "$TMP/home"
cp "$ROOT/.claude/hooks/master-hook.sh" "$ROOT/.claude/hooks/hook-timeout-probe.sh" \
  "$ROOT/.claude/hooks/hook-gate.sh" "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" \
  "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$ROOT/.claude/hooks/path-fold-lib.sh" "$FIX/.claude/hooks/"
cp "$ROOT/core/scripts/resolve-hq-root.sh" "$ROOT/core/scripts/hq-session.sh" \
  "$ROOT/core/scripts/hook-lib.sh" "$FIX/core/scripts/"
cp -R "$ROOT/core/scripts/lib/." "$FIX/core/scripts/lib/"
chmod +x "$FIX/.claude/hooks/master-hook.sh" "$FIX/core/scripts/hq-session.sh"
printf 'companies:\n  acme:\n    name: Acme\n  otherco:\n    name: Other\n' > "$FIX/companies/manifest.yaml"
touch "$FIX/companies/acme/settings/.keep" "$FIX/companies/otherco/settings/.keep"

# Each chat starts the way Cursor's sessionStart leaves it: bound to personal.
seed_personal() { # <chat-id>
  rm -rf "$FIX/workspace/sessions/$1"
  mkdir -p "$FIX/workspace/sessions/$1"
  printf 'session_id: %s\ncompany_slug: personal\n' "$1" > "$FIX/workspace/sessions/$1/meta.yaml"
}

# The environment of a hook process. Cursor exports no session id to hooks or
# to the shell commands it runs; strip any the test process inherited.
hook_env() {
  env -u HQ_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
    -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID -u HQ_FLEET_SESSION_ID \
    -u HQ_HOOK_SESSION_ID -u HQ_HOOK_TOOL_NAME -u HQ_HOOK_CWD -u HQ_HOOK_COMMAND \
    HOME="$TMP/home" HQ_ROOT="$FIX" HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_DEDUPE=0 \
    HQ_HQ_SESSION_NO_CLI=1 CLAUDE_PROJECT_DIR="$FIX" "$@"
}

run_master() { # <event> <payload> <out> <err> [env assignments...]
  local event="$1" payload="$2" out="$3" err="$4" rc=0
  shift 4
  printf '%s' "$payload" | hook_env "$@" bash "$FIX/.claude/hooks/master-hook.sh" "$event" \
    >"$out" 2>"$err" || rc=$?
  printf '%s' "$rc"
}

cursor_pre() { # <chat-id> <tool> <tool_input-json>
  jq -cn --arg cid "$1" --arg tool "$2" --argjson ti "$3" --arg root "$FIX" \
    '{conversation_id:$cid, generation_id:"gen-1", hook_event_name:"preToolUse",
      cursor_version:"2.0.34", workspace_roots:[$root], cwd:$root, model:"m",
      tool_name:$tool, tool_input:$ti, tool_use_id:"tu-1"}'
}
shell_ti() { jq -cn --arg c "$1" --arg d "$FIX" '{command:$c, working_directory:$d}'; }
stop_payload="$(jq -cn '{session_id:"stop-sess", hook_event_name:"Stop", stop_hook_active:false}')"

bound_company() { # <chat-id>
  awk '$1 == "company_slug:" { print $2; exit }' "$FIX/workspace/sessions/$1/meta.yaml" 2>/dev/null
}

scope_verdict() { # <payload> -> exit code of the scope hook
  local rc=0
  printf '%s' "$1" | hook_env bash "$FIX/.claude/hooks/mandatory-scope-authorizer.sh" \
    >/dev/null 2>"$TMP/scope.err" || rc=$?
  printf '%s' "$rc"
}

# ── 1. A Cursor shell call gets the HQ_SESSION_ID prefix ──────────────────
seed_personal chat-one
cmd='echo hello'
rc="$(run_master PreToolUse "$(cursor_pre chat-one Shell "$(shell_ti "$cmd")")" "$TMP/1.out" "$TMP/1.err")"
[ "$rc" = 0 ] || fail "cursor shell call: exit $rc: $(cat "$TMP/1.err")"
jq -e 'type == "object"' "$TMP/1.out" >/dev/null || fail "cursor shell call: stdout is not JSON: $(cat "$TMP/1.out")"
got="$(jq -r '.hookSpecificOutput.updatedInput.command // empty' "$TMP/1.out")"
[ "$got" = "export HQ_SESSION_ID=chat-one; $cmd" ] || fail "cursor shell call: updatedInput.command = '$got'"
jq -e --arg d "$FIX" '.hookSpecificOutput.updatedInput.working_directory == $d
  and .hookSpecificOutput.hookEventName == "PreToolUse"
  and (.hookSpecificOutput | has("permissionDecision") | not)' "$TMP/1.out" >/dev/null \
  || fail "cursor shell call: updatedInput must keep tool_input and decide nothing: $(cat "$TMP/1.out")"
pass "Cursor shell call is rewritten to export HQ_SESSION_ID=<conversation_id>"

# Already prefixed: left alone.
rc="$(run_master PreToolUse "$(cursor_pre chat-one Shell "$(shell_ti "export HQ_SESSION_ID=chat-one; $cmd")")" "$TMP/1b.out" "$TMP/1b.err")"
[ "$rc" = 0 ] || fail "prefixed call: exit $rc"
if jq -e '.hookSpecificOutput.updatedInput' "$TMP/1b.out" >/dev/null 2>&1; then
  fail "an already-prefixed command was prefixed again: $(cat "$TMP/1b.out")"
fi
pass "an already-prefixed command is not prefixed twice"

# ── 2. The rewritten bind lands in the record the scope hook reads ────────
seed_personal chat-two
seed_personal chat-three
bind_cmd='bash core/scripts/hq-session.sh set company_slug acme'
rc="$(run_master PreToolUse "$(cursor_pre chat-two Shell "$(shell_ti "$bind_cmd")")" "$TMP/2.out" "$TMP/2.err")"
[ "$rc" = 0 ] || fail "bind call: exit $rc: $(cat "$TMP/2.err")"
rewritten="$(jq -r '.hookSpecificOutput.updatedInput.command // empty' "$TMP/2.out")"
[ -n "$rewritten" ] || fail "bind call: no updatedInput: $(cat "$TMP/2.out")"
# Reset what the hook's own fallback bind wrote, so this case proves the
# rewritten command alone carries the identity.
seed_personal chat-two
# A Cursor shell: no session id in the environment, cwd at the HQ root.
( cd "$FIX" && hook_env CURSOR_AGENT=1 CURSOR_TRACE_ID=shared-trace bash -c "$rewritten" ) \
  >"$TMP/2.run.out" 2>"$TMP/2.run.err" || fail "rewritten bind failed: $(cat "$TMP/2.run.err")"
[ "$(bound_company chat-two)" = acme ] || fail "rewritten bind did not bind chat-two: $(cat "$FIX/workspace/sessions/chat-two/meta.yaml")"
[ "$(bound_company chat-three)" = personal ] || fail "chat-three changed: $(bound_company chat-three)"
write_ti() { jq -cn --arg p "$1" '{file_path:$p, content:"x"}'; }
rc="$(scope_verdict "$(cursor_pre chat-two Write "$(write_ti "$FIX/companies/acme/settings/new.md")")")"
[ "$rc" = 0 ] || fail "scope hook denied the bound chat: $(cat "$TMP/scope.err")"
rc="$(scope_verdict "$(cursor_pre chat-three Write "$(write_ti "$FIX/companies/acme/settings/new.md")")")"
[ "$rc" = 2 ] || fail "scope hook let the other chat write acme (exit $rc)"
pass "the rewritten bind binds this chat only, and the scope hook allows it"

# ── 3. Fallback: the hook binds on the payload id itself ──────────────────
seed_personal chat-four
# The command after the bind stays outside companies/: the scope guard runs
# before the command and sees this chat bound to personal, so a company path
# in the same command is refused (master-hook runs the scope guard even with
# no registry file).
rc="$(run_master PreToolUse "$(cursor_pre chat-four Shell "$(shell_ti "$bind_cmd && ls workspace")")" "$TMP/3.out" "$TMP/3.err")"
[ "$rc" = 0 ] || fail "fallback bind call: exit $rc: $(cat "$TMP/3.err")"
[ "$(bound_company chat-four)" = acme ] || fail "hook did not bind chat-four on its payload id: $(cat "$TMP/3.err")"
rc="$(scope_verdict "$(cursor_pre chat-four Write "$(write_ti "$FIX/companies/acme/settings/new.md")")")"
[ "$rc" = 0 ] || fail "scope hook denied chat-four after the fallback bind: $(cat "$TMP/scope.err")"
# Not a bind: nothing is bound.
seed_personal chat-five
run_master PreToolUse "$(cursor_pre chat-five Shell "$(shell_ti "echo core/scripts/hq-session.sh set company_slug acme")")" \
  "$TMP/3b.out" "$TMP/3b.err" >/dev/null
[ "$(bound_company chat-five)" = personal ] || fail "a command that only mentions the bind bound chat-five"
# Another tree's script whose path differs from the HQ root only where the
# root has a regex metacharacter: not this HQ's bind, so nothing is bound.
seed_personal chat-six
decoy_root="$TMP/hqxroot"
run_master PreToolUse "$(cursor_pre chat-six Shell "$(shell_ti "bash $decoy_root/core/scripts/hq-session.sh set company_slug acme")")" \
  "$TMP/3c.out" "$TMP/3c.err" >/dev/null
[ "$(bound_company chat-six)" = personal ] || fail "the bind regex matched the HQ root as a pattern: $decoy_root bound chat-six"
# The real absolute path still binds.
run_master PreToolUse "$(cursor_pre chat-six Shell "$(shell_ti "bash $FIX/core/scripts/hq-session.sh set company_slug acme")")" \
  "$TMP/3d.out" "$TMP/3d.err" >/dev/null
[ "$(bound_company chat-six)" = acme ] || fail "the absolute-path bind did not bind chat-six: $(cat "$TMP/3d.err")"
pass "a Cursor bind command is bound on the payload id by the hook"

# ── 4. Claude Code payloads are untouched ─────────────────────────────────
seed_personal claude-sess
payload="$(jq -cn --arg d "$FIX" '{session_id:"claude-sess", hook_event_name:"PreToolUse", cwd:$d,
  tool_name:"Bash", tool_input:{command:"bash core/scripts/hq-session.sh set company_slug acme"}}')"
rc="$(run_master PreToolUse "$payload" "$TMP/4.out" "$TMP/4.err")"
[ "$rc" = 0 ] || fail "claude call: exit $rc"
if grep -q updatedInput "$TMP/4.out" 2>/dev/null; then
  fail "a Claude Code payload got updatedInput: $(cat "$TMP/4.out")"
fi
[ "$(bound_company claude-sess)" = personal ] || fail "the hook bound a Claude Code session on its own"
pass "Claude Code payloads get no rewrite and no hook-side bind"

# ── 5. A hanging directory Stop hook is cut short; the Stop budget holds ──
mkdir -p "$FIX/core/hooks/Stop"
for n in 10 20 30; do
  printf '#!/usr/bin/env bash\ncat >/dev/null\nsleep 120\n' > "$FIX/core/hooks/Stop/$n-hang.sh"
  chmod +x "$FIX/core/hooks/Stop/$n-hang.sh"
done
start=$SECONDS
rc="$(run_master Stop "$stop_payload" "$TMP/5.out" "$TMP/5.err" HQ_MASTER_STOP_CHILD_TIMEOUT=2 HQ_MASTER_STOP_BUDGET=3)"
elapsed=$((SECONDS - start))
[ "$elapsed" -le 8 ] || fail "three hanging Stop hooks held master-hook ${elapsed}s (budget 3 s)"
grep -q 'Stop budget (3s) spent' "$TMP/5.err" || fail "budget skip was not reported: $(cat "$TMP/5.err")"
pass "three hanging Stop hooks end within the Stop budget (${elapsed}s, exit $rc)"
rm -f "$FIX/core/hooks/Stop/20-hang.sh" "$FIX/core/hooks/Stop/30-hang.sh"
start=$SECONDS
run_master Stop "$stop_payload" "$TMP/5b.out" "$TMP/5b.err" >/dev/null
elapsed=$((SECONDS - start))
[ "$elapsed" -le 16 ] || fail "one hanging Stop hook held master-hook ${elapsed}s with the default timeout"
pass "default directory Stop timeout cuts a hanging hook (${elapsed}s)"
rm -f "$FIX/core/hooks/Stop/10-hang.sh"

# ── 6. Claude-only Stop gates skip Cursor payloads ───────────────────────
cat > "$FIX/fixture/stop-block.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"decision":"block","reason":"fixture stop gate"}'
EOF
chmod +x "$FIX/fixture/stop-block.sh"
jq -n '{hooks: {Stop: [{matcher: "", hooks: [
  {id: "enforce-humanize-before-send", script: "fixture/stop-block.sh", timeout: 5, gated: false}]}]}}' \
  > "$FIX/.claude/hooks/hook-registry.json"
rc="$(run_master Stop "$stop_payload" "$TMP/6a.out" "$TMP/6a.err")"
jq -e '.decision == "block"' "$TMP/6a.out" >/dev/null 2>&1 \
  || fail "fixture: the gate did not block a Claude Code Stop (exit $rc): $(cat "$TMP/6a.out") $(cat "$TMP/6a.err")"
cursor_stop="$(jq -cn --arg root "$FIX" '{conversation_id:"chat-one", generation_id:"gen-2",
  hook_event_name:"stop", cursor_version:"2.0.34", workspace_roots:[$root], status:"completed", loop_count:0}')"
rc="$(run_master Stop "$cursor_stop" "$TMP/6b.out" "$TMP/6b.err")"
[ "$rc" = 0 ] || fail "cursor stop: exit $rc"
if grep -q '"block"' "$TMP/6b.out" 2>/dev/null; then
  fail "a Claude-only Stop gate blocked a Cursor Stop: $(cat "$TMP/6b.out")"
fi
pass "Claude-only Stop gates do not run for Cursor"

# ── 7. Registry Stop hooks share the budget; conduct, lanes and blocking gates are exempt ──
# A slow budgeted registry hook is cut at the budget, and later budgeted
# registry and directory hooks are skipped. The conduct link delivery, the
# lanes monitor gate and the four blocking Stop gates still run, past the
# budget and to completion.
cat > "$FIX/fixture/stop-slow.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
sleep 4
touch "$(dirname "$0")/slow.ran"
EOF
cat > "$FIX/fixture/stop-lanes.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
sleep 4
touch "$(dirname "$0")/lanes.ran"
EOF
cat > "$FIX/fixture/stop-deliver.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
touch "$(dirname "$0")/deliver.ran"
EOF
cat > "$FIX/fixture/stop-fast.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
touch "$(dirname "$0")/fast.ran"
EOF
cat > "$FIX/fixture/stop-advisory.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
touch "$(dirname "$0")/advisory.ran"
EOF
# One fixture per blocking gate: each leaves <gate-id>.ran when it runs, and
# checkpoint-stop-gate also returns decision "block".
blocking_gates="checkpoint-stop-gate enforce-capability-link-render enforce-final-message-link-placement enforce-humanize-before-send"
for gate in $blocking_gates; do
  {
    printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null'
    printf 'touch "$(dirname "$0")/%s.ran"\n' "$gate"
  } > "$FIX/fixture/gate-$gate.sh"
  chmod +x "$FIX/fixture/gate-$gate.sh"
done
cat >> "$FIX/fixture/gate-checkpoint-stop-gate.sh" <<'EOF'
printf '%s\n' '{"decision":"block","reason":"fixture checkpoint gate"}'
EOF
chmod +x "$FIX/fixture/stop-slow.sh" "$FIX/fixture/stop-lanes.sh" \
  "$FIX/fixture/stop-deliver.sh" "$FIX/fixture/stop-fast.sh" "$FIX/fixture/stop-advisory.sh"
mkdir -p "$FIX/core/hooks/Stop"
cat > "$FIX/core/hooks/Stop/10-mark.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
touch "$HQ_ROOT/fixture/dir.ran"
EOF
chmod +x "$FIX/core/hooks/Stop/10-mark.sh"
# Same order as the shipped registry: the slow advisory hook first, then a
# budgeted advisory hook, the blocking gates with another advisory hook among
# them, the lanes gate and conduct delivery.
jq -n '{hooks: {Stop: [{matcher: "", hooks: [
  {id: "observe-patterns", script: "fixture/stop-slow.sh", timeout: 30, gated: false},
  {id: "hq-autocommit-bash-sweep", script: "fixture/stop-advisory.sh", timeout: 30, gated: false},
  {id: "checkpoint-stop-gate", script: "fixture/gate-checkpoint-stop-gate.sh", timeout: 5, gated: false},
  {id: "capture-estimates", script: "fixture/stop-fast.sh", timeout: 30, gated: false},
  {id: "enforce-capability-link-render", script: "fixture/gate-enforce-capability-link-render.sh", timeout: 5, gated: false},
  {id: "enforce-final-message-link-placement", script: "fixture/gate-enforce-final-message-link-placement.sh", timeout: 5, gated: false},
  {id: "enforce-humanize-before-send", script: "fixture/gate-enforce-humanize-before-send.sh", timeout: 5, gated: false},
  {id: "lanes-senior-monitor-stop-gate", script: "fixture/stop-lanes.sh", timeout: 10, gated: false},
  {id: "conduct-lanes-link-deliver", script: "fixture/stop-deliver.sh", timeout: 5, gated: false}]}]}}' \
  > "$FIX/.claude/hooks/hook-registry.json"
rm -f "$FIX/fixture/"*.ran
rc="$(run_master Stop "$stop_payload" "$TMP/7.out" "$TMP/7.err" HQ_MASTER_STOP_BUDGET=2)"
[ ! -f "$FIX/fixture/slow.ran" ] || fail "a slow budgeted registry Stop hook outlasted the Stop budget: $(cat "$TMP/7.err")"
grep -q 'Stop budget (2s) spent; skipped hq-autocommit-bash-sweep' "$TMP/7.err" \
  || fail "the budgeted advisory hook after the slow hook was not skipped for budget (exit $rc): $(cat "$TMP/7.err")"
[ ! -f "$FIX/fixture/advisory.ran" ] || fail "a budgeted advisory Stop hook ran after the Stop budget was spent"
grep -q 'Stop budget (2s) spent; skipped capture-estimates' "$TMP/7.err" \
  || fail "the budgeted advisory hook among the gates was not skipped for budget: $(cat "$TMP/7.err")"
[ ! -f "$FIX/fixture/fast.ran" ] || fail "a budgeted advisory Stop hook among the gates ran after the budget was spent"
grep -q 'Stop budget (2s) spent; skipped 10-mark.sh' "$TMP/7.err" \
  || fail "the directory Stop hook was not skipped for budget: $(cat "$TMP/7.err")"
[ ! -f "$FIX/fixture/dir.ran" ] || fail "a directory Stop hook ran after the Stop budget was spent"
for gate in $blocking_gates; do
  [ -f "$FIX/fixture/$gate.ran" ] || fail "blocking Stop gate $gate was skipped by the Stop budget: $(cat "$TMP/7.err")"
  if grep -q "skipped $gate" "$TMP/7.err"; then
    fail "blocking Stop gate $gate was reported skipped: $(cat "$TMP/7.err")"
  fi
done
jq -e '.decision == "block"' "$TMP/7.out" >/dev/null 2>&1 \
  || fail "the checkpoint gate's block was lost after the Stop budget was spent (exit $rc): $(cat "$TMP/7.out") $(cat "$TMP/7.err")"
[ -f "$FIX/fixture/lanes.ran" ] || fail "the lanes Stop gate was cut or skipped by the Stop budget: $(cat "$TMP/7.err")"
[ -f "$FIX/fixture/deliver.ran" ] || fail "conduct link delivery was skipped by the Stop budget: $(cat "$TMP/7.err")"
if grep -Eq 'skipped (lanes-senior-monitor-stop-gate|conduct-lanes-link-deliver)' "$TMP/7.err"; then
  fail "an exempt Stop hook was reported skipped: $(cat "$TMP/7.err")"
fi
pass "budgeted advisory and directory Stop hooks stop at the budget; blocking gates, lanes gate and conduct delivery run past it"

# The time an exempt hook takes is not charged to the budget: a budgeted
# advisory hook and a directory hook after a 4 s lanes gate still run under a
# 3 s budget.
jq -n '{hooks: {Stop: [{matcher: "", hooks: [
  {id: "observe-patterns", script: "fixture/stop-fast.sh", timeout: 30, gated: false},
  {id: "lanes-senior-monitor-stop-gate", script: "fixture/stop-lanes.sh", timeout: 10, gated: false},
  {id: "hq-autocommit-bash-sweep", script: "fixture/stop-advisory.sh", timeout: 30, gated: false}]}]}}' \
  > "$FIX/.claude/hooks/hook-registry.json"
rm -f "$FIX/fixture/"*.ran
rc="$(run_master Stop "$stop_payload" "$TMP/7b.out" "$TMP/7b.err" HQ_MASTER_STOP_BUDGET=3)"
[ -f "$FIX/fixture/fast.ran" ] || fail "fixture: the first budgeted Stop hook did not run: $(cat "$TMP/7b.err")"
[ -f "$FIX/fixture/lanes.ran" ] || fail "the lanes Stop gate was cut by the Stop budget: $(cat "$TMP/7b.err")"
[ -f "$FIX/fixture/advisory.ran" ] \
  || fail "an exempt hook's run time spent the budget of a later advisory hook (exit $rc): $(cat "$TMP/7b.err")"
[ -f "$FIX/fixture/dir.ran" ] || fail "an exempt hook's run time spent the directory Stop budget: $(cat "$TMP/7b.err")"
if grep -q 'Stop budget' "$TMP/7b.err" 2>/dev/null; then
  fail "a Stop child was skipped for budget: $(cat "$TMP/7b.err")"
fi
pass "an exempt Stop hook's run time is not charged to the Stop budget"

# A blocking gate's run time is not charged either: a 4 s enforce gate runs to
# completion under a 3 s budget and leaves that budget for a later advisory hook.
cat > "$FIX/fixture/gate-slow.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
sleep 4
touch "$(dirname "$0")/gateslow.ran"
EOF
chmod +x "$FIX/fixture/gate-slow.sh"
jq -n '{hooks: {Stop: [{matcher: "", hooks: [
  {id: "observe-patterns", script: "fixture/stop-fast.sh", timeout: 30, gated: false},
  {id: "enforce-humanize-before-send", script: "fixture/gate-slow.sh", timeout: 10, gated: false},
  {id: "hq-autocommit-bash-sweep", script: "fixture/stop-advisory.sh", timeout: 30, gated: false}]}]}}' \
  > "$FIX/.claude/hooks/hook-registry.json"
rm -f "$FIX/fixture/"*.ran
rc="$(run_master Stop "$stop_payload" "$TMP/7c.out" "$TMP/7c.err" HQ_MASTER_STOP_BUDGET=3)"
[ -f "$FIX/fixture/gateslow.ran" ] || fail "a 4 s blocking gate was cut by a 3 s Stop budget: $(cat "$TMP/7c.err")"
[ -f "$FIX/fixture/advisory.ran" ] \
  || fail "a blocking gate's run time spent the budget of a later advisory hook (exit $rc): $(cat "$TMP/7c.err")"
if grep -q 'Stop budget' "$TMP/7c.err" 2>/dev/null; then
  fail "a Stop child was skipped for budget after a slow blocking gate: $(cat "$TMP/7c.err")"
fi
pass "a blocking Stop gate's run time is not charged to the Stop budget"
rm -f "$FIX/core/hooks/Stop/10-mark.sh"

echo "PASS: master-hook-cursor-session.test.sh"
