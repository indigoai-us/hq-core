#!/usr/bin/env bash
# Tests for core/hooks/UserPromptSubmit/40-skill-command-script.sh
#
# Contract under test:
#   - /<skill> runs that skill folder's command.sh
#   - output reaches the operator as systemMessage (display-only), never as
#     hookSpecificOutput.additionalContext (which would enter model context)
#   - the prompt is never blocked (exit 0, no decision:block)
#   - company-scoped scripts run only for the session's active company
#
# Fixture company directories are built from the $CO variable rather than a
# literal companies/<slug> path, so the cross-company PreToolUse guard does not
# read this file's fixtures as a real tenant access.

set -uo pipefail

HQ_SRC="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$HQ_SRC/core/hooks/UserPromptSubmit/40-skill-command-script.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok - $1"; }

assert_contains() {
  printf '%s' "$1" | grep -qF -- "$2" || fail "$3: missing '$2' in: $1"
  ok "$3"
}
assert_not_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then fail "$3: unexpected '$2' in: $1"; fi
  ok "$3"
}
assert_empty() {
  [ -z "$1" ] || fail "$2: expected no output, got: $1"
  ok "$2"
}

[ -x "$HOOK" ] || fail "hook is not executable: $HOOK"

# --- Fake HQ root -----------------------------------------------------------
CO="$TMP_ROOT/companies"
CORE_SKILLS="$TMP_ROOT/core/skills"
PERSONAL_SKILLS="$TMP_ROOT/personal/skills"
mkdir -p "$TMP_ROOT/core/scripts" "$CORE_SKILLS" "$PERSONAL_SKILLS" \
         "$CO" "$TMP_ROOT/.claude/skills" "$TMP_ROOT/workspace/sessions"
cp "$HQ_SRC/core/scripts/hook-lib.sh" "$TMP_ROOT/core/scripts/hook-lib.sh"

make_skill() { # <dir> <body>
  mkdir -p "$1"
  printf '%s\n' "$2" > "$1/command.sh"
  chmod +x "$1/command.sh"
}

bind_company() { # <session-id> <slug>
  mkdir -p "$TMP_ROOT/workspace/sessions/$1"
  printf 'session_id: %s\ncompany_slug: %s\n' "$1" "$2" > "$TMP_ROOT/workspace/sessions/$1/meta.yaml"
}

payload() { # <prompt> [session-id]
  jq -nc --arg p "$1" --arg s "${2:-s-test}" \
    '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:$p}'
}

run_hook() { # <payload> [env assignments...]
  local pl="$1"; shift
  printf '%s' "$pl" | HQ_ROOT="$TMP_ROOT" env "$@" bash "$HOOK"
}

# --- 1. core skill runs, output lands in systemMessage ----------------------
make_skill "$CORE_SKILLS/pulse" 'echo "pulse-ran"'
out="$(run_hook "$(payload '/pulse')")"
rc=$?
[ "$rc" -eq 0 ] || fail "core skill: expected exit 0, got $rc"
assert_contains "$out" '"systemMessage"' "core skill emits systemMessage"
assert_contains "$out" 'pulse-ran' "core skill output is carried"
assert_not_contains "$out" 'additionalContext' "output never enters model context"
assert_not_contains "$out" 'decision' "prompt is never blocked"

# --- 2. plain prompt is a no-op --------------------------------------------
assert_empty "$(run_hook "$(payload 'just a normal question')")" "non-slash prompt is a no-op"

# --- 3. slash command with no command.sh -----------------------------------
mkdir -p "$CORE_SKILLS/bare"
printf '%s\n' '# nothing' > "$CORE_SKILLS/bare/SKILL.md"
assert_empty "$(run_hook "$(payload '/bare')")" "skill without command.sh is a no-op"

# --- 4. unknown command -----------------------------------------------------
assert_empty "$(run_hook "$(payload '/nope-not-a-skill')")" "unknown command is a no-op"

