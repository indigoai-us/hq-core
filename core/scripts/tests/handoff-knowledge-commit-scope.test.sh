#!/usr/bin/env bash
# Proves handoff knowledge commits are limited to the explicit session changeset.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
SKILL="$ROOT/.claude/skills/handoff/SKILL.md"
HELPER="$ROOT/core/scripts/handoff-knowledge-commit.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/handoff-knowledge-commit.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

step_one="$(sed -n '/^### 1\./,/^### 2\./p' "$SKILL")"
[[ "$step_one" == *"handoff-knowledge-commit.sh"* ]] || fail 'Step 1 invokes the scoped knowledge commit helper'
[[ "$step_one" == *'--files-touched-json-file'* ]] || fail 'Step 1 passes the session changeset to the helper'
! grep -Fq 'git add -A' <<<"$step_one" || fail 'Step 1 does not stage whole repositories'
! grep -Fq 'for knowledge_path in' <<<"$step_one" || fail 'Step 1 does not walk all knowledge repositories'
ok 'handoff skill routes knowledge commits through the session changeset'

[ -f "$HELPER" ] || fail 'scoped knowledge commit helper exists'
fixture_root="$TMP/hq"
repo="$fixture_root/core/knowledge/public/sample"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name 'Feedback Test'
git -C "$repo" config user.email 'feedback-test@example.invalid'
printf 'base\n' > "$repo/base.md"
git -C "$repo" add -- base.md
git -C "$repo" commit -q -m base
printf 'session edit\n' > "$repo/session.md"
printf 'unrelated edit\n' > "$repo/unrelated.md"
git -C "$repo" add -- unrelated.md
printf '["core/knowledge/public/sample/session.md"]\n' > "$TMP/changeset.json"
bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/changeset.json"
committed="$(git -C "$repo" show --pretty=format: --name-only HEAD | sed '/^$/d')"
[ "$committed" = 'session.md' ] || fail "commit contains only the session file (got: $committed)"
staged="$(git -C "$repo" diff --cached --name-only)"
[ "$staged" = 'unrelated.md' ] || fail "unrelated staged work remains outside the commit (got: $staged)"
[ "$(cat "$repo/unrelated.md")" = 'unrelated edit' ] || fail 'unrelated working content remains intact'
ok 'helper commits the allowlisted file and preserves unrelated staged work'

legacy_repo="$TMP/legacy-knowledge"
mkdir -p "$legacy_repo" "$fixture_root/core/knowledge/public" "$fixture_root/companies/acme"
git -C "$legacy_repo" init -q
git -C "$legacy_repo" config user.name 'Feedback Test'
git -C "$legacy_repo" config user.email 'feedback-test@example.invalid'
printf 'base\n' > "$legacy_repo/base.md"
git -C "$legacy_repo" add -- base.md
git -C "$legacy_repo" commit -q -m base
legacy_head="$(git -C "$legacy_repo" rev-parse HEAD)"
printf 'uncommitted legacy edit\n' > "$legacy_repo/pending.md"
ln -s "$legacy_repo" "$fixture_root/core/knowledge/public/legacy"
company_target="$TMP/company-knowledge"
mkdir -p "$company_target"
ln -s "$company_target" "$fixture_root/companies/acme/knowledge"
printf '["core/knowledge/public/legacy/pending.md","companies/acme/knowledge/notes.md"]\n' > "$TMP/symlink-changeset.json"
symlink_output="$(bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/symlink-changeset.json")"
legacy_warning="INVALID-DIRTY: core/knowledge/public/legacy is a legacy knowledge symlink to $legacy_repo with uncommitted changes — NOT auto-committed; run hq reindex to materialize it, then commit, before archiving this session"
[[ "$symlink_output" == *"$legacy_warning"* ]] || fail 'dirty legacy knowledge symlink is reported with the established wording'
[[ "$symlink_output" == *'NOT-COMMITTED: core/knowledge/public/legacy/pending.md'* ]] || fail 'listed legacy symlink path is reported as not committed'
[[ "$symlink_output" == *'INVALID-LINK: companies/acme/knowledge is a symlink; company knowledge must be a plain directory synced through the company vault'* ]] || fail 'company knowledge symlink is reported with the established wording'
[[ "$symlink_output" != *'NOT-COMMITTED: companies/acme/knowledge/notes.md'* ]] || fail 'company knowledge symlink is not treated as a git repository path'
[ "$(git -C "$legacy_repo" rev-parse HEAD)" = "$legacy_head" ] || fail 'legacy symlink target was not committed'
[ -z "$(git -C "$legacy_repo" diff --cached --name-only)" ] || fail 'legacy symlink target was not staged'
[ -z "$(git -C "$legacy_repo" status --porcelain -- pending.md)" ] && fail 'legacy symlink dirty file was not preserved'
ok 'helper reports invalid symlinks and leaves linked repositories untouched'

mkdir -p "$fixture_root/companies/beta/knowledge" "$fixture_root/personal/knowledge/untracked"
printf 'company knowledge\n' > "$fixture_root/companies/beta/knowledge/notes.md"
printf '["companies/beta/knowledge/notes.md"]\n' > "$TMP/company-changeset.json"
company_output="$(bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/company-changeset.json")"
[[ "$company_output" != *'NOT-COMMITTED:'* ]] || fail 'plain company knowledge changes are not reported as uncommitted'
ok 'plain company knowledge remains outside git commit reporting'

printf 'personal note\n' > "$fixture_root/personal/knowledge/untracked/note.md"
printf '["personal/knowledge/untracked/note.md"]\n' > "$TMP/uncommittable-changeset.json"
uncommittable_output="$(bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/uncommittable-changeset.json")"
[[ "$uncommittable_output" == *'NOT-COMMITTED: personal/knowledge/untracked/note.md'* ]] || fail 'uncommittable personal knowledge path is reported'
ok 'listed personal knowledge outside a git repository is reported'
nested_dir="$repo/nested"
mkdir -p "$nested_dir"
printf 'nested base\n' > "$nested_dir/base.md"
git -C "$repo" add -- nested/base.md
git -C "$repo" commit -q -m nested-base
printf 'nested tracked edit\n' > "$nested_dir/changed.md"
printf 'nested untracked edit\n' > "$nested_dir/new.md"
printf 'outside edit\n' > "$repo/outside.md"
printf '["core/knowledge/public/sample/nested"]\n' > "$TMP/directory-changeset.json"
mkdir -p "$fixture_root/workspace/threads/.handoff-tmp"
directory_output="$(bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/directory-changeset.json")"
[[ "$directory_output" != *"NOT-COMMITTED: core/knowledge/public/sample/nested"* ]] || fail 'committed directory changeset is not reported as uncommitted'
nested_committed="$(git -C "$repo" show --pretty=format: --name-only HEAD | sed '/^$/d' | sort)"
[ "$nested_committed" = $'nested/changed.md\nnested/new.md' ] || fail "directory changeset commits only changed nested files (got: $nested_committed)"
[ "$(git -C "$repo" status --porcelain -- outside.md)" = '?? outside.md' ] || fail 'directory changeset leaves files outside its scope untouched'
ok 'directory changeset expands to changed nested files'
printf '[]\n' > "$TMP/empty-changeset.json"
TMPDIR="$TMP/missing-tmpdir" bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/empty-changeset.json"
ok 'helper uses workspace-local temp storage when TMPDIR is unavailable'

echo 'handoff-knowledge-commit-scope: PASS'
