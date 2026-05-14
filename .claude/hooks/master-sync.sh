#!/bin/bash
# master-sync.sh — surfaces namespace skills as Claude Code slash commands
# under .claude/commands/<ns>/<skill>.md, and mirrors
# personal/{knowledge,policies,workers,settings}/* into the matching
# core/<type>/<name> as symlinks so personal entries appear inside core.
#
# Triggered on Stop and on PostToolUse for Write/Edit/MultiEdit. Idempotent
# and cheap to re-run, so it doesn't gate on whether personal/ was actually
# touched. Real files/dirs already at the link path are left untouched.
#
# Sources surfaced as commands under .claude/commands/<namespace>/<skill>.md
# (each is a symlink to the skill's SKILL.md):
#   companies/<slug>/skills/<skill>/SKILL.md     → .claude/commands/<slug>/<skill>.md
#   core/skills/<skill>/SKILL.md                 → .claude/commands/core/<skill>.md
#   personal/skills/<skill>/SKILL.md             → .claude/commands/personal/<skill>.md
#   core/packages/<pack>/skills/<skill>/SKILL.md → .claude/commands/<pack>/<skill>.md
#
# Namespace folders are created lazily — empty namespaces leave no directory
# behind. Folders starting with '.' or '_' (e.g. _shared, _template) are
# skipped.
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

mkdir -p "$REPO_ROOT/.claude/commands"

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
  # namespace (e.g. a pack name colliding with a company slug), keep the
  # earlier mapping.
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
  seen+=("$ns")

  ns_dir="$REPO_ROOT/.claude/commands/$ns"
  if [ -L "$ns_dir" ]; then
    # Legacy folder-level symlink from a prior version of this script —
    # don't auto-replace; a human should resolve.
    echo "master-sync: $ns_dir is a symlink (legacy folder mirror); leaving alone" >&2
    continue
  fi
  if [ -e "$ns_dir" ] && [ ! -d "$ns_dir" ]; then
    echo "master-sync: $ns_dir exists and is not a directory; skipping" >&2
    continue
  fi

  # Symlink each skill's SKILL.md as <skill>.md inside the namespace folder.
  # The namespace dir is created lazily, on the first skill we actually link.
  ns_dir_created=0
  for skill_path in "$REPO_ROOT/$src_rel"/*; do
    [ -d "$skill_path" ] || continue
    skill_name="$(basename "$skill_path")"
    case "$skill_name" in
      .*|_*) continue ;;
    esac
    skill_md="$skill_path/SKILL.md"
    [ -f "$skill_md" ] || continue

    if [ "$ns_dir_created" -eq 0 ]; then
      mkdir -p "$ns_dir"
      ns_dir_created=1
    fi

    link_path="$ns_dir/$skill_name.md"
    # Link lives at .claude/commands/<ns>/<skill>.md, three levels below REPO_ROOT.
    relative_target="../../../$src_rel/$skill_name/SKILL.md"

    if [ -L "$link_path" ]; then
      current="$(readlink "$link_path")"
      if [ "$current" = "$relative_target" ]; then
        continue
      fi
      echo "master-sync: .claude/commands/$ns/$skill_name.md already points to '$current' (expected '$relative_target'); leaving alone" >&2
      continue
    elif [ -e "$link_path" ]; then
      echo "master-sync: $link_path already exists and is not a symlink; skipping" >&2
      continue
    fi

    ln -s "$relative_target" "$link_path"
  done
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
