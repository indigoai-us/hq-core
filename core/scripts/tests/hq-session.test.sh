#!/usr/bin/env bash
# hq-core: public
# Regression tests for core/scripts/hq-session.sh
#
# Guards two bugs:
#
# 1. REPO_ROOT depth: the script lives in core/scripts/, so it must walk up TWO
#    levels ("../..") to reach the HQ root. A regression to one level ("..")
#    makes SESSIONS_DIR resolve to <root>/core/workspace/sessions, so .current
#    is never found and `set` dies with "no current session".
#
# 2. Wrong-session binds: "current session" must come from this process's own
#    session environment, with workspace/sessions/.current only as a fallback.
#    .current is a single global pointer rewritten by every hook event, so with
#    concurrent sessions it can name a different session — and the scope guard
#    reads the session id from the hook payload, not from .current. Resolving
#    through .current made `hq-session.sh set company_slug <co>` report success
#    while writing to a foreign session's meta.yaml, leaving the calling session
#    unbound and still blocked.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hq-session.sh"
LIB_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# This test runs inside a real session, which exports a session id. Clear the
# whole precedence list so the .current-fallback cases below exercise the
# fallback rather than the ambient session.
unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
      CODEX_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID || true
# Pin the root resolution to the fixture's self-relative walk (the depth guard
# below), independent of any injected root the ambient environment carries.
unset HQ_ROOT CLAUDE_PROJECT_DIR || true
# These tests target the in-tree implementation, not the CLI delegation path, so
# force the fallback body rather than probing the (seconds-slow) installed CLI.
export HQ_HQ_SESSION_NO_CLI=1

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "  PASS: $*"
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

wait_for_workmesh_count() {
  local expected="$1" count=0 attempt
  for attempt in {1..40}; do
    : "$attempt"
    count="$(wc -l <"$TMP/workmesh-register.log" 2>/dev/null | tr -d ' ' || true)"
    [ "$count" = "$expected" ] && return 0
    sleep 0.05
  done
  fail "Work Mesh registration count: expected '$expected', got '$count'"
}

# Build a minimal HQ-shaped layout so the script's BASH_SOURCE-relative
# REPO_ROOT computation has something real to resolve against.
mkdir -p "$TMP/core/scripts/lib" "$TMP/.codex/hooks" "$TMP/workspace/sessions" "$TMP/companies/Acme" "$TMP/companies/Personal" "$TMP/companies/indigo" "$TMP/companies/beta" "$TMP/companies/gamma"
mkdir -p "$TMP/home/.hq"
ln -s Acme "$TMP/companies/acme"
cp "$SRC" "$TMP/core/scripts/hq-session.sh"
cp "$LIB_SRC/session-scope-capability.sh" "$TMP/core/scripts/lib/"
cp "$LIB_SRC/session-id.sh" "$TMP/core/scripts/lib/"
cp "$(dirname "$LIB_SRC")/hqd-hook-flag-cache-lib.sh" "$TMP/core/scripts/"
cp "$(dirname "$LIB_SRC")/../../.codex/hooks/codex-explicit-path-flag.cjs" "$TMP/.codex/hooks/"
chmod +x "$TMP/core/scripts/hq-session.sh"
HS="$TMP/core/scripts/hq-session.sh"
export HOME="$TMP/home"

# 1. No .current yet -> `current` prints empty, exits 0.
out="$("$HS" current)"
assert_eq "$out" "" "current with no session"

# 2. Seed a current session.
printf 'sess-1\n' > "$TMP/workspace/sessions/.current"
mkdir -p "$TMP/workspace/sessions/sess-1"

assert_eq "$("$HS" current)" "sess-1" "current id"

# 3. `path` must resolve under <root>/workspace/sessions, NOT <root>/core/...
#    This is the direct guard against the REPO_ROOT depth regression.
path_out="$("$HS" path)"
assert_eq "$path_out" "$TMP/workspace/sessions/sess-1/meta.yaml" "meta path"
case "$path_out" in
  "$TMP/core/"*) fail "REPO_ROOT resolved one level too shallow: $path_out" ;;
esac

# 4. set/get roundtrip (would error 'no current session' under the bug).
"$HS" set company acme
assert_eq "$("$HS" get company)" "acme" "get after set"

# 5. set replaces in place rather than duplicating.
"$HS" set company beta
assert_eq "$("$HS" get company)" "beta" "get after overwrite"
count="$(grep -c '^company:' "$path_out")"
assert_eq "$count" "1" "company key not duplicated"

