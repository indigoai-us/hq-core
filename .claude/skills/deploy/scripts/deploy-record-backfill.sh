#!/usr/bin/env bash
# deploy-record-backfill.sh — /deploy record-existing: write deploy records for
# the deploys you already made, on your own machine, for one company.
#
# Records written by /deploy since #1452 cover new deploys. This command covers
# older ones, so search and the reuse check (/deploy A.6) find them too. It runs
# locally and writes nothing on any server: it reads the app list from
# hq-deploy, keeps only the apps you created (ownerId matches your sign-in; no
# option records anyone else's apps), skips apps that already have a record
# anywhere under companies/<company>/, and writes the rest with
# deploy-record-home.sh and deploy-record.sh.
#
# Usage (prints one line per app, a summary line, then one JSON line):
#   deploy-record-backfill.sh --company <slug> [--dry-run | --apply]
#                             [--app <subdomain> [--source <dir>]]
#                             [--copy-sources] [--captions] [--search <dir>]...
#                             [--cursor <file>] [--api <base>] [--hq-root <dir>]
#   deploy-record-backfill.sh --company <slug> --set-caption <record> --caption <text>
#
#   --dry-run       the default: print what would be written per app (source,
#                   access mode, type, home) and write nothing.
#   --apply         write the records.
#   --app/--source  one app only; --source points it at a folder on this
#                   machine. It replaces a needs-source record for that app.
#   --copy-sources  also copy a public or company app's local source next to
#                   its record (the deploy-record-home.sh rules). Off by
#                   default, because a backfill of many apps would otherwise
#                   sync every source folder to every company member.
#   --captions      after --apply, write workspace/deploy-record-backfill/
#                   <company>-captions.json listing records under 50 words
#                   that have a local source or a public URL. The deploy skill
#                   has a child agent view a screenshot of each and write two
#                   sentences with --set-caption; the parent never loads the
#                   image. --set-caption replaces the record's description and
#                   adds the caption-generated tag to its frontmatter.
#   --search <dir>  another folder to look in for sources (repeatable).
#
# Source for each app, first match wins:
#   1. a folder on this machine holding an index.html whose name is the
#      subdomain or the app name, or whose index.html links to
#      //<subdomain>. — searched in companies/<company>/projects/, workspace/
#      and ~/.hq/deploy-hosts/ (6 levels deep; node_modules, .git, deploys,
#      worktrees, threads and sessions skipped), plus any --search folder.
#   2. public apps only: the live page, fetched without following redirects
#      (a redirect means a sign-in page). HTML only, 5 MB cap.
#   3. none: the record has the app's own fields, the tags backfill and
#      needs-source, and no page text. The summary names these apps.
#
# The description is the first 300 characters of the page's text, redacted,
# for public and company apps with a source; every other app gets a generic
# line naming the app, its access mode and URL. The type comes from words in
# the subdomain, name and title (deck, report, newsletter and so on; apps are
# tool; otherwise explainer). Every record carries the tag backfill. The home
# comes from deploy-record-home.sh with the session variables cleared, so a
# source inside companies/<company>/projects/<slug>/ files the record in that
# project and every other app goes to companies/<company>/deploys/.
#
# Rate and resume: at most 2 network requests per second (list pages and
# fetches). With --apply each finished app is written to the cursor file
# (default workspace/deploy-record-backfill/<company>.json), so a rerun after
# an interruption resumes and writes no duplicates.
#
#   -> summary line: record-existing <co> (<mode>): written-from-local=N
#      written-from-fetch=N needs-source=N skipped=N failed=N
#   -> {"ok":true,"mode":"dry-run|apply","company":...,"apps_listed":N,
#       "yours":N,"written_from_local":N,"written_from_fetch":N,
#       "needs_source":N,"skipped":N,"failed":N,"needs_source_apps":[...],
#       "failed_apps":[...],"requests":N,["cursor"],["captions_queue",
#       "captions_needed"]}
#   -> {"ok":false,"reason":"bad_args|company_not_found|login_required|
#       list_failed|owner_unknown|app_not_yours|not_a_backfill_record|
#       hq_root_not_found|internal_error",...}
#
# Exit codes: 0 done, 64 bad arguments, 1 runtime failure.
# Tests: HQ_DEPLOY_BACKFILL_APPS_FILE (a {"apps":[...]} file) and
# HQ_DEPLOY_BACKFILL_OWNER replace the signed-in list; HQ_DEPLOY_BACKFILL_GAP
# lowers the request gap.
#
# Needs Python 3.8+ (standard library only). It runs as python3 -I.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 \
    && "$candidate" -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    PY="$(command -v "$candidate")"
    break
  fi
done

if [ -z "$PY" ]; then
  printf '%s\n' '{"ok":false,"reason":"missing_dependency","dep":"python3"}'
  exit 1
fi

exec "$PY" -I "$SCRIPT_DIR/deploy-record-backfill.py" "$@"
