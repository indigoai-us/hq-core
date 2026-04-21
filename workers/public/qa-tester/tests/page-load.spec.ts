/**
 * Page Load Tests
 * Verifies pages load successfully with HTTP 200 and render content
 */
import { test, expect } from '@playwright/test';

const pages: string[] = JSON.parse(process.env.TEST_PAGES || '[]');

for (const pagePath of pages) {
  test(`Page loads: ${pagePath}`, async ({ page }) => {
    const response = await page.goto(pagePath, { waitUntil: 'domcontentloaded' });

    // Check HTTP status
    expect(response?.status(), `${pagePath} should return 200`).toBe(200);

    // Check page has content
    const body = await page.locator('body');
    await expect(body).toBeVisible();

    // Check page has a title
    const title = await page.title();
    expect(title.length, `${pagePath} should have a title`).toBeGreaterThan(0);
  });

  test(`Page loads within 5s: ${pagePath}`, async ({ page }) => {
    const startTime = Date.now();
    await page.goto(pagePath, { waitUntil: 'load' });
    const loadTime = Date.now() - startTime;

    expect(loadTime, `${pagePath} should load within 5000ms`).toBeLessThan(5000);
  });
}
