#!/usr/bin/env bash
# hq-core: public
# Proves /handoff Step 1 and the SessionStart journal index stay inside the
# session's bound company: a handoff bound to one company commits only that
# company's knowledge repository, an unbound handoff skips company knowledge and
# says so, and the journal index loader surfaces only the bound company's
# entries (none when unbound) under Claude, Codex, and Grok dispatch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HELPER="$ROOT/core/scripts/handoff-knowledge-commit.sh"
JOURNAL="$ROOT/core/scripts/session-journal.sh"
HOOK="$ROOT/.claude/hooks/load-journal-index-on-start.sh"
SKILL="$ROOT/.claude/skills/handoff/SKILL.md"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/handoff-journal-company-scope.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

unset HQ_ACTIVE_COMPANY CLAUDE_PROJECT_DIR

# ---- /handoff Step 1: knowledge commits ------------------------------------
fixture="$TMP/hq"
for co in alpha beta; do
  repo="$fixture/companies/$co/knowledge"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Scope Test'
  git -C "$repo" config user.email 'scope-test@example.invalid'
  printf 'base\n' > "$repo/base.md"
  git -C "$repo" add -- base.md
  git -C "$repo" commit -q -m base
  printf 'session edit\n' > "$repo/notes.md"
done
alpha_head="$(git -C "$fixture/companies/alpha/knowledge" rev-parse HEAD)"
beta_head="$(git -C "$fixture/companies/beta/knowledge" rev-parse HEAD)"
printf '["companies/alpha/knowledge/notes.md","companies/beta/knowledge/notes.md"]\n' > "$TMP/changeset.json"

unbound_out="$(bash "$HELPER" --root "$fixture" --files-touched-json-file "$TMP/changeset.json")"
[[ "$unbound_out" == *'SKIPPED-COMPANY-KNOWLEDGE: no bound company'* ]] || fail "unbound handoff reports the company skip (got: $unbound_out)"
[ "$(git -C "$fixture/companies/alpha/knowledge" rev-parse HEAD)" = "$alpha_head" ] || fail 'unbound handoff left alpha uncommitted'
[ "$(git -C "$fixture/companies/beta/knowledge" rev-parse HEAD)" = "$beta_head" ] || fail 'unbound handoff left beta uncommitted'
ok 'unbound handoff skips every company knowledge repository and says so'

bound_out="$(HQ_ACTIVE_COMPANY=alpha bash "$HELPER" --root "$fixture" --files-touched-json-file "$TMP/changeset.json")"
[[ "$bound_out" != *'SKIPPED-COMPANY-KNOWLEDGE'* ]] || fail 'bound handoff does not report a company skip'
[[ "$bound_out" != *'beta'* ]] || fail "bound handoff output never names the other company (got: $bound_out)"
[ "$(git -C "$fixture/companies/alpha/knowledge" rev-parse HEAD)" != "$alpha_head" ] || fail 'bound company knowledge was committed'
committed="$(git -C "$fixture/companies/alpha/knowledge" show --pretty=format: --name-only HEAD | sed '/^$/d')"
[ "$committed" = 'notes.md' ] || fail "bound commit holds only the session file (got: $committed)"
[ "$(git -C "$fixture/companies/beta/knowledge" rev-parse HEAD)" = "$beta_head" ] || fail 'other company knowledge was not committed'
[ -n "$(git -C "$fixture/companies/beta/knowledge" status --porcelain -- notes.md)" ] || fail 'other company dirty file is preserved'
ok 'handoff bound to alpha commits only alpha knowledge'

step_one="$(sed -n '/^### 1\./,/^### 2\./p' "$SKILL")"
[[ "$step_one" == *'HQ_ACTIVE_COMPANY'* ]] || fail 'Step 1 names the bound-company source'
[[ "$step_one" == *'SKIPPED-COMPANY-KNOWLEDGE:'* ]] || fail 'Step 1 documents the unbound skip line'
grep -Fq 'Step 1 printed `SKIPPED-COMPANY-KNOWLEDGE:`' "$SKILL" || fail 'Step 6 report carries the unbound skip'
ok 'shared handoff skill text documents the company scope for every runtime'