# --- 5. personal wins over core --------------------------------------------
make_skill "$CORE_SKILLS/dup" 'echo "from-core"'
make_skill "$PERSONAL_SKILLS/dup" 'echo "from-personal"'
out="$(run_hook "$(payload '/dup')")"
assert_contains "$out" 'from-personal' "personal overrides core"
assert_not_contains "$out" 'from-core' "core is not also run"

# --- 6. company skill runs for the active company --------------------------
bind_company "s-acme" "acme"
make_skill "$CO/acme/skills/report" 'echo "acme-report"'
out="$(run_hook "$(payload '/report' 's-acme')")"
assert_contains "$out" 'acme-report' "active company skill runs"

# --- 7. company wins over personal for the active company ------------------
make_skill "$PERSONAL_SKILLS/report" 'echo "personal-report"'
out="$(run_hook "$(payload '/report' 's-acme')")"
assert_contains "$out" 'acme-report' "company overrides personal"

# --- 8. tenant isolation: another company's namespace is refused -----------
make_skill "$CO/beta/skills/classified" 'echo "beta-only"'
assert_empty "$(run_hook "$(payload '/beta:classified' 's-acme')")" \
  "cross-company namespace is refused"
assert_empty "$(run_hook "$(payload '/beta:classified' 's-unbound')")" \
  "unbound session cannot reach a company script"
assert_empty "$(run_hook "$(payload '/classified' 's-acme')")" \
  "bare name does not reach a non-active company"

# --- 9. explicit personal namespace pins the root --------------------------
out="$(run_hook "$(payload '/personal:report' 's-acme')")"
assert_contains "$out" 'personal-report' "personal: namespace pins the root"

# --- 10. path traversal is refused -----------------------------------------
assert_empty "$(run_hook "$(payload '/../../etc/passwd')")" "traversal is refused"
assert_empty "$(run_hook "$(payload '/a/b')")" "slash in name is refused"
assert_empty "$(run_hook "$(payload '/foo;id')")" "shell metacharacter is refused"

# --- 11. symlinked command.sh is refused -----------------------------------
mkdir -p "$CORE_SKILLS/linked"
printf '%s\n' 'echo "should-not-run"' > "$TMP_ROOT/elsewhere.sh"
chmod +x "$TMP_ROOT/elsewhere.sh"
ln -s "$TMP_ROOT/elsewhere.sh" "$CORE_SKILLS/linked/command.sh"
assert_empty "$(run_hook "$(payload '/linked')")" "symlinked command.sh is refused"

# --- 12. a failing script reports, but does not block ----------------------
make_skill "$CORE_SKILLS/broken" 'echo "partial"; exit 3'
out="$(run_hook "$(payload '/broken')")"
rc=$?
[ "$rc" -eq 0 ] || fail "failing script: hook must still exit 0, got $rc"
assert_contains "$out" 'exited 3' "failing script reports its status"
assert_contains "$out" 'partial' "failing script output is still shown"

# --- 13. stderr is captured too --------------------------------------------
make_skill "$CORE_SKILLS/noisy" 'echo "to-stderr" >&2'
assert_contains "$(run_hook "$(payload '/noisy')")" 'to-stderr' "stderr is captured"

# --- 14. args and scope reach the script -----------------------------------
make_skill "$CORE_SKILLS/echoargs" 'echo "args=[$HQ_COMMAND_ARGS] name=[$HQ_COMMAND_NAME] scope=[$HQ_COMMAND_SCOPE]"'
out="$(run_hook "$(payload '/echoargs one two')")"
assert_contains "$out" 'args=[one two]' "arguments reach the script"
assert_contains "$out" 'name=[echoargs]' "command name reaches the script"
assert_contains "$out" 'scope=[core]' "scope reaches the script"

# --- 15. active company reaches the script ---------------------------------
make_skill "$CO/acme/skills/whoco" 'echo "co=[$HQ_ACTIVE_COMPANY]"'
assert_contains "$(run_hook "$(payload '/whoco' 's-acme')")" 'co=[acme]' \
  "active company reaches the script"

