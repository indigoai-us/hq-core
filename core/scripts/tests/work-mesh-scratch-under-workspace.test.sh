#!/usr/bin/env bash
# hq-core: public
# Regression: the Work Mesh SessionStart hook and the trusted-bind script kept
# their observations, single-flight locks, pending queues and retry logs in the
# system temp folder and never removed them. On Windows that folder is the
# user's Temp, where the files piled up.
#
# Checks, under the shell running this test ("$BASH", so /bin/bash 3.2 on macOS
# really exercises 3.2):
#   1. every scratch file lands under <HQ_ROOT>/workspace/tmp/work-mesh/ and
#      nothing is written to TMPDIR;
#   2. an observation with no reader (no hq CLI) is removed at once;
#   3. a consumed observation, its pending entry and its lock are removed;
#   4. superseded pending observations in the hook's folder are removed, and a
#      path outside that folder is left alone;
#   5. the age sweep removes only day-old entries in its own folder, plus
#      day-old leftovers in the three TMPDIR folders earlier versions used;
#   6. a Windows-shaped (backslash) HQ_ROOT gets the same layout;
#   7. the trusted-bind script follows the same rules.
#
# Hermetic: temp HQ_ROOT and TMPDIR, a fresh temp HOME per run, stub hq CLI,
# no network. PATH never includes node's own folder: CI installs the pinned hq
# CLI there, so node is reached through a folder that holds only a node link.

set -uo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC_HOOK="$SOURCE_ROOT/core/hooks/SessionStart/35-work-mesh-session-start.sh"
SRC_BIND="$SOURCE_ROOT/core/scripts/work-mesh-live-bind-trusted.sh"
[ -f "$SRC_HOOK" ] || { echo "FATAL: missing $SRC_HOOK" >&2; exit 1; }
[ -f "$SRC_BIND" ] || { echo "FATAL: missing $SRC_BIND" >&2; exit 1; }
NODE_BIN="$(command -v node 2>/dev/null || true)"
[ -n "$NODE_BIN" ] || { echo "FATAL: node is required (the hook's bounded runner uses it)" >&2; exit 1; }

FAILURES=0
TMP="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FATAL: mktemp gave no folder" >&2; exit 1; }
TMP="$(cd "$TMP" && pwd -P)" || { echo "FATAL: cannot enter the temp folder" >&2; exit 1; }
[ -n "$TMP" ] && [ "$TMP" != / ] || { echo "FATAL: unusable temp folder" >&2; exit 1; }
WORKERS="$TMP/workers.pid"

cleanup() {
  local pid args
  if [ -f "$WORKERS" ]; then
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      args="$(ps -ww -p "$pid" -o args= 2>/dev/null || true)"
      case "$args" in *"$TMP"*|*_wm_reconcile_drain*) kill -TERM "$pid" 2>/dev/null || true ;; esac
    done <"$WORKERS"
  fi
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

# A day-old timestamp, built in pieces so no long digit run appears in source.
OLD_STAMP="2020""0101""0000"
# Pending queue entries are named by a zero-padded sequence number.
printf -v Q0 "%020d" 0
printf -v Q1 "%020d" 1

SYSTMP="$TMP/systmp"
HQ_LOG="$TMP/hq.log"
# node-bin holds only a node link, so no hq installed next to node is reachable.
NODE_ONLY_DIR="$TMP/node-bin"
mkdir -p "$SYSTMP" "$TMP/bin" "$TMP/nohq-bin" "$NODE_ONLY_DIR"
ln -s "$NODE_BIN" "$NODE_ONLY_DIR/node"

# fresh_home: a new empty HOME for one run, so no run reuses another's
# preflight cache or CLI state. Sets HOME_DIR.
HOME_SEQ=0
fresh_home() {
  HOME_SEQ=$((HOME_SEQ + 1))
  HOME_DIR="$TMP/home-$HOME_SEQ"
  mkdir -p "$HOME_DIR/.hq"
}

# assert_no_hq_on <path value>: stop if any hq is reachable on a no-hq PATH.
assert_no_hq_on() {
  local dir rest="$1:"
  while [ -n "$rest" ]; do
    dir="${rest%%:*}"
    rest="${rest#*:}"
    if [ -n "$dir" ] && [ -e "$dir/hq" ]; then
      echo "FATAL: the no-hq PATH reaches $dir/hq" >&2
      exit 1
    fi
  done
}
: >"$HQ_LOG"

