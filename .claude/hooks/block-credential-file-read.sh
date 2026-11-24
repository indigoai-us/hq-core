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
#     upstream-pin.env (non-secret pin file, exact basename),
#     .env.<name>.example|sample|template, example.env, *.example.env,
#     *.sample.env, *.template.env, *.schema.env, *.dist.env, *.d.ts and *.md
#   backup and editor copies of all of the above: name~ name.bak name.orig
#   name.old name.swp name.swo name.save name.tmp name.N name.bak.* and the
#   vim swap form .name.swp
#
# Read tool: .tool_input.file_path is normalized (~, $HOME, ${HOME},
# relative to the payload cwd, `.`/`..`) and symlinks are resolved.
# On Windows (Git Bash, MSYS, Cygwin) a backslash is also a separator:
# every path and cwd is folded to slashes, a \\?\ or \\.\ prefix is
# removed, trailing dots and spaces on a segment are removed, and a drive
# path (C:\x, C:/x) is checked as the MSYS path /c/x. A drive-relative path
# (C:x) is also checked against the cwd. On any other host a backslash stays
# a literal character.
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
# get the same check. So does the environment of an interpreter, or of an awk
# program that reads ENVIRON: a NAME=value prefix (also after env), an
# exported value (export, declare -x, local -x, export NAME before or after
# the assignment, NAME+=, printf -v NAME, every assignment after set -a)
# that names a credential file, *.env names included
# (F=/srv/app/.env python3 -c "open(os.environ['F'])").
# In code, a *.env name counts when a quote closes the string after it
# ('/srv/app/prod.env'); .envrc always counts.
# Path forms: ~, ~user, $HOME, ${HOME}, absolute, relative to the cwd (cd and
# pushd are followed), quoted, after `--`, brace expansion, globs, variables
# assigned in the same command.
#
# Allowed on credential files (no contents reach the transcript):
#   grep -c / -l / -L / -q, rg --files, the safe commands above,
#   (except a recursive grep, rg or ag whose file-name filter selects
#   credential files: grep -rl --include=.env, rg -g '.env', also with
#   rg --files, ag -G / --file-search-regex. It is blocked with a message,
#   because hidden or git-ignored files can drop out of its results without
#   a warning; list them with find <dir> -name .env instead.)
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
# bash 5.2+ turns on patsub_replacement: an unquoted & in the replacement of
# ${v/pat/rep} stands for the matched text. The guard never wants that, and
# with it the SAFE_TMP_VARS scan put the match back and looped until the hook
# timeout on `a&&T=$(mktemp)&&...` (issue #1750). Older bash has no such
# option, so the error is ignored.
shopt -u patsub_replacement 2>/dev/null || true

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

# Wall-clock budget for the Bash check (feedback_d7a993c8). Each simple
# command and substitution costs a parse, so a long inline script ran the
# guard for 54 s, close to its 60 s registry timeout and well past the master
# hook's time budget. The analysis stops at this budget and blocks, so the
# guard fails closed with a message that says what to do instead of being
# killed with no verdict. HQ_CREDENTIAL_GUARD_BUDGET_SECONDS may lower the
# budget (tests use 1 s); it cannot raise it. SECONDS is reset so an inherited
# value cannot move the start.
CG_BUDGET_MAX=20
CG_BUDGET="${HQ_CREDENTIAL_GUARD_BUDGET_SECONDS:-$CG_BUDGET_MAX}"
case "$CG_BUDGET" in ''|*[!0-9]*|0) CG_BUDGET=$CG_BUDGET_MAX ;; esac
[ "$CG_BUDGET" -le "$CG_BUDGET_MAX" ] || CG_BUDGET=$CG_BUDGET_MAX
SECONDS=0
cg_budget_check() {
  [ "$SECONDS" -lt "$CG_BUDGET" ] \
    || block "the credential guard could not finish checking this long command within ${CG_BUDGET}s. Put the commands in a script file and run that file instead of passing them inline"
}

H="${HOME:-}"
[ -n "$H" ] || H="/nonexistent-home"
# Squeeze repeated slashes (TMPDIR ends in "/" on macOS) so HOME compares
# equal to normalized operand paths.
while case "$H" in *//*) true ;; *) false ;; esac; do H="${H%%//*}/${H#*//}"; done
[ "$H" = "/" ] || H="${H%/}"

# 1 when this hook runs under Git Bash, MSYS or Cygwin, where a backslash is
# a directory separator. On macOS and Linux it is a literal byte and the
# Windows folding below is skipped.
CG_WIN_HOST=0
case "${OSTYPE:-}" in
  msys*|cygwin*|win32*) CG_WIN_HOST=1 ;;
esac
if [ "$CG_WIN_HOST" = 0 ]; then
  case "${MSYSTEM:-}" in
    MINGW*|MSYS*|CYGWIN*|UCRT*|CLANG*) CG_WIN_HOST=1 ;;
  esac
fi
# Prefix of a drive in the shell's own spelling: /c on Git Bash and MSYS,
# /cygdrive/c on Cygwin.
CG_WIN_DRIVE_ROOT=""
case "${OSTYPE:-}" in cygwin*) CG_WIN_DRIVE_ROOT="/cygdrive" ;; esac
case "${MSYSTEM:-}" in CYGWIN*) CG_WIN_DRIVE_ROOT="/cygdrive" ;; esac
# A word that starts with a drive letter and a colon (C:x, 'C:/x').
CG_WIN_DRIVE_WORD_RE='(^|[^A-Za-z0-9_])[A-Za-z]:'
# cg_win_drive_word <text>: 0 when the text has a drive word, also after
# quotes are removed, so C"":x, "C":x, 'C':x, C":"x and C$'':x count. Only
# called on Windows, where bash is 4 or later.
cg_win_drive_word() {
  local t="$1"
  [[ "$t" =~ $CG_WIN_DRIVE_WORD_RE ]] && return 0
  case "$t" in *[\"\']*) ;; *) return 1 ;; esac
  t="${t//\$\'/}"
  t="${t//\$\"/}"
  t="${t//\'/}"
  t="${t//\"/}"
  [[ "$t" =~ $CG_WIN_DRIVE_WORD_RE ]]
}

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
    # Known non-secret pin file (tag name, S3 key, sha256), matched by exact basename.
    upstream-pin.env) r=1 ;;
    # Per-environment templates (.env.local.example), TypeScript declarations
    # (.env.d.ts) and docs (.env.md) hold no values.
    .env.*.example|.env.*.sample|.env.*.template|*.d.ts|*.md) r=1 ;;
    # Template files whose last suffix is .env (config.example.env).
    example.env|*.example.env|*.sample.env|*.template.env|*.schema.env|*.dist.env) r=1 ;;
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
      # hq secrets cache: every file in it is a secret value.
      */.hq/secrets-cache/*) r=0 ;;
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
    */.ssh|*/.aws|*/.docker|*/.gem|*/.config/gh|*/.hq/secrets-cache) r=0 ;;
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
    */.ssh|*/.ssh/*|*/.aws|*/.aws/*|*/.docker|*/.docker/*|*/.gem|*/.gem/*|*/.config|*/.config/gh|*/.config/gh/*|*/.hq|*/.hq/secrets-cache|*/.hq/secrets-cache/*) r=0 ;;
  esac
  [ "$nc" -eq 1 ] || shopt -u nocasematch
  return $r
}

# cg_win_fold <path> -> CG_WIN_P. Windows only. Backslashes become slashes,
# a \\?\ \\?\UNC\ or \\.\ prefix is removed, and trailing dots and spaces
# are removed from each segment (Windows opens .npmrc. as .npmrc). An NTFS
# stream suffix (name::$DATA, name:$DATA, name:s:$DATA, dir::$INDEX_ALLOCATION)
# is removed, since it opens the file or directory itself. A drive
# path becomes the shell's spelling: C:/x and C: become /c/x and /c
# (/cygdrive/c/x on Cygwin). A
# drive-relative C:x becomes /c/x; cg_drive_relative also checks it against
# the cwd. An administrative share //host/c$/x becomes /c/x. "." and ".."
# are kept for norm_path.
CG_WIN_P=""
cg_win_fold() {
  local p="$1" seg rest d
  local out=()
  p="${p//\\//}"
  case "$p" in
    //[?.]/[Uu][Nn][Cc]/*) p="//${p:8}" ;;
    //[?.]/*) p="${p:4}" ;;
  esac
  # An administrative share (//host/c$/x) opens drive C of that host. The
  # host may be this machine under any name, so it is checked as C:/x.
  case "$p" in
    //[!/]*/[A-Za-z]\$|//[!/]*/[A-Za-z]\$/*)
      rest="${p#//*/}"
      case "$rest" in
        [A-Za-z]\$|[A-Za-z]\$/*) p="${rest:0:1}:${rest:2}" ;;
      esac
      ;;
  esac
  case "$p" in
    [A-Za-z]:*)
      lc_word "${p:0:1}"
      d="$LCW"
      rest="${p:2}"
      rest="${rest#/}"
      if [ -n "$rest" ]; then p="${CG_WIN_DRIVE_ROOT:-}/$d/$rest"; else p="${CG_WIN_DRIVE_ROOT:-}/$d"; fi
      ;;
  esac
  rest="$p/"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    rest="${rest#*/}"
    case "$seg" in
      ''|'.'|'..') out+=("$seg"); continue ;;
      *[!.\ ]*) ;;
      *) out+=('.'); continue ;;
    esac
    case "$seg" in
      *::\$*|*:[!:]*:\$*|*:\$[Dd][Aa][Tt][Aa]*|*:\$[Ii][Nn][Dd][Ee][Xx]_*|*:\$[Ii]30*)
        seg="${seg%%:*}"
        [ -n "$seg" ] || continue
        ;;
    esac
    while [ -n "$seg" ]; do
      case "$seg" in
        '.'|'..') break ;;
        *' '|*.) seg="${seg%?}" ;;
        *) break ;;
      esac
    done
    [ -n "$seg" ] || continue
    out+=("$seg")
  done
  local IFS=/
  CG_WIN_P="${out[*]}"
}

# cg_drive_relative <path> <cwd>: Windows only. C:x (no separator after the
# colon) is x in the current directory of drive C. Check x against the cwd;
# norm_path checks the /c/x spelling.
cg_drive_relative() {
  [ "${CG_WIN_HOST:-0}" = 1 ] || return 0
  local p="${1//\\//}" cwd="$2" rest
  case "$p" in
    [A-Za-z]:/*|[A-Za-z]:) return 0 ;;
    [A-Za-z]:*) ;;
    *) return 0 ;;
  esac
  rest="${p:2}"
  norm_path "$rest" "$cwd"
  cg_check_np
}

# cg_win_root_rel <path> <cwd> -> CG_ALT. Windows only. A path with one
# leading backslash (\Users\me), or one leading slash and a backslash later
# (/Users\me), starts at the root of the current drive, so
# Windows programs and the MSYS runtime read it as C:\Users\me when the cwd
# is on C:. norm_path reads it as the MSYS root (/Users/me); CG_ALT is the
# drive reading (/c/Users/me), with drive C when the cwd is not on a drive.
# Empty for any other path.
CG_ALT=""
cg_win_root_rel() {
  CG_ALT=""
  [ "${CG_WIN_HOST:-0}" = 1 ] || return 0
  case "$1" in
    '\\'*|'\/'*) return 0 ;;
    '\'*) ;;
    /[!/]*'\'*) ;;
    *) return 0 ;;
  esac
  local d=c rest
  cg_win_fold "$2"
  case "$CG_WIN_P" in
    "${CG_WIN_DRIVE_ROOT:-}"/[A-Za-z]|"${CG_WIN_DRIVE_ROOT:-}"/[A-Za-z]/*)
      rest="${CG_WIN_P#"${CG_WIN_DRIVE_ROOT:-}"/}"
      d="${rest%%/*}"
      ;;
  esac
  norm_path "$d:$1" "$2"
  # A drive path is a Windows path, so ".." stops at the drive root.
  CG_ALT="${NP_W:-$NP}"
}

# cg_root_relative <path> <cwd>: check the drive reading of a root-relative
# Windows path (see cg_win_root_rel).
cg_root_relative() {
  cg_win_root_rel "$1" "$2"
  [ -z "$CG_ALT" ] || check_abs "$CG_ALT"
}

# cg_check_path <path> <cwd>: normalize and check one path. On Windows a
# drive-relative or root-relative spelling is checked both ways.
cg_check_path() {
  cg_drive_relative "$1" "$2"
  cg_root_relative "$1" "$2"
  norm_path "$1" "$2"
  cg_check_np
}

# cg_win_scan_cmd <command> <cwd>: Windows only. The shell parser below
# treats an unquoted backslash as an escape and drops it, so
# C:\work\.ssh\id_rsa reaches the operand checks as C:work.sshid_rsa.
# Check each unquoted word that holds a backslash as a path as well. Quoted
# text keeps its backslashes and is checked by the operand checks.
cg_win_scan_cmd() {
  [ "${CG_WIN_HOST:-0}" = 1 ] || return 0
  local rest="$1" cwd="$2" chunk q w nf=0
  case "$rest" in *\\*) ;; *) return 0 ;; esac
  case "$-" in *f*) nf=1 ;; esac
  local words=()
  while [ -n "$rest" ]; do
    chunk="${rest%%[\"\']*}"
    case "$chunk" in
      *\\*)
        local IFS=$' \t\n;|&()<>`'
        set -f
        # shellcheck disable=SC2206 # word splitting on IFS is the point.
        words=($chunk)
        [ "$nf" = 1 ] || set +f
        unset IFS
        for w in ${words[@]+"${words[@]}"}; do
          case "$w" in *\\*) cg_check_path "$w" "$cwd" ;; esac
        done
        ;;
    esac
    [ "${#chunk}" -lt "${#rest}" ] || break
    rest="${rest:${#chunk}}"
    q="${rest:0:1}"
    rest="${rest:1}"
    case "$rest" in
      *"$q"*) rest="${rest#*"$q"}" ;;
      *) break ;;
    esac
  done
}

# norm_path <path> <cwd> -> NP (absolute, lexical . / .. / // cleanup), and
# NP_W on Windows (see below).
NP=""
NP_W=""
norm_path() {
  local p="$1" cwd="$2" u rest
  if [ "${CG_WIN_HOST:-0}" = 1 ]; then
    cg_win_fold "$p"
    p="$CG_WIN_P"
    cg_win_fold "$cwd"
    cwd="$CG_WIN_P"
  fi
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
  # On Windows ".." stops at the drive root (C:\..\Users is C:\Users), while
  # the MSYS runtime walks a POSIX path past its mount (/c/../c/Users is
  # /c/Users). NP is the MSYS reading. NP_W is the Windows reading when it
  # differs and is empty otherwise. keep is the number of leading segments
  # that spell the drive (/c, /cygdrive/c).
  local keep=0 clamped=0
  NP_W=""
  if [ "${CG_WIN_HOST:-0}" = 1 ]; then
    case "$p" in
      "${CG_WIN_DRIVE_ROOT:-}"/[A-Za-z]|"${CG_WIN_DRIVE_ROOT:-}"/[A-Za-z]/*)
        keep=1
        [ -z "${CG_WIN_DRIVE_ROOT:-}" ] || keep=2
        ;;
    esac
  fi
  local seg out=() outw=() rest_p="$p/"
  while [ -n "$rest_p" ]; do
    seg="${rest_p%%/*}"
    rest_p="${rest_p#*/}"
    case "$seg" in
      ''|.) ;;
      ..)
        [ ${#out[@]} -gt 0 ] && unset "out[$((${#out[@]} - 1))]"
        if [ "$keep" -gt 0 ]; then
          if [ ${#outw[@]} -gt "$keep" ]; then
            unset "outw[$((${#outw[@]} - 1))]"
          else
            clamped=1
          fi
        fi
        ;;
      *) out+=("$seg"); [ "$keep" -eq 0 ] || outw+=("$seg") ;;
    esac
  done
  local IFS=/
  if [ ${#out[@]} -eq 0 ]; then
    NP="/"
  else
    NP="/${out[*]}"
  fi
  if [ "$clamped" = 1 ]; then
    NP_W="/${outw[*]}"
    [ "$NP_W" != "$NP" ] || NP_W=""
  fi
}

# cg_check_np: check_abs on NP and, on Windows, on NP_W (see norm_path).
cg_check_np() {
  local n="$NP" w="$NP_W"
  [ -z "$w" ] || check_abs "$w"
  check_abs "$n"
}

# cg_win_readings <path> <cwd> -> CG_RDS: Windows only. The readings of one
# word other than norm_path's NP and NP_W: the drive-root reading of a
# root-relative path (cg_win_root_rel) and the cwd readings of a
# drive-relative C:x (cg_drive_relative). Empty off Windows.
CG_RDS=()
cg_win_readings() {
  CG_RDS=()
  [ "${CG_WIN_HOST:-0}" = 1 ] || return 0
  cg_win_root_rel "$1" "$2"
  [ -z "$CG_ALT" ] || CG_RDS+=("$CG_ALT")
  local p="${1//\\//}"
  case "$p" in
    [A-Za-z]:/*|[A-Za-z]:) ;;
    [A-Za-z]:*)
      norm_path "${p:2}" "$2"
      CG_RDS+=("$NP")
      [ -z "$NP_W" ] || CG_RDS+=("$NP_W")
      ;;
  esac
  cg_win_slash_alt "$1" "$2"
  [ -z "$CG_ALT2" ] || CG_RDS+=("$CG_ALT2")
}

# cg_win_file_url <text after file:> -> CG_FU. Windows only (callers check
# CG_WIN_HOST). curl on Windows opens a file URL as a drive or UNC path:
# file:///C:/x, file:///C|/x, file://localhost/C:/x, file://127.0.0.1/C:/x
# and the one-slash file:/C:/x are C:/x, and so is file://C:/x (curl reads
# a drive letter after file:// as the path, not a host); file://host/share/x
# with any other host is the UNC path //host/share/x, which cg_win_fold
# reads (an administrative share //host/c$/x is C:/x). Text with no slash
# after file: is returned unchanged.
CG_FU=""
cg_win_file_url() {
  local r="$1" h p
  case "$r" in
    //*)
      r="${r:2}"
      # A '|' in a case pattern must be quoted; [:|] would open a class.
      case "$r" in
        [A-Za-z]: | [A-Za-z]:[/\\]* | [A-Za-z]'|' | [A-Za-z]'|'[/\\]*) r="/$r" ;;
      esac
      case "$r" in
        */*) h="${r%%/*}"; p="/${r#*/}" ;;
        *) h="$r"; p="" ;;
      esac
      case "$h" in
        '' | [Ll][Oo][Cc][Aa][Ll][Hh][Oo][Ss][Tt] | 127.0.0.1) r="$p" ;;
        *) r="//$h$p" ;;
      esac
      ;;
  esac
  case "$r" in
    /[A-Za-z]:*) r="${r:1}" ;;
    /[A-Za-z]'|'*) r="${r:1:1}:${r:3}" ;;
  esac
  CG_FU="$r"
}

# cg_win_slash_alt <path> <cwd> -> CG_ALT2. Windows only. A native Windows
# program given /x without MSYS path conversion (Cygwin, MSYS_NO_PATHCONV)
# opens it at the root of the cwd's drive (C:\x). The MSYS reading stays
# NP; this reading is only checked, never used as the shell's cwd. A /x
# with a backslash is handled by cg_win_root_rel. Empty otherwise.
CG_ALT2=""
cg_win_slash_alt() {
  CG_ALT2=""
  [ "${CG_WIN_HOST:-0}" = 1 ] || return 0
  case "$1" in
    *\\*) return 0 ;;
    /[!/]*) ;;
    *) return 0 ;;
  esac
  cg_win_root_rel "\\${1#/}" "$2"
  CG_ALT2="$CG_ALT"
}

if [ "$CG_WIN_HOST" = 1 ]; then
  case "$H" in
    *\\*|[A-Za-z]:*) norm_path "$H" "/"; H="$NP" ;;
  esac
fi


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

CRED_WORD_RE='npmrc|netrc|pypirc|yarnrc|git-credentials|\.gem|\.docker|\.aws|\.ssh|id_(rsa|dsa|ecdsa|ed25519)|gh/hosts|\.env|credentials|secrets-cache'
# Also wake for home references and recursive readers: `grep -r token ~`
# reaches credential files without naming one.
PREFILTER_RE="${CRED_WORD_RE}|identity|config\\.json|hosts\\.y|(^|[^a-z])(cd|pushd)([^a-z]|$)|[*?[{]|~|home|(^|[^a-z])(rg|ag|ack|rsync|scp)([^a-z]|$)|(^|[[:space:]])-[A-Za-z]*r|--recursive|--archive|(xargs|parallel|-exec|-ok).*git.*(show|cat-file|archive)|cat-file|alias\\.|git[^;&|]*[[:space:]](archive|grep)([[:space:]]|$)|(^|[^a-z])read([^a-z]|$).*git|git[^;&|]*[[:space:]]-L|git[^;&|]*[[:space:]](show|diff|difftool|format-patch|diff-tree|diff-index|diff-files|fast-export|reflog|stash|bundle)([[:space:]]|$)|git[^;&|]*[[:space:]](log|whatchanged)[^;&|]*[[:space:]]-(p|u|U|c|-patch|-unified|-cc|-word-diff|-color-words)|git[^;&|]*[[:space:]](log|show|diff|whatchanged)([[:space:]]+-[^[:space:];&|]*)*[[:space:]]+([^-[:space:];&|:][^[:space:];&|:]*([[:space:];&|]|$)|:)"
CG_SCREEN_RE="${CRED_WORD_RE}|identity|config\\.json|hosts\\.y"

# Git subcommands the guard knows. git runs a built-in before an alias of the
# same name, so only another word can be an alias (git x HEAD:cfg/$f with
# alias.x=show); git_unknown_sub sends such a command to the full check, which
# resolves the alias (git_alias_value).
GIT_KNOWN_SUBS=" add am apply archive bisect blame branch cat-file check-attr check-ignore checkout cherry-pick clean clone commit config count-objects describe diff fetch for-each-ref format-patch fsck gc grep hash-object help init log ls-files ls-remote ls-tree merge merge-base mv name-rev notes pull push range-diff rebase reflog remote reset restore rev-list rev-parse revert rm shortlog show show-ref sparse-checkout stash status submodule switch symbolic-ref tag update-ref var version whatchanged worktree annotate bundle cherry checkout-index commit-tree credential diff-files diff-index diff-tree difftool fast-export lfs maintenance mergetool mktag mktree prune read-tree repack replace request-pull rerere show-branch subtree update-index verify-commit verify-tag write-tree "
GIT_SUB_RE='(^|[^[:alnum:]_.-])git[[:space:]]+(.*)$'
GIT_OPT_RE='^-[^[:space:]]*[[:space:]]+(.*)$'
GIT_OPTARG_RE='^(-C|-c|--git-dir|--work-tree|--namespace|--config-env)[[:space:]]+[^[:space:]]+[[:space:]]+(.*)$'
GIT_WORD_RE='^([^[:space:];&|)]+)'
git_unknown_sub() { # <command>: 0 when a git word is followed by an unknown subcommand
  local rest="$1" w
  while [[ "$rest" =~ $GIT_SUB_RE ]]; do
    rest="${BASH_REMATCH[2]}"
    while :; do
      if [[ "$rest" =~ $GIT_OPTARG_RE ]]; then rest="${BASH_REMATCH[2]}"
      elif [[ "$rest" =~ $GIT_OPT_RE ]]; then rest="${BASH_REMATCH[1]}"
      else break; fi
    done
    [[ "$rest" =~ $GIT_WORD_RE ]] || continue
    w="${BASH_REMATCH[1]}"
    case "$GIT_KNOWN_SUBS" in *" $w "*) ;; *) return 0 ;; esac
  done
  return 1
}

# Credential basenames and directory names a split word can rebuild
# (cg_split_cred). CG_SPLIT_DIR_NAMES holds names that are credentials only
# inside one directory, as <dir>:<name>. .env.* names are checked by
# cg_split_env.
CG_SPLIT_NAMES=(.npmrc .netrc _netrc .pypirc .yarnrc .yarnrc.yml .yarnrc.yaml
  .git-credentials .env .envrc id_rsa id_dsa id_ecdsa id_ed25519 id_ecdsa_sk
  id_ed25519_sk identity .ssh .aws .docker .gem .config gh)
CG_SPLIT_DIR_NAMES=(.aws:credentials .aws:config .gem:credentials
  .docker:config.json gh:hosts.yml gh:hosts.yaml)
CG_SPLIT_ALLOWED=(.env.example .env.sample .env.template .env.schema .env.dist .pub)

# Bash 3.2 runs ${text//pattern/replacement} in time proportional to the
# number of matches times the length of the text: under a UTF-8 locale a 4 KB
# word of 4,090 $ references took about 3 s per substitution (about 10 times
# less under C, still quadratic), and the pre-pass runs several of them, so
# one such command took 25 s on a laptop and over 30 s on a CI runner. Bash 4
# and later are linear there and keep the plain expansions. On bash 3.2 a text
# over CG_SPLIT_SUB_MAX characters goes through field splitting, or one tr or
# sed process where field splitting cannot be used (bash 3.2 does not split on
# $'\001', its internal quoting byte), with LC_ALL=C set for that process
# only. Each gives the same bytes as the expansion it replaces, in linear time.
# Bash 3.2's ${//} ignores nocasematch, so the case-sensitive tr and sed match
# it there.
CG_SPLIT_SLOW_SUB=0
[ "${BASH_VERSINFO[0]}" -lt 4 ] && CG_SPLIT_SLOW_SUB=1
CG_SPLIT_SUB_MAX=256
CG_SPLIT_ALLOWED_SED=()
for _cg_a in "${CG_SPLIT_ALLOWED[@]}"; do
  CG_SPLIT_ALLOWED_SED+=(-e "s/${_cg_a//./\\.}//g")
done
# The names the full check removes before its CRED_ANY test, in its order.
CG_FULL_ALLOWED=(.env.example .env.sample .env.template .env.schema .env.dist upstream-pin.env .pub)
CG_FULL_ALLOWED_SED=()
for _cg_a in "${CG_FULL_ALLOWED[@]}"; do
  CG_FULL_ALLOWED_SED+=(-e "s/${_cg_a//./\\.}//g")
done
unset _cg_a

# cg_split_long <text>: 0 when <text> takes the bash 3.2 linear path.
cg_split_long() {
  [ "$CG_SPLIT_SLOW_SUB" = 1 ] && [ ${#1} -gt "$CG_SPLIT_SUB_MAX" ]
}

# cg_split_glob <text> -> CG_G: every \001 turned into *. Same value as
# ${text//$'\001'/*}.
CG_G=""
cg_split_glob() {
  if ! cg_split_long "$1"; then
    CG_G="${1//$'\001'/*}"
    return 0
  fi
  case "$1" in *$'\001'*) ;; *) CG_G="$1"; return 0 ;; esac
  # Up to 1,024 characters: the expansion on 256-character pieces, each
  # bounded, which costs less than starting tr (about 4 ms). A piece never
  # splits a character, and \001 is one byte in every locale.
  if [ ${#1} -le 1024 ]; then
    local s="$1" c i=0 n=${#1}
    CG_G=""
    while [ $i -lt $n ]; do
      c="${s:$i:256}"
      CG_G="$CG_G${c//$'\001'/*}"
      i=$((i + 256))
    done
    return 0
  fi
  # The trailing x keeps trailing newlines from being dropped. If tr fails
  # (pipefail is set), the slow expansion gives the value instead.
  if CG_G="$(printf '%sx' "$1" | LC_ALL=C tr '\001' '*' 2>/dev/null)"; then
    CG_G="${CG_G%x}"
  else
    CG_G="${1//$'\001'/*}"
  fi
}

# cg_split_lit <glob> -> CG_L: the glob with every * and ? removed. Same value
# as ${glob//[*?]/}.
CG_L=""
cg_split_lit() {
  if ! cg_split_long "$1"; then
    CG_L="${1//[*?]/}"
    return 0
  fi
  local old_ifs="$IFS" parts
  IFS='*?'
  set -f
  # shellcheck disable=SC2206
  parts=($1)
  set +f
  IFS=""
  CG_L="${parts[*]-}"
  IFS="$old_ifs"
}

# cg_split_unallow <text> [full] -> CG_UA: every allowed .env template word
# and .pub removed, in CG_SPLIT_ALLOWED order. Same value as the loop
# for a in "${CG_SPLIT_ALLOWED[@]}"; do t="${t//$a/}"; done.
# With "full", the list is CG_FULL_ALLOWED (the full check's CRED_ANY test,
# which also allows upstream-pin.env), in that order.
CG_UA=""
cg_split_unallow() {
  local t="$1" a hit=0 words sedargs
  if [ "${2:-}" = full ]; then
    words=("${CG_FULL_ALLOWED[@]}")
    sedargs=("${CG_FULL_ALLOWED_SED[@]}")
  else
    words=("${CG_SPLIT_ALLOWED[@]}")
    sedargs=("${CG_SPLIT_ALLOWED_SED[@]}")
  fi
  if ! cg_split_long "$t"; then
    for a in "${words[@]}"; do t="${t//$a/}"; done
    CG_UA="$t"
    return 0
  fi
  for a in "${words[@]}"; do
    case "$t" in *"$a"*) hit=1; break ;; esac
  done
  if [ "$hit" = 1 ]; then
    # sed works line by line; no allowed word holds a newline, so removing
    # them per line gives the same text. sed ends its output with a newline
    # and the x keeps the text's own trailing newlines; both are taken off.
    # If sed fails, the slow expansions give the value instead.
    if CG_UA="$(printf '%s\n' "$t" | LC_ALL=C sed "${sedargs[@]}" 2>/dev/null && printf x)"; then
      CG_UA="${CG_UA%x}"
      CG_UA="${CG_UA%$'\n'}"
      return 0
    fi
    for a in "${words[@]}"; do t="${t//$a/}"; done
  fi
  CG_UA="$t"
}

# cg_split_cred <raw command>: return 0 when a word that holds an unknown
# variable, substitution or ANSI-C escape could expand to a credential name,
# as in ~/.npm"$F"rc or .e"$F"nv. CRED_WORD_RE only sees credential words
# written out whole, so a name split around a variable passed (an unset F
# expands to nothing). cg_split_mark turns every $ reference and every
# $'\x..' escape into a wildcard, quotes are then removed, brace expansions
# ({a,b}) become wildcards, and every path segment (split on / = : , @, with
# a leading short option such as -f removed) that mixes wildcards with at
# least two literal characters is matched against the names above, backup
# suffixes removed too.
# Not split names: a segment that is only wildcards ("$F"), or has one
# literal character ("$a-$b", "$f"s); a plain $stem.ext ("$f.yml") outside a
# credential directory; and a directory-specific name ("$D"/config"$E")
# whose directory is only a variable. In those the variable supplies the
# whole credential word, the case CRED_WORD_RE leaves to the later checks.
# When it returns 0 the full check also stops trusting values assigned
# earlier in the command (expand_vars): (F=x); cat .np${F}mrc reads .npmrc.
cg_split_cred() {
  case "$1" in *'$'*) ;; *) return 1 ;; esac
  local nc=0 r=1 d
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  # Empty the cg_split_dir_is cache (its answers depend on nocasematch).
  CG_SPLIT_DC_N=0
  # Pass 1: the ${...} expansion is a wildcard (its value is unknown). Pass 2
  # (CG_SPLIT_DEF=1): a ${VAR:-WORD} / ${VAR:=WORD} expands to its literal
  # WORD when the variable is unset, so WORD is marked in place of the
  # wildcard. An unset variable is the attacker's to choose, so either
  # reading is possible; the union of the two passes covers both.
  for d in 0 1; do
    CG_SPLIT_DEF=$d
    CG_SPLIT_DEPTH=0
    CG_SPLIT_WORK=0
    if ! cg_split_mark "$1"; then
      r=0
    else
      cg_split_check && r=0
    fi
    [ "$r" -eq 0 ] && break
    case "$1" in *'${'*) ;; *) break ;; esac
  done
  CG_SPLIT_DEF=0
  [ "$nc" -eq 1 ] || shopt -u nocasematch
  return $r
}

