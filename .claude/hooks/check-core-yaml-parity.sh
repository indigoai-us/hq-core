#!/bin/bash
# check-core-yaml-parity.sh — SessionStart hook (non-blocking)
#
# Warns at session start if HQ root core.yaml:hqVersion has drifted from
# repos/public/hq-core/core.yaml:hqVersion. Policy: core-yaml-parity
# (The /promote-hq-core manifest-bump step is the primary enforcement;
# this hook is belt-and-suspenders that catches drift from hand-edits or
# partial releases.)
#
# Exit codes: always 0 (SessionStart hooks cannot block session startup)

set -euo pipefail

# Read and discard stdin
cat >/dev/null 2>&1 || true

HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
HQ_CORE="$HQ_ROOT/core.yaml"
HQ_CORE_TARGET="$HQ_ROOT/repos/public/hq-core/core.yaml"

# Silent if either file is missing — this hook's job is parity detection,
# not file-presence enforcement. Other hooks / commands own that.
[[ -f "$HQ_CORE" && -f "$HQ_CORE_TARGET" ]] || exit 0

extract_version() {
  awk -F'"' '/^hqVersion:/{print $2; exit}' "$1" 2>/dev/null || true
}

HQ_V="$(extract_version "$HQ_CORE")"
CORE_V="$(extract_version "$HQ_CORE_TARGET")"

# Silent if either extract failed — quiet mode beats noisy-fail.
[[ -n "$HQ_V" && -n "$CORE_V" ]] || exit 0

if [[ "$HQ_V" != "$CORE_V" ]]; then
  cat <<EOF
⚠️  core.yaml hqVersion drift detected

  HQ root:  $HQ_V    ($HQ_CORE)
  hq-core:  $CORE_V    ($HQ_CORE_TARGET)

Consumers running \`/update-hq --check\` will see a phantom upgrade path.
Resolve via /promote-hq-core (manifest-bump step), or manually:

  VERSION="{correct-version}"
  NOW="\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  HQ_BYPASS_CORE_PROTECT=1 sed -i '' \\
    -e "s/^hqVersion: \".*\"\$/hqVersion: \"\${VERSION}\"/" \\
    -e "s/^updatedAt: \".*\"\$/updatedAt: \"\${NOW}\"/" \\
    core.yaml repos/public/hq-core/core.yaml

Policy: .claude/policies/core-yaml-parity.md
EOF
fi

exit 0
