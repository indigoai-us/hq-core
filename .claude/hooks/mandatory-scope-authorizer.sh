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
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$dest" ] && [[ "$line" =~ $consumer_re ]]; then
      for q in "" "'" '"'; do
        for form in "--body-file $q$dest$q" "--body-file=$q$dest$q" "-F $q$dest$q" "--file $q$dest$q" "--file=$q$dest$q"; do
          line="${line//" $form"/ }"
        done
      done
    fi
    out+="$line"$'\n'
  done <<< "$text"
  printf '%s' "$out"
}

scope_strip_inert_heredoc_bodies() {
  local raw="${1:-}" output="" line delimiter="" strip_tabs=0 in_body=0 delimiter_quoted=0
  local original="$raw" tail="" unsafe_re body_sub_prefix data_writer=0
  local writer_dests="" dest dest_rest exec_re
  case "$raw" in *'<<'*) ;; *) printf '%s' "$raw"; return 0 ;; esac

  body_sub_prefix='$'
  body_sub_prefix+='(cat <<'
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_body" -eq 1 ]; then
      local terminator="$line"
      if [ "$strip_tabs" -eq 1 ]; then
        while [[ "$terminator" == $'\t'* ]]; do terminator="${terminator#$'\t'}"; done
      fi
      if [ "$terminator" = "$delimiter" ]; then
        in_body=0
        delimiter=""
        strip_tabs=0
        data_writer=0
      elif [ "$data_writer" -eq 1 ] && [ "$delimiter_quoted" -eq 0 ]; then
        output+="$(scope_heredoc_executions "$line")"$'\n'
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
  printf '%s' "$output"
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

scope_shell_variable_values() {
  local name="${1:-}" prefix="${2:-}" command_text="${3:-}" loop_re assignment_re command_prefix_re
  local raw value command_prefix function_name function_re function_keyword_re statement call_text position call_count call_occurrences loop_match loop_pre
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
    position="$name"
    call_count=0
    IFS=';' read -r -a statements <<< "$command_text"
    for statement in "${statements[@]}"; do
      while [[ "$statement" == [[:space:]]* || "$statement" == '}'* ]]; do
        statement="${statement#?}"
      done
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
    printf '%s\n' "${values[@]}"
    return 0
  fi

  command_prefix_re='^[A-Za-z0-9_./:+@=-]+([[:space:]]+[A-Za-z0-9_./:+@=-]+)*[[:space:]]*$'
  loop_re="(^|[;&"$'\n'"][[:space:]]*)for[[:space:]]+${name}[[:space:]]+in[[:space:]]+([^;|&]+);[[:space:]]*do[[:space:]]+(.*)$"
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
      loop_bind_re="(^|[^A-Za-z0-9_\$])${name}\+?="
      [[ "$command_text" =~ $loop_bind_re ]] && return 1
      loop_bind_re='(^|[^A-Za-z0-9_.-])(read|mapfile|readarray|getopts|eval|source|declare|typeset|local|unset|let|export)([[:space:]]|$)'
      [[ "$command_text" =~ $loop_bind_re ]] && return 1
      loop_bind_re='printf[[:space:]]+-v|\$\{'"$name"':?='
      [[ "$command_text" =~ $loop_bind_re ]] && return 1
      loop_bind_re='(^|[;&|({]|'$'\n'')[[:space:]]*\.[[:space:]]'
      [[ "$command_text" =~ $loop_bind_re ]] && return 1
    fi
    [[ "$command_prefix" =~ (^|[[:space:]])${name}= ]] && return 1
    case "$command_prefix" in
      *"-v $name"*|*"read $name"*|*"declare $name"*|*"local $name"*|*"unset $name"*|*"eval"*|*"source "*|*". "*) return 1 ;;
    esac
    IFS=$' \t\n' read -r -a values <<< "$raw"
    [ "${#values[@]}" -gt 0 ] || return 1
    local glob_match glob_count=0 glob_cwd
    for value in "${values[@]}"; do
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
      case "$value" in
        ""|*[!A-Za-z0-9._/-]*) return 1 ;;
      esac
      printf '%s\n' "$value"
    done
    return 0
  fi

  assignment_re="^[[:space:]]*${name}=([^[:space:];|&]+);[[:space:]]*(.*)$"
  [[ "$prefix" =~ $assignment_re ]] || return 1
  raw="${BASH_REMATCH[1]}"
  command_prefix="${BASH_REMATCH[2]}"
  [[ "$command_prefix" =~ $command_prefix_re ]] || return 1
  [[ "$command_prefix" =~ (^|[[:space:]])${name}= ]] && return 1
  case "$raw" in
    \"*) raw="${raw#\"}"; raw="${raw%\"}" ;;
    \'*) raw="${raw#\'}"; raw="${raw%\'}" ;;
  esac
  case "$raw" in
    ""|*[!A-Za-z0-9_./@+-]*) return 1 ;;
  esac
  printf '%s\n' "$raw"
}

