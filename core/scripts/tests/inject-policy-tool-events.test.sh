#!/usr/bin/env bash
# Regression contract for policy reminder delivery by tool event.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="${HQ_TEST_INJECT_POLICY_HOOK:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}"
TMP="$(mktemp -d)"
trap '[ "${HP17_KEEP_TMP:-0}" = 1 ] || rm -rf "$TMP"' EXIT
mkdir -p "$TMP/core/policies" "$TMP/bin"
cat > "$TMP/bin/hq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' 'hq 5.342.5'
  exit 0
fi
event=""
with_intent=0
for arg in "$@"; do
  case "$arg" in
    PreToolUse|PostToolUse|UserPromptSubmit|AssistantIntent) event="$arg" ;;
    --with-assistant-intent) with_intent=1 ;;
  esac
done
case "$event" in
  PreToolUse) facts='git push' ;;
  PostToolUse) facts='completed' ;;
  UserPromptSubmit) facts='heldfixtureword' ;;
  *) facts="" ;;
esac
if [ "$with_intent" -eq 1 ]; then
  printf '%s\n\n' "$facts"
else
  printf '%s\n' "$facts"
fi
EOF
chmod +x "$TMP/bin/hq"
cat > "$TMP/core/policies/tool-event-default.md" <<'EOF'
---
when: git && push
---
## Rule
Default tool event fixture.
EOF
cat > "$TMP/core/policies/tool-event-post.md" <<'EOF'
---
when: completed
on: [PostToolUse]
---
## Rule
Post tool event fixture.
EOF
cat > "$TMP/core/policies/tool-event-pre.md" <<'EOF'
---
when: git && push
on: [PreToolUse]
---
## Rule
Explicit PreToolUse fixture.
EOF
cat > "$TMP/core/policies/tool-event-background-only.md" <<'EOF'
---
when: run_in_background
---
## Rule
Background marker is only available before the tool call.
EOF

failures=0
check() {
  local label="$1" ok="$2"
  if [ "$ok" = 1 ]; then printf 'ok   %s\n' "$label"; else printf 'FAIL %s\n' "$label"; failures=$((failures+1)); fi
}
run_hook() {
  local sid="$1" event="$2" harness="$3" legacy="$4" output="$5" command="$6" response="$7"
  jq -cn --arg sid "$sid" --arg event "$event" --arg command "$command" --arg response "$response" \
    '{session_id:$sid,hook_event_name:$event,tool_name:"Bash",cwd:"/tmp",tool_input:{command:$command},tool_response:$response}' \
    | PATH="$TMP/bin:$PATH" HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" HQ_HARNESS="$harness" HQ_POLICY_TOOL_EVENTS="$legacy" \
      bash "$HOOK" > "$output" 2>"${output}.stderr"
}

run_hook pre-default PreToolUse claude off "$TMP/pre-default" 'git push origin test' ''
check 'PreToolUse default emits nothing' "$( [ ! -s "$TMP/pre-default" ] && echo 1 || echo 0 )"
check 'PreToolUse default ledgers no slug' "$( [ ! -e "$TMP/workspace/orchestrator/policy-trigger-state/pre-default.txt" ] && echo 1 || echo 0 )"

run_hook post-default PostToolUse claude off "$TMP/post-default" 'git push origin test' 'completed'
check 'PostToolUse command facts match omitted on' "$(jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | contains("tool-event-default"))' "$TMP/post-default" >/dev/null 2>&1 && echo 1 || echo 0)"
check 'PostToolUse is a JSON additionalContext envelope' "$(jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | type == "string")' "$TMP/post-default" >/dev/null 2>&1 && echo 1 || echo 0)"

jq -cn '{session_id:"post-background",hook_event_name:"PostToolUse",tool_name:"Bash",cwd:"/tmp",tool_input:{command:"echo done",run_in_background:true},tool_response:{stdout:"done"}}' \
  | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" HQ_HARNESS=claude HQ_POLICY_TOOL_EVENTS=off \
    bash "$HOOK" > "$TMP/post-background" 2>"$TMP/stderr"
check 'PostToolUse command facts do not recreate the PreToolUse-only background marker' "$( [ ! -s "$TMP/post-background" ] && echo 1 || echo 0 )"

FAIL_ROOT="$TMP/derive-failure"
mkdir -p "$FAIL_ROOT/.claude/hooks" "$FAIL_ROOT/core/scripts" "$FAIL_ROOT/core/policies"
cp "$HOOK" "$FAIL_ROOT/.claude/hooks/inject-policy-on-trigger.sh"
cp "$ROOT/core/scripts/hook-lib.sh" "$FAIL_ROOT/core/scripts/hook-lib.sh"
cat > "$FAIL_ROOT/core/scripts/eval-trigger.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAIL_ROOT/core/scripts/derive-trigger-facts.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'derive-trigger-facts.sh: simulated failure' >&2
exit 127
EOF
chmod +x "$FAIL_ROOT/core/scripts/eval-trigger.sh" "$FAIL_ROOT/core/scripts/derive-trigger-facts.sh"
if jq -cn '{session_id:"post-derive-failure",hook_event_name:"PostToolUse",tool_name:"Bash",cwd:"/tmp",tool_input:{command:"git push origin test"},tool_response:{exit_code:0}}' | env HQ_ROOT="$FAIL_ROOT" CLAUDE_PROJECT_DIR="$FAIL_ROOT" HQ_HARNESS=claude HQ_POLICY_TOOL_EVENTS=off HQ_POLICY_FACT_HELPER_DISABLE=1 bash "$FAIL_ROOT/.claude/hooks/inject-policy-on-trigger.sh" > "$TMP/post-derive-failure" 2> "$TMP/post-derive-failure.stderr"; then
  failed_derive_rc=0
else
  failed_derive_rc=$?
fi
printf '%s\n' 'derive-trigger-facts.sh: simulated failure' > "$TMP/post-derive-failure.expected"
check 'PostToolUse failed derive exits zero and emits no stdout' "$( [ "$failed_derive_rc" -eq 0 ] && [ ! -s "$TMP/post-derive-failure" ] && echo 1 || echo 0 )"
check 'PostToolUse failed derive stderr is emitted once' "$(cmp -s "$TMP/post-derive-failure.expected" "$TMP/post-derive-failure.stderr" && echo 1 || echo 0)"

mkdir -p "$TMP/workspace/orchestrator/policy-enforcement"
printf 'old-reactive\tcore\t%s\thard\told row\treactive\nold-baseline\tcore\t%s\thard\tbaseline row\tbaseline\n' \
  "$TMP/core/policies/tool-event-default.md" "$TMP/core/policies/tool-event-default.md" \
  > "$TMP/workspace/orchestrator/policy-enforcement/prune-session.policies.tsv"
jq -cn '{session_id:"prune-session",hook_event_name:"UserPromptSubmit",prompt:"No policy trigger in this new turn."}' \
  | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" HQ_HARNESS=claude HQ_POLICY_TOOL_EVENTS=off bash "$HOOK" > "$TMP/prune-empty-match" 2>"$TMP/stderr"
check 'UserPromptSubmit prunes old reactive rows when the new turn has no matches' "$(awk -F '\t' '$1 == "old-reactive" {found=1} END {exit found}' "$TMP/workspace/orchestrator/policy-enforcement/prune-session.policies.tsv" && echo 1 || echo 0)"
check 'pruning retains baseline rows' "$(awk -F '\t' '$1 == "old-baseline" {found=1} END {exit !found}' "$TMP/workspace/orchestrator/policy-enforcement/prune-session.policies.tsv" && echo 1 || echo 0)"

