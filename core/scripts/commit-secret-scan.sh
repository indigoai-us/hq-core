#!/usr/bin/env bash
# hq-core: public
#
# commit-secret-scan.sh — HQ's commit-time secret scan (off by default).
#
# When enabled, every `git commit` on this computer runs `hq scan secrets
# --staged` first and is stopped if it finds a possible secret. The scanner is
# built into the hq CLI (5.345.86 or later): offline, no account, no quota, and
# it never prints a secret value.
#
#   status               what is wired now, and the recorded setting
#   enable [--replace]   turn it on for every repo on this computer:
#                          - global core.hooksPath -> ~/.hq/git-hooks (a
#                            dispatcher that scans, then runs the repo's own
#                            .git/hooks/pre-commit, or the previous global hook
#                            folder's hook unless --replace is given)
#                          - husky repos: a marked block in
#                            ~/.config/husky/init.sh (survives npm install)
#                          - repos under $HQ_ROOT/repos that set their own
#                            core.hooksPath: moved to hq.chainHooksPath so the
#                            dispatcher scans first, then runs their hooks
#                        Everything changed is backed up first.
#   disable [--dry-run]  put back exactly what `enable` changed
#   gate                 the pre-commit check itself (used by the dispatcher)
#   pr-check [BASE]      scan the files a branch changed since BASE
#                        (default: origin/HEAD, else origin/main); used by
#                        /review before a pull request
#   hook <name> [args]   dispatcher entry point (called by the hook stubs)
#
# Exit codes: 0 ok, 1 blocked / possible secret, 2 usage or setup error.
# Env: HQ_ROOT (default: this script's HQ), HQ_SECRET_SCAN_BIN (override the
# hq command, for tests), HQ_SECRET_SCAN_HOOKS_DIR (default ~/.hq/git-hooks).
#
# Bash 3.2-safe, no python/node: it runs inside git hooks.

set -u

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
SELF="$HQ_ROOT/core/scripts/commit-secret-scan.sh"
HOOKS_DIR="${HQ_SECRET_SCAN_HOOKS_DIR:-$HOME/.hq/git-hooks}"
STATE_DIR="$(dirname "$HOOKS_DIR")/git-hooks-backups"
SETTING_CORE="$HQ_ROOT/core/settings/commit-secret-scan.yaml"
SETTING_PERSONAL="$HQ_ROOT/personal/settings/commit-secret-scan.yaml"
HUSKY_INIT="${XDG_CONFIG_HOME:-$HOME/.config}/husky/init.sh"
MARK_BEGIN="# >>> HQ commit secret scan (core/scripts/commit-secret-scan.sh) >>>"
MARK_END="# <<< HQ commit secret scan <<<"
MIN_HQ="5.345.86"
HOOK_NAMES="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge pre-push post-rewrite pre-auto-gc push-to-checkout"

# Hooks launched from GUI apps can have a thin PATH.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin"

die() { echo "commit-secret-scan: $*" >&2; exit 2; }

hq_cmd() {
  if [ -n "${HQ_SECRET_SCAN_BIN:-}" ]; then
    # shellcheck disable=SC2086
    $HQ_SECRET_SCAN_BIN "$@"
  else
    hq "$@"
  fi
}

hq_available() {
  if [ -z "${HQ_SECRET_SCAN_BIN:-}" ] && ! command -v hq >/dev/null 2>&1; then return 1; fi
  hq_cmd scan secrets --help >/dev/null 2>&1
}

yaml_scalar() { # file key
  local line=""
  [ -f "$1" ] || return 1
  line="$(grep -E "^$2:[[:space:]]*" "$1" 2>/dev/null | head -n 1)" || return 1
  [ -n "$line" ] || return 1
  printf '%s' "${line#*:}" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//'
}

setting() { # key default
  local v=""
  v="$(yaml_scalar "$SETTING_PERSONAL" "$1")" || v="$(yaml_scalar "$SETTING_CORE" "$1")" || v=""
  printf '%s' "${v:-$2}"
}

write_setting() { # enabled-value
  mkdir -p "$(dirname "$SETTING_PERSONAL")"
  local rec
  rec="$(setting recommend true)"
  cat >"$SETTING_PERSONAL" <<EOF
# Written by core/scripts/commit-secret-scan.sh. Change it with
# \`bash core/scripts/commit-secret-scan.sh enable|disable\`, not by hand.
enabled: $1
recommend: $rec
EOF
}

wired() { [ "$(git config --global --get core.hooksPath 2>/dev/null)" = "$HOOKS_DIR" ]; }

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

# ---------------------------------------------------------------- gate / hook

gate() {
  git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "HQ secret scan: not inside a git work tree" >&2; return 1; }
  if ! hq_available; then
    cat >&2 <<EOF