scope_candidate_is_inert_text() {
  local candidate="${1:-}" command_text="${2:-}" prefix="${3:-}" suffix="${4:-}"
  local segment="" masked_segment="" output_re redirection_re data_option_re backtick text_option_re command_head pr_wrapper_re
  [ -n "$candidate" ] || return 1
  backtick=$'\140'
  # Only a standalone echo/printf is inert. A pipe, redirect, command
  # separator, or substitution can feed or execute the printed path.
  case "$command_text" in *';'*|*'|'*|*'&'*|*'<'*|*'>'*|*'$('*|*"$backtick"*|*$'\n'*) return 1 ;; esac
  # Quoted message values are data only for commands whose option contract
  # identifies them as text. Keep arbitrary programs and file options checked.
  data_option_re="(^|[[:space:]])(--text|--title|--body)(=|[[:space:]])(\"[^\"]*$|'[^']*$)"
  command_head="${command_text#"${command_text%%[![:space:]]*}"}"
  case "$command_head" in
    'hq dm '*) text_option_re="$data_option_re" ;;
    'hq lanes message '*) text_option_re="$data_option_re" ;;
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
    text_option_re="(^|[[:space:]])(--title|--body)(=|[[:space:]])(\"[^\"]*$|'[^']*$)"
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

scope_check_bash_candidate_inner() {
  local candidate="${1:-}" command_text="${2:-}" depth="${3:-0}" expected_company="${4:-}"
  local occurrence_prefix="${5:-}" occurrence_suffix="${6:-}"
  local masked token name prefix values value braced unbraced expanded backtick first_segment resolved
  local -a pending=()
  [ -n "$candidate" ] || return 0
  [ "$depth" -lt 8 ] || scope_block_rel "$candidate"
  scope_candidate_is_inert_text "$candidate" "$command_text" "$occurrence_prefix" "$occurrence_suffix" && return 0
  scope_candidate_is_single_quoted "$candidate" "$occurrence_prefix" && { scope_check_raw "$candidate"; return 0; }

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
  case "$masked" in
    *'$('*|*"$backtick"*) scope_block_rel "$candidate" ;;
  esac
  token="$(printf '%s' "$masked" | grep -oE '\$\{?([A-Za-z_][A-Za-z0-9_]*|[1-9])\}?' 2>/dev/null | head -n 1 || true)"
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
      *) scope_block_rel "$candidate" "expanded path resolves outside companies/$expected_company" ;;
    esac
    scope_check_rel "$resolved"
  else
    scope_check_raw "$candidate"
  fi
}

