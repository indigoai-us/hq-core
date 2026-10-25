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

# 8. The gh pr create wrapper gets the same exemption as `gh pr create` under
#    every path form, so install text in a PR body is not mistaken for a
#    command. Look-alike scripts are still parsed as commands.
PR_BODY='--title t --body "step; npm install left-pad"'
allow_case 0 "gh pr create $PR_BODY"                                  "gh pr create body text is exempt"
allow_case 0 "bash core/scripts/hq-pr-create.sh $PR_BODY"             "wrapper via bash, relative path, is exempt"
allow_case 0 "bash ./core/scripts/hq-pr-create.sh $PR_BODY"           "wrapper via bash, ./ path, is exempt"
allow_case 0 "bash /abs/hq/core/scripts/hq-pr-create.sh $PR_BODY"     "wrapper via bash, absolute path, is exempt"
allow_case 0 "bash \"\$HQ_ROOT/core/scripts/hq-pr-create.sh\" $PR_BODY" "wrapper via bash, quoted \$HQ_ROOT path, is exempt"
allow_case 0 "sh core/scripts/hq-pr-create.sh $PR_BODY"               "wrapper via sh is exempt"
allow_case 0 "core/scripts/hq-pr-create.sh $PR_BODY"                  "wrapper executed directly is exempt"
allow_case 2 "bash other.sh $PR_BODY"                                 "other script with install text is still blocked"
allow_case 2 "bash /abs/hq/core/scripts/hq-pr-create.sh.bak $PR_BODY" "wrapper look-alike name is still blocked"

# DEV-4329: assignment stripping must consume every whitespace delimiter.
# Bound the reproduction so a regression fails instead of hanging CI.
if ! python3 - "$HOOK" <<'PY_ASSIGNMENT_TEST'
import json, os, subprocess, sys, tempfile
hook = sys.argv[1]
cases = [
    ("newline assignments only", "S=scripts\nOUT=output\nAPP_NAME=app", 0),
    ("tab assignments only", "S=scripts\tOUT=output\tAPP_NAME=app", 0),
    ("assignments in chained segment", "true && S=scripts\nOUT=output\nAPP_NAME=app; true", 0),
    ("tab prefix cannot hide unsafe install", "S=scripts\tnpm install left-pad", 2),
    ("newline prefix cannot hide unsafe install", "S=scripts\nnpm install left-pad", 2),
    ("chained prefix cannot hide unsafe install", "true && S=scripts\tnpm install left-pad", 2),
    # feedback_3d0f49f4: the /deploy skill's Phase C block run inline. The
    # segment between `&&` and `;` starts with newline-separated assignments
    # (quoted values, no space anywhere), which hung PreToolUse for 300 s.
    ("deploy phase C inline block (feedback_3d0f49f4)",
     'cd "$HQ_ROOT" && S=.claude/skills/deploy/scripts\nOUT="workspace/deploy/out"\nAPP_NAME="hq-site"; '
     'bash "$S/upload.sh" --app "$APP_NAME" --out "$OUT" && echo done', 0),
    ("deploy phase C shape cannot hide an unsafe install",
     'cd "$HQ_ROOT" && S=.claude/skills/deploy/scripts\nOUT="workspace/deploy/out"\nAPP_NAME="hq-site"\nnpm install left-pad; echo done', 2),
    # feedback_f692e290: a prefix that cannot be consumed must end the strip,
    # not spin. Assignments followed only by whitespace is the no-progress edge.
    ("assignments followed by trailing whitespace only", "S=scripts\nOUT=output\n   ", 0),
    ("assignment with a CRLF line end", "S=scripts\r\nnpm install left-pad", 2),
]
failed = 0
with tempfile.TemporaryDirectory() as tmp:
    env = {"PATH": os.environ["PATH"], "HQ_ROOT": tmp}
    # Preserve only the same parity instrumentation allowlist used by run_hook.
    for key in ("HQ_PARITY_REAL_BASH", "HQ_PARITY_RECORD_ROOT",
                "HQ_PARITY_UNSAFE_BASE_HOOK", "HQ_PARITY_UNSAFE_CANDIDATE_HOOK",
                "HQ_PARITY_CORE_BASE_HOOK", "HQ_PARITY_CORE_CANDIDATE_HOOK"):
        if key in os.environ:
            env[key] = os.environ[key]
    for name, command, expected in cases:
        payload = json.dumps({"tool_name":"Bash", "tool_input":{"command":command}})
        try:
            # This regression fixes behaviour absent from the frozen process baseline.
            # Exercise the current candidate directly; historical parity stays
            # active for the surrounding fixture suite.
            regression_bash = env.get("HQ_PARITY_REAL_BASH", "bash")
            regression_hook = env.get("HQ_PARITY_UNSAFE_CANDIDATE_HOOK", hook)
            result = subprocess.run([regression_bash, regression_hook], input=payload, text=True, capture_output=True,
                                    cwd=tmp, env=env, timeout=5)
            if result.returncode != expected:
                print(f"FAIL - {name}: expected {expected}, got {result.returncode}")
                failed += 1
            else:
                print(f"ok   - {name} terminates with exit {expected}")
        except subprocess.TimeoutExpired:
            print(f"FAIL - {name}: guard failed to terminate within 5 seconds")
            failed += 1
