#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$ROOT/scripts/anywhere-vm-test.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/input"
touch "$TMP/input/hq-cli-1.0.0.tgz" "$TMP/input/hq-core.tar.gz"

cat > "$BIN/hq" <<'HQ'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" != secrets ]; then
  printf 'unexpected hq invocation\n' >&2
  exit 91
fi
shift
only_names=""
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  case "$1" in
    --only) only_names="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$only_names" ] || exit 91
[ "${1:-}" = -- ] || exit 92
shift
printf '%s\n' "$only_names" >> "$HQ_ONLY_LOG"
if [ "${HQ_TEST_NAMESPACED:-0}" = 1 ]; then
  exec env 'HQ_TEST_FLEET/MACHINE_USERNAME=sentinel-machine-user' 'HQ_TEST_FLEET/MACHINE_SECRET=sentinel-machine-secret' "$@"
fi
exec "$@"
HQ

cat > "$BIN/tart" <<'TART'
#!/usr/bin/env bash
set -euo pipefail
command_name="${1:-}"
printf '%s\n' "$command_name" >> "$TART_LOG"
case "$command_name" in
  clone)
    [ "${TART_STUB_CLONE_FAIL:-0}" = 1 ] && exit 1
    :
    ;;
  run)
    sleep 0.05
    ;;
  exec)
    [ "${TART_STUB_SLEEP_ON_EXEC:-0}" = 1 ] && sleep 30
    full_args="$*"
    printf '%s\n' "$full_args" >> "$TART_GUEST_LOG"
    case "$full_args" in
      *sentinel-anthropic-secret*|*sentinel-openai-secret*|*sentinel-machine-user*|*sentinel-machine-secret*|*ANTHROPIC_API_KEY=*|*OPENAI_API_KEY=*|*HQ_MACHINE_USERNAME=*|*HQ_MACHINE_SECRET=*)
        printf 'credential appeared in tart argv\n' >&2
        exit 94
        ;;
      *"-i"*) : ;;
      *) printf 'tart exec did not request stdin forwarding\n' >&2; exit 95 ;;
    esac
    seen_anthropic=0 seen_openai=0 seen_user=0 seen_machine_secret=0
    while IFS= read -r assignment; do
      case "$assignment" in
        ANTHROPIC_API_KEY=sentinel-anthropic-secret) seen_anthropic=1 ;;
        OPENAI_API_KEY=sentinel-openai-secret) seen_openai=1 ;;
        HQ_MACHINE_USERNAME=sentinel-machine-user) seen_user=1 ;;
        HQ_MACHINE_SECRET=sentinel-machine-secret) seen_machine_secret=1 ;;
        *) printf 'unexpected credential input shape\n' >&2; exit 96 ;;
      esac
    done
    if [ "${HQ_TEST_NAMESPACED:-0}" = 1 ]; then
      [ "$seen_user" = 1 ] && [ "$seen_machine_secret" = 1 ] || exit 97
      expected='[ "$HQ_MACHINE_USERNAME" = sentinel-machine-user ] && [ "$HQ_MACHINE_SECRET" = sentinel-machine-secret ]'
      input='HQ_MACHINE_USERNAME=sentinel-machine-user HQ_MACHINE_SECRET=sentinel-machine-secret'
    elif [ "${TART_STUB_MACHINE_LOGIN:-0}" = 1 ]; then
      [ "$seen_user" = 1 ] && [ "$seen_machine_secret" = 1 ] || exit 97
      expected='[ "$HQ_MACHINE_USERNAME" = sentinel-machine-user ] && [ "$HQ_MACHINE_SECRET" = sentinel-machine-secret ]'
      input='HQ_MACHINE_USERNAME=sentinel-machine-user HQ_MACHINE_SECRET=sentinel-machine-secret'
    else
      [ "$seen_anthropic" = 1 ] && [ "$seen_openai" = 1 ] || exit 97
      expected='[ "$ANTHROPIC_API_KEY" = sentinel-anthropic-secret ] && [ "$OPENAI_API_KEY" = sentinel-openai-secret ]'
      input='ANTHROPIC_API_KEY=sentinel-anthropic-secret OPENAI_API_KEY=sentinel-openai-secret'
    fi
    bootstrap="${8:-}"
    if ! printf '%s\n' $input | /bin/bash -c "$bootstrap" anywhere-vm-guest /bin/bash -c "$expected"; then
      printf 'guest environment bootstrap failed\n' >&2
      exit 99
    fi
    case "$full_args" in
      *anywhere-parity-test.sh*)
        runtime="claude"
        case "$full_args" in *HQ_VM_RUNTIME=codex*) runtime="codex" ;; esac
        if [ "${TART_STUB_PARITY_FAIL:-0}" = 1 ]; then
          printf '{"assertion":"startwork","result":"FAIL","runtime":"%s","detail":"fixture assertion failed"}\n' "$runtime"
          printf '{"assertion":"policy","result":"PASS","runtime":"%s","detail":"ok"}\n' "$runtime"
          printf '{"assertion":"run","result":"PASS","runtime":"%s","detail":"ok"}\n' "$runtime"
          printf '{"assertion":"journal","result":"PASS","runtime":"%s","detail":"ok"}\n' "$runtime"
        else
          for assertion in startwork policy run journal; do
            printf '{"assertion":"%s","result":"PASS","runtime":"%s","detail":"ok"}\n' "$assertion" "$runtime"
          done
        fi
        ;;
      *"hq doctor"*) printf '{"doctor":"ok"}\n' ;;
      *) printf 'guest command completed\n' ;;
    esac
    ;;
  stop) : ;;
  delete)
    [ "${TART_STUB_DELETE_FAIL:-0}" = 1 ] && exit 98
    :
    ;;
  *) printf 'unexpected tart command\n' >&2; exit 93 ;;
