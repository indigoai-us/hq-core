#!/bin/bash
# hook-lib.sh — shared, python-free primitives for HQ hooks and scripts.
#
# SOURCED, never executed:  . "$HELPERS/hook-lib.sh"
# bash 3.2 safe; no heredocs nested inside $( ) (hooks-heredoc-syntax lint).
#
# HQ hooks must run on machines WITHOUT python3 — including Windows, where the
# Store alias stub resolves on PATH but cannot execute anything (so a bare
# `command -v python3` is not a usable capability probe). These primitives
# replace every inline `python3 -c` snippet the hooks used to carry.
#
# Engine order (locked 2026-07-15, Shahzaib):
#   - Hot-path primitives (hq_json_get / hq_json_encode / hq_normpath):
#     jq FIRST — jq ships with the HQ toolchain, is already a hard requirement
#     of the policy-trigger pipeline, and spawns fastest — then node (HQ is
#     npm-installed, so node exists on every HQ machine), else degrade to ""
#     so callers keep their existing fail-open behavior.
#   - Complex analyzers stay in their own hooks but follow node-first with an
#     awk fallback (see validate-policy-frontmatter.sh).
#
# Test override: HQ_HOOK_ENGINE=jq|node forces a single engine so parity
# suites can drive both implementations over the same payloads.

HQ_LIB_JQ="$(command -v jq 2>/dev/null || true)"
HQ_LIB_NODE="$(command -v node 2>/dev/null || true)"

# Is "\" a path SEPARATOR on this host, or an ordinary filename character?
#
# On Windows-family shells (Git Bash/MSYS/Cygwin) it is a separator and must be
# folded to "/". On POSIX it is a perfectly legal character IN a filename, and
# folding it corrupts real paths — dangerously so in a guard: with a symlink
# literally named `link\name` pointing into repos/, rewriting the input yields
# the non-existent lexical path workspace/link/name/file.txt, which resolves to
# nothing under repos/, so the hook exits 0 while the actual write follows the
# symlink and lands in the checkout.
#
# Detected ONCE at source time — hq_normpath is on the hook hot path and must
# not fork `uname` per call. Override with HQ_LIB_WINSEP=1|0 for tests.
if [ -z "${HQ_LIB_WINSEP:-}" ]; then
  HQ_LIB_WINSEP=0
  case "${OSTYPE:-}" in msys*|cygwin*|win32*) HQ_LIB_WINSEP=1 ;; esac
  if [ "$HQ_LIB_WINSEP" = "0" ]; then
    case "$(uname -s 2>/dev/null || true)" in MINGW*|MSYS*|CYGWIN*) HQ_LIB_WINSEP=1 ;; esac
  fi
fi
case "${HQ_HOOK_ENGINE:-}" in
  jq)   HQ_LIB_NODE="" ;;
  node) HQ_LIB_JQ="" ;;
esac

# hq_json_get <dotted.key.path>
#   stdin: JSON document. stdout: the addressed value, or "" when the path is
#   missing, null, or resolves to an object/array. Numeric path segments index
#   arrays ("tool_input.edits.0.old_string").
hq_json_get() {
  if [ -n "$HQ_LIB_JQ" ]; then
    "$HQ_LIB_JQ" -r --arg p "$1" '
      try (getpath($p | split(".") | map(if test("^[0-9]+$") then tonumber else . end))
        | if . == null or type == "object" or type == "array" then "" else tostring end)
      catch ""' 2>/dev/null || echo ""
    return 0
  fi
  if [ -n "$HQ_LIB_NODE" ]; then
    "$HQ_LIB_NODE" -e '
      let d = "";
      process.stdin.on("data", c => d += c).on("end", () => {
        let v;
        try { v = JSON.parse(d); } catch (e) { console.log(""); return; }
        for (const k of process.argv[1].split(".")) {
          if (v && typeof v === "object") v = Array.isArray(v) ? v[Number(k)] : v[k];
          else { v = undefined; break; }
        }
        if (v === undefined || v === null || typeof v === "object") console.log("");
        else console.log(String(v));
      });' "$1" 2>/dev/null || echo ""
    return 0
  fi
  cat >/dev/null 2>&1 || true
  echo ""
}

# hq_json_encode
#   stdin: raw string. stdout: the string as a JSON literal (quoted, escaped).
hq_json_encode() {
  if [ -n "$HQ_LIB_JQ" ]; then
    "$HQ_LIB_JQ" -Rs . 2>/dev/null || echo '""'
    return 0
  fi
  if [ -n "$HQ_LIB_NODE" ]; then
    "$HQ_LIB_NODE" -e '
      let d = "";
      process.stdin.on("data", c => d += c).on("end", () => console.log(JSON.stringify(d)));' \
      2>/dev/null || echo '""'
    return 0
  fi
  cat >/dev/null 2>&1 || true
  echo '""'
}

