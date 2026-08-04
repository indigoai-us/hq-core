#!/usr/bin/env bash
# Smoke tests for handoff-finalize.sh and hq-status-summary.sh.
#
# Requires a released @indigoai-us/hq-cli with the hidden core group (hq-cli#279).
# CI job autosave-failure-visibility installs latest CLI and asserts `hq core --help`.
# Stale CLIs without `core` make the status-summary forwarder fail-soft to {}, so
# baseline_noise_count becomes 0 — fail loud here instead of that cryptic assertion.

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

# Loud preflight: hq core group must exist. `hq core --help` alone is not enough
# on some older builds (they exit 0 with *top-level* help). Reject "unknown
# command 'core'" and require *core-specific* positive evidence only.
# Do NOT match generic top-level tokens (usage/session) — stale 5.77.14 prints
# those while masquerading `hq core --help` as root help, then fails later with
# cryptic baseline_noise_count=0.
_hq_preflight_fail() {
  fail "hq CLI too old/incomplete (no usable 'hq core' / hq-status-summary). Upgrade: npm install -g @indigoai-us/hq-cli (CI uses latest; 5.85.1+ known good). Stale CLIs make baseline_noise_count=0 via silent status-summary failure."
}
if ! command -v hq >/dev/null 2>&1; then
  fail "hq CLI missing; install: npm install -g @indigoai-us/hq-cli (need core group; CI uses latest; 5.85.1+ known good)"
fi
_hq_core_probe="$(hq core --help 2>&1 || true)"
if printf '%s\n' "$_hq_core_probe" | grep -qi "unknown command 'core'"; then
  _hq_preflight_fail
fi
# Positive: core help must list the forwarder target, or live invoke emits JSON .counts.
# Core-specific tokens only — rejects top-level help masquerading as core help.
if ! printf '%s\n' "$_hq_core_probe" | grep -Eqi 'hq-status-summary'; then
  if ! hq core hq-status-summary --porcelain-file /dev/null --json 2>/dev/null | grep -q '"counts"'; then
    _hq_preflight_fail
  fi
fi
unset _hq_core_probe

# Snapshot host qmd lock stamp before any fixture isolation (assert unchanged at end).
_HOST_HOME="${HOME}"
_HOST_STAMP="$_HOST_HOME/.hq/locks/qmd-reindex-bg.completed"
_HOST_STAMP_MTIME=""
_HOST_STAMP_EXISTED=0
if [[ -f "$_HOST_STAMP" ]]; then
  _HOST_STAMP_EXISTED=1
  _HOST_STAMP_MTIME=$(stat -c %Y "$_HOST_STAMP" 2>/dev/null || true)
fi

cp "$SRC_ROOT/scripts/handoff-finalize.sh" "$TMP_ROOT/handoff-finalize.sh"
cp "$SRC_ROOT/scripts/hq-status-summary.sh" "$TMP_ROOT/hq-status-summary.sh"
cp "$SRC_ROOT/scripts/qmd-reindex-bg.sh" "$TMP_ROOT/qmd-reindex-bg.sh"
cp "$SRC_ROOT/../.claude/hooks/mirror-thread-to-company.sh" "$TMP_ROOT/mirror-thread-to-company.sh"

mkdir -p "$TMP_ROOT/repo/core/scripts" "$TMP_ROOT/repo/.claude/hooks" "$TMP_ROOT/repo/workspace/baseline" "$TMP_ROOT/repo/workspace/threads" "$TMP_ROOT/repo/workspace/orchestrator"
cp "$TMP_ROOT/handoff-finalize.sh" "$TMP_ROOT/repo/core/scripts/handoff-finalize.sh"
cp "$TMP_ROOT/hq-status-summary.sh" "$TMP_ROOT/repo/core/scripts/hq-status-summary.sh"
cp "$TMP_ROOT/qmd-reindex-bg.sh" "$TMP_ROOT/repo/core/scripts/qmd-reindex-bg.sh"
cp "$TMP_ROOT/mirror-thread-to-company.sh" "$TMP_ROOT/repo/.claude/hooks/mirror-thread-to-company.sh"
chmod +x "$TMP_ROOT/repo/core/scripts/"*.sh
chmod -x "$TMP_ROOT/repo/.claude/hooks/mirror-thread-to-company.sh"

# Isolate host qmd / HOME / lock domain while keeping helper copy for routing fidelity.
# Without this, ambient `qmd` + real HOME mutates ~/.hq/locks/qmd-reindex-bg.*.
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/bin"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$TMP_ROOT/bin/qmd"
chmod +x "$TMP_ROOT/bin/qmd"
export HOME="$TMP_ROOT/home"
export PATH="$TMP_ROOT/bin:$PATH"

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

if [[ -f "$SRC_ROOT/workspace/baseline/hq-local-baseline.json" ]]; then
  cp "$SRC_ROOT/workspace/baseline/hq-local-baseline.json" "$TMP_ROOT/repo/workspace/baseline/hq-local-baseline.json"
