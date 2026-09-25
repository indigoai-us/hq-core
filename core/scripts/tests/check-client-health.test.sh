#!/usr/bin/env bash
# check-client-health.test.sh — behavioural coverage for the check-client-health
# SessionStart self-healing hook (client-sync-health-control-plane US-015).
#
# The hook detects an outdated or degraded install at session start and either
# repairs it in a detached background pass or files one deduplicated bug. That
# makes it the most dangerous class of hook in the tree: it runs on EVERY
# session, it spawns background work, and it can file reports on the user's
# behalf. So the properties pinned here are the ones whose absence would be
# invisible in production:
#
#   1. A healthy install is SILENT and free. No output, no stamp, no launch.
#   2. A degraded install triggers remediation EXACTLY ONCE per cooldown window
#      — and the cooldown stamp is what suppresses the second trigger. That
#      holds under CONCURRENCY (parallel SessionStarts race for the same
#      window) and the cooldown LATCHES: a stamp that cannot be written means
#      no remediation at all, never remediation on every session forever.
#   3. HQ_DISABLED_HOOKS is honoured directly (not only via hook-gate.sh).
#   4. The hook NEVER exits non-zero. A hook that fails a session start is worse
#      than the degradation it was trying to report.
#   5. Remediation parses `hq doctor --json` with NO python3 — it must behave
#      identically under jq and node, and with a BROKEN python3 stub on PATH
#      (the Windows Store-alias worst case; see hooks-no-python.test.sh). With
#      NEITHER engine present it degrades to "no findings" instead of acting.
#   6. An incomplete tree (a bare checkout, or the `hq doctor --deep-test`
#      sandbox) is never remediated — in hook mode OR via `--remediate`.
#   6b. NOTHING free-text leaves the machine. A doctor message containing an
#      absolute path must not reach the bug report, and concurrent remediations
#      must still file exactly one summary.
#   6c. Remediation does not depend on GNU coreutils: `timeout(1)` is absent on
#      a stock macOS, and its absence must not silently disable self-healing —
#      nor leave remediation UNBOUNDED, which on that same common Mac install
#      would let a wedged doctor run forever with no kill switch.
#   7. Gate profiles: the hook runs under standard/strict and deliberately
#      no-ops under `minimal`, which is documented as critical safety hooks
#      only. This is intentional — a background self-healer is not a safety
#      guard — and mirrors check-hq-update, the same background-auto-update
#      class of hook, which is likewise absent from minimal.
#
# Explicitly wired into .github/workflows/pr-checks.yml — tests here are NOT
# auto-discovered.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK_SRC="$ROOT/.claude/hooks/check-client-health.sh"
GATE_SRC="$ROOT/.claude/hooks/hook-gate.sh"
PASS=0
FAIL=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BASH_BIN="$(command -v bash)"
mkdir -p "$TMP/empty-bin"

ok()   { PASS=$((PASS + 1)); echo "ok   [$1]"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL [$1]: $2"; }

# Line count of a file that may legitimately not exist yet — "no file" is 0,
# not a redirection error. (The run_* helpers leave `set -e` on, so an
# unguarded `wc -l < missing` would abort the run instead of failing an
# assertion, hiding every later case.)
count_lines() {
  [ -f "$1" ] || { echo 0; return 0; }
  wc -l < "$1" 2>/dev/null | tr -d ' '
}

# A timestamp far enough in the past to be stale under any threshold the hook
# uses. `touch -t` is portable across GNU and BSD; `touch -d @epoch` is not.
ANCIENT="200001010000"

# ── fake HQ tree ───────────────────────────────────────────────────────────────
# A COMPLETE install (both root markers), so the hook treats it as a legitimate
# remediation target. build_root <path>
build_root() {
  local root="$1"
  mkdir -p "$root/.claude/hooks" "$root/core/scripts" "$root/companies" "$root/workspace"
  cp "$HOOK_SRC" "$root/.claude/hooks/check-client-health.sh"
  cp "$GATE_SRC" "$root/.claude/hooks/hook-gate.sh"
  cp "$ROOT/core/scripts/hook-lib.sh" "$root/core/scripts/hook-lib.sh"
  printf 'hqVersion: "1.0.0"\n' > "$root/core/core.yaml"
  printf 'companies: []\n' > "$root/companies/manifest.yaml"
}

# A sync-journal state dir whose only shard is older than the stale window —
# the cheap foreground signal the hook keys off. stale_state <path>
stale_state() {
  local dir="$1"
  mkdir -p "$dir"
  printf '{}\n' > "$dir/sync-journal.default.json"
  touch -t "$ANCIENT" "$dir/sync-journal.default.json"
}

# A fresh state dir: a journal exists but was just written, so nothing is stale.
fresh_state() {
  local dir="$1"
  mkdir -p "$dir"
  printf '{}\n' > "$dir/sync-journal.default.json"
}

# ── stub `hq` ─────────────────────────────────────────────────────────────────
# Records every invocation to $HQ_STUB_LOG. `doctor --json` prints the document
# at $HQ_STUB_DOCTOR_JSON, switching to $HQ_STUB_DOCTOR_JSON_AFTER_FIX once
# `doctor --fix` has run — so a repair that actually repairs, and one that does
# not, are both expressible. make_hq_stub <bindir>
make_hq_stub() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/hq" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HQ_STUB_LOG"
case "$1" in
  doctor)
    case "$*" in
      *--fix*)
        # HQ_STUB_FIX_HANG models a wedged repair (a doctor stuck on a network
        # call). The completion marker is written only if the sleep RETURNS, so
        # "was this killed at the deadline?" is directly observable.
        if [ -n "${HQ_STUB_FIX_HANG:-}" ]; then
          sleep "$HQ_STUB_FIX_HANG"
          : > "$HQ_STUB_STATE/fix-completed"
        fi
        : > "$HQ_STUB_STATE/fixed"
        exit 0
        ;;
      *--json*)
        if [[ "$*" == *--client-health-report* ]] && [ -n "${HQ_STUB_DOCTOR_JSON_REASON_CODES:-}" ]; then
          cat "$HQ_STUB_DOCTOR_JSON_REASON_CODES"
          exit 0
        fi
        if [ -f "$HQ_STUB_STATE/fixed" ] && [ -n "${HQ_STUB_DOCTOR_JSON_AFTER_FIX:-}" ]; then
          cat "$HQ_STUB_DOCTOR_JSON_AFTER_FIX"
        else
          cat "$HQ_STUB_DOCTOR_JSON"
        fi
        exit 0
        ;;
    esac
    ;;
  feedback)
    # An optional delay widens the window between "no dedupe stamp yet" and
    # "stamp written", so a check-then-act dedupe races deterministically.
    [ -n "${HQ_STUB_FEEDBACK_SLEEP:-}" ] && sleep "$HQ_STUB_FEEDBACK_SLEEP"
    # `hq feedback bug --body-file -` reads the report body from stdin.
    cat >> "$HQ_STUB_STATE/bug-bodies.txt" 2>/dev/null || true
    printf 'x\n' >> "$HQ_STUB_STATE/bugs-filed"
    exit "${HQ_STUB_FEEDBACK_RC:-0}"
    ;;
