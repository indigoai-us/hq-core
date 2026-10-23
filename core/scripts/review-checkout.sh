#!/usr/bin/env bash
# hq-core: public
#
# review-checkout.sh — keep local PR reviews light on the reviewer's machine.
#
# Reviewing someone else's pull request used to mean a fresh `git clone` into
# /tmp per PR (often per PR head), a full dependency install, and the repo's
# full test suite and type check, sometimes several at once. Nothing deleted
# the clones afterwards. On one Mac that left 81 clone directories (some 2 GB
# with node_modules) and kept fseventsd near 100% CPU. This script replaces
# that pattern:
#
#   prepare   One cached checkout per repo at
#             workspace/review-cache/<owner>__<name>. Each PR head is fetched
#             into it (refs/review/pr-<n>) and checked out detached. Ignored
#             files such as node_modules stay, and the output says whether
#             dependencies need a reinstall (only when a tracked lockfile
#             changed since the last recorded install).
#             One review at a time owns a cached checkout. prepare records
#             the PR as the checkout's active review and refuses (exit 73)
#             while a different PR holds it, so a second review never moves
#             the first review's head. cleanup releases it.
#   installed Record the current lockfile fingerprint after an install.
#   affected  List the packages and test files the PR touches, so the review
#             runs only those. Full suites come from the PR's CI checks.
#   heavy     Run one install, build or test command under a lock shared by
#             every review on this HQ, so heavy runs never overlap.
#   cleanup   Delete the per-review scratch directory and the PR ref after the
#             review is posted, and release the checkout if this PR holds
#             it. The cached checkout stays. prepare and cleanup run under
#             the same lock as heavy.
#   stray     Report (never delete) leftover per-PR review clones in /tmp.
#
# Usage:
#   review-checkout.sh prepare   --repo OWNER/NAME --pr N [--base BRANCH]
#   review-checkout.sh installed --repo OWNER/NAME
#   review-checkout.sh affected  --repo OWNER/NAME [--base BRANCH]
#   review-checkout.sh heavy     [--timeout SECONDS] -- COMMAND [ARGS...]
#   review-checkout.sh cleanup   --repo OWNER/NAME --pr N
#   review-checkout.sh stray     [--dir DIR]...
#
# Common options:
#   --hq-root DIR      HQ root (default: $HQ_ROOT, else two levels above this
#                      script).
#   --remote-url URL   Clone source for a new cached checkout (default
#                      https://github.com/OWNER/NAME.git).
#
# Environment:
#   HQ_REVIEW_CACHE         Override the cache root
#                           (default <hq-root>/workspace/review-cache).
#   HQ_REVIEW_LOCK_TIMEOUT  Seconds `heavy`, `prepare` and `cleanup` wait for
#                           the lock (default 3600).
#
# Exit codes: 0 ok, 64 usage, 65 bad input, 69 git failure, 73 checkout held
# by another active review, 75 lock timeout;
# `heavy` otherwise exits with the wrapped command's status.

set -euo pipefail

PROG="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { # die <code> <message>
  printf '%s: %s\n' "$PROG" "$2" >&2
  exit "$1"
}

usage() {
  sed -n '/^# Usage:/,/^# Exit codes:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

LOCKFILE_NAMES='package-lock.json pnpm-lock.yaml yarn.lock bun.lock bun.lockb npm-shrinkwrap.json Cargo.lock poetry.lock uv.lock Pipfile.lock Gemfile.lock go.sum composer.lock'
MANIFEST_NAMES='package.json Cargo.toml pyproject.toml go.mod Gemfile composer.json'

CMD="${1:-}"
[ -n "$CMD" ] || usage
shift

REPO=''
PR=''
BASE='main'
HQ_ROOT_ARG=''
REMOTE_URL=''
TIMEOUT="${HQ_REVIEW_LOCK_TIMEOUT:-3600}"
STRAY_DIRS=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --pr) [ "$#" -ge 2 ] || usage; PR="$2"; shift 2 ;;
    --base) [ "$#" -ge 2 ] || usage; BASE="$2"; shift 2 ;;
    --hq-root) [ "$#" -ge 2 ] || usage; HQ_ROOT_ARG="$2"; shift 2 ;;
    --remote-url) [ "$#" -ge 2 ] || usage; REMOTE_URL="$2"; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || usage; TIMEOUT="$2"; shift 2 ;;
    --dir) [ "$#" -ge 2 ] || usage; STRAY_DIRS="$STRAY_DIRS