esac
TART
chmod +x "$BIN/hq" "$BIN/tart"

run_harness() {
  local name="$1"
  shift
  local run_dir="$TMP/$name"
  mkdir -p "$run_dir"
  if env PATH="$BIN:$PATH" TART_BIN="$BIN/tart" TART_LOG="$run_dir/tart.log" \
    ANTHROPIC_API_KEY='sentinel-anthropic-secret' OPENAI_API_KEY='sentinel-openai-secret' \
    HQ_US016_FIXTURE_REPO='https://github.com/indigoai-us/hq-anywhere-fixture.git' \
    HQ_US016_FIXTURE_REF='0123456789abcdef0123456789abcdef01234567' \
    HQ_US016_TEST_COMPANY='us016-test' \
    HQ_MACHINE_USERNAME='sentinel-machine-user' HQ_MACHINE_SECRET='sentinel-machine-secret' \
    HQ_TEST_NAMESPACED="$([ "$name" = namespaced-secret-map ] && printf 1 || printf 0)" \
    TART_STUB_MACHINE_LOGIN="$([ "$name" = stdin-login ] && printf 1 || printf 0)" \
    TART_GUEST_LOG="$run_dir/guest.log" HQ_ONLY_LOG="$run_dir/only.log" \
    bash "$SCRIPT" \
      --cli-package "$TMP/input/hq-cli-1.0.0.tgz" \
      --core-bundle "$TMP/input/hq-core.tar.gz" \
      --fixture-repo 'https://github.com/indigoai-us/hq-anywhere-fixture.git' \
      --fixture-ref '0123456789abcdef0123456789abcdef01234567' \
      --company 'us016-test' \
      --hq-api-url 'https://api.staging.example.invalid' \
      --secret-names 'ANTHROPIC_API_KEY,OPENAI_API_KEY' \
      --results-dir "$run_dir/results" \
      "$@" >"$run_dir/stdout.log" 2>"$run_dir/stderr.log"; then
    return 0
  else
    local status=$?
    cat "$run_dir/stdout.log" "$run_dir/stderr.log" >&2
    cat "$run_dir/tart.log" >&2 2>/dev/null || true
    return "$status"
  fi
}

assert() {
  if ! eval "$1"; then
    printf 'FAIL: %s\n' "$2" >&2
    exit 1
  fi
}

run_harness success
FIRST_CALL="$(sed -n '1p' "$TMP/success/tart.log")"
SECOND_CALL="$(sed -n '2p' "$TMP/success/tart.log")"
THIRD_CALL="$(sed -n '3p' "$TMP/success/tart.log")"
LAST_CALL="$(tail -n 1 "$TMP/success/tart.log")"
assert '[ "$FIRST_CALL" = clone ]' 'tart clone is the first operation'
assert '[ "$SECOND_CALL" = run ]' 'the VM is booted after clone'
assert '[ "$THIRD_CALL" = exec ]' 'guest exec follows boot'
assert '[ "$LAST_CALL" = delete ]' 'VM is deleted after the run'
assert 'grep -q "PASS US-016 parity" "$TMP/success/stdout.log"' 'successful parity is reported'
assert '! grep -R -E "sentinel-(anthropic|openai)-secret|ANTHROPIC_API_KEY=|OPENAI_API_KEY=" "$TMP/success"' 'credential values and assignments are absent from every output file'


set +e
run_harness namespaced-secret-map --secret-names 'HQ_TEST_FLEET/MACHINE_USERNAME=HQ_MACHINE_USERNAME,HQ_TEST_FLEET/MACHINE_SECRET=HQ_MACHINE_SECRET'
status=$?
set -e
assert '[ "$status" -eq 0 ]' 'slash-namespaced secrets map to explicit environment names'
assert 'grep -q "PASS US-016 parity" "$TMP/namespaced-secret-map/stdout.log"' 'namespaced secret mapping completes the harness'
assert 'grep -qx "HQ_TEST_FLEET/MACHINE_USERNAME,HQ_TEST_FLEET/MACHINE_SECRET" "$TMP/namespaced-secret-map/only.log"' 'hq secrets receives the namespaced record names'