# cg_split_check: CG_SM is marked; return 0 when it names a credential. A
# credential word revealed by decoding ($'\x6e') is matched directly; an
# allowed .env template word is removed first so it is not a false hit.
cg_split_check() {
  local t
  cg_strip_q "$CG_SM"
  cg_split_unallow "$CG_SQ"
  t="$CG_UA"
  [[ "$t" =~ $CRED_WORD_RE ]] && return 0
  cg_split_scan "$CG_SQ"
}

# cg_split_mark <raw text> -> CG_SM: every $ reference replaced by \001,
# read on the raw text so a closing quote ends a variable name ("$A"pmrc is
# \001pmrc). ${...} is matched to its closing brace across nesting. In
# $'...' each backslash escape is a wildcard (not decoded here) and the
# other characters stay; $"..." is its text; a lone $ stays.
# Returns 1 (the caller fails closed) on an unterminated ${, or a ${...} or
# $'...' longer than the scan limits.
# Linear: field splitting on $, bounded scans, output joined from chunks.
CG_SM=""
CG_SPLIT_DEF=0
CG_SPLIT_DEPTH=0
CG_SPLIT_WORK=0
CG_SPLIT_ANSI_RE="^(([^'\\\\]|\\\\.)*)'(.*)\$"
CG_SPLIT_UUC_RE='\\(u[0-9A-Fa-f]{0,4}|U[0-9A-Fa-f]{0,8}|c.?)'
# cg_ansi_decode <$'...' body> -> CG_AD: the real characters, so a credential
# name hidden in ANSI-C escapes ($'\x2e\x65\x6e\x76' = .env) is seen. \u \U
# \c are blanked to the sentinel first (bash 3.2 printf does not decode them
# and a wildcard still matches when one sits inside a name); the rest (\xHH,
# octal, \n \t \\ \' ...) decode the same on bash 3.2 and 5 with one printf.
# A body over 1024 chars is never a basename; it collapses to one wildcard so
# the pre-pass stays bounded.
CG_AD=""
cg_ansi_decode() {
  local b="$1" sb sent=$'\001'
  if [ ${#b} -gt 1024 ]; then CG_AD="$sent"; return; fi
  while [[ "$b" =~ $CG_SPLIT_UUC_RE ]]; do b="${b/"${BASH_REMATCH[0]}"/$sent}"; done
  sb="${b//%/%%}"
  printf -v CG_AD "$sb" 2>/dev/null || CG_AD="$b"
}

# cg_split_default <${...} body> -> CG_DEF, CG_HASDEF=1 when the body is a
# ${VAR:-WORD} / ${VAR-WORD} / ${VAR:=WORD} / ${VAR=WORD} form, whose WORD is
# the literal value when VAR is unset. Other operators (:+ :? # % / ^ , and
# substrings ${VAR:n:m}) have no unset-literal, so CG_HASDEF stays 0.
CG_DEF=""
CG_HASDEF=0
cg_split_default() {
  CG_HASDEF=0
  if [[ "$1" =~ ^([A-Za-z_][A-Za-z0-9_]*|[-@*#?$!0-9])(:-|:=|-|=)(.*)$ ]]; then
    CG_DEF="${BASH_REMATCH[3]}"
    CG_HASDEF=1
  fi
}


# cg_brace_end <text> [<offset>] -> BE: index of the } that closes the { at
# position 0, honoring nesting and \{ \} \\ escapes, or -1 within the first
# 512 characters. Backslash pairs are blanked to a same-length placeholder
# first, so indices still line up with the input and an escaped brace is not
# counted. Bounded so a long or unbalanced ${ cannot run the hook long.
# Incremental: with an <offset>, only text[offset..511] is scanned and the
# nesting depth carries over in BD from the previous call on the same text,
# so the caller that joins one $ piece at a time scans each character once
# (offset 0 starts at depth 0). The scan jumps from brace to brace, so its
# cost is the number of braces, not the length of the text. Rescanning the
# whole joined text one character at a time on every join made a 200-deep
# ${A:-${B:-...}} nest take about 20 s on a CI runner.
BE=-1
BD=0
cg_brace_end() {
  local off="${2:-0}" t pre k
  [ "$off" -gt 0 ] || BD=0
  BE=-1
  [ "$off" -lt 512 ] || return 0
  t="${1:$off:$((512 - off))}"
  t="${t//\\?/@@}"
  k=$off
  while :; do
    pre="${t%%[\{\}]*}"
    [ "${#pre}" -lt "${#t}" ] || return 0
    k=$((k + ${#pre}))
    case "${t:${#pre}:1}" in
      '{') BD=$((BD + 1)) ;;
      *) BD=$((BD - 1)); if [ "$BD" -eq 0 ]; then BE=$k; return 0; fi ;;
    esac
    t="${t:$((${#pre} + 1))}"
    k=$((k + 1))
  done
}

cg_split_mark() {
  local old_ifs="$IFS" parts p q o n out buf w wf wn acc name ok b sent=$'\001' be saved dmark off d
  # bash 3.2 duplicates a literal $'\001' inside array+=( ... ); a variable
  # does not, so every sentinel below is "$sent".
  IFS='$'
  set -f
  # shellcheck disable=SC2206
  parts=($1x)
  set +f
  IFS="$old_ifs"
  n=${#parts[@]}
  parts[n - 1]="${parts[n - 1]%x}"
  # Bash 3.2 arrays are linked lists: reading ${a[$i]} walks from the first
  # element and a+=(x) walks to the last, so indexing or appending to an
  # array with one entry per $ took seconds on a 60 KB command. Here the
  # pieces are read once in order (for ... in), a piece waits in the small
  # window w until CG_SPLIT_LOOK pieces after it are known (the most a ${
  # join can read ahead, see below), and the output is gathered in a short
  # string buf that moves to the array out in chunks. The pieces and their
  # order are the same as an indexed walk over parts.
  # $1 is no longer needed. Clearing it keeps each cg_split_mark_piece call
  # from growing with the command length under bash 3.2 (measured: the loop
  # was about 1.5 times slower at 128 KB with $1 still set).
  set --
  out=()
  buf="${parts[0]}"
  w=()
  wf=0
  wn=0
  for q in "${parts[@]:1}"; do
    w[wn]="$q"
    wn=$((wn + 1))
    while [ $((wn - wf)) -gt "$CG_SPLIT_LOOK" ]; do
      cg_split_mark_piece || return 1
    done
  done
  while [ "$wf" -lt "$wn" ]; do
    cg_split_mark_piece || return 1
  done
  [ -n "$buf" ] && out+=("$buf")
  IFS=""
  # shellcheck disable=SC2124 # ${a[@]+...} only guards an empty array; [*] joins.
  CG_SM="${out[@]+"${out[*]}"}"
  IFS="$old_ifs"
  return 0
}

# A ${ join reads ahead only while the joined text is at most
# CG_SPLIT_JOIN_MAX characters, and each joined piece adds at least one ($),
# so it reads at most CG_SPLIT_JOIN_MAX pieces past the ${ piece. The window
# keeps more than that; it is derived from the limit so the two stay in step.
CG_SPLIT_JOIN_MAX=512
CG_SPLIT_LOOK=$((CG_SPLIT_JOIN_MAX + 88))

# cg_split_mark_piece: mark the piece at the front of cg_split_mark's window
# (w[wf]) and drop it, with any pieces a ${...} joined. Uses the caller's
# locals. Returns 1 when the work budget runs out.
cg_split_mark_piece() {
  p="${w[$wf]}"
  unset "w[$wf]"
  wf=$((wf + 1))
  case "$p" in
    '{'*)
      # ${...} parameter expansion. Find its matching } (cg_brace_end). A
      # $ inside it (${F:-$G}) was split off, so when the } is not in this
      # piece the next piece is joined and the search repeats. The join
      # stops once the unclosed text holds a shell separator: then the { is
      # quoted or inert (echo '${'; cat ~/.np"$F"mrc), the } found later
      # belongs to another word, and swallowing it would hide a split name
      # after it. A quote alone does not stop the join: a real default can
      # hold one (${F:-m"$G"}rc). On the bail the $ is a lone wildcard and
      # the piece is kept literal, so later pieces are still scanned (wf is
      # unchanged; d is a lookahead).
      acc="$p"
      d=$wf
      ok=0
      off=0
      while :; do
        # Each brace scan is bounded; this budget bounds their number
        # across the whole command, so a deeply nested ${A:-${B:-...}}
        # cannot run the scan for seconds. The full check blocks brace
        # nesting over 6 levels anyway, so giving up here changes no
        # verdict; fail closed (return 1 -> the caller treats it as a hit).
        CG_SPLIT_WORK=$((CG_SPLIT_WORK + 1))
        [ "$CG_SPLIT_WORK" -gt 4000 ] && return 1
        # Only the text joined since the last pass is scanned: the brace
        # depth carries over (cg_brace_end offset), and the earlier text
        # was already checked for a separator.
        cg_brace_end "$acc" "$off"
        [ "$BE" -ge 0 ] && { ok=1; break; }
        case "${acc:$off}" in *[" "$'\t'$'\n'";|&<>()"]*) break ;; esac
        [ "$d" -lt "$wn" ] || break
        [ ${#acc} -le "$CG_SPLIT_JOIN_MAX" ] || break
        off=${#acc}
        acc="$acc\$${w[$d]}"
        d=$((d + 1))
      done
      if [ "$ok" = 1 ]; then
        # The joined pieces are consumed.
        while [ "$wf" -lt "$d" ]; do
          unset "w[$wf]"
          wf=$((wf + 1))
        done
        be=$BE
        dmark="$sent"
        if [ "$CG_SPLIT_DEF" = 1 ]; then
          # ${VAR:-WORD}: when VAR is unset the expansion is WORD, so mark
          # WORD (its own $ refs become wildcards) in place of the wildcard.
          cg_split_default "${acc:1:$((be - 1))}"
          # Recurse into the default, but cap the depth: marking a default
          # re-runs cg_split_mark, and a deeply nested ${A:-${B:-...}} would
          # otherwise run the hook for seconds. Beyond the cap the default
          # is a wildcard, the conservative reading (an anchored credential
          # name still matches). The hook fails closed on a timeout anyway,
          # so this only keeps a crafted nest from stalling the command.
          # The recursive call has its own locals; this call's are back
          # when it returns.
          if [ "$CG_HASDEF" = 1 ] && [ "$CG_SPLIT_DEPTH" -lt 24 ]; then
            saved="$CG_SM"
            CG_SPLIT_DEPTH=$((CG_SPLIT_DEPTH + 1))
            if cg_split_mark "$CG_DEF"; then dmark="$CG_SM"; else dmark="$sent"; fi
            CG_SPLIT_DEPTH=$((CG_SPLIT_DEPTH - 1))
            CG_SM="$saved"
          fi
        fi
        o="$dmark${acc:$((be + 1))}"
      else
        o="$sent$p"
      fi
      ;;
    "'"*)
      acc="${p#\'}"
      # The body ends at the first ' not escaped with a backslash.
      if [[ "$acc" =~ $CG_SPLIT_ANSI_RE ]]; then
        b="${BASH_REMATCH[1]}"
        acc="${BASH_REMATCH[3]}"
        # Decode the escapes to real characters so a credential name spelled
        # in ANSI-C ($'\x2e\x65\x6e\x76' = .env) is seen.
        cg_ansi_decode "$b"
        o="$CG_AD$acc"
      else
        o="$sent$acc"
      fi
      ;;
    '"'*) o="$p" ;;
    [A-Za-z_]*)
      name="${p%%[!A-Za-z0-9_]*}"
      o="$sent${p#"$name"}"
      ;;
    '') o="$sent" ;;
    [0-9@*#?!-]*) o="$sent${p:1}" ;;
    # $(...): the body is a command, not part of the word, so a space
    # keeps it apart. COMPUTED_PATH sends the word itself to the full
    # check.
    '('*) o="$sent ${p:1}" ;;
    *) o="\$$p" ;;
  esac
  buf="$buf$o"
  if [ ${#buf} -gt 256 ]; then
    out+=("$buf")
    buf=""
  fi
  return 0
}

# cg_split_env <glob>: the glob (wildcards from variables/substitutions) can
# expand to a .env-class credential. The wildcards can stand for any text, so
# each one is tried as empty and as the letters a .env name needs (the dot,
# "env", a per-environment suffix), and is_env_name decides. This catches the
# variable landing anywhere in the name: .e"$F"nv, x.e"$F"nv (-> *.env),
# .e"$F"nv.local, prod."$E"nv and prod"$E"env (both -> prod.env). A template
# name (.env.example) is not a credential, so is_env_name rejects it.
# "$name".test.ts stays allowed: no filler makes *.test.ts a .env name.
cg_split_env() {
  if cg_split_long "$1"; then
    cg_split_env_long "$1"
    return
  fi
  local c f g="${1//\?/*}" prev=""
  # Collapse runs of wildcards to one, so a single filler can stand for the
  # whole unknown run (a split can emit adjacent wildcards). The pattern and
  # replacement are unquoted: bash 3.2 keeps quotes in ${v//'x'/'y'} literal.
  # The replacement is a bare *: bash 3.2 keeps the backslash of a \*
  # replacement, which turned ** into \* there, so x.e"$A$B"nv gave the
  # candidate x.e\nv and passed while bash 4 and later blocked it.
  while [ "$g" != "$prev" ]; do prev="$g"; g="${g//\*\*/*}"; done
  for f in "" . e n v env rc local production development; do
    c="${g//\*/$f}"
    is_env_name "$c" && return 0
  done
  return 1
}

# cg_split_env_long <glob>: cg_split_env for a long glob on bash 3.2 (the only
# caller), the same candidates built in linear time: every run of wildcards
# becomes one *, as the collapse loop in cg_split_env does, so both lengths
# of glob give the same candidates and the same decision.
# The glob is split on * and ? (each ? is a * there); an empty inner field
# means two wildcards in a row. Each candidate is the collapsed glob with
# every * turned into the filler, joined from its *-separated fields.
cg_split_env_long() {
  local old_ifs="$IFS" parts seq tail c f i k q
  IFS='*?'
  set -f
  # shellcheck disable=SC2206
  parts=($1x)
  set +f
  IFS="$old_ifs"
  k=$((${#parts[@]} - 1))
  parts[k]="${parts[k]%x}"
  # The fields are read in order (for ... in) and the collapsed glob is
  # gathered in a short string moved to seq in chunks: bash 3.2 indexes and
  # appends to an array by walking it, which is quadratic over thousands of
  # fields. Empty pieces are left out of the joins below: bash 3.2 turns an
  # empty element of "${a[*]}" (IFS empty) into its internal \177 marker.
  seq=()
  c="${parts[0]}"
  i=0
  for q in "${parts[@]:1}"; do
    i=$((i + 1))
    # An empty inner field is one more wildcard in the current run.
    [ -z "$q" ] && [ $i -lt $k ] && continue
    c="$c*$q"
    if [ ${#c} -gt 256 ]; then
      seq+=("$c")
      c=""
    fi
  done
  [ -n "$c" ] && seq+=("$c")
  IFS=""
  # shellcheck disable=SC2124 # ${a[@]+...} only guards an empty array; [*] joins.
  c="${seq[@]+"${seq[*]}"}x"
  IFS='*'
  set -f
  # shellcheck disable=SC2206
  parts=($c)
  set +f
  IFS="$old_ifs"
  # The collapsed glob has no two * in a row, so every field after the first
  # is non-empty: the inner ones hold text, the last one keeps the x until
  # the candidate is built.
  tail=("${parts[@]:1}")
  for f in "" . e n v env rc local production development; do
    IFS=""
    # shellcheck disable=SC2124 # ${a[@]+...} only guards an empty array; [*] joins.
    if [ -z "$f" ]; then
      c="${parts[0]}${tail[@]+"${tail[*]}"}"
    else
      c="${parts[0]}${tail[@]+"${tail[*]/#/$f}"}"
    fi
    IFS="$old_ifs"
    c="${c%x}"
    is_env_name "$c" && return 0
  done
  return 1
}

# cg_split_dir_is <segment> <dir>...: the segment, written out or split
# around a variable, can be one of the directories. A segment that is only a
# variable is not counted.
# The answer for every directory the callers ask about (CG_SPLIT_DIRSET) is
# worked out once per segment, when cg_split_scan pushes the segment on its
# directory stack, and kept on a stack beside it. At each step the scan puts
# the parent and grandparent with their answers in CG_SPLIT_DC_* (every
# lookup is about one of those two), so a long parent reached again after
# many /$G/.. steps is not converted and matched again on every lookup,
# which on bash 3.2 meant one tr process each time. A lookup compares the
# segment with [ = ] (exact, unaffected by nocasematch); any other segment
# is matched directly. cg_split_cred clears the cache on entry.
CG_SPLIT_DIRSET=(.ssh .aws .docker .gem gh .config)
CG_SPLIT_DC_SEG1=""
CG_SPLIT_DC_CLS1=""
CG_SPLIT_DC_SEG2=""
CG_SPLIT_DC_CLS2=""
CG_SPLIT_DC_N=0
# cg_split_dir_cls <segment> [<glob>] -> CG_DC: " d1 d2 " for each directory
# in CG_SPLIT_DIRSET the segment can be ("" for a segment that is only a
# variable). <glob>, when given, is the segment's cg_split_glob value
# (the scan has it already), so it is not converted twice.
CG_DC=""
cg_split_dir_cls() {
  local d g
  CG_DC=" "
  case "$1" in *[!$'\001']*) ;; *) CG_DC=""; return 0 ;; esac
  if [ $# -ge 2 ]; then
    g="$2"
  else
    cg_split_glob "$1"
    g="$CG_G"
  fi
  for d in "${CG_SPLIT_DIRSET[@]}"; do
    # shellcheck disable=SC2053 # pattern match is intended.
    [[ "$d" == $g ]] && CG_DC="$CG_DC$d "
  done
}
cg_split_dir_is() {
  local seg="$1" d g cls
  shift
  if [ "$CG_SPLIT_DC_N" -ge 1 ] && [ "$seg" = "$CG_SPLIT_DC_SEG1" ]; then
    cls="$CG_SPLIT_DC_CLS1"
  elif [ "$CG_SPLIT_DC_N" -ge 2 ] && [ "$seg" = "$CG_SPLIT_DC_SEG2" ]; then
    cls="$CG_SPLIT_DC_CLS2"
  else
    cg_split_dir_cls "$seg"
    cls="$CG_DC"
  fi
  for d in "$@"; do
    case " ${CG_SPLIT_DIRSET[*]} " in
      *" $d "*)
        case "$cls" in *" $d "*) return 0 ;; esac
        ;;
      *)
        # Not a cached directory: match it directly.
        case "$seg" in *[!$'\001']*) ;; *) continue ;; esac
        cg_split_glob "$seg"
        g="$CG_G"
        # shellcheck disable=SC2053 # pattern match is intended.
        [[ "$d" == $g ]] && return 0
        ;;
    esac
  done
  return 1
}

# cg_split_cred_dir <parent> <grandparent>: a directory whose every file is
# a credential, or gh under .config.
cg_split_cred_dir() {
  cg_split_dir_is "$1" .ssh .aws .docker .gem && return 0
  cg_split_dir_is "$1" gh && cg_split_dir_is "$2" .config
}

# cg_split_scan <marked text with quotes removed>
CG_SPLIT_BRACE_RE='\{[^{}]*(,|\.\.)[^{}]*\}'
# The same test on the text after one {: up to the first } (the text holds
# no {), with a , or .. before that }.
CG_SPLIT_BRACE_FIELD_RE='^[^{}]*(,|\.\.)[^{}]*\}'

# cg_split_braces <long word> -> CG_BW: the brace loop of cg_split_scan for a
# long word on bash 3.2. Returns 1 where that loop gives up (more than 32
# groups). The loop replaces the first match of CG_SPLIT_BRACE_RE with \001
# by ${w/match/\001}, which on bash 3.2 costs time proportional to the
# square of the word. The loop test is unchanged (the regex on the whole
# word, which also fails as a whole on a word the locale cannot decode). The
# match is located by splitting the word on {: field i (i >= 1) starts a
# match exactly when it holds a } and the text before that } holds a , or
# .., so the first such field is the first match, and its offset is the sum
# of the field lengths before it. The word is cut there only when the text
# at that offset is the regex match; otherwise the original replacement
# runs. Fields are only measured, never joined (bash 3.2 turns an empty
# element of a "${a[*]}" join into its internal \177 marker).
CG_BW=""
cg_split_braces() {
  local bw="$1" g=0 old_ifs="$IFS" parts f i m hit at pre post
  while [[ "$bw" == *'{'*'}'* ]] && [[ "$bw" =~ $CG_SPLIT_BRACE_RE ]]; do
    [ $g -lt 32 ] || return 1
    m="${BASH_REMATCH[0]}"
    IFS='{'
    set -f
    # shellcheck disable=SC2206
    parts=($bw"x")
    set +f
    IFS="$old_ifs"
    hit=0
    i=0
    # at: offset of the { before the field being read.
    at=-1
    for f in "${parts[@]}"; do
      if [ $i -ge 1 ]; then
        if [[ "$f" =~ $CG_SPLIT_BRACE_FIELD_RE ]]; then
          hit=$i
          break
        fi
        at=$((at + 1 + ${#f}))
      else
        at=${#f}
      fi
      i=$((i + 1))
    done
    if [ "$hit" -ge 1 ] && [ "${bw:$at:${#m}}" = "$m" ]; then
      # An empty ${bw:off} is bash 3.2's internal \177 marker, so the cut
      # ends are taken only when they hold text.
      pre=""
      post=""
      [ "$at" -gt 0 ] && pre="${bw:0:$at}"
      [ $((at + ${#m})) -lt ${#bw} ] && post="${bw:$((at + ${#m}))}"
      bw="$pre"$'\001'"$post"
    else
      bw="${bw/"$m"/$'\001'}"
    fi
    g=$((g + 1))
  done
  CG_BW="$bw"
  return 0
}

# Index above the dirs stack in cg_split_scan; more than any segment count.
CG_SPLIT_DTOP=$((1 << 30))
cg_split_scan() {
  local old_ifs="$IFS" w seg prev prev2 pat p n d lit g top words=() segs=() pats=() dirs=() dcls=()
  IFS=$' \t;|&()<>\n'
  set -f
  # shellcheck disable=SC2206
  words=($1)
  set +f
  IFS="$old_ifs"
  for w in ${words[@]+"${words[@]}"}; do
    case "$w" in *$'\001'*) ;; *) continue ;; esac
    # Brace expansion picks one of its parts: .n{p,}"$F"mrc.
    if cg_split_long "$w"; then
      cg_split_braces "$w" || return 0
      w="$CG_BW"
    else
      g=0
      while [[ "$w" == *'{'*'}'* ]] && [[ "$w" =~ $CG_SPLIT_BRACE_RE ]]; do
        [ $g -lt 32 ] || return 0
        w="${w/"${BASH_REMATCH[0]}"/$'\001'}"
        g=$((g + 1))
      done
    fi
    IFS='/=:,@'
    set -f
    # shellcheck disable=SC2206
    segs=($w)
    set +f
    IFS="$old_ifs"
    # prev, prev2: the parent and grandparent segments. Empty and .
    # segments are skipped and .. goes back one (~/.config/gh/./x, gh//x,
    # gh/a/../x).
    # dirs is a stack kept at falling indices, newest first (top entries):
    # bash 3.2 finds an array element by walking from the lowest index, so
    # reading the newest of thousands of segments at the end of the array
    # made a long path quadratic; at the front it is one or two steps.
    # dcls beside it holds each segment's cg_split_dir_cls answer, worked
    # out once when the segment is pushed; CG_SPLIT_DC_* below hands the
    # parent's and grandparent's answers to cg_split_dir_is.
    dirs=()
    dcls=()
    top=0
    prev=""
    prev2=""
    CG_SPLIT_DC_N=0
    for seg in ${segs[@]+"${segs[@]}"}; do
      case "$seg" in
        ''|.) continue ;;
        ..)
          if [ "$top" -gt 0 ]; then
            unset "dirs[$((CG_SPLIT_DTOP - top))]" "dcls[$((CG_SPLIT_DTOP - top))]"
            top=$((top - 1))
          fi
          ;;
        *)
          case "$seg" in
            *$'\001'*)
              cg_split_glob "$seg"
              pat="$CG_G"
              case "$pat" in
                *[!*?]*) cg_split_seg "$seg" "$pat" "$prev" "$prev2" && return 0 ;;
                # Only a variable: any file in a credential directory.
                *) cg_split_cred_dir "$prev" "$prev2" && return 0 ;;
              esac
              ;;
            *)
              # A written-out name under a split directory:
              # .config/g"$F"/hosts.yml.
              case "$prev" in
                *$'\001'*)
                  for n in "${CG_SPLIT_DIR_NAMES[@]}"; do
                    # shellcheck disable=SC2053
                    [[ "${n#*:}" == "$seg" ]] && cg_split_dir_is "$prev" "${n%%:*}" && return 0
                  done
                  ;;
              esac
              ;;
          esac
          top=$((top + 1))
          dirs[CG_SPLIT_DTOP - top]="$seg"
          # A segment with a variable was converted above (pat).
          case "$seg" in
            *$'\001'*) cg_split_dir_cls "$seg" "$pat" ;;
            *) cg_split_dir_cls "$seg" "$seg" ;;
          esac
          dcls[CG_SPLIT_DTOP - top]="$CG_DC"
          ;;
      esac
      prev=""
      prev2=""
      CG_SPLIT_DC_CLS1=""
      CG_SPLIT_DC_CLS2=""
      if [ "$top" -gt 0 ]; then
        prev="${dirs[$((CG_SPLIT_DTOP - top))]}"
        CG_SPLIT_DC_CLS1="${dcls[$((CG_SPLIT_DTOP - top))]}"
      fi
      if [ "$top" -gt 1 ]; then
        prev2="${dirs[$((CG_SPLIT_DTOP - top + 1))]}"
        CG_SPLIT_DC_CLS2="${dcls[$((CG_SPLIT_DTOP - top + 1))]}"
      fi
      # An empty parent is only-variable-like: no directory (CLS "").
      CG_SPLIT_DC_SEG1="$prev"
      CG_SPLIT_DC_SEG2="$prev2"
      CG_SPLIT_DC_N=2
    done
  done
  return 1
}

# cg_split_seg <segment> <glob> <parent> <grandparent>: one segment that
# mixes wildcards and literal text.
cg_split_seg() {
  local pat="$2" prev="$3" prev2="$4" p n d lit pats=("$2")
  # An attached short option: -f.e"$F"nv.
  [[ "$pat" =~ ^-[A-Za-z0-9](.+)$ ]] && pats+=("${BASH_REMATCH[1]}")
  for p in "${pats[@]}"; do
    cg_split_lit "$p"
    lit="$CG_L"
    [ ${#lit} -ge 2 ] || continue
    if [[ "$p" =~ ^\*+\.[^.*?]+$ ]]; then
      # $stem.ext: a split name only inside a credential directory.
      cg_split_cred_dir "$prev" "$prev2" && return 0
      continue
    fi
    strip_backup "$p"
    set -- "$p"
    if [ -n "$SB" ] && [ "$SB" != "$p" ]; then
      set -- "$p" "$SB"
      [ "$SB_SWAP" -eq 1 ] && [ "${SB#.}" != "$SB" ] && set -- "$@" "${SB#.}"
    fi
    for p in "$@"; do
      cg_split_env "$p" && return 0
      for n in "${CG_SPLIT_NAMES[@]}"; do
        # shellcheck disable=SC2053 # pattern match is intended.
        [[ "$n" == $p ]] && return 0
      done
      for n in "${CG_SPLIT_DIR_NAMES[@]}"; do
        d="${n%%:*}"
        n="${n#*:}"
        # shellcheck disable=SC2053
        [[ "$n" == $p ]] || continue
        # The directory is this name's own, written out or split; a
        # directory that is only a variable is not a split name.
        cg_split_dir_is "$prev" "$d" && return 0
      done
    done
  done
  return 1
}

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

CG_ARITH_READY=0
if [ -f "${BASH_SOURCE[0]%/*}/bash-arith-subst-guard-lib.sh" ]; then
  . "${BASH_SOURCE[0]%/*}/bash-arith-subst-guard-lib.sh" && CG_ARITH_READY=1
fi

# cg_zglob <text>: 0 when the unquoted text has a zsh glob form: a ( ) group
# inside a word, ^ or # after a path character, or a group with no spaces at
# the start of a word that holds | or runs on into the word ((.n|x)pmrc). A quoted jq program such as
# 'map(. // "-")' is data. Each quoted span ('..', "..", $'..') becomes one
# placeholder character, so ~/.""(a|b) and $'.n'(p)mrc still count.
CG_ZGLOB_RE='[^[:space:]$<>=(|&;]\([^)]|[/.~_][^[:space:]]*[#^]|<[0-9]*-[0-9]*>|(^|[[:space:]<>])\([^)[:space:]]*(\||\)[^[:space:];&|)<>])'
# CG_ZMARK_RE: an unquoted ^ anywhere or a # inside a word. The tokenizer
# marks such a word z and check_word blocks it as a read operand, so the
# command needs the full check, but its variables stay what they are (a
# git revision "$sha"^ is not a computed path).
CG_ZMARK_RE='\^|[^[:space:]${#]#'
# cg_zglob <text> [regex]: the regex (default CG_ZGLOB_RE) matches the text
# with every quoted span replaced by one placeholder character.
cg_zglob() {
  local uq re="${2:-$CG_ZGLOB_RE}"
  [[ "$1" =~ $re ]] || return 1
  uq=$(printf '%s' "$1" | LC_ALL=C awk 'BEGIN { RS = "\001" } {
    n = length($0); o = ""; q = ""
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (q == "") {
        if (c == "\\") { o = o c substr($0, i + 1, 1); i++; continue }
        if (c == "\047" || c == "\"") { q = c; o = o "q"; continue }
        o = o c
      } else if (q == "\"" && c == "\\") { i++ }
      else if (c == q) { q = "" }
    }
    printf "%s", o
  }') || return 0
  [[ "$uq" =~ $re ]]
}

# cg_fast_allow: return 0 when the call can be allowed without the full
# check.
# cg_gsub <text>: 0 when zsh glob_subst can be on for a word or the
# command: $~name or ${~name}; the option name in any case with quotes,
# backslashes and underscores removed (zsh ignores case and underscores);
# setopt, unsetopt, emulate or options[...] anywhere (an option name can be
# built at run time: o=globsu; setopt ${o}bst); or set/zsh -o with a quoted
# or computed option name.
CG_GSUB_RE='\$\{?~|(^|[^A-Za-z0-9_])(setopt|unsetopt|emulate|options\[)|(^|[^A-Za-z0-9_])(set|zsh)[[:space:]][^;&|]*[-+]o[[:space:]]*[^;&|[:space:]]*[$`]'
cg_gsub() {
  [[ "$1" =~ $CG_GSUB_RE ]] && return 0
  local n
  n=$(printf '%s' "$1" | tr -d "_\\\\'\"" | tr '[:upper:]' '[:lower:]')
  case "$n" in *globsubst*) return 0 ;; esac
  return 1
}
# CG_GITCFG_RE: git configuration that can name a command or an alias given
# on the command line or through the environment.
CG_GITCFG_RE='[Ee][Xx][Tt]::|[Pp][Rr][Oo][Tt][Oo][Cc][Oo][Ll]|[Aa][Ll][Ii][Aa][Ss]\.|GIT_CONFIG|GIT_SSH|ASKPASS|PROXY|VISUAL|[Cc][Oo][Mm][Mm][Aa][Nn][Dd]|--config-env|[Pp][Aa][Gg][Ee][Rr]|[Ee][Dd][Ii][Tt][Oo][Rr]|[Ss][Ss][Hh][Cc][Oo][Mm][Mm][Aa][Nn][Dd]|[Tt][Ee][Xx][Tt][Cc][Oo][Nn][Vv]|[Ee][Xx][Tt][Ee][Rr][Nn][Aa][Ll]|[Pp][Rr][Oo][Gg][Rr][Aa][Mm]|[Hh][Ee][Ll][Pp][Ee][Rr]|[Ff][Ss][Mm][Oo][Nn][Ii][Tt][Oo][Rr]'
# git_cmd_key <config key>: 0 when git runs the key's value as a command or
# a git command line (alias.*, core.pager, *.textconv, credential.*, ...).
git_cmd_key() {
  local key
  key=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$key" in
    alias.*|pager.*|credential.*|gpg.*|core.pager|core.editor|core.sshcommand|core.fsmonitor|core.askpass|core.hookspath|core.gitproxy|sequence.editor|diff.external|interactive.difffilter|*.textconv|*.program|*command*|*.cmd|*.driver|*.clean|*.smudge|*.process|*.helper|*.editor|*.receivepack|*.uploadpack|*.packobjectshook|*.proxy) return 0 ;;
  esac
  return 1
}
# gc_quote <text> <flags> -> GQ: the word written so that analyze_cmd reads
# it back as one word with the same text. Glob, brace and variable parts
# that the flags mark stay live; every other character is escaped.
GQ=""
gc_quote() {
  local LC_ALL=C t="$1" f="$2" i c p="" out=""
  for ((i = 0; i < ${#t}; i++)); do
    c="${t:i:1}"
    case "$c" in
      [A-Za-z0-9/._,:@%+=-]) out="$out$c" ;;
      '*'|'?'|'['|']') case "$f" in *g*) out="$out$c" ;; *) out="$out\\$c" ;; esac ;;
      '{'|'}') case "$f" in *[bvu]*) out="$out$c" ;; *) out="$out\\$c" ;; esac ;;
      '$') case "$f" in *[vu]*) out="$out$c" ;; *) out="$out\\$c" ;; esac ;;
      '~') case "$p" in ''|=|:) out="$out$c" ;; *) out="$out\\$c" ;; esac ;;
      $'\001') out="$out$c" ;;
      $'\n') out="$out\"$c\"" ;;
      *) out="$out\\$c" ;;
    esac
    p="$c"
  done
  [ -n "$out" ] || out="''"
  GQ="$out"
}
cg_fast_allow() {
  [ "${HQ_CRED_GUARD_FASTPATH:-1}" != "0" ] || return 1
  # Every helper must be defined; a missing one would otherwise read as "no
  # match" and allow the call.
  declare -F cg_strip_q cg_unescape cg_parse cg_fast_scan cg_split_cred cg_split_check cg_split_mark cg_split_mark_piece cg_ansi_decode cg_split_default cg_split_scan cg_split_env cg_split_env_long cg_split_long cg_split_glob cg_split_lit cg_split_unallow cg_split_braces cg_split_dir_cls cg_split_dir_is cg_split_cred_dir cg_split_seg git_unknown_sub norm_path is_cred_path is_cred_dir is_cred_name_at is_env_name strip_backup >/dev/null 2>&1 || return 1
  [ ${#INPUT} -le 16384 ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  command -v realpath >/dev/null 2>&1 || return 1
  cg_fast_scan || return 1
  shopt -u nocasematch
  local cwd="$CG_CWD"
  [ -n "$cwd" ] || cwd="$PWD"
  # On Windows a backslash or a drive letter in the command or Read path can
  # name a credential path the checks below do not see; the full check
  # decides those. The cwd is folded to the spelling norm_path uses.
  if [ "${CG_WIN_HOST:-0}" = 1 ]; then
    case "$CG_CMD$CG_FILE" in *\\*) return 1 ;; esac
    case "$CG_FILE" in [A-Za-z]:*) return 1 ;; esac
    cg_win_drive_word "$CG_CMD" && return 1
    norm_path "$cwd" "/"
    cwd="$NP"
  fi
  case "$CG_TOOL" in
    Bash)
      [ -n "$CG_CMD" ] || return 0
      [ "$CG_ARITH_READY" = 1 ] || return 1
      hq_arith_guard_check "$CG_CMD" || return 1
      # Same computed-path rule as the full check (COMPUTED_PATH): a $(...)
      # or backtick body can build a credential name from neutral text
      # (`cat "workspace/$(echo c)redlink"`), so it always gets the full
      # analysis. Without this the fast path allowed what the full check
      # blocks (scope-guard-hotfix-security.test.sh, 14 cases).
      case "$CG_CMD" in *'$('*|*'`'*) return 1 ;; esac
      # An extglob group gets the full check, as COMPUTED_PATH does there.
      case "$CG_CMD" in *[?*+@!]'('*) return 1 ;; esac
      # zsh glob forms get the full check, as COMPUTED_PATH does there; the
      # fast path used to allow them on a home path or with cwd in HOME.
      cg_zglob "$CG_CMD" && return 1
      cg_zglob "$CG_CMD" "$CG_ZMARK_RE" && return 1
      # Revision searches and variables can select paths absent from the
      # command text. Strip quotes so sh"ow" cannot evade this prefilter.
      cg_strip_q "$CG_CMD"
      case "$CG_SQ" in *show*'$'*|*cat-file*'$'*|*:/*) return 1 ;; esac
      # zsh glob_subst and $~ (CG_GSUB in the full check), and git config
      # that names a command (git -c alias.x='!cat f' x) get the full check.
      cg_gsub "$CG_CMD" && return 1
      # Matched without case, as in the full check (nocasematch is on there),
      # so core.gitproxy and http.proxy keys are not missed.
      local fa_nc=0
      shopt -q nocasematch && fa_nc=1
      shopt -s nocasematch
      if [[ "$CG_CMD" =~ git|GIT ]] && [[ "$CG_CMD" =~ $CG_GITCFG_RE ]]; then
        [ "$fa_nc" -eq 1 ] || shopt -u nocasematch
        return 1
      fi
      [ "$fa_nc" -eq 1 ] || shopt -u nocasematch
      cg_strip_q "$CG_CMD" || return 1
      local st="$CG_SQ"
      # A git subcommand the guard does not know may be an alias of show,
      # cat-file, archive, grep or log; the full check resolves it. The
      # unquoted text is used so gi\t and "git" count.
      git_unknown_sub "$st" && return 1
      # Same split-name rule as the full check (SPLIT_CRED).
      cg_split_cred "$CG_CMD" && return 1
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
        if [ "${CG_WIN_HOST:-0}" = 1 ]; then
          case "$lw" in [Ff][Ii][Ll][Ee]:*) cg_win_file_url "${lw:5}"; lw="$CG_FU" ;; esac
        fi
        case "$lw" in file://*|FILE://*) lw="${lw#*://}" ;; *://*) continue ;; esac
        case "$lw" in *=*) lw="${lw#*=}" ;; esac
        [ -n "$lw" ] || continue
        if [ "${CG_WIN_HOST:-0}" = 1 ]; then
          cg_win_slash_alt "$lw" "$cwd"
          if [ -n "$CG_ALT2" ] && { [ -L "$CG_ALT2" ] || [ -e "$CG_ALT2" ]; }; then
            return 1
          fi
          norm_path "$lw" "$cwd"
          [ -z "$NP_W" ] || return 1
          lw="$NP"
        else
          case "$lw" in /*) ;; *) lw="$cwd/$lw" ;; esac
        fi
        if [ -L "$lw" ] || { [[ "$lw" == "$cwd"/*/* ]] && [ -e "$lw" ]; }; then
          return 1
        fi
      done
      return 0
      ;;
    Read)
      [ -n "$CG_FILE" ] || return 0
      # On Windows a slash-first path is also read at the root of the
      # cwd's drive (see the Read check below).
      if [ "${CG_WIN_HOST:-0}" = 1 ]; then
        case "$CG_FILE" in /[!/]*) return 1 ;; esac
      fi
      norm_path "$CG_FILE" "$cwd"
      [ -z "$NP_W" ] || return 1
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

