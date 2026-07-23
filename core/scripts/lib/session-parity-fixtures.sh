#!/usr/bin/env bash
# hq-core: public
# session-parity-fixtures.sh — offline golden-turn parity helpers (US-412).
#
# Sourced by hq-agent-session-parity.test.sh. Provides fixture paths, request
# builders, constant-count guard, and assemble-vs-golden comparison.

# shellcheck shell=bash

# session_parity_repo_root
#   Absolute path to the hq-core-staging (or HQ) tree that owns this lib file.
session_parity_repo_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$here/../../.." && pwd
}

# session_parity_fixtures_dir
session_parity_fixtures_dir() {
  printf '%s/core/scripts/tests/fixtures/agent-session' "$(session_parity_repo_root)"
}

# session_parity_constants_dir
session_parity_constants_dir() {
  printf '%s/constants' "$(session_parity_fixtures_dir)"
}

# session_parity_goldens_dir
session_parity_goldens_dir() {
  printf '%s/core/scripts/tests/goldens/agent-session' "$(session_parity_repo_root)"
}

# session_parity_requests_dir
session_parity_requests_dir() {
  printf '%s/requests' "$(session_parity_fixtures_dir)"
}

# Eight turn-type fixtures: US-412 (3) + US-416 (5).
SESSION_PARITY_FIXTURE_IDS=(
  slack-verified
  slack-untrusted
  dm-verified
  email-verified
  telegram-verified
  job-scheduled
  skill-handoff
  worker-run
)

# session_parity_expected_constants_for <fixture_id>
#   Prints space-separated constant names expected present in assembled output.
session_parity_expected_constants_for() {
  local id="${1:-}"
  case "$id" in
    slack-verified)
      printf '%s' "SLACK_VERIFIED_PREAMBLE VERIFIED_MEMBER_REPLY_POSTURE REPLY_NO_PROMISES SLACK_FORMATTING SLACK_PROGRESSIVE_POSTS SLACK_DECISION_ASKING CHANNEL_VOICE"
      ;;
    slack-untrusted)
      printf '%s' "SLACK_STRICT_UNTRUSTED_PREAMBLE REPLY_NO_PROMISES SLACK_FORMATTING SLACK_PROGRESSIVE_POSTS SLACK_DECISION_ASKING CHANNEL_VOICE"
      ;;
    dm-verified|skill-handoff|worker-run)
      # skill/worker fixtures ride the native DM channel; same brief constants as dm-verified.
      printf '%s' "DM_VERIFIED_PREAMBLE VERIFIED_MEMBER_REPLY_POSTURE REPLY_NO_PROMISES DM_FORMATTING CHANNEL_VOICE"
      ;;
    email-verified)
      printf '%s' "VERIFIED_MEMBER_REPLY_POSTURE REPLY_NO_PROMISES EMAIL_FORMATTING CHANNEL_VOICE"
      ;;
    telegram-verified)
      printf '%s' "VERIFIED_MEMBER_REPLY_POSTURE REPLY_NO_PROMISES TELEGRAM_FORMATTING CHANNEL_VOICE"
      ;;
    job-scheduled)
      # job has no channel-specific brief formatting constant; voice + posture only.
      printf '%s' "VERIFIED_MEMBER_REPLY_POSTURE REPLY_NO_PROMISES CHANNEL_VOICE"
      ;;
    *)
      printf ''
      ;;
  esac
}

