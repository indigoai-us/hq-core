#!/usr/bin/env bash
# Google Antigravity host contract: the shipped files Antigravity reads, the
# release manifest that ships them, and the HQ scripts that recognize the host.
# Antigravity facts: https://antigravity.google/docs/rules (workspace rules in
# .agents/rules/*.md need `trigger:` frontmatter; files are cut at 24,000
# bytes; AGENTS.md at the workspace root is read natively) and
# https://antigravity.google/docs/skills (.agents/skills/<name>/SKILL.md).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
limit=24000

# 1. The always-on workspace rule.
rule="$ROOT/.agents/rules/hq.md"
[ -f "$rule" ] || fail ".agents/rules/hq.md is missing"
[ "$(sed -n 1p "$rule")" = '---' ] || fail "rule must open with YAML frontmatter"
awk 'NR==1{next} /^---$/{exit} {print}' "$rule" > "$TMP/frontmatter"
grep -qx 'trigger: always_on' "$TMP/frontmatter" \
  || fail "rule frontmatter must set trigger: always_on (Antigravity drops rules without a valid trigger)"
grep -q '\.claude/CLAUDE\.md' "$rule" || fail "rule must point at the charter"
grep -q '\.claude/personal-context\.md' "$rule" \
  || fail "rule must name personal-context.md, which Antigravity cannot @import"
grep -q 'personal/CLAUDE\.md' "$rule" || fail "rule must name the personal overlay"
[ "$(wc -c < "$rule")" -lt "$limit" ] || fail "rule exceeds Antigravity's per-file limit"

# 2. The charter Antigravity reads through AGENTS.md, inside the size limit.
[ -L "$ROOT/AGENTS.md" ] || fail "AGENTS.md must stay a symlink to the charter"
[ "$(readlink "$ROOT/AGENTS.md")" = '.claude/CLAUDE.md' ] || fail "AGENTS.md must point at .claude/CLAUDE.md"
[ "$(wc -c < "$ROOT/.claude/CLAUDE.md")" -lt "$limit" ] \
  || fail "charter exceeds Antigravity's ${limit}-byte per-file limit and would be truncated"
grep -q 'Google Antigravity' "$ROOT/.claude/CLAUDE.md" || fail "charter host line must name Google Antigravity"

# 3. Skills reach Antigravity through .agents/skills.
[ -L "$ROOT/.agents/skills" ] || fail ".agents/skills must be a symlink"
[ "$(readlink "$ROOT/.agents/skills")" = '../.claude/skills' ] || fail ".agents/skills must point at ../.claude/skills"

# 4. The release manifest ships and locks .agents/ (rules included).
awk '/^rules:/{r=1} r&&/^  locked:/{l=1;next} l&&/^  [a-z]/{exit} l{print}' "$ROOT/core/core.yaml" > "$TMP/locked"
grep -qx '    - \.agents/' "$TMP/locked" || fail "core.yaml rules.locked must include .agents/"
awk '/^replace_from_staging:/{r=1} r&&/^  paths:/{p=1;next} p&&/^  [a-z]/{exit} p{print}' "$ROOT/core/core.yaml" > "$TMP/replaced"
grep -qx '    - \.agents' "$TMP/replaced" || fail "core.yaml replace_from_staging.paths must include .agents"

# 5. hq-session.sh names the remedy inside an Antigravity shell, and only there.
mkdir -p "$TMP/hq/workspace/sessions" "$TMP/hq/companies/acme"
run_hs() {
  env -u HQ_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
    -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID -u HQ_FLEET_SESSION_ID \
    -u CURSOR_AGENT -u CURSOR_TRACE_ID -u __CFBundleIdentifier \
    HQ_ROOT="$TMP/hq" CLAUDE_PROJECT_DIR="$TMP/hq" HQ_HQ_SESSION_NO_CLI=1 "$@" \
    bash "$ROOT/core/scripts/hq-session.sh" set senior user >/dev/null 2>"$TMP/err"
}
if run_hs __CFBundleIdentifier=com.google.antigravity; then fail "write without identity was permitted"; fi
grep -q 'Google Antigravity does not export a session id' "$TMP/err" || fail "Antigravity shell got no session-id remedy"
grep -q 'HQ_SESSION_ID' "$TMP/err" || fail "Antigravity remedy must name HQ_SESSION_ID"
if run_hs __CFBundleIdentifier=com.example.other; then fail "write without identity was permitted"; fi
if grep -q 'Antigravity' "$TMP/err"; then fail "Antigravity remedy printed outside Antigravity"; fi

# 6. setup-status counts Antigravity conversation history as prior AI footprint.
mkdir -p "$TMP/bin" "$TMP/root/companies" "$TMP/home/.gemini/antigravity/conversations"
printf 'companies: {}\n' > "$TMP/root/companies/manifest.yaml"
: > "$TMP/home/.gemini/antigravity/conversations/c1.pb"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$TMP/bin/timeout"
cat > "$TMP/bin/hq" <<'STUB'
#!/bin/sh
echo '{"authenticated":false}'
STUB
chmod +x "$TMP/bin/timeout" "$TMP/bin/hq"
context_import() {
  PATH="$TMP/bin:$PATH" HOME="$1" bash "$ROOT/core/scripts/setup-status.sh" --root "$TMP/root" --json 2>/dev/null \
    | jq -r '.checks[] | select(.id == "context-import") | .detail' || true
}
[ "$(context_import "$TMP/home")" = 'prior AI footprint found; run /import-context to adopt it' ] \
  || fail "Antigravity conversations were not counted as prior footprint"
mkdir -p "$TMP/empty-home"
[ "$(context_import "$TMP/empty-home")" = 'no prior AI footprint found' ] \
  || fail "empty HOME reported a prior footprint"

echo "PASS: Antigravity rule, charter size, skills link, release manifest, session-id remedy and history scan"
