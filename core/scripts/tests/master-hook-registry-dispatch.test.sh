#!/usr/bin/env bash
# hq-core: public
# master-hook-registry-dispatch.test.sh — the gated project hooks are dispatched
# in-process by master-hook.sh from .claude/hooks/hook-registry.json instead of
# one settings.json registration each (Windows Git Bash paid ~1 s of process
# startup per registration; 34 per Bash tool call).
#
# Guards:
#   1. settings.json carries exactly one master-hook command per event and no
#      gate registrations (otherwise hooks would run twice).
#   2. Every registry script exists; every gated registry id is known to the
#      profile lists under the default profile (or is deliberately optional).
#   3. Prefilters are supersets: a known-trigger payload for each guarded hook
#      still reaches the hook and blocks.
#   4. A benign Bash payload skips the prefiltered hooks (trace shows skips).
#   5. HQ_DISABLED_HOOKS and HQ_HOOK_PROFILE=minimal are honoured in-process.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
SETTINGS="$ROOT/.claude/settings.json"
FAIL=0
pass() { echo "  ok: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

export CLAUDE_PROJECT_DIR="$ROOT"
export HQ_ALLOW_HQ_WORKTREE=1
export HQ_HOOK_TIMEOUT_SENTRY=0

echo "[1] settings.json wires one master-hook command per event, no gate entries"
gate_count="$(jq '[.hooks[][] | .hooks[] | select(.command | contains("hook-gate.sh"))] | length' "$SETTINGS")"
[ "$gate_count" = "0" ] && pass "no hook-gate registrations remain in settings.json" \
  || fail "settings.json still has $gate_count hook-gate registrations (would double-fire)"
for ev in PreToolUse PostToolUse Stop SessionStart UserPromptSubmit PreCompact; do
  n="$(jq --arg ev "$ev" '[.hooks[$ev][]? | .hooks[] | select(.command | contains("master-hook.sh"))] | length' "$SETTINGS")"
  [ "$n" = "1" ] && pass "$ev has one master-hook registration" || fail "$ev has $n master-hook registrations"
done

echo "[2] registry scripts exist and gated ids are known to the profile lists"
. "$ROOT/.claude/hooks/hook-gate.sh" --lib
# These three gated ids remain inactive pending an explicit owner choice
# for their profile placement; they are documented in MIGRATION.md.
DEFERRED_PROFILE_DECISION=" check-core-yaml-parity env-file-no-trailing-newline record-policy-retrieval "
while IFS=$'\t' read -r id script gated; do
  [ -f "$ROOT/$script" ] || fail "registry script missing: $script ($id)"
  if [ "$gated" = "true" ]; then
    if ! is_in_standard_profile "$id" && ! is_in_minimal_profile "$id" && ! is_in_strict_profile "$id"; then
      case "$DEFERRED_PROFILE_DECISION" in
        *" $id "*) ;;
        *) fail "gated id '$id' is in no profile list (would never run)" ;;
      esac
    fi
  fi
done < <(jq -r '.hooks[][] | .hooks[] | [.id, .script, (if .gated == false then "false" else "true" end)] | @tsv' "$REGISTRY" | sort -u)
pass "registry ids resolve to scripts and profile lists"

run_master() { # <event> <payload>  -> sets OUT RC ERR
  ERR_FILE="$(mktemp)"
  OUT="$(printf '%s' "$2" | bash "$MASTER" "$1" 2>"$ERR_FILE")"; RC=$?
  ERR="$(cat "$ERR_FILE")"; rm -f "$ERR_FILE"
}
payload_bash() { jq -nc --arg c "$1" --arg root "$ROOT" '{session_id:"mh-registry-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,tool_input:{command:$c}}'; }
payload_write() { jq -nc --arg p "$1" --arg root "$ROOT" '{session_id:"mh-registry-test",hook_event_name:"PreToolUse",tool_name:"Write",cwd:$root,tool_input:{file_path:$p,content:"x"}}'; }