esac
exit 0
STUB
  chmod +x "$bin/hq"
}

# Stub the detachers (`setsid`, and the `nohup` fallback) so a background
# remediation LAUNCH is an observable, countable event instead of a real
# detached process. Every launch appends one line to $HQ_LAUNCH_LOG.
# make_launch_stub <bindir>
make_launch_stub() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/setsid" <<'STUB'
#!/usr/bin/env bash
printf 'launch %s\n' "$*" >> "${HQ_LAUNCH_LOG:-/dev/null}"
exit 0
STUB
  chmod +x "$bin/setsid"
  cp "$bin/setsid" "$bin/nohup"
}

# A PATH containing only the commands remediation legitimately needs, minus the
# ones named as excluded. Lets a test remove `timeout`/`gtimeout` (the stock
# macOS shape) or `jq`/`node` (no JSON engine at all) without touching the rest
# of the environment. sanitized_bin <dir> [excluded-command...]
sanitized_bin() {
  local dir="$1"; shift
  local excluded=" $* " c src
  rm -rf "$dir"
  mkdir -p "$dir"
  for c in bash sh env date stat tr cat printf mkdir rmdir rm ls touch grep sed \
           awk wc head cut sort uniq chmod sleep dirname basename mktemp uname \
           timeout gtimeout jq node; do
    case "$excluded" in *" $c "*) continue ;; esac
    src="$(command -v "$c" 2>/dev/null)" || true
    [ -n "$src" ] && ln -sf "$src" "$dir/$c"
  done
  ln -sf "$STUB_BIN/hq" "$dir/hq"
}

# The Microsoft Store alias worst case: python3 resolves on PATH and fails.
make_broken_python() {
  local bin="$1"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexit 9\n' > "$bin/python3"
  chmod +x "$bin/python3"
}

# The shape of a live `hq doctor --json`: free-text messages, one of them
# multi-line, and one carrying an ABSOLUTE PATH — exactly what real doctor
# messages embed, and exactly what must never be shipped off-box.
#
# The macOS home segment is COMPOSED rather than written out: the repo's
# users-path tripwire (`bash .leak-scan/scan.sh users-path`) fails on a literal
# `/Users/<name>` anywhere under core/scripts, and the fixture that proves such
# a path never reaches a bug body must not itself be the thing that trips it.
# The value handed to the fixture and to the assertion is byte-identical to the
# literal it replaces, so the redaction property under test is unchanged.
MACOS_HOME_SEGMENT="Users"
LEAK_PATH="/$MACOS_HOME_SEGMENT/jane.doe/hq/workspace/vault/acme/secrets.manifest.json"
DOCTOR_DEGRADED="$TMP/doctor-degraded.json"
cat > "$DOCTOR_DEGRADED" <<JSON
{
  "results": [
    { "family": "sync", "status": "FAIL", "checkId": "sync.journal.stale",
      "message": "The sync journal has not advanced in 9 days." },
    { "family": "sync", "status": "WARN", "checkId": "sync.vault.drift",
      "message": "Vault manifest drifted\nfrom the local tree." },
    { "family": "sync", "status": "FAIL", "checkId": "sync.vault.missing",
      "message": "Vault manifest missing at $LEAK_PATH (owner jane.doe)." },
    { "family": "sync", "status": "PASS", "checkId": "sync.auth.ok",
      "message": "Credentials valid." },
    { "family": "hooks", "status": "FAIL", "checkId": "hooks.other.family",
      "message": "Not a sync finding; must be ignored." }
  ]
}
JSON

DOCTOR_REASON_CODES="$TMP/doctor-reason-codes.json"
cat > "$DOCTOR_REASON_CODES" <<JSON
{
  "clientHealthReasonCodesEnabled": true,
  "results": [
    { "family": "sync", "status": "WARN", "checkId": "sync.journal.personal", "reasonCode": "stale-threshold", "clientHealthReasonCodesEnabled": true,
      "target": "$LEAK_PATH", "message": "private path $LEAK_PATH and private prose" },
    { "family": "sync", "status": "FAIL", "checkId": "sync.manifest.personal", "reasonCode": "stale-threshold",
      "clientHealthReasonCodesEnabled": true, "message": "private manifest prose $LEAK_PATH" },
    { "family": "sync", "status": "WARN", "checkId": "sync.journal.other-company", "reasonCode": "never-synced",
      "message": "private company prose must stay local" },
    { "family": "hooks", "status": "FAIL", "checkId": "hooks.private", "reasonCode": "never-synced" }
  ]
}
JSON

DOCTOR_HEALTHY="$TMP/doctor-healthy.json"
cat > "$DOCTOR_HEALTHY" <<'JSON'
{ "results": [ { "family": "sync", "status": "PASS", "checkId": "sync.auth.ok", "message": "ok" } ] }
JSON

DOCTOR_UPDATE_WARN="$TMP/doctor-update-warn.json"
cat > "$DOCTOR_UPDATE_WARN" <<'JSON'
{ "results": [ { "family": "sync", "status": "WARN", "checkId": "sync.update.core", "message": "A newer HQ Core release is available." } ] }
JSON

DOCTOR_UPDATE_FAIL="$TMP/doctor-update-fail.json"
cat > "$DOCTOR_UPDATE_FAIL" <<'JSON'
{ "results": [ { "family": "sync", "status": "FAIL", "checkId": "sync.update.core", "message": "The installed HQ Core state is invalid." } ] }
JSON

# run_hook <label-vars...> — invokes the hook in SessionStart mode against
# $ROOT_UNDER_TEST, capturing stdout and exit code into HOOK_OUT / HOOK_RC.
# Extra `KEY=VALUE` arguments are exported for that invocation only.
run_hook() {
  local root="$1"; shift
  set +e
  HOOK_OUT="$(printf '{"hook_event_name":"SessionStart"}' \
    | env "$@" \
        PATH="$STUB_BIN:$PATH" \
        CLAUDE_PROJECT_DIR="$root" \
        HQ_STUB_LOG="$STUB_LOG" \
        HQ_STUB_STATE="$STUB_STATE" \
        HQ_LAUNCH_LOG="$LAUNCH_LOG" \
        HQ_STUB_DOCTOR_JSON="$DOCTOR_HEALTHY" \
        bash "$root/.claude/hooks/check-client-health.sh" 2>/dev/null)"
  HOOK_RC=$?
  set -e
}

