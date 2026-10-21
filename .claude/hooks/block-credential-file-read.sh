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
#   echo printf true false realpath readlink basename dirname tee ln ssh
#   ssh-add, the shell builtins pwd read mapfile readarray exit return unset
#   set shift trap wait sleep type which hash kill break continue :,
#   ssh-keygen without -i, mv onto a non-credential name, and git
#   status / add / rm / mv / commit / check-ignore / check-attr / ls-files
#   (add without -p / -i / -e).
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
# Known limits (see the PR body): hard links to a credential file (Read and
# Bash; pinned by credential-read-guard.test.sh [10]), paths computed at runtime without a credential word (for example
# string concatenation inside interpreter code, or a script file that opens
# the credential), a link or rename created and read in the same command,
# and the Grep tool. redact-credential-output.sh is the backstop for output.
#
# Exit 2 + short plain stderr. The message names the path, never contents.

set -o pipefail

INPUT=$(cat)

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

command -v jq >/dev/null 2>&1 || block "credential guard cannot parse the tool call (jq missing)"

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) \
  || block "credential guard cannot parse the tool call"

case "$TOOL" in
  Read|Bash) ;;
  *) exit 0 ;;
esac

PAYLOAD_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) \
  || block "credential guard cannot parse the tool call"
[ -n "$PAYLOAD_CWD" ] || PAYLOAD_CWD="$PWD"
H="${HOME:-}"
[ -n "$H" ] || H="/nonexistent-home"
# Squeeze repeated slashes (TMPDIR ends in "/" on macOS) so HOME compares
# equal to normalized operand paths.
while case "$H" in *//*) true ;; *) false ;; esac; do H="${H%%//*}/${H#*//}"; done
[ "$H" = "/" ] || H="${H%/}"

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
  FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) \
    || block "credential guard cannot parse the tool call"
  [ -n "$FP" ] || exit 0
  norm_path "$FP" "$PAYLOAD_CWD"
  check_abs "$NP"
  exit 0
fi

# ---------------------------------------------------------------- Bash tool

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) \
  || block "credential guard cannot parse the tool call"
[ -n "$CMD" ] || exit 0

CRED_WORD_RE='npmrc|netrc|pypirc|yarnrc|git-credentials|\.gem|\.docker|\.aws|\.ssh|id_(rsa|dsa|ecdsa|ed25519)|gh/hosts|\.env|credentials'
# Also wake for home references and recursive readers: `grep -r token ~`
# reaches credential files without naming one.
PREFILTER_RE="${CRED_WORD_RE}|identity|config\\.json|hosts\\.y|(^|[^a-z])(cd|pushd)([^a-z]|$)|[*?[{]|~|home|(^|[^a-z])(rg|ag|ack|rsync|scp)([^a-z]|$)|(^|[[:space:]])-[A-Za-z]*r|--recursive|--archive"

