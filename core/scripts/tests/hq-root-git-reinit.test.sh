#!/usr/bin/env bash
# hq-core: public
# Regression tests for hq-root-git-reinit.sh: re-creating or repairing HQ-root
# history must never record nested company/project repos as gitlinks
# (mode 160000). (Shepherd 2638)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REINIT="$SCRIPT_DIR/../hq-root-git-reinit.sh"
TMP_PARENT="$(mktemp -d)"
trap 'rm -rf "$TMP_PARENT"' EXIT

export GIT_CONFIG_GLOBAL="$TMP_PARENT/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
: >"$GIT_CONFIG_GLOBAL"

checks=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { checks=$((checks + 1)); }

nested_repo() { # nested_repo <dir>
  mkdir -p "$1"
  git -C "$1" init -q
  printf 'inner\n' >"$1/README.md"
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q -m inner
}

make_hq() { # make_hq <dir>: an HQ-shaped tree with nested repos and no root .git
  local hq="$1"
  mkdir -p "$hq/core" "$hq/companies/example-co/projects/app" "$hq/repos/private/tool"
  printf 'core\n' >"$hq/core/core.yaml"
  printf '/repos/\n' >"$hq/.gitignore"
  printf 'plain\n' >"$hq/companies/example-co/notes.md"
  nested_repo "$hq/companies/example-co/knowledge"
  nested_repo "$hq/companies/example-co/projects/app/src"
  nested_repo "$hq/repos/private/tool"
}

gitlink_count() {
  git -C "$1" ls-files --stage | awk '$1 == "160000" { n++ } END { print n + 0 }'
}

# ── 1. Re-init excludes nested repos instead of recording gitlinks ───────────
HQ="$TMP_PARENT/hq"
make_hq "$HQ"
bash "$REINIT" --root "$HQ" --reinit >"$TMP_PARENT/reinit.out"
[ -d "$HQ/.git" ] || fail "reinit did not create .git"; pass
[ "$(gitlink_count "$HQ")" = "0" ] || fail "reinit recorded gitlinks: $(git -C "$HQ" ls-files --stage | grep '^160000')"; pass
git -C "$HQ" ls-tree -r HEAD | awk '$1 == "160000" { exit 1 }' || fail "HEAD tree contains a gitlink"; pass
[ ! -e "$HQ/.gitmodules" ] || fail "reinit must not create .gitmodules"; pass
git -C "$HQ" ls-files --error-unmatch companies/example-co/notes.md >/dev/null 2>&1 || fail "plain file not committed"; pass
git -C "$HQ" ls-files --error-unmatch core/core.yaml >/dev/null 2>&1 || fail "core file not committed"; pass
grep -qxF '/companies/example-co/knowledge/' "$HQ/.git/info/exclude" || fail "knowledge repo not excluded"; pass
grep -qxF '/companies/example-co/projects/app/src/' "$HQ/.git/info/exclude" || fail "project repo not excluded"; pass
grep -q 'companies/example-co/knowledge' "$TMP_PARENT/reinit.out" || fail "reinit did not report the excluded repo"; pass
[ -z "$(git -C "$HQ" status --porcelain)" ] || fail "tree not clean after reinit: $(git -C "$HQ" status --porcelain)"; pass
# Nested repos are untouched.
[ "$(git -C "$HQ/companies/example-co/knowledge" rev-list --count HEAD)" = "1" ] || fail "nested repo history changed"; pass
# A plain `git add -A` afterwards (what autosave or a person would run) still
# records no gitlink, because the exclusion persists.
git -C "$HQ" add -A
[ "$(gitlink_count "$HQ")" = "0" ] || fail "later git add -A recorded a gitlink"; pass

# Refuses to run over an existing repo.
if bash "$REINIT" --root "$HQ" --reinit >/dev/null 2>&1; then fail "reinit over an existing .git must refuse"; fi; pass

# ── 2. Check and repair an HQ root that already recorded gitlinks ────────────
BAD="$TMP_PARENT/bad"
make_hq "$BAD"
git -C "$BAD" init -q
git -C "$BAD" add -A 2>/dev/null
git -C "$BAD" -c user.name=t -c user.email=t@example.invalid commit -q -m "naive reinit"
[ "$(gitlink_count "$BAD")" = "2" ] || fail "fixture should reproduce 2 gitlinks, got $(gitlink_count "$BAD")"; pass

