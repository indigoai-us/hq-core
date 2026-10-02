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
BASE_SHA="${HQ_HOOK_GUARD_BASE_SHA:-}"
[ -n "$BASE_SHA" ] || BASE_SHA="$(git -C "$ROOT" merge-base HEAD origin/main)"
# The base guard runs from its own directory so it can load the helpers it
# ships with (block-hq-worktree-safe-cd-flag.cjs since #1009).
mkdir -p "$TMP/base-hooks"
BASE_HOOK="$TMP/base-hooks/block-hq-worktree-session.sh"
git -C "$ROOT" show "$BASE_SHA:.claude/hooks/block-hq-worktree-session.sh" > "$BASE_HOOK" \
  || { echo "FAIL: could not load base guard at $BASE_SHA" >&2; exit 1; }
# The base guard runs from its own directory so it can load the helpers it
# ships with (block-hq-worktree-safe-cd-flag.cjs since #1009).
mkdir -p "$TMP/base-hooks"
BASE_HOOK="$TMP/base-hooks/block-hq-worktree-session.sh"
git -C "$ROOT" show "$BASE_SHA:.claude/hooks/block-hq-worktree-session.sh" > "$BASE_HOOK" \
  || { echo "FAIL: could not load base guard at $BASE_SHA" >&2; exit 1; }
if git -C "$ROOT" cat-file -e "$BASE_SHA:.claude/hooks/block-hq-worktree-safe-cd-flag.cjs" 2>/dev/null; then
  git -C "$ROOT" show "$BASE_SHA:.claude/hooks/block-hq-worktree-safe-cd-flag.cjs" \
    > "$TMP/base-hooks/block-hq-worktree-safe-cd-flag.cjs"
fi

git_quiet() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t "$@"; }

# --- Fake HQ root -----------------------------------------------------------
mkdir -p "$TMP/hq"
git_quiet -C "$TMP/hq" init -q
printf 'hq\n' > "$TMP/hq/README.md"
git_quiet -C "$TMP/hq" add README.md
git_quiet -C "$TMP/hq" commit -qm init
git_quiet -C "$TMP/hq" worktree add -q -b wt "$TMP/hq-worktree" >/dev/null 2>&1
git_quiet -C "$TMP/hq" worktree add -q -b wt-two "$TMP/hq-worktree-two" >/dev/null 2>&1
git_quiet -C "$TMP/hq" worktree add -q -b wt-three "$TMP/hq-worktree-three" >/dev/null 2>&1

# --- HQ checkout initialized with a separate Git directory ------------------
HQ_SEPARATE="$TMP/hq-separate"
HQ_SEPARATE_GITDIR="$TMP/hq-separate.git"
HQ_SEPARATE_WT="$TMP/hq-separate-linked"
mkdir -p "$HQ_SEPARATE"
git_quiet -C "$HQ_SEPARATE" init -q --separate-git-dir="$HQ_SEPARATE_GITDIR"
printf 'hq separate git dir\n' > "$HQ_SEPARATE/README.md"
git_quiet -C "$HQ_SEPARATE" add README.md
git_quiet -C "$HQ_SEPARATE" commit -qm init
git_quiet -C "$HQ_SEPARATE" worktree add -q -b linked "$HQ_SEPARATE_WT" >/dev/null 2>&1

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

# Fake the installed CLI's hq-flags dependencies so the safe-directory gate
# is deterministic and never makes a network request.
FLAG_CLI="$TMP/flag-cli"
FLAG_BIN="$TMP/flag-bin"
mkdir -p "$FLAG_CLI/bin" \
  "$FLAG_CLI/node_modules/@indigoai-us/hq-flags-client" \
  "$FLAG_CLI/node_modules/@indigoai-us/hq-cloud" "$FLAG_BIN"
