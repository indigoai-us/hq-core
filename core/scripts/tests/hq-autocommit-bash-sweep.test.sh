#!/usr/bin/env bash
# hq-core: public
# Hermetic tests for the opt-in Stop-time sweep of files written by Bash.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR/../../.." rev-parse --show-toplevel)"
SOURCE_ROOT="${HQ_AUTOCOMMIT_BASH_TEST_SOURCE_ROOT:-$ROOT}"
TMP_PARENT="$(mktemp -d)"
trap 'rm -rf "$TMP_PARENT"' EXIT
HOME="$TMP_PARENT/home"
XDG_CONFIG_HOME="$TMP_PARENT/config"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
export HOME XDG_CONFIG_HOME GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset HQ_FLAGS_API_URL HQ_COMPANY_UID HQ_COMPANY_SLUG HQ_CLI_BIN AWS_PROFILE \
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN \
  AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
  AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_AUTHORIZATION_TOKEN

REAL_NODE="$(command -v node)"
"$REAL_NODE" "$SCRIPT_DIR/hq-autocommit-bash-flag-reach.test.cjs" \
  "$SOURCE_ROOT/.claude/hooks/hq-autocommit-bash-flag.cjs" "$TMP_PARENT/flag-reach-fixtures"

FAKE_BIN="$TMP_PARENT/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/node" <<'NODE'
#!/usr/bin/env bash
if [[ "${1:-}" == *"hq-autocommit-bash-flag.cjs" ]]; then
  printf '%s\n' "${HQ_AUTOCOMMIT_BASH_TEST_FLAG:-false}"
  exit 0
fi
exec "$HQ_AUTOCOMMIT_BASH_TEST_REAL_NODE" "$@"
NODE
chmod +x "$FAKE_BIN/node"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

make_repo() {
  local name="$1" repo="$TMP_PARENT/$1"
  mkdir -p "$repo/.claude/hooks" "$repo/core" "$repo/workspace/ignored" \
    "$repo/repos/public/sample" "$TMP_PARENT/tmp-$name"
  printf 'hqVersion: synthetic-test\n' > "$repo/core/core.yaml"
  printf 'workspace/ignored/**\n' > "$repo/.gitignore"
  printf 'tracked but ignored baseline\n' > "$repo/workspace/ignored/tracked.txt"
  cp "$SOURCE_ROOT/.claude/hooks/hq-autocommit.sh" "$repo/.claude/hooks/hq-autocommit.sh"
  if [[ -f "$SOURCE_ROOT/.claude/hooks/hq-autocommit-bash-sweep.sh" ]]; then
    cp "$SOURCE_ROOT/.claude/hooks/hq-autocommit-bash-sweep.sh" "$repo/.claude/hooks/hq-autocommit-bash-sweep.sh"
  fi
  if [[ -f "$SOURCE_ROOT/.claude/hooks/hq-autocommit-bash-flag.cjs" ]]; then
    cp "$SOURCE_ROOT/.claude/hooks/hq-autocommit-bash-flag.cjs" "$repo/.claude/hooks/hq-autocommit-bash-flag.cjs"
  fi
  chmod +x "$repo/.claude/hooks/hq-autocommit.sh"
  [[ ! -f "$repo/.claude/hooks/hq-autocommit-bash-sweep.sh" ]] || chmod +x "$repo/.claude/hooks/hq-autocommit-bash-sweep.sh"
  git -C "$repo" init -q
  git -C "$repo" config user.email synthetic@example.test
  git -C "$repo" config user.name 'Synthetic HQ Test'
  git -C "$repo" add .gitignore core/core.yaml .claude/hooks/hq-autocommit.sh
  if [[ -f "$repo/.claude/hooks/hq-autocommit-bash-sweep.sh" ]]; then
    git -C "$repo" add .claude/hooks/hq-autocommit-bash-sweep.sh .claude/hooks/hq-autocommit-bash-flag.cjs
  fi
  git -C "$repo" add -f workspace/ignored/tracked.txt
  git -C "$repo" commit -q -m synthetic-baseline
  printf '%s' "$repo"
}

run_sweep() {
  local repo="$1" flag="$2" payload
  payload='{"tool_name":"Stop","session_id":"us165-synthetic-session"}'
  if [[ -x "$repo/.claude/hooks/hq-autocommit-bash-sweep.sh" ]]; then
    printf '%s' "$payload" | env -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID -u HQ_COMPANY_SLUG \
      -u HQ_CLI_BIN CLAUDE_PROJECT_DIR="$repo" HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
      TMPDIR="$TMP_PARENT/tmp-${repo##*/}" PATH="$FAKE_BIN:$PATH" \
      HQ_AUTOCOMMIT_BASH_TEST_REAL_NODE="$REAL_NODE" HQ_AUTOCOMMIT_BASH_TEST_FLAG="$flag" \
      bash "$repo/.claude/hooks/hq-autocommit-bash-sweep.sh"
  else
    # Baseline behavior: the Edit/Write/MultiEdit hook ignores Stop/Bash-shaped input.
    printf '%s' "$payload" | env CLAUDE_PROJECT_DIR="$repo" HOME="$HOME" \
      XDG_CONFIG_HOME="$XDG_CONFIG_HOME" TMPDIR="$TMP_PARENT/tmp-${repo##*/}" \
      bash "$repo/.claude/hooks/hq-autocommit.sh"
  fi
}

