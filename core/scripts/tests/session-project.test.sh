#!/usr/bin/env bash
# Smoke tests for native session project helper.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$ROOT/core/scripts/session-project.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label: missing '$needle' in $haystack"
}

mkdir -p "$TMP/personal/projects/native-project-journaling"
cat > "$TMP/personal/projects/native-project-journaling/prd.json" <<'JSON'
{
  "name": "native-project-journaling",
  "description": "Automatically journal native Claude and Codex executions into project folders and prd.json files.",
  "metadata": {
    "goal": "Native plan mode project capture"
  },
  "userStories": []
}
JSON

reuse_out=$(HQ_ROOT="$TMP" "$HELPER" ensure \
  --scope hq-core \
  --title "Native Codex executions automatically journal project prd files" \
  --prompt "native claude/codex executions automatically journal without startwork prd run-project" \
  --session-id test-reuse)

assert_contains "$reuse_out" '"reused": true' "related project reuse"
assert_contains "$reuse_out" 'personal/projects/native-project-journaling' "reuse path"

new_out=$(HQ_ROOT="$TMP" "$HELPER" ensure \
  --scope hq-core \
  --title "Totally Separate Durable Workstream" \
  --prompt "totally separate durable workstream for a new native session" \
  --session-id test-new \
  --reuse-threshold 99)

assert_contains "$new_out" '"reused": false' "new project creation"
assert_file "$TMP/personal/projects/totally-separate-durable-workstream/prd.json"
assert_file "$TMP/personal/projects/totally-separate-durable-workstream/README.md"

printf '## Plan\n\n- Do the thing.\n' | HQ_ROOT="$TMP" "$HELPER" ingest-plan >/tmp/session-project-plan-path.txt
plan_rel="$(cat /tmp/session-project-plan-path.txt)"
assert_file "$TMP/$plan_rel"

python3 - "$TMP/personal/projects/totally-separate-durable-workstream/prd.json" <<'PY' || fail "native plan not recorded"
import json
import sys
data = json.load(open(sys.argv[1]))
plans = data.get("metadata", {}).get("nativePlans", [])
assert plans and plans[-1]["path"].endswith("-native-plan.md")
PY

# Regression: a conflicted pointer is not a project path. It must fail closed
# rather than creating a directory tree whose names contain merge markers.
mkdir -p "$TMP/.claude/state"
printf '<<<<<<< HEAD\npersonal/projects/one\n=======\npersonal/projects/two\n>>>>>>> topic\n' \
  > "$TMP/.claude/state/active-session-project"
set +e
bad_pointer_out=$(printf '## Plan\n' | HQ_ROOT="$TMP" "$HELPER" ingest-plan 2>&1)
bad_pointer_status=$?
set -e
[[ "$bad_pointer_status" -ne 0 ]] || fail "conflicted active pointer was accepted"
assert_contains "$bad_pointer_out" "invalid active project pointer" "conflicted pointer rejection"
[[ ! -e "$TMP/<<<<<<< HEAD" ]] || fail "conflicted pointer created a filesystem path"
grep -qxF '.claude/state/active-session-project merge=binary' "$ROOT/.gitattributes" \
  || fail "active project pointer lacks binary merge protection"

# Regression: an explicit stale destination with no unique session match must
# fail closed. In particular, append-event must not recreate the old project.
set +e
stale_out=$(HQ_ROOT="$TMP" "$HELPER" append-event \
  --project personal/projects/moved-away \
  --session-id missing-session \
  --kind user-prompt \
  --summary "follow-up after move" 2>&1)
stale_status=$?
set -e
[[ "$stale_status" -ne 0 ]] || fail "stale project destination was accepted"
assert_contains "$stale_out" "cannot uniquely reconcile project" "stale destination rejection"
[[ ! -e "$TMP/personal/projects/moved-away" ]] || fail "stale destination recreated a project"


# ---------------------------------------------------------------------------
# Regression: the reuse matcher must not bind unrelated sessions.
#
# The old rule scored `overlap.length + slugHits.length` over the same query
# word set, and slugHits was a raw `name.includes(word)` substring test. A
# project slug is derived from its own originating prompt, which is also its
# description, so a single shared word scored 2 and cleared the default
# threshold of 2 on its own. One project absorbed 911 sessions from 905
# distinct session ids that way.
# ---------------------------------------------------------------------------

MATCH_ROOT="$TMP/matcher"
mkdir -p "$MATCH_ROOT/personal/projects/worktree-dev-server-github-hq-sync-pull"
cat > "$MATCH_ROOT/personal/projects/worktree-dev-server-github-hq-sync-pull/prd.json" <<'JSON'
{
  "name": "worktree-dev-server-github-hq-sync-pull",
  "description": "worktree dev server for github hq-sync pull requests",
  "metadata": { "goal": "worktree dev server" },
  "userStories": []
}
JSON

# One shared content word ("worktree") must NOT be enough to reuse.
one_word_out=$(HQ_ROOT="$MATCH_ROOT" "$HELPER" ensure \
  --title "Add a worktree for the billing importer" \
  --prompt "add a worktree for the billing importer" \
  --session-id test-one-word)
assert_contains "$one_word_out" '"reused": false' "single shared word must not reuse"

# A query word must match a whole slug word, never a substring of one. "git"
# is a substring of "github" and previously scored a slugHit.
substring_out=$(HQ_ROOT="$MATCH_ROOT" "$HELPER" find --query "git")
[[ "$(printf '%s' "$substring_out" | tr -d '[:space:]')" == "[]" ]] \
  || fail "substring slug match still scores: $substring_out"