# 6. set company_slug mints scope-capability.json for the current session.
"$HS" set company_slug indigo
cap="$TMP/workspace/sessions/sess-1/scope-capability.json"
[ -f "$cap" ] || fail "scope-capability.json not minted"
assert_eq "$(jq -r '.company_slug' "$cap")" "indigo" "capability company_slug"
assert_eq "$(jq -r '.session_id' "$cap")" "sess-1" "capability session_id"

# A common exact-name company bind must short-circuit before case folding.
TR_REAL="$(command -v tr)"
mkdir -p "$TMP/tr-count-bin"
cat > "$TMP/tr-count-bin/tr" <<'TR'
#!/bin/sh
printf 'called\n' >> "$TR_CALLS_FILE"
exec "$TR_REAL" "$@"
TR
chmod +x "$TMP/tr-count-bin/tr"
: > "$TMP/tr-calls"
TR_CALLS_FILE="$TMP/tr-calls" TR_REAL="$TR_REAL" PATH="$TMP/tr-count-bin:$PATH" \
  "$HS" --session-id sess-exact-tr set company_slug Acme >/dev/null
[ ! -s "$TMP/tr-calls" ] || fail "exact hq-session bind called tr"
pass "exact hq-session bind does not invoke case folding"

# Only an explicit cached server false keeps the legacy singleton behavior.
# The previous missing-cache assertion relied on the old default-off fallback;
# default-on now requires the test to seed the kill-switch value it intends.
flag_now="$(cut -d. -f1 /proc/uptime)"
printf 'false %s\n' "$flag_now" >"$HOME/.hq/hook-flag.multi-company-session-lock.indigo"
"$HS" --session-id sess-lock-off set company_slug indigo >/dev/null
rc=0
"$HS" --session-id sess-lock-off add company beta >"$TMP/add-off.out" 2>"$TMP/add-off.err" || rc=$?
[ "$rc" -ne 0 ] || fail "add company should be refused with flag off"
grep -q 'multi-company-session-lock is off' "$TMP/add-off.err" || fail "flag-off refusal did not explain the disabled flag"
assert_eq "$("$HS" --session-id sess-lock-off get company_slugs)" "indigo" "flag-off lock remains primary only"
pass "flag off refuses add company and retains singleton lock"

mkdir -p "$TMP/multi-bin"
cat >"$TMP/multi-bin/node" <<'NODE'
#!/bin/sh
printf 'true\n'
NODE
cat >"$TMP/multi-bin/nohup" <<'NOHUP'
#!/bin/sh
printf '%s\n' "$*" >>"$NOHUP_CALLS"
NOHUP
chmod +x "$TMP/multi-bin/node"
chmod +x "$TMP/multi-bin/nohup"
rm -f "$HOME/.hq/hook-flag.multi-company-session-lock.indigo"
export NOHUP_CALLS="$TMP/workmesh-register.log"
mkdir -p "$TMP/core/hooks/SessionStart"
cat >"$TMP/core/hooks/SessionStart/35-work-mesh-session-start.sh" <<HOOK
#!/bin/sh
cat >>"$TMP/workmesh-register.log"
HOOK
chmod +x "$TMP/core/hooks/SessionStart/35-work-mesh-session-start.sh"
"$HS" --session-id sess-multi set company_slug indigo >/dev/null
PATH="$TMP/multi-bin:$PATH" "$HS" --session-id sess-multi add company beta >/dev/null
assert_eq "$("$HS" --session-id sess-multi get company_slugs)" "indigo,beta" "add appends company"
assert_eq "$(jq -c '.company_slugs' "$TMP/workspace/sessions/sess-multi/scope-capability.json")" '["indigo","beta"]' "add mints ordered capability set"
sed 's/^company_slugs: indigo,beta$/company_slugs: indigo,ghost/' \
  "$TMP/workspace/sessions/sess-multi/meta.yaml" > "$TMP/sess-multi-stale-meta.yaml"
