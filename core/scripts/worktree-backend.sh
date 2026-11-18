#!/usr/bin/env bash
# hq-core: public
# worktree-backend.sh — the one place HQ creates and removes code-repo worktrees.
#
# Backend selection (first match wins):
#   1. HQ_WORKTREE_BACKEND env var            (git | twig)
#   2. personal/settings/worktrees.yaml       worktrees.backend
#   3. core/settings/worktrees.yaml           worktrees.backend   (ships: git)
#   4. git
#
# With backend=git this runs plain `git worktree add`, exactly as before.
#
# With backend=twig it uses `git twig new` (https://twig.leostera.dev) when twig
# is installed and the platform is macOS or Linux, so new worktrees are made with
# native copy-on-write (APFS clonefile, Btrfs/XFS reflink). In every other case
# it falls back to plain `git worktree add` without failing: twig missing, twig
# older than 0.3.0, Windows, or a twig error. On a filesystem without CoW (Linux
# ext4, for example) twig itself delegates to stock Git.
#
# Twig only takes its CoW path when the requested commit is the source
# checkout's current HEAD. HQ usually bases worktrees on origin/<default>, so
# when the base differs from HEAD this script clones HEAD with twig (detached)
# and then switches the new worktree to the requested branch and base. Git then
# rewrites only the files that differ.
#
# Twig also refuses its CoW path when the repo has a post-index-change or
# reference-transaction hook. HQ's global git-hooks dispatcher installs a
# forwarding stub for every hook name, including those two, so every HQ repo
# looks hooked. When the only such hooks are HQ dispatcher stubs with nothing to
# forward to, this script points twig at a filtered view of the hooks directory
# (the same stubs, minus those two). A real hook of either kind is left alone and
# twig falls back to stock Git, as twig intends.
#
# Removal: worktrees made either way are ordinary linked Git worktrees, so
# `remove` always uses `git worktree remove`. worktree-gc.sh, free-disk-space.sh,
# worktree-preserve.sh and /clean-worktree need no twig awareness.
#
# Soak log: when the effective backend is twig, every `add` appends one JSON line
# to workspace/reports/twig-soak/events.jsonl (repo, path, mode, duration, disk
# delta, fallback reason, error). twig-soak-summary.sh turns it into a daily
# report. Logging failures never fail worktree creation.
#
# Usage:
#   worktree-backend.sh add --repo <src> --path <dest> --new-branch <b> --base <ref> [--no-track]
#   worktree-backend.sh add --repo <src> --path <dest> --branch <existing-branch>
#   worktree-backend.sh add --repo <src> --path <dest> --detach --base <ref>
#   worktree-backend.sh remove --repo <src> --path <dest> [--force]
#   worktree-backend.sh backend            # prints the effective backend and why
#
# Exit code is the exit code of the worktree operation that ran.

set -uo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TWIG_MIN_VERSION="0.3.0"

wb_die() { echo "worktree-backend: $*" >&2; exit 2; }

