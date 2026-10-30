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
PREFILTER_RE="${CRED_WORD_RE}|identity|config\\.json|hosts\\.y|(^|[^a-z])(cd|pushd)([^a-z]|$)|[*?[{]|~|home|(^|[^a-z])(rg|ag|ack|rsync|scp)([^a-z]|$)|(^|[[:space:]])-[A-Za-z]*r|--recursive|--archive|(xargs|parallel|-exec|-ok).*git.*(show|cat-file|archive)"
CG_SCREEN_RE="${CRED_WORD_RE}|identity|config\\.json|hosts\\.y"

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
  local t a
  cg_strip_q "$CG_SM"
  t="$CG_SQ"
  for a in "${CG_SPLIT_ALLOWED[@]}"; do t="${t//$a/}"; done
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
# Linear: field splitting on $, bounded scans, one join at the end.
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
  local old_ifs="$IFS" parts p i j n out acc name ok b sent=$'\001' be saved dmark off
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
  # Pieces are collected in an array and joined once: appending to one
  # string is quadratic on a large heredoc with thousands of $ signs.
  out=("${parts[0]}")
  i=1
  while [ $i -lt $n ]; do
    p="${parts[$i]}"
    i=$((i + 1))
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
        # the piece is kept literal, so later pieces are still scanned (i is
        # unchanged; j is a lookahead).
        acc="$p"
        j=$i
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
          [ $j -lt $n ] || break
          [ ${#acc} -le 512 ] || break
          off=${#acc}
          acc="$acc\$${parts[$j]}"
          j=$((j + 1))
        done
        if [ "$ok" = 1 ]; then
          i=$j
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
            if [ "$CG_HASDEF" = 1 ] && [ "$CG_SPLIT_DEPTH" -lt 24 ]; then
              saved="$CG_SM"
              CG_SPLIT_DEPTH=$((CG_SPLIT_DEPTH + 1))
              if cg_split_mark "$CG_DEF"; then dmark="$CG_SM"; else dmark="$sent"; fi
              CG_SPLIT_DEPTH=$((CG_SPLIT_DEPTH - 1))
              CG_SM="$saved"
            fi
          fi
          out+=("$dmark${acc:$((be + 1))}")
        else
          out+=("$sent$p")
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
          out+=("$CG_AD$acc")
        else
          out+=("$sent$acc")
        fi
        ;;
      '"'*) out+=("$p") ;;
      [A-Za-z_]*)
        name="${p%%[!A-Za-z0-9_]*}"
        out+=("$sent${p#"$name"}")
        ;;
      '') out+=("$sent") ;;
      [0-9@*#?!-]*) out+=("$sent${p:1}") ;;
      # $(...): the body is a command, not part of the word, so a space
      # keeps it apart. COMPUTED_PATH sends the word itself to the full
      # check.
      '('*) out+=("$sent ${p:1}") ;;
      *) out+=("\$$p") ;;
    esac
  done
  IFS=""
  CG_SM="${out[*]}"
  IFS="$old_ifs"
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
  local c f g="${1//\?/*}" prev=""
  # Collapse runs of wildcards to one, so a single filler can stand for the
  # whole unknown run (a split can emit adjacent wildcards). The pattern and
  # replacement are unquoted: bash 3.2 keeps quotes in ${v//'x'/'y'} literal.
  while [ "$g" != "$prev" ]; do prev="$g"; g="${g//\*\*/\*}"; done
  for f in "" . e n v env rc local production development; do
    c="${g//\*/$f}"
    is_env_name "$c" && return 0
  done
  return 1
}

