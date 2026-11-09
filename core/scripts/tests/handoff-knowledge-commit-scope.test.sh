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
mkdir -p "$fixture_root/companies"
printf 'companies:\n  acme:\n    name: Acme\n  beta:\n    name: Beta\n' > "$fixture_root/companies/manifest.yaml"
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
symlink_output="$(HQ_ACTIVE_COMPANY=acme bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/symlink-changeset.json")"
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

# Company-owned knowledge is committed only for the active company, and is
# explicitly skipped when the session has no company binding.
acme_repo="$fixture_root/companies/acme/knowledge"
beta_repo="$fixture_root/companies/beta/knowledge"
rm -rf "$fixture_root/companies/acme" "$fixture_root/companies/beta"
for company_repo in "$acme_repo" "$beta_repo"; do
  mkdir -p "$company_repo"
  git -C "$company_repo" init -q
  git -C "$company_repo" config user.name 'Feedback Test'
  git -C "$company_repo" config user.email 'feedback-test@example.invalid'
  printf 'base\n' > "$company_repo/README.md"
  git -C "$company_repo" add -- README.md
  git -C "$company_repo" commit -q -m base
done
acme_base="$(git -C "$acme_repo" rev-parse HEAD)"
beta_base="$(git -C "$beta_repo" rev-parse HEAD)"
printf 'acme session note\n' > "$acme_repo/acme-note.md"
printf 'beta session note\n' > "$beta_repo/beta-note.md"
printf '["companies/acme/knowledge/acme-note.md","companies/beta/knowledge/beta-note.md"]\n' \
  > "$TMP/company-scope-changeset.json"
company_scope_output="$(HQ_ACTIVE_COMPANY=acme bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/company-scope-changeset.json")"
[[ "$company_scope_output" != *'SKIPPED-COMPANY-KNOWLEDGE'* ]] \
  || fail 'bound acme session does not skip company knowledge'
acme_commit="$(git -C "$acme_repo" rev-parse HEAD)"
beta_commit="$(git -C "$beta_repo" rev-parse HEAD)"
[ "$acme_commit" != "$acme_base" ] || fail 'active acme knowledge repo receives a new commit'
acme_committed="$(git -C "$acme_repo" show --pretty=format: --name-only HEAD | sed '/^$/d')"
[ "$acme_committed" = 'acme-note.md' ] || fail "acme commit contains its listed file (got: $acme_committed)"
[ "$beta_commit" = "$beta_base" ] || fail 'inactive beta knowledge repo receives no new commit'
[ "$(git -C "$beta_repo" status --porcelain -- beta-note.md)" = '?? beta-note.md' ] \
  || fail 'beta listed file remains uncommitted'

acme_unbound_head="$(git -C "$acme_repo" rev-parse HEAD)"
beta_unbound_head="$(git -C "$beta_repo" rev-parse HEAD)"
printf 'acme unbound note\n' > "$acme_repo/acme-unbound.md"
printf 'beta unbound note\n' > "$beta_repo/beta-unbound.md"
printf '["companies/acme/knowledge/acme-unbound.md","companies/beta/knowledge/beta-unbound.md"]\n' \
  > "$TMP/unbound-company-changeset.json"
unbound_output="$(env -u HQ_ACTIVE_COMPANY bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/unbound-company-changeset.json")"
[[ "$unbound_output" == *'SKIPPED-COMPANY-KNOWLEDGE'* ]] \
  || fail 'unbound session reports SKIPPED-COMPANY-KNOWLEDGE'
[ "$(git -C "$acme_repo" rev-parse HEAD)" = "$acme_unbound_head" ] \
  || fail 'unbound session creates no acme commit'
[ "$(git -C "$beta_repo" rev-parse HEAD)" = "$beta_unbound_head" ] \
  || fail 'unbound session creates no beta commit'
[ "$(git -C "$acme_repo" status --porcelain -- acme-unbound.md)" = '?? acme-unbound.md' ] \
  || fail 'unbound acme file remains uncommitted'
[ "$(git -C "$beta_repo" status --porcelain -- beta-unbound.md)" = '?? beta-unbound.md' ] \
  || fail 'unbound beta file remains uncommitted'
ok 'company knowledge commits stay scoped to the bound company and skip when unbound'