scope_check_bash_candidate() {
  scope_check_bash_candidate_inner "${1:-}" "${2:-}" 0 "" "${3:-}" "${4:-}"
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
  case "$normalized_prefix" in
    "companies/$glob_company"/*) ;;
    *) scope_block_rel "$candidate" "the literal prefix before the glob does not resolve inside its company" ;;
  esac

  company_root="$(realpath "$HQ_ROOT/companies/$glob_company" 2>/dev/null)" \
    || scope_block_rel "$candidate" "the bound company directory cannot be resolved"
  case "$company_root" in
    "$HQ_ROOT/companies/$glob_company"|"$HQ_ROOT/companies/$glob_company"/*) ;;
    *) scope_block_rel "$candidate" "the bound company directory resolves outside its literal company path" ;;
  esac

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
scope_resolve_absolute_path() {
  local input="${1:-}" resolved="/" pending segment candidate target hops=0
  [ -n "$input" ] || return 1
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
  printf '%s' "$resolved"
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
[ -f "$HQ_ROOT/core/scripts/lib/session-authz.sh" ] || exit 0

LIB_DIR="$HQ_ROOT/core/scripts/lib"
# shellcheck source=../../core/scripts/lib/session-authz.sh
. "$LIB_DIR/session-authz.sh"
# shellcheck source=../../core/scripts/lib/session-scope-capability.sh
. "$LIB_DIR/session-scope-capability.sh"
# shellcheck source=../../core/scripts/lib/session-id.sh
. "$LIB_DIR/session-id.sh"

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
  if [ -z "$co" ] && [ "$CALLER_KIND" = "main" ]; then
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
  local rel="${1:-}" backtick=$'\140'
  case "$rel" in
    *'$('*|*"$backtick"*)
      printf '%s\n' "How to rewrite: a command substitution's output cannot be checked. Run the inner command first, then use the literal path it printed." >&2
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
  rel="$(scope_normalize_hq_relative "$raw")"
  rel="$(scope_resolve_rel_symlinks "$rel")"
  scope_check_rel "$rel"
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
# Only the bare forms `mktemp`, `mktemp -d`, and `-t NAME` qualify, the variable
# must be assigned exactly once, and a command that mentions TMPDIR is refused.
scope_mktemp_assignment_value() {
  local name="${1:-}" command_text="${2:-}" mktemp_re count tmp_root
  [ -n "$name" ] || return 1
  case "$command_text" in *TMPDIR*) return 1 ;; esac
  mktemp_re='(^|[;&|[:space:]])'
  mktemp_re+="$name="
  mktemp_re+='"?\$\(mktemp( -d)?( -t [A-Za-z0-9._-]+)?( -d)?\)"?([;&|[:space:]]|$)'
  [[ "$command_text" =~ $mktemp_re ]] || return 1
  count="$(printf '%s' "$command_text" | grep -oE "(^|[^A-Za-z0-9_])${name}=" | wc -l | tr -d '[:space:]')"
  [ "$count" = "1" ] || return 1
  tmp_root="${TMPDIR:-/tmp}"
  tmp_root="${tmp_root%/}"
  case "$tmp_root" in /*) ;; *) return 1 ;; esac
  case "$tmp_root" in *'..'*|*'$'*|*[[:space:]]*|*'*'*|*'?'*|*'['*) return 1 ;; esac
  printf '%s/hq-scope-mktemp' "$tmp_root"
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
  local tokens
  tokens="$(printf '%s' "$candidate" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' 2>/dev/null || true)"
  for token in $tokens; do
    name="$(printf '%s' "$token" | sed 's/^\$//;s/^{//;s/}$//')"
    value=""
    if [ "$name" = "HQ_ROOT" ] && [ -n "$HQ_ROOT" ]; then
      value="$HQ_ROOT"
    elif [ "$name" = "HOME" ] && [[ "${HOME:-}" == /* ]] \
      && ! [[ "$command_text" =~ (^|[^A-Za-z0-9_])(HOME=|export[[:space:]]+HOME|read[[:space:]]+([^;|&]*[[:space:]])?HOME([[:space:]]|$)|declare|typeset|local[[:space:]]|eval|source|cd[[:space:]]+-|\.[[:space:]]) ]]; then
      # $HOME is the caller's real home unless the same command reassigns it.
      # Substituting it lets `ffmpeg -i $HOME/Desktop/x.mov` be checked like
      # the literal path it is; `$HOME/../../hq/companies/otherco` still
      # resolves under companies/ and is authorized there.
      value="$HOME"
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
        *[[:space:]]*|*'*'*|*'?'*|*'['*|*']'*) value="" ;;
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
  printf '%s' "$candidate"
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
  count="$(printf '%s' "$command_text" | grep -oE "(^|[^A-Za-z0-9_\$])${name}\+?=" 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ "$count" = "1" ] || return 1
  re='(^|[^A-Za-z0-9_.-])(read|mapfile|readarray|getopts|eval|source|declare|typeset|local|unset|let)([[:space:]]|$)'
  [[ "$command_text" =~ $re ]] && return 1
  re='printf[[:space:]]+-v'
  [[ "$command_text" =~ $re ]] && return 1
  re='(^|[;&|({[:space:]])(for|select)[[:space:]]+'"$name"'([[:space:]]|;|$)'
  [[ "$command_text" =~ $re ]] && return 1
  re='\$\{'"$name"':?='
  [[ "$command_text" =~ $re ]] && return 1
  # `. file` at a command position sources code that can set anything.
  re='(^|[;&|({]|'"$nl"')[[:space:]]*\.[[:space:]]'
  [[ "$command_text" =~ $re ]] && return 1

  assign_re="(^|[;&|[:space:](\{${backtick}])(export[[:space:]]+)?${name}="
  assign_re+='(\$\([^()]*\)|"[^"]*"|'"'[^']*'"'|[^][;&|[:space:]<>()"'"'"'\\*?{}~`]*)'
  [[ "$use_prefix" =~ $assign_re ]] || return 1
  raw="${BASH_REMATCH[3]}"
  head_cut="${BASH_REMATCH[1]}${BASH_REMATCH[2]}$name=$raw"
  before="${use_prefix%%"$head_cut"*}${BASH_REMATCH[1]}"
  after="${use_prefix#*"$head_cut"}"
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
    '$('*)
      value="$(scope_date_substitution_value "$raw")" || return 1
      ;;
    \"*\") value="${raw:1:${#raw}-2}"
      case "$value" in *"$backtick"*|*'$('*|*\\*) return 1 ;; esac
      ;;
    \'*\') value="${raw:1:${#raw}-2}"
      case "$value" in *'$'*) return 1 ;; esac
      ;;
    *) value="$raw" ;;
  esac
  [ -n "$value" ] || return 1
  case "$value" in
    *[[:space:]]*|*'*'*|*'?'*|*'['*|*']'*|*"$backtick"*|*\\*|*"$us"*) return 1 ;;
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
  local value expanded root parent physical_tree physical_parent
  root="${candidate%%/*}"
  physical_tree="$(scope_resolve_absolute_path "$HQ_ROOT/$root" 2>/dev/null || true)"
  [ -n "$physical_tree" ] || return 1
  while IFS= read -r value; do
    [ -n "$value" ] || return 1
    expanded="${candidate//"$token"/$value}"
    case "$expanded" in "$root"/*) ;; *) return 1 ;; esac
    parent="${expanded%/}"
    parent="${parent%/*}"
    [ -d "$HQ_ROOT/$parent" ] || return 1
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
  local index="${1:-0}" token head reduced sub_re mark=$'\001'
  scope_prose_subs=()
  [ "$index" -gt 0 ] || return 1
  token="${scope_tokens[$index]:-}"
  case "$token" in http://*'$('*|https://*'$('*) ;; *) return 1 ;; esac
  case "$token" in *$'\140'*|*"$mark"*) return 1 ;; esac
  [[ "${scope_scan_cmd:-}" == *\\* ]] && return 1
  head="${scope_tokens[0]##*/}"
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

