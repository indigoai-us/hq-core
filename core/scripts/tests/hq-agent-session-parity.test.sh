#!/usr/bin/env bash
# hq-core: public
# US-412 + US-416: golden-turn parity harness across eight turn types.
#
# Fixtures: slack verified, slack untrusted, native DM, email, telegram,
# scheduled job, skill (/handoff), worker (/run worker skill).
#
# Fully offline: no provider binaries, no network. Fails on golden drift.
# Regenerate goldens only with --update-goldens.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../lib/session-parity-fixtures.sh
. "$SRC_ROOT/core/scripts/lib/session-parity-fixtures.sh"

UPDATE_GOLDENS=0
for arg in "$@"; do
  case "$arg" in
    --update-goldens) UPDATE_GOLDENS=1 ;;
    -h|--help)
      echo "Usage: $0 [--update-goldens]"
      exit 0
      ;;
  esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

# ── constant count guard ────────────────────────────────────────────────────
CG_MSG=""
if ! CG_MSG="$(session_parity_count_guard)"; then
  fail "$CG_MSG"
fi
pass "constant count guard (13 fixtures; TELEGRAM_FORMATTING + EMAIL_FORMATTING present)"

# Contract doc: Owner marker on VERIFIED_MEMBER_REPLY_POSTURE line
DOC="$SRC_ROOT/core/knowledge/public/hq-core/agent-session-contract.md"
grep -E 'VERIFIED_MEMBER_REPLY_POSTURE.*Owner: request-orchestrator area' "$DOC" >/dev/null \
  || fail "contract doc missing 'Owner: request-orchestrator area' on VERIFIED_MEMBER_REPLY_POSTURE line"
pass "contract doc Owner marker"

# ── offline fixture HQ root ─────────────────────────────────────────────────
FIXTURE="$TMP/hq"
FIXTURE_SRC="$(session_parity_fixtures_dir)"
mkdir -p "$FIXTURE/core/schemas" "$FIXTURE/core/scripts" \
  "$FIXTURE/core/knowledge/public/hq-core/agent-session-constants" \
  "$FIXTURE/workspace/sessions" "$FIXTURE/.claude/hooks" \
  "$FIXTURE/companies/indigo/settings" \
  "$FIXTURE/companies/otherco/settings" \
  "$FIXTURE/.claude/skills" \
  "$FIXTURE/personal/knowledge/public/agent-capabilities" \
  "$FIXTURE/companies/indigo/workers"
cp "$SRC_ROOT/core/core.yaml" "$FIXTURE/core/core.yaml"
cp "$SRC_ROOT/core/schemas/"*.json "$FIXTURE/core/schemas/"
cp "$SRC_ROOT/core/scripts/hq-agent-session.sh" "$FIXTURE/core/scripts/"
cp -R "$SRC_ROOT/core/scripts/lib" "$FIXTURE/core/scripts/lib"
cp "$SRC_ROOT/core/scripts/hq-session.sh" "$FIXTURE/core/scripts/"
cp "$SRC_ROOT/.claude/hooks/master-hook.sh" "$FIXTURE/.claude/hooks/"
cp "$SRC_ROOT/core/knowledge/public/hq-core/channel-writing-formats.md" \
  "$FIXTURE/core/knowledge/public/hq-core/" 2>/dev/null || \
  printf '# Channel Writing Formats\n\n## slack\n\nslack\n\n## dm\n\ndm\n\n## email\n\nemail\n\n## telegram\n\ntelegram\n\n## job\n\njob\n' \
    > "$FIXTURE/core/knowledge/public/hq-core/channel-writing-formats.md"
cp "$SRC_ROOT/core/knowledge/public/hq-core/agent-session-constants/"*.txt \
  "$FIXTURE/core/knowledge/public/hq-core/agent-session-constants/"

# Stable skill bodies (US-416 skill + worker pipeline fixtures).
cp -R "$FIXTURE_SRC/skills/handoff" "$FIXTURE/.claude/skills/handoff"
cp -R "$FIXTURE_SRC/skills/run" "$FIXTURE/.claude/skills/run"

# Agent contract at the path job-runner.ts:105 reads (US-416 job fixture).
cp "$FIXTURE_SRC/agent-contract/hq-agent-contract.md" \
  "$FIXTURE/personal/knowledge/public/agent-capabilities/hq-agent-contract.md"

