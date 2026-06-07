---
id: hq-html-target-blank-noopener
title: Always pair target="_blank" with rel="noopener" to prevent reverse-tabnabbing
scope: global
trigger: when writing HTML with external links that open in a new tab
when: .html
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-04-28
updated: 2026-04-28
source: session-learning
---

## Rule

ALWAYS: Pair `target="_blank"` with `rel="noopener"` on every external `<a>` in HTML decks, sites, and templates:

```html
<!-- Correct -->
<a href="https://example.com" target="_blank" rel="noopener">Link</a>

<!-- Also acceptable (noreferrer implies noopener) -->
<a href="https://example.com" target="_blank" rel="noopener noreferrer">Link</a>

<!-- NEVER -->
<a href="https://example.com" target="_blank">Link</a>
```

This is especially critical for HTML presentations, investor decks, and client-facing sites where the audience may include security-aware reviewers or IT gatekeepers who inspect markup.

## Rationale

Without `rel="noopener"`, a page opened via `target="_blank"` retains a reference to the opener via `window.opener`. A malicious or compromised destination page can call `window.opener.location = 'phishing-site'` to silently redirect the original tab (reverse-tabnabbing). Modern browsers (Chrome 88+, Firefox 79+) default to `noopener` for cross-origin links, but older browsers do not. Explicitly setting `rel="noopener"` is belt-and-suspenders and signals security awareness to anyone reviewing the source.

`noreferrer` additionally prevents sending the `Referer` header — useful for privacy but not required for tabnabbing protection.
