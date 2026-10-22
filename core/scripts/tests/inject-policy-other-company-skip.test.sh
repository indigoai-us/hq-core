#!/usr/bin/env bash
# hq-core: public
# inject-policy-other-company-skip.test.sh
#
# Regression contract for feedback_9eda6433-cd27-45e0-961f-d3b57ff6d5b3:
# a session locked to one company was shown personal, repo and core policies
# written for another client, because only the per-company policy
# directories were filtered by the session lock.
#   [a] session locked to acme: a soft policy that names another company
#       explicitly (frontmatter `company:` or `companies:`) is skipped; a policy naming acme,
#       or naming no company, still surfaces.
#   [b] a policy whose `companies:` lists a locked company and another one
#       surfaces.
#   [c] no company locked: nothing is skipped.
#   [d] a multi-company lock admits every locked company's policies.
#   [e] another company's own policy directory still never loads under an
#       acme lock, even when cwd is inside that company.
#   [f] a bare `when:` word that equals a company folder name (live, beta)
#       is never read as a company: the policy surfaces, HARD or soft.
#   [g] a binding rule (HARD or gate) that names another company explicitly
#       is kept: this path never drops a binding rule.
#   [h] a cwd inside a company with no lock, and a personal lock, are not a
#       company lock: nothing is skipped.
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="${HQ_TEST_INJECT_POLICY_HOOK:-$HQ_SRC/.claude/hooks/inject-policy-on-trigger.sh}"
FACT_LIB="$HQ_SRC/core/scripts/lib/trigger-fact-text.awk"
command -v jq >/dev/null || { echo "jq required"; exit 2; }
[ -r "$FACT_LIB" ] || { echo "missing $FACT_LIB"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--version" ]; then printf '%s\n' 'hq 5.342.5'; exit 0; fi
with_intent=0
for arg in "$@"; do [ "$arg" = --with-assistant-intent ] && with_intent=1; done
text="$(jq -r '.prompt // ""')"
facts="always $(printf '%s\n' "$text" | awk -v mode=all -f "$FAKE_FACT_LIB" | tr '\n' ' ')"
if [ "$with_intent" -eq 1 ]; then printf '%s\n\n' "$facts"; else printf '%s\n' "$facts"; fi
EOF
chmod +x "$TMP/bin/hq"

failures=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

policy() { # <file> <id> <when> <enforcement> <marker> [extra frontmatter line]
  mkdir -p "$(dirname "$1")"
  printf -- '---\nid: %s\nwhen: %s\non: [UserPromptSubmit]\nenforcement: %s\n%s---\n\n## Rule\n\n%s.\n' \
    "$2" "$3" "$4" "${6:+$6
}" "$5" > "$1"
}
lock() { # <root> <sid> <primary> [more...]
  local root="$1" sid="$2" primary="$3"; shift 3
  local json="\"$primary\"" c
  for c in "$@"; do json="$json,\"$c\""; done
  mkdir -p "$root/workspace/sessions/$sid"
  printf 'session_id: %s\ncompany_slug: %s\n' "$sid" "$primary" > "$root/workspace/sessions/$sid/meta.yaml"
  printf '{"session_id":"%s","company_slug":"%s","company_slugs":[%s]}\n' "$sid" "$primary" "$json" \
    > "$root/workspace/sessions/$sid/scope-capability.json"
}
run() { # <root> <sid> <cwd> <prompt>
  jq -cn --arg sid "$2" --arg cwd "$3" --arg p "$4" \
    '{session_id:$sid,hook_event_name:"UserPromptSubmit",cwd:$cwd,prompt:$p}' \
    | env PATH="$TMP/bin:$PATH" FAKE_FACT_LIB="$FACT_LIB" HQ_ROOT="$1" CLAUDE_PROJECT_DIR="$1" \
        HQ_POLICY_RELEVANCE_CAP=0 HQ_INJECT_PERSONAL_SOFT=1 bash "$HOOK" 2>/dev/null || true
}
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

R="$TMP/hq"
CO="$R/companies"
mkdir -p "$R/core/policies" "$R/personal/policies" "$R/core/scripts/lib" \
  "$CO/acme/policies" "$CO/verdanote/policies" "$CO/beta" "$CO/live" "$CO/_template" \
  "$R/workspace/orchestrator/policy-trigger-state" "$R/.codex/hooks"