# A company bound mid-session (hq-session.sh set/add company) is written to the
# session lock but cannot change HQ_ACTIVE_COMPANY of the running process
# (feedback_ea44cf30). With the env var empty the helper must resolve the
# company from the session lock, and only that company.
acme_lock_head="$(git -C "$acme_repo" rev-parse HEAD)"
beta_lock_head="$(git -C "$beta_repo" rev-parse HEAD)"
mkdir -p "$fixture_root/workspace/sessions/lock-acme" "$fixture_root/workspace/sessions/lock-personal"
printf 'session_id: lock-acme\ncompany_slug: acme\ncompany_slugs: acme\n' > "$fixture_root/workspace/sessions/lock-acme/meta.yaml"
printf 'session_id: lock-personal\ncompany_slug: personal\n' > "$fixture_root/workspace/sessions/lock-personal/meta.yaml"
printf 'acme lock note\n' > "$acme_repo/acme-lock.md"
printf 'beta lock note\n' > "$beta_repo/beta-lock.md"
printf '["companies/acme/knowledge/acme-lock.md","companies/beta/knowledge/beta-lock.md"]\n' \
  > "$TMP/lock-changeset.json"

personal_lock_output="$(env -u HQ_ACTIVE_COMPANY -u CLAUDE_CODE_SESSION_ID HQ_SESSION_ID=lock-personal HQ_HQ_SESSION_NO_CLI=1 bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/lock-changeset.json")"
[[ "$personal_lock_output" == *'SKIPPED-COMPANY-KNOWLEDGE'* ]] \
  || fail 'session locked to personal still reports SKIPPED-COMPANY-KNOWLEDGE'
[ "$(git -C "$acme_repo" rev-parse HEAD)" = "$acme_lock_head" ] || fail 'personal lock creates no acme commit'

lock_output="$(env -u HQ_ACTIVE_COMPANY -u CLAUDE_CODE_SESSION_ID HQ_SESSION_ID=lock-acme HQ_HQ_SESSION_NO_CLI=1 bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/lock-changeset.json")"
[[ "$lock_output" != *'SKIPPED-COMPANY-KNOWLEDGE'* ]] \
  || fail 'session locked to acme with an empty HQ_ACTIVE_COMPANY does not skip company knowledge'
[ "$(git -C "$acme_repo" rev-parse HEAD)" != "$acme_lock_head" ] \
  || fail 'session lock company (acme) knowledge is committed'
[ "$(git -C "$acme_repo" show --pretty=format: --name-only HEAD | sed '/^$/d')" = 'acme-lock.md' ] \
  || fail 'only the listed acme file is committed from the session lock'
[ "$(git -C "$beta_repo" rev-parse HEAD)" = "$beta_lock_head" ] \
  || fail 'session lock never widens to beta knowledge'
[ "$(git -C "$beta_repo" status --porcelain -- beta-lock.md)" = '?? beta-lock.md' ] \
  || fail 'beta file outside the lock remains uncommitted'

env_wins_output="$(HQ_ACTIVE_COMPANY=beta HQ_SESSION_ID=lock-acme HQ_HQ_SESSION_NO_CLI=1 bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/lock-changeset.json")"
[[ "$env_wins_output" != *'SKIPPED-COMPANY-KNOWLEDGE'* ]] || fail 'explicit HQ_ACTIVE_COMPANY still binds'
[ "$(git -C "$beta_repo" show --pretty=format: --name-only HEAD | sed '/^$/d')" = 'beta-lock.md' ] \
  || fail 'explicit HQ_ACTIVE_COMPANY keeps precedence over the session lock'
ok 'handoff resolves the bound company from the session lock when HQ_ACTIVE_COMPANY is empty'

# --- Hardening (review of the session-lock fix) ---------------------------
NOENV=(-u HQ_ACTIVE_COMPANY -u HQ_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID)

# 1. No session env: workspace/sessions/.current (a global last-writer-wins
# pointer that can name another live session) must never be consulted.
acme_cur_head="$(git -C "$acme_repo" rev-parse HEAD)"
printf 'current pointer note\n' > "$acme_repo/acme-current.md"
printf '["companies/acme/knowledge/acme-current.md"]\n' > "$TMP/current-changeset.json"
printf 'lock-acme\n' > "$fixture_root/workspace/sessions/.current"
current_output="$(env "${NOENV[@]}" HQ_HQ_SESSION_NO_CLI=1 bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/current-changeset.json")"
[[ "$current_output" == *'SKIPPED-COMPANY-KNOWLEDGE: no bound company (no session id in the environment'* ]] \
  || fail '.current without a session env id reports SKIPPED-COMPANY-KNOWLEDGE'
[ "$(git -C "$acme_repo" rev-parse HEAD)" = "$acme_cur_head" ] \
  || fail '.current pointing at an acme-locked session creates no acme commit'
[ "$(git -C "$acme_repo" status --porcelain -- acme-current.md)" = '?? acme-current.md' ] \
  || fail 'acme file stays uncommitted when only .current names the session'
