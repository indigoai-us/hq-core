#!/bin/bash
# handoff-cross-device.test.sh - two-root integration test for cross-device handoff.
#
# Simulates two HQ roots (machine A and machine B) sharing a fake personal
# vault directory, with a mocked `hq` CLI whose `sync push --personal` /
# `sync pull --personal` subcommands copy only the files the real engine
# carves out of PERSONAL_VAULT_EXCLUDED_TOP_LEVEL:
#   - workspace/threads/handoff.json
#   - the single thread file handoff.json.thread_path references
#
# This mirrors `computeContinuityPointerPaths` behaviour and lets us prove
# the fix end-to-end:
#   1. Machine A: writes handoff.json + T-*.json, runs handoff-sync-publish.
#   2. Vault: now has the pointer + the referenced thread file.
#   3. Machine B: runs handoff-sync-prefetch, reads handoff.json, resolves
#      the referenced thread file.
#
# No cloud / real `hq` CLI is required.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PUBLISH_SH="$REPO_ROOT/core/scripts/handoff-sync-publish.sh"
PREFETCH_SH="$REPO_ROOT/core/scripts/handoff-sync-prefetch.sh"

[[ -f "$PUBLISH_SH" ]] || { echo "FAIL: $PUBLISH_SH not found" >&2; exit 1; }
[[ -f "$PREFETCH_SH" ]] || { echo "FAIL: $PREFETCH_SH not found" >&2; exit 1; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

VAULT="$WORKDIR/vault"           # shared "personal vault"
HQ_A="$WORKDIR/hq-a"              # machine A root
HQ_B="$WORKDIR/hq-b"              # machine B root
mkdir -p "$VAULT" "$HQ_A/workspace/threads" "$HQ_B/workspace/threads"

# ---- mock `hq` CLI --------------------------------------------------------
# `hq sync push --personal --hq-root <path>` copies the two carve-out files
# from <path> into VAULT. `hq sync pull --personal --hq-root <path>` copies
# them back out. Everything else is a no-op success. The mock lives on PATH
# so the helpers find it without a hq-cli install.
MOCK_BIN="$WORKDIR/bin"
mkdir -p "$MOCK_BIN"
cat >"$MOCK_BIN/hq" <<MOCK_EOF
#!/bin/bash
# Minimal hq mock. Only cares about: hq sync push/pull --personal --hq-root P.
set -euo pipefail
VAULT="$VAULT"
sub=""
sub2=""
hq_root=""
if [[ "\${1:-}" == "sync" ]]; then sub="\$2"; shift 2; fi
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --hq-root) hq_root="\$2"; shift 2 ;;
    --personal|--all) shift ;;
    --lock-timeout|--message|--on-conflict|--company) shift 2 ;;
    *) shift ;;
  esac
done
copy_pointer() {
  local src_root="\$1" dst_root="\$2"
  local pointer="\$src_root/workspace/threads/handoff.json"
  [[ -f "\$pointer" ]] || return 0
  mkdir -p "\$dst_root/workspace/threads"
  cp "\$pointer" "\$dst_root/workspace/threads/handoff.json"
  local tp
  tp="\$(sed -n 's/.*"thread_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "\$pointer" | head -n1)"
  if [[ -n "\$tp" && -f "\$src_root/\$tp" ]]; then
    mkdir -p "\$(dirname "\$dst_root/\$tp")"
    cp "\$src_root/\$tp" "\$dst_root/\$tp"
  fi
}
case "\$sub" in
  push) copy_pointer "\$hq_root" "\$VAULT" ;;
  pull) copy_pointer "\$VAULT" "\$hq_root" ;;
  *) : ;;
esac
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/hq"
export PATH="$MOCK_BIN:$PATH"

# ---- machine A: write a handoff.json + thread file ------------------------
THREAD_ID="T-20261005-test-thread"
THREAD_REL="workspace/threads/${THREAD_ID}.json"
cat >"$HQ_A/$THREAD_REL" <<JSON
{"thread_id":"$THREAD_ID","type":"handoff","conversation_summary":"a→b continuity"}
JSON
cat >"$HQ_A/workspace/threads/handoff.json" <<JSON
{"created_at":"2026-01-01T12:00:00Z","last_thread":"$THREAD_ID","thread_path":"$THREAD_REL","context_notes":"xdevice"}
JSON

# ---- publish from A -------------------------------------------------------
PUBLISH_LOG="$WORKDIR/publish.log"
bash "$PUBLISH_SH" --hq-root "$HQ_A" --sync --log "$PUBLISH_LOG" >/dev/null

[[ -f "$VAULT/workspace/threads/handoff.json" ]] || {
  echo "FAIL: publish did not carry handoff.json into the vault" >&2
  cat "$PUBLISH_LOG" >&2 || true
  exit 1
}
[[ -f "$VAULT/$THREAD_REL" ]] || {
  echo "FAIL: publish did not carry the referenced thread file into the vault" >&2
  exit 1
}

