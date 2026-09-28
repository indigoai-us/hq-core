#!/usr/bin/env bash
# hq-core: public
# Regression: Outpost systemd job units retain the resolved CLI PATH and job-owner UIDs reach hq dm unchanged (US-081).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RECON="$ROOT/core/scripts/outpost-jobs-reconcile.sh"
RUN="$ROOT/core/scripts/hq-job-run.sh"
NOTIFY="$ROOT/core/scripts/hq-job-notify.sh"
FIXTURE="$ROOT/core/scripts/tests/fixtures/jobs/valid/personal-daily-digest.yaml"

for tool in yq jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not available"; exit 0; }
done

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/var/tmp}/outpost-job-failure-alerts.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Build a controlled base PATH from the test host's utilities. It excludes
# every installed hq binary, so the fixture remains valid on Outposts where hq
# is also installed in a system directory.
BASE_BIN="$TMP/base-tools"
BASE_PATH="$BASE_BIN"
NPM_GLOBAL_PREFIX="$TMP/npm%global prefix"
NPM_GLOBAL_BIN="$NPM_GLOBAL_PREFIX/bin"
NPM_BIN="$TMP/npm-tools"
mkdir -p "$BASE_BIN" "$NPM_GLOBAL_BIN" "$NPM_BIN"
for tool in awk basename bash cat chmod cp cksum cut date dirname find flock grep head id install jq ln mkdir mktemp mv realpath rm sed sha256sum shasum sleep sort stat tee touch tr wc; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  if [ -n "$tool_path" ] && [ -x "$tool_path" ]; then
    ln -s "$tool_path" "$BASE_BIN/$tool"
  fi
done
ln -s "$(command -v yq)" "$NPM_BIN/yq"

cat >"$NPM_GLOBAL_BIN/hq" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  whoami)
    if [ "${2:-}" = "--json" ]; then
      printf '{"email":"machine@example.test","personUid":"prs_machine"}\n'
    else
      printf 'email: machine@example.test\n'
    fi
    ;;
  dm)
    printf 'recipient=%s\n' "${2:-}" >>"${HQ_JOB_TEST_DM_LOG:-/dev/null}"
    ;;
  *)
    echo "unexpected hq invocation" >&2
    exit 2
    ;;
esac
STUB
chmod +x "$NPM_GLOBAL_BIN/hq"

assert_hq_only_in_npm_global() {
  if /usr/bin/env PATH="$BASE_PATH" /bin/bash -c 'command -v hq >/dev/null 2>&1'; then
    fail "fixture error: hq is also available outside npm-global/bin"
  fi
  local resolved
  resolved="$(/usr/bin/env PATH="$NPM_GLOBAL_BIN:$BASE_PATH" /bin/bash -c 'command -v hq')"
  [ "$resolved" = "$NPM_GLOBAL_BIN/hq" ] || fail "fixture hq resolved outside npm-global/bin: $resolved"
}

create_generated_unit() {
  local job_id="$1" host_path="$2"
  assert_hq_only_in_npm_global
  local hq_root="$TMP/${job_id}-root" home_dir="$TMP/${job_id}-home"
  local unit_dir="$TMP/${job_id}-units" cache_dir="$TMP/${job_id}-cache"
  mkdir -p "$hq_root/personal/jobs" "$home_dir" "$unit_dir" "$cache_dir" \
    "$home_dir/.hq/jobs/reconcile"
  cat >"$NPM_BIN/npm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "prefix" ] && [ "${2:-}" = "-g" ] || exit 2
printf '%s\n' "$HQ_JOB_TEST_NPM_PREFIX"
STUB
  chmod +x "$NPM_BIN/npm"
  export HQ_JOB_TEST_NPM_PREFIX="$NPM_GLOBAL_PREFIX"
  cp "$FIXTURE" "$hq_root/personal/jobs/${job_id}.yaml"
  yq -i ".id = \"$job_id\" | .owner = \"owner@example.test\"" \
    "$hq_root/personal/jobs/${job_id}.yaml"
  jq -nc --arg id "$job_id" \
    '{job_id:$id,readiness:"ready",updated_at:"2026-09-28T00:00:00Z",source:"test"}' \
    >"$cache_dir/${job_id}.json"

  PATH="$NPM_BIN:$host_path" \
  HOME="$home_dir" \
  HQ_ROOT="$hq_root" \
  HQ_JOB_UNIT_DIR="$unit_dir" \
  HQ_JOB_STATUS_CACHE_DIR="$cache_dir" \
  HQ_JOB_SYSTEMCTL=":" \
  HQ_JOB_OWNER_EMAIL="owner@example.test" \
  HQ_JOB_OWNER_UID="prs_owner" \
  HQ_JOB_RANDOMIZE_SEC=0 \
    bash "$RECON" --hq-root "$hq_root" --no-probe --dry-run >"$TMP/${job_id}.stdout" 2>"$TMP/${job_id}.stderr" \
    || fail "reconcile failed for synthetic PATH: $(cat "$TMP/${job_id}.stderr")"

  GENERATED_SERVICE="$unit_dir/hq-job-${job_id}.service"
  [ -f "$GENERATED_SERVICE" ] || fail "reconcile did not generate the service unit"
}

