#!/usr/bin/env bash
# hq-core: public
#
# Regression test for core/scripts/push-guard.sh and the pre-push stage of
# core/scripts/lib/git-hooks-dispatcher.sh: a push whose new commits add
# HQ-root marker paths or more than the file ceiling is rejected; a normal
# push passes; a chained repo pre-push hook still receives git's ref lines.
#
# Sandbox: temp HOME, GIT_CONFIG_GLOBAL, GIT_CONFIG_NOSYSTEM=1, a fake HQ root.
# The dispatcher is wired into the sandbox's global core.hooksPath by
# commit-secret-scan.sh enable with a stub scanner, exactly as on a user's
# machine. Real `git push`es to a local bare remote.
set -u
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/.gitconfig" XDG_CONFIG_HOME="$T/home/.config" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
git -C "$T" config --global user.email t@example.invalid
git -C "$T" config --global user.name test
git -C "$T" config --global init.defaultBranch main

ROOT="$T/hq root"
mkdir -p "$ROOT/core/scripts/lib" "$ROOT/core/settings" "$ROOT/repos"
cp "$REAL/core/scripts/push-guard.sh" "$REAL/core/scripts/commit-secret-scan.sh" "$REAL/core/scripts/hq-fingerprint-hooks.sh" "$ROOT/core/scripts/"
cp "$REAL/core/scripts/lib/hq-root-markers.sh" "$REAL/core/scripts/lib/git-hooks-dispatcher.sh" "$REAL/core/scripts/lib/hq-cli-floor.sh" "$REAL/core/scripts/lib/hq-cli-capability.sh" "$ROOT/core/scripts/lib/"
cp "$REAL/core/settings/worktree-preserve-denylist.txt" "$REAL/core/settings/commit-secret-scan.yaml" "$ROOT/core/settings/"
cat >"$T/stub-hq" <<'STUB'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "scan secrets" ] || exit 2
shift 2
[ "${1:-}" = "--help" ] && { echo "usage: hq scan secrets [--staged] [files...]"; exit 0; }
exit 0
STUB
chmod +x "$T/stub-hq"
export HQ_SECRET_SCAN_BIN="$T/stub-hq" HQ_ROOT="$ROOT" HQ_SECRET_SCAN_HOOKS_DIR="$T/home/.hq/git-hooks"
bash "$ROOT/core/scripts/commit-secret-scan.sh" enable >/dev/null 2>&1 || { echo "FAIL: could not wire the sandbox hooks"; exit 1; }
[ -x "$T/home/.hq/git-hooks/pre-push" ] || { echo "FAIL: dispatcher wrote no pre-push stub"; exit 1; }

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1 (want '$2', got '$3')"; fi; }

git -C "$T" init -q --bare origin.git
git -C "$T" init -q repo
R="$T/repo"
mkdir -p "$R/personal/skills"
echo a >"$R/README.md"; echo s >"$R/personal/skills/README.md"
git -C "$R" add -A && git -C "$R" commit -q -m init
git -C "$R" remote add origin "$T/origin.git"

# 1. a normal first push passes
out="$(git -C "$R" push -q origin main 2>&1)"; rc=$?
ok "first push passes" 0 "$rc"

# 2. a branch that adds HQ-root marker paths is rejected, on a new remote branch
git -C "$R" checkout -q -b wip/leak
mkdir -p "$R/personal/.codex" "$R/companies/voyage"; echo x >"$R/personal/.codex/config.toml"; echo y >"$R/companies/voyage/a.md"
echo ok >"$R/personal/skills/new.md"
git -C "$R" add -A && git -C "$R" commit -q -m leak
out="$(git -C "$R" push origin wip/leak 2>&1)"; rc=$?
ok "marker push rejected" 1 "$rc"
ok "marker push names the path" 1 "$(printf '%s\n' "$out" | grep -c 'foreign:personal/.codex/')"
ok "marker push names the company" 1 "$(printf '%s\n' "$out" | grep -c 'foreign:companies/voyage/')"
ok "marker push did not reach origin" "" "$(git -C "$T/origin.git" rev-parse -q --verify wip/leak 2>/dev/null)"

# 3. the same push with the owner's one-time override passes
out="$(HQ_PUSH_GUARD_ALLOW=1 git -C "$R" push -q origin wip/leak 2>&1)"; rc=$?
ok "override push passes" 0 "$rc"

# 4. an update to an existing remote branch that adds markers is rejected too
mkdir -p "$R/credentials"; echo z >"$R/credentials/k"
git -C "$R" add -A && git -C "$R" commit -q -m creds
out="$(git -C "$R" push origin wip/leak 2>&1)"; rc=$?
ok "marker update rejected" 1 "$rc"
ok "marker update names credentials" 1 "$(printf '%s\n' "$out" | grep -c 'root:credentials/')"

# 5. a tracked-subtree addition (personal/skills/...) alone passes
git -C "$R" checkout -q -b feat/ok main
echo ok >"$R/personal/skills/other.md"; mkdir -p "$R/personal/skills/deep"; echo d >"$R/personal/skills/deep/SKILL.md"
git -C "$R" add -A && git -C "$R" commit -q -m ok
out="$(git -C "$R" push -q origin feat/ok 2>&1)"; rc=$?
ok "tracked subtree push passes" 0 "$rc"

