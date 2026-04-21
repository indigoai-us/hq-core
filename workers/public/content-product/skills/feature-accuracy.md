# Skill: Feature Accuracy

Confirm feature descriptions match actual product capabilities.

## Input

- Page content JSON
- Product documentation
- Release notes

## Process

1. **Extract feature mentions**
   - Explicit feature names
   - Capability descriptions
   - Integration claims
   - Platform support

2. **Map to documentation**
   - Find matching feature
   - Compare description
   - Check availability
   - Verify limitations

3. **Identify discrepancies**
   - Missing features
   - Overstated capabilities
   - Outdated descriptions
   - Missing caveats

4. **Score accuracy**
   - Correct descriptions
   - Minor variations
   - Significant errors
   - Missing information

## Feature Verification Matrix

| Content Element | Documentation Check |
|-----------------|---------------------|
| Feature name | Official naming |
| Description | Capability match |
| Availability | Current release |
| Pricing tier | Feature matrix |
| Limitations | Documented caveats |
| Integrations | Integration list |

## Common Discrepancies

### Naming Issues
- Using internal names publicly
- Inconsistent product naming
- Deprecated feature names
- Unofficial abbreviations

### Capability Overstatements
- "Fully automated" (has manual steps)
- "Unlimited" (has soft limits)
- "All platforms" (specific support)
- "Real-time" (near real-time)

### Missing Context
- Enterprise-only features
- Add-on pricing
- Beta/preview status
- Regional availability

### Outdated Information
- Sunset features still listed
- Old screenshots
- Previous pricing
- Legacy integrations

## Accuracy Levels

| Level | Description | Score Impact |
|-------|-------------|--------------|
| Exact | Perfect match to docs | +10 |
| Equivalent | Same meaning, different words | +8 |
| Simplified | Accurate but less detail | +5 |
| Overstated | Exceeds actual capability | -15 |
| Outdated | No longer accurate | -10 |
| Wrong | Incorrect information | -25 |

## Output

```yaml
feature_accuracy:
  total_features: 20
  exact: 12
  equivalent: 5
  simplified: 2
  overstated: 1
  outdated: 0
  wrong: 0
  accuracy_score: 88
  inventory:
    - feature: "AI-powered document analysis"
      content_description: "Automatically analyzes and extracts data from any document"
      docs_description: "Analyzes structured documents (PDFs, forms) with 95% accuracy"
      status: "overstated"
      issue: "'Any document' overstates; structured docs only"
      recommendation: "Change to 'structured documents like PDFs and forms'"
    - feature: "Slack integration"
      content_description: "Connect with Slack"
      docs_description: "Full Slack integration with notifications, commands, and workflows"
      status: "simplified"
      issue: "Could highlight more capabilities"
      recommendation: "Add specific Slack capabilities"
  missing_from_content:
    - feature: "Microsoft Teams integration"
      note: "Recently launched, not yet on website"
  missing_from_docs:
    - feature: "Custom AI training"
      note: "Mentioned on website but not in product docs"
      action: "Verify if feature exists, update docs or remove from site"
```
