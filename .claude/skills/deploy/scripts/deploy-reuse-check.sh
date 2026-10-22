#!/usr/bin/env bash
# deploy-reuse-check.sh — before a deploy uploads, look for an existing deploy
# that does the same job, so the user can reuse it or add a route to it.
#
# Runs one qmd vector search (qmd vsearch) against the company's projects
# collection with the new deploy's description, keeps only deploy records
# (companies/<co>/projects/<slug>/deploys/<subdomain>.md, never copied
# sources), and returns up to 3. It reads the matched record files and nothing
# else. It never reads a deployed page and never updates the qmd index, so a
# record is found once the index refresh has embedded it.
#
# vsearch rather than the hybrid `qmd query`: without its LLM rerank the
# hybrid score is rank-normalised (the best hit is always 1.0), so a fixed
# threshold would ask on every deploy; with the rerank every deploy pays an
# LLM pass. vsearch returns an absolute similarity the thresholds apply to.
#
# Usage (prints exactly one JSON line on stdout):
#   deploy-reuse-check.sh --company <slug> --description <text> [--type static|app]
#                         [--hq-root <dir>]
#
#   --description  the paragraph the agent wrote for this deploy (C.4.5 uses
#                  the same text for the record). Leading dashes are dropped
#                  from the query so it cannot read as a qmd flag.
#   --type         static or app; candidates of the other app type are dropped.
#   --hq-root      the HQ to search. Default: $HQ_ROOT, then the working
#                  directory, then the HQ this script ships in; the outermost
#                  HQ at or above it is used, as deploy-record.sh does.
#
# Only records under <hq-root>/companies/<company>/projects/ count, so a
# folder of that shape nested in another company's tree is ignored.
# Candidates are sorted by score, then capped at 3.
#
#   -> {"ok":true,"decision":"ask|note|none","candidates":[{"subdomain",
#       "url","project","score","description"}],"ms":N,["reason":...]}
#
# decision: "ask" when the top score is 0.68 or more, "note" from 0.62 to
# 0.68 (one line naming the closest deploy, then proceed), "none" below
# 0.62. Tuned on the US-007 benchmark (2026-10-21): a record searched with
# its own description scores about 0.70, so the planned 0.75 never asked.
# description is cut to 160 characters.
#
# Never blocks a deploy. With qmd missing, the collection missing, a qmd error
# or a qmd run over 20 seconds, it returns "decision":"none" with no
# candidates and a reason (qmd_missing, collection_missing, qmd_failed,
# qmd_timeout, qmd_bad_output, hq_root_not_found, empty_query). qmd runs in
# its own process group and a timeout kills the whole group, so the node
# process qmd starts does not outlive the check. Bad arguments exit 64 with
# "decision":"none". A vector search embeds only the one query line, about a
# second on a laptop.
# HQ_DEPLOY_REUSE_QMD overrides the qmd binary ("none" disables the check).

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
  printf '%s\n' '{"ok":false,"reason":"missing_dependency","dep":"python3","decision":"none","candidates":[]}'
  exit 1
fi

exec "$PY" -I "$SCRIPT_DIR/deploy-reuse-check.py" "$@"