set +e
run_harness stdin-login --secret-names 'HQ_MACHINE_USERNAME,HQ_MACHINE_SECRET'
status=$?
set -e
assert '[ "$status" -eq 0 ]' 'stdin machine login scenario completes'
assert 'grep -q "hq daemon login --stdin" "$TMP/stdin-login/guest.log"' 'guest setup pipes machine credentials into daemon login on stdin'
assert 'grep -q "hq daemon login --status | grep -q" "$TMP/stdin-login/guest.log"' 'guest setup requires a signed-in daemon status'
assert 'grep -q "cognito-tokens.json" "$TMP/stdin-login/guest.log"' 'guest setup checks that machine login wrote no Cognito cache file'
assert '! grep -R -E "sentinel-machine-(user|secret)" "$TMP/stdin-login/guest.log" "$TMP/stdin-login/stdout.log" "$TMP/stdin-login/stderr.log"' 'machine credential values are absent from guest command arguments and logs'

set +e
TART_STUB_PARITY_FAIL=1 run_harness parity-fail
status=$?
set -e
assert '[ "$status" -ne 0 ]' 'a parity FAIL exits non-zero'
assert 'grep -q "FAIL startwork — fixture assertion failed" "$TMP/parity-fail/stdout.log"' 'failing assertion is printed'
assert 'tail -n 1 "$TMP/parity-fail/tart.log" | grep -q "delete"' 'VM is deleted after parity failure'

set +e
TART_STUB_SLEEP_ON_EXEC=1 run_harness timeout --timeout-seconds 8
status=$?
set -e
assert '[ "$status" -ne 0 ]' 'the overall timeout exits non-zero'
assert 'tail -n 1 "$TMP/timeout/tart.log" | grep -q "delete"' 'VM is deleted after timeout'

set +e
TART_STUB_DELETE_FAIL=1 run_harness delete-fail
status=$?
set -e
assert '[ "$status" -ne 0 ]' 'a failed Tart deletion exits non-zero after successful parity'
assert 'grep -q "Tart VM deletion failed" "$TMP/delete-fail/stderr.log"' 'a failed deletion is reported'

set +e
TART_STUB_CLONE_FAIL=1 run_harness clone-fail
status=$?
set -e
assert '[ "$status" -ne 0 ]' 'a failed clone exits non-zero'
assert 'tail -n 1 "$TMP/clone-fail/tart.log" | grep -q "delete"' 'VM deletion is attempted after clone failure'

set +e
run_harness invalid-secret-name --secret-names '1INVALID'
status=$?
set -e
assert '[ "$status" -ne 0 ]' 'secret names beginning with digits are rejected'
assert 'grep -q "secret names must begin" "$TMP/invalid-secret-name/stderr.log"' 'invalid secret name has a clear diagnostic'

set +e
run_harness mismatched-company --company 'contest'
status=$?
set -e
assert '[ "$status" -ne 0 ]' 'unapproved company slugs are rejected'
assert 'grep -q "exactly match HQ_US016_TEST_COMPANY" "$TMP/mismatched-company/stderr.log"' 'company allowlist rejection is explicit'

set +e
run_harness unapproved-fixture --fixture-repo 'https://github.com/indigoai-us/other-repo.git'
status=$?
set -e
assert '[ "$status" -ne 0 ]' 'unapproved fixture repositories are rejected'
assert 'grep -q "exactly match HQ_US016_FIXTURE_REPO" "$TMP/unapproved-fixture/stderr.log"' 'fixture allowlist rejection is explicit'

set +e
run_harness unpinned-fixture --fixture-ref 'main'
status=$?
set -e
assert '[ "$status" -ne 0 ]' 'moving fixture refs are rejected'
assert 'grep -q "exactly match HQ_US016_FIXTURE_REF" "$TMP/unpinned-fixture/stderr.log"' 'unpinned fixture rejection is explicit'

set +e
run_harness unapproved-fixture-ref --fixture-ref 'fedcba9876543210fedcba9876543210fedcba98'
status=$?
set -e
assert '[ "$status" -ne 0 ]' 'unreviewed fixture commits are rejected'
assert 'grep -q "exactly match HQ_US016_FIXTURE_REF" "$TMP/unapproved-fixture-ref/stderr.log"' 'fixture commit allowlist rejection is explicit'

set +e
run_harness deceptive-prod-host --hq-api-url 'https://staging@hqapi.hq.computer'
status=$?
set -e
assert '[ "$status" -ne 0 ]' 'userinfo cannot make a production API host pass validation'
assert 'grep -q "explicitly non-production hostname" "$TMP/deceptive-prod-host/stderr.log"' 'production URL rejection is explicit'

printf 'PASS anywhere-vm-test stub Tart contract, cleanup, failure output, timeout, and secret-disk checks\n'