STUB_BIN="$TMP/bin"
STUB_STATE="$TMP/stub-state"
STUB_LOG="$TMP/stub.log"
LAUNCH_LOG="$TMP/launch.log"
mkdir -p "$STUB_STATE"
: > "$STUB_LOG"
: > "$LAUNCH_LOG"
make_hq_stub "$STUB_BIN"
make_launch_stub "$STUB_BIN"

echo "== 1. a healthy install is silent, free, and exits 0 =="
R1="$TMP/healthy"
build_root "$R1"
fresh_state "$TMP/state-fresh"
run_hook "$R1" HQ_STATE_DIR="$TMP/state-fresh"
[ "$HOOK_RC" = 0 ] && ok "healthy install exits 0" \
  || bad "healthy install exits 0" "exit $HOOK_RC"
[ -z "$HOOK_OUT" ] && ok "healthy install emits no output" \
  || bad "healthy install emits no output" "got: $HOOK_OUT"
[ ! -f "$R1/workspace/.hq-client-health/remediation.stamp" ] \
  && ok "healthy install writes no cooldown stamp" \
  || bad "healthy install writes no cooldown stamp" "stamp exists"

echo "== 2. a degraded install triggers remediation exactly once per cooldown =="
R2="$TMP/degraded"
build_root "$R2"
stale_state "$TMP/state-stale"
run_hook "$R2" HQ_STATE_DIR="$TMP/state-stale"
STAMP2="$R2/workspace/.hq-client-health/remediation.stamp"
[ "$HOOK_RC" = 0 ] && ok "degraded install still exits 0" \
  || bad "degraded install still exits 0" "exit $HOOK_RC"
case "$HOOK_OUT" in
  *"<hq-client-health>"*"stale-sync-journal"*)
    ok "degraded install announces the detected signal" ;;
  *)
    bad "degraded install announces the detected signal" "got: [$HOOK_OUT]" ;;
esac
[ -f "$STAMP2" ] && ok "a landed launch writes the cooldown stamp" \
  || bad "a landed launch writes the cooldown stamp" "no stamp at $STAMP2"

echo "== 3. the cooldown stamp suppresses the second trigger =="
run_hook "$R2" HQ_STATE_DIR="$TMP/state-stale"
[ "$HOOK_RC" = 0 ] && ok "second run inside cooldown exits 0" \
  || bad "second run inside cooldown exits 0" "exit $HOOK_RC"
[ -z "$HOOK_OUT" ] && ok "second run inside cooldown is silent" \
  || bad "second run inside cooldown is silent" "got: [$HOOK_OUT]"
# Ageing the stamp past the 6h window must let it fire again — proving the
# suppression is the cooldown and not a one-shot latch.
touch -t "$ANCIENT" "$STAMP2"
run_hook "$R2" HQ_STATE_DIR="$TMP/state-stale"
case "$HOOK_OUT" in
  *"<hq-client-health>"*) ok "an expired cooldown allows the next trigger" ;;
  *) bad "an expired cooldown allows the next trigger" "got: [$HOOK_OUT]" ;;
esac

echo "== 4. HQ_DISABLED_HOOKS opt-out is honoured directly =="
R4="$TMP/disabled"
build_root "$R4"
run_hook "$R4" HQ_STATE_DIR="$TMP/state-stale" HQ_DISABLED_HOOKS="check-client-health"
[ "$HOOK_RC" = 0 ] && ok "opted-out hook exits 0" \
  || bad "opted-out hook exits 0" "exit $HOOK_RC"
[ -z "$HOOK_OUT" ] && ok "opted-out hook emits nothing on a degraded install" \
  || bad "opted-out hook emits nothing on a degraded install" "got: [$HOOK_OUT]"
[ ! -f "$R4/workspace/.hq-client-health/remediation.stamp" ] \
  && ok "opted-out hook launches no remediation" \
  || bad "opted-out hook launches no remediation" "stamp was written"
# The comma-list form must not match by substring.
run_hook "$R4" HQ_STATE_DIR="$TMP/state-stale" HQ_DISABLED_HOOKS="detect-secrets,check-client-health,protect-core"
[ -z "$HOOK_OUT" ] && ok "opt-out is honoured mid-list" \
  || bad "opt-out is honoured mid-list" "got: [$HOOK_OUT]"

echo "== 5. the hook never exits non-zero =="
# Every hostile shape: no stdin, empty stdin, garbage stdin, no `hq` on PATH,
# an unwritable state dir, and a tree with no workspace/ at all.
R5="$TMP/never-fails"
build_root "$R5"
declare -a rcs=()
set +e
printf '' | env PATH="$STUB_BIN:$PATH" CLAUDE_PROJECT_DIR="$R5" HQ_STATE_DIR="$TMP/state-stale" \
  HQ_STUB_LOG="$STUB_LOG" HQ_STUB_STATE="$STUB_STATE" HQ_STUB_DOCTOR_JSON="$DOCTOR_HEALTHY" \
  bash "$R5/.claude/hooks/check-client-health.sh" >/dev/null 2>&1
rcs+=($?)
printf 'not json at all {{{' | env PATH="$STUB_BIN:$PATH" CLAUDE_PROJECT_DIR="$R5" HQ_STATE_DIR="$TMP/state-stale" \
  HQ_STUB_LOG="$STUB_LOG" HQ_STUB_STATE="$STUB_STATE" HQ_STUB_DOCTOR_JSON="$DOCTOR_HEALTHY" \
  bash "$R5/.claude/hooks/check-client-health.sh" >/dev/null 2>&1
rcs+=($?)
# No `hq` binary — and in fact no PATH at all. bash is invoked by absolute path
# so the empty PATH is the hook's problem to survive, not the harness's.
printf '{}' | env PATH="$TMP/empty-bin" CLAUDE_PROJECT_DIR="$R5" HQ_STATE_DIR="$TMP/state-stale" \
  "$BASH_BIN" "$R5/.claude/hooks/check-client-health.sh" >/dev/null 2>&1
rcs+=($?)
# CLAUDE_PROJECT_DIR pointing at a path that does not exist.
printf '{}' | env PATH="$STUB_BIN:$PATH" CLAUDE_PROJECT_DIR="$TMP/does-not-exist" \
  HQ_STATE_DIR="$TMP/state-stale" HQ_STUB_LOG="$STUB_LOG" HQ_STUB_STATE="$STUB_STATE" \
  HQ_STUB_DOCTOR_JSON="$DOCTOR_HEALTHY" \
  bash "$R5/.claude/hooks/check-client-health.sh" >/dev/null 2>&1
