#!/usr/bin/env bash
# Regression tests: /handoff auto-files hq-core deficiencies as one hq
# feedback report. Covers dedupe within 7 days, opt-out env, zero-item skip,
# secret-scan abort, and the builder-machine skip, using a stubbed hq binary.
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/var/tmp}/handoff-autofile-test.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

root="$TMP_ROOT/hq"
mkdir -p "$root/core/scripts/lib" "$root/workspace" "$TMP_ROOT/bin"
cp "$SRC_ROOT/scripts/handoff-autofile.sh" "$root/core/scripts/"
cp "$SRC_ROOT/scripts/handoff-builder-route.sh" "$root/core/scripts/"
cp "$SRC_ROOT/scripts/lib/secret-patterns.sh" "$root/core/scripts/lib/"
chmod +x "$root/core/scripts/handoff-autofile.sh"

calls="$TMP_ROOT/hq-calls.log"
: > "$calls"
cat > "$TMP_ROOT/bin/hq" <<STUB
#!/bin/sh
if [ "\$1" = "feedback" ] && [ "\$2" = "bug" ]; then
  shift 2
  title=""; body=""; nologs=0
  while [ \$# -gt 0 ]; do
    case "\$1" in
      --title) title="\$2"; shift 2 ;;
      --body-file) body="\$2"; shift 2 ;;
      --no-logs) nologs=1; shift ;;
      *) shift ;;
    esac
  done
  echo "CALL title=\$title nologs=\$nologs" >> "$calls"
  cat "\$body" >> "$calls"
  # "valid" ends in "id": the parser must still pick the real id token.
  echo "Thanks! Your valid feedback was submitted. id: fb_test123"
  exit 0
fi
exit 1
STUB
chmod +x "$TMP_ROOT/bin/hq"
export PATH="$TMP_ROOT/bin:$PATH"

thread="$TMP_ROOT/thread.json"
write_thread() { printf '%s\n' "$1" > "$thread"; }
run() { bash "$root/core/scripts/handoff-autofile.sh" --thread "$thread" --root "$root"; }
call_count() { grep -c '^CALL ' "$calls" || true; }
ledger="$root/workspace/handoff-autofile/filed.json"

two_items='{"system_info":{"hq_version":"9.8.7","os":"darwin","host":"cli","hooks_enforced":false,"hq_cli_version":"1.2.3"},
 "deficiencies":[
  {"lever":"navigation","kind":"hq-core","severity":"low","summary":"low thing","evidence":"e1","proposed_fix":"f1"},
  {"lever":"no-ops","kind":"hq-core","severity":"high","summary":"high thing","evidence":"e2","proposed_fix":"f2"},
  {"lever":"tool-economy","kind":"repo","severity":"high","summary":"repo thing","evidence":"e3","proposed_fix":"f3"}]}'

# 1. Zero hq-core items: nothing filed.
write_thread '{"system_info":{},"deficiencies":[{"lever":"navigation","kind":"local-setup","severity":"high","summary":"s","evidence":"e","proposed_fix":"f"}]}'
out="$(run)"
[ "$out" = "skipped: no hq-core deficiencies" ] || fail "zero-item: got '$out'"
[ "$(call_count)" = "0" ] || fail "zero-item: hq was called"
pass "zero hq-core items files nothing"

# 2. Opt-out env.
write_thread "$two_items"
out="$(HQ_HANDOFF_AUTOFILE=0 run)"
case "$out" in "skipped: auto-filing disabled"*) ;; *) fail "opt-out: got '$out'" ;; esac
[ "$(call_count)" = "0" ] || fail "opt-out: hq was called"
pass "HQ_HANDOFF_AUTOFILE=0 disables filing"

# 3. Builder machine skip: staging repo present and push --dry-run succeeds.
staging="$root/repos/private/hq-core-staging"
git init -q --bare "$TMP_ROOT/staging-remote.git"
git init -q "$staging"
git -C "$staging" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$staging" remote add origin "$TMP_ROOT/staging-remote.git"
out="$(run)"
[ "$out" = "skipped: builder machine" ] || fail "builder: got '$out'"
[ "$(call_count)" = "0" ] || fail "builder: hq was called"
pass "builder machine files nothing"