# Stub hq CLI: records each call and, for a reconcile, whether the observation
# file existed when it was read.
cat >"$TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
printf 'call %s\n' "$*" >>"$TEST_HQ_LOG"
if [ "${1:-} ${2:-} ${3:-}" = "mesh context reconcile" ]; then
  prev=""
  for arg in "$@"; do
    if [ "$prev" = --observation-file ]; then
      if [ -f "$arg" ]; then printf 'read %s\n' "$arg" >>"$TEST_HQ_LOG"; else printf 'missing %s\n' "$arg" >>"$TEST_HQ_LOG"; fi
    fi
    prev=$arg
  done
fi
exit 0
STUB
chmod +x "$TMP/bin/hq"

# make_root <dir>: a minimal HQ root with the hook, the bind script and libs.
make_root() {
  mkdir -p "$1/core/hooks/SessionStart" "$1/core/scripts" "$1/workspace/sessions"
  cp -R "$SOURCE_ROOT/core/scripts/lib" "$1/core/scripts/lib"
  cp "$SRC_HOOK" "$1/core/hooks/SessionStart/"
  cp "$SRC_BIND" "$1/core/scripts/"
  cp "$SOURCE_ROOT/core/scripts/hq-session.sh" "$1/core/scripts/"
  if [ -f "$SOURCE_ROOT/core/hooks/SessionStart/preflight-fixtures.json" ]; then
    cp "$SOURCE_ROOT/core/hooks/SessionStart/preflight-fixtures.json" "$1/core/hooks/SessionStart/"
  fi
}

# run_hook <hq-root value> <session id> <with-hq|no-hq> [cwd]
run_hook() {
  local root="$1" sid="$2" mode="$3" cwd="${4:-$TMP}" path_value
  case "$mode" in
    with-hq) path_value="$TMP/bin:$NODE_ONLY_DIR:/usr/bin:/bin" ;;
    *) path_value="$TMP/nohq-bin:$NODE_ONLY_DIR:/usr/bin:/bin"; assert_no_hq_on "$path_value" ;;
  esac
  fresh_home
  printf '{"session_id":"%s","cwd":"%s"}' "$sid" "$TMP" >"$TMP/payload.json"
  (
    cd "$cwd" || exit 99
    env -u HQ_WORK_MESH_DISABLED -u HQ_DISABLED_HOOKS -u HQ_WORK_MESH_RECONCILE_STUB -u HQ_COMPANY \
      -u HQ_SPAWN_COMPANY -u HQ_ACTIVE_COMPANY -u HQ_WORK_CONTEXT_ROOT -u HQ_REGISTER_PENDING_DIR \
      -u HQ_WORK_MESH_RECONCILE_DIR -u HQ_WORK_MESH_RECONCILE_LOG \
      HQ_ROOT="$root" HOME="$HOME_DIR" TMPDIR="$SYSTMP" PATH="$path_value" \
      HQ_SESSION_ID="$sid" CLAUDE_CODE_SESSION_ID="$sid" WORK_MESH_SEQ_DIR="$TMP/mesh-seq" \
      HQ_WORK_MESH_RECONCILE_WORKER_PID_FILE="$WORKERS" TEST_HQ_LOG="$HQ_LOG" \
      "$BASH" "$root/core/hooks/SessionStart/35-work-mesh-session-start.sh" SessionStart \
      <"$TMP/payload.json" >/dev/null 2>"$TMP/hook.err"
  )
}

