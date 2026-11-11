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
#   - legacy gate entries for this HQ root are removed from the user's Codex
#     hooks file; the user's own hooks and every other entry are kept
#   - a hook-gate.sh entry is removed only when its script is on the retired
#     list and its id matches the script name; a user's own script in
#     .codex/hooks/ run through hook-gate.sh is kept
#   - if the Codex hooks file stops parsing between the count and the clean
#     pass, nothing is written over it and the failure is reported
#   - a retired script still on disk after the file pass (local edits) keeps
#     its hooks.json entry
#   - clean output that does not parse is never moved over hooks.json, and an
#     interrupted clean pass leaves no temp file
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
# Never read or rewrite the real user Codex hooks file.
export CODEX_HOME="$TMP/codex-home-unused"

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

# 12. The legacy Codex hook layer is on the retired list, and shipped .codex
#     files are not.
listed="$(sed -n "/^RETIRED='/,/^'/p" "$SCRIPT" | awk '{print $1}' | sort -u)"
missing=""
for rel in .codex/hooks.json .codex/hooks/hook-gate.sh \
  .codex/hooks/auto-capture-registry.sh .codex/hooks/auto-checkpoint-trigger.sh \
  .codex/hooks/auto-continue-session.sh .codex/hooks/auto-handoff-trigger.sh \
  .codex/hooks/block-env-dump.sh .codex/hooks/block-hq-glob.sh \
  .codex/hooks/block-hq-grep.sh .codex/hooks/block-inline-story-impl.sh \
  .codex/hooks/block-op-leak.sh .codex/hooks/block-secret-cache-read.sh \
  .codex/hooks/check-update.sh .codex/hooks/context-meter.sh \
  .codex/hooks/detect-secrets.sh .codex/hooks/observe-patterns.sh \
  .codex/hooks/package-scope-gate.sh .codex/hooks/protect-core.sh \
  .codex/hooks/scan-output-secrets.sh .codex/hooks/screenshot-resize-trigger.sh \
  .codex/hooks/sweetheart-encouragement.sh .codex/hooks/warn-cross-company-settings.sh; do
  printf '%s\n' "$listed" | grep -xF "$rel" >/dev/null || missing="$missing $rel"
done
[ -z "$missing" ] && ok "legacy .codex hook files are on the retired list" || fail "legacy .codex list" "missing:$missing"
shipped_listed=""
for rel in $(git -C "$ROOT" ls-files .codex 2>/dev/null); do
  printf '%s\n' "$listed" | grep -xF "$rel" >/dev/null && shipped_listed="$shipped_listed $rel"
done
[ -z "$shipped_listed" ] && ok "no shipped .codex file is on the retired list" || fail "shipped .codex listed" "$shipped_listed"

# 13. A locally edited legacy Codex file is kept and named; shipped .codex
#     files are left byte-identical.
T13="$TMP/codex"; mkdir -p "$T13/core" "$T13/.codex/hooks"
printf '#!/bin/bash\n# local legacy gate\nexit 0\n' > "$T13/.codex/hooks/hook-gate.sh"
cp "$ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$T13/.codex/hooks/hq-codex-hook-adapter.sh"
cp "$ROOT/.codex/hooks/deny-core-edits.sh" "$T13/.codex/hooks/deny-core-edits.sh"
out="$(bash "$SCRIPT" "$T13" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$T13/.codex/hooks/hook-gate.sh" ] && ok "edited legacy Codex gate kept" || fail "edited codex gate" "rc=$rc"
case "$out" in
  *"kept .codex/hooks/hook-gate.sh (local edits"*) ok "edited legacy Codex gate is named" ;;
  *) fail "edited codex report" "$out" ;;
esac
cmp -s "$ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$T13/.codex/hooks/hq-codex-hook-adapter.sh" \
  && cmp -s "$ROOT/.codex/hooks/deny-core-edits.sh" "$T13/.codex/hooks/deny-core-edits.sh" \
  && ok "shipped .codex hooks untouched" || fail "shipped codex" "changed or removed"

