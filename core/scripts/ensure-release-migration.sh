#!/usr/bin/env bash
# hq-core: public
# Ensure a release commit carries migration data before it can be tagged.

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  ensure-release-migration.sh --mode <generate|verify> --version <semver|vsemver> [--base-ref <ref>] [--repo <path>]

generate  Creates core/docs/hq/MIGRATION.md section for the release when absent.
verify    Fails when a non-trivial release diff has no consumable migration section.
USAGE
}

MODE=""
VERSION=""
BASE_REF="HEAD^"
REPO="."

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      MODE="${2:-}"; shift 2 ;;
    --version)
      VERSION="${2:-}"; shift 2 ;;
    --base-ref)
      BASE_REF="${2:-}"; shift 2 ;;
    --repo)
      REPO="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 2 ;;
  esac
done

[ "$MODE" = "generate" ] || [ "$MODE" = "verify" ] || {
  echo "ERROR: --mode must be generate or verify" >&2
  exit 2
}
[ -n "$VERSION" ] || {
  echo "ERROR: --version is required" >&2
  exit 2
}

VERSION="${VERSION#v}"
TAG="v${VERSION}"

if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$'; then
  echo "ERROR: invalid release version: ${VERSION}" >&2
  exit 2
fi

cd "$REPO"

if ! git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
  echo "ERROR: base ref not found: ${BASE_REF}" >&2
  exit 2
fi

MIGRATION_PATH="core/docs/hq/MIGRATION.md"

is_release_bookkeeping_path() {
  case "$1" in
    core/core.yaml|MIGRATION.md|core/docs/hq/MIGRATION.md|core/docs/hq/CHANGELOG.md)
      return 0 ;;
    RELEASE-NOTES-*.md|core/docs/hq/RELEASE-NOTES-*.md)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

is_migration_doc_path() {
  case "$1" in
    MIGRATION.md|core/docs/hq/MIGRATION.md)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

NEW_FILES=()
UPDATED_FILES=()
REMOVED_FILES=()
SIGNIFICANT_COUNT=0

add_path() {
  # $1 = bucket name, $2 = path
  [ -n "$2" ] || return 0
  case "$1" in
    new) NEW_FILES+=("$2") ;;
    updated) UPDATED_FILES+=("$2") ;;
    removed) REMOVED_FILES+=("$2") ;;
  esac
}

collect_diff() {
  local status path_a path_b code path
  while IFS=$'\t' read -r status path_a path_b; do
    [ -n "${status:-}" ] || continue
    code="${status:0:1}"
    case "$code" in
      A)
        path="$path_a"
        is_release_bookkeeping_path "$path" || SIGNIFICANT_COUNT=$((SIGNIFICANT_COUNT + 1))
        add_path new "$path"
        ;;
      D)
        path="$path_a"
        is_release_bookkeeping_path "$path" || SIGNIFICANT_COUNT=$((SIGNIFICANT_COUNT + 1))
        is_migration_doc_path "$path" || add_path removed "$path"
        ;;
      M|T)
        path="$path_a"
        is_release_bookkeeping_path "$path" || SIGNIFICANT_COUNT=$((SIGNIFICANT_COUNT + 1))
        add_path updated "$path"
        ;;
      R|C)
        is_release_bookkeeping_path "$path_a" || SIGNIFICANT_COUNT=$((SIGNIFICANT_COUNT + 1))
        is_release_bookkeeping_path "$path_b" || SIGNIFICANT_COUNT=$((SIGNIFICANT_COUNT + 1))
        is_migration_doc_path "$path_a" || add_path removed "$path_a"
        add_path new "$path_b"
        ;;
      *)
        path="$path_a"
        is_release_bookkeeping_path "$path" || SIGNIFICANT_COUNT=$((SIGNIFICANT_COUNT + 1))
        add_path updated "$path"
        ;;
    esac
  done < <(git diff --name-status "$BASE_REF" --)

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    is_release_bookkeeping_path "$path" || SIGNIFICANT_COUNT=$((SIGNIFICANT_COUNT + 1))
    add_path new "$path"
  done < <(git ls-files --others --exclude-standard)
}

