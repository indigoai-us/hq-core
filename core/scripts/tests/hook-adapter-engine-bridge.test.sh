#!/usr/bin/env bash
# hq-core: public
# hook-adapter-engine-bridge.test.sh — the Codex and Grok adapters route the
# policy injector (inject-policy-on-trigger) through the hq-hook engine with
# the same flag, pin and bridge decision master-hook.sh makes for Claude Code,
# and run the bash injector exactly where master-hook does.
#
# Real adapters, hooks, registry and settings in a throwaway HQ root, an
# isolated HOME and flag cache, and a stub hq-hook:
#   bridge-plan            prints plan.txt (or exits with plan-rc)
#   bridge <id> ...        logs argv and stdin length; exits with bridge-rc
#                          when set; `on` prints a marker; `shadow` runs the
#                          --script with the payload and returns its result
# The bash injector logs each run to inj.log.
#
#   [1] flag off: the stub is never started, the injector runs once, and
#       stdout, stderr and exit code are byte-identical to the adapters on the
#       merge base (no bridge in the adapter library)
#   [2] flag on, plan says on: one bridge call with the master-hook argv
#       plus --host <codex|grok> (the adapter-host guard in hq-hook) and
#       the adapter's payload on stdin; the bash injector does not run; the
#       engine's text reaches the Codex answer
#   [3] plan says shadow: the engine runs the bash script; output identical
#       to [1]
#   [4] pin mismatch (the engine leaves the id out of its plan, or `bridge`
#       exits 70/75/1/127 without a verdict): bash runs once, output
#       identical to [1]
#   [5] no engine (missing binary, dangling pointer), kill switch
#       (HQ_HOOK_ENGINE=off, ~/.hq/hook-engine.off), or bridge-plan failing:
#       bash runs once, output identical to [1]
#   [6] engine exit 2 is a verdict: bash does not run, the adapter exits as
#       it does for the bash injector's exit 2
#   [7] hq_hook_engine_port_enabled in core/scripts/lib/hook-adapter-core.sh and
#       master_hook_engine_port_enabled in master-hook.sh agree on the same
#       snapshot lines
# HQ_TEST_SOURCE_ROOT takes the adapters and library from another checkout
# (origin/main shows [2], [3] and [6] red).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
SRC="${HQ_TEST_SOURCE_ROOT:-$ROOT}"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