mv "$TMP/sess-multi-stale-meta.yaml" "$TMP/workspace/sessions/sess-multi/meta.yaml"
assert_eq "$("$HS" --session-id sess-multi get company_slugs)" "indigo,beta" "capability remains authoritative over stale metadata"
wait_for_workmesh_count 1
: >"$TMP/workmesh-register.log"
"$HS" --session-id sess-multi set project old-project >/dev/null
"$HS" --session-id sess-multi set task old-task >/dev/null
PATH="$TMP/multi-bin:$PATH" "$HS" --session-id sess-multi remove company indigo
assert_eq "$("$HS" --session-id sess-multi get company_slug)" "beta" "removing primary promotes next company"
assert_eq "$("$HS" --session-id sess-multi get company_slugs)" "beta" "remove updates lock set"
assert_eq "$(grep '^company_slug:' "$TMP/workspace/sessions/sess-multi/meta.yaml" | tail -n 1 | awk '{print $2}')" "beta" "remove promotes primary in meta.yaml"
assert_eq "$(jq -r '.company_slug' "$TMP/workspace/sessions/sess-multi/scope-capability.json")" "beta" "remove promotes primary in scope capability"
assert_eq "$(jq -c '.company_slugs' "$TMP/workspace/sessions/sess-multi/scope-capability.json")" '["beta"]' "remove writes promoted lock set to capability"
assert_eq "$("$HS" --session-id sess-multi get project)" "" "removing primary clears old project"
assert_eq "$("$HS" --session-id sess-multi get task)" "" "removing primary clears old task"
wait_for_workmesh_count 1
rc=0
PATH="$TMP/multi-bin:$PATH" "$HS" --session-id sess-multi remove company beta >"$TMP/remove-last.out" 2>"$TMP/remove-last.err" || rc=$?
[ "$rc" -ne 0 ] || fail "removing the last company should be refused"
pass "add and remove maintain ordered lock and protect last entry"

# Unbinding removes the capability. The scope authorizer reads the capability
# before meta.yaml, so an unbind that only blanked meta.yaml left the old
# company enforced while `get company_slug` reported the session unbound.
"$HS" --session-id sess-unbind set company_slug indigo >/dev/null
unbind_cap="$TMP/workspace/sessions/sess-unbind/scope-capability.json"
[ -f "$unbind_cap" ] || fail "bind before unbind did not mint a capability"
"$HS" --session-id sess-unbind set company_slug "" >/dev/null
[ ! -e "$unbind_cap" ] || fail "unbind left scope-capability.json behind: $(cat "$unbind_cap")"
assert_eq "$("$HS" --session-id sess-unbind get company_slug)" "" "meta unbound after unbind"
pass "unbind removes the scope capability"

# Setting the primary company again resets the lock set in the capability as
# well as in meta.yaml. Before, the capability was rewritten only when the
# primary changed, so it kept enforcing companies added with `add company`.
"$HS" --session-id sess-reset set company_slug indigo >/dev/null
PATH="$TMP/multi-bin:$PATH" "$HS" --session-id sess-reset add company beta >/dev/null
assert_eq "$(jq -c '.company_slugs' "$TMP/workspace/sessions/sess-reset/scope-capability.json")" '["indigo","beta"]' "add widened the capability before reset"
PATH="$TMP/multi-bin:$PATH" "$HS" --session-id sess-reset set company_slug indigo >/dev/null
assert_eq "$(jq -c '.company_slugs' "$TMP/workspace/sessions/sess-reset/scope-capability.json")" '["indigo"]' "same-company set resets the capability lock set"
assert_eq "$(PATH="$TMP/multi-bin:$PATH" "$HS" --session-id sess-reset get company_slugs)" "indigo" "same-company set resets the reported lock set"
pass "same-company set resets a widened capability"

# A capability that drifted from meta.yaml is repaired by setting the same
# company again rather than skipped because meta.yaml already matched.
"$HS" --session-id sess-drift set company_slug indigo >/dev/null
drift_cap="$TMP/workspace/sessions/sess-drift/scope-capability.json"
jq '.company_slug = "stale" | .company_slugs = ["stale"]' "$drift_cap" > "$drift_cap.tmp" && mv "$drift_cap.tmp" "$drift_cap"
"$HS" --session-id sess-drift set company_slug indigo >/dev/null
assert_eq "$(jq -r '.company_slug' "$drift_cap")" "indigo" "same-company set repairs a drifted capability"
pass "same-company set repairs a drifted capability"

# Re-minting the main thread on every set and clearing it on unbind leave a
# subagent's pinned tuple alone (#1245: an existing tuple is never overwritten),
# and after an unbind a new subagent has nothing to inherit.
"$HS" --session-id sess-pin set company_slug indigo >/dev/null
( . "$TMP/core/scripts/lib/session-scope-capability.sh" && session_scope_inherit_parent "$TMP" sess-pin agent-P ) \
  || fail "subagent did not inherit the bound parent"
pin_cap="$TMP/workspace/sessions/sess-pin/agents/agent-P/scope-capability.json"
pin_before="$(cat "$pin_cap")"
PATH="$TMP/multi-bin:$PATH" "$HS" --session-id sess-pin add company beta >/dev/null
PATH="$TMP/multi-bin:$PATH" "$HS" --session-id sess-pin set company_slug indigo >/dev/null
assert_eq "$(cat "$pin_cap")" "$pin_before" "same-company re-mint leaves a pinned subagent tuple untouched"
"$HS" --session-id sess-pin set company_slug "" >/dev/null
[ ! -e "$TMP/workspace/sessions/sess-pin/scope-capability.json" ] || fail "unbind left the main-thread capability"
assert_eq "$(cat "$pin_cap")" "$pin_before" "unbind leaves a pinned subagent tuple untouched"
if ( . "$TMP/core/scripts/lib/session-scope-capability.sh" && session_scope_inherit_parent "$TMP" sess-pin agent-Q ); then
  fail "a subagent inherited from an unbound parent"
