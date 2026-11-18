#!/usr/bin/env bash
# hq-core: public
# safe-store.test.sh — core/scripts/lib/safe-store.sh refuses entries planted
# before a call, holds the checked folder through each action, and never exits
# its caller.
#
# Sections:
#   [a] hq_store_name_ok: separators, '..', ':', leading '-', control characters
#   [b] hq_store_preflight: every folder from root to file, builtins only (it
#       runs with an empty PATH)
#   [c] hq_store_dir_ok, hq_store_file_ok, hq_store_mkdir: modes, links, owner
#   [d] the pre-placed matrix for append, write_atomic, read, remove, rename
#       and claim: symlink, dangling symlink, hard link, FIFO, folder, group-
#       and other-writable file at the store file; symlinked, group- and
#       other-writable store folder; nothing is written in the target
#   [e] working paths: create, append, replace, read cap, remove, rename,
#       rmdir, claim, quarantine
#   [f] injected races: the store folder swapped for a link after the check;
#       the action stays in the checked folder and returns 3; an entry swapped
#       for a link right before the open is refused by the descriptor check
#   [g] callers: set -euo pipefail, noclobber, umask 000, CDPATH, cwd kept
#   [h] foreign owner (read-only checks of system folders; not as root)
#
# HQ_TEST_BASH=/path/to/bash runs this file under that bash (for example
# /bin/bash 3.2 on macOS).
#
# SC2319: each check passes the status of the test before it on purpose.
# SC2123: [b] empties PATH on purpose to show preflight starts no process.
# shellcheck disable=SC2319,SC2123
if [ -n "${HQ_TEST_BASH:-}" ] && [ "${_HQ_SAFE_STORE_TEST_REEXEC:-}" != 1 ]; then
  _HQ_SAFE_STORE_TEST_REEXEC=1 exec "$HQ_TEST_BASH" "$0" "$@"
fi
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
LIB="$ROOT/core/scripts/lib/safe-store.sh"
# shellcheck source=../lib/safe-store.sh
. "$LIB"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
# expect <want-rc> <got-rc> <label>
expect() {
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (rc $2, want $1; reason: ${HQ_STORE_REASON:-none})"; fi
}
truthy() {
  if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi
}

