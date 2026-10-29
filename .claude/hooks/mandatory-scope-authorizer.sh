#!/usr/bin/env bash
# hq-core: public
# Mandatory company-scope authorizer — blocks cross-company filesystem access.
# PreToolUse for Read, Grep, Glob, Bash, and (since 2026-09-07) Write, Edit,
# MultiEdit, NotebookEdit. Reads were guarded from the start; file mutations
# through the editing tools were not, so a bound session could write into
# another tenant's folder with the Write tool while the same path was blocked
# in Bash. The write side now uses the same session-identity and path rules.
#
# Resolves the active company from workspace/sessions (scope-capability.json,
# then meta.yaml company_slug). Unbound sessions may not read companies/{co}/
# except companies/manifest.yaml and companies/_template/.

set -euo pipefail

# scope_tool_location_bounded leaves this marker after a timeout.
trap 'rmdir "${TMPDIR:-/tmp}/hq-scope-tool-slow.$$" 2>/dev/null || true' EXIT

INPUT=
IFS= read -r -d '' INPUT || true
INPUT="${INPUT%"${INPUT##*[!$'\n']}"}"

if [ "${HQ_HOOK_CWD+set}" = "set" ]; then
  PAYLOAD_CWD="$HQ_HOOK_CWD"
else
  PAYLOAD_CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
fi
if [ "${HQ_HOOK_TOOL_NAME+set}" = "set" ]; then
  TOOL="$HQ_HOOK_TOOL_NAME"   # parsed once by master-hook.sh
else
  TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
fi

scope_mask_literal_expansions() {
  local raw="${1:-}" out="" ch backtick
  local in_single=0 escaped=0 i
  backtick=$'\140'

  for ((i = 0; i < ${#raw}; i++)); do
    ch="${raw:i:1}"
    if [ "$escaped" -eq 1 ]; then
      case "$ch" in
        '$'|"$backtick"|'*'|'?'|'[') out+="__HQ_LITERAL_EXPANSION__" ;;
        *) out+="$ch" ;;
      esac
      escaped=0
      continue
    fi

    if [ "$in_single" -eq 1 ]; then
      if [ "$ch" = "'" ]; then
        in_single=0
        out+="$ch"
      else
        case "$ch" in
          '$'|"$backtick"|'*'|'?'|'[') out+="__HQ_LITERAL_EXPANSION__" ;;
          *) out+="$ch" ;;
        esac
      fi
      continue
    fi

    case "$ch" in
      \\) out+="$ch"; escaped=1 ;;
      \') out+="$ch"; in_single=1 ;;
      '$')
        # A `$` that cannot begin a parameter, command, or arithmetic expansion
        # — nor one of bash's dollar-quoting forms — is a literal dollar to the
        # shell as well: a regex anchor in `grep -E "done$|/tmp/"`, a trailing
        # `"cost$"`. Marking it literal keeps a pattern argument from being read
        # as an unresolvable path expansion.
        #
        # The preserved set must cover EVERY introducer bash honours, or the
        # guard stops seeing a real expansion. `$'…'` (ANSI-C quoting) and
        # `$"…"` (locale quoting) both resolve to plain text the shell then uses
        # as a path — `companies/$'otherco'/settings/x` is a cross-company read
        # — and `$[…]` is legacy arithmetic. All three stay expansions here.
        #
        # Every special character is its OWN quoted pattern. Written as one
        # bracket expression, `[...$!...]` is parameter-expanded before matching:
        # bash reads the `$!` as the last background PID, and under `set -u` a
        # hook with no background job dies with "unbound variable" instead of
        # rendering a verdict (caught by the spawn-budget suite, which skips the
        # process substitution that would otherwise have set `$!`).
        case "${raw:$((i + 1)):1}" in
          [A-Za-z0-9_@]|'*'|'#'|'?'|'$'|'!'|'-'|'{'|'('|'['|"'"|'"') out+="$ch" ;;
          *) out+="__HQ_LITERAL_EXPANSION__" ;;
        esac
        ;;
      *) out+="$ch" ;;
    esac
  done

  printf '%s' "$out"
}

# Keep each heredoc command header in the scan so redirection destinations
# remain authorization targets. Heredoc bodies are stripped only when they are
# data for `gh pr create` or data written by `cat`/`tee` to an output redirect.
# Interpreter heredocs and other command bodies stay visible and fail closed.
scope_heredoc_output_writer() {
  local header="${1:-}" output_redirect_re
  # Do not classify compound commands or pipelines as pure data writers.
  case "$header" in *'|'*|*';'*|*'&'*) return 1 ;; esac
  [[ "$header" =~ ^[[:space:]]*(cat|tee)([[:space:]]|$) ]] || return 1
  output_redirect_re='(^|[[:space:]])(1?>|>>)[[:space:]]*[^[:space:];|&]+'
  [[ "$header" =~ $output_redirect_re ]]
}

# Unquoted here-docs expand command and process substitutions and backticks,
# but plain text such as `$project` is not a filesystem operand. Keep executable
# expansion bodies visible to the normal scanner and discard the surrounding prose.
scope_heredoc_executions() {
  local raw="${1:-}" out="" ch next escaped=0 quote="" depth start i j inner_ch inner_escape
  local backtick
  # Most heredoc lines are plain prose. Avoid the byte-by-byte parser unless
  # an executable expansion marker is present; this is especially costly in
  # Git Bash where substring extraction starts a shell operation per byte.
  case "$raw" in
    *'$('*|*'<('*|*'>('*|*'`'*) ;;
    *) return 0 ;;
  esac
  backtick=$'\140'
  for ((i = 0; i < ${#raw}; i++)); do
    ch="${raw:i:1}"
    if [ "$escaped" -eq 1 ]; then escaped=0; continue; fi
    if [ "$ch" = '\\' ]; then escaped=1; continue; fi
    next="${raw:$((i + 1)):1}"
    if { [ "$ch" = '$' ] || [ "$ch" = '<' ] || [ "$ch" = '>' ]; } && [ "$next" = '(' ]; then
      start=$i
      depth=1
      quote=""
      inner_escape=0
      j=$((i + 2))
      while [ "$j" -lt "${#raw}" ] && [ "$depth" -gt 0 ]; do
        inner_ch="${raw:j:1}"
        if [ "$inner_escape" -eq 1 ]; then inner_escape=0; j=$((j + 1)); continue; fi
        if [ "$inner_ch" = '\\' ]; then inner_escape=1; j=$((j + 1)); continue; fi
        if [ -n "$quote" ]; then
          if [ "$inner_ch" = "$quote" ]; then quote=""; fi
          j=$((j + 1)); continue
        fi
        case "$inner_ch" in
          \'|\") quote="$inner_ch" ;;
          '(') depth=$((depth + 1)) ;;
          ')') depth=$((depth - 1)) ;;
        esac
        j=$((j + 1))
      done
      if [ "$depth" -eq 0 ]; then
        out+="${raw:start:$((j - start))}"$'\n'
        i=$((j - 1))
      else
        # An unterminated substitution is ambiguous; leave its remainder for
        # the normal fail-closed scan.
        out+="${raw:start}"
        break
      fi
      continue
    fi
    if [ "$ch" = "$backtick" ]; then
      start=$i
      j=$((i + 1))
      inner_escape=0
      while [ "$j" -lt "${#raw}" ]; do
        inner_ch="${raw:j:1}"
        if [ "$inner_escape" -eq 1 ]; then inner_escape=0; j=$((j + 1)); continue; fi
        if [ "$inner_ch" = '\\' ]; then inner_escape=1; j=$((j + 1)); continue; fi
        if [ "$inner_ch" = "$backtick" ]; then break; fi
        j=$((j + 1))
      done
      if [ "$j" -lt "${#raw}" ]; then
        out+="${raw:start:$((j - start + 1))}"$'\n'
        i=$j
      else
        out+="${raw:start}"
        break
      fi
      continue
    fi
  done
  printf '%s' "$out"
}

# Remove references to a heredoc-written file that only read it as message
# text: `gh pr|issue create|edit|comment --body-file <dest>` (or -F) and
# `git [-C dir] commit -F|--file <dest>`. Those commands send the file to
# GitHub or into a commit message; they never execute it. Any other mention
# of the file, including a second one on the same line, is left in place so
# the caller still treats the body as possibly executed.
scope_strip_data_file_refs() {
  local text="${1:-}" dest="${2:-}" line out="" consumer_re form q
  consumer_re='^[[:space:]]*(gh[[:space:]]+(pr|issue)[[:space:]]+(create|edit|comment)|git([[:space:]]+-C[[:space:]]+[^[:space:];&|]+)?[[:space:]]+commit)([[:space:]]|$)'
  # `hq feedback bug|feature --body-file <dest>` and `hq dm send ...
  # --prompt-file|--details-file <dest>` read the file as message text and
  # send it; they never run it (feedback 7f9b7ad5 family B). A text option
  # given the file through `"$(cat <dest>)"` on these lines is the same
  # data. --screenshot and --attach upload the file and are not stripped.
  local hq_consumer_re='^[[:space:]]*hq[[:space:]]+(feedback[[:space:]]+(bug|feature)|dm[[:space:]]+send)([[:space:]]|$)'
  local text_opt_re='^[[:space:]]*hq[[:space:]]+(feedback[[:space:]]+(bug|feature|update)|dm[[:space:]]+send)([[:space:]]|$)'
  local opt
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$dest" ] && [[ "$line" =~ $consumer_re ]]; then
      for q in "" "'" '"'; do
        for form in "--body-file $q$dest$q" "--body-file=$q$dest$q" "-F $q$dest$q" "--file $q$dest$q" "--file=$q$dest$q"; do
          line="${line//" $form"/ }"
        done
      done
    fi
    if [ -n "$dest" ] && [[ "$line" =~ $hq_consumer_re ]]; then
      for q in "" "'" '"'; do
        for form in "--body-file $q$dest$q" "--body-file=$q$dest$q" "--prompt-file $q$dest$q" "--prompt-file=$q$dest$q" "--details-file $q$dest$q" "--details-file=$q$dest$q"; do
          line="${line//" $form"/ }"
        done
      done
    fi
    if [ -n "$dest" ] && [[ "$line" =~ $text_opt_re ]]; then
      for opt in --body --title --note --details --prompt; do
        line="${line//" $opt \"\$(cat $dest)\""/ $opt x}"
      done
    fi
    out+="$line"$'\n'
  done <<< "$text"
  printf '%s' "$out"
}

# True when <line> hands a heredoc to a client that only sends it as data:
#   curl [allowed options] (-d|--data|--data-binary|--data-raw|--json) @- URL <<'EOF'
#   (hq|gh) ... WORD --opt "$(cat <<'EOF'
#   gh (pr|issue) ... WORD (--body-file|-F) - <<'EOF'
#   jq ... --arg NAME "$(cat <<'EOF'
# The caller already refused pipes and interpreter words on the line. Only
# one heredoc per line reaches here. The substitution form needs a known data
# option (see scope_token_is_data_option_substitution) to pass the later scan.
# curl is checked word by word against a short list of options that cannot
# read or write a file (scope_curl_stdin_data_line), because many curl
# options read stdin (-K-, -T-, -w @-, --variable @-) and a format or config
# read from stdin can name files to read or write. curl in the substitution
# form is refused: `-d "$(...)"` reads a file when the body starts with `@`.
# For gh the command must be `pr|issue create|edit|comment` (or `pr review`)
# and the option --body or --title (or --body-file/-F - for a stdin body).
# For hq the command must be dm, mesh,
# agents, or integrations and the option a text option those commands take
# (hq run and hq secrets exec pass options to a child; hq core checkpoint
# --payload reads a file). Any other option or command keeps the body in the
# scan. The words before the option must be plain or whole quoted words
# (read unquoted, with no expansion or escape), no word may be `--`, and the
# word before the option must not start with `-`,
# so the option is not itself the value of an earlier option (`gh gist
# create -d --body "$(...)"` makes the body a file argument). A jq line that
# names a file option or --args is refused.
scope_heredoc_data_client_line() {
  local line="${1:-}" re
  case "$line" in *';'*|*'&'*|*'>'*'<<'*|*'`'*) return 1 ;; esac
  re='^[[:space:]]*curl[[:space:]]'
  if [[ "$line" =~ $re ]]; then
    scope_curl_stdin_data_line "$line"
    return
  fi
  re='^[[:space:]]*jq[[:space:]]'
  if [[ "$line" =~ $re ]]; then
    re='[[:space:]](--rawfile|--slurpfile|--from-file|--args|--jsonargs|-[A-Za-z]*[fL])([[:space:]=]|$)'
    [[ "$line" =~ $re ]] && return 1
    re='^[[:space:]]*jq[[:space:]].*[[:space:]]--arg(json)?[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+"\$\(cat[[:space:]]+<<-?[[:space:]]*'"'"'[A-Za-z0-9._-]+'"'"'[[:space:]]*$'
    [[ "$line" =~ $re ]]
    return
  fi
  local client pre opt word last="" sub1="" sub2="" count=0 form=sub tok_re
  local -a words=()
  re='^[[:space:]]*(hq|gh)[[:space:]]+(.*[^[:space:]])[[:space:]]+(-[-A-Za-z]+)[[:space:]]+"\$\(cat[[:space:]]+<<-?[[:space:]]*'"'"'[A-Za-z0-9._-]+'"'"'[[:space:]]*$'
  if ! [[ "$line" =~ $re ]]; then
    # `gh pr edit 12 --body-file - <<'EOF'`: the body is read from stdin.
    re='^[[:space:]]*(gh)[[:space:]]+(.*[^[:space:]])[[:space:]]+(--body-file|-F)[[:space:]]+-[[:space:]]+<<-?[[:space:]]*'"'"'[A-Za-z0-9._-]+'"'"'[[:space:]]*$'
    [[ "$line" =~ $re ]] || return 1
    form=stdin
  fi
  client="${BASH_REMATCH[1]}"
  pre="${BASH_REMATCH[2]}"
  opt="${BASH_REMATCH[3]}"
  # Each word is plain, or a whole "..." (no $, backtick, or backslash) or
  # '...' word, which is read as its unquoted value; so a quoted "-d" still
  # counts as an option below. Anything else (escapes, adjacent quoting,
  # expansions) refuses the line.
  tok_re='^([A-Za-z0-9._/:@,+%=-]+|"[^"$`\\]*"|'"'"'[^'"'"']*'"'"')([[:space:]]+|$)'
  while [ -n "$pre" ]; do
    [[ "$pre" =~ $tok_re ]] || return 1
    word="${BASH_REMATCH[1]}"
    pre="${pre:${#BASH_REMATCH[0]}}"
    case "$word" in \"*|\'*) word="${word:1:${#word}-2}" ;; esac
    words+=("$word")
  done
  [ "${#words[@]}" -gt 0 ] || return 1
  for word in "${words[@]}"; do
    [ "$word" = -- ] && return 1
    count=$((count + 1))
    [ "$count" -eq 1 ] && sub1="$word"
    [ "$count" -eq 2 ] && sub2="$word"
    last="$word"
  done
  case "$last" in -*) return 1 ;; esac
  case "$client" in
    gh)
      case "$sub1 $sub2" in
        'pr create'|'pr edit'|'pr comment'|'pr review'|'issue create'|'issue edit'|'issue comment') ;;
        *) return 1 ;;
      esac
      case "$form:$opt" in sub:--body|sub:--title|stdin:--body-file|stdin:-F) return 0 ;; esac
      return 1
      ;;
    hq)
      [ "$form" = sub ] || return 1
      case "$sub1" in dm|mesh|agents|integrations) ;; *) return 1 ;; esac
      case "$opt" in --message|--text|--note|--body|--summary|--title|--description|--args) return 0 ;; esac
      ;;
  esac
  return 1
}

# True when <line> is `curl WORDS <<'EOF'` and every word is one of: -s -S
# -f -L -i -v (alone or clustered), --silent, --show-error, --fail,
# --fail-with-body, --location, --include, --verbose, --compressed, -X/--request
# METHOD, -H/--header VALUE (not @file), a data option followed by @-, or an
# http(s) URL; and at least one data option reads @-. Shell syntax that could
# change the words (expansions, quotes other than plain double quotes, globs,
# braces, comments, redirects) makes the line unsafe.
scope_curl_stdin_data_line() {
  local line="${1:-}" pre re n i ch word="" have=0 inq=0 pending="" saw_data=0
  local -a words=()
  re="^[[:space:]]*curl[[:space:]](.*)<<-?[[:space:]]*'[A-Za-z0-9._-]+'[[:space:]]*\$"
  [[ "$line" =~ $re ]] || return 1
  pre="${BASH_REMATCH[1]}"
  case "$pre" in
    *'$'*|*'`'*|*'\'*|*"'"*|*'*'*|*'?'*|*'['*|*'{'*|*'~'*|*'('*|*'#'*|*'<'*|*'>'*|*'|'*|*';'*|*'&'*) return 1 ;;
  esac
  n=${#pre}
  i=0
  while [ "$i" -lt "$n" ]; do
    ch="${pre:$i:1}"
    if [ "$ch" = '"' ]; then
      inq=$((1 - inq))
      have=1
    elif [ "$inq" -eq 0 ] && { [ "$ch" = ' ' ] || [ "$ch" = $'\t' ]; }; then
      [ "$have" -eq 1 ] && words+=("$word")
      word=""
      have=0
    else
      word+="$ch"
      have=1
    fi
    i=$((i + 1))
  done
  [ "$inq" -eq 0 ] || return 1
  [ "$have" -eq 1 ] && words+=("$word")
  [ "${#words[@]}" -gt 0 ] || return 1
  for word in "${words[@]}"; do
    case "$pending" in
      X)
        re='^[A-Z]+$'
        [[ "$word" =~ $re ]] || return 1
        pending=""
        continue
        ;;
      H)
        case "$word" in ''|@*) return 1 ;; esac
        pending=""
        continue
        ;;
      D)
        [ "$word" = "@-" ] || return 1
        saw_data=1
        pending=""
        continue
        ;;
    esac
    case "$word" in
      --silent|--show-error|--fail|--fail-with-body|--location|--include|--verbose|--compressed) ;;
      -X|--request) pending=X ;;
      -H|--header) pending=H ;;
      -d|--data|--data-binary|--data-raw|--json) pending=D ;;
      -*)
        re='^(-[sSfLiv]+|-X[A-Z]+)$'
        [[ "$word" =~ $re ]] || return 1
        ;;
      *)
        re='^https?://[^[:space:]]+$'
        [[ "$word" =~ $re ]] || return 1
        ;;
    esac
  done
  [ -z "$pending" ] && [ "$saw_data" -eq 1 ]
}

# True when a heredoc body inside "$(cat <<'EOF' ... EOF\n)" could end the
# command substitution before EOF. bash 3.2 (macOS /bin/bash) finds the end of
# $( ) by matching parentheses and does not know heredocs, so an unmatched `)`
# in the body closes the substitution and the rest of the body runs as shell.
# Quotes, `#` and backslashes change how bash 3.2 counts, so a body with a `)`
# and any of them is treated as able to escape. Backtick spans and `${...}`
# expansions are allowed only when they hold no parenthesis: then they cannot
# change the count whichever way bash reads them, so a PR body that quotes
# `${HOME}/x` next to a balanced `$(pwd)` is data (feedback fd9972dc). An odd
# number of backticks, or a `${` with no closing `}`, still counts as escaping.
scope_comsub_body_escapes() {
  local body="${1:-}" parens depth=1 i rest span ticks
  case "$body" in *')'*) ;; *) return 1 ;; esac
  case "$body" in *"'"*|*'"'*|*'#'*|*'\'*) return 0 ;; esac
  ticks="${body//[!\`]/}"
  [ $(( ${#ticks} % 2 )) -eq 0 ] || return 0
  rest="$body"
  while [[ "$rest" == *'`'* ]]; do
    rest="${rest#*\`}"
    span="${rest%%\`*}"
    case "$span" in *'('*|*')'*) return 0 ;; esac
    rest="${rest#*\`}"
  done
  rest="$body"
  while [[ "$rest" == *'${'* ]]; do
    rest="${rest#*\$\{}"
    case "$rest" in *'}'*) ;; *) return 0 ;; esac
    span="${rest%%\}*}"
    case "$span" in *'('*|*')'*|*'`'*) return 0 ;; esac
    rest="${rest#*\}}"
  done
  parens="${body//[!()]/}"
  for ((i = 0; i < ${#parens}; i++)); do
    if [ "${parens:i:1}" = "(" ]; then depth=$((depth + 1)); else depth=$((depth - 1)); fi
    [ "$depth" -ge 1 ] || return 0
  done
  return 1
}

scope_strip_inert_heredoc_bodies() {
  local raw="${1:-}" output="" line delimiter="" strip_tabs=0 in_body=0 delimiter_quoted=0
  local sub_body=0 held=""
  local original="$raw" tail="" unsafe_re body_sub_prefix data_writer=0
  local writer_dests="" dest dest_rest exec_re
  case "$raw" in *'<<'*) ;; *) printf '%s' "$raw"; return 0 ;; esac
  # A continuation pipe on its own line must not hide the preceding body.
  local pipe_line_re=$'\n''[[:space:]]*\|'
  if [[ "$raw" =~ $pipe_line_re ]]; then printf '%s' "$raw"; return 0; fi

  body_sub_prefix='$'
  body_sub_prefix+='(cat <<'
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_body" -eq 1 ]; then
      local terminator="$line"
      if [ "$strip_tabs" -eq 1 ]; then
        while [[ "$terminator" == $'\t'* ]]; do terminator="${terminator#$'\t'}"; done
      fi
      if [ "$terminator" = "$delimiter" ]; then
        if [ "$sub_body" -eq 1 ] && scope_comsub_body_escapes "$held"; then
          output+="$held"
        fi
        in_body=0
        delimiter=""
        strip_tabs=0
        data_writer=0
        sub_body=0
        held=""
      elif [ "$data_writer" -eq 1 ] && [ "$delimiter_quoted" -eq 0 ]; then
        output+="$(scope_heredoc_executions "$line")"$'\n'
      elif [ "$sub_body" -eq 1 ]; then
        held+="$line"$'\n'
      fi
      continue
    fi

    output+="$line"$'\n'

    # Multiple heredocs on one shell input line are ambiguous to this parser.
    # Leave them visible rather than hiding a later body.
    case "$line" in *'<<'*'<<'*) continue ;; esac
    case "$line" in *'|'*) continue ;; esac
    # An interpreter heredoc body stays FULLY scanned, even with a quoted
    # delimiter. The outer shell expands nothing in such a body, but the
    # interpreter can hand the same text to a shell that does — a python body
    # calling os.system("cat companies/$CO/...") expands $CO at runtime from
    # the exported environment. Treating the body as inert source therefore
    # cannot be made safe by looking at the delimiter's quoting.
    unsafe_re='(^|[[:space:];])(bash|sh|dash|zsh|ksh|python|python[0-9.]*|node|ruby|perl|eval|source)([[:space:]]|$)'
    [[ "$line" =~ $unsafe_re ]] && continue

    # These forms pass the body to GitHub as data. Keep other cat and shell
    # heredocs in the scan because their contents may be executed or consumed.
    if [[ "$line" =~ ^[[:space:]]*gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$) ]]; then
      body_option_re='(^|[[:space:]])--body(=|[[:space:]])'
      body_file_stdin_re='(^|[[:space:]])--body-file(=|[[:space:]])-([[:space:]]|$)'
      if [[ "$line" == *"$body_sub_prefix"* ]] && [[ "$line" =~ $body_option_re ]]; then
        tail="${line#*"$body_sub_prefix"}"
      elif [[ "$line" == *'<<'* ]] && [[ "$line" =~ $body_file_stdin_re ]]; then
        tail="${line#*<<}"
      else
        continue
      fi
    elif [[ "$line" =~ ^[[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:];|&\`\$]+)?[[:space:]]+(commit|tag|notes[[:space:]]+(add|append))[[:space:]]([^;|&<>\`\$]*[[:space:]])?(-F[[:space:]]*-|--file(=|[[:space:]]+)-)[[:space:]]+\<\<-?[[:space:]]*[\'\"] ]]; then
      # `git commit -F - <<'EOF'` hands a quoted (non-expanding) body to git as
      # message text. git never opens or runs paths named in a message, so
      # prose such as "companies/* paths" is not an operand. Only the
      # quoted-delimiter form qualifies; the regex requires the opening quote.
      tail="${line#*<<}"
    else
      if scope_heredoc_output_writer "$line"; then
        tail="${line#*<<}"
        data_writer=1
        dest="${BASH_REMATCH[0]}"
        dest="${dest#"${dest%%[![:space:]]*}"}"
        dest="${dest#>>}"; dest="${dest#1>}"; dest="${dest#>}"
        dest="${dest#"${dest%%[![:space:]]*}"}"
        dest="${dest#[\'\"]}"; dest="${dest%[\'\"]}"
        [ -z "$dest" ] || writer_dests+="$dest"$'\n'
      elif scope_heredoc_data_client_line "$line"; then
        # `curl -d @- URL <<'EOF'` or `hq ... --args "$(cat <<'EOF'`: the
        # client sends the body as data. Only a quoted delimiter qualifies
        # (checked below); an unquoted body stays scanned.
        tail="${line#*<<}"
      elif [[ "$line" =~ ^[[:space:]]*(cat|head|tail)[[:space:]]+\<\< ]] \
        && [[ "$line" != *'>'* ]] && [[ "$line" != *';'* ]] && [[ "$line" != *'&'* ]] && [[ "$line" != *'|'* ]]; then
        # A quoted body on a plain reader is input data, not shell source.
        tail="${line#*<<}"
      else
        continue
      fi
    fi

    strip_tabs=0
    delimiter_quoted=0
    case "$tail" in
      -*) strip_tabs=1; tail="${tail#-}" ;;
    esac
    while [[ "$tail" == [[:space:]]* ]]; do tail="${tail:1}"; done
    case "$tail" in
      \'*)
        delimiter_quoted=1
        tail="${tail#\'}"
        delimiter="${tail%%\'*}"
        ;;
      \"*)
        delimiter_quoted=1
        tail="${tail#\"}"
        delimiter="${tail%%\"*}"
        ;;
      *)
        delimiter="${tail%%[!A-Za-z0-9._-]*}"
        ;;
    esac
    case "$delimiter" in
      ""|*[!A-Za-z0-9._-]*) delimiter=""; strip_tabs=0; continue ;;
    esac
    # Quoted bodies are literal. For an unquoted data-writer body, retain only
    # executable expansions; other unquoted heredocs remain fully scanned.
    if [ "$delimiter_quoted" -eq 0 ] && [ "$data_writer" -eq 0 ]; then
      delimiter=""; strip_tabs=0; continue
    fi
    sub_body=0
    held=""
    [[ "$line" == *"$body_sub_prefix"* ]] && sub_body=1
    in_body=1
  done <<< "$raw"

  # Invalid, unterminated input stays visible to the scope scan.
  if [ "$in_body" -eq 1 ]; then
    printf '%s' "$original"
    return 0
  fi
  # A stripped data-writer body is only inert while nothing runs it. If the
  # same command later names a written file again (`bash /tmp/x`, `./x`,
  # `source x`, `python x`) or invokes any interpreter at all, the body may be
  # executed, so keep every body visible and fail closed on its paths.
  if [ -n "$writer_dests" ]; then
    exec_re='(^|[[:space:];&|(])(bash|sh|dash|zsh|ksh|python|python[0-9.]*|node|ruby|perl|eval|source|exec|\.)([[:space:]]|$)'
    if [[ "$output" =~ $exec_re ]]; then
      printf '%s' "$original"
      return 0
    fi
    while IFS= read -r dest; do
      [ -n "$dest" ] || continue
      dest_rest="$(scope_strip_data_file_refs "${output#*"$dest"}" "$dest")"
      if [[ "$dest_rest" == *"$dest"* ]] || [[ "$dest_rest" == *"./${dest##*/}"* ]]; then
        printf '%s' "$original"
        return 0
      fi
    done <<< "$writer_dests"
  fi
  # Each strip assumes the client word (hq, gh, jq, curl, cat, git) runs the
  # real program. A command that can redefine or re-route a command name
  # (`hq() { cat "$4"; }`, alias, PATH=, hash, source) keeps every body.
  if [ "$output" != "$original" ]; then
    local nl=$'\n' shadow_re
    shadow_re='(^|[^A-Za-z0-9_.-])(hq|gh|jq|curl|cat|head|tail|git|command|builtin)[[:space:]]*\('
    if [[ "$output" =~ $shadow_re ]]; then
      printf '%s' "$original"
      return 0
    fi
    shadow_re='(^|[^A-Za-z0-9_])(function|alias|hash|enable|source|eval|declare|typeset|BASH_FUNC_[A-Za-z0-9_]*|command_not_found_handle)([^A-Za-z0-9_]|$)'
    if [[ "$output" =~ $shadow_re ]]; then
      printf '%s' "$original"
      return 0
    fi
    shadow_re='(^|[^A-Za-z0-9_])(PATH|BASH_ENV|ENV)\+?='
    if [[ "$output" =~ $shadow_re ]]; then
      printf '%s' "$original"
      return 0
    fi
    shadow_re='(^|['"$nl"';&|(){}])[[:space:]]*\.[[:space:]]'
    if [[ "$output" =~ $shadow_re ]]; then
      printf '%s' "$original"
      return 0
    fi
  fi
  printf '%s' "$output"
}

# True when the text after <prefix> lies inside the body of a quoted-delimiter
# heredoc read by plain `cat` (`cat <<'EOF'`, `"$(cat <<'EOF'`, `cat > f
# <<'EOF'`). The shell expands nothing in such a body and cat runs nothing,
# so a quote, comma, or bracket right after a path there is literal text
# (JSON such as `"next": "see companies/x"}`), not shell quoting that could
# join more text to the path. The `<<` must sit at an unquoted position (or
# directly inside one `"$(`), the closing delimiter line must not appear
# between it and the fragment, and it must appear after the fragment.
# Arguments: <prefix> <text after prefix>.
scope_offset_in_cat_quoted_heredoc() {
  local prefix="${1:-}" rest="${2:-}" re word pre stmt nl=$'\n' body
  re="<<-?[[:space:]]*'([A-Za-z_][A-Za-z0-9_]*)'[^${nl}]*${nl}"
  [[ "$prefix" =~ $re ]] || return 1
  # Take the last heredoc opener in the prefix.
  body="$prefix"
  while [[ "$body" =~ $re ]]; do
    word="${BASH_REMATCH[1]}"
    pre="${prefix%"${body}"}${body%%"${BASH_REMATCH[0]}"*}"
    body="${body#*"${BASH_REMATCH[0]}"}"
  done
  # The delimiter line has not closed the body before the fragment ...
  case "$nl$body" in *"$nl$word$nl"*) return 1 ;; esac
  # ... and does close it after the fragment.
  case "$body$rest$nl" in *"$nl$word$nl"*) ;; *) return 1 ;; esac
  case "$pre" in *"$nl"*) pre="${pre##*"$nl"}" ;; esac
  re='^(.*)"\$\(([^"'"'"'()$`]*)$'
  if [[ "$pre" =~ $re ]]; then
    scope_shell_prefix_is_unquoted "${BASH_REMATCH[1]}" || return 1
    stmt="${BASH_REMATCH[2]}"
  else
    scope_shell_prefix_is_unquoted "$pre" || return 1
    stmt="${pre##*[;&|(]}"
  fi
  re='^[[:space:]]*cat([[:space:]]+(>|>>)[[:space:]]*[A-Za-z0-9._/-]+)?[[:space:]]*$'
  [[ "$stmt" =~ $re ]]
}

scope_shell_prefix_is_unquoted() {
  local value="${1:-}" quote="" escaped=0 ch i
  for ((i = 0; i < ${#value}; i++)); do
    ch="${value:i:1}"
    if [ "$escaped" -eq 1 ]; then
      escaped=0
      continue
    fi
    if [ "$quote" = "'" ]; then
      [ "$ch" = "'" ] && quote=""
      continue
    fi
    if [ "$quote" = '"' ]; then
      case "$ch" in
        \\) escaped=1 ;;
        '"') quote="" ;;
      esac
      continue
    fi
    case "$ch" in
      \\) escaped=1 ;;
      "'") quote="'" ;;
      '"') quote='"' ;;
    esac
  done
  [ -z "$quote" ] && [ "$escaped" -eq 0 ]
}

# True when <name> is expanded at least once in <command> and every expansion
# ($name, ${name}) sits inside double quotes, where the shell neither splits
# nor globs the value. Any other parameter form (${name:-x}, ${name/a/b}), a
# command substitution or backtick (whose quoting starts over inside), or a
# heredoc (whose body quoting this scan cannot follow) returns 1.
scope_var_uses_double_quoted() {
  local name="${1:-}" text="${2:-}" i ch quote="" escaped=0 uses=0 rest next
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  case "$text" in *'<<'*|*'$('*|*$'\140'*) return 1 ;; esac
  for ((i = 0; i < ${#text}; i++)); do
    ch="${text:i:1}"
    if [ "$escaped" -eq 1 ]; then escaped=0; continue; fi
    if [ "$quote" = "'" ]; then
      [ "$ch" = "'" ] && quote=""
      continue
    fi
    case "$ch" in
      \\) escaped=1 ;;
      "'") [ "$quote" = '"' ] || quote="'" ;;
      '"') if [ "$quote" = '"' ]; then quote=""; else quote='"'; fi ;;
      '$')
        rest="${text:$((i + 1))}"
        if [[ "$rest" == "{$name}"* ]]; then
          [ "$quote" = '"' ] || return 1
          uses=$((uses + 1))
        elif [[ "$rest" == "{$name"* ]]; then
          return 1
        elif [[ "$rest" == "$name"* ]]; then
          next="${rest:${#name}:1}"
          case "$next" in
            [A-Za-z0-9_]) ;;
            *) [ "$quote" = '"' ] || return 1; uses=$((uses + 1)) ;;
          esac
        fi
        ;;
    esac
  done
  [ "$uses" -gt 0 ]
}

# True when the <calls> plain call statements counted for <name> are the only
# way the command can run it. Any other mention of the name (a subshell, a
# substitution, quotes, an escape, an alias or assignment, a string run by
# eval, trap, or a nested shell), a command word built from an expansion, a
# glob, or a brace list, eval, source, `.`, or set -a can call it with other words.
scope_function_calls_all_visible() {
  local name="${1:-}" text="${2:-}" calls="${3:-0}" tokens defs nl=$'\n' backtick=$'\140' re cmd_pos word
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  defs="$(printf '%s' "$text" | grep -oE "(^|[^A-Za-z0-9_./-])${name}[[:space:]]*\(\)|(^|[^A-Za-z0-9_])function[[:space:]]+${name}([^A-Za-z0-9_./-]|\$)" 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ "${defs:-0}" -gt 0 ] || return 1
  tokens="$(printf '%s' "$text" | tr -d '\\"'"'" | tr -c 'A-Za-z0-9_./-' '\n' | grep -cxF -- "$name" 2>/dev/null || true)"
  [ "$tokens" = "$((calls + defs))" ] || return 1
  re='(^|[^A-Za-z0-9_.-])(eval|source|allexport)([^A-Za-z0-9_]|$)'
  [[ "$text" =~ $re ]] && return 1
  re='(^|[^A-Za-z0-9_.-])set([[:space:]]+[-+][A-Za-z]+)*[[:space:]]+-[A-Za-z]*a'
  [[ "$text" =~ $re ]] && return 1
  re='(^|[;&|(){'"$nl"'])[[:space:]]*\.[[:space:]]'
  [[ "$text" =~ $re ]] && return 1
  cmd_pos='[;&|(!'"$backtick$nl"']|\{[[:space:]]'
  re='(^|[^A-Za-z0-9_])case[[:space:]]'
  [[ "$text" =~ $re ]] && cmd_pos="$cmd_pos"'|\)'
  word='[^[:space:];&|()<>=]*'
  re='(^|'"$cmd_pos"'|(^|[^A-Za-z0-9_])(do|then|else|elif|if|while|until|time))[[:space:]]*([A-Za-z_][A-Za-z0-9_]*\+?=[^[:space:];&|]*[[:space:]]+)*('"$word"'[$*?'"$backtick"']|'"$word"'\[[^][:space:]]*\]|'"$word"'\{[^[:space:]]*\})'
  [[ "$text" =~ $re ]] && return 1
  return 0
}

# A loop word whose glob matches nothing stays the word as typed in bash
# (with nullglob the body never runs). The kernel cannot walk through a
# component spelled `*`, so the path names nothing; print the word with every
# glob character replaced by `_`, a name that must not exist either, so the
# caller checks a literal path at the same depth (a `..` after it is still
# resolved and checked). Arguments: <word> [cwd for a relative word].
scope_glob_nomatch_value() {
  local word="${1:-}" cwd="${2:-}" placeholder
  case "$word" in *[!A-Za-z0-9._/@+*?-]*|*'..'*) return 1 ;; esac
  placeholder="${word//[*?]/_}"
  case "$placeholder" in
    /*) [ ! -e "$placeholder" ] && [ ! -L "$placeholder" ] || return 1 ;;
    *) [ -n "$cwd" ] && [ ! -e "$cwd/$placeholder" ] && [ ! -L "$cwd/$placeholder" ] || return 1 ;;
  esac
  printf '%s\n' "$placeholder"
}

scope_shell_variable_values() {
  local name="${1:-}" prefix="${2:-}" command_text="${3:-}" loop_re assignment_re command_prefix_re
  local raw value command_prefix function_name function_re function_keyword_re statement call_text position call_count call_occurrences loop_match loop_pre
  local function_body shift_re set_re set_ok_re call_pipe_in_re call_heredoc_re call_input_re call_pipe_out_re
  local -a values=() statements=() call_args=()
  [ -n "$name" ] || return 1

  if [[ "$name" =~ ^[1-9]$ ]]; then
    function_re='(^|[;[:space:]])([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\)[[:space:]]*\{[^}]*$'
    function_keyword_re='(^|[;[:space:]])function[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+\{[^}]*$'
    if [[ "$prefix" =~ $function_re ]]; then
      function_name="${BASH_REMATCH[2]}"
    elif [[ "$prefix" =~ $function_keyword_re ]]; then
      function_name="${BASH_REMATCH[2]}"
    else
      return 1
    fi
    # `shift` or `set -- x` in the body before the use moves the positional
    # parameters off the call-site words, so word N is no longer $N. `set`
    # with only option words (`set -e`, `set -o pipefail`) leaves them alone.
    function_body="${BASH_REMATCH[0]}"
    function_body="${function_body#*\{}"
    shift_re='(^|[;&|({[:space:]])shift([[:space:]]|;|$)'
    [[ "$function_body" =~ $shift_re ]] && return 1
    set_ok_re='(^|[;&|({[:space:]])set(([[:space:]]+[-+][A-Za-z]+)|([[:space:]]+[-+][A-Za-z]*o[[:space:]]+[A-Za-z]+))*[[:space:]]*(;|&|\||$)'
    while [[ "$function_body" =~ $set_ok_re ]]; do
      function_body="${function_body/"${BASH_REMATCH[0]}"/;}"
    done
    set_re='(^|[;&|({[:space:]])set([[:space:]]|;|$)'
    [[ "$function_body" =~ $set_re ]] && return 1
    # A call fed by a pipe, reading a literal file, or reading a heredoc
    # (`printf x | w a`, `w a < /dev/null`, `w a <<'EOF'`) still binds its
    # positional parameters to its literal words. Those parts are dropped
    # before the call is matched. A second call hidden on the other side of
    # the pipe or in the heredoc body is still counted below, so the call
    # count no longer matches and the value stays unresolved.
    call_pipe_in_re="^([^|&]*[^|&[:space:]])[[:space:]]*\\|[[:space:]]*(${function_name}([[:space:]].*)?)\$"
    call_heredoc_re="^([^<]*[^<[:space:]])[[:space:]]*<<-?[[:space:]]*[\"']?[A-Za-z_][A-Za-z0-9_]*[\"']?([[:space:]].*)?\$"
    call_input_re="^([^<]*[^<[:space:]])[[:space:]]*<[[:space:]]*[A-Za-z0-9._/-]+[[:space:]]*\$"
    call_pipe_out_re="^([^|]*[^|[:space:]])[[:space:]]*\\|[[:space:]]*[^|&[:space:]].*\$"
    position="$name"
    call_count=0
    IFS=';' read -r -a statements <<< "$command_text"
    for statement in "${statements[@]}"; do
      while [[ "$statement" == [[:space:]]* || "$statement" == '}'* ]]; do
        statement="${statement#?}"
      done
      if [[ "$statement" =~ $call_pipe_in_re ]]; then statement="${BASH_REMATCH[2]}"; fi
      [[ "$statement" =~ ^${function_name}([[:space:]]|$) ]] || continue
      if [[ "$statement" =~ $call_heredoc_re ]]; then statement="${BASH_REMATCH[1]}"; fi
      if [[ "$statement" =~ $call_input_re ]]; then statement="${BASH_REMATCH[1]}"; fi
      if [[ "$statement" =~ $call_pipe_out_re ]]; then statement="${BASH_REMATCH[1]}"; fi
      [[ "$statement" =~ ^${function_name}([[:space:]]+(.*))?$ ]] || continue
      call_text="${BASH_REMATCH[2]:-}"
      [ -n "$call_text" ] || return 1
      [[ "$call_text" =~ ^[A-Za-z0-9._/-]+([[:space:]]+[A-Za-z0-9._/-]+)*[[:space:]]*$ ]] || return 1
      read -r -a call_args <<< "$call_text"
      [ "${#call_args[@]}" -ge "$position" ] || return 1
      values[${#values[@]}]="${call_args[$((position - 1))]}"
      call_count=$((call_count + 1))
    done
    [ "$call_count" -gt 0 ] || return 1
    call_occurrences="$(printf '%s' "$command_text" | grep -oE "(^|[;[:space:]])${function_name}([[:space:]]|$)" 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
    [ "$call_occurrences" = "$call_count" ] || return 1
    scope_function_calls_all_visible "$function_name" "$command_text" "$call_count" || return 1
    printf '%s\n' "${values[@]}"
    return 0
  fi

  command_prefix_re='^[A-Za-z0-9_./:+@=-]+([[:space:]]+[A-Za-z0-9_./:+@=-]+)*[[:space:]]*$'
  # A loop nested directly in another loop's body (`for b in a b; do for
  # ext in png jpg; do cp src/$b.$ext ...`) starts after `do`; the inner
  # list is as literal as the outer one, so both bind the same way.
  loop_re="(^|[;&"$'\n'"][[:space:]]*|[;&"$'\n'"[:space:]]do[[:space:]]+)for[[:space:]]+${name}[[:space:]]+in[[:space:]]+([^;|&]+);[[:space:]]*do[[:space:]]+(.*)$"
  if [[ "$prefix" =~ $loop_re ]]; then
    loop_match="${BASH_REMATCH[0]}"
    loop_pre="${prefix%%"$loop_match"*}"
    scope_shell_prefix_is_unquoted "$loop_pre" || return 1
    raw="${BASH_REMATCH[2]}"
    command_prefix="${BASH_REMATCH[3]}"
    # The loop body before the use may be any commands (`echo "== $f"; cp
    # "workspace/reports/$f" ...`), as long as nothing in the whole command
    # can give the loop variable a value other than a list word: no second
    # `for name`, no `name=`, and none of the builtins that bind names.
    if ! [[ "$command_prefix" =~ $command_prefix_re ]]; then
      local loop_count loop_bind_re
      loop_count="$(printf '%s' "$command_text" | grep -oE "(^|[^A-Za-z0-9_])(for|select)[[:space:]]+${name}([[:space:]]|;|\$)" 2>/dev/null | wc -l | tr -d '[:space:]')"
      [ "$loop_count" = "1" ] || return 1
      local loop_dq
      loop_dq="$(scope_dequote_text "$command_text")"
      scope_text_has_ansi_escape "$command_text" && return 1
      scope_text_touches_ifs "$command_text" && return 1
      loop_count="$(printf '%s' "$loop_dq" | grep -oE "(^|[^A-Za-z0-9_])(for|select)[[:space:]]+${name}([[:space:]]|;|\$)" 2>/dev/null | wc -l | tr -d '[:space:]')"
      [ "$loop_count" = "1" ] || return 1
      loop_bind_re="(^|[^A-Za-z0-9_\$])${name}(\[[^]]*\])?\+?="
      [[ "$command_text" =~ $loop_bind_re || "$loop_dq" =~ $loop_bind_re ]] && return 1
      loop_bind_re='(^|[^A-Za-z0-9_.-])(read|mapfile|readarray|getopts|eval|source|declare|typeset|local|unset|let|export)([[:space:]]|$)'
      [[ "$command_text" =~ $loop_bind_re || "$loop_dq" =~ $loop_bind_re ]] && return 1
      loop_bind_re='printf[[:space:]]+-v|\$\{'"$name"':?='
      [[ "$command_text" =~ $loop_bind_re || "$loop_dq" =~ $loop_bind_re ]] && return 1
      loop_bind_re='(^|[;&|({]|'$'\n'')[[:space:]]*\.[[:space:]]'
      [[ "$command_text" =~ $loop_bind_re || "$loop_dq" =~ $loop_bind_re ]] && return 1
    fi
    [[ "$command_prefix" =~ (^|[[:space:]])${name}= ]] && return 1
    case "$command_prefix" in
      *"-v $name"*|*"read $name"*|*"declare $name"*|*"local $name"*|*"unset $name"*|*"eval"*|*"source "*) return 1 ;;
    esac
    # `. FILE` sources a script that can rebind the loop variable, but only
    # when `.` is the command word. A `.` argument (`jq . "$f"`, `find . -name
    # x`) is data and must not refuse the loop.
    local dot_source_re='(^|[;&|({!'$'\n'']|(^|[^A-Za-z0-9_./-])(do|then|else|elif|time|command|builtin|exec))[[:space:]]*\.[[:space:]]'
    [[ "$command_prefix" =~ $dot_source_re ]] && return 1
    # `for r in $(ls [-1|-A] DIR)` binds r to the entry names in DIR, the
    # same set `DIR/*` would give. DIR must be one literal directory inside
    # the HQ root that this session may read (it is checked here as an
    # operand), and every entry name must be a plain word; ls prints bare
    # names, so a value never contains a slash. Any other ls option (-a
    # adds `.` and `..`, -R and -d change what is printed), a pipe, or a
    # second operand is not matched and the loop stays unresolved.
    local ls_re='^\$\(ls([[:space:]]+-(1|A|1A|A1))?[[:space:]]+([A-Za-z0-9._/@+-]+)\)[[:space:]]*$'
    if [[ "$raw" =~ $ls_re ]]; then
      local ls_flag="${BASH_REMATCH[2]}" ls_dir="${BASH_REMATCH[3]}" ls_abs ls_rel ls_entry ls_count=0
      case "$ls_dir" in -*|*'..'*) return 1 ;; esac
      case "$ls_dir" in
        /*) ls_abs="$ls_dir" ;;
        *)
          [ "$(cd "${COMMAND_CWD:-$HQ_ROOT}" 2>/dev/null && pwd -P)" = "$HQ_ROOT" ] || return 1
          ls_abs="$HQ_ROOT/$ls_dir"
          ;;
      esac
      [ -d "$ls_abs" ] || return 1
      ls_rel="$(scope_normalize_hq_relative "$ls_abs")"
      [ -n "$ls_rel" ] || return 1
      scope_rel_allowed "$ls_rel" || return 1
      while IFS= read -r ls_entry; do
        [ -n "$ls_entry" ] || continue
        case "$ls_entry" in .|..|*[!A-Za-z0-9._@+-]*) return 1 ;; esac
        ls_count=$((ls_count + 1))
        [ "$ls_count" -le 2048 ] || return 1
        printf '%s\n' "$ls_entry"
      done < <(cd "$HQ_ROOT/$ls_rel" 2>/dev/null && { [ -z "$ls_flag" ] || [ "$ls_flag" = 1 ] || shopt -s dotglob; } && compgen -G '*' || true)
      [ "$ls_count" -gt 0 ] || return 1
      return 0
    fi
    # `for d in $(ls -d workspace/x/*)` binds d to the paths the glob
    # matches, spelled as the glob spells them (ls -d prints each operand as
    # given). The same entries `for d in workspace/x/*` would give; each is
    # printed and checked by the caller as a literal path (feedback
    # 2ec4335f, a33f359b). A `| head -N` / `| tail -N` cut only narrows the
    # set, so the full set is checked.
    local sub_body="" sub_glob
    case "$raw" in
      '$('*')')
        sub_body="${raw#\$(}"
        sub_body="${sub_body%)}"
        ;;
    esac
    if [ -n "$sub_body" ] && sub_glob="$(scope_ls_d_glob_operand "$sub_body")"; then
      scope_ls_d_checked_paths "$sub_body" || return 1
      return 0
    fi
    # `for f in $(find workspace/logs -name '*.html')` binds f to paths
    # under the literal directory (find prints them as DIR/...; it follows
    # no symlink without -L, which is not accepted). DIR must be one
    # directory the session may read, inside the HQ root or absolute; the
    # validated predicates are run here, capped, and every path is printed
    # for the caller to check as a literal (feedback b625002d, 41420292).
    if [ -n "$sub_body" ] && scope_find_body_is_bounded "$sub_body" >/dev/null; then
      scope_find_bounded_paths "$sub_body" || return 1
      return 0
    fi
    if [ -n "$sub_body" ] && scope_grep_l_paths "$sub_body" >/dev/null; then
      local grep_l_values
      grep_l_values="$(scope_grep_l_paths "$sub_body")" || return 1
      [ -n "$grep_l_values" ] || return 1
      printf '%s\n' "$grep_l_values"
      return 0
    fi
    IFS=$' \t\n' read -r -a values <<< "$raw"
    [ "${#values[@]}" -gt 0 ] || return 1
    # A literal numeric range word (`for d in {01..31}`, `day-{1..7}`) is
    # expanded here the way bash does it, including zero padding, so each
    # value is checked below as a plain word. Only one range per word, plain
    # word characters around it, and at most 2048 values; anything else
    # keeps the braces and is refused by the word check.
    local -a range_values=()
    local range_re='^([A-Za-z0-9._/-]*)\{(-?[0-9]{1,6})\.\.(-?[0-9]{1,6})\}([A-Za-z0-9._/-]*)$'
    local range_word range_lo range_hi range_width range_step range_i range_n range_pre range_post
    for range_word in "${values[@]}"; do
      if [[ "$range_word" =~ $range_re ]]; then
        range_pre="${BASH_REMATCH[1]}"; range_post="${BASH_REMATCH[4]}"
        range_lo="${BASH_REMATCH[2]}"; range_hi="${BASH_REMATCH[3]}"
        range_width=0
        if [[ "$range_lo" =~ ^-?0[0-9] ]] || [[ "$range_hi" =~ ^-?0[0-9] ]]; then
          range_width="${#range_lo}"
          [ "${#range_hi}" -gt "$range_width" ] && range_width="${#range_hi}"
        fi
        range_lo=$((10#${range_lo#-} * ${range_lo%%[0-9]*}1))
        range_hi=$((10#${range_hi#-} * ${range_hi%%[0-9]*}1))
        range_step=1; [ "$range_lo" -gt "$range_hi" ] && range_step=-1
        range_n=$(( (range_hi - range_lo) * range_step + 1 ))
        [ "$range_n" -le 2048 ] || return 1
        range_i="$range_lo"
        while :; do
          range_values[${#range_values[@]}]="$range_pre$(printf "%0${range_width}d" "$range_i")$range_post"
          [ "$range_i" = "$range_hi" ] && break
          range_i=$((range_i + range_step))
        done
      else
        range_values[${#range_values[@]}]="$range_word"
      fi
    done
    values=("${range_values[@]}")
    local glob_match glob_count=0 glob_cwd glob_abs
    for value in "${values[@]}"; do
      # A loop word that globs an absolute directory outside HQ (`for d in
      # ~/.claude/scheduled-tasks/*/`, `/tmp/runs/*`) expands to the entries
      # it matches now. Each one is printed as an absolute path and checked
      # by the caller like a literal, so a match that resolves into
      # companies/ still needs the lock (feedback 0ed4e446). `~` and $HOME
      # are the caller's home unless the command reassigns it; a word with
      # `..`, an unmatched glob, or an odd character stays unresolved.
      glob_abs=""
      case "$value" in
        '~/'*) glob_abs="${HOME:-}/${value#\~/}" ;;
        '$HOME/'*) glob_abs="${HOME:-}/${value#\$HOME/}" ;;
        '${HOME}/'*) glob_abs="${HOME:-}/${value#\$\{HOME\}/}" ;;
        /*) glob_abs="$value" ;;
      esac
      if [ -n "$glob_abs" ] && [[ "$glob_abs" == *[*?]* ]] && [[ "$glob_abs" != *'..'* ]] \
        && [[ "$glob_abs" =~ ^/[A-Za-z0-9._/@+*?-]*$ ]] \
        && [[ "${HOME:-}" == /* ]] && ! scope_command_may_set_var HOME "$command_text"; then
        # Every match is substituted and checked by the caller as a literal
        # path (a symlink is resolved there), so only a glob over the tenant
        # tree itself is refused here outright.
        case "$glob_abs" in
          "$HQ_ROOT/companies"|"$HQ_ROOT/companies/"*) return 1 ;;
        esac
        glob_count=0
        while IFS= read -r glob_match; do
          [ -n "$glob_match" ] || continue
          case "$glob_match" in *[!A-Za-z0-9._/@+-]*|*'..'*) return 1 ;; esac
          glob_count=$((glob_count + 1))
          [ "$glob_count" -le 2048 ] || return 1
          printf '%s\n' "$glob_match"
        done < <(compgen -G "$glob_abs" || true)
        [ "$glob_count" -gt 0 ] || return 1
        continue
      fi
      # A loop word that globs an open HQ tree (`for d in workspace/x/*`)
      # expands to the existing entries it matches. Enumerate them here so
      # each one is checked as a literal path; anything else stays refused.
      if [[ "$value" =~ ^(workspace|core|personal|repos)/[A-Za-z0-9._/*?-]*$ ]] \
        && [[ "$value" == *[*?]* ]] && [[ "$value" != *'..'* ]]; then
        glob_cwd="${COMMAND_CWD:-$HQ_ROOT}"
        [ "$(cd "$glob_cwd" 2>/dev/null && pwd -P)" = "$HQ_ROOT" ] || return 1
        while IFS= read -r glob_match; do
          [ -n "$glob_match" ] || continue
          case "$glob_match" in *[!A-Za-z0-9._/@+-]*|*'..'*) return 1 ;; esac
          glob_count=$((glob_count + 1))
          [ "$glob_count" -le 2048 ] || return 1
          printf '%s\n' "$glob_match"
        done < <(cd "$glob_cwd" && compgen -G "$value" || true)
        [ "$glob_count" -gt 0 ] || return 1
        continue
      fi
      # A loop word that globs the tenant tree (`for d in companies/*/knowledge`,
      # `for f in companies/indigo/people/*/meta.yaml`) expands to the entries
      # it matches now (feedback 36c3e8cb). A glob in the company segment is
      # accepted only when every tenant folder that segment matches is locked
      # to this session, whether or not the rest of the path exists there, so
      # in a multi-company HQ `companies/*/x` stays refused. Each match is then
      # printed and checked by the caller as a literal path (symlinks resolved
      # there), so a match that resolves into another tenant still blocks.
      if [[ "$value" =~ ^companies/[A-Za-z0-9._/*?-]*$ ]] \
        && [[ "$value" == *[*?]* ]] && [[ "$value" != *'..'* ]] && [[ "$value" != *'**'* ]]; then
        glob_cwd="${COMMAND_CWD:-$HQ_ROOT}"
        [ "$(cd "$glob_cwd" 2>/dev/null && pwd -P)" = "$HQ_ROOT" ] || return 1
        # The lock set loads lazily; the inline-program and -C option scans
        # can reach this before any company path has loaded it. A `**` word
        # is refused: zsh recurses through symlinks there, bash compgen does not.
        scope_load_bound_company
        local loop_co_segment="${value#companies/}" loop_co_word
        loop_co_segment="${loop_co_segment%%/*}"
        [ -n "$loop_co_segment" ] || return 1
        if [[ "$loop_co_segment" == *[*?]* ]]; then
          scope_expand_company_segment_glob "$value" "$loop_co_segment" || return 1
          for loop_co_word in ${scope_glob_words[@]+"${scope_glob_words[@]}"}; do
            loop_co_word="${loop_co_word#companies/}"
            scope_company_is_locked "${loop_co_word%%/*}" || return 1
          done
        else
          scope_company_is_locked "$loop_co_segment" || return 1
        fi
        while IFS= read -r glob_match; do
          [ -n "$glob_match" ] || continue
          case "$glob_match" in *[!A-Za-z0-9._/@+-]*|*'..'*) return 1 ;; esac
          glob_count=$((glob_count + 1))
          [ "$glob_count" -le 2048 ] || return 1
          printf '%s\n' "$glob_match"
        done < <(cd "$glob_cwd" && compgen -G "$value" || true)
        [ "$glob_count" -gt 0 ] || return 1
        continue
      fi
      case "$value" in
        ""|*[!A-Za-z0-9._/-]*) return 1 ;;
      esac
      printf '%s\n' "$value"
    done
    return 0
  fi

  # `local d="personal/skills/$1"` in a function body binds d to literal
  # text around one positional parameter. Resolve d through that
  # positional's literal call sites, only when the local is an unconditional
  # statement of the function the use is in, d is assigned nowhere else in
  # the command, and nothing in the command can rebind it.
  local fn_local_re local_re local_match local_before local_count local_bind_re
  local local_head local_pos local_tail local_values local_value
  fn_local_re='(^|[;[:space:]])([A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)|function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\{[^}]*$'
  local_re='(^|[;'$'\n''])[[:space:]]*local[[:space:]]+'"$name"'=("([A-Za-z0-9._/-]*)\$\{?([1-9])\}?([A-Za-z0-9._/-]*)"|([A-Za-z0-9._/-]*)\$\{?([1-9])\}?([A-Za-z0-9._/-]*))[[:space:]]*(;|'$'\n'')'
  if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && [[ "$prefix" =~ $fn_local_re ]]; then
    local_match="${BASH_REMATCH[0]}"
    local_match="${local_match#*\{}"
    if [[ "$local_match" =~ $local_re ]]; then
      local_head="${BASH_REMATCH[3]}${BASH_REMATCH[6]}"
      local_pos="${BASH_REMATCH[4]}${BASH_REMATCH[7]}"
      local_tail="${BASH_REMATCH[5]}${BASH_REMATCH[8]}"
      local_before="${local_match%%"${BASH_REMATCH[0]}"*}"
      local_bind_re='(^|[;&|[:space:]])(if|then|else|elif|while|until|for|select|case|do)([[:space:]]|;|$)|&&|\|\||[({]'
      [[ "$local_before" =~ $local_bind_re ]] && return 1
      local_count="$(printf '%s' "$command_text" | grep -oE "(^|[^A-Za-z0-9_\$])${name}(\[[^]]*\])?\+?=" 2>/dev/null | wc -l | tr -d '[:space:]')"
      [ "$local_count" = "1" ] || return 1
      local local_dq
      local_dq="$(scope_dequote_text "$command_text")"
      scope_text_has_ansi_escape "$command_text" && return 1
      scope_text_touches_ifs "$command_text" && return 1
      local_count="$(printf '%s' "$local_dq" | grep -oE "(^|[^A-Za-z0-9_\$])${name}(\[[^]]*\])?\+?=" 2>/dev/null | wc -l | tr -d '[:space:]')"
      [ "$local_count" = "1" ] || return 1
      local_bind_re='(^|[^A-Za-z0-9_.-])(read|mapfile|readarray|getopts|eval|source|declare|typeset|unset|let|export)([[:space:]]|$)'
      [[ "$command_text" =~ $local_bind_re || "$local_dq" =~ $local_bind_re ]] && return 1
      local_bind_re='printf[[:space:]]+-v|\$\{'"$name"':?=|(^|[;&|({[:space:]])(for|select)[[:space:]]+'"$name"'([[:space:]]|;|$)'
      [[ "$command_text" =~ $local_bind_re || "$local_dq" =~ $local_bind_re ]] && return 1
      local_bind_re='(^|[;&|({]|'$'\n'')[[:space:]]*\.[[:space:]]'
      [[ "$command_text" =~ $local_bind_re || "$local_dq" =~ $local_bind_re ]] && return 1
      local_values="$(scope_shell_variable_values "$local_pos" "$prefix" "$command_text")" || return 1
      [ -n "$local_values" ] || return 1
      while IFS= read -r local_value; do
        [ -n "$local_value" ] || return 1
        printf '%s\n' "$local_head$local_value$local_tail"
      done <<< "$local_values"
      return 0
    fi
  fi

  # A backslash-escaped space in an unquoted literal (`APP=/Applications/Scroll\
  # Reverser.app; ls "$APP/Contents"`) is one word with a space in it. It is
  # accepted only when every use of the name is double-quoted, so the value
  # is never split or globbed (feedback c030dfe5).
  local esc_assignment_re="^[[:space:]]*${name}=((\\\\ |[A-Za-z0-9_./@+,-])+);[[:space:]]*(.*)$"
  if [[ "$prefix" =~ $esc_assignment_re ]] && [[ "${BASH_REMATCH[1]}" == *'\ '* ]]; then
    raw="${BASH_REMATCH[1]}"
    command_prefix="${BASH_REMATCH[3]}"
    raw="${raw//\\ / }"
    case "$raw" in ""|' '*|*' '|*[!A-Za-z0-9_./@+,\ -]*|*'..'*) return 1 ;; esac
    local esc_count
    esc_count="$(printf '%s' "$command_text" | grep -oE "(^|[^A-Za-z0-9_\$])${name}(\[[^]]*\])?\+?=" 2>/dev/null | wc -l | tr -d '[:space:]')"
    [ "$esc_count" = "1" ] || return 1
    local esc_bind_re='(^|[^A-Za-z0-9_.-])(read|mapfile|readarray|getopts|eval|source|declare|typeset|local|unset|let|export|for|select)([[:space:]]|$)|printf[[:space:]]+-v'
    [[ "$command_text" =~ $esc_bind_re ]] && return 1
    scope_var_uses_double_quoted "$name" "$command_text" || return 1
    printf '%s\n' "$raw"
    return 0
  fi
  assignment_re="^[[:space:]]*${name}=([^[:space:];|&]+);[[:space:]]*(.*)$"
  if [[ "$prefix" =~ $assignment_re ]]; then
    raw="${BASH_REMATCH[1]}"
    command_prefix="${BASH_REMATCH[2]}"
    if [[ "$command_prefix" =~ $command_prefix_re ]]; then
      [[ "$command_prefix" =~ (^|[[:space:]])${name}= ]] && return 1
      case "$raw" in
        \"*) raw="${raw#\"}"; raw="${raw%\"}" ;;
        \'*) raw="${raw#\'}"; raw="${raw%\'}" ;;
      esac
      # A comma is an ordinary filename character and a common list
      # separator in option values (`F=headRefOid,title; gh ... --json $F`).
      # Brace expansion, the one place a comma changes a word, is refused
      # separately (no `{` or `}` passes this class).
      case "$raw" in
        ""|*[!A-Za-z0-9_./@+,-]*) return 1 ;;
      esac
      printf '%s\n' "$raw"
      return 0
    fi
  fi
  # `B=$(ls -t workspace/reports | head -1); sed -n 1,20p "workspace/reports/$B"`
  # binds B to one entry name of DIR (ls prints bare names, never a slash),
  # the same set a `for b in $(ls DIR)` loop gets. The assignment must open
  # the command, be the only way B is set, and DIR must be one literal
  # directory the session may read. Each entry is printed for the caller to
  # check as a literal path (feedback d6e51a0e, 046fcf07).
  local lsa_re="^[[:space:]]*${name}=(\"?)\\\$\\(ls(([[:space:]]+-[1trSA]+)*)[[:space:]]+([A-Za-z0-9._/@+-]+)([[:space:]]*\\|[[:space:]]*(head|tail)([[:space:]]+-n)?[[:space:]]+-?[0-9]+)?\\)(\"?)[[:space:]]*(;|&&)"
  if [[ "$prefix" =~ $lsa_re ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[8]}" ]; then
    local lsa_match="${BASH_REMATCH[0]}" lsa_flags="${BASH_REMATCH[2]}" lsa_dir="${BASH_REMATCH[4]}" lsa_abs lsa_rel lsa_entry lsa_count=0 lsa_dq lsa_bind_re
    case "$lsa_dir" in -*|*'..'*) return 1 ;; esac
    lsa_count="$(printf '%s' "$command_text" | grep -oE "(^|[^A-Za-z0-9_\$])${name}(\[[^]]*\])?\+?=" 2>/dev/null | wc -l | tr -d '[:space:]')"
    [ "$lsa_count" = "1" ] || return 1
    lsa_dq="$(scope_dequote_text "$command_text")"
    scope_text_has_ansi_escape "$command_text" && return 1
    scope_text_touches_ifs "$command_text" && return 1
    lsa_count="$(printf '%s' "$lsa_dq" | grep -oE "(^|[^A-Za-z0-9_\$])${name}(\[[^]]*\])?\+?=" 2>/dev/null | wc -l | tr -d '[:space:]')"
    [ "$lsa_count" = "1" ] || return 1
    lsa_bind_re='(^|[^A-Za-z0-9_.-])(read|mapfile|readarray|getopts|eval|source|declare|typeset|local|unset|let|export)([[:space:]]|$)'
    [[ "$command_text" =~ $lsa_bind_re || "$lsa_dq" =~ $lsa_bind_re ]] && return 1
    lsa_bind_re='printf[[:space:]]+-v|\$\{'"$name"':?=|(^|[^A-Za-z0-9_])(for|select)[[:space:]]+'"$name"'([[:space:]]|;|$)'
    [[ "$command_text" =~ $lsa_bind_re || "$lsa_dq" =~ $lsa_bind_re ]] && return 1
    lsa_bind_re='(^|[;&|({]|'$'\n'')[[:space:]]*\.[[:space:]]'
    [[ "$command_text" =~ $lsa_bind_re || "$lsa_dq" =~ $lsa_bind_re ]] && return 1
    scope_command_may_create_entries "${command_text#*"$lsa_match"}" && return 1
    case "$lsa_dir" in
      /*) lsa_abs="$lsa_dir" ;;
      *)
        [ "$(cd "${COMMAND_CWD:-$HQ_ROOT}" 2>/dev/null && pwd -P)" = "$HQ_ROOT" ] || return 1
        lsa_abs="$HQ_ROOT/$lsa_dir"
        ;;
    esac
    lsa_rel="$(scope_normalize_hq_relative "$lsa_abs")"
    [ -n "$lsa_rel" ] || return 1
    scope_rel_allowed "$lsa_rel" || return 1
    # A missing DIR (or an empty one) makes ls print nothing, so B is empty
    # and the use names DIR itself; `.` stands for that here.
    if [ ! -e "$lsa_abs" ] && [ ! -L "$lsa_abs" ]; then
      printf '.\n'
      return 0
    fi
    [ -d "$lsa_abs" ] || return 1
    lsa_count=0
    while IFS= read -r lsa_entry; do
      [ -n "$lsa_entry" ] || continue
      case "$lsa_entry" in .|..|*[!A-Za-z0-9._@+-]*) return 1 ;; esac
      lsa_count=$((lsa_count + 1))
      [ "$lsa_count" -le 2048 ] || return 1
      printf '%s\n' "$lsa_entry"
    done < <(cd "$lsa_abs" 2>/dev/null && { [[ "$lsa_flags" != *A* ]] || shopt -s dotglob; } && compgen -G '*' || true)
    [ "$lsa_count" -gt 0 ] || printf '.\n'

    return 0
  fi
  # The use is not a plain word list after the assignment (a redirect, a
  # heredoc, quotes: `CO=indigo; cat > companies/$CO/x <<'EOF'`). Accept the
  # value only under the stricter run-order rules of
  # scope_assignment_literal_value, and only as one plain word, so the caller
  # checks the substituted path exactly as if it had been typed (a value
  # naming another company, or climbing out with `..`, is still refused there).
  local assignment_value
  assignment_value="$(scope_assignment_literal_value "$name" "$prefix" "$command_text")" || return 1
  value="${assignment_value##*$'\037'}"
  case "$value" in
    ""|*[!A-Za-z0-9_./@+,-]*) return 1 ;;
  esac
  printf '%s\n' "$value"
}

scope_candidate_is_inert_text() {
  local candidate="${1:-}" command_text="${2:-}" prefix="${3:-}" suffix="${4:-}"
  local segment="" masked_segment="" output_re redirection_re data_option_re backtick text_option_re command_head pr_wrapper_re
  [ -n "$candidate" ] || return 1
  backtick=$'\140'
  # Only a standalone echo/printf is inert. A pipe, redirect, command
  # separator, or substitution can feed or execute the printed path.
  masked_segment="$(scope_mask_literal_expansions "$command_text")"
  case "$masked_segment" in *';'*|*'|'*|*'&'*|*'<'*|*'>'*|*'$('*|*"$backtick"*|*$'\n'*) return 1 ;; esac
  # Quoted message values are data only for commands whose option contract
  # identifies them as text. Keep arbitrary programs and file options checked.
  data_option_re="(^|[[:space:]])(--text|--title|--body|--message|--comment)(=|[[:space:]])(\"[^\"]*$|'[^']*$)"
  command_head="${command_text#"${command_text%%[![:space:]]*}"}"
  case "$command_head" in
    'hq dm '*) text_option_re="$data_option_re" ;;
    'hq lanes message '*|'hq lanes link report '*) text_option_re="$data_option_re" ;;
    'hq mesh '* )
      if [[ "$command_head" =~ ^hq[[:space:]]+mesh[[:space:]]+[^[:space:]]+[[:space:]]+note([[:space:]]|$) ]]; then
        text_option_re="$data_option_re"
      fi
      ;;
    'gh pr create '*|'gh pr comment '*|'gh pr edit '*|'gh issue create '*|'gh issue comment '*|'gh issue edit '*)
      text_option_re="(^|[[:space:]])(--title|--body)(=|[[:space:]])(\"[^\"]*$|'[^']*$)" ;;
    *) text_option_re="" ;;
  esac
  # The gh pr create wrapper gets the gh pr create rule under any path form:
  # bash/sh/zsh or direct execution, relative, ./, or absolute (quoted or not).
  pr_wrapper_re='^((bash|sh|zsh)[[:space:]]+)?"?([^[:space:]"]*/)?core/scripts/hq-pr-create\.sh"?[[:space:]]'
  if [[ "$command_head" =~ $pr_wrapper_re ]]; then
    # An existing script at another absolute path is a different program
    # that may open its --title value (feedback_ef130236); only the in-tree
    # script (or a path that does not exist, which runs nothing) keeps it.
    local pr_wrapper_path="${BASH_REMATCH[3]}core/scripts/hq-pr-create.sh"
    case "$pr_wrapper_path" in
      '$HQ_ROOT/'*) pr_wrapper_path="$HQ_ROOT/${pr_wrapper_path#'$HQ_ROOT/'}" ;;
      '${HQ_ROOT}/'*) pr_wrapper_path="$HQ_ROOT/${pr_wrapper_path#'${HQ_ROOT}/'}" ;;
      /*) ;;
      *) pr_wrapper_path="${COMMAND_CWD:-$HQ_ROOT}/$pr_wrapper_path" ;;
    esac
    # Any form that exists must be the in-tree file; one that does not exist
    # runs nothing.
    if [ -e "$pr_wrapper_path" ] && ! [ "$pr_wrapper_path" -ef "$HQ_ROOT/core/scripts/hq-pr-create.sh" ]; then
      pr_wrapper_path=""
    fi
    [ -z "$pr_wrapper_path" ] || text_option_re="(^|[[:space:]])(--title|--body)(=|[[:space:]])(\"[^\"]*$|'[^']*$)"
  fi
  [ -n "$text_option_re" ] && [[ "$prefix" =~ $text_option_re ]] && return 0
  segment="$prefix$candidate$suffix"
  output_re='^[[:space:]]*(command[[:space:]]+)?(printf|echo)([[:space:]]|$)'
  [[ "$segment" =~ $output_re ]] || return 1
  masked_segment="$(scope_mask_literal_expansions "$segment")"
  backtick=$'\140'
  case "$masked_segment" in *"$backtick"*) return 1 ;; esac
  [ "${scope_had_line_continuation:-0}" -eq 0 ] || return 1
  redirection_re='[<>]'
  [[ "$segment" =~ $redirection_re ]] && return 1
  return 0
}

scope_candidate_is_single_quoted() {
  local candidate="${1:-}" prefix="${2:-}" state=0 escaped=0 ch i
  [ -n "$candidate" ] || return 1
  for ((i = 0; i < ${#prefix}; i++)); do
    ch="${prefix:i:1}"
    if [ "$escaped" -eq 1 ]; then
      escaped=0
      continue
    fi
    if [ "$state" -eq 1 ]; then
      [ "$ch" = "'" ] && state=0
      continue
    fi
    if [ "$state" -eq 2 ]; then
      case "$ch" in
        \\\\) escaped=1 ;;
        '"') state=0 ;;
      esac
      continue
    fi
    case "$ch" in
      \\\\) escaped=1 ;;
      \') state=1 ;;
      '"') state=2 ;;
    esac
  done
  [ "$state" -eq 1 ]
}

# Expand the first plain `{a,b,...}` brace in a candidate into
# scope_brace_words. Refuses (returns 1) on nesting, quotes, backslashes,
# expansions, sequence ranges, or more than 64 words; the caller then fails
# closed. Further braces in a word are expanded by the caller's recursion.
scope_expand_simple_brace() {
  local candidate="${1:-}" brace_re pre body post item backtick=$'\140'
  local -a items=()
  scope_brace_words=()
  case "$candidate" in
    *"'"*|*'"'*|*\\*|*'$'*|*"$backtick"*) return 1 ;;
  esac
  brace_re='^([^{}]*)\{([^{}]*,[^{}]*)\}(.*)$'
  [[ "$candidate" =~ $brace_re ]] || return 1
  pre="${BASH_REMATCH[1]}"
  body="${BASH_REMATCH[2]}"
  post="${BASH_REMATCH[3]}"
  IFS=',' read -r -a items <<< "$body,"
  [ "${#items[@]}" -ge 1 ] && [ "${#items[@]}" -le 64 ] || return 1
  for item in "${items[@]}"; do
    case "$item" in *[[:space:]]*) return 1 ;; esac
    scope_brace_words[${#scope_brace_words[@]}]="$pre$item$post"
  done
  return 0
}

# Enumerate the tenant folders a glob in the company segment can match and
# rewrite the candidate once per match into scope_glob_words. Returns 1 (the
# caller fails closed) on a `..` remainder, a pattern that can match a
# dot-leading name, or when no tenant directory is left to check.
scope_expand_company_segment_glob() {
  local candidate="${1:-}" segment="${2:-}" rest match count=0 backtick=$'\140'
  scope_glob_words=()
  case "$candidate" in
    *"'"*|*'"'*|*\\*|*'$'*|*"$backtick"*|*'{'*|*'}'*) return 1 ;;
  esac
  rest="${candidate#companies/"$segment"}"
  [ -d "$HQ_ROOT/companies" ] || return 1
  # Fail closed when the remainder climbs out (`companies/_t*/../otherco`):
  # the match set is the hook's view, and a skipped or missing match must
  # never leave a `..` unchecked.
  case "$rest" in */..|*/../*) return 1 ;; esac
  # A pattern that can match a dot-leading name (`.*`, `.?`, `.[.]`, `[.]x`)
  # matches `.` and `..` under bash 3.2 (macOS /bin/bash) even where this
  # hook's bash 5.2+ skips them, so its expansion here is not authoritative.
  case "$segment" in .*|'['*) return 1 ;; esac
  while IFS= read -r match; do
    [ -n "$match" ] || continue
    match="${match##*/}"
    case "$match" in .|..) return 1 ;; esac
    count=$((count + 1))
    [ "$count" -le 512 ] || return 1
    # companies/_template/ is readable by every session and a file
    # (manifest.yaml) has no children. With no `..` in the remainder (checked
    # above) neither can lead to a tenant, so they add no word to check.
    [ "$match" = "_template" ] && [ ! -L "$HQ_ROOT/companies/_template" ] && continue
    [ -n "$rest" ] && [ ! -d "$HQ_ROOT/companies/$match" ] && continue
    scope_glob_words[${#scope_glob_words[@]}]="companies/$match$rest"
  done < <(
    cd "$HQ_ROOT/companies" 2>/dev/null || exit 1
    shopt -s nullglob dotglob nocaseglob
    compgen -G "$segment" || true
  )
  # No tenant directory to check means nothing proves the pattern safe.
  [ "${#scope_glob_words[@]}" -gt 0 ] || return 1
  return 0
}

# True when <name> is assigned exactly once in <command>, unconditionally and
# before any compound command, from a replacement that keeps only characters
# of a class without `/`: `key=${sid//[^A-Za-z0-9._-]/_}`. Its value is then
# one slash-free filename fragment whatever the source holds (feedback
# d029ab4c). Nothing may bind the name another way.
scope_var_is_sanitized_segment() {
  local name="${1:-}" text="${2:-}" re before count dq bind_re
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  re='(^|;|'$'\n'')[[:space:]]*'"$name"'=("?)\$\{[A-Za-z_][A-Za-z0-9_]*//\[\^[A-Za-z0-9._-]+\]/[A-Za-z0-9._-]*\}("?)[[:space:]]*(;|'$'\n'')'
  [[ "$text" =~ $re ]] || return 1
  [ "${BASH_REMATCH[2]}" = "${BASH_REMATCH[3]}" ] || return 1
  local cls="${BASH_REMATCH[0]#*\[^}"
  cls="${cls%%]*}"
  case "$cls" in -*) cls="${cls#-}" ;; esac
  case "$cls" in *-) cls="${cls%-}" ;; esac
  # Only the ranges A-Z, a-z and 0-9 may appear; any other `-` is a range
  # the guard does not evaluate.
  local cls_rest="${cls//A-Z/}"
  cls_rest="${cls_rest//a-z/}"
  cls_rest="${cls_rest//0-9/}"
  case "$cls_rest" in *-*) return 1 ;; esac
  before="${text%%"${BASH_REMATCH[0]}"*}"
  # Statements before the assignment must be simple: strip plain `$(...)`
  # bodies, then refuse any compound keyword, brace, parenthesis or `&&`/`||`
  # that could make the assignment conditional or move it into a function.
  local sub_re='\$\([^()]*\)'
  while [[ "$before" =~ $sub_re ]]; do
    before="${before/"${BASH_REMATCH[0]}"/x}"
  done
  case "$before" in *'('*|*')'*|*'{'*|*'}'*|*'&'*|*'|'*|*'`'*) return 1 ;; esac
  re='(^|[^A-Za-z0-9_])(if|then|else|elif|fi|while|until|do|done|case|esac|for|select|function)([^A-Za-z0-9_]|$)'
  [[ "$before" =~ $re ]] && return 1
  count="$(printf '%s' "$text" | grep -oE "(^|[^A-Za-z0-9_\$])${name}(\[[^]]*\])?\+?=" 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ "$count" = "1" ] || return 1
  dq="$(scope_dequote_text "$text")"
  scope_text_has_ansi_escape "$text" && return 1
  count="$(printf '%s' "$dq" | grep -oE "(^|[^A-Za-z0-9_\$])${name}(\[[^]]*\])?\+?=" 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ "$count" = "1" ] || return 1
  bind_re='(^|[^A-Za-z0-9_.-])(read|mapfile|readarray|getopts|eval|source|declare|typeset|local|unset|let|export)([[:space:]]|$)'
  [[ "$text" =~ $bind_re || "$dq" =~ $bind_re ]] && return 1
  bind_re='printf[[:space:]]+-v|\$\{'"$name"':?=|(^|[^A-Za-z0-9_])(for|select)[[:space:]]+'"$name"'([[:space:]]|;|$)'
  [[ "$text" =~ $bind_re || "$dq" =~ $bind_re ]] && return 1
  bind_re='(^|[;&|({]|'$'\n'')[[:space:]]*\.[[:space:]]'
  [[ "$text" =~ $bind_re || "$dq" =~ $bind_re ]] && return 1
  return 0
}

scope_check_bash_candidate_inner() {
  local candidate="${1:-}" command_text="${2:-}" depth="${3:-0}" expected_company="${4:-}"
  local occurrence_prefix="${5:-}" occurrence_suffix="${6:-}"
  local masked token name prefix values value braced unbraced expanded backtick first_segment resolved
  local -a pending=()
  [ -n "$candidate" ] || return 0
  [ "$depth" -lt 8 ] || scope_block_rel "$candidate"
  scope_candidate_is_inert_text "$candidate" "$command_text" "$occurrence_prefix" "$occurrence_suffix" && return 0
  if scope_candidate_is_single_quoted "$candidate" "$occurrence_prefix"; then
    # The shell expands nothing inside single quotes, but a program handed
    # to an interpreter (`node -e '...`companies/${c}/x`...'`, `python3 -c
    # '... f"companies/{c}/x" ...'`) builds the real path at run time from
    # its own template field. When a company path in such a program holds
    # an interpolation marker, the path the program opens cannot be read
    # from the text, so fail closed instead of checking the template text
    # as if it were a literal path.
    local sq_interp_re='(^|[;&|[:space:](])(python[0-9.]*|node|nodejs|deno|bun|perl|ruby|php|bash|sh|zsh|dash|ksh|osascript)([[:space:]]|$)'
    if [[ "$candidate" == companies/* ]] && [[ "$occurrence_prefix" =~ $sq_interp_re ]]; then
      case "$candidate" in
        *'$'*|*'{'*|*$'\140'*|*'%'*)
          scope_block_rel "$candidate" "an interpreter program builds this company path from a template or variable at run time, so the path cannot be checked; spell the company path literally"
          ;;
      esac
    fi
    scope_check_raw "$candidate"
    return 0
  fi

  masked="$(scope_mask_literal_expansions "$candidate")"
  # Only a path that starts with companies/ names a tenant. Stripping the
  # prefix unconditionally read workspace/worktrees/$w as tenant "workspace"
  # whenever a top-level company folder of that name existed, so every loop
  # value then had to land under that folder and was refused.
  if [ -z "$expected_company" ] && [[ "$masked" == companies/* ]]; then
    first_segment="${masked#companies/}"
    first_segment="${first_segment%%/*}"
    case "$first_segment" in
      ""|*'$'*|*'*'*|*'?'*|*'['*) ;;
      *)
        [ -d "$HQ_ROOT/companies/$first_segment" ] && expected_company="$first_segment"
        ;;
    esac
  fi
  backtick=$'\140'
  # One `$(...)` whose output the hook can know without running it (a
  # slash-free `date +FORMAT`, `pwd`, `dirname WORD`, the git top level, an
  # `ls -d GLOB | head -1`; see scope_substitution_literal_value) is replaced
  # by that value and the result is checked like a typed path. The same
  # resolver already serves `D=$(date +%F); cp x "a-$D"`; writing the
  # substitution inline in the word (`cp x "workspace/a-$(date +%F).txt"`)
  # reached the fail-closed branch below instead (feedback cbbd0e33,
  # 2ec4335f, a33f359b).
  case "$masked" in
    *'$('*)
      # `$(ls -d workspace/x/* | head -1)/rest`: ls -d prints a match of the
      # glob as the glob spells it, so the word takes one of the matched
      # entries. Every match is substituted and checked like a literal (a
      # symlink is resolved there); with no match ls prints nothing and the
      # word is the text around the substitution (feedback 2ec4335f,
      # a33f359b).
      local lsd_pre lsd_rest lsd_body lsd_post lsd_glob lsd_match lsd_count=0 lsd_cwd
      lsd_pre="${candidate%%\$\(*}"
      lsd_rest="${candidate#*\$\(}"
      lsd_body="${lsd_rest%%\)*}"
      lsd_post="${lsd_rest#*\)}"
      if [[ "$lsd_rest" == *')'* ]] && [[ "$lsd_pre$lsd_post" != *[\$\(\)\`\\[:space:]]* ]] \
        && lsd_glob="$(scope_ls_d_glob_operand "$lsd_body")"; then
        lsd_cwd="$(cd "${COMMAND_CWD:-$HQ_ROOT}" 2>/dev/null && pwd -P)" || scope_block_rel "$candidate"
        while IFS= read -r lsd_match; do
          [ -n "$lsd_match" ] || continue
          case "$lsd_match" in *[!A-Za-z0-9._/@+-]*|*'..'*) scope_block_rel "$candidate" "an ls -d match holds a character the guard cannot check" ;; esac
          lsd_count=$((lsd_count + 1))
          [ "$lsd_count" -le 2048 ] || scope_block_rel "$candidate" "the ls -d glob has more matches than the hook can check"
          scope_check_bash_candidate_inner "$lsd_pre$lsd_match$lsd_post" "$command_text" "$((depth + 1))" "$expected_company" "" ""
        done < <(cd "$lsd_cwd" && compgen -G "$lsd_glob" || true)
        if [ "$lsd_count" -eq 0 ] && [ -n "$lsd_pre$lsd_post" ]; then
          scope_check_bash_candidate_inner "$lsd_pre$lsd_post" "$command_text" "$((depth + 1))" "$expected_company" "" ""
        fi
        return 0
      fi
      # A sed script word is not a path: scope_token_is_sed_script decides
      # which substitution forms it may hold (an `e` or `w` flag runs or
      # writes the substituted text and stays refused there), so a word
      # given to sed keeps the fail-closed branch below.
      local sub_stmt sub_head
      sub_stmt="${occurrence_prefix##*[;|&()$'\n']}"
      sub_stmt="${sub_stmt#"${sub_stmt%%[![:space:]]*}"}"
      sub_head="${sub_stmt%%[[:space:]]*}"
      sub_head="${sub_head##*/}"
      case "$sub_head" in
        sed|gsed) ;;
        *)
          if expanded="$(scope_expand_one_substitution "$candidate" "$command_text")" && [ -n "$expanded" ]; then
            # The value is built from literal text the resolver proved, so
            # it is checked without the raw spelling around it (which still
            # holds the `$(` and would read as an unchecked expansion).
            scope_check_bash_candidate_inner "$expanded" "$command_text" "$((depth + 1))" "$expected_company" "" ""
            return 0
          fi
          ;;
      esac
      ;;
  esac
  case "$masked" in
    *'$('*|*"$backtick"*) scope_block_rel "$candidate" ;;
  esac
  # `${n%.md}` (and %%, #, ##) with a plain literal word removes that exact
  # text from the end or start of the value, so each value the guard proves
  # for n is cut the same way here and the result is checked as the path
  # (feedback 140b84e9). The word may not hold a glob character, a slash or
  # another expansion; anything else falls through to the refusals below.
  local trim_re='\$\{([A-Za-z_][A-Za-z0-9_]*)(%%|%|##|#)([A-Za-z0-9._-]+)\}'
  if [[ "$masked" =~ $trim_re ]]; then
    local trim_tok="${BASH_REMATCH[0]}" trim_name="${BASH_REMATCH[1]}" trim_op="${BASH_REMATCH[2]}" trim_word="${BASH_REMATCH[3]}" trim_v trim_out
    [[ "$candidate" == *"$trim_tok"* ]] || scope_block_rel "$candidate"
    values="$(scope_shell_variable_values "$trim_name" "$occurrence_prefix" "$command_text" || true)"
    [ -n "$values" ] || scope_block_rel "$candidate"
    while IFS= read -r value; do
      [ -n "$value" ] || scope_block_rel "$candidate"
      case "$trim_op" in
        '%'|'%%') trim_v="${value%"$trim_word"}" ;;
        '#'|'##') trim_v="${value#"$trim_word"}" ;;
      esac
      trim_out="${candidate%%"$trim_tok"*}$trim_v${candidate#*"$trim_tok"}"
      pending[${#pending[@]}]="$trim_out"
    done <<< "$values"
    for expanded in "${pending[@]}"; do
      scope_check_bash_candidate_inner "$expanded" "$command_text" "$((depth + 1))" "$expected_company" "$occurrence_prefix" "$occurrence_suffix"
    done
    return 0
  fi
  token="$(printf '%s' "$masked" | grep -oE '\$\{?([A-Za-z_][A-Za-z0-9_]*|[1-9])\}?' 2>/dev/null | head -n 1 || true)"
  # A slash-free fragment (scope_var_is_sanitized_segment) inside a path
  # segment that also holds a literal character other than `.` cannot change
  # the directory, only the final name. Every existing entry the segment can
  # match is checked as a literal path, and so is a name that does not
  # exist, which stands for the directory itself. The command must create no
  # link or directory first.
  if [ -n "$token" ]; then
    local seg_name="${token#\$}" seg_pre seg_post seg_dir seg_lit seg_glob seg_match seg_count=0 seg_cwd
    seg_name="${seg_name#\{}"; seg_name="${seg_name%\}}"
    if scope_var_is_sanitized_segment "$seg_name" "$command_text" \
      && ! scope_command_may_create_entries "$command_text"; then
      seg_pre="${candidate%%"$token"*}"
      seg_post="${candidate#*"$token"}"
      case "$seg_pre$seg_post" in *'$'*|*'`'*|*'*'*|*'?'*|*'['*|*'{'*|*'}'*|*[[:space:]]*|*'"'*|*"'"*) seg_pre="" ; seg_post="" ;; esac
      seg_dir=""
      case "$seg_pre" in */*) seg_dir="${seg_pre%/*}"; seg_lit="${seg_pre##*/}" ;; *) seg_lit="$seg_pre" ;; esac
      case "$seg_post" in */*) seg_lit="$seg_lit${seg_post%%/*}" ;; *) seg_lit="$seg_lit$seg_post" ;; esac
      case "$seg_post" in */*) seg_lit="" ;; esac
      if [ -n "$seg_dir" ] && [[ "$seg_lit" == *[!.]* ]]; then
        seg_cwd="$(cd "${COMMAND_CWD:-$HQ_ROOT}" 2>/dev/null && pwd -P)" || scope_block_rel "$candidate"
        seg_glob="${seg_pre##*/}*$seg_post"
        while IFS= read -r seg_match; do
          [ -n "$seg_match" ] || continue
          case "$seg_match" in *[!A-Za-z0-9._@+-]*) scope_block_rel "$candidate" "a directory entry holds a character the guard cannot check" ;; esac
          seg_count=$((seg_count + 1))
          [ "$seg_count" -le 2048 ] || scope_block_rel "$candidate" "the directory has more entries than the hook can check"
          scope_check_bash_candidate_inner "$seg_dir/$seg_match" "$command_text" "$((depth + 1))" "$expected_company" "" ""
        done < <({ [[ "$seg_dir" == /* ]] && cd "$seg_dir" 2>/dev/null; } || { [[ "$seg_dir" != /* ]] && cd "$seg_cwd/$seg_dir" 2>/dev/null; } && compgen -G "$seg_glob" || true)
        scope_check_bash_candidate_inner "$seg_dir/${seg_pre##*/}__hq_unmatched__$seg_post" "$command_text" "$((depth + 1))" "$expected_company" "" ""
        return 0
      fi
    fi
  fi
  if [ -n "$token" ]; then
    name="${token#\$}"
    name="${name#\{}"
    name="${name%\}}"
    braced='$'"{$name}"
    unbraced='$'"$name"
    if [ "$token" != "$unbraced" ] && [ "$token" != "$braced" ]; then
      scope_block_rel "$candidate"
    fi
    prefix="$occurrence_prefix"
    values="$(scope_shell_variable_values "$name" "$prefix" "$command_text" || true)"
    [ -n "$values" ] || scope_block_rel "$candidate"

    while IFS= read -r value; do
      [ -n "$value" ] || scope_block_rel "$candidate"
      if [[ "$candidate" == *"$braced"* ]]; then
        # Bash 3.2 can preserve nested quotes from a parameter-replacement
        # replacement word. Assemble the pieces so the checked path has no
        # quote characters that the shell would remove before opening it.
        expanded="${candidate%%"$braced"*}$value${candidate#*"$braced"}"
      elif [[ "$candidate" == *"$unbraced"* ]]; then
        expanded="${candidate%%"$unbraced"*}$value${candidate#*"$unbraced"}"
      else
        scope_block_rel "$candidate"
      fi
      pending[${#pending[@]}]="$expanded"
    done <<< "$values"
    for expanded in "${pending[@]}"; do
      scope_check_bash_candidate_inner "$expanded" "$command_text" "$((depth + 1))" "$expected_company" "$occurrence_prefix" "$occurrence_suffix"
    done
    return 0
  fi

  case "$masked" in
    *'{'*|*'}'*)
      # Expand a plain `{a,b}` brace (no nesting, quoting, or expansion
      # inside the candidate) and check every resulting word. Each word is
      # authorized on its own, so `companies/indigo/{x,y}` passes for a
      # session locked to indigo and `companies/{indigo,otherco}` does not.
      if scope_expand_simple_brace "$candidate"; then
        for expanded in ${scope_brace_words[@]+"${scope_brace_words[@]}"}; do
          scope_check_bash_candidate_inner "$expanded" "$command_text" "$((depth + 1))" "" "$occurrence_prefix" "$occurrence_suffix"
        done
        return 0
      fi
      scope_block_rel "$candidate" "brace expansion cannot be checked safely (spell each path literally, or use a plain {a,b} list with no quotes or variables)"
      ;;
  esac
  case "$masked" in
    *'$'*|*"$backtick"*) scope_block_rel "$candidate" ;;
  esac
  first_segment="${masked#companies/}"
  first_segment="${first_segment%%/*}"
  # bash extglob (`@(x)`, `!(x)`, `+(x)`) and zsh extendedglob (`^x`, `x#`)
  # can match other tenants and are not enumerable here.
  if [[ "$masked" == companies/* ]]; then
    case "$first_segment" in
      *'^'*|*'@'*|*'+'*|*'!'*|*'#'*|*'~'*)
        scope_block_rel "$candidate" "extended glob syntax in the company segment cannot be checked; spell the company name literally"
        ;;
    esac
  fi
  case "$first_segment" in
    *'*'*|*'?'*|*'['*)
      # A glob in the company segment expands to the tenant folders that
      # exist. Enumerate them and check each concrete path, so
      # `companies/*/knowledge` passes when every matching tenant is locked
      # (always true in a single-company HQ) and fails on any other tenant.
      if [[ "$masked" == companies/* ]] && scope_expand_company_segment_glob "$candidate" "$first_segment"; then
        for expanded in ${scope_glob_words[@]+"${scope_glob_words[@]}"}; do
          scope_check_bash_candidate_inner "$expanded" "$command_text" "$((depth + 1))" "" "$occurrence_prefix" "$occurrence_suffix"
        done
        return 0
      fi
      scope_block_rel "$candidate" "glob in the company segment is not allowed"
      ;;
  esac
  case "$masked" in
    *'*'*|*'?'*|*'['*)
      scope_check_bash_glob_candidate "$candidate" "$masked" "$occurrence_prefix"
      return 0
      ;;
  esac
  if [ -n "$expected_company" ]; then
    resolved="$(scope_normalize_hq_relative "$candidate")"
    resolved="$(scope_resolve_rel_symlinks "$resolved")"
    case "$resolved" in
      "companies/$expected_company"|"companies/$expected_company"/*) ;;
      *)
        # A locked company's documented repo link
        # (companies/<co>/repos/app -> ../../../repos/private/app) is checked
        # on its target, as Read already does.
        scope_company_link_target_ok "$expected_company" "$candidate" \
          || scope_block_rel "$candidate" "expanded path resolves outside companies/$expected_company"
        ;;
    esac
    scope_check_rel "$resolved"
  else
    scope_check_raw "$candidate"
  fi
}

# Admit URL data only for one literal simple invocation at a known absolute
# Chromium install path. This is lexical admission, not executable attestation.
# Validate the ENTIRE command before exempting any URI word; wrappers, setup,
# operators and redirects must retain ordinary fail-closed path handling.
scope_check_browser_file_uri_inner() {
  local command_text="${1:-}" prefix="${2:-}" target=${#2}
  local i=0 start raw word head="" uri_path="" uri_rel uri_data input_start=-1 inputs=0
  local scope_url_plain scope_url_end scope_url_split backtick=$'\140'
  local data_re='^(\?[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_=&-]*)?(#[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_=&-]*)?$'
  case "$prefix" in *file://*) ;; *) return 1 ;; esac
  while [ "$i" -lt "${#command_text}" ]; do
    case "${command_text:$i:1}" in
      ' '|$'\t') i=$((i + 1)); continue ;;
      ';'|'|'|'&'|'('|')'|'<'|'>'|$'\n') return 1 ;;
    esac
    start=$i
    scope_url_word_scan "$command_text" "$i"
    [ "$scope_url_end" -gt "$i" ] || return 1
    i=$scope_url_end; word="$scope_url_plain"
    raw="${command_text:$start:$((i - start))}"
    # No expansion, escaping, quote splicing or unterminated quoting anywhere.
    case "$raw" in *'$'*|*"$backtick"*|*\\*) return 1 ;; esac
    if [ "$raw" != "$word" ] && [ "$raw" != "\"$word\"" ] && [ "$raw" != "'$word'" ]; then return 1; fi
    if [ -z "$head" ]; then
      head="$word"
      case "$head" in
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'|/usr/bin/google-chrome|/usr/bin/chromium|/usr/bin/chromium-browser|/snap/bin/chromium) ;;
        *) return 1 ;;
      esac
      continue
    fi
    case "$word" in
      --headless|--headless=new|--disable-gpu|--no-sandbox|--disable-dev-shm-usage|--disable-software-rasterizer|--print-to-pdf=*|--screenshot=*) continue ;;
      file:///*) ;;
      *) return 1 ;;
    esac
    inputs=$((inputs + 1)); [ "$inputs" -eq 1 ] || return 1
    # The input URI must be exactly one quoted literal word.
    [ "$raw" = "\"$word\"" ] || [ "$raw" = "'$word'" ] || return 1
    uri_path="${word#file://}"; uri_path="${uri_path%%[?#]*}"
    case "$uri_path" in //*) return 1 ;; esac
    case "$uri_path" in *'%'*|*'*'*|*'['*|*'{'*|*'}'*|*\"*|*\'*) return 1 ;; esac
    uri_rel="$(scope_normalize_hq_relative "$uri_path")"
    [ -n "$uri_rel" ] || return 1
    uri_data="${word#file://}"; uri_data="${uri_data#"$uri_path"}"
    [[ "$uri_data" =~ $data_re ]] || scope_block_rel "$uri_rel" "browser URL data exceeds literal query alphabet"
    case "/$uri_path/" in */./*|*/../*) scope_block_rel "$uri_rel" "browser URI contains a dot segment" ;; esac
    [ "$target" -lt "$start" ] || [ "$target" -ge "$i" ] || input_start=$start
  done
  [ "$inputs" -eq 1 ] && [ "$input_start" -ge 0 ] || return 1
  scope_check_raw "$uri_path"
  return 0
}

# An ineligible queried/fragment URI must not fall through to the older path
# extractor, which can stop before fragment text and miss the rejected data.
scope_check_browser_file_uri() {
  scope_check_browser_file_uri_inner "$@" && return 0
  local text="${1:-}" target=${#2} i=0 start word raw head="" options_ok=1 uri_path uri_rel backtick=$'\140'
  local scope_url_plain scope_url_end scope_url_split
  case "${2:-}" in *file://*) ;; *) return 1 ;; esac
  while [ "$i" -lt "${#text}" ]; do
    case "${text:$i:1}" in
      ' '|$'\t') i=$((i + 1)); continue ;;
      ';'|'|'|'&'|'('|')'|$'\n') head=""; options_ok=1; i=$((i + 1)); continue ;;
      '<'|'>') options_ok=0; i=$((i + 1)); continue ;;
    esac
    start=$i
    scope_url_word_scan "$text" "$i"
    if [ "$scope_url_end" -le "$i" ]; then i=$((i + 1)); continue; fi
    i=$scope_url_end; word="$scope_url_plain"
    if [ "$target" -ge "$start" ] && [ "$target" -lt "$i" ]; then
      # Retain the prior browser URI path refusal even when dispatch cannot
      # acquire the URL-data exception. This branch ONLY denies; it never
      # admits bare names, setup, wrappers or richer query/fragment data.
      raw="${text:$start:$((i - start))}"
      if [ "$options_ok" -eq 1 ] && { [ "$raw" = "\"$word\"" ] || [ "$raw" = "'$word'" ]; }; then
        case "${head##*/}" in
          chrome|google-chrome|chromium|chromium-browser|'Google Chrome')
            case "$word" in
              file:///*)
                uri_path="${word#file://}"; uri_path="${uri_path%%[?#]*}"
                case "$uri_path" in
                  //*) ;;
                  *'%'*|*'*'*|*'['*|*'{'*|*'}'*|*\"*|*\'*|*'$'*|*"$backtick"*|*\\*) ;;
                  *)
                    uri_rel="$(scope_normalize_hq_relative "$uri_path")"
                    if [ -n "$uri_rel" ]; then
                      case "/$uri_path/" in */./*|*/../*) scope_block_rel "$uri_rel" "browser URI contains a dot segment" ;; esac
                    fi
                    ;;
                esac
                ;;
            esac
            ;;
        esac
      fi
      case "$word" in
        *file://*\?*|*file://*\#*) scope_block_rel "file URI" "queried URI requires one approved literal browser invocation" ;;
      esac
      return 1
    fi
    if [ -z "$head" ]; then
      head="$word"
    else
      case "$word" in
        --headless|--headless=new|--disable-gpu|--no-sandbox|--disable-dev-shm-usage|--disable-software-rasterizer|--print-to-pdf=*|--screenshot=*) ;;
        *) options_ok=0 ;;
      esac
    fi
  done
  return 1
}

scope_check_bash_candidate() {
  scope_check_browser_file_uri "${2:-}" "${3:-}" && return 0
  scope_check_bash_candidate_inner "${1:-}" "${2:-}" 0 "" "${3:-}" "${4:-}"
}

# True when <raw> (the spelling of one argv word, from
# `hq_shell_simple_commands ... raw`) is <word> written literally: the same
# text alone, or inside one pair of enclosing quotes. The raw-text scan for
# `companies/` then saw this path at this argv position, with the context
# that decided it (an inert `--title "..."` value is allowed there only because
# of where it sits). Matching text elsewhere in the command proves nothing:
# `gh pr create --title "companies/otherco/x" --body-file compa''nies/otherco/x`
# has an inert title and a real file argument with the same bash value.
scope_word_spelled_literally() {
  local word="${1:-}" raw="${2:-}"
  [ -n "$word" ] || return 1
  [ "$raw" = "$word" ] && return 0
  [ "$raw" = "'$word'" ] && return 0
  [ "$raw" = "\"$word\"" ] && return 0
  return 1
}

# True when argv word <word> differs from its raw spelling <raw> only by
# double-quote characters and every `companies/` fragment of <word> appears
# verbatim in <raw>. The raw-text scan has then already checked each of those
# fragments with its full context (a function call's literal argument, a loop
# list), so checking it again here without that context would only lose it:
# `w(){ local d="companies/$1"; ...; }; w indigo`. A quote inside a fragment
# (`"compa"nies/otherco`, `companies/oth"er"co/x`) means the fragment is not
# in <raw> verbatim, so the word is still checked.
scope_word_quotes_outside_company_paths() {
  local word="${1:-}" raw="${2:-}" rest frag
  [ -n "$raw" ] || return 1
  case "$raw" in *\'*|*\\*) return 1 ;; esac
  [ "${raw//\"/}" = "$word" ] || return 1
  rest="$word"
  while [[ "$rest" == *companies/* ]]; do
    frag="companies/${rest#*companies/}"
    rest="${frag#companies/}"
    frag="${frag%%[[:space:];|&()<>]*}"
    [[ "$raw" == *"$frag"* ]] || return 1
  done
  return 0
}

# Check one shell word after quote removal. hq_shell_simple_commands joins
# adjacent quoted and unquoted segments, drops the quotes, and applies
# backslash escapes, as bash does before it opens a file. The raw-text scan
# above only sees the spelled form, so `compa''nies/oth''erco/x`,
# `companies/oth\erco/x` and `"companies"/otherco/x` reach it as no company
# path at all. Any word whose bash value names `companies/` and whose argv
# position <raw> is not that same text spelled literally is checked here on
# its bash value, with the same candidate checks. With no <raw> (text from a
# second parse) nothing is skipped.
#
# Every `companies/` occurrence in the word is checked, and each fragment ends
# at whitespace as well as at shell operators and quotes. A word holding a
# blank may be program text for a launcher this hook does not recognize
# (`timeout 5 bash -c '...'`, `find . -exec sh -c '...' \;`), and a quoted
# newline splits a record so the second line arrives as one word. A path after
# the first blank is still a path bash may open.
# Words inside an interpreter heredoc body are source text, not shell words,
# and stay with the body rules of the main scan.
#
# Words come from the split of scope_mask_literal_expansions output
# (scope_norm_scan), so an escaped or single-quoted `$`, `*`, `?` or `[`
# arrives as a literal marker (`companies/x/\$schema.json` stays a plain file
# name) while a real expansion still reaches the fail-closed variable checks.
scope_check_normalized_word() {
  local word="${1:-}" rest frag
  case "$word" in *companies/*) ;; *) return 0 ;; esac
  if [ "$#" -ge 2 ]; then
    scope_word_spelled_literally "$word" "${2:-}" && return 0
    scope_word_quotes_outside_company_paths "$word" "${2:-}" && return 0
  fi
  if [ -n "${scope_interp_bodies:-}" ] \
    && { [[ "$scope_interp_bodies" == *"$word"* ]] || [[ "${scope_interp_bodies_unquoted:-}" == *"$word"* ]] \
      || [[ "${scope_interp_bodies_masked:-}" == *"$word"* ]] || [[ "${scope_interp_bodies_masked_unquoted:-}" == *"$word"* ]]; } \
    && [[ "${scope_interp_outside_unquoted:-}" != *"$word"* ]] \
    && [[ "${scope_interp_outside_masked_unquoted:-}" != *"$word"* ]]; then
    return 0
  fi
  rest="$word"
  while [[ "$rest" == *companies/* ]]; do
    frag="companies/${rest#*companies/}"
    rest="${frag#companies/}"
    frag="${frag%%[[:space:];|&()<>\"\']*}"
    # JSON or prose punctuation after the last segment (`companies/x"},`
    # once quotes are gone): with no `{` in the word there is no brace
    # expansion, and with no `/` after the cut the trailing `}`, `]` or `,`
    # only extends the last segment's name. Check the path before it, so
    # the company segment is still compared with the lock.
    case "$frag" in
      *'{'*) ;;
      *[\},\]])
        local frag_core="${frag%%[\},\]]*}"
        case "${frag#"$frag_core"}" in */*) ;; *) [ "$frag_core" != companies/ ] && frag="$frag_core" ;; esac
        ;;
    esac
    # The splitter ends a word at `$(` and keeps only the `$`, so
    # `compa''nies/$(echo x)/y` arrives as `companies/$`. A command
    # substitution's output cannot be checked; keep it blocked.
    case "$frag" in
      *'$') scope_block_rel "$frag(...)" "a command substitution in a company path cannot be checked" ;;
    esac
    scope_check_bash_candidate "$frag" "$scope_scan_cmd" "" ""
  done
}

# Check every word of the split of <text> against the raw spelling of the
# same argv position. Both outputs are read line by line; a quoted newline
# inside a word splits both at the same place, so lines and fields stay
# paired. If they ever disagree, no word on that line is skipped.
scope_check_normalized_split() {
  local text="${1:-}" line rawline k w
  local -a norm_lines=() raw_lines=() norm_words=() raw_words=()
  while IFS= read -r line; do
    norm_lines[${#norm_lines[@]}]="$line"
  done <<< "$(hq_shell_simple_commands "$text")"
  while IFS= read -r line; do
    raw_lines[${#raw_lines[@]}]="$line"
  done <<< "$(hq_shell_simple_commands "$text" raw)"
  for ((k = 0; k < ${#norm_lines[@]}; k++)); do
    line="${norm_lines[$k]}"
    [ -n "$line" ] || continue
    rawline=""
    [ "$k" -lt "${#raw_lines[@]}" ] && rawline="${raw_lines[$k]}"
    norm_words=(); raw_words=()
    IFS=$'\037' read -r -a norm_words <<< "$line"
    IFS=$'\037' read -r -a raw_words <<< "$rawline"
    for ((w = 0; w < ${#norm_words[@]}; w++)); do
      if [ "${#norm_lines[@]}" -eq "${#raw_lines[@]}" ] \
        && [ "${#raw_words[@]}" -eq "${#norm_words[@]}" ]; then
        scope_check_normalized_word "${norm_words[$w]}" "${raw_words[$w]}"
      else
        scope_check_normalized_word "${norm_words[$w]}"
      fi
    done
  done
}

# `eval ARGS` joins its arguments with spaces and parses the result as shell
# again, so quotes and backslashes that survived the first parse are removed
# a second time: `eval 'cat companies/oth''erco/x'` reads companies/otherco.
# `bash|sh|zsh|dash|ksh [options] -c SCRIPT` parses SCRIPT the same way. The
# shell is found at any argv position, so programs that launch it
# (`timeout 5 bash -c`, `nice bash -c`, `xargs sh -c`,
# `find . -exec sh -c ... \;`, `sudo -u u bash -c`) are covered without a
# list. `eval` is found after scope_strip_command_wrappers, the same wrapper
# parser the main loop uses. Clustered flags (`-ce`) and option arguments
# (`-o pipefail`) before the script are understood. The text is re-split with
# the shared splitter and every resulting word is checked as above; nested
# eval / -c is followed up to four levels, then fails closed. <words> are the
# unmasked words of one simple command; the text is masked again before its
# words are checked, so a `$` the second parse would expand is still seen.
scope_check_reparsed_words() {
  local depth="${1:-0}"; shift
  local -a words=("$@") inner_tokens=() saved_tokens=() stripped=()
  local i j n text="" record found_c
  n=${#words[@]}
  [ "$n" -gt 0 ] || return 0
  saved_tokens=(${scope_tokens[@]+"${scope_tokens[@]}"})
  scope_tokens=("${words[@]}")
  scope_strip_command_wrappers
  stripped=(${scope_tokens[@]+"${scope_tokens[@]}"})
  scope_tokens=(${saved_tokens[@]+"${saved_tokens[@]}"})
  if [ "${#stripped[@]}" -gt 0 ] && [ "${stripped[0]}" = eval ]; then
    text="${stripped[*]:1}"
  else
    for ((i = 0; i < n; i++)); do
      case "${words[$i]##*/}" in
        bash|sh|zsh|dash|ksh) ;;
        *) continue ;;
      esac
      found_c=0
      for ((j = i + 1; j < n; j++)); do
        case "${words[$j]}" in
          -o|+o|-O|+O|--rcfile|--init-file) j=$((j + 1)) ;;
          --) j=$((j + 1)); break ;;
          --*) ;;
          -*c*) found_c=1 ;;
          -*|+*) ;;
          *) break ;;
        esac
      done
      if [ "$found_c" -eq 1 ] && [ "$j" -lt "$n" ]; then
        text="${words[$j]}"
        break
      fi
    done
  fi
  [ -n "$text" ] || return 0
  [ "$depth" -lt 4 ] || scope_block_rel "$text" "nested eval or sh -c is too deep to check; run the command directly"
  scope_check_normalized_split "$(scope_mask_literal_expansions "$text")"
  scope_check_reparsed_text "$((depth + 1))" "$text"
}

# Run scope_check_reparsed_words on every simple command of <text>. The split
# keeps a quoted newline inside its word (`nl` mode encodes it as \036 and it
# is restored here), so a multi-line `sh -c "...<newline>..."` program reaches
# the reparse whole instead of as two unrelated records.
scope_check_reparsed_text() {
  local depth="${1:-0}" text="${2:-}" record k
  local -a inner_tokens=()
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    IFS=$'\037' read -r -a inner_tokens <<< "$record"
    for ((k = 0; k < ${#inner_tokens[@]}; k++)); do
      inner_tokens[$k]="${inner_tokens[$k]//$'\036'/$'\n'}"
    done
    scope_check_reparsed_words "$depth" ${inner_tokens[@]+"${inner_tokens[@]}"}
  done <<< "$(hq_shell_simple_commands "$text" nl)"
}

scope_check_bash_glob_candidate() {
  local candidate="${1:-}" masked="${2:-}" occurrence_prefix="${3:-}"
  local first_glob_prefix="" ch token_prefix="" remaining full_prefix full_pattern
  local normalized_prefix company_root expansion_cwd match resolved_match rel glob_company
  local count=0 prefix_remaining backtick=$'\140'

  scope_load_bound_company
  [ -n "$BOUND_COS" ] || scope_block_rel "$candidate" "no bound company authorizes glob expansion"
  # `"companies/x/dir/"*.md` quotes only the literal prefix; the glob part is
  # unquoted and expands normally. Drop balanced double quotes that sit wholly
  # before the first glob character (including the opening quote that the
  # scanner left in the occurrence prefix) and check the unquoted pattern.
  local lit glob_tail word_head dq_count
  lit="${candidate%%[*?[]*}"
  glob_tail="${candidate:${#lit}}"
  word_head="${occurrence_prefix##*[[:space:];|&()<>]}"
  case "$lit$word_head" in
    *'"'*)
      case "$glob_tail$lit$word_head" in *"'"*|*\\*|*'$'*|*"$backtick"*) ;;
        *)
          case "$glob_tail" in *'"'*) ;;
            *)
              dq_count="${word_head//[!\"]/}${lit//[!\"]/}"
              if [ $(( ${#dq_count} % 2 )) -eq 0 ] && [ "$word_head" = '"' ]; then
                candidate="${lit//\"/}$glob_tail"
                masked="$(scope_mask_literal_expansions "$candidate")"
                occurrence_prefix="${occurrence_prefix%\"}"
              fi
              ;;
          esac
          ;;
      esac
      ;;
  esac
  # `ls "companies/x/people/*/meta.yaml"`, `find companies/x -path
  # "companies/x/people/*/meta.yaml"`: a word double-quoted from end to end
  # with no expansion inside is never globbed; the program gets the literal
  # text, which names a path (or a pattern it matches itself) under the
  # literal prefix before the first glob character. That prefix is checked
  # against the lock below exactly as for an unquoted glob, and the word is
  # then done: nothing expands, so no match can land anywhere else
  # (feedback 36c3e8cb). A `..` after the prefix keeps the normal refusal.
  local quoted_literal=0
  case "$word_head:$candidate" in
    '"':*'"')
      case "${candidate%\"}" in
        *'"'*|*"'"*|*\\*|*'$'*|*"$backtick"*|*'{'*|*'}'*) ;;
        *)
          candidate="${candidate%\"}"
          masked="$(scope_mask_literal_expansions "$candidate")"
          occurrence_prefix="${occurrence_prefix%\"}"
          quoted_literal=1
          ;;
      esac
      ;;
  esac
  case "$candidate" in
    *"'"*|*'"'*|*\\*) scope_block_rel "$candidate" "quoted or escaped glob syntax cannot be checked safely" ;;
  esac
  case "$masked" in
    *'{'*|*'}'*) scope_block_rel "$candidate" "brace expansion cannot be checked safely" ;;
  esac

  remaining="$masked"
  while [ -n "$remaining" ]; do
    ch="${remaining:0:1}"
    case "$ch" in
      '*'|'?'|'[') break ;;
      *) first_glob_prefix+="$ch"; remaining="${remaining:1}" ;;
    esac
  done

  prefix_remaining="$occurrence_prefix"
  while [ -n "$prefix_remaining" ]; do
    ch="${prefix_remaining:0:1}"
    case "$ch" in
      [[:space:]]|';'|'|'|'&'|'('|')'|'<'|'>') token_prefix="" ;;
      *) token_prefix+="$ch" ;;
    esac
    prefix_remaining="${prefix_remaining:1}"
  done
  case "$token_prefix" in
    *'$'*|*"$backtick"*|*'*'*|*'?'*|*'['*|*'{'*|*'}'*|*'"'*|*"'"*|*\\*)
      scope_block_rel "$candidate" "the path prefix before the glob contains unchecked shell expansion"
      ;;
  esac

  expansion_cwd="$(cd "$COMMAND_CWD" 2>/dev/null && pwd -P)" \
    || scope_block_rel "$candidate" "the command working directory cannot be resolved"
  full_prefix="$token_prefix$first_glob_prefix"
  case "$full_prefix" in
    /*) ;;
    *) full_prefix="$expansion_cwd/$full_prefix" ;;
  esac
  normalized_prefix="$(scope_normalize_hq_relative "$full_prefix")"
  glob_company="$(scope_company_slug_for_rel "$normalized_prefix")"
  if ! scope_company_is_locked "$glob_company"; then
    scope_block_rel "$candidate" "the literal prefix before the glob does not resolve inside companies/$BOUND_CO"
  fi
  # `companies/indigo/*.yaml` globs the company root itself: the literal
  # prefix IS the bound company directory, which is inside its company as
  # much as any subdirectory. Every match is still realpath-checked below.
  case "$normalized_prefix" in
    "companies/$glob_company"|"companies/$glob_company"/*) ;;
    *) scope_block_rel "$candidate" "the literal prefix before the glob does not resolve inside its company" ;;
  esac

  company_root="$(realpath "$HQ_ROOT/companies/$glob_company" 2>/dev/null)" \
    || scope_block_rel "$candidate" "the bound company directory cannot be resolved"
  case "$company_root" in
    "$HQ_ROOT/companies/$glob_company"|"$HQ_ROOT/companies/$glob_company"/*) ;;
    *) scope_block_rel "$candidate" "the bound company directory resolves outside its literal company path" ;;
  esac
  if [ "$quoted_literal" -eq 1 ]; then
    case "/$candidate/" in
      */../*) scope_block_rel "$candidate" "a quoted glob climbs out of its company with .." ;;
    esac
    return 0
  fi

  full_pattern="$token_prefix$candidate"
  case "$full_pattern" in
    /*) ;;
    *) full_pattern="$expansion_cwd/$full_pattern" ;;
  esac
  while IFS= read -r match; do
    [ -n "$match" ] || scope_block_rel "$candidate" "the shell glob produced an empty match"
    count=$((count + 1))
    [ "$count" -le 2048 ] || scope_block_rel "$candidate" "the glob has more matches than the hook can check"
    case "$match" in
      /*) ;;
      *) match="$expansion_cwd/$match" ;;
    esac
    resolved_match="$(realpath "$match" 2>/dev/null)" \
      || scope_block_rel "$candidate" "a glob match cannot be resolved with realpath"
    case "$resolved_match" in
      "$company_root"/*) ;;
      *) scope_block_rel "$candidate" "a glob match resolves outside companies/$glob_company" ;;
    esac
    rel="${resolved_match#"$HQ_ROOT"/}"
    scope_check_rel "$rel"
  done < <(
    cd "$expansion_cwd" 2>/dev/null || exit 1
    shopt -s nullglob dotglob nocaseglob
    shopt -s globstar 2>/dev/null || :
    compgen -G "$full_pattern"
  )
  if [ "$count" -eq 0 ]; then
    # A glob that matches nothing is passed to the program as the literal
    # pattern text. Its literal prefix was proven above to sit physically
    # inside a locked company, so the literal word names a (missing) path in
    # that same company unless the remainder climbs back out with `..`.
    # (Matching ran case-insensitively, so no case-variant entry exists.)
    case "/$candidate/" in
      */../*) scope_block_rel "$candidate" "the shell glob produced no checkable matches" ;;
    esac
  fi
}

case "$TOOL" in
  Read|Grep|Glob|Bash|Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

# Resolve an absolute path one component at a time. This mirrors filesystem
# traversal for existing symlinks while retaining a normalized missing tail,
# without relying on GNU-only realpath flags or changing the process cwd.
# Case folding for company paths. On a case-insensitive volume (macOS APFS by
# default) `Companies/otherco`, `COMPANIES/OtherCo`, or the HQ root spelled in
# another case open the same tenant folder as the canonical spelling, but the
# checks below match `companies/<slug>` and "$HQ_ROOT" by exact string. These
# helpers rewrite such spellings to the on-disk names before any check runs,
# so a case variant is classified as the company path it opens. They only
# turn a spelling the checks did not recognise into one they do.
# Detection is one `-ef` test (same device and inode); no process is spawned.
scope_case_folds() {
  if [ -z "${SCOPE_CASE_FOLDS:-}" ]; then
    SCOPE_CASE_FOLDS=0
    if [ -n "${HQ_ROOT:-}" ] && [ -d "$HQ_ROOT/companies" ] \
      && [ "$HQ_ROOT/COMPANIES" -ef "$HQ_ROOT/companies" ]; then
      SCOPE_CASE_FOLDS=1
    fi
  fi
  [ "$SCOPE_CASE_FOLDS" = 1 ]
}

# Print a glob that matches <text> in any letter case (`ab` -> `[aA][bB]`),
# built without spawning a process. Glob metacharacters match only themselves.
# Result in SCOPE_CASE_PAT (no command substitution, so no fork).
scope_case_pattern() {
  local text="${1:-}" out="" ch i rest
  local lower="abcdefghijklmnopqrstuvwxyz" upper="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  for ((i = 0; i < ${#text}; i++)); do
    ch="${text:i:1}"
    case "$ch" in
      [a-z]) rest="${lower%%"$ch"*}"; out="${out}[${ch}${upper:${#rest}:1}]" ;;
      [A-Z]) rest="${upper%%"$ch"*}"; out="${out}[${lower:${#rest}:1}${ch}]" ;;
      '['|']'|'*'|'?'|'\'|'!'|'^') out="${out}[${ch}]" ;;
      *) out="$out$ch" ;;
    esac
  done
  SCOPE_CASE_PAT="$out"
}

# Replace every case variant of <word> (matched by glob <pat>) in <text>.
scope_case_replace_all() {
  local text="${1:-}" word="${2:-}" pat="${3:-}" out="" pre
  # shellcheck disable=SC2295
  while [[ "$text" == *$pat* ]]; do
    pre="${text%%$pat*}"
    out="$out$pre$word"
    text="${text:$((${#pre} + ${#word}))}"
  done
  SCOPE_CASE_OUT="$out$text"
}

# The on-disk name of the companies/ entry that <segment> opens when it is a
# case variant of one; otherwise <segment> unchanged. Result in SCOPE_CASE_ENTRY.
scope_case_company_entry() {
  local seg="${1:-}" pat entry
  SCOPE_CASE_ENTRY="$seg"
  case "$seg" in ""|.|..) return 0 ;; esac
  [ -e "$HQ_ROOT/companies/$seg" ] || return 0
  for entry in "$HQ_ROOT"/companies/* "$HQ_ROOT"/companies/.[!.]*; do
    [ "${entry##*/}" = "$seg" ] && return 0
  done
  scope_case_pattern "$seg"
  pat="$SCOPE_CASE_PAT"
  for entry in "$HQ_ROOT"/companies/* "$HQ_ROOT"/companies/.[!.]*; do
    entry="${entry##*/}"
    # shellcheck disable=SC2053
    if [[ "$entry" == $pat ]] && [ "$HQ_ROOT/companies/$entry" -ef "$HQ_ROOT/companies/$seg" ]; then
      SCOPE_CASE_ENTRY="$entry"
      return 0
    fi
  done
}

SCOPE_CASE_COMPANIES_PAT='[cC][oO][mM][pP][aA][nN][iI][eE][sS]'

# Rewrite <text> (a payload, a command, or a path) so that case variants of
# the HQ root, of the companies segment, and of a company slug right after
# companies/ use the on-disk spelling. A no-op unless the volume folds case.
# Result in SCOPE_CASE_TEXT.
scope_case_fold_text() {
  local text="${1:-}" stripped out="" pre seg
  SCOPE_CASE_TEXT="$text"
  scope_case_folds || return 0
  # Unicode case folding maps two non-ASCII letters onto ASCII ones: U+017F
  # (long s) folds to s and U+212A (Kelvin sign) to k, so `companie\u017f/x`
  # opens companies/x. Spell them as the ASCII letter first.
  text="${text//$'\xc5\xbf'/s}"
  text="${text//$'\xe2\x84\xaa'/k}"
  if [ -z "${SCOPE_CASE_ROOT_PAT:-}" ]; then
    scope_case_pattern "$HQ_ROOT"
    SCOPE_CASE_ROOT_PAT="$SCOPE_CASE_PAT"
  fi
  stripped="${text//"$HQ_ROOT"/}"
  if [[ "$stripped" == *$SCOPE_CASE_ROOT_PAT* ]]; then
    scope_case_replace_all "$text" "$HQ_ROOT" "$SCOPE_CASE_ROOT_PAT"
    text="$SCOPE_CASE_OUT"
  fi
  stripped="${text//companies/}"
  if [[ "$stripped" == *$SCOPE_CASE_COMPANIES_PAT* ]]; then
    scope_case_replace_all "$text" companies "$SCOPE_CASE_COMPANIES_PAT"
    text="$SCOPE_CASE_OUT"
  fi
  while [[ "$text" == *companies/* ]]; do
    pre="${text%%companies/*}"
    out="${out}${pre}companies/"
    text="${text:$((${#pre} + 10))}"
    seg="${text%%[!A-Za-z0-9._-]*}"
    [ -n "$seg" ] || continue
    scope_case_company_entry "$seg"
    out="$out$SCOPE_CASE_ENTRY"
    text="${text:${#seg}}"
  done
  SCOPE_CASE_TEXT="$out$text"
}

scope_resolve_absolute_path() {
  local input="${1:-}" resolved="/" pending segment candidate target hops=0
  [ -n "$input" ] || return 1
  input="$(scope_strip_tool_location "$input")" || return 1
  case "$input" in /*) ;; *) return 1 ;; esac

  pending="${input#/}"
  while [ -n "$pending" ]; do
    case "$pending" in
      */*) segment="${pending%%/*}"; pending="${pending#*/}" ;;
      *) segment="$pending"; pending="" ;;
    esac
    case "$segment" in
      ""|.) continue ;;
      ..)
        [ "$resolved" = "/" ] || resolved="${resolved%/*}"
        [ -n "$resolved" ] || resolved="/"
        continue
        ;;
    esac

    candidate="${resolved%/}/$segment"
    if [ -L "$candidate" ]; then
      hops=$((hops + 1))
      [ "$hops" -le 40 ] || return 1
      target="$(readlink "$candidate" 2>/dev/null)" || return 1
      case "$target" in
        /*) resolved="/"; target="${target#/}" ;;
      esac
      [ -n "$target" ] || continue
      if [ -n "$pending" ]; then
        pending="$target/$pending"
      else
        pending="$target"
      fi
      continue
    fi
    resolved="$candidate"
  done
  # A case variant of the HQ root, companies/, or a slug names the same folder.
  scope_case_fold_text "$resolved"
  printf '%s' "$SCOPE_CASE_TEXT"
}

self_src="${BASH_SOURCE[0]:-$0}"
self_dir="$(cd "$(dirname "$self_src")" 2>/dev/null && pwd -P || true)"
HQ_ROOT=""
if [ -n "$self_dir" ]; then
  cand="$(cd "$self_dir/../.." 2>/dev/null && pwd -P || true)"
  if [ -n "$cand" ] && [ -f "$cand/core/scripts/lib/session-authz.sh" ]; then
    HQ_ROOT="$cand"
  fi
fi
[ -n "$HQ_ROOT" ] || HQ_ROOT="${CLAUDE_PROJECT_DIR:-${HQ_ROOT:-}}"
if [ -z "$HQ_ROOT" ]; then
  logical_pwd="$(pwd -L 2>/dev/null || true)"
  while [ -n "$logical_pwd" ]; do
    if [ -f "$logical_pwd/core/scripts/lib/session-authz.sh" ] && [ -d "$logical_pwd/companies" ]; then
      HQ_ROOT="$logical_pwd"
      break
    fi
    [ "$logical_pwd" != "/" ] || break
    logical_pwd="${logical_pwd%/*}"
    [ -n "$logical_pwd" ] || logical_pwd="/"
  done
fi
[ -n "$HQ_ROOT" ] && [ -d "$HQ_ROOT/companies" ] || exit 0
physical_root="$(scope_resolve_absolute_path "$HQ_ROOT" 2>/dev/null || true)"
[ -n "$physical_root" ] && HQ_ROOT="$physical_root"
unset SCOPE_CASE_FOLDS SCOPE_CASE_ROOT_PAT
[ -f "$HQ_ROOT/core/scripts/lib/session-authz.sh" ] || exit 0

LIB_DIR="$HQ_ROOT/core/scripts/lib"
# shellcheck source=../../core/scripts/lib/session-authz.sh
. "$LIB_DIR/session-authz.sh"
# shellcheck source=../../core/scripts/lib/session-scope-capability.sh
. "$LIB_DIR/session-scope-capability.sh"
# shellcheck source=../../core/scripts/lib/session-id.sh
. "$LIB_DIR/session-id.sh"

# Fold case variants of company paths in everything the checks read: the
# payload (paths, commands) and the working directory.
scope_case_fold_text "$INPUT"
INPUT="$SCOPE_CASE_TEXT"
scope_case_fold_text "$PAYLOAD_CWD"
PAYLOAD_CWD="$SCOPE_CASE_TEXT"

# The hook payload is the ONLY identity this guard accepts. It names the session
# that fired this event; nothing else here describes the caller reliably.
#
# Not workspace/sessions/.current: that pointer is global and last-writer-wins
# (see core/scripts/lib/session-id.sh, whose own header states the invariant this
# restores: "the enforcement side does not use .current"). It names whichever
# session fired a hook most recently, so an unrelated agent inherits a stranger's
# company binding — an UNBOUND agent was observed reading another tenant's files
# because .current happened to name a session bound to that tenant (2026-08-19,
# HQ 15.0.98).
#
# And NOT the session environment either, however tempting: a session id in the
# environment describes whoever EXPORTED it, which for a spawned agent is its
# PARENT. core/scripts/tests/hq-agent-session-hooks.test.sh case 7 documents and
# tests exactly that inheritance ("An agent session spawned from inside another
# session inherits that parent's session id"). Resolving identity from the
# environment would therefore authorize a payload-less child against its parent's
# tenant — the same cross-session failure by a different route.
#
# A payload with no session id is produced by `claude -p --session-id <uuid>`.
# Such a call cannot be attributed to any session and is denied below.
if [ "${HQ_HOOK_SESSION_ID+set}" = "set" ]; then
  SESSION_ID="$HQ_HOOK_SESSION_ID"
else
  SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty')"
fi
CALLER_AGENT_ID=""
CALLER_AGENT_TYPE=""
if [ "${HQ_HOOK_AGENT_ID+set}" = "set" ] && [ "${HQ_HOOK_AGENT_TYPE+set}" = "set" ]; then
  CALLER_AGENT_ID="$HQ_HOOK_AGENT_ID"
  CALLER_AGENT_TYPE="$HQ_HOOK_AGENT_TYPE"
else
  # Read both caller fields in one process; hook process budgets are deliberately
  # tight. NUL framing preserves ordinary values and marks embedded NUL invalid.
  {
    IFS= read -r -d '' CALLER_AGENT_ID || true
    IFS= read -r -d '' CALLER_AGENT_TYPE || true
  } < <(printf '%s' "$INPUT" | jq -j '
    (if .agent_id == null then "" elif (.agent_id | type) == "string" then .agent_id else "!invalid-agent-id-type!" end | gsub("\u0000"; "!invalid-agent-id-nul!"))
    + "\u0000" +
    (if .agent_type == null then "" elif (.agent_type | type) == "string" then .agent_type else "!invalid-agent-type!" end | gsub("\u0000"; "!invalid-agent-type-nul!"))
    + "\u0000"
  ')
  if [ "${HQ_HOOK_AGENT_ID+set}" = "set" ]; then CALLER_AGENT_ID="$HQ_HOOK_AGENT_ID"; fi
  if [ "${HQ_HOOK_AGENT_TYPE+set}" = "set" ]; then CALLER_AGENT_TYPE="$HQ_HOOK_AGENT_TYPE"; fi
fi
CALLER_KIND="main"
CALLER_IDENTITY_ERROR=""
if [ -n "$SESSION_ID" ] && ! session_scope_identity_is_valid "$SESSION_ID"; then
  CALLER_IDENTITY_ERROR="invalid-session"
elif [ -n "$CALLER_AGENT_ID" ]; then
  CALLER_KIND="subagent"
  if ! session_scope_identity_is_valid "$CALLER_AGENT_ID"; then
    CALLER_IDENTITY_ERROR="invalid"
  fi
elif [ -n "$CALLER_AGENT_TYPE" ]; then
  CALLER_KIND="subagent"
  CALLER_IDENTITY_ERROR="missing"
fi
COMMAND_CWD="$PAYLOAD_CWD"
[ -n "$COMMAND_CWD" ] || COMMAND_CWD="$(pwd -P)"

scope_read_bound_company() {
  local sid="${1:-}" aid="${2:-}" co=""
  [ -n "$sid" ] || return 0
  co="$(session_scope_read "$HQ_ROOT" "$sid" "$aid")"
  [ -n "$co" ] || scope_load_caller_parent_session
  if [ -z "$co" ] && [ "$CALLER_KIND" = "main" ] && [ -z "$SCOPE_CALLER_PARENT_SID" ] \
    && [ "$SCOPE_CALLER_REPORTS_PARENT" -eq 0 ]; then
    local meta="$HQ_ROOT/workspace/sessions/$sid/meta.yaml"
    if [ -f "$meta" ]; then
      co="$(awk '
        $1 == "company_slug:" {
          sub(/^[^:]+:[[:space:]]*/, "")
          gsub(/^"|"$/, "")
          print
          exit
        }
      ' "$meta" 2>/dev/null || true)"
    fi
  fi
  printf '%s' "$co"
}

scope_read_bound_companies() {
  local sid="${1:-}" aid="${2:-}" cap=""
  [ -n "$sid" ] || return 0
  cap="$(session_scope_capability_path "$HQ_ROOT" "$sid" "$aid" 2>/dev/null || true)"
  if [ -n "$cap" ] && [ -f "$cap" ]; then
    session_scope_read_companies "$HQ_ROOT" "$sid" "$aid" 2>/dev/null || true
  elif [ -z "$aid" ]; then
    scope_read_bound_company "$sid" "$aid"
  fi
}

# Read the primary binding and its optional lock set in one capability parse.
# This keeps the common hook path to the same jq invocation as the legacy
# primary-only read.
scope_read_bound_scope() {
  local sid="${1:-}" aid="${2:-}" cap="" info="" primary="" has_set="" companies=""
  [ -n "$sid" ] || return 0
  cap="$(session_scope_capability_path "$HQ_ROOT" "$sid" "$aid" 2>/dev/null || true)"
  if [ -n "$cap" ] && [ -f "$cap" ]; then
    info="$(jq -er --arg sid "$sid" --arg aid "$aid" '
      select(.session_id == $sid and (.agent_id // "") == $aid)
      | if (.company_slug | type) != "string" or (.company_slug | test("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$") | not) then error("invalid primary")
        elif has("company_slugs") then
          if (.company_slugs | type) == "array" and all(.company_slugs[]; type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"))
            and (.company_slugs | length) > 0 and .company_slugs[0] == .company_slug
            and ((.company_slugs | unique | length) == (.company_slugs | length))
            and ((.company_slug == "personal" and (.company_slugs | length) == 1) or (.company_slugs | all(. != "personal"))) then
            [.company_slug, "true", (.company_slugs | join(","))] | @tsv
          else error("invalid company_slugs") end
        else [.company_slug, "false", .company_slug] | @tsv end
    ' "$cap" 2>/dev/null)" || return 0
    IFS=$'\t' read -r primary has_set companies <<< "$info"
    printf '%s\t%s\t%s\n' "$primary" "$has_set" "$companies"
  elif [ -z "$aid" ]; then
    primary="$(scope_read_bound_company "$sid" "$aid")"
    [ -n "$primary" ] && printf '%s\tfalse\t%s\n' "$primary" "$primary"
  fi
}

BOUND_CO=""
BOUND_COS=""
BOUND_CO_LOADED=0
scope_load_bound_company() {
  [ "$BOUND_CO_LOADED" -eq 0 ] || return 0
  BOUND_CO_LOADED=1
  [ -n "$SESSION_ID" ] || return 0
  [ -z "$CALLER_IDENTITY_ERROR" ] || return 0
  scope_apply_bound_scope
  # Claude Code fires no SessionStart for a Task subagent, so its tuple is
  # minted here on first use from the parent's main-thread capability only.
  # No parent capability means no inheritance and the deny stands.
  if [ -z "$BOUND_CO" ] && [ "$CALLER_KIND" = "subagent" ] && [ -n "$CALLER_AGENT_ID" ] \
    && session_scope_inherit_parent "$HQ_ROOT" "$SESSION_ID" "$CALLER_AGENT_ID"; then
    scope_apply_bound_scope
  fi
  # SessionStart bind can land in the same turn as the first company path.
  # Re-read once rather than weakening the deny.
  if [ -z "$BOUND_CO" ]; then
    scope_apply_bound_scope
  fi
  # A child the host runs under its own session id (Grok, Codex threads)
  # reports its parent in the payload. Mint its tuple from that parent's
  # main-thread capability, as for a Task subagent. This runs only on the
  # unbound path, so a bound caller pays nothing for it.
  if [ -z "$BOUND_CO" ]; then
    scope_load_caller_parent_session
    if [ -n "$SCOPE_CALLER_PARENT_SID" ] \
      && session_scope_inherit_parent_session "$HQ_ROOT" "$SESSION_ID" "$CALLER_AGENT_ID" "$SCOPE_CALLER_PARENT_SID"; then
      scope_apply_bound_scope
    fi
  fi
  # `core/scripts/hq-session.sh set company_slug X && ls companies/X/...`:
  # the hook runs before the command, so the bind the command opens with
  # has not happened yet and the read after it was refused as unbound
  # (feedback f7a7126c, c52a2d2e, 1ad54d72, 74bfcdbc). For a main thread
  # with no binding at all, the lead bind is taken as this command's lock:
  # it is the same first bind the next call would have seen, and a bound
  # session (or a child) gets nothing from this, so no lock is widened or
  # switched here.
  if [ -z "$BOUND_CO" ] && [ -n "${SCOPE_SAME_CMD_BIND:-}" ] && [ "$CALLER_KIND" = "main" ] \
    && [ -z "$CALLER_AGENT_ID" ] && [ "$SCOPE_CALLER_REPORTS_PARENT" -eq 0 ] \
    && [ -d "$HQ_ROOT/companies/$SCOPE_SAME_CMD_BIND" ] && [ ! -L "$HQ_ROOT/companies/$SCOPE_SAME_CMD_BIND" ]; then
    BOUND_CO="$SCOPE_SAME_CMD_BIND"
    BOUND_COS="$SCOPE_SAME_CMD_BIND"
  fi
}

# Load SCOPE_CALLER_PARENT_SID, the parent session id the payload reports for
# a child caller, once per process (subshell callers re-read it). It stays
# empty when there is none, when it names this session, when the payload has
# no child marker besides the parent id itself (a root session that reports a
# parent does not inherit), or when the shared lineage library is missing;
# the deny then stands.
# SCOPE_CALLER_REPORTS_PARENT is 1 whenever the payload names a parent other
# than this session, marker or not. Such a caller never falls back to its own
# meta.yaml, so a parent id without a marker can fail closed but cannot widen.
SCOPE_CALLER_PARENT_SID=""
SCOPE_CALLER_REPORTS_PARENT=0
SCOPE_CALLER_PARENT_SID_LOADED=0
scope_load_caller_parent_session() {
  local psid=""
  [ "$SCOPE_CALLER_PARENT_SID_LOADED" -eq 0 ] || return 0
  SCOPE_CALLER_PARENT_SID_LOADED=1
  if [ -f "$LIB_DIR/hook-caller-lineage.sh" ]; then
    # shellcheck source=../../core/scripts/lib/hook-caller-lineage.sh
    . "$LIB_DIR/hook-caller-lineage.sh"
    psid="$(hook_caller_parent_session_id "$INPUT")"
    if [ -n "$psid" ] && [ "$psid" != "$SESSION_ID" ]; then
      SCOPE_CALLER_REPORTS_PARENT=1
    fi
    # An older library without the marker check grants no inheritance.
    if ! command -v hook_caller_has_child_marker >/dev/null 2>&1 \
      || ! hook_caller_has_child_marker "$INPUT"; then
      psid=""
    fi
  fi
  if [ -n "$psid" ] && [ "$psid" != "$SESSION_ID" ] && session_scope_identity_is_valid "$psid"; then
    SCOPE_CALLER_PARENT_SID="$psid"
  fi
  return 0
}

scope_apply_bound_scope() {
  local info="" primary="" has_set="" companies="" slug out=""
  info="$(scope_read_bound_scope "$SESSION_ID" "$CALLER_AGENT_ID" || true)"
  IFS=$'\t' read -r primary has_set companies <<< "$info"
  BOUND_CO="$primary"
  BOUND_COS="$primary"
  [ "$has_set" = true ] && [ -n "$companies" ] || return 0
  # The gate is only consulted for a capability that actually carries a
  # multi-company set. A disabled or unavailable flag keeps primary-only scope.
  session_scope_multi_company_enabled "$HQ_ROOT" "$primary" || return 0
  for slug in ${companies//,/ }; do
    case "$slug" in ''|*[!a-zA-Z0-9_-]*) return 0 ;; esac
    if [ "$slug" = personal ] || { [ -d "$HQ_ROOT/companies/$slug" ] && [ ! -L "$HQ_ROOT/companies/$slug" ]; }; then
      case ",$out," in *",$slug,"*) ;; *) out="${out:+$out,}$slug" ;; esac
    fi
  done
  [ -n "$out" ] && BOUND_COS="$out"
}

scope_company_is_locked() {
  local slug="${1:-}"
  [ -n "$slug" ] && case ",$BOUND_COS," in *",$slug,"*) return 0 ;; esac
  return 1
}

scope_normalize_hq_relative() {
  local raw="${1:-}" abs physical
  [ -n "$raw" ] || { printf '%s' ""; return 0; }
  raw="${raw//\\//}"

  case "$raw" in
    ~/*)
      [ -n "${HOME:-}" ] || { printf '%s' ""; return 0; }
      raw="${HOME}/${raw#~/}"
      ;;
    ~)
      raw="${HOME:-}"
      [ -n "$raw" ] || { printf '%s' ""; return 0; }
      ;;
  esac

  case "$raw" in
    /*) abs="$raw" ;;
    *) abs="$HQ_ROOT/$raw" ;;
  esac

  # Resolve each component before interpreting `..`. A symlink followed by a
  # parent segment is relative to the link target, not the lexical path.
  physical="$(scope_resolve_absolute_path "$abs" 2>/dev/null || true)"
  case "$physical" in
    "$HQ_ROOT"/*) printf '%s' "${physical#"$HQ_ROOT"/}" ;;
    "$HQ_ROOT") printf '%s' "" ;;
    *) printf '%s' "" ;;
  esac
}

scope_resolve_rel_symlinks() {
  local rel="${1:-}"
  [ -n "$rel" ] || { printf '%s' ""; return 0; }
  local cur
  cur="$(scope_resolve_absolute_path "$HQ_ROOT/$rel" 2>/dev/null || true)"
  case "$cur" in
    "$HQ_ROOT"/*) rel="${cur#"$HQ_ROOT"/}" ;;
    "$HQ_ROOT") rel="" ;;
    *) rel="" ;;
  esac
  printf '%s' "$rel"
}

scope_company_slug_for_rel() {
  local rel="${1:-}" co
  [ -n "$rel" ] || return 0
  case "$rel" in
    companies)
      printf '%s' "__companies_root__"
      ;;
    companies/*)
      co="${rel#companies/}"
      co="${co%%/*}"
      # The first segment is a company only when it resolves to an actual
      # tenant directory. Top-level files (notably manifest.yaml), shell
      # expansions, and placeholder prose are not tenant targets.
      case "$co" in
        *'$'*|*'`'*|*'('*|*')'*|*'{'*|*'}'*|*'<'*|*'>'*) return 0 ;;
      esac
      [ -d "$HQ_ROOT/companies/$co" ] || return 0
      printf '%s' "$co"
      ;;
  esac
}

scope_is_manifest_rel() {
  case "${1:-}" in
    companies/manifest.yaml|companies/manifest.yml|companies/manifest.json) return 0 ;;
    *) return 1 ;;
  esac
}

scope_is_template_rel() {
  case "${1:-}" in
    companies/_template|companies/_template/*) return 0 ;;
    *) return 1 ;;
  esac
}

scope_bind_retry_done=0

scope_rel_allowed() {
  local rel="${1:-}"
  [ -n "$rel" ] || return 0

  if scope_is_manifest_rel "$rel" || scope_is_template_rel "$rel"; then
    return 0
  fi

  local co
  co="$(scope_company_slug_for_rel "$rel")"
  [ -n "$co" ] || return 0
  [ "$co" != "__companies_root__" ] || return 0
  [ -z "$CALLER_IDENTITY_ERROR" ] || return 1
  scope_load_bound_company

  # SessionStart and the first company path can arrive in one parallel batch.
  # Keep the deny unless the same payload session becomes bound on this delayed
  # read; do this only once per hook invocation and only for a company path.
  if [ -n "$SESSION_ID" ] && [ -z "$BOUND_CO" ] && [ "$scope_bind_retry_done" -eq 0 ]; then
    scope_bind_retry_done=1
    sleep 0.05
    BOUND_CO="$(scope_read_bound_company "$SESSION_ID" "$CALLER_AGENT_ID")"
    BOUND_COS="$(scope_read_bound_companies "$SESSION_ID" "$CALLER_AGENT_ID" | paste -sd, -)"
  fi

  case "$co" in
    _template|_*)
      return 0
      ;;
  esac

  # Fail CLOSED. An unidentifiable session (no id in the payload, none in the
  # environment) gets no company access, and neither does an identified session
  # with no binding. Permitting either would make the guard depend on being able
  # to name the caller, which is precisely what it cannot assume.
  if [ -z "$SESSION_ID" ] || [ -z "$BOUND_CO" ]; then
    return 1
  fi

  scope_company_is_locked "$co"
}

# Say how to rewrite a command whose path the guard could not resolve
# statically, so the next attempt passes instead of guessing.
scope_print_rewrite_hint() {
  local rel="${1:-}" backtick=$'\140' remote_re
  case "$rel" in
    *'$('*|*"$backtick"*)
      printf '%s\n' "How to rewrite: a command substitution's output cannot be checked. Run the inner command first, then use the literal path it printed." >&2
      # Inside double quotes the local shell runs $(...) before ssh or
      # `hq outposts exec` sends the command, so the substitution reads local
      # paths. Single quotes send it unexpanded to run on the remote host.
      remote_re='(^|[;&|({[:space:]])(ssh|hq[[:space:]]+outposts[[:space:]]+exec)[[:space:]]'
      if [[ "${cmd:-}" =~ $remote_re ]]; then
        printf '%s\n' "For a remote command (ssh, hq outposts exec), wrap it in single quotes so \$(...) runs on the remote host: hq outposts exec box -- 'cat \$(ls -d /srv/x/* | tail -1)/VERSION'." >&2
      fi
      ;;
    *'$'*)
      printf '%s\n' "How to rewrite: the guard follows a variable only when the same command gives it a literal value, as in VAR=/abs/path; cmd \"\$VAR/x\" or for x in a b c; do cmd dir/\$x; done. \$HOME is resolved automatically. Otherwise spell the path literally." >&2
      ;;
  esac
}

scope_block_rel() {
  local rel="${1:-}"
  local block_reason="${2:-}"
  local co bound_msg bind_msg="" scope_names_companies=0 traversal_target
  scope_load_bound_company
  co="$(scope_company_slug_for_rel "$rel")"
  # A path with no companies/ segment at all is not a tenancy failure, so it
  # must not be reported as one. Binding a company would not authorize it and
  # would widen the session's scope for nothing; saying so sent agents to
  # `hq-session.sh set company_slug` for paths in /tmp and ~/.claude.
  #
  # An unresolved slug (`companies/$co/x`) keeps the tenancy message below: the
  # path IS under companies/, the guard just cannot say which tenant, and
  # binding the right company is the correct remedy there.
  scope_names_companies=0
  case "$rel" in companies|companies/*|*/companies/*) scope_names_companies=1 ;; esac
  if [ -z "$co" ] && [ "$scope_names_companies" -eq 0 ]; then
    cat >&2 <<EOF
BLOCKED: Cross-company scope violation
Tool: $TOOL
Path: $rel
No company path is involved. This path could not be resolved well enough to
prove it stays outside companies/, so the guard failed closed on it.
EOF
    [ -z "$block_reason" ] || printf 'Reason: %s\n' "$block_reason" >&2
    cat >&2 <<EOF
Session: ${SESSION_ID:-unknown}

Re-run it with a literal path, or use the Write tool (or Edit) for a file
write. Do NOT bind a company to get past this: no company owns this path, and
binding one would only widen this session's scope.
EOF
    scope_print_rewrite_hint "$rel"
    exit 2
  fi
  if [ "$CALLER_IDENTITY_ERROR" = "missing" ]; then
    bound_msg="This subagent call has no agent_id, so its company access is denied. Restart the session so the host supplies the caller identity."
  elif [ "$CALLER_IDENTITY_ERROR" = "invalid" ]; then
    bound_msg="This call has an invalid agent_id, so its company access is denied. Restart the session so the host supplies a valid caller identity."
  elif [ "$CALLER_IDENTITY_ERROR" = "invalid-session" ]; then
    bound_msg="This call has an invalid session_id, so its company access is denied. Restart the session so the host supplies a valid session identity."
  elif [ -z "$SESSION_ID" ]; then
    bound_msg="This call carries NO session id in its hook payload, so there is no
session whose company scope could authorize it, and company paths are denied
rather than guessed. Only the payload identity counts here: an id in the
environment names whoever exported it — for a spawned agent, its parent — and a
child must not inherit its parent's tenant. If this is an agent you spawned, run
it so the host reports a session of its own (a \`claude -p --session-id <uuid>\`
child does not)."
  elif [ "$CALLER_KIND" = "subagent" ] && [ -n "$CALLER_AGENT_ID" ] && [ -z "$BOUND_CO" ]; then
    bound_msg="This subagent has no company binding for its agent_id, and its parent session has no company capability to inherit, so its company access is denied. Bind the parent session (core/scripts/hq-session.sh set company_slug <slug>), then restart or respawn the subagent."
  elif [ -z "$BOUND_CO" ]; then
    bound_msg="Session has no company_slug bound."
    bind_msg="Bind the correct company with: core/scripts/hq-session.sh set company_slug <slug>
If that reports success but this keeps blocking, the bind landed on another
session — retry it as: core/scripts/hq-session.sh --session-id ${SESSION_ID:-<id>} set company_slug <slug>"
  else
    bound_msg="Session locked companies: ${BOUND_COS:-$BOUND_CO}."
  fi

  if [ -z "$co" ] && [[ "$rel" == *'$'* ]]; then
    # A company segment supplied by a variable with no static value. There is
    # no target to name, so report the session's own company instead.
    cat >&2 <<EOF
BLOCKED: Unresolvable company-path expansion
Tool: $TOOL
Path: $rel
EOF
    [ -n "$block_reason" ] || block_reason="variable expansion has no statically resolvable value"
    printf 'Session company_slug: %s\n' "${BOUND_CO:-none}" >&2
  else
    cat >&2 <<EOF
BLOCKED: Cross-company scope violation
Tool: $TOOL
Path: $rel
EOF
    # A traversal such as companies/indigo/../../otherco names one company
    # lexically and opens another. Label the company the path resolves to.
    case "$rel" in
      *..*)
        traversal_target="$(scope_normalize_hq_relative "$rel")"
        co="$(scope_company_slug_for_rel "$traversal_target")"
        ;;
    esac
    # Still `unknown` here: this branch is reached for a companies/ path whose
    # slug could not be resolved, which is exactly an unknown target company.
    printf 'Target company: %s\n' "${co:-unknown}" >&2
  fi
  # The reason is printed as its own line. Wrapping it in `glob "..." blocked:`
  # reported every non-glob refusal as a glob failure.
  [ -z "$block_reason" ] || printf 'Reason: %s\n' "$block_reason" >&2
  cat >&2 <<EOF
Session: ${SESSION_ID:-unknown}
$bound_msg

For data files, use the Write tool (or Edit to change an existing file) with a
literal path under your bound company. Do not write company files with a Bash
heredoc or redirect.
EOF
  if [ -n "$bind_msg" ]; then
    printf '%s\n' "$bind_msg" >&2
  elif [ -n "$BOUND_CO" ]; then
    printf 'For intentional multi-company work, add a lock with: core/scripts/hq-session.sh add company <slug>\n' >&2
  fi
  printf 'Allowed without binding: core/, personal/, repos/, workspace/, companies/manifest.yaml, companies/_template/\n' >&2
  scope_print_rewrite_hint "$rel"
  exit 2
}

scope_check_rel() {
  local rel="${1:-}"
  [ -n "$rel" ] || return 0
  scope_rel_allowed "$rel" || scope_block_rel "$rel"
}

scope_check_raw() {
  local raw="${1:-}" rel
  [ -n "$raw" ] || return 0
  case "$raw" in
    */__hq_scope_*_location__*) scope_block_tool_location_parent "$raw" ;;
  esac
  rel="$(scope_normalize_hq_relative "$raw")"
  rel="$(scope_resolve_rel_symlinks "$rel")"
  scope_check_lexical_company "$raw" "$rel"
  scope_check_rel "$rel"
}

# Program-name trust (feedback_ef130236). Several token exemptions decide that
# an argument is not a path from the program's name (git refs, gh endpoints,
# curl data, sed scripts, echo text, ...). The name proves nothing when the
# same command defines a function or alias of that name, re-routes command
# lookup (PATH=, hash, enable, sourcing a file), or runs a binary of that name
# from an arbitrary path (`./git`, `/tmp/curl`). scope_compute_shadowed_names
# runs once per command (bash regex only, no process); scope_head_is_untrusted
# then says whether the current record's program may keep its exemptions.
scope_compute_shadowed_names() {
  local text="${1:-}" rest re name nl=$'\n'
  SCOPE_SHADOWED_NAMES=" "
  SCOPE_LOOKUP_REROUTED=0
  re='(^|[^A-Za-z0-9_./:-])([A-Za-z_][A-Za-z0-9_.:+-]*)[[:space:]]*\([[:space:]]*\)'
  rest="$text"
  while [[ "$rest" =~ $re ]]; do
    SCOPE_SHADOWED_NAMES+="${BASH_REMATCH[2]} "
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
  re='(^|[^A-Za-z0-9_])function[[:space:]]+([^[:space:](){};&|]+)'
  rest="$text"
  while [[ "$rest" =~ $re ]]; do
    SCOPE_SHADOWED_NAMES+="${BASH_REMATCH[2]} "
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
  # alias/hash/enable/source count only as a command word (start of the
  # command or after an operator, optionally behind `builtin`/`command`),
  # so the words inside a quoted commit message do not.
  re='(^|['"$nl"';&|(){}])[[:space:]]*((builtin|command)[[:space:]]+)?(alias|hash|enable|source)([[:space:]]|$)'
  [[ "$text" =~ $re ]] && SCOPE_LOOKUP_REROUTED=1
  re='(command_not_found_handle|BASH_FUNC_[A-Za-z0-9_%]*)'
  [[ "$text" =~ $re ]] && SCOPE_LOOKUP_REROUTED=1
  re='(^|[^A-Za-z0-9_])(PATH|BASH_ENV|ENV)\+?='
  [[ "$text" =~ $re ]] && SCOPE_LOOKUP_REROUTED=1
  re='(^|['"$nl"';&|(){}])[[:space:]]*\.[[:space:]]'
  [[ "$text" =~ $re ]] && SCOPE_LOOKUP_REROUTED=1
  return 0
}

# True when the program of the current record (scope_tokens) must not keep
# name-based exemptions. A `bash|sh <script>` record is judged by the script.
scope_head_is_untrusted() {
  local head_index head
  head_index="$(scope_command_head_index)"
  head="${scope_tokens[$head_index]:-}"
  case "$head" in
    bash|sh|zsh)
      case "${scope_tokens[$((head_index + 1))]:-}" in
        */*) head="${scope_tokens[$((head_index + 1))]}" ;;
      esac
      ;;
  esac
  SCOPE_REC_HEAD="${head##*/}"
  [ "${SCOPE_LOOKUP_REROUTED:-0}" -eq 1 ] && return 0
  [[ "${SCOPE_SHADOWED_NAMES:- }" == *" ${head##*/} "* ]] && return 0
  case "$head" in
    */*)
      case "$head" in *..*) return 0 ;; esac
      case "$head" in
        /usr/bin/*|/bin/*|/usr/sbin/*|/sbin/*|/usr/local/bin/*|/opt/homebrew/bin/*) return 1 ;;
        "$HQ_ROOT"/core/scripts/*) return 1 ;;
        core/scripts/*|./core/scripts/*)
          # A relative path runs from the shell's cwd: it is the in-tree
          # script only when it names the same file from there.
          case "${COMMAND_CWD:-}" in
            "$HQ_ROOT") return 1 ;;
            /*) [ "${COMMAND_CWD%/}/$head" -ef "$HQ_ROOT/${head#./}" ] && return 1 ;;
          esac
          ;;
      esac
      return 0
      ;;
  esac
  return 1
}

# --- working-directory operands (feedback_ef130236 review) -----------------
# Physical form of COMMAND_CWD, cached per value (one resolution).
scope_cwd_phys() {
  if [ "${SCOPE_CWD_PHYS_FOR-__unset__}" != "${COMMAND_CWD:-}" ]; then
    SCOPE_CWD_PHYS_FOR="${COMMAND_CWD:-}"
    SCOPE_CWD_PHYS=""
    case "$SCOPE_CWD_PHYS_FOR" in
      "$HQ_ROOT") SCOPE_CWD_PHYS="$HQ_ROOT" ;;
      /*) SCOPE_CWD_PHYS="$(scope_resolve_absolute_path "$SCOPE_CWD_PHYS_FOR" 2>/dev/null || true)" ;;
    esac
  fi
}

# True when the command runs inside companies/ (the folder or any depth).
scope_cwd_in_companies() {
  scope_cwd_phys
  case "$SCOPE_CWD_PHYS" in
    "$HQ_ROOT/companies"|"$HQ_ROOT/companies/"*) return 0 ;;
  esac
  return 1
}

# True when companies/ holds a tenant folder this session may not open.
scope_has_foreign_companies() {
  local d n
  if [ -z "${SCOPE_FOREIGN_COMPANIES:-}" ]; then
    SCOPE_FOREIGN_COMPANIES=0
    for d in "$HQ_ROOT"/companies/*/; do
      [ -d "$d" ] || continue
      n="${d%/}"; n="${n##*/}"
      case "$n" in _*) continue ;; esac
      if ! scope_rel_allowed "companies/$n"; then
        SCOPE_FOREIGN_COMPANIES=1
        break
      fi
    done
  fi
  [ "$SCOPE_FOREIGN_COMPANIES" = 1 ]
}

# Check an absolute operand path as the program opens it. Besides the usual
# company check, refuse the companies/ folder itself while another company is
# present (a recursive tool reads every tenant through it), and, when the
# command runs inside companies/, the HQ root or any folder above it.
# True when the current record archives or copies whole trees (tar in
# create mode, zip, rsync, cp -r, ditto, ...) and <phys> is the HQ root or a
# folder above it, while another company's folder exists. Such a command
# copies every company's files, so a company-locked session may not run it
# (PR 1679 carryover: `tar cf /tmp/a.tar <hq-root>` from outside companies/).
# Search and listing tools (rg, grep -r, find, du) are not covered here.
scope_archiver_reaches_hq_root() {
  local phys="${1:-}"
  [ -n "$phys" ] || return 1
  case "${SCOPE_REC_HEAD:-}" in
    tar|gtar|bsdtar|zip|7z|7za|pax|cpio|rsync|rclone|gsutil|aws|hdiutil|ditto|scp|cp|mv) ;;
    *) return 1 ;;
  esac
  scope_record_is_recursive_reader || return 1
  # `tar -C DIR ...` reads its operands from DIR: then DIR itself decides.
  local ti tt cdir=""
  case "${SCOPE_REC_HEAD:-}" in
    tar|gtar|bsdtar)
      for ((ti = 0; ti < ${#scope_tokens[@]}; ti++)); do
        tt="${scope_tokens[$ti]}"
        case "$tt" in
          -C|--directory) cdir="${scope_tokens[$((ti + 1))]:-}"; break ;;
          --directory=*) cdir="${tt#--directory=}"; break ;;
          -C?*) cdir="${tt#-C}"; break ;;
        esac
      done
      if [ -n "$cdir" ]; then
        case "$cdir" in /*) ;; *) cdir="$(cd "${COMMAND_CWD:-$HQ_ROOT}" 2>/dev/null && pwd -P)/$cdir" ;; esac
        phys="$(scope_resolve_absolute_path "$cdir" 2>/dev/null || true)"
        [ -n "$phys" ] || return 1
      fi
      ;;
  esac
  if [ "$phys" = "$HQ_ROOT" ] || [ "$phys" = / ] || [[ "$HQ_ROOT" == "$phys"/* ]]; then
    scope_has_foreign_companies
    return
  fi
  return 1
}

scope_check_cwd_abs() {
  local abs="${1:-}" phys
  [ -n "$abs" ] || return 0
  phys="$(scope_resolve_absolute_path "$abs" 2>/dev/null || true)"
  [ -n "$phys" ] || scope_block_rel "companies/(unresolvable path from the working directory)" "a path from the working directory could not be resolved"
  if [ "${SCOPE_NAMES_ONLY:-0}" -eq 1 ]; then
    scope_check_raw "$abs"
    return 0
  fi
  if [ "$phys" = "$HQ_ROOT/companies" ] && scope_has_foreign_companies; then
    scope_block_rel "companies" "the operand is the companies/ folder, which holds other companies; name companies/<your-company>/... instead"
  fi
  if scope_archiver_reaches_hq_root "$phys"; then
    scope_block_rel "companies" "the operand is the HQ root or a folder above it, so this archive or copy takes other companies' files; name the folders you need instead"
  fi
  if scope_cwd_in_companies; then
    if [ "$phys" = "$HQ_ROOT" ] || [ "$phys" = / ] || [[ "$HQ_ROOT" == "$phys"/* ]]; then
      scope_block_rel "companies" "from inside companies/, the operand reaches the HQ root or a folder above it, which holds other companies"
    fi
  fi
  scope_check_raw "$abs"
}

# Check one argv word as the shell opens it from COMMAND_CWD: option-attached
# values (-f../x, --opt=../x), ~+ and ~-, globs (one expansion, capped), and
# slash-free names that exist there (only symlinks, unless the command runs
# inside companies/). Plain words with a slash are checked from the cwd by
# scope_check_bash_skill_path. From the HQ root only the companies/ folder
# rule applies; every other HQ-relative path is already checked.
scope_check_cwd_token() {
  local tok="${1:-}" val cwd abs alt is_opt=0 norm first name v
  case "$tok" in *'$'*|*$'\140'*)
    # $PWD, ${PWD}, $(pwd) and `pwd` are the working directory while the
    # command has not changed it; $OLDPWD is not known.
    if [ "${scope_cwd_is_static:-1}" -eq 1 ] && [ -n "${COMMAND_CWD:-}" ]; then
      tok="${tok//'${PWD}'/$COMMAND_CWD}"
      tok="${tok//'$PWD'/$COMMAND_CWD}"
      tok="${tok//'$(pwd)'/$COMMAND_CWD}"
      tok="${tok//'`pwd`'/$COMMAND_CWD}"
    fi
    case "$tok" in
      *'$HQ_ROOT'*|*'${HQ_ROOT}'*)
        if ! scope_literal_assignments HQ_ROOT && ! scope_var_assigned_nonliterally HQ_ROOT; then
          tok="${tok//'${HQ_ROOT}'/$HQ_ROOT}"
          tok="${tok//'$HQ_ROOT'/$HQ_ROOT}"
        fi
        ;;
    esac
    if [ -n "${HOME:-}" ]; then
      tok="${tok//'${HOME}'/$HOME}"
      tok="${tok//'$HOME'/$HOME}"
      case "$tok" in
        /*)
          case "$tok" in *'$'*|*$'\140'*|*[*?[{]*) ;; *) scope_check_cwd_abs "$tok"; return 0 ;; esac
          ;;
      esac
    fi
    case "$tok" in
      *'$OLDPWD'*|*'${OLDPWD}'*) scope_block_rel "\$OLDPWD" "\$OLDPWD names the previous directory, which the guard cannot follow" ;;
    esac
    # A bare variable: check every literal value the command assigns it;
    # with none, a recursive reader or copier fails closed.
    if [[ "$tok" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ ]]; then
      name="${BASH_REMATCH[1]}"
      case "$name" in HOME|PWD) return 0 ;; esac
      if scope_var_assigned_nonliterally "$name" && scope_token_is_tree_source; then
        scope_block_rel "\$$name" "a recursive reader or copier names \$$name, which this command sets to a value the guard cannot resolve"
      fi
      if scope_literal_assignments "$name"; then
        local scope_values="$SCOPE_ASSIGNED_VALUES" scope_unsure="$SCOPE_ASSIGN_UNSURE"
        if [ "$scope_unsure" -eq 1 ] && scope_token_is_tree_source; then
          scope_block_rel "\$$name" "a recursive reader or copier names \$$name, whose value the guard cannot resolve"
        fi
        # A value that is itself an expansion (w=$v) is followed a few levels.
        SCOPE_VAR_DEPTH=$(( ${SCOPE_VAR_DEPTH:-0} + 1 ))
        while IFS= read -r v; do
          [ -n "$v" ] || continue
          case "$v" in
            *'$'*|*$'\140'*)
              if [ "$SCOPE_VAR_DEPTH" -gt 4 ]; then
                scope_record_is_recursive_reader && scope_block_rel "\$$name" "a recursive reader or copier names a variable chain the guard cannot resolve"
                continue
              fi
              ;;
          esac
          case "$v" in
            /*) case "$v" in *[*?[{]*) scope_check_cwd_token "$v" ;; *) scope_lexical_abs "$v"; scope_check_cwd_abs "$SCOPE_LEXICAL_ABS" ;; esac ;;
            *) scope_check_cwd_token "$v" ;;
          esac
        done <<< "$scope_values"
        SCOPE_VAR_DEPTH=$(( SCOPE_VAR_DEPTH - 1 ))
        return 0
      fi
      # Assigned in this command some other way (for x in $(...), read,
      # x+=, declare -n, getopts, mapfile): its value is unknown.
      if scope_var_assigned_nonliterally "$name" && scope_token_is_tree_source; then
        scope_block_rel "\$$name" "a recursive reader or copier names \$$name, which this command sets to a value the guard cannot resolve"
      fi
      # Set outside this command and used whole: the existing variable rules
      # decide (`find "$TMPDIR" -name x`, `tar czf "$OUT" dist`).
      return 0
    fi
    # Any other expansion left in the word ($v$w, ${v}ies, ${v:1}, ${v,,},
    # ${UNSET:-x}, $(cmd), c$'x'): a tree reader or copier fails closed when
    # the word could spell a tenant folder, unless the literal folders before
    # the first expansion already pin it inside the bound company, workspace/
    # or repos/. (Applying this to every program blocked 50+ everyday
    # commands in the existing suites, so it stays on the tree-reader list.)
    if scope_record_is_recursive_reader; then
      # Variables the command assigns one literal value are read as that
      # value first (`W=companies/x/site; cp -R $W/out/. $OUT/`).
      local scope_var_re='\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?' scope_rest_tok="$tok" scope_vname scope_vval
      while [[ "$scope_rest_tok" =~ $scope_var_re ]]; do
        scope_vname="${BASH_REMATCH[1]}"
        scope_rest_tok="${scope_rest_tok#*"${BASH_REMATCH[0]}"}"
        case "$scope_vname" in HOME|PWD) continue ;; esac
        if scope_literal_assignments "$scope_vname" && [ "$SCOPE_ASSIGN_UNSURE" -eq 0 ]; then
          scope_vval="${SCOPE_ASSIGNED_VALUES%$'\n'}"
          case "$scope_vval" in *$'\n'*|*'$'*|*$'\140'*|'') continue ;; esac
          tok="${tok//"\${$scope_vname}"/$scope_vval}"
          tok="${tok//"\$$scope_vname"/$scope_vval}"
        fi
      done
      # `$VAR/sub/path` with a plain literal tail keeps the existing variable
      # rules; only built-up words (text joined to an expansion, operators,
      # mid-word $'..') get the rule below.
      # A whole positional or special parameter ("$1", "$@", "$_") is a
      # function argument or shell state: main's rules for ordinary programs,
      # unresolved for tree readers.
      local scope_param_re='^\$\{?([0-9]+|[@*#?!_-])\}?$'
      if [[ "$tok" =~ $scope_param_re ]]; then
        if scope_token_is_tree_source; then
          # Inside a function defined and called here with literal arguments,
          # check those arguments instead.
          if scope_positional_values "$tok"; then
            local scope_pv
            while IFS= read -r scope_pv; do
              [ -n "$scope_pv" ] && scope_check_cwd_token "$scope_pv"
            done <<< "$SCOPE_POS_VALUES"
            return 0
          fi
          scope_block_rel "$tok" "a recursive reader or copier names $tok, which the guard cannot resolve"
        fi
        return 0
      fi
      local scope_whole_re='^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?(/[A-Za-z0-9_.@+-]+)*/?$'
      if [[ "$tok" =~ $scope_whole_re ]] && [[ "/$tok/" != */../* ]]; then
        local scope_whole_name="${tok#\$}"
        scope_whole_name="${scope_whole_name#\{}"
        scope_whole_name="${scope_whole_name%%[!A-Za-z0-9_]*}"
        if scope_var_assigned_nonliterally "$scope_whole_name" && scope_token_is_tree_source; then
          scope_block_rel "$tok" "a recursive reader or copier names \$$scope_whole_name, which this command sets to a value the guard cannot resolve"
        fi
        return 0
      fi
      # $(mktemp ...) names a fresh temp path. $(git rev-parse --show-toplevel)
      # is resolved by running git in the command's cwd, and the result gets
      # the normal HQ-root and companies/ checks; if git cannot answer, a tree
      # reader fails closed. Only as the whole word or followed by `/`, and
      # only when the substitution runs nothing else (`$(mktemp; echo x)`
      # would add words of its own).
      local scope_safe_re='\$\((mktemp[^()$;&|<>`'"'"'"]*|git rev-parse --show-toplevel[[:space:]]*)\)(/|$)'
      while [[ "$tok" =~ $scope_safe_re ]]; do
        case "${BASH_REMATCH[1]}" in
          mktemp*) tok="${tok/"${BASH_REMATCH[0]}"//safe-substitution${BASH_REMATCH[2]}}" ;;
          *)
            # scope_git_toplevel runs its own regex matches.
            local scope_m0="${BASH_REMATCH[0]}" scope_m2="${BASH_REMATCH[2]}"
            scope_git_toplevel
            if [ -z "$SCOPE_GIT_TOPLEVEL" ]; then
              scope_token_is_tree_source && scope_block_rel "$tok" "git rev-parse --show-toplevel could not be resolved from the working directory"
              return 0
            fi
            tok="${tok/"$scope_m0"/$SCOPE_GIT_TOPLEVEL$scope_m2}"
            ;;
        esac
      done
      case "$tok" in
        *'$'*|*$'\140'*) ;;
        *)
          # Every expansion resolved: check the resulting word normally.
          case "$tok" in /safe-substitution*) return 0 ;; esac
          case "$tok" in
            /*) case "$tok" in *[*?[{]*) scope_check_cwd_value "$tok" 0 ;; *) scope_lexical_abs "$tok"; scope_check_cwd_abs "$SCOPE_LEXICAL_ABS" ;; esac ;;
            *) scope_check_cwd_value "$tok" 0 ;;
          esac
          return 0
          ;;
      esac
      local scope_tok_flat="$tok" scope_sub_re='\$\([^()]*\)'
      while [[ "$scope_tok_flat" =~ $scope_sub_re ]]; do
        scope_tok_flat="${scope_tok_flat/"${BASH_REMATCH[0]}"/X}"
      done
      case "$scope_tok_flat" in
        *[[:space:]]*) ;;  # a script or message argument, not a path operand
        *'$'*|*$'\140'*|*X*)
          if ! scope_token_is_search_pattern "${scope_token_index:-0}" \
            && ! scope_expansion_prefix_is_safe "$tok" \
            && scope_expansion_word_could_name_tenant "$tok"; then
            scope_block_rel "$tok" "a recursive reader or copier names a path the guard cannot resolve"
          fi
          ;;
      esac
    fi
    ;;
  esac
  case "$tok" in ''|*'$'*|*$'\140'*|*$'\001'*) return 0 ;; esac
  case "$tok" in
    --*=*) val="${tok#*=}"; is_opt=1 ;;
    -[A-Za-z]?*)
      # A short-option cluster with an attached value (-f../x, -rnf../x):
      # check the text after the option letters, and the text after the
      # first letter, when either looks like a path.
      is_opt=1
      val="${tok#-}"
      while [[ "$val" == [A-Za-z]* ]]; do val="${val:1}"; done
      alt="${tok:2}"
      if [ "$alt" != "$val" ]; then
        case "$alt" in .*|/*|'~'*|*/*) scope_check_cwd_value "$alt" 1 ;; esac
      fi
      case "$val" in .*|/*|'~'*|*/*) ;; *) return 0 ;; esac
      ;;
    -*) return 0 ;;
    *) val="$tok" ;;
  esac
  [ -n "$val" ] || return 0
  scope_check_cwd_value "$val" "$is_opt"
}

# True when <tok> occurs in the scanned command as a whole shell word (blank,
# quote or operator on both sides). A tokenizer fragment (`companies/` from
# `companies/(x)/y`) or a case pattern (`*)`) is not a word anyone passes.
scope_token_is_standalone_word() {
  local tok="${1:-}" padded
  # Quotes and backslashes join a word (`"companies"/`, `compan''ies/`), so
  # they are deleted; operators and blanks separate words.
  padded=" ${scope_scan_cmd:-}"$'\n'
  padded="${padded//[\"\'\\]/}"
  padded="${padded//[;|&<>$'\n'$'\t']/ } "
  [[ "$padded" == *" $tok "* ]]
}

# True when token <index> is the pattern operand of a real grep/rg: the first
# non-option word after the program when no -e/-f/--regexp/--file gives the
# pattern (`grep -rn 'companies/' core`).
scope_token_is_search_pattern() {
  local index="${1:-0}" h j t
  [ "${scope_head_untrusted:-1}" -eq 0 ] || return 1
  case "${SCOPE_REC_HEAD:-}" in grep|egrep|fgrep|rg) ;; *) return 1 ;; esac
  h="$(scope_command_head_index)"
  j=$((h + 1))
  while [ "$j" -lt "${#scope_tokens[@]}" ]; do
    t="${scope_tokens[$j]}"
    case "$t" in
      --) j=$((j + 1)); break ;;
      -e|-f|--regexp|--file|--regexp=*|--file=*|-e?*|-f?*) return 1 ;;
      -*) ;;
      *) break ;;
    esac
    j=$((j + 1))
  done
  [ "$j" -eq "$index" ]
}

# True when the current record only lists names or sizes or prints text:
# a real ls, du, echo or printf, or a for loop whose whole body is one
# echo/printf.
scope_record_only_lists_names() {
  local loop_re
  [ "${scope_head_untrusted:-1}" -eq 0 ] || return 1
  case "${SCOPE_REC_HEAD:-}" in
    ls|du)
      # A recursive or all-files listing prints every name below the folder.
      local t du_summary=0
      for t in "${scope_tokens[@]}"; do
        case "${SCOPE_REC_HEAD}:$t" in
          ls:--recursive|du:--all) return 1 ;;
          du:--summarize) du_summary=1 ;;
          *:--*) ;;
          ls:-*R*|du:-*a*) return 1 ;;
          du:-*s*) du_summary=1 ;;
        esac
      done
      # du lists every folder below its operand unless -s summarises it.
      [ "${SCOPE_REC_HEAD}" = du ] && [ "$du_summary" -eq 0 ] && return 1
      return 0
      ;;
    echo|printf) return 0 ;;
    for)
      loop_re='^[[:space:]]*for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]+[^;&|<>`$()]*[;'$'\n''][[:space:]]*do[[:space:]]+(echo|printf)[[:space:]][^;&|<>`()'$'\n'']*[;'$'\n''][[:space:]]*done[[:space:]]*$'
      [[ "${scope_scan_cmd:-}" =~ $loop_re ]] && return 0
      ;;
  esac
  return 1
}

# For a glob with a segment that starts with `.` and can match `.` or `..`
# (`.*`, `.?`, `.[.]`), check the word with that segment spelled `.` and
# `..`. One segment per call; the recursion handles the rest.
scope_check_dot_glob_spellings() {
  local val="${1:-}" is_opt="${2:-0}" pre="" rest seg after d cand
  rest="$val"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    if [[ "$rest" == */* ]]; then after="/${rest#*/}"; else after=""; fi
    case "$seg" in
      .*[*?[]*)
        for d in . ..; do
          # shellcheck disable=SC2053
          [[ "$d" == $seg ]] || continue
          cand="$pre$d$after"
          case "$cand" in
            *[*?[]*) scope_check_cwd_value "$cand" "$is_opt" ;;
            /*) scope_check_cwd_abs "$cand" ;;
            *) scope_check_cwd_abs "$SCOPE_CWD_PHYS/$cand" ;;
          esac
        done
        return 0
        ;;
    esac
    [ -n "$after" ] || break
    pre="$pre$seg/"
    rest="${after#/}"
  done
  return 0
}

# Quote state at the end of <text>: n (none), s (single), d (double).
scope_quote_state() {
  local text="${1:-}" i n=${#1} c st=n
  for ((i = 0; i < n; i++)); do
    c="${text:i:1}"
    case "$st:$c" in
      'n:\'|'d:\') i=$((i + 1)) ;;
      "n:'") st=s ;;
      'n:"') st=d ;;
      "s:'") st=n ;;
      'd:"') st=n ;;
    esac
  done
  SCOPE_QSTATE="$st"
}

# Rewrite $'...' (ANSI-C quoting) as a plain single-quoted word holding the
# decoded text, and $"..." (locale quoting) as "...". A decoded word that holds
# a quote or a control character makes the command fail closed. Result in
# SCOPE_DECODED_CMD. One printf per $'...' word; none for other commands.
scope_decode_dollar_quotes() {
  local text="${1:-}" out="" pre body i c decoded
  while [[ "$text" == *"\$'"* ]]; do
    pre="${text%%"\$'"*}"
    text="${text:$((${#pre} + 2))}"
    # `$'` is ANSI-C quoting only outside quotes and when the `$` is not
    # escaped or part of `$$` (`'cost$'`, `"$'"`, `$$'` are not).
    scope_quote_state "$out$pre"
    case "$SCOPE_QSTATE:$pre" in
      n:*'$'|n:*'\') out+="$pre\$'"; continue ;;
      n:*) ;;
      *) out+="$pre\$'"; continue ;;
    esac
    body=""
    i=0
    while [ "$i" -lt "${#text}" ]; do
      c="${text:i:1}"
      if [ "$c" = '\' ]; then body+="${text:i:2}"; i=$((i + 2)); continue; fi
      [ "$c" = "'" ] && break
      body+="$c"; i=$((i + 1))
    done
    [ "$i" -lt "${#text}" ] || scope_block_rel "\$'...'" "an ANSI-C quoted word is not closed"
    text="${text:$((i + 1))}"
    # printf %b wants \0NNN for octal; ANSI-C writes \NNN.
    decoded="$(printf '%s' "$body" | sed -E 's/\\([0-7])/\\0\1/g')"
    decoded="$(printf '%b' "$decoded" 2>/dev/null)" || decoded=""
    case "$decoded" in
      *"'"*|*[[:cntrl:]]*)
        # Text such as $'\n' or $'a\tb' keeps its original spelling; a word
        # that could name a path must decode to plain text.
        case "$decoded" in
          */*|*..*|*[cC][oO][mM][pP][aA][nN]*) scope_block_rel "\$'...'" "an ANSI-C quoted path decodes to a quote or a control character" ;;
        esac
        out+="$pre\$'$body'"
        continue
        ;;
    esac
    out+="$pre'$decoded'"
  done
  text="$out$text"
  text="${text//\$\"/\"}"
  SCOPE_DECODED_CMD="$text"
}

# The literal values a command assigns to <name>: `name=value` and
# `printf -v name %s value`. One value per line in SCOPE_ASSIGNED_VALUES;
# returns 1 when the command assigns none.
scope_literal_assignments() {
  local name="${1:-}" text="${scope_scan_cmd:-}" rest re v next
  SCOPE_ASSIGNED_VALUES=""
  SCOPE_ASSIGN_UNSURE=0
  # name=$(mktemp ...) is a fresh temp path; name=$(git rev-parse
  # --show-toplevel) is the current repo root, resolved here.
  local safe_re='(^|[;&|({[:space:]])'"$name"'=("?)\$\((mktemp[^()]*|git rev-parse --show-toplevel)\)("?)([;&|)[:space:]]|$)'
  local m0 m1
  while [[ "$text" =~ $safe_re ]]; do
    m0="${BASH_REMATCH[0]}"; m1="${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[3]}" in
      mktemp*) SCOPE_ASSIGNED_VALUES+="${TMPDIR:-/tmp}/scope-mktemp"$'\n' ;;
      *)
        scope_git_toplevel
        if [ -n "$SCOPE_GIT_TOPLEVEL" ]; then
          SCOPE_ASSIGNED_VALUES+="$SCOPE_GIT_TOPLEVEL"$'\n'
        else
          SCOPE_ASSIGN_UNSURE=1
        fi
        ;;
    esac
    text="${text/"$m0"/$m1}"
  done
  re='(^|[;&|({[:space:]])'"$name"'=("[^"`]*"|'"'"'[^'"'"']*'"'"'|[^][[:space:];&|<>()"'"'"'`]*)'
  rest="$text"
  while [[ "$rest" =~ $re ]]; do
    v="${BASH_REMATCH[2]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
    # A value the pattern could not take whole ($(...), `...`, quotes
    # joined to more text) is not a literal.
    next="${rest:0:1}"
    case "$next" in ''|[[:space:]]|';'|'&'|'|'|')'|$'\n') ;; *) SCOPE_ASSIGN_UNSURE=1 ;; esac
    v="${v#[\"\']}"; v="${v%[\"\']}"
    SCOPE_ASSIGNED_VALUES+="$v"$'\n'
  done
  re='printf[[:space:]]+-v[[:space:]]+'"$name"'[[:space:]]+("%s"|'"'"'%s'"'"'|%s)[[:space:]]+("[^"$`]*"|'"'"'[^'"'"']*'"'"'|[^][[:space:];&|<>()"'"'"'$`]+)'
  rest="$text"
  while [[ "$rest" =~ $re ]]; do
    v="${BASH_REMATCH[2]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
    # More arguments reuse the format and join onto the value.
    next="${rest#"${rest%%[![:space:]]*}"}"
    case "${next:0:1}" in ''|';'|'&'|'|'|')'|$'\n') ;; *) SCOPE_ASSIGN_UNSURE=1 ;; esac
    v="${v#[\"\']}"; v="${v%[\"\']}"
    SCOPE_ASSIGNED_VALUES+="$v"$'\n'
  done
  re='printf[[:space:]]+-v[[:space:]]+'"$name"'([[:space:]]|$)'
  if [[ "$text" =~ $re ]] && [ -z "$SCOPE_ASSIGNED_VALUES" ]; then
    SCOPE_ASSIGN_UNSURE=1
    SCOPE_ASSIGNED_VALUES=$'\n'
  fi
  [ -n "$SCOPE_ASSIGNED_VALUES" ]
}

# True when the command sets <name> other than by `name=literal`: a for loop
# over a list with an expansion, read, name+=, declare/local/typeset -n,
# getopts, mapfile/readarray.
scope_var_assigned_nonliterally() {
  local name="${1:-}" text="${scope_scan_cmd:-}" b='(^|[;&|({[:space:]])' e='([[:space:];&|)]|$)'
  [ -n "$name" ] || return 1
  # A bare `read` (with options only) and `select` fill $REPLY.
  if [ "$name" = REPLY ]; then
    [[ "$text" =~ ${b}(read|select)${e} ]] && return 0
  fi
  [[ "$text" =~ ${b}for[[:space:]]+${name}[[:space:]]+in[[:space:]][^\;]*[\$\`] ]] && return 0
  [[ "$text" =~ ${b}read([[:space:]][^\;\&\|]*)?[[:space:]]${name}${e} ]] && return 0
  [[ "$text" =~ ${b}${name}\+= ]] && return 0
  [[ "$text" =~ ${b}(declare|local|typeset)[[:space:]]+-[A-Za-z]*n[A-Za-z]*[[:space:]]+${name}${e} ]] && return 0
  [[ "$text" =~ ${b}(declare|local|typeset)[[:space:]]+-[A-Za-z]*n[A-Za-z]*[[:space:]]+${name}= ]] && return 0
  [[ "$text" =~ ${b}getopts[[:space:]]+[^[:space:]]+[[:space:]]+${name}${e} ]] && return 0
  [[ "$text" =~ ${b}(mapfile|readarray)([[:space:]][^\;\&\|]*)?[[:space:]]${name}${e} ]] && return 0
  return 1
}

# True when token <index> is the destination of a copy (cp, mv, rsync, scp,
# ditto, rclone, gsutil): the last operand when there are two or more, or the
# value of -t/--target-directory. It is written, not read.
scope_token_is_copy_destination() {
  local index="${1:-0}" h j t last=-1 count=0
  case "${SCOPE_REC_HEAD:-}" in cp|mv|rsync|scp|ditto|rclone|gsutil) ;; *) return 1 ;; esac
  h="$(scope_command_head_index)"
  [ "${scope_tokens[$((index - 1))]:-}" = -t ] && return 0
  [ "${scope_tokens[$((index - 1))]:-}" = --target-directory ] && return 0
  for ((j = h + 1; j < ${#scope_tokens[@]}; j++)); do
    t="${scope_tokens[$j]}"
    case "$t" in -*) continue ;; esac
    count=$((count + 1)); last=$j
  done
  [ "$count" -ge 2 ] && [ "$last" -eq "$index" ]
}

# True when the current token is a tree reader's source operand: the record
# reads a tree, and the token is neither a copy destination nor a search
# pattern.
scope_token_is_tree_source() {
  scope_record_is_recursive_reader || return 1
  scope_token_is_copy_destination "${scope_token_index:-0}" && return 1
  scope_token_is_search_pattern "${scope_token_index:-0}" && return 1
  return 0
}

# An absolute path with `.` and `..` segments folded, in SCOPE_LEXICAL_ABS,
# so `$R/../../companies` is checked as the directory it names.
scope_lexical_abs() {
  local in="$1" seg out="" IFS=/
  local -a parts
  read -r -a parts <<< "$in"
  for seg in ${parts[@]+"${parts[@]}"}; do
    case "$seg" in
      ''|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  SCOPE_LEXICAL_ABS="${out:-/}"
}

# The git top level of COMMAND_CWD (after any followed cd), cached per cwd,
# in SCOPE_GIT_TOPLEVEL; empty when git cannot answer.
scope_git_toplevel() {
  # The hook asks git before the command runs, so the answer is only trusted
  # when nothing else in the command can run first and change it: no other
  # substitution, no redirection other than to /dev/null, no GIT_* variable,
  # and at most one statement besides cd / pushd / popd and assignments,
  # with pipe readers limited to plain filters. Quotes and backslashes are
  # removed first.
  local plain="${scope_scan_cmd:-}" rest seg part head others=0 IFS w first
  local -a words=()
  plain="${plain//\'/}"; plain="${plain//\"/}"; plain="${plain//\\/}"
  for rest in '&>/dev/null' '2>/dev/null' '>/dev/null' '2>&1' '>&2'; do plain="${plain//"$rest"/}"; done
  plain="${plain//\$(git rev-parse --show-toplevel)/X}"
  while [[ "$plain" =~ \$\(mktemp[^\(\)\$\;\&\|\<\>\`]*\) ]]; do plain="${plain/"${BASH_REMATCH[0]}"/X}"; done
  case "$plain" in
    *'$('*|*'`'*|*'<('*|*'>'*|*GIT_*|*worktree*|*gitdir*)
      SCOPE_GIT_TOPLEVEL=""; SCOPE_GIT_TOPLEVEL_FOR="__unset__"; return 0 ;;
  esac
  plain="${plain//&&/;}"; plain="${plain//||/;}"; plain="${plain//&/;}"; plain="${plain//$'\n'/;}"
  local -a segs=() parts=()
  IFS=';' read -r -a segs <<< "$plain"
  for seg in ${segs[@]+"${segs[@]}"}; do
    first=1
    IFS='|' read -r -a parts <<< "$seg"
    for part in ${parts[@]+"${parts[@]}"}; do
      IFS=$' \t' read -r -a words <<< "$part"
      w=0
      while [ "$w" -lt "${#words[@]}" ] && [[ "${words[$w]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do w=$((w + 1)); done
      head="${words[$w]:-}"
      if [ "$first" = 1 ]; then
        case "$head" in ''|cd|pushd|popd|true|:|export|local) ;; *) others=$((others + 1)) ;; esac
      else
        case "$head" in head|tail|sort|wc|grep|uniq|cut|tr|cat|less|column|nl) ;; *) others=2 ;; esac
      fi
      first=0
    done
  done
  if [ "$others" -gt 1 ]; then
    SCOPE_GIT_TOPLEVEL=""; SCOPE_GIT_TOPLEVEL_FOR="__unset__"; return 0
  fi
  if [ "${SCOPE_GIT_TOPLEVEL_FOR-__unset__}" != "${COMMAND_CWD:-$HQ_ROOT}" ]; then
    SCOPE_GIT_TOPLEVEL_FOR="${COMMAND_CWD:-$HQ_ROOT}"
    SCOPE_GIT_TOPLEVEL="$(git -C "$SCOPE_GIT_TOPLEVEL_FOR" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$SCOPE_GIT_TOPLEVEL" ]; then
      scope_case_fold_text "$SCOPE_GIT_TOPLEVEL"
      SCOPE_GIT_TOPLEVEL="$SCOPE_CASE_TEXT"
    fi
  fi
}

# Positional parameters of the one function the command defines, when every
# call passes only literal words: $1..$9 to that argument of each call, $@ and
# $* to all of them. One value per line in SCOPE_POS_VALUES; returns 1 when
# that cannot be proven.
scope_positional_values() {
  local tok="${1:-}" text="${scope_scan_cmd:-}" re fname rest call args n idx v
  local -a defs=() words=()
  SCOPE_POS_VALUES=""
  re='(^|[;&|[:space:]])(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_-]*)[[:space:]]*\(\)[[:space:]]*\{'
  rest="$text"
  while [[ "$rest" =~ $re ]]; do
    defs+=("${BASH_REMATCH[3]}")
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
  [ "${#defs[@]}" -eq 1 ] || return 1
  fname="${defs[0]}"
  case "$tok" in
    '$@'|'${@}'|'$*'|'${*}') idx=all ;;
    *) idx="${tok//[^0-9]/}"; [ -n "$idx" ] && [ "$idx" -ge 1 ] || return 1 ;;
  esac
  # The body ends at the first `}` after the definition; calls come after.
  rest="${text#*"$fname"}"
  rest="${rest#*\}}"
  re='(^|[;&|[:space:]])'"$fname"'([[:space:]]+[^;&|<>()]*)?([;&|]|$)'
  n=0
  while [[ "$rest" =~ $re ]]; do
    args="${BASH_REMATCH[2]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
    case "$args" in *'$'*|*$'\140'*|*[\"\'\\*?[{]*) return 1 ;; esac
    read -r -a words <<< "$args"
    n=$((n + 1))
    if [ "$idx" = all ]; then
      for v in ${words[@]+"${words[@]}"}; do SCOPE_POS_VALUES+="$v"$'\n'; done
    else
      v="${words[$((idx - 1))]:-}"
      [ -n "$v" ] && SCOPE_POS_VALUES+="$v"$'\n'
    fi
  done
  [ "$n" -ge 1 ]
}

# tar runs the program named by -I / --use-compress-program / --to-command /
# --info-script / --new-volume-script / -F / --checkpoint-action=exec=. Only
# a bare program name with plain flags (`zstd -19`, `pigz`) is allowed; a
# shell, a path, an expansion or an operator is refused, since that program
# can read any file.
scope_check_tar_program_options() {
  local i k t v name full opt rest letters prog n start=-1 base flags plain h=0
  local flag_re='^([ 	]+-{1,2}[A-Za-z0-9_.,=+-]*)*$'
  local tar_word_re='(^|[^A-Za-z0-9_])(g|gnu|bsd)?tar([^A-Za-z0-9_]|$)'
  local -a progs=()
  n=${#scope_tokens[@]}
  [ "$n" -gt 0 ] || return 0
  # The command text with quotes and backslashes removed, so TAR_OPT""IONS
  # reads as written.
  plain="${SCOPE_TAR_TEXT:-${scope_scan_cmd:-}}"
  plain="${plain//\'/}"; plain="${plain//\"/}"; plain="${plain//\\/}"
  # GNU tar reads extra options from TAR_OPTIONS; refuse any mention, and
  # in a command that runs tar, refuse an assignment or export whose name
  # is built from an expansion (`${T}OPTIONS=`, `export $(...)`), since it
  # can set TAR_OPTIONS.
  case "$plain" in
    *TAR_OPT*) scope_block_rel "TAR_OPTIONS" "tar options set through TAR_OPTIONS cannot be checked; pass them on the tar command line" ;;
  esac
  if [[ "$plain" =~ $tar_word_re ]]; then
    local built_name_re='(^|[;&|({[:space:]])[A-Za-z0-9_]*\$[^=[:space:];&|]*='
    local built_export_re='(^|[;&|({[:space:]])(export|declare|typeset|readonly|local|env|set)([[:space:]]+-[A-Za-z-]+)*[[:space:]]+[^=[:space:];&|]*\$'
    if [[ "$plain" =~ $built_name_re ]] || [[ "$plain" =~ $built_export_re ]]; then
      scope_block_rel "tar environment" "a variable name built from an expansion could set TAR_OPTIONS for tar; spell the name"
    fi
  fi
  # A command that names tar, carries a tar program option, and also runs
  # a shell, eval or an interpreter (`eval '...'`, `env sh -c`, `| sh`,
  # `sh <<<`, `python3 -c`) can hand tar that option in text this check does
  # not parse: fail closed.
  local prog_opt_re='(^|[[:space:]])(-[A-Za-z]*[IF]|--(use-c|to-c|info|new-v|checkpoint-a|rsh|rmt))'
  # Every program that can run text it is given: shells, eval and source,
  # `.`, interpreters (awk and R included, PR 1679 carryover), and the
  # tools that turn input or a written file into commands (xargs, parallel,
  # make, chmod +x then a path).
  local runner_re='(^|[^A-Za-z0-9_./-])(sh|bash|zsh|dash|ksh|mksh|ash|tcsh|csh|fish|busybox|eval|source|exec|python[0-9.]*|perl[0-9.]*|ruby|node|nodejs|deno|bun|php|lua|luajit|tclsh|wish|expect|osascript|awk|gawk|mawk|nawk|busybox|Rscript|R|julia|swift|xargs|parallel|make|gmake|chmod|env|nohup|script|watch)([[:space:]]|$)'
  local dot_runner_re='(^|[;&|({!]|'$'\n'')[[:space:]]*\.[[:space:]]'
  local path_head_re='(^|[;&|({!]|'$'\n'')[[:space:]]*(\./|/|~/)[^[:space:];&|]*'
  if [[ "$plain" =~ $tar_word_re ]] && [[ "$plain" =~ $prog_opt_re ]]; then
    # An interpreter run on a script file the command neither writes nor
    # pipes into (`tar -I zstd -cf a.tar.zst src && python3 build.py`) is
    # not handed this command's text, so that word alone does not refuse
    # the command. Anything else that can run text still does.
    local runner_text="$plain" file_runner_re file_word
    file_runner_re='(^|[;&({[:space:]])(python[0-9.]*|node|ruby|perl|php|Rscript)[[:space:]]+([A-Za-z0-9_./-]+\.(py|js|mjs|cjs|rb|pl|php|R))([[:space:];&)]|$)'
    case "$plain" in
      *'<<'*|*'<('*|*'>('*) ;;
      *)
        while [[ "$runner_text" =~ $file_runner_re ]]; do
          file_word="${BASH_REMATCH[3]}"
          local file_before="${runner_text%%"${BASH_REMATCH[0]}"*}"
          case "$file_before" in *'|') break ;; esac
          case "${file_before%"${file_before##*[![:space:]]}"}" in *'|') break ;; esac
          # The script file must be named nowhere else in the command.
          [ "$(printf '%s' "$plain" | grep -oF -- "${file_word##*/}" | wc -l | tr -d '[:space:]')" = "1" ] || break
          runner_text="${runner_text/"${BASH_REMATCH[0]}"/ }"
        done
        ;;
    esac
    if [[ "$runner_text" =~ $runner_re ]] || [[ "$plain" =~ $dot_runner_re ]]; then
      scope_block_rel "tar in a nested shell" "a tar program option next to a shell, eval, source, an interpreter or a command runner cannot be checked; run tar directly"
    fi
    local write_re='(^|[^A-Za-z0-9_])(>|tee|cp|mv|ln|install|curl|wget)([^A-Za-z0-9_]|$)'
    if [[ "$plain" =~ $path_head_re ]] && [[ "$plain" =~ $write_re ]]; then
      scope_block_rel "tar in a written script" "a tar program option in a command that writes a file and runs a program by path cannot be checked; run tar directly"
    fi
  fi
  # Skip shell keywords and grouping words at the start of the record.
  while [ "$h" -lt "$n" ]; do
    case "${scope_tokens[$h]}" in
      '{'|'('|'!'|then|do|else|elif|if|while|until|time) h=$((h + 1)) ;;
      *) break ;;
    esac
  done
  [ "$h" -lt "$n" ] || return 0
  # A shell given a -c body: run the same checks on each command in the
  # body, a few levels deep at most; deeper nesting fails closed.
  case "${scope_tokens[$h]##*/}" in
    sh|bash|zsh|dash|ksh|mksh|ash|busybox)
      for ((i = h + 1; i < n; i++)); do
        case "${scope_tokens[$i]}" in
          --*) ;;
          -*c*)
            v="${scope_tokens[$((i + 1))]:-}"
            [ -n "$v" ] || break
            if [[ "$v" =~ $tar_word_re ]] || [[ "$v" == *'$'* ]]; then
              if [ "${SCOPE_TAR_DEPTH:-0}" -ge 4 ]; then
                scope_block_rel "tar in nested shell" "tar inside deeply nested shell -c bodies cannot be checked"
              fi
              local -a saved_tokens=("${scope_tokens[@]}")
              local saved_text="${SCOPE_TAR_TEXT-}" rec
              SCOPE_TAR_DEPTH=$(( ${SCOPE_TAR_DEPTH:-0} + 1 ))
              SCOPE_TAR_TEXT="$plain"$'\n'"$v"
              while IFS= read -r rec; do
                [ -n "$rec" ] || continue
                IFS=$'\037' read -r -a scope_tokens <<< "$rec"
                scope_check_tar_program_options
              done <<< "$(hq_shell_simple_commands "$v")"
              SCOPE_TAR_DEPTH=$(( SCOPE_TAR_DEPTH - 1 ))
              SCOPE_TAR_TEXT="$saved_text"
              scope_tokens=("${saved_tokens[@]}")
            fi
            break
            ;;
          -*) ;;
          *) break ;;
        esac
      done
      ;;
  esac
  # tar may follow a wrapper (command, env, nice, time, xargs, sudo ...).
  for ((i = h; i < n; i++)); do
    case "${scope_tokens[$i]##*/}" in
      tar|gtar|gnutar|bsdtar) start=$i; break ;;
    esac
  done
  # A head the hook cannot name (an expansion, such as `$t` or `t"$1"`
  # inside a function), or a function or alias this command defines in a
  # command that names tar, may still be tar: read its options as tar's.
  if [ "$start" -lt 0 ]; then
    case "${scope_tokens[$h]}" in
      *'$'*|*'`'*) start=$h ;;
    esac
    name="${scope_tokens[$h]}"
    if [ "$start" -lt 0 ] && [[ "$plain" =~ $tar_word_re ]] && [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; then
      case "$plain" in
        *"$name()"*|*"$name ()"*|*"function $name"*|*"alias $name="*) start=$h ;;
      esac
    fi
  fi
  [ "$start" -ge 0 ] || return 0
  # A word that opens with an expansion (`t=ta; p=-I; ${t}r xf e.tar $p sh`)
  # can become an option once the shell expands it, since tar reads options
  # anywhere on its command line. Such a word passes only when every value
  # the command proves for it is a plain word that does not start with `-`;
  # an unknown value fails closed (PR 1679 carryover). A word consumed as
  # the value of -f, -C and similar is skipped below.
  local -a tar_consumed=()
  # Only a record that is tar, or whose command word is built from an
  # expansion with nothing but name characters before it (`${t}r`,
  # `t"$1"`), gets this argument check. A record the head scan above took
  # for tar because its first word holds a `$` somewhere else (an
  # assignment, interpreter source text) keeps the program-option checks
  # below only.
  local tar_args_check=0 tar_head="${scope_tokens[$start]}"
  case "${tar_head##*/}" in tar|gtar|gnutar|bsdtar) tar_args_check=1 ;; esac
  local tar_head_re='^[A-Za-z0-9_-]*"?\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*|[1-9]|\{[1-9]\})"?[A-Za-z0-9_-]*$'
  if [ "$tar_args_check" -eq 0 ] && [[ "$tar_head" =~ $tar_head_re ]]; then
    tar_args_check=1
  fi
  if [ "$tar_args_check" -eq 0 ] && [[ "$tar_head" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; then
    tar_args_check=1
  fi
  for ((i = start + 1; i < n && tar_args_check == 1; i++)); do
    t="${scope_tokens[$i]}"
    case "$t" in --) break ;; esac
    case "$t" in
      -*)
        rest="${t#-}"
        case "$t" in --*) case "$t" in *=*) ;; --file|--directory|--files-from|--exclude-from|--label|--blocking-factor|--group|--owner|--mode|--newer|--after-date|--volno-file|--tape-length|--record-size|--transform|--xform|--exclude|--strip-components) tar_consumed[$((i + 1))]=1 ;; esac; continue ;; esac
        while [ -n "$rest" ]; do
          opt="${rest:0:1}"; rest="${rest:1}"
          case "$opt" in
            f|C|T|X|b|g|K|L|N|V|H|I|F) [ -z "$rest" ] && tar_consumed[$((i + 1))]=1; break ;;
          esac
        done
        ;;
      *)
        if [ "$i" -eq $((start + 1)) ]; then
          letters="$t"; k=$((i + 1))
          while [ -n "$letters" ]; do
            opt="${letters:0:1}"; letters="${letters:1}"
            case "$opt" in f|C|T|X|b|g|K|L|N|V|H|I|F) tar_consumed[$k]=1; k=$((k + 1)) ;; esac
          done
        fi
        ;;
    esac
  done
  for ((i = start + 1; i < n && tar_args_check == 1; i++)); do
    t="${scope_tokens[$i]}"
    [ "$t" = -- ] && break
    [ -n "${tar_consumed[$i]:-}" ] && continue
    case "$t" in
      '$'*|'`'*|'"$'*|'"`'*)
        local tar_tok tar_name tar_vals tar_val tar_dq tar_sub
        tar_dq="${t//\"/}"
        # A substitution whose body prints no option: a path the guard maps
        # (`$(git rev-parse --show-toplevel)`, `$(pwd)`, `$(mktemp)`) or a
        # non-path word (scope_subst_body_is_safe). `seq` can print `-1`.
        case "$tar_dq" in
          '$('*)
            tar_sub="${tar_dq#\$(}"
            tar_sub="${tar_sub%%)*}"
            case "$tar_sub" in seq*|*'('*|*'$'*|*'`'*) ;; *)
              if scope_subst_body_is_safe "$tar_sub"; then continue; fi
              ;;
            esac
            scope_block_rel "$t" "a tar argument starts with a command substitution whose output can become a program option such as -I; spell it literally"
            ;;
          '`'*) scope_block_rel "$t" "a tar argument starts with a command substitution whose output can become a program option such as -I; spell it literally" ;;
        esac
        # Function positional parameters bound to literal call words.
        tar_tok="$(printf '%s' "$tar_dq" | grep -oE '^\$(\{?[1-9@*]\}?)' || true)"
        if [ -n "$tar_tok" ]; then
          scope_positional_values "$tar_tok" \
            || scope_block_rel "$t" "a tar argument comes from a function parameter the guard cannot bind to literal words; spell it literally"
          while IFS= read -r tar_val; do
            [ -n "$tar_val" ] || continue
            case "$tar_val" in -*) scope_block_rel "$t" "a tar argument expands to an option, which can name a program for tar to run; spell the option literally" ;; esac
          done <<< "$SCOPE_POS_VALUES"
          continue
        fi
        tar_tok="$(printf '%s' "$tar_dq" | grep -oE '^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' || true)"
        [ -n "$tar_tok" ] || scope_block_rel "$t" "a tar argument starts with an expansion the guard cannot read, so it can become a program option such as -I; spell it literally"
        tar_name="${tar_tok#\$}"; tar_name="${tar_name#\{}"; tar_name="${tar_name%\}}"
        # A name this command never sets comes from the session's own
        # environment, which the command cannot choose; only a value the
        # command assigns can smuggle an option (`p=-I; tar ... $p sh`).
        scope_command_may_set_var "$tar_name" "${SCOPE_FULL_CMD:-$plain}" || continue
        # $HOME, $PWD and $TMPDIR, when the command does not set them, and a
        # `NAME=$(mktemp ...)` value are absolute paths, never options.
        case "$tar_name" in
          HOME|PWD|TMPDIR)
            scope_command_may_set_var "$tar_name" "${SCOPE_FULL_CMD:-$plain}" || continue
            ;;
        esac
        if scope_mktemp_assignment_value "$tar_name" "${SCOPE_FULL_CMD:-$plain}" >/dev/null 2>&1; then
          continue
        fi
        tar_vals="$(scope_shell_variable_values "$tar_name" "${SCOPE_FULL_CMD:-$plain}" "${SCOPE_FULL_CMD:-$plain}" 2>/dev/null || true)"
        [ -n "$tar_vals" ] || scope_block_rel "$t" "a tar argument starts with an expansion the guard cannot read, so it can become a program option such as -I; spell it literally"
        while IFS= read -r tar_val; do
          case "$tar_val" in
            ''|-*) scope_block_rel "$t" "a tar argument expands to an option, which can name a program for tar to run; spell the option literally" ;;
          esac
        done <<< "$tar_vals"
        ;;
    esac
  done
  for ((i = start + 1; i < n; i++)); do
    t="${scope_tokens[$i]}"
    case "$t" in
      --) break ;;
      --*)
        # GNU tar accepts any unambiguous prefix of a long option.
        name="${t%%=*}"
        [ "${#name}" -ge 5 ] || continue
        for full in --use-compress-program --to-command --info-script --new-volume-script --checkpoint-action --rsh-command --rmt-command; do
          case "$full" in "$name"*) ;; *) continue ;; esac
          [ "$full" = --checkpoint-action ] && [ "$name" = --checkpoint ] && continue
          case "$t" in *=*) v="${t#*=}" ;; *) v="${scope_tokens[$((i + 1))]:-}" ;; esac
          case "$full" in
            --checkpoint-action) case "$v" in exec=*) progs+=("!${v#exec=}") ;; esac ;;
            --use-compress-program) progs+=("$v") ;;
            *) progs+=("!$v") ;;
          esac
          break
        done
        ;;
      -*)
        # A short cluster: an option taking a value takes the rest of the
        # cluster, or the next word when the rest is empty.
        rest="${t#-}"
        while [ -n "$rest" ]; do
          opt="${rest:0:1}"; rest="${rest:1}"
          case "$opt" in
            I) if [ -n "$rest" ]; then progs+=("$rest"); else progs+=("${scope_tokens[$((i + 1))]:-}"); fi; break ;;
            F) if [ -n "$rest" ]; then progs+=("!$rest"); else progs+=("!${scope_tokens[$((i + 1))]:-}"); fi; break ;;
            f|C|T|X|b|g|K|L|N|V|H) break ;;
          esac
        done
        ;;
      *)
        # Old-style first argument (`tar cIf zstd a.tar`): every letter that
        # takes a value consumes the next word in order.
        [ "$i" -eq $((start + 1)) ] || continue
        letters="$t"; k=$((i + 1))
        while [ -n "$letters" ]; do
          opt="${letters:0:1}"; letters="${letters:1}"
          case "$opt" in
            I) progs+=("${scope_tokens[$k]:-}"); k=$((k + 1)) ;;
            F) progs+=("!${scope_tokens[$k]:-}"); k=$((k + 1)) ;;
            f|C|T|X|b|g|K|L|N|V|H) k=$((k + 1)) ;;
          esac
        done
        ;;
    esac
  done
  # The compression program must be a known compressor, by bare name or
  # from a system bin directory, with plain flags. The other program
  # options (marked !) run arbitrary programs and are always refused.
  # ANSI-C quoting can put a newline or other bytes in the program string
  # that the words seen here do not show; GNU tar runs it through sh -c.
  if [ "${#progs[@]}" -gt 0 ]; then
    case "${INPUT:-}" in
      *"\$'"*|*'$"'*)
        scope_block_rel "tar program option" "the tar program string uses \$'...' quoting or spans lines; spell the compressor plainly" ;;
    esac
    case "${cmd:-}" in
      *$'\n'*) scope_block_rel "tar program option" "a tar program option in a multi-line command cannot be checked; run tar on one line" ;;
    esac
  fi
  for v in ${progs[@]+"${progs[@]}"}; do
    case "$v" in
      '!'*) scope_block_rel "tar program option" "tar would run '${v#!}', which can read any file" ;;
    esac
    prog="${v#"${v%%[![:space:]]*}"}"
    base="${prog%%[[:space:]]*}"
    flags="${prog#"$base"}"
    case "$base" in
      */*) case "${base%/*}" in /bin|/usr/bin|/usr/local/bin|/opt/homebrew/bin|/opt/local/bin) ;; *) base="" ;; esac ;;
    esac
    case "${base##*/}" in
      gzip|gunzip|pigz|unpigz|xz|unxz|pixz|zstd|unzstd|zstdmt|pzstd|bzip2|bunzip2|pbzip2|lbzip2|lz4|unlz4|lzip|plzip|lunzip|lzma|unlzma|lzop|brotli|compress|uncompress)
        [[ "$flags" =~ $flag_re ]] && continue ;;
    esac
    scope_block_rel "tar program option" "tar would run '$v', which can read any file; use a compressor such as zstd, xz or pigz"
  done
  return 0
}

# True when the current record reads or copies a whole tree: tar, zip,
# rsync, ditto, find, rg, and cp/grep with a recursive option.
scope_record_is_recursive_reader() {
  local t
  [ "${#scope_tokens[@]}" -gt 0 ] || return 1
  case "${SCOPE_REC_HEAD:-}" in
    du)
      # du -s only reports one size per operand.
      for t in "${scope_tokens[@]}"; do
        case "$t" in --summarize) return 1 ;; --*) ;; -*s*) return 1 ;; esac
      done
      return 0
      ;;
    tar|gtar|bsdtar)
      # Extract and list modes read only the archive; -C is where they write.
      local first="" ti
      for ((ti = 1; ti < ${#scope_tokens[@]}; ti++)); do
        t="${scope_tokens[$ti]}"
        [ "$t" = "${SCOPE_REC_HEAD}" ] && continue
        [ -z "$first" ] && first="$t"
        case "$t" in --extract|--list|--get) return 1 ;; --*) ;; -*[xt]*) return 1 ;; esac
      done
      case "$first" in -*|'') ;; *[xt]*) [[ "$first" =~ ^[A-Za-z]+$ ]] && return 1 ;; esac
      return 0
      ;;
    zip|7z|7za|pax|cpio|rsync|rclone|gsutil|aws|hdiutil|ditto|find|rg|scp|tree|mv) return 0 ;;
    cp|grep|egrep|fgrep|ls)
      for t in "${scope_tokens[@]}"; do
        case "$t" in
          --recursive|--dereference-recursive|--archive) return 0 ;;
          --*) ;;
          -*[rRa]*) [ "${SCOPE_REC_HEAD}" = ls ] && [[ "$t" != -*R* ]] && continue; return 0 ;;
        esac
      done
      ;;
  esac
  return 1
}

# True when <word>, with every expansion read as "anything", could spell the
# companies/ folder, another company's folder, `..`, or the HQ root:
# `${UNSET}companies` (*companies), `c$'ompanies'` (c*), `"$v/"` (*/),
# `${PWD%indigo}otherco` (*otherco). `$C/plain` (*/plain) and
# `out-$(date).tgz` (out-*.tgz) cannot.
scope_expansion_word_could_name_tenant() {
  local word="${1:-}" glob="" rest c i n depth cand d slug bt=$'\140'
  rest="$word"
  # Read the word left to right, turning each expansion into one `*`.
  while [ -n "$rest" ]; do
    c="${rest:0:1}"
    case "$c" in
      '"'|"'"|'\') rest="${rest:1}" ;;
      "$bt")
        rest="${rest:1}"
        [[ "$rest" == *"$bt"* ]] && rest="${rest#*"$bt"}" || rest=""
        glob+="*"
        ;;
      '$')
        rest="${rest:1}"
        case "$rest" in
          '{'*)
            depth=0; n=${#rest}
            for ((i = 0; i < n; i++)); do
              case "${rest:i:1}" in '{') depth=$((depth + 1)) ;; '}') depth=$((depth - 1)); [ "$depth" -eq 0 ] && break ;; esac
            done
            rest="${rest:i+1}"
            ;;
          '('*)
            depth=0; n=${#rest}
            for ((i = 0; i < n; i++)); do
              case "${rest:i:1}" in '(') depth=$((depth + 1)) ;; ')') depth=$((depth - 1)); [ "$depth" -eq 0 ] && break ;; esac
            done
            rest="${rest:i+1}"
            ;;
          "'"*) rest="${rest:1}"; [[ "$rest" == *"'"* ]] && rest="${rest#*"'"}" || rest="" ;;
          '"'*) rest="${rest:1}"; [[ "$rest" == *'"'* ]] && rest="${rest#*'"'}" || rest="" ;;
          [A-Za-z_]*) rest="${rest#"${rest%%[!A-Za-z0-9_]*}"}" ;;
          [0-9@*#?\$!-]*) rest="${rest:1}" ;;
        esac
        glob+="*"
        ;;
      *) glob+="$c"; rest="${rest:1}" ;;
    esac
  done
  # A `..` after an unknown prefix climbs from somewhere the guard cannot see.
  [[ "/$glob/" == */../* ]] && return 0
  # Candidate spellings of a tenant folder or a folder above one.
  local -a cands=(companies companies/ .. ../ ../.. "$HQ_ROOT" "$HQ_ROOT/" "$HQ_ROOT/companies" "$HQ_ROOT/companies/" /)
  for d in "$HQ_ROOT"/companies/*/; do
    [ -d "$d" ] || continue
    slug="${d%/}"; slug="${slug##*/}"
    case "$slug" in _*) continue ;; esac
    scope_rel_allowed "companies/$slug" && continue
    cands+=("companies/$slug" "$slug" "$HQ_ROOT/companies/$slug" "../$slug")
  done
  for cand in "${cands[@]}"; do
    # shellcheck disable=SC2053
    [[ "$cand" == $glob ]] && return 0
  done
  return 1
}

# True when the literal leading folders of <word> (the text before its first
# `$` or backtick, up to the last `/`) resolve inside the bound company,
# workspace/ or repos/.
scope_expansion_prefix_is_safe() {
  local word="${1:-}" pre phys rel cwd
  pre="${word%%[\$\`]*}"
  [[ "$pre" == */* ]] || return 1
  pre="${pre%/*}"
  [ -n "$pre" ] || return 1
  scope_cwd_phys
  cwd="${SCOPE_CWD_PHYS:-$HQ_ROOT}"
  case "$pre" in '~'/*) pre="$HOME/${pre#'~'/}" ;; esac
  case "$pre" in /*) phys="$pre" ;; *) phys="$cwd/$pre" ;; esac
  phys="$(scope_resolve_absolute_path "$phys" 2>/dev/null || true)"
  case "$phys" in
    "$HQ_ROOT"/workspace|"$HQ_ROOT"/workspace/*|"$HQ_ROOT"/repos|"$HQ_ROOT"/repos/*) return 0 ;;
    "$HQ_ROOT"/companies/?*/*|"$HQ_ROOT"/companies/?*)
      rel="${phys#"$HQ_ROOT"/}"
      scope_rel_allowed "$rel" && return 0
      ;;
  esac
  return 1
}

# Lexical brace expansion of <word>: every top-level {a,b,...} group, nested
# groups expanded recursively. Results in SCOPE_BRACE_WORDS; returns 1 when
# the word expands to more than 64 words or nests too deeply.
scope_brace_expand() {
  local word="${1:-}" depth="${2:-0}" pre body post i c level=0 open=-1 close=-1 has_comma=0
  local -a parts=() out=() sub=()
  local part p w
  SCOPE_BRACE_WORDS=()
  [ "$depth" -le 8 ] || return 1
  # Like bash, use the first `{` that has a matching `}` with a top-level
  # comma or `..` between them; an unmatched `{` stays literal.
  local start
  for ((start = 0; start < ${#word}; start++)); do
    [ "${word:start:1}" = '{' ] || continue
    level=0; has_comma=0; close=-1
    for ((i = start; i < ${#word}; i++)); do
      c="${word:i:1}"
      case "$c" in
        '{') level=$((level + 1)) ;;
        '}')
          level=$((level - 1))
          if [ "$level" -eq 0 ]; then close=$i; break; fi
          ;;
        ',') [ "$level" -eq 1 ] && has_comma=1 ;;
        '.') [ "$level" -eq 1 ] && [ "${word:i+1:1}" = . ] && has_comma=1 ;;
      esac
    done
    if [ "$close" -ge 0 ] && [ "$has_comma" -eq 1 ]; then
      open=$start
      break
    fi
    close=-1
  done
  if [ "$open" -lt 0 ] || [ "$close" -lt 0 ]; then
    SCOPE_BRACE_WORDS=("$word")
    return 0
  fi
  pre="${word:0:open}"
  body="${word:open+1:close-open-1}"
  post="${word:close+1}"
  # Split body on top-level commas.
  level=0; part=""
  for ((i = 0; i < ${#body}; i++)); do
    c="${body:i:1}"
    case "$c" in
      '{') level=$((level + 1)); part+="$c" ;;
      '}') level=$((level - 1)); part+="$c" ;;
      ',') if [ "$level" -eq 0 ]; then parts+=("$part"); part=""; else part+="$c"; fi ;;
      *) part+="$c" ;;
    esac
  done
  parts+=("$part")
  # A sequence {a..e}, {1..9}, {a..p..2}: expand it (at most 64 items).
  if [ "${#parts[@]}" -eq 1 ]; then
    local seq_re='^(-?[0-9]+|[A-Za-z])\.\.(-?[0-9]+|[A-Za-z])(\.\.(-?[0-9]+))?$' a b st n k letters='ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz'
    if [[ "$body" =~ $seq_re ]]; then
      a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; st="${BASH_REMATCH[4]:-1}"
      st="${st#-}"; [ "$st" -ne 0 ] 2>/dev/null || st=1
      parts=()
      if [[ "$a" =~ ^-?[0-9]+$ ]] && [[ "$b" =~ ^-?[0-9]+$ ]]; then
        [ $(( (a > b ? a - b : b - a) / st )) -le 64 ] || return 1
        if [ "$a" -le "$b" ]; then
          for ((n = a; n <= b; n += st)); do parts+=("$n"); done
        else
          for ((n = a; n >= b; n -= st)); do parts+=("$n"); done
        fi
      elif [[ "$a" =~ ^[A-Za-z]$ ]] && [[ "$b" =~ ^[A-Za-z]$ ]]; then
        a="${letters%%"$a"*}"; a=${#a}
        b="${letters%%"$b"*}"; b=${#b}
        if [ "$a" -le "$b" ]; then
          for ((k = a; k <= b; k += st)); do parts+=("${letters:k:1}"); done
        else
          for ((k = a; k >= b; k -= st)); do parts+=("${letters:k:1}"); done
        fi
      else
        return 1
      fi
    fi
  fi
  for p in "${parts[@]}"; do
    scope_brace_expand "$pre$p$post" $((depth + 1)) || return 1
    for w in "${SCOPE_BRACE_WORDS[@]}"; do
      out+=("$w")
      [ "${#out[@]}" -le 64 ] || return 1
    done
  done
  SCOPE_BRACE_WORDS=("${out[@]}")
  return 0
}

# True when the fixed (wildcard-free) leading folders of glob <val> resolve,
# from <cwd>, inside the bound company, workspace/ or repos/.
scope_glob_prefix_is_safe() {
  local val="${1:-}" cwd="${2:-}" prefix="" seg rest phys rel
  rest="$val"
  while [[ "$rest" == */* ]]; do
    seg="${rest%%/*}"
    case "$seg" in *[*?[]*) break ;; esac
    prefix="$prefix$seg/"
    rest="${rest#*/}"
  done
  case "$prefix" in /*) phys="$prefix" ;; *) phys="$cwd/$prefix" ;; esac
  phys="$(scope_resolve_absolute_path "$phys" 2>/dev/null || true)"
  case "$phys" in
    "$HQ_ROOT"/workspace|"$HQ_ROOT"/workspace/*|"$HQ_ROOT"/repos|"$HQ_ROOT"/repos/*) return 0 ;;
    "$HQ_ROOT"/companies/?*)
      rel="${phys#"$HQ_ROOT"/}"
      scope_rel_allowed "$rel" && return 0
      ;;
  esac
  return 1
}

# Check one value (an argv word, or an option's attached value) as the shell
# opens it from COMMAND_CWD. See scope_check_cwd_token.
scope_check_cwd_value() {
  local val="${1:-}" is_opt="${2:-0}" cwd abs matches m count=0 norm first w safe=-1
  [ -n "$val" ] || return 0
  scope_cwd_phys
  cwd="$SCOPE_CWD_PHYS"
  [ -n "$cwd" ] || return 0
  case "$val" in
    '~+'|'~+/'*) scope_check_cwd_abs "$cwd${val#'~+'}"; return 0 ;;
    '~-'|'~-/'*) scope_block_rel "$val" "~- names the previous directory, which the guard cannot follow" ;;
    '~'|'~/'*) [ -n "${HOME:-}" ] || return 0; val="$HOME${val#'~'}" ;;
    '~'*) return 0 ;;
  esac
  # An absolute spelling of the companies/ folder, through any symlinked
  # path to the HQ root ("$HOME/hqlink/companies", ~/hqlink/companies/).
  case "$val" in
    /*)
      case "$val" in
        *[*?[{]*) ;;
        *)
          if [ -e "$val" ] && [ "${SCOPE_NAMES_ONLY:-0}" -eq 0 ] && ! scope_record_only_lists_names; then
            norm="$(scope_resolve_absolute_path "$val" 2>/dev/null || true)"
            if [ "$norm" = "$HQ_ROOT/companies" ] && scope_has_foreign_companies; then
              scope_block_rel "companies" "the operand is the companies/ folder, which holds other companies; name companies/<your-company>/... instead"
            fi
          fi
          ;;
      esac
      ;;
  esac
  # Brace patterns expand lexically from any cwd; each word is checked.
  case "$val" in
    *'{'*,*'}'*|*'{'*..*'}'*)
      if ! scope_brace_expand "$val"; then
        scope_block_rel "$val" "the brace pattern expands to too many words to check"
      fi
      if [ "${#SCOPE_BRACE_WORDS[@]}" -gt 1 ] || [ "${SCOPE_BRACE_WORDS[0]}" != "$val" ]; then
        local -a scope_brace_list=("${SCOPE_BRACE_WORDS[@]}")
        for w in "${scope_brace_list[@]}"; do
          case "$w" in
            *[*?[]*) scope_check_cwd_value "$w" "$is_opt" ;;
            /*) scope_check_cwd_abs "$w" ;;
            *) scope_check_cwd_abs "$cwd/$w" ;;
          esac
        done
        return 0
      fi
      ;;
  esac
  # An archive or copy of the HQ root or a folder above it, however it is
  # spelled (`.`, `..`, the absolute root, a symlink to it).
  case "$val" in
    *[*?[{]*) ;;
    *)
      if [ "$is_opt" -eq 0 ] && [ "${SCOPE_NAMES_ONLY:-0}" -eq 0 ]; then
        case "$val" in /*) abs="$val" ;; *) abs="$cwd/$val" ;; esac
        if [ -d "$abs" ]; then
          norm="$(scope_resolve_absolute_path "$abs" 2>/dev/null || true)"
          if scope_archiver_reaches_hq_root "$norm"; then
            scope_block_rel "companies" "the operand is the HQ root or a folder above it, so this archive or copy takes other companies' files; name the folders you need instead"
          fi
        fi
      fi
      ;;
  esac
  if [ "$cwd" = "$HQ_ROOT" ]; then
    case "$val" in
      /*)
        # An absolute spelling of the companies/ folder ("$PWD"/companies).
        if [ -e "$val" ] && ! scope_record_only_lists_names; then
          norm="$(scope_resolve_absolute_path "$val" 2>/dev/null || true)"
          if [ "$norm" = "$HQ_ROOT/companies" ] && scope_has_foreign_companies; then
            scope_block_rel "companies" "the operand is the companies/ folder, which holds other companies; name companies/<your-company>/... instead"
          fi
        fi
        return 0
        ;;
    esac
    # Programs that only list names or sizes, or print text, may name the
    # companies/ folder or a root glob (`ls *`, `du -sh *`, `ls companies`,
    # `for f in *; do echo "$f"; done`). Recursive readers and copiers may not.
    # They still may not name anything inside another company, so their
    # globs are expanded and each match is checked (SCOPE_NAMES_ONLY).
    if scope_record_only_lists_names; then
      case "$val" in
        *[*?[{]*) SCOPE_NAMES_ONLY=1 ;;
        *) return 0 ;;
      esac
    elif [ "${scope_head_untrusted:-1}" -eq 0 ]; then
      # ls -R / du -a of the HQ root lists every company's files.
      case "${SCOPE_REC_HEAD:-}:$val" in
        ls:.|ls:./|du:.|du:./) scope_block_rel "companies" "a recursive listing of the HQ root lists other companies' files" ;;
      esac
    fi
    if [ "${SCOPE_NAMES_ONLY:-0}" -eq 0 ]; then
    norm="$val"
    while [[ "$norm" == ./* ]]; do
      norm="${norm#./}"
      while [[ "$norm" == /* ]]; do norm="${norm#/}"; done
    done
    first="${norm%%/*}"
    [ -n "$first" ] || first="$norm"
    case "$first" in
      *[*?[]*)
        # A glob whose first folder is a wildcard can match companies/.
        scope_token_is_standalone_word "$val" || return 0
        ;;
      *)
        # Only the companies/ folder itself: companies, companies/,
        # ./companies//, a/../companies.
        norm="$val"
        case "$norm" in *[cC][oO][mM][pP][aA][nN][iI][eE]*|*..*) ;; *) return 0 ;; esac
        case "$norm" in *[*?[]*) return 0 ;; esac
        [ "$is_opt" -eq 0 ] || return 0
        abs="$cwd/$norm"
        [ -e "$abs" ] || return 0
        norm="$(scope_resolve_absolute_path "$abs" 2>/dev/null || true)"
        if [ "$norm" = "$HQ_ROOT/companies" ] && scope_has_foreign_companies; then
          scope_block_rel "companies" "the operand is the companies/ folder, which holds other companies; name companies/<your-company>/... instead"
        fi
        return 0
        ;;
    esac
    fi
  fi
  case "$val" in /*) abs="$val" ;; *) abs="$cwd/$val" ;; esac
  case "$val" in
    *[*?[]*)
      # A segment like `.*` can match `.` and `..` in some shells even when
      # this hook's bash skips them; check those spellings too.
      scope_check_dot_glob_spellings "$val" "$is_opt"
      # One expansion in a subshell from the cwd. Up to 64 matches are all
      # checked; past that, only when the glob's fixed leading folders stay
      # in the bound company, workspace/ or repos/, and then only the
      # symlinks among the matches.
      matches="$(cd "$cwd" 2>/dev/null && compgen -G "$val" 2>/dev/null | head -n 4097)" || true
      [ -n "$matches" ] || return 0
      while IFS= read -r m; do
        [ -n "$m" ] || continue
        count=$((count + 1))
        case "$m" in /*) ;; *) m="$cwd/$m" ;; esac
        if [ "$count" -gt 64 ]; then
          if [ "$safe" -lt 0 ]; then
            safe=0
            scope_glob_prefix_is_safe "$val" "$cwd" && safe=1
          fi
          [ "$safe" -eq 1 ] || scope_block_rel "$val" "the glob matches too many entries to check"
          [ "$count" -le 4096 ] || scope_block_rel "$val" "the glob matches too many entries to check"
          [ -L "${m%/}" ] || continue
        fi
        scope_check_cwd_abs "$m"
      done <<< "$matches"
      return 0
      ;;
  esac
  if [ "$is_opt" -eq 1 ]; then
    # An option value is checked when it or its parent folder exists.
    if [ -e "$abs" ] || [ -L "$abs" ] || [ -d "${abs%/*}" ]; then
      scope_check_cwd_abs "$abs"
    fi
    return 0
  fi
  case "$val" in
    */*) return 0 ;;
    .|..) scope_check_cwd_abs "$abs"; return 0 ;;
  esac
  if [ -L "$abs" ]; then
    scope_check_cwd_abs "$abs"
  elif [ -e "$abs" ] && scope_cwd_in_companies; then
    scope_check_cwd_abs "$abs"
  fi
  return 0
}

# A directory change the guard did not follow (cd -, cd "$(...)", an
# unresolved $VAR, ~-/~+, popd, CDPATH=) leaves the real cwd unknown. Any
# later relative operand then fails closed: a word with a slash, . or .., or
# a name that is a company folder.
scope_check_unfollowed_cd() {
  local cmd="${1:-}" rest re verb word unres=0 after="" w nl=$'\n'
  re='(^|['"$nl"';&|({[:space:]])(cd|pushd|popd)([[:space:]]+([^;&|<>()[:space:]]*))?([;&|()<>[:space:]]|$)'
  rest="$cmd"
  while [[ "$rest" =~ $re ]]; do
    verb="${BASH_REMATCH[2]}"
    word="${BASH_REMATCH[4]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
    case "$verb" in popd) unres=1 ;; esac
    case "$word" in -*|*'$'*|*$'\140'*|'~-'*|'~+'*) unres=1 ;; esac
    if [ "$unres" -eq 1 ]; then
      after="$rest"
      break
    fi
  done
  if [ "$unres" -eq 0 ]; then
    re='(^|[^A-Za-z0-9_])CDPATH='
    [[ "$cmd" =~ $re ]] || return 0
    after="${cmd#*CDPATH=}"
  fi
  local -a words=()
  read -r -a words <<< "${after//[\"\'<>;&|()]/ }"
  for w in ${words[@]+"${words[@]}"}; do
    case "$w" in
      # A word that starts with a variable is an absolute or computed path
      # the variable checks handle (`cd "$R" && ls "$R/x"`).
      -*|/*|'~'*|*://*|'$'*) continue ;;
      .|..|*/*)
        scope_block_rel "$w" "the command changes directory in a way the guard cannot follow, then uses a relative path"
        ;;
    esac
    case "$w" in *[!A-Za-z0-9._-]*) continue ;; esac
    if [ -d "$HQ_ROOT/companies/$w" ]; then
      scope_block_rel "$w" "the command changes directory in a way the guard cannot follow, then names a company folder"
    fi
  done
  return 0
}

# The company a path names before symlinks are followed. Prints nothing when
# the path does not start with companies/<tenant>/ (relative to HQ_ROOT or
# spelled under it). String operations only: this runs on every path check.
scope_lexical_company() {
  local lex="${1:-}" co
  lex="${lex//\\//}"
  case "$lex" in
    "$HQ_ROOT"/*) lex="${lex#"$HQ_ROOT"/}" ;;
    /*|'~'*) return 0 ;;
  esac
  while :; do
    case "$lex" in
      ./*) lex="${lex#./}" ;;
      *) break ;;
    esac
  done
  case "$lex" in
    companies/*/*) ;;
    *) return 0 ;;
  esac
  co="${lex#companies/}"
  co="${co%%/*}"
  case "$co" in
    ""|.|..|_template|_*) return 0 ;;
  esac
  [ -d "$HQ_ROOT/companies/$co" ] || return 0
  printf '%s' "$co"
}

# A path that goes through companies/<co>/ but resolves somewhere else (a repo
# link, or a link into another tenant) still needs <co> to be locked. Checking
# only the target let a session read through another company's links.
scope_check_lexical_company() {
  local raw="${1:-}" rel="${2:-}" co
  case "$raw" in
    *companies/*) ;;
    *) return 0 ;;
  esac
  co="$(scope_lexical_company "$raw")"
  [ -n "$co" ] || return 0
  case "$rel" in
    "companies/$co"|"companies/$co"/*) return 0 ;;
  esac
  scope_rel_allowed "companies/$co" \
    || scope_block_rel "companies/$co" "path goes through a link under companies/$co, which this session is not locked to"
}

# True when <candidate>, spelled under companies/<co>/, is a link the locked
# company <co> may follow: the target is a repo under HQ repos/, or a
# non-sensitive path outside HQ that is not $HOME, /, or an HQ ancestor, and
# that has no companies/ folder in it or above it. Every other target inside
# HQ (another tenant, core/, workspace/) is refused.
scope_company_link_target_ok() {
  local co="${1:-}" candidate="${2:-}" lex_co abs physical up
  [ -n "$co" ] && [ -n "$candidate" ] || return 1
  lex_co="$(scope_lexical_company "$candidate")"
  [ "$lex_co" = "$co" ] || return 1
  scope_rel_allowed "companies/$co" || return 1
  case "$candidate" in
    /*) abs="$candidate" ;;
    *) abs="$HQ_ROOT/$candidate" ;;
  esac
  physical="$(scope_resolve_absolute_path "$abs" 2>/dev/null || true)"
  physical="${physical%/}"
  [ -n "$physical" ] || return 1
  scope_link_path_is_sensitive "$physical" && return 1
  case "$physical" in
    "$HQ_ROOT"/repos/*) return 0 ;;
    "$HQ_ROOT"|"$HQ_ROOT"/*) return 1 ;;
  esac
  scope_repo_root_is_rejected "$physical" && return 1
  # A target in another HQ checkout, or in any tree with a companies/ folder,
  # would open that tree's tenants under the locked company's link.
  case "$physical/" in */companies/*) return 1 ;; esac
  up="$physical"
  while [ -n "$up" ]; do
    [ -d "$up/companies" ] && return 1
    up="${up%/*}"
  done
  return 0
}

# Resolve a tool-supplied relative root from its payload cwd. Relative paths in
# a hook payload are not necessarily relative to HQ_ROOT (for example, `lnk`
# while cwd is workspace/).
scope_resolve_payload_path() {
  local raw="${1:-}" cwd="${2:-$PAYLOAD_CWD}" cwd_abs physical
  [ -n "$raw" ] || { printf '%s' ""; return 0; }
  case "$raw" in
    /*) physical="$(scope_resolve_absolute_path "$raw" 2>/dev/null || true)" ;;
    *)
      case "$cwd" in /*) cwd_abs="$cwd" ;; *) cwd_abs="$HQ_ROOT/${cwd:-}" ;; esac
      [ -n "$cwd_abs" ] || cwd_abs="$HQ_ROOT"
      physical="$(scope_resolve_absolute_path "$cwd_abs/$raw" 2>/dev/null || true)"
      ;;
  esac
  case "$physical" in
    "$HQ_ROOT") printf '%s' "" ;;
    "$HQ_ROOT"/*) printf '%s' "${physical#"$HQ_ROOT"/}" ;;
    *) printf '%s' "__OUTSIDE_HQ__" ;;
  esac
}

# Search tools can traverse entries below their declared root. Check a root's
# own resolved target first, then inspect symlinks below it without following
# them. Prune expensive or out-of-scope trees and cap the entries inspected so
# the scan remains bounded independently of directory depth. A scan error or an
# exceeded entry ceiling is denied. A symlink that cannot be resolved is denied
# because its company scope cannot be established safely.
scope_scan_search_symlinks() {
  local dir="${1:-}" entry rel resolved scan_rc max_entries=4096 scanned=0
  [ -d "$dir" ] || return 0
  if find "$dir" \
    \( -type d \( -name .git -o -name node_modules \) -prune \) -o \
    \( -path "$HQ_ROOT/repos" -prune \) -o \
    -print0 |
    while IFS= read -r -d '' entry; do
      scanned=$((scanned + 1))
      [ "$scanned" -le "$max_entries" ] || \
        scope_block_rel "companies/(search root scan limit exceeded; narrow the root and retry)"
      if [ -L "$entry" ]; then
        rel="$(scope_normalize_hq_relative "$entry")"
        if [ -n "$rel" ]; then
          scope_check_rel "$rel"
        else
          resolved="$(scope_resolve_absolute_path "$entry" 2>/dev/null || true)"
          [ -n "$resolved" ] || scope_block_rel "companies/(unresolvable search symlink)"
        fi
      fi
    done; then
    return 0
  else
    scan_rc=$?
  fi
  [ "$scan_rc" -ne 2 ] || exit 2
  [ "$scan_rc" -eq 0 ] || scope_block_rel "companies/(search root could not be scanned safely)"
  return 0
}

scope_check_search_root() {
  local raw="${1:-}" rel candidate_abs
  [ -n "$raw" ] || return 0
  case "$raw" in /*) candidate_abs="$raw" ;; *) candidate_abs="${PAYLOAD_CWD:-$HQ_ROOT}/$raw" ;; esac
  if [ -L "$candidate_abs" ] && [ ! -e "$candidate_abs" ]; then
    scope_block_rel "companies/(unresolvable search root symlink)"
  fi
  rel="$(scope_resolve_payload_path "$raw")"
  [ "$rel" != "__OUTSIDE_HQ__" ] || return 0
  scope_check_rel "$rel"
}

scope_check_recursive_search_root() {
  local raw="${1:-}" rel root_abs
  [ -n "$raw" ] || return 0
  scope_check_search_root "$raw"
  rel="$(scope_resolve_payload_path "$raw")"
  [ "$rel" != "__OUTSIDE_HQ__" ] || return 0
  root_abs="$HQ_ROOT/$rel"
  [ -d "$root_abs" ] || return 0
  scope_scan_search_symlinks "$root_abs"
}

scope_strip_command_wrappers() {
  local i=0 token wrapper
  local -a wrapper_tokens
  wrapper_tokens=("${scope_tokens[@]}")
  while [ "$i" -lt "${#wrapper_tokens[@]}" ]; do
    token="${wrapper_tokens[$i]}"
    if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
      i=$((i + 1)); continue
    fi
    wrapper="${token##*/}"
    case "$wrapper" in
      env)
        i=$((i + 1))
        while [ "$i" -lt "${#wrapper_tokens[@]}" ]; do
          token="${wrapper_tokens[$i]}"
          case "$token" in
            -i|--ignore-environment|-0) i=$((i + 1)) ;;
            -u|--unset) i=$((i + 2)) ;;
            --unset=*) i=$((i + 1)) ;;
            -C|--chdir) i=$((i + 2)) ;;
            --) i=$((i + 1)); break ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      command)
        i=$((i + 1))
        while [ "$i" -lt "${#wrapper_tokens[@]}" ]; do
          case "${wrapper_tokens[$i]}" in -p|-v|-V) i=$((i + 1)) ;; *) break ;; esac
        done
        ;;
      builtin|nohup|time|xargs)
        i=$((i + 1))
        if [ "$wrapper" = time ]; then
          while [ "$i" -lt "${#wrapper_tokens[@]}" ]; do
            case "${wrapper_tokens[$i]}" in
              -p) i=$((i + 1)) ;;
              -f|-o) i=$((i + 2)) ;;
              --) i=$((i + 1)); break ;;
              -*) i=$((i + 1)) ;;
              *) break ;;
            esac
          done
        elif [ "$wrapper" = xargs ]; then
          while [ "$i" -lt "${#wrapper_tokens[@]}" ]; do
            token="${wrapper_tokens[$i]}"
            case "$token" in
              -0|-r|-t|-p|-x|--null|--no-run-if-empty|--verbose|--interactive) i=$((i + 1)) ;;
              -d|-E|-e|-I|-i|-L|-l|-n|-P|-s|--max-lines|--max-args|--max-procs|--max-chars|--replace|--eof) i=$((i + 2)) ;;
              --) i=$((i + 1)); break ;;
              -*) i=$((i + 1)) ;;
              *) break ;;
            esac
          done
        fi
        ;;
      exec)
        i=$((i + 1))
        while [ "$i" -lt "${#wrapper_tokens[@]}" ]; do
          case "${wrapper_tokens[$i]}" in
            -c|-l) i=$((i + 1)) ;;
            -a) i=$((i + 2)) ;;
            --) i=$((i + 1)); break ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      nice)
        i=$((i + 1))
        if [ "$i" -lt "${#wrapper_tokens[@]}" ]; then
          case "${wrapper_tokens[$i]}" in -n) i=$((i + 2)) ;; --adjustment=*) i=$((i + 1)) ;; esac
        fi
        ;;
      timeout)
        i=$((i + 1))
        while [ "$i" -lt "${#wrapper_tokens[@]}" ]; do
          token="${wrapper_tokens[$i]}"
          case "$token" in
            -s|-signal|-k|-kill-after) i=$((i + 2)) ;;
            --signal=*|--kill-after=*) i=$((i + 1)) ;;
            --) i=$((i + 1)); break ;;
            -*) i=$((i + 1)) ;;
            *) i=$((i + 1)); break ;;
          esac
        done
        ;;
      stdbuf)
        i=$((i + 1))
        while [ "$i" -lt "${#wrapper_tokens[@]}" ]; do
          token="${wrapper_tokens[$i]}"
          case "$token" in
            -i|-o|-e) i=$((i + 2)) ;;
            -i?*|-o?*|-e?*) i=$((i + 1)) ;;
            --) i=$((i + 1)); break ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      ionice)
        i=$((i + 1))
        while [ "$i" -lt "${#wrapper_tokens[@]}" ]; do
          token="${wrapper_tokens[$i]}"
          case "$token" in -c|-n|-t|-p) i=$((i + 2)) ;; --) i=$((i + 1)); break ;; -*) i=$((i + 1)) ;; *) break ;; esac
        done
        ;;
      chrt)
        i=$((i + 1))
        while [ "$i" -lt "${#wrapper_tokens[@]}" ]; do
          token="${wrapper_tokens[$i]}"
          case "$token" in
            -f|-o|-r|-b|-i|-d|-p|-m) i=$((i + 2)) ;;
            --) i=$((i + 1)); break ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      taskset)
        i=$((i + 1))
        while [ "$i" -lt "${#wrapper_tokens[@]}" ]; do
          token="${wrapper_tokens[$i]}"
          case "$token" in -c|-p|-a) i=$((i + 2)) ;; --) i=$((i + 1)); break ;; -*) i=$((i + 1)) ;; *) break ;; esac
        done
        ;;
      sudo|doas)
        i=$((i + 1))
        while [ "$i" -lt "${#wrapper_tokens[@]}" ]; do
          token="${wrapper_tokens[$i]}"
          case "$token" in
            -u|-g|-h|-p|-C|-T|-D|-R|-r|-t|-U|-a|-c|-L|-P|--user|--group|--host|--prompt|--close-from|--command-timeout|--chdir|--cwd|--role|--type|--auth-type) i=$((i + 2)) ;;
            --) i=$((i + 1)); break ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      *) break ;;
    esac
  done
  scope_tokens=("${wrapper_tokens[@]:$i}")
}

scope_command_follows_nested_links() {
  local command_name="${scope_tokens[0]##*/}" token cluster option i=1 j saw_find_root=0
  case "$command_name" in grep|egrep|fgrep|zgrep|ggrep) command_name=grep ;; esac
  while [ "$i" -lt "${#scope_tokens[@]}" ]; do
    token="${scope_tokens[$i]}"
    case "$command_name:$token" in
      grep:--dereference-recursive|rg:--follow|find:-follow) return 0 ;;
      find:-L|find:-H)
        [ "$saw_find_root" -eq 0 ] && return 0
        i=$((i + 1)); continue
        ;;
    esac
    case "$command_name" in
      grep|rg)
        case "$token" in
          --) break ;;
          --*) i=$((i + 1)); continue ;;
          -* )
            # A whitespace-bearing quoted token is one operand, not a short-option cluster.
            if [[ "$token" == *[[:space:]]* ]]; then i=$((i + 1)); continue; fi
            cluster="${token#-}"
            j=0
            while [ "$j" -lt "${#cluster}" ]; do
              option="${cluster:$j:1}"
              if { [ "$command_name" = grep ] && [ "$option" = R ]; } || \
                 { [ "$command_name" = rg ] && [ "$option" = L ]; }; then
                return 0
              fi
              j=$((j + 1))
            done
            i=$((i + 1)); continue ;;
          *) i=$((i + 1)); continue ;;
        esac
        ;;
      find)
        case "$token" in
          -follow) return 0 ;;
          -L|-H) [ "$saw_find_root" -eq 0 ] && return 0 ;;
          -* ) ;;
          *) saw_find_root=1 ;;
        esac
        i=$((i + 1)); continue
        ;;
      cp|tar|rsync)
        # Copies and archives that follow symlinks read what every link
        # inside the tree points at (feedback_ef130236): cp -L/-H/-RL,
        # tar -h/chf/--dereference, rsync -L/-k/--copy-links.
        case "$command_name:$token" in
          cp:--dereference|tar:--dereference|rsync:--copy-links|rsync:--copy-dirlinks|rsync:--copy-unsafe-links) return 0 ;;
          *:--*) ;;
          *:-*)
            cluster="${token#-}"
            case "$command_name:$cluster" in
              cp:*[LH]*|tar:*h*|rsync:*[Lk]*) return 0 ;;
            esac
            ;;
          tar:*)
            # tar's first word may be a dash-less option cluster (`chf`).
            if [ "$i" -eq 1 ]; then
              case "$token" in *[!A-Za-z]*) ;; *h*) return 0 ;; esac
            fi
            ;;
        esac
        i=$((i + 1)); continue
        ;;
      *) return 1 ;;
    esac
  done
  return 1
}

scope_glob_static_prefix() {
  local pattern="${1:-}" prefix="" ch i
  for ((i = 0; i < ${#pattern}; i++)); do
    ch="${pattern:i:1}"
    case "$ch" in
      '*'|'?'|'[') break ;;
      *) prefix+="$ch" ;;
    esac
  done
  printf '%s' "$prefix"
}

scope_open_tree_expansion_has_parent_value() {
  local candidate="$1" command_text="$2" token name assignment_re
  local tokens
  tokens="$(printf '%s' "$candidate" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' 2>/dev/null || true)"
  for token in $tokens; do
    name="$(printf '%s' "$token" | sed 's/^\$//;s/^{//;s/}$//')"
    assignment_re='(^|[;[:space:]])'
    assignment_re+="$name="
    assignment_re+='[^;|&]*'
    if [[ "$command_text" =~ $assignment_re ]]; then
      case "$BASH_REMATCH" in
        *'..'*) return 0 ;;
      esac
    fi
  done
  return 1
}

# `D=$(mktemp -d)` names a fresh directory under the temp dir, which is the
# same TMPDIR this hook inherits from the agent's shell. Print a representative
# absolute path inside that temp dir so the operand is authorized like any
# literal path there (a TMPDIR inside companies/ is still checked as such).
# The bare forms `mktemp`, `mktemp -d`, and `-t NAME` qualify, and so do a
# literal TEMPLATE (`mktemp -d /tmp/dl.XXXXXX`, `mktemp workspace/x.XXXX`) and
# `-p DIR` / `--tmpdir=DIR` with a literal DIR. The printed value is the
# template's own path (or DIR/TEMPLATE), which is where mktemp creates the
# entry, so `mktemp -d companies/<other>/x.XXXX` is checked as that company's
# path. A literal suffix after the substitution (`T=$(mktemp -d)/theme`) is
# appended. The variable must be assigned exactly once, every word must be
# literal with no `..`, and a command that mentions TMPDIR is refused.
scope_mktemp_assignment_value() {
  local name="${1:-}" command_text="${2:-}" mktemp_re count tmp_root
  local args suffix arg template="" dir="" have_t=0 expect="" value
  local -a words=()
  [ -n "$name" ] || return 1
  case "$command_text" in *TMPDIR*) return 1 ;; esac
  mktemp_re='(^|[;&|[:space:]])'
  mktemp_re+="$name="
  mktemp_re+='"?\$\(mktemp([^()]*)\)([A-Za-z0-9._/@+-]*)"?([;&|[:space:]]|$)'
  [[ "$command_text" =~ $mktemp_re ]] || return 1
  args="${BASH_REMATCH[2]}"
  suffix="${BASH_REMATCH[3]}"
  count="$(printf '%s' "$command_text" | grep -oE "(^|[^A-Za-z0-9_])${name}=" | wc -l | tr -d '[:space:]')"
  [ "$count" = "1" ] || return 1
  case "$args$suffix" in *'..'*) return 1 ;; esac
  case "$args" in *[!A-Za-z0-9._/@+=[:space:]-]*) return 1 ;; esac
  case "$suffix" in ""|/*) ;; *) return 1 ;; esac
  IFS=$' \t' read -r -a words <<< "$args"
  for arg in ${words[@]+"${words[@]}"}; do
    if [ -n "$expect" ]; then
      case "$arg" in -*|'~'*) return 1 ;; esac
      case "$expect" in
        t) have_t=1; case "$arg" in */*) return 1 ;; esac ;;
        p) dir="$arg" ;;
      esac
      expect=""
      continue
    fi
    case "$arg" in
      -d|-q|--directory|--quiet) ;;
      -t) expect=t ;;
      -p) expect=p ;;
      --tmpdir=?*) dir="${arg#--tmpdir=}" ;;
      -*) return 1 ;;
      *)
        [ -z "$template" ] || return 1
        case "$arg" in '~'*) return 1 ;; esac
        template="$arg"
        ;;
    esac
  done
  [ -z "$expect" ] || return 1
  if [ -n "$template" ]; then
    # -t with a TEMPLATE means different directories on GNU and BSD mktemp.
    [ "$have_t" -eq 0 ] || return 1
    case "$template" in
      */*) [ -z "$dir" ] || return 1; value="$template" ;;
      *) if [ -n "$dir" ]; then value="${dir%/}/$template"; else value="$template"; fi ;;
    esac
  elif [ -n "$dir" ]; then
    [ "$have_t" -eq 0 ] || return 1
    value="${dir%/}/hq-scope-mktemp"
  else
    tmp_root="${TMPDIR:-/tmp}"
    tmp_root="${tmp_root%/}"
    case "$tmp_root" in /*) ;; *) return 1 ;; esac
    case "$tmp_root" in *'..'*|*'$'*|*[[:space:]]*|*'*'*|*'?'*|*'['*) return 1 ;; esac
    value="$tmp_root/hq-scope-mktemp"
  fi
  printf '%s%s' "$value" "$suffix"
}

# The replacement for `${NAME<op>WORD}` (op is `:-` or `-`), or 1 when the
# hook cannot know it. HQ_ROOT, HOME, and PWD (not reassigned in the command)
# resolve only for `:-` and only when WORD is the same directory as the known
# value, so the result does not depend on whether the shell has it set. Any
# other NAME resolves to `${NAME}` when scope_assignment_literal_value proves a
# non-empty value; the caller then resolves `${NAME}` as usual.
scope_default_expansion_value() {
  local name="${1:-}" op="${2:-}" word="${3:-}" command_text="${4:-}" use_prefix="${5:-}"
  local known="" known_p word_p assignment re
  case "$word" in
    ''|-*|*'$'*|*'`'*|*'\'*|*'"'*|*"'"*|*'*'*|*'?'*|*'['*|*'~'*|*'{'*|*'('*|*'..'*|*[[:space:]]*) return 1 ;;
  esac
  case "$name" in
    HQ_ROOT|HOME|PWD)
      [ "$op" = ":-" ] || return 1
      re="(^|[^A-Za-z0-9_])(${name}\\+?=|unset|export|read[[:space:]]|declare|typeset|local[[:space:]]|eval|source|\\.[[:space:]]|cd[[:space:]]|pushd|popd)"
      [[ "$command_text" =~ $re ]] && return 1
      local default_dq
      default_dq="$(scope_dequote_text "$command_text")"
      [[ "$default_dq" =~ $re ]] && return 1
      scope_text_has_ansi_escape "$command_text" && return 1
      case "$name" in
        HQ_ROOT) known="${HQ_ROOT:-}" ;;
        HOME) known="${HOME:-}" ;;
        PWD) [ "${scope_cwd_is_static:-1}" -eq 1 ] && known="${COMMAND_CWD:-}" ;;
      esac
      case "$known" in /*) ;; *) return 1 ;; esac
      case "${COMMAND_CWD:-}" in /*) ;; *) return 1 ;; esac
      known_p="$(CDPATH='' cd "$known" 2>/dev/null && pwd -P)" || return 1
      word_p="$(cd "$COMMAND_CWD" 2>/dev/null && CDPATH='' cd "$word" 2>/dev/null && pwd -P)" || return 1
      [ -n "$known_p" ] && [ "$known_p" = "$word_p" ] || return 1
      printf '%s' "$known"
      return 0
      ;;
  esac
  assignment="$(scope_assignment_literal_value "$name" "$use_prefix" "$command_text")" || return 1
  [ -n "${assignment##*$'\037'}" ] || return 1
  printf '%s' "\${$name}"
}

# scope_setter_scan_awk prints 1 when the shell text it reads could run a
# variable-setting builtin, and 0 otherwise. It walks the text the way the
# shell splits it: single and double quotes, backslashes, `${...}`, `$(...)`,
# backticks, `(...)`, `#` comments, redirections and heredocs. A word counts
# only in command position: the start of the text, or after `;`, `&`, `|`,
# `(`, `)`, `{`, a newline, `$(`, `<(`, a backtick or a keyword such as
# `then` or `do`, after any `NAME=value` prefixes and redirections, and after
# the builtin, command, exec, jobs and time wrappers. A setter word inside a
# quoted argument, a comment or a file name is data. It prints 1 for:
#   - a command word that is read, mapfile, readarray, getopts, select,
#     declare, typeset, local, readonly, export, unset, let, coproc, eval,
#     source, `.`, trap, alias, enable, compgen, fc or bind, however it is
#     quoted (`"read"`, `re""ad`, `\read`);
#   - printf or wait with an option holding v or p, or an expanded,
#     brace-expanded or globbed option (`printf -?` can match a file `-v`);
#   - a command word built from an expansion (`$c`, `${c}d`, `$(...)`, a
#     backtick, a leading `~`), unless it holds a literal `/`, which makes it
#     a file, never a builtin;
#   - a command word, or a wrapper's operand, that bash brace-expands or
#     globs before it looks up the builtin: an unquoted `{` (`{read,}`,
#     `re{a..a}d`), `*`, `?`, a `[...]` bracket, or an extglob `@(`, `+(` or
#     `!(`. These count even with a `/` in the word, because `{read,/x}`
#     still yields `read`. The same characters in arguments are data, so
#     `ls *.md` and `grep -r x {a,b}` are not affected;
#   - case inside `$(...)` or backticks, where a pattern's `)` could end the
#     substitution early for this scanner;
#   - an unquoted heredoc body holding `$(` or a backtick and a setter word;
#   - an unbalanced quote, substitution or bracket, or an empty heredoc
#     delimiter.
# skiphd=1 skips heredoc bodies with a terminator line, so a setter word in
# the body is data. It is set only for the full command as the shell reads
# it, because a body stripped from the text could otherwise make a later
# command look like a body.
scope_setter_scan_awk='
  function resetw() { ws = 0; lit = ""; dyn = 0; sl = 0; un = ""; uq = 1; wst = 0; gx = 0; gb = 0; gbr = 0 }
  function begw() { if (!ws) { ws = 1; wst = i } }
  function addc(c) { begw(); lit = lit c; if (uq) un = un c; if (c == "/" && xd == 0) sl = 1 }
  function mark() { begw(); uq = 0 }
  function push(t) { sp++; md[sp] = t; if (t == "X") xd++ }
  function popq() { if (md[sp] == "X") xd--; sp-- }
  function pushcmd(t,   inword) {
    inword = (ws || md[sp] == "D" || md[sp] == "X")
    sws[sp] = ws || inword; slit[sp] = lit; sdyn[sp] = dyn || inword; ssl[sp] = sl
    sun[sp] = un; suq[sp] = uq && !inword; swst[sp] = (ws ? wst : i); srp[sp] = rp
    sgx[sp] = gx; sgb[sp] = gb; sgbr[sp] = gbr
    sp++; md[sp] = t; cs[sp] = "pre"; resetw(); rp = 0
  }
  function popcmd(   t) {
    t = md[sp]; sp--
    ws = sws[sp]; lit = slit[sp]; dyn = sdyn[sp]; sl = ssl[sp]; un = sun[sp]; uq = suq[sp]; wst = swst[sp]; rp = srp[sp]
    gx = sgx[sp]; gb = sgb[sp]; gbr = sgbr[sp]
    if (t == "C" || t == "B") { ws = 1; dyn = 1; uq = 0 }
  }
  function sep() { cs[sp] = "pre"; rp = 0 }
  function setter(w) {
    return w ~ /^(read|mapfile|readarray|getopts|select|declare|typeset|local|readonly|export|unset|let|coproc|eval|source|trap|alias|enable|compgen|fc|bind|\.)$/
  }
  function endw(   st, raw) {
    if (!ws) return
    if (rp) { rp = 0; resetw(); return }
    st = cs[sp]
    if (st == "fname") { cs[sp] = "pre"; resetw(); return }
    if (st == "pre" || st == "wrap") {
      if (st == "pre" && uq && un ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) { resetw(); return }
      if (st == "pre" && !uq && un ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) { resetw(); return }
      if (gx || (gbr && lit != "{")) hit = 1
      else if (st == "wrap" && !dyn && lit ~ /^-/) { resetw(); return }
      else if (dyn && !sl) hit = 1
      else if (dyn) cs[sp] = "args"
      else if (setter(lit)) hit = 1
      else if (lit == "case" && (md[sp] == "C" || md[sp] == "B")) hit = 1
      else if (lit == "printf" || lit == "wait") cs[sp] = "pw"
      else if (lit ~ /^(builtin|command|exec|jobs|time)$/) cs[sp] = "wrap"
      else if (lit == "function") cs[sp] = "fname"
      else if (lit ~ /^(!|if|then|else|elif|do|while|until|\{|\}|fi|done|esac)$/) cs[sp] = "pre"
      else cs[sp] = "args"
    } else if (st == "pw") {
      raw = substr(s, wst, i - wst)
      if (gx || gbr) hit = 1
      else if (dyn) { if (raw !~ /^"?\$(\{[!$?#]\}|[!$?#])"?$/) hit = 1; else cs[sp] = "args" }
      else if (lit ~ /^-/) { if (lit ~ /^-[A-Za-z]*[vp]/) hit = 1 }
      else cs[sp] = "args"
    }
    resetw()
  }
  function dollar(   d) {
    d = substr(s, i + 1, 1)
    if (d == "(") { pushcmd("C"); i += 2; return }
    if (d == "{") { mark(); dyn = 1; push("X"); i += 2; return }
    if (d == dq) { mark(); dyn = 1; push("D"); i += 2; return }
    if (d == sq) { hit = 1; i += 2; return }
    if (d ~ /[A-Za-z_]/) {
      mark(); dyn = 1; i++
      while (i <= n && substr(s, i, 1) ~ /[A-Za-z0-9_]/) i++
      return
    }
    if (d ~ /[0-9#?$!@*-]/) { mark(); dyn = 1; i += 2; return }
    addc("$"); i++
  }
  function redir(   st, ch, d, q, dash, op) {
    if (ws && !dyn && uq && (lit ~ /^[0-9]+$/ || lit ~ /^\{[A-Za-z_][A-Za-z0-9_]*\}$/)) resetw()
    else endw()
    if (substr(s, i, 3) == "<<<") { i += 3; rp = 1; return }
    if (substr(s, i, 2) == "<<") {
      i += 2; dash = 0
      if (substr(s, i, 1) == "-") { dash = 1; i++ }
      while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
      d = ""; q = 0
      while (i <= n) {
        ch = substr(s, i, 1)
        if (ch ~ /[ \t\n;&|<>()]/) break
        if (ch == sq || ch == dq || ch == bs) q = 1
        else d = d ch
        i++
      }
      if (d == "") { hit = 1; return }
      nh++; hd[nh] = d; hq[nh] = q; ht[nh] = dash
      return
    }
    st = i
    while (i <= n && substr(s, i, 1) ~ /[<>&]/) i++
    if (substr(s, i, 1) == "|" && substr(s, i - 1, 1) == ">") i++
    op = substr(s, st, i - st)
    if (op ~ /&$/ && substr(s, i, 1) ~ /[0-9-]/) {
      while (i <= n && substr(s, i, 1) ~ /[0-9-]/) i++
      rp = 0
      return
    }
    rp = 1
  }
  function heredocs(j,   k, p, e, line, term, body, bodystart) {
    if (nh == 0) return j
    if (!skiphd) { nh = 0; return j }
    p = j
    for (k = 1; k <= nh; k++) {
      bodystart = p
      while (1) {
        if (p > n) { nh = 0; return j }
        e = index(substr(s, p), "\n")
        if (e == 0) { line = substr(s, p); e = n + 1 } else { line = substr(s, p, e - 1); e = p + e - 1 }
        term = line
        if (ht[k]) while (substr(term, 1, 1) == "\t") term = substr(term, 2)
        if (term == hd[k]) break
        p = e + 1
      }
      body = substr(s, bodystart, p - bodystart)
      if (!hq[k] && (body ~ /\$\(/ || index(body, bt) > 0) && body ~ /(^|[^A-Za-z0-9_])(read|mapfile|readarray|getopts|select|declare|typeset|local|readonly|export|unset|let|coproc|eval|source|trap|alias|enable|compgen|fc|bind|printf|wait|\.)([^A-Za-z0-9_]|$)/) hit = 1
      p = e + 1
    }
    nh = 0
    return p
  }
  BEGIN { bt = "`"; bs = "\\" }
  { s = (NR > 1) ? s "\n" $0 : $0 }
  END {
    n = length(s); sp = 0; md[0] = "N"; cs[0] = "pre"; hit = 0; xd = 0; nh = 0; rp = 0
    resetw()
    i = 1
    while (i <= n && !hit) {
      c = substr(s, i, 1); m = md[sp]
      if (m == "S") { if (c == sq) popq(); else addc(c); i++; continue }
      if (m == "D" || m == "X") {
        if (c == bs) { addc(substr(s, i + 1, 1)); i += 2; continue }
        if (m == "D" && c == dq) { popq(); i++; continue }
        if (m == "X" && c == "}") { popq(); i++; continue }
        if (m == "X" && c == sq) { push("S"); i++; continue }
        if (m == "X" && c == dq) { push("D"); i++; continue }
        if (c == "$") { dollar(); continue }
        if (c == bt) { pushcmd("B"); i++; continue }
        addc(c); i++; continue
      }
      if (c == sq) { mark(); push("S"); i++; continue }
      if (c == dq) { mark(); push("D"); i++; continue }
      if (c == bs) { mark(); if (substr(s, i + 1, 1) != "\n") addc(substr(s, i + 1, 1)); i += 2; continue }
      if (c == "$") { dollar(); continue }
      if (c == bt) {
        if (m == "B") { endw(); popcmd(); i++; continue }
        pushcmd("B"); i++; continue
      }
      if (c == "#" && !ws) { while (i <= n && substr(s, i, 1) != "\n") i++; continue }
      if (c == " " || c == "\t" || c == "\r") { endw(); i++; continue }
      if (c == "\n") { endw(); sep(); i = heredocs(i + 1); continue }
      if (c == ";" || c == "|") { endw(); sep(); i++; continue }
      if (c == "&") {
        if (substr(s, i + 1, 1) == ">") { redir(); continue }
        endw(); sep(); i++; continue
      }
      if (c == "<" || c == ">") {
        if (substr(s, i + 1, 1) == "(") { endw(); pushcmd("C"); i += 2; continue }
        redir(); continue
      }
      if (c == "(") { endw(); pushcmd("P"); i++; continue }
      if (c == ")") {
        endw()
        if (m == "C" || m == "P") { popcmd(); if (m == "P") cs[sp] = "pre" }
        else cs[sp] = "pre"
        i++; continue
      }
      if (c == "*" || c == "?") gx = 1
      else if (c == "[") gb = 1
      else if (c == "]" && gb) gx = 1
      else if (c == "{") gbr = 1
      else if ((c == "+" || c == "@" || c == "!") && substr(s, i + 1, 1) == "(") gx = 1
      if (c == "~" && !ws) dyn = 1
      addc(c); i++
    }
    if (!hit) { endw(); if (sp > 0) hit = 1 }
    print (hit ? 1 : 0)
  }
'

# scope_command_may_set_var <name> <command>: true when <command> could give
# <name> a value the hook does not see, so $<name> must stay unknown and
# the path checks fail closed. It is true for:
#   - an assignment to <name> (`NAME=`, `NAME+=`, `NAME[i]=`, `${NAME:=x}`),
#     a `for NAME`, or an fd variable `{NAME}>`;
#   - a variable-setting builtin in command position, found by
#     scope_setter_scan_awk (see there for the full list). A quoted, split or
#     computed operand still fails closed, because the builtin counts
#     whatever its operand. A command word that bash expands (`$c`, `$(...)`,
#     `{read,}`, `rea?`) counts as a possible setter;
#   - arithmetic, which can assign through a variable's value: `((`, `$[`,
#     an array subscript (`a[n]=`, `${a[n]}`), a substring offset
#     (`${s:n}`), `[[` with a numeric test or -v, or -v next to a subscript;
#     an indirect `${!n:=x}`; and ANSI-C quoting (`$'...'`), which can spell
#     any name;
#   - <name> written as a bare word anywhere once quotes and backslashes are
#     removed (`"TMP"DIR`, `TMP\DIR`).
scope_command_may_set_var() {
  local name="${1:-}" text="${2:-}" plain b='(^|[^A-Za-z0-9_])' e='([^A-Za-z0-9_]|$)' re re2
  local scan_text="${2:-}" skiphd=0
  plain="${text//[\"\'\\]/}"
  case "$text" in *'(('*|*'$['*|*"\$'"*) return 0 ;; esac
  re="\\\$\\{[#!]?${name}:?="
  [[ "$plain" =~ $re ]] && return 0
  re='\$\{!?#?[A-Za-z_][A-Za-z0-9_]*(\[|:[^-=?+])'
  [[ "$plain" =~ $re ]] && return 0
  re='\$\{![^}]*='
  [[ "$plain" =~ $re ]] && return 0
  re='[A-Za-z_][A-Za-z0-9_]*\[[^]]*\]\+?='
  [[ "$plain" =~ $re ]] && return 0
  re="${b}-(eq|ne|lt|le|gt|ge|v)${e}"
  if [[ "$plain" =~ $re ]]; then
    case "$plain" in *'[['*) return 0 ;; esac
    re="${b}-v${e}"
    re2='[A-Za-z_][A-Za-z0-9_]*\['
    [[ "$plain" =~ $re ]] && [[ "$plain" =~ $re2 ]] && return 0
  fi
  # Drop every read of the variable, then look for the name anywhere else.
  plain="$(printf '%s' "$plain" | sed -E "s/\\\$\\{?[#!]?${name}//g")"
  re="${b}${name}${e}"
  [[ "$plain" =~ $re ]] && return 0
  # The full command is scanned as the shell reads it, before inert heredoc
  # bodies were stripped, so the scanner sees each body with its terminator.
  if [ -n "${scope_cmd:-}" ] && [ "$text" = "${scope_scan_cmd:-}" ]; then
    scan_text="$scope_cmd"
    skiphd=1
  fi
  [ "$(printf '%s' "$scan_text" | LC_ALL=C awk -v sq="'" -v dq='"' -v skiphd="$skiphd" "$scope_setter_scan_awk" 2>/dev/null)" = 0 ] || return 0
  return 1
}

scope_resolve_known_path_expansions() {
  local candidate="${1:-}" command_text="${2:-}" use_prefix="${3-__SCOPE_UNSET__}" token name value backtick
  local assignment_value assignment_before
  backtick=$'\140'
  # The use site decides which assignments ran before it. Without one, take
  # the text before the candidate's first occurrence in the command.
  if [ "$use_prefix" = "__SCOPE_UNSET__" ]; then
    use_prefix=""
    [[ "$command_text" == *"$candidate"* ]] && use_prefix="${command_text%%"$candidate"*}"
  fi
  # `${NAME:-WORD}` becomes `${NAME}` when NAME has a known non-empty value,
  # or the known value of HQ_ROOT, HOME, or PWD when WORD names the same
  # directory (so set or unset, the result is the same). Anything else stays
  # as written and fails closed below.
  local dflt_re dflt_match dflt_out="" dflt_rest="$candidate" dflt_value
  dflt_re='\$\{([A-Za-z_][A-Za-z0-9_]*)(:?-)([^}]*)\}'
  while [[ "$dflt_rest" =~ $dflt_re ]]; do
    dflt_match="${BASH_REMATCH[0]}"
    dflt_out+="${dflt_rest%%"$dflt_match"*}"
    dflt_rest="${dflt_rest#*"$dflt_match"}"
    if dflt_value="$(scope_default_expansion_value "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "$command_text" "$use_prefix")"; then
      dflt_out+="$dflt_value"
    else
      dflt_out+="$dflt_match"
    fi
  done
  candidate="$dflt_out$dflt_rest"
  local tokens
  tokens="$(printf '%s' "$candidate" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' 2>/dev/null || true)"
  for token in $tokens; do
    name="$(printf '%s' "$token" | sed 's/^\$//;s/^{//;s/}$//')"
    value=""
    if [ "$name" = "HQ_ROOT" ] && [ -n "$HQ_ROOT" ]; then
      value="$HQ_ROOT"
    elif [ "$name" = "HOME" ] && [[ "${HOME:-}" == /* ]] \
      && ! [[ "$command_text" =~ (^|[^A-Za-z0-9_])cd[[:space:]]+- ]] \
      && ! scope_command_may_set_var HOME "$command_text"; then
      # $HOME is the caller's real home unless the same command reassigns it.
      # Substituting it lets `ffmpeg -i $HOME/Desktop/x.mov` be checked like
      # the literal path it is; `$HOME/../../hq/companies/otherco` still
      # resolves under companies/ and is authorized there.
      value="$HOME"
    elif [ "$name" = "TMPDIR" ] && [[ "${TMPDIR:-}" == /* ]] \
      && ! scope_command_may_set_var TMPDIR "$command_text"; then
      # $TMPDIR is the caller's temp folder unless the same command sets it,
      # as for $HOME. The result is checked like the literal path, so a
      # TMPDIR under companies/ still needs that company locked.
      value="$TMPDIR"
    elif { [ "$name" = "USER" ] || [ "$name" = "LOGNAME" ]; } \
      && [[ "${!name:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
      && [[ "$candidate" != "$token"* ]] \
      && ! scope_command_may_set_var "$name" "$command_text"; then
      # $USER and $LOGNAME are the caller's login name unless the same
      # command reassigns them: one plain word, no slash, so the result is
      # checked like the literal when it follows literal text
      # (`postgres://$USER@localhost/db`, `/tmp/$USER`); feedback ae9e4270.
      # Alone at the start of a word (`tar -C "$USER"`) it stays unproven: a
      # bare name is a directory relative to wherever the command runs.
      value="${!name}"
    elif [ "$name" = "PWD" ] && [ "${scope_cwd_is_static:-1}" -eq 1 ] \
      && ! scope_command_may_set_var PWD "$command_text"; then
      # $PWD inside an assignment (`D="$PWD/personal/policies"`) is the
      # command's working directory, the same value a leading "$PWD/" gets.
      # After a cd the hook did not follow, it stays unresolved.
      value="$(cd "${COMMAND_CWD:-}" 2>/dev/null && pwd -P)" || value=""
    elif value="$(scope_mktemp_assignment_value "$name" "$command_text")"; then
      :
    else
      # Only an assignment the shell is guaranteed to have run, once, before
      # this use, gives the variable a known value. See
      # scope_assignment_literal_value for the exact conditions; anything else
      # (a reassignment, a conditional or nested assignment, an assignment
      # after the use, a value the hook cannot compute) leaves the variable
      # unresolved and the downstream checks fail closed on it.
      value=""
      if assignment_value="$(scope_assignment_literal_value "$name" "$use_prefix" "$command_text")"; then
        assignment_before="${assignment_value%%$'\037'*}"
        value="${assignment_value##*$'\037'}"
        value="${value//\$\{HQ_ROOT\}/$HQ_ROOT}"
        value="${value//\$HQ_ROOT/$HQ_ROOT}"
        # A value built from another assignment in the same command
        # (`W=/abs; C=$W/companies/x`) is resolved up to a fixed depth, each
        # inner variable against the text before this assignment. Anything
        # still carrying `$` afterwards is dropped below and fails closed.
        case "$value" in
          *'$'*)
            if [ "${SCOPE_EXPANSION_DEPTH:-0}" -lt 3 ] && [ "$value" != "$candidate" ]; then
              value="$(SCOPE_EXPANSION_DEPTH=$(( ${SCOPE_EXPANSION_DEPTH:-0} + 1 )) \
                scope_resolve_known_path_expansions "$value" "$command_text" "$assignment_before")"
            fi
            ;;
        esac
      fi
    fi
    if [ -n "$value" ]; then
      # A value that is itself unresolved, or that can traverse upward, is never
      # substituted. The candidate stays literal and the fail-closed checks
      # downstream still apply to it.
      case "$value" in
        *'..'*|*'$'*|*"$backtick"*) value="" ;;
      esac
    fi
    if [ -n "$value" ]; then
      case "$value" in
        # An absolute value fully determines where the path lands, whatever
        # literal text precedes the expansion, so substitute it and authorize
        # the result like any literal path: under companies/ it still needs a
        # binding, outside the HQ root it has no tenant to authorize against.
        # Refusing every absolute value instead (the earlier behaviour) blocked
        # ordinary work in /tmp and ~/.claude and told the agent to bind a
        # company for a path no company owns.
        #
        # It only determines ONE path if it yields one word. An unquoted
        # expansion of `D="/tmp companies/otherco"` word-splits into `/tmp` and
        # `companies/otherco/settings/x`, so treating the whole value as a
        # single absolute path would authorize a cross-company read by the
        # leading `/tmp`. A glob character likewise stands for paths this value
        # does not name. Either one stays unresolved and fails closed.
        *'*'*|*'?'*|*'['*|*']'*) value="" ;;
        # A quoted value with a space (`L="/x/My Drive/out"`) is one word when
        # every use of the variable is double-quoted (checked again here for
        # values such as $HOME that did not come from an assignment).
        *[[:space:]]*) scope_var_uses_double_quoted "$name" "$command_text" || value="" ;;
        # A relative value (`D=workspace/x`) is substituted too. The shell
        # pastes the value's text into the word, so the result is exactly the
        # literal path the agent could have typed, and it goes through the
        # same checks: companies/ needs the binding, a symlink is resolved, a
        # `..` was refused above. Leaving it unresolved (the earlier contract)
        # blocked `D=workspace/x; python3 s.py > $D/out.txt` as "not provably
        # confined" although no company path is involved.
        *) ;;
      esac
    fi
    if [ -n "$value" ]; then
      candidate="$(scope_substitute_variable "$candidate" "$name" "$value")"
    fi
  done
  scope_block_tool_location_parent "$candidate"
  printf '%s' "$candidate"
}

# `/__hq_scope_<tool>_location__<hex>` (scope_substitution_literal_value)
# stands for the real path the tool reported, hex-encoded. Print <path> with
# each marker replaced by that real path.
scope_strip_tool_location() {
  local path="${1:-}" marker real
  while [[ "$path" =~ /__hq_scope_(npm|brew)_location__([0-9a-f]*) ]]; do
    marker="${BASH_REMATCH[0]}"
    real="$(printf '%s' "${BASH_REMATCH[2]}" | sed 's/../\\x&/g')"
    real="$(printf '%b' "$real")"
    case "$real" in /*) ;; *) return 1 ;; esac
    path="${path/"$marker"/$real}"
  done
  printf '%s' "$path"
}

# Run `npm ...` or `brew ...` from <dir> for at most 3 seconds and print what
# it wrote. A slow tool would otherwise use up the hook's 30-second budget,
# and a hook that times out lets the tool call run. A timeout, a non-zero exit
# or a missing perl returns 1, so the location stays unknown and is blocked.
# The output goes to a file, and the tool's whole process group is killed, so
# a child still holding the output open cannot hold the hook.
# After one timeout, later calls in the same hook run fail at once, so a
# command that names the tool several times still finishes well inside the
# budget. The marker is a directory: mkdir never follows or truncates an
# existing path, and a stray one only blocks these forms.
# A tool that is slow but always under 3 seconds is caught by a shared limit:
# no call runs past 12 seconds into the hook run ($SECONDS carries into the
# subshells this is called from), so many calls cannot add up to 30 seconds.
scope_tool_location_bounded() {
  local dir="${1:-}" out rc=0 slow="${TMPDIR:-/tmp}/hq-scope-tool-slow.$$"
  local limit=$((12 - SECONDS))
  shift || return 1
  [ -e "$slow" ] && return 1
  [ "$limit" -gt 0 ] || return 1
  [ "$limit" -gt 3 ] && limit=3
  command -v perl >/dev/null 2>&1 || return 1
  out="$(mktemp "${TMPDIR:-/tmp}/hq-scope-tool.XXXXXX" 2>/dev/null)" || return 1
  (cd "$dir" 2>/dev/null && perl -e '
    my $s = shift;
    my $pid = fork;
    defined $pid or exit 125;
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "KILL", -$pid, $pid; exit 124 };
    alarm $s;
    waitpid($pid, 0);
    alarm 0;
    exit(($? & 127) ? 128 : ($? >> 8));
  ' "$limit" "$@" </dev/null >"$out" 2>/dev/null) || rc=$?
  [ "$rc" -eq 124 ] && { mkdir "$slow" 2>/dev/null || true; }
  [ "$rc" -eq 0 ] && cat "$out"
  rm -f "$out"
  return "$rc"
}

# A tool location (scope_substitution_literal_value) is checked against the
# real folder, but a `..` after it is still refused: npm and brew locations
# are only ever read downward.
scope_block_tool_location_parent() {
  case "${1:-}" in
    */__hq_scope_*_location__*/../*|*/__hq_scope_*_location__*/..)
      scope_block_rel "${1:-}" "a parent segment after a tool location (\$(npm root -g)/..) cannot be checked"
      ;;
  esac
  return 0
}

# Replace `${name}` and `$name` in <text> with <value>. `$name` is replaced
# only where the next character cannot extend the name, so resolving `$D`
# leaves `$DIR` alone.
scope_substitute_variable() {
  local text="${1:-}" name="${2:-}" value="${3:-}" out="" rest next
  text="${text//\$\{$name\}/$value}"
  rest="$text"
  while [[ "$rest" == *"\$$name"* ]]; do
    out+="${rest%%"\$$name"*}"
    rest="${rest#*"\$$name"}"
    next="${rest:0:1}"
    case "$next" in
      [A-Za-z0-9_]) out+="\$$name" ;;
      *) out+="$value" ;;
    esac
  done
  printf '%s' "$out$rest"
}

# The output of `date [-u] +FORMAT` when FORMAT uses only numeric conversions
# and the literal characters [A-Za-z0-9_:-]. Such output can never contain a
# slash, whitespace, a glob character, or a `..`, so a variable holding it is
# one plain filename fragment. Prints a representative value (each conversion
# rendered as 0) or returns 1 for any other substitution.
# Expand the single `$(BODY)` in <word> (with literal text on either side)
# when scope_substitution_literal_value knows its output. Any second
# substitution, nested parenthesis, or other expansion fails.
scope_expand_one_substitution() {
  local word="${1:-}" command_text="${2:-}" sub_pre sub_rest sub_body sub_post sub_value
  case "$word" in *'$('*) ;; *) return 1 ;; esac
  sub_pre="${word%%\$\(*}"
  sub_rest="${word#*\$\(}"
  case "$sub_rest" in *')'*) ;; *) return 1 ;; esac
  sub_body="${sub_rest%%\)*}"
  sub_post="${sub_rest#*\)}"
  case "$sub_pre$sub_post$sub_body" in *'$'*|*'('*|*')'*|*'`'*|*'\'*) return 1 ;; esac
  case "$sub_pre$sub_post" in *[[:space:]]*) return 1 ;; esac
  sub_value="$(scope_substitution_literal_value "$sub_body" "$command_text")" || return 1
  [ -n "$sub_value" ] || return 1
  printf '%s' "$sub_pre$sub_value$sub_post"
}

# `ls -d GLOB`, optionally cut with `| head -N` / `| tail -N`: prints the glob
# operand when BODY is exactly that shape. The operand must be one literal
# word with a glob character, no `..`, no expansion, and must start under an
# open HQ tree (workspace/, core/, personal/, repos/, .claude/) or be
# absolute, so the caller's glob check can enumerate it. `-d` is required:
# without it ls prints the entries of a matched directory, which the glob
# does not name. Only -d and the listing flags that keep the operand
# spelling (-1, -t, -r, -S, -A) are accepted.
# True when <command> runs a program that can create a directory or a link
# (mkdir, an archiver, a VCS, an interpreter or shell, a fetcher, a package
# tool, ...) or sources a file. Shapes that rely on the file tree staying as
# it is now while the command runs are refused when this holds.
scope_command_may_create_entries() {
  local text="${1:-}" re sub_re='\$\(([^()]*)\)' safe_text=""
  # A substitution whose body prints a non-path and runs nothing else
  # (scope_subst_body_is_safe: `$(bash core/scripts/hq-session.sh current)`,
  # `$(date +%F)`) creates nothing; drop it before the program scan.
  while [[ "$text" =~ $sub_re ]]; do
    scope_subst_body_is_safe "${BASH_REMATCH[1]}" || break
    safe_text="${BASH_REMATCH[0]}"
    text="${text/"$safe_text"/x}"
  done
  re='(^|[^A-Za-z0-9_.-])(mkdir|ln|mv|cp|rsync|tar|bsdtar|gtar|unzip|zip|7z|ditto|install|git|gh|hq|python[0-9.]*|node|nodejs|deno|bun|ruby|perl|php|lua|Rscript|awk|gawk|mawk|nawk|bash|sh|zsh|dash|ksh|fish|eval|source|exec|xargs|env|sudo|curl|wget|make|npm|npx|pnpm|yarn|pip[0-9.]*|uv|cargo|go|brew|osascript|open|find|patch|unshare|chroot)([^A-Za-z0-9_.-]|$)|(^|[;&|({[:space:]])\.[[:space:]]'
  [[ "$text" =~ $re ]]
}

scope_ls_d_glob_operand() {
  local body="${1:-}" re operand
  body="${body#"${body%%[![:space:]]*}"}"
  body="${body%"${body##*[![:space:]]}"}"
  local flags nod_cwd nod_match nod_count=0
  re='^ls((\ -[1dtrSA]+)*)\ ([A-Za-z0-9_./@+*?-]+)(\ ?\|\ ?(head|tail)(\ -n)?\ -?[0-9]+)?$'
  [[ "$body" =~ $re ]] || return 1
  flags="${BASH_REMATCH[1]}"
  operand="${BASH_REMATCH[3]}"
  case "$operand" in
    -*|*'..'*) return 1 ;;
    *[*?]*) ;;
    *) return 1 ;;
  esac
  case "$operand" in
    workspace/*|core/*|personal/*|repos/*|.claude/*|/*) ;;
    *) return 1 ;;
  esac
  case "$flags" in
    *d*) ;;
    *)
      # Without -d, ls prints a matched file as the glob spells it but lists
      # the entries of a matched directory. `ls -t workspace/logs/*.log |
      # head -1` is accepted only when every match is a non-directory now
      # and the command runs nothing that could create one first, so the
      # output is one of the matches (feedback 046fcf07, f4e499d2).
      scope_command_may_create_entries "${SCOPE_FULL_CMD:-}" && return 1
      [ -n "${SCOPE_FULL_CMD:-}" ] || return 1
      nod_cwd="$(cd "${COMMAND_CWD:-$HQ_ROOT}" 2>/dev/null && pwd -P)" || return 1
      while IFS= read -r nod_match; do
        [ -n "$nod_match" ] || continue
        nod_count=$((nod_count + 1))
        [ "$nod_count" -le 2048 ] || return 1
        case "$nod_match" in /*) ;; *) nod_match="$nod_cwd/$nod_match" ;; esac
        [ -d "$nod_match" ] && return 1
      done < <(cd "$nod_cwd" && compgen -G "$operand" || true)
      ;;
  esac
  printf '%s' "$operand"
}

# Validate the complete ls-d output set before returning any words. A bare
# loop variable may never reach a path scan; syntax alone cannot clear taint.
scope_ls_d_checked_paths() {
  local body="${1:-}" glob cwd match physical count=0
  local -a matches=()
  glob="$(scope_ls_d_glob_operand "$body")" || return 1
  cwd="$(cd "${COMMAND_CWD:-$HQ_ROOT}" 2>/dev/null && pwd -P)" || return 1
  case "$glob" in /*) ;; *) [ "$cwd" = "$HQ_ROOT" ] || return 1 ;; esac
  case "$glob" in "$HQ_ROOT/companies"|"$HQ_ROOT/companies/"*) return 1 ;; esac
  while IFS= read -r match; do
    [ -n "$match" ] || continue
    case "$match" in *[!A-Za-z0-9._/@+-]*|*'..'*) return 1 ;; esac
    count=$((count + 1))
    [ "$count" -le 2048 ] || return 1
    matches[${#matches[@]}]="$match"
  done < <(cd "$cwd" && compgen -G "$glob" || true)
  # No match: ls prints nothing on stdout, so there is no path to check.
  [ "$count" -gt 0 ] || return 0
  for match in "${matches[@]}"; do
    case "$match" in
      /*) physical="$(scope_resolve_absolute_path "$match")" || return 1 ;;
      *) physical="$(scope_resolve_absolute_path "$cwd/$match")" || return 1 ;;
    esac
    [ -n "$physical" ] || return 1
    scope_check_raw "$match"
  done
  printf '%s\n' "${matches[@]}"
}

# `find DIR [-maxdepth N] [-mindepth N] [-type f|d|l] [-name PAT] [-iname PAT]
# [-path PAT] [-ipath PAT] [-not|!] [-a|-o|-and|-or] [-empty] [-print]`:
# prints "DIR\037<the validated arguments, one per line>" when BODY is
# exactly that shape, else returns 1. find prints paths under DIR (it does
# not follow symlinks without -L, which is not accepted), so every value is
# a path the caller can check like a typed one. Actions (-exec, -delete,
# -ok, -fprint, ...) and any other predicate are refused.
scope_find_body_is_bounded() {
  local body="${1:-}" dir word state=dir out="" pat_re='^[A-Za-z0-9_./@+*?-]+$'
  local -a parts=()
  body="${body#"${body%%[![:space:]]*}"}"
  body="${body%"${body##*[![:space:]]}"}"
  case "$body" in find\ *) ;; *) return 1 ;; esac
  case "$body" in *'$'*|*$'\140'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*|*'('*|*')'*|*'\'*) return 1 ;; esac
  # Quotes only group a pattern word; strip them so the word is checked bare.
  body="${body//[\"\']/}"
  read -r -a parts <<< "$body"
  [ "${#parts[@]}" -ge 2 ] || return 1
  dir="${parts[1]}"
  case "$dir" in
    -*|*'..'*|*[!A-Za-z0-9_./@+-]*) return 1 ;;
  esac
  # DIR is an open HQ tree spelled from the root, or an absolute directory
  # under /tmp, $TMPDIR or inside (not at) $HOME and outside the HQ root.
  # `.`, `companies/...`, `/` and any other spelling are refused here, so a
  # loop list over the tenant tree never clears the substitution taint
  # (review C1).
  local hq_phys home_phys
  case "$dir" in
    workspace/*|core/*|personal/*|repos/*|.claude/*) ;;
    /*)
      hq_phys="$(cd "$HQ_ROOT" 2>/dev/null && pwd -P)" || return 1
      case "$dir" in "$hq_phys"|"$hq_phys"/*|"$HQ_ROOT"|"$HQ_ROOT"/*) return 1 ;; esac
      home_phys="${HOME:-}"
      local dir_ok=0
      case "$dir" in /tmp/?*|/private/tmp/?*) dir_ok=1 ;; esac
      [ -n "${TMPDIR:-}" ] && [[ "$dir" == "${TMPDIR%/}"/?* ]] && dir_ok=1
      [ -n "$home_phys" ] && [[ "$dir" == "${home_phys%/}"/?* ]] && dir_ok=1
      [ "$dir_ok" -eq 1 ] || return 1
      ;;
    *) return 1 ;;
  esac
  local i=2
  while [ "$i" -lt "${#parts[@]}" ]; do
    word="${parts[$i]}"
    case "$word" in
      -maxdepth|-mindepth)
        [[ "${parts[$((i + 1))]:-}" =~ ^[0-9]{1,3}$ ]] || return 1
        out+="$word"$'\n'"${parts[$((i + 1))]}"$'\n'
        i=$((i + 2))
        ;;
      -type)
        [[ "${parts[$((i + 1))]:-}" =~ ^[fdl]$ ]] || return 1
        out+="$word"$'\n'"${parts[$((i + 1))]}"$'\n'
        i=$((i + 2))
        ;;
      -name|-iname|-path|-ipath)
        [[ "${parts[$((i + 1))]:-}" =~ $pat_re ]] || return 1
        case "${parts[$((i + 1))]}" in *'..'*) return 1 ;; esac
        out+="$word"$'\n'"${parts[$((i + 1))]}"$'\n'
        i=$((i + 2))
        ;;
      -not|'!'|-a|-o|-and|-or|-empty|-print)
        out+="$word"$'\n'
        i=$((i + 1))
        ;;
      *) return 1 ;;
    esac
  done
  printf '%s\037%s' "$dir" "$out"
}

# Print the paths a bounded `find` body (scope_find_body_is_bounded) names,
# one per line, or return 1. DIR must exist, be readable by the session and
# sit outside companies/; the validated predicates are grouped and re-run
# here from the command's cwd, capped at 2048 paths, and every path must be
# a plain word. With <check> set to 1 each path is also checked as a literal
# operand (symlinks resolved), so a loop list may clear the substitution
# taint only when every value it can take is allowed.
# scope_find_bounded_run DIR [PRED...]: run the validated find from the
# command's directory, at most 2049 lines. The predicates are grouped so the
# final -print applies to the whole expression, as find's implicit -print does
# for the command itself (`-name a -o -name b` prints both sets). A separate
# function because bash 3.2 cannot parse a multi-line group inside <( ).
scope_find_bounded_run() {
  local run_dir="$1"
  shift
  cd "${COMMAND_CWD:-$HQ_ROOT}" 2>/dev/null || return 0
  if [ "$#" -gt 0 ]; then
    find "$run_dir" '(' "$@" ')' -print 2>/dev/null | head -n 2049
  else
    find "$run_dir" -print 2>/dev/null | head -n 2049
  fi
  return 0
}

# `grep -l PATTERN FILE...` prints the names of the given files that match,
# spelled as the operands spell them, so a `for f in $(grep -l x
# workspace/*.md)` loop binds f to a subset of the operands. Each operand is
# a literal word or glob (no `..`, no expansion, no option word), expanded
# here from the HQ root; every match must be a non-directory, the set is
# capped, and the paths are printed for the caller to check as literals.
# Options other than -l and those that only change matching (-i -E -F -w
# -x -s) are refused: -r/-R/-d recurse, -f/-e read or add patterns, -H/-c
# and friends change the output. The command must create no entry or link
# anywhere (scope_command_may_create_entries), so the set cannot change
# before the loop list is read (feedback cbc05663). With <check> set to 1
# each path is also checked as a literal operand.
scope_grep_l_paths() {
  local body="${1:-}" check="${2:-0}" re flags operands op match count=0 cwd
  local sq="'"
  body="${body#"${body%%[![:space:]]*}"}"
  body="${body%"${body##*[![:space:]]}"}"
  re='^grep((\ -[A-Za-z]+)+)\ ('"$sq"'[^'"$sq"']*'"$sq"'|"[^"$`\\]*"|[A-Za-z0-9_.@+:=,-]+)((\ [A-Za-z0-9_./@+*?-]+)+)$'
  [[ "$body" =~ $re ]] || return 1
  flags="${BASH_REMATCH[1]}"
  operands="${BASH_REMATCH[4]}"
  flags="${flags// /}"
  flags="${flags//-/}"
  case "$flags" in *l*) ;; *) return 1 ;; esac
  case "$flags" in *[!liEFwxs]*) return 1 ;; esac
  [ -n "${SCOPE_FULL_CMD:-}" ] || return 1
  scope_command_may_create_entries "$SCOPE_FULL_CMD" && return 1
  cwd="$(cd "${COMMAND_CWD:-$HQ_ROOT}" 2>/dev/null && pwd -P)" || return 1
  [ "$cwd" = "$HQ_ROOT" ] || return 1
  local -a ops=()
  read -r -a ops <<< "$operands"
  for op in "${ops[@]}"; do
    case "$op" in -*|*'..'*) return 1 ;; esac
    case "$op" in
      companies|companies/*|/*) return 1 ;;
    esac
    if [[ "$op" == *[*?]* ]]; then
      while IFS= read -r match; do
        [ -n "$match" ] || continue
        case "$match" in *[!A-Za-z0-9._/@+-]*|*'..'*) return 1 ;; esac
        [ -d "$HQ_ROOT/$match" ] && continue
        count=$((count + 1))
        [ "$count" -le 2048 ] || return 1
        [ "$check" -eq 1 ] && scope_check_raw "$HQ_ROOT/$match"
        printf '%s\n' "$match"
      done < <(cd "$HQ_ROOT" && compgen -G "$op" || true)
    else
      [ -d "$HQ_ROOT/$op" ] && continue
      count=$((count + 1))
      [ "$count" -le 2048 ] || return 1
      [ "$check" -eq 1 ] && scope_check_raw "$HQ_ROOT/$op"
      printf '%s\n' "$op"
    fi
  done
  # Nothing matched: grep prints nothing and the loop body never runs. The
  # first operand, with its glob characters made literal, stands in.
  if [ "$count" -eq 0 ]; then
    op="${operands# }"
    op="${op%% *}"
    scope_glob_nomatch_value "$op" "$HQ_ROOT" || return 1
  fi
  return 0
}

scope_find_bounded_paths() {
  local body="${1:-}" check="${2:-0}" find_spec find_dir find_abs find_rel find_path find_count=0
  local -a find_args=()
  find_spec="$(scope_find_body_is_bounded "$body")" || return 1
  find_dir="${find_spec%%$'\037'*}"
  case "$find_dir" in
    /*) find_abs="$find_dir" ;;
    *)
      [ "$(cd "${COMMAND_CWD:-$HQ_ROOT}" 2>/dev/null && pwd -P)" = "$HQ_ROOT" ] || return 1
      find_abs="$HQ_ROOT/$find_dir"
      ;;
  esac
  [ -d "$find_abs" ] || return 1
  find_rel="$(scope_normalize_hq_relative "$find_abs")"
  if [ -n "$find_rel" ]; then
    scope_rel_allowed "$find_rel" || return 1
    case "$find_rel" in companies|companies/*) return 1 ;; esac
  else
    case "$find_abs" in "$HQ_ROOT"|"$HQ_ROOT"/*) return 1 ;; esac
  fi
  while IFS= read -r find_path; do
    [ -n "$find_path" ] || continue
    find_args[${#find_args[@]}]="$find_path"
  done <<< "${find_spec#*$'\037'}"
  while IFS= read -r find_path; do
    [ -n "$find_path" ] || continue
    case "$find_path" in *[!A-Za-z0-9._/@+-]*|*'..'*) return 1 ;; esac
    find_count=$((find_count + 1))
    [ "$find_count" -le 2048 ] || return 1
    if [ "$check" -eq 1 ]; then
      case "$find_path" in
        /*) scope_check_raw "$find_path" ;;
        *) scope_check_raw "${COMMAND_CWD:-$HQ_ROOT}/$find_path" ;;
      esac
    fi
    printf '%s\n' "$find_path"
  done < <(scope_find_bounded_run "$find_dir" "${find_args[@]+"${find_args[@]}"}")
  [ "$find_count" -gt 0 ] || return 1
  return 0
}

# The output of one `$(BODY)` that the hook can know without running it:
#   date +FORMAT              digits in the format's shape (no slash)
#   echo WORD, printf %s WORD WORD itself (a literal path is then checked
#                             like any typed path, so `$(echo companies/x)`
#                             still needs x locked)
#   dirname WORD              WORD up to its last slash
#   pwd                       the command's cwd, when the command has no cd
#   git rev-parse --show-toplevel
#                             the work tree holding the command's cwd, asked
#                             of git at hook time, when the substitution is
#                             the command's first statement
#   npm root -g, npm prefix -g, npm config get prefix|cache, brew --prefix [f]
#                             an install location outside HQ, when the
#                             substitution is the command's first statement,
#                             the tool resolves outside HQ, nothing in the
#                             command names its config, and the tool itself
#                             (run here, in the command's cwd) reports an
#                             absolute location outside HQ
# Anything else is unknown, and the caller fails closed.
scope_substitution_literal_value() {
  local body="${1:-}" command_text="${2:-}" re word tool="" bin name
  body="${body#"${body%%[![:space:]]*}"}"
  body="${body%"${body##*[![:space:]]}"}"
  [ -n "$body" ] || return 1
  case "$body" in
    date|date[[:space:]]*)
      scope_date_substitution_value "\$($body)"
      return
      ;;
    pwd|'pwd -P'|'pwd -L')
      re='(^|[^A-Za-z0-9_.-])(cd|pushd|popd)([[:space:]]|;|$)'
      [[ "$command_text" =~ $re ]] && return 1
      case "${COMMAND_CWD:-}" in
        /*) printf '%s' "$COMMAND_CWD"; return 0 ;;
      esac
      return 1
      ;;
    'git rev-parse --show-toplevel')
      scope_git_toplevel_value "$body" "$command_text"
      return
      ;;
  esac
  re='^(echo|printf[[:space:]]+(%s|'"'"'%s'"'"'|"%s"))[[:space:]]+([A-Za-z0-9_./@+:][A-Za-z0-9_./@+:-]*)$'
  if [[ "$body" =~ $re ]]; then
    printf '%s' "${BASH_REMATCH[3]}"
    return 0
  fi
  re='^dirname[[:space:]]+([A-Za-z0-9_./@+:][A-Za-z0-9_./@+:-]*)$'
  if [[ "$body" =~ $re ]]; then
    word="${BASH_REMATCH[1]}"
    while [ "${#word}" -gt 1 ] && [ "${word%/}" != "$word" ]; do word="${word%/}"; done
    case "$word" in
      /) ;;
      /*/*|*/*) word="${word%/*}" ;;
      /*) word="/" ;;
      *) word="." ;;
    esac
    while [ "${#word}" -gt 1 ] && [ "${word%/}" != "$word" ]; do word="${word%/}"; done
    printf '%s' "$word"
    return 0
  fi
  case "$body" in
    'npm root -g'|'npm root --global'|'npm prefix -g'|'npm prefix --global'|'npm config get prefix'|'npm config get cache') tool=npm ;;
    'brew --prefix'|'brew --cellar'|'brew --repository') tool=brew ;;
    *)
      re='^brew[[:space:]]+--prefix[[:space:]]+[A-Za-z0-9@._+-]+$'
      [[ "$body" =~ $re ]] && tool=brew
      ;;
  esac
  [ -n "$tool" ] || return 1
  # Nothing may run before the substitution: `NAME=$(tool ...)` or
  # `NAME="$(tool ...)"` opens the command. An earlier statement could
  # write a config file or export a setting the tool reads.
  word="${command_text%%"\$($body)"*}"
  [ "$word" != "$command_text" ] || return 1
  re='^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="?$'
  [[ "$word" =~ $re ]] || return 1
  # The command may not redefine or reconfigure the tool. npm reads its
  # environment settings in any letter case, and quotes or backslashes can
  # split a name, so compare a lower-case copy with those removed.
  word="$(printf '%s' "$command_text" | tr -d "\"'\\\\" | tr '[:upper:]' '[:lower:]')"
  re='(npm_config|npmrc|userconfig|globalconfig|homebrew_|brew\.env|path=|alias|function|'"$tool"'[[:space:]]*\(\))'
  [[ "$word" =~ $re ]] && return 1
  bin="$(command -v "$tool" 2>/dev/null || true)"
  case "$bin" in
    "$HQ_ROOT"|"$HQ_ROOT"/*) return 1 ;;
    /*) ;;
    *) return 1 ;;
  esac
  if [ "$tool" = npm ]; then
    case "${npm_config_prefix:-}${NPM_CONFIG_PREFIX:-}" in
      "") ;;
      *"$HQ_ROOT"*|[!/]*) return 1 ;;
    esac
    [ -e "${COMMAND_CWD:-$HQ_ROOT}/.npmrc" ] && return 1
    [ -e "$HQ_ROOT/.npmrc" ] && return 1
  fi
  # A user or global config written by an earlier command can still move the
  # location, so ask the tool. Only this command shape pays for the call.
  case "${COMMAND_CWD:-}" in /*) ;; *) return 1 ;; esac
  # shellcheck disable=SC2086 # $body is one of the fixed forms above.
  word="$(scope_tool_location_bounded "$COMMAND_CWD" $body)" || return 1
  case "$word" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$word" in *$'\n'*|*'..'*) return 1 ;; esac
  if [ -d "$word" ]; then
    word="$(cd "$word" 2>/dev/null && pwd -P)" || return 1
  fi
  bin="$(cd "$HQ_ROOT" 2>/dev/null && pwd -P)" || return 1
  case "$word" in
    "$HQ_ROOT"|"$HQ_ROOT"/*|"$bin"|"$bin"/*) return 1 ;;
  esac
  case "$word" in
    *[$'\t\r']*|*'*'*|*'?'*|*'['*|*']'*|*'$'*|*'`'*|*\\*|*__hq_scope_*) return 1 ;;
  esac
  # A location with a space (`~/Library/Application Support/...`) is one
  # word only while every use of the variable is double-quoted.
  case "$word" in
    *' '*)
      name="${command_text%%"\$($body)"*}"
      name="${name#"${name%%[![:space:]]*}"}"
      name="${name%%=*}"
      scope_var_uses_double_quoted "$name" "${command_text//"\$($body)"/}" || return 1
      ;;
  esac
  # The real location, hex-encoded behind a marker so it stays one plain
  # word. The marker keeps a `..` after the location refused
  # (scope_block_tool_location_parent); path resolution decodes it
  # (scope_resolve_absolute_path), so the rest of the path is checked against
  # the real folder and its symlinks are followed. A link under the npm root
  # into another company is denied like the literal path.
  printf '/__hq_scope_%s_location__%s' "$tool" \
    "$(printf '%s' "$word" | od -An -v -tx1 | tr -d ' \n')"
}

# The top of the git work tree that holds the command's cwd, for
# `R=$(git rev-parse --show-toplevel)` as the command's first statement, so no
# earlier statement can cd, set GIT_DIR, or change git config. git is asked
# here, in the same cwd, and the real path is returned, so the usual checks
# apply to whatever it names. GIT_DIR or GIT_WORK_TREE in the environment, a
# git binary inside HQ, or output that is not one absolute path leaves it
# unknown. Only this command shape pays for the call.
scope_git_toplevel_value() {
  local body="${1:-}" command_text="${2:-}" word re bin
  word="${command_text%%"\$($body)"*}"
  [ "$word" != "$command_text" ] || return 1
  re='^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="?$'
  [[ "$word" =~ $re ]] || return 1
  [ -z "${GIT_DIR:-}${GIT_WORK_TREE:-}" ] || return 1
  case "${COMMAND_CWD:-}" in /*) ;; *) return 1 ;; esac
  bin="$(command -v git 2>/dev/null || true)"
  case "$bin" in
    "$HQ_ROOT"|"$HQ_ROOT"/*) return 1 ;;
    /*) ;;
    *) return 1 ;;
  esac
  word="$(git -C "$COMMAND_CWD" rev-parse --show-toplevel 2>/dev/null)" || return 1
  case "$word" in /*) ;; *) return 1 ;; esac
  case "$word" in *$'\n'*|*'..'*|*'$'*|*'`'*) return 1 ;; esac
  printf '%s' "$word"
}

scope_date_substitution_value() {
  local sub="${1:-}" fmt out="" ch i
  [[ "$sub" =~ ^\$\(date([[:space:]]+(-u|--utc))?[[:space:]]+(\'\+[^\']*\'|\"\+[^\"]*\"|\+[A-Za-z0-9_:%-]*)\)$ ]] || return 1
  fmt="${BASH_REMATCH[3]}"
  fmt="${fmt#[\'\"]}"
  fmt="${fmt%[\'\"]}"
  fmt="${fmt#+}"
  [ -n "$fmt" ] || return 1
  for ((i = 0; i < ${#fmt}; i++)); do
    ch="${fmt:i:1}"
    if [ "$ch" = "%" ]; then
      i=$((i + 1))
      case "${fmt:i:1}" in
        Y|m|d|H|M|S|s|j|u|w|y|F|T|G|g|V|U|W|C|N|I) out+="0" ;;
        *) return 1 ;;
      esac
      continue
    fi
    case "$ch" in
      [A-Za-z0-9_:-]) out+="$ch" ;;
      *) return 1 ;;
    esac
  done
  printf '%s' "$out"
}

# Assignment counts match NAME=, NAME+=, and NAME[...]= / NAME[...]+=:
# assigning element 0 (W[0]=, W[1-1]=) rebinds the scalar $W too.
# scope_dequote_text <text>: the text with every quote and backslash removed,
# so a quoted or escaped command word (u''nset, de"clare, \\read, f""or)
# reads as the word the shell runs. Rebinding checks run on this copy as well
# as on the raw text.
scope_dequote_text() {
  local t="${1:-}"
  printf '%s' "${t//[\"\'\\]/}"
}

# scope_text_has_ansi_escape <text>: true when the text holds a $'...' string
# with a backslash escape. $'\x75nset' is `unset` to the shell, and no
# dequoted copy shows that, so rebinding checks fail closed on it.
scope_text_has_ansi_escape() {
  local t="${1:-}" re
  re="\\$'[^']*\\\\"
  [[ "$t" =~ $re ]]
}

# scope_text_touches_ifs <text>: true when the text names IFS other than as
# a $IFS read (IFS=, IFS+=, read IFS, for IFS, declare IFS, I""FS=). A changed
# IFS splits an unquoted $W ("indigo" with IFS=i becomes "", "nd", "go"), so
# the guard cannot know which words a followed variable produces.
scope_text_touches_ifs() {
  local t="${1:-}" re dq
  dq="$(scope_dequote_text "$t")"
  re='(^|[^A-Za-z0-9_$])IFS([^A-Za-z0-9_}]|$)'
  [[ "$t" =~ $re || "$dq" =~ $re ]]
}

# scope_unset_may_touch <name> <command text>: true when an `unset` in the
# command can remove <name>. `unset GH_TOKEN GITHUB_TOKEN` names other
# variables and cannot, so it no longer voids an unrelated literal binding
# (feedback_9095ae4c). Any unset whose operands the guard cannot read word by
# word (an expansion, a quote, a glob, `-n`, or an unset not followed by plain
# words) counts as touching every name.
scope_unset_may_touch() {
  local name="${1:-}" cmd="${2:-}" rest args w re dq
  # A quoted or escaped command word (u''nset, un"set, \unset) is still unset
  # to the shell. Match on a copy with quotes and backslashes removed; if that
  # copy names unset but the raw text does not, the guard cannot read the
  # operands, so treat it as touching every name.
  scope_text_has_ansi_escape "$cmd" && return 0
  dq="$(scope_dequote_text "$cmd")"
  re='(^|[^A-Za-z0-9_.-])unset([[:space:]]|$)'
  [[ "$dq" =~ $re ]] || return 1
  # More unset words in the dequoted copy than in the raw text means at least
  # one unset is quoted or escaped (u''nset, un"set", \unset, $'unset'), even
  # when a plain `unset OTHER` is also present. Its operands are not read here.
  local n_dq n_raw
  n_dq="$(printf '%s' "$dq" | grep -oE "$re" 2>/dev/null | wc -l | tr -d '[:space:]')"
  n_raw="$(printf '%s' "$cmd" | grep -oE "$re" 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ "$n_dq" = "$n_raw" ] || return 0
  rest="$cmd"
  re='(^|[^A-Za-z0-9_.-])unset([[:space:]]+[^;&|'$'\n'')}]*)?'
  while [[ "$rest" =~ $re ]]; do
    args="${BASH_REMATCH[2]:-}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
    [ -n "${args//[[:space:]]/}" ] || continue
    local -a unset_words=()
    read -r -a unset_words <<<"$args"
    for w in ${unset_words[@]+"${unset_words[@]}"}; do
      case "$w" in
        -v|-f) ;;
        -*) return 0 ;;
        "$name") return 0 ;;
        *[!A-Za-z0-9_]*) return 0 ;;
      esac
    done
  done
  return 1
}

# Print "<text before the assignment>\037<value>" for the one assignment of
# <name> that the shell is guaranteed to have run before the use whose
# preceding text is <use_prefix>. Returns 1 unless all of these hold:
#   - <name> is assigned exactly once in the whole command, by a plain
#     `name=value` statement (optionally `export name=value`), and nothing
#     else in the command can rebind it (read, for, eval, source, declare,
#     local, unset, mapfile, getopts, printf -v, ${name:=...});
#   - that assignment sits in <use_prefix>, so it runs before the use and the
#     use cannot see a value inherited from the environment;
#   - it is a statement of its own (followed by `;`, `&&`, or a newline), not
#     a prefix of another command, which would not change this shell's value;
#   - nothing before it opens a subshell, group, function, loop, or
#     conditional, and it is not the right side of `||` or `|`; after `&&` the
#     use must be in the same `&&` chain, so a failed left side skips both;
#   - the value is literal text (quoted or not), `$VAR` pieces the caller
#     resolves in turn, or a slash-free `$(date +FORMAT)` (see above), with no
#     whitespace, glob, tilde, backslash, or backtick.
scope_assignment_literal_value() {
  local name="${1:-}" use_prefix="${2:-}" command_text="${3:-}"
  local count assign_re before after value raw stripped head_cut chain_rest re
  local backtick=$'\140' us=$'\037' nl=$'\n'
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  case "$command_text$use_prefix" in *"$us"*) return 1 ;; esac
  count="$(printf '%s' "$command_text" | grep -oE "(^|[^A-Za-z0-9_\$])${name}(\[[^]]*\])?\+?=" 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ "$count" = "1" ] || return 1
  re='(^|[^A-Za-z0-9_.-])(read|mapfile|readarray|getopts|eval|source|declare|typeset|local|let)([[:space:]]|$)'
  [[ "$command_text" =~ $re ]] && return 1
  # Same check on a copy without quotes or backslashes (r''ead, de"clare).
  local dq_text
  dq_text="$(scope_dequote_text "$command_text")"
  [[ "$dq_text" =~ $re ]] && return 1
  scope_unset_may_touch "$name" "$command_text" && return 1
  scope_text_has_ansi_escape "$command_text" && return 1
  scope_text_touches_ifs "$command_text" && return 1
  re='printf[[:space:]]+-v'
  [[ "$command_text" =~ $re || "$dq_text" =~ $re ]] && return 1
  re='(^|[;&|({[:space:]])(for|select)[[:space:]]+'"$name"'([[:space:]]|;|$)'
  [[ "$command_text" =~ $re || "$dq_text" =~ $re ]] && return 1
  re='\$\{'"$name"':?='
  [[ "$command_text" =~ $re || "$dq_text" =~ $re ]] && return 1
  # Count assignments again on the dequoted copy, so ((W""=1)) or a quoted
  # second assignment is not missed.
  count="$(printf '%s' "$dq_text" | grep -oE "(^|[^A-Za-z0-9_\$])${name}(\[[^]]*\])?\+?=" 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ "$count" = "1" ] || return 1
  # `. file` at a command position sources code that can set anything.
  re='(^|[;&|({]|'"$nl"')[[:space:]]*\.[[:space:]]'
  [[ "$command_text" =~ $re || "$dq_text" =~ $re ]] && return 1

  assign_re="(^|[;&|[:space:](\{${backtick}])(export[[:space:]]+)?${name}="
  assign_re+='(\$\([^()]*\)|[A-Za-z0-9_./@+:-]*\$\([^()]*\)[A-Za-z0-9_./@+:-]*|"[^"]*"|'"'[^']*'"'|[^][;&|[:space:]<>()"'"'"'\\*?{}~`]*)'
  [[ "$use_prefix" =~ $assign_re ]] || return 1
  raw="${BASH_REMATCH[3]}"
  head_cut="${BASH_REMATCH[1]}${BASH_REMATCH[2]}$name=$raw"
  before="${use_prefix%%"$head_cut"*}${BASH_REMATCH[1]}"
  after="${use_prefix#*"$head_cut"}"
  # `W=a S=b; cp $S/x $W/` is one statement of plain assignments; with no
  # command word, bash sets each as a shell variable, left to right. Skip the
  # other assignment words on either side so the statement checks below see
  # it as if it held only this one. A word with an expansion, a quote, or any
  # other shell syntax is not skipped, and a following command word (`A=x
  # cmd`, which only sets A in cmd's environment) still fails the check.
  local plain_assign_re='[A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9_./@+:-]*'
  re='^[[:space:]]+'"$plain_assign_re"
  while [[ "$after" =~ $re ]]; do
    after="${after:${#BASH_REMATCH[0]}}"
  done
  re='(^|[;&'"$nl"'])[[:space:]]*('"$plain_assign_re"'[[:space:]]+)+$'
  if [[ "$before" =~ $re ]]; then
    before="${before%"${BASH_REMATCH[0]}"}${BASH_REMATCH[1]}"
  fi
  # A statement of its own: the value ends at `;`, `&&`, or a newline.
  re='^[[:space:]]*(;|&&|'"$nl"')'
  [[ "$after" =~ $re ]] || return 1
  # Nothing before it may open a nested or conditional context.
  # Text inside quotes or a heredoc body that merely looks like an
  # assignment (`echo "D=/tmp;"`) assigns nothing.
  case "$before" in *'('*|*'{'*|*"$backtick"*|*'||'*|*'<<'*) return 1 ;; esac
  scope_shell_prefix_is_unquoted "$before" || return 1
  stripped="${before%"${before##*[![:space:]]}"}"
  case "$stripped" in
    ""|*';'|*"$nl"|*'&&') ;;
    *) return 1 ;;
  esac
  case "$stripped" in *'|') return 1 ;; esac
  re='(^|[;&|[:space:]])(if|then|else|elif|while|until|for|select|case|do|function)([[:space:]]|;|$)'
  [[ "$before" =~ $re ]] && return 1
  # Right side of `&&`: the use must run only if this assignment ran.
  if [[ "$stripped" == *'&&' ]]; then
    chain_rest="${after//&&/}"
    case "$chain_rest" in *';'*|*'|'*|*'&'*|*"$nl"*) return 1 ;; esac
  fi

  case "$raw" in
    \"*\") value="${raw:1:${#raw}-2}"
      case "$value" in *"$backtick"*|*\\*) return 1 ;; esac
      case "$value" in
        *'$('*) value="$(scope_expand_one_substitution "$value" "$command_text")" || return 1 ;;
      esac
      ;;
    \'*\') value="${raw:1:${#raw}-2}"
      case "$value" in *'$'*) return 1 ;; esac
      ;;
    *'$('*)
      # One `$(...)` piece whose output is known without running it, alone
      # or between literal filename characters (`T=/tmp/theme-$(date +%s)`,
      # `CLI_DIR=$(npm root -g)/@indigoai-us/hq-cli`).
      value="$(scope_expand_one_substitution "$raw" "$command_text")" || return 1
      ;;
    *) value="$raw" ;;
  esac
  [ -n "$value" ] || return 1
  case "$value" in
    *[[:space:]]*)
      # A space inside a quoted value (`L="/x/My Drive/out"`) is one word only
      # while every use of the variable is inside double quotes; an unquoted
      # use word-splits it into several paths.
      case "$raw" in \"*\"|\'*\') ;; *) return 1 ;; esac
      case "$value" in *$'\n'*|*$'\t'*|*$'\r'*) return 1 ;; esac
      scope_var_uses_double_quoted "$name" "$command_text" || return 1
      ;;
  esac
  case "$value" in
    *'*'*|*'?'*|*'['*|*']'*|*"$backtick"*|*\\*|*"$us"*) return 1 ;;
    '~'*) return 1 ;;
  esac
  printf '%s%s%s' "$before" "$us" "$value"
}

scope_open_tree_expansion_is_provably_confined() {
  local candidate="${1:-}" command_prefix="${2:-}" root parent segment normalized_parent
  local token name assignment_re glob_segment match physical value backtick physical_parent physical_tree
  backtick=$'\140'
  local tokens
  case "$candidate" in
    workspace/*) root="workspace" ;;
    core/*) root="core" ;;
    personal/*) root="personal" ;;
    repos/*) root="repos" ;;
    *) return 1 ;;
  esac
  parent="${candidate%/*}"
  segment="${candidate##*/}"
  # Expansions in directory components are never granted the open-tree carve-out.
  case "$parent" in *'$'*|*"$backtick"*|*'$('*) return 1 ;; esac
  normalized_parent="$(scope_normalize_hq_relative "$parent")"
  case "$normalized_parent" in "$root"|"$root"/*) ;; *) return 1 ;; esac
  [ -d "$HQ_ROOT/$normalized_parent" ] || return 1
  physical_tree="$(scope_resolve_absolute_path "$HQ_ROOT/$root" 2>/dev/null || true)"
  physical_parent="$(scope_resolve_absolute_path "$HQ_ROOT/$normalized_parent" 2>/dev/null || true)"
  [ -n "$physical_tree" ] && [ -n "$physical_parent" ] || return 1
  case "$physical_parent" in "$physical_tree"|"$physical_tree"/*) ;; *) return 1 ;; esac
  tokens="$(printf '%s' "$segment" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' 2>/dev/null || true)"
  [ -n "$tokens" ] || return 1
  glob_segment="$segment"
  for token in $tokens; do
    name="$(printf '%s' "$token" | sed 's/^\$//;s/^{//;s/}$//')"
    assignment_re='(^|[;[:space:]])'
    assignment_re+="$name="
    assignment_re+='("[^"[:cntrl:]]*"|'
    assignment_re+="'[^'[:cntrl:]]*'"
    assignment_re+='|[^;|&[:space:]]+)'
    if [[ "$command_prefix" =~ $assignment_re ]]; then
      value="${BASH_REMATCH[2]}"
      case "$value" in
        \"*\") value="${value:1:${#value}-2}" ;;
        \'*\') value="${value:1:${#value}-2}" ;;
      esac
      case "$value" in *'/'*|*'..'*|*'$'*|*"$backtick"*) value="" ;; esac
      [ -n "$value" ] || return 1
      glob_segment="${glob_segment//"$token"/*}"
      continue
    fi
    return 1
  done
  case "$glob_segment" in *'$'*|*"$backtick"*|*'$('*) return 1 ;; esac
  while IFS= read -r match; do
    [ -n "$match" ] || continue
    physical="$(scope_resolve_absolute_path "$match" 2>/dev/null || true)"
    case "$physical" in
      "$HQ_ROOT/$root"|"$HQ_ROOT/$root"/*) ;;
      *) return 1 ;;
    esac
  done < <(compgen -G "$physical_parent/$glob_segment" || true)
  # No existing entry can be checked. The slash-free value and resolved
  # parent still prove that a future path cannot leave this tree.
  return 0
}

scope_open_tree_expansion_values_resolve() {
  local candidate="${1:-}" prefix="${2:-}" command_text="${3:-}" token name tokens values
  [ -n "$prefix" ] || return 1
  tokens="$(printf '%s' "$candidate" | grep -oE '\$\{?([A-Za-z_][A-Za-z0-9_]*|[1-9])\}?' 2>/dev/null || true)"
  [ -n "$tokens" ] || return 1
  # One variable only; several would multiply into combinations not checked here.
  [ "$(printf '%s\n' "$tokens" | wc -l | tr -d '[:space:]')" = "1" ] || return 1
  token="$tokens"
  name="${token#\$}"; name="${name#\{}"; name="${name%\}}"
  values="$(scope_shell_variable_values "$name" "$prefix" "$command_text" || true)"
  [ -n "$values" ] || return 1
  case "$values" in *'..'*) return 1 ;; esac
  # Every substituted path must sit in a directory that exists now and resolves
  # physically inside the same open tree. A path the hook cannot resolve stays
  # fail-closed (IC-0019).
  local value expanded root parent physical_tree physical_parent new_dirs_ok=0 link_re
  root="${candidate%%/*}"
  link_re='(^|[;&|({[:space:]])mkdir[[:space:]]'
  [[ "$command_text" =~ $link_re ]] && new_dirs_ok=1
  link_re='(^|[;&|({[:space:]])(ln|mv|cp|rsync|tar|unzip|install)([[:space:]]|;|$)'
  [[ "$command_text" =~ $link_re ]] && new_dirs_ok=0
  physical_tree="$(scope_resolve_absolute_path "$HQ_ROOT/$root" 2>/dev/null || true)"
  [ -n "$physical_tree" ] || return 1
  while IFS= read -r value; do
    [ -n "$value" ] || return 1
    expanded="${candidate//"$token"/$value}"
    case "$expanded" in "$root"/*) ;; *) return 1 ;; esac
    parent="${expanded%/}"
    parent="${parent%/*}"
    # A directory the same command creates first (`mkdir -p
    # "personal/skills/$1"; echo x > "personal/skills/$1/SKILL.md"`) does not
    # exist yet. The value holds no `..`, so the path lands under its nearest
    # existing ancestor, which must resolve inside the tree. Only a command
    # that runs mkdir gets this. A dangling symlink on the way, or a command
    # that can place a link or move an entry there first (ln, mv, cp, ...),
    # keeps the path unresolved, as does a missing parent with no mkdir.
    if [ ! -d "$HQ_ROOT/$parent" ]; then
      [ "$new_dirs_ok" = 1 ] || return 1
      while [ ! -e "$HQ_ROOT/$parent" ]; do
        [ ! -L "$HQ_ROOT/$parent" ] || return 1
        case "$parent" in */*) parent="${parent%/*}" ;; *) return 1 ;; esac
      done
      [ -d "$HQ_ROOT/$parent" ] || return 1
    fi
    physical_parent="$(scope_resolve_absolute_path "$HQ_ROOT/$parent" 2>/dev/null || true)"
    case "$physical_parent" in "$physical_tree"|"$physical_tree"/*) ;; *) return 1 ;; esac
  done <<< "$values"
  return 0
}

scope_resolve_resumework_basename_value() {
  local candidate="${1:-}" command_text="${2:-}" assignment_re value thread_id backtick
  backtick=$'\140'
  if [[ "$command_text" != *'id="${arg%.json}"'* || "$command_text" != *'id="${id##*/}"'* ]]; then
    printf '%s' "$candidate"
    return 0
  fi
  assignment_re='(^|[;[:space:]])arg=("[^"[:cntrl:]]*"|[^;|&[:space:]]+)'
  [[ "$command_text" =~ $assignment_re ]] || { printf '%s' "$candidate"; return 0; }
  value="${BASH_REMATCH[2]}"
  case "$value" in \"*\") value="${value:1:${#value}-2}" ;; esac
  case "$value" in *'$'*|*"$backtick"*) printf '%s' "$candidate"; return 0 ;; esac
  case "$value" in *.json) value="${value%.json}" ;; esac
  thread_id="${value##*/}"
  [ -n "$thread_id" ] || { printf '%s' "$candidate"; return 0; }
  case "$thread_id" in .|..|*/*) printf '%s' "$candidate"; return 0 ;; esac
  candidate="${candidate//\$\{id\}/$thread_id}"
  candidate="${candidate//\$id/$thread_id}"
  candidate="${candidate//\$$thread_id/$thread_id}"
  printf '%s' "$candidate"
}

# A git revision operand or a gh repo slug that carries a shell variable is not
# a filesystem path: git resolves `$C:refs/heads/x` or `origin/main...$b` in
# the object store and gh sends `owner/$r` to the GitHub API. Recognise only
# those exact operand positions and shapes, so a variable path handed to any
# other program, or to git after `--` / `--no-index`, is still checked.
# Arguments: <index of the token in scope_tokens>.
# True when <word> is an http(s) URL given to a network client and is not the
# separate-word value of an output/upload/config option (`-o <word>`). Attached
# forms (`-ofile`, `--output=file`) are not recognised here; such a word does
# not start with http(s):// and is checked as a path by the caller's scan.
# Arguments: <command head basename> <previous word> <word>.
scope_url_is_remote_operand() {
  local head="${1:-}" prev="${2:-}" word="${3:-}"
  case "$word" in http://*|https://*) ;; *) return 1 ;; esac
  case "$head" in curl|wget|gh|git|http|https|xh|open|lynx|w3m) ;; *) return 1 ;; esac
  case "$prev" in -o|-O|--output|--output-document|-T|--upload-file|-K|--config|-d|--data*|-F|--form) return 1 ;; esac
  # An unquoted expansion after the scheme can split into a second,
  # local operand (file:///...), so it is not proven remote.
  scope_word_is_literal_remote_url "$word" || return 1
  return 0
}

# `curl "https://api.x/y?d=$(date +%F)"`: an http(s) URL handed to a network
# client whose only non-literal parts are plain `$(...)` substitutions. The
# URL itself is remote (see scope_url_is_remote_operand); the substitution
# bodies still run, so they are returned in scope_prose_subs for the caller to
# scan with the strict substitution rules. Backticks, nested substitutions,
# or any backslash in the command keep the normal fail-closed path check.
# Arguments: <index of the token in scope_tokens>.
scope_token_is_remote_url_with_substitutions() {
  local index="${1:-0}" token head head_index reduced sub_re mark=$'\001'
  scope_prose_subs=()
  [ "$index" -gt 0 ] || return 1
  token="${scope_tokens[$index]:-}"
  case "$token" in http://*'$('*|https://*'$('*) ;; *) return 1 ;; esac
  case "$token" in *$'\140'*|*"$mark"*) return 1 ;; esac
  [[ "${scope_scan_cmd:-}" == *\\* ]] && return 1
  head_index="$(scope_command_head_index)"
  [ "$index" -gt "$head_index" ] || return 1
  head="${scope_tokens[$head_index]##*/}"
  scope_url_is_remote_operand "$head" "${scope_tokens[$((index - 1))]}" "$token" || return 1
  reduced="$token"
  sub_re='\$\(([^()]*)\)'
  while [[ "$reduced" =~ $sub_re ]]; do
    scope_prose_subs[${#scope_prose_subs[@]}]="${BASH_REMATCH[1]}"
    reduced="${reduced/"${BASH_REMATCH[0]}"/$mark}"
    [ "${#scope_prose_subs[@]}" -le 16 ] || return 1
  done
  case "$reduced" in *'$('*|*'('*|*')'*|*[[:space:]]*) return 1 ;; esac
  return 0
}

# `U=https://api.x; curl -s "$U/items/$ID"`: a network-client operand whose
# leading variable the same command assigned exactly once, earlier, to a
# literal http(s) URL. The operand then names a remote resource, the same as
# the URL typed out (scope_url_is_remote_operand). The value must be a plain
# http(s) URL (no file://, no expansion); a second assignment, a rebinding
# builtin, `.`/source, or an assignment after the use leaves the operand to
# the normal path checks.
# Arguments: <index of the token in scope_tokens>.
# The /deploy engine's API resolver (`API=$(bash
# .claude/skills/deploy/scripts/resolve-deploy-api.sh); curl -s "$API/..."`,
# feedback 14cef35c, aba2d75e, 160bb7d7). The script prints $HQ_DEPLOY_API,
# else the hq-deploy endpoint from the nearest companies/manifest.yaml, else
# https://api.hq.work. Its output is computed here the same way and accepted
# only when it is a plain https URL, so the variable names a remote resource
# for a network client. The script must be the shipped file (pinned by
# hash, not a link); a command that names HQ_DEPLOY_API, the manifest or a
# directory change, or a relative script path from a cwd other than the HQ
# root, leaves the value unknown.
SCOPE_DEPLOY_API_SHA256="0b622ae7efff3be76e8eb199f8327be662bef371a3612d356df505c5a696b492"
scope_deploy_api_resolver_value() {
  local body="${1:-}" cmd="${2:-}" script rel re sum api="" d m cwd
  body="${body#"${body%%[![:space:]]*}"}"
  body="${body%"${body##*[![:space:]]}"}"
  rel=".claude/skills/deploy/scripts/resolve-deploy-api.sh"
  case "$body" in
    "bash $rel"|"$rel"|"./$rel"|"bash ./$rel")
      cwd="$(cd "${COMMAND_CWD:-$HQ_ROOT}" 2>/dev/null && pwd -P)" || return 1
      [ "$cwd" = "$HQ_ROOT" ] || return 1
      ;;
    "bash $HQ_ROOT/$rel"|"$HQ_ROOT/$rel") ;;
    *) return 1 ;;
  esac
  script="$HQ_ROOT/$rel"
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  re='(HQ_DEPLOY_API|manifest|(^|[^A-Za-z0-9_])(cd|pushd|popd|ln|mv|cp|install|tee|eval|source|export|alias|function)([^A-Za-z0-9_]|$)|[(][)]|>)'
  [[ "$cmd" =~ $re ]] && return 1
  if command -v shasum >/dev/null 2>&1; then
    sum="$(shasum -a 256 "$script" 2>/dev/null)" || return 1
  else
    sum="$(sha256sum "$script" 2>/dev/null)" || return 1
  fi
  [ "${sum%% *}" = "$SCOPE_DEPLOY_API_SHA256" ] || return 1
  api="${HQ_DEPLOY_API:-}"
  if [ -z "$api" ]; then
    d="$(cd "${COMMAND_CWD:-$HQ_ROOT}" 2>/dev/null && pwd -P)" || return 1
    while [ -n "$d" ] && [ "$d" != "/" ]; do
      m="$d/companies/manifest.yaml"
      if [ -f "$m" ]; then
        api="$(awk -F'endpoint:[ \t]*' '/hq-deploy/{f=1} f&&/endpoint:/{gsub(/[ \t\r]+$/,"",$2); print $2; exit}' "$m" 2>/dev/null || true)"
        break
      fi
      d="$(dirname "$d")"
    done
  fi
  api="${api:-https://api.hq.work}"
  [[ "$api" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]] || return 1
  case "$api" in *'..'*) return 1 ;; esac
  printf '%s' "$api"
}

scope_token_is_url_variable_operand() {
  local index="${1:-0}" token head head_index name assign_re count_re value cmd bind_re
  [ "$index" -gt 0 ] || return 1
  token="${scope_tokens[$index]:-}"
  if [[ "$token" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}(/.*)?$ ]] || [[ "$token" =~ ^\$([A-Za-z_][A-Za-z0-9_]*)(/.*)?$ ]]; then
    name="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  case "$token" in *'$('*|*$'\140'*) return 1 ;; esac
  head_index="$(scope_command_head_index)"
  [ "$index" -gt "$head_index" ] || return 1
  head="${scope_tokens[$head_index]##*/}"
  scope_url_is_remote_operand "$head" "${scope_tokens[$((index - 1))]}" "https://x" || return 1
  cmd="${scope_scan_cmd:-}"
  assign_re="(^|[;&|[:space:]])${name}=(\"|')?(https?://[A-Za-z0-9._~:/?#@!+,=%-]+)(\"|')?([;&[:space:]]|\$)"
  local resolver_re="^[[:space:]]*${name}=(\"?)\\\$\\(([^()\$\`;&|<>]+)\\)(\"?)[[:space:]]*(;|&&)"
  if [[ "$cmd" =~ $resolver_re ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[3]}" ] \
    && value="$(scope_deploy_api_resolver_value "${BASH_REMATCH[2]}" "$cmd")"; then
    # The resolver opens the command, so it runs first; the checks below
    # still require it to be the only assignment of the name.
    [[ "$cmd" =~ $resolver_re ]] || return 1
  else
    [[ "$cmd" =~ $assign_re ]] || return 1
    value="${BASH_REMATCH[3]}"
    [ "${BASH_REMATCH[2]}" = "${BASH_REMATCH[4]}" ] || return 1
  fi
  # Exactly one assignment in the whole command, and it comes before the use.
  count_re="(^|[^A-Za-z0-9_\$])${name}(\[[^]]*\])?\+?="
  [ "$(printf '%s' "$cmd" | grep -oE "$count_re" 2>/dev/null | wc -l | tr -d '[:space:]')" = "1" ] || return 1
  [[ "$cmd" == *"${BASH_REMATCH[0]}"*"$token"* ]] || return 1
  bind_re='(^|[^A-Za-z0-9_.-])(read|mapfile|readarray|getopts|eval|source|declare|typeset|local|unset|let|for|select)([[:space:]]|$)|printf[[:space:]]+-v|(^|[;&|({]|'$'\n'')[[:space:]]*\.[[:space:]]'
  [[ "$cmd" =~ $bind_re ]] && return 1
  local url_dq
  url_dq="$(scope_dequote_text "$cmd")"
  [[ "$url_dq" =~ $bind_re ]] && return 1
  [ "$(printf '%s' "$url_dq" | grep -oE "$count_re" 2>/dev/null | wc -l | tr -d '[:space:]')" = "1" ] || return 1
  scope_text_has_ansi_escape "$cmd" && return 1
  case "$value" in http://*|https://*) return 0 ;; esac
  return 1
}

scope_token_is_vcs_ref_operand() {
  local index="${1:-0}" token head url_head url_head_index i sub="" ref_re range_re refspec_re
  token="${scope_tokens[$index]:-}"
  case "$token" in *'$'*) ;; *) return 1 ;; esac
  case "$token" in *'$('*|*$'\140'*|*[[:space:]]*) return 1 ;; esac
  head="${scope_tokens[0]##*/}"
  [ "$index" -gt 0 ] || return 1
  # A loop or conditional keyword can lead the record (`do curl ...`); the
  # URL exemption must see the program itself. git and gh keep using token 0.
  url_head_index="$(scope_command_head_index)"
  url_head="${scope_tokens[$url_head_index]##*/}"
  if [ "$head" = gh ]; then
    # gh sends the -R/--repo value to the GitHub API; it never opens it.
    case "${scope_tokens[$((index - 1))]}" in -R|--repo) return 0 ;; esac
    case "$token" in --repo=*) return 0 ;; esac
    # `gh repo <subcommand> OWNER/$name`: the operand is a GitHub slug.
    if [ "${scope_tokens[1]:-}" = repo ] && [ "$index" -eq 3 ]; then
      case "$token" in
        companies/*|repos/*|workspace/*|core/*|personal/*|.*|/*|'~'*) ;;
        [A-Za-z0-9]*/[A-Za-z0-9_.-]*'$'*|[A-Za-z0-9]*/'$'*)
          case "${token%%/*}" in *[!A-Za-z0-9_.-]*) ;; *) return 0 ;; esac ;;
      esac
    fi
  fi
  # An http(s) URL handed to a network client names a remote resource. Any
  # other program opens `https://x/...` as the local path `https:/x/...`
  # (a planted `https:` symlink makes that a tenant path), so only the
  # clients below are exempt. Checked before the glob test: a query string
  # such as `?r=$RANDOM` is not a glob.
  if [ "$index" -gt "$url_head_index" ]; then
    scope_url_is_remote_operand "$url_head" "${scope_tokens[$((index - 1))]}" "$token" && return 0
  fi
  case "$token" in *'*'*|*'?'*|*'['*) return 1 ;; esac
  # git inside a function body or a loop (`show() { git show
  # origin/master:$1; }`) sits past the `{` or `do` the splitter leaves in
  # the record; the program word is at url_head_index.
  [ "$head" = git ] || [ "$url_head" = git ] || return 1
  # Find the git subcommand past global options; give up on anything unusual.
  i=$((url_head_index + 1))
  while [ "$i" -lt "$index" ]; do
    case "${scope_tokens[$i]}" in
      -C|-c|--git-dir|--work-tree) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) sub="${scope_tokens[$i]}"; break ;;
    esac
  done
  [ -n "$sub" ] && [ "$i" -lt "$index" ] || return 1
  case "$sub" in
    push|fetch|log|diff|show|rev-parse|rev-list|merge-base|range-diff|shortlog|cherry|cherry-pick|branch|switch|merge|rebase|tag|update-ref|ls-tree) ;;
    *) return 1 ;;
  esac
  for ((i = i + 1; i < index; i++)); do
    case "${scope_tokens[$i]}" in --|--no-index) return 1 ;; esac
  done
  # A ref never starts with `.` or `/` and never has a `.`-led component
  # (git check-ref-format), so these shapes cannot spell an upward path.
  # A positional parameter in a function body (`show() { git show
  # origin/master:$1; }`) is a ref piece like a named variable (feedback
  # c7d028ed).
  ref_re='(\$\{?([A-Za-z_][A-Za-z0-9_]*|[0-9])\}?|[A-Za-z0-9_@][A-Za-z0-9_@/^~-]*)+'
  range_re="^(${ref_re})?\.\.\.?(${ref_re})?\$"
  refspec_re="^\+?(${ref_re})?:(${ref_re})?\$"
  case "$token" in /*|*/.*) return 1 ;; esac
  if [[ "$token" =~ $range_re ]]; then
    case "$token" in *'....'*) return 1 ;; esac
    return 0
  fi
  [[ "$token" =~ $refspec_re ]] || return 1
  case "$sub" in push|fetch|show|ls-tree|rev-parse|log|diff) return 0 ;; esac
  return 1
}

# Index in scope_tokens of the program a simple command runs: the splitter
# leaves a leading loop or conditional keyword (`do echo ...`, `then sed
# ...`) in the record, so skip those words.
scope_command_head_index() {
  local i=0
  while [ "$i" -lt "${#scope_tokens[@]}" ]; do
    case "${scope_tokens[$i]}" in
      do|then|else|elif|'{'|'!'|while|until|if) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  printf '%s' "$i"
}

# scope_mask_simple_arithmetic <word> — sets scope_arith_view to <word> with
# every simple arithmetic expansion replaced by the digit 0. Arithmetic yields
# an integer, so `$((tot/10))` can never name a path and its `/` is division;
# `0` keeps the word's shape for the path checks that follow (`$((n))/x`
# becomes the literal `0/x`). Only a body made of names, digits, blanks, and
# the operators + - * / % is simple. A body with `$`, brackets, braces,
# parentheses, backticks, or any other punctuation is left as written and
# stays on the fail-closed path: bash evaluates `$(cmd)` inside arithmetic,
# and array subscripts can hold commands.
scope_mask_simple_arithmetic() {
  local word="${1:-}" re out="" rest
  scope_arith_view="$word"
  case "$word" in *'$(('*) ;; *) return 0 ;; esac
  re='\$\(\(([A-Za-z0-9_[:space:]+*/%-]*)\)\)'
  rest="$word"
  while [[ "$rest" =~ $re ]]; do
    out+="${rest%%"${BASH_REMATCH[0]}"*}0"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
  scope_arith_view="$out$rest"
}

# A shell word such as "EXISTS: $(wc -l < f) lines" or the prose line of an
# interpreter heredoc ("see `companies/x` and ...") contains a slash but is
# not a path anyone opens: its first path component begins with a plain word
# followed by whitespace, and no entry with that prefix exists in the command
# cwd. Such a word is prose. Its $(...) bodies still run, so they are
# returned in scope_prose_subs for the caller to scan as commands. Anything
# ambiguous (backticks, nested substitutions, a leading variable, an absolute
# or home path, parent traversal, an existing matching entry) returns 1 and
# keeps the normal fail-closed path check.
#
# Where the word's value is not fully literal (a substitution or variable),
# a shell command could still open it — `mkdir -p "x $(...)"` creates the
# odd first directory and then follows the substituted remainder. So outside
# an interpreter heredoc body, a non-literal prose word is accepted only as
# an echo/printf argument that is not a redirection target.
# Arguments: <token> <context: shell|body> <token index in scope_tokens>.
# A word that is one `$(...)` (or backtick) substitution given to a command
# that opens no file: `echo "$(tail -1 f)"`, `printf '%s\n' "$(...)"`, and a
# string comparison in test (`[ "$(curl ...)" = 200 ]`, `test "$(...)" = ok`,
# `[[ ... ]]`). The value is printed or compared, never opened, so the outer
# word is data; the body still runs and is returned in scope_prose_subs for
# the caller to check as a command of its own. Not for a file test (`[ -f
# "$(...)" ]`, `-nt`/`-ot`/`-ef`), not for echo/printf text piped into a
# shell or interpreter, and not after a redirection operator. A `curl -w
# FORMAT` pair inside the body is dropped before the body check: the format
# (`%{http_code}`) is write-out text, not a brace expansion (feedback
# 41420292, d5df3977, 98c1ecff, aba2d75e).
scope_token_is_nofile_substitution() {
  local index="${1:-0}" token head head_index prev next body backtick=$'\140' shell_pipe_re
  scope_prose_subs=()
  [ "$index" -gt 0 ] || return 1
  token="${scope_tokens[$index]:-}"
  case "$token" in
    '$('*')') body="${token#\$(}"; body="${body%)}" ;;
    "$backtick"*"$backtick") body="${token#"$backtick"}"; body="${body%"$backtick"}" ;;
    *) return 1 ;;
  esac
  case "$body" in *'$('*|*"$backtick"*|*'('*|*')'*|*"$(printf '\001')"*) return 1 ;; esac
  [ -n "$body" ] || return 1
  [[ "${scope_scan_cmd:-}" == *\\* ]] && return 1
  head_index="$(scope_command_head_index)"
  [ "$index" -gt "$head_index" ] || return 1
  head="${scope_tokens[$head_index]:-}"
  head="${head##*/}"
  prev="${scope_tokens[$((index - 1))]:-}"
  next="${scope_tokens[$((index + 1))]:-}"
  [[ "$prev" =~ ^[0-9]*(\<|\>|\>\>|\<\<\<|\>\||\<\<|\<\&|\>\&)$|^\&\>\>?$ ]] && return 1
  shell_pipe_re='\|[[:space:]]*(sudo[[:space:]]+|env[[:space:]]+|command[[:space:]]+|exec[[:space:]]+)*([^[:space:]|;&]*/)?(bash|sh|zsh|dash|ksh|fish|xargs|eval|source|python[0-9.]*|node|perl|ruby|parallel|while|read)([[:space:]]|$)'
  # A body that pipes its text into a shell or interpreter (`cat f | bash`)
  # runs that text; it is not data for any head.
  [[ "$body" =~ $shell_pipe_re ]] && return 1
  case "$head" in
    echo|printf)
      [[ "${scope_scan_cmd:-}" =~ $shell_pipe_re ]] && return 1
      ;;
    '['|'[['|test)
      case "$prev" in -[a-zA-Z]|-[a-zA-Z][a-zA-Z]) return 1 ;; esac
      case "$next" in -nt|-ot|-ef|-eq|-ne|-lt|-le|-gt|-ge) return 1 ;; esac
      case "$prev" in -nt|-ot|-ef) return 1 ;; esac
      ;;
    gh)
      # `gh pr checks "$(git -C <repo> branch --show-current)"`: the word
      # right after the verb names a pull request (number, branch or URL),
      # which gh looks up on GitHub; it never opens it as a file. The body is
      # still checked as a command below (feedback d5df3977).
      [ "${scope_tokens[$((head_index + 1))]:-}" = pr ] || return 1
      case "${scope_tokens[$((head_index + 2))]:-}" in
        checks|view|status|merge|diff|ready|close|reopen|checkout) ;;
        *) return 1 ;;
      esac
      [ "$index" -eq $((head_index + 3)) ] || return 1
      scope_subst_body_is_safe "$body" || return 1
      ;;
    *) return 1 ;;
  esac
  # `curl ... -w %{http_code} URL` inside the body: drop the write-out pair
  # when the format holds only %{name} fields and plain text (no @file, no
  # %output{...}), so the brace check in scope_check_prose_substitutions
  # sees the request itself.
  # The format may be single- or double-quoted (`-w '%{http_code}'`,
  # feedback aba2d75e); the quotes must match.
  local wo_re='(^|[[:space:]])(-w|--write-out)[[:space:]]+(['"'"'"]?)([A-Za-z0-9_%{}:.=,-]+)(['"'"'"]?)([[:space:]]|$)'
  if [[ "$body" =~ $wo_re ]]; then
    [ "${BASH_REMATCH[3]}" = "${BASH_REMATCH[5]}" ] || return 1
    case "${BASH_REMATCH[4]}" in *'@'*|*output*|*'%{'*'%{'*'%{'*'%{'*) return 1 ;; esac
    body="${body/"${BASH_REMATCH[0]}"/ }"
  fi
  scope_prose_subs[0]="$body"
  return 0
}

scope_token_is_prose() {
  local token="${1:-}" context="${2:-shell}" index="${3:-0}"
  local reduced lead sub_re body cwd head prev backtick=$'\140' mark=$'\001' lead_is_var=0 shell_pipe_re whole_sub=0
  scope_prose_subs=()
  case "$token" in /*|~*|*"$mark"*) return 1 ;; esac
  reduced="$token"
  sub_re='\$\(([^()]*)\)'
  while [[ "$reduced" =~ $sub_re ]]; do
    body="${BASH_REMATCH[1]}"
    scope_prose_subs[${#scope_prose_subs[@]}]="$body"
    reduced="${reduced/"${BASH_REMATCH[0]}"/$mark}"
    [ "${#scope_prose_subs[@]}" -le 16 ] || return 1
  done
  sub_re="$backtick([^$backtick\\\\]*)$backtick"
  while [[ "$reduced" =~ $sub_re ]]; do
    body="${BASH_REMATCH[1]}"
    scope_prose_subs[${#scope_prose_subs[@]}]="$body"
    reduced="${reduced/"${BASH_REMATCH[0]}"/$mark}"
    [ "${#scope_prose_subs[@]}" -le 16 ] || return 1
  done
  # A word that is exactly one substitution (`echo "$(wc -l core/x)"`) prints
  # the substitution's output and opens nothing itself, the same as the
  # `"n: $(...)"` form with a text lead. It is accepted only as an echo/printf
  # argument in shell context (the checks below), and its body is still
  # scanned as a command by the caller.
  if [ "$context" != body ] && [ "$reduced" = "$mark" ]; then
    whole_sub=1
    lead_is_var=1
  fi
  # A substitution body that pipes text into a shell or interpreter
  # (`echo "$(cat f | sh)"`) runs that text; no prose exemption for it.
  shell_pipe_re='\|[[:space:]]*(sudo[[:space:]]+|env[[:space:]]+|command[[:space:]]+|exec[[:space:]]+)*([^[:space:]|;&]*/)?(bash|sh|zsh|dash|ksh|fish|xargs|eval|source|python[0-9.]*|node|perl|ruby|parallel|while|read)([[:space:]]|$)'
  local sub_body
  for sub_body in ${scope_prose_subs[@]+"${scope_prose_subs[@]}"}; do
    [[ "$sub_body" =~ $shell_pipe_re ]] && return 1
  done
  case "$reduced" in *[[:space:]]*) ;; *) [ "$whole_sub" -eq 1 ] || return 1 ;; esac
  # A `..` in the text itself can climb out of the first component. A `..`
  # inside a substitution body (`git log origin/main..HEAD`) is an argument
  # of that command; the body is checked as a command by the caller.
  case "$reduced" in *'..'*) return 1 ;; esac
  # The tokenizer has already removed escapes, so a body's `a\ b` would be
  # re-split differently from how the shell runs it. With any backslash in
  # the command, a substitution in prose gets no exemption.
  if [ "${#scope_prose_subs[@]}" -gt 0 ] && [[ "${scope_scan_cmd:-}" == *\\* ]]; then
    return 1
  fi
  case "$reduced" in *'$('*|*"$backtick"*|*'('*'('*) return 1 ;; esac
  # The leading word must be literal text ended by whitespace, before any
  # slash, variable, or substituted value can join the first path component.
  # The one exception is a plain `$name` lead in echo/printf text (checked
  # below), optionally followed by a `:` or `,` label separator (`"$s: ..."`),
  # which prints the word and opens nothing.
  lead="${reduced%%[[:space:]]*}"
  [ -n "$lead" ] || return 1
  if [ "$whole_sub" -eq 0 ]; then
    case "$lead" in
      *'/'*|*'$'*|*"$mark"*|*'*'*|*'?'*|*'['*|*'{'*|*'~'*)
        [ "$context" != body ] && [[ "$lead" =~ ^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?[:,]?$ ]] || return 1
        lead_is_var=1
        ;;
    esac
  fi
  if [ "$context" != body ]; then
    case "$reduced" in
      *'$'*|*"$mark"*)
        local head_index
        head_index="$(scope_command_head_index)"
        head="${scope_tokens[$head_index]:-}"
        head="${head##*/}"
        case "$head" in echo|printf) ;; *) return 1 ;; esac
        [ "$index" -gt "$head_index" ] || return 1
        prev="${scope_tokens[$((index - 1))]:-}"
        [[ "$prev" =~ ^[0-9]*(\<|\>|\>\>|\<\<\<|\>\|)$|^\&\>\>?$ ]] && return 1
        # Printed text piped into a shell or interpreter is run, not shown.
        shell_pipe_re='\|[[:space:]]*(sudo[[:space:]]+|env[[:space:]]+|command[[:space:]]+|exec[[:space:]]+)*([^[:space:]|;&]*/)?(bash|sh|zsh|dash|ksh|fish|xargs|eval|source|python[0-9.]*|node|perl|ruby)([[:space:]]|$)'
        [[ "${scope_scan_cmd:-}" =~ $shell_pipe_re ]] && return 1
        ;;
    esac
  fi
  [ "$lead_is_var" -eq 0 ] || return 0
  cwd="${COMMAND_CWD:-$HQ_ROOT}"
  if ( cd "$cwd" 2>/dev/null && shopt -s dotglob && compgen -G "$lead"'[[:space:]]*' >/dev/null ); then
    return 1
  fi
  return 0
}

# Print the bodies of quoted-delimiter heredocs fed to an interpreter
# (python, node, ruby, perl). The outer shell expands nothing in them, so a
# prose word there is source text, not a shell operand. The bodies remain in
# the company and .claude scans; this only labels tokens for
# scope_token_is_prose.
scope_interpreter_heredoc_bodies() {
  local raw="${1:-}" line delimiter="" in_body=0 interp_re tail
  case "$raw" in *'<<'*) ;; *) return 0 ;; esac
  interp_re='(^|[[:space:];])(python|python[0-9.]*|node|ruby|perl)([[:space:]]|$)'
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_body" -eq 1 ]; then
      if [ "$line" = "$delimiter" ]; then
        in_body=0
      else
        printf '%s\n' "$line"
      fi
      continue
    fi
    [[ "$line" =~ $interp_re ]] || continue
    case "$line" in *'<<'*'<<'*) continue ;; esac
    tail="${line#*<<}"
    while [[ "$tail" == [[:space:]]* ]]; do tail="${tail:1}"; done
    case "$tail" in
      \'*) tail="${tail#\'}"; delimiter="${tail%%\'*}" ;;
      \"*) tail="${tail#\"}"; delimiter="${tail%%\"*}" ;;
      *) continue ;;
    esac
    case "$delimiter" in ""|*[!A-Za-z0-9._-]*) continue ;; esac
    in_body=1
  done <<< "$raw"
}

# Same parse as scope_interpreter_heredoc_bodies, recording where the bodies
# sit instead of printing them: scope_interp_ranges holds start/end character
# offsets (end exclusive) of each body line in <raw>, and scope_interp_outside
# holds every line that is not body text.
scope_interpreter_heredoc_layout() {
  local raw="${1:-}" line delimiter="" in_body=0 interp_re tail offset=0 len
  scope_interp_ranges=()
  scope_interp_outside=""
  case "$raw" in *'<<'*) ;; *) scope_interp_outside="$raw"; return 0 ;; esac
  interp_re='(^|[[:space:];])(python|python[0-9.]*|node|ruby|perl)([[:space:]]|$)'
  while IFS= read -r line || [ -n "$line" ]; do
    len=$(( ${#line} + 1 ))
    if [ "$in_body" -eq 1 ]; then
      if [ "$line" = "$delimiter" ]; then
        in_body=0
        scope_interp_outside+="$line"$'\n'
      else
        scope_interp_ranges[${#scope_interp_ranges[@]}]="$offset"
        scope_interp_ranges[${#scope_interp_ranges[@]}]="$((offset + ${#line}))"
      fi
      offset=$((offset + len))
      continue
    fi
    scope_interp_outside+="$line"$'\n'
    offset=$((offset + len))
    [[ "$line" =~ $interp_re ]] || continue
    case "$line" in *'<<'*'<<'*) continue ;; esac
    tail="${line#*<<}"
    while [[ "$tail" == [[:space:]]* ]]; do tail="${tail:1}"; done
    case "$tail" in
      \'*) tail="${tail#\'}"; delimiter="${tail%%\'*}" ;;
      \"*) tail="${tail#\"}"; delimiter="${tail%%\"*}" ;;
      *) continue ;;
    esac
    case "$delimiter" in ""|*[!A-Za-z0-9._-]*) continue ;; esac
    in_body=1
  done <<< "$raw"
}

# True when character offset <pos> of the scanned command lies on a body line
# of a quoted-delimiter interpreter heredoc.
scope_offset_in_interpreter_body() {
  local pos="${1:-0}" i
  for ((i = 0; i + 1 < ${#scope_interp_ranges[@]}; i += 2)); do
    if [ "$pos" -ge "${scope_interp_ranges[$i]}" ] && [ "$pos" -lt "${scope_interp_ranges[$((i + 1))]}" ]; then
      return 0
    fi
  done
  return 1
}

# True when the companies/ <fragment> found after <prefix> lies inside the
# quoted program of `python[N] -c` or `node -e`, and its literal text up to
# the program's closing quote has no `$`, backtick, backslash, or `..`. Sets
# scope_inline_program_path to the literal path: the fragment cut at the end
# of the program's own string literal (the other quote character), a comma,
# a closing bracket, or the first `{` of an f-string or template field. The
# cut path must name a company segment ended by `/`, so a field cannot be
# glued onto the company name (`companies/x{c}/`).
scope_fragment_in_inline_program() {
  local prefix="${1:-}" fragment="${2:-}" re rest match q="" other between="" pre="" whole path tail
  scope_inline_program_path=""
  re='(^|[;&|[:space:](])(python[0-9.]*|node)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[ce][[:space:]]*(["'"'"'])'
  rest="$prefix"
  while [[ "$rest" =~ $re ]]; do
    match="${BASH_REMATCH[0]}"
    q="${BASH_REMATCH[4]}"
    pre="${prefix:0:$(( ${#prefix} - ${#rest} ))}${rest%%"$match"*}"
    rest="${rest#*"$match"}"
    between="$rest"
  done
  [ -n "$q" ] || return 1
  case "$between" in *"$q"*) return 1 ;; esac
  scope_shell_prefix_is_unquoted "$pre" || return 1
  if [ "$q" = '"' ]; then other="'"; else other='"'; fi
  # No `..` anywhere in the program, so a field value spelled in it
  # (`m='../../otherco'`) cannot climb out of the literal company path.
  tail="${scope_scan_cmd:-}"
  tail="${tail:${#prefix}}"
  tail="${tail%%"$q"*}"
  case "$between$tail" in *'..'*) return 1 ;; esac
  whole="${fragment%%"$q"*}"
  case "$whole" in *'..'*|*'$'*|*$'\140'*|*\\*) return 1 ;; esac
  path="${whole%%["$other"\{,\]\}]*}"
  tail="${path#companies/}"
  [[ "$tail" == [A-Za-z0-9_]*/* ]] || return 1
  scope_inline_program_path="$path"
  return 0
}

scope_check_prose_substitutions() {
  local body record tok tok_prefix body_prefix
  local -a sub_tokens=()
  local stripped cd_re='(^|[;&|[:space:]])(cd|pushd|popd|CDPATH=)'
  for body in ${scope_prose_subs[@]+"${scope_prose_subs[@]}"}; do
    # The prose exemption only covers the outer text. A substitution body is
    # a command, and it gets no more latitude than the top-level scan:
    # escaping, braces, globs, a nested substitution, or a directory change
    # that could assemble or reach a tenant path fails closed here.
    # A curl write-out format of %{name} fields and plain text (`-w
    # '%{http_code}'`, no @file, no %output{...}) names no file, so its
    # braces do not count here; the rest of the body is checked as usual
    # (feedback aba2d75e).
    local check_body="$body" prose_wo_re
    prose_wo_re='(^|[[:space:]])(-w|--write-out)[[:space:]]+(['"'"'"]?)([A-Za-z0-9_%{}:.=,-]+)(['"'"'"]?)([[:space:]]|$)'
    case "$check_body" in
      curl\ *)
        if [[ "$check_body" =~ $prose_wo_re ]] && [ "${BASH_REMATCH[3]}" = "${BASH_REMATCH[5]}" ]; then
          case "${BASH_REMATCH[4]}" in
            *'@'*|*output*|*'%{'*'%{'*'%{'*'%{'*) ;;
            *) check_body="${check_body/"${BASH_REMATCH[0]}"/ }" ;;
          esac
        fi
        ;;
    esac
    case "$check_body" in
      *\\*|*'{'*|*'}'*|*'*'*|*'?'*|*'['*|*$'\140'*|*'$('*)
        scope_block_rel "\$($body)" "a command substitution inside text uses escaping, braces, globbing, or a nested substitution; run it as its own command with literal paths"
        ;;
    esac
    # Quotes only group words here (`grep -n 'start' f`). The tokenizer
    # removes them, and every resulting word is checked below, so a path
    # spliced from quoted pieces is checked as the path the program gets.
    # Unbalanced quoting means the body was cut at a quoted `)`.
    scope_shell_prefix_is_unquoted "$body" \
      || scope_block_rel "\$($body)" "a command substitution inside text has unbalanced quotes; run it as its own command with literal paths"
    [[ "$body" =~ $cd_re ]] && scope_block_rel "\$($body)" "a command substitution inside text changes directory; run it as its own command with literal paths"
    # With quotes removed and every plain `companies/` taken out, what is
    # left must not still spell `companies` in any case (`COMPANIES/x` on a
    # case-insensitive filesystem, `compan"ies"` already collapsed by the
    # strip above), nor `compan` cut short by a non-word character that a
    # later piece could complete. A longer word such as `company_slugs` or
    # `company-name` is an ordinary argument, not a tenant path.
    stripped="${body//[\"\']/}"
    stripped="${stripped//companies\//}"
    case "$stripped" in
      *[Cc][Oo][Mm][Pp][Aa][Nn][Ii][Ee][Ss]*|*[Cc][Oo][Mm][Pp][Aa][Nn][!A-Za-z0-9_]*|*[Cc][Oo][Mm][Pp][Aa][Nn])
        scope_block_rel "\$($body)" "a command substitution inside text names companies in a form the guard cannot resolve"
        ;;
    esac
    body_prefix=""
    if [[ "${scope_scan_cmd:-}" == *"\$($body)"* ]]; then
      body_prefix="${scope_scan_cmd%%"\$($body)"*}\$("
    else
      # The tokenizer drops quotes inside the substitution, so
      # `--summary "$(cat "$T")"` arrives as body `cat $T`, which is not in
      # the command text. Find the first `$(...)` (no nested parentheses)
      # whose text with quotes removed is the body, and take the text before
      # it, so an earlier `T=...;` can still be proven to have run first.
      local body_rest="${scope_scan_cmd:-}" body_seen="" body_inner
      while [[ "$body_rest" == *'$('* ]]; do
        body_seen+="${body_rest%%\$(*}\$("
        body_rest="${body_rest#*\$(}"
        body_inner="${body_rest%%)*}"
        [[ "$body_rest" == *')'* ]] || break
        case "$body_inner" in *'('*) continue ;; esac
        if [ "${body_inner//[\"\']/}" = "$body" ]; then
          body_prefix="$body_seen"
          break
        fi
      done
    fi
    while IFS= read -r record; do
      [ -n "$record" ] || continue
      IFS=$'\037' read -r -a sub_tokens <<< "$record"
      for tok in "${sub_tokens[@]}"; do
        case "$tok" in
          companies/*) scope_check_bash_candidate "$tok" "$body" "" "" ;;
          *'$'*)
            # A variable is accepted only where the rest of the command
            # proves its value (an earlier `D=workspace/x;`, a literal
            # `for c in a b` list). The value is substituted and checked as a
            # path; an unproven variable fails closed, slash or not, because
            # `cat $D` opens whatever D names.
            case "$tok" in
              */*) scope_check_bash_skill_path "$tok" "${scope_scan_cmd:-$body}" "" "" ;;
              *)
                [ -n "$body_prefix" ] && [[ "$body" == *"$tok"* ]] \
                  || scope_block_rel "\$($body)" "a variable inside a command substitution cannot be resolved; run it as its own command with literal paths"
                tok_prefix="$body_prefix${body%%"$tok"*}"
                # `T=$(mktemp); ...; --summary "$(cat "$T")"`: a variable set
                # once from mktemp, before this use, names a fresh temp entry.
                # Check that temp path like a literal one (as an operand with
                # a slash already is, via scope_resolve_known_path_expansions).
                local mk_name="${tok#\$}" mk_value mk_re
                mk_name="${mk_name#\{}"
                mk_name="${mk_name%\}}"
                mk_re='(^|[;&|[:space:]])'"$mk_name"'="?\$\(mktemp'
                if [[ "$mk_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
                  && { [ "$tok" = "\$$mk_name" ] || [ "$tok" = "\${$mk_name}" ]; } \
                  && [[ "$tok_prefix" =~ $mk_re ]] \
                  && mk_value="$(scope_mktemp_assignment_value "$mk_name" "$scope_scan_cmd")"; then
                  scope_check_raw "$mk_value"
                  continue
                fi
                scope_check_bash_candidate_inner "$tok" "$scope_scan_cmd" 0 "" "$tok_prefix" ""
                ;;
            esac
            ;;
          */*|/*|.claude*) scope_check_bash_skill_path "$tok" "$body" "" "" ;;
        esac
      done
    done <<< "$(hq_shell_simple_commands "$body")"
  done
}

# Print the bodies of quoted-delimiter python or node heredocs that cannot
# hand text to a shell: no system/popen/subprocess/spawn/exec/child_process,
# and none of the reflection or dynamic-import names that can reach them.
# In such a body a `$` or backtick is source text that nothing expands, so a
# word like `$30k/mo` or `${x}/bar` names no path. Bodies of any other
# interpreter, or with any of those names, are not printed and keep the
# fail-closed variable checks.
#
# scope_interp_handoff_re is shared with the inline-program check
# (scope_inline_expansions_check_word), so a `python3 -c` program and a
# python heredoc agree on what can reach a shell.
#
# With <allow_fs_require> set to 1, a node `require('<module>')` of a core
# module that cannot start a process or run code (fs, path, util and the
# like, with or without `node:`) is removed before that check. Such a body
# cannot reach a shell but can still write files, so the caller keeps
# checking an expansion that sits next to a `/` (feedback 5e84d816).
# child_process, vm, worker_threads, a relative or package module, and a
# require of anything but a quoted literal still count as a hand-off.
scope_interp_handoff_re='system|popen|Popen|subprocess|spawn|exec|shell|Shell|child_|process\.binding|process\.dlopen|pty\.|commands|getoutput|__import__|__builtins__|__dict__|__class__|__globals__|__subclasses__|getattr|attrgetter|methodcaller|globals\(|vars\(|eval|importlib|import\(|pickle|marshal|ctypes|cffi|Function\(|require\(|fork'
scope_interp_safe_require_re="require\\([[:space:]]*(['\"])(node:)?(fs|fs/promises|path|util|crypto|url|assert|zlib|events|stream|buffer|querystring|string_decoder|os|readline|timers)['\"][[:space:]]*\\)"
scope_text_only_interpreter_bodies() {
  local raw="${1:-}" allow_fs_require="${2:-0}" line delimiter="" in_body=0 interp_re tail body="" keep=0 scope_scan_body
  local safe_require_re="$scope_interp_safe_require_re"
  local handoff_re="$scope_interp_handoff_re"
  case "$raw" in *'<<'*) ;; *) return 0 ;; esac
  interp_re='(^|[[:space:];])(python|python[0-9.]*|node)([[:space:]]|$)'
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_body" -eq 1 ]; then
      if [ "$line" = "$delimiter" ]; then
        in_body=0
        scope_scan_body="$body"
        while [ "$allow_fs_require" = 1 ] && [[ "$scope_scan_body" =~ $safe_require_re ]]; do
          scope_scan_body="${scope_scan_body/"${BASH_REMATCH[0]}"/ }"
        done
        if [ "$keep" -eq 1 ] && ! [[ "$scope_scan_body" =~ $handoff_re ]]; then
          printf '%s' "$body"
        fi
        body=""
      else
        body+="$line"$'\n'
      fi
      continue
    fi
    keep=0
    case "$line" in *'<<'*'<<'*) continue ;; esac
    [[ "$line" =~ $interp_re ]] || continue
    tail="${line#*<<}"
    while [[ "$tail" == [[:space:]]* ]]; do tail="${tail:1}"; done
    case "$tail" in
      \'*) tail="${tail#\'}"; delimiter="${tail%%\'*}" ;;
      \"*) tail="${tail#\"}"; delimiter="${tail%%\"*}" ;;
      *) continue ;;
    esac
    case "$delimiter" in ""|*[!A-Za-z0-9._-]*) continue ;; esac
    in_body=1
    keep=1
  done <<< "$raw"
}

# True when token <end> is the value of `--arg NAME` or `--argjson NAME` for
# the jq command whose head is at <head_index>. Options that take values are
# skipped with them; --args/--jsonargs (every later word is a value) and a
# short cluster with -f or -L fail.
scope_jq_arg_value_position() {
  local j=$(( ${1:-0} + 1 )) end="${2:-0}" w re='^[A-Za-z_][A-Za-z0-9_]*$'
  while [ "$j" -lt "$end" ]; do
    w="${scope_tokens[$j]:-}"
    case "$w" in
      --arg|--argjson)
        if [ $((j + 2)) -eq "$end" ]; then
          [[ "${scope_tokens[$((j + 1))]:-}" =~ $re ]] && return 0
          return 1
        fi
        j=$((j + 3))
        ;;
      --rawfile|--slurpfile) j=$((j + 3)) ;;
      -f|--from-file|-L|--indent) j=$((j + 2)) ;;
      --args|--jsonargs) return 1 ;;
      --*) j=$((j + 1)) ;;
      -*[fL]*) return 1 ;;
      *) j=$((j + 1)) ;;
    esac
  done
  return 1
}

# True when token <index> of scope_tokens is exactly `$(BODY)` (or
# `--opt=$(BODY)`) given as the value of an option that carries data, not a
# path, for a client that sends it (curl, wget, xh/http, gh, hq):
# `hq ... --json "$(cat workspace/x.json)"`, `curl -d "$(cat $D/q.gql)"`. BODY
# must be one plain reader (cat, head, tail, jq) with no pipe, redirect, or
# nested substitution; its operands are returned in scope_prose_subs and
# checked as commands by scope_check_prose_substitutions, so a reader of
# another company's file, or of an unproven variable, still fails closed. A
# substitution in a path position (`cat "$(cat p)"`, `cp a "$(...)"`) is not
# covered and stays refused.
scope_token_is_data_option_substitution() {
  local index="${1:-0}" token prev body opt reader record count=0 head head_index
  scope_prose_subs=()
  [ "$index" -gt 0 ] || return 1
  token="${scope_tokens[$index]:-}"
  prev="${scope_tokens[$((index - 1))]:-}"
  case "$token" in
    '$('*')') opt="$prev"; body="${token#\$(}" ;;
    --*'=$('*')') opt="${token%%=*}"; body="${token#*=\$(}" ;;
    *) return 1 ;;
  esac
  body="${body%)}"
  # Only clients that send the value somewhere: `-d` is a directory for
  # mktemp and unzip, so the option alone does not make the value data.
  head_index="$(scope_command_head_index)"
  head="${scope_tokens[$head_index]:-}"
  # `bash core/scripts/handoff-finalize.sh ...` runs the same script.
  case "$head" in
    bash|sh) case "${scope_tokens[$((head_index + 1))]:-}" in */handoff-finalize.sh|handoff-finalize.sh) head_index=$((head_index + 1)); head="${scope_tokens[$head_index]}" ;; esac ;;
  esac
  head="${head##*/}"
  # `jq --arg NAME "$(cat f)"`: the value follows the variable name. The
  # words before it are walked from the head, so `--rawfile --arg "$(...)"`
  # (where --arg is a variable name and the value is a file) does not count.
  if [ "$head" = jq ]; then
    [ "$opt" = "$prev" ] && scope_jq_arg_value_position "$head_index" "$index" || return 1
    opt=--arg
  fi
  # `hq dm [send] <recipient> <message>` / `hq dm --channel <name> <message>`:
  # the message positional is text the CLI sends, not a path it opens. The
  # recipient (or --channel) must come first, and the token must not be the
  # value of one of the send options that take a value (--prompt-file and
  # --details-file name files and are never message text).
  if [ "$head" = hq ] && [ "$opt" = "$prev" ] \
    && [ "${scope_tokens[$((head_index + 1))]:-}" = dm ]; then
    local dm_j=$((head_index + 2)) dm_positional=0 dm_channel=0
    [ "${scope_tokens[$dm_j]:-}" = send ] && dm_j=$((dm_j + 1))
    case "${scope_tokens[$dm_j]:-}" in
      forward|inbox|thread|read|channel|history|requests|accept|decline|block|help) dm_j="$index" ;;
    esac
    while [ "$dm_j" -lt "$index" ]; do
      case "${scope_tokens[$dm_j]}" in
        --channel) dm_channel=1; dm_j=$((dm_j + 1)) ;;
        --thread|--prompt|--prompt-file|--details|--details-file|--at|--in|--audience) dm_j=$((dm_j + 1)) ;;
        -*) ;;
        *) dm_positional=$((dm_positional + 1)) ;;
      esac
      dm_j=$((dm_j + 1))
    done
    # dm_j == index means the token is not the value of an option above.
    if [ "$dm_j" -eq "$index" ] \
      && { [ "$dm_positional" -ge 1 ] || [ "$dm_channel" -eq 1 ]; }; then
      opt=--message
    fi
  fi
  # `hq agents message <agent> <message...>`: every positional after the
  # agent is message text the CLI sends, not a path it opens.
  if [ "$head" = hq ] && [ "$opt" = "$prev" ] \
    && [ "${scope_tokens[$((head_index + 1))]:-}" = agents ]; then
    case "${scope_tokens[$((head_index + 2))]:-}" in
      message|msg)
        local j=$((head_index + 3)) positional=0
        while [ "$j" -lt "$index" ]; do
          case "${scope_tokens[$j]}" in
            --company|--timeout) j=$((j + 1)) ;;
            -*) ;;
            *) positional=$((positional + 1)) ;;
          esac
          j=$((j + 1))
        done
        # j == index means the token is not the value of --company/--timeout.
        [ "$j" -eq "$index" ] && [ "$positional" -ge 1 ] && opt=--message
        ;;
    esac
  fi
  # `git commit -m "$(cat /tmp/msg.txt)"`: for the subcommands whose -m takes
  # a message, the value is text git stores, not a path. Other subcommands
  # (`git checkout -m`) use -m as a flag, so the next word is a pathspec.
  if [ "$head" = git ]; then
    local git_j=$((head_index + 1)) git_sub=""
    while [ "$git_j" -lt "$index" ]; do
      case "${scope_tokens[$git_j]}" in
        -C|-c|--git-dir|--work-tree|--namespace) git_j=$((git_j + 2)) ;;
        -*) git_j=$((git_j + 1)) ;;
        *) git_sub="${scope_tokens[$git_j]}"; break ;;
      esac
    done
    case "$git_sub:$opt" in
      commit:-m|commit:--message|merge:-m|merge:--message|tag:-m|tag:--message|notes:-m|notes:--message|stash:-m|stash:--message) opt=--message ;;
      *) return 1 ;;
    esac
  fi
  case "$head:$opt" in
    git:--message) ;;
    handoff-finalize.sh:--title|handoff-finalize.sh:--summary|handoff-finalize.sh:--message) ;;
    handoff-finalize.sh:--learnings-json|handoff-finalize.sh:--next-steps-json|handoff-finalize.sh:--tags-json) ;;
    curl:-d|curl:--data|curl:--data-raw|curl:--data-binary|curl:--data-ascii|curl:--json) ;;
    wget:--post-data|wget:--body-data) ;;
    # A database client's inline statement text (`psql -c "$(cat q.sql)"`,
    # `mysql -e "$(...)"`); -f/--file stay paths (feedback fb3a9d72).
    psql:-c|psql:--command|mysql:-e|mysql:--execute|mariadb:-e|mariadb:--execute) ;;
    xh:--raw|http:--raw|https:--raw) ;;
    gh:--body|gh:--title|gh:--raw-field) ;;
    hq:--json|hq:--body|hq:--text|hq:--message|hq:--params|hq:--payload|hq:--summary|hq:--title|hq:--description|hq:--note) ;;
    hq:--args) ;;
    jq:--arg) ;;
    *) return 1 ;;
  esac
  # `--args "$(cat <<'EOF' ... EOF)"`: scope_strip_inert_heredoc_bodies
  # removed the quoted body, which is literal text, so only the reader is
  # left. An unquoted or unstripped body keeps its text here and fails below.
  local heredoc_reader_re="^cat[[:space:]]+<<-?[[:space:]]*'[A-Za-z0-9._-]+'[[:space:]]*\$"
  # Only hq, gh, and jq get the stripped form (scope_heredoc_data_client_line).
  # For hq and gh the option must not be the value of an earlier option.
  if [[ "$body" =~ $heredoc_reader_re ]]; then
    scope_prose_subs=()
    case "$head" in
      hq|gh)
        if [ "$opt" = "$prev" ]; then
          case "${scope_tokens[$((index - 2))]:-}" in -*) return 1 ;; esac
        else
          case "$prev" in -*) return 1 ;; esac
        fi
        return 0
        ;;
      jq) return 0 ;;
    esac
    return 1
  fi
  # `--body "$(printf 'Fixes x\n\nSee a/b')"`: a printf whose words are all
  # single-quoted literals prints only that text and opens nothing. The
  # tokenizer may drop backslashes inside the substitution, so prove the
  # shape on the raw command: every `$(printf` in it must be such a
  # literal-only substitution, and this token must be one of them.
  if [ "${body%%[[:space:]]*}" = printf ]; then
    local printf_re printf_rest printf_total=0 printf_literal=0 printf_found=0 printf_inner
    printf_re="\\\$\\(printf([[:space:]]+'[^']*')+[[:space:]]*\\)"
    printf_rest="${scope_scan_cmd:-}"
    while [[ "$printf_rest" == *'$(printf'* ]]; do
      printf_total=$((printf_total + 1))
      printf_rest="${printf_rest#*\$(printf}"
    done
    printf_rest="${scope_scan_cmd:-}"
    while [[ "$printf_rest" =~ $printf_re ]]; do
      printf_literal=$((printf_literal + 1))
      printf_inner="${BASH_REMATCH[0]#\$(}"
      printf_inner="${printf_inner%)}"
      [ "$printf_inner" = "$body" ] && printf_found=1
      printf_inner="${printf_inner//\\/}"
      [ "$printf_inner" = "$body" ] && printf_found=1
      printf_rest="${printf_rest#*"${BASH_REMATCH[0]}"}"
    done
    [ "$printf_total" -gt 0 ] && [ "$printf_total" -eq "$printf_literal" ] && [ "$printf_found" -eq 1 ] || return 1
    scope_prose_subs=()
    return 0
  fi
  case "$body" in *'('*|*')'*|*$'\140'*|*'|'*|*'<'*|*'>'*|*';'*|*'&'*|*$'\n'*) return 1 ;; esac
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    count=$((count + 1))
    reader="${record%%$'\037'*}"
  done <<< "$(hq_shell_simple_commands "$body")"
  [ "$count" -eq 1 ] || return 1
  case "${reader##*/}" in cat|head|tail|jq) ;; *) return 1 ;; esac
  scope_prose_subs=("$body")
  return 0
}

# A pipeline whose output is only line numbers or counts: `grep -n PAT [FILE]
# | cut -d: -f1`, or anything ending in `wc -l` reading stdin, with optional
# `head`/`tail -n N` stages. Such output cannot carry a sed command or a path.
scope_substitution_prints_numbers() {
  local body="${1:-}" record stage=0 last="" tok i operands saw_n saw_c=0 saw_cut=0
  local -a words=()
  case "$body" in *';'*|*'&'*|*$'\n'*|*'>'*) return 1 ;; esac
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    stage=$((stage + 1))
    IFS=$'\037' read -r -a words <<< "$record"
    case "${words[0]}" in
      grep)
        [ "$stage" -eq 1 ] || return 1
        saw_n=0; saw_c=0; operands=0; i=1
        while [ "$i" -lt "${#words[@]}" ]; do
          tok="${words[$i]}"
          case "$tok" in
            --line-number) saw_n=1 ;;
            --count) saw_c=1 ;;
            -e) i=$((i + 1)); operands=$((operands + 1)) ;;
            --) ;;
            -*)
              case "$tok" in -*[!nEiFwxvPc]*) return 1 ;; esac
              case "$tok" in *n*) saw_n=1 ;; esac
              case "$tok" in *c*) saw_c=1 ;; esac
              ;;
            *) operands=$((operands + 1)) ;;
          esac
          i=$((i + 1))
        done
        # Pattern plus at most one file: with two files grep prefixes names.
        [ "$operands" -ge 1 ] && [ "$operands" -le 2 ] || return 1
        if [ "$saw_c" -eq 1 ]; then
          # `grep -c PAT [FILE]` prints one count (-c overrides -n).
          last="count"
        else
          [ "$saw_n" -eq 1 ] || return 1
          last="grep"
        fi
        ;;
      cut)
        [ "$last" = grep ] || return 1
        case "${words[*]:1}" in
          '-d: -f1'|'-d : -f1'|'-d: -f 1'|'-d : -f 1'|'-f1 -d:'|'-f 1 -d :'|'-f1 -d :') ;;
          *) return 1 ;;
        esac
        saw_cut=1
        last="cut"
        ;;
      head|tail)
        [ "$stage" -gt 1 ] || return 1
        case "${words[*]:1}" in
          ''|-[0-9]*|'-n '[0-9]*|-n[0-9]*) ;;
          *) return 1 ;;
        esac
        case "${words[*]:1}" in *[!0-9n\ -]*) return 1 ;; esac
        ;;
      wc)
        # `wc -l` on stdin (a pipe or `< file`) prints only the count.
        case "${words[*]:1}" in
          -l) ;;
          '-l < '*) [ "${#words[@]}" -eq 4 ] || return 1 ;;
          *) return 1 ;;
        esac
        last="wc"
        ;;
      *) [ "$stage" -eq 1 ] || return 1; last=other ;;
    esac
  done <<< "$(hq_shell_simple_commands "$body")"
  # Only head/tail may follow the final cut, wc, or grep -c.
  [ "$last" = wc ] || [ "$last" = count ] || { [ "$last" = cut ] && [ "$saw_cut" -eq 1 ]; }
}

# True when token <index> is the script operand of sed (the first non-option
# word, or the value of -e/--expression) and every `$(...)` in it prints
# only digits (scope_substitution_prints_numbers) or a slash-free date
# (scope_date_substitution_value). The script must be an address range with
# p/d (`$(...),$p`, `$(...),+40p`) or one s command whose delimiter the
# substituted text cannot contain and whose flags are among g p i I and
# digits (no w file, no e). A literal `$` (a last-line address) must be
# written `\$` in the command, so no shell variable is spliced into the
# script. The substitution bodies are returned in scope_prose_subs and
# checked as commands; the file operands are checked as usual.
# A plain `$NAME` / `${NAME}` in the script (`sed "s|/old/$u|/new/$l|"`,
# `sed -n "${s},+5p"`) is text sed matches or prints, not a path the shell
# opens (feedback cbbd0e33, 2ec4335f, bcf948ff). It is accepted when no
# assignment of NAME in the command can carry the script delimiter, a
# newline or a backslash (which could end the s command early and add a
# `w FILE` command), and no builtin binds NAME from input. A name that holds
# a command substitution's output is still refused by the substitution scan.
scope_sed_var_is_text() {
  local name="${1:-}" delim="${2:-}" cmd="${scope_scan_cmd:-}" assign_re value bind_re loop_re bound=0 word
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  bind_re='(^|[^A-Za-z0-9_.-])(read|mapfile|readarray|getopts|eval|printf[[:space:]]+-v)([[:space:]]|$)'
  [[ "$cmd" =~ $bind_re ]] && return 1
  # The command itself must give the name a value: an assignment or a `for`
  # list of plain words. An unset name expands to nothing, which turns the
  # script into something else (`$p` meant as the last-line address), and a
  # name from the environment is not visible here; both stay refused as
  # before.
  assign_re='(^|[;&|({[:space:]]|'$'\n'')(export[[:space:]]+|local[[:space:]]+|declare[[:space:]]+)?'"$name"'\+?=("[^"]*"|'"'[^']*'"'|[^;&|[:space:]]*)'
  while [[ "$cmd" =~ $assign_re ]]; do
    value="${BASH_REMATCH[3]}"
    cmd="${cmd#*"${BASH_REMATCH[0]}"}"
    case "$value" in *$'\n'*|*\\*|*$'\140'*|*'$('*) return 1 ;; esac
    [ -n "$delim" ] && case "$value" in *"$delim"*) return 1 ;; esac
    bound=1
  done
  loop_re='(^|[;&|({[:space:]]|'$'\n'')for[[:space:]]+'"$name"'[[:space:]]+in[[:space:]]+([^;'$'\n'']+)(;|'$'\n'')'
  cmd="${scope_scan_cmd:-}"
  while [[ "$cmd" =~ $loop_re ]]; do
    cmd="${cmd#*"${BASH_REMATCH[0]}"}"
    for word in ${BASH_REMATCH[2]}; do
      case "$word" in *[!A-Za-z0-9._/@:+=-]*) return 1 ;; esac
      [ -n "$delim" ] && case "$word" in *"$delim"*) return 1 ;; esac
    done
    bound=1
  done
  [ "$bound" -eq 1 ]
}

scope_token_is_sed_script() {
  local index="${1:-0}" token head i tok script_at=-1 saw_script_opt=0 reduced sub_re body escaped whole
  local mark=$'\001' delim rest addr_re var_re var_name
  local -a var_names=()
  scope_prose_subs=()
  [ "$index" -gt 0 ] || return 1
  token="${scope_tokens[$index]:-}"
  var_re='\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?'
  case "$token" in *'$('*) ;; *) [[ "$token" =~ $var_re ]] || return 1 ;; esac
  case "$token" in *$'\140'*|*"$mark"*|*$'\n'*) return 1 ;; esac
  i="$(scope_command_head_index)"
  head="${scope_tokens[$i]:-}"
  head="${head##*/}"
  case "$head" in sed|gsed) ;; *) return 1 ;; esac
  i=$((i + 1))
  while [ "$i" -lt "${#scope_tokens[@]}" ]; do
    tok="${scope_tokens[$i]}"
    case "$tok" in
      -e|--expression)
        saw_script_opt=1
        [ "$((i + 1))" -eq "$index" ] && script_at="$index"
        i=$((i + 2)); continue ;;
      -f|--file) saw_script_opt=1; i=$((i + 2)); continue ;;
      -l|--line-length) i=$((i + 2)); continue ;;
      --) i=$((i + 1)); break ;;
      -*) i=$((i + 1)); continue ;;
    esac
    break
  done
  if [ "$saw_script_opt" -eq 0 ] && [ "$i" -eq "$index" ]; then
    script_at="$index"
  fi
  [ "$script_at" -eq "$index" ] || return 1
  # Every $(...) must be a plain, non-nested substitution.
  reduced="$token"
  sub_re='\$\(([^()]*)\)'
  while [[ "$reduced" =~ $sub_re ]]; do
    body="${BASH_REMATCH[1]}"
    # The checks below run their own regex matches; keep this one.
    whole="${BASH_REMATCH[0]}"
    if ! scope_date_substitution_value "\$($body)" >/dev/null \
      && ! scope_substitution_prints_numbers "$body"; then
      return 1
    fi
    scope_prose_subs[${#scope_prose_subs[@]}]="$body"
    reduced="${reduced/"$whole"/$mark}"
    [ "${#scope_prose_subs[@]}" -le 4 ] || return 1
  done
  case "$reduced" in *'$('*|*'('*|*')'*) return 1 ;; esac
  # Plain variables are text in the script; each one is checked against the
  # delimiter once that is known (scope_sed_var_is_text). An occurrence the
  # command spells `\$NAME` (`",\$p"`, the last-line address) is a literal
  # dollar, left in place for the escape check below.
  local var_rest="$reduced" var_out="" var_match
  while [[ "$var_rest" =~ $var_re ]]; do
    var_match="${BASH_REMATCH[0]}"
    var_out+="${var_rest%%"$var_match"*}"
    var_rest="${var_rest#*"$var_match"}"
    if scope_text_piece_is_escaped "$var_match"; then
      var_out+="$var_match"
    else
      var_names[${#var_names[@]}]="${BASH_REMATCH[1]}"
      var_out+="$mark"
      [ "${#var_names[@]}" -le 8 ] || return 1
    fi
  done
  reduced="$var_out$var_rest"
  # A literal `$` must be backslash-escaped inside the double-quoted word,
  # and that exact word must occur once.
  escaped="$token"
  if [[ "$reduced" == *'$'* ]]; then
    local piece out="" restw="$token"
    while [ -n "$restw" ]; do
      if [[ "$restw" =~ ^\$\(([^()]*)\) ]]; then
        out+="${BASH_REMATCH[0]}"
        restw="${restw:${#BASH_REMATCH[0]}}"
        continue
      fi
      if [[ "$restw" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}? ]] \
        && [[ " ${var_names[*]+"${var_names[*]}"} " == *" ${BASH_REMATCH[1]} "* ]]; then
        out+="${BASH_REMATCH[0]}"
        restw="${restw:${#BASH_REMATCH[0]}}"
        continue
      fi
      piece="${restw:0:1}"
      [ "$piece" = '$' ] && piece='\$'
      out+="$piece"
      restw="${restw:1}"
    done
    escaped="$out"
    [[ "${scope_scan_cmd:-}" == *"\"$escaped\""* ]] || return 1
    rest="${scope_scan_cmd#*"\"$escaped\""}"
    [[ "$rest" != *"\"$escaped\""* ]] || return 1
  fi
  # Address range with p, d or nothing. A substitution here prints a number,
  # so test the shape with a digit in its place (bash 3.2 uses \001
  # internally and cannot match it in a regex).
  addr_re='^([0-9]+|\$)(,([0-9]+|\$|\+[0-9]+|~[0-9]+))?[pd]?$'
  if [[ "${reduced//"$mark"/0}" =~ $addr_re ]]; then
    for var_name in ${var_names[@]+"${var_names[@]}"}; do
      scope_sed_var_is_text "$var_name" "" || return 1
    done
    return 0
  fi
  # One s command.
  [ "${reduced:0:1}" = s ] || return 1
  delim="${reduced:1:1}"
  case "$delim" in /|'|'|'#'|'@'|',') ;; *) return 1 ;; esac
  for var_name in ${var_names[@]+"${var_names[@]}"}; do
    scope_sed_var_is_text "$var_name" "$delim" || return 1
  done
  rest="${reduced:2}"
  [[ "$rest" == *"$delim"*"$delim"* ]] || return 1
  rest="${rest#*"$delim"}"
  rest="${rest#*"$delim"}"
  case "$rest" in *"$delim"*) return 1 ;; esac
  case "$rest" in *[!gpiI0-9]*) return 1 ;; esac
  # No literal `$` outside the substitutions in an s command.
  case "$reduced" in *'$'*) return 1 ;; esac
  return 0
}

# True when token <index> is the value of a text option (`--text`,
# `--summary`, `--title`, `--body`, `--message`, ...; `-m` for git) and holds
# whitespace: message text the program stores or sends, not a path it
# opens. Each whitespace-separated piece that looks like a path is still
# checked: a literal one as a path, one with a `$` variable only if the
# command proves its value, and one with a `$(...)` result next to a `/`
# fails closed. `$(...)` bodies are returned in scope_prose_subs.
# True when <piece> occurs in the scanned command only with every `$`
# written as `\$` (inside double quotes that is a literal dollar sign).
scope_text_piece_is_escaped() {
  local piece="${1:-}" escaped rest
  case "$piece" in *'$'*) ;; *) return 1 ;; esac
  case "$piece" in *\\*) return 1 ;; esac
  escaped="${piece//\$/\\\$}"
  [[ "${scope_scan_cmd:-}" == *"$escaped"* ]] || return 1
  rest="${scope_scan_cmd//"$escaped"/}"
  [[ "$rest" != *"$piece"* ]]
}

# An API endpoint is remote data. File flags and shell substitutions still go
# through the normal checks, including redirects following the endpoint.
scope_token_is_gh_api_endpoint() {
  local index="$1" h token
  h="$(scope_command_head_index)"
  [ "${scope_tokens[$h]:-}" = gh ] || return 1
  [ "${scope_tokens[$((h + 1))]:-}" = api ] || return 1
  [ "$index" -eq "$((h + 2))" ] || return 1
  token="${scope_tokens[$index]}"
  case "$token" in -*|*'$('*|*$'\140'*|*'<'*|*'>'*) return 1 ;; esac
  return 0
}

# Bound a filename selected by ls without executing the user's substitution.
# Check every possible entry, not only the current first/last entry. Arbitrary
# cat output cannot be bounded this way and remains fail-closed.
scope_token_is_bounded_loop_read() {
  local index="$1" h token re name inner prefix values dir entry count=0
  h="$(scope_command_head_index)"
  case "${scope_tokens[$h]:-}" in head|tail|cat) ;; *) return 1 ;; esac
  [ "$index" -gt "$h" ] || return 1
  token="${scope_tokens[$index]}"
  re='^\$([A-Za-z_][A-Za-z0-9_]*)/\$\(ls[[:space:]]+\$([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\|[[:space:]]*(head|tail)[[:space:]]+-[0-9]+\)$'
  case "${scope_tokens[$((index - 1))]:-}" in *'>'*|*'<'*) return 1 ;; esac
  [[ "$token" =~ $re ]] || return 1
  name="${BASH_REMATCH[1]}"; inner="${BASH_REMATCH[2]}"
  [ "$name" = "$inner" ] || return 1
  [[ "$scope_scan_cmd" == *"$token"* ]] || return 1
  prefix="${scope_scan_cmd%%"$token"*}"
  values="$(scope_shell_variable_values "$name" "$prefix" "$scope_scan_cmd")" || return 1
  while IFS= read -r dir; do
    [ -n "$dir" ] || return 1
    scope_check_raw "$dir"
    case "$dir" in /*) ;; *) dir="$COMMAND_CWD/$dir" ;; esac
    [ -d "$dir" ] || return 1
    while IFS= read -r entry; do
      case "$entry" in ''|*[!A-Za-z0-9._@+-]*|.|..) return 1 ;; esac
      count=$((count + 1)); [ "$count" -le 2048 ] || return 1
      scope_check_raw "$dir/$entry"
    done < <(cd "$dir" && compgen -G '*' || true)
  done <<< "$values"
  [ "$count" -gt 0 ]
}

# True when token <index> of scope_tokens is exactly `$(BODY)`, written
# double-quoted in the command, and is one side of a string or integer
# comparison in `test`, `[`, or `[[` (`test "$(git -C r branch
# --show-current)" = main`, `[ -z "$(...)" ]`). test compares the word and
# opens nothing, and the double quotes keep the output one word, so no
# operator or file test can be spliced in from it. BODY must be one simple
# command (no pipe, redirect, nested substitution, or backtick); it is
# returned in scope_prose_subs and checked as a command by
# scope_check_prose_substitutions, so a reader of another company's file or
# an unproven variable inside it still fails closed. A substitution next to
# a file test (`[ -f "$(...)" ]`, `-nt`, `-ef`) is not covered.
scope_token_is_test_string_operand() {
  local index="${1:-0}" token prev next head head_index body
  scope_prose_subs=()
  [ "$index" -gt 0 ] || return 1
  token="${scope_tokens[$index]:-}"
  case "$token" in '$('*')') ;; *) return 1 ;; esac
  body="${token#\$(}"
  body="${body%)}"
  case "$body" in ''|*'('*|*')'*|*$'\140'*|*'|'*|*'<'*|*'>'*|*';'*|*'&'*|*$'\n'*) return 1 ;; esac
  head_index="$(scope_command_head_index)"
  # `if [ ... ]`, `while test ...`: the splitter keeps the keyword in the
  # record, and the test command is the next word.
  case "${scope_tokens[$head_index]:-}" in if|elif|while|until) head_index=$((head_index + 1)) ;; esac
  head="${scope_tokens[$head_index]:-}"
  case "$head" in test|'['|'[[') ;; *) return 1 ;; esac
  [ "$index" -gt "$head_index" ] || return 1
  prev="${scope_tokens[$((index - 1))]:-}"
  next="${scope_tokens[$((index + 1))]:-}"
  case "$prev" in
    -n|-z|=|==|!=|-eq|-ne|-lt|-le|-gt|-ge) ;;
    *)
      case "$next" in =|==|!=|-eq|-ne|-lt|-le|-gt|-ge) ;; *) return 1 ;; esac
      ;;
  esac
  # The tokenizer removes the quotes; the raw command must carry this exact
  # substitution double-quoted, once, so the shell hands test one word.
  [[ "${scope_scan_cmd:-}" == *"\"\$($body)\""* ]] || return 1
  [[ "${scope_scan_cmd:-}" != *\\* ]] || return 1
  scope_prose_subs=("$body")
  return 0
}

# curl -w/--write-out interpolates a format string onto stdout. That value
# is not a filesystem path unless it starts with @ (curl then reads a file).
# feedback_07a4fda9: `curl -w "== /$p code=%{http_code}"` failed closed
# because /$p looked like an unresolved path.
scope_token_is_curl_write_out_format() {
  local index="${1:-0}" token prev="" opt head head_index reduced sub_re mark=$'\001'
  scope_prose_subs=()
  [ "$index" -ge 0 ] || return 1
  token="${scope_tokens[$index]:-}"
  [ "$index" -gt 0 ] && prev="${scope_tokens[$((index - 1))]:-}"
  # An empty or past-the-end head index must not trip set -u. resumework
  # bash blocks and assignment-only / bare-loop records hit this.
  head_index="$(scope_command_head_index)"
  case "$head_index" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$head_index" -lt "${#scope_tokens[@]}" ] || return 1
  head="${scope_tokens[$head_index]:-}"
  head="${head##*/}"
  [ "$head" = curl ] || return 1
  case "$token" in
    --write-out=*)
      opt=--write-out
      token="${token#--write-out=}"
      ;;
    -w)
      return 1
      ;;
    -w*)
      if [ "$prev" = -w ] || [ "$prev" = --write-out ]; then
        opt="$prev"
      else
        opt=-w
        token="${token#-w}"
      fi
      ;;
    *)
      case "$prev" in
        -w|--write-out) opt="$prev" ;;
        *) return 1 ;;
      esac
      ;;
  esac
  case "$opt" in -w|--write-out) ;; *) return 1 ;; esac
  case "$token" in @*) return 1 ;; esac
  reduced="$token"
  sub_re='\$\(([^()]*)\)'
  while [[ "$reduced" =~ $sub_re ]]; do
    scope_prose_subs[${#scope_prose_subs[@]}]="${BASH_REMATCH[1]}"
    reduced="${reduced/"${BASH_REMATCH[0]}"/$mark}"
    [ "${#scope_prose_subs[@]}" -le 16 ] || return 1
  done
  # curl's %output{FILE} / %output{>>FILE} directive writes the rest of the
  # format to FILE, so a format holding it is a file write, not stdout text.
  # Refuse it outright (PR 1544 review): a variable inside FILE expands at
  # run time and could land in another company. Variables, substitutions,
  # quotes and backslashes are removed first so they cannot split the name.
  if scope_curl_write_out_has_output_directive "$token"; then
    scope_block_rel "curl $opt %output{...}" "curl write-out %output{FILE} writes to a file and is refused; use -o/--output with a literal in-scope path instead"
  fi
  return 0
}

# scope_curl_write_out_has_output_directive <format>: 0 when the format holds
# curl's %output{ directive in any case, after dropping $var, ${...}, $(...),
# backticks, quotes and backslashes that could split the directive name.
scope_curl_write_out_has_output_directive() {
  local f="${1:-}" re
  case "$f" in *%*) ;; *) return 1 ;; esac
  re='\$\([^()]*\)'
  while [[ "$f" =~ $re ]]; do f="${f/"${BASH_REMATCH[0]}"/}"; done
  re='\$\{[^{}]*\}'
  while [[ "$f" =~ $re ]]; do f="${f/"${BASH_REMATCH[0]}"/}"; done
  re='\$[A-Za-z0-9_@*#?!$-]+'
  while [[ "$f" =~ $re ]]; do f="${f/"${BASH_REMATCH[0]}"/}"; done
  f="$(printf '%s' "$f" | LC_ALL=C tr -d "\140\"'\\\\\$" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  case "$f" in *%output\{*) return 0 ;; esac
  return 1
}

# scope_url_word_scan <text> <start>: reads one shell word of <text> from
# <start>, honouring quotes, backslashes and $(...). Sets scope_url_plain
# (the word with quotes removed), scope_url_end (offset after it) and
# scope_url_split (1 when the word holds an unquoted $ or backtick, which
# bash expands and word-splits). Globs and braces are not counted: every word
# they produce keeps the literal http(s) prefix typed before them.
scope_url_word_scan() {
  local t="${1:-}" i="${2:-0}" n c q="" depth
  n=${#t}
  scope_url_plain=""
  scope_url_split=0
  while [ "$i" -lt "$n" ]; do
    c="${t:$i:1}"
    if [ -z "$q" ]; then
      case "$c" in ' '|$'\t'|$'\n'|';'|'&'|'|'|'<'|'>'|'('|')') break ;; esac
    fi
    i=$((i + 1))
    if [ "$q" = "'" ]; then
      if [ "$c" = "'" ]; then q=""; else scope_url_plain="$scope_url_plain$c"; fi
      continue
    fi
    case "$c" in
      \\) scope_url_plain="$scope_url_plain${t:$i:1}"; i=$((i + 1)); continue ;;
      '"') if [ "$q" = '"' ]; then q=""; else q='"'; fi; continue ;;
      "'") if [ -z "$q" ]; then q="'"; continue; fi ;;
    esac
    if [ "$c" = '$' ] && [ "${t:$i:1}" = "(" ]; then
      # Copy $(...) whole so its inner spaces and quotes do not end the word.
      [ -n "$q" ] || scope_url_split=1
      scope_url_plain="$scope_url_plain$c"
      depth=0
      while [ "$i" -lt "$n" ]; do
        c="${t:$i:1}"
        i=$((i + 1))
        scope_url_plain="$scope_url_plain$c"
        case "$c" in
          '(') depth=$((depth + 1)) ;;
          ')') depth=$((depth - 1)); [ "$depth" -gt 0 ] || break ;;
        esac
      done
      continue
    fi
    if [ -z "$q" ]; then
      case "$c" in
        '`') scope_url_split=1 ;;
        '$')
          # A loop variable whose list is literal words cannot split.
          if [[ "${t:$i}" =~ ^\{?([A-Za-z_][A-Za-z0-9_]*) ]] \
            && scope_url_is_literal_loop_var "${BASH_REMATCH[1]}"; then
            :
          else
            scope_url_split=1
          fi
          ;;
      esac
    fi
    scope_url_plain="$scope_url_plain$c"
  done
  scope_url_end=$i
}

# True when the raw command (scope_scan_cmd) binds <name> only through one
# `for <name> in <words>` whose words hold no expansion or quote, so each
# value is one literal word and $<name> cannot word-split.
# `grep -o 'https://...' FILE...`: every line grep -o prints is a match of
# the pattern, and a pattern that opens with a literal http(s) scheme (no
# alternation, group, anchor or escape anywhere) can only match text that
# starts with that scheme. The files are literal words the path scans check
# as operands. -o is required; -v, -l, -L, -c, -f, -e, -r and -R change what
# is printed and are refused (feedback c40241c1).
scope_subst_body_prints_https_urls() {
  local body="${1:-}" re flags pattern files word
  body="${body#"${body%%[![:space:]]*}"}"
  body="${body%"${body##*[![:space:]]}"}"
  # The scheme is spelled out at the start of the pattern: a literal `http`
  # that no quantifier applies to (`h?ttps://` could match `ttps://`), an
  # optional `s` only as `s?`, then `://`. The rest may hold brackets and
  # escapes, but no alternation (`|`, which also spells GNU `\|`), group or
  # quote, so every match still opens with that scheme.
  re='^grep((\ -[a-zA-Z]+)*)\ ("|'"'"')?([Hh][Tt][Tt][Pp]([Ss]\??)?://(\\.|[^"'"'"'[:space:]|()\\])*)("|'"'"')?((\ [A-Za-z0-9_./@+-]+)+)$'
  # A single-quoted pattern may also hold `"` (`'https://[^"]*\.woff2'`),
  # which the shell passes to grep as a plain character.
  local sq_re='^grep((\ -[a-zA-Z]+)*)\ '"'"'([Hh][Tt][Tt][Pp]([Ss]\??)?://(\\.|[^'"'"'[:space:]|()\\])*)'"'"'((\ [A-Za-z0-9_./@+-]+)+)$'
  if [[ "$body" =~ $re ]] && [ "${BASH_REMATCH[3]}" = "${BASH_REMATCH[7]}" ]; then
    flags="${BASH_REMATCH[1]}"
    pattern="${BASH_REMATCH[4]}"
    files="${BASH_REMATCH[8]}"
  elif [[ "$body" =~ $sq_re ]]; then
    flags="${BASH_REMATCH[1]}"
    pattern="${BASH_REMATCH[3]}"
    files="${BASH_REMATCH[6]}"
  else
    return 1
  fi
  case "$flags" in *o*) ;; *) return 1 ;; esac
  case "$flags" in *[vlLcferRz]*) return 1 ;; esac
  # Context, filename, offset and other output-changing flags invalidate the
  # match-only contract. Keep only match output and regex/case selection.
  local url_flags="${flags// /}"
  url_flags="${url_flags//-/}"
  case "$url_flags" in *[!oEi]*) return 1 ;; esac
  # for-in splits an unquoted match on whitespace. Only this explicit
  # whitespace-excluding tail proves that every generated word is a URL.
  # In particular .* and [^"]* do not establish this property.
  local url_tail="${pattern#*://}"
  [ -n "$pattern" ] || return 1
  local -a url_files=()
  read -r -a url_files <<< "$files"
  for word in ${url_files[@]+"${url_files[@]}"}; do
    case "$word" in -*|*'..'*|*[*?[]*) return 1 ;; esac
  done
  case "$url_tail" in
    '[^[:space:]]*'|'[^[:space:]\"]*'|'[^[:space:]"]*') return 0 ;;
  esac
  # Any other tail (`'https://[^"]*\.woff2'`) can match whitespace, so a
  # match can split into a word that is not a URL (test c40241c1-unsafe).
  return 1
}

scope_url_is_literal_loop_var() {
  local name="${1:-}" cmd="${scope_scan_cmd:-}" re bind_re
  re="(^|[;&|({[:space:]])for[[:space:]]+${name}[[:space:]]+in[[:space:]]+([^;\$\`\"'\\]*);"
  if ! [[ "$cmd" =~ $re ]]; then
    # The list is one `$(grep -o 'https://...' FILE)`: every value is an
    # http(s) URL (scope_subst_body_prints_https_urls).
    re="(^|[;&|({[:space:]])for[[:space:]]+${name}[[:space:]]+in[[:space:]]+\\\$\\(([^()\`]*)\\)[[:space:]]*;"
    [[ "$cmd" =~ $re ]] || return 1
    scope_subst_body_prints_https_urls "${BASH_REMATCH[2]}" || return 1
  fi
  bind_re="(^|[^A-Za-z0-9_\$])${name}(\[[^]]*\])?\+?=|(^|[^A-Za-z0-9_.-])(read|mapfile|readarray|getopts|eval|source|declare|typeset|local|let|select)([[:space:]]|\$)|printf[[:space:]]+-v"
  [[ "$cmd" =~ $bind_re ]] && return 1
  [ "$(printf '%s' "$cmd" | grep -oE "for[[:space:]]+${name}[[:space:]]" | wc -l | tr -d '[:space:]')" = "1" ]
}

# True when <word> opens with a literal http:// or https:// scheme and holds
# no unquoted expansion. An unquoted command substitution, backtick or
# parameter expansion is expanded and word-split by bash, so
# an operand like https://<unquoted substitution> can hand curl a second
# operand such as file:///other/path (PR 1544 re-review). An expansion
# inside double quotes does not split: the word stays one operand that
# starts with the literal http(s) scheme, so it cannot become a local URL
# and is allowed. Some callers pass a word whose quotes were already
# removed; its quoting is then read back from the raw command text
# (scope_scan_cmd): every raw word that unquotes to it must be free of
# unquoted expansions, and at least one must exist (fail closed otherwise).
scope_word_is_literal_remote_url() {
  local w="${1:-}" re='^[Hh][Tt][Tt][Pp][Ss]?://' t="${scope_scan_cmd:-}" i=0 n found=0
  scope_url_word_scan "$w" 0
  [[ "$scope_url_plain" =~ $re ]] || return 1
  [ "$scope_url_split" -eq 1 ] || return 0
  case "$w" in *\"*|*\'*|*\\*) return 1 ;; esac
  n=${#t}
  while [ "$i" -lt "$n" ]; do
    case "${t:$i:1}" in
      ' '|$'\t'|$'\n'|';'|'&'|'|'|'<'|'>'|'('|')') i=$((i + 1)); continue ;;
    esac
    scope_url_word_scan "$t" "$i"
    [ "$scope_url_end" -gt "$i" ] || scope_url_end=$((i + 1))
    i=$scope_url_end
    if [ "$scope_url_plain" = "$w" ]; then
      [ "$scope_url_split" -eq 0 ] || return 1
      found=1
    fi
  done
  [ "$found" -eq 1 ]
}

# One `ssh -o` value. Records a HostName override in scope_ssh_hostname
# (case-insensitive key, `=` or blank separator). Fails on options that run
# local commands or pull in other config (ProxyCommand, LocalCommand,
# Include, ...) and on a value the guard cannot read literally
# (feedback 944d2873).
scope_ssh_hostname=""
scope_ssh_option_ok() {
  local v="${1:-}" key val
  v="${v//[\"\']/}"
  case "$v" in ''|*'$'*|*$'\140'*|*'\'*) return 1 ;; esac
  v="$(printf '%s' "$v" | tr '\t' ' ')"
  key="${v%%[= ]*}"
  val="${v#"$key"}"
  val="${val#"${val%%[!= ]*}"}"
  key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
  case "$key" in
    hostname)
      # OpenSSH uses the first HostName given; any local one fails closed.
      [ -n "$val" ] || return 1
      scope_ssh_host_is_remote "$val" || return 1
      [ -n "$scope_ssh_hostname" ] || scope_ssh_hostname="$val" ;;
    proxycommand|localcommand|permitlocalcommand|include|knownhostscommand|remotecommand|match|host|canonicalizehostname|proxyjump|proxyusefdpass) return 1 ;;
  esac
  return 0
}

# True only when an ssh destination is proven not to be this machine from
# local text alone (no DNS, no ssh). Case-insensitive; strips ssh://, user@
# and :port. Refuses loopback, unspecified and non-dotted-quad numeric IPv4
# forms (0, 2130706433, 0x7f000001, 127.1, 017700000001), every IPv6
# literal, localhost aliases, this machine's names, and names that
# /etc/hosts maps to a loopback or unspecified address (feedback 944d2873).
scope_ssh_host_is_remote() {
  local h="${1:-}" name hn line addr rest part
  case "$h" in ''|*'$'*|*$'\140'*|*'%'*|*'\'*) return 1 ;; esac
  h="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')"
  h="${h#ssh://}"
  h="${h##*@}"
  case "$h" in '['*|*:*:*) return 1 ;; esac
  h="${h%%:*}"
  h="${h%/}"
  h="${h%.}"
  [ -n "$h" ] || return 1
  case "$h" in *[!a-z0-9._-]*) return 1 ;; esac
  case "$h" in
    *[!0-9a-fx.]*) ;;
    *)
      # Only a plain dotted quad outside 0/8 and 127/8 counts as remote;
      # inet_aton reads every other all-hex/number form as an address.
      if [[ "$h" =~ ^([1-9][0-9]{0,2})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        for part in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
          case "$part" in 0?*) return 1 ;; esac
          [ "$part" -le 255 ] || return 1
        done
        [ "${BASH_REMATCH[1]}" -ne 127 ] || return 1
        return 0
      fi
      # A name of hex letters only (e.g. `cafe.be`) is still a name, but an
      # all-digit, 0x or dotted-number form is an address.
      case "$h" in *[0-9]*|*x*|*.) return 1 ;; esac
      ;;
  esac
  case "$h" in
    localhost|localhost.*|*.localhost|localhost6|localhost6.*|ip6-localhost|ip6-loopback|loopback|broadcasthost|*.localdomain|localdomain|0.*|127.*) return 1 ;;
  esac
  for name in "$(hostname 2>/dev/null)" "$(hostname -s 2>/dev/null)" "$(uname -n 2>/dev/null)" "${HOSTNAME:-}"; do
    hn="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    hn="${hn%.}"
    [ -n "$hn" ] || continue
    [ "$h" != "$hn" ] || return 1
    [ "$h" != "${hn%%.*}" ] || return 1
    [ "$h" != "${hn%%.*}.local" ] || return 1
  done
  if [ -r /etc/hosts ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]' | tr '\t' ' ')"
      addr="${line%% *}"
      rest=" ${line#* } "
      [ -n "$addr" ] && [ "$addr" != "$line" ] || continue
      case "$rest" in *" $h "*) ;; *) continue ;; esac
      case "$addr" in 127.*|0.*|::1|::|*:*) return 1 ;; esac
    done </etc/hosts
  fi
  return 0
}

# True when word <index> (scope_tokens) or word <k> (sw_raw, when <words>
# is "sw") sits in a position whose value is sent to a remote program, never
# opened as a local file: the URL operand of curl/wget (not the value of an
# output or upload option), the command text after the host of ssh, the
# words after `--` of `hq outposts exec NAME --`, or the repository of
# `gh -R` / `--repo`. Such a word may carry a command substitution or a
# variable the guard cannot resolve; the substitution body is still checked
# as a command by the caller, so what it reads locally stays checked
# (feedback aba2d75e, b7c03d1a, 3ee29d66, 2ec4335f).
scope_remote_position() {
  local words="${1:-tokens}" index="${2:-0}" head_index="${3:-0}" head word prev j host_seen=0 dashdash=0 host="" sshflags sshc sshval sshtake
  scope_ssh_hostname=""
  if [ "$words" = sw ]; then
    scope_remote_word() { printf '%s' "${sw_raw[$1]:-}"; }
  else
    scope_remote_word() { printf '%s' "${scope_tokens[$1]:-}"; }
  fi
  # `until curl ...`, `while ssh ...`, `time curl ...`: the client follows
  # the keyword or wrapper.
  while [ "$head_index" -lt "$index" ]; do
    case "$(scope_remote_word "$head_index")" in
      until|while|if|time|nohup|command|builtin|exec) head_index=$((head_index + 1)) ;;
      *) break ;;
    esac
  done
  [ "$index" -gt "$head_index" ] || return 1
  head="$(scope_remote_word "$head_index")"
  head="${head//[\"\'\\]/}"
  head="${head##*/}"
  word="$(scope_remote_word "$index")"
  prev="$(scope_remote_word "$((index - 1))")"
  prev="${prev//[\"\'\\]/}"
  case "${word#[\"\']}" in -*) return 1 ;; esac
  case "$head" in
    curl|wget)
      case "$prev" in
        -o|-O|--output|--output-document|-T|--upload-file|-K|--config|-d|--data*|-F|--form|-D|--dump-header|-c|--cookie-jar|-b|--cookie|-E|--cert|--key|--cacert|--capath|--netrc-file|--output-dir|--trace|--trace-ascii|-i|--input-file|-P|--directory-prefix|-a|--append-output|--load-cookies|--save-cookies|--post-file|--body-file|-w|--write-out|--unix-socket|--abstract-unix-socket|--proxy-cacert|--proxy-cert|--proxy-key|--etag-save|--etag-compare|--hsts|--alt-svc|--libcurl|--stderr|--crlfile|--pinnedpubkey|--proxy-crlfile|--warc-file|--rejected-log|--ca-certificate|--ca-directory|--certificate|--private-key|--hsts-file|--base)
          return 1 ;;
      esac
      # Only a URL operand whose command text spells a literal http(s)
      # scheme. curl and wget also open file:// (and other local
      # schemes), so a URL taken whole from a substitution or a variable is
      # not proven remote and keeps the taint rule (PR 1544 review).
      scope_word_is_literal_remote_url "$word" && return 0
      return 1
      ;;
    ssh)
      case "$prev" in -i|-F|-E|-S|-o|-p|-l|-J|-L|-R|-D|-W|-b|-c|-m|-e|-I|-O|-Q|-w|-B|-P) return 1 ;; esac
      j=$((head_index + 1))
      while [ "$j" -lt "$index" ]; do
        word="$(scope_remote_word "$j")"
        case "$word" in
          -?*|\"-?*|\'-?*)
            # Walk bundled short flags (`-4oHostName=x`, `-vF/tmp/cfg`,
            # `-Ao HostName=x`) as OpenSSH getopt does: the first
            # value-taking letter takes the rest of the word, or the next
            # word when the rest is empty. -o values are read; -F fails
            # closed (feedback 944d2873).
            sshflags="${word#[\"\']}"
            sshflags="${sshflags#-}"
            sshtake=0
            while [ -n "$sshflags" ]; do
              sshc="${sshflags:0:1}"
              sshflags="${sshflags:1}"
              case "$sshc" in
                o|F|b|c|D|E|e|I|i|J|L|l|m|O|p|Q|R|S|W|w|B|P)
                  if [ -n "$sshflags" ]; then
                    sshval="$sshflags"
                  else
                    sshval="$(scope_remote_word "$((j + 1))")"
                    sshtake=1
                  fi
                  case "$sshc" in
                    o) scope_ssh_option_ok "$sshval" || return 1 ;;
                    F) return 1 ;;
                  esac
                  break ;;
              esac
            done
            j=$((j + 1 + sshtake)); continue ;;
          *) if [ "$host_seen" -eq 0 ]; then host="${word//[\"\']/}"; fi; host_seen=1 ;;
        esac
        j=$((j + 1))
      done
      [ "$host_seen" -eq 1 ] || return 1
      # The host must be literal and not this machine: `ssh localhost "..."`
      # runs the text here, unchecked. A HostName option replaces the
      # positional host; a -F config file is not read, so it fails closed
      # (feedback 944d2873).
      [ -z "$scope_ssh_hostname" ] || host="$scope_ssh_hostname"
      scope_ssh_host_is_remote "$host" || return 1
      return 0
      ;;
    hq)
      [ "$(scope_remote_word "$((head_index + 1))")" = outposts ] || return 1
      [ "$(scope_remote_word "$((head_index + 2))")" = exec ] || return 1
      j=$((head_index + 3))
      while [ "$j" -lt "$index" ]; do
        [ "$(scope_remote_word "$j")" = -- ] && dashdash=1
        j=$((j + 1))
      done
      [ "$dashdash" -eq 1 ] && return 0
      return 1
      ;;
    gh)
      case "$prev" in -R|--repo) return 0 ;; esac
      case "${word#[\"\']}" in --repo=*) return 0 ;; esac
      # `gh repo <subcommand> OWNER/name`: the first operand after the
      # subcommand is a GitHub owner/repo slug, never a local path. Local
      # roots and path-looking words stay checked.
      if [ "$(scope_remote_word "$((head_index + 1))")" = repo ] \
        && [ "$index" -eq "$((head_index + 3))" ]; then
        case "${word#[\"\']}" in
          companies/*|repos/*|workspace/*|core/*|personal/*|.*|/*|'~'*) return 1 ;;
          [A-Za-z0-9]*/[A-Za-z0-9_.-]*)
            case "${word%%/*}" in *[!A-Za-z0-9_.\"\'-]*) return 1 ;; esac
            return 0 ;;
        esac
      fi
      return 1
      ;;
  esac
  return 1
}

# True when token <index> holds a `$(...)` in a remote position
# (scope_remote_position) with no backtick, nested substitution or
# backslash; the bodies are returned in scope_prose_subs.
scope_token_is_remote_operand_substitution() {
  local index="${1:-0}" token head_index reduced sub_re mark=$'\001'
  scope_prose_subs=()
  [ "$index" -gt 0 ] || return 1
  token="${scope_tokens[$index]:-}"
  case "$token" in *'$('*) ;; *) return 1 ;; esac
  case "$token" in *$'\140'*|*"$mark"*|*$'\n'*) return 1 ;; esac
  [[ "${scope_scan_cmd:-}" == *\\* ]] && return 1
  # A single-quoted word expands nothing locally; the inert-text rule
  # (scope_candidate_is_single_quoted) already covers it, and its `$(` with a
  # glob inside is remote text that the prose-substitution rules would refuse.
  [[ "${scope_scan_cmd:-}" == *"'$token'"* ]] && return 1
  head_index="$(scope_command_head_index)"
  case "$head_index" in ''|*[!0-9]*) return 1 ;; esac
  [ "$head_index" -lt "${#scope_tokens[@]}" ] || return 1
  scope_remote_position tokens "$index" "$head_index" || return 1
  reduced="$token"
  sub_re='\$\(([^()]*)\)'
  while [[ "$reduced" =~ $sub_re ]]; do
    scope_prose_subs[${#scope_prose_subs[@]}]="${BASH_REMATCH[1]}"
    reduced="${reduced/"${BASH_REMATCH[0]}"/$mark}"
    [ "${#scope_prose_subs[@]}" -le 8 ] || return 1
  done
  case "$reduced" in *'$('*|*'('*|*')'*) return 1 ;; esac
  return 0
}

scope_token_is_text_option_value() {
  local index="${1:-0}" token prev opt head reduced sub_re piece mark=$'\001' backtick=$'\140'
  scope_prose_subs=()
  scope_text_pieces=()
  [ "$index" -gt 0 ] || return 1
  token="${scope_tokens[$index]:-}"
  prev="${scope_tokens[$((index - 1))]:-}"
  head="${scope_tokens[$(scope_command_head_index)]:-}"
  head="${head##*/}"
  case "$token" in
    --*=*) opt="${token%%=*}"; token="${token#*=}" ;;
    *) opt="$prev" ;;
  esac
  case "$opt" in
    --text|--summary|--title|--body|--message|--note|--description|--next|--subject|--comment|--reason|--details|--question) ;;
    # gh's short forms of --body and --title carry the same text.
    -b|-t) [ "$head" = gh ] || return 1 ;;
    # A curl request header is sent to the server, never opened as a file.
    # `-H @file` reads headers from a file, so that spelling stays a path.
    -H|--header) [ "$head" = curl ] || return 1; case "$token" in @*) return 1 ;; esac ;;
    # The HQ lane commands expose --text, not -m. Do not infer a message
    # contract from the executable name alone.
    -m) [ "$head" = git ] || return 1 ;;
    *) return 1 ;;
  esac
  local known_message=0 escaped_token message_head
  message_head="$(scope_command_head_index)"
  if [ "$head" = hq ] && [ "${scope_tokens[$((message_head + 1))]:-}" = lanes ]; then
    if [ "${scope_tokens[$((message_head + 2))]:-}" = message ] \
      || { [ "${scope_tokens[$((message_head + 2))]:-}" = link ] \
        && [ "${scope_tokens[$((message_head + 3))]:-}" = report ]; }; then
      known_message=1
    fi
  fi
  if [ "$known_message" -eq 0 ]; then
    case "$token" in *[[:space:]]*) ;; *) return 1 ;; esac
  fi
  case "$token" in *"$mark"*) return 1 ;; esac
  # The tokenizer removes escapes. Recover a wholly escaped dollar spelling
  # from the original command before interpreting substitutions in message data.
  escaped_token="${token//\$/\\\$}"
  if [ "$known_message" -eq 1 ] && [[ "$scope_scan_cmd" == *"\"$escaped_token\""* ]] \
    && [[ "$scope_scan_cmd" != *"\"$token\""* ]]; then
    token="${token//\$/__HQ_LITERAL_DOLLAR__}"
  else
    [[ "${scope_scan_cmd:-}" == *\\* ]] && case "$token" in *'$('*|*"$backtick"*) return 1 ;; esac
  fi
  reduced="$token"
  sub_re='\$\(([^()]*)\)'
  while [[ "$reduced" =~ $sub_re ]]; do
    scope_prose_subs[${#scope_prose_subs[@]}]="${BASH_REMATCH[1]}"
    reduced="${reduced/"${BASH_REMATCH[0]}"/$mark}"
    [ "${#scope_prose_subs[@]}" -le 16 ] || return 1
  done
  sub_re="$backtick([^$backtick\\\\]*)$backtick"
  while [[ "$reduced" =~ $sub_re ]]; do
    scope_prose_subs[${#scope_prose_subs[@]}]="${BASH_REMATCH[1]}"
    reduced="${reduced/"${BASH_REMATCH[0]}"/$mark}"
    [ "${#scope_prose_subs[@]}" -le 16 ] || return 1
  done
  case "$reduced" in *'$('*|*"$backtick"*) return 1 ;; esac
  [ "$known_message" -eq 1 ] && return 0
  case "$reduced" in *'('*'('*|*'..'*) return 1 ;; esac
  # As for prose: the first word is literal and no entry starting with it
  # exists, so even a program that opened the value could not reach a real
  # directory through it.
  piece="${reduced%%[[:space:]]*}"
  [ -n "$piece" ] || return 1
  case "$piece" in *'/'*|*'$'*|*"$mark"*|*'*'*|*'?'*|*'['*|*'{'*|*'~'*) return 1 ;; esac
  if ( cd "${COMMAND_CWD:-$HQ_ROOT}" 2>/dev/null && shopt -s dotglob && compgen -G "$piece"'[[:space:]]*' >/dev/null ); then
    return 1
  fi
  while IFS= read -r piece; do
    case "$piece" in
      *"$mark"*/*|*/*"$mark"*) scope_block_rel "$token" "a command substitution result is used as part of a path inside message text" ;;
      *'$'*/*|*/*'$'*)
        # The tokenizer drops backslashes, so `"Pro is \$49/mo"` arrives as
        # `$49/mo`. When every `$` in the piece is escaped wherever the piece
        # occurs in the command, the program receives that literal text and
        # no variable is expanded; skip it. Otherwise check it as a path.
        scope_text_piece_is_escaped "$piece" || scope_text_pieces[${#scope_text_pieces[@]}]="$piece"
        ;;
      */*) scope_text_pieces[${#scope_text_pieces[@]}]="$piece" ;;
    esac
  done <<< "${reduced//[[:space:]]/$'\n'}"
  return 0
}

# A repos/private/<name> or repos/public/<name> symlink may point at a checkout
# outside the HQ tree only when that checkout's directory is listed in the
# owner root file. The file is $HOME/.hq/repo-symlink-roots, outside the HQ
# tree: one absolute directory per line, blank lines and # comments ignored.
# The owner adds a root by editing that file in their own editor. This hook
# refuses any Bash, Read, Write, Edit, or MultiEdit that names the file, so a
# session cannot add a root for itself. companies/manifest.yaml is not the
# registry. A listed directory is ignored when it is /, $HOME, the HQ root,
# an ancestor of $HOME or the HQ root, or anywhere under companies/.
scope_owner_roots_file() {
  local home="${HOME:-}"
  case "$home" in
    /*) printf '%s' "${home%/}/.hq/repo-symlink-roots" ;;
    *) printf '%s' "" ;;
  esac
}

scope_block_if_names_owner_roots() {
  local text="${1:-}" kind="${2:-}" squashed roots resolved
  [ -n "$text" ] || return 0
  squashed="${text//[\"\'\\]/}"
  case "$squashed" in
    *repo-symlink-roots*)
      scope_block_rel "repo-symlink-roots" "the repo symlink root list is owner-only; add a root by editing \$HOME/.hq/repo-symlink-roots in your own editor, not from the session"
      ;;
  esac
  roots="$(scope_owner_roots_file)"
  [ -n "$roots" ] || return 0
  case "$text" in
    "$roots"|"$roots"/*)
      scope_block_rel "$roots" "the repo symlink root list is owner-only; add a root by editing \$HOME/.hq/repo-symlink-roots in your own editor, not from the session"
      ;;
  esac
  case "$text" in
    /*)
      resolved="$(scope_resolve_absolute_path "$text" 2>/dev/null || true)"
      if [ -n "$resolved" ] && [ "$resolved" = "$roots" ]; then
        scope_block_rel "$roots" "the repo symlink root list is owner-only; add a root by editing \$HOME/.hq/repo-symlink-roots in your own editor, not from the session"
      fi
      ;;
  esac
  # Read/Write/Edit pass one path. Resolve it (including a relative symlink)
  # before matching. Bash is walked token by token instead of as one path.
  if [ "$kind" = "path" ]; then
    scope_owner_roots_consider "$text" "${COMMAND_CWD:-$HQ_ROOT}"
  fi
}

# 0 when path is /, equals or contains $HOME or the HQ root, or is inside
# companies/. "Contains" means HOME or the HQ root sits inside path.
scope_repo_root_is_rejected() {
  local path="${1:-}" home="${HOME:-}"
  path="${path%/}"
  [ -n "$path" ] || return 0
  [ "$path" = "/" ] && return 0
  case "$home" in
    /*)
      home="${home%/}"
      [ "$path" = "$home" ] && return 0
      case "$home" in
        "$path"/*) return 0 ;;
      esac
      ;;
  esac
  [ "$path" = "$HQ_ROOT" ] && return 0
  case "$HQ_ROOT" in
    "$path"/*) return 0 ;;
  esac
  case "$path" in
    "$HQ_ROOT"/companies|"$HQ_ROOT"/companies/*) return 0 ;;
  esac
  return 1
}

scope_load_owner_roots() {
  # Re-read every check. A path that was a real directory when it was listed
  # can be replaced by a symlink before the next use; do not trust a cache,
  # and do not trust a listed path whose final component is a symlink.
  SCOPE_OWNER_ROOTS=""
  local file line resolved
  file="$(scope_owner_roots_file)"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      ""|\#*) continue ;;
      /*) ;;
      *) continue ;;
    esac
    if [ -L "$line" ]; then
      continue
    fi
    resolved="$(scope_resolve_absolute_path "$line" 2>/dev/null || true)"
    [ -n "$resolved" ] || continue
    resolved="${resolved%/}"
    [ -n "$resolved" ] || resolved="/"
    scope_repo_root_is_rejected "$resolved" && continue
    case "
$SCOPE_OWNER_ROOTS" in
      *"
$resolved
"*) ;;
      *) SCOPE_OWNER_ROOTS="${SCOPE_OWNER_ROOTS}${resolved}"$'\n' ;;
    esac
  done < "$file"
}

scope_owner_root_covers() {
  local path="${1:-}" root
  path="${path%/}"
  [ -n "$path" ] || return 1
  scope_load_owner_roots
  [ -n "${SCOPE_OWNER_ROOTS:-}" ] || return 1
  while IFS= read -r root || [ -n "$root" ]; do
    [ -n "$root" ] || continue
    [ "$path" = "$root" ] && return 0
    case "$path" in
      "$root"/*) return 0 ;;
    esac
  done <<< "${SCOPE_OWNER_ROOTS}"
  return 1
}

# Charter deny list for every path reached through a repo symlink: rc files,
# SSH, AWS (including sso and cache), GPG, env, netrc, shell profiles, and
# gh and kube configs. Matched on the resolved path, not only on $HOME.
scope_fs_folds_case() {
  if [ "${SCOPE_FS_FOLDS_CASE_SET:-0}" -ne 1 ]; then
    SCOPE_FS_FOLDS_CASE_SET=1
    case "$(uname -s 2>/dev/null || true)" in
      Darwin) SCOPE_FS_FOLDS_CASE=1 ;;
      *) SCOPE_FS_FOLDS_CASE=0 ;;
    esac
  fi
  [ "${SCOPE_FS_FOLDS_CASE:-0}" -eq 1 ]
}

# Fold only the repos/ and private|public segments, and only where the
# filesystem does. The rest of the path, including .ENV, stays as typed so a
# later sensitive-name check can fold it on its own.
scope_canonicalize_repos_token() {
  local token="${1:-}" prefix="" body dot="" low rest seg2 seg2low tail
  [ -n "$token" ] || { printf '%s' ""; return 0; }
  scope_fs_folds_case || { printf '%s' "$token"; return 0; }
  case "$token" in
    "$HQ_ROOT"/*)
      prefix="$HQ_ROOT/"
      body="${token#"$HQ_ROOT"/}"
      ;;
    *) body="$token" ;;
  esac
  dot=""
  case "$body" in
    ./*) dot="./"; body="${body#./}" ;;
  esac
  low="$(printf '%s' "${body%%/*}" | tr '[:upper:]' '[:lower:]')"
  [ "$low" = "repos" ] || { printf '%s' "$token"; return 0; }
  if [ "$body" = "${body%%/*}" ]; then
    printf '%s' "${prefix}${dot}repos"
    return 0
  fi
  rest="${body#*/}"
  seg2="${rest%%/*}"
  seg2low="$(printf '%s' "$seg2" | tr '[:upper:]' '[:lower:]')"
  case "$seg2low" in
    private|public) ;;
    *) printf '%s' "$token"; return 0 ;;
  esac
  if [ "$rest" = "$seg2" ]; then
    printf '%s' "${prefix}${dot}repos/$seg2low"
    return 0
  fi
  tail="${rest#*/}"
  printf '%s' "${prefix}${dot}repos/$seg2low/$tail"
}

scope_link_path_is_sensitive() {
  local path="${1:-}" base
  [ -n "$path" ] || return 1
  if scope_fs_folds_case; then
    path="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  fi
  case "$path" in
    /.ssh|/.ssh/*|*/.ssh|*/.ssh/*) return 0 ;;
    /.gnupg|/.gnupg/*|*/.gnupg|*/.gnupg/*) return 0 ;;
    /.aws|/.aws/*|*/.aws|*/.aws/*) return 0 ;;
    /.kube|/.kube/*|*/.kube|*/.kube/*) return 0 ;;
    /.config/gh|/.config/gh/*|*/.config/gh|*/.config/gh/*) return 0 ;;
  esac
  base="${path##*/}"
  case "$base" in
    .env|.env.*|.netrc|.zshrc|.zprofile|.zshenv|.zlogin|.zlogout|.bashrc|.bash_profile|.bash_login|.bash_logout|.profile|.kshrc|.cshrc|.tcshrc|.login|.logout|.bash_aliases)
      return 0 ;;
  esac
  return 1
}

scope_path_inside() {
  local path="${1:-}" root="${2:-}"
  [ -n "$path" ] && [ -n "$root" ] && [ "$root" != "/" ] || return 1
  [ "$path" = "$root" ] && return 0
  case "$path" in
    "$root"/*) return 0 ;;
  esac
  return 1
}

# repos/(private|public)/<segment> for a path that is that link or a file under it.
scope_repo_link_rel() {
  local raw="${1:-}" rel kind rest name
  raw="$(scope_canonicalize_repos_token "$raw")"
  case "$raw" in
    "$HQ_ROOT"/repos/*) rel="${raw#"$HQ_ROOT"/}" ;;
    repos/*) rel="$raw" ;;
    *) printf '%s' ""; return 0 ;;
  esac
  rel="${rel#./}"
  rel="${rel%/}"
  case "$rel" in
    repos/private/*|repos/public/*) ;;
    *) printf '%s' ""; return 0 ;;
  esac
  kind="${rel#repos/}"
  kind="${kind%%/*}"
  rest="${rel#repos/$kind/}"
  name="${rest%%/*}"
  case "$name" in
    ""|.*|*..*|*[!A-Za-z0-9._-]*) printf '%s' ""; return 0 ;;
  esac
  if scope_fs_folds_case; then
    name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  fi
  printf '%s' "repos/$kind/$name"
}

# Print the repos/ relative form of a token, or fail when it is not one.
scope_repos_rel_of_token() {
  local token="${1:-}" kind rest name tail
  token="$(scope_canonicalize_repos_token "$token")"
  token="${token%/}"
  case "$token" in
    ./repos/*) token="${token#./}" ;;
    "$HQ_ROOT"/repos/*) token="${token#"$HQ_ROOT"/}" ;;
  esac
  case "$token" in
    repos/private/*|repos/public/*) ;;
    *) return 1 ;;
  esac
  if scope_fs_folds_case; then
    kind="${token#repos/}"
    kind="${kind%%/*}"
    rest="${token#repos/$kind/}"
    name="${rest%%/*}"
    name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    if [ "$rest" = "$name" ] || [ "$rest" = "${rest%%/*}" ]; then
      token="repos/$kind/$name"
    else
      tail="${rest#*/}"
      token="repos/$kind/$name/$tail"
    fi
  fi
  printf '%s' "$token"
}

scope_repos_rel_is_link_node() {
  local rel="${1:-}" rest
  case "$rel" in
    repos/private/*|repos/public/*) ;;
    *) return 1 ;;
  esac
  rest="${rel#repos/private/}"
  [ "$rest" = "$rel" ] && rest="${rel#repos/public/}"
  case "$rest" in
    ""|*/*|.*|*..*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# The destination of a link mutation is a repos/ path the command is replacing,
# not a path it is reading. Naming it must stay allowed even when the link's
# current target would be denied; the next command rechecks the new target.
scope_path_is_repo_link_mutation_dest() {
  local raw="${1:-}" rel
  [ -n "${SCOPE_LINK_MUTATION_DESTS:-}" ] || return 1
  if ! rel="$(scope_repos_rel_of_token "$raw")"; then
    return 1
  fi
  case "
$SCOPE_LINK_MUTATION_DESTS" in
    *"
$rel
"*) return 0 ;;
  esac
  return 1
}

# Physical checkout root when a cd path goes through a repos/ symlink, else empty.
scope_cd_repo_root() {
  local raw="${1:-}" rel link_rel repo_root
  case "$raw" in
    "$HQ_ROOT"/*) rel="${raw#"$HQ_ROOT"/}" ;;
    /*) printf '%s' ""; return 0 ;;
    *) rel="$raw" ;;
  esac
  link_rel="$(scope_repo_link_rel "$rel")"
  [ -n "$link_rel" ] || { printf '%s' ""; return 0; }
  [ -L "$HQ_ROOT/$link_rel" ] && [ -d "$HQ_ROOT/$link_rel" ] || { printf '%s' ""; return 0; }
  repo_root="$(scope_resolve_absolute_path "$HQ_ROOT/$link_rel" 2>/dev/null || true)"
  [ -n "$repo_root" ] && [ "$repo_root" != "/" ] || { printf '%s' ""; return 0; }
  printf '%s' "${repo_root%/}"
}

# After a leading cd, a relative token that contains .. is resolved from the
# physical directory, not from the HQ root. Returns 0 when the token was
# handled, 1 when it is not that shape.
scope_cd_dotdot_checked() {
  local raw="${1:-}" phys
  case "$raw" in
    /*|~|~/*) return 1 ;;
    workspace/*|core/*|personal/*|repos/*|companies/*|.claude/*) return 1 ;;
    *..*) ;;
    *) return 1 ;;
  esac
  # The same-command walk already resolved this .. against the real checkout.
  # Returning here skips the static-cwd refusal, which would also fire for a
  # .. that stayed inside the checkout.
  if [ "${SCOPE_REPO_CD_HANDLED:-0}" -eq 1 ]; then
    return 0
  fi
  if [ "${SCOPE_CD_APPLIED:-0}" -ne 1 ]; then
    if [ "${scope_cwd_is_static:-1}" -eq 0 ]; then
      scope_block_rel "$raw" "the command changes directory, so a relative .. path cannot be checked against the directory it runs in"
    fi
    return 1
  fi
  phys="$(scope_resolve_absolute_path "${COMMAND_CWD%/}/$raw" 2>/dev/null || true)"
  [ -n "$phys" ] || scope_block_rel "$raw" "a relative path after cd could not be resolved"
  if [ -n "${SCOPE_CD_REPO_ROOT:-}" ]; then
    if scope_repo_root_is_rejected "$SCOPE_CD_REPO_ROOT" || ! scope_owner_root_covers "$SCOPE_CD_REPO_ROOT"; then
      scope_block_rel "$raw" "a relative path after cd is inside a repo symlink the owner root list does not allow"
    fi
    if ! scope_path_inside "$phys" "$SCOPE_CD_REPO_ROOT"; then
      scope_block_rel "$raw" "a relative path after cd leaves the repo symlink target"
    fi
    if scope_link_path_is_sensitive "$phys" || scope_link_path_is_sensitive "$SCOPE_CD_REPO_ROOT"; then
      scope_block_rel "$raw" "a relative path after cd hits a sensitive path"
    fi
    case "$phys" in
      "$HQ_ROOT"/companies|"$HQ_ROOT"/companies/*)
        scope_block_rel "$raw" "a relative path after cd enters a company folder"
        ;;
    esac
    return 0
  fi
  case "$phys" in
    "$HQ_ROOT"|"$HQ_ROOT"/*)
      scope_check_raw "$phys"
      return 0
      ;;
  esac
  scope_block_rel "$raw" "a relative path after cd leaves the HQ root"
}

# A command that creates, removes, or repoints a link under repos/ may not also
# use a path under repos/. The decision follows cd/pushd and the real target
# of a repo symlink, not only a literal repos/ token. A lone ln, cp -s,
# unlink, or rm/mv of the link node itself stays allowed; the next command
# rechecks the target. Destinations are recorded so those tokens are not
# judged by the old target.

scope_expand_home_spell() {
  local token="${1:-}" home="${HOME:-}" prefix rest
  case "$token" in
    '~') printf '%s' "$home"; return 0 ;;
    # The strip pattern has to be quoted. Unquoted, bash tilde-expands
    # ${token#~/} into ${token#$HOME/} and the literal ~/ form survives.
    '~/'*)
      rest="${token#"~/"}"
      printf '%s' "${home%/}/$rest"
      return 0
      ;;
    '$HOME') printf '%s' "$home"; return 0 ;;
    '$HOME/'*)
      prefix='$HOME/'
      printf '%s' "${home%/}/${token#"$prefix"}"
      return 0
      ;;
    '${HOME}') printf '%s' "$home"; return 0 ;;
    '${HOME}/'*)
      prefix='${HOME}/'
      printf '%s' "${home%/}/${token#"$prefix"}"
      return 0
      ;;
  esac
  printf '%s' "$token"
}

# Collapse . and .. without following symlinks. Absolute in, absolute out.
scope_lexical_normalize() {
  local input="${1:-}" resolved="/" pending segment
  case "$input" in
    /*) ;;
    *) printf '%s' "$input"; return 0 ;;
  esac
  pending="${input#/}"
  while [ -n "$pending" ]; do
    case "$pending" in
      */*) segment="${pending%%/*}"; pending="${pending#*/}" ;;
      *) segment="$pending"; pending="" ;;
    esac
    case "$segment" in
      ""|.) continue ;;
      ..)
        [ "$resolved" = "/" ] || resolved="${resolved%/*}"
        [ -n "$resolved" ] || resolved="/"
        ;;
      *) resolved="${resolved%/}/$segment" ;;
    esac
  done
  printf '%s' "$resolved"
}

scope_owner_roots_deny() {
  scope_block_rel "${1:-repo-symlink-roots}" "the repo symlink root list is owner-only; add a root by editing \$HOME/.hq/repo-symlink-roots in your own editor, not from the session"
}

# Block a token that is the owner root list, its parent directory, a glob that
# matches the list, or a symlink that resolves to the list. base is the
# directory a relative token is joined to.
scope_owner_roots_consider() {
  local token="${1:-}" base="${2:-}" head="${3:-}" roots parent expanded abs resolved matches match
  [ -n "$token" ] || return 0
  roots="$(scope_owner_roots_file)"
  [ -n "$roots" ] || return 0
  parent="${roots%/*}"
  expanded="$(scope_expand_home_spell "$token")"
  case "$expanded" in
    /*) abs="$(scope_lexical_normalize "$expanded")" ;;
    *)
      [ -n "$base" ] || base="${SCOPE_WALK_LOGICAL:-${COMMAND_CWD:-$HQ_ROOT}}"
      abs="$(scope_lexical_normalize "${base%/}/$expanded")"
      ;;
  esac
  case "$abs" in
    *'*'*|*'?'*|*'['*)
      case "$abs" in
        "$parent"|"$parent"/*)
          matches="$(compgen -G "$abs" 2>/dev/null || true)"
          while IFS= read -r match || [ -n "$match" ]; do
            [ -n "$match" ] || continue
            match="$(scope_lexical_normalize "$match")"
            if [ "$match" = "$roots" ] || [ "$match" = "$parent" ]; then
              scope_owner_roots_deny "$match"
            fi
            if [ -e "$match" ] || [ -L "$match" ]; then
              resolved="$(scope_resolve_absolute_path "$match" 2>/dev/null || true)"
              if [ "$resolved" = "$roots" ] || [ "$resolved" = "$parent" ]; then
                scope_owner_roots_deny "$match"
              fi
            fi
          done <<< "$matches"
          ;;
      esac
      return 0
      ;;
  esac
  # The parent directory ($HOME/.hq) holds the list, so naming it is denied
  # for any command that can rename, remove, copy into or write it. A
  # command that only lists or tests the directory (`ls $HOME/.hq`,
  # `test -d "$HOME/.hq"`, `mkdir -p $HOME/.hq`, `stat`, `du`) changes
  # nothing under it and is allowed; the list itself stays denied by name
  # above and by the entries check below (feedback 265579a9).
  local parent_ok=0
  case "$head" in
    ls|test|'['|'[['|stat|du|tree|file|mkdir|dirname|basename|realpath|readlink|echo|printf) parent_ok=1 ;;
  esac
  if [ "$abs" = "$roots" ] || { [ "$abs" = "$parent" ] && [ "$parent_ok" -eq 0 ]; }; then
    scope_owner_roots_deny "$abs"
  fi
  if [ -e "$abs" ] || [ -L "$abs" ]; then
    resolved="$(scope_resolve_absolute_path "$abs" 2>/dev/null || true)"
    if [ "$resolved" = "$roots" ] || { [ "$resolved" = "$parent" ] && [ "$parent_ok" -eq 0 ]; }; then
      scope_owner_roots_deny "$abs"
    fi
  fi
}

scope_walk_record_assign() {
  local token="${1:-}" name val line kept
  # A case pattern [A-Za-z0-9_]* still requires a second character, so L=ln
  # never matched. One-character names are real assignments.
  [[ "$token" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || return 0
  name="${BASH_REMATCH[1]}"
  val="${BASH_REMATCH[2]}"
  kept=""
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      "$name"=*) ;;
      *) kept="${kept}${line}"$'\n' ;;
    esac
  done <<< "${SCOPE_WALK_ASSIGNS:-}"
  SCOPE_WALK_ASSIGNS="${kept}${name}=${val}"$'\n'
}

scope_walk_lookup_assign() {
  local token="${1:-}" name line
  # Same case-pattern trap: $L and ${L} are one character and must count.
  if [[ "$token" =~ ^\$([A-Za-z_][A-Za-z0-9_]*)$ ]]; then
    name="${BASH_REMATCH[1]}"
  elif [[ "$token" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
    name="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$name"=*)
        printf '%s' "${line#"$name"=}"
        return 0
        ;;
    esac
  done <<< "${SCOPE_WALK_ASSIGNS:-}"
  return 1
}

scope_walk_push_frame() {
  local payload snap
  payload="${SCOPE_WALK_LOGICAL}"$'\034'"${SCOPE_WALK_PHYSICAL}"$'\034'"${SCOPE_WALK_ASSIGNS}"$'\034'"${SCOPE_WALK_SAW_REPO}"$'\034'"${SCOPE_WALK_DOTDOT_INSIDE}"$'\034'"${SCOPE_WALK_CWD_KNOWN}"$'\034'"${SCOPE_WALK_REPO_ROOTS}"
  printf -v snap '%q' "$payload"
  SCOPE_WALK_FRAMES="${SCOPE_WALK_FRAMES}${snap}"$'\n'
}

scope_walk_pop_frame() {
  local line payload rest
  [ -n "${SCOPE_WALK_FRAMES:-}" ] || return 0
  line="${SCOPE_WALK_FRAMES%$'\n'}"
  line="${line##*$'\n'}"
  case "$SCOPE_WALK_FRAMES" in
    "$line"$'\n') SCOPE_WALK_FRAMES="" ;;
    *) SCOPE_WALK_FRAMES="${SCOPE_WALK_FRAMES%"$line"$'\n'}" ;;
  esac
  payload=""
  eval "payload=$line"
  SCOPE_WALK_LOGICAL="${payload%%$'\034'*}"
  rest="${payload#*$'\034'}"
  SCOPE_WALK_PHYSICAL="${rest%%$'\034'*}"
  rest="${rest#*$'\034'}"
  SCOPE_WALK_ASSIGNS="${rest%%$'\034'*}"
  rest="${rest#*$'\034'}"
  SCOPE_WALK_SAW_REPO="${rest%%$'\034'*}"
  rest="${rest#*$'\034'}"
  SCOPE_WALK_DOTDOT_INSIDE="${rest%%$'\034'*}"
  rest="${rest#*$'\034'}"
  SCOPE_WALK_CWD_KNOWN="${rest%%$'\034'*}"
  rest="${rest#*$'\034'}"
  SCOPE_WALK_REPO_ROOTS="$rest"
}

scope_walk_has_dotdot() {
  case "${1:-}" in
    ..|../*|*/..|*/../*) return 0 ;;
  esac
  return 1
}

# Prints REPOS:<rel>, UNPARSED, or NO. Relative tokens join the walk's
# logical directory, then .. is collapsed without following symlinks.
scope_walk_token_class() {
  local token="${1:-}" expanded joined relpath rel
  [ -n "$token" ] || { printf 'NO'; return 0; }
  case "$token" in
    -*) printf 'NO'; return 0 ;;
  esac
  # $HOME and ~/ are known spellings. Expand them before the unresolved
  # variable check, or ln -sfn "$HOME" is refused as unparsed.
  case "$token" in
    '~'|'~/'*|'$HOME'|'$HOME/'*|'${HOME}'|'${HOME}/'*)
      token="$(scope_expand_home_spell "$token")"
      ;;
    '$'*|'${'*)
      if expanded="$(scope_walk_lookup_assign "$token")"; then
        token="$expanded"
      else
        printf 'UNPARSED'
        return 0
      fi
      ;;
  esac
  case "$token" in
    *'$'*|*'`'*|*'('*|*')'*|*';'*|*'&'*|*[|]*|*[*]*|*[?]*|*[[]*|*' '*|*'"'*)
      printf 'UNPARSED'
      return 0
      ;;
  esac
  expanded="$(scope_expand_home_spell "$token")"
  case "$expanded" in
    /*)
      joined="$(scope_lexical_normalize "$expanded")"
      ;;
    *)
      if [ "${SCOPE_WALK_CWD_KNOWN:-1}" -ne 1 ]; then
        printf 'UNPARSED'
        return 0
      fi
      joined="$(scope_lexical_normalize "${SCOPE_WALK_LOGICAL%/}/$expanded")"
      ;;
  esac
  case "$joined" in
    "$HQ_ROOT"/*) relpath="${joined#"$HQ_ROOT"/}" ;;
    *) printf 'NO'; return 0 ;;
  esac
  if rel="$(scope_repos_rel_of_token "$relpath")"; then
    printf 'REPOS:%s' "$rel"
  else
    printf 'NO'
  fi
}

scope_walk_inside_any() {
  local path="${1:-}" root
  path="${path%/}"
  [ -n "$path" ] || return 1
  [ -n "${SCOPE_WALK_REPO_ROOTS:-}" ] || return 1
  while IFS= read -r root || [ -n "$root" ]; do
    [ -n "$root" ] || continue
    if scope_path_inside "$path" "$root"; then
      return 0
    fi
  done <<< "$SCOPE_WALK_REPO_ROOTS"
  return 1
}

scope_walk_note_entry() {
  local logical="${1:-}" rel link root
  case "$logical" in
    "$HQ_ROOT"/*) rel="${logical#"$HQ_ROOT"/}" ;;
    *) return 0 ;;
  esac
  link="$(scope_repo_link_rel "$rel")"
  [ -n "$link" ] || return 0
  if [ -L "$HQ_ROOT/$link" ] && [ -d "$HQ_ROOT/$link" ]; then
    root="$(scope_resolve_absolute_path "$HQ_ROOT/$link" 2>/dev/null || true)"
    [ -n "$root" ] && [ "$root" != "/" ] || return 0
    root="${root%/}"
    case "
${SCOPE_WALK_REPO_ROOTS:-}" in
      *"
$root
"*) ;;
      *) SCOPE_WALK_REPO_ROOTS="${SCOPE_WALK_REPO_ROOTS:-}${root}"$'\n' ;;
    esac
    SCOPE_WALK_SAW_REPO=1
  fi
}

scope_walk_apply_cd() {
  local dest="${1:-}" logical physical was=0
  [ "${SCOPE_WALK_CWD_KNOWN:-1}" -eq 1 ] || return 0
  if [ -z "$dest" ]; then
    dest="${HOME:-}"
    [ -n "$dest" ] || { SCOPE_WALK_CWD_KNOWN=0; return 0; }
  fi
  case "$dest" in
    '$'*|'${'*|-) SCOPE_WALK_CWD_KNOWN=0; return 0 ;;
  esac
  dest="$(scope_expand_home_spell "$dest")"
  if scope_walk_inside_any "$SCOPE_WALK_PHYSICAL"; then
    was=1
  fi
  case "$dest" in
    /*) logical="$(scope_lexical_normalize "$dest")" ;;
    *) logical="$(scope_lexical_normalize "${SCOPE_WALK_LOGICAL%/}/$dest")" ;;
  esac
  case "$dest" in
    /*) physical="$(scope_resolve_absolute_path "$dest" 2>/dev/null || true)" ;;
    *) physical="$(scope_resolve_absolute_path "${SCOPE_WALK_PHYSICAL%/}/$dest" 2>/dev/null || true)" ;;
  esac
  [ -n "$physical" ] || physical="$logical"
  if scope_walk_has_dotdot "$dest" && [ "$was" -eq 1 ]; then
    if scope_walk_inside_any "$physical"; then
      SCOPE_WALK_DOTDOT_INSIDE=1
    else
      scope_block_rel "$dest" "a relative path after cd leaves the repo symlink target"
    fi
  fi
  SCOPE_WALK_LOGICAL="$logical"
  SCOPE_WALK_PHYSICAL="$physical"
  scope_walk_note_entry "$logical"
}

scope_walk_check_escape() {
  local token="${1:-}" physical expanded
  scope_walk_has_dotdot "$token" || return 0
  [ "${SCOPE_WALK_CWD_KNOWN:-1}" -eq 1 ] || return 0
  scope_walk_inside_any "$SCOPE_WALK_PHYSICAL" || return 0
  expanded="$(scope_expand_home_spell "$token")"
  case "$expanded" in
    /*) physical="$(scope_resolve_absolute_path "$expanded" 2>/dev/null || true)" ;;
    *) physical="$(scope_resolve_absolute_path "${SCOPE_WALK_PHYSICAL%/}/$expanded" 2>/dev/null || true)" ;;
  esac
  [ -n "$physical" ] || scope_block_rel "$token" "a relative path after cd leaves the repo symlink target"
  if scope_walk_inside_any "$physical"; then
    SCOPE_WALK_DOTDOT_INSIDE=1
  else
    scope_block_rel "$token" "a relative path after cd leaves the repo symlink target"
  fi
}

scope_walk_add_dest() {
  local rel="${1:-}"
  [ -n "$rel" ] || return 0
  if [ -n "${SCOPE_WALK_ONE_DEST:-}" ] && [ "$SCOPE_WALK_ONE_DEST" != "$rel" ]; then
    scope_block_rel "$rel" "a command that creates, removes, or repoints a repo symlink cannot also use a path under repos/"
  fi
  SCOPE_WALK_ONE_DEST="$rel"
  case "
${SCOPE_LINK_MUTATION_DESTS:-}" in
    *"
$rel
"*) ;;
    *) SCOPE_LINK_MUTATION_DESTS="${SCOPE_LINK_MUTATION_DESTS:-}${rel}"$'\n' ;;
  esac
  SCOPE_WALK_MUTATION=1
  SCOPE_WALK_THIS_DESTS="${SCOPE_WALK_THIS_DESTS:-}${rel}"$'\n'
}

scope_walk_note_use() {
  local rel="${1:-}"
  [ -n "$rel" ] || return 0
  case "
${SCOPE_WALK_THIS_DESTS:-}" in
    *"
$rel
"*) return 0 ;;
  esac
  if [ "${SCOPE_WALK_MUTATION:-0}" -eq 1 ]; then
    scope_block_rel "$rel" "a command that creates, removes, or repoints a repo symlink cannot also use a path under repos/"
  fi
  case "
${SCOPE_LINK_MUTATION_SEEN:-}" in
    *"
$rel
"*) ;;
    *) SCOPE_LINK_MUTATION_SEEN="${SCOPE_LINK_MUTATION_SEEN:-}${rel}"$'\n' ;;
  esac
}

scope_walk_refuse() {
  scope_block_rel "${1:-repos}" "a command that changes a repo symlink could not be checked, so it is refused"
}

# Text after a symlink/rename call. Prints LIT:path, VAR:name, or FAIL.
scope_walk_second_arg() {
  local rest="${1:-}" i=0 n c quote="" arg="" which=1 depth=0 quoted=0
  n=${#rest}
  while [ "$i" -lt "$n" ]; do
    c="${rest:$i:1}"
    case "$c" in
      [[:space:]]) i=$((i + 1)); continue ;;
      *) break ;;
    esac
  done
  [ "${rest:$i:1}" = "(" ] || { printf 'FAIL'; return 0; }
  i=$((i + 1))
  depth=1
  while [ "$i" -lt "$n" ]; do
    c="${rest:$i:1}"
    if [ -n "$quote" ]; then
      if [ "$c" = "$quote" ]; then
        quote=""
      else
        arg="${arg}${c}"
      fi
      i=$((i + 1))
      continue
    fi
    case "$c" in
      '"'|"'")
        if [ -z "$arg" ] && [ "$which" -eq 2 ]; then
          quoted=1
        fi
        quote="$c"
        ;;
      '(')
        depth=$((depth + 1))
        arg="${arg}${c}"
        ;;
      ')')
        depth=$((depth - 1))
        if [ "$depth" -eq 0 ]; then
          if [ "$which" -ne 2 ]; then
            printf 'FAIL'
          elif [ "$quoted" -eq 1 ]; then
            printf 'LIT:%s' "$arg"
          else
            printf 'VAR:%s' "$arg"
          fi
          return 0
        fi
        arg="${arg}${c}"
        ;;
      ',')
        if [ "$depth" -eq 1 ]; then
          if [ "$which" -eq 1 ]; then
            which=2
            arg=""
            quoted=0
          elif [ "$quoted" -eq 1 ]; then
            printf 'LIT:%s' "$arg"
            return 0
          else
            printf 'VAR:%s' "$arg"
            return 0
          fi
        else
          arg="${arg}${c}"
        fi
        ;;
      [[:space:]]) ;;
      *) arg="${arg}${c}" ;;
    esac
    i=$((i + 1))
  done
  printf 'FAIL'
}

scope_walk_script_body() {
  local body="${1:-}" kind="${2:-}" needle dest path class rel
  local needles
  case "$body" in
    *'$'*|*'`'*)
      case "$body" in
        *symlink*|*os.rename*|*os.link*|*os.replace*|*renameSync*|*linkSync*)
          scope_walk_refuse "$kind"
          ;;
      esac
      return 0
      ;;
  esac
  if [ "$kind" = "python" ]; then
    needles="os.symlink os.rename os.link os.replace"
  else
    needles="symlinkSync renameSync linkSync"
  fi
  for needle in $needles; do
    case "$body" in
      *"$needle"*) ;;
      *) continue ;;
    esac
    dest="$(scope_walk_second_arg "${body#*"$needle"}")"
    case "$dest" in
      FAIL|VAR:*) scope_walk_refuse "$needle" ;;
    esac
    path="${dest#LIT:}"
    class="$(scope_walk_token_class "$path")"
    case "$class" in
      UNPARSED) scope_walk_refuse "$needle" ;;
      REPOS:*)
        rel="${class#REPOS:}"
        case "$needle" in
          os.symlink|os.link|symlinkSync|linkSync)
            scope_walk_add_dest "$rel"
            ;;
          *)
            if scope_repos_rel_is_link_node "$rel"; then
              scope_walk_add_dest "$rel"
            fi
            ;;
        esac
        ;;
    esac
  done
}

scope_walk_parse() {
  printf '%s\n' "$1" | awk '
    function push_word() { if (word != "") { argv[++argc] = word; word = "" } }
    function emit(    j, out) {
      push_word()
      if (argc == 0) return
      out = argv[1]
      for (j = 2; j <= argc; j++) out = out sprintf("%c", 31) argv[j]
      print out
      for (j in argv) delete argv[j]
      argc = 0
    }
    { source = source $0 "\n" }
    END {
      text = source
      n = length(text); quote = ""; escaped = 0; word = ""; argc = 0
      for (i = 1; i <= n; i++) {
        c = substr(text, i, 1)
        if (escaped) { word = word c; escaped = 0; continue }
        if (quote == "\047") {
          if (c == "\047") quote = ""; else word = word c
          continue
        }
        if (quote == "\"") {
          if (c == "\"") quote = ""
          else if (c == "\\") escaped = 1
          else word = word c
          continue
        }
        if (c == "\047" || c == "\"") { quote = c; continue }
        if (c == "\\") { escaped = 1; continue }
        if (c == " " || c == "\t") { push_word(); continue }
        if (c == ";" || c == "|" || c == "&" || c == "\n" || c == "(" || c == ")") {
          emit()
          if (c == "(" || c == ")") printf "%c%s\n", 30, c
          if ((c == "|" || c == "&") && substr(text, i + 1, 1) == c) i++
          continue
        }
        if (c == ">" || c == "<") {
          push_word(); argv[++argc] = c
          if (substr(text, i + 1, 1) == c || (c == ">" && substr(text, i + 1, 1) == "|")) {
            argv[argc] = argv[argc] substr(text, i + 1, 1); i++
          }
          continue
        }
        word = word c
      }
      emit()
    }
  '
}

scope_walk_one() {
  local record="${1:-}" depth="${2:-0}"
  local -a argv words redirs
  local i n tok exe="" exe_at=0 dest="" last="" class="" rel="" body=""
  local symlink=0 rsync_links=0 cluster kind=""
  argv=()
  words=()
  redirs=()
  IFS=$'\037' read -r -a argv <<< "$record" || true
  n=${#argv[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    tok="${argv[$i]}"
    case "$tok" in
      '>'|'>>'|'<'|'<<'|'>|'|'>&'|'&>'|'<>')
        i=$((i + 1))
        if [ "$i" -lt "$n" ]; then
          redirs+=("${argv[$i]}")
        fi
        ;;
      *) words+=("$tok") ;;
    esac
    i=$((i + 1))
  done
  SCOPE_WALK_THIS_DESTS=""
  n=${#words[@]}
  # The program word, past leading assignments, for the owner-roots check:
  # a wrapper (sudo, env, command, ...) is left as the head, so a command
  # run through one gets no read-only allowance there.
  local walk_head=""
  i=0
  while [ "$i" -lt "$n" ]; do
    tok="${words[$i]}"
    if [[ "$tok" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      i=$((i + 1))
      continue
    fi
    walk_head="${tok//[\"\'\\]/}"
    walk_head="${walk_head##*/}"
    break
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    tok="${words[$i]}"
    case "$tok" in
      -*) ;;
      *) scope_owner_roots_consider "$tok" "$SCOPE_WALK_LOGICAL" "$walk_head" ;;
    esac
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#redirs[@]}" ]; do
    scope_owner_roots_consider "${redirs[$i]}" "$SCOPE_WALK_LOGICAL"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    tok="${words[$i]}"
    if [[ "$tok" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      scope_walk_record_assign "$tok"
      i=$((i + 1))
      continue
    fi
    case "$tok" in
      command|builtin|exec|nohup)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          tok="${words[$i]}"
          case "$tok" in
            -*) i=$((i + 1)); continue ;;
            *) break ;;
          esac
        done
        continue
        ;;
      env)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          tok="${words[$i]}"
          if [[ "$tok" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            scope_walk_record_assign "$tok"
            i=$((i + 1))
            continue
          fi
          case "$tok" in
            -u|-C|-S)
              i=$((i + 1))
              [ "$i" -lt "$n" ] && i=$((i + 1))
              continue
              ;;
            -*) i=$((i + 1)); continue ;;
            *) break ;;
          esac
        done
        continue
        ;;
      sudo|doas)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          tok="${words[$i]}"
          case "$tok" in
            -u|-g)
              i=$((i + 1))
              [ "$i" -lt "$n" ] && i=$((i + 1))
              continue
              ;;
            -*) i=$((i + 1)); continue ;;
            *) break ;;
          esac
        done
        continue
        ;;
      *) break ;;
    esac
  done
  exe_at=$i
  if [ "$exe_at" -ge "$n" ]; then
    return 0
  fi
  exe="${words[$exe_at]}"
  case "$exe" in
    '$'*|'${'*)
      if class="$(scope_walk_lookup_assign "$exe")"; then
        exe="$class"
      else
        return 0
      fi
      ;;
  esac
  exe="${exe##*/}"
  case "$exe" in
    cd|pushd)
      dest=""
      i=$((exe_at + 1))
      while [ "$i" -lt "$n" ]; do
        tok="${words[$i]}"
        case "$tok" in
          --)
            i=$((i + 1))
            [ "$i" -lt "$n" ] && dest="${words[$i]}"
            break
            ;;
          -*) i=$((i + 1)); continue ;;
          *) dest="$tok"; break ;;
        esac
      done
      scope_walk_apply_cd "$dest"
      return 0
      ;;
    popd)
      SCOPE_WALK_CWD_KNOWN=0
      return 0
      ;;
  esac
  i=$((exe_at + 1))
  while [ "$i" -lt "$n" ]; do
    tok="${words[$i]}"
    case "$tok" in
      -*) ;;
      *) scope_walk_check_escape "$tok" ;;
    esac
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#redirs[@]}" ]; do
    scope_walk_check_escape "${redirs[$i]}"
    i=$((i + 1))
  done
  case "$exe" in
    ln|cp)
      symlink=0
      i=0
      while [ "$i" -lt "$n" ]; do
        tok="${words[$i]}"
        case "$tok" in
          --symbolic|--symbolic-link|--symbolic=*|--symbolic-link=*) symlink=1 ;;
          --*) ;;
          -*s*) symlink=1 ;;
        esac
        i=$((i + 1))
      done
      if [ "$symlink" -eq 1 ]; then
        last=""
        i=$((exe_at + 1))
        while [ "$i" -lt "$n" ]; do
          tok="${words[$i]}"
          case "$tok" in
            --) i=$((i + 1)); continue ;;
            -*) i=$((i + 1)); continue ;;
          esac
          class="$(scope_walk_token_class "$tok")"
          case "$class" in
            UNPARSED) scope_walk_refuse "$exe" ;;
          esac
          last="$tok"
          i=$((i + 1))
        done
        if [ -n "$last" ]; then
          class="$(scope_walk_token_class "$last")"
          case "$class" in
            REPOS:*) scope_walk_add_dest "${class#REPOS:}" ;;
          esac
        fi
      fi
      ;;
    unlink)
      i=$((exe_at + 1))
      while [ "$i" -lt "$n" ]; do
        tok="${words[$i]}"
        case "$tok" in
          -*) i=$((i + 1)); continue ;;
        esac
        class="$(scope_walk_token_class "$tok")"
        case "$class" in
          UNPARSED) scope_walk_refuse "$exe" ;;
          REPOS:*) scope_walk_add_dest "${class#REPOS:}" ;;
        esac
        i=$((i + 1))
      done
      ;;
    rm|mv|rmdir|install)
      i=$((exe_at + 1))
      while [ "$i" -lt "$n" ]; do
        tok="${words[$i]}"
        case "$tok" in
          --) i=$((i + 1)); continue ;;
          -*)
            case "$tok" in
              --target-directory=*) ;;
              -t|-S|-T|--target-directory|--suffix) i=$((i + 1)) ;;
            esac
            i=$((i + 1))
            continue
            ;;
        esac
        class="$(scope_walk_token_class "$tok")"
        case "$class" in
          REPOS:*)
            rel="${class#REPOS:}"
            if scope_repos_rel_is_link_node "$rel"; then
              scope_walk_add_dest "$rel"
            fi
            ;;
        esac
        i=$((i + 1))
      done
      ;;
    rsync)
      rsync_links=0
      i=0
      while [ "$i" -lt "$n" ]; do
        tok="${words[$i]}"
        case "$tok" in
          --links|--archive) rsync_links=1 ;;
          --copy-links|--safe-links|--hard-links) ;;
          --*) ;;
          -*)
            cluster="${tok#-}"
            case "$cluster" in
              *l*|*a*) rsync_links=1 ;;
            esac
            ;;
        esac
        i=$((i + 1))
      done
      if [ "$rsync_links" -eq 1 ]; then
        last=""
        i=$((exe_at + 1))
        while [ "$i" -lt "$n" ]; do
          tok="${words[$i]}"
          case "$tok" in
            --) i=$((i + 1)); continue ;;
            -*) i=$((i + 1)); continue ;;
          esac
          last="$tok"
          i=$((i + 1))
        done
        if [ -n "$last" ]; then
          class="$(scope_walk_token_class "$last")"
          case "$class" in
            UNPARSED) scope_walk_refuse "$exe" ;;
            REPOS:*)
              rel="${class#REPOS:}"
              if scope_repos_rel_is_link_node "$rel"; then
                scope_walk_add_dest "$rel"
              fi
              ;;
          esac
        fi
      fi
      ;;
    xargs)
      dest=""
      i=$((exe_at + 1))
      while [ "$i" -lt "$n" ]; do
        tok="${words[$i]}"
        case "$tok" in
          -*) i=$((i + 1)); continue ;;
          *) dest="${tok##*/}"; break ;;
        esac
      done
      case "$dest" in
        ln|cp|mv|rm|rmdir|install|rsync|unlink|python|python[0-9]*|node|nodejs)
          scope_walk_refuse "$dest"
          ;;
      esac
      ;;
    bash|sh)
      body=""
      i=$((exe_at + 1))
      while [ "$i" -lt "$n" ]; do
        tok="${words[$i]}"
        case "$tok" in
          -c)
            i=$((i + 1))
            [ "$i" -lt "$n" ] && body="${words[$i]}"
            break
            ;;
        esac
        i=$((i + 1))
      done
      if [ -n "$body" ]; then
        case "$body" in
          *'$'*|*'`'*)
            case "$body" in
              *ln*|*symlink*|*rsync*|*install*) scope_walk_refuse "$exe" ;;
            esac
            ;;
          *)
            if [ "$depth" -ge 4 ]; then
              case "$body" in
                *ln*|*symlink*|*rsync*|*install*) scope_walk_refuse "$exe" ;;
              esac
            else
              scope_walk_push_frame
              SCOPE_WALK_ASSIGNS=""
              scope_walk_commands "$body" $((depth + 1))
              scope_walk_pop_frame
            fi
            ;;
        esac
      fi
      ;;
    python|python[0-9]*|node|nodejs)
      body=""
      kind="python"
      case "$exe" in
        node|nodejs) kind="node" ;;
      esac
      i=$((exe_at + 1))
      while [ "$i" -lt "$n" ]; do
        tok="${words[$i]}"
        case "$tok" in
          -c|-e)
            i=$((i + 1))
            [ "$i" -lt "$n" ] && body="${words[$i]}"
            break
            ;;
        esac
        i=$((i + 1))
      done
      if [ -n "$body" ]; then
        scope_walk_script_body "$body" "$kind"
      fi
      ;;
  esac
  # A repos path in this command is a use, except a destination recorded above.
  # bash -c already walked its body; the body word itself is not one path.
  case "$exe" in
    bash|sh) ;;
    *)
      i=$((exe_at + 1))
      while [ "$i" -lt "$n" ]; do
        tok="${words[$i]}"
        case "$tok" in
          -*) i=$((i + 1)); continue ;;
        esac
        class="$(scope_walk_token_class "$tok")"
        case "$class" in
          REPOS:*) scope_walk_note_use "${class#REPOS:}" ;;
        esac
        i=$((i + 1))
      done
      ;;
  esac
  i=0
  while [ "$i" -lt "${#redirs[@]}" ]; do
    class="$(scope_walk_token_class "${redirs[$i]}")"
    case "$class" in
      REPOS:*) scope_walk_note_use "${class#REPOS:}" ;;
    esac
    i=$((i + 1))
  done
  return 0
}

scope_walk_commands() {
  local cmd="${1:-}" depth="${2:-0}" segments record
  [ -n "$cmd" ] || return 0
  [ "$depth" -le 4 ] || return 0
  segments="$(scope_walk_parse "$cmd" || true)"
  while IFS= read -r record || [ -n "$record" ]; do
    [ -n "$record" ] || continue
    case "$record" in
      $'\036'*)
        case "$record" in
          $'\036(') scope_walk_push_frame ;;
          $'\036)') scope_walk_pop_frame ;;
        esac
        ;;
      *) scope_walk_one "$record" "$depth" ;;
    esac
  done <<< "$segments"
}

scope_note_repo_link_mutations() {
  local cmd="${1:-}" seen phys
  SCOPE_LINK_MUTATION_DESTS=""
  SCOPE_LINK_MUTATION_SEEN=""
  SCOPE_WALK_MUTATION=0
  SCOPE_WALK_ONE_DEST=""
  SCOPE_WALK_THIS_DESTS=""
  SCOPE_WALK_LOGICAL="${PAYLOAD_CWD:-$HQ_ROOT}"
  SCOPE_WALK_PHYSICAL="$SCOPE_WALK_LOGICAL"
  SCOPE_WALK_ASSIGNS=""
  SCOPE_WALK_FRAMES=""
  SCOPE_WALK_SAW_REPO=0
  SCOPE_WALK_DOTDOT_INSIDE=0
  SCOPE_WALK_CWD_KNOWN=1
  SCOPE_WALK_REPO_ROOTS=""
  SCOPE_REPO_CD_HANDLED=0
  [ -n "$cmd" ] || return 0
  case "$SCOPE_WALK_PHYSICAL" in
    /*)
      phys="$(scope_resolve_absolute_path "$SCOPE_WALK_PHYSICAL" 2>/dev/null || true)"
      [ -n "$phys" ] && SCOPE_WALK_PHYSICAL="$phys"
      ;;
  esac
  scope_walk_commands "$cmd" 0
  if [ "${SCOPE_WALK_MUTATION:-0}" -eq 1 ]; then
    while IFS= read -r seen || [ -n "$seen" ]; do
      [ -n "$seen" ] || continue
      scope_block_rel "$seen" "a command that creates, removes, or repoints a repo symlink cannot also use a path under repos/"
    done <<< "${SCOPE_LINK_MUTATION_SEEN:-}"
  fi
  if [ "${SCOPE_WALK_SAW_REPO:-0}" -eq 1 ] \
    && [ "${SCOPE_WALK_DOTDOT_INSIDE:-0}" -eq 1 ] \
    && [ "${SCOPE_WALK_CWD_KNOWN:-1}" -eq 1 ]; then
    SCOPE_REPO_CD_HANDLED=1
  fi
}

# Prints allow, deny, or fallthrough. allow/deny apply only to a literal path
# through a repos/ symlink. An outside checkout is allowed only when its
# resolved directory is on the owner root list, the path stays inside that
# directory, and neither the directory nor the path is rejected or sensitive.
scope_registered_repo_decision() {
  local raw="${1:-}" rel_lex="" link_rel="" repo_root="" final="" backtick
  backtick=$'\140'
  [ -n "$raw" ] || { printf '%s' fallthrough; return 0; }
  raw="$(scope_canonicalize_repos_token "$raw")"
  case "$raw" in
    "$HQ_ROOT"/*) rel_lex="${raw#"$HQ_ROOT"/}" ;;
    /*) printf '%s' fallthrough; return 0 ;;
    *) rel_lex="$raw" ;;
  esac
  rel_lex="${rel_lex%/}"
  case "$rel_lex" in
    *'$'*|*"$backtick"*|*'('*|*'*'*|*'?'*|*'['*) printf '%s' fallthrough; return 0 ;;
  esac
  link_rel="$(scope_repo_link_rel "$rel_lex")"
  [ -n "$link_rel" ] || { printf '%s' fallthrough; return 0; }
  [ -L "$HQ_ROOT/$link_rel" ] && [ -d "$HQ_ROOT/$link_rel" ] || { printf '%s' fallthrough; return 0; }
  repo_root="$(scope_resolve_absolute_path "$HQ_ROOT/$link_rel" 2>/dev/null || true)"
  [ -n "$repo_root" ] && [ "$repo_root" != "/" ] || { printf '%s' deny; return 0; }
  repo_root="${repo_root%/}"
  case "$raw" in
    /*) final="$(scope_resolve_absolute_path "$raw" 2>/dev/null || true)" ;;
    *) final="$(scope_resolve_absolute_path "$HQ_ROOT/$raw" 2>/dev/null || true)" ;;
  esac
  [ -n "$final" ] || { printf '%s' deny; return 0; }
  final="${final%/}"
  if scope_repo_root_is_rejected "$repo_root" || scope_repo_root_is_rejected "$final"; then
    printf '%s' deny
    return 0
  fi
  if scope_link_path_is_sensitive "$repo_root" || scope_link_path_is_sensitive "$final"; then
    printf '%s' deny
    return 0
  fi
  case "$final" in
    "$HQ_ROOT"/companies|"$HQ_ROOT"/companies/*) printf '%s' deny; return 0 ;;
  esac
  if scope_owner_root_covers "$repo_root" && scope_path_inside "$final" "$repo_root"; then
    printf '%s' allow
    return 0
  fi
  case "$final" in
    "$HQ_ROOT"/repos/*|"$HQ_ROOT"/core/*|"$HQ_ROOT"/personal/*|"$HQ_ROOT"/workspace/*)
      printf '%s' fallthrough
      return 0
      ;;
  esac
  printf '%s' deny
}

scope_check_bash_skill_path() {
  local raw="${1:-}" command_text="${2:-}" prefix="${3:-}" suffix="${4:-}"
  local masked raw_masked backtick token rel resolved expansion_cwd expanded expanded_raw open_tree_candidate
  [ -n "$raw" ] || return 0
  # Shell assignment words can themselves carry paths. Check those values,
  # while leaving basename-style parameter transforms such as ${id##*/} alone.
  if [[ "$raw" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    expanded="${raw#*=}"
    case "$expanded" in
      \"*\") expanded="${expanded:1:${#expanded}-2}" ;;
      \'*\') expanded="${expanded:1:${#expanded}-2}" ;;
    esac
    expanded="$(scope_canonicalize_repos_token "$expanded")"
    case "$expanded" in
      workspace/*|core/*|personal/*|repos/*|companies/*|/*|./*|../*|~/*)
        scope_check_bash_skill_path "$expanded" "$command_text" "$prefix" "$suffix"
        return 0
        ;;
      *) return 0 ;;
    esac
  fi
  if [ -z "$prefix" ] && [ "${scope_occurrence_explicit:-0}" -eq 0 ] && [[ "$command_text" == *"$raw"* ]]; then
    prefix="${command_text%%"$raw"*}"
    suffix="${command_text#*"$raw"}"
    # The same text can occur more than once (`echo 'x/$D'; cat x/$D`). The
    # first occurrence alone would decide quoting and assignment order for
    # every one of them, so check each occurrence with its own context.
    if [[ "$suffix" == *"$raw"* ]]; then
      local occurrence_rest="$command_text" occurrence_offset=0 occurrence_pre
      while [[ "$occurrence_rest" == *"$raw"* ]]; do
        occurrence_pre="${occurrence_rest%%"$raw"*}"
        occurrence_offset=$((occurrence_offset + ${#occurrence_pre}))
        scope_occurrence_explicit=1 scope_check_bash_skill_path "$raw" "$command_text" \
          "${command_text:0:$occurrence_offset}" "${command_text:$((occurrence_offset + ${#raw}))}"
        occurrence_offset=$((occurrence_offset + ${#raw}))
        occurrence_rest="${command_text:$occurrence_offset}"
      done
      return 0
    fi
  fi
  # `"$D"/*.md`, `"$D/"*.md`: the tokenizer drops the quotes, so the word
  # `$D/*.md` is not in the command text and the use site (which decides
  # whether `D=...` ran before it) was never found. Locate the quoted
  # spelling and take the text before its opening quote as the prefix. Only
  # a leading `$NAME` / `${NAME}` followed by `/` qualifies; the resolved
  # path, glob included, is then checked like the unquoted form.
  if [ -z "$prefix" ] && [ "${scope_occurrence_explicit:-0}" -eq 0 ] \
    && [[ "$command_text" != *"$raw"* ]] \
    && [[ "$raw" =~ ^(\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?)(/.*)$ ]]; then
    local quoted_var="${BASH_REMATCH[1]}" quoted_rest="${BASH_REMATCH[3]}" quoted_form
    for quoted_form in "\"$quoted_var\"$quoted_rest" "\"$quoted_var/\"${quoted_rest#/}"; do
      if [[ "$command_text" == *"$quoted_form"* ]]; then
        prefix="${command_text%%"$quoted_form"*}"
        suffix="${command_text#*"$quoted_form"}"
        break
      fi
    done
  fi
  scope_candidate_is_inert_text "$raw" "$command_text" "$prefix" "$suffix" && return 0
  case "$raw" in */*|/*) ;; *) return 0 ;; esac
  # The shell opens a relative path from its working directory, not from
  # HQ_ROOT. When the payload cwd (or a followed cd) is somewhere else, such
  # as inside a company folder or behind a symlink, also check the literal
  # path from there: `cat ../otherco/x` with cwd companies/<bound> opens the
  # other tenant (feedback_ef130236). This only adds refusals.
  case "$raw" in
    /*|'~'*|*['$*?[{`']*) ;;
    *)
      case "${COMMAND_CWD:-}" in
        "$HQ_ROOT"|"$HQ_ROOT/"|'') ;;
        /*) scope_check_cwd_abs "${COMMAND_CWD%/}/$raw" ;;
      esac
      ;;
  esac
  raw="$(scope_canonicalize_repos_token "$raw")"
  # A link being created or removed in this command is a repos/ path, not a
  # read of whatever the link points at now. The same-command check already
  # refused any other repos/ use.
  scope_path_is_repo_link_mutation_dest "$raw" && return 0
  scope_cd_dotdot_checked "$raw" && return 0
  # A command substitution stays fail-closed. Its VALUE is the program's
  # stdout, which no static check can bound, and scanning the inner command
  # instead does not help: `"$(printf %s companies / otherco /settings/x)"`
  # has four individually harmless operands that the shell concatenates into
  # one cross-company path. A long argument that needs a substitution belongs
  # in a file the callee reads by literal path.
  #
  # These three forms have the same value as the shell's command cwd. Resolve
  # only the exact leading spellings; any other substitution in the remaining
  # path is checked normally and stays fail-closed when it cannot be resolved.
  #
  # The same value also leads a `file://` URL (`chrome --print-to-pdf=x
  # "file://$PWD/a.html"`) and the value of a `--name=` option
  # (`--print-to-pdf="$PWD/a.pdf"`); both name the file at the expanded path,
  # so the leading option name and URL scheme are dropped and the path is
  # checked as if typed. When the command changes directory after the point
  # the hook follows (scope_cwd_is_static), $PWD is no longer COMMAND_CWD and
  # the form stays closed.
  local pwd_word_re='^(--[A-Za-z0-9][A-Za-z0-9_.-]*=)?(file://)?(\$PWD|\$\{PWD\}|\$\(pwd\)|\$\(pwd -P\)|`pwd`|`pwd -P`)/'
  # A leading `$(git rev-parse --show-toplevel)/` is the git work tree that
  # holds the command's cwd. It is worked out the way scope_git_toplevel_value
  # looks it up (git asked here, in that cwd), when nothing in the command can
  # move the cwd or redirect git: no cd the hook did not follow, no GIT_*
  # variable or git config in the command text or the environment, and git
  # not run from inside HQ. The mapped path is then checked as if typed.
  local toplevel_word_re='^(--[A-Za-z0-9][A-Za-z0-9_.-]*=)?(\$\(git rev-parse --show-toplevel\)|`git rev-parse --show-toplevel`)/'
  if [[ "$raw" =~ $toplevel_word_re ]]; then
    local toplevel_match="${BASH_REMATCH[0]}" toplevel_value="" toplevel_bin
    if [ "${scope_cwd_is_static:-1}" -eq 1 ] \
      && [ -z "${GIT_DIR:-}${GIT_WORK_TREE:-}${GIT_CONFIG_PARAMETERS:-}" ] \
      && ! [[ "$command_text" =~ (GIT_[A-Z_]*=|git[[:space:]]+(-c|config)([[:space:]]|$)|--git-dir|--work-tree) ]]; then
      toplevel_bin="$(command -v git 2>/dev/null || true)"
      case "$toplevel_bin" in
        "$HQ_ROOT"|"$HQ_ROOT"/*) ;;
        /*)
          case "${COMMAND_CWD:-}" in
            /*) toplevel_value="$(git -C "$COMMAND_CWD" rev-parse --show-toplevel 2>/dev/null)" || toplevel_value="" ;;
          esac
          ;;
      esac
    fi
    case "$toplevel_value" in
      /*) case "$toplevel_value" in *$'\n'*|*'..'*|*'$'*|*'`'*) toplevel_value="" ;; esac ;;
      *) toplevel_value="" ;;
    esac
    [ -n "$toplevel_value" ] \
      || scope_block_rel "$raw" "the repo top level cannot be worked out for this command; spell the path literally"
    toplevel_value="$(cd "$toplevel_value" 2>/dev/null && pwd -P)" \
      || scope_block_rel "$raw" "the repo top level cannot be worked out for this command; spell the path literally"
    scope_check_bash_candidate_inner "$toplevel_value/${raw#"$toplevel_match"}" "$command_text" 0 "" "$prefix" "$suffix"
    return 0
  fi
  if [[ "$raw" =~ $pwd_word_re ]]; then
    local pwd_word_match="${BASH_REMATCH[0]}" pwd_word_form="${BASH_REMATCH[3]}"
    [ "${scope_cwd_is_static:-1}" -eq 1 ] \
      || scope_block_rel "$raw" "the command changes directory, so \$PWD or \$(pwd) is not the directory the hook can check; spell the path literally"
    # $(pwd) asks the shell, but $PWD is a variable the same command can set
    # (`mapfile -t PWD < f`), and then it is not the directory checked here.
    case "$pwd_word_form" in
      '$PWD'|'${PWD}')
        ! scope_command_may_set_var PWD "$command_text" \
          || scope_block_rel "$raw" "the command may set \$PWD, so it is not the directory the hook can check; spell the path literally"
        ;;
    esac
    expansion_cwd="$(cd "$COMMAND_CWD" 2>/dev/null && pwd -P)" \
      || scope_block_rel "$raw" "the command working directory cannot be resolved"
    expanded="$expansion_cwd/${raw#"$pwd_word_match"}"
    scope_check_bash_candidate_inner "$expanded" "$command_text" 0 "" "$prefix" "$suffix"
    return 0
  fi
  # Any other substitution stays closed BEFORE lexical normalization: a `..`
  # after the substitution's opening text would otherwise pop it away
  # (`"x $(printf %s /../companies / otherco /new)"` normalized to a
  # harmless-looking `companies / otherco /new)`).
  case "$raw" in
    *'$('*|*$'\140'*)
      scope_check_bash_candidate_inner "$raw" "$command_text" 0 "" "$prefix" "$suffix"
      return 0
      ;;
  esac
  expanded_raw="$(scope_resolve_resumework_basename_value "$raw" "$command_text")"
  expanded_raw="$(scope_resolve_known_path_expansions "$expanded_raw" "$command_text" "$prefix")"
  rel="$(scope_normalize_hq_relative "$expanded_raw")"
  raw_masked="$(scope_mask_literal_expansions "$expanded_raw")"
  case "$raw_masked" in
    workspace/*|core/*|personal/*|repos/*)
      case "$raw_masked:$rel" in
        workspace/*:workspace/*|core/*:core/*|personal/*:personal/*|repos/*:repos/*) ;;
        *)
          case "$(scope_registered_repo_decision "$expanded_raw")" in
            allow) return 0 ;;
            deny) scope_block_rel "$raw" "a path through a repo symlink is not an owner-listed checkout, leaves that checkout, enters another company, or hits a sensitive path" ;;
          esac
          [ -n "$rel" ] || scope_block_rel "$raw" "an expanded path leaves the HQ root"
          scope_check_rel "$rel"
          ;;
      esac
      ;;
  esac
  masked="$(scope_mask_literal_expansions "$rel")"
  backtick=$'\140'
  # Paths rooted in HQ's explicitly open trees remain in those trees when a
  # filename component is supplied by a shell variable. Company paths are
  # handled by the stricter company-aware scanner above; an unresolved company
  # segment must still fail closed.
  case "$masked" in
    workspace/*|core/*|personal/*|repos/*)
      case "$masked" in
        *'$'*|*"$backtick"*)
          case "$raw" in
            *'..'*) scope_block_rel "$raw" "a path expansion can traverse outside an allowed HQ tree" ;;
          esac
          if scope_open_tree_expansion_has_parent_value "$raw" "$command_text"; then
            scope_block_rel "$raw" "a path variable contains parent traversal"
          fi
          # A proven absolute prefix (`W=/abs/hq/workspace/worktrees; ...
          # $W/$n`) lands in the same open tree as its HQ-relative form, which
          # the confinement checks below expect. The variable part is left in
          # place by the normalization and still has to be proven there.
          open_tree_candidate="$expanded_raw"
          case "$expanded_raw" in
            "$HQ_ROOT"/*)
              case "$rel" in
                workspace/*|core/*|personal/*|repos/*) open_tree_candidate="$rel" ;;
              esac
              ;;
          esac
          if scope_open_tree_expansion_is_provably_confined "$open_tree_candidate" "$prefix"; then
            return 0
          fi
          # A `for` loop or assignment can bound the variable to literal
          # values. Substitute each one and check the resulting literal paths;
          # an unresolved variable still fails closed below.
          if scope_open_tree_expansion_values_resolve "$open_tree_candidate" "$prefix" "$command_text"; then
            scope_check_bash_candidate_inner "$expanded_raw" "$command_text" 0 "" "$prefix" "$suffix"
            return 0
          fi
          scope_block_rel "$raw" "an open-tree path expansion is not provably confined"
          ;;
      esac
      ;;
  esac
  case "$masked" in
    *'$('|*"$backtick"*|*'$'*)
      # Resolve assignments, bounded loop values, and literal positional
      # arguments at known function call sites. Any unresolved path stays
      # blocked and is reported by its own literal path.
      scope_check_bash_candidate_inner "$raw" "$command_text" 0 "" "$prefix" "$suffix"
      return 0
      ;;
  esac
  scope_candidate_is_single_quoted "$raw" "$prefix" && {
    resolved="$(scope_resolve_rel_symlinks "$rel")"
    scope_check_rel "$resolved"
    return 0
  }
  token="$(printf '%s' "$masked" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' 2>/dev/null | head -n 1 || true)"
  [ -z "$token" ] || return 0
  case "$masked" in
    *'*'*|*'?'*|*'['*)
      # A glob whose path only lands under companies/ after a variable was
      # substituted or `..` was normalized (`D=companies/a/k; ls $D/../../b/*`)
      # never reaches the companies/ text scan. Expand it and check every
      # match, as for a literal companies/ glob.
      case "$rel" in
        companies|companies/*)
          scope_check_bash_candidate_inner "$HQ_ROOT/$rel" "$command_text" 0 "" "" ""
          ;;
      esac
      return 0
      ;;
  esac
  resolved="$(scope_resolve_rel_symlinks "$rel")"
  scope_check_rel "$resolved"
}

# Unquoted command substitutions in command arguments.
#
# `cat $(cat /tmp/p)` and `cp x $(cat /tmp/p)` read or write whatever path the
# file holds, and the guard cannot see that path. The path scans below miss
# the unquoted form: the tokenizer splits `$(cat /tmp/p)` into `$(cat` and
# `/tmp/p)`, so no single word carries the substitution. A file holding
# another company's path would let the command reach that company's files.
#
# This check reads the raw command, finds every word with a $(...) or `...`
# outside quotes, and blocks it in an argument or redirection position unless
#   - the body prints something that is not a path, or the command's own
#     working directory (scope_subst_body_is_safe: pwd, the repo top level,
#     date, git rev-parse/merge-base/rev-list --count/branch --show-current,
#     nproc, id, whoami, hostname, uname, seq, pgrep, docker ps -q), or
#   - the command takes no file arguments (kill, sleep, wait, [, [[, test,
#     seq, expr; echo and printf when nothing pipes their output on).
# A leading VAR=$(...) assignment, a for/select/case word list, and the
# command name itself are not arguments and are left to the other checks.
# The bodies are lexed as commands too, so a nested substitution is checked
# in its own command. The splitter is the same quote-, heredoc- and
# continuation-aware awk pass the inline-program check uses, with a flag on
# each word that holds an unquoted substitution.
scope_subst_lex() {
  LC_ALL=C awk -v RS='\001' '
    function flush() { if (inw) { printf "W\037%d\037%d\037%s\036", ws, wu, w; inw = 0; w = ""; wu = 0 } }
    function endcmd() { flush(); printf "E\036" }
    function startw(pos) { if (!inw) { inw = 1; ws = pos; w = ""; wu = 0 } }
    function sub_rec(s, e) { if (e > s) printf "S\037%d\037%s\036", s, substr(t, s, e - s) }
    function match_bt(i,   c) {
      for (; i <= n; i++) {
        c = substr(t, i, 1)
        if (c == "\\") { i++; continue }
        if (c == "`") return i
      }
      return n + 1
    }
    function match_sub(i,   depth, q, c) {
      depth = 1; q = ""
      for (; i <= n; i++) {
        c = substr(t, i, 1)
        if (q == "\047") { if (c == "\047") q = ""; continue }
        if (c == "\\") { i++; continue }
        if (q == "\"") {
          if (c == "\"") q = ""
          else if (c == "$" && substr(t, i + 1, 1) == "(") i = match_sub(i + 2)
          else if (c == "`") i = match_bt(i + 1)
          continue
        }
        if (c == "$" && substr(t, i + 1, 1) == "\047") { i = match_ansi(i + 2); continue }
        if (c == "\047" || c == "\"") { q = c; continue }
        if (c == "`") { i = match_bt(i + 1); continue }
        if (c == "(") depth++
        else if (c == ")") { depth--; if (depth == 0) return i }
      }
      return n + 1
    }
    # $'"'"'...'"'"' (ANSI-C quoting): a backslash escapes the next byte, so \'"'"'
    # does not end it. Returns the index of the closing quote.
    # ${...}: the index of the closing brace, skipping quoted text.
    function match_brace(i,   depth, q, c, j2) {
      depth = 1; q = ""
      for (; i <= n; i++) {
        c = substr(t, i, 1)
        if (q == "\047") { if (c == "\047") q = ""; continue }
        if (c == "\\") { i++; continue }
        # A substitution inside the braces (${X:-$(cat p)}) is recorded and,
        # outside quotes, flags the word.
        if (c == "$" && substr(t, i + 1, 1) == "(") { j2 = match_sub(i + 2); sub_rec(i + 2, j2); if (q == "" && substr(t, i + 2, 1) != "(") bu = 1; i = j2; continue }
        if (c == "`") { j2 = match_bt(i + 1); sub_rec(i + 1, j2); if (q == "") bu = 1; i = j2; continue }
        if (q == "\"") { if (c == "\"") q = ""; continue }
        if (c == "\047" || c == "\"") { q = c; continue }
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) return i }
      }
      return n + 1
    }
    function match_ansi(i,   c) {
      for (; i <= n; i++) {
        c = substr(t, i, 1)
        if (c == "\\") { i++; continue }
        if (c == "\047") return i
      }
      return n + 1
    }
    function skip_heredocs(i,   k, rest, nl, line) {
      for (k = 1; k <= nh; k++) {
        while (i < n) {
          rest = substr(t, i + 1); nl = index(rest, "\n")
          if (nl == 0) { line = rest; i = n } else { line = substr(rest, 1, nl - 1); i = i + nl }
          # In an unquoted heredoc a backslash-newline joins body lines
          # before bash compares them with the delimiter.
          while (!hquoted[k] && line ~ /\\$/ && i < n) {
            line = substr(line, 1, length(line) - 1)
            rest = substr(t, i + 1); nl = index(rest, "\n")
            if (nl == 0) { line = line rest; i = n } else { line = line substr(rest, 1, nl - 1); i = i + nl }
          }
          if (hdash[k]) sub(/^\t+/, "", line)
          if (line == hd[k]) break
        }
      }
      nh = 0
      return i
    }
    {
      t = $0; n = length(t); q = ""; inw = 0; w = ""; wu = 0; nh = 0
      for (i = 1; i <= n; i++) {
        c = substr(t, i, 1)
        if (q == "\047") { w = w c; if (c == "\047") q = ""; continue }
        if (q == "\"") {
          w = w c
          if (c == "\\") { i++; w = w substr(t, i, 1); continue }
          if (c == "\"") { q = ""; continue }
          if (c == "$" && substr(t, i + 1, 1) == "(") { j = match_sub(i + 2); sub_rec(i + 2, j); w = w substr(t, i + 1, j - i); i = j; continue }
          if (c == "`") { j = match_bt(i + 1); sub_rec(i + 1, j); w = w substr(t, i + 1, j - i); i = j; continue }
          continue
        }
        # A backslash-newline joins lines outside quotes and comments.
        if (c == "\\" && substr(t, i + 1, 1) == "\n") { i++; continue }
        if (c == "\\") { startw(i); w = w c substr(t, i + 1, 1); i++; continue }
        if (c == "$" && substr(t, i + 1, 1) == "\047") { startw(i); j = match_ansi(i + 2); w = w substr(t, i, j - i + 1); i = j; continue }
        if (c == "\047" || c == "\"") { startw(i); w = w c; q = c; continue }
        # (( ... )) is arithmetic: `<<` there is a shift, not a heredoc. The
        # body is still lexed on its own in case bash reads it as nested
        # subshells instead.
        if (c == "(" && substr(t, i + 1, 1) == "(" && !inw) { endcmd(); j = match_sub(i + 1); sub_rec(i + 2, j - 1); i = j; endcmd(); continue }
        # ${...} is one word: a zsh flag such as ${(f)x} has a "(" that is not
        # a subshell.
        if (c == "$" && substr(t, i + 1, 1) == "{") { startw(i); bu = 0; j = match_brace(i + 2); if (bu) wu = 1; w = w substr(t, i, j - i + 1); i = j; continue }
        if (c == "$" && substr(t, i + 1, 1) == "(") { startw(i); if (substr(t, i + 2, 1) != "(") wu = 1; j = match_sub(i + 2); sub_rec(i + 2, j); w = w substr(t, i, j - i + 1); i = j; continue }
        if (c == "`") { startw(i); wu = 1; j = match_bt(i + 1); sub_rec(i + 1, j); w = w substr(t, i, j - i + 1); i = j; continue }
        if (c == " " || c == "\t") { flush(); continue }
        if (c == "\n") { endcmd(); if (nh > 0) i = skip_heredocs(i); continue }
        if (c == "#" && !inw) { while (i < n && substr(t, i + 1, 1) != "\n") i++; continue }
        if (c == "<" || c == ">") {
          if (inw && w ~ /^[0-9]+$/) { inw = 0; w = "" } else flush()
          op = c; nx = substr(t, i + 1, 1)
          if (c == "<" && nx == "<") {
            i++; op = "<<"; nx = substr(t, i + 1, 1)
            if (nx == "<") { i++; op = "<<<" } else if (nx == "-") { i++; op = "<<-" }
          } else if (nx == ">" || nx == "|" || nx == "&") { i++; op = op nx }
          if (op == "<<" || op == "<<-") {
            while (substr(t, i + 1, 1) == " " || substr(t, i + 1, 1) == "\t") i++
            # The delimiter is one shell word: quoted pieces keep their
            # spaces (<<'"'"'E OF'"'"'), and quote characters are removed.
            # A backslash-newline inside it joins lines (<<E\<nl>OF is EOF).
            # Any quoting makes the body literal, with no line joining.
            d = ""; dq = 0
            while (i < n) {
              nc = substr(t, i + 1, 1)
              if (nc == "\\" && substr(t, i + 2, 1) == "\n") { i += 2; continue }
              if (nc == " " || nc == "\t" || nc == "\n" || nc == ";" || nc == "&" || nc == "|" || nc == "<" || nc == ">" || nc == "(" || nc == ")") break
              i++
              if (nc == "\047" || nc == "\"") {
                dq = 1
                while (i < n && substr(t, i + 1, 1) != nc) { i++; d = d substr(t, i, 1) }
                i++
              } else if (nc == "\\") {
                dq = 1
                i++; d = d substr(t, i, 1)
              } else d = d nc
            }
            nh++; hd[nh] = d; hdash[nh] = (op == "<<-"); hquoted[nh] = dq
            continue
          }
          # A here-string word is data on stdin, not a path.
          if (op == "<<<") printf "H\036"; else printf "R\036"
          continue
        }
        if (c == ";" || c == "|" || c == "(" || c == ")") { endcmd(); continue }
        if (c == "&") {
          if (substr(t, i + 1, 1) == ">") { flush(); i++; if (substr(t, i + 1, 1) == ">") i++; printf "R\036"; continue }
          endcmd(); continue
        }
        startw(i); w = w c
      }
      endcmd()
      printf "Z\036"
    }'
}

# Print the $(...) and `...` bodies that sit outside quotes in <word>, one per
# record ended by \036. A $((...)) arithmetic expansion is not printed. With a
# second argument of 1, bodies inside double quotes are printed too (bodies
# inside single quotes never are).
scope_subst_unquoted_bodies() {
  local word="${1:-}" all="${2:-0}" i=0 q="" ch c2 len depth j bq
  len=${#word}
  while [ "$i" -lt "$len" ]; do
    ch="${word:i:1}"
    if [ "$q" = "'" ] || [ "$q" = A ]; then
      if [ "$q" = A ] && [ "$ch" = "\\" ]; then i=$((i + 2)); continue; fi
      if [ "$ch" = "'" ]; then q=""; fi
      i=$((i + 1))
      continue
    fi
    case "$ch" in
      \\) i=$((i + 2)); continue ;;
      '"') if [ "$q" = '"' ]; then q=""; else q='"'; fi; i=$((i + 1)); continue ;;
      "'") if [ -z "$q" ]; then q="'"; fi; i=$((i + 1)); continue ;;
    esac
    if [ -z "$q" ] && [ "$ch" = '$' ] && [ "${word:$((i + 1)):1}" = "'" ]; then
      q=A
      i=$((i + 2))
      continue
    fi
    if [ "$ch" = '$' ] && [ "${word:$((i + 1)):1}" = '(' ]; then
      # Find the matching paren, skipping quoted text inside the body.
      j=$((i + 2)); depth=1; bq=""
      while [ "$j" -lt "$len" ]; do
        c2="${word:j:1}"
        if [ "$bq" = "'" ]; then
          if [ "$c2" = "'" ]; then bq=""; fi
          j=$((j + 1))
          continue
        fi
        if [ "$c2" = "\\" ]; then j=$((j + 2)); continue; fi
        if [ "$bq" = '"' ]; then
          if [ "$c2" = '"' ]; then bq=""; fi
          j=$((j + 1))
          continue
        fi
        case "$c2" in
          "'"|'"') bq="$c2" ;;
          '(') depth=$((depth + 1)) ;;
          ')')
            depth=$((depth - 1))
            if [ "$depth" -eq 0 ]; then break; fi
            ;;
        esac
        j=$((j + 1))
      done
      if { [ -z "$q" ] || [ "$all" = 1 ]; } && [ "${word:$((i + 2)):1}" != '(' ]; then
        printf '%s\036' "${word:$((i + 2)):$((j - i - 2))}"
      fi
      i=$((j + 1))
      continue
    fi
    if [ "$ch" = $'\140' ]; then
      j=$((i + 1))
      while [ "$j" -lt "$len" ] && [ "${word:j:1}" != $'\140' ]; do
        if [ "${word:j:1}" = "\\" ]; then j=$((j + 1)); fi
        j=$((j + 1))
      done
      if [ -z "$q" ] || [ "$all" = 1 ]; then
        printf '%s\036' "${word:$((i + 1)):$((j - i - 1))}"
      fi
      i=$((j + 1))
      continue
    fi
    i=$((i + 1))
  done
  return 0
}

# True when a command substitution with <body> prints something that is not
# a path, or names the command's own working directory: $(pwd), the repo top
# level, a date, a commit id, a process or container id, a count.
scope_subst_body_is_safe() {
  local body="${1:-}" ref='[A-Za-z0-9_./^~@{}:-]+'
  body="${body#"${body%%[![:space:]]*}"}"
  body="${body%"${body##*[![:space:]]}"}"
  # `git -C <dir>` before a git query that prints a commit id, a branch name
  # or a count: the output is not a path whatever <dir> is, and the git -C
  # check reads <dir> itself (scope_inline_expansions_check_word). The
  # directory word may be one plain variable. --show-toplevel prints the
  # directory, so it does not take this form.
  local gitc_re='^git\ -C\ ("?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?|[A-Za-z0-9_./~@+-]+)\ (rev-parse\ --|merge-base\ |branch\ --show-current$|rev-list\ --count\ )'
  if [[ "$body" =~ $gitc_re ]]; then
    case "$body" in *--show-toplevel*) return 1 ;; esac
    body="git ${body#git -C * }"
  fi
  case "$body" in *'$'*|*$'\140'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*|*'('*|*')'*) return 1 ;; esac
  [[ "$body" =~ ^pwd(\ -[PL])?$ ]] && return 0
  [[ "$body" =~ ^git\ rev-parse\ --show-toplevel$ ]] && return 0
  [[ "$body" =~ ^date(\ [^\'\"]*)?$ ]] && return 0
  [[ "$body" =~ ^git\ rev-parse(\ --(short(=[0-9]+)?|verify|abbrev-ref|quiet))*\ $ref$ ]] && return 0
  [[ "$body" =~ ^git\ merge-base(\ --[a-z-]+)*(\ $ref)+$ ]] && return 0
  [[ "$body" =~ ^git\ branch\ --show-current$ ]] && return 0
  # HQ's own session id: session_id_is_valid limits it to [A-Za-z0-9._-]
  # and refuses . and .., so it holds no slash (resumework lock steps).
  [[ "$body" =~ ^bash\ (\./)?core/scripts/hq-session\.sh\ current$ ]] && return 0
  [[ "$body" =~ ^git\ rev-list\ --count(\ $ref)+$ ]] && return 0
  [[ "$body" =~ ^(nproc|whoami|hostname|id(\ -[ugnr]+)?|uname(\ -[a-zA-Z]+)?)$ ]] && return 0
  [[ "$body" =~ ^seq(\ -?[0-9]+){1,3}$ ]] && return 0
  # pgrep prints process ids. -a and -l add the command line, which can hold
  # a path, so those flags are not on the list.
  [[ "$body" =~ ^pgrep(\ -[b-kmnoq-zA-Z]+)*\ [^\'\"-][^\'\"]*$ ]] && return 0
  [[ "$body" =~ ^docker\ ps(\ -[aq]+|\ --quiet|\ --all)+$ ]] && return 0
  # A fresh temporary file or directory. A template path, if any, is literal
  # text in the command and goes through the path scans.
  [[ "$body" =~ ^mktemp(\ -[dqtu]+)*(\ [A-Za-z0-9._/X-]+)?$ ]] && return 0
  return 1
}

# Print the text a shell receives from the program word <word> of
# `bash -c <word>` or `eval <word>`: single quotes removed as-is, double
# quotes removed with their \$ \` \" \\ escapes undone. Mixed or unquoted
# words are printed unchanged, which keeps any $(...) in them visible.
scope_subst_program_text() {
  local word="${1:-}" inner
  case "$word" in
    \'*\')
      inner="${word:1:${#word}-2}"
      case "$inner" in *"'"*) printf '%s' "$word" ;; *) printf '%s' "$inner" ;; esac
      ;;
    \"*\")
      inner="${word:1:${#word}-2}"
      inner="${inner//\\\$/\$}"
      inner="${inner//\\\"/\"}"
      inner="${inner//\\\`/\`}"
      printf '%s' "$inner"
      ;;
    *) printf '%s' "$word" ;;
  esac
}

# Variables set from a command substitution.
#
# `x=$(cat /tmp/p); cat $x` and `for f in $(cat /tmp/p); do cat $f; done` reach
# the same path as `cat $(cat /tmp/p)`, one statement later. A name that is
# assigned (NAME=, NAME+=, NAME[i]=, NAME=(...), export/local/declare, printf
# -v) or looped over from a substitution the guard cannot read is recorded in
# SCOPE_SUBST_TAINT, as is every name read, mapfile or readarray set in a
# command this check scans. A later word that expands the name is checked like
# the substitution itself. A first pass over the whole command records names
# only, so a use that comes earlier in the text (a function body, a loop) is
# still checked. A body does not mark the name when
#   - it prints a non-path or the working directory (scope_subst_body_is_safe);
#   - the guard turns it into a literal and checks that path itself, or it
#     prints a fresh temporary path or the entry names of a directory spelled
#     out in the command (scope_subst_body_is_known);
#   - it is one https?:// fetch with curl or wget, or one gh call, that sends
#     no local file (scope_subst_body_is_remote).
# A marked value passes as message text of git, gh or hq (--body, --title,
# git -m, ...), as a here-string, as an argument of a command that takes no
# file (kill, echo, test, ...), and inside an http(s) URL given to curl or wget.
# A value built from a marked name is marked too.
SCOPE_SUBST_TAINT=" "

scope_subst_body_is_known() {
  local body="${1:-}" lit='[A-Za-z0-9_./@+:][A-Za-z0-9_./@+:-]*' re
  body="${body#"${body%%[![:space:]]*}"}"
  body="${body%"${body##*[![:space:]]}"}"
  # The deploy API resolver prints one checked https URL
  # (scope_deploy_api_resolver_value); a path use of its value still has to
  # resolve in the path scans, which fail closed on it.
  scope_deploy_api_resolver_value "$body" "${scope_subst_text:-${SCOPE_FULL_CMD:-}}" >/dev/null && return 0
  # The entry names of a directory, given literally or as one plain variable,
  # optionally cut to a count with head or tail: bare names with no slash.
  # The guard bounds loops over these and checks each entry
  # (feedback_decb4125, feedback_f286c9e5). Only flags that print bare names:
  # -l and friends print link targets.
  re='^ls(\ -[1aAFtrS]+)*(\ ('"$lit"'|\$[A-Za-z_][A-Za-z0-9_]*|"\$[A-Za-z_][A-Za-z0-9_]*"))*(\ ?\|\ ?(head|tail)(\ -n)?\ -?[0-9]+)?$'
  [[ "$body" =~ $re ]] && return 0
  # `ls -d workspace/x/* | head -1` prints a path the glob names; the path
  # scans check the glob in its place (scope_substitution_literal_value).
  # `find DIR -name PAT` prints paths under DIR; a loop over it is bounded
  # to DIR's entries (scope_shell_variable_values) and a loop body use is
  # checked as each of those paths.
  scope_ls_d_checked_paths "$body" >/dev/null && return 0
  # A bounded `find` is accepted only as a `for` loop list (see the for
  # branch of scope_subst_check_command), where every value is enumerated and
  # checked with symlinks resolved. As an assignment value it stays tainted:
  # `X=$(find ...); cat $X` would otherwise open paths nothing checked.
  # The last component of one word, literal or one plain variable, with an
  # optional literal suffix to drop. The output holds no slash, so it names a
  # company folder only after a literal companies/ prefix, which the path
  # scans check (an unknown name there still blocks), or after a cd into
  # companies/, which is refused. resumework's lock step uses it on the
  # thread path (feedback: #1512 CI, resumework-skill-scope block [2]).
  # `basename /` prints `/`, so a literal operand must end in a non-slash
  # character, and a variable operand needs every assignment of it in the
  # command to be such a literal (#1512 review: `r=$(basename /)` then
  # `companies${r}otherco${r}...`).
  re='^basename\ ('"$lit"'|\$[A-Za-z_][A-Za-z0-9_]*|"\$[A-Za-z_][A-Za-z0-9_]*")(\ [A-Za-z0-9._-]+)?$'
  if [[ "$body" =~ $re ]]; then
    local bn_word="${BASH_REMATCH[1]}" bn_name bn_rest bn_val bn_seen=0 bn_re
    case "$bn_word" in
      *'$'*)
        bn_name="${bn_word//[\"\$]/}"
        bn_rest="${scope_subst_text:-}"
        bn_re='(^|[;&|({[:space:]])'"$bn_name"'(\+?=)("([^"$`\\]*)"|'"'([^']*)'"'|([^;&|<>()[:space:]"'"'"'$`\\]*))?'
        while [[ "$bn_rest" =~ $bn_re ]]; do
          bn_rest="${bn_rest#*"${BASH_REMATCH[0]}"}"
          [ "${BASH_REMATCH[2]}" = "=" ] || return 1
          [ -n "${BASH_REMATCH[3]}" ] || return 1
          bn_val="${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}"
          case "$bn_val" in ''|*/) return 1 ;; esac
          bn_seen=1
        done
        [ "$bn_seen" -eq 1 ] || return 1
        # Any other way of setting the name (read, for, declare, printf -v,
        # an assignment value with an expansion) leaves it unproven.
        case "${scope_subst_text:-}" in
          *"read "*"$bn_name"*|*"for $bn_name "*|*"-v $bn_name"*|*"declare "*"$bn_name"*|*"local "*"$bn_name="*'$'*|*"$bn_name=\$"*|*"$bn_name=\"\$"*|*"$bn_name=\`"*) return 1 ;;
        esac
        return 0
        ;;
      */) return 1 ;;
      *) return 0 ;;
    esac
  fi
  case "$body" in *'$'*|*$'\140'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*) return 1 ;; esac
  [[ "$body" =~ ^date(\ [^\'\"]*)?$ ]] && return 0
  [[ "$body" =~ ^pwd(\ -[PL])?$ ]] && return 0
  [[ "$body" =~ ^git\ rev-parse\ --show-toplevel$ ]] && return 0
  [[ "$body" =~ ^(echo|printf\ (%s|\'%s\'|\"%s\"))\ $lit$ ]] && return 0
  [[ "$body" =~ ^dirname\ $lit$ ]] && return 0
  case "$body" in
    'npm root -g'|'npm root --global'|'npm prefix -g'|'npm prefix --global'|'npm config get prefix'|'npm config get cache') return 0 ;;
    'brew --prefix'|'brew --cellar'|'brew --repository') return 0 ;;
  esac
  [[ "$body" =~ ^brew\ --prefix\ [A-Za-z0-9@._+-]+$ ]] && return 0
  # A fresh temporary path, with any template or parent directory spelled
  # out in the command where the path scans see it.
  [[ "$body" =~ ^mktemp(\ [A-Za-z0-9._/@+=X-]+)*$ ]] && return 0
  return 1
}

# True when <body> is one curl or wget fetch of an http(s) URL, or one gh
# call, that sends no local file, optionally piped through jq with a filter,
# or head, tail, sort, uniq, wc, base64 with options only, or tr.
scope_subst_body_is_remote() {
  local body="${1:-}" lower stage rest w nonopt
  body="${body#"${body%%[![:space:]]*}"}"
  case "$body" in
    *'$('*|*$'\140'*|*';'*|*'&'*|*'<'*|*'>'*|*'@'*) return 1 ;;
  esac
  lower="$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *'file:'*|*'--config'*|*'--upload-file'*|*'--data-binary'*|*'--post-file'*|*'--body-file'*) return 1 ;;
    *'--input'*|*'--rawfile'*|*'--slurpfile'*|*'--from-file'*) return 1 ;;
  esac
  local -a parts=()
  rest="${body%%|*}"
  # Short option clusters that read a file (-K config, -T upload), however
  # they are bundled.
  read -r -a parts <<< "$rest"
  for w in ${parts[@]+"${parts[@]}"}; do
    case "$w" in --*) ;; -*K*|-*T*) return 1 ;; esac
  done
  case "$rest" in
    gh\ *) ;;
    curl\ *|wget\ *) [[ "$lower" =~ (^|[[:space:]\"\'])https?:// ]] || return 1 ;;
    *) return 1 ;;
  esac
  rest="$body"
  while [ "$rest" != "${rest#*|}" ]; do
    rest="${rest#*|}"
    stage="${rest%%|*}"
    nonopt=0
    parts=()
    read -r -a parts <<< "$stage"
    [ "${#parts[@]}" -gt 0 ] || return 1
    case "${parts[0]}" in
      tr) ;;
      jq)
        for w in "${parts[@]:1}"; do
          case "$w" in -f|--from-file|--arg|--argjson|--args|--jsonargs) return 1 ;; -*) ;; *) nonopt=$((nonopt + 1)) ;; esac
        done
        [ "$nonopt" -le 1 ] || return 1
        ;;
      head|tail|sort|uniq|wc|base64)
        for w in "${parts[@]:1}"; do
          case "$w" in -*|[0-9]*) ;; *) return 1 ;; esac
        done
        ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# True when a substitution with <body> may name the program a command runs:
# a body that prints no path or one the guard maps, or a lookup of a
# program on PATH (which, command -v, type -p).
scope_subst_name_body_is_ok() {
  local body="${1:-}"
  body="${body#"${body%%[![:space:]]*}"}"
  body="${body%"${body##*[![:space:]]}"}"
  scope_subst_body_is_safe "$body" && return 0
  scope_subst_body_is_known "$body" && return 0
  [[ "$body" =~ ^(which|command\ -v|type\ -[pP])\ [A-Za-z0-9._+-]+$ ]]
}

scope_subst_body_taints() {
  local body="${1:-}"
  scope_subst_body_is_safe "$body" && return 1
  scope_subst_body_is_known "$body" && return 1
  scope_subst_body_is_remote "$body" && return 1
  return 0
}

# Print <word> without its single-quoted and $'...' parts and without
# backslash-escaped characters, none of which the shell expands.
scope_subst_expanded_text() {
  local word="${1:-}" out="" i=0 len ch q=""
  len=${#word}
  while [ "$i" -lt "$len" ]; do
    ch="${word:i:1}"
    if [ "$q" = "'" ]; then
      [ "$ch" = "'" ] && q=""
      i=$((i + 1)); continue
    fi
    if [ "$q" = A ]; then
      if [ "$ch" = "\\" ]; then i=$((i + 2)); continue; fi
      [ "$ch" = "'" ] && q=""
      i=$((i + 1)); continue
    fi
    if [ "$ch" = "\\" ]; then i=$((i + 2)); continue; fi
    if [ "$q" = '"' ]; then
      [ "$ch" = '"' ] && q=""
      out="$out$ch"; i=$((i + 1)); continue
    fi
    case "$ch" in
      '"') q='"' ;;
      "'") q="'"; i=$((i + 1)); continue ;;
      '$') if [ "${word:$((i + 1)):1}" = "'" ]; then q=A; i=$((i + 2)); continue; fi ;;
    esac
    out="$out$ch"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# True when <word> expands a marked name, including zsh forms ($=x, ${~x},
# ${(f)x}); the name is left in scope_subst_taint_hit. While any name is
# marked, an indirect expansion (${!y}, ${(P)y}) counts as a use too.
scope_subst_word_uses_taint() {
  local word="${1:-}" text name re
  scope_subst_taint_hit=""
  [ "$SCOPE_SUBST_TAINT" != " " ] || return 1
  case "$word" in *'$'*) ;; *) return 1 ;; esac
  text="$(scope_subst_expanded_text "$word")"
  case "$text" in *'$'*) ;; *) return 1 ;; esac
  re='\$\{(!|[^}]*\([^)]*P[^)]*\))'
  if [[ "$text" =~ $re ]]; then
    scope_subst_taint_hit="{!...}"
    return 0
  fi
  for name in $SCOPE_SUBST_TAINT; do
    re='\$\{?([#!=~^+]|\([^)]*\))*'"$name"'([^A-Za-z0-9_]|$)'
    if [[ "$text" =~ $re ]]; then
      scope_subst_taint_hit="$name"
      return 0
    fi
  done
  return 1
}

# True when the value text <value> carries a substitution that marks its name,
# or expands a marked name.
scope_subst_value_taints() {
  local value="${1:-}" body
  case "$value" in *'$'*|*$'\140'*) ;; *) return 1 ;; esac
  while IFS= read -r -d $'\036' body; do
    scope_subst_body_taints "$body" && return 0
  done < <(scope_subst_unquoted_bodies "$value" 1)
  scope_subst_word_uses_taint "$value"
}

scope_subst_mark() {
  local name="${1:-}"
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
  case "$SCOPE_SUBST_TAINT" in *" $name "*) ;; *) SCOPE_SUBST_TAINT="$SCOPE_SUBST_TAINT$name " ;; esac
}

# The value of assignment word <k>. For NAME=(...) the lexer ends the word at
# `(`, so the parenthesised list is read from the scanned text.
scope_subst_assignment_value() {
  local k="${1:-0}" word pos rest depth=0 j c out=""
  word="${sw_raw[$k]}"
  case "$word" in
    *=)
      pos=$(( ${sw_off[$k]:-0} - 1 + ${#word} ))
      if [ "$pos" -ge 0 ] && [ "${text:$pos:1}" = "(" ]; then
        rest="${text:$pos}"
        j=0
        while [ "$j" -lt "${#rest}" ]; do
          c="${rest:j:1}"
          out="$out$c"
          case "$c" in
            '(') depth=$((depth + 1)) ;;
            ')') depth=$((depth - 1)); [ "$depth" -gt 0 ] || break ;;
          esac
          j=$((j + 1))
        done
        printf '%s' "$out"
        return 0
      fi
      ;;
  esac
  printf '%s' "${word#*=}"
}

# Mark the name of assignment word <k> (NAME=, NAME+=, NAME[i]=, NAME=(...))
# when its value taints.
scope_subst_mark_assignment() {
  local k="${1:-0}" word name value
  word="${sw_raw[$k]}"
  [[ "$word" =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?= ]] || return 0
  name="${word%%[=+[]*}"
  value="$(scope_subst_assignment_value "$k")"
  scope_subst_value_taints "$value" || return 0
  # `s=$(grep -n START f | cut -d: -f1)`: a value that is exactly one
  # substitution whose pipeline prints only line numbers or counts
  # (scope_substitution_prints_numbers) cannot hold a path, so the name is
  # not marked (feedback 2ec4335f). The body is still lexed and checked as
  # a command by scope_subst_scan.
  local numeric_value="${value#[\"\']}"
  numeric_value="${numeric_value%[\"\']}"
  case "$numeric_value" in
    '$('*')')
      numeric_value="${numeric_value#\$(}"
      numeric_value="${numeric_value%)}"
      case "$numeric_value" in *'('*|*')'*|*$'\140'*) ;; *)
        scope_substitution_prints_numbers "$numeric_value" && return 0 ;;
      esac
      ;;
  esac
  scope_subst_mark "$name"
  return 0
}

# True when word <k> is the value of a message-text option of git, gh or hq.
scope_subst_is_text_value() {
  local k="${1:-0}" head="${2:-}" word opt
  case "$head" in git|gh|hq) ;; *) return 1 ;; esac
  word="${sw_raw[$k]//[\"\']/}"
  case "$word" in
    --*=*) opt="${word%%=*}" ;;
    *) [ "$k" -gt 0 ] || return 1; opt="${sw_raw[$((k - 1))]//[\"\']/}" ;;
  esac
  case "$opt" in
    --text|--summary|--title|--body|--message|--note|--description|--subject|--comment|--reason|--details) return 0 ;;
    -m) [ "$head" = git ] && return 0 ;;
  esac
  return 1
}

# Check the simple command in sw_raw/sw_unq/sw_redir from <start> to <end>.
# With scope_subst_mark_only=1 it only records marked names.
scope_subst_check_command() {
  local start="${1:-0}" end="${2:-0}" i word head="" body allowed_head=0 k j declare_head=0 use joined
  i="$start"
  # Leading assignments only store the output (X=$(cat p)); the name is
  # marked and checked where it is used. Wrappers hand the rest to another
  # command.
  while [ "$i" -lt "$end" ]; do
    word="${sw_raw[$i]}"
    if [ "${sw_redir[$i]}" -ne 0 ]; then
      i=$((i + 1))
      continue
    fi
    if [[ "$word" =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?= ]]; then
      scope_subst_mark_assignment "$i"
      i=$((i + 1))
      continue
    fi
    head="${word//[\"\'\\]/}"
    head="${head##*/}"
    case "$head" in
      do|then|else|elif|'!'|'{'|if|while|until|nohup|builtin|exec|command|time|stdbuf|caffeinate)
        i=$((i + 1))
        while [ "$i" -lt "$end" ] && [[ "${sw_raw[$i]}" == -* ]]; do i=$((i + 1)); done
        ;;
      env|sudo|nice|timeout|xargs)
        i=$((i + 1))
        while [ "$i" -lt "$end" ]; do
          case "${sw_raw[$i]}" in
            -u|-g|-C|-D|-n|-s|-k|-I|-P|-L|-d|-E|-a|-p|-r|-t|-U|-T|--signal|--kill-after|--chdir|--unset) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *)
              if [[ "${sw_raw[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then i=$((i + 1)); else break; fi
              ;;
          esac
        done
        # timeout's first operand is the duration.
        if [ "$head" = timeout ]; then i=$((i + 1)); fi
        ;;
      # A loop or case header's word list is not a command argument. A loop
      # variable over a substitution is marked and checked where the body
      # uses it.
      for|select)
        if [ $((i + 2)) -lt "$end" ] && [ "${sw_raw[$((i + 2))]}" = in ]; then
          k=$((i + 3))
          while [ "$k" -lt "$end" ]; do
            if scope_subst_value_taints "${sw_raw[$k]}"; then
              # A list that is one `$(grep -o 'https://...' FILE)` binds
              # the variable to http(s) URLs only; a network client may
              # fetch them (scope_url_is_literal_loop_var), and any other
              # use of the name is still an unresolved variable to the path
              # scans.
              body="${sw_raw[$k]}"
              if [ "$head" = for ] && [ $((k + 1)) -eq "$end" ] && [ "$k" -eq $((i + 3)) ] \
                && [[ "$body" == '$('*')' ]]; then
                body="${body#\$(}"
                body="${body%)}"
                if scope_subst_body_prints_https_urls "$body"; then
                  break
                fi
                # A bounded find over an open tree: every value the loop
                # variable can take is enumerated here and checked as a
                # literal path (a symlink to another tenant blocks), so the
                # name is not tainted. Any value the guard cannot check
                # keeps the taint.
                if scope_find_body_is_bounded "$body" >/dev/null \
                  && scope_find_bounded_paths "$body" 1 >/dev/null; then
                  break
                fi
                # `grep -l PAT FILE...`: the values are the operands that
                # match, each checked here as a literal path.
                if scope_grep_l_paths "$body" 1 >/dev/null; then
                  break
                fi
              fi
              scope_subst_mark "${sw_raw[$((i + 1))]}"
              break
            fi
            k=$((k + 1))
          done
        fi
        return 0
        ;;
      case) return 0 ;;
      *) break ;;
    esac
  done
  head=""
  if [ "$i" -lt "$end" ]; then
    head="${sw_raw[$i]//[\"\'\\]/}"
    head="${head##*/}"
  fi
  # export/local/declare NAME=VALUE store a value like a leading assignment.
  # read, mapfile and readarray store input the guard cannot see, so every
  # name they set is marked. printf -v NAME stores its output.
  case "$head" in
    export|local|declare|typeset|readonly)
      declare_head=1
      k=$((i + 1))
      while [ "$k" -lt "$end" ]; do
        [ "${sw_redir[$k]}" -ne 0 ] || scope_subst_mark_assignment "$k"
        k=$((k + 1))
      done
      ;;
    read|mapfile|readarray)
      k=$((i + 1))
      while [ "$k" -lt "$end" ]; do
        [ "${sw_redir[$k]}" -ne 0 ] || scope_subst_mark "${sw_raw[$k]}"
        k=$((k + 1))
      done
      ;;
    printf)
      k=$((i + 1))
      while [ "$k" -lt "$end" ]; do
        if [ "${sw_raw[$k]}" = -v ] && [ $((k + 1)) -lt "$end" ]; then
          j=$((i + 1))
          while [ "$j" -lt "$end" ]; do
            if [ "$j" -ne $((k + 1)) ] && scope_subst_value_taints "${sw_raw[$j]}"; then
              scope_subst_mark "${sw_raw[$((k + 1))]}"
              break
            fi
            j=$((j + 1))
          done
        fi
        k=$((k + 1))
      done
      ;;
  esac
  # A program handed to another shell runs its own substitutions there:
  # bash -c 'cat $(cat p)', eval "...", find ... -exec sh -c '...' \;
  case "$head" in
    bash|sh|zsh|dash|ksh)
      k=$((i + 1))
      while [ "$k" -lt "$end" ]; do
        case "${sw_raw[$k]}" in
          -o|+o|-O|+O|--rcfile|--init-file) k=$((k + 2)); continue ;;
          --) k=$((k + 1)); break ;;
          -*c*)
            k=$((k + 1))
            while [ "$k" -lt "$end" ] && [[ "${sw_raw[$k]}" == -* ]]; do k=$((k + 1)); done
            if [ "$k" -lt "$end" ]; then
              scope_subst_scan "$(scope_subst_program_text "${sw_raw[$k]}")" "$((scope_subst_depth + 1))" || exit $?
            fi
            break
            ;;
          -*|+*) k=$((k + 1)) ;;
          *) break ;;
        esac
      done
      ;;
    eval)
      # eval joins its arguments with spaces and runs the result.
      joined=""
      k=$((i + 1))
      while [ "$k" -lt "$end" ]; do
        joined="${joined:+$joined }$(scope_subst_program_text "${sw_raw[$k]}")"
        k=$((k + 1))
      done
      [ -z "$joined" ] || scope_subst_scan "$joined" "$((scope_subst_depth + 1))" || exit $?
      ;;
    find)
      k=$((i + 1))
      while [ "$k" -lt "$end" ]; do
        case "${sw_raw[$k]}" in
          -exec|-execdir|-ok|-okdir)
            j=$((k + 1))
            while [ "$j" -lt "$end" ]; do
              case "${sw_raw[$j]}" in '\;'|"';'"|'";"'|'+') break ;; esac
              j=$((j + 1))
            done
            scope_subst_check_command "$((k + 1))" "$j"
            k=$((j + 1))
            ;;
          *) k=$((k + 1)) ;;
        esac
      done
      ;;
  esac
  [ "${scope_subst_mark_only:-0}" != 1 ] || return 0
  # These commands take no file arguments: process ids, seconds, printed
  # text, or a test of a value. echo and printf lose the allowance when the
  # command pipes into something that runs or opens what it reads (xargs, a
  # shell, source, eval, read, while).
  case "$head" in
    kill|sleep|wait|'['|'[['|test|seq|expr) allowed_head=1 ;;
    echo|printf)
      allowed_head=1
      j='\|[[:space:]]*(xargs|sh|bash|zsh|dash|ksh|source|\.|eval|read|while|parallel)([[:space:]]|$)'
      [[ "${scope_subst_text:-}" =~ $j ]] && allowed_head=0
      ;;
  esac
  # Every word with an unquoted substitution is checked except a leading
  # assignment, a here-string and the command name itself ($(which x) args).
  # Redirection targets are checked wherever they sit, also when no command
  # follows (`exec > $(...)`, a bare `> $(...)`); wrapper options (env -C,
  # sudo -D) get no command allowance. A word that expands a marked name is
  # checked the same way, except where the overview above lets it pass.
  k="$start"
  while [ "$k" -lt "$end" ]; do
    word="${sw_raw[$k]}"
    if [ "${sw_redir[$k]}" -eq 2 ]; then
      k=$((k + 1))
      continue
    fi
    # The command name itself: `$(cat /tmp/p)`, `env $(cat /tmp/p)` or `$x`
    # runs whatever the file holds. Only a body that prints no path, one the
    # guard maps, or a PATH lookup may name the program.
    if [ "$k" -eq "$i" ] && [ "${sw_redir[$k]}" -eq 0 ]; then
      if scope_subst_word_uses_taint "$word"; then
        scope_block_rel "\$$scope_subst_taint_hit" "the command name uses \$$scope_subst_taint_hit, which holds a command substitution's output the guard cannot check; run the inner command first and use the literal program path it printed"
      fi
      while IFS= read -r -d $'\036' body; do
        scope_subst_name_body_is_ok "$body" && continue
        scope_block_rel "\$($body)" "a command substitution supplies the command name, so the command runs a program or path the guard cannot check; run the inner command first and use the literal program path it printed"
      done < <(scope_subst_unquoted_bodies "$word" 1)
    fi
    # A double-quoted substitution as an operand of a command that opens,
    # writes or enters the path it is given: `cat "$(cat p)"`, `cp x "$(...)"`.
    if [ "$k" -gt "$i" ] && [ "${sw_redir[$k]}" -eq 0 ]; then
      case "$head" in
        cat|cp|mv|rm|ln|ls|head|tail|less|more|tee|touch|mkdir|rmdir|chmod|chown|stat|file|wc|diff|cd|pushd|source|.|open|tar|zip|unzip|rsync|scp|du|realpath|readlink|truncate|shred|install|dd)
          case "$word" in
            *'"'*'$('*|*'"'*$'\140'*)
              while IFS= read -r -d $'\036' body; do
                scope_subst_body_taints "$body" || continue
                scope_block_rel "\$($body)" "a command substitution in double quotes supplies an argument of $head the guard cannot check; run the inner command first and use the literal path it printed"
              done < <(scope_subst_unquoted_bodies "$word" 1)
              ;;
          esac
          ;;
      esac
    fi
    use=0
    if [ "${sw_redir[$k]}" -eq 1 ]; then
      use=1
    elif [ "$k" -ne "$i" ] && ! { [ "$k" -lt "$i" ] && [[ "$word" =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?= ]]; }; then
      use=1
      if [ "$declare_head" -eq 1 ] && [ "$k" -gt "$i" ] && [[ "$word" =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?= ]]; then
        use=0
      fi
      if [ "$head" = printf ] && [ "$k" -gt 0 ] && [ "${sw_raw[$((k - 1))]}" = -v ]; then
        use=0
      fi
    fi
    if [ "$use" -eq 1 ] && scope_subst_word_uses_taint "$word"; then
      if [ "${sw_redir[$k]}" -eq 1 ]; then
        scope_block_rel "\$$scope_subst_taint_hit" "a redirection target uses \$$scope_subst_taint_hit, which holds a command substitution's output the guard cannot check; run the inner command first and use the literal path it printed"
      fi
      if ! { [ "$k" -gt "$i" ] && {
        [ "$allowed_head" -eq 1 ] || scope_subst_is_text_value "$k" "$head" \
          || { case "$head" in curl|wget) scope_word_is_literal_remote_url "$word" ;; *) false ;; esac; } \
          || scope_remote_position sw "$k" "$i"
      }; }; then
        scope_block_rel "\$$scope_subst_taint_hit" "an argument of ${head:-the command} uses \$$scope_subst_taint_hit, which holds a command substitution's output the guard cannot check; run the inner command first and use the literal path it printed"
      fi
    fi
    if [ "${sw_unq[$k]}" -eq 1 ] && {
      [ "${sw_redir[$k]}" -eq 1 ] || {
        [ "$k" -ne "$i" ] && ! { [ "$k" -lt "$i" ] && [[ "$word" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; }
      }
    }; then
      while IFS= read -r -d $'\036' body; do
        scope_subst_body_is_safe "$body" && continue
        if [ "${sw_redir[$k]}" -eq 0 ] && [ "$k" -gt "$i" ] && [ "$allowed_head" -eq 1 ]; then
          continue
        fi
        # A remote position (curl URL, ssh command text, `hq outposts exec
        # -- ...`, `gh -R`) sends the value away; the body is checked as a
        # command of its own below.
        if [ "${sw_redir[$k]}" -eq 0 ] && [ "$k" -gt "$i" ] && scope_remote_position sw "$k" "$i"; then
          continue
        fi
        if [ "${sw_redir[$k]}" -eq 1 ]; then
          scope_block_rel "\$($body)" "an unquoted command substitution names a redirection target the guard cannot check; run the inner command first and use the literal path it printed"
        fi
        scope_block_rel "\$($body)" "an unquoted command substitution supplies an argument of $head the guard cannot check; run the inner command first and use the literal path it printed"
      done < <(scope_subst_unquoted_bodies "${sw_raw[$k]}")
    fi
    k=$((k + 1))
  done
  return 0
}

# Lex <text> and check every simple command, then every substitution body.
scope_subst_scan() {
  local text="${1:-}" depth="${2:-0}" rec kind rest off flag word redir=0 i finished=0
  local -a sw_raw=() sw_unq=() sw_redir=() sw_off=() s_body=()
  local scope_subst_depth="$depth"
  if [ "$depth" -gt 4 ]; then
    scope_block_rel "\$(...)" "command substitutions are nested too deeply to check; run the inner commands separately"
  fi
  while IFS= read -r -d $'\036' rec; do
    kind="${rec:0:1}"
    case "$kind" in
      W)
        rest="${rec:2}"
        off="${rest%%$'\037'*}"
        rest="${rest#*$'\037'}"
        flag="${rest%%$'\037'*}"
        word="${rest#*$'\037'}"
        sw_raw[${#sw_raw[@]}]="$word"
        sw_unq[${#sw_unq[@]}]="$flag"
        sw_redir[${#sw_redir[@]}]="$redir"
        sw_off[${#sw_off[@]}]="$off"
        redir=0
        ;;
      # sw_redir: 1 for a redirection target, 2 for a here-string word.
      R) redir=1 ;;
      H) redir=2 ;;
      E)
        redir=0
        if [ "${#sw_raw[@]}" -gt 0 ]; then
          scope_subst_check_command 0 "${#sw_raw[@]}"
        fi
        sw_raw=()
        sw_unq=()
        sw_redir=()
        sw_off=()
        ;;
      S)
        rest="${rec:2}"
        s_body[${#s_body[@]}]="${rest#*$'\037'}"
        ;;
      Z) finished=1 ;;
    esac
  done < <(printf '%s' "$text" | scope_subst_lex)
  # A lexer that stopped early checked nothing after that point.
  [ "$finished" -eq 1 ] || return 3
  i=0
  while [ "$i" -lt "${#s_body[@]}" ]; do
    case "${s_body[$i]}" in
      *'$('*|*$'\140'*)
        # set -e is off in the check's subshell; pass a failure up by hand.
        scope_subst_scan "${s_body[$i]}" "$((depth + 1))" || return $?
        ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# Inline interpreter programs and directory options.
#
# `python3 -c "open('$D/x','w')"` and `git -C $R commit` hand a variable to a
# place the path scans above do not look. The shell fills $D or $R from the
# environment before the command runs, so a variable the command never set can
# point at another company's folder. The scans miss both shapes: the tokenizer
# drops the outer double quotes, so the program's own '...' reads as shell
# single quotes and `$D` looks literal; and a bare `$R` with no slash is not a
# path candidate at all.
#
# This check reads the raw command, finds the program argument of
#   python[N] -c, node -e/-p/--eval/--print, ruby -e, perl -e/-E,
#   bash/sh/zsh/dash/ksh -c (also after find -exec/-execdir/-ok),
# and the directory argument of
#   git -C/--git-dir/--work-tree, make -C/--directory, tar -C/--directory,
#   pnpm -C/--dir, npm --prefix/-C, yarn --cwd, env -C/--chdir, sudo -D/--chdir,
# and requires every variable the outer shell expands there to be proven by
# the same command: VAR=literal run before the use, a for loop over literal
# words, a literal argument at a known function call, $HOME, or $PWD. Any
# other variable, any other ${...} form, and any command substitution except
# $(pwd) blocks.
#
# A shell program (`bash -c '...'`) is also read from the inner shell's side,
# because single quotes stop only the outer shell: a variable the inner shell
# expands must be set inside the program, by a VAR=literal prefix on the same
# command, or be $HOME/$PWD, and positional parameters need literal
# arguments. A python/node/ruby/perl program that can start a shell
# (scope_interp_handoff_re, or backticks/qx/%x in perl and ruby) gets the same
# check for its `$NAME` text, as its heredoc form already does.
# Variables that never hold a path: ones bash maintains itself (most are
# read-only or recomputed on each use) and locale, terminal and identity
# variables. They pass without proof. Path-valued variables such as PATH,
# SHELL, TMPDIR and OLDPWD are not listed and still need it.
# They apply to program text only; a directory option always needs proof.
scope_inline_plain_names=' RANDOM LINENO SECONDS EPOCHSECONDS EPOCHREALTIME SRANDOM BASHPID UID EUID PPID SHLVL OSTYPE HOSTTYPE MACHTYPE BASH_VERSION BASH_VERSINFO USER LOGNAME LANG LANGUAGE TERM COLORTERM CI HOSTNAME TZ COLUMNS LINES '
scope_inline_is_plain_name() {
  case "${1:-}" in
    LC_[A-Z]*) return 0 ;;
  esac
  [[ "$scope_inline_plain_names" == *" ${1:-} "* ]]
}
scope_inline_head_re='(^|[^A-Za-z0-9_.-])(python[0-9.]*|pypy[0-9.]*|node|nodejs|ruby|perl|bash|sh|zsh|dash|ksh|git|make|gmake|tar|gtar|bsdtar|pnpm|npm|yarn|env|sudo)([^A-Za-z0-9_.-]|$)'

# True when <text> has an expansion and names a command this check reads.
scope_inline_expansions_wanted() {
  local text="${1:-}"
  case "$text" in *'$'*|*$'\140'*) ;; *) return 1 ;; esac
  # A $'...' escape can spell a command name; a GIT_* assignment moves git.
  case "$text" in *"\$'"*\\*|*GIT_[A-Z]*=*) return 0 ;; esac
  [[ "$text" =~ $scope_inline_head_re ]]
}

# Split stdin into simple commands without evaluating anything. Records, each
# ended by \036:
#   W\037<1-based byte offset>\037<raw word, quotes kept>
#   R   the next word is a redirection target
#   E   end of a simple command
#   S\037<1-based byte offset>\037<body>   a $(...) or `...` body
#   Z   the input was read to the end (the caller fails closed without it)
# Heredoc bodies are skipped; the interpreter-heredoc checks cover them.
# The lexer reads the command before backslash-newlines are removed, because
# bash ends a comment at a backslash-newline instead of joining the lines.
scope_inline_lex() {
  LC_ALL=C awk -v RS='\001' '
    function flush() { if (inw) { printf "W\037%d\037%s\036", ws, w; inw = 0; w = "" } }
    function endcmd() { flush(); printf "E\036" }
    function startw(pos) { if (!inw) { inw = 1; ws = pos; w = "" } }
    function sub_rec(s, e) { if (e > s) printf "S\037%d\037%s\036", s, substr(t, s, e - s) }
    function match_bt(i,   c) {
      for (; i <= n; i++) {
        c = substr(t, i, 1)
        if (c == "\\") { i++; continue }
        if (c == "`") return i
      }
      return n + 1
    }
    function match_sub(i,   depth, q, c) {
      depth = 1; q = ""
      for (; i <= n; i++) {
        c = substr(t, i, 1)
        if (q == "\047") { if (c == "\047") q = ""; continue }
        if (c == "\\") { i++; continue }
        if (q == "\"") {
          if (c == "\"") q = ""
          else if (c == "$" && substr(t, i + 1, 1) == "(") i = match_sub(i + 2)
          else if (c == "`") i = match_bt(i + 1)
          continue
        }
        if (c == "$" && substr(t, i + 1, 1) == "\047") { i = match_ansi(i + 2); continue }
        if (c == "\047" || c == "\"") { q = c; continue }
        if (c == "`") { i = match_bt(i + 1); continue }
        if (c == "(") depth++
        else if (c == ")") { depth--; if (depth == 0) return i }
      }
      return n + 1
    }
    # $'"'"'...'"'"' (ANSI-C quoting): a backslash escapes the next byte, so \'"'"'
    # does not end it. Returns the index of the closing quote.
    function match_ansi(i,   c) {
      for (; i <= n; i++) {
        c = substr(t, i, 1)
        if (c == "\\") { i++; continue }
        if (c == "\047") return i
      }
      return n + 1
    }
    function skip_heredocs(i,   k, rest, nl, line) {
      for (k = 1; k <= nh; k++) {
        while (i < n) {
          rest = substr(t, i + 1); nl = index(rest, "\n")
          if (nl == 0) { line = rest; i = n } else { line = substr(rest, 1, nl - 1); i = i + nl }
          # In an unquoted heredoc a backslash-newline joins body lines
          # before bash compares them with the delimiter.
          while (!hquoted[k] && line ~ /\\$/ && i < n) {
            line = substr(line, 1, length(line) - 1)
            rest = substr(t, i + 1); nl = index(rest, "\n")
            if (nl == 0) { line = line rest; i = n } else { line = line substr(rest, 1, nl - 1); i = i + nl }
          }
          if (hdash[k]) sub(/^\t+/, "", line)
          if (line == hd[k]) break
        }
      }
      nh = 0
      return i
    }
    {
      t = $0; n = length(t); q = ""; inw = 0; w = ""; nh = 0
      for (i = 1; i <= n; i++) {
        c = substr(t, i, 1)
        if (q == "\047") { w = w c; if (c == "\047") q = ""; continue }
        if (q == "\"") {
          w = w c
          if (c == "\\") { i++; w = w substr(t, i, 1); continue }
          if (c == "\"") { q = ""; continue }
          if (c == "$" && substr(t, i + 1, 1) == "(") { j = match_sub(i + 2); sub_rec(i + 2, j); w = w substr(t, i + 1, j - i); i = j; continue }
          if (c == "`") { j = match_bt(i + 1); sub_rec(i + 1, j); w = w substr(t, i + 1, j - i); i = j; continue }
          continue
        }
        # A backslash-newline joins lines outside quotes and comments.
        if (c == "\\" && substr(t, i + 1, 1) == "\n") { i++; continue }
        if (c == "\\") { startw(i); w = w c substr(t, i + 1, 1); i++; continue }
        if (c == "$" && substr(t, i + 1, 1) == "\047") { startw(i); j = match_ansi(i + 2); w = w substr(t, i, j - i + 1); i = j; continue }
        if (c == "\047" || c == "\"") { startw(i); w = w c; q = c; continue }
        # (( ... )) is arithmetic: `<<` there is a shift, not a heredoc. The
        # body is still lexed on its own in case bash reads it as nested
        # subshells instead.
        if (c == "(" && substr(t, i + 1, 1) == "(" && !inw) { endcmd(); j = match_sub(i + 1); sub_rec(i + 2, j - 1); i = j; endcmd(); continue }
        if (c == "$" && substr(t, i + 1, 1) == "(") { startw(i); j = match_sub(i + 2); sub_rec(i + 2, j); w = w substr(t, i, j - i + 1); i = j; continue }
        if (c == "`") { startw(i); j = match_bt(i + 1); sub_rec(i + 1, j); w = w substr(t, i, j - i + 1); i = j; continue }
        if (c == " " || c == "\t") { flush(); continue }
        if (c == "\n") { endcmd(); if (nh > 0) i = skip_heredocs(i); continue }
        if (c == "#" && !inw) { while (i < n && substr(t, i + 1, 1) != "\n") i++; continue }
        if (c == "<" || c == ">") {
          if (inw && w ~ /^[0-9]+$/) { inw = 0; w = "" } else flush()
          op = c; nx = substr(t, i + 1, 1)
          if (c == "<" && nx == "<") {
            i++; op = "<<"; nx = substr(t, i + 1, 1)
            if (nx == "<") { i++; op = "<<<" } else if (nx == "-") { i++; op = "<<-" }
          } else if (nx == ">" || nx == "|" || nx == "&") { i++; op = op nx }
          if (op == "<<" || op == "<<-") {
            while (substr(t, i + 1, 1) == " " || substr(t, i + 1, 1) == "\t") i++
            # The delimiter is one shell word: quoted pieces keep their
            # spaces (<<'"'"'E OF'"'"'), and quote characters are removed.
            # A backslash-newline inside it joins lines (<<E\<nl>OF is EOF).
            # Any quoting makes the body literal, with no line joining.
            d = ""; dq = 0
            while (i < n) {
              nc = substr(t, i + 1, 1)
              if (nc == "\\" && substr(t, i + 2, 1) == "\n") { i += 2; continue }
              if (nc == " " || nc == "\t" || nc == "\n" || nc == ";" || nc == "&" || nc == "|" || nc == "<" || nc == ">" || nc == "(" || nc == ")") break
              i++
              if (nc == "\047" || nc == "\"") {
                dq = 1
                while (i < n && substr(t, i + 1, 1) != nc) { i++; d = d substr(t, i, 1) }
                i++
              } else if (nc == "\\") {
                dq = 1
                i++; d = d substr(t, i, 1)
              } else d = d nc
            }
            nh++; hd[nh] = d; hdash[nh] = (op == "<<-"); hquoted[nh] = dq
            continue
          }
          printf "R\036"
          continue
        }
        if (c == ";" || c == "|" || c == "(" || c == ")") { endcmd(); continue }
        if (c == "&") {
          if (substr(t, i + 1, 1) == ">") { flush(); i++; if (substr(t, i + 1, 1) == ">") i++; printf "R\036"; continue }
          endcmd(); continue
        }
        startw(i); w = w c
      }
      endcmd()
      printf "Z\036"
    }'
}

# Set scope_inline_paren_end to the index of the `)` that closes the `(` at
# <index> in <text> (quote-aware), or to the text length when it never closes.
scope_inline_match_paren() {
  local text="${1:-}" i="${2:-0}" depth=0 q="" ch len
  len=${#text}
  scope_inline_paren_end=$len
  while [ "$i" -lt "$len" ]; do
    ch="${text:i:1}"
    if [ "$q" = "'" ] || [ "$q" = A ]; then
      if [ "$q" = A ] && [ "$ch" = "\\" ]; then
        i=$((i + 2))
        continue
      fi
      if [ "$ch" = "'" ]; then q=""; fi
      i=$((i + 1))
      continue
    fi
    if [ -z "$q" ] && [ "$ch" = '$' ] && [ "${text:$((i + 1)):1}" = "'" ]; then
      q=A
      i=$((i + 2))
      continue
    fi
    case "$ch" in
      \\) i=$((i + 1)) ;;
      '"') if [ "$q" = '"' ]; then q=""; else q='"'; fi ;;
      "'") if [ -z "$q" ]; then q="'"; fi ;;
      '(') if [ -z "$q" ]; then depth=$((depth + 1)); fi ;;
      ')')
        if [ -z "$q" ]; then
          depth=$((depth - 1))
          if [ "$depth" -eq 0 ]; then
            scope_inline_paren_end=$i
            return 0
          fi
        fi
        ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# Print the value(s) a `$name` use after <prefix> in <text> is proven to have,
# one per line, or return 1. Proof is what the path checks already accept: an
# assignment the shell must run first, a for loop over literal words, a
# literal argument at a known function call, $HOME, $HQ_ROOT, a mktemp
# assignment. $PWD is the command's working directory.
# $TMPDIR is not proven here. The path checks read it from the hook's own
# environment, but a program run by `sh -c` or an interpreter gets whatever
# environment its launcher passes, so only a literal assignment in the
# command proves it (scope_shell_variable_values below).
scope_inline_name_values() {
  local name="${1:-}" prefix="${2:-}" text="${3:-}" known_value values
  case "$name" in
    PWD) printf '%s\n' "${COMMAND_CWD:-$PAYLOAD_CWD}"; return 0 ;;
    0) printf 'sh\n'; return 0 ;;
    [1-9]|TMPDIR) ;;
    *)
      known_value="$(scope_resolve_known_path_expansions "\$$name" "$text" "$prefix")"
      case "$known_value" in
        *'$'*) ;;
        *) printf '%s\n' "$known_value"; return 0 ;;
      esac
      ;;
  esac
  values="$(scope_shell_variable_values "$name" "$prefix" "$text" 2>/dev/null || true)"
  [ -n "$values" ] || return 1
  printf '%s\n' "$values"
}

# True when <value>, pasted between <before> and <after>, completes a
# `companies` segment that neither the value nor the literal text holds alone
# (`D=/abs/hq/compan; python3 -c "open('${D}ies/otherco/x','w')"`). A value
# that contains the whole word is literal text in the command, where the
# companies/ scan above already checks it.
scope_inline_value_glues_company() {
  local before="${1:-}" value="${2:-}" after="${3:-}" b a s vs ve rest pre st en base=0
  before="${before//[\"\']/}"
  after="${after//[\"\']/}"
  b="${before:$(( ${#before} > 8 ? ${#before} - 8 : 0 ))}"
  a="${after:0:8}"
  s="$(printf '%s' "$b$value$a" | tr '[:upper:]' '[:lower:]')"
  vs=${#b}
  ve=$((vs + ${#value}))
  rest="$s"
  while [[ "$rest" == *companies* ]]; do
    pre="${rest%%companies*}"
    st=$((base + ${#pre}))
    en=$((st + 9))
    if [ "$st" -lt "$ve" ] && [ "$en" -gt "$vs" ] && ! { [ "$st" -ge "$vs" ] && [ "$en" -le "$ve" ]; }; then
      return 0
    fi
    base=$((st + 1))
    rest="${s:$base}"
  done
  return 1
}

# Walk the program text an inner shell receives (`bash -c '<text>'`) and block
# on any variable it expands that is not set inside <text>, not given by a
# VAR=literal prefix on the same command (<env_names>), and not $HOME/$PWD.
# Positional parameters ($1, $@) are allowed only when every argument after
# the program is literal (<args_literal> = 1), as in find -exec sh -c '...' _ {}.
scope_inline_check_inner_shell() {
  local text="${1:-}" env_names="${2:-}" args_literal="${3:-0}" what="${4:-the shell program}"
  local len i=0 q="" ch nx name content start
  len=${#text}
  while [ "$i" -lt "$len" ]; do
    ch="${text:i:1}"
    if [ "$q" = "'" ] || [ "$q" = A ]; then
      if [ "$q" = A ] && [ "$ch" = "\\" ]; then
        i=$((i + 2))
        continue
      fi
      if [ "$ch" = "'" ]; then q=""; fi
      i=$((i + 1))
      continue
    fi
    if [ -z "$q" ] && [ "$ch" = '$' ] && [ "${text:$((i + 1)):1}" = "'" ]; then
      q=A
      i=$((i + 2))
      continue
    fi
    case "$ch" in
      \\) i=$((i + 2)); continue ;;
      '"') if [ "$q" = '"' ]; then q=""; else q='"'; fi; i=$((i + 1)); continue ;;
      "'") if [ -z "$q" ]; then q="'"; fi; i=$((i + 1)); continue ;;
      '$') ;;
      *) i=$((i + 1)); continue ;;
    esac
    start=$i
    nx="${text:$((i + 1)):1}"
    case "$nx" in
      '{')
        content="${text:$((i + 2))}"
        content="${content%%\}*}"
        if [[ "$content" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || [[ "$content" =~ ^[0-9]+$ ]]; then
          name="$content"
          i=$((i + 3 + ${#content}))
        else
          scope_block_rel "\${$content}" "$what expands a parameter form the guard cannot check; set a plain variable with a literal value inside the program"
        fi
        ;;
      [A-Za-z_])
        name="${text:$((i + 1))}"
        name="${name%%[!A-Za-z0-9_]*}"
        i=$((i + 1 + ${#name}))
        ;;
      [0-9]) name="$nx"; i=$((i + 2)) ;;
      '@'|'*') name="@"; i=$((i + 2)) ;;
      *) i=$((i + 1)); continue ;;
    esac
    case "$name" in
      HOME|PWD|0) continue ;;
    esac
    scope_inline_is_plain_name "$name" && continue
    if [[ "$name" =~ ^[0-9]+$ ]] || [ "$name" = "@" ]; then
      [ "$args_literal" = 1 ] && continue
      if [ "$name" != "@" ] && [ -n "$(scope_shell_variable_values "$name" "${text:0:$start}" "$text" 2>/dev/null || true)" ]; then
        continue
      fi
      scope_block_rel "\$$name" "$what reads a positional parameter, and the arguments after the program are not all literal"
    fi
    [[ " $env_names " == *" $name "* ]] && continue
    scope_inline_name_values "$name" "${text:0:$start}" "$text" >/dev/null && continue
    scope_block_rel "\$$name" "$what runs in a new shell that expands \$$name from the environment, and neither the program nor a $name=value prefix on this command sets it"
  done
  return 0
}

# Check one program or directory word. <raw> is the word as typed (quotes
# kept) and <off> its byte offset in scope_inline_text. <kind> is dir or
# program; <interp> is python, node, ruby, perl, or shell for a program.
scope_inline_expansions_check_word() {
  local raw="${1:-}" off="${2:-0}" kind="${3:-dir}" interp="${4:-}" env_names="${5:-}" args_literal="${6:-0}" what="${7:-the directory option}"
  local len i=0 q="" ch nx name content sub inner="" values value start pos handoff=0
  len=${#raw}
  while [ "$i" -lt "$len" ]; do
    ch="${raw:i:1}"
    if [ "$q" = "'" ]; then
      if [ "$ch" = "'" ]; then q=""; else inner+="$ch"; fi
      i=$((i + 1))
      continue
    fi
    if [ "$q" = A ]; then
      # Inside $'...': \' does not end the string, and a numeric escape
      # (\x24, \044, $) can spell `$` or a path the guard cannot read.
      if [ "$ch" = "\\" ]; then
        nx="${raw:$((i + 1)):1}"
        case "$nx" in
          [0-7]|x|u|U|c) scope_block_rel "\$'...'" "$what uses a \$'...' escape (\\$nx) the guard cannot check; write the text plainly" ;;
          n) inner+=$'\n' ;;
          t) inner+=$'\t' ;;
          *) inner+="$nx" ;;
        esac
        i=$((i + 2))
        continue
      fi
      if [ "$ch" = "'" ]; then q=""; else inner+="$ch"; fi
      i=$((i + 1))
      continue
    fi
    if [ "$ch" = "\\" ]; then
      nx="${raw:$((i + 1)):1}"
      if [ "$q" = '"' ]; then
        case "$nx" in
          '$'|$'\140'|'"'|\\) inner+="$nx" ;;
          $'\n') ;;
          *) inner+="\\$nx" ;;
        esac
      else
        inner+="$nx"
      fi
      i=$((i + 2))
      continue
    fi
    if [ "$ch" = '"' ]; then
      if [ "$q" = '"' ]; then q=""; else q='"'; fi
      i=$((i + 1))
      continue
    fi
    if [ -z "$q" ] && [ "$ch" = "'" ]; then
      q="'"
      i=$((i + 1))
      continue
    fi
    if [ "$ch" = $'\140' ]; then
      scope_block_rel "\$(...)" "a command substitution in $what cannot be checked; run it first and pass the literal value"
    fi
    if [ "$ch" != '$' ]; then
      inner+="$ch"
      i=$((i + 1))
      continue
    fi
    start=$i
    pos=$((off + i))
    nx="${raw:$((i + 1)):1}"
    name=""
    case "$nx" in
      '(')
        scope_inline_match_paren "$raw" "$((i + 1))"
        if [ "${raw:$((i + 2)):1}" = '(' ]; then
          # $((...)) is arithmetic: its value is a number.
          inner+="0"
          i=$((scope_inline_paren_end + 1))
          continue
        fi
        sub="${raw:$i:$((scope_inline_paren_end - i + 1))}"
        # $(pwd) is the command's working directory, and the repo top level
        # is the root of the repo that contains it. Both name the place a
        # plain relative path would already reach.
        case "$sub" in
          '$(pwd)'|'$(pwd -P)'|'$(pwd -L)'|'$(git rev-parse --show-toplevel)')
            inner+="${COMMAND_CWD:-.}"
            i=$((scope_inline_paren_end + 1))
            continue
            ;;
        esac
        scope_block_rel "$sub" "a command substitution in $what cannot be checked; run it first and pass the literal value"
        ;;
      '{')
        content="${raw:$((i + 2))}"
        content="${content%%\}*}"
        if [[ "$content" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || [[ "$content" =~ ^[0-9]+$ ]]; then
          name="$content"
          i=$((i + 3 + ${#content}))
        else
          scope_block_rel "\${$content}" "$what uses a parameter expansion form the guard cannot check; set a plain variable with a literal value in the same command"
        fi
        ;;
      [A-Za-z_])
        name="${raw:$((i + 1))}"
        name="${name%%[!A-Za-z0-9_]*}"
        i=$((i + 1 + ${#name}))
        ;;
      [0-9]) name="$nx"; i=$((i + 2)) ;;
      '@'|'*')
        scope_block_rel "\$$nx" "$what expands all positional parameters, which this command does not set"
        ;;
      '$'|'?'|'#'|'!'|'-') inner+="0"; i=$((i + 2)); continue ;;
      "'"|'"')
        # $'...' and $"..." are quoting forms, not expansions.
        if [ -z "$q" ]; then
          if [ "$nx" = "'" ]; then q=A; else q='"'; fi
          i=$((i + 2))
          continue
        fi
        inner+='$'
        i=$((i + 1))
        continue
        ;;
      *) inner+='$'; i=$((i + 1)); continue ;;
    esac
    if [ "$kind" = program ] && scope_inline_is_plain_name "$name"; then
      inner+="__HQ_EXPANDED__"
      continue
    fi
    values="$(scope_inline_name_values "$name" "${scope_inline_text:0:$pos}" "$scope_inline_text")" \
      || scope_block_rel "\$$name" "$what uses \$$name, which this command does not set; the shell fills it from the environment before the command runs, so it can name another company's folder"
    while IFS= read -r value; do
      if scope_inline_value_glues_company "${raw:0:$start}" "$value" "${raw:$i}"; then
        scope_block_rel "\$$name" "$what joins \$$name to literal text to spell a companies/ path; spell the path literally"
      fi
    done <<< "$values"
    inner+="__HQ_EXPANDED__"
  done
  [ "$kind" = program ] || return 0
  case "$interp" in
    shell)
      scope_inline_check_inner_shell "$inner" "$env_names" "$args_literal" "$what"
      ;;
    *)
      # A node require of a core module that cannot start a process or run
      # code is not a hand-off (scope_interp_safe_require_re, shared with the
      # heredoc body check). Such a program can still write files, so, as in
      # that check, an expansion next to a `/` keeps the hand-off rule: the
      # loop below then needs each name set in the command.
      local handoff_text="$inner" safe_stripped=0
      if [ "$interp" = node ]; then
        while [[ "$handoff_text" =~ $scope_interp_safe_require_re ]]; do
          handoff_text="${handoff_text/"${BASH_REMATCH[0]}"/ }"
          safe_stripped=1
        done
      fi
      if [[ "$handoff_text" =~ $scope_interp_handoff_re ]]; then
        handoff=1
      elif [ "$safe_stripped" -eq 1 ] \
        && [[ "$inner" =~ (\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/|/\$\{?[A-Za-z_]) ]]; then
        handoff=1
      fi
      case "$interp" in
        perl|ruby)
          case "$inner" in *$'\140'*|*qx*|*'%x'*) handoff=1 ;; esac
          ;;
      esac
      [ "$handoff" -eq 1 ] || return 0
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        name="${name#\$}"
        name="${name#\{}"
        case "$name" in HOME|PWD) continue ;; esac
        scope_inline_is_plain_name "$name" && continue
        [[ " $env_names " == *" $name "* ]] && continue
        scope_block_rel "\$$name" "$what can start a shell, and that shell expands \$$name from the environment; set it with a $name=value prefix on this command or spell the value literally"
      done <<< "$(printf '%s' "$inner" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' 2>/dev/null || true)"
      ;;
  esac
  return 0
}

# Check the word at <index> of w_raw, or its text after <skip> leading bytes
# (`--git-dir=$R`), as a directory option value.
scope_inline_check_dir_at() {
  local index="${1:-0}" skip="${2:-0}" what="${3:-the directory option}"
  [ "$index" -lt "${scope_inline_end:-0}" ] || return 0
  scope_inline_expansions_check_word "${w_raw[$index]:$skip}" "$(( ${w_off[$index]} + skip ))" dir "" "" 0 "$what"
}

# Parse <word> as a getopt short-option cluster (-abc). <argletters> are the
# options that take an argument; the first one in the cluster takes the rest
# of the cluster, or the next word when it is last. When that option is one
# of <targets>, set scope_inline_cluster_hit to "attached <byte offset>" or
# "next". scope_inline_cluster_consumed is the number of following words the
# cluster uses (0 or 1).
scope_inline_cluster_arg() {
  local word="${1:-}" argletters="${2:-}" targets="${3:-}" p ch
  scope_inline_cluster_hit=""
  scope_inline_cluster_consumed=0
  [[ "$word" =~ ^-[A-Za-z0-9] ]] || return 0
  p=1
  while [ "$p" -lt "${#word}" ]; do
    ch="${word:p:1}"
    case "$argletters" in
      *"$ch"*)
        if [ "$((p + 1))" -lt "${#word}" ]; then
          case "$targets" in *"$ch"*) scope_inline_cluster_hit="attached $((p + 1))" ;; esac
        else
          scope_inline_cluster_consumed=1
          case "$targets" in *"$ch"*) scope_inline_cluster_hit="next" ;; esac
        fi
        return 0
        ;;
    esac
    p=$((p + 1))
  done
  return 0
}

# Parse <word> as an interpreter's short-option cluster and find where its
# program option (one of <prog>) takes its program text. Option letters in
# <arg> take the rest of the cluster or the next word; letters in <restonly>
# take only the rest of the cluster; a letter in <stop> ends option parsing
# (python -m); letters in <digits> take following digits (perl -l0, -0777).
# Sets scope_inline_cluster_hit ("attached <offset>", "next" or empty),
# scope_inline_cluster_consumed (following words used) and
# scope_inline_cluster_stop.
scope_inline_program_cluster() {
  local word="${1:-}" prog="${2:-}" arg="${3:-}" restonly="${4:-}" stop="${5:-}" digits="${6:-}" p ch
  scope_inline_cluster_hit=""
  scope_inline_cluster_consumed=0
  scope_inline_cluster_stop=0
  p=1
  while [ "$p" -lt "${#word}" ]; do
    ch="${word:p:1}"
    case "$prog" in
      *"$ch"*)
        if [ "$((p + 1))" -lt "${#word}" ]; then
          scope_inline_cluster_hit="attached $((p + 1))"
        else
          scope_inline_cluster_hit="next"
          scope_inline_cluster_consumed=1
        fi
        return 0
        ;;
    esac
    case "$arg" in
      *"$ch"*)
        [ "$((p + 1))" -lt "${#word}" ] || scope_inline_cluster_consumed=1
        return 0
        ;;
    esac
    case "$restonly" in *"$ch"*) return 0 ;; esac
    case "$stop" in *"$ch"*) scope_inline_cluster_stop=1; return 0 ;; esac
    case "$digits" in
      *"$ch"*)
        while [ "$((p + 1))" -lt "${#word}" ] && [[ "${word:$((p + 1)):1}" == [0-9] ]]; do p=$((p + 1)); done
        ;;
    esac
    p=$((p + 1))
  done
  return 0
}

# Check the program found by scope_inline_program_cluster in the word at
# <index> of w_raw: attached to the cluster, or the next word.
scope_inline_check_program_hit() {
  local index="${1:-0}" interp="${2:-}" env_names="${3:-}" args_literal="${4:-0}" what="${5:-the program}" skip
  case "$scope_inline_cluster_hit" in
    attached\ *)
      skip="${scope_inline_cluster_hit#attached }"
      scope_inline_expansions_check_word "${w_raw[$index]:$skip}" "$(( ${w_off[$index]} + skip ))" program "$interp" "$env_names" "$args_literal" "$what"
      ;;
    next)
      [ "$((index + 1))" -lt "${scope_inline_end:-0}" ] || return 0
      scope_inline_expansions_check_word "${w_raw[$((index + 1))]}" "${w_off[$((index + 1))]}" program "$interp" "$env_names" "$args_literal" "$what"
      ;;
  esac
  return 0
}

# True when the shell expands nothing in <word>: no unescaped `$` or backtick
# outside single quotes. Double quotes are tracked, so the `'` inside "'$F'"
# does not hide the expansion (scope_mask_literal_expansions does not track
# double quotes and would read it as single-quoted).
scope_inline_word_is_literal() {
  local word="${1:-}" i=0 q="" ch len
  len=${#word}
  while [ "$i" -lt "$len" ]; do
    ch="${word:i:1}"
    if [ "$q" = "'" ] || [ "$q" = A ]; then
      if [ "$q" = A ] && [ "$ch" = "\\" ]; then
        # A numeric escape can spell any text, so the value is not known.
        case "${word:$((i + 1)):1}" in [0-7]|x|u|U|c) return 1 ;; esac
        i=$((i + 2))
        continue
      fi
      if [ "$ch" = "'" ]; then q=""; fi
      i=$((i + 1))
      continue
    fi
    case "$ch" in
      \\) i=$((i + 2)); continue ;;
      '"') if [ "$q" = '"' ]; then q=""; else q='"'; fi ;;
      "'") if [ -z "$q" ]; then q="'"; fi ;;
      '$')
        # $'...' is a quoting form; its numeric escapes are not literal.
        if [ -z "$q" ] && [ "${word:$((i + 1)):1}" = "'" ]; then
          q=A
          i=$((i + 2))
          continue
        fi
        return 1
        ;;
      $'\140') return 1 ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# Set scope_inline_head to the command name bash runs for <word>: quotes and
# backslashes removed (\git, "git", $'git' all run git), directory part
# dropped. A $'...' with an escape can spell any name, so it blocks. (Not a
# $(...) helper: inside the check's subshell, set -e is off, so a block in a
# command substitution would not stop the check.)
scope_inline_head_name() {
  local word="${1:-}"
  case "$word" in
    *"\$'"*\\*) scope_block_rel "\$'...'" "the command name uses a \$'...' escape the guard cannot check; type the name plainly" ;;
  esac
  word="${word//\$\'/}"
  word="${word//[\"\'\\]/}"
  scope_inline_head="${word##*/}"
}

# When the assignment word at <index> of w_raw sets a git location variable
# (GIT_DIR=$R git log), check its value like a directory option.
scope_inline_check_git_env_at() {
  local index="${1:-0}" word name
  word="${w_raw[$index]:-}"
  [[ "$word" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || return 0
  name="${word%%=*}"
  case "$name" in
    GIT_DIR|GIT_WORK_TREE|GIT_COMMON_DIR|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_CONFIG|GIT_CONFIG_GLOBAL|GIT_CONFIG_SYSTEM|GIT_EXEC_PATH|GIT_TEMPLATE_DIR|GIT_SSH|GIT_SSH_COMMAND)
      scope_inline_check_dir_at "$index" "$(( ${#name} + 1 ))" "the $name assignment"
      ;;
  esac
  return 0
}

# Print 1 when the --long option at <index> of w_raw (no `=value`) is
# followed by a word that is not an option, else 0. That word is read as
# the option's argument (python --check-hash-based-pycs always, node
# --input-type module), so the scan keeps looking for -c/-e after it
# instead of stopping as if it were the script.
scope_inline_long_option_arg() {
  local index="${1:-0}" next
  case "${w_raw[$index]:-}" in *=*) printf '0'; return 0 ;; esac
  next="${w_raw[$((index + 1))]:-}"
  case "$next" in
    ''|-*) printf '0' ;;
    *) printf '1' ;;
  esac
}

# Check the simple command in w_raw/w_off from <start> up to <end>.
scope_inline_expansions_check_command() {
  local start="${1:-0}" end="${2:-0}" i word head flag env_names="" j k n_args has_c args_literal via_xargs=0 scope_inline_end
  scope_inline_end="$end"
  i="$start"
  while [ "$i" -lt "$end" ]; do
    word="${w_raw[$i]}"
    if [[ "$word" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      scope_inline_check_git_env_at "$i"
      scope_inline_word_is_literal "${word#*=}" && env_names+=" ${word%%=*}"
      i=$((i + 1))
      continue
    fi
    scope_inline_head_name "$word"
    head="$scope_inline_head"
    case "$head" in
      do|then|else|elif|'!'|'{'|if|while|until|nohup|builtin|exec|stdbuf) i=$((i + 1)) ;;
      export|declare|typeset|local|readonly)
        # `export GIT_DIR=$R` points every later git at $R.
        for ((k = i + 1; k < end; k++)); do scope_inline_check_git_env_at "$k"; done
        return 0
        ;;
      caffeinate|arch)
        i=$((i + 1))
        while [ "$i" -lt "$end" ]; do
          case "${w_raw[$i]}" in
            -t|-w|-e) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      command|time)
        i=$((i + 1))
        while [ "$i" -lt "$end" ] && [[ "${w_raw[$i]}" == -* ]]; do i=$((i + 1)); done
        ;;
      nice|timeout|xargs)
        # xargs appends words from its input after the ones typed here.
        if [ "$head" = xargs ]; then via_xargs=1; fi
        i=$((i + 1))
        while [ "$i" -lt "$end" ]; do
          case "${w_raw[$i]}" in
            -n|-s|-k|-I|-P|-L|-d|-E|-a|--signal|--kill-after) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        # timeout's first operand is the duration.
        if [ "$head" = timeout ]; then i=$((i + 1)); fi
        ;;
      env|sudo)
        i=$((i + 1))
        while [ "$i" -lt "$end" ]; do
          word="${w_raw[$i]}"
          case "$head:$word" in
            env:--chdir|sudo:--chdir)
              scope_inline_check_dir_at "$((i + 1))" 0 "the $head $word option"
              i=$((i + 2))
              ;;
            env:--chdir=*|sudo:--chdir=*)
              scope_inline_check_dir_at "$i" 8 "the $head --chdir option"
              i=$((i + 1))
              ;;
            env:--split-string|env:--split-string=*)
              # env -S splits (and expands ${VAR} in) its own command line.
              scope_inline_word_is_literal "${w_raw[$((i + 1))]:-}" \
                || scope_block_rel "env -S" "env -S expands variables in its command string; run the command directly"
              i=$((i + 2))
              ;;
            env:--unset|sudo:--user|sudo:--group|sudo:--host|sudo:--prompt|sudo:--role|sudo:--type|sudo:--other-user|sudo:--command-timeout|sudo:--close-from)
              i=$((i + 2))
              ;;
            *:--*) i=$((i + 1)) ;;
            *:-?*)
              # A short-option cluster (-iC dir, -C$R, -uroot -D dir).
              if [ "$head" = env ]; then
                scope_inline_cluster_arg "$word" uCS C
              else
                scope_inline_cluster_arg "$word" ugCDhprtUT D
              fi
              case "$scope_inline_cluster_hit" in
                attached\ *) scope_inline_check_dir_at "$i" "${scope_inline_cluster_hit#attached }" "the $head $word option" ;;
                next) scope_inline_check_dir_at "$((i + 1))" 0 "the $head $word option" ;;
              esac
              if [ "$head" = env ] && [[ "$word" =~ ^-[A-Za-z]*S ]]; then
                scope_inline_word_is_literal "$word${w_raw[$((i + 1))]:-}" \
                  || scope_block_rel "env -S" "env -S expands variables in its command string; run the command directly"
              fi
              i=$((i + 1 + scope_inline_cluster_consumed))
              ;;
            *)
              if [[ "$word" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
                scope_inline_word_is_literal "${word#*=}" && env_names+=" ${word%%=*}"
                i=$((i + 1))
              else
                break
              fi
              ;;
          esac
        done
        ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$end" ] || return 0
  scope_inline_head_name "${w_raw[$i]}"
  head="$scope_inline_head"
  case "$head" in *'$'*|*$'\140'*) return 0 ;; esac
  j=$((i + 1))
  case "$head" in
    python|python[0-9]*|pypy|pypy[0-9]*)
      while [ "$j" -lt "$end" ]; do
        word="${w_raw[$j]}"
        case "$word" in
          -|--) return 0 ;;
          --*) j=$((j + 1 + $(scope_inline_long_option_arg "$j"))) ;;
          -*)
            # -c takes the program, attached (-c"...") or as the next word,
            # and ends option parsing. -m names a module instead.
            scope_inline_program_cluster "$word" c WX "" m ""
            if [ -n "$scope_inline_cluster_hit" ]; then
              scope_inline_check_program_hit "$j" python "$env_names" 0 "the $head -c program"
              return 0
            fi
            [ "$scope_inline_cluster_stop" -eq 0 ] || return 0
            j=$((j + 1 + scope_inline_cluster_consumed))
            ;;
          *) return 0 ;;
        esac
      done
      ;;
    node|nodejs)
      while [ "$j" -lt "$end" ]; do
        word="${w_raw[$j]}"
        case "$word" in
          -e|-p|-pe|-ep|--eval|--print)
            [ "$((j + 1))" -lt "$end" ] || return 0
            scope_inline_expansions_check_word "${w_raw[$((j + 1))]}" "${w_off[$((j + 1))]}" program node "$env_names" 0 "the $head $word program"
            return 0
            ;;
          --eval=*|--print=*)
            flag="${word%%=*}"
            scope_inline_expansions_check_word "${word#*=}" "$(( ${w_off[$j]} + ${#flag} + 1 ))" program node "$env_names" 0 "the $head $flag program"
            return 0
            ;;
          -r|-C) j=$((j + 2)) ;;
          --*) j=$((j + 1 + $(scope_inline_long_option_arg "$j"))) ;;
          -*) j=$((j + 1)) ;;
          *) return 0 ;;
        esac
      done
      ;;
    ruby|perl)
      while [ "$j" -lt "$end" ]; do
        word="${w_raw[$j]}"
        case "$word" in
          -|--) return 0 ;;
          --*) j=$((j + 1 + $(scope_inline_long_option_arg "$j"))); continue ;;
          -*) ;;
          *) return 0 ;;
        esac
        # Each -e adds a program line, attached (-e'...') or as the next
        # word; options before it may take the rest of the cluster.
        if [ "$head" = ruby ]; then
          case "$word" in
            -C) scope_inline_check_dir_at "$((j + 1))" 0 "the ruby -C option" ;;
            -C?*) scope_inline_check_dir_at "$j" 2 "the ruby -C option" ;;
          esac
          scope_inline_program_cluster "$word" e rICE FWKxi "" 0
        else
          scope_inline_program_cluster "$word" eE I MmFxiCdD "" l0
        fi
        if [ -n "$scope_inline_cluster_hit" ]; then
          scope_inline_check_program_hit "$j" "$head" "$env_names" 0 "the $head -e program"
        fi
        j=$((j + 1 + scope_inline_cluster_consumed))
      done
      ;;
    bash|sh|zsh|dash|ksh)
      has_c=0
      while [ "$j" -lt "$end" ]; do
        word="${w_raw[$j]}"
        case "$word" in
          -o|+o|-O|+O|--rcfile|--init-file) j=$((j + 2)) ;;
          --) j=$((j + 1)); break ;;
          --*) j=$((j + 1)) ;;
          -*c*) has_c=1; j=$((j + 1)) ;;
          -*|+*) j=$((j + 1)) ;;
          *) break ;;
        esac
      done
      [ "$has_c" -eq 1 ] && [ "$j" -lt "$end" ] || return 0
      args_literal=1
      [ "$via_xargs" -eq 0 ] || args_literal=0
      for ((k = j + 1; k < end; k++)); do
        if ! scope_inline_word_is_literal "${w_raw[$k]}"; then
          args_literal=0
          break
        fi
      done
      scope_inline_expansions_check_word "${w_raw[$j]}" "${w_off[$j]}" program shell "$env_names" "$args_literal" "the $head -c program"
      ;;
    git)
      while [ "$j" -lt "$end" ]; do
        word="${w_raw[$j]}"
        case "$word" in
          -C|--git-dir|--work-tree)
            scope_inline_check_dir_at "$((j + 1))" 0 "the git $word option"
            j=$((j + 2))
            ;;
          --git-dir=*|--work-tree=*)
            flag="${word%%=*}"
            scope_inline_check_dir_at "$j" "$(( ${#flag} + 1 ))" "the git $flag option"
            j=$((j + 1))
            ;;
          -c)
            # -c core.worktree=$R, core.hooksPath=$R, ... point git at a
            # directory; check the value of every -c.
            word="${w_raw[$((j + 1))]:-}"
            if [[ "$word" == *=* ]]; then
              flag="${word%%=*}"
              scope_inline_check_dir_at "$((j + 1))" "$(( ${#flag} + 1 ))" "the git -c $flag value"
            fi
            j=$((j + 2))
            ;;
          --config-env|--namespace) j=$((j + 2)) ;;
          -*) j=$((j + 1)) ;;
          *) break ;;
        esac
      done
      ;;
    make|gmake|tar|gtar|bsdtar|pnpm|npm|yarn)
      while [ "$j" -lt "$end" ]; do
        word="${w_raw[$j]}"
        case "$head:$word" in
          make:-C|gmake:-C|make:--directory|gmake:--directory|tar:-C|gtar:-C|bsdtar:-C|tar:--directory|gtar:--directory|bsdtar:--directory|pnpm:-C|pnpm:--dir|npm:-C|npm:--prefix|yarn:--cwd)
            scope_inline_check_dir_at "$((j + 1))" 0 "the $head $word option"
            j=$((j + 2))
            ;;
          make:--directory=*|gmake:--directory=*|tar:--directory=*|gtar:--directory=*|bsdtar:--directory=*|pnpm:--dir=*|npm:--prefix=*|yarn:--cwd=*)
            flag="${word%%=*}"
            scope_inline_check_dir_at "$j" "$(( ${#flag} + 1 ))" "the $head $flag option"
            j=$((j + 1))
            ;;
          pnpm:-C?*|npm:-C?*)
            scope_inline_check_dir_at "$j" 2 "the $head -C option"
            j=$((j + 1))
            ;;
          make:--*|gmake:--*|tar:--*|gtar:--*|bsdtar:--*) j=$((j + 1)) ;;
          make:-?*|gmake:-?*|tar:-?*|gtar:-?*|bsdtar:-?*)
            # Short-option clusters: -sC dir, -C$R, -xzC dir.
            case "$head" in
              *make) scope_inline_cluster_arg "$word" CfIoW C ;;
              *) scope_inline_cluster_arg "$word" bCfFTXgKLNVHI C ;;
            esac
            case "$scope_inline_cluster_hit" in
              attached\ *) scope_inline_check_dir_at "$j" "${scope_inline_cluster_hit#attached }" "the $head $word option" ;;
              next) scope_inline_check_dir_at "$((j + 1))" 0 "the $head $word option" ;;
            esac
            j=$((j + 1 + scope_inline_cluster_consumed))
            ;;
          tar:[A-Za-z]*|gtar:[A-Za-z]*|bsdtar:[A-Za-z]*)
            # Old-style first word (`tar xfC a.tar dir`): each letter that
            # takes an argument takes the next unused word, in order.
            if [ "$j" -eq "$((i + 1))" ] && [[ "$word" =~ ^[A-Za-z]+$ ]]; then
              k=0
              n_args=0
              while [ "$k" -lt "${#word}" ]; do
                case "${word:k:1}" in
                  [bCfFTXgKLNVHI])
                    n_args=$((n_args + 1))
                    if [ "${word:k:1}" = C ]; then
                      scope_inline_check_dir_at "$((j + n_args))" 0 "the $head $word option"
                    fi
                    ;;
                esac
                k=$((k + 1))
              done
            fi
            j=$((j + 1))
            ;;
          *) j=$((j + 1)) ;;
        esac
      done
      ;;
    find)
      while [ "$j" -lt "$end" ]; do
        case "${w_raw[$j]}" in
          -exec|-execdir|-ok|-okdir)
            k=$((j + 1))
            while [ "$k" -lt "$end" ]; do
              case "${w_raw[$k]}" in
                '\;'|"';'"|'";"'|'+') break ;;
              esac
              k=$((k + 1))
            done
            scope_inline_expansions_check_command "$((j + 1))" "$k"
            scope_inline_end="$end"
            j=$((k + 1))
            ;;
          *) j=$((j + 1)) ;;
        esac
      done
      ;;
  esac
  return 0
}

# Lex <text> (at byte offset <base> of scope_inline_text) and check each simple
# command, then each $(...) body that names a command this check reads.
scope_inline_expansions_scan() {
  local text="${1:-}" base="${2:-0}" depth="${3:-0}" rec kind rest off word skip=0 i finished=0
  local -a w_raw=() w_off=() s_body=() s_off=()
  if [ "$depth" -gt 4 ]; then
    scope_block_rel "\$(...)" "command substitutions are nested too deeply to check; run the inner commands separately"
  fi
  while IFS= read -r -d $'\036' rec; do
    kind="${rec:0:1}"
    case "$kind" in
      W)
        rest="${rec:2}"
        off="${rest%%$'\037'*}"
        word="${rest#*$'\037'}"
        if [ "$skip" -eq 1 ]; then
          skip=0
          continue
        fi
        w_raw[${#w_raw[@]}]="$word"
        w_off[${#w_off[@]}]=$((base + off - 1))
        ;;
      R) skip=1 ;;
      E)
        skip=0
        if [ "${#w_raw[@]}" -gt 0 ]; then
          scope_inline_expansions_check_command 0 "${#w_raw[@]}"
        fi
        w_raw=()
        w_off=()
        ;;
      S)
        rest="${rec:2}"
        s_off[${#s_off[@]}]=$((base + ${rest%%$'\037'*} - 1))
        s_body[${#s_body[@]}]="${rest#*$'\037'}"
        ;;
      Z) finished=1 ;;
    esac
  done < <(printf '%s' "$text" | scope_inline_lex)
  # A lexer that stopped early checked nothing after that point.
  [ "$finished" -eq 1 ] || return 3
  i=0
  while [ "$i" -lt "${#s_body[@]}" ]; do
    if scope_inline_expansions_wanted "${s_body[$i]}"; then
      # set -e is off in the check's subshell; pass a failure up by hand.
      scope_inline_expansions_scan "${s_body[$i]}" "${s_off[$i]}" "$((depth + 1))" || return $?
    fi
    i=$((i + 1))
  done
  return 0
}

case "$TOOL" in
  Read|Write|Edit|MultiEdit)
    # One jq for the path. A second parse put read-workspace and write-personal
    # at dirname+jq+jq, over the spawn budget of 2, on paths that never touch
    # repos/. The root-list check still runs on that same path.
    scope_tool_path="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')"
    scope_block_if_names_owner_roots "$scope_tool_path" path
    scope_check_raw "$scope_tool_path"
    # A relative path is opened from the payload cwd (feedback_ef130236).
    case "$scope_tool_path" in
      ''|/*|'~'*) ;;
      *) case "${PAYLOAD_CWD:-}" in "$HQ_ROOT"|'') ;; /*) scope_check_cwd_abs "${PAYLOAD_CWD%/}/$scope_tool_path" ;; esac ;;
    esac
    ;;
  NotebookEdit)
    scope_tool_path="$(printf '%s' "$INPUT" | jq -r '.tool_input.notebook_path // empty')"
    scope_check_raw "$scope_tool_path"
    case "$scope_tool_path" in
      ''|/*|'~'*) ;;
      *) case "${PAYLOAD_CWD:-}" in "$HQ_ROOT"|'') ;; /*) scope_check_cwd_abs "${PAYLOAD_CWD%/}/$scope_tool_path" ;; esac ;;
    esac
    ;;
  Grep|Glob)
    scope_search_root="$(printf '%s' "$INPUT" | jq -r '.tool_input.path // empty')"
    scope_search_root_is_implicit=0
    if [ -z "$scope_search_root" ]; then
      scope_search_root="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
      scope_search_root_is_implicit=1
    fi
    scope_search_root_rel="$(scope_resolve_payload_path "$scope_search_root")"
    # The search root as seen from the payload cwd: the companies/ folder, or
    # from inside companies/ the HQ root or above, is refused
    # (feedback_ef130236). An HQ-root search from the HQ root is unchanged.
    case "$scope_search_root" in
      /*) case "${PAYLOAD_CWD:-}" in "$HQ_ROOT"|'') ;; *) scope_check_cwd_abs "$scope_search_root" ;; esac ;;
      '~'*) ;;
      *)
        case "${PAYLOAD_CWD:-}" in
          /*) scope_check_cwd_abs "${PAYLOAD_CWD%/}/$scope_search_root" ;;
        esac
        ;;
    esac
    if [ "$TOOL" = Grep ] && [ "$scope_search_root_is_implicit" -eq 1 ] && [ -z "$scope_search_root_rel" ]; then
      # Grep's implicit HQ-root search skips hidden directories and symlink
      # directories. Avoid a broad whole-tree scan; explicit roots are scanned.
      :
    else
      scope_check_recursive_search_root "$scope_search_root"
    fi
    if [ "$TOOL" = "Glob" ]; then
      scope_pattern="$(printf '%s' "$INPUT" | jq -r '.tool_input.pattern // empty')"
      scope_prefix="$(scope_glob_static_prefix "$scope_pattern")"
      if [ -n "$scope_prefix" ]; then
        case "$scope_prefix" in
          /*) scope_pattern_root="$scope_prefix" ;;
          *) scope_pattern_root="${scope_search_root%/}/$scope_prefix" ;;
        esac
        scope_check_recursive_search_root "$scope_pattern_root"
      fi
    fi
    ;;
  Bash)
    cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
    [ -n "$cmd" ] || exit 0
    scope_arith_raw="$cmd"
    # ANSI-C ($'\x63ompanies') and locale ($"companies") quoting spell the
    # same words; check the decoded spelling (feedback_ef130236).
    case "$cmd" in
      *"\$'"*|*'$"'*) scope_decode_dollar_quotes "$cmd"; cmd="$SCOPE_DECODED_CMD" ;;
    esac
    # The whole command, for checks that must know everything it runs.
    SCOPE_FULL_CMD="$cmd"
    SCOPE_CD_APPLIED=0
    SCOPE_CD_REPO_ROOT=""
    SCOPE_LINK_MUTATION_DESTS=""
    SCOPE_REPO_CD_HANDLED=0
    scope_block_if_names_owner_roots "$cmd"
    # Inspect the original quoting before the path scanner decodes ANSI-C strings.
    if [ ! -f "${BASH_SOURCE[0]%/*}/bash-arith-subst-guard-lib.sh" ]; then
      printf '%s\n' 'BLOCKED: Bash arithmetic check. The arithmetic guard helper is missing; refresh the hook installation.' >&2
      exit 2
    fi
    . "${BASH_SOURCE[0]%/*}/bash-arith-subst-guard-lib.sh"
    if ! hq_arith_guard_check "$scope_arith_raw"; then
      hq_arith_guard_message
      exit 2
    fi
    scope_compute_shadowed_names "$cmd"
    # A command that opens with the session bind (see scope_load_bound_company).
    # Only the exact in-tree script, as the first simple command, followed by
    # `&&` (with `;` the rest runs even when the bind fails), with a plain
    # slug listed in companies/manifest.yaml and at most a --session-id for
    # this session. A relative script path counts only when the payload cwd
    # is HQ_ROOT, so a look-alike script elsewhere cannot stand in for it.
    SCOPE_SAME_CMD_BIND=""
    scope_same_bind_re='^[[:space:]]*(bash[[:space:]]+)?(\./|'"$HQ_ROOT"'/)?core/scripts/hq-session\.sh[[:space:]]+set[[:space:]]+company_slug[[:space:]]+([a-z0-9][a-z0-9_-]*)([[:space:]]+--session-id[[:space:]]+([A-Za-z0-9_-]+))?[[:space:]]*&&'
    if [[ "$cmd" =~ $scope_same_bind_re ]]; then
      scope_same_bind_slug="${BASH_REMATCH[3]}"
      scope_same_bind_sid="${BASH_REMATCH[5]}"
      scope_same_bind_path="${BASH_REMATCH[2]}"
      scope_same_bind_ok=1
      if [ "$scope_same_bind_path" != "$HQ_ROOT/" ]; then
        [ "$(cd "$COMMAND_CWD" 2>/dev/null && pwd -P)" = "$(cd "$HQ_ROOT" 2>/dev/null && pwd -P)" ] || scope_same_bind_ok=0
      fi
      if [ ! -f "$HQ_ROOT/companies/manifest.yaml" ] || [ -L "$HQ_ROOT/companies/manifest.yaml" ] \
        || ! grep -Eq "^  ${scope_same_bind_slug}:[[:space:]]*$" "$HQ_ROOT/companies/manifest.yaml" 2>/dev/null; then
        scope_same_bind_ok=0
      fi
      if [ "$scope_same_bind_ok" -eq 1 ] && { [ -z "$scope_same_bind_sid" ] || [ "$scope_same_bind_sid" = "$SESSION_ID" ]; }; then
        SCOPE_SAME_CMD_BIND="$scope_same_bind_slug"
      fi
    fi
    # A working directory inside another company makes every relative
    # operand that company's file (feedback_ef130236).
    case "${COMMAND_CWD:-}" in
      "$HQ_ROOT"|'') ;;
      /*) scope_check_raw "$COMMAND_CWD" ;;
    esac
    # `cd /abs/hq; grep x companies/co/policies/*.md`: a leading cd to a
    # literal, existing directory is where the rest of the command runs, so
    # globs and $(pwd) are expanded from there instead of the payload cwd.
    # Only when nothing later changes directory again; otherwise the payload
    # cwd stays and the checks below are unchanged.
    scope_cd_re='^[[:space:]]*cd[[:space:]]+("([^"$`\\]+)"|'"'([^']+)'"'|([^][[:space:];&|<>()"'"'"'$`\\*?{}~]+))[[:space:]]*(;|&&)'
    # $PWD and $(pwd) equal COMMAND_CWD only while nothing in the command
    # changes directory, apart from the leading cd handled below. After a
    # second cd (`cd workspace && cd ../companies && cat $PWD/x`) the shell's
    # $PWD is somewhere the hook did not follow, so those forms stay closed.
    scope_cwd_is_static=1
    scope_cd_any_re='(^|[;&|({[:space:]]|'$'\n'')(cd|pushd|popd)([[:space:]]|;|$)'
    if [[ "$cmd" =~ $scope_cd_any_re ]]; then
      scope_cwd_is_static=0
    fi
    # A chain of leading cds (`cd workspace/x/backend && cd ../frontend &&
    # ls`) is followed hop by hop: each target is resolved from the directory
    # the previous hop reached, must exist, and is checked as the path it
    # resolves to (a symlink into another tenant is refused here). A hop may
    # name a variable the command assigned once to a literal before it
    # (`B=workspace/x; cd "$B/backend" && ...`), proven by
    # scope_assignment_literal_value. Leading plain assignments are skipped.
    # The chain is applied only when nothing after it changes directory
    # again, as for a single cd (feedback dd75a03a, a150c7a2, 919788bb).
    scope_cd_again_re='(^|[;&|({[:space:]]|'$'\n'')(cd|pushd|popd)([[:space:]]|;|$)'
    scope_cd_chain_text="$cmd"
    scope_cd_chain_cwd="$COMMAND_CWD"
    scope_cd_chain_n=0
    scope_cd_chain_ok=1
    scope_cd_chain_repo_root=""
    scope_cd_assign_lead_re='^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=("[^"$`\\]*"|'"'"'[^'"'"']*'"'"'|[^][[:space:];&|<>()"'"'"'$`\\*?{}~]*)[[:space:]]*;'
    while [[ "$scope_cd_chain_text" =~ $scope_cd_assign_lead_re ]]; do
      scope_cd_chain_text="${scope_cd_chain_text#"${BASH_REMATCH[0]}"}"
    done
    scope_cd_var_lead_re='^[[:space:]]*cd[[:space:]]+("?)\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(/[^][[:space:];&|<>()"'"'"'$`\\*?{}~]*)?("?)[[:space:]]*(;|&&)'
    while :; do
      if [[ "$scope_cd_chain_text" =~ $scope_cd_re ]]; then
        scope_cd_dir="${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
        scope_cd_match="${BASH_REMATCH[0]}"
      elif [[ "$scope_cd_chain_text" =~ $scope_cd_var_lead_re ]]; then
        scope_cd_match="${BASH_REMATCH[0]}"
        scope_cd_var_name="${BASH_REMATCH[2]}"
        scope_cd_var_tail="${BASH_REMATCH[3]}"
        [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[4]}" ] || { scope_cd_chain_ok=0; break; }
        scope_cd_use_prefix="${cmd%%"$scope_cd_match"*}"
        [ "$scope_cd_use_prefix" != "$cmd" ] || { scope_cd_chain_ok=0; break; }
        scope_cd_var_value="$(scope_assignment_literal_value "$scope_cd_var_name" "$scope_cd_use_prefix" "$cmd")" || { scope_cd_chain_ok=0; break; }
        scope_cd_var_value="${scope_cd_var_value##*$'\037'}"
        case "$scope_cd_var_value" in
          ''|-*|*'$'*|*[*?[]*|*'~'*|*'..'*|*[!A-Za-z0-9_./@+-]*) scope_cd_chain_ok=0; break ;;
        esac
        scope_cd_dir="$scope_cd_var_value$scope_cd_var_tail"
      else
        break
      fi
      case "$scope_cd_dir" in -*|'') scope_cd_chain_ok=0; break ;; esac
      case "$scope_cd_dir" in
        /*) scope_cd_abs="$scope_cd_dir" ;;
        *) scope_cd_abs="$scope_cd_chain_cwd/$scope_cd_dir" ;;
      esac
      if [ ! -d "$scope_cd_abs" ]; then
        # `cd /abs/missing && cat ../x`: when the directory does not exist,
        # cd fails and an `&&` chain runs nothing after it. Only a chain the
        # failure stops everywhere qualifies: no `||`, `;`, newline or
        # background `&` after the cd. The rest is then checked from the
        # place the directory would be (its nearest existing ancestor, with
        # no `.` or `..` in the missing part), so a path that climbs into a
        # company from there is still refused (feedback 1295c88f, 919788bb).
        scope_cd_missing_rest="${scope_cd_chain_text#"$scope_cd_match"}"
        scope_cd_missing_amp="${scope_cd_missing_rest//&&/}"
        case "$scope_cd_match" in *'&&') ;; *) scope_cd_chain_ok=0; break ;; esac
        case "$scope_cd_missing_rest" in *'||'*|*';'*|*$'\n'*) scope_cd_chain_ok=0; break ;; esac
        case "$scope_cd_missing_amp" in *'&'*) scope_cd_chain_ok=0; break ;; esac
        scope_cd_missing_up="${scope_cd_abs%/}"
        scope_cd_missing_tail=""
        while [ -n "$scope_cd_missing_up" ] && [ ! -d "$scope_cd_missing_up" ]; do
          [ ! -L "$scope_cd_missing_up" ] || { scope_cd_chain_ok=0; break; }
          scope_cd_missing_tail="/${scope_cd_missing_up##*/}$scope_cd_missing_tail"
          scope_cd_missing_up="${scope_cd_missing_up%/*}"
        done
        [ "$scope_cd_chain_ok" -eq 1 ] || break
        case "$scope_cd_missing_tail/" in */./*|*/../*|//*) scope_cd_chain_ok=0; break ;; esac
        [ -n "$scope_cd_missing_up" ] || scope_cd_missing_up="/"
        scope_cd_phys="$(cd "$scope_cd_missing_up" 2>/dev/null && pwd -P)" || { scope_cd_chain_ok=0; break; }
        scope_cd_phys="${scope_cd_phys%/}$scope_cd_missing_tail"
        scope_check_raw "$scope_cd_phys"
      else
      scope_cd_phys="$(cd "$scope_cd_abs" 2>/dev/null && pwd -P)" || { scope_cd_chain_ok=0; break; }
      fi
      [ -n "$scope_cd_phys" ] || { scope_cd_chain_ok=0; break; }
      if [ "$scope_cd_chain_n" -eq 0 ]; then
        scope_cd_chain_repo_root="$(scope_cd_repo_root "$scope_cd_dir")"
      else
        # Later hops are checked as the directory they reach; a hop through
        # a repos/ link keeps the single-cd rules (chain not applied).
        case "$scope_cd_dir" in repos/*|*/repos/*) scope_cd_chain_ok=0; break ;; esac
        scope_check_raw "$scope_cd_phys"
      fi
      scope_cd_chain_cwd="$scope_cd_phys"
      scope_cd_chain_n=$((scope_cd_chain_n + 1))
      scope_cd_chain_text="${scope_cd_chain_text#"$scope_cd_match"}"
      [ "$scope_cd_chain_n" -le 8 ] || { scope_cd_chain_ok=0; break; }
    done
    if [ "$scope_cd_chain_ok" -eq 1 ] && [ "$scope_cd_chain_n" -gt 0 ] \
      && ! [[ "$scope_cd_chain_text" =~ $scope_cd_again_re ]]; then
      scope_cwd_is_static=1
      COMMAND_CWD="$scope_cd_chain_cwd"
      SCOPE_CD_APPLIED=1
      SCOPE_CD_REPO_ROOT="$scope_cd_chain_repo_root"
    fi
    [ "$SCOPE_CD_APPLIED" -eq 1 ] || scope_check_unfollowed_cd "$cmd"
    # A cd/pushd into the companies/ root itself makes every later relative
    # operand a company folder (`cd companies; cat other/settings/x`, or the
    # slug from a variable, `C=x; cd companies; cat "$C/..."`). Those words
    # carry no companies/ prefix, so the path scan below never sees them.
    # Ported from the #1436 cwd tracking in narrow form: refuse the cd and
    # ask for companies/<slug>/... paths from the HQ root instead.
    scope_cd_target_re='(^|[;&|({[:space:]]|'$'\n'')(cd|pushd)[[:space:]]+([^;&|<>()[:space:]]+)'
    scope_cd_scan="$cmd"
    while [[ "$scope_cd_scan" =~ $scope_cd_target_re ]]; do
      scope_cd_word="${BASH_REMATCH[3]}"
      scope_cd_scan="${scope_cd_scan#*"${BASH_REMATCH[0]}"}"
      # `D=companies; cd "$D"`: follow a literal assignment in the same
      # command so the variable form is mapped like the literal one. Any
      # other computed target that mentions companies is refused.
      scope_cd_var_re='^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(/[^$`\\]*)?$'
      scope_cd_bare="${scope_cd_word//[\"\']/}"
      if ! [[ "$scope_cd_bare" =~ $scope_cd_var_re ]]; then
        case "$scope_cd_word" in
          *'$'*|*$'\140'*|*\\*)
            case "$scope_cd_word" in
              *[Cc][Oo][Mm][Pp][Aa][Nn]*)
                scope_block_rel "$scope_cd_word" "the command changes directory to a computed path under companies/; use literal companies/<slug>/... paths from the HQ root"
                ;;
            esac
            continue
            ;;
        esac
      fi
      scope_cd_word="$scope_cd_bare"
      if [[ "$scope_cd_word" =~ $scope_cd_var_re ]]; then
        scope_cd_var="${BASH_REMATCH[1]}"
        scope_cd_var_tail="${BASH_REMATCH[2]}"
        scope_cd_assign_re='(^|[;&|({[:space:]])'"$scope_cd_var"'=("([^"$`\\]*)"|'"'([^']*)'"'|([^;&|<>()[:space:]"'"'"'$`\\]*))'
        if [[ "$cmd" =~ $scope_cd_assign_re ]]; then
          scope_cd_word="${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}$scope_cd_var_tail"
        fi
      fi
      case "$scope_cd_word" in -*|''|*'$'*) continue ;; esac
      case "$scope_cd_word" in
        /*) scope_cd_try="$scope_cd_word" ;;
        *) scope_cd_try="${PAYLOAD_CWD:-$HQ_ROOT}/$scope_cd_word" ;;
      esac
      scope_cd_phys="$(cd "$scope_cd_try" 2>/dev/null && pwd -P)" || scope_cd_phys=""
      scope_cd_lex="${scope_cd_word%/}"
      scope_cd_lex="${scope_cd_lex#./}"
      if [ "$scope_cd_phys" = "$HQ_ROOT/companies" ] || [ "$scope_cd_lex" = "companies" ] \
        || [ "$scope_cd_lex" = "$HQ_ROOT/companies" ]; then
        scope_block_rel "$scope_cd_word" "the command changes directory into the companies/ root, so later relative paths name company folders the guard cannot attribute; use companies/<slug>/... paths from the HQ root"
      fi
    done
    # Text piped into a stdin shell (`printf ... | bash`) is a program the
    # guard does not parse. Quote splicing (`compa''nies/x`) hides the path
    # from the scan while the shell rejoins it, so any mention of companies
    # in such a pipeline, once quotes and backslashes are removed, is refused.
    scope_stdin_shell_re='\|[[:space:]]*(command[[:space:]]+|exec[[:space:]]+|env[[:space:]]+)?([^[:space:];&|]*/)?(bash|sh|zsh|dash|ksh|mksh)([[:space:]]+-[a-zA-Z]*s[a-zA-Z]*|[[:space:]]+-)?[[:space:]]*($|[;&|)]|'$'\n'')'
    if [[ "$cmd" =~ $scope_stdin_shell_re ]]; then
      scope_stdin_text="${cmd//[\"\'\\]/}"
      case "$scope_stdin_text" in
        *[Cc][Oo][Mm][Pp][Aa][Nn]*)
          scope_block_rel "| ${BASH_REMATCH[3]}" "text piped into a shell names companies; the guard cannot check a program built from text, so run the command directly with literal paths"
          ;;
      esac
    fi
    # A plain path-free command cannot name an HQ tenant path. Skip the shell
    # parser in this common case; commands that can traverse or change roots
    # stay on the full fail-closed scan.
    scope_simple_command_re='^(printf|echo|true|false|pwd)([[:blank:]]+[[:alnum:]_.+-]+)*$'
    if [[ "$cmd" =~ $scope_simple_command_re ]]; then
      exit 0
    fi
    # Reuse the shared non-evaluating shell splitter so recursive checks see
    # every simple command, including commands after separators and pipelines.
    . "$HQ_ROOT/core/scripts/hook-lib.sh"
    # Bash removes an unquoted backslash-newline before tokenizing, so scan the
    # same normalized form when extracting possible path tokens.
    #
    # The pattern MUST be a quoted VARIABLE. Written inline and unquoted, as
    # ${cmd//$'\\\n'/}, bash 3.2 — the stock macOS shell — matches nothing: it
    # reads the leading backslash as a pattern escape rather than a literal, so
    # the strip silently no-ops and a company path split by a line continuation
    # is never reassembled. The scan then sees only the fragment before the
    # break (an unknown company, allowed) and never examines the rest, so the
    # cross-company read this normalization exists to stop goes through. bash 5
    # matches the same expression, which is why CI stayed green and only macOS
    # runs of test [9] failed. Quoting makes it a literal on 3.2 and 5.x alike.
    scope_line_continuation=$'\\\n'
    scope_had_line_continuation=0
    case "$cmd" in *"$scope_line_continuation"*) scope_had_line_continuation=1 ;; esac
    scope_cmd="${cmd//"$scope_line_continuation"/}"
    scope_scan_cmd="$(scope_strip_inert_heredoc_bodies "$scope_cmd")"
    # Unquoted command substitutions in arguments (see scope_subst_scan). It
    # reads the command as typed, before line continuations are joined. Run
    # in a subshell under the C locale; exit 2 is a block, and any other
    # failure is a bug in the check and fails closed.
    case "$cmd" in
      *'$('*|*$'\140'*)
        scope_subst_rc=0
        # Two passes: the first only records variables set from a
        # substitution, so a use that comes earlier in the text than the
        # assignment (a function body, a loop) is still checked.
        ( LC_ALL=C; scope_subst_text="$cmd"
          scope_subst_mark_only=1; scope_subst_scan "$cmd" 0 || exit $?
          scope_subst_mark_only=0; scope_subst_scan "$cmd" 0 ) || scope_subst_rc=$?
        if [ "$scope_subst_rc" -eq 2 ]; then
          exit 2
        elif [ "$scope_subst_rc" -ne 0 ]; then
          scope_block_rel "\$(...)" "the command-substitution check could not finish (exit $scope_subst_rc); spell paths literally"
        fi
        ;;
    esac
    # Variables in inline interpreter programs and directory options (see
    # scope_inline_expansions_check_word). It reads the command as typed,
    # before line continuations are joined (see scope_inline_lex). Run in a
    # subshell under the C locale so the lexer's byte offsets index the text
    # exactly. Exit 2 is a block; any other failure is a bug in the check and
    # fails closed.
    # The gate also reads the joined form: `g\<newline>it -C $R` runs git.
    if scope_inline_expansions_wanted "$cmd" || scope_inline_expansions_wanted "$scope_cmd"; then
      scope_inline_rc=0
      ( LC_ALL=C; scope_inline_text="$cmd"; scope_inline_expansions_scan "$cmd" 0 0 ) || scope_inline_rc=$?
      if [ "$scope_inline_rc" -eq 2 ]; then
        exit 2
      elif [ "$scope_inline_rc" -ne 0 ]; then
        scope_block_rel "\$(...)" "the inline-program variable check could not finish (exit $scope_inline_rc); spell paths literally"
      fi
    fi
    scope_note_repo_link_mutations "$scope_scan_cmd"
    scope_interpreter_heredoc_layout "$scope_scan_cmd"
    scope_remaining="$scope_scan_cmd"
    scope_offset=0
    while [[ "$scope_remaining" == *companies/* ]]; do
      scope_before="${scope_remaining%%companies/*}"
      scope_after="${scope_remaining#*companies/}"
      fragment="companies/"
      while [ -n "$scope_after" ]; do
        scope_char="${scope_after:0:1}"
        case "$scope_char" in
          [[:space:]]|';'|'|'|'&'|'('|')'|'<'|'>') break ;;
        esac
        fragment+="$scope_char"
        scope_after="${scope_after:1}"
      done
      # `companies/@(x)/`, `companies/(a|b)/` (extglob / zsh groups): the
      # scan stops at `(` while the company segment is still open.
      # A plain placeholder such as `companies/(shell-expanded)/` is a bash
      # syntax error and, in zsh, a group naming no tenant; it stays allowed.
      if [ "${scope_after:0:1}" = "(" ] && [[ "${fragment#companies/}" != */* ]]; then
        scope_group="${scope_after#(}"
        scope_group="${scope_group%%)*}"
        scope_group_pre="${fragment#companies/}"
        scope_load_bound_company
        if [ -n "$scope_group_pre" ] || [[ "$scope_group" == *'|'* ]] \
          || [[ "$scope_group" == *[*?[]* ]] \
          || { [ -n "$scope_group" ] && [ -d "$HQ_ROOT/companies/$scope_group" ] && ! scope_company_is_locked "$scope_group"; }; then
          if ! { [ -z "$scope_group_pre" ] && [[ "$scope_group" != *'|'* ]] && [[ "$scope_group" != *[*?[]* ]] && scope_company_is_locked "$scope_group"; }; then
            scope_block_rel "$fragment(${scope_after#(}" "a glob group in the company segment cannot be checked; spell the company name literally"
          fi
        fi
      fi
      # `rm -rf "companies/x"` or `ls companies/a"/../x"`: a quote or
      # backslash glued to the company segment is removed by the shell, so
      # the segment `x"` names company x. Strip quoting from the segment and
      # refuse an existing company outside the locked set; the later checks
      # would read `x"` as a folder that does not exist.
      scope_quoted_seg="${fragment#companies/}"
      scope_quoted_seg="${scope_quoted_seg%%/*}"
      case "$scope_quoted_seg" in
        *[\"\'\\]*)
          scope_quoted_seg="${scope_quoted_seg//[\"\'\\]/}"
          if [ -n "$scope_quoted_seg" ] && [[ "$scope_quoted_seg" != *[!A-Za-z0-9._-]* ]] \
            && [ "$scope_quoted_seg" != . ] && [ "$scope_quoted_seg" != .. ] \
            && [ -d "$HQ_ROOT/companies/$scope_quoted_seg" ] \
            && ! { scope_load_bound_company; scope_company_is_locked "$scope_quoted_seg"; }; then
            scope_block_rel "companies/$scope_quoted_seg" "the company segment is quoted; the shell removes the quotes, so it names another company"
          fi
          ;;
      esac
      # The same holds for a quoted `..` climb (`companies/a"/../x"`): check
      # the path the shell would build once the quotes are removed.
      case "$fragment" in
        *[\"\'\\]*)
          scope_quoted_path="${fragment//[\"\'\\]/}"
          case "$scope_quoted_path" in
            *'$'*|*$'\140'*|*[{}*?[]*) ;;
            */..*) scope_check_raw "$scope_quoted_path" ;;
          esac
          ;;
      esac
      scope_prefix_length=$((scope_offset + ${#scope_before}))
      scope_prefix="${scope_scan_cmd:0:$scope_prefix_length}"
      scope_suffix="${scope_scan_cmd:$((scope_prefix_length + ${#fragment}))}"
      scope_consumed=$((${#scope_before} + ${#fragment}))
      # Inside a quoted-delimiter interpreter heredoc the shell expands
      # nothing, and a quote, comma, or bracket ends the string literal that
      # holds the path (`json.dump({"src": "companies/x/y"}, ...)`). Check the
      # literal path itself rather than failing on `"},` as brace syntax. The
      # company segment is still checked; a bare `companies/` is left whole.
      # The string's opening quote is program text too, so the path is
      # checked as a word of its own: a glob in it (`"companies/x/p/*.md"`)
      # is enumerated against the locked companies instead of failing on the
      # quote as unchecked shell expansion (feedback e2b0f0b4).
      scope_check_prefix="$scope_prefix"
      if [ "${#scope_interp_ranges[@]}" -gt 0 ] && scope_offset_in_interpreter_body "$scope_prefix_length"; then
        scope_body_path="${fragment%%[\"\'\`,\)\]\}]*}"
        scope_body_path="${scope_body_path%%[\{\[]*}"
        case "$scope_body_path" in
          companies/|companies/[!A-Za-z0-9_]*) ;;
          *) fragment="$scope_body_path"; scope_check_prefix="${scope_prefix%[\"\']} " ;;
        esac
      elif scope_fragment_in_inline_program "$scope_prefix" "$fragment"; then
        # The same holds inside a quoted `python -c` / `node -e` program:
        # the shell does no brace expansion inside quotes, so the `{d}` of
        # an f-string (`open(f'companies/x/r-{d}.md','w')`) is program
        # text. Check the literal path up to the string's end or the first
        # brace; the company segment is still checked.
        scope_body_path="$scope_inline_program_path"
        case "$scope_body_path" in
          companies/|companies/[!A-Za-z0-9_]*) ;;
          *) fragment="$scope_body_path" ;;
        esac
      elif [[ "$fragment" == *[\"\'\`,\)\]\}]* ]] \
        && scope_offset_in_cat_quoted_heredoc "$scope_prefix" "$fragment$scope_suffix"; then
        # Literal text of a quoted heredoc that cat prints: the quote or
        # bracket ends the path inside the data (`"companies/x/y"},`).
        # The company segment and any `..` before the cut are still checked.
        scope_body_path="${fragment%%[\"\'\`,\)\]\}]*}"
        case "$scope_body_path" in
          companies/|companies/[!A-Za-z0-9_]*) ;;
          *) fragment="$scope_body_path" ;;
        esac
      fi
      # Markdown-style `companies/x/y` (one backtick on each side, none inside)
      # names the same path whether the backticks are prose in a quoted body
      # or a shell command substitution that runs that path. Check the path
      # without the closing backtick instead of failing on the backtick.
      scope_bt=$'\140'
      if [[ "$fragment" == *"$scope_bt" ]] && [[ "$scope_prefix" == *"$scope_bt" ]]; then
        scope_fragment_core="${fragment%"$scope_bt"}"
        case "$scope_fragment_core" in
          *"$scope_bt"*|*'$'*|companies/) ;;
          *) fragment="$scope_fragment_core" ;;
        esac
      fi
      # `companies/` inside an http(s) URL is part of a remote resource name
      # (`https://github.com/o/r/tree/main/companies/x`), never a local file.
      # Only for a network client; see scope_url_is_remote_operand.
      scope_url_word="${scope_prefix##*[[:space:];|&()<>]}"
      scope_url_rest="${scope_prefix%"$scope_url_word"}"
      scope_url_word="${scope_url_word#[\"\']}"
      scope_url_stmt="${scope_url_rest##*[;|&()$'\n']}"
      read -r scope_url_head _ <<< "$scope_url_stmt"
      scope_url_prev="${scope_url_rest%"${scope_url_rest##*[![:space:]]}"}"
      scope_url_prev="${scope_url_prev##*[[:space:]]}"
      case "$scope_url_word" in *'$'*|*$'\140'*|*'"'*|*"'"*) scope_url_word="" ;; esac
      if [ -n "$scope_url_word" ] && scope_url_is_remote_operand "${scope_url_head##*/}" "$scope_url_prev" "$scope_url_word"; then
        scope_offset=$((scope_offset + scope_consumed))
        scope_remaining="${scope_remaining:$scope_consumed}"
        continue
      fi
      # A bracketed company segment that is not a tenant path. Two shapes:
      #  - the fragment continues a `repos/...` path (a Next.js dynamic route
      #    such as repos/private/app/src/app/companies/[slug]/page.tsx): the
      #    whole word is checked by the repos/ open-tree scan, and the
      #    `companies/` inside it is a source directory, not a tenant.
      #  - the fragment sits inside a quoted pattern operand of grep/rg
      #    (`grep -rn "companies/[a-z]+/" repos/x`): a quoted word is never
      #    glob-expanded, so it is a regex and opens no file.
      # Only a `[` in the company segment qualifies, and `..` anywhere in the
      # word keeps the normal check, so an unquoted bracket glob under
      # companies/ and repos/../companies/ with a bracket stay blocked.
      scope_regex_segment="${fragment#companies/}"
      scope_regex_segment="${scope_regex_segment%%/*}"
      if [[ "$scope_regex_segment" == *'['* ]]; then
        scope_raw_word="${scope_prefix##*[[:space:];|&()<>]}"
        scope_raw_stmt="${scope_prefix%"$scope_raw_word"}"
        scope_raw_stmt="${scope_raw_stmt##*[;|&()$'
']}"
        read -r scope_raw_head _ <<< "$scope_raw_stmt"
        scope_raw_head="${scope_raw_head##*/}"
        scope_raw_last="${scope_raw_stmt%"${scope_raw_stmt##*[![:space:]]}"}"
        scope_raw_last="${scope_raw_last##*[[:space:]]}"
        scope_raw_skip=0
        case "$scope_raw_word" in
          *'..'*|*'$'*|*$'`'*) ;;
          repos/*/|./repos/*/|"$HQ_ROOT"/repos/*/) scope_raw_skip=1 ;;
          '"'|"'")
            # The word must be one quoted string that holds the bracket: the
            # opening quote sits right before companies/, the body runs to
            # the matching quote with the whole bracketed segment inside it,
            # and the closing quote ends the word. `""companies/[o]therco`
            # (empty quotes, bare bracket) and `"companies/"[o]therco` are
            # globs and keep the normal check (#1512 review).
            case "$scope_raw_head" in
              grep|egrep|fgrep|rg|ag|ack)
                case "$scope_raw_last" in
                  -f|--file|--file=*|--exclude-from|--ignore-file) ;;
                  *)
                    if [[ "$scope_scan_cmd" == "$scope_prefix"* ]]; then
                      scope_raw_rest="${scope_scan_cmd:${#scope_prefix}}"
                      scope_raw_body="${scope_raw_rest%%"$scope_raw_word"*}"
                      if [ "$scope_raw_body" != "$scope_raw_rest" ] \
                        && [[ "$scope_raw_body" == "companies/$scope_regex_segment"* ]]; then
                        scope_raw_after="${scope_raw_rest:$(( ${#scope_raw_body} + 1 )):1}"
                        case "$scope_raw_word:$scope_raw_body" in
                          '"':*'$'*|'"':*$'`'*|'"':*\\*) ;;
                          *)
                            case "$scope_raw_after" in
                              ''|' '|$'\t'|$'\n'|';'|'|'|'&'|')') scope_raw_skip=1 ;;
                            esac
                            ;;
                        esac
                      fi
                    fi
                    ;;
                esac
                ;;
            esac
            ;;
        esac
        if [ "$scope_raw_skip" -eq 1 ]; then
          scope_offset=$((scope_offset + scope_consumed))
          scope_remaining="${scope_remaining:$scope_consumed}"
          continue
        fi
      fi
      scope_check_bash_candidate "$fragment" "$scope_scan_cmd" "$scope_check_prefix" "$scope_suffix"
      scope_offset=$((scope_offset + scope_consumed))
      scope_remaining="${scope_remaining:$scope_consumed}"
    done
    scope_remaining="$scope_scan_cmd"
    scope_offset=0
    while [[ "$scope_remaining" == *'.claude'* ]]; do
      scope_before="${scope_remaining%%.claude*}"
      scope_after="${scope_remaining#*.claude}"
      fragment='.claude'
      while [ -n "$scope_after" ]; do
        scope_char="${scope_after:0:1}"
        case "$scope_char" in
          [[:space:]]|';'|'|'|'&'|'('|')'|'<'|'>') break ;;
        esac
        fragment+="$scope_char"
        scope_after="${scope_after:1}"
      done
      scope_candidate_length=${#fragment}
      scope_prefix_length=$((scope_offset + ${#scope_before}))
      scope_prefix="${scope_scan_cmd:0:$scope_prefix_length}"
      scope_suffix="${scope_scan_cmd:$((scope_prefix_length + scope_candidate_length))}"
      case "$fragment" in
        *'"') fragment="${fragment%\"}" ;;
        *"'") fragment="${fragment%\'}" ;;
      esac
      # A markdown code span closes the path with a backtick ("see
      # `.claude/skills/x/SKILL.md` for ..." in a quoted interpreter heredoc,
      # a commit message, or a PR body). The scan starts at `.claude`, so the
      # opening backtick never joins the fragment, but the closing one did and
      # made the literal path unresolvable (thread T-20261022-140549). Drop
      # one trailing backtick and check the path it closes: in a real
      # substitution that same literal path is what the shell runs, and a
      # fragment with any other backtick inside stays unresolvable.
      # Bash 3.2 needs the ANSI-C character in a quoted pattern variable.
      scope_bt=$'\140'
      case "$fragment" in
        *"$scope_bt") fragment="${fragment%"$scope_bt"}" ;;
      esac
      scope_check_bash_skill_path "$fragment" "$scope_scan_cmd" "$scope_prefix" "$scope_suffix"
      scope_consumed=$((${#scope_before} + scope_candidate_length))
      scope_offset=$((scope_offset + scope_consumed))
      scope_remaining="${scope_remaining:$scope_consumed}"
    done
    scope_interp_bodies="$(scope_interpreter_heredoc_bodies "$scope_scan_cmd")"
    # Backslashes go too: the tokenizer drops them, so a body word such as
    # r"\$(\w+)/" reaches the token loop as r$(w+)/ and must still match.
    scope_interp_bodies_unquoted="${scope_interp_bodies//[\"\'\\]/}"
    scope_interp_outside_unquoted="${scope_interp_outside//[\"\'\\]/}"
    # The normalized split (scope_norm_scan) masks `*`, `?`, `[` and `$`
    # inside single quotes, and a python body quotes its strings with the
    # same character (`['companies/x/policies/*.md']`), so a word from that
    # split carries the mask and is not in the body verbatim. Keep a masked
    # copy of the bodies so such a word is still recognised as body text
    # (feedback e2b0f0b4, single-quoted form).
    scope_interp_bodies_masked="$(scope_mask_literal_expansions "$scope_interp_bodies")"
    scope_interp_bodies_masked_unquoted="${scope_interp_bodies_masked//[\"\'\\]/}"
    scope_interp_outside_masked_unquoted="$(scope_mask_literal_expansions "$scope_interp_outside")"
    scope_interp_outside_masked_unquoted="${scope_interp_outside_masked_unquoted//[\"\'\\]/}"
    # The `$` relaxation applies only when every interpreter body in the
    # command is a python/node body with no shell handoff. 2 means the only
    # hand-off names were node requires of file and text modules (fs, path,
    # ...): no shell, but a file write is possible, so an expansion next to
    # a `/` (a template literal such as workspace/${b}.txt) is still checked.
    scope_text_bodies_only=0
    if [ -n "$scope_interp_bodies" ]; then
      if [ "$(scope_text_only_interpreter_bodies "$scope_scan_cmd")" = "$scope_interp_bodies" ]; then
        scope_text_bodies_only=1
      elif [ "$(scope_text_only_interpreter_bodies "$scope_scan_cmd" 1)" = "$scope_interp_bodies" ]; then
        scope_text_bodies_only=2
      fi
    fi
    # Check every word on its bash value after quote removal (see
    # scope_check_normalized_word). Only a command whose text, with quotes and
    # backslashes deleted, still says `companies` can spell a company path
    # this way, so other commands skip the second split. The same holds for
    # the second parse of `eval` and `sh -c` text: with no quote or backslash
    # it sees the same words as the first parse.
    scope_norm_scan=""
    case "$scope_scan_cmd" in
      *[\"\'\\]*)
        if [[ "${scope_scan_cmd//[\"\'\\]/}" == *companies* ]]; then
          scope_norm_scan="$(scope_mask_literal_expansions "$scope_scan_cmd")"
          scope_check_normalized_split "$scope_norm_scan"
          scope_check_reparsed_text 0 "$scope_scan_cmd"
        fi
        ;;
    esac
    scope_segments="$(hq_shell_simple_commands "$scope_scan_cmd")"
    while IFS= read -r scope_record; do
      [ -n "$scope_record" ] || continue
      IFS=$'\037' read -r -a scope_tokens <<< "$scope_record"
      [ "${#scope_tokens[@]}" -gt 0 ] || continue
      scope_head_untrusted=0
      SCOPE_REC_HEAD=""
      scope_head_is_untrusted && scope_head_untrusted=1
      scope_check_tar_program_options
      scope_token_index=-1
      for scope_token in "${scope_tokens[@]}"; do
        scope_token_index=$((scope_token_index + 1))
        if [ "$scope_head_untrusted" -eq 0 ]; then
          case "${SCOPE_REC_HEAD:-}:$scope_token" in
            echo:*[*?[]*|printf:*[*?[]*|echo:*'{'*,*'}'*|printf:*'{'*,*'}'*|echo:*'{'*..*'}'*|printf:*'{'*..*'}'*)
              SCOPE_NAMES_ONLY=1
              scope_check_cwd_token "$scope_token"
              SCOPE_NAMES_ONLY=0
              ;;
          esac
        fi
        case "$scope_token" in
          companies/*|.claude*)
            # companies/, companies//, companies/. name the companies/ folder.
            if [[ "$scope_token" =~ ^companies[/.]*$ ]] && scope_token_is_standalone_word "$scope_token" \
              && ! scope_token_is_search_pattern "$scope_token_index"; then
              scope_check_cwd_token "$scope_token"
              SCOPE_NAMES_ONLY=0
            fi
            continue
            ;;
        esac
        [ "$scope_head_untrusted" -eq 0 ] && scope_token_is_vcs_ref_operand "$scope_token_index" && continue
        [ "$scope_head_untrusted" -eq 0 ] && scope_token_is_gh_api_endpoint "$scope_token_index" && continue
        [ "$scope_head_untrusted" -eq 0 ] && scope_token_is_url_variable_operand "$scope_token_index" && continue
        scope_token_is_bounded_loop_read "$scope_token_index" && continue
        if [ "$scope_head_untrusted" -eq 0 ] && scope_token_is_remote_url_with_substitutions "$scope_token_index"; then
          scope_check_prose_substitutions
          continue
        fi
        if [ "$scope_head_untrusted" -eq 0 ] && scope_token_is_sed_script "$scope_token_index"; then
          scope_check_prose_substitutions
          continue
        fi
        if [ "$scope_head_untrusted" -eq 0 ] && scope_token_is_data_option_substitution "$scope_token_index"; then
          scope_check_prose_substitutions
          continue
        fi
        if [ "$scope_head_untrusted" -eq 0 ] && scope_token_is_curl_write_out_format "$scope_token_index"; then
          scope_check_prose_substitutions
          continue
        fi
        if [ "$scope_head_untrusted" -eq 0 ] && scope_token_is_remote_operand_substitution "$scope_token_index"; then
          scope_check_prose_substitutions
          continue
        fi
        if [ "$scope_head_untrusted" -eq 0 ] && scope_token_is_test_string_operand "$scope_token_index"; then
          scope_check_prose_substitutions
          continue
        fi
        if [ "$scope_head_untrusted" -eq 0 ] && scope_token_is_text_option_value "$scope_token_index"; then
          scope_check_prose_substitutions
          for scope_text_piece in ${scope_text_pieces[@]+"${scope_text_pieces[@]}"}; do
            scope_check_bash_skill_path "$scope_text_piece" "$scope_scan_cmd" "" ""
          done
          continue
        fi
        scope_token_context=shell
        if [ -n "$scope_interp_bodies" ]; then
          if [[ "$scope_interp_bodies" == *"$scope_token"* ]] \
            && [[ "$scope_interp_outside" != *"$scope_token"* ]]; then
            scope_token_context=body
          elif { [[ "$scope_token" == *[[:space:]]* ]] || [[ "$scope_token" == *$'\140'* ]] || [ "$scope_text_bodies_only" -ge 1 ]; } \
            && { [[ "$scope_interp_bodies_unquoted" == *"$scope_token"* ]] \
              || [[ "$scope_interp_bodies_unquoted" == *"${scope_token//[\"\'\\]/}"* ]]; } \
            && [[ "$scope_interp_outside_unquoted" != *"${scope_token//[\"\'\\]/}"* ]]; then
            # Two adjacent string literals (`.replace('<b>$19</b>','x')`)
            # arrive as one glued word that still carries the inner
            # double quotes of each literal; compare it with those quotes
            # removed too (feedback dfd6d198).
            # The tokenizer drops quotes, so adjacent string literals with
            # no space after the comma (`print('a','see `x`')`) reach here as
            # one glued word that is not in the body verbatim. Match it
            # against the body with quotes removed (and against the outside
            # with quotes and backslashes removed, so a shell word cannot be
            # mistaken for body text).
            scope_token_context=body
          fi
        fi
        # A body word with spaces or backticks is source text such as
        # "see `companies/x` and `../y`", not one path. The outer shell
        # expands nothing in it, so check each path-like piece on its own
        # (company and .claude pieces are covered by the scans above). A
        # piece with `$` still goes through the fail-closed variable checks,
        # except in a python/node body that cannot hand text to a shell
        # (scope_text_only_interpreter_bodies), where `$30k/mo` or `${x}/y`
        # is text nothing expands.
        # In such a body `$(` is source text too (a regex such as
        # r"\$(\w+)/" or a template string), so the word is split like any
        # other instead of being read as a shell substitution.
        # Mode 1 (no hand-off at all) splits every word, `$(` included. Mode 2
        # (a node body whose only require is a safe core module, which can
        # still write files) keeps a `$(` word on the substitution checks.
        scope_body_split_token="$scope_token"
        if [ "$scope_token_context" = body ]; then
          case "$scope_text_bodies_only:$scope_token" in
            1:*[[:space:]]*|1:*$'\140'*) ;;
            1:*) scope_body_split_token="$scope_token " ;;
            2:*'$('*|2:*[[:space:]]*|2:*$'\140'*) ;;
            2:*) scope_body_split_token="$scope_token " ;;
          esac
        fi
        if [ "$scope_token_context" = body ]; then
          case "$scope_text_bodies_only:$scope_body_split_token" in
            0:*'$('*) ;;
            *[[:space:]]*|*$'\140'*)
              # In a body that can reach a shell, check every expansion in
              # the whole word before it is split: splitting at braces would
              # turn `${D}/x` into the harmless-looking pieces `$`, `D`, `/x`.
              if [ "$scope_text_bodies_only" -ne 1 ]; then
                scope_body_var_re='\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*|[0-9])'
                [ "$scope_text_bodies_only" -eq 2 ] && scope_body_var_re="/$scope_body_var_re|$scope_body_var_re/"
                while IFS= read -r scope_body_var; do
                  scope_body_var="${scope_body_var#/}"
                  scope_body_var="${scope_body_var%/}"
                  [ -n "$scope_body_var" ] || continue
                  scope_body_resolved="$(scope_resolve_known_path_expansions "$scope_body_var" "$scope_scan_cmd")"
                  case "$scope_body_resolved" in
                    *'$'*) scope_block_rel "$scope_token" "interpreter source that can run a shell command uses a variable the command does not set" ;;
                  esac
                done <<< "$(printf '%s' "$(scope_mask_literal_expansions "$scope_token")" | grep -oE "$scope_body_var_re" 2>/dev/null || true)"
              fi
              scope_body_pieces="${scope_token//[[:space:]\`\"\'(),;\{\}\[\]]/$'\n'}"
              while IFS= read -r scope_body_piece; do
                case "$scope_body_piece" in
                  companies/*|.claude*|*/companies/*|*/.claude*) continue ;;
                  *'$'*)
                    [ "$scope_text_bodies_only" -ge 1 ] && continue
                    # This body can hand the text to a shell (os.system,
                    # subprocess, perl, ...), which expands the variable from
                    # the environment. The interpreter's own quotes do not
                    # stop that, so the shell single-quote rule does not
                    # apply: the value must be proven by the command.
                    scope_body_resolved="$(scope_resolve_known_path_expansions "$scope_body_piece" "$scope_scan_cmd")"
                    case "$(scope_mask_literal_expansions "$scope_body_resolved")" in
                      *'$'*) scope_block_rel "$scope_body_piece" "interpreter source that can run a shell command uses a variable the command does not set" ;;
                    esac
                    scope_body_piece="$scope_body_resolved"
                    ;;
                esac
                case "$scope_body_piece" in
                  */*) scope_check_bash_skill_path "$scope_body_piece" "$scope_scan_cmd" "" "" ;;
                esac
              done <<< "$scope_body_pieces"
              continue
              ;;
          esac
        fi
        if [ "$scope_head_untrusted" -eq 0 ] && scope_token_is_nofile_substitution "$scope_token_index"; then
          scope_check_prose_substitutions
          continue
        fi
        # `$((tot/10))` is a number, never a path: its `/` is division. Check
        # the word with each simple arithmetic expansion read as a number, so
        # `echo "$label: avg $((tot/10))"` is the echo text it is instead of an
        # unresolvable path (feedback: four echo/loop rewrites per handoff).
        scope_mask_simple_arithmetic "$scope_token"
        if [ "$scope_head_untrusted" -eq 0 ] && scope_token_is_prose "$scope_arith_view" "$scope_token_context" "$scope_token_index"; then
          scope_check_prose_substitutions
          continue
        fi
        case "$scope_arith_view" in
          */*|/*) scope_check_bash_skill_path "$scope_arith_view" "$scope_scan_cmd" "" "" ;;
        esac
        # echo/printf words are text the program prints.
        if [ "$scope_head_untrusted" -eq 1 ] || { [ "${SCOPE_REC_HEAD:-}" != echo ] && [ "${SCOPE_REC_HEAD:-}" != printf ]; }; then
          scope_check_cwd_token "$scope_token"
          SCOPE_NAMES_ONLY=0
        else
          # echo/printf print text, but a glob or brace word prints the names
          # it matches, which must not come from another company.
          case "$scope_token" in
            *[*?[]*|*'{'*,*'}'*|*'{'*..*'}'*)
              SCOPE_NAMES_ONLY=1
              scope_check_cwd_token "$scope_token"
              SCOPE_NAMES_ONLY=0
              ;;
          esac
        fi
      done
      scope_strip_command_wrappers
      [ "${#scope_tokens[@]}" -gt 0 ] || continue
      if scope_command_follows_nested_links; then
        scope_recursive_roots=0
        for scope_token in "${scope_tokens[@]:1}"; do
          case "$scope_token" in -*|''|*://*) continue ;; esac
          scope_root_candidate="$(scope_resolve_payload_path "$scope_token")"
          [ "$scope_root_candidate" != "__OUTSIDE_HQ__" ] || continue
          scope_root_abs="$HQ_ROOT/$scope_root_candidate"
          if [ -d "$scope_root_abs" ]; then
            scope_check_recursive_search_root "$scope_token"
            scope_recursive_roots=$((scope_recursive_roots + 1))
          fi
        done
        if [ "$scope_recursive_roots" -eq 0 ]; then
          scope_check_recursive_search_root "$PAYLOAD_CWD"
        fi
      fi
    done <<< "$scope_segments"
    ;;
esac

exit 0
