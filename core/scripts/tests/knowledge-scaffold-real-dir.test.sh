#!/usr/bin/env bash
# Regression: company knowledge scaffolding must create a real plain directory,
# while cleanup must not inspect tenant directories for Git state.
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
IMPORT="${ROOT}/.claude/skills/import-context/SKILL.md"
TUTORIAL="${ROOT}/.claude/skills/tutorial/SKILL.md"
PULSE="${ROOT}/.claude/skills/knowledge-pulse/SKILL.md"
CHECKPOINT="${ROOT}/.claude/skills/checkpoint/SKILL.md"
HANDOFF="${ROOT}/.claude/skills/handoff/SKILL.md"
TAGGER="${ROOT}/core/workers/public/knowledge-tagger/worker.yaml"
README="${ROOT}/core/docs/hq/README.md"
POLICY="${ROOT}/core/policies/knowledge-repositories-never-symlink.md"

for required in "$NEWCOMPANY" "$SETUP" "$CLEANUP" "$IMPORT" "$TUTORIAL" "$PULSE" "$CHECKPOINT" "$HANDOFF" "$TAGGER" "$README" "$POLICY"; do
  [[ -f "$required" ]] || fail "required knowledge guidance missing: $required"
done

# A package may mount read-only knowledge from core/packages, but no knowledge
# entry may link to an independent repository.
root_repo="$(git -C "$ROOT" rev-parse --show-toplevel)"
while IFS= read -r link; do
  target_repo="$(git -C "$link" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$target_repo" && "$target_repo" != "$root_repo" ]]; then
    fail "knowledge symlink targets a separate git repository: $link -> $target_repo"
  fi
done < <(find "${ROOT}/core/knowledge" -type l -print)

grep -Fq 'Company knowledge at `companies/{co}/knowledge/` is always a plain directory' "$POLICY" \
  || fail "policy must define company knowledge as a plain directory"
grep -Fq 'Package-manager links from `core/knowledge/` into `core/packages/*/knowledge/`' "$POLICY" \
  || fail "policy must preserve package contributions"

grep -Fq 'plain real directory' "$NEWCOMPANY" \
  || fail "newcompany must identify company knowledge as a plain directory"
grep -Fq 'test -d companies/{slug}/knowledge && ! test -L companies/{slug}/knowledge' "$NEWCOMPANY" \
  || fail "newcompany must verify the canonical path is a real directory"
phase04="$(sed -n '/### 0.4 Create Knowledge Directory/,/### 0.5/p' "$NEWCOMPANY")"
if grep -Eq 'git[[:space:]]+(init|add|commit)|git -C' <<<"$phase04"; then
  fail "newcompany knowledge scaffold must not run Git commands"
fi

grep -Fq 'Company knowledge always stays a plain directory' "$SETUP" \
  || fail "setup must limit company knowledge to a plain directory"
grep -Fq 'The manifest `knowledge` value is the directory path' "$IMPORT" \
  || fail "import-context must treat manifest knowledge as a directory path"
if grep -Eiq 'knowledge_dirs.*optionally initialize git' "$IMPORT"; then
  fail "import-context must not offer embedded Git for company knowledge"
fi
grep -Fq 'company knowledge is a plain real directory' "$TUTORIAL" \
  || fail "tutorial must teach plain company knowledge directories"
grep -Fq 'report the changed path for vault sync' "$TAGGER" \
  || fail "knowledge-tagger retag must report its changed path for vault sync"
if grep -Eq 'git -C|git log|/\.git|repo_type="embedded"' "$PULSE"; then
  fail "knowledge-pulse must not inspect or change Git metadata for company knowledge"
fi
if grep -Eq 'ln -s .*knowledge|knowledge.*symlinked git repo|independent git repos symlinked' "$SETUP" "$NEWCOMPANY" "$IMPORT" "$TUTORIAL" "$README"; then
  fail "active setup or documentation still recommends a symlinked knowledge directory"
fi

# Extract the cleanup loop and prove a plain company directory causes no Git probe.
cleanup_loop="$(awk '
  /^ *```bash$/ { in_code=1; next }
  in_code && /^ *```$/ {
    if (code ~ /for knowledge_path in core\/knowledge\/public\//) { printf "%s", code; exit }
    in_code=0; code=""; next
  }
  in_code { sub(/^   /, ""); code=code $0 ORS }
' "$CLEANUP")"
[[ -n "$cleanup_loop" ]] || fail "cleanup knowledge scan loop not found"

fixture="$TMP/hq"
knowledge="$fixture/companies/testco/knowledge"
mkdir -p "$knowledge" "$TMP/bin"
printf '# Test Co Knowledge\n\nCompany vault content.\n' > "$knowledge/README.md"
[[ -d "$knowledge" ]] || fail "knowledge path must exist"
[[ ! -L "$knowledge" ]] || fail "knowledge path must not be a symlink"
[[ -f "$knowledge/README.md" ]] || fail "knowledge content must be materialized"
grep -Fq 'Test Co Knowledge' "$knowledge/README.md" || fail "README must contain real content"

cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PWD $*" >> "$GIT_PROBE_LOG"
exit 0
SH
chmod +x "$TMP/bin/git"
export GIT_PROBE_LOG="$TMP/git-probes.log"
output="$(cd "$fixture" && PATH="$TMP/bin:$PATH" bash -c "$cleanup_loop" 2>&1)" \
  || fail "cleanup scan failed on a plain company directory: $output"
[[ -z "$output" ]] || fail "plain company directory should not be reported as a Git repo: $output"
[[ ! -f "$GIT_PROBE_LOG" ]] || fail "cleanup must not run Git inside the company knowledge directory"

# A company knowledge symlink is reported directly without resolving or
# probing the linked repository. Company knowledge must stay at its vault path.
rm -rf "$knowledge"
legacy_repo="$TMP/legacy-company-knowledge"
mkdir -p "$legacy_repo/.git" "$(dirname "$knowledge")"
ln -s "$legacy_repo" "$knowledge"
rm -f "$GIT_PROBE_LOG"
output="$(cd "$fixture" && PATH="$TMP/bin:$PATH" bash -c "$cleanup_loop" 2>&1)" \
  || fail "cleanup scan failed on a company knowledge symlink: $output"
[[ "$output" == *"company knowledge must be a plain directory"* ]] \
  || fail "cleanup must report company knowledge symlinks: $output"
[[ ! -f "$GIT_PROBE_LOG" ]] \
  || fail "cleanup must not inspect Git state through a company knowledge symlink"

echo "knowledge-scaffold-real-dir: passed"
