#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/core/hooks/SessionStart/20-setup-completeness-nag.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
state_key() {
  local state_key
  state_key="$(printf '%s\n' "$1" | cksum)"
  printf '%s\n' "${state_key%% *}"
}

make_fixture() {
  local root="$1" result="$2" status_rc="$3"
  mkdir -p "$root/core/scripts"
  printf 'hqVersion: "15.0.131"\n' > "$root/core/core.yaml"
  cat > "$root/core/scripts/setup-status.sh" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >> "$SETUP_CALLS"
printf '%s\n' "$SETUP_JSON"
exit "$SETUP_RC"
EOF
  chmod +x "$root/core/scripts/setup-status.sh"
  : > "$TMP/$result.calls"
}

run_nag() {
  local root="$1" label="$2" result="$3" status_rc="$4" output rc=0
  output="$TMP/$label.out"
  env -u CI \
    HOME="$TMP/home" \
    XDG_STATE_HOME="$TMP/state" \
    HQ_SETUP_NAG_STATE_DIR="$TMP/state/hq" \
    CLAUDE_PROJECT_DIR="$root" \
    SETUP_CALLS="$TMP/$result.calls" \
    SETUP_RC="$status_rc" \
    bash "$HOOK" </dev/null > "$output" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label returned $rc instead of 0"
  if [ "$result" = incomplete ] && [ "$label" = "$result-1" ]; then
    jq -e '.hookSpecificOutput.additionalContext == "HQ setup is unfinished: missing profile. Run /setup to finish it. Silence this reminder with HQ_NO_SETUP_NAG=1."' "$output" >/dev/null \
      || fail "$label changed the setup reminder output"
  else
    [ ! -s "$output" ] || fail "$label unexpectedly emitted a reminder"
  fi
}

INCOMPLETE="$TMP/incomplete"
make_fixture "$INCOMPLETE" incomplete 1
export SETUP_JSON='{"complete":false,"missingRequired":["profile"]}' SETUP_RC=1 SETUP_CALLS="$TMP/incomplete.calls"
for run in 1 2 3 4 5; do
  run_nag "$INCOMPLETE" "incomplete-$run" incomplete 1
done
incomplete_calls="$(wc -l < "$TMP/incomplete.calls" | tr -d '[:space:]')"
[ "$incomplete_calls" = 1 ] \
  || fail "setup-status should be checked once per day for incomplete setup; got $incomplete_calls calls"

COMPLETE="$TMP/complete"
make_fixture "$COMPLETE" complete 0
export SETUP_JSON='{"complete":true,"missingRequired":[]}' SETUP_RC=0 SETUP_CALLS="$TMP/complete.calls"
for run in 1 2 3; do
  run_nag "$COMPLETE" "complete-$run" complete 0
done
complete_calls="$(wc -l < "$TMP/complete.calls" | tr -d '[:space:]')"
[ "$complete_calls" = 1 ] \
  || fail "setup-status should be checked once per day for complete setup; got $complete_calls calls"

UNAVAILABLE="$TMP/unavailable"
make_fixture "$UNAVAILABLE" unavailable 2
export SETUP_JSON='{}' SETUP_RC=2 SETUP_CALLS="$TMP/unavailable.calls"
for run in 1 2; do
  run_nag "$UNAVAILABLE" "unavailable-$run" unavailable 2
done
unavailable_calls="$(wc -l < "$TMP/unavailable.calls" | tr -d '[:space:]')"
[ "$unavailable_calls" = 1 ] \
  || fail "unavailable setup status should be checked once per day; got $unavailable_calls calls"

# Q47: a collect-only machine-check batch (HQ_MACHINE_CHECK=1 and
# HQ_MACHINE_CHECK_COLLECT_ONLY=1) prints the reminder but writes no delivery
# stamp, so the session that shows it still can. The stamp is still the probe
# throttle for complete and unavailable results.
nag_once() { # nag_once <root> <out> [env...]
  local root="$1" out="$2"; shift 2
  env -u CI -u HQ_MACHINE_CHECK -u HQ_MACHINE_CHECK_COLLECT_ONLY \
    HOME="$TMP/home" XDG_STATE_HOME="$TMP/q47-state" HQ_SETUP_NAG_STATE_DIR="$TMP/q47-state/hq" \
    CLAUDE_PROJECT_DIR="$root" "$@" bash "$HOOK" </dev/null > "$out" || fail "nag returned non-zero"
}
REMINDER_TEXT="HQ setup is unfinished: missing profile. Run /setup to finish it. Silence this reminder with HQ_NO_SETUP_NAG=1."
has_reminder() { jq -e --arg t "$REMINDER_TEXT" '.hookSpecificOutput.additionalContext == $t' "$1" >/dev/null 2>&1; }

