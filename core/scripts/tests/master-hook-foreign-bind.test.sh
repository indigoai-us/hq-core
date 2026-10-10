#!/usr/bin/env bash
# hq-core: public
# US-007: a SessionStart whose cwd is outside the HQ tree (cwd_kind=foreign)
# resolves its company from the repo-to-company registry through
# `$HQ_CLI_BIN resolve-company --path <cwd> --json`. Hit binds the company and
# emits its policy digest; miss binds personal with one `hq link` hint;
# resolver-unavailable binds personal with a loud stderr line. The scope
# authorizer then allows the foreign repo and blocks other companies' paths.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
FIX="$TMP/hq"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts/lib" "$FIX/workspace/sessions" \
  "$FIX/companies/indigo/policies" "$FIX/companies/otherco/policies" "$FIX/personal" \
  "$TMP/bin" "$TMP/linked-repo" "$TMP/plain-folder"
cp "$ROOT/.claude/hooks/master-hook.sh" "$ROOT/.claude/hooks/hook-timeout-probe.sh" \
  "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$FIX/.claude/hooks/"
cp "$ROOT/core/scripts/resolve-hq-root.sh" "$ROOT/core/scripts/resolve-company.sh" \
  "$ROOT/core/scripts/hq-anywhere-runtime-flag.cjs" "$ROOT/core/scripts/hq-session.sh" "$ROOT/core/scripts/hook-lib.sh" "$FIX/core/scripts/"
source "$ROOT/core/scripts/tests/hq-anywhere-flag-fixture.sh"
hq_anywhere_flag_fixture "$TMP"
cp -R "$ROOT/core/scripts/lib/." "$FIX/core/scripts/lib/"
printf 'companies:\n  indigo:\n    name: Indigo\n  otherco:\n    name: Other\n' > "$FIX/companies/manifest.yaml"
cat > "$FIX/companies/indigo/policies/indigo-fixture-rule.md" <<'MD'
---
id: indigo-fixture-rule
enforcement: hard
---
## Rule

Indigo fixture hard rule.
MD

# Registry stub: linked-repo → indigo, anything else → miss. Records each call.
cat > "$TMP/bin/hq-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/stub-calls.log"
[ "\$1 \$2 \$4" = "resolve-company --path --json" ] || exit 64
case "\$3" in
  "$TMP/linked-repo"*) printf '{"company":"indigo","key":"%s","source":"link"}\n' "\$3" ;;
  *) printf '{"company":null,"reason":"no registry entry"}\n' ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 3\n' > "$TMP/bin/hq-broken"
printf '#!/usr/bin/env bash\nexit 127\n' > "$TMP/bin/hq-missing"
cat > "$TMP/bin/hq-ghost" <<'STUB'
#!/usr/bin/env bash
printf '{"company":"ghostco","key":"k","source":"link"}\n'
STUB
chmod +x "$TMP/bin/hq-stub" "$TMP/bin/hq-broken" "$TMP/bin/hq-ghost"

