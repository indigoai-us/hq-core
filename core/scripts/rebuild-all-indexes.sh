#!/usr/bin/env bash
# rebuild-all-indexes.sh — fan out to every per-class INDEX.md regenerator.
#
# Stdout: JSON array of every INDEX.md path that was actually written
# (parsed from per-script "wrote {path}" lines on stderr).
# Stderr: passthrough log from each script, plus a final "all-indexes: ok"
# or "all-indexes: errors" line.
#
# Used by handoff-post.sh / handoff-finalize.sh / /cleanup --reindex.
# Exit 0 always (handoff must not fail because one INDEX class blew up).

set -uo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$HQ_ROOT"

SCRIPTS=(
  "rebuild-threads-index.sh"
  "rebuild-orchestrator-index.sh"
  "rebuild-companies-index.sh"
  "rebuild-projects-index.sh"
  "rebuild-company-knowledge-index.sh"
  "rebuild-public-knowledge-index.sh"
  "rebuild-workers-index.sh"
  "rebuild-reports-index.sh"
  "rebuild-social-drafts-index.sh"
)

TMP_STDERR=$(mktemp /tmp/rebuild-all-indexes.XXXXXX)
trap 'rm -f "$TMP_STDERR"' EXIT

ERRORS=0
for s in "${SCRIPTS[@]}"; do
  path="core/scripts/${s}"
  if [[ ! -x "$path" ]] && [[ -f "$path" ]]; then
    chmod +x "$path" 2>/dev/null || true
  fi
  if [[ ! -f "$path" ]]; then
    echo "rebuild-all-indexes: skip ${s} (missing)" >&2
    continue
  fi
  if ! bash "$path" 2>>"$TMP_STDERR"; then
    echo "rebuild-all-indexes: ERROR in ${s}" >&2
    ERRORS=$((ERRORS+1))
  fi
done

# Replay each rebuild's stderr to our stderr (so callers see logs)
cat "$TMP_STDERR" >&2

# Parse "wrote {path}" lines to build the JSON output array
paths_json=$(
  grep -E 'wrote (workspace|companies|knowledge|workers|projects)' "$TMP_STDERR" 2>/dev/null \
    | sed -E 's/.*wrote ([^ ]+).*/\1/' \
    | sort -u \
    | jq -R . \
    | jq -s .
)
[[ -z "$paths_json" ]] && paths_json='[]'

printf '%s\n' "$paths_json"

if [[ "$ERRORS" -gt 0 ]]; then
  echo "all-indexes: errors (${ERRORS})" >&2
else
  echo "all-indexes: ok" >&2
fi

exit 0
