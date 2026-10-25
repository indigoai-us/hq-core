#!/usr/bin/env bash
# hq-core: public
# Regression tests: /handoff self-archive decision. Flags beat env, env beats
# settings, personal settings beat core, default is off. A wanted archive is
# refused when recovery is pending, the handoff files are missing, a linked
# worktree is dirty, the session's branch has an open PR, the session has
# background work, or the session has an ask waiting on the owner. A check
# that cannot run refuses too. The handoff message is read from a file, never
# argv, and taken literally.
# Uses a fixture HQ tree, local git repos, and fake hq/gh binaries; no network.
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/var/tmp}/handoff-archive-decision-test.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

root="$TMP_ROOT/hq"
mkdir -p "$root/core/scripts" "$root/core/settings" "$root/personal/settings" \
  "$root/workspace/threads" "$root/workspace/reports/conduct"
cp "$SRC_ROOT/scripts/handoff-archive-decision.sh" "$root/core/scripts/"
plain="$TMP_ROOT/plain"; mkdir -p "$plain"
SID="sess-1111"

# Handoff fixture: what handoff-finalize.sh writes.
thread="workspace/threads/T-test.json"
write_handoff() {
  printf '{"thread_id":"T-test"}\n' > "$root/$thread"
  printf '{"thread_id":"T-test","files":[]}\n' > "$root/workspace/threads/T-test.changeset.json"
  printf '{"last_thread":"T-test","thread_path":"%s"}\n' "$thread" > "$root/workspace/threads/handoff.json"
}
write_handoff

# Fake hq and gh. Behaviour comes from env; every call is logged.
bin="$TMP_ROOT/bin"; mkdir -p "$bin"
calls="$TMP_ROOT/calls.log"; : > "$calls"
cat > "$bin/hq" <<'EOF'
#!/usr/bin/env bash
echo "hq $*" >> "$FAKE_CALLS"
case "$1 $2" in
  "lanes list")
    [ "${FAKE_LANES_FAIL:-0}" = 1 ] && { echo "boom" >&2; exit 1; }
    if [ -n "${FAKE_LANES_JSON:-}" ]; then printf '%s\n' "$FAKE_LANES_JSON"; else echo '{"ok":true,"action":"list","lanes":[]}'; fi ;;
  "monitor list")
    [ "${FAKE_MONITORS_FAIL:-0}" = 1 ] && { echo "boom" >&2; exit 1; }
    if [ -n "${FAKE_MONITORS_JSON:-}" ]; then printf '%s\n' "$FAKE_MONITORS_JSON"; else echo '{"monitors":[]}'; fi ;;
  *) exit 2 ;;
esac
EOF
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE_CALLS"
[ "${FAKE_GH_FAIL:-0}" = 1 ] && { echo "gh: not logged in" >&2; exit 1; }
printf '%s\n' "${FAKE_GH_PRS:-[]}"
EOF
chmod +x "$bin/hq" "$bin/gh"

msgfile="$TMP_ROOT/msg"
# run [--msg "<handoff message>"] [script args...]
run() {
  local msg=""
  if [ "${1:-}" = "--msg" ]; then msg="$2"; shift 2; fi
  printf '%s' "$msg" > "$msgfile"
  env -u HQ_HANDOFF_ARCHIVE -u HQ_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
    PATH="$bin:$PATH" FAKE_CALLS="$calls" \
    bash "$root/core/scripts/handoff-archive-decision.sh" --root "$root" --cwd "$plain" \
    --session-id "$SID" --thread "$thread" --args-file "$msgfile" "$@"
}
expect() { local want="$1"; shift; local got; got="$(run "$@")"; [ "$got" = "$want" ] || fail "$* -> '$got', want '$want'"; }

# 1. No settings anywhere: off.
expect "archive: no (off)"
pass "default is off"

# 2. Core setting false, personal absent: off by setting.
echo "auto_archive: false" > "$root/core/settings/handoff.yaml"
expect "archive: no (off by setting)"
pass "core setting false"