# ---- session journal: company tags and the SessionStart loader -------------
jroot="$TMP/jhq"
mkdir -p "$jroot/workspace/sessions/sess-alpha" "$jroot/workspace/sessions/sess-none"
printf 'company_slug: alpha\n' > "$jroot/workspace/sessions/sess-alpha/meta.yaml"
printf 'session_id: sess-none\n' > "$jroot/workspace/sessions/sess-none/meta.yaml"
alpha_entry="$(HQ_ROOT="$jroot" HQ_ACTIVE_COMPANY=alpha bash "$JOURNAL" write "alpha milestone")"
HQ_ROOT="$jroot" bash "$JOURNAL" write "beta milestone" --company beta >/dev/null
HQ_ROOT="$jroot" bash "$JOURNAL" write "untagged milestone" >/dev/null
# A beta entry whose title merely mentions alpha's tag must not leak into alpha.
HQ_ROOT="$jroot" bash "$JOURNAL" write "beta note about [company: alpha] handling" --company beta >/dev/null
grep -qx 'company: alpha' "$alpha_entry" || fail 'journal entry frontmatter records the company'
idx="$(HQ_ROOT="$jroot" bash "$JOURNAL" index-path)"
grep -q 'alpha milestone \[company: alpha\]$' "$idx" || fail 'INDEX line carries the company tag'
grep -q 'untagged milestone$' "$idx" || fail 'unbound entry stays untagged'
ok 'journal writes tag entries with the bound company'

assert_alpha_only() {
  local label="$1" out="$2"
  [[ "$out" == *'alpha milestone'* ]] || fail "$label: bound company entry surfaces (got: $out)"
  [[ "$out" != *'beta milestone'* ]] || fail "$label: other company entry is withheld"
  [[ "$out" != *'untagged milestone'* ]] || fail "$label: untagged entry is withheld"
  [[ "$out" != *'beta note about'* ]] || fail "$label: a title that mentions the tag mid-line is withheld"
}

out="$(CLAUDE_PROJECT_DIR="$jroot" HQ_ACTIVE_COMPANY=alpha bash "$HOOK" </dev/null)"
assert_alpha_only 'env-bound' "$out"
out="$(printf '{"session_id":"sess-alpha"}' | CLAUDE_PROJECT_DIR="$jroot" bash "$HOOK")"
assert_alpha_only 'meta-bound' "$out"
out="$(printf '{"session_id":"sess-none"}' | CLAUDE_PROJECT_DIR="$jroot" bash "$HOOK")"
[ -z "$out" ] || fail "unbound session gets no journal entries (got: $out)"
ok 'journal loader injects only the bound company entries, none when unbound'

# ---- the same loader through the Codex and Grok adapters -------------------
fix="$jroot"
mkdir -p "$fix/.claude/hooks" "$fix/.codex/hooks" "$fix/.grok/hooks" "$fix/core/scripts/lib"
cp "$HOOK" "$fix/.claude/hooks/load-journal-index-on-start.sh"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$fix/core/scripts/lib/hook-adapter-core.sh"
cp "$ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$fix/.codex/hooks/hq-codex-hook-adapter.sh"
cp "$ROOT/.grok/hooks/hq-grok-hook-adapter.sh" "$fix/.grok/hooks/hq-grok-hook-adapter.sh"
: > "$fix/core/scripts/hook-lib.sh"
# The fixture keeps the release SessionStart registration (the master hook).
# Its stub master hook runs the real journal loader on the payload the adapter
# forwarded and records the output, because Grok ignores SessionStart stdout.
jq '{hooks: {SessionStart: .hooks.SessionStart}}' "$ROOT/.claude/settings.json" > "$fix/.claude/settings.json"
cat > "$fix/.claude/hooks/hook-gate.sh" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--lib" ] && { return 0 2>/dev/null || exit 0; }
cat >/dev/null 2>&1 || true
exit 0
STUB
cat > "$fix/.claude/hooks/master-hook.sh" <<'STUB'
#!/bin/bash
payload="$(cat 2>/dev/null || true)"
[ "${1:-}" = "SessionStart" ] || exit 0
printf '%s' "$payload" | bash "$CLAUDE_PROJECT_DIR/.claude/hooks/load-journal-index-on-start.sh" >> "$CLAUDE_PROJECT_DIR/capture.log"
exit 0
STUB

run_adapter() {
  local adapter="$1" payload="$2"
  : > "$fix/capture.log"
  (cd "$fix" && printf '%s' "$payload" | env -u HQ_ACTIVE_COMPANY CLAUDE_PROJECT_DIR="$fix" HQ_ROOT="$fix" \
    bash "$adapter" >"$fix/adapter.out" 2>&1) || true
  [ -z "${DEBUG_ADAPTER:-}" ] || cat "$fix/adapter.out" >&2
  cat "$fix/capture.log"
}

for runtime in codex grok; do
  adapter="$fix/.$runtime/hooks/hq-$runtime-hook-adapter.sh"
  out="$(run_adapter "$adapter" "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"sess-alpha\",\"cwd\":\"$fix\"}")"
  assert_alpha_only "$runtime-bound" "$out"
  out="$(run_adapter "$adapter" "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"sess-none\",\"cwd\":\"$fix\"}")"
  [[ "$out" != *'milestone'* ]] || fail "$runtime: unbound session gets no journal entries (got: $out)"
  ok "$runtime adapter dispatch keeps the journal loader company-scoped"
done

echo "PASS: handoff-journal-company-scope"
