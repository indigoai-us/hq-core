#!/usr/bin/env bash
# hq-core: public
# Regression test for core/scripts/resumework-resolve.sh.
#
# feedback_050aaf1f: a handoff written on another device lived only in
#   companies/<co>/workspace/sessions/ (and the company vault), so /resumework,
#   which searched workspace/threads only, could not find it.
# feedback_b75f1436: several handoffs shared a slug and title; the picker gave
#   no way to tell them apart.

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "resumework-resolve: skipped (jq missing)"; exit 0; }

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/hq"
mkdir -p "$ROOT/core/scripts" "$ROOT/workspace/threads/archive/2026-09" "$ROOT/workspace/threads/resume-locks" \
  "$ROOT/companies/acme/workspace/sessions" "$ROOT/companies/otherco/workspace/sessions" "$TMP/bin"
cp "$SRC_ROOT/core/scripts/resumework-resolve.sh" "$ROOT/core/scripts/"
RESOLVE="$ROOT/core/scripts/resumework-resolve.sh"

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "  ok - $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL - $1" >&2; }

thread() {
  # thread <path> <thread_id> <created_at> <session> <title> <summary> [branch]
  jq -n --arg id "$2" --arg c "$3" --arg s "$4" --arg t "$5" --arg sum "$6" --arg b "${7:-main}" '
    {thread_id:$id, created_at:$c, session_id:$s, metadata:{title:$t},
     conversation_summary:$sum, git:{branch:$b},
     next_steps:[{id:($id+"#1"),status:"open",step:"a"},{id:($id+"#2"),status:"closed",step:"b"}]}' > "$1"
}

run() { HQ_ROOT="$ROOT" HQ_BIN="$TMP/bin/hq" PATH="$TMP/bin:$PATH" bash "$RESOLVE" "$@"; }

echo "[1] local exact match"
thread "$ROOT/workspace/threads/T-20261001-100000-local-one.json" T-20261001-100000-local-one 2026-10-01T10:00:00Z s1 "Local one" "did local work"
printf '{}' > "$ROOT/workspace/threads/T-20261001-100000-local-one.changeset.json"
out="$(HQ_RESUMEWORK_COMPANY=acme run T-20261001-100000-local-one --no-vault)"
[ "$(jq '.matches | length' <<<"$out")" = 1 ] && ok "one match, changeset ignored" || bad "exact: $out"
[ "$(jq -r '.matches[0].source' <<<"$out")" = local ] && ok "source local" || bad "source: $out"
[ "$(jq -r '.matches[0].open_steps' <<<"$out")" = 1 ] && ok "open steps counted" || bad "open steps: $out"

echo "[2] cross-device handoff in the bound company's sessions folder (feedback_050aaf1f)"
thread "$ROOT/companies/acme/workspace/sessions/T-20261014-210036-email-flow-recs-us008.json" \
  T-20261014-210036-email-flow-recs-us008 2026-10-14T21:00:36Z s-other-device "Email flow recs" "US-008 work"
out="$(HQ_RESUMEWORK_COMPANY=acme run T-20261014-210036-email-flow-recs-us008 --no-vault)"
[ "$(jq -r '.matches[0].source // empty' <<<"$out")" = company ] && ok "found in companies/acme/workspace/sessions" || bad "company search: $out"
[ "$(jq -r '.matches[0].path' <<<"$out")" = "companies/acme/workspace/sessions/T-20261014-210036-email-flow-recs-us008.json" ] \
  && ok "path is HQ-relative" || bad "path: $out"

echo "[3] other companies are never searched"
thread "$ROOT/companies/otherco/workspace/sessions/T-20261014-220000-secret-thing.json" \
  T-20261014-220000-secret-thing 2026-10-14T22:00:00Z s9 "Other co" "x"
out="$(HQ_RESUMEWORK_COMPANY=acme run secret-thing --no-vault)"
[ "$(jq '.matches | length' <<<"$out")" = 0 ] && ok "otherco thread not visible from acme" || bad "leak: $out"
out="$(HQ_RESUMEWORK_COMPANY= run secret-thing --no-vault)"
[ "$(jq '.matches | length' <<<"$out")" = 0 ] && ok "no company bound: no company folder searched" || bad "unbound leak: $out"

echo "[4] local copy wins over the company mirror of the same thread"
thread "$ROOT/workspace/threads/T-20261014-210036-email-flow-recs-us008.json" \
  T-20261014-210036-email-flow-recs-us008 2026-10-14T21:00:36Z s-other-device "Email flow recs" "US-008 work"
out="$(HQ_RESUMEWORK_COMPANY=acme run email-flow-recs --no-vault)"
[ "$(jq '.matches | length' <<<"$out")" = 1 ] && [ "$(jq -r '.matches[0].source' <<<"$out")" = local ] \
  && ok "de-duplicated by thread_id, local preferred" || bad "dedupe: $out"

echo "[5] repeated handoffs with one slug and title (feedback_b75f1436)"
for t in 100000 100300 100700; do
  thread "$ROOT/workspace/threads/T-20260907-${t}-recruiting-candidate-base.json" \
    "T-20260907-${t}-recruiting-candidate-base" "2026-09-07T${t:0:2}:${t:2:2}:${t:4:2}Z" "sess-$t" \
    "Recruiting candidate base" "same summary"