# 3. Personal true beats core false.
echo "auto_archive: true  # mine" > "$root/personal/settings/handoff.yaml"
expect "archive: yes"
pass "personal setting true beats core"

# 4. --no-archive beats the setting; --archive beats a false setting.
expect "archive: no (--no-archive)" --msg "--no-archive"
expect "archive: no (--no-archive)" --msg "wrapping up --no-archive please"
echo "auto_archive: false" > "$root/personal/settings/handoff.yaml"
expect "archive: yes" --msg "--archive"
expect "archive: yes" --msg "--archive wrapping up the auth fix"
expect "archive: no (off by setting)" --msg "notes about archives"
pass "flags beat settings and match whole words"

# 5. --archive counts only as a leading argument token. Prose that mentions it
#    never archives, even when the setting is on.
expect "archive: no (--archive is not a leading flag)" --msg "don't --archive"
expect "archive: no (--archive is not a leading flag)" --msg "please do not use --archive here"
expect "archive: no (--archive is not a leading flag)" --msg "--archived"
expect "archive: no (--archive is not a leading flag)" --msg "--archive=yes"
echo "auto_archive: true" > "$root/personal/settings/handoff.yaml"
expect "archive: no (--archive is not a leading flag)" --msg "don't --archive"
expect "archive: no (--no-archive)" --msg "don't --archive --no-archive"
echo "auto_archive: false" > "$root/personal/settings/handoff.yaml"
pass "\"don't --archive\" does not archive"

# 6. The message is read from a file and taken literally: quotes and command
#    substitutions are never evaluated.
rm -f "$TMP_ROOT/PWNED"
expect "archive: yes" --msg "--archive he said \"done\" \$(touch $TMP_ROOT/PWNED) \`touch $TMP_ROOT/PWNED\`"
[ ! -e "$TMP_ROOT/PWNED" ] || fail "handoff message was evaluated"
got="$(printf '%s' '--archive "x" $(touch '"$TMP_ROOT"'/PWNED)' | env -u HQ_HANDOFF_ARCHIVE PATH="$bin:$PATH" FAKE_CALLS="$calls" \
  bash "$root/core/scripts/handoff-archive-decision.sh" --root "$root" --cwd "$plain" \
  --session-id "$SID" --thread "$thread" --args-file -)"
[ "$got" = "archive: yes" ] || fail "stdin message -> '$got'"
[ ! -e "$TMP_ROOT/PWNED" ] || fail "stdin handoff message was evaluated"
expect "archive: no (could not read the handoff message)" --msg "--archive" --args-file "$TMP_ROOT/missing"
pass "message read from file or stdin, taken literally"

# 7. Env beats settings, loses to flags.
got="$(HQ_HANDOFF_ARCHIVE=1 PATH="$bin:$PATH" FAKE_CALLS="$calls" bash "$root/core/scripts/handoff-archive-decision.sh" --root "$root" --cwd "$plain" --session-id "$SID" --thread "$thread")"
[ "$got" = "archive: yes" ] || fail "env=1 -> '$got'"
printf '%s' "--archive" > "$msgfile"
got="$(HQ_HANDOFF_ARCHIVE=0 PATH="$bin:$PATH" FAKE_CALLS="$calls" bash "$root/core/scripts/handoff-archive-decision.sh" --root "$root" --cwd "$plain" --session-id "$SID" --thread "$thread" --args-file "$msgfile")"
[ "$got" = "archive: yes" ] || fail "env=0 + --archive -> '$got'"
pass "env beats settings, flag beats env"

# 8. Recovery pending refuses.
expect "archive: no (follow-up recovery pending)" --msg "--archive" --recovery-pending
pass "recovery pending refuses"

