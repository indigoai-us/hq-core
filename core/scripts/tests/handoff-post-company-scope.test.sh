#!/usr/bin/env bash
# Regression coverage for handoff-post company selection and files_touched shapes.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

mkdir -p "$TMP_ROOT/repo/core/scripts/lib" \
  "$TMP_ROOT/repo/core/scripts" \
  "$TMP_ROOT/repo/.claude/hooks" \
  "$TMP_ROOT/repo/workspace/threads" \
  "$TMP_ROOT/repo/workspace/sessions/scoped-session" \
  "$TMP_ROOT/repo/companies/indigo/workspace" \
  "$TMP_ROOT/repo/.claude/skills/document-release" \
  "$TMP_ROOT/bin" \
  "$TMP_ROOT/logs"
cp "$SRC_ROOT/scripts/handoff-post.sh" "$TMP_ROOT/repo/core/scripts/handoff-post.sh"
cp "$SRC_ROOT/scripts/lib/session-id.sh" "$TMP_ROOT/repo/core/scripts/lib/session-id.sh"
cp "$SRC_ROOT/../.claude/hooks/mirror-thread-to-company.sh" "$TMP_ROOT/repo/.claude/hooks/mirror-thread-to-company.sh"
cp "$SRC_ROOT/scripts/skill-installed.sh" "$TMP_ROOT/repo/core/scripts/skill-installed.sh"
cp "$SRC_ROOT/scripts/lib/session-skill-catalog.sh" "$TMP_ROOT/repo/core/scripts/lib/session-skill-catalog.sh"
chmod +x "$TMP_ROOT/repo/core/scripts/handoff-post.sh"
cat > "$TMP_ROOT/repo/.claude/skills/document-release/SKILL.md" <<'MD'
---
name: document-release
description: Fixture release documentation skill.
---
MD
cat > "$TMP_ROOT/repo/core/scripts/qmd-reindex-bg.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP_ROOT/repo/core/scripts/qmd-reindex-bg.sh"
source "$SRC_ROOT/scripts/tests/lib/handoff-post-test-helpers.sh"
printf 'company_slug: indigo\n' > "$TMP_ROOT/repo/workspace/sessions/scoped-session/meta.yaml"

cat > "$TMP_ROOT/bin/hq" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == "sync push" ]]; then
  if [[ -n "${MIRROR_REQUIRED_PATH:-}" ]]; then
    if [[ -f "$MIRROR_REQUIRED_PATH" ]]; then
      printf 'mirror-present-before-push\n' >> "${MIRROR_ORDER_LOG:?}"
    else
      printf 'missing-mirror-before-push\n' >> "${MIRROR_ORDER_LOG:?}"
      exit 91
    fi
  fi
  printf '%s\n' "$*" >> "$HQ_SYNC_CALLS"
fi
exit 0
SH
chmod +x "$TMP_ROOT/bin/hq"

run_post() {
  local thread_path="$1"
  handoff_post_test_run --clean-env "$TMP_ROOT/repo" "$thread_path" "" \
    CODEX_THREAD_ID=scoped-session \
    HOME="$TMP_ROOT/home" \
    HQ_ACTIVE_COMPANY=acme \
    HQ_SYNC_CALLS="$TMP_ROOT/hq-sync-calls" \
    HANDOFF_LOG_DIR="$TMP_ROOT/logs" \
    PATH="$TMP_ROOT/bin:/usr/bin:/bin"
}

# The active company is acme, while this thread belongs to indigo.
cat > "$TMP_ROOT/repo/workspace/threads/T-company.json" <<'JSON'
{
  "thread_id": "T-company",
  "files_touched": [],
  "metadata": {"company": ["indigo"]}
}
JSON
run_post "workspace/threads/T-company.json"
if ! grep -Fxq 'sync push --company indigo companies/indigo/workspace' "$TMP_ROOT/hq-sync-calls"; then
  fail "company sync did not pass --company indigo for a thread whose company differs from the active company"
fi

