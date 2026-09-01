#!/usr/bin/env bash
# Report whether an HQ installation has completed the durable parts of /setup.
#
# Usage:
#   bash core/scripts/setup-status.sh [--json] [--root <hq-root>]
#
# The check is intentionally cheap and read-only so hooks, installers, and the
# Desktop app can all use the same contract.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 2
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)" || exit 2
ROOT="$DEFAULT_ROOT"
JSON=false

usage() {
  printf 'Usage: %s [--json] [--root <hq-root>]\n' "${0##*/}" >&2
}

environment_error() {
  printf '%s\n' "$*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      JSON=true
      shift
      ;;
    --root)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      ROOT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[ -d "$ROOT" ] || environment_error "setup-status: HQ root is not a directory: $ROOT"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)" || environment_error "setup-status: cannot resolve HQ root"

command -v jq >/dev/null 2>&1 || environment_error "setup-status: jq is required"

CHECK_LINES=""
MISSING_REQUIRED=""
MISSING_OPTIONAL=""
REQUIRED_TOTAL=0
REQUIRED_DONE=0

add_check() {
  local id="$1" label="$2" tier="$3" done="$4" detail="$5"
  CHECK_LINES+="${id}"$'\t'"${label}"$'\t'"${tier}"$'\t'"${done}"$'\t'"${detail}"$'\n'

  if [ "$tier" = "required" ]; then
    REQUIRED_TOTAL=$((REQUIRED_TOTAL + 1))
    if [ "$done" = true ]; then
      REQUIRED_DONE=$((REQUIRED_DONE + 1))
    else
      MISSING_REQUIRED+="${id}"$'\n'
    fi
  elif [ "$done" != true ]; then
    MISSING_OPTIONAL+="${id}"$'\n'
  fi
}

has_content() {
  grep -q '[^[:space:]]' "$1" 2>/dev/null
}

missing_dirs=""
for dir in repos/public repos/private; do
  [ -d "$ROOT/$dir" ] || missing_dirs+="${dir}, "
done
if [ -z "$missing_dirs" ]; then
  add_check "repos-dirs" "repos/public and repos/private exist" "required" true ""
else
  add_check "repos-dirs" "repos/public and repos/private exist" "required" false "missing ${missing_dirs%, }"
fi

missing_dirs=""
for dir in personal/knowledge personal/policies personal/workers personal/settings personal/skills personal/hooks; do
  [ -d "$ROOT/$dir" ] || missing_dirs+="${dir#personal/}, "
done
if [ -z "$missing_dirs" ]; then
  add_check "personal-scaffold" "personal scaffold directories exist" "required" true ""
else
  add_check "personal-scaffold" "personal scaffold directories exist" "required" false "missing ${missing_dirs%, }"
fi

profile="$ROOT/personal/knowledge/profile.md"
if [ ! -f "$profile" ]; then
  add_check "profile" "profile is filled in" "required" false "profile.md is missing"
elif ! has_content "$profile"; then
  add_check "profile" "profile is filled in" "required" false "profile.md is empty"
elif grep -qF -e '{Answer from Q2' -e '{Answer from Q3' -e '{Name}' "$profile" 2>/dev/null; then
  add_check "profile" "profile is filled in" "required" false "profile.md still contains setup placeholders"
else
  add_check "profile" "profile is filled in" "required" true ""
fi

agents_profile="$ROOT/agents-profile.md"
if [ -f "$agents_profile" ] && head -n 1 "$agents_profile" 2>/dev/null | grep -Eq '^# .+ - Profile$'; then
  add_check "agents-profile" "agents profile has a valid heading" "required" true ""
else
  add_check "agents-profile" "agents profile has a valid heading" "required" false "agents-profile.md is missing or has an invalid heading"
fi

for required_file in \
  "systems-of-record:personal/knowledge/systems-of-record.md:systems of record exists" \
  "voice-style:personal/knowledge/voice-style.md:voice style exists" \
  "agents-companies:personal/agents-companies.md:agents companies exists" \
  "next-steps:personal/knowledge/getting-started-next-steps.md:getting started next steps exists"; do
  IFS=: read -r id path label <<<"$required_file"
  if [ ! -f "$ROOT/$path" ]; then
    add_check "$id" "$label" "required" false "${path##*/} is missing"
  elif ! has_content "$ROOT/$path"; then
    add_check "$id" "$label" "required" false "${path##*/} is empty"
  else
    add_check "$id" "$label" "required" true ""
  fi
done

missing_tools=""
for tool in hq qmd gh; do
  command -v "$tool" >/dev/null 2>&1 || missing_tools+="${tool}, "