sys.exit(bool(failed))
PY_ASSIGNMENT_TEST
then
  fail "assignment whitespace regression"
fi

# feedback_a041edbc: a package install run through a launcher wrapper must be
# matched like the bare command. Lockfile hydration through a wrapper still passes.
wrapper_case() {  # <expected-ec> <cmd>
  local want="$1" cmd="$2" ec
  ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook "$cmd")"
  [ "$ec" = "$want" ] && pass "wrapper: $cmd -> exit $want" \
                      || fail "wrapper: $cmd: expected exit $want, got $ec"
}
wrapper_case 2 "mise exec -- bun install left-pad"
wrapper_case 2 "mise x node@20 -- npm i left-pad"
wrapper_case 2 "npx -y pnpm add left-pad"
wrapper_case 2 "bunx yarn add left-pad"
wrapper_case 2 "env FOO=1 npm install left-pad"
wrapper_case 2 "/usr/bin/env -i -u HOME npm install left-pad"
wrapper_case 2 "nohup npm i left-pad"
wrapper_case 2 "command bun add left-pad"
wrapper_case 2 "cd /tmp && mise exec -- env A=1 npm i left-pad"
wrapper_case 2 "mise exec -- npm i left-pad -- x"
wrapper_case 2 "env -S 'npm install left-pad'"
wrapper_case 2 "env -S\"npm install left-pad\""
wrapper_case 2 "npx npm@latest install left-pad"
wrapper_case 2 "sudo -E npm i left-pad"
wrapper_case 2 "sudo -u builder npm i left-pad"
wrapper_case 2 "npx --yes pnpm@9 add left-pad"
wrapper_case 2 "npx -p pnpm pnpm add left-pad"
wrapper_case 2 "env -i npm i left-pad"
wrapper_case 2 "time -p npm i left-pad"
wrapper_case 2 "nice npm i left-pad"
wrapper_case 2 "nice -n 5 npm i left-pad"
wrapper_case 2 "timeout 60 npm i left-pad"
wrapper_case 2 "timeout -k 5 1m pnpm add left-pad"
wrapper_case 2 "stdbuf -oL npm i left-pad"
wrapper_case 2 "caffeinate npm i left-pad"
wrapper_case 2 "exec -a foo npm i left-pad"
wrapper_case 2 "xargs npm i"
wrapper_case 2 "true | xargs -n 1 pnpm add"
wrapper_case 2 "yarn dlx -p x npm i left-pad"
wrapper_case 2 "npm exec -- pnpm add left-pad"
wrapper_case 2 "pnpm exec npm i left-pad"
wrapper_case 2 "corepack pnpm add left-pad"
wrapper_case 2 "volta run --node 20 npm i left-pad"
wrapper_case 2 "\"npm\" i left-pad"
wrapper_case 2 "'env' npm i left-pad"
wrapper_case 2 "\\npm i left-pad"
wrapper_case 2 "sudo -iu x npm i left-pad"
wrapper_case 2 "sudo -Hu x npm i left-pad"
wrapper_case 2 "sudo -uroot npm i left-pad"
wrapper_case 2 "stdbuf -o L npm i left-pad"
wrapper_case 2 "npm exec -c 'npm i left-pad'"
wrapper_case 2 "npm exec --call \"pnpm add left-pad\""
wrapper_case 2 "npm x -- npm i left-pad"
wrapper_case 2 "pnpm x npm i left-pad"
wrapper_case 2 "yarn npx npm i left-pad"
wrapper_case 2 "pnpx pnpm add left-pad"
wrapper_case 2 "nohup nohup nohup nohup nohup nohup nohup nohup nohup npm i left-pad"
wrapper_case 0 "npm exec -c 'tsc --noEmit'"
wrapper_case 0 "sudo make install"
wrapper_case 0 "nohup npm run dev"
wrapper_case 0 "pnpx tsc"
wrapper_case 0 "xargs npm ci"
wrapper_case 0 "xargs rm"
wrapper_case 0 "nice make"
wrapper_case 0 "timeout 5 npm ci"
wrapper_case 0 "npm exec -- tsc --noEmit"
wrapper_case 0 "pnpm exec vitest run"
wrapper_case 0 "corepack enable"
wrapper_case 0 "\"npm\" ci"
wrapper_case 0 "mise exec -- bun install --frozen-lockfile"
wrapper_case 0 "env -S 'npm ci'"
wrapper_case 0 "sudo npm ci"
wrapper_case 0 "env CI=1 npm ci"
wrapper_case 0 "npx create-react-app demo"
wrapper_case 0 "mise exec -- node script.js"
wrapper_case 0 "env"