cat > "$TMP_ROOT/repo/workspace/threads/T-files.json" <<'JSON'
{
  "thread_id": "T-files",
  "files_touched": [
    {"path": "companies/indigo/knowledge/release-note.md"},
    "repos/private/example/src/change.sh",
    {"path": 42},
    null,
    false,
    {"other": "value"},
    "README.md"
  ],
  "metadata": {"company": []}
}
JSON
run_post "workspace/threads/T-files.json"
if ! grep -Fq 'document-release: eligible and pending runtime dispatch by handoff skill (2 scoped files; no dispatch proof)' "$TMP_ROOT/logs/handoff-post.log"; then
  fail "object-form files_touched path did not count as scoped"
fi
skipped_count=$(grep -Fc 'document-release: skipped unsupported files_touched entry' "$TMP_ROOT/logs/handoff-post.log" || true)
if [[ "$skipped_count" -ne 4 ]]; then
  fail "expected one skip log line for each of 4 unsupported entries; found $skipped_count"
fi

# A zero-file handoff still carries its session-bound company through finalize,
# mirror, and post-sync while leaving the unrelated active company untouched.
ZERO_REPO="$TMP_ROOT/zero-change-repo"
ZERO_BIN="$TMP_ROOT/zero-change-bin"
ZERO_SESSION="synthetic-session-01"
mkdir -p "$ZERO_REPO/core/scripts/tests/lib" "$ZERO_REPO/core/scripts/lib" "$ZERO_REPO/.claude/hooks" \
  "$ZERO_REPO/companies/acme/workspace" "$ZERO_REPO/workspace/sessions/$ZERO_SESSION" \
  "$ZERO_REPO/workspace/threads" "$ZERO_BIN" "$TMP_ROOT/zero-change-logs" "$TMP_ROOT/zero-change-home"
cp "$SRC_ROOT/scripts/handoff-finalize.sh" "$ZERO_REPO/core/scripts/handoff-finalize.sh"
cp "$SRC_ROOT/scripts/handoff-post.sh" "$ZERO_REPO/core/scripts/handoff-post.sh"
cp "$SRC_ROOT/scripts/lib/session-id.sh" "$ZERO_REPO/core/scripts/lib/session-id.sh"
cp "$SRC_ROOT/../.claude/hooks/mirror-thread-to-company.sh" "$ZERO_REPO/.claude/hooks/mirror-thread-to-company.sh"
cp "$SRC_ROOT/scripts/tests/lib/handoff-post-test-helpers.sh" "$ZERO_REPO/core/scripts/tests/lib/handoff-post-test-helpers.sh"
chmod +x "$ZERO_REPO/core/scripts/handoff-finalize.sh" "$ZERO_REPO/core/scripts/handoff-post.sh"
cat > "$ZERO_REPO/core/scripts/qmd-reindex-bg.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$ZERO_BIN/hq" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "sync push" ]]; then
  if [[ -n "${MIRROR_REQUIRED_PATH:-}" ]]; then
    if [[ -f "$MIRROR_REQUIRED_PATH" ]]; then
      printf 'mirror-present-before-push\n' >> "${MIRROR_ORDER_LOG:?}"
    else
      printf 'missing-mirror-before-push\n' >> "${MIRROR_ORDER_LOG:?}"
      exit 91
    fi
  fi
  printf '%s|%s\n' "${HQ_ACTIVE_COMPANY:-}" "$*" >> "${HQ_SYNC_CALLS:?}"
elif [[ "${1:-} ${2:-}" == "core hq-status-summary" ]]; then
  printf '{}'
fi
exit 0
SH
cat > "$ZERO_BIN/hq-cloud" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HQ_CLOUD_CALLS:?}"
exit 99
SH
chmod +x "$ZERO_REPO/core/scripts/qmd-reindex-bg.sh" "$ZERO_BIN/hq" "$ZERO_BIN/hq-cloud"
git -C "$ZERO_REPO" init -q -b main
git -C "$ZERO_REPO" config user.name "Synthetic Handoff Test"
git -C "$ZERO_REPO" config user.email synthetic-handoff@example.invalid
printf 'synthetic base\n' > "$ZERO_REPO/README.md"
git -C "$ZERO_REPO" add README.md
git -C "$ZERO_REPO" commit -qm "synthetic fixture base"
printf 'company_slug: acme\n' > "$ZERO_REPO/workspace/sessions/$ZERO_SESSION/meta.yaml"
: > "$TMP_ROOT/zero-change-hq-sync-calls"
: > "$TMP_ROOT/zero-change-hq-cloud-calls"

