# shellcheck shell=bash
# hq-core: public
# bash-arith-subst-guard-lib.sh: one check shared by the Bash branches of
# mandatory-scope-authorizer.sh, block-credential-file-read.sh and
# enforce-vault-write-access.sh. Sourced, never run.
#
# Why: bash reads a variable's VALUE as an arithmetic expression when the
# variable is used in an arithmetic context, and expands an array subscript
# found in that value at that moment, command substitutions included. The
# command text the guards inspect then shows only a variable name, while the
# command that runs sits in the value. The value can be written where the
# guards treat text as inert data (single quotes, escapes, a quoted heredoc)
# or come from outside the command (read, mapfile, printf -v, getopts,
# arguments, the environment).
#
# Rule: in every arithmetic or subscript context, each variable that is read
# must be shown by the command itself to hold a number. Shown means every
# assignment of it in the command is one of
#   - a literal number (or empty),
#   - an arithmetic result: $((...)), $[...], or an assignment inside an
#     arithmetic context,
#   - a length expansion ${#...},
#   - a numeric for-list: literal numbers, {N..M}, $(seq N M), or the keys
#     ${!arr[@]} of an indexed array,
#   - the output of `wc -l` on stdin or `grep -c` on stdin or one file,
#     `date +%s`, `id -u` / `id -g`, `git rev-list --count` with literal
#     revisions, or `jq length` on one literal file,
#   - another variable that is itself shown to be a number,
# and at least one of them comes before the use. A variable that is also set
# by read, mapfile, readarray, printf -v, getopts, select, wait -p or
# ${name:=...}, or that holds a positional parameter, other command output or
# a non-numeric literal, is refused. A variable with no assignment in the
# command is refused (its value would come from the environment), except the
# counters bash maintains itself (RANDOM, SECONDS, LINENO, ...).
# One inert exception: `wc -l NAME.EXT` with a literal dotted basename may
# pass, although its output includes the filename and is not numeric. Bash
# rejects that dot during identifier lookahead, before reading the name's
# value. Use `wc -l < file` for arithmetic that succeeds. Other wc file
# operands are refused because their output may reference unchecked names.
#
# Arithmetic and subscript contexts checked: $((...)), $[...], ((...)) and
# for ((...)), let, declare/local/typeset -i values, indexed-array subscripts
# (in expansions, assignments and name arguments), substring offsets
# ${v:off:len}, indirect expansion ${!name} (the name must hold a literal
# variable name or a number), [[ ... -eq|-ne|-lt|-le|-gt|-ge ... ]], and the
# name arguments of read, mapfile, readarray, getopts, printf -v, wait -p,
# unset, declare/local/typeset/export/readonly, test -v and [[ -v ]].
# Namerefs (declare -n) must point at a literal name, and the ${v@P} prompt
# expansion is refused.
#
# Text inside single quotes, $'...' and quoted heredocs is data for most
# commands. When the command can run text as shell code (eval, trap, alias,
# bash/sh/zsh/... , source, su, ssh, watch, parallel, script, $SHELL, PS4=,
# PROMPT_COMMAND=, BASH_ENV=), that text is checked as code as well.
#
# Interface:
#   hq_arith_guard_check CMD
#     returns 0 to allow, 1 to refuse; on refusal HQ_ARITH_GUARD_REASON holds
#     one plain sentence for the block message.
# Pure bash 3.2+, no subprocesses (the spawn-budget tests count them), safe
# under set -euo pipefail when called as `if ! hq_arith_guard_check ...`.
# Inspected code and executable heredoc bodies are limited to 16 KiB; inert
# quoted-heredoc data is removed before that limit. Numeric proofs survive
# same-shell branches and loops; new conditional proofs expire at their end.
# Shell reentry and arbitrary substitutions do not establish numeric proofs.
# Associative string keys and unclassified command names are refused.

HQ_ARITH_GUARD_REASON=""

# Shared plain-language explanation; callers retain their own exit/JSON
# contracts. This is an arithmetic decision, not a path or credential denial.
hq_arith_guard_message() {
  printf 'BLOCKED: Bash arithmetic check. %s.\n' "$HQ_ARITH_GUARD_REASON" >&2
  printf '%s\n' 'Rewrite: assign a literal number or an arithmetic result before using the variable as a number; keep unchecked input out of that variable.' >&2
}

# Counters bash maintains itself; a read of one needs no assignment.
_HQ_AG_SPECIAL=' RANDOM SECONDS LINENO PPID UID EUID PIPESTATUS BASH_SUBSHELL '
_HQ_AG_SAFE_LIT_RE='^[A-Za-z0-9_.,:/%+@-]+$'
_HQ_AG_NAME_RE='^[A-Za-z_][A-Za-z0-9_]*$'
_HQ_AG_NAME_SUB_RE='^([A-Za-z_][A-Za-z0-9_]*)\[(.*)\]$'
_HQ_AG_INT_RE='^[+-]?[0-9]+$'
_HQ_AG_HEX_RE='^0[xX][0-9A-Fa-f]+$'
_HQ_AG_BASE_RE='^[0-9]+#[0-9A-Za-z@_]+$'
_HQ_AG_RANGE_RE='^\{[+-]?[0-9]+\.\.[+-]?[0-9]+(\.\.[+-]?[0-9]+)?\}$'
_HQ_AG_KEYS_RE='^\$\{!([A-Za-z_][A-Za-z0-9_]*)\[[@*]\]\}$'
_HQ_AG_VARREF_RE='^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$'
_HQ_AG_WORD_RUN_RE='^[^[:space:];&|)<>$(\[`]+'
_HQ_AG_EVALUATING_HEADS=' let declare typeset local export readonly read readarray mapfile printf getopts unset wait test eval source . trap alias command builtin bash sh zsh ksh dash mksh ash busybox su ssh watch parallel script '
# Text that can change what a resolved program name runs: a function
# definition, a PATH write (= or +=), enable (builtins on or off) or hash -p.
_HQ_AG_SHADOW_RE='\(\)[[:space:]]*\{|(^|[[:space:];&|(])function[[:space:]]|(^|[[:space:];&|(])PATH\+?=|(^|[[:space:];&|(])enable[[:space:]]|(^|[[:space:];&|(])hash[[:space:]]+-[A-Za-z]*p'
# A word that starts a simple command or an assignment: an identifier right
# after a separator, followed by `[`, `=`, `+=`, or (for the listed builtins)
# a separator. \003 marks the start of the text.
_HQ_AG_WORD_RE=$'[\003[:space:];&|()!`{](([A-Za-z_][A-Za-z0-9_]*)(\\[|\\+?=)|(let|read|readarray|mapfile|getopts|printf|unset|wait|test|declare|typeset|local|export|readonly|for|select|case|\\[)[[:space:];&|)])'

_hq_ag_fail() {
  if [ "$_hq_ag_mode" = check ] && [ -z "$_hq_ag_reason" ]; then
    _hq_ag_reason="$1"
  fi
  return 1
}

# _hq_ag_close TEXT START OPEN CLOSE: index of the CLOSE that balances an
# OPEN just before START, in _hq_ag_m (-1 and status 1 when unbalanced).
_hq_ag_close() {
  local t="$1" j="$2" o="$3" c="$4" d=1 n=${#1} w k ch
  while [ "$j" -lt "$n" ]; do
    w="${t:j:512}"
    case "$o" in
      '(') k="${w%%[()]*}" ;;
      '[') k="${w%%[][]*}" ;;
      *) k="${w%%[\{\}]*}" ;;
    esac
    if [ "${#k}" -eq "${#w}" ]; then
      j=$((j + ${#w}))
      continue
    fi
    j=$((j + ${#k}))
    ch="${t:j:1}"
    if [ "$ch" = "$o" ]; then
      d=$((d + 1))
    elif [ "$ch" = "$c" ]; then
      d=$((d - 1))
      if [ "$d" -eq 0 ]; then
        _hq_ag_m=$j
        return 0
      fi
    fi
    j=$((j + 1))
  done
  _hq_ag_m=-1
  return 1
}

# _hq_ag_wordend TEXT START: end (exclusive) of the shell word at START, in
# _hq_ag_m. $(...), ${...}, $[...], (...), [...] and `...` count as one word.
_hq_ag_wordend() {
  local t="$1" j="$2" n=${#1} ch rest w chunk
  while [ "$j" -lt "$n" ]; do
    chunk="${t:j:512}"
    if [[ "$chunk" =~ $_HQ_AG_WORD_RUN_RE ]]; then
      j=$((j + ${#BASH_REMATCH[0]}))
      continue
    fi
    ch="${t:j:1}"
    case "$ch" in
      ' ' | $'\t' | $'\n' | ';' | '&' | '|' | ')' | '<' | '>') break ;;
      '$')
        case "${t:j+1:1}" in
          '(') if _hq_ag_close "$t" $((j + 2)) '(' ')'; then j=$((_hq_ag_m + 1)); else j=$n; fi ;;
          '{') if _hq_ag_close "$t" $((j + 2)) '{' '}'; then j=$((_hq_ag_m + 1)); else j=$n; fi ;;
          '[') if _hq_ag_close "$t" $((j + 2)) '[' ']'; then j=$((_hq_ag_m + 1)); else j=$n; fi ;;
          *) j=$((j + 1)) ;;
        esac
        ;;
      '(') if _hq_ag_close "$t" $((j + 1)) '(' ')'; then j=$((_hq_ag_m + 1)); else j=$n; fi ;;
      '[') if _hq_ag_close "$t" $((j + 1)) '[' ']'; then j=$((_hq_ag_m + 1)); else j=$((j + 1)); fi ;;
      '`')
        rest="${t:j+1}"
        case "$rest" in
          *'`'*) w="${rest%%\`*}"; j=$((j + ${#w} + 2)) ;;
          *) j=$n ;;
        esac
        ;;
      *) j=$((j + 1)) ;;
    esac
  done
  _hq_ag_m=$j
}

# _hq_ag_words TEXT START: the words of one simple command from START to the
# next ; & | newline or unbalanced ), without redirections. Sets _hq_ag_w[],
# _hq_ag_wp[] (start index of each word), _hq_ag_nw, and _hq_ag_m (the stop).
_hq_ag_words() {
  local t="$1" j="$2" n=${#1} ch s wd
  _hq_ag_nw=0
  while [ "$j" -lt "$n" ]; do
    ch="${t:j:1}"
    case "$ch" in
      ' ' | $'\t') j=$((j + 1)); continue ;;
      ';' | '&' | '|' | $'\n' | ')') break ;;
      '<' | '>')
        while [ "$j" -lt "$n" ]; do
          case "${t:j:1}" in '<' | '>') j=$((j + 1)) ;; *) break ;; esac
        done
        if [ "${t:j:1}" = '&' ]; then
          j=$((j + 1))
          while [ "$j" -lt "$n" ]; do
            case "${t:j:1}" in [0-9] | '-') j=$((j + 1)) ;; *) break ;; esac
          done
          continue
        fi
        while [ "${t:j:1}" = ' ' ] || [ "${t:j:1}" = $'\t' ]; do j=$((j + 1)); done
        _hq_ag_wordend "$t" "$j"
        j=$_hq_ag_m
        continue
        ;;
    esac
    s=$j
    _hq_ag_wordend "$t" "$j"
    j=$_hq_ag_m
    if [ "$j" -le "$s" ]; then
      j=$((s + 1))
      continue
    fi
    wd="${t:s:j-s}"
    # 2>file: the digits are a file descriptor, not a word.
    case "${t:j:1}" in
      '<' | '>') case "$wd" in *[!0-9]*) ;; *) continue ;; esac ;;
    esac
    _hq_ag_w[_hq_ag_nw]="$wd"
    _hq_ag_wp[_hq_ag_nw]=$s
    _hq_ag_nw=$((_hq_ag_nw + 1))
  done
  _hq_ag_m=$j
}

# ---------------------------------------------------------------- lexer
#
# _hq_ag_lex CMD REENTRY: writes the code view of CMD to _hq_ag_V and returns
# 1 when the quoting cannot be followed. In the code view:
#   - single-quoted and $'...' text is kept when it is a plain word of
#     [A-Za-z0-9_.,:/%+@-], otherwise replaced by \001 (opaque literal);
#     with REENTRY=1 it is kept as written, since it may run as code;
#   - backslash escapes become \001 (kept as the escaped char with REENTRY);
#   - double quotes are dropped; inside them whitespace becomes \002 and
#     ; & | ( ) ! < > become \004, so quoted text never starts a command,
#     while $(...), ${...} and `...` stay visible;
#   - quoted heredoc bodies are dropped (kept as code with REENTRY);
#     unquoted bodies are read like double-quoted text;
#   - comments are dropped.

