#!/usr/bin/env bash
# hq-core: public
# Regression: the PostToolUse tool-writes hook must only change toolWrites and
# updatedAt on ~/.hq/work-context/sessions/<sid>.json. Before this test the
# hook rewrote the file with a fixed printf and dropped companyUid, companySlug,
# projectId, taskId, startedAt, bindingEpisodeId, decision and the CLI's
# contextStatus on every Edit/Write/Bash redirect. On macOS/Linux the next
# reconcile re-established the company (attribution flickered); on Windows
# nothing repaired it, so attribution was permanently lost.
#
# Cases:
#   1. seeded compact JSON (jq available)      -> fields byte-identical
#   2. seeded pretty JSON (jq available)       -> fields byte-identical
#   3. seeded JSON with jq hidden from PATH    -> fields byte-identical (fallback)
#   4. absent file                             -> minimal stub with contextStatus=unresolved
#   5. existing file without counters gains them and keeps every other field
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="${TOOL_WRITES_HOOK:-$REPO_ROOT/core/hooks/PostToolUse/35-work-mesh-tool-writes.sh}"
[ -f "$HOOK" ] || { echo "FATAL: missing $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 1; }

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }

SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

HOME_DIR="$SANDBOX/home"
mkdir -p "$HOME_DIR/.hq/work-context/sessions" "$SANDBOX/bin"
export HOME="$HOME_DIR"
export WORK_MESH_HOME="$HOME_DIR"
export HQ_ROOT="$REPO_ROOT"
unset HQ_WORK_MESH_DISABLED HQ_DISABLED_HOOKS || true
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID HQ_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID || true

STATE_DIR="$HOME_DIR/.hq/work-context/sessions"

run_hook() {
  # $1 sid, $2 PATH override (optional)
  local sid="$1" path_override="${2:-$PATH}"
  printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"a.ts","old_string":"a","new_string":"b"}}' "$sid" \
    | env -u HQ_DISABLED_HOOKS -u HQ_WORK_MESH_DISABLED \
        HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" HQ_ROOT="$HQ_ROOT" PATH="$path_override" \
        bash "$HOOK" >/dev/null 2>&1
}

# Seeded state as the hq-cli reconcile/ack path writes it (superset of the stub).
seed_compact() {
  printf '{"contractVersion":1,"sessionId":"%s","contextStatus":"needs_project","companyUid":"co_01HXYZABC","companySlug":"acme","projectId":"proj-42","taskId":"task-7","startedAt":"2026-09-20T10:00:00.000Z","bindingEpisodeId":"ep-9","decision":{"kind":"bound","by":"user"},"toolWrites":3,"updatedAt":"2026-09-20T10:05:00.000Z"}\n' "$1"
}
seed_pretty() {
  printf '{\n  "contractVersion": 1,\n  "sessionId": "%s",\n  "contextStatus": "needs_project",\n  "companyUid": "co_01HXYZABC",\n  "companySlug": "acme",\n  "projectId": "proj-42",\n  "taskId": "task-7",\n  "startedAt": "2026-09-20T10:00:00.000Z",\n  "bindingEpisodeId": "ep-9",\n  "decision": {\n    "kind": "bound",\n    "by": "user"\n  },\n  "toolWrites": 3,\n  "updatedAt": "2026-09-20T10:05:00.000Z"\n}\n' "$1"
}

PRESERVED_KEYS='contractVersion sessionId contextStatus companyUid companySlug projectId taskId startedAt bindingEpisodeId decision'

