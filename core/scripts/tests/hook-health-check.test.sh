#!/usr/bin/env bash
# Regression tests for the runtime-independent HQ hook-health checker.
#
# DEV-1942: Claude Desktop and SDK sessions can silently skip every project
# hook when settings.json is missing or project settings are not loaded. The
# checker must detect that condition without depending on those hooks.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CHECKER="$ROOT/core/scripts/check-hq-hooks.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

run_expect() {
  local expected="$1" root="$2" output rc
  set +e
  output="$(bash "$CHECKER" --root "$root" "${@:3}" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -eq "$expected" ] || fail "expected exit $expected, got $rc: $output"
  printf '%s' "$output"
}

make_healthy_root() {
  local root="$1"
  mkdir -p "$root/.claude"
  cat >"$root/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "echo session-start"}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "echo pre-tool"}]}]
  }
}
JSON
}

echo "[1] a healthy project configuration passes without relying on hooks"
HEALTHY="$TMP/healthy"
make_healthy_root "$HEALTHY"
out="$(run_expect 0 "$HEALTHY")"
printf '%s' "$out" | grep -Fq 'HQ hook health: PASS' || fail "healthy root did not pass: $out"
printf '%s' "$out" | grep -Fq 'ledger: not checked' || fail "default check should not falsely require a fresh-session ledger: $out"
pass "healthy settings pass and fresh installs are not falsely warned"

echo "[2] a missing settings file produces an actionable desktop/SDK repair"
MISSING="$TMP/missing"
mkdir -p "$MISSING/.claude"
out="$(run_expect 2 "$MISSING")"
printf '%s' "$out" | grep -Fq '.claude/settings.json is missing' || fail "missing settings diagnosis absent: $out"
printf '%s' "$out" | grep -Fq 'settingSources: ["project"]' || fail "SDK settingSources repair absent: $out"
printf '%s' "$out" | grep -Fq 'hq rescue -y --paths .claude' || fail "targeted rescue repair absent: $out"
pass "missing settings fail with a copy-paste remediation"

echo "[3] missing required hook events fail clearly"
NO_START="$TMP/no-start"
mkdir -p "$NO_START/.claude"
cat >"$NO_START/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo pre-tool"}]}]}}
JSON
out="$(run_expect 2 "$NO_START")"
printf '%s' "$out" | grep -Fq 'SessionStart has no command hook' || fail "missing SessionStart diagnosis absent: $out"
pass "missing SessionStart hook fails"

NO_PRE="$TMP/no-pre"
mkdir -p "$NO_PRE/.claude"
cat >"$NO_PRE/.claude/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo session-start"}]}]}}
JSON
out="$(run_expect 2 "$NO_PRE")"
printf '%s' "$out" | grep -Fq 'PreToolUse has no command hook' || fail "missing PreToolUse diagnosis absent: $out"
pass "missing PreToolUse hook fails"

echo "[4] malformed JSON fails instead of being treated as hook-ready"
BAD_JSON="$TMP/bad-json"
mkdir -p "$BAD_JSON/.claude"
printf '{not json\n' >"$BAD_JSON/.claude/settings.json"
out="$(run_expect 2 "$BAD_JSON")"
printf '%s' "$out" | grep -Fq 'is not valid JSON' || fail "invalid JSON diagnosis absent: $out"
pass "invalid JSON fails"

echo "[5] ledger verification detects a runtime that never wrote policy state"
LEDGER="$TMP/ledger"
make_healthy_root "$LEDGER"
out="$(run_expect 2 "$LEDGER" --require-ledger)"
printf '%s' "$out" | grep -Fq 'policy-trigger ledger was not found' || fail "missing ledger diagnosis absent: $out"
printf '%s' "$out" | grep -Fq 'HQ runtime enforcement: NOT OBSERVED' \
  || fail "missing ledger did not emit the runtime-off warning: $out"