_hq_ag_lit() {
  if [ "$re" = 1 ]; then
    _hq_ag_V+="$1"
  elif [ -z "$1" ]; then
    :
  elif [[ "$1" =~ $_HQ_AG_SAFE_LIT_RE ]]; then
    _hq_ag_V+="$1"
  else
    _hq_ag_V+=$'\001'
  fi
}

# _hq_ag_hd_extent TEXT START DELIM STRIP: the heredoc body that starts at
# START ends at _hq_ag_he; the text after its delimiter line starts at
# _hq_ag_hs. Status 1 when the delimiter line is missing.
_hq_ag_hd_extent() {
  local t="$1" b="$2" dl="$3" st="$4" quoted="$5" off=0 line cmp tab=$'\t'
  while IFS= read -r line || [ -n "$line" ]; do
    # Unquoted backslash-newline joins before delimiter matching. Refuse
    # that ambiguous form rather than dropping code after a joined marker.
    if [ "$quoted" = 0 ]; then case "$line" in *'\') return 1 ;; esac; fi
    cmp="$line"
    if [ "$st" = 1 ]; then
      cmp="${cmp#"${cmp%%[!$tab]*}"}"
    fi
    if [ "$cmp" = "$dl" ]; then
      _hq_ag_he=$((b + off))
      _hq_ag_hs=$((b + off + ${#line} + 1))
      [ "$_hq_ag_hs" -le "${#t}" ] || _hq_ag_hs=${#t}
      return 0
    fi
    off=$((off + ${#line} + 1))
  done <<<"${t:b}"
  # A quoted delimiter disables body expansion/line joining. Only that
  # known-inert case may safely consume an unmatched body through EOF.
  [ "$quoted" = 1 ] || return 1
  _hq_ag_he=${#t}
  _hq_ag_hs=${#t}
  return 0
}

# Start the next pending heredoc body at i (uses _hq_ag_lex's locals).
_hq_ag_hd_start() {
  while [ "$hk" -lt "$nh" ]; do
    _hq_ag_hd_extent "$s" "$i" "${hdd[hk]}" "${hds[hk]}" "${hdq[hk]}" || return 1
    if [ "$re" != 1 ] && [ "${hdq[hk]}" = 1 ]; then
      hk=$((hk + 1))
      i=$_hq_ag_hs
      _hq_ag_V+=$'\n'
      continue
    fi
    hd_end=$_hq_ag_he
    hd_skip=$_hq_ag_hs
    if [ $((hd_end - i)) -gt 16384 ]; then return 1; fi
    if [ "$re" = 1 ]; then
      hd_frame=0
      hd_base=$nf
    else
      ft[nf]=H
      fd[nf]=0
      nf=$((nf + 1))
      hd_frame=1
      # Heredoc prose is data, even when its expansions are active. Keep a
      # distinct token for the command-head scan; nested substitutions stay
      # visible and are checked as code separately.
      _hq_ag_V+=$'\006'
    fi
    hk=$((hk + 1))
    return 0
  done
  nh=0
  hk=0
  return 0
}

_hq_ag_lex() {
  local s="$1" re="$2" n=${#1} i=0 j c d t w k nf=0 cd=0 body rest delim hq strip delimiter_quote
  local hd_end=-1 hd_skip=-1 hd_frame=0 hd_base=0 nh=0 hk=0 tab=$'\t'
  local p_code=$'[]\'"\\\\$()`#<[\n]*'
  local p_dq=$'[\'"\\\\$` \t\n;&|()!<>]*'
  local -a ft=() fd=() hdd=() hdq=() hds=()
  _hq_ag_V=""
  _hq_ag_qpos=" "
  _hq_ag_ansi=0
  while :; do
    [ "${#_hq_ag_V}" -le 16384 ] || return 1
    if [ "$hd_end" -ge 0 ] && [ "$i" -ge "$hd_end" ]; then
      if [ "$hd_frame" = 1 ]; then
        if [ "$nf" -eq 0 ] || [ "${ft[nf-1]}" != H ]; then return 1; fi
        nf=$((nf - 1))
      elif [ "$nf" -ne "$hd_base" ]; then
        return 1
      fi
      i=$hd_skip
      hd_end=-1
      _hq_ag_V+=$'\n'
      _hq_ag_hd_start || return 1
      continue
    fi
    [ "$i" -lt "$n" ] || break
    t=C
    [ "$nf" -gt 0 ] && t="${ft[nf-1]}"
    w="${s:i:256}"
    if [ "$hd_end" -ge 0 ] && [ $((i + ${#w})) -gt "$hd_end" ]; then
      w="${s:i:hd_end-i}"
    fi
    case "$t" in
      D | H) k="${w%%$p_dq}" ;;
      *) k="${w%%$p_code}" ;;
    esac
    if [ -n "$k" ]; then
      _hq_ag_V+="$k"
      i=$((i + ${#k}))
      continue
    fi
    c="${s:i:1}"
    if [ "$t" = D ] || [ "$t" = H ]; then
      case "$c" in
        '"')
          if [ "$t" = D ]; then nf=$((nf - 1)); else _hq_ag_V+=$'\001'; fi
          i=$((i + 1))
          ;;
        "'") _hq_ag_V+=$'\001'; i=$((i + 1)) ;;
        '\')
          d="${s:i+1:1}"
          case "$d" in
            $'\n') i=$((i + 2)) ;;
            '$' | '`' | '\')
              if [ "$re" = 1 ]; then _hq_ag_V+="$d"; else _hq_ag_V+=$'\001'; fi
              i=$((i + 2))
              ;;
            '"')
              if [ "$t" = D ]; then
                if [ "$re" = 1 ]; then _hq_ag_V+='"'; else _hq_ag_V+=$'\001'; fi
                i=$((i + 2))
              else
                _hq_ag_V+=$'\001'
                i=$((i + 1))
              fi
              ;;
            *) _hq_ag_V+=$'\001'; i=$((i + 1)) ;;
          esac
          ;;
        '$')
          if [ "${s:i+1:1}" = '(' ]; then
            ft[nf]=S; fd[nf]=0; nf=$((nf + 1))
            _hq_ag_V+='$('
            i=$((i + 2))
          elif [ "${s:i+1:1}" = '{' ]; then
            # Parameter operators retain their meaning inside double quotes.
            _hq_ag_close "$s" $((i + 2)) '{' '}' || return 1
            _hq_ag_V+="${s:i:_hq_ag_m-i+1}"
            i=$((_hq_ag_m + 1))
          else
            _hq_ag_V+='$'
            i=$((i + 1))
          fi
          ;;
        '`') ft[nf]=K; fd[nf]=0; nf=$((nf + 1)); _hq_ag_V+='`'; i=$((i + 1)) ;;
        ' ' | "$tab" | $'\n')
          if [ "$re" = 1 ]; then _hq_ag_V+="$c"; else _hq_ag_V+=$'\002'; fi
          i=$((i + 1))
          ;;
        *)
          if [ "$re" = 1 ]; then _hq_ag_V+="$c"; else _hq_ag_V+=$'\004'; fi
          i=$((i + 1))
          ;;
      esac
      continue
    fi
    case "$c" in
      "'")
        _hq_ag_qpos+="${#_hq_ag_V} "
        rest="${s:i+1}"
        case "$rest" in *"'"*) ;; *) return 1 ;; esac
        body="${rest%%\'*}"
        _hq_ag_lit "$body"
        i=$((i + ${#body} + 2))
        ;;
      '"') _hq_ag_qpos+="${#_hq_ag_V} "; ft[nf]=D; fd[nf]=0; nf=$((nf + 1)); i=$((i + 1)) ;;
      '\')
        d="${s:i+1:1}"
        if [ "$d" = $'\n' ]; then
          : # The shell removes a continued newline without separating words.
        elif [ "$re" = 1 ]; then
          _hq_ag_V+="$d"
        else
          _hq_ag_qpos+="${#_hq_ag_V} "
          case "$d" in
            [A-Za-z0-9_-]) _hq_ag_V+="$d" ;;
            *) _hq_ag_V+=$'\001' ;;
          esac
        fi
        i=$((i + 2))
        ;;
      '$')
        case "${s:i+1:1}" in
          "'")
            j=$((i + 2))
            body=""
            while [ "$j" -lt "$n" ]; do
              d="${s:j:1}"
              if [ "$d" = '\' ]; then
                body+="${s:j:2}"
                j=$((j + 2))
                continue
              fi
              [ "$d" = "'" ] && break
              body+="$d"
              j=$((j + 1))
            done
            [ "$j" -lt "$n" ] || return 1
            if [ "$re" = 1 ]; then
              case "$body" in *'\'*) _hq_ag_ansi=1 ;; esac
            fi
            _hq_ag_lit "$body"
            i=$((j + 1))
            ;;
          '"') ft[nf]=D; fd[nf]=0; nf=$((nf + 1)); i=$((i + 2)) ;;
          '(') ft[nf]=S; fd[nf]=0; nf=$((nf + 1)); _hq_ag_V+='$('; i=$((i + 2)) ;;
          '[') ft[nf]=B; fd[nf]=0; nf=$((nf + 1)); _hq_ag_V+='$['; i=$((i + 2)) ;;
          *) _hq_ag_V+='$'; i=$((i + 1)) ;;
        esac
        ;;
      '(')
        if [ "$t" = S ]; then fd[nf-1]=$((fd[nf-1] + 1)); elif [ "$t" = C ]; then cd=$((cd + 1)); fi
        _hq_ag_V+='('
        i=$((i + 1))
        ;;
      ')')
        if [ "$t" = S ]; then
          if [ "${fd[nf-1]}" -eq 0 ]; then nf=$((nf - 1)); else fd[nf-1]=$((fd[nf-1] - 1)); fi
        elif [ "$t" = C ] && [ "$cd" -gt 0 ]; then
          cd=$((cd - 1))
        fi
        _hq_ag_V+=')'
        i=$((i + 1))
        ;;
      '[')
        if [ "$t" = B ]; then fd[nf-1]=$((fd[nf-1] + 1)); fi
        _hq_ag_V+='['
        i=$((i + 1))
        ;;
      ']')
        if [ "$t" = B ]; then
          if [ "${fd[nf-1]}" -eq 0 ]; then nf=$((nf - 1)); else fd[nf-1]=$((fd[nf-1] - 1)); fi
        fi
        _hq_ag_V+=']'
        i=$((i + 1))
        ;;
      '`')
        if [ "$t" = K ]; then nf=$((nf - 1)); else ft[nf]=K; fd[nf]=0; nf=$((nf + 1)); fi
        _hq_ag_V+='`'
        i=$((i + 1))
        ;;
      '#')
        d="${_hq_ag_V: -1}"
        case "$d" in
          '' | ' ' | "$tab" | $'\n' | ';' | '&' | '|' | '(')
            rest="${s:i}"
            body="${rest%%$'\n'*}"
            i=$((i + ${#body}))
            ;;
          *) _hq_ag_V+='#'; i=$((i + 1)) ;;
        esac
        ;;
      '<')
        if [ "${s:i:3}" = '<<<' ]; then
          _hq_ag_V+='<<<'
          i=$((i + 3))
          continue
        fi
        # A heredoc only where a command can start: not inside ((...)),
        # $((...)) or $[...], where << is a shift.
        if [ "${s:i+1:1}" = '<' ] && [ "${s:i+2:1}" != '<' ] \
          && { { [ "$t" = C ] && [ "$cd" -eq 0 ]; } || { [ "$t" = S ] && [ "${fd[nf-1]}" -eq 0 ]; } || [ "$t" = K ]; }; then
          j=$((i + 2))
          strip=0
          if [ "${s:j:1}" = '-' ]; then strip=1; j=$((j + 1)); fi
          while [ "${s:j:1}" = ' ' ] || [ "${s:j:1}" = "$tab" ]; do j=$((j + 1)); done
          delim=""
          hq=0
          delimiter_quote=""
          while [ "$j" -lt "$n" ]; do
            d="${s:j:1}"
            if [ -n "$delimiter_quote" ]; then
              if [ "$delimiter_quote" = '"' ] && [ "$d" = '\' ]; then
                case "${s:j+1:1}" in
                  '$' | '`' | '"' | '\') delim+="${s:j+1:1}"; j=$((j + 2)); continue ;;
                  $'\n') j=$((j + 2)); continue ;;
                esac
              fi
              if [ "$d" = "$delimiter_quote" ]; then delimiter_quote=""; else delim+="$d"; fi
              j=$((j + 1))
              continue
            fi
            case "$d" in
              '$')
                case "${s:j+1:1}" in "'" | '"') return 1 ;; esac
                delim+="$d"; j=$((j + 1))
                ;;
              ' ' | "$tab" | $'\n' | ';' | '&' | '|' | '<' | '>' | '(' | ')') break ;;
              "'" | '"') hq=1; delimiter_quote="$d"; j=$((j + 1)) ;;
              '\')
                if [ "${s:j+1:1}" != $'\n' ]; then hq=1; delim+="${s:j+1:1}"; fi
                j=$((j + 2))
                ;;
              *) delim+="$d"; j=$((j + 1)) ;;
            esac
          done
          [ -z "$delimiter_quote" ] || return 1
          [ -n "$delim" ] || return 1
          hdd[nh]="$delim"
          hdq[nh]=$hq
          hds[nh]=$strip
          nh=$((nh + 1))
          _hq_ag_V+='<< '
          i=$j
        else
          _hq_ag_V+='<'
          i=$((i + 1))
        fi
        ;;
      $'\n')
        _hq_ag_V+=$'\n'
        i=$((i + 1))
        if [ "$hk" -lt "$nh" ] && [ "$hd_end" -lt 0 ]; then
          _hq_ag_hd_start || return 1
        fi
        ;;
      *) _hq_ag_V+="$c"; i=$((i + 1)) ;;
    esac
  done
  [ "$nf" -eq 0 ] || return 1
  [ "$hk" -ge "$nh" ] || [ "$nh" -eq 0 ] || return 1
  return 0
}

