#!/bin/bash
# PreToolUse hook: block reads of credential files.
#
# Registration: hook-registry.json PreToolUse matchers "Read" and "Bash"
# (dispatched by master-hook.sh, the only command in .claude/settings.json).
# The registry entry sets "fail_closed": true, so a timeout of this hook
# blocks the call instead of letting it run unchecked.
#
# Covered files (any directory, case-insensitive):
#   .npmrc .netrc _netrc .pypirc .yarnrc .yarnrc.yml .git-credentials
#   .gem/credentials .docker/config.json .config/gh/hosts.yml|hosts.yaml
#   anything under .aws/   (credentials, config, sso cache)
#   anything under .ssh/   except *.pub, known_hosts*, config, authorized_keys*
#                          and backups of those (config.bak)
#   id_rsa id_dsa id_ecdsa id_ed25519 *_sk (private keys, anywhere)
#   .env .env.* .envrc *.env
#     allowed: .env.example .env.sample .env.template .env.schema .env.dist,
#     .env.<name>.example|sample|template, *.d.ts and *.md
#   backup and editor copies of all of the above: name~ name.bak name.orig
#   name.old name.swp name.swo name.save name.tmp name.N name.bak.* and the
#   vim swap form .name.swp
#
# Read tool: .tool_input.file_path is normalized (~, $HOME, ${HOME},
# relative to the payload cwd, `.`/`..`) and symlinks are resolved.
#
# Bash: the command is tokenized (quotes, escapes, $(...), backticks, <(...),
# heredocs, redirects) and each simple command is checked. Deny by default:
# every operand of every command is checked, including option values
# (--opt=path, -opath, and the word after an option that takes a value, so
# a flag that takes no value on another platform cannot hide the file),
# file:// URLs, @file arguments and commands whose name
# is held in a variable or substitution. Existing operands are resolved
# through symlinks before the fast path exits. Only these commands may name a
# credential file:
#   ls stat test [ [[ chmod chown chgrp touch rm rmdir mkdir unlink wc file du
#   echo printf true false realpath readlink basename dirname tee ssh
#   ssh-add, the shell builtins pwd read mapfile readarray exit return unset
#   set shift trap wait sleep type which hash kill break continue :,
#   ssh-keygen without -i, ln -s, and git status / add / rm / commit /
#   check-ignore / check-attr / ls-files (add without -p / -i / -e).
# mv, gmv, git mv and ln without -s (a hard link) may move a credential file
# only to a name the guard still covers (mv ~/.ssh/id_rsa backup/ keeps
# id_rsa); a rename to an uncovered name (mv ~/.ssh/deploy_key /tmp/k) would
# let a later read of the new name through, so it is blocked (DEV-5254).
# Identity files: scp and sftp -i <key> and -o IdentityFile=<key>, and rsync
# -e / --rsh "ssh -i <key>", are allowed like ssh -i. ssh reads the key to
# authenticate and never prints it. rsync's remote-shell command is checked
# as a command of its own, and every other operand keeps the usual checks.
# Interpreters (python, node, deno, bun, perl, ruby, php, lua, osascript, ...)
# and shells reading stdin are also blocked when their code (-c / -e text,
# arguments, heredoc or here-string bodies, or text piped in from the same
# pipeline) names a credential file. awk programs that use getline or system
# get the same check.
# Path forms: ~, ~user, $HOME, ${HOME}, absolute, relative to the cwd (cd and
# pushd are followed), quoted, after `--`, brace expansion, globs, variables
# assigned in the same command.
#
# Allowed on credential files (no contents reach the transcript):
#   grep -c / -l / -L / -q, rg --files, the safe commands above,
#   sed -i '/pattern/d' with no backup suffix (in-place delete).
# Blocked writes: sed -i<suffix> on a credential file, and cp / install /
# rsync / scp / mv onto a credential name (cp of an allowed .env template
# such as .env.example onto .env is still allowed).
#
# Fails closed: unparsable payload or command, unterminated quote or
# substitution, nesting deeper than 6 levels, or jq missing -> block. When
# realpath is missing, any operand that passes through a symlink below the
# top level is blocked, since its target cannot be checked.
#
# Known limits (see the PR body): hard links to a credential file that already
# exist (Read and Bash; pinned by credential-read-guard.test.sh [10]; creating
# one with ln is blocked), paths computed at runtime without a credential word (for example
# string concatenation inside interpreter code, or a script file that opens
# the credential), a symlink created and read in the same command,
# and the Grep tool. redact-credential-output.sh is the backstop for output.
#
# Exit 2 + short plain stderr. The message names the path, never contents.

set -o pipefail

# Trailing newlines are trimmed with [[ $v == *$'\n' ]] and ${v%?}: the form
# [ "${v%$'\n'}" != "$v" ] costs seconds per test on a 100 KB value in
# bash 5 (a large heredoc), which pushed the hook past its timeout.
# Read stdin once without a subprocess. Same value as INPUT=$(cat): NUL
# bytes are dropped (the loop concatenates the NUL-separated chunks) and
# trailing newlines are removed.
INPUT=""
_cg_chunk=""
while IFS= read -r -d '' _cg_chunk; do INPUT="$INPUT$_cg_chunk"; done
INPUT="$INPUT$_cg_chunk"
while [[ "$INPUT" == *$'\n' ]]; do INPUT="${INPUT%?}"; done
unset _cg_chunk

block() { # <reason-line>
  local reason="$1"
  printf 'BLOCKED: %s\n\n' "$reason" >&2
  cat >&2 <<'EOF'
Credential files (.npmrc, .netrc, .pypirc, .yarnrc, .git-credentials,
.aws/, .ssh/ private keys, .docker/config.json, gh hosts.yml, .env) must not
be printed into the session.

Safe alternatives:
  test -f ~/.npmrc && echo exists
  grep -c registry ~/.npmrc
  grep -c '^SOME_KEY=' .env
  hq secrets exec -- <command>
EOF
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "BLOCKED: $reason" '{decision:"block",reason:$m}' || true
  fi
  exit 2
}

H="${HOME:-}"
[ -n "$H" ] || H="/nonexistent-home"
# Squeeze repeated slashes (TMPDIR ends in "/" on macOS) so HOME compares
# equal to normalized operand paths.
while case "$H" in *//*) true ;; *) false ;; esac; do H="${H%%//*}/${H#*//}"; done
[ "$H" = "/" ] || H="${H%/}"

# lc_word <word> -> LCW, the word in lower case. ${1,,} needs bash 4; with
# bash 3.2 (macOS /bin/bash), or for any character outside plain ASCII
# letters, digits and ._+@:/=,%~- , tr is used as before.
LCW=""
if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
  eval 'lc_word() {
    case "$1" in
      *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+@:/=,%~-]*)
        LCW="$(printf "%s" "$1" | tr "[:upper:]" "[:lower:]")" ;;
      *) LCW="${1,,}" ;;
    esac
  }'
else
  lc_word() { LCW="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; }
fi

# ---------------------------------------------------------------- paths

# Display form of a path: $HOME prefix shown as ~.
show_path() {
  case "$1" in
    "$H"/*) printf '~/%s' "${1#"$H"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# .env-class basename.
is_env_name() {
  local b="$1" r=1 nc=0
  # Save the caller's nocasematch so the prefilter's setting survives.
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  case "$b" in
    .env.example|.env.sample|.env.template|.env.schema|.env.dist|*.env.example|*.env.sample|*.env.template) r=1 ;;
    # Per-environment templates (.env.local.example), TypeScript declarations
    # (.env.d.ts) and docs (.env.md) hold no values.
    .env.*.example|.env.*.sample|.env.*.template|*.d.ts|*.md) r=1 ;;
    .env|.env.*|.envrc|*.env) r=0 ;;
  esac
  [ "$nc" -eq 1 ] || shopt -u nocasematch
  return $r
}

# strip_backup <basename> -> SB with backup and editor suffixes removed
# (name~ .bak .orig .old .swp .save .tmp .N .bak.N ...). SB_SWAP=1 when a vim
# swap suffix was removed, since vim also prepends a dot (.name.swp).
SB=""
SB_SWAP=0
strip_backup() {
  local b="$1" prev="" nc=0
  SB_SWAP=0
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  while [ "$b" != "$prev" ] && [ -n "$b" ]; do
    prev="$b"
    case "$b" in
      *'~') b="${b%'~'}" ;;
      *.swp|*.swo|*.swn|*.swx) b="${b%.*}"; SB_SWAP=1 ;;
      *.bak|*.orig|*.old|*.save|*.sav|*.tmp|*.backup|*.bk|*.prev|*.rej) b="${b%.*}" ;;
      *.bak.*|*.orig.*|*.old.*|*.save.*|*.backup.*|*.tmp.*) b="${b%.*}" ;;
      *)
        if [[ "$b" =~ ^(.+)\.[0-9]+$ ]]; then b="${BASH_REMATCH[1]}"; fi
        ;;
    esac
  done
  [ "$nc" -eq 1 ] || shopt -u nocasematch
  SB="$b"
}

# is_cred_path <normalized absolute path>: a credential file, or a backup or
# editor copy of one.
is_cred_path() {
  local p="$1" b dir
  b="${p##*/}"
  dir="${p%/*}"
  is_cred_name_at "$dir" "$b" && return 0
  strip_backup "$b"
  if [ -n "$SB" ] && [ "$SB" != "$b" ]; then
    is_cred_name_at "$dir" "$SB" && return 0
    if [ "$SB_SWAP" -eq 1 ] && [ "${SB#.}" != "$SB" ]; then
      is_cred_name_at "$dir" "${SB#.}" && return 0
    fi
  fi
  return 1
}

# is_cred_name_at <directory> <basename>
is_cred_name_at() {
  local p="$1/$2" b="$2" r=1 nc=0
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  case "$b" in
    .npmrc|.netrc|_netrc|.pypirc|.yarnrc|.yarnrc.yml|.yarnrc.yaml|.git-credentials) r=0 ;;
    *.pub) ;;
    id_rsa|id_dsa|id_ecdsa|id_ed25519|id_*_sk) r=0 ;;
  esac
  if [ $r -ne 0 ]; then
    case "$p" in
      */.gem/credentials|*/.docker/config.json|*/.config/gh/hosts.yml|*/.config/gh/hosts.yaml|*/.aws/*) r=0 ;;
      */.ssh/*)
        case "$b" in
          *.pub|known_hosts|known_hosts.*|known_hosts2|config|authorized_keys|authorized_keys2) ;;
          *)
            r=0
            # A backup of an allowed name (config.bak) is allowed too.
            strip_backup "$b"
            case "$SB" in
              *.pub|known_hosts|known_hosts2|config|authorized_keys|authorized_keys2) r=1 ;;
            esac
            ;;
        esac
        ;;
    esac
  fi
  [ "$nc" -eq 1 ] || shopt -u nocasematch
  if [ $r -ne 0 ] && is_env_name "$b"; then
    r=0
  fi
  return $r
}

# is_template_name <basename>: example files that are safe to copy onto a
# credential name (cp .env.example .env).
is_template_name() {
  local r=1 nc=0
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  case "$1" in
    *.example|*.sample|*.template|*.dist|*.schema) r=0 ;;
  esac
  [ "$nc" -eq 1 ] || shopt -u nocasematch
  return $r
}

# is_secret_dir <normalized absolute path>: a directory that holds only
# credentials. Any command other than the safe list may not take it.
is_secret_dir() {
  local r=1 nc=0
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  case "$1" in
    */.ssh|*/.aws|*/.docker|*/.gem|*/.config/gh) r=0 ;;
  esac
  [ "$nc" -eq 1 ] || shopt -u nocasematch
  return $r
}

# is_cred_dir <normalized absolute path>: HOME, an ancestor of HOME, or a
# directory that holds credentials. Recursive readers may not target these.
is_cred_dir() {
  local p="$1" r=1 nc=0
  [ "$p" = "/" ] && return 0
  [ "$p" = "$H" ] && return 0
  case "$H/" in "$p"/*) return 0 ;; esac
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  case "$p" in
    */.ssh|*/.ssh/*|*/.aws|*/.aws/*|*/.docker|*/.docker/*|*/.gem|*/.gem/*|*/.config|*/.config/gh|*/.config/gh/*) r=0 ;;
  esac
  [ "$nc" -eq 1 ] || shopt -u nocasematch
  return $r
}

# norm_path <path> <cwd> -> NP (absolute, lexical . / .. / // cleanup).
NP=""
norm_path() {
  local p="$1" cwd="$2" u rest
  case "$p" in
    "~") p="$H" ;;
    "~/"*) p="$H/${p#"~/"}" ;;
    "~"*)
      u="${p#"~"}"; u="${u%%/*}"; rest="${p#"~$u"}"
      p="${H%/*}/$u$rest"
      ;;
  esac
  p="${p//\$\{HOME\}/$H}"
  p="${p//\$HOME/$H}"
  case "$p" in
    /*) ;;
    *) p="$cwd/$p" ;;
  esac
  local seg out=() rest_p="$p/"
  while [ -n "$rest_p" ]; do
    seg="${rest_p%%/*}"
    rest_p="${rest_p#*/}"
    case "$seg" in
      ''|.) ;;
      ..) [ ${#out[@]} -gt 0 ] && unset "out[$((${#out[@]} - 1))]" ;;
      *) out+=("$seg") ;;
    esac
  done
  if [ ${#out[@]} -eq 0 ]; then
    NP="/"
  else
    local IFS=/
    NP="/${out[*]}"
  fi
}


# ---------------------------------------------------------------- fast path
#
# Most calls name no credential file. This block decides those calls with
# bash builtins only (no subprocess), before jq runs. It allows a call only
# when the full check below would also allow it; anything unexpected returns
# 1 and the full check runs. Set HQ_CRED_GUARD_FASTPATH=0 to skip it (the
# tests compare both paths).
#
# Conditions for the fast exit, all required:
#   - jq and realpath are installed (the full check blocks without jq and
#     cannot take its own fast exit without realpath);
#   - the payload is at most 16 KiB of printable ASCII (plus tab, CR, LF);
#   - the payload with quotes and backslashes removed contains none of the
#     credential words in CG_SCREEN_RE (CRED_WORD_RE plus the path words of
#     the prefilter), so \u escapes, split words and case variants fall
#     through;
#   - it parses as exactly one strict JSON object with no \u escapes, and
#     tool_name, cwd, tool_input.command and tool_input.file_path, when
#     present, are strings that occur once (tool_input must be an object);
#   - Bash: the command has no $(...) or backtick substitution (the full
#     check analyzes those as computed paths), the full check's own
#     prefilter (PREFILTER_RE on the command with
#     quotes and backslashes removed) does not match, the cwd is not a
#     credential directory, and no word of the command is an existing
#     symlink or an existing path two levels below the cwd (the full check
#     resolves those with realpath; here they fall through);
#   - Read: the path has no ~ after normalization, is not a credential path,
#     and no component of it is a symlink, so realpath would return it
#     unchanged.

CRED_WORD_RE='npmrc|netrc|pypirc|yarnrc|git-credentials|\.gem|\.docker|\.aws|\.ssh|id_(rsa|dsa|ecdsa|ed25519)|gh/hosts|\.env|credentials'
# Also wake for home references and recursive readers: `grep -r token ~`
# reaches credential files without naming one.
PREFILTER_RE="${CRED_WORD_RE}|identity|config\\.json|hosts\\.y|(^|[^a-z])(cd|pushd)([^a-z]|$)|[*?[{]|~|home|(^|[^a-z])(rg|ag|ack|rsync|scp)([^a-z]|$)|(^|[[:space:]])-[A-Za-z]*r|--recursive|--archive"
CG_SCREEN_RE="${CRED_WORD_RE}|identity|config\\.json|hosts\\.y"

# cg_unescape <json string body> [key] -> CG_U (decoded; for values, trailing
# newlines are then removed as command substitution of `jq -r` would; keys
# are kept exact).
CG_U=""
cg_unescape() {
  local b="$1" out="" pre c
  while :; do
    case "$b" in *\\*) ;; *) break ;; esac
    pre="${b%%\\*}"
    b="${b#*\\}"
    c="${b:0:1}"
    b="${b:1}"
    case "$c" in
      n) c=$'\n' ;;
      t) c=$'\t' ;;
      r) c=$'\r' ;;
      b) c=$'\b' ;;
      f) c=$'\f' ;;
    esac
    out="$out$pre$c"
  done
  out="$out$b"
  if [ "${2:-}" != "key" ]; then
    while [[ "$out" == *$'\n' ]]; do out="${out%?}"; done
  fi
  CG_U="$out"
}

