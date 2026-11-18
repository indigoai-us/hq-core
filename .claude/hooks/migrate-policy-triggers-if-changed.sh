#!/bin/bash
# hq-core: public
# migrate-policy-triggers-if-changed.sh — SessionStart hook.
#
# Runs core/scripts/migrate-policy-triggers.sh (the generated forwarder to
# `hq core migrate-policy-triggers`) only when a policy file or policy
# directory changed since the last successful run. The migration is idempotent
# over policy files, so an unchanged tree has nothing to do, and starting the hq
# CLI twice (version-floor probe + command) costs every session about 2 s.
#
# Two stamps can show that the tree is already migrated:
#   * this hook's own stamp (below), and
#   * the success stamp `hq core migrate-policy-triggers` writes itself, at
#     <state dir>/<scope hash>/last-success. /update-hq runs the forwarder
#     directly, so after an update only that stamp is fresh. Its path is
#     resolved here in bash, with no hq or node process, the same way the
#     native command computes it. A root the migration has not run for has no
#     such stamp, so it still migrates here.
# The hook exits at once when either stamp is current. It re-runs when:
#   * any file or directory under core/policies, personal/policies,
#     companies/*/policies, companies/*/workers/*/policies, or
#     personal/workers/*/policies is newer than the stamp
#   * the hq binary is newer than the stamp (migration rules ship with hq)
#   * HQ_MIGRATE_TRIGGERS_FORCE=1
#   * no stamp exists yet, or a stamp is missing, unreadable or malformed
#
# The hook's own stamp is dated from BEFORE the run and kept only on exit 0, so
# a failing run, or a policy edited while the migration was running, is never
# masked. The native command writes its stamp only after a successful run.
# The forwarder itself is untouched: its ABI (and the cli-hosted manifest that
# generates it) stay exactly as shipped. hq-hook-perf HP-7.

set -uo pipefail

# Consume stdin (master-hook pipes the event JSON).
cat >/dev/null 2>&1 || true

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd)}}"
[ -n "$HQ_ROOT" ] || exit 0

FORWARDER="$HQ_ROOT/core/scripts/migrate-policy-triggers.sh"
[ -f "$FORWARDER" ] || exit 0

STATE_DIR="$HQ_ROOT/workspace/orchestrator/policy-trigger-state"
STAMP="$STATE_DIR/migrate-policy-triggers.stamp"

hq_bin="$(command -v hq 2>/dev/null || true)"
policy_dirs=()
for _d in "$HQ_ROOT/core/policies" "$HQ_ROOT/personal/policies" \
          "$HQ_ROOT"/companies/*/policies "$HQ_ROOT"/companies/*/workers/*/policies \
          "$HQ_ROOT"/personal/workers/*/policies; do
  [ -d "$_d" ] && policy_dirs+=("$_d")
done

# True only when $1 is a readable regular file newer than the hq binary and
# than every policy file and directory. A stamp that vanishes mid-check, or a
# find that fails, is not a pass.
stamp_is_current() {
  local stamp="$1" changed
  [ -f "$stamp" ] && [ -r "$stamp" ] || return 1
  if [ -n "$hq_bin" ] && [ "$hq_bin" -nt "$stamp" ]; then return 1; fi
  [ "${#policy_dirs[@]}" -gt 0 ] || return 1
  # One find over the tree is the only check. A directory mtime cannot stand
  # in for it: an in-place edit does not change its parent's mtime, and a new
  # file in a subfolder changes only that subfolder's. The output is captured
  # whole (no head) to avoid a second process on the no-change path.
  changed="$(find "${policy_dirs[@]}" \
    -newer "$stamp" \( -type d -o -type f -name '*.md' \) -print 2>/dev/null)" || return 1
  [ -z "$changed" ]
}

# Physical path of directory $1 into _mpt_dir, with builtins only.
_mpt_physical_dir() {
  local here="$PWD"
  cd -P -- "$1" 2>/dev/null || return 1
  _mpt_dir="$PWD"
  cd -- "$here" 2>/dev/null || return 1
}

# Entries of directory $1 in byte order, dot entries included (readdirSync
# lists them), into _mpt_entries.
_mpt_list_dir() {
  local LC_ALL=C dotglob_was=0 nullglob_was=0 _e
  _mpt_entries=()
  [ -d "$1" ] || return 0
  shopt -q dotglob && dotglob_was=1
  shopt -q nullglob && nullglob_was=1
  shopt -s dotglob nullglob
  for _e in "$1"/*; do _mpt_entries+=("${_e##*/}"); done
  [ "$dotglob_was" = 1 ] || shopt -u dotglob
  [ "$nullglob_was" = 1 ] || shopt -u nullglob
}