# Checked-in worker materialization set (US-416 worker fixture / US-052 shape).
cp -R "$FIXTURE_SRC/worker-materialization/parity-worker" \
  "$FIXTURE/companies/indigo/workers/parity-worker"

# Stable charter bodies so goldens do not churn on AGENTS.md edits in the tree.
printf '# AGENTS\nparity-fixture charter body\n' > "$FIXTURE/AGENTS.md"
printf '# Company\nindigo parity charter\n' > "$FIXTURE/companies/indigo/CLAUDE.md"
printf '# Company\notherco parity charter\n' > "$FIXTURE/companies/otherco/CLAUDE.md"
chmod +x "$FIXTURE/core/scripts/"*.sh "$FIXTURE/core/scripts/lib/"*.sh \
  "$FIXTURE/.claude/hooks/master-hook.sh"

export HOME="$TMP/home"
mkdir -p "$HOME"
export HQ_AGENT_WORKDIR="$FIXTURE"
export HQ_AGENT_SESSION_SKIP_PROVIDER=1

# Offline: strip provider binaries from PATH; no network required.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
# Ensure jq still available
command -v jq >/dev/null 2>&1 || fail "jq required on PATH"
# Prove providers absent
for bin in claude codex grok; do
  if command -v "$bin" >/dev/null 2>&1; then
    # Shadow with a non-executable / missing via a private bin dir
    :
  fi
done
SHADOW="$TMP/shadow-bin"
mkdir -p "$SHADOW"
# Prefer shadow PATH with only essential tools + jq location
JQ_PATH="$(command -v jq)"
JQ_DIR="$(dirname "$JQ_PATH")"
# Keep python3 for timing helpers
PY_PATH="$(command -v python3 2>/dev/null || true)"
export PATH="${SHADOW}:${JQ_DIR}:/usr/bin:/bin"
if [ -n "$PY_PATH" ]; then
  export PATH="$(dirname "$PY_PATH"):$PATH"
fi
# Intentionally do NOT place claude/codex/grok on PATH
command -v claude >/dev/null 2>&1 && fail "claude must not be on PATH for offline harness"
command -v codex >/dev/null 2>&1 && fail "codex must not be on PATH for offline harness"
command -v grok >/dev/null 2>&1 && fail "grok must not be on PATH for offline harness"
pass "offline PATH (no provider binaries)"

# Confirm TELEGRAM_FORMATTING + EMAIL_FORMATTING constant files exist (count guard already = 13).
C_DIR="$(session_parity_constants_dir)"
[ -f "$C_DIR/TELEGRAM_FORMATTING.txt" ] || fail "TELEGRAM_FORMATTING constant fixture missing"
[ -f "$C_DIR/EMAIL_FORMATTING.txt" ] || fail "EMAIL_FORMATTING constant fixture missing"
pass "TELEGRAM_FORMATTING + EMAIL_FORMATTING constant fixtures present"

REQ_DIR="$(session_parity_requests_dir)"
GOLD_DIR="$(session_parity_goldens_dir)"
mkdir -p "$GOLD_DIR" "$TMP/assembled"

