#!/usr/bin/env bash
# hq-core: public
# A Skill call for a core, pack, personal-overlay or user-level skill is never
# refused because a company skill has the same name. Names that only a company
# outside the session's scope carries, and names addressed to such a company
# (`<slug>:x`, `hq-<slug>:x`, `companies/<slug>:x`), are still refused.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

failures=0
checks=0
last_stderr_file=""

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

skill_md() { # <folder> <frontmatter name>
  mkdir -p "$1"
  printf -- '---\nname: %s\ndescription: fixture\n---\nfixture body\n' "$2" > "$1/SKILL.md"
}

# A mirror as hq lays it out: a real folder whose SKILL.md is a link to the
# source skill's SKILL.md.
link_mirror() { # <mirror folder> <source folder, relative to the HQ root>
  mkdir -p "$1"
  ln -s "../../../$2/SKILL.md" "$1/SKILL.md"
}

# An HQ root shaped like the install the bug was reported on: a company folder
# that holds a whole copy of the core skills under its own .claude/skills, a
# company skill with a copied mirror, and a company named `personal` beside
# the personal overlay.
install_fixture() { # [bound company]
  local bound="${1:-}" hook_source="${SCOPE_HOOK_SOURCE:-$ROOT/.claude/hooks/mandatory-scope-authorizer.sh}"
  chmod -R u+rwx "$TMP" 2>/dev/null
  rm -rf "$TMP/.claude" "$TMP/core" "$TMP/companies" "$TMP/workspace" "$TMP/personal" "$TMP/claude-config"
  mkdir -p "$TMP/.claude/hooks" "$TMP/.claude/skills" "$TMP/core/scripts/lib" \
    "$TMP/workspace/sessions/sess-1" "$TMP/personal/skills" "$TMP/claude-config/skills" \
    "$TMP/companies/otherco/skills" "$TMP/companies/ownco/skills" "$TMP/companies/personal/skills"
  cp "$hook_source" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh"
  cp "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$TMP/.claude/hooks/"
  cp "$ROOT/core/scripts/lib/session-authz.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-id.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
  printf 'companies:\n  otherco:\n    name: otherco\n  ownco:\n    name: ownco\n  personal:\n    name: personal\n' \
    > "$TMP/companies/manifest.yaml"

  # Core skills.
  skill_md "$TMP/.claude/skills/brainstorm" brainstorm
  skill_md "$TMP/.claude/skills/checkpoint" checkpoint
  skill_md "$TMP/.claude/skills/signals" signals
  # A pack skill and a personal-overlay skill, as HQ lays them out.
  skill_md "$TMP/core/packages/hq-pack-engineering/skills/review" review
  link_mirror "$TMP/.claude/skills/hq-pack-engineering:review" core/packages/hq-pack-engineering/skills/review
  skill_md "$TMP/personal/skills/brainstorm" brainstorm
  link_mirror "$TMP/.claude/skills/personal:brainstorm" personal/skills/brainstorm
  # A personal-overlay skill whose mirror is a copy, not links.
  skill_md "$TMP/personal/skills/copied" copied
  skill_md "$TMP/.claude/skills/personal:copied" copied
  # A user-level skill.
  skill_md "$TMP/claude-config/skills/mine" mine

  # otherco: a copy of the core skills under its own .claude/skills, plus
  # company skills with copied mirrors.
  skill_md "$TMP/companies/otherco/.claude/skills/brainstorm" brainstorm
  skill_md "$TMP/companies/otherco/.claude/skills/checkpoint" checkpoint
  skill_md "$TMP/companies/otherco/skills/signals" signals
  link_mirror "$TMP/.claude/skills/otherco:signals" companies/otherco/skills/signals
  skill_md "$TMP/companies/otherco/skills/review" review
  skill_md "$TMP/companies/otherco/skills/mine" mine
  skill_md "$TMP/companies/otherco/skills/anatomy" anatomy
  skill_md "$TMP/.claude/skills/otherco:anatomy" anatomy
  # The company named `personal` has a skill of its own.
  skill_md "$TMP/companies/personal/skills/ledger" ledger
  link_mirror "$TMP/.claude/skills/personal:ledger" companies/personal/skills/ledger

  if [ -n "$bound" ]; then
    printf 'company_slug: %s\n' "$bound" > "$TMP/workspace/sessions/sess-1/meta.yaml"
  fi
}