echo "[3] known triggers still reach their guard through the prefilter"
K1="AKIA"; K2="ABCDEFGHIJKLMNOP"   # assembled so the literal never appears in this file
run_master PreToolUse "$(payload_bash "echo ${K1}${K2} > note.txt")"
# Avoid a producer-side SIGPIPE from `grep -q` under pipefail: ERR is already
# captured, so a here-string checks the identical stderr content directly.
[ "$RC" = "2" ] && grep -q "SECRET DETECTED" <<<"$ERR" && pass "detect-secrets blocks through the dispatcher" \
  || fail "detect-secrets did not block (rc=$RC): $ERR"
run_master PreToolUse "$(payload_write "$ROOT/.claude/CLAUDE.md")"
[ "$RC" = "2" ] && grep -q "locked HQ charter" <<<"$ERR" && pass "protect-core blocks the charter through the dispatcher" \
  || fail "protect-core did not block (rc=$RC): $ERR"
run_master PreToolUse "$(payload_bash "git -C $ROOT push --force")"
[ "$RC" = "2" ] && pass "block-hq-root-git-mutation blocks through the dispatcher" \
  || fail "git mutation guard did not block (rc=$RC): $ERR"
run_master PreToolUse "$(payload_bash "qmd vsearch hello")"
grep -q "GGUF" <<<"$ERR" && pass "block-qmd-model-download reached through the prefilter" \
  || pass "block-qmd-model-download ran (model present or guard allowed): rc=$RC"
run_master PreToolUse "$(payload_bash "printenv")"
[ "$RC" = "2" ] && grep -q "environment dump" <<<"$ERR" && pass "block-env-dump blocks printenv through the dispatcher" \
  || fail "block-env-dump did not block printenv (rc=$RC): $ERR"

echo "[3b] read-only handoff-script commands are allowed"
run_master PreToolUse "$(payload_bash "bash core/scripts/handoff-finalize.sh")"
[ "$RC" = "0" ] && [ -z "$ERR" ] && pass "running the handoff finalizer is not blocked by the Bash dispatcher" \
  || fail "handoff finalizer command was blocked (rc=$RC): $ERR"
run_master PreToolUse "$(payload_bash "sed -n 1,5p core/scripts/handoff-finalize.sh")"
[ "$RC" = "0" ] && [ -z "$ERR" ] && pass "reading the handoff finalizer is not blocked by the Bash dispatcher" \
  || fail "read-only handoff script command was blocked (rc=$RC): $ERR"

echo "[4] a benign Bash payload skips prefiltered guards"
HQ_HOOK_TRACE=1 run_master PreToolUse "$(payload_bash "echo bench")"
[ "$RC" = "0" ] && pass "benign command passes (rc=0)" || fail "benign command rc=$RC: $ERR"
for id in detect-secrets block-env-dump block-hq-root-git-mutation block-qmd-model-download block-unsafe-package-install; do
  grep -q "skip $id (prefilter)" <<<"$ERR" && pass "$id skipped by prefilter" || fail "$id was not skipped for a benign command"
done
grep -q "run mandatory-scope-authorizer" <<<"$ERR" && pass "mandatory-scope-authorizer always runs" \
  || fail "mandatory-scope-authorizer did not run"

echo "[5] disabled list and minimal profile are honoured in-process"
HQ_HOOK_TRACE=1 HQ_DISABLED_HOOKS=detect-secrets run_master PreToolUse "$(payload_bash "echo ${K1}${K2} > note.txt")"
[ "$RC" = "0" ] && pass "HQ_DISABLED_HOOKS skips detect-secrets" || fail "HQ_DISABLED_HOOKS not honoured (rc=$RC)"
HQ_HOOK_TRACE=1 HQ_HOOK_PROFILE=minimal run_master PreToolUse "$(payload_bash "echo bench")"
grep -q "run inject-policy-on-trigger" <<<"$ERR" && fail "minimal profile still ran inject-policy-on-trigger" \
  || pass "minimal profile drops non-safety hooks"