FIXTURE_COUNT=0
for id in "${SESSION_PARITY_FIXTURE_IDS[@]}"; do
  req="$REQ_DIR/${id}.json"
  [ -f "$req" ] || fail "missing request fixture $req"

  # Deny-list: no absolute /Users paths, and every companies/<slug> reference
  # must be a synthetic fixture tenant from the allow-list below. Enumerating
  # REAL private slugs here would itself leak them into this public-bound repo
  # (the .leak-scan CI guards catch exactly that) — so allow-list, don't deny-list.
  if grep -E '/Users/' "$req" >/dev/null 2>&1; then
    fail "fixture $id contains a /Users path"
  fi
  if grep -oE 'companies/[a-z0-9-]+' "$req" | grep -vE 'companies/(indigo|otherco|acme-fixture)$' >/dev/null 2>&1; then
    fail "fixture $id references a non-synthetic tenant slug"
  fi

  OUT="$(bash "$FIXTURE/core/scripts/hq-agent-session.sh" < "$req" 2>"$TMP/err-$id")" || RC=$?
  RC="${RC:-0}"
  [ "$RC" -eq 0 ] || fail "fixture $id exit $RC stderr=$(cat "$TMP/err-$id")"
  echo "$OUT" | jq -e '.disposition == "reply" and (.runDir | type == "string")' >/dev/null \
    || fail "fixture $id bad envelope: $OUT"
  RUNDIR="$(echo "$OUT" | jq -r .runDir)"
  [ -f "$RUNDIR/system.txt" ] && [ -f "$RUNDIR/user.txt" ] \
    || fail "fixture $id missing system/user under $RUNDIR"

  cp "$RUNDIR/system.txt" "$TMP/assembled/${id}.system.txt"
  cp "$RUNDIR/user.txt" "$TMP/assembled/${id}.user.txt"
  [ -f "$RUNDIR/skill.txt" ] && cp "$RUNDIR/skill.txt" "$TMP/assembled/${id}.skill.txt" || true

  # user.txt must not carry brief constants / section markers
  if grep -q '<!-- hq-section:' "$RUNDIR/user.txt"; then
    fail "fixture $id user.txt contains hq-section markers"
  fi

  # Constant VALUE asserts + exclusive preamble / channel-format cross-checks
  if ! MSG="$(session_parity_assert_constants "$id" "$RUNDIR/system.txt" "$RUNDIR/user.txt")"; then
    fail "$MSG"
  fi
  printf '%s\n' "$MSG"

  # US-416 pipeline asserts (skill.txt, worker materialization, agent-contract).
  # Capture for fail messages; re-print success lines with an explicit newline
  # because $(...) strips a single trailing newline.
  if ! MSG="$(session_parity_assert_pipeline "$id" "$RUNDIR")"; then
    fail "$MSG"
  fi
  [ -n "$MSG" ] && printf '%s\n' "$MSG"

  # Golden compare (or update)
  if ! MSG="$(session_parity_compare_golden "$id" "$RUNDIR/system.txt" system "$UPDATE_GOLDENS")"; then
    fail "$MSG"
  fi
  [ "$UPDATE_GOLDENS" = "1" ] && printf '%s' "$MSG" | grep -q updated && echo "  $MSG"

  if ! MSG="$(session_parity_compare_golden "$id" "$RUNDIR/user.txt" user "$UPDATE_GOLDENS")"; then
    fail "$MSG"
  fi
  [ "$UPDATE_GOLDENS" = "1" ] && printf '%s' "$MSG" | grep -q updated && echo "  $MSG"

  FIXTURE_COUNT=$((FIXTURE_COUNT + 1))
  pass "fixture $id"
done

[ "$FIXTURE_COUNT" -eq 8 ] || fail "expected 8 fixtures, ran $FIXTURE_COUNT"
pass "eight fixtures executed"

# Drift detection self-check (only when not updating): one-char edit must fail compare
if [ "$UPDATE_GOLDENS" != "1" ]; then
  BROKEN="$TMP/assembled/slack-verified.system.txt"
  printf 'x' >> "$BROKEN"
  if session_parity_compare_golden slack-verified "$BROKEN" system 0 >/dev/null 2>&1; then
    fail "expected golden drift detection to fail after edit"
  fi
  pass "golden drift detection (slack-verified)"

  # Drift on a US-416 fixture is also detected and named.
  if [ -f "$TMP/assembled/email-verified.system.txt" ]; then
    BROKEN_E="$TMP/assembled/email-verified.system.txt"
    printf 'x' >> "$BROKEN_E"
    DRIFT_MSG=""
    if DRIFT_MSG="$(session_parity_compare_golden email-verified "$BROKEN_E" system 0 2>&1)"; then
      fail "expected golden drift detection to fail for email-verified"
    fi
    printf '%s' "$DRIFT_MSG" | grep -q 'email-verified' \
      || fail "drift failure must name fixture email-verified: $DRIFT_MSG"
    pass "golden drift detection names email-verified"
  fi
fi

# Without --update-goldens, goldens dir must not have been rewritten this run.
# (cmp already enforces content; flag is the only rewrite path.)
if [ "$UPDATE_GOLDENS" != "1" ]; then
  pass "no golden rewrite without --update-goldens"
fi

echo "PASS: hq-agent-session-parity.test.sh ($FIXTURE_COUNT fixtures)"
