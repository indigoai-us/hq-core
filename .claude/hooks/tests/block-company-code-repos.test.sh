#!/usr/bin/env bash
# Regression coverage for the Bash and file-write company Git guards.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
BASH_GUARD="$ROOT/.claude/hooks/block-company-repo-creation.sh"
WRITE_GUARD="$ROOT/.claude/hooks/block-company-git-metadata.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HQ="$TMP/hq"
COMPANY="$HQ/companies/acme"
APP="$HQ/repos/private/app"
mkdir -p "$COMPANY" "$APP"
git -C "$HQ" init -q
git -C "$APP" init -q

PASS=0
FAIL=0

run_bash() {
  local expected="$1" cwd="$2" command="$3" label="$4" expected_message="${5:-}" rc=0 payload err
  payload="$(jq -n --arg cwd "$cwd" --arg command "$command" \
    '{cwd:$cwd,tool_input:{command:$command}}')"
  err="$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$HQ" bash "$BASH_GUARD" 2>&1 >/dev/null)" || rc=$?
  if [[ "$rc" -eq "$expected" && ( -z "$expected_message" || "$err" == *"$expected_message"* ) ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL [$label]: expected exit $expected with message '$expected_message', got $rc" >&2
    [[ -z "$err" ]] || printf '  hook output: %s\n' "$err" >&2
  fi
}

run_file_tool() {
  local expected="$1" tool_name="$2" file_path="$3" label="$4" rc=0 payload err
  payload="$(jq -n --arg file_path "$file_path" \
    --arg tool_name "$tool_name" \
    '{tool_name:$tool_name,tool_input:{file_path:$file_path}}')"
  err="$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$HQ" bash "$WRITE_GUARD" 2>&1 >/dev/null)" || rc=$?
  if [[ "$rc" -eq "$expected" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL [$label]: expected exit $expected, got $rc" >&2
    [[ -z "$err" ]] || printf '  hook output: %s\n' "$err" >&2
  fi
}

run_multiedit() {
  local expected="$1" file_path="$2" label="$3" rc=0 payload
  payload="$(jq -n --arg file_path "$file_path" \
    '{tool_name:"MultiEdit",tool_input:{edits:[{file_path:$file_path}]}}')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$HQ" bash "$WRITE_GUARD" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq "$expected" ]]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    echo "FAIL [$label]: expected exit $expected, got $rc" >&2
  fi
}

# Git clone: explicit, URL-derived, -C, cd, and relative destinations.
run_bash 2 "$HQ" "git clone https://example.test/org/widget.git $COMPANY/widget" 'absolute clone destination blocked'
run_bash 2 "$COMPANY" 'git clone https://example.test/org/widget.git' 'clone destination derived from URL under company cwd blocked'
run_bash 2 "$HQ" 'git -C companies/acme clone https://example.test/org/widget.git modules/widget' 'git -C and relative clone destination blocked'
run_bash 2 "$HQ" 'cd companies/acme && git clone https://example.test/org/widget.git' 'cd anchor and derived clone destination blocked'
run_bash 2 "$HQ" 'git clone https://example.test/org/widget.git companies/acme/widget' 'relative clone destination blocked'
run_bash 2 "$HQ" 'git clone --filter blob:none https://example.test/org/widget.git companies/acme/repo' 'clone --filter value is consumed before destination'
run_bash 2 "$HQ" 'git clone --bundle-uri https://example.test/bundle https://example.test/org/widget.git companies/acme/repo' 'clone --bundle-uri value is consumed before destination'
run_bash 2 "$HQ" 'git clone --config core.bare=false https://example.test/org/widget.git companies/acme/repo' 'clone --config value is consumed before destination'
run_bash 2 "$HQ" 'git clone --origin upstream https://example.test/org/widget.git companies/acme/repo' 'clone --origin value is consumed before destination'
run_bash 2 "$HQ" 'git clone --jobs 2 https://example.test/org/widget.git companies/acme/repo' 'clone --jobs value is consumed before destination'
run_bash 2 "$HQ" 'git clone --no-template templates https://example.test/org/widget.git companies/acme/repo' 'clone --no-template value is consumed before destination'
run_bash 2 "$HQ" 'git clone --no-reference /tmp/cache https://example.test/org/widget.git companies/acme/repo' 'clone --no-reference value is consumed before destination'
run_bash 2 "$HQ" 'git clone --no-reference-if-able /tmp/cache https://example.test/org/widget.git companies/acme/repo' 'clone --no-reference-if-able value is consumed before destination'
run_bash 2 "$HQ" 'git clone --no-branch main https://example.test/org/widget.git companies/acme/repo' 'clone --no-branch value is consumed before destination'
run_bash 2 "$HQ" 'git clone --no-depth 1 https://example.test/org/widget.git companies/acme/repo' 'clone --no-depth value is consumed before destination'
run_bash 2 "$HQ" 'git clone --no-filter blob:none https://example.test/org/widget.git companies/acme/repo' 'clone --no-filter value is consumed before destination'
run_bash 2 "$HQ" 'git clone --no-config core.bare=false https://example.test/org/widget.git companies/acme/repo' 'clone --no-config value is consumed before destination'
run_bash 2 "$HQ" 'git clone --no-server-option protocol-v2 https://example.test/org/widget.git companies/acme/repo' 'clone --no-server-option value is consumed before destination'
run_bash 2 "$HQ" 'git clone --recursive https://example.test/org/widget.git companies/acme/repo' 'clone recursive alias is accepted'
run_bash 2 "$HQ" 'git clone --future-clone-option URL companies/acme/repo' 'unknown clone option scans later operands'
run_bash 2 "$COMPANY" 'git clone --future-clone-option URL' 'unknown clone option blocks company cwd default'
run_bash 2 "$HQ" 'git clone --depth' 'malformed clone parser emits its reason' 'git clone is missing the value for --depth'
ln -s "$COMPANY" "$HQ/repos/private/company-alias"
run_bash 2 "$HQ" 'git init repos/private/company-alias/linked-repo' 'symlink destination resolving into companies blocked'

