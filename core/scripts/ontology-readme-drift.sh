#!/usr/bin/env bash
# hq-core: public
# Detect README team-table names that no longer match ontology person entities.
set -euo pipefail

usage() {
  echo "USAGE: ontology-readme-drift.sh <company-slug> [--root <HQ_ROOT>]" >&2
}

SLUG=""
ROOT_ARG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      if [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      ROOT_ARG="$2"
      shift 2
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      if [ -n "$SLUG" ]; then
        usage
        exit 2
      fi
      SLUG="$1"
      shift
      ;;
  esac
done

if [ -z "$SLUG" ]; then
  usage
  exit 2
fi

if [ -n "$ROOT_ARG" ]; then
  ROOT="$ROOT_ARG"
elif [ -n "${HQ_ROOT:-}" ]; then
  ROOT="$HQ_ROOT"
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  ROOT="$CLAUDE_PROJECT_DIR"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

README="$ROOT/companies/$SLUG/README.md"
PERSONS_DIR="$ROOT/companies/$SLUG/ontology/entities/person"

if [ ! -f "$README" ]; then
  echo "ERROR: README missing: companies/$SLUG/README.md" >&2
  exit 2
fi

if [ ! -d "$PERSONS_DIR" ]; then
  echo "ERROR: ontology person directory missing: companies/$SLUG/ontology/entities/person" >&2
  exit 2
fi

has_person_file=0
for person_file in "$PERSONS_DIR"/*.md; do
  [ -f "$person_file" ] || continue
  has_person_file=1
  break
done

if [ "$has_person_file" -eq 0 ]; then
  echo "ERROR: ontology person directory is empty: companies/$SLUG/ontology/entities/person" >&2
  exit 2
fi

trim_name_awk='
function trim(s) {
  sub(/^[[:space:]]+/, "", s)
  sub(/[[:space:]]+$/, "", s)
  return s
}
'

extract_team_names() {
  # Parse only the first markdown table after ## Team; column 2 is Name.
  awk "$trim_name_awk"'
    /^##[[:space:]]+Team[[:space:]]*$/ {
      in_team = 1
      next
    }
    in_team && /^##[[:space:]]+/ {
      exit
    }
    in_team {
      if ($0 ~ /^[[:space:]]*\|/) {
        in_table = 1
        row += 1
        if (row <= 2) {
          next
        }
        line = $0
        sub(/^[[:space:]]*/, "", line)
        split(line, cols, /\|/)
        name = cols[3]
        gsub(/<!--[^>]*-->/, "", name)
        name = trim(name)
        if (name != "") {
          print name
        }
        next
      }
      if (in_table) {
        exit
      }
    }
  ' "$README"
}

extract_person_names() {
  # Read canonical_name and aliases from YAML frontmatter only.
  awk "$trim_name_awk"'
    function unquote(s) {
      s = trim(s)
      if ((s ~ /^".*"$/) || (s ~ /^'\''.*'\''$/)) {
        s = substr(s, 2, length(s) - 2)
      }
      return s
    }
    /^---[[:space:]]*$/ {
      markers += 1
      if (markers == 1) {
        in_frontmatter = 1
        next
      }
      if (markers == 2) {
        exit
      }
    }
    !in_frontmatter {
      next
    }
    /^[[:space:]]*aliases:[[:space:]]*$/ {
      in_aliases = 1
      next
    }
    in_aliases && /^[[:space:]]*-[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      line = unquote(line)
      if (line != "") {
        print line
      }
      next
    }
    in_aliases && $0 !~ /^[[:space:]]*($|#)/ {
      in_aliases = 0
    }
    /^[[:space:]]*canonical_name[[:space:]]*:/ {
      line = $0
      sub(/^[[:space:]]*canonical_name[[:space:]]*:[[:space:]]*/, "", line)
      line = unquote(line)
      if (line != "") {
        print line
      }
      next
    }
  ' "$1"
}

normalize_name() {
  LC_ALL=C awk -v s="$1" 'BEGIN {
    s = tolower(s)
    gsub(/[^[:alnum:][:space:]]/, "", s)
    gsub(/[[:space:]]+/, " ", s)
    sub(/^ /, "", s)
    sub(/ $/, "", s)
    print s
  }'
}

contains_token() {
  token="$1"
  shift
  for candidate in "$@"; do
    if [ "$candidate" = "$token" ]; then
      return 0
    fi
  done
  return 1
}

name_matches() {
  readme_norm="$1"
  ontology_norm="$2"

  if [ "$readme_norm" = "$ontology_norm" ]; then
    return 0
  fi
  if [ -z "$readme_norm" ] || [ -z "$ontology_norm" ]; then
    return 1
  fi

  IFS=' ' read -r -a readme_tokens <<< "$readme_norm"
  IFS=' ' read -r -a ontology_tokens <<< "$ontology_norm"

  if [ "${#readme_tokens[@]}" -lt "${#ontology_tokens[@]}" ] ||
    { [ "${#readme_tokens[@]}" -eq "${#ontology_tokens[@]}" ] && [ "${#readme_norm}" -le "${#ontology_norm}" ]; }; then
    for token in "${readme_tokens[@]}"; do
      contains_token "$token" "${ontology_tokens[@]}" || return 1
    done
  else
    for token in "${ontology_tokens[@]}"; do
      contains_token "$token" "${readme_tokens[@]}" || return 1
    done
  fi

  return 0
}

ontology_names=()
for person_file in "$PERSONS_DIR"/*.md; do
  [ -f "$person_file" ] || continue
  while IFS= read -r person_name; do
    person_norm="$(normalize_name "$person_name")"
    [ -n "$person_norm" ] || continue
    ontology_names+=("$person_norm")
  done < <(extract_person_names "$person_file")
done

if [ "${#ontology_names[@]}" -eq 0 ]; then
  echo "ERROR: ontology person directory has no canonical_name or aliases to compare: companies/$SLUG/ontology/entities/person" >&2
  exit 2
fi

drift_count=0
while IFS= read -r team_name; do
  team_norm="$(normalize_name "$team_name")"
  [ -n "$team_norm" ] || continue

  matched=0
  for ontology_name in "${ontology_names[@]}"; do
    if name_matches "$team_norm" "$ontology_name"; then
      matched=1
      break
    fi
  done

  if [ "$matched" -eq 0 ]; then
    echo "DRIFT: \"$team_name\" in companies/$SLUG README team table has no matching active ontology person entity (possibly departed or misspelled)"
    drift_count=$((drift_count + 1))
  fi
done < <(extract_team_names)

if [ "$drift_count" -eq 0 ]; then
  echo "ontology-readme-drift($SLUG): no drift"
fi
echo "ontology-readme-drift($SLUG): $drift_count drift(s)"

if [ "$drift_count" -gt 0 ]; then
  exit 1
fi
