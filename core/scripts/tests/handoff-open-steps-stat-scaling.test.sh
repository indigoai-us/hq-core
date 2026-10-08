#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/handoff-open-steps.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/handoff-stat-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

REAL_STAT="$(command -v stat)"
REAL_FIND="$(command -v find)"
BIN="$TMP/bin"
FALLBACK_BIN="$TMP/fallback-bin"
NO_PERL_BIN="$TMP/no-perl-bin"
mkdir -p "$BIN" "$FALLBACK_BIN" "$NO_PERL_BIN"
cat > "$BIN/stat" <<'STAT_SHIM'
#!/usr/bin/env bash
printf '.\n' >> "$STAT_COUNT_FILE"
exec "$REAL_STAT" "$@"
STAT_SHIM
chmod +x "$BIN/stat"
cat > "$FALLBACK_BIN/find" <<'FIND_SHIM'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "-printf" ]]; then
    exit 1
  fi
done
exec "$REAL_FIND" "$@"
FIND_SHIM
chmod +x "$FALLBACK_BIN/find"
cat > "$NO_PERL_BIN/perl" <<'PERL_SHIM'
#!/usr/bin/env bash
printf 'called\n' >> "$PERL_CALL_FILE"
exit 127
PERL_SHIM
chmod +x "$NO_PERL_BIN/perl"

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

measure_stat_calls() {
  local count="$1" label="$2" branch="$3" path="$BIN:$PATH"
  if [[ "$branch" == "perl" ]]; then
    path="$FALLBACK_BIN:$path"
  fi
  local root="$TMP/$label" stat_count="$TMP/$label.stat-count"
  make_fixture "$count" "$root"
  : > "$stat_count"
  HQ_ROOT="$root" \
    PATH="$path" \
    STAT_COUNT_FILE="$stat_count" \
    REAL_STAT="$REAL_STAT" \
    REAL_FIND="$REAL_FIND" \
    bash "$SCRIPT" list --limit 10 >/dev/null
  wc -l < "$stat_count" | tr -d '[:space:]'
}

assert_non_scaling() {
  local branch_label="$1" small_count="$2" large_count="$3"
  if [[ "$large_count" -gt "$small_count" ]]; then
    printf 'FAIL: external stat calls scale with thread-file count in %s (%s calls at 100 files, %s at 300)\n' "$branch_label" "$small_count" "$large_count" >&2
    exit 1
  fi
  printf 'PASS: %s external stat calls do not scale with thread-file count (%s at 100 files, %s at 300)\n' "$branch_label" "$small_count" "$large_count"
}

gnu_small="$(measure_stat_calls 100 gnu-small gnu)"
gnu_large="$(measure_stat_calls 300 gnu-large gnu)"
assert_non_scaling 'GNU find -printf branch' "$gnu_small" "$gnu_large"

perl_small="$(measure_stat_calls 100 perl-small perl)"
perl_large="$(measure_stat_calls 300 perl-large perl)"
assert_non_scaling 'Perl File::Find fallback branch' "$perl_small" "$perl_large"

# A missing thread directory must not make a supported GNU find look unsupported.
missing_root="$TMP/missing-thread-root"
perl_call_file="$TMP/perl-called-for-missing-threads"
mkdir -p "$missing_root"
: > "$perl_call_file"
HQ_ROOT="$missing_root" \
  PATH="$NO_PERL_BIN:$BIN:$PATH" \
  STAT_COUNT_FILE="$TMP/missing-root.stat-count" \
  REAL_STAT="$REAL_STAT" \
  REAL_FIND="$REAL_FIND" \
  PERL_CALL_FILE="$perl_call_file" \
  bash "$SCRIPT" list --limit 10 >/dev/null
if [[ -s "$perl_call_file" ]]; then
  printf 'FAIL: missing thread directory caused GNU find capability probe to invoke Perl\n' >&2
  exit 1
fi
printf 'PASS: GNU find -printf capability probe succeeds when the thread directory is missing\n'
