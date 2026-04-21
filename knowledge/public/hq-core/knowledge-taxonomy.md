---
type: reference
domain: [operations, engineering]
status: canonical
tags: [knowledge-taxonomy, directory-structure, organization, standard, ontology]
relates_to:
  - knowledge-ontology.yaml
  - index-md-spec.md
---

# Knowledge Taxonomy Specification

Standard directory structure for all company knowledge repositories in HQ. Defines 8 canonical subdirectories aligned to `knowledge-ontology.yaml` domains.

---

## Standard Taxonomy Tree

```
companies/{co}/knowledge/
├── brand/          # Voice, visual identity, messaging, guidelines
├── product/        # Features, capabilities, pricing, roadmap docs
├── engineering/    # Architecture, APIs, databases, infra, schemas
├── growth/         # Channels, campaigns, acquisition, partnerships
├── market/         # Competitive, segments, verticals, ICP, positioning
├── operations/     # Workflows, runbooks, team processes, compliance
├── data/           # Metrics, analytics, reporting, tracking
├── assets/         # Logos, images, design files, static resources
├── INDEX.md        # Auto-generated directory map (see index-md-spec.md)
└── README.md       # Knowledge repo overview (human-maintained)
```

Root files that always stay at root:
```
├── company-info.md       # Corporate details, address, legal (agent context)
├── competitive-landscape.md  # Market position, competitors (cross-domain)
├── AGENT-GUIDE.md        # How AI agents should navigate ({company} only)
├── profile.md            # Personal profile (personal company only)
```

---

## Domain → Subdir Mapping

| Ontology Domain | Canonical Subdir | Contents |
|-----------------|-----------------|----------|
| `brand`         | `brand/`        | Voice guides, visual identity, brand guidelines, messaging frameworks, archetype docs |
| `product`       | `product/`      | Product specs, feature docs, pricing, overviews, roadmaps, changelogs |
| `engineering`   | `engineering/`  | Architecture, database schemas, API references, infrastructure, queries, integrations, setup guides |
| `growth`        | `growth/`       | Campaign docs, channel strategy, analytics setup, acquisition playbooks, social ops |
| `market`        | `market/`       | Competitive analysis, target segments, positioning, ICP, market analysis, revenue models |
| `operations`    | `operations/`   | Team workflows, runbooks, onboarding, deployment guides, contributing guides, admin docs |
| `data`          | `data/`         | Metrics dashboards, funnel analyses, A/B test logs, interview insights, tracking docs |
| _(visual assets)_ | `assets/`    | Logos, images, design tokens, SVGs, brand asset exports |

---

## Rules

### Subdir Threshold
A subdir is created when **2+ docs** belong to the same domain. Single documents may stay at root until a second related doc is added.

### Lean Company Rule
Small companies (≤5 docs total) may omit most subdirs and organize minimally. Only create the subdirs that have content. Example: `dominion` has only `engineering/` and `product/` because it has 3 docs total.

### Escape Hatch
Domain-specific content that doesn't fit the 8-subdir model may use a named subdir as an "escape hatch":
- `wildcat/` in keptwork — client deliverable archive, specific to the Wildcat brand engagement

Escape hatch subdirs must be documented in the company's README.md.

### Canonical File Names
When moving files, use these canonical names regardless of original filename:

| Canonical Name | Use Case |
|---------------|----------|
| `brand/voice-guide.md` | Brand voice, tone, writing style |
| `brand/brand-guidelines.md` | Visual identity, logo usage, color palette |
| `product/overview.md` | Product overview / summary |
| `engineering/architecture.md` | System or platform architecture |
| `engineering/database-schema.md` | DB schemas and data models |

### Root vs Subdir Rules
Files that **always stay at root**:
1. `company-info.md` — High-traffic agent context file (analogous to `agents-companies.md`)
2. `competitive-landscape.md` — Cross-domain strategic reference, spans multiple subdir categories
3. `AGENT-GUIDE.md` — Navigation meta-doc for AI agents
4. `profile.md` — Personal identity file (personal company only)
5. `README.md` — Human-maintained repo overview

Files that **move to subdirs**:
- Any technical doc (architecture, schema, queries) → `engineering/`
- Any brand/voice/messaging doc → `brand/`
- Any product spec/feature doc → `product/`
- Any campaign/channel/social doc → `growth/`
- Any market positioning/segment doc → `market/`
- Any workflow/runbook/onboarding doc → `operations/`
- Any metrics/analytics/tracking doc → `data/`
- Any logo/image/design asset → `assets/`

---

## Per-Company Structure (Post-Migration)

| Company | Subdirs Used |
|---------|-------------|
| {company} | `engineering/`, `product/`, `data/` |
| {company} | `brand/`, `engineering/`, `product/`, `growth/`, `market/`, `operations/`, `assets/` |
| brandstage | `engineering/`, `product/`, `growth/`, `market/`, `operations/`, `data/` |
| keptwork | `engineering/`, `operations/`, `wildcat/` (escape hatch) |
| moonflow | `brand/`, `product/`, `growth/`, `operations/`, `assets/` |
| holler-mgmt | `brand/`, `engineering/`, `market/`, `operations/` |
| hpo | `brand/`, `product/`, `growth/` |
| personal | `brand/`, `growth/`, `operations/`, `data/` |
| golden-thread | `brand/`, `growth/`, `operations/` |
| dominion | `engineering/`, `product/` |

---

## Application

**For new knowledge docs:** Determine the primary domain, place in the corresponding subdir. Use canonical filename if applicable.

**For new companies:** Run `/garden` or `/cleanup --reindex` after initial knowledge population to apply taxonomy and rebuild INDEX.md.

**For agents reading knowledge:** Load `INDEX.md` for directory map. Load subdir by domain when topic is known (e.g., load `engineering/` when debugging a technical issue).

**Spec version:** 1.0 — established 2026-03-09 post-taxonomy migration.
