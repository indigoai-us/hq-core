#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
FORWARDER="${HQ_TEST_FORWARDER:-$ROOT/core/scripts/read-policy-frontmatter.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/read-policy-frontmatter-batch.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
# Keep the fake hq version in sync with the same core.yaml floor enforced by the
# forwarder, so floor raises do not require a brittle literal update.
# shellcheck source=../lib/hq-cli-floor.sh
. "$ROOT/core/scripts/lib/hq-cli-floor.sh"
HQ_TEST_CLI_VERSION="$(hq_cli_floor_required "$ROOT")"

cat > "$TMP/bin/hq" <<'HQ'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'CALL:'
  printf ' <%s>' "$@"
  printf '\n'
} >> "$HQ_TEST_CALLS"
if [ "${1-}" = "--version" ]; then
  printf '%s\n' "$HQ_TEST_CLI_VERSION"
  exit 0
fi
if [ "${1-}" = core ] && [ "${2-}" = policy ] && [ "${3-}" = frontmatter ]; then
  exit 0
fi
printf 'unexpected hq invocation\n' >&2
exit 64
HQ
chmod +x "$TMP/bin/hq"

touch "$TMP/one.md" "$TMP/two.md"
HQ_TEST_CLI_VERSION="$HQ_TEST_CLI_VERSION" HQ_TEST_CALLS="$TMP/calls.log" PATH="$TMP/bin:$PATH" bash "$FORWARDER" "$TMP/one.md" "$TMP/two.md"

version_calls="$(grep -c '^CALL: <--version>$' "$TMP/calls.log")"
command_calls="$(grep -c '^CALL: <core> <policy> <frontmatter> ' "$TMP/calls.log")"
file_args="$(tail -n 1 "$TMP/calls.log")"
[ "$version_calls" -eq 1 ] || {
  echo "FAIL: expected one CLI version probe, found $version_calls" >&2
  exit 1
}
[ "$command_calls" -eq 1 ] || {
  echo "FAIL: expected one frontmatter CLI process for the whole file set, found $command_calls" >&2
  exit 1
}
[ "$file_args" = "CALL: <core> <policy> <frontmatter> <$TMP/one.md> <$TMP/two.md>" ] || {
  echo "FAIL: the batch invocation did not preserve both file arguments: $file_args" >&2
  exit 1
}

# An older CLI silently accepts a multi-file argv but processes only the first
# path. The forwarder's release-floor check must stop it before that partial
# result can reach a skill.
mkdir -p "$TMP/old-floor-bin"
cat > "$TMP/old-floor-bin/hq" <<'HQ'
#!/usr/bin/env bash
if [ "${1-}" = "--version" ]; then
  printf '%s\n' "${HQ_TEST_CLI_VERSION:?}"
  exit 0
fi
printf 'partial result\n'
exit 0
HQ
chmod +x "$TMP/old-floor-bin/hq"
if HQ_TEST_CLI_VERSION=5.345.62 PATH="$TMP/old-floor-bin:$PATH" bash "$FORWARDER" "$TMP/one.md" "$TMP/two.md" > "$TMP/old-floor.stdout" 2> "$TMP/old-floor.stderr"; then
  old_floor_status=0
else
  old_floor_status=$?
fi
[ "$old_floor_status" -ne 0 ] || {
  echo "FAIL: forwarder accepted hq-cli 5.345.62 below its 5.345.63 floor" >&2
  exit 1
}
grep -Fq 'needs hq-cli >= 5.345.63 (found 5.345.62)' "$TMP/old-floor.stderr" || {
  echo "FAIL: old CLI rejection did not include the floor message" >&2
  exit 1
}
if grep -Fq 'partial result' "$TMP/old-floor.stdout"; then
  echo "FAIL: old CLI printed a partial result before the floor rejection" >&2
  exit 1
fi
printf 'PASS: forwarder rejects hq-cli 5.345.62 before any partial multi-file output\n'

SKILL_ROOT="${HQ_TEST_SKILL_ROOT:-$ROOT/.claude/skills}"
POLICY_CHUNK_SIZE=""
for skill in learn brainstorm knowledge-pulse storyboard startwork deep-plan execute-task prd; do
  skill_file="$SKILL_ROOT/$skill/SKILL.md"
  chunk_declarations="$(LC_ALL=C grep -oE 'chunks of at most [0-9]+ files' "$skill_file" | sed 's/[^0-9]//g' || true)"
  [ -n "$chunk_declarations" ] || {
    echo "FAIL: $skill does not declare a frontmatter chunk size" >&2
    exit 1
  }
  for declared_size in $chunk_declarations; do
    if [ -z "$POLICY_CHUNK_SIZE" ]; then
      POLICY_CHUNK_SIZE="$declared_size"
    elif [ "$declared_size" -ne "$POLICY_CHUNK_SIZE" ]; then
      echo "FAIL: $skill declares chunk size $declared_size, expected consistent size $POLICY_CHUNK_SIZE" >&2
      exit 1
    fi
  done
  if ! grep -Fq 'chunks of at most ' "$skill_file" || \
     ! grep -Fq 'bash core/scripts/read-policy-frontmatter.sh {file1} {file2} ...' "$skill_file" || \
     grep -Fq 'hq core policy frontmatter {file1} {file2} ...' "$skill_file" || \
     ! grep -Fq 'under 30 KB of output' "$skill_file" || \
     ! grep -Fq 'first output block belongs to the chunk’s first file argument' "$skill_file" || \
     ! grep -Fq 'each later block belongs to the path named by its preceding' "$skill_file"; then
    echo "FAIL: $skill does not document bounded chunks and per-file result ownership" >&2
    exit 1
  fi
  if ! sed -n '4p' "$skill_file" | grep -Fq 'Bash(bash core/scripts/read-policy-frontmatter.sh:*)'; then
    echo "FAIL: $skill does not allow the floor-checked forwarder command" >&2
    exit 1
  fi
