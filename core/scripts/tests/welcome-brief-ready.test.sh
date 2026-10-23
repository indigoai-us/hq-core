#!/usr/bin/env bash
# Cases for the once-per-person welcome-brief SessionStart hook.
# Every case uses a temp HOME and a temp HQ root. Nothing touches the real ~/.hq.

set -euo pipefail

BASH_BIN="${BASH_BIN:-bash}"
# Absolute path so a case that empties PATH can still start the interpreter.
case "$BASH_BIN" in
  /*) ;;
  *) BASH_BIN="$(command -v "$BASH_BIN")" || { printf 'FAIL: bash not found\n' >&2; exit 1; } ;;
esac
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/welcome-brief-ready.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/welcome-brief-ready.XXXXXX")"
trap 'chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Git Bash ln -s copies the target unless MSYS asks for a native link. A copy
# sits inside the HQ root, so the symlink cases would test nothing. nativestrict
# makes ln -s fail instead of copying.
case "${OSTYPE:-}" in
  msys*|cygwin*|mingw*) export MSYS="${MSYS:+${MSYS} }winsymlinks:nativestrict" ;;
esac

[ -x "$HOOK" ] || fail "hook is not executable: $HOOK"
command -v jq >/dev/null 2>&1 || fail "jq is required"

SENTENCE='Your welcome brief is ready. [Open your welcome brief](hq://brief). See your files: [Open your files](hq://vault).'
INSTRUCTION='Show that sentence to the person in your first reply.'
EXPECTED="${SENTENCE}
${INSTRUCTION}"

# ln -s, then check a real link was made.
make_link() {
  ln -s "$1" "$2" || fail "ln -s $1 $2 failed"
  [ -L "$2" ] || fail "ln -s made a copy, not a link: $2"
}

# Git Bash ignores chmod on a directory, and an elevated Git Bash opens files
# with backup intent, so a deny ACL does not stop it either. On Windows the
# directory is replaced by a plain file, which no writer can create files
# under. The probe write fails the case if the path still accepts files.
is_windows=0
case "${OSTYPE:-}" in
  msys*|cygwin*|mingw*) is_windows=1 ;;
esac
deny_writes() {
  if [ "$is_windows" -eq 1 ]; then
    rmdir "$1" || fail "deny_writes: $1 is not an empty dir"
    : >"$1"
  else
    chmod 555 "$1"
  fi
  if ( : >"$1/.write-probe" ) 2>/dev/null; then
    fail "could not make $1 unwritable"
  fi
}
allow_writes() {
  if [ "$is_windows" -eq 1 ]; then
    rm -f "$1"
    mkdir "$1"
  else
    chmod 755 "$1"
  fi
}

new_home() {
  local home="$TMP/home-$1"
  mkdir -p "$home"
  printf '%s' "$home"
}

new_root() {
  local root="$TMP/hq-$1"
  mkdir -p "$root/workspace/brief"
  printf '%s' "$root"
}

write_run() {
  local root="$1" id="$2" state="$3" welcome="$4"
  mkdir -p "$root/workspace/brief/$id"
  if [ "$welcome" = "yes" ]; then
    jq -cn --arg id "$id" '{run_id:$id,welcome:{title:"Welcome"}}' \
      >"$root/workspace/brief/$id/brief.json"
  else
    jq -cn --arg id "$id" '{run_id:$id,lead:"daily"}' \
      >"$root/workspace/brief/$id/brief.json"
  fi
  jq -cn --arg state "$state" '{state:$state}' \
    >"$root/workspace/brief/$id/status.json"
}

# Real index schema from daily-brief: no welcome, kind, or type field.
# The welcome block lives only in brief.json.
index_line() {
  local id="$1" state="${2:-ready}"
  jq -cn --arg id "$id" --arg state "$state" \
    '{run_id:$id,created_at:"2026-01-01T00:00:00Z",finished_at:"2026-01-01T00:01:00Z",duration_s:1,window:{from:"2026-01-01",to:"2026-01-02"},state:$state,mode:"personal",company:null,catch_up:false,lead:"Daily",counts:{decisions:0,shipped:0,incidents:0,carry:0,recovered:0},landed:false,headline:"one plain line"}'
}

# Session-principal inputs are cleared so the runner's own env cannot make a
# case look like an agent or bot. HQ_AGENT_ROOT_PREFIX points at an empty dir
# so a real /var/lib/hq-agent identity on the runner is not read either.
PRINCIPAL_UNSET=(-u HQ_SESSION_PRINCIPAL -u HQ_AGENT_WORKDIR -u HQ_AGENT_COMPANY_DIR
  -u HQ_AGENT_IDENTITY_FILE -u HQ_BOT_AGENT_UID -u HQ_MACHINE_CREDS_FILE
  -u HQ_DISABLED_HOOKS -u HQ_HOOK_PROFILE -u HQ_CHECKPOINT_SIBLING -u HQ_LANE_ID)
NO_AGENT_ROOT="$TMP/no-agent-root"
mkdir -p "$NO_AGENT_ROOT"

invoke() {
  local home="$1" root="$2" payload="$3"
  shift 3
  OUT_FILE="$TMP/stdout"
  ERR_FILE="$TMP/stderr"
  set +e
  env -u BASH_ENV -u ENV -u HQ_WELCOME_BRIEF_HOOK "${PRINCIPAL_UNSET[@]}" \
    HOME="$home" CLAUDE_PROJECT_DIR="$root" HQ_AGENT_ROOT_PREFIX="$NO_AGENT_ROOT" \
    "$@" \
    "$BASH_BIN" "$HOOK" >"$OUT_FILE" 2>"$ERR_FILE" <<<"$payload"
  RC=$?
  set -e
  OUT="$(cat "$OUT_FILE")"
  ERR="$(cat "$ERR_FILE")"
}

assert_silent_clean() {
  local label="$1" home="$2"
  [ "$RC" -eq 0 ] || fail "$label: exit $RC"
  [ -z "$OUT" ] || fail "$label: expected no stdout, got: $OUT"
  [ -z "$ERR" ] || fail "$label: expected no stderr, got: $ERR"
  [ ! -e "$home/.hq/onboarding/welcome-brief-announced" ] || fail "$label: wrote the marker"
}

assert_no_none_marker() {
  local label="$1" home="$2" found=""
  if [ -d "$home/.hq/onboarding" ]; then
    found="$(find "$home/.hq/onboarding" -name 'welcome-brief-checked-none*' -print)"
  fi
  [ -z "$found" ] || fail "$label: wrote checked-none ($found)"
}

# The single checked-none file holds exactly this run id, with no temp left.
assert_checked_none() {
  local label="$1" home="$2" id="$3" file extra
  file="$home/.hq/onboarding/welcome-brief-checked-none"
  [ -f "$file" ] || fail "$label: checked-none marker missing"
  jq -e --arg id "$id" '. == {run_id:$id}' "$file" >/dev/null \
    || fail "$label: checked-none JSON is wrong: $(cat "$file")"
  extra="$(find "$home/.hq/onboarding" -name 'welcome-brief-checked-none?*' -print)"
  [ -z "$extra" ] || fail "$label: extra checked-none files ($extra)"
}

assert_announced() {
  local label="$1" home="$2" id="$3" context at got
  [ "$RC" -eq 0 ] || fail "$label: exit $RC"
  [ -z "$ERR" ] || fail "$label: expected no stderr, got: $ERR"
  context="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')" || fail "$label: stdout is not the hook JSON"
  # jq.exe -r writes CRLF. The sentence itself stays LF.
  context="${context//$'\r'/}"
  [ "$context" = "$EXPECTED" ] || fail "$label: context mismatch: [$context]"
  got="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')"
  got="${got//$'\r'/}"
  [ "$got" = "SessionStart" ] || fail "$label: hookEventName=$got"
  [ -f "$home/.hq/onboarding/welcome-brief-announced" ] || fail "$label: marker missing"
  jq -e --arg id "$id" '.run_id == $id and (.at | type == "string") and (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
    "$home/.hq/onboarding/welcome-brief-announced" >/dev/null \
    || fail "$label: marker JSON is wrong: $(cat "$home/.hq/onboarding/welcome-brief-announced")"
}

PAYLOAD='{"hook_event_name":"SessionStart","source":"startup","session_id":"s-test"}'

echo "[1] ready welcome briefs announce the oldest"
HOME1="$(new_home ready)"
ROOT1="$(new_root ready)"
write_run "$ROOT1" brief-20260101-000000 ready yes
write_run "$ROOT1" brief-20260102-000000 ready yes
{
  index_line brief-20260101-000000 ready
  index_line brief-20260102-000000 ready
} >"$ROOT1/workspace/brief/index.jsonl"
grep -q '"welcome"' "$ROOT1/workspace/brief/index.jsonl" && fail "index fixture must not carry a welcome field"
invoke "$HOME1" "$ROOT1" "$PAYLOAD"
assert_announced "ready" "$HOME1" brief-20260101-000000

echo "[2] second run is silent and does not rewrite the marker"
BEFORE="$(cat "$HOME1/.hq/onboarding/welcome-brief-announced")"
write_run "$ROOT1" brief-20260103-000000 ready yes
index_line brief-20260103-000000 ready >>"$ROOT1/workspace/brief/index.jsonl"
invoke "$HOME1" "$ROOT1" "$PAYLOAD"
[ "$RC" -eq 0 ] || fail "second run: exit $RC"
[ -z "$OUT" ] || fail "second run: expected no stdout, got: $OUT"
[ -z "$ERR" ] || fail "second run: expected no stderr, got: $ERR"
AFTER="$(cat "$HOME1/.hq/onboarding/welcome-brief-announced")"
[ "$BEFORE" = "$AFTER" ] || fail "second run rewrote the marker"

echo "[3] source=resume is silent"
HOME3="$(new_home resume)"
ROOT3="$(new_root resume)"
write_run "$ROOT3" brief-20260101-000000 ready yes
index_line brief-20260101-000000 ready >"$ROOT3/workspace/brief/index.jsonl"
invoke "$HOME3" "$ROOT3" '{"hook_event_name":"SessionStart","source":"resume"}'
assert_silent_clean "resume" "$HOME3"

echo "[4] source=compact is silent"
HOME4="$(new_home compact)"
ROOT4="$(new_root compact)"
write_run "$ROOT4" brief-20260101-000000 ready yes
index_line brief-20260101-000000 ready >"$ROOT4/workspace/brief/index.jsonl"
invoke "$HOME4" "$ROOT4" '{"hook_event_name":"SessionStart","source":"compact"}'
assert_silent_clean "compact" "$HOME4"

echo "[5] status running is silent"
HOME5="$(new_home running)"
ROOT5="$(new_root running)"
write_run "$ROOT5" brief-20260101-000000 running yes
index_line brief-20260101-000000 ready >"$ROOT5/workspace/brief/index.jsonl"
invoke "$HOME5" "$ROOT5" "$PAYLOAD"
assert_silent_clean "running" "$HOME5"

echo "[6] status failed is silent"
HOME6="$(new_home failed)"
ROOT6="$(new_root failed)"
write_run "$ROOT6" brief-20260101-000000 failed yes
index_line brief-20260101-000000 ready >"$ROOT6/workspace/brief/index.jsonl"
invoke "$HOME6" "$ROOT6" "$PAYLOAD"
assert_silent_clean "failed" "$HOME6"

echo "[7] no welcome run is silent"
HOME7="$(new_home none)"
ROOT7="$(new_root none)"
write_run "$ROOT7" brief-20260101-000000 ready no
index_line brief-20260101-000000 ready >"$ROOT7/workspace/brief/index.jsonl"
invoke "$HOME7" "$ROOT7" "$PAYLOAD"
assert_silent_clean "no welcome" "$HOME7"
assert_checked_none "no welcome" "$HOME7" brief-20260101-000000
invoke "$HOME7" "$ROOT7" "$PAYLOAD"
assert_silent_clean "no welcome repeat" "$HOME7"

echo "[8] index.jsonl missing uses the brief.json fallback"
HOME8="$(new_home fallback)"
ROOT8="$(new_root fallback)"
write_run "$ROOT8" brief-20260101-010101 ready yes
write_run "$ROOT8" brief-20260102-020202 ready no
write_run "$ROOT8" brief-20260103-030303 ready yes
mkdir -p "$ROOT8/workspace/brief/brief-not-a-date"
jq -cn '{welcome:{title:"nope"}}' >"$ROOT8/workspace/brief/brief-not-a-date/brief.json"
invoke "$HOME8" "$ROOT8" "$PAYLOAD"
assert_announced "fallback" "$HOME8" brief-20260101-010101

echo "[9] malformed index line is silent and does not fall back"
HOME9="$(new_home malformed)"
ROOT9="$(new_root malformed)"
write_run "$ROOT9" brief-20260101-000000 ready yes
printf '%s\n' '{this is not json' >"$ROOT9/workspace/brief/index.jsonl"
invoke "$HOME9" "$ROOT9" "$PAYLOAD"
assert_silent_clean "malformed" "$HOME9"

echo "[10] a run_id containing ../ is rejected"
HOME10="$(new_home traversal)"
ROOT10="$(new_root traversal)"
write_run "$ROOT10" brief-20260101-000000 ready yes
mkdir -p "$ROOT10/workspace/evil"
jq -cn '{state:"ready"}' >"$ROOT10/workspace/evil/status.json"
jq -cn '{run_id:"../evil",created_at:"2026-01-01T00:00:00Z",finished_at:"2026-01-01T00:01:00Z",duration_s:1,window:{from:"2026-01-01",to:"2026-01-02"},state:"ready",mode:"personal",company:null,catch_up:false,lead:"Daily",counts:{decisions:0,shipped:0,incidents:0,carry:0,recovered:0},landed:false,headline:"one plain line"}' >"$ROOT10/workspace/brief/index.jsonl"
invoke "$HOME10" "$ROOT10" "$PAYLOAD"
assert_silent_clean "traversal" "$HOME10"
[ ! -e "$ROOT10/workspace/evil/welcome-brief-announced" ] || fail "traversal wrote next to the decoy"

echo "[11] kill switch is silent"
HOME11="$(new_home kill)"
ROOT11="$(new_root kill)"
write_run "$ROOT11" brief-20260101-000000 ready yes
index_line brief-20260101-000000 ready >"$ROOT11/workspace/brief/index.jsonl"
for kill_value in 0 false FALSE off OFF no NO; do
  invoke "$HOME11" "$ROOT11" "$PAYLOAD" HQ_WELCOME_BRIEF_HOOK="$kill_value"
  assert_silent_clean "kill switch $kill_value" "$HOME11"
done

echo "[12] jq missing from PATH is silent"
HOME12="$(new_home nojq)"
ROOT12="$(new_root nojq)"
write_run "$ROOT12" brief-20260101-000000 ready yes
index_line brief-20260101-000000 ready >"$ROOT12/workspace/brief/index.jsonl"
mkdir -p "$TMP/empty-bin"
invoke "$HOME12" "$ROOT12" "$PAYLOAD" PATH="$TMP/empty-bin"
assert_silent_clean "jq missing" "$HOME12"

echo "[8b] empty index uses the brief.json fallback"
HOME8B="$(new_home empty-index)"
ROOT8B="$(new_root empty-index)"
write_run "$ROOT8B" brief-20260103-030303 ready yes
printf '\n  \n' >"$ROOT8B/workspace/brief/index.jsonl"
invoke "$HOME8B" "$ROOT8B" "$PAYLOAD"
assert_announced "empty index" "$HOME8B" brief-20260103-030303

echo "[13] mixed welcome and non-welcome runs announce the newest welcome"
HOME13="$(new_home mixed)"
ROOT13="$(new_root mixed)"
write_run "$ROOT13" brief-20260101-000000 ready yes
write_run "$ROOT13" brief-20260102-000000 ready no
{
  index_line brief-20260101-000000 ready
  index_line brief-20260102-000000 ready
} >"$ROOT13/workspace/brief/index.jsonl"
invoke "$HOME13" "$ROOT13" "$PAYLOAD"
assert_announced "mixed" "$HOME13" brief-20260101-000000

echo "[14] a brief dir symlinked outside the HQ root is ignored"
HOME14="$(new_home symlink-dir)"
ROOT14="$(new_root symlink-dir)"
OUT14="$TMP/outside-brief-14"
mkdir -p "$OUT14/brief-20260104-040404"
jq -cn '{run_id:"brief-20260104-040404",welcome:{title:"Welcome"}}' >"$OUT14/brief-20260104-040404/brief.json"
jq -cn '{state:"ready"}' >"$OUT14/brief-20260104-040404/status.json"
rm -rf "$ROOT14/workspace/brief"
make_link "$OUT14" "$ROOT14/workspace/brief"
invoke "$HOME14" "$ROOT14" "$PAYLOAD"
assert_silent_clean "symlink brief dir" "$HOME14"

echo "[15] a status.json symlinked outside the HQ root is skipped"
HOME15="$(new_home symlink-status)"
ROOT15="$(new_root symlink-status)"
write_run "$ROOT15" brief-20260101-000000 ready yes
write_run "$ROOT15" brief-20260102-000000 ready yes
OUT15="$TMP/outside-status-15"
mkdir -p "$OUT15"
jq -cn '{state:"ready"}' >"$OUT15/status.json"
rm -f "$ROOT15/workspace/brief/brief-20260101-000000/status.json"
make_link "$OUT15/status.json" "$ROOT15/workspace/brief/brief-20260101-000000/status.json"
{
  index_line brief-20260101-000000 ready
  index_line brief-20260102-000000 ready
} >"$ROOT15/workspace/brief/index.jsonl"
invoke "$HOME15" "$ROOT15" "$PAYLOAD"
assert_announced "symlink status" "$HOME15" brief-20260102-000000

echo "[16] an unwritable marker dir is silent and does not repeat"
HOME16="$(new_home nowrite)"
ROOT16="$(new_root nowrite)"
write_run "$ROOT16" brief-20260101-000000 ready yes
index_line brief-20260101-000000 ready >"$ROOT16/workspace/brief/index.jsonl"
mkdir -p "$HOME16/.hq/onboarding"
deny_writes "$HOME16/.hq/onboarding"
invoke "$HOME16" "$ROOT16" "$PAYLOAD"
assert_silent_clean "unwritable marker dir" "$HOME16"
invoke "$HOME16" "$ROOT16" "$PAYLOAD"
assert_silent_clean "unwritable marker dir repeat" "$HOME16"
allow_writes "$HOME16/.hq/onboarding"
HOME16B="$(new_home nowrite-hq)"
ROOT16B="$(new_root nowrite-hq)"
write_run "$ROOT16B" brief-20260101-000000 ready yes
index_line brief-20260101-000000 ready >"$ROOT16B/workspace/brief/index.jsonl"
mkdir -p "$HOME16B/.hq"
deny_writes "$HOME16B/.hq"
invoke "$HOME16B" "$ROOT16B" "$PAYLOAD"
assert_silent_clean "unwritable hq dir" "$HOME16B"
invoke "$HOME16B" "$ROOT16B" "$PAYLOAD"
assert_silent_clean "unwritable hq dir repeat" "$HOME16B"
allow_writes "$HOME16B/.hq"

echo "[17] concurrent startups announce once"
HOME17="$(new_home concurrent)"
ROOT17="$(new_root concurrent)"
write_run "$ROOT17" brief-20260101-000000 ready yes
index_line brief-20260101-000000 ready >"$ROOT17/workspace/brief/index.jsonl"
i=1
while [ "$i" -le 8 ]; do
  env -u BASH_ENV -u ENV -u HQ_WELCOME_BRIEF_HOOK "${PRINCIPAL_UNSET[@]}" \
    HOME="$HOME17" CLAUDE_PROJECT_DIR="$ROOT17" HQ_AGENT_ROOT_PREFIX="$NO_AGENT_ROOT" \
    "$BASH_BIN" "$HOOK" >"$TMP/concurrent-$i.out" 2>"$TMP/concurrent-$i.err" <<<"$PAYLOAD" &
  i=$((i + 1))
done
wait
announced=0
i=1
while [ "$i" -le 8 ]; do
  [ ! -s "$TMP/concurrent-$i.err" ] || fail "concurrent $i wrote stderr: $(cat "$TMP/concurrent-$i.err")"
  if [ -s "$TMP/concurrent-$i.out" ]; then
    announced=$((announced + 1))
    context="$(jq -er '.hookSpecificOutput.additionalContext' "$TMP/concurrent-$i.out")" || fail "concurrent $i stdout is not hook JSON"
    context="${context//$'\r'/}"
    [ "$context" = "$EXPECTED" ] || fail "concurrent $i context mismatch"
  fi
  i=$((i + 1))
done
[ "$announced" -eq 1 ] || fail "concurrent announced $announced times, want 1"
jq -e --arg id brief-20260101-000000 '.run_id == $id' \
  "$HOME17/.hq/onboarding/welcome-brief-announced" >/dev/null \
  || fail "concurrent marker is wrong"

echo "[18] a newer welcome is announced when the older run is not one"
HOME18="$(new_home newer-welcome)"
ROOT18="$(new_root newer-welcome)"
write_run "$ROOT18" brief-20260101-000000 ready no
write_run "$ROOT18" brief-20260102-000000 failed yes
write_run "$ROOT18" brief-20260103-000000 ready yes
{
  index_line brief-20260101-000000 ready
  index_line brief-20260102-000000 failed
  index_line brief-20260103-000000 ready
} >"$ROOT18/workspace/brief/index.jsonl"
invoke "$HOME18" "$ROOT18" "$PAYLOAD"
assert_announced "newer welcome" "$HOME18" brief-20260103-000000

echo "[19] a two-hop status.json symlink outside the HQ root is skipped"
HOME19="$(new_home two-hop-file)"
ROOT19="$(new_root two-hop-file)"
write_run "$ROOT19" brief-20260101-000000 ready yes
write_run "$ROOT19" brief-20260102-000000 ready yes
OUT19="$TMP/outside-status-19"
mkdir -p "$OUT19"
jq -cn '{state:"ready"}' >"$OUT19/status.json"
# The outside link is the older run. Following it would announce that id.
run19="$ROOT19/workspace/brief/brief-20260101-000000"
make_link "$OUT19/status.json" "$run19/hop"
rm -f "$run19/status.json"
make_link hop "$run19/status.json"
{
  index_line brief-20260101-000000 ready
  index_line brief-20260102-000000 ready
} >"$ROOT19/workspace/brief/index.jsonl"
invoke "$HOME19" "$ROOT19" "$PAYLOAD"
assert_announced "two-hop status file" "$HOME19" brief-20260102-000000

echo "[20] a status.json link through an outside directory link is skipped"
HOME20="$(new_home two-hop-dir)"
ROOT20="$(new_root two-hop-dir)"
write_run "$ROOT20" brief-20260101-000000 ready yes
write_run "$ROOT20" brief-20260102-000000 ready yes
OUT20="$TMP/outside-status-20"
mkdir -p "$OUT20"
jq -cn '{state:"ready"}' >"$OUT20/status.json"
# The outside directory is the older run. Following it would announce that id.
run20="$ROOT20/workspace/brief/brief-20260101-000000"
rm -rf "$run20/sub"
make_link "$OUT20" "$run20/sub"
rm -f "$run20/status.json"
make_link "sub/status.json" "$run20/status.json"
{
  index_line brief-20260101-000000 ready
  index_line brief-20260102-000000 ready
} >"$ROOT20/workspace/brief/index.jsonl"
invoke "$HOME20" "$ROOT20" "$PAYLOAD"
assert_announced "two-hop status dir" "$HOME20" brief-20260102-000000

echo "[21] an in-root status.json symlink is still read"
HOME21="$(new_home in-root-link)"
ROOT21="$(new_root in-root-link)"
write_run "$ROOT21" brief-20260101-000000 ready yes
run21="$ROOT21/workspace/brief/brief-20260101-000000"
mv "$run21/status.json" "$run21/status.real.json"
make_link status.real.json "$run21/status.json"
index_line brief-20260101-000000 ready >"$ROOT21/workspace/brief/index.jsonl"
invoke "$HOME21" "$ROOT21" "$PAYLOAD"
assert_announced "in-root symlink" "$HOME21" brief-20260101-000000

echo "[22] a two-hop brief dir outside the HQ root is ignored"
HOME22="$(new_home two-hop-brief-dir)"
ROOT22="$(new_root two-hop-brief-dir)"
OUT22="$TMP/outside-brief-22"
mkdir -p "$OUT22/brief-20260104-040404"
jq -cn '{run_id:"brief-20260104-040404",welcome:{title:"Welcome"}}' >"$OUT22/brief-20260104-040404/brief.json"
jq -cn '{state:"ready"}' >"$OUT22/brief-20260104-040404/status.json"
rm -rf "$ROOT22/workspace/brief"
make_link "$OUT22" "$ROOT22/workspace/brief-hop"
make_link brief-hop "$ROOT22/workspace/brief"
invoke "$HOME22" "$ROOT22" "$PAYLOAD"
assert_silent_clean "two-hop brief dir" "$HOME22"

write_series() {
  local root="$1" day="$2" count="$3" welcome_at="$4"
  local i id dir idxf="$root/workspace/brief/index.jsonl"
  : >"$idxf"
  i=0
  while [ "$i" -lt "$count" ]; do
    id=$(printf 'brief-%s-%06d' "$day" "$i")
    dir="$root/workspace/brief/$id"
    mkdir -p "$dir"
    if [ "$i" -eq "$welcome_at" ]; then
      printf '%s\n' "{\"run_id\":\"$id\",\"welcome\":{\"title\":\"Welcome\"}}" >"$dir/brief.json"
    else
      printf '%s\n' "{\"run_id\":\"$id\",\"lead\":\"daily\"}" >"$dir/brief.json"
    fi
    printf '%s\n' '{"state":"ready"}' >"$dir/status.json"
    printf '%s\n' "{\"run_id\":\"$id\",\"created_at\":\"2020-01-01T00:00:00Z\",\"finished_at\":\"2020-01-01T00:01:00Z\",\"duration_s\":1,\"window\":{\"from\":\"2020-01-01\",\"to\":\"2020-01-02\"},\"state\":\"ready\",\"mode\":\"personal\",\"company\":null,\"catch_up\":false,\"lead\":\"Daily\",\"counts\":{\"decisions\":0,\"shipped\":0,\"incidents\":0,\"carry\":0,\"recovered\":0},\"landed\":false,\"headline\":\"one plain line\"}" >>"$idxf"
    i=$((i + 1))
  done
}

echo "[23] the oldest welcome in a long history is still announced"
HOME23="$(new_home oldest-of-many)"
ROOT23="$(new_root oldest-of-many)"
write_series "$ROOT23" 20220303 45 0
invoke "$HOME23" "$ROOT23" "$PAYLOAD"
assert_announced "oldest of many" "$HOME23" brief-20220303-000000

echo "[24] a welcome run outside the oldest 20 and newest 20 stays quiet"
HOME24="$(new_home middle-gap)"
ROOT24="$(new_root middle-gap)"
write_series "$ROOT24" 20220404 45 22
invoke "$HOME24" "$ROOT24" "$PAYLOAD"
assert_silent_clean "middle gap" "$HOME24"
assert_checked_none "middle gap" "$HOME24" brief-20220404-000044

echo "[25] 500 non-welcome runs stay within the jq budget"
HOME25="$(new_home budget)"
ROOT25="$(new_root budget)"
write_series "$ROOT25" 20200101 500 -1
REAL_JQ="$(command -v jq)"
mkdir -p "$TMP/jqbin"
cat >"$TMP/jqbin/jq" <<EOF
#!/bin/bash
printf 'x\n' >> "$TMP/jq-spawns"
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$TMP/jqbin/jq"
: >"$TMP/jq-spawns"
budget_hook() {
  local out="$1" err="$2"
  env -u BASH_ENV -u ENV -u HQ_WELCOME_BRIEF_HOOK "${PRINCIPAL_UNSET[@]}" \
    HOME="$HOME25" CLAUDE_PROJECT_DIR="$ROOT25" HQ_AGENT_ROOT_PREFIX="$NO_AGENT_ROOT" \
    PATH="$TMP/jqbin:$PATH" \
    "$BASH_BIN" "$HOOK" >"$out" 2>"$err" <<<"$PAYLOAD"
}
budget_hook "$TMP/budget.out" "$TMP/budget.err"
[ -z "$(cat "$TMP/budget.err")" ] || fail "budget wrote stderr: $(cat "$TMP/budget.err")"
[ -z "$(cat "$TMP/budget.out")" ] || fail "budget wrote stdout: $(cat "$TMP/budget.out")"
spawns="$(awk 'END { print NR }' "$TMP/jq-spawns")"
[ "$spawns" -le 4 ] || fail "budget jq spawns $spawns, want <= 4"
assert_checked_none "budget" "$HOME25" brief-20200101-000499
: >"$TMP/jq-spawns"
budget_hook "$TMP/budget2.out" "$TMP/budget2.err"
[ -z "$(cat "$TMP/budget2.err")" ] || fail "budget repeat wrote stderr: $(cat "$TMP/budget2.err")"
[ -z "$(cat "$TMP/budget2.out")" ] || fail "budget repeat wrote stdout: $(cat "$TMP/budget2.out")"
spawns2="$(awk 'END { print NR }' "$TMP/jq-spawns")"
[ "$spawns2" -eq 0 ] || fail "budget repeat jq spawns $spawns2, want 0"
write_run "$ROOT25" brief-20200101-000500 ready yes
index_line brief-20200101-000500 ready >>"$ROOT25/workspace/brief/index.jsonl"
invoke "$HOME25" "$ROOT25" "$PAYLOAD"
assert_announced "budget new welcome" "$HOME25" brief-20200101-000500

echo "[26] a running first welcome with no index announces once it is ready"
HOME26="$(new_home s1-running-welcome)"
ROOT26="$(new_root s1-running-welcome)"
S26=brief-20261018-090000
mkdir -p "$ROOT26/workspace/brief/$S26"
jq -cn '{state:"running"}' >"$ROOT26/workspace/brief/$S26/status.json"
invoke "$HOME26" "$ROOT26" "$PAYLOAD"
assert_silent_clean "s1 running no brief" "$HOME26"
assert_no_none_marker "s1 running no brief" "$HOME26"
write_run "$ROOT26" "$S26" running yes
invoke "$HOME26" "$ROOT26" "$PAYLOAD"
assert_silent_clean "s1 running with brief" "$HOME26"
assert_no_none_marker "s1 running with brief" "$HOME26"
write_run "$ROOT26" "$S26" ready yes
index_line "$S26" ready >"$ROOT26/workspace/brief/index.jsonl"
invoke "$HOME26" "$ROOT26" "$PAYLOAD"
assert_announced "s1 ready" "$HOME26" "$S26"
BEFORE26="$(cat "$HOME26/.hq/onboarding/welcome-brief-announced")"
invoke "$HOME26" "$ROOT26" "$PAYLOAD"
[ "$RC" -eq 0 ] || fail "s1 repeat: exit $RC"
[ -z "$OUT" ] || fail "s1 repeat: expected no stdout, got: $OUT"
[ -z "$ERR" ] || fail "s1 repeat: expected no stderr, got: $ERR"
[ "$BEFORE26" = "$(cat "$HOME26/.hq/onboarding/welcome-brief-announced")" ] \
  || fail "s1 repeat rewrote the marker"

echo "[27] an indexed welcome that is still running announces once it is ready"
HOME27="$(new_home s3-indexed-running)"
ROOT27="$(new_root s3-indexed-running)"
S27=brief-20261018-000000
write_run "$ROOT27" "$S27" running yes
index_line "$S27" ready >"$ROOT27/workspace/brief/index.jsonl"
invoke "$HOME27" "$ROOT27" "$PAYLOAD"
assert_silent_clean "s3 running" "$HOME27"
assert_no_none_marker "s3 running" "$HOME27"
write_run "$ROOT27" "$S27" ready yes
invoke "$HOME27" "$ROOT27" "$PAYLOAD"
assert_announced "s3 ready" "$HOME27" "$S27"
BEFORE27="$(cat "$HOME27/.hq/onboarding/welcome-brief-announced")"
invoke "$HOME27" "$ROOT27" "$PAYLOAD"
[ "$RC" -eq 0 ] || fail "s3 repeat: exit $RC"
[ -z "$OUT" ] || fail "s3 repeat: expected no stdout, got: $OUT"
[ -z "$ERR" ] || fail "s3 repeat: expected no stderr, got: $ERR"
[ "$BEFORE27" = "$(cat "$HOME27/.hq/onboarding/welcome-brief-announced")" ] \
  || fail "s3 repeat rewrote the marker"

echo "[28] a welcome dir with no index announces once it is ready"
HOME28="$(new_home s5-dir-running)"
ROOT28="$(new_root s5-dir-running)"
S28=brief-20261018-000000
write_run "$ROOT28" "$S28" running yes
invoke "$HOME28" "$ROOT28" "$PAYLOAD"
assert_silent_clean "s5 running" "$HOME28"
assert_no_none_marker "s5 running" "$HOME28"
write_run "$ROOT28" "$S28" ready yes
invoke "$HOME28" "$ROOT28" "$PAYLOAD"
assert_announced "s5 ready" "$HOME28" "$S28"
BEFORE28="$(cat "$HOME28/.hq/onboarding/welcome-brief-announced")"
invoke "$HOME28" "$ROOT28" "$PAYLOAD"
[ "$RC" -eq 0 ] || fail "s5 repeat: exit $RC"
[ -z "$OUT" ] || fail "s5 repeat: expected no stdout, got: $OUT"
[ -z "$ERR" ] || fail "s5 repeat: expected no stderr, got: $ERR"
[ "$BEFORE28" = "$(cat "$HOME28/.hq/onboarding/welcome-brief-announced")" ] \
  || fail "s5 repeat rewrote the marker"

echo "[29] one malformed candidate does not hide a ready welcome"
HOME29="$(new_home skip-bad)"
ROOT29="$(new_root skip-bad)"
write_run "$ROOT29" brief-20260101-000000 ready yes
write_run "$ROOT29" brief-20260102-000000 ready yes
printf '%s\n' '{not json' >"$ROOT29/workspace/brief/brief-20260101-000000/status.json"
{
  index_line brief-20260101-000000 ready
  index_line brief-20260102-000000 ready
} >"$ROOT29/workspace/brief/index.jsonl"
invoke "$HOME29" "$ROOT29" "$PAYLOAD"
assert_announced "skip bad welcome" "$HOME29" brief-20260102-000000

echo "[30] one malformed older file still records checked-none"
HOME30="$(new_home skip-bad-none)"
ROOT30="$(new_root skip-bad-none)"
write_run "$ROOT30" brief-20260101-000000 ready no
write_run "$ROOT30" brief-20260102-000000 ready no
printf '%s\n' '{not json' >"$ROOT30/workspace/brief/brief-20260101-000000/status.json"
{
  index_line brief-20260101-000000 ready
  index_line brief-20260102-000000 ready
} >"$ROOT30/workspace/brief/index.jsonl"
invoke "$HOME30" "$ROOT30" "$PAYLOAD"
assert_silent_clean "skip bad none" "$HOME30"
assert_checked_none "skip bad none" "$HOME30" brief-20260102-000000

echo "[31] an index linked elsewhere still reads runs from the brief dir"
HOME31="$(new_home index-link)"
ROOT31="$(new_root index-link)"
write_run "$ROOT31" brief-20260101-000000 running no
mkdir -p "$ROOT31/other/brief-20260101-000000"
index_line brief-20260101-000000 ready >"$ROOT31/other/index.jsonl"
make_link "$ROOT31/other/index.jsonl" "$ROOT31/workspace/brief/index.jsonl"
OUT31="$TMP/outside-index-link-31"
mkdir -p "$OUT31"
jq -cn '{run_id:"brief-20260101-000000",welcome:{title:"Welcome"}}' >"$OUT31/brief.json"
jq -cn '{state:"ready"}' >"$OUT31/status.json"
make_link "$OUT31/brief.json" "$ROOT31/other/brief-20260101-000000/brief.json"
make_link "$OUT31/status.json" "$ROOT31/other/brief-20260101-000000/status.json"
invoke "$HOME31" "$ROOT31" "$PAYLOAD"
assert_silent_clean "index link outside run" "$HOME31"
assert_no_none_marker "index link outside run" "$HOME31"
write_run "$ROOT31" brief-20260101-000000 ready yes
invoke "$HOME31" "$ROOT31" "$PAYLOAD"
assert_announced "index link brief dir run" "$HOME31" brief-20260101-000000

echo "[32] agent, bot, checkpoint-sibling and lane sessions leave the marker for the next human session"
HOME32="$(new_home non-human)"
ROOT32="$(new_root non-human)"
write_run "$ROOT32" brief-20260101-000000 ready yes
index_line brief-20260101-000000 ready >"$ROOT32/workspace/brief/index.jsonl"
HOME32N="$(new_home non-human-none)"
ROOT32N="$(new_root non-human-none)"
write_run "$ROOT32N" brief-20260101-000000 ready no
index_line brief-20260101-000000 ready >"$ROOT32N/workspace/brief/index.jsonl"
FLEET32="$TMP/fleet-root-32"
mkdir -p "$FLEET32/var/lib/hq-agent"
printf '%s\n' '{"agent_id":"a1"}' >"$FLEET32/var/lib/hq-agent/identity.json"
for principal_env in HQ_BOT_AGENT_UID=bot1 HQ_MACHINE_CREDS_FILE="$TMP/creds.json" \
  HQ_SESSION_PRINCIPAL=agent HQ_SESSION_PRINCIPAL=bot HQ_AGENT_WORKDIR="$TMP" \
  HQ_AGENT_COMPANY_DIR="$TMP" HQ_AGENT_IDENTITY_FILE="$TMP/id.json" \
  HQ_AGENT_ROOT_PREFIX="$FLEET32" HQ_CHECKPOINT_SIBLING=1 HQ_LANE_ID=lane-1; do
  invoke "$HOME32" "$ROOT32" "$PAYLOAD" "$principal_env"
  assert_silent_clean "non-human $principal_env" "$HOME32"
  assert_no_none_marker "non-human $principal_env" "$HOME32"
  invoke "$HOME32N" "$ROOT32N" "$PAYLOAD" "$principal_env"
  assert_silent_clean "non-human none $principal_env" "$HOME32N"
  assert_no_none_marker "non-human none $principal_env" "$HOME32N"
done
invoke "$HOME32" "$ROOT32" "$PAYLOAD"
assert_announced "human after non-human" "$HOME32" brief-20260101-000000
invoke "$HOME32N" "$ROOT32N" "$PAYLOAD"
assert_silent_clean "human none after non-human" "$HOME32N"
assert_checked_none "human none after non-human" "$HOME32N" brief-20260101-000000
HOME32H="$(new_home explicit-human)"
invoke "$HOME32H" "$ROOT32" "$PAYLOAD" HQ_SESSION_PRINCIPAL=human HQ_BOT_AGENT_UID=bot1
assert_announced "explicit human" "$HOME32H" brief-20260101-000000

echo "[33] a workflow child is gated off and the next human session announces"
HOME33="$(new_home workflow-child)"
ROOT33="$(new_root workflow-child)"
write_run "$ROOT33" brief-20260101-000000 ready yes
index_line brief-20260101-000000 ready >"$ROOT33/workspace/brief/index.jsonl"
invoke_gate() {
  local home="$1" root="$2"
  shift 2
  set +e
  env -u BASH_ENV -u ENV -u HQ_WELCOME_BRIEF_HOOK "${PRINCIPAL_UNSET[@]}" \
    HOME="$home" CLAUDE_PROJECT_DIR="$root" HQ_AGENT_ROOT_PREFIX="$NO_AGENT_ROOT" \
    "$@" \
    "$BASH_BIN" "$ROOT/.claude/hooks/hook-gate.sh" welcome-brief-ready "$HOOK" \
    >"$TMP/stdout" 2>"$TMP/stderr" <<<"$PAYLOAD"
  RC=$?
  set -e
  OUT="$(cat "$TMP/stdout")"
  ERR="$(cat "$TMP/stderr")"
}
invoke_gate "$HOME33" "$ROOT33" HQ_DISABLED_HOOKS=checkpoint-stop-gate,welcome-brief-ready
assert_silent_clean "workflow child" "$HOME33"
assert_no_none_marker "workflow child" "$HOME33"
invoke_gate "$HOME33" "$ROOT33"
assert_announced "human after workflow child" "$HOME33" brief-20260101-000000

echo "[34] a welcome block that holds an error is not announced"
HOME34="$(new_home welcome-error)"
ROOT34="$(new_root welcome-error)"
write_run "$ROOT34" brief-20260101-000000 ready yes
jq -cn '{run_id:"brief-20260101-000000",welcome:{error:"x"}}' \
  >"$ROOT34/workspace/brief/brief-20260101-000000/brief.json"
index_line brief-20260101-000000 ready >"$ROOT34/workspace/brief/index.jsonl"
invoke "$HOME34" "$ROOT34" "$PAYLOAD"
assert_silent_clean "welcome error" "$HOME34"
assert_checked_none "welcome error" "$HOME34" brief-20260101-000000
write_run "$ROOT34" brief-20260102-000000 ready yes
index_line brief-20260102-000000 ready >>"$ROOT34/workspace/brief/index.jsonl"
invoke "$HOME34" "$ROOT34" "$PAYLOAD"
assert_announced "welcome after error" "$HOME34" brief-20260102-000000

echo "[35] a marker write that fails after open leaves no marker"
HOME35="$(new_home write-fail)"
ROOT35="$(new_root write-fail)"
write_run "$ROOT35" brief-20260101-000000 ready yes
index_line brief-20260101-000000 ready >"$ROOT35/workspace/brief/index.jsonl"
# The probe uses an external printf: bash 3.2 flushes a failed builtin printf
# to stdout later. The hook's stdout and stderr go through pipes, which the
# file size limit does not cover, so a leaked marker text would show up.
# The probe exits 1 only when ulimit -f 0 is accepted and the write then
# fails. Git Bash can refuse the ulimit itself, and that must not count as a
# blocked write.
set +e
"$BASH_BIN" -c 'trap "" XFSZ; ulimit -f 0 || exit 3; command -p printf x >"$1" && exit 0; exit 1' _ "$TMP/fsize-probe" >/dev/null 2>&1
PROBE35=$?
set -e
if [ "$PROBE35" -ne 1 ]; then
  printf '  note: ulimit -f 0 does not stop writes on this host (probe exit %s); case 35 cannot run here\n' "$PROBE35"
else
  set +e
  OUT="$(
    { env -u BASH_ENV -u ENV -u HQ_WELCOME_BRIEF_HOOK "${PRINCIPAL_UNSET[@]}" \
      HOME="$HOME35" CLAUDE_PROJECT_DIR="$ROOT35" HQ_AGENT_ROOT_PREFIX="$NO_AGENT_ROOT" \
      "$BASH_BIN" -c 'trap "" XFSZ; ulimit -f 0 || exit 97; exec "$1" "$2"' _ "$BASH_BIN" "$HOOK" \
      <<<"$PAYLOAD" 2>&1 1>&3 | cat >"$TMP/stderr"; } 3>&1
  )"
  RC=$?
  set -e
  [ "$RC" -ne 97 ] || fail "write fail: ulimit -f 0 was refused after the probe accepted it"
  ERR="$(cat "$TMP/stderr")"
  assert_silent_clean "write fail" "$HOME35"
  invoke "$HOME35" "$ROOT35" "$PAYLOAD"
  assert_announced "after write fail" "$HOME35" brief-20260101-000000
fi

echo "[36] an older welcome still running blocks checked-none for a newer run"
HOME36="$(new_home older-running)"
ROOT36="$(new_root older-running)"
write_run "$ROOT36" brief-20260101-000000 running yes
write_run "$ROOT36" brief-20260102-000000 ready no
{
  index_line brief-20260101-000000 running
  index_line brief-20260102-000000 ready
} >"$ROOT36/workspace/brief/index.jsonl"
invoke "$HOME36" "$ROOT36" "$PAYLOAD"
assert_silent_clean "older running" "$HOME36"
assert_no_none_marker "older running" "$HOME36"
write_run "$ROOT36" brief-20260101-000000 ready yes
{
  index_line brief-20260101-000000 ready
  index_line brief-20260102-000000 ready
} >"$ROOT36/workspace/brief/index.jsonl"
invoke "$HOME36" "$ROOT36" "$PAYLOAD"
assert_announced "older now ready" "$HOME36" brief-20260101-000000

echo "[37] inline headless launches keep the person's env, so they turn the hook off"
PARITY37="$ROOT/core/scripts/anywhere-parity-test.sh"
# Command lines in skills and workers: a line that starts with the launch, a
# YAML list entry, or `cd {dir} && <launch>`, each with optional VAR=value
# prefixes. Prose mentions in backticks do not match.
LAUNCH37='(^[[:space:]]*|^[[:space:]]*- |&&[[:space:]]*)([A-Z_][A-Z0-9_]*=[^[:space:]]* )*(codex exec|claude -p) --'
all37="$(grep -rnE "$LAUNCH37" "$ROOT/.claude/skills" "$ROOT/core/workers" 2>/dev/null || true)"
[ -n "$all37" ] || fail "no inline headless launch lines found to check"
printf '%s\n' "$all37" | grep 'execute-task/SKILL.md' >/dev/null \
  || fail "execute-task inline codex exec not matched"
printf '%s\n' "$all37" | grep 'codex-debugger/skills/debug-issue.md' >/dev/null \
  || fail "codex-debugger inline codex exec not matched"
bad37="$(printf '%s\n' "$all37" | grep -v 'HQ_WELCOME_BRIEF_HOOK=0 \(codex exec\|claude -p\)' || true)"
[ -z "$bad37" ] || fail "inline headless launch without HQ_WELCOME_BRIEF_HOOK=0: $bad37"
n37="$(grep -c 'CLAUDE_HEADLESS=1' "$PARITY37" || true)"
[ "$n37" -ge 3 ] || fail "anywhere-parity-test: expected 3 headless runs, found $n37"
if grep 'CLAUDE_HEADLESS=1' "$PARITY37" | grep -v 'HQ_WELCOME_BRIEF_HOOK=0' | grep -q .; then
  fail "anywhere-parity-test: headless run without HQ_WELCOME_BRIEF_HOOK=0"
fi

echo "welcome-brief-ready: ok"