# wb_setting_from <file> — print worktrees.backend from a small YAML file.
wb_setting_from() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk '
    /^[[:space:]]*#/ { next }
    /^worktrees:[[:space:]]*($|#)/ { inblk=1; next }
    /^[^[:space:]]/ { inblk=0 }
    inblk && /^[[:space:]]+backend:/ {
      v=$0; sub(/^[[:space:]]+backend:[[:space:]]*/, "", v); sub(/[[:space:]]*#.*$/, "", v)
      gsub(/["'\'']/, "", v); print v; exit
    }
  ' "$f"
}

# wb_configured — print "<backend> <source>" for the configured backend.
wb_configured() {
  local v
  if [ -n "${HQ_WORKTREE_BACKEND:-}" ]; then
    printf '%s env\n' "$HQ_WORKTREE_BACKEND"; return
  fi
  v="$(wb_setting_from "$HQ_ROOT/personal/settings/worktrees.yaml")"
  if [ -n "$v" ]; then printf '%s personal\n' "$v"; return; fi
  v="$(wb_setting_from "$HQ_ROOT/core/settings/worktrees.yaml")"
  if [ -n "$v" ]; then printf '%s core\n' "$v"; return; fi
  printf 'git default\n'
}

# wb_version_ge <a> <b> — true when dotted version a >= b.
wb_version_ge() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]
}

# wb_twig_status — print "ok <version>" or "<reason>" for twig availability.
wb_twig_status() {
  case "$(uname -s 2>/dev/null)" in
    Darwin|Linux) ;;
    *) echo "unsupported-platform"; return ;;
  esac
  local out ver
  out="$(git twig --version 2>/dev/null)" || { echo "twig-missing"; return; }
  ver="$(printf '%s' "$out" | sed -n 's/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
  [ -n "$ver" ] || { echo "twig-version-unknown"; return; }
  wb_version_ge "$ver" "$TWIG_MIN_VERSION" || { echo "twig-too-old-$ver"; return; }
  echo "ok $ver"
}

wb_now_ms() {
  LC_ALL=C perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null || echo $(( $(date +%s) * 1000 ))
}

wb_free_kb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

wb_json_str() {
  printf '%s' "$1" | awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); if (NR>1) print "\\n"; print}'
}

# wb_log key=value ... — append one JSON line to the soak log. Best-effort.
wb_log() {
  local dir="${HQ_TWIG_SOAK_DIR:-$HQ_ROOT/workspace/reports/twig-soak}"
  mkdir -p "$dir" 2>/dev/null || return 0
  local line="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$v" in
      ''|*[!0-9-]*|-) line="$line,\"$k\":\"$(wb_json_str "$v")\"" ;;
      *) line="$line,\"$k\":$v" ;;
    esac
  done
  printf '%s}\n' "$line" >> "$dir/events.jsonl" 2>/dev/null || true
}