for dep in jq perl tar; do
  command -v "$dep" >/dev/null 2>&1 || { echo "SKIP: $dep unavailable" >&2; exit 0; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hqad-engine-bridge.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
FIX="$TMP/hq"
REF="$TMP/hq-ref"
FAKE_HOME="$TMP/home"
CACHE="$FAKE_HOME/.cache"
ENGINE="$TMP/engine"
STUB="$ENGINE/hq-hook"
CALLS="$ENGINE/calls.log"
INJ_LOG="$TMP/inj.log"
ID="inject-policy-on-trigger"
mkdir -p "$FIX" "$REF" "$FAKE_HOME" "$CACHE/hq/flags" "$ENGINE"

TRACE_LINE='[ -z "${HQ_TEST_INJ_LOG:-}" ] || printf "ran %s\n" "$*" >> "$HQ_TEST_INJ_LOG"'
make_fixture() { # <root>
  (cd "$SRC" && tar -cf - --exclude 'core/scripts/tests' \
    .claude/hooks .claude/settings.json core/scripts core/hooks core/core.yaml \
    .codex/hooks .grok/hooks) | tar -xf - -C "$1"
  TRACE_LINE="$TRACE_LINE" perl -0pi -e 's{\A(#![^\n]*\n)}{$1$ENV{TRACE_LINE}\n} or die "no shebang\n";' \
    "$1/.claude/hooks/$ID.sh"
}
make_fixture "$FIX"
make_fixture "$REF"
# Reference: the adapter library this branch was cut from, with no bridge.
BASE_SHA="$(git -C "$SRC" merge-base HEAD origin/main 2>/dev/null || true)"
if [ -n "$BASE_SHA" ] && git -C "$SRC" show "$BASE_SHA:core/scripts/lib/hook-adapter-core.sh" > "$REF/core/scripts/lib/hook-adapter-core.sh.base" 2>/dev/null \
  && [ -s "$REF/core/scripts/lib/hook-adapter-core.sh.base" ]; then
  mv -f "$REF/core/scripts/lib/hook-adapter-core.sh.base" "$REF/core/scripts/lib/hook-adapter-core.sh"
  echo "reference adapter library: merge-base $BASE_SHA"
else
  rm -f "$REF/core/scripts/lib/hook-adapter-core.sh.base"
  # Without the merge base, the reference is the same library with
  # hqad_engine_bridge redefined to always decline.
  printf '\nhqad_engine_bridge() { return 1; }\n' >> "$REF/core/scripts/lib/hook-adapter-core.sh"
  echo "reference adapter library: bridge disabled (merge base unavailable)"
fi

cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
cmd="${1:-}"
[ $# -eq 0 ] || shift
case "$cmd" in
  bridge-plan)
    printf 'bridge-plan %s\n' "$*" >> "$here/calls.log"
    [ ! -f "$here/plan-rc" ] || exit "$(cat "$here/plan-rc")"
    [ ! -f "$here/plan.txt" ] || cat "$here/plan.txt"
    exit 0
    ;;
  bridge)
    payload="$(cat)"
    printf 'bridge %s stdin=%s\n' "$*" "${#payload}" >> "$here/calls.log"
    printf '%s' "$payload" > "$here/bridge-stdin"
    if [ -f "$here/bridge-rc" ]; then
      echo "engine stderr noise" >&2
      echo "engine stdout noise"
      exit "$(cat "$here/bridge-rc")"
    fi
    mode="" script=""
    args=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --mode) mode="${2:-}"; shift 2 ;;
        --script) script="${2:-}"; shift 2 ;;
        --event|--timeout) shift 2 ;;
        --) shift; args=("$@"); break ;;
        *) shift ;;
      esac
    done
    if [ "$mode" = "shadow" ]; then
      printf '%s' "$payload" | "$script" ${args[@]+"${args[@]}"}
      exit "${PIPESTATUS[1]}"
    fi
    printf 'ENGINE-POLICY-REMINDER from the bridged injector\n'
    exit 0
    ;;
esac
exit 64
STUB
chmod +x "$STUB"

flag_off() {
  printf '%s\n' "{\"flags\":{\"hook-engine-port-$ID\":false,\"hq-anywhere-runtime\":false}}" > "$CACHE/hq/flags/snapshot-cmp_1.json"
}
flag_on() {
  printf '%s\n' "{\"flags\":{\"hook-engine-port-$ID\":\"on\",\"hq-anywhere-runtime\":false}}" > "$CACHE/hq/flags/snapshot-cmp_1.json"
}
reset_state() {
  rm -f "$CALLS" "$INJ_LOG" "$ENGINE/plan-rc" "$ENGINE/plan.txt" "$ENGINE/bridge-rc" "$ENGINE/bridge-stdin" \
    "$FAKE_HOME/.hq/hook-engine.off"
  rm -rf "$FAKE_HOME/.hq/bin"
}

