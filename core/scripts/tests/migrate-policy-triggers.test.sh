#!/usr/bin/env bash
# Regression: trigger migration must not promote trigger-less non-hard policies
# into the always-on SessionStart baseline. Hard-policy fallback and ordinary
# reactive trigger derivation/injection remain unchanged.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
MIGRATOR="$ROOT/core/scripts/migrate-policy-triggers.sh"
HOOK="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_line() { grep -qxF "$2" "$1" || fail "$3: missing '$2' in $1"; }
assert_no_field() { ! grep -q "^$2:" "$1" || fail "$3: unexpected $2 in $1"; }

mkdir -p "$TMP/core/policies" "$TMP/workspace/orchestrator/policy-trigger-state"

cat > "$TMP/core/policies/hard-triggerless.md" <<'EOF'
---
id: hard-triggerless
enforcement: hard
---

## Rule
Hard policies remain part of the startup baseline when no signal exists.
EOF

cat > "$TMP/core/policies/soft-triggerless.md" <<'EOF'
---
id: soft-triggerless
enforcement: soft
---

## Rule
Soft trigger-less policies must not become startup baseline noise.
EOF

cat > "$TMP/core/policies/unset-triggerless.md" <<'EOF'
---
id: unset-triggerless
---

## Rule
Unset trigger-less policies must not become startup baseline noise.
EOF

cat > "$TMP/core/policies/normal-triggered.md" <<'EOF'
---
id: normal-triggered
enforcement: soft
trigger: when deploying
---

## Rule
Normal triggered policies still inject when their signal appears.
EOF

HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$TMP/legacy-state" \
  bash "$MIGRATOR" "$TMP/core/policies" 2>"$TMP/migrate.err"

assert_line "$TMP/core/policies/hard-triggerless.md" "when: always" \
  "hard trigger-less fallback"
assert_line "$TMP/core/policies/hard-triggerless.md" "on: [SessionStart]" \
  "hard trigger-less event"
assert_no_field "$TMP/core/policies/soft-triggerless.md" when \
  "soft trigger-less policy"
assert_no_field "$TMP/core/policies/soft-triggerless.md" on \
  "soft trigger-less policy"
assert_no_field "$TMP/core/policies/unset-triggerless.md" when \
  "unset trigger-less policy"
assert_no_field "$TMP/core/policies/unset-triggerless.md" on \
  "unset trigger-less policy"
assert_line "$TMP/core/policies/normal-triggered.md" "when: deploy" \
  "normal reactive trigger"
assert_line "$TMP/core/policies/normal-triggered.md" \
  "on: [PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]" \
  "normal reactive events"

run_hook() {
  printf '%s' "$1" | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>/dev/null || true
}

start_out="$(run_hook '{"hook_event_name":"SessionStart","session_id":"rebloat-start","cwd":"'"$TMP"'"}')"
grep -q 'hard-triggerless' <<<"$start_out" || fail "hard fallback did not inject at SessionStart: [$start_out]"
grep -q 'soft-triggerless' <<<"$start_out" && fail "soft trigger-less policy injected at SessionStart: [$start_out]"
grep -q 'unset-triggerless' <<<"$start_out" && fail "unset trigger-less policy injected at SessionStart: [$start_out]"
grep -q 'normal-triggered' <<<"$start_out" && fail "reactive policy injected at SessionStart: [$start_out]"

# Pre-warm the normal policy's session so the hard baseline is already deduped,
# then prove the ordinary deploy trigger still surfaces through the live path.
run_hook '{"hook_event_name":"SessionStart","session_id":"normal-session","cwd":"'"$TMP"'"}' >/dev/null
normal_out="$(run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"normal-session","cwd":"'"$TMP"'","prompt":"deploy the release"}')"
grep -q 'normal-triggered' <<<"$normal_out" || fail "normal triggered policy did not inject: [$normal_out]"
grep -q 'soft-triggerless' <<<"$normal_out" && fail "soft trigger-less policy injected on later event: [$normal_out]"
grep -q 'unset-triggerless' <<<"$normal_out" && fail "unset trigger-less policy injected on later event: [$normal_out]"

