#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SELF="${BASH_SOURCE[0]#"$ROOT"/}"
PATTERN='\$\{[^}]*@[[:alpha:]]\}'
FOUND=0

for operator in Q E P A a K k; do
  fixture='${value@'"$operator"'}'
  if ! [[ "$fixture" =~ $PATTERN ]]; then
    printf 'FAIL: regex does not recognize Bash parameter transformation @%s\n' "$operator" >&2
    FOUND=1
  fi
done

while IFS= read -r path; do
  [[ "$path" == "$SELF" ]] && continue
  case "$path" in
    *test*.sh|*.test.sh|*/tests/*.sh|*/test/*.sh) ;;
    *) continue ;;
  esac
  if matches="$(LC_ALL=C grep -nE "$PATTERN" "$ROOT/$path")"; then
    printf 'FAIL: Bash 4.4 parameter transformation in test script %s:\n%s\n' "$path" "$matches" >&2
    FOUND=1
  fi
done < <(git -C "$ROOT" ls-files)

if [[ "$FOUND" -ne 0 ]]; then
  exit 1
fi

echo "bash32-parameter-expansion-guard: no unsupported parameter transformations in tracked shell test scripts"
