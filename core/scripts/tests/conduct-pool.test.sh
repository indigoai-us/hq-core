#!/usr/bin/env bash
# conduct-pool.test.sh — behavioural coverage for core/scripts/conduct-pool.sh,
# the session worker pool behind /conduct.
#
# The pool's whole job is a cap that cannot be walked past by accident, so the
# cases that matter are the boundaries: the second task for a known worker must
# resume rather than start a new lane, a ninth worker must cost an idle slot,
# and a ninth worker with nothing idle to retire must fail loudly and change
# nothing. The last test pins the storage decision itself — the pool must never
# round-trip through `hq-session.sh set`, which only replaces single-line
# scalars and would silently flatten the list.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok — $1"; }

assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3: missing '$2' in: $1" ;;
  esac
}

mkdir -p "$TMP/core/scripts/lib" "$TMP/workspace/sessions"
cp "$ROOT/core/scripts/conduct-pool.sh" "$TMP/core/scripts/"
cp "$ROOT/core/scripts/lib/session-id.sh" "$TMP/core/scripts/lib/"
chmod +x "$TMP/core/scripts/conduct-pool.sh"

# A booby-trapped hq-session.sh next to the script under test: if conduct-pool.sh
# ever shells out to it, the call is loud instead of silent.
cat > "$TMP/core/scripts/hq-session.sh" <<'TRAP'
#!/usr/bin/env bash
echo "hq-session.sh must not be called by conduct-pool.sh (args: $*)" >&2
exit 97
TRAP
chmod +x "$TMP/core/scripts/hq-session.sh"

export HQ_ROOT="$TMP"
unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID || true

SID="test-session"
META="$TMP/workspace/sessions/$SID/meta.yaml"
pool() { "$TMP/core/scripts/conduct-pool.sh" --session-id "$SID" "$@"; }
reset_pool() { rm -rf "$TMP/workspace/sessions/$SID"; }
slot_count() { grep -c '^  - worker_id:' "$META" 2>/dev/null || echo 0; }

echo "conduct-pool: assign spawns then resumes"
reset_pool
out="$(pool assign --worker-id backend-dev --task 'implement the thing')"
assert_contains "$out" '"action":"spawn"' "first assign"
assert_contains "$out" '"worker_id":"backend-dev"' "first assign names the worker"
pool record --worker-id backend-dev --subagent-id lane-0001 --status idle
out="$(pool assign --worker-id backend-dev --task 'now fix the test')"
assert_contains "$out" '"action":"resume"' "second assign"
assert_contains "$out" '"subagent_id":"lane-0001"' "resume carries the recorded lane id"
assert_eq "$(slot_count)" "1" "one worker means one slot"
ok "spawn then resume, one slot"

echo "conduct-pool: state is a readable YAML list on session meta"
assert_contains "$(cat "$META")" "conduct_pool:" "meta has the list key"
assert_contains "$(cat "$META")" 'last_task: "now fix the test"' "meta keeps the last task"
out="$(pool list)"
assert_contains "$out" '"worker_id":"backend-dev"' "list names the worker"
assert_contains "$out" '"status":"running"' "list reports status"
ok "conduct_pool list round-trips through meta.yaml"

echo "conduct-pool: an unrelated meta key survives a pool write"
reset_pool
mkdir -p "$(dirname "$META")"
printf 'session_id: %s\ncompany_slug: acme\n' "$SID" > "$META"
pool assign --worker-id backend-dev >/dev/null
assert_contains "$(cat "$META")" "company_slug: acme" "sibling key preserved"
pool clear
assert_contains "$(cat "$META")" "company_slug: acme" "sibling key survives clear"
case "$(cat "$META")" in
  *conduct_pool:*) fail "clear left the pool block behind" ;;
esac
ok "pool writes leave the rest of meta.yaml alone"

echo "conduct-pool: a ninth worker retires the least-recently-used idle slot"
reset_pool
for i in 1 2 3 4 5 6 7 8; do
  pool assign --worker-id "worker-$i" >/dev/null
  pool record --worker-id "worker-$i" --subagent-id "lane-$i" --status idle
done
assert_eq "$(slot_count)" "8" "eight slots before the ninth"
out="$(pool assign --worker-id worker-9)"
assert_contains "$out" '"action":"spawn"' "ninth worker spawns"
assert_contains "$out" '"recycled":"worker-1"' "the LRU idle slot is the one retired"
assert_contains "$(pool list)" '"worker_id":"worker-1","subagent_id":"","status":"recycled"' \
  "retired slot keeps its name, loses its lane id"
assert_eq "$(slot_count)" "9" "the tombstone stays listed"
live="$(pool list | grep -c '"status":"running"\|"status":"idle"')"
assert_eq "$live" "8" "live slots still capped at 8"
ok "cap recycles the LRU idle slot"

echo "conduct-pool: a full pool with nothing idle fails loudly and changes nothing"
reset_pool
for i in 1 2 3 4 5 6 7 8; do
  pool assign --worker-id "worker-$i" >/dev/null
done
before="$(cat "$META")"
set +e
out="$(pool assign --worker-id worker-9 2>&1)"
code=$?
set -e
[ "$code" -ne 0 ] || fail "cap-full assign should exit non-zero, got 0"
assert_eq "$code" "3" "cap-full exit code"
assert_contains "$out" "pool is full at cap 8" "cap-full message"
assert_contains "$out" "worker-1" "cap-full message names the live workers"
assert_eq "$(cat "$META")" "$before" "cap-full assign must not touch meta.yaml"
assert_eq "$(slot_count)" "8" "still eight slots"
ok "cap-full assign refuses and leaves state untouched"

