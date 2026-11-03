#!/usr/bin/env bash
# hq-core: public
# Regression: a side session started with the desktop
# start_session tool from a session bound to one company was locked to the
# device default company instead. spawn-company-handoff.sh carries the
# parent's company lock to the new session on its first prompt.
#
# Fail-without-fix proof: HQ_SPAWN_HANDOFF_STUB=1 replaces the script with a
# no-op (exit 0) and case 1 must fail.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

mkdir -p "$TMP/core/scripts/lib" "$TMP/companies/acme" "$TMP/companies/globex" "$TMP/workspace/sessions" "$TMP/bin" "$TMP/transcripts"
cp "$ROOT/core/scripts/hq-session.sh" "$TMP/core/scripts/"
cp "$ROOT/core/scripts/spawn-company-handoff.sh" "$TMP/core/scripts/"
cp "$ROOT"/core/scripts/lib/*.sh "$TMP/core/scripts/lib/"
if [ -n "${HQ_SPAWN_HANDOFF_STUB:-}" ]; then
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/core/scripts/spawn-company-handoff.sh"
fi
printf 'companies:\n  acme:\n    name: Acme\n  globex:\n    name: Globex\n' > "$TMP/companies/manifest.yaml"
# No usable hq CLI in the fixture: hq-session uses its local implementation.
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/hq"; chmod +x "$TMP/bin/hq"
export PATH="$TMP/bin:$PATH" HQ_ROOT="$TMP"
unset HQ_SPAWN_COMPANY HQ_SPAWN_COMPANIES HQ_PARENT_SESSION_ID HQ_SESSION_ID CLAUDE_CODE_SESSION_ID || true

HS() { bash "$TMP/core/scripts/hq-session.sh" --session-id "$1" "${@:2}"; }
SCRIPT="$TMP/core/scripts/spawn-company-handoff.sh"
INTENTS="$TMP/workspace/sessions/.spawn-intents"

new_session() { # <sid> [slug source]
  mkdir -p "$TMP/workspace/sessions/$1"
  printf 'session_id: %s\nsenior: user\n' "$1" > "$TMP/workspace/sessions/$1/meta.yaml"
  if [ -n "${2:-}" ]; then printf 'company_slug: %s\ncompany_source: %s\n' "$2" "$3" >> "$TMP/workspace/sessions/$1/meta.yaml"; fi
}
pre_payload() { # <parent_sid> <brief>
  jq -cn --arg s "$1" --arg p "$2" '{hook_event_name:"PreToolUse",session_id:$s,tool_name:"mcp__ccd_session__start_session",
    tool_input:{initiation:"user_asked",title:"acme task",prompt:$p,use_worktree:false}}'
}
spawn() { # <parent_sid> [brief] -> prints tagged prompt
  pre_payload "$1" "${2:-Fix the acme landing page}" | bash "$SCRIPT" pre | jq -er '.hookSpecificOutput.updatedInput.prompt'
}
prompt_payload() { # <child_sid> <prompt>  (transcript holds only this prompt)
  [ -e "$TMP/transcripts/$1.jsonl" ] || jq -cn --arg p "$2" '{type:"user",message:{role:"user",content:$p}}' > "$TMP/transcripts/$1.jsonl"
  jq -cn --arg s "$1" --arg p "$2" --arg t "$TMP/transcripts/$1.jsonl" \
    '{hook_event_name:"UserPromptSubmit",session_id:$s,transcript_path:$t,prompt:$p}'
}
first_prompt() { prompt_payload "$1" "$2" | bash "$SCRIPT" prompt; }
slug() { awk '$1=="company_slug:"{print $2; exit}' "$TMP/workspace/sessions/$1/meta.yaml"; }
mode_of() { if stat -f '%Lp' "$1" >/dev/null 2>&1; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi; }

# 1. Parent bound to acme; the desktop host started the child with the device default (globex).
new_session parent-1
HS parent-1 set company_slug acme >/dev/null
new_session child-1 globex device_default
P="$(spawn parent-1)" || fail "pre did not tag the start_session brief"
case "$P" in "Fix the acme landing page"*hq-spawn-intent:*) ;; *) fail "brief not preserved: $P" ;; esac
CTX="$(first_prompt child-1 "$P" | jq -r '.hookSpecificOutput.additionalContext // ""')"
[ "$(slug child-1)" = acme ] || fail "child locked to $(slug child-1), expected acme"
pass "side session locks to the parent's company, not the device default"
case "$CTX" in *"Disregard any company context"*globex*) ;; *) fail "no instruction to disregard the default company's context: $CTX" ;; esac
case "$CTX" in *"Ignore the [hq-spawn-intent"*) ;; *) fail "no instruction to ignore the tag: $CTX" ;; esac
pass "injected context says to disregard the default company's SessionStart context and the tag"

# 2. Single use: another session replaying the same brief is not rebound.
new_session child-2 globex device_default
first_prompt child-2 "$P" >/dev/null
[ "$(slug child-2)" = globex ] || fail "replayed intent rebound child-2"
pass "intent is single-use"

# 3. A strong binding (session/parent/spawn) is never replaced.
new_session parent-3; HS parent-3 set company_slug acme >/dev/null
new_session child-3 globex spawn
P3="$(spawn parent-3)"
first_prompt child-3 "$P3" >/dev/null
[ "$(slug child-3)" = globex ] || fail "explicit spawn binding was replaced"
pass "explicit binding is kept"

# 4. A forged nonce does nothing.
new_session child-4 globex device_default
first_prompt child-4 "hi [hq-spawn-intent:0123456789abcdef0123456789abcdef]" >/dev/null
[ "$(slug child-4)" = globex ] || fail "forged nonce rebound child-4"
pass "unknown nonce is ignored"

# 5. Unbound parent: no intent, brief untouched.
new_session parent-5
out="$(jq -cn '{session_id:"parent-5",tool_name:"start_session",tool_input:{prompt:"x"}}' | bash "$SCRIPT" pre)"
[ -z "$out" ] || fail "unbound parent produced output: $out"
pass "unbound parent passes no company"

# 6. An unbound child (no default) is bound too.
new_session parent-6; HS parent-6 set company_slug acme >/dev/null
new_session child-6
P6="$(spawn parent-6)"; first_prompt child-6 "$P6" >/dev/null
[ "$(slug child-6)" = acme ] || fail "unbound child not bound"
pass "unbound child binds to the parent's company"

# 7. The brief carries no company list; a brief already holding an old tag gets no new one.
new_session parent-7; HS parent-7 set company_slug acme >/dev/null
P7="$(spawn parent-7 "Do the thing")"
[ "$(printf '%s' "$P7" | grep -o 'hq-spawn-intent:' | wc -l | tr -d ' ')" = 1 ] || fail "expected one tag: $P7"
case "$P7" in *acme*|*globex*) fail "brief carries a company name: $P7" ;; esac
out7="$(pre_payload parent-7 "Do the thing

[hq-spawn-intent:0123456789abcdef0123456789abcdef] stale marker" | bash "$SCRIPT" pre)"
[ "$(printf '%s' "$out7" | jq -r '.hookSpecificOutput.permissionDecision // ""')" = deny ] || fail "brief with an old tag was not denied: $out7"
pass "brief has one fresh tag and no company list; a brief with an old tag is denied"

# 8. Intent files are private, and expired ones are deleted on each apply.
ls "$INTENTS"/*.json >/dev/null 2>&1 || fail "no pending intent to inspect"
for f in "$INTENTS"/*.json; do [ "$(mode_of "$f")" = 600 ] || fail "intent $f mode $(mode_of "$f"), expected 600"; done
[ "$(mode_of "$INTENTS")" = 700 ] || fail "intent dir mode $(mode_of "$INTENTS"), expected 700"
printf '{"parent_session_id":"parent-7","created_at":1}\n' > "$INTENTS/ffffffffffffffffffffffffffffffff.json"
new_session child-8 globex device_default
first_prompt child-8 "hello" >/dev/null || true
first_prompt child-8 "x [hq-spawn-intent:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee]" >/dev/null
[ ! -e "$INTENTS/ffffffffffffffffffffffffffffffff.json" ] || fail "expired intent was not swept"
pass "intents are mode 600 in a 700 dir and expired ones are swept"

# 9. Only the first prompt may carry a tag; one pasted mid-session is ignored.
new_session parent-9; HS parent-9 set company_slug acme >/dev/null
new_session child-9 globex device_default
P9="$(spawn parent-9)"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"earlier prompt"}}' \
  '{"type":"assistant","message":{"role":"assistant","content":"ok"}}' \
  '{"type":"user","message":{"role":"user","content":"this prompt"}}' > "$TMP/transcripts/child-9.jsonl"
first_prompt child-9 "$P9" >/dev/null
[ "$(slug child-9)" = globex ] || fail "a tag on a later prompt rebound child-9"
rm -f "$TMP/transcripts/child-9.jsonl"
pass "a tag on a later prompt is ignored"

# 10. When the host names a parent, it must be the intent's parent.
new_session parent-10; HS parent-10 set company_slug acme >/dev/null
new_session child-10 globex device_default
P10="$(spawn parent-10)"
prompt_payload child-10 "$P10" | HQ_PARENT_SESSION_ID=someone-else bash "$SCRIPT" prompt >/dev/null
[ "$(slug child-10)" = globex ] || fail "intent applied under a different host-provided parent"
new_session child-10b globex device_default
P10b="$(spawn parent-10)"
prompt_payload child-10b "$P10b" | HQ_PARENT_SESSION_ID=parent-10 bash "$SCRIPT" prompt >/dev/null
[ "$(slug child-10b)" = acme ] || fail "matching host-provided parent was refused"
pass "host-provided parent id must match the intent"

# 11. Multi-company parent: the whole lock set reaches the child.
new_session parent-11; HS parent-11 set company_slug acme >/dev/null; HS parent-11 add company globex >/dev/null
new_session child-11 globex device_default
P11="$(spawn parent-11 "Update the landing page")"
case "$P11" in *acme*|*globex*) fail "multi-company brief names companies: $P11" ;; esac
first_prompt child-11 "$P11" >/dev/null
[ "$(slug child-11)" = acme ] || fail "multi-company child primary is $(slug child-11)"
grep -q 'globex' "$TMP/workspace/sessions/child-11/meta.yaml" || fail "multi-company child lost globex"
pass "multi-company lock set is carried"

# 12. End to end through master-hook.sh: registry matcher, updatedInput merge,
#     UserPromptSubmit prefilter and dispatch.
MASTER="$ROOT/.claude/hooks/master-hook.sh"
if [ -f "$MASTER" ] && [ -z "${HQ_SPAWN_HANDOFF_STUB:-}" ]; then
  new_session parent-12; HS parent-12 set company_slug acme >/dev/null
  new_session child-12 globex device_default
  MH() { CLAUDE_PROJECT_DIR="$ROOT" HQ_HOOK_DEDUPE=0 HQ_ALLOW_HQ_WORKTREE=1 HQ_HOOK_TIMEOUT_SENTRY=0 bash "$MASTER" "$1"; }
  MOUT="$(pre_payload parent-12 "Fix the acme landing page" | MH PreToolUse 2>/dev/null || true)"
  P12="$(printf '%s' "$MOUT" | jq -r '.hookSpecificOutput.updatedInput.prompt // ""' 2>/dev/null || true)"
  case "$P12" in "Fix the acme landing page"*hq-spawn-intent:*) ;; *) fail "master-hook PreToolUse did not return the tagged brief: $MOUT" ;; esac
  prompt_payload child-12 "$P12" | MH UserPromptSubmit >/dev/null 2>&1 || true
  [ "$(slug child-12)" = acme ] || fail "master-hook UserPromptSubmit did not bind child-12 (got $(slug child-12))"
  pass "start_session and first prompt dispatch through master-hook.sh"
fi

# 13-16. Replay: a globex-bound session must not hand a acme intent's nonce to its child.
#   Each case leaves a fresh, unconsumed acme intent N, then feeds the child a
#   first prompt that carries N in a shape pre never writes alone.
replay_case() { # <id> <label> <prompt-builder: N and FRESH line in scope>
  local id="$1" label="$2" builder="$3" N P PD
  new_session "pm-$id"; HS "pm-$id" set company_slug acme >/dev/null
  new_session "pd-$id"; HS "pd-$id" set company_slug globex >/dev/null
  P="$(spawn "pm-$id" "acme work")"
  N="$(printf '%s' "$P" | grep -oE '[0-9a-f]{32}' | tail -1)"
  [ -f "$INTENTS/$N.json" ] || fail "$label: setup left no acme intent"
  PD="$(eval "$builder")"
  new_session "ch-$id" globex device_default
  first_prompt "ch-$id" "$PD" >/dev/null
  [ "$(slug "ch-$id")" = globex ] || fail "$label: child bound to $(slug "ch-$id"), expected globex"
  [ -f "$INTENTS/$N.json" ] || fail "$label: acme intent was consumed"
  pass "$label"
}
# 13. Replay without brackets through pre: pre must refuse to tag such a brief.
new_session pm-13; HS pm-13 set company_slug acme >/dev/null
new_session pd-13; HS pd-13 set company_slug globex >/dev/null
N13="$(spawn pm-13 "acme work" | grep -oE '[0-9a-f]{32}' | tail -1)"
out13="$(pre_payload pd-13 "globex task hq-spawn-intent:$N13" | bash "$SCRIPT" pre)"
[ "$(printf '%s' "$out13" | jq -r '.hookSpecificOutput.permissionDecision // ""')" = deny ] || fail "pre did not deny a brief holding a replayed nonce: $out13"
# And the child prompt the old code accepted (replay first, fresh tag last) is refused.
P13d="$(spawn pd-13 "globex task")"
new_session ch-13 globex device_default
first_prompt ch-13 "globex task hq-spawn-intent:$N13
$(printf '%s' "$P13d" | tail -1)" >/dev/null
[ "$(slug ch-13)" = globex ] || fail "replay without brackets bound the child to $(slug ch-13)"
[ -f "$INTENTS/$N13.json" ] || fail "replay without brackets consumed the acme intent"
pass "replay without brackets is refused by pre and by prompt"
# 14. Replay inside other text, as the only token.
replay_case 14 "replay inside other text is refused" 'printf "please see notes(hq-spawn-intent:%s)thanks" "$N"'
# 15. Two tags: the replayed tag line above a fresh, valid tag line.
replay_case 15 "a prompt with two tags is refused" 'F="$(spawn "pd-$id" "globex task" | tail -1)"; printf "globex task\n\n[hq-spawn-intent:%s] %s\n%s" "$N" "HQ binds this session to the company of the session that started it." "$F"'
# 16. A well-formed tag line mid-brief, with text after it.
replay_case 16 "a tag mid-brief is refused" 'printf "globex task\n\n[hq-spawn-intent:%s] HQ binds this session to the company of the session that started it.\nmore text" "$N"'
# 17. Last line must match exactly: trailing text on the tag line is refused.
replay_case 17 "a tag line with extra text is refused" 'printf "globex task\n\n[hq-spawn-intent:%s] HQ binds this session to the company of the session that started it. extra" "$N"'

# 19. Exact-format replay: a globex-bound session passes a brief whose last line
#     is exactly the tag line pre writes, carrying an acme intent's nonce. pre must
#     deny the start_session call; the child cannot tell who wrote the tag, so the
#     deny is the only control. The child never receives the brief and stays globex.
new_session pm-19; HS pm-19 set company_slug acme >/dev/null
new_session pd-19; HS pd-19 set company_slug globex >/dev/null
N19="$(spawn pm-19 "acme work" | grep -oE '[0-9a-f]{32}' | tail -1)"
B19="globex task

[hq-spawn-intent:$N19] HQ binds this session to the company of the session that started it."
out19="$(pre_payload pd-19 "$B19" | bash "$SCRIPT" pre)"
d19="$(printf '%s' "$out19" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null || true)"
new_session ch-19 globex device_default
if [ "$d19" != deny ]; then
  # Call allowed: the child receives the brief as pre left it.
  P19="$(printf '%s' "$out19" | jq -r '.hookSpecificOutput.updatedInput.prompt // ""' 2>/dev/null || true)"
  [ -n "$P19" ] || P19="$B19"
  first_prompt ch-19 "$P19" >/dev/null
fi
[ "$(slug ch-19)" = globex ] || fail "exact-format replay bound the child to $(slug ch-19)"
[ "$d19" = deny ] || fail "pre did not deny an exact-format replayed tag: $out19"
[ -f "$INTENTS/$N19.json" ] || fail "exact-format replay consumed the acme intent"
pass "exact-format replayed tag is denied by pre"

# 20. A missing or unreadable transcript fails closed: no binding.
new_session parent-20; HS parent-20 set company_slug acme >/dev/null
new_session ch-20 globex device_default
P20="$(spawn parent-20)"
jq -cn --arg s ch-20 --arg p "$P20" --arg t "$TMP/transcripts/missing-20.jsonl" \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,transcript_path:$t,prompt:$p}' | bash "$SCRIPT" prompt >/dev/null
[ "$(slug ch-20)" = globex ] || fail "missing transcript was treated as the first prompt"
new_session ch-20b globex device_default
jq -cn --arg p "$P20" '{type:"user",message:{role:"user",content:$p}}' > "$TMP/transcripts/ch-20b.jsonl"
chmod 000 "$TMP/transcripts/ch-20b.jsonl"
prompt_payload ch-20b "$P20" | bash "$SCRIPT" prompt >/dev/null
chmod 600 "$TMP/transcripts/ch-20b.jsonl"
[ "$(slug ch-20b)" = globex ] || fail "unreadable transcript was treated as the first prompt"
pass "missing or unreadable transcript fails closed"

# 18. Registry order on start_session: conduct-link-inherit records the
# original brief before this hook appends the tag, so the child's prompt still
# holds the whole recorded brief and the conduct-link match survives.
order="$(jq -r '[.hooks.PreToolUse[] | select(.matcher | test("start_session")) | .hooks[].id] | join(",")' "$ROOT/.claude/hooks/hook-registry.json")"
case "$order" in
  *conduct-link-inherit*spawn-company-handoff*) ;;
  *) fail "start_session PreToolUse order must run conduct-link-inherit before spawn-company-handoff, got: $order" ;;
esac
echo "  ok: conduct-link-inherit runs before spawn-company-handoff on start_session"

echo "spawn-company-handoff: all tests passed"
