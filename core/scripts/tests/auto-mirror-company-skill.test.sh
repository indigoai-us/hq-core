#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HOOK="${AUTO_MIRROR_TEST_HOOK:-$ROOT/.claude/hooks/auto-mirror-company-skill.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/auto-mirror-company-skill.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); printf '  ok %s\n' "$1"; }

CLI="$TMP/npm-global/lib/node_modules/@indigoai-us/hq-cli"
mkdir -p "$CLI/bin" "$CLI/node_modules/@indigoai-us/hq-flags-client" \
  "$CLI/node_modules/@indigoai-us/hq-cloud" "$TMP/bin"
cat > "$TMP/bin/yq" <<'SH'
#!/usr/bin/env bash
file="${@: -1}"
awk '
  /^  acme-team:$/ { in_company = 1; next }
  in_company && /^[^ ]/ { exit }
  in_company && /^    prefix:/ {
    sub(/^    prefix:[[:space:]]*/, "")
    gsub(/^"|"$/, "")
    print
    found = 1
    exit
  }
  END { if (!found) print "" }
' "$file"
SH
chmod +x "$TMP/bin/yq"
printf '%s\n' '{"name":"@indigoai-us/hq-cli","bin":{"hq":"bin/hq"}}' > "$CLI/package.json"
printf '%s\n' '#!/usr/bin/env sh' 'exit 0' > "$CLI/bin/hq"
chmod +x "$CLI/bin/hq"
ln -s "$CLI/bin/hq" "$TMP/bin/hq"
printf '%s\n' '{"type":"module","exports":{".":{"import":"./index.js"}}}' > "$CLI/node_modules/@indigoai-us/hq-flags-client/package.json"
cat > "$CLI/node_modules/@indigoai-us/hq-flags-client/index.js" <<'JS'
export const createFlagClient = () => ({
  ready: async () => {},
  snapshot: () => ({ flags: { "hooks.company-skill-slug-fallback": process.env.HQ_TEST_FLAG_ENABLED === "true" } }),
  close() {},
});
JS
printf '%s\n' '{"type":"module","exports":{".":{"import":"./index.js"}}}' > "$CLI/node_modules/@indigoai-us/hq-cloud/package.json"
printf '%s\n' 'export const loadCachedTokens = () => ({ idToken: "test-only-token" });' > "$CLI/node_modules/@indigoai-us/hq-cloud/index.js"

setup_project() {
  local prefix="$1" slug="acme-team"
  PROJECT="$TMP/project-$((pass + 1))"
  mkdir -p "$PROJECT/companies/$slug/skills/sample-skill" "$PROJECT/.claude/skills"
  printf '%s\n' 'companies:' "  $slug:" "    prefix: $prefix" > "$PROJECT/companies/manifest.yaml"
  printf '%s\n' '---' 'name: sample-skill' '---' 'sample content' > "$PROJECT/companies/$slug/skills/sample-skill/SKILL.md"
}

run_hook() {
  local flag="$1" path="$2"
  printf '{"tool_input":{"file_path":"%s"}}' "$path" \
    | env PATH="$TMP/bin:$PATH" HQ_FLAGS_API_URL=https://flags.invalid \
      HQ_COMPANY_UID=cmp_Test123 HQ_COMPANY_SLUG=indigo HQ_TEST_FLAG_ENABLED="$flag" \
      CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" 2>"$TMP/stderr"
}

setup_project '""'
run_hook true "$PROJECT/companies/acme-team/skills/sample-skill/SKILL.md"
[ -L "$PROJECT/.claude/skills/acme-team-sample-skill" ] || fail "empty manifest prefix should mirror under the company slug"
[ "$(readlink "$PROJECT/.claude/skills/acme-team-sample-skill")" = "../../companies/acme-team/skills/sample-skill" ] || fail "slug mirror should point to the source skill"
ok "empty prefix mirrors under the company slug when the flag is enabled"

setup_project 'indigo'
run_hook false "$PROJECT/companies/acme-team/skills/sample-skill/SKILL.md"
[ -L "$PROJECT/.claude/skills/indigo-sample-skill" ] || fail "explicit prefix must retain the existing mirror name"
[ ! -e "$PROJECT/.claude/skills/acme-team-sample-skill" ] || fail "explicit prefix must not also mirror under the slug"
ok "explicit prefix remains unchanged"

setup_project '""'
mkdir -p "$PROJECT/.claude/skills/acme-team-sample-skill"
printf '%s\n' '---' 'name: user-owned' '---' > "$PROJECT/.claude/skills/acme-team-sample-skill/SKILL.md"
run_hook true "$PROJECT/companies/acme-team/skills/sample-skill/SKILL.md"
[ ! -L "$PROJECT/.claude/skills/acme-team-sample-skill" ] || fail "collision must not be replaced with a symlink"
[ -f "$PROJECT/.claude/skills/acme-team-sample-skill/SKILL.md" ] || fail "collision must preserve the user skill"
ok "existing user skill collision is skipped"

setup_project '""'
run_hook false "$PROJECT/companies/acme-team/skills/sample-skill/SKILL.md"
[ ! -e "$PROJECT/.claude/skills/acme-team-sample-skill" ] || fail "default-off flag must keep empty-prefix behavior unchanged"
grep -Fq 'skipping mirror' "$TMP/stderr" || fail "gate-off path should retain the skip warning"
ok "gate off leaves empty-prefix behavior unchanged"

PROJECT="$TMP/unsafe-company"
mkdir -p "$PROJECT/companies/bad_slug/skills/sample-skill"
printf '%s\n' 'companies:' '  bad_slug:' '    prefix: ""' > "$PROJECT/companies/manifest.yaml"
printf '%s\n' '---' 'name: sample-skill' '---' > "$PROJECT/companies/bad_slug/skills/sample-skill/SKILL.md"
run_hook true "$PROJECT/companies/bad_slug/skills/sample-skill/SKILL.md"
[ ! -e "$PROJECT/.claude/skills/bad_slug-sample-skill" ] || fail "unsafe company slug must not become a mirror name"
[ "$(wc -l < "$TMP/stderr")" -eq 1 ] || fail "unsafe slug should produce exactly one warning line"
grep -Fq "unsafe company slug" "$TMP/stderr" || fail "unsafe slug warning should explain the skip"
ok "unsafe company slug is skipped with one warning"

printf '\nPASS (%s assertions)\n' "$pass"
