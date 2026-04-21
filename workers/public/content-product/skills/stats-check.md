# Skill: Stats Check

Validate statistics and metrics for accuracy and currency.

## Input

- Page content JSON
- Metrics database
- Publication dates

## Process

1. **Extract all statistics**
   - Percentages
   - Counts
   - Financial figures
   - Time-based metrics

2. **Identify source**
   - Internal data
   - Customer data
   - Third-party research
   - Unknown/unattributed

3. **Verify accuracy**
   - Match to source
   - Check calculation
   - Validate methodology

4. **Check currency**
   - Data collection date
   - Update frequency
   - Staleness threshold

## Statistics Categories

### Company Metrics
- Customer count
- Revenue figures
- Growth rates
- Team size

### Product Metrics
- Feature counts
- Performance benchmarks
- Uptime statistics
- Usage volumes

### Customer Outcomes
- ROI figures
- Efficiency gains
- Cost savings
- Time reductions

### Market Data
- Market size
- Industry growth
- Competitive position
- Analyst ratings

## Verification Checklist

### Accuracy Checks
- [ ] Number matches source exactly
- [ ] Calculation methodology correct
- [ ] Sample size appropriate
- [ ] Context preserved

### Currency Checks
- [ ] Data collected within 12 months
- [ ] Reflects current product state
- [ ] Market data still relevant
- [ ] Customer still active

### Attribution Checks
- [ ] Source clearly stated
- [ ] Link to full study (if third-party)
- [ ] Customer permission (if named)
- [ ] Methodology available

## Red Flags

| Issue | Example | Action |
|-------|---------|--------|
| Round numbers | "Exactly 50% improvement" | Verify exact figure |
| Extreme claims | "99.999% uptime" | Verify SLA |
| Old data | "2022 study shows..." | Update or remove |
| Unattributed | "Studies show..." | Find source or remove |
| Aggregated | "Customers report..." | Get specific examples |

## Output

```yaml
stats_check:
  total_stats: 12
  verified: 8
  outdated: 2
  unverified: 1
  inaccurate: 1
  inventory:
    - stat: "500+ customers"
      value: 500
      actual: 523
      status: "verified"
      source: "CRM as of 2026-01"
      recommendation: "Update to current count"
    - stat: "99.9% uptime"
      value: 99.9
      actual: 99.95
      status: "verified"
      source: "Status page, 12-month average"
    - stat: "40% faster than alternatives"
      value: 40
      actual: null
      status: "unverified"
      source: null
      recommendation: "Remove or provide benchmark source"
    - stat: "Used by 3 of top 5 banks"
      value: 3
      actual: 2
      status: "inaccurate"
      source: "Customer list"
      recommendation: "Correct to '2 of top 5' or verify"
  currency_issues:
    - stat: "Industry grew 25% in 2024"
      issue: "Outdated market data"
      recommendation: "Update with 2025 figures"
```