# Append the bytes of $1, then a NUL, to _mpt_bytes.
_mpt_push() {
  local LC_ALL=C s="$1" i c n
  n=${#s}
  for ((i = 0; i < n; i++)); do
    printf -v c '%d' "'${s:i:1}"
    _mpt_bytes[${#_mpt_bytes[@]}]=$(( c & 255 ))
  done
  _mpt_bytes[${#_mpt_bytes[@]}]=0
}

# SHA-256 (FIPS 180-4) of _mpt_bytes as hex into _mpt_hex, in bash arithmetic.
_mpt_sha256() {
  local -a K=(
    0x428a2f98 0x71374491 0xb5c0fbcf 0xe9b5dba5 0x3956c25b 0x59f111f1 0x923f82a4 0xab1c5ed5
    0xd807aa98 0x12835b01 0x243185be 0x550c7dc3 0x72be5d74 0x80deb1fe 0x9bdc06a7 0xc19bf174
    0xe49b69c1 0xefbe4786 0x0fc19dc6 0x240ca1cc 0x2de92c6f 0x4a7484aa 0x5cb0a9dc 0x76f988da
    0x983e5152 0xa831c66d 0xb00327c8 0xbf597fc7 0xc6e00bf3 0xd5a79147 0x06ca6351 0x14292967
    0x27b70a85 0x2e1b2138 0x4d2c6dfc 0x53380d13 0x650a7354 0x766a0abb 0x81c2c92e 0x92722c85
    0xa2bfe8a1 0xa81a664b 0xc24b8b70 0xc76c51a3 0xd192e819 0xd6990624 0xf40e3585 0x106aa070
    0x19a4c116 0x1e376c08 0x2748774c 0x34b0bcb5 0x391c0cb3 0x4ed8aa4a 0x5b9cca4f 0x682e6ff3
    0x748f82ee 0x78a5636f 0x84c87814 0x8cc70208 0x90befffa 0xa4506ceb 0xbef9a3f7 0xc67178f2)
  local -a H=(0x6a09e667 0xbb67ae85 0x3c6ef372 0xa54ff53a 0x510e527f 0x9b05688c 0x1f83d9ab 0x5be0cd19)
  local -a b=("${_mpt_bytes[@]}") w=()
  local M=0xFFFFFFFF n=${#_mpt_bytes[@]} bits i t blk x s0 s1 t1 t2 a bb c d e f g h
  bits=$(( n * 8 ))
  b[n]=128
  i=$(( n + 1 ))
  while (( i % 64 != 56 )); do b[i]=0; i=$(( i + 1 )); done
  for ((t = 56; t >= 0; t -= 8)); do b[i]=$(( (bits >> t) & 255 )); i=$(( i + 1 )); done
  for ((blk = 0; blk < i; blk += 64)); do
    for ((t = 0; t < 16; t++)); do
      x=$(( blk + t * 4 ))
      w[t]=$(( (b[x] << 24) | (b[x + 1] << 16) | (b[x + 2] << 8) | b[x + 3] ))
    done
    for ((t = 16; t < 64; t++)); do
      x=${w[t - 15]}; s0=$(( (((x >> 7) | (x << 25)) ^ ((x >> 18) | (x << 14)) ^ (x >> 3)) & M ))
      x=${w[t - 2]};  s1=$(( (((x >> 17) | (x << 15)) ^ ((x >> 19) | (x << 13)) ^ (x >> 10)) & M ))
      w[t]=$(( (w[t - 16] + s0 + w[t - 7] + s1) & M ))
    done
    a=${H[0]} bb=${H[1]} c=${H[2]} d=${H[3]} e=${H[4]} f=${H[5]} g=${H[6]} h=${H[7]}
    for ((t = 0; t < 64; t++)); do
      t1=$(( (h + ((((e >> 6) | (e << 26)) ^ ((e >> 11) | (e << 21)) ^ ((e >> 25) | (e << 7))) & M) \
        + ((e & f) ^ (~e & g)) + K[t] + w[t]) & M ))
      t2=$(( (((((a >> 2) | (a << 30)) ^ ((a >> 13) | (a << 19)) ^ ((a >> 22) | (a << 10))) & M) \
        + ((a & bb) ^ (a & c) ^ (bb & c))) & M ))
      h=$g g=$f f=$e e=$(( (d + t1) & M )) d=$c c=$bb bb=$a a=$(( (t1 + t2) & M ))
    done
    H[0]=$(( (H[0] + a) & M )) H[1]=$(( (H[1] + bb) & M )) H[2]=$(( (H[2] + c) & M ))
    H[3]=$(( (H[3] + d) & M )) H[4]=$(( (H[4] + e) & M )) H[5]=$(( (H[5] + f) & M ))
    H[6]=$(( (H[6] + g) & M )) H[7]=$(( (H[7] + h) & M ))
  done
  printf -v _mpt_hex '%08x' "${H[@]}"
}

# The last non-empty, slash-free segment after <marker> ($2) in $1, as the
# JavaScript regex `.*<marker>([^/]+)` picks it, into _mpt_seg; the text
# before that marker into _mpt_pre.
_mpt_last_segment() {
  local s="$1" marker="$2" rest
  _mpt_seg="" _mpt_pre=""
  while :; do
    case "$s" in *"$marker"*) ;; *) return 1 ;; esac
    rest="${s##*"$marker"}"
    _mpt_pre="${s%"$marker"*}"
    _mpt_seg="${rest%%/*}"
    [ -z "$_mpt_seg" ] || return 0
    s="$_mpt_pre"
  done
}

# The native command's success stamp for the scope this hook's forwarder run
# uses, into NATIVE_STAMP. Mirrors runMigratePolicyTriggers in hq-cli
# (src/commands/core-migrate-policy-triggers-native.ts): the state dir, then
# sha256 of "<root>\0" and "<dir>\0" for each default policy dir, in its
# order. Returns 1 when the path cannot be computed; that is never a pass. Any
# difference from hq's own scope gives a different hash, so no stamp is found
# and the migration runs.
native_stamp_path() {
  local state="${HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR:-}" root logical company entry
  local pub_pre="" pub_seg="" priv_pre="" priv_seg="" repo=""
  if [ -z "$state" ]; then
    if [ -n "${XDG_STATE_HOME:-}" ]; then state="$XDG_STATE_HOME/hq-migrate-policy-triggers"
    elif [ -n "${HOME:-}" ]; then state="$HOME/.local/state/hq-migrate-policy-triggers"
    else return 1
    fi
  fi
  # hq resolves --hq-root with realpath.
  _mpt_physical_dir "$HQ_ROOT" || return 1
  root="$_mpt_dir"
  case "$root" in /?*) ;; *) return 1 ;; esac
  # hq reads the company and repo from CLAUDE_PROJECT_DIR, else its own cwd.
  logical="${CLAUDE_PROJECT_DIR:-}"
  if [ -z "$logical" ]; then
    _mpt_physical_dir . || return 1
    logical="$_mpt_dir"
  fi
  case "$logical" in *$'\n'*) return 1 ;; esac

  _mpt_bytes=()
  _mpt_push "$root"
  _mpt_push "$root/core/policies"
  _mpt_push "$root/personal/policies"
  _mpt_list_dir "$root/personal/workers"
  for entry in ${_mpt_entries[@]+"${_mpt_entries[@]}"}; do
    [ -d "$root/personal/workers/$entry/policies" ] && _mpt_push "$root/personal/workers/$entry/policies"
  done
  company="${HQ_POLICY_COMPANY:-}"
  if [ -z "$company" ] && _mpt_last_segment "$logical" "companies/"; then company="$_mpt_seg"; fi
  case "$company" in .|..|*/*) company="" ;; esac
  if [ -n "$company" ]; then
    _mpt_push "$root/companies/$company/policies"
    _mpt_list_dir "$root/companies/$company/workers"
    for entry in ${_mpt_entries[@]+"${_mpt_entries[@]}"}; do
      [ -d "$root/companies/$company/workers/$entry/policies" ] \
        && _mpt_push "$root/companies/$company/workers/$entry/policies"
    done
  fi
  # `.*repos/(public|private)/([^/]+)`: the later of the two matches wins.
  if _mpt_last_segment "$logical" "repos/public/"; then pub_pre="$_mpt_pre" pub_seg="$_mpt_seg"; fi
  if _mpt_last_segment "$logical" "repos/private/"; then priv_pre="$_mpt_pre" priv_seg="$_mpt_seg"; fi
  if [ -n "$pub_seg" ] && { [ -z "$priv_seg" ] || [ "${#pub_pre}" -gt "${#priv_pre}" ]; }; then
    repo="public/$pub_seg"
  elif [ -n "$priv_seg" ]; then
    repo="private/$priv_seg"
  fi
  [ -z "$repo" ] || _mpt_push "$root/repos/$repo/.claude/policies"

  _mpt_sha256
  NATIVE_STAMP="$state/$_mpt_hex/last-success"
}

# The native stamp holds the run's epoch seconds. Anything else is not a pass
# (the native command treats it as unreadable too).
native_stamp_valid() {
  local v=""
  { IFS= read -r v < "$1"; } 2>/dev/null || [ -n "$v" ] || return 1
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
}

if [ "${HQ_MIGRATE_TRIGGERS_FORCE:-0}" != "1" ]; then
  stamp_is_current "$STAMP" && exit 0
  if native_stamp_path && native_stamp_valid "$NATIVE_STAMP" && stamp_is_current "$NATIVE_STAMP"; then
    exit 0
  fi
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true
: > "$STAMP.new" 2>/dev/null || true
rc=0
bash "$FORWARDER" </dev/null || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$STAMP.new" ]; then
  mv -f "$STAMP.new" "$STAMP" 2>/dev/null || true
else
  rm -f "$STAMP.new" 2>/dev/null || true
fi
exit "$rc"
