#!/usr/bin/env bash
# Repo-wide guard: every shipped shell file that runs perl must run it under
# LC_ALL=C.
#
# Why: Apple's system Perl 5.34 exits 9 with
#   panic: locale.c: 4486: Could not change LC_CTYPE locale to C.utf8
# when it inherits LC_ALL or LANG set to C.utf8 (not installed on macOS; the
# installed name is C.UTF-8). A perl call that has not pinned the locale then
# fails, and at the PreToolUse shim that turns into exit 2 on every hook.
# handoff-open-steps.sh (PR #1769) and the call sites fixed with this guard run perl as `LC_ALL=C perl ...`.
#
# What counts as a perl call: a command-position `perl` (or "$perl_bin"-style
# variable) followed by an option or quoted argument. `command -v perl`,
# comments, regex alternations such as `ruby|perl|php`, and strings such as
# "perl -e" are not calls. The call is compliant when LC_ALL=C appears in the
# prefix assignments / env words in front of perl, on the same line.
#
# Exempt: test scripts (tests/ directories and *.test.sh). They are harnesses
# run by developers and CI, not scripts a user's session executes, and several
# only stub perl. If a test needs perl under a bad locale it sets its own env.
# A perl call that execs or forks a child is not enough with the plain prefix: it
# also leaks LC_ALL=C to that child. Those calls go through hq_perl_spawn in
# core/scripts/lib/perl-child-locale.sh, checked by perl-child-locale.test.sh.
#
# Usage: bash core/scripts/tests/perl-locale-guard.test.sh   (cwd inside the repo)

set -u

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# command-position boundary, optional env words and VAR=value assignments, then
# perl (or a perl variable) followed by an option, quote, or variable argument.
BOUNDARY='(^|^[[:space:]]*(if|elif|while|until)[[:space:]]|[;&|(!`{]|\$\(|[[:space:]](then|else|do|--|if|elif|while|until|!)[[:space:]])[[:space:]]*'
PREFIX='(env[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
PERLWORD='("?\$\{?(perl|perl_bin|PERL)\}?"?|perl)'
INVOKE="${BOUNDARY}${PREFIX}${PERLWORD}"'[[:space:]]+[-"'"'"'$]'
PINNED='(^|[^A-Za-z0-9_])LC_ALL=C[[:space:]]'

# unpinned_perl_calls <line>: prints each perl call on the line that lacks
# LC_ALL=C, returns 0 when there is at least one.
unpinned_perl_calls() {
  local rest="$1" m found=1
  # whole-line comments carry no calls
  case "$rest" in [[:space:]]*'#'*|'#'*) return 1 ;; esac
  while [[ $rest =~ $INVOKE ]]; do
    m="${BASH_REMATCH[0]}"
    if ! [[ "$m " =~ $PINNED ]]; then
      printf '%s\n' "$m"
      found=0
    fi
    rest="${rest#*"$m"}"
  done
  return $found
}

echo "== detector self-test"
expect_flag() {
  if unpinned_perl_calls "$2" >/dev/null; then pass "flags: $1"; else fail "flags: $1" "$2"; fi
}
expect_clean() {
  if unpinned_perl_calls "$2" >/dev/null; then fail "clean: $1" "$2"; else pass "clean: $1"; fi
}
expect_flag  "bare perl -e"                 "  perl -e 'alarm shift; exec @ARGV' \"\$s\" \"\$@\""
expect_flag  "command substitution"         "now=\"\$(perl -MTime::HiRes=time -e 'print 1' 2>/dev/null || true)\""
expect_flag  "pipeline"                     "  g cat-file commit \"\$c\" | perl -e '"
expect_flag  "array command"                "cmd=(perl -e \"\$prog\" \"\$@\")"
expect_flag  "set -- form"                  "  set -- perl -e 'alarm shift' \"\$T\" bash x"
expect_flag  "negated probe"                "  || ! perl -MJSON::PP -MIO::Socket::UNIX -e 1 >/dev/null 2>&1; then"
expect_flag  "if condition"                 "if perl -e 'exit 0'; then"
expect_flag  "perl variable"                "  \"\$perl_bin\" -e '"
expect_flag  "other assignments only"       "x=\$(printf '%s' \"\$p\" | A=1 B=2 perl -e 'print')"
expect_flag  "second call unpinned"         "LC_ALL=C perl -e 1 && perl -e 2"
expect_clean "pinned prefix"                "  LC_ALL=C perl -e 'alarm shift; exec @ARGV' \"\$s\""
expect_clean "pinned with other vars"       "out=\$(printf x | A=1 LC_ALL=C B=2 perl -e 'print')"
expect_clean "pinned via env"               "cmd=(env LC_ALL=C perl -e \"\$prog\")"
expect_clean "pinned in command substitution" "now=\"\$(LC_ALL=C perl -MTime::HiRes=time -e 'print 1' 2>/dev/null)\""
expect_clean "pinned in function body"     "now_ms() { LC_ALL=C perl -e 'print 1'; }"
expect_flag  "unpinned in function body"   "now_ms() { perl -e 'print 1'; }"
expect_flag  "unpinned negated in if"      "  if ! perl -pi -e 's/x//' \"\$f\"; then"
expect_clean "pinned perl variable"         "  LC_ALL=C \"\$perl_bin\" -e '"
expect_clean "command -v perl"              "if command -v perl >/dev/null 2>&1; then"
expect_clean "comment"                      "# perl -e 'print 1' is the fallback"
expect_clean "indented comment"             "    # perl -e 'print 1'"
expect_clean "regex alternation"            "re='(^|[[:space:]])(python|node|ruby|perl)([[:space:]]|\$)'"
expect_clean "quoted string"                "\"python -c\"|\"node -e\"|\"ruby -e\"|\"perl -e\") return 0 ;;"
expect_clean "prose"                        "echo \"perl is required\""

echo "== repo scan"
CANDIDATES="$(mktemp "${TMPDIR:-/tmp}/perl-locale-guard.XXXXXX")"
trap 'rm -f "$CANDIDATES"' EXIT
git grep -n -I perl -- '*.sh' '*.bash' \
  ':(exclude,glob)**/tests/**' ':(exclude,glob)**/test/**' ':(exclude,glob)**/*.test.sh' >"$CANDIDATES" 2>/dev/null

SCANNED=0
BAD=0
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  file="${hit%%:*}"
  rest="${hit#*:}"
  lineno="${rest%%:*}"
  text="${rest#*:}"
  SCANNED=$((SCANNED + 1))
  if unpinned_perl_calls "$text" >/dev/null; then
    BAD=$((BAD + 1))
    fail "perl without LC_ALL=C: $file:$lineno" "$(printf '%s' "$text" | cut -c1-160)"
  fi
done <"$CANDIDATES"

[ "$SCANNED" -gt 20 ] && pass "scanned $SCANNED shell lines mentioning perl" \
  || fail "scan found too few perl lines ($SCANNED); the file list is broken"
[ "$BAD" -eq 0 ] && pass "every shipped perl call runs under LC_ALL=C"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