# Idempotence: a second migration must leave all files byte-for-byte unchanged.
before="$(sha256sum "$TMP/core/policies/"*.md)"
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$TMP/legacy-state" \
  HQ_MIGRATE_POLICY_TRIGGERS_FORCE=1 \
  bash "$MIGRATOR" "$TMP/core/policies" 2>"$TMP/migrate-second.err"
after="$(sha256sum "$TMP/core/policies/"*.md)"
[ "$before" = "$after" ] || fail "second migration changed policy files"

write_migratable_policy() {
  local file="$1" id
  id="$(basename "$file" .md)"
  cat > "$file" <<EOF
---
id: $id
enforcement: soft
trigger: when deploying
---

## Rule
This policy must be backfilled when the cooldown permits a migration.
EOF
}

assert_migrated() {
  assert_line "$1" "when: deploy" "$2"
}

assert_unmigrated() {
  assert_no_field "$1" when "$2"
}

run_migrator() {
  local state_dir="$1" policy_dir="$2"
  HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
    HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$state_dir" \
    bash "$MIGRATOR" "$policy_dir"
}

stamp_file() {
  find "$1" -type f -name last-success -print -quit
}

# 1. First run: an absent stamp must permit a full migration and record only a
# completed pass. Every cooldown case gets its own state directory so no case
# can inherit a clock from another assertion.
FIRST_DIR="$TMP/cooldown-first/policies"
FIRST_STATE="$TMP/cooldown-first/state"
mkdir -p "$FIRST_DIR"
write_migratable_policy "$FIRST_DIR/first.md"
run_migrator "$FIRST_STATE" "$FIRST_DIR"
assert_migrated "$FIRST_DIR/first.md" "first run with no stamp"
FIRST_STAMP="$(stamp_file "$FIRST_STATE")"
[ -n "$FIRST_STAMP" ] && [ -s "$FIRST_STAMP" ] || fail "first run did not write a success stamp"

# 2. A fresh stamp suppresses the next run. The pending policy is created only
# after the seed pass, so it can change only if the second invocation ran.
SUPPRESS_DIR="$TMP/cooldown-suppress/policies"
SUPPRESS_STATE="$TMP/cooldown-suppress/state"
mkdir -p "$SUPPRESS_DIR"
write_migratable_policy "$SUPPRESS_DIR/seed.md"
run_migrator "$SUPPRESS_STATE" "$SUPPRESS_DIR"
write_migratable_policy "$SUPPRESS_DIR/pending.md"
run_migrator "$SUPPRESS_STATE" "$SUPPRESS_DIR"
assert_unmigrated "$SUPPRESS_DIR/pending.md" "fresh stamp did not suppress the second run"

# 3. FORCE bypasses a fresh stamp.
FORCE_DIR="$TMP/cooldown-force/policies"
FORCE_STATE="$TMP/cooldown-force/state"
mkdir -p "$FORCE_DIR"
write_migratable_policy "$FORCE_DIR/seed.md"
run_migrator "$FORCE_STATE" "$FORCE_DIR"
write_migratable_policy "$FORCE_DIR/pending.md"
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$FORCE_STATE" \
  HQ_MIGRATE_POLICY_TRIGGERS_FORCE=1 \
  bash "$MIGRATOR" "$FORCE_DIR"
assert_migrated "$FORCE_DIR/pending.md" "force override did not bypass a fresh stamp"

# 4. A zero cooldown bypasses a fresh stamp without requiring FORCE.
ZERO_DIR="$TMP/cooldown-zero/policies"
ZERO_STATE="$TMP/cooldown-zero/state"
mkdir -p "$ZERO_DIR"
write_migratable_policy "$ZERO_DIR/seed.md"
run_migrator "$ZERO_STATE" "$ZERO_DIR"
write_migratable_policy "$ZERO_DIR/pending.md"
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$ZERO_STATE" \
  HQ_MIGRATE_POLICY_TRIGGERS_COOLDOWN_SECONDS=0 \
  bash "$MIGRATOR" "$ZERO_DIR"