N=0
# run <runtime> <root> [ENV=VALUE ...] -> RC, $TMP/out, $TMP/err (session id
# replaced by SID so two runs compare), $TMP/payload
run() {
  local rt="$1" root="$2" sid
  shift 2
  N=$((N + 1))
  sid="bridge-sid-$N"
  jq -nc --arg s "$sid" --arg cwd "$root" \
    '{session_id:$s,hook_event_name:"UserPromptSubmit",hookEventName:"UserPromptSubmit",cwd:$cwd,prompt:"please deploy the site"}' > "$TMP/payload"
  RC=0
  (cd "$root" && env -i PATH="$PATH" HOME="$FAKE_HOME" XDG_CACHE_HOME="$CACHE" TMPDIR="${TMPDIR:-/tmp}" \
    CLAUDE_PROJECT_DIR="$root" HQ_HOOK_TIMEOUT_SENTRY=0 HQ_WORK_MESH_DISABLED=1 \
    HQ_TEST_INJ_LOG="$INJ_LOG" "$@" \
    env BASH_ENV=/dev/null /bin/bash "$root/.$rt/hooks/hq-$rt-hook-adapter.sh" \
    < "$TMP/payload" > "$TMP/out.raw" 2> "$TMP/err.raw") || RC=$?
  sed -e "s/$sid/SID/g" -e "s#$root#ROOT#g" "$TMP/out.raw" > "$TMP/out"
  sed -e "s/$sid/SID/g" -e "s#$root#ROOT#g" "$TMP/err.raw" > "$TMP/err"
}
count_lines() { # <file> <regex>: lines matching, 0 when the file is absent
  [ -f "$1" ] || { echo 0; return; }
  grep -c "$2" "$1" || true
}
inj_runs() { count_lines "$INJ_LOG" '^ran'; }
bridge_calls() { count_lines "$CALLS" '^bridge '; }
plan_calls() { count_lines "$CALLS" '^bridge-plan '; }
save_ref() { REF_RC="$RC"; cp "$TMP/out" "$TMP/out-ref"; cp "$TMP/err" "$TMP/err-ref"; }
same_as_ref() { [ "$RC" = "$REF_RC" ] && cmp -s "$TMP/out" "$TMP/out-ref" && cmp -s "$TMP/err" "$TMP/err-ref"; }
diffs() { printf 'rc %s vs %s; out=%s; ref=%s; err=%s' "$RC" "$REF_RC" "$(head -c 200 "$TMP/out")" "$(head -c 200 "$TMP/out-ref")" "$(head -c 200 "$TMP/err")"; }

