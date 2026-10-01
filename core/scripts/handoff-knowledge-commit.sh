#!/usr/bin/env bash
# Commit only knowledge-repo files explicitly named by the handoff changeset.
set -euo pipefail

usage() {
  echo "Usage: $0 --files-touched-json-file <path> [--root <hq-root>]" >&2
  exit 2
}

changeset=""
root="$(pwd -P)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --files-touched-json-file) [ "$#" -ge 2 ] || usage; changeset="$2"; shift 2 ;;
    --root) [ "$#" -ge 2 ] || usage; root="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$changeset" ] && [ -f "$changeset" ] || usage
root="$(cd "$root" && pwd -P)"
tmp_parent="$root/workspace/threads/.handoff-tmp"
mkdir -p "$tmp_parent"
tmp_dir="$(mktemp -d "$tmp_parent/handoff-knowledge-commit.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
handled_paths="$tmp_dir/handled-paths"
: > "$handled_paths"

jq -e 'def safe_path: type == "string" and length > 0 and (startswith("/") | not) and (split("/") | all(.[]; . != "" and . != "." and . != "..")) and (contains("\n") | not) and (contains("\r") | not); type == "array" and all(.[]; if type == "string" then safe_path else type == "object" and (.path | safe_path) end)' "$changeset" >/dev/null || {
  echo "handoff knowledge commit: changeset must be an array of safe relative file paths" >&2
  exit 1
}

for knowledge_path in "$root"/core/knowledge/public/* "$root"/core/knowledge/private/* "$root"/personal/knowledge/* "$root"/companies/*/knowledge; do
  [ -e "$knowledge_path" ] || [ -L "$knowledge_path" ] || continue
  knowledge_rel="${knowledge_path#"$root"/}"
  if [ -L "$knowledge_path" ]; then
    case "$knowledge_path" in
      "$root"/companies/*/knowledge)
        echo "INVALID-LINK: $knowledge_rel is a symlink; company knowledge must be a plain directory synced through the company vault"
        ;;
      *)
        repo_dir="$(git -C "$knowledge_path" rev-parse --show-toplevel 2>/dev/null)" || continue
        repo_real="$(cd "$repo_dir" && pwd -P)"
        hq_repo="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || hq_repo=""
        hq_repo_real=""
        [ -z "$hq_repo" ] || hq_repo_real="$(cd "$hq_repo" && pwd -P)"
        [ "$repo_real" = "$hq_repo_real" ] && continue
        dirty="$(git -C "$repo_dir" status --porcelain)"
        [ -n "$dirty" ] || continue
        echo "INVALID-DIRTY: $knowledge_rel is a legacy knowledge symlink to $repo_dir with uncommitted changes — NOT auto-committed; run hq reindex to materialize it, then commit, before archiving this session"
        ;;
    esac
    continue
  fi
  case "$knowledge_path" in
    "$root"/companies/*/knowledge) continue ;;
  esac
  [ -e "$knowledge_path/.git" ] || continue
  repo_dir="$(git -C "$knowledge_path" rev-parse --show-toplevel 2>/dev/null)" || continue
  knowledge_real="$(cd "$knowledge_path" && pwd -P)"
  repo_real="$(cd "$repo_dir" && pwd -P)"
  [ "$knowledge_real" = "$repo_real" ] || continue
  knowledge_rel="${knowledge_path#"$root"/}"
  repo_paths=()
  while IFS= read -r touched_path; do
    case "$touched_path" in
      "$knowledge_rel"/*) relative_path="${touched_path#"$knowledge_rel"/}" ;;
      *) continue ;;
    esac
    case "/$relative_path/" in */../*|*/./*)
      echo "handoff knowledge commit: unsafe path in changeset: $touched_path" >&2
      exit 1
      ;;
    esac
    [ -n "$relative_path" ] || continue
    if [ -d "$repo_dir/$relative_path" ]; then
      printf '%s\n' "$touched_path" >> "$handled_paths"
      while IFS= read -r -d '' status_entry; do
        status_code="${status_entry:0:2}"
        status_path="${status_entry:3}"
        case "$status_code" in *R*|*C*) IFS= read -r -d '' original_path || original_path="" ;; esac
        case "$status_path" in
          "$relative_path"/*)
            repo_paths+=("$status_path")
            printf '%s/%s\n' "$knowledge_rel" "$status_path" >> "$handled_paths"
            ;;
        esac
        case "$status_code" in *R*|*C*)
          case "$original_path" in
            "$relative_path"/*)
              repo_paths+=("$original_path")
              printf '%s/%s\n' "$knowledge_rel" "$original_path" >> "$handled_paths"
              ;;
          esac
          ;;
        esac
      done < <(git -C "$repo_dir" status --porcelain=v1 -z --untracked-files=all -- "$relative_path")
      continue
    fi
    if [ ! -e "$repo_dir/$relative_path" ] && ! git -C "$repo_dir" ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1; then
      continue
    fi
    repo_paths+=("$relative_path")
    printf '%s\n' "$touched_path" >> "$handled_paths"
  done < <(jq -r '.[] | if type == "string" then . else .path end' "$changeset")

  [ "${#repo_paths[@]}" -gt 0 ] || continue
  changed="$(git -C "$repo_dir" status --porcelain -- "${repo_paths[@]}")"
  [ -n "$changed" ] || continue
  git -C "$repo_dir" add -- "${repo_paths[@]}"
  git -C "$repo_dir" commit --only -m "checkpoint: save session knowledge changes" -- "${repo_paths[@]}"
done

while IFS= read -r touched_path; do
  case "$touched_path" in
    core/knowledge/public/*|core/knowledge/private/*|personal/knowledge/*)
      if ! grep -Fqx -- "$touched_path" "$handled_paths"; then
        echo "NOT-COMMITTED: $touched_path is listed in the handoff changeset but no knowledge repository committed it"
      fi
      ;;
  esac
done < <(jq -r '.[] | if type == "string" then . else .path end' "$changeset")