mkdir -p "$LEDGER/workspace/orchestrator/policy-trigger-state"
: >"$LEDGER/workspace/orchestrator/policy-trigger-state/desktop-session.txt"
out="$(run_expect 0 "$LEDGER" --require-ledger)"
printf '%s' "$out" | grep -Fq 'ledger: present' || fail "present ledger not reported: $out"
printf '%s' "$out" | grep -Fq 'HQ runtime enforcement: OBSERVED' \
  || fail "present ledger did not emit the runtime-on signal: $out"
pass "ledger requirement distinguishes hook-ready from hooks-observed"

echo "[6] session-scoped verification cannot be satisfied by a stale ledger"
out="$(run_expect 2 "$LEDGER" --session-id app-sdk-session)"
printf '%s' "$out" | grep -Fq 'HQ runtime enforcement: NOT OBSERVED' \
  || fail "missing session ledger did not emit runtime-off warning: $out"
: >"$LEDGER/workspace/orchestrator/policy-trigger-state/app-sdk-session.txt"
out="$(run_expect 0 "$LEDGER" --session-id app-sdk-session)"
printf '%s' "$out" | grep -Fq 'session: app-sdk-session' \
  || fail "exact session identity was not reported: $out"
pass "session-scoped ledger check rejects stale evidence"

echo "[7] an unquoted project-dir reference is caught, not reported as healthy"
# feedback_4e67345c-ca66-4dae-8500-19c52726c39c: an install root containing a
# space plus unquoted $CLAUDE_PROJECT_DIR made /bin/sh split the script path, so
# every hook died as a non-blocking error while this checker still said PASS.
make_hook_scripts() {
  local root="$1"
  mkdir -p "$root/.claude/hooks"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$root/.claude/hooks/hook-gate.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$root/.claude/hooks/probe.sh"
  chmod +x "$root/.claude/hooks/hook-gate.sh" "$root/.claude/hooks/probe.sh"
}

SPACED="$TMP/HQ With Spaces"
make_hook_scripts "$SPACED"
# The checker reports the physical root; compare against the same form.
SPACED="$(cd "$SPACED" && pwd -P)"
cat >"$SPACED/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "bash $CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh probe $CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh"}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "bash $CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh"}]}]
  }
}
JSON

# Anchor the claim: that exact command really does die on this root.
split_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$SPACED/.claude/settings.json")"
set +e
CLAUDE_PROJECT_DIR="$SPACED" /bin/sh -c "$split_cmd" >/dev/null 2>&1
split_rc=$?
set -e
[ "$split_rc" -ne 0 ] || fail "expected the unquoted command to fail on a spaced root, but it succeeded"

out="$(run_expect 2 "$SPACED")"
printf '%s' "$out" | grep -Fq 'without quotes' || fail "unquoted reference diagnosis absent: $out"
printf '%s' "$out" | grep -Fq "$SPACED" || fail "diagnosis did not name the spaced root: $out"
pass "unquoted references on a spaced root fail instead of passing silently"

echo "[8] the same root passes once every reference is quoted"
cat >"$SPACED/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh\" probe \"$CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh\""}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh\""}]}]
  }
}
JSON
quoted_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$SPACED/.claude/settings.json")"
CLAUDE_PROJECT_DIR="$SPACED" /bin/sh -c "$quoted_cmd" >/dev/null 2>&1 \
  || fail "the quoted command should run cleanly from a spaced root"
out="$(run_expect 0 "$SPACED")"
printf '%s' "$out" | grep -Fq 'HQ hook health: PASS' || fail "quoted spaced root did not pass: $out"
pass "quoted references pass on a path containing a space"

echo "[9] braced and embedded references are caught too"
for variant in \
  'bash ${CLAUDE_PROJECT_DIR}/.claude/hooks/probe.sh' \
  'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh" --root=$CLAUDE_PROJECT_DIR'