unit_path_from_generated_service() {
  local encoded
  encoded="$(sed -n 's/^Environment=\"PATH=\(.*\)\"$/\1/p' "$GENERATED_SERVICE")"
  [ -n "$encoded" ] || fail "generated service unit does not preserve a PATH"
  printf '%s' "$encoded" | sed 's/%%/%/g'
}

test_generated_unit_percent_escape() {
  create_generated_unit "us083-percent-path" "$BASE_PATH"
  local encoded expected_fragment unit_path resolved
  encoded="$(sed -n 's/^Environment=\"PATH=\(.*\)\"$/\1/p' "$GENERATED_SERVICE")"
  expected_fragment="${NPM_GLOBAL_BIN//%/%%}"
  case "$encoded" in
    *"$expected_fragment"*) ;;
    *) fail "systemd PATH did not double percent in resolved hq path: '$encoded'" ;;
  esac
  unit_path="$(unit_path_from_generated_service)"
  resolved="$(/usr/bin/env -i PATH="$unit_path" /bin/bash -c 'command -v hq' 2>/dev/null || true)"
  [ "$resolved" = "$NPM_GLOBAL_BIN/hq" ] || fail "decoded unit PATH did not resolve npm-global hq: '$resolved'"
  pass "generated unit doubles systemd percent specifiers in PATH"
}

test_generated_unit_path_filter() {
  local host_path="$BASE_BIN::$NPM_GLOBAL_BIN:relative:.:$NPM_BIN:$BASE_BIN"
  create_generated_unit "us083-clean-path" "$host_path"
  local unit_path expected resolved
  unit_path="$(unit_path_from_generated_service)"
  expected="$NPM_BIN:$BASE_BIN:$NPM_GLOBAL_BIN"
  [ "$unit_path" = "$expected" ] || fail "generated PATH was not absolute, ordered, and deduplicated: '$unit_path'"
  resolved="$(/usr/bin/env -i PATH="$unit_path" /bin/bash -c 'command -v hq' 2>/dev/null || true)"
  [ "$resolved" = "$NPM_GLOBAL_BIN/hq" ] || fail "filtered unit PATH did not resolve hq: '$resolved'"
  pass "generated unit removes empty and relative PATH entries and preserves order without duplicates"
}

test_person_uid_owner() {
  assert_hq_only_in_npm_global
  local hq_root="$TMP/owner-hq-root" home_dir="$TMP/owner-home" run_bin="$TMP/owner-run-bin"
  local dm_log="$TMP/owner-dm.log" whoami_log="$TMP/owner-whoami.log"
  mkdir -p "$hq_root/personal/jobs" "$hq_root/personal/settings" "$hq_root/personal" \
    "$home_dir/.claude" "$home_dir/.hq/jobs" "$run_bin"
  cp "$FIXTURE" "$hq_root/personal/jobs/person-uid.yaml"
  yq -i '.id = "us081-person-uid" | .owner = "prs_01TESTOWNER0000000000000000" | .notify = "dm"' \
    "$hq_root/personal/jobs/person-uid.yaml"
  cat >"$hq_root/personal/settings/schedule-alerts.yaml" <<'YAML'
channel: dm
updated_at: "2026-09-28T00:00:00Z"
YAML
  printf '{"token":"synthetic-test-token"}\n' >"$home_dir/.claude/.credentials.json"
  cat >"$run_bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'synthetic job completed\n'
STUB
  chmod +x "$run_bin/claude"
  : >"$dm_log"
  : >"$whoami_log"
  export HQ_JOB_TEST_DM_LOG="$dm_log"
  export HQ_JOB_TEST_WHOAMI_LOG="$whoami_log"
  cat >"$NPM_GLOBAL_BIN/hq" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  whoami)
    printf 'whoami\n' >>"$HQ_JOB_TEST_WHOAMI_LOG"
    printf 'email: machine@example.test\n'
    ;;
  dm)
    printf 'recipient=%s\n' "${2:-}" >>"$HQ_JOB_TEST_DM_LOG"
    ;;
  *)
    echo "unexpected hq invocation" >&2
    exit 2
    ;;