section_has() {
  # $1 = awk condition evaluated inside the matching release section.
  local condition="$1"
  [ -f "$MIGRATION_PATH" ] || return 1
  awk -v tag="$TAG" -v condition="$condition" '
    /^## / {
      in_section = ($0 ~ "^## (Release:|Migrating to) " tag "($|[[:space:]-])")
      next
    }
    in_section {
      if (condition == "migration_steps" && $0 ~ /^### Migration Steps/) found = 1
      if (condition == "file_path" && $0 ~ /^- `[^`]+`/) found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$MIGRATION_PATH"
}

section_exists() {
  [ -f "$MIGRATION_PATH" ] || return 1
  grep -Eq "^## (Release:|Migrating to) ${TAG}($|[[:space:]-])" "$MIGRATION_PATH"
}

verify_section() {
  if [ "$SIGNIFICANT_COUNT" -eq 0 ]; then
    echo "ensure-release-migration: no non-bookkeeping release diff; migration doc not required"
    return 0
  fi
  if [ ! -f "$MIGRATION_PATH" ]; then
    echo "::error file=${MIGRATION_PATH}::${TAG} changes ${SIGNIFICANT_COUNT} non-bookkeeping path(s), but ${MIGRATION_PATH} is missing" >&2
    return 1
  fi
  if ! section_exists; then
    echo "::error file=${MIGRATION_PATH}::missing ${TAG} migration section" >&2
    return 1
  fi
  if ! section_has migration_steps; then
    echo "::error file=${MIGRATION_PATH}::${TAG} migration section must include ### Migration Steps" >&2
    return 1
  fi
  if ! section_has file_path; then
    echo "::error file=${MIGRATION_PATH}::${TAG} migration section must include backtick-wrapped file paths for /update-hq" >&2
    return 1
  fi
  echo "ensure-release-migration: ${TAG} migration section present"
}

print_path_section() {
  # $1 = heading, remaining args = paths
  local heading="$1"; shift
  printf '### %s\n\n' "$heading"
  if [ "$#" -eq 0 ]; then
    printf -- '- None.\n\n'
    return 0
  fi
  local p
  for p in "$@"; do
    printf -- '- `%s`\n' "$p"
  done
  printf '\n'
}

print_array_section() {
  # $1 = heading, $2 = array variable name
  local heading="$1"
  local array_name="$2"
  eval "local count=\${#${array_name}[@]}"
  if [ "$count" -eq 0 ]; then
    print_path_section "$heading"
    return 0
  fi
  eval "print_path_section \"\$heading\" \"\${${array_name}[@]}\""
}

generate_section() {
  mkdir -p "$(dirname "$MIGRATION_PATH")"
  local tmp body existing
  tmp="$(mktemp)"
  body="$(mktemp)"
  existing="$(mktemp)"
  trap 'rm -f "${tmp:-}" "${body:-}" "${existing:-}"' EXIT

  {
    printf '## Migrating to %s -- generated migration summary\n\n' "$TAG"
    printf 'Generated from the release diff against `%s` so `/update-hq` has concrete migration data at the target tag.\n\n' "$BASE_REF"
    print_array_section "New Files" NEW_FILES
    print_array_section "Updated Files" UPDATED_FILES
    print_array_section "Removed" REMOVED_FILES
    printf '### Breaking Changes\n\n'
    printf -- '- None declared automatically. Review hook, settings, and updater changes before merging if this release changes session startup or upgrade behavior.\n\n'
    printf '### Migration Steps\n\n'
    printf '1. Run `/update-hq` to apply this release.\n'
    printf '2. Restart Claude Code or Codex after the update if this release changes `.claude/hooks/`, `.claude/settings.json`, `.codex/`, `.agents/`, or `core/scripts/`.\n'
    printf '3. Review any local drift that `/update-hq` reports before continuing normal work.\n\n'
  } > "$body"

  if [ -f "$MIGRATION_PATH" ]; then
    awk 'NR == 1 && /^## Release: TBD/ { next } { print }' "$MIGRATION_PATH" > "$existing"
  else
    : > "$existing"
  fi

  {
    cat "$body"
    if [ -s "$existing" ]; then
      cat "$existing"
    fi
  } > "$tmp"
  mv "$tmp" "$MIGRATION_PATH"
  echo "ensure-release-migration: generated ${TAG} section in ${MIGRATION_PATH}"
}

collect_diff

if [ "$MODE" = "verify" ]; then
  verify_section
  exit $?
fi

if [ "$SIGNIFICANT_COUNT" -eq 0 ]; then
  echo "ensure-release-migration: no non-bookkeeping release diff; nothing to generate"
  exit 0
fi

if section_exists; then
  verify_section
  exit $?
fi

generate_section
verify_section