HQ_HOOK_PROFILE=bogus run_master PreToolUse "$(payload_bash "echo bench")"
grep -q "Unknown profile" <<<"$ERR" && pass "unknown profile reports an error" || fail "unknown profile silently accepted"

echo "[6] policy-vocabulary prefilter skips the injector only when no policy token is present"
PF_FIXTURE="$(mktemp -d)"
mkdir -p "$PF_FIXTURE/.claude/hooks" "$PF_FIXTURE/core/scripts/lib"   "$PF_FIXTURE/core/policies" "$PF_FIXTURE/personal/policies"   "$PF_FIXTURE/workspace/orchestrator/policy-trigger-state"
cp "$MASTER" "$PF_FIXTURE/.claude/hooks/master-hook.sh"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$PF_FIXTURE/.claude/hooks/"
cp "$ROOT/.claude/hooks/hook-timeout-watchdog.sh" "$PF_FIXTURE/.claude/hooks/"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$PF_FIXTURE/.claude/hooks/"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$PF_FIXTURE/core/scripts/lib/"
cp "$ROOT/core/scripts/lib/trigger-fact-text.awk" "$PF_FIXTURE/core/scripts/lib/"
printf 'hqVersion: "15.0.131"\n' > "$PF_FIXTURE/core/core.yaml"
cat > "$PF_FIXTURE/core/policies/test-git-trigger.md" <<'POLICY'
---
id: test-git-trigger
title: fixture git trigger
when: git
on: [PreToolUse]
enforcement: soft
---
Fixture trigger for the dispatcher prefilter test.
POLICY
cat > "$PF_FIXTURE/.claude/hooks/injector.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '{"injector":"ran"}'
SH
chmod +x "$PF_FIXTURE/.claude/hooks/injector.sh"
cat > "$PF_FIXTURE/.claude/hooks/hook-registry.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
  {"id":"inject-policy-on-trigger","script":".claude/hooks/injector.sh","timeout":30,"gated":false,"prefilter":{"policy_vocab":true}}
]}]}}
JSON
: > "$PF_FIXTURE/workspace/orchestrator/policy-trigger-state/mh-prefilter-test.txt"
run_pf_master() { # <command> -> sets PF_ERR and PF_RC
  local payload
  payload="$(jq -nc --arg c "$1" --arg root "$PF_FIXTURE" '{session_id:"mh-prefilter-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,tool_input:{command:$c}}')"
  PF_ERR_FILE="$(mktemp)"
  PF_OUT="$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$PF_FIXTURE" HQ_ROOT="$PF_FIXTURE" \
    HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_TRACE=1 bash "$PF_FIXTURE/.claude/hooks/master-hook.sh" PreToolUse 2>"$PF_ERR_FILE")"
  PF_RC=$?
  PF_ERR="$(cat "$PF_ERR_FILE")"
  rm -f "$PF_ERR_FILE"
}
run_pf_master "zzqqc153prefilterfixture"
grep -q "skip inject-policy-on-trigger (policy-vocab)" <<<"$PF_ERR" \
  && pass "token-free command skips the injector" \
  || fail "token-free command did not skip the injector: $PF_ERR"
PF_CACHE="$PF_FIXTURE/workspace/orchestrator/hook-state/policy-prefilter/personal_policies+core_policies+PreToolUse.v1"
[ -s "$PF_CACHE" ] && pass "compiled vocabulary written" || fail "no compiled vocabulary file at $PF_CACHE"
run_pf_master "git status"
grep -q "run inject-policy-on-trigger" <<<"$PF_ERR" \
  && pass "git command still runs the injector" \
  || fail "git command was skipped by the vocabulary prefilter"