fi
[ ! -e "$TMP/workspace/sessions/sess-pin/agents/agent-Q/scope-capability.json" ] \
  || fail "unbound parent minted a subagent tuple"
"$HS" --session-id sess-pin set company_slug indigo >/dev/null
( . "$TMP/core/scripts/lib/session-scope-capability.sh" && session_scope_inherit_parent "$TMP" sess-pin agent-Q ) \
  || fail "subagent did not inherit after the parent rebound"
assert_eq "$(jq -r '.company_slug' "$TMP/workspace/sessions/sess-pin/agents/agent-Q/scope-capability.json")" "indigo" "rebound parent passes its company to a new subagent"
pass "re-mint and unbind keep subagent pins; unbound parents give nothing"

# Two concurrent additions must serialize around the same session snapshot.
"$HS" --session-id sess-concurrent set company_slug indigo >/dev/null
mkdir -p "$TMP/workspace/sessions/sess-concurrent/.company-lock-set.lock"
printf '%s\n' "$$" > "$TMP/workspace/sessions/sess-concurrent/.company-lock-set.lock/pid"
PATH="$TMP/multi-bin:$PATH" "$HS" --session-id sess-concurrent add company beta >/dev/null & blocked_add_pid=$!
sleep 0.3
kill -0 "$blocked_add_pid" 2>/dev/null || fail "company lock update did not wait for the per-session lock"
rm -rf "$TMP/workspace/sessions/sess-concurrent/.company-lock-set.lock"
wait "$blocked_add_pid"
assert_eq "$("$HS" --session-id sess-concurrent get company_slugs)" "indigo,beta" "company update waits for existing session lock"
"$HS" --session-id sess-concurrent remove company beta >/dev/null
PATH="$TMP/multi-bin:$PATH" "$HS" --session-id sess-concurrent add company beta >/dev/null & add_beta_pid=$!
PATH="$TMP/multi-bin:$PATH" "$HS" --session-id sess-concurrent add company gamma >/dev/null & add_gamma_pid=$!
wait "$add_beta_pid"
wait "$add_gamma_pid"
concurrent_meta="$("$HS" --session-id sess-concurrent get company_slugs | tr ',' '\n' | sort | paste -sd, -)"
concurrent_cap="$(jq -r '.company_slugs | sort | join(",")' "$TMP/workspace/sessions/sess-concurrent/scope-capability.json")"
assert_eq "$concurrent_meta" "beta,gamma,indigo" "concurrent adds retain both lock updates"
assert_eq "$concurrent_cap" "$concurrent_meta" "concurrent capability matches serialized metadata"
pass "per-session company lock updates serialize concurrent adds"

# A case alias must not be persisted as a company identity when only the
# differently-cased real directory exists.
rc=0
case_alias_out="$("$HS" --session-id sess-case-alias set company_slug acme 2>"$TMP/case-alias.err")" || rc=$?
[ "$rc" -eq 1 ] || fail "expected case-alias company bind to be rejected, got exit $rc"
[ -z "$case_alias_out" ] || fail "case-alias bind surfaced policy output: $case_alias_out"
[ ! -e "$TMP/workspace/sessions/sess-case-alias/scope-capability.json" ] \
  || fail "case-alias company bind minted a scope capability"
[ -z "$("$HS" --session-id sess-case-alias get company_slug)" ] \
  || fail "case-alias company bind persisted a slug"

# Older installed CLI bundles may advertise hq-session without carrying the
# exact-directory fix. The wrapper must stay on the in-tree guard unless the
# CLI help advertises the explicit capability marker.
mkdir -p "$TMP/old-cli-bin"
cat > "$TMP/old-cli-bin/hq" <<'CLI'
#!/usr/bin/env bash
if [ "${1:-}" = "core" ] && [ "${2:-}" = "--help" ]; then
  printf '%s\n' "${HQ_CLI_CAPS_TEXT:-hq-session}"
  exit 0
fi
if [ "${1:-}" = "core" ] && [ "${2:-}" = "hq-session" ]; then
  : > "$HQ_CLI_DELEGATION_MARKER"
  exit 0
