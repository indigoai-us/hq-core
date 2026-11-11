#!/usr/bin/env bash
# hq-core: public
#
# Regression test for core/scripts/worktree-preserve.sh and
# core/scripts/lib/hq-root-markers.sh (incident a1227963, 2026-11-05: a
# worktree holding a copy of the HQ root was staged, committed with
# --no-verify and pushed).
#
# Sandbox: temp HOME, GIT_CONFIG_GLOBAL, GIT_CONFIG_NOSYSTEM=1, a fake HQ root
# and a stub secret scanner. The real machine's git config is never touched.
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
mkdir -p "$ROOT/core/scripts/lib" "$ROOT/core/settings" "$ROOT/workspace/reports"
cp "$REAL/core/scripts/worktree-preserve.sh" "$REAL/core/scripts/commit-secret-scan.sh" "$REAL/core/scripts/hq-fingerprint-hooks.sh" "$ROOT/core/scripts/"
cp "$REAL/core/scripts/lib/hq-root-markers.sh" "$REAL/core/scripts/lib/git-hooks-dispatcher.sh" "$REAL/core/scripts/lib/hq-cli-floor.sh" "$REAL/core/scripts/lib/hq-cli-capability.sh" "$ROOT/core/scripts/lib/"
cp "$REAL/core/settings/worktree-preserve-denylist.txt" "$REAL/core/settings/commit-secret-scan.yaml" "$ROOT/core/settings/"
git -C "$ROOT" init -q # the fake HQ root is itself a repo, like the real one
# Stub scanner: flags a GitHub-token shape in the staged diff. Never prints a value.
cat >"$T/stub-hq" <<'STUB'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "scan secrets" ] || exit 2
shift 2
[ "${1:-}" = "--help" ] && { echo "usage: hq scan secrets [--staged] [files...]"; exit 0; }
pat='gh''p_[A-Za-z0-9]{36}'
git diff --cached -U0 | grep -qE "^\+.*$pat" && { echo "stub: possible secret" >&2; exit 1; }
exit 0
STUB
chmod +x "$T/stub-hq"
export HQ_SECRET_SCAN_BIN="$T/stub-hq" HQ_ROOT="$ROOT" HQ_PRESERVE_LEDGER="$T/ledger.md"
S="$ROOT/core/scripts/worktree-preserve.sh"

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1 (want '$2', got '$3')"; fi; }
rnd() { LC_ALL=C tr -dc "$1" </dev/urandom | head -c "$2"; }
action() { printf '%s\n' "$1" | tail -1 | cut -f1; }

# A repo with a bare origin, a main checkout and a linked worktree per case.
git -C "$T" init -q --bare "origin.git"
git -C "$T" init -q "repo"
R="$T/repo"
mkdir -p "$R/personal/skills" "$R/companies/_template"
echo a >"$R/README.md"; echo t >"$R/personal/skills/README.md"; echo c >"$R/companies/_template/README.md"
git -C "$R" add -A && git -C "$R" commit -q -m init
git -C "$R" remote add origin "$T/origin.git"
git -C "$R" push -q origin main
wt() { # name -> path; new branch wt/<name> off main
  local p="$T/wt-$1"
  git -C "$R" worktree add -q -b "wt/$1" "$p" main >/dev/null 2>&1
  echo "$p"
}

# 1. clean worktree: CLEAN, nothing committed
W="$(wt clean)"
out="$(bash "$S" "$W")"; rc=$?
ok "clean worktree exits 0" 0 "$rc"
ok "clean worktree action" CLEAN "$(action "$out")"

# 2. dirty under the ceiling, --push: COMMITTED and pushed to its own branch
W="$(wt dirty)"
echo work >"$W/feature.txt"; mkdir -p "$W/personal/skills/new"; echo s >"$W/personal/skills/new/SKILL.md"
out="$(bash "$S" "$W" --push)"; rc=$?
ok "dirty worktree exits 0" 0 "$rc"
ok "dirty worktree action" PUSHED "$(action "$out")"
ok "branch pushed to origin" "$(git -C "$W" rev-parse HEAD)" "$(git -C "$T/origin.git" rev-parse wt/dirty)"
ok "commit message" "wip: preserve worktree wt-dirty before removal ($(date -u +%Y-%m-%d))" "$(git -C "$W" log -1 --format=%s)"
ok "tracked subtree addition allowed" "personal/skills/new/SKILL.md" "$(git -C "$W" diff-tree --no-commit-id --name-only -r HEAD | grep personal)"
ok "ledger row written" 1 "$(grep -c "| PUSHED |" "$T/ledger.md")"