printf '%s\n' '{"name":"@indigoai-us/hq-cli"}' > "$FLAG_CLI/package.json"
cat > "$FLAG_CLI/bin/hq" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod +x "$FLAG_CLI/bin/hq"
cat > "$FLAG_CLI/node_modules/@indigoai-us/hq-flags-client/package.json" <<'JSON'
{"type":"module","exports":{".":{"import":"./index.js"}}}
JSON
cat > "$FLAG_CLI/node_modules/@indigoai-us/hq-flags-client/index.js" <<'JS'
export const createFlagClient = () => ({
  ready: async () => {},
  snapshot: () => ({ flags: {
    "hooks.hq-worktree-safe-directory-change": process.env.HQ_TEST_SAFE_CWD_FLAG === "true",
  } }),
  close: () => {},
});
JS
cat > "$FLAG_CLI/node_modules/@indigoai-us/hq-cloud/package.json" <<'JSON'
{"type":"module","exports":{".":{"import":"./index.js"}}}
JSON
cat > "$FLAG_CLI/node_modules/@indigoai-us/hq-cloud/index.js" <<'JS'
export const loadCachedTokens = () => ({ idToken: "test-only-token" });
JS
ln -s "$FLAG_CLI/bin/hq" "$FLAG_BIN/hq"

PASS=0
FAIL=0

