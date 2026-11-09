#!/usr/bin/env bash
# hq-core: public
# Regression: an unbounded `find` over HQ.s workspace runs bundled bfs through
# the shell `find` function; one run used 2.6-4.5 cores for about 3 minutes over
# at least 795,688 entries. bfs ignores .ignore, and block-hq-glob only guards
# the Glob tool, so Bash searches ran unguarded.
#
# Nothing here runs a search. Each case hands the command to the guard as text.
#
# Covers:
#   1. block-hq-unbounded-search.sh denies unbounded find and recursive grep at
#      the HQ root or workspace, in absolute and relative forms and inside
#      compounds, pipelines, substitutions and sh -c.
#   2. It allows subfolder roots, -maxdepth, plain grep, paths outside HQ, rg,
#      and the words inside quoted text, comments and heredoc bodies.
#   3. It fails open on bad input and when jq or perl is missing.
#   4. All three hook-gate profiles run it.
#   5. master-hook denies the incident command in under 1 s, starts no bfs, and
#      passes the bounded form. Commands without find or grep skip the guard.
set -uo pipefail
export HQ_HOOK_DEDUPE=0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HOOK="$ROOT/.claude/hooks/block-hq-unbounded-search.sh"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
MASTER="$ROOT/.claude/hooks/master-hook.sh"
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
WS="$ROOT/workspace"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/block-hq-unbounded-search.XXXXXX")" && pwd -P)"
trap 'rm -rf -- "$SANDBOX"' EXIT

payload() { jq -nc --arg c "$1" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }

# case_at <want-rc> <cwd> <command>
case_at() {
  local want="$1" cwd="$2" cmd="$3" rc=0
  payload "$cmd" "$cwd" | env -u HQ_HOOK_CWD bash "$HOOK" >"$SANDBOX/out" 2>"$SANDBOX/err" || rc=$?
  local desc="[${cwd#"$ROOT"}] $(printf '%s' "$cmd" | tr '\n' '~')"
  if [ "$rc" -eq "$want" ]; then ok "want $want: $desc"
  else bad "want $want got $rc: $desc (err=$(tr '\n' ' ' <"$SANDBOX/err" | cut -c1-160))"; fi
}
deny() { case_at 2 "$ROOT" "$1"; }
allow() { case_at 0 "$ROOT" "$1"; }

echo "[1] denied"
# The incident command, verbatim in shape.
deny "find $WS -name '*counsel-brief*'"
deny "find $ROOT -name x"
deny "find $WS/ -name x"
deny "find \"$WS\" -name x"
deny "find '$ROOT/workspace' -type f"
deny "find . -name x"
deny "find ./ -name x"
deny "find workspace -name x"
deny "find workspace/ -name x"
deny "find ./workspace -name x"
deny "find workspace/reports/.. -name x"
deny "find -name x"
deny "find"
deny "find -L workspace -name x"
deny "find workspace/* -name x"
deny "find workspace/reports workspace -name x"
deny "/usr/bin/find workspace -name x"
deny "command find workspace -name x"
deny "\\find workspace -name x"
deny "FOO=1 find workspace -name x"
deny "find workspace -name x 2>/dev/null"
deny "find workspace -name x 2> /dev/null | head -5"
deny "find workspace -name 'maxdepth' -o -name '-maxdepth1'"
deny "grep -r x workspace"
deny "grep -R x workspace"
deny "grep --recursive x workspace"
deny "grep --dereference-recursive x workspace"
deny "grep -rn x workspace"
deny "grep -nr x $WS"
deny "grep -il -r x ."
deny "grep x -r workspace"
deny "grep -r x"
deny "grep -r -e x workspace"
deny "grep -re x workspace"
deny "grep -A3 -r x workspace"
deny "grep -A 3 -r x workspace"
deny "grep -r --include '*.md' x workspace"
deny "grep -r --include='*.md' x workspace"
deny "grep -d recurse x workspace"
deny "grep --directories=recurse x workspace"
deny "egrep -r x workspace"
deny "fgrep -r x workspace"
deny "grep -r x workspace/*"
deny "grep -r -- x workspace"
deny "ls && find workspace -name x"
deny "ls; find workspace -name x"
deny "ls || find workspace -name x"
deny "ls | find workspace -name x"
deny "(find workspace -name x)"
deny "{ find workspace -name x; }"
deny "if find workspace -name x; then echo y; fi"
deny "for d in a; do grep -r x workspace; done"
deny "ls"$'\n'"find workspace -name x"
deny "echo \$(find workspace -name x)"
deny "echo \"\$(find workspace -name x)\""
deny "echo \`find workspace -name x\`"
deny "while read f; do echo \$f; done < <(find workspace -name x)"
deny "bash -c 'find workspace -name x'"
deny "sh -c \"grep -r x workspace\""
deny "bash -lc 'find workspace -name x'"
deny "eval 'find workspace -name x'"
deny "sudo find workspace -name x"
deny "nice -n 5 find workspace -name x"
deny "time find workspace -name x"
deny "env A=1 find workspace -name x"
deny "xargs grep -r x workspace"
deny "cd workspace && find . -name x"
deny "cd $WS; grep -r x ."
deny "cd workspace/reports && find .. -name x"
deny "cd workspace/reports && find ../.. -name x"
deny "find ~/Documents/HQ/workspace-not-a-guess -name x; find $WS -name x"
case_at 2 "$WS" "find . -name x"
case_at 2 "$WS" "find .. -name x"
case_at 2 "$WS" "grep -r x ."
case_at 2 "$WS" "grep -r x"
case_at 2 "$WS/reports" "find ../.. -name x"
case_at 2 "/tmp" "find $WS -name x"
case_at 2 "/tmp" "grep -r x $ROOT"

