#!/bin/bash
# Block Glob calls that should use qmd or direct Read instead
# 1. Block ALL Glob for prd.json / worker.yaml (use qmd search or Read)
# 2. Block unscoped Glob from HQ root (causes 20s timeouts)

INPUT=$(cat)
HQ="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"

PATH_PARAM=$(echo "$INPUT" | jq -r '.tool_input.path // empty')
PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern')
CWD=$(echo "$INPUT" | jq -r '.cwd')

# Block prd.json and worker.yaml discovery — always use qmd or direct Read
if echo "$PATTERN" | grep -qE 'prd\.json|worker\.yaml'; then
  cat >&2 <<EOF
BLOCKED: Never use Glob for prd.json or worker.yaml.

For discovery:  qmd search "{name} prd.json" --json -n 5
For known path: Read companies/{co}/projects/{name}/prd.json
For workers:    Read workers/registry.yaml → find path → Read worker.yaml
EOF
  exit 2
fi

# Resolve effective search path
if [ -z "$PATH_PARAM" ]; then
  SEARCH_PATH="$CWD"
else
  SEARCH_PATH="$PATH_PARAM"
fi

# Block if searching HQ root exactly
if [ "$SEARCH_PATH" = "$HQ" ] || [ "$SEARCH_PATH" = "$HQ/" ]; then
  cat >&2 <<EOF
BLOCKED: Glob from HQ root causes timeouts (1.38M files via symlinked repos).

Fix: Add path: scoped to a subdirectory:
  Glob pattern="$PATTERN" path="companies/"
  Glob pattern="$PATTERN" path="workers/"
  Glob pattern="$PATTERN" path="workspace/"

Or use: qmd search "query" --json -n 10
EOF
  exit 2
fi

exit 0
