#!/usr/bin/env bash
# hq-core: public
# verify-story-deliverables.sh — make `passes: true` checkable: verify the
# evidence a story worker returns, and any deliverables the PRD declared
# (2026-09-07).
#
# Why: a PRD "passes" flag recorded that a step RAN, not that work EXISTS. An
# audit found a project marked 16/17 complete whose named deliverables mostly
# did not exist anywhere. Nothing anywhere checked disk or git.
#
# Two inputs, both optional, deliberately NOT strict by default:
#   * EVIDENCE — what the worker says it produced, returned at completion in
#     the run-project / execute-task return contract (`evidence: [...]`, plus
#     `commits: [...]` which are checked as `commit:` evidence). This is the
#     primary signal: it is written at the moment of completion, so it is
#     accurate to what was built, and --write records it on the story as an
#     audit trail. A claimed-but-missing item FAILS (a fabricated claim is
#     worse than no claim). No evidence at all is allowed (legacy workers).
#   * DELIVERABLES — what the PRD declared up front (optional). Checked when
#     present; a planned-but-missing item fails, because that is exactly the
#     "16/17 complete, nothing on disk" case.
#
# Usage:
#   verify-story-deliverables.sh --prd <prd.json> --story <id> [--repo <path>]
#       [--evidence-json '<array>'] [--commits-json '<array>'] [--write] [--json] [--strict]
#
# Reference forms (evidence and deliverables share them):
#   "deliverables": [
#     "path:core/scripts/foo.sh",            # file or dir, relative to HQ root
#     "repo-path:src/lib/bar.ts",            # relative to --repo (or metadata.repoPath)
#     "branch:feature/x",                    # branch exists in --repo (local or origin)
#     "commit:<sha-prefix>",                 # commit reachable in --repo
#     "url:https://…"                        # HTTP 2xx/3xx (skipped with --offline)
#   ]
#   A bare string without a prefix is treated as "path:".
#
# Exit 0: every checked reference present. With nothing to check (no evidence,
#         no declared deliverables) this is reported as "unverified" and still
#         exits 0 — pass --strict to make that a failure.
# Exit 3: one or more references missing (each is named on stderr).
# Exit 2: usage / unreadable PRD / unknown story.
# --write: on exit 0, record the verified references on the story in prd.json as
#          `evidence: [{ref, verifiedAt}]` (only that field is touched).
set -uo pipefail

HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
PRD=""; STORY=""; REPO=""; JSON=0; STRICT=0; WRITE=0; EVIDENCE_JSON="[]"; COMMITS_JSON="[]"; OFFLINE="${HQ_DELIVERABLES_OFFLINE:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --prd) PRD="$2"; shift 2 ;;
    --story) STORY="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --evidence-json) EVIDENCE_JSON="$2"; shift 2 ;;
    --commits-json) COMMITS_JSON="$2"; shift 2 ;;
    --write) WRITE=1; shift ;;
    --json) JSON=1; shift ;;
    --strict) STRICT=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    -h|--help) sed -n 2,30p "$0"; exit 0 ;;
    *) echo "verify-story-deliverables: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$PRD" ] && [ -n "$STORY" ] || { echo "usage: --prd <prd.json> --story <id> [--repo <path>]" >&2; exit 2; }
[ -r "$PRD" ] || { echo "verify-story-deliverables: cannot read $PRD" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "verify-story-deliverables: jq required" >&2; exit 2; }