for rt in codex grok; do
  echo "== $rt"
  echo "[1] $rt flag off: bash exactly as on the merge base"
  reset_state; flag_off
  printf '%s\t%s\n' "$ID" on > "$ENGINE/plan.txt"
  run "$rt" "$REF" HQ_HOOK_ENGINE_BIN="$STUB"
  [ "$(inj_runs)" = "1" ] && ok "$rt reference: bash injector ran once" || bad "$rt reference: injector ran $(inj_runs) times"
  save_ref
  reset_state; flag_off
  printf '%s\t%s\n' "$ID" on > "$ENGINE/plan.txt"
  run "$rt" "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
  [ ! -e "$CALLS" ] && ok "$rt flag off: engine never started" || bad "$rt flag off: engine started: $(cat "$CALLS")"
  [ "$(inj_runs)" = "1" ] && ok "$rt flag off: bash injector ran once" || bad "$rt flag off: injector ran $(inj_runs) times"
  same_as_ref && ok "$rt flag off: stdout, stderr and exit code match the merge base (rc=$RC)" || bad "$rt flag off: $(diffs)"

  echo "[2] $rt flag on, plan says on: the bridge answers"
  reset_state; flag_on
  printf '%s\t%s\n' "$ID" on > "$ENGINE/plan.txt"
  run "$rt" "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
  [ "$(plan_calls)" = "1" ] && grep -qx 'bridge-plan --min-version 0.3.1 --schema 1' "$CALLS" \
    && ok "$rt: one bridge-plan call with master-hook's version and schema" || bad "$rt: plan calls: $(cat "$CALLS" 2>/dev/null)"
  want="bridge $ID --mode on --event UserPromptSubmit --timeout 60 --host $rt --script $FIX/.claude/hooks/$ID.sh -- stdin="
  [ "$(bridge_calls)" = "1" ] && grep -q "^$want" "$CALLS" \
    && ok "$rt: one bridge call with master-hook's argv plus --host $rt" || bad "$rt: bridge calls: $(cat "$CALLS" 2>/dev/null)"
  if [ -f "$ENGINE/bridge-stdin" ] && jq -e '.prompt == "please deploy the site"' "$ENGINE/bridge-stdin" >/dev/null 2>&1; then
    ok "$rt: the engine got the adapter's payload on stdin"
  else
    bad "$rt: engine stdin: $(head -c 200 "$ENGINE/bridge-stdin" 2>/dev/null)"
  fi
  [ "$(inj_runs)" = "0" ] && ok "$rt: bash injector did not run" || bad "$rt: bash injector ran $(inj_runs) times"
  [ "$RC" = "0" ] && ok "$rt: rc 0" || bad "$rt: rc=$RC err=$(head -c 200 "$TMP/err")"
  if [ "$rt" = codex ]; then
    grep -q 'ENGINE-POLICY-REMINDER' "$TMP/out" && ok "codex: the engine's text is in the answer" \
      || bad "codex: engine text missing: $(head -c 300 "$TMP/out")"
  fi

  echo "[3] $rt plan says shadow: the engine runs bash; same output as bash"
  reset_state; flag_on
  printf '%s\t%s\n' "$ID" shadow > "$ENGINE/plan.txt"
  run "$rt" "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
  [ "$(bridge_calls)" = "1" ] && ok "$rt shadow: one bridge call" || bad "$rt shadow: bridge calls $(bridge_calls)"
  [ "$(inj_runs)" = "1" ] && ok "$rt shadow: bash ran once (inside the engine)" || bad "$rt shadow: injector ran $(inj_runs) times"
  same_as_ref && ok "$rt shadow: output matches bash" || bad "$rt shadow: $(diffs)"

  echo "[4] $rt pin mismatch or no verdict: bash runs"
  reset_state; flag_on
  printf 'some-other-port\ton\n' > "$ENGINE/plan.txt"
  run "$rt" "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
  [ "$(bridge_calls)" = "0" ] && [ "$(inj_runs)" = "1" ] && same_as_ref \
    && ok "$rt: id left out of the plan (pin mismatch): bash only, same output" || bad "$rt left out: bridge=$(bridge_calls) inj=$(inj_runs) $(diffs)"
  for code in 70 75 1 127; do
    reset_state; flag_on
    printf '%s\t%s\n' "$ID" on > "$ENGINE/plan.txt"
    printf '%s\n' "$code" > "$ENGINE/bridge-rc"
    run "$rt" "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
    [ "$(bridge_calls)" = "1" ] && [ "$(inj_runs)" = "1" ] && same_as_ref \
      && ok "$rt: engine exit $code is no verdict: bash once, same output, engine output dropped" \
      || bad "$rt exit $code: bridge=$(bridge_calls) inj=$(inj_runs) $(diffs)"
  done

  echo "[5] $rt no engine, kill switch, failing plan: bash runs"
  reset_state; flag_on
  printf '%s\t%s\n' "$ID" on > "$ENGINE/plan.txt"
  run "$rt" "$FIX"
  [ ! -e "$CALLS" ] && [ "$(inj_runs)" = "1" ] && same_as_ref && ok "$rt: no engine binary: bash only, same output" || bad "$rt no engine: $(diffs)"
  reset_state; flag_on
  printf '%s\t%s\n' "$ID" on > "$ENGINE/plan.txt"
  mkdir -p "$FAKE_HOME/.hq/bin/hq-hook"
  printf '%s\n' "$ENGINE/missing-hq-hook" > "$FAKE_HOME/.hq/bin/hq-hook/current"
  run "$rt" "$FIX"
  [ ! -e "$CALLS" ] && [ "$(inj_runs)" = "1" ] && same_as_ref && ok "$rt: pointer to a missing engine: bash only" || bad "$rt dangling pointer: $(diffs)"
  reset_state; flag_on
  printf '%s\t%s\n' "$ID" on > "$ENGINE/plan.txt"
  mkdir -p "$FAKE_HOME/.hq/bin/hq-hook"
  printf '%s\n' "$STUB" > "$FAKE_HOME/.hq/bin/hq-hook/current"
  run "$rt" "$FIX"
  [ "$(bridge_calls)" = "1" ] && [ "$(inj_runs)" = "0" ] && ok "$rt: pointer file finds the engine" || bad "$rt pointer: bridge=$(bridge_calls) inj=$(inj_runs)"
  reset_state; flag_on
  printf '%s\t%s\n' "$ID" on > "$ENGINE/plan.txt"
  run "$rt" "$FIX" HQ_HOOK_ENGINE_BIN="$STUB" HQ_HOOK_ENGINE=OFF
  [ ! -e "$CALLS" ] && [ "$(inj_runs)" = "1" ] && same_as_ref && ok "$rt: HQ_HOOK_ENGINE=OFF: bash only" || bad "$rt kill env: $(diffs)"
  reset_state; flag_on
  printf '%s\t%s\n' "$ID" on > "$ENGINE/plan.txt"
  mkdir -p "$FAKE_HOME/.hq"; : > "$FAKE_HOME/.hq/hook-engine.off"
  run "$rt" "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
  [ ! -e "$CALLS" ] && [ "$(inj_runs)" = "1" ] && same_as_ref && ok "$rt: ~/.hq/hook-engine.off: bash only" || bad "$rt kill file: $(diffs)"
  reset_state; flag_on
  printf '%s\t%s\n' "$ID" on > "$ENGINE/plan.txt"
  printf '1\n' > "$ENGINE/plan-rc"
  run "$rt" "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
  [ "$(plan_calls)" = "1" ] && [ "$(bridge_calls)" = "0" ] && [ "$(inj_runs)" = "1" ] && same_as_ref \
    && ok "$rt: bridge-plan exit 1: bash only" || bad "$rt plan rc 1: plan=$(plan_calls) bridge=$(bridge_calls) $(diffs)"

  echo "[6] $rt engine exit 2 is a verdict"
  reset_state; flag_on
  printf '%s\t%s\n' "$ID" on > "$ENGINE/plan.txt"
  printf '2\n' > "$ENGINE/bridge-rc"
  run "$rt" "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
  [ "$(bridge_calls)" = "1" ] && [ "$(inj_runs)" = "0" ] && ok "$rt: exit 2: bash did not run" || bad "$rt exit 2: bridge=$(bridge_calls) inj=$(inj_runs)"
