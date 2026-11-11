#!/usr/bin/env bash
# hq-core: public
# Regression: a session that starts at the HQ root is bound to the device
# default company by SessionStart before the first prompt is read. When the
# first prompt then names exactly one other manifest company (by slug or by its
# manifest name), nothing rebound the session: the natural-language router only
# hinted, the session title said "none resolved", and the cross-company scope
# guard blocked reads until the user bound the company by hand.
#
# natural-language-router.sh now rebinds on the FIRST prompt only, through
# hq-session.sh (the explicit bind path), when the binding is an unreplaced
# device default and the prompt names one company unambiguously.
#
# Cases:
#   1  device default + clear mention (manifest name) -> rebinds, full state
#   2  device default + clear mention (slug)          -> rebinds
#   3  ambiguous / multiple mentions                  -> no rebind, hint kept
#   4  second prompt                                  -> no rebind
#   5  explicit prior bind (and other strong sources)  -> no rebind
#   6  mention only in pasted content shapes           -> no rebind
#   7b resumed/forked transcript with prior turns   -> no rebind
#   10 ordinary-word slugs without a cue            -> no rebind
#   11 explicit cues (for/in/on, @, /, company)      -> rebind
#   7  mention of the already-bound company, tagged handoff, no transcript,
#      kill switch                                     -> no rebind
#   8  hq-session.sh stamps company_source on explicit bind / unbind
#   9  session title resolves the company after a prompt_mention bind
#   12 unbound scheduled-task run binds the one company its cwd or task
#      text names; disagreement, no evidence or a strong bind binds nothing

set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "prompt-company-first-message-bind: skipped (jq missing)"; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pcfmb.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

mkdir -p "$TMP/core/scripts/lib" "$TMP/.claude/hooks" "$TMP/companies/acme" "$TMP/companies/globex" \
  "$TMP/companies/initech" "$TMP/companies/team" "$TMP/companies/live" \
  "$TMP/companies/beta" "$TMP/companies/ridge" "$TMP/companies/ok" "$TMP/companies/hq-demo-3" \
  "$TMP/companies/liverecover" "$TMP/companies/indigo" "$TMP/companies/vyg-dev" "$TMP/companies/vyg""$TMP/workspace/sessions" "$TMP/bin" "$TMP/transcripts"