# ---------------------------------------------------------------- proofs

# _hq_ag_bind NAME KIND POS. KIND: N number, I identifier literal, U unknown,
# R:<names> same as those variables.
_hq_ag_bind() {
  local loop=0 expiry=${#_hq_ag_V}
  local kind="$2"
  [ "${_hq_ag_binding_allowed:-1}" = 1 ] || kind=U
  while [ "$loop" -lt "$_hq_ag_nfr" ]; do
    if [ "$3" -ge "${_hq_ag_forpos[loop]}" ] && [ "$3" -le "${_hq_ag_forend[loop]}" ]; then
      expiry=${_hq_ag_forend[loop]}
    fi
    loop=$((loop + 1))
  done
  loop=0
  while [ "$loop" -lt "$_hq_ag_nr" ]; do
    if [ "$3" -ge "${_hq_ag_rs[loop]}" ] && [ "$3" -le "${_hq_ag_re[loop]}" ] \
      && [ "${_hq_ag_re[loop]}" -lt "$expiry" ]; then
      expiry=${_hq_ag_re[loop]}
    fi
    loop=$((loop + 1))
  done
  _hq_ag_bn[_hq_ag_nb]="$1"
  _hq_ag_bk[_hq_ag_nb]="$kind"
  _hq_ag_bp[_hq_ag_nb]="$3"
  _hq_ag_be[_hq_ag_nb]=$expiry
  _hq_ag_nb=$((_hq_ag_nb + 1))
}

# _hq_ag_ctx KIND TEXT POS [NAME]. KIND: E arithmetic expression, P inside of
# ${...}, N name argument, S subscript of NAME.
_hq_ag_ctx() {
  _hq_ag_ck[_hq_ag_nc]="$1"
  _hq_ag_ct[_hq_ag_nc]="$2"
  _hq_ag_cp[_hq_ag_nc]="$3"
  _hq_ag_cn[_hq_ag_nc]="${4:-}"
  _hq_ag_nc=$((_hq_ag_nc + 1))
}

# _hq_ag_prove NAME POS MODE [DEPTH]: NAME holds a number (MODE arith) or a
# literal variable name or number (MODE ind) when read at POS.
_hq_ag_prove() {
  local nm="$1" p="$2" md="$3" dp="${4:-0}" k=0 found=0 kd r
  [ "$dp" -le 8 ] || return 1
  # Textual order cannot establish execution order across these constructs.
  [ "$_hq_ag_uncertain_flow" = 0 ] || return 1
  while [ "$k" -lt "$_hq_ag_nb" ]; do
    if [ "${_hq_ag_bn[k]}" = "$nm" ]; then
      kd="${_hq_ag_bk[k]}"
      case "$kd" in
        U) return 1 ;;
        I) [ "$md" = ind ] || [ "$md" = command ] || return 1 ;;
        L) [ "$md" = command ] || return 1 ;;
        R:*)
          for r in ${kd#R:}; do
            _hq_ag_prove "$r" "${_hq_ag_bp[k]}" "$md" $((dp + 1)) || return 1
          done
          ;;
      esac
      if [ "${_hq_ag_bp[k]}" -lt "$p" ] && [ "$p" -le "${_hq_ag_be[k]}" ]; then found=1; fi
    fi
    k=$((k + 1))
  done
  [ "$found" = 1 ] && return 0
  if [ "$md" = arith ]; then
    case "$_HQ_AG_SPECIAL" in *" $nm "*) return 0 ;; esac
  fi
  return 1
}

_hq_ag_read() { # NAME POS
  [ "$_hq_ag_mode" = check ] || return 0
  _hq_ag_prove "$1" "$2" arith && return 0
  _hq_ag_fail "\$$1 is used as a number (arithmetic, an array index or a numeric test), but this command does not show that it holds one"
}

# Numeric command output, plus the narrow inert wc-filename exception above.
_hq_ag_numcmd() {
  local x="$1" pre
  x="${x//$'\002'/ }"
  x="${x#"${x%%[![:space:]]*}"}"
  x="${x%"${x##*[![:space:]]}"}"
  case "$x" in *'||'* | *'&&'*) return 1 ;; esac
  local wc_re='^wc[[:space:]]+-l[[:space:]]*(<[[:space:]]*[^[:space:]<>|;&`(){}]+)?$'
  # Both Bash 3.2 and 5 readtok() look ahead with noeval=1, then call
  # expr_streval() for the identifier. The following dot raises evalerror()
  # during that lookahead, before any variable lookup. Do not broaden this
  # to a general path alphabet: a plain name or '/' can cause lookup first.
  local wc_file_re='^wc[[:space:]]+-l[[:space:]]+[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z0-9_]+$'
  local grep_re=$'^grep(([[:space:]]+-[cEFGPiwvxsy]+)+)[[:space:]]+([^[:space:]-][^[:space:]]*)([[:space:]]+([A-Za-z0-9_./~+@:,%\001-]+))?$'
  local date_re='^date([[:space:]]+-u)?[[:space:]]+\+%s$'
  local id_re='^id[[:space:]]+-[ug]r?$'
  local git_re='^git[[:space:]]+rev-list[[:space:]]+--count([[:space:]]+[A-Za-z0-9_./^][A-Za-z0-9_./~^:@+-]*)+$'
  local jq_re='^jq[[:space:]]+length[[:space:]]+[A-Za-z0-9_./][A-Za-z0-9_./~+@:,%+-]*$'
  # A pipeline into the counter: nothing but pipes before it, so its output
  # is the count alone.
  case "$x" in
    *'|'*)
      pre="${x%|*}"
      x="${x##*|}"
      x="${x#"${x%%[![:space:]]*}"}"
      case "$pre" in *';'* | *'&'* | *$'\n'* | *'||'*) return 1 ;; esac
      case "$x" in wc* | grep*) ;; *) return 1 ;; esac
      ;;
  esac
  [[ "$x" =~ $wc_re ]] && return 0
  # A grep pattern must not absorb a second command or expansion.
  case "$x" in *';'* | *'&'* | *'<'* | *'>'* | *'$'* | *'`'* | *$'\n'*) return 1 ;; esac
  if [[ "$x" =~ $grep_re ]]; then
    case "${BASH_REMATCH[1]}" in *c*) return 0 ;; esac
    return 1
  fi
  [[ "$x" =~ $date_re ]] && return 0
  [[ "$x" =~ $id_re ]] && return 0
  [[ "$x" =~ $wc_file_re ]] && return 0
  [[ "$x" =~ $git_re ]] && return 0
  [[ "$x" =~ $jq_re ]] && return 0
  return 1
}

# Subscript SUB of NAME at POS.
_hq_ag_sub() {
  case "$2" in '@' | '*') return 0 ;; esac
  # Do not infer array type from declarations: they may be conditional,
  # scoped to another shell, or unsupported by the executing Bash version.
  # Every non-list subscript must meet the same numeric proof rule.
  _hq_ag_E "$2" "$3"
}

# Name argument WORD at POS (read x, unset 'a[i]', printf -v x, ...).
_hq_ag_name() {
  if [[ "$1" =~ $_HQ_AG_NAME_RE ]]; then
    return 0
  fi
  if [[ "$1" =~ $_HQ_AG_NAME_SUB_RE ]]; then
    _hq_ag_sub "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$2"
    return $?
  fi
  _hq_ag_fail "a variable name passed to read, unset, printf -v, declare or a similar builtin is not a plain name"
}

# ${...} read inside an arithmetic expression.
_hq_ag_param_in_E() {
  local x="$1" p="$2" nm
  case "$x" in
    '#' | '#'[@*#?] | '#'[0-9]*) return 0 ;;
    '?' | '#' | '$' | '!') return 0 ;;
    '#'*)
      x="${x#\#}"
      if [[ "$x" =~ $_HQ_AG_NAME_RE ]]; then return 0; fi
      if [[ "$x" =~ $_HQ_AG_NAME_SUB_RE ]]; then
        _hq_ag_sub "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$p"
        return $?
      fi
      ;;
    *)
      if [[ "$x" =~ $_HQ_AG_NAME_RE ]]; then
        _hq_ag_read "$x" "$p"
        return $?
      fi
      if [[ "$x" =~ $_HQ_AG_NAME_SUB_RE ]]; then
        nm="${BASH_REMATCH[1]}"
        _hq_ag_sub "$nm" "${BASH_REMATCH[2]}" "$p" || return 1
        _hq_ag_read "$nm" "$p"
        return $?
      fi
      ;;
  esac
  _hq_ag_fail "an expansion inside arithmetic is not a plain variable, length or number"
}