run_case() { # <label> <tool> <skill name or path or command> <expected exit>
  local label="$1" tool="$2" arg="$3" expected="$4"
  local tool_input payload rc=0 stderr_file
  checks=$((checks + 1))
  stderr_file="$TMP/stderr-$checks"
  last_stderr_file="$stderr_file"
  case "$tool" in
    Skill) tool_input="$(jq -cn --arg v "$arg" '{skill:$v}')" ;;
    Read) tool_input="$(jq -cn --arg v "$arg" '{file_path:$v}')" ;;
    Bash) tool_input="$(jq -cn --arg v "$arg" '{command:$v}')" ;;
    *) fail "$label has unsupported tool $tool"; return ;;
  esac
  payload="$(jq -cn --arg tool "$tool" --arg cwd "$TMP" --argjson input "$tool_input" \
    '{tool_name:$tool,session_id:"sess-1",cwd:$cwd,tool_input:$input}')"
  printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$TMP/claude-config" CLAUDE_PROJECT_DIR="$TMP" \
    bash "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$stderr_file" || rc=$?
  printf '%-64s exit=%s\n' "$label" "$rc"
  if [ "$rc" -ne "$expected" ]; then
    fail "$label expected exit $expected, got $rc: $(head -c 400 "$stderr_file" | tr '\n' ' ')"
  elif [ "$expected" -eq 2 ] && ! grep -q 'Cross-company scope violation' "$stderr_file"; then
    fail "$label was denied without the cross-company message"
  fi
}

assert_stderr() { # <label> <fixed text expected in the last case's stderr>
  checks=$((checks + 1))
  if [ -n "$last_stderr_file" ] && grep -qF -- "$2" "$last_stderr_file"; then
    printf '%-64s ok\n' "$1"
  else
    fail "$1: stderr lacks: $2"
  fi
}

for bound in '' ownco; do
  install_fixture "$bound"
  echo "[bound='${bound:-none}': a core skill loads whatever a company names its skills]"
  run_case 'core brainstorm loads beside a company copy' Skill 'brainstorm' 0
  run_case 'core checkpoint loads beside a company copy' Skill 'checkpoint' 0
  run_case 'core name with a leading slash loads' Skill '/brainstorm' 0
  run_case 'core name with padding loads' Skill ' brainstorm ' 0
  run_case 'core name a mirrored company skill shares loads' Skill 'signals' 0
  echo "[bound='${bound:-none}': pack, personal-overlay and user-level skills load]"
  run_case 'pack skill loads when a company has a skill of that name' Skill 'hq-pack-engineering:review' 0
  run_case 'personal overlay skill loads beside a company named personal' Skill 'personal:brainstorm' 0
  run_case 'personal overlay skill with a copied mirror loads' Skill 'personal:copied' 0
  run_case 'bare name of a personal-only skill loads nothing foreign' Skill 'copied' 0
  run_case 'user-level skill loads when a company has that name' Skill 'mine' 0
  run_case 'personal overlay mirror is readable' Read "$TMP/.claude/skills/personal:brainstorm/SKILL.md" 0
  run_case 'personal overlay mirror is readable with cat' Bash 'cat .claude/skills/personal:brainstorm/SKILL.md' 0
  echo "[bound='${bound:-none}': another company's skills are still refused]"
  run_case 'company-addressed name is refused' Skill 'otherco:signals' 2
  assert_stderr 'refusal names the company' 'Target company: otherco'
  run_case 'company-addressed copy of a core name is refused' Skill 'otherco:brainstorm' 2
  run_case 'hq- company-addressed name is refused' Skill 'hq-otherco:signals' 2
  run_case 'directory-scoped company name is refused' Skill 'companies/otherco:brainstorm' 2
  run_case 'a name only the company carries is refused' Skill 'anatomy' 2
  assert_stderr 'refusal names the company skill' 'otherco:anatomy'
  run_case 'a skill of the company named personal is refused' Skill 'personal:ledger' 2
  run_case 'a mirror of the company named personal is not readable' Read "$TMP/.claude/skills/personal:ledger/SKILL.md" 2
  run_case 'company skill body is not readable' Read "$TMP/companies/otherco/.claude/skills/brainstorm/SKILL.md" 2
  run_case 'company mirror is not readable' Bash 'cat .claude/skills/otherco:signals/SKILL.md' 2