# 3b. Staging dir present but push --dry-run fails: public route, files.
git -C "$staging" remote set-url origin "$TMP_ROOT/missing-remote.git"
out="$(run)"
[ "$out" = "filed: fb_test123" ] || fail "unpushable staging: got '$out'"
[ "$(call_count)" = "1" ] || fail "unpushable staging: expected one hq call"
rm -rf "$staging" "$TMP_ROOT/staging-remote.git" "$root/workspace/handoff-autofile"
: > "$calls"
pass "staging repo that cannot push still files"

# 4. Secret-scan abort. The fake token is assembled at runtime so this file
# does not itself look like a credential.
fake_token="$(printf 'gh%s_%s' p "$(printf 'a%.0s' $(seq 1 40))")"
write_thread "$(jq -cn --arg ev "token $fake_token seen" \
  '{system_info:{},deficiencies:[{lever:"information-access",kind:"hq-core",severity:"high",summary:"leak",evidence:$ev,proposed_fix:"f"}]}')"
out="$(run)"
case "$out" in "aborted: "*) ;; *) fail "secret: got '$out'" ;; esac
[ "$(call_count)" = "0" ] || fail "secret: hq was called"
[ "$(jq 'length' "$ledger")" = "0" ] || fail "secret: ledger recorded a hash"
pass "secret match aborts submit"

# 5. Happy path: one report, highest-severity title, sections + system_info.
write_thread "$two_items"
out="$(run)"
[ "$out" = "filed: fb_test123" ] || fail "file: got '$out'"
[ "$(call_count)" = "1" ] || fail "file: expected one call"
grep -q '^CALL title=high thing nologs=1$' "$calls" || fail "file: title not highest severity, or log tails not suppressed"
for s in '- lever: navigation' '- lever: no-ops' '- severity: high' '- evidence: e2' '- proposed fix: f1' '## system_info' '"hq_version":"9.8.7"'; do
  grep -qF -- "$s" "$calls" || fail "file: body missing '$s'"
done
if grep -q 'repo thing' "$calls"; then fail "file: repo item leaked into body"; fi
[ "$(jq 'length' "$ledger")" = "2" ] || fail "file: ledger should hold 2 hashes"
pass "files one report with sections and system_info"

# 6. Dedupe within 7 days: all omitted -> nothing filed.
out="$(run)"
[ "$out" = "skipped: all hq-core deficiencies already filed in the last 7 days" ] || fail "dedupe: got '$out'"
[ "$(call_count)" = "1" ] || fail "dedupe: hq called again"
pass "all items filed in last 7 days files nothing"

# 7. Partial dedupe: only the new item is filed.
write_thread '{"system_info":{},"deficiencies":[
  {"lever":"no-ops","kind":"hq-core","severity":"high","summary":"high thing","evidence":"e2","proposed_fix":"f2"},
  {"lever":"automated-checks","kind":"hq-core","severity":"medium","summary":"new thing","evidence":"e4","proposed_fix":"f4"}]}'
: > "$calls"
out="$(run)"
[ "$out" = "filed: fb_test123" ] || fail "partial: got '$out'"
grep -q '^CALL title=new thing nologs=1$' "$calls" || fail "partial: title should be the only fresh item"
if grep -q 'high thing' "$calls"; then fail "partial: deduped item re-filed"; fi
pass "recently filed items are omitted"

# 8. Hashes older than 7 days are filed again.
old=$(( $(date +%s) - 8 * 86400 ))
jq --argjson old "$old" 'map_values($old)' "$ledger" > "$TMP_ROOT/l.json"
mv "$TMP_ROOT/l.json" "$ledger"
: > "$calls"
out="$(run)"
[ "$out" = "filed: fb_test123" ] || fail "expiry: got '$out'"
grep -q 'high thing' "$calls" || fail "expiry: expired item not re-filed"
pass "items older than 7 days are filed again"

echo "handoff-autofile: all tests passed"
