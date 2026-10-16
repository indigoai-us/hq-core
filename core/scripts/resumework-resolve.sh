#!/usr/bin/env bash
# hq-core: public
# resumework-resolve.sh — resolve a /resumework thread id (full id, prefix or
# slug) to candidate handoff thread files, newest first, as JSON.
#
# Usage:
#   bash core/scripts/resumework-resolve.sh <thread-id-or-slug> [--no-vault]
#
# Search order (all matches are collected, then de-duplicated by thread_id):
#   1. workspace/threads/<id>.json (exact), then T-*.json whose name contains
#      <id>, in workspace/threads/ and workspace/threads/archive/**.
#   2. The session's BOUND company only: companies/<co>/workspace/sessions/,
#      where mirror-thread-to-company writes each company handoff. A handoff
#      written on another device can arrive here through the company vault
#      while workspace/threads/ never sees it (feedback_050aaf1f).
#   3. Only when 1 and 2 found nothing and a company is bound: `hq files search`
#      in that company's vault, then `hq files get` for each matching
#      workspace/sessions thread (at most 5), which materializes it in place.
#      Skipped with --no-vault, HQ_RESUMEWORK_VAULT=0, or when hq is missing.
# Other companies are never searched.
#
# Output (stdout, one JSON object):
#   {"query":..., "company":..., "vault":{"searched":bool,"fetched":[...],"error":...},
#    "matches":[{"thread_id","path","source","created_at","session_id","title",
#                "summary","branch","open_steps","same_as_newer"}]}
# matches are newest first. same_as_newer is true when a newer match has the
# same title and summary: repeated handoffs of one session (feedback_b75f1436).
# Pick one by its full thread_id; never guess.
#
# Test seams: HQ_ROOT (default: repo root of this script), HQ_BIN (default hq),
# HQ_RESUMEWORK_COMPANY (overrides the bound-company lookup).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
HQ_BIN="${HQ_BIN:-hq}"

ARG=""; USE_VAULT=1
[ "${HQ_RESUMEWORK_VAULT:-1}" = "0" ] && USE_VAULT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-vault) USE_VAULT=0; shift ;;
    -h|--help) sed -n '3,30p' "$0"; exit 0 ;;
    *) [ -z "$ARG" ] && ARG="$1"; shift ;;
  esac
done

id="${ARG%.json}"; id="${id##*/}"
id="$(printf '%s' "$id" | tr -d '[:space:]')"
if [ -z "$id" ]; then
  echo "resumework-resolve: a thread id is required" >&2
  exit 2
fi
case "$id" in
  *[!A-Za-z0-9._-]*) echo "resumework-resolve: invalid thread id: $id" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "resumework-resolve: jq is required" >&2; exit 2; }

# --- bound company (only this one is searched) --------------------------------
CO="${HQ_RESUMEWORK_COMPANY-}"
if [ -z "${HQ_RESUMEWORK_COMPANY+x}" ] && [ -f "$ROOT/core/scripts/hq-session.sh" ]; then
  CO="$(cd "$ROOT" && bash core/scripts/hq-session.sh get company_slug 2>/dev/null | head -1 | tr -d '[:space:]"' || true)"
fi
case "$CO" in
  personal|none|null) CO="" ;;
esac
if [ -n "$CO" ] && ! printf '%s' "$CO" | grep -Eq '^[a-z0-9][a-z0-9_-]*$'; then CO=""; fi
[ -n "$CO" ] && [ ! -d "$ROOT/companies/$CO" ] && CO=""

LIST="$(mktemp "${TMPDIR:-/tmp}/resumework-resolve.XXXXXX")"
trap 'rm -f "$LIST"' EXIT

