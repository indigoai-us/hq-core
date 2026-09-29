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
HOOK="${HQ_TEST_BLOCK_UNSAFE_PACKAGE_INSTALL_HOOK:-$ROOT/.claude/hooks/block-unsafe-package-install.sh}"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK not found" >&2; exit 1; }

# The cross-version parity suite wraps Bash via PATH. Preserve only its
# instrumentation variables when the hook cases below deliberately use env -i.
PARITY_ENV_ARGS=()
for parity_var in HQ_PARITY_REAL_BASH HQ_PARITY_RECORD_ROOT \
  HQ_PARITY_UNSAFE_BASE_HOOK HQ_PARITY_UNSAFE_CANDIDATE_HOOK \
  HQ_PARITY_CORE_BASE_HOOK HQ_PARITY_CORE_CANDIDATE_HOOK; do
  if [[ -n "${!parity_var:-}" ]]; then
    PARITY_ENV_ARGS+=("$parity_var=${!parity_var}")
  fi
done

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
  # Run with an isolated CWD and only the bypass flag preserved from the caller.
  # Release-age variables must not make command-line cases pass accidentally.
  ( cd "$tmp" && printf '%s' "$json" | env -i PATH="$PATH" HQ_ROOT="$tmp" HQ_ALLOW_UNSAFE_INSTALL="${HQ_ALLOW_UNSAFE_INSTALL:-0}" "${PARITY_ENV_ARGS[@]}" bash "$HOOK" >/dev/null 2>&1 )
  ec=$?
  rm -rf "$tmp"
  echo "$ec"
}

# run_hook_with_env <name> <value> <command-string> — isolate the hook
# environment so each release-age alias is checked independently.
run_hook_with_env() {
  local name="$1" value="$2" cmd="$3" tmp ec json
  tmp="$(mktemp -d)"
  json="$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))')"
  ( cd "$tmp" && printf '%s' "$json" | env -i PATH="$PATH" HQ_ROOT="$tmp" "$name=$value" "${PARITY_ENV_ARGS[@]}" bash "$HOOK" >/dev/null 2>&1 )
  ec=$?
  rm -rf "$tmp"
  echo "$ec"
}

# run_hook_with_repo_config <filename> <line> <command-string> — isolate the
# working directory and put one package-manager config value in its repo root.
run_hook_with_repo_config() {
  local filename="$1" line="$2" cmd="$3" tmp ec json
  tmp="$(mktemp -d)"
  printf '%s\n' "$line" > "$tmp/$filename"
  json="$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))')"
  ( cd "$tmp" && printf '%s' "$json" | env -i PATH="$PATH" HQ_ROOT="$tmp" HQ_ALLOW_UNSAFE_INSTALL="${HQ_ALLOW_UNSAFE_INSTALL:-0}" "${PARITY_ENV_ARGS[@]}" bash "$HOOK" >/dev/null 2>&1 )
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

# 4b. A command-line release-age gate is valid only at 1440 minutes or more.
#     Check both pnpm spellings and the threshold/invalid-value boundaries.
release_age_cmd_case() {  # <expected-ec> <setting-name> <age> <label>
  local want="$1" setting="$2" age="$3" label="$4" ec
  ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook "pnpm add left-pad --config.${setting}=${age}")"
  [ "$ec" = "$want" ] && pass "$label (exit $want)" \
                      || fail "$label: expected exit $want, got $ec"
}
for setting in minimumReleaseAge minimum-release-age; do
  release_age_cmd_case 2 "$setting" 1200 "${setting}=1200 is below the 1440-minute minimum"
  release_age_cmd_case 2 "$setting" 0 "${setting}=0 is below the 1440-minute minimum"
  release_age_cmd_case 2 "$setting" "" "${setting}=empty is rejected"
  release_age_cmd_case 2 "$setting" abc "${setting}=abc is rejected"
  release_age_cmd_case 0 "$setting" 1440 "${setting}=1440 meets the minimum"
  release_age_cmd_case 0 "$setting" 10080 "${setting}=10080 exceeds the minimum"
done
ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook "pnpm add left-pad --config.minimumReleaseAge='1440'")"
[ "$ec" = "0" ] && pass "single-quoted release-age value is accepted (exit 0)" \
                 || fail "single-quoted valid release-age value should be accepted, got $ec"
ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook 'pnpm add left-pad "--config.minimumReleaseAge=1440"')"
[ "$ec" = "0" ] && pass "quoted release-age option is accepted (exit 0)" \
                 || fail "quoted valid release-age option should be accepted, got $ec"
