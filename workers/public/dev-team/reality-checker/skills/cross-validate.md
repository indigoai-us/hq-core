# Cross-Validate

Verify another agent's QA findings without trusting their conclusions.

## Trigger

Called when you need to independently verify a QA report — especially useful when
qa-tester reports zero issues (red flag) or perfect scores.

## Inputs

- `qa_report`: Path to the QA report to cross-validate
- `url`: Live URL to test against
- `viewports`: Viewports to check (default: 375px, 768px, 1440px)

## Process

1. Parse prior QA report into claim list
2. For each claim, run independent verification:
   - Take own screenshot at same viewport
   - Run own console check
   - Run own axe scan if a11y claim
3. Classify each claim: CONFIRMED / FALSE POSITIVE / INCOMPLETE
4. Report accuracy rate of prior QA

## Output

- Cross-validation report with per-claim verification
- Prior QA accuracy percentage
- List of false positives caught
- List of issues missed by prior QA
