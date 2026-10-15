#!/usr/bin/env bash
# shellcheck disable=SC2016  # stub and husky text is single-quoted on purpose
# hq-core: public
#
# git-hooks-dispatcher.sh - the shared machine-wide git hook dispatcher behind
# HQ's commit-time features. Sourced by core/scripts/commit-secret-scan.sh
# (pre-commit secret scan) and core/scripts/hq-fingerprint-hooks.sh
# (commit-msg HQ-Fingerprint trailer). Run directly:
#
#   dispatch <name> [args]   run each enabled feature's stage for hook <name>,
#                            then chain to the repo's own hook (the stubs call
#                            this only when a stage has work to do)
#   husky <name> [args]      run the feature stages only (sourced from
#                            ~/.config/husky/init.sh; husky runs its own hook)
#   repair                   rewrite the stubs and the husky block from this
#                            file's location. Run it after the HQ folder moved
#                            or core/ was reverted:
#                              bash core/scripts/lib/git-hooks-dispatcher.sh repair
#
# What it wires (once, shared by every feature):
#   - global core.hooksPath -> ~/.hq/git-hooks, a small POSIX stub per hook
#     name. A stub starts bash and this file only when a feature needs it:
#     pre-commit while the secret scan is on (every repo), commit-msg while
#     the trailer is on and the repo is inside the HQ folder. Every other
#     call passes straight to the hook git would have run without HQ: the
#     repo's hq.chainHooksPath, else the previous global hook folder
#     (hq.secretScan.previousHooksPath), else <git common dir>/hooks.
#   - husky repos: a marked block in ~/.config/husky/init.sh, written while the
#     secret scan is on, or while the trailer is on and husky is in use.
#   - repos under $HQ_ROOT/repos that set their own core.hooksPath: moved to
#     hq.chainHooksPath so the dispatcher runs first, then their hooks
#   Everything changed is backed up first (~/.hq/git-hooks-backups) and put
#   back by ghd_uninstall_if_unused once no feature is on.
#
# The stubs and the husky block record the HQ folder, this file's path and
# which features are on. A stub or block whose lib is missing (HQ moved,
# reverted or removed) lets git run as if HQ were not there; only the secret
# scan, when it is on, blocks the commit and names the repair command.
#
# Per-feature switches live in global git config so the dispatcher can read
# them from any repo: hq.hooks.secretScan, hq.hooks.fingerprint. A machine
# wired by the older secret-scan-only script (no hq.hooks.* keys) counts as
# secretScan on; that is recorded as hq.hooks.secretScan=true before any
# switch is written (ghd_migrate_legacy). Changing a switch rewrites the
# stubs; after editing hq.hooks.* by hand, run repair.
#
# Squash messages (`git merge --squash`, `rebase -i` squash/fixup) keep the
# squashed commits' HQ-Fingerprint lines in the body, the same as
# Signed-off-by; only the last trailer block counts as trailers.
#
# Bash 3.2-safe, no python/node/jq: it runs inside git hooks. The stubs and
# the husky block are POSIX sh (dash when present, it starts fastest).

GHD_LIB="$HQ_ROOT/core/scripts/lib/git-hooks-dispatcher.sh"
# ${HOME:-}: a hook can run with HOME unset, and set -u must not end it.
GHD_HOOKS_DIR="${HQ_SECRET_SCAN_HOOKS_DIR:-${HOME:-}/.hq/git-hooks}"
GHD_STATE_DIR="$(dirname "$GHD_HOOKS_DIR")/git-hooks-backups"
GHD_HUSKY_INIT="${XDG_CONFIG_HOME:-${HOME:-}/.config}/husky/init.sh"
GHD_MARK_BEGIN="# >>> HQ git hooks (core/scripts/lib/git-hooks-dispatcher.sh) >>>"
GHD_MARK_END="# <<< HQ git hooks <<<"
# Blocks written by older versions; stripped on every rewrite.
GHD_LEGACY_MARK_BEGIN="# >>> HQ commit secret scan"
GHD_LEGACY_MARK_END="# <<< HQ commit secret scan <<<"
GHD_STUB_TAG="# hq-git-hooks-dispatcher stub"
GHD_FEATURES="secretScan fingerprint"
GHD_HOOK_NAMES="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge pre-push post-rewrite pre-auto-gc push-to-checkout"
# Hook names git also runs from core.hooksPath. Without a pass-through stub, a
# global hooksPath hides the repo's own hook of that name.
GHD_HOOK_NAMES_EXTRA="pre-receive update proc-receive post-receive post-update sendemail-validate fsmonitor-watchman p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit post-index-change"
# Runs several times per commit and per checkout, so its stub is only written
# when the previous global hook folder has one to pass to.
GHD_HOOK_REFTX="reference-transaction"
GHD_CHANGED=""

