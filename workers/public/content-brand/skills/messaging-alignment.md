# Skill: Messaging Alignment

Verify content aligns with approved brand messaging and key messages.

## Input

- Page content JSON
- Brand messaging guidelines
- Key message library

## Process

1. **Load key messages**
   - Core value proposition
   - Product positioning statements
   - Audience-specific messages
   - Proof points and stats

2. **Scan content for alignment**
   - Key message presence
   - Accurate representation
   - Consistent terminology
   - No conflicting claims

3. **Identify gaps**
   - Missing key messages
   - Diluted messaging
   - Off-brand statements

4. **Score alignment**
   - Message coverage
   - Accuracy
   - Consistency

## Key Message Categories

### Core Value Proposition
- What ExampleCo does
- Who it's for
- Why it matters
- How it's different

### Product Messaging
- Feature descriptions
- Benefit statements
- Use case framing
- Technical capabilities

### Audience-Specific
- Banking/Credit Union focus
- Healthcare positioning
- Enterprise requirements
- Security/Compliance emphasis

### Proof Points
- Customer metrics
- Industry recognition
- Security certifications
- Case study references

## Scoring Criteria

| Criterion | Weight | Description |
|-----------|--------|-------------|
| Coverage | 30% | Key messages present |
| Accuracy | 30% | Messages stated correctly |
| Consistency | 20% | Same terms throughout |
| Prominence | 20% | Messages visible, not buried |

## Output

```yaml
alignment_score: 85
key_messages:
  present:
    - "Enterprise AI platform"
    - "Banking-focused"
    - "SOC2 certified"
  missing:
    - "Implementation support"
  inaccurate:
    - message: "Industry leader"
      issue: "Claim not substantiated on page"
terminology:
  consistent:
    - "ExampleCo OS" (used 4x)
  inconsistent:
    - term: "AI assistant"
      variants: ["AI helper", "virtual assistant", "bot"]
      recommendation: "Standardize on 'AI assistant'"
```