printf '# bash %s\n' "$BASH_VERSION"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/safe-store-test.XXXXXX")"
TMP="$(cd -P "$TMP" && pwd -P)"
cleanup() { chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
umask 022

n=0
# fresh — a new 0700 store folder in D and a victim file and folder outside it.
fresh() {
  n=$((n + 1))
  D="$TMP/s$n/store"
  V="$TMP/s$n/victim.txt"
  VD="$TMP/s$n/victim-dir"
  mkdir -p "$TMP/s$n" "$VD"
  mkdir "$D"
  chmod 700 "$D"
  printf 'VICTIM\n' > "$V"
}
# file_text <path> — the content of a regular file; prints nothing for a FIFO,
# folder or anything else, so a helper that leaves a FIFO at a store name
# makes a check fail instead of hanging the test.
file_text() {
  [ -f "$1" ] && cat "$1"
}
victim_intact() {
  [ "$(file_text "$V")" = "VICTIM" ] && [ -z "$(ls -A "$VD")" ]
}
mode_of() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# bounded <seconds> <cmd>... — run in the background; rc 124 if it hangs.
bounded() {
  local secs="$1" pid i=0 limit
  shift
  "$@" </dev/null >/dev/null 2>&1 &
  pid=$!
  limit=$((secs * 10))
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt "$limit" ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.1
  done
  wait "$pid"
}

echo "[a] hq_store_name_ok"
for good in abc a.b ses-1234_ABCD.held 0f8e2c1a-3b4d-4e5f-8a9b-0c1d2e3f4a5b.seen.tsv; do
  hq_store_name_ok "$good"; expect 0 $? "name accepted: $good"
done
long="$(printf '%0256d' 0)"
for badname in "" . .. a/b ../x /abs -rf 'a\b' a:b a..b "$(printf 'a\tb')" "$long"; do
  hq_store_name_ok "$badname"; expect 1 $? "name refused: $(printf '%q' "$badname" | cut -c1-40)"
done
hq_store_name_ok $'a\nb'; expect 1 $? "name refused: newline"
hq_store_name_ok $'a\rb'; expect 1 $? "name refused: carriage return"

echo "[b] hq_store_preflight"
fresh
mkdir -p "$D/hq/flags"; chmod 700 "$D/hq" "$D/hq/flags"
printf '{"x":true}\n' > "$D/hq/flags/snap.json"
hq_store_preflight "$D" "$D/hq/flags/snap.json"; expect 0 $? "preflight: clean path"
hq_store_preflight "$D/" "$D/hq/flags/snap.json"; expect 0 $? "preflight: root with trailing slash"
hq_store_preflight "$D" "$D/hq/flags/none.json"; expect 2 $? "preflight: absent file"
hq_store_preflight "$D" "$D/hq/nope/snap.json"; expect 2 $? "preflight: absent folder"
hq_store_preflight "$D.none" "$D.none/hq/x"; expect 2 $? "preflight: absent root"
hq_store_preflight "$D" "$V"; expect 1 $? "preflight: file outside root"
hq_store_preflight "$D" "$D/hq/../hq/flags/snap.json"; expect 1 $? "preflight: '..' part"
hq_store_preflight "$D" "$D/hq//flags/snap.json"; expect 1 $? "preflight: empty part"
ln -s "$V" "$D/hq/flags/link.json"
hq_store_preflight "$D" "$D/hq/flags/link.json"; expect 1 $? "preflight: symlink file"
ln -s "$TMP/s$n/nowhere" "$D/hq/flags/dangling.json"
hq_store_preflight "$D" "$D/hq/flags/dangling.json"; expect 1 $? "preflight: dangling symlink file"
mkfifo "$D/hq/flags/fifo.json"
hq_store_preflight "$D" "$D/hq/flags/fifo.json"; expect 1 $? "preflight: FIFO"
mkdir "$D/hq/flags/dir.json"
hq_store_preflight "$D" "$D/hq/flags/dir.json"; expect 1 $? "preflight: folder at the file"
mkdir -p "$VD/flags"; printf 'x\n' > "$VD/flags/snap.json"
ln -s "$VD" "$D/linked"
hq_store_preflight "$D" "$D/linked/flags/snap.json"; expect 1 $? "preflight: symlinked middle folder"
ln -s "$D" "$TMP/s$n/rootlink"
hq_store_preflight "$TMP/s$n/rootlink" "$TMP/s$n/rootlink/hq/flags/snap.json"; expect 1 $? "preflight: symlinked root"
mkdir "$TMP/s$n/empty-path"
out="$( { PATH="$TMP/s$n/empty-path"; hash -r; hq_store_preflight "$D" "$D/hq/flags/snap.json"; echo "rc=$?"; hq_store_preflight "$D" "$D/hq/flags/link.json"; echo "rc=$?"; } 2>&1 )"
if [ "$out" = "rc=0${_HQ_STORE_NL}rc=1" ]; then ok "preflight: runs with an empty PATH (builtins only)"; else bad "preflight: runs with an empty PATH ($out)"; fi

echo "[c] hq_store_dir_ok, hq_store_file_ok, hq_store_mkdir"
fresh
hq_store_dir_ok "$D"; expect 0 $? "dir_ok: 0700"
chmod 750 "$D"; hq_store_dir_ok "$D"; expect 0 $? "dir_ok: 0750"
chmod 770 "$D"; hq_store_dir_ok "$D"; expect 1 $? "dir_ok: 0770 group-writable"
chmod 707 "$D"; hq_store_dir_ok "$D"; expect 1 $? "dir_ok: 0707 other-writable"
chmod 1777 "$D"; hq_store_dir_ok "$D"; expect 1 $? "dir_ok: 1777 sticky world-writable"
chmod 700 "$D"
ln -s "$D" "$TMP/s$n/dlink"; hq_store_dir_ok "$TMP/s$n/dlink"; expect 1 $? "dir_ok: symlink"
hq_store_dir_ok "$TMP/s$n/none"; expect 2 $? "dir_ok: absent"
hq_store_dir_ok "$V"; expect 1 $? "dir_ok: a file"
printf 'a\n' > "$D/f"; chmod 600 "$D/f"
hq_store_file_ok "$D/f"; expect 0 $? "file_ok: 0600"
chmod 640 "$D/f"; hq_store_file_ok "$D/f"; expect 0 $? "file_ok: 0640"
chmod 660 "$D/f"; hq_store_file_ok "$D/f"; expect 1 $? "file_ok: 0660 group-writable"
chmod 606 "$D/f"; hq_store_file_ok "$D/f"; expect 1 $? "file_ok: 0606 other-writable"
chmod 600 "$D/f"
ln "$D/f" "$D/hard"; hq_store_file_ok "$D/f"; expect 1 $? "file_ok: two links"
ln -s "$V" "$D/l"; hq_store_file_ok "$D/l"; expect 1 $? "file_ok: symlink"
ln -s "$TMP/s$n/nowhere" "$D/dl"; hq_store_file_ok "$D/dl"; expect 1 $? "file_ok: dangling symlink"
mkfifo "$D/p"; hq_store_file_ok "$D/p"; expect 1 $? "file_ok: FIFO"
mkdir "$D/sub"; hq_store_file_ok "$D/sub"; expect 1 $? "file_ok: folder"
hq_store_file_ok "$D/none"; expect 2 $? "file_ok: absent"
fresh
hq_store_mkdir "$D/new"; expect 0 $? "mkdir: creates"
[ "$(mode_of "$D/new")" = 700 ]; truthy $? "mkdir: mode 0700 under umask 022"
hq_store_mkdir "$D/new"; expect 0 $? "mkdir: existing private folder accepted"
ln -s "$VD" "$D/lnk"; hq_store_mkdir "$D/lnk"; expect 1 $? "mkdir: symlink refused"
[ -z "$(ls -A "$VD")" ]; truthy $? "mkdir: symlink target untouched"
mkdir "$D/open"; chmod 777 "$D/open"; hq_store_mkdir "$D/open"; expect 1 $? "mkdir: 0777 folder refused"
[ "$(mode_of "$D/open")" = 777 ]; truthy $? "mkdir: refused folder mode not changed"
hq_store_mkdir "$TMP/s$n/no/such/parent"; expect 4 $? "mkdir: missing parent"
mkdir "$D/open-parent"; chmod 777 "$D/open-parent"
hq_store_mkdir "$D/open-parent/child"; expect 1 $? "mkdir: refused parent, nothing created"
[ ! -e "$D/open-parent/child" ]; truthy $? "mkdir: no child under a refused parent"
( cd "$D" && hq_store_mkdir relchild ); expect 0 $? "mkdir: relative name under the working folder"

echo "[c2] trailing '/', '/.' and '/..' on folder paths"
fresh
ln -s "$VD" "$D/link"
ln -s "$TMP/s$n/nowhere" "$D/dangling"
mkdir "$D/real"; chmod 700 "$D/real"
for p in "$D/link/" "$D/link//" "$D/link/." "$D/real/.." "$D/real/." "/" "."; do
  hq_store_dir_ok "$p"; expect 1 $? "dir_ok refuses $(printf '%s' "$p" | sed "s#$TMP#TMP#")"
  hq_store_append "$p" x <<< "NEW"; expect 1 $? "append refuses folder $(printf '%s' "$p" | sed "s#$TMP#TMP#")"
  hq_store_write_atomic "$p" x <<< "NEW"; expect 1 $? "write_atomic refuses folder $(printf '%s' "$p" | sed "s#$TMP#TMP#")"
done
hq_store_dir_ok "$D/real/"; expect 0 $? "dir_ok accepts a real folder with a trailing '/'"
for p in "$D/dangling/" "$D/link/" "$D/link/."; do
  hq_store_mkdir "$p"; expect 1 $? "mkdir refuses $(printf '%s' "$p" | sed "s#$TMP#TMP#")"
done
[ ! -e "$TMP/s$n/nowhere" ] && [ -z "$(ls -A "$VD")" ]; truthy $? "trailing '/': link targets not created or written"
hq_store_preflight "$D/link/." "$D/link/./x"; expect 1 $? "preflight refuses a root ending in '/.'"
printf 'f\n' > "$D/real/f"; chmod 600 "$D/real/f"
hq_store_file_ok "$D/real/f/"; expect 1 $? "file_ok refuses a file path ending in '/'"

echo "[c3] hq_store_read: bytes and NUL"
fresh
printf 'a\000b\n' > "$D/nul"; chmod 600 "$D/nul"
hq_store_read "$D" nul > "$TMP/read.out"; expect 1 $? "read: file with a NUL byte refused"
[ ! -s "$TMP/read.out" ]; truthy $? "read: nothing printed for a NUL file"
printf '\303\251\303\251\303\251' > "$D/utf"; chmod 600 "$D/utf"
utf8=""
for loc in C.UTF-8 en_US.UTF-8 C.utf8; do
  if [ "$(LC_ALL="$loc" bash -c 'x=$(printf "\303\251"); printf %s ${#x}' 2>/dev/null)" = 1 ]; then utf8="$loc"; break; fi
done
if [ -n "$utf8" ]; then
  ( export LC_ALL="$utf8"; hq_store_read "$D" utf 5 > "$TMP/read.out" ); expect 1 $? "read: cap counts bytes under $utf8 (6 bytes, cap 5)"
  ( export LC_ALL="$utf8"; hq_store_read "$D" utf 6 > "$TMP/read.out" ); expect 0 $? "read: 6 bytes under cap 6 under $utf8"
  [ "$(wc -c < "$TMP/read.out" | tr -d ' ')" = 6 ]; truthy $? "read: all 6 bytes printed under $utf8"
else
  echo "# no UTF-8 locale on this machine: the locale cap check did not run"
fi

echo "[d] pre-placed matrix"
op_append() { hq_store_append "$1" "$2" <<< "NEW"; }
op_write() { hq_store_write_atomic "$1" "$2" <<< "NEW"; }
op_read() { hq_store_read "$1" "$2" > "$TMP/read.out"; }
op_remove() { hq_store_remove "$1" "$2"; }
op_rename() { hq_store_rename "$1" "$2" renamed; }
op_claim() { hq_store_claim "$1" "$2"; }
# no_new_files — nothing but the planted entry is in the store folder.
only_entry() {
  [ "$(ls -A "$D")" = "$1" ]
}
for op in append write read remove rename claim; do
  fresh; ln -s "$V" "$D/s"
  "op_$op" "$D" s; rc=$?
  expect 1 "$rc" "$op: symlink at the file refused"
  victim_intact && [ -L "$D/s" ] && only_entry s; truthy $? "$op: symlink target and link untouched"

  fresh; ln -s "$TMP/s$n/nowhere" "$D/s"
  "op_$op" "$D" s; rc=$?
  expect 1 "$rc" "$op: dangling symlink refused"
  [ ! -e "$TMP/s$n/nowhere" ] && only_entry s; truthy $? "$op: dangling target not created"

  fresh; ln "$V" "$D/s"
  "op_$op" "$D" s; rc=$?
  expect 1 "$rc" "$op: hard link refused"
  victim_intact && [ -f "$D/s" ] && only_entry s; truthy $? "$op: hard-linked file untouched"

  fresh; mkfifo "$D/s"
  bounded 10 "op_$op" "$D" s; rc=$?
  expect 1 "$rc" "$op: FIFO refused without blocking"
  [ -p "$D/s" ] && only_entry s; truthy $? "$op: FIFO left in place"

  if [ "$op" != claim ]; then
    fresh; mkdir "$D/s"
    "op_$op" "$D" s; rc=$?
    expect 1 "$rc" "$op: folder at the file refused"
    [ -d "$D/s" ] && [ -z "$(ls -A "$D/s")" ] && only_entry s; truthy $? "$op: folder left empty"
  fi

  for m in 660 606; do
    fresh; printf 'OLD\n' > "$D/s"; chmod "$m" "$D/s"
    "op_$op" "$D" s; rc=$?
    expect 1 "$rc" "$op: file mode $m refused"
    [ "$(file_text "$D/s")" = OLD ] && only_entry s; truthy $? "$op: file mode $m content untouched"
  done

  fresh; printf 'OLD\n' > "$TMP/s$n/victim-dir/s"; rm -rf "$D"; ln -s "$VD" "$D"
  "op_$op" "$D" s; rc=$?
  expect 1 "$rc" "$op: symlinked store folder refused"
  [ "$(file_text "$VD/s")" = OLD ] && [ "$(ls -A "$VD")" = s ]; truthy $? "$op: linked folder untouched"

  for m in 770 707; do
    fresh; printf 'OLD\n' > "$D/s"; chmod 600 "$D/s"; chmod "$m" "$D"
    "op_$op" "$D" s; rc=$?
    expect 1 "$rc" "$op: store folder mode $m refused"
    [ "$(file_text "$D/s")" = OLD ] && only_entry s; truthy $? "$op: folder mode $m content untouched"
  done
done
[ ! -s "$TMP/read.out" ]; truthy $? "read: printed nothing on any refusal"
# rename and write_atomic targets
fresh; printf 'A\n' > "$D/a"; chmod 600 "$D/a"; ln -s "$V" "$D/b"
hq_store_rename "$D" a b; expect 1 $? "rename: symlink at the target refused"
victim_intact && [ -L "$D/b" ] && [ -f "$D/a" ]; truthy $? "rename: target link and source untouched"
fresh; printf 'A\n' > "$D/a"; chmod 600 "$D/a"; mkdir "$D/b"
hq_store_rename "$D" a b; expect 1 $? "rename: folder at the target refused"
[ -f "$D/a" ] && [ -z "$(ls -A "$D/b")" ]; truthy $? "rename: nothing moved into the folder"
fresh; printf 'OLD\n' > "$D/s"; chmod 600 "$D/s"
hq_store_append "$D" "../victim.txt" <<< "NEW"; expect 1 $? "append: '..' name refused"
victim_intact; truthy $? "append: '..' name wrote nothing"
hq_store_write_atomic "$D" "-x" <<< "NEW"; expect 1 $? "write_atomic: leading '-' name refused"

echo "[d2] a refused store folder: every function changes nothing on disk"
# tree_state <dir> — names, types, modes and file contents under <dir>.
tree_state() {
  local p
  find "$1" | LC_ALL=C sort | while IFS= read -r p; do
    if [ -L "$p" ]; then
      printf 'L %s\n' "$p"
    elif [ -d "$p" ]; then
      printf 'D %s %s\n' "$p" "$(mode_of "$p")"
    elif [ -f "$p" ]; then
      printf 'F %s %s %s\n' "$p" "$(mode_of "$p")" "$(file_text "$p")"
    else
      printf 'O %s\n' "$p"
    fi
  done
}
# populate <dir> — a store file s, an empty folder e and a held folder h.
populate() {
  printf 'OLD\n' > "$1/s"; chmod 600 "$1/s"
  mkdir "$1/e" "$1/h"; chmod 700 "$1/e" "$1/h"
  printf 'held\n' > "$1/h/out"; chmod 600 "$1/h/out"
}
refused_calls() {
  hq_store_append "$1" new <<< "NEW"; printf 'append-new %s\n' "$?"
  hq_store_append "$1" s <<< "NEW"; printf 'append-existing %s\n' "$?"
  hq_store_write_atomic "$1" new <<< "NEW"; printf 'write_atomic-new %s\n' "$?"
  hq_store_write_atomic "$1" s <<< "NEW"; printf 'write_atomic-existing %s\n' "$?"
  hq_store_read "$1" s > "$TMP/read.out"; printf 'read %s %s\n' "$?" "$(wc -c < "$TMP/read.out" | tr -d ' ')"
  hq_store_remove "$1" s; printf 'remove %s\n' "$?"
  hq_store_rename "$1" s t; printf 'rename %s\n' "$?"
  hq_store_rmdir "$1" e; printf 'rmdir %s\n' "$?"
  hq_store_claim "$1" s; printf 'claim-file %s\n' "$?"
  hq_store_claim "$1" h; printf 'claim-folder %s\n' "$?"
  hq_store_quarantine "$1" s; printf 'quarantine-file %s\n' "$?"
  hq_store_quarantine "$1" e; printf 'quarantine-folder %s\n' "$?"
  hq_store_mkdir "$1/newdir"; printf 'mkdir-child %s\n' "$?"
}
for m in 777 770 707 1777; do
  fresh; populate "$D"; chmod "$m" "$D"
  before="$(tree_state "$TMP/s$n")"
  calls="$(refused_calls "$D")"
  after="$(tree_state "$TMP/s$n")"
  while IFS= read -r line; do
    case "$line" in
      "read 1 0"|*" 1") ok "folder mode $m: $line (refused)" ;;
      *) bad "folder mode $m: $line (want rc 1, nothing printed)" ;;
    esac
  done <<< "$calls"
  if [ "$before" = "$after" ]; then ok "folder mode $m: nothing created, removed, moved or changed"; else bad "folder mode $m: tree changed"; diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -10; fi