rc=0
out="$(cd "$ZERO_REPO" && env -i CODEX_THREAD_ID="$ZERO_SESSION" \
  HQ_ROOT="$ZERO_REPO" HOME="$TMP_ROOT/zero-change-home" \
  HQ_ACTIVE_COMPANY=otherco \
  HQ_SYNC_CALLS="$TMP_ROOT/zero-change-hq-sync-calls" \
  HQ_CLOUD_CALLS="$TMP_ROOT/zero-change-hq-cloud-calls" \
  HANDOFF_LOG_DIR="$TMP_ROOT/zero-change-logs" PATH="$ZERO_BIN:/usr/bin:/bin" \
  bash core/scripts/handoff-finalize.sh \
    --title "Handoff: synthetic empty changeset" \
    --summary "Synthetic no-change handoff" \
    --files-touched-json '[]' \
    --next-command '' \
    --slug "synthetic-empty")" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  fail "zero-change finalizer exit code: expected 0, got $rc"
fi
thread_path="$(jq -r '.thread_path' <<<"$out")"
thread_id="$(jq -r '.thread_id' <<<"$out")"
if [[ "$(jq -r '.metadata.company | index("acme") != null' "$ZERO_REPO/$thread_path")" != "true" ]]; then
  fail "zero-change thread metadata omitted the bound company"
fi
snapshot_path="$ZERO_REPO/companies/acme/workspace/sessions/$thread_id.json"
[[ -f "$snapshot_path" ]] || fail "bound-company session snapshot was not mirrored"
cmp -s "$ZERO_REPO/$thread_path" "$snapshot_path" || fail "mirrored snapshot does not preserve the thread contents"
handoff_post_test_run --clean-env "$ZERO_REPO" "$thread_path" "" \
  CODEX_THREAD_ID="$ZERO_SESSION" \
  HQ_ACTIVE_COMPANY=otherco \
  HQ_SYNC_CALLS="$TMP_ROOT/zero-change-hq-sync-calls" \
  HQ_CLOUD_CALLS="$TMP_ROOT/zero-change-hq-cloud-calls" \
  HANDOFF_LOG_DIR="$TMP_ROOT/zero-change-logs" \
  PATH="$ZERO_BIN:/usr/bin:/bin"
if ! grep -Fxq 'otherco|sync push --company acme companies/acme/workspace' "$TMP_ROOT/zero-change-hq-sync-calls"; then
  fail "zero-change handoff did not sync the bound company while preserving active-company state"
fi
if grep -Fq 'sync push --company otherco ' "$TMP_ROOT/zero-change-hq-sync-calls"; then
  fail "zero-change handoff synced the unrelated active company"
fi
[[ ! -s "$TMP_ROOT/zero-change-hq-cloud-calls" ]] || fail "zero-change test invoked hq-cloud instead of the stubbed hq path"

# A bound-company fallback must materialize the thread mirror before attempting
# its sync push. This covers a zero-change thread whose metadata has no company.
POST_THREAD_ID="T-synthetic-post-empty-company"
POST_THREAD_PATH="workspace/threads/$POST_THREAD_ID.json"
POST_MIRROR_PATH="$ZERO_REPO/companies/acme/workspace/sessions/$POST_THREAD_ID.json"
POST_THREAD="$ZERO_REPO/$POST_THREAD_PATH"
cat > "$POST_THREAD" <<JSON
{"thread_id":"$POST_THREAD_ID","type":"handoff","created_at":"2026-09-28T00:00:00Z","updated_at":"2026-09-28T00:00:00Z","files_touched":[],"metadata":{"company":[]}}
JSON
: > "$TMP_ROOT/post-mirror-order"
: > "$TMP_ROOT/post-mirror-sync-calls"
handoff_post_test_run --clean-env "$ZERO_REPO" "$POST_THREAD_PATH" "" \
  CLAUDE_CODE_SESSION_ID="$ZERO_SESSION" \
  HQ_ACTIVE_COMPANY=otherco \
  HQ_SYNC_CALLS="$TMP_ROOT/post-mirror-sync-calls" \
  HQ_CLOUD_CALLS="$TMP_ROOT/zero-change-hq-cloud-calls" \
  MIRROR_REQUIRED_PATH="$POST_MIRROR_PATH" \
  MIRROR_ORDER_LOG="$TMP_ROOT/post-mirror-order" \
  HANDOFF_LOG_DIR="$TMP_ROOT/zero-change-logs" \
  PATH="$ZERO_BIN:/usr/bin:/bin"
