#!/usr/bin/env bash
# Regression test for core/scripts/remove-installed-test-files.sh, the
# /update-hq step that takes test and tooling files out of an existing install
# (hq-core-rust US-031).
#
# The "existing install" is a throwaway copy of this checkout with every test
# and tooling file in it, the shape an install had before releases left them
# out. After the script runs, the hq-cli installed-core check is clean, every
# file the release ships is still there, and the moved files sit in the backup
# folder unchanged. Installed packs, company and pack skills, company folders
# and linked folders are left alone. Uses the published checker (npm pack), as
# installed-core-check.sh does.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$root/core/scripts/remove-installed-test-files.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }
pass() { echo "PASS: $1"; }

# 1. The shipped rules are the release's rules.
if cmp -s "$root/core/scripts/release-install-excludes.rsync" "$root/.github/release/install-excludes.rsync"; then
  pass "core/scripts/release-install-excludes.rsync matches .github/release/install-excludes.rsync"
else
  fail "core/scripts/release-install-excludes.rsync differs from .github/release/install-excludes.rsync; copy it again"
fi

version=$(sed -n 's/^CHECKER_CLI_VERSION="\(.*\)"$/\1/p' "$root/.github/release/installed-core-check.sh")
npm pack "@indigoai-us/hq-cli@$version" --silent --ignore-scripts --pack-destination "$tmp" > "$tmp/pack.out"
tar -xzf "$tmp/$(tail -n 1 "$tmp/pack.out")" -C "$tmp" package/scripts/check-function-manifest.mjs
checker="$tmp/package/scripts/check-function-manifest.mjs"

# 2. An install made before the exclusions: the whole tree, tests included.
hq="$tmp/hq"
mkdir -p "$hq"
rsync -a --exclude=.git --exclude=.github --exclude=.leak-scan --exclude=node_modules "$root/" "$hq/"
# What the release ships today, to prove nothing it ships is taken out.
stage="$tmp/stage"
mkdir -p "$stage"
rsync -a --exclude=.git --exclude=.github --exclude=.leak-scan --exclude=node_modules \
  --exclude-from="$root/.github/release/install-excludes.rsync" "$root/" "$stage/"
# Things the script must not touch.
mkdir -p "$hq/core/packages/hq-pack-demo/tests" "$hq/.claude/skills/acme:demo/tests" "$hq/companies/acme/tests" "$tmp/elsewhere/tests"
printf 'pack\n' > "$hq/core/packages/hq-pack-demo/tests/pack.test.sh"
printf 'skill\n' > "$hq/.claude/skills/acme:demo/tests/skill.test.sh"
printf 'company\n' > "$hq/companies/acme/tests/company.test.sh"
printf 'linked\n' > "$tmp/elsewhere/tests/linked.test.sh"
mkdir -p "$hq/core/workers/public/linked-worker"
ln -s "$tmp/elsewhere/tests" "$hq/core/workers/public/linked-worker/tests"
# User content outside the release-owned trees, and dependency or wrapper
# folders inside them (review round 1): none of these may move.
mkdir -p "$hq/targets/app/tests" "$hq/tmp/tests" "$hq/research/__tests__" \
  "$hq/core/packages/hq-pack-cowork/mcp-server/node_modules/dep/tests" \
  "$hq/core/workers/public/demo-worker/node_modules/dep" \
  "$hq/.claude/skills/.hq-company-skill-wrappers/acme-demo/tests" "$hq/core/scripts/lib"
printf 'user\n' > "$hq/targets/app/tests/user.test.ts"
printf 'user\n' > "$hq/tmp/tests/scratch.test.sh"
printf 'user\n' > "$hq/research/__tests__/notes.test.py"
printf 'user\n' > "$hq/top-level.test.sh"
printf 'dep\n' > "$hq/core/packages/hq-pack-cowork/mcp-server/node_modules/dep/tests/dep.test.js"
printf 'dep\n' > "$hq/core/workers/public/demo-worker/node_modules/dep/index.spec.js"
printf 'wrap\n' > "$hq/.claude/skills/.hq-company-skill-wrappers/acme-demo/tests/w.test.sh"
printf 'mts\n' > "$hq/core/scripts/lib/shipped.test.mts"
untouched="targets/app/tests/user.test.ts tmp/tests/scratch.test.sh research/__tests__/notes.test.py top-level.test.sh core/packages/hq-pack-cowork/mcp-server/node_modules/dep/tests/dep.test.js core/workers/public/demo-worker/node_modules/dep/index.spec.js .claude/skills/.hq-company-skill-wrappers/acme-demo/tests/w.test.sh core/scripts/lib/shipped.test.mts"
# Names the keep list cannot hold one per line (review notes on #2007): a
# leading "#" (a comment to the keep-file reader), a leading or trailing space
# (trimmed by it) and a newline (splits the entry). None of these may move.
nl=$'\n'
odd=("#notes/tests/oddfix-1.test.sh" " spaced/tests/oddfix-2.test.sh" "trail /tests/oddfix-3.test.sh"
  "two${nl}lines/tests/oddfix-4.test.sh" "core/packages/#pack/tests/oddfix-5.test.sh"
  "core/packages/ pack/tests/oddfix-6.test.sh" "core/packages/new${nl}line/tests/oddfix-7.test.sh"
  ".claude/skills/acme:#odd/tests/oddfix-8.test.sh")
for f in "${odd[@]}"; do mkdir -p "$hq/${f%/*}"; printf 'odd\n' > "$hq/$f"; done
probe=core/scripts/tests/us031-probe.test.sh
printf '#!/bin/sh\necho probe\n' > "$hq/$probe"
printf '#!/bin/sh\n' > "$hq/core/scripts/ci/us031-probe-tool.sh"
before=$(find "$hq/core/scripts/tests" -type f | wc -l | tr -d ' ')

