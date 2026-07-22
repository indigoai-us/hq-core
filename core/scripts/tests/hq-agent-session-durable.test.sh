#!/usr/bin/env bash
# hq-core: public
# US-408 / US-407: durable session writes — stable slug derivation, traversal
# rejection, bookkeeping exclusion, nonDurableWrites + artifacts reporting.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

export HOME="$TMP/home"
mkdir -p "$HOME"

# shellcheck source=/dev/null
. "$SRC_ROOT/core/scripts/lib/session-durable-writes.sh"

# ── 1. stable slug derivation across two turns ──────────────────────────────
CONV="agt_test#slack:C-durable-stable"
S1="$(session_project_slug_from_convkey "$CONV")"
S2="$(session_project_slug_from_convkey "$CONV")"
[ -n "$S1" ] || fail "empty slug"
[ "$S1" = "$S2" ] || fail "slug unstable: $S1 vs $S2"
S3="$(session_project_slug_from_convkey "different-key")"
[ "$S1" != "$S3" ] || fail "different convKeys produced same slug"
session_validate_project_slug "$S1" || fail "derived slug invalid: $S1"
pass "stable slug derivation"

# ── 2. traversal / invalid slug rejection ───────────────────────────────────
session_validate_project_slug '../escape' && fail "accepted ../escape"
session_validate_project_slug 'foo/bar' && fail "accepted foo/bar"
session_validate_project_slug 'HasUpper' && fail "accepted uppercase"
session_validate_project_slug '' && fail "accepted empty"
session_validate_project_slug 'good-slug-1' || fail "rejected good-slug-1"

ROOT="$TMP/hq"
mkdir -p "$ROOT/companies/indigo"
# Resolver must exit non-zero and create no dir for bad slug
RC=0
session_resolve_project_dir "$ROOT" "indigo" '../escape' "$CONV" >/dev/null 2>"$TMP/bad.err" || RC=$?
[ "$RC" -ne 0 ] || fail "resolver accepted ../escape"
[ ! -e "$ROOT/companies/indigo/projects/../escape" ] || fail "escape dir created"
# Also no literal '../escape' under projects
[ ! -d "$ROOT/companies/indigo/projects/../escape" ] 2>/dev/null || true
find "$ROOT/companies/indigo" -name '*escape*' 2>/dev/null | grep -q . && fail "escape path leaked" || true
pass "traversal rejection"

# ── 3. resolve creates project dir (export applies when not in $()) ─────────
# Entrypoint re-exports after capture; also call once without subshell to prove
# the function itself exports HQ_SESSION_PROJECT_DIR.
DIR="$(session_resolve_project_dir "$ROOT" "indigo" "" "$CONV")"
[ -d "$DIR" ] || fail "project dir not created: $DIR"
echo "$DIR" | grep -q "/companies/indigo/projects/" || fail "dir not under projects: $DIR"
# Direct call (no command substitution) stamps the env var for the process
unset HQ_SESSION_PROJECT_DIR
session_resolve_project_dir "$ROOT" "indigo" "" "$CONV" >/dev/null
[ "${HQ_SESSION_PROJECT_DIR:-}" = "$DIR" ] || fail "HQ_SESSION_PROJECT_DIR not exported (got=${HQ_SESSION_PROJECT_DIR:-})"
# Explicit project field
DIR2="$(session_resolve_project_dir "$ROOT" "indigo" "my-feature" "$CONV")"
[ -d "$DIR2" ] || fail "explicit project dir missing"
echo "$DIR2" | grep -q '/projects/my-feature$' || fail "explicit slug not used: $DIR2"
pass "resolve + export"

# ── 4. durable guidance contains literal $HQ_SESSION_PROJECT_DIR ────────────
SYS="$TMP/system.txt"
printf '<!-- hq-section: charter -->\nbase\n' > "$SYS"
export HQ_SESSION_PROJECT_DIR="$DIR"
session_append_durable_guidance "$SYS"
grep -F '$HQ_SESSION_PROJECT_DIR' "$SYS" || fail "missing literal \$HQ_SESSION_PROJECT_DIR"
grep -q 'durable-writes' "$SYS" || fail "missing durable-writes section"
pass "system guidance"

# ── 5. bookkeeping exclusion + nonDurableWrites ─────────────────────────────
mkdir -p "$ROOT/workspace/sessions/run-xyz" "$ROOT/workspace/locks" "$ROOT/workspace/scratch"
# Start epoch slightly in the past so our writes are newer
START=$(( $(date +%s) - 5 ))
# Bookkeeping (must be excluded)
printf 'company: indigo\n' > "$ROOT/workspace/sessions/run-xyz/meta.yaml"
printf 'run-xyz\n' > "$ROOT/workspace/sessions/.current"
printf 'lock\n' > "$ROOT/workspace/locks/turn.lock"
# Real residual write (must be reported)
printf 'plan\n' > "$ROOT/workspace/scratch/plan.md"
# Brief sleep so mtime is reliably newer on 1s-resolution FS
sleep 1
# Re-touch residual to guarantee newermt
touch "$ROOT/workspace/scratch/plan.md"