if ! grep -Fxq 'mirror-present-before-push' "$TMP_ROOT/post-mirror-order"; then
  fail "bound-company sync did not verify the thread mirror before the push step"
fi
if grep -Fxq 'missing-mirror-before-push' "$TMP_ROOT/post-mirror-order"; then
  fail "handoff-post attempted a bound-company push before the thread mirror existed"
fi
if ! grep -Fxq 'otherco|sync push --company acme companies/acme/workspace' "$TMP_ROOT/post-mirror-sync-calls"; then
  fail "handoff-post did not push the bound company after creating its mirror"
fi

# Codex thread-scoped sessions must use the shared resolver in handoff-post.
CODEX_POST_THREAD_ID="T-synthetic-post-codex-thread"
CODEX_POST_THREAD_PATH="workspace/threads/$CODEX_POST_THREAD_ID.json"
CODEX_POST_MIRROR_PATH="$ZERO_REPO/companies/acme/workspace/sessions/$CODEX_POST_THREAD_ID.json"
cat > "$ZERO_REPO/$CODEX_POST_THREAD_PATH" <<JSON
{"thread_id":"$CODEX_POST_THREAD_ID","type":"handoff","created_at":"2026-09-28T00:00:00Z","updated_at":"2026-09-28T00:00:00Z","files_touched":[],"metadata":{"company":[]}}
JSON
: > "$TMP_ROOT/codex-post-mirror-order"
: > "$TMP_ROOT/codex-post-sync-calls"
handoff_post_test_run --clean-env "$ZERO_REPO" "$CODEX_POST_THREAD_PATH" "" \
  CODEX_THREAD_ID="$ZERO_SESSION" \
  HQ_ACTIVE_COMPANY=otherco \
  HQ_SYNC_CALLS="$TMP_ROOT/codex-post-sync-calls" \
  HQ_CLOUD_CALLS="$TMP_ROOT/zero-change-hq-cloud-calls" \
  MIRROR_REQUIRED_PATH="$CODEX_POST_MIRROR_PATH" \
  MIRROR_ORDER_LOG="$TMP_ROOT/codex-post-mirror-order" \
  HANDOFF_LOG_DIR="$TMP_ROOT/zero-change-logs" \
  PATH="$ZERO_BIN:/usr/bin:/bin"
if ! grep -Fxq 'mirror-present-before-push' "$TMP_ROOT/codex-post-mirror-order"; then
  fail "CODEX_THREAD_ID was not resolved to the bound-company mirror before push"
fi
if ! grep -Fxq 'otherco|sync push --company acme companies/acme/workspace' "$TMP_ROOT/codex-post-sync-calls"; then
  fail "CODEX_THREAD_ID did not select its bound company for sync"
fi

# A handoff that touches two companies must not place its complete summary in
# either company's mirror. The finalizer and post hook both see this same
# session-bound company, which used to make the full thread visible in both.
mkdir -p "$ZERO_REPO/companies/beta/workspace" \
  "$ZERO_REPO/companies/acme/knowledge" "$ZERO_REPO/companies/beta/knowledge"
printf 'synthetic acme file\n' > "$ZERO_REPO/companies/acme/knowledge/a.md"
printf 'synthetic beta file\n' > "$ZERO_REPO/companies/beta/knowledge/b.md"
git -C "$ZERO_REPO" add companies/acme/knowledge/a.md companies/beta/knowledge/b.md
git -C "$ZERO_REPO" commit -qm "add synthetic two-company handoff paths"
: > "$TMP_ROOT/multi-company-sync-calls"
MULTI_OUT="$(cd "$ZERO_REPO" && env -i CODEX_THREAD_ID="$ZERO_SESSION" \
  HQ_ROOT="$ZERO_REPO" HOME="$TMP_ROOT/zero-change-home" \
  HQ_ACTIVE_COMPANY=otherco \
  HQ_SYNC_CALLS="$TMP_ROOT/multi-company-sync-calls" \
  HQ_CLOUD_CALLS="$TMP_ROOT/zero-change-hq-cloud-calls" \
  HANDOFF_LOG_DIR="$TMP_ROOT/zero-change-logs" PATH="$ZERO_BIN:/usr/bin:/bin" \
  bash core/scripts/handoff-finalize.sh \
    --title "Handoff: two-company scope" \
    --summary "Synthetic content that must not be copied into either company" \
    --files-touched-json '["companies/acme/knowledge/a.md","companies/beta/knowledge/b.md"]' \
    --next-command '' \
    --slug "two-company")" || fail "two-company finalizer failed"