# cg_parse <json>: strict JSON object parser. Sets CG_TOOL CG_CWD CG_CMD
# CG_FILE (and CG_HAVE_* flags). Returns 1 on anything it does not accept.
cg_parse() {
  local s="$1" stack="" expect="v" key="" k1="" c kind body
  local re_ws=$'^[ \t\n\r]+'
  # Any character except quote, backslash and raw tab/CR/LF (the input is
  # already printable ASCII), or a short escape. No ranges: same in every
  # locale.
  local re_str='^"(([^"\'$'\t\r\n'']|\\["\\/bfnrt])*)"'
  local re_num='^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?'
  local re_lit='^(true|false|null)'
  CG_TOOL="" CG_CWD="" CG_CMD="" CG_FILE=""
  CG_HAVE_TOOL=0 CG_HAVE_CWD=0 CG_HAVE_CMD=0 CG_HAVE_FILE=0 CG_HAVE_TI=0
  while :; do
    if [[ "$s" =~ $re_ws ]]; then s="${s:${#BASH_REMATCH[0]}}"; fi
    [ -n "$s" ] || break
    [ "$expect" != "e" ] || return 1
    c="${s:0:1}"
    case "$expect" in
      k0|k)
        if [ "$c" = "}" ] && [ "$expect" = "k0" ]; then
          stack="${stack%o}"; s="${s:1}"
        else
          [[ "$s" =~ $re_str ]] || return 1
          body="${BASH_REMATCH[1]}"
          s="${s:${#BASH_REMATCH[0]}}"
          cg_unescape "$body" key
          key="$CG_U"
          [ ${#stack} -ne 1 ] || k1="$key"
          expect=":"
          continue
        fi
        ;;
      :)
        [ "$c" = ":" ] || return 1
        s="${s:1}"; expect="v"; continue
        ;;
      c)
        case "$c" in
          ,) s="${s:1}"
             case "$stack" in *o) expect="k" ;; *a) expect="v" ;; *) return 1 ;; esac
             continue ;;
          "}") [ "${stack%o}" != "$stack" ] || return 1; stack="${stack%o}"; s="${s:1}" ;;
          "]") [ "${stack%a}" != "$stack" ] || return 1; stack="${stack%a}"; s="${s:1}" ;;
          *) return 1 ;;
        esac
        ;;
      v|a0)
        if [ "$c" = "]" ] && [ "$expect" = "a0" ]; then
          stack="${stack%a}"; s="${s:1}"
        else
          case "$c" in
            "{") kind=o ;;
            "[") kind=a ;;
            '"') kind=s ;;
            *) kind=x ;;
          esac
          # The top level must be an object.
          if [ -z "$stack" ] && [ "$kind" != "o" ]; then return 1; fi
          # Watched fields: tool_input must be an object, the others strings,
          # and each may occur only once.
          if [ "$stack" = "o" ] && [ "$expect" = "v" ]; then
            case "$key" in
              tool_input) [ "$kind" = o ] && [ "$CG_HAVE_TI" -eq 0 ] || return 1; CG_HAVE_TI=1 ;;
              tool_name|cwd) [ "$kind" = s ] || return 1 ;;
            esac
          elif [ "$stack" = "oo" ] && [ "$k1" = "tool_input" ] && [ "$expect" = "v" ]; then
            case "$key" in
              command|file_path) [ "$kind" = s ] || return 1 ;;
            esac
          fi
          case "$kind" in
            o) stack="${stack}o"; s="${s:1}"; expect="k0"; continue ;;
            a) stack="${stack}a"; s="${s:1}"; expect="a0"; continue ;;
            s)
              [[ "$s" =~ $re_str ]] || return 1
              body="${BASH_REMATCH[1]}"
              s="${s:${#BASH_REMATCH[0]}}"
              if [ "$stack" = "o" ] && [ "$expect" = "v" ]; then
                case "$key" in
                  tool_name) [ "$CG_HAVE_TOOL" -eq 0 ] || return 1; CG_HAVE_TOOL=1; cg_unescape "$body"; CG_TOOL="$CG_U" ;;
                  cwd) [ "$CG_HAVE_CWD" -eq 0 ] || return 1; CG_HAVE_CWD=1; cg_unescape "$body"; CG_CWD="$CG_U" ;;
                esac
              elif [ "$stack" = "oo" ] && [ "$k1" = "tool_input" ] && [ "$expect" = "v" ]; then
                case "$key" in
                  command) [ "$CG_HAVE_CMD" -eq 0 ] || return 1; CG_HAVE_CMD=1; cg_unescape "$body"; CG_CMD="$CG_U" ;;
                  file_path) [ "$CG_HAVE_FILE" -eq 0 ] || return 1; CG_HAVE_FILE=1; cg_unescape "$body"; CG_FILE="$CG_U" ;;
                esac
              fi
              ;;
            x)
              if [[ "$s" =~ $re_lit ]] || [[ "$s" =~ $re_num ]]; then
                s="${s:${#BASH_REMATCH[0]}}"
              else
                return 1
              fi
              ;;
          esac
        fi
        ;;
      *) return 1 ;;
    esac
    # A value (or a closed container) just ended.
    if [ -z "$stack" ]; then expect="e"; else expect="c"; fi
  done
  [ "$expect" = "e" ] || return 1
  # tool_input is required so that "no command" means the same as in jq.
  [ "$CG_HAVE_TOOL" -eq 1 ] && [ "$CG_HAVE_TI" -eq 1 ] || return 1
  return 0
}

# cg_strip_q <s> -> CG_SQ: <s> with every " ' and \ removed. Same result as
# ${s//[\"\'\\]/}, which is quadratic in bash 3.2: split on those three
# characters and join the pieces with nothing between them.
CG_SQ=""
cg_strip_q() {
  local old_ifs="$IFS" parts
  IFS="\"'\\"
  set -f
  # shellcheck disable=SC2206
  parts=($1)
  set +f
  IFS=""
  CG_SQ="${parts[*]-}"
  IFS="$old_ifs"
}

# cg_nl3 <text>: CG_NL = text with every \003 turned into a newline. Same
# value as ${text//$'\003'/$'\n'}, which is quadratic in bash 3.2: a 2,000
# line heredoc body took over 100 s there and the hook timed out. Field
# splitting is linear; the trailing x keeps a final \003 from being dropped.
cg_nl3() {
  case "$1" in
    *$'\003'*) ;;
    *) CG_NL="$1"; return 0 ;;
  esac
  local old_ifs="$IFS" parts
  IFS=$'\003'
  set -f
  # shellcheck disable=SC2206
  parts=($1x)
  set +f
  IFS=$'\n'
  CG_NL="${parts[*]}"
  IFS="$old_ifs"
  CG_NL="${CG_NL%x}"
}

# cg_fast_scan: character checks and parse. The locale is never changed:
# assigning LC_ALL makes bash print a setlocale warning on stderr when the
# inherited locale is not installed, and this hook must stay silent. The
# allowed characters are listed one by one instead of as a range, so the
# check means the same in every locale.
cg_fast_scan() {
  # Printable ASCII, tab, CR and LF only.
  case "$INPUT" in
    *[!' !"#$%&'\''()*+,./01234:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~56789-'$'\t\r\n']*) return 1 ;;
  esac
  cg_strip_q "$INPUT" || return 1
  local raw="$CG_SQ"
  shopt -s nocasematch
  if [[ "$raw" =~ $CG_SCREEN_RE ]]; then shopt -u nocasematch; return 1; fi
  shopt -u nocasematch
  cg_parse "$INPUT"
}

# cg_fast_allow: return 0 when the call can be allowed without the full
# check.
cg_fast_allow() {
  [ "${HQ_CRED_GUARD_FASTPATH:-1}" != "0" ] || return 1
  # Every helper must be defined; a missing one would otherwise read as "no
  # match" and allow the call.
  declare -F cg_strip_q cg_unescape cg_parse cg_fast_scan norm_path is_cred_path is_cred_dir is_cred_name_at is_env_name strip_backup >/dev/null 2>&1 || return 1
  [ ${#INPUT} -le 16384 ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  command -v realpath >/dev/null 2>&1 || return 1
  cg_fast_scan || return 1
  shopt -u nocasematch
  local cwd="$CG_CWD"
  [ -n "$cwd" ] || cwd="$PWD"
  case "$CG_TOOL" in
    Bash)
      [ -n "$CG_CMD" ] || return 0
      # Same computed-path rule as the full check (COMPUTED_PATH): a $(...)
      # or backtick body can build a credential name from neutral text
      # (`cat "workspace/$(echo c)redlink"`), so it always gets the full
      # analysis. Without this the fast path allowed what the full check
      # blocks (scope-guard-hotfix-security.test.sh, 14 cases).
      case "$CG_CMD" in *'$('*|*'`'*) return 1 ;; esac
      cg_strip_q "$CG_CMD" || return 1
      local st="$CG_SQ"
      # Same cwd rule as the full check.
      local in_cred=0
      if is_cred_dir "$cwd" && [ "$cwd" != "/" ] && [ "$cwd" != "$H" ]; then in_cred=1; fi
      case "$H/" in "$cwd"/*) in_cred=0 ;; esac
      [ "$in_cred" -eq 0 ] || return 1
      shopt -s nocasematch
      if [[ "$st" =~ $PREFILTER_RE ]]; then shopt -u nocasematch; return 1; fi
      shopt -u nocasematch
      # Words that the full check would resolve with realpath: fall through.
      # Split on the same characters as the full check (empty words are
      # skipped there too). Field splitting, not ${st//[...]/}, which is
      # quadratic in bash 3.2.
      local lw old_ifs="$IFS"
      IFS=$' \t;|&()<>\n'
      set -f
      # shellcheck disable=SC2206
      local arr=($st)
      set +f
      IFS="$old_ifs"
      for lw in ${arr[@]+"${arr[@]}"}; do
        lw="${lw#@}"
        case "$lw" in file://*|FILE://*) lw="${lw#*://}" ;; *://*) continue ;; esac
        case "$lw" in *=*) lw="${lw#*=}" ;; esac
        [ -n "$lw" ] || continue
        case "$lw" in /*) ;; *) lw="$cwd/$lw" ;; esac
        if [ -L "$lw" ] || { [[ "$lw" == "$cwd"/*/* ]] && [ -e "$lw" ]; }; then
          return 1
        fi
      done
      return 0
      ;;
    Read)
      [ -n "$CG_FILE" ] || return 0
      norm_path "$CG_FILE" "$cwd"
      case "$NP" in *'~'*) return 1 ;; esac
      is_cred_path "$NP" && return 1
      local q="$NP"
      while [ -n "$q" ] && [ "$q" != "/" ]; do
        [ -L "$q" ] && return 1
        q="${q%/*}"
      done
      return 0
      ;;
  esac
  return 1
}

if cg_fast_allow; then
  exit 0
fi

# ---------------------------------------------------------------- full check

command -v jq >/dev/null 2>&1 || block "credential guard cannot parse the tool call (jq missing)"

# One jq call for every field. @sh quotes each value for eval; non-string
# values are rejected (the guard blocks), and more than one JSON document
# blocks. NUL bytes inside values are dropped by the command substitution,
# and trailing newlines are removed below, as with the old per-field
# TOOL=$(jq -r ...) calls.
CG_JQ='def s: if type == "string" then . else error("non-string field") end;
def norm: tostring | explode | map(select(. != 0)) | implode
  | until((endswith("\n") | not); .[:-1]);
[inputs] as $docs
| if ($docs | length) == 0 then "TOOL="
  elif ($docs | length) > 1 then error("more than one document")
  else $docs[0]
  | (if .tool_name == null or .tool_name == false then "" else (.tool_name | norm) end) as $t
  | if $t == "Read" then
      @sh "TOOL=Read PAYLOAD_CWD=\(.cwd // "" | s) VAL=\(.tool_input.file_path // "" | s)"
    elif $t == "Bash" then
      @sh "TOOL=Bash PAYLOAD_CWD=\(.cwd // "" | s) VAL=\(.tool_input.command // "" | s)"
    else "TOOL=" end
  end'
TOOL="" PAYLOAD_CWD="" VAL=""
CG_OUT=$(jq -nr "$CG_JQ" 2>/dev/null <<<"$INPUT") \
  || block "credential guard cannot parse the tool call"
eval "$CG_OUT" || block "credential guard cannot parse the tool call"
while [[ "$PAYLOAD_CWD" == *$'\n' ]]; do PAYLOAD_CWD="${PAYLOAD_CWD%?}"; done
while [[ "$VAL" == *$'\n' ]]; do VAL="${VAL%?}"; done

case "$TOOL" in
  Read|Bash) ;;
  *) exit 0 ;;
esac

[ -n "$PAYLOAD_CWD" ] || PAYLOAD_CWD="$PWD"

REALPATH_BIN=$(command -v realpath 2>/dev/null || true)

# link_in_path <normalized absolute path>: the path or one of its parent
# directories is a symlink. Used only when realpath is missing, so a link
# cannot be followed and the guard fails closed instead. Top-level system
# links (/tmp, /var, /etc on macOS) need root to create and are skipped.
link_in_path() {
  local q="$1"
  while [ -n "$q" ] && [ "$q" != "/" ] && [ "${q%/*}" != "" ]; do
    [ -L "$q" ] && return 0
    q="${q%/*}"
  done
  return 1
}

# check_abs <normalized absolute path>: block if it or its resolved target is
# a credential file.
check_abs() {
  local p="$1" rp
  if is_cred_path "$p"; then
    block "reading a credential file ($(show_path "$p"))"
  fi
  if [ -z "$REALPATH_BIN" ] && link_in_path "$p"; then
    block "cannot resolve a symlink without realpath ($(show_path "$p")); failing closed"
  fi
  if [ -n "$REALPATH_BIN" ] && [ -e "$p" ]; then
    rp=$("$REALPATH_BIN" "$p" 2>/dev/null) || rp=""
    if [ -n "$rp" ] && [ "$rp" != "$p" ] && is_cred_path "$rp"; then
      block "reading a credential file ($(show_path "$p") -> $(show_path "$rp"))"
    fi
  fi
}

# ---------------------------------------------------------------- Read tool

if [ "$TOOL" = "Read" ]; then
  FP="$VAL"
  [ -n "$FP" ] || exit 0
  norm_path "$FP" "$PAYLOAD_CWD"
  check_abs "$NP"
  exit 0
fi

# ---------------------------------------------------------------- Bash tool

CMD="$VAL"
[ -n "$CMD" ] || exit 0
# CRED_WORD_RE and PREFILTER_RE are defined above the fast path.

