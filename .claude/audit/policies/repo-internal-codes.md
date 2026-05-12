---
id: hq-core-staging-internal-codes
title: HQ internal product/company codes
scope: repo
trigger: code review
enforcement: hard
public: false
version: 1
---

| field | value |
|-------|-------|
| rule_id | repo/hq-internal-code |
| pattern | `(?:HQ-PRO|INDIGO-CONFIDENTIAL|HQ-INTERNAL-DRAFT)-\d{3,5}` |
| severity | high |
| redaction | replace with `${REDACTED:internal-code}` |

## Rule

HQ internal-product and confidential project codes (e.g. `HQ-PRO-1234`,
`INDIGO-CONFIDENTIAL-456`) refer to unannounced products or commercially
sensitive draft features. They appear in private planning documents but
should never land in committed code or PR diffs intended for review.

If found in a PR, redact to `${REDACTED:internal-code}` and post a
finding so the human reviewer can confirm the intent (sometimes these
codes legitimately appear in changelogs after announcement — but the
default assumption is "should not be here").

## Rationale

The org default scanner doesn't know about HQ-specific codename schemes.
This repo-level scanner adds them. As more codenames retire or
graduate to public, edit this file to remove their patterns.