scope_token_is_vcs_ref_operand() {
  local index="${1:-0}" token head i sub="" ref_re range_re refspec_re
  token="${scope_tokens[$index]:-}"
  case "$token" in *'$'*) ;; *) return 1 ;; esac
  case "$token" in *'$('*|*$'\140'*|*[[:space:]]*) return 1 ;; esac
  head="${scope_tokens[0]##*/}"
  [ "$index" -gt 0 ] || return 1
  if [ "$head" = gh ]; then
    # gh sends the -R/--repo value to the GitHub API; it never opens it.
    case "${scope_tokens[$((index - 1))]}" in -R|--repo) return 0 ;; esac
    case "$token" in --repo=*) return 0 ;; esac
  fi
  # An http(s) URL handed to a network client names a remote resource. Any
  # other program opens `https://x/...` as the local path `https:/x/...`
  # (a planted `https:` symlink makes that a tenant path), so only the
  # clients below are exempt. Checked before the glob test: a query string
  # such as `?r=$RANDOM` is not a glob.
  scope_url_is_remote_operand "$head" "${scope_tokens[$((index - 1))]}" "$token" && return 0
  case "$token" in *'*'*|*'?'*|*'['*) return 1 ;; esac
  [ "$head" = git ] || return 1
  # Find the git subcommand past global options; give up on anything unusual.
  i=1
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
  ref_re='(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|[A-Za-z0-9_@][A-Za-z0-9_@/^~-]*)+'
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
scope_token_is_prose() {
  local token="${1:-}" context="${2:-shell}" index="${3:-0}"
  local reduced lead sub_re body cwd head prev backtick=$'\140' mark=$'\001'
  scope_prose_subs=()
  case "$token" in /*|~*|*'..'*|*"$mark"*) return 1 ;; esac
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
  case "$reduced" in *[[:space:]]*) ;; *) return 1 ;; esac
  # The tokenizer has already removed escapes, so a body's `a\ b` would be
  # re-split differently from how the shell runs it. With any backslash in
  # the command, a substitution in prose gets no exemption.
  if [ "${#scope_prose_subs[@]}" -gt 0 ] && [[ "${scope_scan_cmd:-}" == *\\* ]]; then
    return 1
  fi
  case "$reduced" in *'$('*|*"$backtick"*|*'('*'('*) return 1 ;; esac
  # The leading word must be literal text ended by whitespace, before any
  # slash, variable, or substituted value can join the first path component.
  lead="${reduced%%[[:space:]]*}"
  [ -n "$lead" ] || return 1
  case "$lead" in *'/'*|*'$'*|*"$mark"*|*'*'*|*'?'*|*'['*|*'{'*|*'~'*) return 1 ;; esac
  if [ "$context" != body ]; then
    case "$reduced" in
      *'$'*|*"$mark"*)
        head="${scope_tokens[0]:-}"
        head="${head##*/}"
        case "$head" in echo|printf) ;; *) return 1 ;; esac
        [ "$index" -gt 0 ] || return 1
        prev="${scope_tokens[$((index - 1))]:-}"
        [[ "$prev" =~ ^[0-9]*(\<|\>|\>\>|\<\<\<|\>\|)$|^\&\>\>?$ ]] && return 1
        ;;
    esac
  fi
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

