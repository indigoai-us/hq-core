#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hq" <<'SH'
#!/bin/bash
printf 'query\n' >> "$CALLS"
case "$MODE" in
  daemon) printf '{"schema":"hq-machine-check-owner.v1","owner":"daemon"}\n' ;;
  legacy) printf '{"schema":"hq-machine-check-owner.v1","owner":"legacy"}\n' ;;
  malformed) printf '{}\n{}\n' ;;
  failed) exit 1 ;;
  slow) sleep 4 ;;
esac
SH
chmod +x "$TMP/bin/hq"
export PATH="$TMP/bin:$PATH" CALLS="$TMP/calls"
export REPO_ROOT="$ROOT" ACTIVE_COMPANY='' MODE=daemon
# Isolated home: the daemon results file, the native SessionStart registration
# and the legacy-answer stamp all live under it.
export HOME="$TMP/home"
unset HQ_DAEMON_DIR CLAUDE_CONFIG_DIR CODEX_HOME HQ_MACHINE_CHECK_OWNER_TRACE
RESULTS="$HOME/.hq/daemon/machine-checks.json"
mkdir -p "$HOME/.hq/daemon" "$HOME/.claude"
printf '%s\n' "{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"hq core-next 'run' '--host' 'claude' 'SessionStart'\"}]}]}}" > "$HOME/.claude/settings.json"
fresh_results() { printf '{"results":[]}\n' > "$RESULTS"; }
reset_owner() { MASTER_MACHINE_CHECK_OWNER=unknown; rm -f "$HOME"/.hq/machine-check-owner.legacy.*; : > "$CALLS"; }
calls() { wc -l < "$CALLS" | tr -d ' '; }
fresh_results
: > "$CALLS"
. "$ROOT/.claude/hooks/machine-check-owner.sh"
master_machine_check_owned_by_daemon SessionStart .claude/hooks/check-hq-update.sh
master_machine_check_owned_by_daemon UserPromptSubmit core/hooks/UserPromptSubmit/30-ensure-hq-cli.sh
for relative in .claude/hooks/check-client-health.sh .claude/hooks/check-stale-model-pin.sh \
  .claude/hooks/check-claude-desktop-bridge-health.sh .claude/hooks/repair-stale-review-base.sh \
  .claude/hooks/welcome-brief-ready.sh core/scripts/refresh-vault-access-session-start.sh \
  core/hooks/SessionStart/20-setup-completeness-nag.sh core/hooks/SessionStart/40-fingerprint-hooks-enable.sh \
  core/hooks/SessionStart/50-agent-browser-presence-check.sh; do
  master_machine_check_owned_by_daemon SessionStart "$relative"
done
master_machine_check_owned_by_daemon UserPromptSubmit core/hooks/UserPromptSubmit/31-ensure-hq-desktop.sh
[ "$(wc -l < "$CALLS" | tr -d ' ')" = 1 ]
if master_machine_check_owned_by_daemon PreToolUse .claude/hooks/check-hq-update.sh; then exit 1; fi
if master_machine_check_owned_by_daemon SessionStart .claude/hooks/unrelated.sh; then exit 1; fi
for MODE in legacy malformed failed slow; do
  export MODE
  reset_owner
  if master_machine_check_owned_by_daemon SessionStart .claude/hooks/check-hq-update.sh; then
    printf 'FAIL: %s suppressed the legacy check\n' "$MODE" >&2; exit 1
  fi
done
UPS=core/hooks/UserPromptSubmit/30-ensure-hq-cli.sh
expect_legacy_without_query() {
  reset_owner
  if master_machine_check_owned_by_daemon UserPromptSubmit "$UPS"; then
    printf 'FAIL: %s still skipped the legacy check\n' "$1" >&2; exit 1
  fi
  [ "$(calls)" = 0 ] || { printf 'FAIL: %s still started hq\n' "$1" >&2; exit 1; }
}
# Precheck: without a fresh results file or a native SessionStart registration
# the CLI would answer legacy, so it is not started at all.
export MODE=daemon
rm -f "$RESULTS"
expect_legacy_without_query 'no results file'
fresh_results; python3 -c 'import os, sys; os.utime(sys.argv[1], (999999999, 999999999))' "$RESULTS"
expect_legacy_without_query 'stale results file'
fresh_results; mv "$HOME/.claude/settings.json" "$TMP/settings.json"
expect_legacy_without_query 'no native SessionStart'
mv "$TMP/settings.json" "$HOME/.claude/settings.json"
HQ_DAEMON_DIR="$TMP/elsewhere" expect_legacy_without_query 'results outside HQ_DAEMON_DIR'
# Negative cache: a legacy answer is reused by the next event (a new master-hook
# process), so hq starts once per window instead of once per prompt.
for MODE in legacy failed; do
  export MODE
  reset_owner
  if master_machine_check_owned_by_daemon UserPromptSubmit "$UPS"; then exit 1; fi
  MASTER_MACHINE_CHECK_OWNER=unknown
  if master_machine_check_owned_by_daemon UserPromptSubmit "$UPS"; then exit 1; fi
  [ "$(calls)" = 1 ] || { printf 'FAIL: cached %s answer started hq again\n' "$MODE" >&2; exit 1; }