done
fresh; populate "$VD"; rm -rf "$D"; ln -s "$VD" "$D"
before="$(tree_state "$TMP/s$n")"
calls="$(refused_calls "$D")"
after="$(tree_state "$TMP/s$n")"
while IFS= read -r line; do
  case "$line" in
    "read 1 0"|*" 1") ok "symlinked folder: $line (refused)" ;;
    *) bad "symlinked folder: $line (want rc 1, nothing printed)" ;;
  esac
done <<< "$calls"
if [ "$before" = "$after" ]; then ok "symlinked folder: link target unchanged"; else bad "symlinked folder: link target changed"; fi

echo "[d3] a refused child in a private store folder is left in place"
# child_case <label> <setup-cmd> <function> <name>... — run the function on a
# fresh 0700 store (made here, after the arguments are read) with the names
# after the setup; it must return 1 and change nothing.
child_case() {
  local label="$1" setup="$2" fn="$3" rc before after
  shift 3
  fresh
  "$setup"
  before="$(tree_state "$TMP/s$n")"
  "$fn" "$D" "$@" > "$TMP/read.out"; rc=$?
  after="$(tree_state "$TMP/s$n")"
  expect 1 "$rc" "$label: refused"
  if [ "$before" = "$after" ]; then ok "$label: nothing removed, moved or changed"; else bad "$label: tree changed"; fi
}
mk_child_777() { mkdir "$D/child"; chmod 777 "$D/child"; }
mk_child_770() { mkdir "$D/child"; chmod 770 "$D/child"; }
mk_child_707() { mkdir "$D/child"; chmod 707 "$D/child"; }
mk_child_1777() { mkdir "$D/child"; chmod 1777 "$D/child"; }
mk_child_link() { ln -s "$VD" "$D/child"; }
mk_file_666() { printf 'OLD\n' > "$D/child"; chmod 666 "$D/child"; }
mk_file_link() { ln -s "$V" "$D/child"; }
mk_target_666() { printf 'A\n' > "$D/src"; chmod 600 "$D/src"; printf 'OLD\n' > "$D/child"; chmod 666 "$D/child"; }
mk_target_link() { printf 'A\n' > "$D/src"; chmod 600 "$D/src"; ln -s "$V" "$D/child"; }
mk_target_dirlink() { printf 'A\n' > "$D/src"; chmod 600 "$D/src"; ln -s "$VD" "$D/child"; }
for m in 777 770 707 1777; do
  child_case "rmdir: empty child folder mode $m" "mk_child_$m" hq_store_rmdir child
  child_case "claim: child folder mode $m" "mk_child_$m" hq_store_claim child
