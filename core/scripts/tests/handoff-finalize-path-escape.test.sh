#!/usr/bin/env bash
# handoff-finalize-path-escape.test.sh — a changeset path can never stage files
# outside the handoff's own company. Each path is canonicalised once (".."
# components refused anywhere, "//" and "./" folded, symlinks resolved) and
# that one value drives validation, company detection and git add/commit.
#
#   feedback_bc850888: a trailing ".." after a company folder passed the
#     ".." pattern checks and committed a sibling company's files under a
#     commit labelled for one company.
#
# Temp git repos only; fixture companies are synthetic (acme, zeta).

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }

CO=companies
A=acme
Z=zeta

scaffold_repo() {
  local repo="$1"
  mkdir -p "$repo/core/scripts/lib" "$repo/workspace/baseline" "$repo/workspace/threads" "$repo/workspace/orchestrator"
  cp "$SRC_ROOT/scripts/handoff-finalize.sh" "$repo/core/scripts/handoff-finalize.sh"
  cp "$SRC_ROOT/scripts/lib/session-id.sh" "$repo/core/scripts/lib/session-id.sh"
  cp "$SRC_ROOT/scripts/hq-status-summary.sh" "$repo/core/scripts/hq-status-summary.sh"
  cp "$SRC_ROOT/scripts/lib/forwarder.sh" "$repo/core/scripts/lib/forwarder.sh"
  cp "$SRC_ROOT/scripts/lib/hq-cli-floor.sh" "$repo/core/scripts/lib/hq-cli-floor.sh"
  printf '#!/usr/bin/env bash\nmkdir -p workspace/threads; echo "# Threads" > workspace/threads/INDEX.md\n' \
    > "$repo/core/scripts/rebuild-threads-index.sh"
  printf '#!/usr/bin/env bash\nmkdir -p workspace/orchestrator; echo "# Orchestrator" > workspace/orchestrator/INDEX.md\n' \
    > "$repo/core/scripts/rebuild-orchestrator-index.sh"
  chmod +x "$repo/core/scripts/"*.sh
  mkdir -p "$repo/.claude/hooks"
  cp "$SRC_ROOT/../.claude/hooks/mirror-thread-to-company.sh" "$repo/.claude/hooks/mirror-thread-to-company.sh"
  printf '{"categories":[{"name":"baseline","patterns":["workspace/*","repos/*","core/settings/*",".hq/*"]}]}\n' \
    > "$repo/workspace/baseline/hq-local-baseline.json"
  mkdir -p "$repo/$CO/$A/projects/p" "$repo/$CO/$Z/projects/p"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name "Handoff Path Escape Test"
  echo base > "$repo/$CO/$A/projects/p/notes.md"
  echo base > "$repo/$CO/$Z/projects/p/secret.md"
  git -C "$repo" add .claude core/scripts workspace/baseline/hq-local-baseline.json "$CO"
  git -C "$repo" commit -qm base
}

finalize() { # <slug> <files-touched-json>
  bash core/scripts/handoff-finalize.sh --title "Handoff: $1" --summary "$1" --message "$1" \
    --files-touched-json "$2" --slug "$1" --company "$A"
}

# Dirty both companies, run one handoff for acme, and require that zeta's
# change is not committed, not listed as committed, and is reported skipped.
expect_refused() { # <case> <path>
  local name="$1" path="$2" repo="$TMP_ROOT/$1" out rc=0
  scaffold_repo "$repo"
  cd "$repo"
  if [[ -n "${SETUP:-}" ]]; then eval "$SETUP"; fi
  echo changed > "$CO/$A/projects/p/notes.md"
  echo leaked > "$CO/$Z/projects/p/secret.md"
  out=$(finalize "$name" "[\"$CO/$A/projects/p/notes.md\",\"$path\"]") || rc=$?
  [[ "$rc" == 0 || "$rc" == 4 ]] || fail "$name: unexpected exit $rc"
  if git show "HEAD:$CO/$Z/projects/p/secret.md" | grep -q leaked; then
    fail "$name: sibling company file was committed"
  fi
  [[ -z "$(git diff --cached --name-only -- "$CO/$Z")" ]] \
    || fail "$name: sibling company file left staged for the next commit"
  jq -e --arg z "$CO/$Z" --arg c "$CO" '(.committed_paths // []) | map(select(startswith($z) or . == $c or test("\\.\\."))) | length == 0' <<<"$out" >/dev/null \
    || fail "$name: committed_paths lists a sibling path"
  jq -e '(.skipped_paths // []) | length > 0' <<<"$out" >/dev/null \
    || fail "$name: escaping path was not reported as refused"
  git show "HEAD:$CO/$A/projects/p/notes.md" | grep -q changed \
    || fail "$name: the legitimate acme path must still commit"
  cd "$TMP_ROOT"
}

# Reporter's case: trailing parent segment after the owner's company folder.
expect_refused trailing-dotdot "$CO/$A/.."
expect_refused trailing-dotdot-slash "$CO/$A/../"
expect_refused trailing-dotdot-deep "$CO/$A/projects/../.."
expect_refused double-slash-dotdot "$CO//$A//.."
expect_refused dot-segments-dotdot "./$CO/./$A/./.."
expect_refused inner-dotdot "$CO/$A/../$Z/projects/p/secret.md"
expect_refused direct-sibling "$CO/$Z/projects/p/secret.md"
expect_refused bare-companies "$CO"
expect_refused companies-slash "$CO//"
SETUP='ln -s ../../$Z $CO/$A/projects/zlink' \
  expect_refused symlink-dir-into-sibling "$CO/$A/projects/zlink/projects/p/secret.md"