# _hq_ag_E EXPR POS: check an arithmetic expression. In collect mode it only
# records assignments made inside it.
_hq_ag_E() {
  local e="$1" p="$2" m=${#1} j=0 c d k nm rest sub hassub q dep
  local conditional="${_hq_ag_conditional_expr:-0}"
  case "$e" in *'?'* | *'&&'* | *'||'*) conditional=1 ;; esac
  local _hq_ag_conditional_expr="$conditional"
  while [ "$j" -lt "$m" ]; do
    c="${e:j:1}"
    case "$c" in
      ' ' | $'\t' | $'\n' | $'\002') j=$((j + 1)) ;;
      [0-9])
        rest="${e:j}"
        rest="${rest%%[!0-9A-Za-z_#@]*}"
        j=$((j + ${#rest}))
        ;;
      [A-Za-z_])
        rest="${e:j}"
        nm="${rest%%[!A-Za-z0-9_]*}"
        j=$((j + ${#nm}))
        hassub=0
        sub=""
        if [ "${e:j:1}" = '[' ]; then
          if ! _hq_ag_close "$e" $((j + 1)) '[' ']'; then
            _hq_ag_fail "an array index inside arithmetic is not closed"
            return 1
          fi
          sub="${e:j+1:_hq_ag_m-j-1}"
          j=$((_hq_ag_m + 1))
          hassub=1
        fi
        rest="${e:j}"
        rest="${rest#"${rest%%[![:space:]$'\002']*}"}"
        if [ "$hassub" = 1 ]; then
          _hq_ag_sub "$nm" "$sub" $((p + j)) || return 1
        fi
        case "$rest" in
          '=='*) _hq_ag_read "$nm" $((p + j)) || return 1 ;;
          '='*)
            # Plain assignment: a write, not a read. The value is a number
            # from the end of this clause on.
            if [ "$_hq_ag_mode" = collect ] && [ "$conditional" = 0 ]; then
              q=$j
              dep=0
              while [ "$q" -lt "$m" ]; do
                d="${e:q:1}"
                case "$d" in
                  '(') dep=$((dep + 1)) ;;
                  ')') [ "$dep" -eq 0 ] && break; dep=$((dep - 1)) ;;
                  ',' | ';') [ "$dep" -eq 0 ] && break ;;
                esac
                q=$((q + 1))
              done
              if [ "$hassub" = 1 ]; then
                _hq_ag_bind "$nm" U $((p + q))
              else
                _hq_ag_bind "$nm" N $((p + q))
              fi
            fi
            ;;
          *) _hq_ag_read "$nm" $((p + j)) || return 1 ;;
        esac
        ;;
      '$')
        d="${e:j+1:1}"
        case "$d" in
          '(')
            if ! _hq_ag_close "$e" $((j + 2)) '(' ')'; then
              _hq_ag_fail "a substitution inside arithmetic is not closed"
              return 1
            fi
            k=$_hq_ag_m
            if [ "${e:j+2:1}" = '(' ] && [ "${e:k-1:1}" = ')' ]; then
              _hq_ag_E "${e:j+3:k-j-4}" $((p + j)) || return 1
            elif ! _hq_ag_numcmd "${e:j+2:k-j-2}"; then
              _hq_ag_fail "a command substitution inside arithmetic is not a supported numeric source"
              return 1
            fi
            j=$((k + 1))
            ;;
          '[')
            if ! _hq_ag_close "$e" $((j + 2)) '[' ']'; then
              _hq_ag_fail "an arithmetic expansion is not closed"
              return 1
            fi
            k=$_hq_ag_m
            _hq_ag_E "${e:j+2:k-j-2}" $((p + j)) || return 1
            j=$((k + 1))
            ;;
          '{')
            if ! _hq_ag_close "$e" $((j + 2)) '{' '}'; then
              _hq_ag_fail "an expansion inside arithmetic is not closed"
              return 1
            fi
            k=$_hq_ag_m
            _hq_ag_param_in_E "${e:j+2:k-j-2}" $((p + j)) || return 1
            j=$((k + 1))
            ;;
          [A-Za-z_])
            rest="${e:j+1}"
            nm="${rest%%[!A-Za-z0-9_]*}"
            _hq_ag_read "$nm" $((p + j)) || return 1
            j=$((j + 1 + ${#nm}))
            ;;
          '?' | '#' | '$' | '!') j=$((j + 2)) ;;
          *)
            _hq_ag_fail "a positional parameter or special expansion is used as a number"
            return 1
            ;;
        esac
        ;;
      '`')
        rest="${e:j+1}"
        case "$rest" in
          *'`'*) ;;
          *) _hq_ag_fail "a substitution inside arithmetic is not closed"; return 1 ;;
        esac
        rest="${rest%%\`*}"
        if ! _hq_ag_numcmd "$rest"; then
          _hq_ag_fail "a command substitution inside arithmetic is not a supported numeric source"
          return 1
        fi
        j=$((j + ${#rest} + 2))
        ;;
      '+' | '-' | '*' | '/' | '%' | '<' | '>' | '=' | '!' | '&' | '|' | '^' | '~' | '?' | ':' | ',' | '(' | ')' | ';')
        j=$((j + 1))
        ;;
      *)
        _hq_ag_fail "arithmetic contains quoted, escaped or other text that is not a number, variable or operator"
        return 1
        ;;
    esac
  done
  return 0
}

# _hq_ag_P INNER POS: the inside of one ${...} outside arithmetic.
_hq_ag_P() {
  local x="$1" p="$2" nm op rest d k q dep off len
  case "$x" in
    '#'*)
      rest="${x#\#}"
      if [[ "$rest" =~ $_HQ_AG_NAME_SUB_RE ]]; then
        _hq_ag_sub "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$p"
        return $?
      fi
      return 0
      ;;
    '!'*)
      rest="${x#!}"
      case "$rest" in '#' | '') return 0 ;; esac
      local keys_re='^[A-Za-z_][A-Za-z0-9_]*(\[[@*]\]|[@*])$'
      [[ "$rest" =~ $keys_re ]] && return 0
      nm="${rest%%[!A-Za-z0-9_]*}"
      case "$nm" in
        '' | [0-9]*)
          _hq_ag_fail "an indirect expansion \${!...} goes through a positional or special parameter"
          return 1
          ;;
      esac
      if [ "$_hq_ag_mode" = check ] && ! _hq_ag_prove "$nm" "$p" ind; then
        _hq_ag_fail "\${!$nm} uses the value of \$$nm as a variable name, but this command does not set it to a literal name"
        return 1
      fi
      op="${rest#"$nm"}"
      if [ "${op:0:1}" = '[' ]; then
        if ! _hq_ag_close "$op" 1 '[' ']'; then
          _hq_ag_fail "an array index is not closed"
          return 1
        fi
        k=$_hq_ag_m
        _hq_ag_sub "$nm" "${op:1:k-1}" "$p" || return 1
        op="${op:k+1}"
      fi
      ;;
    *)
      nm="${x%%[!A-Za-z0-9_]*}"
      if [ -z "$nm" ]; then
        case "$x" in
          [@*#?\$!-]*) nm="${x:0:1}" ;;
          *) _hq_ag_fail "an expansion \${...} could not be read"; return 1 ;;
        esac
      fi
      op="${x:${#nm}}"
      if [ "${op:0:1}" = '[' ]; then
        if ! _hq_ag_close "$op" 1 '[' ']'; then
          _hq_ag_fail "an array index is not closed"
          return 1
        fi
        k=$_hq_ag_m
        _hq_ag_sub "$nm" "${op:1:k-1}" "$p" || return 1
        op="${op:k+1}"
      fi
      case "$op" in
        ':='* | '='*)
          if [ "$_hq_ag_mode" = collect ]; then _hq_ag_bind "$nm" U "$p"; fi
          return 0
          ;;
      esac
      ;;
  esac
  case "$op" in
    '' | ':-'* | ':+'* | ':?'* | '-'* | '+'* | '?'* | '#'* | '%'* | '/'* | '^'* | ','*) return 0 ;;
    '@P'*)
      _hq_ag_fail "the \${...@P} prompt expansion runs the substitutions in a value"
      return 1
      ;;
    '@'*) return 0 ;;
    ':'*)
      # Substring: offset and length are arithmetic.
      rest="${op:1}"
      q=0
      dep=0
      while [ "$q" -lt "${#rest}" ]; do
        d="${rest:q:1}"
        case "$d" in
          '(' | '[' | '{') dep=$((dep + 1)) ;;
          ')' | ']' | '}') dep=$((dep - 1)) ;;
          ':') [ "$dep" -eq 0 ] && break ;;
        esac
        q=$((q + 1))
      done
      off="${rest:0:q}"
      _hq_ag_E "$off" "$p" || return 1
      if [ "$q" -lt "${#rest}" ]; then
        len="${rest:q+1}"
        _hq_ag_E "$len" "$p" || return 1
      fi
      return 0
      ;;
  esac
  _hq_ag_fail "an expansion \${...} uses a form this check does not know"
}

