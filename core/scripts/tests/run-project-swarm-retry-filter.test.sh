#!/usr/bin/env bash
# Execute the real swarm retry-queue filter with a non-empty retry queue.
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/run-project.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FILTER="$TMP/swarm-retry-filter.sh"
HARNESS="$TMP/harness.sh"

awk '
  $0 == "    # Filter out stories that exhausted swarm retries (already in retry_queue)" {
    capturing = 1
    next
  }
  capturing && $0 == "    fi" {
    found = 1
    sub(/^    /, "")
    print
    exit
  }
  capturing {
    sub(/^    /, "")
    print
  }
  END {
    if (!found) exit 1
  }
' "$SCRIPT" > "$FILTER"

cat > "$HARNESS" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
retry_queue=("retried-story")
local_candidates=$'retried-story\nfresh-story'
. "$FILTER_FRAGMENT"
[[ "$local_candidates" == "fresh-story" ]] || {
  printf 'unexpected filtered candidates: %s\n' "$local_candidates" >&2
  exit 1
}
printf '%s\n' 'swarm retry filter behavior passed'
HARNESS

status=0
FILTER_FRAGMENT="$FILTER" /bin/bash "$HARNESS" > "$TMP/output" 2> "$TMP/stderr" || status=$?
if [[ "$status" -ne 0 ]]; then
  printf 'FAIL: extracted swarm retry filter exited %s\n' "$status" >&2
  cat "$TMP/stderr" >&2
  exit 1
fi

grep -Fxq 'swarm retry filter behavior passed' "$TMP/output" || {
  echo 'FAIL: retry filter did not complete its behavior assertion' >&2
  cat "$TMP/output" "$TMP/stderr" >&2
  exit 1
}

echo 'run-project swarm retry filter test passed'
