# Skill: Disclaimer Check

Verify required disclaimers are present and properly formatted.

## Input

- Page content JSON
- Claim types found on page
- Page type/context

## Process

1. **Identify required disclaimers**
   - Based on claims made
   - Based on page type
   - Based on industry

2. **Search for disclaimers**
   - Footer content
   - Inline disclaimers
   - Linked pages

3. **Evaluate completeness**
   - All required present?
   - Properly formatted?
   - Appropriately placed?

4. **Flag missing/incomplete**
   - Missing disclaimers
   - Incomplete disclaimers
   - Poorly placed disclaimers

## Required Disclaimers by Claim Type

### Security/Compliance Claims
| Claim | Required Disclaimer |
|-------|---------------------|
| SOC 2 | Link to trust/security page |
| HIPAA | BAA availability statement |
| Encryption | Technical details or link |
| "Secure" | Security measures link |

### Performance Claims
| Claim | Required Disclaimer |
|-------|---------------------|
| % improvement | "Results may vary" + methodology |
| Speed claims | Benchmark conditions |
| ROI claims | Sample size, time period |
| Customer results | "Individual results may vary" |

### Financial Content
| Context | Required Disclaimer |
|---------|---------------------|
| Pricing page | Terms and conditions link |
| ROI calculator | "Estimates only" |
| Cost comparison | Assumptions stated |
| Free trial | What happens after trial |

### Testimonials
| Type | Required Disclaimer |
|------|---------------------|
| Customer quote | Attribution |
| Case study | Customer permission |
| Results cited | Verification available |
| Video testimonial | Disclosure if compensated |

### General Website
| Page Type | Required Elements |
|-----------|-------------------|
| All pages | Privacy policy link |
| All pages | Terms of service link |
| Cookie use | Cookie consent/policy |
| Forms | Data use statement |

## Disclaimer Placement Guidelines

### Acceptable Placement
- Adjacent to claim
- Footer with clear link
- Dedicated disclosure page (linked)
- Tooltip/hover text

### Unacceptable Placement
- Buried in unrelated content
- Tiny/illegible text
- Multiple clicks away
- No placement at all

## Disclaimer Format Requirements

### Must Include
- Clear language
- Reasonable font size
- Visible contrast
- Accessible location

### Should Avoid
- Legalese
- Excessive length
- Hidden visibility
- Misdirection

## Output

```yaml
disclaimer_check:
  required: 8
  present: 5
  missing: 3
  incomplete: 1
  score: 62
  inventory:
    - disclaimer: "Privacy policy link"
      required: true
      present: true
      location: "Footer"
      status: "compliant"
    - disclaimer: "Results may vary"
      required: true
      present: false
      trigger: "40% efficiency improvement claim"
      location: null
      status: "missing"
      recommendation: "Add disclaimer near performance claim"
    - disclaimer: "Security documentation link"
      required: true
      present: true
      location: "Footer"
      status: "incomplete"
      issue: "Links to generic page, not specific security docs"
      recommendation: "Link directly to trust center"
    - disclaimer: "Cookie consent"
      required: true
      present: false
      trigger: "Website uses cookies"
      location: null
      status: "missing"
      recommendation: "Add cookie consent banner"
  required_actions:
    - priority: "high"
      action: "Add 'results may vary' to performance claims"
    - priority: "high"
      action: "Implement cookie consent"
    - priority: "medium"
      action: "Update security link to trust center"
```