cp "$HQ_SRC/core/scripts/lib/session-scope-capability.sh" "$R/core/scripts/lib/"
cp "$HQ_SRC/core/scripts/hqd-hook-flag-cache-lib.sh" "$R/core/scripts/"
printf '%s\n' 'process.stdout.write("true")' > "$R/.codex/hooks/codex-explicit-path-flag.cjs"

P="$R/personal/policies"
policy "$P/vn-field.md" vn-field 'backfill' soft MARK_OTHER_FIELD 'company: verdanote'
policy "$R/core/policies/beta-list.md" beta-list 'backfill' soft MARK_BETA 'companies: [beta]'
policy "$P/acme-field.md" acme-field 'backfill' soft MARK_ACME 'company: acme'
policy "$P/plain.md" plain 'backfill' soft MARK_PLAIN
policy "$P/both.md" both 'backfill' soft MARK_BOTH 'companies: [verdanote, acme]'
policy "$P/live-word-hard.md" live-word-hard 'live || backfill' hard MARK_WORD_HARD
policy "$P/beta-word-soft.md" beta-word-soft 'beta && backfill' soft MARK_WORD_SOFT
policy "$P/vn-hard.md" vn-hard 'backfill' hard MARK_VN_HARD 'company: verdanote'
policy "$R/core/policies/vn-gate.md" vn-gate 'backfill' gate MARK_VN_GATE 'company: verdanote'
policy "$CO/verdanote/policies/vn-dir.md" vn-dir 'backfill' hard MARK_VN_DIR

echo "[a] acme lock skips soft policies written for another company"
lock "$R" s-acme acme
OUT="$(run "$R" s-acme "$R" "run the beta live backfill")"
has "$OUT" MARK_PLAIN && ok "[a] company-neutral policy surfaces" || bad "[a] plain policy missing: $OUT"
has "$OUT" MARK_ACME && ok "[a] locked-company policy surfaces" || bad "[a] acme policy missing"
has "$OUT" MARK_OTHER_FIELD && bad "[a] company: verdanote policy surfaced" || ok "[a] company: field for another company skipped"
has "$OUT" MARK_BETA && bad "[a] companies: [beta] surfaced under acme lock" || ok "[a] companies: list for another company skipped"
has "$OUT" MARK_BOTH && ok "[b] policy listing a locked company surfaces" || bad "[b] both policy missing"
has "$OUT" MARK_WORD_HARD && ok "[f] HARD rule keyed on the word live surfaces" || bad "[f] live-word HARD rule dropped"
has "$OUT" MARK_WORD_SOFT && ok "[f] soft rule keyed on the word beta surfaces" || bad "[f] beta-word soft rule dropped"
has "$OUT" MARK_VN_HARD && ok "[g] HARD rule naming another company is kept" || bad "[g] HARD rule dropped"
has "$OUT" MARK_VN_GATE && ok "[g] gate rule naming another company is kept" || bad "[g] gate rule dropped"

echo "[c] no lock: nothing skipped"
OUT="$(run "$R" s-none "$R" "run the backfill")"
has "$OUT" MARK_OTHER_FIELD && ok "[c] verdanote policy surfaces without a lock" || bad "[c] verdanote missing: $OUT"
has "$OUT" MARK_BETA && ok "[c] beta policy surfaces without a lock" || bad "[c] beta missing"

echo "[d] multi-company lock"
lock "$R" s-multi acme beta
OUT="$(run "$R" s-multi "$R" "run the backfill")"
has "$OUT" MARK_BETA && ok "[d] beta policy surfaces under acme+beta lock" || bad "[d] beta missing: $OUT"
has "$OUT" MARK_OTHER_FIELD && bad "[d] verdanote surfaced under acme+beta" || ok "[d] verdanote skipped"

echo "[e] other company's own policy dir"
OUT="$(run "$R" s-acme "$CO/verdanote" "run the backfill")"
has "$OUT" MARK_VN_DIR && bad "[e] verdanote policy dir loaded under acme lock" || ok "[e] other company dir not loaded"