assert_migrated "$ZERO_DIR/pending.md" "zero cooldown did not disable suppression"

# 5. A non-numeric stamp is corrupt, not fresh: run rather than silently
# suppressing work on the host.
CORRUPT_DIR="$TMP/cooldown-corrupt/policies"
CORRUPT_STATE="$TMP/cooldown-corrupt/state"
mkdir -p "$CORRUPT_DIR" "$CORRUPT_STATE"
write_migratable_policy "$CORRUPT_DIR/seed.md"
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$CORRUPT_STATE" \
  HQ_MIGRATE_POLICY_TRIGGERS_COOLDOWN_SECONDS=0 \
  bash "$MIGRATOR" "$CORRUPT_DIR"
CORRUPT_STAMP="$(stamp_file "$CORRUPT_STATE")"
[ -n "$CORRUPT_STAMP" ] || fail "corrupt-stamp setup did not create a stamp"
write_migratable_policy "$CORRUPT_DIR/pending.md"
printf 'not-a-number\n' > "$CORRUPT_STAMP"
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$CORRUPT_STATE" \
  bash "$MIGRATOR" "$CORRUPT_DIR" >"$TMP/corrupt.out" 2>"$TMP/corrupt.err"
assert_migrated "$CORRUPT_DIR/pending.md" "corrupt stamp suppressed the migration"
assert_line "$TMP/corrupt.err" "migrate-policy-triggers: cooldown stamp is unreadable; running" \
  "corrupt stamp diagnostic"

# 6. A future stamp is equally untrustworthy: a clock rollback must not hold
# the hook quiet for an arbitrarily long period.
FUTURE_DIR="$TMP/cooldown-future/policies"
FUTURE_STATE="$TMP/cooldown-future/state"
mkdir -p "$FUTURE_DIR" "$FUTURE_STATE"
write_migratable_policy "$FUTURE_DIR/seed.md"
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$FUTURE_STATE" \
  HQ_MIGRATE_POLICY_TRIGGERS_COOLDOWN_SECONDS=0 \
  bash "$MIGRATOR" "$FUTURE_DIR"
FUTURE_STAMP="$(stamp_file "$FUTURE_STATE")"
[ -n "$FUTURE_STAMP" ] || fail "future-stamp setup did not create a stamp"
write_migratable_policy "$FUTURE_DIR/pending.md"
printf '%s\n' "$(( $(date -u '+%s') + 3600 ))" > "$FUTURE_STAMP"
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$FUTURE_STATE" \
  bash "$MIGRATOR" "$FUTURE_DIR" >"$TMP/future.out" 2>"$TMP/future.err"
assert_migrated "$FUTURE_DIR/pending.md" "future stamp suppressed the migration"
assert_line "$TMP/future.err" "migrate-policy-triggers: cooldown stamp is in the future; running" \
  "future stamp diagnostic"

# 7. A killed pass must not create a successful-completion stamp. Delay the
# first grep long enough to terminate the shell before it reaches its success
# path, then prove the next invocation really migrates the pending policy.
INCOMPLETE_DIR="$TMP/cooldown-incomplete/policies"
INCOMPLETE_STATE="$TMP/cooldown-incomplete/state"
INCOMPLETE_BIN="$TMP/cooldown-incomplete/bin"
SYSTEM_GREP="$(command -v grep)"
mkdir -p "$INCOMPLETE_DIR" "$INCOMPLETE_STATE" "$INCOMPLETE_BIN"
write_migratable_policy "$INCOMPLETE_DIR/pending.md"
cat > "$INCOMPLETE_BIN/grep" <<EOF
#!/usr/bin/env bash
sleep 1
exec "$SYSTEM_GREP" "\$@"
EOF
chmod +x "$INCOMPLETE_BIN/grep"
PATH="$INCOMPLETE_BIN:$PATH" HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$INCOMPLETE_STATE" \
  bash "$MIGRATOR" "$INCOMPLETE_DIR" >"$TMP/incomplete.out" 2>"$TMP/incomplete.err" &