run_hook pre-legacy PreToolUse claude legacy "$TMP/pre-legacy" 'git push origin test' ''
check 'legacy restores PreToolUse policy evaluation' "$(grep -q 'tool-event-pre' "$TMP/pre-legacy" && echo 1 || echo 0)"
check 'legacy restores omitted-on PreToolUse default' "$(grep -q 'tool-event-default' "$TMP/pre-legacy" && echo 1 || echo 0)"

# Grok delivers PostToolUse additionalContext. This hook used to skip the event
# for Grok, so no tool-triggered policy reached a Grok session.
run_hook post-grok PostToolUse grok off "$TMP/post-grok" 'git push origin test' 'completed'
check 'Grok PostToolUse returns the policy as additionalContext' "$(jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | contains("tool-event-default") and contains("tool-event-post"))' "$TMP/post-grok" >/dev/null 2>&1 && echo 1 || echo 0)"
check 'Grok PostToolUse records the policy it returned' "$(grep -Fxq 'tool-event-default' "$TMP/workspace/orchestrator/policy-trigger-state/post-grok.txt" 2>/dev/null && echo 1 || echo 0)"

# Held reminders. The Grok adapter (HQ_HARNESS=grok) marks an event whose
# output Grok does not hand to the model with
# HQ_POLICY_REMINDER_DELIVERABLE=0. The reminder is then
# kept under <session>.held and recorded only in the ledger copies there; the
# session's own ledgers change when the held text is handed out.
STATE="$TMP/workspace/orchestrator/policy-trigger-state"
HELD_TOKEN='held-token-7c1d94e2'
cat > "$TMP/core/policies/held-prompt-fixture.md" <<EOF
---
when: heldfixtureword
on: [UserPromptSubmit]
enforcement: hard
---
## Rule
Held prompt fixture. Token $HELD_TOKEN.
EOF
run_prompt() { # <session> <deliverable: 0|1|unset> <output> [extra env assignment]
  local sid="$1" deliverable="$2" output="$3" extra="${4:-HQ_TEST_UNUSED=1}"
  local env_args=(PATH="$TMP/bin:$PATH" HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" HQ_HARNESS="${HELD_HARNESS:-grok}" "$extra")
  [ "$deliverable" = unset ] || env_args+=(HQ_POLICY_REMINDER_DELIVERABLE="$deliverable")
  jq -cn --arg sid "$sid" '{session_id:$sid,hook_event_name:"UserPromptSubmit",cwd:"/tmp",prompt:"Please look at heldfixtureword now."}' \
    | env -u HQ_POLICY_REMINDER_DELIVERABLE "${env_args[@]}" bash "$HOOK" > "$output" 2>"${output}.stderr"
}
flush_held() { # <session> <max-bytes> <output>
  jq -cn --arg sid "$1" '{session_id:$sid,hook_event_name:"PostToolUse",tool_name:"Read",cwd:"/tmp",tool_input:{file_path:"/tmp/x"}}' \
    | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" HQ_HARNESS=grok HQ_POLICY_FLUSH_HELD=1 HQ_POLICY_FLUSH_HELD_MAX_BYTES="$2" \
      bash "$HOOK" > "$3" 2>"${3}.stderr"
}
session_ledgers_name() { # <session> <slug>: 0 when any of the session's own ledger files names the slug
  local f
  for f in "$STATE/$1".*; do
    [ -f "$f" ] || continue
    grep -Fq "$2" "$f" && return 0
  done
  return 1
}

run_prompt held-a 0 "$TMP/held-a-1"
check 'undeliverable event prints no reminder' "$( [ ! -s "$TMP/held-a-1" ] && echo 1 || echo 0 )"
check 'undeliverable event records nothing in the session ledgers' "$(session_ledgers_name held-a held-prompt-fixture && echo 0 || echo 1)"
check 'undeliverable event holds the reminder text' "$(grep -Fq "$HELD_TOKEN" "$STATE/held-a.held/out" 2>/dev/null && echo 1 || echo 0)"
check 'holding a reminder writes one stderr line' "$( [ "$(grep -c 'held .* bytes of policy reminder' "$TMP/held-a-1.stderr")" = 1 ] && echo 1 || echo 0 )"
run_prompt held-a 0 "$TMP/held-a-2"
check 'a held policy is not held twice' "$( [ "$(grep -Fc "$HELD_TOKEN" "$STATE/held-a.held/out" 2>/dev/null)" = 1 ] && echo 1 || echo 0 )"
check 'a second undeliverable event still records nothing in the session ledgers' "$(session_ledgers_name held-a held-prompt-fixture && echo 0 || echo 1)"
flush_held held-a 20 "$TMP/held-a-small"
check 'held text larger than the room is not handed out' "$( [ ! -s "$TMP/held-a-small" ] && grep -Fq "$HELD_TOKEN" "$STATE/held-a.held/out" 2>/dev/null && echo 1 || echo 0 )"
check 'held text that was not handed out is still unrecorded' "$(session_ledgers_name held-a held-prompt-fixture && echo 0 || echo 1)"
flush_held held-a 0 "$TMP/held-a-flush"
check 'handing out held text prints it' "$(grep -Fq "$HELD_TOKEN" "$TMP/held-a-flush" && echo 1 || echo 0)"
check 'handing out held text records the policy in the session ledger' "$(grep -Fxq 'held-prompt-fixture' "$STATE/held-a.txt" 2>/dev/null && echo 1 || echo 0)"
check 'handing out held text removes the held directory' "$( [ ! -e "$STATE/held-a.held" ] && echo 1 || echo 0 )"
flush_held held-a 0 "$TMP/held-a-flush-again"
check 'held text is handed out once' "$( [ ! -s "$TMP/held-a-flush-again" ] && echo 1 || echo 0 )"
run_prompt held-a unset "$TMP/held-a-3"
check 'a delivered held policy is not shown in full again' "$(grep -Fq "$HELD_TOKEN" "$TMP/held-a-3" && echo 0 || echo 1)"

run_prompt held-b unset "$TMP/held-b-1"
check 'a delivering host still prints the reminder at the prompt' "$(grep -Fq "$HELD_TOKEN" "$TMP/held-b-1" && echo 1 || echo 0)"
check 'a delivering host still records the policy at the prompt' "$(grep -Fxq 'held-prompt-fixture' "$STATE/held-b.txt" 2>/dev/null && echo 1 || echo 0)"
check 'a delivering host holds nothing' "$( [ ! -e "$STATE/held-b.held" ] && echo 1 || echo 0 )"

run_prompt held-c 0 "$TMP/held-c-1" HQ_POLICY_HELD_MAX_BYTES=10
check 'a reminder over the held limit is not held' "$( [ ! -s "$TMP/held-c-1" ] && [ ! -e "$STATE/held-c.held" ] && echo 1 || echo 0 )"
check 'a reminder over the held limit is not recorded' "$(session_ledgers_name held-c held-prompt-fixture && echo 0 || echo 1)"
check 'a reminder over the held limit is reported on stderr' "$(grep -Fq 'HQ_POLICY_HELD_MAX_BYTES=10' "$TMP/held-c-1.stderr" && echo 1 || echo 0)"

# The hold variables belong to the Grok adapter. Set in a Claude Code or Codex
# environment they change nothing: the reminder prints and is recorded.
for host in claude codex; do
  HELD_HARNESS="$host" run_prompt "plain-$host" unset "$TMP/plain-$host"
  HELD_HARNESS="$host" run_prompt "undeliv-$host" 0 "$TMP/undeliv-$host"
  HELD_HARNESS="$host" run_prompt "flush-$host" unset "$TMP/flush-$host" HQ_POLICY_FLUSH_HELD=1
  HELD_HARNESS="$host" run_prompt "drop-$host" unset "$TMP/drop-$host" HQ_POLICY_DROP_HELD=1
  for variant in undeliv flush drop; do
    check "$host output is unchanged with the $variant variable set" "$(grep -Fq "$HELD_TOKEN" "$TMP/plain-$host" && cmp -s "$TMP/plain-$host" "$TMP/$variant-$host" && echo 1 || echo 0)"
    check "$host records the policy and holds nothing with the $variant variable set" "$(grep -Fxq 'held-prompt-fixture' "$STATE/$variant-$host.txt" 2>/dev/null && [ ! -e "$STATE/$variant-$host.held" ] && echo 1 || echo 0)"
  done
done

# A compaction purges the session ledgers. The ledger copies kept with held
# text are purged too, so handing the text out afterwards records nothing.
purge_ledgers() { # <session>
  jq -cn --arg sid "$1" '{session_id:$sid,hook_event_name:"PreCompact"}' \
    | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/.claude/hooks/purge-policy-ledger-precompact.sh"
}
held_copies_name() { # <session> <slug>: 0 when a held ledger copy names the slug
  local f
  for f in "$STATE/$1.held/$1".*; do
    [ -f "$f" ] || continue
    grep -Fq "$2" "$f" && return 0
  done
  return 1
}
run_prompt held-p 0 "$TMP/held-p-1"
check 'a held policy is recorded in the held ledger copies' "$(held_copies_name held-p held-prompt-fixture && echo 1 || echo 0)"
purge_ledgers held-p
check 'the compaction purge keeps the held text' "$(grep -Fq "$HELD_TOKEN" "$STATE/held-p.held/out" 2>/dev/null && echo 1 || echo 0)"
check 'the compaction purge removes the held ledger copies' "$(held_copies_name held-p held-prompt-fixture && echo 0 || echo 1)"
run_prompt held-p 0 "$TMP/held-p-2"
check 'text held before a purge is not held twice after it' "$( [ "$(grep -Fc "$HELD_TOKEN" "$STATE/held-p.held/out" 2>/dev/null)" = 1 ] && echo 1 || echo 0 )"
purge_ledgers held-p
flush_held held-p 0 "$TMP/held-p-flush"
check 'held text is still handed out after a purge' "$(grep -Fq "$HELD_TOKEN" "$TMP/held-p-flush" && echo 1 || echo 0)"
check 'handing out held text after a purge does not undo the purge' "$(session_ledgers_name held-p held-prompt-fixture && echo 0 || echo 1)"

# Session end removes held text without recording it as shown.
run_prompt held-e 0 "$TMP/held-e-1"
check 'text is held before the session ends' "$(grep -Fq "$HELD_TOKEN" "$STATE/held-e.held/out" 2>/dev/null && echo 1 || echo 0)"
jq -cn '{session_id:"held-e",hook_event_name:"SessionEnd"}' \
  | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" HQ_HARNESS=grok HQ_POLICY_DROP_HELD=1 bash "$HOOK" > "$TMP/held-e-drop" 2>"$TMP/held-e-drop.stderr"
check 'session end removes the held text' "$( [ ! -e "$STATE/held-e.held" ] && [ ! -s "$TMP/held-e-drop" ] && echo 1 || echo 0 )"
check 'session end does not record held text as shown' "$(session_ledgers_name held-e held-prompt-fixture && echo 0 || echo 1)"

# Without a session id from the host nothing is held: a made-up id can be
# reused by a later session, which would then receive this one's text.
run_prompt held-n 0 "$TMP/held-n-1" HQ_POLICY_SESSION_ID_SYNTHETIC=1
check 'a made-up session id holds nothing' "$( [ ! -s "$TMP/held-n-1" ] && [ ! -e "$STATE/held-n.held" ] && echo 1 || echo 0 )"
check 'a made-up session id records nothing' "$(session_ledgers_name held-n held-prompt-fixture && echo 0 || echo 1)"
check 'a dropped reminder is reported on stderr' "$(grep -Fq 'no session id' "$TMP/held-n-1.stderr" && echo 1 || echo 0)"

# A prompt consumes the deferred queue. On an undeliverable prompt the
# session's own queue keeps the rule until the held text is handed out, and a
# refused hold leaves it queued.
printf 'held-prompt-fixture\n' > "$STATE/held-d.deferred.tsv"
run_prompt held-d 0 "$TMP/held-d-1"
check 'a held prompt leaves the session deferred queue as it was' "$(grep -Fxq 'held-prompt-fixture' "$STATE/held-d.deferred.tsv" 2>/dev/null && grep -Fq "$HELD_TOKEN" "$STATE/held-d.held/out" 2>/dev/null && echo 1 || echo 0)"
check 'a held prompt consumes the rule in the held queue copy' "$( [ -f "$STATE/held-d.held/held-d.deferred.tsv" ] && ! grep -Fxq 'held-prompt-fixture' "$STATE/held-d.held/held-d.deferred.tsv" && echo 1 || echo 0 )"
flush_held held-d 0 "$TMP/held-d-flush"
check 'handing out the held text consumes the session deferred queue' "$(grep -Fxq 'held-prompt-fixture' "$STATE/held-d.deferred.tsv" 2>/dev/null && echo 0 || echo 1)"
printf 'held-prompt-fixture\n' > "$STATE/held-r.deferred.tsv"
run_prompt held-r 0 "$TMP/held-r-1" HQ_POLICY_HELD_MAX_BYTES=10
check 'a refused hold keeps the deferred rule queued' "$( [ ! -e "$STATE/held-r.held" ] && grep -Fxq 'held-prompt-fixture' "$STATE/held-r.deferred.tsv" 2>/dev/null && echo 1 || echo 0 )"
# Links in the held store. The store is written with shell redirection, so a
# link planted at the held directory or at a file in it would redirect the
# write. The hook refuses such a store: the file or directory the link names is
# unchanged, the event's result is what a clean session gets (exit 0, no
# stdout), nothing is recorded as shown, and stderr says why.
OUTSIDE="$TMP/outside"
mkdir -p "$OUTSIDE"
plant_victim() { # <name>: a file outside the state directory, with a kept copy
  printf 'outside content of %s\n' "$1" > "$OUTSIDE/$1"
  cp "$OUTSIDE/$1" "$OUTSIDE/$1.orig"
}
victim_unchanged() { # <name>
  cmp -s "$OUTSIDE/$1" "$OUTSIDE/$1.orig"
}
link_count() { # <file>
  stat -c %h "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null
}
refused_like_clean() { # <output>: no stdout and a refusal line on stderr
  [ ! -s "$1" ] && grep -q 'held-reminder store refused' "$1.stderr"
}
clean_rc=0
run_prompt link-clean 0 "$TMP/link-clean" || clean_rc=$?
check 'a clean session exits 0 with no stdout on an undeliverable event' "$( [ "$clean_rc" -eq 0 ] && [ ! -s "$TMP/link-clean" ] && echo 1 || echo 0 )"

# Symlink at the held file, pointing at a file with content.
plant_victim sym-full
mkdir -p "$STATE/link-sym.held"
ln -s "$OUTSIDE/sym-full" "$STATE/link-sym.held/out"
link_rc=0
run_prompt link-sym 0 "$TMP/link-sym" || link_rc=$?
check 'symlinked held file: the outside file is unchanged' "$(victim_unchanged sym-full && echo 1 || echo 0)"
check 'symlinked held file: the hook result is unchanged' "$( [ "$link_rc" -eq "$clean_rc" ] && refused_like_clean "$TMP/link-sym" && echo 1 || echo 0 )"
check 'symlinked held file: the reminder is dropped unrecorded' "$(session_ledgers_name link-sym held-prompt-fixture && echo 0 || echo 1)"
check 'symlinked held file: the planted store is removed' "$( [ ! -e "$STATE/link-sym.held" ] && [ ! -L "$STATE/link-sym.held" ] && echo 1 || echo 0 )"
run_prompt link-sym 0 "$TMP/link-sym-2"
check 'symlinked held file: the next event holds in a new store' "$(grep -Fq "$HELD_TOKEN" "$STATE/link-sym.held/out" 2>/dev/null && [ ! -L "$STATE/link-sym.held/out" ] && victim_unchanged sym-full && echo 1 || echo 0)"

# Symlink at the held file, pointing at an empty file and at a missing file.
: > "$OUTSIDE/sym-empty"
mkdir -p "$STATE/link-empty.held" "$STATE/link-dangling.held"
ln -s "$OUTSIDE/sym-empty" "$STATE/link-empty.held/out"
ln -s "$OUTSIDE/sym-missing" "$STATE/link-dangling.held/out"
run_prompt link-empty 0 "$TMP/link-empty"
run_prompt link-dangling 0 "$TMP/link-dangling"
check 'symlink to an empty file: the outside file stays empty' "$( [ -f "$OUTSIDE/sym-empty" ] && [ ! -s "$OUTSIDE/sym-empty" ] && echo 1 || echo 0 )"
check 'symlink to a missing file: the outside file is not created' "$( [ ! -e "$OUTSIDE/sym-missing" ] && echo 1 || echo 0 )"
check 'symlink to an empty or missing file: the held file is a new regular file' "$( [ -f "$STATE/link-empty.held/out" ] && [ ! -L "$STATE/link-empty.held/out" ] && [ -f "$STATE/link-dangling.held/out" ] && [ ! -L "$STATE/link-dangling.held/out" ] && echo 1 || echo 0 )"

# Hard link at the held file.
plant_victim hard
mkdir -p "$STATE/link-hard.held"
ln "$OUTSIDE/hard" "$STATE/link-hard.held/out"
link_rc=0
run_prompt link-hard 0 "$TMP/link-hard" || link_rc=$?
check 'hardlinked held file: the outside file is unchanged' "$(victim_unchanged hard && [ "$(link_count "$OUTSIDE/hard")" = 1 ] && echo 1 || echo 0)"
check 'hardlinked held file: the hook result is unchanged' "$( [ "$link_rc" -eq "$clean_rc" ] && refused_like_clean "$TMP/link-hard" && echo 1 || echo 0 )"
check 'hardlinked held file: the reminder is dropped unrecorded' "$(session_ledgers_name link-hard held-prompt-fixture && echo 0 || echo 1)"

# Symlink at the held directory, pointing at a directory that has an out file
# and a file named like a ledger copy.
mkdir -p "$OUTSIDE/dir"
printf 'outside out\n' > "$OUTSIDE/dir/out"
printf 'outside ledger\n' > "$OUTSIDE/dir/link-dir.txt"
cp -R "$OUTSIDE/dir" "$OUTSIDE/dir.orig"
ln -s "$OUTSIDE/dir" "$STATE/link-dir.held"
link_rc=0
run_prompt link-dir 0 "$TMP/link-dir" || link_rc=$?
check 'symlinked held directory: the outside directory is unchanged' "$(diff -r "$OUTSIDE/dir" "$OUTSIDE/dir.orig" >/dev/null 2>&1 && echo 1 || echo 0)"
check 'symlinked held directory: the hook result is unchanged' "$( [ "$link_rc" -eq "$clean_rc" ] && refused_like_clean "$TMP/link-dir" && echo 1 || echo 0 )"
check 'symlinked held directory: the reminder is dropped unrecorded' "$(session_ledgers_name link-dir held-prompt-fixture && echo 0 || echo 1)"
# Same link, target without an out file: the link is replaced by a new directory.
mkdir -p "$OUTSIDE/dir-empty"
ln -s "$OUTSIDE/dir-empty" "$STATE/link-dir-empty.held"
run_prompt link-dir-empty 0 "$TMP/link-dir-empty"
check 'symlinked held directory without held text: nothing is written under the target' "$( [ -z "$(ls -A "$OUTSIDE/dir-empty")" ] && [ ! -L "$STATE/link-dir-empty.held" ] && echo 1 || echo 0 )"
# A compaction purge does not remove files under a symlinked held directory.
printf 'outside ledger\n' > "$OUTSIDE/dir/link-purge.txt"
ln -s "$OUTSIDE/dir" "$STATE/link-purge.held"
purge_ledgers link-purge
check 'symlinked held directory: a purge leaves the outside files in place' "$( [ -f "$OUTSIDE/dir/link-purge.txt" ] && echo 1 || echo 0 )"
rm -f "$OUTSIDE/dir/link-purge.txt" "$STATE/link-purge.held"

# Symlink and hard link at a ledger copy inside a real held directory.
plant_victim ledger-sym
plant_victim ledger-hard
run_prompt link-ledger-sym 0 "$TMP/link-ledger-sym-0"
run_prompt link-ledger-hard 0 "$TMP/link-ledger-hard-0"
rm -f "$STATE/link-ledger-sym.held/link-ledger-sym.txt" "$STATE/link-ledger-hard.held/link-ledger-hard.seen.tsv"
ln -s "$OUTSIDE/ledger-sym" "$STATE/link-ledger-sym.held/link-ledger-sym.txt"
ln "$OUTSIDE/ledger-hard" "$STATE/link-ledger-hard.held/link-ledger-hard.seen.tsv"
link_rc=0
run_prompt link-ledger-sym 0 "$TMP/link-ledger-sym" || link_rc=$?
check 'symlinked ledger copy: the outside file is unchanged' "$(victim_unchanged ledger-sym && echo 1 || echo 0)"
check 'symlinked ledger copy: the hook result is unchanged' "$( [ "$link_rc" -eq "$clean_rc" ] && refused_like_clean "$TMP/link-ledger-sym" && echo 1 || echo 0 )"
link_rc=0
run_prompt link-ledger-hard 0 "$TMP/link-ledger-hard" || link_rc=$?
check 'hardlinked ledger copy: the outside file is unchanged' "$(victim_unchanged ledger-hard && echo 1 || echo 0)"
check 'hardlinked ledger copy: the hook result is unchanged' "$( [ "$link_rc" -eq "$clean_rc" ] && refused_like_clean "$TMP/link-ledger-hard" && echo 1 || echo 0 )"

# Handing out: a linked held file is not read, and a linked ledger copy is not
# moved into the session's ledgers.
plant_victim flush-sym
mkdir -p "$STATE/link-flush.held"
ln -s "$OUTSIDE/flush-sym" "$STATE/link-flush.held/out"
link_rc=0
flush_held link-flush 0 "$TMP/link-flush" || link_rc=$?
check 'symlinked held file: handing out prints nothing from the outside file' "$( [ "$link_rc" -eq 0 ] && [ ! -s "$TMP/link-flush" ] && victim_unchanged flush-sym && echo 1 || echo 0 )"
plant_victim flush-ledger
run_prompt link-flush-ledger 0 "$TMP/link-flush-ledger-0"
rm -f "$STATE/link-flush-ledger.held/link-flush-ledger.txt"
ln -s "$OUTSIDE/flush-ledger" "$STATE/link-flush-ledger.held/link-flush-ledger.txt"
flush_held link-flush-ledger 0 "$TMP/link-flush-ledger"
check 'symlinked ledger copy: handing out moves no link into the session ledgers' "$( [ ! -s "$TMP/link-flush-ledger" ] && [ ! -L "$STATE/link-flush-ledger.txt" ] && victim_unchanged flush-ledger && echo 1 || echo 0 )"

# Symlinked parent: the state directory that holds every held directory is a
# link. Nothing is held, read, handed out, dropped or purged through it; the
# held directory already under the target is left as it was.
mv "$STATE" "$OUTSIDE/state-real"
ln -s "$OUTSIDE/state-real" "$STATE"
mkdir -p "$OUTSIDE/state-real/link-parent-old.held"
printf 'outside held text\n' > "$OUTSIDE/state-real/link-parent-old.held/out"
printf 'outside ledger copy\n' > "$OUTSIDE/state-real/link-parent-old.held/link-parent-old.txt"
cp -R "$OUTSIDE/state-real/link-parent-old.held" "$OUTSIDE/parent-old.orig"
link_rc=0
run_prompt link-parent 0 "$TMP/link-parent" || link_rc=$?
check 'symlinked state directory: nothing is held under the target' "$( [ ! -e "$OUTSIDE/state-real/link-parent.held" ] && ! session_ledgers_name link-parent held-prompt-fixture && ! cat "$OUTSIDE/state-real"/link-parent.* 2>/dev/null | grep -Fq "$HELD_TOKEN" && echo 1 || echo 0 )"
check 'symlinked state directory: the hook result is unchanged' "$( [ "$link_rc" -eq "$clean_rc" ] && refused_like_clean "$TMP/link-parent" && echo 1 || echo 0 )"
link_rc=0
run_prompt link-parent-old 0 "$TMP/link-parent-old" || link_rc=$?
check 'symlinked state directory: held text under the target is not appended to' "$( [ "$link_rc" -eq "$clean_rc" ] && refused_like_clean "$TMP/link-parent-old" && diff -r "$OUTSIDE/state-real/link-parent-old.held" "$OUTSIDE/parent-old.orig" >/dev/null 2>&1 && echo 1 || echo 0 )"
flush_held link-parent-old 0 "$TMP/link-parent-flush"
check 'symlinked state directory: handing out prints nothing and moves nothing' "$( [ ! -s "$TMP/link-parent-flush" ] && diff -r "$OUTSIDE/state-real/link-parent-old.held" "$OUTSIDE/parent-old.orig" >/dev/null 2>&1 && echo 1 || echo 0 )"
jq -cn '{session_id:"link-parent-old",hook_event_name:"SessionEnd"}' \
  | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" HQ_HARNESS=grok HQ_POLICY_DROP_HELD=1 bash "$HOOK" >/dev/null 2>&1
purge_ledgers link-parent-old
check 'symlinked state directory: session end and a purge leave the target in place' "$(diff -r "$OUTSIDE/state-real/link-parent-old.held" "$OUTSIDE/parent-old.orig" >/dev/null 2>&1 && echo 1 || echo 0)"
rm -rf "$OUTSIDE/state-real/link-parent-old.held"
rm -f "$STATE"
mv "$OUTSIDE/state-real" "$STATE"

# Symlinked ledger lock. The lock beside a ledger is a directory the hook
# makes; an old one is reclaimed as stale by removing its pid file. A lock name
# planted as an old symlink to an outside directory must not cost that
# directory its pid file. The stale check reads the link's own time, so the
# link is dated long ago.
plant_lock_target() { # <name>: an outside directory with a pid file
  mkdir -p "$OUTSIDE/$1"
  printf 'outside pid\n' > "$OUTSIDE/$1/pid"
}
plant_lock_target lock-held
run_prompt link-lock 0 "$TMP/link-lock-0"
ln -s "$OUTSIDE/lock-held" "$STATE/link-lock.held/link-lock.txt.lock"
touch -h -t 200001010000 "$STATE/link-lock.held/link-lock.txt.lock"
link_rc=0
run_prompt link-lock 0 "$TMP/link-lock" || link_rc=$?
check 'symlinked lock in the held store: the outside pid file stays' "$( [ -f "$OUTSIDE/lock-held/pid" ] && echo 1 || echo 0 )"
check 'symlinked lock in the held store: the hook result is unchanged' "$( [ "$link_rc" -eq "$clean_rc" ] && refused_like_clean "$TMP/link-lock" && echo 1 || echo 0 )"
plant_lock_target lock-own
ln -s "$OUTSIDE/lock-own" "$STATE/lock-own.txt.lock"
touch -h -t 200001010000 "$STATE/lock-own.txt.lock"
link_rc=0
run_prompt lock-own unset "$TMP/lock-own" || link_rc=$?
check 'symlinked lock beside a session ledger: the outside pid file stays' "$( [ -f "$OUTSIDE/lock-own/pid" ] && [ -L "$STATE/lock-own.txt.lock" ] && echo 1 || echo 0 )"
check 'symlinked lock beside a session ledger: the reminder is still printed' "$( [ "$link_rc" -eq 0 ] && grep -Fq "$HELD_TOKEN" "$TMP/lock-own" && echo 1 || echo 0 )"
rm -f "$STATE/lock-own.txt.lock"

# A link planted in advance at the old fixed hand-out claim name
# (<sid>.held.flush.<pid>). The hand-out must hand out the real held text and
# leave the link's target untouched.
run_prompt claim-plant 0 "$TMP/claim-plant-0"
mkdir -p "$OUTSIDE/claim-dir"
printf 'outside claim out\n' > "$OUTSIDE/claim-dir/out"
printf 'outside claim ledger\n' > "$OUTSIDE/claim-dir/claim-plant.txt"
cp -R "$OUTSIDE/claim-dir" "$OUTSIDE/claim-dir.orig"
jq -cn '{session_id:"claim-plant",hook_event_name:"PostToolUse",tool_name:"Read",cwd:"/tmp",tool_input:{file_path:"/tmp/x"}}' \
  | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" HQ_HARNESS=grok HQ_POLICY_FLUSH_HELD=1 HQ_POLICY_FLUSH_HELD_MAX_BYTES=0 \
    PLANT_STATE="$STATE" PLANT_TARGET="$OUTSIDE/claim-dir" PLANT_HOOK="$HOOK" \
    bash -c 'ln -s "$PLANT_TARGET" "$PLANT_STATE/claim-plant.held.flush.$$"; exec bash "$PLANT_HOOK"' \
    > "$TMP/claim-plant" 2>"$TMP/claim-plant.stderr" || true
check 'planted claim link: the hand-out prints the real held text' "$(grep -Fq "$HELD_TOKEN" "$TMP/claim-plant" && ! grep -Fq 'outside claim' "$TMP/claim-plant" && echo 1 || echo 0)"
check 'planted claim link: the link target is unchanged' "$(diff -r "$OUTSIDE/claim-dir" "$OUTSIDE/claim-dir.orig" >/dev/null 2>&1 && echo 1 || echo 0)"
check 'planted claim link: no outside file became a session ledger' "$( ! grep -Fq 'outside claim' "$STATE/claim-plant.txt" 2>/dev/null && echo 1 || echo 0)"
rm -f "$STATE"/claim-plant.held.flush.*

# A link planted in advance at the old fixed stale-lock name
# (<ledger>.lock.stale.<pid>.0). Reclaiming a stale lock must not move it into
# the link's target or remove the target's pid file.
plant_lock_target stale-target
mkdir -p "$STATE/stale-plant.txt.lock"
printf '1\n' > "$STATE/stale-plant.txt.lock/pid"
touch -t 200001010000 "$STATE/stale-plant.txt.lock"
jq -cn '{session_id:"stale-plant",hook_event_name:"UserPromptSubmit",cwd:"/tmp",prompt:"Please look at heldfixtureword now."}' \
  | env -u HQ_POLICY_REMINDER_DELIVERABLE PATH="$TMP/bin:$PATH" HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" HQ_HARNESS=grok \
    PLANT_STATE="$STATE" PLANT_TARGET="$OUTSIDE/stale-target" PLANT_HOOK="$HOOK" \
    bash -c 'ln -s "$PLANT_TARGET" "$PLANT_STATE/stale-plant.txt.lock.stale.$$.0"; exec bash "$PLANT_HOOK"' \
    > "$TMP/stale-plant" 2>"$TMP/stale-plant.stderr" || true
check 'planted stale-lock link: the target keeps its pid file' "$( [ -f "$OUTSIDE/stale-target/pid" ] && echo 1 || echo 0 )"
check 'planted stale-lock link: the stale lock is not moved into the target' "$( [ ! -e "$OUTSIDE/stale-target/stale-plant.txt.lock" ] && echo 1 || echo 0 )"
check 'planted stale-lock link: the stale lock is reclaimed and the slug recorded' "$( [ ! -e "$STATE/stale-plant.txt.lock" ] && grep -Fq held-prompt-fixture "$STATE/stale-plant.txt" 2>/dev/null && echo 1 || echo 0 )"
rm -f "$STATE"/stale-plant.txt.lock.stale.*

# A held file that vanishes between the checks and the link-count stat, under
# GNU stat. GNU stat -f is file-system mode, so it is no fallback: the vanished
# file is skipped and the real held text is still handed out.
mkdir -p "$TMP/gnustat"
cat > "$TMP/gnustat/stat" <<'EOF'
#!/usr/bin/env bash
# GNU stat stand-in: -c %h / %Y per file, -f prints the file-system name limit.
# The file named in FAKE_STAT_VANISH is removed on the first multi-file -c call.
if [ "$1" = -f ]; then shift 2; for f in "$@"; do echo 255; done; exit 0; fi
[ "$1" = -c ] || exit 1
fmt="$2"; shift 2; rc=0
if [ "$#" -gt 1 ] && [ -n "${FAKE_STAT_VANISH:-}" ] && [ -e "$FAKE_STAT_VANISH" ]; then rm -f "$FAKE_STAT_VANISH"; fi
for f in "$@"; do
  if [ ! -e "$f" ]; then echo "stat: cannot statx '$f': No such file or directory" >&2; rc=1; continue; fi
  case "$fmt" in %h) echo 1 ;; %Y) date -r "$f" +%s ;; *) exit 1 ;; esac
