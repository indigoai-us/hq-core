#!/usr/bin/env bash
# hq-core: public
# Regression: parse-release-tag.sh (US-048).
#
# Live 2026-09-24: hq-core PR 310 "release: v15.0.162" merged with a merge
# commit. Auto-tag read only the head subject ("Merge pull request #310 …")
# and skipped the tag. Squash path must stay identical; merge commits must
# resolve from parent-2 subject or the associated PR title.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PARSE="$ROOT/core/scripts/parse-release-tag.sh"
WORKFLOW="$ROOT/.github/workflows/auto-tag-release.yml"

[ -f "$PARSE" ] || { echo "FAIL: missing $PARSE" >&2; exit 1; }
[ -x "$PARSE" ] || chmod +x "$PARSE"
[ -f "$WORKFLOW" ] || { echo "FAIL: missing $WORKFLOW" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

field() {
  # field <output> <key>
  printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k { print substr($0, index($0,"=")+1); exit }'
}

run_parse() {
  env -u GITHUB_OUTPUT -u MSG -u RELEASE_SUBJECT -u GITHUB_SHA -u GITHUB_REPOSITORY \
    "$PARSE" "$@"
}

echo "[1] squash: exact release subject"
out="$(run_parse --subject "release: v15.0.162" --no-fetch)"
[ "$(field "$out" match)" = "true" ] || fail "squash match: $out"
[ "$(field "$out" tag)" = "v15.0.162" ] || fail "squash tag: $out"
[ "$(field "$out" source)" = "head" ] || fail "squash source: $out"
pass "release: v15.0.162 → v15.0.162 source=head"

echo "[2] squash: GitHub (#N) suffix"
out="$(run_parse --subject "release: v15.0.162 (#310)" --no-fetch)"
[ "$(field "$out" match)" = "true" ] || fail "suffix match: $out"
[ "$(field "$out" tag)" = "v15.0.162" ] || fail "suffix tag: $out"
[ "$(field "$out" source)" = "head" ] || fail "suffix source: $out"
pass "release: v15.0.162 (#310) → v15.0.162"

echo "[3] squash: prerelease"
out="$(run_parse --subject "release: v15.0.162-beta.1" --no-fetch)"
[ "$(field "$out" tag)" = "v15.0.162-beta.1" ] || fail "prerelease tag: $out"
pass "release: v15.0.162-beta.1"

echo "[4] squash path does not call gh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
printf '#!/bin/sh\necho "gh must not run on the squash path" >&2\nexit 1\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
out="$(PATH="$TMP/bin:$PATH" run_parse --subject "release: v1.2.3")"
[ "$(field "$out" match)" = "true" ] || fail "bomb-gh squash: $out"
[ "$(field "$out" source)" = "head" ] || fail "bomb-gh source: $out"
pass "head match never fetches"

echo "[5] non-release head, not a merge"
out="$(run_parse --subject "chore(release): stamp v15.0.162" --no-fetch)"
[ "$(field "$out" match)" = "false" ] || fail "stamp should not match: $out"
[ -z "$(field "$out" tag)" ] || fail "stamp leaked tag: $out"
pass "chore(release) stamp is not a release"

echo "[6] merge: second-parent subject (live PR 310 shape)"
out="$(run_parse \
  --subject "Merge pull request #310 from indigoai-us/promote/auto-main" \
  --parent2-subject "release: v15.0.162" \
  --no-fetch)"
[ "$(field "$out" match)" = "true" ] || fail "parent2 match: $out"
[ "$(field "$out" tag)" = "v15.0.162" ] || fail "parent2 tag: $out"
[ "$(field "$out" source)" = "parent2" ] || fail "parent2 source: $out"
pass "merge + parent2 subject → v15.0.162 source=parent2"

echo "[7] merge: PR title when parent2 is not a release"
out="$(run_parse \
  --subject "Merge pull request #310 from indigoai-us/promote/auto-main" \
  --parent2-subject "chore: leftover on promote branch" \
  --pr-title "release: v15.0.162" \
  --no-fetch)"
[ "$(field "$out" match)" = "true" ] || fail "pr-title match: $out"
[ "$(field "$out" tag)" = "v15.0.162" ] || fail "pr-title tag: $out"
[ "$(field "$out" source)" = "pr" ] || fail "pr-title source: $out"
pass "merge + PR title → v15.0.162 source=pr"

echo "[8] PR title ignored unless the head is a merge"
out="$(run_parse \
  --subject "docs: mention release: v15.0.162 in the changelog" \
  --pr-title "release: v15.0.162" \
  --no-fetch)"
[ "$(field "$out" match)" = "false" ] || fail "non-merge must ignore PR title: $out"
pass "non-merge does not use PR title"

echo "[9] merge with no release on parent2 or PR"
out="$(run_parse \
  --subject "Merge pull request #99 from indigoai-us/fix/core-foo" \
  --parent2-subject "fix(core): foo" \
  --pr-title "fix(core): foo" \
  --no-fetch)"
[ "$(field "$out" match)" = "false" ] || fail "fix merge should not tag: $out"
pass "non-release merge stays untagged"