set +e
bash "$REINIT" --root "$BAD" --check >"$TMP_PARENT/check.out" 2>&1
rc=$?
set -e
[ "$rc" = "2" ] || fail "--check should exit 2 on gitlinks, got $rc"; pass
grep -q 'companies/example-co/knowledge' "$TMP_PARENT/check.out" || fail "--check did not name the gitlink"; pass

bash "$REINIT" --root "$BAD" --repair >/dev/null
[ "$(gitlink_count "$BAD")" = "0" ] || fail "repair left gitlinks in the index"; pass
git -C "$BAD" ls-tree -r HEAD | awk '$1 == "160000" { exit 1 }' || fail "repair did not commit the removal"; pass
[ -f "$BAD/companies/example-co/knowledge/README.md" ] || fail "repair deleted nested repo files"; pass
[ -z "$(git -C "$BAD" status --porcelain)" ] || fail "tree not clean after repair: $(git -C "$BAD" status --porcelain)"; pass
bash "$REINIT" --root "$BAD" --check >/dev/null || fail "--check should pass after repair"; pass

# ── 3. Works with no git identity configured ─────────────────────────────────
NOID="$TMP_PARENT/noid"
make_hq "$NOID"
# useConfigOnly stops git from guessing an identity from the host name, so
# this exercises the placeholder fallback on every platform.
NOID_CFG="$TMP_PARENT/noid-gitconfig"
printf '[user]\n\tuseConfigOnly = true\n' >"$NOID_CFG"
( unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  GIT_CONFIG_GLOBAL="$NOID_CFG" HOME="$TMP_PARENT/empty-home" bash "$REINIT" --root "$NOID" --reinit >/dev/null )
git -C "$NOID" rev-parse -q --verify HEAD >/dev/null || fail "reinit without identity made no commit"; pass
[ "$(git -C "$NOID" log -1 --format=%an)" = "HQ" ] || fail "placeholder identity not used"; pass
# A configured user.name is kept when only user.email is missing.
NAMEONLY="$TMP_PARENT/nameonly"
make_hq "$NAMEONLY"
NAME_CFG="$TMP_PARENT/name-gitconfig"
printf '[user]\n\tuseConfigOnly = true\n\tname = Real Person\n' >"$NAME_CFG"
( unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  GIT_CONFIG_GLOBAL="$NAME_CFG" HOME="$TMP_PARENT/empty-home" bash "$REINIT" --root "$NAMEONLY" --reinit >/dev/null )
[ "$(git -C "$NAMEONLY" log -1 --format=%an)" = "Real Person" ] || fail "configured user.name was replaced"; pass

# ── 4. Glob characters in a nested repo name ─────────────────────────────────
GLOB="$TMP_PARENT/glob"
make_hq "$GLOB"
nested_repo "$GLOB/companies/example-co/projects/Client [old]"
mkdir -p "$GLOB/companies/example-co/projects/Client o"
printf 'sibling\n' >"$GLOB/companies/example-co/projects/Client o/notes.md"
bash "$REINIT" --root "$GLOB" --reinit >/dev/null
[ "$(gitlink_count "$GLOB")" = "0" ] || fail "bracketed nested repo recorded as gitlink"; pass
git -C "$GLOB" ls-files --error-unmatch "companies/example-co/projects/Client o/notes.md" >/dev/null 2>&1 \
  || fail "escaped exclude must not hide a sibling folder"; pass
git -C "$GLOB" add -A
[ "$(gitlink_count "$GLOB")" = "0" ] || fail "later git add -A recorded the bracketed repo"; pass

# Repair of a bracketed gitlink keeps it out on the next add.
GLOBR="$TMP_PARENT/globr"
make_hq "$GLOBR"
nested_repo "$GLOBR/companies/example-co/projects/Client [old]"
git -C "$GLOBR" init -q
git -C "$GLOBR" add -A 2>/dev/null
git -C "$GLOBR" -c user.name=t -c user.email=t@example.invalid commit -q -m naive
bash "$REINIT" --root "$GLOBR" --repair >/dev/null
git -C "$GLOBR" add -A
[ "$(gitlink_count "$GLOBR")" = "0" ] || fail "repaired bracketed gitlink came back on git add -A"; pass