echo "conduct-pool: recycle frees a slot for the next worker"
pool recycle --worker-id worker-3
out="$(pool assign --worker-id worker-9)"
assert_contains "$out" '"action":"spawn"' "assign succeeds once a slot is freed"
ok "explicit recycle makes room"

echo "conduct-pool: a worker whose lane is still running is not resumable"
reset_pool
pool assign --worker-id backend-dev --task 'first task' >/dev/null
pool record --worker-id backend-dev --subagent-id lane-live --status running
before="$(cat "$META")"
set +e
out="$(pool assign --worker-id backend-dev --task 'second task' 2>&1)"
code=$?
set -e
assert_eq "$code" "4" "assign on a running worker"
assert_contains "$out" "already has a lane running" "busy message"
assert_contains "$out" "lane-live" "busy message names the live run id"
assert_eq "$(cat "$META")" "$before" "a refused assign must not touch meta.yaml"
pool record --worker-id backend-dev --subagent-id lane-live --status idle
assert_contains "$(pool assign --worker-id backend-dev)" '"action":"resume"' "idle again means resumable"
ok "only idle slots resume; a live lane is never relaunched over"

echo "conduct-pool: concurrent assigns cannot approve more spawns than the cap"
# Repeated on purpose: one clean interleaving proves nothing about a race. The
# unlocked version passed single runs and still let twelve concurrent processes
# each approve a spawn against a cap of eight, keeping one slot on disk.
mkdir -p "$TMP/race"
for round in 1 2 3 4 5; do
  reset_pool
  rm -f "$TMP/race"/*
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    (
      set +e
      o="$(pool assign --worker-id "racer-$i" 2>&1)"
      printf '%s|%s\n' "$?" "$o" > "$TMP/race/$i"
    ) &
  done
  wait
  spawns=0
  refused=0
  for f in "$TMP/race"/*; do
    # Only the first line carries the exit code; a refusal's message follows it.
    c="$(head -1 "$f" | cut -d'|' -f1)"
    case "$c" in
      0) spawns=$((spawns + 1)) ;;
      3) refused=$((refused + 1)) ;;
      *) fail "round $round: unexpected assign exit $c ($(cat "$f"))" ;;
    esac
  done
  assert_eq "$spawns" "8" "round $round: spawns approved"
  assert_eq "$refused" "4" "round $round: cap-full refusals"
  assert_eq "$(slot_count)" "8" "round $round: slots actually recorded"
  assert_eq "$(pool list | grep -c '"status":"running"')" "8" "round $round: live slots"
done
ok "12 concurrent assigns against cap 8 yield exactly 8 spawns, over 5 rounds"

echo "conduct-pool: CONDUCT_POOL_CAP overrides the default"
reset_pool
CONDUCT_POOL_CAP=2 pool assign --worker-id a >/dev/null
CONDUCT_POOL_CAP=2 pool assign --worker-id b >/dev/null
set +e
CONDUCT_POOL_CAP=2 pool assign --worker-id c >/dev/null 2>&1
code=$?
set -e
assert_eq "$code" "3" "cap 2 is enforced"
ok "CONDUCT_POOL_CAP is honoured"

echo "conduct-pool: record refuses a worker that never went through assign"
reset_pool
set +e
out="$(pool record --worker-id ghost --subagent-id lane-x --status idle 2>&1)"
code=$?
set -e
[ "$code" -ne 0 ] || fail "record on an unknown worker should fail"
assert_contains "$out" "assign" "record error points at assign"
ok "record cannot insert around the cap"

echo "conduct-pool: ids are validated, not invented"
reset_pool
set +e
out="$(pool assign --worker-id 'bad id' 2>&1)"
code=$?
set -e
[ "$code" -ne 0 ] || fail "an invalid worker id should be rejected"
assert_contains "$out" "--worker-id" "invalid id message names the flag"
[ ! -f "$META" ] || fail "a rejected id must not create pool state"
ok "invalid worker ids are rejected"

echo "conduct-pool: free-text task labels cannot break the YAML or the JSON"
reset_pool
pool assign --worker-id backend-dev --task 'fix "quoted" \and\ multi
line' >/dev/null
assert_contains "$(cat "$META")" 'last_task: "fix quoted and multi line"' "task sanitized in YAML"
assert_contains "$(pool list)" '"last_task":"fix quoted and multi line"' "task sanitized in JSON"
ok "task text is sanitized on the way in"

echo "conduct-pool: the pool is never persisted through hq-session.sh set"
# The header comment explains WHY the pool avoids hq-session.sh, so only
# executable lines are checked for a call.
if sed -e 's/#.*$//' "$TMP/core/scripts/conduct-pool.sh" | grep -q "hq-session"; then
  fail "conduct-pool.sh calls hq-session.sh — its cmd_set cannot round-trip a nested list"
fi
reset_pool
pool assign --worker-id backend-dev >/dev/null
pool record --worker-id backend-dev --subagent-id lane-1 --status idle
pool list >/dev/null
ok "no scalar-set path, and the trap script was never triggered"

echo
echo "conduct-pool.test.sh: $PASS checks passed"
