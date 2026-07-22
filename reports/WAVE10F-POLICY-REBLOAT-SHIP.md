# Wave 10-F — Policy Re-bloat Hardening Ship Note

Feedback UUID: `8a2bda75-1d19-4df3-8026-0cd8c6eabe25`

## Confirmed re-bloat mechanism

`core/scripts/migrate-policy-triggers.sh` runs from the SessionStart hook and
backfills policies that do not already declare `when:`. Before this change,
`build_when()` used `when: always` + `on: [SessionStart]` whenever neither the
legacy `trigger:` prose nor `tags:` produced a usable signal, without checking
the policy's enforcement level.

That fallback feeds directly into `.claude/hooks/inject-policy-on-trigger.sh`.
The injector treats every policy whose `on:` contains `SessionStart` as a
per-session baseline, evaluates `when:` against the event facts, and can
backfill a missed baseline on the first later prompt or Bash event. Because the
reserved `always` fact is present in every fact set, every policy promoted by
the old fallback joined the always-injected baseline. Repeated `/learn` output
with no derivable trigger therefore re-filled the policy injection set even
after the old prebuilt digest path had been retired.

## Enforcement-gated fallback

- `core/scripts/migrate-policy-triggers.sh:133` passes enforcement into
  `build_when()` and normalizes plain, quoted, and inline-commented values.
- `core/scripts/migrate-policy-triggers.sh:161` emits `always` + SessionStart
  only when the normalized value is exactly `hard`.
- `core/scripts/migrate-policy-triggers.sh:184` reads each policy's enforcement;
  lines 187-190 leave a trigger-less non-hard policy unchanged when
  `build_when()` reports that no fallback is allowed.
- Hard-policy behavior is unchanged. A trigger-less hard policy still joins the
  SessionStart baseline. Policies with a real derived trigger still receive the
  live event set and inject reactively.
- The current behavior and `/learn` authoring guidance are recorded in
  `core/knowledge/public/hq-core/policies-spec.md` and
  `.claude/skills/learn/SKILL.md`.

## Dead digest code retired

Repository and call-site searches confirmed that the former
`core/scripts/build-policy-digest.sh` generator,
`.claude/hooks/load-policies-for-session.sh` loader, and
`core/policies/_digest.md` artifact are no longer tracked and have no live
caller. The remaining executable legacy surface was the special `_digest.md`
exemption:

- Removed the `_digest.md` scan exclusion from
  `core/scripts/migrate-policy-triggers.sh` and
  `.claude/hooks/inject-policy-on-trigger.sh`.
- Removed the `_digest.md` write-validation bypass from both engines in
  `.claude/hooks/validate-policy-frontmatter.sh`.
- Changed the validator regression so an attempted legacy digest artifact with
  no trigger frontmatter is blocked instead of silently exempted.

Historical changelog/release-note references remain as history. The live
mid-session company hard-policy emitter in `core/scripts/hq-session.sh` also
remains: `cmd_set()` calls it when `company_slug` changes, so it is not dead
code and removing it would weaken hard-policy surfacing.

## Tests

Added `core/scripts/tests/migrate-policy-triggers.test.sh` and wired it into a
dedicated `policy-trigger-migration` PR job. It proves:

1. A trigger-less hard policy still receives `when: always` and
   `on: [SessionStart]`, then injects at SessionStart.
2. Trigger-less soft and unset-enforcement policies receive neither field and
   inject neither at SessionStart nor on a later prompt.
3. A normal derived `deploy` trigger still receives the live event set and
   injects on a matching prompt.
4. A second migration remains byte-for-byte idempotent.

The same CI job runs `validate-policy-frontmatter.test.sh` to cover retirement
of the digest exemption. Local validation also passed baseline bounds, scope
precedence, personal overlay, agent-session policy ordering/truncation,
Codex preflight, preferred-capability triggers, Python-free hook operation,
shell portability, shell syntax, and `git diff --check`.

## PR, CI, and merge verification

- PR: [#412](https://github.com/indigoai-us/hq-core-staging/pull/412)
- Target: `indigoai-us/hq-core-staging:main`
- Required checks: `pr-checks` and `PR Audit` (final head status verified before
  merge; the linked PR is the authoritative run and merge record).
- Merge: the linked PR is merged only after both required checks are green;
  final state and merge commit are verified through the PR record.
