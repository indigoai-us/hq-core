#!/usr/bin/env bash
# compute-checksums.sh — Regenerate SHA256 checksums for all locked paths in core.yaml
# Usage: scripts/compute-checksums.sh [path-to-core.yaml]
#
# For files: SHA256 of file contents
# For directories: deterministic hash — sorted recursive file list,
#   each line '<file-sha256>  <relative-path>', then SHA256 of combined string
# core.yaml itself is excluded (self-referential / circular)
#
# Compatible with bash 3.2+ (macOS default)

set -euo pipefail

HQ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE_YAML="${1:-$HQ_ROOT/core.yaml}"

if [ ! -f "$CORE_YAML" ]; then
  echo "ERROR: core.yaml not found at $CORE_YAML" >&2
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required (brew install yq)" >&2
  exit 1
fi

# Compute SHA256 for a single file (returns hex string)
file_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# Compute deterministic SHA256 for a directory
dir_sha256() {
  local dir="${1%/}"
  local tmpfile
  tmpfile=$(mktemp)

  # Find all files recursively, sorted by relative path
  find "$dir" -type f | sort | while IFS= read -r filepath; do
    local relpath="${filepath#$dir/}"
    local hash
    hash=$(file_sha256 "$filepath")
    printf '%s  %s\n' "$hash" "$relpath"
  done > "$tmpfile"

  # SHA256 of the combined string
  shasum -a 256 "$tmpfile" | awk '{print $1}'
  rm -f "$tmpfile"
}

# Temp file to collect path=hash pairs
CHECKSUM_FILE=$(mktemp)
trap 'rm -f "$CHECKSUM_FILE"' EXIT

count=0

# Read locked paths and compute checksums
yq '.rules.locked[]' "$CORE_YAML" | while IFS= read -r path; do
  # Skip core.yaml itself (circular reference)
  if [ "$path" = "core.yaml" ]; then
    continue
  fi

  full_path="$HQ_ROOT/$path"

  if [ ! -e "$full_path" ]; then
    echo "WARNING: locked path does not exist: $path" >&2
    continue
  fi

  # Strip trailing slash for consistency in key name
  clean_path="${path%/}"

  if [ -f "$full_path" ]; then
    hash=$(file_sha256 "$full_path")
    printf '%s\t%s\n' "$clean_path" "$hash" >> "$CHECKSUM_FILE"
  elif [ -d "$full_path" ]; then
    hash=$(dir_sha256 "$full_path")
    printf '%s\t%s\n' "$clean_path" "$hash" >> "$CHECKSUM_FILE"
  fi
done

# Clear existing checksums
yq -i '.checksums = {}' "$CORE_YAML"

# Write checksums sorted by path
sort "$CHECKSUM_FILE" | while IFS=$'\t' read -r path hash; do
  yq -i ".checksums.\"$path\" = \"$hash\"" "$CORE_YAML"
  count=$((count + 1))
done

# Update the updatedAt timestamp
yq -i ".updatedAt = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$CORE_YAML"

# Count results
num_checksums=$(yq '.checksums | length' "$CORE_YAML")
echo "Checksums updated in $CORE_YAML"
echo "Paths processed: $num_checksums"