echo "[10] multiline head uses only the first line (squash body ignored)"
out="$(run_parse --subject "$(printf 'release: v9.9.9\n\nMore body')" --no-fetch)"
[ "$(field "$out" tag)" = "v9.9.9" ] || fail "multiline squash: $out"
pass "first line of squash message"

echo "[11] GITHUB_OUTPUT contract"
gho="$TMP/github-output"
: > "$gho"
out="$(env -u MSG -u RELEASE_SUBJECT GITHUB_OUTPUT="$gho" "$PARSE" --subject "release: v2.0.0" --no-fetch)"
grep -qx 'match=true' "$gho" || fail "GITHUB_OUTPUT missing match: $(cat "$gho")"
grep -qx 'tag=v2.0.0' "$gho" || fail "GITHUB_OUTPUT missing tag: $(cat "$gho")"
grep -qx 'source=head' "$gho" || fail "GITHUB_OUTPUT missing source: $(cat "$gho")"
pass "writes match/tag/source to GITHUB_OUTPUT"

echo "[12] workflow invokes the script (no inline-only parse)"
grep -q 'core/scripts/parse-release-tag.sh' "$WORKFLOW" \
  || fail "auto-tag-release.yml must call parse-release-tag.sh"
grep -q 'github.event.head_commit.message' "$WORKFLOW" \
  || fail "workflow must still pass the head commit message"
# The old inline regex must not come back as the only parser.
if grep -n 'head -1' "$WORKFLOW" | grep -vq parse-release-tag; then
  fail "inline head-subject parse leaked back into auto-tag-release.yml"
fi
pass "workflow delegates parse to the script"

echo "[13] gh api merge-commit fetch (parent2 + pulls)"
if ! command -v jq >/dev/null 2>&1; then
  echo "  skip: jq not available for gh-stub --jq"
else
  mkdir -p "$TMP/ghbin" "$TMP/fixtures"
  cat > "$TMP/fixtures/merge.json" <<'JSON'
{"sha":"MERGE_SHA","commit":{"message":"Merge pull request #310 from indigoai-us/promote/auto-main"},"parents":[{"sha":"P1_SHA"},{"sha":"P2_SHA"}]}
JSON
  cat > "$TMP/fixtures/parent2.json" <<'JSON'
{"sha":"P2_SHA","commit":{"message":"release: v15.0.162\n\nPromote staging to hq-core"},"parents":[{"sha":"P0_SHA"}]}
JSON
  cat > "$TMP/fixtures/pulls.json" <<'JSON'
[{"number":310,"title":"release: v15.0.162","merged_at":"2026-09-24T00:00:00Z"}]
JSON
  cat > "$TMP/ghbin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prev=""
path=""
jq_filter=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then
    jq_filter="$a"
    prev=""
    continue
  fi
  case "$a" in
    api|--jq) prev="$a"; continue ;;
    *) path="$a"; prev="" ;;
  esac
done
fx="${GH_FIXTURE_DIR:-}"
body=""
case "$path" in
  repos/indigoai-us/hq-core/commits/MERGE_SHA/pulls)
    body="$(cat "$fx/pulls.json")"
    ;;
  repos/indigoai-us/hq-core/commits/MERGE_SHA)
    body="$(cat "$fx/merge.json")"
    ;;
  repos/indigoai-us/hq-core/commits/P2_SHA)
    body="$(cat "$fx/parent2.json")"
    ;;
  *)
    echo "unexpected gh api path: $path" >&2
    exit 1
    ;;
esac
if [ -n "$jq_filter" ]; then
  printf '%s' "$body" | jq -r "$jq_filter"
else
  printf '%s\n' "$body"
fi
EOF
  chmod +x "$TMP/ghbin/gh"

  out="$(
    PATH="$TMP/ghbin:$PATH" GH_FIXTURE_DIR="$TMP/fixtures" \
      run_parse \
        --subject "Merge pull request #310 from indigoai-us/promote/auto-main" \
        --sha MERGE_SHA \
        --repo indigoai-us/hq-core
  )"
  [ "$(field "$out" match)" = "true" ] || fail "gh parent2 match: $out"
  [ "$(field "$out" tag)" = "v15.0.162" ] || fail "gh parent2 tag: $out"
  [ "$(field "$out" source)" = "parent2" ] || fail "gh parent2 source: $out"
  pass "gh api second parent → v15.0.162"

  # Parent2 is not a release; PR title is.
  cat > "$TMP/fixtures/parent2.json" <<'JSON'
{"sha":"P2_SHA","commit":{"message":"chore: leftover on promote branch"},"parents":[{"sha":"P0_SHA"}]}
JSON
  out="$(
    PATH="$TMP/ghbin:$PATH" GH_FIXTURE_DIR="$TMP/fixtures" \
      run_parse \
        --subject "Merge pull request #310 from indigoai-us/promote/auto-main" \
        --sha MERGE_SHA \
        --repo indigoai-us/hq-core
  )"
  [ "$(field "$out" match)" = "true" ] || fail "gh pr match: $out"
  [ "$(field "$out" tag)" = "v15.0.162" ] || fail "gh pr tag: $out"
  [ "$(field "$out" source)" = "pr" ] || fail "gh pr source: $out"
  pass "gh api commits/<sha>/pulls title → v15.0.162"
fi

echo "PASS: parse-release-tag"
