# hq-core: public
# HQ Integrations you can use (Grok)

Grok-only. Claude Code and Codex get a SessionStart note, "HQ Integrations you
can use in company <slug>", listing the connected apps shared with the caller.
Grok ignores SessionStart output, so the note never reaches this session. The
same hook still runs here and keeps the per-company cache warm.

Before any task that reads, searches, creates, or updates something in an
external app (Linear, Notion, Jira, Slack, Gmail, HubSpot, Figma, and the
rest), once the session's company is bound:

1. Run `bash core/scripts/usable-integrations.sh show --company <slug>`. It
   reads the cache, refreshes it when stale, and prints each usable app with
   the exact flag to call it.
2. If the app is listed, use it through HQ before a separate MCP, web search,
   or asking the user, with the exact flag the list printed for it:
   `hq integrations tools --company <slug> <flag>`, then
   `hq integrations call <tool> --company <slug> <flag> --args '<json>'`.
3. If it is not listed, fall back as usual. If it is connected but not shared
   with you (`hq integrations list --company <slug>` shows it), say so and
   suggest asking a company admin to share it.

Use only the bound company's apps. Never list or call another company's
integrations.

Source of truth: `core/policies/hq-prefer-usable-integrations.md`.