# --- 16. the payload reaches the script on stdin ---------------------------
make_skill "$CORE_SKILLS/readsin" 'cat'
assert_contains "$(run_hook "$(payload '/readsin')")" 'UserPromptSubmit' \
  "payload is piped to the script"

# --- 17. a hanging script is bounded ---------------------------------------
if command -v timeout >/dev/null 2>&1 || command -v perl >/dev/null 2>&1; then
  make_skill "$CORE_SKILLS/hangs" 'sleep 30'
  start="$(date +%s)"
  out="$(run_hook "$(payload '/hangs')" HQ_SKILL_COMMAND_TIMEOUT=1)"
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  [ "$rc" -eq 0 ] || fail "timeout: hook must still exit 0, got $rc"
  [ "$elapsed" -lt 10 ] || fail "timeout: took ${elapsed}s, expected the 1s bound"
  assert_contains "$out" 'timed out after 1s' "a hanging script is bounded"
else
  echo "  skip - no timeout/perl on PATH, cannot bound a hanging script"
fi

# --- 18. output is capped --------------------------------------------------
make_skill "$CORE_SKILLS/flood" 'i=0; while [ $i -lt 500 ]; do echo "0123456789012345678901234567890123456789"; i=$((i+1)); done'
out="$(run_hook "$(payload '/flood')" HQ_SKILL_COMMAND_MAX_BYTES=200)"
assert_contains "$out" 'truncated at 200 bytes' "runaway output is capped"
[ "${#out}" -lt 1500 ] || fail "cap: systemMessage still ${#out} bytes"
ok "capped message stays small"

# --- 19. the emitted JSON is valid and shaped correctly --------------------
out="$(run_hook "$(payload '/pulse')")"
printf '%s' "$out" | jq -e 'type == "object" and has("systemMessage")' >/dev/null \
  || fail "emitted output is not a JSON object with systemMessage: $out"
ok "emits a single valid JSON object"
printf '%s' "$out" | jq -e 'keys == ["systemMessage"]' >/dev/null \
  || fail "emitted object carries keys other than systemMessage: $out"
ok "systemMessage is the only key"

# --- 20. kill switches ------------------------------------------------------
assert_empty "$(run_hook "$(payload '/pulse')" HQ_SKILL_COMMAND_SCRIPTS=0)" \
  "HQ_SKILL_COMMAND_SCRIPTS=0 disables the hook"
assert_empty "$(run_hook "$(payload '/pulse')" HQ_DISABLED_HOOKS=skill-command-script)" \
  "HQ_DISABLED_HOOKS disables the hook"
assert_empty "$(run_hook "$(payload '/pulse')" HQ_DISABLED_HOOKS='*')" \
  "HQ_DISABLED_HOOKS=* disables the hook"

# --- 21. configurable script name ------------------------------------------
mkdir -p "$CORE_SKILLS/renamed"
printf '%s\n' 'echo "renamed-ran"' > "$CORE_SKILLS/renamed/on-invoke.sh"
assert_empty "$(run_hook "$(payload '/renamed')")" "non-default name is ignored by default"
assert_contains "$(run_hook "$(payload '/renamed')" HQ_SKILL_COMMAND_FILE=on-invoke.sh)" \
  'renamed-ran' "HQ_SKILL_COMMAND_FILE selects the script name"

# --- 22. empty / malformed input -------------------------------------------
assert_empty "$(printf '' | HQ_ROOT="$TMP_ROOT" bash "$HOOK")" "empty stdin is a no-op"
assert_empty "$(printf 'not json' | HQ_ROOT="$TMP_ROOT" bash "$HOOK")" "non-JSON stdin is a no-op"

