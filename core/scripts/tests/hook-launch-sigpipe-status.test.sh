#!/usr/bin/env bash
# Regression: a hook's recorded exit status must be the HOOK's status, never the
# status of the process writing its payload.
#
# Every HQ dispatch path fed the payload through a pipe:
#
#   printf '%s' "$payload" | "$hook"
#
# A hook that exits before reading stdin (conduct-lane-inbox's
# `[ -n "${HQ_CONDUCT_RUN_DIR:-}" ] || exit 0` guard is the canonical shape)
# closes the read end while printf is still writing. printf dies with SIGPIPE,
# and `pipefail` — set by hook-gate.sh, master-hook.sh, and both cross-runtime
# adapters — promotes 141 to the pipeline status. The hook is then reported as
# having FAILED with 141 even though it exited 0.
#
# Observed on fleet boxes at hq-core 15.0.139, where it refused an agent's first
# company read on a fresh session and failed 2 of 3 v1->v2 migration probes:
#
#   PROBE_FAIL - pre-bind: first company read on a fresh session was refused
#   (rc=141): Hook 'conduct-lane-inbox' exited 141.
#
# The race needs the payload to exceed the pipe buffer (64 KiB on Linux, 8 KiB
# on stock macOS), so these cases use 1 MiB and are deterministic.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
LIB="$ROOT/core/scripts/hook-lib.sh"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
MASTER="$ROOT/.claude/hooks/master-hook.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$LIB" ] || fail "hook-lib.sh not found at $LIB"
[ -f "$GATE" ] || fail "hook-gate.sh not found at $GATE"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 1 MiB: larger than any platform pipe buffer, so the writer is guaranteed to
# still be blocked in write() when an early-exit hook closes its stdin.
PAYLOAD="$(head -c 1048576 /dev/zero | tr '\0' 'x')"
[ "${#PAYLOAD}" -eq 1048576 ] || fail "payload builder produced ${#PAYLOAD} bytes, expected 1048576"

# Exits 0 without reading stdin — conduct-lane-inbox's guard shape.
cat > "$TMP/early-exit.sh" <<'HOOK'
#!/usr/bin/env bash
exit 0
HOOK

# Exits 2 without reading stdin: a real blocking decision must survive too.
cat > "$TMP/early-block.sh" <<'HOOK'
#!/usr/bin/env bash
echo "EARLY_BLOCK_RAN" >&2
exit 2
HOOK

# Reads its whole payload, then fails on its own merits.
cat > "$TMP/reads-then-fails.sh" <<'HOOK'
#!/usr/bin/env bash
n="$(cat | wc -c | tr -d '[:space:]')"
echo "READ_BYTES=$n" >&2
exit 3
HOOK
chmod +x "$TMP/early-exit.sh" "$TMP/early-block.sh" "$TMP/reads-then-fails.sh"

echo "[1] hook-lib: early-exit-0 hook under pipefail records 0, not 141"
(
  set -o pipefail
  # shellcheck source=/dev/null
  . "$LIB"
  status=0
  hq_launch_shell_path "$ROOT" "$TMP/early-exit.sh" "$PAYLOAD" || status=$?
  printf '%s\n' "$status" > "$TMP/s1"
  printf '%s\n' "${HQ_HOOK_LAST_STATUS:-unset}" > "$TMP/s1last"
)
s1="$(cat "$TMP/s1")"
[ "$s1" = "0" ] || fail "hq_launch_shell_path returned $s1 for a hook that exited 0 (SIGPIPE from the payload writer leaked into the hook's status)"
s1last="$(cat "$TMP/s1last")"
[ "$s1last" = "0" ] || fail "HQ_HOOK_LAST_STATUS recorded $s1last for a hook that exited 0"
pass "hq_launch_shell_path reports 0"

echo "[2] hook-lib: non-executable early-exit hook (bash fallback path) records 0"
cp "$TMP/early-exit.sh" "$TMP/early-exit-noexec.sh"
chmod 0444 "$TMP/early-exit-noexec.sh"
(
  set -o pipefail
  # shellcheck source=/dev/null
  . "$LIB"
  status=0
  # Outside the HQ root, so hq_launch_shell_path will not chmod-repair it and
  # must take the readable-bash fallback pipeline.
  hq_launch_shell_path "$TMP/not-hq-root" "$TMP/early-exit-noexec.sh" "$PAYLOAD" || status=$?
  printf '%s\n' "$status" > "$TMP/s2"
)
s2="$(cat "$TMP/s2")"
[ "$s2" = "0" ] || fail "bash-fallback path returned $s2 for a hook that exited 0"
pass "bash fallback path reports 0"

