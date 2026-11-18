#!/usr/bin/env bash
# hq-core: public
# worktree-backend.sh: backend selection, twig use, silent fallback, removal,
# HQ hook-stub filtering, and the soak log. Uses a stub `git-twig` so the test
# runs on any platform; one extra case runs the real twig when it is installed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$ROOT/core/scripts/worktree-backend.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $*" >&2; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export HOME="$TMP/home"; mkdir -p "$HOME"

# PATH without any real git-twig, plus a stub dir we can switch on.
CLEAN_PATH=""
IFS=: read -r -a _dirs <<< "$PATH"
for d in "${_dirs[@]}"; do
  [ -n "$d" ] && [ -x "$d/git-twig" ] && continue
  CLEAN_PATH="${CLEAN_PATH:+$CLEAN_PATH:}$d"
done
STUB="$TMP/stub-bin"; mkdir -p "$STUB"
cat > "$STUB/git-twig" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo "git-twig ${STUB_TWIG_VERSION:-0.3.0}"; exit 0; fi
[ "${1:-}" = new ] || exit 64
shift
printf 'new %s | hooksPath=%s\n' "$*" "$(git config --get core.hooksPath || echo none)" >> "$STUB_TWIG_LOG"
[ "${STUB_TWIG_FAIL:-0}" = 1 ] && { echo "git-twig: boom" >&2; exit 1; }
if [ "${STUB_TWIG_STOCK:-0}" = 1 ]; then echo "git-twig: stock Git: request is outside the CoW fast path" >&2
else echo "git-twig: APFS CoW: verified tracked files" >&2; fi
exec git worktree add "$@"
EOF
chmod +x "$STUB/git-twig"
export STUB_TWIG_LOG="$TMP/twig-calls.log"

HQ="$TMP/hq"; mkdir -p "$HQ/core/scripts" "$HQ/core/settings" "$HQ/personal/settings" "$HQ/workspace"
cp "$HELPER" "$HQ/core/scripts/worktree-backend.sh"
printf 'worktrees:\n  backend: git\n' > "$HQ/core/settings/worktrees.yaml"
SOAK="$HQ/workspace/reports/twig-soak/events.jsonl"

mkrepo() { # mkrepo <dir> : repo with main + origin/main one commit ahead of HEAD
  git init -q -b main "$1"
  echo a > "$1/a.txt"; git -C "$1" add a.txt; git -C "$1" commit -qm one
  git init -q --bare "$1.remote"; git -C "$1" remote add origin "$1.remote"
  git -C "$1" push -q origin main
}
wb() { HQ_ROOT="$HQ" bash "$HQ/core/scripts/worktree-backend.sh" "$@"; }
set_personal() { printf 'worktrees:\n  backend: %s   # soak\n' "$1" > "$HQ/personal/settings/worktrees.yaml"; }

R="$TMP/repo"; mkrepo "$R"

# 1. Setting off (core default git): plain git, twig never called, no soak log.
rm -f "$STUB_TWIG_LOG"
PATH="$STUB:$CLEAN_PATH" wb add --repo "$R" --path "$TMP/wt1" --new-branch wt/one --base main --no-track >/dev/null 2>&1
check "off: worktree created" '[ -f "$TMP/wt1/a.txt" ]'
check "off: branch checked out" '[ "$(git -C "$TMP/wt1" branch --show-current)" = wt/one ]'
check "off: twig not called" '[ ! -s "$STUB_TWIG_LOG" ]'
check "off: no soak log" '[ ! -e "$SOAK" ]'
check "off: backend reports git" 'PATH="$STUB:$CLEAN_PATH" wb backend | grep -q "^git (configured: git, from core)"'