HQ secret scan: COMMIT BLOCKED — the hq CLI with \`hq scan secrets\` ($MIN_HQ or
later) is not available, so this commit cannot be checked. Update the hq CLI.
To turn the check off instead: bash "$SELF" disable
EOF
    return 1
  fi
  hq_cmd scan secrets --staged
  local rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$rc" -eq 1 ]; then
    cat >&2 <<EOF

HQ secret scan: COMMIT BLOCKED — possible secret in the staged changes (above; values hidden).
Keep credentials out of the repo: store them with \`hq secrets\` and load them at
run time with \`hq run\` or \`hq secrets exec\` instead of a local file.
Skipping this check (git commit --no-verify) needs the repo owner's explicit OK.
EOF
  else
    echo "HQ secret scan: COMMIT BLOCKED — the scan could not run (exit $rc)." >&2
  fi
  return 1
}

hook() { # name args...
  local n="$1"; shift
  if [ "$n" = "pre-commit" ]; then gate || exit 1; fi

  local chain d=""
  chain="$(git config --get hq.chainHooksPath 2>/dev/null)"
  if [ -n "$chain" ]; then
    case "$chain" in /*) d="$chain" ;; *) d="$(git rev-parse --show-toplevel 2>/dev/null)/$chain" ;; esac
  else
    local prev
    prev="$(git config --global --get hq.secretScan.previousHooksPath 2>/dev/null)"
    if [ -n "$prev" ]; then
      d="$prev"
    else
      # Same as git without a global hooksPath, for pre-commit; other hook
      # types also run from .git/hooks, which is git's default behaviour.
      d="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)/hooks"
    fi
  fi
  [ -n "$d" ] && [ -d "$d" ] || exit 0
  [ "$(cd "$d" && pwd -P)" = "$(cd "$HOOKS_DIR" 2>/dev/null && pwd -P)" ] && exit 0
  if [ -f "$d/$n" ] && [ -x "$d/$n" ]; then exec "$d/$n" "$@"; fi
  exit 0
}

# ---------------------------------------------------------------- enable/disable

enable() {
  local replace=0
  [ "${1:-}" = "--replace" ] && replace=1
  hq_available || die "the hq CLI with \`hq scan secrets\` ($MIN_HQ or later) is required. Update the hq CLI, then run this again."
  if wired; then echo "Already on."; status; return 0; fi

  mkdir -p "$HOOKS_DIR" "$STATE_DIR"
  local ts b prev
  ts="$(date +%Y%m%d-%H%M%S)"
  b="$STATE_DIR/backup-$ts.tsv"
  prev="$(git config --global --get core.hooksPath 2>/dev/null)"
  {
    printf 'global\t-\t%s\n' "${prev:--}"
    own_path_repos | while IFS="$(printf '\t')" read -r r hp; do
      if [ -n "$hp" ]; then printf 'repo\t%s\t%s\n' "$r" "$hp"; fi
    done
  } >"$b" || die "could not write the backup"
  echo "Backed up current hook settings: $b"

  # %q keeps a path with spaces, quotes or $ intact in the generated scripts.
  local qself
  qself="$(printf '%q' "$SELF")"
  for n in $HOOK_NAMES; do
    printf '#!/usr/bin/env bash\nexec bash %s hook %s "$@"\n' "$qself" "$n" >"$HOOKS_DIR/$n"
    chmod +x "$HOOKS_DIR/$n"
  done

  if [ -n "$prev" ] && [ "$replace" -eq 0 ]; then
    git config --global hq.secretScan.previousHooksPath "$prev"
    echo "Your previous global hooks ($prev) still run after the scan. Use --replace to drop them."
  fi
  git config --global core.hooksPath "$HOOKS_DIR"

  mkdir -p "$(dirname "$HUSKY_INIT")"
  if ! { [ -f "$HUSKY_INIT" ] && grep -qF "$MARK_BEGIN" "$HUSKY_INIT"; }; then
    printf '%s\nif [ "${n:-}" = "pre-commit" ]; then\n  bash %s gate || exit 1\nfi\n%s\n' \
      "$MARK_BEGIN" "$qself" "$MARK_END" >>"$HUSKY_INIT"
  fi

  own_path_repos | while IFS="$(printf '\t')" read -r r hp; do
    [ -z "$hp" ] && continue
    [ "$hp" = ".husky/_" ] && continue
    case "$hp" in
      /*) if [ ! -d "$hp" ]; then git -C "$r" config --local --unset core.hooksPath; continue; fi ;;
    esac
    git -C "$r" config --local hq.chainHooksPath "$hp"
    git -C "$r" config --local --unset core.hooksPath
  done

  write_setting true
  echo "On. Every commit on this computer is now checked for secrets."
  echo "To undo: bash \"$SELF\" disable"
}

disable() {
  local dry="${1:-}" b
  run() { if [ "$dry" = "--dry-run" ]; then echo "  would run: $*"; else "$@"; fi; }
  b="$(ls -t "$STATE_DIR"/backup-*.tsv 2>/dev/null | head -1)"
  if [ -z "$b" ]; then
    wired && die "no backup found in $STATE_DIR; set core.hooksPath back by hand"
    echo "Already off."; [ "$dry" = "--dry-run" ] || write_setting false; return 0
  fi
  echo "Restoring from $b ${dry}"
  while IFS="$(printf '\t')" read -r kind r hp; do
    case "$kind" in
      global)
        if [ -n "$hp" ] && [ "$hp" != "-" ]; then run git config --global core.hooksPath "$hp"
        else run git config --global --unset core.hooksPath; fi
        run git config --global --unset hq.secretScan.previousHooksPath ;;
      repo)
        [ -d "$r" ] || continue
        [ "$(git -C "$r" config --local --get core.hooksPath 2>/dev/null)" = "$hp" ] && continue
        run git -C "$r" config --local core.hooksPath "$hp"
        run git -C "$r" config --local --unset hq.chainHooksPath ;;
    esac
  done <"$b"
  if [ -f "$HUSKY_INIT" ] && grep -qF "$MARK_BEGIN" "$HUSKY_INIT"; then
    if [ "$dry" = "--dry-run" ]; then echo "  would remove the HQ block from $HUSKY_INIT"
    else
      awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{s=1} !s{print} $0==e{s=0}' "$HUSKY_INIT" >"$HUSKY_INIT.hq-tmp" \
        && mv "$HUSKY_INIT.hq-tmp" "$HUSKY_INIT"
    fi
  fi
  if [ "$dry" != "--dry-run" ]; then
    mv "$b" "$b.restored"
    write_setting false
    echo "Off. Commits are no longer checked by HQ."
  fi
}

status() {
  local en
  en="$(setting enabled false)"
  if wired; then echo "commit secret scan: on"; else echo "commit secret scan: off"; fi
  echo "setting: enabled=$en recommend=$(setting recommend true)"
  if [ "$en" = "true" ] && ! wired; then echo "note: the setting says on, but it is not wired. Run: bash \"$SELF\" enable"; fi
  if hq_available; then echo "scanner: hq scan secrets available"; else echo "scanner: missing (needs hq CLI $MIN_HQ or later)"; fi
}

# ---------------------------------------------------------------- pr-check

pr_check() {
  local base="${1:-}"
  git rev-parse --show-toplevel >/dev/null 2>&1 || die "not inside a git work tree"
  if [ -z "$base" ]; then
    base="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" || base=""
    [ -n "$base" ] || base="origin/main"
  fi
  git rev-parse --verify -q "$base" >/dev/null || die "base '$base' not found; pass one: pr-check <base>"
  hq_available || die "the hq CLI with \`hq scan secrets\` ($MIN_HQ or later) is required"
  local top files=() hist n_commits=0 c f
  top="$(git rev-parse --show-toplevel)"
  # The branch's final contents.
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$top/$f" ] && files+=("$top/$f")
  done < <(git -c core.quotePath=false diff --name-only --diff-filter=ACMR "$base...HEAD")
  # Every version each branch commit added or changed, so a secret that was
  # committed and deleted later on the branch is still caught: it stays in
  # history. Findings here show as <tmp>/<commit>/<path>.
  hist="$(mktemp -d "${TMPDIR:-/tmp}/hq-pr-check.XXXXXX")" || die "could not create a temp folder"
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    n_commits=$((n_commits + 1))
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      mkdir -p "$hist/${c:0:12}/$(dirname "$f")"
      git show "$c:$f" >"$hist/${c:0:12}/$f" 2>/dev/null && files+=("$hist/${c:0:12}/$f")
    done < <(git -c core.quotePath=false diff-tree --no-commit-id --name-only -r --diff-filter=ACMR "$c")
  done < <(git rev-list --no-merges "$base..HEAD")
  if [ "${#files[@]}" -eq 0 ]; then rm -rf "$hist"; echo "HQ secret scan: no changed files since $base."; return 0; fi
  hq_cmd scan secrets "${files[@]}"
  local rc=$?
  rm -rf "$hist"
  if [ "$rc" -eq 0 ]; then echo "HQ secret scan: $n_commits commits since $base and their files, no secrets found."; fi
  return "$rc"
}

case "${1:-status}" in
  status)   status ;;
  enable)   enable "${2:-}" ;;
  disable)  disable "${2:-}" ;;
  gate)     gate; exit $? ;;
  pr-check) pr_check "${2:-}"; exit $? ;;
  hook)     shift; [ $# -ge 1 ] || die "hook needs a name"; hook "$@" ;;
  -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "usage: $(basename "$0") status | enable [--replace] | disable [--dry-run] | gate | pr-check [BASE]" ;;
esac
