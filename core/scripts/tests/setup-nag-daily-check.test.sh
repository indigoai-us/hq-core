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

printf 'PASS: setup completeness is checked once per day with unchanged reminder output\n'
