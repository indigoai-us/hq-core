#!/bin/bash
# master-sync.sh — surfaces namespace skills as Claude Code skills under
# .claude/skills/<ns>:<skill>/ with every file in the source skill folder
# mirrored as a symlink. Also mirrors personal/{knowledge,policies,workers,
# settings}/* into core/<type>/<name>.
#
# Triggered on Stop and on PostToolUse for Write/Edit/MultiEdit. Idempotent
# and cheap to re-run, so it doesn't gate on whether personal/ was actually
# touched. Real files/dirs already at the link path are left untouched.
#
# Sources surfaced as skills under .claude/skills/<namespace>:<skill>/
# (each contains a symlink per source file, including SKILL.md):
#   companies/<slug>/skills/<skill>/*     → .claude/skills/<slug>:<skill>/*
#   core/skills/<skill>/*                 → .claude/skills/core:<skill>/*
#   personal/skills/<skill>/*             → .claude/skills/personal:<skill>/*
#   core/packages/<pack>/skills/<skill>/* → .claude/skills/<pack>:<skill>/*
#
# Namespace folders are created lazily. Skill folders starting with '.' or
# '_' (e.g. _shared, _template) are skipped. Dotfiles inside a skill folder
# (e.g. .DS_Store, .git) are not mirrored.
#
# Cleanup performed each run:
#   1. Legacy .claude/commands/<ns>/<skill>.md symlinks created by a prior
#      version of this script are removed. Non-symlink files left alone.
#      Empty .claude/commands/<ns>/ dirs are rmdir'd.
#   2. Stale entries inside a wrapper (symlinks whose source file no longer
#      exists) are pruned.
#   3. Orphan .claude/skills/<ns>:<skill>/ wrappers (where <ns> is one of
#      the namespaces we manage but the source skill is gone) are deleted.
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

