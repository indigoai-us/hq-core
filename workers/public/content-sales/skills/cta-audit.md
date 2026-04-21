# Skill: CTA Audit

Detailed analysis of call-to-action elements across page.

## Input

Page content JSON with extracted CTAs.

## Process

1. **Inventory all CTAs**
   - Buttons
   - Text links
   - Form submissions
   - Navigation prompts

2. **Classify each CTA**
   - Type (primary, secondary, tertiary)
   - Goal (demo, signup, learn more)
   - Commitment level (high, medium, low)

3. **Evaluate each CTA**
   - Copy effectiveness
   - Visual prominence
   - Placement strategy
   - Context appropriateness

4. **Assess overall strategy**
   - CTA density
   - Variety balance
   - Journey alignment
   - Conflict detection

## CTA Evaluation Criteria

### Copy Quality
- **Excellent**: Benefit-driven, specific outcome ("Start Saving 40% Today")
- **Good**: Action-oriented with context ("Get Your Free Demo")
- **Adequate**: Clear but generic ("Request Demo")
- **Poor**: Vague or passive ("Submit", "Click Here")

### Visual Prominence
- **Excellent**: High contrast, ample whitespace, prominent size
- **Good**: Noticeable, clear hierarchy
- **Adequate**: Visible but not prominent
- **Poor**: Hard to find, blends with content

### Placement
- **Excellent**: At decision points, after value established
- **Good**: Strategically placed, good density
- **Adequate**: Present but not optimal
- **Poor**: Misplaced, too early/late, wrong context

## CTA Best Practices

### Primary CTA
- One per viewport
- High contrast color
- Benefit-driven copy
- After value proposition

### Secondary CTA
- Lower commitment option
- Complement primary
- Text link or ghost button
- Different action/audience

### Micro-CTAs
- Content engagement
- Social sharing
- Navigation helpers
- Lead nurturing

## Output

```yaml
cta_audit:
  total_count: 6
  breakdown:
    primary: 2
    secondary: 3
    tertiary: 1
  inventory:
    - text: "Get a Demo"
      type: "primary"
      location: "hero"
      rating: "A"
      notes: "Well-placed, clear action"
    - text: "Learn More"
      type: "secondary"
      location: "features"
      rating: "C"
      notes: "Generic copy, could be more specific"
    - text: "Submit"
      type: "primary"
      location: "form"
      rating: "D"
      notes: "Generic, no benefit stated"
  issues:
    - "Two primary CTAs compete in hero section"
    - "Form CTA uses generic 'Submit' text"
    - "No CTA in pricing section"
  recommendations:
    - "Change 'Submit' to 'Start My Free Trial'"
    - "Add secondary CTA to pricing comparison"
    - "Consolidate hero CTAs to single primary"
```
