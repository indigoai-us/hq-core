#!/bin/sh
# hq-core: public
# Export systemd credential files, including multiline values, then exec the job.
set -eu
directory="${CREDENTIALS_DIRECTORY:?}"
names="$directory/names"
[ -f "$names" ] || exit 2
while IFS= read -r name || [ -n "$name" ]; do
  case "$name" in
    ''|*[!A-Za-z0-9_]*) exit 2 ;;
  esac
  file="$directory/$name"
  [ -f "$file" ] || exit 2
  # Command substitution drops trailing newlines. The sentinel keeps them.
  value=$(cat "$file"; printf x)
  value=${value%x}
  export "$name=$value"
done < "$names"
exec "$@"
