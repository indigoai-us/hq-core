#!/usr/bin/env bash
# inject-policy-utf8-locale.test.sh
#
# Regression for feedback_ed476a84-8321-49f0-b201-aaf8d20997ca: under a UTF-8
# locale the policy evaluator awk lost every policy when a rule summary was cut
# at the 160-byte ceiling through a multibyte character (BSD awk aborted with
# "towc: multibyte conversion failure").
#
# Checks, with LANG and LC_ALL set to a UTF-8 locale:
#   1. both fixture policies load and awk reports no multibyte failure;
#   2. the summary cut drops the split character whole: the kept prefix is the
#      155 ASCII bytes followed directly by "...", and the evaluator's own
#      output is valid UTF-8 even when the iconv repair step is a no-op.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
PASS=0
FAIL=0
ok() { echo "  ok $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null || { echo "jq required"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

UTF8_LOCALE=""
for candidate in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
  if locale -a 2>/dev/null | grep -qx "$candidate"; then
    UTF8_LOCALE="$candidate"
    break
  fi
done
if [ -z "$UTF8_LOCALE" ]; then
  # macOS lists en_US.UTF-8 under that exact name; Linux images may only
  # carry C.UTF-8 under a spelling locale -a normalises.
  UTF8_LOCALE="en_US.UTF-8"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/inject-utf8.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/bin-noiconv" "$tmp/root/core/policies" \
  "$tmp/root/workspace/orchestrator/policy-trigger-state"

# Stand-in for `hq core derive-trigger-facts`, as in the other policy tests.
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "${1:-}" = "--version" ]; then echo "hq 5.342.5"; exit 0; fi' \
  'cat >/dev/null; echo "always"' > "$tmp/bin/hq"
chmod +x "$tmp/bin/hq"
cp "$tmp/bin/hq" "$tmp/bin-noiconv/hq"
# A pass-through iconv exposes the evaluator's raw bytes.
printf '%s\n' '#!/usr/bin/env bash' 'exec cat' > "$tmp/bin-noiconv/iconv"
chmod +x "$tmp/bin-noiconv/iconv"

pad="$(printf 'a%.0s' $(seq 1 155))"
# 155 ASCII bytes, then an em dash spanning bytes 156-158, then more text, so
# the byte cut at 157 lands inside the em dash.
emdash=$'\xe2\x80\x94'
long_rule="${pad}${emdash} tail text that pushes the line past 160 bytes."
write_policy() {
  printf -- '---\nid: %s\nwhen: always\non: UserPromptSubmit\nenforcement: hard\n---\n\n## Rule\n\n%s\n' \
    "$1" "$2" > "$tmp/root/core/policies/$1.md"
}
write_policy aaa-emdash "$long_rule"
write_policy zzz-plain "Plain rule that should always load."

run_hook() {
  local label="$1" bindir="$2" emit="${3:-}"
  rm -rf "$tmp/root/workspace/orchestrator/hook-state"
  jq -cn --arg sid "utf8-$label-$$" \
    '{session_id:$sid,hook_event_name:"UserPromptSubmit",prompt:"hello world",cwd:"/tmp"}' \
    | env PATH="$bindir:$PATH" HQ_ROOT="$tmp/root" CLAUDE_PROJECT_DIR="$tmp/root" \
        LANG="$UTF8_LOCALE" LC_ALL="$UTF8_LOCALE" HQ_POLICY_EMIT="$emit" \
        bash "$HOOK" > "$tmp/out-$label" 2> "$tmp/err-$label" || true
}

valid_utf8() {
  python3 -I -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' < "$1" 2>/dev/null
}

echo "inject-policy-utf8-locale (locale $UTF8_LOCALE)"

# 1. Both policies load under the UTF-8 locale.
run_hook utf8 "$tmp/bin"
if grep -q 'aaa-emdash' "$tmp/out-utf8" && grep -q 'zzz-plain' "$tmp/out-utf8"; then
  ok "both policies load under $UTF8_LOCALE"
else
  bad "a policy is missing under $UTF8_LOCALE (stderr: $(head -c 200 "$tmp/err-utf8"))"
fi
if grep -qi 'multibyte' "$tmp/err-utf8"; then
  bad "awk reported a multibyte failure: $(head -c 200 "$tmp/err-utf8")"
else
  ok "no multibyte conversion failure on stderr"
fi

# 2. The cut is byte-safe without relying on the iconv repair. The TSV emit
#    path prints the evaluator's rule summary field as-is.
run_hook raw "$tmp/bin-noiconv" tsv
if grep -qF "${pad}..." "$tmp/out-raw"; then
  ok "summary keeps the whole-character prefix and drops the split em dash"
else
  bad "summary is not '<155 bytes>...' (stderr: $(head -c 200 "$tmp/err-raw"))"
fi
if valid_utf8 "$tmp/out-raw"; then
  ok "evaluator output is valid UTF-8 with a no-op iconv"
else
  bad "evaluator output contains a split UTF-8 sequence"
fi
if grep -q 'zzz-plain' "$tmp/out-raw"; then
  ok "the policy after the cut summary still loads"
else
  bad "the policy after the cut summary is missing"
fi

# 3. A summary under the ceiling keeps its multibyte text unchanged.
write_policy aaa-emdash "Short rule ${emdash} with an em dash."
run_hook short "$tmp/bin-noiconv" tsv
if grep -qF "Short rule ${emdash} with an em dash." "$tmp/out-short"; then
  ok "a short multibyte summary is not truncated"
else
  bad "a short multibyte summary was altered"
fi

echo "inject-policy-utf8-locale: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