SETUP='ln -s ../../$Z $CO/$A/projects/zlink' \
  expect_refused symlink-leaf-into-sibling "$CO/$A/projects/zlink"
SETUP='ln -s ../$Z/projects/p/secret.md $CO/$A/s.md' \
  expect_refused symlink-file-into-sibling "$CO/$A/s.md"
expect_refused case-variant-root "Companies/$Z/projects/p/secret.md"
expect_refused case-variant-root-upper "COMPANIES/$Z/projects/p"
expect_refused case-variant-bare "Companies"
expect_refused unicode-fold-root "$(printf 'companie\305\277')/$Z/projects/p/secret.md"
SETUP='echo new > $CO/$Z/projects/p/new.md' \
  expect_refused case-variant-untracked "Companies/$Z/projects/p/new.md"
SETUP='ln -s .. $CO/$A/up' \
  expect_refused symlink-parent "$CO/$A/up/$Z/projects/p/secret.md"

# Absolute path through the HQ root with a trailing parent segment.
R="$TMP_ROOT/absolute"
scaffold_repo "$R"
cd "$R"
echo leaked > "$CO/$Z/projects/p/secret.md"
rc=0; out=$(finalize absolute "[\"$(pwd -P)/$CO/$A/..\"]") || rc=$?
if git show "HEAD:$CO/$Z/projects/p/secret.md" | grep -q leaked; then fail "absolute: sibling committed"; fi
jq -e '(.skipped_paths // []) | length > 0' <<<"$out" >/dev/null || fail "absolute: not reported as refused"
cd "$TMP_ROOT"

# A deleted entry spelled as a pathspec pattern is a literal name: it is
# reported missing, not silently treated as matching a sibling's files.
R="$TMP_ROOT/deleted-glob"
scaffold_repo "$R"
cd "$R"
rc=0; out=$(finalize deleted-glob "[{\"path\":\":(top)$CO/$Z\",\"deleted\":true},{\"path\":\"c*/$Z/projects/p/secret.md\",\"deleted\":true}]") || rc=$?
assert_eq "$(jq -r '[.skipped_paths[] | select(.reason == "missing")] | length' <<<"$out")" "2" "deleted-glob: both reported missing"
cd "$TMP_ROOT"

# No owner at all: two companies in one handoff are refused, not committed.
R="$TMP_ROOT/no-owner"
scaffold_repo "$R"
cd "$R"
echo changed > "$CO/$A/projects/p/notes.md"
echo leaked > "$CO/$Z/projects/p/secret.md"
rc=0; out=$(bash core/scripts/handoff-finalize.sh --title t --summary t --message t --slug no-owner \
  --files-touched-json "[\"$CO/$A/projects/p/notes.md\",\"$CO/$Z/projects/p/secret.md\"]") || rc=$?
if git show "HEAD:$CO/$Z/projects/p/secret.md" | grep -q leaked; then fail "no-owner: sibling committed"; fi
[[ -z "$(git diff --cached --name-only -- "$CO")" ]] || fail "no-owner: company path left staged"
jq -e '[.skipped_paths[] | select(.reason == "multi-company-no-owner")] | length == 2' <<<"$out" >/dev/null \
  || fail "no-owner: both company paths must be reported refused"
cd "$TMP_ROOT"

# ── allow cases: normal handoff paths still commit ─────────────────────────
R="$TMP_ROOT/allow"
scaffold_repo "$R"
cd "$R"
P="$CO/$A/projects/p"
echo a > "$P/notes.md"
echo b > "$P/new.md"
mkdir -p "$P/sub" && echo c > "$P/sub/x.md"
echo d > top.md
ln -s notes.md "$P/alias.md"
rc=0; out=$(finalize allow "[\"$P/notes.md\",\"./$P/new.md\",\"$CO//$A/projects/p/sub/./x.md\",\"top.md\",\"$P/alias.md\",\"$(pwd -P)/$P/sub/\"]") || rc=$?
assert_eq "$rc" "0" "allow: exit code"
assert_eq "$(jq -r '.hq_commit_status' <<<"$out")" "committed" "allow: status"
for f in "$P/notes.md" "$P/new.md" "$P/sub/x.md" top.md "$P/alias.md"; do
  git cat-file -e "HEAD:$f" 2>/dev/null || fail "allow: $f not committed"
  jq -e --arg p "$f" '.committed_paths | index($p)' <<<"$out" >/dev/null || fail "allow: committed_paths missing $f"
done
assert_eq "$(jq -r '.skipped_paths | length' <<<"$out")" "0" "allow: nothing skipped"

# A dotted file name is not a parent segment.
R="$TMP_ROOT/dotname"
scaffold_repo "$R"
cd "$R"
echo e > "$P/..notes.md"
rc=0; out=$(finalize dotname "[\"$P/..notes.md\"]") || rc=$?
assert_eq "$rc" "0" "dotname: exit code"
git cat-file -e "HEAD:$P/..notes.md" || fail "dotname: not committed"

echo "handoff-finalize-path-escape: all checks passed"
