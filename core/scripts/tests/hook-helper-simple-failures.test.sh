#!/usr/bin/env bash
set -euo pipefail

# Targeted 127 and absent-helper behavior for simple registered hook callers.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/out"; ERR="$TMP/err"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf '  ok: %s\n' "$*"; }

make_root() {
  local name="$1" root
  root="$TMP/$name"
  mkdir -p "$root/.claude/hooks" "$root/.claude/state" "$root/core/scripts" \
    "$root/core/scripts/lib"
  printf '%s' "$root"
}

make_forwarder_stub() {
  local helper_path="$1" helper_name="$2" call_log="$3"
  mkdir -p "$(dirname "$helper_path")"
  cat > "$helper_path" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '$helper_name: this script needs hq-cli >= 5.78.0 (found 5.77.0); upgrade with: npm install -g @indigoai-us/hq-cli@latest' >&2
printf 'called\\n' >> '$call_log'
exit 127
EOF
  chmod +x "$helper_path"
}

run_hook() {
  local root="$1" hook="$2" payload="${3:-}" rc
  if printf '%s' "$payload" | env -u HQ_ROOT -u HQ_POLICY_WORKER_DIR CLAUDE_PROJECT_DIR="$root" \
    bash "$hook" >"$OUT" 2>"$ERR"; then
    rc=0
  else
    rc=$?
  fi
  printf '%s' "$rc"
}

assert_empty_result() {
  local label="$1" rc="$2"
  [ "$rc" = 0 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ] \
    || fail "$label expected exit 0 with empty stdout/stderr (rc=$rc stdout=$(cat "$OUT") stderr=$(cat "$ERR"))"
}

JOURNAL_BANNER="$TMP/journal-banner.expected"
cat > "$JOURNAL_BANNER" <<'EOF'
╔══════════════════════════════════════════════════════════════╗
║  Autocompact about to run — JOURNAL ENTRY RECOMMENDED        ║
╠══════════════════════════════════════════════════════════════╣
║  Raw tool-results in the prefix will be lossy-compressed.    ║
║  Write a journal entry NOW capturing:                        ║
║    • Goal of the current slice of work                       ║
║    • Findings worth recovering (non-obvious things learned)  ║
║    • Decisions made (with rejected alternatives if useful)   ║
║    • What the next slice will pick up                        ║
║                                                              ║
║    /journal "<title>"                                        ║
║                                                              ║
║  Post-compact, raw tool-results are gone — the journal entry ║
║  is what survives. Read it back via /journal --read <NNN>.   ║
╚══════════════════════════════════════════════════════════════╝
EOF

# journal-precompact: helper exit 127 and helper absence both retain the exact
# static reminder; only a present stub is invoked.
ROOT_PRE="$(make_root journal-precompact)"
cp "$ROOT/.claude/hooks/journal-precompact.sh" "$ROOT_PRE/.claude/hooks/"
PRE_HELPER="$ROOT_PRE/core/scripts/session-journal.sh"
PRE_LOG="$TMP/journal-precompact.calls"
make_forwarder_stub "$PRE_HELPER" session-journal.sh "$PRE_LOG"
rc="$(run_hook "$ROOT_PRE" "$ROOT_PRE/.claude/hooks/journal-precompact.sh")"
[ "$rc" = 0 ] && cmp -s "$OUT" "$JOURNAL_BANNER" && [ ! -s "$ERR" ] \
  && [ "$(cat "$PRE_LOG")" = called ] || fail "journal-precompact with 127 stub changed its banner or status"
pass "journal-precompact preserves exact stdout and suppresses a 127 helper"
rm -f "$PRE_HELPER"
rc="$(run_hook "$ROOT_PRE" "$ROOT_PRE/.claude/hooks/journal-precompact.sh")"
[ "$rc" = 0 ] && cmp -s "$OUT" "$JOURNAL_BANNER" && [ ! -s "$ERR" ] \
  || fail "journal-precompact with absent helper changed its banner or status"
