#!/usr/bin/env bash
# hq-core: public
# lint-awk-path-escapes.test.sh
#
# awk processes backslash escapes in -v assignments and in string literals of
# its program text. A filesystem path handed over either way loses its
# separators on Windows (C:\Users\... becomes C:Users..., with gawk warning
# "escape sequence '\U' treated as plain 'U'"), so reads miss and redirects
# fail. The policy injector lost its cache and its SessionStart reminder this
# way. Hooks must pass paths through ENVIRON["NAME"] or a shell-side redirect.
#
# This lint scans every shell hook under .claude/hooks and core/hooks and
# fails on:
#   - awk -v NAME="$VAR" where NAME or VAR names a path (ROOT, DIR, FILE,
#     PATH, TMP, LEDGER, STATUS, ...),
#   - a shell expansion spliced into single-quoted program text
#     ('...'"$X"'...'),
#   - a double-quoted awk program that expands a variable.
# A program held whole in a variable (awk "$PROG") is not flagged.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); printf '  ok %s\n' "$1"; }

command -v perl >/dev/null 2>&1 || fail "perl required"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lint-awk-path.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

SCANNER="$TMP/scan.pl"
cat >"$SCANNER" <<'PERL'
use strict; use warnings;
my $PATHVAR = qr/(?:^|_)(?:ROOT|DIR|FILE|PATH|TMP|TEMP|LEDGER|STATUS|META|JOURNAL|HOME|PWD|CWD|REPO|LOCK|SOCK)$/i;
my $ID = qr/[A-Za-z_][A-Za-z0-9_]*/;
for my $f (@ARGV) {
  open my $fh, '<', $f or next;
  local $/; my $s = <$fh>; close $fh;
  my $lineof = sub { my $p = shift; (substr($s, 0, $p) =~ tr/\n//) + 1 };
  while ($s =~ /(?:^|[\s;|&(`])(?:LC_ALL=C\s+)?g?awk(?=\s)/mg) {
    my $at = pos($s);
    my $ln = $lineof->($at);
    my $bol = rindex($s, "\n", $at - 1) + 1;
    next if substr($s, $bol, $at - $bol) =~ /^\s*#/;
    # Option head, up to the program text. -f means no inline program.
    my $p = $at; my $len = length $s; my $head = '';
    while ($p < $len) {
      my $c = substr($s, $p, 1);
      if ($c eq "\\" && substr($s, $p + 1, 1) eq "\n") { $p += 2; $head .= ' '; next; }
      last if $c eq "\n" || $c eq ';' || $c eq '|';
      if ($c eq '-' && substr($s, $p) =~ /\A(-[vF]\s*(?:$ID=)?(?:"(?:[^"\\]|\\.)*"|'[^']*'|\S+))/) {
        $head .= $1; $p += length $1; next;
      }
      if ($c eq '-' && substr($s, $p) =~ /\A-f\s*\S+/) { $p = -1; last; }
      last if $c eq "'" || $c eq '"';
      $head .= $c; $p++;
    }
    while ($head =~ /-v\s*($ID)=("?)\$\{?($ID)/g) {
      my ($name, $var) = ($1, $3);
      print "$f:$ln: awk -v $name=\$$var passes a path through -v\n"
        if $var =~ $PATHVAR || $name =~ $PATHVAR;
    }
    next if $p < 0 || $p >= $len;
    my $q = substr($s, $p, 1);
    if ($q eq '"') {
      my $rest = substr($s, $p);
      next if $rest =~ /\A"\$\{?$ID\}?"/;
      if ($rest =~ /\A"((?:[^"\\]|\\.)*)"/s && $1 =~ /\$\{?($ID)/) {
        print "$f:$ln: double-quoted awk program expands \$$1\n";
      }
      next;
    }
    next unless $q eq "'";
    my $e = index($s, "'", $p + 1);
    next if $e < 0;
    while (substr($s, $e + 1) =~ /\A("?\$\{?($ID)\}?"?)'/) {
      print "$f:$ln: awk program text splices \$$2\n";
      my $n = index($s, "'", $e + 1 + length($1) + 1);
      last if $n < 0;
      $e = $n;
    }
  }
}
PERL

# 1. Detector self-test: every unsafe spelling is caught, safe ones are not.
cat >"$TMP/bad.sh" <<'EOF'
#!/usr/bin/env bash
awk -v f="$CACHE_TMP" 'BEGIN { print 1 > f }'
awk 'BEGIN { print 1 > "'"$HQ_ROOT"'/x" }'
awk "BEGIN { print \"$HQ_ROOT\" }"
awk 'BEGIN { x = 1 }
  { print > "'$OUT_DIR'/f" }' file
LC_ALL=C awk -F '\t' -v now="$now" \
  -v ledger="$LEDGER_FILE" '{ print }'
EOF
cat >"$TMP/good.sh" <<'EOF'
#!/usr/bin/env bash
# awk -v f="$IGNORED_FILE" 'a comment is not code'
awk "$PROG" f
awk -v n="$COUNT" -v sep="$TRIM_SEPARATOR" '{ print }'
HQ_AWK_CACHE_TMP="$CACHE_TMP" awk 'BEGIN { f = ENVIRON["HQ_AWK_CACHE_TMP"]; print 1 > f }'
awk -f "$LIB_FILE" input
awk '{ print }' "$INPUT_FILE" > "$OUT_FILE"
EOF
bad_hits="$(perl "$SCANNER" "$TMP/bad.sh" | wc -l | tr -d ' ')"
[ "$bad_hits" -eq 5 ] \
  || fail "detector found $bad_hits of 5 unsafe awk path handoffs: $(perl "$SCANNER" "$TMP/bad.sh")"
ok "detector flags -v paths, spliced program text, and double-quoted programs"
good_hits="$(perl "$SCANNER" "$TMP/good.sh")"
[ -z "$good_hits" ] || fail "detector false positives: $good_hits"
ok "detector ignores ENVIRON handoffs, -f, operands, and program variables"

# 2. The live hook tree is clean.
hooks=()
while IFS= read -r -d '' f; do hooks+=("$f"); done < <(
  find "$ROOT/.claude/hooks" "$ROOT/core/hooks" -type f -name '*.sh' -print0 2>/dev/null
)
[ "${#hooks[@]}" -gt 0 ] || fail "no hook scripts found under $ROOT"
findings="$(perl "$SCANNER" "${hooks[@]}")"
if [ -n "$findings" ]; then
  printf '%s\n' "$findings" | sed "s|$ROOT/||" >&2
  fail "hooks hand filesystem paths to awk where backslash escapes apply; pass them through ENVIRON"
fi
ok "no hook hands a path to awk through -v or program text (${#hooks[@]} files)"

echo "PASS ($pass checks) lint-awk-path-escapes"
