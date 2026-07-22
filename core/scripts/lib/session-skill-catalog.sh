#!/usr/bin/env bash
# hq-core: public
# session-skill-catalog.sh — bounded company-scoped skill catalog for system.txt.
#
# Enumerates SKILL.md frontmatter (name + description) from:
#   1. companies/<companySlug>/skills/*/SKILL.md   (wins on name collision)
#   2. .claude/skills/*/SKILL.md
#   3. core/packages/*/skills/*/SKILL.md
#
# Cross-company skills are never listed. Catalog is name + one-line description
# only (never full bodies). Bounded by HQ_SESSION_SKILL_CATALOG_MAX_BYTES
# (default 32768). Exports:
#   SESSION_SKILLS_AVAILABLE
#   SESSION_SKILL_CATALOG_TSV   — name<TAB>path<TAB>origin per line
#   SESSION_SKILL_CATALOG_BODY
#   SESSION_SKILL_CATALOG_RENDERED_BYTES

# session_skill_read_frontmatter <skill.md>
#   Prints "name<TAB>description" from YAML frontmatter (first --- block).
session_skill_read_frontmatter() {
  local file="${1:-}"
  [ -f "$file" ] || return 1
  awk '
    BEGIN { in_fm=0; name=""; desc="" }
    /^---[ \t]*$/ {
      if (in_fm == 0) { in_fm=1; next }
      if (name != "") {
        gsub(/[ \t\r\n]+/, " ", desc)
        gsub(/^ | $/, "", desc)
        print name "\t" desc
      }
      exit
    }
    in_fm && /^name:[ \t]*/ {
      s=$0; sub(/^name:[ \t]*/,"",s)
      gsub(/^["'"'"']|["'"'"']$/,"",s)
      name=s; next
    }
    in_fm && /^description:[ \t]*/ {
      s=$0; sub(/^description:[ \t]*/,"",s)
      gsub(/^["'"'"']|["'"'"']$/,"",s)
      desc=s; next
    }
  ' "$file"
}

# session_skill_catalog_build <root> <companySlug>
#   Builds internal catalog state. Prints skillsAvailable on stdout.
session_skill_catalog_build() {
  local root="${1:-}" company="${2:-}"
  local max_bytes skill_dir f fm n d line lb
  local count=0 rendered_bytes=0
  local tsv_file render_file list_file

  SESSION_SKILLS_AVAILABLE=0
  SESSION_SKILL_CATALOG_TSV=""
  SESSION_SKILL_CATALOG_RENDERED_BYTES=0
  SESSION_SKILL_CATALOG_BODY=""

  [ -n "$root" ] && [ -n "$company" ] || {
    echo 0
    return 0
  }

  max_bytes="${HQ_SESSION_SKILL_CATALOG_MAX_BYTES:-32768}"
  case "$max_bytes" in ''|*[!0-9]*) max_bytes=32768 ;; esac

  tsv_file="$(mktemp)"
  render_file="$(mktemp)"
  list_file="$(mktemp)"
  : > "$tsv_file"
  : > "$render_file"
  : > "$list_file"

  # Build ordered candidate list: company first, then root, then packages.
  # Format per line: origin<TAB>path
  if [ -d "$root/companies/$company/skills" ]; then
    for skill_dir in "$root/companies/$company/skills"/*/; do
      [ -d "$skill_dir" ] || continue
      f="${skill_dir}SKILL.md"
      [ -f "$f" ] && printf 'company\t%s\n' "$f" >> "$list_file"
    done
  fi
  if [ -d "$root/.claude/skills" ]; then
    for skill_dir in "$root/.claude/skills"/*/; do
      [ -d "$skill_dir" ] || continue
      case "$(basename "$skill_dir")" in
        _*|README*) continue ;;
      esac
      f="${skill_dir}SKILL.md"
      [ -f "$f" ] && printf 'root\t%s\n' "$f" >> "$list_file"
    done
  fi
  if [ -d "$root/core/packages" ]; then
    for skill_dir in "$root/core/packages"/*/skills/*/; do
      [ -d "$skill_dir" ] || continue
      f="${skill_dir}SKILL.md"
      [ -f "$f" ] && printf 'package\t%s\n' "$f" >> "$list_file"
    done
  fi

  # First name wins (company enumerated first → shadowing).
  local origin names_blob=""
  names_blob=""
  while IFS=$'\t' read -r origin f || [ -n "${origin:-}" ]; do
    [ -z "${origin:-}" ] && continue
    [ -f "$f" ] || continue
    fm="$(session_skill_read_frontmatter "$f")" || continue
    [ -n "$fm" ] || continue
    n="${fm%%$'\t'*}"
    d="${fm#*$'\t'}"
    [ -n "$n" ] || continue
    case $'\n'"$names_blob"$'\n' in
      *$'\n'"$n"$'\n'*) continue ;;
    esac
    names_blob="${names_blob}${n}"$'\n'
    printf '%s\t%s\t%s\n' "$n" "$f" "$origin" >> "$tsv_file"
    count=$((count + 1))
    if [ -n "$d" ]; then
      line="- /$n — $d"
    else
      line="- /$n"
    fi
    lb="$(printf '%s\n' "$line" | wc -c | tr -d '[:space:]')"
    case "$lb" in ''|*[!0-9]*) lb=0 ;; esac
    if [ $((rendered_bytes + lb)) -le "$max_bytes" ]; then
      printf '%s\n' "$line" >> "$render_file"
      rendered_bytes=$((rendered_bytes + lb))
    fi
  done < "$list_file"

  SESSION_SKILLS_AVAILABLE="$count"
  SESSION_SKILL_CATALOG_TSV="$(cat "$tsv_file")"
  SESSION_SKILL_CATALOG_RENDERED_BYTES="$rendered_bytes"
  SESSION_SKILL_CATALOG_BODY="$(cat "$render_file")"

  rm -f "$tsv_file" "$render_file" "$list_file"
  echo "$count"
  return 0
}

# session_skill_catalog_append <runDir>
session_skill_catalog_append() {
  local run_dir="${1:-}"
  local system_txt="$run_dir/system.txt"
  [ -f "$system_txt" ] || return 0
  {
    printf '<!-- hq-section: skill-catalog -->\n'
    if [ -n "${SESSION_SKILL_CATALOG_BODY:-}" ]; then
      printf '%s\n' "$SESSION_SKILL_CATALOG_BODY"
    else
      printf '(no skills available)\n'
    fi
  } >> "$system_txt"
  return 0
}
