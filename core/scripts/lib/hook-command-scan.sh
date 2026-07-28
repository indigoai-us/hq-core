#!/usr/bin/env bash
# hook-command-scan.sh — quote-aware analysis of Claude Code hook command strings.
#
# Sourced by:
#   core/scripts/check-hq-hooks.sh              (diagnoses whatever is installed)
#   core/scripts/tests/hook-path-resolution.test.sh  (holds the shipped settings
#                                                     file to its canonical shape)
#
# One implementation so the checker and the test can never disagree about what
# "quoted" means or about which path a hook command actually runs.
#
# Why this exists: Claude Code executes each hook command with /bin/sh. An
# unquoted $CLAUDE_PROJECT_DIR is word-split, so on an install root containing a
# space the shell execs a truncated path and every hook dies non-blocking and
# invisibly. Quoting is the fix; these helpers are the guard.
#
# Transport: commands move between functions JSON-encoded, one per line. A hook
# command may legally contain a newline, so one-record-per-line only holds for
# the encoded form. Use hook_scan_commands_json (from a settings file) or
# hook_scan_encode (from raw single-line strings) to produce that form.
#
# Requires: jq, awk.

# Read a settings file, emit every hook command JSON-encoded, one per line.
hook_scan_commands_json() {
  jq -r '
    ..
    | objects
    | select(.type? == "command")
    | select(.command? | type == "string")
    | .command
    | @json
  ' "$1"
}

# Encode raw commands (one per line on stdin) into the same transport form.
hook_scan_encode() {
  jq -R .
}

# stdin: encoded commands. stdout: one line per command that expands
# $CLAUDE_PROJECT_DIR outside quotes (newlines flattened so the count of output
# lines is the count of offending COMMANDS, not of source lines).
hook_scan_unquoted_commands() {
  _hook_scan_awk unquoted
}

# stdin: encoded commands. stdout: every path the command builds from
# $CLAUDE_PROJECT_DIR, relative to the root, one per line. Spaces inside a
# quoted path segment are preserved.
hook_scan_relpaths() {
  _hook_scan_awk relpaths
}

# stdin: encoded commands. stdout: only the relative paths the command actually
# EXECUTES — the interpreter argument of its first simple command, plus the
# delegate script when that entrypoint is hook-gate.sh. Conditional guards
# (`[ -f "$CLAUDE_PROJECT_DIR/personal/opt.sh" ] && …`), data arguments and
# runtime-created paths are deliberately excluded: a missing optional file is
# not a broken install.
hook_scan_required_relpaths() {
  _hook_scan_awk required
}

_hook_scan_awk() {
  awk -v MODE="$1" '
function json_unescape(s,   out, i, n, c, d) {
  out = ""; n = length(s); i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == BS && i < n) {
      i = i + 1
      d = substr(s, i, 1)
      if (d == "n") out = out "\n"
      else if (d == "t") out = out "\t"
      else if (d == "r") out = out "\r"
      else if (d == "b") out = out sprintf("%c", 8)
      else if (d == "f") out = out sprintf("%c", 12)
      else if (d == "u") { out = out "?"; i = i + 4 }
      else out = out d
    } else {
      out = out c
    }
    i = i + 1
  }
  return out
}

# Length of a CLAUDE_PROJECT_DIR expansion starting at i, or 0.
function var_expansion_len(s, i,   nxt) {
  if (substr(s, i, 19) == "$CLAUDE_PROJECT_DIR") {
    nxt = substr(s, i + 19, 1)
    if (nxt == "" || nxt !~ /[A-Za-z0-9_]/) return 19
    return 0
  }
  if (substr(s, i, 21) == "${CLAUDE_PROJECT_DIR}") return 21
  return 0
}

function end_token() {
  if (INTOK) {
    NALL = NALL + 1
    ALL[NALL] = TOK
    if (!FIRSTDONE) { NFIRST = NFIRST + 1; FIRST[NFIRST] = TOK }
  }
  TOK = ""; INTOK = 0
}

