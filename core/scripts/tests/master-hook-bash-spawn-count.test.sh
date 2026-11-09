#!/usr/bin/env bash
# hq-core: public
# master-hook-bash-spawn-count.test.sh — one benign Bash tool call must not
# start more than a fixed number of bash processes through master-hook.sh.
#
# Why: on Windows every bash start is a full bash.exe (feedback c4622e80, family
# ea24aaad: 59 concurrent bash.exe during normal work, each hook nesting 3-6
# bash layers). Always-on registry hooks that run as `exec` pay two bash starts
# each (the completion-marker wrapper, then the script); `runner: source` pays
# one. This test runs a real PreToolUse and PostToolUse dispatch with a `bash`
# shim first on PATH and fails when the count grows past the budget.
#
# The fixture copy rewrites `#!/bin/bash` shebangs to `#!/usr/bin/env bash` so
# hook scripts that the kernel would start directly also go through the shim.
# Works on macOS bash 3.2 (no associative arrays, no BASH_XTRACEFD).
#
# The absolute count differs by bash version and host (bash 3.2 takes an extra
# path that runs derive-trigger-facts.sh / policy-enforcement-gate.sh directly),
# so the assertion is relative: the same fixture is dispatched twice with the
# same bash, once with the registry as shipped and once with every
# `runner: source` entry forced back to exec. The shipped run must start
# strictly fewer bash processes. Main's registry has no source entries, so the
# two runs are equal there and the test fails (RED).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
FAIL=0
pass() { echo "  ok: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
if ! command -v jq >/dev/null 2>&1; then
  if [ -n "${CI:-}" ]; then echo "FAIL: jq is required in CI" >&2; exit 1; fi
  echo "SKIP: jq unavailable" >&2; exit 0
fi

# Optional absolute ceilings (unset by default; the relative check is the gate).
PRE_MAX="${HQ_BASH_SPAWN_PRE_MAX:-}"
POST_MAX="${HQ_BASH_SPAWN_POST_MAX:-}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
SHIM="$TMP/shim"
mkdir -p "$FIX/core" "$FIX/workspace" "$FIX/personal" "$FIX/companies" "$SHIM" "$TMP/home"
cp -R "$ROOT/.claude" "$FIX/.claude"
# core/scripts without its test tree (large; the dispatch never reads it).
mkdir -p "$FIX/core/scripts"
for f in "$ROOT"/core/scripts/*; do
  case "${f##*/}" in tests|__tests__) continue ;; esac
  cp -R "$f" "$FIX/core/scripts/"
done
for f in core.yaml; do [ ! -f "$ROOT/core/$f" ] || cp "$ROOT/core/$f" "$FIX/core/$f"; done

# Route kernel-started bash scripts through the shim as well.
rewritten=0
while IFS= read -r f; do
  first="$(head -n 1 "$f")"
  if [ "$first" = '#!/bin/bash' ]; then
    { echo '#!/usr/bin/env bash'; tail -n +2 "$f"; } > "$f.rw" && cat "$f.rw" > "$f" && rm -f "$f.rw"
    rewritten=$((rewritten + 1))
  fi
done < <(find "$FIX/.claude/hooks" "$FIX/core/scripts" -maxdepth 1 -name '*.sh')

REAL_BASH="${HQ_TEST_BASH:-$(type -P bash)}"
cat > "$SHIM/bash" <<SHIMEOF
#!$REAL_BASH
printf '%s\n' "\$*" | cut -c1-160 >> "\$BASH_SPAWN_LOG"
exec $REAL_BASH "\$@"
SHIMEOF
chmod +x "$SHIM/bash"

dispatch_once() { # <event> <log>
  local event="$1" log="$2" payload
  : > "$log"
  payload="$(printf '{"session_id":"spawn-count","cwd":"%s","hook_event_name":"%s","tool_name":"Bash","tool_input":{"command":"ls -la"}}' "$FIX" "$event")"
  printf '%s' "$payload" | env -u BASH_ENV HOME="$TMP/home" PATH="$SHIM:$PATH" \
    BASH_SPAWN_LOG="$log" HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" \
    HQ_HOOK_DEDUPE=0 HQ_ALLOW_HQ_WORKTREE=1 HQ_HOOK_TIMEOUT_SENTRY=0 \
    "$REAL_BASH" "$FIX/.claude/hooks/master-hook.sh" "$event" >/dev/null 2>&1
}
count_dispatch() { # <event> -> prints bash starts of a WARM dispatch
  # The first dispatch after a fresh fixture or registry swap is cold (rebuilds
  # registry-row caches and probes), which adds starts that differ by bash
  # version. Run once to warm up, then count the second run.
  local event="$1" log="$TMP/$1.log"
  dispatch_once "$event" "$TMP/warmup.log"
  dispatch_once "$event" "$log"
  cp "$log" "$TMP/last-$event.log"
  wc -l < "$log" | tr -d ' '
}

echo "[1] shebang rewrite reached the hooks ($rewritten scripts)"
[ "$rewritten" -gt 0 ] && pass "shim sees kernel-started scripts" || fail "no scripts were rewritten; count would undercount"

REG="$FIX/.claude/hooks/hook-registry.json"
cp "$REG" "$TMP/registry.shipped.json"
# Baseline = the same registry with the always-on hooks this fix converted put
# back to exec (the main-branch state for those entries).
CONVERTED='["inject-policy-on-trigger","policy-enforcement-gate","hq-monitor-session-hook","merged-write-guard-shadow"]'
jq --argjson ids "$CONVERTED" '(.. | objects | select(.runner? == "source" and ((.id? // "") as $i | $ids | index($i) != null))) |= del(.runner)' \
  "$TMP/registry.shipped.json" > "$TMP/registry.exec.json"