# feedback_03770784: a leading text command (echo, printf, cat, awk, sed,
# git commit, gh pr create, python3 -c, bash -c) used to exempt the WHOLE
# command line, so an install chained after it was never checked. The split
# is now quote-aware and every unit is checked.
segment_case() {  # <expected-ec> <cmd>
  local want="$1" cmd="$2" ec
  ec="$(unset HQ_ALLOW_UNSAFE_INSTALL; run_hook "$cmd")"
  [ "$ec" = "$want" ] && pass "segment: $(printf '%s' "$cmd" | tr '\n' '~') -> exit $want" \
                      || fail "segment: $(printf '%s' "$cmd" | tr '\n' '~'): expected exit $want, got $ec"
}
segment_case 2 "echo x | npm install left-pad"
segment_case 2 "echo x | npm i left-pad"
segment_case 2 "echo x|npm install left-pad"
segment_case 2 "echo x; npm install left-pad"
segment_case 2 "printf x | npm install left-pad"
segment_case 2 "echo \"a\" && pnpm add left-pad"
segment_case 2 "cat foo | yarn add left-pad"
segment_case 2 "ls | bun add left-pad"
segment_case 2 "git commit -m x; npm install left-pad"
segment_case 2 "bash -c 'npm install left-pad'"
segment_case 2 "sh -c \"npm i left-pad\""
segment_case 2 "bash -lc \"cd /tmp && npm i left-pad\""
segment_case 2 "python3 -c \"print(1)\"; npm install left-pad"
segment_case 2 "gh pr create --title x; npm install left-pad"
segment_case 2 "awk '{print}' f | npm install left-pad"
segment_case 2 "sed -n 1p f && npm install left-pad"
segment_case 2 "echo x 2>&1 | npm install left-pad"
segment_case 2 $'echo x\nnpm install left-pad'
segment_case 2 $'cat <<EOF\nhi\nEOF\nnpm install left-pad'
# npm ci is lockfile hydration and allowed standalone; chaining keeps that.
segment_case 0 "echo x | npm ci"
segment_case 0 "echo npm install left-pad"
segment_case 0 "echo \"npm install left-pad\""
segment_case 0 "grep -n \"npm install left-pad\" README.md"
segment_case 0 "git commit -m \"fix: npm install left-pad\""
segment_case 0 "git commit -m \"a; npm install left-pad\""
segment_case 0 $'git commit -m "line1\nnpm install left-pad\nline3"'
segment_case 0 $'git commit -m "$(cat <<\'EOF\'\nfix: x; npm install left-pad\n| pnpm add y\nEOF\n)"'
segment_case 0 "git commit -F msg.txt && echo ok"
segment_case 0 "gh pr create --title x --body \"run npm install left-pad\""
segment_case 0 "gh pr create --title x --body-file body.md"
segment_case 0 "bash core/scripts/hq-pr-create.sh --title \"x; npm install left-pad\" --body \"a | npm i b\""
segment_case 0 "echo \"a | npm install left-pad\""
segment_case 0 "echo 'x; pnpm add y'"
segment_case 0 "bash -c \"echo \\\"npm i left-pad\\\"\""
segment_case 0 $'cat <<\'EOF\'\nnpm install left-pad\nEOF'
segment_case 0 $'cat <<-EOF > f\n\tnpm install left-pad; x\n\tEOF\necho done'