# ── 5. A line break in a nested repo name stops cleanly ─────────────────────
NL="$TMP_PARENT/nl"
make_hq "$NL"
nested_repo "$NL/companies/example-co/projects/bad"$'\n'"name"
if bash "$REINIT" --root "$NL" --reinit >/dev/null 2>&1; then fail "line-break repo name must refuse"; fi; pass
[ ! -e "$NL/.git" ] || fail "refused reinit must not leave a half-made .git"; pass

# ── 6. Not an HQ root ────────────────────────────────────────────────────────
mkdir -p "$TMP_PARENT/plain/sub"
if bash "$REINIT" --root "$TMP_PARENT/plain/sub" --reinit >/dev/null 2>&1; then fail "reinit outside an HQ root must refuse"; fi; pass
[ ! -e "$TMP_PARENT/plain/sub/.git" ] || fail "refused reinit created .git"; pass

# ── 7. Repair does not exclude a folder that is no longer a repo ─────────────
GONE="$TMP_PARENT/gone"
make_hq "$GONE"
git -C "$GONE" init -q
git -C "$GONE" add -A 2>/dev/null
git -C "$GONE" -c user.name=t -c user.email=t@example.invalid commit -q -m naive
rm -rf "$GONE/companies/example-co/knowledge/.git"
bash "$REINIT" --root "$GONE" --repair >/dev/null
if grep -qxF '/companies/example-co/knowledge/' "$GONE/.git/info/exclude"; then fail "repair excluded a folder that lost its .git"; fi; pass
grep -qxF '/companies/example-co/projects/app/src/' "$GONE/.git/info/exclude" || fail "repair did not exclude the live repo"; pass

# ── 8. --check fails loudly when git cannot read the index ───────────────────
CORRUPT="$TMP_PARENT/corrupt"
make_hq "$CORRUPT"
bash "$REINIT" --root "$CORRUPT" --reinit >/dev/null
printf 'garbage' >"$CORRUPT/.git/index"
set +e
bash "$REINIT" --root "$CORRUPT" --check >/dev/null 2>&1
rc=$?
set -e
[ "$rc" != "0" ] && [ "$rc" != "2" ] || fail "--check on a corrupt index must error, got $rc"; pass

# ── 9. Repair refuses to sweep unrelated staged changes into its commit ─────
STAGED="$TMP_PARENT/staged"
make_hq "$STAGED"
git -C "$STAGED" init -q
git -C "$STAGED" add -A 2>/dev/null
git -C "$STAGED" -c user.name=t -c user.email=t@example.invalid commit -q -m naive
printf 'unrelated\n' >"$STAGED/core/unrelated.md"
git -C "$STAGED" add core/unrelated.md
if bash "$REINIT" --root "$STAGED" --repair >/dev/null 2>&1; then fail "repair must refuse when other changes are staged"; fi; pass
[ "$(gitlink_count "$STAGED")" = "2" ] || fail "refused repair must not change the index"; pass

# ── 10. Repair of a line-break gitlink still unstages it ─────────────────────
NLR="$TMP_PARENT/nlr"
make_hq "$NLR"
nested_repo "$NLR/companies/example-co/projects/bad"$'\n'"name"
git -C "$NLR" init -q
git -C "$NLR" add -A 2>/dev/null
git -C "$NLR" -c user.name=t -c user.email=t@example.invalid commit -q -m naive
bash "$REINIT" --root "$NLR" --repair >/dev/null 2>&1 || fail "repair with a line-break gitlink must still succeed"; pass
[ "$(gitlink_count "$NLR")" = "0" ] || fail "repair left the line-break gitlink staged"; pass