# 3. dirty, no --push: COMMITTED only
W="$(wt local)"
echo work >"$W/feature.txt"
out="$(bash "$S" "$W")"; rc=$?
ok "commit-only exits 0" 0 "$rc"
ok "commit-only action" COMMITTED "$(action "$out")"
ok "commit-only did not push" "" "$(git -C "$T/origin.git" rev-parse -q --verify wt/local 2>/dev/null)"

# 4. HQ-root copy dropped in: KEPT, nothing committed, nothing staged
W="$(wt hqcopy)"
before="$(git -C "$W" rev-parse HEAD)"
mkdir -p "$W/personal/.codex" "$W/companies/voyage/settings" "$W/credentials" "$W/personal/skills/x"
echo x >"$W/personal/.codex/config.toml"; echo y >"$W/companies/voyage/settings/a.yaml"; echo z >"$W/credentials/k.json"
echo "legit" >"$W/personal/skills/x/SKILL.md"; echo "d" >"$W/personal/settings.json.drift-1-2"
out="$(bash "$S" "$W" --push 2>"$T/err4")"; rc=$?
ok "hq-root copy exits 1" 1 "$rc"
ok "hq-root copy action" KEPT "$(action "$out")"
ok "hq-root copy committed nothing" "$before" "$(git -C "$W" rev-parse HEAD)"
ok "hq-root copy staged nothing" "" "$(git -C "$W" diff --cached --name-only)"
ok "hq-root copy names the foreign subtree" 1 "$(grep -c 'foreign:personal/.codex/' "$T/err4")"
ok "hq-root copy names the company folder" 1 "$(grep -c 'foreign:companies/voyage/' "$T/err4")"
ok "hq-root copy names credentials" 1 "$(grep -c 'root:credentials/' "$T/err4")"
ok "hq-root copy names drift file" 1 "$(grep -c 'glob:\*.drift-\*' "$T/err4")"
ok "hq-root copy never pushed" "" "$(git -C "$T/origin.git" rev-parse -q --verify wt/hqcopy 2>/dev/null)"
ok "ledger KEPT row" 1 "$(grep -c "| KEPT |" "$T/ledger.md")"

# 5. too many files: KEPT; --allow-large lets it through
W="$(wt big)"
mkdir -p "$W/gen"; i=0; while [ $i -lt 30 ]; do echo $i >"$W/gen/f$i"; i=$((i+1)); done
out="$(HQ_PRESERVE_MAX_FILES=20 bash "$S" "$W" 2>/dev/null)"; rc=$?
ok "size ceiling exits 1" 1 "$rc"
ok "size ceiling action" KEPT "$(action "$out")"
ok "size ceiling committed nothing" 0 "$(git -C "$W" rev-list --count main..HEAD)"
out="$(HQ_PRESERVE_MAX_FILES=20 bash "$S" "$W" --allow-large "generated corpus" 2>/dev/null)"; rc=$?
ok "--allow-large exits 0" 0 "$rc"
ok "--allow-large action" COMMITTED "$(action "$out")"

# 6. markers are not overridable by --allow-large
W="$(wt hqcopy2)"
mkdir -p "$W/worktrees/x"; echo x >"$W/worktrees/x/f"
out="$(bash "$S" "$W" --allow-large "no" 2>/dev/null)"; rc=$?
ok "marker beats --allow-large" KEPT "$(action "$out")"

# 7. secret in the changes: KEPT, nothing committed, index reset
W="$(wt secret)"
printf 'token = "gh''p_%s"\n' "$(rnd 'A-Za-z0-9' 36)" >"$W/config.ini"
before="$(git -C "$W" rev-parse HEAD)"
out="$(bash "$S" "$W" 2>/dev/null)"; rc=$?
ok "secret exits 1" 1 "$rc"
ok "secret action" KEPT "$(action "$out")"
ok "secret committed nothing" "$before" "$(git -C "$W" rev-parse HEAD)"
ok "secret left nothing staged" "" "$(git -C "$W" diff --cached --name-only)"

# 8. the repo's main checkout is refused
echo m >"$R/main-edit.txt"
out="$(bash "$S" "$R" 2>/dev/null)"; rc=$?
ok "main checkout exits 1" 1 "$rc"
ok "main checkout action" KEPT "$(action "$out")"
rm -f "$R/main-edit.txt"

