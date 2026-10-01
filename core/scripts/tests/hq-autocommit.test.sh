#!/usr/bin/env bash
# hq-core: public
# Smoke tests for silent HQ-local autosave.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR/../../.." rev-parse --show-toplevel)"
TMP_PARENT="$(mktemp -d)"
TMP="$TMP_PARENT/hq"
trap 'rm -rf "$TMP_PARENT"' EXIT
mkdir -p "$TMP"

# The hook keys its cross-process mutex off TMPDIR. Point it at the sandbox so
# this suite can neither be blocked by, nor block, a real autosave on the host.
export TMPDIR="$TMP_PARENT/tmp"
mkdir -p "$TMPDIR"

SAFE_BIN="$TMP_PARENT/safe-bin"
mkdir -p "$SAFE_BIN"
AWS_PROFILE="us-110-111-test"
AWS_SHARED_CREDENTIALS_FILE="$TMP_PARENT/empty-aws-credentials"
AWS_CONFIG_FILE="$TMP_PARENT/empty-aws-config"
AWS_EC2_METADATA_DISABLED=true
: >"$AWS_SHARED_CREDENTIALS_FILE"
: >"$AWS_CONFIG_FILE"
export AWS_PROFILE AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE AWS_EC2_METADATA_DISABLED
unset HQ_FLAGS_API_URL HQ_COMPANY_UID HQ_COMPANY_SLUG HQ_CLI_BIN \
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN \
  AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
  AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_AUTHORIZATION_TOKEN
for blocked_binary in aws sst pulumi systemctl; do
  cat >"$SAFE_BIN/$blocked_binary" <<'STUB'
#!/usr/bin/env bash
printf 'unexpected external binary: %s\n' "${0##*/}" >&2
exit 97
STUB
  chmod +x "$SAFE_BIN/$blocked_binary"
done
export PATH="$SAFE_BIN:$PATH"
for blocked_binary in aws sst pulumi systemctl; do
  if [[ "$(command -v "$blocked_binary")" != "$SAFE_BIN/$blocked_binary" ]]; then
    echo "the test must not resolve the host $blocked_binary binary" >&2
    exit 1
  fi
done

mkdir -p "$TMP/.claude/hooks" "$TMP/core" "$TMP/repos/public/app"
HOOK_SOURCE="${HQ_AUTOCOMMIT_TEST_HOOK_SOURCE:-$ROOT/.claude/hooks/hq-autocommit.sh}"
FLAG_SOURCE="${HQ_AUTOCOMMIT_TEST_FLAG_SOURCE:-$ROOT/.claude/hooks/hq-autocommit-failure-context-flag.cjs}"
cp "$HOOK_SOURCE" "$TMP/.claude/hooks/hq-autocommit.sh"
if [[ -f "$FLAG_SOURCE" ]]; then
  cp "$FLAG_SOURCE" "$TMP/.claude/hooks/hq-autocommit-failure-context-flag.cjs"
fi
chmod +x "$TMP/.claude/hooks/hq-autocommit.sh"
printf 'hqVersion: "test"\n' > "$TMP/core/core.yaml"

git -C "$TMP" init -q
git -C "$TMP" config user.email "hq-autocommit-test"
git -C "$TMP" config user.name "HQ Autocommit Test"
git -C "$TMP" add core/core.yaml .claude/hooks/hq-autocommit.sh
git -C "$TMP" commit -q -m "init"

run_auto_maintenance_disabled_case() {
  local shim_dir="$TMP_PARENT/git-maintenance-shim" trace="$TMP_PARENT/git-maintenance-trace" real_git payload rc=0 output
  real_git="$(command -v git)"
  mkdir -p "$shim_dir"
  cat >"$shim_dir/git" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${HQ_AUTOCOMMIT_TEST_GIT_TRACE:?}"
exec "${HQ_AUTOCOMMIT_TEST_REAL_GIT:?}" "$@"
SHIM
  chmod +x "$shim_dir/git"
  : >"$trace"
  git -C "$TMP" config gc.auto 1
  printf 'maintenance regression\n' > "$TMP/maintenance-regression.md"
  payload="$(jq -cn --arg path "$TMP/maintenance-regression.md" '{tool_name:"Edit",tool_input:{file_path:$path}}')"
  output="$(cd "$TMP" && printf '%s' "$payload" | env \
    PATH="$shim_dir:$PATH" HQ_AUTOCOMMIT_TEST_GIT_TRACE="$trace" \
    HQ_AUTOCOMMIT_TEST_REAL_GIT="$real_git" bash .claude/hooks/hq-autocommit.sh 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 || -n "$output" ]]; then
    echo "autosave with gc.auto=1 should commit silently; rc=$rc out='$output'" >&2
    return 1
  fi
  if ! grep -Fq -- '-c gc.auto=0 -c maintenance.auto=false' "$trace" || ! grep -Eq ' commit --no-verify ' "$trace"; then
    echo "autosave commit must disable per-commit auto maintenance without changing config; git calls: $(cat "$trace")" >&2
    return 1
  fi
  if grep -Eq '(^| )(gc --auto|maintenance run --auto)( |$)' "$trace"; then
    echo "autosave spawned automatic git maintenance: $(cat "$trace")" >&2
    return 1
  fi
}

run_linked_worktree_case() {
  local linked="$TMP_PARENT/hq-linked" branch="us085-linked-worktree" base_head payload rc output
  git -C "$TMP" worktree add -q -b "$branch" "$linked"
  base_head="$(git -C "$TMP" rev-parse HEAD)"
  printf 'linked worktree edit\n' > "$linked/linked-worktree.md"
  payload="$(jq -cn --arg path "$linked/linked-worktree.md" '{tool_name:"Edit",tool_input:{file_path:$path}}')"
  rc=0
  output="$(cd "$linked" && printf '%s' "$payload" | env CLAUDE_PROJECT_DIR="$linked" bash .claude/hooks/hq-autocommit.sh 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 || -n "$output" ]]; then
    echo "linked-worktree autosave should stay silent and exit 0; rc=$rc out='$output'" >&2
    return 1
  fi
  if [[ "$(git -C "$linked" branch --show-current)" != "$branch" ]]; then
    echo "linked-worktree autosave must retain its worktree branch" >&2
    return 1
  fi
  if ! git -C "$linked" show --name-only --format= HEAD | grep -Fqx 'linked-worktree.md'; then
    echo "linked-worktree edit was not committed on its linked branch" >&2
    return 1
  fi
  if [[ "$(git -C "$TMP" rev-parse HEAD)" != "$base_head" ]]; then
    echo "linked-worktree autosave changed the base worktree branch" >&2
    return 1
  fi
}

