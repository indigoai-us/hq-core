#!/usr/bin/env bash
# Large-changeset regression tests for handoff-finalize.sh (feedback_39891a53).
#
# On Windows Git Bash, CreateProcess caps a command line at ~32KB (~8KB under
# cmd.exe). /handoff used to inline the whole changeset into --files-touched-json,
# which then rode argv through hq-status-summary.sh and two jq calls. This suite
# proves the file-based path keeps the giant JSON off argv at every hop while the
# emitted thread JSON still carries every path.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

ASSERTIONS=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass_assert() {
  ASSERTIONS=$((ASSERTIONS + 1))
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
  pass_assert
}

# -------- harness: assemble a temp HQ root with the scripts under test --------
mkdir -p "$TMP_ROOT/repo/core/scripts" "$TMP_ROOT/repo/.claude/hooks" \
  "$TMP_ROOT/repo/workspace/baseline" "$TMP_ROOT/repo/workspace/threads" \
  "$TMP_ROOT/repo/workspace/orchestrator"
cp "$SRC_ROOT/scripts/handoff-finalize.sh" "$TMP_ROOT/repo/core/scripts/handoff-finalize.sh"
cp "$SRC_ROOT/scripts/hq-status-summary.sh" "$TMP_ROOT/repo/core/scripts/hq-status-summary.sh"
cp "$SRC_ROOT/../.claude/hooks/mirror-thread-to-company.sh" "$TMP_ROOT/repo/.claude/hooks/mirror-thread-to-company.sh"
chmod +x "$TMP_ROOT/repo/core/scripts/"*.sh
chmod -x "$TMP_ROOT/repo/.claude/hooks/mirror-thread-to-company.sh"

cat > "$TMP_ROOT/repo/core/scripts/rebuild-threads-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/threads
echo "# Threads" > workspace/threads/INDEX.md
echo "- recent" > workspace/threads/recent.md
SH
cat > "$TMP_ROOT/repo/core/scripts/rebuild-orchestrator-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/orchestrator
echo "# Orchestrator" > workspace/orchestrator/INDEX.md
SH
chmod +x "$TMP_ROOT/repo/core/scripts/rebuild-threads-index.sh" "$TMP_ROOT/repo/core/scripts/rebuild-orchestrator-index.sh"

cat > "$TMP_ROOT/repo/workspace/baseline/hq-local-baseline.json" <<'JSON'
{"categories":[{"name":"baseline","patterns":["companies/*","workspace/*","repos/*","core/settings/*",".hq/*"]}]}
JSON

cd "$TMP_ROOT/repo"
git init -q
git config user.email test@example.invalid
git config user.name "Handoff Large Test"

# Mirror production ignore so handoff temps under .handoff-tmp/ stay out of status.
printf '%s\n' 'workspace/threads/.handoff-tmp/' > .gitignore

echo "readme" > README.md
git add README.md .gitignore core/scripts workspace/baseline/hq-local-baseline.json
git commit -qm "base"

# -------- build a 5000-path changeset on disk (never on argv) --------
# The paths reference real, already-committed files so the changeset mirrors a
# genuine large session changeset (files exist -> staged_paths grows to 5000).
# Committing them first keeps `git status` clean, so this test measures the argv
# plumbing rather than status-classification cost.
mkdir -p workspace/gen
i=0
while [ "$i" -lt 5000 ]; do
  : > "workspace/gen/file_$i.ts"
  i=$((i + 1))
done
git add workspace/gen
git commit -qm "5000 generated files"

CHANGESET_FILE="workspace/threads/.large-changeset.json"
jq -n -c '[range(0;5000) | "workspace/gen/file_\(.).ts"]' > "$CHANGESET_FILE"
assert_eq "$(jq -r 'length' "$CHANGESET_FILE")" "5000" "changeset fixture has 5000 paths"