echo "[h] cwd fallback and personal lock are not a company lock"
OUT="$(run "$R" s-cwd "$CO/acme" "run the backfill")"
has "$OUT" MARK_OTHER_FIELD && ok "[h] cwd-only session keeps verdanote policy" || bad "[h] cwd-only session dropped verdanote: $OUT"
lock "$R" s-personal personal
OUT="$(run "$R" s-personal "$R" "run the backfill")"
has "$OUT" MARK_OTHER_FIELD && ok "[h] personal lock keeps verdanote policy" || bad "[h] personal lock dropped verdanote: $OUT"

echo "[i] unknown company values hide nothing (#1571 review)"
policy "$P/literal-slug.md" literal-slug 'backfill' soft MARK_LITERAL_SLUG 'company: <slug>'
policy "$P/template-uncommented.md" template-uncommented 'backfill' soft MARK_TEMPLATE_LINE 'company: <slug>   # optional; see Company field below. Uncomment only with one real manifest slug'
policy "$P/comment-tail.md" comment-tail 'backfill' soft MARK_COMMENT_TAIL 'company: verdanote   # also used at acme'
policy "$P/unknown-co.md" unknown-co 'backfill' soft MARK_UNKNOWN_CO 'company: nosuchco'
policy "$P/bracketed.md" bracketed 'backfill' soft MARK_BRACKETED 'company: <verdanote>'
policy "$P/prose.md" prose 'backfill' soft MARK_PROSE 'company: verdanote client'
policy "$P/list-junk.md" list-junk 'backfill' soft MARK_LIST_JUNK 'companies: [verdanote, <slug>]'
lock "$R" s-acme2 acme
OUT="$(run "$R" s-acme2 "$R" "run the backfill")"
has "$OUT" MARK_LITERAL_SLUG && ok "[i] literal <slug> value hides nothing" || bad "[i] literal <slug> rule hidden: $OUT"
has "$OUT" MARK_TEMPLATE_LINE && ok "[i] uncommented template line hides nothing" || bad "[i] template-line rule hidden"
has "$OUT" MARK_COMMENT_TAIL && bad "[i] a word in a # comment was read as a company" || ok "[i] # comment after the slug is ignored"
has "$OUT" MARK_UNKNOWN_CO && ok "[i] a company with no folder hides nothing" || bad "[i] unknown company hid the rule"
has "$OUT" MARK_BRACKETED && ok "[i] a slug inside non-slug text names nothing" || bad "[i] <verdanote> read as verdanote"
has "$OUT" MARK_PROSE && ok "[i] slug followed by prose names nothing" || bad "[i] 'verdanote client' read as verdanote"
has "$OUT" MARK_LIST_JUNK && bad "[i] valid list item ignored next to a junk item" || ok "[i] valid list item still counts next to a junk item"
has "$OUT" MARK_OTHER_FIELD && bad "[i] known other company no longer skipped" || ok "[i] known other company still skipped"

echo "[j] explicit multi-company lock and untagged rules"
lock "$R" s-multi2 acme verdanote
OUT="$(run "$R" s-multi2 "$R" "run the backfill")"
has "$OUT" MARK_OTHER_FIELD && ok "[j] multi-company lock keeps verdanote policy" || bad "[j] multi lock dropped verdanote: $OUT"
has "$OUT" MARK_ACME && ok "[j] multi-company lock keeps acme policy" || bad "[j] multi lock dropped acme"
has "$OUT" MARK_BETA && bad "[j] beta policy surfaced under acme+verdanote lock" || ok "[j] beta policy skipped under acme+verdanote lock"
has "$OUT" MARK_PLAIN && ok "[j] untagged rule kept under a multi lock" || bad "[j] untagged rule dropped"
OUT="$(run "$R" s-unlocked "$R" "run the backfill")"
has "$OUT" MARK_PLAIN && ok "[j] untagged rule kept with no lock" || bad "[j] untagged rule dropped unlocked"
lock "$R" s-vn verdanote
OUT="$(run "$R" s-vn "$R" "run the backfill")"
has "$OUT" MARK_PLAIN && ok "[j] untagged rule kept under another company's lock" || bad "[j] untagged rule dropped under verdanote lock"
has "$OUT" MARK_ACME && bad "[j] acme policy surfaced under verdanote lock" || ok "[j] acme policy skipped under verdanote lock"

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all passed"
