#!/usr/bin/env bash
# Offline regression: 11 synthetic tenants, real mirror hook and native
# `hq core handoff finalize` / `hq core handoff post`, no HQ services.
# A multi-company metadata array or changeset must not broadcast full records
# across tenants or push any tenant workspace, while single-owner strings,
# one-element arrays, locked multi-company sets, and digit-first slugs stay
# strictly scoped.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPO_ROOT="$(cd "$SRC_ROOT/.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() {
  local attempt=0
  while [[ -d "$TMP_ROOT" && "$attempt" -lt 10 ]]; do
    rm -rf "$TMP_ROOT" 2>/dev/null && break || true
    sleep 0.05
    attempt=$((attempt + 1))
  done
}
trap cleanup EXIT

# shellcheck source=../lib/hq-cli-floor.sh
source "$SRC_ROOT/scripts/lib/hq-cli-floor.sh"

failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

REAL_HQ="$(command -v hq 2>/dev/null || true)"
REAL_NODE="$(command -v node 2>/dev/null || true)"
REAL_HQ_VER=""
if [[ -n "$REAL_HQ" ]]; then
  REAL_HQ_VER="$(HQ_NO_UPDATE_CHECK=1 "$REAL_HQ" --version 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
fi

ROOT="$TMP_ROOT/repo"
mkdir -p "$ROOT/core/scripts/lib" "$ROOT/.claude/hooks" "$ROOT/workspace/threads" \
  "$ROOT/bin" "$ROOT/home" "$ROOT/logs"
cp "$SRC_ROOT/scripts/lib/session-id.sh" "$ROOT/core/scripts/lib/session-id.sh"
cp "$SRC_ROOT/scripts/lib/session-scope-capability.sh" "$ROOT/core/scripts/lib/session-scope-capability.sh"
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
  mkdir -p "$ROOT/companies/$tenant/workspace"
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
      HQ_SESSION_ID="${HQ_SESSION_ID:-}" \
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

# 2b. Digit-first company slugs (feedback_65f4edea). The owner regex and the
# files_touched capture used to require [a-z] as the first character.
DIGIT="31-cornwallis-crescent"
DIGIT_SESSION=digit-first-session
mkdir -p "$ROOT/companies/$DIGIT" "$ROOT/workspace/sessions/$DIGIT_SESSION"
printf 'slug: %s\ncloud: true\n' "$DIGIT" > "$ROOT/companies/$DIGIT/company.yaml"
printf 'note\n' > "$ROOT/companies/$DIGIT/note.md"
printf 'company_slug: %s\n' "$DIGIT" > "$ROOT/workspace/sessions/$DIGIT_SESSION/meta.yaml"
export CODEX_THREAD_ID="$DIGIT_SESSION"
export HQ_SESSION_ID="$DIGIT_SESSION"
digit_tid=T-digit-first
digit_path="$ROOT/workspace/threads/${digit_tid}.json"
jq -n --arg company "$DIGIT" --arg tid "$digit_tid" --arg touched "companies/${DIGIT}/note.md" \
  '{thread_id:$tid, created_at:"fixture", type:"handoff", files_touched:[$touched], metadata:{company:[$company]}}' \
  > "$digit_path"
digit_rc=0
jq -n --arg file_path "$digit_path" '{tool_name:"Write", tool_input:{file_path:$file_path}}' | \
  env PATH="$PATH" HOME="$HOME" HQ_ROOT="$HQ_ROOT" CODEX_THREAD_ID="$DIGIT_SESSION" HQ_SESSION_ID="$DIGIT_SESSION" \
    bash "$ROOT/.claude/hooks/mirror-thread-to-company.sh" || digit_rc=$?
if [[ "$digit_rc" -ne 0 ]]; then
  fail "digit-first company slug was rejected (rc=$digit_rc)"
fi
if [[ ! -f "$ROOT/companies/$DIGIT/workspace/sessions/${digit_tid}.json" ]]; then
  fail "digit-first company slug did not mirror"
fi
export CODEX_THREAD_ID="$SESSION"
export HQ_SESSION_ID="$SESSION"

# 7. Missing session meta fails closed, and loudly, when there is no lock set.
NOMETA=nometa-session
export CODEX_THREAD_ID="$NOMETA"
export HQ_SESSION_ID="$NOMETA"
mkdir -p "$ROOT/workspace/sessions/$NOMETA"
hook_rc=0
hook_err="$(run_hook '"tenant-0"' T-nometa-empty 2>&1 >/dev/null)" || hook_rc=$?
if [[ "$hook_rc" -eq 0 ]]; then
  fail "missing-meta empty-lock hook exited 0 without a mirror"
