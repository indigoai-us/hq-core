/**
 * Test Runner
 * Orchestrates Playwright tests and generates reports
 */
import { spawn } from 'node:child_process';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { discoverPages } from './discovery.js';

export interface RunnerOptions {
  url: string;
  pages?: string[];
  viewports?: ('mobile' | 'tablet' | 'desktop')[];
  outputDir?: string;
  testTypes?: ('page-load' | 'console-errors' | 'navigation' | 'responsive' | 'accessibility')[];
}

export interface TestResult {
  meta: {
    url: string;
    timestamp: string;
    duration_ms: number;
    pages_tested: number;
  };
  summary: {
    total: number;
    passed: number;
    failed: number;
    skipped: number;
  };
  failures: Array<{
    test: string;
    page: string;
    message: string;
  }>;
}

/**
 * Run Playwright tests
 */
export async function runTests(options: RunnerOptions): Promise<TestResult> {
  const {
    url,
    pages,
    viewports = ['mobile', 'tablet', 'desktop'],
    outputDir = 'test-results',
    testTypes = ['page-load', 'console-errors', 'navigation', 'responsive', 'accessibility'],
  } = options;

  const startTime = Date.now();

  // Discover pages
  const discoveredPages = await discoverPages({
    baseUrl: url,
    pages,
  });

  if (discoveredPages.length === 0) {
    throw new Error('No pages found to test');
  }

  console.log(`\nTesting ${discoveredPages.length} pages:`);
  discoveredPages.forEach((p) => console.log(`  ${p}`));
  console.log('');

  // Convert pages to full URLs
  const fullUrls = discoveredPages.map((p) => `${url}${p}`);

  // Build test file pattern
  const testFiles = testTypes.map((t) => `tests/${t}.spec.ts`);

  // Build project args for viewports (multiple --project flags)
  const projectArgs = viewports.flatMap((v) => ['--project', v]);

  // Run playwright with environment
  const env = {
    ...process.env,
    BASE_URL: url,
    TEST_PAGES: JSON.stringify(fullUrls),
  };

  return new Promise((resolve, reject) => {
    const args = [
      'playwright',
      'test',
      ...testFiles,
      ...projectArgs,
      '--reporter=json',
    ];

    console.log(`Running: npx ${args.join(' ')}`);

    const proc = spawn('npx', args, {
      env,
      cwd: dirname(dirname(import.meta.url.replace('file://', ''))),
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';

    proc.stdout.on('data', (data) => {
      stdout += data.toString();
      process.stdout.write(data);
    });

    proc.stderr.on('data', (data) => {
      stderr += data.toString();
      process.stderr.write(data);
    });

    proc.on('close', async (code) => {
      const duration = Date.now() - startTime;

      // Parse results from JSON reporter output
      let results: TestResult = {
        meta: {
          url,
          timestamp: new Date().toISOString(),
          duration_ms: duration,
          pages_tested: discoveredPages.length,
        },
        summary: {
          total: 0,
          passed: 0,
          failed: 0,
          skipped: 0,
        },
        failures: [],
      };

      try {
        const jsonPath = join(outputDir, 'results.json');
        const jsonContent = await readFile(jsonPath, 'utf-8');
        const pwResults = JSON.parse(jsonContent);

        results.summary.total = pwResults.stats?.expected || 0;
        results.summary.passed = pwResults.stats?.expected || 0;
        results.summary.failed = pwResults.stats?.unexpected || 0;
        results.summary.skipped = pwResults.stats?.skipped || 0;

        // Extract failures
        if (pwResults.suites) {
          for (const suite of pwResults.suites) {
            for (const spec of suite.specs || []) {
              for (const test of spec.tests || []) {
                if (test.status === 'unexpected') {
                  results.failures.push({
                    test: spec.title,
                    page: spec.file,
                    message: test.results?.[0]?.error?.message || 'Unknown error',
                  });
                }
              }
            }
          }
        }
      } catch {
        // Could not parse results
      }

      resolve(results);
    });

    proc.on('error', reject);
  });
}

/**
 * Generate markdown report
 */
export function generateMarkdownReport(results: TestResult): string {
  const { meta, summary, failures } = results;
  const passRate = ((summary.passed / summary.total) * 100).toFixed(1);

  let md = `# QA Report

**URL:** ${meta.url}
**Date:** ${meta.timestamp}
**Duration:** ${(meta.duration_ms / 1000).toFixed(1)}s
**Pages Tested:** ${meta.pages_tested}

## Summary

| Metric | Value |
|--------|-------|
| Total Tests | ${summary.total} |
| Passed | ${summary.passed} |
| Failed | ${summary.failed} |
| Skipped | ${summary.skipped} |
| Pass Rate | ${passRate}% |

`;

  if (failures.length > 0) {
    md += `## Failures

`;
    for (const failure of failures) {
      md += `### ${failure.test}
- **Page:** ${failure.page}
- **Error:** ${failure.message}

`;
    }
  } else {
    md += `## Result

All tests passed!
`;
  }

  return md;
}

/**
 * Save reports to output directory
 */
export async function saveReports(
  results: TestResult,
  outputDir: string,
  siteName: string
): Promise<{ json: string; md: string }> {
  const date = new Date().toISOString().split('T')[0];
  const baseName = `${date}-${siteName}-report`;

  await mkdir(outputDir, { recursive: true });

  const jsonPath = join(outputDir, `${baseName}.json`);
  const mdPath = join(outputDir, `${baseName}.md`);

  await writeFile(jsonPath, JSON.stringify(results, null, 2));
  await writeFile(mdPath, generateMarkdownReport(results));

  return { json: jsonPath, md: mdPath };
}
