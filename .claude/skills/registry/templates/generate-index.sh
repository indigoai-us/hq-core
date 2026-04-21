#!/usr/bin/env bash
# scripts/generate-index.sh
# Reads all resources/*.yaml files and produces registry.yaml at the repo root.
#
# Usage:
#   ./scripts/generate-index.sh
#
# Output:
#   registry.yaml — index of all resources (id, name, type, status, path)
#
# Requirements:
#   yq v4+ (https://github.com/mikefarah/yq) — brew install yq
#
# The registry.yaml follows the same pattern as workers/registry.yaml in HQ:
# a flat list of lightweight index entries, each pointing to the full resource
# file for detailed fields.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES_DIR="${REPO_ROOT}/resources"
OUTPUT_FILE="${REPO_ROOT}/registry.yaml"

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required but not found." >&2
  echo "Install with: brew install yq" >&2
  exit 1
fi

YQ_VERSION=$(yq --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
YQ_MAJOR=$(echo "$YQ_VERSION" | cut -d. -f1)
if [[ "$YQ_MAJOR" -lt 4 ]]; then
  echo "ERROR: yq v4+ is required (found v${YQ_VERSION})." >&2
  echo "Install with: brew install yq" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Collect resource files
# ---------------------------------------------------------------------------
if [[ ! -d "$RESOURCES_DIR" ]]; then
  echo "ERROR: resources/ directory not found at ${RESOURCES_DIR}" >&2
  exit 1
fi

readarray_compat() {
  # Portable alternative to mapfile/readarray for bash 3.x (macOS system bash)
  local line
  RESOURCE_FILES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && RESOURCE_FILES+=("$line")
  done < <(find "$RESOURCES_DIR" -maxdepth 1 -name "*.yaml" | sort)
}
readarray_compat

if [[ ${#RESOURCE_FILES[@]} -eq 0 ]]; then
  echo "WARNING: No resource files found in resources/. Writing empty registry." >&2
fi

# ---------------------------------------------------------------------------
# Build registry.yaml
# ---------------------------------------------------------------------------
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ENTRY_COUNT=${#RESOURCE_FILES[@]}

{
  echo "# registry.yaml"
  echo "# Auto-generated index of all resources in this company's registry."
  echo "# DO NOT edit by hand — regenerate with: ./scripts/generate-index.sh"
  echo "#"
  echo "# Generated: ${TIMESTAMP}"
  echo "# Resources: ${ENTRY_COUNT}"
  echo ""
  echo "generated_at: \"${TIMESTAMP}\""
  echo "resource_count: ${ENTRY_COUNT}"
  echo "resources:"
} > "$OUTPUT_FILE"

ERRORS=0

for file in "${RESOURCE_FILES[@]}"; do
  # Relative path from repo root (for portability)
  rel_path="${file#${REPO_ROOT}/}"

  # Extract required index fields using yq
  id=$(yq '.id // ""' "$file" 2>/dev/null || true)
  name=$(yq '.name // ""' "$file" 2>/dev/null || true)
  type=$(yq '.type // ""' "$file" 2>/dev/null || true)
  status=$(yq '.status // ""' "$file" 2>/dev/null || true)

  # Validate required fields are present
  missing=()
  [[ -z "$id" || "$id" == "null" ]]     && missing+=("id")
  [[ -z "$name" || "$name" == "null" ]] && missing+=("name")
  [[ -z "$type" || "$type" == "null" ]] && missing+=("type")
  [[ -z "$status" || "$status" == "null" ]] && missing+=("status")

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "WARNING: Skipping ${rel_path} — missing required fields: ${missing[*]}" >&2
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Append index entry
  {
    echo "  - id: ${id}"
    echo "    name: ${name}"
    echo "    type: ${type}"
    echo "    status: ${status}"
    echo "    path: ${rel_path}"
  } >> "$OUTPUT_FILE"
done

echo "" >> "$OUTPUT_FILE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
INDEXED=$((ENTRY_COUNT - ERRORS))
echo "Generated ${OUTPUT_FILE}"
echo "  Indexed: ${INDEXED} resource(s)"
[[ $ERRORS -gt 0 ]] && echo "  Skipped: ${ERRORS} file(s) with missing required fields" >&2

exit 0
