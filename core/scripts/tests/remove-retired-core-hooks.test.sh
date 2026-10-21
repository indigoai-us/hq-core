#!/usr/bin/env bash
# remove-retired-core-hooks.test.sh — regression for retired core hooks that
# `hq rescue` leaves on disk.
#
# Asserts:
#   - released copies of the retired Stop leaf and its helper are removed
#   - --check reports them and exits 1 without deleting anything
#   - a retired path with local edits is kept and named
#   - live core hooks are never touched
#   - a clean tree is a silent no-op, and a second run is a no-op
#   - nothing is deleted through a symlinked core/hooks or core/hooks/Stop
#   - a CRLF copy of a released file still matches
#   - a failed removal is reported and exits 1
#   - master-hook's skip list matches the script's retired Stop leaves
#
# Explicitly wired into .github/workflows/pr-checks.yml (tests here are not
# auto-discovered).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/remove-retired-core-hooks.sh"
FIX="$ROOT/core/scripts/tests/fixtures/retired-core-hooks"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   [$1]"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]: $2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_tree() {
  local dir="$1"
  mkdir -p "$dir/core/hooks/Stop"
  cp "$FIX/Stop-70-work-mesh-done.sh.txt" "$dir/core/hooks/Stop/70-work-mesh-done.sh"
  cp "$FIX/work-mesh-done.sh.txt" "$dir/core/hooks/work-mesh-done.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/core/hooks/Stop/70-work-mesh-turn-end.sh"
}

# 1. --check reports and keeps.
T1="$TMP/check"; make_tree "$T1"
out="$(bash "$SCRIPT" "$T1" --check 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "--check exits 1 with retired files present" || fail "--check rc" "got $rc"
case "$out" in
  *"retired file present: core/hooks/Stop/70-work-mesh-done.sh"*"retired file present: core/hooks/work-mesh-done.sh"*)
    ok "--check names both retired files" ;;
  *) fail "--check output" "$out" ;;
esac
[ -f "$T1/core/hooks/Stop/70-work-mesh-done.sh" ] && [ -f "$T1/core/hooks/work-mesh-done.sh" ] \
  && ok "--check deletes nothing" || fail "--check deleted" "a retired file is gone"

# 2. Default mode removes released copies only.
T2="$TMP/remove"; make_tree "$T2"
out="$(bash "$SCRIPT" "$T2" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "remove exits 0" || fail "remove rc" "got $rc"
[ ! -e "$T2/core/hooks/Stop/70-work-mesh-done.sh" ] && [ ! -e "$T2/core/hooks/work-mesh-done.sh" ] \
  && ok "released copies removed" || fail "remove" "retired file still present"
[ -f "$T2/core/hooks/Stop/70-work-mesh-turn-end.sh" ] && ok "live Stop hook kept" || fail "live hook" "removed"
case "$out" in
  *"removed core/hooks/Stop/70-work-mesh-done.sh"*) ok "removal is reported" ;;
  *) fail "removal report" "$out" ;;
esac

# 3. Second run and --check on the cleaned tree are silent no-ops.
out="$(bash "$SCRIPT" "$T2" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "second run is a silent no-op" || fail "idempotent" "rc=$rc out=$out"
out="$(bash "$SCRIPT" "$T2" --check 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "--check on a clean tree exits 0" || fail "clean check" "rc=$rc out=$out"

# 4. Local edits are kept and named.
T4="$TMP/edited"; make_tree "$T4"
printf '# local tweak\n' >> "$T4/core/hooks/Stop/70-work-mesh-done.sh"
out="$(bash "$SCRIPT" "$T4" 2>&1)"
[ -f "$T4/core/hooks/Stop/70-work-mesh-done.sh" ] && ok "edited retired leaf kept" || fail "edited" "removed"
case "$out" in
  *"kept core/hooks/Stop/70-work-mesh-done.sh (local edits"*) ok "edited file is named" ;;
  *) fail "edited report" "$out" ;;
esac
[ ! -e "$T4/core/hooks/work-mesh-done.sh" ] && ok "unedited helper still removed" || fail "helper" "kept"

# 5. A tree without core/ is left alone.
mkdir -p "$TMP/empty"
out="$(bash "$SCRIPT" "$TMP/empty" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "non-HQ root is a no-op" || fail "non-HQ" "rc=$rc out=$out"