fi
exit 91
CLI
chmod +x "$TMP/old-cli-bin/hq"
rc=0
env -u HQ_HQ_SESSION_NO_CLI \
  HQ_ROOT="$TMP" PATH="$TMP/old-cli-bin:$PATH" \
  HQ_CLI_CAPS_CACHE="$TMP/old-cli-caps" \
  HQ_CLI_DELEGATION_MARKER="$TMP/old-cli-called" \
  "$HS" --session-id sess-cli-case-alias set company_slug acme \
  >"$TMP/old-cli.out" 2>"$TMP/old-cli.err" || rc=$?
[ "$rc" -eq 1 ] || fail "old CLI alias path expected refusal via fallback, got exit $rc"
[ ! -e "$TMP/old-cli-called" ] || fail "old CLI without exact-directory capability was called"
pass "wrapper refuses to delegate to an old CLI that lacks the exact-directory capability"

env -u HQ_HQ_SESSION_NO_CLI \
  HQ_ROOT="$TMP" PATH="$TMP/old-cli-bin:$PATH" \
  HQ_CLI_CAPS_CACHE="$TMP/new-cli-caps" \
  HQ_CLI_CAPS_TEXT='exact-company-directory-match-v1 hq-session' \
  HQ_CLI_DELEGATION_MARKER="$TMP/new-cli-called" \
  "$HS" --session-id sess-cli-capable get company_slug >/dev/null
[ -e "$TMP/new-cli-called" ] || fail "CLI with the exact-directory capability was not used"
pass "wrapper delegates when the installed CLI advertises the exact-directory capability"

# 6a. Cloud company IDs may be opaque case-sensitive values rather than slugs.
#     The binding accepts the safe ASCII identifier and preserves it exactly.
"$HS" --session-id sess-opaque set company_slug cmp_FIXTURE >/dev/null
opaque_cap="$TMP/workspace/sessions/sess-opaque/scope-capability.json"
[ -f "$opaque_cap" ] || fail "opaque company binding did not mint scope-capability.json"
assert_eq "$(jq -r '.company_slug' "$opaque_cap")" "cmp_FIXTURE" \
  "opaque company capability preserves case-sensitive identifier"

# 6b. `personal` is a reserved no-company scope: it binds (mints the capability)
#     but must NOT surface a company hard-policy digest, even if a companies/
#     directory of that name happens to exist. A real company, by contrast, does.
mkdir -p "$TMP/companies/realco/policies" "$TMP/companies/personal/policies"
printf -- '---\nid: realco-rule\nenforcement: hard\n---\n\n## Rule\n\nDo the realco thing.\n' \
  > "$TMP/companies/realco/policies/r.md"
printf -- '---\nid: personal-rule\nenforcement: hard\n---\n\n## Rule\n\nShould never surface.\n' \
  > "$TMP/companies/personal/policies/p.md"

# Use a dedicated session so the .current (sess-1) assertions below stay valid.
real_out="$("$HS" --session-id sess-personal set company_slug realco)"
case "$real_out" in
  *"<company-policy-digest"*) : ;;
  *) fail "a real company bind must surface its hard-policy digest" ;;
esac
# The frontmatter id is deliberately different from the filename (realco-rule
# vs r.md). Each surfaced rule must identify the real file that can be opened;
# the company qmd collection indexes knowledge/, not policies/.
case "$real_out" in
  *'- [hard] **realco-rule**: Do the realco thing. Full text: `companies/realco/policies/r.md`.'*) : ;;
  *) fail "digest must identify the real policy file when id and filename differ: $real_out" ;;
esac
case "$real_out" in
  *"qmd get -c"*) fail "digest must not advertise qmd retrieval for company policies: $real_out" ;;
esac

personal_out="$("$HS" --session-id sess-personal set company_slug personal)"
case "$personal_out" in
  *"<company-policy-digest"*) fail "personal bind must not surface a company digest: $personal_out" ;;
esac
cap_personal="$TMP/workspace/sessions/sess-personal/scope-capability.json"
assert_eq "$(jq -r '.company_slug' "$cap_personal")" "personal" "personal capability slug"
assert_eq "$("$HS" --session-id sess-personal get company_slug)" "personal" "personal get roundtrip"

# 6c. The bind digest is deduped: generated digests, docs, examples, and
#     sync-conflict copies (space-named or *.conflict-*) contribute no lines.
#     A stray "r 2.md" copy previously emitted a duplicate [hard] line, which
#     is how one tenant's bind ballooned to ~298 lines.
printf -- '---\nid: realco-rule\nenforcement: hard\n---\n\n## Rule\n\nDuplicate from space-named copy.\n' \
  > "$TMP/companies/realco/policies/r 2.md"