# wait_until <seconds> <command...>: polls every 0.1 s.
wait_until() {
  local limit=$(( $1 * 10 )) i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

no_json_in() { [ -z "$(find "$1" -name '*.json' 2>/dev/null | head -1)" ]; }
no_lock_in() { [ -z "$(find "$1" -name '*.lock' 2>/dev/null | head -1)" ]; }
# drained <scratch root> <session id>: its observations, queue entries and lock are gone.
drained() {
  [ -z "$(find "$1/obs" -name "$2.*" 2>/dev/null | head -1)" ] \
    && no_json_in "$1/reconcile/$2.pending" && [ ! -e "$1/reconcile/$2.lock" ]
}
read_count() { grep -c "^read .*/$1\\." "$HQ_LOG" 2>/dev/null || true; }

expect_systmp_clean() {
  local found
  found="$(find "$SYSTMP" -mindepth 1 ! -name 'hq-seeded-old.json' 2>/dev/null | head -5 | tr '\n' ' ')"
  if [ -z "$found" ]; then pass "$1: nothing written to TMPDIR"; else fail "$1: TMPDIR holds: $found"; fi
}

ROOT_A="$TMP/hq"
make_root "$ROOT_A"
SCRATCH_A="$ROOT_A/workspace/tmp/work-mesh"

echo "[1] no hq CLI: an observation nothing would read is not left anywhere"
run_hook "$ROOT_A" wm-scratch-nohq no-hq || fail "no-hq hook rc $?"
if [ -z "$(find "$ROOT_A/workspace" -name 'wm-scratch-nohq.*' 2>/dev/null | head -1)" ]; then
  pass "no unread observation left under workspace/"
else
  fail "unread observation left: $(find "$ROOT_A/workspace" -name 'wm-scratch-nohq.*' | tr '\n' ' ')"
fi
expect_systmp_clean "no hq CLI"

echo "[2] hq CLI present: observation is read, then removed with its queue entry and lock"
# Seed the sweep's inputs. Contents are backdated before their folders, because
# removing or adding an entry refreshes the folder's own time.
mkdir -p "$SCRATCH_A/obs" "$SCRATCH_A/reconcile/old-sid.lock" "$SCRATCH_A/reconcile/old-sid.pending" \
  "$SCRATCH_A/reconcile/old-queue.pending" "$SCRATCH_A/register-pending/old-co.lock" \
  "$ROOT_A/workspace/tmp/other" "$ROOT_A/workspace/sessions/keep"
printf '{}\n' >"$SCRATCH_A/obs/crashed-sid.1.json"
printf '{}\n' >"$SCRATCH_A/obs/crashed-sid.bind.4242.json"
printf '{}\n' >"$SCRATCH_A/obs/fresh-sid.1.json"
printf '1\n' >"$SCRATCH_A/reconcile/old-sid.lock/pid"
printf '%s\n' "$SCRATCH_A/obs/nothing.json" >"$SCRATCH_A/reconcile/old-queue.pending/${Q1}.op.json"
printf '1\n' >"$SCRATCH_A/register-pending/old-co.lock/pid"
printf 'log\n' >"$SCRATCH_A/register-pending/old-co.log"
printf '{}\n' >"$ROOT_A/workspace/tmp/other/old.json"
printf '{}\n' >"$ROOT_A/workspace/sessions/keep/old.json"
printf '{}\n' >"$SYSTMP/hq-seeded-old.json"
touch -t "$OLD_STAMP" "$SCRATCH_A/obs/crashed-sid.1.json" "$SCRATCH_A/obs/crashed-sid.bind.4242.json" \
  "$SCRATCH_A/reconcile/old-sid.lock/pid" "$SCRATCH_A/reconcile/old-queue.pending/${Q1}.op.json" \
  "$SCRATCH_A/register-pending/old-co.lock/pid" "$SCRATCH_A/register-pending/old-co.log" \
  "$ROOT_A/workspace/tmp/other/old.json" "$ROOT_A/workspace/sessions/keep/old.json" "$SYSTMP/hq-seeded-old.json"
touch -t "$OLD_STAMP" "$SCRATCH_A/reconcile/old-sid.lock" "$SCRATCH_A/reconcile/old-sid.pending" \
  "$SCRATCH_A/reconcile/old-queue.pending" "$SCRATCH_A/register-pending/old-co.lock"

run_hook "$ROOT_A" wm-scratch-hq with-hq || fail "with-hq hook rc $?"
wait_until 15 drained "$SCRATCH_A" wm-scratch-hq >/dev/null 2>&1 || true
# The sweep runs after the drainer releases its lock; .swept marks its end.
swept() { [ -f "$SCRATCH_A/.swept" ]; }
wait_until 15 swept >/dev/null 2>&1 || fail "the sweep never finished (no .swept stamp)"
reads="$(read_count wm-scratch-hq)"
if [ "$reads" -ge 2 ]; then
  pass "observation read by the preflight and by the detached reconcile ($reads reads)"
else
  fail "expected 2 reads of the observation, got $reads: $(tr '\n' '|' <"$HQ_LOG")"
fi
if ! grep -q '^missing ' "$HQ_LOG"; then pass "no reconcile saw a missing observation"; else fail "a reconcile ran after its observation was removed"; fi
if [ -z "$(find "$SCRATCH_A/obs" -name "wm-scratch-hq.*" | head -1)" ]; then
  pass "consumed observation removed"
else
  fail "consumed observation left: $(find "$SCRATCH_A/obs" -type f | tr '\n' ' ')"
fi
if [ -z "$(find "$SCRATCH_A/reconcile/wm-scratch-hq.pending" -type f 2>/dev/null | head -1)" ]; then pass "pending queue entry removed"; else fail "pending queue entry left"; fi
if [ ! -e "$SCRATCH_A/reconcile/wm-scratch-hq.lock" ]; then pass "single-flight lock released"; else fail "single-flight lock left"; fi
expect_systmp_clean "hq CLI present"

echo "[3] the age sweep removes only day-old entries in its own folder"
for gone in obs/crashed-sid.1.json obs/crashed-sid.bind.4242.json reconcile/old-sid.lock reconcile/old-sid.pending \
  reconcile/old-queue.pending/${Q1}.op.json register-pending/old-co.lock register-pending/old-co.log; do
  if [ ! -e "$SCRATCH_A/$gone" ]; then pass "sweep removed day-old $gone"; else fail "sweep left day-old $gone"; fi
done
if [ -f "$SCRATCH_A/obs/fresh-sid.1.json" ]; then pass "sweep kept a recent observation"; else fail "sweep removed a recent observation"; fi
if [ -f "$ROOT_A/workspace/tmp/other/old.json" ]; then pass "sweep left another workspace/tmp folder alone"; else fail "sweep reached outside its folder (workspace/tmp/other)"; fi
if [ -f "$ROOT_A/workspace/sessions/keep/old.json" ]; then pass "sweep left workspace/sessions alone"; else fail "sweep reached workspace/sessions"; fi
if [ -f "$SYSTMP/hq-seeded-old.json" ]; then pass "sweep left TMPDIR alone"; else fail "sweep reached TMPDIR"; fi

echo "[3a] the sweep runs at most once an hour"
printf '{}\n' >"$SCRATCH_A/obs/second-crash.1.json"
touch -t "$OLD_STAMP" "$SCRATCH_A/obs/second-crash.1.json"
run_hook "$ROOT_A" wm-scratch-rate with-hq || fail "rate-limit hook rc $?"
wait_until 15 drained "$SCRATCH_A" wm-scratch-rate >/dev/null 2>&1 || true
sleep 1
if [ -f "$SCRATCH_A/obs/second-crash.1.json" ]; then pass "a sweep within the hour is skipped"; else fail "the sweep ran again within the hour"; fi
rm -f "$SCRATCH_A/obs/second-crash.1.json"

echo "[3b] the sweep also clears day-old leftovers of earlier versions in TMPDIR, and nothing else there"
# hq-work-mesh-obs: a real folder this user owns, with old and recent entries.
# hq-register-pending: an empty, day-old real folder.
# hq-work-mesh-reconcile: a symlink to another folder; the sweep must not follow it.
mkdir -p "$SYSTMP/hq-work-mesh-obs/old-sid.lock" "$SYSTMP/hq-register-pending" "$SYSTMP/unrelated" \
  "$TMP/link-target/old-sid.lock"
printf '{}\n' >"$SYSTMP/hq-work-mesh-obs/old-sid.1.json"
printf '{}\n' >"$SYSTMP/hq-work-mesh-obs/young-sid.1.json"
printf '1\n' >"$SYSTMP/hq-work-mesh-obs/old-sid.lock/pid"
printf '{}\n' >"$SYSTMP/unrelated/old.json"
printf '{}\n' >"$TMP/link-target/old.json"
printf '1\n' >"$TMP/link-target/old-sid.lock/pid"
ln -s "$TMP/link-target" "$SYSTMP/hq-work-mesh-reconcile"
touch -t "$OLD_STAMP" "$SYSTMP/hq-work-mesh-obs/old-sid.1.json" "$SYSTMP/hq-work-mesh-obs/old-sid.lock/pid" \
  "$SYSTMP/unrelated/old.json" "$TMP/link-target/old.json" "$TMP/link-target/old-sid.lock/pid"
touch -t "$OLD_STAMP" "$SYSTMP/hq-work-mesh-obs/old-sid.lock" "$SYSTMP/hq-register-pending" "$SYSTMP/unrelated" \
  "$TMP/link-target/old-sid.lock"
rm -f "$SCRATCH_A/.swept"
run_hook "$ROOT_A" wm-scratch-legacy with-hq || fail "legacy-sweep hook rc $?"
wait_until 15 drained "$SCRATCH_A" wm-scratch-legacy >/dev/null 2>&1 || true
wait_until 15 swept >/dev/null 2>&1 || fail "the legacy sweep never finished (no .swept stamp)"
if [ ! -e "$SYSTMP/hq-work-mesh-obs/old-sid.1.json" ]; then pass "legacy day-old observation removed"; else fail "legacy day-old observation left"; fi
if [ ! -e "$SYSTMP/hq-work-mesh-obs/old-sid.lock" ]; then pass "legacy day-old lock removed"; else fail "legacy day-old lock left"; fi
if [ ! -e "$SYSTMP/hq-register-pending" ]; then pass "empty day-old legacy folder removed"; else fail "empty day-old legacy folder left"; fi
if [ -f "$SYSTMP/hq-work-mesh-obs/young-sid.1.json" ]; then pass "legacy recent observation kept"; else fail "legacy recent observation removed"; fi
if [ -f "$TMP/link-target/old.json" ] && [ -d "$TMP/link-target/old-sid.lock" ] && [ -L "$SYSTMP/hq-work-mesh-reconcile" ]; then
  pass "a symlinked legacy folder is not followed"
else
  fail "the sweep followed a symlinked legacy folder"
fi
if [ -f "$SYSTMP/unrelated/old.json" ] && [ -f "$SYSTMP/hq-seeded-old.json" ]; then
  pass "sweep left other TMPDIR entries alone"
else
  fail "sweep removed TMPDIR entries it does not own"
fi
rm -rf "$SYSTMP/hq-work-mesh-obs" "$SYSTMP/hq-work-mesh-reconcile" "$SYSTMP/hq-register-pending" "$SYSTMP/unrelated"

echo "[4] superseded pending observations are removed; paths outside the folder are not"
SID_C=wm-scratch-superseded
mkdir -p "$SCRATCH_A/reconcile/$SID_C.pending"
printf '{}\n' >"$SCRATCH_A/obs/$SID_C.old.json"
printf '{}\n' >"$TMP/outside-observation.json"
printf '%s\n' "$SCRATCH_A/obs/$SID_C.old.json" >"$SCRATCH_A/reconcile/$SID_C.pending/${Q0}.a.json"
printf '%s\n' "$TMP/outside-observation.json" >"$SCRATCH_A/reconcile/$SID_C.pending/${Q0}.b.json"
run_hook "$ROOT_A" "$SID_C" with-hq || fail "superseded hook rc $?"
wait_until 15 drained "$SCRATCH_A" "$SID_C" >/dev/null 2>&1 || true
if [ ! -e "$SCRATCH_A/obs/$SID_C.old.json" ]; then pass "superseded observation removed"; else fail "superseded observation left"; fi
if [ -f "$TMP/outside-observation.json" ]; then pass "a queued path outside the observation folder is never removed"; else fail "drainer removed a file outside its observation folder"; fi
if ! grep -q "^read .*$SID_C.old.json" "$HQ_LOG"; then pass "only the newest observation was reconciled"; else fail "a superseded observation was reconciled"; fi
expect_systmp_clean "superseded queue"

echo "[5] backslash (Windows-shaped) HQ_ROOT"
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    WIN_DIR="$TMP/winroot"
    make_root "$WIN_DIR"
    WIN_ROOT="$(cygpath -w "$WIN_DIR")"
    WIN_CWD="$TMP"
    ;;
  *)
    # A backslash is an ordinary file name character here, so the root is a
    # relative folder named C:\hq inside RUN_DIR, entered as the cwd.
    WIN_CWD="$TMP/run"
    WIN_ROOT='C:\hq'
    WIN_DIR="$WIN_CWD/$WIN_ROOT"
    mkdir -p "$WIN_CWD"
    make_root "$WIN_DIR"
    ;;
