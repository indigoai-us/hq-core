# Skill: Conversion Analysis

Comprehensive conversion optimization assessment for page content.

## Input

- Page content JSON
- Page type and conversion goal

## Process

1. **Identify page conversion goal**
   - Primary action (demo, signup, download)
   - Secondary actions
   - Micro-conversions

2. **Audit conversion elements**
   - CTA presence and quality
   - Value proposition visibility
   - Trust signals
   - Friction points

3. **Analyze user journey**
   - Entry point clarity
   - Information hierarchy
   - Decision support
   - Exit paths

4. **Score conversion readiness**
   - Element presence
   - Element quality
   - Strategic placement
   - Overall optimization

## Conversion Element Checklist

### Above the Fold
- [ ] Clear headline with value prop
- [ ] Primary CTA visible
- [ ] Supporting visual
- [ ] Trust indicator

### Body Content
- [ ] Benefits clearly stated
- [ ] Features connected to outcomes
- [ ] Social proof present
- [ ] Objection handling

### Conversion Points
- [ ] Multiple CTA placements
- [ ] Varied CTA types (primary/secondary)
- [ ] Low-commitment options
- [ ] Clear next steps

## Scoring Matrix

| Element | Weight | Criteria |
|---------|--------|----------|
| Hero Section | 25% | Value prop, CTA, clarity |
| Social Proof | 20% | Testimonials, logos, stats |
| Benefit Clarity | 20% | Outcomes, not features |
| CTA Strategy | 20% | Placement, copy, variety |
| Trust Elements | 15% | Security, guarantees, authority |

## Output

```yaml
conversion_score: 72
page_type: "product"
primary_goal: "Demo request"
elements:
  hero:
    score: 80
    has_value_prop: true
    has_cta: true
    clarity: "good"
  social_proof:
    score: 60
    testimonials: 0
    logos: 5
    stats: 2
  ctas:
    count: 4
    primary: 2
    secondary: 2
    effectiveness: 75
friction_points:
  - "No testimonials on product page"
  - "Form requires too many fields"
  - "Secondary CTA competes with primary"
recommendations:
  - priority: "high"
    action: "Add customer testimonial to hero"
  - priority: "medium"
    action: "Reduce form fields to 3"
```