# A genuinely related query still reuses.
related_out=$(HQ_ROOT="$MATCH_ROOT" "$HELPER" ensure \
  --title "Worktree dev server github checkout" \
  --prompt "worktree dev server github checkout" \
  --session-id test-related)
assert_contains "$related_out" '"reused": true' "related query must still reuse"
assert_contains "$related_out" 'worktree-dev-server-github-hq-sync-pull' "related reuse path"

# ---------------------------------------------------------------------------
# Regression: saturation breaker. A project that has already absorbed many
# sessions is an attractor, not a match, unless the query really covers its
# slug.
# ---------------------------------------------------------------------------

SAT_ROOT="$TMP/saturated"
mkdir -p "$SAT_ROOT/personal/projects/billing-importer-retry-backoff"
python3 - "$SAT_ROOT/personal/projects/billing-importer-retry-backoff/prd.json" <<'PY'
import json, sys
prd = {
    "name": "billing-importer-retry-backoff",
    "description": "billing importer retry backoff for stripe webhooks ledger reconciliation",
    "metadata": {
        "goal": "billing importer retry backoff",
        "nativeSessions": [
            {"ts": "2026-01-01T00:00:00Z", "sessionId": "s%d" % i, "prompt": "", "reused": True}
            for i in range(30)
        ],
    },
    "userStories": [],
}
json.dump(prd, open(sys.argv[1], "w"), indent=2)
PY

# Four shared words, but none of them the project's own subject: skipped.
sat_out=$(HQ_ROOT="$SAT_ROOT" "$HELPER" ensure \
  --title "Stripe webhooks ledger reconciliation deep dive" \
  --prompt "stripe webhooks ledger reconciliation deep dive" \
  --session-id test-saturated)
assert_contains "$sat_out" '"reused": false' "saturated project must not absorb a loose match"

# Covering the project's own slug words still reuses it.
sat_strong_out=$(HQ_ROOT="$SAT_ROOT" "$HELPER" ensure \
  --title "Billing importer retry semantics" \
  --prompt "billing importer retry semantics" \
  --session-id test-saturated-strong)
assert_contains "$sat_strong_out" '"reused": true' "strong slug match must still reuse"
assert_contains "$sat_strong_out" 'billing-importer-retry-backoff' "strong slug reuse path"

# ---------------------------------------------------------------------------
# Regression: an unparseable prd.json must never be overwritten. It used to be
# read through a catch-all that returned null, coerced to {}, and written back
# as a metadata-only stub — destroying the project's name, description and
# user stories. Seven project files were flattened that way in the field.
# ---------------------------------------------------------------------------

CORRUPT_ROOT="$TMP/corrupt"
CORRUPT_DIR="$CORRUPT_ROOT/personal/projects/quantum-ledger-migration"
mkdir -p "$CORRUPT_DIR"
printf '{\n  "name": "quantum-ledger-migration",\n  "userStories": [\n' > "$CORRUPT_DIR/prd.json"
corrupt_before="$(cksum < "$CORRUPT_DIR/prd.json")"

assert_corrupt_intact() {
  local now
  now="$(cksum < "$CORRUPT_DIR/prd.json")"
  [[ "$now" == "$corrupt_before" ]] || fail "$1: unparseable prd.json was rewritten"
}

# ensure: a slug collision lands on the existing directory. It must refuse.
set +e
corrupt_ensure_out=$(HQ_ROOT="$CORRUPT_ROOT" "$HELPER" ensure \
  --title "quantum ledger migration" \
  --prompt "quantum ledger migration" \
  --session-id test-corrupt 2>&1)
corrupt_ensure_status=$?
set -e
[[ "$corrupt_ensure_status" -ne 0 ]] || fail "ensure accepted an unparseable prd.json"
assert_contains "$corrupt_ensure_out" "refusing to overwrite unparseable" "ensure corrupt refusal"
assert_corrupt_intact "ensure"

# ingest-plan: same refusal, same file left alone.
set +e
corrupt_plan_out=$(printf '## Plan\n\n- Do the thing.\n' | HQ_ROOT="$CORRUPT_ROOT" "$HELPER" ingest-plan \
  --project personal/projects/quantum-ledger-migration 2>&1)
corrupt_plan_status=$?
set -e
[[ "$corrupt_plan_status" -ne 0 ]] || fail "ingest-plan accepted an unparseable prd.json"
assert_contains "$corrupt_plan_out" "refusing to overwrite unparseable" "ingest-plan corrupt refusal"
assert_corrupt_intact "ingest-plan"

# append-event: must fail closed rather than silently rehoming the event into
# some other project and leaving the damage unreported.
set +e
corrupt_event_out=$(HQ_ROOT="$CORRUPT_ROOT" "$HELPER" append-event \
  --project personal/projects/quantum-ledger-migration \
  --session-id test-corrupt \
  --kind user-prompt \
  --summary "follow-up" 2>&1)
corrupt_event_status=$?
set -e
[[ "$corrupt_event_status" -ne 0 ]] || fail "append-event accepted an unparseable prd.json"
assert_contains "$corrupt_event_out" "refusing to overwrite unparseable" "append-event corrupt refusal"
assert_corrupt_intact "append-event"

echo "session-project smoke: ok"
