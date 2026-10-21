#!/usr/bin/env bash
# deploy-record-home.sh — decide where a deploy record lives and keep a copy of
# the deploy source next to it.
#
# A deploy record (deploy-record.sh) belongs to the project that made the
# deploy, so whoever takes over the project finds the deploy and its source.
# This script picks that folder and, when the source lives somewhere else
# (workspace/, a temp dir, another repo), copies the source into it.
#
# Usage (prints exactly one JSON line on stdout):
#   deploy-record-home.sh --subdomain <label> --source <dir>
#                         [--app-json <file>] [--access-mode <mode>] [--copy yes|no]
#                         [--company <slug>] [--project <slug>]
#                         [--session-id <id>] [--cwd <dir>] [--hq-root <dir>]
#
# The deploy's gate decides whether the source is copied. It is resolved the
# way deploy-record.sh resolves it: the stricter of --access-mode and the app
# JSON, an unrecognised value counts as gated, and with neither given the gate
# is "unknown". Only public and company deploys are copied, because the company
# folder syncs to every member; for any other gate the result says
# "copied":false and "copy_withheld":<mode>, and the source stays where it is.
# --copy no resolves the home without copying ("copy_withheld":
# "not_requested"); the record step uses it for app deploys recorded from a
# generated page.
#
# The home is resolved in this order; the first rung that names an existing
# project wins:
#   1. flag         --project <slug> (with --company, or the session's company)
#   2. session      the project in workspace/sessions/<id>/meta.yaml. The id is
#                   --session-id, else HQ_SESSION_ID, CLAUDE_CODE_SESSION_ID,
#                   CLAUDE_SESSION_ID, CODEX_SESSION_ID, CODEX_THREAD_ID or
#                   GROK_SESSION_ID. The file is read, never written.
#   3. source_path  a companies/<co>/projects/<slug>/ segment in --source,
#   3. cwd          then in --cwd (default: the working directory)
#   4. fallback     companies/<co>/deploys/, for deploys with no project
#
# A project home is companies/<co>/projects/<slug>/deploys/. The company comes
# from --company, else the session's company_slug, else the path segment, and
# must be listed in companies/manifest.yaml. A session project or path segment
# from a different company than --company is skipped and named in "notes".
#
# Source copy: when --source lies outside the resolved project (outside the
# company folder for the fallback) and the gate allows it, it is copied to
# <home>/<subdomain>/source/ and that copy is the source_path to record. The
# source must hold a regular index.html, and the copy stops with
# source_too_large past 2000 files or 50 MB, leaving nothing behind.
# Skipped: node_modules and .git directories, files over 5 MB, symlinks,
# FIFOs and devices, .DS_Store, and files that usually hold credentials
# (.env, .env.*, .envrc, .npmrc, .netrc, .pypirc, .pgpass, .htpasswd,
# .git-credentials, .dockercfg, credentials*, secret*/secrets*,
# service-account*.json, *.tfstate, *.tfvars, SSH keys including id_*_sk and
# *_rsa, deploy_key, *.pem, *.key, *.p12, *.pfx, *.ppk, *.jks, *.keystore,
# *.kdbx; .env.example, .env.sample and .env.template are kept). Every file
# that reads as UTF-8 text (html, js, tsx, jsx, vue, svelte, css, json, md and
# so on) passes through deploy-record.py's credential redaction on the way
# in. Files are opened without following links, so a link swapped in mid-copy
# is skipped. The copy is
# built in a temp folder and swapped in whole, so a rerun replaces it and a
# failure leaves the previous copy. The copy carries a .hq-deploy-source
# marker; a <home>/<subdomain>/source without it (or that is a link or a file)
# is never replaced, and the run fails with source_conflict. A source already
# inside the project is recorded where it is and nothing is copied.
#
# The home must resolve inside companies/<company>/: a company, project or
# deploys folder that is a link to somewhere else fails with
# home_outside_company, so a copy never lands in another company. A source
# that belongs to another company is refused (source_in_other_company): its
# companies/<co>/ tree, a repo the manifest lists for it, a worktree of that
# repo under workspace/worktrees/, or a workspace folder named for it. The
# check runs on the source and on every folder and file inside it, so a
# source that merely contains another company's folder is refused too. A
# top-level HQ folder (repos, repos/public, repos/private, workspace,
# workspace/worktrees, personal, core, .claude) is never a source
# (source_too_broad). The HQ root is the outermost HQ at or above the
# starting point, the same rule deploy-record.sh uses.
#
#   -> {"ok":true,"home":<abs>,"home_rel":<HQ-relative>,"company":...,
#       "project":<slug>|null,"resolution":"flag|session|source_path|cwd|
#       fallback","subdomain":...,"access_mode":...,"copied":bool,
#       "source":<abs dir to pass to deploy-record.sh --source>,
#       "source_path":<HQ-relative or ~ path>,["copy_withheld":<mode>],
#       ["copied_from","files_copied","bytes_copied","files_redacted",
#       "excluded":{...}],["notes":[...]]}
#   -> {"ok":false,"reason":"bad_args|invalid_app_json|source_not_found|
#       company_not_found|company_unresolved|project_not_found|
#       source_in_other_company|source_contains_home|home_outside_company|
#       home_not_writable|no_index_html|source_conflict|source_too_large|
#       source_too_broad|copy_failed|hq_root_not_found|missing_dependency|
#       internal_error",...}
#
# Exit codes: 0 resolved, 64 bad arguments or invalid input, 1 runtime failure.
# The deploy skill runs under set -e, so callers guard the call.
#
# Needs Python 3.8+ (standard library only). It runs as python3 -I, so the
# working directory and PYTHONPATH cannot inject a module.

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

exec "$PY" -I "$SCRIPT_DIR/deploy-record-home.py" "$@"