ND="$(session_collect_non_durable_writes "$ROOT" "$START")"
echo "$ND" | jq -e . >/dev/null || fail "nonDurable JSON invalid: $ND"
echo "$ND" | jq -e 'map(test("workspace/sessions")) | any | not' >/dev/null \
  || fail "sessions leaked into nonDurable: $ND"
echo "$ND" | jq -e 'map(test("workspace/locks")) | any | not' >/dev/null \
  || fail "locks leaked into nonDurable: $ND"
echo "$ND" | jq -e 'index("workspace/scratch/plan.md") != null' >/dev/null \
  || fail "plan.md missing from nonDurable: $ND"
pass "nonDurableWrites + bookkeeping exclusion"

# ── 6. artifacts under project dir ──────────────────────────────────────────
printf 'brainstorm notes\n' > "$DIR/brainstorm.md"
touch "$DIR/brainstorm.md"
ART="$(session_collect_project_artifacts "$ROOT" "$DIR" "$START")"
echo "$ART" | jq -e . >/dev/null || fail "artifacts JSON invalid: $ART"
echo "$ART" | jq -e --arg p "companies/indigo/projects/$(basename "$DIR")/brainstorm.md" \
  'index($p) != null' >/dev/null \
  || fail "brainstorm not in artifacts: $ART"
pass "project artifacts"

# ── 7. entrypoint integration (skip provider) ───────────────────────────────
FIXTURE="$TMP/hq-ep"
mkdir -p "$FIXTURE/core/schemas" "$FIXTURE/core/scripts" \
  "$FIXTURE/core/knowledge/public/hq-core" \
  "$FIXTURE/companies/indigo/settings" \
  "$FIXTURE/workspace/sessions" \
  "$FIXTURE/.claude/hooks"
cp "$SRC_ROOT/core/core.yaml" "$FIXTURE/core/core.yaml"
cp "$SRC_ROOT/core/schemas/"*.json "$FIXTURE/core/schemas/"
cp "$SRC_ROOT/core/scripts/hq-agent-session.sh" "$FIXTURE/core/scripts/"
cp -R "$SRC_ROOT/core/scripts/lib" "$FIXTURE/core/scripts/lib"
cp "$SRC_ROOT/core/scripts/hq-session.sh" "$FIXTURE/core/scripts/" 2>/dev/null || true
cp "$SRC_ROOT/.claude/hooks/master-hook.sh" "$FIXTURE/.claude/hooks/" 2>/dev/null || true
printf '# Formats\n\n## slack\n\nSlack.\n' \
  > "$FIXTURE/core/knowledge/public/hq-core/channel-writing-formats.md"
printf 'CHARTER\n' > "$FIXTURE/AGENTS.md"
printf 'COMPANY\n' > "$FIXTURE/companies/indigo/CLAUDE.md"
chmod +x "$FIXTURE/core/scripts/"*.sh "$FIXTURE/core/scripts/lib/"*.sh \
  "$FIXTURE/.claude/hooks/"*.sh 2>/dev/null || true

export HQ_AGENT_WORKDIR="$FIXTURE"
export HQ_AGENT_SESSION_SKIP_PROVIDER=1

REQ="$(jq -nc '{
  contractVersion: 1,
  agentUid: "agt_test",
  companySlug: "indigo",
  channel: "slack",
  convKey: "agt_test#slack:C-ep-durable",
  messageText: "plan something",
  provider: "claude",
  sender: {verified: true}
}')"
RC=0
OUT="$(printf '%s' "$REQ" | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/ep.err")" || RC=$?
[ "$RC" -eq 0 ] || fail "entrypoint exit $RC err=$(cat "$TMP/ep.err")"
echo "$OUT" | jq -e '.projectDir | type == "string" and test("companies/indigo/projects/")' >/dev/null \
  || fail "projectDir missing: $OUT"
PDIR="$(echo "$OUT" | jq -r .projectDir)"
[ -d "$PDIR" ] || fail "projectDir does not exist: $PDIR"
RUNDIR="$(echo "$OUT" | jq -r .runDir)"
grep -F '$HQ_SESSION_PROJECT_DIR' "$RUNDIR/system.txt" \
  || fail "system.txt missing durable guidance"
# Two turns same convKey → same projectDir
OUTB="$(printf '%s' "$REQ" | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/ep2.err")" || true
PDIRB="$(echo "$OUTB" | jq -r .projectDir)"
[ "$PDIR" = "$PDIRB" ] || fail "projectDir unstable across turns: $PDIR vs $PDIRB"
pass "entrypoint projectDir + guidance"

# Residual write via post-hoc: write into fixture workspace and re-collect
mkdir -p "$FIXTURE/workspace/scratch"
# shellcheck source=/dev/null
. "$SRC_ROOT/core/scripts/lib/session-durable-writes.sh"
START2=$(( $(date +%s) - 2 ))
printf 'lost-plan\n' > "$FIXTURE/workspace/scratch/lost.md"
touch "$FIXTURE/workspace/scratch/lost.md"
sleep 1
touch "$FIXTURE/workspace/scratch/lost.md"
ND2="$(session_collect_non_durable_writes "$FIXTURE" "$START2")"
echo "$ND2" | jq -e 'index("workspace/scratch/lost.md") != null' >/dev/null \
  || fail "entrypoint residual detect: $ND2"
pass "residual workspace write detection"

echo "PASS: hq-agent-session-durable.test.sh"
