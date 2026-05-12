/**
 * Console Errors Tests
 * Checks for JavaScript errors in browser console
 */
import { test, expect } from '@playwright/test';

const pages: string[] = JSON.parse(process.env.TEST_PAGES || '[]');

for (const pagePath of pages) {
  test(`No console errors: ${pagePath}`, async ({ page }) => {
    const consoleErrors: string[] = [];

    page.on('console', (msg) => {
      if (msg.type() === 'error') {
        // Ignore some common non-critical errors
        const text = msg.text();
        if (
          !text.includes('favicon') &&
          !text.includes('Failed to load resource: net::ERR_FAILED') &&
          !text.includes('Third-party cookie')
        ) {
          consoleErrors.push(text);
        }
      }
    });

    page.on('pageerror', (error) => {
      consoleErrors.push(error.message);
    });

    await page.goto(pagePath, { waitUntil: 'networkidle' });

    // Wait a bit for any async errors
    await page.waitForTimeout(1000);

    expect(
      consoleErrors,
      `${pagePath} should have no console errors:\n${consoleErrors.join('\n')}`
    ).toHaveLength(0);
  });
}