# --- Cleanup pass A: drop legacy .claude/commands/<ns>/<skill>.md symlinks ---
# Scan ALL .claude/commands/*/ namespace dirs (not just ones whose source
# root currently exists). Remove any *.md symlink whose target follows the
# legacy bridge pattern. This handles namespaces whose entire source root
# was deleted between runs — e.g. an archived company or removed pack —
# which otherwise leave broken slash-command symlinks behind.
# Manual or unrelated *.md files (non-symlinks, or symlinks pointing
# elsewhere) are preserved.
if [ -d "$REPO_ROOT/.claude/commands" ]; then
  for cmd_ns_dir in "$REPO_ROOT/.claude/commands"/*/; do
    [ -d "$cmd_ns_dir" ] || continue
    cmd_ns_dir="${cmd_ns_dir%/}"
    # Don't touch folder-level symlinks (could be legacy structure from an
    # even older script version — let a human resolve).
    [ -L "$cmd_ns_dir" ] && continue

    for f in "$cmd_ns_dir"/*.md; do
      [ -L "$f" ] || continue
      target="$(readlink "$f")"
      case "$target" in
        ../../../companies/*/skills/*/SKILL.md|\
../../../core/skills/*/SKILL.md|\
../../../personal/skills/*/SKILL.md|\
../../../core/packages/*/skills/*/SKILL.md)
          rm "$f"
          ;;
      esac
    done

    # rmdir if empty; ignore "directory not empty"
    rmdir "$cmd_ns_dir" 2>/dev/null || true
  done
fi

# --- Skill wrapper creation ---
# Track which <ns>:<skill> wrappers we maintained this run, for orphan
# cleanup at the end.
expected_wrappers=()

i=0
seen=()
while [ "$i" -lt "${#namespaces[@]}" ]; do
  ns="${namespaces[$i]}"
  src_rel="${src_rels[$i]}"
  i=$((i + 1))

  # First writer for a namespace wins.
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

  for skill_path in "$REPO_ROOT/$src_rel"/*; do
    [ -d "$skill_path" ] || continue
    skill_name="$(basename "$skill_path")"
    case "$skill_name" in
      .*|_*) continue ;;
    esac
    [ -f "$skill_path/SKILL.md" ] || continue

    wrapper_name="$ns:$skill_name"
    wrapper="$REPO_ROOT/.claude/skills/$wrapper_name"
    expected_wrappers+=("$wrapper_name")

    # If something non-directory occupies the slot, bail.
    if [ -e "$wrapper" ] && [ ! -L "$wrapper" ] && [ ! -d "$wrapper" ]; then
      echo "master-sync: $wrapper exists and is not a directory; skipping" >&2
      continue
    fi
    # If it's a symlink (e.g. legacy directory-symlink form from earlier
    # experimentation), replace with a real directory of per-file symlinks.
    if [ -L "$wrapper" ]; then
      rm "$wrapper"
    fi
    mkdir -p "$wrapper"

    # Symlink every (non-hidden) entry in the source skill folder into the
    # wrapper. Wrapper lives at .claude/skills/<ns>:<skill>/, three levels
    # below REPO_ROOT.
    for entry_path in "$skill_path"/*; do
      [ -e "$entry_path" ] || continue
      entry="$(basename "$entry_path")"
      link_path="$wrapper/$entry"
      relative_target="../../../$src_rel/$skill_name/$entry"

      if [ -L "$link_path" ]; then
        current="$(readlink "$link_path")"
        if [ "$current" = "$relative_target" ]; then
          continue
        fi
        echo "master-sync: .claude/skills/$wrapper_name/$entry already points to '$current' (expected '$relative_target'); leaving alone" >&2
        continue
      elif [ -e "$link_path" ]; then
        echo "master-sync: $link_path already exists and is not a symlink; skipping" >&2
        continue
      fi

      ln -s "$relative_target" "$link_path"
    done

    # Prune symlinks in the wrapper whose source entry no longer exists.
    # -e on a symlink dereferences; a stale link fails -e.
    for link_path in "$wrapper"/*; do
      [ -L "$link_path" ] || continue
      [ -e "$link_path" ] && continue
      rm "$link_path"
    done
  done
done

# --- Cleanup pass B: drop orphan <ns>:<skill> wrappers ---
# A wrapper is an orphan if its <ns> belongs to a managed namespace but the
# source skill folder no longer exists (so we didn't add it to
# expected_wrappers this run). Unmanaged-namespace entries are left alone —
# users can hand-author <ns>:<name> wrappers and we won't clobber them.
for entry_path in "$REPO_ROOT/.claude/skills"/*; do
  # Accept entries that exist OR are broken symlinks. A bare -e check
  # would skip dangling symlink wrappers, which are exactly the orphans
  # this pass needs to remove.
  [ -e "$entry_path" ] || [ -L "$entry_path" ] || continue
  entry="$(basename "$entry_path")"
  case "$entry" in
    *:*) ;;
    *) continue ;;  # not a namespaced wrapper
  esac

  # Skip wrappers we maintained this run.
  is_expected=0
  for w in ${expected_wrappers[@]+"${expected_wrappers[@]}"}; do
    if [ "$w" = "$entry" ]; then
      is_expected=1
      break
    fi
  done
  if [ "$is_expected" -eq 1 ]; then
    continue
  fi

  # Detect whether this wrapper was produced by this script. Required:
  # the wrapper's namespace prefix MUST match the namespace encoded in its
  # symlink target. That distinguishes script-produced wrappers
  # (e.g. personal:foo -> personal/skills/foo) from hand-authored composite
  # wrappers (e.g. vendor:tool -> core/skills/some-helper, where 'vendor'
  # is not a namespace we manage). Without the cross-check we'd clobber
  # the user's hand-authored entries.
  #
  # Two wrapper shapes need to be handled:
  #   (a) entry_path itself is a symlink — directory-style wrapper from an
  #       older script version. Target uses 2-level relative paths.
  #   (b) entry_path is a real directory containing per-file symlinks —
  #       current shape. Each inner symlink uses 3-level relative paths.
  ns="${entry%%:*}"
  is_managed=0
  match_target() {
    # Args: $1=target, $2=relative prefix (../.. or ../../..)
    # Returns 0 if target matches the expected pattern for $ns.
    local t="$1" p="$2"
    case "$t" in
      "$p"/personal/skills/*)         [ "$ns" = "personal" ] && return 0 ;;
      "$p"/core/skills/*)             [ "$ns" = "core" ] && return 0 ;;
      "$p"/companies/"$ns"/skills/*)  return 0 ;;
      "$p"/core/packages/"$ns"/skills/*) return 0 ;;
    esac
    return 1
  }
  if [ -L "$entry_path" ]; then
    t="$(readlink "$entry_path")"
    if match_target "$t" "../.."; then
      is_managed=1
    fi
  else
    for f in "$entry_path"/*; do
      [ -L "$f" ] || continue
      t="$(readlink "$f")"
      if match_target "$t" "../../.."; then
        is_managed=1
        break
      fi
    done
  fi
  if [ "$is_managed" -eq 0 ]; then
    continue
  fi

  # It's a managed-namespace wrapper with no corresponding live source → drop.
  if [ -L "$entry_path" ]; then
    rm "$entry_path"
  elif [ -d "$entry_path" ]; then
    rm -rf "$entry_path"
  fi
done

# --- Personal type mirroring (unchanged from prior version) ---
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

# --- Workers registry regeneration ---
# Source of truth: each worker.yaml. Registry is a derived index — regenerated
# here so it stays in sync with worker.yaml edits. Idempotent — only writes
# when generated content differs.
"$REPO_ROOT/core/scripts/generate-workers-registry.sh" >&2 2>&1 || true
