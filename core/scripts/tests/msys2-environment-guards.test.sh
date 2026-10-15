#!/usr/bin/env bash
# Regression test: the MSYS2 guards in core scripts match every MSYS2
# environment, not only MINGW64. Git for Windows 2.56+ sets MSYSTEM=UCRT64, and
# a MINGW-only guard skipped the jq --binary wrapper and the session-journal
# newline fix there (hq-cli #1943 follow-up, feedback_a60339e8 Windows cluster).
#
# Each guard is extracted from its script and evaluated in isolation, so the
# test runs on any host.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPTS="$ROOT/core/scripts"
fail=0

case_guard_matches() {
  local script="$1" key="$2" pattern
  pattern="$(sed -n 's/^  \(msys\*:\*|[^)]*\))$/\1/p' "$script" | head -n 1)"
  if [[ -z "$pattern" ]]; then
    echo "FAIL: no OSTYPE:MSYSTEM guard found in $script" >&2
    return 2
  fi
  # shellcheck disable=SC2254 # the pattern is the script's own case arm.
  eval "case \"\$key\" in $pattern) return 0 ;; *) return 1 ;; esac"
}

for name in hq-delegate-grant.sh hq-delegate-send.sh hq-job-probe.sh jobs-validate.sh; do
  script="$SCRIPTS/$name"
  for key in "darwin:MINGW64" "darwin:MINGW32" "darwin:UCRT64" "darwin:CLANG64" "darwin:CLANGARM64" "cygwin:MSYS" "msys:"; do
    if ! case_guard_matches "$script" "$key"; then
      echo "FAIL: $name guard does not match $key" >&2
      fail=1
    fi
  done
  for key in "darwin:" "linux-gnu:" "linux-gnu:MSYSTEM_UNSET"; do
    if case_guard_matches "$script" "$key"; then
      echo "FAIL: $name guard matches non-MSYS2 $key" >&2
      fail=1
    fi
  done
done

# session-journal.sh folds newlines in a slug on MSYS2; check its MSYSTEM test.
# shellcheck disable=SC2016 # the regex matches a literal ${MSYSTEM:-} in the script.
journal_test="$(grep -o '\[\[ "\${MSYSTEM:-}" [^]]*\]\]' "$SCRIPTS/session-journal.sh" | head -n 1)"
if [[ -z "$journal_test" ]]; then
  echo "FAIL: no MSYSTEM test found in session-journal.sh" >&2
  fail=1
else
  for value in MINGW64 UCRT64 CLANG64 MSYS; do
    if ! MSYSTEM="$value" eval "$journal_test"; then
      echo "FAIL: session-journal.sh MSYSTEM test does not match $value" >&2
      fail=1
    fi
  done
  if MSYSTEM="" eval "$journal_test"; then
    echo "FAIL: session-journal.sh MSYSTEM test matches an empty MSYSTEM" >&2
    fail=1
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "PASS: MSYS2 guards match MINGW, UCRT, CLANG and MSYS environments"