done

# The exemption needs a real skill folder of exactly that name. Anything less
# falls back to the company name rule.
install_fixture ''
echo '[a same-name folder that is not a loadable non-company skill does not exempt]'
rm -rf "$TMP/.claude/skills/brainstorm"
run_case 'no core folder: the company copy name is refused' Skill 'brainstorm' 2
mkdir -p "$TMP/.claude/skills/brainstorm"
run_case 'empty core folder does not exempt' Skill 'brainstorm' 2
mkdir -p "$TMP/.claude/skills/brainstorm/SKILL.md"
run_case 'SKILL.md that is a folder does not exempt' Skill 'brainstorm' 2
rm -rf "$TMP/.claude/skills/brainstorm"
ln -s ../../companies/otherco/.claude/skills/brainstorm "$TMP/.claude/skills/brainstorm"
run_case 'core folder linking to the company skill does not exempt' Skill 'brainstorm' 2
rm -f "$TMP/.claude/skills/brainstorm"
mkdir -p "$TMP/.claude/skills/brainstorm"
ln -s ../../../companies/otherco/.claude/skills/brainstorm/SKILL.md "$TMP/.claude/skills/brainstorm/SKILL.md"
run_case 'SKILL.md linking to the company skill does not exempt' Skill 'brainstorm' 2
rm -rf "$TMP/.claude/skills/brainstorm"
skill_md "$TMP/.claude/skills/Brainstorm" brainstorm
run_case 'case-variant core folder does not exempt' Skill 'brainstorm' 2
rm -rf "$TMP/.claude/skills/Brainstorm"
skill_md "$TMP/.claude/skills/brainstorm" brainstorm
run_case 'upper-case request does not match the core folder' Skill 'BRAINSTORM' 2
# A plugin or pack namespace is compared by its whole name only
# (scope-guard-false-blocks.test.sh), so the part after the colon matching a
# company skill no longer refuses it.
run_case 'pack-prefixed name with no folder of its own loads' Skill 'hq-core:signals' 0
ln -s "$TMP/companies/otherco/skills/anatomy" "$TMP/claude-config/skills/anatomy"
run_case 'user-level link to a company skill does not exempt' Skill 'anatomy' 2
rm -f "$TMP/claude-config/skills/anatomy"
# The personal overlay exemption needs the overlay source folder.
rm -rf "$TMP/personal/skills/brainstorm"
run_case 'personal: name with no overlay source is the company rule' Skill 'personal:brainstorm' 2
# With the source gone the linked SKILL.md dangles; a copied one is checked.
rm -f "$TMP/.claude/skills/personal:brainstorm/SKILL.md"
printf 'copied body\n' > "$TMP/.claude/skills/personal:brainstorm/SKILL.md"
run_case 'personal: copied mirror with no overlay source is refused' Skill 'personal:brainstorm' 2
run_case 'personal: mirror with no overlay source is not readable' Read "$TMP/.claude/skills/personal:brainstorm/SKILL.md" 2
ln -s ../../companies/personal/skills/ledger "$TMP/personal/skills/ledger"
run_case 'overlay source linking into the company does not exempt' Skill 'personal:ledger' 2

