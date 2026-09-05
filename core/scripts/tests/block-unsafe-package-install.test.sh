#!/usr/bin/env bash
# hq-core: public
# Regression tests for .claude/hooks/block-unsafe-package-install.sh.
#
# DEV-1798: the hook's emit_block message and header comment used to advertise an
# inline `HQ_ALLOW_UNSAFE_INSTALL=1 <cmd>` command prefix as the bypass. That does
# NOT work: the hook reads HQ_ALLOW_UNSAFE_INSTALL from its OWN process environment
# (not from the parsed command string), so an inline prefix sets the var only in the
# command's subprocess, never reaches the hook, and the block still fires. The docs
# were corrected to the real mechanism (env var via settings.local.json "env" or an
# `export` before launching Claude Code). These tests LOCK that behavior so the docs
# can never drift back to advertising a bypass that doesn't work.

set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/block-unsafe-package-install.sh"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK not found" >&2; exit 1; }

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; fails=$((fails+1)); }

# run_hook <command-string> — feed the hook PreToolUse JSON on stdin from an
# isolated CWD (no .npmrc up the tree) and echo its exit code. HQ_ROOT is pinned
# to a throwaway dir so a bypass audit row never pollutes the real workspace.
run_hook() {
  local cmd="$1" tmp ec json
  tmp="$(mktemp -d)"
  json="$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))')"
  # Run from an isolated CWD with no .npmrc up the tree. `env` forwards the current
  # environment (so a caller-set HQ_ALLOW_UNSAFE_INSTALL reaches the hook) plus a
  # throwaway HQ_ROOT for any audit-row write.
  ( cd "$tmp" && printf '%s' "$json" | env HQ_ROOT="$tmp" bash "$HOOK" >/dev/null 2>&1 )
  ec=$?
  rm -rf "$tmp"
  echo "$ec"
}

# run_hook_with_allow <command-string> — same as run_hook, but the real
# core/scripts/install-deps.allow is copied into the throwaway HQ_ROOT so the
# hook's sanctioned-global-CLI allow-list is active.
ALLOW_SRC="$ROOT/core/scripts/install-deps.allow"
run_hook_with_allow() {
  local cmd="$1" tmp ec json
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/core/scripts"
  cp "$ALLOW_SRC" "$tmp/core/scripts/install-deps.allow"
  json="$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))')"
  ( cd "$tmp" && printf '%s' "$json" | env HQ_ROOT="$tmp" bash "$HOOK" >/dev/null 2>&1 )
  ec=$?
  rm -rf "$tmp"
  echo "$ec"
}

# 1. Baseline: raw `npm install <pkg>` with no gate configured is BLOCKED (exit 2).
ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook 'npm install left-pad')"
[ "$ec" = "2" ] && pass "raw 'npm install left-pad' is blocked (exit 2)" \
                 || fail "raw 'npm install left-pad' should block (exit 2), got $ec"

# 2. THE bug fix: an INLINE 'HQ_ALLOW_UNSAFE_INSTALL=1 <cmd>' prefix does NOT bypass —
#    the var is in the command string, not the hook's env, so the block still fires.
ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook 'HQ_ALLOW_UNSAFE_INSTALL=1 npm install left-pad')"
[ "$ec" = "2" ] && pass "inline HQ_ALLOW_UNSAFE_INSTALL=1 prefix does NOT bypass (still blocked, exit 2)" \
                 || fail "inline prefix must NOT bypass (expected exit 2), got $ec"

# 3. The REAL bypass: HQ_ALLOW_UNSAFE_INSTALL=1 in the hook's ENVIRONMENT allows (exit 0).
ec="$(HQ_ALLOW_UNSAFE_INSTALL=1 run_hook 'npm install left-pad')"
[ "$ec" = "0" ] && pass "env HQ_ALLOW_UNSAFE_INSTALL=1 bypasses (exit 0)" \
                 || fail "env bypass should allow (exit 0), got $ec"

# 4. Lockfile hydration (no positional pkg) is always allowed (exit 0).
ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook 'npm ci')"
[ "$ec" = "0" ] && pass "'npm ci' (lockfile hydration) is allowed (exit 0)" \
                 || fail "'npm ci' should be allowed (exit 0), got $ec"

# 5. Docs guard: neither the hook nor the policy may advertise the inline-prefix
#    form as a working bypass (the exact regression that produced DEV-1798).
POLICY="$ROOT/core/policies/hq-pnpm-min-release-age-supply-chain.md"
if grep -Eq 'HQ_ALLOW_UNSAFE_INSTALL=1[[:space:]]+<(cmd|command)>' "$HOOK"; then
  fail "hook still advertises the inline 'HQ_ALLOW_UNSAFE_INSTALL=1 <cmd>' bypass form"
else
  pass "hook no longer advertises the inline-prefix bypass form"
fi
if grep -Eq '`HQ_ALLOW_UNSAFE_INSTALL=1 <command>`' "$POLICY"; then
  fail "policy still advertises the inline 'HQ_ALLOW_UNSAFE_INSTALL=1 <command>' bypass form"
else
  pass "policy no longer advertises the inline-prefix bypass form"
fi

# 6. Sanctioned global CLI allow-list (core/scripts/install-deps.allow).
[ -f "$ALLOW_SRC" ] && pass "core/scripts/install-deps.allow exists" \
                    || fail "core/scripts/install-deps.allow missing"

allow_case() {  # <expected-ec> <cmd> <label>
  local want="$1" cmd="$2" label="$3" ec
  ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook_with_allow "$cmd")"
  [ "$ec" = "$want" ] && pass "$label (exit $want)" \
                      || fail "$label: expected exit $want, got $ec"
}
allow_case 0 'npm install -g @tobilu/qmd@2.5.3'                 "global exact-pinned qmd is allowed"
allow_case 2 'npm i -g @tobilu/qmd'                             "global UNPINNED qmd is blocked"
allow_case 2 'npm install -g @tobilu/qmd@2.5.2'                 "global qmd with wrong exact pin is blocked"
allow_case 0 'npm install -g @indigoai-us/hq-cli@1.2.3'         "global hq-cli with explicit pin (name@*) is allowed"
# The first-party trusted-scope rule (HQ_TRUSTED_INSTALL_SCOPES, default @indigoai-us)
# allows HQ's own scope even unpinned, so hq-cli@latest passes here by design;
# dist-tags on NON-trusted allow-listed packages must still block.
allow_case 0 'npm install -g @indigoai-us/hq-cli@latest'        "global hq-cli@latest is allowed via the trusted scope"
allow_case 2 'npm install -g @tobilu/qmd@latest'                "global qmd@latest dist-tag is blocked"
allow_case 2 'npm install @tobilu/qmd@2.5.3'                    "NON-global pinned qmd is blocked"
allow_case 2 'npm install -g @tobilu/qmd@2.5.3 left-pad@1.0.0'  "global install with one non-allowed pkg is blocked"

# 7. Missing allow file: behave exactly as before (blocked).
ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook 'npm install -g @tobilu/qmd@2.5.3')"
[ "$ec" = "2" ] && pass "missing allow file still blocks 'npm install -g @tobilu/qmd@2.5.3' (exit 2)" \
                 || fail "missing allow file should block (exit 2), got $ec"

if [ "$fails" -gt 0 ]; then
  echo "block-unsafe-package-install.test.sh: $fails check(s) failed" >&2
  exit 1
fi
echo "block-unsafe-package-install.test.sh: all checks passed"