ghd_die() { echo "${GHD_PROG:-git-hooks-dispatcher}: $*" >&2; exit 2; }

# The value of "key:" in a flat YAML file, comment and spaces trimmed. Shell
# builtins only: it runs on every commit.
yaml_scalar() { # file key
  local line v
  [ -f "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$2:"*)
        v="${line#*:}"
        v="${v%%#*}"
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        printf '%s' "$v"
        return 0 ;;
    esac
  done <"$1"
  return 1
}

# A path in one comparable form: physical, and in Windows mixed form
# (C:/...) when cygpath exists, so /c/Users/x and C:/Users/x match.
ghd_canon() { # path
  local c w
  c="$(cd "$1" 2>/dev/null && pwd -P)" || c=""
  [ -n "$c" ] || c="$1"
  if command -v cygpath >/dev/null 2>&1; then
    w="$(cygpath -m "$c" 2>/dev/null)" || w=""
    [ -n "$w" ] && c="$w"
  fi
  printf '%s' "$c"
}

# A global path setting as git uses it: ~ expanded (git config --path),
# with a fallback for a git that cannot expand it.
ghd_global_path() { # key
  local v rc
  v="$(git config --global --get --path "$1" 2>/dev/null)"; rc=$?
  # 1 = not set: done, no second spawn. Anything else: retry without --path.
  if [ "$rc" -eq 1 ]; then return 1; fi
  if [ "$rc" -ne 0 ]; then v="$(git config --global --get "$1" 2>/dev/null)" || return 1; fi
  # shellcheck disable=SC2088  # "~/" is a pattern here, not a path
  case "$v" in
    "~") v="${HOME:-}" ;;
    "~/"*) v="${HOME:-}/${v#??}" ;;
  esac
  printf '%s' "$v"
}

ghd_wired() {
  local v
  v="$(ghd_global_path core.hooksPath)" || return 1
  [ -n "$v" ] || return 1
  [ "$v" = "$GHD_HOOKS_DIR" ] && return 0
  [ "$(ghd_canon "$v")" = "$(ghd_canon "$GHD_HOOKS_DIR")" ]
}

# All hq.hooks.* switches, read with one git call and kept for this process.
# Anything that writes a switch calls ghd_markers_changed.
ghd_load_markers() {
  [ "${GHD_M_LOADED:-0}" = 1 ] && return 0
  GHD_M_ANY=0; GHD_M_SECRETSCAN=""; GHD_M_FINGERPRINT=""
  local k v
  while read -r k v; do
    [ -n "$k" ] || continue
    GHD_M_ANY=1
    case "$k" in
      hq.hooks.secretscan) GHD_M_SECRETSCAN="$v" ;;
      hq.hooks.fingerprint) GHD_M_FINGERPRINT="$v" ;;
    esac
  done <<EOF
$(git config --global --get-regexp '^hq\.hooks\.' 2>/dev/null)
EOF
  GHD_M_LOADED=1
}
ghd_markers_changed() { GHD_M_LOADED=0; }

ghd_any_marker() { ghd_load_markers; [ "$GHD_M_ANY" = 1 ]; }

ghd_feature_on() { # feature
  ghd_load_markers
  case "$1" in
    secretScan) [ "$GHD_M_SECRETSCAN" = "true" ] && return 0 ;;
    fingerprint) [ "$GHD_M_FINGERPRINT" = "true" ] && return 0 ;;
  esac
  # Wired by the older secret-scan-only script: no per-feature keys at all.
  [ "$1" = "secretScan" ] && [ "$GHD_M_ANY" = 0 ] && ghd_wired && return 0
  return 1
}

ghd_others_on() { # feature: is any other feature on?
  local f
  for f in $GHD_FEATURES; do
    [ "$f" = "$1" ] && continue
    ghd_feature_on "$f" && return 0
  done
  return 1
}

# Unset a global key and drop its section when that leaves it empty, so an
# enable/disable round trip leaves ~/.gitconfig as it was.
ghd_unset_global() { # key
  local sec="${1%.*}"
  git config --global --unset "$1" 2>/dev/null
  git config --global --get-regexp "^$(printf '%s' "$sec" | sed 's/\./\\./g')\." >/dev/null 2>&1 \
    || git config --global --remove-section "$sec" 2>/dev/null
  return 0
}

# An older secret-scan-only install has no per-feature key. Writing any key
# would hide it from ghd_feature_on, so record it first. ghd_install and
# ghd_clear_marker run this before they change anything; ghd_set_marker must
# not, because right after a fresh install the machine is wired with no keys.
ghd_migrate_legacy() {
  if ghd_wired && ! ghd_any_marker; then
    git config --global hq.hooks.secretScan true
    ghd_markers_changed
  fi
  return 0
}

