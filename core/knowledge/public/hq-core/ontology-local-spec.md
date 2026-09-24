---
type: reference
domain: [knowledge, engineering]
status: canonical
tags: [ontology, signals, sources, audience, spec]
---

# Local ontology, signals, and sources — storage and audience spec

This is the contract every writer and reader of a company's local `ontology/`,
`signals/`, and `sources/` folders follows. Writers: `/checkpoint`, `/handoff`,
`/learn` (candidates only), the ontology worker (`garden`, `process-source`).
Readers: `/ontology`, `/signals`, `hq sources|signals`, `/meeting-notes`.

All paths are relative to `companies/{co}/`.

## The audience rule

A signal or fact is readable only by the people who were privy to the source it
came from. The audience is fixed at capture time and never widened later.

| Source | Audience |
|---|---|
| Email | every address on the chain (from, to, cc) |
| Slack | members of the channel at message time |
| Meeting | attendees who were present on the call |
| HQ session | the session's user, unless the content is a company-wide artifact (a merged PR, a knowledge doc, a company policy) |
| Company knowledge / policy | `company` |

A source with no recorded audience is skipped. It is never defaulted to
`company`.

### Audience key

Every audience is reduced to a stable key used in paths and in dedup:

- `company` — everyone in the company.
- Otherwise the first 16 hex characters of
  `sha256(join(",", sort(unique(principal))))`, where each principal is
  trimmed, emails are lowercased, and person/agent uids (`prs_…`, `agt_…`) keep
  their case. Meeting attendees usually arrive as uids from the source's vault ACL.

`a@x.com,b@x.com` and `B@x.com, a@x.com` produce the same key. The principal
list for a key is recorded once, at `signals/@{key}/_audience.yaml`
(`principals: [...]`), inside the scoped folder so it inherits the same access.

## Layout

```
ontology/
  entities/{type}/{slug}.md              # shared: name, type, aliases only
  facts/@{key}/{type}/{slug}.md           # facts about an entity, one file per audience
  _candidates/{YYYY-MM-DD}/{sha256}.md    # entity candidates (writer-local, not synced)
  _candidates/_done/{YYYY-MM-DD}/...      # processed candidates
  _rejected/{YYYY-MM-DD}.jsonl            # stopword / type-conflict rejections
  .last-run                               # garden watermark (epoch ms)
signals/
  {type}/{sha256}.md                      # audience = company
  @{key}/{type}/{sha256}.md               # scoped audience
  @{key}/_audience.yaml                   # principals for that key
  _candidates/{YYYY-MM-DD}/{sha256}.md    # signal candidates (writer-local, not synced)
  _index/{YYYY-MM-DD}.json                # daily ledger of promoted signals
sources/
  {channel}/source.yaml                   # see source-yaml-spec.md
  {channel}/@{key}/...                    # raw items for that audience
  _index/{YYYY-MM-DD}.json
```

`{type}` for entities is one of `person`, `project`, `company`, `concept`.
`{type}` for signals is one of the eight canonical types: `action_item`,
`commitment`, `decision`, `risk`, `question`, `key_point`,
`participant_contribution`, `summary`.

## Entity files carry no fact text

`ontology/entities/{type}/{slug}.md` is visible to the whole company, so it holds
only identity:

```yaml
---
type: person
canonical_name: Jane Doe
slug: jane-doe
aliases: [jane, jane@acme.com]
signal_count: 12
first_seen: 2026-09-01T10:00:00Z
last_updated: 2026-09-22T18:00:00Z
enriched_by: ontology-worker
---
```

Everything else about the entity — what it decided, what it owns, who it works
with — is a fact and lives in `ontology/facts/@{key}/{type}/{slug}.md`, where
`{key}` is the audience of the source the fact came from. A reader sees the
facts for the audiences they belong to and nothing else.

`signal_count` counts only company-audience signals, so a scoped conversation
cannot be inferred from a shared number.

## Candidates

Session-close skills never write canon. They write candidates, and the ontology
worker promotes them. Candidate frontmatter is required:

```yaml
---
kind: signal            # or entity
type: decision          # signal type, or entity type
audience_key: company   # or 16-hex key
audience: [a@x.com]     # principals; omitted when audience_key is company
source_ref: handoff:T-20260922-...  # where it came from
created_by: corey@example.com
created_at: 2026-09-22T21:00:00Z
---
<one-line canonical statement, or the entity name>
```

The candidate file name is `sha256(kind, type, audience_key, normalized body)`.
Writing the same candidate twice is a no-op.

## Dedup never crosses audiences

The dedup key for signals and facts includes `audience_key`. Two identical
decisions heard in two different meetings with different attendees are two
signals. Merging them would show one meeting's citations to the other meeting's
attendees.

## Sync and access

- `_candidates/` and `_rejected/` are not synced. They belong to the writer's
  machine until the worker promotes them.
- On a cloud-backed company, the worker grants read on each `@{key}/*` shared glob (never the bare `@{key}/` private-folder pattern) to
  each principal in that audience, and `@all` read only on company-audience
  paths. No member-baseline grant covers `ontology/`, `signals/`, or `sources/`.
- Because sync pull only delivers what the caller may read, a reader's local
  tree already contains exactly their visible facts and signals. Readers render
  from the local tree and never write a shared brief file.

## Readers that depend on this schema

`/ontology` (entity files + facts), `/signals` (signal frontmatter and paths),
`hq sources|signals` (types and ids), `/meeting-notes` (sources/meetings). The
entity frontmatter fields and the eight signal types above are unchanged from
the cloud gardener's schema; only the location of fact text and the `@{key}`
scoping are new.