# ---------------------------------------------------------------- Unicode fold
# A case-insensitive volume (APFS and HFS+ on macOS, NTFS on Windows) folds
# some non-ASCII letters to ASCII ones, so `cat ~/.aw<U+017F>/credentials`
# opens ~/.aws/credentials. Bash's nocasematch does not see that: under
# LC_ALL=C it compares bytes, and in UTF-8 locales towlower() leaves U+017F
# and the ligatures alone. The guard therefore also checks a folded copy of
# the payload.
#
# Fold rule (block-credential-file-read fold v1; the native guard in hq-cli
# must apply the same table). Every string value of the payload JSON,
# after JSON unescaping, has each code point replaced as follows; all others
# are kept:
#   U+00DF (sharp s) -> "ss"     U+1E9E (capital sharp s) -> "ss"
#   U+017F (long s)  -> "s"      U+212A (Kelvin sign)     -> "k"
#   U+0130 (I with dot above) -> "i"   U+0131 (dotless i) -> "i"
#   U+FB00 -> "ff"  U+FB01 -> "fi"  U+FB02 -> "fl"  U+FB03 -> "ffi"
#   U+FB04 -> "ffl" U+FB05 -> "st"  U+FB06 -> "st"
#   fullwidth letters and digits, and fullwidth . _ -
#     U+FF10..U+FF19, U+FF21..U+FF3A, U+FF41..U+FF5A,
#     U+FF0E, U+FF3F, U+FF0D -> code point - 0xFEE0 (0-9 A-Z a-z . _ -)
# The first eleven entries other than U+0130 and U+0131 are exactly the
# non-ASCII code points that a case-insensitive APFS volume resolves to an
# ASCII name (probed over U+0080..U+2FFFF). U+0130 and U+0131 fold to i in
# Turkish casing and on NTFS; fullwidth forms map to ASCII under NFKC and
# under Windows "best fit" code-page conversion. The existing
# case-insensitive matching (nocasematch) then applies to the result.
#
# Every fold produces only letters, digits, ".", "_" or "-". Other fullwidth
# punctuation is kept as it is: bash and zsh treat U+FF03 or U+FF02 as an
# ordinary word character, but folded to # or " it would turn the rest of the
# folded copy into a comment or a quoted string, so the folded copy would
# hide a read whose name only the folded copy recognizes
# (`true <U+FF03>; cat ~/.config/gh/ho<U+017F>ts.yml`).
#
# Decision: when folding changes the payload, the folded payload is checked
# first by a second run of this script; if it blocks, that block (exit 2 and
# its message) is the verdict. Otherwise the payload as sent is checked as
# before, and must pass too. The folded payload holds none of the folded
# code points, so the second run folds nothing and does not recurse.
# Payloads of plain printable ASCII with no \u escape cannot contain a
# folded code point and skip this step.
CG_FOLD_JQ='def fold_cp:
  if . == 223 or . == 7838 then [115, 115]
  elif . == 383 then [115]
  elif . == 8490 then [107]
  elif . == 304 or . == 305 then [105]
  elif . == 64256 then [102, 102]
  elif . == 64257 then [102, 105]
  elif . == 64258 then [102, 108]
  elif . == 64259 then [102, 102, 105]
  elif . == 64260 then [102, 102, 108]
  elif . == 64261 or . == 64262 then [115, 116]
  elif (. >= 65296 and . <= 65305) or (. >= 65313 and . <= 65338)
    or (. >= 65345 and . <= 65370) or . == 65294 or . == 65343 or . == 65293
    then [. - 65248]
  else [.] end;
def fold: [explode[] | fold_cp[]] | implode;
def fold_all: if type == "string" then fold
  elif type == "object" then map_values(fold_all)
  elif type == "array" then map(fold_all)
  else . end;
[inputs] as $docs
| if ($docs | length) != 1 then empty
  else $docs[0] as $o | ($o | fold_all) as $f
  | if $f == $o then empty else $f end
  end'
case "$INPUT" in
  *'\u'*|*[!' !"#$%&'\''()*+,./01234:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~56789-'$'\t\r\n']*)
    # A payload jq cannot read is blocked by the full check below.
    if CG_FOLDED=$(jq -nc "$CG_FOLD_JQ" 2>/dev/null <<<"$INPUT"); then
      if [ -n "$CG_FOLDED" ]; then
        "${BASH:-bash}" "${BASH_SOURCE[0]}" <<<"$CG_FOLDED"
        cg_fold_rc=$?
        case "$cg_fold_rc" in
          0) ;;
          2) exit 2 ;;
          *) block "credential guard cannot parse the tool call" ;;
        esac
      fi
    fi
    unset CG_FOLDED cg_fold_rc
    ;;
esac

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
# On Windows the cwd arrives as C:\work\proj. Fold it once to the
# spelling norm_path uses (/c/work/proj), so the cwd checks below and
# the link resolution see the directory the command runs in.
if [ "$CG_WIN_HOST" = 1 ]; then
  norm_path "$PAYLOAD_CWD" "/"
  PAYLOAD_CWD="$NP"
fi

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
  # On Windows the Read tool (Node) opens /x at the root of the cwd's
  # drive (C:\x), so that reading is checked too.
  if [ "${CG_WIN_HOST:-0}" = 1 ]; then
    case "$FP" in
      /[!/]*) cg_root_relative "\\${FP#/}" "$PAYLOAD_CWD" ;;
    esac
  fi
  cg_check_path "$FP" "$PAYLOAD_CWD"
  exit 0
fi

# ---------------------------------------------------------------- Bash tool

CMD="$VAL"
[ "$CG_ARITH_READY" = 1 ] || block "The arithmetic guard helper is missing; refresh the hook installation."
if ! hq_arith_guard_check "$CMD"; then
  hq_arith_guard_message
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "BLOCKED: Bash arithmetic check. $HQ_ARITH_GUARD_REASON." '{decision:"block",reason:$m}' || true
  fi
  exit 2
fi
# The arithmetic check above runs before any credential analysis; count its
# time against the same budget so a slow pass there also ends in a block.
cg_budget_check
[ -n "$CMD" ] || exit 0
cg_win_scan_cmd "$CMD" "$PAYLOAD_CWD"
# CRED_WORD_RE and PREFILTER_RE are defined above the fast path.