do
  BRACED="$TMP/braced"
  rm -rf "$BRACED"
  make_hook_scripts "$BRACED"
  jq -n --arg cmd "$variant" '{
    hooks: {
      SessionStart: [{hooks: [{type: "command", command: "echo session-start"}]}],
      PreToolUse: [{hooks: [{type: "command", command: $cmd}]}]
    }
  }' >"$BRACED/.claude/settings.json"
  out="$(run_expect 2 "$BRACED")"
  printf '%s' "$out" | grep -Fq 'without quotes' \
    || fail "variant not detected as unquoted: $variant :: $out"
done
pass "braced and embedded project-dir references are detected"

echo "[10] a QUOTED braced reference is split-safe and must not be called broken"
# The detector blanks well-formed quoted tokens and reports the rest. If it only
# recognised "$CLAUDE_PROJECT_DIR/..." then "${CLAUDE_PROJECT_DIR}/..." — which
# /bin/sh handles perfectly — would be reported as a hook that is "failing right
# now", turning the tool meant to end a silent misdiagnosis into a confident
# false one. Anchor the claim by running the command before trusting the verdict.
cat >"$SPACED/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/hook-gate.sh\" probe \"${CLAUDE_PROJECT_DIR}/.claude/hooks/probe.sh\""}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/probe.sh\""}]}]
  }
}
JSON
braced_quoted_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$SPACED/.claude/settings.json")"
CLAUDE_PROJECT_DIR="$SPACED" /bin/sh -c "$braced_quoted_cmd" >/dev/null 2>&1 \
  || fail "the quoted braced command should run cleanly from a spaced root"
out="$(run_expect 0 "$SPACED")"
printf '%s' "$out" | grep -Fq 'HQ hook health: PASS' \
  || fail "quoted braced reference was wrongly reported as broken: $out"
pass "a quoted \${CLAUDE_PROJECT_DIR} reference passes on a spaced root"

echo "[11] an unquoted command in the local settings overlay is caught"
# Claude Code merges .claude/settings.local.json over .claude/settings.json, so
# a hook that lives only in the overlay fails on a spaced root just as silently.
LOCAL="$TMP/HQ With Local Overlay"
make_hook_scripts "$LOCAL"
LOCAL="$(cd "$LOCAL" && pwd -P)"
cat >"$LOCAL/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh\""}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh\""}]}]
  }
}
JSON
# With no overlay present at all the root is healthy: absence must stay benign.
out="$(run_expect 0 "$LOCAL")"
printf '%s' "$out" | grep -Fq 'HQ hook health: PASS' \
  || fail "a root without a local overlay should pass: $out"
if printf '%s' "$out" | grep -Fq 'settings.local.json'; then
  fail "an absent overlay must not be reported as scanned: $out"
fi

cat >"$LOCAL/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "PostToolUse": [{"hooks": [{"type": "command", "command": "bash $CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh"}]}]
  }
}
JSON
overlay_cmd="$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$LOCAL/.claude/settings.local.json")"
set +e
CLAUDE_PROJECT_DIR="$LOCAL" /bin/sh -c "$overlay_cmd" >/dev/null 2>&1
overlay_rc=$?
set -e
[ "$overlay_rc" -ne 0 ] || fail "expected the overlay command to fail on a spaced root, but it succeeded"

out="$(run_expect 2 "$LOCAL")"
printf '%s' "$out" | grep -Fq '.claude/settings.local.json' \
  || fail "overlay diagnosis did not name the local settings file: $out"
printf '%s' "$out" | grep -Fq 'without quotes' \
  || fail "unquoted overlay reference not detected: $out"
pass "an unquoted hook that lives only in the local overlay is detected"

echo "[12] a quoted reference to a missing hook script fails"
GONE="$TMP/gone"
make_hook_scripts "$GONE"
rm -f "$GONE/.claude/hooks/probe.sh"
cat >"$GONE/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh\""}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh\""}]}]
  }
}
JSON
out="$(run_expect 2 "$GONE")"
printf '%s' "$out" | grep -Fq 'runs a script that does not exist: .claude/hooks/probe.sh' \
  || fail "missing hook script diagnosis absent: $out"
