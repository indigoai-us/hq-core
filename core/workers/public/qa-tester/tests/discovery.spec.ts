import { expect, test } from '@playwright/test';
import { discoverFromSitemap } from '../src/discovery.js';

test.describe.configure({ mode: 'serial' });

const originalFetch = globalThis.fetch;
const originalWarn = console.warn;
const originalTimeout = AbortSignal.timeout;

test.afterEach(() => {
  globalThis.fetch = originalFetch;
  console.warn = originalWarn;
  AbortSignal.timeout = originalTimeout;
});

test('uses normal sitemap results without warning', async () => {
  const warnings: unknown[][] = [];
  console.warn = (...args: unknown[]) => warnings.push(args);
  globalThis.fetch = async () => new Response(
    '<urlset><url><loc>https://example.test/</loc></url><url><loc>https://example.test/pricing</loc></url></urlset>',
  );

  await expect(discoverFromSitemap('https://example.test')).resolves.toEqual(['/', '/pricing']);
  expect(warnings).toEqual([]);
});

test('keeps a missing sitemap quiet and returns the empty fallback', async () => {
  const warnings: unknown[][] = [];
  console.warn = (...args: unknown[]) => warnings.push(args);
  globalThis.fetch = async () => new Response('', { status: 404 });

  await expect(discoverFromSitemap('https://example.test')).resolves.toEqual([]);
  expect(warnings).toEqual([]);
});

test('reports an HTTP failure once and keeps the empty fallback', async () => {
  const warnings: unknown[][] = [];
  console.warn = (...args: unknown[]) => warnings.push(args);
  globalThis.fetch = async () => new Response('', { status: 503 });

  await expect(discoverFromSitemap('https://example.test')).resolves.toEqual([]);
  expect(warnings).toEqual([
    ['[qa-tester] sitemap request failed', { status: 503 }],
  ]);
});

test('bounds sitemap fetch and reports timeout while keeping the empty fallback', async () => {
  const warnings: unknown[][] = [];
  let timeoutMs: number | undefined;
  let passedSignal: AbortSignal | null | undefined;
  const timeoutController = new AbortController();

  console.warn = (...args: unknown[]) => warnings.push(args);
  AbortSignal.timeout = ((ms: number) => {
    timeoutMs = ms;
    return timeoutController.signal;
  }) as typeof AbortSignal.timeout;
  globalThis.fetch = async (_input, init) => {
    passedSignal = init?.signal;
    throw new DOMException('request timed out', 'TimeoutError');
  };

  await expect(discoverFromSitemap('https://example.test')).resolves.toEqual([]);
  expect(timeoutMs).toBe(10_000);
  expect(passedSignal).toBe(timeoutController.signal);
  expect(warnings).toEqual([
    ['[qa-tester] sitemap discovery failed', { errorName: 'TimeoutError' }],
  ]);
});