# Case: the constructed argv stays under 8192 bytes for a 5000-path changeset.
# Measure the command WE build, not the host's ARG_MAX (Linux ~2MB would never
# fail). Also assert the equivalent inline JSON would have blown past the limit,
# so this test is not vacuous.
inline_json=$(cat "$CHANGESET_FILE")
inline_len=${#inline_json}
[[ "$inline_len" -gt 8192 ]] || fail "inline changeset only $inline_len bytes — fixture too small to exercise the overflow"
pass_assert

file_argv="core/scripts/handoff-finalize.sh --title Handoff --summary x --message x --next-steps-json [] --files-touched-json-file ${CHANGESET_FILE} --learnings-json [] --tags-json [\"handoff\"] --slug large"
file_len=${#file_argv}
[[ "$file_len" -lt 8192 ]] || fail "file-based argv is $file_len bytes — expected well under 8192"
pass_assert

# -------- Case: finalizer accepts 5000 paths via --files-touched-json-file --------
out=$(bash core/scripts/handoff-finalize.sh \
  --title "Handoff: large" \
  --summary "Large changeset" \
  --message "Large changeset" \
  --next-steps-json '[]' \
  --files-touched-json-file "$CHANGESET_FILE" \
  --learnings-json '[]' \
  --tags-json '["test"]' \
  --slug "large") || fail "finalizer failed on 5000-path --files-touched-json-file"
pass_assert

thread_path=$(jq -r '.thread_path' <<<"$out")
changeset_path=$(jq -r '.changeset_path' <<<"$out")
[[ -f "$thread_path" ]] || fail "thread file missing"
pass_assert
[[ -f "$changeset_path" ]] || fail "changeset file missing"
pass_assert

# -------- Case: thread JSON contains all 5000 paths (guards --slurpfile [0]) --------
assert_eq "$(jq -r '.files_touched | length' "$thread_path")" "5000" "thread files_touched count"
assert_eq "$(jq -r '.files_touched[0]' "$thread_path")" "workspace/gen/file_0.ts" "thread files_touched first element (not the slurp wrapper array)"
assert_eq "$(jq -r '.files_touched[4999]' "$thread_path")" "workspace/gen/file_4999.ts" "thread files_touched last element"
# The changeset JSON must also carry the full list (second jq hop).
assert_eq "$(jq -r '.files_touched | length' "$changeset_path")" "5000" "changeset files_touched count"
# staged_paths is derived from the changeset and is equally large; it must survive
# its own jq hop (was --argjson, would overflow a single 128KB argv on any host).
assert_eq "$(jq -r '.staged_paths | length' "$changeset_path")" "5000" "changeset staged_paths count (derived-array hop)"

# -------- Case: status summary populated, not the {} fallback --------
status_summary=$(jq -c '.status_summary' "$changeset_path")
[[ "$status_summary" != "{}" ]] || fail "status_summary degraded to the {} fallback (hop 2 broke)"
pass_assert
jq -e '.status_summary.counts | type == "object"' "$changeset_path" >/dev/null \
  || fail "status_summary.counts missing — hq-status-summary did not run"
pass_assert
# 5000 session paths that do not exist on disk land as unrelated/baseline noise,
# not as tracked changes; the summary should still classify them.
jq -e '.status_summary.counts.tracked_changes | type == "number"' "$changeset_path" >/dev/null \
  || fail "status_summary counts not numeric"
pass_assert

# -------- Case: inline --files-touched-json still works for small lists --------
inline_out=$(bash core/scripts/handoff-finalize.sh \
  --title "Handoff: inline compat" \
  --summary "Inline compat" \
  --message "Inline compat" \
  --next-steps-json '[]' \
  --files-touched-json '["README.md"]' \
  --learnings-json '[]' \
  --tags-json '["test"]' \
  --slug "inline-compat") || fail "inline --files-touched-json compat path failed"
pass_assert
inline_thread=$(jq -r '.thread_path' <<<"$inline_out")
assert_eq "$(jq -c '.files_touched' "$inline_thread")" '["README.md"]' "inline compat thread files_touched"

# -------- Case: --files-touched-json-file with a missing file exits non-zero --------
set +e
missing_err=$(bash core/scripts/handoff-finalize.sh \
  --title "Handoff: missing" \
  --summary "Missing file" \
  --message "Missing file" \
  --next-steps-json '[]' \
  --files-touched-json-file "workspace/threads/does-not-exist.json" \
  --learnings-json '[]' \
  --tags-json '["test"]' \
  --slug "missing" 2>&1 >/dev/null)
missing_rc=$?
set -e
[[ "$missing_rc" -ne 0 ]] || fail "missing --files-touched-json-file should exit non-zero"
pass_assert
echo "$missing_err" | grep -q "not found" || fail "missing file error message absent (silent {} regression)"
pass_assert

# -------- Case: EXIT trap cleans registered temps (new_tmp must not use $()) --------
# After a successful finalize, only durable thread/changeset artifacts remain —
# no leaked .handoff-tmp temps from the registry.
leaked=$(find workspace/threads/.handoff-tmp -mindepth 1 -maxdepth 1 -type f -name '.handoff-*' 2>/dev/null | wc -l | tr -d ' ')
[[ "$leaked" -eq 0 ]] || fail "leaked $leaked .handoff-tmp temps — FINALIZE_TMP_FILES registry broken under subshell"
pass_assert

# -------- Case: temps stay gitignored so a clean tree stays git.dirty=false --------
# Commit any durable thread artifacts from prior cases so status is clean, then
# finalize with an empty changeset. Unignored temps used to flip dirty=true.
# Commit durable artifacts (incl. .claude/ from the mirror hook). Ignored
# .handoff-tmp/ stays out of the index so the tree is clean aside from temps.
git add -A 2>/dev/null || true
git commit -qm "checkpoint prior handoff artifacts" >/dev/null 2>&1 || true
[[ -z "$(git status --porcelain 2>/dev/null)" ]] || fail "precondition: tree not clean before dirty check"
clean_out=$(bash core/scripts/handoff-finalize.sh \
  --title "Handoff: clean dirty" \
  --summary "Clean dirty" \
  --message "Clean dirty" \
  --next-steps-json '[]' \
  --files-touched-json '[]' \
  --learnings-json '[]' \
  --tags-json '["test"]' \
  --slug "clean-dirty") || fail "finalizer failed on clean empty changeset"
pass_assert
clean_thread=$(jq -r '.thread_path' <<<"$clean_out")
assert_eq "$(jq -r '.git.dirty' "$clean_thread")" "false" "git.dirty must stay false when only ignored handoff temps exist"

# -------- Case: thousands of skipped paths stay off argv (NDJSON accumulate) --------
skip_changeset="workspace/threads/.skip-changeset.json"
jq -n -c '[range(0;2000) | "workspace/gen/missing_\(.).ts"]' > "$skip_changeset"
skip_out=$(bash core/scripts/handoff-finalize.sh \
  --title "Handoff: many skips" \
  --summary "Many skips" \
  --message "Many skips" \
  --next-steps-json '[]' \
  --files-touched-json-file "$skip_changeset" \
  --learnings-json '[]' \
  --tags-json '["test"]' \
  --slug "many-skips") || fail "finalizer failed on 2000 missing skipped paths"
pass_assert
skip_thread=$(jq -r '.thread_path' <<<"$skip_out")
skip_changeset_out=$(jq -r '.changeset_path' <<<"$skip_out")
assert_eq "$(jq -r '.skipped_paths | length' "$skip_changeset_out")" "2000" "skipped_paths count via NDJSON accumulate"
assert_eq "$(jq -r '.skipped_paths[0].reason' "$skip_changeset_out")" "missing" "first skip reason"
[[ -f "$skip_thread" ]] || fail "many-skips thread missing"
pass_assert

# -------- Case: many untracked paths keep status_summary off argv (no {} fallback) --------
# Place files directly under workspace/ (which already has tracked content) so
# `git status --porcelain` lists each path — a single untracked dir collapses to 1.
i=0
while [ "$i" -lt 3000 ]; do
  : > "workspace/u_$i.ts"
  i=$((i + 1))
done
noise_out=$(bash core/scripts/handoff-finalize.sh \
  --title "Handoff: status noise" \
  --summary "Status noise" \
  --message "Status noise" \
  --next-steps-json '[]' \
  --files-touched-json '["README.md"]' \
  --learnings-json '[]' \
  --tags-json '["test"]' \
  --slug "status-noise") || fail "finalizer failed with 3000 untracked baseline paths"
pass_assert
noise_changeset=$(jq -r '.changeset_path' <<<"$noise_out")
noise_summary=$(jq -c '.status_summary' "$noise_changeset")
[[ "$noise_summary" != "{}" ]] || fail "status_summary degraded to {} with large untracked tree (hq-status-summary argv overflow)"
pass_assert
jq -e '.status_summary.counts.baseline_untracked >= 3000' "$noise_changeset" >/dev/null \
  || fail "baseline_untracked did not classify the 3000 untracked paths"
pass_assert

echo "handoff-finalize large-changeset: PASS ($ASSERTIONS assertions)"
