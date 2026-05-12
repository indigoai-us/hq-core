# Company Design Styles

Company-scoped brand packs (`type: brand`, `scope: company`) live under `packs/{pack-id}/`.

Each pack is a self-contained directory with at minimum:

- `pack.yaml` — manifest declaring `id`, `version`, `extends: {style-pack-id}`, `scope: company`, `company: {slug}`
- `style-guide.md` — voice, palette, typography, layout principles
- `design-tokens.css` and/or `design-tokens.json` — DTCG tokens
- `design-template.md` — drop-in template for repos that adopt this pack
- `swipes/` — reference imagery

Packs are registered in the global `core/knowledge/public/design-styles/registry.yaml` with `scope: company` and `company: {your-slug}`. Workers (e.g. `frontend-designer`) auto-load this directory via their `dynamic` context when a target company is bound.

See `core/knowledge/public/design-styles/PACK-SCHEMA.md` for the full pack schema, and `core/knowledge/public/design-styles/_template/` for a scaffold.