Q47_INCOMPLETE="$TMP/q47-incomplete"
make_fixture "$Q47_INCOMPLETE" q47-incomplete 1
export SETUP_JSON='{"complete":false,"missingRequired":["profile"]}' SETUP_RC=1 SETUP_CALLS="$TMP/q47-incomplete.calls"
Q47_STAMP="$TMP/q47-state/hq/setup-completeness-nag.$(state_key "$Q47_INCOMPLETE").last"
for batch in 1 2 3; do
  nag_once "$Q47_INCOMPLETE" "$TMP/q47-batch-$batch.out" HQ_MACHINE_CHECK=1 HQ_MACHINE_CHECK_COLLECT_ONLY=1
  has_reminder "$TMP/q47-batch-$batch.out" || fail "collect-only batch $batch did not print the reminder"
  [ ! -e "$Q47_STAMP" ] || fail "collect-only batch $batch wrote the delivery stamp"
done
# While a reminder is due, the status probe still runs once per interval, not
# once per (hourly) batch.
q47_calls="$(wc -l < "$TMP/q47-incomplete.calls" | tr -d '[:space:]')"
[ "$q47_calls" = 1 ] || fail "collect-only batches probed setup status $q47_calls times while a reminder was due; want 1"
nag_once "$Q47_INCOMPLETE" "$TMP/q47-session-1.out"
has_reminder "$TMP/q47-session-1.out" || fail "the session after collect-only batches did not show the reminder"
[ -s "$Q47_STAMP" ] || fail "the session that showed the reminder wrote no delivery stamp"
[ ! -e "${Q47_STAMP%.last}.collected" ] || fail "delivery left the collected reminder cache behind"
nag_once "$Q47_INCOMPLETE" "$TMP/q47-session-2.out"
[ ! -s "$TMP/q47-session-2.out" ] || fail "the reminder was shown again inside the cooldown"
nag_once "$Q47_INCOMPLETE" "$TMP/q47-batch-3.out" HQ_MACHINE_CHECK=1 HQ_MACHINE_CHECK_COLLECT_ONLY=1
[ ! -s "$TMP/q47-batch-3.out" ] || fail "a collect-only batch inside the cooldown reported the shown reminder again"

# Normal delivery writes the stamp only after the reminder is out: with stdout
# closed the reminder cannot be delivered, so no cooldown starts.
Q47_CLOSED="$TMP/q47-closed"
make_fixture "$Q47_CLOSED" q47-closed 1
export SETUP_CALLS="$TMP/q47-closed.calls"
Q47_CLOSED_STAMP="$TMP/q47-state/hq/setup-completeness-nag.$(state_key "$Q47_CLOSED").last"
env -u CI -u HQ_MACHINE_CHECK -u HQ_MACHINE_CHECK_COLLECT_ONLY \
  HOME="$TMP/home" XDG_STATE_HOME="$TMP/q47-state" HQ_SETUP_NAG_STATE_DIR="$TMP/q47-state/hq" \
  CLAUDE_PROJECT_DIR="$Q47_CLOSED" bash "$HOOK" </dev/null >&- || fail "nag with closed stdout returned non-zero"
[ ! -e "$Q47_CLOSED_STAMP" ] || fail "a reminder that could not be written still started the cooldown"

# A batch without the collect-only marker (an older hq-cli) is unchanged: it
# writes the stamp when it prints.
Q47_OLD="$TMP/q47-old-cli"
make_fixture "$Q47_OLD" q47-old-cli 1
export SETUP_CALLS="$TMP/q47-old-cli.calls"
nag_once "$Q47_OLD" "$TMP/q47-old.out" HQ_MACHINE_CHECK=1
has_reminder "$TMP/q47-old.out" || fail "a batch without collect-only did not print the reminder"
[ -s "$TMP/q47-state/hq/setup-completeness-nag.$(state_key "$Q47_OLD").last" ] \
  || fail "a batch without collect-only no longer writes the stamp"

# Operational throttle unchanged in collect-only: complete and unavailable
# results still stamp, so the probe runs once per day.
for kind in complete unavailable; do
  Q47_ROOT="$TMP/q47-$kind"
  if [ "$kind" = complete ]; then rc=0; json='{"complete":true,"missingRequired":[]}'; else rc=2; json='{}'; fi
  make_fixture "$Q47_ROOT" "q47-$kind" "$rc"
  export SETUP_JSON="$json" SETUP_RC="$rc" SETUP_CALLS="$TMP/q47-$kind.calls"
  for batch in 1 2 3; do
    nag_once "$Q47_ROOT" "$TMP/q47-$kind-$batch.out" HQ_MACHINE_CHECK=1 HQ_MACHINE_CHECK_COLLECT_ONLY=1
    [ ! -s "$TMP/q47-$kind-$batch.out" ] || fail "collect-only $kind run $batch printed something"
  done
  calls="$(wc -l < "$TMP/q47-$kind.calls" | tr -d '[:space:]')"
  [ "$calls" = 1 ] || fail "collect-only $kind: the probe throttle changed; got $calls calls"
done

printf 'PASS: setup completeness is checked once per day with unchanged reminder output\n'
printf 'PASS: a collect-only batch leaves the delivery stamp to the session that shows the reminder\n'