# Kind of an assignment value.
_hq_ag_classify() {
  local v="$1" inner
  _hq_ag_kind=U
  if [ -z "$v" ] || [[ "$v" =~ $_HQ_AG_INT_RE ]] || [[ "$v" =~ $_HQ_AG_HEX_RE ]] || [[ "$v" =~ $_HQ_AG_BASE_RE ]]; then
    _hq_ag_kind=N
    return
  fi
  case "$v" in
    '$?' | '$#' | '$$' | '$!') _hq_ag_kind=N; return ;;
  esac
  if [[ "$v" =~ $_HQ_AG_VARREF_RE ]]; then
    _hq_ag_kind="R:${BASH_REMATCH[1]}"
    return
  fi
  if [[ "$v" =~ $_HQ_AG_NAME_RE ]]; then
    _hq_ag_kind=I
    return
  fi
  if [[ "$v" =~ $_HQ_AG_SAFE_LIT_RE ]]; then
    _hq_ag_kind=L
    return
  fi
  case "$v" in
    '$(('*)
      if _hq_ag_close "$v" 2 '(' ')' && [ "$_hq_ag_m" -eq $((${#v} - 1)) ] && [ "${v:${#v}-2:1}" = ')' ]; then
        _hq_ag_kind=N
      fi
      ;;
    '$['*)
      if _hq_ag_close "$v" 2 '[' ']' && [ "$_hq_ag_m" -eq $((${#v} - 1)) ]; then _hq_ag_kind=N; fi
      ;;
    '${#'*)
      if _hq_ag_close "$v" 2 '{' '}' && [ "$_hq_ag_m" -eq $((${#v} - 1)) ]; then _hq_ag_kind=N; fi
      ;;
    '$('*)
      if _hq_ag_close "$v" 2 '(' ')' && [ "$_hq_ag_m" -eq $((${#v} - 1)) ]; then
        inner="${v:2:${#v}-3}"
        if _hq_ag_numcmd "$inner"; then
          _hq_ag_kind=N
        elif _hq_ag_resolver "$inner"; then
          # A program path: usable as a command name, never as a number.
          _hq_ag_kind=L
        fi
      fi
      ;;
    '`'*'`')
      inner="${v:1:${#v}-2}"
      case "$inner" in
        *'`'*) ;;
        *)
          if _hq_ag_numcmd "$inner"; then _hq_ag_kind=N
          elif _hq_ag_resolver "$inner"; then _hq_ag_kind=L
          fi
          ;;
      esac
      ;;
  esac
}

# Kind of a for-loop word list (words in _hq_ag_fl[0.._hq_ag_nfl-1]).
_hq_ag_forkind() {
  local k=0 x refs="" seq_re a
  seq_re='^\$\(seq(([[:space:]]+([+-]?[0-9]+|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?))+)\)$'
  while [ "$k" -lt "$_hq_ag_nfl" ]; do
    x="${_hq_ag_fl[k]}"
    x="${x//$'\002'/ }"
    k=$((k + 1))
    [[ "$x" =~ $_HQ_AG_INT_RE ]] && continue
    [[ "$x" =~ $_HQ_AG_RANGE_RE ]] && continue
    if [[ "$x" =~ $_HQ_AG_KEYS_RE ]]; then
      case "$_hq_ag_assoc" in *" ${BASH_REMATCH[1]} "*) _hq_ag_kind=U; return ;; esac
      continue
    fi
    if [[ "$x" =~ $seq_re ]]; then
      for a in ${BASH_REMATCH[1]}; do
        case "$a" in
          '$'*) a="${a#\$}"; a="${a#\{}"; a="${a%\}}"; refs="$refs $a" ;;
        esac
      done
      continue
    fi
    _hq_ag_kind=U
    return
  done
  if [ -n "$refs" ]; then _hq_ag_kind="R:${refs# }"; else _hq_ag_kind=N; fi
}

# Normalize the inside of [[ ... ]]: grouping parens, !, && and || and the
# string comparison < > become blanks; $(...), ${...} and $[...] are kept.
_hq_ag_test_norm() {
  local t="$1" j=0 n=${#1} ch out=""
  while [ "$j" -lt "$n" ]; do
    ch="${t:j:1}"
    case "$ch" in
      '$')
        case "${t:j+1:1}" in
          '(' | '{' | '[')
            _hq_ag_wordend "$t" "$j"
            out+="${t:j:_hq_ag_m-j}"
            j=$_hq_ag_m
            continue
            ;;
        esac
        out+='$'
        ;;
      '`')
        _hq_ag_wordend "$t" "$j"
        out+="${t:j:_hq_ag_m-j}"
        j=$_hq_ag_m
        continue
        ;;
      '(' | ')' | '!' | '&' | '|' | '<' | '>') out+=' ' ;;
      *) out+="$ch" ;;
    esac
    j=$((j + 1))
  done
  _hq_ag_tn="$out"
}

# ---------------------------------------------------------------- collect

# Keyword handler: KW at V index TP; arguments start at AS.
_hq_ag_unquoted_word() {
  local pos="$1" length="$2" q
  for q in $_hq_ag_qpos; do
    if [ "$q" -ge "$pos" ] && [ "$q" -le $((pos + length)) ]; then return 1; fi
  done
  return 0
}

_hq_ag_keyword() {
  local kw="$1" tp="$2" as="$3" k=0 x nw flags="" fl takes skip=0 opt nm pos name_next=0
  if [ "$_hq_ag_reentry" = 0 ] && [ "$_hq_ag_case_context" = 0 ]; then _hq_ag_command_position "$tp" || return 0; fi
  if [ "$kw" = case ]; then
    _hq_ag_unquoted_word "$tp" "${#kw}" || return 0
    _hq_ag_case_context=1; return 0
  fi
  if [ "$kw" = for ]; then
    _hq_ag_unquoted_word "$tp" "${#kw}" || return 0
  fi
  local -a ww=() wp=()
  _hq_ag_words "$_hq_ag_V" "$as"
  nw=$_hq_ag_nw
  while [ "$k" -lt "$nw" ]; do
    ww[k]="${_hq_ag_w[k]}"
    wp[k]="${_hq_ag_wp[k]}"
    k=$((k + 1))
  done
  local wend=$_hq_ag_m
  k=0
  case "$kw" in
    let)
      while [ "$k" -lt "$nw" ]; do
        _hq_ag_ctx E "${ww[k]}" "${wp[k]}"
        k=$((k + 1))
      done
      ;;
    read | mapfile | readarray | getopts | printf | wait | select)
      case "$kw" in
        read | select) _hq_ag_bind REPLY U "$tp" ;;
        mapfile | readarray) _hq_ag_bind MAPFILE U "$tp" ;;
        getopts) _hq_ag_bind OPTARG U "$tp"; _hq_ag_bind OPTIND U "$tp" ;;
      esac
      case "$kw" in
        read) takes='adinNptu' ;;
        mapfile | readarray) takes='dnOsuCc' ;;
        *) takes='' ;;
      esac
      if [ "$kw" = getopts ]; then
        # getopts OPTSTRING NAME [ARGS]
        if [ "$nw" -ge 2 ]; then
          _hq_ag_ctx N "${ww[1]}" "${wp[1]}"
          nm="${ww[1]%%[!A-Za-z0-9_]*}"
          [ -n "$nm" ] && _hq_ag_bind "$nm" U "$tp"
        fi
        return 0
      fi
      if [ "$kw" = select ]; then
        if [ "$nw" -ge 1 ]; then
          nm="${ww[0]%%[!A-Za-z0-9_]*}"
          [ -n "$nm" ] && _hq_ag_bind "$nm" U "$tp"
        fi
        return 0
      fi
      while [ "$k" -lt "$nw" ]; do
        x="${ww[k]}"
        pos="${wp[k]}"
        k=$((k + 1))
        if [ "$name_next" = 1 ]; then
          name_next=0
          _hq_ag_ctx N "$x" "$pos"
          nm="${x%%[!A-Za-z0-9_]*}"
          [ -n "$nm" ] && _hq_ag_bind "$nm" U "$tp"
          continue
        fi
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$kw" in
          printf | wait)
            # Only printf -v NAME and wait -p NAME set a variable.
            case "$x" in
              -v | -p)
                if { [ "$kw" = printf ] && [ "$x" = -v ]; } || { [ "$kw" = wait ] && [ "$x" = -p ]; }; then
                  name_next=1
                fi
                continue
                ;;
              -v?* | -p?*)
                if { [ "$kw" = printf ] && [ "${x:0:2}" = -v ]; } || { [ "$kw" = wait ] && [ "${x:0:2}" = -p ]; }; then
                  _hq_ag_ctx N "${x:2}" "$pos"
                  nm="${x:2}"
                  nm="${nm%%[!A-Za-z0-9_]*}"
                  [ -n "$nm" ] && _hq_ag_bind "$nm" U "$tp"
                fi
                continue
                ;;
              --) continue ;;
              -*) [ "$kw" = wait ] && continue; break ;;
            esac
            break
            ;;
        esac
        case "$x" in
          --) continue ;;
          -?*)
            fl="${x:1}"
            while [ -n "$fl" ]; do
              opt="${fl:0:1}"
              fl="${fl:1}"
              case "$takes" in
                *"$opt"*)
                  if [ "$opt" = a ]; then
                    if [ -n "$fl" ]; then
                      _hq_ag_ctx N "$fl" "$pos"
                      nm="${fl%%[!A-Za-z0-9_]*}"
                      [ -n "$nm" ] && _hq_ag_bind "$nm" U "$tp"
                    else
                      name_next=1
                    fi
                  elif [ -z "$fl" ]; then
                    skip=1
                  fi
                  fl=""
                  ;;
              esac
            done
            continue
            ;;
        esac
        _hq_ag_ctx N "$x" "$pos"
        nm="${x%%[!A-Za-z0-9_]*}"
        [ -n "$nm" ] && _hq_ag_bind "$nm" U "$tp"
      done
      ;;
    unset)
      while [ "$k" -lt "$nw" ]; do
        x="${ww[k]}"
        case "$x" in
          -f) return 0 ;;
          -*) ;;
          *) _hq_ag_ctx N "$x" "${wp[k]}" ;;
        esac
        k=$((k + 1))
      done
      ;;
    test | '[')
      while [ "$k" -lt "$nw" ]; do
        if [ "${ww[k]}" = -v ] && [ $((k + 1)) -lt "$nw" ]; then
          _hq_ag_ctx N "${ww[k+1]}" "${wp[k+1]}"
        fi
        k=$((k + 1))
      done
      ;;
    declare | typeset | local | export | readonly)
      while [ "$k" -lt "$nw" ]; do
        x="${ww[k]}"
        case "$x" in
          -- ) k=$((k + 1)); continue ;;
          [-+]*) flags="$flags${x:1}"; k=$((k + 1)); continue ;;
        esac
        break
      done
      case "$flags" in *[pfF]*) return 0 ;; esac
      while [ "$k" -lt "$nw" ]; do
        x="${ww[k]}"
        pos="${wp[k]}"
        k=$((k + 1))
        case "$x" in
          *=*)
            nm="${x%%=*}"
            nm="${nm%+}"
            ;;
          *) nm="$x" ;;
        esac
        _hq_ag_ctx N "$nm" "$pos"
        nm="${nm%%[!A-Za-z0-9_]*}"
        [ -n "$nm" ] || continue
        case "$flags" in *A*)
          _hq_ag_assoc="$_hq_ag_assoc$nm "
          ;;
        esac
        case "$flags" in *i*)
          _hq_ag_int="$_hq_ag_int$nm "
          case "$x" in *=*) _hq_ag_ctx E "${x#*=}" "$pos" ;; esac
          ;;
        esac
        case "$flags" in *n*) _hq_ag_nref="$_hq_ag_nref$nm " ;; esac
        # local may be outside a function or inherit an unchecked value;
        # a declaration without an assignment supplies no numeric proof.
        case "$x" in
          *=*) ;;
          *)
            case "$kw" in
              local | readonly) _hq_ag_bind "$nm" U "$((pos + ${#x}))" ;;
              declare | typeset) case "$flags" in *r*) _hq_ag_bind "$nm" U "$((pos + ${#x}))" ;; esac ;;
            esac
            ;;
        esac
      done
      ;;
    for)
      [ "$nw" -ge 1 ] || return 0
      x="${ww[0]}"
      [[ "$x" =~ $_HQ_AG_NAME_RE ]] || return 0
      if [ "$nw" -lt 2 ] || [ "${ww[1]}" != in ]; then
        # for NAME; do ... iterates over the positional parameters.
        _hq_ag_bind "$x" U "$tp"
        return 0
      fi
      _hq_ag_nfl=0
      k=2
      while [ "$k" -lt "$nw" ] && [ "${ww[k]}" != do ]; do
        _hq_ag_fl[_hq_ag_nfl]="${ww[k]}"
        _hq_ag_nfl=$((_hq_ag_nfl + 1))
        k=$((k + 1))
      done
      _hq_ag_forraw[_hq_ag_nfr]="$x"
      _hq_ag_forpos[_hq_ag_nfr]="$wend"
      # Bindings established only in the loop cannot prove a later use:
      # even indexed keys may be empty. The first done is conservative for
      # nested loops; it can shorten a proof, never extend it.
      local loop_tail="${_hq_ag_V:wend}" loop_done='(^|[[:space:];])done([[:space:];]|$)' loop_pre
      if [[ "$loop_tail" =~ $loop_done ]]; then
        loop_pre="${loop_tail%%"${BASH_REMATCH[0]}"*}"
        _hq_ag_forend[_hq_ag_nfr]=$((wend + ${#loop_pre}))
      else
        _hq_ag_forend[_hq_ag_nfr]=$wend
      fi
      _hq_ag_forlist[_hq_ag_nfr]=""
      k=0
      while [ "$k" -lt "$_hq_ag_nfl" ]; do
        _hq_ag_forlist[_hq_ag_nfr]+="${_hq_ag_fl[k]}"$'\005'
        k=$((k + 1))
      done
      _hq_ag_nfr=$((_hq_ag_nfr + 1))
      ;;
  esac
  return 0
}

# Only assignment-only commands and declaration arguments prove a binding.
# A word such as `echo x=1`, or a command-local `x=1 env`, is not a proof.
_hq_ag_assignment_position() {
  local tp="$1" nm="$2" start end k=0 word declaration=0 declaration_name="" q found=0
  local declaration_flags_re='^-[airtx]+$'
  _hq_ag_command_start "$tp"
  start=$_hq_ag_start
  _hq_ag_words "$_hq_ag_V" "$start"
  end=$_hq_ag_m
  _hq_ag_proof=1
  case "${_hq_ag_V:end:2}" in
    '&&' | '||') ;;
    '|'* | '&'*) _hq_ag_proof=0 ;;
  esac
  if [ "$start" -gt 0 ]; then
    case "${_hq_ag_V:start-2:2}" in
      '&&' | '||') ;;
      *) case "${_hq_ag_V:start-1:1}" in '|' | '&') _hq_ag_proof=0 ;; esac ;;
    esac
  fi
  while [ "$k" -lt "$_hq_ag_nw" ]; do
    word="${_hq_ag_w[k]}"
    [ "${_hq_ag_wp[k]}" -eq "$tp" ] && found=1
    case "$word" in
      command | builtin | do | then | else | if | elif | while | until) [ "$found" = 1 ] && _hq_ag_proof=0 ;;
      declare | typeset | local | export | readonly)
        [ "$found" = 1 ] && _hq_ag_proof=0
        declaration=1
        declaration_name="$word"
        ;;
      [-+]*)
        [ "$declaration" = 1 ] || return 1
        if [ "$word" != -- ]; then
          case "$declaration_name" in
            declare | typeset | local) [[ "$word" =~ $declaration_flags_re ]] || _hq_ag_proof=0 ;;
            *) _hq_ag_proof=0 ;;
          esac
        fi
        ;;
      *)
        if ! [[ "$word" =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?= ]]; then
          if [ "$declaration" = 1 ]; then
            [[ "$word" =~ $_HQ_AG_NAME_RE ]] || _hq_ag_proof=0
          else
            [ "$found" = 1 ] || return 1
            _hq_ag_proof=0
          fi
        fi
        ;;
    esac
    k=$((k + 1))
  done
  [ "$found" = 1 ] || return 1
  if [ "$declaration" = 0 ]; then
    for q in $_hq_ag_qpos; do
      if [ "$q" -ge "$tp" ] && [ "$q" -le $((tp + ${#nm})) ]; then return 1; fi
    done
  fi
  return 0
}

_hq_ag_command_start() {
  local prefix="${_hq_ag_V:0:$1}" tail separators=$';\n&|(`{'
  tail="${prefix##*[$separators]}"
  _hq_ag_start=$((${#prefix} - ${#tail}))
}

# A builtin or reserved word is syntax only in command position. Prefix
# assignments and the shell's command/builtin wrappers may precede it.
_hq_ag_command_position() {
  local tp="$1" k=0 word
  _hq_ag_command_start "$tp"
  _hq_ag_words "$_hq_ag_V" "$_hq_ag_start"
  while [ "$k" -lt "$_hq_ag_nw" ]; do
    [ "${_hq_ag_wp[k]}" -eq "$tp" ] && return 0
    word="${_hq_ag_w[k]}"
    case "$word" in command | builtin | do | then | else | if | elif | while | until | '!' | --) ;;
      *) [[ "$word" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || return 1 ;;
    esac
    k=$((k + 1))
  done
  return 1
}

# Record where newly established proofs expire. A numeric assignment inside
# a possibly skipped branch/loop is still numeric, but cannot initialize a
# later use outside it. Earlier proofs remain valid; unknown writes anywhere
# still poison the name in _hq_ag_prove. Only a literal `if true` has a then
# branch known to execute. Function/subshell/reentry scopes stay fail-closed.
_hq_ag_region() {
  _hq_ag_rs[_hq_ag_nr]="$1"
  _hq_ag_re[_hq_ag_nr]="$2"
  _hq_ag_nr=$((_hq_ag_nr + 1))
}

_hq_ag_regions() {
  local start=0 stop k nw word pos head depth=0 inner prefix conditional=0 pending=0
  local has_compound=0 has_job=0
  local -a words=() positions=() kinds=() starts=() limited=()
  while [ "$start" -lt "${#_hq_ag_V}" ]; do
    _hq_ag_words "$_hq_ag_V" "$start"
    stop=$_hq_ag_m; nw=$_hq_ag_nw
    # Empty commands (including a redirection-only command) have no words.
    # Indexed copying avoids empty-array expansion under Bash 3.2 nounset.
    words=(); positions=(); k=0
    while [ "$k" -lt "$nw" ]; do
      words[k]="${_hq_ag_w[k]}"; positions[k]="${_hq_ag_wp[k]}"
      k=$((k + 1))
    done
    # _words skips substitutions and redirections, so this sees shell job
    # operators even after a compound's redirects or before its first word.
    case "${_hq_ag_V:stop:2}" in
      '&&' | '||') ;;
      '&'* | '|'*) has_job=1 ;;
    esac
    # A command to the right of && or || may never run. Do not carry its
    # new proofs across another operator (especially a switch from && to ||).
    conditional=$pending
    if [ "$start" -ge 2 ]; then
      case "${_hq_ag_V:start-2:2}" in
        '&&' | '||')
          conditional=1
          ;;
      esac
    fi
    # Newlines (including a removed comment's newline) after &&/|| do not
    # start an unconditional command. Keep the pending operator until a
    # nonempty command has been classified.
    pending=0
    if [ "$nw" = 0 ]; then
      pending=$conditional
    elif [ "$conditional" = 1 ]; then
      _hq_ag_region "$start" "$stop"
    fi
    k=0; head=1
    while [ "$k" -lt "$nw" ] && [ "$head" = 1 ]; do
      word="${words[k]}"; pos="${positions[k]}"; k=$((k + 1))
      if ! _hq_ag_unquoted_word "$pos" "${#word}"; then break; fi
      case "$word" in
        if)
          has_compound=1
          kinds[depth]=if; starts[depth]=$pos; limited[depth]=1
          if [ "$conditional" = 0 ] && [ "$k" -lt "$nw" ] && [ "${words[k]}" = true ] \
            && [ $((k + 1)) -eq "$nw" ] && [ "${_hq_ag_V:stop:1}" != '&' ] \
            && [ "${_hq_ag_V:stop:1}" != '|' ]; then limited[depth]=0; fi
          depth=$((depth + 1))
          ;;
        while | until | for)
          has_compound=1
          kinds[depth]=loop; starts[depth]=$pos; limited[depth]=1
          # C-for initialization runs even when its body is skipped. Only
          # the condition/update/body bindings expire at done.
          if [ "$word" = for ] && [ "$k" -lt "$nw" ]; then
            inner="${words[k]}"
            case "$inner" in
              '(('*';'*)
                prefix="${inner%%;*}"
                starts[depth]=$((positions[k] + ${#prefix} + 1))
                ;;
            esac
          fi
          depth=$((depth + 1)); head=0
          ;;
        else | elif)
          if [ "$depth" -gt 0 ] && [ "${kinds[depth-1]}" = if ]; then
            if [ "${limited[depth-1]}" = 1 ]; then _hq_ag_region "${starts[depth-1]}" "$pos"; fi
            starts[depth-1]=$pos; limited[depth-1]=1
          fi
          ;;
        fi | done)
          if [ "$depth" -gt 0 ]; then
            depth=$((depth - 1))
            if [ "${limited[depth]}" = 1 ]; then _hq_ag_region "${starts[depth]}" "$pos"; fi
          fi
          head=0
          ;;
        then | do | '!' | '{') ;;
        *) head=0 ;;
      esac
    done
    start=$((stop + 1))
    case "${_hq_ag_V:stop:2}" in '&&' | '||') start=$((stop + 2)) ;; esac
  done
  # An unclosed compound command cannot establish a lasting proof.
  while [ "$depth" -gt 0 ]; do
    depth=$((depth - 1))
    _hq_ag_region "${starts[depth]}" "${#_hq_ag_V}"
  done
  # Do not infer execution scope for compound pipeline/background jobs.
  # Standalone numeric-command substitutions remain handled by _numcmd.
  if [ "$has_compound" = 1 ] && [ "$has_job" = 1 ]; then _hq_ag_uncertain_flow=1; fi
}

