#!/usr/bin/env bash
# hq-core: public
#
# hq-root-markers.sh — shared check: does a set of added paths look like a copy
# of an HQ root (personal/, companies/<co>/, credentials/, drift and rescue
# files, ...) dropped into a code repository?
#
# SOURCED, never executed. Bash 3.2-safe, no python/node: it runs inside git
# hooks. Used by core/scripts/worktree-preserve.sh and core/scripts/push-guard.sh.
#
#   hqm_load [hq-root]
#       Reads core/settings/worktree-preserve-denylist.txt and, when present,
#       personal/settings/worktree-preserve-denylist.txt. Sets HQM_RULES (one
#       "<kind> <value>" per line). Call once.
#   hqm_scan <repo-dir> <base-treeish> <paths-file>
#       Reads one repo-relative path per line from <paths-file> and prints
#       "<rule>\t<path>" for every path the denylist marks. <base-treeish> is
#       the tree the paths are added to; "" means "no base" (a brand-new
#       repository: the dir/ foreign-subtree rules are skipped, the root:,
#       anydir: and glob: rules still apply). Returns 1 when at least one
#       path was marked, else 0.
#       At most HQM_MAX_HITS (default 20) lines are printed; the return code
#       still reflects every hit.
#
# The rule forms are documented in the denylist file.

HQM_RULES=""
HQM_MAX_HITS="${HQM_MAX_HITS:-20}"

hqm_load() { # [hq-root]
  local root="${1:-${HQ_ROOT:-}}" f line kind val
  if [ -z "$root" ]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
  fi
  HQM_RULES=""
  for f in "$root/core/settings/worktree-preserve-denylist.txt" "$root/personal/settings/worktree-preserve-denylist.txt"; do
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] || continue
      case "$line" in
        root:*/)   kind=root;   val="${line#root:}" ;;
        anydir:*)  kind=anydir; val="${line#anydir:}" ;;
        glob:*)    kind=glob;   val="${line#glob:}" ;;
        */)        kind=dir;    val="$line" ;;
        *) echo "hq-root-markers: ignoring malformed line in $f: $line" >&2; continue ;;
      esac
      HQM_RULES="${HQM_RULES}${kind} ${val}
"
    done <"$f"
  done
  [ -n "$HQM_RULES" ] || { echo "hq-root-markers: no denylist found under $root (core/settings/worktree-preserve-denylist.txt)" >&2; return 2; }
  return 0
}

# Is <dir> (repo-relative, no trailing slash) a tracked directory in <base>?
# Cached per call of hqm_scan in HQM_TRACKED / HQM_UNTRACKED (newline lists).
hqm_tracked_dir() { # repo-dir base dir
  local repo="$1" base="$2" d="$3" out
  case "$HQM_TRACKED" in *"
$d
"*) return 0 ;; esac
  case "$HQM_UNTRACKED" in *"
$d
"*) return 1 ;; esac
  [ -n "$base" ] || { HQM_UNTRACKED="${HQM_UNTRACKED}${d}
"; return 1; }
  out="$(git -C "$repo" ls-tree -d --name-only "$base" -- "$d" 2>/dev/null)"
  if [ "$out" = "$d" ]; then HQM_TRACKED="${HQM_TRACKED}${d}
"; return 0; fi
  HQM_UNTRACKED="${HQM_UNTRACKED}${d}
"
  return 1
}

# Prints the first rule that marks <path>, or nothing.
hqm_match() { # repo-dir base path
  local repo="$1" base="$2" p="$3" kind val rest first second base_name comp line
  p="${p#./}"
  base_name="${p##*/}"
  first="${p%%/*}"
  rest="${p#*/}"
  second="${rest%%/*}"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind="${line%% *}"; val="${line#* }"
    case "$kind" in
      root)
        case "$p" in "$val"*) echo "root:$val"; return 0 ;; esac ;;
      anydir)
        case "/$p/" in *"/$val/"*) echo "anydir:$val"; return 0 ;; esac ;;
      glob)
        # shellcheck disable=SC2254 # the glob is the point
        case "$base_name" in $val) echo "glob:$val"; return 0 ;; esac ;;
      dir)
        case "$p" in
          "$val"*) ;;
          *) continue ;;
        esac
        # Need at least three components: dir/sub/file, and a base tree to
        # compare against (a repo's first push has none; the root:, anydir:
        # and glob: rules still apply to it).
        [ -n "$base" ] || continue
        case "$rest" in */*) ;; *) continue ;; esac
        comp="$first/$second"
        if ! hqm_tracked_dir "$repo" "$base" "$comp"; then echo "foreign:$comp/"; return 0; fi ;;
    esac
  done <<EOF
$HQM_RULES
EOF
  return 1
}

hqm_scan() { # repo-dir base paths-file
  local repo="$1" base="$2" file="$3" p r hits=0 shown=0
  [ -n "$HQM_RULES" ] || hqm_load || return 2
  HQM_TRACKED="
"; HQM_UNTRACKED="
"
  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    r="$(hqm_match "$repo" "$base" "$p")" || continue
    hits=$((hits + 1))
    if [ "$shown" -lt "$HQM_MAX_HITS" ]; then printf '%s\t%s\n' "$r" "$p"; shown=$((shown + 1)); fi
  done <"$file"
  if [ "$hits" -gt "$shown" ]; then printf '...\t%s more\n' "$((hits - shown))"; fi
  [ "$hits" -eq 0 ]
}
