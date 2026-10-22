---
name: hq-library
description: Find, add, tag, link, fetch or remove images, videos and other media in the company's HQ Asset Library (`hq library`). Use for "find the photo of…", "what assets do we have for…", "add these images to the library", "tag this video", "get a link to the video", "send me the logo file", "remove this from the library", and for Claude using the library through the hosted HQ connector (`hq_library_*` tools) or a bot using a library API key. Not for documents, folder ACLs or sharing vault paths with people (use /hq-files or /hq-share).
allowed-tools: Bash(hq:*), Read, Glob, Grep
---

# HQ Library — the company asset library

The HQ Asset Library holds a company's images, videos and other media. The
original file lives in the company vault. Every computer keeps a small
`.hqcloud` placeholder (about 1 KB) under `companies/{company}/library/` with
the asset's title, tags, description and media kind. Teammates sync only the
placeholders, and search runs in the cloud over them.

When a person adds an image or video, the local Claude Code CLI writes an AI
description and suggested tags into the placeholder. It sends up to 4 frames
to Claude; no separate HQ caption service is used. HEIC photos are decoded
with `sips` on macOS, then ImageMagick or ffmpeg. If Claude Code is not
installed or not signed in, the caption is skipped with a note and the upload
still succeeds. For sensitive files, use `--no-caption --note "<description>"`.

## When to use this skill, and when not

| The user wants to... | Use |
|---|---|
| Find media by what is in it ("the photo of the team at the booth") | `hq library search` (this skill) |
| Add images, video or other media so the team can find them | `hq library add` (this skill) |
| Hand one file to someone right now (a download link) | `hq library link` (this skill) |
| Have the bytes on this machine to edit or attach | `hq library fetch` (this skill), only when needed |
| Delete an asset | `hq library rm` (this skill), dry run first |
| Give a person lasting access to a vault folder or file | `/hq-share` |
| Inspect or change ACLs and grants on vault prefixes | `/hq-files` |
| Find documents, notes, policies or meeting content | `/search` or `qmd` |
| Pull or push the whole company tree | `/hq-sync` |

A library download link is a 15-minute file download. It does not grant access
to anything else, and it is not a share. If the user wants a teammate to have
ongoing access, use `/hq-share`, or tell the teammate the asset title so they
can search for it themselves.

## Step 0: resolve the company and check the CLI

1. Use the session's active company. Pass `--company {company}` to `search`,
   `add`, `rm`, and `link` when linking by vault key. `ls`, `tag`,
   `describe` and `fetch` take a local path under `companies/{company}/`
   and have no `--company` flag. Never search, link or add in a company
   outside the session's locked company set. If the user asks about another company's
   assets, stop and ask them to add that company to the session first
   (`core/scripts/hq-session.sh add company <slug>`).
2. Once per session, check that `hq --version` is 5.345.155 or later (`rm`, the API-key fixes and the
   HEIC caption fix). If it is older, ask the user to upgrade with
   `npm i -g @indigoai-us/hq-cli@latest`.
3. Not signed in (`hq` says to run `hq login`)? Run `/hq-login`. Bots use an
   API key instead (see "Bots and agents").