# Assignment NAME at V index TP; OP is `[`, `=` or `+=`.
_hq_ag_assign() {
  local nm="$1" tp="$2" op="$3" j sub="" hassub=0 vs ve val isarr=0 ar=0
  # Arithmetic writes are collected by _hq_ag_E with their own conditional
  # semantics. Re-reading them as shell assignments would invent proofs for
  # skipped &&/||/ternary operands.
  while [ "$ar" -lt "$_hq_ag_nar" ]; do
    if [ "$tp" -ge "${_hq_ag_ars[ar]}" ] && [ "$tp" -le "${_hq_ag_are[ar]}" ]; then return 0; fi
    ar=$((ar + 1))
  done
  if ! _hq_ag_assignment_position "$tp" "$nm"; then
    [ "$_hq_ag_case_context" = 1 ] || return 0
    # A case arm cannot establish a proof, but its possible writes still
    # need their arithmetic contexts checked.
    _hq_ag_proof=0
  fi
  j=$((tp + ${#nm}))
  if [ "$op" = '[' ]; then
    _hq_ag_close "$_hq_ag_V" $((j + 1)) '[' ']' || return 0
    sub="${_hq_ag_V:j+1:_hq_ag_m-j-1}"
    j=$((_hq_ag_m + 1))
    hassub=1
    case "${_hq_ag_V:j:2}" in
      '+=') j=$((j + 2)) ;;
      '='*) j=$((j + 1)) ;;
      *) return 0 ;;   # a glob such as file[0-9], not an assignment
    esac
  else
    j=$((tp + ${#nm} + ${#op}))
  fi
  vs=$j
  if [ "${_hq_ag_V:j:1}" = '(' ]; then
    if _hq_ag_close "$_hq_ag_V" $((j + 1)) '(' ')'; then
      ve=$((_hq_ag_m + 1))
    else
      ve=${#_hq_ag_V}
    fi
    isarr=1
  else
    _hq_ag_wordend "$_hq_ag_V" "$j"
    ve=$_hq_ag_m
  fi
  val="${_hq_ag_V:vs:ve-vs}"
  _hq_ag_an[_hq_ag_na]="$nm"
  _hq_ag_as[_hq_ag_na]="$sub"
  _hq_ag_ah[_hq_ag_na]=$hassub
  _hq_ag_av[_hq_ag_na]="$val"
  _hq_ag_aa[_hq_ag_na]=$isarr
  _hq_ag_ap[_hq_ag_na]=$tp
  _hq_ag_ae[_hq_ag_na]=$ve
  _hq_ag_aproof[_hq_ag_na]=$_hq_ag_proof
  case "$op" in '+=') _hq_ag_ao[_hq_ag_na]='+=' ;; '[') case "${_hq_ag_V:vs-2:1}" in '+') _hq_ag_ao[_hq_ag_na]='+=' ;; *) _hq_ag_ao[_hq_ag_na]='=' ;; esac ;; *) _hq_ag_ao[_hq_ag_na]='=' ;; esac
  _hq_ag_na=$((_hq_ag_na + 1))
}