# hq_normpath <path>
#   Lexical normalization (no filesystem access): backslashes -> "/", collapse
#   interior "//" and "/./", resolve "x/..", trim trailing "/" (keeps root).
#   Both engines produce IDENTICAL output, so equality checks between two
#   hq_normpath results are stable regardless of engine or platform.
#
#   A LEADING "//" is preserved ONLY where it names a genuinely DISTINCT root:
#   Windows Git Bash/MSYS/Cygwin UNC shares (//server/share). POSIX leaves the
#   exactly-two-slash case implementation-defined; Linux resolves //tmp and /tmp
#   to the SAME directory, so preserving the distinction there protects nothing
#   and instead guarantees a mismatch whenever the two sides of a prefix check
#   are spelled differently. Both directions are live bypasses: a "//" project
#   root with a "/" file path, and a "/" root with a "//" file path, each let a
#   write into repos/ through. `pwd -P` does preserve "//", so the collapse must
#   happen HERE, after the physical resolution both helpers end with -- that is
#   what makes every spelling of one physical path compare equal, which is the
#   only property the repo guard actually depends on.
hq_normpath() {
  local input="$1" p line remaining s out last r drive root
  local isabs winsep
  local nl='
'
  [ -n "$input" ] || return 0
  winsep="${HQ_LIB_WINSEP:-0}"

  # Preserve the prior record-by-record behavior for embedded newlines while
  # keeping this hot path entirely within bash.
  while :; do
    case "$input" in
      *"$nl"*)
        line=${input%%"$nl"*}
        input=${input#*"$nl"}
        ;;
      *)
        line=$input
        input=""
        ;;
    esac

    p=$line
    if [ "$winsep" = "1" ]; then
      p=${p//\\//}
    fi
    isabs=0
    drive=""
    case "$p" in
      /*) isabs=1 ;;
    esac
    case "$p" in
      [A-Za-z]:*)
        drive=${p:0:2}
        p=${p:2}
        case "$p" in
          /*) isabs=1 ;;
          *) isabs=0 ;;
        esac
        ;;
    esac
    root=""
    if [ "$isabs" = "1" ]; then
      if [ "$winsep" = "1" ]; then
        case "$p" in
          //|//[!/]*) root="//" ;;
          *) root="/" ;;
        esac
      else
        root="/"
      fi
    fi

    out=""
    remaining=$p
    while :; do
      case "$remaining" in
        */*)
          s=${remaining%%/*}
          remaining=${remaining#*/}
          ;;
        *)
          s=$remaining
          remaining=""
          ;;
      esac
      case "$s" in
        ''|.) ;;
        ..)
          if [ -n "$out" ]; then
            last=${out##*/}
          else
            last=""
          fi
          if [ -n "$out" ] && [ "$last" != ".." ]; then
            case "$out" in
              */*) out=${out%/*} ;;
              *) out="" ;;
            esac
          elif [ "$isabs" != "1" ]; then
            if [ -n "$out" ]; then
              out="$out/.."
            else
              out=".."
            fi
          fi
          ;;
        *)
          if [ -n "$out" ]; then
            out="$out/$s"
          else
            out=$s
          fi
          ;;
      esac
      [ -n "$remaining" ] || break
    done

    r=$out
    if [ "$isabs" = "1" ]; then
      r="$root$r"
    fi
    if [ -n "$drive" ]; then
      r="$drive$r"
    fi
    if [ -z "$r" ]; then
      if [ "$isabs" = "1" ]; then
        r=$root
      else
        r="."
      fi
    fi
    printf '%s\n' "$r"
    [ -n "$input" ] || break
  done
}

# hq_realpath_lenient <path>
#   Symlink-resolved path that tolerates a leaf which does not exist yet, and
#   an arbitrarily deep tail of missing parents. Mirrors the semantics the repo
#   guard previously got from `python3 os.path.realpath(dirname(p))` + join
#   leaf: the PARENT chain is symlink-resolved, the leaf is kept verbatim.
#
#   Implementation is `cd -P` + POSIX shell only. `readlink -f` is deliberately
#   NOT used: macOS ships BSD readlink, which has no -f. python3 is deliberately
#   NOT used: it is absent on many Windows machines, and there the Store alias
#   stub resolves on PATH while failing every call, so a `command -v python3`
#   guard around it silently disables whatever the resolution was protecting.
#
#   ORDER IS LOAD-BEARING. The existing part of the path is handed to `cd -P`
#   with its `..` segments INTACT, because `..` must be applied by the OS after
#   symlinks are resolved, not collapsed lexically first. Given
#   workspace/link -> repos/private/app/dir, the path
#   workspace/link/../secret.txt really means repos/private/app/secret.txt;
#   normalizing first yields workspace/secret.txt, which escapes a repos/ prefix
#   check entirely. For the same reason `cd` must be `cd -P` — bash's default
#   logical `cd` collapses link/.. to the link's parent, reintroducing the bug.
#   Only the not-yet-existing tail is normalized lexically, since there is no
#   filesystem there to consult (this is what python's realpath does too).
hq_realpath_lenient() {
  local p="$1" leaf parent head tail resolved
  [ -n "$p" ] || { printf '%s' "$p"; return 0; }
  # Separator folding ONLY where "\" is actually a separator; NO `..` collapsing
  # here — see above. On POSIX a backslash is part of the filename and folding it
  # would make this resolve a path the write will never touch.
  if [ "${HQ_LIB_WINSEP:-0}" = "1" ]; then
    case "$p" in
      *\\*) p="$(printf '%s' "$p" | tr '\\' '/')" ;;
    esac
  fi
  case "$p" in
    */*) leaf="${p##*/}"; parent="${p%/*}"; [ -n "$parent" ] || parent="/" ;;
    *)   leaf="$p"; parent="." ;;
  esac
  # Walk up to the deepest ancestor that actually exists; remember the rest.
  # `[ -d ]` follows symlinks, so a head ending in `link/..` tests the real dir.
  head="$parent"; tail=""
  while [ "$head" != "/" ] && [ "$head" != "." ] && [ ! -d "$head" ]; do
    tail="${head##*/}${tail:+/}${tail}"
    case "$head" in
      */*) head="${head%/*}"; [ -n "$head" ] || head="/" ;;
      *)   head="." ;;
    esac
  done
  resolved="$(cd -P "$head" 2>/dev/null && pwd -P)" || resolved="$(hq_normpath "$head")"
  [ -n "$tail" ] && resolved="${resolved%/}/$tail"
  hq_normpath "${resolved%/}/$leaf"
}

# hq_realpath_dir <dir>
#   FULL symlink resolution for a directory that exists, including its own leaf;
#   echoes the input unchanged if it is not a directory.
#
#   Use this for the ROOT side of a prefix comparison. hq_realpath_lenient
#   deliberately leaves the leaf alone, which is right for a write target but
#   wrong for a root: when HQ itself is reached through a symlink (/home/me/hq
#   -> /mnt/data/hq), a leaf-preserving root stays "/home/me/hq" while every
#   fully-resolved file path under it reads "/mnt/data/hq/...", so the prefix
#   test silently never matches and the guard passes everything.
#   `cd -P`, not plain `cd`, for the same reason as hq_realpath_lenient — and it
#   matters MORE here, because the two sides of the prefix test must agree. With
#   link -> real/other and both real/hq and hq existing, a logical `cd` on
#   link/../hq lands on hq while the file side resolves to real/hq/..., the
#   prefix comparison misses, and the guard exits 0.
#   The result is passed through hq_normpath for the same reason: BOTH operands
#   of a prefix comparison must go through the identical normalizer, or a form
#   one side preserves and the other rewrites (a leading "//", a trailing "/")
#   silently breaks the match. Do not "simplify" this by returning pwd -P raw.
hq_realpath_dir() {
  local d="$1" p
  [ -d "$d" ] || { hq_normpath "$d"; return 0; }
  p="$(cd -P "$d" 2>/dev/null && pwd -P)" || p="$d"
  hq_normpath "$p"
}

# Strip only a complete standalone quoted cat-to-file heredoc. The header
# remains visible to guards; unquoted bodies, pipelines, trailing commands and
# ambiguous headers remain untouched. No shell input is evaluated.
hq_shell_strip_standalone_data_heredoc() {
  local raw="$1" header rest delimiter quote close line
  local re='^[[:space:]]*cat[[:space:]]+>[[:space:]]*[A-Za-z0-9_./-]+[[:space:]]+<<[[:space:]]*([\x27"])([A-Za-z0-9_]+)([\x27"])[[:space:]]*$'
  # Build the quote character class portably for Bash 3.2's ERE engine.
  re="${re//\\x27/\'}"
  header="${raw%%$'\n'*}"
  if [[ "$raw" != *$'\n'* ]] || ! [[ "$header" =~ $re ]]; then printf '%s' "$raw"; return; fi
  quote="${BASH_REMATCH[1]}"; delimiter="${BASH_REMATCH[2]}"; close="${BASH_REMATCH[3]}"
  if [ "$quote" != "$close" ]; then printf '%s' "$raw"; return; fi
  rest="${raw#*$'\n'}"
  while [ -n "$rest" ]; do
    line="${rest%%$'\n'*}"
    if [ "$line" = "$delimiter" ]; then
      if [ "$rest" = "$line" ] || [ "$rest" = "$line"$'\n' ]; then
        printf '%s' "$header"; return
      fi
      break
    fi
    [[ "$rest" == *$'\n'* ]] || break
    rest="${rest#*$'\n'}"
  done
  printf '%s' "$raw"
}

# hq_shell_simple_commands <command>
# Emit one unit-separator-delimited argv record for each simple command in a
# shell command string. Quotes and escapes are interpreted only far enough to
# identify command boundaries and arguments; nothing is evaluated. This gives
# guards a safe classification surface: `grep "git reset"` is grep, while
# `git reset` is git. Redirections are retained as argv tokens so write guards
# can inspect their targets.
#
# An ANSI-C string ($'...') is decoded the way Bash 5 decodes it, so a word
# spelled with escapes (\x2e, \056, \u002e, \t, \cA, ...) reaches guards as the
# word Bash runs. Where Bash 3.2 reads an escape differently (it has no \u or
# \U escape and keeps both as written), the record is printed a second time
# with the Bash 3.2 reading, so a guard checks both words and blocks if either
# is protected. A decoded newline, tab or space becomes "?", so it cannot split
# a record or a target word.
#
# hq_shell_simple_commands <command> raw
# Same split, but each word is printed as it is spelled in the command, with
# its quotes and backslashes kept. Records, words and embedded newlines line
# up one for one with the default output, so a caller can read both and tell
# whether a word was written literally at that argv position.
#
# hq_shell_simple_commands <command> nl
# Same split as the default, but a newline inside a word (a quoted newline in a
# `bash -c` program) is printed as the record-separator byte \036, so each
# simple command stays on one output line. The caller turns \036 back into a
# newline in each word.
hq_shell_simple_commands() {
  local rc=0 lrc=0
  _hq_shell_simple_commands_lexer "$@" || lrc=$?
  # Exit 3 from the lexer: the input ended inside a $( or backtick
  # substitution that it read as commands, so the words after the opener were
  # read as the inside of that substitution (where a quote can hide a later
  # command). The flat reading is printed too, as for <<, so such input reads
  # no looser than before substitutions were modelled. The lexer also exits 3
  # when it read a # inside a substitution as a comment: /bin/bash 3.2 may end
  # the substitution at a ) after a # that follows an operator.
  if [ "$lrc" -eq 3 ]; then
    _hq_shell_simple_commands_flat "$@" || rc=$?
    return "$rc"
  fi
  rc="$lrc"
  # Fail closed on heredoc guesses. Whether a << starts a heredoc, and where
  # its body ends, depends on parse context this lexer does not model in full:
  # arithmetic after time -p or coproc, redirections before an assignment, a
  # substitution in the delimiter, a body that ends at EOF) inside $(...), and
  # more. A wrong guess turns the lines after it into body text, where # and
  # quotes are data, so a guard could read a different target from the one
  # Bash runs. So whenever the command holds <<, the records of the flat
  # reading (no heredoc detection, every line read as shell text) are printed
  # after the heredoc-aware ones, and a guard blocks if either reading is
  # protected. Both readings are printed in every mode, so the default, raw
  # and nl outputs still line up record for record.
  case "$1" in
    *'<<'*) _hq_shell_simple_commands_flat "$@" || rc=$? ;;
  esac
  return "$rc"
}

# _hq_shell_simple_commands_lexer: the heredoc-aware reading (see above).
_hq_shell_simple_commands_lexer() {
  # A function, alias, PATH, hash or enable change in the same command can
  # make the `cat`, `gh` or `git` of a message heredoc run something else, as
  # in `cat() { sh; }; gh pr comment 1 --body "$(cat <<'EOF' ...`. With any of
  # them in the text, message heredoc bodies are printed like other bodies
  # (see hd_text_arg).
  local hq_msg_relax_off=0
  case "$1" in
    *'<<'*)
      local hq_fn_re='[A-Za-z_][A-Za-z0-9_.:-]*[[:space:]]*[(][[:space:]]*[)]'
      local hq_word_re='(^|[^A-Za-z0-9_-])(function|alias|hash|enable)([^A-Za-z0-9_-]|$)'
      local hq_path_re='(^|[^A-Za-z0-9_])PATH[+]?='
      if [[ "$1" =~ $hq_fn_re ]] || [[ "$1" =~ $hq_word_re ]] || [[ "$1" =~ $hq_path_re ]]; then
        hq_msg_relax_off=1
      fi
      # Bash sets $_ to the last argument of the previous command, which for
      # a message command is the hidden body itself. A later `sh -c "$_"`,
      # `eval "$_"`, `python3 -c "$_"` and the like would then run it. With
      # $_ or ${_...} in the text, or a way to reach $_ without naming it
      # (${!name} indirection, eval of a built string, a declare or typeset
      # nameref), message heredoc bodies are printed like other bodies.
      # Bash deletes a backslash-newline before it reads words, also inside
      # double quotes, so "$\<newline>_" is "$_". The text is matched with
      # those pairs removed.
      local hq_bsnl=$'\\\n'
      local hq_joined="${1//"$hq_bsnl"/}"
      local hq_last_re='[$]_([^A-Za-z0-9_]|$)|[$][{]_([^A-Za-z0-9_]|$)|[$][{]!'
      local hq_reach_re='(^|[^A-Za-z0-9_-])(eval|declare|typeset)([^A-Za-z0-9_-]|$)'
      if [[ "$hq_joined" =~ $hq_last_re ]] || [[ "$hq_joined" =~ $hq_reach_re ]] \
        || [[ "$hq_joined" =~ $hq_fn_re ]] || [[ "$hq_joined" =~ $hq_word_re ]] || [[ "$hq_joined" =~ $hq_path_re ]]; then
        hq_msg_relax_off=1
      fi
      ;;
  esac
  # The handoff script is named by a relative path, so a directory change
  # earlier in the command (cd, pushd, popd, CDPATH) can make that path run
  # another file, and BASH_ENV, ENV, SHELLOPTS or BASHOPTS can make the shell
  # run code before the script reads its arguments. With any of them in the
  # text, its --summary and --title bodies are printed (see hd_text_arg).
  local hq_handoff_off=0
  case "$1" in
    *'<<'*)
      local hq_dir_re='(^|[^A-Za-z0-9_-])(cd|pushd|popd)([^A-Za-z0-9_-]|$)'
      local hq_env_re='(BASH_ENV|SHELLOPTS|BASHOPTS|CDPATH)|(^|[^A-Za-z0-9_])ENV[+]?='
      if [[ "$1" =~ $hq_dir_re ]] || [[ "$1" =~ $hq_env_re ]]; then
        hq_handoff_off=1
      fi
      ;;
  esac
  printf '%s' "$1" | awk -v raw_mode="${2:-}" -v msg_relax_off="$hq_msg_relax_off" -v handoff_off="$hq_handoff_off" '
    # Append to the current word, and to its Bash 3.2 reading when that differs.
    function aw(s) { word = word s; if (wamb) aword = aword s }
    function push_op(s) { if (hd_n > 0 && !hd_body) hd_ok = 0; argc++; argv[argc] = s; aargv[argc] = s; dargv[argc] = s }
    # A word after which (( starts an arithmetic command.
    function arith_lead(w) {
      return w == "{" || w == "!" || w == "then" || w == "do" || w == "else" || w == "elif" || w == "if" || w == "while" || w == "until" || w == "time" || w == "for"
    }
    # True when the word being read starts where Bash accepts an assignment:
    # the start of a command, or after assignments or a reserved word.
    function assign_pos(    k) {
      for (k = 1; k <= argc; k++) {
        # A redirection (an optional fd number, the operator and its target)
        # can come before an assignment in Bash.
        if (argv[k] ~ /^[<>]/) { k++; continue }
        if (argv[k] ~ /^[0-9]+$/ && k < argc && argv[k + 1] ~ /^[<>]/) continue
        if (argv[k] !~ /^[A-Za-z_][A-Za-z0-9_]*(\[.*\])?\+?=/ && !arith_lead(argv[k])) return 0
      }
      return 1
    }
    # A ) outside heredoc bodies closes the innermost ( on the paren stack.
    function paren_close() {
      if (sq > 0 && sqbase == pdepth) sq = 0
      if (pdepth > 0) {
        if (ptype[pdepth] == "s") { sq = psq[pdepth]; pq = ppq[pdepth]; sqbase = psqb[pdepth] }
        pdepth--
      }
    }
    function push_word(    hw) {
      hw = 0
      if (hd_want && (word != "" || rword != "")) { heredoc_word(); hw = 1 }
      # A word after the heredoc delimiter on its line: not a lone cat.
      if (!hw && hd_n > 0 && !hd_body && (word != "" || rword != "")) hd_ok = 0
      # Count case and esac at a command start inside $(, so the ) after a
      # case pattern does not end the substitution.
      if (sd > 0 && sk[sd] == "p" && (argc == 0 || cmd_lead(argv[argc]))) {
        if (word == "case") sc[sd]++
        else if (word == "esac" && sc[sd] > 0) sc[sd]--
      }
      if (word != "" || aword != "") {
        argc++
        dargv[argc] = word
        argv[argc] = (raw_mode == "raw" ? rword : word)
        aargv[argc] = (raw_mode == "raw" ? rword : (wamb ? aword : word))
        if (wamb) ramb = 1
        if (raw_mode == "nl") {
          gsub(/\n/, sprintf("%c", 30), argv[argc])
          gsub(/\n/, sprintf("%c", 30), aargv[argc])
        }
      }
      word = ""; rword = ""; aword = ""; wamb = 0
    }
    function emit(    j, out, aout) {
      push_word()
      if (argc == 0) return
      if (sd > 0 && sub_cd()) { argc = 0; ramb = 0; return }
      if (hd_body && hd_text_arg()) {
        for (j in argv) delete argv[j]
        for (j in aargv) delete aargv[j]
        argc = 0; ramb = 0; return
      }
      out = argv[1]; aout = aargv[1]
      for (j = 2; j <= argc; j++) { out = out US argv[j]; aout = aout US aargv[j] }
      print out
      # Same record count in every mode, so raw output still lines up.
      if (ramb) print aout
      for (j in argv) delete argv[j]
      for (j in aargv) delete aargv[j]
      argc = 0; ramb = 0
    }
    # A command substitution that Bash runs as its own command list: $( or a
    # backtick inside double quotes, and a backtick outside quotes (kind b),
    # or an escaped backtick inside one (kind e, one more level down). The
    # outer record is set aside, the text inside is read as new commands and
    # printed as records of its own, and then the outer record goes on with
    # the substitution text in its word, as it read before. Without this, a
    # write inside double quotes was never read as a command, and a backtick
    # at the start of a word was glued to the command name.
    function sub_push(kind, opener, beg,    j) {
      sd++; sk[sd] = kind; sop[sd] = opener; sbeg[sd] = beg; stx[sd] = ""
      sp[sd] = 0; sc[sd] = 0; sa[sd] = 0
      sargc[sd] = argc
      for (j = 1; j <= argc; j++) { sargv[sd, j] = argv[j]; saargv[sd, j] = aargv[j]; sdargv[sd, j] = dargv[j] }
      sword[sd] = word; srword[sd] = rword; saword[sd] = aword; swamb[sd] = wamb
      sramb[sd] = ramb; squote[sd] = quote; shdepth[sd] = hdepth
      # Bash reads << as a heredoc again inside a substitution, so the
      # arithmetic, ${ and [ state outside it is set aside until it ends.
      saq[sd] = aq; spq[sd] = pq; ssq[sd] = sq; ssqb[sd] = sqbase
      aq = 0; pq = 0; sq = 0
      for (j in argv) delete argv[j]
      for (j in aargv) delete aargv[j]
      argc = 0; word = ""; rword = ""; aword = ""; wamb = 0; ramb = 0
      quote = ""; hdepth = 0; fresh = 1
      bt = (kind != "p")
    }
    # End the innermost substitution. atend 0: its closer starts at text
    # position i. atend 1: the input or a heredoc body ended (the text is
    # already saved). atend 2: it ends at i with no closer of its own.
    function sub_pop(atend,    body, closer, add, j) {
      emit()
      body = stx[sd]
      if (atend != 1) body = body substr(text, sbeg[sd], i - sbeg[sd])
      closer = ""
      if (atend == 0) closer = (sk[sd] == "p" ? ")" : (sk[sd] == "e" ? "\\`" : "`"))
      if (sa[sd]) arith--
      argc = sargc[sd]
      for (j = 1; j <= argc; j++) {
        argv[j] = sargv[sd, j]; aargv[j] = saargv[sd, j]; dargv[j] = sdargv[sd, j]
        delete sargv[sd, j]; delete saargv[sd, j]; delete sdargv[sd, j]
      }
      word = sword[sd]; rword = srword[sd]; aword = saword[sd]; wamb = swamb[sd]
      ramb = sramb[sd]; quote = squote[sd]; hdepth = shdepth[sd]
      aq = saq[sd]; pq = spq[sd]; sq = ssq[sd]; sqbase = ssqb[sd]
      add = sop[sd] body closer
      sd--
      bt = (sd > 0 && sk[sd] != "p")
      rword = rword add
      aw(quote == "\"" ? dq_read(add) : add)
    }
    # An unescaped backtick ends an escaped-backtick level and the backtick
    # substitution around it.
    function bt_close() {
      if (sk[sd] == "e") sub_pop(2)
      sub_pop(0)
    }
    # The word text Bash keeps for s inside double quotes: a backslash before
    # a dollar sign, backtick, double quote, backslash or newline is dropped.
    function dq_read(s,    out, k, ch, nx) {
      out = ""
      for (k = 1; k <= length(s); k++) {
        ch = substr(s, k, 1); nx = substr(s, k + 1, 1)
        if (ch == "\\" && (nx == "$" || nx == "`" || nx == "\"" || nx == "\\" || nx == "\n")) { out = out nx; k++ }
        else out = out ch
      }
      return out
    }
    # True when the record is cd, pushd or popd. Inside a substitution a cd
    # changes the directory only there, but guards read records as one flat
    # list and would apply it to the commands after the substitution, so the
    # record is not printed. The decision reads the default words, so every
    # output mode prints the same records.
    # The command name is found the way block-core-writes-bash finds it
    # (shell_command_executable_result): assignments, the prefix words, and
    # options and assignments after env are skipped, so env X=y -i cd is a
    # cd here too.
    function sub_cd(    j, w, inenv) {
      inenv = 0
      for (j = 1; j <= argc; j++) {
        w = dargv[j]
        if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
        if (inenv && w ~ /^-/) continue
        if (w == "env") { inenv = 1; continue }
        inenv = 0
        if (w == "command" || w == "builtin" || w == "exec" || w == "sudo") continue
        return w == "cd" || w == "pushd" || w == "popd"
      }
      return 0
    }
    # True while the lines of a quoted heredoc body are message text that no
    # shell reads: the body of a lone `cat <<QUOTED` (nothing else on its
    # line) that is the whole of a double-quoted $( word, given as the value
    # of a message option: gh pr|issue create|comment|edit|review --body,
    # -b, --title or -t, or git ... commit|tag -m or --message. Those body
    # lines are not printed, so a PR body or commit message that quotes a
    # command is not read as one. Any other heredoc body is still printed;
    # under bash -c or eval it may run.
    function hd_text_arg(    n, a, c, v, j) {
      if (msg_relax_off) return 0
      if (!hd_q[hd_cur] || !hd_ok || sd == 0 || sd != hd_sd) return 0
      if (sk[sd] != "p" || squote[sd] != "\"" || sword[sd] != "") return 0
      n = sargc[sd]
      a = sdargv[sd, n]; c = sdargv[sd, 1]
      # The handoff script takes its --summary and --title text as data (it
      # passes them to jq as --arg values). Only the shipped relative path
      # counts, run directly or as the first operand of bash or sh with no
      # shell option before it, so another script of that name elsewhere,
      # or bash -c, still has its body printed. So does any command that
      # changes directory or sets a shell startup variable (handoff_off).
      v = (c == "bash" || c == "sh") ? sdargv[sd, 2] : c
      if (!handoff_off && (v == "core/scripts/handoff-finalize.sh" || v == "./core/scripts/handoff-finalize.sh") && (a == "--summary" || a == "--title"))
        return n >= ((c == "bash" || c == "sh") ? 3 : 2)
      if (n < 3) return 0
      if (c == "gh") {
        if (a != "--body" && a != "-b" && a != "--title" && a != "-t") return 0
        if (sdargv[sd, 2] != "pr" && sdargv[sd, 2] != "issue") return 0
        v = sdargv[sd, 3]
        return v == "create" || v == "comment" || v == "edit" || v == "review"
      }
      if (c == "git") {
        if (a != "-m" && a != "--message") return 0
        for (j = 2; j < n; j++) if (sdargv[sd, j] == "commit" || sdargv[sd, j] == "tag") return 1
      }
      return 0
    }
    # A reserved word after which the next word starts a command too.
    function cmd_lead(w) { return w != "for" && arith_lead(w) }
    # The word after << or <<- names the heredoc delimiter. Any quoting in it
    # makes the body literal text, as in Bash.
    function heredoc_word(    d, r) {
      d = word; r = rword
      if (hd_dash == 1) {
        if (r == "-") { hd_dash = 2; return }
        d = substr(d, 2); r = substr(r, 2)
      }
      # <<$(...) : the word was cut at the ( so only the dollar sign is
      # left. Its body end cannot be known here, so no heredoc is started
      # and the lines after it are read as shell.
      if (r == "$") { hd_want = 0; hd_dash = 0; return }
      hd_n++; hd_delim[hd_n] = d; hd_q[hd_n] = (r != d); hd_tab[hd_n] = (hd_dash > 0)
      # A lone cat with this one heredoc (see hd_text_arg).
      hd_ok = (hd_n == 1 && argc == 2 && dargv[1] == "cat" && argv[2] == "<<"); hd_par = 0
      hd_want = 0; hd_dash = 0
    }
    # Add decoded text s (Bash 5) and as (Bash 3.2) to an ANSI-C word. A NUL
    # byte ends the rest of the string in Bash, so drop and adrop stop the
    # text for that reading until the closing quote.
    function ansi_add(s, as, drop, adrop) {
      ansi_qonly = 0
      if ((s != as || drop != adrop) && !wamb) { wamb = 1; aword = word; ansi_adrop = ansi_drop }
      if (!ansi_drop) word = word s
      if (wamb && !ansi_adrop) aword = aword as
      if (drop) ansi_drop = 1
      if (adrop) ansi_adrop = 1
    }
    # One decoded byte. A byte that would split the record or the word
    # (newline, tab, space, and the record and unit separators) becomes "?":
    # guards read records line by line and split targets on whitespace again,
    # so a decoded newline or space hid the command or its target. A byte
    # outside ASCII keeps its escape as written: it cannot spell any ASCII
    # path name, so the exact byte does not matter to a guard.
    function ansi_char(v, raw) {
      if (v == 0) return ""
      if (v == 9 || v == 10 || v == 32 || v == 30 || v == 31) return "?"
      if (v >= 128) return raw
      return sprintf("%c", v)
    }
    # An ANSI-C string made of nothing but escaped quotes keeps the shape the
    # lexer gave it before decoding: the dollar sign and each escape as written
    # (the strip-exclude helper and its tests read that shape). This is safe
    # because both readings of such a string, the dollar sign with the escapes
    # as written and the bare quote Bash runs, are a single path component
    # made of a quote character. Neither can ever equal ".", "..", ".claude"
    # or "/", so no guard match depends on which reading it sees.
    # Any other string that holds an escaped quote is decoded in full, quote
    # included, so a protected path with an escaped quote in it reads as the
    # path Bash runs.
    function ansi_close(    k) {
      if (!(ansi_hasq && ansi_qonly)) return
      word = substr(word, 1, ansi_start) "$"
      for (k = 1; k <= ansi_qn; k++) word = word "\\" "\047"
      if (wamb) {
        aword = substr(aword, 1, ansi_start) "$"
        for (k = 1; k <= ansi_qn; k++) aword = aword "\\" "\047"
      }
    }
    # Decode the backslash escape at text position i inside an ANSI-C string.
    function ansi_escape(    nc, ch, v, k, max, d, raw, alt, keep) {
      nc = substr(text, i + 1, 1)
      i++; rword = rword nc; raw = "\\" nc; v = -1; alt = 0
      if (nc == "a") v = 7
      else if (nc == "b") v = 8
      else if (nc == "e" || nc == "E") v = 27
      else if (nc == "f") v = 12
      else if (nc == "n") v = 10
      else if (nc == "r") v = 13
      else if (nc == "t") v = 9
      else if (nc == "v") v = 11
      else if (nc == "\047") { keep = ansi_qonly; ansi_add(nc, nc, 0, 0); ansi_qonly = keep; ansi_hasq = 1; ansi_qn++; return }
      else if (nc == "\\" || nc == "\"" || nc == "?") { ansi_add(nc, nc, 0, 0); return }
      else if (nc ~ /^[0-7]$/) {
        v = nc + 0
        for (k = 1; k < 3; k++) {
          ch = substr(text, i + 1, 1)
          if (ch !~ /^[0-7]$/) break
          v = v * 8 + ch; i++; rword = rword ch; raw = raw ch
        }
        v = v % 256
      }
      else if (nc == "x" || nc == "u" || nc == "U") {
        max = (nc == "x" ? 2 : (nc == "u" ? 4 : 8)); v = 0
        for (k = 0; k < max; k++) {
          ch = substr(text, i + 1, 1)
          d = (ch == "" ? 0 : index("0123456789abcdef", tolower(ch)))
          if (d == 0) break
          v = v * 16 + d - 1; i++; rword = rword ch; raw = raw ch
        }
        if (k == 0) { ansi_add(raw, raw, 0, 0); return }
        # Bash 3.2 has no \u or \U escape: it keeps both as written.
        if (nc != "x" && v < 128) alt = 1
        if (nc != "x" && v >= 128) v = 128
      }
      else if (nc == "c") {
        ch = substr(text, i + 1, 1)
        if (ch == "\047" || !(ch in ORD)) { ansi_add(raw, raw, 0, 0); return }
        i++; rword = rword ch; raw = raw ch
        v = (ch == "?" ? 127 : ORD[toupper(ch)] % 32)
      }
      else { ansi_add(raw, raw, 0, 0); return }
      if (alt) ansi_add(ansi_char(v, raw), raw, v == 0, 0)
      else ansi_add(ansi_char(v, raw), ansi_char(v, raw), v == 0, v == 0)
    }
    BEGIN {
      quote = ""; escaped = 0; word = ""; rword = ""; aword = ""; wamb = 0
      argc = 0; ramb = 0; bt = 0; fresh = 0; ansi_drop = 0; ansi_adrop = 0; ansi_hasq = 0; ansi_qonly = 0; ansi_qn = 0; ansi_start = 0
      hd_want = 0; hd_dash = 0; hd_n = 0; hd_cur = 0; hd_body = 0; hdepth = 0; contline = 0
      aq = 0; qbody = 0; pq = 0; sq = 0; sqbase = 0; dol = 0; pdol = 0; pdepth = 0
      sd = 0; arith = 0; hd_sd = 0; hd_ok = 0
      US = sprintf("%c", 31)
      for (k = 1; k < 128; k++) ORD[sprintf("%c", k)] = k
    }
    {
      # Parse the payload as one stream: quote, escape, and word state carry
      # over from one input line to the next, because a quoted `bash -c`
      # program and a heredoc can span newlines; resetting quote state at
      # each line silently discarded the command before it. Each line is
      # parsed as it is read, with its newline restored. Joining all lines
      # into one string first copied the string once per line, which grew
      # with the square of the command length.
      text = $0 "\n"
      n = length(text)
      # A heredoc body ends at the first line that is exactly its delimiter
      # (after leading tabs, for <<-). Bash reads the body before it parses
      # anything in it, so the delimiter line ends the body whatever the body
      # left open.
      hd_last = 0
      if (hd_body) {
        hd_line = $0
        if (hd_tab[hd_cur]) sub(/^\t+/, "", hd_line)
        if (hd_line == hd_delim[hd_cur]) hd_last = 1
      }
      # Bash 3.2 does not read a heredoc inside $( as a body: it ends the
      # substitution at the first ) that its own count does not match, and
      # the lines after it can then run. Message body lines stay hidden only
      # while every ( and ) so far is matched and no line holds a character
      # that can hide one from that count (a single quote, a backtick, a
      # backslash, or a # before a parenthesis). From the first line that
      # breaks this, body lines are printed again.
      # Double quotes are read the way Bash 3.2 counts them: a parenthesis in
      # a double-quoted span is not counted unless it belongs to a $( in that
      # span, which Bash 3.2 does match. A line keeps the body hidden only
      # when each double-quoted span closes on the same line, holds no bare
      # parenthesis, and holds no quote inside a $( of its own. So JSON text
      # such as {"cost": "$(date)"} stays hidden, while a quoted ( with a bare
      # ) on a later line does not: Bash 3.2 ends the substitution at that )
      # and runs the lines after it.
      if (hd_body && hd_ok && !hd_last) {
        hd_line = $0
        if (index(hd_line, "`") || index(hd_line, "\\") || index(hd_line, "\047") || hd_line ~ /#.*[()]/) hd_ok = 0
        hd_dq = 0; hd_dqp = 0
        for (k = 1; hd_ok && k <= length(hd_line); k++) {
          c = substr(hd_line, k, 1)
          if (c == "\"") { if (hd_dqp > 0) hd_ok = 0; else hd_dq = !hd_dq; continue }
          if (hd_dq) {
            if (c == "$" && substr(hd_line, k + 1, 1) == "(") { hd_dqp++; k++ }
            else if (c == "(") { if (hd_dqp > 0) hd_dqp++; else hd_ok = 0 }
            else if (c == ")") { if (hd_dqp > 0) hd_dqp--; else hd_ok = 0 }
            continue
          }
          if (c == "(") hd_par++
          else if (c == ")" && --hd_par < 0) hd_ok = 0
        }
        if (hd_dq || hd_dqp) hd_ok = 0
      }
      hd_hide = (hd_body && !hd_last && hd_text_arg())
      for (i = 1; i <= n; i++) {
        c = substr(text, i, 1)
        ws = fresh; fresh = 0
        pdol = dol; dol = 0
        if (qbody && c == "\n") { quote = ""; qbody = 0; escaped = 0 }
        if (escaped) { aw(c); rword = rword c; escaped = 0; continue }
        # Inside a backtick substitution, Bash finds the closing backtick
        # before it reads any quote, so an unescaped backtick ends the
        # substitution even inside a quote that was opened in it.
        if (quote == "\047") {
          if (bt && c == "\\" && substr(text, i + 1, 1) == "`") {
            if (sk[sd] == "e") { sub_pop(0); i++; continue }
            aw("`"); rword = rword c "`"; i++; continue
          }
          if (bt && c == "`") { bt_close(); continue }
          rword = rword c
          if (c == "\047") quote = ""; else aw(c)
          continue
        }
        if (quote == "$\047") {
          # ANSI-C quoting (dollar sign, then a single-quoted string): a
          # backslash starts an escape, so an escaped quote does not end the
          # string. Escapes are decoded into the word; the raw word keeps
          # the string as written. (No quote characters in this comment: the
          # awk program is a single-quoted shell string.)
          if (bt && c == "`") { ansi_drop = 0; ansi_adrop = 0; bt_close(); continue }
          if (sk[sd] == "e" && c == "\\" && substr(text, i + 1, 1) == "`") {
            ansi_drop = 0; ansi_adrop = 0; sub_pop(0); i++; continue
          }
          rword = rword c
          if (c == "\047") {
            ansi_close()
            quote = ""; ansi_drop = 0; ansi_adrop = 0
            continue
          }
          if (c == "\\") ansi_escape(); else ansi_add(c, c, 0, 0)
          continue
        }
        if (quote == "\"") {
          # Inside double quotes a backslash escapes only $ ` " \ and newline,
          # as in Bash. Any other backslash stays in the word, so
          # "C:\Program Files\Git\cmd\git.exe" keeps its path separators.
          # A backslash-newline is removed (a line continuation).
          if (c == "\\" && substr(text, i + 1, 1) == "\n") { i++; contline = 1; continue }
          # $( and a backtick start a command substitution here too.
          if (bt && c == "`") { bt_close(); continue }
          if (sk[sd] == "e" && c == "\\" && substr(text, i + 1, 1) == "`") { sub_pop(0); i++; continue }
          if (c == "`") { sub_push("b", c, i + 1); continue }
          if (c == "$" && substr(text, i + 1, 1) == "(") {
            sub_push("p", "$(", i + 2); i++
            if (substr(text, i + 1, 1) == "(") { sa[sd] = 1; arith++ }
            continue
          }
          rword = rword c
          if (c == "\"") quote = ""
          else if (c == "\\") {
            nc = substr(text, i + 1, 1)
            if (nc == "$" || nc == "`" || nc == "\"" || nc == "\\" || nc == "\n") escaped = 1
            else aw(c)
          }
          else aw(c)
          continue
        }
        # Heredoc body text is data: quotes and # are ordinary characters in
        # it, so an apostrophe in the body cannot open a quote that hides the
        # commands after the heredoc. Its words are still split and shown to
        # guards. In an unquoted body, $( and backticks still run commands,
        # so the text inside them is read as shell again.
        hlit = hd_body && sd == hd_sd && (hd_q[hd_cur] || (hdepth == 0 && !bt))
        if (hlit) {
          if (!hd_q[hd_cur] && c == "`") { sub_push("b", c, i + 1); continue }
          if (!hd_q[hd_cur] && c == "$" && substr(text, i + 1, 1) == "(") {
            aw(c); rword = rword c; emit(); hdepth = 1; i++; continue
          }
          # A quote here holds no state, but it is still dropped from the
          # word as Bash would drop it, so a quoted path reads the same if
          # the << was not a heredoc after all (an arithmetic shift).
          # In a quoted body nothing expands, so a quote still groups the
          # words inside it, but only to the end of its line (qbody): an
          # apostrophe cannot reach the commands after the heredoc, and a
          # quoted string in a python line stays one word with its spaces.
          # Guards rely on that shape to tell body text from shell words. In
          # an unquoted body a substitution runs, so a quote there holds no
          # state.
          if (c == "\047" || c == "\"") {
            rword = rword c
            if (hd_q[hd_cur]) { quote = c; qbody = 1 }
            continue
          }
          if (c == "#" || c == "$") { aw(c); rword = rword c; continue }
        } else {
          # A backtick opens or closes a command substitution, and inside one
          # an escaped backtick opens or closes one more level.
          if (c == "`") { if (bt) bt_close(); else sub_push("b", c, i + 1); continue }
          if (bt && c == "\\" && substr(text, i + 1, 1) == "`") {
            if (sk[sd] == "e") sub_pop(0); else sub_push("e", "\\`", i + 2)
            i++; continue
          }
          # Two dollar signs are the shell PID expansion, read before any
          # quote. Take them as a pair so a quote right after them stays an
          # ordinary single quote and never opens an ANSI-C string. An odd
          # run still ends in one dollar sign that can start one, as in Bash.
          if (c == "$" && substr(text, i + 1, 1) == "$") {
            aw("$$"); rword = rword "$$"; i++; continue
          }
          # Locale quoting: $"..." is the quoted text without the dollar sign.
          if (c == "$" && substr(text, i + 1, 1) == "\"") { rword = rword c; continue }
          if (c == "$" && substr(text, i + 1, 1) == "\047") {
            quote = "$\047"; rword = rword c "\047"; ansi_drop = 0; ansi_adrop = 0; ansi_hasq = 0; ansi_qonly = 1; ansi_qn = 0; ansi_start = length(word); i++; continue
          }
          # An unquoted # at the start of a word begins a comment, as in Bash.
          # Without this, a quote character inside a trailing comment opened
          # a quote that swallowed the whole command, so no record was
          # emitted and guards saw nothing to check. The first word inside a
          # backtick substitution is a word start too, and there the comment
          # ends at the closing backtick, not at the end of the line.
          # Inside a substitution, a # right after a non-blank byte (as in
          # x;# or x&#) is a comment for Bash 5, but /bin/bash 3.2 ends the
          # substitution at the next ) and runs what follows. Any comment
          # inside a substitution is flagged so the caller adds the flat
          # reading, where # is a word byte (fail closed: a comment after a
          # blank costs at most a false block).
          if (c == "#" && ((word == "" && rword == "") || ws)) {
            if (sd > 0) cmt_amb = 1
            while (i < n) {
              nc = substr(text, i + 1, 1)
              if (nc == "\n" || (bt && nc == "`")) break
              if (bt && nc == "\\" && substr(text, i + 2, 1) == "`") {
                if (sk[sd] == "e") break
                i++
              }
              i++
            }
            continue
          }
          if (c == "\047" || c == "\"") { quote = c; rword = rword c; continue }
        }
        # A backslash-newline outside a heredoc body joins the two lines, as
        # in Bash: neither byte is part of the word, and the dollar-sign and
        # word-start state before it carry over. The lexer reads one line at
        # a time and cannot look ahead past the line end, so a << on a line
        # that was continued starts no heredoc (contline): a construct split
        # by the continuation, such as a[ or $(( , may make it a shift.
        if (c == "\\" && !hlit && substr(text, i + 1, 1) == "\n") { i++; dol = pdol; fresh = ws; contline = 1; continue }
        if (c == "\\") { escaped = 1; rword = rword c; continue }
        if (c == " " || c == "\t") { push_word(); continue }
        # Track arithmetic: $(( and (( at a command start open it, and its
        # parentheses are counted until they close. A << inside it is a
        # shift, not a heredoc. Parentheses in heredoc body text are data,
        # so they are not counted.
        if (!hlit && c == "(") {
          if (aq > 0) aq++
          else if (substr(text, i + 1, 1) == "(" && (substr(rword, length(rword)) == "$" || (word == "" && rword == "" && (argc == 0 || arith_lead(argv[argc]))))) aq = 1
        }
        else if (!hlit && c == ")" && aq > 0) aq--
        if (!hlit && hdepth == 0 && c == ")" && sd > 0 && sk[sd] == "p") {
          # The ) that matches the $( ends it, unless it ends a case pattern.
          # A ) in heredoc body text is data and ends nothing.
          push_word()
          if (sp[sd] == 0 && sc[sd] == 0) { sub_pop(0); continue }
          if (sp[sd] > 0) { sp[sd]--; if (!hd_body) paren_close() }
          else if (!hd_body && sq > 0 && sqbase == pdepth) sq = 0
          emit(); continue
        }
        if (!hlit && hdepth == 0 && c == "(" && sd > 0 && sk[sd] == "p") sp[sd]++
        # Bash also reads << as a shift inside ${...}, inside $[...] and
        # inside the subscript of name[...] at an assignment spot (with or
        # without a following =), so none of them starts a heredoc. A wrong
        # heredoc guess turns the lines after it into body text, where a
        # trailing comment is read as words and can replace a write target.
        # An unclosed ${ here is a syntax error that stops Bash before
        # anything after it runs. A [ in a case pattern is not a subscript,
        # so a ) that closes no ( opened after the [ ends it.
        if (!hlit) {
          if (c == "{" && pdol) pq++
          else if (c == "}" && pq > 0) pq--
          else if (c == "[" && (sq > 0 || pdol || (pq == 0 && word == rword && rword ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && assign_pos()))) { if (sq == 0) sqbase = pdepth; sq++ }
          else if (c == "]" && sq > 0) sq--
        }
        # Parentheses outside heredoc bodies are kept on a stack. $( opens a
        # command substitution, where Bash reads << as a heredoc again, so
        # the ${ and [ state outside it is saved and cleared until its ).
        # name=( and name+=( open a compound array assignment, where Bash 5
        # reads << as part of a subscript and Bash 3.2 stops at a syntax
        # error, so no heredoc starts directly inside one.
        if (!hlit && !hd_body && c == "(") {
          pdepth++; psq[pdepth] = sq; ppq[pdepth] = pq; psqb[pdepth] = sqbase
          if (pdol && substr(text, i + 1, 1) != "(") { ptype[pdepth] = "s"; sq = 0; pq = 0 }
          else if (rword ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=$/) ptype[pdepth] = "c"
          else ptype[pdepth] = "p"
        }
        else if (!hlit && !hd_body && c == ")") paren_close()
        if (c == ";" || c == "|" || c == "&" || c == "\n" || c == "(" || c == ")") {
          if (c != "\n" && hd_n > 0 && !hd_body) hd_ok = 0
          if (hdepth > 0) { if (c == "(") hdepth++; else if (c == ")") hdepth-- }
          emit()
          if ((c == "|" || c == "&") && substr(text, i + 1, 1) == c) i++
          if (c == "\n") {
            contline = 0
            # A heredoc body starts on the line after its << operator.
            hd_want = 0; hd_dash = 0
            if (hd_n > 0 && !hd_body) { hd_body = 1; hd_cur = 1; hdepth = 0; hd_sd = sd }
          }
          continue
        }
        if (c == ">" || c == "<") {
          push_word(); push_op(c)
          # Keep the Bash noclobber-override redirection (>|) with its target.
          # Treating the pipe byte as a command boundary would otherwise split
          # `printf x >| target` into two harmless-looking records.
          if (substr(text, i + 1, 1) == c || (c == ">" && substr(text, i + 1, 1) == "|")) {
            argv[argc] = argv[argc] substr(text, i + 1, 1); aargv[argc] = argv[argc]; i++
          }
          # << (but not the <<< here-string) starts a heredoc; <<- also
          # strips leading tabs from its body and delimiter lines.
          if (argv[argc] == "<<" && !hd_body && !aq && !arith && !pq && !sq && !bt && !(pdepth > 0 && ptype[pdepth] == "c") && !contline && !(argc > 1 && argv[argc - 1] ~ /\$\[[^]]*$/) && substr(text, i + 1, 1) != "<") {
            hd_want = 1; hd_dash = (substr(text, i + 1, 1) == "-")
          }
          continue
        }
        aw(c); rword = rword c
        if (!hlit && c == "$") dol = 1
      }
      # Keep the text of each open substitution, for the outer word. A body
      # line of message text (see hd_text_arg) is left out of it too: its
      # records are not printed, and the same line kept inside the outer
      # word would reach guards anyway, as one long word per body line.
      # (hd_hide is set before the line is read, so the << line itself,
      # which starts the body, is kept.)
      for (k = 1; k <= sd; k++) { stx[k] = stx[k] (hd_hide ? "" : substr(text, sbeg[k])); sbeg[k] = 1 }
      if (hd_last) {
        # Show any words a substitution in the body left open, then drop
        # every state the body left behind.
        while (sd > hd_sd) sub_pop(1)
        emit()
        quote = ""; qbody = 0; escaped = 0; hdepth = 0; ansi_drop = 0; ansi_adrop = 0; pq = 0; sq = 0
        bt = (sd > 0 && sk[sd] != "p")
        hd_cur++
        if (hd_cur > hd_n) { hd_body = 0; hd_n = 0; hd_cur = 0 }
      }
    }
    # Input that ends inside a quote is a shell syntax error, and input that
    # ends in a backslash is a literal backslash, but emit what was read so
    # far either way: guards then still see the words before it.
    # A substitution still open at the end is closed, so its words and the
    # outer record are both shown.
    # Exit 3 tells the caller a substitution was still open at the end, or
    # that a # inside one may not be a comment under /bin/bash 3.2.
    END { sub_open = (sd > 0); while (sd > 0) sub_pop(1); emit(); if (sub_open || cmt_amb) exit 3 }
  '
}

# _hq_shell_simple_commands_flat: the reading with no heredoc detection, in
# which every line is shell text. It is the lexer as it was before heredoc
# bodies and backtick substitutions were modelled, kept unchanged so a wrong
# heredoc guess in the lexer above can never read looser than it.
_hq_shell_simple_commands_flat() {
  printf '%s' "$1" | awk -v raw_mode="${2:-}" '
    function push_word() {
      if (word != "") {
        argv[++argc] = (raw_mode == "raw" ? rword : word)
        if (raw_mode == "nl") gsub(/\n/, sprintf("%c", 30), argv[argc])
      }
      word = ""; rword = ""
    }
    function emit(    j, out) {
      push_word()
      if (argc == 0) return
      out = argv[1]
      for (j = 2; j <= argc; j++) out = out sprintf("%c", 31) argv[j]
      print out
      for (j in argv) delete argv[j]
      argc = 0
    }
    BEGIN { quote = ""; escaped = 0; word = ""; rword = ""; argc = 0 }
    {
      # Parse the payload as one stream: quote, escape, and word state carry
      # over from one input line to the next, because a quoted `bash -c`
      # program and a heredoc can span newlines; resetting quote state at
      # each line silently discarded the command before it. Each line is
      # parsed as it is read, with its newline restored. Joining all lines
      # into one string first copied the string once per line, which grew
      # with the square of the command length.
      text = $0 "\n"
      n = length(text)
      for (i = 1; i <= n; i++) {
        c = substr(text, i, 1)
        if (escaped) { word = word c; rword = rword c; escaped = 0; continue }
        if (quote == "\047") {
          rword = rword c
          if (c == "\047") quote = ""; else word = word c
          continue
        }
        if (quote == "$\047") {
          # ANSI-C quoting (dollar sign, then a single-quoted string): a
          # backslash escapes the next character, so an escaped quote does
          # not end the string. The word keeps the dollar sign and every
          # escape as written; only the end of the string changes, so an
          # escaped quote no longer reads as an open single quote that hides
          # the rest of the command. (No quote characters in this comment:
          # the awk program is a single-quoted shell string.)
          rword = rword c
          if (c == "\\") {
            nc = substr(text, i + 1, 1)
            if (nc != "") { word = word c nc; rword = rword nc; i++ }
            else word = word c
          }
          else if (c == "\047") quote = ""
          else word = word c
          continue
        }
        if (quote == "\"") {
          # Inside double quotes a backslash escapes only $ ` " \ and newline,
          # as in Bash. Any other backslash stays in the word, so
          # "C:\Program Files\Git\cmd\git.exe" keeps its path separators.
          rword = rword c
          if (c == "\"") quote = ""
          else if (c == "\\") {
            nc = substr(text, i + 1, 1)
            if (nc == "$" || nc == "`" || nc == "\"" || nc == "\\" || nc == "\n") escaped = 1
            else word = word c
          }
          else word = word c
          continue
        }
        # Two dollar signs are the shell PID expansion, read before any quote.
        # Take them as a pair so a quote right after them stays an ordinary
        # single quote and never opens an ANSI-C string. An odd run still
        # ends in one dollar sign that can start one, as in Bash.
        if (c == "$" && substr(text, i + 1, 1) == "$") {
          word = word "$$"; rword = rword "$$"; i++; continue
        }
        if (c == "$" && substr(text, i + 1, 1) == "\047") {
          quote = "$\047"; word = word c; rword = rword c "\047"; i++; continue
        }
        # An unquoted # at the start of a word begins a comment that runs to
        # the end of the line, as in Bash. Without this, a quote character
        # inside a trailing comment opened a quote that swallowed the whole
        # command, so no record was emitted and guards saw nothing to check.
        if (c == "#" && word == "" && rword == "") {
          while (i < n && substr(text, i + 1, 1) != "\n") i++
          continue
        }
        if (c == "\047" || c == "\"") { quote = c; rword = rword c; continue }
        if (c == "\\") { escaped = 1; rword = rword c; continue }
        if (c == " " || c == "\t") { push_word(); continue }
        if (c == ";" || c == "|" || c == "&" || c == "\n" || c == "(" || c == ")") {
          emit()
          if ((c == "|" || c == "&") && substr(text, i + 1, 1) == c) i++
          continue
        }
        if (c == ">" || c == "<") {
          push_word(); argv[++argc] = c
          # Keep the Bash noclobber-override redirection (>|) with its target.
          # Treating the pipe byte as a command boundary would otherwise split
          # `printf x >| target` into two harmless-looking records.
          if (substr(text, i + 1, 1) == c || (c == ">" && substr(text, i + 1, 1) == "|")) {
            argv[argc] = argv[argc] substr(text, i + 1, 1); i++
          }
          continue
        }
        word = word c; rword = rword c
      }
    }
    # Input that ends inside a quote is a shell syntax error, but emit what
    # was read so far: guards then still see the words before the quote.
    END { if (quote != "") emit() }
  '
}

# hq_shell_command_executable <US-delimited argv>
# Print the executable of a simple command after leading environment
# assignments and the common `env` / `command` wrappers.
hq_shell_command_executable() {
  hq_shell_record_executable "$1" || return 1
  printf '%s' "$HQ_SHELL_EXECUTABLE"
}

# hq_shell_record_words <US-delimited argv>
# Split one hq_shell_simple_commands record into the HQ_SHELL_WORDS array.
# This matches `IFS=$'\037' read -r -a` for a record (records hold no newline)
# without a here-string, which Bash 3.2 backs with a temporary file: about
# 0.2 ms per call, or seconds across a 10,000-line command. Globbing is off
# while the record is split, so a word such as `*` stays literal.
hq_shell_record_words() {
  local IFS=$'\037' hq_words_noglob=0
  case "$-" in *f*) hq_words_noglob=1 ;; esac
  set -f
  # shellcheck disable=SC2206  # split on US with globbing off, as above
  HQ_SHELL_WORDS=($1)
  [ "$hq_words_noglob" -eq 1 ] || set +f
}

# hq_shell_record_executable <US-delimited argv>
# Same lookup as hq_shell_command_executable, but stores the result in
# HQ_SHELL_EXECUTABLE (empty when there is none) instead of printing it.
# Guards that classify every record of a long command call this form so the
# lookup costs no command-substitution subshell per record.
hq_shell_record_executable() {
  local token
  local -a argv
  HQ_SHELL_EXECUTABLE=""
  HQ_SHELL_SUDO_CHDIR=""
  [ -n "$1" ] || return 1
  # Fast path: when the first word is not an assignment or a prefix word
  # (env, command, builtin, exec, sudo), it is the executable. This skips the
  # split and the loop below for almost every record.
  token="${1%%$'\037'*}"
  case "$token" in
    *=*|env|command|builtin|exec|sudo) ;;
    *) HQ_SHELL_EXECUTABLE="$token"; return 0 ;;
  esac
  hq_shell_record_words "$1"
  argv=(${HQ_SHELL_WORDS[@]+"${HQ_SHELL_WORDS[@]}"})
  local i=0
  while [ "$i" -lt "${#argv[@]}" ]; do
    token="${argv[$i]}"
    if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      i=$((i + 1)); continue
    fi
    case "$token" in
      env)
        i=$((i + 1))
        while [ "$i" -lt "${#argv[@]}" ]; do
          token="${argv[$i]}"
          if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            i=$((i + 1)); continue
          fi
          case "$token" in
            -*) i=$((i + 1)); continue ;;
          esac
          break
        done
        continue
        ;;
      sudo)
        # Skip sudo's own options and their values, or `sudo -u nobody cp`
        # resolves to `-u` instead of `cp`.
        _hq_sudo_option_end "$((i + 1))" "${argv[@]}"
        i="$HQ_SUDO_OPTION_END"; HQ_SHELL_SUDO_CHDIR="$HQ_SUDO_CHDIR"; continue ;;
      command|builtin|exec)
        i=$((i + 1)); continue ;;
      *) HQ_SHELL_EXECUTABLE="$token"; return 0 ;;
    esac
  done
  return 1
}

# _hq_sudo_option_takes_value <short option letter or long option>
#   0 when the sudo option reads a value: -a -c -u -g -C -p -r -t -U -D -R -T
#   and their long forms (sudo's getopt string has a: c: C: D: g: p: r: R: t:
#   T: U: u:). -h is not listed: its value is optional and only attached
#   (-hhost); a bare -h is --help and does not read the next word. Callers
#   end a short-option cluster at h for that reason.
_hq_sudo_option_takes_value() {
  case "$1" in
    a|c|u|g|C|p|r|t|U|D|R|T) return 0 ;;
    --user|--group|--close-from|--host|--prompt|--role|--type|--other-user) return 0 ;;
    --chdir|--chroot|--command-timeout|--auth-type|--login-class) return 0 ;;
  esac
  return 1
}

# _hq_sudo_option_end <index> <word>...
#   <word>... is a simple command's argv and <index> the word right after
#   `sudo`. Set HQ_SUDO_OPTION_END to the index of the first word after sudo's
#   own options: combined short flags (-nE), a value attached (-uroot) or in
#   the next word (-u root, -nu root), long options (--user root,
#   --user=root, --preserve-env), and `--`, which ends them.
#   Also set HQ_SUDO_CHDIR to the directory of the last -D/--chdir (empty when
#   there is none): the command runs there, as `git -C DIR` would.
HQ_SUDO_OPTION_END=0
HQ_SUDO_CHDIR=""
# hq_shell_record_executable copies HQ_SUDO_CHDIR here for the record it
# resolved (block-hq-root-git-mutation.sh reads it as a git -C anchor).
# shellcheck disable=SC2034 # Read by guards after this sourced function returns.
HQ_SHELL_SUDO_CHDIR=""
_hq_sudo_option_end() {
  local i="$1" token cluster c n
  shift
  local -a w=("$@")
  n="${#w[@]}"
  HQ_SUDO_CHDIR=""
  while [ "$i" -lt "$n" ]; do
    token="${w[$i]}"
    case "$token" in
      --) i=$((i + 1)); break ;;
      --chdir=*) HQ_SUDO_CHDIR="${token#--chdir=}"; i=$((i + 1)) ;;
      --*=*) i=$((i + 1)) ;;
      --?*)
        i=$((i + 1))
        if _hq_sudo_option_takes_value "$token"; then
          [ "$token" != --chdir ] || HQ_SUDO_CHDIR="${w[$i]:-}"
          i=$((i + 1))
        fi
        ;;
      -?*)
        cluster="${token#-}"
        i=$((i + 1))
        while [ -n "$cluster" ]; do
          c="${cluster:0:1}"
          cluster="${cluster:1}"
          # -h: the rest of the word, if any, is its value; never the next word.
          [ "$c" != h ] || break
          if _hq_sudo_option_takes_value "$c"; then
            if [ -n "$cluster" ]; then
              [ "$c" != D ] || HQ_SUDO_CHDIR="$cluster"
            else
              [ "$c" != D ] || HQ_SUDO_CHDIR="${w[$i]:-}"
              i=$((i + 1))
            fi
            break
          fi
        done
        ;;
      *) break ;;
    esac
  done
  [ "$i" -le "$n" ] || i="$n"
  HQ_SUDO_OPTION_END="$i"
}

# _hq_sudo_options_as_assignments <command>
#   For block-core-writes-bash.sh, whose command-name lookup is frozen
#   (merged-write-guard-shadow.test.sh) and skips the word `sudo` but not its
#   options, so it took `-u` as the command in `sudo -u nobody cp ...`. Set
#   HQ_SUDO_REWRITE_RESULT to the command with each option word and option
#   value of a `sudo` in command position replaced by the assignment word
#   HQ_SUDO_OPTION=1. The guard's lookup skips NAME=value words, so it reaches
#   the real command, and every other word keeps its place. A `sudo` is in
#   command position at the start, after ; & | ( or a newline, after `$(` or a
#   backtick, or after env/command/exec/nohup/time/builtin or NAME=value in
#   command position. When an option word or value holds anything but
#   letters, digits and _ . , : / @ + = % -, the command is left as written.
#   That includes a quoted value (-u "build user", -p 'pw:'): this scan splits
#   on whitespace and does not track quotes, so the word `sudo` may sit inside
#   a string or a comment, and a quote after it may close that string. Only
#   plain words are replaced, one for one, so the quotes and operators of the
#   command are never changed.
#   A newline ends the sudo command, so an option at the end of a line never
#   takes a word of the next line as its value.
#   -D/--chdir and -R/--chroot get the same HQ_SUDO_OPTION=1 words and nothing
#   else. They change only the sudo child's directory, never the caller's, so
#   no `cd` is modelled for them: an injected `cd` changes the guard's cd
#   tracking for the rest of the command (an outside DIR turns off its
#   relative-path checks; any non-protected DIR clears a protected cwd set by
#   an earlier `cd`). A relative target after them is checked against the
#   caller's directory, as on main.
#   The command is read line by line and only a line with the word `sudo` is
#   scanned, so a long script costs no more than its sudo lines.
HQ_SUDO_REWRITE_RESULT=""
HQ_SUDO_LINE_RESULT=""

_hq_sudo_options_as_assignments() {
  local input="$1" line changed=0
  local -a hq_sudo_lines=()
  HQ_SUDO_REWRITE_RESULT="$input"
  case "$input" in *sudo*) ;; *) return 0 ;; esac
  # The here-string adds one newline, so joining the lines with newlines
  # gives the input back exactly, with or without a final newline.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *sudo*)
        # One word that cannot be replaced safely leaves the whole command
        # as written.
        _hq_sudo_line_options_as_assignments "$line" || return 0
        [ "$HQ_SUDO_LINE_RESULT" = "$line" ] || changed=1
        line="$HQ_SUDO_LINE_RESULT"
        ;;
    esac
    hq_sudo_lines+=("$line")
  done <<< "$input"
  [ "$changed" -eq 1 ] || return 0
  printf -v HQ_SUDO_REWRITE_RESULT '%s\n' "${hq_sudo_lines[@]}"
  HQ_SUDO_REWRITE_RESULT="${HQ_SUDO_REWRITE_RESULT%$'\n'}"
}

# _hq_sudo_line_options_as_assignments <one line of a command>
#   Set HQ_SUDO_LINE_RESULT to the line with the option words and option
#   values of each `sudo` in command position replaced. Return 1 when a word
#   that would be replaced holds a character outside the safe set.
_hq_sudo_line_options_as_assignments() {
  local input="$1" remaining token after_token separator consumed core
  local at_cmd=1 in_sudo=0 need_value=0 changed=0 seen_backslash=0 c cluster
  local ws=$' \t\n\r'
  local -a hq_sudo_out=()
  HQ_SUDO_LINE_RESULT="$input"
  remaining="$input"
  while [ -n "$remaining" ]; do
    token="${remaining%%[$ws]*}"
    after_token="${remaining:${#token}}"
    separator="${after_token%%[!$ws]*}"
    consumed=$((${#token} + ${#separator}))
    remaining="${remaining:$consumed}"
    if [ -z "$token" ]; then
      hq_sudo_out+=("$separator")
      case "$separator" in *$'\n'*) at_cmd=1 ;; esac
      continue
    fi
    if [ "$in_sudo" -eq 1 ]; then
      if [ "$need_value" -eq 1 ]; then
        # A quoted value is not rewritten. This scan does not track quotes,
        # so a quote here may be the end of a string that holds the word
        # `sudo`, and taking it as the start of a value would swallow the
        # real commands after that string.
        case "$token" in *[!A-Za-z0-9_.,:/@+=%-]*) return 1 ;; esac
        hq_sudo_out+=("HQ_SUDO_OPTION=1" "$separator"); changed=1; need_value=0
        case "$separator" in *$'\n'*) in_sudo=0; at_cmd=1 ;; esac
        continue
      fi
      case "$token" in
        --)
          hq_sudo_out+=("HQ_SUDO_OPTION=1" "$separator"); changed=1; in_sudo=0; at_cmd=1
          continue
          ;;
        -?*)
          case "$token" in *[!A-Za-z0-9_.,:/@+=%-]*) return 1 ;; esac
          case "$token" in
            --*=*) ;;
            --*)
              if _hq_sudo_option_takes_value "$token"; then need_value=1; fi
              ;;
            *)
              cluster="${token#-}"
              while [ -n "$cluster" ]; do
                c="${cluster:0:1}"; cluster="${cluster:1}"
                # -h: the rest of the word, if any, is its value; never the next word.
                [ "$c" != h ] || break
                if _hq_sudo_option_takes_value "$c"; then
                  [ -n "$cluster" ] || need_value=1
                  break
                fi
              done
              ;;
          esac
          hq_sudo_out+=("HQ_SUDO_OPTION=1" "$separator"); changed=1
          # An unquoted newline ends the sudo command. An option still waiting
          # for its value (`sudo -u` at the end of a line) must not take the
          # first word of the next line, which is a command of its own.
          case "$separator" in *$'\n'*) in_sudo=0; need_value=0; at_cmd=1 ;; esac
          continue
          ;;
      esac
      in_sudo=0; at_cmd=1
    fi
    hq_sudo_out+=("$token" "$separator")
    core="$token"
    while :; do
      case "$core" in
        '$('*) core="${core#\$(}" ;;
        '`'*) core="${core#\`}" ;;
        '('*) core="${core#(}" ;;
        *[\;\&\|]*) core="${core##*[;&|]}" ;;
        *) break ;;
      esac
    done
    if [ "$core" = sudo ] && { [ "$at_cmd" -eq 1 ] || [ "$core" != "$token" ]; }; then
      # A backslash may escape the `;`, `&` or `|` cut above (`x\;sudo` is one
      # plain argument in a shell), so leave the command as written.
      case "$token" in *\\*) return 1 ;; esac
      # An earlier word with a backslash may hold an escaped operator
      # (`x\;`, `\(`, `x\&`) that is a plain argument in a shell, so the
      # command position read from it cannot be trusted.
      [ "$seen_backslash" -eq 0 ] || return 1
      in_sudo=1; need_value=0
      case "$separator" in *$'\n'*) in_sudo=0; at_cmd=1 ;; esac
      continue
    fi
    case "$token" in *\\*) seen_backslash=1 ;; esac
    case "$token" in
      *';'|*'&'|*'|'|*'(') at_cmd=1 ;;
      # Reserved words start a command only where a command could start;
      # as plain arguments (`cp evil.sh then sudo ...`) they are words.
      '!'|'{'|then|do|else|elif|if|while|until) ;;
      *)
        if [ "$at_cmd" -eq 1 ] && { [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] \
          || case "$token" in env|command|exec|nohup|time|builtin) true ;; *) false ;; esac; }; then
          at_cmd=1
        else
          at_cmd=0
        fi
        ;;
    esac
    case "$separator" in *$'\n'*) at_cmd=1 ;; esac
  done
  [ "$changed" -eq 1 ] || return 0
  printf -v HQ_SUDO_LINE_RESULT "%s" "${hq_sudo_out[@]}"
}

# hq_crlf_to_lf <varname>...
#   Rewrite each named variable in place, turning every CRLF pair into LF.
#   Native Windows jq.exe writes stdout in text mode, so an LF inside a JSON
#   string comes out as CRLF. A guard that re-reads the command from the stdin
#   payload must undo that before matching, or `cd <HQ>` + newline + `git init`
#   reaches it as `cd <HQ>\r` and `init`, which match nothing, while bash runs
#   the original LF command. A CR that is not followed by LF is left alone, so
#   jq.exe's output round-trips exactly. master-hook.sh does the same collapse
#   on the HQ_HOOK_COMMAND it exports. Bash 3.2 safe.
#   ${var//$'\r\n'/$'\n'} gives the same result but grows quadratically with
#   the length (5,000 CRLF lines took over a minute on bash 3.2, and a 64 KB
#   command 24 s), so split into lines, drop one CR from each line end, and
#   rejoin. The x keeps the real tail apart from the LF the here-string adds,
#   so a trailing CR is never taken for half of a CRLF.
#   On Windows (Git Bash, MSYS, Cygwin) mapfile and read take the here-string
#   one byte per read() call, which is slow there. The substitution costs
#   about 0.06 s for 64 KB on bash 5, so Windows uses it up to 64 KB and one
#   awk process above that; neither reads the text through a builtin.
hq_crlf_to_lf() {
  local hq_crlf_name hq_crlf_value hq_crlf_line hq_crlf_out hq_crlf_n
  local -a hq_crlf_parts
  for hq_crlf_name in "$@"; do
    hq_crlf_value="${!hq_crlf_name}"
    [[ "$hq_crlf_value" == *$'\r\n'* ]] || continue
    case "${OSTYPE:-}" in
      msys* | cygwin*)
        if ((${#hq_crlf_value} <= 65536)); then
          printf -v "$hq_crlf_name" '%s' "${hq_crlf_value//$'\r\n'/$'\n'}"
        else
          hq_crlf_out="$(LC_ALL=C awk '{ sub(/\r$/, ""); print }' <<< "${hq_crlf_value}x")"
          printf -v "$hq_crlf_name" '%s' "${hq_crlf_out%x}"
        fi
        continue
        ;;
    esac
    hq_crlf_parts=()
    if ((BASH_VERSINFO[0] >= 4)); then
      mapfile -t hq_crlf_parts <<< "${hq_crlf_value}x"
    else
      hq_crlf_n=0
      while IFS= read -r hq_crlf_line; do
        hq_crlf_parts[hq_crlf_n]="$hq_crlf_line"
        hq_crlf_n=$((hq_crlf_n + 1))
      done <<< "${hq_crlf_value}x"
    fi
    printf -v hq_crlf_out '%s\n' "${hq_crlf_parts[@]%$'\r'}"
    printf -v "$hq_crlf_name" '%s' "${hq_crlf_out%x$'\n'}"
  done
}

hq_text_compact() {
  local max="${1:-240}"
  local text="$2"
  text="$(printf '%s' "$text" | tr '\r\n' '  ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')"
  if [ "${#text}" -gt "$max" ]; then
    printf '%s...' "${text:0:$((max - 3))}"
  else
    printf '%s' "$text"
  fi
}

hq_hook_safe_session_key() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '_')"
  raw="${raw#_}"
  raw="${raw%_}"
  if [ -z "$raw" ]; then
    raw="session-${PPID:-$$}"
  fi
  if [ "${#raw}" -gt 96 ]; then
    raw="${raw:0:96}"
  fi
  printf '%s' "$raw"
}

hq_hook_session_key_from_payload() {
  local payload="$1"
  local key="${HQ_HOOK_SESSION_ID:-}"
  # The shared payload reader (session_id, then Cursor's conversation_id),
  # loaded from lib/ next to this file when the caller has not sourced it.
  if [ -z "$key" ] && ! command -v session_id_from_payload >/dev/null 2>&1 \
    && [ -f "${BASH_SOURCE[0]%/*}/lib/session-id.sh" ]; then
    # shellcheck source=lib/session-id.sh
    . "${BASH_SOURCE[0]%/*}/lib/session-id.sh" 2>/dev/null || true
  fi
  if [ -z "$key" ] && command -v session_id_from_payload >/dev/null 2>&1; then
    key="$(session_id_from_payload "$payload")"
  fi
  if [ -z "$key" ]; then
    key="$(printf '%s' "$payload" | hq_json_get 'session_id')"
  fi
  if [ -z "$key" ]; then
    key="$(printf '%s' "$payload" | hq_json_get 'sessionId')"
  fi
  if [ -z "$key" ]; then
    key="$(printf '%s' "$payload" | hq_json_get 'conversation_id')"
  fi
  if [ -z "$key" ]; then
    key="$(printf '%s' "$payload" | hq_json_get 'conversationId')"
  fi
  if [ -z "$key" ]; then
    key="$(printf '%s' "$payload" | hq_json_get 'thread_id')"
  fi
  if [ -z "$key" ]; then
    key="$(printf '%s' "$payload" | hq_json_get 'threadId')"
  fi
  if [ -z "$key" ]; then
    key="$(printf '%s' "$payload" | hq_json_get 'tool_input.session_id')"
  fi
  hq_hook_safe_session_key "$key"
}

# hq_hook_state_dir <hq_root>
#   Session-scoped hook state lives under the resolved HQ root, never /tmp and
#   never keyed by $PPID — tool and hook processes do not share a parent PID in
#   every host, so a PID-keyed path silently defeats debouncing.
hq_hook_state_dir() {
  local root="$1"
  local dir="$root/workspace/orchestrator/hook-state"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s' "$dir"
}

# hq_hook_tool_failed <payload>
#   Exit 0 when the PostToolUse payload shows the tool call FAILED, 1 when it
#   succeeded or the host reported nothing either way.
#
#   Claude Code does not dispatch PostToolUse at all for a failed tool call, so
#   this matters for the Codex adapter, which forwards every call along with
#   `tool_response.exit_code`. Without it a red test run counts as a milestone
#   and every targeted rerun mints another reminder.
hq_hook_tool_failed() {
  local payload="$1"
  local key v
  for key in tool_response.exit_code tool_response.exitCode tool_response.returnCode; do
    v="$(printf '%s' "$payload" | hq_json_get "$key")"
    case "$v" in
      '') continue ;;
      0) return 1 ;;
      *[!0-9-]*) continue ;;
      *) return 0 ;;
    esac
  done
  for key in tool_response.is_error tool_response.isError tool_response.interrupted; do
    v="$(printf '%s' "$payload" | hq_json_get "$key")"
    [ "$v" = "true" ] && return 0
  done
  return 1
}

# hq_hook_within_window <state_file> <seconds>
#   Exit 0 when <state_file> holds an epoch stamp newer than <seconds> ago —
#   i.e. the caller is still inside its debounce window and should stay quiet.
#   A stamp that is not purely numeric, is oversized, or lies in the future
#   counts as expired, so a corrupt stamp can never silence a hook for good;
#   the caller fires and overwrites it.
hq_hook_within_window() {
  local file="$1"
  local window="$2"
  local raw last now
  [ -f "$file" ] || return 1
  raw="$(tr -d '[:space:]' < "$file" 2>/dev/null)"
  case "$raw" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#raw}" -le 12 ] || return 1
  last=$(( 10#$raw ))
  now="$(date +%s)"
  [ "$last" -le "$now" ] || return 1
  [ $(( now - last )) -lt "$window" ]
}

hq_hook_stamp_now() {
  date +%s > "$1" 2>/dev/null || true
}

# hq_path_is_absolute <path>
#   Unix roots are absolute everywhere; drive roots only on Windows.
hq_path_is_absolute() {
  case "$1" in
    /*) return 0 ;;
    [a-zA-Z]:/*|[a-zA-Z]:\\*) [ "${HQ_LIB_WINSEP:-0}" = 1 ]; return $? ;;
  esac
  return 1
}

# hq_canonical_path <path>
#   Normalize for hook comparisons. On MSYS/Git Bash, cygpath -m unifies
#   /tmp/... and C:/Users/.../Temp/... forms of the same directory.
hq_canonical_path() {
  local p="$1"
  p="$(hq_normpath "$p" 2>/dev/null || printf '%s' "$p")"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$p" 2>/dev/null || printf '%s' "$p"
    return 0
  fi
  printf '%s' "$p"
}

# hq_path_matches_core_yaml_exclude <hq_root> <file_path> [<core_yaml>]
#   exit 0 when file_path matches a core/core.yaml rules.exclude entry (file or
#   directory prefix). Requires yq and a readable core_yaml; otherwise exit 1.
hq_path_matches_core_yaml_exclude() {
  local hq_root="$1"
  local file_path="$2"
  local core_yaml="${3:-$hq_root/core/core.yaml}"
  local exc_path exc_abs exclude_paths

  [ -n "$hq_root" ] || return 1
  [ -n "$file_path" ] || return 1
  [ -f "$core_yaml" ] || return 1
  command -v yq >/dev/null 2>&1 || return 1

  file_path="$(hq_canonical_path "$file_path")"
  hq_root="$(hq_canonical_path "$hq_root")"

  exclude_paths="$(yq eval '.rules.exclude[]' "$core_yaml" 2>/dev/null)" || exclude_paths=""
  while IFS= read -r exc_path; do
    [ -n "$exc_path" ] || continue
    exc_abs="$(hq_normpath "${hq_root}/${exc_path%/}")"
    case "$file_path" in
      "$exc_abs"|"$exc_abs"/*) return 0 ;;
    esac
  done <<< "$exclude_paths"
  return 1
}

# --- Always-writable path masking (feedback_fff53135) ----------------------
# block-core-writes-bash.sh removes every word that names an always-writable
# path (core.yaml rules.exclude, .claude/settings.local.json,
# .claude/personal-context.md) before it parses the command. It does this
# through hq_bash_strip_core_yaml_exclude_tokens and then
# hq_strip_tokens_containing_literals. Removing a word shifts the words after
# it, so in `cp .claude/settings.backup.json .claude/settings.local.json` the
# source took the destination's place and the copy was refused.
#
# The guard itself is frozen (merged-write-guard-shadow.test.sh), so the fix
# lives in these two helpers, which only that guard calls. When every simple
# command in the text is a plain copy, move or text command (see
# _hq_writable_mask_shape_is_plain), a word whose whole path is always
# writable is replaced in place by a stand-in that the guard never treats as
# protected, so every other word keeps its slot. A word that merely contains
# such a path, or has a `..` segment, is left as written and checked like any
# other word. Any other command shape (ln, cp -s/-l/-a/-r, rsync -a, sudo, a
# heredoc, an interpreter, ...) keeps the old removal exactly, so for those
# the guard decides as it did before this change: a link planted at an
# always-writable path that points into a protected directory stays blocked.

HQ_WM_NEEDLES=()
HQ_WM_EXACT=()
HQ_WM_DIRS=()
HQ_WM_SIBLING=()
HQ_WM_TOKEN_RESULT=""
HQ_WM_ROOT=""
HQ_WM_BARE_OK=no

# _hq_writable_mask_bare_ok <command>
#   Set HQ_WM_BARE_OK=yes when a bare file name (settings.local.json, with no
#   directory) can only mean the file in .claude/: the command has no cd or
#   pushd, or every one of them goes to .claude itself. After a cd anywhere
#   else (for example .claude/hooks) a bare name is checked like any other
#   word.
_hq_writable_mask_bare_ok() {
  local i n tok arg
  local -a toks=()
  HQ_WM_BARE_OK=yes
  case "$1" in *cd*|*pushd*) ;; *) return 0 ;; esac
  read -r -d '' -a toks <<< "$1" || :
  n="${#toks[@]}"
  i=0
  while [ "$i" -lt "$n" ]; do
    tok="${toks[$i]##*[;&|(]}"
    tok="${tok//\"/}"; tok="${tok//\'/}"; tok="${tok//\\/}"
    i=$((i + 1))
    case "$tok" in cd|pushd) ;; *) continue ;; esac
    arg="${toks[$i]:-}"
    arg="${arg//\"/}"; arg="${arg//\'/}"
    while :; do case "$arg" in ./*) arg="${arg#./}" ;; *) break ;; esac; done
    arg="${arg%%[;&|)]*}"
    arg="${arg%/}"
    if [ "$arg" = ".claude" ] || { [ -n "$HQ_WM_ROOT" ] && [ "$arg" = "${HQ_WM_ROOT%/}/.claude" ]; }; then
      continue
    fi
    HQ_WM_BARE_OK=no
    return 0
  done
  return 0
}

# _hq_writable_mask_option_ok <command> <option word>
#   0 when the option cannot make the command create a link or copy one.
_hq_writable_mask_option_ok() {
  local cmd="$1" opt="$2" allowed
  case "$cmd:$opt" in
    cp:--force|cp:--interactive|cp:--no-clobber|cp:--verbose|cp:--dereference) return 0 ;;
    mv:--force|mv:--interactive|mv:--no-clobber|mv:--verbose) return 0 ;;
    rsync:--progress|rsync:--partial|rsync:--checksum|rsync:--update|rsync:--times) return 0 ;;
    rsync:--perms|rsync:--verbose|rsync:--quiet|rsync:--whole-file) return 0 ;;
    rsync:--human-readable|rsync:--itemize-changes) return 0 ;;
    mkdir:--parents|mkdir:--verbose|tee:--append) return 0 ;;
    *:--*) return 1 ;;
  esac
  case "$cmd" in
    cp) allowed=finvpL ;;
    mv) allowed=finv ;;
    rsync) allowed=vhPcuqWtpi ;;
    mkdir) allowed=pv ;;
    touch) allowed=acm ;;
    tee) allowed=ai ;;
    *) return 1 ;;
  esac
  opt="${opt#-}"
  [ -n "$opt" ] || return 1
  case "$opt" in *[!$allowed]*) return 1 ;; esac
  return 0
}

# _hq_writable_mask_shape_is_plain <command>
#   0 when every simple command (after NAME=value prefixes) is cp, mv, rsync,
#   mkdir, touch or tee with only the options above, or a command that writes
#   nothing itself (echo, printf, cat, ls, test, true, :, cd, pushd, popd).
#   Redirections are checked by the guard as usual. 1 for anything else,
#   including a lexer failure, so the caller falls back to the old removal.
_hq_writable_mask_shape_is_plain() {
  local records record cmd tok n i end_of_options
  local -a words
  records="$(hq_shell_simple_commands "$1" 2>/dev/null)" || return 1
  [ -n "$records" ] || return 1
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    hq_shell_record_words "$record"
    words=(${HQ_SHELL_WORDS[@]+"${HQ_SHELL_WORDS[@]}"})
    n="${#words[@]}"
    i=0
    while [ "$i" -lt "$n" ] && [[ "${words[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
      i=$((i + 1))
    done
    [ "$i" -lt "$n" ] || continue
    cmd="${words[$i]}"
    case "$cmd" in
      cd|pushd|popd|echo|printf|cat|ls|test|true|:|'[') continue ;;
      cp|mv|rsync|mkdir|touch|tee) ;;
      *) return 1 ;;
    esac
    end_of_options=0
    i=$((i + 1))
    while [ "$i" -lt "$n" ]; do
      tok="${words[$i]}"
      i=$((i + 1))
      [ "$end_of_options" -eq 0 ] || continue
      case "$tok" in
        --) end_of_options=1 ;;
        -) ;;
        -*) _hq_writable_mask_option_ok "$cmd" "$tok" || return 1 ;;
      esac
    done
  done <<< "$records"
  return 0
}

# _hq_writable_mask_token <token> <previous token>
#   Set HQ_WM_TOKEN_RESULT to the token with an always-writable path replaced
#   by a stand-in, or to the token unchanged. Only a whole path is masked: a
#   word in HQ_WM_EXACT, a path inside a directory in HQ_WM_DIRS, or a
#   temp/backup sibling (no slash after the suffix) of a word in
#   HQ_WM_SIBLING. A redirection operator, NAME= or --option= prefix and
#   trailing ; & | ) are kept around the stand-in. A word with a `..`
#   segment, an inner quote, an escape, an expansion or a glob is never
#   masked.
_hq_writable_mask_token() {
  local token="$1" prev="$2" prefix="" suffix="" core p entry rest hit=no standin
  local re_redir='^([0-9]*(>>|>\||>|<)|&>>|&>)(.+)$'
  local re_assign='^([A-Za-z_][A-Za-z0-9_]*=|--[A-Za-z0-9][A-Za-z0-9-]*=)(.+)$'
  local dbl='//' dot='/./'
  HQ_WM_TOKEN_RESULT="$token"
  core="$token"
  if [[ "$core" =~ $re_redir ]]; then
    prefix="${BASH_REMATCH[1]}"; core="${BASH_REMATCH[3]}"
  elif [[ "$core" =~ $re_assign ]]; then
    prefix="${BASH_REMATCH[1]}"; core="${BASH_REMATCH[2]}"
  fi
  while :; do
    case "$core" in
      *';'|*'&'|*'|'|*')') suffix="${core: -1}$suffix"; core="${core%?}" ;;
      *) break ;;
    esac
  done
  case "$core" in
    \"*\") p="${core#\"}"; p="${p%\"}"; case "$p" in *\"*) return 0 ;; esac; core="$p" ;;
    \'*\') p="${core#\'}"; p="${p%\'}"; case "$p" in *\'*) return 0 ;; esac; core="$p" ;;
  esac
  case "$core" in
    ''|'~'*|*[\"\'\\\$\`\*\?\[\]\{\}\;\&\|\<\>]*) return 0 ;;
  esac
  p="$core"
  while :; do case "$p" in *//*) p="${p//$dbl//}" ;; *) break ;; esac; done
  while :; do case "$p" in */./*) p="${p//$dot//}" ;; *) break ;; esac; done
  while :; do case "$p" in ./*) p="${p#./}" ;; *) break ;; esac; done
  case "$p" in */.) p="${p%/.}" ;; esac
  case "$p" in /) ;; */) p="${p%/}" ;; esac
  case "/$p/" in */../*) return 0 ;; esac
  [ -n "$p" ] && [ "$p" != "." ] || return 0
  for entry in ${HQ_WM_EXACT[@]+"${HQ_WM_EXACT[@]}"}; do
    case "$entry" in */*) ;; *) [ "$HQ_WM_BARE_OK" = yes ] || continue ;; esac
    [ "$p" = "$entry" ] && { hit=yes; break; }
  done
  if [ "$hit" = no ]; then
    for entry in ${HQ_WM_DIRS[@]+"${HQ_WM_DIRS[@]}"}; do
      case "$p" in "$entry"|"$entry"/*) hit=yes; break ;; esac
    done
  fi
  if [ "$hit" = no ]; then
    for entry in ${HQ_WM_SIBLING[@]+"${HQ_WM_SIBLING[@]}"}; do
      case "$entry" in */*) ;; *) [ "$HQ_WM_BARE_OK" = yes ] || continue ;; esac
      case "$p" in
        "$entry".*|"$entry"~*|"$entry"-*|"$entry"_*)
          rest="${p#"$entry"}"
          case "$rest" in */*) ;; *) hit=yes; break ;; esac
          ;;
      esac
    done
  fi
  [ "$hit" = yes ] || return 0
  # The guard reads the word after cd/pushd as the new directory. An absolute
  # stand-in there would look like a cd out of HQ, so use `.` instead.
  standin=/dev/null
  if [ -z "$prefix" ]; then
    prev="${prev##*[;&|(]}"
    prev="${prev//\"/}"; prev="${prev//\'/}"; prev="${prev//\\/}"
    case "$prev" in cd|pushd) standin=. ;; esac
  fi
  HQ_WM_TOKEN_RESULT="$prefix$standin$suffix"
}

# _hq_writable_mask_apply <command>
#   Print the command with each whitespace token that contains a needle in
#   HQ_WM_NEEDLES either masked (plain command shape) or removed (any other
#   shape, as before), preserving separators.
_hq_writable_mask_apply() {
  local input="$1" remaining token after_token separator consumed needle match mode prev=""
  local whitespace_chars=$' \t\n\r'
  local -a output_parts=()
  match=no
  for needle in ${HQ_WM_NEEDLES[@]+"${HQ_WM_NEEDLES[@]}"}; do
    [ -n "$needle" ] || continue
    case "$input" in *"$needle"*) match=yes; break ;; esac
  done
  [ "$match" = yes ] || { printf '%s' "$input"; return 0; }
  if _hq_writable_mask_shape_is_plain "$input"; then mode="mask"; else mode="strip"; fi
  [ "$mode" = strip ] || _hq_writable_mask_bare_ok "$input"
  remaining="$input"
  while [ -n "$remaining" ]; do
    token="${remaining%%[$whitespace_chars]*}"
    after_token="${remaining:${#token}}"
    separator="${after_token%%[!$whitespace_chars]*}"
    match=no
    for needle in "${HQ_WM_NEEDLES[@]}"; do
      [ -n "$needle" ] || continue
      case "$token" in *"$needle"*) match=yes; break ;; esac
    done
    if [ "$match" = no ]; then
      output_parts+=("$token")
    elif [ "$mode" = mask ]; then
      _hq_writable_mask_token "$token" "$prev"
      output_parts+=("$HQ_WM_TOKEN_RESULT")
    fi
    output_parts+=("$separator")
    [ -z "$token" ] || prev="$token"
    consumed=$((${#token} + ${#separator}))
    remaining="${remaining:$consumed}"
  done
  printf '%s' ${output_parts[@]+"${output_parts[@]}"}
}

# hq_strip_tokens_containing_literals <command> <literal>...
#   For block-core-writes-bash.sh: handle whitespace-delimited command tokens
#   that contain any literal needle, preserving separators. A needle with no
#   slash names a fixed always-writable file in .claude/ (settings.local.json,
#   personal-context.md): the bare name, .claude/<name>, the absolute form
#   under CLAUDE_PROJECT_DIR (or the working directory) and their temp/backup
#   siblings are masked when the command shape is plain (see the section
#   comment above); otherwise matching tokens are removed as before. A needle
#   with a slash is an exact path, or a directory when it ends in a slash.
#   This stays in Bash so hook hot paths do not spawn a sed process per
#   configured exclude entry.
#   block-core-writes-bash.sh parses this function's output, so it also turns
#   the options of a `sudo` into NAME=value words first (see
#   _hq_sudo_options_as_assignments) for that guard's frozen command lookup.
#   That runs before the needle check, so it applies to every command.
hq_strip_tokens_containing_literals() {
  local input="$1" needle match root
  _hq_sudo_options_as_assignments "$input"
  input="$HQ_SUDO_REWRITE_RESULT"
  shift
  HQ_WM_NEEDLES=(); HQ_WM_EXACT=(); HQ_WM_DIRS=(); HQ_WM_SIBLING=()
  match=no
  for needle in "$@"; do
    [ -n "$needle" ] || continue
    HQ_WM_NEEDLES+=("$needle")
    case "$input" in *"$needle"*) match=yes ;; esac
  done
  [ "$match" = yes ] || { printf '%s' "$input"; return 0; }
  root="${CLAUDE_PROJECT_DIR:-$PWD}"
  root="$(hq_normpath "$root" 2>/dev/null)" || root=""
  HQ_WM_ROOT="$root"
  for needle in "${HQ_WM_NEEDLES[@]}"; do
    case "$needle" in
      */) HQ_WM_DIRS+=("${needle%/}") ;;
      */*) HQ_WM_EXACT+=("$needle") ;;
      *)
        HQ_WM_EXACT+=("$needle" ".claude/$needle")
        HQ_WM_SIBLING+=("$needle" ".claude/$needle")
        if [ -n "$root" ]; then
          HQ_WM_EXACT+=("${root%/}/.claude/$needle")
          HQ_WM_SIBLING+=("${root%/}/.claude/$needle")
        fi
        ;;
    esac
  done
  _hq_writable_mask_apply "$input"
}

# hq_core_yaml_exclude_needles <hq_root> [<core_yaml>]
#   Load the literal needles that name core/core.yaml rules.exclude paths into
#   the array HQ_CORE_YAML_EXCLUDE_NEEDLES: each root-relative path, its
#   trailing-slash form for a directory, and its absolute form under hq_root.
#   The same paths, without a trailing slash, are also split into
#   HQ_CORE_YAML_EXCLUDE_FILES and HQ_CORE_YAML_EXCLUDE_DIRS (relative and
#   absolute). Empty when the file or yq is missing. Runs in the caller's
#   shell.
HQ_CORE_YAML_EXCLUDE_NEEDLES=()
HQ_CORE_YAML_EXCLUDE_FILES=()
HQ_CORE_YAML_EXCLUDE_DIRS=()
hq_core_yaml_exclude_needles() {
  local hq_root="$1"
  local core_yaml="${2:-$hq_root/core/core.yaml}"
  local exc_path rel abs exclude_paths abs_paths_text normalized_abs_paths idx
  local -a kinds=()
  HQ_CORE_YAML_EXCLUDE_NEEDLES=()
  HQ_CORE_YAML_EXCLUDE_FILES=()
  HQ_CORE_YAML_EXCLUDE_DIRS=()

  [ -f "$core_yaml" ] || return 0
  command -v yq >/dev/null 2>&1 || return 0

  hq_root="$(hq_canonical_path "$hq_root")"
  exclude_paths="$(yq eval '.rules.exclude[]' "$core_yaml" 2>/dev/null)" || exclude_paths=""
  abs_paths_text=""
  while IFS= read -r exc_path; do
    [ -n "$exc_path" ] || continue
    rel="${exc_path%/}"
    [ -n "$rel" ] || continue
    HQ_CORE_YAML_EXCLUDE_NEEDLES+=("$rel")
    if [[ "$exc_path" == */ ]]; then
      HQ_CORE_YAML_EXCLUDE_NEEDLES+=("$exc_path")
      HQ_CORE_YAML_EXCLUDE_DIRS+=("$rel")
      kinds+=(d)
    else
      HQ_CORE_YAML_EXCLUDE_FILES+=("$rel")
      kinds+=(f)
    fi
    # hq_root is already in canonical slash form. Normalize all absolute
    # exclude paths in one Bash pass below instead of launching one command
    # substitution (and, on MSYS, cygpath process) per entry.
    abs_paths_text+="${hq_root%/}/${rel}"$'\n'
  done <<< "$exclude_paths"

  [ "${#HQ_CORE_YAML_EXCLUDE_NEEDLES[@]}" -gt 0 ] || return 0
  normalized_abs_paths="$(hq_normpath "$abs_paths_text")" || normalized_abs_paths=""
  idx=0
  while IFS= read -r abs; do
    [ -n "$abs" ] || continue
    HQ_CORE_YAML_EXCLUDE_NEEDLES+=("$abs")
    case "${kinds[$idx]:-}" in
      d) HQ_CORE_YAML_EXCLUDE_DIRS+=("$abs") ;;
      f) HQ_CORE_YAML_EXCLUDE_FILES+=("$abs") ;;
    esac
    idx=$((idx + 1))
  done <<< "$normalized_abs_paths"
  return 0
}

