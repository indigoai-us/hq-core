#!/bin/bash
# Block Grep calls that should use qmd or direct Read instead
# Block Grep for prd.json / worker.yaml discovery (use qmd search or Read)

INPUT=$(cat)

PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern')

# Block prd.json and worker.yaml discovery — always use qmd or direct Read
if echo "$PATTERN" | grep -qE 'prd\.json|worker\.yaml'; then
  cat >&2 <<EOF
BLOCKED: Never use Grep for prd.json or worker.yaml discovery.

For discovery:  qmd search "{name} prd.json" --json -n 5
For known path: Read companies/{co}/projects/{name}/prd.json
For workers:    Read workers/registry.yaml → find path → Read worker.yaml
EOF
  exit 2
fi

exit 0