check_preserved() {
  # $1 label, $2 before-file, $3 after-file
  local label="$1" before="$2" after="$3" k bv av
  if ! jq -e . "$after" >/dev/null 2>&1; then
    fail "$label: state file is not valid JSON after hook: $(cat "$after")"
    return
  fi
  for k in $PRESERVED_KEYS; do
    bv="$(jq -c --arg k "$k" '.[$k]' "$before")"
    av="$(jq -c --arg k "$k" '.[$k]' "$after")"
    if [ "$bv" = "$av" ]; then
      pass "$label: $k preserved ($av)"
    else
      fail "$label: $k changed: before=$bv after=$av"
    fi
  done
  local tw_b tw_a up_b up_a
  tw_b="$(jq -r '.toolWrites' "$before")"; tw_a="$(jq -r '.toolWrites' "$after")"
  [ "$tw_a" = "$((tw_b + 1))" ] && pass "$label: toolWrites $tw_b -> $tw_a" || fail "$label: toolWrites expected $((tw_b + 1)) got $tw_a"
  up_b="$(jq -r '.updatedAt' "$before")"; up_a="$(jq -r '.updatedAt' "$after")"
  if [ "$up_a" != "$up_b" ] && [ -n "$up_a" ] && [ "$up_a" != "null" ]; then
    pass "$label: updatedAt changed ($up_b -> $up_a)"
  else
    fail "$label: updatedAt not updated (before=$up_b after=$up_a)"
  fi
  local nb na
  nb="$(jq 'keys|length' "$before")"; na="$(jq 'keys|length' "$after")"
  [ "$nb" = "$na" ] && pass "$label: key count unchanged ($na)" || fail "$label: key count $nb -> $na"
}

# --- 1. compact seeded state, jq available ----------------------------------
sid=sid-compact
seed_compact "$sid" >"$STATE_DIR/$sid.json"
cp "$STATE_DIR/$sid.json" "$SANDBOX/before-compact.json"
run_hook "$sid"
check_preserved "compact+jq" "$SANDBOX/before-compact.json" "$STATE_DIR/$sid.json"

# --- 2. pretty seeded state, jq available -----------------------------------
sid=sid-pretty
seed_pretty "$sid" >"$STATE_DIR/$sid.json"
cp "$STATE_DIR/$sid.json" "$SANDBOX/before-pretty.json"
run_hook "$sid"
check_preserved "pretty+jq" "$SANDBOX/before-pretty.json" "$STATE_DIR/$sid.json"

# --- 3. seeded state with jq hidden (pure-shell fallback) --------------------
# Shadow jq with a failing stub at the front of PATH so the hook takes the
# no-jq branch while every other tool stays reachable.
printf '#!/bin/sh\nexit 127\n' >"$SANDBOX/bin/jq"
chmod +x "$SANDBOX/bin/jq"
NOJQ_PATH="$SANDBOX/bin:$PATH"
if [ "$(PATH="$NOJQ_PATH" jq -r '.a' <<<'{"a":1}' 2>/dev/null)" = "1" ]; then
  echo "FATAL: could not shadow jq on PATH" >&2; exit 1
fi
for variant in compact pretty; do
  sid="sid-nojq-$variant"
  "seed_$variant" "$sid" >"$STATE_DIR/$sid.json"
  cp "$STATE_DIR/$sid.json" "$SANDBOX/before-nojq-$variant.json"
  run_hook "$sid" "$NOJQ_PATH"
  check_preserved "$variant+nojq" "$SANDBOX/before-nojq-$variant.json" "$STATE_DIR/$sid.json"
done