esac
STUB
  chmod +x "$NPM_GLOBAL_BIN/hq"
  unset HQ_JOB_RUN_NO_NOTIFY HQ_JOB_RUN_SKIP_EXEC || true
  export PATH="$NPM_GLOBAL_BIN:$run_bin:$NPM_BIN:$BASE_PATH"
  export HOME="$home_dir"
  export HQ_ROOT="$hq_root"
  export HQ_JOB_LOCK="$home_dir/.hq/jobs/run.lock"
  export HQ_JOB_LOG_DIR="$home_dir/.hq/jobs/logs"
  export HQ_JOB_METER_DIR="$home_dir/.hq/jobs/meters"
  export HQ_JOB_RUN_NO_INGEST=1
  export HQ_JOB_NOTIFY_NOW_EPOCH=1790553600
  export HQ_JOB_NOW="2026-09-28T00:00:00Z"

  bash "$RUN" --hq-root "$hq_root" --job-id us081-person-uid >"$TMP/owner.stdout" 2>"$TMP/owner.stderr" \
    || fail "job runner failed: $(cat "$TMP/owner.stderr")"
  grep -Fxq 'recipient=prs_01TESTOWNER0000000000000000' "$dm_log" \
    || fail "personUid was not delivered unchanged; observed recipients: $(cat "$dm_log")"
  [ ! -s "$whoami_log" ] || fail "personUid owner triggered hq whoami"
  pass "personUid owner is sent directly to hq dm without hq whoami"
}

test_missing_hq_is_nonfatal() {
  local hq_root="$TMP/no-hq-root" home_dir="$TMP/no-hq-home" out rc
  mkdir -p "$hq_root/personal/settings" "$home_dir/.hq/jobs"
  cat >"$hq_root/personal/settings/schedule-alerts.yaml" <<'YAML'
channel: dm
updated_at: "2026-09-28T00:00:00Z"
YAML
  assert_hq_only_in_npm_global
  set +e
  out="$(PATH="$BASE_PATH" HOME="$home_dir" HQ_ROOT="$hq_root" \
    HQ_JOB_ALERT_DIR="$home_dir/.hq/jobs/alerts" \
    bash "$NOTIFY" --hq-root "$hq_root" --job-id no-hq --job-name "No hq binary" \
      --owner owner@example.test --notify dm --outcome failed --summary "synthetic failure" \
      --duration 1 --log-path "$home_dir/run.log" 2>"$TMP/no-hq.stderr")"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "notify failed when hq was unavailable (exit $rc)"
  printf '%s' "$out" | jq -e '.delivered == false' >/dev/null || fail "missing-hq result did not report undelivered"
  grep -Fq 'skip dm send — hq CLI not found' "$TMP/no-hq.stderr" \
    || fail "missing hq binary was not clearly logged"
  pass "missing hq binary is logged and does not fail the job"
}

case "${1:-all}" in
  unit-percent) test_generated_unit_percent_escape ;;
  unit-path-filter) test_generated_unit_path_filter ;;
  unit-path) test_generated_unit_percent_escape; test_generated_unit_path_filter ;;
  person-uid) test_person_uid_owner ;;
  missing-hq) test_missing_hq_is_nonfatal ;;
  all)
    test_generated_unit_percent_escape
    test_generated_unit_path_filter
    test_person_uid_owner
    test_missing_hq_is_nonfatal
    ;;
  *) fail "usage: $0 [unit-percent|unit-path-filter|unit-path|person-uid|missing-hq|all]" ;;
esac

echo "ALL PASSED (outpost-job-failure-alerts)"