$2"; shift 2 ;;
    --) shift; break ;;
    -h|--help) usage ;;
    *) [ "$CMD" = heavy ] && break; die 64 "unknown argument: $1" ;;
  esac
done

HQ="${HQ_ROOT_ARG:-${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
[ -d "$HQ" ] || die 65 "HQ root not found: $HQ"
HQ="$(cd "$HQ" && pwd)"
CACHE="${HQ_REVIEW_CACHE:-$HQ/workspace/review-cache}"
REPORTS="$HQ/workspace/reports/reviews"
LOCK="$CACHE/.heavy.lock"

need_repo() {
  [ -n "$REPO" ] || die 64 "--repo OWNER/NAME is required"
  printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
    || die 65 "--repo must look like OWNER/NAME: $REPO"
  case "$REPO" in *..*|.*|*/.*) die 65 "--repo must look like OWNER/NAME: $REPO" ;; esac
  printf '%s' "$BASE" | grep -Eq '^[A-Za-z0-9._/-]+$' || die 65 "bad --base: $BASE"
  case "$BASE" in -*|*..*) die 65 "bad --base: $BASE" ;; esac
  SLUG="${REPO%%/*}__${REPO#*/}"
  CO="$CACHE/$SLUG"
}

need_pr() {
  [ -n "$PR" ] || die 64 "--pr N is required"
  printf '%s' "$PR" | grep -Eq '^[0-9]+$' || die 65 "--pr must be a number: $PR"
  SCRATCH="$CACHE/.scratch/$SLUG-pr-$PR"
  PR_REF="refs/review/pr-$PR"
}

need_checkout() {
  git -C "$CO" rev-parse --git-dir >/dev/null 2>&1 \
    || die 69 "no cached checkout for $REPO at $CO; run '$PROG prepare' first"
}

