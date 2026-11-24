#!/usr/bin/env bash
# hq-core: public
# hq-session-concurrent-sessions.test.sh
#
# `hq-session.sh set` without --session-id must write only the calling
# session's record, or refuse with a clear message when it cannot tell which
# session is calling. Every case runs with two or more live sessions, and
# workspace/sessions/.current names a session other than the caller.
#
#   1. The environment names two sessions (a stale HQ_SESSION_ID inherited from
#      the shell that launched the host, next to the host's own
#      CLAUDE_CODE_SESSION_ID): refuse, name both, write nothing.
#   2. Variables that legitimately differ are not a conflict: the legacy
#      CLAUDE_SESSION_ID, CODEX_THREAD_ID next to CODEX_SESSION_ID, and a Fleet
#      job's HQ_FLEET_SESSION_ID next to the harness id.
#   3. The host kept exporting an old id after the conversation moved to a new
#      one. master-hook sees both and records the alias; set refuses the stale
#      id and names the payload id. A second, healthy session is unaffected.
#      --session-id with the payload id binds it. The alias expires after the
#      TTL once the stale process stops firing hooks.
#   4. The CLI-hosted copy gets the resolved id as --session-id, so an older
#      bundle that still falls back to .current cannot pick another session.
#   5. A successful env-resolved write says which session it targeted.
set -euo pipefail
export HQ_HOOK_DEDUPE=0 HQ_HOOK_PARALLEL=0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
FIX="$TMP/hq"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/hooks" "$FIX/core/scripts/lib" \
  "$FIX/workspace/sessions" "$FIX/companies/acme/settings" "$FIX/personal" "$TMP/home" "$TMP/bin"
cp "$ROOT/.claude/hooks/master-hook.sh" "$ROOT/.claude/hooks/hook-timeout-probe.sh" \
  "$ROOT/.claude/hooks/hook-gate.sh" "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" \
  "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$ROOT/.claude/hooks/path-fold-lib.sh" "$FIX/.claude/hooks/"
cp "$ROOT/core/scripts/resolve-hq-root.sh" "$ROOT/core/scripts/hq-session.sh" \
  "$ROOT/core/scripts/hook-lib.sh" "$FIX/core/scripts/"
cp -R "$ROOT/core/scripts/lib/." "$FIX/core/scripts/lib/"
printf 'companies:\n  acme:\n    name: Acme\n' > "$FIX/companies/manifest.yaml"
touch "$FIX/companies/acme/settings/.keep"
HS="$FIX/core/scripts/hq-session.sh"
SESS="$FIX/workspace/sessions"

seed() { # <id>...
  local id
  for id in "$@"; do
    rm -rf "${SESS:?}/$id"
    mkdir -p "$SESS/$id"
    printf 'session_id: %s\nsenior: user\n' "$id" > "$SESS/$id/meta.yaml"
  done
}
bound() { awk '$1 == "company_slug:" { print $2; exit }' "$SESS/$1/meta.yaml" 2>/dev/null; }
assert_unbound() { local id; for id in "$@"; do [ -z "$(bound "$id")" ] || fail "$id was bound: $(cat "$SESS/$id/meta.yaml")"; done; }

# A shell or hook process: no inherited session ids, isolated root and home.
clean_env() {
  env -u HQ_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
    -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID -u HQ_FLEET_SESSION_ID \
    -u HQ_HOOK_SESSION_ID -u HQ_HOOK_TOOL_NAME -u HQ_HOOK_CWD -u HQ_HOOK_COMMAND \
    -u CURSOR_AGENT -u CURSOR_TRACE_ID \
    HOME="$TMP/home" HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" HQ_HQ_SESSION_NO_CLI=1 \
    HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_DEDUPE=0 "$@"
}
hs() { # [VAR=val...] -- args ; sets rc, leaves $TMP/out and $TMP/err
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  rc=0
  clean_env ${envs[@]+"${envs[@]}"} bash "$HS" "$@" >"$TMP/out" 2>"$TMP/err" || rc=$?
}

# ── 1. Two ids in the environment ────────────────────────────────────────
seed sess-a sess-b
printf 'sess-a\n' > "$SESS/.current"
hs HQ_SESSION_ID=sess-a CLAUDE_CODE_SESSION_ID=sess-b -- set company_slug acme
[ "$rc" -ne 0 ] || fail "two ids: set succeeded: $(cat "$TMP/err")"
grep -q 'more than one session' "$TMP/err" || fail "two ids: unclear message: $(cat "$TMP/err")"
grep -q 'HQ_SESSION_ID=sess-a' "$TMP/err" && grep -q 'CLAUDE_CODE_SESSION_ID=sess-b' "$TMP/err" \
  || fail "two ids: message must name both: $(cat "$TMP/err")"
