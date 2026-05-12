#!/bin/bash
# master-sync.sh — syncs namespace skills folders into .claude/skills/, and
# mirrors personal/{knowledge,policies,workers,settings}/* into the matching
# core/<type>/<name> as symlinks so personal entries appear inside core.
#
# Triggered on Stop and on PostToolUse for Write/Edit/MultiEdit. Idempotent
# and cheap to re-run, so it doesn't gate on whether personal/ was actually
# touched. Real files/dirs already at the link path are left untouched.
#
# Sources mirrored into .claude/skills/<namespace>:
#   companies/<slug>/skills/        → .claude/skills/<slug>
#   core/skills/                    → .claude/skills/core
#   personal/skills/                → .claude/skills/personal
#   core/packages/<pack>/skills/    → .claude/skills/<pack>
#
# Sources mirrored into core/<type>/ (one symlink per entry):
#   personal/knowledge/<entry>      → core/knowledge/<entry>
#   personal/policies/<entry>       → core/policies/<entry>
#   personal/workers/<entry>        → core/workers/<entry>
#   personal/settings/<entry>       → core/settings/<entry>
#
# Collision: if the link path already exists as a non-symlink, log + skip.

set -uo pipefail

# Read and discard stdin (hook contract).
cat > /dev/null

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

mkdir -p "$REPO_ROOT/.claude/skills"

# Build (namespace, src_rel) pairs.
namespaces=()
src_rels=()

add_ns() {
  local ns="$1" src_rel="$2"
  [ -d "$REPO_ROOT/$src_rel" ] || return 0
  namespaces+=("$ns")
  src_rels+=("$src_rel")
}

for company_dir in "$REPO_ROOT"/companies/*/; do
  [ -d "$company_dir" ] || continue
  slug="$(basename "${company_dir%/}")"
  add_ns "$slug" "companies/$slug/skills"
done

add_ns "core" "core/skills"
add_ns "personal" "personal/skills"

for pack_dir in "$REPO_ROOT"/core/packages/*/; do
  [ -d "$pack_dir" ] || continue
  pack="$(basename "${pack_dir%/}")"
  add_ns "$pack" "core/packages/$pack/skills"
done

i=0
seen=()
while [ "$i" -lt "${#namespaces[@]}" ]; do
  ns="${namespaces[$i]}"
  src_rel="${src_rels[$i]}"
  i=$((i + 1))

  # First writer for a namespace wins. If two sources resolve to the same
  # namespace (e.g. companies/personal/skills and top-level personal/skills,
  # or a pack name colliding with a company slug), keep the earlier link.
  already=0
  for s in ${seen[@]+"${seen[@]}"}; do
    if [ "$s" = "$ns" ]; then
      already=1
      break
    fi
  done
  if [ "$already" -eq 1 ]; then
    echo "master-sync: namespace '$ns' already claimed by an earlier source; skipping $src_rel" >&2
    continue
  fi

  link_path="$REPO_ROOT/.claude/skills/$ns"
  relative_target="../../$src_rel"

  if [ -L "$link_path" ]; then
    current="$(readlink "$link_path")"
    if [ "$current" = "$relative_target" ]; then
      seen+=("$ns")
      continue
    fi
    # Existing symlink points elsewhere — preserve it and log. A namespace's
    # source is human-resolved, not auto-repointed on every Stop hook.
    echo "master-sync: .claude/skills/$ns already points to '$current' (expected '$relative_target'); leaving alone" >&2
    seen+=("$ns")
    continue
  elif [ -e "$link_path" ]; then
    echo "master-sync: $link_path already exists and is not a symlink; skipping" >&2
    continue
  fi

  ln -s "$relative_target" "$link_path"
  seen+=("$ns")
done

# Mirror personal/<type>/<entry> into core/<type>/<entry> as symlinks.
# .gitkeep and dotfiles are ignored.
for type in knowledge policies workers settings; do
  personal_dir="$REPO_ROOT/personal/$type"
  core_dir="$REPO_ROOT/core/$type"

  [ -d "$personal_dir" ] || continue
  mkdir -p "$core_dir"

  for entry_path in "$personal_dir"/*; do
    [ -e "$entry_path" ] || continue
    entry="$(basename "$entry_path")"
    case "$entry" in
      .*) continue ;;
    esac

    link_path="$core_dir/$entry"
    relative_target="../../personal/$type/$entry"

    if [ -L "$link_path" ]; then
      current="$(readlink "$link_path")"
      if [ "$current" = "$relative_target" ]; then
        continue
      fi
      echo "master-sync: core/$type/$entry already points to '$current' (expected '$relative_target'); leaving alone" >&2
      continue
    elif [ -e "$link_path" ]; then
      echo "master-sync: core/$type/$entry already exists and is not a symlink; skipping" >&2
      continue
    fi

    ln -s "$relative_target" "$link_path"
  done
done