N=0
start_session() { # <cwd> <cli-bin> [agent_id] [agent_type] → sets SID, OUT, ERR
  N=$((N + 1))
  SID="foreign-sess-$N"
  OUT="$TMP/out.$N"; ERR="$TMP/err.$N"
  jq -cn --arg sid "$SID" --arg cwd "$1" --arg aid "${3:-}" --arg atype "${4:-}" \
    '({session_id:$sid, cwd:$cwd, hook_event_name:"SessionStart", source:"startup"}
      + (if $aid == "" then {} else {agent_id:$aid} end)
      + (if $atype == "" then {} else {agent_type:$atype} end))' \
    | if [ "${5:-configured}" = "missing-flag-config" ]; then
        ( cd "$1" && env -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID -u HQ_FLAG_HQ_ANYWHERE_RUNTIME \
            HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HQ_SESSION_NO_CLI=1 HQ_CLI_BIN="$2" \
            HQ_FLAG_CLI_BIN="$TMP/bin/hq-stub" HQ_TEST_FLAG=true \
            bash "$FIX/.claude/hooks/master-hook.sh" SessionStart ) >"$OUT" 2>"$ERR"
      elif [ "${5:-configured}" = "local-kill-switch" ]; then
        ( cd "$1" && env -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID \
            HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HQ_SESSION_NO_CLI=1 HQ_CLI_BIN="$2" \
            HQ_FLAG_CLI_BIN="$TMP/bin/hq-stub" HQ_FLAG_HQ_ANYWHERE_RUNTIME=0 \
            bash "$FIX/.claude/hooks/master-hook.sh" SessionStart ) >"$OUT" 2>"$ERR"
      else
        ( cd "$1" && env HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HQ_SESSION_NO_CLI=1 HQ_CLI_BIN="$2" \
            HQ_FLAG_CLI_BIN="$TMP/bin/hq-stub" HQ_FLAGS_API_URL=https://flags.test \
            HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG=true \
            bash "$FIX/.claude/hooks/master-hook.sh" SessionStart ) >"$OUT" 2>"$ERR"
      fi \
    || fail "master-hook exited non-zero for $1: $(cat "$ERR")"
}
bound() { HQ_HQ_SESSION_NO_CLI=1 bash "$FIX/core/scripts/hq-session.sh" --session-id "$SID" get "$1"; }
context() { jq -r '.hookSpecificOutput.additionalContext // ""' "$OUT"; }

# 1. Hit: linked repo binds indigo and emits the indigo policy digest.
start_session "$TMP/linked-repo" "$TMP/bin/hq-stub"
[ "$(bound company_slug)" = "indigo" ] || fail "hit bound '$(bound company_slug)', want indigo"
[ "$(bound foreign_cwd)" = "$TMP/linked-repo" ] || fail "foreign_cwd not recorded"
[ -f "$FIX/workspace/sessions/$SID/meta.yaml" ] || fail "meta.yaml not under HQ workspace/sessions/<sid>/"
context | grep -q 'company-policy-digest co="indigo"' || fail "hit output lacks indigo policy digest: $(cat "$OUT")"
context | grep -q 'indigo-fixture-rule' || fail "hit digest lacks the indigo hard rule"
grep -q "resolve-company --path $TMP/linked-repo --json" "$TMP/stub-calls.log" || fail "resolver not called with --path <cwd> --json"
pass "hit binds indigo and emits its policy digest"
HIT_SID="$SID"

# 2. Miss: unlinked folder binds personal, link hint exactly once.
start_session "$TMP/plain-folder" "$TMP/bin/hq-stub"
[ "$(bound company_slug)" = "personal" ] || fail "miss bound '$(bound company_slug)', want personal"
[ "$(context | grep -o 'hq link <company>' | wc -l | tr -d ' ')" = "1" ] || fail "miss hint count != 1: $(cat "$OUT")"
if context | grep -q 'company-policy-digest'; then fail "miss emitted a company digest"; fi
pass "miss binds personal with one hq link hint"

# This child reports the flag inherited from master-hook without a registry config.
mkdir -p "$FIX/core/hooks/SessionStart"
cat > "$FIX/core/hooks/SessionStart/98-anywhere-flag-state.sh" <<'HOOK'
#!/usr/bin/env bash
jq -cn --arg enabled "${HQ_ANYWHERE_RUNTIME_ENABLED:-unset}" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("HQ_ANYWHERE_RUNTIME_ENABLED=" + $enabled)}}'
HOOK
chmod +x "$FIX/core/hooks/SessionStart/98-anywhere-flag-state.sh"

