#!/usr/bin/env bash
# Regression: `printf '%s' "$VAR" | grep -q PATTERN` under `set -o pipefail`
# is nondeterministic. grep -q exits on the first match; if printf is still
# writing it gets SIGPIPE (status 141) and pipefail fails the pipeline even
# though the pattern matched. This flaked the grouped linux-checks jobs
# (deploy-summary-gating.test.sh line 198: "printf: write error: Broken pipe",
# run 39687987449 attempt 1). Use `grep >/dev/null PATTERN` (reads all input)
# instead.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok - $*"; }

echo "[1] the old idiom reproduces the flake; the replacement does not"
big="MATCH"$'\n'"$(head -c 4000000 /dev/zero | tr '\0' 'x')"
old_fail=0 new_fail=0
for _ in 1 2 3 4 5; do
  printf '%s' "$big" 2>/dev/null | grep -q '^MATCH$' || old_fail=$((old_fail + 1))
  printf '%s' "$big" | grep >/dev/null '^MATCH$' || new_fail=$((new_fail + 1))
done
[ "$old_fail" -gt 0 ] || fail "expected printf | grep -q to hit SIGPIPE under pipefail at least once"
[ "$new_fail" -eq 0 ] || fail "grep >/dev/null failed $new_fail/5 times"
pass "printf | grep -q failed $old_fail/5 under pipefail; grep >/dev/null 0/5"

echo "[2] no pipefail test pipes printf/echo of a variable into grep -q"
hits="$(cd "$ROOT" && grep -nE "(printf +('%s(\\\\n)?'|\"%s(\\\\n)?\")|echo( +-[neE]+)?) +\"\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?\" *\\| *grep +-[A-Za-z]*q" \
  $(grep -l pipefail core/scripts/tests/*.sh) | grep -vE '^[^:]+:[0-9]+: *#' \
  | grep -vE '^core/scripts/tests/hq-agent-session-authz\.test\.sh:[0-9]+:.*# pipefail-grep-q: intentional hazard demo$' || true)"
[ -z "$hits" ] || fail "SIGPIPE-prone printf|grep -q under pipefail (use grep >/dev/null):
$hits"
# The exemption must stay narrow: exactly one marked line, in that one file.
marked="$(cd "$ROOT" && grep -rlF '# pipefail-grep-q: intentional hazard demo' core/scripts/tests | grep -v test-pipefail-grep-q.test.sh || true)"
[ "$marked" = "core/scripts/tests/hq-agent-session-authz.test.sh" ] || fail "exemption marker found outside hq-agent-session-authz.test.sh: $marked"
[ "$(cd "$ROOT" && grep -cF '# pipefail-grep-q: intentional hazard demo' core/scripts/tests/hq-agent-session-authz.test.sh)" = 1 ] || fail "exemption marker must appear on exactly one line"
pass "no printf/echo \"\$VAR\" | grep -q in pipefail tests"
echo "test-pipefail-grep-q: passed"
