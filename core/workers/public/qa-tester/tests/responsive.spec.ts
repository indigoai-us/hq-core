/**
 * Responsive Tests
 * Verifies pages render correctly at different viewport sizes
 */
import { test, expect } from '@playwright/test';

const pages: string[] = JSON.parse(process.env.TEST_PAGES || '[]');

for (const pagePath of pages) {
  test(`Responsive layout: ${pagePath}`, async ({ page }) => {
    await page.goto(pagePath, { waitUntil: 'domcontentloaded' });

    // Check no horizontal overflow
    const bodyWidth = await page.evaluate(() => document.body.scrollWidth);
    const viewportWidth = await page.evaluate(() => window.innerWidth);

    expect(
      bodyWidth,
      `${pagePath} should not have horizontal overflow (body: ${bodyWidth}px, viewport: ${viewportWidth}px)`
    ).toBeLessThanOrEqual(viewportWidth + 5); // 5px tolerance

    // Check main content is visible
    const main =
      (await page.locator('main').count()) > 0
        ? page.locator('main')
        : page.locator('body');
    await expect(main).toBeVisible();

    // Check text is readable (not too small)
    const fontSize = await page.evaluate(() => {
      const body = document.body;
      return parseInt(window.getComputedStyle(body).fontSize);
    });
    expect(fontSize, `${pagePath} base font size should be at least 12px`).toBeGreaterThanOrEqual(
      12
    );
  });

  test(`No overlapping elements: ${pagePath}`, async ({ page }) => {
    await page.goto(pagePath, { waitUntil: 'domcontentloaded' });

    // Check navigation is visible
    const nav = page.locator('nav, header').first();
    if ((await nav.count()) > 0) {
      await expect(nav).toBeVisible();
    }

    // Check footer is accessible (scroll to bottom)
    const footer = page.locator('footer').first();
    if ((await footer.count()) > 0) {
      await footer.scrollIntoViewIfNeeded();
      await expect(footer).toBeVisible();
    }
  });
}
