#!/usr/bin/env bash
# private-lists.test.sh: the private leak-scan lists stay out of public hq-core.
#
# Public hq-core carried .leak-scan/denylist.yaml (private company names in
# plain text) and .leak-scan/manifest-snapshot.yaml (salted hashes next to
# their salt, so every hash could be recovered by hashing a candidate name).
# The promotion now excludes both files and deletes any copy already in
# hq-core; hq-core CI reads the lists from secrets.
#
# The slug scan was retired in #1628, so the scanner reads only the denylist;
# the promotion still excludes and removes an old snapshot copy.
#
# Covers: scan.sh reads the denylist from its secret when the file is absent,
# fails closed (exit 2) when neither is present, also under --warn, still reads
# the file on staging, and the promotion workflow excludes and removes both files.
# Made-up names only.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
leak="$(cd "$here/.." && pwd)"
root="$(cd "$leak/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); }

# A throwaway repo with the scanner and one changed file per case.
repo="$work/repo"
mkdir -p "$repo/.leak-scan"
cp "$leak/scan.sh" "$repo/.leak-scan/"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m base

DENY=$'version: 1\ncompanies:\n  zqfakeco: "{company}"\n'

change() { # $1 = file content; commits it as the change under test
  printf '%s\n' "$1" > "$repo/doc.md"
  git -C "$repo" add doc.md
  git -C "$repo" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -q -m change
}
scan() { # $1 = mode, $2 = optional --warn; prints exit code. Extra env comes from the caller.
  local rc=0
  (cd "$repo" && GITHUB_BASE_REF=nonexistent bash .leak-scan/scan.sh "$@") >"$work/out.txt" 2>"$work/err.txt" || rc=$?
  echo "$rc"
}

# 1. No denylist file and no secret: fail closed.
change 'hello'
[[ "$(LEAK_SCAN_DENYLIST_YAML='' scan denylist)" == 2 ]] || fail "denylist with no file and no secret should exit 2"
ok

# 2. Denylist from the secret catches a hit in the changed file.
change 'a note about zqfakeco'
[[ "$(LEAK_SCAN_DENYLIST_YAML="$DENY" scan denylist)" == 1 ]] || fail "denylist from secret missed a hit: $(cat "$work/err.txt")"
ok

# 3. Denylist from the secret is clean on a clean file.
change 'nothing private here'
[[ "$(LEAK_SCAN_DENYLIST_YAML="$DENY" scan denylist)" == 0 ]] || fail "denylist from secret flagged a clean file: $(cat "$work/out.txt")"
ok

# 4. Staging keeps the file: no secret needed.
printf '%s' "$DENY" > "$repo/.leak-scan/denylist.yaml"
change 'zqfakeco again'
[[ "$(LEAK_SCAN_DENYLIST_YAML='' scan denylist)" == 1 ]] || fail "denylist file on staging no longer read"
rm -f "$repo/.leak-scan/denylist.yaml"
ok

# 5. --warn (how CI runs it) must not turn a missing list into a pass.
change 'hello'
[[ "$(LEAK_SCAN_DENYLIST_YAML='' scan denylist --warn)" == 2 ]] || fail "denylist --warn (how CI runs it) with no file and no secret should exit 2"
ok

# 6. --warn with the secret still reports the hit (exit 0, warning printed).
change 'a note about zqfakeco'
[[ "$(LEAK_SCAN_DENYLIST_YAML="$DENY" scan denylist --warn)" == 0 ]] || fail "denylist --warn from secret should exit 0"
grep -q '::warning' "$work/out.txt" || fail "denylist --warn from secret printed no warning"
ok

# 7. No temp copy of a list is left behind.
leftover="$(grep -l 'zqfakeco' "${TMPDIR:-/tmp}"/tmp.* 2>/dev/null | head -1 || true)"
[[ -z "$leftover" ]] || fail "a temp copy of the denylist was left at $leftover"
ok

# 8. The promotion excludes both lists and removes a copy already in hq-core.
wf="$root/.github/workflows/promote-to-hq-core.yml"
grep -q -- "--exclude='.leak-scan/denylist.yaml'" "$wf" || fail "promotion does not exclude the denylist"
grep -q -- "--exclude='.leak-scan/manifest-snapshot.yaml'" "$wf" || fail "promotion does not exclude the slug snapshot"
grep -q 'rm -f target/.leak-scan/denylist.yaml target/.leak-scan/manifest-snapshot.yaml' "$wf" || fail "promotion does not remove an existing copy"
ok

# 9. hq-core CI passes the denylist secret to the scan step.
pc="$root/.github/workflows/pr-checks.yml"
grep -q 'LEAK_SCAN_DENYLIST_YAML: \${{ secrets.LEAK_SCAN_DENYLIST_YAML }}' "$pc" || fail "pr-checks does not pass the denylist secret"
ok

# 10. The Codex policy rubric reads the denylist the same way (secret, file,
# else exit 2). SKIP_CODEX=1 stops it right after the list check, offline.
cp "$leak/codex-rubric.sh" "$leak/rubric-prompt.md" "$repo/.leak-scan/"
rubric() { local rc=0; (cd "$repo" && SKIP_CODEX=1 bash .leak-scan/codex-rubric.sh doc.md) >"$work/out.txt" 2>"$work/err.txt" || rc=$?; echo "$rc"; }
[[ "$(LEAK_SCAN_DENYLIST_YAML='' rubric)" == 2 ]] || fail "rubric with no denylist file and no secret should exit 2"
[[ "$(LEAK_SCAN_DENYLIST_YAML="$DENY" rubric)" == 0 ]] || fail "rubric did not accept the denylist secret: $(cat "$work/err.txt")"
grep -q 'LEAK_SCAN_DENYLIST_YAML: \${{ secrets.LEAK_SCAN_DENYLIST_YAML }}' <(sed -n '/codex-pii-rubric:/,/codex-rubric.sh/p' "$pc") || fail "codex-pii-rubric job does not pass the denylist secret"
ok

echo "PASS: private-lists ($pass cases)"