# wb_hooks_view <repo> — print a hooks dir for twig to use, or nothing to keep
# the repo's own hooks path. See the header for why.
wb_hooks_view() {
  local repo="$1" hooks name f chain view key
  hooks="$(git -C "$repo" rev-parse --git-path hooks 2>/dev/null)" || return 0
  case "$hooks" in /*) ;; *) hooks="$(git -C "$repo" rev-parse --show-toplevel)/$hooks" ;; esac
  [ -d "$hooks" ] || return 0
  local need=0
  for name in post-index-change reference-transaction; do
    f="$hooks/$name"
    [ -e "$f" ] || continue
    grep -q 'hq-git-hooks-dispatcher stub' "$f" 2>/dev/null || return 0   # a real hook: leave it
    need=1
  done
  [ "$need" -eq 1 ] || return 0
  # The stub forwards to hq.chainHooksPath or <common-dir>/hooks. If either has
  # a real hook of these kinds, the stub is not a no-op: leave the hooks alone.
  chain="$(git -C "$repo" config --get hq.chainHooksPath 2>/dev/null || true)"
  for f in "$chain" "$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/hooks"; do
    [ -n "$f" ] || continue
    for name in post-index-change reference-transaction; do
      [ -x "$f/$name" ] && ! [ "$f/$name" -ef "$hooks/$name" ] && return 0
    done
  done
  key="$(printf '%s' "$hooks" | cksum | cut -d' ' -f1)"
  view="$HQ_ROOT/workspace/.cache/twig-hooks-view/$key"
  mkdir -p "$view" 2>/dev/null || return 0
  for f in "$hooks"/*; do
    [ -e "$f" ] || continue
    name="$(basename "$f")"
    case "$name" in post-index-change|reference-transaction) rm -f "$view/$name"; continue ;; esac
    [ -e "$view/$name" ] || ln -s "$f" "$view/$name" 2>/dev/null || true
  done
  printf '%s\n' "$view"
}

# wb_twig_preflight <repo> — print a reason when twig 0.3.0 would refuse its
# CoW path for this repo, so the helper goes straight to plain git instead of
# paying for twig's stock checkout plus a switch. Mirrors twig's own checks
# that are cheap to test; anything missed here still falls back inside twig.
wb_twig_preflight() {
  local repo="$1" top v cache
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || { echo "not-a-repo"; return; }
  v="$(git -C "$repo" config --get core.autocrlf 2>/dev/null || true)"
  [ -n "$v" ] && [ "$v" != false ] && { echo "twig-ineligible-autocrlf"; return; }
  [ "$(git -C "$repo" config --bool --get core.sparseCheckout 2>/dev/null)" = true ] && { echo "twig-ineligible-sparse"; return; }
  [ "$(git -C "$repo" config --bool --get core.symlinks 2>/dev/null)" = false ] && { echo "twig-ineligible-symlinks"; return; }
  [ -f "$top/.gitmodules" ] && { echo "twig-ineligible-submodules"; return; }
  # text/eol/filter/ident/working-tree-encoding attributes in any tracked
  # .gitattributes, or in info/attributes.
  local f attr_files
  attr_files="$(git -C "$repo" ls-files -- ':(glob).gitattributes' ':(glob)**/.gitattributes' 2>/dev/null)"
  for f in $attr_files "$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/info/attributes"; do
    case "$f" in /*) ;; *) f="$top/$f" ;; esac
    [ -f "$f" ] || continue
    if grep -v '^[[:space:]]*#' "$f" 2>/dev/null | grep -Eq '(^|[[:space:]])-?(text|eol|crlf|filter|ident|working-tree-encoding)([=[:space:]]|$)'; then
      echo "twig-ineligible-attributes"; return
    fi
  done
  # A recent unexplained stock fallback for this repo: skip twig for a day.
  cache="$HQ_ROOT/workspace/.cache/twig-stock/$(printf '%s' "$top" | cksum | cut -d' ' -f1)"
  if [ -f "$cache" ] && [ -n "$(find "$cache" -mmin -1440 2>/dev/null)" ]; then
    echo "twig-stock-recent"; return
  fi
}

wb_mark_stock() {
  local top cache
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 0
  cache="$HQ_ROOT/workspace/.cache/twig-stock"
  mkdir -p "$cache" 2>/dev/null && : > "$cache/$(printf '%s' "$top" | cksum | cut -d' ' -f1)" 2>/dev/null || true
}

# wb_twig_new <repo> <hooks-view> <args...> — run git twig new with trace on,
# stderr captured to $WB_TRACE. Returns twig's exit code.
wb_twig_new() {
  local repo="$1" view="$2"; shift 2
  if [ -n "$view" ]; then
    TWIG_TRACE=1 git -c core.hooksPath="$view" -C "$repo" twig new "$@" 2>"$WB_TRACE" >&2
  else
    TWIG_TRACE=1 git -C "$repo" twig new "$@" 2>"$WB_TRACE" >&2
  fi
}

wb_twig_mode() { # read $WB_TRACE: cow or stock
  if grep -q 'git-twig: stock Git' "$WB_TRACE" 2>/dev/null; then echo stock; else echo cow; fi
}

wb_registered() { git -C "$1" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $2"; }

# wb_discard_partial <repo> <path> — remove a worktree this call created and
# could not finish. Only called when the path did not exist before this call.
wb_discard_partial() {
  local repo="$1" path="$2"
  if [ -e "$path" ] || wb_registered "$repo" "$path"; then
    git -C "$repo" worktree remove --force "$path" >/dev/null 2>&1 || true
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
  fi
}

wb_git_add() { # mode-specific plain git add
  local repo="$1" path="$2"
  case "$MODE" in
    new) if [ "$NO_TRACK" -eq 1 ]; then git -C "$repo" worktree add --no-track -b "$NEW_BRANCH" "$path" "$BASE"
         else git -C "$repo" worktree add -b "$NEW_BRANCH" "$path" "$BASE"; fi ;;
    existing) git -C "$repo" worktree add "$path" "$BRANCH" ;;
    detach) git -C "$repo" worktree add --detach "$path" "$BASE" ;;
  esac
}

# wb_twig_add — try twig; set TWIG_RESULT (cow|cow+switch|stock|failed) and
# TWIG_ERR. Returns 0 when a usable worktree exists at $PATH_ARG.
wb_twig_add() {
  local repo="$1" path="$2" view head target rc
  view="$(wb_hooks_view "$repo")"
  HOOKS_VIEW_USED="${view:+yes}"; HOOKS_VIEW_USED="${HOOKS_VIEW_USED:-no}"
  head="$(git -C "$repo" rev-parse --verify --quiet HEAD 2>/dev/null || true)"
  case "$MODE" in
    new|detach) target="$(git -C "$repo" rev-parse --verify --quiet "$BASE^{commit}" 2>/dev/null || true)" ;;
    existing) target="$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}" 2>/dev/null || true)" ;;
  esac
  if [ -n "$head" ] && [ "$head" = "$target" ] && [ "$MODE" = new ]; then
    # Base is the source HEAD: one twig call does it all. --no-track is not
    # passed: twig's CoW parser rejects it, and a branch started from the local
    # HEAD gets no upstream anyway. Any upstream is cleared below to be sure.
    wb_twig_new "$repo" "$view" -b "$NEW_BRANCH" "$path" HEAD; rc=$?
    if [ "$rc" -eq 0 ] && [ "$NO_TRACK" -eq 1 ]; then
      git -C "$path" branch --unset-upstream "$NEW_BRANCH" >/dev/null 2>&1 || true
    fi
    if [ "$rc" -ne 0 ]; then TWIG_RESULT=failed; TWIG_ERR="$(tail -3 "$WB_TRACE" | tr '\n' ' ')"; return 1; fi
    TWIG_RESULT="$(wb_twig_mode)"; return 0
  fi
  # Base differs from HEAD (or existing branch / detach): clone HEAD detached,
  # then move the new worktree to the requested ref.
  [ -n "$head" ] && [ -n "$target" ] || { TWIG_RESULT=failed; TWIG_ERR="cannot resolve HEAD or target"; return 1; }
  wb_twig_new "$repo" "$view" --detach "$path" HEAD; rc=$?
  if [ "$rc" -ne 0 ]; then TWIG_RESULT=failed; TWIG_ERR="$(tail -3 "$WB_TRACE" | tr '\n' ' ')"; return 1; fi
  local mode; mode="$(wb_twig_mode)"
  local sw_err
  case "$MODE" in
    new) if [ "$NO_TRACK" -eq 1 ]; then sw_err="$(git -C "$path" switch -q --no-track -c "$NEW_BRANCH" "$BASE" 2>&1)"
         else sw_err="$(git -C "$path" switch -q -c "$NEW_BRANCH" "$BASE" 2>&1)"; fi ;;
    existing) sw_err="$(git -C "$path" switch -q "$BRANCH" 2>&1)" ;;
    detach) sw_err="$(git -C "$path" switch -q --detach "$BASE" 2>&1)" ;;
  esac
  rc=$?
  if [ "$rc" -ne 0 ]; then
    TWIG_RESULT=failed; TWIG_ERR="switch after twig failed: $(printf '%s' "$sw_err" | tail -2 | tr '\n' ' ')"
    wb_discard_partial "$repo" "$path"
    return 1
  fi
  if [ "$mode" = cow ]; then TWIG_RESULT="cow+switch"; else TWIG_RESULT=stock; fi
  return 0
}

cmd_add() {
  local repo="" path="" ; MODE=""; NEW_BRANCH=""; BRANCH=""; BASE=""; NO_TRACK=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --path) path="${2:-}"; shift 2 ;;
      --new-branch) NEW_BRANCH="${2:-}"; MODE=new; shift 2 ;;
      --branch) BRANCH="${2:-}"; MODE=existing; shift 2 ;;
      --detach) MODE=detach; shift ;;
      --base) BASE="${2:-}"; shift 2 ;;
      --no-track) NO_TRACK=1; shift ;;
      *) wb_die "add: unknown arg $1" ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$path" ] && [ -n "$MODE" ] || wb_die "add needs --repo, --path and one of --new-branch/--branch/--detach"
  case "$MODE" in new|detach) [ -n "$BASE" ] || wb_die "add: --base is required with --new-branch/--detach" ;; esac

  local configured source
  read -r configured source <<EOF
$(wb_configured)
EOF
  if [ "$configured" != twig ]; then
    [ "$configured" = git ] || echo "worktree-backend: unknown backend '$configured' ($source); using git" >&2
    wb_git_add "$repo" "$path"; return $?
  fi

  # twig requested. Measure and log everything from here on.
  local parent start free0 free1 rc status ver="" fallback="" used
  parent="$(dirname "$path")"; mkdir -p "$parent" 2>/dev/null || true
  start="$(wb_now_ms)"; free0="$(wb_free_kb "$parent")"
  status="$(wb_twig_status)"
  TWIG_RESULT=""; TWIG_ERR=""; HOOKS_VIEW_USED=no
  WB_TRACE="$(mktemp 2>/dev/null || echo "/tmp/wb-trace.$$")"
  local preexisting=0; [ -e "$path" ] && preexisting=1
  case "$status" in
    ok\ *)
      ver="${status#ok }"
      fallback="$(wb_twig_preflight "$repo")"
      if [ -n "$fallback" ]; then
        used=git
        wb_git_add "$repo" "$path"; rc=$?
      elif wb_twig_add "$repo" "$path"; then
        used="twig-$TWIG_RESULT"; rc=0
        [ "$TWIG_RESULT" = stock ] && wb_mark_stock "$repo"
      else
        wb_mark_stock "$repo"
        [ "$preexisting" -eq 0 ] && wb_discard_partial "$repo" "$path"
        fallback="twig-error"; used=git
        wb_git_add "$repo" "$path"; rc=$?
      fi ;;
    *)
      fallback="$status"; used=git
      wb_git_add "$repo" "$path"; rc=$? ;;
  esac
  free1="$(wb_free_kb "$parent")"
  local dur=$(( $(wb_now_ms) - start )) delta=""
  [ -n "$free0" ] && [ -n "$free1" ] && delta=$(( free0 - free1 ))
  wb_log "repo=$repo" "path=$path" "mode=$MODE" "backend=$used" "twig_version=$ver" \
    "fallback=$fallback" "error=$TWIG_ERR" "hooks_view=$HOOKS_VIEW_USED" \
    "duration_ms=$dur" "disk_delta_kb=${delta:-}" "rc=$rc" "setting_source=$source"
  rm -f "$WB_TRACE" 2>/dev/null || true
  return "$rc"
}

cmd_remove() {
  local repo="" path="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --path) path="${2:-}"; shift 2 ;;
      --force) force=1; shift ;;
      *) wb_die "remove: unknown arg $1" ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$path" ] || wb_die "remove needs --repo and --path"
  if [ "$force" -eq 1 ]; then git -C "$repo" worktree remove --force "$path"
  else git -C "$repo" worktree remove "$path"; fi
}

cmd_backend() {
  local configured source status
  read -r configured source <<EOF
$(wb_configured)
EOF
  if [ "$configured" != twig ]; then echo "git (configured: $configured, from $source)"; return 0; fi
  status="$(wb_twig_status)"
  case "$status" in
    ok\ *) echo "twig ${status#ok } (from $source)" ;;
    *) echo "git (twig requested from $source, falling back: $status)" ;;
  esac
}

case "${1:-}" in
  add) shift; cmd_add "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  backend) shift; cmd_backend ;;
  -h|--help|"") sed -n '2,52p' "$0" ;;
  *) wb_die "unknown command $1 (add|remove|backend)" ;;
esac
