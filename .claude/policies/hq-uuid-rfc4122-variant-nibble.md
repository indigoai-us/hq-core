---
id: hq-uuid-rfc4122-variant-nibble
title: UUID test fixtures must honor RFC 4122 variant nibble
scope: global
trigger: writing UUID string literals as test fixtures against a validator that enforces RFC 4122 shape (version + variant bits)
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

ALWAYS ensure the 4th group (positions 20-23) of a UUID test fixture starts with `8`, `9`, `a`, or `b` when the validator uses an RFC 4122 regex like `[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}`.

- WRONG: `11111111-2222-3333-4444-555555555555` (4th group starts with `4` — variant=0, fails regex)
- RIGHT: `11111111-2222-3333-8444-555555555555` (4th group starts with `8` — RFC variant=10xx)
- Also RIGHT: `...-9xxx-...`, `...-axxx-...`, `...-bxxx-...`

Also verify the 3rd group starts with `1`-`5` (the version nibble). A version-1 fixture uses `1xxx`, a version-4 uses `4xxx`.

## Rationale

A test suite caught this when a validator accepted every real UUID from the codebase but silently rejected the "obvious" all-same-digit fixture. RFC 4122 reserves two specific nibbles — version (char 14) and variant (char 19). Common placeholder shapes like `aaaa-aaaa-aaaa-aaaa-...` or incrementing digits look like UUIDs but fail the strict regex because the variant bits aren't `10xx` binary. Any test validator that rejects fixtures but accepts production data is dead weight; fixing the fixture is correct, loosening the regex is wrong.