done
child_case "rmdir: symlink child to a folder" mk_child_link hq_store_rmdir child
child_case "remove: symlink child" mk_file_link hq_store_remove child
child_case "remove: child file mode 666" mk_file_666 hq_store_remove child
child_case "rename: symlink source" mk_file_link hq_store_rename child other
child_case "rename: source mode 666" mk_file_666 hq_store_rename child other
child_case "rename: target mode 666" mk_target_666 hq_store_rename src child
child_case "rename: target symlink to a file" mk_target_link hq_store_rename src child
child_case "rename: target symlink to a folder" mk_target_dirlink hq_store_rename src child
child_case "claim: symlink child" mk_child_link hq_store_claim child
victim_intact; truthy $? "child cases: link targets untouched"
if [ "$(id -u)" -eq 0 ] && id nobody >/dev/null 2>&1; then
  mk_foreign_dir() { mkdir "$D/child"; chmod 700 "$D/child"; chown nobody "$D/child"; }
  mk_foreign_file() { printf 'OLD\n' > "$D/child"; chmod 600 "$D/child"; chown nobody "$D/child"; }
  mk_foreign_target() { printf 'A\n' > "$D/src"; chmod 600 "$D/src"; mk_foreign_file; }
  child_case "rmdir: child folder owned by another user" mk_foreign_dir hq_store_rmdir child
  child_case "remove: child file owned by another user" mk_foreign_file hq_store_remove child
  child_case "rename: source owned by another user" mk_foreign_file hq_store_rename child other
  child_case "rename: target owned by another user" mk_foreign_target hq_store_rename src child
  child_case "claim: child folder owned by another user" mk_foreign_dir hq_store_claim child
