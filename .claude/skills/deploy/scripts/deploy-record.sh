#!/usr/bin/env bash
# deploy-record.sh — write a searchable record of a finished deploy.
#
# A deploy record is one markdown file, <home>/<subdomain>.md, that says what
# the deploy is and where its source lives: YAML frontmatter (app id, url, type,
# access mode, company, project, source path, tags), the deploying agent's
# one-paragraph description, and the text extracted from the deployed pages.
# Records live in the project folder, so qmd indexes them and anyone who takes
# over the project gets them. hq-deploy itself stores only the slug.
#
# Usage (prints exactly one JSON line on stdout):
#   deploy-record.sh --app-json <file> --source <dir> --home <dir>
#                    --description <text> --type <type>
#                    [--access-mode <mode>] [--project <slug>] [--company <slug>]
#                    [--created-by <id>] [--deploy-id <id>] [--tag <tag>]...
#                    [--source-path <path>]
#
#   --source-path  the path to record as source_path when --source is a
#                  stand-in (an app deploy recorded from a generated page).
#                  Defaults to --source, written relative to HQ or ~.
#
#   --app-json     the app object from hq-deploy (id, name, subdomain, url,
#                  type, accessMode, createdAt). subdomain names the record.
#   --source       the directory that was uploaded; must hold index.html.
#   --home         the folder the record goes in, created if missing. Inside
#                  an HQ it must sit under companies/<company>/ for a company
#                  listed in companies/manifest.yaml; --company and --project
#                  must match that path and default to it. A home outside
#                  every companies/ folder is refused when --company is set.
#   --description  one paragraph written by the agent that built the artifact.
#                  Required for every deploy, including videos and image-only
#                  pages whose page text says little.
#   --type         primary content type, one of: explainer report memo deck
#                  pdf-deck landing tool demo-site newsletter preview asset
#                  video stub.
#   --access-mode  the gate the deploy ends up with (public company password
#                  private selected). The gate is also resolved from the app
#                  JSON (privateMode, accessPolicy.mode, accessMode,
#                  passwordProtected; the strictest field wins, an
#                  unrecognised value counts as gated, and an app object with
#                  none of these fields counts as unknown, which is gated),
#                  and the stricter of the two is used. The flag can tighten
#                  the gate, for one set after the app JSON was read, but
#                  never loosen it.
#
#   -> {"ok":true,"record":<real path>,"subdomain":...,"type":...,
#       "access_mode":...,"words":N,"truncated":bool,"tags":[...]}
#   -> {"ok":false,"reason":"bad_args|invalid_app_json|no_index_html|
#       home_outside_company|company_not_found|home_not_writable|
#       record_conflict|write_failed|missing_dependency|internal_error",...}
#
# Exit codes: 0 written, 64 bad arguments or invalid input, 1 runtime failure.
# The deploy skill runs under set -e, so callers guard the call. A missing
# index.html, an unwritable home or bad input writes nothing; a record is
# renamed into place only once complete, so no failure leaves a partial file.
# Running it again for the same app replaces the record. A file at the record
# path that is not a deploy record (or is a symlink) is never replaced; the run
# fails with record_conflict.
#
# What goes in the body: visible page text from every .html page (script,
# style, svg and the injected "Built in HQ" badge are dropped), each page's
# title, image alt text, and the text of same-site PDFs the pages embed or
# link. Only regular files inside --source are read: symlinks pointing out of
# it, FIFOs and devices are skipped. PDF text needs pdftotext; without it the
# record is tagged needs-description. The body is capped at 1500 words, the
# title at 200 characters and the meta description at 500. A page that fails
# to parse keeps what was read and tags the record extract-partial.
# Credential-shaped strings (API keys, tokens, JWTs, private keys, passwords
# in URLs, token or signature query parameters, env-style assignments, and
# "password: ..." or "token = ..." pairs in any case) are redacted.
#
# Only public and company deploys get page text. For every other access mode
# the record keeps the agent's description and the app's own fields, and
# leaves out page text, titles, routes, file names and word counts, because
# records are readable by everyone in the company.
#
# Environment (tests):
#   HQ_DEPLOY_RECORD_PDFTOTEXT  path to a pdftotext-compatible binary, or
#                               "none" to disable PDF text.
#
# The extractor runs under `python3 -I`, so Python never imports code from the
# artifact directory, the current directory, or user site-packages.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 \
    && "$candidate" -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
if [ -z "$PY" ]; then
  printf '{"ok":false,"reason":"missing_dependency","dep":"python3"}\n'
  exit 1
fi

exec "$PY" -I "$SCRIPT_DIR/deploy-record.py" "$@"
