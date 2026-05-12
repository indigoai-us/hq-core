# Skill: Voice Analysis

Evaluate overall brand voice consistency across page content.

## Input

Page content JSON with extracted text sections.

## Process

1. **Extract all text elements**
   - Headings (H1-H6)
   - Paragraphs
   - CTAs and buttons
   - List items

2. **Analyze voice characteristics**
   - Professional tone markers
   - Approachability indicators
   - Confidence level (without arrogance)
   - Technical clarity

3. **Score each characteristic**
   - 0-25: Poor alignment
   - 26-50: Needs improvement
   - 51-75: Acceptable
   - 76-100: Strong alignment

4. **Identify deviations**
   - Flag overly casual language
   - Flag aggressive sales language
   - Flag inconsistent tone shifts

## Scoring Rubric

### Professional Markers (positive)
- Industry-appropriate terminology
- Clear, direct statements
- Data-backed claims
- Formal structure

### Approachability Markers (positive)
- Second person ("you", "your")
- Benefit-focused language
- Conversational clarity
- Empathetic acknowledgment

### Red Flags (negative)
- Hyperbole ("revolutionary", "game-changing")
- Urgency pressure ("act now", "don't miss")
- Unexplained acronyms
- Jargon overload

## Output

```yaml
voice_score: 82
characteristics:
  professional: 85
  approachable: 78
  confident: 80
  clear: 84
deviations:
  - location: "Hero section"
    issue: "Overly promotional language"
    evidence: "Revolutionary AI that transforms everything"
    suggestion: "Focus on specific, provable benefits"
```
