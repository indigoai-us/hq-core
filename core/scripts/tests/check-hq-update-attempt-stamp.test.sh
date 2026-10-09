#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/check-hq-update.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP/root/core/scripts" "$TMP/bin"
printf 'hqVersion: "15.0.131"\n' > "$TMP/root/core/core.yaml"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TMP/root/core/scripts/remove-stray-gate-hooks.sh"
chmod +x "$TMP/root/core/scripts/remove-stray-gate-hooks.sh"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${1:-}" "${2:-}" >> "$HQ_TEST_GH_CALLS"
exit 1
EOF
chmod +x "$TMP/bin/gh"

stamp="$TMP/state/release-network-attempt.last"
call_count() { wc -l < "$TMP/gh.calls" | tr -d '[:space:]'; }
run_hook() {
  local label="$1" rc=0
  env -u CI \
    BASH_ENV=/dev/null \
    CLAUDE_PROJECT_DIR="$TMP/root" \
    HQ_UPDATE_CHECK_STATE_DIR="$TMP/state" \
    HQ_TEST_GH_CALLS="$TMP/gh.calls" \
    PATH="$TMP/bin:/usr/bin:/bin" \
    bash "$HOOK" > "$TMP/$label.out" 2> "$TMP/$label.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label returned $rc instead of 0"
  [ ! -s "$TMP/$label.out" ] || fail "$label changed the no-update output"
  [ ! -s "$TMP/$label.err" ] || fail "$label wrote to stderr"
}

: > "$TMP/gh.calls"
run_hook first
[ "$(call_count)" = 1 ] || fail 'the first SessionStart did not attempt the GitHub check'
[ -f "$stamp" ] || fail 'a failed GitHub check did not write a daily attempt stamp'
run_hook second
[ "$(call_count)" = 1 ] || fail 'a recent failed GitHub check was repeated on the next SessionStart'

printf 'PASS: failed release checks are stamp-gated without changing output or exit status\n'