# hq_bash_strip_core_yaml_exclude_tokens <command> <hq_root> [<core_yaml>]
#   For block-core-writes-bash.sh: handle command tokens that reference
#   rules.exclude paths or the two fixed always-writable files. Match full
#   root-relative (and absolute) paths, never basename substrings, which would
#   hide unrelated protected targets (e.g. toolkit.sh when .claude/kit/ is
#   excluded). With a plain command shape a whole always-writable path is
#   masked in place; otherwise every token containing one is removed, as
#   before (see the section comment above).
hq_bash_strip_core_yaml_exclude_tokens() {
  local cmd="$1"
  local hq_root="$2"
  local core_yaml="${3:-$hq_root/core/core.yaml}"
  local stripped fixed root

  [ -n "$cmd" ] || { printf '%s' "$cmd"; return 0; }
  [ -f "$core_yaml" ] || { printf '%s' "$cmd"; return 0; }
  command -v yq >/dev/null 2>&1 || { printf '%s' "$cmd"; return 0; }

  hq_core_yaml_exclude_needles "$hq_root" "$core_yaml"
  [ "${#HQ_CORE_YAML_EXCLUDE_NEEDLES[@]}" -gt 0 ] || { printf '%s' "$cmd"; return 0; }
  HQ_WM_NEEDLES=("${HQ_CORE_YAML_EXCLUDE_NEEDLES[@]}")
  HQ_WM_EXACT=(${HQ_CORE_YAML_EXCLUDE_FILES[@]+"${HQ_CORE_YAML_EXCLUDE_FILES[@]}"})
  HQ_WM_DIRS=(${HQ_CORE_YAML_EXCLUDE_DIRS[@]+"${HQ_CORE_YAML_EXCLUDE_DIRS[@]}"})
  HQ_WM_SIBLING=()
  # The fixed exceptions join here so that the removal fallback removes
  # exactly what the two old passes removed, and the guard's second pass
  # (hq_strip_tokens_containing_literals) then finds nothing left to remove.
  HQ_WM_NEEDLES+=(settings.local.json personal-context.md)
  case "$cmd" in
    *settings.local.json*|*personal-context.md*)
      root="$(hq_normpath "$(hq_canonical_path "$hq_root")" 2>/dev/null)" || root=""
      HQ_WM_ROOT="$root"
      for fixed in settings.local.json personal-context.md; do
        HQ_WM_EXACT+=("$fixed" ".claude/$fixed")
        HQ_WM_SIBLING+=("$fixed" ".claude/$fixed")
        if [ -n "$root" ]; then
          HQ_WM_EXACT+=("${root%/}/.claude/$fixed")
          HQ_WM_SIBLING+=("${root%/}/.claude/$fixed")
        fi
      done
      ;;
  esac
  stripped="$(_hq_writable_mask_apply "$cmd")" || stripped=""
  # Never fail open. An empty helper result would make block-core-writes-bash
  # treat the command as touching no protected paths and allow the write.
  # Hand the original command back so the caller still sees the real targets.
  if [ -z "$stripped" ]; then
    printf '%s' "$cmd"
    return 0
  fi
  printf '%s' "$stripped"
}