incomplete_pid=$!
sleep 0.2
kill -TERM "$incomplete_pid" 2>/dev/null || fail "incomplete migration exited before it could be terminated"
if wait "$incomplete_pid"; then
  fail "incomplete migration unexpectedly exited successfully"
fi
[ -z "$(stamp_file "$INCOMPLETE_STATE")" ] || fail "incomplete migration wrote a success stamp"
# The killed shell's current grep inherits its advisory-lock descriptor; let
# that child exit before exercising the next independent SessionStart.
sleep 2
run_migrator "$INCOMPLETE_STATE" "$INCOMPLETE_DIR"
assert_migrated "$INCOMPLETE_DIR/pending.md" "next run after an incomplete pass was suppressed"

# Scope is part of the cache key: a company-A completion cannot suppress the
# first default-scope migration for company B.
SCOPE_STATE="$TMP/cooldown-scope/state"
SCOPE_A_DIR="$TMP/companies/a/policies"
SCOPE_B_DIR="$TMP/companies/b/policies"
mkdir -p "$SCOPE_A_DIR" "$SCOPE_B_DIR"
write_migratable_policy "$SCOPE_A_DIR/a.md"
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP/companies/a" \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$SCOPE_STATE" \
  bash "$MIGRATOR"
assert_migrated "$SCOPE_A_DIR/a.md" "company A default scope"
write_migratable_policy "$SCOPE_B_DIR/b.md"
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP/companies/b" \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$SCOPE_STATE" \
  bash "$MIGRATOR"
assert_migrated "$SCOPE_B_DIR/b.md" "company A stamp suppressed company B"
[ "$(find "$SCOPE_STATE" -type f -name last-success | wc -l)" -eq 2 ] || \
  fail "default scopes did not receive independent stamps"

# Default scans include every personal worker profile and only the active
# company's worker profiles. A run in company A must never modify company B.
PERSONAL_WORKER_POLICY="$TMP/personal/workers/default-worker/policies/personal-worker.md"
COMPANY_A_WORKER_POLICY="$TMP/companies/a/workers/default-worker/policies/company-a-worker.md"
COMPANY_B_WORKER_POLICY="$TMP/companies/b/workers/default-worker/policies/company-b-worker.md"
mkdir -p "$(dirname "$PERSONAL_WORKER_POLICY")" \
  "$(dirname "$COMPANY_A_WORKER_POLICY")" \
  "$(dirname "$COMPANY_B_WORKER_POLICY")"
write_migratable_policy "$PERSONAL_WORKER_POLICY"
write_migratable_policy "$COMPANY_A_WORKER_POLICY"
write_migratable_policy "$COMPANY_B_WORKER_POLICY"
DEFAULT_WORKER_STATE="$TMP/default-worker-scope/state"
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP/companies/a" \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$DEFAULT_WORKER_STATE" \
  HQ_MIGRATE_POLICY_TRIGGERS_COOLDOWN_SECONDS=0 bash "$MIGRATOR"
assert_migrated "$PERSONAL_WORKER_POLICY" "default personal worker scan"
assert_migrated "$COMPANY_A_WORKER_POLICY" "active company worker scan"
assert_unmigrated "$COMPANY_B_WORKER_POLICY" "inactive company worker tenant isolation"
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP/companies/b" \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$DEFAULT_WORKER_STATE" \
  HQ_MIGRATE_POLICY_TRIGGERS_COOLDOWN_SECONDS=0 bash "$MIGRATOR"
assert_migrated "$COMPANY_B_WORKER_POLICY" "company B worker scan in its own scope"

# A trusted active-company override takes precedence when the session project
# directory is outside that tenant's company tree.
OVERRIDE_A_POLICY="$TMP/companies/override-a/workers/default-worker/policies/company-override-worker.md"
OVERRIDE_B_POLICY="$TMP/companies/override-b/workers/default-worker/policies/company-override-control.md"
mkdir -p "$(dirname "$OVERRIDE_A_POLICY")" "$(dirname "$OVERRIDE_B_POLICY")"
write_migratable_policy "$OVERRIDE_A_POLICY"
write_migratable_policy "$OVERRIDE_B_POLICY"
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP/companies/override-b" HQ_POLICY_COMPANY=override-a \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$DEFAULT_WORKER_STATE" \
  HQ_MIGRATE_POLICY_TRIGGERS_COOLDOWN_SECONDS=0 bash "$MIGRATOR"