# Git init: explicit target, effective cwd, -C, cd, and relative target.
run_bash 2 "$HQ" "git init $COMPANY/widget" 'absolute init target blocked'
run_bash 2 "$COMPANY" 'git init' 'implicit init target under company cwd blocked'
run_bash 2 "$HQ" 'git -C companies/acme init nested/repo' 'git -C and relative init target blocked'
run_bash 2 "$HQ" 'cd companies/acme && git init .' 'cd anchor init target blocked'
run_bash 2 "$HQ" 'git init companies/acme/relative-repo' 'relative init target blocked'
run_bash 2 "$HQ" 'git init --no-bare companies/acme/repo' 'git init --no-bare target blocked'
run_bash 2 "$HQ" 'git init --no-quiet companies/acme/repo' 'git init --no-quiet target blocked'
run_bash 2 "$HQ" 'git init --no-initial-branch main companies/acme/repo' 'git init --no-initial-branch value is consumed before target'
run_bash 2 "$HQ" 'git init --no-template templates companies/acme/repo' 'git init --no-template value is consumed before target'
run_bash 2 "$HQ" 'git init --future-init-option "$APP/new-repo"' 'unknown git init option fails closed' 'BLOCKED: Could not safely parse Git repository creation command'

# Worktree and submodule creation.
run_bash 2 "$HQ" "git -C $APP worktree add $COMPANY/worktree main" 'absolute worktree path blocked'
run_bash 2 "$HQ" 'git -C companies/acme worktree add ../worktree main' 'git -C relative worktree path blocked'
run_bash 2 "$HQ" 'cd companies/acme && git worktree add worktree main' 'cd anchor worktree path blocked'
run_bash 2 "$HQ" "git -C $APP submodule add https://example.test/org/widget.git $COMPANY/vendor/widget" 'absolute submodule path blocked'
run_bash 2 "$HQ" 'git -C companies/acme submodule add https://example.test/org/widget.git vendor/widget' 'git -C relative submodule path blocked'
run_bash 2 "$HQ" 'git -C companies/acme submodule --quiet add https://example.test/org/widget.git vendor' 'submodule --quiet before add is parsed'
run_bash 2 "$HQ" 'git -C companies/acme submodule --cached --quiet add https://example.test/org/widget.git vendor' 'submodule global options before add are parsed'
run_bash 2 "$HQ" 'git worktree add --reason' 'malformed worktree parser fails closed' 'git worktree add is missing the value for --reason'
run_bash 2 "$HQ" 'git submodule add --branch' 'malformed submodule parser fails closed' 'git submodule add is missing the value for --branch'
run_bash 2 "$HQ" 'cd companies/acme && git submodule add https://example.test/org/widget.git' 'cd anchor default submodule path blocked'

# GitHub CLI clone: explicit destination and the cwd-derived destination.
run_bash 2 "$HQ" "gh repo clone org/widget $COMPANY/widget" 'gh repo clone absolute destination blocked'
run_bash 2 "$COMPANY" 'gh repo clone org/widget' 'gh repo clone destination derived under company cwd blocked'
run_bash 2 "$HQ" 'cd companies/acme && gh repo clone org/widget' 'gh repo clone after cd blocked'
run_bash 2 "$HQ" 'gh repo clone' 'malformed gh clone parser fails closed' 'BLOCKED: Could not safely parse Git repository creation command'

# File guards cover a .git directory and the .git worktree file, across tool
# shapes. Ordinary company files and Git metadata in repos/ stay writable.
run_file_tool 2 Write "$COMPANY/repo/.git/HEAD" 'Write inside company .git directory blocked'
run_file_tool 2 Edit "$COMPANY/repo/.git" 'Edit of company worktree .git file blocked'
run_file_tool 2 Write companies/acme/repo/.git/config 'relative Write inside company .git directory blocked'
run_multiedit 2 "$COMPANY/repo/.git/config" 'MultiEdit inside company .git directory blocked'
run_file_tool 0 Write "$COMPANY/README.md" 'ordinary company file allowed'
run_file_tool 0 Edit "$APP/.git/HEAD" 'repo metadata outside companies allowed'