assert_unbound sess-a sess-b
for args in 'add company acme' 'remove company acme' 'set senior user'; do
  # shellcheck disable=SC2086
  hs HQ_SESSION_ID=sess-a CLAUDE_CODE_SESSION_ID=sess-b -- $args
  [ "$rc" -ne 0 ] || fail "two ids: '$args' succeeded"
done
assert_unbound sess-a sess-b
# The same id in two variables is one session.
hs HQ_SESSION_ID=sess-b CLAUDE_CODE_SESSION_ID=sess-b -- set company_slug acme
[ "$rc" -eq 0 ] || fail "same id twice refused: $(cat "$TMP/err")"
[ "$(bound sess-b)" = acme ] || fail "same id twice: sess-b not bound"
assert_unbound sess-a
pass "two session ids in the environment: refused, both named, nothing written"

# ── 2. Variables that legitimately differ ────────────────────────────────
seed sess-a sess-b sess-c sess-d
hs CLAUDE_CODE_SESSION_ID=sess-b CLAUDE_SESSION_ID=sess-a -- set company_slug acme
[ "$rc" -eq 0 ] && [ "$(bound sess-b)" = acme ] || fail "legacy CLAUDE_SESSION_ID: $(cat "$TMP/err")"
hs CODEX_SESSION_ID=sess-c CODEX_THREAD_ID=sess-a -- set company_slug acme
[ "$rc" -eq 0 ] && [ "$(bound sess-c)" = acme ] || fail "codex thread id: $(cat "$TMP/err")"
hs CLAUDE_CODE_SESSION_ID=sess-d HQ_FLEET_SESSION_ID=sess-a -- set company_slug acme
[ "$rc" -eq 0 ] && [ "$(bound sess-d)" = acme ] || fail "fleet + harness: $(cat "$TMP/err")"
assert_unbound sess-a
pass "same-harness pairs and Fleet fallback target the harness id"

# ── 3. Stale host id seen by master-hook ─────────────────────────────────
seed sess-old sess-new sess-c
printf 'sess-c\n' > "$SESS/.current"
post_payload() { jq -cn --arg s "$1" --arg d "$FIX" \
  '{session_id:$s, hook_event_name:"PostToolUse", cwd:$d, tool_name:"Read", tool_input:{file_path:"/dev/null"}, tool_response:{}}'; }
run_hook() { # <env-id> <payload-id>
  post_payload "$2" | clean_env CLAUDE_CODE_SESSION_ID="$1" bash "$FIX/.claude/hooks/master-hook.sh" PostToolUse \
    >"$TMP/hook.out" 2>"$TMP/hook.err" || fail "master-hook failed: $(cat "$TMP/hook.err")"
}
ENVIDS="$SESS/.env-ids"
rm -rf "${SESS:?}/sess-old"  # the stale id's own record need not exist
run_hook sess-old sess-old   # the conversation that really was sess-old, earlier
sleep 1
run_hook sess-old sess-new   # the same environment, now a new conversation
run_hook sess-c sess-c       # a healthy concurrent session
[ -f "$ENVIDS/sess-old/sess-new" ] || fail "master-hook did not record the stale alias"
[ -z "$(find "$ENVIDS/sess-c" -type f ! -name sess-c)" ] || fail "healthy session got an alias"
for id in sess-old sess-c; do
  [ ! -e "$SESS/$id/env-aliases" ] || fail "alias written into $id's session record"
done
hs CLAUDE_CODE_SESSION_ID=sess-old -- set company_slug acme
[ "$rc" -ne 0 ] || fail "stale id: set succeeded"
grep -q 'CLAUDE_CODE_SESSION_ID=sess-old is stale' "$TMP/err" && grep -q 'sess-new' "$TMP/err" \
  || fail "stale id: message must name the stale and payload ids: $(cat "$TMP/err")"