printf -- '---\nid: digest-rule\nenforcement: hard\n---\n\n## Rule\n\nShould never surface.\n' \
  > "$TMP/companies/realco/policies/_digest.md"
printf -- '---\nid: example-rule\nenforcement: hard\n---\n\n## Rule\n\nShould never surface.\n' \
  > "$TMP/companies/realco/policies/example-policy.md"
printf -- '---\nid: conflict-rule\nenforcement: hard\n---\n\n## Rule\n\nShould never surface.\n' \
  > "$TMP/companies/realco/policies/r.md.conflict-abc123.md"
dedupe_out="$("$HS" --session-id sess-dedupe set company_slug realco)"
assert_eq "$(printf '%s\n' "$dedupe_out" | grep -c 'realco-rule')" "1" \
  "sync-conflict copy must not duplicate the policy line"
case "$dedupe_out" in
  *digest-rule*|*example-rule*|*conflict-rule*)
    fail "non-policy files leaked into the bind digest: $dedupe_out" ;;
esac

# 6d. The bind digest is budgeted, never silently truncated: the count cap and
#     the byte cap each limit the emitted lines and summarize the overflow with
#     a pointer, so withheld hard policies stay discoverable.
mkdir -p "$TMP/companies/bigco/policies"
for i in 1 2 3; do
  printf -- '---\nid: big-rule-%s\nenforcement: hard\n---\n\n## Rule\n\nRule number %s.\n' "$i" "$i" \
    > "$TMP/companies/bigco/policies/big-rule-$i.md"
done
cap_out="$(HQ_COMPANY_BIND_POLICY_CAP=2 "$HS" --session-id sess-cap set company_slug bigco)"
assert_eq "$(printf '%s\n' "$cap_out" | grep -c '^- \[hard\]')" "2" \
  "count cap must limit emitted policy lines"
case "$cap_out" in
  *"1 more hard policy not shown"*) : ;;
  *) fail "count-cap overflow must be summarized, not silent: $cap_out" ;;
esac
case "$cap_out" in
  *"qmd get -c"*) fail "count-cap overflow must not advertise qmd policy retrieval: $cap_out" ;;
esac
assert_eq "$(printf '%s\n' "$cap_out" | grep -c 'Browse `companies/bigco/policies/` for the full set')" "2" \
  "count-cap header and overflow must use the same valid retrieval guidance"
bytes_out="$(HQ_COMPANY_BIND_POLICY_BYTES=160 "$HS" --session-id sess-bytes set company_slug bigco)"
assert_eq "$(printf '%s\n' "$bytes_out" | grep -c '^- \[hard\]')" "1" \
  "byte cap must limit emitted policy lines"
case "$bytes_out" in
  *"2 more hard policies not shown"*) : ;;
  *) fail "byte-cap overflow must be summarized, not silent: $bytes_out" ;;
esac
case "$bytes_out" in
  *"qmd get -c"*) fail "byte-cap overflow must not advertise qmd policy retrieval: $bytes_out" ;;
esac
assert_eq "$(printf '%s\n' "$bytes_out" | grep -c 'Browse `companies/bigco/policies/` for the full set')" "2" \
  "byte-cap header and overflow must use the same valid retrieval guidance"

# ── Wrong-session bind regression ──────────────────────────────────────────────
# .current still says sess-1 (another session fired the most recent hook), but
# THIS process belongs to sess-2. Every read and write must follow sess-2.

# 7. The environment wins over .current for `current` and `path`.
assert_eq "$(CLAUDE_CODE_SESSION_ID=sess-2 "$HS" current)" "sess-2" \
  "env session id must beat .current"
assert_eq "$(CLAUDE_CODE_SESSION_ID=sess-2 "$HS" path)" \
  "$TMP/workspace/sessions/sess-2/meta.yaml" "env session meta path"

# 8. `set company_slug` binds THIS session, bootstrapping its record if the hook
#    has not created one yet — and leaves the .current session untouched.
CLAUDE_CODE_SESSION_ID=sess-2 "$HS" set company_slug otherco >/dev/null
cap2="$TMP/workspace/sessions/sess-2/scope-capability.json"
[ -f "$cap2" ] || fail "scope-capability.json not minted for the env session"
assert_eq "$(jq -r '.company_slug' "$cap2")" "otherco" "env session capability slug"
assert_eq "$(jq -r '.session_id' "$cap2")" "sess-2" "env session capability id"
assert_eq "$(CLAUDE_CODE_SESSION_ID=sess-2 "$HS" get company_slug)" "otherco" \
  "env session get company_slug"
assert_eq "$(grep -c '^session_id: sess-2$' "$TMP/workspace/sessions/sess-2/meta.yaml")" "1" \
  "bootstrapped meta.yaml carries its own session_id"