scope_check_prose_substitutions() {
  local body record tok
  local -a sub_tokens=()
  local stripped cd_re='(^|[;&|[:space:]])(cd|pushd|CDPATH=)'
  for body in ${scope_prose_subs[@]+"${scope_prose_subs[@]}"}; do
    # The prose exemption only covers the outer text. A substitution body is
    # a command, and it gets no more latitude than the top-level scan: any
    # quoting, escaping, brace, glob, expansion, or directory change that
    # could assemble or reach a tenant path fails closed here.
    case "$body" in
      *"'"*|*'"'*|*\\*|*'{'*|*'}'*|*'*'*|*'?'*|*'['*|*'$'*|*$'\140'*)
        scope_block_rel "\$($body)" "a command substitution inside text uses quoting, globbing, or expansion; run it as its own command with literal paths"
        ;;
    esac
    [[ "$body" =~ $cd_re ]] && scope_block_rel "\$($body)" "a command substitution inside text changes directory; run it as its own command with literal paths"
    stripped="${body//companies\//}"
    case "$stripped" in *[Cc][Oo][Mm][Pp][Aa][Nn]*)
      scope_block_rel "\$($body)" "a command substitution inside text names companies in a form the guard cannot resolve"
      ;;
    esac
    while IFS= read -r record; do
      [ -n "$record" ] || continue
      IFS=$'\037' read -r -a sub_tokens <<< "$record"
      for tok in "${sub_tokens[@]}"; do
        case "$tok" in
          companies/*) scope_check_bash_candidate "$tok" "$body" "" "" ;;
          */*|/*|.claude*) scope_check_bash_skill_path "$tok" "$body" "" "" ;;
        esac
      done
    done <<< "$(hq_shell_simple_commands "$body")"
  done
}

scope_check_bash_skill_path() {
  local raw="${1:-}" command_text="${2:-}" prefix="${3:-}" suffix="${4:-}"
  local masked raw_masked backtick token rel resolved expansion_cwd expanded expanded_raw
  [ -n "$raw" ] || return 0
  # Shell assignment words can themselves carry paths. Check those values,
  # while leaving basename-style parameter transforms such as ${id##*/} alone.
  if [[ "$raw" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    expanded="${raw#*=}"
    case "$expanded" in
      \"*\") expanded="${expanded:1:${#expanded}-2}" ;;
      \'*\') expanded="${expanded:1:${#expanded}-2}" ;;
    esac
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
  scope_candidate_is_inert_text "$raw" "$command_text" "$prefix" "$suffix" && return 0
  case "$raw" in */*|/*) ;; *) return 0 ;; esac
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
  case "$raw" in
    '$(pwd)/'*|'$(pwd -P)/'*|'$PWD/'*)
      expansion_cwd="$(cd "$COMMAND_CWD" 2>/dev/null && pwd -P)" \
        || scope_block_rel "$raw" "the command working directory cannot be resolved"
      case "$raw" in
        '$(pwd)/'*) expanded="$expansion_cwd/${raw#\$(pwd)/}" ;;
        '$(pwd -P)/'*) expanded="$expansion_cwd/${raw#\$(pwd -P)/}" ;;
        '$PWD/'*) expanded="$expansion_cwd/${raw#\$PWD/}" ;;
      esac
      scope_check_bash_candidate_inner "$expanded" "$command_text" 0 "" "$prefix" "$suffix"
      return 0
      ;;
  esac
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
          if scope_open_tree_expansion_is_provably_confined "$expanded_raw" "$prefix"; then
            return 0
          fi
          # A `for` loop or assignment can bound the variable to literal
          # values. Substitute each one and check the resulting literal paths;
          # an unresolved variable still fails closed below.
          if scope_open_tree_expansion_values_resolve "$expanded_raw" "$prefix" "$command_text"; then
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
    *'*'*|*'?'*|*'['*) return 0 ;;
  esac
  resolved="$(scope_resolve_rel_symlinks "$rel")"
  scope_check_rel "$resolved"
}

case "$TOOL" in
  Read|Write|Edit|MultiEdit)
    scope_check_raw "$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')"
    ;;
  NotebookEdit)
    scope_check_raw "$(printf '%s' "$INPUT" | jq -r '.tool_input.notebook_path // empty')"
    ;;
  Grep|Glob)
    scope_search_root="$(printf '%s' "$INPUT" | jq -r '.tool_input.path // empty')"
    scope_search_root_is_implicit=0
    if [ -z "$scope_search_root" ]; then
      scope_search_root="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
      scope_search_root_is_implicit=1
    fi
    scope_search_root_rel="$(scope_resolve_payload_path "$scope_search_root")"
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
    # `cd /abs/hq; grep x companies/co/policies/*.md`: a leading cd to a
    # literal, existing directory is where the rest of the command runs, so
    # globs and $(pwd) are expanded from there instead of the payload cwd.
    # Only when nothing later changes directory again; otherwise the payload
    # cwd stays and the checks below are unchanged.
    scope_cd_re='^[[:space:]]*cd[[:space:]]+("([^"$`\\]+)"|'"'([^']+)'"'|([^][[:space:];&|<>()"'"'"'$`\\*?{}~]+))[[:space:]]*(;|&&)'
    if [[ "$cmd" =~ $scope_cd_re ]]; then
      scope_cd_dir="${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
      scope_cd_rest="${cmd#"${BASH_REMATCH[0]}"}"
      scope_cd_again_re='(^|[;&|({[:space:]]|'$'\n'')(cd|pushd|popd)([[:space:]]|;|$)'
      if ! [[ "$scope_cd_rest" =~ $scope_cd_again_re ]] && [[ "$scope_cd_dir" != -* ]]; then
        case "$scope_cd_dir" in
          /*) scope_cd_abs="$scope_cd_dir" ;;
          *) scope_cd_abs="$COMMAND_CWD/$scope_cd_dir" ;;
        esac
        if [ -d "$scope_cd_abs" ]; then
          COMMAND_CWD="$(cd "$scope_cd_abs" 2>/dev/null && pwd -P)" || COMMAND_CWD="$PAYLOAD_CWD"
          [ -n "$COMMAND_CWD" ] || COMMAND_CWD="$PAYLOAD_CWD"
        fi
      fi
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
      scope_prefix_length=$((scope_offset + ${#scope_before}))
      scope_prefix="${scope_scan_cmd:0:$scope_prefix_length}"
      scope_suffix="${scope_scan_cmd:$((scope_prefix_length + ${#fragment}))}"
      scope_consumed=$((${#scope_before} + ${#fragment}))
      # Inside a quoted-delimiter interpreter heredoc the shell expands
      # nothing, and a quote, comma, or bracket ends the string literal that
      # holds the path (`json.dump({"src": "companies/x/y"}, ...)`). Check the
      # literal path itself rather than failing on `"},` as brace syntax. The
      # company segment is still checked; a bare `companies/` is left whole.
      if [ "${#scope_interp_ranges[@]}" -gt 0 ] && scope_offset_in_interpreter_body "$scope_prefix_length"; then
        scope_body_path="${fragment%%[\"\'\`,\)\]\}]*}"
        scope_body_path="${scope_body_path%%[\{\[]*}"
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
      scope_check_bash_candidate "$fragment" "$scope_scan_cmd" "$scope_prefix" "$scope_suffix"
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
      scope_check_bash_skill_path "$fragment" "$scope_scan_cmd" "$scope_prefix" "$scope_suffix"
      scope_consumed=$((${#scope_before} + scope_candidate_length))
      scope_offset=$((scope_offset + scope_consumed))
      scope_remaining="${scope_remaining:$scope_consumed}"
    done
    scope_interp_bodies="$(scope_interpreter_heredoc_bodies "$scope_scan_cmd")"
    scope_segments="$(hq_shell_simple_commands "$scope_scan_cmd")"
    while IFS= read -r scope_record; do
      [ -n "$scope_record" ] || continue
      IFS=$'\037' read -r -a scope_tokens <<< "$scope_record"
      [ "${#scope_tokens[@]}" -gt 0 ] || continue
      scope_token_index=-1
      for scope_token in "${scope_tokens[@]}"; do
        scope_token_index=$((scope_token_index + 1))
        case "$scope_token" in companies/*|.claude*) continue ;; esac
        scope_token_is_vcs_ref_operand "$scope_token_index" && continue
        if scope_token_is_remote_url_with_substitutions "$scope_token_index"; then
          scope_check_prose_substitutions
          continue
        fi
        scope_token_context=shell
        if [ -n "$scope_interp_bodies" ] && [[ "$scope_interp_bodies" == *"$scope_token"* ]] \
          && [[ "$scope_interp_outside" != *"$scope_token"* ]]; then
          scope_token_context=body
        fi
        # A body word with spaces or backticks is source text such as
        # "see `companies/x` and `../y`", not one path. The outer shell
        # expands nothing in it, so check each path-like piece on its own
        # (company and .claude pieces are covered by the scans above). A
        # piece with `$` still goes through the fail-closed variable checks.
        if [ "$scope_token_context" = body ]; then
          case "$scope_token" in
            *'$('*) ;;
            *[[:space:]]*|*$'\140'*)
              scope_body_pieces="${scope_token//[[:space:]\`\"\'(),;\{\}\[\]]/$'\n'}"
              while IFS= read -r scope_body_piece; do
                case "$scope_body_piece" in
                  companies/*|.claude*|*/companies/*|*/.claude*) continue ;;
                  */*) scope_check_bash_skill_path "$scope_body_piece" "$scope_scan_cmd" "" "" ;;
                esac
              done <<< "$scope_body_pieces"
              continue
              ;;
          esac
        fi
        if scope_token_is_prose "$scope_token" "$scope_token_context" "$scope_token_index"; then
          scope_check_prose_substitutions
          continue
        fi
        case "$scope_token" in
          */*|/*) scope_check_bash_skill_path "$scope_token" "$scope_scan_cmd" "" "" ;;
        esac
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
