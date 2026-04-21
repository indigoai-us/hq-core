# Skill: Value Proposition Check

Assess value proposition clarity, differentiation, and impact.

## Input

- Page content JSON
- Brand messaging guidelines
- Competitor positioning (if available)

## Process

1. **Identify value proposition elements**
   - Headline/tagline
   - Subheadline
   - Supporting points
   - Proof elements

2. **Evaluate core components**
   - What: Product/service clarity
   - Who: Target audience specificity
   - Why: Benefit articulation
   - How: Differentiation

3. **Assess communication**
   - Clarity (instantly understood?)
   - Specificity (concrete vs vague?)
   - Credibility (provable?)
   - Memorability (sticky?)

4. **Score effectiveness**
   - Component presence
   - Communication quality
   - Strategic alignment

## Value Proposition Framework

### Essential Components

| Component | Question | Good Example | Bad Example |
|-----------|----------|--------------|-------------|
| What | What do you offer? | "AI-powered banking assistant" | "Next-gen solution" |
| Who | Who is it for? | "Community banks and credit unions" | "Businesses everywhere" |
| Why | Why does it matter? | "Reduce call center volume 40%" | "Transform your operations" |
| How | How is it different? | "Only AI trained on banking regulations" | "Industry-leading technology" |

### Quality Indicators

**Clarity**
- Understood in <5 seconds
- No jargon required
- Specific, not abstract

**Specificity**
- Numbers over adjectives
- Outcomes over features
- Examples over generalizations

**Credibility**
- Backed by proof
- Realistic claims
- Third-party validation

**Differentiation**
- Unique vs competitors
- Ownable position
- Clear alternative

## Scoring Rubric

| Score | Description |
|-------|-------------|
| 90-100 | Exceptional - all components strong, differentiated |
| 70-89 | Good - most components present, some gaps |
| 50-69 | Adequate - basic value prop, weak differentiation |
| 30-49 | Poor - unclear or missing key components |
| 0-29 | Failed - no clear value proposition |

## Output

```yaml
value_prop_score: 78
headline_analysis:
  text: "AI That Understands Banking"
  clarity: 85
  specificity: 70
  differentiation: 80
  issues:
    - "Could be more specific about outcomes"
components:
  what:
    present: true
    score: 80
    evidence: "AI-powered platform"
  who:
    present: true
    score: 85
    evidence: "Banks and credit unions"
  why:
    present: true
    score: 70
    evidence: "Benefits mentioned but not quantified"
  how:
    present: false
    score: 40
    evidence: "Differentiation unclear"
recommendations:
  - priority: "high"
    issue: "Missing differentiation"
    suggestion: "Add 'Only AI trained on 10,000+ banking regulations'"
  - priority: "medium"
    issue: "Vague benefits"
    suggestion: "Quantify outcomes: 'Reduce call volume 40%'"
```