done

echo "[7] the adapter pre-gate agrees with master-hook's"
LIB="$TMP/adapter-pregate.sh"
MASTER="$SRC/.claude/hooks/master-hook.sh"
awk '/^hq_hook_engine_port_enabled\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$SRC/core/scripts/lib/hook-adapter-core.sh" > "$LIB"
if [ ! -s "$LIB" ]; then
  bad "no hq_hook_engine_port_enabled in core/scripts/lib/hook-adapter-core.sh"
else
  awk '/^master_hook_engine_port_enabled\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$MASTER" > "$TMP/master-pregate.sh"
  [ -s "$TMP/master-pregate.sh" ] || bad "master_hook_engine_port_enabled not found in master-hook.sh"
  cat > "$TMP/lines.txt" <<'LINES'
{"flags":{"hook-engine-port-inject-policy-on-trigger":"on"}}
{"flags":{"hook-engine-port-inject-policy-on-trigger":"shadow"}}
{"flags":{"hook-engine-port-inject-policy-on-trigger":true}}
{"flags":{"hook-engine-port-inject-policy-on-trigger": "on"}}
{"flags":{"hook-engine-port-inject-policy-on-trigger":false}}
{"flags":{"hook-engine-port-inject-policy-on-trigger":"off"}}
{"flags":{"hook-engine-port-inject-policy-on-trigger":null}}
{"flags":{"hook-engine-port-Bad_Id":"on"}}
{"flags":{"hook-engine-port-a":false,"hook-engine-port-b":"on"}}
{"flags":{"hook-engine-port-":"on"}}
{"flags":{"hook-engine-port-x" "on"}}
{"flags":{"other":"on"}}
"hook-engine-port-x
LINES
  agree=1
  while IFS= read -r line; do
    a="$(bash -c '. "$1"; master_hook_engine_port_enabled "$2" && echo y || echo n' _ "$TMP/master-pregate.sh" "$line")"
    b="$(bash -c '. "$1"; hq_hook_engine_port_enabled "$2" && echo y || echo n' _ "$LIB" "$line")"
    [ "$a" = "$b" ] || { agree=0; bad "pre-gate differs on $line: master=$a adapter=$b"; }
  done < "$TMP/lines.txt"
  [ "$agree" = 1 ] && ok "pre-gate agrees on $(wc -l < "$TMP/lines.txt" | tr -d ' ') snapshot lines"
fi

if [ "$fail" -eq 0 ]; then
  echo "ALL PASS: hook-adapter-engine-bridge ($pass)"
  exit 0
fi
echo "FAILURES: hook-adapter-engine-bridge ($fail failed, $pass passed)" >&2
exit 1
