#!/usr/bin/env bash
# Regression: every knowledge repository must live at its canonical path as a
# real directory with optional embedded git — never as a symlink into repos/
# (sync uploads ~50-byte vault markers and teammates receive nothing).
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
IMPORT="${ROOT}/.claude/skills/import-claude/SKILL.md"
TUTORIAL="${ROOT}/.claude/skills/tutorial/SKILL.md"
README="${ROOT}/core/docs/hq/README.md"
POLICY="${ROOT}/core/policies/knowledge-repositories-never-symlink.md"

[[ -f "$NEWCOMPANY" ]] || fail "newcompany skill missing"
[[ -f "$SETUP" ]] || fail "setup skill missing"
[[ -f "$CLEANUP" ]] || fail "cleanup skill missing"
[[ -f "$IMPORT" ]] || fail "import-claude skill missing"
[[ -f "$TUTORIAL" ]] || fail "tutorial skill missing"
[[ -f "$README" ]] || fail "HQ README missing"
[[ -f "$POLICY" ]] || fail "knowledge no-symlink policy missing"

# A package may mount read-only knowledge from core/packages, but no knowledge
# entry may link to an independent repository. Compare git roots so this guard
# covers targets outside repos/ too.
root_repo="$(git -C "$ROOT" rev-parse --show-toplevel)"
while IFS= read -r link; do
  target_repo="$(git -C "$link" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$target_repo" && "$target_repo" != "$root_repo" ]]; then
    fail "knowledge symlink targets a separate git repository: $link -> $target_repo"
  fi
done < <(find "${ROOT}/core/knowledge" -type l -print)

grep -Fq 'enforcement: hard' "$POLICY" \
  || fail "knowledge no-symlink policy must be hard"
grep -Fq 'Never create a repository under' "$POLICY" \
  && grep -Fq '`repos/` and symlink the knowledge path to it.' "$POLICY" \
  || fail "knowledge no-symlink policy must state the invariant"
grep -Fq 'Package-manager links from `core/knowledge/` into `core/packages/*/knowledge/`' "$POLICY" \
  || fail "knowledge no-symlink policy must preserve package contributions"

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
if grep -Eq 'ln -s .*knowledge|knowledge.*symlinked git repo|independent git repos symlinked' "$SETUP" "$NEWCOMPANY" "$IMPORT" "$TUTORIAL" "$README"; then
  fail "active setup or documentation still recommends a symlinked knowledge repository"
fi
grep -Fq 'real canonical knowledge directory' "$IMPORT" \
  || fail "import-claude must materialize knowledge at its canonical path"
grep -Fq 'two supported knowledge storage forms' "$TUTORIAL" \
  || fail "tutorial must teach only real-directory knowledge layouts"

# cleanup audit loop must discover embedded repos. It still recognizes legacy
# symlinks only so cleanup can report them for migration.
grep -Fq '[ -d "$knowledge_path/.git" ] || continue' "$CLEANUP" \
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
  git config user.email test@example.com
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
canonical_knowledge="$(git -C "$knowledge" rev-parse --show-toplevel)"
grep -Fq "DIRTY: companies/$slug/knowledge → $canonical_knowledge" <<<"$output" \
  || fail "cleanup audit did not report dirty embedded knowledge repo"

echo "knowledge-scaffold-real-dir: passed"
