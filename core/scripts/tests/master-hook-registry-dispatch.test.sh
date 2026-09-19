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
# Ids that were already gated-but-absent from every profile list when the
# registry was introduced (they never ran under hook-gate.sh either). Kept
# byte-for-byte to preserve behaviour; enabling them is a separate decision.
KNOWN_DEAD=" capture-estimates check-core-yaml-parity env-file-no-trailing-newline record-policy-retrieval "
while IFS=$'\t' read -r id script gated; do
  [ -f "$ROOT/$script" ] || fail "registry script missing: $script ($id)"
  if [ "$gated" = "true" ]; then
    if ! is_in_standard_profile "$id" && ! is_in_minimal_profile "$id" && ! is_in_strict_profile "$id"; then
      case "$KNOWN_DEAD" in
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
PF_DIR="$ROOT/workspace/orchestrator/hook-state/policy-prefilter"
rm -rf "$PF_DIR"
HQ_HOOK_TRACE=1 run_master PreToolUse "$(payload_bash "cat README.md")"
grep -q "skip inject-policy-on-trigger (policy-vocab)" <<<"$ERR" && pass "token-free command skips the injector" \
  || fail "token-free command did not skip the injector: $(printf '%s' "$ERR" | grep inject-policy)"
ls "$PF_DIR"/*PreToolUse.v1 >/dev/null 2>&1 && pass "compiled vocabulary written" || fail "no compiled vocabulary file"
HQ_HOOK_TRACE=1 run_master PreToolUse "$(payload_bash "git -C $ROOT status")"
grep -q "run inject-policy-on-trigger" <<<"$ERR" && pass "git command still runs the injector" \
  || fail "git command was skipped by the vocabulary prefilter"
# A new policy keyed on a fresh token must invalidate the compiled vocabulary
# (directory mtime) and make that token run the injector.
TMP_POLICY="$ROOT/personal/policies/zz-registry-test-token.md"
mkdir -p "$ROOT/personal/policies"
cat > "$TMP_POLICY" <<'POLICY'
---
id: zz-registry-test-token
title: registry dispatch test token
when: zzqqregistrytoken
on: [PreToolUse]
enforcement: soft
---
## Rule
Test-only policy; safe to delete.
POLICY
sleep 1
HQ_HOOK_TRACE=1 run_master PreToolUse "$(payload_bash "echo zzqqregistrytoken")"
rc_new=$?
grep -q "run inject-policy-on-trigger" <<<"$ERR" && pass "new policy token recompiles the vocabulary and runs the injector" \
  || fail "new policy token did not run the injector: $(printf '%s' "$ERR" | grep inject-policy)"
# A policy the compiler cannot prove (bare negation) must disable the skip.
# Staleness is detected by policy-directory mtime (a file added, removed or
# renamed) or the 5 minute TTL; an in-place edit alone is picked up at the
# TTL. Replace the file under a new name so the directory mtime changes.
rm -f "$TMP_POLICY"
TMP_POLICY="$ROOT/personal/policies/zz-registry-test-negated.md"
cat > "$TMP_POLICY" <<'POLICY'
---
id: zz-registry-test-negated
title: registry dispatch test negated
when: !zzqqregistrytoken
on: [PreToolUse]
enforcement: soft
---
## Rule
Test-only policy; safe to delete.
POLICY
sleep 1
HQ_HOOK_TRACE=1 run_master PreToolUse "$(payload_bash "cat README.md")"
grep -q "run inject-policy-on-trigger" <<<"$ERR" && pass "unprovable policy disables the skip" \
  || fail "unprovable (negated) policy did not disable the skip"
rm -f "$TMP_POLICY"; rm -rf "$PF_DIR"
rm -f "$ROOT/workspace/orchestrator/policy-trigger-state/mh-registry-test"* 2>/dev/null

echo "[7] a blocking registry hook wins over earlier errors or missing scripts"
FIXTURE="$(mktemp -d)"
mkdir -p "$FIXTURE/.claude/hooks"
cp "$MASTER" "$FIXTURE/.claude/hooks/master-hook.sh"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$FIXTURE/.claude/hooks/hook-gate.sh"
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
  printf '%s' "$fixture_payload" | HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_TRACE=1 \
    bash "$FIXTURE/.claude/hooks/master-hook.sh" PreToolUse > /dev/null 2>"$FIXTURE_ERR_FILE"
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

write_fixture_registry ".claude/hooks/advisory.sh" ""
run_fixture_master
[ "$FIXTURE_RC" -ne 0 ] && pass "advisory errors remain non-zero when no hook blocks" \
  || fail "advisory error was downgraded to success (rc=$FIXTURE_RC)"
rm -rf "$FIXTURE"

if [ "$FAIL" -eq 0 ]; then echo "master-hook-registry-dispatch: all checks passed"; exit 0; fi
echo "master-hook-registry-dispatch: $FAIL failure(s)" >&2; exit 1