done
# An expired stamp asks again.
for stamp in "$HOME"/.hq/machine-check-owner.legacy.*; do printf '999999999\n' > "$stamp"; done
MASTER_MACHINE_CHECK_OWNER=unknown
if master_machine_check_owned_by_daemon UserPromptSubmit "$UPS"; then exit 1; fi
[ "$(calls)" = 2 ] || { echo 'FAIL: expired legacy stamp did not ask hq again' >&2; exit 1; }
# Daemon owns: skip as before, and a daemon answer is never stamped.
export MODE=daemon
reset_owner
master_machine_check_owned_by_daemon UserPromptSubmit "$UPS"
[ "$(calls)" = 1 ] || { echo 'FAIL: daemon answer needed one query' >&2; exit 1; }
if ls "$HOME"/.hq/machine-check-owner.legacy.* >/dev/null 2>&1; then echo 'FAIL: daemon answer wrote a legacy stamp' >&2; exit 1; fi
# Exercise both master dispatch paths with harmless scripts in an isolated tree.
FIX="$TMP/root"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts" "$FIX/core/hooks/SessionStart" "$FIX/workspace"
for name in master-hook.sh hook-gate.sh hook-timeout-probe.sh hook-timeout-watchdog.sh machine-check-owner.sh; do
  cp "$ROOT/.claude/hooks/$name" "$FIX/.claude/hooks/$name"
done
cp "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$FIX/core/scripts/"
printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"id":"check-hq-update","script":".claude/hooks/check-hq-update.sh","gated":false}]}]}}' > "$FIX/.claude/hooks/hook-registry.json"
printf '#!/bin/bash\nprintf "registry\\n" >> "$BODY_CALLS"\n' > "$FIX/.claude/hooks/check-hq-update.sh"
printf '#!/bin/bash\nprintf "directory\\n" >> "$BODY_CALLS"\n' > "$FIX/core/hooks/SessionStart/20-setup-completeness-nag.sh"
chmod +x "$FIX/.claude/hooks/check-hq-update.sh" "$FIX/core/hooks/SessionStart/20-setup-completeness-nag.sh"
export BODY_CALLS="$TMP/body-calls" TRACE="$TMP/trace"
for MODE in daemon legacy; do
  export MODE
  reset_owner; : > "$BODY_CALLS"; : > "$TRACE"
  rc=0
  printf '{"session_id":"owner-test","hook_event_name":"SessionStart"}' | \
    env CLAUDE_PROJECT_DIR="$FIX" HQ_ROOT="$FIX" HQ_HOOK_DEDUPE=0 HQ_HOOK_TIMEOUT_SENTRY=0 \
    HQ_MACHINE_CHECK_OWNER_TRACE="$TRACE" \
    bash "$FIX/.claude/hooks/master-hook.sh" SessionStart > "$TMP/out" 2> "$TMP/err" || rc=$?
  [ "$rc" = 0 ] || { printf 'FAIL: master-hook exited %s in %s mode\n' "$rc" "$MODE" >&2; exit 1; }
  [ "$(calls)" = 1 ] || { printf 'FAIL: %s mode made %s owner queries, want 1\n' "$MODE" "$(calls)" >&2; exit 1; }
  if [ "$MODE" = daemon ]; then
    [ ! -s "$BODY_CALLS" ] || { echo 'FAIL: daemon-owned checks still ran' >&2; exit 1; }
    # Positive proof that both dispatch loops reached the skip decision, so an
    # early exit cannot pass for "skipped".
    grep -qx 'skip SessionStart:.claude/hooks/check-hq-update.sh' "$TRACE" || { echo 'FAIL: registry loop did not reach the skip' >&2; exit 1; }
    grep -qx 'skip SessionStart:core/hooks/SessionStart/20-setup-completeness-nag.sh' "$TRACE" || { echo 'FAIL: directory loop did not reach the skip' >&2; exit 1; }
  else
    [ ! -s "$TRACE" ] || { echo 'FAIL: legacy mode recorded a skip' >&2; exit 1; }
    grep -qx registry "$BODY_CALLS"
    grep -qx directory "$BODY_CALLS"
  fi