# 6. core/hooks/Stop is a symlink into personal/: nothing outside core/hooks
#    is deleted, even a released copy.
T6="$TMP/symstop"; make_tree "$T6"
mkdir -p "$T6/personal/hooks"
mv "$T6/core/hooks/Stop" "$T6/personal/hooks/Stop"
ln -s "$T6/personal/hooks/Stop" "$T6/core/hooks/Stop"
out="$(bash "$SCRIPT" "$T6" 2>&1)"
[ -f "$T6/personal/hooks/Stop/70-work-mesh-done.sh" ] \
  && ok "symlinked core/hooks/Stop: target file kept" || fail "symlinked Stop" "personal copy deleted"
case "$out" in
  *"kept core/hooks/Stop/70-work-mesh-done.sh (outside core/hooks"*) ok "symlinked core/hooks/Stop is reported" ;;
  *) fail "symlinked Stop report" "$out" ;;
esac
[ ! -e "$T6/core/hooks/work-mesh-done.sh" ] && ok "real core/hooks helper still removed" || fail "helper" "kept"
out="$(bash "$SCRIPT" "$T6" --check 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "--check ignores a file outside core/hooks" || fail "symlinked Stop --check" "rc=$rc out=$out"

# 7. core/hooks is a symlink into a company folder: both files kept.
T7="$TMP/symhooks"; make_tree "$T7"
mkdir -p "$T7/companies/example"
mv "$T7/core/hooks" "$T7/companies/example/hooks"
ln -s "$T7/companies/example/hooks" "$T7/core/hooks"
out="$(bash "$SCRIPT" "$T7" 2>&1)"
[ -f "$T7/companies/example/hooks/Stop/70-work-mesh-done.sh" ] && [ -f "$T7/companies/example/hooks/work-mesh-done.sh" ] \
  && ok "symlinked core/hooks: target files kept" || fail "symlinked hooks" "a company file was deleted"
case "$out" in
  *"kept core/hooks/Stop/70-work-mesh-done.sh (outside core/hooks"*"kept core/hooks/work-mesh-done.sh (outside core/hooks"*)
    ok "symlinked core/hooks is reported for both files" ;;
  *) fail "symlinked hooks report" "$out" ;;
esac

# 8. An HQ root reached through a symlink still has its own core/hooks cleaned.
T8="$TMP/realroot"; make_tree "$T8"
ln -s "$T8" "$TMP/linkroot"
bash "$SCRIPT" "$TMP/linkroot" >/dev/null 2>&1
[ ! -e "$T8/core/hooks/Stop/70-work-mesh-done.sh" ] && ok "symlinked HQ root is cleaned" || fail "symlinked root" "leaf kept"

# 9. A CRLF copy of a released file matches and is removed.
T9="$TMP/crlf"; make_tree "$T9"
sed 's/$/\r/' "$FIX/Stop-70-work-mesh-done.sh.txt" > "$T9/core/hooks/Stop/70-work-mesh-done.sh"
grep -q $'\r' "$T9/core/hooks/Stop/70-work-mesh-done.sh" || fail "crlf fixture" "no carriage returns written"
out="$(bash "$SCRIPT" "$T9" 2>&1)"
[ ! -e "$T9/core/hooks/Stop/70-work-mesh-done.sh" ] && ok "CRLF released copy removed" || fail "crlf" "$out"

# 10. A failed removal is reported and exits 1.
T10="$TMP/rmfail"; make_tree "$T10"
mkdir -p "$TMP/fakebin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/fakebin/rm"
chmod +x "$TMP/fakebin/rm"
out="$(PATH="$TMP/fakebin:$PATH" bash "$SCRIPT" "$T10" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "failed removal exits 1" || fail "rm fail rc" "got $rc"
case "$out" in
  *"could not remove core/hooks/Stop/70-work-mesh-done.sh"*) ok "failed removal is reported" ;;
  *) fail "rm fail report" "$out" ;;
esac

# 11. Every retired core/hooks/<event>/ leaf in the script is in master-hook's
#     skip list, and the skip list names nothing else.
MH="$ROOT/.claude/hooks/master-hook.sh"
script_leaves="$(sed -n "/^RETIRED='/,/^'/p" "$SCRIPT" | awk '{print $1}' \
  | sed -n 's#^core/hooks/\([^/]*/[^/]*\)$#\1#p' | sort -u)"
hook_leaves="$(sed -n '/^# Retired core leaves/,/^    esac/p' "$MH" \
  | sed -n 's#^ *\([A-Za-z]*/[^)]*\.sh\))$#\1#p' | tr '|' '\n' | sort -u)"
if [ -n "$script_leaves" ] && [ "$script_leaves" = "$hook_leaves" ]; then
  ok "master-hook skip list matches the retired leaves"
else
  fail "skip list drift" "script=[$script_leaves] master-hook=[$hook_leaves]"
fi

echo "remove-retired-core-hooks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