# ---- prefetch into B ------------------------------------------------------
PREFETCH_LOG="$WORKDIR/prefetch.log"
status="$(bash "$PREFETCH_SH" --hq-root "$HQ_B" --log "$PREFETCH_LOG")"
[[ "$status" == "ok" ]] || {
  echo "FAIL: prefetch status was '$status' (expected 'ok')" >&2
  cat "$PREFETCH_LOG" >&2 || true
  exit 1
}

[[ -f "$HQ_B/workspace/threads/handoff.json" ]] || {
  echo "FAIL: prefetch did not land handoff.json on machine B" >&2
  exit 1
}
[[ -f "$HQ_B/$THREAD_REL" ]] || {
  echo "FAIL: prefetch did not land the referenced thread file on machine B" >&2
  exit 1
}

# Thread body must be byte-identical to what A wrote.
if ! diff -q "$HQ_A/$THREAD_REL" "$HQ_B/$THREAD_REL" >/dev/null; then
  echo "FAIL: thread file on B does not match A" >&2
  exit 1
fi

# ---- missing-CLI path should fail soft and not raise ---------------------
# Use a sandbox PATH that keeps coreutils but excludes every `hq` the host may
# ship. We seed it only with /usr/bin:/bin, then verify `hq` is not found.
SANDBOX_PATH="/usr/bin:/bin"
if PATH="$SANDBOX_PATH" command -v hq >/dev/null 2>&1; then
  echo "SKIP: host ships hq under $SANDBOX_PATH; cannot exercise missing-CLI case" >&2
else
  status_nocli="$(PATH="$SANDBOX_PATH" bash "$PREFETCH_SH" --hq-root "$HQ_B" --log /dev/null)"
  [[ "$status_nocli" == "missing-cli" ]] || {
    echo "FAIL: prefetch without hq CLI should report 'missing-cli', got '$status_nocli'" >&2
    exit 1
  }
  PATH="$SANDBOX_PATH" bash "$PUBLISH_SH" --hq-root "$HQ_A" --sync --log /dev/null \
    || { echo "FAIL: publish without hq CLI should exit 0" >&2; exit 1; }
fi

# ---- portable timeout path (no `timeout` on PATH) ------------------------
# Regression for a bug where the timebox silently did nothing on stock macOS
# because /usr/bin/timeout does not exist and only Homebrew coreutils ships
# it. The helper must enforce the wall-clock bound itself and must report
# `timed-out` on expiry (not `error:143` from a propagated signal).
SLOW_BIN="$WORKDIR/bin-slow"
mkdir -p "$SLOW_BIN"
cat >"$SLOW_BIN/hq" <<'SLOW_EOF'
#!/bin/bash
# Mock hq that never returns in a reasonable time, so the helper must kill it.
sleep 30
SLOW_EOF
chmod +x "$SLOW_BIN/hq"

# Scrub real `timeout` from PATH too, and make sure our slow `hq` wins.
NO_TIMEOUT_PATH="$SLOW_BIN:/usr/bin:/bin"
if PATH="$NO_TIMEOUT_PATH" command -v timeout >/dev/null 2>&1; then
  echo "SKIP: host ships timeout under $NO_TIMEOUT_PATH; cannot exercise no-timeout case" >&2
else
  # --- prefetch: should print `timed-out` within ~2s of the deadline --------
  SLOW_LOG="$WORKDIR/prefetch-slow.log"
  t0=$(date +%s)
  slow_status="$(PATH="$NO_TIMEOUT_PATH" bash "$PREFETCH_SH" \
    --hq-root "$HQ_B" --timeout 1 --log "$SLOW_LOG")"
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  [[ "$slow_status" == "timed-out" ]] || {
    echo "FAIL: prefetch with slow hq expected 'timed-out', got '$slow_status'" >&2
    cat "$SLOW_LOG" >&2 || true
    exit 1
  }
  if [[ "$elapsed" -gt 6 ]]; then
    echo "FAIL: prefetch timebox did not fire fast enough ($elapsed s for 1s timeout)" >&2
    exit 1
  fi

  # --- publish --sync: should exit 124 on timeout, within the same window --
  SLOW_PUB_LOG="$WORKDIR/publish-slow.log"
  t0=$(date +%s)
  pub_rc=0
  PATH="$NO_TIMEOUT_PATH" bash "$PUBLISH_SH" \
    --hq-root "$HQ_A" --timeout 1 --sync --log "$SLOW_PUB_LOG" \
    || pub_rc=$?
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  [[ "$pub_rc" == "124" ]] || {
    echo "FAIL: publish --sync with slow hq expected rc=124, got rc=$pub_rc" >&2
    cat "$SLOW_PUB_LOG" >&2 || true
    exit 1
  }
  if [[ "$elapsed" -gt 6 ]]; then
    echo "FAIL: publish timebox did not fire fast enough ($elapsed s for 1s timeout)" >&2
    exit 1
  fi
fi

echo "PASS: cross-device handoff carries handoff.json + referenced thread A→B"
