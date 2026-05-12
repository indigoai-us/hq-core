# Skill: Compliance Scan

Scan content for regulated terms and potentially problematic language.

## Input

Page content JSON with all text elements.

## Process

1. **Tokenize content**
   - Extract all text
   - Identify terms and phrases
   - Note context/location

2. **Match against term lists**
   - High-risk terms
   - Medium-risk terms
   - Prohibited terms

3. **Evaluate context**
   - Is term used appropriately?
   - Is substantiation provided?
   - Is disclaimer present?

4. **Flag issues**
   - Severity level
   - Context
   - Required action

## Regulated Terms Database

### Security/Compliance Certifications
| Term | Risk Level | Requirement |
|------|------------|-------------|
| SOC 2 / SOC2 | High | Link to audit report or trust page |
| ISO 27001 | High | Link to certification |
| HIPAA | High | BAA availability, compliance details |
| PCI DSS | High | Certification level, date |
| GDPR | High | DPA availability, compliance scope |
| CCPA | High | Privacy policy link |
| FedRAMP | High | Authorization status |

### Financial Terms
| Term | Risk Level | Requirement |
|------|------------|-------------|
| FDIC | High | Only if actually FDIC insured |
| NCUA | High | Only if actually NCUA insured |
| Guaranteed | High | Conditions must be stated |
| Risk-free | Prohibited | Cannot use for financial products |
| Insured | High | Proof of insurance required |

### Performance Claims
| Term | Risk Level | Requirement |
|------|------------|-------------|
| Best / #1 | Medium | Third-party validation |
| Fastest | Medium | Benchmark data |
| Leading | Medium | Market data or remove |
| Proven | Medium | Proof required |
| Award-winning | Low | Award citation |

### Absolute Terms
| Term | Risk Level | Requirement |
|------|------------|-------------|
| Always | High | Rarely accurate, avoid |
| Never | High | Rarely accurate, avoid |
| 100% | High | Must be literally true |
| Guaranteed | High | Conditions required |
| Ensures | Medium | Context needed |

## Context Evaluation

### Acceptable Usage
- "SOC 2 Type II certified" + link to trust center
- "HIPAA-compliant" + BAA available statement
- "Up to 40% faster" + methodology note

### Unacceptable Usage
- "SOC 2 compliant" with no documentation link
- "HIPAA certified" (HIPAA has no certification)
- "Guaranteed results" with no conditions

## Output

```yaml
compliance_scan:
  total_terms_found: 15
  high_risk: 4
  medium_risk: 6
  low_risk: 5
  issues: 3
  findings:
    - term: "SOC 2 Type II"
      location: "Security section"
      risk: "high"
      status: "compliant"
      note: "Links to trust center"
    - term: "HIPAA certified"
      location: "Healthcare page hero"
      risk: "high"
      status: "non-compliant"
      issue: "HIPAA has no certification; misleading term"
      recommendation: "Change to 'HIPAA-compliant' and link to BAA"
    - term: "guaranteed"
      location: "Pricing section"
      risk: "high"
      status: "non-compliant"
      issue: "No conditions stated"
      recommendation: "Add 'subject to terms' or remove"
    - term: "fastest"
      location: "Features section"
      risk: "medium"
      status: "unsubstantiated"
      issue: "No benchmark provided"
      recommendation: "Add benchmark source or use 'faster'"
  required_actions:
    - severity: "high"
      item: "Fix 'HIPAA certified' language"
    - severity: "high"
      item: "Add conditions to guarantee"
    - severity: "medium"
      item: "Substantiate 'fastest' claim"
```