hq_path_within_root() {
  local root="$1"
  local path="$2"
  local root_norm path_norm
  [ -n "$root" ] || return 1
  [ -n "$path" ] || return 1
  # Never chmod through a symlink that may resolve outside HQ_ROOT.
  [ -L "$path" ] && return 1
  root_norm="$(hq_normpath "$root")"
  path_norm="$(hq_normpath "$path")"
  case "$path_norm" in
    "$root_norm"|"$root_norm"/*) return 0 ;;
  esac
  return 1
}

hq_path_label() {
  local root="$1"
  local path="$2"
  local root_norm path_norm
  [ -n "$path" ] || return 0
  root_norm="$(hq_normpath "$root")"
  path_norm="$(hq_normpath "$path")"
  case "$path_norm" in
    "$root_norm")
      printf '.'
      return 0
      ;;
    "$root_norm"/*)
      printf '%s' "${path_norm#"$root_norm"/}"
      return 0
      ;;
  esac
  case "$path" in
    */*) printf '%s' "${path##*/}" ;;
    *) printf '%s' "$path" ;;
  esac
}

# Git Bash/MSYS chmod rewrites NTFS ACLs with DENY ACEs. That can make the
# owner unable to read a file whose POSIX mode still looks like -rw-r--r--.
# Never chmod HQ files on Windows; launch with bash instead.
hq_windows_native_path() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$p" 2>/dev/null || printf '%s' "$p"
    return 0
  fi
  printf '%s' "$p"
}