# Switch changes rewrite the stubs and the husky block, which record the
# switches so that a hook with nothing to do never starts bash.
ghd_set_marker() {
  git config --global "hq.hooks.$1" true
  ghd_markers_changed
  if ghd_wired; then ghd_refresh; fi
  return 0
}
# Off is recorded as false, not unset: with no hq.hooks.* keys left, a wired
# dispatcher would read as the older secret-scan-only install (see above).
# The last feature off drops the whole section (ghd_drop_markers).
ghd_clear_marker() {
  ghd_migrate_legacy
  git config --global "hq.hooks.$1" false
  ghd_markers_changed
  if ghd_wired; then ghd_refresh; fi
  return 0
}

# Hooks launched from GUI apps can have a thin PATH: add the usual homes of
# the hq CLI (Homebrew, the HQ desktop app toolchain, npm/pnpm/volta/bun).
ghd_augment_path() {
  PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
  if [ -n "${HOME:-}" ]; then
    PATH="$PATH:$HOME/Library/Application Support/Indigo HQ/toolchain/node/bin"
    PATH="$PATH:$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/Library/pnpm:$HOME/.local/share/pnpm:$HOME/.volta/bin:$HOME/.bun/bin"
  fi
  export PATH
}
ghd_drop_markers() {
  local f
  for f in $GHD_FEATURES; do ghd_unset_global "hq.hooks.$f"; done
  ghd_markers_changed
}