printf '%s' "$(payload "find $WS -name x" "$ROOT")" | env -u HQ_HOOK_CWD bash "$HOOK" >"$SANDBOX/out" 2>"$SANDBOX/err"
grep -q 'qmd query' "$SANDBOX/err" && ok "deny message names qmd query" || bad "deny message names qmd query"
grep -q -- '-maxdepth' "$SANDBOX/err" && ok "deny message names -maxdepth" || bad "deny message names -maxdepth"
grep -q "$WS" "$SANDBOX/err" && ok "deny message names the root" || bad "deny message names the root"

echo "[2] allowed"
allow "find workspace/reports -name x"
allow "find $WS/reports -name x"
allow "find ./workspace/reports -type f"
allow "find workspace/worktrees/foo -name x"
allow "find workspace-other -name x"
allow "find workspace -maxdepth 2 -name x"
allow "find $WS -maxdepth 2 -name x"
allow "find . -maxdepth 1 -type f"
allow "find . -type f -maxdepth 1"
allow "find $ROOT -maxdepth 3 -name x | head -5"
allow "find workspace/reports workspace -maxdepth 1"
allow "find repos/public/hq -name x"
allow "find /tmp -name x"
allow "find /tmp/workspace -name x"
allow "find /elsewhere/Documents/HQ/workspace -name x"
allow "find core -name x"
allow "find --help"
allow "find --version"
allow "grep x workspace/notes.md"
allow "grep -n x workspace"
allow "grep -rn x workspace/reports"
allow "grep -r x core/policies"
allow "grep -r x /tmp"
allow "grep -er x workspace/notes.md"
allow "grep -e -r workspace/notes.md"
allow "grep -- -r workspace/notes.md"
allow "grep -- -r workspace"
allow "grep -f -r workspace/notes.md"
allow "grep -v -r"
allow "ls workspace | grep -r x"
allow "grep -r x < input.txt"
allow "cat a | grep x"
allow "ls | xargs grep -r x"
allow "ls | xargs -I{} find {} -name x"
allow "git grep -r x workspace"
allow "git log --grep -r"
allow "rg x workspace"
allow "rg x ."
allow "rg --files workspace"
allow "command -v find"
allow "command -V grep"
allow "which find"
allow "man find"
allow "echo find workspace -name x"
allow "echo \"find workspace -name x\""
allow "echo 'find . -name x; grep -r x .'"
allow "echo 'x; find workspace -name y'"
allow "printf '%s\\n' 'grep -r x workspace'"
allow "git -C $ROOT/repos/public/hq commit -m \"find workspace -name x\""
allow "git -C $ROOT/repos/public/hq commit -m 'run grep -r x .'"
allow "echo done # find workspace -name x"
allow "# grep -r x ."$'\n'"ls"
allow "cat > /tmp/a <<'EOF'"$'\n'"find workspace -name x"$'\n'"grep -r x ."$'\n'"EOF"
allow "cat <<-EOF"$'\n'"	find . -name x"$'\n'"	EOF"$'\n'"ls"
allow "cd workspace/reports && find . -name x"
allow "cd workspace/reports; grep -r x ."
allow "cd /tmp && find . -name x"
allow "cd /tmp && grep -r x ."
allow "x=\$(cd /tmp && find . -name x)"
allow "cd /tmp && x=\$(find . -name y)"
allow "(cd /tmp && find . -name x)"
allow "cd \$SOMEWHERE && find . -name x"
allow "find \$SOMEWHERE -name x"
allow "find \"\$SOMEWHERE/workspace\" -name x"
allow "find workspace/?eports -name x"
case_at 0 "$ROOT/repos/public/hq" "find . -name x"
case_at 0 "$ROOT/repos/public/hq" "grep -r x ."
case_at 0 "$WS/reports" "find . -name x"
case_at 0 "$WS/reports" "grep -r x"
case_at 0 "/tmp" "find . -name x"
case_at 0 "/tmp" "find workspace -name x"
case_at 0 "/tmp" "grep -r x workspace"