_hq_ag_collect() {
  local V="$_hq_ag_V" j k e rest pre m tp S off
  # An arbitrary command substitution runs in another shell. Its assignments
  # cannot establish proofs in this command. Trust only the counter forms,
  # which contain no assignments, and literal numeric seq lists.
  local body seq_re='^seq[[:space:]]+[0-9 .+-]+$'
  j=0
  while :; do
    rest="${V:j}"
    case "$rest" in *'$('* ) ;; *) break ;; esac
    pre="${rest%%'$('*}"
    k=$((j + ${#pre}))
    if [ "${V:k+2:1}" != '(' ]; then
      _hq_ag_close "$V" $((k + 2)) '(' ')' || return 1
      body="${V:k+2:_hq_ag_m-k-2}"
      case "$body" in *'='*) _hq_ag_uncertain_flow=1 ;; esac
      if ! _hq_ag_numcmd "$body" && ! [[ "$body" =~ $seq_re ]] && ! _hq_ag_resolver "$body"; then
        _hq_ag_uncertain_flow=1
      fi
    fi
    j=$((k + 2))
  done
  rest="$V"
  while [[ "$rest" == *'`'* ]]; do
    rest="${rest#*\`}"
    body="${rest%%\`*}"
    case "$body" in *'='*) _hq_ag_uncertain_flow=1 ;; esac
    _hq_ag_numcmd "$body" || _hq_ag_resolver "$body" || _hq_ag_uncertain_flow=1
    case "$rest" in *'`'*) rest="${rest#*\`}" ;; *) break ;; esac
  done
  # Arithmetic: ((...)), $((...)) and for ((...)).
  j=0
  while :; do
    rest="${V:j}"
    case "$rest" in *'(('*) ;; *) break ;; esac
    pre="${rest%%'(('*}"
    k=$((j + ${#pre}))
    if ! _hq_ag_close "$V" $((k + 1)) '(' ')'; then
      _hq_ag_reason="an arithmetic expression is not closed"
      return 1
    fi
    e=$_hq_ag_m
    if [ "${V:e-1:1}" = ')' ] && [ $((e - 1)) -gt $((k + 1)) ]; then
      _hq_ag_ctx E "${V:k+2:e-k-3}" "$((k + 2))"
      _hq_ag_ars[_hq_ag_nar]=$k
      _hq_ag_are[_hq_ag_nar]=$e
      _hq_ag_nar=$((_hq_ag_nar + 1))
      j=$((e + 1))
    else
      j=$((k + 1))
    fi
  done
  # $[...]
  j=0
  while :; do
    rest="${V:j}"
    case "$rest" in *'$['*) ;; *) break ;; esac
    pre="${rest%%'$['*}"
    k=$((j + ${#pre}))
    if ! _hq_ag_close "$V" $((k + 2)) '[' ']'; then
      _hq_ag_reason="an arithmetic expression is not closed"
      return 1
    fi
    _hq_ag_ctx E "${V:k+2:_hq_ag_m-k-2}" "$k"
    j=$((k + 2))
  done
  # ${...}
  j=0
  while :; do
    rest="${V:j}"
    case "$rest" in *'${'*) ;; *) break ;; esac
    pre="${rest%%'${'*}"
    k=$((j + ${#pre}))
    if ! _hq_ag_close "$V" $((k + 2)) '{' '}'; then
      _hq_ag_reason="a \${...} expansion is not closed"
      return 1
    fi
    _hq_ag_ctx P "${V:k+2:_hq_ag_m-k-2}" "$k"
    j=$((k + 2))
  done
  # {name[sub]}>file: the fd number is stored in name[sub].
  j=0
  local brace_re='^\{([A-Za-z_][A-Za-z0-9_]*)\['
  while :; do
    rest="${V:j}"
    case "$rest" in *'{'*) ;; *) break ;; esac
    pre="${rest%%'{'*}"
    k=$((j + ${#pre}))
    j=$((k + 1))
    rest="${V:k:256}"
    [[ "$rest" =~ $brace_re ]] || continue
    m="${BASH_REMATCH[1]}"
    _hq_ag_close "$V" $((k + 2 + ${#m})) '[' ']' || continue
    if [ "${V:_hq_ag_m+1:1}" = '}' ]; then
      _hq_ag_ctx S "${V:k+2+${#m}:_hq_ag_m-k-2-${#m}}" "$k" "$m"
    fi
  done
  # [[ ... ]]
  j=0
  while :; do
    rest="${V:j}"
    case "$rest" in *'[['*) ;; *) break ;; esac
    pre="${rest%%'[['*}"
    k=$((j + ${#pre}))
    j=$((k + 2))
    case "${V:k-1:1}" in
      '' | ' ' | $'\t' | $'\n' | ';' | '&' | '|' | '(' | '!' | '`') ;;
      *) [ "$k" -eq 0 ] || continue ;;
    esac
    rest="${V:k+2}"
    m="${rest%%[[:space:]]]]*}"
    _hq_ag_test_norm "$m"
    _hq_ag_test "$_hq_ag_tn" $((k + 2))
  done
  # Command words and assignments.
  S=$'\003'"$V"' '
  off=0
  rest="$S"
  while [[ "$rest" =~ $_HQ_AG_WORD_RE ]]; do
    m="${BASH_REMATCH[0]}"
    pre="${rest%%"$m"*}"
    tp=$((off + ${#pre}))
    if [ -n "${BASH_REMATCH[2]}" ]; then
      _hq_ag_assign "${BASH_REMATCH[2]}" "$tp" "${BASH_REMATCH[3]}"
    else
      _hq_ag_keyword "${BASH_REMATCH[4]}" "$tp" $((tp + ${#BASH_REMATCH[4]}))
    fi
    off=$((tp + 2))
    rest="${S:off}"
  done
  return 0
}

# Words of a [[ ]] test (normalized) starting at V index P.
_hq_ag_test() {
  local t="$1" p="$2" k=0 nw x
  local -a ww=() wp=()
  _hq_ag_words "$t" 0
  nw=$_hq_ag_nw
  while [ "$k" -lt "$nw" ]; do
    ww[k]="${_hq_ag_w[k]}"
    wp[k]=$((p + ${_hq_ag_wp[k]}))
    k=$((k + 1))
  done
  k=0
  while [ "$k" -lt "$nw" ]; do
    x="${ww[k]}"
    case "$x" in
      -eq | -ne | -lt | -le | -gt | -ge)
        [ "$k" -gt 0 ] && _hq_ag_ctx E "${ww[k-1]}" "${wp[k-1]}"
        [ $((k + 1)) -lt "$nw" ] && _hq_ag_ctx E "${ww[k+1]}" "${wp[k+1]}"
        ;;
      -v)
        [ $((k + 1)) -lt "$nw" ] && _hq_ag_ctx N "${ww[k+1]}" "${wp[k+1]}"
        ;;
    esac
    k=$((k + 1))
  done
  return 0
}

# Bindings from the assignments and for-loops, once the attribute sets are
# known.
_hq_ag_build() {
  local k=0 nm val pos tp el x kind ok
  local _hq_ag_binding_allowed=1
  while [ "$k" -lt "$_hq_ag_na" ]; do
    nm="${_hq_ag_an[k]}"
    val="${_hq_ag_av[k]}"
    tp="${_hq_ag_ap[k]}"
    pos="${_hq_ag_ae[k]}"
    _hq_ag_binding_allowed=${_hq_ag_aproof[k]}
    k=$((k + 1))
    if [ "${_hq_ag_ah[k-1]}" = 1 ]; then
      _hq_ag_ctx S "${_hq_ag_as[k-1]}" "$tp" "$nm"
      # A partial write cannot prove the untouched elements (including [0]).
      case "$_hq_ag_int" in *" $nm "*) _hq_ag_ctx E "$val" "$tp" ;; esac
      _hq_ag_bind "$nm" U "$pos"
      continue
    fi
    if [ "${_hq_ag_ao[k-1]}" = '+=' ]; then
      # String appends are legal, but prove a number only with a numeric old
      # value. Integer appends are checked as arithmetic below as well.
      if ! _hq_ag_prove "$nm" "$tp" arith; then
        _hq_ag_bind "$nm" U "$pos"
      fi
    fi
    case "$_hq_ag_nref" in
      *" $nm "*)
        if [[ "$val" =~ $_HQ_AG_NAME_RE ]]; then
          _hq_ag_ctx E "$val" "$tp"
          _hq_ag_bind "$nm" I "$pos"
        elif [[ "$val" =~ $_HQ_AG_NAME_SUB_RE ]]; then
          _hq_ag_ctx S "${BASH_REMATCH[2]}" "$tp" "${BASH_REMATCH[1]}"
          _hq_ag_bind "$nm" I "$pos"
        else
          _hq_ag_reason="a nameref (declare -n) must point at a literal variable name"
          return 1
        fi
        continue
        ;;
    esac
    if [ "${_hq_ag_aa[k-1]}" = 1 ]; then
      # name=(...) or name+=(...): numeric literals only, or arithmetic for
      # an integer array.
      _hq_ag_words "${val:1:${#val}-2}" 0
      ok=N
      el=0
      while [ "$el" -lt "$_hq_ag_nw" ]; do
        x="${_hq_ag_w[el]}"
        # ([sub]=value): an indexed array's sub is arithmetic.
        if [ "${x:0:1}" = '[' ] && _hq_ag_close "$x" 1 '[' ']' && [ "${x:_hq_ag_m+1:1}" = '=' ]; then
          _hq_ag_ctx S "${x:1:_hq_ag_m-1}" "$tp" "$nm"
        fi
        case "$_hq_ag_int" in
          *" $nm "*) _hq_ag_ctx E "${x#\[*\]=}" "$tp" ;;
          *) [[ "$x" =~ $_HQ_AG_INT_RE ]] || ok=U ;;
        esac
        el=$((el + 1))
      done
      _hq_ag_bind "$nm" "$ok" "$pos"
      continue
    fi
    case "$_hq_ag_int" in
      *" $nm "*)
        _hq_ag_ctx E "$val" "$tp"
        # x+=v on an integer adds to the old value, which is read.
        if [ "${_hq_ag_ao[k-1]}" = '+=' ]; then _hq_ag_ctx E "$nm" "$tp"; fi
        _hq_ag_bind "$nm" N "$pos"
        continue
        ;;
    esac
    _hq_ag_classify "$val"
    _hq_ag_bind "$nm" "$_hq_ag_kind" "$pos"
  done
  k=0
  _hq_ag_binding_allowed=1
  while [ "$k" -lt "$_hq_ag_nfr" ]; do
    _hq_ag_nfl=0
    x="${_hq_ag_forlist[k]}"
    while [ -n "$x" ]; do
      _hq_ag_fl[_hq_ag_nfl]="${x%%$'\005'*}"
      _hq_ag_nfl=$((_hq_ag_nfl + 1))
      x="${x#*$'\005'}"
    done
    _hq_ag_forkind
    _hq_ag_bind "${_hq_ag_forraw[k]}" "$_hq_ag_kind" "${_hq_ag_forpos[k]}"
    k=$((k + 1))
  done
  return 0
}

_hq_ag_run_ctx() {
  local k=0 kind txt pos
  while [ "$k" -lt "$_hq_ag_nc" ]; do
    kind="${_hq_ag_ck[k]}"
    txt="${_hq_ag_ct[k]}"
    pos="${_hq_ag_cp[k]}"
    case "$kind" in
      E) _hq_ag_E "$txt" "$pos" ;;
      P) _hq_ag_P "$txt" "$pos" ;;
      N) _hq_ag_name "$txt" "$pos" ;;
      S) _hq_ag_sub "${_hq_ag_cn[k]}" "$txt" "$pos" ;;
    esac || {
      [ "$_hq_ag_mode" = check ] && return 1
    }
    k=$((k + 1))
  done
  return 0
}

# ---------------------------------------------------------------- entry

# A shell reading a literal script file receives its remaining arguments as
# data. Only -c/-s/stdin or an unclassified script operand needs a code view.
# File contents remain outside this command-text guard.
_hq_ag_needs_reentry() {
  local dot_re=$'(^|[[:space:];&|(`{])\\.[[:space:]]' dot_rest="$_hq_ag_V" dot_offset=0 dot_match dot_pre dot_at
  while [[ "$dot_rest" =~ $dot_re ]]; do
    dot_match="${BASH_REMATCH[0]}"; dot_pre="${dot_rest%%"$dot_match"*}"
    dot_at=$((dot_offset + ${#dot_pre} + ${#BASH_REMATCH[1]}))
    _hq_ag_command_position "$dot_at" && return 0
    dot_offset=$((dot_at + 1)); dot_rest="${_hq_ag_V:dot_offset}"
  done
  local other_re=$'(^|[[:space:];&|(`/])(eval|trap|alias|source|su|ssh|watch|parallel|script)([[:space:];&|)]|$)|(^|[;\n&|(`])[[:space:]]*((command|builtin)[[:space:]]+)?\\.[[:space:]]|\\$\\{?(SHELL|BASH|0)([^A-Za-z0-9_]|$)|(^|[[:space:];&|(])(PS4|PROMPT_COMMAND|BASH_ENV|ENV)='
  [[ "$_hq_ag_V" =~ $other_re ]] && return 0
  local shell_re=$'(^|[[:space:];&|(`/])(bash|sh|zsh|ksh|dash|mksh|ash|busybox)([[:space:];&|)]|$)'
  local rest="$_hq_ag_V" offset=0 pre match at name k word script
  while [[ "$rest" =~ $shell_re ]]; do
    match="${BASH_REMATCH[0]}"; name="${BASH_REMATCH[2]}"
    pre="${rest%%"$match"*}"
    at=$((offset + ${#pre} + ${#BASH_REMATCH[1]} + ${#name}))
    _hq_ag_words "$_hq_ag_V" "$at"
    k=0; script=""
    while [ "$k" -lt "$_hq_ag_nw" ]; do
      word="${_hq_ag_w[k]}"; k=$((k + 1))
      case "$word" in
        --noprofile | --norc | --) continue ;;
        --*) return 0 ;;
        -*) case "$word" in *c* | *s*) return 0 ;; *) continue ;; esac ;;
        *) script="$word"; break ;;
      esac
    done
    [[ "$script" =~ $_HQ_AG_SAFE_LIT_RE ]] || return 0
    case "$script" in */* | *.sh) ;; *) return 0 ;; esac
    offset=$((at + 1)); rest="${_hq_ag_V:offset}"
  done
  return 1
}

# A substitution body that only resolves one literal program name
# (command -v NAME, which NAME, type -P NAME). It assigns nothing and runs no
# other code. Sets _hq_ag_rname to NAME.
_hq_ag_resolver() {
  local x="$1" re='^(command[[:space:]]+-v|which|type[[:space:]]+-P)[[:space:]]+([A-Za-z0-9_][A-Za-z0-9_.+-]*)$'
  x="${x//$'\002'/ }"
  x="${x#"${x%%[![:space:]]*}"}"
  x="${x%"${x##*[![:space:]]}"}"
  # An unquoted newline would end the resolver and start a second command.
  case "$x" in *$'\n'* | *$'\r'*) return 1 ;; esac
  [[ "$x" =~ $re ]] || return 1
  _hq_ag_rname="${BASH_REMATCH[2]}"
}

# A whole word that is exactly $(RESOLVER) or `RESOLVER`.
_hq_ag_resolved_value() {
  local v="$1"
  case "$v" in
    '$(('*) return 1 ;;
    '$('*')') _hq_ag_resolver "${v:2:${#v}-3}" ;;
    '`'*'`') _hq_ag_resolver "${v:1:${#v}-2}" ;;
    *) return 1 ;;
  esac
}

# The base name of PATH is in the evaluating-heads list. macOS and Windows
# file systems fold case and Windows adds .exe, so /bin/BASH and bash.exe
# still run bash: compare without case and without a trailing .exe.
_hq_ag_evaluating_name() {
  local n="${1##*/}" rc=1 nocase=0
  shopt -q nocasematch && nocase=1
  shopt -s nocasematch
  case "$n" in *.exe) n="${n%????}" ;; esac
  case "$_HQ_AG_EVALUATING_HEADS" in *" $n "*) rc=0 ;; esac
  [ "$nocase" = 1 ] || shopt -u nocasematch
  return "$rc"
}

# A resolved NAME may run as a command name only outside shell reentry, with
# nothing in the command that could shadow the resolver (_HQ_AG_SHADOW_RE),
# and when NAME is not a command that evaluates arithmetic or shell code.
_hq_ag_resolver_ok() {
  [ "$_hq_ag_reentry" = 0 ] || return 1
  [[ "$_hq_ag_V" =~ $_HQ_AG_SHADOW_RE ]] && return 1
  _hq_ag_evaluating_name "$1" && return 1
  return 0
}

# These existing path resolvers name an external executable, not arbitrary
# shell code from a file or environment value. Evaluating shell names remain
# excluded even when resolved through which/command -v/type -P.
_hq_ag_command_path() {
  local word="$1" _hq_ag_rname=""
  local root_re='^\$\(git rev-parse --show-toplevel\)/[A-Za-z0-9_./-]+$'
  if _hq_ag_resolved_value "$word"; then
    _hq_ag_resolver_ok "$_hq_ag_rname"
    return
  fi
  if [[ "$word" =~ $root_re ]]; then
    _hq_ag_resolver_ok "$word"
    return
  fi
  return 1
}