# run <expected_exit> <project_dir> <cwd> <event> <label> [env assignments...]
run() {
  local expect="$1" project="$2" cwd="$3" event="$4" label="$5"
  shift 5
  local payload rc=0 err_file run_cwd="${TEST_RUN_CWD:-$ROOT}" agent_id="${TEST_AGENT_ID:-}" agent_type="${TEST_AGENT_TYPE:-}" session_id="${TEST_SESSION_ID:-test}"
  payload=$(jq -n --arg cwd "$cwd" --arg ev "$event" \
    --arg agent_id "$agent_id" --arg agent_type "$agent_type" --arg sid "$session_id" \
    '{cwd: $cwd, hook_event_name: $ev, session_id: $sid}
      + (if $agent_id == "" then {} else {agent_id: $agent_id} end)
      + (if $agent_type == "" then {} else {agent_type: $agent_type} end)')
  err_file="$(mktemp)"
  LAST_STDOUT="$(
    run_cdpath_set=0; run_cdpath=""
    if [ "${CDPATH+x}" = x ]; then run_cdpath_set=1; run_cdpath="$CDPATH"; fi
    unset CDPATH
    cd -P -- "$run_cwd" || exit 125
    [ "$run_cdpath_set" -eq 0 ] || export CDPATH="$run_cdpath"
    printf '%s' "$payload" \
      | env -u HQ_HOOK_AGENT_ID -u HQ_HOOK_SESSION_ID -u HQ_HOOK_CWD -u HQ_HOOK_EVENT \
        CLAUDE_PROJECT_DIR="$project" HQ_ROOT= HQ_ALLOW_HQ_WORKTREE= "$@" \
        bash "$HOOK" "$event" 2>"$err_file"
  )" || rc=$?
  LAST_STDERR="$(cat "$err_file")"
  rm -f "$err_file"
  if [[ "$rc" -eq "$expect" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL [$label]: expected exit $expect, got $rc (project=$project cwd=$cwd event=$event)" >&2
  fi
}

HQ="$TMP/hq"
HQWT="$TMP/hq-worktree"
HQWT2="$TMP/hq-worktree-two"
HQWT3="$TMP/hq-worktree-three"
HQWT_LAST="$(git_quiet -C "$HQ" worktree list --porcelain \
  | awk '/^worktree / { path=substr($0, 10) } END { print path }')"
APP="$TMP/hq/repos/private/app"
APPWT="$TMP/hq/workspace/worktrees/app/x"
[ "$HQWT_LAST" != "$HQ" ] || { echo 'FAIL: multi-worktree fixture has no linked worktree' >&2; exit 1; }

# --- The block: HQ itself running from a worktree ---------------------------
run 2 "$HQWT" "$HQWT" UserPromptSubmit 'project dir is a linked HQ worktree — prompt blocked'
if [[ "$LAST_STDERR" != *"When starting an HQ session, leave Claude Code's Worktree toggle unchecked."* ]]; then
  FAIL=$((FAIL + 1))
  echo 'FAIL [UserPromptSubmit toggle guidance]: missing Worktree toggle instruction in refusal' >&2
else
  PASS=$((PASS + 1))
fi
run 2 "$HQWT" "$HQWT" PreToolUse       'project dir is a linked HQ worktree — tool blocked'
run 2 "$HQ"   "$HQWT" UserPromptSubmit 'cwd is a worktree cut from HQ — blocked'
run 2 "$HQ"   "$HQWT" PreToolUse       'cwd is a worktree cut from HQ — tool blocked'

# Only a session still rooted in canonical HQ may opt into a shell directory
# change. The flag is default-off; a session started from an HQ worktree stays
# blocked even when the flag is on.
run 2 "$HQ" "$HQWT" PreToolUse 'safe directory change remains blocked by default'
run 0 "$HQ" "$HQWT" PreToolUse 'safe directory change allowed when flag is on' \
  PATH="$FLAG_BIN:$PATH" HQ_CLI_BIN="$FLAG_CLI/bin/hq" \
  HQ_FLAGS_API_URL=https://flags.invalid HQ_COMPANY_UID=cmp_test123 \
  HQ_TEST_SAFE_CWD_FLAG=true
run 2 "$HQWT" "$HQWT" PreToolUse 'session started in HQ worktree stays blocked with flag on' \
  PATH="$FLAG_BIN:$PATH" HQ_CLI_BIN="$FLAG_CLI/bin/hq" \
  HQ_FLAGS_API_URL=https://flags.invalid HQ_COMPANY_UID=cmp_test123 \
  HQ_TEST_SAFE_CWD_FLAG=true
run 2 "$HQ" "$HQWT" PreToolUse 'invalid company identity fails closed' \
  PATH="$FLAG_BIN:$PATH" HQ_CLI_BIN="$FLAG_CLI/bin/hq" \
  HQ_FLAGS_API_URL=https://flags.invalid HQ_COMPANY_UID=invalid \
  HQ_TEST_SAFE_CWD_FLAG=true

# The worktree-toggle note is new candidate output. Strip it from base and
# candidate alike so parity holds whether or not the base already has it.
strip_worktree_toggle_note() {
  printf '%s\n' "$1" | awk 'skip { skip--; next } /^When starting an HQ session,/ { skip=2; next } NF { if (blank) print ""; print; blank=0; next } { blank=1 }'
}

# Regression: a base that already prints the note must normalize to the same
# text as a base without it, so the parity checks below hold on either base.
note_free=$'Blocked.\n\nSource-repo worktrees are unaffected.'
note_present=$'Blocked.\n\nWhen starting an HQ session, leave the Worktree toggle unchecked. It\nstarts HQ in a linked worktree.\nUse the toggle for a source session.\n\nSource-repo worktrees are unaffected.'
if [ "$(strip_worktree_toggle_note "$note_present")" = "$(strip_worktree_toggle_note "$note_free")" ] \
  && [ "$(strip_worktree_toggle_note "$note_free")" = "$note_free" ]; then
  PASS=$((PASS + 1)); echo 'ok: worktree-toggle note normalizes away on base and candidate stderr'
else
  FAIL=$((FAIL + 1)); echo 'FAIL [note normalization]: base and candidate stderr normalize differently' >&2
fi

# The last listed linked worktree must not be mistaken for the main checkout.
# Run the same multi-worktree cwd denial on the PR base and candidate guard.
HOOK="$BASE_HOOK"
TEST_SESSION_ID=c153-multi-worktree
run 2 "$HQ" "$HQWT_LAST" UserPromptSubmit 'base denies cwd in the last of several HQ worktrees'
base_multi_worktree_stdout="$LAST_STDOUT"
base_multi_worktree_stderr="$(strip_worktree_toggle_note "$LAST_STDERR")"
HOOK="$ROOT/.claude/hooks/block-hq-worktree-session.sh"
TEST_SESSION_ID=c153-multi-worktree \
  run 2 "$HQ" "$HQWT_LAST" UserPromptSubmit 'candidate denies cwd in the last of several HQ worktrees'
candidate_multi_worktree_stderr="$(strip_worktree_toggle_note "$LAST_STDERR")"
[ "$LAST_STDOUT" = "$base_multi_worktree_stdout" ] \
  && [ "$candidate_multi_worktree_stderr" = "$base_multi_worktree_stderr" ] \
  && { PASS=$((PASS + 1)); echo 'ok: base and candidate both deny the multi-worktree session'; } \
  || {
    FAIL=$((FAIL + 1))
    echo 'FAIL [multi-worktree parity]: base and candidate output differ' >&2
    printf 'base stdout: <%s>\ncandidate stdout: <%s>\nbase stderr: <%s>\ncandidate stderr: <%s>\n' \
      "$base_multi_worktree_stdout" "$LAST_STDOUT" "$base_multi_worktree_stderr" "$LAST_STDERR" >&2
  }

# An exported CDPATH must not contaminate norm's captured output for a relative
# project path.
HOOK="$BASE_HOOK"
TEST_SESSION_ID=c153-cdpath \
  TEST_RUN_CWD="$TMP" CDPATH="$TMP" \
  run 2 hq-worktree-two hq-worktree-two UserPromptSubmit 'base denies relative path with CDPATH'
base_cdpath_stdout="$LAST_STDOUT"
base_cdpath_stderr="$(strip_worktree_toggle_note "$LAST_STDERR")"
HOOK="$ROOT/.claude/hooks/block-hq-worktree-session.sh"
TEST_SESSION_ID=c153-cdpath \
  TEST_RUN_CWD="$TMP" CDPATH="$TMP" \
  run 2 hq-worktree-two hq-worktree-two UserPromptSubmit 'candidate denies relative path with CDPATH'
candidate_cdpath_stderr="$(strip_worktree_toggle_note "$LAST_STDERR")"
[ "$LAST_STDOUT" = "$base_cdpath_stdout" ] \
  && [ "$candidate_cdpath_stderr" = "$base_cdpath_stderr" ] \
  && { PASS=$((PASS + 1)); echo 'ok: base and candidate keep relative path output clean with CDPATH'; } \
  || {
    FAIL=$((FAIL + 1))
    echo 'FAIL [CDPATH parity]: base and candidate output differ' >&2
    printf 'base stdout: <%s>\ncandidate stdout: <%s>\nbase stderr: <%s>\ncandidate stderr: <%s>\n' \
      "$base_cdpath_stdout" "$LAST_STDOUT" "$base_cdpath_stderr" "$LAST_STDERR" >&2
  }

# Direct calls carry session_id and cwd only in stdin. Both fields must survive
# the later command substitutions that feed the deny and cached-allow paths.
TEST_SESSION_ID=c153-direct-deny \
  run 2 "$HQ" "$HQWT" UserPromptSubmit 'direct payload retains cwd for linked-worktree denial'
cache_session=c153-direct-cache
cache_path="$HQWT/workspace/orchestrator/hook-state/worktree-guard/$cache_session"
mkdir -p "${cache_path%/*}"
printf 'root=%s\ncwd=%s\nts=%s\n' "$HQWT" "$HQWT" "$(date +%s)" > "$cache_path"
TEST_SESSION_ID="$cache_session" \
  run 0 "$HQWT" "$HQWT" UserPromptSubmit 'direct payload retains cwd for cached allow'

# A manually selected --agent has agent_type but no subagent id. It is still an
# ordinary worktree session and must not gain the background-task exemption.
TEST_AGENT_TYPE=general-purpose \
  run 2 "$HQWT" "$HQWT" UserPromptSubmit 'agent_type alone does not bypass the block'

# --- Background tasks: isolated HQ worktrees are intentional ----------------
# Claude marks hook calls made inside Task subagents with agent_id. These child
# sessions must reach both their prompt and their tools, including repeat runs.
TEST_AGENT_ID=agent-task-1 TEST_AGENT_TYPE=general-purpose \
  run 0 "$HQWT" "$HQWT" UserPromptSubmit 'background task reaches its prompt'
TEST_AGENT_ID=agent-task-1 TEST_AGENT_TYPE=general-purpose \
  run 0 "$HQWT" "$HQWT" PreToolUse 'background task reaches its first tool call'
TEST_AGENT_ID=agent-task-2 TEST_AGENT_TYPE=general-purpose \
  run 0 "$HQWT" "$HQWT" UserPromptSubmit 'repeated background task launch is allowed'

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

# A linked worktree still shares a repository when the main checkout uses an
# arbitrary --separate-git-dir path. Detection uses Git metadata identity;
# deriving a human-facing checkout path remains a separate concern.
run 0 "$HQ_SEPARATE" "$HQ_SEPARATE" UserPromptSubmit \
  'canonical HQ checkout with a separate Git dir allowed'
run 2 "$HQ_SEPARATE" "$HQ_SEPARATE_WT" UserPromptSubmit \
  'cwd linked to HQ through an arbitrary common Git dir is blocked'
if [[ "$LAST_STDERR" != *"Canonical HQ:  $HQ_SEPARATE"* ]]; then
  FAIL=$((FAIL + 1))
  echo 'FAIL [separate git dir canonical path]: cwd warning omitted the known HQ checkout' >&2
else
  PASS=$((PASS + 1))
fi
run 2 "$HQ_SEPARATE_WT" "$HQ_SEPARATE_WT" UserPromptSubmit \
  'project dir linked through an arbitrary common Git dir is blocked'
if [[ "$LAST_STDERR" != *"path unavailable (separate Git directory: $HQ_SEPARATE_GITDIR)"* ]]; then
  FAIL=$((FAIL + 1))
  echo 'FAIL [separate git dir display]: metadata path was presented as a checkout' >&2
else
  PASS=$((PASS + 1))
fi

# SessionStart must still identify the real HQ worktree without launching a
# potentially slow Git subprocess on the cold path. The stub sleeps long
# enough to exceed the 2-second budget if the hook invokes it.
SLOW_GIT_BIN="$TMP/slow-git-bin"
mkdir -p "$SLOW_GIT_BIN"
cat > "$SLOW_GIT_BIN/git" <<'SH'
#!/usr/bin/env bash
sleep 5
exec /usr/bin/git "$@"
SH
chmod +x "$SLOW_GIT_BIN/git"
slow_payload="$(jq -nc --arg cwd "$HQWT" --arg sid c207-slow-git-session \
  '{cwd:$cwd,hook_event_name:"SessionStart",session_id:$sid}')"
slow_started="$(date +%s%N)"
slow_rc=0
slow_stdout="$(printf '%s' "$slow_payload" \
  | env -u HQ_HOOK_AGENT_ID -u HQ_HOOK_SESSION_ID -u HQ_HOOK_CWD -u HQ_HOOK_EVENT \
      CLAUDE_PROJECT_DIR="$HQ" HQ_ROOT= HQ_ALLOW_HQ_WORKTREE= PATH="$SLOW_GIT_BIN:$PATH" \
      timeout 2s bash "$HOOK" SessionStart 2>"$TMP/slow-git.err")" || slow_rc=$?
slow_finished="$(date +%s%N)"
slow_elapsed_ms=$(((slow_finished - slow_started) / 1000000))
if [ "$slow_rc" -eq 0 ] && [ "$slow_elapsed_ms" -lt 1500 ] \
   && [[ "$slow_stdout" == *"<hq-worktree-block>"* ]]; then
  PASS=$((PASS + 1))
  echo "ok: cold SessionStart blocks HQ worktree without the slow Git call (${slow_elapsed_ms}ms)"
else
  FAIL=$((FAIL + 1))
  echo "FAIL [cold SessionStart budget]: rc=$slow_rc elapsed=${slow_elapsed_ms}ms stdout=$slow_stdout" >&2
fi

# --- Escape hatch -----------------------------------------------------------
run 0 "$HQWT" "$HQWT" UserPromptSubmit 'HQ_ALLOW_HQ_WORKTREE=1 bypasses the block' \
  HQ_ALLOW_HQ_WORKTREE=1

# --- Shipped background knowledge callers use Claude's trusted Task lineage -
# spawn_task creates an HQ-linked child worktree without the provider-owned
# agent_id that this guard relies on. Task defaults to the current canonical
# checkout when worktree isolation is not requested.
for skill in brainstorm deep-plan plan prd; do
  skill_file="$ROOT/.claude/skills/$skill/SKILL.md"
  if ! grep -qE '^allowed-tools: (Task([, ]|$)|.*[, ]Task([, ]|$))' "$skill_file"; then
    FAIL=$((FAIL + 1))
    echo "FAIL [knowledge pulse caller $skill]: Task is missing from allowed-tools" >&2
  elif grep -q 'spawn_task(' "$skill_file"; then
    FAIL=$((FAIL + 1))
    echo "FAIL [knowledge pulse caller $skill]: still uses spawn_task without trusted Task lineage" >&2
  elif ! grep -q 'Task({' "$skill_file" \
      || ! grep -q 'run_in_background: true' "$skill_file" \
      || ! grep -q 'Run the knowledge-pulse skill' "$skill_file" \
      || ! grep -q 'without worktree isolation' "$skill_file"; then
    FAIL=$((FAIL + 1))
    echo "FAIL [knowledge pulse caller $skill]: missing background Task contract" >&2
  else
    PASS=$((PASS + 1))
  fi
done

echo "block-hq-worktree-session: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
