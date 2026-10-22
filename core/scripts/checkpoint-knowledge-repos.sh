#!/usr/bin/env bash
# checkpoint-knowledge-repos.sh — print knowledge repos with uncommitted
# changes, and flag knowledge symlinks, for the checkpoint thread's
# git.knowledge_repos field.
#
# Usage: bash core/scripts/checkpoint-knowledge-repos.sh [HQ_ROOT]
#
# This replaces an inline snippet in .claude/skills/checkpoint/SKILL.md. The
# snippet used `shopt`, which is bash-only; agents (including the automated
# checkpoint sibling) often retyped it into a zsh shell and hit
# "shopt: command not found" (feedback 5ad007c4). Running a real bash script
# makes the shell irrelevant: call it as `bash <script>` from any shell.
set -u
root="${1:-$PWD}"
cd "$root" 2>/dev/null || { echo "checkpoint-knowledge-repos: cannot enter $root" >&2; exit 0; }
shopt -s nullglob
for knowledge_path in core/knowledge/public/* core/knowledge/private/* personal/knowledge/* companies/*/knowledge; do
  if [ -L "$knowledge_path" ]; then
    case "$knowledge_path" in
      companies/*/knowledge)
        echo "$knowledge_path: INVALID symlink (company knowledge must be a plain directory synced through the vault)"
        continue
        ;;
    esac
    target=$(cd "$knowledge_path" 2>/dev/null && pwd -P) || continue
    case "$target" in
      "$(pwd -P)"/core/packages/*) continue ;;  # package-managed mount — the only valid knowledge link
    esac
    repo_dir=$(cd "$knowledge_path" && git rev-parse --show-toplevel 2>/dev/null) || repo_dir=""
    hq_repo=$(git rev-parse --show-toplevel 2>/dev/null) || hq_repo=""
    if [ -n "$repo_dir" ] && [ "$repo_dir" != "$hq_repo" ]; then
      echo "$knowledge_path: INVALID legacy symlink to $repo_dir (migration required — run hq reindex)"
    else
      echo "$knowledge_path: NONSTANDARD symlink to $target (knowledge must be a real directory)"
    fi
    continue
  fi
  case "$knowledge_path" in
    companies/*/knowledge) continue ;;  # plain company directory; no embedded Git state
  esac
  [ -d "$knowledge_path/.git" ] || continue
  repo_dir=$(cd "$knowledge_path" && git rev-parse --show-toplevel 2>/dev/null) || continue
  dirty=$(cd "$repo_dir" && git status --porcelain)
  [ -z "$dirty" ] && continue
  echo "$knowledge_path: $(cd "$repo_dir" && git rev-parse --short HEAD) (dirty)"
done
exit 0
