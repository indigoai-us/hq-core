#!/usr/bin/env bash
# qmd-reindex-after-sync.sh — incremental qmd reindex after an HQ sync.
#
# Why this exists: the qmd index is a per-machine local SQLite store derived
# from local folder paths. Nothing re-indexed it after `hq-sync` pulled new
# files in, so search results diverged between teammates depending on who ran
# `qmd update` most recently. This script makes post-sync indexing automatic
# and deterministic, so every machine's personal index converges to the same
# content. The index itself stays personal (it is large, binary, and embeds
# absolute local paths); only the *freshness* is made automatic.
#
# Behavior:
#   1. Auto-registers any company knowledge dir that isn't yet a qmd
#      collection (fixes the "newly-synced knowledge isn't searchable until I
#      manually map it" gap).
#   2. Runs an incremental lexical reindex (`qmd update` — fast, skips
#      unchanged files by mtime).
#   3. Rebuilds embeddings only when called with --embed (slow on a
#      multi-GB index; meant for an idle/interval pass, not every sync).
#
# Idempotent and safe: no-op (exit 0) when qmd is absent or the path isn't an
# HQ root. Never blocks or fails a sync.
#
# Usage: qmd-reindex-after-sync.sh [hq_root] [--embed]
#   hq_root  Local HQ directory (default: $PWD). Must contain core/core.yaml.
#   --embed  Also rebuild embeddings (deferred-cost; omit for fast lexical-only).

set -uo pipefail

hq_root=""
embed=0
for arg in "$@"; do
  case "$arg" in
    --embed) embed=1 ;;
    --*)     : ;;                       # ignore unknown flags
    *)       [ -z "$hq_root" ] && hq_root="$arg" ;;
  esac
done
[ -z "$hq_root" ] && hq_root="$PWD"

command -v qmd >/dev/null 2>&1 || exit 0
[ -f "$hq_root/core/core.yaml" ] || exit 0

cd "$hq_root" || exit 0

# 1. Auto-register company knowledge collections that don't exist yet.
#    Convention matches /newcompany: --name <slug> --mask "**/*.md".
existing="$(qmd collection list 2>/dev/null || true)"
for kdir in companies/*/knowledge; do
  [ -d "$kdir" ] || continue
  find "$kdir" -name '*.md' -not -name 'INDEX.md' 2>/dev/null | head -1 | grep -q . || continue
  slug="$(basename "$(dirname "$kdir")")"
  printf '%s\n' "$existing" | grep -Fq "qmd://$slug/" && continue
  qmd collection add "$hq_root/$kdir" --name "$slug" --mask "**/*.md" >/dev/null 2>&1 || true
  qmd context add "qmd://$slug" "Knowledge base for $slug." >/dev/null 2>&1 || true
done

# 1b. Auto-register company *projects* collections that don't exist yet.
#    Convention matches the HQ-level `hq-projects` collection: --name <slug>-projects
#    --mask "**/*.{md,json}" (so prd.json + project docs are searchable). Without
#    this, company projects/ dirs are indexed by nothing and /startwork's global
#    `qmd search "prd.json"` and /brainstorm's project discovery silently miss them.
for pdir in companies/*/projects; do
  [ -d "$pdir" ] || continue
  find "$pdir" -type f \( -name '*.md' -o -name '*.json' \) 2>/dev/null | head -1 | grep -q . || continue
  slug="$(basename "$(dirname "$pdir")")"
  name="${slug}-projects"
  printf '%s\n' "$existing" | grep -Fq "qmd://$name/" && continue
  qmd collection add "$hq_root/$pdir" --name "$name" --mask "**/*.{md,json}" >/dev/null 2>&1 || true
  qmd context add "qmd://$name" "Project PRDs and documentation for $slug." >/dev/null 2>&1 || true
done

# 2. Incremental lexical reindex (cheap; mtime-incremental inside qmd).
qmd update >/dev/null 2>&1 || true

# 3. Embeddings only on explicit request.
if [ "$embed" -eq 1 ]; then
  qmd embed >/dev/null 2>&1 || true
fi

exit 0
