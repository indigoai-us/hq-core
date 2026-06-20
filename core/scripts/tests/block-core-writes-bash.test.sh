#!/usr/bin/env bash
# hq-core: public
# Regression tests for block-core-writes-bash.sh.
#
# Covers:
#   - common write shapes into protected scaffold dirs stay blocked;
#   - the 2026-06-14 boundary fix: VAR=<protected path> assignments and
#     colon-joined paths are now caught (previously slipped through because
#     '=' / ':' were not treated as token boundaries);
#   - .claude/settings.local.json remains writable;
#   - companies/_template/ (a locked path per core.yaml) is blocked, while a
#     real tenant dir (companies/<co>/) stays writable;
#   - the settings.local.json HQ_BYPASS_CORE_PROTECT escape hatch still works
#     (it is consent-gated by messaging, not removed).

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/block-core-writes-bash.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.claude" "$TMP/core/packages/x" "$TMP/personal" "$TMP/repos/private/app" "$TMP/companies/_template/knowledge" "$TMP/companies/acme/data"
printf '{}' > "$TMP/.claude/settings.local.json"   # no bypass by default

PASS=0
FAIL=0

# run <expected_exit> <command> <label>
run() {
  local expect="$1" cmd="$2" label="$3" rc=0 payload
  payload=$(jq -n --arg cmd "$cmd" '{tool_input: {command: $cmd}}')
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [$label]: expected exit $expect, got $rc -- cmd: $cmd" >&2
  fi
}

C="$TMP/core/packages/x"

# --- Blocked: common write shapes ----------------------------------------
run 2 "mv /tmp/y $C/s.json"                  'absolute mv into core blocked'
run 2 "cd $C && mv /tmp/y s.json"            'cd abs-core + relative mv blocked'
run 2 "cd core/packages/x && mv /tmp/y s"    'cd rel-core + relative mv blocked'
run 2 "echo hi > $C/s.json"                  'redirect into abs core blocked'
run 2 "printf x >> core/packages/x/s"        'append into rel core blocked'
run 2 "cp /tmp/y $TMP/.claude/h.sh"          'cp into .claude blocked'
run 2 "touch $TMP/.codex/x"                  'touch into .codex blocked'
run 2 "touch $TMP/companies/_template/x"                   'touch into abs companies/_template blocked'
run 2 "echo x > companies/_template/seed.md"              'redirect into rel companies/_template blocked'
run 2 "cp /tmp/y $TMP/companies/_template/knowledge/k.md" 'cp into companies/_template blocked'

# --- Blocked: 2026-06-14 boundary fix (= and : are boundaries) -----------
run 2 "D=$C; mv /tmp/y \"\$D/s.json\""       'VAR=core-path assignment + mv blocked (boundary fix)'
run 2 "P=/x:$TMP/core/y; cp /tmp/z \$P"      'colon-joined core path + cp blocked (boundary fix)'

# --- Allowed: exceptions and non-protected targets -----------------------
run 0 "echo x > $TMP/.claude/settings.local.json"  'settings.local.json writable'
run 0 "mv /tmp/y $TMP/repos/private/app/s"         'write into repos/ allowed'
run 0 "mv /tmp/y $TMP/personal/p.md"               'write into personal/ allowed'
run 0 "cat $C/s.json"                              'read-only cat of core allowed'
run 0 "ls $TMP/core"                               'read-only ls of core allowed'
run 0 "mv /tmp/y $TMP/companies/acme/data/r.md"    'write into a real tenant (not _template) allowed'

# --- Allowed: settings.local.json bypass still works ---------------------
printf '{"env":{"HQ_BYPASS_CORE_PROTECT":"1"}}' > "$TMP/.claude/settings.local.json"
run 0 "mv /tmp/y $C/s.json"                  'bypass flag set -> core write allowed'
printf '{}' > "$TMP/.claude/settings.local.json"

echo "block-core-writes-bash: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