hq_repair_windows_acl() {
  local path="${1:-}" native user
  [ -n "$path" ] || return 1
  [ -e "$path" ] || return 1
  [ -r "$path" ] && return 0
  [ "${HQ_LIB_WINSEP:-0}" = 1 ] || return 1
  command -v icacls >/dev/null 2>&1 || return 1
  native="$(hq_windows_native_path "$path")" || return 1
  user="${USERNAME:-${USER:-}}"
  icacls "$native" /reset >/dev/null 2>&1 || true
  if [ -n "$user" ]; then
    icacls "$native" /remove:d "$user" >/dev/null 2>&1 || true
    icacls "$native" /grant:r "${user}:(RX)" >/dev/null 2>&1 || true
  fi
  [ -r "$path" ]
}

hq_hook_repair_command() {
  local root="$1"
  local path="$2"
  local rel
  if ! hq_path_within_root "$root" "$path"; then
    return 0
  fi
  rel="$(hq_path_label "$root" "$path")"
  [ -n "$rel" ] || return 0
  if [ "${HQ_LIB_WINSEP:-0}" = 1 ]; then
    printf 'icacls "$(cygpath -w "$HQ_ROOT/%s")" /grant:r "%%USERNAME%%:(RX)"' "$rel"
    return 0
  fi
  printf 'chmod u+x "$HQ_ROOT/%s"' "$rel"
}