done
exit "$rc"
EOF
chmod +x "$TMP/gnustat/stat"
run_prompt vanish 0 "$TMP/vanish-0"
check 'vanished held file: the fixture held text and a ledger copy' "$(grep -Fq "$HELD_TOKEN" "$STATE/vanish.held/out" 2>/dev/null && [ -f "$STATE/vanish.held/vanish.txt" ] && echo 1 || echo 0)"
jq -cn '{session_id:"vanish",hook_event_name:"PostToolUse",tool_name:"Read",cwd:"/tmp",tool_input:{file_path:"/tmp/x"}}' \
  | PATH="$TMP/gnustat:$PATH" FAKE_STAT_VANISH="$STATE/vanish.held/vanish.txt" HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
    HQ_HARNESS=grok HQ_POLICY_FLUSH_HELD=1 HQ_POLICY_FLUSH_HELD_MAX_BYTES=0 bash "$HOOK" > "$TMP/vanish" 2>"$TMP/vanish.stderr" || true
check 'vanished held file under GNU stat: the held text is handed out, not refused' "$(grep -Fq "$HELD_TOKEN" "$TMP/vanish" && ! grep -q 'refused' "$TMP/vanish.stderr" && echo 1 || echo 0)"
rm -f "$TMP/core/policies/held-prompt-fixture.md"