ok 'workspace/sessions/.current is never used to pick the company'

# 2. Multi-company lock: only the primary company_slug is used.
mkdir -p "$fixture_root/workspace/sessions/lock-multi"
printf 'session_id: lock-multi\ncompany_slug: acme\ncompany_slugs: acme,beta\n' > "$fixture_root/workspace/sessions/lock-multi/meta.yaml"
acme_multi_head="$(git -C "$acme_repo" rev-parse HEAD)"
beta_multi_head="$(git -C "$beta_repo" rev-parse HEAD)"
printf 'multi acme\n' > "$acme_repo/acme-multi.md"
printf 'multi beta\n' > "$beta_repo/beta-multi.md"
printf '["companies/acme/knowledge/acme-multi.md","companies/beta/knowledge/beta-multi.md"]\n' > "$TMP/multi-changeset.json"
multi_output="$(env "${NOENV[@]}" HQ_SESSION_ID=lock-multi HQ_HQ_SESSION_NO_CLI=1 bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/multi-changeset.json")"
[[ "$multi_output" != *'SKIPPED-COMPANY-KNOWLEDGE'* ]] || fail 'multi-company lock binds its primary company'
[ "$(git -C "$acme_repo" rev-parse HEAD)" != "$acme_multi_head" ] || fail 'primary company acme is committed'
[ "$(git -C "$acme_repo" show --pretty=format: --name-only HEAD | sed '/^$/d')" = 'acme-multi.md' ] \
  || fail 'only the listed acme file is committed'
[ "$(git -C "$beta_repo" rev-parse HEAD)" = "$beta_multi_head" ] || fail 'secondary lock company beta gets no commit'
[ "$(git -C "$beta_repo" status --porcelain -- beta-multi.md)" = '?? beta-multi.md' ] || fail 'beta file stays untouched'
ok 'multi-company lock commits only the primary company'

# 3. A slug without a real company directory and exact-case manifest entry is
# unbound, for both the env and the lock paths.
mkdir -p "$fixture_root/companies/gamma/knowledge"
gamma_out="$(env "${NOENV[@]}" HQ_ACTIVE_COMPANY=gamma bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/multi-changeset.json")"
[[ "$gamma_out" == *"SKIPPED-COMPANY-KNOWLEDGE: company 'gamma' is not a registered company"* ]] \
  || fail 'directory without a manifest entry is skipped'
ghost_out="$(env "${NOENV[@]}" HQ_ACTIVE_COMPANY=ghost bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/multi-changeset.json")"
[[ "$ghost_out" == *"company 'ghost' is not a registered company"* ]] || fail 'slug without a directory is skipped'
case_out="$(env "${NOENV[@]}" HQ_ACTIVE_COMPANY=ACME bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/multi-changeset.json")"
[[ "$case_out" == *"company 'ACME' is not a registered company"* ]] || fail 'wrong-case slug is skipped'
mkdir -p "$fixture_root/workspace/sessions/lock-gamma"
printf 'session_id: lock-gamma\ncompany_slug: gamma\n' > "$fixture_root/workspace/sessions/lock-gamma/meta.yaml"
gamma_lock_out="$(env "${NOENV[@]}" HQ_SESSION_ID=lock-gamma HQ_HQ_SESSION_NO_CLI=1 bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/multi-changeset.json")"
[[ "$gamma_lock_out" == *"company 'gamma' is not a registered company"* ]] || fail 'lock naming an unregistered company is skipped'
ok 'unregistered or wrong-case company slugs are treated as unbound'

# 4. Unreadable lock reports a distinct reason.
mkdir -p "$fixture_root/workspace/sessions/lock-bad"
printf 'session_id: lock-bad\ncompany_slug: acme\n' > "$fixture_root/workspace/sessions/lock-bad/meta.yaml"
chmod 000 "$fixture_root/workspace/sessions/lock-bad/meta.yaml"
if [ ! -r "$fixture_root/workspace/sessions/lock-bad/meta.yaml" ]; then
  bad_out="$(env "${NOENV[@]}" HQ_SESSION_ID=lock-bad HQ_HQ_SESSION_NO_CLI=1 bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/multi-changeset.json")"
  [[ "$bad_out" == *'SKIPPED-COMPANY-KNOWLEDGE: session lock unreadable'* ]] || fail 'unreadable lock reports its own reason'
  ok 'unreadable session lock reports a distinct SKIPPED reason'
else
  ok 'unreadable-lock check skipped (running with permissions that ignore chmod 000)'
fi
chmod 600 "$fixture_root/workspace/sessions/lock-bad/meta.yaml"

