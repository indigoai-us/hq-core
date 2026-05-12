# Skill: Claim Substantiation

Verify that marketing claims have proper substantiation.

## Input

- Page content JSON
- Available proof sources
- Claim type classification

## Process

1. **Extract all claims**
   - Performance claims
   - Comparative claims
   - Superlative claims
   - Quantitative claims

2. **Classify substantiation requirement**
   - Must have proof
   - Should have proof
   - Nice to have proof

3. **Search for substantiation**
   - On-page evidence
   - Linked documentation
   - Referenced sources

4. **Evaluate quality**
   - Source credibility
   - Data currency
   - Methodology clarity

## Substantiation Requirements by Claim Type

### Must Substantiate (Legal Risk)

| Claim Type | Required Proof |
|------------|----------------|
| "SOC 2 certified" | Audit report or trust page |
| "X% improvement" | Customer data, methodology |
| "#1 in category" | Third-party ranking |
| "Award-winning" | Award citation, date |
| Security claims | Certification documentation |
| Regulatory compliance | Compliance documentation |

### Should Substantiate (Credibility Risk)

| Claim Type | Recommended Proof |
|------------|-------------------|
| "Leading platform" | Market share, analyst quote |
| "Trusted by X" | Customer permission, logos |
| "Faster than Y" | Benchmark comparison |
| "Proven results" | Case studies, testimonials |
| "Enterprise-grade" | Feature comparison |

### Nice to Substantiate (Best Practice)

| Claim Type | Optional Proof |
|------------|----------------|
| "Easy to use" | User testimonials |
| "Powerful" | Feature demonstration |
| "Modern" | Screenshots, demos |
| "Innovative" | Feature descriptions |

## Substantiation Quality Levels

### Strong Substantiation
- Third-party validation
- Published research
- Audited data
- Named customer reference

### Adequate Substantiation
- Internal data with methodology
- Multiple customer examples
- Industry benchmarks
- Time-bound claims

### Weak Substantiation
- Anecdotal evidence
- Undated claims
- Single example
- Self-reported data

### No Substantiation
- No supporting evidence
- Claim stands alone
- Source not provided
- Evidence not accessible

## Red Flags

| Issue | Example | Action |
|-------|---------|--------|
| Unqualified superlative | "Best AI platform" | Add qualifier or proof |
| Vague percentage | "Significant improvement" | Quantify or remove |
| Implied comparison | "Better results" | State comparison clearly |
| Outdated proof | "2020 study shows..." | Update or remove |
| Inaccessible source | "Research proves..." | Provide link |

## Output

```yaml
claim_substantiation:
  total_claims: 12
  fully_substantiated: 7
  partially_substantiated: 3
  unsubstantiated: 2
  score: 75
  claims:
    - claim: "SOC 2 Type II certified"
      type: "security"
      requirement: "must"
      substantiation: "strong"
      evidence: "Link to trust center with audit details"
      status: "compliant"
    - claim: "40% reduction in call volume"
      type: "performance"
      requirement: "must"
      substantiation: "adequate"
      evidence: "Case study link"
      status: "needs_improvement"
      issue: "Claim is absolute but based on single customer"
      recommendation: "Change to 'up to 40%' or add more examples"
    - claim: "Industry-leading AI"
      type: "superlative"
      requirement: "should"
      substantiation: "none"
      evidence: null
      status: "non-compliant"
      recommendation: "Remove claim or add analyst quote/ranking"
    - claim: "Trusted by 500+ organizations"
      type: "quantitative"
      requirement: "must"
      substantiation: "partial"
      evidence: "Logo section shows ~20 logos"
      status: "needs_improvement"
      recommendation: "Ensure count is accurate and current"
  required_actions:
    - priority: "high"
      claim: "Industry-leading AI"
      action: "Substantiate or remove"
    - priority: "medium"
      claim: "40% reduction"
      action: "Add qualifier 'up to'"
    - priority: "low"
      claim: "500+ organizations"
      action: "Verify current count"
```
