#!/usr/bin/env bash
# startwork-prefetch.test.sh — `/startwork <exact slug>` binds that company and
# prints the <startwork-prefetch> block from the UserPromptSubmit intent hook;
# typos, case changes, aliases, repo names, project names, free text, bounded
# actions, chained skills and second companies print nothing and bind nothing;
# the last-thread line only names a thread of the same company; and the hook
# stays inside its runtime budget.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
fail() { echo "FAIL: $*" >&2; exit 1; }

# This test runs inside a real session. Clear the host session ids so nothing
# can fall through to the caller's session, and keep hq-session in-tree.
unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID HQ_HOOK_SESSION_ID HQ_DISABLED_HOOKS HQ_INTENT_HINT HQ_STARTWORK_PREFETCH CLAUDE_PROJECT_DIR || true
export HQ_HQ_SESSION_NO_CLI=1 HQ_WORK_MESH_RECONCILE_STUB=1 TMPDIR="$TMP" HOME="$TMP/home"
mkdir -p "$HOME"

mkdir -p "$FIX/core/scripts/lib" "$FIX/core/settings" "$FIX/core/workers" "$FIX/.claude/hooks" "$FIX/.claude/skills/run-project" \
  "$FIX/companies/acme/policies" "$FIX/companies/acme/projects/alpha" "$FIX/companies/acme-labs" "$FIX/companies/other" \
  "$FIX/workspace/threads" "$FIX/workspace/sessions"
for f in startwork-prefetch.sh startwork-context.sh hq-session.sh work-mesh-live-bind-trusted.sh hook-lib.sh; do
  cp "$SRC/core/scripts/$f" "$FIX/core/scripts/$f"
done
cp "$SRC/core/scripts/lib/"*.sh "$FIX/core/scripts/lib/"
cp "$SRC/.claude/hooks/intent-hint.sh" "$FIX/.claude/hooks/intent-hint.sh"
touch "$FIX/.claude/skills/run-project/SKILL.md" "$FIX/core/settings/intent-index.yaml"
printf 'workers: []\n' > "$FIX/core/workers/registry.yaml"
cat > "$FIX/companies/manifest.yaml" <<'YAML'
companies:
  acme:
    name: Acme Corp
    path: companies/acme
    repos:
    - repos/private/acme-site
    knowledge: companies/acme/knowledge/
  acme-labs:
    name: Acme Labs
    path: companies/acme-labs
  other:
    name: Other
    path: companies/other
YAML
cat > "$FIX/companies/acme/policies/acme-rule.md" <<'MD'
---
id: acme-rule
enforcement: hard
---
## Rule
Acme work stays in Acme services.
MD
printf '{"name":"alpha","userStories":[{"id":"A1"}]}\n' > "$FIX/companies/acme/projects/alpha/prd.json"
printf '{"thread_id":"T-acme-1","conversation_summary":"Shipped the acme pricing page.","metadata":{"company":["acme"]},"cwd":"/x"}\n' > "$FIX/workspace/threads/T-acme-1.json"
printf '{"thread_id":"T-other-1","conversation_summary":"Other company secret plan.","metadata":{"company":"other"},"cwd":"/x"}\n' > "$FIX/workspace/threads/T-other-1.json"
handoff_to() { printf '{"last_thread":"%s","thread_path":"workspace/threads/%s.json"}\n' "$1" "$1" > "$FIX/workspace/threads/handoff.json"; }
handoff_to T-acme-1

hook() { # prompt sid -> hook stdout
  printf '{"session_id":%s,"prompt":%s}' "$(printf '%s' "$2" | jq -Rs .)" "$(printf '%s' "$1" | jq -Rs .)" \
    | HQ_ROOT="$FIX" bash "$FIX/.claude/hooks/intent-hint.sh"
}
bound() { HQ_ROOT="$FIX" bash "$FIX/core/scripts/hq-session.sh" --session-id "$1" get company_slug 2>/dev/null || true; }

# 1. exact slug: prefetch emitted, session bound, policy digest and last thread.
out="$(hook "/startwork acme" s-exact)"
grep -q '^<startwork-prefetch company="acme">$' <<<"$out" || fail "exact slug: no prefetch block: $out"
grep -q '^<startwork-context company="acme">' <<<"$out" || fail "exact slug: capability block missing"
grep -q '^Remaining args: none$' <<<"$out" || fail "exact slug: remaining args line wrong"
grep -q '^Last thread: T-acme-1 — Shipped the acme pricing page.$' <<<"$out" || fail "exact slug: last thread line wrong: $(grep '^Last thread' <<<"$out")"
grep -q 'acme-rule' <<<"$out" || fail "exact slug: hard-policy digest missing"
[ "$(bound s-exact)" = "acme" ] || fail "exact slug: session not bound (got '$(bound s-exact)')"
grep -q '<intent-hints>' <<<"$out" && fail "bare /startwork must not add intent hints"
echo "ok 1 exact slug binds and prefetches"

# 2. a thread from another company is never named.
handoff_to T-other-1
out="$(hook "/startwork acme" s-otherthread)"
grep -q '^Last thread: none for acme$' <<<"$out" || fail "other-company thread leaked: $(grep '^Last thread' <<<"$out")"
grep -q 'secret plan' <<<"$out" && fail "other-company summary leaked"
handoff_to T-acme-1
echo "ok 2 last thread filtered to the bound company"