pass "a hook command pointing at a deleted script fails"

echo "[13] the shipped project settings satisfy the checker"
out="$(run_expect 0 "$ROOT")"
printf '%s' "$out" | grep -Fq 'HQ hook health: PASS' || fail "shipped settings did not pass: $out"
pass "shipped .claude/settings.json is quote-safe and fully resolvable"

echo "[14] a quoted token that merely CONTAINS the variable is split-safe"
# "--root=$CLAUDE_PROJECT_DIR" is a single word to /bin/sh even on a spaced
# root. A detector that only recognises a quoted token STARTING with the
# variable calls this healthy config broken — and in the overlay the printed
# repair (hq rescue) cannot even touch it, so the operator is sent in a circle.
# Anchor the verdict: run the command first, observe rc=0, then ask the checker.
EMBED="$TMP/HQ With Embedded Args"
make_hook_scripts "$EMBED"
EMBED="$(cd "$EMBED" && pwd -P)"
cat >"$EMBED/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh\" probe \"$CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh\""}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh\" \"--root=$CLAUDE_PROJECT_DIR\""}]}]
  }
}
JSON
embed_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$EMBED/.claude/settings.json")"
CLAUDE_PROJECT_DIR="$EMBED" /bin/sh -c "$embed_cmd" >/dev/null 2>&1 \
  || fail "the embedded-but-quoted command should run cleanly from a spaced root"
out="$(run_expect 0 "$EMBED")"
printf '%s' "$out" | grep -Fq 'HQ hook health: PASS' \
  || fail "a quoted token containing the variable was wrongly called unquoted: $out"

cat >"$EMBED/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "PostToolUse": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh\" \"--root=$CLAUDE_PROJECT_DIR\""}]}]
  }
}
JSON
overlay_embed_cmd="$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$EMBED/.claude/settings.local.json")"
CLAUDE_PROJECT_DIR="$EMBED" /bin/sh -c "$overlay_embed_cmd" >/dev/null 2>&1 \
  || fail "the embedded-but-quoted overlay command should run cleanly from a spaced root"
out="$(run_expect 0 "$EMBED")"
printf '%s' "$out" | grep -Fq 'HQ hook health: PASS' \
  || fail "a quoted token containing the variable was wrongly called unquoted in the overlay: $out"
pass "\"--root=\$CLAUDE_PROJECT_DIR\" passes in both the shipped file and the overlay"

echo "[15] paths a command does not execute are not required to exist"
# A guarded optional hook and a data argument the hook creates at runtime are
# both absent on a perfectly healthy install. Failing them would make the
# checker cry wolf on configurations that run without error.
OPTIONAL="$TMP/optional"
make_hook_scripts "$OPTIONAL"
cat >"$OPTIONAL/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "[ -f \"$CLAUDE_PROJECT_DIR/personal/hooks/opt.sh\" ] && bash \"$CLAUDE_PROJECT_DIR/personal/hooks/opt.sh\" || true"}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh\" \"$CLAUDE_PROJECT_DIR/workspace/generated-at-runtime.json\""}]}]
  }
}
JSON
while IFS= read -r optional_cmd; do
  CLAUDE_PROJECT_DIR="$OPTIONAL" /bin/sh -c "$optional_cmd" >/dev/null 2>&1 \
    || fail "an optional/runtime path command should run cleanly: $optional_cmd"
done < <(jq -r '.. | objects | select(.type? == "command") | .command' "$OPTIONAL/.claude/settings.json")
out="$(run_expect 0 "$OPTIONAL")"
printf '%s' "$out" | grep -Fq 'HQ hook health: PASS' \
  || fail "a guarded optional path or runtime data path was wrongly failed: $out"
pass "guarded optional hooks and runtime data paths do not fail a healthy install"

