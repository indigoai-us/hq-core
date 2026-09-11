#!/bin/bash
# hq-core: public
# Block Glob calls that should use qmd or direct Read instead
# 1. Block ALL Glob for prd.json / worker.yaml (use qmd search or Read)
# 2. Block unscoped Glob from HQ root (causes 20s timeouts)

INPUT=$(cat)
HQ="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
# Prefer HQ_ROOT from the Grok adapter when git toplevel is a nested repo.
if [ -n "${HQ_ROOT:-}" ] && [ -d "$HQ_ROOT" ]; then
  HQ="$HQ_ROOT"
fi

# Accept Claude + Grok field names (path / target_directory / file_path).
PATH_PARAM=$(echo "$INPUT" | jq -r '
  .tool_input.path
  // .tool_input.target_directory
  // .tool_input.file_path
  // .toolInput.path
  // .toolInput.target_directory
  // empty
')
PATTERN=$(echo "$INPUT" | jq -r '
  .tool_input.pattern // .tool_input.glob // .toolInput.pattern // empty
')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
TOOL=$(echo "$INPUT" | jq -r '.tool_name // .toolName // empty')

# list_dir / ListDir is a shallow readdir — never subject to the recursive Glob guard.
case "$TOOL" in
  list_dir|ListDir|LS|list)
    exit 0
    ;;
esac

# Block prd.json and worker.yaml discovery — always use qmd or direct Read
if echo "$PATTERN" | grep -qE 'prd\.json|worker\.yaml'; then
  cat >&2 <<EOF
BLOCKED: Never use Glob for prd.json or worker.yaml.

For discovery:  qmd search "{name} prd.json" --json -n 5
For known path: Read companies/{co}/projects/{name}/prd.json
For workers:    Read core/workers/registry.yaml → find path → Read worker.yaml
EOF
  exit 2
fi

if [ -z "$PATH_PARAM" ] || [ "$PATH_PARAM" = "null" ]; then
  cat >&2 <<EOF
BLOCKED: Glob needs a path. Pass path scoped to a subdirectory (not HQ root).
  Glob pattern="<pattern>" path="core/"
  Glob pattern="<pattern>" path="workspace/"
  Glob pattern="<pattern>" path="companies/"
Or use: qmd search "query" --json -n 10
EOF
  exit 2
fi

# Resolve effective search path
if [ -z "$PATH_PARAM" ]; then
  SEARCH_PATH="$CWD"
else
  SEARCH_PATH="$PATH_PARAM"
fi

# Block if searching HQ root exactly (recursive Glob only — not a single-dir list)
if [ "$SEARCH_PATH" = "$HQ" ] || [ "$SEARCH_PATH" = "$HQ/" ]; then
  cat >&2 <<EOF
BLOCKED: Glob from HQ root causes timeouts (1.38M files via symlinked repos).

Fix: Add path: scoped to a subdirectory:
  Glob pattern="$PATTERN" path="companies/"
  Glob pattern="$PATTERN" path="core/workers/"
  Glob pattern="$PATTERN" path="workspace/"

Or use: qmd search "query" --json -n 10
EOF
  exit 2
fi

exit 0