# personal/ is writable without a bind, so an overlay folder alone must not
# unlock a skill of the company named personal (reviews of this change,
# critical 1 in both passes). The mirror's own SKILL.md has to be the
# overlay's: a link to it, or a byte-identical copy.
install_fixture ''
echo '[personal: an overlay folder does not unlock the company named personal]'
mkdir -p "$TMP/personal/skills/ledger" "$TMP/claude-config/skills/hq-personal:ledger"
printf 'stub planted in the overlay\n' > "$TMP/personal/skills/ledger/SKILL.md"
cp "$TMP/companies/personal/skills/ledger/SKILL.md" "$TMP/claude-config/skills/hq-personal:ledger/SKILL.md"
run_case 'stub overlay does not unlock a linked company mirror' Skill 'personal:ledger' 2
run_case 'stub overlay does not unlock the hq- spelling' Skill 'hq-personal:ledger' 2
run_case 'stub overlay does not make the mirror readable' Read "$TMP/.claude/skills/personal:ledger/SKILL.md" 2
run_case 'stub overlay does not make the mirror readable with cat' Bash 'cat .claude/skills/personal:ledger/SKILL.md' 2
run_case 'stub overlay does not make the user-level copy readable' Read "$TMP/claude-config/skills/hq-personal:ledger/SKILL.md" 2
# A stale mirror: the company skill was renamed, its copied mirror stayed.
rm -f "$TMP/.claude/skills/personal:ledger/SKILL.md"
printf -- '---\nname: ledger\n---\ncompany body\n' > "$TMP/.claude/skills/personal:ledger/SKILL.md"
mv "$TMP/companies/personal/skills/ledger" "$TMP/companies/personal/skills/books"
run_case 'stub overlay does not unlock a stale copied company mirror' Skill 'personal:ledger' 2
run_case 'stale copied company mirror stays unreadable' Read "$TMP/.claude/skills/personal:ledger/SKILL.md" 2
rm -rf "$TMP/companies/personal/skills/books"
run_case 'stub overlay does not unlock a mirror whose source is gone' Skill 'personal:ledger' 2
# The same name on both sides.
skill_md "$TMP/companies/personal/.claude/skills/brainstorm" brainstorm
run_case 'same name on both sides: a mirror linked to the overlay loads' Skill 'personal:brainstorm' 0
run_case 'same name on both sides: that mirror is readable' Read "$TMP/.claude/skills/personal:brainstorm/SKILL.md" 0
rm -f "$TMP/.claude/skills/personal:brainstorm/SKILL.md"
ln -s ../../../companies/personal/.claude/skills/brainstorm/SKILL.md "$TMP/.claude/skills/personal:brainstorm/SKILL.md"
run_case 'same name on both sides: a mirror linked to the company is refused' Skill 'personal:brainstorm' 2
run_case 'same name on both sides: that mirror is not readable' Read "$TMP/.claude/skills/personal:brainstorm/SKILL.md" 2
rm -f "$TMP/.claude/skills/personal:brainstorm/SKILL.md"
cp "$TMP/personal/skills/brainstorm/SKILL.md" "$TMP/.claude/skills/personal:brainstorm/SKILL.md"
run_case 'same name on both sides: an identical copied mirror loads' Skill 'personal:brainstorm' 0
printf 'company body\n' > "$TMP/.claude/skills/personal:brainstorm/SKILL.md"
run_case 'same name on both sides: a differing copied mirror is refused' Skill 'personal:brainstorm' 2
run_case 'same name on both sides: a differing copied mirror is not readable' Read "$TMP/.claude/skills/personal:brainstorm/SKILL.md" 2
run_case 'hq-personal: spelling is never the overlay' Skill 'hq-personal:brainstorm' 2
# A user-level `personal:<name>` entry is checked on its own content.
install_fixture ''
skill_md "$TMP/companies/personal/skills/copied" copied
mkdir -p "$TMP/claude-config/skills/personal:copied"
printf 'company body\n' > "$TMP/claude-config/skills/personal:copied/SKILL.md"
run_case 'user-level personal: company copy is not readable' Read "$TMP/claude-config/skills/personal:copied/SKILL.md" 2
run_case 'user-level personal: company copy blocks the name' Skill 'personal:copied' 2
rm -rf "$TMP/claude-config/skills/personal:copied"
run_case 'without that user-level entry the overlay skill loads' Skill 'personal:copied' 0