story_json="$(jq -c --arg id "$STORY" '.userStories[]? | select(.id == $id)' "$PRD" 2>/dev/null | head -1)"
[ -n "$story_json" ] || { echo "verify-story-deliverables: story $STORY not in $PRD" >&2; exit 2; }
[ -n "$REPO" ] || REPO="$(jq -r '.metadata.repoPath // empty' "$PRD" 2>/dev/null)"
case "$REPO" in ""|/*) ;; *) REPO="$HQ_ROOT/$REPO" ;; esac

jq -e 'type == "array"' <<<"$EVIDENCE_JSON" >/dev/null 2>&1 || { echo "verify-story-deliverables: --evidence-json must be a JSON array" >&2; exit 2; }
jq -e 'type == "array"' <<<"$COMMITS_JSON" >/dev/null 2>&1 || { echo "verify-story-deliverables: --commits-json must be a JSON array" >&2; exit 2; }
# Everything to check: declared deliverables + worker evidence + worker commits
# (as commit: refs), de-duplicated, in that order.
REFS_JSON="$(jq -cn --argjson d "$(printf '%s' "$story_json" | jq -c '(.deliverables // [])')" --argjson e "$EVIDENCE_JSON" --argjson c "$COMMITS_JSON" \
  '($d + $e + ($c | map("commit:" + tostring))) | map(select(type == "string" and length > 0)) | unique')"
count="$(jq -r 'length' <<<"$REFS_JSON")"
declared="$(printf '%s' "$story_json" | jq -r '(.deliverables // []) | length')"
if [ "$count" = "0" ]; then
  if [ "$STRICT" = "1" ]; then
    echo "verify-story-deliverables: $STORY has no evidence and declares no deliverables (--strict)" >&2
    [ "$JSON" = 1 ] && printf '{"story":"%s","status":"unverified","missing":[],"present":[]}\n' "$STORY"
    exit 3
  fi
  [ "$JSON" = 1 ] && printf '{"story":"%s","status":"unverified","missing":[],"present":[]}\n' "$STORY" \
    || echo "verify-story-deliverables: $STORY — nothing to verify (worker returned no evidence; PRD declares no deliverables). Allowed, but this done-mark is unverified."
  exit 0
fi

present=(); missing=()
while IFS= read -r d; do
  [ -n "$d" ] || continue
  kind="${d%%:*}"; val="${d#*:}"
  case "$d" in *:*) ;; *) kind="path"; val="$d" ;; esac
  ok=0
  case "$kind" in
    path)
      case "$val" in /*) t="$val" ;; *) t="$HQ_ROOT/$val" ;; esac
      [ -e "$t" ] && ok=1 ;;
    repo-path)
      [ -n "$REPO" ] && [ -e "$REPO/$val" ] && ok=1 ;;
    branch)
      [ -n "$REPO" ] && [ -d "$REPO" ] && {
        git -C "$REPO" show-ref --verify --quiet "refs/heads/$val" \
        || git -C "$REPO" show-ref --verify --quiet "refs/remotes/origin/$val"; } && ok=1 ;;
    commit)
      [ -n "$REPO" ] && [ -d "$REPO" ] && git -C "$REPO" cat-file -e "${val}^{commit}" 2>/dev/null && ok=1 ;;
    url)
      if [ "$OFFLINE" = "1" ]; then ok=1
      else
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -L "$val" 2>/dev/null || echo 000)"
        case "$code" in 2*|3*) ok=1 ;; esac
      fi ;;
    *) ok=0 ;;
  esac
  if [ "$ok" = 1 ]; then present+=("$d"); else missing+=("$d"); fi
done < <(jq -r '.[]' <<<"$REFS_JSON")

if [ "$JSON" = 1 ]; then
  jq -cn --arg s "$STORY" \
    --argjson m "$(printf '%s\n' "${missing[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
    --argjson p "$(printf '%s\n' "${present[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
    '{story:$s, status:(if ($m|length)==0 then "present" else "missing" end), missing:$m, present:$p}'
fi
if [ "${#missing[@]}" -gt 0 ]; then
  echo "verify-story-deliverables: $STORY is NOT verifiably complete — ${#missing[@]} of $count reference(s) do not exist:" >&2
  for d in "${missing[@]}"; do echo "  - $d" >&2; done
  echo "Do not write passes:true. A claimed path/branch/commit/URL must exist; a declared deliverable must be produced (or the declaration corrected)." >&2
  exit 3
fi
if [ "$WRITE" = 1 ]; then
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq --arg id "$STORY" --arg now "$now" --argjson refs "$(printf '%s\n' "${present[@]}" | jq -R . | jq -s 'map(select(. != ""))')" \
    '.userStories = (.userStories | map(if .id == $id then .evidence = ($refs | map({ref: ., verifiedAt: $now})) else . end))' \
    "$PRD" > "$PRD.tmp" && mv "$PRD.tmp" "$PRD"
fi
[ "$JSON" = 1 ] || echo "verify-story-deliverables: $STORY — all $count reference(s) present ($declared declared, $((count - declared)) from worker evidence)${WRITE:+; recorded on the story}"
exit 0