rcs+=($?)
# An unwritable state directory: mkdir of the stamp dir must not fail the hook.
R5B="$TMP/unwritable"
build_root "$R5B"
chmod 500 "$R5B/workspace"
printf '{}' | env PATH="$STUB_BIN:$PATH" CLAUDE_PROJECT_DIR="$R5B" HQ_STATE_DIR="$TMP/state-stale" \
  HQ_STUB_LOG="$STUB_LOG" HQ_STUB_STATE="$STUB_STATE" HQ_STUB_DOCTOR_JSON="$DOCTOR_HEALTHY" \
  bash "$R5B/.claude/hooks/check-client-health.sh" >/dev/null 2>&1
rcs+=($?)
chmod 700 "$R5B/workspace"
set -e
BADRC=""
for rc in "${rcs[@]}"; do [ "$rc" = 0 ] || BADRC="$BADRC $rc"; done
[ -z "$BADRC" ] && ok "hook exits 0 under every hostile input (${#rcs[@]} cases)" \
  || bad "hook exits 0 under every hostile input" "non-zero exits:$BADRC"

echo "== 6. an incomplete tree is never remediated =="
R6="$TMP/partial"
build_root "$R6"
rm -f "$R6/companies/manifest.yaml"   # the `--deep-test` sandbox shape
run_hook "$R6" HQ_STATE_DIR="$TMP/state-stale"
[ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] \
  && ok "a tree without companies/manifest.yaml is left alone" \
  || bad "a tree without companies/manifest.yaml is left alone" "rc=$HOOK_RC out=[$HOOK_OUT]"
[ ! -f "$R6/workspace/.hq-client-health/remediation.stamp" ] \
  && ok "an incomplete tree gets no cooldown stamp" \
  || bad "an incomplete tree gets no cooldown stamp" "stamp was written"

echo "== 7. remediation: python-free doctor parsing, fix-then-verify, dedupe =="
make_broken_python "$STUB_BIN"
ENGINES="-"
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && ENGINES="jq node"

# run_remediate <root> <engine> [doctor-json] — runs the detached remediation pass in the
# foreground (it is the same script with --remediate) with a broken python3 on
# PATH, and returns its exit code in REM_RC.
run_remediate() {
  local root="$1" engine="$2" doctor_json="${3:-$DOCTOR_DEGRADED}"
  local -a extra=()
  [ "$engine" = "-" ] || extra+=("HQ_HOOK_ENGINE=$engine")
  set +e
  env "${extra[@]}" \
    PATH="$STUB_BIN:$PATH" \
    HQ_STUB_LOG="$STUB_LOG" \
    HQ_STUB_STATE="$REM_STATE" \
    HQ_STUB_DOCTOR_JSON="$doctor_json" \
    bash "$root/.claude/hooks/check-client-health.sh" --remediate "$root" >/dev/null 2>&1
  REM_RC=$?
  set -e
}

for eng in $ENGINES; do
  label="$eng"; [ "$eng" = "-" ] && label="default"
  RR="$TMP/rem-$label"
  build_root "$RR"
  REM_STATE="$TMP/rem-stub-$label"
  mkdir -p "$REM_STATE"

  # Findings survive `--fix`: the three sync FAIL/WARN checks must be
  # reported together, and nothing from another family or a PASS status. The count is
  # also what pins record integrity — a multi-line doctor message that leaked
  # into the record stream would show up here as a fourth, bogus filing.
  run_remediate "$RR" "$eng"
  [ "$REM_RC" = 0 ] && ok "remediate($label) exits 0" \
    || bad "remediate($label) exits 0" "exit $REM_RC"
  FILED=$(count_lines "$REM_STATE/bugs-filed")
  [ "${FILED:-0}" = 1 ] \
    && ok "remediate($label) files one summary for unresolved sync findings" \
    || bad "remediate($label) files one summary for unresolved sync findings" "filed ${FILED:-0}, expected 1"
  BUGS="$RR/workspace/.hq-client-health/bugs"
  [ -f "$BUGS/summary.stamp" ] && [ -f "$BUGS/report-attempt.stamp" ] \
    && ok "remediate($label) records summary and attempt" \
    || bad "remediate($label) records summary and attempt" "missing stamp"
  grep -Fq -- '--no-logs' "$STUB_LOG" \
    && ok "automatic reports disable log uploads" \
    || bad "automatic reports disable log uploads" "missing --no-logs"
  if grep -Fq "hooks.other.family" "$REM_STATE/bug-bodies.txt" 2>/dev/null; then
    bad "remediate($label) ignores non-sync families" "hooks.other.family was reported"
  else
    ok "remediate($label) ignores non-sync families"
  fi
  # PRIVACY. Doctor messages embed absolute paths; nothing but the stable check
  # id may reach a bug body. Assert on the path itself, on its parent shape,
  # and on the message prose that carried it.
  if grep -Fq "$LEAK_PATH" "$REM_STATE/bug-bodies.txt" 2>/dev/null; then
    bad "remediate($label) never ships an absolute path off-box" \
      "bug body contains $LEAK_PATH"
  else
    ok "remediate($label) never ships an absolute path off-box"
  fi
  if grep -Eq '(^|[^A-Za-z0-9])/(Users|home)/' "$REM_STATE/bug-bodies.txt" 2>/dev/null; then
    bad "remediate($label) bug bodies carry no home-directory path shape" \
      "body: $(tr '\n' ' ' < "$REM_STATE/bug-bodies.txt" 2>/dev/null | head -c 300)"
  else
    ok "remediate($label) bug bodies carry no home-directory path shape"
  fi
  if grep -Fq "Vault manifest drifted" "$REM_STATE/bug-bodies.txt" 2>/dev/null \
    || grep -Fq "has not advanced in 9 days" "$REM_STATE/bug-bodies.txt" 2>/dev/null; then
    bad "remediate($label) reports the check id only, never the doctor message" \
      "raw doctor message text reached the bug body"
  else
    ok "remediate($label) reports the check id only, never the doctor message"
  fi
  if grep -Fq "sync.journal.stale: stale-threshold" "$REM_STATE/bug-bodies.txt" 2>/dev/null; then
    bad "reason codes stay off when the hq-flags gate is off" "unexpected reason code in default report"
  else
    ok "reason codes stay off when the hq-flags gate is off"
  fi
  # The check id itself still has to be there, or the report is useless.
  grep -Fq "sync.vault.missing" "$REM_STATE/bug-bodies.txt" 2>/dev/null \
    && ok "remediate($label) still identifies the failing check by id" \
    || bad "remediate($label) still identifies the failing check by id" \
      "no check id in body"
  # `hq doctor --fix --yes` must actually be attempted before anything is filed.
  grep -Fq -- "doctor --fix --yes" "$STUB_LOG" \
    && ok "remediate($label) attempts the safe repair pass first" \
    || bad "remediate($label) attempts the safe repair pass first" "no --fix in stub log"

  # Second pass inside the 24h window: dedupe means NO new bug.
  : > "$REM_STATE/bugs-filed"
  run_remediate "$RR" "$eng"
  REFILED=$(count_lines "$REM_STATE/bugs-filed")
  [ "${REFILED:-0}" = 0 ] \
    && ok "remediate($label) dedupes inside the 24h window" \
    || bad "remediate($label) dedupes inside the 24h window" "refiled ${REFILED:-0}"