assert_unbound sess-old sess-new sess-c
hs CLAUDE_CODE_SESSION_ID=sess-c -- set company_slug acme
[ "$rc" -eq 0 ] && [ "$(bound sess-c)" = acme ] || fail "healthy session refused: $(cat "$TMP/err")"
assert_unbound sess-old sess-new
hs CLAUDE_CODE_SESSION_ID=sess-old -- --session-id sess-new set company_slug acme
[ "$rc" -eq 0 ] && [ "$(bound sess-new)" = acme ] || fail "explicit payload id refused: $(cat "$TMP/err")"
assert_unbound sess-old
# The alias lapses once the stale process has fired no hook for the TTL.
touch -t 202001010000 "$ENVIDS/sess-old/sess-new"
hs CLAUDE_CODE_SESSION_ID=sess-old SESSION_ID_ENV_ALIAS_TTL_MIN=60 -- set senior user
[ "$rc" -eq 0 ] || fail "expired alias still refused: $(cat "$TMP/err")"
pass "stale host id: refused with the payload id named; healthy and explicit writes still bind"

# ── 3b. A run started inside a live session inherits its id ──────────────
# The child's hooks see the parent's id in the environment and the child's id
# in the payload. They must not create or touch the parent's session record.
# While the parent keeps firing hooks after the child, the parent's own
# env-resolved writes still bind; after the child fires again, a write from
# that environment could belong to either, so it is refused.
seed parent child
run_hook parent parent
sleep 1
touch "$TMP/parent-stamp"
sleep 1
run_hook parent child
[ -z "$(find "$SESS/parent" -newer "$TMP/parent-stamp" 2>/dev/null)" ] \
  || fail "child hook changed the parent's session record: $(find "$SESS/parent" -newer "$TMP/parent-stamp")"
[ ! -e "$SESS/parent/env-aliases" ] || fail "child hook wrote into the parent's session record"
hs CLAUDE_CODE_SESSION_ID=parent -- set company_slug acme
[ "$rc" -ne 0 ] || fail "ambiguous parent/child environment: write was not refused"
assert_unbound parent child
sleep 1
run_hook parent parent
hs CLAUDE_CODE_SESSION_ID=parent -- set company_slug acme
[ "$rc" -eq 0 ] && [ "$(bound parent)" = acme ] || fail "live parent refused after its own hook: $(cat "$TMP/err")"
assert_unbound child
pass "inherited id: no write into the parent's record; ambiguous writes refused, the live parent still binds"

# ── 4. CLI forwarding carries the resolved id ────────────────────────────
seed fleet-1 foreign
printf 'foreign\n' > "$SESS/.current"
cat > "$TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HQ_TEST_CLI_CALLS"
STUB
chmod +x "$TMP/bin/hq"
printf 'hq-session exact-company-directory-match-v1\n' > "$TMP/caps"
hs PATH="$TMP/bin:$PATH" HQ_HQ_SESSION_NO_CLI=0 HQ_CLI_CAPS_CACHE="$TMP/caps" \
   HQ_TEST_CLI_CALLS="$TMP/cli-calls" HQ_FLEET_SESSION_ID=fleet-1 -- set company_slug acme
[ "$rc" -eq 0 ] || fail "cli forward: $(cat "$TMP/err")"
[ "$(cat "$TMP/cli-calls")" = 'core hq-session --session-id fleet-1 set company_slug acme' ] \
  || fail "cli forward args: $(cat "$TMP/cli-calls")"
rm -f "$TMP/cli-calls"
hs PATH="$TMP/bin:$PATH" HQ_HQ_SESSION_NO_CLI=0 HQ_CLI_CAPS_CACHE="$TMP/caps" \
   HQ_TEST_CLI_CALLS="$TMP/cli-calls" HQ_SESSION_ID=foreign CLAUDE_CODE_SESSION_ID=fleet-1 -- set company_slug acme
[ "$rc" -ne 0 ] && [ ! -e "$TMP/cli-calls" ] || fail "cli forward: conflicting ids reached the CLI"
pass "CLI-hosted copy receives --session-id; conflicts never reach it"

# ── 5. Successful write names its target ─────────────────────────────────
seed sess-e
hs CLAUDE_CODE_SESSION_ID=sess-e -- set company_slug acme
[ "$rc" -eq 0 ] || fail "named target: $(cat "$TMP/err")"
grep -q 'writing to session sess-e (from CLAUDE_CODE_SESSION_ID)' "$TMP/err" \
  || fail "write did not name its target: $(cat "$TMP/err")"
pass "env-resolved write names the session it targets"

echo "PASS: hq-session.sh set without --session-id targets only the calling session or refuses"