# 6. file ceiling
git -C "$R" checkout -q -b feat/big main
mkdir -p "$R/gen"; i=0; while [ $i -lt 25 ]; do echo $i >"$R/gen/f$i"; i=$((i+1)); done
git -C "$R" add -A && git -C "$R" commit -q -m big
out="$(HQ_PUSH_GUARD_MAX_ADDED=20 git -C "$R" push origin feat/big 2>&1)"; rc=$?
ok "ceiling push rejected" 1 "$rc"
ok "ceiling push says why" 1 "$(printf '%s\n' "$out" | grep -c 'adds 25 files (ceiling 20)')"
out="$(HQ_PUSH_GUARD_MAX_ADDED=30 git -C "$R" push -q origin feat/big 2>&1)"; rc=$?
ok "under-ceiling push passes" 0 "$rc"

# 7. deleting a remote branch is not checked
out="$(git -C "$R" push -q origin :feat/big 2>&1)"; rc=$?
ok "branch delete passes" 0 "$rc"

# 8. a chained repo pre-push hook still receives git's ref lines
mkdir -p "$R/.git/hooks"
cat >"$R/.git/hooks/pre-push" <<EOF
#!/bin/sh
cat >"$T/chained-stdin"
echo "\$1 \$2" >"$T/chained-args"
exit 0
EOF
chmod +x "$R/.git/hooks/pre-push"
git -C "$R" checkout -q -b feat/chain main
echo c >"$R/c.txt"; git -C "$R" add -A && git -C "$R" commit -q -m chain
out="$(git -C "$R" push -q origin feat/chain 2>&1)"; rc=$?
ok "chained push passes" 0 "$rc"
ok "chained hook got the ref line" 1 "$(grep -c "refs/heads/feat/chain $(git -C "$R" rev-parse HEAD) refs/heads/feat/chain" "$T/chained-stdin" 2>/dev/null)"
ok "chained hook got remote name" "origin $T/origin.git" "$(cat "$T/chained-args" 2>/dev/null)"
rm -f "$R/.git/hooks/pre-push"

# 8b. a file moved into a marker path is an addition there (renames off)
git -C "$R" checkout -q -b feat/move main
mkdir -p "$R/personal/.grok"; git -C "$R" mv README.md personal/.grok/README.md; git -C "$R" commit -q -m move
out="$(git -C "$R" push origin feat/move 2>&1)"; rc=$?
ok "rename into marker path rejected" 1 "$rc"

# 8c. a new second-level folder under .claude/ is normal work, not a marker
git -C "$R" checkout -q -b feat/claude main
mkdir -p "$R/.claude/policies" "$R/.claude/agents"; echo p >"$R/.claude/policies/a.md"
git -C "$R" add -A && git -C "$R" commit -q -m p
git -C "$R" push -q origin feat/claude 2>/dev/null
echo a >"$R/.claude/agents/r.md"; git -C "$R" add -A && git -C "$R" commit -q -m a
out="$(git -C "$R" push -q origin feat/claude 2>&1)"; rc=$?
ok "new .claude subfolder passes" 0 "$rc"
mkdir -p "$R/.claude/worktrees/x"; echo w >"$R/.claude/worktrees/x/f"; git -C "$R" add -A && git -C "$R" commit -q -m w
out="$(git -C "$R" push origin feat/claude 2>&1)"; rc=$?
ok ".claude/worktrees is still a marker" 1 "$rc"

# 8d. the husky block keeps git's ref lines for the repo's own pre-push hook
INIT="$T/home/.config/husky/init.sh"
[ -f "$INIT" ] || INIT="$XDG_CONFIG_HOME/husky/init.sh"
ok "husky init block written" 1 "$( [ -f "$INIT" ] && grep -c 'pre-commit|pre-push' "$INIT" || echo 0)"
ZERO_SHA=0000000000000000000000000000000000000000
refline="refs/heads/feat/chain $(git -C "$R" rev-parse feat/chain) refs/heads/feat/chain $ZERO_SHA"
got="$(cd "$R" && printf '%s\n' "$refline" | sh -c 'n=pre-push; . "$1"; cat' sh "$INIT" origin "$T/origin.git" 2>/dev/null)"
ok "husky pre-push replays stdin to the repo hook" "$refline" "$got"
got="$(cd "$R" && printf 'refs/heads/wip/leak %s refs/heads/wip/leak-h %s\n' "$(git -C "$R" rev-parse wip/leak)" "$ZERO_SHA" | sh -c 'n=pre-push; . "$1"; echo reached' sh "$INIT" origin "$T/origin.git" 2>/dev/null)"
ok "husky pre-push blocks a marker push" "" "$got"

# 9. direct check from inside the repo
rc=0; (cd "$R" && bash "$ROOT/core/scripts/push-guard.sh" check main wip/leak >/dev/null 2>&1) || rc=$?
ok "check subcommand flags markers" 1 "$rc"
rc=0; (cd "$R" && bash "$ROOT/core/scripts/push-guard.sh" check main feat/ok >/dev/null 2>&1) || rc=$?
ok "check subcommand passes clean range" 0 "$rc"

# 10. HQ_PUSH_GUARD=off disables the stage (the rest of the dispatcher still runs)
out="$(HQ_PUSH_GUARD=off git -C "$R" push -q origin wip/leak:refs/heads/wip/leak-off 2>&1)"; rc=$?
ok "HQ_PUSH_GUARD=off passes" 0 "$rc"

echo "push-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