# cg_split_dir_is <segment> <dir>...: the segment, written out or split
# around a variable, can be one of the directories. A segment that is only a
# variable is not counted.
cg_split_dir_is() {
  local seg="$1" d
  shift
  case "$seg" in *[!$'\001']*) ;; *) return 1 ;; esac
  for d in "$@"; do
    # shellcheck disable=SC2053 # pattern match is intended.
    [[ "$d" == ${seg//$'\001'/*} ]] && return 0
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
cg_split_scan() {
  local old_ifs="$IFS" w seg prev prev2 pat p n d lit g words=() segs=() pats=() dirs=()
  IFS=$' \t;|&()<>\n'
  set -f
  # shellcheck disable=SC2206
  words=($1)
  set +f
  IFS="$old_ifs"
  for w in ${words[@]+"${words[@]}"}; do
    case "$w" in *$'\001'*) ;; *) continue ;; esac
    # Brace expansion picks one of its parts: .n{p,}"$F"mrc.
    g=0
    while [[ "$w" == *'{'*'}'* ]] && [[ "$w" =~ $CG_SPLIT_BRACE_RE ]]; do
      [ $g -lt 32 ] || return 0
      w="${w/"${BASH_REMATCH[0]}"/$'\001'}"
      g=$((g + 1))
    done
    IFS='/=:,@'
    set -f
    # shellcheck disable=SC2206
    segs=($w)
    set +f
    IFS="$old_ifs"
    # prev, prev2: the parent and grandparent segments. Empty and .
    # segments are skipped and .. goes back one (~/.config/gh/./x, gh//x,
    # gh/a/../x).
    dirs=()
    prev=""
    prev2=""
    for seg in ${segs[@]+"${segs[@]}"}; do
      case "$seg" in
        ''|.) continue ;;
        ..) [ ${#dirs[@]} -gt 0 ] && unset "dirs[$((${#dirs[@]} - 1))]" ;;
        *)
          case "$seg" in
            *$'\001'*)
              pat="${seg//$'\001'/*}"
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
          dirs+=("$seg")
          ;;
      esac
      prev=""
      prev2=""
      [ ${#dirs[@]} -gt 0 ] && prev="${dirs[$((${#dirs[@]} - 1))]}"
      [ ${#dirs[@]} -gt 1 ] && prev2="${dirs[$((${#dirs[@]} - 2))]}"
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
    lit="${p//[*?]/}"
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

# cg_fast_allow: return 0 when the call can be allowed without the full
# check.
cg_fast_allow() {
  [ "${HQ_CRED_GUARD_FASTPATH:-1}" != "0" ] || return 1
  # Every helper must be defined; a missing one would otherwise read as "no
  # match" and allow the call.
  declare -F cg_strip_q cg_unescape cg_parse cg_fast_scan cg_split_cred cg_split_check cg_split_mark cg_ansi_decode cg_split_default cg_split_scan cg_split_env cg_split_dir_is cg_split_cred_dir cg_split_seg norm_path is_cred_path is_cred_dir is_cred_name_at is_env_name strip_backup >/dev/null 2>&1 || return 1
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
      [ "$CG_ARITH_READY" = 1 ] || return 1
      hq_arith_guard_check "$CG_CMD" || return 1
      # Same computed-path rule as the full check (COMPUTED_PATH): a $(...)
      # or backtick body can build a credential name from neutral text
      # (`cat "workspace/$(echo c)redlink"`), so it always gets the full
      # analysis. Without this the fast path allowed what the full check
      # blocks (scope-guard-hotfix-security.test.sh, 14 cases).
      case "$CG_CMD" in *'$('*|*'`'*) return 1 ;; esac
      # A git show <ref>:<path> with a variable reads a tree object the name
      # prefilter cannot see; the full check proves it (GS_COMPUTED).
      case "$CG_CMD" in *show*:*'$'*) return 1 ;; esac
      cg_strip_q "$CG_CMD" || return 1
      local st="$CG_SQ"
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
[ "$CG_ARITH_READY" = 1 ] || block "The arithmetic guard helper is missing; refresh the hook installation."
if ! hq_arith_guard_check "$CMD"; then
  hq_arith_guard_message
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "BLOCKED: Bash arithmetic check. $HQ_ARITH_GUARD_REASON." '{decision:"block",reason:$m}' || true
  fi
  exit 2
fi
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
# git show <ref>:<path> with a variable names a tree entry, not a file the
# name prefilter can match: `ls src | while read f; do git show "HEAD:src/$f"`
# carries no credential word. Treat it as computed so the full check runs and
# unknown variables are wildcards there.
case "$CMD" in *show*:*'$'*) COMPUTED_PATH=1 ;; esac
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
if [ "$COMPUTED_PATH" -eq 0 ] && [ "$SPLIT_CRED" -eq 0 ] && [ "$CWD_IN_CRED" -eq 0 ] && [ "$LINK_HIT" -eq 0 ] && ! [[ "$STRIPPED" =~ $PREFILTER_RE ]]; then
  shopt -u nocasematch
  exit 0
fi
# CRED_ANY: a credential word remains after removing allowed names, or a
# word could expand to one (SPLIT_CRED). Unknown
# variables and substitutions are treated as wildcards only when it is set.
ALLOW_STRIPPED="$STRIPPED"
for allowed in .env.example .env.sample .env.template .env.schema .env.dist .pub; do
  ALLOW_STRIPPED="${ALLOW_STRIPPED//$allowed/}"
done
CRED_ANY=0
if [[ "$ALLOW_STRIPPED" =~ $CRED_WORD_RE ]] || [ "$CWD_IN_CRED" -eq 1 ] || [ "$LINK_HIT" -eq 1 ] || [ "$COMPUTED_PATH" -eq 1 ] || [ "$SPLIT_CRED" -eq 1 ]; then
  CRED_ANY=1
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
  w = ""; ws = 0; fs_ = ""; rop = ""; nhd = 0; failed = 0; inq = 0
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
  local text="$1" depth="$2" toks t fl op tx first=1 name="" sub="" last_s="" asg=0
  [ "$depth" -le 6 ] || { SUBST_IMPURE=1; return; }
  toks=$(printf '%s' "$text" | LC_ALL=C awk "$AWK_PROG") || { SUBST_IMPURE=1; return; }
  while IFS=$'\t' read -r t fl op tx; do
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
git_show_tree_safe() {
  local op="$1" gcwd="$2" redirect="${3:-1}" ref path dir pat tf top listing
  [ "$redirect" = 0 ] || return 1
  [ -z "${GIT_DIR:-}" ] && [ -z "${GIT_WORK_TREE:-}" ] && [ -z "${GIT_NAMESPACE:-}" ] || return 1
  case "$op" in *:*) ;; *) return 1 ;; esac
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
  listing="$(git -C "$gcwd" ls-tree -r --full-tree --name-only "$ref" -- ${dir:+"$dir/"} 2>/dev/null)" || return 1
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
SPLIT_TRUST=1
SPLIT_INHERIT_G=0
split_var_mark() { # <name> <ok 0|1> <group>
  local i
  for ((i = 0; i < ${#SPLIT_VAR_NAMES[@]}; i++)); do
    if [ "${SPLIT_VAR_NAMES[$i]}" = "$1" ]; then
      [ "$2" = 1 ] || SPLIT_VAR_OK[$i]=0
      return
    fi
  done
  SPLIT_VAR_NAMES+=("$1")
  SPLIT_VAR_OK+=("$2")
  SPLIT_VAR_G+=("$3")
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
  local ok=1
  for ((i = a + 3; i < b; i++)); do
    case "${T[$i]}" in S) continue ;; W) ;; *) ok=0; break ;; esac
    case "${F[$i]}" in *q*|*g*|*b*) ok=0; break ;; esac
    case "${X[$i]}" in "~"*|*'{'*|*'}'*|*'['*|*'*'*|*'?'*) ok=0; break ;; esac
  done
  split_var_mark "$name" "$ok" "$g"
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