# Through the Grok adapter. Grok hands hook context to the model on PostToolUse
# and discards what a SessionStart or UserPromptSubmit hook prints, so the
# adapter holds a prompt-time reminder, unrecorded, and returns it with the
# next tool result. The fixture is a minimal HQ root: the adapter, the policy
# hook, one registry entry per event and two policies. Its fact helpers are
# stand-ins, so the checks do not depend on an installed hq CLI.
PR="$TMP/grok-root"
mkdir -p "$PR/.claude/hooks" "$PR/.grok/hooks" "$PR/core/scripts" "$PR/core/policies"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$PR/.claude/hooks/"
cp "$HOOK" "$PR/.claude/hooks/inject-policy-on-trigger.sh"
cp "$ROOT/core/scripts/hook-lib.sh" "$PR/core/scripts/"
cp -R "$ROOT/core/scripts/lib" "$PR/core/scripts/lib"
cp "$ROOT/.grok/hooks/hq-grok-hook-adapter.sh" "$PR/.grok/hooks/"
cp "$FAIL_ROOT/core/scripts/eval-trigger.sh" "$PR/core/scripts/eval-trigger.sh"
cat > "$PR/core/scripts/derive-trigger-facts.sh" <<'EOF'
#!/usr/bin/env bash
# Stand-in fact helper: the words of the prompt or the shell command.
payload="$(cat)"
with_intent=0
for arg in "$@"; do
  case "$arg" in
    AssistantIntent) exit 0 ;;
    --with-assistant-intent) with_intent=1 ;;
  esac