done
thread "$ROOT/workspace/threads/archive/2026-09/T-20260901-090000-recruiting-candidate-base.json" \
  T-20260901-090000-recruiting-candidate-base 2026-09-01T09:00:00Z sess-old "Recruiting candidate base" "earlier summary" feat/x
out="$(HQ_RESUMEWORK_COMPANY=acme run recruiting-candidate-base --no-vault)"
[ "$(jq '.matches | length' <<<"$out")" = 4 ] && ok "four matches" || bad "count: $out"
[ "$(jq -r '.matches[0].thread_id' <<<"$out")" = T-20260907-100700-recruiting-candidate-base ] && ok "newest first" || bad "order: $out"
[ "$(jq -r '[.matches[].session_id] | join(",")' <<<"$out")" = "sess-100700,sess-100300,sess-100000,sess-old" ] \
  && ok "each match carries its session id" || bad "sessions: $out"
[ "$(jq -r '[.matches[].same_as_newer] | join(",")' <<<"$out")" = "false,true,true,false" ] \
  && ok "identical repeats flagged same_as_newer" || bad "same_as_newer: $out"
[ "$(jq -r '.matches[3].source' <<<"$out")" = archive ] && ok "archived thread found" || bad "archive: $out"
out="$(HQ_RESUMEWORK_COMPANY=acme run T-20260907-100300-recruiting-candidate-base --no-vault)"
[ "$(jq -r '[.matches[].thread_id] | join(",")' <<<"$out")" = T-20260907-100300-recruiting-candidate-base ] \
  && ok "full thread id selects exactly one" || bad "full id: $out"

echo "[5b] resume-lock records are never threads"
mkdir -p "$ROOT/workspace/threads/archive/resume-locks/T-20260907-100000-recruiting-candidate-base.lock"
printf '{"thread_id":"T-20260907-100000-recruiting-candidate-base","lock":true}' \
  > "$ROOT/workspace/threads/archive/resume-locks/T-20260907-100000-recruiting-candidate-base.lock/T-lock-recruiting-candidate-base.json"
out="$(HQ_RESUMEWORK_COMPANY=acme run recruiting-candidate-base --no-vault)"
if jq -e '.matches[] | select(.path | test("resume-locks"))' <<<"$out" >/dev/null; then bad "lock record listed as a thread"; else ok "lock records pruned"; fi

echo "[6] vault fallback: hq files search + get, bound company only"
cat > "$TMP/bin/hq" <<'HQ'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HQ_LOG"
if [ "$1 $2" = "files search" ]; then
  printf 'KEY  SIZE  MODIFIED  ACL\n'
  printf 'companies/%s/workspace/sessions/T-20261015-080000-vault-only.json  10  x  shared\n' "$5"
  printf 'companies/%s/workspace/sessions/T-20261015-080000-vault-only.changeset.json  10  x  shared\n' "$5"
  exit 0
fi
if [ "$1 $2" = "files get" ]; then
  mkdir -p "$HQ_ROOT/$(dirname "$3")"
  printf '{"thread_id":"T-20261015-080000-vault-only","created_at":"2026-10-15T08:00:00Z","session_id":"s-vault","metadata":{"title":"Vault only"},"next_steps":[]}' > "$HQ_ROOT/$3"
  exit 0
fi
exit 1
HQ
chmod +x "$TMP/bin/hq"
export HQ_LOG="$TMP/hq.log"; : > "$HQ_LOG"
out="$(HQ_RESUMEWORK_COMPANY=acme run vault-only)"
[ "$(jq -r '.matches[0].thread_id // empty' <<<"$out")" = T-20261015-080000-vault-only ] && ok "vault thread fetched and resolved" || bad "vault: $out"
[ "$(jq -r '.matches[0].source' <<<"$out")" = vault ] && ok "source vault" || bad "vault source: $out"
grep -q 'files search vault-only --company acme' "$HQ_LOG" && ok "searched the bound company" || bad "search call: $(cat "$HQ_LOG")"
if grep -q 'changeset' "$HQ_LOG"; then bad "fetched a changeset sidecar"; else ok "changeset sidecar not fetched"; fi
: > "$HQ_LOG"
out="$(HQ_RESUMEWORK_COMPANY=acme run T-20261001-100000-local-one)"
[ ! -s "$HQ_LOG" ] && ok "no vault call when found locally" || bad "unneeded vault call: $(cat "$HQ_LOG")"
out="$(HQ_RESUMEWORK_COMPANY= run nothing-here)"
[ ! -s "$HQ_LOG" ] && [ "$(jq -r '.vault.searched' <<<"$out")" = false ] && ok "no vault call without a bound company" || bad "unbound vault: $out"
out="$(HQ_RESUMEWORK_COMPANY=acme run nothing-here --no-vault)"
[ ! -s "$HQ_LOG" ] && ok "--no-vault honoured" || bad "--no-vault ignored"

echo "[7] bad input"
rc=0; run '../../etc/passwd;x' >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "unsafe id rejected" || bad "unsafe id rc=$rc"
rc=0; run '' >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "empty id rejected" || bad "empty id rc=$rc"

echo "resumework-resolve: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