# Same value as ${CMD//[\"\'\\]/}, which is quadratic in bash 3.2 and took
# minutes on a large heredoc (the hook then timed out and failed closed).
cg_strip_q "$CMD"
STRIPPED="$CG_SQ"
# Computed neutral names can resolve to credential symlinks even when no
# credential word appears in the command. Analyze, never execute, the body.
COMPUTED_PATH=0
case "$CMD" in *'$('*|*'`'*) COMPUTED_PATH=1 ;; esac
# An extglob group can name a credential file with no credential word in the
# command (~/.!(x)pmrc), so it gets the full analysis too.
case "$CMD" in *[?*+@!]'('*) COMPUTED_PATH=1 ;; esac
# zsh globs (~/.(npmrc|x), ~/.npm^x, ~/.npmr#c, and the same forms on an
# absolute home path or relative to a cwd in HOME) can name a credential file
# with no credential word either (cg_zglob).
cg_zglob "$CMD" && COMPUTED_PATH=1
ZMARK=0
cg_zglob "$CMD" "$CG_ZMARK_RE" && ZMARK=1
# git show <ref>:<path> with a variable names a tree entry, not a file the
# name prefilter can match: `ls src | while read f; do git show "HEAD:src/$f"`
# carries no credential word. Treat it as computed so the full check runs and
# unknown variables are wildcards there.
case "$STRIPPED" in *show*'$'*|*cat-file*'$'*|*:/*) COMPUTED_PATH=1 ;; esac
# An unknown git subcommand may be an alias of a git object reader.
GIT_ALIAS_CAND=0
git_unknown_sub "$STRIPPED" && GIT_ALIAS_CAND=1
# The command can change what a command name runs. is_safe_cmd uses these:
#   CG_CMD_OVERRIDE=1  alias, hash or enable run as a command (zsh expands
#                      aliases, bash with expand_aliases), BASH_ENV/ENV or
#                      BASH_FUNC_ mentioned, or an assignment into the alias
#                      and command tables (BASH_ALIASES[, BASH_CMDS[, zsh
#                      aliases[, commands[, functions[): no name is trusted,
#                      so `alias ls=cat; ls ~/.npmrc` blocks;
#   CG_PATH_CHANGED=1  PATH or zsh path assigned (NAME=, NAME+=, NAME[,
#                      read/printf -v/for/declare/export/... naming it), or a
#                      copy, move, link or write into a bin directory: names
#                      that are programs on PATH (ls, stat, ...) are not
#                      trusted; builtins such as test, [ and echo still are.
#                      Reading $PATH is not a change.
# A function needs no flag: its body is analysed where it is defined, and an
# argument it reads ("$@", $1) is an unknown value there.
CG_CMD_OVERRIDE=0
CG_PATH_CHANGED=0
_cg_ov_re='(^|[;&|({!`'$'\n'']|then|do|else|builtin|command|eval)[[:space:]]*\\?(alias|hash|enable)([[:space:];&|)]|$)'
[[ "$STRIPPED" =~ $_cg_ov_re ]] && CG_CMD_OVERRIDE=1
# eval and source/. run text the guard does not see as commands here; it
# can define an alias or change PATH (`eval "$a ls=cat"`), so no name is
# trusted after either.
_cg_ov_re='(^|[;&|({!`'$'\n'']|then|do|else|builtin|command)[[:space:]]*\\?(eval|source|\.)([[:space:];&|)]|$)'
[[ "$STRIPPED" =~ $_cg_ov_re ]] && CG_CMD_OVERRIDE=1
# CG_ZSH_EXT: zsh extended globbing is turned on in the command, so a `~`
# inside a word is the exclusion operator (~/.npmrc~x names ~/.npmrc).
CG_ZSH_EXT=0
_cg_ov_re='extendedglob|extended_glob|EXTENDED_GLOB|EXTENDEDGLOB|setopt|emulate'
[[ "$STRIPPED" =~ $_cg_ov_re ]] && CG_ZSH_EXT=1
# zsh glob_subst: `$~name`, `${~name}`, `setopt globsubst` (any spelling,
# also set -o; see cg_gsub) and `emulate` (ksh and sh modes set it) make
# zsh glob the value of a variable, so a quoted or escaped ^ or # anywhere
# in the command can reach a reader as a glob (p='i#d_rsa'; cat $~p). The
# guard does not track which value reaches which word: a ^ or # anywhere
# in such a command blocks.
if cg_gsub "$CMD"; then
  case "$CMD" in
    *'^'*|*'#'*) block "a zsh glob_subst or \$~ expansion in a command with a ^ or # the credential guard cannot evaluate" ;;
  esac
fi
_cg_ov_re='(^|[^A-Za-z0-9_])(BASH_ENV|ENV|BASH_FUNC[A-Za-z0-9_%]*)([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])(BASH_ALIASES|BASH_CMDS|aliases|commands|functions)\['
[[ "$STRIPPED" =~ $_cg_ov_re ]] && CG_CMD_OVERRIDE=1
_cg_ov_re='(^|[^A-Za-z0-9_])(PATH|path)(\+?=|\[)|(^|[^A-Za-z0-9_])(read|mapfile|readarray|printf|for|select|getopts|declare|typeset|local|export|readonly|unset|eval|let)([[:space:]][^;&|]*)?[^A-Za-z0-9_$](PATH|path)([^A-Za-z0-9_]|$)'
[[ "$STRIPPED" =~ $_cg_ov_re ]] && CG_PATH_CHANGED=1
_cg_ov_re='(^|[^A-Za-z0-9_])(cp|mv|ln|install|tee|rsync|ditto|curl|wget)[[:space:]][^;&|]*bin|>[[:space:]]*[^[:space:];&|]*bin'
[[ "$STRIPPED" =~ $_cg_ov_re ]] && CG_PATH_CHANGED=1
unset _cg_ov_re
# A credential name split around a variable (~/.npm"$F"rc) names no
# credential word, so it is caught here instead (cg_split_cred).
SPLIT_CRED=0
cg_split_cred "$CMD" && SPLIT_CRED=1

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
      # Each pass removes one match; a cap keeps a scan that stops shrinking
      # from spinning until the hook timeout (issue #1750).
      [ "$_tmp_n" -le 256 ] || block "the credential guard could not finish its temp-variable scan (too many mktemp assignments)"
      _tmp_scan="${_tmp_scan/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]} ${BASH_REMATCH[5]}"}"
    done
    [ "$_tmp_n" -eq 1 ] || continue
    _tmp_read_re="\\\$(\\{${_tmp_name}\\}|${_tmp_name}([^A-Za-z0-9_]|\$))"
    _tmp_r=0
    while [[ "$_tmp_scan" =~ $_tmp_read_re ]]; do
      _tmp_r=$((_tmp_r + 1))
      [ "$_tmp_r" -le 4096 ] || block "the credential guard could not finish its temp-variable scan (too many reads)"
      _tmp_tail="${BASH_REMATCH[3]}"
      _tmp_scan="${_tmp_scan/"${BASH_REMATCH[0]}"/" ${_tmp_tail}"}"
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
# On Windows the word list below loses backslashes (STRIPPED drops them) and
# reads C:lnk as a name under the cwd, so a neutral link named that way
# would be missed. Those commands get the full analysis.
CG_WIN_FULL=0
if [ "$CG_WIN_HOST" = 1 ]; then
  case "$CMD" in *\\*) CG_WIN_FULL=1 ;; esac
  cg_win_drive_word "$CMD" && CG_WIN_FULL=1
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
    if [ "$CG_WIN_HOST" = 1 ]; then
      case "$lw" in [Ff][Ii][Ll][Ee]:*) cg_win_file_url "${lw:5}"; lw="$CG_FU" ;; esac
    fi
    case "$lw" in file://*|FILE://*) lw="${lw#*://}" ;; *://*) continue ;; esac
    case "$lw" in *=*) lw="${lw#*=}" ;; esac
    [ -n "$lw" ] || continue
    if [ "$CG_WIN_HOST" = 1 ]; then
      # The Windows ".." and native drive-root readings name other files.
      cg_win_slash_alt "$lw" "$PAYLOAD_CWD"
      _cg_lx="$CG_ALT2"
      norm_path "$lw" "$PAYLOAD_CWD"
      lw="$NP"
      for _cg_ly in "$NP_W" "$_cg_lx"; do
        if [ -n "$_cg_ly" ] && { [ -L "$_cg_ly" ] || [ -e "$_cg_ly" ]; }; then
          LINK_CANDS+=("$_cg_ly")
        fi
      done
    else
      case "$lw" in /*) ;; *) lw="$PAYLOAD_CWD/$lw" ;; esac
    fi
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
# git configuration that names a command (CG_GITCFG_RE) always gets the
# full analysis: the body can read a file with no credential word in the
# command (git -c alias.x='!cat id^x' x).
GITCFG=0
if [[ "$CMD" =~ git|GIT ]] && [[ "$CMD" =~ $CG_GITCFG_RE ]]; then GITCFG=1; fi
if [ "$GITCFG" -eq 0 ] && [ "$COMPUTED_PATH" -eq 0 ] && [ "$ZMARK" -eq 0 ] && [ "$GIT_ALIAS_CAND" -eq 0 ] && [ "$SPLIT_CRED" -eq 0 ] && [ "$CWD_IN_CRED" -eq 0 ] && [ "$LINK_HIT" -eq 0 ] && [ "$CG_WIN_FULL" -eq 0 ] && ! [[ "$STRIPPED" =~ $PREFILTER_RE ]]; then
  shopt -u nocasematch
  exit 0
fi
# CRED_ANY: a credential word remains after removing allowed names, or a
# word could expand to one (SPLIT_CRED). Unknown
# variables and substitutions are treated as wildcards only when it is set.
# cg_split_unallow gives the value of the loop
# for a in "${CG_FULL_ALLOWED[@]}"; do t="${t//$a/}"; done in linear time on
# bash 3.2 (the loop took about 50 s there on one 16 KB word of .pub under a
# UTF-8 locale).
cg_split_unallow "$STRIPPED" full
ALLOW_STRIPPED="$CG_UA"
CRED_ANY=0
if [[ "$ALLOW_STRIPPED" =~ $CRED_WORD_RE ]] || [ "$CWD_IN_CRED" -eq 1 ] || [ "$LINK_HIT" -eq 1 ] || [ "$COMPUTED_PATH" -eq 1 ] || [ "$SPLIT_CRED" -eq 1 ]; then
  CRED_ANY=1
fi
# CG_CRED_NAMED: the command itself names a credential word (CRED_ANY without
# the computed-path trigger, which every $(...) sets). An environment value
# the guard cannot resolve fails closed only then (env_check).
CG_CRED_NAMED=0
if [[ "$ALLOW_STRIPPED" =~ $CRED_WORD_RE ]] || [ "$CWD_IN_CRED" -eq 1 ] || [ "$LINK_HIT" -eq 1 ] || [ "$SPLIT_CRED" -eq 1 ]; then
  CG_CRED_NAMED=1
fi
shopt -u nocasematch

# Tokenizer. Output: one token per line, 4 tab fields, each field prefixed
# (f flags, o operator, x text) so no field is empty.
#   W f<flags> o- x<text>        word. flags: g glob, b brace, v variable,
#                                s substitution (\001 in text), c the
#                                substitution mentions a credential word,
#                                q quoted, u an unquoted expansion (variable,
#                                $(...) or backtick outside double quotes, so
#                                its value is word-split)
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
  return (y ~ /npmrc|netrc|pypirc|yarnrc|git-credentials|\.gem|\.docker|\.aws|\.ssh|id_(rsa|dsa|ecdsa|ed25519)|gh\/hosts|\.env|credentials|secrets-cache/)
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
    # A redirect does not change whether the next word is an argument.
    lastw = prelastw
  } else {
    print "W\tf" fs_ "\to-\tx" enc(w)
    # The function and for keywords count in command position: first word,
    # or after prefix keywords only ({ function f ( .. ); }, then for f (..)).
    if (allkw && w == "function") fnat = nwords + 1
    if (allkw && w ~ /^(for|foreach|select)$/) { forat = nwords + 1; forin = 0 }
    if (forat && w == "in" && nwords > forat) forin = 1
    if (allkw && !(w ~ /^(if|then|else|elif|do|while|until|time|!|\{|coproc)$/ || (w == "-p" && lastword == "time") || (w == "--" && lastword ~ /^(time|-p)$/))) allkw = 0
    if (!allkw && (cmdword == "" || cmdword ~ /^(sudo|doas|env|nohup|command|builtin|exec|nice|timeout|gtimeout|stdbuf|caffeinate)$/) && w !~ /^-/ && w !~ /^[A-Za-z_][A-Za-z0-9_]*=/ && w !~ /^[0-9.]+[smhd]?$/) cmdword = w
    lastw = 1; lastword = w
    nwords++; if (nwords == 1) firstword = w
  }
  w = ""; ws = 0; fs_ = ""
}
# notgroup(): a ( at the start of a word opens a subshell or a grouping,
# not a zsh glob group: after a keyword in command position (if (x), ! (x)),
# after the name in `function NAME ( body )`, inside [[ ]], after a test
# operator, and after `in` of case/for/select.
function notgroup() {
  # A keyword counts while every word before it in the command is a prefix
  # keyword too (if ! (x), time -p (x), else ! (x)).
  if (allkw && lastword ~ /^(if|then|else|elif|do|while|until|time|-p|--|!|\{|coproc)$/) return 1
  if (nwords == 1 && lastword ~ /^(\[\[|function)$/) return 1
  if (fnat && nwords == fnat + 1) return 1
  if (firstword == "[[") return 1
  if (lastword ~ /^(==|=|!=|=~)$/) return 1
  if (lastword == "in" && firstword ~ /^(case|for|select)$/) return 1
  return 0
}
# urlword(x): x is a network URL (http, https, ftp, ws, wss) with a host
# and no .. anywhere, and the command word is a tool that fetches URLs
# rather than reading local paths.
function urlword(x) {
  if (x !~ /^(https?|ftp|wss?):\/\/[A-Za-z0-9]/ || x ~ /\.\./) return 0
  return (cmdword ~ /^(curl|wget|xh|http|https|open)$/)
}
function op(o) {
  flushw()
  if (rop != "") { err("redirect without target"); rop = "" }
  print "O\tf-\to" o "\tx-"
  lastw = 0; nwords = 0; firstword = ""; allkw = 1; fnat = 0; forat = 0; forin = 0; cmdword = ""
}
function setredir(o) {
  if (ws && w ~ /^[0-9]+$/ && fs_ == "") { w = ""; ws = 0; fs_ = "" }
  flushw()
  if (rop != "") { err("redirect without target") }
  prelastw = lastw
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
  if (substr(inner, 1, 1) == "(") {
    inner = substr(inner, 2, length(inner) - 2)
    # $(( )) is arithmetic: ^ is xor and # a base (16#ff), not zsh globs.
    # With no nested substitution there is nothing for them to name.
    if (inner !~ /[$`<>]\(|`/) gsub(/[\^#]/, "+", inner)
  }
  emit_s(inner, "w")
  if (!inq) fs_ = fs_ "u"
  return k + 1
}
function sub_backtick(j,  k) {
  k = find_bt(j + 1)
  if (!k) { err("unterminated backtick"); return n + 1 }
  emit_s(substr(s, j + 1, k - j - 1), "w")
  if (!inq) fs_ = fs_ "u"
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
    if (!inq) fs_ = fs_ "u"
    return k + 1
  }
  if (c ~ /[A-Za-z_]/) {
    k = j + 1
    while (k <= n && a[k] ~ /[A-Za-z0-9_]/) k++
    w = w substr(s, j, k - j); ws = 1; fs_ = fs_ "v"
    if (!inq) fs_ = fs_ "u"
    return k
  }
  if (c ~ /[0-9@*#?$!-]/) {
    w = w "$" c; ws = 1; fs_ = fs_ "v"
    if (!inq) fs_ = fs_ "u"
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
  w = ""; ws = 0; fs_ = ""; rop = ""; nhd = 0; failed = 0; inq = 0; allkw = 1; fnat = 0; forat = 0; forin = 0; cmdword = ""
  i = 1
  while (i <= n && !failed) {
    c = a[i]
    if (c == " " || c == "\t") { flushw(); i++; continue }
    if (c == "\n") {
      flushw()
      if (rop != "") { err("redirect without target"); break }
      print "O\tf-\to" "NL" "\tx-"
      lastw = 0; nwords = 0; firstword = ""; allkw = 1; fnat = 0; forat = 0; forin = 0; cmdword = ""
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
      closed = 0; inq = 1
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
      inq = 0
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
        k = i + 2; t = ""; av = 0
        while (k <= n && a[k] != "'") {
          if (a[k] == "\\" && k + 1 <= n) {
            e = a[k + 1]
            if (e == "n") t = t "\n"; else if (e == "t") t = t "\t"
            else if (e == "\\" || e == "'" || e == "\"" || e == "?") t = t e
            else {
              # \xHH, \uHHHH, \UHHHHHHHH, octal \nnn, \cX and the other
              # escapes are not decoded: the character is unknown, so it
              # reads as an unknown variable (${?}), a wildcard once
              # expand_vars runs with CRED_ANY set. cg_split_cred sets it.
              k += 2
              if (e == "x") { m = 2 } else if (e == "u") { m = 4 } else if (e == "U") { m = 8 } else if (e == "c") { m = 1 } else { m = 0 }
              if (e ~ /[0-7]/) { m = 2; while (m > 0 && a[k] ~ /[0-7]/) { k++; m-- } }
              else if (e == "c") { if (k <= n && a[k] != "'") k++ }
              else { while (m > 0 && a[k] ~ /[0-9A-Fa-f]/) { k++; m-- } }
              t = t "${?}"; av = 1
              continue
            }
            k += 2; continue
          }
          t = t a[k]; k++
        }
        if (k > n) { err("unterminated quote"); break }
        w = w t; ws = 1; fs_ = fs_ "q"
        if (av) fs_ = fs_ "v"
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
    # zsh numeric glob <N-M> (<-> matches any number): one unknown part.
    if (c == "<" && match(substr(s, i), /^<[0-9]*-[0-9]*>/)) {
      emit_s("", "w")
      fs_ = fs_ "g"
      i += RLENGTH; continue
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
    # A glob group inside a word is one unknown part, like a substitution:
    # a read operand that holds one is never proved safe. That covers the
    # extglob groups ?(..) *(..) +(..) @(..) !(..) (extglob on from a previous
    # line or the user's shell) and zsh groups such as ~/.(npmrc|x) in a
    # word that has a path character (/ . ~ _). `f()`, `a=(..)`, `a+=(..)`
    # and code such as print(1) are not groups.
    if (c == "(" && ws && a[i + 1] != ")" && substr(w, length(w), 1) != "=" \
        && (substr(w, length(w), 1) ~ /[?*+@!]/ || w ~ /[\/.~_]/ || w == "")) {
      k = find_close(i + 1)
      if (!k) { err("unterminated glob group"); break }
      g = substr(s, i + 1, k - i - 1)
      if (substr(w, length(w), 1) ~ /[?*+@!]/) w = substr(w, 1, length(w) - 1)
      emit_s("", "w")
      if (credword(g)) fs_ = fs_ "c"
      fs_ = fs_ "g"
      i = k + 1; continue
    }
    # zsh extended glob: ^x negates the rest of the path segment and x#
    # repeats the character before it. Either makes the word unknown (the
    # user's zsh can have extendedglob on without a setopt in the command).
    # A group at the start of a word in argument or redirect position
    # (cat (.n|x)pmrc, cat < (.n)pmrc) is a zsh glob too: bash rejects the
    # syntax, zsh expands it. A ( after a keyword or test operator still
    # opens a subshell or a grouping.
    # zsh short for loop, for NAME (LIST) BODY: the list is expanded and the
    # body runs with NAME bound to each value. The guard does not model it,
    # so it fails closed. for (( .. )) is arithmetic and is not this form.
    if (c == "(" && rop == "" && forat && !forin && (nwords > forat || ws) && a[i + 1] != "(") {
      err("zsh short for loop"); break
    }
    if (c == "(" && !ws && a[i + 1] != ")" && (rop != "" || (lastw && !notgroup()))) {
      k = find_close(i + 1)
      if (!k) { err("unterminated glob group"); break }
      g = substr(s, i + 1, k - i - 1)
      emit_s("", "w")
      if (credword(g)) fs_ = fs_ "c"
      fs_ = fs_ "g"
      i = k + 1; continue
    }
    # zsh extended glob: an unquoted ^ (negation) anywhere in a word or a
    # # (repetition) inside a word marks the word z. check_word blocks a z
    # operand unless the command is git or an npm-family tool, whose
    # operands are revisions (HEAD^, v1#2) and version ranges. A ^ right
    # after @ (pkg@^1.2) and a URL given to a URL tool (curl
    # https://h/a#frag) are not marked. Any other word with :// is a path
    # when a folder like a: exists, so cat a://../i#d_rsa is marked.
    if (c == "^" && !urlword(w) && substr(w, length(w), 1) != "@") {
      fs_ = fs_ "z"; w = w c; ws = 1; i++; continue
    }
    if (c == "#" && ws && !urlword(w)) {
      fs_ = fs_ "z"; w = w c; i++; continue
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
# Aliases defined earlier in the same command (alias NAME=BODY): a later
# command named NAME is analysed as BODY followed by its arguments.
CG_ALIAS_N=()
CG_ALIAS_B=()
CG_ALIAS_SKIP=" "
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
  # A split credential name (SPLIT_CRED) does not trust earlier
  # assignments: a subshell, unset, a pipeline or a skipped && branch can
  # leave the variable empty when the read runs ((F=x); cat .np${F}mrc).
  for ((i = 0; SPLIT_CRED == 0 && i < ${#VAR_NAMES[@]}; i++)); do
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
      # Bash reads a range in base 10 and keeps a leading zero as padding
      # ({08..10} -> 08 09 10). $((08)) is an octal error that used to abort
      # the analysis and allow the call (issue #1749), so every value goes
      # through 10#. More than 18 digits could overflow: refuse it.
      local fs="${BASH_REMATCH[1]}" ts="${BASH_REMATCH[2]}" from to step=1 cnt=0 width=0 kp
      if [ ${#fs} -gt 18 ] || [ ${#ts} -gt 18 ]; then
        block "a numeric brace range too large for the credential guard to expand"
      fi
      from=$((10#${fs#-})); [ "${fs:0:1}" != "-" ] || from=$((0 - from))
      to=$((10#${ts#-})); [ "${ts:0:1}" != "-" ] || to=$((0 - to))
      if [[ "$fs" =~ ^-?0[0-9] ]] || [[ "$ts" =~ ^-?0[0-9] ]]; then
        width=${#fs}; [ ${#ts} -le "$width" ] || width=${#ts}
      fi
      [ "$from" -le "$to" ] || step=-1
      k=$from
      while [ $cnt -lt 64 ]; do
        if [ "$width" -gt 0 ]; then printf -v kp '%0*d' "$width" "$k"; else kp="$k"; fi
        work+=("$pre$kp$post"); cnt=$((cnt + 1))
        [ "$k" -eq "$to" ] && break
        k=$((k + step))
      done
    elif [[ "$body" =~ ^([A-Za-z])\.\.([A-Za-z])$ ]]; then
      # Letter ranges expand exactly, through every ASCII character between
      # the ends as bash does ({Z..a} includes [ \ ] ^ _ `). A single `?`
      # missed names such as ~/.np{m..m}rc.
      local lt='ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz' lpre li lto lstep=1
      lpre="${lt%%"${BASH_REMATCH[1]}"*}"; li=${#lpre}
      lpre="${lt%%"${BASH_REMATCH[2]}"*}"; lto=${#lpre}
      [ "$li" -le "$lto" ] || lstep=-1
      while :; do
        work+=("$pre${lt:$li:1}$post")
        [ "$li" -ne "$lto" ] || break
        li=$((li + lstep))
      done
    elif [[ "$body" =~ ^[^,]*\.\.[^,]*\.\.[^,]*$ ]]; then
      # A range with a step ({1..9..2}, {a..z..3}) is not expanded.
      block "a brace range with a step, which the credential guard does not expand"
    else
      work+=("$pre"$'\005'"$body"$'\006'"$post")
    fi
    if [ $((${#out[@]} + ${#work[@]})) -gt 64 ]; then break; fi
  done
  BR=()
  # The braces come from variables: bash 3.2 keeps the backslash of a \{ or
  # \} replacement, so cat l{x} was checked as l\{x\} there and a link named
  # l{x} to a credential file passed.
  local lb='{' rb='}'
  for cur in ${out[@]+"${out[@]}"} ${work[@]+"${work[@]}"}; do
    cur="${cur//$'\005'/$lb}"
    cur="${cur//$'\006'/$rb}"
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
  local text="$1" depth="$2" toks t fl op tx first=1 name="" sub="" last_s="" asg=0
  cg_budget_check
  [ "$depth" -le 6 ] || { SUBST_IMPURE=1; return; }
  toks=$(printf '%s' "$text" | LC_ALL=C awk "$AWK_PROG") || { SUBST_IMPURE=1; return; }
  while IFS=$'\t' read -r t fl op tx; do
    [ "$SECONDS" -lt "$CG_BUDGET" ] || cg_budget_check
    fl="${fl#f}"; op="${op#o}"; tx="${tx#x}"
    case "$t" in
      E) SUBST_IMPURE=1 ;;
      S) last_s="$tx"; cg_nl3 "$tx"; prescan "$CG_NL" $((depth + 1)) ;;
      O)
        # A pipeline or background stage that is only an assignment sets
        # nothing the next stage can see, so the listing it would name is
        # not what the later stage reads.
        case "$op" in '|'|'|&'|'&') [ "$asg" -eq 0 ] || SUBST_IMPURE=1 ;; esac
        first=1; name=""; asg=0
        ;;
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
          # An assignment prefix (F=$(ls dir)) runs nothing itself; its
          # substitution is prescanned through its own S record.
          # Only a plain `NAME=$(ls ...)` is skipped: a substitution nested in
          # a parameter expansion (${x:-$(ln ...)}, flag v) emits no S record of
          # its own, and any other command (date, cat) keeps the command impure.
          if [[ "$tx" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            case "$fl" in
              *v*) ;;
              *s*) case "$last_s" in ls|ls\ *) asg=1; continue ;; esac ;;
            esac
          fi
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
    bash|.claude/skills/deploy/scripts/resolve-deploy-api.sh|./.claude/skills/deploy/scripts/resolve-deploy-api.sh)
      # The /deploy API resolver, pinned by hash, prints one https URL
      # (same rule as the scope guard's scope_deploy_api_resolver_value).
      [ ${#stages[@]} -eq 1 ] || return 1
      local rv_rel=".claude/skills/deploy/scripts/resolve-deploy-api.sh" rv_s="${w[*]}" rv_sum rv_api="" rv_d rv_m
      case "$rv_s" in "bash $rv_rel"|"$rv_rel"|"./$rv_rel"|"bash ./$rv_rel") ;; *) return 1 ;; esac
      [ "$CWD_UNCERTAIN" -eq 0 ] || return 1
      [ -f "$cwd/$rv_rel" ] && [ ! -L "$cwd/$rv_rel" ] || return 1
      case "$STRIPPED" in *HQ_DEPLOY_API*|*manifest*) return 1 ;; esac
      if command -v shasum >/dev/null 2>&1; then rv_sum="$(shasum -a 256 "$cwd/$rv_rel" 2>/dev/null)" || return 1
      else rv_sum="$(sha256sum "$cwd/$rv_rel" 2>/dev/null)" || return 1; fi
      [ "${rv_sum%% *}" = "0b622ae7efff3be76e8eb199f8327be662bef371a3612d356df505c5a696b492" ] || return 1 # gitleaks:allow
      rv_api="${HQ_DEPLOY_API:-}"
      if [ -z "$rv_api" ]; then
        rv_d="$cwd"
        while [ -n "$rv_d" ] && [ "$rv_d" != "/" ]; do
          rv_m="$rv_d/companies/manifest.yaml"
          if [ -f "$rv_m" ]; then
            rv_api="$(awk -F'endpoint:[ \t]*' '/hq-deploy/{f=1} f&&/endpoint:/{gsub(/[ \t\r]+$/,"",$2); print $2; exit}' "$rv_m" 2>/dev/null || true)"
            break
          fi
          rv_d="$(dirname "$rv_d")"
        done
      fi
      rv_api="${rv_api:-https://api.hq.work}"
      [[ "$rv_api" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]] || return 1
      SUBST_OUT="$rv_api"
      return 0
      ;;
    git)
      # `git [-C DIR] branch --show-current`: the branch name is read from
      # the repository's HEAD file here (no git process, so no configured
      # program can run). A detached HEAD prints nothing.
      if [ ${#w[@]} -eq 3 ] && [ "${w[1]} ${w[2]}" = "branch --show-current" ] \
        || { [ ${#w[@]} -eq 5 ] && [ "${w[1]}" = "-C" ] && [ "${w[3]} ${w[4]}" = "branch --show-current" ]; }; then
        [ -z "${GIT_DIR:-}" ] && [ -z "${GIT_WORK_TREE:-}" ] || return 1
        local gd="$cwd" gh_line
        [ ${#w[@]} -eq 5 ] && { case "${w[2]}" in /*) gd="${w[2]}" ;; *) [ "$CWD_UNCERTAIN" -eq 0 ] || return 1; gd="$cwd/${w[2]}" ;; esac; }
        [ ${#w[@]} -eq 3 ] && { [ "$CWD_UNCERTAIN" -eq 0 ] || return 1; }
        while [ -n "$gd" ] && [ ! -e "$gd/.git" ]; do
          [ "$gd" = "/" ] && return 1
          gd="${gd%/*}"; [ -n "$gd" ] || gd="/"
        done
        if [ -f "$gd/.git" ]; then
          gh_line="$(head -n 1 "$gd/.git" 2>/dev/null)" || return 1
          case "$gh_line" in "gitdir: "/*) gd="${gh_line#gitdir: }" ;; "gitdir: "*) gd="$gd/${gh_line#gitdir: }" ;; *) return 1 ;; esac
        else
          gd="$gd/.git"
        fi
        [ -f "$gd/HEAD" ] || return 1
        gh_line="$(head -n 1 "$gd/HEAD" 2>/dev/null)" || return 1
        case "$gh_line" in
          "ref: refs/heads/"*) out="${gh_line#ref: refs/heads/}" ;;
          *) out="" ;;
        esac
        case "$out" in *[!A-Za-z0-9._/@+-]*|*..*|/*|.*|*/.*) return 1 ;; esac
        [ -n "$out" ] || return 1
        SUBST_OUT="$out"
        return 0
      fi
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
      local dirok=0 arg pat prefix m matches=() cntm=0 lsdot=0 lsents=() ent
      for ((i = 1; i < ${#w[@]}; i++)); do
        arg="${w[$i]}"
        case "$arg" in
          -1) continue ;;
          -d|-1d|-d1) dirok=1; continue ;;
          # Ordering and dot-entry flags keep the printed names the same set
          # (-A adds dot entries, never `.` or `..`).
          -[1trSA]*)
            case "$arg" in *[!-1trSAd]*) return 1 ;; esac
            case "$arg" in *d*) dirok=1 ;; esac
            case "$arg" in *A*) lsdot=1 ;; esac
            continue
            ;;
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
        # One directory operand without -d: ls prints its entry names, bare.
        if [ $dirok -eq 0 ] && [ ${#matches[@]} -eq 1 ] && [ ${#w[@]} -le 3 ] \
          && [ -d "${matches[0]}" ] && [ ! -L "${matches[0]}" ]; then
          [ $i -eq $((${#w[@]} - 1)) ] || return 1
          lsents=()
          shopt -s nullglob
          [ $lsdot -eq 1 ] && shopt -s dotglob
          lsents=("${matches[0]}"/*)
          shopt -u nullglob dotglob
          for ent in ${lsents[@]+"${lsents[@]}"}; do
            ent="${ent##*/}"
            cntm=$((cntm + 1)); [ $cntm -le 256 ] || return 1
            out="$out$ent"$'\n'
          done
          [ $cntm -gt 0 ] || return 1
          continue
        fi
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

# git_show_stage_var <raw-word>: 0 when the raw git show operand is
# :$NAME:<rest> (or :${NAME}:<rest>) and NAME is a `for` loop variable bound,
# before this simple command, only over literal words 0-3 (SPLIT_VAR_STAGE),
# and nothing in the command can rebind it (NAME=, NAME+=, read, eval,
# printf -v, ...). Quoting of the operand does not matter: the value itself
# is proven to be a merge-stage digit.
git_show_stage_var() {
  local raw="$1" name i
  [ "$SPLIT_TRUST" = 1 ] || return 1
  [[ "$raw" =~ ^:\$([A-Za-z_][A-Za-z0-9_]*): ]] || [[ "$raw" =~ ^:\$\{([A-Za-z_][A-Za-z0-9_]*)\}: ]] || return 1
  name="${BASH_REMATCH[1]}"
  [[ "$CMD" =~ $GS_HAZARD_RE ]] && return 1
  [[ "$CMD" =~ (^|[^[:alnum:]_])"$name"(\[[^]]*\])?\+?= ]] && return 1
  for ((i = 0; i < ${#SPLIT_VAR_NAMES[@]}; i++)); do
    if [ "${SPLIT_VAR_NAMES[$i]}" = "$name" ]; then
      [ "${SPLIT_VAR_OK[$i]}" = 1 ] && [ "${SPLIT_VAR_STAGE[$i]:-0}" = 1 ] || return 1
      [ "${SPLIT_VAR_G[$i]}" -lt "$SPLIT_CUR_G" ] || return 1
      return 0
    fi
  done
  return 1
}

# git_show_tree_safe <operand> <cwd>: 0 when the operand is <ref>:<path> for
# a read-only `git show`, the ref and the leading directories are literal, only
# the file name is computed (loop variable, wildcard, substitution), and no
# credential file is tracked at any path the operand could name in that ref.
# git show can only read objects the ref's tree holds, so listing the tree
# proves the computed part instead of guessing. Anything else returns 1 and
# the caller keeps the fail-closed block.
#
# Fails closed (returns 1) when the proof could be run against a different
# tree than the one git show reads (PR #1700 review):
#   - the caller passes redirect=1 when the git command carries -C, -c,
#     --git-dir, --work-tree or --namespace, or a GIT_* variable is set in the
#     command or the environment, or the working directory is uncertain;
#   - the path starts with ./ or has a . component (cwd-relative forms);
#   - ls-tree fails or lists nothing.
# <ref>:<path> is relative to the repository top level, so the listing uses
# --full-tree and the matched names are joined to the top level, not the cwd.
# cg_gitz <git args>: runs git (its -z listing) and prints each NUL-ended name
# on its own line, with git's exit code. Without -z, git prints a name that
# holds a non-ASCII byte, ", \ or a control character in quotes with octal
# escapes ("\303\251/.npmrc"), which is_cred_path does not read as .npmrc.
# A name that holds a newline is split into lines; each line is still checked,
# and a credential name never needs a newline to match.
cg_gitz() {
  git "$@" 2>/dev/null | tr '\000' '\n'
  return "${PIPESTATUS[0]}"
}

git_show_tree_safe() {
  local op="$1" gcwd="$2" redirect="${3:-1}" raw="${4:-}" ref path dir pat tf top listing
  [ "$redirect" = 0 ] || return 1
  [ -z "${GIT_DIR:-}" ] && [ -z "${GIT_WORK_TREE:-}" ] && [ -z "${GIT_NAMESPACE:-}" ] || return 1
  case "$op" in *:*) ;; *) return 1 ;; esac
  # Merge-stage form :<n>:<path> with a computed index (`for n in 1 2 3; do
  # git show :$n:path; done`). The index must be a loop variable whose every
  # binding is a list of literal digits 0-3 (git_show_stage_var): any other
  # value makes git read another revision form, and :/<text> or :/!-<text>
  # selects a commit by its message and prints the whole commit (PR #1798
  # review). git then reads the index entry for <path> at that stage. The
  # path must be literal and is still proven against the index git show
  # reads, with any entry named "<value>:<path>" (gs_cmd_readonly keeps git
  # add and other index writers out of the command).
  if [[ "$op" == :$'\001':* ]]; then
    git_show_stage_var "$raw" || return 1
    path="${op#:$'\001':}"
    case "$path" in ""|*$'\001'*|*'*'*|*'?'*|*'['*|*'{'*|*'}'*|*..*|/*|./*|.|*/.|*/./*|:*) return 1 ;; esac
    [ -d "$gcwd" ] || return 1
    top="$(git -C "$gcwd" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ -n "$top" ] && [ -d "$top" ] || return 1
    norm_path "$top/$path" "$top"
    if is_cred_path "$NP"; then return 1; fi
    listing="$(cg_gitz -C "$top" ls-files -z --full-name)" || return 1
    while IFS= read -r tf; do
      [ -n "$tf" ] || continue
      case "$tf" in *":$path") ;; *) continue ;; esac
      norm_path "$top/$tf" "$top"
      if is_cred_path "$NP"; then return 1; fi
    done <<< "$listing"
    return 0
  fi
  ref="${op%%:*}"
  path="${op#*:}"
  case "$ref" in ""|-*|*$'\001'*|*[!A-Za-z0-9._/@^~+-]*) return 1 ;; esac
  case "$path" in
    */*) dir="${path%/*}" ;;
    *) dir="" ;;
  esac
  case "$dir" in *$'\001'*|*'*'*|*'?'*|*'['*|*..*|/*|.|./*|*/.|*/./*) return 1 ;; esac
  case "$path" in *..*|/*|./*|.|*'{'*|*'}'*) return 1 ;; esac
  pat="${path//$'\001'/*}"
  [ -d "$gcwd" ] || return 1
  top="$(git -C "$gcwd" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$top" ] && [ -d "$top" ] || return 1
  listing="$(cg_gitz -C "$gcwd" ls-tree -r -z --full-tree --name-only "$ref" -- ${dir:+"$dir/"})" || return 1
  [ -n "$listing" ] || return 1
  while IFS= read -r tf; do
    # shellcheck disable=SC2254 # the glob in pat is the match.
    case "$tf" in $pat) ;; *) continue ;; esac
    norm_path "$top/$tf" "$top"
    if is_cred_path "$NP"; then return 1; fi
  done <<< "$listing"
  return 0
}

# Loop variables bound by `for NAME in <list>` where every list word is
# unquoted (a literal word, a bare $var or a bare $(...)): bash word-splits
# the list, so each value holds no IFS character and an unquoted $NAME in an
# operand cannot split into a second operand. A binding over a quoted word, a
# glob, a brace or a tilde (a value may hold whitespace) marks the name
# tainted for the whole command. note_for_bindings scans every simple command
# of the script before analysis so a later tainting binding still counts; a
# use is trusted only when a trusted binding (SPLIT_VAR_G, the index of its
# simple command) comes before the simple command that reads the variable.
# The arrays are made local per analyze_cmd level: a $(...) inherits the
# bindings that precede it in the same shell (index -1); a script run by
# another shell (bash -c, a heredoc script) inherits none; taints are always
# inherited.
SPLIT_VAR_NAMES=()
SPLIT_VAR_OK=()
SPLIT_VAR_G=()
# SPLIT_VAR_STAGE: 1 when every binding of the name is a `for` list of
# literal merge-stage digits (0-3) only; see git_show_stage_var.
SPLIT_VAR_STAGE=()
SPLIT_TRUST=1
SPLIT_INHERIT_G=0
split_var_mark() { # <name> <ok 0|1> <group> [stage 0|1]
  local i
  for ((i = 0; i < ${#SPLIT_VAR_NAMES[@]}; i++)); do
    if [ "${SPLIT_VAR_NAMES[$i]}" = "$1" ]; then
      [ "$2" = 1 ] || SPLIT_VAR_OK[$i]=0
      [ "${4:-0}" = 1 ] || SPLIT_VAR_STAGE[$i]=0
      return
    fi
  done
  SPLIT_VAR_NAMES+=("$1")
  SPLIT_VAR_OK+=("$2")
  SPLIT_VAR_G+=("$3")
  SPLIT_VAR_STAGE+=("${4:-0}")
}
# note_for_bindings: T/F/X token arrays of analyze_cmd, one simple command
# [start, end) with its index. Called for every simple command of a level.
note_for_bindings() { # <start> <end> <group>
  local a="$1" b="$2" g="$3" i name=""
  # Leading assignments and prefixes do not precede `for`; the keyword is the
  # first word or nothing.
  [ "${T[$a]:-}" = W ] || return 0
  case "${X[$a]}" in
    for|select) ;;
    in) SPLIT_TRUST=0; return 0 ;;
    *) return 0 ;;
  esac
  [ $((a + 1)) -lt "$b" ] || { SPLIT_TRUST=0; return 0; }
  name="${X[$((a + 1))]}"
  if ! [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || [ -n "${F[$((a + 1))]:-}" ]; then
    SPLIT_TRUST=0; return 0
  fi
  if [ $((a + 2)) -ge "$b" ] || [ "${X[$((a + 2))]}" != in ] || [ -n "${F[$((a + 2))]:-}" ]; then
    split_var_mark "$name" 0 "$g"; return 0
  fi
  local ok=1 stage=0 nw=0
  [ "${X[$a]}" = for ] && stage=1
  for ((i = a + 3; i < b; i++)); do
    case "${T[$i]}" in S) continue ;; W) ;; *) ok=0; break ;; esac
    nw=$((nw + 1))
    case "${F[$i]}" in *q*|*g*|*b*) ok=0; break ;; esac
    case "${X[$i]}" in "~"*|*'{'*|*'}'*|*'['*|*'*'*|*'?'*) ok=0; break ;; esac
    # A merge-stage index is one literal digit 0-3. Any other value turns
    # :<value>:<path> into another revision form (:/<text> searches commit
    # messages, and git show then prints a whole commit).
    case "${F[$i]}" in *s*|*v*) stage=0 ;; esac
    case "${X[$i]}" in [0-3]) ;; *) stage=0 ;; esac
  done
  [ "$ok" = 1 ] && [ "$nw" -ge 1 ] || stage=0
  split_var_mark "$name" "$ok" "$g" "$stage"
}
# zword_check <start> <end>: a word marked z (an unquoted zsh ^ or a # inside
# a word) in any simple command is a zsh extended glob that can name a
# credential file, whether the command reads it, prints it for xargs or
# loops over it (echo id^x | xargs cat, for f in i#d_rsa; do cat $f; done).
# git and npm-family operands are revisions and version ranges and get the
# wildcard check in check_word; inside [[ ]] a pattern is not a file glob.
# Every other command with a z word is blocked.
zword_check() { # <start> <end>
  local a="$1" b="$2" k w cmd="" hasz=0
  for ((k = a; k < b; k++)); do
    [ "${T[$k]}" = W ] || continue
    case "${F[$k]}" in *z*) ;; *) continue ;; esac
    # ^ inside $[ ] is arithmetic xor, not a glob.
    w="${X[$k]}"
    while [[ "$w" =~ ^(.*)\$\[[^]]*\](.*)$ ]]; do w="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"; done
    case "$w" in *'^'*|?*'#'*) hasz=1; break ;; esac
  done
  [ "$hasz" = 1 ] || return 0
  for ((k = a; k < b; k++)); do
    [ "${T[$k]}" = W ] || continue
    w="${X[$k]}"
    [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue
    case "$w" in
      -*) continue ;;
      '!'|'{'|'}'|then|do|else|elif|if|while|until|time|command|builtin|exec|nohup|nice|sudo|doas|env|timeout|gtimeout|stdbuf|caffeinate|coproc) continue ;;
    esac
    case "${F[$k]}" in *z*) cmd=""; break ;; esac
    lc_word "${w##*/}"
    cmd="$LCW"
    # The [[ ]] exemption ends at ]]: words after it (zsh short
    # if [[ c ]] { echo id^x }) are a command of their own.
    if [ "$cmd" = '[[' ]; then
      local k5
      for ((k5 = k + 1; k5 < b; k5++)); do
        if [ "${T[$k5]}" = W ] && [ "${X[$k5]}" = ']]' ]; then
          zword_check $((k5 + 1)) "$b"
          return 0
        fi
      done
    fi
    break
  done
  case "$cmd" in
    git|npm|pnpm|yarn|npx|bun|'[[') return 0 ;;
  esac
  block "a zsh extended-glob ^ or # word the credential guard cannot evaluate"
}

# gs_split_free <raw-word> <flags>: 0 when every $ reference in the raw word
# is a bare $NAME or ${NAME} of a loop variable split-bound earlier in this
# shell level (or inherited from the enclosing one), the word holds no
# substitution, glob or brace, and nothing in the command can rebind a
# variable or IFS behind the analysis (read, eval, mapfile, IFS=...).
GS_HAZARD_RE='(^|[^[:alnum:]_])(read|readarray|mapfile|getopts|eval|source|let|IFS)([^[:alnum:]_]|$)|printf[[:space:]]+-v|(^|[;&|[:space:]])\.[[:space:]]'
gs_split_free() {
  local raw="$1" flags="$2" rest name
  [ "$SPLIT_TRUST" = 1 ] || return 1
  case "$flags" in *s*|*g*|*b*) return 1 ;; esac
  case "$raw" in *'{'*|*'}'*|*'['*|*'*'*|*'?'*|*'~'*) return 1 ;; esac
  [[ "$CMD" =~ $GS_HAZARD_RE ]] && return 1
  rest="$raw"
  while :; do
    case "$rest" in *'$'*) ;; *) break ;; esac
    rest="${rest#*\$}"
    case "$rest" in
      '{'*)
        name="${rest%%\}*}"; name="${name#\{}"
        rest="${rest#*\}}"
        ;;
      *)
        [[ "$rest" =~ ^([A-Za-z_][A-Za-z0-9_]*) ]] || return 1
        name="${BASH_REMATCH[1]}"
        rest="${rest#"$name"}"
        ;;
    esac
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    # An assignment anywhere in the command (any level) rebinds the name.
    [[ "$CMD" =~ (^|[^[:alnum:]_])"$name"= ]] && return 1
    local i found=0
    for ((i = 0; i < ${#SPLIT_VAR_NAMES[@]}; i++)); do
      if [ "${SPLIT_VAR_NAMES[$i]}" = "$name" ]; then
        [ "${SPLIT_VAR_OK[$i]}" = 1 ] || return 1
        [ "${SPLIT_VAR_G[$i]}" -lt "$SPLIT_CUR_G" ] || return 1
        found=1; break
      fi
    done
    [ "$found" = 1 ] || return 1
  done
  return 0
}

# gs_cmd_readonly: 0 when nothing in the whole command can move a ref, HEAD
# or the object store between the hook's ls-tree and the git show it proves
# (PR #1700 review: `git checkout x && ... git show HEAD:src/$f`). The command
# is cut at ; & | ( ) { } ` $( and newlines; the first word of every piece,
# after assignments and the keywords do then else elif if while until !, must
# be on a read-only allowlist. Every git piece must name a read-only
# subcommand right after `git` and carry no --output, -O or
# --open-files-in-pager. No word may name a .git path, and no output
# redirection may target anything but /dev/null or a file descriptor.
# Anything unknown (a variable or quoted command word, a function definition,
# xargs, env, sed, cp, ...) fails closed: the caller keeps the normal check.
GS_RO_CMDS=" for in done fi esac read echo printf ls cat head tail wc sort uniq cut tr grep true false : test [ [[ ]] git "
GS_RO_GIT=" show log ls-files ls-tree rev-parse diff cat-file grep status blame "
GS_CMD_RO=""
gs_cmd_readonly() {
  if [ -n "$GS_CMD_RO" ]; then [ "$GS_CMD_RO" = 1 ]; return; fi
  GS_CMD_RO=0
  local t="$CMD" c seg w i first sub
  [[ "$t" =~ \.git([^[:alnum:]_]|$) ]] && return 1
  t="${t//2>&1/}"; t="${t//1>&2/}"; t="${t//>&2/}"
  t="${t//2>\/dev\/null/}"; t="${t//>\/dev\/null/}"
  case "$t" in *'>'*) return 1 ;; esac
  t="${t//\$(/$'\n'}"
  for c in ';' '&' '|' '(' ')' '`' '{' '}'; do t="${t//"$c"/$'\n'}"; done
  while IFS= read -r seg; do
    local -a ws=()
    read -ra ws <<< "$seg"
    first=""; i=0
    while [ $i -lt ${#ws[@]} ]; do
      w="${ws[$i]}"
      case "$w" in
        '"'|"'"|'""'|"''") i=$((i + 1)); continue ;;
        do|then|else|elif|if|while|until|'!') i=$((i + 1)); continue ;;
      esac
      if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then i=$((i + 1)); continue; fi
      first="$w"; break
    done
    [ -n "$first" ] || continue
    case "$GS_RO_CMDS" in *" $first "*) ;; *) return 1 ;; esac
    if [ "$first" = git ]; then
      sub="${ws[$((i + 1))]:-}"
      case "$GS_RO_GIT" in *" $sub "*) ;; *) return 1 ;; esac
      case "$seg" in *--output*|*' -O'*|*--open-files-in-pager*) return 1 ;; esac
    fi
  done <<< "$t"
  GS_CMD_RO=1
  return 0
}

