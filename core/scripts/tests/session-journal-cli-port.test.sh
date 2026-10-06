#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="${SESSION_JOURNAL:-$ROOT/core/scripts/session-journal.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

yaml_root="$TMP/yaml"
mkdir -p "$yaml_root"
c1_title="$(printf 'C1 control:\302\205')"
c1_path="$(HQ_ROOT="$yaml_root" bash "$HELPER" write "$c1_title")"
grep -Fq 'title: "C1 control:\u0085"' "$c1_path"
grep -Fq '# 001 — C1 control:' "$c1_path"

newline_root="$TMP/newline"
mkdir -p "$newline_root"
newline_path="$(MSYSTEM=MINGW64 HQ_ROOT="$newline_root" bash "$HELPER" write $'Alpha\nBeta')"
[[ "${newline_path##*/}" == "001-alpha-beta.md" ]]
grep -Fq 'slug: alpha-beta' "$newline_path"

parallel_root="$TMP/parallel"
mkdir -p "$parallel_root"
pids=()
for index in {1..8}; do
  HQ_ROOT="$parallel_root" bash "$HELPER" write "parallel $index" >"$TMP/parallel-$index.path" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
journal_dir="$parallel_root/workspace/threads/journal/$(date -u +%Y-%m-%d)"
entries=("$journal_dir"/[0-9][0-9][0-9]-*.md)
[[ "${#entries[@]}" -eq 8 ]]
for index in {1..8}; do
  [[ -s "$TMP/parallel-$index.path" ]]
done
[[ -s "$journal_dir/INDEX.md" ]]

HQ_ROOT="$yaml_root" bash "$HELPER" read abc >"$TMP/read.out" 2>"$TMP/read.err"
grep -Fq 'read: NNN required' "$TMP/read.err"

echo "session-journal CLI port: YAML C1 title, Win32 newline slug, concurrent unique sequence writes, and invalid sequence diagnostic"
