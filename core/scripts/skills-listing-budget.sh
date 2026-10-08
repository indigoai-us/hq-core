#!/usr/bin/env bash
# Report the skill listing size and description characters above Claude's
# context-dependent budget. Compatible with the system Bash 3.2.
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -d "$1/.claude/skills" ]; then
  echo "Usage: $0 <hq-root> (must contain .claude/skills)" >&2
  exit 2
fi

root="$1"
skills="$root/.claude/skills"
settings="$root/.claude/settings.json"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
files="$tmp/files"
find -L "$skills" -type f -name SKILL.md -print | LC_ALL=C sort > "$files"

# Settings overrides are a JSON object of flat skill-name/value pairs. The
# awk reader handles both the pretty-printed and single-line object forms.
skill_override() {
  [ -f "$settings" ] || return 0
  awk -v wanted="$1" '
    {
      line = $0
      if (!inside && line ~ /"skillOverrides"[[:space:]]*:/) {
        sub(/^.*"skillOverrides"[[:space:]]*:[[:space:]]*/, "", line)
        inside = 1
      }
      if (!inside) next
      entry = line
      sub(/^[^{]*\{/, "", entry)
      while (match(entry, /"[^"]*"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
        pair = substr(entry, RSTART, RLENGTH)
        key = pair
        sub(/^[[:space:]]*"/, "", key)
        sub(/".*/, "", key)
        value = pair
        sub(/^[^:]*:[[:space:]]*/, "", value)
        sub(/^"/, "", value)
        sub(/".*/, "", value)
        if (key == wanted) found = value
        entry = substr(entry, RSTART + RLENGTH)
      }
      if (entry ~ /}/) inside = 0
    }
    END { if (found != "") print found }
  ' "$settings"
}

visible_count=0
name_chars=0
description_chars=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  name="$(basename "$(dirname "$file")")"
  metadata="$(awk '
    function set_value(key, raw, value, quote) {
      sub(/^[[:space:]]*/, "", raw)
      if (raw ~ /^[>|][+-]?[[:space:]]*$/) {
        values[key] = ""
        modes[key] = "block"
        return
      }
      quote = substr(raw, 1, 1)
      if ((quote == "\"" || quote == "\047") && substr(raw, length(raw), 1) == quote)
        raw = substr(raw, 2, length(raw) - 2)
      values[key] = raw
      modes[key] = "plain"
    }
    NR == 1 && $0 == "---" { frontmatter = 1; next }
    frontmatter && $0 == "---" { frontmatter = 0; next }
    !frontmatter && first_line == "" && $0 !~ /^[[:space:]]*$/ { first_line = $0 }
    frontmatter {
      if ($0 ~ /^listing:[[:space:]]*hidden([[:space:]]|$)/) hidden = 1
      if ($0 ~ /^disable-model-invocation:[[:space:]]*/) {
        flag = $0
        sub(/^disable-model-invocation:[[:space:]]*/, "", flag)
        sub(/[[:space:]]*#.*/, "", flag)
        sub(/^\047/, "", flag); sub(/\047$/, "", flag)
        sub(/^"/, "", flag); sub(/"$/, "", flag)
        flag = tolower(flag)
        if (flag == "true" || flag == "yes" || flag == "on" || flag == "1") hidden = 1
      }
      if ($0 ~ /^description:[[:space:]]*/) {
        raw = $0; sub(/^description:[[:space:]]*/, "", raw)
        set_value("description", raw); field = "description"; next
      }
      if ($0 ~ /^when_to_use:[[:space:]]*/) {
        raw = $0; sub(/^when_to_use:[[:space:]]*/, "", raw)
        set_value("when_to_use", raw); field = "when_to_use"; next
      }
      if ($0 !~ /^[[:space:]]/) { field = ""; next }
      if (field != "") {
        continuation = $0; sub(/^[[:space:]]+/, "", continuation)
        if (values[field] != "") {
          if (modes[field] == "block") values[field] = values[field] "\n" continuation
          else values[field] = values[field] " " continuation
        } else values[field] = continuation
      }
    }
    END {
      listing = values["description"]
      when = values["when_to_use"]
      if (listing == "") listing = first_line
      if (when != "") {
        if (listing != "") listing = listing "\n"
        listing = listing when
      }
      if (length(listing) > 1536) listing = substr(listing, 1, 1536)
      printf "%d\t%d\n", hidden, length(listing)
    }
  ' "$file")"
  hidden="${metadata%%$'\t'*}"
  listing_chars="${metadata#*$'\t'}"
  [ "$hidden" = "1" ] && continue

  override="$(skill_override "$name")"
  case "$override" in
    off|user-invocable-only) continue ;;
    name-only) listing_chars=0 ;;
  esac

  visible_count=$((visible_count + 1))
  name_chars=$((name_chars + ${#name}))
  description_chars=$((description_chars + listing_chars))
done < "$files"

total=$((name_chars + description_chars))
overflow_for_budget() {
  budget="$1"
  available=$((budget - name_chars))
  [ "$available" -lt 0 ] && available=0
  overflow=$((description_chars - available))
  [ "$overflow" -lt 0 ] && overflow=0
  printf '%s' "$overflow"
}

printf 'Visible listing entries: %s\n' "$visible_count"
printf 'Listing characters (name + description): %s\n' "$total"
printf '200K estimate (2,000 characters): %s description characters over budget; affected skill names depend on Claude invocation frequency\n' "$(overflow_for_budget 2000)"
printf '1M estimate (10,000 characters): %s description characters over budget; affected skill names depend on Claude invocation frequency\n' "$(overflow_for_budget 10000)"