# ── 10b. Staged gitlinks themselves never block repair ───────────────────────
# A: naive init + add with no commit yet.
NOHEAD="$TMP_PARENT/nohead"
make_hq "$NOHEAD"
git -C "$NOHEAD" init -q
git -C "$NOHEAD" add -A 2>/dev/null
bash "$REINIT" --root "$NOHEAD" --repair >/dev/null 2>&1 || fail "repair must work on an uncommitted naive init"; pass
[ "$(gitlink_count "$NOHEAD")" = "0" ] || fail "repair left gitlinks on an uncommitted naive init"; pass
# B: committed repo where a later add staged a new nested repo as a gitlink.
LATER="$TMP_PARENT/later"
make_hq "$LATER"
bash "$REINIT" --root "$LATER" --reinit >/dev/null
nested_repo "$LATER/companies/example-co/projects/new-repo"
git -C "$LATER" add -A 2>/dev/null
[ "$(gitlink_count "$LATER")" = "1" ] || fail "fixture should stage one new gitlink"; pass
bash "$REINIT" --root "$LATER" --repair >/dev/null 2>&1 || fail "repair must not count the staged gitlink as another change"; pass
[ "$(gitlink_count "$LATER")" = "0" ] || fail "repair left the newly staged gitlink"; pass
[ -f "$LATER/.git/index.hq-root-git-reinit.bak" ] || fail "repair did not back up the index"; pass
# D: line-break gitlink repaired, folder renamed, re-added, repaired again.
git -C "$NLR" add -A 2>/dev/null
mv "$NLR/companies/example-co/projects/bad"$'\n'"name" "$NLR/companies/example-co/projects/badname"
git -C "$NLR" add -A 2>/dev/null
bash "$REINIT" --root "$NLR" --repair >/dev/null 2>&1 || fail "repair after renaming the line-break folder must succeed"; pass
git -C "$NLR" add -A
[ "$(gitlink_count "$NLR")" = "0" ] || fail "renamed repo came back as a gitlink"; pass

# ── 10c. Repair finishes an interrupted re-init (git init ran, nothing else) ─
INT="$TMP_PARENT/interrupted"
make_hq "$INT"
git -C "$INT" init -q
bash "$REINIT" --root "$INT" --repair >/dev/null 2>&1 || fail "repair must finish an interrupted re-init"; pass
git -C "$INT" rev-parse -q --verify HEAD >/dev/null || fail "repair of an interrupted re-init made no commit"; pass
git -C "$INT" ls-files --error-unmatch core/core.yaml >/dev/null 2>&1 || fail "interrupted re-init repair did not commit files"; pass
grep -qxF '/companies/example-co/knowledge/' "$INT/.git/info/exclude" || fail "interrupted re-init repair did not exclude nested repos"; pass

# ── 10d. Secret folders stay out of local history with an older .gitignore ──
SEC="$TMP_PARENT/secrets"
make_hq "$SEC"
mkdir -p "$SEC/companies/example-co/secrets" "$SEC/.secrets"
printf 'token\n' >"$SEC/companies/example-co/secrets/oauth.json"
printf 'token\n' >"$SEC/.secrets/oauth.json"
bash "$REINIT" --root "$SEC" --reinit >/dev/null
if git -C "$SEC" ls-files | grep -q 'secrets/oauth.json'; then fail "reinit committed a secret folder"; fi; pass

# ── 10e. Repair of a naive uncommitted init keeps staged secrets out ────────
NSEC="$TMP_PARENT/naive-secrets"
make_hq "$NSEC"
mkdir -p "$NSEC/companies/example-co/secrets" "$NSEC/x/.secrets"
printf 'token\n' >"$NSEC/companies/example-co/secrets/oauth.json"
printf 'token\n' >"$NSEC/x/.secrets/t.json"
git -C "$NSEC" init -q
git -C "$NSEC" add -A 2>/dev/null
bash "$REINIT" --root "$NSEC" --repair >/dev/null 2>&1 || fail "repair of a naive init with secrets failed"; pass
if git -C "$NSEC" ls-tree -r --name-only HEAD | grep -q 'secrets/'; then fail "repair committed staged secret files"; fi; pass
git -C "$NSEC" ls-files --error-unmatch core/core.yaml >/dev/null 2>&1 || fail "repair of a naive init dropped ordinary files"; pass

