#!/bin/bash
# hq-core: public
# Regression: env-file-no-trailing-newline must block a contaminated dotenv
# write however much content follows the first bad line. The guard pipes the
# content through awk under `set -euo pipefail`, and bash's printf writes one
# line at a time. When awk stopped at the first bad line, a later printf write
# hit a closed pipe, the pipeline died of SIGPIPE, and the hook exited 141 with
# no output, which hosts treat as a non-blocking error. More than a pipe
# buffer of content after the bad line made that certain; two lines made it a
# race. The guard now lets awk read to the end.
#
# Runs the guard under every bash found among /bin/bash and the bash on PATH
# (bash 3.2 and 5.x on macOS). HQ_ENV_GUARD_UNDER_TEST overrides the guard
# path, to show the old guard failing.
#
# Fixture-only: the .env file here is a synthetic file in a temp dir.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
GUARD="${HQ_ENV_GUARD_UNDER_TEST:-$ROOT/.claude/hooks/env-file-no-trailing-newline.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
touch "$TMP/.ENV.local"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# The content goes to jq on stdin, not as an argument: Linux caps a single
# argument at 128 KiB, and the large cases are bigger than that.
payload() {
  printf '%s' "$1" | jq -Rsc --arg cwd "$TMP" \
    '{tool_name: "Write", cwd: $cwd, tool_input: {file_path: ".ENV.local", content: .}}'
}

clean_lines() {
  local n="$1" i out=""
  for ((i = 1; i <= n; i++)); do out="${out}CLEAN_KEY_$i=\"value\""$'\n'; done
  printf '%s' "$out"
}

CLEAN="$(clean_lines 20000)"
if [ "${#CLEAN}" -le 65536 ]; then
  echo "FAIL: clean block is ${#CLEAN} bytes, not more than one pipe buffer" >&2
  exit 1
fi

# expect <bash> <label> <content> <exit> <reason or empty>
expect() {
  local sh="$1" label="$2" content="$3" want_rc="$4" want_reason="$5" rc=0
  payload "$content" | (cd "$TMP" && "$sh" "$GUARD") > "$TMP/out" 2> "$TMP/err" || rc=$?
  if [ "$rc" != "$want_rc" ]; then
    bad "$sh: $label: exit $rc, want $want_rc (stderr bytes: $(wc -c < "$TMP/err" | tr -d ' '))"
    return
  fi
  if [ -s "$TMP/out" ]; then
    bad "$sh: $label: unexpected stdout"
    return
  fi
  if [ -n "$want_reason" ]; then
    if ! grep -q "BLOCKED: .ENV.local contains an env line whose quoted value has $want_reason." "$TMP/err"; then
      bad "$sh: $label: stderr lacks the $want_reason block message"
      return
    fi
  elif [ -s "$TMP/err" ]; then
    bad "$sh: $label: unexpected stderr"
    return
  fi
  ok
}

shells=()
for candidate in /bin/bash "$(command -v bash)"; do
  [ -x "$candidate" ] || continue
  seen=0
  for s in "${shells[@]+"${shells[@]}"}"; do
    [ "$s" -ef "$candidate" ] && seen=1
  done
  [ "$seen" = 1 ] || shells+=("$candidate")
done

for sh in "${shells[@]}"; do
  echo "guard under $("$sh" -c 'echo "$BASH_VERSION"') ($sh)"
  # A bad first line followed by more than a pipe buffer: the old guard died
  # of SIGPIPE here every time.
  for i in 1 2 3; do
    expect "$sh" "trailing whitespace, then 20000 clean lines (run $i)" \
      "KEY=\"bad \""$'\n'"$CLEAN" 2 trailing_whitespace
    expect "$sh" "literal backslash-n, then 20000 clean lines (run $i)" \
      'KEY="bad\n"'$'\n'"$CLEAN" 2 literal_backslash_n
  done
  # Two lines with a bad first line: the race case.
  expect "$sh" "two lines, bad first" 'KEY="bad "'$'\n''SECOND="bad\n"' 2 trailing_whitespace
  # The first bad line decides the reason, as before.
  expect "$sh" "first violation wins" 'A="x\n"'$'\n''B="y "' 2 literal_backslash_n
  expect "$sh" "bad line last" "$CLEAN"'KEY="bad "' 2 trailing_whitespace
  # Clean content still passes, large or small.
  expect "$sh" "20000 clean lines" "$CLEAN" 0 ""
  expect "$sh" "one clean line" 'KEY="value"' 0 ""
done

echo "env-file guard large content: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