# --- 4. absent file -> minimal stub ------------------------------------------
sid=sid-absent
rm -f "$STATE_DIR/$sid.json"
run_hook "$sid"
if [ -f "$STATE_DIR/$sid.json" ] && jq -e . "$STATE_DIR/$sid.json" >/dev/null 2>&1; then
  pass "absent: stub created and valid JSON"
  v="$(jq -r '.contextStatus' "$STATE_DIR/$sid.json")"; [ "$v" = "unresolved" ] && pass "absent: contextStatus=unresolved" || fail "absent: contextStatus=$v"
  v="$(jq -r '.toolWrites' "$STATE_DIR/$sid.json")"; [ "$v" = "1" ] && pass "absent: toolWrites=1" || fail "absent: toolWrites=$v"
  v="$(jq -r '.sessionId' "$STATE_DIR/$sid.json")"; [ "$v" = "$sid" ] && pass "absent: sessionId" || fail "absent: sessionId=$v"
  v="$(jq -r '.contractVersion' "$STATE_DIR/$sid.json")"; [ "$v" = "1" ] && pass "absent: contractVersion=1" || fail "absent: contractVersion=$v"
  v="$(jq -r '.updatedAt' "$STATE_DIR/$sid.json")"; [ -n "$v" ] && [ "$v" != "null" ] && pass "absent: updatedAt set" || fail "absent: updatedAt=$v"
  run_hook "$sid"
  v="$(jq -r '.toolWrites' "$STATE_DIR/$sid.json")"; [ "$v" = "2" ] && pass "absent: second bump -> 2" || fail "absent: second bump=$v"
else
  fail "absent: stub missing or invalid"
fi
sid=sid-absent-nojq
rm -f "$STATE_DIR/$sid.json"
run_hook "$sid" "$NOJQ_PATH"
if jq -e '.contextStatus=="unresolved" and .toolWrites==1 and .sessionId=="sid-absent-nojq" and .contractVersion==1' "$STATE_DIR/$sid.json" >/dev/null 2>&1; then
  pass "absent+nojq: stub created"
else
  fail "absent+nojq: stub wrong: $(cat "$STATE_DIR/$sid.json" 2>/dev/null)"
fi

# --- 5. existing file without toolWrites/updatedAt gains them, keeps the rest --
sid=sid-noctr
printf '{"contractVersion":1,"sessionId":"sid-noctr","contextStatus":"resolved","companyUid":"co_1","companySlug":"acme"}\n' >"$STATE_DIR/$sid.json"
run_hook "$sid"
if jq -e '.toolWrites==1 and .contextStatus=="resolved" and .companyUid=="co_1" and .companySlug=="acme" and (.updatedAt|type)=="string"' "$STATE_DIR/$sid.json" >/dev/null 2>&1; then
  pass "no-counter: toolWrites/updatedAt added, other fields kept"
else
  fail "no-counter: $(cat "$STATE_DIR/$sid.json")"
fi
run_hook "$sid" "$NOJQ_PATH"
if jq -e '.toolWrites==2 and .contextStatus=="resolved" and .companyUid=="co_1" and .companySlug=="acme" and (.updatedAt|type)=="string"' "$STATE_DIR/$sid.json" >/dev/null 2>&1; then
  pass "no-counter+nojq: second bump kept fields"
else
  fail "no-counter+nojq: $(cat "$STATE_DIR/$sid.json")"
fi
sid=sid-noctr-nojq
printf '{"contractVersion":1,"sessionId":"sid-noctr-nojq","contextStatus":"resolved","companyUid":"co_1"}\n' >"$STATE_DIR/$sid.json"
run_hook "$sid" "$NOJQ_PATH"
if jq -e '.toolWrites==1 and .contextStatus=="resolved" and .companyUid=="co_1" and (.updatedAt|type)=="string"' "$STATE_DIR/$sid.json" >/dev/null 2>&1; then
  pass "no-counter+nojq-first: counters added, fields kept"
else
  fail "no-counter+nojq-first: $(cat "$STATE_DIR/$sid.json")"
fi

# --- 6. malformed/partial JSON --------------------------------------------------
# jq present: the file cannot be parsed, so the hook must leave it byte-identical
# (no stub, no bump) rather than replace known-good fields.
sid=sid-malformed
printf '{"contractVersion":1,"sessionId":"sid-malformed","contextStatus":"needs_project","companyUid":"co_01HXYZABC","companySlug":"acme","projectId":"proj-42","startedAt":"2026-09-20T10:00:00.000Z","bindingEpisodeId":"ep-9","toolWrites":3,"updatedAt":"2026-09-20T10:05:00.000Z"' >"$STATE_DIR/$sid.json"
cp "$STATE_DIR/$sid.json" "$SANDBOX/before-malformed.json"
run_hook "$sid"
if cmp -s "$SANDBOX/before-malformed.json" "$STATE_DIR/$sid.json"; then
  pass "malformed+jq: file left byte-identical (bump skipped)"
