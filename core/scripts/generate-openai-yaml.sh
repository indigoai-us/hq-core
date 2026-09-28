#!/usr/bin/env bash
#
# Generate agents/openai.yaml for Claude Code skills that lack one.
# Reads SKILL.md frontmatter (name + description) and writes a minimal
# openai.yaml so Codex can render the skill in its UI.
#
# Usage:
#   core/scripts/generate-openai-yaml.sh           # generate for all HQ-owned skills
#   core/scripts/generate-openai-yaml.sh --dry-run # preview without writing
#   core/scripts/generate-openai-yaml.sh --force   # overwrite existing openai.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SKILLS_DIR="${HQ_ROOT}/.claude/skills"

DRY_RUN=false
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force) FORCE=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if [[ ! -d "$SKILLS_DIR" ]]; then
  echo "Skills directory not found: $SKILLS_DIR" >&2
  exit 1
fi

# Convert "kebab-case-name" to "Title Case Name"
to_title_case() {
  echo "$1" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'
}

# Extract a Codex-valid description from the first sentence, bounded to 25-64
# characters and truncated only at a word boundary.
first_sentence() {
  local sentence="$1"
  local bounded=""
  local candidate
  local word
  local -a words=()

  sentence="$(printf '%s\n' "$sentence" | sed 's/\. .*/\./' | sed 's/[[:space:]]*$//')"

  if ((${#sentence} > 64)); then
    read -r -a words <<< "$sentence"
    for word in "${words[@]}"; do
      candidate="${bounded:+${bounded} }${word}"
      if ((${#candidate} > 64)); then
        break
      fi
      bounded="$candidate"
    done

    bounded="$(printf '%s\n' "$bounded" | sed 's/[[:space:],;:—-]*$//')"

    # A single unbroken token cannot fit the word-boundary limit. Use a useful
    # generic description rather than emitting an invalid or mid-word value.
    if [[ -z "$bounded" ]]; then
      bounded="See the full skill instructions."
    fi
    sentence="$bounded"
  fi

  if [[ -z "$sentence" ]]; then
    sentence="See the full skill instructions."
  elif ((${#sentence} < 25)); then
    [[ "$sentence" == *. ]] || sentence="${sentence}."
    sentence="${sentence} See the full skill instructions."
  fi

  printf '%s\n' "$sentence"
}

# Extract YAML frontmatter field from SKILL.md
extract_field() {
  local file="$1"
  local field="$2"
  # Handle multi-line description fields (folded with |)
  awk -v field="$field" '
    /^---$/ { fm++; next }
    fm == 1 && $0 ~ "^"field":" {
      sub("^"field":[ ]*", "")
      # Check for block scalar indicator
      if ($0 ~ /^\|/) { multiline=1; next }
      gsub(/^["'\''"]|["'\''"]$/, "")
      print
      exit
    }
    fm == 1 && multiline && /^  / {
      sub(/^  /, "")
      printf "%s ", $0
      next
    }
    fm == 1 && multiline && !/^  / { exit }
  ' "$file" | sed 's/ $//'
}

generated=0
skipped=0
skipped_symlink=0

for skill_dir in "${SKILLS_DIR}"/*/; do
  [ -d "$skill_dir" ] || continue

  skill_name="$(basename "$skill_dir")"
  skill_md="${skill_dir}SKILL.md"
  yaml_path="${skill_dir}agents/openai.yaml"

  # Skip symlinked skills (gstack etc.) — they're read-only
  if [ -L "$skill_dir" ] || [ -L "${skill_dir%/}" ]; then
    skipped_symlink=$((skipped_symlink + 1))
    continue
  fi

  # Skip if no SKILL.md
  if [ ! -f "$skill_md" ]; then
    continue
  fi

  # Skip if openai.yaml exists (unless --force)
  if [ -f "$yaml_path" ] && [ "$FORCE" = false ]; then
    skipped=$((skipped + 1))
    continue
  fi

  # Extract fields
  name="$(extract_field "$skill_md" "name")"
  description="$(extract_field "$skill_md" "description")"

  if [ -z "$name" ]; then
    echo "WARN: No name in ${skill_md}, skipping" >&2
    continue
  fi

  display_name="$(to_title_case "$name")"
  short_description="$(first_sentence "$description")"

  if [ "$DRY_RUN" = true ]; then
    printf '%s:\n  display_name: >-\n    %s\n  short_description: >-\n    %s\n\n' \
      "$skill_name" "$display_name" "$short_description"
  else
    mkdir -p "${skill_dir}agents"
    cat > "$yaml_path" <<EOF
interface:
  display_name: >-
    ${display_name}
  short_description: >-
    ${short_description}
EOF
    echo "Generated: ${skill_name}/agents/openai.yaml"
  fi

  generated=$((generated + 1))
done

echo
echo "Summary: ${generated} generated, ${skipped} already existed, ${skipped_symlink} symlinks skipped"
