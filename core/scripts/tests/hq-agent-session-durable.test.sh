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

# ── residual scan prunes dependency/VCS trees (fleet-box hang regression) ───
# A node_modules tree under the scanned dir once cost >400s (2 subprocesses
# per file); the scan must skip node_modules/.git/.pnpm and still find real
# files, in both the GNU fast path and the portable fallback.
SCAN="$TMP/scan[bracket]"
mkdir -p "$SCAN/node_modules/dep" "$SCAN/.git" "$SCAN/.pnpm" \
  "$SCAN/.session-logs/grok/session" "$SCAN/real"
echo x > "$SCAN/real/artifact.txt"
echo x > "$SCAN/node_modules/dep/index.js"
echo x > "$SCAN/.git/config"
echo x > "$SCAN/.pnpm/pkg.js"
echo x > "$SCAN/.session-logs/grok/session/events.jsonl"
FOUND="$(_session_find_newer "$SCAN" 0 workspace)"
printf '%s\n' "$FOUND" | grep -q 'real/artifact.txt' || fail "residual scan missed real artifact"
printf '%s\n' "$FOUND" | grep -q 'node_modules' && fail "residual scan descended into node_modules"
printf '%s\n' "$FOUND" | grep -q '.git/config' && fail "residual scan descended into .git"
printf '%s\n' "$FOUND" | grep -q '.pnpm' && fail "residual scan descended into .pnpm"
printf '%s\n' "$FOUND" | grep -q '.session-logs' && fail "residual scan descended into provider session logs"
pass "GNU residual scan prunes node_modules/.git/.pnpm/.session-logs"

# The helper also scans durable project trees. A project-owned directory with
# the same basename remains a legitimate artifact; only the top-level workspace
# telemetry tree is implementation-owned.
FOUND_PROJECT="$(_session_find_newer "$SCAN" 0 any)"
printf '%s\n' "$FOUND_PROJECT" | grep -q '.session-logs/grok/session/events.jsonl' \
  || fail "project artifact scan incorrectly pruned a user .session-logs directory"
pass "project artifact scan retains user .session-logs directories"

# Force _session_find_newer through its portable fallback and prove the same
# provider-log boundary there. The production incident was Linux/GNU, but a
# one-sided prune would leave macOS/BSD sessions with the identical failure.
SYSTEM_FIND="$(command -v find)"
find() {
  if [ "$*" = "$SCAN -maxdepth 0 -newermt @0" ]; then
    return 1
  fi
  "$SYSTEM_FIND" "$@"
}
FOUND_PORTABLE="$(_session_find_newer "$SCAN" 0 workspace)"
unset -f find
printf '%s\n' "$FOUND_PORTABLE" | grep -q 'real/artifact.txt' \
  || fail "portable residual scan missed real artifact"
printf '%s\n' "$FOUND_PORTABLE" | grep -q '.session-logs' \
  && fail "portable residual scan descended into provider session logs"
pass "portable residual scan prunes provider session logs"

# ── Serialisation: one jq for the stream, and a hard cap ────────────────────
#
# Regression: Izzy discarded completed turns as "unexpected failure (exit 0)".
# _session_paths_to_json_array called `jq -nc --arg p "$rel" '$p'` PER PATH,
# purely to JSON-escape one short string. A turn touching ~47k workspace files
# cost ~47k process spawns in post-turn bookkeeping -- after the model had
# answered -- which outran the dispatch lane's 900s absolute cap. The engine
# was killed before it emitted and the finished reply was thrown away.
JQROOT="$(mktemp -d)"

# Escaping is the reason jq is here at all: paths carry quotes, backslashes,
# tabs and non-ASCII. Assert the DECODED values, so the test pins behaviour
# rather than one particular escaping spelling.
ESC="$(printf '%s\n' \
  "$JQROOT/workspace/plain.md" \
  "$JQROOT/workspace/it's a \"quoted\" file.md" \
  "$JQROOT/workspace/back\\slash.md" \
  "$JQROOT/workspace/uni-café-日本.md" \
  | _session_paths_to_json_array "$JQROOT" workspace)"
printf '%s' "$ESC" | jq -e 'type == "array"' >/dev/null \
  || fail "path array is not valid JSON: $ESC"
# Compare via --arg so the expectation is a literal shell string; writing these
# inline makes the test about jq's own escaping spelling rather than about the
# value that survives the round trip.
printf '%s' "$ESC" | jq -e --arg w "workspace/it's a \"quoted\" file.md" '.[1] == $w' >/dev/null \
  || fail "quotes/apostrophes not round-tripped: $ESC"
printf '%s' "$ESC" | jq -e --arg w 'workspace/back\slash.md' '.[2] == $w' >/dev/null \
  || fail "backslash not round-tripped: $ESC"
printf '%s' "$ESC" | jq -e --arg w "workspace/uni-café-日本.md" '.[3] == $w' >/dev/null \
  || fail "non-ASCII not round-tripped: $ESC"
pass "path array JSON-escapes quotes, backslashes and non-ASCII"

# Empty input must still be a valid empty array, not "[" or "".
EMPTY="$(printf '' | _session_paths_to_json_array "$JQROOT" workspace)"
[ "$EMPTY" = "[]" ] || fail "empty input produced '$EMPTY', expected []"
pass "empty input yields []"

# The cap is what makes the failure mode impossible rather than merely faster.
BIG="$(i=1; while [ "$i" -le 300 ]; do printf '%s\n' "$JQROOT/workspace/f$i.md"; i=$((i+1)); done)"
CAPPED="$(printf '%s\n' "$BIG" | SESSION_PATHS_MAX=50 _session_paths_to_json_array "$JQROOT" workspace 2>/dev/null | jq 'length')"
[ "$CAPPED" = "50" ] || fail "SESSION_PATHS_MAX not honoured: got $CAPPED entries, expected 50"
WARN="$(printf '%s\n' "$BIG" | SESSION_PATHS_MAX=50 _session_paths_to_json_array "$JQROOT" workspace 2>&1 >/dev/null | grep -c 'truncated')"
[ "$WARN" = "1" ] || fail "truncation warned $WARN times, expected exactly 1"
pass "path array caps at SESSION_PATHS_MAX and says so once"

# The defect itself: jq must NOT be invoked per path. Bound the process count by
# shadowing jq with a counting wrapper.
JQ_REAL="$(command -v jq)"
JQ_COUNT="$JQROOT/jq-calls"
: > "$JQ_COUNT"
jq() { echo x >> "$JQ_COUNT"; "$JQ_REAL" "$@"; }
printf '%s\n' "$BIG" | SESSION_PATHS_MAX=999999 _session_paths_to_json_array "$JQROOT" workspace >/dev/null
unset -f jq
CALLS="$(wc -l < "$JQ_COUNT" | tr -d ' ')"
[ "$CALLS" -le 2 ] \
  || fail "jq invoked $CALLS times for 300 paths — the per-path spawn is back (must be O(1), not O(paths))"
pass "serialises 300 paths with $CALLS jq process(es), not one per path"

rm -rf "$JQROOT"

echo "PASS: hq-agent-session-durable.test.sh"
