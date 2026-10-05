#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/jq-output.js" <<'NODE'
const platform = process.argv[2];
const sample = process.argv[3];
const output = sample === "ordinary"
  ? (platform === "msys" ? "value\r\n" : "value\n")
  : (platform === "msys" ? "before\rinside\r\r\nlast\r\n" : "before\rinside\r\nlast\n");
process.stdout.write(Buffer.from(output, "binary"));
NODE
cat > "$TMP/bin/jq" <<'JQ'
#!/usr/bin/env bash
if [[ "${1:-}" == "-e" ]]; then exit 1; fi
node "$JQ_OUTPUT" "$TEST_OSTYPE" "${2:-}"
JQ
chmod +x "$TMP/bin/jq"

assets=(
  core/scripts/hq-delegate-grant.sh
  core/scripts/hq-delegate-send.sh
  core/scripts/hq-job-probe.sh
  core/scripts/jobs-validate.sh
)

extract_wrapper() {
  awk '
    index($0, "case \"${OSTYPE:-}\" in") { capture = 1 }
    capture { print; if ($0 == "esac") exit }
  ' "$1" | sed 's/${OSTYPE:-}/${TEST_OSTYPE:-}/g' > "$TMP/wrapper.sh"
}

for asset in "${assets[@]}"; do
  extract_wrapper "$ROOT/$asset"
  for platform in msys linux; do
    TEST_OSTYPE="$platform" JQ_OUTPUT="$TMP/bin/jq-output.js" PATH="$TMP/bin:$PATH" bash -c '
      set -uo pipefail
      source "$1"
      jq -r ordinary > "$2/ordinary.bin"
      jq -r embedded > "$2/embedded.bin"
      set +e
      jq -e false >/dev/null 2>&1
      jq_status=$?
      set -e
      printf "%s\n" "$jq_status" > "$2/status"
    ' _ "$TMP/wrapper.sh" "$TMP"
    printf 'value\n' > "$TMP/ordinary.expected"
    printf 'before\rinside\r\nlast\n' > "$TMP/embedded.expected"
    cmp "$TMP/ordinary.expected" "$TMP/ordinary.bin"
    cmp "$TMP/embedded.expected" "$TMP/embedded.bin"
    [[ "$(cat "$TMP/status")" == 1 ]]
    echo "jq wrapper output parity: $asset ($platform)"
  done
done
