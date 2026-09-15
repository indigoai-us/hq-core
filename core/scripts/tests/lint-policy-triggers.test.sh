#!/usr/bin/env bash
# Regression: the policy linter must stream a corpus larger than ARG_MAX and
# must not report a failed parser pass as a clean zero-policy scan.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
LINT="$ROOT/core/scripts/lint-policy-triggers.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

POLICIES="$TMP/policies"
mkdir -p "$POLICIES"

# 1,800 records match the production corpus size. The valid trigger carried by
# 1,799 of them makes the old `awk -v tsv="$FACTS_TSV"` handoff exceed the
# normal Linux argument limit, while the final record proves malformed results
# still reach the caller.
printf -v padding '%*s' 2048 ''
padding="${padding// /x}"
long_trigger="signal_${padding}"

for i in $(seq 1 1800); do
  when="$long_trigger"
  [ "$i" -eq 1800 ] && when='merge || pull request'
  printf -- '---\nid: policy-%s\nwhen: %s\non: [PreToolUse]\nenforcement: soft\n---\n\n## Rule\n\nSynthetic policy.\n' \
    "$i" "$when" > "$POLICIES/policy-$i.md"
done

stdout="$TMP/linter.stdout"
stderr="$TMP/linter.stderr"
rc=0
HQ_ROOT="$TMP" bash "$LINT" "$POLICIES" > "$stdout" 2> "$stderr" || rc=$?

[ "$rc" -eq 1 ] || fail "malformed corpus must exit 1 (got $rc)"
grep -q 'MALFORMED.*policy-1800' "$stdout" \
  || fail "malformed policy was not reported: $(tail -20 "$stdout")"
grep -q 'policies scanned: 1800 | malformed when: 1' "$stdout" \
  || fail "unexpected scan summary: $(tail -20 "$stdout")"
[ ! -s "$stderr" ] || fail "linter emitted stderr at corpus scale: $(cat "$stderr")"
! grep -qi 'argument list too long' "$stdout" \
  || fail "linter hit the argument limit: $(tail -20 "$stdout")"

# With no HQ_ROOT and no directory arguments, the linter must resolve the
# repository root (not the core/ directory containing its own script).
DEFAULT_ROOT="$TMP/default-root"
mkdir -p "$DEFAULT_ROOT/core/scripts" "$DEFAULT_ROOT/core/policies"
cp "$LINT" "$DEFAULT_ROOT/core/scripts/lint-policy-triggers.sh"
cp "$ROOT/core/scripts/eval-trigger.sh" "$DEFAULT_ROOT/core/scripts/eval-trigger.sh"
printf -- '---\nid: default-root\nwhen: deploy\non: [PreToolUse]\nenforcement: soft\n---\n\n## Rule\n\nDefault root.\n' \
  > "$DEFAULT_ROOT/core/policies/default-root.md"
default_stdout="$TMP/default-root.stdout"
default_stderr="$TMP/default-root.stderr"
default_rc=0
bash "$DEFAULT_ROOT/core/scripts/lint-policy-triggers.sh" --quiet \
  > "$default_stdout" 2> "$default_stderr" || default_rc=$?

[ "$default_rc" -eq 0 ] || fail "no-argument scan must succeed (got $default_rc)"
grep -q '^policies scanned: 1 ' "$default_stdout" \
  || fail "no-argument scan did not find core/policies: $(cat "$default_stdout")"
[ ! -s "$default_stderr" ] \
  || fail "no-argument scan emitted stderr: $(cat "$default_stderr")"

# A failed parser subprocess must fail the linter without a clean-looking
# summary. This guards the second half of the incident independently of scale.
mkdir -p "$TMP/fail-bin"
printf '#!/bin/sh\nexit 91\n' > "$TMP/fail-bin/awk"
chmod +x "$TMP/fail-bin/awk"
failed_stdout="$TMP/failed-parser.stdout"
failed_stderr="$TMP/failed-parser.stderr"
failed_rc=0
PATH="$TMP/fail-bin:$PATH" HQ_ROOT="$TMP" bash "$LINT" "$POLICIES" \
  > "$failed_stdout" 2> "$failed_stderr" || failed_rc=$?

[ "$failed_rc" -ne 0 ] || fail "parser failure must exit non-zero"
! grep -q '^policies scanned:' "$failed_stdout" \
  || fail "parser failure printed a clean-looking summary: $(cat "$failed_stdout")"
grep -q 'failed to extract policy facts' "$failed_stderr" \
  || fail "parser failure was not reported clearly: $(cat "$failed_stderr")"

echo 'PASS: lint-policy-triggers streams an ARG_MAX-scale corpus and fails closed'