# Opaque or computed command names can hide arithmetic builtins themselves.
# Inspect heads separately from arguments, including nested code. A plain
# variable may name a literal non-evaluating command/path proved in this same
# command; all other computed heads are refused without running them.
_hq_ag_heads() {
  local text="$1" base="$2" depth="${3:-0}" start=0 stop=0 nw k head word pos inner j rest pre at nm v found idx function_name=0 case_depth=0 case_pattern=0 restart_case=0
  local function_re='^[A-Za-z_][A-Za-z0-9_]*\(\)\{?$'
  local -a words=() positions=()
  [ "$depth" -le 16 ] || { _hq_ag_reason="nested shell code exceeds the arithmetic guard limit"; return 1; }
  while [ "$start" -lt "${#text}" ]; do
    _hq_ag_words "$text" "$start"
    stop=$_hq_ag_m
    nw=$_hq_ag_nw
    k=0
    while [ "$k" -lt "$nw" ]; do
      words[k]="${_hq_ag_w[k]}"; positions[k]="${_hq_ag_wp[k]}"
      k=$((k + 1))
    done
    if [ "$case_pattern" = 1 ]; then
      if [ "$nw" -gt 0 ] && [ "${words[0]}" = esac ] && [ "${text:stop:1}" != ')' ] && _hq_ag_unquoted_word $((base + positions[0])) 4; then
        case_depth=$((case_depth - 1)); case_pattern=0
      elif [ "$nw" -gt 0 ] && [ "${text:positions[0]:1}" = '(' ]; then
        # The optional parenthesis before a case pattern is syntax, not a
        # subshell. Balanced extglob/bracket parts remain words below.
        start=$((positions[0] + 1)); continue
      elif [ "${text:stop:1}" = ')' ]; then
        case_pattern=0
      fi
      start=$((stop + 1)); continue
    fi
    head=1
    restart_case=0
    k=0
    while [ "$k" -lt "$nw" ]; do
      word="${words[k]}"; pos=$((base + positions[k])); k=$((k + 1))
      [ "$head" = 1 ] || continue
      if [ "$function_name" = 1 ]; then
        function_name=0
        if [[ "$word" =~ $_HQ_AG_NAME_RE ]] || [[ "$word" =~ $function_re ]]; then continue; fi
        _hq_ag_reason="a function name could not be classified"; return 1
      fi
      if [[ "$word" =~ $function_re ]]; then continue; fi
      if [[ "$word" =~ $_HQ_AG_NAME_RE ]] && [ "$k" -lt "$nw" ]; then
        case "${words[k]}" in '()' | '(){') k=$((k + 1)); continue ;; esac
      fi
      case "$word" in
        $'\006'*) head=0; continue ;;
        function) function_name=1; continue ;;
        'if' | 'then' | 'else' | 'elif' | 'while' | 'until' | 'do' | '{' | '!' | command | builtin | --) continue ;;
        -*) continue ;;
        case)
          if ! _hq_ag_unquoted_word "$pos" 4; then head=0; continue; fi
          if [ $((k + 1)) -ge "$nw" ] || [ "${words[k+1]}" != in ]; then
            _hq_ag_reason="case header could not be classified"; return 1
          fi
          case_depth=$((case_depth + 1)); case_pattern=1
          start=$((positions[k+1] + 2)); restart_case=1
          break
          ;;
        'esac')
          if _hq_ag_unquoted_word "$pos" 4 && [ "$case_depth" -gt 0 ]; then case_depth=$((case_depth - 1)); fi
          head=0; continue
          ;;
        for | select) head=0; continue ;;
        '[['* | '[' | '[ '*) head=0; continue ;;
        '(('*) head=0; continue ;;
        '('*)
          _hq_ag_heads "${word:1:${#word}-2}" $((pos + 1)) $((depth + 1)) || return 1
          head=0; continue
          ;;
      esac
      if [[ "$word" =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?= ]]; then continue; fi
      if _hq_ag_command_path "$word"; then head=0; continue; fi
      if [[ "$word" =~ $_HQ_AG_VARREF_RE ]]; then
        nm="${BASH_REMATCH[1]}"; found=0; idx=0
        [ "$_hq_ag_uncertain_flow" = 0 ] || { _hq_ag_reason="a computed command name crosses an uncertain shell scope"; return 1; }
        _hq_ag_prove "$nm" "$pos" command || { _hq_ag_reason="a computed command name has an unchecked input"; return 1; }
        while [ "$idx" -lt "$_hq_ag_na" ]; do
          if [ "${_hq_ag_an[idx]}" = "$nm" ]; then
            v="${_hq_ag_av[idx]}"
            if [ "${_hq_ag_aproof[idx]}" = 1 ] && _hq_ag_resolved_value "$v"; then
              # NAME=$(command -v prog); $NAME: same rule as the head form.
              _hq_ag_resolver_ok "$_hq_ag_rname" || {
                _hq_ag_reason="a computed command name may invoke arithmetic or shell evaluation"; return 1
              }
            else
              if [ "${_hq_ag_aproof[idx]}" != 1 ] || ! [[ "$v" =~ $_HQ_AG_SAFE_LIT_RE ]]; then
                _hq_ag_reason="a computed command name is not a proven literal"; return 1
              fi
              if _hq_ag_evaluating_name "$v"; then
                _hq_ag_reason="a computed command name may invoke arithmetic or shell evaluation"; return 1
              fi
            fi
            if [ "${_hq_ag_ae[idx]}" -lt "$pos" ]; then found=1; fi
          fi
          idx=$((idx + 1))
        done
        if [ "$found" = 0 ]; then _hq_ag_reason="a computed command name is not set to a literal in this command"; return 1; fi
      else
        case "$word" in
          *$'\001'* | *'$'* | *'`'* | *'*'* | *'?'* | *'['* | *'{'*)
            _hq_ag_reason="an unclassified expansion supplies the command name and could hide arithmetic evaluation"; return 1 ;;
        esac
      fi
      head=0
    done
    [ "$restart_case" = 0 ] || continue
    if [ "$case_depth" -gt 0 ]; then
      case "${text:stop:2}" in ';;' | ';&') case_pattern=1 ;; esac
      [ "${text:stop:1}" != ')' ] || case_pattern=0
    fi
    start=$((stop + 1))
  done
  if [ "$case_depth" -ne 0 ]; then _hq_ag_reason="case command boundaries could not be classified"; return 1; fi
  # Substitutions in arguments are code too; arithmetic expansions themselves
  # are handled by the expression checker.
  j=0
  while :; do
    rest="${text:j}"
    case "$rest" in *'$('* ) ;; *) break ;; esac
    pre="${rest%%'$('*}"; at=$((j + ${#pre}))
    if [ "${text:at+2:1}" != '(' ]; then
      _hq_ag_close "$text" $((at + 2)) '(' ')' || return 1
      inner="${text:at+2:_hq_ag_m-at-2}"
      _hq_ag_heads "$inner" $((base + at + 2)) $((depth + 1)) || return 1
    fi
    j=$((at + 2))
  done
  j=0
  while :; do
    rest="${text:j}"
    case "$rest" in *'`'*) ;; *) break ;; esac
    pre="${rest%%\`*}"; at=$((j + ${#pre}))
    rest="${text:at+1}"; inner="${rest%%\`*}"
    _hq_ag_heads "$inner" $((base + at + 1)) $((depth + 1)) || return 1
    j=$((at + ${#inner} + 2))
  done
  return 0
}

hq_arith_guard_check() {
  HQ_ARITH_GUARD_REASON=""
  local cmd="${1:-}"
  # These literal command heads do not evaluate Bash arithmetic arguments.
  # With no expansion, redirection, separator or escape, quoting their data
  # cannot introduce a second shell command. Keep large data arguments cheap.
  # pytho[n] is written as a bracket so the hooks-no-python tripwire, which
  # looks for runtime interpreter calls, does not read this list as one.
  local data_head_re='^[[:space:]]*(echo|pytho[n]3|pytho[n]|node|ruby|perl)[[:space:]]'
  case "$cmd" in
    *'$'* | *'`'* | *'\'* | *';'* | *'&'* | *'|'* | *'<'* | *'>'* | *$'\n'*) ;;
    *) [[ "$cmd" =~ $data_head_re ]] && return 0 ;;
  esac
  # Nothing that can make an arithmetic or subscript context.
  case "$cmd" in
    *'(('* | *'$['* | *'['* | *'${'* | *let* | *read* | *printf* | *unset* | *mapfile* | *getopts* \
      | *declare* | *typeset* | *local* | *export* | *readonly* | *wait* | *test* | *select* \
      | *'\'* | *'"'* | *"'"* | *'$'* | *'`'* | *'{'* | *'*'* | *'?'*) ;;
    *) return 0 ;;
  esac
  local LC_ALL=C
  local _hq_ag_V="" _hq_ag_m=0 _hq_ag_ansi=0 _hq_ag_he=0 _hq_ag_hs=0 _hq_ag_tn="" _hq_ag_kind=""
  local _hq_ag_mode=collect _hq_ag_reason="" _hq_ag_nw=0 _hq_ag_nfl=0 _hq_ag_nfr=0
  local _hq_ag_qpos=" " _hq_ag_assoc=" " _hq_ag_int=" " _hq_ag_nref=" " _hq_ag_uncertain_flow=0 _hq_ag_reentry=0 _hq_ag_case_context=0
  local _hq_ag_nb=0 _hq_ag_nc=0 _hq_ag_na=0 _hq_ag_start=0 _hq_ag_proof=0 _hq_ag_nr=0 _hq_ag_nar=0 k nm
  local -a _hq_ag_rs=() _hq_ag_re=() _hq_ag_ars=() _hq_ag_are=()
  local -a _hq_ag_w=() _hq_ag_wp=() _hq_ag_fl=() _hq_ag_forraw=() _hq_ag_forpos=() _hq_ag_forend=() _hq_ag_forlist=()
  local -a _hq_ag_bn=() _hq_ag_bk=() _hq_ag_bp=() _hq_ag_be=()
  local -a _hq_ag_ck=() _hq_ag_ct=() _hq_ag_cp=() _hq_ag_cn=()
  local -a _hq_ag_an=() _hq_ag_as=() _hq_ag_ah=() _hq_ag_av=() _hq_ag_aa=() _hq_ag_ap=() _hq_ag_ae=() _hq_ag_ao=() _hq_ag_aproof=()
  local _hq_ag_rname=""

  if ! _hq_ag_lex "$cmd" 0; then
    HQ_ARITH_GUARD_REASON="the command's quoting or heredocs could not be followed far enough to check its arithmetic"
    return 1
  fi
  if _hq_ag_needs_reentry; then
    if [ "${#cmd}" -gt 16384 ]; then
      HQ_ARITH_GUARD_REASON="the shell-evaluating command is too long to check for arithmetic on unchecked values"
      return 1
    fi
    _hq_ag_reentry=1
    _hq_ag_uncertain_flow=1
    if ! _hq_ag_lex "$cmd" 1; then
      HQ_ARITH_GUARD_REASON="the command's quoting or heredocs could not be followed far enough to check its arithmetic"
      return 1
    fi
    if [ "$_hq_ag_ansi" = 1 ]; then
      HQ_ARITH_GUARD_REASON="a \$'...' string with escapes is passed to something that runs it as shell code"
      return 1
    fi
  fi
  _hq_ag_regions
  if ! _hq_ag_collect || ! _hq_ag_build; then
    HQ_ARITH_GUARD_REASON="$_hq_ag_reason"
    return 1
  fi
  # Separate or unclassified shell scopes still cannot establish proofs.
  # Supported same-shell branches/loops use the proof lifetimes above.
  local flow_re='(^|[[:space:];&|])(case|function|select)([[:space:];(]|$)|(^|[[:space:];&|])\{([[:space:];]|$)|(^|[^$=(])\([^()]|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)|\$\([^()][^)]*='
  if [[ "$_hq_ag_V" =~ $flow_re ]]; then _hq_ag_uncertain_flow=1; fi
  if ! _hq_ag_heads "$_hq_ag_V" 0; then
    HQ_ARITH_GUARD_REASON="${_hq_ag_reason:-a command name could not be classified}"
    return 1
  fi
  _hq_ag_mode=collect
  _hq_ag_run_ctx
  _hq_ag_mode=check
  if ! _hq_ag_run_ctx; then
    HQ_ARITH_GUARD_REASON="${_hq_ag_reason:-a value used as a number could not be checked}"
    return 1
  fi
  # Integer variables evaluate every value given to them, and namerefs
  # resolve to whatever name they were given: neither may take a value from
  # read, mapfile, printf -v, getopts or similar.
  for nm in $_hq_ag_int $_hq_ag_nref; do
    k=0
    while [ "$k" -lt "$_hq_ag_nb" ]; do
      if [ "${_hq_ag_bn[k]}" = "$nm" ] && [ "${_hq_ag_bk[k]}" = U ]; then
        HQ_ARITH_GUARD_REASON="\$$nm is an integer or nameref variable that is given a value this command does not show"
        return 1
      fi
      k=$((k + 1))
    done
  done
  return 0
}