# Same value as ${CMD//[\"\'\\]/}, which is quadratic in bash 3.2 and took
# minutes on a large heredoc (the hook then timed out and failed closed).
cg_strip_q "$CMD"
STRIPPED="$CG_SQ"
# Computed neutral names can resolve to credential symlinks even when no
# credential word appears in the command. Analyze, never execute, the body.
COMPUTED_PATH=0
case "$CMD" in *'$('*|*'`'*) COMPUTED_PATH=1 ;; esac

# SAFE_TMP_VARS: names exempted as a fresh temp path. This is an allowlist; a
# name qualifies only when every condition holds:
#   - it is assigned exactly once, as N=$(mktemp) or N=$(mktemp -d) (the
#     substitution may be double-quoted), ending at the closing paren;
#   - every other mention of N is a plain read, $N or ${N};
#   - the command has no TMPDIR mention, no `..`, and none of the builtins
#     that can assign a variable by name or indirection (read, mapfile,
#     readarray, select, getopts, declare, typeset, local, export, eval, let,
#     source, printf -v, ((, $[, ${!).
# mktemp then prints a fresh path under the default temp directory, so "$N"/*
# is a project-neutral path and not a wildcard that could reach a credential.
SAFE_TMP_VARS=" "
if [[ "$CMD" == *mktemp* ]]; then
  _tmp_global_ok=1
  _tmp_deny_re='(^|[^A-Za-z0-9_])(read|mapfile|readarray|select|getopts|declare|typeset|local|export|eval|let|source)([^A-Za-z0-9_]|$)|TMPDIR|\.\.|\(\(|\$\[|\$\{!|printf.*[[:space:]]-[A-Za-z]*v'
  [[ "$CMD" =~ $_tmp_deny_re ]] && _tmp_global_ok=0
  _tmp_rest="$CMD"
  _tmp_safe_re='(^|[^A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)=("?)\$\(mktemp( +-d)?\)'
  while [ "$_tmp_global_ok" = 1 ] && [[ "$_tmp_rest" =~ $_tmp_safe_re ]]; do
    _tmp_name="${BASH_REMATCH[2]}"
    _tmp_rest="${_tmp_rest#*"${BASH_REMATCH[0]}"}"
    case "$SAFE_TMP_VARS" in *" $_tmp_name "*) continue ;; esac
    # Remove the one allowed assignment (exact text, followed by a separator
    # or the end) and then every plain read; any mention left over is a
    # disqualifying use.
    _tmp_assign_re="(^|[^A-Za-z0-9_])${_tmp_name}=(\\\$\\(mktemp( +-d)?\\)|\"\\\$\\(mktemp( +-d)?\\)\")([[:space:];&|)]|\$)"
    _tmp_scan="$CMD"
    _tmp_n=0
    while [[ "$_tmp_scan" =~ $_tmp_assign_re ]]; do
      _tmp_n=$((_tmp_n + 1))
      _tmp_scan="${_tmp_scan/"${BASH_REMATCH[0]}"/${BASH_REMATCH[1]} ${BASH_REMATCH[5]}}"
    done
    [ "$_tmp_n" -eq 1 ] || continue
    _tmp_read_re="\\\$(\\{${_tmp_name}\\}|${_tmp_name}([^A-Za-z0-9_]|\$))"
    while [[ "$_tmp_scan" =~ $_tmp_read_re ]]; do
      _tmp_tail="${BASH_REMATCH[3]}"
      _tmp_scan="${_tmp_scan/"${BASH_REMATCH[0]}"/ ${_tmp_tail}}"
    done
    # Any remaining occurrence of the name, even inside another word such as
    # -vN or R=N, disqualifies it.
    case "$_tmp_scan" in *"$_tmp_name"*) continue ;; esac
    SAFE_TMP_VARS="$SAFE_TMP_VARS$_tmp_name "
  done
fi
shopt -s nocasematch
CWD_IN_CRED=0
if is_cred_dir "$PAYLOAD_CWD" && [ "$PAYLOAD_CWD" != "/" ] && [ "$PAYLOAD_CWD" != "$H" ]; then
  CWD_IN_CRED=1
