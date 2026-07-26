#!/usr/bin/env bash
# Regression coverage for rebuild-orchestrator-index.sh.
#
# Verifies the INDEX generator tolerates BOTH on-disk state schemas side by side:
#   - project-run state (run-project.sh): .project / .prd_path / .progress,
#     terminal on .status == "completed"
#   - garden state (/garden): .run_id / .scope, terminal on .phase == "complete"
# Project-run rows must be byte-identical to the pre-change output. A malformed
# state.json must warn on stderr and must NOT wipe the rest of the index
# (hq-never-swallow-errors).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/rebuild-orchestrator-index.sh"

ASSERTIONS=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# assert_contains <file> <fixed-string> <label>
assert_contains() {
  grep -Fq -- "$2" "$1" || fail "$3 (expected to find: $2)"
  ASSERTIONS=$((ASSERTIONS + 1))
}

# assert_absent <file> <fixed-string> <label>
assert_absent() {
  if grep -Fq -- "$2" "$1"; then
    fail "$3 (unexpectedly found: $2)"
  fi
  ASSERTIONS=$((ASSERTIONS + 1))
}

write_state() {
  # write_state <hq_root> <rel-dir> <json>
  mkdir -p "$1/workspace/orchestrator/$2"
  printf '%s\n' "$3" > "$1/workspace/orchestrator/$2/state.json"
}

# --------------------------------------------------------------------------
# Scenario A: mixed schemas in one orchestrator dir.
# --------------------------------------------------------------------------
ROOT_A="$(mktemp -d)"
trap 'rm -rf "$ROOT_A" "${ROOT_B:-}" "${ROOT_C:-}"' EXIT

# project-run, in progress — must render byte-identically to today.
write_state "$ROOT_A" "proj-active" \
  '{"project":"acme-proj","prd_path":"companies/indigo/projects/acme-proj/prd.json","status":"in_progress","progress":{"completed":2,"total":5},"updated_at":"2026-07-26T10:00:00Z"}'

# project-run, completed — excluded on .status == "completed".
write_state "$ROOT_A" "proj-done" \
  '{"project":"done-proj","prd_path":"companies/indigo/projects/done-proj/prd.json","status":"completed","progress":{"completed":5,"total":5},"updated_at":"2026-07-26T09:00:00Z"}'

# garden, in progress, companies/ scope — run_id label, company parsed, progress "-".
write_state "$ROOT_A" "garden-active" \
  '{"run_id":"garden-20260726-abc","scope":"companies/indigo/knowledge","phase":"scanning","status":"in_progress","findings_count":3,"updated_at":"2026-07-26T11:00:00Z"}'

# garden, in progress, bare-slug scope — company column "-".
write_state "$ROOT_A" "garden-bare" \
  '{"run_id":"garden-bare","scope":"acme","phase":"scanning","status":"in_progress","updated_at":"2026-07-26T12:00:00Z"}'

# garden, phase complete — the load-bearing exclusion.
write_state "$ROOT_A" "garden-phase-done" \
  '{"run_id":"garden-phase-done","scope":"companies/indigo/knowledge","phase":"complete","status":"in_progress","updated_at":"2026-07-26T08:00:00Z"}'

# garden, status complete — drift guard (garden should never write this, but may).
write_state "$ROOT_A" "garden-drift-done" \
  '{"run_id":"garden-drift-done","scope":"companies/indigo/knowledge","phase":"scanning","status":"complete","updated_at":"2026-07-26T07:00:00Z"}'

# _archive and _pipeline entries at depth 2 — excluded by the path greps.
write_state "$ROOT_A" "_archive" \
  '{"project":"archived-proj","prd_path":"companies/indigo/projects/archived-proj/prd.json","status":"in_progress","progress":{"completed":1,"total":2},"updated_at":"2026-07-26T06:00:00Z"}'
write_state "$ROOT_A" "_pipeline" \
  '{"project":"pipeline-proj","prd_path":"companies/indigo/projects/pipeline-proj/prd.json","status":"in_progress","progress":{"completed":1,"total":3},"updated_at":"2026-07-26T05:00:00Z"}'

