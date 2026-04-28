---
id: hq-deploy-default-style-goclaw-admin
title: Default style for wrapped reports and deploy-scaffolded mini-apps is goclaw-admin
scope: global
trigger: when wrapping a raw report for deploy, when scaffolding a web repo via /plan or /newworker
enforcement: soft
public: true
version: 1
created: 2026-04-22
---

## Rule

When HQ wraps a raw `.html` / `.md` artifact for auto-deploy (deploy skill Step 2.5) or scaffolds a new repo with a web target via `/plan` or `/newworker`, the default style is **`goclaw-admin`** (`knowledge/public/design-styles/packs/goclaw-admin/`).

Override conditions (in precedence order):

1. Company brand pack explicitly `extends:` a different style in `knowledge/public/design-styles/registry.yaml` → use the company brand pack
2. `prd.json` `metadata.stylePack` declares a different pack → use the declared pack
3. Existing `design.md` at the repo root declares `style-pack: <other>` → do not overwrite
4. User states a different preference during `/plan` dialog → use the stated pack

Otherwise, write `style-pack: goclaw-admin` into the scaffolded `design.md`, and render wrapped reports with the goclaw-admin shell at `packs/goclaw-admin/templates/report-shell.html` + `design-tokens.css`.

Opt-out for a single report: YAML frontmatter `hq-wrap: false` (renderer exits with code 10; deploy skill falls through to shipping the raw file).

## Rationale

HQ's previous implicit default was a "blue theme" — saturated primary blues with Inter body and no unified display face — which leaked into every scaffolded dashboard and report. It doesn't match the rest of HQ's surface area (hq-console already runs on goclaw-admin) and makes reports feel disconnected from the operator console they originate from.

`goclaw-admin` is purpose-built for data-dense operator surfaces: zinc-950 base, Barlow Condensed uppercase display, IBM Plex Mono for identifiers, hairline `rgba(255,255,255,0.06)` rules, 240px fixed sidebar rail. It reads as "HQ output" at a glance, and the pack is already fully structured (tokens + templates + pack.yaml) — no migration cost to adopt it as the default.

Treating it as the default (not a forced mandate) preserves per-company brand overrides and explicit PRD declarations while flipping the implicit baseline from "blue theme" to "goclaw-admin" everywhere HQ generates a surface without being told what style to use.
