#!/bin/bash
# hq-core: public
# migrate-policy-triggers-if-changed.sh — SessionStart hook.
#
# Runs core/scripts/migrate-policy-triggers.sh (the generated forwarder to
# `hq core migrate-policy-triggers`) only when a policy file or policy
# directory changed since the last successful run. The migration is idempotent
# over policy files, so an unchanged tree has nothing to do, and starting the hq
# CLI twice (version-floor probe + command) costs every session about 2 s.
#
# Re-runs when:
#   * any file or directory under core/policies, personal/policies,
#     companies/*/policies, companies/*/workers/*/policies, or
#     personal/workers/*/policies is newer than the stamp
#   * the hq binary is newer than the stamp (migration rules ship with hq)
#   * HQ_MIGRATE_TRIGGERS_FORCE=1
#   * no stamp exists yet
#
# The stamp is dated from BEFORE the run and kept only on exit 0, so a failing
# run, or a policy edited while the migration was running, is never masked.
# The forwarder itself is untouched: its ABI (and the cli-hosted manifest that
# generates it) stay exactly as shipped. hq-hook-perf HP-7.

set -uo pipefail

# Consume stdin (master-hook pipes the event JSON).
cat >/dev/null 2>&1 || true

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd)}}"
[ -n "$HQ_ROOT" ] || exit 0

FORWARDER="$HQ_ROOT/core/scripts/migrate-policy-triggers.sh"
[ -f "$FORWARDER" ] || exit 0

STATE_DIR="$HQ_ROOT/workspace/orchestrator/policy-trigger-state"
STAMP="$STATE_DIR/migrate-policy-triggers.stamp"

if [ "${HQ_MIGRATE_TRIGGERS_FORCE:-0}" != "1" ] && [ -f "$STAMP" ]; then
  hq_bin="$(command -v hq 2>/dev/null || true)"
  if [ -z "$hq_bin" ] || [ ! "$hq_bin" -nt "$STAMP" ]; then
    changed="$(find "$HQ_ROOT/core/policies" "$HQ_ROOT/personal/policies" \
      "$HQ_ROOT"/companies/*/policies "$HQ_ROOT"/companies/*/workers/*/policies \
      "$HQ_ROOT"/personal/workers/*/policies \
      -newer "$STAMP" \( -type d -o -type f -name '*.md' \) -print 2>/dev/null | head -n 1 || true)"
    [ -n "$changed" ] || exit 0
  fi
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true
: > "$STAMP.new" 2>/dev/null || true
rc=0
bash "$FORWARDER" </dev/null || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$STAMP.new" ]; then
  mv -f "$STAMP.new" "$STAMP" 2>/dev/null || true
else
  rm -f "$STAMP.new" 2>/dev/null || true
fi
exit "$rc"