# session_parity_forbidden_constants_for <fixture_id>
#   Prints space-separated constant names that must be ABSENT.
#   Cross-asserts channel formatting so TELEGRAM/EMAIL/DM never leak across fixtures.
session_parity_forbidden_constants_for() {
  local id="${1:-}"
  case "$id" in
    slack-verified)
      printf '%s' "SLACK_STRICT_UNTRUSTED_PREAMBLE DM_VERIFIED_PREAMBLE DM_STRICT_UNTRUSTED_PREAMBLE TELEGRAM_FORMATTING EMAIL_FORMATTING DM_FORMATTING"
      ;;
    slack-untrusted)
      printf '%s' "SLACK_VERIFIED_PREAMBLE DM_VERIFIED_PREAMBLE DM_STRICT_UNTRUSTED_PREAMBLE VERIFIED_MEMBER_REPLY_POSTURE TELEGRAM_FORMATTING EMAIL_FORMATTING DM_FORMATTING"
      ;;
    dm-verified|skill-handoff|worker-run)
      printf '%s' "DM_STRICT_UNTRUSTED_PREAMBLE SLACK_VERIFIED_PREAMBLE SLACK_STRICT_UNTRUSTED_PREAMBLE TELEGRAM_FORMATTING EMAIL_FORMATTING"
      ;;
    email-verified)
      printf '%s' "TELEGRAM_FORMATTING DM_FORMATTING SLACK_FORMATTING SLACK_VERIFIED_PREAMBLE SLACK_STRICT_UNTRUSTED_PREAMBLE DM_VERIFIED_PREAMBLE DM_STRICT_UNTRUSTED_PREAMBLE"
      ;;
    telegram-verified)
      printf '%s' "EMAIL_FORMATTING DM_FORMATTING SLACK_FORMATTING SLACK_VERIFIED_PREAMBLE SLACK_STRICT_UNTRUSTED_PREAMBLE DM_VERIFIED_PREAMBLE DM_STRICT_UNTRUSTED_PREAMBLE"
      ;;
    job-scheduled)
      printf '%s' "TELEGRAM_FORMATTING EMAIL_FORMATTING DM_FORMATTING SLACK_FORMATTING SLACK_VERIFIED_PREAMBLE SLACK_STRICT_UNTRUSTED_PREAMBLE DM_VERIFIED_PREAMBLE DM_STRICT_UNTRUSTED_PREAMBLE"
      ;;
    *)
      printf ''
      ;;
  esac
}

# session_parity_assert_pipeline <fixture_id> <runDir>
#   US-416 pipeline asserts beyond brief constants:
#     skill-handoff / worker-run → skill.txt present with resolved body marker
#     worker-run → checked-in worker materialization fixture present under HQ root
#     job-scheduled → agent-contract body (same path job-runner.ts reads) in system.txt
session_parity_assert_pipeline() {
  local id="${1:-}" run_dir="${2:-}"
  local system_txt skill_txt root
  system_txt="${run_dir}/system.txt"
  skill_txt="${run_dir}/skill.txt"
  root="${HQ_AGENT_WORKDIR:-}"

  case "$id" in
    skill-handoff)
      [ -f "$skill_txt" ] || { printf 'skill-handoff: missing skill.txt under %s' "$run_dir"; return 1; }
      grep -Fq 'PARITY_SKILL_HANDOFF_BODY' "$skill_txt" \
        || { printf 'skill-handoff: skill.txt missing resolved handoff body marker'; return 1; }
      grep -Fq 'PARITY_SKILL_HANDOFF_BODY' "$system_txt" \
        || { printf 'skill-handoff: system.txt missing skill body under skill section'; return 1; }
      if grep -Fq 'PARITY_SKILL_HANDOFF_BODY' "${run_dir}/user.txt" 2>/dev/null; then
        printf 'skill-handoff: skill body leaked into user.txt'
        return 1
      fi
      printf '  pipeline skill-handoff: skill.txt + system skill section\n'
      ;;
    worker-run)
      [ -f "$skill_txt" ] || { printf 'worker-run: missing skill.txt under %s' "$run_dir"; return 1; }
      # /run <worker> <skill> resolves the root "run" skill (pipeline output).
      grep -Fq 'PARITY_SKILL_RUN_BODY' "$skill_txt" \
        || { printf 'worker-run: skill.txt missing resolved /run skill body marker'; return 1; }
      grep -Fq 'PARITY_SKILL_RUN_BODY' "$system_txt" \
        || { printf 'worker-run: system.txt missing /run skill body'; return 1; }
      # Materialized worker file set matches checked-in US-416/US-052 fixture shape.
      [ -f "$root/companies/indigo/workers/parity-worker/worker.yaml" ] \
        || { printf 'worker-run: missing materialized worker.yaml'; return 1; }
      [ -f "$root/companies/indigo/workers/parity-worker/skills/review/SKILL.md" ] \
        || { printf 'worker-run: missing materialized review SKILL.md'; return 1; }
      grep -Fq 'parity-worker' "$root/companies/indigo/workers/parity-worker/worker.yaml" \
        || { printf 'worker-run: worker.yaml id mismatch vs checked-in fixture'; return 1; }
      grep -Fq 'PARITY_WORKER_REVIEW_SKILL_BODY' \
        "$root/companies/indigo/workers/parity-worker/skills/review/SKILL.md" \
        || { printf 'worker-run: review skill body mismatch vs checked-in fixture'; return 1; }
      printf '  pipeline worker-run: skill.txt + worker materialization fixture\n'
      ;;
    job-scheduled)
      # job-runner.ts reads AGENT_WORKDIR/personal/knowledge/public/agent-capabilities/hq-agent-contract.md
      # and the contract entrypoint assembles that same path into the agent-contract section.
      grep -Fq 'PARITY_AGENT_CONTRACT_BODY' "$system_txt" \
        || { printf 'job-scheduled: agent-contract body missing from system.txt'; return 1; }
      grep -Fq '<!-- hq-section: agent-contract -->' "$system_txt" \
        || { printf 'job-scheduled: agent-contract section marker missing'; return 1; }
      # Path-shape assert: the relative path the job runner uses is the assembly source.
      [ -f "$root/personal/knowledge/public/agent-capabilities/hq-agent-contract.md" ] \
        || { printf 'job-scheduled: hq-agent-contract.md missing at job-runner path'; return 1; }
      printf '  pipeline job-scheduled: agent-contract path content in system.txt\n'
      ;;
  esac
  return 0
}

