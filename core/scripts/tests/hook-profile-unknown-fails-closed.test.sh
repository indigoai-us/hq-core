#!/usr/bin/env bash
# hq-core: public
# Regression: an unknown or misspelled HQ_HOOK_PROFILE must fail closed. Before
# the fix, master-hook.sh printed "Unknown profile" and skipped every gated
# guard, and hook-gate.sh exited 1 (not a block), so HQ_HOOK_PROFILE=bogus let
# a `printenv` dump through. An unknown name now runs as strict, the superset
# tier, and warns once on stderr. Known profiles behave as before.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HOOK="$ROOT/.claude/hooks/block-env-dump.sh"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
MASTER="$ROOT/.claude/hooks/master-hook.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }
for f in "$HOOK" "$GATE" "$MASTER"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hook-profile-unknown.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

payload() {
  jq -nc --arg c "$1" --arg root "$ROOT" \
    '{session_id:"hook-profile-unknown-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,tool_input:{command:$c}}'
}

# Unknown names: a typo, case variants, padded whitespace, a Cyrillic "і"
# lookalike, and a name with a trailing newline.
UNKNOWN_PROFILES=(bogus STRICT Standard " minimal" "minimal " "strіct" $'standard\n' "min")

export CLAUDE_PROJECT_DIR="$ROOT"
export HQ_HOOK_TIMEOUT_SENTRY=0
export HQ_ALLOW_HQ_WORKTREE=1
unset HQ_DISABLED_HOOKS HQ_HOOK_PROFILE_WARNED

label() { printf '%q' "$1"; }

echo "[1] master-hook PreToolUse: unknown profile still blocks printenv"
for p in "${UNKNOWN_PROFILES[@]}"; do
  rc=0
  payload "printenv" | HQ_HOOK_PROFILE="$p" bash "$MASTER" PreToolUse >"$TMP/out" 2>"$TMP/err" || rc=$?
  if [ "$rc" = "2" ] || jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/out" >/dev/null 2>&1; then
    ok "master-hook profile=$(label "$p") blocks printenv (rc=$rc)"
  else
    bad "master-hook profile=$(label "$p") let printenv through (rc=$rc err=$(tr '\n' ' ' < "$TMP/err"))"
  fi
  warn_count="$(grep -c "unknown HQ_HOOK_PROFILE" "$TMP/err" || true)"
  if [ "$warn_count" = "1" ]; then
    ok "master-hook profile=$(label "$p") warns exactly once"
  else
    bad "master-hook profile=$(label "$p") warned $warn_count times"
  fi
  if grep -q "Unknown profile" "$TMP/err"; then
    bad "master-hook profile=$(label "$p") still prints the old skip error"
  else
    ok "master-hook profile=$(label "$p") no longer prints the skip error"
  fi
done

echo "[2] master-hook PreToolUse: unknown profile still allows benign commands"
for p in bogus STRICT; do
  rc=0
  payload "ls" | HQ_HOOK_PROFILE="$p" bash "$MASTER" PreToolUse >/dev/null 2>"$TMP/err" || rc=$?
  [ "$rc" = "0" ] && ok "master-hook profile=$p allows ls" || bad "master-hook profile=$p ls want 0 got $rc"
done

echo "[3] hook-gate: unknown profile runs the guard instead of exiting 1"
for p in "${UNKNOWN_PROFILES[@]}"; do
  rc=0
  payload "printenv" | HQ_HOOK_PROFILE="$p" bash "$GATE" block-env-dump "$HOOK" >/dev/null 2>"$TMP/err" || rc=$?
  [ "$rc" = "2" ] && ok "hook-gate profile=$(label "$p") blocks printenv" \
    || bad "hook-gate profile=$(label "$p") want 2 got $rc err=$(tr '\n' ' ' < "$TMP/err")"
  grep -q "unknown HQ_HOOK_PROFILE" "$TMP/err" && ok "hook-gate profile=$(label "$p") warns" \
    || bad "hook-gate profile=$(label "$p") did not warn"
done

echo "[4] known and empty profiles behave as before"
for p in minimal standard strict ""; do
  for case_spec in "printenv:2" "ls:0"; do
    cmd="${case_spec%:*}"; want="${case_spec##*:}"
    rc=0
    payload "$cmd" | HQ_HOOK_PROFILE="$p" bash "$MASTER" PreToolUse >/dev/null 2>"$TMP/err" || rc=$?
    [ "$rc" = "$want" ] && ok "master-hook profile=$(label "$p") $cmd rc=$rc" \
      || bad "master-hook profile=$(label "$p") $cmd want $want got $rc"
    if grep -q "unknown HQ_HOOK_PROFILE" "$TMP/err"; then
      bad "master-hook profile=$(label "$p") warned for a known profile"
    fi
  done
done

echo "[5] library: unknown profile resolves to the strict tier"
# shellcheck disable=SC1090
. "$GATE" --lib
strict_only=""
for id in auto-checkpoint-trigger hq-autocommit session-title check-hq-update; do
  if is_in_strict_profile "$id" && ! is_in_minimal_profile "$id"; then strict_only="$id"; break; fi
done
if [ -z "$strict_only" ]; then
  bad "could not find a strict-only hook id for the library check"
else
  for p in bogus "" minimal; do
    unset HQ_HOOK_PROFILE_WARNED
    rc=0; HQ_HOOK_PROFILE="$p" hq_hook_profile_allows "$strict_only" 2>/dev/null || rc=$?
    case "$p" in
      bogus) want=0 ;;
      minimal) want=1 ;;
      *) if is_in_standard_profile "$strict_only"; then want=0; else want=1; fi ;;
    esac
    [ "$rc" = "$want" ] && ok "hq_hook_profile_allows $strict_only profile=$(label "$p") rc=$rc" \
      || bad "hq_hook_profile_allows $strict_only profile=$(label "$p") want $want got $rc"
  done
  unset HQ_HOOK_PROFILE_WARNED
  rc=0; HQ_HOOK_PROFILE=bogus HQ_DISABLED_HOOKS="$strict_only" hq_hook_profile_allows "$strict_only" 2>/dev/null || rc=$?
  [ "$rc" = "1" ] && ok "HQ_DISABLED_HOOKS still disables a hook under an unknown profile" \
    || bad "HQ_DISABLED_HOOKS under unknown profile want 1 got $rc"
fi

echo
echo "hook-profile-unknown-fails-closed: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