cat > "$PF_FIXTURE/personal/policies/zz-registry-test-token.md" <<'POLICY'
---
id: zz-registry-test-token
title: registry dispatch test token
when: zzqqregistrytoken
on: [PreToolUse]
enforcement: soft
---
Test-only policy.
POLICY
sleep 1
run_pf_master "echo zzqqregistrytoken"
grep -q "run inject-policy-on-trigger" <<<"$PF_ERR" \
  && pass "new policy token recompiles the vocabulary and runs the injector" \
  || fail "new policy token did not run the injector: $PF_ERR"
rm -f "$PF_FIXTURE/personal/policies/zz-registry-test-token.md"
cat > "$PF_FIXTURE/personal/policies/zz-registry-test-negated.md" <<'POLICY'
---
id: zz-registry-test-negated
title: registry dispatch test negated
when: !zzqqregistrytoken
on: [PreToolUse]
enforcement: soft
---
Test-only policy.
POLICY
sleep 1
run_pf_master "cat README.md"
grep -q "run inject-policy-on-trigger" <<<"$PF_ERR" \
  && pass "unprovable policy disables the skip" \
  || fail "unprovable (negated) policy did not disable the skip"
rm -rf "$PF_FIXTURE"

echo "[7] a blocking registry hook wins over earlier errors or missing scripts"
FIXTURE="$(mktemp -d)"
mkdir -p "$FIXTURE/.claude/hooks" "$FIXTURE/core/scripts/lib"
cp "$MASTER" "$FIXTURE/.claude/hooks/master-hook.sh"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIXTURE/.claude/hooks/"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$FIXTURE/.claude/hooks/hook-gate.sh"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIXTURE/.claude/hooks/hook-timeout-probe.sh"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIXTURE/core/scripts/lib/hook-adapter-core.sh"
cat > "$FIXTURE/.claude/hooks/advisory.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 1
SH
cat > "$FIXTURE/.claude/hooks/guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'fixture guard blocked\n' >&2
exit 2
SH
chmod +x "$FIXTURE/.claude/hooks/advisory.sh" "$FIXTURE/.claude/hooks/guard.sh"
fixture_payload="$(jq -nc --arg root "$FIXTURE" '{session_id:"mh-exit-code-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,tool_input:{command:"echo registry test"}}')"
run_fixture_master() { # registry has already been written to $FIXTURE
  FIXTURE_ERR_FILE="$(mktemp)"
  FIXTURE_OUT="$(printf '%s' "$fixture_payload" | HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_TRACE=1 \
    bash "$FIXTURE/.claude/hooks/master-hook.sh" PreToolUse 2>"$FIXTURE_ERR_FILE")"
  FIXTURE_RC=$?
  FIXTURE_ERR="$(cat "$FIXTURE_ERR_FILE")"
  rm -f "$FIXTURE_ERR_FILE"
}
write_fixture_registry() { # <first script> <second script, or empty>
  jq -n --arg first "$1" --arg second "$2" '
    {hooks:{PreToolUse:[{
      matcher:"Bash",
      hooks: (
        [{id:"first",script:$first,timeout:30,gated:false}]
        + (if $second == "" then [] else [
          {id:"guard",script:$second,timeout:30,gated:false}
        ] end)
      )
    }]}}' > "$FIXTURE/.claude/hooks/hook-registry.json"
  rm -f "$FIXTURE/workspace/orchestrator/hook-state/registry-rows/PreToolUse.Bash.rows"
}

write_fixture_registry ".claude/hooks/advisory.sh" ".claude/hooks/guard.sh"
run_fixture_master
[ "$FIXTURE_RC" = "2" ] && grep -q "fixture guard blocked" <<<"$FIXTURE_ERR" \
  && pass "later block wins over an earlier advisory error" \
  || fail "advisory before block must exit 2 and preserve guard stderr (rc=$FIXTURE_RC): $FIXTURE_ERR"

