#!/usr/bin/env bash
set -euo pipefail

# Re-run the documented tracked-source search, require every executable helper
# call or file guard in a registered hook to appear in the checker's mapping,
# then prove the detector catches an unmapped synthetic hook.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHECKER="${HOOK_CHECKER_SOURCE:-$ROOT/core/scripts/check-hq-hooks.sh}"
CONTRACT="$ROOT/core/docs/hq/hook-helper-contract.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HELPER_PATTERN='derive-trigger-facts|eval-trigger|session-title|session-title-config|session-project|session-journal|share-suggestion-state|repo-run-registry|detect-stale-review-base|register-project|migrate-policy-triggers|work-mesh-live-rebind'
MAP="$(awk '/# CALL_SITE_MAP_START/ { inside = 1; next } /# CALL_SITE_MAP_END/ { exit } inside { print }' "$CHECKER")"

[ -n "$MAP" ] || { echo 'FAIL: helper call-site map markers are missing' >&2; exit 1; }

mapping_has() {
  local wanted_hook="$1" wanted_helper="$2" hook helper form
  while IFS='|' read -r hook helper form; do
    [ -n "$hook" ] && [ -n "$helper" ] && [ -n "$form" ] || continue
    if [ "$hook" = "$wanted_hook" ] && [ "$helper" = "$wanted_helper" ]; then
      return 0
    fi
  done <<< "$MAP"
  return 1
}

mapping_matches_contract() {
  local wanted_hook="$1" wanted_helper="$2" wanted_form="$3"
  local hook_marker helper_marker form_marker matches
  hook_marker="$(printf '`%s`' "$wanted_hook")"
  helper_marker="$(printf '`%s`' "${wanted_helper##*/}")"
  form_marker="$(printf '| `%s`:' "$wanted_form")"
  matches="$(grep -F "$hook_marker" "$CONTRACT" | grep -F "$helper_marker" | grep -F "$form_marker" || true)"
  [ -n "$matches" ]
}

while IFS='|' read -r hook helper form; do
  [ -n "$hook" ] && [ -n "$helper" ] || continue
  case "$form" in
    exec|bash|guard) ;;
    *) printf 'FAIL: helper mapping has no recognized third-field call form: %s|%s|%s\n' \
      "$hook" "$helper" "$form" >&2; exit 1 ;;
  esac
  mapping_matches_contract "$hook" "$helper" "$form" || {
    printf 'FAIL: helper mapping disagrees with the documented call form: %s|%s|%s\n' \
      "$hook" "$helper" "$form" >&2
    exit 1
  }
done <<< "$MAP"
echo '  ok: checker call forms match the contract table'

registered_hook() {
  local repo="$1" path="$2"
  case "$path" in
    .claude/hooks/*.sh|core/scripts/migrate-policy-triggers.sh)
      jq -e --arg script "$path" \
        'any(.. | objects; .script? == $script)' \
        "$repo/.claude/hooks/hook-registry.json" >/dev/null 2>&1
      ;;
    .codex/hooks/*.sh|.grok/hooks/*.sh|core/hooks/*.sh|core/scripts/lib/*.sh)
      return 0
      ;;
    *) return 1 ;;
  esac
}

find_unmapped_calls() {
  local repo="$1" output rc path _line_number line trimmed helper helper_path
  rc=0
  output="$(git -C "$repo" grep -nE "$HELPER_PATTERN" -- \
    '.claude/hooks' '.codex/hooks' '.grok/hooks' 'core/hooks' \
    'core/scripts/lib' 'core/scripts/migrate-policy-triggers.sh' \
    ':!.claude/hooks/tests' ':!core/scripts/tests' ':!core/scripts/__tests__' 2>&1)" || rc=$?
  [ "$rc" -le 1 ] || { printf '%s\n' "$output" >&2; return 2; }

  while IFS=: read -r path line_number line; do
    [ -n "$path" ] || continue
    case "$path" in
      *.sh) ;;
      *) continue ;;
    esac
    case "$path" in
      */tests/*|*/__tests__/*) continue ;;
    esac
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      \#*|CTX=*) continue ;;
    esac
    registered_hook "$repo" "$path" || continue

    for helper in \
      derive-trigger-facts eval-trigger session-title session-title-config \
      session-project session-journal share-suggestion-state repo-run-registry \
      detect-stale-review-base register-project migrate-policy-triggers work-mesh-live-rebind; do
      helper_path="$helper.sh"
      # A library with the same basename is a different module from the planned
      # core/scripts/<helper>.sh command; user-facing path text is not a call.
      case "$trimmed" in
        *"core/scripts/lib/$helper_path"*) continue ;;
        *"/$helper_path"*) ;;
        *) continue ;;
      esac
      if ! mapping_has "$path" "core/scripts/$helper_path"; then
        printf '%s|core/scripts/%s\n' "$path" "$helper_path"
      fi
    done
  done <<< "$output" | sort -u
}

real_unmapped="$(find_unmapped_calls "$ROOT")" || {
  echo 'FAIL: documented call-site search failed on the real tree' >&2
  exit 1
}
[ -z "$real_unmapped" ] || {
  printf 'FAIL: registered helper call sites are absent from the map:\n%s\n' "$real_unmapped" >&2
  exit 1
}
echo '  ok: documented tracked-source search is covered by the helper map'

FIX="$TMP/fixture"
mkdir -p "$FIX/.claude/hooks" "$FIX/.codex/hooks" "$FIX/.grok/hooks" \
  "$FIX/core/hooks" "$FIX/core/scripts/lib"
cat > "$FIX/.claude/hooks/hook-registry.json" <<'JSON'
{"entries":[{"script":".claude/hooks/unmapped-hook.sh"}]}
JSON
cat > "$FIX/.claude/hooks/unmapped-hook.sh" <<'HOOK'
#!/usr/bin/env bash
# Documentation does not create a call site: core/scripts/session-journal.sh
bash "$ROOT/core/scripts/work-mesh-live-rebind.sh" --from-state
HOOK
cat > "$FIX/core/scripts/non-hook-caller.sh" <<'NONHOOK'
#!/usr/bin/env bash
bash "$ROOT/core/scripts/session-journal.sh"
NONHOOK
: > "$FIX/core/scripts/migrate-policy-triggers.sh"
: > "$FIX/.codex/hooks/.keep"
: > "$FIX/.grok/hooks/.keep"
: > "$FIX/core/hooks/.keep"
: > "$FIX/core/scripts/lib/.keep"
git -C "$FIX" init -q
git -C "$FIX" add .

fixture_unmapped="$(find_unmapped_calls "$FIX")" || {
  echo 'FAIL: documented call-site search failed on the synthetic fixture' >&2
  exit 1
}
expected='.claude/hooks/unmapped-hook.sh|core/scripts/work-mesh-live-rebind.sh'
[[ "$fixture_unmapped" == "$expected" ]] || {
  printf 'FAIL: unmapped fixture call was not detected; got: %s\n' "${fixture_unmapped:-<none>}" >&2
  exit 1
}
echo "  ok: synthetic registered hook is detected as unmapped: $expected"
echo 'PASS: hook helper call-site coverage'
