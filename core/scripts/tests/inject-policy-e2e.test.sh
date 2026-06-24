#!/usr/bin/env bash
# End-to-end battery for the policy-trigger pipeline: drives the REAL hook
# (.claude/hooks/inject-policy-on-trigger.sh) with realistic hook JSON and
# asserts which policy slugs get injected. Exercises the full path:
#   hook event -> derive-trigger-facts.sh -> eval-trigger.sh -> <policy-reminder>.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
PASS=0; FAIL=0
# Counter in a file: run_hook executes inside $(...) subshells, so a plain shell
# var would never persist the increment back to the parent — every case would
# reuse one session_id and per-session dedup would suppress slugs that already
# fired in an earlier case. The file survives the subshell.
SIDFILE="$(mktemp)"; printf '0' > "$SIDFILE"
trap 'rm -f "$SIDFILE"' EXIT
# A per-RUN nonce makes session ids unique across separate invocations of this
# script, so leftover dedup files from a prior run never pre-suppress this run.
RUN="$$-$RANDOM"

# run_hook <event> <json-without-event-or-session> -> stdout of hook
# Each call gets a UNIQUE session_id so cases are dedup-isolated.
run_hook() {
  local event="$1" body="$2" n
  n=$(( $(cat "$SIDFILE") + 1 )); printf '%s' "$n" > "$SIDFILE"
  printf '{"hook_event_name":"%s","session_id":"e2e-%s-%s",%s}' "$event" "$RUN" "$n" "$body" \
    | HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" 2>/dev/null
}

# slugs <hook-output> -> newline list of injected slugs.
# PURE BASH — no subprocess. The previous version forked `sed` inside $(...) on
# every membership check (two or three forks per assertion). Under heavy load
# (e.g. looping this suite, which fires the hook hundreds of times) a transient
# fork failure made one `slugs` call return empty, so a slug that WAS present
# read as absent and the assertion false-failed nondeterministically. Parsing
# in-process removes the fork entirely and makes the harness deterministic
# regardless of system load. (The hook output was always correct — this only
# ever flaked in the test's own membership check.)
slugs() {
  local line s
  while IFS= read -r line; do
    case "$line" in
      '> Policy `'*) s="${line#'> Policy `'}"; printf '%s\n' "${s%%\`*}" ;;
    esac
  done <<SLUGS_EOF
$1
SLUGS_EOF
}

# fork-free membership: is <slug> ($1) a line in the newline list <list> ($2)?
_has_slug() { case $'\n'"$2"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; *) return 1 ;; esac; }

# assert_has <label> <output> <slug...>
assert_has() {
  local label="$1" out="$2"; shift 2
  local got; got="$(slugs "$out")"
  local s ok=1
  for s in "$@"; do
    _has_slug "$s" "$got" || { ok=0; echo "FAIL [$label]: expected slug '$s'; got: [$(printf '%s' "$got" | tr '\n' ' ')]"; }
  done
  [ "$ok" = 1 ] && { PASS=$((PASS+1)); echo "ok   [$label]: $*"; } || FAIL=$((FAIL+1))
}

# assert_not <label> <output> <slug...>
assert_not() {
  local label="$1" out="$2"; shift 2
  local got; got="$(slugs "$out")"
  local s ok=1
  for s in "$@"; do
    _has_slug "$s" "$got" && { ok=0; echo "FAIL [$label]: did NOT expect '$s'; got: [$(printf '%s' "$got" | tr '\n' ' ')]"; }
  done
  [ "$ok" = 1 ] && { PASS=$((PASS+1)); echo "ok   [$label]: none of $*"; } || FAIL=$((FAIL+1))
}

# assert_empty <label> <output>
assert_empty() {
  local label="$1" out="$2"
  local got; got="$(slugs "$out")"
  [ -z "$got" ] && { PASS=$((PASS+1)); echo "ok   [$label]: no injection"; } \
    || { FAIL=$((FAIL+1)); echo "FAIL [$label]: expected nothing; got: [$(printf '%s' "$got" | tr '\n' ' ')]"; }
}

# bash <cmd> helper for PreToolUse Bash JSON body
bashbody() { printf '"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"' "$1" "$ROOT"; }
promptbody() { printf '"prompt":"%s","cwd":"%s"' "$1" "$ROOT"; }

