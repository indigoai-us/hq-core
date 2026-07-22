#!/usr/bin/env bash
# hq-core: public
# session-skill-dispatch.sh — resolve /<skill-name> against the catalog.
#
# On hit: write full SKILL.md to <runDir>/skill.txt (bounded), append body under
# <!-- hq-section: skill --> in system.txt (never user.txt). Skill bodies are
# TRUSTED repo content (hq rescue / sync), not channel input.
#
# On miss: set SESSION_SKILL_CLARIFY=1 and SESSION_SKILL_SUGGESTIONS (space-
# separated nearest names by edit distance) for a disposition=clarify response.
#
# Env:
#   HQ_SESSION_SKILL_BODY_MAX_BYTES  default 65536
# Requires SESSION_SKILL_CATALOG_TSV from session_skill_catalog_build.

# session_levenshtein <a> <b>  → distance on stdout (integer)
session_levenshtein() {
  # Portable awk Levenshtein.
  awk -v s="${1:-}" -v t="${2:-}" '
    BEGIN {
      n = length(s); m = length(t)
      if (n == 0) { print m; exit }
      if (m == 0) { print n; exit }
      for (i = 0; i <= n; i++) d[i, 0] = i
      for (j = 0; j <= m; j++) d[0, j] = j
      for (i = 1; i <= n; i++) {
        si = substr(s, i, 1)
        for (j = 1; j <= m; j++) {
          tj = substr(t, j, 1)
          cost = (si == tj) ? 0 : 1
          del = d[i - 1, j] + 1
          ins = d[i, j - 1] + 1
          subc = d[i - 1, j - 1] + cost
          min = del
          if (ins < min) min = ins
          if (subc < min) min = subc
          d[i, j] = min
        }
      }
      print d[n, m]
    }
  '
}

# session_skill_dispatch <runDir> <messageText>
#   Returns 0 always.
#   Sets:
#     SESSION_SKILL_DISPATCHED=0|1
#     SESSION_SKILL_CLARIFY=0|1
#     SESSION_SKILL_SUGGESTIONS="a b c"
#     SESSION_SKILL_BODY_TRUNCATED=0|1
#     SESSION_SKILL_NAME
session_skill_dispatch() {
  local run_dir="${1:-}" message_text="${2-}"
  local max_body name rest path body skill_txt system_txt
  local truncated=0

  SESSION_SKILL_DISPATCHED=0
  SESSION_SKILL_CLARIFY=0
  SESSION_SKILL_SUGGESTIONS=""
  SESSION_SKILL_BODY_TRUNCATED=0
  SESSION_SKILL_NAME=""

  [ -n "$run_dir" ] || return 0
  system_txt="$run_dir/system.txt"
  skill_txt="$run_dir/skill.txt"

  # Only messages that begin with /skill-name (optional trailing whitespace/args)
  # match the slash form. Leading whitespace allowed.
  local trimmed
  trimmed="$(printf '%s' "$message_text" | sed -e 's/^[[:space:]]*//')"
  case "$trimmed" in
    /*) ;;
    *) return 0 ;;
  esac

  # Extract skill token: /name or /name rest...
  name="$(printf '%s' "$trimmed" | sed -E 's|^/([A-Za-z0-9_./-]+).*|\1|')"
  # Reject empty or path-like traversal
  case "$name" in
    ''|*..*|*/*) return 0 ;;
  esac
  SESSION_SKILL_NAME="$name"

  # Resolve against catalog TSV: name\tpath\torigin
  path=""
  if [ -n "${SESSION_SKILL_CATALOG_TSV:-}" ]; then
    while IFS=$'\t' read -r cname cpath corigin || [ -n "${cname:-}" ]; do
      [ -z "${cname:-}" ] && continue
      if [ "$cname" = "$name" ]; then
        path="$cpath"
        break
      fi
    done <<< "$SESSION_SKILL_CATALOG_TSV"
  fi

  if [ -z "$path" ] || [ ! -f "$path" ]; then
    # Clarify with three nearest catalog names by edit distance.
    SESSION_SKILL_CLARIFY=1
    local candidates=""
    if [ -n "${SESSION_SKILL_CATALOG_TSV:-}" ]; then
      local tmp_rank
      tmp_rank="$(mktemp)"
      while IFS=$'\t' read -r cname cpath corigin || [ -n "${cname:-}" ]; do
        [ -z "${cname:-}" ] && continue
        local dist
        dist="$(session_levenshtein "$name" "$cname")"
        printf '%s\t%s\n' "$dist" "$cname" >> "$tmp_rank"
      done <<< "$SESSION_SKILL_CATALOG_TSV"
      candidates="$(sort -n -t$'\t' -k1,1 "$tmp_rank" | head -n 3 | cut -f2 | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
      rm -f "$tmp_rank"
    fi
    SESSION_SKILL_SUGGESTIONS="$candidates"
    return 0
  fi

  max_body="${HQ_SESSION_SKILL_BODY_MAX_BYTES:-65536}"
  case "$max_body" in ''|*[!0-9]*) max_body=65536 ;; esac

  # Load body with optional truncation + visible marker.
  local full_size
  full_size="$(wc -c < "$path" | tr -d '[:space:]')"
  case "$full_size" in ''|*[!0-9]*) full_size=0 ;; esac

  if [ "$full_size" -gt "$max_body" ]; then
    head -c "$max_body" "$path" > "$skill_txt"
    printf '\n\n[... skill body truncated at %s bytes ...]\n' "$max_body" >> "$skill_txt"
    truncated=1
  else
    cp "$path" "$skill_txt"
  fi
  SESSION_SKILL_BODY_TRUNCATED="$truncated"
  SESSION_SKILL_DISPATCHED=1

  # Append to system.txt under skill section — never user.txt.
  if [ -f "$system_txt" ]; then
    {
      printf '<!-- hq-section: skill -->\n'
      printf 'Invoked skill: /%s (TRUSTED repo content)\n\n' "$name"
      cat "$skill_txt"
      printf '\n'
    } >> "$system_txt"
  fi
  return 0
}
