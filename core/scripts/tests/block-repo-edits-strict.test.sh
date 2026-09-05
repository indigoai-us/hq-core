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
#   2. An invalid legacy knowledge tree symlinked in from repos/private/. The
#      guard must block it and require migration to a real canonical directory.
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

# Invalid legacy layout retained only as a path-safety fixture.
ln -s ../../repos/private/knowledge-acme "$HQ/companies/acme/knowledge"

# Same legacy shape at the HQ-level knowledge root — the classification must
# cover core/knowledge/* too, not just company/personal paths.
mkdir -p "$HQ/core/knowledge/public"
ln -s ../../../repos/private/knowledge-acme "$HQ/core/knowledge/public/acme-notes"

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

# --- Path resolution must not depend on python3 ------------------------------
# The guard resolves symlinks and `..` before the repos/ prefix test. That
# resolution used to be a `python3 -c realpath` call behind `command -v python3`
# — which is not a usable probe on Windows, where the Store alias stub resolves
# on PATH and then fails every invocation. On any machine without a working
# python3 the resolution was skipped silently and dodges sailed through. These
# two assertions pin the replacement.

# run_at <project_dir> <file_path> -> exit code. Unlike run(), the HQ root is a
# parameter, so a root reached through a symlink can be exercised.
run_at() {
  local proj="$1" path="$2" payload rc=0
  payload="$(jq -nc --arg p "$path" '{tool_name:"Write", tool_input:{file_path:$p}}')"
  ( cd "$proj" && printf '%s' "$payload" | \
      env -u HQ_BYPASS_REPO_WORKTREE CLAUDE_PROJECT_DIR="$proj" \
      bash "$HOOK" PreToolUse ) >/dev/null 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# An HQ root reached through a symlink. The ROOT side of the prefix comparison
# must be resolved as fully as the file side: if the root stays "$HQ_LINK" while
# the file path resolves to "$HQ", the prefix test never matches and the guard
# passes everything under repos/.
HQ_LINK="$TMP/hq-via-symlink"
ln -s "$HQ" "$HQ_LINK"

got="$(run_at "$HQ_LINK" "$HQ_LINK/repos/private/app-code/src/main.ts")"
if [ "$got" = "2" ]; then
  ok "repos/ write is blocked when HQ root is reached via a symlink"
else
  fail "repos/ write is blocked when HQ root is reached via a symlink" "expected 2, got $got"
fi

got="$(run_at "$HQ_LINK" "$HQ_LINK/workspace/worktrees/app-code/feature/src/main.ts")"
if [ "$got" = "0" ]; then
  ok "sanctioned worktree stays writable when HQ root is reached via a symlink"
else
  fail "sanctioned worktree stays writable when HQ root is reached via a symlink" "expected 0, got $got"
fi

# A symlink followed by `..`. This is the case that distinguishes real symlink
# resolution from lexical normalization, and it is a live bypass if you get the
# order wrong: with workspace/via-link -> repos/private/app-code/src, the path
# workspace/via-link/../main.ts really means repos/private/app-code/main.ts, but
# collapsing `..` textually first yields workspace/main.ts — which is not under
# repos/, so the guard exits 0 and the write lands in the checkout anyway.
# Resolution must therefore hand `..` to the OS with symlinks already resolved
# (`cd -P`), never pre-collapse it.
ln -s "$HQ/repos/private/app-code/src" "$HQ/workspace/via-link"

expect "a symlink followed by \`..\` is blocked, not collapsed lexically" \
  "$HQ/workspace/via-link/../main.ts" 2

expect "a symlink into a checkout is blocked" \
  "$HQ/workspace/via-link/main.ts" 2

# A "//"-prefixed root. `pwd -P` preserves exactly two leading slashes, so the
# two sides of the guard's prefix comparison can disagree on the SPELLING of one
# physical path — the root reads //x/hq while files under it read /x/hq/repos/...,
# nothing matches, and the guard exits 0. On Linux //tmp and /tmp are the same
# directory, so every spelling must normalize to one form; the //server/share
# case that is genuinely distinct only exists on Windows Git Bash/MSYS/Cygwin.
# All four root/file spelling combinations are asserted below because each
# mismatched pair is independently a full bypass.
if [ -d //tmp ]; then
  DS="//tmp/hq-guard-ds-$$"
  mkdir -p "$DS/repos/private/app-code/src" "$DS/workspace/worktrees/app-code/feature"
  got="$(run_at "$DS" "$DS/repos/private/app-code/src/main.ts")"
  if [ "$got" = "2" ]; then
    ok "repos/ write is blocked under a // (UNC-style) project root"
  else
    fail "repos/ write is blocked under a // (UNC-style) project root" "expected 2, got $got"
  fi
  got="$(run_at "$DS" "$DS/workspace/worktrees/app-code/feature/main.ts")"
  if [ "$got" = "0" ]; then
    ok "sanctioned worktree stays writable under a // project root"
  else
    fail "sanctioned worktree stays writable under a // project root" "expected 0, got $got"
  fi

  # MIXED spellings of that same physical directory: "/tmp/..." on one side,
  # "//tmp/..." on the other. Preserving "//" on POSIX makes these two strings
  # unequal even though they name one directory, so the prefix check misses and
  # the write lands in the checkout. Both orderings are separate bypasses.
  SS="${DS#/}"
  got="$(run_at "$SS" "$DS/repos/private/app-code/src/main.ts")"
  if [ "$got" = "2" ]; then
    ok "repos/ write is blocked with a / root and a // file path"
  else
    fail "repos/ write is blocked with a / root and a // file path" "expected 2, got $got"
  fi
  got="$(run_at "$DS" "$SS/repos/private/app-code/src/main.ts")"
  if [ "$got" = "2" ]; then
    ok "repos/ write is blocked with a // root and a / file path"
  else
    fail "repos/ write is blocked with a // root and a / file path" "expected 2, got $got"
  fi
  got="$(run_at "$SS" "$DS/workspace/worktrees/app-code/feature/main.ts")"
  if [ "$got" = "0" ]; then
    ok "sanctioned worktree stays writable across mixed / and // spellings"
  else
    fail "sanctioned worktree stays writable across mixed / and // spellings" "expected 0, got $got"
  fi
  rm -rf "$DS"
fi

# A backslash in a filename. On POSIX "\" is an ordinary legal character, NOT a
# separator, so folding it to "/" before filesystem resolution makes the guard
# inspect a path the write will never touch: with a symlink literally named
# `link\name` pointing into repos/, the folded form workspace/link/name/file.txt
# exists nowhere, resolves to nothing under repos/, and the hook exits 0 while
# the write follows the real symlink into the checkout. Skipped on Windows-family
# shells, where "\" genuinely IS a separator and such a name cannot exist.
if [ "$(uname -s 2>/dev/null || true)" = "Linux" ] || [ "$(uname -s 2>/dev/null || true)" = "Darwin" ]; then
  BS_LINK="$HQ/workspace/link\\name"
  if ln -s "$HQ/repos/private/app-code" "$BS_LINK" 2>/dev/null; then
    got="$(run "$BS_LINK/src/main.ts" -u HQ_BYPASS_REPO_WORKTREE)"
    if [ "$got" = "2" ]; then
      ok "a backslash-named symlink into a checkout is blocked"
    else
      fail "a backslash-named symlink into a checkout is blocked" "expected 2, got $got"
    fi
    rm -f "$BS_LINK"
  fi
fi

# The worst case is not "python3 absent" but "python3 present and broken": it
# satisfies command -v, so a guard written around that probe takes the branch
# and then silently gets nothing back.
PYSTUB="$TMP/pystub"
mkdir -p "$PYSTUB"
printf '#!/bin/sh\necho "python3: cannot execute" >&2\nexit 1\n' > "$PYSTUB/python3"
cp "$PYSTUB/python3" "$PYSTUB/python"
chmod +x "$PYSTUB/python3" "$PYSTUB/python"

got="$(PATH="$PYSTUB:$PATH" run "$HQ/repos/private/app-code/src/main.ts" -u HQ_BYPASS_REPO_WORKTREE)"
if [ "$got" = "2" ]; then
  ok "repos/ write stays blocked when python3 on PATH is a broken stub"
else
  fail "repos/ write stays blocked when python3 on PATH is a broken stub" "expected 2, got $got"
fi

got="$(PATH="$PYSTUB:$PATH" run "$HQ/workspace/worktrees/app-code/feature/../../../../repos/private/app-code/src/main.ts" -u HQ_BYPASS_REPO_WORKTREE)"
if [ "$got" = "2" ]; then
  ok "\`..\` traversal stays blocked when python3 on PATH is a broken stub"
else
  fail "\`..\` traversal stays blocked when python3 on PATH is a broken stub" "expected 2, got $got"
fi

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

# A legacy knowledge symlink gets a migration diagnostic, never a bypass recipe.
run "$HQ/companies/acme/knowledge/finance/overview.md" -u HQ_BYPASS_REPO_WORKTREE >/dev/null
if grep -Fq 'invalid legacy knowledge symlink' "$ERR" && grep -Fq '! test -L' "$ERR" && ! grep -Fq 'cat >' "$ERR"; then
  ok "a legacy knowledge symlink is told to migrate"
else
  fail "a legacy knowledge symlink is told to migrate" "$(cat "$ERR")"
fi

# The same diagnostic covers a legacy link at the HQ knowledge root
# (core/knowledge/*): the write resolves into repos/, and "open a worktree"
# would be the wrong advice there too.
run "$HQ/core/knowledge/public/acme-notes/finance/overview.md" -u HQ_BYPASS_REPO_WORKTREE >/dev/null
if grep -Fq 'invalid legacy knowledge symlink' "$ERR" && grep -Fq '! test -L' "$ERR" && ! grep -Fq 'cat >' "$ERR"; then
  ok "a legacy core-knowledge symlink is told to migrate"
else
  fail "a legacy core-knowledge symlink is told to migrate" "$(cat "$ERR")"
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