else
  echo "# not root: foreign-owned child checks need chown and did not run here"
fi

echo "[e] working paths"
fresh
hq_store_append "$D" log.tsv <<< "one"; expect 0 $? "append: creates"
hq_store_append "$D" log.tsv <<< "two"; expect 0 $? "append: appends"
[ "$(file_text "$D/log.tsv")" = "one${_HQ_STORE_NL}two" ]; truthy $? "append: content in order"
[ "$(mode_of "$D/log.tsv")" = 600 ]; truthy $? "append: new file mode 0600"
hq_store_write_atomic "$D" snap.json <<< '{"a":1}'; expect 0 $? "write_atomic: creates"
hq_store_write_atomic "$D" snap.json <<< '{"a":2}'; expect 0 $? "write_atomic: replaces"
[ "$(file_text "$D/snap.json")" = '{"a":2}' ]; truthy $? "write_atomic: new content"
[ "$(mode_of "$D/snap.json")" = 600 ]; truthy $? "write_atomic: mode 0600"
[ -z "$(find "$D" -name '*.tmp.*')" ]; truthy $? "write_atomic: no temporary file left"
printf 'line1\nline2\n\n' > "$D/r.txt"; chmod 600 "$D/r.txt"
got="$(hq_store_read "$D" r.txt; printf x)"; rc=$?
[ "$got" = "line1${_HQ_STORE_NL}line2${_HQ_STORE_NL}${_HQ_STORE_NL}x" ]; truthy $? "read: exact content with trailing newlines"
hq_store_read "$D" r.txt 5 > "$TMP/read.out"; expect 1 $? "read: larger than the cap refused"
[ ! -s "$TMP/read.out" ]; truthy $? "read: nothing printed over the cap"
hq_store_read "$D" r.txt 13 > "$TMP/read.out"; expect 0 $? "read: exactly the cap accepted"
hq_store_read "$D" none.txt > "$TMP/read.out"; expect 2 $? "read: absent"
hq_store_remove "$D" r.txt; expect 0 $? "remove: removes"
[ ! -e "$D/r.txt" ]; truthy $? "remove: file gone"
hq_store_remove "$D" r.txt; expect 2 $? "remove: absent"
hq_store_rename "$D" log.tsv log.old; expect 0 $? "rename: renames"
hq_store_rename "$D" snap.json log.old; expect 0 $? "rename: replaces a checked file"
[ "$(file_text "$D/log.old")" = '{"a":2}' ] && [ ! -e "$D/snap.json" ]; truthy $? "rename: content moved"
mkdir "$D/empty" "$D/full"; printf 'k\n' > "$D/full/keep"
hq_store_rmdir "$D" empty; expect 0 $? "rmdir: empty folder removed"
hq_store_rmdir "$D" full; expect 4 $? "rmdir: folder with entries kept"
[ -f "$D/full/keep" ]; truthy $? "rmdir: entries untouched"
ln -s "$VD" "$D/dl"; hq_store_rmdir "$D" dl; expect 1 $? "rmdir: symlink refused"
[ -d "$VD" ] && [ -L "$D/dl" ]; truthy $? "rmdir: link and target untouched"
# claim
fresh
mkdir "$D/ses.held"; chmod 700 "$D/ses.held"; printf 'held\n' > "$D/ses.held/out"
hq_store_claim "$D" ses.held; expect 0 $? "claim: folder claimed"
claim="$HQ_STORE_PATH"
case "$claim" in "$D"/.hq-claim.??????????) ok "claim: private folder made inside the store folder" ;; *) bad "claim: path $claim" ;; esac
[ ! -e "$D/ses.held" ] && [ "$(file_text "$claim/ses.held/out")" = held ]; truthy $? "claim: entry moved with its content"
[ "$(mode_of "$claim")" = 700 ]; truthy $? "claim: claim folder mode 0700"
hq_store_claim "$D" ses.held; expect 2 $? "claim: second claim finds nothing"
printf 'f\n' > "$D/one.txt"; chmod 600 "$D/one.txt"
hq_store_claim "$D" one.txt; expect 0 $? "claim: file claimed"
[ -f "$HQ_STORE_PATH/one.txt" ]; truthy $? "claim: file inside the claim folder"
mkdir "$D/.hq-claim.planted"
mkdir "$D/open.held"; chmod 777 "$D/open.held"
hq_store_claim "$D" open.held; expect 1 $? "claim: other-writable folder refused"
[ -d "$D/open.held" ]; truthy $? "claim: refused folder left in place"
# quarantine
fresh
ln -s "$VD" "$D/ses.held"
hq_store_quarantine "$D" ses.held; expect 0 $? "quarantine: symlink set aside"
q="$HQ_STORE_PATH"
[ ! -e "$D/ses.held" ] && [ ! -L "$D/ses.held" ] && [ -L "$q/ses.held" ] && [ -d "$VD" ]; truthy $? "quarantine: link moved, target untouched"
mkdir "$D/bad.held"; printf 'k\n' > "$D/bad.held/keep"; ln "$D/bad.held/keep" "$D/bad.held/hard"; chmod 777 "$D/bad.held"
hq_store_quarantine "$D" bad.held; expect 0 $? "quarantine: refused folder set aside"
[ "$(file_text "$HQ_STORE_PATH/bad.held/keep")" = k ] && [ -f "$HQ_STORE_PATH/bad.held/hard" ]; truthy $? "quarantine: nothing deleted inside"
hq_store_quarantine "$D" none; expect 2 $? "quarantine: absent"
fresh; printf 'k\n' > "$D/x"; chmod 777 "$D"
hq_store_quarantine "$D" x; expect 1 $? "quarantine: under a refused folder nothing moves"
[ -f "$D/x" ] && [ "$(ls -A "$D")" = x ]; truthy $? "quarantine: refused folder untouched"
chmod 700 "$D"
fresh; printf 'OLD\n' > "$VD/x"; rm -rf "$D"; ln -s "$VD" "$D"
hq_store_quarantine "$D" x; expect 1 $? "quarantine: under a symlinked folder nothing moves"
[ "$(ls -A "$VD")" = x ]; truthy $? "quarantine: linked folder untouched"

