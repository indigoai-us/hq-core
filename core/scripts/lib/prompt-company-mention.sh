#!/usr/bin/env bash
# hq-core: public
# prompt-company-mention.sh — find the one company a user's first prompt names.
#
# Sourced by .claude/hooks/natural-language-router.sh; never execute directly.
# Scheduled-task runs use prompt_company_mention_scheduled_task_resolve (below).
#
# A company counts as named only on an explicit cue. Cues, in the user's own
# first line, for a manifest slug or manifest `name:` value <co>:
#   for <co>      company <co>      <co> company      @<co> as the first token
# <co> must be followed by whitespace, end of line, or , ; : then a space (or a
# final period). Paths (/co), domains (co.com), calls (co(...)), non-ASCII
# neighbours, and "in|on|at|about <co>" never count. A term in PCM_COMMON_WORDS,
# or under 4 characters, never binds by any cue, but it still counts as a
# mention. The resolver answers only when exactly one company (common or not)
# is mentioned anywhere in the line (cue or not) and that company is not
# common and has a cue; two companies
# named, a line with an error/exception word, or any doubt yields nothing, so
# the caller keeps the existing binding.
#
# Scanned text: only the first non-empty line of the prompt, cut at the first
# paste-introducing phrase, with inline code, matched <tag>...</tag> pairs and
# anything from an unclosed <tag to the end of the line removed. A first line
# that is a fence or a quote scans nothing. Pasted content therefore never
# reaches the matcher.

# The one place that lists slugs/names that are ordinary words. Space separated.
PCM_COMMON_WORDS="${PCM_COMMON_WORDS:-team live beta ridge ok acme demo test core main dev hq app lab labs hub home work data cloud star blue red green one two new next first}"

PCM_SCAN_CHARS="${PCM_SCAN_CHARS:-500}"