# With no endpoint or company UID, the runtime flag reader's fail-safe still
# enables the Anywhere hook path, while the company resolver binds personal.
start_session "$TMP/plain-folder" "$TMP/bin/hq-stub" "" "" missing-flag-config
[ "$(bound company_slug)" = "personal" ] || fail "missing flag config did not bind personal"
context | grep -q 'hq link <company>' || fail "missing flag config skipped the default-on Anywhere path"
context | grep -q 'HQ_ANYWHERE_RUNTIME_ENABLED=true' || fail "missing flag config did not export the ON decision"
pass "missing endpoint and company UID keep the default-on hook path"
rm -f "$FIX/core/hooks/SessionStart/98-anywhere-flag-state.sh"

# 2b. A later SessionStart (resume) for the bound session does not repeat the hint.
jq -cn --arg sid "$SID" --arg cwd "$TMP/plain-folder" '{session_id:$sid, cwd:$cwd, source:"resume"}' \
  | ( cd "$TMP/plain-folder" && env HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_DEDUPE=0 HQ_HQ_SESSION_NO_CLI=1 HQ_CLI_BIN="$TMP/bin/hq-stub" \
      bash "$FIX/.claude/hooks/master-hook.sh" SessionStart ) > "$TMP/resume.out" 2>/dev/null
if grep -q 'hq link' "$TMP/resume.out"; then fail "resume repeated the link hint"; fi
pass "resume does not repeat the hint"

# The local override remains authoritative when the registry config is absent.
start_session "$TMP/plain-folder" "$TMP/bin/hq-stub" "" "" local-kill-switch
if context | grep -q 'hq link <company>'; then fail "local kill switch did not suppress the Anywhere hook path"; fi
pass "local kill switch suppresses the hook path without registry config"

# 3. Resolver unavailable: CLI missing → personal, loud stderr line.
start_session "$TMP/linked-repo" "$TMP/bin/hq-missing"
[ "$(bound company_slug)" = "personal" ] || fail "missing CLI bound '$(bound company_slug)', want personal"
grep -q 'company registry unavailable' "$ERR" || fail "missing CLI was silent on stderr"
context | grep -q 'could not check' || fail "missing CLI gave the model no notice"
pass "missing CLI binds personal with a stderr warning"

# 3b. Resolver unavailable: CLI exits non-zero → personal, loud stderr line.
start_session "$TMP/linked-repo" "$TMP/bin/hq-broken"
[ "$(bound company_slug)" = "personal" ] || fail "failing CLI bound '$(bound company_slug)', want personal"
grep -q "exited 3" "$ERR" || fail "failing CLI was silent on stderr: $(cat "$ERR")"
pass "failing CLI binds personal with a stderr warning"

# 3c. Registry names a company with no tenant directory → personal, not a guess.
start_session "$TMP/linked-repo" "$TMP/bin/hq-ghost"
[ "$(bound company_slug)" = "personal" ] || fail "unknown company bound '$(bound company_slug)'"
grep -q "ghostco" "$ERR" || fail "unknown company was silent on stderr"
pass "unknown registry company binds personal"

# 4. HQ-tree sessions are untouched: no foreign bind from the HQ root.
start_session "$FIX" "$TMP/bin/hq-stub"
[ -z "$(bound company_slug)" ] || fail "HQ-root session was bound to '$(bound company_slug)'"
pass "HQ-root session is not foreign-bound"

