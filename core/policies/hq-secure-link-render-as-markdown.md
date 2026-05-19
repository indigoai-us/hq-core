---
id: hq-secure-link-render-as-markdown
enforcement: hard
public: true
scope: global
trigger: any assistant turn that surfaces a single-use / capability link minted by an HQ command — `hq files share` (without `--with`) share-session URLs, `hq secrets generate-link` URLs, `hq invite` claim/magic links, or any analogous short-lived credential-bearing URL
tags: [security, hq-cli, vault, capabilities, secrets, ux]
created: 2026-05-18
provenance: user-directive
---

## Rule

When an HQ command produces a secure capability link and the assistant surfaces it to the user (the minting turn), the link MUST be rendered **only** as a Markdown inline link:

```
[<purpose> — expires <timestamp> ›](<full-url-with-token-intact>)
```

In that same turn:

- NEVER print the bare URL or the token as visible text — no "here's the link: https://…", no code-fenced URL, no echoed token segment, no plaintext fallback alongside the Markdown link.
- The visible **label** MUST NOT contain any portion of the token, nonce, or secret. The label carries only human-readable purpose plus the expiry the CLI reported (e.g. `Open share-session link — expires 03:47Z ›`).
- The **href** MUST be the complete, unmodified, working URL (token intact) so the single click redeems successfully.
- Exactly one such Markdown link per minted capability. Do not also restate it.

In-scope link types:

- `hq files share <prefix>` (no `--with`) — share-session URLs (`/share-session/<token>`)
- `hq secrets generate-link <PATH>` — secret-submission URLs (`/secrets-input/<token>`)
- `hq invite` — claim / magic links the CLI emits back to the agent (e.g. the `--no-email` path where the recipient must be told out-of-band)
- Any future HQ command that returns a single-use or otherwise credential-bearing capability URL

Out of scope (may be rendered as plain visible URLs): non-secret links such as the `/deploy` public app URL, the `/deploy` localhost preview URL, and the onboarding signup URL. These are not capabilities and the plaintext-exposure concern does not apply.

## Rationale

A capability URL printed as plaintext is exposed three ways the Markdown form removes: it is shoulder-surfable on screen, it is trivially text-selected and pasted somewhere it should not live, and it sits in terminal scrollback as a copyable blob. Rendering it as `[label](url)` keeps the link one-click usable while the token never appears as visible text — only the click target carries it.

This composes with, and does not replace, `hq-share-session-urls-are-capabilities`:

- **This policy** governs the *render form at the minting turn* — Markdown link, never bare text.
- **`hq-share-session-urls-are-capabilities`** governs *persistence and reuse* — the token (in any form, bare or inside a Markdown href) must never be written to a subsequent assistant turn, summary, thread file, journal, learning, commit message, PR body, or any durable artifact. There, the redacted text form `https://hq.{co}.com/share-session/<TOKEN_REDACTED>` is the only permitted representation.

A Markdown href still embeds the live token in the transcript JSONL, so it is exactly as sensitive to persist as a bare URL. This policy reduces *on-screen* exposure at mint; it does not relax the persistence ban.

## How to apply

- **Minting turn**: emit one Markdown inline link, label = purpose + expiry, href = full URL. Nothing else carrying the token.
- **If the recipient says the link failed**: mint a fresh one (single-use by design) and render the new one the same way — never re-emit the prior token in any form.
- **Subsequent / persisted context**: no link at all — describe the action and use the `<TOKEN_REDACTED>` text form per `hq-share-session-urls-are-capabilities`.
- **Headless / `--no-open` / no-Markdown sinks** (background orchestrators, scheduled tasks, plain-text side channels): the Markdown-render requirement assumes a Markdown-rendering chat surface. When the sink cannot render Markdown, the capabilities policy still applies in full; coordinate the human handoff over a channel that can, rather than dumping a bare token.

## Detection (future hook target)

A future PreToolUse/Stop hook could pattern-match an assistant turn containing `/share-session/[A-Za-z0-9_-]{40,}` or `/secrets-input/[A-Za-z0-9_-]{40,}` that is NOT wrapped in a Markdown `](…)` href, and warn (mint turn) or block (persisted surface, per the capabilities policy).
