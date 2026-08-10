#!/usr/bin/env bash
# hq-core: public
# Regression tests for block-hq-worktree-session.sh.
#
# The guard must fire on exactly one thing — a Claude session running HQ itself
# from a linked git worktree — and must stay silent on the worktree flow HQ
# depends on (editing a checkout under repos/ from workspace/worktrees/).
#
# Layout built below mirrors a real install:
#   $TMP/hq                              main HQ checkout      (allowed)
#   $TMP/hq-worktree                     linked worktree of HQ (BLOCKED)
#   $TMP/hq/repos/private/app            nested source repo    (allowed)
#   $TMP/hq/workspace/worktrees/app/x    worktree of app       (allowed)

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/block-hq-worktree-session.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git_quiet() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t "$@"; }

# --- Fake HQ root -----------------------------------------------------------
mkdir -p "$TMP/hq"
git_quiet -C "$TMP/hq" init -q
printf 'hq\n' > "$TMP/hq/README.md"
git_quiet -C "$TMP/hq" add README.md
git_quiet -C "$TMP/hq" commit -qm init
git_quiet -C "$TMP/hq" worktree add -q -b wt "$TMP/hq-worktree" >/dev/null 2>&1

# --- Nested source repo + its own worktree (the sanctioned editing flow) ----
mkdir -p "$TMP/hq/repos/private/app"
git_quiet -C "$TMP/hq/repos/private/app" init -q
printf 'app\n' > "$TMP/hq/repos/private/app/README.md"
git_quiet -C "$TMP/hq/repos/private/app" add README.md
git_quiet -C "$TMP/hq/repos/private/app" commit -qm init
mkdir -p "$TMP/hq/workspace/worktrees/app"
git_quiet -C "$TMP/hq/repos/private/app" worktree add -q -b feat \
  "$TMP/hq/workspace/worktrees/app/x" >/dev/null 2>&1

mkdir -p "$TMP/not-a-repo"

# --- Git for Windows path aliases ------------------------------------------
# Git Bash can spell the same checkout as /c/... while Git itself emits C:/....
# Mock that split so this regression remains runnable on Linux.
WINDOWS_HQ="$TMP/windows-hq"
WINDOWS_BIN="$TMP/windows-bin"
mkdir -p "$WINDOWS_HQ/core/scripts" "$WINDOWS_BIN"
cp "$ROOT/core/scripts/hook-lib.sh" "$WINDOWS_HQ/core/scripts/hook-lib.sh"

cat > "$WINDOWS_BIN/git" <<'WINDOWS_GIT'
#!/usr/bin/env bash
case "$*" in
  *"rev-parse --absolute-git-dir"*) printf '%s\n' 'C:/hq-test/.git' ;;
  *"rev-parse --git-common-dir"*) printf '%s\n' '.git' ;;
  *"rev-parse --show-toplevel"*) printf '%s\n' 'C:/hq-test' ;;
  *"worktree list --porcelain"*) printf '%s\n' 'worktree C:/hq-test' ;;
  *) exit 1 ;;
esac
WINDOWS_GIT

cat > "$WINDOWS_BIN/realpath" <<WINDOWS_REALPATH
#!/usr/bin/env bash
case "\${1:-}" in
  "$WINDOWS_HQ"*) printf '/c/hq-test%s\n' "\${1#"$WINDOWS_HQ"}" ;;
  *) printf '%s\n' "\${1:-}" ;;
esac
WINDOWS_REALPATH

cat > "$WINDOWS_BIN/cygpath" <<'WINDOWS_CYGPATH'
#!/usr/bin/env bash
path="${2:-${1:-}}"
case "$path" in
  /c/*) printf 'C:/%s\n' "${path#/c/}" ;;
  *) printf '%s\n' "$path" ;;
esac
WINDOWS_CYGPATH
chmod +x "$WINDOWS_BIN/git" "$WINDOWS_BIN/realpath" "$WINDOWS_BIN/cygpath"

PASS=0
FAIL=0

# run <expected_exit> <project_dir> <cwd> <event> <label> [env assignments...]
run() {
  local expect="$1" project="$2" cwd="$3" event="$4" label="$5"
  shift 5
  local payload rc=0
  payload=$(jq -n --arg cwd "$cwd" --arg ev "$event" \
    '{cwd: $cwd, hook_event_name: $ev, session_id: "test"}')
  LAST_STDOUT="$(printf '%s' "$payload" \
    | env CLAUDE_PROJECT_DIR="$project" HQ_ROOT= HQ_ALLOW_HQ_WORKTREE= "$@" \
      bash "$HOOK" "$event" 2>/dev/null)" || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL [$label]: expected exit $expect, got $rc (project=$project cwd=$cwd event=$event)" >&2
  fi
}

HQ="$TMP/hq"
HQWT="$TMP/hq-worktree"
APP="$TMP/hq/repos/private/app"
APPWT="$TMP/hq/workspace/worktrees/app/x"

# --- The block: HQ itself running from a worktree ---------------------------
run 2 "$HQWT" "$HQWT" UserPromptSubmit 'project dir is a linked HQ worktree — prompt blocked'
run 2 "$HQWT" "$HQWT" PreToolUse       'project dir is a linked HQ worktree — tool blocked'
run 2 "$HQ"   "$HQWT" UserPromptSubmit 'cwd is a worktree cut from HQ — blocked'
run 2 "$HQ"   "$HQWT" PreToolUse       'cwd is a worktree cut from HQ — tool blocked'

# SessionStart cannot stop a session: it must warn (exit 0) and say why.
run 0 "$HQWT" "$HQWT" SessionStart 'SessionStart never blocks startup'
if [[ "$LAST_STDOUT" != *"<hq-worktree-block>"* || "$LAST_STDOUT" != *"$HQ"* ]]; then
  FAIL=$((FAIL + 1))
  echo "FAIL [SessionStart banner]: missing marker or canonical path in stdout" >&2
else
  PASS=$((PASS + 1))
fi

# --- Must stay silent: the normal HQ flows ----------------------------------
run 0 "$HQ" "$HQ"           UserPromptSubmit 'canonical HQ checkout allowed'
run 0 "$HQ" "$APP"          UserPromptSubmit 'cwd in a nested source repo allowed'
run 0 "$HQ" "$APPWT"        UserPromptSubmit 'cwd in a repo worktree under workspace/worktrees allowed'
run 0 "$HQ" "$APPWT"        PreToolUse       'repo worktree tool calls allowed'
run 0 "$HQ" "$TMP/not-a-repo" UserPromptSubmit 'cwd outside any repo allowed'
run 0 "$TMP/not-a-repo" "$TMP/not-a-repo" UserPromptSubmit 'project dir outside any repo allowed'
run 0 "$WINDOWS_HQ" "$WINDOWS_HQ" UserPromptSubmit \
  'Git Bash and drive-letter aliases identify the same canonical HQ checkout' \
  PATH="$WINDOWS_BIN:$PATH"

# --- Escape hatch -----------------------------------------------------------
run 0 "$HQWT" "$HQWT" UserPromptSubmit 'HQ_ALLOW_HQ_WORKTREE=1 bypasses the block' \
  HQ_ALLOW_HQ_WORKTREE=1

echo "block-hq-worktree-session: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
