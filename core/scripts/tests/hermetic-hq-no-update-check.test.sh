#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SOURCE_ROOT="${HQ_TEST_SOURCE_ROOT:-$ROOT}"
HELPER="$SOURCE_ROOT/core/scripts/tests/lib/hq-hermetic-env.sh"
if [ -f "$HELPER" ]; then
  source "$HELPER"
else
  # Baseline behavior for the fail-first control: plain env -i drops the
  # caller's update opt-out.
  hq_test_clean_env() { env -i "$@"; }
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-hermetic-env.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hq" <<'HQ'
#!/usr/bin/env bash
if [ "${1:-}" = "expect-unset" ]; then
  if [ "${HQ_NO_UPDATE_CHECK+x}" = x ]; then
    printf 'HQ_NO_UPDATE_CHECK should stay unset\n' >&2
    exit 91
  fi
  printf 'unset preserved as unset\n'
  exit 0
fi
if [ "${HQ_NO_UPDATE_CHECK:-}" != "1" ]; then
  printf 'hq-cli 5.269.0 is below the minimum required version (5.293.0)\n' >&2
  exit 75
fi
printf 'normal hq output\n'
HQ
chmod +x "$TMP/bin/hq"

failures=0
if output="$(HQ_NO_UPDATE_CHECK=1 hq_test_clean_env PATH="$TMP/bin:/usr/bin:/bin" hq run 2>&1)"; then
  if [ "$output" = 'normal hq output' ]; then
    printf 'ok: caller opt-out reaches hq through a clean environment\n'
  else
    printf 'FAIL: unexpected hq output: %s\n' "$output" >&2
    failures=$((failures + 1))
  fi
else
  rc=$?
  printf 'FAIL: pinned hq exited %s through a clean environment: %s\n' "$rc" "$output" >&2
  failures=$((failures + 1))
fi

unset HQ_NO_UPDATE_CHECK
if output="$(hq_test_clean_env PATH="$TMP/bin:/usr/bin:/bin" hq expect-unset 2>&1)"; then
  if [ "$output" = 'unset preserved as unset' ]; then
    printf 'ok: unset caller opt-out remains unset\n'
  else
    printf 'FAIL: unexpected unset-case output: %s\n' "$output" >&2
    failures=$((failures + 1))
  fi
else
  rc=$?
  printf 'FAIL: unset-case hq exited %s: %s\n' "$rc" "$output" >&2
  failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] || exit 1
printf 'PASS: hq hermetic environment preserves only the caller-set update opt-out\n'