done
facts="$(printf '%s' "$payload" | jq -r '[.prompt?, .tool_input.command?] | map(select(type == "string")) | join(" ") | ascii_downcase | gsub("[^a-z0-9]+"; " ")' 2>/dev/null || true)"
if [ "$with_intent" -eq 1 ]; then printf '%s\n\n' "$facts"; else printf '%s\n' "$facts"; fi
EOF
chmod +x "$PR/core/scripts/derive-trigger-facts.sh"
printf '{"hooks":{}}\n' > "$PR/.claude/settings.json"
# The profile gate only runs known ids, so the fixture guard borrows one.
cat > "$PR/.claude/hooks/hook-registry.json" <<'JSON'
{"hooks":{
  "SessionStart":[{"matcher":"","hooks":[{"id":"inject-policy-on-trigger","script":".claude/hooks/inject-policy-on-trigger.sh","gated":true}]}],
  "UserPromptSubmit":[{"matcher":"","hooks":[{"id":"inject-policy-on-trigger","script":".claude/hooks/inject-policy-on-trigger.sh","gated":true}]}],
  "PreToolUse":[{"matcher":"Bash","hooks":[{"id":"detect-secrets","script":".claude/hooks/fixture-guard.sh","gated":true}]}],
  "PostToolUse":[{"matcher":"Bash","hooks":[{"id":"inject-policy-on-trigger","script":".claude/hooks/inject-policy-on-trigger.sh","gated":true}]}]
}}
JSON
cat > "$PR/.claude/hooks/fixture-guard.sh" <<'SH'
#!/bin/bash
payload="$(cat)"
case "$payload" in
  *fixture-blocked-command*) echo 'FIXTURE GUARD: this command is not allowed.' >&2; exit 2 ;;
