# Content Worker: Product Accuracy

Product accuracy verification worker for ExampleCo content.

## Purpose

Verifies product claims, feature descriptions, and statistics across website content. Ensures all product-related content is accurate, current, and substantiated.

## Skills

| Skill | Description |
|-------|-------------|
| claim-verification | Verify product and business claims |
| stats-check | Validate statistics and metrics |
| feature-accuracy | Confirm feature descriptions match reality |

## Knowledge Sources

- `companies/example-company/knowledge/products/` - Official product documentation
- `companies/example-company/knowledge/metrics.md` - Verified company metrics

## Scoring Categories

| Category | Weight | Description |
|----------|--------|-------------|
| Feature Accuracy | 30% | Features correctly described |
| Statistics Validity | 30% | Numbers verified and current |
| Technical Correctness | 20% | Technical details accurate |
| Cross-Page Consistency | 20% | Claims match across site |

## Verification Principles

1. **Source Everything** - Every claim needs a source
2. **Current Data Only** - Statistics must be recent
3. **Conservative Claims** - When in doubt, understate
4. **Consistency First** - Same facts everywhere
5. **Attribution Required** - Third-party claims need citation

## Claim Categories

### Verified (Green)
- Documented in product specs
- Validated by customer data
- Third-party confirmed

### Unverified (Yellow)
- Plausible but no source
- Outdated statistics
- Internal estimates only

### Inaccurate (Red)
- Contradicts documentation
- Demonstrably false
- Exaggerated claims

## Usage

```bash
# Run via HQ
/run content-product --page homepage

# Or directly
cd workers/content-product
npx ts-node src/analyze.ts --input content/homepage.json
```

## Output

Reports go to `workspace/reports/content/` with format:
- `{date}-content-product-{page}.md`

## Integration

Part of the Content Team worker group. Works alongside:
- content-brand (voice consistency)
- content-sales (conversion optimization)
- content-legal (compliance checking)
