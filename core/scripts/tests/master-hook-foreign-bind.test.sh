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
start_session() { # <cwd> <cli-bin> → sets SID, OUT, ERR
  N=$((N + 1))
  SID="foreign-sess-$N"
  OUT="$TMP/out.$N"; ERR="$TMP/err.$N"
  jq -cn --arg sid "$SID" --arg cwd "$1" \
    '{session_id:$sid, cwd:$cwd, hook_event_name:"SessionStart", source:"startup"}' \
    | ( cd "$1" && env HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HQ_SESSION_NO_CLI=1 HQ_CLI_BIN="$2" HQ_FLAG_CLI_BIN="$TMP/bin/hq-stub" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG=true \
        bash "$FIX/.claude/hooks/master-hook.sh" SessionStart ) >"$OUT" 2>"$ERR" \
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

# 2b. A later SessionStart (resume) for the bound session does not repeat the hint.
jq -cn --arg sid "$SID" --arg cwd "$TMP/plain-folder" '{session_id:$sid, cwd:$cwd, source:"resume"}' \
  | ( cd "$TMP/plain-folder" && env HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_DEDUPE=0 HQ_HQ_SESSION_NO_CLI=1 HQ_CLI_BIN="$TMP/bin/hq-stub" \
      bash "$FIX/.claude/hooks/master-hook.sh" SessionStart ) > "$TMP/resume.out" 2>/dev/null
if grep -q 'hq link' "$TMP/resume.out"; then fail "resume repeated the link hint"; fi
pass "resume does not repeat the hint"

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

echo "master-hook-foreign-bind: all passed"
