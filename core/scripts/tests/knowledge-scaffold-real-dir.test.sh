#!/usr/bin/env bash
# Regression: /newcompany must scaffold companies/{slug}/knowledge/ as a real
# directory with embedded git — not a symlink into repos/ (sync uploads ~50-byte
# vault markers for symlinks and teammates receive nothing).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

NEWCOMPANY="${ROOT}/.claude/skills/newcompany/SKILL.md"
SETUP="${ROOT}/.claude/skills/setup/SKILL.md"
CLEANUP="${ROOT}/.claude/skills/cleanup/SKILL.md"

[[ -f "$NEWCOMPANY" ]] || fail "newcompany skill missing"
[[ -f "$SETUP" ]] || fail "setup skill missing"
[[ -f "$CLEANUP" ]] || fail "cleanup skill missing"

# Skill docs must forbid default symlink layout
grep -Fq 'Do **not** symlink into `repos/`' "$NEWCOMPANY" \
  || fail "newcompany must document no-symlink default"
grep -Fq 'test -d companies/{slug}/knowledge && ! test -L companies/{slug}/knowledge' "$NEWCOMPANY" \
  || fail "newcompany must include real-directory verify step"

grep -Fq 'Do **not** symlink `personal/knowledge/`' "$SETUP" \
  || fail "setup must document no-symlink for personal knowledge"
if grep -qF 'All repos — code, knowledge, company projects — live under `repos/`' "$SETUP"; then
  fail "setup still claims all knowledge lives under repos/"
fi

# cleanup audit loop must discover embedded repos, not only symlinks
grep -Fq '[ -L "$knowledge_path" ] || [ -d "$knowledge_path/.git" ] || continue' "$CLEANUP" \
  || fail "cleanup knowledge audit must handle embedded git directories"

# Scaffold fixture following newcompany documented steps
slug="testco"
name="Test Co"
fixture="$TMP/hq"
knowledge="$fixture/companies/$slug/knowledge"

mkdir -p "$knowledge/design-styles/packs"
(
  cd "$knowledge"
  git init -q
  git config user.email [EMAIL]
  git config user.name test
  printf '# %s Knowledge\n\nKnowledge base for %s.\n' "$name" "$name" > README.md
  : > design-styles/packs/.gitkeep
  git add -A
  git commit -qm "init: knowledge base"
)

# Real directory — not a symlink marker
[[ -d "$knowledge" ]] || fail "knowledge path must exist"
[[ ! -L "$knowledge" ]] || fail "knowledge path must not be a symlink"
[[ -f "$knowledge/README.md" ]] || fail "README must exist for sync-visible content"

content="$(cat "$knowledge/README.md")"
[[ "$content" == *"Test Co Knowledge"* ]] \
  || fail "README must contain real document content, not a symlink marker"

# Embedded git repo is discoverable by cleanup audit logic
printf 'dirty\n' >> "$knowledge/state.txt"
output="$(cd "$fixture" && bash -c '
shopt -s nullglob
for knowledge_path in core/knowledge/public/* core/knowledge/private/* personal/knowledge/* companies/*/knowledge; do
  [ -L "$knowledge_path" ] || [ -d "$knowledge_path/.git" ] || continue
  repo_dir=$(cd "$knowledge_path" && git rev-parse --show-toplevel 2>/dev/null) || continue
  dirty=$(cd "$repo_dir" && git status --porcelain)
  [ -z "$dirty" ] && continue
  echo "DIRTY: $knowledge_path → $repo_dir"
done
' 2>&1)" || fail "cleanup audit snippet failed on embedded knowledge repo"
grep -Fq "DIRTY: companies/$slug/knowledge → $knowledge" <<<"$output" \
  || fail "cleanup audit did not report dirty embedded knowledge repo"

echo "knowledge-scaffold-real-dir: passed"
