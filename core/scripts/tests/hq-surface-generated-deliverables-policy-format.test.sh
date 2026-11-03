#!/usr/bin/env bash
# Core policy format: hq-surface-generated-deliverables-immediately keeps at most
# one line of reason and no incident story or provenance section.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
F="$ROOT/core/policies/hq-surface-generated-deliverables-immediately.md"
n="$(awk '/^## /{on=($0 ~ /^## (Rationale|Why)/);next} on && NF' "$F" | wc -l | tr -d ' ')"
if [ "$n" -gt 1 ]; then echo "FAIL: reason section has $n non-empty lines (max 1)"; exit 1; fi
if grep -Eq '^## (Provenance|Examples?)' "$F"; then echo "FAIL: Provenance or Examples section present"; exit 1; fi
echo "PASS: policy format"