# --- 24. traversal guard is load-bearing, not incidentally satisfied --------
# The cases in 10 pass even with the slug guard removed, because the paths they
# build happen not to exist. These plant a real command.sh at the exact place
# each traversal would land, so the only thing that can refuse them is the
# guard itself.
#   "/../evil" resolves <root>/core/skills/../evil -> <root>/core/evil, which is
#   still inside HQ_ROOT, so the containment check cannot catch it.
make_skill "$TMP_ROOT/core/evil" 'echo "traversal-escaped"'
out="$(run_hook "$(payload '/../evil')")"
assert_empty "$out" "traversal inside HQ_ROOT is refused by the slug guard"
#   ...and one that leaves HQ_ROOT entirely, which the containment check owns.
OUTSIDE="$TMP_ROOT/../outside-hq-$$"
make_skill "$OUTSIDE" 'echo "left-the-root"'
out="$(run_hook "$(payload "/../../outside-hq-$$")")"
assert_empty "$out" "traversal out of HQ_ROOT is refused"
rm -rf "$OUTSIDE"

# --- 25. containment check: a skill DIRECTORY symlinked out of HQ_ROOT ------
# The slug guard already refuses anything with a "/" in the name, so a
# traversal string never reaches the containment check. The case that does is a
# skill directory that is itself a symlink pointing outside HQ_ROOT -- the name
# is a clean slug, the dir exists, and command.sh is a real file. Only the
# resolved-path containment check can refuse it. HQ symlinks knowledge and repo
# directories routinely, so this is a reachable shape, not a contrived one.
ESCAPED="$TMP_ROOT/../escaped-skill-$$"
make_skill "$ESCAPED" 'echo "outside-hq-root-ran"'
ln -s "$ESCAPED" "$CORE_SKILLS/escapee"
out="$(run_hook "$(payload '/escapee')")"
assert_empty "$out" "a skill dir symlinked outside HQ_ROOT is refused"
rm -rf "$ESCAPED" "$CORE_SKILLS/escapee"
# A skill dir symlinked to another location INSIDE HQ_ROOT stays allowed.
make_skill "$TMP_ROOT/personal/elsewhere" 'echo "inside-root-ran"'
ln -s "$TMP_ROOT/personal/elsewhere" "$CORE_SKILLS/insider"
out="$(run_hook "$(payload '/insider')")"
assert_contains "$out" 'inside-root-ran' "a skill dir symlinked within HQ_ROOT still runs"

# --- 23. live-captured payload shape ----------------------------------------
# The synthetic payloads above carry three keys. A real interactive
# UserPromptSubmit payload, captured from this harness on a /hq-whoami turn,
# carries seven -- including prompt_id, whose name contains the substring the
# hot-path prefilter matches on. Pin the real shape so a fixture built from an
# assumption cannot pass while the live payload fails.
live_payload() { # <prompt>
  jq -nc --arg p "$1" '{
    cwd: "/tmp/hq",
    hook_event_name: "UserPromptSubmit",
    permission_mode: "bypassPermissions",
    prompt: $p,
    prompt_id: "b2e1c7d4-0000-4aaa-9bbb-1c2d3e4f5a6b",
    session_id: "s-test",
    transcript_path: "/tmp/hq/transcript.jsonl"
  }'
}
out="$(printf '%s' "$(live_payload '/pulse')" | HQ_ROOT="$TMP_ROOT" bash "$HOOK")"
assert_contains "$out" 'pulse-ran' "live 7-key payload resolves the command"
assert_contains "$out" '"systemMessage"' "live payload still emits systemMessage"
out="$(printf '%s' "$(live_payload 'an ordinary question')" | HQ_ROOT="$TMP_ROOT" bash "$HOOK")"
assert_empty "$out" "live payload with a plain prompt is a no-op"
# prompt_id must not be mistaken for prompt by the prefilter or the parser.
out="$(printf '%s' "$(jq -nc '{prompt_id:"/pulse",hook_event_name:"UserPromptSubmit",session_id:"s-test",prompt:"hello"}')" \
  | HQ_ROOT="$TMP_ROOT" bash "$HOOK")"
assert_empty "$out" "a slash value in prompt_id does not trigger the hook"

echo
echo "PASS: $PASS assertions"