echo "== git family (PreToolUse Bash) =="
O="$(run_hook PreToolUse "$(bashbody 'git push origin main')")"
assert_has "git push->shared" "$O" hq-always-pr-shared-state-repos
O="$(run_hook PreToolUse "$(bashbody 'git commit -m wip')")"
assert_has "git commit"        "$O" hq-git-branch-verify
assert_not "commit !=> push"   "$O" hq-always-pr-shared-state-repos hq-no-force-push-diverged-release-branch
O="$(run_hook PreToolUse "$(bashbody 'git merge --ff-only origin/main')")"
assert_has "git merge"         "$O" hq-git-merge-ff-only-trunk

echo "== build / deploy =="
O="$(run_hook PreToolUse "$(bashbody 'docker buildx build --platform linux/amd64 .')")"
assert_has "docker build"      "$O" hq-docker-build-platform-amd64
O="$(run_hook UserPromptSubmit "$(promptbody 'please deploy to prod')")"
assert_has "deploy prompt"     "$O" hq-announce-before-irreversible

echo "== grep / search =="
O="$(run_hook PreToolUse "$(bashbody 'grep -r TODO .')")"
assert_has "grep"              "$O" hq-qmd-first-for-hq-search hq-no-grep-discovery

echo "== secret / credential =="
O="$(run_hook PreToolUse "$(bashbody 'AWS_PROFILE=x aws s3 ls')")"
assert_has "aws_profile->secret" "$O" credential-access-protocol

echo "== slash-commands (UserPromptSubmit) =="
O="$(run_hook UserPromptSubmit "$(promptbody '/prd for the dashboard')")"
assert_has "/prd"              "$O" prd-content-sources prd-story-sizing prd-validation
O="$(run_hook UserPromptSubmit "$(promptbody '/plan for the dashboard')")"
assert_has "/plan"             "$O" prd-content-sources prd-story-sizing prd-validation
O="$(run_hook UserPromptSubmit "$(promptbody '/run-project the auth epic')")"
assert_has "/run-project"      "$O" prd-validation regression-gate-lint-fix verify-routes-after-parallel-execution ralph-orchestrator-context-discipline hq-learn-auto-no-confirmation
O="$(run_hook UserPromptSubmit "$(promptbody 'kick off /deep-plan now')")"
assert_has "/deep-plan"        "$O" hq-deep-plan-skill-routing
O="$(run_hook UserPromptSubmit "$(promptbody '/handoff please')")"
assert_has "/handoff"          "$O" hq-handoff-changeset-scope

echo "== ai-velocity-time-sense: scoped to planning/estimate/handoff skills =="
O="$(run_hook UserPromptSubmit "$(promptbody '/track-estimate for this task')")"
assert_has "/track-estimate"   "$O" ai-velocity-time-sense
O="$(run_hook UserPromptSubmit "$(promptbody '/brainstorm the architecture')")"
assert_has "/brainstorm->velocity" "$O" ai-velocity-time-sense
O="$(run_hook UserPromptSubmit "$(promptbody 'fix the failing test in auth')")"
assert_not "velocity not always" "$O" ai-velocity-time-sense

echo "== filename tokens (UserPromptSubmit) =="
O="$(run_hook UserPromptSubmit "$(promptbody 'edit .claude/settings.json perms')")"
assert_has "settings.json"     "$O" hq-permission-rules-literal-subcommand-prefixes hq-permissions-fan-out-edit-write-multiedit hq-rm-permission-allow-scope-paths hq-claude-code-default-mode-plan-not-auto
assert_not "settings != jq/mcp" "$O" hq-jq-atomic-edits-large-json-configs mcp-transport-detection
O="$(run_hook UserPromptSubmit "$(promptbody 'add a server to .mcp.json')")"
assert_has ".mcp.json"         "$O" mcp-transport-detection hq-jq-atomic-edits-large-json-configs
O="$(run_hook UserPromptSubmit "$(promptbody 'review the shot.png export')")"
assert_has ".png->image"       "$O" hq-image-context-isolation