pass "journal-precompact preserves exact stdout when the helper is absent"

# journal-due: a non-milestone Read reaches dir-path, then stays silent whether
# the helper returns 127 or is absent.
ROOT_DUE="$(make_root journal-due)"
cp "$ROOT/.claude/hooks/journal-due.sh" "$ROOT_DUE/.claude/hooks/"
cp "$ROOT/core/scripts/hook-lib.sh" "$ROOT_DUE/core/scripts/"
DUE_HELPER="$ROOT_DUE/core/scripts/session-journal.sh"
DUE_LOG="$TMP/journal-due.calls"
make_forwarder_stub "$DUE_HELPER" session-journal.sh "$DUE_LOG"
PAYLOAD='{"tool_name":"Read","session_id":"contract-session","tool_response":{"exit_code":0}}'
rc="$(run_hook "$ROOT_DUE" "$ROOT_DUE/.claude/hooks/journal-due.sh" "$PAYLOAD")"
assert_empty_result "journal-due with 127" "$rc"
[ "$(cat "$DUE_LOG")" = called ] || fail "journal-due did not call the 127 helper"
pass "journal-due ignores 127 and remains silent"
rm -f "$DUE_HELPER"
rc="$(run_hook "$ROOT_DUE" "$ROOT_DUE/.claude/hooks/journal-due.sh" "$PAYLOAD")"
assert_empty_result "journal-due absent helper" "$rc"
pass "journal-due remains silent when the helper is absent"

# native-plan-project-sync: its pointer and ExitPlanMode payload reach the
# helper; helper output and status are discarded. Missing/non-executable exits
# before the attempt and is equally silent.
ROOT_PLAN="$(make_root native-plan-project-sync)"
cp "$ROOT/.claude/hooks/native-plan-project-sync.sh" "$ROOT_PLAN/.claude/hooks/"
cp "$ROOT/core/scripts/hook-lib.sh" "$ROOT_PLAN/core/scripts/"
printf 'projects/demo\n' > "$ROOT_PLAN/.claude/state/active-session-project"
PLAN_HELPER="$ROOT_PLAN/core/scripts/session-project.sh"
PLAN_LOG="$TMP/native-plan.calls"
make_forwarder_stub "$PLAN_HELPER" session-project.sh "$PLAN_LOG"
PAYLOAD='{"tool_name":"ExitPlanMode","tool_input":{"plan":"Synthetic plan"}}'
rc="$(run_hook "$ROOT_PLAN" "$ROOT_PLAN/.claude/hooks/native-plan-project-sync.sh" "$PAYLOAD")"
assert_empty_result "native-plan-project-sync with 127" "$rc"
[ "$(cat "$PLAN_LOG")" = called ] || fail "native-plan-project-sync did not invoke its helper"
pass "native-plan-project-sync ignores 127 and discards helper output"
rm -f "$PLAN_HELPER"
rc="$(run_hook "$ROOT_PLAN" "$ROOT_PLAN/.claude/hooks/native-plan-project-sync.sh" "$PAYLOAD")"
assert_empty_result "native-plan-project-sync absent helper" "$rc"
pass "native-plan-project-sync is silent when its helper is absent"

# repair-stale-review-base: the detector's first failed --check is hidden and
# translated to a clean SessionStart exit; absence takes the early clean path.
ROOT_REPAIR="$(make_root repair-stale-review-base)"
cp "$ROOT/.claude/hooks/repair-stale-review-base.sh" "$ROOT_REPAIR/.claude/hooks/"
REPAIR_HELPER="$ROOT_REPAIR/core/scripts/detect-stale-review-base.sh"
REPAIR_LOG="$TMP/repair-stale.calls"
make_forwarder_stub "$REPAIR_HELPER" detect-stale-review-base.sh "$REPAIR_LOG"
rc="$(run_hook "$ROOT_REPAIR" "$ROOT_REPAIR/.claude/hooks/repair-stale-review-base.sh")"
assert_empty_result "repair-stale-review-base with 127" "$rc"
[ "$(cat "$REPAIR_LOG")" = called ] || fail "repair-stale-review-base did not call --check"
pass "repair-stale-review-base suppresses 127 and exits cleanly"
rm -f "$REPAIR_HELPER"
rc="$(run_hook "$ROOT_REPAIR" "$ROOT_REPAIR/.claude/hooks/repair-stale-review-base.sh")"
assert_empty_result "repair-stale-review-base absent helper" "$rc"
pass "repair-stale-review-base is silent when the detector is absent"