echo "[3] fails open"
open_case() { # <desc> <stdin> [env...]
  local desc="$1" body="$2" rc=0
  shift 2
  printf '%s' "$body" | env -u HQ_HOOK_CWD "$@" bash "$HOOK" >"$SANDBOX/out" 2>"$SANDBOX/err" || rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$SANDBOX/err" ]; then ok "fails open: $desc"
  else bad "fails open: $desc (rc=$rc err=$(tr '\n' ' ' <"$SANDBOX/err" | cut -c1-160))"; fi
}
open_case "empty stdin" ""
open_case "bad JSON" '{not json'
open_case "JSON array" '[1,2]'
open_case "no command" '{"tool_name":"Bash","tool_input":{}}'
open_case "non-string command" '{"tool_name":"Bash","tool_input":{"command":{"a":1}}}'
open_case "another tool with a command field" "$(jq -nc --arg c "find $WS -name x" '{tool_name:"Monitor",tool_input:{command:$c}}')"
open_case "unterminated single quote" "$(payload "echo 'find workspace" "$ROOT")"
open_case "unterminated substitution" "$(payload "echo \$(ls" "$ROOT")"

# PATH holding only bash, so jq and perl are both missing to the hook.
mkdir -p "$SANDBOX/nobin"
ln -s "$(command -v bash)" "$SANDBOX/nobin/bash"
ln -s "$(command -v env)" "$SANDBOX/nobin/env"
open_case "jq and perl missing" "$(payload "find $WS -name x" "$ROOT")" PATH="$SANDBOX/nobin"

# jq present, perl dying: stub perl to crash, so the guard's parser never runs.
mkdir -p "$SANDBOX/crashbin"
printf '#!/bin/sh\necho boom >&2\nexit 70\n' >"$SANDBOX/crashbin/perl"
chmod +x "$SANDBOX/crashbin/perl"
rc=0
payload "find $WS -name x" "$ROOT" | env -u HQ_HOOK_CWD PATH="$SANDBOX/crashbin:$PATH" bash "$HOOK" >/dev/null 2>"$SANDBOX/err" || rc=$?
[ "$rc" -eq 0 ] && ok "fails open: parser crash exits 0" || bad "fails open: parser crash (rc=$rc)"

# A huge command is passed without parsing rather than stalling the call.
{ printf 'find %s -name x; echo ' "$WS"; head -c 400000 /dev/zero | tr '\0' 'a'; } >"$SANDBOX/big.txt"
jq -Rsc --arg d "$ROOT" '{tool_name:"Bash",cwd:$d,tool_input:{command:.}}' <"$SANDBOX/big.txt" >"$SANDBOX/big.json"
rc=0
env -u HQ_HOOK_CWD bash "$HOOK" <"$SANDBOX/big.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "fails open: oversized command" || bad "fails open: oversized command (rc=$rc)"

echo "[4] every hook-gate profile runs the guard"
for p in minimal standard strict; do
  rc=0
  payload "find $WS -name x" "$ROOT" \
    | env -u HQ_HOOK_CWD HQ_HOOK_PROFILE="$p" CLAUDE_PROJECT_DIR="$ROOT" \
      bash "$GATE" block-hq-unbounded-search "$HOOK" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && ok "profile $p denies" || bad "profile $p want 2 got $rc"
done

echo "[5] master-hook dispatch"
{
  entry_filter='.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.id == "block-hq-unbounded-search")'
  [ "$(jq -r "$entry_filter | .script" "$REGISTRY")" = ".claude/hooks/block-hq-unbounded-search.sh" ] \
    && ok "registered on the Bash matcher" || bad "registered on the Bash matcher"
  [ "$(jq -r "$entry_filter | .safety // false" "$REGISTRY")" = "false" ] \
    && ok "not a safety guard, so a timeout cannot block Bash" || bad "marked safety: a timeout would block Bash"
  [ "$(jq -r "$entry_filter | .fail_closed // false" "$REGISTRY")" = "false" ] \
    && ok "not fail_closed" || bad "marked fail_closed"

  # A bfs on PATH that leaves a marker proves the guard path never starts one.
  mkdir -p "$SANDBOX/shim"
  printf '#!/bin/sh\n: >"%s/bfs-ran"\n' "$SANDBOX" >"$SANDBOX/shim/bfs"
  chmod +x "$SANDBOX/shim/bfs"
  master_payload() { jq -nc --arg c "$1" --arg root "$ROOT" '{session_id:"unbounded-search-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,tool_input:{command:$c}}'; }
  run_master() {
    ERR="$(printf '%s' "$1" | env PATH="$SANDBOX/shim:$PATH" CLAUDE_PROJECT_DIR="$ROOT" HQ_ALLOW_HQ_WORKTREE=1 \
      HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_TRACE=1 bash "$MASTER" PreToolUse 2>&1 >/dev/null)"; RC=$?
  }
  run_master "$(master_payload "find $WS -name x")"
  [ "$RC" = 2 ] && grep -q 'unbounded recursive search' <<<"$ERR" && ok "master-hook denies the incident command" \
    || bad "master-hook denies the incident command (rc=$RC err=$(tr '\n' ' ' <<<"$ERR" | cut -c1-300))"
  [ ! -e "$SANDBOX/bfs-ran" ] && ok "no bfs started" || bad "a bfs was started"

  run_master "$(master_payload "find $WS/reports -maxdepth 2 -name x")"
  [ "$RC" = 0 ] && ! grep -q 'unbounded recursive search' <<<"$ERR" \
    && grep -q 'block-hq-unbounded-search' <<<"$ERR" && ! grep -q 'skip block-hq-unbounded-search' <<<"$ERR" \
    && ok "master-hook runs the guard and passes the bounded form" \
    || bad "master-hook passes the bounded form (rc=$RC err=$(tr '\n' ' ' <<<"$ERR" | cut -c1-300))"

  run_master "$(master_payload "ls workspace")"
  grep -q 'skip block-hq-unbounded-search' <<<"$ERR" \
    && ok "prefilter skips a command without find or grep" \
    || bad "prefilter did not skip (err=$(tr '\n' ' ' <<<"$ERR" | cut -c1-300))"

  run_master "$(master_payload "ls"$'\n'"find $WS -name x")"
  [ "$RC" = 2 ] && ok "prefilter sees a find on a later line" || bad "prefilter missed a later line (rc=$RC)"
}

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