esac
exit 0
SH
PROMPT_TOKEN='prompt fixture marker alpha'
TOOL_TOKEN='tool fixture marker beta'
cat > "$PR/core/policies/grok-prompt-fixture.md" <<EOF
---
when: grokpromptword
on: [UserPromptSubmit]
enforcement: hard
---
## Rule
Prompt fixture. Carries the $PROMPT_TOKEN.
EOF
cat > "$PR/core/policies/grok-tool-fixture.md" <<EOF
---
when: groktoolword
on: [PostToolUse]
enforcement: hard
---
## Rule
Tool fixture. Carries the $TOOL_TOKEN.
EOF
PSID="grok-policy-$$"
PSTATE="$PR/workspace/orchestrator/policy-trigger-state"
ADAPTER_OUT=""
ADAPTER_ST=0
policy_adapter() { # <payload> [env assignment...]
  local payload="$1"
  shift
  ADAPTER_ST=0
  printf '%s' "$payload" | env -u HQ_ROOT -u CLAUDE_PROJECT_DIR -u HQ_HARNESS -u HQ_POLICY_REMINDER_DELIVERABLE \
    -u HQ_GROK_ADAPTER_TRACE HQ_POLICY_FACT_HELPER_DISABLE=1 HQ_GROK_POLICY_DEBOUNCE_SECS=0 \
    HQ_WORK_MESH_DISABLED=1 ${@+"$@"} bash "$PR/.grok/hooks/hq-grok-hook-adapter.sh" >"$TMP/adapter.out" 2>"$TMP/adapter.err" \
    || ADAPTER_ST=$?
  ADAPTER_OUT="$(cat "$TMP/adapter.out")"
}
pcheck() { # <label> <0 when it holds>
  check "$1" "$( [ "$2" -eq 0 ] && echo 1 || echo 0 )"
}
grok_ledgers_name() { # <session> <slug>: 0 when one of the session's own ledger files names it
  local f
  for f in "$PSTATE/$1".*; do
    [ -f "$f" ] || continue
    grep -Fq "$2" "$f" && return 0
  done
  return 1
}
context_has() { # <token>: 0 when the adapter's additionalContext carries it
  printf '%s' "$ADAPTER_OUT" | jq -e --arg t "$1" \
    '(.hookSpecificOutput.additionalContext // "") | contains($t)' >/dev/null 2>&1
}
grok_event() { # <event> <extra-json> [session]
  jq -cn --arg e "$1" --arg sid "${3-$PSID}" --arg cwd "$PR" --argjson x "$2" \
    '{hookEventName:$e, cwd:$cwd} + (if $sid == "" then {} else {sessionId:$sid} end) + $x'
}
READ_RESULT='{"toolName":"read_file","toolInput":{"file_path":"core/policies/grok-tool-fixture.md"},"toolResult":{"content":"x"}}'