# collect <source> <dir> <maxdepth>
collect() {
  local source="$1" dir="$2" depth="$3" f
  [ -d "$dir" ] || return 0
  if [ -f "$dir/${id}.json" ]; then
    printf '%s\t%s\n' "$source" "$dir/${id}.json" >> "$LIST"
  fi
  while IFS= read -r f; do
    [ -n "$f" ] && printf '%s\t%s\n' "$source" "$f" >> "$LIST"
  done < <(find "$dir" -maxdepth "$depth" -path '*/resume-locks' -prune -o \
             -type f -name "T-*${id}*.json" ! -name '*.changeset.json' -print 2>/dev/null)
}

collect local "$ROOT/workspace/threads" 1
collect archive "$ROOT/workspace/threads/archive" 6
[ -n "$CO" ] && collect company "$ROOT/companies/$CO/workspace/sessions" 1

VAULT_SEARCHED=false; VAULT_ERROR=""; FETCHED=()
if [ ! -s "$LIST" ] && [ "$USE_VAULT" = 1 ] && [ -n "$CO" ]; then
  if command -v "$HQ_BIN" >/dev/null 2>&1; then
    VAULT_SEARCHED=true
    if out="$(cd "$ROOT" && "$HQ_BIN" files search "$id" --company "$CO" 2>&1)"; then
      keys="$(printf '%s\n' "$out" | grep -oE "companies/$CO/workspace/sessions/T-[A-Za-z0-9._-]*\\.json" \
        | grep -v '\.changeset\.json$' | grep -F -- "$id" | sort -u | head -5 || true)"
      while IFS= read -r key; do
        [ -n "$key" ] || continue
        if (cd "$ROOT" && "$HQ_BIN" files get "$key" --company "$CO" >/dev/null 2>&1) && [ -f "$ROOT/$key" ]; then
          FETCHED+=("$key")
        else
          VAULT_ERROR="hq files get failed for $key"
        fi
      done <<<"$keys"
      collect vault "$ROOT/companies/$CO/workspace/sessions" 1
    else
      VAULT_ERROR="hq files search failed: $(printf '%s' "$out" | tail -1 | cut -c1-200)"
    fi
  else
    VAULT_ERROR="hq CLI not found; vault search skipped"
  fi
fi

FETCHED_JSON="$(printf '%s\n' ${FETCHED[@]+"${FETCHED[@]}"} | jq -R . | jq -sc 'map(select(length > 0))')"

# One record per file, then de-duplicate by thread_id (workspace/threads wins).
records="$(
  sort -u "$LIST" | while IFS=$'\t' read -r source path; do
    [ -f "$path" ] || continue
    rel="${path#"$ROOT"/}"
    jq -c --arg source "$source" --arg path "$rel" --arg fallback "$(basename "$path" .json)" '
      {
        thread_id: (.thread_id // $fallback),
        path: $path,
        source: $source,
        created_at: (.created_at // .updated_at // null),
        session_id: (.session_id // null),
        title: (.metadata.title // null),
        summary: ((.conversation_summary // "") | tostring | .[0:160]),
        branch: (.git.branch // null),
        open_steps: ([(.next_steps // [])[]? | select((type == "object" and ((.status // "open") == "open")) or type == "string")] | length)
      }' "$path" 2>/dev/null || true
  done
)"

printf '%s\n' "$records" | jq -sc \
  --arg query "$id" --arg company "$CO" \
  --argjson searched "$VAULT_SEARCHED" --arg verr "$VAULT_ERROR" --argjson fetched "$FETCHED_JSON" '
  def rank: {"local":0,"archive":1,"company":2,"vault":3}[.source] // 9;
  def stamp: (.created_at // "") + "|" + .thread_id;
  map(select(type == "object"))
  | group_by(.thread_id) | map(sort_by(rank) | .[0])
  | sort_by(stamp) | reverse
  | . as $all
  | [ range(0; length) as $i
      | $all[$i] + { same_as_newer: (
          $all[$i].title != null and
          ([ $all[0:$i][] | select(.title == $all[$i].title and .summary == $all[$i].summary) ] | length > 0)) } ]
  | { query: $query,
      company: (if $company == "" then null else $company end),
      vault: { searched: $searched, fetched: $fetched, error: (if $verr == "" then null else $verr end) },
      matches: . }'