HQ_ROOT="$ROOT_A" bash "$SCRIPT" 2>/dev/null
INDEX_A="$ROOT_A/workspace/orchestrator/INDEX.md"
[ -f "$INDEX_A" ] || fail "scenario A: INDEX.md not written"

# Byte-identical project-run row (AC #3 — exact table line).
assert_contains "$INDEX_A" '| acme-proj | indigo | in_progress | 2/5 | 2026-07-26T10:00:00Z |' \
  "project-run in-progress row is not byte-identical"

# Garden in-progress: run_id in project column, company parsed, progress "-".
assert_contains "$INDEX_A" '| garden-20260726-abc | indigo | in_progress | - | 2026-07-26T11:00:00Z |' \
  "garden in-progress row (run_id + companies scope + progress -) missing"

# Garden bare-slug scope: company column "-".
assert_contains "$INDEX_A" '| garden-bare | - | in_progress | - | 2026-07-26T12:00:00Z |' \
  "garden bare-slug scope row (company -) missing"

# Exclusions.
assert_absent "$INDEX_A" 'done-proj' "completed project-run was not excluded"
assert_absent "$INDEX_A" 'garden-phase-done' "garden phase:complete was not excluded"
assert_absent "$INDEX_A" 'garden-drift-done' "garden status:complete drift guard failed"
assert_absent "$INDEX_A" 'archived-proj' "_archive entry was not excluded"
assert_absent "$INDEX_A" 'pipeline-proj' "_pipeline entry was not excluded"

# --------------------------------------------------------------------------
# Scenario B: empty orchestrator dir -> header-only index.
# --------------------------------------------------------------------------
ROOT_B="$(mktemp -d)"
mkdir -p "$ROOT_B/workspace/orchestrator"
HQ_ROOT="$ROOT_B" bash "$SCRIPT" 2>/dev/null
INDEX_B="$ROOT_B/workspace/orchestrator/INDEX.md"
[ -f "$INDEX_B" ] || fail "scenario B: INDEX.md not written for empty dir"
assert_contains "$INDEX_B" '# Orchestrator Projects' "header missing from empty index"
# Only the two structural table lines (header + separator), no data rows.
table_lines=$(grep -c '^|' "$INDEX_B" || true)
[ "$table_lines" = "2" ] || fail "empty index has data rows (found $table_lines '^|' lines, expected 2)"
ASSERTIONS=$((ASSERTIONS + 1))

# --------------------------------------------------------------------------
# Scenario C: malformed state.json warns and does NOT empty the index.
# --------------------------------------------------------------------------
ROOT_C="$(mktemp -d)"
write_state "$ROOT_C" "good-proj" \
  '{"project":"good-proj","prd_path":"companies/indigo/projects/good-proj/prd.json","status":"in_progress","progress":{"completed":1,"total":4},"updated_at":"2026-07-26T13:00:00Z"}'
# broken file — invalid JSON.
mkdir -p "$ROOT_C/workspace/orchestrator/broken-proj"
printf '%s\n' 'this is not { valid json' > "$ROOT_C/workspace/orchestrator/broken-proj/state.json"

STDERR_C=$(HQ_ROOT="$ROOT_C" bash "$SCRIPT" 2>&1 >/dev/null)
INDEX_C="$ROOT_C/workspace/orchestrator/INDEX.md"
[ -f "$INDEX_C" ] || fail "scenario C: INDEX.md not written"

case "$STDERR_C" in
  *"skipped unparseable"*) ASSERTIONS=$((ASSERTIONS + 1)) ;;
  *) fail "malformed state.json did not emit a warning to stderr" ;;
esac
# The valid row survives — the malformed file did not wipe the index.
assert_contains "$INDEX_C" '| good-proj | indigo | in_progress | 1/4 | 2026-07-26T13:00:00Z |' \
  "valid row was wiped by a malformed sibling state.json"

echo "PASS ($ASSERTIONS assertions)"
