#!/usr/bin/env bash
# Register one local PRD on the Work Mesh Board and record threadId/channelId
# on the company board.json. Audit and backfill never run unless asked.
set -euo pipefail

ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

die() {
  echo "$*" >&2
  exit 1
}

resolve_uid() {
  local company="$1"
  if [ -n "${HQ_COMPANY_UID:-}" ]; then
    printf '%s\n' "$HQ_COMPANY_UID"
    return
  fi
  local file="$ROOT/companies/$company/.company-uid"
  if [ -f "$file" ]; then
    tr -d '[:space:]' < "$file"
    return
  fi
  die "no company uid for $company (set HQ_COMPANY_UID or companies/$company/.company-uid)"
}

has_board() {
  local company="$1" project="$2" uid
  uid="$(resolve_uid "$company")"
  [ -f "${HOME}/.hq/work-mesh/cache/projects/${uid}/${project}.json" ]
}

story_not_done() {
  jq -e '[.userStories[]? | select((.status // "") != "done")] | length > 0' "$1" >/dev/null
}

recent_dir() {
  local path="$1" mtime now age
  case "$(uname -s)" in
    Darwin) mtime="$(stat -f %m "$path")" ;;
    *) mtime="$(stat -c %Y "$path")" ;;
  esac
  now="$(date +%s)"
  age=$((now - mtime))
  if [ "$age" -lt $((30 * 86400)) ]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

register_one() {
  local company="$1" project="$2"
  local prd="$ROOT/companies/$company/projects/$project/prd.json"
  [ -f "$prd" ] || die "registration incomplete: missing $prd"
  local ensure_json
  if ! ensure_json="$(hq mesh project ensure "$project" --company "$company" --stories-file "$prd" --json)"; then
    echo "registration incomplete: hq mesh project ensure failed for $company/$project" >&2
    exit 1
  fi
  local thread channel
  thread="$(printf '%s' "$ensure_json" | jq -er '.threadId // empty')" || die "registration incomplete: ensure output missing threadId"
  channel="$(printf '%s' "$ensure_json" | jq -er '.channelId // empty')" || die "registration incomplete: ensure output missing channelId"
  [ -n "$thread" ] || die "registration incomplete: empty threadId"
  [ -n "$channel" ] || die "registration incomplete: empty channelId"

  local board="$ROOT/companies/$company/board.json"
  local rel="companies/$company/projects/$project/prd.json"
  local now title tmp
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  title="$(jq -r '.name // empty' "$prd")"
  [ -n "$title" ] || title="$project"
  mkdir -p "$(dirname "$board")"
  if [ ! -f "$board" ]; then
    jq -n --arg company "$company" '{company:$company, projects:[]}' > "$board"
  fi
  tmp="$(mktemp)"
  jq \
    --arg id "$project" \
    --arg path "$rel" \
    --arg thread "$thread" \
    --arg channel "$channel" \
    --arg now "$now" \
    --arg title "$title" \
    '
      .projects = (.projects // []) |
      if any(.projects[]; .id == $id or .prd_path == $path or .mesh_project_id == $id) then
        .projects |= map(
          if .id == $id or .prd_path == $path or .mesh_project_id == $id then
            . + {threadId:$thread, channelId:$channel, updated_at:$now, prd_path:(.prd_path // $path), mesh_project_id:$id}
          else . end
        )
      else
        .projects += [{
          id:$id,
          title:$title,
          status:"prd_created",
          scope:"company",
          prd_path:$path,
          threadId:$thread,
          channelId:$channel,
          mesh_project_id:$id,
          created_at:$now,
          updated_at:$now
        }]
      end
    ' "$board" > "$tmp"
  mv "$tmp" "$board"
  jq -e \
    --arg id "$project" \
    --arg path "$rel" \
    --arg thread "$thread" \
    --arg channel "$channel" \
    'any(.projects[]?; (.id == $id or .prd_path == $path or .mesh_project_id == $id) and .threadId == $thread and .channelId == $channel)' \
    "$board" >/dev/null \
    || die "registration incomplete: board.json entry for $project did not verify"
  echo "registered $company/$project thread=$thread channel=$channel"
}

audit() {
  local company="$1"
  [ -n "$company" ] || die "usage: register-project.sh --audit <company>"
  local dir="$ROOT/companies/$company/projects"
  [ -d "$dir" ] || return 0
  local prd name
  for prd in "$dir"/*/prd.json; do
    [ -f "$prd" ] || continue
    name="$(basename "$(dirname "$prd")")"
    if ! has_board "$company" "$name"; then
      printf '%s\n' "$name"
    fi
  done | sort
}

backfill() {
  local company="" only=0 yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --only-active) only=1 ;;
      --yes) yes=1 ;;
      --*) die "unknown flag $1" ;;
      *) company="$1" ;;
    esac
    shift
  done
  [ -n "$company" ] || die "usage: register-project.sh --backfill <company> --only-active [--yes]"
  [ "$only" -eq 1 ] || die "--backfill requires --only-active"
  local dir="$ROOT/companies/$company/projects"
  [ -d "$dir" ] || return 0
  local prd name recent
  local -a targets=()
  for prd in "$dir"/*/prd.json; do
    [ -f "$prd" ] || continue
    name="$(basename "$(dirname "$prd")")"
    story_not_done "$prd" || continue
    recent="$(recent_dir "$(dirname "$prd")")"
    [ "$recent" = "yes" ] || continue
    targets+=("$name")
  done
  IFS=$'\n' targets=($(printf '%s\n' "${targets[@]+"${targets[@]}"}" | sed '/^$/d' | sort))
  unset IFS
  if [ "$yes" -ne 1 ]; then
    local item
    for item in "${targets[@]+"${targets[@]}"}"; do
      echo "would register $company/$item"
    done
    return 0
  fi
  local item
  for item in "${targets[@]+"${targets[@]}"}"; do
    register_one "$company" "$item"
  done
}

if [ "${1:-}" = "--audit" ]; then
  audit "${2:-}"
elif [ "${1:-}" = "--backfill" ]; then
  shift
  backfill "$@"
elif [ $# -eq 2 ]; then
  register_one "$1" "$2"
else
  die "usage: register-project.sh <company> <project> | --audit <company> | --backfill <company> --only-active [--yes]"
fi