# 14. The user's Codex hooks file: legacy gate entries for this HQ root are
#     removed, everything else is kept, --check reports without writing.
if command -v node >/dev/null 2>&1; then
  T14="$TMP/codexhome-root"; mkdir -p "$T14/core"
  T14P="$(cd -P "$T14" && pwd -P)"
  CH14="$TMP/codexhome"; mkdir -p "$CH14"
  cat > "$CH14/hooks.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "'$T14P/.codex/hooks/hook-gate.sh' detect-secrets '$T14P/.codex/hooks/detect-secrets.sh'", "timeout": 5 },
        { "type": "command", "command": "bash /opt/user/my-own-hook.sh", "timeout": 5 }
      ] },
      { "matcher": "Glob", "hooks": [
        { "type": "command", "command": "'$T14P/.codex/hooks/hook-gate.sh' block-hq-glob '$T14P/.codex/hooks/block-hq-glob.sh'", "timeout": 5 }
      ] }
    ],
    "SessionStart": [
      { "hooks": [
        { "type": "command", "command": "'$T14P/.codex/hooks/hook-gate.sh' example-gate '$T14P/.codex/hooks/example-gate-runner.sh'", "timeout": 5 },
        { "type": "command", "command": "'$T14P/.codex/hooks/hook-gate.sh' my-hook '$T14P/.codex/hooks/my-hook.sh'", "timeout": 5 },
        { "type": "command", "command": "'$T14P/.codex/hooks/hook-gate.sh' detect-secrets '$T14P/.codex/hooks/block-hq-glob.sh'", "timeout": 5 },
        { "type": "command", "command": "'/other/hq/.codex/hooks/hook-gate.sh' detect-secrets '/other/hq/.codex/hooks/detect-secrets.sh'", "timeout": 5 },
        { "type": "command", "command": "/bin/sh \"$T14P/core/scripts/hqd-hook-shim.sh\" --runtime codex", "timeout": 300 }
      ] }
    ],
    "Stop": [
      { "hooks": [
        { "type": "command", "command": "'$T14P/.codex/hooks/hook-gate.sh' auto-checkpoint-trigger '$T14P/.codex/hooks/auto-checkpoint-trigger.sh'", "timeout": 5 }
      ] }
    ]
  }
}
JSON
  before="$(cat "$CH14/hooks.json")"
  out="$(CODEX_HOME="$CH14" bash "$SCRIPT" "$T14" --check 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && ok "--check exits 1 with legacy entries in the user Codex hooks file" || fail "codex home --check rc" "rc=$rc out=$out"
  case "$out" in
    *"retired Codex hook entries present: 3 in $CH14/hooks.json"*) ok "--check counts the legacy Codex entries" ;;
    *) fail "codex home --check output" "$out" ;;
  esac
  [ "$(cat "$CH14/hooks.json")" = "$before" ] && ok "--check leaves the user Codex hooks file unchanged" || fail "codex home --check" "file changed"

  out="$(CODEX_HOME="$CH14" bash "$SCRIPT" "$T14" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "cleaning the user Codex hooks file exits 0" || fail "codex home rc" "rc=$rc out=$out"
  case "$out" in
    *"removed 3 retired Codex hook entries from $CH14/hooks.json"*) ok "removal from the user Codex hooks file is reported" ;;
    *) fail "codex home report" "$out" ;;
  esac
  left="$(node -e '
    const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const cmds = Object.entries(d.hooks).flatMap(([e, gs]) => gs.flatMap((g) => g.hooks.map((h) => e + "|" + (g.matcher || "") + "|" + h.command)));
    process.stdout.write(cmds.join("\n"));' "$CH14/hooks.json" 2>&1)"
  expected="PreToolUse|Bash|bash /opt/user/my-own-hook.sh
