#!/usr/bin/env bash
# Regression: hq-delegate-repo.sh must hand over the code branch with an
# explicit repo anchor, record dirty work as NOT transferred, verify access
# read-only, and never leak repo paths into vault prefixes.
#
# Guards (uses a REAL git fixture — local clone + bare origin):
#   1. Local-only branch + --yes -> pushed with `git -C ... push -u origin`,
#      visible in the bare origin, headSha recorded, branchPushed=true.
#   2. Local-only branch without --yes -> exit 2, branch NOT pushed.
#   3. Dirty/untracked files -> recorded in repo.dirtyFiles[] AND called out
#      in BRIEF.md as not transferred.
#   4. gh access check failure -> accessVerified=false, note says UNVERIFIED;
#      no step claims access exists.
#   5. vaultPrefixes[] untouched and free of repos/ paths.
#   6. repo: null -> clean exit 0, nothing changed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$ROOT/core/scripts/hq-delegate-repo.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$HELPER" ] || fail "missing helper: $HELPER"

# --- real git fixture: bare origin + working clone under a fake HQ root ------

FIX="$TMP/hqroot"
mkdir -p "$FIX/repos/public" "$TMP/origin"
git init --bare --quiet --initial-branch=main "$TMP/origin/widget-repo.git"
git -C "$FIX/repos/public" clone --quiet "$TMP/origin/widget-repo.git" widget-repo 2>/dev/null
REPO="$FIX/repos/public/widget-repo"
git -C "$REPO" config user.email test@test.local
git -C "$REPO" config user.name Test
echo "hello" > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit --quiet -m "init"
git -C "$REPO" push --quiet -u origin main 2>/dev/null
git -C "$REPO" switch --quiet -c feature/widget
echo "wip" > "$REPO/feature.txt"
git -C "$REPO" add feature.txt
git -C "$REPO" commit --quiet -m "feature work"
# leave dirty + untracked work behind
echo "uncommitted" >> "$REPO/README.md"
echo "scratch" > "$REPO/notes.tmp"

# stub gh: always 404s the collaborator check
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_STUB_LOG"
exit 1
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_STUB_LOG="$TMP/gh.log"

# --- bundle fixture ----------------------------------------------------------

BUNDLE="$TMP/bundle"
mkdir -p "$BUNDLE"
MANIFEST="$BUNDLE/manifest.json"
cat > "$MANIFEST" <<'JSON'
{
  "schemaVersion": 1,
  "delegationId": "dlg-test-widget",
  "company": "acme",
  "to": {"kind": "person", "principal": "alice@acme.test"},
  "project": {"name": "widget"},
  "vaultPrefixes": [
    {"prefix": "projects/widget/", "permission": "write", "reason": "project dossier"}
  ],
  "repo": {"path": "repos/public/widget-repo", "remote": null, "branch": "feature/widget",
           "baseBranch": "main", "headSha": null, "dirtyFiles": [], "accessVerified": false},
  "status": "building"
}
JSON
echo "# Delegation brief — widget" > "$BUNDLE/BRIEF.md"
PREFIXES_BEFORE="$(jq -c '.vaultPrefixes' "$MANIFEST")"

# --- 2. without --yes: exit 2, branch not pushed -----------------------------

set +e
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -eq 2 ] || fail "local-only branch without --yes must exit 2, got $RC"
git -C "$TMP/origin/widget-repo.git" rev-parse --verify --quiet refs/heads/feature/widget >/dev/null \
  && fail "branch must NOT be pushed without --yes"

# --- 1+3+4. with --yes: push, record dirty, unverified access ----------------

HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --yes --github-user alicehub >/dev/null 2>&1 \
  || fail "handover with --yes exited non-zero"

# 1. branch landed in the bare origin; manifest records it
git -C "$TMP/origin/widget-repo.git" rev-parse --verify --quiet refs/heads/feature/widget >/dev/null \
  || fail "branch was not pushed to origin"
LOCAL_SHA="$(git -C "$REPO" rev-parse refs/heads/feature/widget)"
jq -e --arg sha "$LOCAL_SHA" '.repo.headSha == $sha and .repo.branchPushed == true' "$MANIFEST" >/dev/null \
  || fail "manifest must record the pushed headSha: $(jq -c '.repo' "$MANIFEST")"

# 3. dirty + untracked recorded and surfaced in the brief
jq -e '.repo.dirtyFiles | index("README.md") and index("notes.tmp")' "$MANIFEST" >/dev/null \
  || fail "dirty and untracked files must land in repo.dirtyFiles: $(jq -c '.repo.dirtyFiles' "$MANIFEST")"
grep -q "not transferred" "$BUNDLE/BRIEF.md" || fail "BRIEF must call out untransferred work"
grep -q "README.md" "$BUNDLE/BRIEF.md" || fail "BRIEF must name the dirty files"

# 4. gh 404 -> unverified, stated plainly, never claimed
grep -q "collaborators/alicehub" "$GH_STUB_LOG" || fail "gh collaborator check was not invoked"
jq -e '.repo.accessVerified == false' "$MANIFEST" >/dev/null \
  || fail "failed gh check must leave accessVerified=false"
jq -e '.repo.accessNote | test("UNVERIFIED")' "$MANIFEST" >/dev/null \
  || fail "manifest accessNote must say UNVERIFIED"
grep -q "UNVERIFIED" "$BUNDLE/BRIEF.md" || fail "BRIEF must state access is unverified"

# --- 5. vaultPrefixes untouched, no repos/ paths -----------------------------

[ "$(jq -c '.vaultPrefixes' "$MANIFEST")" = "$PREFIXES_BEFORE" ] \
  || fail "handover must not touch vaultPrefixes"
jq -e 'all(.vaultPrefixes[]; .prefix | startswith("repos/") | not)' "$MANIFEST" >/dev/null \
  || fail "vaultPrefixes must contain no repos/ path"

# --- 6. repo: null skips cleanly ---------------------------------------------

NULL_MANIFEST="$TMP/null-manifest.json"
jq '.repo = null' "$MANIFEST" > "$NULL_MANIFEST"
BEFORE="$(cat "$NULL_MANIFEST")"
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$NULL_MANIFEST" >/dev/null 2>&1 \
  || fail "repo:null project must skip cleanly with exit 0"
[ "$(cat "$NULL_MANIFEST")" = "$BEFORE" ] || fail "repo:null run must change nothing"

echo "hq-delegate-repo: ok (anchored push behind --yes, dirty work surfaced, access unverified stated plainly, vaultPrefixes untouched, null skip)"
