/**
 * Page Discovery
 * Discovers pages to test via sitemap, crawling, or manual list
 */
import { chromium } from '@playwright/test';
import { parseStringPromise } from 'xml2js';

export interface DiscoveryOptions {
  baseUrl: string;
  pages?: string[];
  maxPages?: number;
}

/**
 * Discover pages from sitemap.xml
 */
export async function discoverFromSitemap(baseUrl: string): Promise<string[]> {
  const sitemapUrl = `${baseUrl}/sitemap.xml`;

  try {
    const response = await fetch(sitemapUrl);
    if (!response.ok) return [];

    const xml = await response.text();
    const result = await parseStringPromise(xml);

    const urls: string[] = [];
    if (result.urlset?.url) {
      for (const entry of result.urlset.url) {
        const loc = entry.loc?.[0];
        if (loc) {
          // Convert to relative path
          const path = loc.replace(baseUrl, '').replace(/\/$/, '') || '/';
          urls.push(path);
        }
      }
    }

    return urls;
  } catch {
    return [];
  }
}

/**
 * Crawl site from homepage to discover pages
 */
export async function discoverByCrawling(
  baseUrl: string,
  maxPages: number = 50
): Promise<string[]> {
  const discovered = new Set<string>(['/']);
  const toVisit = ['/'];
  const visited = new Set<string>();

  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  while (toVisit.length > 0 && discovered.size < maxPages) {
    const path = toVisit.shift()!;
    if (visited.has(path)) continue;
    visited.add(path);

    try {
      await page.goto(`${baseUrl}${path}`, {
        waitUntil: 'domcontentloaded',
        timeout: 10000,
      });

      // Find all internal links
      const links = await page.locator('a[href^="/"]').all();
      for (const link of links) {
        const href = await link.getAttribute('href');
        if (href && !discovered.has(href)) {
          // Skip anchors, files, and query strings
          if (
            href.includes('#') ||
            href.includes('.') ||
            href.includes('?')
          ) {
            continue;
          }
          discovered.add(href);
          toVisit.push(href);
        }
      }
    } catch {
      // Skip pages that fail to load
    }
  }

  await browser.close();
  return Array.from(discovered).sort();
}

/**
 * Main discovery function
 */
export async function discoverPages(options: DiscoveryOptions): Promise<string[]> {
  const { baseUrl, pages, maxPages = 50 } = options;

  // If manual pages provided, use them
  if (pages && pages.length > 0) {
    return pages.map((p) => (p.startsWith('/') ? p : `/${p}`));
  }

  // Try sitemap first
  console.log('Checking for sitemap.xml...');
  const sitemapPages = await discoverFromSitemap(baseUrl);
  if (sitemapPages.length > 0) {
    console.log(`Found ${sitemapPages.length} pages in sitemap`);
    return sitemapPages.slice(0, maxPages);
  }

  // Fall back to crawling
  console.log('No sitemap found, crawling site...');
  const crawledPages = await discoverByCrawling(baseUrl, maxPages);
  console.log(`Discovered ${crawledPages.length} pages by crawling`);
  return crawledPages;
}