fi
case "$H/" in "$PAYLOAD_CWD"/*) CWD_IN_CRED=0 ;; esac
# A neutral name can be a link to a credential file (lnk -> ~/.npmrc) or a
# secret directory. Resolve every existing word in one realpath call before
# the fast path exits, so Bash agrees with the Read tool.
LINK_HIT=0
if [ -z "$REALPATH_BIN" ]; then
  # Without realpath a neutral name that links to a credential file cannot be
  # resolved, so the fast path is not taken: every operand goes through the
  # full analysis, and check_abs blocks an operand that passes through a link.
  LINK_HIT=1
fi
if [ "$CWD_IN_CRED" -eq 0 ] && ! [[ "$STRIPPED" =~ $PREFILTER_RE ]] && [ -n "$REALPATH_BIN" ]; then
  shopt -u nocasematch
  LINK_CANDS=()
  # Split on the same characters as ${STRIPPED//[$' \t;|&()<>']/$'\n'} plus
  # newline, by field splitting: the pattern substitution is quadratic in
  # bash 3.2. Empty words are skipped either way.
  _cg_old_ifs="$IFS"
  IFS=$' \t;|&()<>\n'
  set -f
  # shellcheck disable=SC2206
  _cg_words=($STRIPPED)
  set +f
  IFS="$_cg_old_ifs"
  for lw in ${_cg_words[@]+"${_cg_words[@]}"}; do
    lw="${lw#@}"
    case "$lw" in file://*|FILE://*) lw="${lw#*://}" ;; *://*) continue ;; esac
    case "$lw" in *=*) lw="${lw#*=}" ;; esac
    [ -n "$lw" ] || continue
    case "$lw" in /*) ;; *) lw="$PAYLOAD_CWD/$lw" ;; esac
    if [ -L "$lw" ] || { [[ "$lw" == "$PAYLOAD_CWD"/*/* ]] && [ -e "$lw" ]; }; then
      LINK_CANDS+=("$lw")
    fi
  done
  unset _cg_words _cg_old_ifs
  if [ ${#LINK_CANDS[@]} -gt 0 ]; then
    while IFS= read -r lr; do
      [ -n "$lr" ] || continue
      if is_cred_path "$lr" || is_secret_dir "$lr" || is_cred_dir "$lr"; then LINK_HIT=1; break; fi
    done < <("$REALPATH_BIN" -- "${LINK_CANDS[@]}" 2>/dev/null)
  fi
  shopt -s nocasematch
fi
if [ "$COMPUTED_PATH" -eq 0 ] && [ "$CWD_IN_CRED" -eq 0 ] && [ "$LINK_HIT" -eq 0 ] && ! [[ "$STRIPPED" =~ $PREFILTER_RE ]]; then
  shopt -u nocasematch
  exit 0
fi
# CRED_ANY: a credential word remains after removing allowed names. Unknown
# variables and substitutions are treated as wildcards only when it is set.
ALLOW_STRIPPED="$STRIPPED"
for allowed in .env.example .env.sample .env.template .env.schema .env.dist .pub; do
  ALLOW_STRIPPED="${ALLOW_STRIPPED//$allowed/}"
done
CRED_ANY=0
if [[ "$ALLOW_STRIPPED" =~ $CRED_WORD_RE ]] || [ "$CWD_IN_CRED" -eq 1 ] || [ "$LINK_HIT" -eq 1 ] || [ "$COMPUTED_PATH" -eq 1 ]; then
  CRED_ANY=1
fi
shopt -u nocasematch

# Tokenizer. Output: one token per line, 4 tab fields, each field prefixed
# (f flags, o operator, x text) so no field is empty.
#   W f<flags> o- x<text>        word. flags: g glob, b brace, v variable,
#                                s substitution (\001 in text), c the
#                                substitution mentions a credential word,
#                                q quoted
#   O f- o<op> x-                ; ;; & && | || |& ( ) NL
#   R f<flags> o<op> x<target>   redirect (< <> <& > >> >& >| &> &>> <<<)
#   S f- o- x<inner>             $(...), `...`, <(...), >(...) inner script
#   E f- o- x<message>           parse error -> block
# Newlines inside text are encoded as \003.
read -r -d '' AWK_PROG <<'AWK' || true
function enc(x) { gsub(/\n/, "\003", x); gsub(/\t/, " ", x); return x }
function credword(x,  y) {
  y = tolower(x)
  gsub(/["'\\]/, "", y)
  return (y ~ /npmrc|netrc|pypirc|yarnrc|git-credentials|\.gem|\.docker|\.aws|\.ssh|id_(rsa|dsa|ecdsa|ed25519)|gh\/hosts|\.env|credentials/)
}
function err(m) { print "E\tf-\to-\tx" m; failed = 1 }
function emit_s(inner, kind) {
  # kind: "w" for $(...) and backticks, "p" for <(...) and >(...). Both put
  # one \001 into the current word, in token order (see SUBQ in analyze_cmd).
  print "S\tf" kind "\to-\tx" enc(inner)
  w = w "\001"; ws = 1; fs_ = fs_ "s"
  if (credword(inner)) fs_ = fs_ "c"
}
function flushw(  d) {
  if (!ws) return
  if (rop != "") {
    if (rop == "<<" || rop == "<<-") {
      d = w
      nhd++; hd_delim[nhd] = d; hd_strip[nhd] = (rop == "<<-"); hd_quoted[nhd] = (fs_ ~ /q/)
      print "R\tf" fs_ "\to" rop "\tx" enc(w)
    } else {
      print "R\tf" fs_ "\to" rop "\tx" enc(w)
    }
    rop = ""
  } else {
    print "W\tf" fs_ "\to-\tx" enc(w)
  }
  w = ""; ws = 0; fs_ = ""
}
function op(o) {
  flushw()
  if (rop != "") { err("redirect without target"); rop = "" }
  print "O\tf-\to" o "\tx-"
}
function setredir(o) {
  if (ws && w ~ /^[0-9]+$/ && fs_ == "") { w = ""; ws = 0; fs_ = "" }
  flushw()
  if (rop != "") { err("redirect without target") }
  rop = o
}
# find_close(j): j is the index after "(" ; returns index of matching ")".
function find_close(j,  depth, c) {
  depth = 1
  while (j <= n) {
    c = a[j]
    if (c == "\\") { j += 2; continue }
    if (c == "'") { j++; while (j <= n && a[j] != "'") j++; if (j > n) return 0; j++; continue }
    if (c == "\"") {
      j++
      while (j <= n && a[j] != "\"") { if (a[j] == "\\") j++; j++ }
      if (j > n) return 0
      j++; continue
    }
    if (c == "`") { j = find_bt(j + 1); if (!j) return 0; j++; continue }
    if (c == "(") depth++
    else if (c == ")") { depth--; if (depth == 0) return j }
    j++
  }
  return 0
}
# find_bt(j): j is the index after the opening backtick.
function find_bt(j) {
  while (j <= n) {
    if (a[j] == "\\") { j += 2; continue }
    if (a[j] == "`") return j
    j++
  }
  return 0
}
function sub_dollar_paren(j,  k, inner) {
  # a[j] == "$", a[j+1] == "("
  k = find_close(j + 2)
  if (!k) { err("unterminated $("); return n + 1 }
  inner = substr(s, j + 2, k - j - 2)
  if (substr(inner, 1, 1) == "(") inner = substr(inner, 2, length(inner) - 2)
  emit_s(inner, "w")
  return k + 1
}
function sub_backtick(j,  k) {
  k = find_bt(j + 1)
  if (!k) { err("unterminated backtick"); return n + 1 }
  emit_s(substr(s, j + 1, k - j - 1), "w")
  return k + 1
}
# read_var(j): a[j] == "$"; appends the variable reference text; returns next index.
function read_var(j,  k, c) {
  c = a[j + 1]
  if (c == "{") {
    k = j + 2
    while (k <= n && a[k] != "}") k++
    if (k > n) { err("unterminated ${"); return n + 1 }
    w = w substr(s, j, k - j + 1); ws = 1; fs_ = fs_ "v"
    return k + 1
  }
  if (c ~ /[A-Za-z_]/) {
    k = j + 1
    while (k <= n && a[k] ~ /[A-Za-z0-9_]/) k++
    w = w substr(s, j, k - j); ws = 1; fs_ = fs_ "v"
    return k
  }
  if (c ~ /[0-9@*#?$!-]/) {
    w = w "$" c; ws = 1; fs_ = fs_ "v"
    return j + 2
  }
  w = w "$"; ws = 1
  return j + 1
}
function heredocs(i,  h, ls, le, line, k, c, body) {
  # i is the index of the newline that ends the command line. Each body is
  # emitted as an H token, in the same order as the << redirects.
  for (h = 1; h <= nhd; h++) {
    body = ""
    while (1) {
      ls = i + 1
      if (ls > n) { i = n; break }
      le = ls
      while (le <= n && a[le] != "\n") le++
      line = substr(s, ls, le - ls)
      if (hd_strip[h]) sub(/^\t+/, "", line)
      if (line == hd_delim[h]) { i = le; break }
      body = body line "\n"
      if (!hd_quoted[h]) {
        k = ls
        while (k < le) {
          c = a[k]
          if (c == "\\") { k += 2; continue }
          if (c == "$" && a[k + 1] == "(") {
            kk = find_close(k + 2)
            if (kk) { print "S\tf-\to-\tx" enc(substr(s, k + 2, kk - k - 2)); k = kk + 1; continue }
          }
          if (c == "`") {
            kk = find_bt(k + 1)
            if (kk) { print "S\tf-\to-\tx" enc(substr(s, k + 1, kk - k - 1)); k = kk + 1; continue }
          }
          k++
        }
      }
      i = le
      if (le > n) break
    }
    print "H\tf" (hd_quoted[h] ? "q" : "-") "\to-\tx" enc(body)
  }
  nhd = 0
  return i
}
{ s = (NR > 1) ? s "\n" $0 : $0 }
END {
  n = split(s, a, "")
  w = ""; ws = 0; fs_ = ""; rop = ""; nhd = 0; failed = 0
  i = 1
  while (i <= n && !failed) {
    c = a[i]
    if (c == " " || c == "\t") { flushw(); i++; continue }
    if (c == "\n") {
      flushw()
      if (rop != "") { err("redirect without target"); break }
      print "O\tf-\to" "NL" "\tx-"
      if (nhd > 0) i = heredocs(i)
      i++; continue
    }
    if (c == "#" && !ws) {
      while (i <= n && a[i] != "\n") i++
      continue
    }
    if (c == "'") {
      k = i + 1
      while (k <= n && a[k] != "'") k++
      if (k > n) { err("unterminated quote"); break }
      w = w substr(s, i + 1, k - i - 1); ws = 1; fs_ = fs_ "q"
      i = k + 1; continue
    }
    if (c == "\"") {
      ws = 1; fs_ = fs_ "q"; i++
      closed = 0
      while (i <= n) {
        c = a[i]
        if (c == "\"") { closed = 1; i++; break }
        if (c == "\\") {
          d = a[i + 1]
          if (d == "\n") { i += 2; continue }
          if (d == "$" || d == "`" || d == "\"" || d == "\\") { w = w d; i += 2; continue }
          w = w c; i++; continue
        }
        if (c == "$" && a[i + 1] == "(") { i = sub_dollar_paren(i); continue }
        if (c == "`") { i = sub_backtick(i); continue }
        if (c == "$") { i = read_var(i); continue }
        w = w c; i++
      }
      if (!closed && !failed) { err("unterminated quote") }
      continue
    }
    if (c == "\\") {
      d = a[i + 1]
      if (d == "\n") { i += 2; continue }
      if (i + 1 <= n) { w = w d; ws = 1; fs_ = fs_ "q" }
      i += 2; continue
    }
    if (c == "$") {
      d = a[i + 1]
      if (d == "(") { i = sub_dollar_paren(i); continue }
      if (d == "'") {
        k = i + 2; t = ""
        while (k <= n && a[k] != "'") {
          if (a[k] == "\\" && k + 1 <= n) {
            e = a[k + 1]
            if (e == "n") t = t "\n"; else if (e == "t") t = t "\t"; else t = t e
            k += 2; continue
          }
          t = t a[k]; k++
        }
        if (k > n) { err("unterminated quote"); break }
        w = w t; ws = 1; fs_ = fs_ "q"
        i = k + 1; continue
      }
      if (d == "\"") { i++; continue }
      i = read_var(i); continue
    }
    if (c == "`") { i = sub_backtick(i); continue }
    if ((c == "<" || c == ">") && a[i + 1] == "(") {
      k = find_close(i + 2)
      if (!k) { err("unterminated process substitution"); break }
      emit_s(substr(s, i + 2, k - i - 2), "p")
      i = k + 1; continue
    }
    if (c == "<") {
      if (a[i + 1] == "<" && a[i + 2] == "<") { setredir("<<<"); i += 3; continue }
      if (a[i + 1] == "<" && a[i + 2] == "-") { setredir("<<-"); i += 3; continue }
      if (a[i + 1] == "<") { setredir("<<"); i += 2; continue }
      if (a[i + 1] == ">") { setredir("<>"); i += 2; continue }
      if (a[i + 1] == "&") { setredir("<&"); i += 2; continue }
      setredir("<"); i++; continue
    }
    if (c == ">") {
      if (a[i + 1] == ">") { setredir(">>"); i += 2; continue }
      if (a[i + 1] == "&") { setredir(">&"); i += 2; continue }
      if (a[i + 1] == "|") { setredir(">|"); i += 2; continue }
      setredir(">"); i++; continue
    }
    if (c == "&") {
      if (a[i + 1] == "&") { op("&&"); i += 2; continue }
      if (a[i + 1] == ">" && a[i + 2] == ">") { flushw(); setredir("&>>"); i += 3; continue }
      if (a[i + 1] == ">") { flushw(); setredir("&>"); i += 2; continue }
      op("&"); i++; continue
    }
    if (c == "|") {
      if (a[i + 1] == "|") { op("||"); i += 2; continue }
      if (a[i + 1] == "&") { op("|&"); i += 2; continue }
      op("|"); i++; continue
    }
    if (c == ";") {
      if (a[i + 1] == ";") { op(";;"); i += 2; continue }
      op(";"); i++; continue
    }
    if (c == "(" || c == ")") { op(c); i++; continue }
    if (c == "*" || c == "?" || c == "[") { fs_ = fs_ "g" }
    if (c == "{") { fs_ = fs_ "b" }
    w = w c; ws = 1; i++
  }
  if (!failed) {
    flushw()
    if (rop != "") err("redirect without target")
  }
}
AWK

# Variables assigned earlier in the same command (NAME=value, export NAME=value).
VAR_NAMES=()
VAR_VALS=()

set_var() { # <name> <value>
  local i
  # A bare mktemp substitution (see SAFE_TMP_VARS) is a fresh temp path, not
  # an unknown wildcard.
  if [ "$2" = $'\001' ]; then
    case "$SAFE_TMP_VARS" in *" $1 "*) set -- "$1" "/tmp/hq-mktemp-$1" ;; esac
  fi
  for ((i = 0; i < ${#VAR_NAMES[@]}; i++)); do
    if [ "${VAR_NAMES[$i]}" = "$1" ]; then VAR_VALS[$i]="$2"; return; fi
  done
  VAR_NAMES+=("$1")
  VAR_VALS+=("$2")
}

# expand_vars <text> -> EV. HOME and known variables are substituted. Other
# references become \001 (wildcard) when the command mentions a credential
# word, and stay literal otherwise.
EV=""
expand_vars() {
  local t="$1" i m name
  t="${t//\$\{HOME\}/$H}"
  t="${t//\$HOME/$H}"
  for ((i = 0; i < ${#VAR_NAMES[@]}; i++)); do
    name="${VAR_NAMES[$i]}"
    t="${t//\$\{$name\}/${VAR_VALS[$i]}}"
    t="${t//\$$name/${VAR_VALS[$i]}}"
  done
  if [ "$CRED_ANY" -eq 1 ]; then
    local re='\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@*#?$!-]'
    local guard=0
    while [[ "$t" =~ $re ]] && [ $guard -lt 64 ]; do
      m="${BASH_REMATCH[0]}"
      t="${t/"$m"/$'\001'}"
      guard=$((guard + 1))
    done
  fi
  EV="$t"
}

# expand_braces <text> -> BR array (max 64 results).
BR=()
expand_braces() {
  local work=("$1") out=() cur pre post body alt rest close_i open_i k ch depth parts
  local guard=0
  while [ ${#work[@]} -gt 0 ] && [ $guard -lt 256 ]; do
    guard=$((guard + 1))
    cur="${work[0]}"
    work=("${work[@]:1}")
    # innermost: first "}" and the nearest "{" before it.
    rest="${cur%%\}*}"
    if [ "$rest" = "$cur" ]; then out+=("$cur"); continue; fi
    pre="${rest%\{*}"
    if [ "$pre" = "$rest" ]; then
      # "}" without "{": protect it and continue.
      work=("${rest}"$'\006'"${cur#*\}}" ${work[@]+"${work[@]}"})
      continue
    fi
    body="${rest##*\{}"
    post="${cur#*\}}"
    if [[ "$body" == *,* ]]; then
      local alts=() a2="$body,"
      while [ -n "$a2" ]; do
        alts+=("${a2%%,*}")
        a2="${a2#*,}"
      done
      for alt in "${alts[@]}"; do
        work+=("$pre$alt$post")
      done
    elif [[ "$body" =~ ^(-?[0-9]+)\.\.(-?[0-9]+)$ ]]; then
      local from="${BASH_REMATCH[1]}" to="${BASH_REMATCH[2]}" step=1 cnt=0
      [ "$from" -le "$to" ] || step=-1
      k=$from
      while [ $cnt -lt 64 ]; do
        work+=("$pre$k$post"); cnt=$((cnt + 1))
        [ "$k" -eq "$to" ] && break
        k=$((k + step))
      done
    elif [[ "$body" =~ ^([A-Za-z])\.\.([A-Za-z])$ ]]; then
      # Letter ranges: approximate with a wildcard character.
      work+=("$pre?$post")
    else
      work+=("$pre"$'\005'"$body"$'\006'"$post")
    fi
    if [ $((${#out[@]} + ${#work[@]})) -gt 64 ]; then break; fi
  done
  BR=()
  for cur in ${out[@]+"${out[@]}"} ${work[@]+"${work[@]}"}; do
    cur="${cur//$'\005'/\{}"
    cur="${cur//$'\006'/\}}"
    BR+=("$cur")
  done
}

CRED_TAILS=(.npmrc .netrc _netrc .pypirc .yarnrc .yarnrc.yml .git-credentials
  .gem/credentials .docker/config.json .config/gh/hosts.yml .aws/credentials
  .aws/config .ssh/id_rsa .ssh/id_dsa .ssh/id_ecdsa .ssh/id_ed25519)
CRED_BASENAMES=(.npmrc .netrc _netrc .pypirc .yarnrc .yarnrc.yml .git-credentials
  credentials config.json hosts.yml id_rsa id_dsa id_ecdsa id_ed25519 identity
  .env .env.local .env.production .envrc)

# check_pattern <absolute pattern with * wildcards> <basename-from-cred-subst 0|1> [<dot-wild 0|1>]
# A `*` or `?` that opens a path segment does not match a leading dot in
# bash or zsh (no dotglob), so `.github/workflows/*.yml` cannot name
# `.yarnrc.yml` (feedback b625002d). The third argument is 1 when the
# wildcards stand for a variable or substitution the guard cannot read;
# those can expand to any name and keep matching a dot (the default here).
check_pattern() {
  local pat="$1" dotwild="${3:-1}" concrete="${4:-0}" cand dir base t
  # The command can turn dot matching on (`shopt -s dotglob`, `bash -O
  # dotglob`, zsh `setopt GLOB_DOTS`, a GLOBIGNORE assignment, which also
  # sets dotglob); any mention keeps the wildcard matching a dot (review C2).
  case "$STRIPPED" in
    *dotglob*|*DOTGLOB*|*GLOB_DOTS*|*glob_dots*|*globdots*|*GLOBDOTS*|*GLOBIGNORE*|*globignore*|*setopt*|*shopt*|*"zsh -4"*) dotwild=1 ;;
  esac
  # A wildcard aimed straight at $HOME or a credential directory keeps
  # matching dot files, whatever the shell would expand: the home-dir
  # star and question-mark forms stay blocked. Only project trees get the
  # no-dot reading.
  dir="${pat%/*}"
  case "$dir" in
    *'*'*|*'?'*|*'['*) ;;
    *) if [ "$dir" = "$H" ] || is_cred_dir "$dir"; then dotwild=1; fi ;;
  esac
  if [ "$dotwild" -ne 1 ]; then
    pat="$(printf '%s' "$pat" | sed -e 's#/\*#/[!.]*#g' -e 's#/?#/[!.]#g' -e 's#^\*#[!.]*#' -e 's#^?#[!.]#')"
  fi
  for t in "${CRED_TAILS[@]}"; do
    cand="$H/$t"
    # shellcheck disable=SC2053 # pattern match is intended.
    if [[ "$cand" == $pat ]]; then block "reading a credential file ($(show_path "$cand") matches pattern $(show_path "$pat"))"; fi
  done
  dir="${pat%/*}"
  base="${pat##*/}"
  case "$dir" in
    *'*'*|*'?'*|*'['*) ;;
    *)
      # concrete=1: the caller expands this literal glob and checks every
      # real match, so a credential name that is not there cannot be read.
      # That only holds when nothing in the command can create a file first
      # (SUBST_IMPURE=0) and the directory is not HOME or a credential
      # directory (feedback_0ae14829: `cat dir/*` in a project tree).
      # prescan normally runs only for commands with a substitution; run it
      # here too so a write anywhere in the command is seen.
      if [ "$concrete" -eq 1 ] && [ "${PRESCAN_DONE:-0}" -ne 1 ]; then
        prescan "$CMD" 0
        PRESCAN_DONE=1
      fi
      if [ "$concrete" -ne 1 ] || [ "$SUBST_IMPURE" -ne 0 ] || [ "$dir" = "$H" ] || is_cred_dir "$dir"; then
        for t in "${CRED_BASENAMES[@]}"; do
          cand="$dir/$t"
          if [[ "$cand" == $pat ]] && is_cred_path "$cand"; then
            block "reading a credential file ($(show_path "$cand") matches pattern $(show_path "$pat"))"
          fi
        done
      fi
      if is_cred_dir "$dir" && [ "$dir" != "$H" ] && [ "$dir" != "/" ]; then
        case "$H/" in "$dir"/*) ;; *)
          case "$base" in *.pub) ;; *) block "reading a credential directory with a wildcard ($(show_path "$pat"))" ;; esac
        ;; esac
      fi
      ;;
  esac
}

# prescan <text> <depth>: one pass over the whole command, nested scripts
# included, before any check. eval_subst reads files at check time, so it
# must know whether anything in the command can change them first:
# SUBST_IMPURE=1 when a command outside a small read-only set runs anywhere,
# or a write goes to a target the guard cannot name; SUBST_WRITES holds the
# basenames of named write targets.
SUBST_IMPURE=0
SUBST_WRITES=" "
# 1 when the command changes directory anywhere. The guard does not model
# subshells, pipelines, & or && / || branches, so it cannot know which
# directory a substitution runs in.
SUBST_CD=0
prescan() {
  local text="$1" depth="$2" toks t fl op tx first=1 name="" sub=""
  [ "$depth" -le 6 ] || { SUBST_IMPURE=1; return; }
  toks=$(printf '%s' "$text" | LC_ALL=C awk "$AWK_PROG") || { SUBST_IMPURE=1; return; }
  while IFS=$'\t' read -r t fl op tx; do
    fl="${fl#f}"; op="${op#o}"; tx="${tx#x}"
    case "$t" in
      E) SUBST_IMPURE=1 ;;
      S) cg_nl3 "$tx"; prescan "$CG_NL" $((depth + 1)) ;;
      O) first=1; name="" ;;
      R)
        case "$op" in
          '>'|'>>'|'>|'|'&>'|'&>>'|'<>')
            case "$tx" in
              /dev/null|/dev/stderr|/dev/stdout) ;;
              *[\$\`$'\001']*|'') SUBST_IMPURE=1 ;;
              # Any named write can reach the file through a link, so it counts
              # as a change too (SUBST_WRITES is kept for the messages).
              *) SUBST_WRITES="$SUBST_WRITES${tx##*/} "; SUBST_IMPURE=1 ;;
            esac
            ;;
          '>&') case "$tx" in [0-9]|-) ;; *) SUBST_IMPURE=1 ;; esac ;;
        esac
        ;;
      W)
        if [ "$first" -eq 1 ]; then
          case "$fl" in *s*|*v*) SUBST_IMPURE=1; first=0; continue ;; esac
          case "$tx" in
            [A-Za-z_]*=*) continue ;;
            if|then|else|elif|fi|do|done|while|until|'!'|'{'|'}'|time) continue ;;
          esac
          first=0
          name="${tx##*/}"
          case "$name" in cd|pushd|popd) SUBST_CD=1 ;; esac
          case "$name" in
            cat|head|tail|ls|grep|egrep|fgrep|wc|echo|printf|pwd|date|sort|cut|tr|test|'['|'[['|true|false|cd|basename|dirname|jq|stat|realpath|readlink|diff|cmp|column|nl|fold|expand|seq|mktemp) ;;
            git) sub=1 ;;
            *) SUBST_IMPURE=1 ;;
          esac
        elif [ "$name" = "git" ] && [ "$sub" = 1 ]; then
          sub=""
          # Other subcommands can run configured programs (diff drivers,
          # textconv, fsmonitor).
          case "$tx" in rev-parse) ;; *) SUBST_IMPURE=1 ;; esac
        else
          # An option that writes a file or runs a program, on any command.
          case "$tx" in --output*|--out-file*|--pre*|--exec*|--ext-diff*|--textconv*) SUBST_IMPURE=1 ;; esac
          case "$name" in
            # Short-option clusters: sort -uo FILE writes FILE.
            sort) case "$tx" in --*) SUBST_IMPURE=1 ;; -*o*|-*T*) SUBST_IMPURE=1 ;; esac ;;
            git) case "$tx" in --*) ;; -*o*|-*O*) SUBST_IMPURE=1 ;; esac ;;
          esac
        fi
        ;;
    esac
  done <<< "$toks"
}