policy_adapter "$(grok_event UserPromptSubmit '{"prompt":"Please check grokpromptword today."}')"
pcheck 'adapter: a prompt-time reminder is not printed to Grok' \
  "$([ "$ADAPTER_ST" -eq 0 ] && [ -z "$ADAPTER_OUT" ] && echo 0 || echo 1)"
pcheck 'adapter: a prompt-time policy is not recorded as shown before delivery' \
  "$(grok_ledgers_name "$PSID" grok-prompt-fixture && echo 1 || echo 0)"
pcheck 'adapter: the prompt-time reminder is held' \
  "$(grep -Fq "$PROMPT_TOKEN" "$PSTATE/$PSID.held/out" 2>/dev/null && echo 0 || echo 1)"

policy_adapter "$(grok_event PreToolUse '{"toolName":"run_terminal_command","toolInput":{"command":"echo fixture-blocked-command"}}')"
pcheck 'adapter: a deny still denies while a reminder is held' \
  "$([ "$ADAPTER_ST" -eq 2 ] && printf '%s' "$ADAPTER_OUT" | jq -e '.decision == "deny" and (.reason | contains("FIXTURE GUARD"))' >/dev/null 2>&1 && echo 0 || echo 1)"
pcheck 'adapter: a denied call leaves the reminder held and unrecorded' \
  "$(grep -Fq "$PROMPT_TOKEN" "$PSTATE/$PSID.held/out" 2>/dev/null && ! grok_ledgers_name "$PSID" grok-prompt-fixture && echo 0 || echo 1)"

policy_adapter "$(grok_event PreToolUse '{"toolName":"run_terminal_command","toolInput":{"command":"echo ok"}}')"
pcheck 'adapter: an allowed PreToolUse does not release the held reminder' \
  "$([ "$ADAPTER_ST" -eq 0 ] && [ "$ADAPTER_OUT" = '{"decision":"allow"}' ] && grep -Fq "$PROMPT_TOKEN" "$PSTATE/$PSID.held/out" 2>/dev/null && echo 0 || echo 1)"

policy_adapter "$(grok_event PostToolUse "$READ_RESULT")" HQ_GROK_CONTEXT_BUDGET=40
pcheck 'adapter: a held reminder that does not fit beside the tool result stays held' \
  "$([ "$ADAPTER_ST" -eq 0 ] && [ -z "$ADAPTER_OUT" ] && grep -Fq "$PROMPT_TOKEN" "$PSTATE/$PSID.held/out" 2>/dev/null && ! grok_ledgers_name "$PSID" grok-prompt-fixture && echo 0 || echo 1)"

policy_adapter "$(grok_event PostToolUse "$READ_RESULT")"
pcheck 'adapter: the next tool result of any tool returns the held reminder as additionalContext' \
  "$([ "$ADAPTER_ST" -eq 0 ] && printf '%s' "$ADAPTER_OUT" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null 2>&1 && context_has "$PROMPT_TOKEN" && echo 0 || echo 1)"
pcheck 'adapter: the prompt-time policy is recorded once it was returned' \
  "$(grep -Fxq 'grok-prompt-fixture' "$PSTATE/$PSID.txt" 2>/dev/null && [ ! -e "$PSTATE/$PSID.held" ] && echo 0 || echo 1)"

policy_adapter "$(grok_event PostToolUse '{"toolName":"run_terminal_command","toolInput":{"command":"echo groktoolword"},"toolResult":{"stdout":"groktoolword","exit_code":0}}')"
pcheck 'adapter: a tool-triggered policy is returned on Grok PostToolUse' \
  "$([ "$ADAPTER_ST" -eq 0 ] && context_has "$TOOL_TOKEN" && echo 0 || echo 1)"
pcheck 'adapter: a returned reminder is not returned twice' \
  "$(context_has "$PROMPT_TOKEN" && echo 1 || echo 0)"
pcheck 'adapter: the tool-triggered policy is recorded with its delivery' \
  "$(grep -Fxq 'grok-tool-fixture' "$PSTATE/$PSID.txt" 2>/dev/null && echo 0 || echo 1)"

policy_adapter "$(grok_event UserPromptSubmit '{"prompt":"Again, check grokpromptword."}')"
policy_adapter "$(grok_event PostToolUse "$READ_RESULT")"
pcheck 'adapter: a delivered policy is not shown in full on a later prompt' \
  "$(context_has "$PROMPT_TOKEN" && echo 1 || echo 0)"

