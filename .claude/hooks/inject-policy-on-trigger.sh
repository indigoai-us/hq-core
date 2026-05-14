#!/bin/bash
# inject-policy-on-trigger.sh — PreToolUse hook that injects a one-line policy
# reminder when a tool invocation matches a known trigger.
#
# Tier-3 of the policy injection model (see .claude/plans/please-evaluate-...md).
# Tier 1 = always-on (digest at SessionStart). Tier 2 = stack-filtered. Tier 3
# is THIS file: load only when a concrete tool/path pattern fires, ~150 bytes
# per match. The trigger map is hardcoded below for the MVP — future iteration
# will generate it from `triggers:` frontmatter on policy files.
#
# Input: PreToolUse JSON on stdin —
#   {"session_id":"abc","tool_name":"Bash","tool_input":{"command":"find . ..."}}
# Output: a `<policy-reminder>` block on stdout when matched, otherwise nothing.
# Dedupe: per-session-id; same slug never fires twice in one session.
# Exit: always 0 (advisory hook, never blocks).

set -euo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"

extract() {
  printf '%s' "$STDIN_JSON" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
keys = sys.argv[1].split(".")
v = data
for k in keys:
    if isinstance(v, dict):
        v = v.get(k, "")
    else:
        v = ""
        break
if isinstance(v, (dict, list)):
    v = ""
print(str(v))
' "$1" 2>/dev/null || echo ""
}

SESSION_ID="$(extract session_id)"
TOOL_NAME="$(extract tool_name)"
[ -z "$TOOL_NAME" ] && exit 0

case "$TOOL_NAME" in
  Bash)                       ARG="$(extract tool_input.command)" ;;
  Edit|Write|MultiEdit|NotebookEdit) ARG="$(extract tool_input.file_path)" ;;
  *) exit 0 ;;
esac
[ -z "$ARG" ] && exit 0

# Trigger registry. Tab-separated: ToolName \t extended-regex \t slug \t rule.
# (Tab chosen because regex patterns commonly use `|` for alternation.)
# Keep rule lines under 120 chars. Add new triggers here; one per line.
TAB=$'\t'
TRIGGERS=$(printf '%s\n' \
  "Bash${TAB}(^|[[:space:]])find[[:space:]]${TAB}hq-glob-scoped-path${TAB}\`find\` is unrestricted but Glob is hook-blocked. Prefer qmd/Grep over \`find\`; scope \`find\` to a known sub-tree." \
  "Bash${TAB}(^|[[:space:]])git[[:space:]]+checkout[[:space:]].*[[:space:]]--[[:space:]]*\\.${TAB}git-checkout-not-a-probe${TAB}\`git checkout {ref} -- .\` is NOT a read-only probe — it overwrites your working tree with that ref's files." \
  "Bash${TAB}(^|[[:space:]])git[[:space:]]+push[[:space:]]${TAB}hq-always-pr-shared-state-repos${TAB}Never push directly to \`main\` on shared-state repos. Open a PR or push a feature branch." \
  "Bash${TAB}(^|[[:space:]])pgrep[[:space:]]${TAB}hq-bash-discipline${TAB}Never hardcode a \`pgrep\`-discovered PID into a follow-up command — re-discover and validate with \`ps\` each invocation." \
  "Bash${TAB}(^|[[:space:]])git[[:space:]]+filter-repo[[:space:]]${TAB}hq-git-discipline${TAB}\`git filter-repo --path\` is case-sensitive. Run separate passes for case variants (e.g. \`Foo\` and \`foo\`)." \
  "Bash${TAB}(^|[[:space:]])git[[:space:]]+reflog[[:space:]]+expire[[:space:]]${TAB}hq-git-discipline${TAB}\`git reflog expire --all --expire=now\` permanently destroys stashes too. Stash explicitly first or filter the expire." \
  "Bash${TAB}IFS=\":\"${TAB}hq-bash-discipline${TAB}\`IFS=\":\" read\` corrupts paths. Use \`IFS=\$'\\''\\\\t'\\''\` or read fields by index instead." \
  "Edit${TAB}companies/[^/]+/settings/${TAB}credential-access-protocol${TAB}Editing inside \`companies/{co}/settings/\` — never read or use credentials from a different company. If unsure, stop and ask." \
  "Write${TAB}companies/[^/]+/settings/${TAB}credential-access-protocol${TAB}Writing inside \`companies/{co}/settings/\` — never read or use credentials from a different company. If unsure, stop and ask." \
  "MultiEdit${TAB}companies/[^/]+/settings/${TAB}credential-access-protocol${TAB}Editing inside \`companies/{co}/settings/\` — never read or use credentials from a different company. If unsure, stop and ask." \
  "Bash${TAB}(^|[[:space:]])(npm|yarn|bun|pnpm)[[:space:]]+(install|i|add)[[:space:]]+[^-]${TAB}hq-pnpm-min-release-age-supply-chain${TAB}Supply-chain guard: prefer \`pnpm\` with \`minimum-release-age=1440\` (24h). Raw \`npm/yarn/bun install <pkg>\` is hard-blocked by block-unsafe-package-install.sh.")

# Per-session dedupe file. Falls back to 'default' if session_id missing.
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
DEDUPE_DIR="$HQ_ROOT/workspace/orchestrator/policy-trigger-state"
mkdir -p "$DEDUPE_DIR" 2>/dev/null || true
DEDUPE_FILE="$DEDUPE_DIR/${SESSION_ID:-default}.txt"
touch "$DEDUPE_FILE" 2>/dev/null || true

# Walk triggers: first match wins. Skip if already injected this session.
matched_slug=""
matched_rule=""
while IFS=$'\t' read -r t_tool t_pat t_slug t_rule; do
  [ -z "$t_tool" ] && continue
  [ "$t_tool" = "$TOOL_NAME" ] || continue
  if printf '%s' "$ARG" | grep -Eq "$t_pat"; then
    if grep -Fxq "$t_slug" "$DEDUPE_FILE" 2>/dev/null; then
      continue
    fi
    matched_slug="$t_slug"
    matched_rule="$t_rule"
    break
  fi
done <<< "$TRIGGERS"

[ -z "$matched_slug" ] && exit 0

# Record + emit
printf '%s\n' "$matched_slug" >> "$DEDUPE_FILE"
printf '<policy-reminder>\n'
printf '> Policy `%s` applies here: %s\n' "$matched_slug" "$matched_rule"
printf '> Read the full rule at `core/policies/%s.md` if you need rationale.\n' "$matched_slug"
printf '</policy-reminder>\n'

exit 0