# eval_subst <inner script> <cwd> -> SUBST_OUT, return 0 when the guard can
# compute what the substitution prints without running the payload
# (feedback 10e92984). Before this, every $(...) or backtick operand became a
# wildcard that matched home-dir dot files (pattern /*) or was blocked as
# unprovable, so `grep x $(cat list.txt)` and handoff reads were blocked.
# Only these inner forms are computed; everything else keeps the old
# fail-closed handling:
#   ls [-1|-d|-1d] ARG...       (ARG literal or glob; expanded here)
#   pwd | git rev-parse --show-toplevel | date [+FMT]
# optionally followed by `| head [-n N|-N]`, `| tail [-n N|-N]`, `| sort [-r|-u]`.
# The inner script has already been checked as a command of its own, so a
# credential FILE was blocked before this runs.
SUBST_OUT=""
CWD_UNCERTAIN=0
subst_count_opt() { # <word> [<next>] -> SC_N, SC_USED (1 or 2); 1 if not a count
  SC_USED=1
  case "$1" in
    -n) [[ "${2:-}" =~ ^[0-9]{1,6}$ ]] || return 1; SC_N="$2"; SC_USED=2 ;;
    -n[0-9]*) [[ "${1#-n}" =~ ^[0-9]{1,6}$ ]] || return 1; SC_N="${1#-n}" ;;
    -[0-9]*) [[ "${1#-}" =~ ^[0-9]{1,6}$ ]] || return 1; SC_N="${1#-}" ;;
    *) return 1 ;;
  esac
}
eval_subst() {
  # Anything outside the read-only set (eval, source, a program) can change
  # files or the directory first, so nothing is computed.
  [ "$SUBST_IMPURE" -eq 0 ] || return 1
  local CWD_UNCERTAIN="$CWD_UNCERTAIN"
  [ "$SUBST_CD" -eq 0 ] || CWD_UNCERTAIN=1
  case "$STRIPPED" in *CDPATH*|*cdpath*) CWD_UNCERTAIN=1 ;; esac
  local s="$1" cwd="$2" out="" w=() st i k n listed=0
  SUBST_OUT=""
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  case "$s" in
    ''|*[\$\`\;\&\(\)\<\>\\\"\'\{\}\#\!]*|*$'\n'*|*$'\r'*|*'||'*|*'|') return 1 ;;
  esac
  # A shell option can change how the substitution's globs expand.
  # IFS changes how the output splits into words.
  case "$STRIPPED" in *shopt*|*setopt*|*glob*|*GLOB*|*'set -'*|*'set +'*|*IFS*|*ifs*) return 1 ;; esac
  # A function or a PATH change can replace the command the guard models.
  case "$STRIPPED" in *'('*')'*'{'*|*function*|*PATH*|*path=*|*BASH_FUNC*|*enable*|*hash*) return 1 ;; esac
  local stages=() old_ifs="$IFS"
  IFS='|'
  read -r -a stages <<< "$s"
  IFS="$old_ifs"
  [ ${#stages[@]} -ge 1 ] && [ ${#stages[@]} -le 4 ] || return 1
  read -r -a w <<< "${stages[0]}"
  [ ${#w[@]} -ge 1 ] || return 1
  case "${w[0]}" in
    pwd)
      [ ${#w[@]} -eq 1 ] && [ "$CWD_UNCERTAIN" -eq 0 ] || return 1
      out="$cwd"
      ;;
    git)
      [ "${w[*]}" = "git rev-parse --show-toplevel" ] && [ "$CWD_UNCERTAIN" -eq 0 ] || return 1
      [ -z "${GIT_DIR:-}" ] && [ -z "${GIT_WORK_TREE:-}" ] || return 1
      local d="$cwd"
      while [ -n "$d" ] && [ ! -e "$d/.git" ]; do
        [ "$d" = "/" ] && return 1
        d="${d%/*}"; [ -n "$d" ] || d="/"
      done
      [ -e "$d/.git" ] || return 1
      out="$d"
      ;;
    date)
      if [ ${#w[@]} -eq 1 ]; then
        out=$(LC_ALL=C date 2>/dev/null) || return 1
      else
        [ ${#w[@]} -eq 2 ] || return 1
        # Digits, separators and numeric fields only: no "/" and no ".",
        # so the output cannot spell a path segment or a dot-file name.
        [[ "${w[1]}" =~ ^\+([-_:T0-9]|%[YmdHMSFjyesuT])+$ ]] || return 1
        out=$(LC_ALL=C date "${w[1]}" 2>/dev/null) || return 1
      fi
      ;;
    # cat, head and tail of a file are not computed: the guard would read
    # the file now and bash reads it again later, and an earlier command (or
    # one running alongside) can swap its contents in between, so
    # cat $(cat list) could name a credential file the guard never saw.
    ls)
      [ "$SUBST_IMPURE" -eq 0 ] && [ "$SUBST_WRITES" = " " ] || return 1
      case "$cwd" in *'*'*|*'?'*|*'['*) return 1 ;; esac
      local dirok=0 arg pat prefix m matches=() cntm=0
      for ((i = 1; i < ${#w[@]}; i++)); do
        arg="${w[$i]}"
        case "$arg" in
          -1) continue ;;
          -d|-1d|-d1) dirok=1; continue ;;
          -*|'~'*|*'['*) return 1 ;;
        esac
        case "$arg" in /*) prefix="" ; pat="$arg" ;; *) [ "$CWD_UNCERTAIN" -eq 0 ] || return 1; prefix="$cwd/"; pat="$cwd/$arg" ;; esac
        case "$arg" in
          *'*'*|*'?'*)
            shopt -s nullglob
            IFS=
            # shellcheck disable=SC2206 # glob expansion is the point.
            matches=($pat)
            IFS="$old_ifs"
            shopt -u nullglob
            ;;
          *) matches=("$pat") ;;
        esac
        for m in ${matches[@]+"${matches[@]}"}; do
          [ -e "$m" ] || [ -L "$m" ] || continue
          if [ -d "$m" ] && [ $dirok -eq 0 ]; then return 1; fi
          cntm=$((cntm + 1)); [ $cntm -le 256 ] || return 1
          out="$out${m#"$prefix"}"$'\n'
        done
      done
      [ $cntm -gt 0 ] || return 1
      out="${out%$'\n'}"
      listed=1
      ;;
    *) return 1 ;;
  esac
  for ((k = 1; k < ${#stages[@]}; k++)); do
    read -r -a w <<< "${stages[$k]}"
    [ ${#w[@]} -ge 1 ] || return 1
    case "${w[0]}" in
      head|tail)
        local cnt=10
        if [ ${#w[@]} -gt 1 ]; then
          subst_count_opt "${w[1]}" "${w[2]:-}" || return 1
          [ $((1 + SC_USED)) -eq ${#w[@]} ] || return 1
          cnt="$SC_N"
        fi
        # ls order can differ from the guard's glob order, so a filter over
        # a listing keeps every line (a superset); other outputs are exact.
        [ $listed -eq 1 ] || out=$(printf '%s\n' "$out" | "${w[0]}" -n "$cnt")
        ;;
      sort)
        [ ${#w[@]} -eq 1 ] || { [ ${#w[@]} -eq 2 ] && case "${w[1]}" in -r|-u) true ;; *) false ;; esac; } || return 1
        # Not applied here, so a later head or tail keeps every line.
        listed=1
        ;;
      *) return 1 ;;
    esac
  done
  # Output words must be plain: no option-like words, wildcards, or the
  # guard's own marker bytes.
  local ow=()
  read -r -d '' -a ow <<< "$out" || true
  [ ${#ow[@]} -ge 1 ] && [ ${#ow[@]} -le 256 ] || return 1
  for m in "${ow[@]}"; do
    case "$m" in -*|*'*'*|*'?'*|*'['*|*'{'*|*'}'*|*,*|*[$'\001'-$'\006']*) return 1 ;; esac
  done
  SUBST_OUT="$out"
}

# subst_word <text> -> SW (the words that stand for the text after
# substitution), SW_LEFT (1 when a substitution stayed unknown, and SW is
# then the text unchanged). Consumes one SUBQ entry per \001 in the text,
# from SUBQ_I. SW holds the exact unquoted split first; when an output has
# several words, the quoted reading (one word with the whitespace kept)
# follows as an extra operand, so both readings are checked.
# subq_skip <text>: a word whose substitutions are not computed still uses
# up one SUBQ entry per \001, so later words stay matched to their own
# substitution.
subq_skip() {
  local r="$1"
  while :; do
    case "$r" in *$'\001'*) ;; *) break ;; esac
    r="${r#*$'\001'}"
    SUBQ_I=$((SUBQ_I + 1))
  done
}
SW=()
SW_LEFT=0
subst_word() {
  local text="$1" pre cur rest j q="" multi=0 kind inner
  local outw=()
  SW_LEFT=0
  SW=()
  cur=""
  rest="$text"
  while :; do
    case "$rest" in *$'\001'*) ;; *) break ;; esac
    pre="${rest%%$'\001'*}"
    rest="${rest#*$'\001'}"
    kind="${SUBQK[$SUBQ_I]:-}"
    inner="${SUBQ[$SUBQ_I]:-}"
    SUBQ_I=$((SUBQ_I + 1))
    if [ "$SW_LEFT" -eq 1 ] || [ "$kind" != "w" ] || ! eval_subst "$inner" "$CUR_CWD"; then
      SW_LEFT=1
      continue
    fi
    # Leading or trailing blanks end the outer word in bash; not modeled.
    case "$SUBST_OUT" in [[:space:]]*|*[[:space:]]) SW_LEFT=1; continue ;; esac
    outw=()
    read -r -d '' -a outw <<< "$SUBST_OUT" || true
    q="$q$pre$SUBST_OUT"
    if [ ${#outw[@]} -eq 1 ]; then
      cur="$cur$pre${outw[0]}"
    else
      multi=1
      SW+=("$cur$pre${outw[0]}")
      for ((j = 1; j < ${#outw[@]} - 1; j++)); do SW+=("${outw[$j]}"); done
      cur="${outw[$((${#outw[@]} - 1))]}"
    fi
  done
  SW+=("$cur$rest")
  [ "$multi" -eq 0 ] || SW+=("$q$rest")
  if [ "$SW_LEFT" -eq 1 ]; then SW=("$text"); fi
}

# check_word <text> <flags> <cwd>: an operand that the command reads.
check_word() {
  local text="$1" flags="$2" cwd="$3" cand pat m
  case "$flags" in *v*) expand_vars "$text"; text="$EV" ;; esac
  local cands=()
  case "$flags" in
    *b*) expand_braces "$text"; cands=("${BR[@]}") ;;
    *) cands=("$text") ;;
  esac
  for cand in "${cands[@]}"; do
    [ -n "$cand" ] || continue
    [ "$cand" = "-" ] && continue
    case "$cand" in
      *$'\001'*)
        pat="${cand//$'\001'/*}"
        case "$cand" in
          # An unknown variable at the start can be any absolute directory
          # ($DIR/.npmrc), so match it from the root instead of the cwd.
          $'\001'*) pat="/$pat" ;;
          "~"*|/*|\$*) ;;
          *) pat="$cwd/$pat" ;;
        esac
        norm_path "$pat" "$cwd"
        case "$flags" in
          *c*)
            case "${cand##*/}" in
              *$'\001'*) block "reading a path computed from a credential-file name" ;;
            esac
            ;;
        esac
        # A literal credential basename behind an unknown directory is a
        # credential file wherever the directory points.
        case "${cand##*/}" in
          *$'\001'*) ;;
          *) if is_cred_path "$NP"; then block "reading a credential file through a variable path ($(show_path "$pat"))"; fi ;;
        esac
        # A pattern that is only wildcards (a leading $(...) or variable the
        # guard cannot read) names no path: say which operand it could not
        # prove, not "pattern /*" (it still blocks, fail closed).
        case "$NP" in
          *[!/*?]*) check_pattern "$NP" 0 ;;
          *) block "reading a path computed by a substitution or variable the credential guard cannot evaluate (operand: ${text})" ;;
        esac
        # A wildcard cannot model unknown separators or parent segments.
        # Missing matches are not proof: output can name a deeper neutral
        # link, or leave this directory entirely. Metadata-only commands
        # never reach this read-operand check.
        block "reading a path whose computed value the credential guard cannot prove"
        ;;
      *)
        norm_path "$cand" "$cwd"
        case "$flags" in
          *g*)
            check_pattern "$NP" 0 0 1
            local matches=() mm cnt=0 rps=() ri
            local old_ifs="$IFS"
            shopt -s nullglob
            IFS=
            # shellcheck disable=SC2206 # glob expansion is the point.
            matches=($NP)
            IFS="$old_ifs"
            shopt -u nullglob
            # The cap bounds hook time, not safety: every match is still
            # checked. 500 blocked an ordinary `grep x policies/*.md` over a
            # folder of about 2,000 files (feedback_0ae14829).
            [ ${#matches[@]} -le 10000 ] || block "path has more matches than the credential guard can check"
            for mm in ${matches[@]+"${matches[@]}"}; do
              is_cred_path "$mm" && block "reading a credential file ($(show_path "$mm"))"
            done
            if [ ${#matches[@]} -gt 0 ] && [ -n "$REALPATH_BIN" ]; then
              # Resolve symlink targets in chunks of 500 paths, one realpath
              # call per chunk, so a large folder stays fast and under the
              # argument limit. A chunk whose realpath exits non-zero (a
              # dangling link) or prints a different number of lines (a
              # newline in a name) is checked file by file instead, so the
              # line order is never trusted on its own.
              local cs ce chunk rpout rprc
              for ((cs = 0; cs < ${#matches[@]}; cs += 500)); do
                chunk=("${matches[@]:cs:500}")
                rprc=0
                rpout="$("$REALPATH_BIN" -- "${chunk[@]}" 2>/dev/null)" || rprc=$?
                rps=()
                if [ "$rprc" -eq 0 ]; then
                  while IFS= read -r ri; do rps+=("$ri"); done <<< "$rpout"
                fi
                if [ "$rprc" -eq 0 ] && [ ${#rps[@]} -eq ${#chunk[@]} ]; then
                  for ((ce = 0; ce < ${#chunk[@]}; ce++)); do
                    if [ "${rps[$ce]}" != "${chunk[$ce]}" ] && is_cred_path "${rps[$ce]}"; then
                      block "reading a credential file ($(show_path "${chunk[$ce]}") -> $(show_path "${rps[$ce]}"))"
                    fi
                  done
                else
                  for mm in "${chunk[@]}"; do check_abs "$mm"; done
                fi
              done
            else
              for mm in ${matches[@]+"${matches[@]}"}; do check_abs "$mm"; done
            fi
            ;;
          *) check_abs "$NP" ;;
        esac
        ;;
    esac
  done
}

# resolve_dir <text> <flags> <cwd> -> NP or empty (for cd / recursive targets).
resolve_dir() {
  local text="$1" flags="$2"
  case "$flags" in *v*) expand_vars "$text"; text="$EV" ;; esac
  case "$text" in *$'\001'*) NP=""; return ;; esac
  norm_path "$text" "$3"
}

# Per-tool option tables (short options that take an argument).
argopts_for() {
  case "$1" in
    nl) printf 'bdfhilnsvw' ;;
    tac) printf 's' ;;
    head|tail) printf 'ncbs' ;;
    less|more) printf 'bhjkoOpPtTxyz' ;;
    bat|batcat) printf 'lmrH' ;;
    sed|gsed) printf 'efl' ;;
    awk|gawk|mawk|nawk) printf 'fvF' ;;
    grep|egrep|fgrep|zgrep) printf 'ABCDdefm' ;;
    rg) printf 'ABCefgjmMtTEr' ;;
    ag) printf 'ABCGgm' ;;
    ack) printf 'ABC' ;;
    strings) printf 'nte' ;;
    xxd) printf 'cglson' ;;
    od) printf 'AjNtw' ;;
    hexdump|hd) printf 'efns' ;;
    base64|base32) printf 'wbio' ;;
    cp) printf 'tS' ;;
    rsync) printf 'efTB' ;;
    scp) printf 'cFiJloPS' ;;
    install) printf 'mogtS' ;;
    jq) printf 'fL' ;;
    yq) printf 'oIpf' ;;
    diff) printf 'LxXIFDCU' ;;
    cmp) printf 'in' ;;
    sort) printf 'oktST' ;;
    uniq) printf 'fs' ;;
    cut) printf 'bcdf' ;;
    paste) printf 'd' ;;
    fold|fmt) printf 'w' ;;
    pr) printf 'hlwoNsSe' ;;
    column) printf 'cst' ;;
    expand) printf 't' ;;
  esac
}

# Long options (without =) that take one argument.
long_takes_arg() { # <cmd> <--opt>
  case "$2" in
    --regexp|--file|--max-count|--after-context|--before-context|--context|\
    --include|--exclude|--exclude-dir|--label|--devices|--directories|\
    --binary-files|--glob|--iglob|--type|--type-not|--replace|--max-depth|\
    --encoding|--sort|--sortr|--max-filesize|--colors|--pre|--threads|\
    --ignore-file|--expression|--from-file|--indent|--output|--lines|--bytes|\
    --target-directory|--suffix|--field-separator|--delimiter|--fields|\
    --key|--width|--assign|--source)
      return 0 ;;
  esac
  return 1
}

# Options whose argument is a file the tool reads.
is_file_argopt() { # <cmd> <opt-char-or-long>
  case "$1:$2" in
    grep:f|egrep:f|fgrep:f|zgrep:f|rg:f|sed:f|gsed:f|awk:f|gawk:f|mawk:f|nawk:f|jq:f|yq:f|base64:i|base32:i) return 0 ;;
    *:--file|*:--from-file) return 0 ;;
  esac
  return 1
}

# Options whose argument is a pattern or glob, not a file. Their values are
# not checked as paths (grep -e .env, rg -g '!*.env').
is_pattern_argopt() { # <cmd> <opt-char-or-long>
  case "$1:$2" in
    grep:e|egrep:e|fgrep:e|zgrep:e|rg:e|sed:e|gsed:e|ack:e) return 0 ;;
    rg:g|rg:t|rg:T|rg:r|rg:E|rg:M|ag:G|ag:g) return 0 ;;
    awk:F|gawk:F|mawk:F|nawk:F|cut:d|paste:d|sort:t|column:s|tac:s|uniq:s) return 0 ;;
    *:--regexp|*:--expression|*:--include|*:--exclude|*:--exclude-dir|*:--glob|\
    *:--iglob|*:--type|*:--type-not|*:--replace|*:--label|*:--field-separator|\
    *:--delimiter) return 0 ;;
  esac
  return 1
}

is_reader() {
  case "$1" in
    cat|tac|nl|head|tail|less|more|bat|batcat|sed|gsed|awk|gawk|mawk|nawk|\
    grep|egrep|fgrep|zgrep|rg|ag|ack|strings|xxd|od|hexdump|hd|base64|base32|\
    cp|rsync|scp|install|jq|yq|diff|cmp|sort|uniq|cut|paste|fold|fmt|pr|\
    column|rev|expand|dd)
      return 0 ;;
  esac
  return 1
}

# Commands that never print or copy the contents of a file operand. Every
# other command has each operand checked (deny by default).
is_safe_cmd() {
  case "$1" in
    ls|stat|test|'['|'[['|chmod|chown|chgrp|touch|rm|rmdir|mkdir|unlink|wc|\
    file|du|echo|printf|true|false|realpath|readlink|basename|dirname|tee|ln|\
    ssh|ssh-add|:|pwd|read|mapfile|readarray|exit|return|unset|set|shift|\
    trap|wait|sleep|type|which|hash|kill|break|continue)
      return 0 ;;
  esac
  return 1
}

is_interpreter() {
  case "$1" in
    python|python[0-9]*|pypy|pypy[0-9]*|node|nodejs|deno|bun|perl|perl[0-9]*|\
    ruby|irb|php|lua|luajit|osascript|rscript|tclsh|wish|julia|groovy)
      return 0 ;;
  esac
  return 1
}

# Credential file names as they appear in interpreter code. ".env" must not
# follow a word character, so process.env and os.environ do not match.
CODE_CRED_RE='(^|[^A-Za-z0-9_.$])\.env([^A-Za-z0-9_]|$)|npmrc|netrc|pypirc|yarnrc|git-credentials|\.aws([^A-Za-z0-9_]|$)|\.ssh([^A-Za-z0-9_]|$)|id_(rsa|dsa|ecdsa|ed25519)([^.A-Za-z0-9_]|$)|\.docker/config|gh/hosts|\.gem/credentials'

# subst_code_check <word...> <command>: code that comes from a $(...) or
# backtick (sh -c "$(cat <<'EOF' ... EOF)", eval "$(...)") runs whatever the
# substitution prints, and the word itself holds only the \001 marker. Check
# the text of every substitution in this command line as code too, so a
# credential name in a heredoc body that is printed and then run still
# blocks. Over-matching (another substitution in the same line) only blocks.
subst_code_check() {
  local cmd="${!#}" w has=0 q
  # A variable can hold a substitution's output (x=$(cat <<EOF ...); sh -c
  # "$x"), so a $ in the code word counts too.
  for w in "$@"; do
    case "$w" in *$'\001'*|*'$'*) has=1; break ;; esac
  done
  [ "$has" -eq 1 ] || return 0
  for q in ${SUBQ_ALL[@]+"${SUBQ_ALL[@]}"}; do
    code_check "$q" "$cmd (from a substitution)"
  done
  return 0
}

# code_check <code text> <command>: block interpreter code that names a
# credential file.
code_check() {
  local t="$1" allowed nc=0 hit=1
  for allowed in .env.example .env.sample .env.template .env.schema .env.dist; do
    t="${t//$allowed/}"
  done
  # Per-environment templates (.env.local.example) hold no values.
  local tre='\.env\.[A-Za-z0-9_-]+\.(example|sample|template)' m
  while [[ "$t" =~ $tre ]]; do
    m="${BASH_REMATCH[0]}"
    t="${t//"$m"/}"
  done
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  [[ "$t" =~ $CODE_CRED_RE ]] && hit=0
  [ "$nc" -eq 1 ] || shopt -u nocasematch
  [ $hit -eq 0 ] && block "$2 code that names a credential file"
  return 0
}

# check_operand <word> <flags> <cwd>: an operand of a command that is not on
# the safe list.
check_operand() {
  local w="$1" f="$2" cwd="$3" rp nc=0 skip=0
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  case "$w" in
    file://*) w="${w:7}" ;;
    [a-z]*://*) skip=1 ;;
  esac
  [ "$nc" -eq 1 ] || shopt -u nocasematch
  [ $skip -eq 0 ] || return 0
  w="${w#@}"
  [ -n "$w" ] || return 0
  check_word "$w" "$f" "$cwd"
  # KEY=path, rev:path, host:path
  if [[ "$w" =~ ^[^/=:]+[=:](.+)$ ]]; then
    check_word "${BASH_REMATCH[1]#@}" "$f" "$cwd"
  fi
  resolve_dir "$w" "$f" "$cwd"
  if [ -n "$NP" ]; then
    if is_secret_dir "$NP"; then
      block "a command reading a credential directory ($(show_path "$NP"))"
    fi
    if [ -n "$REALPATH_BIN" ] && [ -L "$NP" ] && [ -d "$NP" ]; then
      rp=$("$REALPATH_BIN" "$NP" 2>/dev/null) || rp=""
      if [ -n "$rp" ] && is_secret_dir "$rp"; then
        block "a command reading a credential directory ($(show_path "$NP") -> $(show_path "$rp"))"
      fi
    fi
  fi
}

# check_generic <start> <end> <cwd>: every operand and option value.
check_generic() {
  local s="$1" e="$2" cwd="$3" j w f endopts=0
  for ((j = s; j < e; j++)); do
    w="${CW[$j]}"; f="${CF[$j]}"
    if [ $endopts -eq 0 ] && [ "$w" = "--" ]; then endopts=1; continue; fi
    if [ $endopts -eq 0 ] && [[ "$w" == -?* ]]; then
      if [[ "$w" == --*=* ]]; then
        check_operand "${w#*=}" "$f" "$cwd"
      elif [[ "$w" != --* ]] && [ ${#w} -gt 2 ]; then
        check_operand "${w:2}" "$f" "$cwd"
      fi
      continue
    fi
    check_operand "$w" "$f" "$cwd"
  done
}

# copy_onto_cred <dest> <dest-flags> <cwd> <source>...: block a copy or move
# that creates a credential name (a backup such as ~/.npmrc.bak), unless every
# source is a template (cp .env.example .env).
copy_onto_cred() {
  local d="$1" f="$2" cwd="$3" src
  shift 3
  case "$f" in *v*) expand_vars "$d"; d="$EV" ;; esac
  case "$d" in *$'\001'*) return 0 ;; esac
  norm_path "$d" "$cwd"
  [ -d "$NP" ] && return 0
  is_cred_path "$NP" || return 0
  for src in "$@"; do
    is_template_name "${src##*/}" || block "copying onto a credential file name ($(show_path "$NP"))"
  done
  return 0
}

