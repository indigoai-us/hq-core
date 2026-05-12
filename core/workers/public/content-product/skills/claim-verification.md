# Skill: Claim Verification

Verify product and business claims against authoritative sources.

## Input

- Page content JSON
- Product documentation
- Metrics database

## Process

1. **Extract all claims**
   - Product capabilities
   - Business outcomes
   - Comparative statements
   - Performance metrics

2. **Classify claims**
   - Feature claims
   - Performance claims
   - Business impact claims
   - Competitive claims

3. **Verify each claim**
   - Check product documentation
   - Cross-reference metrics
   - Validate with case studies
   - Flag unverifiable

4. **Rate verification status**
   - Verified: Source found, accurate
   - Partially verified: Source found, needs update
   - Unverified: No source found
   - Inaccurate: Contradicts source

## Claim Types and Sources

### Feature Claims
**Source:** Product documentation, release notes
**Example:** "Supports 50+ integrations"
**Verify:** Count actual integrations in docs

### Performance Claims
**Source:** Internal benchmarks, customer data
**Example:** "Processes 1M transactions/day"
**Verify:** Check metrics database, customer case studies

### Business Impact Claims
**Source:** Customer case studies, ROI analyses
**Example:** "Customers see 40% cost reduction"
**Verify:** Specific customer results, average across customers

### Competitive Claims
**Source:** Third-party analysis, feature comparison
**Example:** "Only platform with X feature"
**Verify:** Competitor research, market analysis

## Verification Standards

| Claim Type | Required Evidence |
|------------|-------------------|
| "Supports X" | Documentation listing |
| "X% improvement" | Customer data, case study |
| "Fastest/Best" | Third-party benchmark |
| "Only solution" | Competitive analysis |
| "X customers" | Current customer count |
| "Used by [Company]" | Customer permission |

## Output

```yaml
claim_verification:
  total_claims: 15
  verified: 10
  partially_verified: 3
  unverified: 2
  inaccurate: 0
  claims:
    - claim: "50+ enterprise integrations"
      status: "verified"
      source: "products/integrations.md"
      note: "Actually 54 integrations listed"
    - claim: "40% reduction in call volume"
      status: "partially_verified"
      source: "case-studies/acme-bank.md"
      note: "Specific to one customer, state as 'up to 40%'"
    - claim: "Industry-leading AI"
      status: "unverified"
      source: null
      note: "Subjective claim, recommend removing or substantiating"
  recommendations:
    - "Add 'up to' qualifier for percentage claims"
    - "Remove 'industry-leading' or cite ranking"
    - "Update integration count to current number"
```
