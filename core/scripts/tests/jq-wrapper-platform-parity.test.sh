#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ASSET_ROOT="${TEST_ASSET_ROOT:-$ROOT}/core/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/jq" <<'JQ'
#!/usr/bin/env bash
binary=no
if [[ "${1:-}" == "--binary" ]]; then
  if [[ "$TEST_JQ_MODE" == legacy ]]; then
    echo 'jq: unknown option --binary' >&2
    exit 2
  fi
  binary=yes
  shift
fi
printf '%s %s\n' "$binary" "$*" >> "$JQ_ARGV_LOG"
if [[ "${1:-}" == "-n" && "${2:-}" == "null" ]]; then
  printf 'null\n'
  exit 0
fi
if [[ "${1:-}" == "-e" && "${2:-}" == "false" ]]; then
  if [[ "$TEST_OSTYPE" == msys && "$binary" == no ]]; then printf 'jq: false\r\n' >&2; else printf 'jq: false\n' >&2; fi
  exit 1
fi
case "${TEST_OSTYPE}:${TEST_JQ_MODE}:${1:-}:${2:-}:${binary}" in
  msys:legacy:-r:ordinary:no) printf 'value\r\n' ;;
  msys:legacy:-r:embedded:no) printf 'before\rinside\r\r\nlast\r\r\n' ;;
  msys:modern:-r:ordinary:yes) printf 'value\n' ;;
  msys:modern:-r:embedded:yes) printf 'before\rinside\r\nlast\r\n' ;;
  linux:*:-r:ordinary:no) printf 'value\n' ;;
  linux:*:-r:embedded:no) printf 'before\rinside\r\nlast\r\n' ;;
  *) echo "unexpected jq args: $* (mode=$TEST_JQ_MODE, binary=$binary)" >&2; exit 97 ;;
esac
JQ
chmod +x "$TMP/bin/jq"

assets=(
  hq-delegate-grant.sh
  hq-delegate-send.sh
  hq-job-probe.sh
  jobs-validate.sh
)

# Exercise jobs-validate with the real jq behind a shim that reproduces the
# Git Bash jq.exe text-mode CRLF on its root-type query. A plain `tr` probe
# would only test tr, not the validator's comparison.
jobs_validate="$ASSET_ROOT/jobs-validate.sh"
real_jq="$(command -v jq)"
[[ -x "$real_jq" ]] || { echo "FAIL: real jq is not executable: $real_jq" >&2; exit 1; }
real_yq="$(command -v yq || true)"
[[ -n "$real_yq" && -x "$real_yq" ]] \
  || { echo "FAIL: yq missing; install pinned mikefarah/yq v4.45.1 before running this test" >&2; exit 1; }
mkdir -p "$TMP/jobs-bin"
cat > "$TMP/jobs-bin/jq" <<'JQ_CRLF'
#!/usr/bin/env bash
set -euo pipefail
printf 'args=%s\n' "$*" >> "$JQ_TYPE_LOG"
# Reproduce jq.exe's CRLF text-mode output for the old captured `-r type`
# query. The `-es` slurp query checks one object document through jq's status.
if [[ " $* " == *" -r type "* ]]; then
  printf '%s\n' 'root-type-query-crlf' >> "$JQ_TYPE_LOG"
  value="$("$REAL_JQ" "$@")"
  printf '%s\r\n' "$value"
elif [[ " $* " == *'-es length == 1 and (.[0] | type == "object")'* ]]; then
  printf '%s\n' 'root-object-query' >> "$JQ_TYPE_LOG"
  exec "$REAL_JQ" "$@"
else
  exec "$REAL_JQ" "$@"
fi
JQ_CRLF
chmod +x "$TMP/jobs-bin/jq"
valid_job="$ASSET_ROOT/tests/fixtures/jobs/valid/personal-daily-digest.yaml"
: > "$TMP/jq-type.log"
set +e
REAL_JQ="$real_jq" JQ_TYPE_LOG="$TMP/jq-type.log" PATH="$TMP/jobs-bin:$PATH" \
  "$jobs_validate" "$valid_job" >"$TMP/jobs-validate.stdout" 2>"$TMP/jobs-validate.stderr"
jobs_validate_status=$?
set -e
[[ "$jobs_validate_status" -eq 0 ]] \
  || { printf 'FAIL: jobs-validate rejected valid job after CRLF jq type output (status=%s)\n' "$jobs_validate_status" >&2; cat "$TMP/jobs-validate.stderr" >&2; exit 1; }
! grep -Fq 'job root must be a mapping' "$TMP/jobs-validate.stderr" \
  || { echo 'FAIL: jobs-validate compared the CRLF root type without removing CR' >&2; exit 1; }