write_fixture_registry ".claude/hooks/absent.sh" ".claude/hooks/guard.sh"
run_fixture_master
[ "$FIXTURE_RC" = "2" ] && grep -q "fixture guard blocked" <<<"$FIXTURE_ERR" \
  && grep -q "skip first (missing-script)" <<<"$FIXTURE_ERR" \
  && pass "missing registry script is skipped and later block wins" \
  || fail "missing script before block must exit 2, trace skip, and preserve guard stderr (rc=$FIXTURE_RC): $FIXTURE_ERR"

cat > "$FIXTURE/.claude/hooks/silent-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 2
SH
chmod +x "$FIXTURE/.claude/hooks/silent-guard.sh"
write_fixture_registry ".claude/hooks/silent-guard.sh" ""
run_fixture_master
[ "$FIXTURE_RC" = "2" ] && grep -q "Blocked by hook silent-guard" <<<"$FIXTURE_ERR" \
  && pass "silent sub-hook blocks include a reason naming the hook" \
  || fail "silent sub-hook block did not produce a named stderr reason (rc=$FIXTURE_RC): $FIXTURE_ERR"

cat > "$FIXTURE/.claude/hooks/json-block.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"block"}'
SH
chmod +x "$FIXTURE/.claude/hooks/json-block.sh"
write_fixture_registry ".claude/hooks/json-block.sh" ""
run_fixture_master
[ "$FIXTURE_RC" = "0" ] && jq -e '.decision == "block"' <<<"$FIXTURE_OUT" >/dev/null \
  && grep -q "Blocked by hook json-block" <<<"$FIXTURE_ERR" \
  && pass "JSON deny decisions include a reason naming the hook on stderr" \
  || fail "JSON deny did not produce a named stderr reason (rc=$FIXTURE_RC, out=$FIXTURE_OUT): $FIXTURE_ERR"

cat > "$FIXTURE/.claude/hooks/permission-deny.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"}}'
SH
chmod +x "$FIXTURE/.claude/hooks/permission-deny.sh"
write_fixture_registry ".claude/hooks/permission-deny.sh" ""
run_fixture_master
[ "$FIXTURE_RC" = "0" ] && jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$FIXTURE_OUT" >/dev/null \
  && grep -q "Blocked by hook permission-deny" <<<"$FIXTURE_ERR" \
  && pass "permissionDecision deny outputs include a reason naming the hook on stderr" \
  || fail "permissionDecision deny did not produce a named stderr reason (rc=$FIXTURE_RC, out=$FIXTURE_OUT): $FIXTURE_ERR"

cat > "$FIXTURE/.claude/hooks/json-looking-text.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '{"unfinished": }'
SH
chmod +x "$FIXTURE/.claude/hooks/json-looking-text.sh"
write_fixture_registry ".claude/hooks/json-looking-text.sh" ""
run_fixture_master
[ "$FIXTURE_RC" = "0" ] && [ "$FIXTURE_OUT" = '{"unfinished": }' ] \
  && pass "malformed JSON-looking child output remains plain text" \
  || fail "malformed JSON-looking output was lost or changed (rc=$FIXTURE_RC, out=$FIXTURE_OUT): $FIXTURE_ERR"

write_fixture_registry ".claude/hooks/advisory.sh" ""
run_fixture_master
[ "$FIXTURE_RC" -ne 0 ] && pass "advisory errors remain non-zero when no hook blocks" \
  || fail "advisory error was downgraded to success (rc=$FIXTURE_RC)"

