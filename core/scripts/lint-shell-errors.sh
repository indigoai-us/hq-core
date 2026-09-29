#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-$(git rev-parse --show-toplevel)}"
repo_root="$(cd "$repo_root" && pwd)"
tracked_list="$(mktemp)"
trap 'unlink "$tracked_list"' EXIT

if ! git -C "$repo_root" ls-files -z > "$tracked_list"; then
  printf 'unable to list tracked files in %s\n' "$repo_root" >&2
  exit 1
fi

shell_scripts=()
shell_script_count=0
while IFS= read -r -d '' path; do
  if [[ "$path" == *.sh ]]; then
    shell_scripts+=("$path")
    shell_script_count=$((shell_script_count + 1))
    continue
  fi

  shebang=''
  IFS= read -r shebang < "$repo_root/$path" || true
  shebang="${shebang%$'\r'}"
  [[ "$shebang" == '#!'* ]] || continue
  read -r -a words <<< "${shebang#\#!}"
  for word in "${words[@]}"; do
    case "${word##*/}" in
      bash|sh)
        shell_scripts+=("$path")
        shell_script_count=$((shell_script_count + 1))
        break
        ;;
    esac
  done
done < "$tracked_list"

printf 'ShellCheck checking %d tracked shell scripts at error severity\n' "$shell_script_count"
if ((shell_script_count > 0)); then
  (cd "$repo_root" && shellcheck -S error -- "${shell_scripts[@]}")
fi