echo "== AssistantIntent (assistant names a file before a Bash call) =="
TR="$(mktemp)"; { printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"}}'; printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will edit .mcp.json to add the server"}]}}'; } > "$TR"
O="$(run_hook PreToolUse "$(printf '"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"%s","transcript_path":"%s"' "$ROOT" "$TR")")"
assert_has "intent .mcp.json"  "$O" mcp-transport-detection hq-jq-atomic-edits-large-json-configs
rm -f "$TR"

echo "== bash-only tool scoping =="
O="$(run_hook PreToolUse "$(printf '"tool_name":"Glob","tool_input":{"pattern":"**/*.ts"},"cwd":"%s"' "$ROOT")")"
assert_empty "Glob skipped"    "$O"
O="$(run_hook PreToolUse "$(printf '"tool_name":"Read","tool_input":{"file_path":"/x.png"},"cwd":"%s"' "$ROOT")")"
assert_empty "Read skipped"    "$O"

echo "== SessionStart baseline backfill (injected on ANY first event, then deduped) =="
# A neutral event matching NO reactive trigger still backfills the always-on
# SessionStart baseline on the FIRST event of a fresh session.
BSID1="baseline-bash-$RUN"
O="$(printf '{"hook_event_name":"PreToolUse","session_id":"%s","tool_name":"Bash","tool_input":{"command":"ls -la"},"cwd":"%s"}' "$BSID1" "$ROOT" | HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" 2>/dev/null)"
assert_has "baseline on first Bash" "$O" decision-queue-one-at-a-time hq-audience-mode quiet-by-default-narration
# Second neutral event in the SAME session: baseline already recorded -> nothing.
O2="$(printf '{"hook_event_name":"PreToolUse","session_id":"%s","tool_name":"Bash","tool_input":{"command":"echo hi"},"cwd":"%s"}' "$BSID1" "$ROOT" | HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" 2>/dev/null)"
assert_empty "baseline deduped 2nd event" "$O2"
# Same backfill when the first event of a fresh session is a neutral prompt.
BSID2="baseline-prompt-$RUN"
O="$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt":"what does this function do?","cwd":"%s"}' "$BSID2" "$ROOT" | HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" 2>/dev/null)"
assert_has "baseline on first prompt" "$O" decision-queue-one-at-a-time hq-audience-mode

echo "== negative / neutral (baseline pre-warmed -> no reactive noise) =="
# Pre-warm a session via SessionStart so the baseline is injected+recorded, then
# fire neutral events on that SAME session: nothing new should surface.
NSID="neutral-$RUN"
printf '{"hook_event_name":"SessionStart","session_id":"%s","cwd":"%s"}' "$NSID" "$ROOT" | HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" >/dev/null 2>&1
nrun() { printf '{"hook_event_name":"%s","session_id":"%s",%s}' "$1" "$NSID" "$2" | HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" 2>/dev/null; }
O="$(nrun PreToolUse "$(bashbody 'ls -la')")"
assert_empty "plain ls (warmed)"        "$O"
O="$(nrun UserPromptSubmit "$(promptbody 'what does this function do?')")"
assert_empty "neutral prompt (warmed)"  "$O"

echo "== legacy regex map (precise patterns) =="
O="$(run_hook PreToolUse "$(bashbody 'find . -name foo')")"
assert_has "find->glob-scoped" "$O" hq-glob-scoped-path
O="$(run_hook PreToolUse "$(bashbody 'git checkout HEAD -- .')")"
assert_has "checkout -- ."     "$O" git-checkout-not-a-probe

echo "== install supply-chain =="
O="$(run_hook PreToolUse "$(bashbody 'pnpm add left-pad')")"
assert_has "pnpm add"          "$O" hq-pnpm-min-release-age-supply-chain

echo "== per-session dedupe =="
FIX="dedupe-$RUN"
emit() { printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt":"/handoff","cwd":"%s"}' "$FIX" "$ROOT" | HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" 2>/dev/null; }
A="$(emit)"; B="$(emit)"
[ -n "$(slugs "$A")" ] && [ -z "$(slugs "$B")" ] \
  && { PASS=$((PASS+1)); echo "ok   [dedupe]: fires once, suppressed second time"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL [dedupe]: A=[$(slugs "$A" | tr '\n' ' ')] B=[$(slugs "$B" | tr '\n' ' ')]"; }

echo
echo "==== e2e: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ] || exit 1
