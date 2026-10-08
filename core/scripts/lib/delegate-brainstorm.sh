# shellcheck shell=bash
# hq-core: public
# delegate-brainstorm.sh — shared readers for brainstorm-stage projects in the
# /delegate helpers.
#
# SOURCED, never executed:  . "$ROOT/core/scripts/lib/delegate-brainstorm.sh"
# bash 3.2 safe; no associative arrays, no GNU-only flags.
#
# A brainstorm-stage project has companies/<co>/projects/<slug>/brainstorm.md
# and no prd.json yet (policy hq-brainstorm-leaves-handoffable-project-folder).
# Every delegation helper that reads the PRD falls back to these readers when
# the manifest says project.stage == "brainstorm".

# Project stage from the files on disk. Prints "prd", "brainstorm", or "none".
hq_delegate_project_stage() { # project_dir
  if [ -f "$1/prd.json" ]; then
    echo prd
  elif [ -f "$1/brainstorm.md" ]; then
    echo brainstorm
  else
    echo none
  fi
}

# Value of a top-level `key: value` line inside the leading YAML frontmatter.
# Prints nothing when the file has no frontmatter or the key is absent.
hq_brainstorm_frontmatter_get() { # file key
  awk -v key="$2" '
    NR == 1 { if ($0 != "---") exit; next }
    /^---[[:space:]]*$/ { exit }
    {
      split($0, kv, ":")
      if (kv[1] == key) {
        sub("^[^:]*:[[:space:]]*", "", $0)
        gsub(/^"|"$/, "", $0)
        print
        exit
      }
    }' "$1"
}

# One-line summary: the first `> ` blockquote after the H1, else the first
# non-empty prose line after the H1.
hq_brainstorm_summary() { # file
  awk '
    /^# / && !seen_h1 { seen_h1 = 1; next }
    !seen_h1 { next }
    /^> / { sub(/^> /, ""); print; exit }
    /^#/ { exit }
    /^[[:space:]]*$/ { next }
    { print; exit }' "$1"
}

# Project title: the first H1 without the leading `# `.
hq_brainstorm_title() { # file
  awk '/^# / { sub(/^# /, ""); print; exit }' "$1"
}

# Body of a `## <heading>` section, up to the next `## ` heading. The heading
# is matched by prefix so `## Recommendation` also matches a decorated title.
hq_brainstorm_section() { # file heading
  awk -v heading="$2" '
    /^## / {
      if (in_section) exit
      if (index($0, "## " heading) == 1) { in_section = 1; next }
    }
    in_section { print }' "$1" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

# Newest journal note by filename, excluding the delegation log the transfer
# step maintains. Prints the HQ-root-relative path or nothing.
hq_brainstorm_latest_journal() { # hq_root rel_project_dir
  local dir="$1/$2/journal" f
  [ -d "$dir" ] || return 0
  f="$(find "$dir" -maxdepth 1 -type f -name '*.md' ! -name 'delegations.md' | sort | tail -1)"
  [ -n "$f" ] || return 0
  printf '%s\n' "${f#"$1/"}"
}

# HQ-root-relative dossier paths for a brainstorm-stage project, one per line:
# brainstorm.md, every file under research/, the newest journal note.
hq_brainstorm_dossier() { # hq_root rel_project_dir
  local root="$1" rel="$2"
  printf '%s\n' "$rel/brainstorm.md"
  if [ -d "$root/$rel/research" ]; then
    (cd "$root" && find "$rel/research" -type f ! -name '.DS_Store' | sort)
  fi
  hq_brainstorm_latest_journal "$root" "$rel"
}

# Write or replace `key: value` inside the frontmatter, creating the
# frontmatter block when the file has none. Rewrites the file in place through
# a temp file so a failure leaves the original intact.
hq_brainstorm_frontmatter_set() { # file key value
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  if [ "$(head -1 "$file")" = "---" ]; then
    awk -v key="$key" -v value="$value" '
      NR == 1 { print; next }
      !done && /^---[[:space:]]*$/ { print key ": " value; done = 1; print; next }
      !done {
        split($0, kv, ":")
        if (kv[1] == key) { print key ": " value; done = 1; next }
      }
      { print }' "$file" > "$tmp"
  else
    { printf -- '---\n%s: %s\n---\n' "$key" "$value"; cat "$file"; } > "$tmp"
  fi
  mv -f "$tmp" "$file"
}