else
  fail "malformed+jq: file was rewritten: $(cat "$STATE_DIR/$sid.json")"
fi
# jq absent: the sed fallback edits only the two counter values in place; every
# seeded field must still be present verbatim.
sid=sid-malformed-nojq
printf '{"contractVersion":1,"sessionId":"sid-malformed-nojq","contextStatus":"needs_project","companyUid":"co_01HXYZABC","companySlug":"acme","projectId":"proj-42","startedAt":"2026-09-20T10:00:00.000Z","bindingEpisodeId":"ep-9","toolWrites":3,"updatedAt":"2026-09-20T10:05:00.000Z"' >"$STATE_DIR/$sid.json"
run_hook "$sid" "$NOJQ_PATH"
after="$(cat "$STATE_DIR/$sid.json")"
for needle in '"contextStatus":"needs_project"' '"companyUid":"co_01HXYZABC"' '"companySlug":"acme"' '"projectId":"proj-42"' '"startedAt":"2026-09-20T10:00:00.000Z"' '"bindingEpisodeId":"ep-9"' '"sessionId":"sid-malformed-nojq"'; do
  case "$after" in
    *"$needle"*) pass "malformed+nojq: $needle kept" ;;
    *) fail "malformed+nojq: $needle lost: $after" ;;
  esac
done
case "$after" in
  *'"toolWrites": 4'*|*'"toolWrites":4'*) pass "malformed+nojq: toolWrites 3 -> 4" ;;
  *) fail "malformed+nojq: toolWrites not bumped: $after" ;;
esac
case "$after" in
  *'"updatedAt":"2026-09-20T10:05:00.000Z"'*) fail "malformed+nojq: updatedAt unchanged" ;;
  *) pass "malformed+nojq: updatedAt changed" ;;
esac

# --- 7. contextStatus "bound" survives a bump ---------------------------------
for variant in jq nojq; do
  sid="sid-bound-$variant"
  printf '{"contractVersion":1,"sessionId":"%s","contextStatus":"bound","companyUid":"co_01HXYZABC","companySlug":"acme","projectId":"proj-42","taskId":"task-7","bindingEpisodeId":"ep-9","toolWrites":5,"updatedAt":"2026-09-20T10:05:00.000Z"}\n' "$sid" >"$STATE_DIR/$sid.json"
  if [ "$variant" = nojq ]; then run_hook "$sid" "$NOJQ_PATH"; else run_hook "$sid"; fi
  if jq -e '.contextStatus=="bound" and .toolWrites==6 and .companyUid=="co_01HXYZABC" and .companySlug=="acme" and .projectId=="proj-42" and .taskId=="task-7" and .bindingEpisodeId=="ep-9" and .updatedAt!="2026-09-20T10:05:00.000Z"' "$STATE_DIR/$sid.json" >/dev/null 2>&1; then
    pass "bound+$variant: contextStatus bound survives, toolWrites 5 -> 6"
  else
    fail "bound+$variant: $(cat "$STATE_DIR/$sid.json")"
  fi
done