# A user-level `personal:<name>` entry that is not the overlay's blocks the
# name even when no company skill carries it, and a folder called skills
# elsewhere in the HQ root gets no overlay treatment (third review pass).
install_fixture ''
mkdir -p "$TMP/claude-config/skills/personal:brainstorm" "$TMP/skills/personal:brainstorm"
printf 'company body\n' > "$TMP/claude-config/skills/personal:brainstorm/SKILL.md"
printf 'company body\n' > "$TMP/skills/personal:brainstorm/SKILL.md"
rm -rf "$TMP/companies/otherco/.claude/skills/brainstorm"
run_case 'user-level personal: copy blocks a name no company carries' Skill 'personal:brainstorm' 2
run_case 'top-level skills folder gets no overlay treatment' Read "$TMP/skills/personal:brainstorm/SKILL.md" 2
run_case 'top-level skills folder gets no overlay treatment with cat' Bash 'cat skills/personal:brainstorm/SKILL.md' 2

# The overlay check runs once per `personal:` mirror on every Skill call that
# reaches the name rule, so for linked mirrors it must start no process
# (third review pass, major 1: 150 mirrors took about 3 seconds).
install_fixture ''
echo '[linked personal mirrors are checked without starting a process]'
i=0
while [ "$i" -lt 150 ]; do
  skill_md "$TMP/personal/skills/many-$i" "many-$i"
  link_mirror "$TMP/.claude/skills/personal:many-$i" "personal/skills/many-$i"
  i=$((i + 1))
done
mkdir -p "$TMP/count-bin"
for tool in readlink cmp; do
  real="$(command -v "$tool")"
  printf '#!/bin/sh\necho %s >> "%s/spawn-count"\nexec "%s" "$@"\n' "$tool" "$TMP" "$real" > "$TMP/count-bin/$tool"
  chmod +x "$TMP/count-bin/$tool"
done
: > "$TMP/spawn-count"
PATH="$TMP/count-bin:$PATH" run_case 'unknown name passes the name rule beside 150 mirrors' Skill 'no-such-skill' 0
PATH="$TMP/count-bin:$PATH" run_case 'company name is refused beside 150 mirrors' Skill 'anatomy' 2
checks=$((checks + 1))
spawned="$(wc -l < "$TMP/spawn-count" | tr -d ' ')"
if [ "$spawned" -le 4 ]; then
  printf '%-64s ok (%s)\n' 'readlink and cmp runs for two Skill calls' "$spawned"
else
  fail "the name rule started readlink or cmp $spawned times for two Skill calls beside 150 linked personal mirrors"
fi