# 9. a worktree of the HQ root itself is refused
git -C "$ROOT" add -A >/dev/null 2>&1; git -C "$ROOT" commit -q -m hq >/dev/null 2>&1
git -C "$ROOT" worktree add -q -b wt/hq "$T/hq-wt" >/dev/null 2>&1
echo e >"$T/hq-wt/edit.txt"
out="$(bash "$S" "$T/hq-wt" --push 2>/dev/null)"; rc=$?
ok "hq-root worktree exits 1" 1 "$rc"
ok "hq-root worktree action" KEPT "$(action "$out")"
ok "hq-root worktree committed nothing" 0 "$(git -C "$T/hq-wt" rev-list --count main..HEAD 2>/dev/null || echo 0)"

# 10. detached HEAD or main commits and pushes on wip/<slug>-<date>, never main
W="$T/wt-detached"
git -C "$R" worktree add -q --detach "$W" main >/dev/null 2>&1
echo d >"$W/d.txt"
mainsha="$(git -C "$T/origin.git" rev-parse main)"
localmain="$(git -C "$R" rev-parse main)"
out="$(bash "$S" "$W" --push)"; rc=$?
ok "detached push exits 0" 0 "$rc"
ok "detached push action" PUSHED "$(action "$out")"
ok "detached push went to wip branch" "$(git -C "$W" rev-parse HEAD)" "$(git -C "$T/origin.git" rev-parse "wip/wt-detached-$(date -u +%Y-%m-%d)")"
ok "origin main untouched" "$mainsha" "$(git -C "$T/origin.git" rev-parse main)"
ok "local main untouched" "$localmain" "$(git -C "$R" rev-parse main)"
ok "worktree now on the wip branch" "wip/wt-detached-$(date -u +%Y-%m-%d)" "$(git -C "$W" symbolic-ref -q --short HEAD)"
# A worktree checked out at main (not detached) behaves the same.
git -C "$R" checkout -q --detach main 2>/dev/null # free the main ref for the worktree
W="$T/wt-onmain"
git -C "$R" worktree add -q "$W" main >/dev/null 2>&1
echo m >"$W/m.txt"
out="$(bash "$S" "$W")"; rc=$?
ok "on-main commit exits 0" 0 "$rc"
ok "on-main commit action" COMMITTED "$(action "$out")"
ok "on-main left local main alone" "$localmain" "$(git -C "$R" rev-parse main)"
ok "on-main committed on a wip branch" "wip/wt-onmain-$(date -u +%Y-%m-%d)" "$(git -C "$W" symbolic-ref -q --short HEAD)"
git -C "$R" checkout -q main 2>/dev/null

# 10b. content someone already staged counts (the index is what a commit ships)
W="$(wt prestaged)"
mkdir -p "$W/personal/.codex"; echo x >"$W/personal/.codex/config.toml"
git -C "$W" add -A # staged, nothing unstaged
out="$(bash "$S" "$W" --push 2>/dev/null)"; rc=$?
ok "pre-staged marker exits 1" 1 "$rc"
ok "pre-staged marker action" KEPT "$(action "$out")"
ok "pre-staged marker never pushed" "" "$(git -C "$T/origin.git" rev-parse -q --verify wt/prestaged 2>/dev/null)"
W="$(wt prestaged2)"
echo w >"$W/w.txt"; git -C "$W" add -A
out="$(bash "$S" "$W")"; rc=$?
ok "pre-staged work is not CLEAN" COMMITTED "$(action "$out")"
ok "pre-staged work committed" "w.txt" "$(git -C "$W" diff-tree --no-commit-id --name-only -r HEAD)"

# 11. --dry-run changes nothing
W="$(wt dry)"
echo w >"$W/w.txt"
out="$(bash "$S" "$W" --push --dry-run)"; rc=$?
ok "dry-run exits 0" 0 "$rc"
ok "dry-run action" DRY-RUN "$(action "$out")"
ok "dry-run committed nothing" 0 "$(git -C "$W" rev-list --count main..HEAD)"
ok "dry-run staged nothing" "" "$(git -C "$W" diff --cached --name-only)"

# 12. the commit never skips hooks: a repo pre-commit hook that fails keeps the worktree
W="$(wt hooked)"
mkdir -p "$R/.git/hooks"; printf '#!/bin/sh\nexit 1\n' >"$R/.git/hooks/pre-commit"; chmod +x "$R/.git/hooks/pre-commit"
echo h >"$W/h.txt"
out="$(bash "$S" "$W" 2>/dev/null)"; rc=$?
ok "repo hook failure exits 1" 1 "$rc"
ok "repo hook failure action" KEPT "$(action "$out")"
ok "repo hook failure committed nothing" 0 "$(git -C "$W" rev-list --count main..HEAD)"
rm -f "$R/.git/hooks/pre-commit"

echo "worktree-preserve: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