MULTI_THREAD_PATH="$(jq -r '.thread_path' <<<"$MULTI_OUT")"
MULTI_THREAD_ID="$(jq -r '.thread_id' <<<"$MULTI_OUT")"
if [[ "$(jq -c '.metadata.company' "$ZERO_REPO/$MULTI_THREAD_PATH")" != '[]' ]]; then
  fail "two-company handoff metadata should disable mirroring, got $(jq -c '.metadata.company' "$ZERO_REPO/$MULTI_THREAD_PATH")"
fi
[[ ! -e "$ZERO_REPO/companies/acme/workspace/sessions/$MULTI_THREAD_ID.json" ]] \
  || fail "finalizer copied the two-company handoff into acme"
[[ ! -e "$ZERO_REPO/companies/beta/workspace/sessions/$MULTI_THREAD_ID.json" ]] \
  || fail "finalizer copied the two-company handoff into beta"

# The generic hook must also reject multi-company metadata if invoked by a
# direct Write/Edit event instead of the handoff finalizer.
DIRECT_THREAD_ID="T-synthetic-direct-multi-company"
DIRECT_THREAD_PATH="$ZERO_REPO/workspace/threads/$DIRECT_THREAD_ID.json"
cat > "$DIRECT_THREAD_PATH" <<'JSON'
{"thread_id":"T-synthetic-direct-multi-company","type":"handoff","conversation_summary":"Synthetic cross-company summary","files_touched":["companies/acme/knowledge/a.md","companies/beta/knowledge/b.md"],"metadata":{"company":["acme","beta"]}}
JSON
jq -n --arg file_path "$DIRECT_THREAD_PATH" \
  '{tool_name:"Write",tool_input:{file_path:$file_path}}' | \
  env CODEX_THREAD_ID="$ZERO_SESSION" HQ_ROOT="$ZERO_REPO" \
    bash "$ZERO_REPO/.claude/hooks/mirror-thread-to-company.sh"
[[ ! -e "$ZERO_REPO/companies/acme/workspace/sessions/$DIRECT_THREAD_ID.json" ]] \
  || fail "generic mirror hook copied multi-company content into acme"
[[ ! -e "$ZERO_REPO/companies/beta/workspace/sessions/$DIRECT_THREAD_ID.json" ]] \
  || fail "generic mirror hook copied multi-company content into beta"

# Post-processing must also reject a multi-company handoff whose finalizer
# deliberately left metadata.company empty, rather than adding the bound
# company's mirror back in as a fallback.
handoff_post_test_run --clean-env "$ZERO_REPO" "$MULTI_THREAD_PATH" "" \
  CODEX_THREAD_ID="$ZERO_SESSION" \
  HQ_ACTIVE_COMPANY=otherco \
  HQ_SYNC_CALLS="$TMP_ROOT/multi-company-sync-calls" \
  HQ_CLOUD_CALLS="$TMP_ROOT/zero-change-hq-cloud-calls" \
  HANDOFF_LOG_DIR="$TMP_ROOT/zero-change-logs" \
  PATH="$ZERO_BIN:/usr/bin:/bin"
[[ ! -e "$ZERO_REPO/companies/acme/workspace/sessions/$MULTI_THREAD_ID.json" ]] \
  || fail "post hook reintroduced the two-company handoff into the bound acme mirror"
[[ ! -s "$TMP_ROOT/multi-company-sync-calls" ]] \
  || fail "post hook synced a two-company handoff: $(cat "$TMP_ROOT/multi-company-sync-calls")"
grep -Fq 'workspace-sync: skipped (handoff spans multiple companies)' "$TMP_ROOT/zero-change-logs/handoff-post.log" \
  || fail "post hook did not log why it skipped the multi-company mirror"