echo "[16] a path segment containing a space survives the scan"
# The relpath must be read through its closing quote. Truncating at the first
# space reports the nonexistent path "my" and hides the real one.
SPACED_REL="$TMP/spaced-relpath"
make_hook_scripts "$SPACED_REL"
mkdir -p "$SPACED_REL/.claude/hooks/my dir"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SPACED_REL/.claude/hooks/my dir/x.sh"
chmod +x "$SPACED_REL/.claude/hooks/my dir/x.sh"
cat >"$SPACED_REL/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh\""}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/my dir/x.sh\""}]}]
  }
}
JSON
spaced_rel_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$SPACED_REL/.claude/settings.json")"
CLAUDE_PROJECT_DIR="$SPACED_REL" /bin/sh -c "$spaced_rel_cmd" >/dev/null 2>&1 \
  || fail "a quoted path with a spaced segment should run cleanly"
out="$(run_expect 0 "$SPACED_REL")"
printf '%s' "$out" | grep -Fq 'HQ hook health: PASS' \
  || fail "a present hook script with a spaced path segment was reported missing: $out"

rm -f "$SPACED_REL/.claude/hooks/my dir/x.sh"
out="$(run_expect 2 "$SPACED_REL")"
printf '%s' "$out" | grep -Fq 'runs a script that does not exist: .claude/hooks/my dir/x.sh' \
  || fail "the missing spaced path was not named in full: $out"
if printf '%s\n' "$out" | grep -Eq 'does not exist: \.claude/hooks/my$'; then
  fail "the spaced path was truncated at the space: $out"
fi
pass "a spaced path segment is reported whole, present or missing"

echo "[17] the count names broken commands, not matching lines"
# A hook command may contain a newline. Counting lines turns one broken command
# into several and understates two refs in one command, so the number an
# operator reads would not be the number of hooks they have to fix.
COUNT="$TMP/count"
make_hook_scripts "$COUNT"
multiline_cmd="$(printf 'bash $CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh\nbash $CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh')"
jq -n --arg cmd "$multiline_cmd" '{
  hooks: {
    SessionStart: [{hooks: [{type: "command", command: "echo session-start"}]}],
    PreToolUse: [{hooks: [{type: "command", command: $cmd}]}]
  }
}' >"$COUNT/.claude/settings.json"
out="$(run_expect 2 "$COUNT")"
printf '%s' "$out" | grep -Fq '1 hook command(s)' \
  || fail "one multi-line command should count once: $out"

jq -n '{
  hooks: {
    SessionStart: [{hooks: [{type: "command", command: "bash $CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh $CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh"}]}],
    PreToolUse: [{hooks: [{type: "command", command: "bash $CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh"}]}]
  }
}' >"$COUNT/.claude/settings.json"
out="$(run_expect 2 "$COUNT")"
printf '%s' "$out" | grep -Fq '2 hook command(s)' \
  || fail "two broken commands should count twice: $out"
pass "the reported number is a count of broken commands"

echo "[18] an agents-v2 (hermes) box gets v2-appropriate ledger guidance, not Claude-CLI steps"
# The ledger ASSERTION is identical across runtimes (present => OBSERVED / exit
# 0, missing => NOT OBSERVED / exit 2); only the recovery guidance differs.
# Detection is either the runtime marker (runtimeMode=agents-v2) or the on-box
# adapter under the tree. A v2 box legitimately has no ledger until the agent's
# first live turn writes it through the same .claude hooks, so the Claude
# Desktop/SDK repair steps are wrong there (they send the operator in a circle).
NO_MARKER="$TMP/no-such-runtime-marker.json"   # isolate from the host's marker

