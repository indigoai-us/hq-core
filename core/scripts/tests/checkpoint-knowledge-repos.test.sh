#!/usr/bin/env bash
# Regression for feedback 5ad007c4: the checkpoint knowledge-repo scan failed
# with "shopt: command not found" when an agent ran it from zsh. The scan now
# lives in a bash script; it must work when launched from zsh and from
# /bin/bash, and the skill must not ask an agent to type bash-only syntax.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SCRIPT="$REPO/core/scripts/checkpoint-knowledge-repos.sh"
SKILL="$REPO/.claude/skills/checkpoint/SKILL.md"
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/hq"
mkdir -p "$root/personal/knowledge/notes" "$root/personal/knowledge/clean" "$root/companies/acme/knowledge" "$root/core/knowledge/public"
for k in notes clean; do
  git -C "$root/personal/knowledge/$k" init -q
  git -C "$root/personal/knowledge/$k" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
done
echo dirty > "$root/personal/knowledge/notes/new.md"
mkdir -p "$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$root/personal/knowledge/linked"

check_output() {
  local label="$1" out="$2"
  if grep -q '^personal/knowledge/notes: [0-9a-f]* (dirty)$' <<<"$out"; then ok "$label reports the dirty repo"; else bad "$label missed the dirty repo: $out"; fi
  if grep -q 'personal/knowledge/clean' <<<"$out"; then bad "$label listed a clean repo"; else ok "$label skips clean repos"; fi
  if grep -q '^personal/knowledge/linked: NONSTANDARD symlink' <<<"$out"; then ok "$label flags the symlink"; else bad "$label missed the symlink: $out"; fi
  if grep -q 'shopt' <<<"$out"; then bad "$label printed a shopt error"; else ok "$label has no shopt error"; fi
}

out="$(/bin/bash "$SCRIPT" "$root" 2>&1)"
check_output "/bin/bash" "$out"

if command -v zsh >/dev/null 2>&1; then
  out="$(cd "$root" && zsh -fc 'bash "$1" "$PWD"' zsh "$SCRIPT" 2>&1)"
  check_output "zsh" "$out"
else
  echo "note: zsh not installed; zsh launch case not run"
fi

# A missing root must not fail the checkpoint.
if /bin/bash "$SCRIPT" "$tmp/does-not-exist" >/dev/null 2>&1; then ok "missing root exits 0"; else bad "missing root failed"; fi

# The skill must call the script, not inline bash-only syntax.
if grep -q 'shopt' "$SKILL"; then bad "SKILL.md still inlines shopt"; else ok "SKILL.md has no inline shopt"; fi
if grep -q 'bash core/scripts/checkpoint-knowledge-repos.sh' "$SKILL"; then ok "SKILL.md calls the script"; else bad "SKILL.md does not call the script"; fi

if [[ "$fail" -gt 0 ]]; then echo "Failed $fail checkpoint-knowledge-repos assertions" >&2; exit 1; fi
echo "PASS: checkpoint-knowledge-repos"
