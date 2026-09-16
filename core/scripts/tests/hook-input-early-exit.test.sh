#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT/core/scripts/hook-lib.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/root"
payload="$(head -c 200000 /dev/zero | tr '\0' x)"
for mode in executable fallback; do
  script="$tmp/$mode.sh"
  printf '#!/usr/bin/env bash\nexit "$1"\n' > "$script"
  [ "$mode" != executable ] || chmod +x "$script"
  for expected in 0 2 7; do
    actual=0
    hq_launch_shell_path "$tmp/root" "$script" "$payload" "$expected" || actual=$?
    [ "$actual" = "$expected" ] || { echo "$mode: expected $expected, got $actual"; exit 1; }
  done
done
printf '#!/usr/bin/env bash\ncat\n' > "$tmp/reader.sh"
actual="$(hq_launch_shell_path "$tmp/root" "$tmp/reader.sh" "$payload")"
[ "$actual" = "$payload" ] || { echo 'Payload changed'; exit 1; }
echo 'PASS: early exits preserve hook status, denials and input'
