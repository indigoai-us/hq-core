#!/usr/bin/env bash
# Regression: the /team-access skill must carry the access-heal contract that
# matches how the vault resolves member access (hq-pro-core acl-permission:
# most-specific row wins, a bare `<root>` row outranks `<root>/*`, an empty
# winning row locks members out).
#
# Guards:
#   1. Frontmatter: name, description, AskUserQuestion in allowed-tools, and a
#      chat fallback for hosts without it (Codex).
#   2. Step 2 reads the legacy bare `<root>` row as well as `<root>/` and
#      `<root>/*`, and names the winning-row order.
#   3. Whole-folder grants also write `@all` on an existing bare row; the skill
#      never unshares from, or creates, a bare row.
#   4. Before a new row is written, the grants it would hide (inherited from
#      `*`) are listed and the owner is asked; app grants are called out.
#   5. ACL_PATTERN_CONFLICT (DEV-3405) stops the folder and routes the owner to
#      Indigo support; no workaround commands.
#   6. Readback judges `.direct` on the winning row and rejects
#      `effectivePermission` as proof.
#   7. Subfolder rows below a granted root are listed (`.children`), empty ones
#      are probed per direct subfolder, and the CLI limitation is named.
#   8. Multi-company loop: owner-only, one company per question.
#   9. The Codex copy under .agents/skills resolves to the same file.
#  10. Every jq program in the skill parses and behaves as described on
#      fixture JSON shaped like `hq files acl --json` output.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/team-access/SKILL.md"
CODEX="$ROOT/.agents/skills/team-access/SKILL.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -qF -- "$1" "$SKILL" || fail "$2"; }

[ -f "$SKILL" ] || fail "missing team-access skill: $SKILL"

# 1. frontmatter + question flow
grep -q '^name: team-access$' "$SKILL" || fail "frontmatter must declare name: team-access"
grep -q '^description: ' "$SKILL" || fail "frontmatter must carry a description"
grep -q '^allowed-tools: .*AskUserQuestion' "$SKILL" || fail "allowed-tools must include AskUserQuestion"
grep -q '^allowed-tools: .*Bash(awk:\*)' "$SKILL" || fail "allowed-tools must include awk for the role lookup"
has 'Ask one question at a time with `AskUserQuestion`' "one-question flow must remain"
has 'any host without `AskUserQuestion`' "chat fallback for Codex must be stated"

# 2. bare row read + winning order
has 'hq files acl "$root"   --company "$slug" --json' "step 2 must read the bare <root> row"
has 'hq files acl "$root/"  --company "$slug" --json' "step 2 must read the <root>/ private-folder row"
has 'hq files acl "$root/*" --company "$slug" --json' "step 2 must read the <root>/* row"
has 'outranks `knowledge/*`' "skill must state that a bare row outranks <root>/*"
has 'bare `$root` exists → the bare row wins' "winning-row order must start with the bare row"

# 3. bare-row grant and never-unshare
has 'hq files share "$root"   --with @all --permission write --company "$slug"   # only when the bare row exists' \
  "whole-folder grant must also write @all on an existing bare row"
has 'never run `hq files unshare`' "skill must forbid unsharing from a bare row"
has 'Never unshare from a bare `{root}` row' "rules must forbid unsharing from a bare row"
has 'Never create a bare row that does not already exist' "skill must not create bare rows"
if grep -nE '^hq files unshare "\$root"( |$)' "$SKILL"; then
  fail "skill must not contain an unshare command on the bare row"
fi

has '**Narrowing is blocked when a bare `$root` row carries the team grant.**' \
  "narrowing over a granted bare row must be blocked, not reported as done"
has 'hq files share "$root"   --with "$principal" --permission write --company "$slug"   # only when the bare row exists' \
  "group whole-folder grants must also cover an existing bare row"
has 'the same principal the owner chose' "winning-row readback must check the chosen principal"
has 'Never add `@all` just to' "readback must not widen access to pass"
has 'A bare row on the folder' "bare-row handling must cover chosen subfolders"
has 'For every `{folder}/*` grant' "winning-row readback must cover subfolder grants"
# Every share/unshare the skill tells the agent to run must be company-scoped.
if grep -nE '(^|`)hq files (share|unshare) ' "$SKILL" | grep -v -- '--company "\$slug"' | grep -v -- '--full'; then
  fail "every hq files share/unshare command must pass --company \"\$slug\""
fi

# 4. hidden '*' grants
has '### 3b. Grants a new row would hide' "step 3b must exist"
has 'Keep them** (recommended)' "step 3b must offer to copy hidden grants"
has 'It cannot write an' "step 3b must state app grants cannot be copied"

# 5. DEV-3405
has 'ACL_PATTERN_CONFLICT' "skill must name ACL_PATTERN_CONFLICT"
has 'DEV-3405' "skill must name DEV-3405"
has 'Please contact' "skill must route the owner to Indigo support"
has 'mention DEV-3405' "support message must name DEV-3405"
has 'Do not remove the `$root/` row' "skill must forbid removing the private-folder row"
if grep -nE '^hq files unshare "\$root/"' "$SKILL"; then
  fail "skill must not contain an unshare command on the <root>/ row"
fi

# 6. readback
has "'.exists and any(.direct[]?;" "readback must check .direct on the exact row"
has 'Never use `effectivePermission` as proof' "readback must reject effectivePermission"
has 'A `{folder}/*` readback' "readback must check the winning bare row"

