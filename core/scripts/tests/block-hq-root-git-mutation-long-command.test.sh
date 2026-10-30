#!/usr/bin/env bash
# block-hq-root-git-mutation-long-command.test.sh
#
# Pins the speed of block-hq-root-git-mutation.sh on a long command. The guard
# is a master-hook safety guard, so a run longer than the 25 s safety cap now
# blocks the tool call as "guard timed out". Before this change it started
# about three subshells per simple command (about 3 ms per line), and a
# 10,000-line command took about 30 s. The guard must still find and block an
# HQ-root `git commit` on the last line, and must finish well under the cap.
#
# Runs under every Bash found: the PATH bash (bash 5 on CI and Homebrew) and
# /bin/bash (3.2 on macOS). Set GIT_GUARD_TEST_BASHES to override the list.
# Set GIT_GUARD_LONG_BUDGET_S to change the per-run budget (default 12 s).
# Each timing is printed and, on GitHub Actions, added to the step summary.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/block-hq-root-git-mutation.sh"
LINES="${GIT_GUARD_LONG_LINES:-10000}"
BUDGET_S="${GIT_GUARD_LONG_BUDGET_S:-12}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$HOOK" ] || fail "missing $HOOK"
command -v jq >/dev/null 2>&1 || fail "jq required"
command -v perl >/dev/null 2>&1 || fail "perl required (timing)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/git-guard-long.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# Fake HQ root with a nested working repo, as in block-hq-root-git-mutation.test.sh.
HQ="$TMP/hq"
mkdir -p "$HQ/repos/private/app"
git -C "$HQ" init -q
git -C "$HQ/repos/private/app" init -q
NESTED="$HQ/repos/private/app"

# write_payload <file> <last line>: LINES-1 harmless lines, then <last line>.
write_payload() {
  local file="$1" last="$2"
  perl -e '
    my ($n, $last) = @ARGV;
    print "echo line $_\n" for 1 .. $n - 1;
    print $last;
  ' "$LINES" "$last" > "$TMP/cmd.txt"
  jq -n --rawfile cmd "$TMP/cmd.txt" --arg cwd "$HQ" \
    '{cwd: $cwd, tool_input: {command: $cmd}}' > "$file"
}
write_payload "$TMP/block.json" "git commit -m x"
write_payload "$TMP/allow.json" "git -C $NESTED commit -m x"
[ "$(jq -r '.tool_input.command' "$TMP/block.json" | wc -l | tr -d ' ')" -eq "$LINES" ] \
  || fail "payload does not hold $LINES lines"

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

BASHES=()
if [ -n "${GIT_GUARD_TEST_BASHES:-}" ]; then
  read -r -a BASHES <<<"$GIT_GUARD_TEST_BASHES"
else
  for candidate in "$(command -v bash)" /bin/bash; do
    [ -x "$candidate" ] || continue
    dup=0
    for seen in ${BASHES[@]+"${BASHES[@]}"}; do
      [ "$candidate" -ef "$seen" ] && dup=1
    done
    [ "$dup" -eq 1 ] || BASHES+=("$candidate")
  done
fi
[ "${#BASHES[@]}" -gt 0 ] || fail "no bash found"

# run_case <bash> <payload> <expected rc> <label>
run_case() {
  local sh="$1" payload="$2" want="$3" label="$4" rc=0 t0 t1 secs version
  version="$("$sh" -c 'echo "$BASH_VERSION"')"
  t0="$(now)"
  CLAUDE_PROJECT_DIR="$HQ" HQ_ALLOW_HQ_ROOT_GIT= "$sh" "$HOOK" < "$payload" > "$TMP/out" 2> "$TMP/err" || rc=$?
  t1="$(now)"
  secs="$(perl -e 'printf "%.2f", $ARGV[1] - $ARGV[0]' "$t0" "$t1")"
  echo "  timing: bash $version, $LINES lines, $label: ${secs}s (rc $rc)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "| $(uname -s) | bash $version | $LINES | $label | ${secs}s | $rc |" >> "$GITHUB_STEP_SUMMARY"
  fi
  [ "$rc" -eq "$want" ] || { cat "$TMP/err" >&2; fail "bash $version $label: rc $rc, want $want"; }
  perl -e 'exit($ARGV[0] <= $ARGV[1] ? 0 : 1)' "$secs" "$BUDGET_S" \
    || fail "bash $version $label: ${secs}s exceeds the ${BUDGET_S}s budget"
  pass "bash $version $label: rc $rc in ${secs}s (budget ${BUDGET_S}s)"
}

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### block-hq-root-git-mutation long-command timing"
    echo "| OS | Bash | Lines | Case | Time | Exit |"
    echo "|---|---|---|---|---|---|"
  } >> "$GITHUB_STEP_SUMMARY"
fi

# Bash reads a pipe one byte per read() call, and each call is slow on Git
# Bash. While the guard read the command and its records with `read`, the
# 10,000-line case took 21.6 s on the Windows runner. Count the reading
# builtins the guard calls; the count must not grow with the line count.
# READ_LIMIT is far below one call per line.
READ_LIMIT=20
cat > "$TMP/count-reads.sh" <<'CASE'
reads=0
read() { reads=$((reads + 1)); builtin read "$@"; }
mapfile() { reads=$((reads + 1)); builtin mapfile "$@"; }
readarray() { reads=$((reads + 1)); builtin readarray "$@"; }
trap 'printf "%s\n" "$reads" > "$READS_OUT"' EXIT
. "$1"
CASE

# read_case <bash> <payload> <expected rc> <label>
read_case() {
  local sh="$1" payload="$2" want="$3" label="$4" rc=0 reads version
  version="$("$sh" -c 'echo "$BASH_VERSION"')"
  rm -f "$TMP/reads"
  READS_OUT="$TMP/reads" CLAUDE_PROJECT_DIR="$HQ" HQ_ALLOW_HQ_ROOT_GIT= \
    "$sh" "$TMP/count-reads.sh" "$HOOK" < "$payload" > "$TMP/out" 2> "$TMP/err" || rc=$?
  [ "$rc" -eq "$want" ] || { cat "$TMP/err" >&2; fail "bash $version $label (read count): rc $rc, want $want"; }
  [ -s "$TMP/reads" ] || fail "bash $version $label: read count was not recorded"
  reads="$(cat "$TMP/reads")"
  [ "$reads" -le "$READ_LIMIT" ] \
    || fail "bash $version $label: $reads read/mapfile calls for $LINES lines (limit $READ_LIMIT)"
  pass "bash $version $label: $reads read/mapfile calls for $LINES lines"
}

for sh in "${BASHES[@]}"; do
  read_case "$sh" "$TMP/block.json" 2 "HQ-root git commit on the last line is blocked"
  read_case "$sh" "$TMP/allow.json" 0 "git -C nested-repo commit on the last line is allowed"
  run_case "$sh" "$TMP/block.json" 2 "HQ-root git commit on the last line is blocked"
  grep -q 'git commit' "$TMP/err" || fail "block message does not name the git commit"
  run_case "$sh" "$TMP/allow.json" 0 "git -C nested-repo commit on the last line is allowed"
done

echo "ALL PASS: block-hq-root-git-mutation-long-command"