Step 0 and the recipes below are for a machine with the hq CLI. Claude in a
chat app through the hosted connector uses the MCP tools instead (see "Claude
through the hosted HQ connector").

## Recipes

Run these from the HQ root.

### Search

```bash
hq library search <words> --company {company}            # natural language over title, tags, description
hq library search <words> --tag <tag> --company {company} # require a tag (repeat or comma-separate)
hq library search --tag launch --company {company} -n 20  # tags only, up to 20 results
hq library search <words> --company {company} --json      # placeholderPath, originalPath, title, tags, mediaKind, vaultKey, snippet
```

Search runs in the cloud and falls back to the local index when offline (the
JSON `source` field says which). Results come back best match first. Describe
what is in the picture, not the file name: "red shirt city plaza", "lofi
animation city skyline". The CLI has no media-kind filter; read `mediaKind`
(`image`, `video` or `other`) in the results, or use a tag.

Show results as a short list: title, media kind, tags, and the local
placeholder path. Do not dump raw JSON on the user. When the user asks for
"the best one", take the top result unless their words point to another; when
several fit equally, show the list and ask.

### Paths: search output vs the other commands

`search` prints company-relative paths (`library/hero.png.hqcloud`). `link`,
`tag`, `describe`, `fetch` and `rm` need the local path from the HQ root:
prefix `companies/{company}/`, giving
`companies/{company}/library/hero.png.hqcloud`. The JSON `originalPath` field
(`companies/{company}/library/hero.png`) already has the prefix, and these
commands accept it as is. `link` also accepts the `vaultKey`
(`.hq-offload/blobs/<sha256>`) together with `--company`, which works on a
machine that has no local copy of the placeholder.

### List

```bash
hq library ls companies/{company}/library               # every placeholder in the library folder
hq library ls companies/{company}/library --tag logo    # filter by tag
```

`ls` reads local placeholders. It takes a folder and has no `--company` flag.

### Add

```bash
hq library add <file-or-url>... --company {company} --tags <a,b> --title "<title>" --note "<description>"
hq library add ./shoot/*.jpg --company {company} --tags event,booth
hq library add <file> --company {company} --to companies/{company}/projects/launch/assets
hq library add <file> --company {company} --no-caption --note "<description>"
```

- Sources are local files or http(s) URLs. Each file is uploaded to the
  company vault, checked by sha256, and replaced by a placeholder.
- Default folder is `companies/{company}/library/`. `--to` must stay inside
  `companies/{company}/`.
- `--title` defaults to the file name and applies to every file in the call,
  so use it only when adding one file. `--note` sets the description.
- Without `--no-caption`, images and videos get a local AI description and
  suggested tags (see the top of this file); this takes 20 to 90 seconds per
  file. Your `--tags` stay first and the suggested tags are added after them.
  With `--no-caption`, give a `--note` so search has something to match.
- A file name already used in the target folder is refused, whatever the
  bytes. A file that is already inside the HQ tree is refused too; turn it
  into a placeholder with `hq storage offload --current <path>` instead. The
  same bytes under another name are added without a second upload.
- In shared sync mode, `add` pins the library folder (or the written
  placeholders for a `--to` folder) so desktop sync uploads them. Nothing to
  do by hand.
- Confirm with the user before adding more than 10 files at once or files
  that look personal. Everything added is visible to the whole company.

### Tag and describe

```bash
hq library tag companies/{company}/library/hero.png.hqcloud --add launch,hero --remove draft
hq library describe companies/{company}/library/hero.png.hqcloud   # re-run the AI description and suggested tags
```

### Download link (prefer this to fetch)

```bash
hq library link companies/{company}/library/hero.png.hqcloud                       # 15 minutes
hq library link companies/{company}/library/hero.png.hqcloud --expires 60          # 1 to 60 minutes
hq library link .hq-offload/blobs/<sha256> --company {company} --json              # by vault key
```

The CLI prints the link and its expiry. Give it to the user once, as one
Markdown link whose label says what it is and when it expires, for example
`[Download hero.png — expires 14:05Z ›](<url>)`. Do not print the bare URL,
and do not repeat it later (rules below).

### Fetch the original (only when the bytes are needed here)

```bash
hq library fetch companies/{company}/library/hero.png.hqcloud
```

Fetch downloads the original next to its placeholder. Use it only when the
user needs the file on this machine (to edit it, attach it, or process it). To
hand a file to someone, use `link`.

On desktop sync older than hq-cloud 6.18.94, fetch removes the placeholder,
and sync then deletes the asset from the vault for the whole team. The hq CLI
cannot report the desktop sync version, so after every fetch, turn the
original back into a placeholder as soon as the user is done. On newer sync
this keeps the existing placeholder and uploads nothing, so it is always
safe. Show the dry run, then run it:

```bash
hq storage offload --current companies/{company}/library/hero.png --idle-days 0 --min-size 1 --dry-run
hq storage offload --current companies/{company}/library/hero.png --idle-days 0 --min-size 1 --yes
```

If the user edited the file, do not offload it over the library copy. Move
the edited file outside the HQ folder (`add` refuses files inside it) and add
it as a new asset under a new name with `hq library add`. The vault copy of
the original is unchanged.

API keys cannot fetch. A bot uses `link` and downloads the URL itself.

### Remove

```bash
hq library rm companies/{company}/library/old.png.hqcloud --dry-run    # always first; show the user
hq library rm companies/{company}/library/old.png.hqcloud              # previews and asks
hq library rm companies/{company}/library/old.png.hqcloud --yes --json # after the user confirmed
hq library rm companies/{company}/library/old.png.hqcloud --purge      # also delete the stored file
```

`rm` deletes the local original (if it was fetched), the local placeholder
and the vault placeholder. If a fetched original was edited and its hash no
longer matches, `rm` refuses and removes nothing; move the file out first.
The stored file (blob) is kept unless `--purge`. `--purge` refuses when any
other placeholder uses the same blob; the check reads the full vault listing
and can take several minutes on a large company.

Removal affects the whole team. As an agent:

1. Run `--dry-run` and show the result.
2. Get a clear yes.
3. Run with `--yes`. The form without `--yes` waits for a terminal prompt,
   which an agent shell cannot answer.

Leave `--purge` off unless the user asks to delete the stored file too, and
ask again before using it.

## Claude through the hosted HQ connector

Claude, ChatGPT and other chat apps connected to the hosted hq-mcp connector
(see `core/knowledge/public/hq-core/external-agents-mcp.md`) get the library
as tools. They act as the signed-in person, in that person's company.

| Job | MCP tool | CLI equivalent |
|---|---|---|
| Search by text and/or tags, optional media kind | `hq_library_search` (`query`, `tags`, `kind`: `image`, `video` or `other`, `limit`) | `hq library search` |
| Read one asset's title, tags, description, kind, size, sha256 | `hq_library_get` (`path` from search) | `hq library ls` / the placeholder |
| Download link, 1 to 60 minutes (default 15) | `hq_library_link` (`path`, `expiresInMinutes`) | `hq library link` |
| Add one file in two calls: call 1 returns an upload URL, call 2 with `confirm: true` writes the placeholder | `hq_library_add` (`name`, `sha256`, `size`, `contentType`, optional `dir`, `title`, `tags`, `description`, `confirm`) | `hq library add` |

There is no MCP tool for tag, describe, fetch or remove. Do those with the CLI
on a machine with HQ installed. The connector writes no AI caption on add, so
pass a `description` and `tags`. The link rules below apply to connector links
too: a chat app must not post an `hq_library_link` URL into a channel. If the
user wants a channel told about an asset, give them the asset title to post,
or post the title with that chat app's own messaging tool after the user
confirms the text. Teammates find it with search and mint their own link.

## Bots and agents (API key)

A bot or headless agent without an HQ login uses a library API key in
`HQ_API_KEY`. A signed-in person creates it (keys cannot create keys):

```bash
hq api-keys --company {company} create --name "<bot> library" --preset library-agent                 # search and link
hq api-keys --company {company} create --name "<bot> library" --preset library-agent --allow-upload  # also add
```

`library-agent` grants `search:query` and `files:read`; `--allow-upload` adds
`files:write`. Store the key with `/hq-secrets` and inject it with
`hq secrets exec` or `hq run`. Never paste it into chat, a file or a commit.

With the key, the bot runs `hq library search`, `hq library link` and, with
upload, `hq library add`, always with `--company {company}`. The bot's runtime
puts the key in `HQ_API_KEY` (its platform secret store, or `hq secrets exec
--company {company} --only HQ_API_KEY -- <command>` on a signed-in host). A
bot usually has no local placeholders, so it links by the `vaultKey` from
search:

```bash
hq library search warehouse b-roll --company {company} -n 5 --json
hq library link .hq-offload/blobs/<sha256> --company {company} --expires 60 --json
```

A key without upload
rights gets "This API key cannot upload (missing files:write)". Keys cannot
`fetch`. Revoke a key that is no longer used: `hq api-keys --company {company} list`,
then `hq api-keys --company {company} revoke <keyId>`.

## Rules

1. **Company scope only.** Search, link, add and remove only in the session's
   company. Never move an asset, link or description from one company into
   another company's files, channels or services.
2. **Prefer `link` over `fetch`.** Fetch only when the user needs the bytes on
   this machine. After a fetch on older desktop sync, offload the file again
   (see Fetch).
3. **Dry run before `rm`.** Show the `--dry-run` result and get a clear yes.
   Ask again before `--purge`.
4. **A download link is a credential.** Anyone holding it can download the
   file until it expires. Give it only to the person who asked, once, as a
   Markdown link. Never paste it into Slack, a shared or public channel, an
   email to a group, a PR, a commit, a doc, a journal, a handoff or a later
   turn. In any written record use `<presigned link redacted>`. For a
   teammate or a channel, post the asset title and placeholder path (through
   `/dm` or `/hq-integrations`, after the user confirms the message) so each
   reader can mint their own link.
5. **Links expire.** Default 15 minutes, 60 at most. When a link stops
   working, mint a new one instead of looking for the old one. A large
   download over a slow connection can outlast a 15-minute link; use
   `--expires 60` for big videos.
6. **Adds are company-visible.** Ask before adding files that look personal
   or sensitive, and before large batches.
7. **Never print API keys.** Use `/hq-secrets` workflows.

## Not built yet

Say so plainly when asked. These do not exist yet:

- resized copies or other renditions (thumbnails, web sizes, format conversion)
- usage rights, licences and expiry dates on assets
- asset versions
- webhooks or notifications when assets change
- collections or albums (use tags and folders instead)
- duplicate warnings beyond the exact-bytes dedupe on add
- a desktop app screen for the library (today it is CLI, connector and API only)

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `No HQ cloud placeholder found for 'library/...'` | A company-relative path from search. Prefix `companies/{company}/`, or pass the vault key with `--company`. |
| `error: unknown option '--company'` on `ls` | `ls` takes a folder: `hq library ls companies/{company}/library`. |
| An asset vanished from search after someone fetched it | Older desktop sync deleted the placeholder (see Fetch). Re-add the file, or offload the fetched original with `hq storage offload --current`. |
| `offload` skips a fetched file as "not synced" | hq-cli older than 5.345.155. Upgrade. |
| A bot gets "Run `hq login`" on add | hq-cli older than 5.345.155, or the key has no `files:write`. Upgrade, or create the key with `--allow-upload`. |
| `rm` says the file "is not a library asset" | It is a plain storage offload pointer, not a library placeholder. Use `/hq-files` (`hq files delete`) after a dry run. |

## See also

- `/hq-share` — lasting access to vault paths for people
- `/hq-files` — ACLs, grants and raw vault operations
- `/hq-secrets` — store and inject the library API key
- `/hq-sync` — sync the whole company tree