# Split a command the way /bin/sh would: track single- and double-quote state,
# honour backslash escapes, replace each CLAUDE_PROJECT_DIR expansion with a
# sentinel, and flag the command when an expansion sits outside double quotes
# (that is the one form the shell word-splits).
function tokenize(cmd,   i, n, c, d, ins, ind, vl) {
  NALL = 0; NFIRST = 0; FIRSTDONE = 0; UNSAFE = 0
  TOK = ""; INTOK = 0; ins = 0; ind = 0
  n = length(cmd); i = 1
  while (i <= n) {
    c = substr(cmd, i, 1)
    if (ins) {
      if (c == SQ) ins = 0; else TOK = TOK c
      INTOK = 1; i = i + 1; continue
    }
    if (c == BS) {
      d = substr(cmd, i + 1, 1)
      if (d == "") { TOK = TOK c; INTOK = 1; i = i + 1; continue }
      if (ind && d != DQ && d != BS && d != "$" && d != "`") {
        TOK = TOK c; INTOK = 1; i = i + 1; continue
      }
      TOK = TOK d; INTOK = 1; i = i + 2; continue
    }
    if (c == DQ) { ind = 1 - ind; INTOK = 1; i = i + 1; continue }
    if (!ind && c == SQ) { ins = 1; INTOK = 1; i = i + 1; continue }
    vl = var_expansion_len(cmd, i)
    if (vl > 0) {
      if (!ind) UNSAFE = 1
      TOK = TOK SENT; INTOK = 1; i = i + vl; continue
    }
    if (!ind) {
      if (c == " " || c == "\t") { end_token(); i = i + 1; continue }
      if (c == "\n" || c == ";" || c == "&" || c == "|" || c == "(" || c == ")") {
        end_token(); FIRSTDONE = 1; i = i + 1; continue
      }
    }
    TOK = TOK c; INTOK = 1; i = i + 1
  }
  end_token()
}

# Path a token builds from the expansion: text between the sentinel and either
# the next sentinel or the end of the token. Quoting already collapsed, so a
# space inside the path survives.
function relpath_of(t,   p, q, r) {
  p = index(t, SENT)
  if (p == 0) return ""
  q = substr(t, p + 1)
  r = index(q, SENT)
  if (r > 0) q = substr(q, 1, r - 1)
  if (substr(q, 1, 1) != "/") return ""
  return substr(q, 2)
}

# Every path a single token builds. One token can name two — a colon-joined
# list such as "--pair=$CLAUDE_PROJECT_DIR/a:$CLAUDE_PROJECT_DIR/b" is the form
# that does it, so a segment ends at the next colon as well as at the next
# expansion. A path this never prints is a path the caller never checks.
function emit_relpaths_of(t,   p, rest, r, seg, colon) {
  rest = t
  while (1) {
    p = index(rest, SENT)
    if (p == 0) return
    rest = substr(rest, p + 1)
    r = index(rest, SENT)
    seg = (r > 0) ? substr(rest, 1, r - 1) : rest
    colon = index(seg, ":")
    if (colon > 0) seg = substr(seg, 1, colon - 1)
    if (substr(seg, 1, 1) == "/") print substr(seg, 2)
    if (r == 0) return
    rest = substr(rest, r)
  }
}

function base_name(p,   i) {
  for (i = length(p); i >= 1; i--) if (substr(p, i, 1) == "/") return substr(p, i + 1)
  return p
}

function emit_required(   k, b, rp, j, rp2) {
  k = 1
  while (k <= NFIRST && FIRST[k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) k = k + 1
  if (k > NFIRST) return
  b = base_name(FIRST[k])
  if (b == "bash" || b == "sh" || b == "zsh" || b == "dash" || b == "ksh") {
    k = k + 1
    while (k <= NFIRST && substr(FIRST[k], 1, 1) == "-") {
      # -c means the script is inline, not a file we can check.
      if (FIRST[k] ~ /^-[A-Za-z]*c/) return
      k = k + 1
    }
  }
  if (k > NFIRST) return
  rp = relpath_of(FIRST[k])
  if (rp == "") return
  print rp
  # hook-gate.sh runs the script named in its second argument.
  if (base_name(rp) == "hook-gate.sh") {
    for (j = k + 1; j <= NFIRST; j++) {
      rp2 = relpath_of(FIRST[j])
      if (rp2 != "") { print rp2; return }
    }
  }
}

BEGIN {
  SENT = sprintf("%c", 1)
  SQ   = sprintf("%c", 39)
  DQ   = sprintf("%c", 34)
  BS   = sprintf("%c", 92)
}

{
  line = $0
  if (substr(line, 1, 1) == DQ) line = substr(line, 2, length(line) - 2)
  cmd = json_unescape(line)
  if (cmd == "") next
  tokenize(cmd)
  if (MODE == "unquoted") {
    if (UNSAFE) { flat = cmd; gsub(/[\n\t]/, " ", flat); print flat }
  } else if (MODE == "relpaths") {
    for (idx = 1; idx <= NALL; idx++) emit_relpaths_of(ALL[idx])
  } else if (MODE == "required") {
    emit_required()
  }
}
'
}