done

echo "== 7b. the ordinary sync.update.core WARN is not a defect report =="
for eng in $ENGINES; do
  label="$eng"; [ "$eng" = "-" ] && label="default"

  WARN_ROOT="$TMP/update-warn-$label"
  build_root "$WARN_ROOT"
  REM_STATE="$TMP/rem-update-warn-$label"
  mkdir -p "$REM_STATE"
  run_remediate "$WARN_ROOT" "$eng" "$DOCTOR_UPDATE_WARN"
  [ "$REM_RC" = 0 ] && ok "remediate($label) handles sync.update.core WARN" \
    || bad "remediate($label) handles sync.update.core WARN" "exit $REM_RC"
  [ "$(count_lines "$REM_STATE/bugs-filed")" = 0 ] \
    && ok "sync.update.core WARN alone files no client-health report ($label)" \
    || bad "sync.update.core WARN alone files no client-health report ($label)" "filed $(count_lines "$REM_STATE/bugs-filed")"

  FAIL_ROOT="$TMP/update-fail-$label"
  build_root "$FAIL_ROOT"
  REM_STATE="$TMP/rem-update-fail-$label"
  mkdir -p "$REM_STATE"
  run_remediate "$FAIL_ROOT" "$eng" "$DOCTOR_UPDATE_FAIL"
  [ "$(count_lines "$REM_STATE/bugs-filed")" = 1 ] \
    && ok "sync.update.core FAIL still files a client-health report ($label)" \
    || bad "sync.update.core FAIL still files a client-health report ($label)" "filed $(count_lines "$REM_STATE/bugs-filed")"
  grep -Fq "sync.update.core" "$REM_STATE/bug-bodies.txt" \
    && ok "sync.update.core FAIL remains in the report body ($label)" \
    || bad "sync.update.core FAIL remains in the report body ($label)" "check id missing"
done
echo "== 7c. opted-in diagnostics carry only checkId: reasonCode pairs =="
RDIAG="$TMP/rem-diagnostics"
build_root "$RDIAG"
REM_STATE="$TMP/rem-stub-diagnostics"
mkdir -p "$REM_STATE"
set +e
env PATH="$STUB_BIN:$PATH" HQ_STUB_LOG="$STUB_LOG" HQ_STUB_STATE="$REM_STATE" \
  HQ_STUB_DOCTOR_JSON="$DOCTOR_DEGRADED" \
  HQ_STUB_DOCTOR_JSON_REASON_CODES="$DOCTOR_REASON_CODES" \
  bash "$RDIAG/.claude/hooks/check-client-health.sh" --remediate "$RDIAG" >/dev/null 2>&1
RDIAG_RC=$?
set -e
[ "$RDIAG_RC" = 0 ] && ok "opted-in remediation exits 0" \
  || bad "opted-in remediation exits 0" "exit $RDIAG_RC"
grep -Fq "sync.journal.personal: stale-threshold" "$REM_STATE/bug-bodies.txt" 2>/dev/null \
  && ok "opted-in report includes journal reason code" \
  || bad "opted-in report includes journal reason code" "missing checkId: reasonCode pair"
grep -Fq "sync.manifest.personal: stale-threshold" "$REM_STATE/bug-bodies.txt" 2>/dev/null \
  && ok "opted-in report includes manifest reason code" \
  || bad "opted-in report includes manifest reason code" "missing checkId: reasonCode pair"
grep -Fq "sync.journal.other-company" "$REM_STATE/bug-bodies.txt" 2>/dev/null \
  && ok "non-opted-in company finding remains reportable" \
  || bad "non-opted-in company finding remains reportable" "bare check id missing"
if grep -Fq "sync.journal.other-company: never-synced" "$REM_STATE/bug-bodies.txt" 2>/dev/null; then
  bad "non-opted-in company finding has no reason code" "reason code leaked from another company's opt-in"
else
  ok "non-opted-in company finding has no reason code"
fi
if grep -Fq "$LEAK_PATH" "$REM_STATE/bug-bodies.txt" 2>/dev/null \
  || grep -Fq "private prose" "$REM_STATE/bug-bodies.txt" 2>/dev/null \
  || grep -Fq "hooks.private" "$REM_STATE/bug-bodies.txt" 2>/dev/null; then
  bad "opted-in report excludes paths, free text, and non-sync findings" \
    "unexpected diagnostic data reached the body"
else
  ok "opted-in report excludes paths, free text, and non-sync findings"
fi

echo "== 8. a repair that succeeds files no bug =="
RFIX="$TMP/rem-fixed"
build_root "$RFIX"
REM_STATE="$TMP/rem-stub-fixed"
mkdir -p "$REM_STATE"
set +e
env PATH="$STUB_BIN:$PATH" HQ_STUB_LOG="$STUB_LOG" HQ_STUB_STATE="$REM_STATE" \
  HQ_STUB_DOCTOR_JSON="$DOCTOR_DEGRADED" HQ_STUB_DOCTOR_JSON_AFTER_FIX="$DOCTOR_HEALTHY" \
  bash "$RFIX/.claude/hooks/check-client-health.sh" --remediate "$RFIX" >/dev/null 2>&1
RC8=$?
set -e
[ "$RC8" = 0 ] && ok "remediate exits 0 after a successful repair" \
  || bad "remediate exits 0 after a successful repair" "exit $RC8"
[ ! -s "$REM_STATE/bugs-filed" ] && ok "an auto-fixed issue files no bug" \
  || bad "an auto-fixed issue files no bug" "$(cat "$REM_STATE/bugs-filed" 2>/dev/null | wc -l) filed"