hq_hook_warning_cache_path() {
  local root="$1"
  local session_key="$2"
  local cache_dir
  [ -n "$root" ] || return 1
  cache_dir="$root/workspace/.hook-launch-warnings"
  mkdir -p "$cache_dir" 2>/dev/null || return 1
  printf '%s/%s.keys' "$cache_dir" "$session_key"
}

hq_hook_warning_once() {
  local root="$1"
  local session_key="$2"
  local dedupe_key="$3"
  local cache_path
  cache_path="$(hq_hook_warning_cache_path "$root" "$session_key")" || return 0
  if grep -Fqx "$dedupe_key" "$cache_path" 2>/dev/null; then
    return 1
  fi
  printf '%s\n' "$dedupe_key" >>"$cache_path" 2>/dev/null || true
  return 0
}

hq_hook_launch_warning_text() {
  local payload="$1"
  local root="$2"
  local mode="$3"
  local kind="$4"
  local label="$5"
  local path="$6"
  local cause="$7"
  local session_key rel repair dedupe_key msg

  session_key="$(hq_hook_session_key_from_payload "$payload")"
  rel="$(hq_path_label "$root" "$path")"
  repair="$(hq_hook_repair_command "$root" "$path")"
  dedupe_key="$(hq_text_compact 240 "$mode|$kind|$label|$rel|$cause")"
  if ! hq_hook_warning_once "$root" "$session_key" "$dedupe_key"; then
    return 0
  fi

  msg="WARNING: HQ ${mode} ${kind} launch failed for ${label}"
  if [ -n "$rel" ]; then
    msg="${msg} (${rel})"
  fi
  msg="${msg}: ${cause}."
  if [ -n "$repair" ]; then
    msg="${msg} Repair: ${repair}"
  fi
  printf '%s' "$(hq_text_compact 420 "$msg")"
}

