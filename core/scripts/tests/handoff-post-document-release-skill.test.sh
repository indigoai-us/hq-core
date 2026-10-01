#!/usr/bin/env bash
# Regression coverage for the optional document-release follow-up.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SOURCE_ROOT="${HANDOFF_TEST_SOURCE_ROOT:-$REPO_ROOT}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
assert_log() {
  local pattern="$1" description="$2"
  if ! grep -Fq "$pattern" "$TMP_ROOT/logs/handoff-post.log"; then
    echo "FAIL: $description" >&2
    failures=$((failures + 1))
  fi
}

reject_log() {
  local pattern="$1" description="$2"
  if grep -Fq "$pattern" "$TMP_ROOT/logs/handoff-post.log"; then
    echo "FAIL: $description" >&2
    failures=$((failures + 1))
  fi
}

FIXTURE="$TMP_ROOT/hq"
mkdir -p "$FIXTURE/core/scripts/lib" \
  "$FIXTURE/.claude/skills/document-release" \
  "$FIXTURE/companies/acme/workspace" \
  "$TMP_ROOT/bin" "$TMP_ROOT/logs"

cp "$SOURCE_ROOT/core/scripts/handoff-post.sh" "$FIXTURE/core/scripts/handoff-post.sh"
cp "$SOURCE_ROOT/core/scripts/lib/session-id.sh" "$FIXTURE/core/scripts/lib/session-id.sh"
if [[ -f "$SOURCE_ROOT/core/scripts/skill-installed.sh" ]]; then
  cp "$SOURCE_ROOT/core/scripts/skill-installed.sh" "$FIXTURE/core/scripts/skill-installed.sh"
fi
if [[ -f "$SOURCE_ROOT/core/scripts/lib/session-skill-catalog.sh" ]]; then
  cp "$SOURCE_ROOT/core/scripts/lib/session-skill-catalog.sh" \
    "$FIXTURE/core/scripts/lib/session-skill-catalog.sh"
fi

cat > "$FIXTURE/core/scripts/qmd-reindex-bg.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FIXTURE/core/scripts/handoff-post.sh" "$FIXTURE/core/scripts/qmd-reindex-bg.sh"

cat > "$FIXTURE/.claude/skills/document-release/SKILL.md" <<'MD'
---
name: document-release
description: Fixture release documentation skill.
---
Fixture skill body.
MD

cat > "$TMP_ROOT/bin/hq" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP_ROOT/bin/hq"

THREAD="$TMP_ROOT/thread.json"
cat > "$THREAD" <<'JSON'
{
  "files_touched": ["companies/acme/docs/release.md"],
  "metadata": {"company": ["acme"]}
}
JSON

run_post() {
  local thread_path="$1"
  local active_company="acme"
  if [[ "$#" -ge 2 ]]; then
    active_company="$2"
  fi
  (
    cd "$FIXTURE" || exit 1
    env -i \
      PATH="$TMP_ROOT/bin:/usr/bin:/bin" \
      HOME="$TMP_ROOT/home" \
      HQ_ROOT="$FIXTURE" \
      HQ_ACTIVE_COMPANY="$active_company" \
      HANDOFF_LOG_DIR="$TMP_ROOT/logs" \
      bash core/scripts/handoff-post.sh "$thread_path" ""
  )
}

# Installed: preserve the existing eligible/pending outcome.
run_post "$THREAD"
assert_log \
  'document-release: eligible and pending runtime dispatch by handoff skill (1 scoped files; no dispatch proof)' \
  'installed document-release skill should keep the existing pending-dispatch output'

# A touched tenant must not supply the active session's skill catalog.
rm "$FIXTURE/.claude/skills/document-release/SKILL.md"
mkdir -p "$FIXTURE/companies/indigo/skills/document-release"
cat > "$FIXTURE/companies/indigo/skills/document-release/SKILL.md" <<'MD'
---
name: document-release
description: Fixture skill for a different tenant.
---
MD
cat > "$THREAD" <<'JSON'
{
  "files_touched": ["companies/indigo/docs/release.md"],
  "metadata": {"company": ["indigo"]}
}
JSON
run_post "$THREAD"
assert_log 'document-release: skipped (skill not installed)' \
  'skill installed only for a touched tenant must not satisfy the active-company check'