# 3. trailing whitespace / newline and extra focus text still count.
out="$(hook $'/startwork acme\n' s-nl)"
grep -q 'company="acme"' <<<"$out" || fail "trailing newline should still prefetch"
out="$(hook "/startwork acme pricing page polish" s-focus)"
grep -q '^Remaining args: pricing page polish$' <<<"$out" || fail "focus text should prefetch with remaining args"
[ "$(bound s-focus)" = "acme" ] || fail "focus text: session not bound"
echo "ok 3 newline and focus text"

# 4. no exact slug -> nothing printed, nothing bound.
i=0
for p in "/startwork acmee" "/startwork Acme" "/startwork ACME" "/startwork acm" "/startwork acme-site" \
         "/startwork alpha" "/startwork Acme Corp" "/startwork fix the pricing page" "/startwork" "/startwork " \
         "/startworkacme" "startwork acme" "/startwork-x acme" "/startwork ../acme" "/startwork acme*" "please /startwork acme"; do
  i=$((i + 1)); sid="s-neg-$i"
  out="$(hook "$p" "$sid")"
  grep -q '<startwork-prefetch' <<<"$out" && fail "no prefetch expected for '$p'"
  [ -z "$(bound "$sid")" ] || fail "'$p' must not bind (got '$(bound "$sid")')"
done
echo "ok 4 typo, case, alias, repo, project, free text: no prefetch"

# 5. bounded actions, chained skills and a second company -> no prefetch.
i=0
for p in "/startwork open my DM on acme" "/startwork acme open my DM" "/startwork acme check inbox" \
         "/startwork acme meeting notes from monday" "/startwork acme what are my action items" \
         "/startwork acme signals" "/startwork acme search for pricing" "/startwork acme where is the deck" \
         "/startwork acme goals" "/startwork acme who am i" "/startwork acme /deep-plan new checkout" \
         "/startwork acme deep-plan new checkout" "/startwork acme prd checkout" "/startwork acme run-project alpha" \
         "/startwork acme other" "/startwork acme compare with acme-labs"; do
  i=$((i + 1)); sid="s-bounded-$i"
  out="$(hook "$p" "$sid")"
  grep -q '<startwork-prefetch' <<<"$out" && fail "no prefetch expected for '$p'"
  [ -z "$(bound "$sid")" ] || fail "'$p' must not bind (got '$(bound "$sid")')"
done
echo "ok 5 bounded action, chained skill, second company: no prefetch"

# 6. no or invalid session id -> nothing (a bind could hit another session).
for sid in "" "../x" "a b"; do
  out="$(hook "/startwork acme" "$sid")"
  grep -q '<startwork-prefetch' <<<"$out" && fail "invalid session id '$sid' must not prefetch"
done
for d in "$FIX/workspace/sessions"/*; do
  case "${d##*/}" in s-*|'*') ;; *) fail "invalid session id wrote a session dir: ${d##*/}" ;; esac
done
echo "ok 6 invalid session id"

# 7. disable switches and a symlinked company dir.
out="$(printf '{"session_id":"s-off","prompt":"/startwork acme"}' | HQ_ROOT="$FIX" HQ_STARTWORK_PREFETCH=0 bash "$FIX/.claude/hooks/intent-hint.sh")"
[ -z "$out" ] && [ -z "$(bound s-off)" ] || fail "HQ_STARTWORK_PREFETCH=0 must disable"
out="$(printf '{"session_id":"s-off2","prompt":"/startwork acme"}' | HQ_ROOT="$FIX" HQ_DISABLED_HOOKS=startwork-prefetch bash "$FIX/.claude/hooks/intent-hint.sh")"
[ -z "$out" ] && [ -z "$(bound s-off2)" ] || fail "HQ_DISABLED_HOOKS=startwork-prefetch must disable"
rm -rf "$FIX/companies/other"; ln -s "$FIX/companies/acme" "$FIX/companies/other"
out="$(hook "/startwork other" s-link)"
grep -q '<startwork-prefetch' <<<"$out" && fail "symlinked company dir must not prefetch"
rm "$FIX/companies/other"; mkdir "$FIX/companies/other"
echo "ok 7 disable switches and symlinked company"

# 7b. a session already bound to another company is never switched by the hook;
# re-running for the same company still works.
hook "/startwork other" s-locked >/dev/null
[ "$(bound s-locked)" = "other" ] || fail "setup: s-locked should be bound to other"
out="$(hook "/startwork acme" s-locked)"
grep -q '<startwork-prefetch' <<<"$out" && fail "a session bound to another company must not prefetch"
[ "$(bound s-locked)" = "other" ] || fail "the hook switched a bound session to $(bound s-locked)"
out="$(hook "/startwork other" s-locked)"
grep -q '<startwork-prefetch company="other">' <<<"$out" || fail "same-company re-run should still prefetch"
echo "ok 7b bound session is not switched"

# 8. runtime budget for the whole hook on a match. Best of three fresh
# sessions, so one scheduler stall on a busy machine does not fail the run.
budget_ms="${HQ_STARTWORK_PREFETCH_BUDGET_MS:-1500}"
best=""
for n in 1 2 3; do
  start="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
  hook "/startwork acme" "s-timed-$n" >/dev/null
  end="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
  ms=$((end - start))
  if [ -z "$best" ] || [ "$ms" -lt "$best" ]; then best="$ms"; fi
done
[ "$best" -lt "$budget_ms" ] || fail "prefetch hook took $best ms at best of 3 (budget ${budget_ms} ms)"
echo "ok 8 prefetch hook ran in $best ms, best of 3 (budget ${budget_ms} ms)"

echo "PASS startwork-prefetch"
