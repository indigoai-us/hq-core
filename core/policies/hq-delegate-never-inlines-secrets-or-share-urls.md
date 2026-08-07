---
id: hq-delegate-never-inlines-secrets-or-share-urls
enforcement: hard
public: true
when: delegate || delegation || handoff || hq-delegate
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
tags: [security, delegation, secrets, vault, capabilities, dm]
created: 2026-08-07
provenance: prd-decision
---

## Rule

Two hard constraints bind every delegation artifact and every step of the
`/delegate` flow — the manifest, `BRIEF.md`, `PICKUP-PROMPT.md`, the DM
headline/prompt/details, journal stanzas, commit messages, and any output the
skill or its helpers produce:

1. **No secret value, ever.** Secrets travel by NAME only
   (`manifest.secrets[]`, granted via `hq secrets share <name>`); the
   recipient consumes them at runtime through `hq run` / `hq secrets exec`.
   No delegation step may invoke a value-reading command (`hq secrets get
   --reveal`, `hq secrets env`, printing injected env) or interpolate a value
   into any artifact. The bundle builder and send helper scan their own
   output against `core/scripts/lib/secret-patterns.sh` and MUST fail closed
   (non-zero, nothing written or sent) on any match.

2. **No share-session URL, ever.** Delegation grants access exclusively via
   direct ACL grants (`hq files share <prefix> --with <principal>
   --permission <level>`). A share-session URL is a live, single-use
   capability token — any holder can redeem it to write ACLs in the issuer's
   name — and minting or embedding one in a delegation artifact would persist
   a capability into surfaces that outlive its safety (vault, DMs, journals).
   The send helper scans for `share-session/` shapes and aborts on a match.

A failure from either scan is the policy working. Never weaken the patterns,
whitelist a match, or route around a failed scan to make a delegation go
through.

## Rationale

A delegation bundle is designed to be copied: it is pushed to the vault,
attached to a DM, pulled onto another machine, and quoted into a fresh agent
session. Anything embedded in it escapes every boundary HQ maintains —
tenancy, ACLs, TTLs. Secret values and capability URLs are exactly the two
classes of content whose exposure cannot be undone by revoking access later:
the value is known, the token may already be redeemed. Granting by name and
by ACL keeps every access decision revocable and auditable after the
handoff; inlining either one converts a revocable grant into a permanent
leak. Enforcement lives in the helpers' fail-closed scans and their
regression tests (`hq-delegate-bundle.test.sh`, `hq-delegate-send.test.sh`,
`hq-delegate-secrets.test.sh` sentinel check), not in reviewer vigilance.