# Mixed path spellings must still reveal every company before bound-session
# fallback is applied. One path is relative with ./ and the other is absolute.
WINKS_SESSION="synthetic-winks-session"
mkdir -p "$ZERO_REPO/companies/winks/workspace" "$ZERO_REPO/companies/winks/knowledge" \
  "$ZERO_REPO/companies/acme/knowledge" "$ZERO_REPO/workspace/sessions/$WINKS_SESSION"
printf 'synthetic winks file\n' > "$ZERO_REPO/companies/winks/knowledge/x.md"
printf 'synthetic acme file\n' > "$ZERO_REPO/companies/acme/knowledge/y.md"
printf 'company_slug: winks\n' > "$ZERO_REPO/workspace/sessions/$WINKS_SESSION/meta.yaml"
git -C "$ZERO_REPO" add companies/winks/knowledge/x.md companies/acme/knowledge/y.md
git -C "$ZERO_REPO" commit -qm "add synthetic mixed-form company handoff paths"
MIXED_PATHS_JSON="$(jq -cn --arg root "$ZERO_REPO" '["./companies/winks/knowledge/x.md", ($root + "/companies/acme/knowledge/y.md")]')"

: > "$TMP_ROOT/mixed-finalize-sync-calls"
MIXED_OUT="$(cd "$ZERO_REPO" && env -i CODEX_THREAD_ID="$WINKS_SESSION" \
  HQ_ROOT="$ZERO_REPO" HOME="$TMP_ROOT/zero-change-home" \
  HQ_ACTIVE_COMPANY=otherco \
  HQ_SYNC_CALLS="$TMP_ROOT/mixed-finalize-sync-calls" \
  HQ_CLOUD_CALLS="$TMP_ROOT/zero-change-hq-cloud-calls" \
  HANDOFF_LOG_DIR="$TMP_ROOT/zero-change-logs" PATH="$ZERO_BIN:/usr/bin:/bin" \
  bash core/scripts/handoff-finalize.sh \
    --title "Handoff: mixed-form company paths" \
    --summary "Synthetic mixed-form company scope" \
    --files-touched-json "$MIXED_PATHS_JSON" \
    --next-command '' \
    --slug "mixed-form")" || fail "mixed-form finalizer failed"
MIXED_THREAD_ID="$(jq -r '.thread_id' <<<"$MIXED_OUT")"
if [[ "$(jq -c '.mirror_companies' <<<"$MIXED_OUT")" != '[]' ]]; then
  fail "mixed-form finalizer should skip all company mirrors, got $(jq -c '.mirror_companies' <<<"$MIXED_OUT")"
fi
[[ ! -e "$ZERO_REPO/companies/winks/workspace/sessions/$MIXED_THREAD_ID.json" ]] \
  || fail "finalizer mirrored a mixed-company handoff into bound winks"

# handoff-post must make the same decision before its bound-company fallback.
MIXED_POST_ID="T-synthetic-post-mixed-form"
MIXED_POST_PATH="workspace/threads/$MIXED_POST_ID.json"
MIXED_POST_MIRROR="$ZERO_REPO/companies/winks/workspace/sessions/$MIXED_POST_ID.json"
cat > "$ZERO_REPO/$MIXED_POST_PATH" <<JSON
{"thread_id":"$MIXED_POST_ID","type":"handoff","created_at":"2026-09-28T00:00:00Z","updated_at":"2026-09-28T00:00:00Z","files_touched":["./companies/winks/knowledge/x.md","$ZERO_REPO/companies/acme/knowledge/y.md"],"metadata":{"company":[]}}
JSON
: > "$TMP_ROOT/mixed-post-sync-calls"
handoff_post_test_run --clean-env "$ZERO_REPO" "$MIXED_POST_PATH" "" \
  CODEX_THREAD_ID="$WINKS_SESSION" \
  HQ_ACTIVE_COMPANY=otherco \
  HQ_SYNC_CALLS="$TMP_ROOT/mixed-post-sync-calls" \
  HQ_CLOUD_CALLS="$TMP_ROOT/zero-change-hq-cloud-calls" \
  HANDOFF_LOG_DIR="$TMP_ROOT/zero-change-logs" \
  PATH="$ZERO_BIN:/usr/bin:/bin"