# 18a: detected via the runtime marker file (HQ_RUNTIME_MARKER_FILE override).
V2ROOT="$TMP/agents-v2-marker"
make_healthy_root "$V2ROOT"
V2MARKER="$TMP/agents-v2-runtime.json"
printf '{"runtimeMode":"agents-v2"}\n' >"$V2MARKER"
set +e
out="$(HQ_RUNTIME_MARKER_FILE="$V2MARKER" bash "$CHECKER" --root "$V2ROOT" --require-ledger 2>&1)"; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "v2 marker + missing ledger should exit 2: $out"
printf '%s' "$out" | grep -Fq 'HQ runtime enforcement: NOT OBSERVED' \
  || fail "v2 missing ledger must keep the identical NOT OBSERVED assertion: $out"
printf '%s' "$out" | grep -Fq 'agents-v2 (hermes)' \
  || fail "v2 box did not get agents-v2 guidance: $out"
printf '%s' "$out" | grep -Fq 'live turn' \
  || fail "v2 guidance should tell the operator to drive a live turn: $out"
if printf '%s' "$out" | grep -Fq 'For Claude Desktop'; then
  fail "v2 box was shown the wrong Claude Desktop recovery steps: $out"
fi
if printf '%s' "$out" | grep -Fq 'settingSources: ["project"]'; then
  fail "v2 box was shown the wrong SDK recovery steps: $out"
fi
pass "v2 marker box: identical NOT OBSERVED assertion, v2 guidance, no Claude-CLI steps"

# 18b: detected via the on-box adapter marker under the tree (no runtime marker).
V2ADP="$TMP/agents-v2-adapter"
make_healthy_root "$V2ADP"
mkdir -p "$V2ADP/.agents-v2-hooks"
printf '#!/bin/bash\nexit 0\n' >"$V2ADP/.agents-v2-hooks/hq-agents-v2-hook-adapter.sh"
set +e
out="$(HQ_RUNTIME_MARKER_FILE="$NO_MARKER" bash "$CHECKER" --root "$V2ADP" --require-ledger 2>&1)"; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "v2 adapter-marker + missing ledger should exit 2: $out"
printf '%s' "$out" | grep -Fq 'agents-v2 (hermes)' \
  || fail "adapter-marker box did not get agents-v2 guidance: $out"
if printf '%s' "$out" | grep -Fq 'For Claude Desktop'; then
  fail "adapter-marker box was shown the wrong Claude Desktop steps: $out"
fi
pass "v2 adapter-marker box is detected from the tree alone"

# 18c: once the ledger is present the v2 box reads OBSERVED — byte-identical to
# the Claude runtime's OBSERVED verdict.
mkdir -p "$V2ADP/workspace/orchestrator/policy-trigger-state"
: >"$V2ADP/workspace/orchestrator/policy-trigger-state/hermes-turn.txt"
out="$(HQ_RUNTIME_MARKER_FILE="$NO_MARKER" bash "$CHECKER" --root "$V2ADP" --require-ledger 2>&1)"
printf '%s' "$out" | grep -Fq 'HQ runtime enforcement: OBSERVED' \
  || fail "present ledger on a v2 box must read OBSERVED: $out"
printf '%s' "$out" | grep -Fq 'ledger: present' || fail "v2 present ledger not reported: $out"
pass "v2 box with a live-turn ledger reads OBSERVED (identical assertion)"

# 18d: a plain Claude tree (no marker, no adapter) still gets the Claude-CLI
# recovery steps — the v2 branch must not leak into the default runtime.
CLAUDEROOT="$TMP/claude-default"
make_healthy_root "$CLAUDEROOT"
set +e
out="$(HQ_RUNTIME_MARKER_FILE="$NO_MARKER" bash "$CHECKER" --root "$CLAUDEROOT" --require-ledger 2>&1)"; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "claude default + missing ledger should exit 2: $out"
printf '%s' "$out" | grep -Fq 'For Claude Desktop' \
  || fail "the default runtime lost its Claude Desktop guidance: $out"
if printf '%s' "$out" | grep -Fq 'agents-v2 (hermes)'; then
  fail "a plain Claude tree wrongly got agents-v2 guidance: $out"
fi
pass "the default Claude runtime keeps its own recovery steps"

echo "PASS: hook-health checker"
