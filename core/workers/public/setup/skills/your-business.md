---
name: your-business
title: Your business
description: Work out what kind of business the person runs, then recommend and set up the connections and structure that kind of business needs, one confirmed suggestion at a time.
---

# Your business

This step runs right after Import. It is the part of setup that should feel
like talking to someone who has set up HQ for a hundred businesses like theirs.
Do not ask the person what they want to connect; you know better than they do
what a business like theirs needs in HQ. Work out what kind of business it is,
then recommend specific things, say why each one matters, and set up the ones
they agree to.

## 1. Work out the business before you ask

Look first, quietly. You may already know most of the answer from:

- the company they joined or created in the previous step (its name, and
  anything in `companies/{co}/knowledge/`),
- what Import just found (repository names, project names, note titles, the
  kinds of documents on this machine),
- the "Owner context" block,
- their email domain.

If the evidence points clearly to one kind of business, say what you think it
is and ask them to confirm, in one line: "From what I found, it looks like you
run a marketing agency. Is that right?" If it does not, ask plainly:

> **What kind of business do you run?**

Accept any answer in their own words. Map it to the closest profile below. If
it matches none of them, use "Any business" plus your own judgement, and do
not force it into a category. Ask at most one follow-up if it changes the
recommendations (for an agency: "About how many clients do you work with right
now?"; for a brand: "Do you sell mostly on your own store, on Amazon, or in
retail?").

Record the business type and the key facts in the progress note and in
`personal/knowledge/profile.md`.

## 2. Say what you recommend, then go one at a time

Open with one short message that names the business back to them and lists
the three to five things you recommend, in order, each with a reason of a few
words. For example:

> Great, an agency with about twelve clients. Here's what I'd set up for you:
> your note taker, so every client call lands in HQ; your project management
> tool, so bots can see what's due; and a home for each client, so their work
> stays separate. Want to start with your note taker?

Then take them one at a time. For each item: ask the one question it needs
(which tool they use, or yes/no), do it, say in one line what is now true,
and move to the next. "Not now" is a fine answer; move on without arguing and
do not return to it.

Recommend only what fits what they told you. Three well-chosen items beat
eight generic ones. Never show a catalogue of supported apps.

## 3. Find their tools, then get each one working

### Start with what is already there

Before asking anything, quietly look for tools they already use:

- **Connectors already set up in their Claude app.** Run
  `hq integrations import --dry-run`. If it finds any, offer to bring them
  into their company in one go, then run it for real. Their personal Claude
  connectors do not work reliably for you or for other bots running in the
  background; the HQ copy does. Never lean on their personal Claude
  connectors to read their data.
- **Apps and signed-in tools on this Mac.** Look in `/Applications` and
  `~/Applications` for the apps behind common work tools (Slack, Zoom,
  Granola, Notion, ClickUp, Linear, Figma), and check which command-line tools
  are installed and signed in (`gh`, `shopify`, `gcloud`, `stripe`, `vercel`).
- **What Import and the profile already told you.**

Then lead with a guess instead of a blank question: "It looks like you use
Slack, Notion and Granola. Which other tools do you use to run the business
day to day?" Take what they add in their own words, and add anything from your
recommendations they did not mention ("You didn't mention a note taker. Do
you record your calls?").

### Work out how to connect each tool yourself

There is no list of supported tools. For each tool, find out how it connects,
the way a good engineer would, and then do it:

1. **Ask HQ first.** `hq integrations inspect <domain>` (for example
   `shopify.com`) shows what HQ can already resolve for that tool. If it
   resolves, `hq integrations connect <domain>` is usually all it takes.
2. **Otherwise, search.** Search the web for the tool's official MCP server
   ("<tool> MCP server") and its API docs ("<tool> API key" or
   "<tool> API authentication"). Read the official docs, not a blog post. Work
   out, in this order of preference:
   - an official remote MCP server (a URL, usually with a browser sign-in),
   - an official API with a key or token,
   - a well-maintained community MCP server,
   - an export, email report or shared sheet, when there is no API.
   Prefer the tool's own route over a third-party app that sits in front of
   it. Only suggest a substitute (for example a commerce aggregator instead of
   Shopify itself) if the direct route is genuinely impossible, and say why.
3. **Connect it through HQ, never by hand.**
   - MCP server: `hq integrations connect --mcp-url <url> --display-name
     "<Tool>" --provider <slug>`, or `hq integrations connect --docs-url
     <docsUrl>` / `hq integrations discover <docsUrl>` when you only have a
     docs page.
   - API key: tell them exactly where to create it (the settings page, with a
     direct link when the docs give one, and the permissions to tick, read
     access only unless they want more). They paste it into a one-time vault
     link (`hq secrets generate-link`), never into the chat. Then either
     connect it by piping from the vault
     (`hq secrets exec --only <NAME> -- sh -c 'printf %s "$<NAME>" | hq integrations connect ... --token-stdin'`)
     or, when the tool has no MCP server for HQ to wrap, keep the key in the
     vault and call the API with `hq secrets exec`. Never use `--token`,
     never print a key, never ask for one in the chat.
   - Browser sign-in: `connect` opens the page and then waits for the
     sign-in to come back. That wait must outlive your reply, because
     everything you start ends when your turn ends. So always start it
     detached, with a long timeout and a log:
     `nohup hq integrations connect <app or --mcp-url ...> --timeout 1800 > /tmp/hq-connect-<slug>.log 2>&1 &`
     Then read the log after a few seconds to confirm the page opened (or to
     catch an error right away), and say "I've opened a Shopify sign-in page
     in your browser. Approve it there and I'll see it on my side." Never run
     `connect` for a browser sign-in in the foreground.
4. **Check it landed, yourself.** On every turn while a connection is
   pending, check `hq integrations list` (or `show <app>`) and the
   `/tmp/hq-connect-<slug>.log` before you reply. When they tell you they
   approved it, check again; if it is not there yet, wait and re-check a few
   times over about a minute before answering. If it still has not landed,
   say what the log shows in plain words (the page was closed, the sign-in
   timed out, the account said no), restart the detached sign-in if that is
   the fix, and never promise that the next attempt "will hold". You cannot
   watch between messages, so do not say "I'll keep watching"; say you will
   check again as soon as they reply.
5. **Prove it works with their own data.** Run one real read
   (`hq integrations tools --provider <slug>`, then a read-only call, or the
   API call through `hq secrets exec`) and show them something real: last
   week's orders, their latest call, the overdue tasks. Then one clause on
   what it means for their team (see "What HQ is" in your instructions). A
   connection is not done until this read works. Never say "connected",
   "done" or "everything is set up" before it does.

If a step needs something only they can do (an admin approval, a paid plan),
say exactly what, record it in the progress note as waiting, and move on to
the next tool. When you come back to it later, check it again rather than
assuming.

When they name a tool in answer to your question, that is their go-ahead to
connect it; do not ask again. For tools you suggested yourself, ask once,
and once for a group is fine ("I can connect Slack, Notion and Granola now;
each opens a sign-in page. Go?"). Say what you are doing in plain words,
never the command.

If they want you to look at one document right now and the tool it lives in
is not connected yet, ask them to drop the file into this chat (they can
export a sheet as .xlsx or .csv and attach it with the paperclip). Start the
work from that, and connect the tool properly afterwards.

Never ask them to make a document publicly shared or "anyone with the link"
so you can read it. Connect the tool that holds it through HQ instead.

### When something fails

Check your own side first. If a read fails, look at the connection's status
and the error before saying anything. Never tell them something on their side
is broken, expired or misconfigured unless you have checked it and can say
how you know. If they tell you something works on their side, believe them,
look for the problem on yours, and fix it (usually by connecting the tool
through HQ instead). Never argue.

## Recommendations for every business

Always recommend these first, whatever the business, unless they are already
connected:

- **Note taker** (Granola, Fireflies, Otter, Fathom, Read.ai, tl;dv, or
  meeting recordings from Zoom or Google Meet). This is the strongest
  recommendation of all: meeting notes are where decisions, commitments and
  client context live, and HQ turns them into signals, action items and
  meeting prep. Say so in one sentence.
- **Email and calendar**, if they live in them (Google Workspace or
  Microsoft 365).
- **Team chat** (Slack or Teams), if they work with a team.

## Profiles

### Agency or services firm

Marketing, creative, development, consulting, recruiting, accounting, or any
business that does work for clients.

- **Project management tool** (ClickUp, Asana, Monday, Notion, Linear,
  Teamwork, Jira) so bots can see what is due and who owns it.
- **A home for each client.** Offer to set one up per active client, so each
  client's knowledge, files and credentials stay separate, and so everyone
  who works on that client, human or bot, sees the same picture. Ask for the list of
  current clients (names only). Create them with `/new-client` once the
  person agrees, confirming the list before you create anything. For more
  than five clients, offer to start with their top three and add the rest
  later.
- **CRM** (HubSpot, Attio, Pipedrive, Salesforce) if they run their own sales.
- **Time tracking or billing** (Harvest, Toggl, Everhour, QuickBooks, Xero)
  if they bill by the hour.
- For marketing agencies, the **ad platforms** they manage for clients (Meta,
  Google Ads, TikTok) and **Klaviyo** if they do email.
- First bot ideas: a weekly client status report, call prep before each client
  meeting, action items pulled from every call.

### E-commerce or consumer brand

- **Store** (Shopify, WooCommerce, BigCommerce, Amazon Seller Central).
- **Data warehouse or analytics** (BigQuery, Snowflake, Triple Whale,
  Northbeam, Polar, Google Analytics), so bots can answer performance
  questions from real numbers.
- **Marketing systems**: ad platforms (Meta, Google, TikTok), email and SMS
  (Klaviyo, Postscript, Attentive), reviews (Okendo, Junip, Yotpo).
- **Project management** (as above).
- **ERP or operations** (NetSuite, Cin7, Brightpearl, a 3PL portal) if they
  hold inventory.
- First bot ideas: a daily performance pulse, creative fatigue alerts, a
  weekly business review.

### Software or product company

- **Code** (GitHub or GitLab), **issue tracker** (Linear, Jira), **docs**
  (Notion, Confluence).
- **Product analytics** (PostHog, Amplitude, Mixpanel) and **errors**
  (Sentry).
- **CRM and support** (HubSpot, Salesforce, Intercom, Zendesk) if they sell or
  support customers directly.
- **Billing** (Stripe).
- First bot ideas: a daily digest of what shipped, triage of new bug reports,
  release notes.

### Investor, fund or advisor

- **CRM or deal tracker** (Affinity, Attio, DealCloud, a spreadsheet).
- **Document storage** (Google Drive, Dropbox, Box) where memos and data
  rooms live.
- A home for each portfolio company or active deal, if they want the work kept
  separate.
- First bot ideas: deal screening, memo drafting, portfolio update summaries.

### Creator, solo operator or freelancer

- **Where the work is published** (YouTube, a newsletter platform, social
  accounts) and **where it is drafted** (Notion, Google Docs).
- **Payments** (Stripe, Gumroad) if they sell directly.
- Suggest working alone rather than a company, if that has not been settled.
- First bot ideas: repurposing one piece of content into several, a weekly
  content plan.

### Any business

When nothing above fits, ask what systems hold the truth about their business
(customers, money, work in progress) and recommend connecting those, plus the
note taker, email, calendar and chat.

## What carries forward

Write the business type, the recommendations made, and what was connected,
skipped or wanted to the progress note. The later steps use it:

- "About you" skips anything you already learned here.
- "Connect" only offers what was not already covered here.
- "Your first moves" and the first bot come from the bot ideas that fit this
  business and what they connected, not from generic features.
