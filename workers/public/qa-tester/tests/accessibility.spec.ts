/**
 * Accessibility Tests
 * Uses axe-core to check WCAG 2.1 AA compliance
 */
import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

const pages: string[] = JSON.parse(process.env.TEST_PAGES || '[]');

for (const pagePath of pages) {
  test(`Accessibility: ${pagePath}`, async ({ page }) => {
    await page.goto(pagePath, { waitUntil: 'domcontentloaded' });

    // Run axe-core accessibility scan
    const accessibilityScanResults = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
      .analyze();

    // Filter to serious and critical violations only
    const seriousViolations = accessibilityScanResults.violations.filter(
      (v) => v.impact === 'serious' || v.impact === 'critical'
    );

    // Build readable error message
    const violationSummary = seriousViolations.map((v) => {
      const nodes = v.nodes.slice(0, 3).map((n) => n.html).join('\n  ');
      return `- ${v.id} (${v.impact}): ${v.help}\n  ${nodes}`;
    });

    expect(
      seriousViolations,
      `${pagePath} has accessibility violations:\n${violationSummary.join('\n')}`
    ).toHaveLength(0);
  });
}