n_source="$(jq --argjson ids "$CONVERTED" '[.. | objects | select(.runner? == "source" and ((.id? // "") as $i | $ids | index($i) != null))] | length' "$TMP/registry.shipped.json")"

echo "[2] bash starts per benign Bash tool call ($REAL_BASH; $n_source converted registry entries)"
[ "$n_source" -gt 0 ] && pass "converted hooks are sourced in the registry" || fail "no converted hooks run sourced; nothing to compare"
pre="$(count_dispatch PreToolUse)"
cp "$TMP/last-PreToolUse.log" "$TMP/pre.shipped.log"
grep -q 'block-credential-file-read' "$TMP/last-PreToolUse.log" && gate_ran=1 || gate_ran=0
post="$(count_dispatch PostToolUse)"
cp "$TMP/registry.exec.json" "$REG"
# The dispatcher caches registry rows by mtime; drop them so the swap is seen.
rm -rf "$FIX/workspace/orchestrator/hook-state/registry-rows"
pre_exec="$(count_dispatch PreToolUse)"
cp "$TMP/last-PreToolUse.log" "$TMP/pre.exec.log"
if [ -n "${HQ_BASH_SPAWN_DEBUG:-}" ]; then
  echo "--- PreToolUse starts, shipped registry"; cat "$TMP/pre.shipped.log"
  echo "--- PreToolUse starts, converted hooks forced to exec"; cat "$TMP/pre.exec.log"
fi
post_exec="$(count_dispatch PostToolUse)"
cp "$TMP/registry.shipped.json" "$REG"
echo "  PreToolUse: shipped=$pre forced-exec=$pre_exec   PostToolUse: shipped=$post forced-exec=$post_exec"

# Floor: a dispatcher that bails early counts ~0 and must not pass vacuously.
[ "$gate_ran" -eq 1 ] && pass "dispatch ran block-credential-file-read (fail-closed, always exec)" || fail "block-credential-file-read never ran; dispatch bailed early"
[ "$pre" -ge 3 ] && [ "$pre_exec" -ge 3 ] && pass "PreToolUse count above floor" \
  || fail "PreToolUse counts too low (shipped=$pre exec=$pre_exec); dispatch likely bailed"
# Measured warm on bash 3.2 and 5.x: Pre 6 vs 10, Post 5 vs 6.
[ "$pre" -lt "$pre_exec" ] && pass "PreToolUse starts fewer bash than the exec baseline" \
  || fail "PreToolUse shipped ($pre) is not lower than forced-exec ($pre_exec)"
[ "$post" -lt "$post_exec" ] && pass "PostToolUse starts fewer bash than the exec baseline" \
  || fail "PostToolUse shipped ($post) is not lower than forced-exec ($post_exec)"
[ -z "$PRE_MAX" ] || { [ "$pre" -le "$PRE_MAX" ] && pass "PreToolUse <= $PRE_MAX" || fail "PreToolUse $pre > $PRE_MAX"; }
[ -z "$POST_MAX" ] || { [ "$post" -le "$POST_MAX" ] && pass "PostToolUse <= $POST_MAX" || fail "PostToolUse $post > $POST_MAX"; }

echo "[3] always-on, non-fail-closed registry hooks on tool events run sourced"
# An unprefiltered, ungated-by-file hook runs on every tool call. As exec it
# costs two bash starts (marker wrapper + script); sourced it costs one.
exec_always_on="$(jq -r '
  .hooks | to_entries[] | select(.key == "PreToolUse" or .key == "PostToolUse") |
  .key as $ev | .value[] | .hooks[] |
  select((.prefilter == null) and ((.runner // "exec") == "exec") and ((.fail_closed // false) | not)) |
  "\($ev):\(.id)"' "$ROOT/.claude/hooks/hook-registry.json" | sort -u)"
# Allowed to stay exec: tool-specific or rare hooks that are not on every Bash call.
unexpected=""
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  case "$entry" in
    # Credential guards stay exec so a crash or exit in the redaction/read-block
    # path cannot take down the dispatcher (#1480). block-credential-file-read is
    # also fail_closed, so the jq filter above already skips it; listed for clarity.
    PostToolUse:redact-credential-output) ;;
    PreToolUse:block-credential-file-read) ;;
    # Spawn/handoff and the never-matching monitor variant do not fire on an
    # ordinary Bash call, so exec costs nothing per call.
    PreToolUse:spawn-company-handoff|PreToolUse:hq-monitor-session-hook-never) ;;
    # Rare capture paths: gate internally and return before doing work.
    PostToolUse:native-plan-project-sync|PostToolUse:journal-autocapture) ;;
    PostToolUse:hq-autocommit|PostToolUse:journal-due|PostToolUse:auto-checkpoint-trigger) ;; # Write/Edit only
    # Conductor-lane-only hooks; no-ops outside a conduct session.
    PostToolUse:conduct-lanes-link-deliver|PostToolUse:conduct-link-inherit) ;;
    *) unexpected="$unexpected $entry" ;;
  esac
done <<< "$exec_always_on"
[ -z "$unexpected" ] && pass "no always-on exec hook outside the allow list" \
  || fail "always-on exec registry hooks cost two bash starts per call:$unexpected"

if [ "$FAIL" -ne 0 ]; then
  echo "FAILED ($FAIL)" >&2
  exit 1
fi
echo "PASS"