done

if [ "${HQ_TEST_REQUIRE_REAL_CLI:-0}" = 1 ]; then
  REAL_HQ="${HQ_TEST_REAL_CLI:-}"
  case "$REAL_HQ" in
    */*) ;;
    *) REAL_HQ="$(command -v "$REAL_HQ" || true)" ;;
  esac
  [ -n "$REAL_HQ" ] && [ -x "$REAL_HQ" ] || {
    echo "FAIL: HQ_TEST_REQUIRE_REAL_CLI needs an executable HQ_TEST_REAL_CLI" >&2
    exit 1
  }
  mkdir -p "$TMP/real-cli"
  printf '%s\n' '---' 'title: first' '---' 'body' > "$TMP/real-cli/one.md"
  printf '%s\n' '---' 'title: second' '---' 'body' > "$TMP/real-cli/two.md"
  printf '%s\n' 'title: first' > "$TMP/real-cli/one.expected"
  printf '%s\n' 'title: second' > "$TMP/real-cli/two.expected"
  printf 'title: first\n\n# --- policy-file: %s ---\ntitle: second\n' "$TMP/real-cli/two.md" > "$TMP/real-cli/batch.expected"
  mkdir -p "$TMP/real-cli-bin"
  ln -s "$REAL_HQ" "$TMP/real-cli-bin/hq"
  REAL_CLI_PATH="$TMP/real-cli-bin:$PATH"
  HQ_FLAG_HQ_CORE_NATIVE_FAST_ROUTE=true HQ_FLAG_CORE_NATIVE_POLICY=true PATH="$REAL_CLI_PATH" bash "$FORWARDER" "$TMP/real-cli/one.md" "$TMP/real-cli/two.md" > "$TMP/real-cli/batch.actual"
  HQ_FLAG_HQ_CORE_NATIVE_FAST_ROUTE=true HQ_FLAG_CORE_NATIVE_POLICY=true PATH="$REAL_CLI_PATH" bash "$FORWARDER" "$TMP/real-cli/one.md" > "$TMP/real-cli/one.actual"
  HQ_FLAG_HQ_CORE_NATIVE_FAST_ROUTE=true HQ_FLAG_CORE_NATIVE_POLICY=true PATH="$REAL_CLI_PATH" bash "$FORWARDER" "$TMP/real-cli/two.md" > "$TMP/real-cli/two.actual"
  cmp "$TMP/real-cli/batch.expected" "$TMP/real-cli/batch.actual"
  cmp "$TMP/real-cli/one.expected" "$TMP/real-cli/one.actual"
  cmp "$TMP/real-cli/two.expected" "$TMP/real-cli/two.actual"
  printf 'PASS: installed CLI matches single-file and batch output contracts\n'

  # Exercise the chunking documented by the skills against the real global
  # policy tree. Keep each shell-tool result below 20,000 bytes with headroom
  # for policies added after this test was written.
  policy_files=()
  for policy_file in "$ROOT"/core/policies/*.md; do
    [ -f "$policy_file" ] || continue
    [ "${policy_file##*/}" = example-policy.md ] && continue
    policy_files+=("$policy_file")
  done
  chunk_number=0
  for ((chunk_start=0; chunk_start<${#policy_files[@]}; chunk_start+=POLICY_CHUNK_SIZE)); do
    chunk_args=()
    chunk_end=$((chunk_start + POLICY_CHUNK_SIZE))
    [ "$chunk_end" -le "${#policy_files[@]}" ] || chunk_end="${#policy_files[@]}"
    for ((file_index=chunk_start; file_index<chunk_end; file_index++)); do
      chunk_args+=("${policy_files[$file_index]}")
    done
    chunk_output="$TMP/real-cli/policy-chunk-$chunk_number.out"
    HQ_FLAG_HQ_CORE_NATIVE_FAST_ROUTE=true HQ_FLAG_CORE_NATIVE_POLICY=true PATH="$REAL_CLI_PATH" bash "$FORWARDER" "${chunk_args[@]}" > "$chunk_output"
    chunk_bytes="$(wc -c < "$chunk_output" | tr -d '[:space:]')"
    if [ "$chunk_bytes" -gt 20000 ]; then
      echo "FAIL: real policy tree chunk $chunk_number ($POLICY_CHUNK_SIZE files) emitted $chunk_bytes bytes; limit is 20000" >&2
      exit 1
    fi
    printf 'PASS: real policy tree chunk %s (%s files) emitted %s bytes\n' "$chunk_number" "${#chunk_args[@]}" "$chunk_bytes"
    chunk_number=$((chunk_number + 1))
  done
  [ "$POLICY_CHUNK_SIZE" -le 40 ] || {
    echo "FAIL: all skills must keep chunk size at most 40 files; found $POLICY_CHUNK_SIZE" >&2
    exit 1
  }
  printf 'PASS: all nine skills agree on chunk size %s; %s real-tree chunks are at most 20000 bytes\n' "$POLICY_CHUNK_SIZE" "$chunk_number"
fi

printf 'PASS: one hq frontmatter invocation carries both file arguments\n'
printf 'PASS: all nine policy-reading skills use the floor-checked forwarder in bounded stable chunks and document result ownership\n'