SessionStart||'$T14P/.codex/hooks/hook-gate.sh' example-gate '$T14P/.codex/hooks/example-gate-runner.sh'
SessionStart||'$T14P/.codex/hooks/hook-gate.sh' my-hook '$T14P/.codex/hooks/my-hook.sh'
SessionStart||'$T14P/.codex/hooks/hook-gate.sh' detect-secrets '$T14P/.codex/hooks/block-hq-glob.sh'
SessionStart||'/other/hq/.codex/hooks/hook-gate.sh' detect-secrets '/other/hq/.codex/hooks/detect-secrets.sh'
SessionStart||/bin/sh \"$T14P/core/scripts/hqd-hook-shim.sh\" --runtime codex"
  [ "$left" = "$expected" ] && ok "user hooks, user gate scripts, mismatched ids, other HQ roots and the global-install entry kept; emptied groups dropped" \
    || fail "codex home kept entries" "got [$left]"
  ls "$T14"/workspace/.hq-update-check/settings-backups/*/codex-hooks.json >/dev/null 2>&1 \
    && ok "user Codex hooks file is backed up before the rewrite" || fail "codex home backup" "no backup written"
  out="$(CODEX_HOME="$CH14" bash "$SCRIPT" "$T14" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] && ok "second run on the user Codex hooks file is a silent no-op" || fail "codex home idempotent" "rc=$rc out=$out"

  # A user Codex hooks file that holds only legacy entries is removed.
  CH14B="$TMP/codexhome-only"; mkdir -p "$CH14B"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s","timeout":5}]}]}}\n' \
    "'$T14P/.codex/hooks/hook-gate.sh' context-meter '$T14P/.codex/hooks/context-meter.sh'" > "$CH14B/hooks.json"
  CODEX_HOME="$CH14B" bash "$SCRIPT" "$T14" >/dev/null 2>&1
  [ ! -e "$CH14B/hooks.json" ] && ok "a user Codex hooks file with only legacy entries is removed" || fail "codex home only-legacy" "file kept"

  # The file stops parsing between the count pass and the clean pass (another
  # tool rewrote it). A node wrapper corrupts the file just before the clean
  # pass runs. Nothing may be written over it, and the failure is reported.
  CH14C="$TMP/codexhome-race"; mkdir -p "$CH14C" "$TMP/racebin"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s","timeout":5}]}]}}\n' \
    "'$T14P/.codex/hooks/hook-gate.sh' context-meter '$T14P/.codex/hooks/context-meter.sh'" > "$CH14C/hooks.json"
  REAL_NODE="$(command -v node)"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = clean ] && printf "{ not json" > "%s"; done\nexec "%s" "$@"\n' \
    "$CH14C/hooks.json" "$REAL_NODE" > "$TMP/racebin/node"
  chmod +x "$TMP/racebin/node"
  out="$(PATH="$TMP/racebin:$PATH" CODEX_HOME="$CH14C" bash "$SCRIPT" "$T14" 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && ok "a parse failure in the clean pass exits 1" || fail "codex home race rc" "rc=$rc out=$out"
  [ "$(cat "$CH14C/hooks.json")" = "{ not json" ] && ok "a parse failure in the clean pass writes nothing" \
    || fail "codex home race write" "got [$(cat "$CH14C/hooks.json")]"
  case "$out" in
    *"could not clean $CH14C/hooks.json"*) ok "a parse failure in the clean pass is reported" ;;
    *) fail "codex home race report" "$out" ;;
  esac
  ls "$CH14C"/hooks.json.hq-retired-tmp.* >/dev/null 2>&1 && fail "codex home race tmp" "temp file left behind" \
    || ok "a parse failure in the clean pass leaves no temp file"

  # A retired script kept on disk after the file pass (local edits) keeps its
  # hooks.json entry, so the user's edited copy keeps running. An entry whose
  # retired script is gone is still removed.
  T15="$TMP/codexhome-kept-root"; mkdir -p "$T15/core" "$T15/.codex/hooks"
  T15P="$(cd -P "$T15" && pwd -P)"
  printf '#!/bin/bash\n# my edited detect-secrets\nexit 0\n' > "$T15/.codex/hooks/detect-secrets.sh"
  CH15="$TMP/codexhome-kept"; mkdir -p "$CH15"
  printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"%s","timeout":5},{"type":"command","command":"%s","timeout":5}]}]}}\n' \
    "'$T15P/.codex/hooks/hook-gate.sh' detect-secrets '$T15P/.codex/hooks/detect-secrets.sh'" \
    "'$T15P/.codex/hooks/hook-gate.sh' block-hq-glob '$T15P/.codex/hooks/block-hq-glob.sh'" > "$CH15/hooks.json"
  out="$(CODEX_HOME="$CH15" bash "$SCRIPT" "$T15" --check 2>&1)"; rc=$?
  case "$out" in
    *"retired Codex hook entries present: 1 in $CH15/hooks.json"*) ok "--check does not count the entry of a kept retired script" ;;
    *) fail "codex kept-script --check" "rc=$rc out=$out" ;;
  esac
  out="$(CODEX_HOME="$CH15" bash "$SCRIPT" "$T15" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ -f "$T15/.codex/hooks/detect-secrets.sh" ] && ok "edited retired script kept" || fail "codex kept-script rc" "rc=$rc out=$out"
  left="$(node -e '
    const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.stdout.write(d.hooks.PreToolUse.flatMap((g) => g.hooks.map((h) => h.command)).join("\n"));' "$CH15/hooks.json" 2>&1)"
  [ "$left" = "'$T15P/.codex/hooks/hook-gate.sh' detect-secrets '$T15P/.codex/hooks/detect-secrets.sh'" ] \
    && ok "the entry of a kept retired script stays; the entry of a removed one goes" \
    || fail "codex kept-script entries" "got [$left]"

  # The clean pass writes something that does not parse: it is re-parsed
  # before it replaces hooks.json, so nothing is moved over the file.
  CH16="$TMP/codexhome-badout"; mkdir -p "$CH16" "$TMP/badbin"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s","timeout":5}]}]}}\n' \
    "'$T14P/.codex/hooks/hook-gate.sh' context-meter '$T14P/.codex/hooks/context-meter.sh'" > "$CH16/hooks.json"
  before16="$(cat "$CH16/hooks.json")"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = clean ] && { printf "{ broken"; exit 0; }; done\nexec "%s" "$@"\n' \
    "$REAL_NODE" > "$TMP/badbin/node"
  chmod +x "$TMP/badbin/node"
  out="$(PATH="$TMP/badbin:$PATH" CODEX_HOME="$CH16" bash "$SCRIPT" "$T14" 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && [ "$(cat "$CH16/hooks.json")" = "$before16" ] \
    && ok "unparseable clean output is not moved over hooks.json" || fail "codex bad output" "rc=$rc file=[$(cat "$CH16/hooks.json")]"
  ls "$CH16"/hooks.json.hq-retired-tmp.* >/dev/null 2>&1 && fail "codex bad output tmp" "temp file left behind" \
    || ok "unparseable clean output leaves no temp file"

  # Interrupted during the clean pass: the temp file is removed on exit and
  # hooks.json is unchanged.
  CH17="$TMP/codexhome-interrupt"; mkdir -p "$CH17" "$TMP/slowbin"
  cp "$CH16/hooks.json" "$CH17/hooks.json"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = clean ] && sleep 2; done\nexec "%s" "$@"\n' \
    "$REAL_NODE" > "$TMP/slowbin/node"
  chmod +x "$TMP/slowbin/node"
  PATH="$TMP/slowbin:$PATH" CODEX_HOME="$CH17" bash "$SCRIPT" "$T14" >/dev/null 2>&1 &
  pid17=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    ls "$CH17"/hooks.json.hq-retired-tmp.* >/dev/null 2>&1 && break
    sleep 0.1
  done
  kill -TERM "$pid17" 2>/dev/null
  wait "$pid17"; rc=$?
  [ "$rc" -ne 0 ] && [ "$(cat "$CH17/hooks.json")" = "$before16" ] \
    && ok "an interrupted clean pass leaves hooks.json unchanged" || fail "codex interrupt" "rc=$rc file=[$(cat "$CH17/hooks.json")]"
  ls "$CH17"/hooks.json.hq-retired-tmp.* >/dev/null 2>&1 && fail "codex interrupt tmp" "temp file left behind" \
    || ok "an interrupted clean pass removes its temp file"
else
  echo "skip [14] node is not installed"
fi

echo "remove-retired-core-hooks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
