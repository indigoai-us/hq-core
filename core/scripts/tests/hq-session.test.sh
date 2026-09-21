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

assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

# Build a minimal HQ-shaped layout so the script's BASH_SOURCE-relative
# REPO_ROOT computation has something real to resolve against.
mkdir -p "$TMP/core/scripts/lib" "$TMP/workspace/sessions"
cp "$SRC" "$TMP/core/scripts/hq-session.sh"
cp "$LIB_SRC/session-scope-capability.sh" "$TMP/core/scripts/lib/"
cp "$LIB_SRC/session-id.sh" "$TMP/core/scripts/lib/"
chmod +x "$TMP/core/scripts/hq-session.sh"
HS="$TMP/core/scripts/hq-session.sh"

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

echo "PASS: hq-session.sh ($(basename "$HS"))"