fi
if [[ "$hook_err" != *"session has no company lock"* ]]; then
  fail "missing-meta empty-lock hook did not say why it refused: $hook_err"
fi
if [[ -f "$ROOT/companies/tenant-0/workspace/sessions/T-nometa-empty.json" ]]; then
  fail "missing-meta empty-lock still mirrored tenant-0"
fi

# 8. Missing session meta still mirrors when scope-capability includes the owner.
jq -n --arg sid "$NOMETA" \
  '{session_id:$sid, agent_id:"", company_slug:"tenant-0", company_slugs:["tenant-0"]}' \
  > "$ROOT/workspace/sessions/$NOMETA/scope-capability.json"
hook_rc=0
run_hook '"tenant-0"' T-nometa || hook_rc=$?
if [[ "$hook_rc" -ne 0 ]]; then
  fail "missing-meta hook failed for tenant-0 (rc=$hook_rc)"
fi
if [[ ! -f "$ROOT/companies/tenant-0/workspace/sessions/T-nometa.json" ]]; then
  fail "missing-meta hook did not mirror tenant-0"
fi

# 9. Missing session meta does not mirror a company outside the lock set.
hook_rc=0
run_hook '"tenant-1"' T-nometa-out || hook_rc=$?
if [[ "$hook_rc" -ne 0 ]]; then
  fail "missing-meta out-of-lock hook failed (rc=$hook_rc)"
fi
if [[ -f "$ROOT/companies/tenant-1/workspace/sessions/T-nometa-out.json" ]]; then
  fail "missing-meta hook mirrored tenant-1 outside the lock set"
fi

# 10. A capability that exists but does not match this session is authoritative:
# meta.yaml must not override the refusal.
BADCAP=badcap-session
export CODEX_THREAD_ID="$BADCAP"
export HQ_SESSION_ID="$BADCAP"
mkdir -p "$ROOT/workspace/sessions/$BADCAP"
printf 'company_slug: tenant-0\n' > "$ROOT/workspace/sessions/$BADCAP/meta.yaml"
jq -n '{session_id:"another-session", agent_id:"", company_slug:"tenant-0", company_slugs:["tenant-0"]}' \
  > "$ROOT/workspace/sessions/$BADCAP/scope-capability.json"
hook_rc=0
hook_err="$(run_hook '"tenant-0"' T-badcap-mismatch 2>&1 >/dev/null)" || hook_rc=$?
if [[ "$hook_rc" -eq 0 ]]; then
  fail "mismatched capability fell back to meta.yaml (rc=0)"
fi
if [[ "$hook_err" != *"scope capability is invalid"* ]]; then
  fail "mismatched capability refusal did not say why: $hook_err"
fi
if [[ -f "$ROOT/companies/tenant-0/workspace/sessions/T-badcap-mismatch.json" ]]; then
  fail "mismatched capability still mirrored tenant-0 via meta.yaml"
fi

# 11. A malformed capability does not fall back to meta.yaml either.
printf '{not json\n' > "$ROOT/workspace/sessions/$BADCAP/scope-capability.json"
hook_rc=0
run_hook '"tenant-0"' T-badcap-malformed 2>/dev/null || hook_rc=$?
if [[ "$hook_rc" -eq 0 ]]; then
  fail "malformed capability fell back to meta.yaml (rc=0)"
fi
if [[ -f "$ROOT/companies/tenant-0/workspace/sessions/T-badcap-malformed.json" ]]; then
  fail "malformed capability still mirrored tenant-0 via meta.yaml"
fi

# 12. With no capability file, meta.yaml company_slug is still the lock set.
rm -f "$ROOT/workspace/sessions/$BADCAP/scope-capability.json"
hook_rc=0
run_hook '"tenant-0"' T-badcap-meta-only || hook_rc=$?
if [[ "$hook_rc" -ne 0 ]]; then
  fail "meta-only session hook failed (rc=$hook_rc)"
fi
if [[ ! -f "$ROOT/companies/tenant-0/workspace/sessions/T-badcap-meta-only.json" ]]; then
  fail "meta-only session did not mirror tenant-0"
fi