STRIPPED="${CMD//[\"\'\\]/}"
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
  while IFS= read -r lw; do
    lw="${lw#@}"
    case "$lw" in file://*|FILE://*) lw="${lw#*://}" ;; *://*) continue ;; esac
    case "$lw" in *=*) lw="${lw#*=}" ;; esac
    [ -n "$lw" ] || continue
    case "$lw" in /*) ;; *) lw="$PAYLOAD_CWD/$lw" ;; esac
    if [ -L "$lw" ] || { [[ "$lw" == "$PAYLOAD_CWD"/*/* ]] && [ -e "$lw" ]; }; then
      LINK_CANDS+=("$lw")
    fi
  done < <(printf '%s\n' "$STRIPPED" | tr -s ' \t;|&()<>' '\n\n\n\n\n\n\n\n')
  if [ ${#LINK_CANDS[@]} -gt 0 ]; then
    while IFS= read -r lr; do
      [ -n "$lr" ] || continue
      if is_cred_path "$lr" || is_secret_dir "$lr" || is_cred_dir "$lr"; then LINK_HIT=1; break; fi
    done < <("$REALPATH_BIN" -- "${LINK_CANDS[@]}" 2>/dev/null)
  fi
  shopt -s nocasematch
fi
if [ "$CWD_IN_CRED" -eq 0 ] && [ "$LINK_HIT" -eq 0 ] && ! [[ "$STRIPPED" =~ $PREFILTER_RE ]]; then
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
if [[ "$ALLOW_STRIPPED" =~ $CRED_WORD_RE ]] || [ "$CWD_IN_CRED" -eq 1 ] || [ "$LINK_HIT" -eq 1 ]; then
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
function emit_s(inner) {
  print "S\tf-\to-\tx" enc(inner)
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
  emit_s(inner)
  return k + 1
}
function sub_backtick(j,  k) {
  k = find_bt(j + 1)
  if (!k) { err("unterminated backtick"); return n + 1 }
  emit_s(substr(s, j + 1, k - j - 1))
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
      emit_s(substr(s, i + 2, k - i - 2))
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

# check_pattern <absolute pattern with * wildcards> <basename-from-cred-subst 0|1>
check_pattern() {
  local pat="$1" cand dir base t
  for t in "${CRED_TAILS[@]}"; do
    cand="$H/$t"
    # shellcheck disable=SC2053 # pattern match is intended.
    if [[ "$cand" == $pat ]]; then block "reading a credential file (pattern $(show_path "$pat"))"; fi
  done
  dir="${pat%/*}"
  base="${pat##*/}"
  case "$dir" in
    *'*'*|*'?'*|*'['*) ;;
    *)
      for t in "${CRED_BASENAMES[@]}"; do
        cand="$dir/$t"
        if [[ "$cand" == $pat ]] && is_cred_path "$cand"; then
          block "reading a credential file (pattern $(show_path "$pat"))"
        fi
      done
      if is_cred_dir "$dir" && [ "$dir" != "$H" ] && [ "$dir" != "/" ]; then
        case "$H/" in "$dir"/*) ;; *)
          case "$base" in *.pub) ;; *) block "reading a credential directory with a wildcard ($(show_path "$pat"))" ;; esac
        ;; esac
      fi
      ;;
  esac
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
        check_pattern "$NP" 0
        ;;
      *)
        norm_path "$cand" "$cwd"
        case "$flags" in
          *g*)
            check_pattern "$NP" 0
            local matches=() mm cnt=0
            local old_ifs="$IFS"
            shopt -s nullglob
            IFS=
            # shellcheck disable=SC2206 # glob expansion is the point.
            matches=($NP)
            IFS="$old_ifs"
            shopt -u nullglob
            for mm in ${matches[@]+"${matches[@]}"}; do
              cnt=$((cnt + 1))
              [ $cnt -le 500 ] || break
              check_abs "$mm"
            done
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
  cmd="$(printf '%s' "${cw0##*/}" | tr '[:upper:]' '[:lower:]')"
  case "$cmd" in
    cd|pushd)
      local target=""
      for ((k = a; k < e; k++)); do
        case "${CW[$k]}" in -?*) continue ;; esac
        target="${CW[$k]}"; resolve_dir "$target" "${CF[$k]}" "$CUR_CWD"
        [ -n "$NP" ] && CUR_CWD="$NP"
        break
      done
      [ -n "$target" ] || CUR_CWD="$H"
      return 0
      ;;
    bash|sh|zsh|dash|ksh)
      for ((k = a; k < e; k++)); do
        w="${CW[$k]}"
        case "$w" in
          -*c*)
            if [[ "$w" != --* ]] && [ $((k + 1)) -lt $e ]; then
              analyze_cmd "${CW[$((k + 1))]}" $((depth + 1)) "$CUR_CWD"
              return 0
            fi
            ;;
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
        status|rm|mv|check-ignore|check-attr|ls-files)
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
    mv|gmv)
      local mv_ops=() mv_fl=() endo=0
      for ((k = a; k < e; k++)); do
        w="${CW[$k]}"
        if [ $endo -eq 0 ] && [ "$w" = "--" ]; then endo=1; continue; fi
        if [ $endo -eq 0 ] && [[ "$w" == -?* ]]; then
          case "$w" in -t|--target-directory|--target-directory=*|-t?*) return 0 ;; esac
          continue
        fi
        mv_ops+=("$w"); mv_fl+=("${CF[$k]}")
      done
      k=${#mv_ops[@]}
      if [ $k -ge 2 ]; then
        k=$((k - 1))
        copy_onto_cred "${mv_ops[$k]}" "${mv_fl[$k]}" "$CUR_CWD" "${mv_ops[@]:0:$k}"
      fi
      return 0
      ;;
    source|.)
      [ $a -lt $e ] && check_word "${CW[$a]}" "${CF[$a]}" "$CUR_CWD"
      return 0
      ;;
    eval)
      local joined="" sep=""
      for ((k = a; k < e; k++)); do joined="$joined$sep${CW[$k]}"; sep=" "; done
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
      if [ $k -lt $e ] && ! is_safe_cmd "$(printf '%s' "${CW[$k]##*/}" | tr '[:upper:]' '[:lower:]')" && [ "$CRED_ANY" -eq 1 ]; then
        block "xargs feeding a command in a command line that names a credential file"
      fi
      return 0
      ;;
    find)
      for ((k = a; k < e; k++)); do
        case "${CW[$k]}" in
          -exec|-execdir|-ok|-okdir)
            if [ $((k + 1)) -lt $e ] && ! is_safe_cmd "$(printf '%s' "${CW[$((k + 1))]##*/}" | tr '[:upper:]' '[:lower:]')" && [ "$CRED_ANY" -eq 1 ]; then
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
    [ -n "$in_kind" ] && code_check "$in_text" "$cmd"
    check_generic "$a" "$e" "$CUR_CWD"
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
        analyze_cmd "${X[$i]//$'\003'/$'\n'}" $((depth + 1)) "$CUR_CWD"
        ;;
      H)
        HB+=("${X[$i]//$'\003'/$'\n'}")
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
        W) CW+=("${X[$i]//$'\003'/$'\n'}"); CF+=("${F[$i]}") ;;
        R) rt+=("${O[$i]}"); rf+=("${F[$i]}"); rx+=("${X[$i]//$'\003'/$'\n'}") ;;
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

analyze_cmd "$CMD" 0 "$PAYLOAD_CWD"
exit 0