# The .current session must NOT have been rewritten by the sess-2 bind.
assert_eq "$("$HS" get company_slug)" "indigo" ".current session left untouched"
assert_eq "$(jq -r '.company_slug' "$cap")" "indigo" ".current capability left untouched"

# 9. Precedence: HQ_SESSION_ID outranks the host-provided id.
assert_eq "$(HQ_SESSION_ID=sess-3 CLAUDE_CODE_SESSION_ID=sess-2 "$HS" current)" "sess-3" \
  "HQ_SESSION_ID precedence"

# 10. --session-id overrides everything, including the environment.
assert_eq "$(CLAUDE_CODE_SESSION_ID=sess-2 "$HS" --session-id sess-4 current)" "sess-4" \
  "--session-id overrides env"
assert_eq "$(CLAUDE_CODE_SESSION_ID=sess-2 "$HS" --session-id=sess-4 current)" "sess-4" \
  "--session-id= form"

# 11. A malformed session id is never turned into a path segment.
rc=0
"$HS" --session-id '../escape' current >/dev/null 2>&1 || rc=$?
[ "$rc" = "1" ] || fail "expected exit 1 for traversal in --session-id, got $rc"

# A malformed env value is skipped, not fatal — the next source still resolves.
assert_eq "$(CLAUDE_CODE_SESSION_ID='../escape' "$HS" current)" "sess-1" \
  "malformed env session id falls through to .current"

# 12. A malformed .current with no session env yields no session, and `set`
#     fails loudly rather than writing somewhere unexpected.
printf '../escape\n' > "$TMP/workspace/sessions/.current"
assert_eq "$("$HS" current)" "" "malformed .current resolves to empty"
rc=0
"$HS" set company_slug indigo >/dev/null 2>&1 || rc=$?
[ "$rc" = "1" ] || fail "expected exit 1 for set with no resolvable session, got $rc"
[ ! -e "$TMP/workspace/sessions/../escape" ] || fail "traversal target was created"

# ── senior field (authority-walk hop 2) ─────────────────────────────────────
# --session-id is used throughout: test 12 left .current malformed.

# 13. cmd_set seed includes senior: user (the copy that is not the hook).
"$HS" --session-id sess-senior-seed set project foo
seed_meta="$TMP/workspace/sessions/sess-senior-seed/meta.yaml"
grep -qx 'senior: user' "$seed_meta" \
  || fail "cmd_set seed missing senior: user in $seed_meta"
assert_eq "$("$HS" --session-id sess-senior-seed get senior)" "user" \
  "get senior after cmd_set seed"

# 14. Accepted forms write; anything else is rejected BEFORE write.
"$HS" --session-id sess-senior-val set senior user
assert_eq "$("$HS" --session-id sess-senior-val get senior)" "user" \
  "set senior user"
"$HS" --session-id sess-senior-val set senior session:0026e2dd-7fff-4733-8d61-9a6fe7004908
assert_eq "$("$HS" --session-id sess-senior-val get senior)" \
  "session:0026e2dd-7fff-4733-8d61-9a6fe7004908" "set senior session:<uuid>"
"$HS" --session-id sess-senior-val set senior lane:01M30KHSEX50K0G203QNV2590N_ip-172-31-47-133-ec2-internal
assert_eq "$("$HS" --session-id sess-senior-val get senior)" \
  "lane:01M30KHSEX50K0G203QNV2590N_ip-172-31-47-133-ec2-internal" \
  "set senior lane:<ulid_hostname>"
"$HS" --session-id sess-senior-val set senior session:run.2026_08
assert_eq "$("$HS" --session-id sess-senior-val get senior)" "session:run.2026_08" \
  "set senior session id with dot and underscore"

# Restore a known previous value so a refused write can be checked against it.
"$HS" --session-id sess-senior-val set senior user
val_meta="$TMP/workspace/sessions/sess-senior-val/meta.yaml"
prev_meta="$(cat "$val_meta")"

reject_senior() {
  local value="$1" label="$2" rc=0 err
  err="$(mktemp)"
  "$HS" --session-id sess-senior-val set senior "$value" >/dev/null 2>"$err" || rc=$?
  [ "$rc" = "1" ] || fail "$label: expected exit 1, got $rc (value='$value')"
  grep -q 'accepted forms: user, session:<id>, lane:<id>' "$err" \
    || fail "$label: rejection must name accepted forms: $(cat "$err")"
  rm -f "$err"
  assert_eq "$("$HS" --session-id sess-senior-val get senior)" "user" \
    "$label: previous senior must survive a refused write"
  [ "$(cat "$val_meta")" = "$prev_meta" ] \
    || fail "$label: meta.yaml changed after refused write"
}