esac
run_hook "$WIN_ROOT" wm-scratch-win with-hq "$WIN_CWD" || fail "backslash-root hook rc $?"
wait_until 15 drained "$WIN_DIR/workspace/tmp/work-mesh" wm-scratch-win >/dev/null 2>&1 || true
if [ -d "$WIN_DIR/workspace/tmp/work-mesh/obs" ]; then pass "backslash root: scratch folder under the root's workspace/"; else fail "backslash root: no scratch folder under workspace/"; fi
if [ "$(read_count wm-scratch-win)" -ge 2 ]; then pass "backslash root: observation read twice"; else fail "backslash root: observation not read twice: $(tr '\n' '|' <"$HQ_LOG")"; fi
if no_json_in "$WIN_DIR/workspace/tmp/work-mesh/obs" && no_lock_in "$WIN_DIR/workspace/tmp/work-mesh/reconcile"; then
  pass "backslash root: observation and lock removed"
else
  fail "backslash root: left $(find "$WIN_DIR/workspace/tmp/work-mesh" -type f | tr '\n' ' ')"
fi
expect_systmp_clean "backslash root"

echo "[6] trusted-bind script"
run_bind() {
  local mode="$1" path_value
  shift
  case "$mode" in
    with-hq) path_value="$TMP/bin:$NODE_ONLY_DIR:/usr/bin:/bin" ;;
    *) path_value="$TMP/nohq-bin:$NODE_ONLY_DIR:/usr/bin:/bin"; assert_no_hq_on "$path_value" ;;
  esac
  fresh_home
  env -u HQ_WORK_MESH_RECONCILE_LOG -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID \
    HQ_ROOT="$ROOT_A" CLAUDE_PROJECT_DIR="$ROOT_A" HOME="$HOME_DIR" TMPDIR="$SYSTMP" PATH="$path_value" \
    HQ_HQ_SESSION_NO_CLI=1 TEST_HQ_LOG="$HQ_LOG" "$@" \
    "$BASH" "$ROOT_A/core/scripts/work-mesh-live-bind-trusted.sh" --session wm-scratch-bind --root "$ROOT_A" \
    >/dev/null 2>"$TMP/bind.err"
}
bind_obs() { find "$SCRATCH_A/obs" -name 'wm-scratch-bind.bind.*.json' 2>/dev/null | head -1; }

