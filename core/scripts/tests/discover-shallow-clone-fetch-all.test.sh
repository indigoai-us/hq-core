#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/discover/SKILL.md"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/discover-shallow-clone.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

clone_line="$(sed -n '/git clone --depth=50 /{s/^[[:space:]]*//;p;q;}' "$SKILL")"
[[ -n "$clone_line" ]] || { echo "FAIL: discover clone command not found" >&2; exit 1; }
read -r -a words <<< "$clone_line"
[[ "${words[0]}" == git && "${words[1]}" == clone ]] || {
  echo "FAIL: unexpected discover clone command: $clone_line" >&2
  exit 1
}
clone_flags=()
for word in "${words[@]:2}"; do
  [[ "$word" == '<url>' ]] && break
  clone_flags+=("$word")
done

mkdir -p "$WORK/seed" "$WORK/bare"
git -C "$WORK/seed" init -q -b main
git -C "$WORK/seed" config user.name "US-086 fixture"
git -C "$WORK/seed" config user.email "us086-fixture@example.invalid"
printf 'main\n' > "$WORK/seed/file.txt"
git -C "$WORK/seed" add file.txt
git -C "$WORK/seed" commit -q -m main
git -C "$WORK/bare" init -q --bare
git -C "$WORK/seed" remote add origin "$WORK/bare"
git -C "$WORK/seed" push -q origin main
git -C "$WORK/seed" checkout -q -b secondary
printf 'secondary\n' >> "$WORK/seed/file.txt"
git -C "$WORK/seed" commit -q -am secondary
git -C "$WORK/seed" push -q origin secondary
git -C "$WORK/bare" symbolic-ref HEAD refs/heads/main

git -C "$WORK" clone "${clone_flags[@]}" "file://$WORK/bare" "$WORK/clone" >/dev/null 2>&1
git -C "$WORK/clone" fetch origin >/dev/null 2>&1
if ! git -C "$WORK/clone" show-ref --verify --quiet refs/remotes/origin/secondary; then
  echo "FAIL: plain fetch after the discover shallow clone did not fetch origin/secondary" >&2
  exit 1
fi

echo "PASS: discover shallow clone retains the full remote fetch refspec"