# 5. Scope authorizer for the hit session: foreign repo allowed, other company blocked.
authz() { # <path> → exit code
  local rc=0
  jq -cn --arg sid "$HIT_SID" --arg p "$1" --arg cwd "$TMP/linked-repo" \
    '{session_id:$sid, cwd:$cwd, tool_name:"Write", tool_input:{file_path:$p, content:"x"}}' \
    | bash "$FIX/.claude/hooks/mandatory-scope-authorizer.sh" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
[ "$(authz "$TMP/linked-repo/src/app.ts")" = "0" ] || fail "foreign repo write blocked"
[ "$(authz "$FIX/companies/indigo/knowledge/a.md")" = "0" ] || fail "bound company write blocked"
[ "$(authz "$FIX/companies/otherco/knowledge/a.md")" = "2" ] || fail "other company write not blocked"
pass "authorizer allows foreign repo + bound company, blocks other company"

# 6. Task subagent SessionStart receives the same tuple key used by PreToolUse.
start_session "$TMP/linked-repo" "$TMP/bin/hq-stub" "agent-a" "general-purpose"
AGENT_SID="$SID"
AGENT_CAP="$FIX/workspace/sessions/$AGENT_SID/agents/agent-a/scope-capability.json"
[ "$(jq -r '.company_slug' "$AGENT_CAP")" = "indigo" ] || fail "Task SessionStart did not mint tuple capability"
[ -z "$(jq -r '.company_slug // empty' "$FIX/workspace/sessions/$AGENT_SID/scope-capability.json" 2>/dev/null || true)" ] \
  || fail "Task SessionStart wrote the main-thread capability too"
printf 'session_id: %s\ncompany_slug: otherco\n' "$AGENT_SID" > "$FIX/workspace/sessions/$AGENT_SID/meta.yaml"
jq -cn --arg sid "$AGENT_SID" --arg cwd "$FIX" \
  '{session_id:$sid,cwd:$cwd,source:"resume",agent_id:"agent-a",agent_type:"general-purpose"}' \
  | ( cd "$FIX" && env HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_DEDUPE=0 HQ_HQ_SESSION_NO_CLI=1 HQ_CLI_BIN="$TMP/bin/hq-stub" \
      bash "$FIX/.claude/hooks/master-hook.sh" SessionStart ) > "$TMP/agent-resume.out" 2> "$TMP/agent-resume.err" \
  || fail "Task SessionStart resume failed: $(cat "$TMP/agent-resume.err")"
[ "$(jq -r '.company_slug' "$AGENT_CAP")" = "indigo" ] \
  || fail "Task SessionStart resume changed the agent binding to $(jq -r '.company_slug' "$AGENT_CAP")"
[ "$(bound company_slug)" = "otherco" ] || fail "Task resume rewrote the shared session metadata"
authz_agent() { # <path> <agent_id> <agent_type> → exit code
  local rc=0
  jq -cn --arg sid "$AGENT_SID" --arg p "$1" --arg cwd "$TMP/linked-repo" --arg aid "$2" --arg atype "$3" \
    '{session_id:$sid,cwd:$cwd,tool_name:"Write",agent_id:$aid,agent_type:$atype,tool_input:{file_path:$p,content:"x"}}' \
    | bash "$FIX/.claude/hooks/mandatory-scope-authorizer.sh" >/dev/null 2>"$TMP/agent-authz.err" || rc=$?
  printf '%s' "$rc"
}
[ "$(authz_agent "$FIX/companies/indigo/knowledge/a.md" agent-a general-purpose)" = "0" ] \
  || fail "subagent tuple did not authorize its company"
[ "$(authz_agent "$FIX/companies/otherco/knowledge/a.md" agent-a general-purpose)" = "2" ] \
  || fail "subagent tuple authorized a different company"
[ "$(authz_agent "$FIX/companies/indigo/knowledge/a.md" '' general-purpose)" = "2" ] \
  || fail "missing-id subagent was not denied"
grep -qi 'restart the session' "$TMP/agent-authz.err" || fail "missing-id denial lacks restart direction"
pass "Task SessionStart mint and authorizer lookup share the caller tuple"

# 7. Claude Code starts an Agent-tool subagent with SubagentStart, never
# SessionStart (feedback_284bc210). The subagent inherits the parent's
# main-thread lock set at spawn, and only that set.
subagent_start() { # <sid> <agent_id> <agent_type>
  jq -cn --arg sid "$1" --arg cwd "$FIX" --arg aid "$2" --arg atype "$3" \
    '{session_id:$sid,cwd:$cwd,hook_event_name:"SubagentStart"}
      + (if $aid == "" then {} else {agent_id:$aid} end)
      + (if $atype == "" then {} else {agent_type:$atype} end)' \
    | ( cd "$FIX" && env HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_DEDUPE=0 HQ_HQ_SESSION_NO_CLI=1 HQ_CLI_BIN="$TMP/bin/hq-stub" \
        bash "$FIX/.claude/hooks/master-hook.sh" SubagentStart ) > "$TMP/substart.out" 2> "$TMP/substart.err" \
    || fail "SubagentStart failed: $(cat "$TMP/substart.err")"
}
authz_as() { # <sid> <path> <agent_id> <agent_type> → exit code
  local rc=0
  jq -cn --arg sid "$1" --arg p "$2" --arg cwd "$FIX" --arg aid "$3" --arg atype "$4" \
    '{session_id:$sid,cwd:$cwd,tool_name:"Write",tool_input:{file_path:$p,content:"x"}}
      + (if $aid == "" then {} else {agent_id:$aid} end)
      + (if $atype == "" then {} else {agent_type:$atype} end)' \
    | bash "$FIX/.claude/hooks/mandatory-scope-authorizer.sh" >/dev/null 2>"$TMP/authz-as.err" || rc=$?
  printf '%s' "$rc"
}

PARENT_SID="parent-sess-subagent"
HQ_HQ_SESSION_NO_CLI=1 bash "$FIX/core/scripts/hq-session.sh" --session-id "$PARENT_SID" set company_slug indigo >/dev/null \
  || fail "could not bind parent session"
[ "$(authz_as "$PARENT_SID" "$FIX/companies/indigo/knowledge/a.md" '' '')" = "0" ] \
  || fail "parent main thread is not authorized for its own company"

# No authorizer call before SubagentStart: the authorizer would pin the tuple
# lazily (#1245) and this case must prove the spawn-time mint on its own.
[ ! -e "$FIX/workspace/sessions/$PARENT_SID/agents/sub-1/scope-capability.json" ] \
  || fail "subagent tuple existed before SubagentStart"

subagent_start "$PARENT_SID" sub-1 Explore
SUB_CAP="$FIX/workspace/sessions/$PARENT_SID/agents/sub-1/scope-capability.json"
[ "$(jq -r '.company_slug' "$SUB_CAP")" = "indigo" ] || fail "SubagentStart did not mint the subagent tuple"
[ "$(jq -r '.agent_id' "$SUB_CAP")" = "sub-1" ] || fail "SubagentStart minted the wrong agent_id"
[ "$(jq -r '.company_slug' "$FIX/workspace/sessions/$PARENT_SID/scope-capability.json")" = "indigo" ] \
  || fail "SubagentStart changed the parent main-thread capability"
[ "$(authz_as "$PARENT_SID" "$FIX/companies/indigo/knowledge/a.md" sub-1 Explore)" = "0" ] \
  || fail "subagent bound by SubagentStart was denied its parent's company: $(cat "$TMP/authz-as.err")"
[ "$(authz_as "$PARENT_SID" "$FIX/companies/otherco/knowledge/a.md" sub-1 Explore)" = "2" ] \
  || fail "subagent bound by SubagentStart was authorized for another company"
pass "SubagentStart binds the subagent to the parent's company only"

# A later parent rebind does not move an agent that is already bound.
HQ_HQ_SESSION_NO_CLI=1 bash "$FIX/core/scripts/hq-session.sh" --session-id "$PARENT_SID" set company_slug otherco >/dev/null \
  || fail "could not rebind parent session"
subagent_start "$PARENT_SID" sub-1 Explore
[ "$(jq -r '.company_slug' "$SUB_CAP")" = "indigo" ] || fail "repeat SubagentStart rebound an existing agent tuple"
# A new subagent inherits the parent's current binding.
subagent_start "$PARENT_SID" sub-2 Explore
[ "$(jq -r '.company_slug' "$FIX/workspace/sessions/$PARENT_SID/agents/sub-2/scope-capability.json")" = "otherco" ] \
  || fail "new subagent did not inherit the parent's current binding"
pass "existing subagent tuples win; new subagents inherit the current parent binding"

# The spawn-time mint and the authorizer's lazy inherit share one source and
# one pin: whichever runs first wins and the other never re-mints.
[ "$(authz_as "$PARENT_SID" "$FIX/companies/otherco/knowledge/a.md" sub-1 Explore)" = "2" ] \
  || fail "authorizer re-minted a subagent pinned at SubagentStart"
[ "$(jq -r '.company_slug' "$SUB_CAP")" = "indigo" ] || fail "authorizer moved a SubagentStart pin"
LAZY_CAP="$FIX/workspace/sessions/$PARENT_SID/agents/sub-lazy/scope-capability.json"
[ "$(authz_as "$PARENT_SID" "$FIX/companies/otherco/knowledge/a.md" sub-lazy Explore)" = "0" ] \
  || fail "lazy inherit did not bind a subagent with no SubagentStart"
HQ_HQ_SESSION_NO_CLI=1 bash "$FIX/core/scripts/hq-session.sh" --session-id "$PARENT_SID" set company_slug indigo >/dev/null \
  || fail "could not rebind parent session"
subagent_start "$PARENT_SID" sub-lazy Explore
[ "$(jq -r '.company_slug' "$LAZY_CAP")" = "otherco" ] || fail "SubagentStart moved a lazily pinned subagent"
HQ_HQ_SESSION_NO_CLI=1 bash "$FIX/core/scripts/hq-session.sh" --session-id "$PARENT_SID" set company_slug otherco >/dev/null \
  || fail "could not restore parent session"
pass "SubagentStart and the authorizer's lazy inherit never re-mint each other's pin"

# Session metadata alone is not a source: a parent whose meta.yaml names a
# company but has no main-thread capability gives its subagent nothing.
META_ONLY_SID="parent-sess-meta-only"
mkdir -p "$FIX/workspace/sessions/$META_ONLY_SID"
printf 'session_id: %s\ncompany_slug: indigo\n' "$META_ONLY_SID" > "$FIX/workspace/sessions/$META_ONLY_SID/meta.yaml"
subagent_start "$META_ONLY_SID" sub-meta Explore
[ ! -e "$FIX/workspace/sessions/$META_ONLY_SID/agents/sub-meta/scope-capability.json" ] \
  || fail "SubagentStart minted a subagent from session metadata"
[ ! -e "$FIX/workspace/sessions/$META_ONLY_SID/scope-capability.json" ] \
  || fail "SubagentStart minted the main-thread capability"
pass "SubagentStart never mints from session metadata"

# An unbound parent gives its subagents nothing.
UNBOUND_SID="parent-sess-unbound"
subagent_start "$UNBOUND_SID" sub-3 Explore
[ ! -f "$FIX/workspace/sessions/$UNBOUND_SID/agents/sub-3/scope-capability.json" ] \
  || fail "subagent of an unbound parent was bound"
[ "$(authz_as "$UNBOUND_SID" "$FIX/companies/indigo/knowledge/a.md" sub-3 Explore)" = "2" ] \
  || fail "subagent of an unbound parent was authorized"
# A SubagentStart with agent_type but no agent_id binds nothing.
subagent_start "$PARENT_SID" '' Explore
[ ! -d "$FIX/workspace/sessions/$PARENT_SID/agents/Explore" ] || fail "agent_type was used as a capability key"
[ "$(jq -r '.company_slug' "$FIX/workspace/sessions/$PARENT_SID/scope-capability.json")" = "otherco" ] \
  || fail "id-less SubagentStart changed the main-thread capability"
pass "unbound parent and id-less SubagentStart stay denied"

echo "master-hook-foreign-bind: all passed"