[[ ! -e "$MIXED_POST_MIRROR" ]] || fail "handoff-post mirrored mixed-company content into bound winks"
[[ ! -s "$TMP_ROOT/mixed-post-sync-calls" ]] || fail "handoff-post synced a mixed-company handoff"
grep -Fq 'workspace-sync: skipped (handoff spans multiple companies)' "$TMP_ROOT/zero-change-logs/handoff-post.log" \
  || fail "handoff-post did not identify mixed-form multi-company scope"

# A direct mirror-hook event must reject the same mixed-form paths.
MIXED_HOOK_ID="T-synthetic-hook-mixed-form"
MIXED_HOOK_PATH="$ZERO_REPO/workspace/threads/$MIXED_HOOK_ID.json"
cat > "$MIXED_HOOK_PATH" <<JSON
{"thread_id":"$MIXED_HOOK_ID","type":"handoff","files_touched":["./companies/winks/knowledge/x.md","$ZERO_REPO/companies/acme/knowledge/y.md"],"metadata":{"company":["winks"]}}
JSON
jq -n --arg file_path "$MIXED_HOOK_PATH" \
  '{tool_name:"Write",tool_input:{file_path:$file_path}}' | \
  env -i CODEX_THREAD_ID="$WINKS_SESSION" HQ_ROOT="$ZERO_REPO" PATH="/usr/bin:/bin" \
    bash "$ZERO_REPO/.claude/hooks/mirror-thread-to-company.sh"
[[ ! -e "$ZERO_REPO/companies/winks/workspace/sessions/$MIXED_HOOK_ID.json" ]] \
  || fail "mirror hook copied mixed-company content into bound winks"

HOOK_CONTROL_ID="T-synthetic-hook-dotted-control"
HOOK_CONTROL_PATH="$ZERO_REPO/workspace/threads/$HOOK_CONTROL_ID.json"
mkdir -p "$ZERO_REPO/core/scripts/lib" "$ZERO_REPO/.codex/hooks"
cp "$SRC_ROOT/scripts/lib/session-scope-capability.sh" "$ZERO_REPO/core/scripts/lib/session-scope-capability.sh"
cat > "$ZERO_REPO/core/scripts/hqd-hook-flag-cache-lib.sh" <<'SH'
hqd_hook_flag_enabled_for() {
  [[ "$1" == multi-company-session-lock && "$2" == hooks.multi-company-session-lock ]] || return 1
  HQD_FLAG_ENABLED=true
}
SH
printf '%s\n' 'process.stdout.write("true")' > "$ZERO_REPO/.codex/hooks/codex-explicit-path-flag.cjs"
printf '{"session_id":"%s","company_slug":"winks","company_slugs":["winks","acme"]}\n' "$WINKS_SESSION" \
  > "$ZERO_REPO/workspace/sessions/$WINKS_SESSION/scope-capability.json"
POST_LOCKS_ID="T-synthetic-handoff-post-lock-redaction"
POST_LOCKS_PATH="workspace/threads/$POST_LOCKS_ID.json"
cat > "$ZERO_REPO/$POST_LOCKS_PATH" <<'JSON'
{"thread_id":"T-synthetic-handoff-post-lock-redaction","type":"handoff","files_touched":["companies/winks/knowledge/x.md"],"metadata":{"company":["winks"],"company_slugs":["winks","acme"]}}
JSON
handoff_post_test_run --clean-env "$ZERO_REPO" "$POST_LOCKS_PATH" "" \
  CODEX_THREAD_ID="$WINKS_SESSION" HOME="$TMP_ROOT/zero-change-home" \
  HQ_SYNC_CALLS="$TMP_ROOT/lock-redaction-sync-calls" \
  HANDOFF_LOG_DIR="$TMP_ROOT/zero-change-logs" PATH="$ZERO_BIN:/usr/bin:/bin"
[[ "$(jq -c '.metadata.company_slugs' "$ZERO_REPO/$POST_LOCKS_PATH")" == '["winks"]' ]] \
  || fail "handoff-post retained a locked company not touched by this handoff"
[[ "$(jq -c '.metadata.company_slugs' "$ZERO_REPO/companies/winks/workspace/sessions/$POST_LOCKS_ID.json")" == '["winks"]' ]] \
  || fail "handoff-post company mirror leaked a foreign locked company"