# feedback_03770784 review: substitutions, ANSI-C quotes, arithmetic, shell
# option forms, keywords, eval, dequoting, line continuation, stdin shells,
# and global options before the subcommand.
segment_case 2 "foo \"\$(npm i left-pad)\""
segment_case 2 "echo \"\$(npm i left-pad)\""
segment_case 2 "foo \"\`npm i left-pad\`\""
segment_case 2 "foo \$(npm i left-pad)"
segment_case 2 "foo <(npm i left-pad)"
segment_case 2 $'cat <<EOF\n$(npm i left-pad)\nEOF'
segment_case 2 $'cat <<EOF\n`npm i left-pad`\nEOF'
segment_case 2 "true \$'\\'' & npm i left-pad & #'"
segment_case 2 $'true $\'\\\'\'\nnpm i left-pad\n#\''
segment_case 2 $'true $((1<<2))\nnpm i left-pad'
segment_case 2 $'echo $((1<<2))\nnpm i left-pad\n2'
segment_case 2 "bash -ec 'npm i left-pad'"
segment_case 2 "bash -c -- 'npm i left-pad'"
segment_case 2 "bash -c -e 'npm i left-pad'"
segment_case 2 "bash --norc -c 'npm i left-pad'"
segment_case 2 "bash -o errexit -c 'npm i left-pad'"
segment_case 2 "/bin/bash -c 'npm i left-pad'"
segment_case 2 "/usr/bin/env bash -c 'npm i left-pad'"
segment_case 2 "sudo bash -c 'npm i left-pad'"
segment_case 2 "bash -c \"bash -c 'npm i left-pad'\""
segment_case 2 "bash -c 'true' && npm i left-pad"
segment_case 2 "{ npm i left-pad; }"
segment_case 2 "if true; then npm i left-pad; fi"
segment_case 2 "while false; do npm i left-pad; done"
segment_case 2 "! npm i left-pad"
segment_case 2 "coproc npm i left-pad"
segment_case 2 "eval \"npm i left-pad\""
segment_case 2 "eval npm i left-pad"
segment_case 2 "n''pm i left-pad"
segment_case 2 $'npm \\\n i left-pad'
segment_case 2 "bash <<< 'npm i left-pad'"
segment_case 2 "echo 'npm i left-pad' | bash"
segment_case 2 $'bash <<EOF\nnpm i left-pad\nEOF'
segment_case 2 $'cat <<\'EOF\' | sh\nnpm i left-pad\nEOF'
segment_case 2 "npm --prefix /tmp i left-pad"
segment_case 2 "true |& npm i left-pad"
segment_case 2 "true 2>&1 & npm i left-pad"
segment_case 2 $'true\r\nnpm i left-pad'
segment_case 2 $'true #x\nnpm i left-pad'
segment_case 2 $'true\ncat <<\'E\'\nx\nE\nnpm i left-pad'
segment_case 0 $'git commit -m "$(cat <<\'EOF\'\nfix: pad 6" wide\nnpm install left-pad\nEOF\n)"'
segment_case 0 $'gh pr create --title x --body "$(cat <<\'EOF\'\nUse a 3" margin\nnpm install left-pad\nEOF\n)"'
segment_case 0 $'git commit -m "$(cat <<\'EOF\'\nFixes `a | b` and it\'s "quoted\n- npm i left-pad\nEOF\n)"'
segment_case 0 $'cat > f.md <<EOF\n$(date)\nnpm install left-pad\nEOF'
segment_case 0 $'gh issue create --title x --body \'npm-ish: run\'\n\'npm i left-pad\''
segment_case 0 "bash -c \"echo 'a' && echo \\\"npm i left-pad\\\"\""
segment_case 0 "echo \"don't\" && echo \"npm i left-pad\""
segment_case 0 "printf '%s\\n' 'step 1' 'npm i left-pad'"
segment_case 0 $'cat <<\\EOF\n$(npm i left-pad)\nEOF'
segment_case 0 $'cat <<"EOF"\n`npm i left-pad`\nEOF'
segment_case 0 "npm --prefix /tmp ci"
segment_case 0 "bash <<< 'npm ci'"