reject_senior "bogus value" "set senior bogus value"
reject_senior "session:" "session: with empty id"
reject_senior "lane:" "lane: with empty id"
reject_senior "" "empty senior"
reject_senior "session: " "session: with space id"
reject_senior $'user\nextra' "senior with newline"
reject_senior "parent:foo" "unknown prefix"
reject_senior "session:../escape" "session: traversal id"
reject_senior "session:." "session: dot id"
reject_senior "session:.." "session: dotdot id"

# 15. Unrelated keys are unchanged: company_slug still mints, project still
#     accepts values that would be invalid as senior, and neither path exits.
"$HS" --session-id sess-unrel set company_slug indigo >/dev/null
assert_eq "$("$HS" --session-id sess-unrel get company_slug)" "indigo" \
  "company_slug set still works with senior validation present"
cap_unrel="$TMP/workspace/sessions/sess-unrel/scope-capability.json"
[ -f "$cap_unrel" ] || fail "company_slug must still mint scope-capability.json"
assert_eq "$(jq -r '.company_slug' "$cap_unrel")" "indigo" \
  "unrelated company_slug capability"
"$HS" --session-id sess-unrel set project "bogus value"
assert_eq "$("$HS" --session-id sess-unrel get project)" "bogus value" \
  "project with a space (invalid as senior) must still write"

# 16. Absent senior on a pre-field record: get returns empty, exit 0.
#     Distinct from an unreadable file, which must not exit 0.
mkdir -p "$TMP/workspace/sessions/sess-old"
printf 'session_id: sess-old\nstarted_at: "2020-01-01T00:00:00Z"\n' \
  > "$TMP/workspace/sessions/sess-old/meta.yaml"
old_out="$("$HS" --session-id sess-old get senior)"
assert_eq "$old_out" "" "absent senior returns empty (pre-field record)"
old_rc=0
"$HS" --session-id sess-old get senior >/dev/null || old_rc=$?
[ "$old_rc" = "0" ] || fail "absent senior must be a successful read, got $old_rc"

missing_out="$("$HS" --session-id sess-no-meta get senior)"
assert_eq "$missing_out" "" "missing meta.yaml get senior returns empty"
missing_rc=0
"$HS" --session-id sess-no-meta get senior >/dev/null || missing_rc=$?
[ "$missing_rc" = "0" ] || fail "missing meta.yaml must not fail get, got $missing_rc"

if [ "$(id -u)" != "0" ]; then
  chmod 000 "$TMP/workspace/sessions/sess-old/meta.yaml"
  unread_rc=0
  "$HS" --session-id sess-old get senior >/dev/null 2>/dev/null || unread_rc=$?
  chmod 644 "$TMP/workspace/sessions/sess-old/meta.yaml"
  [ "$unread_rc" != "0" ] \
    || fail "unreadable meta.yaml must not look like an absent key (exit 0)"
fi

# ── Company rebind clears stale context before Work Mesh registration ─────────
mkdir -p "$TMP/companies/Beta" "$TMP/companies/beta" "$TMP/core/hooks/SessionStart"
cat > "$TMP/core/hooks/SessionStart/35-work-mesh-session-start.sh" <<'HOOK'
#!/usr/bin/env bash
meta="$HQ_ROOT/workspace/sessions/$CLAUDE_CODE_SESSION_ID/meta.yaml"
cp "$meta" "$HQ_REGISTER_CAPTURE"
HOOK
chmod +x "$TMP/core/hooks/SessionStart/35-work-mesh-session-start.sh"
mkdir -p "$TMP/workspace/sessions/sess-company-rebind"
printf 'session_id: sess-company-rebind\ncompany_slug: acme\nproject: old-project\ntask: OLD-1\n' \
  > "$TMP/workspace/sessions/sess-company-rebind/meta.yaml"
capture="$TMP/work-mesh-registration-meta.yaml"
HQ_HQ_SESSION_NO_CLI=1 HQ_REGISTER_CAPTURE="$capture" \
  "$HS" --session-id sess-company-rebind set company_slug beta >/dev/null
for _ in {1..50}; do
  [ -f "$capture" ] && break
  sleep 0.1
done
[ -f "$capture" ] || fail "company rebind did not reach Work Mesh registration hook"
if grep -qE '^(project|task):' "$capture"; then
  fail "Work Mesh registration saw stale project/task after company rebind: $(grep -E '^(project|task):' "$capture" | tr '\n' ' ')"
fi
pass "company rebind clears stale project/task before Work Mesh registration"

echo "PASS: hq-session.sh ($(basename "$HS"))"
