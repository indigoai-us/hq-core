#!/bin/bash
# master-sync.sh — syncs per-company skills folders into .claude/skills/.
#
# Triggered on Stop events. For each companies/<slug>/skills/ that exists,
# creates (or updates) a relative symlink at .claude/skills/<slug>. Idempotent.
# Real files/dirs already at the link path are left untouched.

set -uo pipefail

# Read and discard stdin (hook contract).
cat > /dev/null

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

mkdir -p "$REPO_ROOT/.claude/skills"

for company_dir in "$REPO_ROOT"/companies/*/; do
  slug="$(basename "${company_dir%/}")"
  skills_src="$REPO_ROOT/companies/$slug/skills"
  link_path="$REPO_ROOT/.claude/skills/$slug"

  [ -d "$skills_src" ] || continue

  relative_target="../../companies/$slug/skills"

  if [ -L "$link_path" ]; then
    current="$(readlink "$link_path")"
    if [ "$current" = "$relative_target" ]; then
      continue
    fi
    rm "$link_path"
  elif [ -e "$link_path" ]; then
    echo "master-sync: $link_path already exists and is not a symlink; skipping" >&2
    continue
  fi

  ln -s "$relative_target" "$link_path"
done