echo "[f] injected races"
race_op=""
race_stage=""
race_kind=""
_hq_store_test_point() {
  [ "$1" = "$race_op" ] && [ "$2" = "$race_stage" ] || return 0
  case "$race_kind" in
    folder)
      mv "$D" "$D.held"
      ln -s "$VD" "$D"
      ;;
    file-link)
      mv "./$race_name" "./$race_name.orig"
      ln -s "$V" "./$race_name"
      ;;
    file-dir)
      mv "./$race_name" "./$race_name.orig"
      mkdir "./$race_name"
      ;;
    tmp-link)
      rm -f "./$3"
      ln -s "$V" "./$3"
      ;;
    tmp-fifo)
      rm -f "./$3"
      mkfifo "./$3"
      ;;
    tmp-swap-target-dir)
      # Another file takes the temporary name after this call wrote it, and
      # the target becomes a folder, so the call fails and cleans up.
      mv "./$3" "./$3.mine"
      printf 'OTHER\n' > "./$3"
      mv "./$race_name" "./$race_name.orig"
      mkdir "./$race_name"
      ;;
    target-dirlink)
      [ ! -e "./$race_name" ] || mv "./$race_name" "./$race_name.orig"
      ln -s "$VD" "./$race_name"
      ;;
    folder-back)
      # The path pointed at the link target during cd, then is put back.
      if [ "$2" = before-cd ]; then
        mv "$D" "$D.held"
        ln -s "$VD" "$D"
        race_stage=after-cd
      else
        rm "$D"
        mv "$D.held" "$D"
        race_stage=""
      fi
      ;;
  esac
}
race() { race_op="$1"; race_stage="$2"; race_kind="$3"; race_name="${4-}"; }
norace() { race_op=""; race_stage=""; race_kind=""; }
seed() { printf 'OLD\n' > "$D/s"; chmod 600 "$D/s"; }

