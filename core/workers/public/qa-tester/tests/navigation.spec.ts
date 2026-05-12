/**
 * Navigation Tests
 * Verifies all internal links work and don't 404
 */
import { test, expect } from '@playwright/test';

const pages: string[] = JSON.parse(process.env.TEST_PAGES || '[]');

for (const pagePath of pages) {
  test(`Internal links work: ${pagePath}`, async ({ page, baseURL }) => {
    await page.goto(pagePath, { waitUntil: 'domcontentloaded' });

    // Get all internal links
    const links = await page.locator('a[href^="/"], a[href^="' + baseURL + '"]').all();
    const brokenLinks: string[] = [];

    for (const link of links.slice(0, 20)) {
      // Limit to first 20 links per page
      const href = await link.getAttribute('href');
      if (!href) continue;

      // Skip anchors and external links
      if (href.startsWith('#') || href.startsWith('mailto:') || href.startsWith('tel:')) {
        continue;
      }

      // Normalize URL
      const url = href.startsWith('/') ? `${baseURL}${href}` : href;

      try {
        const response = await page.request.get(url);
        if (response.status() === 404) {
          brokenLinks.push(`${href} (404)`);
        }
      } catch (e) {
        brokenLinks.push(`${href} (failed to fetch)`);
      }
    }

    expect(
      brokenLinks,
      `${pagePath} has broken links:\n${brokenLinks.join('\n')}`
    ).toHaveLength(0);
  });
}