# session_parity_count_guard
#   Fail (print reason to stdout, return 1) when constants/ file count != 13
#   or (when HQ_PRO inbox-watcher path is available) named const declarations
#   diverge from the fixture set.
session_parity_count_guard() {
  local cdir count expected=13
  cdir="$(session_parity_constants_dir)"
  count="$(find "$cdir" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | wc -l | tr -d '[:space:]')"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$count" -ne "$expected" ]; then
    printf 'constant count guard: fixtures has %s files, expected %s under %s' "$count" "$expected" "$cdir"
    return 1
  fi

  # Optional: when hq-pro sources are on disk, ensure each fixture name has a
  # corresponding `const NAME =` (or export alias) somewhere in the brief region.
  local pro_cli="${HQ_PRO_INBOX_WATCHER_CLI:-}"
  if [ -z "$pro_cli" ] && [ -n "${HQ_PRO_ROOT:-}" ]; then
    pro_cli="${HQ_PRO_ROOT}/src/agents/inbox-watcher-cli.ts"
  fi
  # Common sibling layout: repos/private/hq-pro next to hq-core-staging.
  if [ -z "$pro_cli" ] || [ ! -f "$pro_cli" ]; then
    local guess
    guess="$(cd "$(session_parity_repo_root)/.." 2>/dev/null && pwd)/hq-pro/src/agents/inbox-watcher-cli.ts"
    if [ -f "$guess" ]; then
      pro_cli="$guess"
    fi
  fi
  if [ -n "$pro_cli" ] && [ -f "$pro_cli" ]; then
    local name base missing=0
    for f in "$cdir"/*.txt; do
      [ -f "$f" ] || continue
      base="$(basename "$f" .txt)"
      # Count-guard AC: const NAME = declarations must cover fixture files.
      # Some values are aliases (SLACK_FORMATTING = SLACK_WRITING_FORMAT); still
      # require the brief constant name itself to appear as `const NAME`.
      if ! grep -qE "const[[:space:]]+${base}[[:space:]]*=" "$pro_cli" 2>/dev/null; then
        printf 'constant count guard: %s missing `const %s =` in %s' "$base" "$base" "$pro_cli"
        missing=1
        break
      fi
    done
    if [ "$missing" -ne 0 ]; then
      return 1
    fi
  fi
  return 0
}

# session_parity_grep_value <haystack_file> <needle_file>
#   Return 0 if needle file contents appear in haystack.
session_parity_grep_value() {
  local haystack="${1:-}" needle_file="${2:-}"
  [ -f "$haystack" ] && [ -f "$needle_file" ] || return 1
  # Use fgrep fixed-string of first line (all constants are single-line).
  local needle
  needle="$(tr -d '\r' < "$needle_file")"
  [ -n "$needle" ] || return 1
  grep -F -q -- "$needle" "$haystack"
}

# session_parity_assert_constants <fixture_id> <system.txt> <user.txt>
#   Grep expected/forbidden constant VALUES; print hits as "NAME in file".
session_parity_assert_constants() {
  local id="${1:-}" system_txt="${2:-}" user_txt="${3:-}"
  local cdir name f expected forbidden
  cdir="$(session_parity_constants_dir)"
  expected="$(session_parity_expected_constants_for "$id")"
  forbidden="$(session_parity_forbidden_constants_for "$id")"

  for name in $expected; do
    f="${cdir}/${name}.txt"
    [ -f "$f" ] || { printf 'missing constant fixture %s' "$name"; return 1; }
    if session_parity_grep_value "$system_txt" "$f"; then
      printf '  constant %s hit in system.txt\n' "$name"
    elif session_parity_grep_value "$user_txt" "$f"; then
      printf '  constant %s hit in user.txt\n' "$name"
    else
      printf 'constant %s VALUE not found in system.txt or user.txt for %s' "$name" "$id"
      return 1
    fi
  done

  for name in $forbidden; do
    f="${cdir}/${name}.txt"
    [ -f "$f" ] || continue
    if session_parity_grep_value "$system_txt" "$f" || session_parity_grep_value "$user_txt" "$f"; then
      printf 'constant %s VALUE unexpectedly present for %s' "$name" "$id"
      return 1
    fi
  done
  return 0
}

# session_parity_normalize_assembled <src> <dest> [hq_root]
#   Rewrite absolute fixture HQ roots to the stable token <HQ_ROOT> so goldens
#   do not embed /tmp or /var/folders paths (durable-writes resolved dir).
session_parity_normalize_assembled() {
  local src="${1:-}" dest="${2:-}" root="${3:-${HQ_AGENT_WORKDIR:-}}"
  [ -f "$src" ] || return 1
  python3 - "$src" "$dest" "$root" <<'PY'
import os
import sys

src, dest, root = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, "r", encoding="utf-8").read()
roots = set()
for candidate in (
    root,
    os.path.realpath(root) if root else "",
    os.path.abspath(root) if root else "",
):
    if not candidate:
        continue
    roots.add(candidate)
    if candidate.startswith("/var/"):
        roots.add("/private" + candidate)
    if candidate.startswith("/private/var/"):
        roots.add(candidate[len("/private") :])
for r in sorted(roots, key=len, reverse=True):
    text = text.replace(r, "<HQ_ROOT>")
open(dest, "w", encoding="utf-8").write(text)
PY
}

# session_parity_compare_golden <fixture_id> <assembled_file> <kind:system|user> <update:0|1>
session_parity_compare_golden() {
  local id="${1:-}" assembled="${2:-}" kind="${3:-}" update="${4:-0}"
  local golden normalized
  golden="$(session_parity_goldens_dir)/${id}.${kind}.txt"
  normalized="$(mktemp)"
  session_parity_normalize_assembled "$assembled" "$normalized" "${HQ_AGENT_WORKDIR:-}" \
    || { rm -f "$normalized"; printf 'normalize failed for %s' "$id"; return 1; }
  if [ "$update" = "1" ]; then
    mkdir -p "$(dirname "$golden")"
    cp "$normalized" "$golden"
    rm -f "$normalized"
    printf 'updated golden %s\n' "$golden"
    return 0
  fi
  if [ ! -f "$golden" ]; then
    rm -f "$normalized"
    printf 'missing golden for fixture %s (%s): %s' "$id" "$kind" "$golden"
    return 1
  fi
  if ! cmp -s "$normalized" "$golden"; then
    rm -f "$normalized"
    printf 'golden drift in fixture %s (%s.txt)' "$id" "$kind"
    return 1
  fi
  rm -f "$normalized"
  return 0
}