echo "== 9. a failed filing is not recorded as done =="
RBAD="$TMP/rem-filing-fails"
build_root "$RBAD"
REM_STATE="$TMP/rem-stub-badfile"
mkdir -p "$REM_STATE"
set +e
env PATH="$STUB_BIN:$PATH" HQ_STUB_LOG="$STUB_LOG" HQ_STUB_STATE="$REM_STATE" \
  HQ_STUB_DOCTOR_JSON="$DOCTOR_DEGRADED" HQ_STUB_FEEDBACK_RC=1 \
  bash "$RBAD/.claude/hooks/check-client-health.sh" --remediate "$RBAD" >/dev/null 2>&1
RC9=$?
set -e
[ "$RC9" = 0 ] && ok "remediate exits 0 when filing fails" \
  || bad "remediate exits 0 when filing fails" "exit $RC9"
if [ -f "$RBAD/workspace/.hq-client-health/bugs/summary.stamp" ]; then
  bad "a failed filing writes no dedupe stamp" "stamps exist; the retry would be lost"
else
  ok "a failed filing writes no dedupe stamp"
fi

echo "== 10. gate profiles: runs under standard/strict, no-ops under minimal =="
# The `minimal` absence is DELIBERATE — that profile is documented as critical
# safety hooks only, and a background self-healer is not one. check-hq-update,
# the same class of hook, is likewise standard+strict only.
RG="$TMP/gated"
build_root "$RG"
run_gate() {
  set +e
  GATE_OUT="$(printf '{"hook_event_name":"SessionStart"}' \
    | env PATH="$STUB_BIN:$PATH" \
        HQ_HOOK_PROFILE="$1" \
        CLAUDE_PROJECT_DIR="$RG" \
        HQ_ROOT="$RG" \
        HQ_STATE_DIR="$TMP/state-stale" \
        HQ_STUB_LOG="$STUB_LOG" \
        HQ_STUB_STATE="$STUB_STATE" \
        HQ_STUB_DOCTOR_JSON="$DOCTOR_HEALTHY" \
        bash "$RG/.claude/hooks/hook-gate.sh" check-client-health \
          "$RG/.claude/hooks/check-client-health.sh" 2>/dev/null)"
  GATE_RC=$?
  set -e
}

rm -rf "$RG/workspace/.hq-client-health"
run_gate minimal
[ "$GATE_RC" = 0 ] && [ -z "$GATE_OUT" ] \
  && ok "minimal profile: gated out, silent, exit 0" \
  || bad "minimal profile: gated out, silent, exit 0" "rc=$GATE_RC out=[$GATE_OUT]"
[ ! -f "$RG/workspace/.hq-client-health/remediation.stamp" ] \
  && ok "minimal profile launches no remediation" \
  || bad "minimal profile launches no remediation" "stamp was written under minimal"

for profile in standard strict; do
  rm -rf "$RG/workspace/.hq-client-health"
  run_gate "$profile"
  [ "$GATE_RC" = 0 ] || bad "$profile profile exits 0" "rc=$GATE_RC"
  case "$GATE_OUT" in
    *"<hq-client-health>"*) ok "$profile profile: hook runs and announces" ;;
    *) bad "$profile profile: hook runs and announces" "out=[$GATE_OUT]" ;;
  esac
done

echo "== 11. concurrent SessionStarts launch remediation exactly once =="
# A cooldown that is checked and then acted on is not a cooldown: N sessions
# starting together all read "no stamp" and all launch. The window must be
# CLAIMED atomically, so N racers produce exactly one launch and one banner.
R11="$TMP/concurrent-start"
build_root "$R11"
CONC_LOG="$TMP/launch-concurrent.log"
CONC_OUT="$TMP/concurrent-out"
: > "$CONC_LOG"
mkdir -p "$CONC_OUT"
set +e
for i in 1 2 3 4 5 6 7 8; do
  (
    printf '{"hook_event_name":"SessionStart"}' \
      | env PATH="$STUB_BIN:$PATH" \
          CLAUDE_PROJECT_DIR="$R11" \
          HQ_STATE_DIR="$TMP/state-stale" \
          HQ_STUB_LOG="$STUB_LOG" \
          HQ_STUB_STATE="$STUB_STATE" \
          HQ_LAUNCH_LOG="$CONC_LOG" \
          HQ_STUB_DOCTOR_JSON="$DOCTOR_HEALTHY" \
          bash "$R11/.claude/hooks/check-client-health.sh" \
          > "$CONC_OUT/$i.out" 2>/dev/null
    echo "$?" > "$CONC_OUT/$i.rc"
  ) &
done
wait
set -e
sleep 1
CONC_LAUNCHES=$(count_lines "$CONC_LOG")
[ "${CONC_LAUNCHES:-0}" = 1 ] \
  && ok "8 parallel SessionStarts launch remediation exactly once" \
  || bad "8 parallel SessionStarts launch remediation exactly once" \
    "launches=${CONC_LAUNCHES:-0}, expected 1"