# 2. Personal setting on + twig installed: twig used, soak log written.
set_personal twig
rm -f "$STUB_TWIG_LOG"
PATH="$STUB:$CLEAN_PATH" wb add --repo "$R" --path "$TMP/wt2" --new-branch wt/two --base main --no-track >/dev/null 2>&1
check "on: worktree created" '[ -f "$TMP/wt2/a.txt" ]'
check "on: twig called with -b at HEAD" 'grep -q "^new -b wt/two $TMP/wt2 HEAD" "$STUB_TWIG_LOG"'
check "on: branch checked out" '[ "$(git -C "$TMP/wt2" branch --show-current)" = wt/two ]'
check "on: no upstream with --no-track" '! git -C "$TMP/wt2" rev-parse --abbrev-ref wt/two@{upstream} >/dev/null 2>&1'
check "on: soak log line" 'tail -1 "$SOAK" | grep -q "\"backend\":\"twig-cow\""'
check "on: soak log has duration" 'tail -1 "$SOAK" | grep -q "\"duration_ms\":[0-9]"'
check "on: backend reports twig" 'PATH="$STUB:$CLEAN_PATH" wb backend | grep -q "^twig 0.3.0 (from personal)"'

# 3. Base differs from source HEAD: twig clones HEAD detached, then switches.
echo b > "$TMP/b.txt"
git -C "$TMP/wt2" add -A >/dev/null 2>&1; echo b > "$TMP/wt2/b.txt"; git -C "$TMP/wt2" add b.txt; git -C "$TMP/wt2" commit -qm two
git -C "$TMP/wt2" push -q origin wt/two:main; git -C "$R" fetch -q origin
rm -f "$STUB_TWIG_LOG"
PATH="$STUB:$CLEAN_PATH" wb add --repo "$R" --path "$TMP/wt3" --new-branch wt/three --base origin/main --no-track >/dev/null 2>&1
check "switch: twig cloned HEAD detached" 'grep -q "^new --detach $TMP/wt3 HEAD" "$STUB_TWIG_LOG"'
check "switch: on requested branch" '[ "$(git -C "$TMP/wt3" branch --show-current)" = wt/three ]'
check "switch: at requested base" '[ "$(git -C "$TMP/wt3" rev-parse HEAD)" = "$(git -C "$R" rev-parse origin/main)" ]'
check "switch: base file present" '[ -f "$TMP/wt3/b.txt" ]'
check "switch: no upstream with --no-track" '! git -C "$TMP/wt3" rev-parse --abbrev-ref wt/three@{upstream} >/dev/null 2>&1'
check "switch: clean tree" '[ -z "$(git -C "$TMP/wt3" status --porcelain)" ]'
check "switch: logged" 'tail -1 "$SOAK" | grep -q "\"backend\":\"twig-cow+switch\""'

# 4. Setting on, twig NOT installed: silent fallback to git, logged.
PATH="$CLEAN_PATH" wb add --repo "$R" --path "$TMP/wt4" --new-branch wt/four --base main >"$TMP/out4" 2>&1
rc4=$?
check "missing: rc 0" '[ "$rc4" -eq 0 ]'
check "missing: worktree created" '[ -f "$TMP/wt4/a.txt" ]'
check "missing: fallback logged" 'tail -1 "$SOAK" | grep -q "\"fallback\":\"twig-missing\""'
check "missing: backend reports fallback" 'PATH="$CLEAN_PATH" wb backend | grep -q "falling back: twig-missing"'

# 5. Twig too old: fallback.
STUB_TWIG_VERSION=0.2.9 PATH="$STUB:$CLEAN_PATH" wb add --repo "$R" --path "$TMP/wt5" --new-branch wt/five --base main >/dev/null 2>&1
check "old: worktree created" '[ -f "$TMP/wt5/a.txt" ]'
check "old: fallback logged" 'tail -1 "$SOAK" | grep -q "\"fallback\":\"twig-too-old-0.2.9\""'