# 9. The handoff files must exist and agree.
got="$(env -u HQ_HANDOFF_ARCHIVE PATH="$bin:$PATH" FAKE_CALLS="$calls" bash "$root/core/scripts/handoff-archive-decision.sh" --root "$root" --cwd "$plain" --session-id "$SID" --args-file "$msgfile")"
[ "$got" = "archive: no (handoff not verified: no --thread given)" ] || fail "no --thread -> '$got'"
rm "$root/$thread"
expect "archive: no (handoff not verified: thread file missing)" --msg "--archive"
write_handoff; printf 'not json' > "$root/$thread"
expect "archive: no (handoff not verified: thread file is not valid JSON)" --msg "--archive"
write_handoff; rm "$root/workspace/threads/T-test.changeset.json"
expect "archive: no (handoff not verified: changeset file missing)" --msg "--archive"
write_handoff; rm "$root/workspace/threads/handoff.json"
expect "archive: no (handoff not verified: handoff.json missing)" --msg "--archive"
write_handoff
expect "archive: yes" --msg "--archive" --thread "$root/$thread"
pass "handoff files are verified"

# 9b. handoff.json is one shared last-writer-wins pointer. When another session
#     hands off in the same window (or a vault pull replays an older copy), the
#     pointer names a different thread even though this session's handoff is
#     on disk. The thread still counts as this session's when the pointer
#     carries this session id, or when the thread file is committed in the
#     HQ root. Only an uncommitted thread behind a foreign pointer refuses.
other_pointer() {
  printf '{"last_thread":"T-other","thread_path":"workspace/threads/T-other.json","created_at":"%s"%s}\n' \
    "$1" "${2:-}" > "$root/workspace/threads/handoff.json"
}
write_handoff; other_pointer 20261025T050000Z
expect "archive: no (handoff not verified: handoff.json points at another thread and this thread is not committed)" --msg "--archive"
other_pointer 20261025T050000Z ',"session_id":"'"$SID"'"'
expect "archive: yes" --msg "--archive"
other_pointer 20261025T050000Z ',"session_id":"sess-other"'
expect "archive: no (handoff not verified: handoff.json points at another thread and this thread is not committed)" --msg "--archive"
git -C "$root" init -q -b main
git -C "$root" -c user.email=t@t -c user.name=t add "$thread" workspace/threads/T-test.changeset.json
git -C "$root" -c user.email=t@t -c user.name=t commit -q -m "checkpoint: handoff T-test"
expect "archive: yes" --msg "--archive"
# A thread that changed since its commit is not durable yet.
printf '{"thread_id":"T-test","edited":true}\n' > "$root/$thread"
expect "archive: no (handoff not verified: handoff.json points at another thread and this thread is not committed)" --msg "--archive"
git -C "$root" checkout -q -- "$thread"
expect "archive: yes" --msg "--archive"
rm -rf "$root/.git"
write_handoff
pass "own committed thread (or own session id in the pointer) archives behind a foreign pointer"

# 10. Linked worktree: clean is fine, dirty refuses. Main checkout dirt is ignored.
repo="$TMP_ROOT/repo"
git init -q -b main "$repo"
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$repo" worktree add -q "$TMP_ROOT/wt" -b wt
echo x > "$repo/dirty-main"
expect "archive: yes" --msg "--archive" --cwd "$repo"
expect "archive: yes" --msg "--archive" --cwd "$TMP_ROOT/wt"
echo x > "$TMP_ROOT/wt/dirty"
expect "archive: no (uncommitted changes in this session's worktree)" --msg "--archive" --cwd "$TMP_ROOT/wt"
rm "$TMP_ROOT/wt/dirty"
pass "dirty linked worktree refuses; main checkout is not checked"