else
  cat > "$TMP_ROOT/repo/workspace/baseline/hq-local-baseline.json" <<'JSON'
{"categories":[{"name":"baseline","patterns":["companies/*","workspace/*","repos/*","core/settings/*",".hq/*"]}]}
JSON
fi

cd "$TMP_ROOT/repo"
git init -q
git config user.email test@example.com
git config user.name "Handoff Test"

echo "base" > tracked.txt
git add tracked.txt core/scripts workspace/baseline/hq-local-baseline.json
git commit -qm "base"

echo "changed" > tracked.txt
mkdir -p notes companies/acme settings core/settings
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

# --session-files-file path is used when provided (mirrors --session-files-json).
echo '[{"path":"notes/new.md"}]' > "$TMP_ROOT/session-files.json"
summary_file=$(bash core/scripts/hq-status-summary.sh \
  --porcelain-file "$TMP_ROOT/porcelain.txt" \
  --session-files-file "$TMP_ROOT/session-files.json" \
  --json)
assert_eq "$(jq -r '.counts.session_touched_untracked' <<<"$summary_file")" "1" "session untracked count (file input)"
assert_eq "$(jq -r '.counts.unrelated_untracked' <<<"$summary_file")" "1" "unrelated untracked count (file input)"

# A missing --session-files-file is a hard error, never a silent empty summary.
if bash core/scripts/hq-status-summary.sh \
    --porcelain-file "$TMP_ROOT/porcelain.txt" \
    --session-files-file "$TMP_ROOT/does-not-exist.json" \
    --json >/dev/null 2>&1; then
  fail "missing --session-files-file should exit non-zero"
fi

# Regression: empty --files-touched-json '[]' must not crash under `set -u`.
# Previously the bare "${SAFE_STAGE_PATHS[@]}" expansion in EXPLICIT_PATHS
# tripped nounset when no foreground file edits occurred (empty array case).
empty_out=$(bash core/scripts/handoff-finalize.sh \
  --title "Handoff: empty smoke" \
  --summary "Empty changeset smoke test" \
  --message "Empty changeset smoke test" \
  --next-steps-json '[]' \
  --files-touched-json '[]' \
  --learnings-json '[]' \
  --tags-json '["test"]' \
  --slug "empty-smoke") || fail "handoff-finalize crashed on empty --files-touched-json (SAFE_STAGE_PATHS unbound regression)"

empty_changeset=$(jq -r '.changeset_path' <<<"$empty_out")
[[ -f "$empty_changeset" ]] || fail "empty changeset file missing"
assert_eq "$(jq -r '.staged_paths | length' "$empty_changeset")" "0" "empty changeset has zero staged_paths"

# Regression: a company-scoped handoff mirrors even when the helper lacks an
# executable bit. The finalizer runs it through Bash because a shell hook is
# not an executable contract.
mkdir -p companies/winks/projects/offer
echo "offer" > companies/winks/projects/offer/README.md
[[ ! -x .claude/hooks/mirror-thread-to-company.sh ]] || fail "mirror hook unexpectedly executable"
mirror_out=$(bash core/scripts/handoff-finalize.sh \
  --title "Handoff: Winks offer" \
  --summary "Mirror handoff across devices" \
  --message "Mirror handoff" \
  --next-steps-json '[]' \
  --files-touched-json '["companies/winks/projects/offer/README.md"]' \
  --learnings-json '[]' \
  --tags-json '["test"]' \
  --slug "winks-offer")
mirror_thread_path=$(jq -r '.thread_path' <<<"$mirror_out")
mirror_thread_id=$(jq -r '.thread_id' <<<"$mirror_out")
assert_eq "$(jq -c '.mirror_companies' <<<"$mirror_out")" '["winks"]' "mirrored company output"
jq -e '.metadata.company == ["winks"]' "$mirror_thread_path" >/dev/null \
  || fail "handoff metadata omitted touched company"
[[ -f "companies/winks/workspace/sessions/${mirror_thread_id}.json" ]] \
  || fail "non-executable mirror hook was not replayed"
git show "HEAD:companies/winks/workspace/index.jsonl" | grep -q "${mirror_thread_id}" \
  || fail "mirror index was not committed with handoff"

# Host lock domain must be untouched (helper fidelity without host mutation).
if [[ "$_HOST_STAMP_EXISTED" -eq 1 ]]; then
  _after_mtime=$(stat -c %Y "$_HOST_STAMP" 2>/dev/null || true)
  [[ "$_after_mtime" == "$_HOST_STAMP_MTIME" ]] \
    || fail "smoke mutated host qmd completion stamp mtime (before=$_HOST_STAMP_MTIME after=$_after_mtime)"
else
  if [[ -f "$_HOST_STAMP" ]]; then
    fail "smoke created host qmd completion stamp at $_HOST_STAMP"
  fi
fi

echo "handoff-finalize smoke: ok"