assert_committed() {
  local repo="$1" rel="$2"
  git -C "$repo" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 \
    || fail "expected $rel to be committed"
  git -C "$repo" show --format= --name-only HEAD | grep -Fqx -- "$rel" \
    || fail "latest autosave commit did not include $rel"
}

# RED on origin/main: the Bash-shaped event is ignored by the current hook.
repo="$(make_repo baseline-red)"
printf 'written by synthetic Bash command\n' > "$repo/workspace/bash-created.txt"
before="$(git -C "$repo" rev-parse HEAD)"
run_sweep "$repo" true
if [[ "$(git -C "$repo" rev-parse HEAD)" == "$before" ]]; then
  fail "Bash-written HQ file was not autosaved"
fi
assert_committed "$repo" workspace/bash-created.txt
pass "Bash-written HQ file is committed when the sweep flag is on"

# Default-off behavior leaves a Bash-written file uncommitted.
repo="$(make_repo flag-off)"
printf 'not committed while flag is off\n' > "$repo/workspace/off.txt"
before="$(git -C "$repo" rev-parse HEAD)"
run_sweep "$repo" false
[[ "$(git -C "$repo" rev-parse HEAD)" == "$before" ]] || fail "flag-off sweep committed a file"
[[ -z "$(git -C "$repo" diff --cached --name-only)" ]] || fail "flag-off sweep staged a file"
pass "Bash-written HQ file stays uncommitted while the injected flag is off"

# Ignored and repos/ paths are never staged, even when the sweep is enabled.
repo="$(make_repo excluded-paths)"
printf 'modified ignored content\n' > "$repo/workspace/ignored/tracked.txt"
printf 'new ignored content\n' > "$repo/workspace/ignored/new.txt"
printf 'repo-owned content\n' > "$repo/repos/public/sample/payload.txt"
before="$(git -C "$repo" rev-parse HEAD)"
run_sweep "$repo" true
[[ "$(git -C "$repo" rev-parse HEAD)" == "$before" ]] || fail "ignored or repos/ path was committed"
[[ -z "$(git -C "$repo" diff --cached --name-only)" ]] || fail "ignored or repos/ path was staged"
git -C "$repo" ls-files --error-unmatch -- workspace/ignored/tracked.txt repos/public/sample/payload.txt >/dev/null 2>&1 \
  && fail "ignored or repos/ path became tracked"
pass "ignored and repos/ paths are not staged"

# More than the documented cap skips the entire sweep and records the reason.
repo="$(make_repo over-cap)"
mkdir -p "$repo/workspace/batch"
for index in $(seq 1 21); do
  printf 'synthetic batch %s\n' "$index" > "$repo/workspace/batch/file-$index.txt"
done
before="$(git -C "$repo" rev-parse HEAD)"
run_sweep "$repo" true
[[ "$(git -C "$repo" rev-parse HEAD)" == "$before" ]] || fail "over-cap sweep committed files"
[[ -z "$(git -C "$repo" diff --cached --name-only)" ]] || fail "over-cap sweep staged files"
grep -Fq 'SKIP stage=bash-sweep reason=path-cap changed=21 cap=20' "$repo/workspace/logs/hq-autocommit.log" \
  || fail "over-cap sweep did not log its skip reason"
pass "21 changed paths exceed the cap of 20 and are skipped with a log entry"

# The new gated Stop hook must be reachable in the same profiles as hq-autocommit.
. "$SOURCE_ROOT/.claude/hooks/hook-gate.sh" --lib
is_in_standard_profile hq-autocommit-bash-sweep || fail "sweep hook missing from standard profile"
is_in_strict_profile hq-autocommit-bash-sweep || fail "sweep hook missing from strict profile"
! is_in_minimal_profile hq-autocommit-bash-sweep || fail "sweep hook must not run in minimal profile"
jq -e '.hooks.Stop[] | select(.matcher == "") | .hooks[] | select(.id == "hq-autocommit-bash-sweep" and .gated == true)' \
  "$SOURCE_ROOT/.claude/hooks/hook-registry.json" >/dev/null || fail "gated Stop registration missing"
pass "gated Stop registration is standard/strict only"

echo "hq-autocommit-bash-sweep: all checks passed"