# One line per distinct repo config under $HQ_ROOT/repos (worktrees share it):
# <checkout>\t<local core.hooksPath>
own_path_repos() {
  [ -d "$HQ_ROOT/repos" ] || return 0
  find "$HQ_ROOT/repos" -maxdepth 4 -name .git 2>/dev/null | while read -r g; do
    r="$(dirname "$g")"
    cd_="$(git -C "$r" rev-parse --git-common-dir 2>/dev/null)" || continue
    case "$cd_" in /*) ;; *) cd_="$r/$cd_" ;; esac
    cd_="$(cd "$cd_" 2>/dev/null && pwd -P)" || continue
    printf '%s\t%s\t%s\n' "$cd_" "$r" "$(git -C "$r" config --local --get core.hooksPath 2>/dev/null)"
  done | sort -u -t "$(printf '\t')" -k1,1 | cut -f2-
}

# shellcheck disable=SC2012  # backup names are ours: backup-<stamp>.tsv
ghd_latest_backup() { ls -t "$GHD_STATE_DIR"/backup-*.tsv 2>/dev/null | head -1; }

# What was there before install, as recorded in the backup's husky line:
# none (no folder), dir (folder, no init.sh) or file (init.sh existed).
ghd_husky_before() {
  if [ -f "$GHD_HUSKY_INIT" ]; then echo file
  elif [ -d "$(dirname "$GHD_HUSKY_INIT")" ]; then echo dir
  else echo none; fi
}

# The husky line of the newest backup; file when there is none.
ghd_backup_husky_before() {
  local b kind r hp
  b="$(ghd_latest_backup)"
  if [ -n "$b" ]; then
    while IFS="$(printf '\t')" read -r kind r hp; do
      if [ "$kind" = "husky" ]; then
        case "$hp" in none|dir|file) echo "$hp"; return 0 ;; esac
      fi
    done <"$b"
  fi
  echo file
}

# Did install move any repo's own hook folder to hq.chainHooksPath? Only then
# do the stubs need to ask git for it.
ghd_backup_has_chain() {
  local b kind r hp
  b="$(ghd_latest_backup)"
  [ -n "$b" ] || return 1
  while IFS="$(printf '\t')" read -r kind r hp; do
    [ "$kind" = "repo" ] && [ -n "$hp" ] && [ "$hp" != ".husky/_" ] && return 0
  done <"$b"
  return 1
}

ghd_has_husky_block() {
  [ -f "$GHD_HUSKY_INIT" ] && grep -qE '# >>> HQ (git hooks|commit secret scan)' "$GHD_HUSKY_INIT"
}

# Print the husky file without HQ blocks (current and legacy labels). A begin
# marker after other text on a line (a file that had no final newline when a
# block was appended) keeps the text before it.
ghd_husky_stripped() { # file
  awk -v b1="$GHD_MARK_BEGIN" -v b2="$GHD_LEGACY_MARK_BEGIN" -v e1="$GHD_MARK_END" -v e2="$GHD_LEGACY_MARK_END" '
    {
      line = $0
      if (!s) {
        p = index(line, b1); q = index(line, b2)
        if (q && (!p || q < p)) p = q
        if (p) { if (p > 1) print substr(line, 1, p - 1); s = 1; next }
        print line; next
      }
      if (index(line, e1) || index(line, e2)) s = 0
    }' "$1"
}

ghd_strip_husky_block() { # [before: none|dir|file]
  local before="${1:-file}" tmp
  ghd_has_husky_block || return 0
  tmp="$GHD_HUSKY_INIT.hq-tmp.$$"
  ghd_husky_stripped "$GHD_HUSKY_INIT" >"$tmp" && cat "$tmp" >"$GHD_HUSKY_INIT"
  rm -f "$tmp"
  # Only our block was in a file install created: put back the "no file"
  # state. A file that existed before (even empty) stays, and so does a
  # folder that existed before. Backups without a husky line keep the file.
  if [ ! -s "$GHD_HUSKY_INIT" ] && [ "$before" != "file" ]; then
    rm -f "$GHD_HUSKY_INIT"
    [ "$before" = "none" ] && rmdir "$(dirname "$GHD_HUSKY_INIT")" 2>/dev/null
  fi
  return 0
}

# Print $1 as one single-quoted shell word: wrap it in single quotes and write
# each ' inside as '\''. Unlike printf %q, the result is the same on bash 3.2
# and bash 5, and it keeps spaces, quotes, $ and backslashes literal.
# The trailing x keeps a path that ends in a newline intact through $(...).
ghd_shq() {
  local q
  q="$(printf '%s\n' "$1" | sed "s/'/'\\\\''/g"; printf x)"
  q="${q%x}"
  printf "'%s'" "${q%?}"
}

# Move a freshly written file into place unless the target already has the
# same content, so a refresh that changes nothing touches nothing.
ghd_put() { # target tmp label
  if [ -f "$1" ] && [ -x "$1" ] && cmp -s "$1" "$2"; then rm -f "$2"; return 0; fi
  mv -f "$2" "$1" || { rm -f "$2"; return 1; }
  GHD_CHANGED="$GHD_CHANGED $3"
  return 0
}

ghd_stub_shell() {
  if [ -n "${GHD_STUB_SHELL:-}" ]; then printf '%s' "$GHD_STUB_SHELL"
  elif [ -x /bin/dash ]; then printf '/bin/dash'
  else printf '/bin/sh'; fi
}

ghd_missing_msg() {
  printf 'HQ git hooks: %s is missing, so the commit secret scan cannot run. Fix it from your HQ folder with: bash core/scripts/lib/git-hooks-dispatcher.sh repair (or turn the hooks off: git config --global --unset core.hooksPath)' "$GHD_LIB"
}

# git's own push-to-checkout behaviour (receive.denyCurrentBranch=
# updateInstead), which a push-to-checkout hook replaces. Used when the stub
# finds no hook of that name to pass to. $1 is the pushed commit.
GHD_PUSH_TO_CHECKOUT_DEFAULT='git update-index -q --ignore-submodules --refresh || { echo "Up-to-date check failed" >&2; exit 1; }
git diff-files --quiet --ignore-submodules -- || { echo "Working directory has unstaged changes" >&2; exit 1; }
if git cat-file -e HEAD 2>/dev/null; then hq_t=HEAD; else hq_t=$(git hash-object -t tree --stdin </dev/null); fi
git diff-index --quiet --cached --ignore-submodules "$hq_t" -- || { echo "Working directory has staged changes" >&2; exit 1; }
git read-tree -u -m "$1" || { echo "Could not update working tree to new HEAD" >&2; exit 1; }
exit 0'

# The stub for hook $1. POSIX sh with no subprocess on the pass-through path.
ghd_stub_text() { # name scan(0|1) trailer(0|1) chain(0|1) qroot qlib qrphys qprev shell
  local n="$1" s="$2" f="$3" c="$4" qroot="$5" qlib="$6" qr="$7" qp="$8"
  printf '#!%s\n' "$9"
  printf '%s\n' "$GHD_STUB_TAG"
  printf '# Written by HQ. If the HQ folder moved, run from it:\n'
  printf '#   bash core/scripts/lib/git-hooks-dispatcher.sh repair\n'
  printf 'hq_r=%s\nhq_l=%s\nhq_p=%s\n' "$qr" "$qlib" "$qp"
  case "$n" in
    pre-commit)
      printf 'if [ %s = 1 ]; then\n' "$s"
      printf '  if [ -f "$hq_l" ]; then\n'
      printf 'HQ_ROOT=%s HQ_GHD_STUB_CHAIN=%s HQ_GHD_STUB_PREV="$hq_p" exec bash %s dispatch %s "$@"\n' "$qroot" "$c" "$qlib" "$n"
      printf '  fi\n'
      printf '  printf %%s\\\\n %s >&2\n' "$(ghd_shq "$(ghd_missing_msg)")"
      printf '  exit 1\n'
      printf 'fi\n' ;;
    commit-msg)
      printf 'hq_go=\n'
      printf 'if [ %s = 1 ] && [ -f "$hq_l" ]; then\n' "$f"
      printf '  hq_o=$PWD; cd -P . 2>/dev/null\n'
      printf '  case "$PWD/" in "$hq_r"/*) hq_go=1 ;; esac\n'
      printf '  cd "$hq_o" 2>/dev/null\n'
      printf 'fi\n'
      printf 'if [ -n "$hq_go" ]; then\n'
      printf 'HQ_ROOT=%s HQ_GHD_STUB_CHAIN=%s HQ_GHD_STUB_PREV="$hq_p" exec bash %s dispatch %s "$@"\n' "$qroot" "$c" "$qlib" "$n"
      printf 'fi\n' ;;
  esac
  # Pass through to the hook git would run without HQ.
  printf 'hq_d=\n'
  if [ "$c" = 1 ]; then
    printf 'hq_o=$PWD; cd -P . 2>/dev/null; hq_w=$PWD; cd "$hq_o" 2>/dev/null\n'
    printf 'case "$hq_w/" in "$hq_r"/*) hq_d=$(git config --get hq.chainHooksPath 2>/dev/null) ;; esac\n'
  fi
  cat <<'EOF'
if [ -n "$hq_d" ]; then
  case "$hq_d" in /*) ;; *) hq_d="$PWD/$hq_d" ;; esac
elif [ -n "$hq_p" ]; then
  hq_d=$hq_p
else
  hq_g=${GIT_COMMON_DIR:-}
  if [ -z "$hq_g" ]; then
    hq_g=${GIT_DIR:-.git}
    if [ -f "$hq_g" ]; then
      hq_x=; read -r hq_x <"$hq_g"
      case "$hq_g" in */*) hq_b=${hq_g%/*} ;; *) hq_b=. ;; esac
      case "$hq_x" in "gitdir: /"*) hq_g=${hq_x#gitdir: } ;; "gitdir: "?*) hq_g="$hq_b/${hq_x#gitdir: }" ;; esac
    fi
    if [ -f "$hq_g/commondir" ]; then
      hq_x=; read -r hq_x <"$hq_g/commondir"
      case "$hq_x" in /*) hq_g=$hq_x ;; ?*) hq_g="$hq_g/$hq_x" ;; esac
    fi
  fi
  case "$hq_g" in /*) ;; *) hq_g="$PWD/$hq_g" ;; esac
  if [ ! -d "$hq_g" ]; then
    hq_g=$(git rev-parse --git-common-dir 2>/dev/null)
    case "$hq_g" in /*) ;; *) hq_g="$PWD/$hq_g" ;; esac
  fi
  hq_d="$hq_g/hooks"
fi
EOF
  printf 'hq_h="$hq_d/%s"\n' "$n"
  printf 'if [ -f "$hq_h" ] && [ -x "$hq_h" ] && [ ! "$hq_h" -ef "$0" ]; then exec "$hq_h" "$@"; fi\n'
  if [ "$n" = "push-to-checkout" ]; then
    printf '%s\n' "$GHD_PUSH_TO_CHECKOUT_DEFAULT"
  else
    printf 'exit 0\n'
  fi
}

ghd_write_stubs() {
  local qlib qroot qr qp rphys prev s=0 f=0 c=0 sh n tmp
  qlib="$(ghd_shq "$GHD_LIB")"
  qroot="$(ghd_shq "$HQ_ROOT")"
  rphys="$(cd "$HQ_ROOT" 2>/dev/null && pwd -P)" || rphys="$HQ_ROOT"
  qr="$(ghd_shq "$rphys")"
  prev="$(ghd_global_path hq.secretScan.previousHooksPath)" || prev=""
  qp="$(ghd_shq "$prev")"
  ghd_feature_on secretScan && s=1
  ghd_feature_on fingerprint && f=1
  ghd_backup_has_chain && c=1
  sh="$(ghd_stub_shell)"
  mkdir -p "$GHD_HOOKS_DIR" || return 1
  for n in $GHD_HOOK_NAMES $GHD_HOOK_NAMES_EXTRA $GHD_HOOK_REFTX; do
    if [ "$n" = "$GHD_HOOK_REFTX" ] && ! { [ -n "$prev" ] && [ -f "$prev/$n" ] && [ -x "$prev/$n" ]; }; then
      if [ -f "$GHD_HOOKS_DIR/$n" ] && grep -qF "$GHD_STUB_TAG" "$GHD_HOOKS_DIR/$n"; then
        rm -f "$GHD_HOOKS_DIR/$n"; GHD_CHANGED="$GHD_CHANGED -$n"
      fi
      continue
    fi
    tmp="$GHD_HOOKS_DIR/.$n.hq-tmp.$$"
    ghd_stub_text "$n" "$s" "$f" "$c" "$qroot" "$qlib" "$qr" "$qp" "$sh" >"$tmp" || { rm -f "$tmp"; continue; }
    chmod 755 "$tmp"
    ghd_put "$GHD_HOOKS_DIR/$n" "$tmp" "$n"
  done
  return 0
}

ghd_remove_stubs() {
  local n
  for n in $GHD_HOOK_NAMES $GHD_HOOK_NAMES_EXTRA $GHD_HOOK_REFTX; do
    [ -f "$GHD_HOOKS_DIR/$n" ] && grep -qF "$GHD_STUB_TAG" "$GHD_HOOKS_DIR/$n" && rm -f "$GHD_HOOKS_DIR/$n"
  done
  rmdir "$GHD_HOOKS_DIR" 2>/dev/null
  return 0
}

# Is the husky block needed? Always while the secret scan is on (it covers
# every husky repo). For the trailer only when husky is in use: a husky
# config folder exists, or a repo inside the HQ folder has .husky.
ghd_husky_wanted() {
  ghd_feature_on secretScan && return 0
  ghd_feature_on fingerprint || return 1
  [ -d "$(dirname "$GHD_HUSKY_INIT")" ] && return 0
  [ -n "$(find "$HQ_ROOT/repos" "$HQ_ROOT/workspace/worktrees" -maxdepth 3 -type d -name .husky 2>/dev/null | head -n 1)" ]
}

ghd_husky_block() {
  local s=0 f=0 qlib qr rphys
  ghd_feature_on secretScan && s=1
  ghd_feature_on fingerprint && f=1
  qlib="$(ghd_shq "$GHD_LIB")"
  rphys="$(cd "$HQ_ROOT" 2>/dev/null && pwd -P)" || rphys="$HQ_ROOT"
  qr="$(ghd_shq "$rphys")"
  printf '%s\n' "$GHD_MARK_BEGIN"
  printf 'hq_go=\n'
  printf 'case "${n:-}" in\n'
  printf '  pre-commit) [ %s = 1 ] && hq_go=1 ;;\n' "$s"
  printf '  commit-msg)\n'
  printf '    if [ %s = 1 ]; then\n' "$f"
  printf '      hq_o=$PWD; cd -P . 2>/dev/null\n'
  printf '      case "$PWD/" in %s/*) hq_go=1 ;; esac\n' "$qr"
  printf '      cd "$hq_o" 2>/dev/null\n'
  printf '    fi ;;\n'
  printf 'esac\n'
  printf 'if [ -n "$hq_go" ]; then\n'
  printf '  if [ -f %s ]; then\n' "$qlib"
  printf '    bash %s husky "$n" "$@" || exit 1\n' "$qlib"
  printf '  elif [ "$n" = pre-commit ]; then\n'
  printf '    printf %%s\\\\n %s >&2; exit 1\n' "$(ghd_shq "$(ghd_missing_msg)")"
  printf '  fi\n'
  printf 'fi\n'
  printf 'unset hq_go hq_o\n'
  printf '%s\n' "$GHD_MARK_END"
}

# Write (or drop) the husky block. The file keeps its inode and is only
# rewritten when its content changes.
ghd_write_husky() {
  local tmp dir
  if ! ghd_husky_wanted; then
    if ghd_has_husky_block; then ghd_strip_husky_block "$(ghd_backup_husky_before)"; GHD_CHANGED="$GHD_CHANGED -husky"; fi
    return 0
  fi
  dir="$(dirname "$GHD_HUSKY_INIT")"
  mkdir -p "$dir" || return 0
  tmp="$GHD_HUSKY_INIT.hq-tmp.$$"
  {
    # awk ends every line with a newline, so the block never joins the
    # file's last line.
    if [ -f "$GHD_HUSKY_INIT" ]; then ghd_husky_stripped "$GHD_HUSKY_INIT"; fi
    ghd_husky_block
  } >"$tmp" || { rm -f "$tmp"; return 0; }
  if [ -f "$GHD_HUSKY_INIT" ]; then
    if ! cmp -s "$tmp" "$GHD_HUSKY_INIT"; then
      cat "$tmp" >"$GHD_HUSKY_INIT" && GHD_CHANGED="$GHD_CHANGED husky"
    fi
    rm -f "$tmp"
  else
    mv -f "$tmp" "$GHD_HUSKY_INIT" && GHD_CHANGED="$GHD_CHANGED husky"
  fi
  return 0
}

# Rewrite the stubs and the husky block for the current switches and HQ
# location. GHD_CHANGED lists what changed.
ghd_refresh() {
  GHD_CHANGED=""
  ghd_write_stubs
  ghd_write_husky
  return 0
}

# Wire the dispatcher. Idempotent: when already wired it only refreshes the
# stubs and the husky block, and takes no second backup. The caller sets its
# switch next (ghd_set_marker), which writes the husky block.
ghd_install() { # [--replace]
  local replace=0
  [ "${1:-}" = "--replace" ] && replace=1
  ghd_migrate_legacy

  mkdir -p "$GHD_HOOKS_DIR" "$GHD_STATE_DIR" || ghd_die "could not create $GHD_HOOKS_DIR"
  if ghd_wired; then ghd_refresh; return 0; fi

  local ts b prev_raw prev
  ts="$(date +%Y%m%d-%H%M%S)"
  b="$GHD_STATE_DIR/backup-$ts.tsv"
  # The backup keeps the value as written (~/.githooks stays ~/.githooks);
  # the chain uses it expanded, as git does.
  prev_raw="$(git config --global --get core.hooksPath 2>/dev/null)"
  prev="$(ghd_global_path core.hooksPath)" || prev=""
  {
    printf 'global\t-\t%s\n' "${prev_raw:--}"
    printf 'husky\t-\t%s\n' "$(ghd_husky_before)"
    own_path_repos | while IFS="$(printf '\t')" read -r r hp; do
      if [ -n "$hp" ]; then printf 'repo\t%s\t%s\n' "$r" "$hp"; fi
    done
  } >"$b" || ghd_die "could not write the backup"
  echo "Backed up current hook settings: $b"

  if [ -n "$prev" ] && [ "$replace" -eq 0 ]; then
    git config --global hq.secretScan.previousHooksPath "$prev"
    echo "Your previous global hooks ($prev_raw) still run after the HQ checks. Use --replace to drop them."
  fi
  # Stubs first, so git never sees the new hooksPath without them.
  GHD_CHANGED=""
  ghd_write_stubs
  git config --global core.hooksPath "$GHD_HOOKS_DIR"

  own_path_repos | while IFS="$(printf '\t')" read -r r hp; do
    [ -z "$hp" ] && continue
    [ "$hp" = ".husky/_" ] && continue
    case "$hp" in
      /*) if [ ! -d "$hp" ]; then git -C "$r" config --local --unset core.hooksPath; continue; fi ;;
    esac
    git -C "$r" config --local hq.chainHooksPath "$hp"
    git -C "$r" config --local --unset core.hooksPath
  done
  return 0
}

# Put back what ghd_install changed, unless another feature still needs it.
# The caller clears its own marker first (skipped for --dry-run, so pass the
# feature being turned off). Prints "kept" and returns 0 when it stays wired.
ghd_uninstall_if_unused() { # feature [--dry-run]
  local feature="$1" dry="${2:-}" b husky_before=file
  if ghd_others_on "$feature"; then echo "kept"; return 0; fi
  run() { if [ "$dry" = "--dry-run" ]; then echo "  would run: $*"; else "$@"; fi; }
  b="$(ghd_latest_backup)"
  if [ -z "$b" ]; then
    ghd_wired && ghd_die "no backup found in $GHD_STATE_DIR; set core.hooksPath back by hand"
    [ "$dry" = "--dry-run" ] || ghd_drop_markers
    echo "Already off."; return 0
  fi
  echo "Restoring from $b ${dry}"
  while IFS="$(printf '\t')" read -r kind r hp; do
    case "$kind" in
      global)
        if [ -n "$hp" ] && [ "$hp" != "-" ]; then run git config --global core.hooksPath "$hp"
        else run ghd_unset_global core.hooksPath; fi
        run ghd_unset_global hq.secretScan.previousHooksPath ;;
      husky)
        case "$hp" in none|dir|file) husky_before="$hp" ;; esac ;;
      repo)
        [ -d "$r" ] || continue
        [ "$(git -C "$r" config --local --get core.hooksPath 2>/dev/null)" = "$hp" ] && continue
        run git -C "$r" config --local core.hooksPath "$hp"
        run git -C "$r" config --local --unset hq.chainHooksPath ;;
    esac
  done <"$b"
  if ghd_has_husky_block; then
    if [ "$dry" = "--dry-run" ]; then echo "  would remove the HQ block from $GHD_HUSKY_INIT"
    else ghd_strip_husky_block "$husky_before"; fi
  fi
  if [ "$dry" != "--dry-run" ]; then
    mv "$b" "$b.restored"
    ghd_remove_stubs
    ghd_drop_markers
  fi
  return 0
}

# Rewrite the stubs and husky block from this file's location (repair).
ghd_repair() {
  if ghd_wired; then
    ghd_refresh
    if [ -n "$GHD_CHANGED" ]; then echo "Rewrote:$GHD_CHANGED"
    else echo "HQ git hooks are up to date."; fi
    return 0
  fi
  if ghd_has_husky_block; then
    ghd_strip_husky_block "$(ghd_backup_husky_before)"
    echo "Not wired; removed the HQ block from $GHD_HUSKY_INIT."
  else
    echo "Not wired; nothing to repair."
  fi
  return 0
}

# ---------------------------------------------------------------- dispatch

ghd_stages() { # name args...: 1 = blocked
  local n="$1"; shift
  case "$n" in
    pre-commit)
      if ghd_feature_on secretScan; then bash "$HQ_ROOT/core/scripts/commit-secret-scan.sh" gate || return 1; fi ;;
    commit-msg)
      # Fails open: the trailer is never worth a failed commit.
      if ghd_feature_on fingerprint && [ -f "$HQ_ROOT/core/scripts/hq-fingerprint-hooks.sh" ]; then
        bash "$HQ_ROOT/core/scripts/hq-fingerprint-hooks.sh" hook commit-msg "$@" >/dev/null 2>&1 </dev/null
      fi ;;
  esac
  return 0
}

# The repository's common git dir, read the way the stub reads it (GIT_DIR,
# a .git file, a worktree's commondir) without starting git; git answers
# only when that finds no directory.
ghd_common_dir() {
  local g="${GIT_COMMON_DIR:-}" x b
  if [ -z "$g" ]; then
    g="${GIT_DIR:-.git}"
    if [ -f "$g" ]; then
      x=""; read -r x <"$g"
      case "$g" in */*) b="${g%/*}" ;; *) b=. ;; esac
      case "$x" in "gitdir: /"*) g="${x#gitdir: }" ;; "gitdir: "?*) g="$b/${x#gitdir: }" ;; esac
    fi
    if [ -f "$g/commondir" ]; then
      x=""; read -r x <"$g/commondir"
      case "$x" in /*) g="$x" ;; ?*) g="$g/$x" ;; esac
    fi
  fi
  if [ -d "$g" ]; then printf '%s' "$g"; return 0; fi
  git rev-parse --git-common-dir 2>/dev/null
}

ghd_dispatch() { # name args...
  local n="$1"; shift
  ghd_stages "$n" "$@" || exit 1

  local chain="" prev="" d="" keys=0 stub_chain="${HQ_GHD_STUB_CHAIN:-}" stub_prev="${HQ_GHD_STUB_PREV:-}"
  unset HQ_GHD_STUB_CHAIN HQ_GHD_STUB_PREV
  if [ "$stub_chain" = 0 ]; then
    # A current stub called in: it was written with no hook chain recorded
    # and carries the previous hooks path, so its own pass-through reads no
    # git config. Do the same here (two git calls fewer per commit).
    prev="$stub_prev"
  # One git call answers "is either chain key set at all?" (the usual answer
  # is no); only then pay for the exact per-key reads. Git lowercases section
  # and key names before matching, but a subsection keeps its case.
  elif git config --get-regexp '^hq\.(chainhookspath|secretScan\.previoushookspath)$' >/dev/null 2>&1; then
    keys=1
    chain="$(git config --get hq.chainHooksPath 2>/dev/null)"
  fi
  if [ -n "$chain" ]; then
    case "$chain" in /*) d="$chain" ;; *) d="$(git rev-parse --show-toplevel 2>/dev/null)/$chain" ;; esac
  else
    if [ "$keys" = 1 ]; then prev="$(ghd_global_path hq.secretScan.previousHooksPath)" || prev=""; fi
    if [ -n "$prev" ]; then
      d="$prev"
    else
      # Where git looks without a global hooksPath.
      d="$(cd "$(ghd_common_dir)" 2>/dev/null && pwd -P)/hooks"
    fi
  fi
  if [ -n "$d" ] && [ -d "$d" ] && [ "$(cd "$d" && pwd -P)" != "$(cd "$GHD_HOOKS_DIR" 2>/dev/null && pwd -P)" ]; then
    if [ -f "$d/$n" ] && [ -x "$d/$n" ]; then exec "$d/$n" "$@"; fi
  fi
  if [ "$n" = "push-to-checkout" ]; then
    eval "$GHD_PUSH_TO_CHECKOUT_DEFAULT"
  fi
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  case "${1:-}" in
    repair)
      # Always the HQ folder this file is in: that is the point of repair.
      HQ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)" ;;
    *) HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)}" ;;
  esac
  GHD_LIB="$HQ_ROOT/core/scripts/lib/git-hooks-dispatcher.sh"
  ghd_augment_path
  case "${1:-}" in
    dispatch) shift; [ $# -ge 1 ] || ghd_die "dispatch needs a hook name"; ghd_dispatch "$@" ;;
    husky)    shift; [ $# -ge 1 ] || ghd_die "husky needs a hook name"; ghd_stages "$@"; exit $? ;;
    repair)   ghd_repair; exit $? ;;
    *) ghd_die "usage: $(basename "$0") dispatch|husky <hook-name> [args] | repair" ;;
  esac
fi