# Fingerprint of every tracked lockfile at HEAD (path + blob id). Empty when
# the repo tracks no lockfile.
lock_fingerprint() {
  git -C "$CO" ls-tree -r HEAD \
    | awk -v names="$LOCKFILE_NAMES" 'BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
        { path = $0; sub(/^[^\t]*\t/, "", path); base = path; sub(/.*\//, "", base)
          if ((base in want) && path !~ /(^|\/)node_modules\//) print $3 "\t" path }' \
    | LC_ALL=C sort
}

deps_state_file() { printf '%s/hq-review-deps\n' "$(git -C "$CO" rev-parse --absolute-git-dir)"; }

changed_files() { git -C "$CO" diff --name-only "refs/remotes/origin/$BASE...HEAD"; }

release_lock() {
  if [ -f "$LOCK/pid" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$LOCK"
  fi
}

# Take the review lock shared by heavy, prepare and cleanup. Held until this
# process exits.
acquire_lock() {
  printf '%s' "$TIMEOUT" | grep -Eq '^[0-9]+$' || die 65 "--timeout must be whole seconds"
  mkdir -p "$CACHE"
  local start holder announced=0
  start="$(date +%s)"
  while ! mkdir "$LOCK" 2>/dev/null; do
    holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      # Holder is gone. Re-read before removing so a lock taken over by a
      # live process in the meantime is left alone.
      if [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$holder" ]; then
        rm -rf "$LOCK"
      fi
      continue
    fi
    if [ "$announced" = 0 ]; then
      printf '%s: waiting for the review lock (held by pid %s)\n' "$PROG" "${holder:-?}" >&2
      announced=1
    fi
    if [ $(( $(date +%s) - start )) -ge "$TIMEOUT" ]; then
      die 75 "timed out after ${TIMEOUT}s waiting for $LOCK"
    fi
    sleep 1
  done
  printf '%s\n' "$$" > "$LOCK/pid"
  trap release_lock EXIT
  trap 'exit 130' INT TERM HUP
}

# The PR that owns the cached checkout, recorded by prepare and removed by
# that PR's cleanup. Empty when no review is active.
active_file() { printf '%s/hq-review-active\n' "$(git -C "$CO" rev-parse --absolute-git-dir)"; }
active_review() {
  local f
  f="$(active_file)"
  [ -f "$f" ] && sed -n 's/^pr=//p' "$f" | head -1 || true
}

refuse_if_busy() {
  git -C "$CO" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local holder
  holder="$(active_review)"
  if [ -n "$holder" ] && [ "$holder" != "$PR" ]; then
    die 73 "cached checkout $CO is in use by the active review of $REPO PR $holder; finish that review and run '$PROG cleanup --repo $REPO --pr $holder' first (nothing changed)"
  fi
}

cmd_prepare() {
  need_repo; need_pr
  local url="${REMOTE_URL:-https://github.com/$REPO.git}"
  mkdir -p "$CACHE"
  # Fail fast before waiting on the lock, then check again under it.
  refuse_if_busy
  acquire_lock
  refuse_if_busy
  if [ -e "$CO" ] && ! git -C "$CO" rev-parse --git-dir >/dev/null 2>&1; then
    die 69 "$CO exists but is not a git checkout; remove it and run again"
  fi
  if [ ! -e "$CO" ]; then
    git clone -q --no-checkout --filter=blob:none "$url" "$CO" >/dev/null 2>&1 \
      || git clone -q --no-checkout "$url" "$CO" >/dev/null 2>&1 \
      || die 69 "cannot clone $url"
  else
    local have
    have="$(git -C "$CO" remote get-url origin 2>/dev/null || true)"
    [ -z "$REMOTE_URL" ] || [ "$have" = "$REMOTE_URL" ] \
      || die 69 "cached checkout $CO points at $have, not $REMOTE_URL"
  fi
  git -C "$CO" fetch -q --no-tags origin \
    "+refs/heads/$BASE:refs/remotes/origin/$BASE" "+refs/pull/$PR/head:$PR_REF" >/dev/null 2>&1 \
    || die 69 "cannot fetch $BASE and pull/$PR/head for $REPO"
  # A review checkout holds no work of its own: drop tracked edits and
  # untracked files, but keep ignored files (installed dependencies).
  git -C "$CO" reset -q --hard >/dev/null 2>&1 || true
  git -C "$CO" clean -q -fd >/dev/null 2>&1 || true
  git -C "$CO" checkout -q --force --detach "$PR_REF" >/dev/null 2>&1 \
    || die 69 "cannot check out $PR_REF in $CO"
  printf 'pr=%s\n' "$PR" > "$(active_file)"

  local now saved install
  now="$(lock_fingerprint)"
  saved=''
  [ -f "$(deps_state_file)" ] && saved="$(cat "$(deps_state_file)")"
  if [ -z "$now" ]; then
    install=none
  elif [ "$now" = "$saved" ]; then
    install=skip
  else
    install=needed
  fi

  mkdir -p "$SCRATCH" "$REPORTS"
  changed_files > "$SCRATCH/changed-files.txt"
  printf 'checkout=%s\n' "$CO"
  printf 'head=%s\n' "$(git -C "$CO" rev-parse HEAD)"
  printf 'base=origin/%s\n' "$BASE"
  printf 'install=%s\n' "$install"
  printf 'scratch=%s\n' "$SCRATCH"
  printf 'changed=%s\n' "$SCRATCH/changed-files.txt"
  printf 'reports=%s\n' "$REPORTS"
}

cmd_installed() {
  need_repo; need_checkout
  lock_fingerprint > "$(deps_state_file)"
  printf 'recorded lockfile fingerprint for %s at %s\n' "$REPO" "$(git -C "$CO" rev-parse --short HEAD)"
}

cmd_affected() {
  need_repo; need_checkout
  git -C "$CO" rev-parse -q --verify "refs/remotes/origin/$BASE" >/dev/null \
    || die 69 "origin/$BASE is not fetched in $CO; run '$PROG prepare' first"
  local f dir m found base stem seen_pkgs='' seen_tests=''
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Nearest existing directory with a package manifest.
    dir="$(dirname "$f")"
    while :; do
      found=''
      if [ -d "$CO/$dir" ]; then
        for m in $MANIFEST_NAMES; do
          [ -f "$CO/$dir/$m" ] && { found="$dir"; break; }
        done
      fi
      [ -n "$found" ] && break
      [ "$dir" = "." ] && break
      dir="$(dirname "$dir")"
    done
    if [ -n "$found" ]; then
      case "
$seen_pkgs
" in *"
$found
"*) ;; *) seen_pkgs="$seen_pkgs
$found"; printf 'package=%s\n' "$found" ;; esac
    fi
    # Test files: the changed file itself, or tests/<stem>.test.sh next to a
    # changed shell script.
    base="${f##*/}"
    case "$base" in
      *.test.*|*.spec.*|*_test.*|test_*) [ -f "$CO/$f" ] && found="$f" || found='' ;;
      *.sh)
        stem="${base%.sh}"
        found="$(dirname "$f")/tests/$stem.test.sh"
        [ -f "$CO/$found" ] || found=''
        ;;
      *) found='' ;;
    esac
    if [ -n "$found" ]; then
      found="${found#./}"
      case "
$seen_tests
" in *"
$found
"*) ;; *) seen_tests="$seen_tests
$found"; printf 'test=%s\n' "$found" ;; esac
    fi
  done <<EOF
$(changed_files)
EOF
}

cmd_heavy() {
  [ "$#" -gt 0 ] || die 64 "heavy needs a command after --"
  acquire_lock
  local rc=0
  "$@" || rc=$?
  return "$rc"
}

cmd_cleanup() {
  need_repo; need_pr
  local removed=0 released=no holder=''
  case "$SCRATCH" in "$CACHE"/.scratch/*) ;; *) die 65 "refusing to remove $SCRATCH" ;; esac
  acquire_lock
  if [ -e "$SCRATCH" ]; then
    rm -rf "$SCRATCH"
    removed=1
  fi
  if git -C "$CO" rev-parse --git-dir >/dev/null 2>&1; then
    holder="$(active_review)"
    git -C "$CO" update-ref -d "$PR_REF" >/dev/null 2>&1 || true
    # Only the review that owns the checkout may clean its working tree or
    # release it; another PR's cleanup leaves the active review's files alone.
    if [ -z "$holder" ] || [ "$holder" = "$PR" ]; then
      git -C "$CO" clean -q -fd >/dev/null 2>&1 || true
      rm -f "$(active_file)"
      [ "$holder" = "$PR" ] && released=yes
    fi
  fi
  printf 'cleaned %s pr %s (scratch removed: %s, checkout released: %s); cached checkout kept at %s\n' \
    "$REPO" "$PR" "$([ "$removed" = 1 ] && echo yes || echo no)" "$released" "$CO"
}

cmd_stray() {
  local dirs d p kb
  dirs="$STRAY_DIRS"
  [ -n "$dirs" ] || dirs="/tmp
${TMPDIR:-/tmp}"
  printf '%s\n' "$dirs" | while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    (cd "$d" && pwd -P)
  done | LC_ALL=C sort -u | while IFS= read -r d; do
    for p in "$d"/rv-* "$d"/rev-* "$d"/review-* "$d"/pr-* "$d"/hq-review-*; do
      [ -d "$p/.git" ] || [ -f "$p/.git" ] || continue
      kb="$(du -sk "$p" 2>/dev/null | awk '{print $1}')"
      printf 'stray=%s\t%s KB\n' "$p" "${kb:-?}"
    done
  done
}

case "$CMD" in
  prepare) cmd_prepare ;;
  installed) cmd_installed ;;
  affected) cmd_affected ;;
  heavy) cmd_heavy "$@" ;;
  cleanup) cmd_cleanup ;;
  stray) cmd_stray ;;
  -h|--help|help) usage ;;
  *) die 64 "unknown command: $CMD" ;;
esac