# ── 10f. A failing git add makes re-init fail, not report success ────────────
if [ "$(id -u)" != "0" ]; then
  LOCKED="$TMP_PARENT/locked"
  make_hq "$LOCKED"
  printf 'x\n' >"$LOCKED/core/locked.md"
  chmod 000 "$LOCKED/core/locked.md"
  set +e
  bash "$REINIT" --root "$LOCKED" --reinit >/dev/null 2>&1
  rc=$?
  set -e
  chmod 644 "$LOCKED/core/locked.md"
  [ "$rc" != "0" ] || fail "reinit must fail when git add fails"; pass
fi

# ── 10g. No-commit --repair refuses a repo that is not an HQ root ───────────
NHQ="$TMP_PARENT/fxg/companies/example-co/new-project"
mkdir -p "$NHQ"
printf 'draft\n' >"$NHQ/draft.md"
git -C "$NHQ" init -q
set +e
bash "$REINIT" --root "$NHQ" --repair >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "1" ] || fail "no-HEAD repair outside an HQ root must exit 1, got $rc"; pass
if git -C "$NHQ" rev-parse -q --verify HEAD >/dev/null; then fail "no-HEAD repair committed in a non-HQ repo"; fi; pass
[ -z "$(git -C "$NHQ" ls-files)" ] || fail "no-HEAD repair staged files in a non-HQ repo"; pass
if grep -qs 'hq-root-git-reinit' "$NHQ/.git/info/exclude"; then fail "no-HEAD repair wrote HQ excludes into a non-HQ repo"; fi; pass

# ── 10h. --reinit refuses a folder inside another work tree (<HQ>/core) ─────
if bash "$REINIT" --root "$HQ/core" --reinit >/dev/null 2>&1; then fail "reinit of <HQ>/core must refuse"; fi; pass
[ ! -e "$HQ/core/.git" ] || fail "refused reinit created core/.git"; pass

# ── 10i. A failed commit exits 1, and --repair finishes once fixed ──────────
HOOKFAIL="$TMP_PARENT/hookfail"
make_hq "$HOOKFAIL"
mkdir -p "$TMP_PARENT/failhooks"
printf '#!/bin/sh\nexit 1\n' >"$TMP_PARENT/failhooks/pre-commit"
chmod +x "$TMP_PARENT/failhooks/pre-commit"
set +e
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$TMP_PARENT/failhooks" \
  bash "$REINIT" --root "$HOOKFAIL" --reinit >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "1" ] || fail "failed reinit commit must exit 1, got $rc"; pass
bash "$REINIT" --root "$HOOKFAIL" --repair >/dev/null || fail "repair after a failed commit failed"; pass
git -C "$HOOKFAIL" rev-parse -q --verify HEAD >/dev/null || fail "repair did not finish the re-init"; pass
[ "$(gitlink_count "$HOOKFAIL")" = "0" ] || fail "finished re-init recorded gitlinks"; pass

# ── 11. macOS system bash 3.2, when present ──────────────────────────────────
if [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ]'; then
  OLD="$TMP_PARENT/bash32"
  make_hq "$OLD"
  nested_repo "$OLD/companies/example-co/projects/Client [old]"
  /bin/bash "$REINIT" --root "$OLD" --reinit >/dev/null || fail "reinit under bash 3.2 failed"; pass
  [ "$(gitlink_count "$OLD")" = "0" ] || fail "bash 3.2 reinit recorded a gitlink"; pass
  /bin/bash "$REINIT" --root "$OLD" --check >/dev/null || fail "--check under bash 3.2 failed"; pass
  OLDR="$TMP_PARENT/bash32r"
  make_hq "$OLDR"
  git -C "$OLDR" init -q
  git -C "$OLDR" add -A 2>/dev/null
  git -C "$OLDR" -c user.name=t -c user.email=t@example.invalid commit -q -m naive
  /bin/bash "$REINIT" --root "$OLDR" --repair >/dev/null || fail "--repair under bash 3.2 failed"; pass
  [ "$(gitlink_count "$OLDR")" = "0" ] || fail "bash 3.2 repair left gitlinks"; pass
fi

echo "hq-root-git-reinit: $checks checks passed"
