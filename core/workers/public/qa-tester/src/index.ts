#!/usr/bin/env node
/**
 * QA Tester CLI
 * Run automated tests on any website
 */
import { runTests, saveReports, type RunnerOptions } from './runner.js';
import { resolve } from 'node:path';

interface CliArgs {
  command: string;
  url: string;
  pages?: string[];
  viewports?: ('mobile' | 'tablet' | 'desktop')[];
  output?: string;
}

function parseArgs(args: string[]): CliArgs {
  const result: CliArgs = {
    command: args[0] || 'full-scan',
    url: '',
  };

  for (let i = 1; i < args.length; i++) {
    const arg = args[i];
    const next = args[i + 1];

    switch (arg) {
      case '--url':
      case '-u':
        result.url = next;
        i++;
        break;
      case '--pages':
      case '-p':
        result.pages = next.split(',').map((p) => p.trim());
        i++;
        break;
      case '--viewports':
      case '-v':
        result.viewports = next.split(',').map((v) => v.trim()) as CliArgs['viewports'];
        i++;
        break;
      case '--output':
      case '-o':
        result.output = next;
        i++;
        break;
    }
  }

  return result;
}

function printUsage() {
  console.log(`
QA Tester - Automated Website Testing

Usage:
  node dist/index.js <command> --url <url> [options]

Commands:
  full-scan    Run all tests on all pages (default)
  smoke-test   Quick health check (homepage + critical paths)
  page-test    Test a single page deeply

Options:
  --url, -u        Base URL to test (required)
  --pages, -p      Comma-separated page paths (default: auto-discover)
  --viewports, -v  Comma-separated viewports: mobile,tablet,desktop (default: all)
  --output, -o     Output directory for reports (default: workspace/reports/qa/)

Examples:
  node dist/index.js full-scan --url http://localhost:3000
  node dist/index.js full-scan --url http://localhost:3000 --pages /,/pricing,/demo
  node dist/index.js smoke-test --url https://example.com
  node dist/index.js page-test --url http://localhost:3000 --pages /pricing
`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (!args.url) {
    printUsage();
    process.exit(1);
  }

  console.log(`
╔══════════════════════════════════════════════╗
║           QA Tester - ${args.command.padEnd(15)}      ║
╚══════════════════════════════════════════════╝
`);

  console.log(`URL: ${args.url}`);
  if (args.pages) console.log(`Pages: ${args.pages.join(', ')}`);
  if (args.viewports) console.log(`Viewports: ${args.viewports.join(', ')}`);

  const options: RunnerOptions = {
    url: args.url,
    pages: args.pages,
    viewports: args.viewports,
    outputDir: args.output || resolve(process.cwd(), '../../workspace/reports/qa'),
  };

  // Adjust test types based on command
  if (args.command === 'smoke-test') {
    options.pages = options.pages || ['/'];
    options.testTypes = ['page-load', 'console-errors'];
    options.viewports = ['desktop'];
  } else if (args.command === 'page-test') {
    options.testTypes = ['page-load', 'console-errors', 'navigation', 'responsive', 'accessibility'];
  }

  try {
    const results = await runTests(options);

    // Extract site name from URL
    const siteName = new URL(args.url).hostname.replace(/[^a-z0-9]/gi, '-');

    // Save reports
    const outputDir = args.output || resolve(process.cwd(), '../../workspace/reports/qa');
    const paths = await saveReports(results, outputDir, siteName);

    console.log(`
╔══════════════════════════════════════════════╗
║                   Results                     ║
╚══════════════════════════════════════════════╝

Total:   ${results.summary.total}
Passed:  ${results.summary.passed}
Failed:  ${results.summary.failed}
Skipped: ${results.summary.skipped}

Reports saved:
  JSON: ${paths.json}
  MD:   ${paths.md}
`);

    process.exit(results.summary.failed > 0 ? 1 : 0);
  } catch (error) {
    console.error('Error running tests:', error);
    process.exit(1);
  }
}

main();
