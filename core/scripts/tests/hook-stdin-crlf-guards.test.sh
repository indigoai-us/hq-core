#!/usr/bin/env bash
# Three Bash guards read the command straight from the stdin payload with jq:
# enforce-vault-write-access, block-on-active-run and
# mandatory-scope-authorizer. Native Windows jq.exe writes stdout in text mode,
# so every LF inside the command comes back as CRLF. Without hq_crlf_to_lf the
# word before each line break kept a trailing CR: `cd "<HQ>"` became a cd to
# "<HQ>\r", outside HQ, and a final path operand such as
# companies/acme/reports/locked no longer matched its own grant. Bash itself
# runs the LF command, so the core-writes, vault and active-run cases below
# were allowed while the real command wrote to a protected path. The scope
# authorizer splits words on any whitespace, CR included, so no CRLF bypass
# was found there; its cases keep the normalized command blocked the same way.
#
# On macOS and Linux a jq wrapper reproduces jq.exe for the command field
# only: interior LFs become CRLF, and the final LF stays bare as Git Bash
# command substitution leaves it. On Windows the real jq.exe is used.
#
# Explicitly wired into .github/workflows/pr-checks.yml.
set -uo pipefail
TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required for this suite"; exit 0; }

TMP="$(mktemp -d)"
OWNER_PID=""
cleanup() {
  if [ -n "$OWNER_PID" ]; then
    kill "$OWNER_PID" 2>/dev/null
    wait "$OWNER_PID" 2>/dev/null
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
TMP="$(cd "$TMP" && pwd -P)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

REAL_JQ="$(command -v jq)"
NATIVE_CRLF=0
if [[ "$(printf '"a\\nb"' | jq -j . | od -An -c | tr -d ' \n')" == 'a\r\nb' ]]; then
  NATIVE_CRLF=1
fi
mkdir -p "$TMP/crlf-jq-bin"
cat > "$TMP/crlf-jq-bin/jq" <<'JQ'
#!/usr/bin/env bash
case "$*" in
  *tool_input.command*)
    "${HQ_TEST_REAL_JQ:?}" "$@" | perl -0777 -pe 's/\n(?!\z)/\r\n/g'
    ;;
  *) exec "${HQ_TEST_REAL_JQ:?}" "$@" ;;
esac
JQ
chmod +x "$TMP/crlf-jq-bin/jq"
if ((NATIVE_CRLF)); then
  CRLF_PATH="$PATH"
  printf 'jq writes CRLF natively; using the real jq\n'
else
  CRLF_PATH="$TMP/crlf-jq-bin:$PATH"
fi

sample="$(printf '%s' '{"tool_input":{"command":"a\nb"}}' \
  | HQ_TEST_REAL_JQ="$REAL_JQ" PATH="$CRLF_PATH" jq -r '.tool_input.command // empty' | od -An -c | tr -d ' \n')"
if [[ "$sample" == 'a\r\nb\n' || "$sample" == 'a\r\nb\r\n' ]]; then
  pass "simulated jq output turns the command's LF into CRLF"
else
  fail "simulated jq output is not CRLF ($sample)"
fi

# check <label> <mode> <expected rc> <rc> <stderr file>
check() {
  local label="$1" mode="$2" want="$3" got="$4" err="$5"
  if [[ "$got" == "$want" ]]; then
    pass "$label ($mode): exit $got"
  else
    fail "$label ($mode): expected exit $want, got $got; stderr=$(head -c 300 "$err" 2>/dev/null)"
  fi
}

# block-core-writes-bash is not covered here. Its CRLF fix was dropped from
# this PR because merged-write-guard-shadow.test.sh fails any PR that edits
# that legacy guard; it needs its own follow-up.

# ── enforce-vault-write-access ──────────────────────────────────────────────
VW="$TMP/vault"
mkdir -p "$VW/.claude/hooks" "$VW/.hq" "$VW/core/scripts" "$VW/companies/acme/reports/locked"
cp "$ROOT/core/scripts/hook-lib.sh" "$VW/core/scripts/"
cp "$ROOT/.claude/hooks/enforce-vault-write-access.sh" "$VW/.claude/hooks/"
cp "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$VW/.claude/hooks/"
printf '{}' > "$VW/.claude/settings.local.json"
cat > "$VW/.hq/vault-access.json" <<'EOF'
{
  "version": 1,
  "companies": {
    "acme": {
      "role": "member",
      "enforced": true,
      "grants": [
        { "path": "reports/*", "permission": "write" },
        { "path": "reports/locked/*", "permission": "read" }
      ]
    }
  }
}
EOF
run_vault() { # <mode> <command>
  local mode="$1" rc=0 path="$PATH"
  [[ "$mode" == crlf ]] && path="$CRLF_PATH"
  jq -n --arg cmd "$2" '{tool_name:"Bash",tool_input:{command:$cmd}}' | (
    cd "$VW"
    HQ_TEST_REAL_JQ="$REAL_JQ" PATH="$path" CLAUDE_PROJECT_DIR="$VW" \
      bash "$VW/.claude/hooks/enforce-vault-write-access.sh" > /dev/null 2> "$TMP/vw.err"
  ) || rc=$?
  printf '%s' "$rc"
}
for mode in lf crlf; do
  # reports/locked/* is read-only and covers the bare directory. With a CR the
  # operand became reports/locked<CR>, which only reports/* (write) matched.
  check "rm -rf a read-only vault dir, then newline" "$mode" 2 \
    "$(run_vault "$mode" "rm -rf companies/acme/reports/locked"$'\n'"true")" "$TMP/vw.err"
  check "allowed write under reports/ stays allowed" "$mode" 0 \
    "$(run_vault "$mode" "touch companies/acme/reports/a.md"$'\n'"true")" "$TMP/vw.err"
