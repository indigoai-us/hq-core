#!/usr/bin/env bash
# Return success when a skill contains a path rooted in the HQ checkout that
# is unavailable in the standalone plugin or Codex pack.
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "usage: skill-has-unshipped-hq-path.sh <SKILL.md>" >&2
  exit 2
fi

skill_file=$1

# Match a root-relative core/ or .claude/ path. A slash, dot, or home/repo
# prefix immediately before the path means it belongs to a nested checkout,
# such as libs/core/, $HOME/.claude/, or <repo>/.claude/. Also recognize paths
# explicitly rooted at HQ_ROOT / the HQ root or checkout.
if grep -Eq '(^|[^[:alnum:]_./~$-])(core/|\.claude/)|\./(core/|\.claude/)|\$HQ_ROOT/(core/|\.claude/)|\$\{HQ_ROOT\}/(core/|\.claude/)|(HQ_ROOT|HQ root|HQ checkout)/(core/|\.claude/)' "$skill_file"; then
  exit 0
fi

exit 1