reject_log 'eligible and pending runtime dispatch' \
  'a touched tenant skill must not be dispatched in another active company'

# Unbound sessions can discover root skills without reading any company catalog.
rm "$FIXTURE/companies/indigo/skills/document-release/SKILL.md"
cat > "$FIXTURE/.claude/skills/document-release/SKILL.md" <<'MD'
---
name: document-release
description: Fixture release documentation skill.
---
Fixture skill body.
MD
run_post "$THREAD" ""
assert_log \
  'document-release: eligible and pending runtime dispatch by handoff skill (1 scoped files; no dispatch proof)' \
  'unbound sessions should retain root-installed document-release skills'

# Missing: skip the model dispatch and give a concise reason.
rm "$FIXTURE/.claude/skills/document-release/SKILL.md"
cat > "$THREAD" <<'JSON'
{
  "files_touched": ["companies/acme/docs/release.md"],
  "metadata": {"company": ["acme"]}
}
JSON
run_post "$THREAD"
assert_log 'document-release: skipped (skill not installed)' \
  'missing document-release skill should be recorded as skipped'
reject_log 'eligible and pending runtime dispatch' \
  'missing document-release skill must not be recorded as pending dispatch'

# No eligible files: keep the previous scope-based skip even when the skill is absent.
cat > "$THREAD" <<'JSON'
{
  "files_touched": ["README.md"],
  "metadata": {"company": ["acme"]}
}
JSON
run_post "$THREAD"
assert_log 'document-release: skipped (no company/repo files in files_touched)' \
  'thread without eligible files should retain the existing skip output'
reject_log 'document-release: skipped (skill not installed)' \
  'skill availability should not replace the no-eligible-files outcome'

# The handoff guidance must gate both dispatch and recovery output on this same resolver.
HANDOFF_SKILL="$SOURCE_ROOT/.claude/skills/handoff/SKILL.md"
if [[ ! -f "$HANDOFF_SKILL" ]] || \
  ! grep -Fq 'skill-installed.sh document-release' "$HANDOFF_SKILL" || \
  ! grep -Fq 'document-release: skipped (skill not installed)' "$HANDOFF_SKILL" || \
  ! grep -Fq 'Only when document-release is installed' "$HANDOFF_SKILL"; then
  echo 'FAIL: handoff follow-up and recovery guidance must use the installed-skill check' >&2
  failures=$((failures + 1))
fi
if [[ ! -f "$HANDOFF_SKILL" ]] || \
  ! grep -Fq 'omit the document-release recovery entry and command' "$HANDOFF_SKILL"; then
  echo 'FAIL: missing skill must suppress its Run exactly recovery command' >&2
  failures=$((failures + 1))
fi
if [[ ! -f "$HANDOFF_SKILL" ]] || \
  ! grep -Fq 'do not derive the skill scope from `.metadata.company`' "$HANDOFF_SKILL" || \
  ! grep -Fq 'HQ_ACTIVE_COMPANY' "$HANDOFF_SKILL" || \
  ! grep -Fq 'When no company is bound, the check searches root and package skills only.' "$HANDOFF_SKILL"; then
  echo 'FAIL: handoff skill availability must use the active company and allow global skills when unbound' >&2
  failures=$((failures + 1))
fi

CHECKPOINT_SKILL="$SOURCE_ROOT/.claude/skills/checkpoint/SKILL.md"
if [[ ! -f "$CHECKPOINT_SKILL" ]] || \
  ! grep -Fq 'skill-installed.sh document-release' "$CHECKPOINT_SKILL" || \
  ! grep -Fq 'If it is absent, skip this step silently.' "$CHECKPOINT_SKILL"; then
  echo 'FAIL: checkpoint document-release follow-up must use the installed-skill check' >&2
  failures=$((failures + 1))
fi

if [[ "$failures" -gt 0 ]]; then
  echo "Failed $failures handoff document-release skill assertions" >&2
  exit 1
fi

echo 'Passed 12 handoff document-release skill assertions'
