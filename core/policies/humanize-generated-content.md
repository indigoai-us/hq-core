---
id: humanize-generated-content
when: always
on: [SessionStart]
enforcement: hard
tags: [content, writing, email, blog, social, marketing, copy, voice, humanize, deliverable]
public: true
created: 2026-05-28
provenance: user-correction
supersedes-scope-of: email-humanize
---

## Rule

Whenever you generate or substantially revise a human-facing prose deliverable, you must run the humanize pass defined in the `/humanize` skill (`.claude/skills/humanize/SKILL.md`) before delivering it. This is not limited to email. It applies to any content a real person will read as finished writing.

This rule restores a general capability that had been narrowed to email-only (`email-humanize`). The humanize pass is now mandatory across all content generation, with `email-humanize` remaining as the email-channel-specific reinforcement.

### What this applies to

Run the pass on:

- Email (cold outreach, replies, follow-ups) — already covered by `email-humanize`, still required here.
- Blog posts, essays, and long-form articles (including MDX written to any personal or company website repo).
- Social posts and drafts (X, LinkedIn, threads, captions).
- Marketing and landing-page copy, product descriptions, ad copy, announcements.
- Outreach and sales messaging, intros, and bios.
- External-facing documentation, READMEs, and release notes meant for human readers.
- Any deliverable a user explicitly asks you to "write," "draft," "compose," or "polish" for an external audience.

### What this does NOT apply to

This rule governs finished human-facing prose, not the working surface of a coding session. Do not apply it to:

- Source code, code comments, commit messages, or PR descriptions.
- Terse HQ session chat, status updates, and tool-call narration (those follow the HQ chat voice, which is intentionally terse).
- Internal scratch notes, plans, checkpoints, and handoff threads written for future-Claude rather than an external reader.
- Structured machine data (JSON, YAML, config, `prd.json`).
- Verbatim quotes, citations, or content the user supplied and asked you to preserve exactly.

When the deliverable type is ambiguous, default to running the pass; over-applying to genuine prose is cheap, while shipping obvious AI tells to an external audience is the failure this rule exists to prevent.

### How to comply

1. Produce your draft.
2. Run the internal audit step from the skill: ask "what makes this obviously AI generated?" and name the remaining tells.
3. Revise into a final version that addresses them and contains no em dashes or en dashes.
4. For the owner's first-person content, calibrate voice against `personal/agents-profile.md`; for company content, against that company's brand voice knowledge.

When the user explicitly invokes `/humanize` on existing text, deliver the full draft → audit → final loop. When the pass runs inline as part of producing a deliverable, the audit step is still mandatory, but you may present only the final result.

### Outbound enforcement (humanize before send)

For outbound communication channels the pass has an enforced seam at the
draft → send step. Each outbound skill (`dm`, `work-broadcast`,
`social-publisher` / `post`, `hq-cowork-dm`) runs the shared, channel-aware
"humanize before send" block (`core/knowledge/public/hq-core/humanize-before-send.md`)
on the human-readable body before the message is sent. Intensity is per-channel
and configurable via `personal/settings/communication-preferences.yaml` and
`companies/{co}/settings/communication/preferences.yaml` (company over global),
and voice can be calibrated with a brand-voice pack
(`core/knowledge/public/brand-voice/`). The `enforce-humanize-before-send` Stop
hook (`.claude/hooks/enforce-humanize-before-send.sh`, routed via `hook-gate.sh`)
is the backstop: it scans the just-finished turn for an outbound send whose body
still carries a cluster of AI-writing tells and blocks once with a corrective
directive. Loop-safe via `stop_hook_active`; fail-open on any error.

### Why this is hard-enforcement

AI writing tells (em dashes, rule-of-three, inflated significance, promotional vocabulary, sycophantic framing, generic upbeat conclusions) are immediately recognizable to readers and undermine the credibility of anything published under the owner's or a company's name. The cost of the pass is low and the cost of shipping slop to a real audience is high, so the pass is required rather than optional.