HQ_HOOK_LAST_STATUS=0
HQ_HOOK_LAST_CAUSE=""

# hq_hook_repair_path <root> <path>
# The permission repair every hook launcher does before it runs a hook under
# HQ_ROOT: reset NTFS ACLs when the file is unreadable (Windows only), then
# chmod u+x when it is not executable (never on Windows, where chmod writes
# DENY ACEs). Symlinks and paths outside HQ_ROOT are left alone. Forks nothing
# when the file is already readable and executable.
hq_hook_repair_path() {
  local root="$1"
  local path="$2"
  [ -f "$path" ] || return 0
  if [ ! -r "$path" ] && hq_path_within_root "$root" "$path"; then
    hq_repair_windows_acl "$path" || true
  fi
  if [ ! -x "$path" ] && hq_path_within_root "$root" "$path" \
    && [ "${HQ_LIB_WINSEP:-0}" != 1 ]; then
    chmod u+x "$path" 2>/dev/null || true
  fi
  return 0
}

hq_launch_shell_path() {
  local root="$1"
  local path="$2"
  local payload="$3"
  shift 3

  HQ_HOOK_LAST_STATUS=0
  HQ_HOOK_LAST_CAUSE=""

  if [ ! -f "$path" ]; then
    HQ_HOOK_LAST_STATUS=127
    if hq_path_within_root "$root" "$path"; then
      HQ_HOOK_LAST_CAUSE="file is missing under HQ_ROOT"
    else
      HQ_HOOK_LAST_CAUSE="file is missing"
    fi
    return 127
  fi

  hq_hook_repair_path "$root" "$path"

  if [ -x "$path" ]; then
    printf '%s' "$payload" | "$path" "$@"
    # PIPESTATUS[1], never $?. A hook that exits before reading stdin (the
    # `[ -n "${HQ_CONDUCT_RUN_DIR:-}" ] || exit 0` guard shape) closes the read
    # end while printf is still writing, so printf dies with SIGPIPE. Under the
    # `pipefail` that every HQ dispatcher sets, $? is then 141 and a hook that
    # exited 0 is reported as having failed. Read the hook's own element.
    HQ_HOOK_LAST_STATUS=${PIPESTATUS[1]}
    return "$HQ_HOOK_LAST_STATUS"
  fi

  local bash_bin="${BASH:-}"
  if [ -z "$bash_bin" ] || [ ! -x "$bash_bin" ]; then
    bash_bin="$(command -v bash 2>/dev/null || true)"
  fi
  if [ -r "$path" ] && [ -n "$bash_bin" ]; then
    printf '%s' "$payload" | "$bash_bin" "$path" "$@"
    # Same contract as the exec path above: the hook's status, not the writer's.
    HQ_HOOK_LAST_STATUS=${PIPESTATUS[1]}
    return "$HQ_HOOK_LAST_STATUS"
  fi

  if [ ! -r "$path" ]; then
    if hq_path_within_root "$root" "$path"; then
      HQ_HOOK_LAST_CAUSE="the file is not readable (on Windows, NTFS DENY ACEs can hide it while ls still shows -rw-r--r--)"
    else
      HQ_HOOK_LAST_CAUSE="file is not executable or readable"
    fi
    HQ_HOOK_LAST_STATUS=126
    return 126
  fi

  HQ_HOOK_LAST_STATUS=127
  # shellcheck disable=SC2034 # Read by adapters after this sourced function returns.
  HQ_HOOK_LAST_CAUSE="bash is unavailable for the readable shell fallback"
  return 127
}