run_bind no-hq HQ_WORK_MESH_RECONCILE_STUB=0 || fail "bind without hq rc $?"
if grep -q 'hq CLI not found' "$TMP/bind.err"; then pass "bind without hq reports the skip"; else fail "bind without hq did not report the skip"; fi
if [ -z "$(bind_obs)" ]; then pass "bind without hq removes its unread observation"; else fail "bind without hq left $(bind_obs)"; fi

run_bind with-hq HQ_WORK_MESH_RECONCILE_STUB=0 || fail "bind with hq rc $?"
bind_gone() { [ -z "$(bind_obs)" ] && grep -q '^read .*wm-scratch-bind\.bind\.' "$HQ_LOG"; }
if wait_until 10 bind_gone; then pass "bind: reconcile read the observation, then it was removed"; else fail "bind: observation not read-then-removed (left: $(bind_obs))"; fi

run_bind with-hq HQ_WORK_MESH_RECONCILE_STUB=1 || fail "bind stub rc $?"
case "$(bind_obs)" in
  "$SCRATCH_A/obs/"*) pass "bind writes its observation under workspace/tmp/work-mesh/obs" ;;
  *) fail "bind observation not under workspace/tmp/work-mesh/obs" ;;
esac
expect_systmp_clean "trusted bind"

if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASS: work-mesh-scratch-under-workspace"
  exit 0
fi
echo "$FAILURES failure(s)" >&2
exit 1