# 6. Twig errors: partial state discarded, plain git used, error logged.
STUB_TWIG_FAIL=1 PATH="$STUB:$CLEAN_PATH" wb add --repo "$R" --path "$TMP/wt6" --new-branch wt/six --base main >/dev/null 2>&1
rc6=$?
check "error: rc 0" '[ "$rc6" -eq 0 ]'
check "error: worktree created by git" '[ "$(git -C "$TMP/wt6" branch --show-current)" = wt/six ]'
check "error: fallback logged" 'tail -1 "$SOAK" | grep -q "\"fallback\":\"twig-error\""'
# A failed or stock twig run makes the next create in that repo skip twig for a day.
rm -f "$STUB_TWIG_LOG"
PATH="$STUB:$CLEAN_PATH" wb add --repo "$R" --path "$TMP/wt6b" --new-branch wt/six-b --base main >/dev/null 2>&1
check "recent-stock: twig skipped" '[ ! -s "$STUB_TWIG_LOG" ] && [ -f "$TMP/wt6b/a.txt" ]'
check "recent-stock: reason logged" 'tail -1 "$SOAK" | grep -q "\"fallback\":\"twig-stock-recent\""'
rm -rf "$HQ/workspace/.cache/twig-stock"

# 6c. Repos twig 0.3.0 cannot CoW (conversion attributes, submodules) skip twig up front.
RA="$TMP/attr-repo"; mkrepo "$RA"
printf '* text=auto eol=lf\n' > "$RA/.gitattributes"; git -C "$RA" add .gitattributes; git -C "$RA" commit -qm attrs
rm -f "$STUB_TWIG_LOG"
PATH="$STUB:$CLEAN_PATH" wb add --repo "$RA" --path "$TMP/wta" --new-branch wt/attr --base main >/dev/null 2>&1
check "attributes: twig skipped" '[ ! -s "$STUB_TWIG_LOG" ] && [ -f "$TMP/wta/a.txt" ]'
check "attributes: reason logged" 'tail -1 "$SOAK" | grep -q "\"fallback\":\"twig-ineligible-attributes\""'
RC="$TMP/comment-attr-repo"; mkrepo "$RC"
printf '# text=auto in a comment only\n*.bin binary-ish\n' > "$RC/.gitattributes"; git -C "$RC" add .gitattributes; git -C "$RC" commit -qm attrs
rm -f "$STUB_TWIG_LOG"
PATH="$STUB:$CLEAN_PATH" wb add --repo "$RC" --path "$TMP/wtc" --new-branch wt/cattr --base main >/dev/null 2>&1
check "attributes: comments and non-conversion attrs do not block twig" '[ -s "$STUB_TWIG_LOG" ]'

# 7. Existing branch and detach modes through twig.
git -C "$R" branch wt/seven main
PATH="$STUB:$CLEAN_PATH" wb add --repo "$R" --path "$TMP/wt7" --branch wt/seven >/dev/null 2>&1
check "existing: on branch" '[ "$(git -C "$TMP/wt7" branch --show-current)" = wt/seven ]'
PATH="$STUB:$CLEAN_PATH" wb add --repo "$R" --path "$TMP/wt8" --detach --base origin/main >/dev/null 2>&1
check "detach: detached at base" '[ "$(git -C "$TMP/wt8" rev-parse HEAD)" = "$(git -C "$R" rev-parse origin/main)" ] && [ -z "$(git -C "$TMP/wt8" branch --show-current)" ]'

# 8. HQ dispatcher stubs for post-index-change are filtered out for twig only.
H="$TMP/hooks"; mkdir -p "$H"
for n in post-index-change reference-transaction post-checkout; do
  printf '#!/bin/sh\n# hq-git-hooks-dispatcher stub\nexit 0\n' > "$H/$n"; chmod +x "$H/$n"