# inject-policy-on-trigger: derive-trigger-facts is launched through bash;
# exit 127 stderr passes through while its failed facts are ignored. Absence
# disables the helper block, with the same empty policy set and no output.
ROOT_INJECT="$(make_root inject-policy)"
cp "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" "$ROOT_INJECT/.claude/hooks/"
cp "$ROOT/core/scripts/hook-lib.sh" "$ROOT_INJECT/core/scripts/"
cp "$ROOT/core/scripts/eval-trigger.sh" "$ROOT_INJECT/core/scripts/"
INJECT_HELPER="$ROOT_INJECT/core/scripts/derive-trigger-facts.sh"
INJECT_LOG="$TMP/inject-derived.calls"
make_forwarder_stub "$INJECT_HELPER" derive-trigger-facts.sh "$INJECT_LOG"
PAYLOAD='{"hook_event_name":"PostToolUse","session_id":"contract-session","tool_name":"Bash","tool_input":{"command":"echo ok"},"tool_response":{"exit_code":0}}'
rc="$(run_hook "$ROOT_INJECT" "$ROOT_INJECT/.claude/hooks/inject-policy-on-trigger.sh" "$PAYLOAD")"
[ "$rc" = 0 ] && [ ! -s "$OUT" ] || fail "inject derive 127 changed status/stdout"
printf '%s\n' 'derive-trigger-facts.sh: this script needs hq-cli >= 5.78.0 (found 5.77.0); upgrade with: npm install -g @indigoai-us/hq-cli@latest' > "$TMP/inject.expected"
cmp -s "$TMP/inject.expected" "$ERR" || fail "inject derive 127 stderr differs: $(cat "$ERR")"
[ "$(cat "$INJECT_LOG")" = called ] || fail "inject hook did not run its derive helper"
rm -f "$INJECT_HELPER"
rc="$(run_hook "$ROOT_INJECT" "$ROOT_INJECT/.claude/hooks/inject-policy-on-trigger.sh" "$PAYLOAD")"
assert_empty_result "inject derive absent" "$rc"
pass "inject-policy-on-trigger ignores derive 127 and remains silent when absent"

# eval-trigger is only a file-presence gate here. A forwarder-shaped file is
# not executed; absence suppresses frontmatter evaluation. With no policies,
# both paths have identical byte output and exit status.
ROOT_EVAL="$(make_root inject-eval-guard)"
cp "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" "$ROOT_EVAL/.claude/hooks/"
cp "$ROOT/core/scripts/hook-lib.sh" "$ROOT_EVAL/core/scripts/"
cp "$ROOT/core/scripts/derive-trigger-facts.sh" "$ROOT_EVAL/core/scripts/"
cp "$ROOT/core/scripts/lib/transcript-tail.sh" "$ROOT_EVAL/core/scripts/lib/"
cp "$ROOT/core/scripts/lib/trigger-fact-text.awk" "$ROOT_EVAL/core/scripts/lib/"
EVAL_LOG="$TMP/inject-eval.calls"
make_forwarder_stub "$ROOT_EVAL/core/scripts/eval-trigger.sh" eval-trigger.sh "$EVAL_LOG"
PAYLOAD='{"hook_event_name":"PostToolUse","session_id":"contract-session","tool_name":"Bash","tool_input":{"command":"echo ok"},"tool_response":{"exit_code":0}}'
rc="$(run_hook "$ROOT_EVAL" "$ROOT_EVAL/.claude/hooks/inject-policy-on-trigger.sh" "$PAYLOAD")"
assert_empty_result "inject eval presence guard" "$rc"
[ ! -e "$EVAL_LOG" ] || fail "inject hook executed eval-trigger despite its inline parser"
rm -f "$ROOT_EVAL/core/scripts/eval-trigger.sh"
rc="$(run_hook "$ROOT_EVAL" "$ROOT_EVAL/.claude/hooks/inject-policy-on-trigger.sh" "$PAYLOAD")"
assert_empty_result "inject eval absent" "$rc"
pass "inject eval-trigger presence guard never executes the helper"

