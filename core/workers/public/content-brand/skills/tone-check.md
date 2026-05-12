# Skill: Tone Check

Verify tone matches page context and target audience.

## Input

- Page content JSON
- Page type (homepage, product, solutions, etc.)
- Target audience (if specified)

## Process

1. **Identify page context**
   - Page type from URL/metadata
   - Target audience from content signals
   - Conversion goal

2. **Define expected tone**
   - Homepage: Confident, welcoming, high-level
   - Product pages: Detailed, technical, benefit-focused
   - Solutions pages: Empathetic, problem-aware, specific
   - About pages: Authentic, credible, human

3. **Analyze actual tone**
   - Sentence structure (formal vs casual)
   - Word choice complexity
   - Emotional register
   - Call-to-action intensity

4. **Compare and score**
   - Match percentage
   - Deviation severity
   - Context appropriateness

## Tone Expectations by Page Type

### Homepage
- Confident but not boastful
- Welcoming, inclusive
- Clear value proposition
- Light on details, heavy on benefits

### Product Pages
- Technical accuracy
- Feature-benefit connections
- Use case clarity
- Appropriate depth

### Solutions Pages
- Problem acknowledgment
- Empathy for pain points
- Specific to vertical/audience
- Proof points relevant to context

### Legal/Compliance Pages
- Formal, precise
- No marketing language
- Clear and unambiguous
- Properly structured

## Output

```yaml
tone_score: 76
page_type: "product"
expected_tone: "technical, benefit-focused"
actual_tone: "promotional, feature-heavy"
mismatches:
  - element: "Product description"
    expected: "Specific technical capabilities"
    actual: "Generic marketing language"
    impact: "medium"
recommendations:
  - "Add specific metrics and use cases"
  - "Reduce promotional adjectives"
```
