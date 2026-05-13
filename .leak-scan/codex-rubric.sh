#!/usr/bin/env bash
# codex-rubric.sh — semantic per-file PII review via codex CLI.
#
# Used by the codex-pii-rubric matrix job in pr-checks.yml. Invoked once per
# changed policy file. Returns:
#
#   exit 0 + verdict=PASS  → silent success
#   exit 0 + verdict=EDIT  → posts a PR comment with redactions, job stays
#                            green (advisory)
#   exit 1 + verdict=DROP  → fails the job, contributor must remove the file
#                            (or flip frontmatter and re-promote)
#
# Codex auth: requires OPENAI_API_KEY (set as repo secret in workflow).
# Cost guard: only invoked on core/policies/*.md changes. Workflow caps
# matrix at max-parallel: 10 to mirror the local Phase-3 batching rule.
#
# Outputs the parsed JSON verdict on stdout for the workflow to capture.

set -euo pipefail

file="${1:-}"
if [[ -z "$file" ]]; then
  echo "Usage: $0 <policy-file>" >&2
  exit 2
fi

if [[ ! -f "$file" ]]; then
  echo "::error::file not found: $file" >&2
  exit 2
fi

prompt_file=".leak-scan/rubric-prompt.md"
deny_file=".leak-scan/denylist.yaml"
[[ -f "$prompt_file" ]] || { echo "::error::$prompt_file missing" >&2; exit 2; }
[[ -f "$deny_file" ]]  || { echo "::error::$deny_file missing"  >&2; exit 2; }

# Skip-label respected by the workflow before invoking us, but double-check.
if [[ "${SKIP_CODEX:-0}" == "1" ]]; then
  echo '{"verdict":"PASS","reason":"skip-codex-rubric label set"}'
  exit 0
fi

# Build inputs.
tokens="$(awk '
  /^companies:/ || /^persons:/ || /^domains:/ || /^products:/ || /^operational:/ { in_sec=1; next }
  in_sec && /^[a-zA-Z]/ { in_sec=0 }
  in_sec && /^  [^ #]/ {
    sub(/:.*$/, "")
    gsub(/^  /, "")
    gsub(/^"|"$/, "")
    if (length($0) > 0) print
  }
' "$deny_file")"

body="$(cat "$file")"

user_msg="$(cat <<EOF
=== DENYLIST ===
$tokens

=== FILE: $file ===
$body
EOF
)"

system_msg="$(cat "$prompt_file")"

# Run codex non-interactively. The CLI flag set is intentionally minimal —
# we want a single JSON object on stdout, no scratchpad noise.
#
# `codex exec` reads the full prompt from stdin and exits after one turn.
# codex-cli 0.125 has no `--system` / `--no-tool-use` / `--max-output-tokens`
# flags, so the system instructions are folded into the prompt itself,
# bracketed by markers that the rubric prompt explains. Any non-zero exit
# from codex itself is a job failure (treat as DROP escalation).

if ! command -v codex >/dev/null 2>&1; then
  echo "::error::codex CLI not on PATH" >&2
  exit 2
fi

combined_prompt="$(cat <<EOF
=== SYSTEM INSTRUCTIONS ===
$system_msg

=== USER REQUEST ===
$user_msg
EOF
)"

raw="$(codex exec \
  --skip-git-repo-check \
  --sandbox read-only \
  --model "${CODEX_MODEL:-gpt-5}" \
  --json \
  - <<< "$combined_prompt" 2>&1)" || {
    echo "::error file=$file::codex CLI failed: $raw" >&2
    exit 2
}

# Codex emits JSONL when --json is passed. Find the LAST line that parses as
# our verdict shape.
verdict_json="$(printf '%s\n' "$raw" \
  | grep -E '"verdict"[[:space:]]*:[[:space:]]*"(PASS|EDIT|DROP)"' \
  | tail -n1)"

if [[ -z "$verdict_json" ]]; then
  echo "::error file=$file::codex returned no parseable verdict. Raw: $raw" >&2
  exit 2
fi

# Validate JSON and extract verdict.
verdict="$(printf '%s' "$verdict_json" | python3 -c '
import json, sys
try:
    obj = json.loads(sys.stdin.read())
    print(obj.get("verdict", ""))
except Exception as e:
    sys.stderr.write(f"json parse failed: {e}\n")
    sys.exit(2)
')" || { echo "::error file=$file::malformed verdict JSON" >&2; exit 2; }

# Echo the verdict for workflow capture.
printf '%s\n' "$verdict_json"

case "$verdict" in
  PASS) exit 0 ;;
  EDIT)
    # Workflow will turn EDIT into a PR comment via the captured stdout.
    echo "::warning file=$file::codex rubric returned EDIT (see job summary)" >&2
    exit 0
    ;;
  DROP)
    echo "::error file=$file::codex rubric returned DROP — file is not portable" >&2
    exit 1
    ;;
  *)
    echo "::error file=$file::unknown verdict '$verdict'" >&2
    exit 2
    ;;
esac
