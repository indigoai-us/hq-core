#!/usr/bin/env bash
# hq-core: public
# Regression test for core/scripts/resumework-resolve.sh prefix matching.
#
# feedback_76a8b4f7: the name search used find -name "T-*${id}*.json". A partial
#   id that already starts with "T-" (for example T-20261109-135034-theme-) put
#   "T-" into the pattern twice, so it never matched; only the exact full-name
#   check worked. Prefixes, slugs and full ids must all resolve, an ambiguous
#   prefix must list every candidate, and find pattern characters in the id must
#   not widen the match. An id that starts with T- is a prefix of the name, so a
#   short T-a or T-- cannot match one unrelated thread mid-name.

# ok() always returns 0, so "cond && ok || bad" cannot run both branches.
# shellcheck disable=SC2015
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "resumework-resolve-prefix: skipped (jq missing)"; exit 0; }

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/hq"
mkdir -p "$ROOT/core/scripts" "$ROOT/workspace/threads/archive/2026-11" "$ROOT/companies/acme/workspace/sessions"
cp "$SRC_ROOT/core/scripts/resumework-resolve.sh" "$ROOT/core/scripts/"
RESOLVE="$ROOT/core/scripts/resumework-resolve.sh"

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "  ok - $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL - $1" >&2; }

thread() {
  # thread <path> <thread_id> <created_at> <title>
  jq -n --arg id "$2" --arg c "$3" --arg t "$4" \
    '{thread_id:$id, created_at:$c, session_id:("s-"+$id), metadata:{title:$t}, conversation_summary:$t, next_steps:[]}' > "$1"
}

run() { HQ_ROOT="$ROOT" HQ_RESUMEWORK_COMPANY=acme bash "$RESOLVE" "$@" --no-vault; }
ids() { jq -r '[.matches[].thread_id] | join(",")' <<<"$1"; }

A=T-20261109-135034-theme-settings-refresh
B=T-20261109-141500-theme-settings-audit
C=T-20261108-090000-billing-export
D=T-20261102-080000-archived-theme-notes
E=T-20261107-120000-company-mirror-task
thread "$ROOT/workspace/threads/$A.json" "$A" 2026-11-09T13:50:34Z "Theme settings refresh"
thread "$ROOT/workspace/threads/$B.json" "$B" 2026-11-09T14:15:00Z "Theme settings audit"
thread "$ROOT/workspace/threads/$C.json" "$C" 2026-11-08T09:00:00Z "Billing export"
thread "$ROOT/workspace/threads/archive/2026-11/$D.json" "$D" 2026-11-02T08:00:00Z "Archived theme notes"
thread "$ROOT/companies/acme/workspace/sessions/$E.json" "$E" 2026-11-07T12:00:00Z "Company mirror task"
printf '{}' > "$ROOT/workspace/threads/$A.changeset.json"

echo "[1] full id"
out="$(run "$A")"
[ "$(ids "$out")" = "$A" ] && ok "full id selects exactly one" || bad "full id: $out"
out="$(run "$A.json")"
[ "$(ids "$out")" = "$A" ] && ok "full id with .json selects exactly one" || bad "full id .json: $out"

echo "[2] prefix that starts with T- (feedback_76a8b4f7)"
out="$(run T-20261109-135034-theme-settings-)"
[ "$(ids "$out")" = "$A" ] && ok "T- prefix resolves" || bad "T- prefix: $out"
out="$(run T-20261108-090000)"
[ "$(ids "$out")" = "$C" ] && ok "T- timestamp prefix resolves" || bad "T- timestamp prefix: $out"
out="$(run T-20261102-080000-archived)"
[ "$(ids "$out")" = "$D" ] && [ "$(jq -r '.matches[0].source' <<<"$out")" = archive ] \
  && ok "T- prefix finds an archived thread" || bad "T- prefix archive: $out"
out="$(run "$D")"
[ "$(ids "$out")" = "$D" ] && [ "$(jq -r '.matches[0].source' <<<"$out")" = archive ] \
  && ok "complete T- id finds a nested archived thread" || bad "full id archive: $out"
out="$(run "$D.json")"
[ "$(ids "$out")" = "$D" ] && [ "$(jq -r '.matches[0].source' <<<"$out")" = archive ] \
  && ok "complete T- id with .json finds a nested archived thread" || bad "full id .json archive: $out"
out="$(run 20261102-080000-archived-theme-notes)"
[ "$(ids "$out")" = "$D" ] && [ "$(jq -r '.matches[0].source' <<<"$out")" = archive ] \
  && ok "bare id without T- finds the same nested archived thread" || bad "bare id archive: $out"
