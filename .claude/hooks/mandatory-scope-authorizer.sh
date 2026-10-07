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

scope_strip_inert_heredoc_bodies() {
  local raw="${1:-}" output="" line delimiter="" strip_tabs=0 in_body=0 delimiter_quoted=0
  local original="$raw" tail="" unsafe_re body_sub_prefix data_writer=0
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
    else
      if scope_heredoc_output_writer "$line"; then
        tail="${line#*<<}"
        data_writer=1
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
  else
    printf '%s' "$output"
  fi
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
  loop_re="(^|;[[:space:]]*)for[[:space:]]+${name}[[:space:]]+in[[:space:]]+([^;|&]+);[[:space:]]*do[[:space:]]+(.*)$"
  if [[ "$prefix" =~ $loop_re ]]; then
    loop_match="${BASH_REMATCH[0]}"
    loop_pre="${prefix%%"$loop_match"*}"
    scope_shell_prefix_is_unquoted "$loop_pre" || return 1
    raw="${BASH_REMATCH[2]}"
    command_prefix="${BASH_REMATCH[3]}"
    if ! [[ "$command_prefix" =~ $command_prefix_re ]]; then
      [[ "$command_prefix" =~ ^[[:space:]]*(printf|echo)[[:space:]] ]] || return 1
    fi
    [[ "$command_prefix" =~ (^|[[:space:]])${name}= ]] && return 1
    case "$command_prefix" in
      *"-v $name"*|*"read $name"*|*"declare $name"*|*"local $name"*|*"unset $name"*|*"eval"*|*"source "*|*". "*) return 1 ;;
    esac
    IFS=$' \t\n' read -r -a values <<< "$raw"
    [ "${#values[@]}" -gt 0 ] || return 1
    for value in "${values[@]}"; do
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
  local segment="" masked_segment="" output_re redirection_re data_option_re backtick text_option_re command_head
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
  if [ -z "$expected_company" ]; then
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
    *'{'*|*'}'*) scope_block_rel "$candidate" "brace expansion cannot be checked safely" ;;
  esac
  case "$masked" in
    *'$'*|*"$backtick"*) scope_block_rel "$candidate" ;;
  esac
  first_segment="${masked#companies/}"
  first_segment="${first_segment%%/*}"
  case "$first_segment" in
    *'*'*|*'?'*|*'['*) scope_block_rel "$candidate" "glob in the company segment is not allowed" ;;
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
      *) scope_block_rel "$candidate" ;;
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
  local normalized_prefix company_root expansion_cwd match resolved_match rel
  local count=0 prefix_remaining backtick=$'\140'

  scope_load_bound_company
  [ -n "$BOUND_CO" ] || scope_block_rel "$candidate" "no bound company authorizes glob expansion"
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
  case "$normalized_prefix" in
    "companies/$BOUND_CO"/*) ;;
    *) scope_block_rel "$candidate" "the literal prefix before the glob does not resolve inside companies/$BOUND_CO" ;;
  esac

  company_root="$(realpath "$HQ_ROOT/companies/$BOUND_CO" 2>/dev/null)" \
    || scope_block_rel "$candidate" "the bound company directory cannot be resolved"
  case "$company_root" in
    "$HQ_ROOT/companies/$BOUND_CO"|"$HQ_ROOT/companies/$BOUND_CO"/*) ;;
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
      *) scope_block_rel "$candidate" "a glob match resolves outside companies/$BOUND_CO" ;;
    esac
    rel="${resolved_match#"$HQ_ROOT"/}"
    scope_check_rel "$rel"
  done < <(
    cd "$expansion_cwd" 2>/dev/null || exit 1
    shopt -s nullglob dotglob nocaseglob
    shopt -s globstar 2>/dev/null || :
    compgen -G "$full_pattern"
  )
  [ "$count" -gt 0 ] || scope_block_rel "$candidate" "the shell glob produced no checkable matches"
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

BOUND_CO=""
BOUND_CO_LOADED=0
scope_load_bound_company() {
  [ "$BOUND_CO_LOADED" -eq 0 ] || return 0
  BOUND_CO_LOADED=1
  [ -n "$SESSION_ID" ] || return 0
  [ -z "$CALLER_IDENTITY_ERROR" ] || return 0
  BOUND_CO="$(scope_read_bound_company "$SESSION_ID" "$CALLER_AGENT_ID")"
  # SessionStart bind can land in the same turn as the first company path.
  # Re-read once rather than weakening the deny.
  if [ -z "$BOUND_CO" ]; then
    BOUND_CO="$(scope_read_bound_company "$SESSION_ID" "$CALLER_AGENT_ID")"
  fi
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

  [ "$co" = "$BOUND_CO" ]
}

scope_block_rel() {
  local rel="${1:-}"
  local glob_reason="${2:-}"
  local co bound_msg bind_msg=""
  scope_load_bound_company
  co="$(scope_company_slug_for_rel "$rel")"
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
    bound_msg="This subagent has no company binding for its agent_id, so its company access is denied. Restart or respawn the subagent so the host can bind its company scope."
  elif [ -z "$BOUND_CO" ]; then
    bound_msg="Session has no company_slug bound."
    bind_msg="Bind the correct company with: core/scripts/hq-session.sh set company_slug <slug>
If that reports success but this keeps blocking, the bind landed on another
session — retry it as: core/scripts/hq-session.sh --session-id ${SESSION_ID:-<id>} set company_slug <slug>"
  else
    bound_msg="Session company_slug is '$BOUND_CO'."
  fi

  cat >&2 <<EOF
BLOCKED: Cross-company scope violation
Tool: $TOOL
Path: $rel
EOF
  if [ -n "$glob_reason" ]; then
    printf 'Target company: %s (glob "%s" blocked: %s)\n' "${co:-unknown}" "$rel" "$glob_reason" >&2
  else
    printf 'Target company: %s\n' "${co:-unknown}" >&2
  fi
  cat >&2 <<EOF
Session: ${SESSION_ID:-unknown}
$bound_msg

For data files, use the Write tool (or Edit to change an existing file) with a
literal path under your bound company. Do not write company files with a Bash
heredoc or redirect.
EOF
  if [ -n "$bind_msg" ]; then
    printf '%s\n' "$bind_msg" >&2
  fi
  printf 'Allowed without binding: core/, personal/, repos/, workspace/, companies/manifest.yaml, companies/_template/\n' >&2
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

scope_check_bash_skill_path() {
  local raw="${1:-}" command_text="${2:-}" prefix="${3:-}" suffix="${4:-}"
  local masked backtick token rel resolved expansion_cwd expanded
  [ -n "$raw" ] || return 0
  if [ -z "$prefix" ] && [[ "$command_text" == *"$raw"* ]]; then
    prefix="${command_text%%"$raw"*}"
    suffix="${command_text#*"$raw"}"
  fi
  scope_candidate_is_inert_text "$raw" "$command_text" "$prefix" "$suffix" && return 0
  case "$raw" in */*|/*) ;; *) return 0 ;; esac
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
  rel="$(scope_normalize_hq_relative "$raw")"
  masked="$(scope_mask_literal_expansions "$raw")"
  backtick=$'\140'
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
      scope_prefix_length=$((scope_offset + ${#scope_before}))
      scope_prefix="${scope_scan_cmd:0:$scope_prefix_length}"
      scope_suffix="${scope_scan_cmd:$((scope_prefix_length + ${#fragment}))}"
      scope_consumed=$((${#scope_before} + ${#fragment}))
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
    scope_segments="$(hq_shell_simple_commands "$scope_scan_cmd")"
    while IFS= read -r scope_record; do
      [ -n "$scope_record" ] || continue
      IFS=$'\037' read -r -a scope_tokens <<< "$scope_record"
      [ "${#scope_tokens[@]}" -gt 0 ] || continue
      for scope_token in "${scope_tokens[@]}"; do
        case "$scope_token" in companies/*|.claude*) continue ;; esac
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
