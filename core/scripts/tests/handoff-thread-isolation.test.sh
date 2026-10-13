#!/usr/bin/env bash
# Offline regression: 11 synthetic tenants, real writers, no HQ services.
# A handoff changeset that names many companies must not copy the full record
# into each tenant or attempt a workspace push for each.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPO_ROOT="$(cd "$SRC_ROOT/.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

ROOT="$TMP_ROOT/repo"
mkdir -p "$ROOT/core/scripts/lib" "$ROOT/.claude/hooks" "$ROOT/workspace/threads" \
  "$ROOT/bin" "$ROOT/home" "$ROOT/logs"
cp "$SRC_ROOT/scripts/handoff-finalize.sh" "$ROOT/core/scripts/handoff-finalize.sh"
cp "$SRC_ROOT/scripts/handoff-post.sh" "$ROOT/core/scripts/handoff-post.sh"
cp "$SRC_ROOT/scripts/lib/session-id.sh" "$ROOT/core/scripts/lib/session-id.sh"
cp "$REPO_ROOT/.claude/hooks/mirror-thread-to-company.sh" "$ROOT/.claude/hooks/mirror-thread-to-company.sh"
cat > "$ROOT/core/scripts/qmd-reindex-bg.sh" <<'SH'
#!/bin/sh
echo skipped-fixture
SH
chmod +x "$ROOT/core/scripts/qmd-reindex-bg.sh"

tenants=()
for i in $(seq 0 10); do
  tenants+=("tenant-$i")
done

for tenant in "${tenants[@]}"; do
  mkdir -p "$ROOT/companies/$tenant"
  printf 'synthetic\n' > "$ROOT/companies/$tenant/note.md"
  printf 'slug: %s\ncloud: true\n' "$tenant" > "$ROOT/companies/$tenant/company.yaml"
done

for cmd in jq git; do
  ln -s "$(command -v "$cmd")" "$ROOT/bin/$cmd"
done
cat > "$ROOT/bin/hq" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HQ_ROOT/hq-calls.log"
printf '{}\n'
SH
chmod +x "$ROOT/bin/hq"

export PATH="$ROOT/bin:/usr/bin:/bin"
export HOME="$ROOT/home"
export HQ_ROOT="$ROOT"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export LC_ALL=C

git -C "$ROOT" init -q
git -C "$ROOT" config user.name Fixture
git -C "$ROOT" config user.email fixture@example.invalid
git -C "$ROOT" config core.hooksPath /dev/null
git -C "$ROOT" add -A
git -C "$ROOT" commit -qm seed

mirrors() {
  find "$ROOT/companies" -path '*/workspace/sessions/*.json' 2>/dev/null | wc -l | tr -d ' '
}

rows() {
  find "$ROOT/companies" -name index.jsonl -exec cat {} + 2>/dev/null | grep -c . || true
}

run_hook() {
  local company_json="$1"
  local tid="$2"
  local path="$ROOT/workspace/threads/${tid}.json"
  jq -n --argjson company "$company_json" --arg tid "$tid" \
    '{thread_id:$tid, created_at:"fixture", type:"handoff", metadata:{company:$company}}' \
    > "$path"
  jq -n --arg file_path "$path" '{tool_name:"Write", tool_input:{file_path:$file_path}}' | \
    env PATH="$PATH" HOME="$HOME" HQ_ROOT="$HQ_ROOT" CODEX_THREAD_ID="${CODEX_THREAD_ID:-}" \
      bash "$ROOT/.claude/hooks/mirror-thread-to-company.sh"
}

# 1. Legacy 11-company metadata must be refused before any tenant write.
hook_rc=0
run_hook "$(printf '%s\n' "${tenants[@]}" | jq -R . | jq -s -c .)" T-legacy || hook_rc=$?
if [[ "$hook_rc" -eq 0 ]]; then
  fail "mirror hook accepted an 11-company ownership array"
fi
if [[ "$(mirrors)" -ne 0 || "$(rows)" -ne 0 ]]; then
  fail "ambiguous ownership broadcast full records to tenants (mirrors=$(mirrors) rows=$(rows))"
fi

# 2. A single owner string and a one-element array still mirror to that owner.
SESSION=isolation-session
mkdir -p "$ROOT/workspace/sessions/$SESSION"
printf 'company_slug: tenant-0\n' > "$ROOT/workspace/sessions/$SESSION/meta.yaml"
export CODEX_THREAD_ID="$SESSION"
export HQ_SESSION_ID="$SESSION"

for spec in 'string|"tenant-0"' 'array|["tenant-0"]'; do
  kind="${spec%%|*}"
  owner="${spec#*|}"
  tid="T-single-$kind"
  hook_rc=0
  run_hook "$owner" "$tid" || hook_rc=$?
  if [[ "$hook_rc" -ne 0 ]]; then
    fail "single-owner hook failed for $owner (rc=$hook_rc)"
  fi
  if [[ ! -f "$ROOT/companies/tenant-0/workspace/sessions/${tid}.json" ]]; then
    fail "single-owner hook did not mirror $owner into tenant-0"
  fi