# 11. Open PRs on the session's branches. Repos without a remote, and the
#     default branch, are not checked. gh errors refuse.
git -C "$repo" remote add origin "$TMP_ROOT/origin.git"
: > "$calls"
expect "archive: yes" --msg "--archive" --cwd "$repo"
! grep -q '^gh ' "$calls" || fail "gh called for the main branch"
: > "$calls"
expect "archive: yes" --msg "--archive" --cwd "$TMP_ROOT/wt"
grep -q '^gh pr list --head wt --state open' "$calls" || fail "gh not asked about branch wt: $(cat "$calls")"
FAKE_GH_PRS='[{"number":7,"url":"https://github.com/o/r/pull/7"}]' \
  expect "archive: no (open PR on branch wt: https://github.com/o/r/pull/7)" --msg "--archive" --cwd "$TMP_ROOT/wt"
FAKE_GH_FAIL=1 expect "archive: no (could not verify open PRs for branch wt)" --msg "--archive" --cwd "$TMP_ROOT/wt"
FAKE_GH_PRS='nonsense' expect "archive: no (could not verify open PRs for branch wt)" --msg "--archive" --cwd "$TMP_ROOT/wt"
# --repo-dir adds another checkout the session worked in.
FAKE_GH_PRS='[{"number":8,"url":"https://github.com/o/r/pull/8"}]' \
  expect "archive: no (open PR on branch wt: https://github.com/o/r/pull/8)" --msg "--archive" --repo-dir "$TMP_ROOT/wt"
git init -q -b main "$TMP_ROOT/noremote"
git -C "$TMP_ROOT/noremote" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$TMP_ROOT/noremote" checkout -q -b feat
FAKE_GH_FAIL=1 expect "archive: yes" --msg "--archive" --cwd "$TMP_ROOT/noremote"
pass "open PR on the session's branch refuses; gh failure refuses"

# 12. Background work: active lanes owned by the session, running monitors
#     aimed at it, and in-session background tasks. Failures refuse.
: > "$calls"
expect "archive: yes" --msg "--archive"
grep -q "^hq lanes list --senior session:$SID --active --json" "$calls" || fail "lanes not filtered by session: $(cat "$calls")"
FAKE_LANES_JSON='{"ok":true,"lanes":[{"lane_id":"L1","state":"running"}]}' \
  expect "archive: no (background work running: 1 active lane(s))" --msg "--archive"
FAKE_LANES_FAIL=1 expect "archive: no (could not verify background work: hq lanes list failed)" --msg "--archive"
FAKE_LANES_JSON='{"ok":false}' expect "archive: no (could not verify background work: hq lanes list failed)" --msg "--archive"
FAKE_MONITORS_JSON='{"monitors":[{"monitor_id":"mon_1","target":{"kind":"session","sessionId":"'"$SID"'"},"state":{"status":"running"}}]}' \
  expect "archive: no (background work running: monitor mon_1)" --msg "--archive"
FAKE_MONITORS_JSON='{"monitors":[{"monitor_id":"mon_2","target":{"kind":"session","sessionId":"other"},"state":{"status":"running"}}]}' \
  expect "archive: yes" --msg "--archive"
FAKE_MONITORS_FAIL=1 expect "archive: no (could not verify background work: hq monitor list failed)" --msg "--archive"
expect "archive: no (background work running in this session)" --msg "--archive" --background-running
got="$(env -u HQ_HANDOFF_ARCHIVE -u HQ_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID PATH="$bin:$PATH" FAKE_CALLS="$calls" \
  bash "$root/core/scripts/handoff-archive-decision.sh" --root "$root" --cwd "$plain" --thread "$thread" --args-file "$msgfile")"
[ "$got" = "archive: no (could not verify background work: no session id)" ] || fail "no session id -> '$got'"
got="$(env -u HQ_HANDOFF_ARCHIVE -u HQ_SESSION_ID CLAUDE_CODE_SESSION_ID="$SID" PATH="$bin:$PATH" FAKE_CALLS="$calls" \
  bash "$root/core/scripts/handoff-archive-decision.sh" --root "$root" --cwd "$plain" --thread "$thread" --args-file "$msgfile")"
[ "$got" = "archive: yes" ] || fail "session id from env -> '$got'"
pass "background work refuses; unverifiable background work refuses"