# feedback_03770784 round 2: dollar-quoted heredoc delimiters, nesting limit,
# ANSI-C escapes, wrappers before stdin shells, shell option forms, npm
# subcommand aliases, function bodies, find -exec and watch.
segment_case 2 $'cat <<$\'E\'\nx\nE\nnpm i left-pad\n$E'
segment_case 2 $'cat <<$"E"\nx\nE\nnpm i left-pad\n$E'
segment_case 2 "$(printf '$(%.0s' $(seq 1 70))"$'\nnpm i left-pad'
segment_case 2 "\$'\\x6e'pm i left-pad"
segment_case 2 "\$'\\156'pm i left-pad"
segment_case 2 "\$'\\u006e'pm i left-pad"
segment_case 2 "echo 'npm i left-pad' | sudo bash"
segment_case 2 "echo 'npm i left-pad' | env bash"
segment_case 2 "echo 'npm i left-pad' | tee /dev/null | bash"
segment_case 2 $'sudo bash <<EOF\nnpm i left-pad\nEOF'
segment_case 2 $'env bash <<EOF\nnpm i left-pad\nEOF'
segment_case 2 "bash --rcfile /dev/null -c 'npm i left-pad'"
segment_case 2 "bash --init-file /dev/null -c 'npm i left-pad'"
segment_case 2 "busybox sh -c 'npm i left-pad'"
segment_case 2 "fish -c 'npm i left-pad'"
segment_case 2 "npm in left-pad"
segment_case 2 "npm ins left-pad"
segment_case 2 "npm inst left-pad"
segment_case 2 "npm insta left-pad"
segment_case 2 "npm instal left-pad"
segment_case 2 "npm isnt left-pad"
segment_case 2 "npm isnta left-pad"
segment_case 2 "npm isntal left-pad"
segment_case 2 "npm isntall left-pad"
segment_case 2 "npm it left-pad"
segment_case 2 "npm install-test left-pad"
segment_case 2 "pnpm it left-pad"
segment_case 2 "function f { npm i left-pad; }"
segment_case 2 "f() { npm i left-pad; }"
segment_case 2 "find . -maxdepth 0 -exec npm i left-pad \\;"
segment_case 2 "find . -execdir sh -c 'npm i left-pad' {} +"
segment_case 2 "watch -n 5 npm i left-pad"
segment_case 2 "watch 'npm i left-pad'"
segment_case 0 "npm init foo"
segment_case 0 "npm it"
segment_case 0 "npm isntall"
segment_case 0 "npm ci"
segment_case 0 $'cat <<$\'E\'\n$(npm i left-pad)\nE'
segment_case 0 "echo \$'\\x6e'pm i left-pad"
segment_case 0 "find . -name '*.json' -exec grep -l npm {} +"
segment_case 0 "watch -n 5 'npm ls'"
segment_case 0 "echo 'npm ls' | sudo bash"

# feedback_03770784 round 3: ANSI-C heredoc delimiters and more launchers.
segment_case 2 $'cat <<$\'E\\x46\'\nx\nEF\nnpm i left-pad\nE\\x46'
segment_case 2 $'cat <<$\'E\\106\'\nx\nEF\nnpm i left-pad'
segment_case 2 "arch -arm64 npm i left-pad"
segment_case 2 "arch -x86_64 npm i left-pad"
segment_case 2 "flock /tmp/lock npm i left-pad"
segment_case 2 "flock -w 5 /tmp/lock npm i left-pad"
segment_case 2 "flock /tmp/lock -c 'npm i left-pad'"
segment_case 2 "flock -c 'npm i left-pad' /tmp/lock"
segment_case 2 "script -q /dev/null npm i left-pad"
segment_case 2 "script -q -c 'npm i left-pad' /dev/null"
segment_case 2 "parallel npm i ::: left-pad"
segment_case 2 "parallel -j 2 npm i ::: left-pad is-odd"
segment_case 2 "chronic npm i left-pad"
segment_case 2 "unbuffer npm i left-pad"
segment_case 2 "tcsh -c 'npm i left-pad'"
segment_case 2 "csh -c 'npm i left-pad'"
segment_case 2 "echo 'npm i left-pad' | arch -arm64 bash"
segment_case 0 $'cat <<$\'E\\x46\'\nnpm i left-pad\nEF'
segment_case 0 "arch -arm64 npm ci"
segment_case 0 "flock /tmp/lock npm ci"
segment_case 0 "script -q /dev/null npm run build"
segment_case 0 "parallel echo ::: npm i left-pad"
segment_case 0 "tcsh -c 'echo npm i left-pad'"

if [ "$fails" -gt 0 ]; then
  echo "block-unsafe-package-install.test.sh: $fails check(s) failed" >&2
  exit 1
fi
echo "block-unsafe-package-install.test.sh: all checks passed"