# is_key_tree <normalized path>: .ssh/ or .aws/ or inside one, where every
# name the guard does not allow by name is a credential.
is_key_tree() {
  local r=1 nc=0
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  case "$1" in */.ssh|*/.ssh/*|*/.aws|*/.aws/*) r=0 ;; esac
  [ "$nc" -eq 1 ] || shopt -u nocasematch
  return $r
}

# is_cred_store <normalized path>: a directory whose name makes the files in
# it credentials (.ssh/id_x, .docker/config.json, .config/gh/hosts.yml).
is_cred_store() {
  local r=1 nc=0
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  case "$1" in */.ssh|*/.aws|*/.docker|*/.gem|*/.config|*/.config/gh) r=0 ;; esac
  [ "$nc" -eq 1 ] || shopt -u nocasematch
  return $r
}

# keeps_cred_name <source> <new path>: the new path is still covered, so a
# later read of it is blocked the same as a read of the source.
keeps_cred_name() {
  local src="$1" eff="$2" sb eb pb
  if is_cred_store "$src" || [ -d "$src" ]; then
    is_key_tree "$eff" && return 0
    sb="$(printf '%s' "${src##*/}" | tr '[:upper:]' '[:lower:]')"
    eb="$(printf '%s' "${eff##*/}" | tr '[:upper:]' '[:lower:]')"
    [ "$sb" = "$eb" ] || return 1
    case "$sb" in
      .ssh|.aws|.docker|.gem|.config) return 0 ;;
      gh)
        pb="${eff%/*}"
        pb="$(printf '%s' "${pb##*/}" | tr '[:upper:]' '[:lower:]')"
        [ "$pb" = ".config" ] && return 0
        ;;
    esac
    return 1
  fi
  is_cred_path "$eff"
}

# cred_sources <word> <flags> <cwd>: append to CRED_SRC each path the move
# source names that is a credential file or a directory that holds them.
# A source the guard cannot expand (unknown variable) is added as "?" when it
# may name one.
CRED_SRC=()
cred_sources() {
  local text="$1" fl="$2" cwd="$3" cand m cnt
  local cands=() matches=()
  case "$fl" in *v*) expand_vars "$text"; text="$EV" ;; esac
  case "$fl" in
    *b*) expand_braces "$text"; cands=("${BR[@]}") ;;
    *) cands=("$text") ;;
  esac
  for cand in "${cands[@]}"; do
    [ -n "$cand" ] || continue
    case "$cand" in
      *$'\001'*)
        ( check_word "$1" "$fl" "$cwd" ) >/dev/null 2>&1 || CRED_SRC+=("?")
        continue
        ;;
    esac
    norm_path "$cand" "$cwd"
    matches=("$NP")
    case "$fl" in
      *g*)
        local old_ifs="$IFS"
        shopt -s nullglob
        IFS=
        # shellcheck disable=SC2206 # glob expansion is the point.
        matches=($NP)
        IFS="$old_ifs"
        shopt -u nullglob
        ;;
    esac
    cnt=0
    for m in ${matches[@]+"${matches[@]}"}; do
      cnt=$((cnt + 1))
      [ $cnt -le 500 ] || block "a move of more files than the credential guard can check"
      if is_cred_path "$m" || is_cred_store "$m"; then CRED_SRC+=("$m"); fi
    done
  done
}

# move_like <cmd> <start> <end> <cwd>: mv, git mv, and ln without -s. A move
# or hard link that gives a credential file a name the guard does not cover
# would let a later read of the new name through, so it is blocked. Moves
# that keep a covered name (mv ~/.ssh/id_rsa backup/) are allowed, and so are
# symlinks, which reads resolve.
move_like() {
  local cmd="$1" s="$2" e="$3" cwd="$4" k w rest ch endo=0 notdir=0
  local tdir="" tdirf="" has_t=0
  local ops=() opf=()
  for ((k = s; k < e; k++)); do
    w="${CW[$k]}"
    if [ $endo -eq 0 ] && [ "$w" = "--" ]; then endo=1; continue; fi
    if [ $endo -eq 0 ] && [[ "$w" == -?* ]]; then
      case "$w" in
        --target-directory) k=$((k + 1)); tdir="${CW[$k]:-}"; tdirf="${CF[$k]:-}"; has_t=1 ;;
        --target-directory=*) tdir="${w#*=}"; tdirf="${CF[$k]}"; has_t=1 ;;
        --suffix) k=$((k + 1)) ;;
        --symbolic) [ "$cmd" = "ln" ] && return 0 ;;
        --no-target-directory) notdir=1 ;;
        --*) ;;
        *)
          rest="${w#-}"
          while [ -n "$rest" ]; do
            ch="${rest:0:1}"
            rest="${rest:1}"
            case "$ch" in
              s) [ "$cmd" = "ln" ] && return 0 ;;
              T) notdir=1 ;;
              t)
                has_t=1
                if [ -n "$rest" ]; then
                  tdir="$rest"; tdirf="${CF[$k]}"
                else
                  k=$((k + 1)); tdir="${CW[$k]:-}"; tdirf="${CF[$k]:-}"
                fi
                rest=""
                ;;
              S) [ -n "$rest" ] || k=$((k + 1)); rest="" ;;
            esac
          done
          ;;
      esac
      continue
    fi
    ops+=("$w"); opf+=("${CF[$k]}")
  done
  local n=${#ops[@]} dest destf ddir=0
  if [ $has_t -eq 1 ]; then
    dest="$tdir"; destf="$tdirf"; ddir=1
  elif [ "$n" -eq 1 ] && [ "$cmd" = "ln" ]; then
    # ln with one operand links into the cwd under the same base name.
    dest="."; destf=""; ddir=1
  elif [ "$n" -ge 2 ]; then
    n=$((n - 1))
    dest="${ops[$n]}"; destf="${opf[$n]}"
    [ "$n" -gt 1 ] && ddir=1
    case "$cmd" in
      mv|gmv) copy_onto_cred "$dest" "$destf" "$cwd" "${ops[@]:0:$n}" ;;
    esac
  else
    return 0
  fi
  CRED_SRC=()
  for ((k = 0; k < n; k++)); do
    cred_sources "${ops[$k]}" "${opf[$k]}" "$cwd"
  done
  [ ${#CRED_SRC[@]} -gt 0 ] || return 0
  case "$destf" in *v*) expand_vars "$dest"; dest="$EV" ;; esac
  case "$destf" in *g*|*b*) block "$cmd of a credential file to a wildcard destination" ;; esac
  case "$dest" in *$'\001'*) block "$cmd of a credential file to a destination the credential guard cannot resolve" ;; esac
  norm_path "$dest" "$cwd"
  local dn="$NP" src eff
  if [ $notdir -eq 0 ]; then
    case "$dest" in */) ddir=1 ;; esac
    [ -d "$dn" ] && ddir=1
  fi
  for src in "${CRED_SRC[@]}"; do
    if [ "$src" = "?" ]; then
      [ $ddir -eq 1 ] && is_key_tree "$dn" && continue
      block "$cmd of a path the credential guard cannot resolve, which may be a credential file"
    fi
    if [ $ddir -eq 1 ]; then eff="$dn/${src##*/}"; else eff="$dn"; fi
    keeps_cred_name "$src" "$eff" && continue
    block "$cmd of a credential file to a name the guard does not cover ($(show_path "$src") -> $(show_path "$eff")); a later read of it would not be blocked"
  done
  return 0
}

