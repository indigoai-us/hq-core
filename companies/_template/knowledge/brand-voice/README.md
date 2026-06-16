# Company brand-voice packs

Company-scoped voice packs (`type: voice`, `scope: company`) live under
`packs/{pack-id}/`. They define how this company's outbound prose should sound,
and they feed the humanize-before-send pass when a channel sets `voice_pack` in
`companies/{co}/settings/communication/preferences.yaml`.

Each pack is a self-contained directory with at minimum:

- `pack.yaml` — manifest declaring `id`, `version`, `type: voice`,
  `scope: company`, `company: {slug}`, and optional `extends: {parent-pack-id}`.
- `voice-guide.md` — tone, diction, rhythm, do / don't, before / after.
- `samples/` — real writing in the company voice for calibration.

Register packs in the global `core/knowledge/public/brand-voice/registry.yaml`
with `scope: company` and `company: {your-slug}`.

A company voice usually starts from the shipped `hq-plain` pack and diverges in a
few places. Set `extends: hq-plain` and document only the deltas.

See `core/knowledge/public/brand-voice/PACK-SCHEMA.md` for the full schema and
`core/knowledge/public/brand-voice/_template/` for a scaffold to copy.