# session-title: the actual title helper is fail-soft behind 2>/dev/null; both
# a 127 forwarder and absence produce the empty hook response.
ROOT_TITLE="$(make_root session-title)"
cp "$ROOT/.claude/hooks/session-title.sh" "$ROOT_TITLE/.claude/hooks/"
cp "$ROOT/core/scripts/hook-lib.sh" "$ROOT_TITLE/core/scripts/"
TITLE_HELPER="$ROOT_TITLE/core/scripts/session-title.sh"
TITLE_LOG="$TMP/session-title.calls"
make_forwarder_stub "$TITLE_HELPER" session-title.sh "$TITLE_LOG"
PAYLOAD='{"hook_event_name":"SessionStart","session_id":"contract-title"}'
rc="$(run_hook "$ROOT_TITLE" "$ROOT_TITLE/.claude/hooks/session-title.sh" "$PAYLOAD")"
assert_empty_result "session-title 127" "$rc"
[ "$(cat "$TITLE_LOG")" = called ] || fail "session-title did not call 127 helper"
rm -f "$TITLE_HELPER"
rc="$(run_hook "$ROOT_TITLE" "$ROOT_TITLE/.claude/hooks/session-title.sh" "$PAYLOAD")"
assert_empty_result "session-title absent" "$rc"
pass "session-title suppresses helper stderr and keeps an empty response on 127/absence"

# session-title-config is only a file-presence gate. Its contents are read by
# the hook itself, and a forwarder-shaped executable is never launched. With
# mode=auto in the settings file, an absent config helper preserves full-mode
# first-turn nudge bytes; a present helper enables inline parsing and silences
# that nudge. The title helper returns no title in both cases.
make_title_config_root() {
  local root="$1" with_config="$2"
  mkdir -p "$root/.claude/hooks" "$root/.claude/state" "$root/core/scripts" "$root/core/settings"
  cp "$ROOT/.claude/hooks/session-title.sh" "$root/.claude/hooks/"
  cp "$ROOT/core/scripts/hook-lib.sh" "$root/core/scripts/"
  cat > "$root/core/scripts/session-title.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$root/core/scripts/session-title.sh"
  printf 'mode: auto\n' > "$root/core/settings/session-title.yaml"
  if [ "$with_config" = 1 ]; then
    cat > "$root/core/scripts/session-title-config.sh" <<EOF
#!/usr/bin/env bash
printf '%s\\n' 'session-title-config.sh: this script needs hq-cli >= 5.78.0 (found 5.77.0); upgrade with: npm install -g @indigoai-us/hq-cli@latest' >&2
printf 'called\\n' >> '$TMP/session-title-config.calls'
exit 127
EOF
    chmod +x "$root/core/scripts/session-title-config.sh"
  fi
}
ROOT_TITLE_NO_CONFIG="$TMP/title-config-absent"
ROOT_TITLE_CONFIG="$TMP/title-config-forwarder"
make_title_config_root "$ROOT_TITLE_NO_CONFIG" 0
make_title_config_root "$ROOT_TITLE_CONFIG" 1
TITLE_PROMPT='{"hook_event_name":"UserPromptSubmit","session_id":"contract-config","prompt":"hello"}'
for root in "$ROOT_TITLE_NO_CONFIG" "$ROOT_TITLE_CONFIG"; do
  if printf '%s' "$TITLE_PROMPT" | env -u HQ_ROOT CLAUDE_PROJECT_DIR="$root" \
    bash "$root/.claude/hooks/session-title.sh" >"$TMP/$(basename "$root").out" 2>"$TMP/$(basename "$root").err"; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" = 0 ] && [ ! -s "$TMP/$(basename "$root").err" ] \
    || fail "session-title-config guard changed status/stderr (rc=$rc)"
