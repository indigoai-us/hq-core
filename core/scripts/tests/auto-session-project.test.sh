#!/usr/bin/env bash
# Smoke tests for auto-session-project UserPromptSubmit hook.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label: missing '$needle'"
}

assert_empty() {
  local value="$1" label="$2"
  [ -z "$value" ] || fail "$label: expected empty output, got: $value"
}

assert_event_present() {
  local prd_path="$1" summary="$2" label="$3"
  python3 - "$prd_path" "$summary" <<'PY' || fail "$label"
import json
import sys

with open(sys.argv[1]) as fh:
    prd = json.load(fh)
events = prd.get("metadata", {}).get("nativeEvents", [])
assert any(event.get("summary") == sys.argv[2] for event in events)
PY
}

assert_event_absent() {
  local prd_path="$1" summary="$2" label="$3"
  python3 - "$prd_path" "$summary" <<'PY' || fail "$label"
import json
import sys

with open(sys.argv[1]) as fh:
    prd = json.load(fh)
events = prd.get("metadata", {}).get("nativeEvents", [])
assert not any(event.get("summary") == sys.argv[2] for event in events)
PY
}

mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts" "$TMP/personal/projects/native-project-journaling" "$TMP/companies"
cp "$ROOT/.claude/hooks/auto-session-project.sh" "$TMP/.claude/hooks/auto-session-project.sh"
cp "$ROOT/core/scripts/session-project.sh" "$TMP/core/scripts/session-project.sh"
cp "$ROOT/core/scripts/resolve-company.sh" "$TMP/core/scripts/resolve-company.sh"
# The hook sources hook-lib.sh relative to its own location (../../core/scripts).
cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/hook-lib.sh"
chmod +x "$TMP/.claude/hooks/auto-session-project.sh" "$TMP/core/scripts/session-project.sh" \
  "$TMP/core/scripts/resolve-company.sh"
cat > "$TMP/companies/manifest.yaml" <<'YAML'
companies:
  acme:
    name: Acme
YAML
# Isolate from the live HQ session so resolve-company does not inherit indigo.
unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID
export HQ_HQ_SESSION_NO_CLI=1
export HQ_ROOT="$TMP"
export CLAUDE_PROJECT_DIR="$TMP"

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

payload='{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"in hqwork make native claude/codex executions automatically journal to project prd files"}'
out=$(CLAUDE_PROJECT_DIR="$TMP" "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload")
assert_contains "$out" "auto-session-project" "context wrapper"
assert_contains "$out" "personal/projects/native-project-journaling" "reused related project"
assert_contains "$(cat "$TMP/.claude/state/active-session-project")" "native-project-journaling" "active pointer"

out_second=$(CLAUDE_PROJECT_DIR="$TMP" "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload")
assert_empty "$out_second" "second prompt is quiet"

# Regression: a session continues in its uniquely relocated project when a
# Personal project is moved into a company. The old path must stay absent.
mkdir -p "$TMP/personal/projects/atlas-relocation"
cat > "$TMP/personal/projects/atlas-relocation/prd.json" <<'JSON'
{
  "name": "atlas-relocation",
  "description": "Atlas relocation across organizational homes",
  "metadata": {"goal": "Relocate Atlas work"},
  "userStories": []
}
JSON
payload_relocation='{"hook_event_name":"UserPromptSubmit","session_id":"relocate-personal","prompt":"in hqwork continue atlas relocation across organizational homes"}'
out_relocation=$(CLAUDE_PROJECT_DIR="$TMP" "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload_relocation")
assert_contains "$out_relocation" "personal/projects/atlas-relocation" "personal relocation source selected"
mkdir -p "$TMP/companies/acme/projects"
mv "$TMP/personal/projects/atlas-relocation" "$TMP/companies/acme/projects/atlas-relocated"
out_relocated=$(CLAUDE_PROJECT_DIR="$TMP" "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload_relocation")
assert_empty "$out_relocated" "relocated follow-up is quiet"
[[ ! -e "$TMP/personal/projects/atlas-relocation" ]] || fail "personal relocation source was recreated"
assert_event_present \
  "$TMP/companies/acme/projects/atlas-relocated/prd.json" \
  "in hqwork continue atlas relocation across organizational homes" \
  "relocated company project did not receive follow-up event"
grep -qxF 'companies/acme/projects/atlas-relocated' \
  "$TMP/.claude/state/auto-session-project-relocate-personal" \
  || fail "relocated session marker was not refreshed"

