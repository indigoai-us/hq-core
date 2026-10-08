#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass() { echo "ok: $*"; }

make_root() {
  local root="$1"
  mkdir -p "$root/.claude/hooks" "$root/.codex/hooks" "$root/.grok/hooks" \
    "$root/core/scripts/lib" "$root/core/policies" "$root/personal/policies" \
    "$root/workspace"
  cp "$ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$root/.codex/hooks/"
  cp "$ROOT/.grok/hooks/hq-grok-hook-adapter.sh" "$root/.grok/hooks/"
  cp "$ROOT/.claude/hooks/hook-gate.sh" "$root/.claude/hooks/"
  cp "$ROOT/.claude/hooks/policy-enforcement-gate.sh" "$root/.claude/hooks/"
  cp "$ROOT/core/scripts/hook-lib.sh" "$root/core/scripts/"
  cp "${HQ_TEST_ADAPTER_CORE_LIB:-$ROOT/core/scripts/lib/hook-adapter-core.sh}" "$root/core/scripts/lib/hook-adapter-core.sh"
  cp "$ROOT/core/scripts/lib/trigger-fact-text.awk" "$root/core/scripts/lib/"
  cat > "$root/.claude/hooks/master-hook.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  for id in adapter-alpha adapter-beta registry-alpha registry-beta; do
    cat > "$root/.claude/hooks/$id.sh" <<SH
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '$id' >> "\${HQ_TEST_HOOK_RUN_LOG:?}"
SH
    chmod +x "$root/.claude/hooks/$id.sh"
  done
  cat > "$root/.claude/hooks/hook-registry.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"id":"registry-alpha","script":".claude/hooks/registry-alpha.sh"},{"id":"registry-beta","script":".claude/hooks/registry-beta.sh"}]}]}}
JSON
  cat > "$root/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/master-hook.sh\" PreToolUse"},{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/adapter-alpha.sh\""},{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/adapter-beta.sh\""}]}]}}
JSON
  cat > "$root/.claude/settings.local.json" <<'JSON'
{"env":{"LOCAL_KEEP":"yes"},"permissions":{"allow":["Bash(git status:*)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/registry-alpha.sh\"","timeout":31},{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/registry-beta.sh\"","timeout":32}]}]}}
JSON
}

fallback_registry() {
  local root="$1" registry_mode="$2"
  case "$registry_mode" in
    missing) rm -f "$root/.claude/hooks/hook-registry.json" ;;
    malformed) printf '%s\n' '{not json' > "$root/.claude/hooks/hook-registry.json" ;;
  esac
  HQ_ROOT="$root" bash -c '
    . "$HQ_ROOT/core/scripts/lib/hook-adapter-core.sh"
    hqad_iter_registry PreToolUse Bash "{}"
  ' 2>/dev/null
}

run_adapter() {
  local provider="$1" root="$2" adapter
  [ "$provider" = codex ] && adapter="$root/.codex/hooks/hq-codex-hook-adapter.sh" || adapter="$root/.grok/hooks/hq-grok-hook-adapter.sh"
  grep -Fq 'hqad_iter_settings' "$adapter" || return 1
  HQ_ROOT="$root" HQ_CHECKPOINT_RUNTIME="$provider" bash -c '
    export HQ_ROOT HQ_CHECKPOINT_RUNTIME
    . "$HQ_ROOT/core/scripts/lib/hook-adapter-core.sh"
    hqad_iter_settings PreToolUse Bash
  ' | awk -F '\t' '
    $1 == "gate" { print "gate:" $2; next }
    $1 == "master" { print "master:" $2; next }
    $1 == "script" { n=split($2,p,"/"); print "script:" p[n] }
  '
}

for engine in jq node; do
  command -v "$engine" >/dev/null 2>&1 || continue
  for provider in codex grok; do
    before_root="$TMP/$engine-$provider-before"
    make_root "$before_root"
    before="$(run_adapter "$provider" "$before_root")"
    case "$before" in *registry-alpha*registry-beta*master:PreToolUse*adapter-alpha.sh*adapter-beta.sh*) ;; *) fail "$engine/$provider did not dispatch the expected settings/registry ids: $before" ;; esac
    after_root="$TMP/$engine-$provider-after"
    make_root "$after_root"
    HQ_HOOK_ENGINE="$engine" bash "$ROOT/core/scripts/remove-stray-gate-hooks.sh" "$after_root" >/dev/null
    after="$(run_adapter "$provider" "$after_root")"
    [ "$after" = "$before" ] || fail "$engine/$provider adapter dispatch changed after local cleanup: $before -> $after"
    [ "$(jq -r '.env.LOCAL_KEEP' "$after_root/.claude/settings.local.json")" = yes ] || fail "$engine/$provider cleanup lost local env"
    [ "$(jq -c '.permissions.allow' "$after_root/.claude/settings.local.json")" = '["Bash(git status:*)"]' ] || fail "$engine/$provider cleanup lost permissions"
    [ "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(contains("registry-"))] | length' "$after_root/.claude/settings.local.json")" = 0 ] || fail "$engine/$provider cleanup left a registry script registered locally"
  done
  pass "$engine: Codex and Grok settings.json hook id lists are unchanged after local cleanup"
done

fallback_root="$TMP/fallback-policy-gate"
make_root "$fallback_root"
for registry_mode in missing malformed; do
  fallback="$(fallback_registry "$fallback_root" "$registry_mode")"
  printf '%s\n' "$fallback" | awk -F '\t' '$1 == "gate" && $2 == "policy-enforcement-gate" {found=1} END {exit !found}' \
    || fail "$registry_mode registry fallback omitted policy-enforcement-gate"
done
pass "Codex/Grok registry fallback retains policy enforcement with missing or malformed registry"

[ "$FAIL" -eq 0 ] || exit 1
echo 'PASS: adapter dispatch parity across local duplicate cleanup'