done
[ -s "$TMP/title-config-absent.out" ] || fail "absent config helper should retain first-turn nudge output"
[ ! -s "$TMP/title-config-forwarder.out" ] || fail "present config helper should enable inline mode=auto parsing"
[ ! -e "$TMP/session-title-config.calls" ] || fail "session-title hook executed session-title-config helper"
pass "session-title-config presence guard controls inline parsing without executing the file"

# Both Stop hooks query share-suggestion-state. A 127 response is swallowed
# and the hook continues to its ordinary output; an absent file skips the
# query. Compare complete stdout/stderr bytes and pin status in both cases.
for hook_name in 40-auto-acl-share-suggestion 50-after-turn-suggestions; do
  STOP_HOOK="$ROOT/core/hooks/Stop/$hook_name.sh"
  for state in forwarder absent; do
    STOP_ROOT="$(make_root "${hook_name}-${state}")"
    mkdir -p "$STOP_ROOT/core/hooks/Stop" "$STOP_ROOT/workspace"
    cp "$STOP_HOOK" "$STOP_ROOT/core/hooks/Stop/"
    STOP_HELPER="$STOP_ROOT/core/scripts/share-suggestion-state.sh"
    if [ "$state" = forwarder ]; then
      make_forwarder_stub "$STOP_HELPER" share-suggestion-state.sh "$TMP/${hook_name}.calls"
      chmod +x "$STOP_HELPER"
    fi
    STOP_PAYLOAD='{"session_id":"contract-stop","transcript_path":""}'
    if printf '%s' "$STOP_PAYLOAD" | env -u HQ_ROOT CLAUDE_PROJECT_DIR="$STOP_ROOT" HOME="$STOP_ROOT/home" \
      bash "$STOP_ROOT/core/hooks/Stop/$hook_name.sh" >"$TMP/${hook_name}.${state}.out" 2>"$TMP/${hook_name}.${state}.err"; then
      rc=0
    else
      rc=$?
    fi
    [ "$rc" = 0 ] || fail "$hook_name $state helper changed status (rc=$rc)"
    if [ "$hook_name" = "40-auto-acl-share-suggestion" ] && [ "$state" = forwarder ]; then
      printf '%s\n' 'share-suggestion-state.sh: this script needs hq-cli >= 5.78.0 (found 5.77.0); upgrade with: npm install -g @indigoai-us/hq-cli@latest' \
        > "$TMP/${hook_name}.err.expected"
      cmp -s "$TMP/${hook_name}.err.expected" "$TMP/${hook_name}.${state}.err" \
        || fail "$hook_name forwarder stderr differs: $(cat "$TMP/${hook_name}.${state}.err")"
      [ "$(cat "$TMP/${hook_name}.calls")" = called ] || fail "$hook_name did not call the forwarder"
    else
      [ ! -s "$TMP/${hook_name}.${state}.err" ] \
        || fail "$hook_name $state helper should have empty stderr: $(cat "$TMP/${hook_name}.${state}.err")"
    fi
  done
  cmp -s "$TMP/${hook_name}.forwarder.out" "$TMP/${hook_name}.absent.out" \
    || fail "$hook_name stdout differs for 127 and absent helper"
  pass "$hook_name keeps identical stdout and exit 0 for 127/absence"
done

echo "PASS: simple hook helper failure contracts"