assert_migrated "$OVERRIDE_A_POLICY" "HQ_POLICY_COMPANY worker scope override"
assert_unmigrated "$OVERRIDE_B_POLICY" "HQ_POLICY_COMPANY excludes cwd tenant workers"

# A second SessionStart that begins before the first completion must not scan
# concurrently. The first process holds its lock in grep; the policy added
# after it begins is outside its already-expanded file list, so it changes only
# if the second process gets past the lock/recheck path.
LOCK_DIR="$TMP/cooldown-lock/policies"
LOCK_STATE="$TMP/cooldown-lock/state"
LOCK_BIN="$TMP/cooldown-lock/bin"
LOCK_MARKER="$TMP/cooldown-lock/grep-started"
mkdir -p "$LOCK_DIR" "$LOCK_STATE" "$LOCK_BIN"
write_migratable_policy "$LOCK_DIR/seed.md"
cat > "$LOCK_BIN/grep" <<EOF
#!/usr/bin/env bash
touch "$LOCK_MARKER"
sleep 2
exec "$SYSTEM_GREP" "\$@"
EOF
chmod +x "$LOCK_BIN/grep"
PATH="$LOCK_BIN:$PATH" HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$LOCK_STATE" \
  bash "$MIGRATOR" "$LOCK_DIR" >"$TMP/lock-first.out" 2>"$TMP/lock-first.err" &
lock_first_pid=$!
for _ in $(seq 1 50); do
  [ -e "$LOCK_MARKER" ] && break
  sleep 0.1
done
[ -e "$LOCK_MARKER" ] || fail "first concurrent migration never reached its lock-held scan"
write_migratable_policy "$LOCK_DIR/pending.md"
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$LOCK_STATE" \
  bash "$MIGRATOR" "$LOCK_DIR" >"$TMP/lock-second.out" 2>"$TMP/lock-second.err" &
lock_second_pid=$!
wait "$lock_first_pid" || fail "first concurrent migration failed"
wait "$lock_second_pid" || fail "second concurrent migration failed"
assert_unmigrated "$LOCK_DIR/pending.md" "concurrent SessionStart scanned despite the cooldown lock"

# A clean service environment may have neither HOME nor XDG_STATE_HOME. In
# that case the migration remains available, with no cooldown state to trust.
NO_HOME_DIR="$TMP/cooldown-no-home/policies"
mkdir -p "$NO_HOME_DIR"
write_migratable_policy "$NO_HOME_DIR/pending.md"
env -u HOME -u XDG_STATE_HOME HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  bash "$MIGRATOR" "$NO_HOME_DIR"
assert_migrated "$NO_HOME_DIR/pending.md" "migration failed when HOME and XDG_STATE_HOME were unset"

# Call-site contract: the registered migration hook shells out to the
# evaluator. A 127 forwarder is treated as an unparseable trigger and leaves
# the source file untouched; an absent evaluator deliberately skips grammar
# validation and writes the derived trigger. Both paths keep exit 0 and exact
# output streams pinned.
CONTRACT_ROOT="$TMP/evaluator-callsite"
CONTRACT_FORWARDER="$CONTRACT_ROOT/forwarder"
CONTRACT_ABSENT="$CONTRACT_ROOT/absent"
mkdir -p "$CONTRACT_FORWARDER/core/scripts" "$CONTRACT_FORWARDER/core/policies" \
  "$CONTRACT_ABSENT/core/scripts" "$CONTRACT_ABSENT/core/policies"