# fed_git_read <start> <end> <placeholder> <appends> <tool>: the command
# that xargs, find -exec or parallel runs is a git object reader (git show,
# cat-file, archive) whose <ref>:<path> operand the tool fills in, either
# through the placeholder or by appending input lines. The path is computed,
# so it is refused whatever it resolves to.
fed_git_read() {
  local s="$1" e="$2" ph="$3" app="$4" tool="$5" j t="" sep=""
  for ((j = s; j < e; j++)); do t="$t$sep${CW[$j]}"; sep=" "; done
  [[ "$t" =~ (^|[[:space:]/\'\"])git([[:space:]]|$) ]] || return 0
  [[ "$t" =~ (^|[[:space:]])(show|cat-file|archive)([[:space:]]|$) ]] || return 0
  if [ "$app" -eq 1 ] || { [ -n "$ph" ] && [[ "$t" == *"$ph"* ]]; }; then
    block "$tool filling in the path of a git show, cat-file or archive (a computed path)"
  fi
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
      local k2 gs_w
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
      if [ "${CW[$k]}" = show ]; then
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
        local gs_re='\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@*#?$!-]' gs_m gs_guard gs_comp
        for ((k2 = k + 1; k2 < e; k2++)); do
          gs_w="${CW[$k2]}"
          case "${CF[$k2]}" in *v*) expand_vars "$gs_w"; gs_w="$EV" ;; esac
          gs_guard=0
          while [[ "$gs_w" =~ $gs_re ]] && [ $gs_guard -lt 64 ]; do
            gs_m="${BASH_REMATCH[0]}"; gs_w="${gs_w/"$gs_m"/$'\001'}"; gs_guard=$((gs_guard + 1))
          done
          gs_comp=0
          case "$gs_w" in *:*$'\001'*) gs_comp=1 ;; esac
          case "${CF[$k2]}" in
            *b*) ;;
            *u*)
              if gs_split_free "${CW[$k2]}" "${CF[$k2]}"; then
                case "$gs_w" in
                  *:*$'\001'*) git_show_tree_safe "$gs_w" "$CUR_CWD" "$gs_redirect" && continue ;;
                esac
              fi
              ;;
            *)
              case "$gs_w" in
                *:*$'\001'*|*:*'*'*|*:*'?'*) git_show_tree_safe "$gs_w" "$CUR_CWD" "$gs_redirect" && continue ;;
              esac
              ;;
          esac
          if [ "$gs_comp" = 1 ]; then
            block "git show of a computed <ref>:<path> the credential guard cannot prove against the tree git reads"
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
      if [ $k -lt $e ] && [ "$CRED_ANY" -eq 1 ] && { lc_word "${CW[$k]##*/}"; ! is_safe_cmd "$LCW"; }; then
        block "xargs feeding a command in a command line that names a credential file"
      fi
      return 0
      ;;
    parallel)
      # GNU parallel fills {} (and its variants) or appends each input.
      fed_git_read "$a" "$e" "" 1 parallel
      ;;
    find)
      for ((k = a; k < e; k++)); do
        case "${CW[$k]}" in
          -exec|-execdir|-ok|-okdir)
            fed_git_read $((k + 1)) "$e" "{}" 0 "find -exec"
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
  # Loop bindings of this level. Inherit the caller's trusted bindings that
  # precede the substitution (SPLIT_INHERIT_G) and every taint, then record
  # this level's own bindings first, so a git show inside a substitution of
  # the loop body sees them too.
  local sv_i sv_n=() sv_ok=() sv_g=()
  for ((sv_i = 0; sv_i < ${#SPLIT_VAR_NAMES[@]}; sv_i++)); do
    if [ "${SPLIT_VAR_OK[$sv_i]}" != 1 ] || [ "${SPLIT_VAR_G[$sv_i]}" -lt "$SPLIT_INHERIT_G" ]; then
      sv_n+=("${SPLIT_VAR_NAMES[$sv_i]}"); sv_ok+=("${SPLIT_VAR_OK[$sv_i]}"); sv_g+=(-1)
    fi
  done
  local SPLIT_VAR_NAMES=(${sv_n[@]+"${sv_n[@]}"}) SPLIT_VAR_OK=(${sv_ok[@]+"${sv_ok[@]}"}) SPLIT_VAR_G=(${sv_g[@]+"${sv_g[@]}"})
  local SPLIT_CUR_G=-1
  SPLIT_INHERIT_G=0
  local nb_s=0 nb_g=0
  for ((i = 0; i <= n; i++)); do
    if [ $i -eq $n ] || [ "${T[$i]}" = "O" ]; then
      note_for_bindings "$nb_s" "$i" "$nb_g"
      nb_s=$((i + 1)); nb_g=$((nb_g + 1))
    fi
  done
  nb_g=0
  for ((i = 0; i < n; i++)); do
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
case "$CMD" in *'$('*|*'`'*) prescan "$CMD" 0; PRESCAN_DONE=1 ;; esac
analyze_cmd "$CMD" 0 "$PAYLOAD_CWD"
exit 0
