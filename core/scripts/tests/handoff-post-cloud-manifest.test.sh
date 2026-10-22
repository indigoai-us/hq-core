#!/usr/bin/env bash
# handoff-post-cloud-manifest.test.sh — handoff-post must treat a company as
# cloud-backed when companies/manifest.yaml carries its cloud_uid, even with no
# company.yaml (feedback_98f2ce49-5065-4670-8544-1a3dccd9985e). It used to read
# only company.yaml `cloud: true`, so every manifest-only cloud company was
# logged "local-only" and its handoff workspace was never pushed. An explicit
# `cloud: false` still keeps the company local.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/core/scripts/lib" \
  "$REPO/.claude/hooks" \
  "$REPO/workspace/threads" \
  "$REPO/workspace/sessions/scoped-session" \
  "$REPO/companies/syntha/workspace" \
  "$TMP_ROOT/bin" "$TMP_ROOT/logs" "$TMP_ROOT/home"
cp "$SRC_ROOT/scripts/handoff-post.sh" "$REPO/core/scripts/handoff-post.sh"
cp "$SRC_ROOT/scripts/lib/session-id.sh" "$REPO/core/scripts/lib/session-id.sh"
cp "$SRC_ROOT/../.claude/hooks/mirror-thread-to-company.sh" "$REPO/.claude/hooks/mirror-thread-to-company.sh"
cp "$SRC_ROOT/scripts/skill-installed.sh" "$REPO/core/scripts/skill-installed.sh"
cp "$SRC_ROOT/scripts/lib/session-skill-catalog.sh" "$REPO/core/scripts/lib/session-skill-catalog.sh"
cat > "$REPO/core/scripts/qmd-reindex-bg.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$REPO/core/scripts/handoff-post.sh" "$REPO/core/scripts/qmd-reindex-bg.sh"
source "$SRC_ROOT/scripts/tests/lib/handoff-post-test-helpers.sh"
printf 'company_slug: syntha\n' > "$REPO/workspace/sessions/scoped-session/meta.yaml"

cat > "$TMP_ROOT/bin/hq" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "sync push" ]]; then
  printf '%s\n' "$*" >> "${HQ_SYNC_CALLS:?}"
fi
exit 0
SH
chmod +x "$TMP_ROOT/bin/hq"

cat > "$REPO/workspace/threads/T-cloud.json" <<'JSON'
{
  "thread_id": "T-cloud",
  "files_touched": [],
  "metadata": {"company": ["syntha"]}
}
JSON

# run_case <label> — run handoff-post once; echo "pushed" or "skipped".
run_case() {
  rm -f "$TMP_ROOT/hq-sync-calls" "$TMP_ROOT/logs/handoff-post.log"
  rm -rf "$REPO/companies/syntha/workspace/sessions"
  handoff_post_test_run --clean-env "$REPO" "workspace/threads/T-cloud.json" "" \
    CODEX_THREAD_ID=scoped-session \
    HOME="$TMP_ROOT/home" \
    HQ_SYNC_CALLS="$TMP_ROOT/hq-sync-calls" \
    HANDOFF_LOG_DIR="$TMP_ROOT/logs" \
    PATH="$TMP_ROOT/bin:/usr/bin:/bin" >/dev/null 2>&1 || true
  if [[ -f "$TMP_ROOT/hq-sync-calls" ]] \
     && grep -Fxq 'sync push --company syntha companies/syntha/workspace' "$TMP_ROOT/hq-sync-calls"; then
    echo pushed
  else
    echo skipped
  fi
}

write_manifest() {
  # $1: cloud_uid value, or empty for none
  {
    printf 'companies:\n'
    printf '  synthb:\n    cloud_uid: cmp_SYNTHB\n    name: Synth B\n'
    printf '  syntha:\n'
    if [[ -n "$1" ]]; then printf '    cloud_uid: %s\n' "$1"; fi
    printf '    name: Synth A\n'
  } > "$REPO/companies/manifest.yaml"
}

# 1. No company.yaml, manifest cloud_uid → cloud, pushed.
rm -f "$REPO/companies/syntha/company.yaml"
write_manifest cmp_SYNTHA
got="$(run_case)"
[[ "$got" == pushed ]] || fail "manifest cloud_uid with no company.yaml: expected pushed, got $got"

# 2. company.yaml without a cloud: line, manifest cloud_uid → pushed.
printf 'slug: syntha\n' > "$REPO/companies/syntha/company.yaml"
got="$(run_case)"
[[ "$got" == pushed ]] || fail "company.yaml without cloud: and manifest cloud_uid: expected pushed, got $got"

# 3. Explicit cloud: false wins over the manifest → skipped.
printf 'slug: syntha\ncloud: false\n' > "$REPO/companies/syntha/company.yaml"
got="$(run_case)"
[[ "$got" == skipped ]] || fail "cloud: false must stay local even with a manifest cloud_uid, got $got"
grep -Fq 'workspace-sync: skipped (company is local-only' "$TMP_ROOT/logs/handoff-post.log" \
  || fail "cloud: false skip must log the local-only reason"

# 4. No company.yaml and no cloud_uid for this company (synthb has
#    one) → skipped. The manifest lookup must not leak across company keys.
rm -f "$REPO/companies/syntha/company.yaml"
write_manifest ""
got="$(run_case)"
[[ "$got" == skipped ]] || fail "no cloud_uid for syntha must stay local, got $got"

# 5. cloud: true still pushes with no manifest at all.
rm -f "$REPO/companies/manifest.yaml"
printf 'slug: syntha\ncloud: true\n' > "$REPO/companies/syntha/company.yaml"
got="$(run_case)"
[[ "$got" == pushed ]] || fail "cloud: true with no manifest: expected pushed, got $got"

if [[ $failures -gt 0 ]]; then
  echo "handoff-post-cloud-manifest: $failures failure(s)" >&2
  exit 1
fi
echo "PASS: handoff-post resolves cloud companies from the manifest"
