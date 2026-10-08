#!/usr/bin/env bash
# Tests for core/scripts/resolve-hq-root.sh and master-hook.sh foreign-cwd handling.
# shellcheck disable=SC2034 # REPO_ROOT/PAYLOAD_CWD are read by master_cwd_kind via eval.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RESOLVER="$ROOT/core/scripts/resolve-hq-root.sh"
MASTER="$ROOT/.claude/hooks/master-hook.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FOREIGN="$TMP/foreign-repo"
mkdir -p "$FOREIGN" "$TMP/home-empty" "$TMP/home-ptr/.hq"
printf '%s\n' "$ROOT" > "$TMP/home-ptr/.hq/root"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

# 1. Unresolvable: exit 3, exactly one reason line.
set +e
err="$(cd "$FOREIGN" && HOME="$TMP/home-empty" env -u HQ_ROOT bash "$RESOLVER" 2>&1 >/dev/null)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "expected exit 3, got $rc"
[ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" = 1 ] || fail "expected one reason line, got: $err"
pass "unresolved exits 3 with one reason line"

# 2. HQ_ROOT env wins.
out="$(cd "$FOREIGN" && HOME="$TMP/home-empty" HQ_ROOT="$ROOT" bash "$RESOLVER")"
[ "$out" = "$ROOT" ] || fail "HQ_ROOT not honoured: $out"
pass "HQ_ROOT env resolves"

# The unconditional master-hook resolver must match the old script-dir root
# calculation when the session cwd is the HQ root.
old_root="$(cd "$ROOT/.claude/hooks/../.." && pwd)"
new_root="$(cd "$ROOT" && HQ_ROOT= HOME="$TMP/home-empty" bash "$RESOLVER")"
[ "$new_root" = "$old_root" ] || fail "HQ-root resolver changed the old root ($new_root != $old_root)"
pass "HQ-root cwd resolves exactly to the former master-hook root"

# 3. Pointer file.
out="$(cd "$FOREIGN" && HOME="$TMP/home-ptr" env -u HQ_ROOT bash "$RESOLVER")"
[ "$out" = "$ROOT" ] || fail "pointer file not honoured: $out"
pass "home pointer file resolves"

# 4. Walk-up from a subdirectory.
out="$(cd "$ROOT/core/scripts" && HOME="$TMP/home-empty" env -u HQ_ROOT bash "$RESOLVER")"
[ "$out" = "$ROOT" ] || fail "walk-up failed: $out"
pass "walk-up from cwd resolves"

# 5. CLAUDE_PROJECT_DIR is ignored.
set +e
(cd "$FOREIGN" && HOME="$TMP/home-empty" CLAUDE_PROJECT_DIR="$ROOT" env -u HQ_ROOT bash "$RESOLVER" >/dev/null 2>&1)
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "CLAUDE_PROJECT_DIR should not resolve, rc=$rc"
pass "CLAUDE_PROJECT_DIR is not consulted"

# 6. master_cwd_kind classifies a foreign cwd as foreign.
fn="$(sed -n '/^master_cwd_kind() {/,/^}/p' "$MASTER")"
[ -n "$fn" ] || fail "master_cwd_kind not found"
eval "$fn"
PAYLOAD_CWD=""
REPO_ROOT="$ROOT"
PAYLOAD_CWD="$FOREIGN"; [ "$(master_cwd_kind)" = foreign ] || fail "foreign cwd misclassified"
PAYLOAD_CWD=""; [ "$(master_cwd_kind)" = other ] || fail "empty cwd should stay other"
PAYLOAD_CWD="$ROOT"; [ "$(master_cwd_kind)" = hq-root ] || fail "hq root misclassified"
PAYLOAD_CWD="$ROOT/companies/x"; [ "$(master_cwd_kind)" = other ] || fail "in-HQ cwd should be other"
pass "master_cwd_kind reports foreign for out-of-HQ cwd"

# 7. master-hook runs from a foreign cwd with HQ_ROOT set and does not crash.
payload="$(jq -cn --arg cwd "$FOREIGN" '{hook_event_name:"SessionStart",session_id:"resolve-hq-root-test",cwd:$cwd,source:"startup"}')"
set +e
(cd "$FOREIGN" && HQ_ROOT="$ROOT" HOME="$TMP/home-ptr" HQ_HOOK_PROFILE=minimal \
  bash "$MASTER" SessionStart <<<"$payload" >/dev/null 2>"$TMP/master.err")
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "master-hook exited $rc from foreign cwd: $(head -5 "$TMP/master.err")"
pass "master-hook runs from foreign cwd without crashing"

# 8. With no hq-flags configuration, the default-on fail-safe keeps the hook
# path on; the resolver binds personal, never a company.
payload="$(jq -cn --arg cwd "$FOREIGN" '{hook_event_name:"SessionStart",session_id:"resolve-hq-root-flag-on",cwd:$cwd,source:"startup"}')"
set +e
(cd "$FOREIGN" && env -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID HQ_ROOT="$ROOT" HOME="$TMP/home-ptr" HQ_HOOK_PROFILE=minimal \
  bash "$MASTER" SessionStart <<<"$payload" >"$TMP/flag-on.out" 2>"$TMP/flag-on.err")
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "default-on master-hook exited $rc"
[ "$(HQ_ROOT="$ROOT" bash "$ROOT/core/scripts/hq-session.sh" --session-id resolve-hq-root-flag-on get company_slug 2>/dev/null)" = "personal" ] || fail "default-on master-hook did not bind the foreign session to personal"
pass "missing hq-flags configuration keeps foreign bind on and binds personal"

# 8b. The explicit local kill switch keeps the old off behavior covered.
payload="$(jq -cn --arg cwd "$FOREIGN" '{hook_event_name:"SessionStart",session_id:"resolve-hq-root-local-off",cwd:$cwd,source:"startup"}')"
set +e
(cd "$FOREIGN" && env -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID HQ_FLAG_HQ_ANYWHERE_RUNTIME=0 HQ_ROOT="$ROOT" HOME="$TMP/home-ptr" HQ_HOOK_PROFILE=minimal \
  bash "$MASTER" SessionStart <<<"$payload" >"$TMP/local-off.out" 2>"$TMP/local-off.err")
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "local-kill-switch master-hook exited $rc"
[ -z "$(HQ_ROOT="$ROOT" bash "$ROOT/core/scripts/hq-session.sh" --session-id resolve-hq-root-local-off get company_slug 2>/dev/null)" ] || fail "local-kill-switch master-hook bound a foreign session"
pass "local kill switch keeps foreign bind off"

echo "PASS: resolve-hq-root"