done

# ── block-on-active-run ─────────────────────────────────────────────────────
AR="$TMP/active-run"
mkdir -p "$AR/.claude/hooks" "$AR/core/scripts/lib" "$AR/workspace" "$AR/repos/private/app/src"
cp "$ROOT/.claude/hooks/block-on-active-run.sh" "$AR/.claude/hooks/"
cp "$ROOT/core/scripts/repo-run-registry.sh" "$ROOT/core/scripts/hook-lib.sh" "$AR/core/scripts/"
cp "$ROOT/core/scripts/lib/portable.sh" "$AR/core/scripts/lib/"
git -C "$AR/repos/private/app" init -q
sleep 600 &
OWNER_PID=$!
HQ_ROOT="$AR" "$AR/core/scripts/repo-run-registry.sh" register --run-id foreign-run --pid "$OWNER_PID" \
  --session-id other-session --command /run-project --project demo --repo "$AR/repos/private/app" \
  --scope repo > /dev/null 2>&1 || fail "register a foreign run"
run_active() { # <mode> <command>
  local mode="$1" rc=0 path="$PATH"
  [[ "$mode" == crlf ]] && path="$CRLF_PATH"
  jq -nc --arg cmd "$2" '{tool_name:"Bash",session_id:"mine",tool_input:{command:$cmd}}' | (
    cd "$AR"
    env -u BASH_ENV -u HQ_IGNORE_ACTIVE_RUNS HQ_TEST_REAL_JQ="$REAL_JQ" PATH="$path" \
      HQ_ROOT="$AR" CLAUDE_PROJECT_DIR="$AR" \
      bash "$AR/.claude/hooks/block-on-active-run.sh" > /dev/null 2> "$TMP/ar.err"
  ) || rc=$?
  printf '%s' "$rc"
}
for mode in lf crlf; do
  check "rm -rf a repo another session is running in, then newline" "$mode" 2 \
    "$(run_active "$mode" "rm -rf $AR/repos/private/app"$'\n'"true")" "$TMP/ar.err"
done

# ── mandatory-scope-authorizer ──────────────────────────────────────────────
SA="$TMP/scope"
mkdir -p "$SA/.claude/hooks" "$SA/core/scripts/lib" "$SA/.codex/hooks" \
  "$SA/companies/example-co/settings" "$SA/companies/otherco/settings" \
  "$SA/workspace/sessions/sess-bound" "$SA/home/.hq"
cp "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$SA/.claude/hooks/"
cp "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$SA/.claude/hooks/"
cp "$ROOT/core/scripts/lib/session-authz.sh" "$ROOT/core/scripts/lib/session-scope-capability.sh" \
  "$ROOT/core/scripts/lib/hook-caller-lineage.sh" "$ROOT/core/scripts/lib/session-id.sh" \
  "$SA/core/scripts/lib/"
cp "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$ROOT/core/scripts/hook-lib.sh" "$SA/core/scripts/"
cp "$ROOT/.codex/hooks/codex-explicit-path-flag.cjs" "$SA/.codex/hooks/"
printf 'companies:\n  example-co:\n    name: example-co\n  otherco:\n    name: otherco\n' > "$SA/companies/manifest.yaml"
touch "$SA/companies/example-co/settings/.keep" "$SA/companies/otherco/settings/secret.yaml"
printf 'sess-bound\n' > "$SA/workspace/sessions/.current"
printf 'company_slug: example-co\n' > "$SA/workspace/sessions/sess-bound/meta.yaml"
(
  export HOME="$SA/home"
  . "$ROOT/core/scripts/lib/session-scope-capability.sh"
  session_scope_mint "$SA" sess-bound example-co
) || fail "mint the example-co session scope"
run_scope() { # <mode> <command>
  local mode="$1" rc=0 path="$PATH"
  [[ "$mode" == crlf ]] && path="$CRLF_PATH"
  jq -nc --arg cmd "$2" --arg cwd "$SA" \
    '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$cmd}}' | (
    cd "$SA"
    HOME="$SA/home" HQ_TEST_REAL_JQ="$REAL_JQ" PATH="$path" CLAUDE_PROJECT_DIR="$SA" \
      bash "$SA/.claude/hooks/mandatory-scope-authorizer.sh" > /dev/null 2> "$TMP/sa.err"
  ) || rc=$?
  printf '%s' "$rc"
}
for mode in lf crlf; do
  check "list another company's directory, then newline" "$mode" 2 \
    "$(run_scope "$mode" "ls $SA/companies/otherco"$'\n'"true")" "$TMP/sa.err"
  check "copy from another company's settings, then newline" "$mode" 2 \
    "$(run_scope "$mode" "cd $SA/companies/otherco"$'\n'"cat settings/secret.yaml")" "$TMP/sa.err"
  check "own company stays allowed" "$mode" 0 \
    "$(run_scope "$mode" "ls $SA/companies/example-co/settings"$'\n'"true")" "$TMP/sa.err"
done

if ((FAIL)); then
  printf 'hook-stdin-crlf-guards: %s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf 'hook-stdin-crlf-guards: %s passed, 0 failed\n' "$PASS"
