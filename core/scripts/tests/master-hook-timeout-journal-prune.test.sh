#!/usr/bin/env bash
# hq-core: public
# master-hook-timeout-journal-prune.test.sh — master-hook.sh keeps
# workspace/.hook-timeout-journal bounded and does not read that directory on
# every event.
#
# The directory holds two kinds of file. Per-session files (<session>.tsv, the
# timing journal, with .meta, .root-storage-class, .spawn-ms and
# <session>.cli-version beside it) are written while a session runs and were
# never removed, so they stayed after the session ended. Per-dispatch files
# (<session>.tsv.<invocation>.active, .active.<index>, <invocation>.debug.tsv
# and its .active, .child, .child.active and .cli-version) are removed when a
# dispatch ends, and stayed when the dispatch was killed. Nothing pruned
# either kind. With HQ_HOOK_PARALLEL=1 the dispatcher found its per-child
# breadcrumbs (.active.<index>) with a glob at the end of every event, which
# reads the whole directory and costs time per entry.
#
# Sections:
#   [a] sequential: one dispatch leaves the session journal and no
#       per-dispatch file
#   [b] parallel (bash 5.1 or later): no per-child breadcrumb is left
#   [c] parallel: the breadcrumbs are removed by name, so the cleanup works in
#       a journal directory that cannot be listed
#   [d] a directory of 27,000 aged files and no sweep stamp is cleaned by one
#       dispatch; files that are recent for their kind, files with other
#       names and subdirectories stay
#   [e] the cleanup is throttled by a stamp beside the directory
#   [f] a session that is still running keeps its journal, and gets its
#       metadata file back after it aged out
#   [g] 27,000 files too recent to remove do not slow a dispatch, parallel or
#       sequential
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "SKIP: perl unavailable" >&2; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mh-journal-prune.XXXXXX")"
JOURNAL=""
cleanup() {
  [ -z "$JOURNAL" ] || [ ! -d "$JOURNAL" ] || chmod 755 "$JOURNAL" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
TMP="$(cd "$TMP" && pwd -P)"
FIX="$TMP/hq"
FAKE_HOME="$TMP/home"
CACHE="$FAKE_HOME/.cache"
JOURNAL="$FIX/workspace/.hook-timeout-journal"
STAMP="$JOURNAL.swept"
FILES=27000
DAY=86400
SESSION_OLD=$((8 * DAY))      # older than the per-session bound (7 days)
SESSION_RECENT=$((3 * DAY))   # inside it
DISPATCH_OLD=7200             # older than the per-dispatch bound (60 minutes)
DISPATCH_RECENT=600           # inside it
# The interpreter under test is pinned: HQ_TEST_BASH when set, else /bin/bash
# (what settings.json resolves on macOS), else the first bash on PATH.
TEST_BASH="${HQ_TEST_BASH:-/bin/bash}"
[ -x "$TEST_BASH" ] || TEST_BASH="$(command -v bash)"
echo "interpreter under test: $TEST_BASH ($("$TEST_BASH" -c 'echo "$BASH_VERSION"'))"
# Parallel dispatch needs bash 5.1 or later, and the directory read was
# slowest under bash 5. Use the pinned interpreter when it qualifies, else the
# first bash on PATH that does.
is_bash51() { "$1" -c '[ "${BASH_VERSINFO[0]}" -gt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }' 2>/dev/null; }
BASH51=""
if is_bash51 "$TEST_BASH"; then
  BASH51="$TEST_BASH"
elif command -v bash >/dev/null 2>&1 && is_bash51 "$(command -v bash)"; then
  BASH51="$(command -v bash)"
fi
[ -n "$BASH51" ] || echo "note: no bash 5.1 or later on this host; parallel dispatch stays sequential there, so [b], [c] and the parallel half of [g] do not run"
mkdir -p "$FAKE_HOME" "$CACHE"

mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts/lib" "$FIX/workspace/orchestrator"
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
for f in hook-timeout-probe.sh hook-timeout-watchdog.sh hook-gate.sh; do
  cp "$ROOT/.claude/hooks/$f" "$FIX/.claude/hooks/"
done
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$ROOT/core/scripts/lib/trigger-fact-text.awk" "$FIX/core/scripts/lib/"
[ ! -f "$ROOT/core/scripts/lib/perl-child-locale.sh" ] \
  || cp "$ROOT/core/scripts/lib/perl-child-locale.sh" "$FIX/core/scripts/lib/"
cp "$ROOT/core/scripts/resolve-hq-root.sh" "$FIX/core/scripts/"
printf 'hqVersion: "15.0.131"\n' > "$FIX/core/core.yaml"
for id in fixture-one fixture-two; do
  cat > "$FIX/.claude/hooks/$id.sh" <<HOOK
#!/usr/bin/env bash
cat >/dev/null
here="\$(cd "\$(dirname "\$0")" && pwd)"
printf '$id\n' >> "\$here/ran.log"
exit 0
HOOK
  chmod +x "$FIX/.claude/hooks/$id.sh"
done
jq -nc '
  {hooks: {PreToolUse: [{matcher: "Bash", hooks: [
    {id: "fixture-one", script: ".claude/hooks/fixture-one.sh", timeout: 7, gated: false, runner: "exec", args: ["PreToolUse"]},
    {id: "fixture-two", script: ".claude/hooks/fixture-two.sh", timeout: 7, gated: false, runner: "exec", args: ["PreToolUse"]}
  ]}]}}' > "$FIX/.claude/hooks/hook-registry.json"

PAYLOAD="$(jq -nc --arg d "$FIX" '{session_id:"journal-prune",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:"echo hi"}}')"

# run [ENV=VALUE ...] -> RC. RUN_BASH picks the interpreter. The timeout
# sentry is on, so the dispatcher uses the journal on every host.
RUN_BASH="$TEST_BASH"
run() {
  RC=0
  printf '%s' "$PAYLOAD" | (cd "$FIX" && env HOME="$FAKE_HOME" XDG_CACHE_HOME="$CACHE" \
    HQ_HOOK_PROFILE=standard CLAUDE_PROJECT_DIR="$FIX" HQ_ROOT="$FIX" \
    HQ_HOOK_DEDUPE=0 HQ_HOOK_TIMEOUT_SENTRY=1 HQ_DISABLED_HOOKS= HQ_FLAGS_API_URL= HQ_COMPANY_UID= \
    "$@" "$RUN_BASH" "$FIX/.claude/hooks/master-hook.sh" PreToolUse) \
    >"$TMP/out" 2>"$TMP/err" || RC=$?
}
run_parallel() { RUN_BASH="$BASH51"; run HQ_HOOK_PARALLEL=1 "$@"; RUN_BASH="$TEST_BASH"; }
reset_logs() { rm -f "$FIX/.claude/hooks/ran.log"; }
ran() { # <id>: times the hook ran
  [ -f "$FIX/.claude/hooks/ran.log" ] || { echo 0; return; }
  grep -c "^$1\$" "$FIX/.claude/hooks/ran.log" || true
}
both_ran() { [ "$RC" = "0" ] && [ "$(ran fixture-one)" = "1" ] && [ "$(ran fixture-two)" = "1" ]; }
run_detail() { printf 'rc=%s ran=%s/%s err=%s' "$RC" "$(ran fixture-one)" "$(ran fixture-two)" "$(head -c 300 "$TMP/err")"; }
# Per-dispatch files: a finished dispatch must leave none.
dispatch_names() {
  [ -d "$JOURNAL" ] || return 0
  find "$JOURNAL" -maxdepth 1 -type f \
    \( -name '*.active' -o -name '*.active.*' -o -name '*.debug.tsv' -o -name '*.debug.tsv.*' \) 2>/dev/null \
    | sed 's|.*/||' | sort
}
no_dispatch_files() { # <label>
  local n
  n="$(dispatch_names | grep -c . || true)"
  [ "$n" = "0" ] && ok "$1: no per-dispatch file left in .hook-timeout-journal" \
    || bad "$1: $n per-dispatch file(s) left: $(dispatch_names | head -n 4 | tr '\n' ' ')"
  [ "$n" = "0" ] || find "$JOURNAL" -maxdepth 1 -type f \
    \( -name '*.active' -o -name '*.active.*' -o -name '*.debug.tsv' -o -name '*.debug.tsv.*' \) \
    -exec rm -f {} + 2>/dev/null
}
age() { # <seconds> <path...>
  perl -e 'my $t = time - shift; utime($t, $t, @ARGV) == @ARGV or exit 1' "$@"
}
now_ms() { perl -MTime::HiRes=time -e 'printf("%d\n", time()*1000)'; }
# plant <session|dispatch> <groups> <tag> <age seconds>: files named like the
# real ones, every name starting with <tag>. A session group is 5 files, a
# dispatch group 7. Age 0 leaves the current time.
SESSION_GROUP=5
DISPATCH_GROUP=7
plant() {
  perl -e '
    my ($d, $kind, $n, $tag, $age) = @ARGV;
    my $t = time - $age;
    for my $i (1 .. $n) {
      my $s = sprintf("%s%060x", $tag, $i);
      my $v = sprintf("%sd%059x", $tag, $i);
      my @names = $kind eq "session"
        ? ("$s.tsv", "$s.tsv.meta", "$s.tsv.root-storage-class", "$s.tsv.spawn-ms", "$s.cli-version")
        : ("$s.tsv.$v.active", "$s.tsv.$v.active.3", "$v.debug.tsv", "$v.debug.tsv.active",
           "$v.debug.tsv.child", "$v.debug.tsv.child.active", "$v.debug.tsv.cli-version");
      for my $name (@names) {
        my $f = "$d/$name";
        open my $fh, ">", $f or die "$f: $!";
        print $fh "fixture\n";
        close $fh;
        utime($t, $t, $f) if $age > 0;
      }
    }' "$JOURNAL" "$@"
}
count_tag() { # <tag>
  find "$JOURNAL" -maxdepth 1 -type f -name "$1*" 2>/dev/null | grep -c . || true
}
remove_tag() { find "$JOURNAL" -maxdepth 1 -type f -name "$1*" -exec rm -f {} + 2>/dev/null; }
session_journal() { # the test session's own journal file, once it exists
  find "$JOURNAL" -maxdepth 1 -type f -name '*.tsv' ! -name '*.debug.tsv' 2>/dev/null | head -n 1
}

echo "[a] sequential dispatch"
reset_logs
run
both_ran && ok "both hooks ran (rc 0)" || bad "$(run_detail)"
[ -d "$JOURNAL" ] && ok "journal directory is in use" \
  || bad "no journal directory: the timeout sentry is off here, so the fixture is not exercising the journal"
SESSION_TSV="$(session_journal)"
[ -n "$SESSION_TSV" ] && [ -s "$SESSION_TSV" ] && ok "the session journal has rows" \
  || bad "no session journal with rows in $JOURNAL"
no_dispatch_files "[a]"
[ -s "$STAMP" ] && ok "a new journal directory gets a sweep stamp, so its first sweep waits a full interval" \
  || bad "no sweep stamp at $STAMP"

if [ -n "$BASH51" ]; then
  echo "[b] parallel dispatch"
  reset_logs
  run_parallel
  both_ran && ok "both hooks ran in parallel ($BASH51)" || bad "$(run_detail)"
  no_dispatch_files "[b]"

  echo "[c] parallel dispatch in a journal directory that cannot be listed"
  # Mode 311: files in the directory can be made, opened and removed by name,
  # and the directory cannot be listed. A cleanup that finds the per-child
  # breadcrumbs with a glob sees none and leaves them behind.
  chmod 311 "$JOURNAL"
  if ls "$JOURNAL" >/dev/null 2>&1; then
    chmod 755 "$JOURNAL"
    echo "note: this host does not enforce directory read permission (root, or a Windows filesystem); [c] does not run, [g] still times the read"
  else
    reset_logs
    run_parallel
    chmod 755 "$JOURNAL"
    both_ran && ok "both hooks ran in parallel with the directory unlistable" || bad "$(run_detail)"
    no_dispatch_files "[c]"
  fi
fi

echo "[d] $FILES aged files and no sweep stamp: one dispatch cleans them"
reset_logs
rm -f "$STAMP"
old_session_groups=3000
old_dispatch_groups=$(( (FILES - old_session_groups * SESSION_GROUP) / DISPATCH_GROUP ))
old_session_files=$((old_session_groups * SESSION_GROUP))
old_dispatch_files=$((old_dispatch_groups * DISPATCH_GROUP))
plant session "$old_session_groups" aaaa "$SESSION_OLD"
plant dispatch "$old_dispatch_groups" bbbb "$DISPATCH_OLD"
plant session 2 cccc "$SESSION_RECENT"
plant dispatch 2 dddd "$DISPATCH_RECENT"
printf 'x\n' > "$JOURNAL/keep-me.txt"
mkdir -p "$JOURNAL/eeee.tsv.lock"
printf 'x\n' > "$JOURNAL/eeee.tsv.lock/pid"
age "$SESSION_OLD" "$JOURNAL/keep-me.txt" "$JOURNAL/eeee.tsv.lock/pid" "$JOURNAL/eeee.tsv.lock"
[ "$(count_tag aaaa)" = "$old_session_files" ] && [ "$(count_tag bbbb)" = "$old_dispatch_files" ] \
  || bad "fixture: planted $(count_tag aaaa) of $old_session_files session files and $(count_tag bbbb) of $old_dispatch_files dispatch files"
run
both_ran && ok "dispatch rc 0, both hooks ran" || bad "$(run_detail)"
[ "$(count_tag aaaa)" = "0" ] && ok "all $old_session_files per-session files older than 7 days removed" \
  || bad "$(count_tag aaaa) of $old_session_files per-session files older than 7 days left"
[ "$(count_tag bbbb)" = "0" ] && ok "all $old_dispatch_files per-dispatch files older than 60 minutes removed" \
  || bad "$(count_tag bbbb) of $old_dispatch_files per-dispatch files older than 60 minutes left"
[ "$(count_tag cccc)" = "$((2 * SESSION_GROUP))" ] && ok "per-session files 3 days old kept" \
  || bad "$(count_tag cccc) of $((2 * SESSION_GROUP)) per-session files 3 days old left"
[ "$(count_tag dddd)" = "$((2 * DISPATCH_GROUP))" ] && ok "per-dispatch files 10 minutes old kept (they may belong to a live dispatch)" \
  || bad "$(count_tag dddd) of $((2 * DISPATCH_GROUP)) per-dispatch files 10 minutes old left"
[ -e "$JOURNAL/keep-me.txt" ] && ok "an aged file with another name is kept" || bad "keep-me.txt was removed"
[ -f "$JOURNAL/eeee.tsv.lock/pid" ] && ok "an aged subdirectory is kept" || bad "the aged lock directory was removed"
[ -s "$STAMP" ] && ok "sweep stamp written" || bad "no sweep stamp at $STAMP"
remove_tag dddd

echo "[e] the cleanup is throttled by the stamp"
plant session 1 ffff "$SESSION_OLD"
run
[ "$(count_tag ffff)" = "$SESSION_GROUP" ] && ok "fresh stamp: the aged files stay, so the directory was not swept on this event" \
  || bad "fresh stamp: aged files were removed ($(count_tag ffff) of $SESSION_GROUP left), so the sweep runs on every event"
printf '1\n' > "$STAMP"
run
[ "$(count_tag ffff)" = "0" ] && ok "old stamp: the next dispatch removes the aged files" \
  || bad "old stamp: $(count_tag ffff) aged files are still there"
printf 'not-a-number\n' > "$STAMP"
plant session 1 gggg "$SESSION_OLD"
run
[ "$(count_tag gggg)" = "0" ] && ok "unreadable stamp: treated as due" || bad "unreadable stamp: $(count_tag gggg) aged files are still there"

echo "[f] a running session keeps its journal"
[ -n "$SESSION_TSV" ] && [ -s "$SESSION_TSV" ] && ok "the session journal survived the sweeps above" \
  || bad "the session journal was removed by a sweep"
if [ -n "$SESSION_TSV" ] && [ -f "$SESSION_TSV.meta" ]; then
  # A long session: the metadata file is written once and left alone while
  # its content is unchanged, so it can pass the age bound while the session
  # is still running. It is a cache: the next event writes it again.
  age "$SESSION_OLD" "$SESSION_TSV.meta"
  printf '1\n' > "$STAMP"
  run
  run
  [ -s "$SESSION_TSV.meta" ] && ok "a metadata file that aged out is written again by the session's next event" \
    || bad "the session has no metadata file after two more events"
  [ -s "$SESSION_TSV" ] && ok "the journal itself, written on every event, is kept" || bad "the session journal was removed"
else
  bad "fixture: no metadata file beside the session journal"
fi
remove_tag cccc

echo "[g] $FILES files too recent to remove do not slow a dispatch"
# min_ms <sequential|parallel>: fastest of five dispatches, in the C locale
# (the locale master-hook gives itself when the host sets none).
min_ms() {
  local i s e best=""
  for i in 1 2 3 4 5; do
    s="$(now_ms)"
    if [ "$1" = parallel ]; then run_parallel LC_ALL=C; else run LC_ALL=C; fi
    e="$(now_ms)"
    [ -n "$best" ] && [ "$best" -le $((e - s)) ] || best=$((e - s))
  done
  printf '%s' "$best"
}
SLOW_MARGIN_MS=250
timing_case() { # <sequential|parallel> <interpreter label>
  local clean big groups=$((FILES / SESSION_GROUP))
  remove_tag hhhh
  run
  clean="$(min_ms "$1")"
  plant session "$groups" hhhh 0
  big="$(min_ms "$1")"
  [ "$(count_tag hhhh)" = "$((groups * SESSION_GROUP))" ] \
    || bad "fixture: recent files were removed ($(count_tag hhhh) of $((groups * SESSION_GROUP)) left)"
  remove_tag hhhh
  if [ $((big - clean)) -le "$SLOW_MARGIN_MS" ]; then
    ok "$1, $2: ${big} ms with $FILES files, ${clean} ms without (limit +${SLOW_MARGIN_MS} ms)"
  else
    bad "$1, $2: ${big} ms with $FILES files, ${clean} ms without: the directory is read on every event (limit +${SLOW_MARGIN_MS} ms)"
  fi
}
[ -z "$BASH51" ] || timing_case parallel "$BASH51"
timing_case sequential "$TEST_BASH"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
