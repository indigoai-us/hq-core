#!/usr/bin/env bash
# Pins the /super-conductor scripts when HQ is reached through a symlink (for
# example ~/hq -> ~/Documents/HQ). Node resolves the main module to its real
# path, so a guard that compares argv[1] with import.meta.url skips main() and
# the script exits 0 with no output. Each script must still run through the link:
#   - sweep-check prints its targets;
#   - open-asks reads a transcript folder and prints the open ask;
#   - the message watcher writes its state file;
#   - the scope filter drops a co-b channel under --company co-a.
# Regression: PR 1450 review, the watcher silently did nothing under a symlinked root.
set -uo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # description condition-exit-code
  if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi
}

ln -s "$ROOT" "$tmp/link"
L="$tmp/link/core/scripts"

# A throwaway HQ root: co-a and co-b in the manifest, one co-a session.
mkdir -p "$tmp/root/companies" "$tmp/root/workspace/sessions/s-co-a"
printf 'companies:\n  co-a:\n    cloud_uid: cmp_co-a\n  co-b:\n    cloud_uid: cmp_co-b\n' >"$tmp/root/companies/manifest.yaml"
printf 'session_id: s-co-a\ncompany_slug: co-a\n' >"$tmp/root/workspace/sessions/s-co-a/meta.yaml"
export HQ_ROOT="$tmp/root"

# 1. sweep-check
out="$(node "$L/super-conductor-sweep-check.mjs" targets --channels hq_dms 2>&1)"
grep -qx 'hq_dms' <<<"$out"; check "sweep-check runs through a symlinked root (got: '$out')" $?

# 2. open-asks
mkdir -p "$tmp/tx"
printf '{"type":"assistant","timestamp":"2026-10-19T14:53:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"AskUserQuestion","input":{"questions":[{"question":"Which option?","options":[{"label":"A"}]}]}}]}}\n' >"$tmp/tx/s-co-a.jsonl"
out="$(node "$L/super-conductor-open-asks.mjs" --dir "$tmp/tx" --company co-a --now 2026-10-19T15:00:00Z --max-age-hours 9999 2>&1)"
grep -q '"session":"s-co-a".*"ask_id":"tu_1"' <<<"$out"; check "open-asks runs through a symlinked root (got: '$out')" $?

# 3. message watcher, one poll against a fake hq.
cat >"$tmp/hq" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "whoami --json") echo '{"personUid":"prs_owner"}' ;;
  "dm inbox") echo '[]' ;;
  "channels changes") echo '{"snapshot":true,"reset":false,"cursor":"c1","rows":[],"changed":[],"removedChannelIds":[]}' ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$tmp/hq"
HQ_BIN="$tmp/hq" node "$L/super-conductor-message-watch.mjs" --state "$tmp/watch.json" --company co-a --once >/dev/null 2>&1
grep -q '"cursor": "c1"' "$tmp/watch.json" 2>/dev/null; check "the message watcher runs through a symlinked root" $?

# 4. scope filter: a co-a row, a co-b row and a group DM.
out="$(printf '[{"channelId":"chn_co-a","companyUid":"cmp_co-a"},{"channelId":"chn_co-b","companyUid":"cmp_co-b"},{"channelId":"chn_grp","type":"group"}]' \
  | node "$L/lib/super-conductor-scope.mjs" filter-channels --company co-a 2>&1)"
grep -q chn_co-a <<<"$out"; check "filter-channels keeps the co-a channel (got: '$out')" $?
grep -q chn_grp <<<"$out"; check "filter-channels keeps a person-to-person DM" $?
check "filter-channels drops the co-b channel" "$(! grep -q chn_co-b <<<"$out"; echo $?)"
out="$(printf '{"cursor":"c1","rows":[{"channelId":"chn_co-b","companyUid":"cmp_co-b"}],"changed":[{"channelId":"chn_co-b","companyUid":"cmp_co-b"}]}' \
  | node "$L/lib/super-conductor-scope.mjs" filter-channels --company co-a 2>&1)"
check "filter-channels drops co-b rows from a changes object" "$(! grep -q chn_co-b <<<"$out"; echo $?)"
grep -q '"cursor": "c1"' <<<"$out"; check "filter-channels keeps the changes cursor" $?

# 5. --session-companies reads the locked set from hq-session.sh, so skill
# commands need no "$(...)"; an empty set fails closed.
printf '#!/usr/bin/env bash\n[[ "$1 $2" == "get company_slugs" ]] && echo co-a\n' >"$tmp/hs-ok"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/hs-empty"
rows='[{"channelId":"chn_co-a","companyUid":"cmp_co-a"},{"channelId":"chn_co-b","companyUid":"cmp_co-b"}]'
out="$(printf '%s' "$rows" | HQ_SESSION_SH="$tmp/hs-ok" node "$L/lib/super-conductor-scope.mjs" filter-channels --session-companies 2>&1)"
grep -q chn_co-a <<<"$out" && ! grep -q chn_co-b <<<"$out"; check "filter-channels --session-companies uses the session's set (got: '$out')" $?
printf '%s' "$rows" | HQ_SESSION_SH="$tmp/hs-empty" node "$L/lib/super-conductor-scope.mjs" filter-channels --session-companies >/dev/null 2>&1; rc=$?
check "an empty session set fails closed (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
HQ_SESSION_SH="$tmp/hs-empty" node "$L/super-conductor-open-asks.mjs" --session-companies --dir "$tmp" >/dev/null 2>&1; rc=$?
check "open-asks --session-companies with an empty set fails closed (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor-symlink-root: ok"
