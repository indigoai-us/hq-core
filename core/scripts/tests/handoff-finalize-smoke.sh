#!/usr/bin/env bash
# Smoke tests for handoff-finalize.sh and hq-status-summary.sh.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

cp "$SRC_ROOT/scripts/handoff-finalize.sh" "$TMP_ROOT/handoff-finalize.sh"
cp "$SRC_ROOT/scripts/hq-status-summary.sh" "$TMP_ROOT/hq-status-summary.sh"

mkdir -p "$TMP_ROOT/repo/scripts" "$TMP_ROOT/repo/workspace/baseline" "$TMP_ROOT/repo/workspace/threads" "$TMP_ROOT/repo/workspace/orchestrator"
cp "$TMP_ROOT/handoff-finalize.sh" "$TMP_ROOT/repo/scripts/handoff-finalize.sh"
cp "$TMP_ROOT/hq-status-summary.sh" "$TMP_ROOT/repo/scripts/hq-status-summary.sh"
chmod +x "$TMP_ROOT/repo/scripts/"*.sh

cat > "$TMP_ROOT/repo/scripts/rebuild-threads-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/threads
echo "# Threads" > workspace/threads/INDEX.md
echo "- recent" > workspace/threads/recent.md
SH
cat > "$TMP_ROOT/repo/scripts/rebuild-orchestrator-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/orchestrator
echo "# Orchestrator" > workspace/orchestrator/INDEX.md
SH
chmod +x "$TMP_ROOT/repo/scripts/rebuild-threads-index.sh" "$TMP_ROOT/repo/scripts/rebuild-orchestrator-index.sh"

cp "$SRC_ROOT/workspace/baseline/hq-local-baseline.json" "$TMP_ROOT/repo/workspace/baseline/hq-local-baseline.json"

cd "$TMP_ROOT/repo"
git init -q
git config user.email test@example.com
git config user.name "Handoff Test"

echo "base" > tracked.txt
git add tracked.txt scripts workspace/baseline/hq-local-baseline.json
git commit -qm "base"

echo "changed" > tracked.txt
mkdir -p notes companies/acme settings
echo "new" > notes/new.md
echo "baseline" > companies/acme/local.md
echo "secret" > core/settings/secret.json

out=$(bash core/scripts/handoff-finalize.sh \
  --title "Handoff: smoke" \
  --summary "Smoke test" \
  --message "Smoke test" \
  --next-steps-json '[]' \
  --files-touched-json '["tracked.txt", {"path":"notes/new.md","reason":"new note"}, {"path":"missing.txt"}, {"path":"../escape.txt"}, {"path":"core/settings/secret.json"}]' \
  --learnings-json '[]' \
  --tags-json '["test"]' \
  --slug "smoke")

thread_path=$(jq -r '.thread_path' <<<"$out")
changeset_path=$(jq -r '.changeset_path' <<<"$out")
baseline_noise=$(jq -r '.baseline_noise_count' <<<"$out")

[[ -f "$thread_path" ]] || fail "thread file missing"
[[ -f "$changeset_path" ]] || fail "changeset file missing"
assert_eq "$(jq -r '.changeset_path' "$thread_path")" "$changeset_path" "thread changeset pointer"
[[ "$baseline_noise" -ge 1 ]] || fail "expected baseline noise count"

git show HEAD:tracked.txt | grep -q changed || fail "tracked touched file not committed"
git show HEAD:notes/new.md | grep -q new || fail "untracked session file not committed"
if git cat-file -e HEAD:companies/acme/local.md 2>/dev/null; then
  fail "baseline unrelated file was committed"
fi
if git cat-file -e HEAD:core/settings/secret.json 2>/dev/null; then
  fail "sensitive settings file was committed"
fi

jq -e '.skipped_paths[] | select(.path == "missing.txt" and .reason == "missing")' "$changeset_path" >/dev/null \
  || fail "missing path skip not recorded"
jq -e '.skipped_paths[] | select(.path == "../escape.txt" and .reason == "unsafe-path")' "$changeset_path" >/dev/null \
  || fail "unsafe path skip not recorded"
jq -e '.skipped_paths[] | select(.path == "core/settings/secret.json" and .reason == "sensitive-path")' "$changeset_path" >/dev/null \
  || fail "sensitive path skip not recorded"

rm tracked.txt
delete_out=$(bash core/scripts/handoff-finalize.sh \
  --title "Handoff: delete smoke" \
  --summary "Delete smoke test" \
  --message "Delete smoke test" \
  --next-steps-json '[]' \
  --files-touched-json '[{"path":"tracked.txt","deleted":true,"reason":"delete tracked file"}]' \
  --learnings-json '[]' \
  --tags-json '["test"]' \
  --slug "delete-smoke")

delete_changeset=$(jq -r '.changeset_path' <<<"$delete_out")
[[ -f "$delete_changeset" ]] || fail "delete changeset file missing"
if git cat-file -e HEAD:tracked.txt 2>/dev/null; then
  fail "deleted tracked file was not removed from commit"
fi
jq -e '.staged_paths[] | select(. == "tracked.txt")' "$delete_changeset" >/dev/null \
  || fail "deleted path not recorded in staged paths"

cat > "$TMP_ROOT/porcelain.txt" <<'EOF'
 M tracked.txt
?? notes/new.md
?? companies/acme/local.md
?? random.tmp
!! .cache/foo
EOF

summary=$(bash core/scripts/hq-status-summary.sh \
  --porcelain-file "$TMP_ROOT/porcelain.txt" \
  --session-files-json '[{"path":"notes/new.md"}]' \
  --json)

assert_eq "$(jq -r '.counts.tracked_changes' <<<"$summary")" "1" "tracked count"
assert_eq "$(jq -r '.counts.session_touched_untracked' <<<"$summary")" "1" "session untracked count"
assert_eq "$(jq -r '.counts.baseline_untracked' <<<"$summary")" "1" "baseline untracked count"
assert_eq "$(jq -r '.counts.unrelated_untracked' <<<"$summary")" "1" "unrelated untracked count"
assert_eq "$(jq -r '.counts.ignored' <<<"$summary")" "1" "ignored count"

echo "handoff-finalize smoke: ok"