done
if [[ "$(mirrors)" -ne 2 ]]; then
  fail "expected two tenant-0 mirrors, got $(mirrors)"
fi
for tenant in "${tenants[@]:1}"; do
  if find "$ROOT/companies/$tenant/workspace/sessions" -name '*.json' 2>/dev/null | grep -q .; then
    fail "single-owner hook wrote into $tenant"
  fi
done

# 3. Finalizer with 11 company paths must not stamp recipients from the changeset.
: > "$ROOT/hq-calls.log"
paths_json="$(printf '%s\n' "${tenants[@]}" | jq -R . | jq -s -c 'map("companies/" + . + "/note.md")')"
fin_rc=0
fin_out="$(
  cd "$ROOT" && env -i CODEX_THREAD_ID="$SESSION" HQ_SESSION_ID="$SESSION" \
    HQ_ROOT="$ROOT" HOME="$HOME" PATH="$PATH" LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    bash core/scripts/handoff-finalize.sh \
      --company tenant-0 \
      --title "Handoff: isolation" \
      --summary "Synthetic 11-tenant changeset" \
      --files-touched-json "$paths_json" \
      --next-command '' \
      --slug isolation
)" || fin_rc=$?
if [[ "$fin_rc" -ne 0 ]]; then
  fail "finalizer exited $fin_rc on a multi-company changeset: $fin_out"
fi
thread_path="$(jq -r '.thread_path' <<<"$fin_out")"
thread_id="$(jq -r '.thread_id' <<<"$fin_out")"
if [[ "$(jq -c '.metadata.company' "$ROOT/$thread_path")" != '[]' ]]; then
  fail "finalizer derived recipients from the changeset: $(jq -c '.metadata.company' "$ROOT/$thread_path")"
fi
if [[ "$(jq -c '.mirror_companies' <<<"$fin_out")" != '[]' ]]; then
  fail "finalizer mirrored a multi-company changeset: $(jq -c '.mirror_companies' <<<"$fin_out")"
fi
if [[ -e "$ROOT/companies/tenant-0/workspace/sessions/${thread_id}.json" ]]; then
  fail "finalizer copied the 11-tenant handoff into tenant-0"
fi

# 4. Post must refuse an 11-company metadata array and must not push any tenant.
legacy_post="$ROOT/workspace/threads/T-post-legacy.json"
jq -n --argjson company "$(printf '%s\n' "${tenants[@]}" | jq -R . | jq -s -c .)" \
  '{thread_id:"T-post-legacy", type:"handoff", files_touched:[], metadata:{company:$company}}' \
  > "$legacy_post"
: > "$ROOT/hq-calls.log"
post_rc=0
cd "$ROOT"
HANDOFF_LOG_DIR="$ROOT/logs" HQ_ROOT="$ROOT" PATH="$PATH" HOME="$HOME" \
  bash core/scripts/handoff-post.sh "$legacy_post" "" \
  && post_rc=0 || post_rc=$?
if [[ "$post_rc" -eq 0 ]]; then
  fail "handoff-post accepted 11-company ownership"
fi
if grep -E 'sync push' "$ROOT/hq-calls.log" >/dev/null 2>&1; then
  fail "handoff-post attempted tenant pushes: $(cat "$ROOT/hq-calls.log")"
fi
if grep -Fq 'workspace-sync: refused invalid or ambiguous ownership' "$ROOT/logs/handoff-post.log"; then
  :
else
  fail "handoff-post did not log the ownership refusal"
fi

# 5. Invalid --company is rejected without tenant writes.
before_mirrors="$(mirrors)"
bad_rc=0
cd "$ROOT" && env -i CODEX_THREAD_ID="$SESSION" HQ_ROOT="$ROOT" HOME="$HOME" PATH="$PATH" \
  bash core/scripts/handoff-finalize.sh \
    --company 'Not A Slug' \
    --title "Handoff: bad owner" \
    --summary "invalid" \
    --files-touched-json '["companies/tenant-0/note.md"]' \
    --next-command '' \
    --slug bad-owner \
  && bad_rc=0 || bad_rc=$?
if [[ "$bad_rc" -eq 0 ]]; then
  fail "finalizer accepted an invalid --company slug"
fi
if [[ "$(mirrors)" -ne "$before_mirrors" ]]; then
  fail "invalid --company still wrote tenant mirrors"
fi

if [[ "$failures" -gt 0 ]]; then
  echo "Failed $failures handoff isolation assertions" >&2
  exit 1
fi

echo "Passed handoff thread isolation checks"