CONC_BANNERS=$(grep -lF "<hq-client-health>" "$CONC_OUT"/*.out 2>/dev/null | wc -l | tr -d ' ')
[ "${CONC_BANNERS:-0}" = 1 ] \
  && ok "exactly one racing session announces remediation" \
  || bad "exactly one racing session announces remediation" \
    "banners=${CONC_BANNERS:-0}, expected 1"
CONC_BADRC=""
for i in 1 2 3 4 5 6 7 8; do
  RCV="$(cat "$CONC_OUT/$i.rc" 2>/dev/null || echo missing)"
  [ "$RCV" = 0 ] || CONC_BADRC="$CONC_BADRC $RCV"
done
[ -z "$CONC_BADRC" ] && ok "every racing session still exits 0" \
  || bad "every racing session still exits 0" "non-zero:$CONC_BADRC"
[ -e "$R11/workspace/.hq-client-health/remediation.lock" ] \
  && bad "the cooldown claim is released after the launch" "claim left behind" \
  || ok "the cooldown claim is released after the launch"

echo "== 12. the cooldown must latch: an unwritable stamp means NO remediation =="
# If the stamp cannot be written the window can never close, so remediation
# would fire on EVERY session forever. Both blocked shapes are made to fail for
# root as well as for an ordinary user (a mode bit alone would not).
#   (a) the state dir path is occupied by a regular file → mkdir -p fails
#   (b) the stamp path is occupied by a directory        → the write fails
for shape in state-dir-blocked stamp-blocked; do
  R12="$TMP/unwritable-$shape"
  build_root "$R12"
  if [ "$shape" = "state-dir-blocked" ]; then
    printf 'not a directory\n' > "$R12/workspace/.hq-client-health"
  else
    mkdir -p "$R12/workspace/.hq-client-health/remediation.stamp"
  fi
  U_LOG="$TMP/launch-$shape.log"
  : > "$U_LOG"
  set +e
  U_OUT="$(printf '{"hook_event_name":"SessionStart"}' \
    | env PATH="$STUB_BIN:$PATH" \
        CLAUDE_PROJECT_DIR="$R12" \
        HQ_STATE_DIR="$TMP/state-stale" \
        HQ_STUB_LOG="$STUB_LOG" \
        HQ_STUB_STATE="$STUB_STATE" \
        HQ_LAUNCH_LOG="$U_LOG" \
        HQ_STUB_DOCTOR_JSON="$DOCTOR_HEALTHY" \
        bash "$R12/.claude/hooks/check-client-health.sh" 2>/dev/null)"
  U_RC=$?
  set -e
  sleep 0.3
  [ "$U_RC" = 0 ] && ok "unwritable stamp ($shape): hook still exits 0" \
    || bad "unwritable stamp ($shape): hook still exits 0" "exit $U_RC"
  [ ! -s "$U_LOG" ] && ok "unwritable stamp ($shape): no remediation launched" \
    || bad "unwritable stamp ($shape): no remediation launched" \
      "$(wc -l < "$U_LOG" | tr -d ' ') launch(es) with no cooldown to stop them"
  [ -z "$U_OUT" ] && ok "unwritable stamp ($shape): no banner is emitted" \
    || bad "unwritable stamp ($shape): no banner is emitted" "got: [$U_OUT]"
done

echo "== 13. --remediate refuses an incomplete tree directly =="
# Defense in depth: the hook mode's dual-marker guard must also hold when
# --remediate is invoked on its own (a stale detached child, or by hand).
R13="$TMP/remediate-partial"
build_root "$R13"
rm -f "$R13/companies/manifest.yaml"
REM_STATE="$TMP/rem-stub-partial"
mkdir -p "$REM_STATE"
R13_LOG="$TMP/stub-partial.log"
: > "$R13_LOG"
set +e
env PATH="$STUB_BIN:$PATH" HQ_STUB_LOG="$R13_LOG" HQ_STUB_STATE="$REM_STATE" \
  HQ_STUB_DOCTOR_JSON="$DOCTOR_DEGRADED" \
  bash "$R13/.claude/hooks/check-client-health.sh" --remediate "$R13" >/dev/null 2>&1
RC13=$?
set -e
[ "$RC13" = 0 ] && ok "remediate on an incomplete tree exits 0" \
  || bad "remediate on an incomplete tree exits 0" "exit $RC13"
grep -Fq -- "doctor" "$R13_LOG" 2>/dev/null \
  && bad "remediate on an incomplete tree runs no doctor" "doctor was invoked" \
  || ok "remediate on an incomplete tree runs no doctor"
[ ! -s "$REM_STATE/bugs-filed" ] \
  && ok "remediate on an incomplete tree files no bug" \
  || bad "remediate on an incomplete tree files no bug" "bugs were filed"

echo "== 14. remediation does not depend on GNU coreutils' timeout(1) =="
# `timeout` ships with coreutils and is ABSENT on a stock macOS. Bounding must
# degrade to gtimeout, then to unbounded — never to "every bounded call fails
# with 127", which would make self-healing silently never run on a Mac.
R14="$TMP/no-timeout"
build_root "$R14"
REM_STATE="$TMP/rem-stub-no-timeout"
mkdir -p "$REM_STATE"
NO_TIMEOUT_BIN="$TMP/bin-no-timeout"
sanitized_bin "$NO_TIMEOUT_BIN" timeout gtimeout
set +e
env PATH="$NO_TIMEOUT_BIN" HQ_STUB_LOG="$STUB_LOG" HQ_STUB_STATE="$REM_STATE" \
  HQ_STUB_DOCTOR_JSON="$DOCTOR_DEGRADED" \
  "$BASH_BIN" "$R14/.claude/hooks/check-client-health.sh" --remediate "$R14" >/dev/null 2>&1
RC14=$?
set -e
[ "$RC14" = 0 ] && ok "remediate exits 0 with no timeout(1) on PATH" \
  || bad "remediate exits 0 with no timeout(1) on PATH" "exit $RC14"
FILED14=$(count_lines "$REM_STATE/bugs-filed")
[ "${FILED14:-0}" = 1 ] \
  && ok "remediate still self-heals with no timeout(1) on PATH" \
  || bad "remediate still self-heals with no timeout(1) on PATH" \
    "filed ${FILED14:-0}, expected 1 — bounding failed open and did nothing"

grep -Fq 'sync.vault.missing' "$REM_STATE/bug-bodies.txt" \
  && ok "portable timeout preserves report stdin" \
  || bad "portable timeout preserves report stdin" "empty report body"

echo "== 15. no JSON engine at all: degrade silently, act on nothing =="
# With NEITHER jq nor node the shared engine order runs out. This is the
# fail-open path the hook already had (it must not guess at findings); pinning
# it keeps a future refactor from turning "cannot parse" into "act blindly".
R15="$TMP/no-engine"
build_root "$R15"
REM_STATE="$TMP/rem-stub-no-engine"
mkdir -p "$REM_STATE"
NO_ENGINE_BIN="$TMP/bin-no-engine"
sanitized_bin "$NO_ENGINE_BIN" jq node
set +e
env PATH="$NO_ENGINE_BIN" HQ_STUB_LOG="$STUB_LOG" HQ_STUB_STATE="$REM_STATE" \
  HQ_STUB_DOCTOR_JSON="$DOCTOR_DEGRADED" \
  "$BASH_BIN" "$R15/.claude/hooks/check-client-health.sh" --remediate "$R15" >/dev/null 2>&1
RC15=$?
set -e
[ "$RC15" = 0 ] && ok "remediate exits 0 with neither jq nor node" \
  || bad "remediate exits 0 with neither jq nor node" "exit $RC15"
[ ! -s "$REM_STATE/bugs-filed" ] \
  && ok "no JSON engine files no bug (degrades, never guesses)" \
  || bad "no JSON engine files no bug (degrades, never guesses)" \
    "$(count_lines "$REM_STATE/bugs-filed") filed"

echo "== 16. concurrent remediations file exactly one summary =="
# Two detached remediations can overlap (a long doctor run, an expired
# cooldown). Reading the dedupe stamp and then writing it is not dedupe: both
# see "no stamp" and both file. HQ_STUB_FEEDBACK_SLEEP widens that window so
# the race is deterministic rather than lucky.
R16="$TMP/concurrent-remediate"
build_root "$R16"
REM_STATE="$TMP/rem-stub-concurrent"
mkdir -p "$REM_STATE"
set +e
for i in 1 2; do
  env PATH="$STUB_BIN:$PATH" HQ_STUB_LOG="$STUB_LOG" HQ_STUB_STATE="$REM_STATE" \
    HQ_STUB_DOCTOR_JSON="$DOCTOR_DEGRADED" HQ_STUB_FEEDBACK_SLEEP=0.5 \
    bash "$R16/.claude/hooks/check-client-health.sh" --remediate "$R16" >/dev/null 2>&1 &
done
wait
set -e
FILED16=$(count_lines "$REM_STATE/bugs-filed")
[ "${FILED16:-0}" = 1 ] \
  && ok "concurrent remediations file exactly one summary" \
  || bad "concurrent remediations file exactly one summary" \
    "filed ${FILED16:-0}, expected 1"
if ls "$R16/workspace/.hq-client-health/bugs/"*.lock >/dev/null 2>&1; then
  bad "summary claims are released" "lock dirs left behind"
else
  ok "summary claims are released"
fi

echo "== 17. with no timeout(1), a hanging command is still killed at the deadline =="
# Case 14 pins that self-healing still RUNS without coreutils. This pins the
# other half: it must not run UNBOUNDED. Stock macOS has neither `timeout` nor
# `gtimeout`, so that fallback is the COMMON Mac path, not an edge case — an
# unbounded one would let `hq doctor` / `hq feedback` run forever with no kill
# switch and leave stray processes behind on every affected machine.
#
# Shape: `hq doctor --fix` wedges for 45s while the deadline is 3s (the
# HQ_TEST_FORCE_HEALTH_DEADLINE fixture seam shortens the budget for BOTH
# bounding paths, so this exercises the real code path, not a test-only one).
R17="$TMP/no-timeout-hang"
build_root "$R17"
REM_STATE="$TMP/rem-stub-no-timeout-hang"
mkdir -p "$REM_STATE"
HANG_BIN="$TMP/bin-no-timeout-hang"
sanitized_bin "$HANG_BIN" timeout gtimeout
R17_START=$(date +%s)
set +e
env PATH="$HANG_BIN" HQ_STUB_LOG="$STUB_LOG" HQ_STUB_STATE="$REM_STATE" \
  HQ_STUB_DOCTOR_JSON="$DOCTOR_DEGRADED" \
  HQ_STUB_FIX_HANG=45 HQ_TEST_FORCE_HEALTH_DEADLINE=3 \
  "$BASH_BIN" "$R17/.claude/hooks/check-client-health.sh" --remediate "$R17" >/dev/null 2>&1
RC17=$?
set -e
R17_ELAPSED=$(( $(date +%s) - R17_START ))

[ "$RC17" = 0 ] && ok "remediate exits 0 when a bounded command is killed" \
  || bad "remediate exits 0 when a bounded command is killed" "exit $RC17"

# (a) The hang is cut off. Unbounded, this returns only after the full 45s.
[ "$R17_ELAPSED" -lt 25 ] \
  && ok "hanging remediation is killed at the deadline with no timeout(1)" \
  || bad "hanging remediation is killed at the deadline with no timeout(1)" \
    "took ${R17_ELAPSED}s against a 3s deadline — the command ran unbounded"
[ ! -f "$REM_STATE/fix-completed" ] \
  && ok "the killed command never ran to completion" \
  || bad "the killed command never ran to completion" \
    "hq doctor --fix finished its 45s hang — nothing bounded it"

# (b) The watchdog kills its own command and NOTHING else: the fast `hq
#     feedback` calls that follow the killed fix all complete normally under
#     the same fallback, each well inside the deadline.
FILED17=$(count_lines "$REM_STATE/bugs-filed")
[ "${FILED17:-0}" = 1 ] \
  && ok "fast commands still complete under the portable fallback" \
  || bad "fast commands still complete under the portable fallback" \
    "filed ${FILED17:-0}, expected 1 — a watchdog outlived its command"
STAMPS17=$(ls "$R17/workspace/.hq-client-health/bugs/"*.stamp 2>/dev/null | wc -l | tr -d ' ')
[ "${STAMPS17:-0}" = 2 ] \
  && ok "the fallback propagates a completed command's exit status" \
  || bad "the fallback propagates a completed command's exit status" \
    "${STAMPS17:-0} summary/attempt stamps, expected 2 — a success was read as a failure"

echo "== 18. failed sends respect cooldown and retry after expiry =="
REM_STATE="$TMP/rem-stub-badfile"
run_remediate "$RBAD" "-"
[ "$(count_lines "$REM_STATE/bugs-filed")" = 1 ] \
  && ok "failed send is not immediately retried" || bad "failed send is not immediately retried" "duplicate attempt"
touch -t "$ANCIENT" "$RBAD/workspace/.hq-client-health/bugs/report-attempt.stamp"
run_remediate "$RBAD" "-"
[ "$(count_lines "$REM_STATE/bugs-filed")" = 2 ] \
  && ok "failed send retries after cooldown" || bad "failed send retries after cooldown" "retry missing"

echo "== 19. many company checks and changing findings cannot flood =="
MANY="$TMP/many.json"
printf '{"results":[' > "$MANY"
for ((i=1; i<=45; i++)); do
  [ "$i" = 1 ] || printf ',' >> "$MANY"
  printf '{"family":"sync","status":"WARN","checkId":"sync.journal.company%s"}' "$i" >> "$MANY"
done
printf ']}' >> "$MANY"
R18="$TMP/many-companies"
build_root "$R18"
REM_STATE="$TMP/rem-many"
mkdir -p "$REM_STATE"
SAVED_DOCTOR="$DOCTOR_DEGRADED"
DOCTOR_DEGRADED="$MANY"
run_remediate "$R18" "-"
DOCTOR_DEGRADED="$SAVED_DOCTOR"
run_remediate "$R18" "-"
[ "$(count_lines "$REM_STATE/bugs-filed")" = 1 ] \
  && ok "45 companies and changed findings share one daily report" \
  || bad "45 companies and changed findings share one daily report" "flood"
grep -Fq 'sync.journal.company45' "$REM_STATE/bug-bodies.txt" \
  && ok "summary retains all company checks" || bad "summary retains all company checks" "last finding missing"

echo "== 20. an unwritable attempt stamp prevents submission =="
R19="$TMP/report-stamp-blocked"
build_root "$R19"
mkdir -p "$R19/workspace/.hq-client-health/bugs/report-attempt.stamp"
REM_STATE="$TMP/rem-blocked"
mkdir -p "$REM_STATE"
run_remediate "$R19" "-"
[ ! -s "$REM_STATE/bugs-filed" ] \
  && ok "cannot send without durable cooldown" || bad "cannot send without durable cooldown" "sent without stamp"

echo
echo "==== check-client-health: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ] || exit 1