# --- 8. concurrent writer between the hook's read and its mv ------------------
# The hook reads a company-less file, then (test seam) sleeps 0.4s; a
# background writer replaces the file with the CLI's bound state the way
# hq-cli atomicWriteFile does (same-dir tmp + rename). The re-read before mv
# must pick up the company, and toolWrites must be bumped from the new body.
for variant in jq nojq; do
  sid="sid-race-$variant"
  printf '{"contractVersion":1,"sessionId":"%s","contextStatus":"unresolved","toolWrites":1,"updatedAt":"2026-09-20T10:05:00.000Z"}\n' "$sid" >"$STATE_DIR/$sid.json"
  p="$PATH"; [ "$variant" = nojq ] && p="$NOJQ_PATH"
  (
    sleep 0.15
    printf '{"contractVersion":1,"sessionId":"%s","contextStatus":"bound","companyUid":"co_RACE","companySlug":"acme","projectId":"proj-42","bindingEpisodeId":"ep-9","toolWrites":1,"updatedAt":"2026-09-20T10:06:00.000Z"}\n' "$sid" >"$STATE_DIR/.$sid.json.tmp.writer"
    mv -f -- "$STATE_DIR/.$sid.json.tmp.writer" "$STATE_DIR/$sid.json"
  ) &
  writer=$!
  printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"a.ts"}}' "$sid" \
    | env -u HQ_DISABLED_HOOKS -u HQ_WORK_MESH_DISABLED \
        HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" HQ_ROOT="$HQ_ROOT" PATH="$p" \
        WORK_MESH_BUMP_TEST_SLEEP_AFTER_READ=0.4 \
        bash "$HOOK" >/dev/null 2>&1
  wait "$writer" 2>/dev/null || true
  if jq -e '.companyUid=="co_RACE" and .companySlug=="acme" and .contextStatus=="bound" and .projectId=="proj-42" and .bindingEpisodeId=="ep-9" and .toolWrites==2' "$STATE_DIR/$sid.json" >/dev/null 2>&1; then
    pass "race+$variant: company written mid-bump survives; toolWrites bumped from the new body"
  else
    fail "race+$variant: $(cat "$STATE_DIR/$sid.json")"
  fi
  [ -d "$STATE_DIR/$sid.json.lock" ] && fail "race+$variant: lock dir left behind" || pass "race+$variant: lock released"
done

# --- 9. lock held by another process -> bump skipped, file untouched -----------
sid=sid-locked
seed_compact "$sid" >"$STATE_DIR/$sid.json"
cp "$STATE_DIR/$sid.json" "$SANDBOX/before-locked.json"
mkdir -p "$STATE_DIR/$sid.json.lock"
date +%s >"$STATE_DIR/$sid.json.lock/ts"
run_hook "$sid"
if cmp -s "$SANDBOX/before-locked.json" "$STATE_DIR/$sid.json"; then
  pass "locked: fresh lock held elsewhere -> bump skipped, file byte-identical"
else
  fail "locked: file changed under a held lock: $(cat "$STATE_DIR/$sid.json")"
fi
[ -d "$STATE_DIR/$sid.json.lock" ] && pass "locked: foreign fresh lock not removed" || fail "locked: foreign fresh lock was removed"
# Stale lock (older than 5s) is reclaimed and the bump proceeds.
printf '%s\n' "$(( $(date +%s) - 60 ))" >"$STATE_DIR/$sid.json.lock/ts"
run_hook "$sid"
if jq -e '.toolWrites==4 and .companyUid=="co_01HXYZABC" and .contextStatus=="needs_project"' "$STATE_DIR/$sid.json" >/dev/null 2>&1; then
  pass "locked: stale lock reclaimed, bump applied, fields kept"
else
  fail "locked: stale lock not reclaimed: $(cat "$STATE_DIR/$sid.json")"
fi
[ -d "$STATE_DIR/$sid.json.lock" ] && fail "locked: lock left behind after reclaim" || pass "locked: lock released after reclaim"

# --- mode 600 kept ----------------------------------------------------------
mode="$(stat -c '%a' "$STATE_DIR/sid-compact.json" 2>/dev/null || stat -f '%Lp' "$STATE_DIR/sid-compact.json" 2>/dev/null || true)"
case "$mode" in
  600) pass "state file mode 600" ;;
  "") echo "SKIP: stat mode unavailable" ;;
  *) case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "SKIP: mode check on Windows ($mode)" ;; *) fail "state file mode $mode != 600" ;; esac ;;
esac

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