# Native `hq core handoff finalize` and `hq core handoff post` tenant-isolation
# assertions (3, 4, 5, 6, 7b). Requires hq-cli >= 5.345.263 (US-029 floor with
# native `--company`, mirror-hook execution, locked-set enforcement, #4006, and #4073).
native_ran=0
if [[ -n "$REAL_HQ" && -n "$REAL_NODE" && -n "$REAL_HQ_VER" ]] && hq_cli_version_ge "$REAL_HQ_VER" 5.345.263; then
  native_ran=1
  export CODEX_THREAD_ID="$SESSION"
  export HQ_SESSION_ID="$SESSION"
  NODE_DIR="$(dirname "$REAL_NODE")"
  NATIVE_PATH="$ROOT/bin:$NODE_DIR:/usr/bin:/bin"

  # 3. Native finalizer with 11 company paths must not stamp recipients from
  # the changeset or mirror into tenant-0.
  : > "$ROOT/hq-calls.log"
  paths_json="$(printf '%s\n' "${tenants[@]}" | jq -R . | jq -s -c 'map("companies/" + . + "/note.md")')"
  fin_rc=0
  fin_out="$(
    cd "$ROOT" && env -i CODEX_THREAD_ID="$SESSION" HQ_SESSION_ID="$SESSION" \
      HQ_ROOT="$ROOT" HOME="$HOME" PATH="$NATIVE_PATH" LC_ALL=C \
      HQ_NO_UPDATE_CHECK=1 HQ_HANDOFF_PUBLISH=0 \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$REAL_HQ" core --hq-root "$ROOT" handoff finalize \
        --company tenant-0 \
        --title "Handoff: isolation" \
        --summary "Synthetic 11-tenant changeset" \
        --files-touched-json "$paths_json" \
        --next-command '' \
        --slug isolation
  )" || fin_rc=$?
  if [[ "$fin_rc" -ne 0 ]]; then
    fail "native finalizer exited $fin_rc on a multi-company changeset: $fin_out"
  else
    thread_path="$(jq -r '.thread_path' <<<"$fin_out")"
    thread_id="$(jq -r '.thread_id' <<<"$fin_out")"
    if [[ "$(jq -c '.metadata.company' "$ROOT/$thread_path")" != '[]' ]]; then
      fail "native finalizer derived recipients from the changeset: $(jq -c '.metadata.company' "$ROOT/$thread_path")"
    fi
    if [[ "$(jq -c '.mirror_companies' <<<"$fin_out")" != '[]' ]]; then
      fail "native finalizer mirrored a multi-company changeset: $(jq -c '.mirror_companies' <<<"$fin_out")"
    fi
    if [[ -e "$ROOT/companies/tenant-0/workspace/sessions/${thread_id}.json" ]]; then
      fail "native finalizer copied the 11-tenant handoff into tenant-0"
    fi
  fi

  # 4. Native post with an 11-company metadata array must not mirror or push
  # any tenant workspace (the mirror hook refuses ambiguous ownership, so no
  # tenant mirror exists and zero `hq sync push` calls run).
  legacy_post="$ROOT/workspace/threads/T-post-legacy.json"
  jq -n --argjson company "$(printf '%s\n' "${tenants[@]}" | jq -R . | jq -s -c .)" \
    '{thread_id:"T-post-legacy", type:"handoff", files_touched:[], metadata:{company:$company}}' \
    > "$legacy_post"
  : > "$ROOT/hq-calls.log"
  before_post_mirrors="$(mirrors)"
  (
    cd "$ROOT" && env -i HANDOFF_LOG_DIR="$ROOT/logs" HQ_ROOT="$ROOT" HOME="$HOME" \
      PATH="$NATIVE_PATH" LC_ALL=C HQ_NO_UPDATE_CHECK=1 HQ_NATIVE_HANDOFF_POST_CHILD=1 \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$REAL_HQ" core --hq-root "$ROOT" handoff post "$legacy_post" ""
  ) >/dev/null 2>&1 || true
  if grep -E 'sync push' "$ROOT/hq-calls.log" >/dev/null 2>&1; then
    fail "native handoff post attempted tenant pushes on 11-company metadata: $(cat "$ROOT/hq-calls.log")"
  fi
  if [[ "$(mirrors)" -ne "$before_post_mirrors" ]]; then
    fail "native handoff post created tenant mirrors for 11-company metadata"
  fi
  if ! grep -Fq 'workspace-sync: skipped (thread mirror missing for tenant-0)' "$ROOT/logs/handoff-post.log"; then
    fail "native handoff post did not record missing-mirror skip after refusal: $(cat "$ROOT/logs/handoff-post.log")"
  fi

  # 5. Invalid --company is rejected without tenant writes.
  before_mirrors="$(mirrors)"
  bad_rc=0
  (
    cd "$ROOT" && env -i CODEX_THREAD_ID="$SESSION" HQ_SESSION_ID="$SESSION" \
      HQ_ROOT="$ROOT" HOME="$HOME" PATH="$NATIVE_PATH" LC_ALL=C \
      HQ_NO_UPDATE_CHECK=1 HQ_HANDOFF_PUBLISH=0 \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$REAL_HQ" core --hq-root "$ROOT" handoff finalize \
        --company 'Not A Slug' \
        --title "Handoff: bad owner" \
        --summary "invalid" \
        --files-touched-json '["companies/tenant-0/note.md"]' \
        --next-command '' \
        --slug bad-owner
  ) >/dev/null 2>&1 || bad_rc=$?
  if [[ "$bad_rc" -eq 0 ]]; then
    fail "native finalizer accepted an invalid --company slug"
  fi
  if [[ "$(mirrors)" -ne "$before_mirrors" ]]; then
    fail "invalid --company still wrote tenant mirrors"
  fi

  # 6. --company accepts any company in the session's locked set, not only the
  # first-bound one, and rejects a company outside the set.
  jq -n --arg sid "$SESSION" \
    '{session_id:$sid, agent_id:"", company_slug:"tenant-0", company_slugs:["tenant-0","tenant-1"]}' \
    > "$ROOT/workspace/sessions/$SESSION/scope-capability.json"
  for spec in 'tenant-1|0' 'tenant-2|2'; do
    owner="${spec%%|*}"
    want_rc="${spec#*|}"
    set_rc=0
    (
      cd "$ROOT" && env -i CODEX_THREAD_ID="$SESSION" HQ_SESSION_ID="$SESSION" \
        HQ_ROOT="$ROOT" HOME="$HOME" PATH="$NATIVE_PATH" LC_ALL=C \
        HQ_NO_UPDATE_CHECK=1 HQ_HANDOFF_PUBLISH=0 \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        "$REAL_HQ" core --hq-root "$ROOT" handoff finalize \
          --company "$owner" \
          --title "Handoff: locked set $owner" \
          --summary "locked set membership" \
          --files-touched-json "[\"companies/$owner/note.md\"]" \
          --next-command '' \
          --slug "locked-set-$owner"
    ) >/dev/null 2>&1 || set_rc=$?
    if [[ "$set_rc" -ne "$want_rc" ]]; then
      fail "--company $owner exited $set_rc with locked set tenant-0,tenant-1 (want $want_rc)"
    fi
  done

  # 7b. --company from a session with no meta and no capability must not finish
  # looking successful: finalize reports the refused mirror (exit 5).
  UNBOUND=unbound-finalize-session
  mkdir -p "$ROOT/workspace/sessions/$UNBOUND"
  unbound_rc=0
  unbound_err="$(
    cd "$ROOT" && env -i CODEX_THREAD_ID="$UNBOUND" HQ_SESSION_ID="$UNBOUND" \
      HQ_ROOT="$ROOT" HOME="$HOME" PATH="$NATIVE_PATH" LC_ALL=C \
      HQ_NO_UPDATE_CHECK=1 HQ_HANDOFF_PUBLISH=0 \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      "$REAL_HQ" core --hq-root "$ROOT" handoff finalize \
        --company tenant-0 \
        --title "Handoff: unbound owner" \
        --summary "no meta and no capability" \
        --files-touched-json '["companies/tenant-0/note.md"]' \
        --next-command '' \
        --slug unbound-owner 2>&1 >/dev/null
  )" || unbound_rc=$?
  if [[ "$unbound_rc" -ne 5 ]]; then
    fail "--company from an unbound session exited $unbound_rc (want 5): $unbound_err"
  fi
  if [[ "$unbound_err" != *"company mirror failed"* ]]; then
    fail "--company from an unbound session did not report the mirror failure: $unbound_err"
  fi
elif [[ "${HQ_REQUIRE_NATIVE_HANDOFF_ISOLATION:-0}" == "1" ]]; then
  fail "HQ_REQUIRE_NATIVE_HANDOFF_ISOLATION=1 but installed hq (${REAL_HQ_VER:-missing}) is below 5.345.263"
else
  echo "NOTE: native finalize/post tenant assertions deferred (installed hq ${REAL_HQ_VER:-missing} < 5.345.263; covered in hq-cli core-handoff.test.ts and core-handoff-helper-parity.test.ts)"
fi

if [[ "$failures" -ne 0 ]]; then
  echo "Failed $failures handoff isolation assertions" >&2
  exit 1
fi
if [[ "$native_ran" -eq 1 ]]; then
  echo "handoff-thread-isolation: ok (mirror hook + native finalize/post isolate tenants and accept digit-first slugs)"
else
  echo "handoff-thread-isolation: ok (mirror hook 1-12 isolate tenants and accept digit-first slugs; native finalize/post deferred on hq ${REAL_HQ_VER:-missing})"
fi