ensure_cygpath_shim() {
  local shim_dir="$TMP/windows-path-shim"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/cygpath" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-u" ]]; then shift; fi
windows_path="${1:-}"
windows_path="${windows_path//\\//}"
case "$windows_path" in
  [A-Za-z]:/hq/*) ;;
  *) exit 1 ;;
esac
printf '%s/%s\n' "${HQ_AUTOCOMMIT_TEST_WINDOWS_ROOT:?}" "${windows_path:6}"
SHIM
  chmod +x "$shim_dir/cygpath"
  printf '%s' "$shim_dir"
}

run_windows_style_path_case() {
  local style="$1" fixture windows_path payload shim_dir rc=0 output
  case "$style" in
    backslash)
      fixture="windows-backslash.md"
      windows_path='C:\hq\windows-backslash.md'
      ;;
    forwardslash)
      fixture="windows-forwardslash.md"
      windows_path='C:/hq/windows-forwardslash.md'
      ;;
    *)
      echo "unknown Windows path style: $style" >&2
      return 1
      ;;
  esac
  shim_dir="$(ensure_cygpath_shim)"
  printf 'Windows path edit\n' > "$TMP/$fixture"
  payload="$(jq -cn --arg path "$windows_path" '{tool_name:"Edit",tool_input:{file_path:$path}}')"
  output="$(cd "$TMP" && printf '%s' "$payload" | env \
    HQ_AUTOCOMMIT_TEST_WINDOWS_ROOT="$TMP" PATH="$shim_dir:$PATH" \
    bash .claude/hooks/hq-autocommit.sh 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 || -n "$output" ]]; then
    echo "Windows-style $style path should autosave silently; rc=$rc out='$output'" >&2
    return 1
  fi
  if ! git -C "$TMP" show --name-only --format= HEAD | grep -Fqx "$fixture"; then
    echo "Windows-style $style path was not committed: $windows_path" >&2
    return 1
  fi
}

run_unresolved_windows_path_case() {
  local shim_dir payload rc=0 output before after
  shim_dir="$(ensure_cygpath_shim)"
  mkdir -p "$TMP/unresolved"
  before="$(grep -c 'FAIL stage=resolve' "$TMP/workspace/logs/hq-autocommit.log" 2>/dev/null || true)"
  payload="$(jq -cn --arg path 'C:\hq\unresolved\missing.md' '{tool_name:"Edit",tool_input:{file_path:$path}}')"
  output="$(cd "$TMP" && printf '%s' "$payload" | env \
    HQ_AUTOCOMMIT_TEST_WINDOWS_ROOT="$TMP" PATH="$shim_dir:$PATH" \
    bash .claude/hooks/hq-autocommit.sh 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 || -n "$output" ]]; then
    echo "unresolved Windows path should remain non-blocking and silent; rc=$rc out='$output'" >&2
    return 1
  fi
  after="$(grep -c 'FAIL stage=resolve' "$TMP/workspace/logs/hq-autocommit.log" 2>/dev/null || true)"
  if [[ "$after" -le "$before" ]]; then
    echo "unresolved Windows path was silently dropped instead of logged" >&2
    return 1
  fi
}

run_windows_fallback_path_case() {
  local shim_dir="$TMP/cygpath-failure-shim" payload rc=0 output log
  mkdir -p "$shim_dir"
  cat > "$shim_dir/cygpath" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
  chmod +x "$shim_dir/cygpath"
  payload="$(jq -cn --arg path 'C:\hq\fallback-missing.md' '{tool_name:"Edit",tool_input:{file_path:$path}}')"
  output="$(cd "$TMP" && printf '%s' "$payload" | env \
    PATH="$shim_dir:$PATH" bash .claude/hooks/hq-autocommit.sh 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 || -n "$output" ]]; then
    echo "unresolved fallback path should remain non-blocking and silent; rc=$rc out='$output'" >&2
    return 1
  fi
  log="$TMP/workspace/logs/hq-autocommit.log"
  if ! grep -Fq 'FAIL stage=resolve path=/c/hq/fallback-missing.md' "$log" 2>/dev/null; then
    echo "failed cygpath conversion did not use and log the pure-Bash drive mapping" >&2
    return 1
  fi
}

run_failure_context_case() {
  local shim_dir="$TMP_PARENT/failing-git" payload rc=0 stderr_file="$TMP_PARENT/failure-stderr" strict_stderr="$TMP_PARENT/strict-stderr" real_git default_tmp strict_tmp off_tmp cli fake_bin
  real_git="$(command -v git)"
  default_tmp="$TMP_PARENT/tmp/failure-default"
  strict_tmp="$TMP_PARENT/tmp/failure-strict"
  off_tmp="$TMP_PARENT/tmp/failure-off"
  cli="$TMP_PARENT/flag-cli"
  fake_bin="$TMP_PARENT/flag-bin"
  mkdir -p "$shim_dir" "$default_tmp" "$strict_tmp" "$off_tmp" \
    "$cli/bin" "$cli/node_modules/@indigoai-us/hq-flags-client" \
    "$cli/node_modules/@indigoai-us/hq-cloud" "$fake_bin"
  cat >"$shim_dir/git" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [[ "$arg" == "commit" ]]; then
    printf 'synthetic commit failure\n' >&2
    exit 23
  fi
done
exec "${HQ_AUTOCOMMIT_TEST_REAL_GIT:?}" "$@"
SHIM
  chmod +x "$shim_dir/git"
  cat >"$cli/package.json" <<'JSON'
{"name":"@indigoai-us/hq-cli","bin":{"hq":"bin/hq"}}
JSON
  cat >"$cli/bin/hq" <<'SH'
#!/usr/bin/env sh
exit 0
SH
  chmod +x "$cli/bin/hq"
  ln -s "$cli/bin/hq" "$fake_bin/hq"
  cat >"$cli/node_modules/@indigoai-us/hq-flags-client/package.json" <<'JSON'
{"type":"module","exports":{".":{"import":"./index.js"}}}
JSON
  cat >"$cli/node_modules/@indigoai-us/hq-flags-client/index.js" <<'JS'
export const createFlagClient = () => ({
  ready: async () => {},
  snapshot: () => ({ flags: { "hooks.hq-autocommit-failure-context": process.env.HQ_TEST_FLAG_ENABLED === "true" } }),
  close: () => {},
});
JS
  cat >"$cli/node_modules/@indigoai-us/hq-cloud/package.json" <<'JSON'
{"type":"module","exports":{".":{"import":"./index.js"}}}
JSON
  cat >"$cli/node_modules/@indigoai-us/hq-cloud/index.js" <<'JS'
export const loadCachedTokens = () => ({ idToken: "synthetic-test-token" });
JS

  printf 'failure context\n' >"$TMP/failure-context.md"
  payload="$(jq -cn --arg path "$TMP/failure-context.md" '{tool_name:"Edit",session_id:"failure-context-default",tool_input:{file_path:$path}}')"
  HOOK_OUT="$(cd "$TMP" && printf '%s' "$payload" | env \
    PATH="$fake_bin:$shim_dir:$PATH" TMPDIR="$default_tmp" CLAUDE_PROJECT_DIR="$TMP" \
    HQ_AUTOCOMMIT_TEST_REAL_GIT="$real_git" HQ_CLI_BIN="$cli/bin/hq" \
    HQ_FLAGS_API_URL="https://flags.invalid" HQ_COMPANY_UID=cmp_test123 \
    HQ_COMPANY_SLUG=indigo HQ_TEST_FLAG_ENABLED=true \
    bash .claude/hooks/hq-autocommit.sh 2>"$stderr_file")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "default PostToolUse failure must remain non-blocking; rc=$rc" >&2
    return 1
  fi
  if ! printf '%s' "$HOOK_OUT" | jq -e '
      .hookSpecificOutput.hookEventName == "PostToolUse" and
      (.hookSpecificOutput.additionalContext | contains("git commit exited 23"))
    ' >/dev/null 2>&1; then
    echo "enabled git failure must emit PostToolUse additionalContext JSON; stdout was: $HOOK_OUT" >&2
    return 1
  fi
  if ! grep -Fq 'WARNING: HQ autosave failed — git commit exited 23' "$stderr_file"; then
    echo "default failure must retain the human-readable stderr warning" >&2
    return 1
  fi
  if ! grep -Fq 'FAIL stage=commit exit=23' "$TMP/workspace/logs/hq-autocommit.log"; then
    echo "failure must retain the existing durable log record" >&2
    return 1
  fi

  "$real_git" -C "$TMP" reset -q
  printf 'strict failure context\n' >"$TMP/failure-context-strict.md"
  payload="$(jq -cn --arg path "$TMP/failure-context-strict.md" '{tool_name:"Edit",session_id:"failure-context-strict",tool_input:{file_path:$path}}')"
  rc=0
  HOOK_OUT="$(cd "$TMP" && printf '%s' "$payload" | env \
    PATH="$fake_bin:$shim_dir:$PATH" TMPDIR="$strict_tmp" CLAUDE_PROJECT_DIR="$TMP" \
    HQ_AUTOCOMMIT_TEST_REAL_GIT="$real_git" HQ_CLI_BIN="$cli/bin/hq" \
    HQ_FLAGS_API_URL="https://flags.invalid" HQ_COMPANY_UID=cmp_test123 \
    HQ_COMPANY_SLUG=indigo HQ_TEST_FLAG_ENABLED=true HQ_AUTOCOMMIT_STRICT=1 \
    bash .claude/hooks/hq-autocommit.sh 2>"$strict_stderr")" || rc=$?
  if [[ "$rc" -ne 1 ]]; then
    echo "strict PostToolUse failure must keep exit 1; rc=$rc" >&2
    return 1
  fi
  if ! printf '%s' "$HOOK_OUT" | jq -e '
      .hookSpecificOutput.hookEventName == "PostToolUse" and
      (.hookSpecificOutput.additionalContext | contains("git commit exited 23"))
    ' >/dev/null 2>&1; then
    echo "strict enabled git failure must emit PostToolUse additionalContext JSON; stdout was: $HOOK_OUT" >&2
    return 1
  fi
  if ! grep -Fq 'WARNING: HQ autosave failed — git commit exited 23' "$strict_stderr"; then
    echo "strict failure must retain the human-readable stderr warning" >&2
    return 1
  fi

  "$real_git" -C "$TMP" reset -q
  printf 'default off failure context\n' >"$TMP/failure-context-off.md"
  payload="$(jq -cn --arg path "$TMP/failure-context-off.md" '{tool_name:"Edit",session_id:"failure-context-off",tool_input:{file_path:$path}}')"
  rc=0
  HOOK_OUT="$(cd "$TMP" && printf '%s' "$payload" | env \
    PATH="$shim_dir:$PATH" TMPDIR="$off_tmp" CLAUDE_PROJECT_DIR="$TMP" \
    HQ_AUTOCOMMIT_TEST_REAL_GIT="$real_git" \
    bash .claude/hooks/hq-autocommit.sh 2>"$strict_stderr")" || rc=$?
  if [[ "$rc" -ne 0 || "$HOOK_OUT" != *"HQ autosave failed"* ]]; then
    echo "missing flag configuration must keep the previous non-blocking warning; rc=$rc stdout=$HOOK_OUT" >&2
    return 1
  fi
  if printf '%s' "$HOOK_OUT" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null 2>&1; then
    echo "the default-off flag must not switch to model-context JSON" >&2
    return 1
  fi

  "$real_git" -C "$TMP" reset -q
  local node_bin="$TMP_PARENT/node-trace-bin" node_trace="$TMP_PARENT/node-calls"
  mkdir -p "$node_bin"
  cat >"$node_bin/node" <<'SHIM'
#!/usr/bin/env bash
printf 'node %s\n' "$*" >>"${HQ_AUTOCOMMIT_TEST_NODE_TRACE:?}"
printf 'false\n'
SHIM
  chmod +x "$node_bin/node"
  : >"$node_trace"
  printf 'unset flag inputs\n' >"$TMP/failure-context-unset-flags.md"
  payload="$(jq -cn --arg path "$TMP/failure-context-unset-flags.md" '{tool_name:"Edit",session_id:"failure-context-unset-flags",tool_input:{file_path:$path}}')"
  rc=0
  HOOK_OUT="$(cd "$TMP" && printf '%s' "$payload" | env \
    PATH="$node_bin:$shim_dir:$PATH" TMPDIR="$off_tmp" CLAUDE_PROJECT_DIR="$TMP" \
    HQ_AUTOCOMMIT_TEST_REAL_GIT="$real_git" HQ_AUTOCOMMIT_TEST_NODE_TRACE="$node_trace" \
    bash .claude/hooks/hq-autocommit.sh 2>"$strict_stderr")" || rc=$?
  if [[ "$rc" -ne 0 || "$HOOK_OUT" != *"HQ autosave failed"* ]]; then
    echo "unset flag inputs must keep the plain non-blocking warning; rc=$rc stdout=$HOOK_OUT" >&2
    return 1
  fi
  if [[ -s "$node_trace" ]]; then
    echo "node must not start when the flag URL and company UID are unset; calls: $(cat "$node_trace")" >&2
    return 1
  fi
}

if [[ -n "${HQ_AUTOCOMMIT_TEST_PATH_CASE:-}" ]]; then
  case "$HQ_AUTOCOMMIT_TEST_PATH_CASE" in
    linked-worktree) run_linked_worktree_case ;;
    auto-maintenance) run_auto_maintenance_disabled_case ;;
    windows-backslash) run_windows_style_path_case backslash ;;
    windows-forwardslash) run_windows_style_path_case forwardslash ;;
    unresolved-windows) run_unresolved_windows_path_case ;;
    windows-fallback) run_windows_fallback_path_case ;;
    failure-context) run_failure_context_case ;;
    *) echo "unknown path regression case: $HQ_AUTOCOMMIT_TEST_PATH_CASE" >&2; exit 2 ;;
  esac
  echo "hq-autocommit path regression $HQ_AUTOCOMMIT_TEST_PATH_CASE: ok"
  exit 0
fi

printf 'one\n' > "$TMP/notes.md"
payload='{"tool_name":"Edit","tool_input":{"file_path":"notes.md"}}'
(cd "$TMP" && printf '%s' "$payload" | .claude/hooks/hq-autocommit.sh)

git -C "$TMP" show --name-only --format=%s HEAD | grep -q "autosave(hq): notes.md"
git -C "$TMP" show --name-only --format= HEAD | grep -q "^notes.md$"

printf 'repo\n' > "$TMP/repos/public/app/file.txt"
payload_repo='{"tool_name":"Edit","tool_input":{"file_path":"repos/public/app/file.txt"}}'
(cd "$TMP" && printf '%s' "$payload_repo" | .claude/hooks/hq-autocommit.sh)

if git -C "$TMP" show --name-only --format= HEAD | grep -q "repos/public/app/file.txt"; then
  echo "repo path should not be autocommitted" >&2
  exit 1
fi

REAL_GIT="$(command -v git)"
SHIM_DIR="$TMP/git-shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/git" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

real_git="${HQ_AUTOCOMMIT_TEST_REAL_GIT:?}"
show_toplevel=0
previous=""

for arg in "$@"; do
  if [[ "$previous" == "rev-parse" && "$arg" == "--show-toplevel" ]]; then
    show_toplevel=1
    break
  fi
  previous="$arg"
done

if [[ "$show_toplevel" == "1" ]]; then
  top="$("$real_git" "$@")"
  printf 'C:%s\n' "$top"
else
  exec "$real_git" "$@"
fi
SHIM
chmod +x "$SHIM_DIR/git"
cat > "$SHIM_DIR/python3" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
chmod +x "$SHIM_DIR/python3"

printf 'windows\n' > "$TMP/windows-path.txt"
payload_windows='{"tool_name":"Edit","tool_input":{"file_path":"windows-path.txt"}}'
(
  cd "$TMP"
  export HQ_AUTOCOMMIT_TEST_REAL_GIT="$REAL_GIT"
  export PATH="$SHIM_DIR:$PATH"
  printf '%s' "$payload_windows" | .claude/hooks/hq-autocommit.sh
)

git -C "$TMP" show --name-only --format=%s HEAD | grep -q "autosave(hq): windows-path.txt"
git -C "$TMP" show --name-only --format= HEAD | grep -q "^windows-path.txt$"

mkdir -p "$TMP/workspace/nested"
git -C "$TMP/workspace/nested" init -q
git -C "$TMP/workspace/nested" config user.email "hq-autocommit-test"
git -C "$TMP/workspace/nested" config user.name "HQ Autocommit Test"
printf 'nested\n' > "$TMP/workspace/nested/file.txt"
head_before_nested="$(git -C "$TMP" rev-parse HEAD)"
payload_nested='{"tool_name":"Edit","tool_input":{"file_path":"workspace/nested/file.txt"}}'
(cd "$TMP" && printf '%s' "$payload_nested" | .claude/hooks/hq-autocommit.sh)

if [[ "$(git -C "$TMP" rev-parse HEAD)" != "$head_before_nested" ]]; then
  echo "nested repo path should not be autocommitted" >&2
  exit 1
fi

# A file under workspace/worktrees/ (a live project worktree) is never autosaved
# into the HQ root. (feedback_2ada615f)
mkdir -p "$TMP/workspace/worktrees/proj"
printf 'wt\n' > "$TMP/workspace/worktrees/proj/notes.md"
head_before_wt="$(git -C "$TMP" rev-parse HEAD)"
payload_wt='{"tool_name":"Edit","tool_input":{"file_path":"workspace/worktrees/proj/notes.md"}}'
(cd "$TMP" && printf '%s' "$payload_wt" | .claude/hooks/hq-autocommit.sh)

if [[ "$(git -C "$TMP" rev-parse HEAD)" != "$head_before_wt" ]]; then
  echo "workspace/worktrees path should not be autocommitted" >&2
  exit 1
fi

# Gitlink guard: a directory add that would sweep a nested repo into the HQ root
# as an embedded gitlink (mode 160000) is refused — no commit, nothing staged.
# (feedback_2ada615f)
mkdir -p "$TMP/holder/inner"
git -C "$TMP/holder/inner" init -q
git -C "$TMP/holder/inner" config user.email "hq-autocommit-test"
git -C "$TMP/holder/inner" config user.name "HQ Autocommit Test"
printf 'inner\n' > "$TMP/holder/inner/f.txt"
git -C "$TMP/holder/inner" add -A
git -C "$TMP/holder/inner" commit -q -m "inner"
printf 'plain\n' > "$TMP/holder/plain.txt"
head_before_gitlink="$(git -C "$TMP" rev-parse HEAD)"
payload_gitlink='{"tool_name":"Edit","tool_input":{"file_path":"holder"}}'
(cd "$TMP" && printf '%s' "$payload_gitlink" | .claude/hooks/hq-autocommit.sh)

if [[ "$(git -C "$TMP" rev-parse HEAD)" != "$head_before_gitlink" ]]; then
  echo "directory add sweeping a gitlink should not be autocommitted" >&2
  exit 1
fi
if git -C "$TMP" ls-files --stage | awk '$1 == "160000" { exit 0 } END { exit 1 }'; then
  echo "gitlink (mode 160000) must not remain staged in the HQ root" >&2
  exit 1
fi

# ── Failure visibility (B4) ─────────────────────────────────────────────────
# The hook used to end every git call with `|| exit 0` and funnel all output to
# /tmp, so an orphaned .git/index.lock stopped autosave for hours while printing
# nothing anywhere. A git failure must now leave a durable record and say so.

LOG_REL="workspace/logs/hq-autocommit.log"
LOG="$TMP/$LOG_REL"

run_hook() {
  # run_hook <session-id> <rel-path> [env assignments...] -> stdout, sets HOOK_RC
  local session="$1" rel="$2"
  shift 2
  local payload
  payload="$(printf '{"tool_name":"Edit","session_id":"%s","tool_input":{"file_path":"%s"}}' "$session" "$rel")"
  HOOK_RC=0
  HOOK_OUT="$(cd "$TMP" && printf '%s' "$payload" | env "$@" bash .claude/hooks/hq-autocommit.sh 2>/dev/null)" || HOOK_RC=$?
}

REAL_GIT="$(command -v git)"
INDEX_LOCK_GIT_SHIM_DIR="$TMP/index-lock-git-shim"
mkdir -p "$INDEX_LOCK_GIT_SHIM_DIR"
cat >"$INDEX_LOCK_GIT_SHIM_DIR/git" <<'SHIM'
#!/usr/bin/env python3
import os
import shlex
import sys
from pathlib import Path
import subprocess

args = sys.argv[1:]
trace = Path(os.environ["HQ_AUTOCOMMIT_TEST_GIT_TRACE"])
with trace.open("a") as handle:
    handle.write("git " + " ".join(shlex.quote(arg) for arg in args) + "\n")

real_git = os.environ["HQ_AUTOCOMMIT_TEST_REAL_GIT"]
root = os.environ.get("HQ_AUTOCOMMIT_TEST_ROOT", "")
if len(args) >= 5 and args[:3] == ["-C", root, "add"] and args[3] == "--":
    attempts_file = Path(os.environ["HQ_AUTOCOMMIT_TEST_ATTEMPTS"])
    try:
        attempts = int(attempts_file.read_text().strip() or "0")
    except FileNotFoundError:
        attempts = 0
    attempts += 1
    attempts_file.write_text(f"{attempts}\n")
    lock_path = Path(root) / ".git" / "index.lock"

    if attempts > 4:
        print("test stub stopped an unbounded git add retry loop", file=sys.stderr)
        sys.exit(97)
    mode = os.environ["HQ_AUTOCOMMIT_TEST_ADD_MODE"]
    if mode == "persistent" or attempts == 1:
        lock_path.touch()
        message = "File exists" if mode != "locale" or os.environ.get("LC_ALL") == "C" else "Datei existiert"
        print(f"fatal: Unable to create '{lock_path}': {message}.", file=sys.stderr)
        sys.exit(128)

    if mode == "foreign-staged" and attempts == 2:
        concurrent_index = Path(root) / ".git" / "index.concurrent"
        env = os.environ.copy()
        env["LC_ALL"] = "C"
        env["GIT_INDEX_FILE"] = str(concurrent_index)
        subprocess.run([real_git, "-C", root, "read-tree", "HEAD"], env=env, check=True)
        subprocess.run([real_git, "-C", root, "add", "--", "manually-staged.md"], env=env, check=True)
        os.replace(concurrent_index, Path(root) / ".git" / "index")
        lock_path.unlink(missing_ok=True)
    elif mode in ("transient", "locale") and attempts == 2:
        lock_path.unlink(missing_ok=True)

env = os.environ.copy()
env["LC_ALL"] = "C"
os.execve(real_git, [real_git, *args], env)
SHIM
chmod +x "$INDEX_LOCK_GIT_SHIM_DIR/git"

run_index_lock_retry_case() {
  local mode="$1" rel="$2" attempts_file head_before staged_paths git_trace_file mode_tmpdir
  mode_tmpdir="$TMP_PARENT/tmp/$mode"
  mkdir -p "$mode_tmpdir"
  if [[ -e "$mode_tmpdir/hq-autocommit.lock" ]]; then
    echo "index-lock $mode case started with a stale hook lock; owner: $(cat "$mode_tmpdir/hq-autocommit.lock/owner" 2>/dev/null || echo missing)" >&2
    return 1
  fi
  staged_paths="$(git -C "$TMP" diff --cached --name-only)"
  if [[ -n "$staged_paths" ]]; then
    echo "index-lock $mode case requires a clean fixture index; staged paths: $staged_paths" >&2
    return 1
  fi
  attempts_file="$TMP/$mode-add-attempts"
  git_trace_file="$TMP/$mode-git-trace"
  printf '%s contention\n' "$mode" >"$TMP/$rel"
  if [[ "$mode" == "foreign-staged" ]]; then
    printf 'manual stage during retry\n' >"$TMP/manually-staged.md"
  fi
  head_before="$(git -C "$TMP" rev-parse HEAD)"
  if [[ "$mode" == "locale" ]]; then
    run_hook "sess-index-lock-$mode" "$rel" \
      PATH="$INDEX_LOCK_GIT_SHIM_DIR:$PATH" \
      TMPDIR="$mode_tmpdir" \
      HQ_AUTOCOMMIT_TEST_REAL_GIT="$REAL_GIT" \
      HQ_AUTOCOMMIT_TEST_ROOT="$TMP" \
      HQ_AUTOCOMMIT_TEST_ATTEMPTS="$attempts_file" \
      HQ_AUTOCOMMIT_TEST_GIT_TRACE="$git_trace_file" \
      HQ_AUTOCOMMIT_TEST_ADD_MODE="$mode" \
      LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8 \
      HQ_AUTOCOMMIT_STRICT=1
  else
    run_hook "sess-index-lock-$mode" "$rel" \
      PATH="$INDEX_LOCK_GIT_SHIM_DIR:$PATH" \
      TMPDIR="$mode_tmpdir" \
      HQ_AUTOCOMMIT_TEST_REAL_GIT="$REAL_GIT" \
      HQ_AUTOCOMMIT_TEST_ROOT="$TMP" \
      HQ_AUTOCOMMIT_TEST_ATTEMPTS="$attempts_file" \
      HQ_AUTOCOMMIT_TEST_GIT_TRACE="$git_trace_file" \
      HQ_AUTOCOMMIT_TEST_ADD_MODE="$mode" \
      HQ_AUTOCOMMIT_STRICT=1
  fi

  if [[ "$mode" == "locale" || "$mode" == "foreign-staged" ]]; then
    if [[ ! -f "$attempts_file" ]]; then
      echo "$mode index.lock contention did not reach the git-add shim; rc=$HOOK_RC out='$HOOK_OUT'; trace='$(cat "$git_trace_file" 2>/dev/null || true)'; process_lock='$([[ -e "$mode_tmpdir/hq-autocommit.lock" ]] && cat "$mode_tmpdir/hq-autocommit.lock/owner" 2>/dev/null || echo absent)'; staged='$(git -C "$TMP" diff --cached --name-only)'; log='$(cat "$LOG")'" >&2
      return 1
    fi
    local observed_attempts
    observed_attempts="$(cat "$attempts_file")"
    if [[ "$observed_attempts" -ne 2 ]]; then
      echo "$mode index.lock contention should use exactly two add attempts (got $observed_attempts); hook='$HOOK_OUT'; log='$(cat "$LOG")'" >&2
      return 1
    fi
  fi

  if [[ "$mode" == "foreign-staged" ]]; then
    if [[ "$(git -C "$TMP" rev-parse HEAD)" != "$head_before" ]]; then
      echo "autosave must not commit a foreign path staged during the retry window" >&2
      return 1
    fi
    if ! git -C "$TMP" diff --cached --name-only -- manually-staged.md | grep -Fqx 'manually-staged.md'; then
      echo "foreign manually staged path must remain staged after autosave skips" >&2
      return 1
    fi
    if ! grep -Fq 'SKIP stage=foreign-staged' "$LOG"; then
      echo "foreign staged path must log SKIP stage=foreign-staged" >&2
      return 1
    fi
    if ! git -C "$TMP" diff --cached --quiet -- "$rel"; then
      echo "the autosave target must be unstaged when a foreign staged path appears" >&2
      return 1
    fi
    git -C "$TMP" reset -q -- manually-staged.md
    return 0
  fi

  if [[ "$mode" == "transient" || "$mode" == "locale" ]]; then
    if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
      echo "$mode index.lock contention should autosave silently; rc=$HOOK_RC out='$HOOK_OUT'" >&2
      return 1
    fi
    if [[ "$(cat "$attempts_file")" -ne 2 ]]; then
      echo "$mode index.lock contention should use exactly two add attempts" >&2
      return 1
    fi
    if [[ -e "$TMP/.git/index.lock" ]]; then
      echo "the synthetic $mode index.lock should be released before the successful add" >&2
      return 1
    fi
    if ! git -C "$TMP" show --name-only --format= HEAD | grep -Fqx "$rel"; then
      echo "$mode index.lock contention did not commit $rel" >&2
      return 1
    fi
    return 0
  fi

  if [[ "$HOOK_RC" -eq 0 || "$HOOK_OUT" != *"HQ autosave failed"* ]]; then
    echo "persistent index.lock contention should report the add failure; rc=$HOOK_RC out='$HOOK_OUT'" >&2
    return 1
  fi
  if [[ "$(cat "$attempts_file")" -ne 4 ]]; then
    echo "persistent index.lock contention should stop after four total add attempts" >&2
    return 1
  fi
  if [[ "$(git -C "$TMP" rev-parse HEAD)" != "$head_before" ]]; then
    echo "persistent index.lock contention must not commit $rel" >&2
    return 1
  fi
  if ! grep -Fq 'FAIL stage=add' "$LOG" || ! grep -Fq 'index.lock' "$LOG"; then
    echo "persistent index.lock contention must retain the add failure details" >&2
    return 1
  fi
  if [[ ! -e "$TMP/.git/index.lock" ]]; then
    echo "the hook must leave the fresh persistent index.lock untouched" >&2
    return 1
  fi
  rm -f -- "$TMP/.git/index.lock"
}

case "${HQ_AUTOCOMMIT_TEST_INDEX_LOCK_CASE:-}" in
  transient)
    run_index_lock_retry_case transient transient-index-lock.md
    echo "hq-autocommit transient index.lock retry: ok"
    exit 0
    ;;
  persistent)
    run_index_lock_retry_case persistent persistent-index-lock.md
    echo "hq-autocommit persistent index.lock retry: ok"
    exit 0
    ;;
  foreign-staged)
    run_index_lock_retry_case foreign-staged retry-with-foreign-staged.md
    echo "hq-autocommit foreign staged path during index.lock retry: ok"
    exit 0
    ;;
  locale)
    run_index_lock_retry_case locale locale-index-lock.md
    echo "hq-autocommit index.lock retry under non-English locale: ok"
    exit 0
    ;;
  "")
    run_index_lock_retry_case transient transient-index-lock.md
    run_index_lock_retry_case persistent persistent-index-lock.md
    run_index_lock_retry_case locale locale-index-lock.md
    run_index_lock_retry_case foreign-staged retry-with-foreign-staged.md
    ;;
  *) echo "unknown index-lock regression case: $HQ_AUTOCOMMIT_TEST_INDEX_LOCK_CASE" >&2; exit 2 ;;
esac

printf 'blocked\n' > "$TMP/wedged.md"
: > "$TMP/.git/index.lock"
head_before_fail="$(git -C "$TMP" rev-parse HEAD)"

run_hook "sess-a" "wedged.md"
if [[ "$HOOK_RC" -ne 0 ]]; then
  echo "a git failure must not block the editor (expected exit 0, got $HOOK_RC)" >&2
  exit 1
fi
if [[ "$HOOK_OUT" != *"HQ autosave failed"* ]]; then
  echo "a git failure must emit a visible warning; got: '$HOOK_OUT'" >&2
  exit 1
fi
if [[ ! -f "$LOG" ]]; then
  echo "a git failure must be recorded in $LOG_REL" >&2
  exit 1
fi
if ! grep -q "FAIL stage=add" "$LOG"; then
  echo "failure log must name the git stage that failed" >&2
  exit 1
fi
if ! grep -q "index.lock" "$LOG"; then
  echo "failure log must retain git's own error text" >&2
  exit 1
fi
if [[ "$(git -C "$TMP" rev-parse HEAD)" != "$head_before_fail" ]]; then
  echo "nothing should have been committed while the index was locked" >&2
  exit 1
fi

# Same session, same cause: logged again, but warned about only once. A wedged
# repo fails on every edit and a warning per edit trains the user to ignore it.
fail_lines_before="$(grep -c "FAIL stage=add" "$LOG" || true)"
printf 'blocked again\n' > "$TMP/wedged.md"
run_hook "sess-a" "wedged.md"
if [[ -n "$HOOK_OUT" ]]; then
  echo "repeat failure in the same session must not re-warn; got: '$HOOK_OUT'" >&2
  exit 1
fi
if [[ "$(grep -c "FAIL stage=add" "$LOG" || true)" -le "$fail_lines_before" ]]; then
  echo "every failure must still be logged, even when the warning is deduped" >&2
  exit 1
fi

# HQ_AUTOCOMMIT_STRICT makes "did autosave work" machine-readable.
run_hook "sess-b" "wedged.md" HQ_AUTOCOMMIT_STRICT=1
if [[ "$HOOK_RC" -eq 0 ]]; then
  echo "HQ_AUTOCOMMIT_STRICT=1 must exit non-zero on a git failure" >&2
  exit 1
fi

rm -f "$TMP/.git/index.lock"

# A stale index lock with no live holder is recovered automatically. The
# probe seam returns non-zero for "unowned" so this remains deterministic on
# CI images that do not install lsof/fuser.
printf 'recovered index\n' > "$TMP/recovered-index.md"
: > "$TMP/.git/index.lock"
touch -t 202001010000 "$TMP/.git/index.lock"
run_hook "sess-index-recover" "recovered-index.md" \
  HQ_AUTOCOMMIT_LOCK_PROBE=false
if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
  echo "an unowned stale index lock should self-heal silently; rc=$HOOK_RC out='$HOOK_OUT'" >&2
  exit 1
fi
if [[ -e "$TMP/.git/index.lock" ]]; then
  echo "the recovered stale index lock must be removed" >&2
  exit 1
fi
if ! git -C "$TMP" show --name-only --format= HEAD | grep -q '^recovered-index.md$'; then
  echo "autosave must continue after recovering a stale index lock" >&2
  exit 1
fi
if ! grep -q "RECOVER stage=index-lock" "$LOG"; then
  echo "stale index-lock recovery must be recorded in $LOG_REL" >&2
  exit 1
fi

# A healthy commit stays completely silent and adds no failure record.
fail_lines_healthy="$(grep -c "FAIL " "$LOG" || true)"
printf 'healthy\n' > "$TMP/healthy.md"
run_hook "sess-c" "healthy.md"
if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
  echo "a successful autosave must stay silent; rc=$HOOK_RC out='$HOOK_OUT'" >&2
  exit 1
fi
git -C "$TMP" show --name-only --format=%s HEAD | grep -q "autosave(hq): healthy.md"
if [[ "$(grep -c "FAIL " "$LOG" || true)" -ne "$fail_lines_healthy" ]]; then
  echo "a successful autosave must not write a failure record" >&2
  exit 1
fi

# An unchanged file is "nothing to commit", not a failure.
run_hook "sess-c" "healthy.md"
if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
  echo "a no-op autosave must stay silent; rc=$HOOK_RC out='$HOOK_OUT'" >&2
  exit 1
fi
if [[ "$(grep -c "FAIL " "$LOG" || true)" -ne "$fail_lines_healthy" ]]; then
  echo "a no-op autosave must not write a failure record" >&2
  exit 1
fi

# Live contention is normal and silent; an orphaned lock suppresses every
# autosave indefinitely, so it gets said out loud once.
printf 'contended\n' > "$TMP/contended.md"
mkdir -p "$TMPDIR/hq-autocommit.lock"
run_hook "sess-d" "contended.md"
if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
  echo "fresh lock contention must stay silent; rc=$HOOK_RC out='$HOOK_OUT'" >&2
  exit 1
fi

owner_birth="$(LC_ALL=C ps -p "$$" -o lstart= 2>/dev/null | tr -d '[:space:]' || true)"
printf 'pid=%s\nbirth=%s\n' "$$" "$owner_birth" > "$TMPDIR/hq-autocommit.lock/owner"
touch -t 202001010000 "$TMPDIR/hq-autocommit.lock"
run_hook "sess-live-lock" "contended.md"
if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
  echo "a stale-looking lock with a live owner must stay untouched and silent" >&2
  exit 1
fi
if [[ ! -d "$TMPDIR/hq-autocommit.lock" ]]; then
  echo "a live owner's autosave lock must never be recovered" >&2
  exit 1
fi

if [[ -n "$owner_birth" ]]; then
  # A stale lock carrying a live but reused PID must be recoverable when the
  # process birth token does not match the original owner.
  printf 'pid=%s\nbirth=%s\n' "$$" "different-process" > "$TMPDIR/hq-autocommit.lock/owner"
  touch -t 202001010000 "$TMPDIR/hq-autocommit.lock"
  run_hook "sess-reused-pid" "contended.md"
  if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
    echo "a reused PID lock should self-heal silently; rc=$HOOK_RC out='$HOOK_OUT'" >&2
    exit 1
  fi
  if [[ -d "$TMPDIR/hq-autocommit.lock" ]]; then
    echo "a reused PID must not keep an orphaned autosave lock alive" >&2
    exit 1
  fi
else
  rm -f "$TMPDIR/hq-autocommit.lock/owner"
  rmdir "$TMPDIR/hq-autocommit.lock"
fi

# Recreate an ownerless stale lock to exercise the legacy recovery path too.
mkdir -p "$TMPDIR/hq-autocommit.lock"
printf 'contended-again\n' > "$TMP/contended.md"

rm -f "$TMPDIR/hq-autocommit.lock/owner"
touch -t 202001010000 "$TMPDIR/hq-autocommit.lock"
run_hook "sess-e" "contended.md"
if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
  echo "an unowned stale autosave lock should self-heal silently; rc=$HOOK_RC out='$HOOK_OUT'" >&2
  exit 1
fi
if [[ -d "$TMPDIR/hq-autocommit.lock" ]]; then
  echo "the recovered stale autosave lock must be removed after the hook exits" >&2
  exit 1
fi
if ! grep -q "RECOVER stage=lock" "$LOG"; then
  echo "stale autosave-lock recovery must be recorded in $LOG_REL" >&2
  exit 1
fi
if ! git -C "$TMP" show --name-only --format= HEAD | grep -q '^contended.md$'; then
  echo "autosave must continue after recovering its stale process lock" >&2
  exit 1
fi

# --- macOS Finder Icon\r / control-character paths -------------------------
# Finder writes a file literally named `Icon` + CR into every directory it
# renders a custom icon for, and a folder-level cloud-sync agent spreads them
# tree-wide. Once one is committed, Finder rewriting it makes it a tracked
# modification that autosave would re-commit forever. They also cannot sync:
# an S3 key may not contain a control character, so each is a permanent
# per-file upload failure. Autosave must never stage one.

icon_name="Icon"$'\r'

# Direct hit: the tool call names the control-char path itself. The JSON
# payload carries it as an escaped \r, which jq decodes back to a real CR.
printf 'finder cruft\n' > "$TMP/$icon_name"
head_before_icon="$(git -C "$TMP" rev-parse HEAD)"
HOOK_RC=0
HOOK_OUT="$(cd "$TMP" \
  && printf '{"tool_name":"Edit","session_id":"sess-icon","tool_input":{"file_path":"Icon\\r"}}' \
  | bash .claude/hooks/hq-autocommit.sh 2>/dev/null)" || HOOK_RC=$?
if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
  echo "an Icon\\r autosave must be a silent no-op; rc=$HOOK_RC out='$HOOK_OUT'" >&2
  exit 1
fi
if [[ "$(git -C "$TMP" rev-parse HEAD)" != "$head_before_icon" ]]; then
  echo "an Icon\\r path must never be committed" >&2
  exit 1
fi
if git -C "$TMP" ls-files -z | tr '\0' '\n' | grep -q "^Icon"; then
  echo "an Icon\\r path must never become tracked" >&2
  exit 1
fi

# Directory sweep: the tool call names a DIRECTORY, so `git add -- <dir>`
# reaches every file beneath it. The legitimate file must still be committed
# and the control-char sibling must be left behind — this is the path that
# actually made `.agents/Icon\r` tracked on the reporting machine.
mkdir -p "$TMP/docs"
printf 'real content\n' > "$TMP/docs/page.md"
printf 'finder cruft\n' > "$TMP/docs/$icon_name"
HOOK_RC=0
HOOK_OUT="$(cd "$TMP" \
  && printf '{"tool_name":"Edit","session_id":"sess-icon-dir","tool_input":{"file_path":"docs"}}' \
  | bash .claude/hooks/hq-autocommit.sh 2>/dev/null)" || HOOK_RC=$?
if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
  echo "a directory autosave alongside Icon\\r must stay silent; rc=$HOOK_RC out='$HOOK_OUT'" >&2
  exit 1
fi
if ! git -C "$TMP" show --name-only --format= HEAD | grep -q "^docs/page.md$"; then
  echo "the legitimate file in the directory must still be autosaved" >&2
  exit 1
fi
if git -C "$TMP" ls-files -z | tr '\0' '\n' | grep -q "^docs/Icon"; then
  echo "a directory add must not sweep in an Icon\\r sibling" >&2
  exit 1
fi
# The staged control-char entry is dropped, so it must not linger in the index.
if git -C "$TMP" diff --cached --name-only -z | tr '\0' '\n' | grep -q "Icon"; then
  echo "an Icon\\r path must not be left staged in the index" >&2
  exit 1
fi

run_linked_worktree_case
run_windows_style_path_case backslash
run_windows_style_path_case forwardslash
run_unresolved_windows_path_case
run_windows_fallback_path_case

echo "hq-autocommit smoke: ok"
