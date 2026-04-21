---
id: email-humanize
title: Humanize all outbound email content
scope: command
trigger: /email, /checkemail, mcp__gmail__send_email, mcp__gmail__draft_email
enforcement: hard
created: 2026-03-04
---

## Rule

Before sending or drafting any outbound email (cold outreach, replies, follow-ups), run the content-brand humanize pass:

1. **No em dashes in subject lines.** Use colons, commas, or shorter subject. Em dashes render as mojibake in some clients.
2. **No em dashes in body copy.** Replace with periods, commas, or restructure the sentence. Max 1 em dash per email if absolutely necessary.
3. **Strip AI vocabulary:** delve, tapestry, landscape, foster, garner, underscore, crucial, enhance, intricate, pivotal, showcase, vibrant, additionally, furthermore.
4. **No copula avoidance:** "serves as" -> "is", "functions as" -> "is".
5. **Vary sentence rhythm.** Mix short punchy sentences with longer ones. No 3+ consecutive sentences of similar length.
6. **No formulaic structure.** Don't open with "I hope this email finds you well." Don't close with "I look forward to hearing from you."
7. **First-person voice, specific examples.** Name real products, real numbers, real outcomes.