# cg_zpat <word> -> CG_ZP: the word with each zsh ^ (to the end of its path
# segment) and each x# (the character before # and the #) replaced by *.
# After }, ) or ] the # repeats part of an expansion, group or bracket: the
# whole path segment before it becomes * (${p:-i}#d_rsa -> *d_rsa).
cg_zpat() {
  local t="$1" o="" c i n=${#1} skip=0
  for ((i = 0; i < n; i++)); do
    c="${t:i:1}"
    if [ $skip = 1 ]; then
      [ "$c" = / ] || continue
      skip=0
    fi
    case "$c" in
      '^') o="$o*"; skip=1 ;;
      '#')
        local last="${o: -1}"
        if [ "$last" = '}' ] || [ "$last" = ')' ] || [ "$last" = ']' ]; then
          case "$o" in */*) o="${o%/*}/*" ;; *) o="*" ;; esac
        else
          o="${o%?}*"
        fi
        ;;
      *) o="$o$c" ;;
    esac
  done
  CG_ZP="$o"
}

# check_word <text> <flags> <cwd>: an operand that the command reads.
check_word() {
  local text="$1" flags="$2" cwd="$3" cand pat m
  case "$flags" in
    *z*) [ "${CG_ZOK:-0}" = 1 ] || block "a read operand with a zsh extended-glob ^ or # the credential guard cannot evaluate" ;;
  esac
  local cg_zuse=0
  if [ "${CG_ZOK:-0}" = 1 ]; then
    case "$flags" in
      *z*) cg_zuse=1 ;;
      # An expansion next to any glob character (${p}*, ${p:-i}#d_rsa) can
      # name any file once zsh expands it: same check as a z word.
      *[vs]*)
        case "$text" in
          *'*'*|*'?'*|*'['*|*'^'*|*'#'*|*'~'*|*'('*) cg_zuse=1 ;;
        esac
        ;;
    esac
  fi
  case "$cg_zuse" in
    1)
      # git and npm-family operands are mostly revisions and ranges, but zsh
      # still expands them first: check the word as the wildcard pattern it
      # can match (x^y -> x*, x#y -> *y), so git diff --no-index on
      # .n^xpmrc or i#d_rsa blocks while HEAD^ (HEAD*) passes.
      # A variable the command does not assign is a wildcard here (CRED_ANY),
      # so "$p"^x fails closed as it does for cat.
      cg_zpat "$text"
      local CRED_ANY=1 CG_ZOK=0
      check_word "$CG_ZP" "${flags//z/}g" "$cwd"
      return 0
      ;;
  esac
  # zsh extended glob ~ (exclusion): the user's zsh can have extendedglob
  # on, so a ~ after a glob character always counts; any ~ inside a word
  # counts when the command turns zsh extended globbing on itself.
  case "$text" in
    *[*?]*'~'*|*']'*'~'*) block "a read operand with a zsh extended-glob ~ (exclusion) the credential guard cannot evaluate" ;;
  esac
  if [ "${CG_ZSH_EXT:-0}" = 1 ]; then
    case "$text" in
      ?*'~'*) block "a read operand with a zsh extended-glob ~ (exclusion) the credential guard cannot evaluate" ;;
    esac
  fi
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
          *) block "reading a path computed by a substitution or variable the credential guard cannot evaluate (operand: ${text//$'\001'/<computed value>})" ;;
        esac
        # A wildcard cannot model unknown separators or parent segments.
        # Missing matches are not proof: output can name a deeper neutral
        # link, or leave this directory entirely. Metadata-only commands
        # never reach this read-operand check.
        block "reading a path whose computed value the credential guard cannot prove"
        ;;
      *)
        norm_path "$cand" "$cwd"
        local np_w="$NP_W"
        case "$flags" in
          *g*)
            # On Windows the shell expands the pattern with Windows rules
            # (C:/../x/* is C:/x/*), so every reading of the word is
            # expanded and checked.
            local gp_list=("$NP") gp
            if [ "${CG_WIN_HOST:-0}" = 1 ]; then
              [ -z "$np_w" ] || gp_list+=("$np_w")
              cg_win_readings "$cand" "$cwd"
              [ ${#CG_RDS[@]} -eq 0 ] || gp_list+=("${CG_RDS[@]}")
            fi
            for gp in "${gp_list[@]}"; do
              cg_glob_check "$gp"
            done
            ;;
          *)
            local np_m="$NP"
            [ -z "$np_w" ] || check_abs "$np_w"
            check_abs "$np_m"
            cg_drive_relative "$cand" "$cwd"
            cg_root_relative "$cand" "$cwd"
            cg_win_slash_alt "$cand" "$cwd"
            [ -z "$CG_ALT2" ] || check_abs "$CG_ALT2"
            ;;
        esac
        ;;
    esac
  done
}

# cg_glob_check <pattern>: check an absolute glob pattern and each of its
# matches (and their link targets) as check_word does for one reading.
cg_glob_check() {
            local pat_g="$1"
            check_pattern "$pat_g" 0 0 1
            local matches=() mm cnt=0 rps=() ri
            local old_ifs="$IFS"
            shopt -s nullglob
            IFS=
            # shellcheck disable=SC2206 # glob expansion is the point.
            matches=($pat_g)
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
}

# resolve_dir <text> <flags> <cwd> -> NP or empty (for cd / recursive targets).
# On Windows a drive-relative C:x (no separator after the colon) has two
# readings. The MSYS and Cygwin runtime, which runs cd, pushd and the MSYS
# tools, reads it as C:\x, which is NP. A native Windows program reads it as
# x in the current directory of drive C; unless the cwd is on another drive,
# that is x under the cwd, which is NP_ALT. A root-relative \x is read
# from the root of the cwd's drive; NP_ALT holds that reading and
# NP_ALT_ROOT is 1. NP_ALT is empty otherwise. RD_EXTRA lists every reading
# other than NP (NP_ALT and the Windows ".." readings) for the checks;
# RD_NP_W is the Windows ".." reading of NP itself. RD_CHECK is RD_EXTRA
# plus the native drive-root reading of a slash-first /x (cg_win_slash_alt),
# for the name and directory checks only; cd and git -C use RD_EXTRA.
NP_ALT=""
NP_ALT_ROOT=0
RD_EXTRA=()
RD_NP_W=""
RD_CHECK=()
resolve_dir() {
  local text="$1" flags="$2" dr d nc=0
  NP_ALT=""
  NP_ALT_ROOT=0
  RD_EXTRA=()
  RD_NP_W=""
  RD_CHECK=()
  case "$flags" in *v*) expand_vars "$text"; text="$EV" ;; esac
  case "$text" in *$'\001'*) NP=""; return ;; esac
  if [ "${CG_WIN_HOST:-0}" = 1 ]; then
    dr="${text//\\//}"
    case "$dr" in
      [A-Za-z]:/*|[A-Za-z]:) ;;
      [A-Za-z]:*)
        lc_word "${dr:0:1}"
        d="$LCW"
        cg_win_fold "$3"
        shopt -q nocasematch && nc=1
        shopt -s nocasematch
        case "$CG_WIN_P" in
          "${CG_WIN_DRIVE_ROOT:-}/$d"|"${CG_WIN_DRIVE_ROOT:-}/$d"/*) d="" ;;
          "${CG_WIN_DRIVE_ROOT:-}"/[a-z]|"${CG_WIN_DRIVE_ROOT:-}"/[a-z]/*) ;;
          *) d="" ;;
        esac
        [ "$nc" -eq 1 ] || shopt -u nocasematch
        if [ -z "$d" ]; then
          norm_path "${dr:2}" "$3"
          NP_ALT="$NP"
        fi
        ;;
    esac
  fi
  if [ -z "$NP_ALT" ]; then
    cg_win_root_rel "$text" "$3"
    NP_ALT="$CG_ALT"
    [ -z "$NP_ALT" ] || NP_ALT_ROOT=1
  fi
  local alt_w=""
  if [ -n "$NP_ALT" ] && [ "$NP_ALT_ROOT" = 0 ]; then
    # The cwd reading of a drive-relative C:x is the native program's, so
    # ".." stops at the drive root there.
    norm_path "${dr:2}" "$3"
    alt_w="$NP_W"
  fi
  cg_win_slash_alt "$text" "$3"
  local alt_s="$CG_ALT2"
  norm_path "$text" "$3"
  RD_NP_W="$NP_W"
  [ "$NP_ALT" != "$NP" ] || NP_ALT=""
  RD_EXTRA=()
  [ -z "$NP_ALT" ] || RD_EXTRA+=("$NP_ALT")
  [ -z "$alt_w" ] || RD_EXTRA+=("$alt_w")
  [ -z "$NP_W" ] || RD_EXTRA+=("$NP_W")
  [ ${#RD_EXTRA[@]} -eq 0 ] || RD_CHECK=("${RD_EXTRA[@]}")
  [ -z "$alt_s" ] || [ "$alt_s" = "$NP" ] || RD_CHECK+=("$alt_s")
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
  # When the command can replace what a name runs (an alias, a PATH change,
  # hash, enable), that name is not trusted as metadata-only.
  [ "${CG_CMD_OVERRIDE:-0}" = 0 ] || return 1
  if [ "${CG_PATH_CHANGED:-0}" = 1 ]; then
    case "$1" in
      ls|stat|chmod|chown|chgrp|touch|rm|rmdir|mkdir|unlink|wc|file|du|\
      realpath|readlink|basename|dirname|tee|ln|ssh|ssh-add|sleep|which)
        return 1 ;;
    esac
  fi
  case "$1" in
    ls|stat|test|'['|'[['|chmod|chown|chgrp|touch|rm|rmdir|mkdir|unlink|wc|\
    file|du|echo|printf|true|false|realpath|readlink|basename|dirname|tee|ln|\
    ssh|ssh-add|:|pwd|read|mapfile|readarray|exit|return|unset|set|shift|\
    trap|wait|sleep|type|which|hash|kill|break|continue)
      return 0 ;;
  esac
  return 1
}

# cg_trusted_word <command word>: 1 when the word names a program by a path
# outside the standard system directories (/tmp/x/ls, ./ls). That program
# only shares the name of a safe command, so is_safe_cmd does not apply.
# Only the root-owned system directories count.
cg_trusted_word() {
  case "$1" in
    */*) ;;
    *) return 0 ;;
  esac
  case "${1%/*}" in
    # Root-owned only: Homebrew's /usr/local/bin and /opt/homebrew/bin are
    # writable by the user.
    /bin|/usr/bin|/sbin|/usr/sbin) return 0 ;;
  esac
  return 1
}

# cygpath_converts_only <start> <end>: 0 when this cygpath call can only print
# converted path text. cygpath -f/--file reads a file and prints its lines, so
# only the conversion options below qualify. A computed word could expand to
# --file=<path>, so it must come after `--`, which ends option parsing. So can
# an unquoted brace or glob word (cygpath {-f,} ~/.npmrc runs cygpath -f).
# Anything else returns 1 and keeps the usual operand checks.
cygpath_converts_only() {
  local s="$1" e="$2" k w
  for ((k = s; k < e; k++)); do
    w="${CW[$k]}"
    [ "$w" = "--" ] && return 0
    case "${CF[$k]:-}" in *b*|*g*) return 1 ;; esac
    case "$w" in
      --) return 0 ;;
      -[almpsuw]|-[almpsuw][almpsuw]|--absolute|--long-name|--mixed|--path|--short-name|--unix|--windows) ;;
      -*|*\$*|*\`*|*$'\001'*|*[*?[]*) return 1 ;;
    esac
  done
  return 0
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
# follow a word character, so process.env and os.environ do not match. A
# *.env name (prod.env, app.env) does follow one, so it counts when a quote
# closes the string right after it ('/srv/app/prod.env'): process.env and
# settings.env are never followed by a quote (feedback 166f01a7).
CODE_CRED_RE='(^|[^A-Za-z0-9_.$])\.env([^A-Za-z0-9_]|$)|npmrc|netrc|pypirc|yarnrc|git-credentials|\.aws([^A-Za-z0-9_]|$)|\.ssh([^A-Za-z0-9_]|$)|id_(rsa|dsa|ecdsa|ed25519)([^.A-Za-z0-9_]|$)|\.docker/config|gh/hosts|\.gem/credentials'
CODE_CRED_RE+='|[A-Za-z0-9_-]\.env\\?["'"'"'`]|\.envrc([^A-Za-z0-9_]|$)'

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

# code_check <code text> <command> [reason]: block interpreter code that
# names a credential file. [reason] replaces the default block message.
code_check() {
  local t="$1" allowed nc=0 hit=1
  for allowed in .env.example .env.sample .env.template .env.schema .env.dist upstream-pin.env; do
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
  [[ "$t" =~ ${CG_CODE_RE:-$CODE_CRED_RE} ]] && hit=0
  [ "$nc" -eq 1 ] || shopt -u nocasematch
  [ $hit -eq 0 ] && block "${3:-$2 code that names a credential file}"
  return 0
}

# Values of variables exported earlier in this command line (export F=...,
# declare -x F=..., export F after F=...). An interpreter started later sees
# them in its environment.
CG_EXPORTED=""
# Names marked for export before or after their value is set (export F;
# F=...; local -x F, printf -v F ...; export F), and set -a / set -o
# allexport, which exports every later assignment. Their current values are
# checked when an interpreter runs.
CG_EXPORT_NAMES=" "
CG_ALLEXPORT=0

# assign_word <NAME=value or NAME+=value>: record the assignment (tilde and
# known variables expanded). NAME+=value appends to ${NAME}, which stays an
# unknown reference when NAME was not assigned earlier. Sets EV to the new
# value and AN to the name.
AN=""
assign_word() {
  local w="$1" v name
  name="${w%%=*}"
  v="${w#*=}"
  case "$v" in "~"|"~/"*) v="$H${v#"~"}" ;; esac
  case "$name" in
    *+) name="${name%+}"; v="\${$name}$v" ;;
  esac
  expand_vars "$v"
  set_var "$name" "$EV"
  AN="$name"
}

# printf -v NAME ...: the words after the name, kept per name and checked
# only as an environment value (they never replace NAME for path checks).
CG_PFV_N=()
CG_PFV_V=()

# env_values -> ENVV: every value the next command may get in its
# environment: NAME=value prefixes (passed in), values exported earlier, and
# the current values of exported names (all names after set -a). Each value
# is followed by a quote, so a *.env name at its end matches CODE_CRED_RE
# the way it does at the end of a quoted string in code (prod.env').
ENVV=""
env_values() {
  local i n
  ENVV="$1 $CG_EXPORTED"
  for ((i = 0; i < ${#VAR_NAMES[@]}; i++)); do
    n="${VAR_NAMES[$i]}"
    if [ "$CG_ALLEXPORT" -eq 1 ]; then ENVV="$ENVV ${VAR_VALS[$i]}'"; continue; fi
    case "$CG_EXPORT_NAMES" in *" $n "*) ENVV="$ENVV ${VAR_VALS[$i]}'" ;; esac
  done
  for ((i = 0; i < ${#CG_PFV_N[@]}; i++)); do
    n="${CG_PFV_N[$i]}"
    if [ "$CG_ALLEXPORT" -eq 1 ]; then ENVV="$ENVV ${CG_PFV_V[$i]}'"; continue; fi
    case "$CG_EXPORT_NAMES" in *" $n "*) ENVV="$ENVV ${CG_PFV_V[$i]}'" ;; esac
  done
}

# ENV_CRED_RE: credential file names in an environment value. Same as
# CODE_CRED_RE except that a bare ~/.ssh or ~/.aws directory does not count:
# an agent socket (SSH_AUTH_SOCK=~/.ssh/agent.sock), AWS_CONFIG_FILE=
# ~/.aws/config and GIT_SSH_COMMAND="ssh -i ~/.ssh/deploy" are ordinary.
# Private key names and ~/.aws/credentials still count.
ENV_CRED_RE="${CODE_CRED_RE//'|\.aws([^A-Za-z0-9_]|$)|\.ssh([^A-Za-z0-9_]|$)'/}"'|\.aws/credentials'

# env_check <prefix values> <command>: block when the environment the
# command gets (env_values) names a credential file, or holds a value the
# guard cannot resolve (another variable, a substitution, ${X:-...}) in a
# command that names a credential word anywhere (CRED_ANY): fail closed
# (review C1 of PR 1911).
env_check() {
  env_values "$1"
  case "$ENVV" in
    *$'\001'*)
      [ "$CG_CRED_NAMED" -eq 1 ] && block "$2 with an environment value the credential guard cannot resolve, in a command that names a credential file" ;;
  esac
  CG_CODE_RE="$ENV_CRED_RE" code_check "$ENVV" "$2" \
    "$2 with an environment variable that names a credential file"
  return 0
}

# shell_env_file <value> <flags>: the value of BASH_ENV or ENV for a shell.
# A value the guard cannot resolve blocks when the command names a
# credential word; a literal path is checked as a read operand.
shell_env_file() {
  local v="$1"
  case "$v" in ''|/dev/null) return 0 ;; esac
  case "$v" in
    *$'\001'*)
      [ "$CG_CRED_NAMED" -eq 1 ] && block "a shell started with BASH_ENV or ENV the credential guard cannot resolve, in a command that names a credential file"
      return 0 ;;
  esac
  check_word "$v" "" "$CUR_CWD"
  return 0
}

# GLOB_CRED_RE: a file-name filter (grep --include, rg -g / --glob / --iglob,
# ag -G) that selects credential files: .env, .env*, *.env, .env.local,
# prod.env, .envrc, .npmrc and the other credential names. *.environment.ts
# does not match.
GLOB_CRED_RE='(^|[^a-z0-9_])\.env([^a-z0-9_]|$)|[a-z0-9_*?-]\.env$|\.envrc|npmrc|netrc|pypirc|yarnrc|git-credentials|id_(rsa|dsa|ecdsa|ed25519)'

# glob_names_cred <glob>: 0 when a recursive search's file-name filter selects
# credential files. A negated rg glob (!*.env) leaves them out and does not
# count, nor do the allowed templates (.env.example ...).
glob_names_cred() {
  local b="${1##*/}"
  case "$1" in '!'*) return 1 ;; esac
  lc_word "$b"; b="$LCW"
  case "$b" in
    .env.example|.env.sample|.env.template|.env.schema|.env.dist|upstream-pin.env) return 1 ;;
    .env.*.example|.env.*.sample|.env.*.template) return 1 ;;
    # *.env.example, app.env.sample: template names only (review false block).
    *.env.example|*.env.sample|*.env.template|*.env.schema|*.env.dist) return 1 ;;
    example.env|*.example.env|*.sample.env|*.template.env|*.schema.env|*.dist.env) return 1 ;;
  esac
  [[ "$b" =~ $GLOB_CRED_RE ]]
}

# fed_git_read <start> <end> <placeholder> <appends> <tool>: the command
# that xargs, find -exec or parallel runs is a git object reader (git show,
# cat-file, archive) whose <ref>:<path> operand the tool fills in, either
# through the placeholder or by appending input lines. The path is computed,
# so it is refused whatever it resolves to.
fed_git_read() {
  local s="$1" e="$2" ph="$3" app="$4" tool="$5" j t="" sep=""
  for ((j = s; j < e; j++)); do t="$t$sep${CW[$j]}"; sep=" "; done
  [[ "$t" =~ (^|[[:space:]/\'\"])git([[:space:]]|$) ]] || return 0
  if [[ "$t" =~ (^|[[:space:]])(show|cat-file|archive)([[:space:]]|$) ]]; then
    if [ "$app" -eq 1 ] || { [ -n "$ph" ] && [[ "$t" == *"$ph"* ]]; }; then
      block "$tool filling in the path of a git show, cat-file or archive (a computed path)"
    fi
  fi
  fed_git_check "$@"
  return 0
}

# fed_q <word>: FQ is the word quoted for analyze_cmd: printf %q, except a
# word with an expansion, which stays an expansion.
fed_q() {
  local w="$1"
  if [[ "$w" == *'$'* || "$w" == *'`'* ]]; then
    w="${w//\\/\\\\}"; FQ="\"${w//\"/\\\"}\""
  else
    FQ="$(printf '%q' "$w")"
  fi
}

# fed_git_check <start> <end> <placeholder> <appends> <tool> [find paths...]:
# the git command that xargs, find -exec or parallel runs is checked as if it
# ran directly, with the input it is fed standing for a computed word
# (${__cg_fed}): a patch reader (git log -p --) then counts as covering every
# file. find -exec stops at its ; or + terminator, and a {} word stands for
# the starting paths of find, which hold every file it can name.
fed_git_check() {
  local s="$1" e="$2" ph="$3" app="$4" tool="$5" j w q t="" sep="" piece fed='"${__cg_fed}"' fp=""
  shift 5
  for w in "$@"; do fed_q "$w"; fp="$fp${fp:+ }$FQ"; done
  for ((j = s; j < e; j++)); do
    w="${CW[$j]}"
    if [ "$tool" = "find -exec" ]; then
      case "$w" in ';') break ;; '+') [ "${CW[$((j - 1))]:-}" = "$ph" ] && break ;; esac
    fi
    q=""
    if [ -n "$fp" ] && [ "$w" = "$ph" ]; then
      q="$fp"
    elif [ -n "$ph" ] && [[ "$w" == *"$ph"* ]]; then
      while [[ "$w" == *"$ph"* ]]; do
        piece="${w%%"$ph"*}"
        [ -z "$piece" ] || q="$q$(printf '%q' "$piece")"
        q="$q$fed"; w="${w#*"$ph"}"
      done
      [ -z "$w" ] || q="$q$(printf '%q' "$w")"
    else
      fed_q "$w"; q="$FQ"
    fi
    t="$t$sep$q"; sep=" "
  done
  [ "$app" -eq 1 ] && t="$t $fed"
  [ -n "$t" ] || return 0
  local f_cw=("${CW[@]}") f_cf=("${CF[@]}")
  analyze_cmd "$t" $((depth + 1)) "$CUR_CWD"
  CW=("${f_cw[@]}"); CF=("${f_cf[@]}")
  return 0
}

# cg_split_cmdline <text>: SCW set to the words git makes of alias text
# (split_cmdline in git's alias.c). Space, tab, newline and carriage return
# separate words outside quotes; '...' and "..." group and are removed; a
# backslash outside single quotes keeps the next character as it is. So
# `"log" -p`, `lo\g -p` and a value holding a newline (log<LF>-p) read as git
# runs them. An unclosed quote or a trailing backslash makes git refuse the
# alias; the words read so far are kept.
cg_split_cmdline() {
  local s="$1" i n c q="" cur="" have=0
  SCW=()
  n=${#s}
  for ((i = 0; i < n; i++)); do
    c="${s:i:1}"
    if [ -z "$q" ]; then
      case "$c" in
        ' '|$'\t'|$'\n'|$'\r')
          [ "$have" = 0 ] || SCW+=("$cur")
          cur=""; have=0; continue ;;
        "'"|'"') q="$c"; have=1; continue ;;
      esac
    elif [ "$c" = "$q" ]; then
      q=""; continue
    fi
    if [ "$c" = '\' ] && [ "$q" != "'" ]; then
      i=$((i + 1))
      [ $i -lt $n ] || break
      c="${s:i:1}"
    fi
    cur="$cur$c"; have=1
  done
  [ "$have" = 0 ] || SCW+=("$cur")
  return 0
}

# git_alias_value <name> <dir> <c-values>: 0 and GAV set to the alias text
# when <name> is a git alias: a `-c alias.NAME=VALUE` of this invocation (the
# newline-separated <c-values>), else `git config --get alias.NAME` read in
# <dir>. Returns 2 when the alias may be defined where that lookup cannot see
# it: the command line names alias.NAME (git config alias.NAME ...,
# GIT_CONFIG_KEY_n, --config-env), or passes git config that can define one
# (-c include.path=..., -c includeIf..., --config-env, GIT_CONFIG_*). Returns
# 1 for a built-in or no alias.
#
# The -c values are passed one per argument (from the 3rd on), so a value
# that holds a newline (-c $'alias.x=log\n-p') stays one value.
git_alias_value() {
  local name="$1" dir="$2" line ln cvs=""
  shift 2
  GAV=""
  case "$GIT_KNOWN_SUBS" in *" $name "*) return 1 ;; esac
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || return 1
  lc_word "alias.$name"; ln="$LCW"
  for line in "$@"; do
    cvs="$cvs$line"$'\n'
    [[ "$line" == *=* ]] || continue
    lc_word "${line%%=*}"
    [ "$LCW" = "$ln" ] && GAV="${line#*=}"
  done
  if [ -n "$GAV" ]; then
    # A -c value is a shell word: a $ or ` in it ($'\x20', $X, $(...)) is
    # expanded by the shell before git reads the alias, so the text here is
    # not what git runs (a $(...) or `...` is stored as \001). A shell alias
    # (!...) is checked as a script.
    case "$GAV" in '!'*) ;; *'$'*|*'`'*|*$'\001'*) return 2 ;; esac
    return 0
  fi
  lc_word "$cvs"
  case "$LCW" in *include.path*|*includeif.*) return 2 ;; esac
  lc_word "$STRIPPED"
  case "$LCW" in *"$ln"*|*git_config*|*--config-env*) return 2 ;; esac
  [ -d "$dir" ] || return 1
  GAV="$(git -C "$dir" config --get "alias.$name" 2>/dev/null)" || GAV=""
  [ -n "$GAV" ]
}

# Pathspecs that cover every name is_cred_path accepts (a superset; listings
# are filtered by is_cred_path), from the top of the repository whatever the
# cwd. Used when git prints every file: no pathspec, or a computed one.
CRED_GIT_PATHSPECS=(':(top,glob,icase)**/.npmrc*' ':(top,glob,icase)**/.netrc*'
  ':(top,glob,icase)**/_netrc*' ':(top,glob,icase)**/._netrc*' ':(top,glob,icase)**/.pypirc*'
  ':(top,glob,icase)**/.yarnrc*' ':(top,glob,icase)**/.git-credentials*'
  ':(top,glob,icase)**/id_*' ':(top,glob,icase)**/.id_*' ':(top,glob,icase)**/*.env*'
  ':(top,glob,icase)**/.gem/**' ':(top,glob,icase)**/.docker/**'
  ':(top,glob,icase)**/.config/gh/**' ':(top,glob,icase)**/.aws/**' ':(top,glob,icase)**/.ssh/**')

# git_tree_has_cred <cwd> <mode> <arg>... -- <path>...: 0 when a credential
# file is among the files git prints for these args and paths. Modes: tree
# (each rev's tree: ls-tree, or an empty-tree diff-tree for wildcards and
# pathspec magic), log (files the history of the revs touches), any (files
# any commit or the index holds: a revision the guard cannot read), show
# (files the named commits touch), diff (files the diff covers), difftree
# (files git diff-tree covers), stash (files the stash entry holds). Paths
# are pathspecs relative to <cwd>, as git reads them. Outside a work tree git
# prints nothing, so that is not a credential; inside one a failed listing
# counts as a credential (fail closed). Only read-only listings run.
git_tree_has_cred() {
  local gcwd="$1" mode="$2" top listing="" tf r et=""
  shift 2
  local revs=() paths=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do revs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  paths=("$@")
  [ -d "$gcwd" ] || return 1
  top="$(git -C "$gcwd" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$top" ] || return 1
  case "$mode" in
    tree)
      local magic=0 pth
      for pth in ${paths[@]+"${paths[@]}"}; do
        case "$pth" in :*|*'*'*|*'?'*|*'['*) magic=1 ;; esac
      done
      for r in "${revs[@]}"; do
        # ls-tree reads no wildcard or pathspec magic; diff-tree against the
        # empty tree lists the same files and does.
        # -z: names are printed as they are, never quoted (cg_gitz).
        if [ "$magic" = 1 ] || ! tf="$(cg_gitz -C "$gcwd" ls-tree -r -z --full-name --name-only "$r" -- ${paths[@]+"${paths[@]}"})"; then
          [ -n "$et" ] || et="$(git -C "$gcwd" hash-object -t tree /dev/null 2>/dev/null)" || return 0
          tf="$(cg_gitz -C "$gcwd" -c diff.relative=false diff-tree -r -z --name-only --no-commit-id "$et" "$r" -- ${paths[@]+"${paths[@]}"})" || return 0
        fi
        listing="$listing$tf"$'\n'
      done
      ;;
    log) listing="$(cg_gitz -C "$gcwd" -c diff.relative=false log -m -z --name-only --format= "${revs[@]}" -- "${paths[@]}")" || return 0 ;;
    any)
      listing="$(cg_gitz -C "$gcwd" -c diff.relative=false log --all --reflog -m -z --name-only --format= -- "${paths[@]}")" || return 0
      tf="$(cg_gitz -C "$gcwd" ls-files -z --full-name -- "${paths[@]}")" || return 0
      listing="$listing"$'\n'"$tf"
      ;;
    show) listing="$(cg_gitz -C "$gcwd" -c diff.relative=false log --no-walk -m -z --name-only --format= "${revs[@]}" -- "${paths[@]}")" || return 0 ;;
    diff) listing="$(cg_gitz --no-optional-locks -C "$gcwd" -c diff.relative=false diff -z --name-only ${revs[@]+"${revs[@]}"} -- "${paths[@]}")" || return 0 ;;
    difftree) listing="$(cg_gitz -C "$gcwd" -c diff.relative=false diff-tree -r -m -z --name-only --no-commit-id ${revs[@]+"${revs[@]}"} -- "${paths[@]}")" || return 0 ;;
    diffindex) listing="$(cg_gitz --no-optional-locks -C "$gcwd" -c diff.relative=false diff-index -z --name-only ${revs[@]+"${revs[@]}"} -- "${paths[@]}")" || return 0 ;;
    difffiles) listing="$(cg_gitz --no-optional-locks -C "$gcwd" -c diff.relative=false diff-files -z --name-only -- "${paths[@]}")" || return 0 ;;
    stash)
      # With no stash list, git stash show prints only an error unless it is
      # named a commit that exists (one from git stash create, say). A stash
      # number (0, stash@{0}) needs the stash list. Otherwise a failed listing
      # still counts as a credential.
      if ! git -C "$gcwd" rev-parse -q --verify refs/stash >/dev/null 2>&1; then
        local named=0
        for r in ${revs[@]+"${revs[@]}"}; do
          case "$r" in -*) continue ;; esac
          [[ "$r" =~ ^[0-9]+$ ]] && continue
          git -C "$gcwd" rev-parse -q --verify "$r" >/dev/null 2>&1 && named=1
        done
        [ "$named" = 1 ] || return 1
      fi
      listing="$(cg_gitz -C "$gcwd" -c diff.relative=false stash show -z --name-only ${revs[@]+"${revs[@]}"})" || return 0
      ;;
  esac
  while IFS= read -r tf; do
    [ -n "$tf" ] || continue
    norm_path "$top/$tf" "$top"
    if is_cred_path "$NP"; then return 0; fi
  done <<< "$listing"
  return 1
}