echo "[3] hook-lib: a hook that genuinely fails still reports its own status"
(
  set -o pipefail
  # shellcheck source=/dev/null
  . "$LIB"
  status=0
  hq_launch_shell_path "$ROOT" "$TMP/reads-then-fails.sh" "$PAYLOAD" 2>"$TMP/e3" || status=$?
  printf '%s\n' "$status" > "$TMP/s3"
)
s3="$(cat "$TMP/s3")"
[ "$s3" = "3" ] || fail "expected the hook's own exit 3, got $s3"
grep -q "READ_BYTES=1048576" "$TMP/e3" \
  || fail "hook did not receive all 1048576 payload bytes (got: $(cat "$TMP/e3"))"
pass "genuine exit 3 preserved and payload delivered byte-for-byte"

echo "[4] hook-lib: an early-exit BLOCK (2) is still reported as 2"
(
  set -o pipefail
  # shellcheck source=/dev/null
  . "$LIB"
  status=0
  hq_launch_shell_path "$ROOT" "$TMP/early-block.sh" "$PAYLOAD" 2>"$TMP/e4" || status=$?
  printf '%s\n' "$status" > "$TMP/s4"
)
s4="$(cat "$TMP/s4")"
[ "$s4" = "2" ] || fail "expected blocking exit 2 from an early-exit hook, got $s4"
grep -q EARLY_BLOCK_RAN "$TMP/e4" || fail "early-block hook did not run"
pass "blocking exit 2 preserved"

echo "[5] hook-gate.sh: early-exit-0 hook is not reported as 141"
gate_status=0
# detect-secrets is in every profile, so the gate delegates under the default.
printf '%s' "$PAYLOAD" | bash "$GATE" detect-secrets "$TMP/early-exit.sh" >/dev/null 2>"$TMP/e5" || gate_status=$?
[ "$gate_status" = "0" ] || fail "hook-gate.sh exited $gate_status for a hook that exited 0 (stderr: $(cat "$TMP/e5"))"
pass "hook-gate.sh exits 0"

echo "[6] hook-gate.sh: a delegated non-zero exit still propagates"
gate_status=0
printf '%s' "$PAYLOAD" | bash "$GATE" detect-secrets "$TMP/early-block.sh" >/dev/null 2>"$TMP/e6" || gate_status=$?
[ "$gate_status" = "2" ] || fail "hook-gate.sh should propagate exit 2, got $gate_status"
pass "hook-gate.sh propagates exit 2"

echo "[7] master-hook.sh registry dispatch: early-exit-0 hook does not fail the batch"
FIX="$TMP/fixture"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts/lib"
cp "$MASTER" "$GATE" "$FIX/.claude/hooks/"
cp "$LIB" "$FIX/core/scripts/"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIX/.claude/hooks/"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIX/core/scripts/lib/"
cp "$TMP/early-exit.sh" "$FIX/.claude/hooks/sigpipe-probe.sh"
chmod +x "$FIX/.claude/hooks/sigpipe-probe.sh"
cat > "$FIX/.claude/hooks/hook-registry.json" <<'REG'
{
  "$schema": "hq-hook-registry@1",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "id": "detect-secrets",
            "script": ".claude/hooks/sigpipe-probe.sh",
            "timeout": 30,
            "gated": true
          }
        ]
      }
    ]
  }
}
REG
# tool_input carries the bulk so the payload master-hook pipes to the child is
# over 1 MiB, exactly as a large Write or Edit would be. The payload goes to jq
# via --rawfile and to master-hook via a redirect: 1 MiB does not fit in argv
# (macOS caps it at 1 MiB total, so --arg would abort with E2BIG).
printf '%s' "$PAYLOAD" > "$TMP/payload.txt"
jq -n --rawfile p "$TMP/payload.txt" \
  '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$p}}' > "$TMP/big.json"
master_status=0
HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" HQ_HOOK_TIMEOUT_SENTRY=0 \
  bash "$FIX/.claude/hooks/master-hook.sh" PreToolUse \
  < "$TMP/big.json" >/dev/null 2>"$TMP/e7" || master_status=$?
[ "$master_status" = "0" ] \
  || fail "master-hook.sh exited $master_status because a registry hook exited 0 without reading stdin (stderr: $(cat "$TMP/e7"))"
pass "master-hook.sh registry dispatch exits 0"

echo "ALL PASS: hook-launch-sigpipe-status"