fresh; seed; race append before-open folder
hq_store_append "$D" s <<< "NEW"; expect 3 $? "race append: folder swapped after the check reports 3"
victim_intact && [ "$(file_text "$D.held/s")" = "OLD${_HQ_STORE_NL}NEW" ]; truthy $? "race append: written in the checked folder, not the link target"
fresh; race append before-open folder
hq_store_append "$D" s <<< "NEW"; expect 3 $? "race append (create): folder swapped reports 3"
victim_intact && [ "$(file_text "$D.held/s")" = NEW ]; truthy $? "race append (create): created in the checked folder"
fresh; seed; race write_atomic before-open folder
hq_store_write_atomic "$D" s <<< "NEW"; expect 3 $? "race write_atomic: folder swapped reports 3"
victim_intact && [ "$(file_text "$D.held/s")" = NEW ]; truthy $? "race write_atomic: replaced in the checked folder"
fresh; seed; race write_atomic before-rename folder
hq_store_write_atomic "$D" s <<< "NEW"; expect 3 $? "race write_atomic: folder swapped before the rename reports 3"
victim_intact && [ "$(file_text "$D.held/s")" = NEW ]; truthy $? "race write_atomic: renamed in the checked folder"
fresh; seed; race read before-open folder
hq_store_read "$D" s > "$TMP/read.out"; expect 3 $? "race read: folder swapped reports 3"
[ ! -s "$TMP/read.out" ]; truthy $? "race read: nothing printed"
fresh; seed; printf 'OLD\n' > "$VD/s"; race remove before-act folder
hq_store_remove "$D" s; expect 3 $? "race remove: folder swapped reports 3"
[ "$(file_text "$VD/s")" = OLD ] && [ ! -e "$D.held/s" ]; truthy $? "race remove: removed in the checked folder only"
fresh; seed; race rename before-act folder
hq_store_rename "$D" s t; expect 3 $? "race rename: folder swapped reports 3"
victim_intact && [ -f "$D.held/t" ]; truthy $? "race rename: renamed in the checked folder"
fresh; mkdir "$D/e"; race rmdir before-act folder
hq_store_rmdir "$D" e; expect 3 $? "race rmdir: folder swapped reports 3"
victim_intact && [ ! -e "$D.held/e" ]; truthy $? "race rmdir: removed in the checked folder"
fresh; seed; race claim before-act folder
hq_store_claim "$D" s; expect 3 $? "race claim: folder swapped reports 3"
victim_intact && [ -f "$D.held/${HQ_STORE_PATH##*/}/s" ]; truthy $? "race claim: claimed in the checked folder"
fresh; seed; race quarantine before-act folder
hq_store_quarantine "$D" s; expect 3 $? "race quarantine: folder swapped reports 3"
victim_intact && [ -f "$D.held/${HQ_STORE_PATH##*/}/s" ]; truthy $? "race quarantine: moved in the checked folder"
fresh; seed; race append open-existing file-link s
hq_store_append "$D" s <<< "NEW"; expect 1 $? "race append: file swapped for a link before the open is refused"
victim_intact; truthy $? "race append: link target not written"
fresh; seed; race read open file-link s
hq_store_read "$D" s > "$TMP/read.out"; expect 1 $? "race read: file swapped for a link before the open is refused"
[ ! -s "$TMP/read.out" ]; truthy $? "race read: link target not printed"
fresh; seed; race write_atomic before-mv file-dir s
hq_store_write_atomic "$D" s <<< "NEW"; rc=$?
case "$rc" in 3|4) ok "race write_atomic: folder swapped in at the name before mv reports 3 or 4 (rc $rc)" ;; *) bad "race write_atomic: folder at the name before mv (rc $rc)" ;; esac
victim_intact; truthy $? "race write_atomic: nothing written outside the store"
fresh; seed; race write_atomic before-mv target-dirlink s
hq_store_write_atomic "$D" s <<< "NEW"; rc=$?
case "$rc" in 0|3) ok "race write_atomic: link to an outside folder swapped in before mv (rc $rc)" ;; *) bad "race write_atomic: link before mv (rc $rc)" ;; esac
victim_intact && [ ! -L "$D/s" ] && [ "$(file_text "$D/s")" = NEW ]; truthy $? "race write_atomic: mv replaced the link; nothing moved into the outside folder"
fresh; seed; race rename before-act target-dirlink t
hq_store_rename "$D" s t; rc=$?
case "$rc" in 0|3) ok "race rename: link to an outside folder swapped in before mv (rc $rc)" ;; *) bad "race rename: link before mv (rc $rc)" ;; esac
victim_intact && [ ! -L "$D/t" ] && [ "$(file_text "$D/t")" = OLD ]; truthy $? "race rename: mv replaced the link; nothing moved into the outside folder"
fresh; seed; race write_atomic before-rename file-dir s
hq_store_write_atomic "$D" s <<< "NEW"; expect 1 $? "race write_atomic: folder at the target after the write is refused"
[ -z "$(find "$D" -name '*.tmp.*')" ] && [ -d "$D/s" ]; truthy $? "race write_atomic: this call's temporary file removed"
fresh; seed; race write_atomic before-rename tmp-swap-target-dir s
hq_store_write_atomic "$D" s <<< "NEW"; expect 1 $? "race write_atomic: target folder after the write is refused"
other="$(find "$D" -name '*.tmp.*' ! -name '*.mine' -type f)"
[ -n "$other" ] && [ "$(file_text "$other")" = OTHER ]; truthy $? "race write_atomic: cleanup leaves a file this call did not create"
fresh; seed; race write_atomic before-tmp tmp-fifo
bounded 10 hq_store_write_atomic "$D" s; expect 1 $? "race write_atomic: FIFO swapped in at the temporary name is refused without blocking"
[ "$(file_text "$D/s")" = OLD ] && [ -n "$(find "$D" -name '*.tmp.*' -type p)" ]; truthy $? "race write_atomic: the FIFO, not this call's file, is left in place"
fresh; seed; race enter before-cd folder
hq_store_append "$D" s <<< "NEW"; expect 1 $? "race enter: folder swapped for a link before cd is refused"
victim_intact && [ "$(file_text "$D.held/s")" = OLD ]; truthy $? "race enter: nothing written"
fresh; seed; race enter before-cd folder-back
hq_store_append "$D" s <<< "NEW"; expect 1 $? "race enter: link during cd, folder put back after, is refused"
victim_intact && [ "$(file_text "$D/s")" = OLD ]; truthy $? "race enter: nothing written in the link target"
fresh; seed; race write_atomic before-tmp tmp-link
hq_store_write_atomic "$D" s <<< "NEW"; expect 1 $? "race write_atomic: link swapped in at the temporary name is refused"
victim_intact && [ "$(file_text "$D/s")" = OLD ] && [ -n "$(find "$D" -name '*.tmp.*' -type l)" ]; truthy $? "race write_atomic: link target, store file and the link itself untouched"
norace
_hq_store_test_point() { :; }