# git_pathspec_read <sub> <start> <end> <cwd> <redirect> [alias words...]:
# git readers that print the contents of every file under their paths:
# archive, grep on a revision, bundle create to stdout, fast-export, and the
# patch output of log (and git reflog), show, diff, difftool, whatchanged,
# format-patch, diff-tree, diff-index, diff-files and stash show (with a
# pathspec, -L <range>:<path>, or none). A directory, the
# whole tree or the whole history can hold a credential file the command
# never names, so the files git would print are listed and a credential among
# them blocks. A computed path counts as every file and a computed revision as
# every commit. A repository the guard cannot list (--git-dir, GIT_DIR,
# archive --remote) blocks.
GP_VAR_RE='\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@*#?$!-]|\$\('
# Long options of log, show, diff and format-patch that take no value.
GP_NOARG_LONG=' --oneline --graph --no-merges --merges --first-parent --reverse --no-color --color --decorate --no-decorate --abbrev-commit --no-abbrev-commit --no-renames --minimal --patience --histogram --binary --text --no-prefix --full-index --no-ext-diff --ext-diff --no-textconv --textconv --exit-code --quiet --function-context --find-renames --find-copies --find-copies-harder --irreversible-delete --pickaxe-all --pickaxe-regex --topo-order --date-order --author-date-order --no-walk --do-walk --left-right --cherry-pick --cherry-mark --boundary --source --use-mailmap --show-signature --no-notes --numbered --no-numbered --stdout --attach --inline --thread --keep-subject --no-stat --signoff --cover-letter --no-binary --zero-commit --progress --ignore-if-in-upstream --ignore-space-change --ignore-all-space --ignore-blank-lines --ignore-cr-at-eol --ignore-space-at-eol --no-indent-heuristic --indent-heuristic --no-relative --raw --no-patch --name-only --name-status --numstat --shortstat --summary --check --stat --dirstat --cumulative --full-history --dense --sparse --simplify-merges --ancestry-path --no-min-parents --no-max-parents --remerge-diff --dd --diff-merges=off --no-diff-merges --combined-all-paths --no-ita-invisible-in-index --ita-invisible-in-index --default-prefix --no-color-moved --color-moved --dir-diff --no-prompt --prompt --trust-exit-code --no-trust-exit-code --gui --no-gui --symlinks --no-symlinks --keep-index --index '
# 1 when this git command passed -c or --config-env. Set before the log read.
GP_CFGOVR=0
# gp_short_patch <word> <sub>: 0 when <word> is a glued cluster of short
# options that asks for a patch (-pU3, -uU3, -Up). Options that take an
# attached value (-S<str>, -G<re>, -O<file>, -n<n>, -L, -I, -l, -M, -C, -B)
# are not clusters. In stash show, -u means --include-untracked.
gp_short_patch() {
  local w="$1" sub="$2"
  [[ "$w" =~ ^-[A-Za-z]+[0-9]*$ ]] || return 1
  case "$w" in -[SGOnLIlMCBXR]*) return 1 ;; esac
  case "$w" in -*p*|-*U*) return 0 ;; esac
  [ "$sub" != stash ] && case "$w" in -*u*) return 0 ;; esac
  return 1
}
# gp_glob_word <word> <flags> <dir>...: GPG empty when the word is not an
# unquoted glob or brace (or holds a $ or a substitution, read elsewhere, or
# is <ref>:<path> with a literal ref); "all" for a leading ~, a brace left
# unexpanded, **, a ( qualifier, a missing directory, or a glob that matches
# nothing (nullglob drops it, so git may get no pathspec); else "names" with
# GPG_N the word itself (git reads it as a pathspec when the shell leaves it
# unexpanded: quoted parts, set -f, GLOBIGNORE) and every file it matches in
# each <dir> (the shell's cwd may not be the one the guard tracks). The match
# is a superset of the shell's: dot files and case variants count.
GPG=""
GPG_N=()
gp_glob_word() {
  local w="$1" fl="$2" x d seen=" "
  shift 2
  GPG=""; GPG_N=()
  # A leading ~ (~, ~+, ~-, ~user) is a directory the shell substitutes.
  case "$w" in '~'*) GPG=all; return 0 ;; esac
  case "$fl" in *g*|*b*) ;; *) return 0 ;; esac
  case "$w" in *'$'*|*$'\001'*) return 0 ;; esac
  # <ref>:<path> objects of git show (before --, the part before the first
  # ':' a revision git resolves) are checked by the show branch. Anywhere
  # else (archive and grep paths included) a
  # ':' is part of a file name, a glob ([b:], [[:alpha:]]) or pathspec magic
  # (:(literal,attr:x)...).
  local rp
  case "$w" in
    *:*)
      rp="${w%%:*}"
      if [ -n "$rp" ] && [ "${GP_EO:-1}" = 0 ] && [ "${GP_SUB:-}" = show ]; then
        case "$rp" in
          *'*'*|*'?'*|*'['*|*']'*|*'{'*|*'('*|-*) ;;
          *) git -C "${GP_GCWD:-.}" rev-parse --verify -q "$rp^{object}" >/dev/null 2>&1 && return 0 ;;
        esac
      fi
      ;;
  esac
  case "$fl" in *b*) GPG=all; return 0 ;; esac
  case "$w" in *'**'*|*'('*) GPG=all; return 0 ;; esac
  GPG_N=("$w")
  for d in "$@"; do
    [ -n "$d" ] || continue
    case "$seen" in *" $d "*) continue ;; esac
    seen="$seen$d "
    [ -d "$d" ] || { GPG=all; return 0; }
    while IFS= read -r -d '' x; do
      GPG_N+=("$x")
    done < <(cd "$d" 2>/dev/null || exit 0
      shopt -s dotglob nocaseglob 2>/dev/null
      shopt -u nullglob failglob 2>/dev/null
      IFS=
      # shellcheck disable=SC2086 # the glob in w is the match.
      for x in $w; do
        if [ -e "$x" ] || [ -L "$x" ]; then printf '%s\0' "$x"; fi
      done)
  done
  GPG=names
  if [ ${#GPG_N[@]} -le 1 ]; then
    # No match: the shell passes the word on, unless nullglob is on (set in
    # the command in any spelling, or by a sourced file or rc file the guard
    # cannot read), which drops it and leaves git no pathspec at all.
    GPG=all
    return 0
  fi
  # Before --, a match may be read as an option (a file named -p) or a
  # revision (a file named HEAD~1 or A..B): git_pathspec_read blocks on
  # GPG=opt and takes any commit and any file on GPG=allrev.
  if [ "${GP_EO:-1}" = 0 ]; then
    local m i
    for ((i = 1; i < ${#GPG_N[@]}; i++)); do
      m="${GPG_N[$i]}"
      case "$m" in -*) GPG=opt; return 0 ;; esac
      case "$m" in *..*) GPG=allrev; return 0 ;; esac
      if git -C "${GP_GCWD:-.}" rev-parse "$m" -- >/dev/null 2>&1; then GPG=allrev; return 0; fi
    done
  fi
  return 0
}

git_pathspec_read() {
  local sub="$1" st="$2" en="$3" gcwd="$4" redir="$5" j w fl endopts=0 patch=0 nopatch=0 pat=0 skip=0 lr=0 nrev=0 wide=0
  local anyrev=0 anypath=0 objw=0 stdin=0 bfile="" unk=0 cnt="" cntok=1 cntnext=0
  shift 5
  local ws=() fs=() revs=() paths=() gp_k
  for w in "$@"; do ws+=("$w"); fs+=(""); done
  # A brace word is expanded as the shell does ({-p,--} is two words) and
  # each result loses the b flag. An expansion that does not finish (64
  # results or more, or a result that still holds {a,b}) blocks: an option
  # inside it ({-p,HEAD{,}{,}...}) would go unseen.
  local bx
  for ((j = st; j < en; j++)); do
    case "${CF[$j]}" in
      *b*)
        expand_braces "${CW[$j]}"
        if [ ${#BR[@]} -eq 0 ] || [ ${#BR[@]} -ge 64 ]; then
          block "git $sub with a computed path or revision the credential guard cannot list"
        fi
        for bx in "${BR[@]}"; do
          case "$bx" in *'{'*,*'}'*) block "git $sub with a computed path or revision the credential guard cannot list" ;; esac
        done
        for bx in "${BR[@]}"; do ws+=("$bx"); fs+=("${CF[$j]//b/}"); done
        continue
        ;;
    esac
    ws+=("${CW[$j]}"); fs+=("${CF[$j]}")
  done
  # A glob word before -- (-[p], ?p, *patch) becomes an option when a file
  # of that name exists when the command runs (it may be created earlier in
  # the same command). Blocked unless its literal start fixes the word: text
  # that does not start with -, or an option with = (--grep=fix*).
  local gl
  for ((j = 0; j < ${#ws[@]}; j++)); do
    [ "${ws[$j]}" != -- ] || break
    case "${fs[$j]}" in
      *g*)
        gl="${ws[$j]%%[*?[]*}"
        case "$gl" in
          -*=*) ;;
          ''|-*) block "git $sub with a computed path or revision the credential guard cannot list" ;;
        esac
        ;;
    esac
  done
  case "$sub" in grep) pat=1 ;; format-patch|fast-export) patch=1 ;; difftool) sub='diff' ;; esac
  # log, whatchanged and the diff plumbing print no file contents without a
  # patch option. A reflog walk (log -g, git reflog) reaches commits the
  # history no longer holds, so it counts as any commit.
  case "$sub" in
    log|whatchanged|diff-tree|diff-index|diff-files)
      for w in ${ws[@]+"${ws[@]}"}; do
        case "$sub:$w" in
          log:-g|log:--walk-reflogs) anyrev=1 ;;
          # Exact --follow, before or after --. rev-list does not follow.
          log:--follow) cntok=0 ;;
        esac
      done
      # A -c or --config-env on the git command can set log.follow.
      [ "$sub" = log ] && [ "${GP_CFGOVR:-0}" != 0 ] && cntok=0
      for w in ${ws[@]+"${ws[@]}"}; do
        case "$w" in -p|-u|--patch|-U*|--unified*|--patch-with-stat|--patch-with-raw|-c|--cc|--word-diff*|--color-words*|-L*) patch=1 ;; esac
        gp_short_patch "$w" "$sub" && patch=1
      done
      [ "$patch" = 1 ] || return 0
      ;;
  esac
  for ((j = 0; j < ${#ws[@]}; j++)); do
    w="${ws[$j]}"; fl="${fs[$j]}"
    if [ "$skip" = 1 ]; then
      skip=0
      # -n / --max-count still consume their value; that value is the count.
      # Any other consumed word means log's count path is not safe.
      if [ "$cntnext" = 1 ]; then
        cntnext=0
        if [[ "$w" =~ ^[0-9]+$ ]]; then cnt="$w"; else cntok=0; fi
      elif [ "$sub" = log ]; then
        cntok=0
      fi
      continue
    fi
    if [ $endopts -eq 0 ] && [ "$lr" = 0 ]; then
      # log: -<n>, -n <n> and --max-count=<n> record a commit count. Any
      # other option means the limited listing is not safe. Not whatchanged:
      # it skips merges, so rev-list would count different commits.
      case "$sub" in
        log)
          case "$w" in
            --|-) ;;
            -*)
              case "$w" in
                -p|-u|--patch|--patch-with-stat|--patch-with-raw|-c|--cc|-m|--numstat|--shortstat|\
                --name-only|--name-status|--summary|--raw|--oneline|--no-color|--color|--no-decorate|\
                --abbrev-commit|--no-abbrev-commit|--no-ext-diff|--no-textconv|--no-renames|--binary|\
                --text|--full-index|--no-prefix|--stat) ;;
                --stat=*|--color=*|--decorate=*|--format=*|--pretty=*) ;;
                --unified=*) [[ "$w" =~ ^--unified=[0-9]+$ ]] || cntok=0 ;;
                # Glued cluster of only p, u and U<digits> (-pU3, -pu, -U3).
                -U*) [[ "$w" =~ ^-([pu]+|[pu]*U[0-9]+)$ ]] || cntok=0 ;;
                -n|--max-count) cntnext=1 ;;
                --max-count=*)
                  if [[ "$w" =~ ^--max-count=[0-9]+$ ]]; then cnt="${w#--max-count=}"; continue; fi
                  cntok=0 ;;
                -n*)
                  if [[ "$w" =~ ^-n[0-9]+$ ]]; then cnt="${w#-n}"; continue; fi
                  cntok=0 ;;
                -[0-9]*)
                  if [[ "$w" =~ ^-[0-9]+$ ]]; then cnt="${w#-}"; continue; fi
                  cntok=0 ;;
                *) [[ "$w" =~ ^-([pu]+|[pu]*U[0-9]+)$ ]] || cntok=0 ;;
              esac
              ;;
          esac
          ;;
      esac
      # Options that take the next word as their value.
      case "$sub:$w" in
        archive:-o|archive:--output|archive:--format|archive:--prefix|\
        grep:-A|grep:-B|grep:-C|grep:-m|grep:--max-count|grep:--max-depth|grep:--threads|\
        format-patch:-o|format-patch:--output-directory|format-patch:--subject-prefix|format-patch:--to|\
        format-patch:--cc|format-patch:--in-reply-to|format-patch:--suffix|format-patch:--start-number|\
        format-patch:-v|format-patch:--reroll-count|format-patch:--signature|format-patch:--signature-file|\
        format-patch:--base|format-patch:--interdiff|format-patch:--range-diff|format-patch:--creation-factor|\
        format-patch:--add-header|format-patch:--filename-max-length|format-patch:--cover-from-description|\
        diff:-x|diff:--extcmd|diff:-t|diff:--tool|[lsdw]*:-l|\
        [lsdfw]*:--rotate-to|[lsdfw]*:--skip-to|[lsdfw]*:--inter-hunk-context|[lsdfw]*:--anchored|\
        [lsdfw]*:--diff-algorithm|[lsdfw]*:--src-prefix|[lsdfw]*:--dst-prefix|[lsdfw]*:--line-prefix|\
        [lsdfw]*:-I|[lsdfw]*:--ignore-matching-lines|[lsdfw]*:--color-moved-ws|[lsdfw]*:--word-diff-regex|\
        [lsdfw]*:--find-object|[lsdfw]*:--output|[lsdfw]*:--encoding|\
        [lsdw]*:-n|[lsdw]*:-G|[lsdw]*:-S|[lsdw]*:-O|[lsdw]*:--max-count|[lsdw]*:--skip|\
        [lsdw]*:--author|[lsdw]*:--committer|[lsdw]*:--grep|[lsdw]*:--since|[lsdw]*:--until|\
        [lsdw]*:--after|[lsdw]*:--before|[lsdw]*:--pretty|[lsdw]*:--format|[lsdw]*:--diff-filter) skip=1; continue ;;
        stash:-u|stash:--include-untracked|stash:--only-untracked) revs+=("$w"); continue ;;
        archive:-l|archive:--list|grep:-l|grep:-L|grep:--files-with-matches|grep:--files-without-match|grep:--name-only) return 0 ;;
        diff-tree:--stdin|fast-export:--stdin) stdin=1; continue ;;
        fast-export:--no-data|fast-export:--anonymize) return 0 ;;
        diff-tree:--root|format-patch:--root) revs+=("$w"); wide=1; continue ;;
      esac
      case "$w" in
        -) ;;
        --) endopts=1; unk=0; continue ;;
        --no-index) return 0 ;;
        --relative) paths+=("."); continue ;;
        --relative=*) paths+=("${w#--relative=}"); continue ;;
        --cached|--untracked) [ "$sub" != grep ] || return 0; revs+=("$w"); continue ;;
        --remote) redir=1; skip=1; continue ;;
        --remote=*) redir=1; continue ;;
        -e|-f) pat=0; skip=1; continue ;;
        -L) patch=1; lr=1; continue ;;
        -L?*) patch=1; lr=1; w="${w#-L}" ;;
        -p|-u|--patch|-U*|--unified*|--patch-with-stat|--patch-with-raw|-c|--cc|--word-diff*|--color-words*) patch=1; continue ;;
        -s|--no-patch|--stat*|--numstat|--shortstat|--name-only|--name-status|--summary|--raw|--dirstat*|--check) nopatch=1; continue ;;
        --full-diff|--follow) wide=1; revs+=("$w"); continue ;;
        --all|--branches*|--tags*|--remotes*|--glob=*|--staged|--merge-base) revs+=("$w"); continue ;;
        -*)
          # A glued cluster such as -pU3; any other option may take the next
          # word as its value, so that word is not trusted as a path or a
          # revision (it counts as every file and every commit).
          if gp_short_patch "$w" "$sub"; then
            patch=1
            [ "$sub" != stash ] || case "$w" in -*u*) revs+=(--include-untracked) ;; esac
            continue
          fi
          case "$w" in
            --*=*|-?) ;;
            *) case "$GP_NOARG_LONG" in *" $w "*) ;; *) [ "$sub" = archive ] || [ "$sub" = grep ] || unk=1 ;; esac ;;
          esac
          continue
          ;;
      esac
    fi
    if [ "$unk" = 1 ]; then
      unk=0
      case "$sub" in
        log|show|diff|whatchanged|format-patch|diff-tree|diff-index|diff-files|fast-export) anypath=1; anyrev=1; continue ;;
      esac
    fi
    case "$fl" in *v*) expand_vars "$w"; w="$EV" ;; esac
    # -L <start>,<end>:<path> or -L :<func>:<path> prints that file's history.
    if [ "$lr" = 1 ]; then
      lr=0
      if [[ "$w" =~ $GP_VAR_RE ]]; then anypath=1; else paths+=("${w##*:}"); fi
      continue
    fi
    if [ "$pat" = 1 ]; then pat=0; continue; fi
    # <ref>:<path> objects of show are checked by the show branch.
    case "$sub:$w" in
      archive:*|grep:*|bundle:*|stash:*|*::*) ;;
      *:*:*) if [ $endopts -eq 0 ]; then objw=1; [ "$sub" = log ] && cntok=0; continue; fi ;;
    esac
    if [[ "$w" =~ $GP_VAR_RE ]]; then
      case "$w" in *'$('*) block "git $sub with a computed path or revision the credential guard cannot list" ;; esac
      case "$sub" in
        archive|bundle|stash) block "git $sub with a computed path or revision the credential guard cannot list" ;;
        grep)
          # Input that xargs, find -exec or parallel feeds in (fed_git_check)
          # can be any revision or any path.
          if [ "${ws[$j]}" = '${__cg_fed}' ]; then anypath=1; anyrev=1; nrev=1; continue; fi
          # A bare variable before -- that is not read from input is taken as
          # a revision, as before.
          if [ $endopts -eq 0 ] && [[ "${ws[$j]}" =~ $GS_WHOLE_VAR_RE ]] && ! gs_read_bound "${BASH_REMATCH[1]}"; then continue; fi
          block "git grep with a computed path or revision the credential guard cannot list"
          ;;
      esac
      # A computed word is any file; before -- it may also be any revision.
      anypath=1
      [ $endopts -eq 1 ] || anyrev=1
      continue
    fi
    # An unquoted glob or brace: the shell expands it to file names before
    # git reads them (s?b names sub, t?ab a name with a tab), while git would
    # read the word as a pathspec that matches neither. A glob is expanded
    # here in the directory git runs in (dot files included, a superset of
    # the shell's match) and each name is listed; ** and braces count as
    # every file. A glob that matches nothing reaches git as it is, as in
    # bash. <ref>:<path> words are left to the show branch.
    GPG=""; GP_EO="$endopts"; GP_GCWD="$gcwd"; GP_SUB="$sub"
    case "$sub:$fl" in
      bundle:*|stash:*) ;;
      archive:*) [ $nrev -eq 0 ] || gp_glob_word "$w" "$fl" "$CUR_CWD" "${CG_CWD:-}" "$gcwd" ;;
      *) gp_glob_word "$w" "$fl" "$CUR_CWD" "${CG_CWD:-}" "$gcwd" ;;
    esac
    # Before --, the shell can expand a glob word to a revision git lists
    # without asking whether it is a file: a range (HEAD..oth* with a file
    # named HEAD..other), a ^ form (o* with a file named other^!), or any
    # name when the command has a -- after it (o* -- with a file named
    # other). The file may be created earlier in the same command, so a
    # match found now proves nothing: such a word counts as every commit and
    # every file.
    case "$GPG" in
      all|names)
        if [ $endopts -eq 0 ]; then
          case "$w" in
            *..*|*'^'*) GPG=allrev ;;
            *)
              for ((gp_k = 0; gp_k < ${#ws[@]}; gp_k++)); do
                [ "${ws[$gp_k]}" != -- ] || { GPG=allrev; break; }
              done
              ;;
          esac
        fi
        ;;
    esac
    case "$GPG" in
      opt) block "git $sub with a computed path or revision the credential guard cannot list" ;;
      allrev) anypath=1; anyrev=1; nrev=1; continue ;;
      all) anypath=1; continue ;;
      names) paths+=(${GPG_N[@]+"${GPG_N[@]}"}); wide=1; continue ;;
    esac
    if [ "$sub" = bundle ]; then
      if [ -z "$bfile" ]; then bfile="$w"; else revs+=("$w"); nrev=1; fi
      continue
    fi
    if [ "$sub" = stash ]; then revs+=("$w"); continue; fi
    case "$sub" in
      archive) if [ $nrev -eq 0 ]; then revs+=("$w"); nrev=1; else paths+=("$w"); fi; continue ;;
    esac
    if [ $endopts -eq 1 ]; then paths+=("$w"); continue; fi
    case "$sub" in
      grep) if git -C "$gcwd" rev-parse --verify -q "$w^{tree}" >/dev/null 2>&1; then revs+=("$w"); nrev=1; else paths+=("$w"); fi ;;
      *)
        # log count: only a verified plain commit. Other spellings keep the full listing.
        if [ "$sub" = log ]; then
          case "$w" in
            *:/*|:*|*..*) cntok=0 ;;
            *'^!'*) cntok=0 ;;
            *'^@'*) cntok=0 ;;
            ^*) cntok=0 ;;
            *'@{'*) cntok=0 ;;
          esac
        fi
        case "$w" in *..*) revs+=("$w"); nrev=1; [ "$sub" = log ] && cntok=0; continue ;; esac
        local peel='^{commit}'
        case "$sub" in diff|diff-tree|diff-index) peel='^{tree}' ;; esac
        if git -C "$gcwd" rev-parse --verify -q "$w$peel" >/dev/null 2>&1; then
          revs+=("$w"); nrev=1
        elif git -C "$gcwd" rev-parse "$w" -- >/dev/null 2>&1; then
          # A revision expression --verify does not take: <rev>^@ (its
          # parents), <rev>^! (the commit alone), <rev>^-<n>, ^<rev>. git
          # reads it as revisions, not a path, so the listing takes it as is.
          revs+=("$w"); nrev=1; [ "$sub" = log ] && cntok=0
        else
          paths+=("$w"); [ "$sub" = log ] && cntok=0
        fi
        ;;
    esac
  done
  case "$sub" in
    archive|grep)
      [ $nrev -eq 1 ] || return 0
      [ "$redir" = 0 ] || block "git $sub of a revision in a repository the credential guard cannot list"
      ;;
    bundle)
      [ "$bfile" = - ] && [ ${#revs[@]} -gt 0 ] || return 0
      [ "$redir" = 0 ] || block "git bundle of a repository the credential guard cannot list"
      ;;
    *)
      if [ "$sub" = stash ] && [ "$patch" = 0 ] && [ "$nopatch" = 0 ]; then
        # git stash show prints a patch by default when stash.showPatch is set.
        [ "$(git -C "$gcwd" config --bool --get stash.showPatch 2>/dev/null)" != true ] || patch=1
        # The command line can set it too (-c, GIT_CONFIG_*, --config-env).
        lc_word "$STRIPPED"
        case "$LCW" in *stash.showpatch*) patch=1 ;; esac
      fi
      if [ "$sub" = stash ]; then
        lc_word "$STRIPPED"
        case "$LCW" in *stash.showincludeuntracked*) revs+=(--include-untracked) ;; esac
      fi
      case "$sub" in show|diff) [ "$nopatch" = 1 ] || patch=1 ;; esac
      [ "$patch" = 1 ] || return 0
      # diff-tree --stdin reads its commits from input: any commit.
      [ "$stdin" = 0 ] || anyrev=1
      # git show of <ref>:<path> objects only (checked by the show branch).
      if [ "$sub" = show ] && [ "$objw" = 1 ] && [ $nrev -eq 0 ] && [ "$anyrev" = 0 ] && [ ${#paths[@]} -eq 0 ] && [ "$anypath" = 0 ]; then
        return 0
      fi
      [ "$redir" = 0 ] || block "git $sub patch output in a repository the credential guard cannot list"
      ;;
  esac
  # The tokenizer turns a tab inside a word into a space and a newline into
  # \003, so such a path names a different file than git reads (a tracked
  # 't<TAB>ab/.npmrc' would be listed as 't ab'). A path with \003, or with a
  # space when the command holds a tab or ANSI-C quoting ($'\t', $'\cI'),
  # counts as every file.
  local qp
  for qp in ${paths[@]+"${paths[@]}"}; do
    case "$qp" in
      *$'\003'*) anypath=1 ;;
      *' '*) case "${CMD:-}" in *$'\t'*|*"\$'"*) anypath=1 ;; esac ;;
    esac
  done
  # The user's paths, before a missing pathspec is widened below.
  local upaths=()
  upaths=(${paths[@]+"${paths[@]}"})
  # No pathspec, or a computed one: git prints every file, so list the names
  # a credential file can have.
  if [ "$anypath" = 1 ] || [ ${#paths[@]} -eq 0 ]; then
    paths=("${CRED_GIT_PATHSPECS[@]}"); wide=1
  fi
  # Paths that are all existing regular files (no glob, no pathspec magic)
  # print only themselves; their names are checked as operands.
  if [ "$wide" = 0 ]; then
    local pth plain=1
    for pth in "${paths[@]}"; do
      case "$pth" in :*|*'*'*|*'?'*|*'['*) plain=0 ;; esac
      { [ -f "$gcwd/$pth" ] && [ ! -L "$gcwd/$pth" ]; } || plain=0
    done
    [ "$plain" = 0 ] || return 0
  fi
  local r rv=()
  for r in ${revs[@]+"${revs[@]}"}; do
    case "$sub:$r" in archive:-*|grep:-*) ;; *) rv+=("$r") ;; esac
  done
  local mode
  case "$sub" in
    archive|grep) mode=tree ;;
    bundle) mode=log ;;
    stash) mode=stash ;;
    diff) mode='diff' ;;
    diff-tree) mode=difftree ;;
    diff-index) mode=diffindex ;;
    diff-files) mode=difffiles ;;
    show) mode=show; [ ${#rv[@]} -gt 0 ] || rv=(HEAD) ;;
    format-patch) mode=log; rv+=(HEAD) ;;
    *) mode=log; [ ${#rv[@]} -gt 0 ] || rv=(HEAD) ;;
  esac
  [ "$anyrev" = 0 ] || mode=any
  # A commit count (-1, -n 1, --max-count=1) on log names those commits
  # only, so the listing must not walk the rest of history. rev-list
  # selects them and show lists the files each one touches. It applies
  # only with no path, no --follow and no command-line config. Any other
  # option, or a rev-list that fails, keeps the full listing below.
  if [ "$sub" = log ]; then
    if [ -n "$cnt" ] && [ "$cntok" = 1 ] && [ "$anyrev" = 0 ] && [ "$anypath" = 0 ] && [ "$stdin" = 0 ] && [ ${#upaths[@]} -eq 0 ]; then
      local rr rvdash=0
      for rr in ${rv[@]+"${rv[@]}"}; do
        case "$rr" in -*) rvdash=1 ;; esac
      done
      if [ "$rvdash" = 0 ]; then
        local commits="" rc=0 cmt
        local carr=()
        commits="$(git -C "$gcwd" rev-list --max-count="$cnt" "${rv[@]}" -- ${upaths[@]+"${upaths[@]}"} 2>/dev/null)" || rc=$?
        if [ "$rc" -eq 0 ]; then
          if [ -z "$commits" ]; then return 0; fi
          while IFS= read -r cmt; do
            [ -n "$cmt" ] || continue
            carr+=("$cmt")
          done <<< "$commits"
          git_tree_has_cred "$gcwd" show ${carr[@]+"${carr[@]}"} -- "${paths[@]}" || return 0
          block "git $sub output that covers a tracked credential file"
        fi
      fi
    fi
  fi
  git_tree_has_cred "$gcwd" "$mode" ${rv[@]+"${rv[@]}"} -- "${paths[@]}" || return 0
  block "git $sub output that covers a tracked credential file"
}

GS_WHOLE_VAR_RE='^\$\{?([A-Za-z_][A-Za-z0-9_]*|[0-9]+)\}?$'
GIT_WORD_IN_RE='(^|[^[:alnum:]_.-])git([^[:alnum:]_.-]|$)'
GIT_SHELL_PASS_RE='^[[:space:]]*(command[[:space:]]+)?([^[:space:];&|<>$`()]*/)?git([[:space:]]+([^;&|<>$`()]*))?[[:space:]]*$'
# gs_read_bound <name>: 0 when the variable may hold a line read from input
# (`while read -r ref; do git show "$ref"; done < list`).
# Any name counts when the command reads input into variables at all (a bare
# `read` sets REPLY; mapfile and readarray fill arrays a loop then walks).
GS_READS_RE='(^|[^[:alnum:]_])(read|readarray|mapfile)([^[:alnum:]_]|$)'
gs_read_bound() {
  [[ "$CMD" =~ $GS_READS_RE ]]
}

# CG_URL_MULTI_RE: a command line with more than one command, a subshell,
# a substitution or a redirect, or an option that changes the directory.
CG_URL_MULTI_RE=$'[;&|()<>`\n]|[$][(]|(^|[[:space:]])(-C|--git-dir|--work-tree|--prefix)([=[:space:]]|$)'
# Directory creators that can make a scheme-named folder (https:) before a
# later URL word in the same command line.
CG_URL_DIRCREATE_RE='(^|[[:space:];|&])(ln|mkdir|install)[[:space:]]'
# CG_CURL_NOVAL_RE, CG_WGET_NOVAL_RE: options of curl and wget that take no
# value. A word after one of these, after a non-option word or after -- is a
# positional URL operand. A word after any other option may be that option's
# value (curl -T f, -K f, wget --post-file f, -i f), which the tool can read
# as a local file, so it keeps the path rule.
CG_CURL_NOVAL_RE='^(-[0-46aBfgGiIjJklLMnNOpqRsSvVZ#]+|--(silent|show-error|location|location-trusted|fail|fail-with-body|fail-early|head|include|insecure|verbose|compressed|globoff|get|http0[.]9|http1[.]0|http1[.]1|http2|http2-prior-knowledge|http3|http3-only|remote-name|remote-name-all|remote-header-name|remote-time|progress-bar|create-dirs|ipv4|ipv6|raw|ssl-reqd|tcp-nodelay|tcp-fastopen|append|list-only|disable|disable-eprt|disable-epsv|digest|basic|ntlm|anyauth|negotiate|path-as-is|styled-output|no-[a-z0-9-]+))$'
CG_WGET_NOVAL_RE='^(-(n[vcdHp]|[46bcdEFhHkKmNpqrSvVx])+|--(quiet|verbose|debug|continue|recursive|mirror|timestamping|server-response|spider|page-requisites|convert-links|adjust-extension|span-hosts|inet4-only|inet6-only|content-disposition|show-progress|force-directories|protocol-directories|trust-server-names|backup-converted|force-html|background|ignore-case|keep-session-cookies|retry-connrefused|no-[a-z0-9-]+))$'

# fed_cmd <start> <end> <depth>: the command that xargs, find -exec or
# parallel runs gets the same analysis as a command line (xargs sh -c
# 'cat f', xargs git -c alias.x='!cat f' x). The input the tool adds is not
# known; the words given are analysed. CW and CF are restored afterwards.
fed_cmd() {
  local s="$1" e="$2" d="$3" j t="" sep=""
  [ "$s" -lt "$e" ] || return 0
  for ((j = s; j < e; j++)); do gc_quote "${CW[$j]}" "${CF[$j]}"; t="$t$sep$GQ"; sep=" "; done
  local fc_cw=("${CW[@]}") fc_cf=("${CF[@]}")
  analyze_cmd "$t" $((d + 1)) "$CUR_CWD"
  CW=("${fc_cw[@]}"); CF=("${fc_cf[@]}")
  return 0
}

# check_operand <word> <flags> <cwd> [url_ok]: an operand of a command that
# is not on the safe list. url_ok=1 marks a positional URL operand of curl or
# wget (see check_generic); option values never get it.
check_operand() {
  local w="$1" f="$2" cwd="$3" url_ok="${4:-0}" rp nc=0 skip=0
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  # A URL operand is not a file, but only a URL with a host and no ..
  # segment, and no zsh glob mark: a folder named a: makes a://../i#d_rsa
  # a path that zsh expands (git diff --no-index /dev/null a://../i#d_rsa).
  case "$w" in
    file:*)
      if [ "${CG_WIN_HOST:-0}" = 1 ]; then
        cg_win_file_url "${w:5}"; w="$CG_FU"
      else
        case "$w" in file://*) w="${w:7}" ;; esac
      fi
      ;;
    [a-z]*://[!/]*)
      case "$f" in
        *z*) ;;
        *)
          case "$w" in
            *'/..'|*'/../'*|*'/.'|*'/./'*) ;;
            http://*|https://*|ssh://*|git://*|ftp://*|ftps://*|git+ssh://*|git+https://*|git+http://*|ssh+git://*|ws://*|wss://*)
              # A folder named like the scheme (https:) makes the word a path.
              # The folder can also be made earlier in the same command line
              # (ln -s .. https: && ...) or sit in another directory (git -C),
              # so the word stays a URL only in a single simple command that
              # changes no directory. A positional URL operand of curl or
              # wget (url_ok=1) is fetched, never read as a path, so it stays a
              # URL in a multi-command line too (`for id in ...; do curl
              # https://host?v=$id; done`, feedback_27e97d5d), unless the line
              # also runs ln, mkdir or install. Option values (curl -T, -K,
              # wget --post-file) do not get url_ok and keep the rule above.
              if [ -e "$cwd/${w%%:*}:" ] || [ -e "${w%%:*}:" ]; then
                :
              elif [[ "$STRIPPED" =~ $CG_URL_MULTI_RE ]] \
                && { [ "$url_ok" != 1 ] || [[ "$STRIPPED" =~ $CG_URL_DIRCREATE_RE ]]; }; then
                :
              else
                skip=1
              fi ;;
          esac
          ;;
      esac
      ;;
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
  # On Windows NP_ALT is the cwd reading of a drive-relative C:x (see
  # resolve_dir); it gets the same name and link checks as NP.
  local np_dir
  for np_dir in ${RD_CHECK[@]+"${RD_CHECK[@]}"} "$NP"; do
    [ -n "$np_dir" ] || continue
    if is_secret_dir "$np_dir"; then
      block "a command reading a credential directory ($(show_path "$np_dir"))"
    fi
    if [ -n "$REALPATH_BIN" ] && [ -L "$np_dir" ] && [ -d "$np_dir" ]; then
      rp=$("$REALPATH_BIN" "$np_dir" 2>/dev/null) || rp=""
      if [ -n "$rp" ] && is_secret_dir "$rp"; then
        block "a command reading a credential directory ($(show_path "$np_dir") -> $(show_path "$rp"))"
      fi
    fi
  done
}