# Allowed Bash cases from the brief.
run_bash 0 "$HQ" "git -C $APP status" 'git command in existing repos checkout allowed'
run_bash 0 "$HQ" 'git -C repos/private/app log' 'relative git -C under repos allowed'
run_bash 0 "$COMPANY" 'git status' 'git status under companies allowed'
run_bash 0 "$COMPANY" 'git log -1' 'git log under companies allowed'
run_bash 0 "$HQ" 'cat companies/acme/README.md' 'reading company files allowed'
run_bash 0 "$HQ" 'hq core checkpoint --summary "companies/acme git clone org/widget"' 'hq command with company and Git words allowed'
run_bash 0 "$HQ" 'echo "companies/acme git init companies/acme/widget"' 'company path in a message string allowed'

# Each guard is live through hook-gate under every configured profile. This
# catches a missing profile allowlist entry, which makes direct tests look green
# while the installed hook silently passes through.
run_gate() {
  local profile="$1" hook_id="$2" script="$3" payload="$4" label="$5" rc=0
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$ROOT" HQ_HOOK_PROFILE="$profile" \
    bash "$ROOT/.claude/hooks/hook-gate.sh" "$hook_id" "$script" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 2 ]]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    echo "FAIL [$label]: expected exit 2, got $rc" >&2
  fi
}

for profile in minimal standard strict; do
  payload="$(jq -n --arg cwd "$ROOT" \
    --arg command 'git init companies/_template/guard-profile-test' \
    '{cwd:$cwd,tool_input:{command:$command}}')"
  run_gate "$profile" block-company-repo-creation "$BASH_GUARD" "$payload" "$profile profile runs Bash guard"
  payload="$(jq -n --arg file_path "$ROOT/companies/_template/guard-profile-test/.git/HEAD" \
    '{tool_name:"Write",tool_input:{file_path:$file_path}}')"
  run_gate "$profile" block-company-git-metadata "$WRITE_GUARD" "$payload" "$profile profile runs file guard"
done

echo "block-company-code-repos: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

# Codex adapter case: use the real adapter, hook gate and fallback dispatcher
# from a small fixture so the test proves the new critical guard is dispatched.
FIXTURE="$TMP/codex"
mkdir -p "$FIXTURE/.codex/hooks" "$FIXTURE/.claude/hooks" "$FIXTURE/core/scripts/lib" "$FIXTURE/companies/acme"
cp "$ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$FIXTURE/.codex/hooks/"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$FIXTURE/.claude/hooks/"
cp "$BASH_GUARD" "$FIXTURE/.claude/hooks/"
cp "$WRITE_GUARD" "$FIXTURE/.claude/hooks/"
cp "$ROOT/.claude/hooks/hook-registry.json" "$FIXTURE/.claude/hooks/"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIXTURE/core/scripts/"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIXTURE/core/scripts/lib/"
chmod +x "$FIXTURE/.codex/hooks/hq-codex-hook-adapter.sh" "$FIXTURE/.claude/hooks/hook-gate.sh" "$FIXTURE/.claude/hooks/block-company-repo-creation.sh" "$FIXTURE/.claude/hooks/block-company-git-metadata.sh"
export HQ_DISABLED_HOOKS="detect-secrets,block-env-dump,block-core-writes-bash,block-policy-writes-bash,block-hq-root-git-mutation,enforce-vault-write-access,block-on-active-run,inject-policy-on-trigger,block-unsafe-package-install,block-qmd-model-download,mandatory-scope-authorizer"

payload="$(jq -n --arg cwd "$FIXTURE/companies/acme" \
  --arg command 'git clone https://example.test/org/widget.git' \
  '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$command}}')"
run_codex_case() {
  local label="$1" rc=0
  printf '%s' "$payload" | (cd / && bash "$FIXTURE/.codex/hooks/hq-codex-hook-adapter.sh") >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 2 ]]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    echo "FAIL [$label]: expected exit 2, got $rc" >&2
  fi
}
run_codex_case 'Codex adapter dispatches the registered company repo guard'
payload="$(jq -n --arg cwd "$FIXTURE" --arg file_path "$FIXTURE/companies/acme/repo/.git/HEAD" \
  '{hook_event_name:"PreToolUse",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$file_path}}')"
run_codex_case 'Codex adapter dispatches the registered company Git metadata guard'
mv "$FIXTURE/.claude/hooks/hook-registry.json" "$FIXTURE/.claude/hooks/hook-registry.disabled.json"
payload="$(jq -n --arg cwd "$FIXTURE/companies/acme" \
  --arg command 'git clone https://example.test/org/widget.git' \
  '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$command}}')"
run_codex_case 'Codex adapter fallback dispatches the company repo guard'
payload="$(jq -n --arg cwd "$FIXTURE" --arg file_path "$FIXTURE/companies/acme/repo/.git/HEAD" \
  '{hook_event_name:"PreToolUse",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$file_path}}')"
run_codex_case 'Codex adapter fallback dispatches the company Git metadata guard'

echo "block-company-code-repos + Codex adapter: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