done
python3 - "$ROOT" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
registry=json.loads((root/'.claude/hooks/hook-registry.json').read_text())
# Regression: policies that arrive by sync, CLI update or hand edit must still
# get their triggers backfilled, so a SessionStart path must run the migration.
ss=[h for g in registry['hooks']['SessionStart'] for h in g.get('hooks', [])]
mig=[h for h in ss if h.get('script') == '.claude/hooks/migrate-policy-triggers-if-changed.sh']
assert len(mig) == 1, 'SessionStart must register migrate-policy-triggers-if-changed.sh'
assert mig[0].get('id') == 'migrate-policy-triggers'
assert '.claude/hooks/migrate-policy-triggers-if-changed.sh' not in (root/'.claude/hooks/machine-check-owner.sh').read_text(), 'the backfill is not a daemon-owned machine check'
skill=(root/'.claude/skills/update-hq/SKILL.md').read_text()
# US-043: the skill runs the hq core twin with the selected root.
mig_cmd = 'HQ_ROOT={hq-root} hq core migrate-policy-triggers\n'
assert skill.index('hq rescue -y {mapped-flags}') < skill.index(mig_cmd) < skill.index('bash core/scripts/check-hq-hooks.sh --root')
assert '\nbash core/scripts/migrate-policy-triggers.sh' not in skill, 'the migration must target the selected --hq-root'
assert '\nhq core migrate-policy-triggers' not in skill, 'the migration must target the selected --hq-root'
assert 'Bash(HQ_ROOT={hq-root} hq core migrate-policy-triggers:*)' in skill
master=(root/'.claude/hooks/master-hook.sh').read_text()
assert 'master_machine_check_owned_by_daemon "$EVENT" "$rscript"' in master
assert 'master_machine_check_owned_by_daemon "$EVENT" "${hook#"$REPO_ROOT/"}"' in master
PY
# Behaviour: a policy added after the last run makes the SessionStart hook run
# the backfill forwarder; an unchanged tree does not.
MIG="$TMP/mig"
mkdir -p "$MIG/.claude/hooks" "$MIG/core/scripts" "$MIG/personal/policies" "$MIG/core/policies"
cp "$ROOT/.claude/hooks/migrate-policy-triggers-if-changed.sh" "$MIG/.claude/hooks/"
printf '#!/bin/bash\nprintf "ran\\n" >> "$MIG_CALLS"\n' > "$MIG/core/scripts/migrate-policy-triggers.sh"
export MIG_CALLS="$TMP/mig-calls"
: > "$MIG_CALLS"
run_mig() { HQ_ROOT="$MIG" bash "$MIG/.claude/hooks/migrate-policy-triggers-if-changed.sh" </dev/null; }
run_mig
[ "$(wc -l < "$MIG_CALLS" | tr -d ' ')" = 1 ] || { echo 'FAIL: first SessionStart did not backfill' >&2; exit 1; }
run_mig
[ "$(wc -l < "$MIG_CALLS" | tr -d ' ')" = 1 ] || { echo 'FAIL: unchanged tree re-ran the backfill' >&2; exit 1; }
sleep 1
printf -- '---\nid: synced\nenforcement: hard\n---\nrule\n' > "$MIG/personal/policies/synced.md"
run_mig
[ "$(wc -l < "$MIG_CALLS" | tr -d ' ')" = 2 ] || { echo 'FAIL: a new policy without triggers was not backfilled at SessionStart' >&2; exit 1; }
# Q47: core.yaml advertises the collect-only contract that hq-cli's daemon
# batch keys on, and every machine-check script with a show-once record reads
# the marker. Removing either silently turns hq-cli back to stamping batches.
grep -Eq '^machineCheckCollectOnly: 1$' "$ROOT/core/core.yaml" \
  || { echo 'FAIL: core/core.yaml does not advertise machineCheckCollectOnly: 1' >&2; exit 1; }
for script in core/hooks/SessionStart/20-setup-completeness-nag.sh .claude/hooks/welcome-brief-ready.sh \
    .claude/hooks/check-client-health.sh core/hooks/UserPromptSubmit/31-ensure-hq-desktop.sh; do
  grep -Fq 'HQ_MACHINE_CHECK_COLLECT_ONLY:-}" = "1"' "$ROOT/$script" \
    || { echo "FAIL: $script does not honour HQ_MACHINE_CHECK_COLLECT_ONLY" >&2; exit 1; }
done
printf 'PASS: machine-check ownership is prechecked from files, bounded, cached per event and per minute when legacy, exact-path-only and legacy on failure; backfill runs at SessionStart (hash-gated) and after update\n'
