---
name: add-a-pack
description: Recognize a content pack the person pastes or names (a hqforwork.com pack link, hq-pack-{slug}, a bare slug, or a display name from the catalog), confirm in one message, install it with --start-bot, and hand over to the pack's bot.
---

# Adding a pack from the chat

A pack is a bundle of workers, knowledge and a setup bot that HQ installs with
`hq packages install`. People arrive with one in three ways: they paste a link
from a pack page, they type the pack's name, or they drop a folder path. You add
it without them leaving this conversation, and you end by introducing the bot
the pack brings. This skill only adds that; nothing else about how you run setup
or answer how-do-I questions changes.

## Spotting a pack in the message

Any of these, anywhere in what they wrote, is a pack reference. Read the slug
out of it:

- `https://www.hqforwork.com/packs/{slug}`
- `hqforwork.com/packs/{slug}` (no scheme, with or without `www.`)
- `hq-pack-{slug}` (the package name)
- `{slug}` on its own, when it is in the catalog (for example `sample-kit`)
- a display name from the catalog, in plain words ("add the sample kit",
  "I want the Sample Kit"). Match case-insensitively; "sample kit" and
  "sample-kit" are the same name.
- a local folder path whose last `hq-pack-*` segment names the pack
  (`./packs/hq-pack-sample-kit`, `~/Downloads/hq-pack-sample-kit`). Keep the
  path: it is what you install from.

`sample-kit` / "Sample Kit" below is a placeholder: use the real slug and
display name from the catalog.

Slugs are lowercase letters, digits and hyphens. A link or a package name is
always a reference, even if the catalog does not list it: the slug is explicit.
A bare word or a name must match the catalog, so you never guess a pack from
ordinary conversation ("my co-founder is joining" is not a pack).

### The catalog

The catalog is what `hq packages list` prints under "Available (curated)": each
line is an install source like `github:indigoai-us/hq-packages#packages/hq-pack-design-styles`
with a description. The slug is the last segment without `hq-pack-`; the display
name is the slug in title case (`design-styles` is "Design Styles") unless the
catalog gives one. Run the list once per conversation when you need to check a
name; never invent a pack that is not there.

## Confirm first, in one message

Before you install anything, send exactly one message: the pack's display name,
its one-line description from the catalog (or from the pack page if the person
pasted a link and the catalog has no description), and what will happen: you
will add it and its bot will introduce itself. End with the suggestions
envelope, exactly these two:

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Add the {displayName}","Not now"]}]}
```

Example, for `https://www.hqforwork.com/packs/sample-kit`:

> Sample Kit: {the catalog's one-line description}. It brings its own bot, who
> will take you through its setup with a few quick questions. Want me to add it?

followed by the envelope with `["Add the Sample Kit","Not now"]`.

"Not now" (or anything that is not a yes): say "Okay, it's here whenever you
want it" and carry on with whatever you were doing. Do not ask again in that
conversation unless they bring it up.

## On "Add the ..."

Run, from the HQ root:

    hq packages install {slug-or-path} --start-bot

`{slug-or-path}` is the slug (`sample-kit`), or the local path when the message
carried one. Quote a path with spaces. Wait for it to finish; it can take a
minute. Do not narrate the steps while it runs.

Then report in **one** message:

1. What was added, in one line ("The Sample Kit is in.").
2. Where its pieces live, as Files-tab locations, only if the install output
   names any (for example Knowledge > {Pack} Playbook). Never a filesystem path.
3. The hand-over. The install output has a line `bot: {name}` when a bot was
   started. Name that bot by its display name and say it will take it from here
   in its own conversation in Messages, for example: "{Bot display name} is
   starting now and will take it from here; look for its message in Messages."
   If the output has no `bot:` line, say the pack is installed and name what it
   added instead.

That ends your part. Do not run the pack's setup yourself, do not re-ask the
pack's questions, and do not keep the conversation going about the pack: the
pack's bot owns it from here. Write one line in your progress note
(`Pack added: {slug}, bot {name}`) so a later turn knows.

## When you do not know the pack

A bare word or name that matches nothing in the catalog: say so in one line and
offer the three closest names from the catalog, as suggestions, plus "Not now".
For example:

> I don't know a pack called "growth-kit". The closest I have are Sample Kit,
> Field Notes and Design Styles.

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["Add the Sample Kit","Add the Field Notes","Add the Design Styles","Not now"]}]}
```

If the catalog has fewer than three packs, offer what there is. Never offer a
name you did not see in the list.

## When the install fails

Say what went wrong in plain words and give one next step, in one message. Take
the reason from the command's output, not from a guess, and translate it:

- not signed in to HQ Cloud: "I couldn't add the pack because you're not signed
  in to HQ Cloud. Sign in from the HQ app, then tell me to try again."
- no network or the registry did not answer: "I couldn't reach the pack
  registry. Check your connection and tell me to try again."
- the pack was installed but its bot did not start (the output says so): "The
  Sample Kit is in, but its bot didn't start: {reason in plain words}. Open
  Bots in HQ and start {bot display name}, or tell me to try again."
- anything else: quote the one line of the error that says what happened, in
  plain words, then: "Tell me to try again, or send me the link once more."

End that message with `["Try again","Not now"]` as the suggestions. Never paste
a stack trace or a wall of command output into the chat.