# 5. HQ_ACTIVE_COMPANY=personal is unbound with the same reason as the lock route.
personal_out="$(env "${NOENV[@]}" HQ_ACTIVE_COMPANY=personal bash "$HELPER" --root "$fixture_root" --files-touched-json-file "$TMP/multi-changeset.json")"
[[ "$personal_out" == *'SKIPPED-COMPANY-KNOWLEDGE: no bound company;'* ]] || fail "personal env maps to 'no bound company' (got: $personal_out)"
ok 'HQ_ACTIVE_COMPANY=personal is skipped as no bound company'

# 6. Poll fallback (no timeout/gtimeout): a hanging lock read is killed with its
# children and leaves no hkc-timeout.* file, including when the helper is TERMed.
fb="$TMP/fallback"
mkdir -p "$fb/scripts/lib" "$fb/bin" "$fb/tmp" "$fb/root/companies" "$fb/root/workspace/sessions/hang"
cp "$HELPER" "$fb/scripts/handoff-knowledge-commit.sh"
cat > "$fb/scripts/lib/session-id.sh" <<'SH'
session_id_from_env() { printf '%s' "${HQ_SESSION_ID:-}"; }
SH
cat > "$fb/scripts/hq-session.sh" <<'SH'
#!/usr/bin/env bash
sleep 60 &
echo "$$ $!" > "$HKC_PIDS"
sleep 60
SH
printf 'companies:\n  acme:\n    name: Acme\n' > "$fb/root/companies/manifest.yaml"
printf 'session_id: hang\ncompany_slug: acme\n' > "$fb/root/workspace/sessions/hang/meta.yaml"
# PATH holds only the tools the helper needs, so timeout and gtimeout are absent.
for tool in bash jq git sed awk tr mktemp rm sleep cat dirname pgrep head grep ps mkdir uname date; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  case "$tool_path" in /*) printf '#!/bin/sh\nexec %s "$@"\n' "$tool_path" > "$fb/bin/$tool"; chmod +x "$fb/bin/$tool" ;; esac
done
[ ! -e "$fb/bin/timeout" ] && [ ! -e "$fb/bin/gtimeout" ] || fail 'fallback PATH shadows timeout and gtimeout'
printf '[]\n' > "$fb/changeset.json"
run_fallback() {
  rm -f "$fb/pids"
  exec env "${NOENV[@]}" PATH="$fb/bin" TMPDIR="$fb/tmp" HQ_SESSION_ID=hang HQ_HQ_SESSION_NO_CLI=1 \
    HQ_HANDOFF_LOCK_TIMEOUT="$1" HKC_PIDS="$fb/pids" \
    "$fb/bin/bash" "$fb/scripts/handoff-knowledge-commit.sh" --root "$fb/root" --files-touched-json-file "$fb/changeset.json"
}
assert_clean() {
  local label="$1" pid
  [ -z "$(find "$fb/tmp" -mindepth 1 2>/dev/null)" ] || fail "$label: leftover temp entries: $(find "$fb/tmp" -mindepth 1)"
  [ -s "$fb/pids" ] || fail "$label: stub did not record pids"
  # shellcheck disable=SC2013 # two numeric pids, word splitting intended
  for pid in $(cat "$fb/pids"); do
    ! kill -0 "$pid" 2>/dev/null || { kill "$pid" 2>/dev/null; fail "$label: process $pid survived"; }
  done
}
fb_out="$( (run_fallback 1) )"
[[ "$fb_out" == *'SKIPPED-COMPANY-KNOWLEDGE: session lock unreadable'* ]] || fail "fallback timeout reports unreadable lock (got: $fb_out)"
assert_clean 'timeout'
ok 'fallback timeout kills the job and its children and leaves no temp file'

rm -f "$fb/pids"
run_fallback 30 >/dev/null 2>&1 &
helper_pid=$!
for _ in $(seq 1 100); do [ -s "$fb/pids" ] && break; sleep 0.1; done
[ -s "$fb/pids" ] || fail 'TERM case: stub never started'
kill -TERM "$helper_pid" 2>/dev/null || true
for _ in $(seq 1 100); do kill -0 "$helper_pid" 2>/dev/null || break; sleep 0.1; done
! kill -0 "$helper_pid" 2>/dev/null || { kill -KILL "$helper_pid" 2>/dev/null; fail 'helper did not exit after TERM'; }
wait "$helper_pid" 2>/dev/null || true
sleep 0.3
assert_clean 'TERM'
ok 'TERM during the fallback poll leaves no temp file and no orphaned job'

echo 'handoff-knowledge-commit-scope: PASS'
