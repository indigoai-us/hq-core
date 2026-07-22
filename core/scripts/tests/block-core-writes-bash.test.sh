#!/usr/bin/env bash
# hq-core: public
# Regression tests for block-core-writes-bash.sh.
#
# Covers:
#   - common write shapes into protected scaffold dirs stay blocked;
#   - the 2026-06-14 boundary fix: VAR=<protected path> assignments and
#     colon-joined paths are now caught (previously slipped through because
#     '=' / ':' were not treated as token boundaries);
#   - .claude/settings.local.json and the durable personal context remain writable;
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
run 2 "cp /tmp/y $C/s.json"                  'cp into core still blocked'
run 2 "mv $C/old.md /tmp/old.md"             'mv out of core blocked'
run 2 "rm -rf $C"                            'rm -rf core blocked'
run 2 "cp -t $C /tmp/a /tmp/b"               'cp -t target-dir into core blocked'
run 2 "tee $TMP/.claude/x < /tmp/in"         'tee into .claude blocked'
run 2 "sed -i 's/a/b/' $C/p.md"              'sed -i editing core blocked'
run 2 "touch $C/new"                         'touch into core blocked'

# --- Blocked: 2026-06-14 boundary fix (= and : are boundaries) -----------
run 2 "D=$C; mv /tmp/y \"\$D/s.json\""       'VAR=core-path assignment + mv blocked (boundary fix)'
run 2 "P=/x:$TMP/core/y; cp /tmp/z \$P"      'colon-joined core path + cp blocked (boundary fix)'

# --- Allowed: exceptions and non-protected targets -----------------------
run 0 "echo x > $TMP/.claude/settings.local.json"  'settings.local.json writable'
run 0 "echo x > $TMP/.claude/personal-context.md"   'personal-context.md writable'
run 0 "mv /tmp/y $TMP/repos/private/app/s"         'write into repos/ allowed'
run 0 "mv /tmp/y $TMP/personal/p.md"               'write into personal/ allowed'
run 0 "cat $C/s.json"                              'read-only cat of core allowed'
run 0 "ls $TMP/core"                               'read-only ls of core allowed'
run 0 "mv /tmp/y $TMP/companies/acme/data/r.md"    'write into a real tenant (not _template) allowed'
run 0 "cp $C/a.md /tmp/a.md"                       'cp out of core to tmp allowed'
run 0 "cp $TMP/.claude/hooks/x.sh /tmp/b.sh"       'cp out of .claude to tmp allowed'
run 0 "touch /tmp/marker && cat $C/p.md"           'touch tmp + read core allowed'
run 0 "rm /tmp/scratch; grep -l foo $C/p.md"       'rm tmp + grep core allowed'
run 0 "sed -i 's|core/|X|' /tmp/f"                 'sed script mentions core, target tmp allowed'
run 0 "cp $C/a.md /tmp/ && rm -f /tmp/a.md"        'core read + tmp cleanup allowed'

# --- Allowed: settings.local.json bypass still works ---------------------
printf '{"env":{"HQ_BYPASS_CORE_PROTECT":"1"}}' > "$TMP/.claude/settings.local.json"
run 0 "mv /tmp/y $C/s.json"                  'bypass flag set -> core write allowed'
printf '{}' > "$TMP/.claude/settings.local.json"

# --- Regression (2026-06-23): the deny output must not leak a grep warning.
# esc() previously escaped '/' as '\/' (invalid in ERE) -> "grep: warning: stray
# \ before /" lines polluted stderr and the deny reason surfaced to Codex/Grok. ---
stray_err="$(printf '%s' "$(jq -n --arg cmd "echo hi > $C/s.json" '{tool_input:{command:$cmd}}')" | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>&1 1>/dev/null || true)"
if printf '%s' "$stray_err" | grep -q 'stray'; then
  FAIL=$((FAIL+1)); echo "FAIL [no-grep-warning]: deny output leaked a grep warning" >&2
else
  PASS=$((PASS+1))
fi

echo "block-core-writes-bash: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
