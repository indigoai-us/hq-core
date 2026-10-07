#!/usr/bin/env bash
# hq-core: public
# Exercise the exact Bash examples shipped in resumework against the scope guard.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts/lib" \
  "$TMP/companies/indigo/settings" "$TMP/companies/otherco/settings" "$TMP/companies/_template" \
  "$TMP/personal" "$TMP/workspace/sessions/sess-bound" "$TMP/workspace/threads"
printf 'fixture\n' > "$TMP/companies/otherco/x"
ln -s "$TMP/companies/otherco" "$TMP/workspace/link"
ln -s "$TMP/companies/otherco" "$TMP/workspace/parent"
AUTHORIZER_SOURCE="${AUTHORIZER_SOURCE:-$ROOT/.claude/hooks/mandatory-scope-authorizer.sh}"
cp "$AUTHORIZER_SOURCE" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh"
cp "$ROOT/core/scripts/lib/session-authz.sh" "$ROOT/core/scripts/lib/session-scope-capability.sh" \
  "$ROOT/core/scripts/lib/session-id.sh" "$TMP/core/scripts/lib/"
cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
printf 'companies:\n  indigo:\n    name: Indigo\n' > "$TMP/companies/manifest.yaml"
printf 'sess-bound\n' > "$TMP/workspace/sessions/.current"
printf 'company_slug: indigo\n' > "$TMP/workspace/sessions/sess-bound/meta.yaml"
. "$ROOT/core/scripts/lib/session-scope-capability.sh"
session_scope_mint "$TMP" sess-bound indigo
chmod +x "$TMP/.claude/hooks/mandatory-scope-authorizer.sh"

python3 - "$ROOT/.claude/skills/resumework/SKILL.md" "$TMP" <<'PY'
import json
import os
import pathlib
import re
import subprocess
import sys

skill_path = pathlib.Path(sys.argv[1])
root = sys.argv[2]
text = skill_path.read_text()
blocks = [block for _, block in re.findall(r"(?m)^([ \t]*)```bash[ \t]*\n(.*?)^\1```[ \t]*$", text, re.DOTALL)]
if not blocks:
    raise SystemExit("FAIL: no bash blocks found in resumework skill")
replacements = {
    "$ARGUMENTS": "T-20261007-091000-resumework-scope-regression",
    "{thread_id}": "T-20261007-091000-resumework-scope-regression",
    "{co}": "indigo",
    "{repoPath}": "/home/ec2-user/hq/repos/private/hq-core-staging",
    "{session_id}": "sess-bound",
    "{lock_generation from inspected JSON}": "1",
}
hook = pathlib.Path(root) / ".claude/hooks/mandatory-scope-authorizer.sh"

def invoke(command):
    payload = json.dumps({
        "tool_name": "Bash",
        "session_id": "sess-bound",
        "cwd": root,
        "tool_input": {"command": command},
    })
    env = {**os.environ, "HQ_ROOT": root, "CLAUDE_PROJECT_DIR": str(skill_path.parents[3])}
    result = subprocess.run(["bash", str(hook)], input=payload, text=True, capture_output=True, env=env)
    control_payload = json.dumps({
        "tool_name": "Bash",
        "session_id": "sess-bound",
        "cwd": root,
        "tool_input": {"command": "cat companies/otherco/x"},
    })
    control = subprocess.run(["bash", str(hook)], input=control_payload, text=True, capture_output=True, env=env)
    if control.returncode != 2:
        raise SystemExit(f"FAIL: real-HQ-root blocking control expected exit 2, got {control.returncode}")
    return result

for index, original in enumerate(blocks, 1):
    command = original
    for source, value in replacements.items():
        command = command.replace(source, value)
    # Replace any remaining prose placeholders with safe, realistic examples.
    command = re.sub(r"\{[A-Za-z0-9_ -]+\}", "T-20261007-091000-resumework-scope-regression", command)
    result = invoke(command)
    if result.returncode != 0:
        print(f"FAIL: resumework bash block [{index}] denied (exit {result.returncode})", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        raise SystemExit(1)
    print(f"PASS: resumework bash block [{index}] allowed")
print(f"PASS: all {len(blocks)} resumework bash blocks allowed")

allowed_roots = ["workspace", "core", "personal", "repos"]
for path in allowed_roots:
    command = f"path=note.txt; cat {path}/$path"
    result = invoke(command)
    if result.returncode != 0:
        print(f"FAIL: allowed HQ root {path} denied (exit {result.returncode})", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        raise SystemExit(1)
    print(f"PASS: literal value under {path} stays allowed")

traversal_controls = [
    ("assigned traversal from workspace", 'id="../../companies/otherco"; cat "workspace/threads/' + chr(36) + '{id}/x"'),
    ("assigned workspace path with parent segment", 'p="workspace/../companies/otherco/x"; cat "$p"'),
    ("positional traversal out of workspace", 'cat "workspace/threads/$1/../../../companies/otherco/x"'),
    ("absolute assigned path under workspace", 'id="/home/ec2-user/hq/companies/otherco/x"; cat "workspace/' + chr(36) + '{id}"'),
    ("absolute HQ_ROOT path assignment", 'p="' + chr(36) + 'HQ_ROOT/companies/otherco/x"; cat "$p"'),
    ("expanded workspace symlink into another company", 'l=link; cat "workspace/' + chr(36) + '{l}/x"'),
    ("parent symlink outside workspace is denied without an existing leaf", 'l=missing; cat "workspace/parent/$l"'),
    ("single-quoted assignment cannot hide workspace symlink", "l='link'; cat \"workspace/${l}/x\""),
    ("command substitution cannot hide workspace symlink", 'l=$(echo link); cat "workspace/${l}/x"'),
    ("read variable cannot hide workspace symlink", 'read l; cat "workspace/$l/x"'),
    ("unset variable cannot hide workspace symlink", 'cat "workspace/$UNSET_V/x"'),
    ("loop value cannot hide workspace symlink", 'for l in link; do cat "workspace/$l/x"; done'),
    ("assignment chain cannot hide workspace symlink", 'a=link; l=$a; cat "workspace/$l/x"'),
    ("export cannot hide workspace symlink", 'export l=link; cat "workspace/$l/x"'),
    ("redirect cannot write through workspace symlink", 'l=link; echo hi > "workspace/$l/x"'),
    ("expanded foreign company after workspace parent", 'd="otherco"; cat "workspace/../companies/' + chr(36) + '{d}/x"'),
]
traversal_failures = []
for label, command in traversal_controls:
    result = invoke(command)
    if result.returncode != 2:
        traversal_failures.append(label)
        print(f"FAIL: {label} expected exit 2, got {result.returncode}")
        if result.stderr:
            print(result.stderr, file=sys.stderr)
    else:
        print(f"PASS: {label} remains blocked")
if traversal_failures:
    raise SystemExit("FAIL: traversal controls escaped: " + ", ".join(traversal_failures))

controls = [
    ("literal cross-company read", "cat companies/otherco/x"),
    ("assigned cross-company read", 'f=companies/otherco/x; cat "$f"'),
    ("assigned cross-company write", 'out=companies/otherco/x; echo hi > $out'),
    ("environment assignment to foreign path", "F=companies/otherco/x cmd"),
    ("nested shell foreign path", 'X=companies/otherco/secret.yaml bash -c "cat \\$X"'),
]
for label, command in controls:
    result = invoke(command)
    if result.returncode != 2:
        print(f"FAIL: {label} expected exit 2, got {result.returncode}", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        raise SystemExit(1)
    print(f"PASS: {label} remains blocked")
PY