# Pack skills: the linked SKILL.md has to resolve inside the HQ root and
# outside companies/.
install_fixture ''
echo '[pack skills: where the linked SKILL.md resolves decides]'
run_case 'pack skill linked into core loads' Skill 'hq-pack-engineering:review' 0
rm -f "$TMP/.claude/skills/hq-pack-engineering:review/SKILL.md"
ln -s ../../../companies/otherco/skills/review/SKILL.md "$TMP/.claude/skills/hq-pack-engineering:review/SKILL.md"
run_case 'pack-named folder linked into a company is refused' Skill 'hq-pack-engineering:review' 2
rm -f "$TMP/.claude/skills/hq-pack-engineering:review/SKILL.md"
ln -s ../otherco:signals/SKILL.md "$TMP/.claude/skills/hq-pack-engineering:review/SKILL.md"
run_case 'pack-named folder linked to a company mirror is refused' Skill 'hq-pack-engineering:review' 2
rm -f "$TMP/.claude/skills/hq-pack-engineering:review/SKILL.md"
printf 'outside\n' > "$TMP/../outside-skill-$$.md"
ln -s "$TMP/../outside-skill-$$.md" "$TMP/.claude/skills/hq-pack-engineering:review/SKILL.md"
# A link out of the HQ root or to nothing is not a company file, and the pack
# namespace is compared by its whole name, so these load (nothing of a
# company can be read through them).
run_case 'pack-named folder linked outside the HQ root loads' Skill 'hq-pack-engineering:review' 0
rm -f "$TMP/../outside-skill-$$.md"
rm -f "$TMP/.claude/skills/hq-pack-engineering:review/SKILL.md"
ln -s nowhere.md "$TMP/.claude/skills/hq-pack-engineering:review/SKILL.md"
run_case 'pack-named folder with a dangling link loads' Skill 'hq-pack-engineering:review' 0

# A user-level entry of the same name can be the one Claude Code loads, so it
# has to be a real skill folder too (review of this change, major 2).
install_fixture ''
echo '[an entry of the same name in the other skills folder must also be real]'
skill_md "$TMP/.claude/skills/anatomy" anatomy
run_case 'real core folder loads with no user-level entry' Skill 'anatomy' 0
ln -s "$TMP/companies/otherco/skills/anatomy" "$TMP/claude-config/skills/anatomy"
run_case 'user-level link to a company skill beside a core folder' Skill 'anatomy' 2
rm -f "$TMP/claude-config/skills/anatomy"
mkdir -p "$TMP/claude-config/skills/anatomy"
run_case 'empty user-level folder beside a core folder' Skill 'anatomy' 2
rm -rf "$TMP/claude-config/skills"
mkdir -p "$TMP/elsewhere"
ln -s "$TMP/companies/otherco/skills/anatomy" "$TMP/elsewhere/anatomy"
ln -s "$TMP/elsewhere" "$TMP/claude-config/skills"
run_case 'user-level skills folder that is a link holding the name' Skill 'anatomy' 2
rm -f "$TMP/claude-config/skills"
mkdir -p "$TMP/claude-config/skills"
skill_md "$TMP/claude-config/skills/anatomy" anatomy
run_case 'real folders in both skills folders load' Skill 'anatomy' 0

# The exemption follows the folder name, as Claude Code does: a company
# mirror whose frontmatter name equals a core folder name is not what a call
# for that name loads. A linked .claude/skills gets no exemption.
install_fixture ''
echo '[folder name decides; a linked skills folder keeps the name rule]'
skill_md "$TMP/.claude/skills/otherco:zeta" brainstorm
run_case 'core folder loads beside a mirror with that frontmatter name' Skill 'brainstorm' 0
run_case 'that mirror is still refused by its own name' Skill 'otherco:zeta' 2
run_case 'that mirror is still not readable' Read "$TMP/.claude/skills/otherco:zeta/SKILL.md" 2
mv "$TMP/.claude/skills" "$TMP/.claude/skills-real"
ln -s skills-real "$TMP/.claude/skills"
run_case 'linked .claude/skills keeps the name rule' Skill 'brainstorm' 2

install_fixture 'otherco'
echo '[bound to the company: its own skills and the core skills load]'
run_case 'bound company loads the core name' Skill 'brainstorm' 0
run_case 'bound company loads its own skill' Skill 'otherco:signals' 0
run_case 'bound company loads its bare name' Skill 'anatomy' 0

echo "Checks: $checks; failures: $failures"
[ "$failures" -eq 0 ]
