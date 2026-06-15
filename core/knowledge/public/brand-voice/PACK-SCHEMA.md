# Brand-voice pack schema

A pack is a self-contained directory. Minimum contents:

- `pack.yaml` — manifest.
- `voice-guide.md` — the voice in prose: tone, diction, rhythm, do / don't.
- `samples/` — real writing in the target voice, for calibration.

## pack.yaml

```yaml
id: acme-voice              # unique, kebab-case; matches registry + voice_pack value
version: 1.0.0
type: voice
scope: company             # global | company
company: acme              # required when scope: company
extends: hq-plain          # optional: inherit from another pack id, override below
description: >-
  One or two lines on who this voice is for and how it should feel.
```

## voice-guide.md

Free-form Markdown, but cover at least:

- **Tone** — the feeling a reader should get (plain, warm, blunt, formal, playful).
- **Diction** — words to favor and words to avoid (beyond the universal AI-tell
  list in the `/humanize` skill). Name the jargon this voice never uses.
- **Rhythm** — sentence length and variation; how paragraphs open.
- **Person and stance** — first person? Opinions allowed? How much hedging?
- **Do / don't** — a short table or list of concrete rules.
- **Before / after** — at least one rewrite showing the voice applied.

The guide layers on top of, and never contradicts, the universal AI-writing-tell
removal in `core/policies/humanize-generated-content.md` and the `/humanize`
skill. A pack adds voice; it does not re-introduce em dashes or hype.

## samples/

One or more Markdown or text files of genuine writing in this voice. The pass
reads them the way the `/humanize` skill reads a writing sample for voice
matching. More samples, closer match. Keep them real; invented samples teach the
model a voice nobody actually writes in.

## extends

When `extends: <id>` is set, the pass loads the parent pack first, then applies
this pack's guide and samples on top. Use it for a company voice that starts
from `hq-plain` and diverges in a few places, so you only document the deltas.
