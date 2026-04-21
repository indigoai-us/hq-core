# Content Worker: Brand Voice

Brand voice analysis worker for ExampleCo content.

## Purpose

Analyzes website content for brand voice consistency, tone alignment, and messaging effectiveness. Ensures all content reflects ExampleCo's professional-yet-approachable brand identity.

## Skills

| Skill | Description |
|-------|-------------|
| voice-analysis | Evaluate overall brand voice consistency |
| tone-check | Check tone matches context (page type, audience) |
| messaging-alignment | Verify key messages are represented |

## Knowledge Sources

- `companies/example-company/knowledge/brand-guidelines.md` - Core brand voice guide
- `companies/example-company/knowledge/messaging/` - Messaging by audience/vertical

## Scoring Categories

| Category | Weight | Description |
|----------|--------|-------------|
| Tone Alignment | 30% | Matches professional-approachable balance |
| Messaging Consistency | 30% | Key messages present and accurate |
| Jargon Appropriateness | 20% | Technical language at right level |
| Trust Elements | 20% | Proof points, credentials, social proof |

## Brand Voice Characteristics

1. **Professional but Approachable** - Enterprise credibility without coldness
2. **Confident without Arrogance** - Authority without dismissiveness
3. **Technical with Clarity** - Accuracy without confusion
4. **Trust-Building** - Proof-driven claims, no hype

## Usage

```bash
# Run via HQ
/run content-brand --page homepage

# Or directly
cd workers/content-brand
npx ts-node src/analyze.ts --input content/homepage.json
```

## Output

Reports go to `workspace/reports/content/` with format:
- `{date}-content-brand-{page}.md`

## Integration

Part of the Content Team worker group. Works alongside:
- content-sales (conversion analysis)
- content-product (accuracy verification)
- content-legal (compliance checking)