# strip_identity_opts <cmd> <start> <end>: scp, sftp and rsync hand an
# identity file to ssh, which reads it to authenticate and never prints it,
# the same as `ssh -i key` on the safe list. Removes scp/sftp -i <file> and
# -o IdentityFile=<file>, and rsync -e / --rsh <command>, from CW/CF. The
# rsync remote-shell commands are left in RSH_CMDS to be checked as commands
# of their own. Every other option and operand keeps the usual checks.
RSH_CMDS=()
strip_identity_opts() {
  local cmd="$1" s="$2" e="$3" k w f rest ch val vf kept used endo=0 argopts
  local nw=() nf=()
  RSH_CMDS=()
  case "$cmd" in
    scp) argopts='cFiJloPS' ;;
    sftp) argopts='BbcDFiJloPRSs' ;;
    rsync) argopts="$(argopts_for rsync)" ;;
  esac
  for ((k = 0; k < s; k++)); do nw+=("${CW[$k]}"); nf+=("${CF[$k]}"); done
  k=$s
  while [ "$k" -lt "$e" ]; do
    w="${CW[$k]}"; f="${CF[$k]}"
    if [ $endo -eq 1 ] || [[ "$w" != -?* ]]; then
      nw+=("$w"); nf+=("$f"); k=$((k + 1)); continue
    fi
    if [ "$w" = "--" ]; then
      endo=1; nw+=("$w"); nf+=("$f"); k=$((k + 1)); continue
    fi
    if [[ "$w" == --* ]]; then
      if [ "$cmd" = "rsync" ]; then
        case "$w" in
          --rsh=*) RSH_CMDS+=("${w#--rsh=}"); k=$((k + 1)); continue ;;
          --rsh) [ $((k + 1)) -lt "$e" ] && RSH_CMDS+=("${CW[$((k + 1))]}"); k=$((k + 2)); continue ;;
        esac
      fi
      nw+=("$w"); nf+=("$f"); k=$((k + 1)); continue
    fi
    rest="${w#-}"; kept=""; used=0
    while [ -n "$rest" ]; do
      ch="${rest:0:1}"
      rest="${rest:1}"
      case "$argopts" in
        *"$ch"*)
          if [ -n "$rest" ]; then
            val="$rest"; vf="$f"
          else
            val="${CW[$((k + 1))]:-}"; vf="${CF[$((k + 1))]:-}"; used=1
          fi
          rest=""
          if [ "$cmd" = "rsync" ] && [ "$ch" = "e" ]; then
            RSH_CMDS+=("$val")
          elif [ "$cmd" != "rsync" ] && [ "$ch" = "i" ]; then
            :
          elif [ "$cmd" != "rsync" ] && [ "$ch" = "o" ] && [[ "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" =~ ^[[:space:]]*identityfile([[:space:]]*=|[[:space:]]) ]]; then
            :
          else
            if [ -n "$kept" ]; then nw+=("-$kept"); nf+=("$f"); kept=""; fi
            nw+=("-$ch" "$val"); nf+=("$f" "$vf")
          fi
          ;;
        *) kept="$kept$ch" ;;
      esac
    done
    if [ -n "$kept" ]; then nw+=("-$kept"); nf+=("$f"); fi
    k=$((k + 1 + used))
  done
  CW=(${nw[@]+"${nw[@]}"}); CF=(${nf[@]+"${nf[@]}"})
}

# Words of the current simple command, and its stdin text when that is a
# heredoc, a here-string, or echo/printf output piped in.
CW=()
CF=()
STDIN_KIND=""
STDIN_TEXT=""

# check_reader <cmd> <start-of-args> <end> <cwd>
check_reader() {
  local cmd="$1" s="$2" e="$3" cwd="$4"
  local argopts pattern_first=0 have_pattern=0 pattern_skipped=0 endopts=0
  local exempt=0 recursive=0 sed_inplace=0 sed_suffix=0 dest_t=0 jq_args=0
  local j w f o rest ch k
  local ops_t=() ops_f=() scripts=()
  argopts="$(argopts_for "$cmd")"
  case "$cmd" in
    grep|egrep|fgrep|zgrep|rg|ag|ack|sed|gsed|awk|gawk|mawk|nawk|jq|yq) pattern_first=1 ;;
  esac
  case "$cmd" in rg|ag|ack) recursive=1 ;; esac
  j=$s
  while [ $j -lt $e ]; do
    w="${CW[$j]}"; f="${CF[$j]}"
    if [ $endopts -eq 0 ] && [ "$w" = "--" ]; then endopts=1; j=$((j + 1)); continue; fi
    if [ $endopts -eq 0 ] && [ $jq_args -eq 0 ] && [[ "$w" == -?* ]]; then
      if [[ "$w" == --* ]]; then
        o="${w%%=*}"
        case "$cmd:$o" in
          grep:--count|grep:--files-with-matches|grep:--files-without-match|grep:--quiet|grep:--silent|\
          egrep:--count|egrep:--quiet|fgrep:--count|fgrep:--quiet|\
          rg:--count|rg:--count-matches|rg:--files|rg:--files-with-matches|rg:--files-without-match|rg:--quiet|\
          ag:--count|ag:--files-with-matches|ag:-l)
            exempt=1 ;;
        esac
        case "$o" in
          --recursive|--dereference-recursive|--archive) recursive=1 ;;
          --directories) [ "${w#*=}" = "recurse" ] && recursive=1 ;;
          --regexp|--expression|--file|--from-file|--source) have_pattern=1 ;;
          --target-directory) dest_t=1 ;;
          --in-place) sed_inplace=1; [[ "$w" == *=?* ]] && sed_suffix=1 ;;
          --args|--jsonargs) [ "$cmd" = "jq" ] && jq_args=1 ;;
        esac
        if [[ "$w" == *=* ]]; then
          case "$o" in
            --regexp|--expression) scripts+=("${w#*=}") ;;
            --file|--from-file|--ignore-file|--slurpfile|--rawfile) ops_t+=("${w#*=}"); ops_f+=("$f") ;;
            --target-directory|--output|--suffix|--label|--include|--exclude|--exclude-dir|--glob|--iglob) ;;
            --in-place) ;;
            *) case "${w#*=}" in */*|.*|~*) ops_t+=("${w#*=}"); ops_f+=("$f") ;; esac ;;
          esac
          j=$((j + 1)); continue
        fi
        if [ "$cmd" = "jq" ] || [ "$cmd" = "yq" ]; then
          case "$o" in
            --arg|--argjson) j=$((j + 3)); continue ;;
            --slurpfile|--rawfile)
              if [ $((j + 2)) -lt $e ]; then ops_t+=("${CW[$((j + 2))]}"); ops_f+=("${CF[$((j + 2))]}"); fi
              j=$((j + 3)); continue ;;
          esac
        fi
        if long_takes_arg "$cmd" "$o"; then
          if [ $((j + 1)) -lt $e ]; then
            case "$o" in
              --regexp|--expression) scripts+=("${CW[$((j + 1))]}") ;;
              --file|--from-file|--ignore-file) ops_t+=("${CW[$((j + 1))]}"); ops_f+=("${CF[$((j + 1))]}") ;;
              *) is_pattern_argopt "$cmd" "$o" || check_operand "${CW[$((j + 1))]}" "${CF[$((j + 1))]}" "$cwd" ;;
            esac
          fi
          j=$((j + 2)); continue
        fi
        j=$((j + 1)); continue
      fi
      # short option cluster
      rest="${w#-}"
      local consumed_next=0
      while [ -n "$rest" ]; do
        ch="${rest:0:1}"
        rest="${rest:1}"
        case "$cmd" in
          grep|egrep|fgrep|zgrep) case "$ch" in c|l|L|q) exempt=1 ;; r|R) recursive=1 ;; esac ;;
          rg|ag) case "$ch" in c|l|q) exempt=1 ;; esac ;;
          cp) case "$ch" in r|R|a) recursive=1 ;; esac ;;
          rsync) case "$ch" in r|a) recursive=1 ;; esac ;;
          scp) case "$ch" in r) recursive=1 ;; esac ;;
          sed|gsed)
            if [ "$ch" = "i" ]; then
              sed_inplace=1
              # -i.bak, -ibak, -ie (GNU suffix "e") and BSD -i .bak keep a
              # backup copy of the file.
              [ -n "$rest" ] && sed_suffix=1
              if [ -z "$rest" ] && [ $((j + 1)) -lt $e ]; then
                case "${CW[$((j + 1))]}" in
                  '') consumed_next=1 ;;
                  .*) consumed_next=1; sed_suffix=1 ;;
                esac
              fi
              rest=""
              continue
            fi
            ;;
        esac
        if [ "$cmd" = "grep" ] && [ "$ch" = "d" ]; then
          local darg="$rest"
          [ -n "$darg" ] || darg="${CW[$((j + 1))]:-}"
          [ "$darg" = "recurse" ] && recursive=1
        fi
        case "$argopts" in
          *"$ch"*)
            local arg="$rest"
            if [ -z "$arg" ]; then
              arg="${CW[$((j + 1))]:-}"
              consumed_next=1
            fi
            case "$ch" in
              e) have_pattern=1; scripts+=("$arg") ;;
              f) case "$cmd" in grep|egrep|fgrep|zgrep|rg|sed|gsed|awk|gawk|mawk|nawk|jq|yq) have_pattern=1 ;; esac ;;
              t) [ "$cmd" = "cp" ] || [ "$cmd" = "install" ] && dest_t=1 ;;
            esac
            if is_file_argopt "$cmd" "$ch"; then
              if [ -z "$rest" ]; then ops_t+=("$arg"); ops_f+=("${CF[$((j + 1))]:-}"); else ops_t+=("$arg"); ops_f+=("$f"); fi
            elif ! is_pattern_argopt "$cmd" "$ch"; then
              # Option values are checked too: some table entries take an
              # optional or no argument on some platforms (column -t, pr -s,
              # od -w), so the "value" can be the file operand itself.
              if [ -z "$rest" ]; then check_operand "$arg" "${CF[$((j + 1))]:-}" "$cwd"; else check_operand "$arg" "$f" "$cwd"; fi
            fi
            rest=""
            ;;
        esac
      done
      j=$((j + 1 + consumed_next))
      continue
    fi
    # operand
    if [ $pattern_first -eq 1 ] && [ $have_pattern -eq 0 ] && [ $pattern_skipped -eq 0 ]; then
      if [ "$cmd" = "yq" ]; then
        case "$w" in e|eval|ea|eval-all) j=$((j + 1)); continue ;; esac
      fi
      pattern_skipped=1
      scripts+=("$w")
      j=$((j + 1)); continue
    fi
    case "$cmd" in
      awk|gawk|mawk|nawk) [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && { j=$((j + 1)); continue; } ;;
      dd)
        case "$w" in if=*) ops_t+=("${w#if=}"); ops_f+=("$f") ;; esac
        j=$((j + 1)); continue ;;
    esac
    ops_t+=("$w"); ops_f+=("$f")
    j=$((j + 1))
  done

  [ $exempt -eq 1 ] && return 0

  # An in-place delete is allowed only without a backup suffix: the backup
  # (~/.npmrc.bak) is a full copy of the credential file.
  if [ $sed_inplace -eq 1 ] && [ $sed_suffix -eq 0 ]; then
    local all_delete=1 sc
    [ ${#scripts[@]} -gt 0 ] || all_delete=0
    for sc in ${scripts[@]+"${scripts[@]}"}; do
      [[ "$sc" =~ ^/[^/]*/[Ii]?d$ ]] || all_delete=0
    done
    [ $all_delete -eq 1 ] && return 0
  fi

  local n_ops=${#ops_t[@]}
  case "$cmd" in
    cp|rsync|scp|install)
      if [ $dest_t -eq 0 ] && [ $n_ops -gt 0 ]; then
        n_ops=$((n_ops - 1))
        copy_onto_cred "${ops_t[$n_ops]}" "${ops_f[$n_ops]}" "$cwd" "${ops_t[@]:0:$n_ops}"
      fi
      ;;
  esac

  if [ $recursive -eq 1 ]; then
    local any_target=0
    for ((k = 0; k < n_ops; k++)); do
      any_target=1
      resolve_dir "${ops_t[$k]}" "${ops_f[$k]}" "$cwd"
      if [ -n "$NP" ] && is_cred_dir "$NP"; then
        block "recursive read of a directory that holds credentials ($(show_path "$NP"))"
      fi
    done
    if [ $any_target -eq 0 ] && is_cred_dir "$cwd"; then
      block "recursive read of a directory that holds credentials ($(show_path "$cwd"))"
    fi
  fi

  for ((k = 0; k < n_ops; k++)); do
    check_word "${ops_t[$k]}" "${ops_f[$k]}" "$cwd"
  done
}

# Prefix words that precede the real command, and their option arguments.
prefix_argopts() {
  case "$1" in
    sudo) printf 'ugCDhprtU' ;;
    doas) printf 'uC' ;;
    nice) printf 'n' ;;
    timeout|gtimeout) printf 'sk' ;;
    stdbuf) printf 'ioe' ;;
    exec) printf 'a' ;;
    caffeinate) printf 'tw' ;;
    env) printf 'uSC' ;;
  esac
}