cp "$MIGRATOR" "$CONTRACT_FORWARDER/core/scripts/migrate-policy-triggers.sh"
cp "$MIGRATOR" "$CONTRACT_ABSENT/core/scripts/migrate-policy-triggers.sh"
write_migratable_policy "$CONTRACT_FORWARDER/core/policies/forwarder.md"
write_migratable_policy "$CONTRACT_ABSENT/core/policies/absent.md"
CONTRACT_LOG="$CONTRACT_ROOT/eval.calls"
cat > "$CONTRACT_FORWARDER/core/scripts/eval-trigger.sh" <<EOF
#!/usr/bin/env bash
printf 'called\n' >> '$CONTRACT_LOG'
printf '%s\n' 'eval-trigger.sh: this script needs hq-cli >= 5.78.0 (found 5.77.0); upgrade with: npm install -g @indigoai-us/hq-cli@latest' >&2
exit 127
EOF
chmod +x "$CONTRACT_FORWARDER/core/scripts/eval-trigger.sh"
if HQ_ROOT="$CONTRACT_FORWARDER" CLAUDE_PROJECT_DIR="$CONTRACT_FORWARDER" \
  HQ_MIGRATE_POLICY_TRIGGERS_COOLDOWN_SECONDS=0 \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$CONTRACT_FORWARDER/state" \
  bash "$CONTRACT_FORWARDER/core/scripts/migrate-policy-triggers.sh" \
    "$CONTRACT_FORWARDER/core/policies" >"$CONTRACT_ROOT/forwarder.out" 2>"$CONTRACT_ROOT/forwarder.err"; then
  got=0
else
  got=$?
fi
[ "$got" = 0 ] && [ ! -s "$CONTRACT_ROOT/forwarder.out" ] || fail "migration 127 forwarder changed status/stdout"
grep -qx 'called' "$CONTRACT_LOG" || fail "migration did not execute evaluator forwarder"
cmp -s "$CONTRACT_FORWARDER/core/policies/forwarder.md" <(printf '%s\n' \
  '---' 'id: forwarder' 'enforcement: soft' 'trigger: when deploying' '---' '' \
  '## Rule' 'This policy must be backfilled when the cooldown permits a migration.') \
  || fail "migration wrote an unparseable trigger despite evaluator 127"
cat > "$CONTRACT_ROOT/forwarder.expected" <<'EOF'
eval-trigger.sh: this script needs hq-cli >= 5.78.0 (found 5.77.0); upgrade with: npm install -g @indigoai-us/hq-cli@latest
migrate-policy-triggers: refusing to write unparseable when: forwarder.md -> `deploy`
EOF
cmp -s "$CONTRACT_ROOT/forwarder.expected" "$CONTRACT_ROOT/forwarder.err" \
  || fail "migration 127 stderr differs: $(cat "$CONTRACT_ROOT/forwarder.err")"

if HQ_ROOT="$CONTRACT_ABSENT" CLAUDE_PROJECT_DIR="$CONTRACT_ABSENT" \
  HQ_MIGRATE_POLICY_TRIGGERS_COOLDOWN_SECONDS=0 \
  HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR="$CONTRACT_ABSENT/state" \
  bash "$CONTRACT_ABSENT/core/scripts/migrate-policy-triggers.sh" \
    "$CONTRACT_ABSENT/core/policies" >"$CONTRACT_ROOT/absent.out" 2>"$CONTRACT_ROOT/absent.err"; then
  got=0
else
  got=$?
fi
[ "$got" = 0 ] && [ ! -s "$CONTRACT_ROOT/absent.out" ] || fail "migration absent evaluator changed status/stdout"
grep -qx 'when: deploy' "$CONTRACT_ABSENT/core/policies/absent.md" \
  || fail "missing evaluator no longer skips validation and writes trigger"
grep -qx 'migrate-policy-triggers: backfilled 1 policy trigger(s) (0 hard -> SessionStart, 0 non-hard triggerless left unchanged, 0 unparseable derivations skipped, 0 already had when)' "$CONTRACT_ROOT/absent.err" \
  || fail "migration absent evaluator stderr differs: $(cat "$CONTRACT_ROOT/absent.err")"
echo "PASS: migration evaluator 127/absence call-site contract"

echo "PASS: migrate-policy-triggers enforcement-gated fallback and 10 cooldown cases"