for setting in minimumReleaseAge minimum-release-age; do
  multiline_cmd="$(printf 'pnpm add left-pad \\\n--config.%s=1200' "$setting")"
  ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook "$multiline_cmd")"
  [ "$ec" = "2" ] && pass "continued command with ${setting}=1200 is blocked (exit 2)" \
                   || fail "continued command with ${setting}=1200 should block, got $ec"
  multiline_cmd="$(printf 'pnpm add left-pad \\\n--config.%s=1440' "$setting")"
  ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook "$multiline_cmd")"
  [ "$ec" = "0" ] && pass "continued command with ${setting}=1440 is accepted (exit 0)" \
                   || fail "continued command with ${setting}=1440 should pass, got $ec"
done
# Repository config values receive the same 1440-minute validation.
release_age_repo_case() {  # <expected-ec> <filename> <setting-line> <label>
  local want="$1" filename="$2" line="$3" label="$4" ec
  ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook_with_repo_config "$filename" "$line" 'pnpm add left-pad')"
  [ "$ec" = "$want" ] && pass "$label (exit $want)" \
                      || fail "$label: expected exit $want, got $ec"
}
for filename in .npmrc pnpm-workspace.yaml; do
  if [ "$filename" = ".npmrc" ]; then
    setting=minimum-release-age
    separator="="
  else
    setting=minimumReleaseAge
    separator=": "
  fi
  release_age_repo_case 2 "$filename" "${setting}${separator}1200" "$filename below-minimum value is rejected"
  release_age_repo_case 2 "$filename" "${setting}${separator}0" "$filename zero value is rejected"
  release_age_repo_case 2 "$filename" "${setting}${separator}" "$filename empty value is rejected"
  release_age_repo_case 2 "$filename" "${setting}${separator}abc" "$filename non-numeric value is rejected"
  release_age_repo_case 0 "$filename" "${setting}${separator}1440" "$filename minimum value is accepted"
  release_age_repo_case 0 "$filename" "${setting}${separator}10080" "$filename above-minimum value is accepted"
done
release_age_repo_case 0 pnpm-workspace.yaml 'minimumReleaseAge: 1440 # enforced' \
  "pnpm-workspace.yaml inline-commented minimum value is accepted"

# Environment aliases receive the same value validation as command flags.
release_age_env_case() {  # <expected-ec> <env-name> <age> <label>
  local want="$1" name="$2" age="$3" label="$4" ec
  ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook_with_env "$name" "$age" 'pnpm add left-pad')"
  [ "$ec" = "$want" ] && pass "$label (exit $want)" \
                      || fail "$label: expected exit $want, got $ec"
}
for name in npm_config_minimum_release_age NPM_CONFIG_MINIMUM_RELEASE_AGE; do
  release_age_env_case 2 "$name" 1200 "$name=1200 is below the minimum"
  release_age_env_case 2 "$name" 0 "$name=0 is below the minimum"
  release_age_env_case 2 "$name" "" "$name empty value is rejected"
  release_age_env_case 2 "$name" abc "$name non-numeric value is rejected"
  release_age_env_case 0 "$name" 1440 "$name=1440 meets the minimum"
  release_age_env_case 0 "$name" 10080 "$name=10080 exceeds the minimum"
done
ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook_with_env npm_config_minimum_release_age 1440 'pnpm add left-pad --config.minimumReleaseAge=1200')"
[ "$ec" = "2" ] && pass "invalid command value cannot fall through to a valid environment value (exit 2)" \
                 || fail "invalid command value must block despite valid environment value, got $ec"


if [[ "${HQ_TEST_RELEASE_AGE_ONLY:-0}" == "1" ]]; then
  if [[ "$fails" -gt 0 ]]; then
    echo "release-age checks failed ($fails assertions)" >&2
    exit 1
  fi
  echo "release-age checks passed"
  exit 0
fi

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