# 7. subfolders
has '### 4b. Locked subfolders under a granted root' "step 4b must exist"
has 'hq files acl "$root/$sub/*" --company "$slug" --json' "step 4b must probe direct subfolders"
has '**Limitation:** no `hq files` command lists rows that have no entries' "step 4b must name the CLI limitation"
has 'These were shared on purpose. Do not change them.' "rows with grants must stay unchanged"

# 8. multi-company
has '## Several companies in one run' "multi-company section must exist"
has 'and your role is' "multi-company loop must be owner-only"
has 'Never mix companies' "multi-company loop must keep companies separate"

# 9. Codex copy
[ -f "$CODEX" ] || fail "missing Codex copy: $CODEX"
cmp -s "$SKILL" "$CODEX" || fail "Codex copy differs from .claude/skills/team-access/SKILL.md"

# 10. jq programs on fixtures
command -v jq >/dev/null || { echo "SKIP jq checks: jq not installed"; echo "PASS team-access-skill"; exit 0; }

readback='.exists and any(.direct[]?; (.granteeId==$p or ($p=="@all" and .granteeType=="company-wide")) and .permission==$perm)'
hidden='if .exists then .prefix as $from | [.direct[] | select(.granteeType != "company-wide") | {granteeType, granteeId, permission, from: $from}] else [] end'
children='.children | group_by(.sourcePrefix) | map({path: .[0].sourcePrefix, team: ([.[] | select(.granteeType == "company-wide") | .permission] | first), grants: length})'

# The programs above must be the ones the skill ships (whitespace-normalised).
norm() { tr -s ' \n' ' ' <"$SKILL"; }
norm | grep -qF "$(printf '%s' "$hidden" | tr -s ' \n' ' ')" || fail "hidden-grant jq drifted from the test copy"
norm | grep -qF "$(printf '%s' "$children" | tr -s ' \n' ' ')" || fail "children jq drifted from the test copy"
norm | grep -qF "$(printf '%s' "$readback" | tr -s ' \n' ' ')" || fail "readback jq drifted from the test copy"

# Readback: an owner's admin effectivePermission on an empty row must NOT pass.
empty_row='{"prefix":"knowledge","exists":true,"direct":[],"inherited":[],"children":[],"effectivePermission":"admin"}'
if printf '%s' "$empty_row" | jq -e --arg p "@all" --arg perm write "$readback" >/dev/null; then
  fail "readback passed on an empty row with admin effectivePermission"
fi
granted='{"prefix":"knowledge","exists":true,"direct":[{"granteeType":"company-wide","granteeId":"","permission":"write"}],"inherited":[],"children":[],"effectivePermission":null}'
printf '%s' "$granted" | jq -e --arg p "@all" --arg perm write "$readback" >/dev/null \
  || fail "readback must pass when .direct carries company-wide write"
absent='{"prefix":"knowledge/*","exists":false,"direct":[],"inherited":[{"granteeType":"company-wide","granteeId":"","permission":"write","sourcePrefix":"*"}],"children":[]}'
if printf '%s' "$absent" | jq -e --arg p "@all" --arg perm write "$readback" >/dev/null; then
  fail "readback must not count an inherited '*' entry as the row's own grant"
fi

# Hidden grants come from the governing row's own .direct entries, company-wide excluded.
star='{"prefix":"*","exists":true,"direct":[
  {"granteeType":"app","granteeId":"app_x","permission":"write"},
  {"granteeType":"email","granteeId":"a@example.com","permission":"read"},
  {"granteeType":"company-wide","granteeId":"","permission":"read"}]}'
got="$(printf '%s' "$star" | jq -c "$hidden")"
[ "$got" = '[{"granteeType":"app","granteeId":"app_x","permission":"write","from":"*"},{"granteeType":"email","granteeId":"a@example.com","permission":"read","from":"*"}]' ] \
  || fail "hidden-grant jq must list non-company-wide entries of the governing row: $got"
# An empty governing row (auto-lock) blocks '*' today, so nothing may be copied from '*'
# even though '*' entries appear in its .inherited.
empty_glob='{"prefix":"knowledge/*","exists":true,"direct":[],"inherited":[
  {"granteeType":"email","granteeId":"x@example.com","permission":"write","sourcePrefix":"*"}]}'
got="$(printf '%s' "$empty_glob" | jq -c "$hidden")"
[ "$got" = '[]' ] || fail "an empty governing row must yield no grants to copy: $got"
got="$(printf '%s' '{"prefix":"knowledge","exists":false,"direct":[],"inherited":[]}' | jq -c "$hidden")"
[ "$got" = '[]' ] || fail "a missing row must yield no grants: $got"
has 'an empty row still governs' "3b must pick the governing row by existence, not entries"
has 'Do not read these entries from `.inherited` of the new path' \
  "3b must forbid copying from .inherited"

# Children: grouped per row, team permission surfaced, null when the team is left out.
kids='{"children":[
  {"granteeType":"person","granteeId":"prs_a","permission":"write","sourcePrefix":"projects/a/*"},
  {"granteeType":"email","granteeId":"b@example.com","permission":"read","sourcePrefix":"projects/a/*"},
  {"granteeType":"company-wide","granteeId":"","permission":"read","sourcePrefix":"projects/b/*"}]}'
got="$(printf '%s' "$kids" | jq -c "$children")"
[ "$got" = '[{"path":"projects/a/*","team":null,"grants":2},{"path":"projects/b/*","team":"read","grants":1}]' ] \
  || fail "children jq output wrong: $got"

echo "PASS team-access-skill"
