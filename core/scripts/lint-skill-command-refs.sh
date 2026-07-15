#!/usr/bin/env bash
# lint-skill-command-refs.sh — fail if release-shipped guidance instructs a
# slash-command that is not resolvable on the install it is shown to.
#
# WHY (DEV-1716): hq-core ships a lean scaffold. The engineering commands
# (/run-project, /execute-task, /prd, /diagnose, ...) were extracted into the
# separately-installed hq-pack-engineering in 15.0.0 (core/docs/hq/CHANGELOG.md).
# They are auto-installed for upgraders but deliberately NOT for greenfield
# installs. A core skill that prints "run /run-project" as a next step therefore
# strands any pack-less user — the documented dead-end the reporter hit after
# /plan. This lint asserts every command a core skill presents as runnable is
# either (a) a shipped core skill or (b) explicitly allowlisted in
# core/scripts/skill-command-refs.allow. It catches FUTURE dangling references,
# not just the originally-reported skills.
#
# Detection is deliberately low-false-positive: a "command reference" is the
# FIRST token of a fenced-code-block line or of a `backtick span`, matching
# ^/[a-z][a-z0-9-]*. In release policies, namespaced targets and `/invite`
# receive the same validation; hook-injected text is checked for commands named
# after a routing verb.
# Path/URL/route fragments (/api/.., /tmp/.., /sts/vend, /share-session/<t>)
# are excluded. Namespaced targets are resolved against the shipped target skill
# (for example, /indigo:signals resolves to the shipped signals skill).
#
# Exit codes: 0 = clean, 1 = dangling reference(s) found, 2 = script error.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

skills_dir=".claude/skills"
allow_file="core/scripts/skill-command-refs.allow"

if [[ ! -d "$skills_dir" ]]; then
  echo "lint-skill-command-refs: no $skills_dir (nothing to check)"
  exit 0
fi

resolvable_file="$(mktemp)"
trap 'rm -f "$resolvable_file"' EXIT

# Resolvable set = shipped core skills (bare dir names, skipping _shared etc.)
# ∪ allowlisted tokens.
{
  for d in "$skills_dir"/*/; do
    bn="$(basename "$d")"
    [[ "$bn" == _* ]] && continue
    echo "$bn"
  done
  if [[ -f "$allow_file" ]]; then
    sed -E 's/#.*$//' "$allow_file" | tr -d '[:blank:]' | grep -E '^[a-z][a-z0-9-]*$' || true
  fi
} | sort -u > "$resolvable_file"

set +e
python3 - "$skills_dir" "core/policies" ".claude/hooks" "$resolvable_file" <<'PY'
import re, sys, glob, os

skills_dir, policies_dir, hooks_dir, resolvable_file = sys.argv[1:]
resolvable = set(open(resolvable_file).read().split())

# First token of a line/span: a slash-command, not a path/route fragment.
cmd = re.compile(r'^/([a-z][a-z0-9-]*(?::[a-z][a-z0-9-]*)?)(?![a-z0-9/:-])')
hook_cmd = re.compile(r'\b(?:run|running|invoke|execute)\s+`?/([a-z][a-z0-9-]*(?::[a-z][a-z0-9-]*)?)(?![a-z0-9/:-])')
backtick = re.compile(r'`([^`]+)`')
hq_invite = re.compile(r'(?<![a-z0-9_-])hq\s+invite(?:\s|$)')

# These commands are supplied by their named integrations rather than hq-core.
# Other namespaced targets must resolve to a shipped skill.
external_namespaced = {'indigo:action-items', 'personal:worktree'}

bad = []
files = sorted(glob.glob(os.path.join(skills_dir, '*', 'SKILL.md')))
files += sorted(glob.glob(os.path.join(policies_dir, '**', '*.md'), recursive=True))
files += sorted(glob.glob(os.path.join(hooks_dir, '*.sh')))

def slack_native_invite(f, line, command):
    return (
        command == 'invite'
        and os.path.normpath(f) == os.path.normpath('core/policies/hq-slack.md')
        and re.search(r'/invite\s+@[a-z0-9_-]+', line, re.I)
    )

def resolvable_command(command):
    if command in external_namespaced:
        return True
    return command.rsplit(':', 1)[-1] in resolvable

for f in files:
    is_hook = os.path.normpath(f).startswith(os.path.normpath(hooks_dir) + os.sep)
    is_policy = os.path.normpath(f).startswith(os.path.normpath(policies_dir) + os.sep)
    in_fence = False
    for i, line in enumerate(open(f, errors='ignore'), 1):
        s = line.rstrip('\n')
        if hq_invite.search(s):
            bad.append((f, i, 'hq invite'))

        if is_hook:
            if 'additionalContext' in s:
                cands = [m.group(1) for m in hook_cmd.finditer(s)]
                for c in cands:
                    if not resolvable_command(c):
                        bad.append((f, i, c))
            continue

        if s.lstrip().startswith('```'):
            in_fence = not in_fence
            continue
        cands = []
        if in_fence:
            m = cmd.match(s.strip())
            if m:
                cands.append(m.group(1))
        for span in backtick.findall(s):
            m = cmd.match(span.strip())
            if m:
                cands.append(m.group(1))
        for c in cands:
            if is_policy and ':' not in c and c != 'invite' and '⚠' not in s:
                continue
            if slack_native_invite(f, s, c):
                continue
            if not resolvable_command(c):
                bad.append((f, i, c))

if bad:
    print("FAIL: dangling release-guidance command reference(s) — these commands are neither")
    print("a shipped core skill nor allowlisted in core/scripts/skill-command-refs.allow:")
    print()
    for f, i, c in bad:
        print(f"  {f}:{i}  ->  {c if c == 'hq invite' else '/' + c}")
    print()
    print("Fix one of:")
    print("  • change the skill to instruct a command that ships in core; or")
    print("  • if /<cmd> comes from an installable pack, reference it WITH the")
    print("    pack's install line and add /<cmd> to skill-command-refs.allow; or")
    print("  • if it is a genuine non-command (API route/placeholder), add it to")
    print("    the 'Not commands' section of skill-command-refs.allow.")
    sys.exit(1)

print(f"OK: every command referenced by release guidance resolves "
      f"({len(resolvable)} resolvable names).")
PY
rc=$?
set -e
exit "$rc"
