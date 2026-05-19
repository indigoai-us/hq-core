# hq-core-staging — Repo-specific audit guidance

This file is read by `hq-audit-bot` at the top of every audit run. The
contents below override or augment the org-default scanner behavior for
this repo only.

## What this repo is

`hq-core-staging` is HQ's pre-release / staging contributor repo. The contents
include:
- The promotion target for `companies/_template/` (a starter HQ filesystem)
- Example policy files under `core/policies/`
- Example workers under `core/workers/`
- Test fixtures the audit bot itself uses (under `audit-fixtures/`)

Because this repo *describes* a security tooling system, several files
intentionally contain PII patterns, denylist-shaped strings, and policy
language that would be findings in any other repo. **Treat the patterns
in this repo as documentation, not data.**

## Specific guidance

### Audit-fixture files are intentional

Files under `audit-fixtures/` are deliberately constructed to exercise
the four scanners. Every PII pattern there is fake (RFC-5733 phone, Visa
test card, all-zero SSN). **Never flag findings under this path.**
A suppression rule in `suppressions.yaml` covers this — but trust the
path even if the suppression file is somehow missing.

### Policy markdown files are documentation

Any `.md` under `core/policies/` or `companies/_template/policies/`
may contain example regexes, sample
denylist terms wrapped in `${REDACTED}` sentinels, or "do not share
externally"-style policy language **as documentation of the rule**, not
as the violation itself. Do not flag pattern-quoted PII regexes or
discussion of denylist mechanics. Flag the actual violation only — i.e.
a real email address that isn't inside a code block describing a
detector.

### Onboarding examples mention real-sounding companies

Files under `companies/_template/` and `companies/_setup-examples/` may
reference example company names like "Acme", "Voyage", "GoClaw" — these
are scaffolding placeholders. Don't treat them as denylist hits.

## Severity overrides

- `pii/policy-language` (the "internal policy / do not share externally"
  rule): downgrade from medium → info in this repo. We discuss policy
  mechanics openly here as part of describing the system.

## When in doubt

If a finding looks like it might be documentation about a rule rather
than a real violation, **err on the side of flagging it** but include in
the comment: "this may be a documentation reference rather than a real
finding — please verify." A false positive that asks the reviewer is
better than a false negative that misses a real leak.