out="$(run T-20261107-120000-company)"
[ "$(ids "$out")" = "$E" ] && [ "$(jq -r '.matches[0].source' <<<"$out")" = company ] \
  && ok "T- prefix finds a thread in the bound company's sessions" || bad "T- prefix company: $out"

echo "[3] prefix without T-"
out="$(run 20261109-135034-theme)"
[ "$(ids "$out")" = "$A" ] && ok "prefix without T- resolves" || bad "bare prefix: $out"

echo "[4] slug"
out="$(run billing-export)"
[ "$(ids "$out")" = "$C" ] && ok "slug resolves" || bad "slug: $out"

echo "[5] ambiguous prefix lists every candidate, newest first"
out="$(run T-20261109-)"
[ "$(ids "$out")" = "$B,$A" ] && ok "ambiguous T- prefix returns both, newest first" || bad "ambiguous T- prefix: $out"
out="$(run theme-settings)"
[ "$(ids "$out")" = "$B,$A" ] && ok "ambiguous slug returns both, newest first" || bad "ambiguous slug: $out"

echo "[6] no widening"
out="$(run T-)"
[ "$(jq '.matches | length' <<<"$out")" = 0 ] && ok "bare T- matches nothing" || bad "bare T-: $out"
out="$(run T-20261109-135034-theme-settings-refreshX)"
[ "$(jq '.matches | length' <<<"$out")" = 0 ] && ok "longer non-matching id matches nothing" || bad "non-match: $out"
for pat in 'T-2026*' 'theme?settings' 'T-[0-9]*' '*'; do
  rc=0; run "$pat" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && ok "pattern characters rejected: $pat" || bad "pattern $pat rc=$rc"
done

echo "[7] an id that starts with T- is anchored at the start of the name"
out="$(run T-9)"
[ "$(jq '.matches | length' <<<"$out")" = 0 ] && ok "T-9 matches nothing (no name starts with it)" || bad "T-9: $out"
out="$(run 9)"
[ "$(jq '.matches | length' <<<"$out")" -gt 0 ] && ok "bare 9 still matches inside names" || bad "bare 9: $out"
out="$(run T-a)"
[ "$(jq '.matches | length' <<<"$out")" = 0 ] && ok "T-a matches nothing" || bad "T-a: $out"
out="$(run T--)"
[ "$(jq '.matches | length' <<<"$out")" = 0 ] && ok "T-- matches nothing" || bad "T--: $out"
out="$(run T-theme-settings)"
[ "$(jq '.matches | length' <<<"$out")" = 0 ] && ok "T- plus a mid-name slug matches nothing" || bad "T-slug: $out"
out="$(run T-2)"
[ "$(jq '.matches | length' <<<"$out")" = 5 ] && ok "T-2 matches every thread whose name starts with it, for the user to pick" || bad "T-2: $out"

echo "[8] vault search follows the same rule"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hq" <<'HQ'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HQ_LOG"
if [ "$1 $2" = "files search" ]; then
  printf 'companies/%s/workspace/sessions/T-20261201-010000-vault-T-9-notes.json  10  x  shared\n' "$5"
  exit 0
fi
if [ "$1 $2" = "files get" ]; then
  mkdir -p "$HQ_ROOT/$(dirname "$3")"
  printf '{"thread_id":"%s","created_at":"2026-12-01T01:00:00Z"}' "$(basename "$3" .json)" > "$HQ_ROOT/$3"
  exit 0
fi
exit 1
HQ
chmod +x "$TMP/bin/hq"
export HQ_LOG="$TMP/hq.log"; : > "$HQ_LOG"
run_vault() { HQ_ROOT="$ROOT" HQ_BIN="$TMP/bin/hq" PATH="$TMP/bin:$PATH" HQ_RESUMEWORK_COMPANY=acme bash "$RESOLVE" "$@"; }
out="$(run_vault T-)"
[ ! -s "$HQ_LOG" ] && [ "$(jq '.matches | length' <<<"$out")" = 0 ] && ok "bare T- runs no vault search" || bad "bare T- vault: $(cat "$HQ_LOG") $out"
: > "$HQ_LOG"
out="$(run_vault T-9)"
if grep -q 'files get' "$HQ_LOG"; then bad "T-9 fetched a vault thread that only contains it mid-name: $(cat "$HQ_LOG")"; else ok "T-9 fetches no vault thread that only contains it mid-name"; fi
[ "$(jq '.matches | length' <<<"$out")" = 0 ] && ok "T-9 resolves nothing from the vault" || bad "T-9 vault: $out"

echo "resumework-resolve-prefix: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