done
git -C "$R" config core.hooksPath "$H"
rm -f "$STUB_TWIG_LOG"
PATH="$STUB:$CLEAN_PATH" wb add --repo "$R" --path "$TMP/wt9" --new-branch wt/nine --base main >/dev/null 2>&1
view="$(sed -n 's/.*hooksPath=//p' "$STUB_TWIG_LOG" | head -1)"
check "hooks: twig saw a filtered view" '[ "$view" != "$H" ] && [ -d "$view" ]'
check "hooks: view drops post-index-change" '[ ! -e "$view/post-index-change" ] && [ ! -e "$view/reference-transaction" ]'
check "hooks: view keeps other stubs" '[ "$view/post-checkout" -ef "$H/post-checkout" ]'
check "hooks: repo config untouched" '[ "$(git -C "$R" config core.hooksPath)" = "$H" ]'
# A real (non-stub) post-index-change hook is left alone.
printf '#!/bin/sh\necho real\n' > "$H/post-index-change"; chmod +x "$H/post-index-change"
rm -f "$STUB_TWIG_LOG"
PATH="$STUB:$CLEAN_PATH" wb add --repo "$R" --path "$TMP/wt10" --new-branch wt/ten --base main >/dev/null 2>&1
check "hooks: real hook keeps repo hooks path" 'grep -q "hooksPath=$H\$" "$STUB_TWIG_LOG"'
git -C "$R" config --unset core.hooksPath

# 9. Removal works for twig-made and git-made worktrees alike.
wb remove --repo "$R" --path "$TMP/wt2" >/dev/null 2>&1
check "remove: twig-made removed" '[ ! -e "$TMP/wt2" ] && ! git -C "$R" worktree list | grep -q "$TMP/wt2 "'
wb remove --repo "$R" --path "$TMP/wt1" >/dev/null 2>&1
check "remove: git-made removed" '[ ! -e "$TMP/wt1" ]'
echo dirty > "$TMP/wt3/dirty.txt"
wb remove --repo "$R" --path "$TMP/wt3" >/dev/null 2>&1
check "remove: dirty refused without --force" '[ -e "$TMP/wt3/dirty.txt" ]'
wb remove --repo "$R" --path "$TMP/wt3" --force >/dev/null 2>&1
check "remove: --force removes" '[ ! -e "$TMP/wt3" ]'

# 10. env override beats personal; unknown value falls back to git.
rm -f "$STUB_TWIG_LOG"
HQ_WORKTREE_BACKEND=git PATH="$STUB:$CLEAN_PATH" wb add --repo "$R" --path "$TMP/wt11" --new-branch wt/eleven --base main >/dev/null 2>&1
check "env: git override skips twig" '[ ! -s "$STUB_TWIG_LOG" ] && [ -f "$TMP/wt11/a.txt" ]'
HQ_WORKTREE_BACKEND=bogus PATH="$STUB:$CLEAN_PATH" wb add --repo "$R" --path "$TMP/wt12" --new-branch wt/twelve --base main >/dev/null 2>"$TMP/err12"
check "env: unknown value warns and uses git" 'grep -q "unknown backend" "$TMP/err12" && [ -f "$TMP/wt12/a.txt" ]'

# 11. Real twig, when installed (skipped cleanly otherwise; stub cases above cover CI).
if command -v git-twig >/dev/null 2>&1; then
  R2="$TMP/real"; mkrepo "$R2"
  PATH="$PATH" HQ_WORKTREE_BACKEND=twig wb add --repo "$R2" --path "$TMP/real-wt" --new-branch wt/real --base main --no-track >/dev/null 2>&1
  check "real twig: worktree created" '[ "$(git -C "$TMP/real-wt" branch --show-current)" = wt/real ]'
  check "real twig: logged as twig" 'tail -1 "$SOAK" | grep -q "\"backend\":\"twig-"'
  wb remove --repo "$R2" --path "$TMP/real-wt" >/dev/null 2>&1
  check "real twig: removed" '[ ! -e "$TMP/real-wt" ]'
fi

echo "worktree-backend: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
