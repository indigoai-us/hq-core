# Content Worker: Regulatory Compliance

Regulatory compliance analysis worker for content review.

## Purpose

Scans website content for regulated terms, verifies claim substantiation, and identifies missing disclaimers. Helps ensure content meets regulatory requirements for financial services and enterprise software marketing.

## Skills

| Skill | Description |
|-------|-------------|
| compliance-scan | Scan for regulated terms and language |
| disclaimer-check | Verify required disclaimers are present |
| claim-substantiation | Check claims have proper support |

## Knowledge Sources

Compliance terms and requirements are defined inline in worker.yaml to ensure they're always available and version-controlled with the worker.

## Scoring Categories

| Category | Weight | Description |
|----------|--------|-------------|
| Regulated Terms | 30% | Proper use of regulated language |
| Disclaimers | 30% | Required disclaimers present |
| Substantiation | 25% | Claims properly supported |
| Risk Language | 15% | Appropriate risk disclosure |

## Compliance Principles

1. **Substantiate Everything** - Every claim needs backup
2. **Disclose Appropriately** - Required disclaimers present
3. **Avoid Absolutes** - No unqualified guarantees
4. **Link to Proof** - Security/compliance claims need documentation
5. **When in Doubt, Flag** - Better to over-flag for legal review

## Regulated Term Categories

### High-Risk (Require Documentation)
- Security certifications (SOC 2, ISO 27001)
- Compliance claims (HIPAA, PCI DSS, GDPR)
- Financial guarantees

### Medium-Risk (Need Context)
- Performance claims
- Comparative statements
- Award references

### Low-Risk (Monitor)
- General superlatives
- Customer testimonials
- Feature claims

## Usage

```bash
# Run via HQ
/run content-legal --page homepage

# Or directly
cd workers/content-legal
npx ts-node src/analyze.ts --input content/homepage.json
```

## Output

Reports go to `workspace/reports/content/` with format:
- `{date}-content-legal-{page}.md`

## Disclaimer

This worker provides content guidance only, not legal advice. All flagged items should be reviewed by qualified legal counsel before making decisions.

## Integration

Part of the Content Team worker group. Works alongside:
- content-brand (voice consistency)
- content-sales (conversion optimization)
- content-product (accuracy verification)
