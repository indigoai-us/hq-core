#!/usr/bin/env bash
# qmd-ready.sh — is semantic qmd (vsearch / query / embed) safe to run WITHOUT
# triggering a model download?
#
# WHY: qmd's semantic commands lazily download GGUF models on first use — a
# ~1.3GB query-expansion model plus embedding + reranker models. On a fresh or
# constrained machine that download blocks the session (verified new-user
# report: a ~1.28GB pull mid-/learn dedup). Skills therefore gate every
# `qmd vsearch` / `qmd query` behind this script and drop to BM25 while the
# models aren't cached yet:
#
#   bash core/scripts/qmd-ready.sh && qmd query "..." --json || qmd search "..." --json
#
# Semantic search ladder: vsearch/query (models cached) → qmd search (BM25) → Grep.
#
# CONTRACT:
#   exit 0 — qmd is installed AND all semantic models are already cached locally
#   exit 1 — not ready (qmd missing, or ≥1 model absent → a semantic call would
#            block on a download)
#   exit 2 — usage error
#
# Pure filesystem checks (<100ms). NEVER invokes qmd itself — a qmd invocation
# could be the very thing that starts the download.
#
# Model cache locations (union — a model may live in any of them):
#   $QMD_READY_MODEL_DIRS          colon-separated override (tests / CI)
#   $XDG_CACHE_HOME/qmd/models     or ~/.cache/qmd/models (Linux/WSL, qmd default)
#   ~/Library/Caches/qmd/models    (macOS-native cache)
#   $LOCALAPPDATA/qmd/models      (Windows, when set)
#
# Usage: qmd-ready.sh [--explain]
#   --explain   print why (not) ready to stdout; silent otherwise.

set -euo pipefail

EXPLAIN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --explain) EXPLAIN=1; shift ;;
    -h|--help)
      echo "usage: qmd-ready.sh [--explain]"
      echo "exit 0 iff qmd is installed and its semantic models are cached locally."
      exit 0 ;;
    *)
      echo "qmd-ready: unknown argument '$1' (usage: qmd-ready.sh [--explain])" >&2
      exit 2 ;;
  esac
done

say() { if [[ "$EXPLAIN" == "1" ]]; then printf '%s\n' "$*"; fi; }

if ! command -v qmd >/dev/null 2>&1; then
  say "not ready: qmd is not installed — use Grep (bottom rung of the search ladder)"
  exit 1
fi

# Candidate model directories, newline-separated (bash-3.2-safe: no arrays).
candidate_dirs() {
  if [[ -n "${QMD_READY_MODEL_DIRS:-}" ]]; then
    printf '%s\n' "$QMD_READY_MODEL_DIRS" | tr ':' '\n'
    return 0
  fi
  printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/qmd/models"
  printf '%s\n' "$HOME/Library/Caches/qmd/models"
  if [[ -n "${LOCALAPPDATA:-}" ]]; then
    printf '%s\n' "$LOCALAPPDATA/qmd/models"
  fi
}

# Role detection by GGUF filename across all candidate dirs. Filenames vary by
# qmd version/cache (e.g. "hf_ggml-org_embeddinggemma-300M-Q8_0.gguf" vs
# "embeddinggemma-300M-Q8_0.gguf"), so match on the stable role substrings.
HAVE_EMBED=0
HAVE_EXPAND=0
HAVE_RERANK=0
DIRS_CHECKED=""

while IFS= read -r dir; do
  [[ -n "$dir" && -d "$dir" ]] || continue
  DIRS_CHECKED="${DIRS_CHECKED}${DIRS_CHECKED:+, }${dir}"
  for f in "$dir"/*.gguf; do
    [[ -e "$f" ]] || continue
    name="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
    case "$name" in *embed*)  HAVE_EMBED=1  ;; esac
    case "$name" in *expan*)  HAVE_EXPAND=1 ;; esac
    case "$name" in *rerank*) HAVE_RERANK=1 ;; esac
  done
done < <(candidate_dirs)

MISSING=""
[[ "$HAVE_EMBED"  == 1 ]] || MISSING="${MISSING}${MISSING:+, }embedding"
[[ "$HAVE_EXPAND" == 1 ]] || MISSING="${MISSING}${MISSING:+, }query-expansion (~1.3GB)"
[[ "$HAVE_RERANK" == 1 ]] || MISSING="${MISSING}${MISSING:+, }reranker"

if [[ -z "$MISSING" ]]; then
  say "ready: qmd installed and semantic models cached (${DIRS_CHECKED})"
  exit 0
fi

say "not ready: qmd is installed but model(s) not cached yet: ${MISSING}"
if [[ -n "$DIRS_CHECKED" ]]; then
  say "checked: ${DIRS_CHECKED}"
else
  say "checked: no qmd model directory exists yet"
fi
say "running 'qmd vsearch/query/embed' now would BLOCK on a model download."
say "use 'qmd search' (BM25, no model) instead, or warm up once with: qmd embed"
exit 1