# hq_gate_fact_present <fact> [minutes]
#   Return 0 when the current session has a valid fact, optionally within the
#   requested freshness window. Failures write a one-line reason to stderr.
hq_gate_fact_fail() {
  printf '%s\n' "$1" >&2
  return 1
}

hq_gate_fact_present() {
  local fact="${1:-}" within="${2:-}" root lib_dir session_id state_dir file record ts epoch now age
  case "$fact" in
    sending_account_confirmed|recipients_confirmed|draft_approved|humanize_passed|enforcement_observed) ;;
    *) hq_gate_fact_fail "unknown gate fact: ${fact:-<empty>}"; return 1 ;;
  esac
  if [ -n "$within" ]; then
    case "$within" in *[!0-9]*|'') hq_gate_fact_fail 'invalid freshness window'; return 1 ;; esac
    while [ "${within#0}" != "$within" ]; do within="${within#0}"; done
    [ -n "$within" ] || within=0
    case "$within" in ????????*) hq_gate_fact_fail 'freshness window is too large'; return 1 ;; esac
  fi

  root="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-}}"
  if [ -z "$root" ]; then
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || lib_dir=""
    [ -n "$lib_dir" ] || { hq_gate_fact_fail 'cannot resolve HQ root'; return 1; }
    root="$(cd "$lib_dir/../.." 2>/dev/null && pwd)" || root=""
  fi
  [ -n "$root" ] || { hq_gate_fact_fail 'cannot resolve HQ root'; return 1; }

  if ! command -v session_id_resolve >/dev/null 2>&1; then
    [ -f "$root/core/scripts/lib/session-id.sh" ] || { hq_gate_fact_fail 'session resolver is unavailable'; return 1; }
    . "$root/core/scripts/lib/session-id.sh" || { hq_gate_fact_fail 'session resolver could not be loaded'; return 1; }
  fi
  session_id="$(session_id_resolve "$root")"
  [ -n "$session_id" ] || { hq_gate_fact_fail 'no current session id'; return 1; }
  state_dir="$(hq_hook_state_dir "$root")/gate-facts/$session_id"
  file="$state_dir/$fact.json"
  [ -f "$file" ] || { hq_gate_fact_fail "fact absent: $fact"; return 1; }
  command -v jq >/dev/null 2>&1 || { hq_gate_fact_fail 'jq is unavailable'; return 1; }
  record="$(jq -er --arg fact "$fact" 'select(.fact == $fact and (.confirmed_at | type == "string") and (.note | type == "string") and (.source == "askuserquestion" or .source == "helper" or .source == "override"))' "$file" 2>/dev/null)" || {
    hq_gate_fact_fail "fact record is invalid: $fact"
    return 1
  }
  [ -n "$record" ] || { hq_gate_fact_fail "fact record is invalid: $fact"; return 1; }
  ts="$(printf '%s' "$record" | jq -r '.confirmed_at')"
  case "$ts" in ????-??-??T??:??:??Z) ;; *) hq_gate_fact_fail "fact timestamp is invalid: $fact"; return 1 ;; esac
  epoch="$(date -u -d "$ts" +%s 2>/dev/null || true)"
  case "$epoch" in *[!0-9]*|'') epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null || true)" ;; esac
  case "$epoch" in *[!0-9]*|'') hq_gate_fact_fail "fact timestamp is invalid: $fact"; return 1 ;; esac
  if [ -z "$within" ]; then
    return 0
  fi
  now="$(date -u +%s 2>/dev/null || true)"
  case "$now" in *[!0-9]*|'') hq_gate_fact_fail 'current time is unavailable'; return 1 ;; esac
  age=$((now - epoch))
  if [ "$age" -lt 0 ] || [ "$age" -ge $((10#$within * 60)) ]; then
    hq_gate_fact_fail "fact stale: $fact"
    return 1
  fi
  return 0
}