# Session end: held text that met no tool result is removed, unrecorded.
ESID="grok-end-$$"
policy_adapter "$(grok_event UserPromptSubmit '{"prompt":"Please check grokpromptword today."}' "$ESID")"
pcheck 'adapter: text is held before the session ends' \
  "$(grep -Fq "$PROMPT_TOKEN" "$PSTATE/$ESID.held/out" 2>/dev/null && echo 0 || echo 1)"
policy_adapter "$(grok_event SessionEnd '{}' "$ESID")"
pcheck 'adapter: SessionEnd removes held text' \
  "$([ ! -e "$PSTATE/$ESID.held" ] && echo 0 || echo 1)"
pcheck 'adapter: SessionEnd does not record held text as shown' \
  "$(grok_ledgers_name "$ESID" grok-prompt-fixture && echo 1 || echo 0)"

# No session id from Grok: the adapter keys state on its parent pid, which a
# later session can reuse. Nothing is held under that key.
policy_adapter "$(grok_event UserPromptSubmit '{"prompt":"Please check grokpromptword today."}' '')"
pcheck 'adapter: without a session id nothing is held or recorded' \
  "$([ "$ADAPTER_ST" -eq 0 ] && [ -z "$ADAPTER_OUT" ] && ! grep -Frq "$PROMPT_TOKEN" "$PSTATE" 2>/dev/null && ! grep -Frq 'grok-prompt-fixture' "$PSTATE" --include='grok-[0-9]*' 2>/dev/null && echo 0 || echo 1)"
policy_adapter "$(grok_event PostToolUse "$READ_RESULT" '')"
pcheck 'adapter: without a session id a later tool result carries no earlier prompt reminder' \
  "$(context_has "$PROMPT_TOKEN" && echo 1 || echo 0)"

# Links through the adapter. A link planted in the held store changes neither
# the adapter's allow nor its deny, the outside file is unchanged, and a tool
# result carries nothing read from it.
LSID="grok-link-$$"
printf 'outside adapter content\n' > "$OUTSIDE/adapter"
cp "$OUTSIDE/adapter" "$OUTSIDE/adapter.orig"
mkdir -p "$PSTATE/$LSID.held"
ln -s "$OUTSIDE/adapter" "$PSTATE/$LSID.held/out"
policy_adapter "$(grok_event UserPromptSubmit '{"prompt":"Please check grokpromptword today."}' "$LSID")"
pcheck 'adapter: a symlinked held file leaves the prompt result unchanged' \
  "$([ "$ADAPTER_ST" -eq 0 ] && [ -z "$ADAPTER_OUT" ] && echo 0 || echo 1)"
pcheck 'adapter: a symlinked held file leaves the outside file unchanged' \
  "$(cmp -s "$OUTSIDE/adapter" "$OUTSIDE/adapter.orig" && ! grok_ledgers_name "$LSID" grok-prompt-fixture && echo 0 || echo 1)"
rm -rf "$PSTATE/$LSID.held"
mkdir -p "$PSTATE/$LSID.held"
ln "$OUTSIDE/adapter" "$PSTATE/$LSID.held/out"
policy_adapter "$(grok_event PreToolUse '{"toolName":"run_terminal_command","toolInput":{"command":"echo fixture-blocked-command"}}' "$LSID")"
pcheck 'adapter: a deny still denies with a hardlinked held file' \
  "$([ "$ADAPTER_ST" -eq 2 ] && printf '%s' "$ADAPTER_OUT" | jq -e '.decision == "deny" and (.reason | contains("FIXTURE GUARD"))' >/dev/null 2>&1 && echo 0 || echo 1)"
policy_adapter "$(grok_event PreToolUse '{"toolName":"run_terminal_command","toolInput":{"command":"echo ok"}}' "$LSID")"
pcheck 'adapter: an allow still allows with a hardlinked held file' \
  "$([ "$ADAPTER_ST" -eq 0 ] && [ "$ADAPTER_OUT" = '{"decision":"allow"}' ] && echo 0 || echo 1)"
policy_adapter "$(grok_event PostToolUse "$READ_RESULT" "$LSID")"
pcheck 'adapter: a tool result carries nothing from a hardlinked held file' \
  "$([ "$ADAPTER_ST" -eq 0 ] && ! context_has 'outside adapter content' && cmp -s "$OUTSIDE/adapter" "$OUTSIDE/adapter.orig" && echo 0 || echo 1)"
rm -rf "$PSTATE/$LSID.held"
mkdir -p "$OUTSIDE/adapter-dir"
printf 'outside adapter out\n' > "$OUTSIDE/adapter-dir/out"
cp -R "$OUTSIDE/adapter-dir" "$OUTSIDE/adapter-dir.orig"
ln -s "$OUTSIDE/adapter-dir" "$PSTATE/$LSID.held"
policy_adapter "$(grok_event UserPromptSubmit '{"prompt":"Please check grokpromptword today."}' "$LSID")"
pcheck 'adapter: a symlinked held directory leaves the prompt result and the outside directory unchanged' \
  "$([ "$ADAPTER_ST" -eq 0 ] && [ -z "$ADAPTER_OUT" ] && diff -r "$OUTSIDE/adapter-dir" "$OUTSIDE/adapter-dir.orig" >/dev/null 2>&1 && echo 0 || echo 1)"
rm -rf "$PSTATE/$LSID.held"
ln -s "$OUTSIDE/adapter-dir" "$PSTATE/$LSID.held"
policy_adapter "$(grok_event PostToolUse "$READ_RESULT" "$LSID")"
pcheck 'adapter: a tool result carries nothing from a symlinked held directory' \
  "$([ "$ADAPTER_ST" -eq 0 ] && ! context_has 'outside adapter out' && diff -r "$OUTSIDE/adapter-dir" "$OUTSIDE/adapter-dir.orig" >/dev/null 2>&1 && echo 0 || echo 1)"

helper_output_is_deliverable() {
  local file="$1"
  [ ! -s "$file" ] || jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | type == "string")' "$file" >/dev/null 2>&1
}
HELPER_PAYLOAD="$(jq -cn '{session_id:"hp17-helper",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"git commit -m hp17"},tool_response:{exit_code:0}}')"
printf '%s' "$HELPER_PAYLOAD" | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/.claude/hooks/auto-checkpoint-trigger.sh" > "$TMP/auto-helper"
check 'auto-checkpoint PostToolUse output is enveloped or empty' "$(helper_output_is_deliverable "$TMP/auto-helper" && echo 1 || echo 0)"
printf '%s' "$HELPER_PAYLOAD" | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/.claude/hooks/journal-due.sh" > "$TMP/journal-helper"
check 'journal-due PostToolUse output is enveloped or empty' "$(helper_output_is_deliverable "$TMP/journal-helper" && echo 1 || echo 0)"
printf '%s' '{"session_id":"hp17-helper","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"sst deploy"}}' \
  | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/.claude/hooks/surface-company-infra-policy.sh" > "$TMP/surface-helper"
check 'surface-company-infra PreToolUse output is empty' "$( [ ! -s "$TMP/surface-helper" ] && echo 1 || echo 0 )"

check 'registry binds surface helper to PreToolUse' "$(jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.id == "surface-company-infra-policy")] | length == 1' "$ROOT/.claude/hooks/hook-registry.json" >/dev/null && echo 1 || echo 0)"
check 'registry binds journal and checkpoint helpers to PostToolUse' "$(jq -e '[.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.id == "journal-due" or .id == "auto-checkpoint-trigger")] | length == 2' "$ROOT/.claude/hooks/hook-registry.json" >/dev/null && echo 1 || echo 0)"

printf '\n==== inject-policy-tool-events: %s failures ====\n' "$failures"
[ "$failures" -eq 0 ]
