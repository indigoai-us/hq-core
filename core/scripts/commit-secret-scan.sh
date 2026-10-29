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
#   pr-check [BASE]      scan what the branch added since BASE
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
SETTING_CORE="$HQ_ROOT/core/settings/commit-secret-scan.yaml"
SETTING_PERSONAL="$HQ_ROOT/personal/settings/commit-secret-scan.yaml"
MIN_HQ="5.345.86"
# shellcheck disable=SC2034 # read by ghd_die in the sourced lib
GHD_PROG="commit-secret-scan"
# The dispatcher, backups and husky block are shared with
# core/scripts/hq-fingerprint-hooks.sh.
# shellcheck source=lib/git-hooks-dispatcher.sh
. "$HQ_ROOT/core/scripts/lib/git-hooks-dispatcher.sh"

# Hooks launched from GUI apps can have a thin PATH.
ghd_augment_path

die() { echo "commit-secret-scan: $*" >&2; exit 2; }

hq_cmd() {
  if [ -n "${HQ_SECRET_SCAN_BIN:-}" ]; then
    # shellcheck disable=SC2086
    $HQ_SECRET_SCAN_BIN "$@"
  else
    hq "$@"
  fi
}

# An hq CLI older than $MIN_HQ has no `scan` command but still exits 0 on
# `scan secrets --help` (it prints the root help). Require the scanner's own
# --staged option in the help text so an old CLI is reported as missing
# instead of every commit failing as a "possible secret".
hq_available() {
  if [ -z "${HQ_SECRET_SCAN_BIN:-}" ] && ! command -v hq >/dev/null 2>&1; then return 1; fi
  local help
  help="$(hq_cmd scan secrets --help 2>&1)" || return 1
  case "$help" in
    *--staged*) return 0 ;;
  esac
  return 1
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
  cat >"$SETTING_PERSONAL" <<EOS
# Written by core/scripts/commit-secret-scan.sh. Change it with
# \`bash core/scripts/commit-secret-scan.sh enable|disable\`, not by hand.
enabled: $1
recommend: $rec
EOS
}

wired() { ghd_wired && ghd_feature_on secretScan; }

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

# Older hook stubs call `commit-secret-scan.sh hook <name>`; they keep working.
hook() { # name args...
  exec bash "$GHD_LIB" dispatch "$@"
}

# ---------------------------------------------------------------- enable/disable

enable() {
  local replace=""
  [ "${1:-}" = "--replace" ] && replace="--replace"
  hq_available || die "the hq CLI with \`hq scan secrets\` ($MIN_HQ or later) is required. Update the hq CLI, then run this again."
  # Already wired: rewrite stale stubs (moved HQ folder, edited markers).
  if wired; then ghd_refresh >/dev/null 2>&1; echo "Already on."; status; return 0; fi

  ghd_install $replace
  ghd_set_marker secretScan

  write_setting true
  echo "On. Every commit on this computer is now checked for secrets."
  echo "To undo: bash \"$SELF\" disable"
}

disable() {
  local dry="${1:-}" out
  [ "$dry" = "--dry-run" ] || ghd_clear_marker secretScan
  out="$(ghd_uninstall_if_unused secretScan "$dry")" || { [ "$dry" = "--dry-run" ] || ghd_set_marker secretScan; exit 2; }
  if [ "$out" = "kept" ]; then
    [ "$dry" = "--dry-run" ] && { echo "  would stop the secret scan; the HQ git hook stays for the fingerprint trailer"; return 0; }
    write_setting false
    echo "Off. Commits are no longer checked for secrets. The HQ git hook stays on for the fingerprint trailer."
    return 0
  fi
  [ -n "$out" ] && echo "$out"
  [ "$dry" = "--dry-run" ] && return 0
  write_setting false
  [ "$out" = "Already off." ] || echo "Off. Commits are no longer checked by HQ."
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
  # A CLI with --range (hq-cli 5.345.171+) scans only what the branch's
  # commits added (each commit, merges included, plus the net diff from the
  # merge-base), with rules and allowlists from the base's .gitleaks.toml. Its
  # exit code is passed through: 0 clean, 1 possible secret, 2 bad ref or scan
  # error. Any other non-zero code is reported as 2, so a scan that did not
  # finish never counts as a pass. Older CLIs use the snapshot scan below.
  # Only committed changes are scanned; uncommitted edits are not part of the PR.
  case "$(hq_cmd scan secrets --help 2>&1)" in
    *"--range <"*)
      local rbase rtop rrc
      rbase="$(git rev-parse --verify -q "$base^{commit}")" || die "base '$base' is not a commit"
      rtop="$(git rev-parse --show-toplevel)"
      hq_cmd scan secrets --repo "$rtop" --range "$rbase..HEAD"
      rrc=$?
      case "$rrc" in
        0) echo "HQ secret scan: commits since $base, no secrets found." ; return 0 ;;
        1) return 1 ;;
        *) echo "HQ secret scan: the scan could not run (exit $rrc); treating it as a failure." >&2; return 2 ;;
      esac
      ;;
  esac
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
  # A CLI with --allowlist-rev applies the .gitleaks.toml allowlists committed
  # on the base branch; history copies match by their repo path. The base copy
  # is used for every file, so an allowlist the branch adds cannot exempt the
  # branch's own commits. An older CLI scans without allowlists (stricter,
  # never looser).
  local base_sha
  base_sha="$(git rev-parse --verify -q "$base^{commit}")" || { rm -rf "$hist"; die "base '$base' is not a commit"; }
  case "$(hq_cmd scan secrets --help 2>&1)" in
    *--allowlist-rev*) hq_cmd scan secrets --repo "$top" --allowlist-rev "$base_sha" --snapshot-root "$hist" "${files[@]}" ;;
    *) hq_cmd scan secrets "${files[@]}" ;;
  esac
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