cp "$ROOT/core/scripts/hq-session.sh" "$ROOT/core/scripts/hook-lib.sh" "$ROOT/core/scripts/session-title.sh" "$TMP/core/scripts/"
cp "$ROOT"/core/scripts/lib/*.sh "$TMP/core/scripts/lib/"
cp "$ROOT/.claude/hooks/natural-language-router.sh" "$TMP/.claude/hooks/"
printf 'companies:\n  acme:\n    name: Acme\n  globex:\n    name: "Globex Corporation"  # display name\n  initech:\n    name: Initech\n  team:\n    name: Team\n  live:\n    name: Live\n  beta:\n    name: Beta\n  ridge:\n    name: Ridge\n  ok:\n    name: OK\n  hq-demo-3:\n    name: HQ Demo\n  liverecover:\n    name: LiveRecover\n  indigo:\n    name: Indigo\n  vyg-dev:\n    name: VYG Dev\n  vyg:\n    name: VYG\n' \
  > "$TMP/companies/manifest.yaml"
# No usable hq CLI: hq-session uses its in-tree implementation.
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/hq"; chmod +x "$TMP/bin/hq"
export PATH="$TMP/bin:$PATH" HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP"
unset HQ_SPAWN_COMPANY HQ_SPAWN_COMPANIES HQ_PARENT_SESSION_ID HQ_SESSION_ID CLAUDE_CODE_SESSION_ID \
  HQ_PROMPT_COMPANY_BIND HQ_NL_ROUTER HQ_DISABLED_HOOKS PCM_SCAN_CHARS || true

ROUTER="$TMP/.claude/hooks/natural-language-router.sh"
HS() { bash "$TMP/core/scripts/hq-session.sh" --session-id "$1" "${@:2}"; }
meta_get() { awk -v k="$2" '$1==k":"{sub(/^[^:]+:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit}' "$TMP/workspace/sessions/$1/meta.yaml"; }
cap_slugs() { # scope-capability company set for a session
  ( . "$TMP/core/scripts/lib/session-scope-capability.sh"; session_scope_read_companies "$TMP" "$1" | paste -sd, - )
}

# Session as SessionStart leaves it: a company bound with company_source=device_default.
new_session() { # <sid> <slug> [source]
  mkdir -p "$TMP/workspace/sessions/$1"
  printf 'session_id: %s\nsenior: user\nproject: old-project\ntask: old-task\n' "$1" > "$TMP/workspace/sessions/$1/meta.yaml"
  HQ_SESSION_COMPANY_SOURCE="${3:-device_default}" HS "$1" set company_slug "$2" >/dev/null
}
transcript() { # <sid> <user-line-count>
  : > "$TMP/transcripts/$1.jsonl"
  local i
  for i in $(seq 1 "$2"); do printf '{"type":"user","message":{"role":"user","content":"prompt %s"}}\n' "$i" >> "$TMP/transcripts/$1.jsonl"; done
}
payload() { # <sid> <prompt> [transcript-path]
  jq -cn --arg s "$1" --arg p "$2" --arg t "${3-$TMP/transcripts/$1.jsonl}" \
    '{hook_event_name:"UserPromptSubmit",session_id:$s,transcript_path:$t,prompt:$p}'
}
run_router() { payload "$@" | bash "$ROUTER"; }
ctx_of() { jq -r '.hookSpecificOutput.additionalContext // ""'; }
rm_marker() { rm -f "$TMP/workspace/orchestrator/policy-trigger-state/$1.nl-router-fired"; }

# 1. Clear mention by manifest name rebinds, with the same state an explicit bind leaves.
new_session s1 acme
transcript s1 1
OUT="$(run_router s1 "This session is for Globex Corporation: why is activity missing from the app?")"
[ "$(meta_get s1 company_slug)" = globex ] || fail "case 1: bound to '$(meta_get s1 company_slug)', expected globex"
[ "$(meta_get s1 company_source)" = prompt_mention ] || fail "case 1: company_source is '$(meta_get s1 company_source)'"
[ "$(meta_get s1 company_slugs)" = globex ] || fail "case 1: company_slugs is '$(meta_get s1 company_slugs)'"
[ "$(cap_slugs s1)" = globex ] || fail "case 1: scope capability is '$(cap_slugs s1)', expected globex only"
[ -z "$(meta_get s1 project)" ] && [ -z "$(meta_get s1 task)" ] || fail "case 1: old project/task survived the company change"
CTX="$(printf '%s' "$OUT" | ctx_of)"
case "$CTX" in *"bound this session to company globex"*"Disregard any company context"*acme*) ;; *) fail "case 1: no rebind notice naming both companies: $CTX" ;; esac
case "$CTX" in *"<natural-language-routing>"*) ;; *) fail "case 1: routing hint dropped" ;; esac
printf '%s' "$OUT" | jq -e . >/dev/null || fail "case 1: output is not valid JSON"
pass "device default + manifest-name mention rebinds (source, lock set, capability, project/task, notice)"

# 2. Slug mention, as in "VYG/liverecover".
new_session s2 acme
transcript s2 1
run_router s2 "@globex, fix the landing page" >/dev/null
[ "$(meta_get s2 company_slug)" = globex ] && [ "$(meta_get s2 company_source)" = prompt_mention ] \
  || fail "case 2: slug mention did not rebind ($(meta_get s2 company_slug)/$(meta_get s2 company_source))"
pass "slug mention rebinds"

# 3. Ambiguous: two companies named, or a name that overlaps another company's name.
new_session s3 acme
transcript s3 1
OUT="$(run_router s3 "Compare for globex and for initech onboarding flows")"
[ "$(meta_get s3 company_slug)" = acme ] && [ "$(meta_get s3 company_source)" = device_default ] || fail "case 3: multiple mentions rebound"
case "$(printf '%s' "$OUT" | ctx_of)" in *"<natural-language-routing>"*) ;; *) fail "case 3: hint missing" ;; esac
case "$(printf '%s' "$OUT" | ctx_of)" in *"bound this session"*) fail "case 3: notice present without a bind" ;; esac
new_session s3b acme
transcript s3b 1
run_router s3b "company globex corporation and company initech need a shared deck" >/dev/null
[ "$(meta_get s3b company_slug)" = acme ] || fail "case 3: two named companies rebound the session"
pass "ambiguous or multiple mentions keep the binding and today's hint"

# 4. Second prompt: transcript already holds an earlier prompt, and the router marker is spent.
new_session s4 acme
transcript s4 2
run_router s4 "now work for globex" >/dev/null
[ "$(meta_get s4 company_slug)" = acme ] || fail "case 4: second transcript prompt rebound"
new_session s4b acme
transcript s4b 1
run_router s4b "hello there" >/dev/null
run_router s4b "now work for globex" >/dev/null
[ "$(meta_get s4b company_slug)" = acme ] || fail "case 4: second router call rebound"
# Tool results in the transcript are not prompts: a resumed-free first prompt still counts as first.
new_session s4c acme
transcript s4c 1
printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}\n' >> "$TMP/transcripts/s4c.jsonl"
run_router s4c "work for globex" >/dev/null
[ "$(meta_get s4c company_slug)" = globex ] || fail "case 4: tool_result line counted as a user prompt"
pass "only the first prompt can rebind"

# 5. Strong bindings are never replaced.
for src in explicit session parent spawn spawn_intent manifest_single_company registry prompt_mention; do
  sid="s5-$src"
  new_session "$sid" acme "$src"
  transcript "$sid" 1
  run_router "$sid" "This session is for globex" >/dev/null
  [ "$(meta_get "$sid" company_slug)" = acme ] && [ "$(meta_get "$sid" company_source)" = "$src" ] \
    || fail "case 5: company_source=$src was replaced ($(meta_get "$sid" company_slug))"
done
# A bind made with plain `hq-session.sh set company_slug` (no env) is explicit.
new_session s5x acme
HS s5x set company_slug acme >/dev/null
[ "$(meta_get s5x company_source)" = explicit ] || fail "case 5: plain hq-session set did not stamp explicit"
transcript s5x 1
run_router s5x "This session is for globex" >/dev/null
[ "$(meta_get s5x company_slug)" = acme ] || fail "case 5: explicit hq-session bind was replaced"
# A capability that disagrees with meta, or a multi-company lock set, is left alone.
new_session s5y acme
HQ_SESSION_COMPANY_SOURCE=device_default HS s5y set company_slug acme >/dev/null
( . "$TMP/core/scripts/lib/session-scope-capability.sh"; session_scope_mint_set "$TMP" s5y "acme,initech" ) >/dev/null
transcript s5y 1
run_router s5y "This session is for globex" >/dev/null
[ "$(meta_get s5y company_slug)" = acme ] || fail "case 5: multi-company lock set was replaced"
pass "explicit, session, parent, spawn, registry, prior mention and multi-company bindings are never replaced"

# 6. Mentions inside pasted content shapes do not count.
n6=0
pasted() { # <prompt>
  n6=$((n6 + 1)); local sid="s6-$n6"
  new_session "$sid" acme
  transcript "$sid" 1
  run_router "$sid" "$1" >/dev/null
  [ "$(meta_get "$sid" company_slug)" = acme ] || fail "case 6.$n6: pasted-content mention rebound: $1"
}
FENCE='```'
pasted "$(printf 'Please summarize this log:\n%s\n2026-01-01 globex deploy failed\n%s\nThanks.' "$FENCE" "$FENCE")"
pasted "$(printf 'Look at this <tool_result>globex api returned 500</tool_result> please.')"
pasted "$(printf 'Why did this happen?\n> globex says the export is broken\nPlease advise.')"
pasted "$(printf 'Unterminated paste:\n%s\nglobex stack trace' "$FENCE")"
pasted "$(printf '%0600d' 0 | tr 0 x) for globex"
pasted "$(printf 'Look at this <system-reminder> for globex')"
pasted "$(printf '<system-reminder>\nfor globex\nmore text')"
pasted "summarize this for globex"
pasted "$(printf 'Please summarize this:\nfor globex the deploy failed')"
pasted "$(printf 'Why did the export fail?\nThe logs say: work for globex now')"
pasted "$(printf '%s\nfor globex' "$FENCE")"
pass "fenced code, tagged blocks (matched or unclosed), quoted lines, paste phrases, later lines and text past the scan window do not bind"

# 7. Other no-bind conditions.
new_session s7a acme; transcript s7a 1
run_router s7a "fix the acme landing page" >/dev/null
[ "$(meta_get s7a company_source)" = device_default ] || fail "case 7: naming the already-bound company changed the source"
new_session s7b acme; transcript s7b 1
run_router s7b "work for globex
[hq-spawn-intent:0123456789abcdef0123456789abcdef] HQ binds this session to the company of the session that started it." >/dev/null
[ "$(meta_get s7b company_slug)" = acme ] || fail "case 7: handoff-tagged prompt rebound"
new_session s7c acme
run_router s7c "work for globex" "" >/dev/null
[ "$(meta_get s7c company_slug)" = acme ] || fail "case 7: missing transcript rebound (must fail closed)"
new_session s7d acme; transcript s7d 1
HQ_PROMPT_COMPANY_BIND=0 run_router s7d "work for globex" >/dev/null
[ "$(meta_get s7d company_slug)" = acme ] || fail "case 7: kill switch ignored"
new_session s7e acme; transcript s7e 1
run_router s7e "/startwork globex" >/dev/null
[ "$(meta_get s7e company_slug)" = acme ] || fail "case 7: slash-command prompt rebound"
new_session s7f acme; transcript s7f 1
run_router s7f "tell me about globexx and myglobex" >/dev/null
[ "$(meta_get s7f company_slug)" = acme ] || fail "case 7: partial-word match rebound"
pass "same company, handoff tag, missing transcript, kill switch, slash command, partial word: no bind"

# 7b. Resume/fork under a new session id: prior turns in the transcript block a rebind,
# whether or not the current prompt has been written to it yet.
new_session s7g acme
: > "$TMP/transcripts/s7g.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"old prompt"}}' \
  '{"type":"assistant","message":{"role":"assistant","content":"old answer"}}' >> "$TMP/transcripts/s7g.jsonl"
run_router s7g "work for globex" >/dev/null
[ "$(meta_get s7g company_slug)" = acme ] || fail "case 7b: resumed transcript (user+assistant) rebound"
new_session s7h acme
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":"summary"}}' \
  '{"type":"user","message":{"role":"user","content":"work for globex"}}' > "$TMP/transcripts/s7h.jsonl"
run_router s7h "work for globex" >/dev/null
[ "$(meta_get s7h company_slug)" = acme ] || fail "case 7b: transcript with an assistant line rebound"
pass "a transcript with prior assistant turns never counts as a first prompt"

# 10. Companies whose slugs or names are ordinary words never bind without a cue.
n10=0
nobind() { # <prompt>
  n10=$((n10 + 1)); local sid="s10-$n10"
  new_session "$sid" acme
  transcript "$sid" 1
  run_router "$sid" "$1" >/dev/null
  [ "$(meta_get "$sid" company_slug)" = acme ] && [ "$(meta_get "$sid" company_source)" = device_default ] \
    || fail "case 10.$n10: rebound to $(meta_get "$sid" company_slug): $1"
}
nobind "ask the team why the export is slow"
nobind "Why is the live dashboard empty?"
nobind "Ship the beta build today"
nobind "Ridge line chart for the quarterly report"
nobind "set up an hq demo for tomorrow"
nobind "ok let's go"
nobind "Hq-demo-3 is flaky"
nobind "ask for team input on this"
nobind "check in live mode"
nobind "work on beta features"
nobind "what is the ridge regression formula"
nobind "the company beta-tested it"
nobind "build the next thing"
nobind "fix the globex"
nobind "globex corporation is down"
# Second review: paths, routes, mentions, errors, traces, domains, non-ASCII.
nobind "fix the /live route in the app"
nobind "the /team page is broken"
nobind "go to /ridge"
nobind "ping @team about it"
nobind "thanks @beta"
nobind "fix /indigo/api route"
nobind "cd /indigo"
nobind "email from @indigo.com"
nobind "@live"
nobind "@team check deploys"
nobind "the team company"
nobind "company team"
nobind "the beta company"
nobind "a live company"
nobind "company live demo"
nobind "company live: what is deployed"
nobind "How do I get a refund for indigo?"
nobind "Error: boom in indigo"
nobind "at indigo (file.js:1:2)"
nobind "at indigo.handler (/var/task/x.js:3)"
nobind "for indigo.com"
nobind "in indigo.com"
nobind "for liverecover/foo"
nobind "for indigoé"
nobind "@indigoé"
nobind "check /vyg-dev deploys"
nobind "about indigo"
nobind "copy the report from liverecover for indigo"
nobind "about indigo vs liverecover"
nobind "for indigo and liverecover"
nobind "paint the wall in indigo"
nobind "Write a poem in indigo"
nobind "an essay on indigo"
nobind "the movie on indigo"
nobind "Is this color in indigo or violet"
nobind "in globex please look at billing"
nobind "on liverecover fix login"
nobind "in vyg-dev fix login"
nobind "work on liverecover"
nobind "Compare this for indigo vs vyg"
nobind "for indigo and acme"
nobind "for indigo team"
nobind "for indigo live"
nobind "for indigo ok"
nobind "for indigo/liverecover"
nobind "for liverecover, and also indigo"
pass "ordinary-word slugs, bare names, paths, mentions, errors, traces, domains, non-ASCII and two-company prompts do not bind"

# 11. Explicit cues still bind.
bind_to() { # <expected-slug> <prompt>
  n10=$((n10 + 1)); local sid="s11-$n10"
  new_session "$sid" acme
  transcript "$sid" 1
  run_router "$sid" "$2" >/dev/null
  [ "$(meta_get "$sid" company_slug)" = "$1" ] && [ "$(meta_get "$sid" company_source)" = prompt_mention ] \
    || fail "case 11: expected $1, got $(meta_get "$sid" company_slug)/$(meta_get "$sid" company_source): $2"
}
bind_to liverecover "work for liverecover"
bind_to liverecover "Work for LiveRecover"
bind_to indigo "for indigo: fix the report"
bind_to vyg-dev "@vyg-dev check deploys"
bind_to globex "for globex please look at billing"
bind_to liverecover "for liverecover fix login"
bind_to hq-demo-3 "Set up the HQ Demo company"
bind_to indigo "@indigo check deploys"
bind_to indigo "for indigo, fix the report"
bind_to liverecover "the liverecover company needs a new report"
bind_to liverecover "$(printf 'work for liverecover\n```\nfor globex\n```')"
pass "slug or name with an explicit cue binds; common-word companies never bind"

# 7c. Multi-company lock set in meta.yaml, TOCTOU re-check under the lock, bounded lock wait.
new_session s7i acme
grep -v '^company_slugs:' "$TMP/workspace/sessions/s7i/meta.yaml" > "$TMP/s7i.meta" || true
printf 'company_slugs: acme,initech\n' >> "$TMP/s7i.meta"
cp "$TMP/s7i.meta" "$TMP/workspace/sessions/s7i/meta.yaml"
transcript s7i 1
run_router s7i "work for globex" >/dev/null
[ "$(meta_get s7i company_slug)" = acme ] && [ "$(meta_get s7i company_source)" = device_default ] \
  || fail "case 7c: meta.yaml multi-company set was replaced"
new_session s7j acme
HQ_SESSION_COMPANY_SOURCE=explicit HS s7j set company_slug acme >/dev/null
RC=0; HQ_SESSION_REQUIRE_SOURCE=device_default HQ_SESSION_COMPANY_SOURCE=prompt_mention HS s7j set company_slug globex >/dev/null 2>&1 || RC=$?
[ "$RC" = 3 ] && [ "$(meta_get s7j company_slug)" = acme ] || fail "case 7c: set did not re-check company_source under the lock (rc=$RC)"
[ ! -d "$TMP/workspace/sessions/s7j/.company-lock-set.lock" ] || fail "case 7c: lock left behind after skipped bind"
new_session s7k acme; transcript s7k 1
mkdir "$TMP/workspace/sessions/s7k/.company-lock-set.lock"; printf '%s\n' "$$" > "$TMP/workspace/sessions/s7k/.company-lock-set.lock/pid"
T0="$(date +%s)"
run_router s7k "work for globex" >/dev/null
T1="$(date +%s)"
rm -rf "$TMP/workspace/sessions/s7k/.company-lock-set.lock"
[ "$(meta_get s7k company_slug)" = acme ] || fail "case 7c: bound while the lock was held"
[ $((T1 - T0)) -le 3 ] || fail "case 7c: lock wait took $((T1 - T0))s, expected the router to fail open within ~2.5s"
pass "meta.yaml multi-company set, source change under the lock and a held lock all leave the binding alone (bounded wait)"

# 8. hq-session.sh company_source bookkeeping.
new_session s8 acme
HS s8 set company_slug globex >/dev/null
[ "$(meta_get s8 company_source)" = explicit ] || fail "case 8: explicit bind left company_source=$(meta_get s8 company_source)"
[ "$(grep -c '^company_source:' "$TMP/workspace/sessions/s8/meta.yaml")" = 1 ] || fail "case 8: duplicate company_source lines"
HS s8 set company_slug "" >/dev/null
[ -z "$(meta_get s8 company_source)" ] || fail "case 8: unbind left company_source"
pass "explicit bind stamps company_source; unbind drops it"

# 9. The first-turn title hint names the company bound from the first message.
cp "$ROOT/.claude/hooks/session-title.sh" "$TMP/.claude/hooks/"
mkdir -p "$TMP/.claude/state"
title_hint() { # <sid> -> the additionalContext the model gets on the first turn
  : > "$TMP/.claude/state/auto-session-project-$1"   # no project: skip the 2s marker wait
  jq -cn --arg s "$1" '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:"hello"}' \
    | bash "$TMP/.claude/hooks/session-title.sh" | jq -r '.hookSpecificOutput.additionalContext // ""'
}
new_session s9 acme
transcript s9 1
run_router s9 "This session is for Globex Corporation" >/dev/null
HINT="$(title_hint s9)"
case "$HINT" in *'Hook-resolved hint: "company globex '*) ;; *) fail "case 9: title hint does not resolve the bound company: $HINT" ;; esac
new_session s9b acme
HINT="$(title_hint s9b)"
case "$HINT" in *"none resolved"*) ;; *) fail "case 9: title hint guessed a company from the device default: $HINT" ;; esac
pass "title hint resolves a prompt_mention company and does not guess from other sources"

# 12. A scheduled-task run that SessionStart left unbound. Its first line is the
# <scheduled-task ...> wrapper and nobody is there to bind a company, so the
# scope guard refused its first command under companies/<co>/. It now binds
# from the run's cwd, companies/<slug> paths in the task text, or a cue in the
# task's first line, when all of them name one company.
unbound_session() { # <sid>
  mkdir -p "$TMP/workspace/sessions/$1"
  printf 'session_id: %s\nsenior: user\n' "$1" > "$TMP/workspace/sessions/$1/meta.yaml"
}
sched_prompt() { # <body>
  printf '<scheduled-task name="daily-check" file="/home/u/.claude/scheduled-tasks/daily-check/SKILL.md">\n%s\n</scheduled-task>' "$1"
}
run_router_cwd() { # <sid> <prompt> <cwd>
  jq -cn --arg s "$1" --arg p "$2" --arg t "$TMP/transcripts/$1.jsonl" --arg c "$3" \
    '{hook_event_name:"UserPromptSubmit",session_id:$s,transcript_path:$t,prompt:$p,cwd:$c}' | bash "$ROUTER"
}
unbound_session s12a; transcript s12a 1
OUT="$(run_router_cwd s12a "$(sched_prompt "Run the daily exceptions report.
cd $TMP/companies/globex/projects/shop && npm run report")" "$TMP")"
[ "$(meta_get s12a company_slug)" = globex ] && [ "$(meta_get s12a company_source)" = scheduled_task ] \
  || fail "case 12: task path did not bind ($(meta_get s12a company_slug)/$(meta_get s12a company_source))"
[ "$(cap_slugs s12a)" = globex ] || fail "case 12: scope capability is '$(cap_slugs s12a)', expected globex"
case "$(printf '%s' "$OUT" | ctx_of)" in *"bound this scheduled-task session to company globex"*) ;; *) fail "case 12: no scheduled-task bind notice" ;; esac
printf '%s' "$OUT" | jq -e . >/dev/null || fail "case 12: output is not valid JSON"
mkdir -p "$TMP/companies/initech/projects/x"
unbound_session s12b; transcript s12b 1
run_router_cwd s12b "$(sched_prompt "Run the daily exceptions report.")" "$TMP/companies/initech/projects/x" >/dev/null
[ "$(meta_get s12b company_slug)" = initech ] && [ "$(meta_get s12b company_source)" = scheduled_task ] \
  || fail "case 12: cwd under companies/initech did not bind ($(meta_get s12b company_slug))"
unbound_session s12c; transcript s12c 1
run_router_cwd s12c "$(sched_prompt "Daily report for globex")" "$TMP" >/dev/null
[ "$(meta_get s12c company_slug)" = globex ] || fail "case 12: first-line cue in the task did not bind"
unbound_session s12d; transcript s12d 1
run_router_cwd s12d "$(sched_prompt "Run companies/globex/x then companies/initech/y")" "$TMP" >/dev/null
[ -z "$(meta_get s12d company_slug)" ] || fail "case 12: two companies in the task text bound $(meta_get s12d company_slug)"
unbound_session s12e; transcript s12e 1
run_router_cwd s12e "$(sched_prompt "Run companies/globex/x")" "$TMP/companies/initech/projects/x" >/dev/null
[ -z "$(meta_get s12e company_slug)" ] || fail "case 12: cwd and task text disagree but bound $(meta_get s12e company_slug)"
unbound_session s12f; transcript s12f 1
run_router_cwd s12f "$(sched_prompt "Check the inbox and summarize it.")" "$TMP" >/dev/null
[ -z "$(meta_get s12f company_slug)" ] || fail "case 12: no evidence but bound $(meta_get s12f company_slug)"
unbound_session s12g; transcript s12g 1
run_router_cwd s12g "$(sched_prompt "Run companies/nosuchco/x")" "$TMP" >/dev/null
[ -z "$(meta_get s12g company_slug)" ] || fail "case 12: unknown company dir bound $(meta_get s12g company_slug)"
# An ordinary (non-scheduled) first prompt still never binds an unbound session.
unbound_session s12h; transcript s12h 1
run_router_cwd s12h "work for globex in companies/globex/x" "$TMP/companies/globex" >/dev/null
[ -z "$(meta_get s12h company_slug)" ] || fail "case 12: ordinary prompt bound an unbound session"
# A device default is replaced by the task's company; a strong bind is not.
new_session s12i acme; transcript s12i 1
run_router_cwd s12i "$(sched_prompt "cd companies/globex && npm test")" "$TMP" >/dev/null
[ "$(meta_get s12i company_slug)" = globex ] && [ "$(meta_get s12i company_source)" = scheduled_task ] \
  || fail "case 12: device default not replaced by the task company ($(meta_get s12i company_slug))"
new_session s12j acme explicit; transcript s12j 1
run_router_cwd s12j "$(sched_prompt "cd companies/globex && npm test")" "$TMP" >/dev/null
[ "$(meta_get s12j company_slug)" = acme ] || fail "case 12: explicit bind replaced by a scheduled task"
# A second prompt in a scheduled session does not bind.
unbound_session s12k; transcript s12k 2
run_router_cwd s12k "$(sched_prompt "cd companies/globex && npm test")" "$TMP" >/dev/null
[ -z "$(meta_get s12k company_slug)" ] || fail "case 12: second prompt bound a scheduled session"
# REQUIRE_SOURCE=none is re-checked under the lock: a session bound meanwhile is kept.
new_session s12l acme explicit
RC=0; HQ_SESSION_REQUIRE_SOURCE=none HQ_SESSION_COMPANY_SOURCE=scheduled_task HS s12l set company_slug globex >/dev/null 2>&1 || RC=$?
[ "$RC" = 3 ] && [ "$(meta_get s12l company_slug)" = acme ] || fail "case 12: REQUIRE_SOURCE=none bound over a bound session (rc=$RC)"
unbound_session s12m
RC=0; HQ_SESSION_REQUIRE_SOURCE=none HQ_SESSION_COMPANY_SOURCE=scheduled_task HS s12m set company_slug globex >/dev/null 2>&1 || RC=$?
[ "$RC" = 0 ] && [ "$(meta_get s12m company_slug)" = globex ] || fail "case 12: REQUIRE_SOURCE=none refused an unbound session (rc=$RC)"
pass "an unbound scheduled-task run binds the one company its cwd or task text names; doubt binds nothing"

echo "prompt-company-first-message-bind: all cases passed"
