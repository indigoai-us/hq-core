#!/usr/bin/env bash
# block-repo-edits-strict.test.sh
#
# Pins that the repo-edit guard admits exactly ONE worktree location —
# {HQ_ROOT}/workspace/worktrees/ — and that nothing under repos/ is ever a valid
# Edit/Write target.
#
# This suite exists because the pressure runs the other way. Operators hit the
# guard in three recurring shapes and each one invites an exemption:
#
#   1. A worktree created as a sibling of its checkout (repos/**/{repo}-wt-*).
#      Tempting to allow by inspecting whether the directory is "really" a git
#      worktree. Instead the orchestrator now creates its worktrees in the
#      sanctioned location, so the need is gone.
#   2. A knowledge tree symlinked in from repos/private/knowledge-*. Tempting to
#      exempt by resolving which repo a knowledge symlink points at. Instead the
#      guard explains the Bash-redirect route, which it does not intercept.
#   3. An env-var escape hatch. Tempting because it is one line.
#
# Every one of those is a hole, and every structural test that would police one
# ("is this really a worktree?", "is this really a knowledge repo?") is a thing
# that can be spoofed or can decay. The assertions below fail if any of them is
# reintroduced.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/core/hooks/PreToolUse/10-Edit,Write,MultiEdit--block-repo-edits-use-worktree.sh"
PASS=0; FAIL=0

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required for this suite"; exit 0; }
[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HQ="$TMP/hq"
mkdir -p "$HQ/repos/private/app-code/src" \
         "$HQ/repos/private/app-code-wt-feature/src" \
         "$HQ/repos/private/knowledge-acme/finance" \
         "$HQ/companies/acme" \
         "$HQ/personal" \
         "$HQ/workspace/worktrees/app-code/feature/src"

# A knowledge repo symlinked in the way HQ's own /setup wires it.
ln -s ../../repos/private/knowledge-acme "$HQ/companies/acme/knowledge"

# A structurally real git worktree living under repos/ — the exact shape a
# "just check whether it's a worktree" exemption would let through.
mkdir -p "$HQ/repos/private/app-code/.git/worktrees/feature"
printf 'gitdir: %s/repos/private/app-code/.git/worktrees/feature\n' "$HQ" \
  > "$HQ/repos/private/app-code-wt-feature/.git"

ok()   { PASS=$((PASS+1)); echo "ok   [$1]"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]: $2" >&2; }

# run <file_path> [env assignments...] -> exit code; stderr captured to $ERR
ERR="$TMP/err"
run() {
  local path="$1"; shift
  local payload
  payload="$(jq -nc --arg p "$path" '{tool_name:"Write", tool_input:{file_path:$p}}')"
  ( cd "$HQ" && printf '%s' "$payload" | \
      env "$@" CLAUDE_PROJECT_DIR="$HQ" bash "$HOOK" PreToolUse ) >/dev/null 2>"$ERR"
  echo $?
}

expect() {
  local name="$1" path="$2" want="$3" got
  got="$(run "$path" -u HQ_BYPASS_REPO_WORKTREE)"
  if [ "$got" = "$want" ]; then ok "$name"; else fail "$name" "expected exit $want, got $got"; fi
}

# --- The one thing that IS allowed ------------------------------------------
expect "the sanctioned worktree location is writable" \
  "$HQ/workspace/worktrees/app-code/feature/src/main.ts" 0

expect "paths outside repos/ are ignored" \
  "$HQ/workspace/scratch.md" 0

# --- Everything under repos/ stays blocked ----------------------------------
expect "a plain checkout is blocked" \
  "$HQ/repos/private/app-code/src/main.ts" 2

# Shape 1: structurally a real git worktree, still under repos/, still blocked.
expect "a real git worktree under repos/ is STILL blocked" \
  "$HQ/repos/private/app-code-wt-feature/src/main.ts" 2

# Shape 2: both the canonical symlink path and the resolved repo path.
expect "a knowledge tree via its symlink is blocked" \
  "$HQ/companies/acme/knowledge/finance/overview.md" 2

expect "a knowledge tree via its repos/ path is blocked" \
  "$HQ/repos/private/knowledge-acme/finance/overview.md" 2

expect "traversal into a checkout is blocked" \
  "$HQ/workspace/worktrees/app-code/feature/../../../../repos/private/app-code/src/main.ts" 2

# Shape 3: the env-var escape hatch must not exist.
got="$(run "$HQ/repos/private/app-code/src/main.ts" HQ_BYPASS_REPO_WORKTREE=1)"
if [ "$got" = "2" ]; then
  ok "HQ_BYPASS_REPO_WORKTREE does not bypass the guard"
else
  fail "HQ_BYPASS_REPO_WORKTREE does not bypass the guard" "expected exit 2, got $got"
fi

# --- The block message has to be actionable ---------------------------------
run "$HQ/repos/private/app-code/src/main.ts" -u HQ_BYPASS_REPO_WORKTREE >/dev/null
if grep -Fq 'workspace/worktrees/' "$ERR"; then
  ok "the block message names workspace/worktrees/"
else
  fail "the block message names workspace/worktrees/" "$(cat "$ERR")"
fi
# Assert on the command's SHAPE rather than the helper's filename. Naming the
# forwarder here would make forwarder-ci-contract require an hq CLI install step
# in whichever job runs this suite — for a string this test only greps for and
# never executes.
if grep -Fq -- '--source' "$ERR" && grep -Fq -- '--name' "$ERR"; then
  ok "the block message gives the command that creates one"
else
  fail "the block message gives the command that creates one" "$(cat "$ERR")"
fi

# A knowledge write gets the knowledge route, not "go open a worktree" — that
# advice is useless for a repo with no PR workflow.
run "$HQ/companies/acme/knowledge/finance/overview.md" -u HQ_BYPASS_REPO_WORKTREE >/dev/null
if grep -Fq 'knowledge tree' "$ERR" && grep -Fq 'cat >' "$ERR"; then
  ok "a knowledge write is told the Bash-redirect route"
else
  fail "a knowledge write is told the Bash-redirect route" "$(cat "$ERR")"
fi

# --- Bash classification uses actual operations, not argument text ----------
# The active-run guard is the Bash counterpart of this repo-write policy. Give
# it a foreign owner for every target so a real mutation must block.
ACTIVE_HOOK="$ROOT/.claude/hooks/block-on-active-run.sh"
mkdir -p "$HQ/scripts" "$HQ/core/scripts"
cp "$ROOT/core/scripts/hook-lib.sh" "$HQ/core/scripts/hook-lib.sh"
cat > "$HQ/scripts/repo-run-registry.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '[{"pid":"999999","session_id":"other","run_id":"foreign","command":"run","project":"p","scope":"repo","started_at":"now"}]'
EOF
chmod +x "$HQ/scripts/repo-run-registry.sh"

run_bash() {
  local command="$1" payload rc=0
  payload="$(jq -nc --arg cmd "$command" '{tool_name:"Bash", tool_input:{command:$cmd}}')"
  ( cd "$HQ" && printf '%s' "$payload" | HQ_ROOT="$HQ" CLAUDE_PROJECT_DIR="$HQ" \
      bash "$ACTIVE_HOOK" ) >/dev/null 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

got="$(run_bash 'grep -niE "git reset|reset --hard|git checkout|git restore" some.log')"
if [ "$got" = "0" ]; then ok "git write words in a grep pattern do not activate Bash repo guard"; else fail "grep pattern is allowed" "expected 0, got $got"; fi
got="$(run_bash 'git -C repos/private/app-code reflog --date=iso -8')"
if [ "$got" = "0" ]; then ok "read-only git reflog does not activate Bash repo guard"; else fail "git reflog is allowed" "expected 0, got $got"; fi
got="$(run_bash 'git -C repos/private/app-code reset --hard origin/main')"
if [ "$got" = "2" ]; then ok "real git reset against a repo remains blocked"; else fail "git reset remains blocked" "expected 2, got $got"; fi
got="$(run_bash 'rm -rf repos/private/app-code')"
if [ "$got" = "2" ]; then ok "real repo deletion remains blocked"; else fail "repo rm remains blocked" "expected 2, got $got"; fi

echo "block-repo-edits-strict: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
