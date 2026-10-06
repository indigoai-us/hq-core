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