done
if [ -z "$missing_tools" ]; then
  add_check "deps" "hq, qmd, and gh are on PATH" "optional" true ""
else
  add_check "deps" "hq, qmd, and gh are on PATH" "optional" false "missing: ${missing_tools%, }"
fi

if ! command -v hq >/dev/null 2>&1; then
  add_check "cloud-login" "HQ Cloud session is active" "optional" false "hq is not on PATH"
elif command -v timeout >/dev/null 2>&1 && timeout 0.25 hq auth status >/dev/null 2>&1; then
  add_check "cloud-login" "HQ Cloud session is active" "optional" true ""
else
  add_check "cloud-login" "HQ Cloud session is active" "optional" false "no active HQ Cloud session or status is unavailable"
fi

if [ -f "$ROOT/personal/knowledge/social-presence.md" ]; then
  add_check "social-presence" "social presence has been captured" "optional" true ""
else
  add_check "social-presence" "social presence has been captured" "optional" false "social-presence.md is missing"
fi

prior_footprint=false
if [ -f "$ROOT/companies/manifest.yaml" ] && [ -n "${HOME:-}" ]; then
  for dir in "$HOME/.claude/plans" "$HOME/.claude/commands" "$HOME/.claude/skills" \
    "$HOME/.claude/projects" "$HOME/.claude/agents" "$HOME/.codex/sessions" "$HOME/.grok/sessions"; do
    if [ -d "$dir" ] && find "$dir" -mindepth 1 -maxdepth 2 -print -quit 2>/dev/null | grep -q .; then
      prior_footprint=true
      break
    fi
  done
fi

if [ ! -f "$ROOT/companies/manifest.yaml" ]; then
  add_check "context-import" "prior AI context has been considered" "optional" true "no companies manifest; nothing to import against"
elif [ "$prior_footprint" = false ]; then
  add_check "context-import" "prior AI context has been considered" "optional" true "no prior AI footprint found"
elif [ -f "$ROOT/workspace/imports/index.json" ]; then
  add_check "context-import" "prior AI context has been considered" "optional" true "import decisions recorded"
else
  add_check "context-import" "prior AI context has been considered" "optional" false "prior AI footprint found; run /import-context to adopt it"
fi

CHECKS_JSON="$(printf '%s' "$CHECK_LINES" | jq -Rsc '
  split("\n")
  | map(select(length > 0) | split("\t") | {
      id: .[0],
      label: .[1],
      tier: .[2],
      done: (.[3] == "true"),
      detail: .[4]
    })
')" || environment_error "setup-status: could not construct check output"
MISSING_REQUIRED_JSON="$(printf '%s' "$MISSING_REQUIRED" | jq -Rsc 'split("\n") | map(select(length > 0))')" || environment_error "setup-status: could not construct required output"
MISSING_OPTIONAL_JSON="$(printf '%s' "$MISSING_OPTIONAL" | jq -Rsc 'split("\n") | map(select(length > 0))')" || environment_error "setup-status: could not construct optional output"

if [ "$REQUIRED_DONE" -eq "$REQUIRED_TOTAL" ]; then
  COMPLETE=true
  EXIT_CODE=0
else
  COMPLETE=false
  EXIT_CODE=1
fi

STATUS_JSON="$(jq -nc \
  --argjson complete "$COMPLETE" \
  --argjson requiredTotal "$REQUIRED_TOTAL" \
  --argjson requiredDone "$REQUIRED_DONE" \
  --argjson checks "$CHECKS_JSON" \
  --argjson missingRequired "$MISSING_REQUIRED_JSON" \
  --argjson missingOptional "$MISSING_OPTIONAL_JSON" \
  '{complete: $complete, requiredTotal: $requiredTotal, requiredDone: $requiredDone, checks: $checks, missingRequired: $missingRequired, missingOptional: $missingOptional}')" \
  || environment_error "setup-status: could not construct JSON output"

if [ "$JSON" = true ]; then
  printf '%s\n' "$STATUS_JSON"
else
  if [ "$COMPLETE" = true ]; then
    printf 'Setup status: complete (%s/%s required checks complete).\n' "$REQUIRED_DONE" "$REQUIRED_TOTAL"
  else
    printf 'Setup status: incomplete (%s/%s required checks complete). Missing: %s.\n' \
      "$REQUIRED_DONE" "$REQUIRED_TOTAL" "$(printf '%s' "$MISSING_REQUIRED" | paste -sd ', ' -)"
  fi
  if [ -n "$MISSING_OPTIONAL" ]; then
    printf 'Optional setup items still pending: %s.\n' "$(printf '%s' "$MISSING_OPTIONAL" | paste -sd ', ' -)"
  fi
fi

exit "$EXIT_CODE"
