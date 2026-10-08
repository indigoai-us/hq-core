#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/handoff-open-steps.sh"
TEMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
TMP="$(mktemp -d "$TEMP_ROOT/handoff-stat-scaling-bench.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

REAL_STAT="$(command -v stat)"
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/stat" <<'STAT_SHIM'
#!/usr/bin/env bash
printf '.\n' >> "$STAT_COUNT_FILE"
exec "$REAL_STAT" "$@"
STAT_SHIM
chmod +x "$BIN/stat"

now_ms() {
  local value
  value="$(date +%s%3N)"
  if [[ ! "$value" =~ ^[0-9]{13}$ ]]; then
    printf 'ERROR: date +%%s%%3N did not return a 13-digit millisecond timestamp: %s\n' "$value" >&2
    exit 2
  fi
  printf '%s' "$value"
}

make_fixture() {
  local count="$1" root="$2"
  python3 - "$count" "$root" <<'PYFIXTURE'
import json
import pathlib
import sys

count = int(sys.argv[1])
root = pathlib.Path(sys.argv[2])
threads = root / "workspace" / "threads"
threads.mkdir(parents=True)
for index in range(count):
    path = threads / f"T-{index:05d}.json"
    path.write_text(json.dumps({"thread_id": path.stem, "next_steps": []}), encoding="utf-8")
PYFIXTURE
}

measure_size() {
  local count="$1" root elapsed_file stats_file stat_count
  root="$TMP/fixture-$count"
  elapsed_file="$TMP/elapsed-$count"
  stats_file="$TMP/stats-$count"
  make_fixture "$count" "$root"
  : > "$elapsed_file"
  : > "$stats_file"

  for ((run = 1; run <= 5; run++)); do
    stat_count="$TMP/stat-count-$count-$run"
    : > "$stat_count"
    local start end elapsed stat_calls
    start="$(now_ms)"
    HQ_ROOT="$root" \
      PATH="$BIN:$PATH" \
      STAT_COUNT_FILE="$stat_count" \
      REAL_STAT="$REAL_STAT" \
      bash "$SCRIPT" list --limit 10 >/dev/null
    end="$(now_ms)"
    elapsed=$((end - start))
    stat_calls="$(wc -l < "$stat_count" | tr -d '[:space:]')"
    printf '%s\n' "$elapsed" >> "$elapsed_file"
    printf '%s\n' "$stat_calls" >> "$stats_file"
  done

  local elapsed_p50 stat_calls_p50
  elapsed_p50="$(sort -n "$elapsed_file" | sed -n '3p')"
  stat_calls_p50="$(sort -n "$stats_file" | sed -n '3p')"
  printf 'files=%s stat_calls_p50=%s elapsed_ms_p50=%s\n' "$count" "$stat_calls_p50" "$elapsed_p50"
}

platform="$(uname -s)"
case "$platform" in
  MINGW*|MSYS*|CYGWIN*) platform_label='windows-gitbash' ;;
  Linux*)
    arch="$(uname -m)"
    if [[ "$arch" == 'aarch64' || "$arch" == 'arm64' ]]; then
      platform_label='linux-ubuntu-24.04-arm'
    else
      platform_label="linux-$arch"
    fi
    ;;
  *) platform_label="$(printf '%s' "$platform" | tr '[:upper:]' '[:lower:]')" ;;
esac

sample_6000="$(measure_size 6000)"
sample_18000="$(measure_size 18000)"
printf '%s\n' "$sample_6000" "$sample_18000"
printf 'platform=%s\n' "$platform_label"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '\n### Handoff listing stat and elapsed scaling benchmark (%s)\n\n' "$platform_label"
    printf '| files | stat_calls_p50 | elapsed_ms_p50 |\n|---:|---:|---:|\n'
    for sample in "$sample_6000" "$sample_18000"; do
      read -r files stat_calls_field elapsed_field <<<"$sample"
      printf '| %s | %s | %s |\n' "${files#files=}" "${stat_calls_field#stat_calls_p50=}" "${elapsed_field#elapsed_ms_p50=}"
    done
  } >> "$GITHUB_STEP_SUMMARY"
fi
