#!/usr/bin/env bash
# Core policy format: hq-surface-generated-deliverables-immediately keeps at most
# one line of reason and no incident story or provenance section.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
F="$ROOT/core/policies/hq-surface-generated-deliverables-immediately.md"
n="$(awk '/^## /{on=($0 ~ /^## (Rationale|Why)/);next} on && NF' "$F" | wc -l | tr -d ' ')"
if [ "$n" -gt 1 ]; then echo "FAIL: reason section has $n non-empty lines (max 1)"; exit 1; fi
if grep -Eq '^## (Provenance|Examples?)' "$F"; then echo "FAIL: Provenance or Examples section present"; exit 1; fi
# The rule must say what to do when the file-sending tool refuses the file
# (for example a host that sends files only inside a project thread).
if ! grep -Eq '^[0-9]+\. When the file-sending tool refuses the file' "$F"; then echo "FAIL: no fallback rule for a refused file send"; exit 1; fi
if ! grep -E '^[0-9]+\. When the file-sending tool refuses the file' "$F" | grep -q 'project thread'; then echo "FAIL: refusal rule does not name the project-thread case"; exit 1; fi
if ! grep -E '^[0-9]+\. When the file-sending tool refuses the file' "$F" | grep -q '/hq-share'; then echo "FAIL: refusal rule does not name the /hq-share fallback"; exit 1; fi
# Rules stay numbered 1..N without gaps or repeats.
nums="$(sed -n '/^## Rule/,/^## /p' "$F" | grep -Eo '^[0-9]+\.' | tr -d '.' | tr '\n' ' ')"
want="$(seq 1 "$(echo "$nums" | wc -w | tr -d ' ')" | tr '\n' ' ')"
if [ "$nums" != "$want" ]; then echo "FAIL: rule numbering is '$nums', want '$want'"; exit 1; fi
echo "PASS: policy format"