# check_generic <start> <end> <cwd> [cmd]: every operand and option value.
# For curl and wget, an operand is a positional URL (url_ok=1) when it follows
# --, a non-option word, an option with its value attached (--x=v) or an
# option that takes no value; any other option's next word may be its value.
check_generic() {
  local s="$1" e="$2" cwd="$3" cmd="${4:-}" j w f endopts=0 noval_re="" pos=1
  case "$cmd" in
    curl) noval_re="$CG_CURL_NOVAL_RE" ;;
    wget) noval_re="$CG_WGET_NOVAL_RE" ;;
  esac
  for ((j = s; j < e; j++)); do
    w="${CW[$j]}"; f="${CF[$j]}"
    if [ $endopts -eq 0 ] && [ "$w" = "--" ]; then endopts=1; pos=1; continue; fi
    if [ $endopts -eq 0 ] && [[ "$w" == -?* ]]; then
      if [[ "$w" == --*=* ]]; then
        check_operand "${w#*=}" "$f" "$cwd"
        pos=1
      else
        if [[ "$w" != --* ]] && [ ${#w} -gt 2 ]; then
          check_operand "${w:2}" "$f" "$cwd"
        fi
        pos=0
        if [ -n "$noval_re" ] && [[ "$w" =~ $noval_re ]]; then pos=1; fi
      fi
      continue
    fi
    if [ -n "$noval_re" ] && [ $pos -eq 1 ]; then
      check_operand "$w" "$f" "$cwd" 1
    else
      check_operand "$w" "$f" "$cwd"
    fi
    pos=1
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
  case "$1" in */.ssh|*/.ssh/*|*/.aws|*/.aws/*|*/.hq/secrets-cache|*/.hq/secrets-cache/*) r=0 ;; esac
  [ "$nc" -eq 1 ] || shopt -u nocasematch
  return $r
}

# is_cred_store <normalized path>: a directory whose name makes the files in
# it credentials (.ssh/id_x, .docker/config.json, .config/gh/hosts.yml).
is_cred_store() {
  local r=1 nc=0
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  case "$1" in */.ssh|*/.aws|*/.docker|*/.gem|*/.config|*/.config/gh|*/.hq/secrets-cache) r=0 ;; esac
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
    local cs_rd=("$NP") cs_r cs_m
    if [ "${CG_WIN_HOST:-0}" = 1 ]; then
      [ -z "$NP_W" ] || cs_rd+=("$NP_W")
      cg_win_readings "$cand" "$cwd"
      [ ${#CG_RDS[@]} -eq 0 ] || cs_rd+=("${CG_RDS[@]}")
    fi
    matches=("${cs_rd[@]}")
    case "$fl" in
      *g*)
        matches=()
        local old_ifs="$IFS"
        shopt -s nullglob
        IFS=
        for cs_r in "${cs_rd[@]}"; do
          # shellcheck disable=SC2206 # glob expansion is the point.
          cs_m=($cs_r)
          [ ${#cs_m[@]} -eq 0 ] || matches+=("${cs_m[@]}")
        done
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
  local ops_t=() ops_f=() scripts=() incs=()
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
            --include|--glob|--iglob|--file-search-regex) incs+=("${w#*=}") ;;
            --target-directory|--output|--suffix|--label|--exclude|--exclude-dir) ;;
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
        # ag --file-search-regex PATTERN (long form of -G): the filter is
        # recorded, and the next word keeps its usual checks as a pattern or
        # operand.
        if [ "$cmd" = "ag" ] && [ "$o" = "--file-search-regex" ] && [ $((j + 1)) -lt $e ]; then
          incs+=("${CW[$((j + 1))]}")
        fi
        if long_takes_arg "$cmd" "$o"; then
          if [ $((j + 1)) -lt $e ]; then
            case "$o" in
              --regexp|--expression) scripts+=("${CW[$((j + 1))]}") ;;
              --file|--from-file|--ignore-file) ops_t+=("${CW[$((j + 1))]}"); ops_f+=("${CF[$((j + 1))]}") ;;
              --include|--glob|--iglob|--file-search-regex) incs+=("${CW[$((j + 1))]}") ;;
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
            case "$cmd:$ch" in rg:g|ag:G) incs+=("$arg") ;; esac
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

  # A recursive search limited to credential file names (grep -rl
  # --include=.env TOKEN dir, rg -l -g '.env') is refused loudly, -l or not.
  # Its result cannot be trusted: grep builds and sandboxes that skip hidden
  # or git-ignored files leave real .env files out without a warning, so an
  # empty or partial list reads as "not in any env file"; without -l the
  # matching lines print the secrets (feedback 166f01a7).
  if [ $recursive -eq 1 ]; then
    local g
    for g in ${incs[@]+"${incs[@]}"}; do
      if glob_names_cred "$g"; then
        block "recursive $cmd limited to credential files ($g): such a search can skip hidden or git-ignored files such as .env without a warning, so its results look complete when they are not. List the files with find <dir> -name '$g' -type f, then run grep -l PATTERN on each named path."
      fi
    done
  fi

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
      local rd_x
      for rd_x in ${RD_CHECK[@]+"${RD_CHECK[@]}"}; do
        if is_cred_dir "$rd_x"; then
          block "recursive read of a directory that holds credentials ($(show_path "$rd_x"))"
        fi
      done
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
  # Values the command gets in its environment from NAME=value prefixes
  # (also after env), checked below when it is an interpreter.
  local env_text=""
  # assignments and prefixes
  j=$s
  while [ $j -lt $e ]; do
    w="${CW[$j]}"
    if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]]; then
      assign_word "$w"
      env_text="$env_text $EV'"
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
          # env -S / --split-string splits one word into the command and its
          # environment, which the guard does not parse: fail closed when the
          # command names a credential word (review C1 of PR 1911).
          if [ "$b" = "env" ] && [ "$CG_CRED_NAMED" -eq 1 ]; then
            case "$w" in
              --split-string|--split-string=*)
                block "env -S (split string) in a command that names a credential file" ;;
              --*) ;;
              -*S*)
                block "env -S (split string) in a command that names a credential file" ;;
            esac
          fi
          if [[ "$w" == -?* ]]; then
            local optc="${w:1:1}"
            if [ ${#w} -eq 2 ] && [ -n "$pa" ] && [[ "$pa" == *"$optc"* ]]; then j=$((j + 2)); else j=$((j + 1)); fi
            continue
          fi
          if [ "$b" = "env" ] && [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            local ev="${w#*=}"
            case "$ev" in "~"|"~/"*) ev="$H${ev#"~"}" ;; esac
            expand_vars "$ev"
            env_text="$env_text $EV'"
            j=$((j + 1)); continue
          fi
          break
        done
        if [ "$b" = "timeout" ] || [ "$b" = "gtimeout" ]; then j=$((j + 1)); fi
        continue
        ;;
      function)
        # `function f { body; }` on one line: the name is not a command and
        # the body is (it used to be skipped with the keyword). The parser
        # splits `()` off as operators, so only the name is skipped.
        j=$((j + 2)); continue ;;
      for|select)
        # A glob in the list (for f in ~/.n*) names files that reach the
        # body through the loop variable: check it as a read operand.
        local k3 CG_ZOK=0
        for ((k3 = j + 1; k3 < e; k3++)); do
          case "${CF[$k3]}" in
            *g*) check_word "${CW[$k3]}" "${CF[$k3]}" "$CUR_CWD" ;;
          esac
        done
        return 0 ;;
      case|in)
        return 0 ;;
      export|local|declare|readonly|typeset)
        local k2 exp=0
        [ "$b" = "export" ] && exp=1
        for ((k2 = j + 1; k2 < e; k2++)); do
          case "$b:${CW[$k2]}" in declare:-*x*|typeset:-*x*|local:-*x*) exp=1 ;; esac
        done
        for ((k2 = j + 1; k2 < e; k2++)); do
          w="${CW[$k2]}"
          if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]]; then
            assign_word "$w"
            if [ "$exp" -eq 1 ]; then
              CG_EXPORTED="$CG_EXPORTED $EV'"
              CG_EXPORT_NAMES="$CG_EXPORT_NAMES$AN "
            fi
          elif [ "$exp" -eq 1 ] && [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            # export F before or after F=/path/.env: F's value (now, or once
            # it is set later in the command) reaches the environment.
            CG_EXPORT_NAMES="$CG_EXPORT_NAMES$w "
          fi
        done
        return 0
        ;;
    esac
    break
  done
  [ $j -lt $e ] || return 0
  # set -a / set -o allexport exports every later assignment. printf -v F
  # assigns F; its words are kept (CG_PFV_*), so a path in the format or the
  # arguments is seen when F is exported.
  case "${CW[$j]}" in
    set)
      local k4
      for ((k4 = j + 1; k4 < e; k4++)); do
        case "${CW[$k4]}" in
          --*) ;;
          -*a*) CG_ALLEXPORT=1 ;;
          allexport) [ "${CW[$((k4 - 1))]}" = "-o" ] && CG_ALLEXPORT=1 ;;
        esac
      done
      ;;
    shopt)
      # shopt -so allexport / shopt -s -o allexport is set -o allexport
      # (review C1 of PR 1911). An option name from a variable counts too
      # when the command names a credential word.
      local k4b so_s=0 so_o=0
      for ((k4b = j + 1; k4b < e; k4b++)); do
        case "${CW[$k4b]}" in
          -*) [[ "${CW[$k4b]}" == *s* ]] && so_s=1; [[ "${CW[$k4b]}" == *o* ]] && so_o=1 ;;
          allexport) [ "$so_s" -eq 1 ] && [ "$so_o" -eq 1 ] && CG_ALLEXPORT=1 ;;
          *$'\001'*|*'$'*) [ "$so_o" -eq 1 ] && [ "$CG_CRED_NAMED" -eq 1 ] && CG_ALLEXPORT=1 ;;
        esac
      done
      ;;
    printf)
      local k5 pv="" pt="" psep=""
      for ((k5 = j + 1; k5 < e; k5++)); do
        if [ -z "$pv" ]; then
          case "${CW[$k5]}" in
            -v) pv="${CW[$((k5 + 1))]:-}"; k5=$((k5 + 1)); continue ;;
            -v?*) pv="${CW[$k5]#-v}"; continue ;;
          esac
        fi
        pt="$pt$psep${CW[$k5]}"; psep=" "
      done
      if [ -n "$pv" ] && [[ "$pv" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        expand_vars "$pt"
        CG_PFV_N+=("$pv"); CG_PFV_V+=("$EV")
      fi
      ;;
  esac
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
  # zsh short forms (while [[ c ]] { body }, if [[ c ]] { body }) put the
  # body in the same simple command after ]]: analyze it as a command.
  if [ "$cmd" = '[[' ]; then
    local k4
    for ((k4 = j + 1; k4 < e; k4++)); do
      if [ "${CW[$k4]}" = ']]' ]; then
        [ $((k4 + 1)) -ge "$e" ] || analyze_simple $((k4 + 1)) "$e" "$depth"
        break
      fi
    done
  fi
  # Operands of git and npm-family tools are revisions and version ranges
  # (HEAD^, pkg@^1), not zsh globs: check_word lets a z word through.
  local CG_ZOK=0
  case "$cmd" in git|npm|pnpm|yarn|npx|bun) CG_ZOK=1 ;; esac
  [ "$cmd" != "popd" ] || CWD_UNCERTAIN=1
  # A name defined as an alias runs its body with these arguments appended.
  # While a body is expanded its own name is not expanded again, as in bash.
  local k2
  for ((k = ${#CG_ALIAS_N[@]} - 1; k >= 0; k--)); do
    [ "${CG_ALIAS_N[$k]}" = "${CW[$j]}" ] || continue
    case "$CG_ALIAS_SKIP" in *" ${CG_ALIAS_N[$k]} "*) break ;; esac
    joined="${CG_ALIAS_B[$k]}"
    for ((k2 = a; k2 < e; k2++)); do joined="$joined ${CW[$k2]}"; done
    local CG_ALIAS_SKIP="$CG_ALIAS_SKIP${CG_ALIAS_N[$k]} "
    analyze_cmd "$joined" $((depth + 1)) "$CUR_CWD"
    return 0
  done
  case "$cmd" in
    cd|pushd)
      local target=""
      for ((k = a; k < e; k++)); do
        case "${CW[$k]}" in -?*) continue ;; esac
        target="${CW[$k]}"; resolve_dir "$target" "${CF[$k]}" "$CUR_CWD"
        [ ${#RD_EXTRA[@]} -eq 0 ] || CWD_UNCERTAIN=1
        [ "$NP_ALT_ROOT" = 0 ] || [ -z "$NP_ALT" ] || NP="$NP_ALT"
        # A Windows-form target is opened with Windows rules, so ".." stops
        # at the drive root (cd 'C:\..' is C:\).
        case "$target" in
          *\\*|[A-Za-z]:*) [ -z "$RD_NP_W" ] || [ "$NP_ALT_ROOT" = 1 ] || NP="$RD_NP_W" ;;
        esac
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
      # BASH_ENV and ENV name a file the shell sources before it runs
      # anything (BASH_ENV=.env bash -xc : prints it), as do --init-file and
      # --rcfile: each is a read of that file (review C2 of PR 1911).
      local sk si sv
      for ((sk = s; sk < a; sk++)); do
        case "${CW[$sk]}" in
          BASH_ENV=*|ENV=*)
            sv="${CW[$sk]#*=}"
            case "$sv" in "~"|"~/"*) sv="$H${sv#"~"}" ;; esac
            expand_vars "$sv"
            shell_env_file "$EV" "${CF[$sk]}"
            ;;
        esac
      done
      for ((si = 0; si < ${#VAR_NAMES[@]}; si++)); do
        case "${VAR_NAMES[$si]}" in
          BASH_ENV|ENV)
            if [ "$CG_ALLEXPORT" -eq 1 ] || [[ "$CG_EXPORT_NAMES" == *" ${VAR_NAMES[$si]} "* ]]; then
              shell_env_file "${VAR_VALS[$si]}" ""
            fi
            ;;
        esac
      done
      for ((k = a; k < e; k++)); do
        w="${CW[$k]}"
        case "$w" in
          --rcfile|--init-file)
            k=$((k + 1))
            [ $k -lt $e ] && check_word "${CW[$k]}" "${CF[$k]}" "$CUR_CWD"
            continue ;;
          --rcfile=*|--init-file=*)
            check_word "${w#*=}" "${CF[$k]}" "$CUR_CWD"; continue ;;
          -*c*)
            if [[ "$w" != --* ]] && [ $((k + 1)) -lt $e ]; then
              subst_code_check "${CW[$((k + 1))]}" "$cmd -c"
              analyze_cmd "${CW[$((k + 1))]}" $((depth + 1)) "$CUR_CWD"
              return 0
            fi
            ;;
          # `bash -O dotglob -c ...` / `-o pipefail`: the option name is not
          # the script, so skip it and keep looking for -c (review C2).
          -O|+O|-o|+o) k=$((k + 1)) ;;
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
      # git runs some configuration values as commands: an alias that starts
      # with ! is a shell command (git -c alias.x='!cat f' x), any other
      # alias is a git command line, and pager, editor, sshCommand,
      # textconv, credential helper, filter and similar keys name a program.
      # Such a value given with -c, in a GIT_CONFIG_VALUE_<n> or
      # GIT_CONFIG_PARAMETERS variable, or set with git config is analysed
      # as a command, with the arguments after the subcommand appended.
      # --config-env takes the value from a variable the guard cannot read.
      local gc_v=() gc_key gc_val k6 gc_args="" gc_cfg=0
      # Configuration from GIT_CONFIG_PARAMETERS or GIT_CONFIG_COUNT/KEY/VALUE
      # (also exported earlier) is quoted in git's own format: blocked.
      # GIT_EXTERNAL_DIFF, GIT_PAGER, GIT_EDITOR, GIT_SSH_COMMAND and the like
      # name a command: their values (before git or assigned earlier in the
      # command) are analysed as commands.
      # Matched on STRIPPED (quotes and backslashes removed), so a word
      # split with quotes (pro''tocol, e\xt::) is matched as the shell joins it.
      case "$STRIPPED" in
        *GIT_CONFIG_PARAMETERS*|*GIT_CONFIG_COUNT*|*GIT_CONFIG_KEY_*|*GIT_CONFIG_VALUE_*)
          block "git configuration from GIT_CONFIG_* variables the credential guard cannot check" ;;
      esac
      # The ext:: transport runs its URL as a command, and the URL can come
      # from a url.<base>.insteadOf key: block ext:: and turning it on.
      local gc_nc=0
      shopt -q nocasematch && gc_nc=1
      shopt -s nocasematch
      case "$STRIPPED" in
        *ext::*|*protocol*allow*|*GIT_ALLOW_PROTOCOL*ext*|*GIT_ALLOW_PROTOCOL=*'$'*|*GIT_ALLOW_PROTOCOL=*'`'*)
          [ "$gc_nc" -eq 1 ] || shopt -u nocasematch
          block "git ext:: transport, which runs a command the credential guard cannot check" ;;
      esac
      [ "$gc_nc" -eq 1 ] || shopt -u nocasematch
      for ((k6 = s; k6 < e; k6++)); do
        case "${CW[$k6]}" in
          GIT_EXTERNAL_DIFF=*|GIT_PAGER=*|GIT_EDITOR=*|GIT_SEQUENCE_EDITOR=*|GIT_SSH_COMMAND=*|GIT_SSH=*|GIT_ASKPASS=*|GIT_PROXY_COMMAND=*|PAGER=*|EDITOR=*|VISUAL=*|SSH_ASKPASS=*)
            gc_v+=("!${CW[$k6]#*=}") ;;
        esac
      done
      for ((k6 = 0; k6 < ${#VAR_NAMES[@]}; k6++)); do
        case "${VAR_NAMES[$k6]}" in
          GIT_EXTERNAL_DIFF|GIT_PAGER|GIT_EDITOR|GIT_SEQUENCE_EDITOR|GIT_SSH_COMMAND|GIT_SSH|GIT_ASKPASS|GIT_PROXY_COMMAND|PAGER|EDITOR|VISUAL|SSH_ASKPASS)
            gc_v+=("!${VAR_VALS[$k6]}") ;;
        esac
      done
      k=$a
      # g_dir: the directory git reads (a literal -C applies); g_redir: the
      # repository is redirected in a way the listings below cannot follow;
      # g_cv: the -c values, one per element, for -c alias.NAME=VALUE;
      # g_cfgo: -c or --config-env appeared (log must not use the
      # commit-count shortcut).
      local g_dir="$CUR_CWD" g_redir=0 g_cfgo=0 k3
      local g_cv=()
      while [ $k -lt $e ]; do
        case "${CW[$k]}" in
          -C)
            if [ $((k + 1)) -lt $e ]; then
              resolve_dir "${CW[$((k + 1))]}" "${CF[$((k + 1))]}" "$g_dir"
              if [ -n "$NP" ]; then g_dir="$NP"; else g_redir=1; fi
              [ ${#RD_EXTRA[@]} -eq 0 ] || g_redir=1
              # ~+ and ~- are the shell's $PWD and $OLDPWD, ~user another
              # home: a directory the guard does not resolve.
              case "${CW[$((k + 1))]}" in '~'[!/]*) g_redir=1 ;; esac
            fi
            k=$((k + 2)); continue ;;
          -c)
            g_cfgo=1
            if [ $((k + 1)) -lt $e ]; then
              g_cv+=("${CW[$((k + 1))]}")
              gc_key="${CW[$((k + 1))]%%=*}"; gc_val="${CW[$((k + 1))]#*=}"
              # A computed key (protocol.$e.allow) can name any setting.
              case "$gc_key" in
                *'$'*|*'`'*) block "git -c with a computed key the credential guard cannot check" ;;
              esac
              if git_cmd_key "$gc_key"; then
                [ "$gc_key" = "${CW[$((k + 1))]}" ] || gc_v+=("$gc_val")
              fi
            fi
            k=$((k + 2)); continue ;;
          --config-env|--config-env=*)
            g_cfgo=1
            if [ "${CW[$k]}" = --config-env ]; then gc_key="${CW[$((k + 1))]:-}"; k=$((k + 2)); else gc_key="${CW[$k]#--config-env=}"; k=$((k + 1)); fi
            case "${gc_key%%=*}" in *'$'*|*'`'*) block "git -c with a computed key the credential guard cannot check" ;; esac
            git_cmd_key "${gc_key%%=*}" && block "git --config-env sets a command or alias from a variable the credential guard cannot read"
            continue ;;
          --git-dir|--work-tree|--namespace) g_redir=1; k=$((k + 2)); continue ;;
          --git-dir=*|--work-tree=*|--namespace=*) g_redir=1; k=$((k + 1)); continue ;;
          --attr-source|--super-prefix) k=$((k + 2)); continue ;;
          --*=*|-p|--paginate|-P|--no-pager|--bare|--no-replace-objects|--no-lazy-fetch|--no-optional-locks|--no-advice|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--exec-path|--html-path|--man-path|--info-path|--version|-v|--help|-h)
            k=$((k + 1)); continue ;;
          # An option that takes a separate value would hide the -c after it
          # (git --attr-source HEAD -c alias.x='!cat f' x).
          -*) block "a git option the credential guard does not know, before the git subcommand" ;;
        esac
        break
      done
      # A brace or glob word among git's options or as the subcommand
      # expands to other words ({-c,alias.x=log\ -p} x, {log,-p}, l?g when
      # a file log exists): the option and alias reads above take it as is.
      local gb_i
      for ((gb_i = a; gb_i <= k && gb_i < e; gb_i++)); do
        case "${CF[$gb_i]}" in
          *b*|*g*) block "a git option the credential guard does not know, before the git subcommand" ;;
        esac
      done
      if [ $k -lt $e ] && [ "${CW[$k]}" = config ]; then
        # git config [set] [--global|--file f ...] KEY VALUE
        local gc_w=() k7
        for ((k7 = k + 1; k7 < e; k7++)); do
          case "${CW[$k7]}" in
            -f|--file|--blob|--type|--default|--comment|--value) k7=$((k7 + 1)) ;;
            -*) ;;
            *) gc_w+=("${CW[$k7]}") ;;
          esac
        done
        case "${gc_w[0]:-}" in set|--add|add) gc_w=("${gc_w[@]:1}") ;; esac
        if [ ${#gc_w[@]} -ge 2 ] && git_cmd_key "${gc_w[0]}"; then
          gc_v+=("${gc_w[1]}")
        fi
        gc_cfg=1
      fi
      if [ ${#gc_v[@]} -gt 0 ]; then
        # Each argument is quoted, so a word stays one word (git passes it to
        # the alias as one argument: git -c alias.x='!sh -c' x 'cat f').
        for ((k6 = k + 1; gc_cfg == 0 && k6 < e; k6++)); do gc_quote "${CW[$k6]}" "${CF[$k6]}"; gc_args="$gc_args $GQ"; done
        local gc_cw=("${CW[@]}") gc_cf=("${CF[@]}") gc_b
        for gc_b in "${gc_v[@]}"; do
          case "$gc_b" in
            '!'*) analyze_cmd "${gc_b#!}$gc_args" $((depth + 1)) "$CUR_CWD" ;;
            *)
              [ -n "$gc_b" ] && analyze_cmd "$gc_b$gc_args" $((depth + 1)) "$CUR_CWD"
              [ -n "$gc_b" ] && analyze_cmd "git $gc_b$gc_args" $((depth + 1)) "$CUR_CWD"
              ;;
          esac
        done
        CW=("${gc_cw[@]}"); CF=("${gc_cf[@]}")
      fi
      [ $k -lt $e ] || return 0
      for ((k3 = s; k3 < a; k3++)); do
        case "${CW[$k3]}" in GIT_DIR=*|GIT_WORK_TREE=*|GIT_INDEX_FILE=*|GIT_OBJECT_DIRECTORY=*|GIT_ALTERNATE_OBJECT_DIRECTORIES=*|GIT_NAMESPACE=*|GIT_COMMON_DIR=*) g_redir=1 ;; esac
      done
      [ -z "${GIT_DIR:-}${GIT_WORK_TREE:-}${GIT_NAMESPACE:-}${GIT_OBJECT_DIRECTORY:-}${GIT_COMMON_DIR:-}" ] || g_redir=1
      [ "${CWD_UNCERTAIN:-0}" -eq 0 ] || g_redir=1
      # A git alias runs its text in place of the subcommand: resolve it (up to
      # five levels) and check what it expands to. A shell alias (!...) that
      # runs a git reader with operands, or an alias the command line itself
      # defines (its value is not known here), blocks.
      local g_sub="${CW[$k]}" g_n=0 g_rc g_aw=()
      local g_extra=()
      while :; do
        g_rc=0; git_alias_value "$g_sub" "$g_dir" ${g_cv[@]+"${g_cv[@]}"} || g_rc=$?
        [ "$g_rc" != 1 ] || break
        [ "$g_rc" != 2 ] || block "git alias $g_sub defined in the same command (the guard cannot read its value)"
        g_n=$((g_n + 1))
        [ $g_n -le 5 ] || block "git alias chain deeper than the credential guard follows"
        case "$GAV" in
          '!'*)
            # A body that only runs git (`!git`, `!/usr/bin/git show`,
            # `!command git`) gets the operands appended: read it as a plain
            # alias of the words after git.
            if [[ "${GAV#!}" =~ $GIT_SHELL_PASS_RE ]]; then
              GAV="${BASH_REMATCH[4]}"
              if [ -z "$GAV" ]; then
                k=$((k + 1))
                [ $k -lt $e ] || return 0
                g_sub="${CW[$k]}"
                continue
              fi
            else
              # Any other body runs in a shell with the operands appended:
              # refuse operands passed to git in it, and check it as a script.
              if [ $((k + 1)) -lt $e ] && [[ "$GAV" =~ $GIT_WORD_IN_RE ]]; then
                block "git shell alias $g_sub passing operands to git"
              fi
              local g_scw=("${CW[@]}") g_scf=("${CF[@]}")
              analyze_cmd "${GAV#!}" $((depth + 1)) "$g_dir"
              CW=("${g_scw[@]}"); CF=("${g_scf[@]}")
              break
            fi
            ;;
        esac
        # Split the alias text as git does: quotes and backslashes are
        # removed and a newline separates words (cg_split_cmdline).
        cg_split_cmdline "$GAV"
        g_aw=(${SCW[@]+"${SCW[@]}"})
        # Leading git options in the alias apply before its subcommand.
        k3=0
        while [ $k3 -lt ${#g_aw[@]} ]; do
          case "${g_aw[$k3]}" in
            -c) g_cv+=("${g_aw[$((k3 + 1))]:-}"); g_cfgo=1; k3=$((k3 + 2)) ;;
            -C|--git-dir|--work-tree|--namespace) g_redir=1; k3=$((k3 + 2)) ;;
            --config-env) g_cfgo=1; k3=$((k3 + 2)) ;;
            # Attached form steps one word, same as the -* arm below.
            --config-env=*) g_cfgo=1; k3=$((k3 + 1)) ;;
            -*) case "${g_aw[$k3]}" in --git-dir=*|--work-tree=*|--namespace=*) g_redir=1 ;; esac; k3=$((k3 + 1)) ;;
            *) break ;;
          esac
        done
        [ $k3 -lt ${#g_aw[@]} ] || break
        g_sub="${g_aw[$k3]}"
        g_extra=("${g_aw[@]:$((k3 + 1))}" ${g_extra[@]+"${g_extra[@]}"})
      done
      for w in ${g_extra[@]+"${g_extra[@]}"}; do check_operand "$w" "" "$CUR_CWD"; done
      # Seen by git_pathspec_read: command-line config drops log's count path.
      GP_CFGOVR="$g_cfgo"
      local k2 gs_w
      case "$g_sub" in
        archive|grep|log|diff|difftool|whatchanged|show|format-patch|diff-tree|diff-index|diff-files|fast-export)
          git_pathspec_read "$g_sub" $((k + 1)) "$e" "$g_dir" "$g_redir" ${g_extra[@]+"${g_extra[@]}"} ;;
        reflog)
          # git reflog [show] is git log -g: its -p prints the patches of
          # every commit the reflog reaches. Its other actions print no files.
          local g_act g_rest=()
          if [ ${#g_extra[@]} -gt 0 ]; then
            g_act="${g_extra[0]}"; g_rest=("${g_extra[@]:1}"); k2=$((k + 1))
          else
            g_act="${CW[$((k + 1))]:-}"; k2=$((k + 2))
          fi
          case "$g_act" in
            expire|delete|exists|list|drop) ;;
            show) git_pathspec_read log "$k2" "$e" "$g_dir" "$g_redir" -g ${g_rest[@]+"${g_rest[@]}"} ;;
            *) git_pathspec_read log $((k + 1)) "$e" "$g_dir" "$g_redir" -g ${g_extra[@]+"${g_extra[@]}"} ;;
          esac
          ;;
        stash|bundle)
          # git stash show and git bundle create: the action word comes from
          # the alias text or the command line.
          local g_act g_rest=()
          if [ ${#g_extra[@]} -gt 0 ]; then
            g_act="${g_extra[0]}"; g_rest=("${g_extra[@]:1}")
            k2=$((k + 1))
          else
            g_act="${CW[$((k + 1))]:-}"; k2=$((k + 2))
          fi
          case "$g_sub:$g_act" in
            stash:show) git_pathspec_read stash "$k2" "$e" "$g_dir" "$g_redir" ${g_rest[@]+"${g_rest[@]}"} ;;
            bundle:create) git_pathspec_read bundle "$k2" "$e" "$g_dir" "$g_redir" ${g_rest[@]+"${g_rest[@]}"} ;;
          esac
          ;;
        cat-file)
          # --batch and --batch-command print every object named on stdin (a
          # here-string, heredoc, pipe or file) or in the whole store: the
          # guard cannot see which files those are. --batch-check prints only
          # names, types and sizes.
          # git accepts any unique prefix of --batch-command, and an option
          # word can come from a variable: expand it, and when a variable
          # stays unknown and no literal mode (-p, -t, a type) is given, it
          # may be the option.
          local g_mode=0 g_unk=0
          for w in ${g_extra[@]+"${g_extra[@]}"}; do
            case "$w" in --batch-ch*|--batch-a*) ;; --batch*) block "git cat-file $w reading object names the credential guard cannot see" ;; -p|-t|-s|-e|blob|tree|commit|tag|--textconv|--filters) g_mode=1 ;; esac
          done
          for ((k2 = k + 1; k2 < e; k2++)); do
            w="${CW[$k2]}"
            case "${CF[$k2]}" in *v*) expand_vars "$w"; w="$EV" ;; esac
            case "$w" in
              --batch-ch*|--batch-a*) ;;
              --batch*) block "git cat-file $w reading object names the credential guard cannot see" ;;
              -p|-t|-s|-e|blob|tree|commit|tag|--textconv|--filters) g_mode=1 ;;
            esac
            [[ "${CW[$k2]}" =~ $GS_WHOLE_VAR_RE ]] && [[ "$w" =~ $GP_VAR_RE ]] && g_unk=1
          done
          if [ "$g_unk" = 1 ] && [ "$g_mode" = 0 ]; then
            block "git cat-file with an option the credential guard cannot read"
          fi
          ;;
      esac
      case "$g_sub" in
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
      # A :/ search selects a commit, even with an apparent :path suffix.
      # Never treat that suffix as a filesystem path or a safe tree proof.
      # Checked for the resolved subcommand (an alias such as show) and for
      # the word on the command line, over the command words and the words
      # an alias supplies.
      local gr_hit=0 gr_word
      case "${CW[$k]}" in show|cat-file|log|grep) gr_hit=1 ;; esac
      case "$g_sub" in show|cat-file|log|grep) gr_hit=1 ;; esac
      if [ "$gr_hit" = 1 ]; then
        for gr_word in ${g_extra[@]+"${g_extra[@]}"}; do
          case "$gr_word" in
            *:/*) block "git revision search reads a computed path the credential guard cannot prove" ;;
          esac
        done
        for ((k2 = k + 1; k2 < e; k2++)); do
          gr_word="${CW[$k2]}"
          case "${CF[$k2]}" in *v*) expand_vars "$gr_word"; gr_word="$EV" ;; esac
          case "$gr_word" in
            *:/*) block "git revision search reads a computed path the credential guard cannot prove" ;;
          esac
        done
      fi
      if [ "$g_sub" = show ] || [ "$g_sub" = cat-file ]; then
        # Read-only `git show <ref>:<path>` of tracked source: a computed file
        # name is proven against the ref's tree, not blocked blindly. The
        # proof runs in CUR_CWD, so anything that points git at another
        # repository or work tree disables it (gs_redirect=1).
        local gs_redirect=0 k3
        for ((k3 = s; k3 < k; k3++)); do
          case "${CW[$k3]}" in
            -C|-c|--git-dir|--git-dir=*|--work-tree|--work-tree=*|--namespace|--namespace=*|--exec-path|--exec-path=*|GIT_*=*) gs_redirect=1 ;;
          esac
        done
        case "$CMD" in *GIT_*) gs_redirect=1 ;; esac
        [ "${CWD_UNCERTAIN:-0}" -eq 0 ] || gs_redirect=1
        # An earlier step of the command could repoint the ref (checkout,
        # branch -f, a write under .git): the ls-tree proof would hold for a
        # tree git show no longer reads.
        gs_cmd_readonly || gs_redirect=1
        # The operand must stay one word: a computed part that bash
        # word-splits (unquoted $var or $(...), flag u) could carry a second
        # <ref>:<path> the proof never sees, unless every such part is a bare
        # loop variable bound over a word-split list (gs_split_free). A brace
        # word (flag b) expands to several operands and skips the proof.
        # A variable the analysis cannot resolve is unknown here even when
        # the command names no credential word (expand_vars keeps it literal
        # then): `git checkout x; ... git show "HEAD:src/$f"` must not pass as
        # the literal text `$f`. A computed <ref>:<path> operand is allowed
        # only through the tree proof; otherwise it blocks.
        local gs_re='\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@*#?$!-]' gs_m gs_guard gs_comp gs_eo=0
        for ((k2 = k + 1; k2 < e; k2++)); do
          gs_w="${CW[$k2]}"
          # The whole object name is a variable read from input: git prints
          # whatever <ref>:<path> the input holds.
          if [[ "$gs_w" =~ $GS_WHOLE_VAR_RE ]] && gs_read_bound "${BASH_REMATCH[1]}"; then
            block "git $g_sub of an object name read from input"
          fi
          case "${CF[$k2]}" in *v*) expand_vars "$gs_w"; gs_w="$EV" ;; esac
          gs_guard=0
          while [[ "$gs_w" =~ $gs_re ]] && [ $gs_guard -lt 64 ]; do
            gs_m="${BASH_REMATCH[0]}"; gs_w="${gs_w/"$gs_m"/$'\001'}"; gs_guard=$((gs_guard + 1))
          done
          gs_comp=0
          case "$gs_w" in *$'\001'*) gs_comp=1 ;; esac
          case "${CF[$k2]}" in
            *b*) ;;
            *u*)
              if gs_split_free "${CW[$k2]}" "${CF[$k2]}"; then
                case "$gs_w" in
                  *:*$'\001'*) [ "${CW[$k]}" = show ] && git_show_tree_safe "$gs_w" "$CUR_CWD" "$gs_redirect" "${CW[$k2]}" && continue ;;
                esac
              fi
              ;;
            *)
              case "$gs_w" in
                *:*$'\001'*|*:*'*'*|*:*'?'*|*:*'['*) [ "${CW[$k]}" = show ] && git_show_tree_safe "$gs_w" "$CUR_CWD" "$gs_redirect" "${CW[$k2]}" && continue ;;
              esac
              ;;
          esac
          # An unquoted glob object word before -- that the tree proof did not
          # pass (HEAD:?npmrc, HEAD?.npmrc, H*) can match a cwd file named
          # HEAD:.npmrc, and the shell then hands git that object name. Option
          # words (--format=%h:%s*) and paths after -- of git show are not
          # objects; for cat-file -- only ends the options, and the object
          # name still follows.
          if [ "${CW[$k2]}" = -- ] && [ "$g_sub" = show ]; then gs_eo=1; fi
          case "${CF[$k2]}" in
            *g*)
              case "$gs_eo:$gs_w" in
                1:*|0:-*) ;;
                *) block "git object revision or path the credential guard cannot prove against the tree git reads" ;;
              esac
              ;;
          esac
          if [ "$gs_comp" = 1 ]; then
            block "git object revision or path the credential guard cannot prove against the tree git reads"
          fi
          check_operand "${CW[$k2]}" "${CF[$k2]}" "$CUR_CWD"
        done
        return 0
      fi
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
    alias)
      # Each alias body runs as a command wherever its name is used later,
      # so it gets the same analysis as eval text (alias cygpath='cat ~/.np*').
      for ((k = a; k < e; k++)); do
        w="${CW[$k]}"
        case "$w" in
          *=*)
            CG_ALIAS_N+=("${w%%=*}"); CG_ALIAS_B+=("${w#*=}")
            [ -n "${w#*=}" ] && analyze_cmd "${w#*=}" $((depth + 1)) "$CUR_CWD"
            ;;
        esac
      done
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
      local xph=""
      while [ $k -lt $e ]; do
        w="${CW[$k]}"
        case "$w" in
          -a|--arg-file) [ $((k + 1)) -lt $e ] && check_word "${CW[$((k + 1))]}" "${CF[$((k + 1))]}" "$CUR_CWD"; k=$((k + 2)); continue ;;
          --arg-file=*) check_word "${w#*=}" "${CF[$k]}" "$CUR_CWD"; k=$((k + 1)); continue ;;
          -I|-J) [ $((k + 1)) -lt $e ] && xph="${CW[$((k + 1))]}"; k=$((k + 2)); continue ;;
          -I?*|-J?*) xph="${w:2}"; k=$((k + 1)); continue ;;
          -i|--replace) xph="{}"; k=$((k + 1)); continue ;;
          -i?*) xph="${w:2}"; k=$((k + 1)); continue ;;
          --replace=*) xph="${w#*=}"; k=$((k + 1)); continue ;;
          -L|-n|-P|-s|-d|-E) k=$((k + 2)); continue ;;
          -*) k=$((k + 1)); continue ;;
        esac
        break
      done
      # With -I the input fills the placeholder; without it, input lines are
      # appended as operands.
      if [ -n "$xph" ]; then fed_git_read "$k" "$e" "$xph" 0 xargs; else fed_git_read "$k" "$e" "" 1 xargs; fi
      if [ $k -lt $e ] && [ "$CRED_ANY" -eq 1 ] && { lc_word "${CW[$k]##*/}"; ! { cg_trusted_word "${CW[$k]}" && is_safe_cmd "$LCW"; }; }; then
        block "xargs feeding a command in a command line that names a credential file"
      fi
      fed_cmd "$k" "$e" "$depth"
      return 0
      ;;
    parallel)
      # GNU parallel fills {} (and its variants) or appends each input.
      fed_git_read "$a" "$e" "" 1 parallel
      # The command runs from the first word after the options up to :::.
      local pk=$a pe
      while [ $pk -lt $e ]; do
        case "${CW[$pk]}" in
          -j|-P|-S|-N|-n|-L|-l|-d|-C|-a|-I|-E|-X|--jobs|--sshlogin|--colsep|--delimiter|--arg-file|--joblog|--results|--res|--tmpdir|--timeout|--delay|--retries|--memfree|--load|--nice|--halt|--tagstring|--tag-string|--workdir|--wd|--basefile|--env|--header|--rpl|--max-args|--max-lines|--max-replace-args|--sshloginfile|--slf|--transferfile|--tf|--return|--trc|--eta-file|--cat-file|--block|--recstart|--recend|--termseq|--seqreplace|--plus-replace)
            pk=$((pk + 2)); continue ;;
          -*) pk=$((pk + 1)); continue ;;
        esac
        break
      done
      for ((pe = pk; pe < e; pe++)); do
        case "${CW[$pe]}" in :::|::::|:::+|::::+) break ;; esac
      done
      fed_cmd "$pk" "$pe" "$depth"
      ;;
    find)
      # The starting paths (after -H, -L, -P, -D <x>, -O<n>); . when none.
      local f_start=()
      k=$a
      while [ $k -lt $e ]; do
        case "${CW[$k]}" in -H|-L|-P|-O*) k=$((k + 1)) ;; -D) k=$((k + 2)) ;; *) break ;; esac
      done
      while [ $k -lt $e ]; do
        case "${CW[$k]}" in -*|'('|')'|'!'|,) break ;; esac
        f_start+=("${CW[$k]}"); k=$((k + 1))
      done
      [ ${#f_start[@]} -gt 0 ] || f_start=(.)
      for ((k = a; k < e; k++)); do
        case "${CW[$k]}" in
          -exec|-execdir|-ok|-okdir)
            fed_git_read $((k + 1)) "$e" "{}" 0 "find -exec" "${f_start[@]}"
            if [ $((k + 1)) -lt $e ] && [ "$CRED_ANY" -eq 1 ] && { lc_word "${CW[$((k + 1))]##*/}"; ! { cg_trusted_word "${CW[$((k + 1))]}" && is_safe_cmd "$LCW"; }; }; then
              block "find -exec in a command line that names a credential file"
            fi
            local fe
            for ((fe = k + 1; fe < e; fe++)); do
              case "${CW[$fe]}" in ';'|'+') break ;; esac
            done
            fed_cmd $((k + 1)) "$fe" "$depth"
            ;;
        esac
      done
      return 0
      ;;
  esac
  # An archiver copies every file under a directory operand, so a directory
  # that holds credentials (HOME, ~/.config, ~/.hq, ...) may not be one.
  case "$cmd" in
    tar|gtar|bsdtar|zip|7z|7za|7zz|cpio|pax|ditto|jar|rar|zstd|xz|gzip|bzip2)
      for ((k = a; k < e; k++)); do
        case "${CW[$k]}" in -*) continue ;; esac
        resolve_dir "${CW[$k]}" "${CF[$k]}" "$CUR_CWD"
        local rd_x
        for rd_x in ${RD_CHECK[@]+"${RD_CHECK[@]}"}; do
          if is_cred_dir "$rd_x"; then
            block "archiving a directory that holds credentials ($(show_path "$rd_x"))"
          fi
        done
        if [ -n "$NP" ] && is_cred_dir "$NP"; then
          block "archiving a directory that holds credentials ($(show_path "$NP"))"
        fi
      done
      ;;
  esac
  cg_trusted_word "$cw0" && is_safe_cmd "$cmd" && return 0
  # cygpath gets the same trust rules as is_safe_cmd: an alias, eval or
  # source, a PATH change, or a cygpath named by a path outside the system
  # directories can run something else under that name.
  if [ "$cmd" = cygpath ] && cygpath_converts_only "$a" "$e"; then
    if [ "${CG_CMD_OVERRIDE:-0}" = 0 ] && [ "${CG_PATH_CHANGED:-0}" = 0 ] && cg_trusted_word "$cw0"; then
      return 0
    fi
  fi
  # After a PATH change (only), a system cygpath may still be the one that
  # runs, as in the setup skill's `export PATH="$(cygpath -u -- "$X")/..."`.
  # Each operand must not name a credential; an operand that is only an
  # unknown value with no credential word passes. After an alias, eval or
  # source, or for ./cygpath, the name is not trusted at all and the usual
  # unknown-command checks below run.
  if [ "$cmd" = cygpath ] && [ "${CG_CMD_OVERRIDE:-0}" = 0 ] && [ "${CG_PATH_CHANGED:-0}" = 1 ] \
    && cg_trusted_word "$cw0" && cygpath_converts_only "$a" "$e"; then
    for ((k = a; k < e; k++)); do
      w="${CW[$k]}"
      case "$w" in --|-*) continue ;; esac
      case "${CF[$k]}" in
        *c*) ;;
        *v*|*s*)
          expand_vars "$w"
          case "$EV" in *$'\001'*) [[ "$EV" =~ $CRED_WORD_RE ]] || continue ;; esac
          ;;
      esac
      check_word "$w" "${CF[$k]}" "$CUR_CWD"
    done
    return 0
  fi
  if is_interpreter "$cmd"; then
    joined=""; sep=""
    for ((k = a; k < e; k++)); do joined="$joined$sep${CW[$k]}"; sep=" "; done
    code_check "$joined" "$cmd"
    # A credential path handed over in the environment (F=/srv/app/.env
    # python3 -c "open(os.environ['F'])", env F=..., export F=... earlier in
    # the command) is opened by code that never names it (feedback 166f01a7).
    env_check "$env_text" "$cmd"
    subst_code_check "$joined" "$cmd"
    [ -n "$in_kind" ] && code_check "$in_text" "$cmd"
    check_generic "$a" "$e" "$CUR_CWD"
    return 0
  fi
  # gh, hq and git message text (`--body "$(cat <<'EOF' ...)"`, `--title`,
  # `-m`, `hq dm send <to> "$(cat note.md)"`), a gh repository (`-R "$R"`)
  # and the pull request word of `gh pr checks|view|... "$(...)"` take the
  # text itself, never a path. A value that is exactly one substitution is
  # data; the substitution's own script was analyzed above as a command, so
  # `$(cat ~/.npmrc)` is still blocked there (feedback 237d598f, e6ef0b06,
  # a71b3d1c, 882a7f9c, d5df3977).
  # Only these commands, where those options are known to be text: hq dm and
  # hq feedback, gh pr|issue|release (and -R on any gh command), git
  # commit|tag. Other hq commands keep the operand check (test "non-dm hq
  # command keeps operand check").
  local td_cmd=0 td_text=0
  case "$cmd:${CW[$a]:-}" in
    hq:dm|hq:feedback) td_cmd=1; td_text=1 ;;
    gh:pr|gh:issue|gh:release) td_cmd=1; td_text=1 ;;
    gh:*) td_cmd=1 ;;
    git:commit|git:tag) td_cmd=1; td_text=1 ;;
  esac
  case "$td_cmd:$cmd" in
    1:gh|1:hq|1:git)
      local td_next=0 tw tk pos=0 sub1="${CW[$a]:-}" sub2="${CW[$((a + 1))]:-}"
      for ((tk = a; tk < e; tk++)); do
        tw="${CW[$tk]}"
        # gh never opens the value of -R/--repo as a file: it is OWNER/REPO
        # or a URL, so any value passes (`R=$(gh repo view ...); gh pr list
        # -R "$R"`).
        if [ $td_next -eq 2 ]; then td_next=0; continue; fi
        if [ $td_next -eq 1 ]; then
          td_next=0
          case "${CF[$tk]}" in *s*) [ "$tw" = $'\001' ] && continue ;; esac
        fi
        case "$tw" in
          -R|--repo)
            [ "$cmd" = gh ] && td_next=2; check_generic "$tk" $((tk + 1)) "$CUR_CWD"; continue ;;
          --repo=*) [ "$cmd" = gh ] && continue ;;
          --body|--title|--message|--text|--prompt|--note|--summary|--details|--description|--subject|--comment|--reason)
            [ "$td_text" -eq 1 ] && td_next=1; check_generic "$tk" $((tk + 1)) "$CUR_CWD"; continue ;;
          -m|-b|-t)
            if [ "$td_text" -eq 1 ]; then
              case "$cmd" in git) [ "$tw" = -m ] && td_next=1 ;; gh) [ "$tw" != -m ] && td_next=1 ;; esac
            fi
            check_generic "$tk" $((tk + 1)) "$CUR_CWD"; continue ;;
          --body=$'\001'|--title=$'\001'|--message=$'\001'|--text=$'\001'|--prompt=$'\001'|--note=$'\001') [ "$td_text" -eq 1 ] && continue ;;
          # gh options whose value is a name, a filter or a query, never a
          # file gh opens (`gh run list --workflow "$(gh run view ...)"`).
          --workflow|--branch|--jq|-q|--json|--template|--limit|-L|--state|--search|--label|--assignee|--author|--base|--head|--milestone|--event|--status|--user|--commit|--job|--attempt|--ref|--name|--created)
            [ "$cmd" = gh ] && td_next=1; check_generic "$tk" $((tk + 1)) "$CUR_CWD"; continue ;;
        esac
        case "$tw" in -*) ;; *) pos=$((pos + 1)) ;; esac
        if [ "$tw" = $'\001' ]; then
          case "${CF[$tk]}" in *s*)
            # hq dm send <recipient> <message>: the second word after send.
            if [ "$cmd" = hq ] && [ "$sub1" = dm ] && [ "$sub2" = send ] && [ "$pos" -eq 4 ]; then continue; fi
            # gh pr <verb> <pr>: the word right after the verb.
            if [ "$cmd" = gh ] && [ "$sub1" = pr ] && [ "$tk" -eq $((a + 2)) ]; then
              case "$sub2" in checks|view|status|merge|diff|ready|close|reopen|checkout) continue ;; esac
            fi
            # gh run <verb> <run-id>: the word right after the verb.
            if [ "$cmd" = gh ] && [ "$sub1" = run ] && [ "$tk" -eq $((a + 2)) ]; then
              case "$sub2" in watch|view|rerun|cancel|delete) continue ;; esac
            fi
            ;;
          esac
        fi
        check_generic "$tk" $((tk + 1)) "$CUR_CWD"
      done
      return 0
      ;;
  esac
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
      # ENVIRON["F"] hands a path from the environment to getline or ARGV
      # (feedback 166f01a7).
      if [[ "$joined" =~ ENVIRON ]]; then
        env_check "$env_text" "$cmd"
      fi
      ;;
  esac
  if is_reader "$cmd"; then
    check_reader "$cmd" "$a" "$e" "$CUR_CWD"
  else
    check_generic "$a" "$e" "$CUR_CWD" "$cmd"
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
  # Budget the work before the per-command loop too (review of #1860): on
  # macOS /bin/bash (3.2) reading 24,000 tokens into arrays and the binding
  # and substitution passes below took about 20 s before the first check in
  # that loop ran. Each pass now checks the clock per item, so the block comes
  # at the budget whichever pass is running.
  cg_budget_check
  local toks
  toks=$(printf '%s' "$text" | LC_ALL=C awk "$AWK_PROG") \
    || block "credential guard could not parse the command"
  cg_budget_check
  local T=() F=() O=() X=() HB=()
  # Substitutions that put a \001 into a word, in token order (SUBQK: w or p).
  local SUBQ=() SUBQK=() SUBQ_I=0
  # Every substitution text in this command line (subst_code_check).
  local SUBQ_ALL=()
  local CWD_UNCERTAIN="$CWD_UNCERTAIN"
  local t fl op tx hb_next=0 pipe_text=""
  while IFS=$'\t' read -r t fl op tx; do
    [ -n "$t" ] || continue
    [ "$SECONDS" -lt "$CG_BUDGET" ] || cg_budget_check
    T+=("$t"); F+=("${fl#f}"); O+=("${op#o}"); X+=("${tx#x}")
  done <<< "$toks"
  local i n=${#T[@]}
  # Loop bindings of this level. Inherit the caller's trusted bindings that
  # precede the substitution (SPLIT_INHERIT_G) and every taint, then record
  # this level's own bindings first, so a git show inside a substitution of
  # the loop body sees them too.
  local sv_i sv_n=() sv_ok=() sv_g=() sv_st=()
  for ((sv_i = 0; sv_i < ${#SPLIT_VAR_NAMES[@]}; sv_i++)); do
    if [ "${SPLIT_VAR_OK[$sv_i]}" != 1 ] || [ "${SPLIT_VAR_G[$sv_i]}" -lt "$SPLIT_INHERIT_G" ]; then
      sv_n+=("${SPLIT_VAR_NAMES[$sv_i]}"); sv_ok+=("${SPLIT_VAR_OK[$sv_i]}"); sv_g+=(-1)
      sv_st+=("${SPLIT_VAR_STAGE[$sv_i]:-0}")
    fi
  done
  local SPLIT_VAR_NAMES=(${sv_n[@]+"${sv_n[@]}"}) SPLIT_VAR_OK=(${sv_ok[@]+"${sv_ok[@]}"}) SPLIT_VAR_G=(${sv_g[@]+"${sv_g[@]}"})
  local SPLIT_VAR_STAGE=(${sv_st[@]+"${sv_st[@]}"})
  local SPLIT_CUR_G=-1
  SPLIT_INHERIT_G=0
  local nb_s=0 nb_g=0
  for ((i = 0; i <= n; i++)); do
    [ "$SECONDS" -lt "$CG_BUDGET" ] || cg_budget_check
    if [ $i -eq $n ] || [ "${T[$i]}" = "O" ]; then
      note_for_bindings "$nb_s" "$i" "$nb_g"
      zword_check "$nb_s" "$i"
      nb_s=$((i + 1)); nb_g=$((nb_g + 1))
    fi
  done
  nb_g=0
  for ((i = 0; i < n; i++)); do
    [ "$SECONDS" -lt "$CG_BUDGET" ] || cg_budget_check
    [ "${T[$i]}" != "O" ] || nb_g=$((nb_g + 1))
    case "${T[$i]}" in
      E)
        block "credential guard could not parse the command (${X[$i]})"
        ;;
      S)
        cg_nl3 "${X[$i]}"
        local sub_text="$CG_NL"
        SUBQ_ALL+=("$sub_text")
        SPLIT_INHERIT_G=$nb_g
        analyze_cmd "$sub_text" $((depth + 1)) "$CUR_CWD"
        SPLIT_INHERIT_G=0
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
    [ "$SECONDS" -lt "$CG_BUDGET" ] || cg_budget_check
    if [ $i -eq $n ] || [ "${T[$i]}" = "O" ]; then
      starts+=("$cs"); ends+=("$i")
      if [ $i -lt $n ]; then seps+=("${O[$i]}"); else seps+=(""); fi
      cs=$((i + 1))
    fi
  done
  local c nc=${#starts[@]}
  # The first simple command of the top-level line, when it is followed by
  # `;`, `&&`, `||`, a newline or nothing (not `|` or `&`, whose other side
  # runs at the same time) and has no write redirection: its substitutions
  # run before any other command. Only substitutions directly in that
  # command count; a loop header (`for x in $(...)`) is not modelled.
  # The command may hold only one substitution: bash runs several in one
  # command left to right, so an earlier one (`B=$(ln -s ~/.npmrc d/zz)
  # C=$(ls d | tail -1)`) could change what a later one lists (review of
  # this change, CRITICAL 1).
  for ((c = 0; c < nc; c++)); do
    cg_budget_check
    CW=(); CF=()
    local rt=() rf=() rx=()
    for ((i = ${starts[$c]}; i < ${ends[$c]}; i++)); do
      case "${T[$i]}" in
        W)
          cg_nl3 "${X[$i]}"; tx="$CG_NL"
          case "${F[$i]}" in
            *c*|*b*) subq_skip "$tx" ;;
            *s*)
              # A whole-word process substitution <(...) is a pipe (/dev/fd/N),
              # not a path; its inner script is analyzed as its own command.
              if [ "$tx" = $'\001' ] && [ "${SUBQK[$SUBQ_I]:-}" = "p" ]; then
                SUBQ_I=$((SUBQ_I + 1))
                CW+=("/dev/fd/63"); CF+=("-")
                continue
              fi
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
      SPLIT_CUR_G=$c
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
# A bash expansion error (for example an arithmetic error) abandons the whole
# top-level command it happens in and the script carries on. The flag is set
# in the same command as the analysis, so an abandoned analysis is seen here
# and blocks instead of falling through to exit 0 (issue #1749).
CG_ANALYZED=0
case "$CMD" in *'$('*|*'`'*) prescan "$CMD" 0; PRESCAN_DONE=1 ;; *) PRESCAN_DONE=2 ;; esac
[ "$PRESCAN_DONE" != 0 ] || block "the credential guard could not finish analysing this command"
analyze_cmd "$CMD" 0 "$PAYLOAD_CWD"; CG_ANALYZED=1
[ "$CG_ANALYZED" = 1 ] || block "the credential guard could not finish analysing this command"
exit 0
