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
  if [ -f "$ROOT/companies/manifest.yaml" ]; then
    local manifest_uid
    manifest_uid="$(awk -v company="$company" '
      /^companies:[[:space:]]*$/ { in_companies=1; next }
      in_companies && /^[^[:space:]]/ { in_companies=0 }
      in_companies && /^  [^ #][^:]*:/ {
        slug=$1; sub(/[[:space:]]+$/, "", slug); sub(/:$/, "", slug); in_company=(slug == company); next
      }
      in_company && /^  [^[:space:]#]/ { exit }
      in_company && $1 == "cloud_uid:" { gsub(/["\047]/, "", $2); sub(/[[:space:]]+$/, "", $2); print $2; exit }
    ' "$ROOT/companies/manifest.yaml")"
    if [ -n "$manifest_uid" ]; then
      printf '%s\n' "$manifest_uid"
      return
    fi
  fi
  die "no company uid for $company (set HQ_COMPANY_UID, companies/$company/.company-uid, or manifest cloud_uid)"
}

mesh_project_id_for_prd() {
  local company="$1" project="$2" board rel resolved
  board="$(board_path "$company")"
  rel="companies/$company/projects/$project/prd.json"
  resolved=""
  if [ -f "$board" ]; then
    resolved="$(jq -r --arg path "$rel" --arg project "$project" '
      [.projects[]? | select(.prd_path == $path or .id == $project)] | first | (.mesh_project_id // .id // empty)
    ' "$board" 2>/dev/null | tr -d '\r' || true)"
  fi
  printf '%s\n' "${resolved:-$project}"
}

has_board() {
  local company="$1" project="$2" uid mesh_project
  uid="$(resolve_uid "$company")"
  mesh_project="$(mesh_project_id_for_prd "$company" "$project")"
  [ -f "${HOME}/.hq/work-mesh/cache/projects/${uid}/${mesh_project}.json" ] \
    || [ -f "${HOME}/.hq/work-mesh/cache/projects/${uid}/${project}.json" ]
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

# hq mesh project ensure shipped in hq-cli 5.139.0. Probe the subcommand,
# not the version string: a laptop can be one release behind the supply-chain
# install guard for up to 24h.
MIN_HQ_CLI="5.139.0"

cli_has_project_ensure() {
  hq mesh project ensure --help >/dev/null 2>&1
}

board_path() {
  printf '%s\n' "$ROOT/companies/$1/board.json"
}

mark_pending() {
  local company="$1" project="$2"
  local board prd rel now title tmp
  board="$(board_path "$company")"
  prd="$ROOT/companies/$company/projects/$project/prd.json"
  rel="companies/$company/projects/$project/prd.json"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  title="$(jq -r '.name // empty' "$prd" 2>/dev/null | tr -d '\r' || true)"
  [ -n "$title" ] || title="$project"
  mkdir -p "$(dirname "$board")"
  if [ ! -f "$board" ]; then
    jq -n --arg company "$company" '{company:$company, projects:[]}' | tr -d '\r' > "$board"
  fi
  tmp="$(mktemp)"
  jq \
    --arg id "$project" \
    --arg path "$rel" \
    --arg now "$now" \
    --arg title "$title" \
    '
      .projects = (.projects // []) |
      if any(.projects[]; .id == $id or .prd_path == $path or .mesh_project_id == $id) then
        .projects |= map(
          if .id == $id or .prd_path == $path or .mesh_project_id == $id then
            . + {pending_registration:true, updated_at:$now, prd_path:(.prd_path // $path)}
          else . end
        )
      else
        .projects += [{
          id:$id,
          title:$title,
          status:"prd_created",
          scope:"company",
          prd_path:$path,
          pending_registration:true,
          created_at:$now,
          updated_at:$now
        }]
      end
    ' "$board" | tr -d '\r' > "$tmp"
  mv "$tmp" "$board"
}

register_one() {
  local company="$1" project="$2"
  local prd="$ROOT/companies/$company/projects/$project/prd.json"
  local mesh_project
  mesh_project="$(mesh_project_id_for_prd "$company" "$project")"
  [ -f "$prd" ] || die "registration incomplete: missing $prd"
  if ! cli_has_project_ensure; then
    mark_pending "$company" "$project"
    die "hq-cli ${MIN_HQ_CLI} or newer is required; ${company}/${project} stays local until then"
  fi
  local ensure_json
  if ! ensure_json="$(hq mesh project ensure "$mesh_project" --company "$company" --stories-file "$prd" --json)"; then
    echo "registration incomplete: hq mesh project ensure failed for $company/$project" >&2
    exit 1
  fi
  local thread channel
  thread="$(printf '%s' "$ensure_json" | jq -er '.threadId // empty' | tr -d '\r')" || die "registration incomplete: ensure output missing threadId"
  channel="$(printf '%s' "$ensure_json" | jq -er '.channelId // empty' | tr -d '\r')" || die "registration incomplete: ensure output missing channelId"
  [ -n "$thread" ] || die "registration incomplete: empty threadId"
  [ -n "$channel" ] || die "registration incomplete: empty channelId"

  local board="$ROOT/companies/$company/board.json"
  local rel="companies/$company/projects/$project/prd.json"
  local now title tmp
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  title="$(jq -r '.name // empty' "$prd" | tr -d '\r')"
  [ -n "$title" ] || title="$project"
  mkdir -p "$(dirname "$board")"
  if [ ! -f "$board" ]; then
    jq -n --arg company "$company" '{company:$company, projects:[]}' | tr -d '\r' > "$board"
  fi
  tmp="$(mktemp)"
  jq \
    --arg id "$mesh_project" \
    --arg project "$project" \
    --arg path "$rel" \
    --arg thread "$thread" \
    --arg channel "$channel" \
    --arg now "$now" \
    --arg title "$title" \
    '
      .projects = (.projects // []) |
      if any(.projects[]; .id == $id or .id == $project or .prd_path == $path or .mesh_project_id == $id) then
        .projects |= map(
          if .id == $id or .id == $project or .prd_path == $path or .mesh_project_id == $id then
            . + {threadId:$thread, channelId:$channel, updated_at:$now, prd_path:(.prd_path // $path), mesh_project_id:$id} | del(.pending_registration)
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
    ' "$board" | tr -d '\r' > "$tmp"
  mv "$tmp" "$board"
  jq -e \
    --arg id "$project" \
    --arg path "$rel" \
    --arg mesh "$mesh_project" \
    --arg thread "$thread" \
    --arg channel "$channel" \
    'any(.projects[]?; (.id == $id or .prd_path == $path or .mesh_project_id == $mesh) and .mesh_project_id == $mesh and .threadId == $thread and .channelId == $channel)' \
    "$board" >/dev/null \
    || die "registration incomplete: board.json entry for $project did not verify"
  echo "registered $company/$project thread=$thread channel=$channel"
}

register_brainstorm() {
  local company="$1" project="$2" board title description ensure_json thread channel tmp
  resolve_uid "$company" >/dev/null
  board="$(board_path "$company")"
  [ -f "$board" ] || die "registration incomplete: missing $board"
  title="$(jq -r --arg id "$project" '[.projects[]? | select(.id == $id or .mesh_project_id == $id)] | first | .title // empty' "$board" | tr -d '\r')"
  description="$(jq -r --arg id "$project" '[.projects[]? | select(.id == $id or .mesh_project_id == $id)] | first | .description // empty' "$board" | tr -d '\r')"
  [ -n "$title" ] || die "registration incomplete: missing local Board project $company/$project"
  if ! ensure_json="$(hq mesh project set "$project" --company "$company" --name "$title" --description "$description" --create --json)"; then
    die "registration incomplete: hq mesh project set failed for $company/$project"
  fi
  thread="$(printf '%s' "$ensure_json" | jq -er '.registration.threadId // .threadId // empty' | tr -d '\r')" \
    || die "registration incomplete: project set output missing threadId"
  channel="$(printf '%s' "$ensure_json" | jq -er '.registration.channelId // .channelId // empty' | tr -d '\r')" \
    || die "registration incomplete: project set output missing channelId"
  [ -n "$thread" ] && [ -n "$channel" ] || die "registration incomplete: empty threadId or channelId"
  tmp="$(mktemp)"
  jq --arg id "$project" --arg thread "$thread" --arg channel "$channel" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .projects |= map(if .id == $id or .mesh_project_id == $id then . + {
      threadId:$thread, channelId:$channel, mesh_project_id:$id,
      mesh_registration_prompt_state:"accepted", updated_at:$now
    } | del(.pending_registration) else . end)
  ' "$board" > "$tmp"
  mv "$tmp" "$board"
  jq -e --arg id "$project" --arg thread "$thread" --arg channel "$channel" \
    'any(.projects[]?; (.id == $id or .mesh_project_id == $id) and .threadId == $thread and .channelId == $channel)' \
    "$board" >/dev/null || die "registration incomplete: local Board registration did not verify"
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

retry_pending() {
  local company="${1:-}"
  [ -n "$company" ] || die "usage: register-project.sh --retry-pending <company>"
  cli_has_project_ensure || return 0
  local board
  board="$(board_path "$company")"
  [ -f "$board" ] || return 0
  local id count=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    count=$((count + 1))
    [ "$count" -le 3 ] || break
    ( register_one "$company" "$id" ) || true
  done < <(jq -r '[.projects[]? | select(.pending_registration == true) | .id // empty] | .[]' "$board" 2>/dev/null | tr -d '\r' || true)
}

if [ "${1:-}" = "--brainstorm" ]; then
  [ "$#" -eq 3 ] || die "usage: register-project.sh --brainstorm <company> <board-project-id>"
  register_brainstorm "$2" "$3"
elif [ "${1:-}" = "--audit" ]; then
  audit "${2:-}"
elif [ "${1:-}" = "--backfill" ]; then
  shift
  backfill "$@"
elif [ "${1:-}" = "--retry-pending" ]; then
  retry_pending "${2:-}"
elif [ $# -eq 2 ]; then
  register_one "$1" "$2"
else
  die "usage: register-project.sh <company> <project> | --brainstorm <company> <board-project-id> | --audit <company> | --backfill <company> --only-active [--yes] | --retry-pending <company>"
fi
