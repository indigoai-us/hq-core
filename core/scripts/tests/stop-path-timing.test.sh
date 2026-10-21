#!/usr/bin/env bash
# stop-path-timing.test.sh — the full Stop path stays well under its budget.
#
# Builds a temp HQ from the tracked tree, plants the retired Stop leaf
# core/hooks/Stop/70-work-mesh-done.sh (left on disk by `hq rescue` on older
# installs) with a helper that sleeps, then runs master-hook.sh Stop with a
# realistic payload at a plain turn end and during a handoff.
#
# Asserts:
#   - master-hook never dispatches the retired leaf
#   - every Stop dispatch exits 0
#   - the median wall time per mode is under 12 s (40% of the 30 s per-hook
#     timeout); a warm local run takes about 2 s, so the bound is generous
#
# Explicitly wired into .github/workflows/pr-checks.yml (tests here are not
# auto-discovered).
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
RUNS="${HQ_STOP_TIMING_RUNS:-5}"
BOUND_MS="${HQ_STOP_TIMING_BOUND_MS:-12000}"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   [$1]"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]: $2"; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git is required" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HQ="$TMP/hq"
mkdir -p "$HQ" "$TMP/home"

# Tracked plus untracked-but-not-ignored files, so a local run sees edits.
(cd "$SRC" && git ls-files -co --exclude-standard -z \
  | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
  | tar --null -T - -cf -) | tar -xf - -C "$HQ"
(cd "$HQ" && git init -q && git -c user.email=t@t -c user.name=t add -A \
  && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1

# The retired leaf, byte-identical to its released copy, and a slow helper.
cp "$SRC/core/scripts/tests/fixtures/retired-core-hooks/Stop-70-work-mesh-done.sh.txt" \
  "$HQ/core/hooks/Stop/70-work-mesh-done.sh"
printf '#!/usr/bin/env bash\nsleep 25\n' > "$HQ/core/hooks/work-mesh-done.sh"
chmod +x "$HQ/core/hooks/Stop/70-work-mesh-done.sh" "$HQ/core/hooks/work-mesh-done.sh"

now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local t="${EPOCHREALTIME/[.,]/}"; printf '%s' "$((t / 1000))"
  else
    perl -MTime::HiRes=time -e 'printf "%.0f", time*1000'
  fi
}

write_transcript() {
  local path="$1" mode="$2" sid="$3" i
  : > "$path"
  for i in $(seq 1 150); do
    jq -cn --arg s "$sid" --arg c "work item $i" '{type:"user",sessionId:$s,message:{role:"user",content:$c}}' >> "$path"
    jq -cn --arg s "$sid" --arg c "done with item $i" '{type:"assistant",sessionId:$s,message:{role:"assistant",content:[{type:"text",text:$c}]}}' >> "$path"
  done
  if [ "$mode" = handoff ]; then
    jq -cn --arg s "$sid" '{type:"user",sessionId:$s,message:{role:"user",content:"<command-name>/handoff</command-name>"}}' >> "$path"
    jq -cn --arg s "$sid" '{type:"assistant",sessionId:$s,message:{role:"assistant",content:[{type:"tool_use",id:"t1",name:"Skill",input:{skill:"handoff"}}]}}' >> "$path"
    jq -cn --arg s "$sid" '{type:"assistant",sessionId:$s,message:{role:"assistant",content:[{type:"text",text:"Handoff ready. To continue in a fresh session run /resumework T-timing."}]}}' >> "$path"
  else
    jq -cn --arg s "$sid" '{type:"user",sessionId:$s,message:{role:"user",content:"what is the status?"}}' >> "$path"
    jq -cn --arg s "$sid" '{type:"assistant",sessionId:$s,message:{role:"assistant",content:[{type:"text",text:"All set."}]}}' >> "$path"
  fi
}

median() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }

for mode in plain handoff; do
  sid="stop-timing-$mode-$$"
  tr="$TMP/$mode.jsonl"
  write_transcript "$tr" "$mode" "$sid"
  if [ "$mode" = handoff ]; then
    mkdir -p "$HQ/workspace/threads"
    printf '{"thread_id":"T-timing"}\n' > "$HQ/workspace/threads/T-timing.json"
  fi
  payload="$(jq -cn --arg s "$sid" --arg t "$tr" --arg c "$HQ" \
    '{session_id:$s,transcript_path:$t,cwd:$c,hook_event_name:"Stop",stop_hook_active:false}')"
  : > "$TMP/$mode.ms"
  rcs=""
  dispatched=0
  for i in $(seq 1 "$RUNS"); do
    start="$(now_ms)"
    printf '%s' "$payload" | (cd "$HQ" && env HOME="$TMP/home" CLAUDE_PROJECT_DIR="$HQ" \
      HQ_HOOK_TRACE=1 BASH_ENV=/dev/null bash "$HQ/.claude/hooks/master-hook.sh" Stop) \
      >"$TMP/$mode.out.$i" 2>"$TMP/$mode.err.$i"
    rc=$?
    end="$(now_ms)"
    echo "$((end - start))" >> "$TMP/$mode.ms"
    [ "$rc" -eq 0 ] || rcs="$rcs run$i=rc$rc"
    grep -q '^master-hook: run 70-work-mesh-done' "$TMP/$mode.err.$i" && dispatched=1
  done
  med="$(median < "$TMP/$mode.ms")"
  echo "  $mode: runs_ms=$(tr '\n' ' ' < "$TMP/$mode.ms")median=${med}ms bound=${BOUND_MS}ms"
  [ -z "$rcs" ] && ok "$mode: every Stop dispatch exits 0" || fail "$mode exit" "$rcs $(cat "$TMP/$mode.err.1" | tail -5)"
  [ "$dispatched" -eq 0 ] && ok "$mode: retired 70-work-mesh-done.sh is not dispatched" \
    || fail "$mode retired leaf" "master-hook ran the retired Stop leaf"
  grep -q 'master-hook: skip 70-work-mesh-done.sh (retired)' "$TMP/$mode.err.1" \
    && ok "$mode: trace records the retired skip" || fail "$mode trace" "no skip line"
  [ "$med" -lt "$BOUND_MS" ] && ok "$mode: median ${med}ms < ${BOUND_MS}ms" \
    || fail "$mode timing" "median ${med}ms >= ${BOUND_MS}ms; slowest children: $(grep '^master-hook: run' "$TMP/$mode.err.$RUNS" | awk '{ms=$NF; sub(/ms$/, "", ms); print ms "\t" $0}' | sort -n | tail -3 | cut -f2 | tr '\n' ';')"
done

echo "stop-path-timing: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
