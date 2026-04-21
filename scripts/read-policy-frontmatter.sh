#!/bin/bash
# read-policy-frontmatter.sh — Extract YAML frontmatter from a policy file
#
# Usage: bash scripts/read-policy-frontmatter.sh <policy-file>
#
# Returns only the YAML frontmatter block (between the first two --- markers),
# skipping the policy body. Used by /startwork, /prd, /brainstorm, /run commands
# to minimize context burn when scanning policy metadata (id, title, enforcement,
# trigger) without loading the full ## Rule and ## Rationale sections.
#
# Exit codes:
#   0 - Success, frontmatter written to stdout
#   1 - Usage error or file not readable

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "USAGE: read-policy-frontmatter.sh <policy-file>" >&2
  exit 1
fi

FILE="$1"

if [ ! -r "$FILE" ]; then
  echo "ERROR: File not readable: $FILE" >&2
  exit 1
fi

# Extract frontmatter: lines between first two --- markers.
# c counts --- markers; print lines only while inside the frontmatter (c==1).
awk '/^---$/{c++; next} c==1' "$FILE"