cat > "$FIXTURE/.claude/hooks/exit-zero.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
set -euo pipefail
trap ':' EXIT
CHILD_STATE=first-child
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"exit-zero"}}'
exit "${1:-0}"
SH
cat > "$FIXTURE/.claude/hooks/exit-one.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
[ -z "${CHILD_STATE:-}" ] || exit 9
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"exit-one"}}'
exit "${1:-1}"
SH
cat > "$FIXTURE/.claude/hooks/exit-two.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"exit-two"}}'
exit "${1:-2}"
SH
chmod +x "$FIXTURE/.claude/hooks/exit-zero.sh" "$FIXTURE/.claude/hooks/exit-one.sh" "$FIXTURE/.claude/hooks/exit-two.sh"
jq -n \
  --arg first ".claude/hooks/exit-zero.sh" \
  --arg second ".claude/hooks/exit-one.sh" \
  --arg third ".claude/hooks/exit-two.sh" \
  '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[
    {id:"exit-zero",script:$first,timeout:30,gated:false,args:["0"],runner:"source"},
    {id:"exit-one",script:$second,timeout:30,gated:false,args:["1"],runner:"source"},
    {id:"exit-two",script:$third,timeout:30,gated:false,args:["2"],runner:"source"}
  ]}]}}' > "$FIXTURE/.claude/hooks/hook-registry.json"
rm -f "$FIXTURE/workspace/orchestrator/hook-state/registry-rows/PreToolUse.Bash.rows"
run_fixture_master
[ "$FIXTURE_RC" = "2" ] || fail "child exit 0/1/2 composition should finish at rc=2 (rc=$FIXTURE_RC)"
jq -e '.hookSpecificOutput.additionalContext == "exit-zero\n\nexit-one\n\nexit-two"' \
  <<<"$FIXTURE_OUT" >/dev/null \
  && pass "source-runner exits 0/1/2 compose every child's output in registry order" \
  || fail "source-runner stopped after an exit or changed composition: $FIXTURE_OUT"

# Exercise the timeout runner's completion-marker branch. The shim runs the
# child command directly, then records whether the branch wrote its marker
# before master-hook removes it in record_child_execution.
MARKER_BIN="$FIXTURE/timeout-bin"
MARKER_TRACE="$FIXTURE/completion-trace"
mkdir -p "$MARKER_BIN"
cat > "$MARKER_BIN/timeout" <<'SH'
#!/usr/bin/env bash
set -u
[ "$#" -gt 1 ] || exit 125
shift
"$@"
rc=$?
if [ "${1:-}" = "bash" ] && [ "${2:-}" = "-c" ] \
   && [[ "${3:-}" == *'marker="$1"'* ]]; then
  marker="${5:-}"
  child="${6:-}"
  if [ -f "$marker" ]; then state=recorded-completed; else state=missing; fi
  printf '%s\t%s\n' "${child##*/}" "$state" >> "${HQ_TEST_COMPLETION_TRACE:?}"
fi
exit "$rc"
SH
chmod +x "$MARKER_BIN/timeout"
: > "$MARKER_TRACE"
PATH="$MARKER_BIN:$PATH" HQ_TEST_COMPLETION_TRACE="$MARKER_TRACE" run_fixture_master
[ "$FIXTURE_RC" = "2" ] || fail "timeout-marker source exits should finish at rc=2 (rc=$FIXTURE_RC)"
jq -e '.hookSpecificOutput.additionalContext == "exit-zero\n\nexit-one\n\nexit-two"' \
  <<<"$FIXTURE_OUT" >/dev/null \
  && pass "timeout-marker source exits still run later children and preserve output order" \
  || fail "timeout-marker source exits changed composition: $FIXTURE_OUT"
for child in exit-zero.sh exit-one.sh exit-two.sh; do
  grep -F "$child"$'\t'recorded-completed "$MARKER_TRACE" >/dev/null \
    || fail "timeout-marker branch did not record $child as completed"
done
[ "$(wc -l < "$MARKER_TRACE" | tr -d '[:space:]')" = "3" ] \
  && pass "timeout-marker branch checks all three source children before recording them" \
  || fail "expected completion-marker evidence for all three source children: $(cat "$MARKER_TRACE")"
rm -rf "$FIXTURE"

if [ "$FAIL" -eq 0 ]; then echo "master-hook-registry-dispatch: all checks passed"; exit 0; fi
echo "master-hook-registry-dispatch: $FAIL failure(s)" >&2; exit 1