grep -Fxq 'root-object-query' "$TMP/jq-type.log" \
  || { echo 'FAIL: the jq shim did not exercise jobs-validate root type query' >&2; cat "$TMP/jq-type.log" >&2; exit 1; }
echo 'jobs-validate accepts a valid job when the Windows jq shim reproduces CRLF text-mode output'

multi_job="$TMP/jobs-validate-multi-document.yaml"
cat >"$multi_job" <<'MULTI_JOB'
id: first
name: First job
schedule: '0 9 * * *'
runtime: claude
timeout_seconds: 600
notify: none
enabled: true
owner: owner@example.test
created_at: '2026-09-01T00:00:00Z'
---
id: second
name: Second job
schedule: '0 9 * * *'
runtime: claude
timeout_seconds: 600
notify: none
enabled: true
owner: owner@example.test
created_at: '2026-09-01T00:00:00Z'
MULTI_JOB
: > "$TMP/jq-type.log"
set +e
REAL_JQ="$real_jq" JQ_TYPE_LOG="$TMP/jq-type.log" PATH="$TMP/jobs-bin:$PATH" \
  "$jobs_validate" "$multi_job" >"$TMP/jobs-validate-multi.stdout" 2>"$TMP/jobs-validate-multi.stderr"
multi_status=$?
set -e
[[ "$multi_status" -eq 1 ]] \
  || { printf 'FAIL: jobs-validate accepted multiple YAML documents (status=%s)\n' "$multi_status" >&2; cat "$TMP/jobs-validate-multi.stderr" >&2; exit 1; }
grep -Fq 'job root must be a mapping' "$TMP/jobs-validate-multi.stderr" \
  || { echo 'FAIL: jobs-validate did not preserve the multi-document root diagnostic' >&2; cat "$TMP/jobs-validate-multi.stderr" >&2; exit 1; }
echo 'jobs-validate preserves the old rejection of multiple YAML documents'

extract_wrapper() {
  awk '
    index($0, "case \"${OSTYPE:-}") { capture = 1 }
    capture { print; if ($0 == "esac") exit }
  ' "$1" | sed 's/${OSTYPE:-}/${TEST_OSTYPE:-}/g; s/${MSYSTEM:-}/${TEST_MSYSTEM:-}/g' > "$TMP/wrapper.sh"
}

for asset in "${assets[@]}"; do
  extract_wrapper "$ASSET_ROOT/$asset"
  for platform in msys linux; do
    modes=(legacy)
    [[ "$platform" == msys ]] && modes+=(modern)
    if [[ -n "${TEST_JQ_MODE:-}" ]]; then modes=("$TEST_JQ_MODE"); fi
    for mode in "${modes[@]}"; do
      test_msystem=""
      [[ "$platform" == msys ]] && test_msystem="MINGW64"
      : > "$TMP/jq-argv.log"
      TEST_OSTYPE="$platform" TEST_MSYSTEM="$test_msystem" TEST_JQ_MODE="$mode" JQ_ARGV_LOG="$TMP/jq-argv.log" PATH="$TMP/bin:$PATH" bash -c '
        set -uo pipefail
        source "$1"
        jq -r ordinary > "$2/ordinary.bin"
        jq -r embedded > "$2/embedded.bin"
        set +e
        jq -e false > "$2/false.stdout" 2> "$2/false.stderr"
        jq_status=$?
        set -e
        printf "%s\n" "$jq_status" > "$2/status"
      ' _ "$TMP/wrapper.sh" "$TMP"
      printf 'value\n' > "$TMP/ordinary.expected"
      printf 'before\rinside\r\nlast\r\n' > "$TMP/embedded.expected"
      printf 'jq: false\n' > "$TMP/false.stderr.expected"
      : > "$TMP/false.stdout.expected"
      cmp "$TMP/ordinary.expected" "$TMP/ordinary.bin"
      cmp "$TMP/embedded.expected" "$TMP/embedded.bin"
      cmp "$TMP/false.stdout.expected" "$TMP/false.stdout"
      cmp "$TMP/false.stderr.expected" "$TMP/false.stderr"
      [[ "$(cat "$TMP/status")" == 1 ]]
      if [[ "$platform:$mode" == msys:modern ]]; then
        grep -q '^yes -r ordinary$' "$TMP/jq-argv.log"
      elif [[ "$platform:$mode" == msys:legacy ]]; then
        grep -q '^no -r ordinary$' "$TMP/jq-argv.log"
      else
        grep -q '^no -r ordinary$' "$TMP/jq-argv.log"
      fi
      echo "jq wrapper output parity: $asset ($platform/$mode)"
    done
  done
done