# Regression: the same reconciliation works for a rename within a company.
mkdir -p "$TMP/companies/acme/projects/zephyr-original"
cat > "$TMP/companies/acme/projects/zephyr-original/prd.json" <<'JSON'
{
  "name": "zephyr-original",
  "description": "Zephyr billing initiative within company",
  "metadata": {"goal": "Rename Zephyr billing initiative"},
  "userStories": []
}
JSON
payload_rename='{"hook_event_name":"UserPromptSubmit","session_id":"rename-company","prompt":"acme rename zephyr billing initiative within company"}'
out_rename=$(CLAUDE_PROJECT_DIR="$TMP" "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload_rename")
assert_contains "$out_rename" "companies/acme/projects/zephyr-original" "company rename source selected"
mv "$TMP/companies/acme/projects/zephyr-original" "$TMP/companies/acme/projects/zephyr-renamed"
out_renamed=$(CLAUDE_PROJECT_DIR="$TMP" "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload_rename")
assert_empty "$out_renamed" "renamed follow-up is quiet"
[[ ! -e "$TMP/companies/acme/projects/zephyr-original" ]] || fail "company rename source was recreated"
assert_event_present \
  "$TMP/companies/acme/projects/zephyr-renamed/prd.json" \
  "acme rename zephyr billing initiative within company" \
  "renamed company project did not receive follow-up event"

# Regression: each session marker wins over the shared active pointer.
mkdir -p "$TMP/personal/projects/orion-telemetry" "$TMP/personal/projects/nebula-indexing"
cat > "$TMP/personal/projects/orion-telemetry/prd.json" <<'JSON'
{
  "name": "orion-telemetry",
  "description": "Orion telemetry alerts",
  "metadata": {"goal": "Improve Orion telemetry alerts"},
  "userStories": []
}
JSON
cat > "$TMP/personal/projects/nebula-indexing/prd.json" <<'JSON'
{
  "name": "nebula-indexing",
  "description": "Nebula indexing throughput",
  "metadata": {"goal": "Improve Nebula indexing throughput"},
  "userStories": []
}
JSON
payload_orion='{"hook_event_name":"UserPromptSubmit","session_id":"session-orion","prompt":"in hqwork improve orion telemetry alerts"}'
payload_nebula='{"hook_event_name":"UserPromptSubmit","session_id":"session-nebula","prompt":"in hqwork improve nebula indexing throughput"}'
CLAUDE_PROJECT_DIR="$TMP" "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload_orion" >/dev/null
CLAUDE_PROJECT_DIR="$TMP" "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload_nebula" >/dev/null
out_orion_followup=$(CLAUDE_PROJECT_DIR="$TMP" "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload_orion")
assert_empty "$out_orion_followup" "first session follow-up is quiet"
assert_event_present \
  "$TMP/personal/projects/orion-telemetry/prd.json" \
  "in hqwork improve orion telemetry alerts" \
  "first session event did not follow its marker"
assert_event_absent \
  "$TMP/personal/projects/nebula-indexing/prd.json" \
  "in hqwork improve orion telemetry alerts" \
  "first session event followed the shared active pointer"

payload_traversal='{"hook_event_name":"UserPromptSubmit","session_id":"../escape","prompt":"in hqwork make native claude/codex executions automatically journal to project prd files"}'
out_traversal=$(CLAUDE_PROJECT_DIR="$TMP" "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload_traversal")
assert_contains "$out_traversal" "auto-session-project" "traversal payload still handled"
[ -f "$TMP/.claude/state/auto-session-project-.._escape" ] || fail "sanitized session marker missing"
[ ! -e "$TMP/.claude/escape" ] || fail "session id escaped state dir"

out_disabled=$(CLAUDE_PROJECT_DIR="$TMP" HQ_AUTO_SESSION_PROJECT=0 "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload")
assert_empty "$out_disabled" "disabled env is quiet"

out_trivial=$(CLAUDE_PROJECT_DIR="$TMP" "$TMP/.claude/hooks/auto-session-project.sh" <<<'{"session_id":"s2","prompt":"thanks"}')
assert_empty "$out_trivial" "trivial prompt is quiet"

# Ghost tenant: a leftover companies/ok dir must NOT capture "ok …" prompts.
mkdir -p "$TMP/companies/ok/projects/already-there"
payload_ok='{"session_id":"s-ok-ghost","prompt":"ok really will fix sync try now please"}'
out_ok=$(CLAUDE_PROJECT_DIR="$TMP" "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload_ok")
assert_contains "$out_ok" "personal/projects" "ok-prefix prompt files personal, not companies/ok"
case "$out_ok" in
  *companies/ok*) fail "ok-prefix prompt must not mention companies/ok" ;;
esac
[ ! -d "$TMP/companies/ok/projects/really-will-fix-sync-try" ] || fail "ghost ok company grew a new project"

# session-project must not mkdir an unregistered company even when asked.
ensure_out="$("$TMP/core/scripts/session-project.sh" ensure \
  --scope company --company ghostco --title "ghost tenant" \
  --prompt "unique ghost-tenant fallback probe xyzzy" \
  --session-id s-ghost-ensure --origin test --force-new)"
case "$ensure_out" in
  *personal/projects*) ;;
  *) fail "unregistered company ensure should fall back to personal: $ensure_out" ;;
esac
case "$ensure_out" in
  *companies/ghostco*) fail "ensure must not file under an unregistered company: $ensure_out" ;;
esac
[ ! -d "$TMP/companies/ghostco" ] || fail "ensure must not mkdir an unregistered company tree"

echo "auto-session-project smoke: ok"