echo "[g] callers"
fresh
out="$(
  set -euo pipefail
  hq_store_mkdir "$D/strict"
  hq_store_write_atomic "$D/strict" a <<< "x"
  hq_store_append "$D/strict" a <<< "y"
  hq_store_read "$D/strict" a > /dev/null
  hq_store_dir_ok "$D/strict"
  hq_store_file_ok "$D/strict/a"
  hq_store_remove "$D/strict" a
  if ! hq_store_remove "$D/strict" a; then :; fi
  ln -s "$V" "$D/strict/l"
  if hq_store_append "$D/strict" l <<< "z"; then echo "appended through a link"; fi
  echo reached
)"
[ "$out" = reached ]; truthy $? "set -euo pipefail caller: successes and refusals do not exit it"
victim_intact; truthy $? "set -euo pipefail caller: link target untouched"
fresh; printf 'OLD\n' > "$D/a"; chmod 600 "$D/a"
( set -C; hq_store_write_atomic "$D" a <<< "NEW" ); expect 0 $? "noclobber caller: write_atomic still replaces"
( umask 000; hq_store_append "$D" b <<< "x" ); expect 0 $? "umask 000 caller: append creates"
[ "$(mode_of "$D/b")" = 600 ]; truthy $? "umask 000 caller: new file mode 0600"
here="$PWD"
( CDPATH="$VD"; mkdir "$VD/s$n" 2>/dev/null; cd "$TMP" && hq_store_append "s$n/store" c <<< "rel" ); expect 0 $? "relative folder with CDPATH set: appends under the working folder"
[ -f "$D/c" ] && [ ! -e "$VD/s$n/store" ]; truthy $? "relative folder with CDPATH set: CDPATH ignored"
hq_store_append "$D" d <<< "x"
[ "$PWD" = "$here" ]; truthy $? "caller working folder unchanged"
ln -s "$V" "$D/l"
hq_store_append "$D" l <<< "x"
case "$HQ_STORE_REASON" in *symlink*) ok "reason names the refusal" ;; *) bad "reason: $HQ_STORE_REASON" ;; esac

echo "[h] foreign owner"
if [ "$(id -u)" -eq 0 ]; then
  echo "# running as root: foreign-owner checks not run"
else
  hq_store_dir_ok /usr; expect 1 $? "foreign: dir_ok refuses a folder owned by another user"
  hq_store_file_ok /etc/hosts; expect 1 $? "foreign: file_ok refuses a file owned by another user"
  hq_store_preflight /usr /usr/bin/env; expect 1 $? "foreign: preflight refuses a root owned by another user"
  hq_store_read /etc hosts > "$TMP/read.out"; expect 1 $? "foreign: read refuses a folder owned by another user"
  hq_store_append /usr safe-store-test <<< "x"; expect 1 $? "foreign: append refuses a folder owned by another user"
  hq_store_quarantine /usr bin; expect 1 $? "foreign: quarantine refuses a folder owned by another user"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
