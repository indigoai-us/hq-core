#!/usr/bin/env bash
# Guards that shipped INDEX.md files match the hq CLI renderers.
# If this fails, regenerate with hq core rebuild-index public-knowledge|workers --accept.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
export HQ_NO_UPDATE_CHECK=1

hq core --hq-root "$ROOT" rebuild-index public-knowledge --accept
hq core --hq-root "$ROOT" rebuild-index workers --accept

for path in \
  core/knowledge/public/INDEX.md \
  core/workers/INDEX.md \
  core/workers/public/INDEX.md; do
  if ! diff -u \
    <(git show "HEAD:$path" | sed -E 's/(Updated:) .*/\1 <date>/') \
    <(sed -E 's/(Updated:) .*/\1 <date>/' "$path"); then
    printf 'Generated index is stale: %s\n' "$path" >&2
    printf 'Regenerate with: hq core --hq-root . rebuild-index public-knowledge --accept\n' >&2
    printf 'and: hq core --hq-root . rebuild-index workers --accept\n' >&2
    exit 1
  fi
done