# Print the scannable part of the prompt (see header). Reads the prompt as $1.
# Prints nothing when jq is missing.
prompt_company_mention_scan_text() {
  local prompt="${1:-}"
  command -v jq >/dev/null 2>&1 || return 0
  printf '%s' "$prompt" | jq -Rrs --argjson max "$PCM_SCAN_CHARS" '
    ( split("\n") | map(select(test("\\S"))) | .[0] // "" ) as $l
    | if ($l | test("^\\s*(```|~~~|>)")) then ""
      else $l
        | gsub("`[^`]*`"; " ")
        | gsub("<(?<t>[A-Za-z][A-Za-z0-9_:.-]*)(\\s[^>]*)?>.*?</\\k<t>\\s*>"; " ")
        | sub("<[A-Za-z/!][^>]*(>.*)?$"; "")
        | sub("(?i)\\b((summari[sz]e|analy[sz]e|translate|proofread|explain|review) (this|these|the following|the text|the log)|here is|here\u0027s|the following|pasted)\\b.*$"; "")
        | .[0:$max]
      end
  ' 2>/dev/null || true
}

# Print the slug of the single manifest company named in $2 (already sanitized
# text), or nothing. $1 is the HQ root.
prompt_company_mention_resolve() {
  local root="${1:-}" text="${2:-}" manifest slug count d real=""
  [ -n "$root" ] && [ -n "$text" ] || return 0
  manifest="$root/companies/manifest.yaml"
  [ -f "$manifest" ] || return 0
  local hits
  hits="$(LC_ALL=C PCM_TEXT="$text" PCM_COMMON="$PCM_COMMON_WORDS" awk '
    function clean(v) {
      sub(/^[^:]+:[ \t]*/, "", v)
      if (v ~ /^"/) { sub(/^"/, "", v); sub(/".*$/, "", v) }
      else if (v ~ /^'"'"'/) { sub(/^'"'"'/, "", v); sub(/'"'"'.*$/, "", v) }
      else { sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v) }
      return v
    }
    function keep(s) {
      return s != "" && s != "_template" && s != "companies" && s != "unaffiliated_repos" && s != "personal"
    }
    function word(c) { return c ~ /[a-z0-9_-]/ || (c != "" && c > "~") }
    function lastword(pre,   w) {
      sub(/[ \t]+$/, "", pre)
      w = pre; sub(/^.*[ \t(]/, "", w)
      return w
    }
    function endok(post) { return post ~ /^([ \t]|$|[,;:]([ \t]|$)|\.[ \t]*$)/ }
    # mention: 1 if term appears at a word boundary; cue: 1 if some boundary
    # occurrence carries an explicit cue. Both set by scan().
    function scan(term,   from, pos, before, after, pre, post, lw) {
      mention = 0; cue = 0
      from = 1
      while ((pos = index(substr(T, from), term)) > 0) {
        pos = from + pos - 1
        before = substr(T, pos - 1, 1)
        after = substr(T, pos + length(term), 1)
        if (!word(before) && !word(after)) {
          mention = 1
          pre = substr(T, 1, pos - 1)
          post = substr(T, pos + length(term))
          if (before == "@") {
            if (pos == 3 && substr(T, 1, 2) == " @" && endok(post)) cue = 1
          } else if (before == " ") {
            lw = lastword(pre)
            if (endok(post) && (lw == "for" || lw == "company")) cue = 1
            if (post ~ /^[ \t]+company([ \t,;:.?!]|$)/) cue = 1
          }
        }
        from = pos + 1
      }
    }
    function common(term) {
      return length(term) < 4 || (" " term " ") in COMMON
    }
    function norm(v) {
      v = tolower(v); gsub(/[ \t\r\n]+/, " ", v)
      sub(/^ /, "", v); sub(/ $/, "", v)
      return v
    }
    function test(slug, term) {
      if (!keep(slug) || term == "") return
      t = norm(term)
      if (length(t) < 2) return
      scan(t)
      if (mention) seen[slug] = 1
      if (cue && !common(t)) hit[slug] = 1
    }
    BEGIN {
      T = " " norm(ENVIRON["PCM_TEXT"]) " "
      n = split(tolower(ENVIRON["PCM_COMMON"]), cw, /[ \t\n]+/)
      for (i = 1; i <= n; i++) if (cw[i] != "") COMMON[" " cw[i] " "] = 1
    }
    /^[ \t]*#/ { next }
    /^companies:[ \t]*$/ { wrapped = 1; in_c = 1; next }
    wrapped && /^[^ \t#][^:]*:/ { in_c = 0 }
    wrapped && in_c && /^  [A-Za-z][A-Za-z0-9_-]*:/ {
      cur = $0; sub(/^  /, "", cur); sub(/:.*/, "", cur); test(cur, cur); next
    }
    wrapped && in_c && /^    name:/ { test(cur, clean($0)); next }
    !wrapped && /^[A-Za-z][A-Za-z0-9_-]*:/ {
      cur = $0; sub(/:.*/, "", cur); test(cur, cur); next
    }
    !wrapped && /^  name:/ { test(cur, clean($0)); next }
    END {
      if (T ~ /(^|[^a-z])(error|exception|traceback|fatal|warning|stack trace)([^a-z]|$)/) exit
      n = 0
      for (s in seen) { n++; one = s }
      if (n == 1 && (one in hit)) print one
    }
  ' "$manifest" 2>/dev/null)"
  [ -n "$hits" ] || return 0
  count="$(printf '%s\n' "$hits" | awk 'NF' | wc -l | tr -d ' ')"
  [ "$count" = "1" ] || return 0
  slug="$(printf '%s\n' "$hits" | awk 'NF {print; exit}')"
  # Same rule as the session binder: an exact, real (non-symlink) company dir.
  case "$slug" in ''|personal|*[!A-Za-z0-9_-]*) return 0 ;; esac
  for d in "$root"/companies/*; do
    [ -d "$d" ] && [ ! -L "$d" ] && [ "${d##*/}" = "$slug" ] && real="$slug"
  done
  [ -n "$real" ] && printf '%s' "$real"
  return 0
}

# True when the prompt is a scheduled-task run: it opens with the
# <scheduled-task name="..." file="..."> wrapper around the task's instructions.
prompt_company_mention_is_scheduled_task() {
  local prompt="${1:-}"
  prompt="${prompt#"${prompt%%[![:space:]]*}"}"
  case "$prompt" in '<scheduled-task '*|'<scheduled-task>'*) return 0 ;; esac
  return 1
}

# Print the one company a scheduled-task run points to, or nothing. $1 is the
# HQ root, $2 the session cwd, $3 the prompt. Evidence: a cwd under
# companies/<slug>/, companies/<slug> paths in the task text, and a cue in the
# task's first line (same rules as above). Every piece of evidence must name
# the same single real company; none, or two companies, yields nothing.
prompt_company_mention_scheduled_task_resolve() {
  local root="${1:-}" cwd="${2:-}" prompt="${3:-}" cands="" s d body real=$'\n' uniq=$'\n' n=0
  [ -n "$root" ] && [ -n "$prompt" ] || return 0
  if [ -n "$cwd" ]; then
    for d in "$cwd" "$(cd "$cwd" 2>/dev/null && pwd -P)"; do
      case "$d" in
        "$root"/companies/*) s="${d#"$root"/companies/}"; cands="$cands${s%%/*}"$'\n' ;;
      esac
    done
  fi
  cands="$cands$(printf '%s\n' "$prompt" | grep -oE '(^|[^A-Za-z0-9_.-])companies/[A-Za-z0-9][A-Za-z0-9_-]*' 2>/dev/null \
    | sed -E 's#^.*companies/##')"$'\n'
  body="$(printf '%s\n' "$prompt" | sed -E '1s/^[[:space:]]*<scheduled-task[^>]*>//; s#</scheduled-task>##')"
  cands="$cands$(prompt_company_mention_resolve "$root" "$(prompt_company_mention_scan_text "$body")")"$'\n'
  # Exact, real (non-symlink) company dirs only, as the session binder requires.
  for d in "$root"/companies/*; do
    [ -d "$d" ] && [ ! -L "$d" ] && real="$real${d##*/}"$'\n'
  done
  while IFS= read -r s; do
    case "$s" in ''|personal|_template|*[!A-Za-z0-9_-]*) continue ;; esac
    case "$real" in *$'\n'"$s"$'\n'*) ;; *) continue ;; esac
    case "$uniq" in *$'\n'"$s"$'\n'*) ;; *) uniq="$uniq$s"$'\n'; n=$((n + 1)) ;; esac
  done <<< "$cands"
  [ "$n" -eq 1 ] || return 0
  s="${uniq#$'\n'}"
  printf '%s' "${s%$'\n'}"
  return 0
}
