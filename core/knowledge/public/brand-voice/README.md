# Brand-voice packs

A brand-voice pack defines how outbound prose should sound. It is the voice
counterpart to a design-styles pack, and it follows the same shape on purpose:
a registry, a pack schema, a `_template/` scaffold, and one directory per pack.

Voice packs feed the humanize-before-send pass. When a communication channel
sets `voice_pack: <id>` in its preferences
(`core/knowledge/public/hq-core/humanize-before-send.md`), the pass reads that
pack's `voice-guide.md` and `samples/` and calibrates the rewrite to it, on top
of the standard AI-tell removal from the `/humanize` skill.

## Layout

- `registry.yaml` — one row per pack (`id`, `version`, `scope`, `path`).
- `PACK-SCHEMA.md` — the full pack schema.
- `_template/` — scaffold to copy when authoring a new pack.
- `packs/<id>/` — global packs. The shipped starter is `hq-plain`.

Company packs live at `companies/<slug>/knowledge/brand-voice/packs/<id>/` with
`scope: company` and `company: <slug>`, registered in this same `registry.yaml`.
See `companies/_template/knowledge/brand-voice/README.md`.

## Authoring a pack

1. Copy `_template/` to `packs/<your-id>/` (or the company path above).
2. Fill in `pack.yaml`, `voice-guide.md`, and add real writing samples under
   `samples/`. Samples matter most — the pass calibrates against actual prose,
   not adjectives about prose.
3. Add a row to `registry.yaml`.
4. Point a channel at it: set `voice_pack: <your-id>` in a communication
   preferences file (personal or company).

## The starter

`hq-plain` is intentionally minimal and personalizable. Treat it as a starting
point: copy it, keep what fits your voice, and change the rest. It is the
default reference when no other pack is configured.