# 13. Pending asks: an ask from this session queued to the owner, or a
#     decision-queue row for one of its asks that is open or answered but
#     not yet relayed back.
asks="$root/workspace/reports/conduct/cl-x-asks.json"
printf '{"asks":{"%s:a1":{"session":"%s","ask_id":"a1","status":"relayed"},"other:a2":{"session":"other","ask_id":"a2","status":"queued"}}}\n' "$SID" "$SID" > "$asks"
expect "archive: yes" --msg "--archive"
printf '{"asks":{"%s:a1":{"session":"%s","ask_id":"a1","status":"queued"}}}\n' "$SID" "$SID" > "$asks"
expect "archive: no (pending ask waiting on the owner: a1)" --msg "--archive"
printf 'not json' > "$asks"
expect "archive: no (could not verify pending asks: cl-x-asks.json)" --msg "--archive"
rm "$asks"
dq="$root/workspace/reports/conduct/cl-x-decisions.jsonl"
printf '%s\n' '{"id":"dq_1","source":"ask","ref":"'"$SID"':a3","status":"open","question":"q"}' > "$dq"
expect "archive: no (pending ask waiting on the owner: a3)" --msg "--archive"
printf '%s\n' '{"id":"dq_1","status":"answered","answer":"ok"}' >> "$dq"
expect "archive: no (pending ask waiting on the owner: a3)" --msg "--archive"
printf '%s\n' '{"id":"dq_1","status":"relayed"}' >> "$dq"
expect "archive: yes" --msg "--archive"
printf '%s\n' '{"id":"dq_2","source":"ask","ref":"other:a4","status":"open"}' >> "$dq"
expect "archive: yes" --msg "--archive"
printf 'garbage\n' >> "$dq"
expect "archive: no (could not verify pending asks: cl-x-decisions.jsonl)" --msg "--archive"
rm "$dq"
pass "pending asks refuse; unreadable ask records refuse"

# 14. All clear: every check ran and passed.
: > "$calls"
expect "archive: yes" --msg "--archive" --cwd "$TMP_ROOT/wt"
grep -q '^gh pr list' "$calls" || fail "all-clear skipped the PR check"
grep -q '^hq lanes list' "$calls" || fail "all-clear skipped the lanes check"
grep -q '^hq monitor list' "$calls" || fail "all-clear skipped the monitor check"
pass "all-clear path archives after every check"

# /handoff-and-archive is a shortcut for /handoff --archive.
SHORTCUT="$SRC_ROOT/../.claude/skills/handoff-and-archive/SKILL.md"
HANDOFF="$SRC_ROOT/../.claude/skills/handoff/SKILL.md"
[ -f "$SHORTCUT" ] || fail "missing $SHORTCUT"
grep -q '^name: handoff-and-archive$' "$SHORTCUT" || fail "shortcut skill name"
grep -q '^description: "' "$SHORTCUT" || fail "shortcut description must be a quoted YAML scalar"
grep -q 'Invoke the `handoff` skill' "$SHORTCUT" || fail "shortcut does not invoke the handoff skill"
grep -q 'Pass `--archive`' "$SHORTCUT" || fail "shortcut does not pass --archive"
grep -q 'handoff-archive-decision.sh' "$SHORTCUT" || fail "shortcut does not defer to the archive decision"
grep -q '^### 7. Archive this session' "$HANDOFF" || fail "handoff skill has no Step 7"
step7="$(sed -n '/^### 7. Archive this session/,/^## /p' "$HANDOFF")"
printf '%s' "$step7" | grep -- '--args-file' >/dev/null || fail "Step 7 must pass the message through --args-file"
! printf '%s' "$step7" | grep -- '--args "' >/dev/null || fail "Step 7 still pastes the message into --args"
printf '%s' "$step7" | grep -- '--thread' >/dev/null || fail "Step 7 must pass --thread"
pass "/handoff-and-archive runs /handoff --archive and defers to Step 7"

echo "PASS: handoff-archive-decision"