# 3. --check lists the files and moves nothing.
set +e
bash "$script" "$hq" --check --checker "$checker" > "$tmp/check.out" 2> "$tmp/check.err"
status=$?
set -e
[ "$status" -eq 1 ] && pass "--check exits 1 on an install with test files" || fail "--check exited $status"
grep -qxF "would move: $probe" "$tmp/check.out" && pass "--check lists a core test file" || fail "--check did not list $probe"
grep -qxF "would move: core/scripts/ci/us031-probe-tool.sh" "$tmp/check.out" && pass "--check lists a CI tooling file" || fail "--check did not list the CI tooling file"
[ -f "$hq/$probe" ] && pass "--check moved nothing" || fail "--check moved $probe"
for keep in core/packages/hq-pack-demo/tests/pack.test.sh ".claude/skills/acme:demo/tests/skill.test.sh" companies/acme/tests/company.test.sh core/scripts/tests/skill-script-refs.test.sh $untouched; do
  if grep -qF "$keep" "$tmp/check.out"; then fail "--check listed $keep"; else pass "--check leaves $keep alone"; fi
done

if grep -F oddfix "$tmp/check.out" >/dev/null; then fail "--check listed a file whose folder name the keep list cannot hold"; else pass "--check leaves the #, space and newline names alone"; fi

# 4. A missing checker stops before anything moves.
set +e
bash "$script" "$hq" --checker "$tmp/missing.mjs" --backup-dir "$tmp/none" > /dev/null 2>&1
status=$?
set -e
[ "$status" -eq 2 ] && [ -f "$hq/$probe" ] && [ ! -e "$tmp/none" ] && pass "a missing checker exits 2 and moves nothing" || fail "a missing checker exited $status or moved files"

# 5. The real run.
backup="$tmp/backup"
set +e
bash "$script" "$hq" --checker "$checker" --backup-dir "$backup" > "$tmp/run.out" 2> "$tmp/run.err"
status=$?
set -e
if [ "$status" -eq 0 ]; then pass "the run exits 0"; else fail "the run exited $status"; cat "$tmp/run.out" "$tmp/run.err" >&2; fi
[ ! -e "$hq/$probe" ] && pass "the core test file left the install" || fail "$probe is still installed"
cmp -s "$backup/$probe" <(printf '#!/bin/sh\necho probe\n') \
  && pass "the moved file is in the backup folder, unchanged" || fail "the backup copy of $probe is missing or changed"
after=$(find "$hq/core/scripts/tests" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$after" -lt "$before" ] && [ "$after" -eq 7 ] && pass "core/scripts/tests keeps only the 7 files shipped scripts run ($before before)" || fail "core/scripts/tests has $after files after the run ($before before)"
for keep in core/packages/hq-pack-demo/tests/pack.test.sh ".claude/skills/acme:demo/tests/skill.test.sh" companies/acme/tests/company.test.sh "core/workers/public/linked-worker/tests/linked.test.sh" $untouched; do
  [ -e "$hq/$keep" ] && pass "the run leaves $keep in place" || fail "the run took out $keep"
done
for f in "${odd[@]}"; do
  [ -f "$hq/$f" ] && pass "the run leaves ${f//$nl/\\n} in place" || fail "the run took out ${f//$nl/\\n}"
done
[ -f "$tmp/elsewhere/tests/linked.test.sh" ] && pass "the file behind the linked folder is untouched" || fail "the run removed a file through a linked folder"
missing=0
while IFS= read -r f; do
  rel=${f#"$stage/"}
  [ -e "$hq/$rel" ] || { missing=$((missing + 1)); echo "  shipped file taken out: $rel" >&2; }
done < <(find "$stage" -type f)
[ "$missing" -eq 0 ] && pass "every file the release ships is still installed" || fail "$missing shipped file(s) were taken out"

# 6. The installed-core check agrees, with the release's own wrapper rules.
if bash "$root/.github/release/installed-core-check.sh" "$hq" --checker "$checker" > "$tmp/ic.out" 2>&1; then
  fail "installed-core-check.sh passed on a whole HQ root; it should still report the skipped company, pack and link files"
else
  if grep -E 'FAIL \[installed-' "$tmp/ic.out" | grep -vE 'companies/|core/packages/hq-pack-demo/|\.claude/skills/acme:demo/|linked-worker/|targets/|tmp/|research/|top-level\.test|node_modules/|hq-company-skill-wrappers/|shipped\.test\.mts|oddfix-|\] two$|\] core/packages/new$|\] tests?/' | grep . >/dev/null; then
    fail "the installed-core check still finds test or tooling files the script should have moved"
    grep -E 'FAIL \[installed-' "$tmp/ic.out" | grep -vE 'companies/|core/packages/hq-pack-demo/|\.claude/skills/acme:demo/|linked-worker/|targets/|tmp/|research/|top-level\.test|node_modules/|hq-company-skill-wrappers/|shipped\.test\.mts|oddfix-|\] two$|\] core/packages/new$|\] tests?/' | head -20 >&2
  else
    pass "the installed-core check finds no test or tooling file outside the skipped folders"
  fi
fi

# 7. A second run has nothing to do.
set +e
bash "$script" "$hq" --checker "$checker" --backup-dir "$tmp/backup2" > "$tmp/run2.out" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] && grep -q 'moved 0 ' "$tmp/run2.out" && pass "a second run moves nothing and exits 0" || { fail "a second run exited $status"; cat "$tmp/run2.out" >&2; }

if [ "$failures" -gt 0 ]; then echo "remove-installed-test-files: $failures failure(s)" >&2; exit 1; fi
echo "remove-installed-test-files: all checks passed"