# 6b. Redirection tokens must not be mistaken for positional package args.
#     Found 2026-09-05: the allow-list override was dead in practice because
#     agents almost always write installs as `... 2>&1 | tail`. `2>&1` does not
#     start with '-', so every token loop counted it as a package name, the
#     "every positional token is allow-listed" check failed, and the install was
#     blocked. Redirections are shell plumbing and must be ignored.
allow_case 0 'npm install -g @tobilu/qmd@2.5.3 2>&1'               "allow-listed pin with trailing 2>&1 is allowed"
allow_case 0 'npm install -g @tobilu/qmd@2.5.3 2>&1 | tail -2'     "allow-listed pin with 2>&1 and a pipe is allowed"
allow_case 0 'npm install -g @tobilu/qmd@2.5.3 >/tmp/out.log 2>&1' "allow-listed pin with >file 2>&1 is allowed"
allow_case 0 'npm install -g @tobilu/qmd@2.5.3 > /tmp/out.log'     "allow-listed pin with detached '> file' target is allowed"
allow_case 0 'npm install -g @tobilu/qmd@2.5.3 >> /tmp/out.log'    "allow-listed pin with detached '>> file' target is allowed"
allow_case 0 'npm install -g @tobilu/qmd@2.5.3 &>/tmp/out.log'     "allow-listed pin with &>file is allowed"
allow_case 0 'npm install -g @tobilu/qmd@2.5.3 2>/dev/null'        "allow-listed pin with 2>/dev/null is allowed"
allow_case 0 'npm install -g @tobilu/qmd@2.5.3 1>&2'               "allow-listed pin with 1>&2 is allowed"
allow_case 0 'npm install -g @tobilu/qmd@2.5.3 </dev/null'         "allow-listed pin with <file is allowed"
allow_case 0 'pnpm add -g @tobilu/qmd@2.5.3 2>&1'                  "pnpm allow-listed pin with 2>&1 is allowed"
# Feedback 2313: hq-heal CLI restore. npm @latest is what the agent used to
# run and the supply-chain hook blocked. The age-gated pnpm form must pass.
allow_case 0 'pnpm add -g @indigoai-us/hq-cli@latest --config.minimumReleaseAge=1440' \
  "heal CLI restore (pnpm + minimumReleaseAge=1440) is allowed"

# 6c. Redirections must NOT launder an install that would otherwise be blocked.
allow_case 2 'npm i -g @tobilu/qmd 2>&1'                           "UNPINNED qmd with 2>&1 is still blocked"
allow_case 2 'npm install -g @tobilu/qmd@latest 2>&1'              "qmd@latest dist-tag with 2>&1 is still blocked"
allow_case 2 'npm install -g @tobilu/qmd@2.5.2 2>&1'               "wrong exact pin with 2>&1 is still blocked"
allow_case 2 'npm install @tobilu/qmd@2.5.3 2>&1'                  "NON-global pinned qmd with 2>&1 is still blocked"
allow_case 2 'npm install -g @tobilu/qmd@2.5.3 left-pad@1.0.0 2>&1' "mixed install with 2>&1 is still blocked"
allow_case 2 'npm install left-pad 2>&1'                           "third-party install with 2>&1 is still blocked"
allow_case 2 'npm install left-pad >/tmp/out.log 2>&1'             "third-party install with >file 2>&1 is still blocked"
allow_case 2 'pnpm add left-pad 2>&1'                              "pnpm third-party install with 2>&1 is still blocked"

# 6d. The same token loop feeds hydration detection, so a redirection must not
#     turn a bare `npm install` into a "has a positional package" install.
ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook 'npm install 2>&1')"
[ "$ec" = "0" ] && pass "'npm install 2>&1' (hydration + redirect) is allowed (exit 0)" \
                 || fail "'npm install 2>&1' should be allowed (exit 0), got $ec"
ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook 'pnpm install >/tmp/out.log 2>&1')"
[ "$ec" = "0" ] && pass "'pnpm install >file 2>&1' (hydration + redirect) is allowed (exit 0)" \
                 || fail "'pnpm install >file 2>&1' should be allowed (exit 0), got $ec"

# 7. Missing allow file: behave exactly as before (blocked).
ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook 'npm install -g @tobilu/qmd@2.5.3')"
[ "$ec" = "2" ] && pass "missing allow file still blocks 'npm install -g @tobilu/qmd@2.5.3' (exit 2)" \
                 || fail "missing allow file should block (exit 2), got $ec"

if [ "$fails" -gt 0 ]; then
  echo "block-unsafe-package-install.test.sh: $fails check(s) failed" >&2
  exit 1
fi
echo "block-unsafe-package-install.test.sh: all checks passed"