# A session may be locked to winks and acme while this handoff touches only
# winks. The company mirror must not expose acme in any JSON string value.
POST_CAP_ID="T-synthetic-handoff-post-capability-lockset"
POST_CAP_PATH="workspace/threads/$POST_CAP_ID.json"
cat > "$ZERO_REPO/$POST_CAP_PATH" <<'JSON'
{"thread_id":"T-synthetic-handoff-post-capability-lockset","type":"handoff","files_touched":["companies/winks/knowledge/x.md"],"metadata":{"company":["winks"]}}
JSON
handoff_post_test_run --clean-env "$ZERO_REPO" "$POST_CAP_PATH" "" \
  CODEX_THREAD_ID="$WINKS_SESSION" HOME="$TMP_ROOT/zero-change-home" \
  HQ_SYNC_CALLS="$TMP_ROOT/capability-lockset-sync-calls" \
  HANDOFF_LOG_DIR="$TMP_ROOT/zero-change-logs" PATH="$ZERO_BIN:/usr/bin:/bin"
if ! jq -e --arg foreign_company acme 'all(.. | strings; (contains($foreign_company) | not))' \
    "$ZERO_REPO/companies/winks/workspace/sessions/$POST_CAP_ID.json" >/dev/null; then
  fail "winks company mirror exposed acme in a JSON string value"
fi
cat > "$HOOK_CONTROL_PATH" <<'JSON'
{"thread_id":"T-synthetic-hook-dotted-control","type":"handoff","files_touched":["./companies/winks/knowledge/x.md"],"metadata":{"company":["winks"],"company_slugs":["winks","acme"]}}
JSON
jq -n --arg file_path "$HOOK_CONTROL_PATH" \
  '{tool_name:"Write",tool_input:{file_path:$file_path}}' | \
  env -i CODEX_THREAD_ID="$WINKS_SESSION" HQ_ROOT="$ZERO_REPO" PATH="/usr/bin:/bin" \
    bash "$ZERO_REPO/.claude/hooks/mirror-thread-to-company.sh"
[[ -f "$ZERO_REPO/companies/winks/workspace/sessions/$HOOK_CONTROL_ID.json" ]] \
  || fail "mirror hook failed to preserve a single bound-company dotted path"
[[ "$(jq -c '.metadata.company_slugs' "$ZERO_REPO/companies/winks/workspace/sessions/$HOOK_CONTROL_ID.json")" == '["winks"]' ]] \
  || fail "company mirror leaked foreign locked company identity"
[[ "$(jq -c '.metadata.company_slugs' "$HOOK_CONTROL_PATH")" == '["winks","acme"]' ]] \
  || fail "mirror redaction modified the canonical root handoff"

# Dotted relative paths for one bound company remain mirrorable.
CONTROL_OUT="$(cd "$ZERO_REPO" && env -i CODEX_THREAD_ID="$WINKS_SESSION" \
  HQ_ROOT="$ZERO_REPO" HOME="$TMP_ROOT/zero-change-home" \
  HQ_ACTIVE_COMPANY=otherco \
  HQ_SYNC_CALLS="$TMP_ROOT/mixed-finalize-sync-calls" \
  HQ_CLOUD_CALLS="$TMP_ROOT/zero-change-hq-cloud-calls" \
  HANDOFF_LOG_DIR="$TMP_ROOT/zero-change-logs" PATH="$ZERO_BIN:/usr/bin:/bin" \
  bash core/scripts/handoff-finalize.sh \
    --title "Handoff: one dotted company path" \
    --summary "Synthetic single-company dotted path" \
    --files-touched-json '["./companies/winks/knowledge/x.md"]' \
    --next-command '' \
    --slug "single-dotted")" || fail "single dotted-path finalizer failed"
CONTROL_THREAD_ID="$(jq -r '.thread_id' <<<"$CONTROL_OUT")"
if [[ "$(jq -c '.mirror_companies' <<<"$CONTROL_OUT")" != '["winks"]' ]]; then
  fail "single dotted-path finalizer should preserve the winks mirror, got $(jq -c '.mirror_companies' <<<"$CONTROL_OUT")"
fi
[[ -f "$ZERO_REPO/companies/winks/workspace/sessions/$CONTROL_THREAD_ID.json" ]] \
  || fail "single dotted-path handoff did not mirror into winks"

if [[ "$failures" -gt 0 ]]; then
  echo "Failed $failures handoff-post regression assertions" >&2
  exit 1
fi

echo "Passed handoff-post company-scope regression checks"
