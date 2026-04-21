# Content Worker: Conversion Copy

Conversion optimization analysis worker for ExampleCo content.

## Purpose

Analyzes website content for conversion effectiveness, CTA quality, and value proposition clarity. Identifies opportunities to improve lead generation and user journey optimization.

## Skills

| Skill | Description |
|-------|-------------|
| conversion-analysis | Overall conversion optimization assessment |
| cta-audit | Evaluate CTA placement, copy, and effectiveness |
| value-prop-check | Assess value proposition clarity and impact |

## Knowledge Sources

- `companies/example-company/knowledge/verticals/` - Vertical-specific messaging
- `companies/example-company/knowledge/campaign-playbook.md` - Campaign strategy

## Scoring Categories

| Category | Weight | Description |
|----------|--------|-------------|
| CTA Effectiveness | 30% | Clear, compelling, well-placed CTAs |
| Value Proposition | 30% | Benefits clear and differentiated |
| Persuasion Elements | 20% | Social proof, trust signals |
| Conversion Path | 20% | Clear journey, low friction |

## Conversion Principles

1. **Clarity over Cleverness** - User should instantly understand offer
2. **Benefit-First CTAs** - State what user gets, not what they do
3. **Strategic Placement** - CTAs where intent is highest
4. **Reduce Friction** - Minimize steps to conversion
5. **Build Trust** - Social proof before asking for action

## Usage

```bash
# Run via HQ
/run content-sales --page homepage

# Or directly
cd workers/content-sales
npx ts-node src/analyze.ts --input content/homepage.json
```

## Output

Reports go to `workspace/reports/content/` with format:
- `{date}-content-sales-{page}.md`

## CTA Rating Scale

| Rating | Description |
|--------|-------------|
| A | Optimal - clear, compelling, well-placed |
| B | Good - minor improvements possible |
| C | Adequate - noticeable issues |
| D | Poor - significant problems |
| F | Failed - missing or ineffective |

## Integration

Part of the Content Team worker group. Works alongside:
- content-brand (voice consistency)
- content-product (accuracy verification)
- content-legal (compliance checking)