# analyze_simple <start> <end> <cwd-var-name> <depth>: one simple command in CW/CF.
CUR_CWD=""
analyze_simple() {
  local s="$1" e="$2" depth="$3"
  local j w b
  # assignments and prefixes
  j=$s
  while [ $j -lt $e ]; do
    w="${CW[$j]}"
    if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      local val="${w#*=}"
      case "$val" in "~"|"~/"*) val="$H${val#"~"}" ;; esac
      expand_vars "$val"
      set_var "${w%%=*}" "$EV"
      j=$((j + 1)); continue
    fi
    b="${w##*/}"
    case "$b" in
      '!'|'{'|'}'|then|do|else|elif|if|while|until|time|command|builtin|exec|nohup|nice|sudo|doas|env|timeout|gtimeout|stdbuf|caffeinate|fi|done|esac)
        local pa
        pa="$(prefix_argopts "$b")"
        j=$((j + 1))
        while [ $j -lt $e ]; do
          w="${CW[$j]}"
          if [[ "$w" == -?* ]]; then
            local optc="${w:1:1}"
            if [ ${#w} -eq 2 ] && [ -n "$pa" ] && [[ "$pa" == *"$optc"* ]]; then j=$((j + 2)); else j=$((j + 1)); fi
            continue
          fi
          if [ "$b" = "env" ] && [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then j=$((j + 1)); continue; fi
          break
        done
        if [ "$b" = "timeout" ] || [ "$b" = "gtimeout" ]; then j=$((j + 1)); fi
        continue
        ;;
      for|case|select|function|in)
        return 0 ;;
      export|local|declare|readonly|typeset)
        local k2
        for ((k2 = j + 1; k2 < e; k2++)); do
          w="${CW[$k2]}"
          if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            local v2="${w#*=}"
            case "$v2" in "~"|"~/"*) v2="$H${v2#"~"}" ;; esac
            expand_vars "$v2"
            set_var "${w%%=*}" "$EV"
          fi
        done
        return 0
        ;;
    esac
    break
  done
  [ $j -lt $e ] || return 0
  local in_kind="$STDIN_KIND" in_text="$STDIN_TEXT"
  local a=$((j + 1)) k joined sep
  # A command word held in a variable ($c) or built by a substitution is
  # resolved when it was assigned earlier; otherwise it is unknown, and every
  # operand and argument is checked.
  local cw0="${CW[$j]}" dynamic=0
  case "${CF[$j]}" in
    *s*) dynamic=1 ;;
    *v*)
      expand_vars "$cw0"; cw0="$EV"
      case "$cw0" in *'$'*|*$'\001'*|*' '*) dynamic=1 ;; esac
      ;;
  esac
  if [ $dynamic -eq 1 ]; then
    joined=""; sep=""
    for ((k = a; k < e; k++)); do joined="$joined$sep${CW[$k]}"; sep=" "; done
    code_check "$joined" "a dynamic command with"
    check_generic "$a" "$e" "$CUR_CWD"
    return 0
  fi
  local cmd
  lc_word "${cw0##*/}"
  cmd="$LCW"
  [ "$cmd" != "popd" ] || CWD_UNCERTAIN=1
  case "$cmd" in
    cd|pushd)
      local target=""
      for ((k = a; k < e; k++)); do
        case "${CW[$k]}" in -?*) continue ;; esac
        target="${CW[$k]}"; resolve_dir "$target" "${CF[$k]}" "$CUR_CWD"
        # An unresolved or history target (cd -, cd $X) leaves the working
        # directory unknown, so substitutions with relative paths are no
        # longer computed (eval_subst).
        if [ -n "$NP" ] && [ "$target" != "-" ]; then CUR_CWD="$NP"; else CWD_UNCERTAIN=1; fi
        break
      done
      if [ -z "$target" ]; then
        if [ "$a" -lt "$e" ]; then CWD_UNCERTAIN=1; else CUR_CWD="$H"; fi
      fi
      return 0
      ;;
    bash|sh|zsh|dash|ksh)
      for ((k = a; k < e; k++)); do
        w="${CW[$k]}"
        case "$w" in
          -*c*)
            if [[ "$w" != --* ]] && [ $((k + 1)) -lt $e ]; then
              subst_code_check "${CW[$((k + 1))]}" "$cmd -c"
              analyze_cmd "${CW[$((k + 1))]}" $((depth + 1)) "$CUR_CWD"
              return 0
            fi
            ;;
          # `bash -O dotglob -c ...` / `-o pipefail`: the option name is not
          # the script, so skip it and keep looking for -c (review C2).
          -O|+O|-o|+o|--rcfile|--init-file) k=$((k + 1)) ;;
          -*) ;;
          *) check_word "$w" "${CF[$k]}" "$CUR_CWD"; return 0 ;;
        esac
      done
      # No -c and no script: the shell runs its stdin.
      if [ "$in_kind" = "script" ]; then
        analyze_cmd "$in_text" $((depth + 1)) "$CUR_CWD"
      elif [ "$in_kind" = "pipe" ]; then
        code_check "$in_text" "$cmd"
      fi
      return 0
      ;;
    git)
      k=$a
      while [ $k -lt $e ]; do
        case "${CW[$k]}" in
          -C|-c|--git-dir|--work-tree|--namespace) k=$((k + 2)); continue ;;
          -*) k=$((k + 1)); continue ;;
        esac
        break
      done
      [ $k -lt $e ] || return 0
      local k2
      case "${CW[$k]}" in
        status|rm|check-ignore|check-attr|ls-files)
          return 0 ;;
        mv)
          move_like "git-mv" $((k + 1)) "$e" "$CUR_CWD"
          return 0 ;;
        commit)
          # The message file is the only operand commit reads.
          for ((k2 = k + 1; k2 < e; k2++)); do
            case "${CW[$k2]}" in
              -F|--file) [ $((k2 + 1)) -lt $e ] && check_operand "${CW[$((k2 + 1))]}" "${CF[$((k2 + 1))]}" "$CUR_CWD" ;;
              --file=*) check_operand "${CW[$k2]#--file=}" "${CF[$k2]}" "$CUR_CWD" ;;
              -F?*) check_operand "${CW[$k2]#-F}" "${CF[$k2]}" "$CUR_CWD" ;;
            esac
          done
          return 0
          ;;
        add)
          for ((k2 = k + 1; k2 < e; k2++)); do
            case "${CW[$k2]}" in
              -p|--patch|-i|--interactive|-e|--edit) check_generic $((k + 1)) "$e" "$CUR_CWD"; return 0 ;;
            esac
          done
          return 0
          ;;
      esac
      check_generic $((k + 1)) "$e" "$CUR_CWD"
      return 0
      ;;
    ssh-keygen)
      for ((k = a; k < e; k++)); do
        case "${CW[$k]}" in -i|-*i*) [[ "${CW[$k]}" == --* ]] || { check_generic "$a" "$e" "$CUR_CWD"; return 0; } ;; esac
      done
      return 0
      ;;
    mv|gmv|ln)
      move_like "$cmd" "$a" "$e" "$CUR_CWD"
      return 0
      ;;
    scp|sftp|rsync)
      strip_identity_opts "$cmd" "$a" "$e"
      e=${#CW[@]}
      local rsh_cmds=(${RSH_CMDS[@]+"${RSH_CMDS[@]}"})
      if [ "$cmd" = "sftp" ]; then
        check_generic "$a" "$e" "$CUR_CWD"
      else
        check_reader "$cmd" "$a" "$e" "$CUR_CWD"
      fi
      # analyze_cmd replaces CW, so the remote-shell commands go last.
      for w in ${rsh_cmds[@]+"${rsh_cmds[@]}"}; do
        analyze_cmd "$w" $((depth + 1)) "$CUR_CWD"
      done
      return 0
      ;;
    source|.)
      [ $a -lt $e ] && check_word "${CW[$a]}" "${CF[$a]}" "$CUR_CWD"
      # source /dev/stdin <<'EOF' runs the heredoc or here-string as code.
      [ -n "$in_kind" ] && code_check "$in_text" "$cmd"
      return 0
      ;;
    eval)
      local joined="" sep=""
      for ((k = a; k < e; k++)); do joined="$joined$sep${CW[$k]}"; sep=" "; done
      subst_code_check "$joined" "eval"
      [ -n "$joined" ] && analyze_cmd "$joined" $((depth + 1)) "$CUR_CWD"
      return 0
      ;;
    xargs)
      k=$a
      while [ $k -lt $e ]; do
        w="${CW[$k]}"
        case "$w" in
          -a|--arg-file) [ $((k + 1)) -lt $e ] && check_word "${CW[$((k + 1))]}" "${CF[$((k + 1))]}" "$CUR_CWD"; k=$((k + 2)); continue ;;
          --arg-file=*) check_word "${w#*=}" "${CF[$k]}" "$CUR_CWD"; k=$((k + 1)); continue ;;
          -I|-L|-n|-P|-s|-d|-E) k=$((k + 2)); continue ;;
          -*) k=$((k + 1)); continue ;;
        esac
        break
      done
      if [ $k -lt $e ] && [ "$CRED_ANY" -eq 1 ] && { lc_word "${CW[$k]##*/}"; ! is_safe_cmd "$LCW"; }; then
        block "xargs feeding a command in a command line that names a credential file"
      fi
      return 0
      ;;
    find)
      for ((k = a; k < e; k++)); do
        case "${CW[$k]}" in
          -exec|-execdir|-ok|-okdir)
            if [ $((k + 1)) -lt $e ] && [ "$CRED_ANY" -eq 1 ] && { lc_word "${CW[$((k + 1))]##*/}"; ! is_safe_cmd "$LCW"; }; then
              block "find -exec in a command line that names a credential file"
            fi
            ;;
        esac
      done
      return 0
      ;;
  esac
  is_safe_cmd "$cmd" && return 0
  if is_interpreter "$cmd"; then
    joined=""; sep=""
    for ((k = a; k < e; k++)); do joined="$joined$sep${CW[$k]}"; sep=" "; done
    code_check "$joined" "$cmd"
    subst_code_check "$joined" "$cmd"
    [ -n "$in_kind" ] && code_check "$in_text" "$cmd"
    check_generic "$a" "$e" "$CUR_CWD"
    return 0
  fi
  # `hq dm send --body "$(cat workspace/drafts/x.md)"`: the message text
  # option takes the text itself, never a path. A value that is exactly one
  # substitution is data; the substitution's own script is analyzed as its
  # own token, so `$(cat ~/.npmrc)` is still blocked there. Every other
  # operand is checked as usual.
  if [ "$cmd" = "hq" ] && [ "${CW[$a]:-}" = "dm" ]; then
    local dm_data=0 dw
    for ((k = a; k < e; k++)); do
      dw="${CW[$k]}"
      if [ $dm_data -eq 1 ]; then
        dm_data=0
        case "${CF[$k]}" in *s*) [ "$dw" = $'\001' ] && continue ;; esac
      fi
      case "$dw" in
        --body|--message|--text|--prompt) dm_data=1; continue ;;
        --body=$'\001'|--message=$'\001'|--text=$'\001'|--prompt=$'\001') continue ;;
      esac
      check_generic "$k" $((k + 1)) "$CUR_CWD"
    done
    return 0
  fi
  case "$cmd" in
    awk|gawk|mawk|nawk)
      # awk can open files from inside the program (getline < f, system()).
      joined=""; sep=""
      for ((k = a; k < e; k++)); do joined="$joined$sep${CW[$k]}"; sep=" "; done
      if [[ "$joined" =~ getline|system ]]; then code_check "$joined" "$cmd"; fi
      ;;
  esac
  if is_reader "$cmd"; then
    check_reader "$cmd" "$a" "$e" "$CUR_CWD"
  else
    check_generic "$a" "$e" "$CUR_CWD"
  fi
  return 0
}

# analyze_cmd <text> <depth> <cwd>
analyze_cmd() {
  local text="$1" depth="$2"
  local saved_cwd="$CUR_CWD"
  CUR_CWD="$3"
  if [ "$depth" -gt 6 ]; then
    block "command nesting too deep for the credential guard to check"
  fi
  local toks
  toks=$(printf '%s' "$text" | LC_ALL=C awk "$AWK_PROG") \
    || block "credential guard could not parse the command"
  local T=() F=() O=() X=() HB=()
  # Substitutions that put a \001 into a word, in token order (SUBQK: w or p).
  local SUBQ=() SUBQK=() SUBQ_I=0
  # Every substitution text in this command line (subst_code_check).
  local SUBQ_ALL=()
  local CWD_UNCERTAIN="$CWD_UNCERTAIN"
  local t fl op tx hb_next=0 pipe_text=""
  while IFS=$'\t' read -r t fl op tx; do
    [ -n "$t" ] || continue
    T+=("$t"); F+=("${fl#f}"); O+=("${op#o}"); X+=("${tx#x}")
  done <<< "$toks"
  local i n=${#T[@]}
  for ((i = 0; i < n; i++)); do
    case "${T[$i]}" in
      E)
        block "credential guard could not parse the command (${X[$i]})"
        ;;
      S)
        cg_nl3 "${X[$i]}"
        local sub_text="$CG_NL"
        SUBQ_ALL+=("$sub_text")
        analyze_cmd "$sub_text" $((depth + 1)) "$CUR_CWD"
        case "${F[$i]}" in
          w|p) SUBQ+=("$sub_text"); SUBQK+=("${F[$i]}") ;;
        esac
        ;;
      H)
        cg_nl3 "${X[$i]}"
        HB+=("$CG_NL")
        ;;
    esac
  done
  # Group into simple commands. A command's input redirects are checked too.
  local starts=() ends=() seps=()
  local cs=0
  for ((i = 0; i <= n; i++)); do
    if [ $i -eq $n ] || [ "${T[$i]}" = "O" ]; then
      starts+=("$cs"); ends+=("$i")
      if [ $i -lt $n ]; then seps+=("${O[$i]}"); else seps+=(""); fi
      cs=$((i + 1))
    fi
  done
  local c nc=${#starts[@]}
  for ((c = 0; c < nc; c++)); do
    CW=(); CF=()
    local rt=() rf=() rx=()
    for ((i = ${starts[$c]}; i < ${ends[$c]}; i++)); do
      case "${T[$i]}" in
        W)
          cg_nl3 "${X[$i]}"; tx="$CG_NL"
          case "${F[$i]}" in
            *c*|*b*) subq_skip "$tx" ;;
            *s*)
              # A substitution the guard can compute is replaced by its output.
              subst_word "$tx"
              if [ "$SW_LEFT" -eq 0 ]; then
                local swf="${F[$i]//s/}" sww
                for sww in "${SW[@]}"; do CW+=("$sww"); CF+=("${swf:--}"); done
                continue
              fi
              ;;
          esac
          CW+=("$tx"); CF+=("${F[$i]}")
          ;;
        R)
          cg_nl3 "${X[$i]}"; tx="$CG_NL"
          case "${F[$i]}" in
            *c*|*b*) subq_skip "$tx" ;;
            *s*)
              subst_word "$tx"
              if [ "$SW_LEFT" -eq 0 ] && [ ${#SW[@]} -eq 1 ]; then
                local srf="${F[$i]//s/}"
                rt+=("${O[$i]}"); rf+=("${srf:--}"); rx+=("${SW[0]}")
                continue
              fi
              ;;
          esac
          rt+=("${O[$i]}"); rf+=("${F[$i]}"); rx+=("$tx")
          ;;
      esac
    done
    # Standard input for this command: a heredoc or herestring, or text that
    # an earlier pipeline stage prints (echo/printf words, heredoc bodies).
    STDIN_KIND=""; STDIN_TEXT=""
    for ((i = 0; i < ${#rt[@]}; i++)); do
      case "${rt[$i]}" in
        '<<'|'<<-') STDIN_KIND=script; STDIN_TEXT="${HB[$hb_next]:-}"; hb_next=$((hb_next + 1)) ;;
        '<<<') STDIN_KIND=script; STDIN_TEXT="${rx[$i]}" ;;
      esac
    done
    if [ -z "$STDIN_KIND" ] && [ $c -gt 0 ] && [ -n "$pipe_text" ]; then
      case "${seps[$((c - 1))]}" in '|'|'|&') STDIN_KIND=pipe; STDIN_TEXT="$pipe_text" ;; esac
    fi
    # What this stage hands to the next one. Computed before analyze_simple,
    # which may overwrite CW.
    local next_pipe=""
    [ "$STDIN_KIND" = "script" ] && next_pipe="$STDIN_TEXT"
    if [ ${#CW[@]} -gt 0 ]; then
      case "${CW[0]##*/}" in
        echo|printf)
          local pj="" ps=""
          for ((i = 1; i < ${#CW[@]}; i++)); do pj="$pj$ps${CW[$i]}"; ps=" "; done
          next_pipe="$next_pipe$pj"
          ;;
      esac
    fi
    for ((i = 0; i < ${#rt[@]}; i++)); do
      case "${rt[$i]}" in
        '<'|'<>') check_word "${rx[$i]}" "${rf[$i]}" "$CUR_CWD" ;;
        '<&') case "${rx[$i]}" in -|[0-9]|[0-9][0-9]) ;; *) check_word "${rx[$i]}" "${rf[$i]}" "$CUR_CWD" ;; esac ;;
      esac
    done
    if [ ${#CW[@]} -gt 0 ]; then
      analyze_simple 0 ${#CW[@]} "$depth"
    fi
    case "${seps[$c]}" in
      '|'|'|&') pipe_text="$pipe_text$next_pipe" ;;
      *) pipe_text="" ;;
    esac
  done
  STDIN_KIND=""; STDIN_TEXT=""
  # cd inside $(...) or a subshell does not leak out; top level keeps it.
  [ "$depth" -eq 0 ] || CUR_CWD="$saved_cwd"
}

PRESCAN_DONE=0
case "$CMD" in *'$('*|*'`'*) prescan "$CMD" 0; PRESCAN_DONE=1 ;; esac
analyze_cmd "$CMD" 0 "$PAYLOAD_CWD"
exit 0
