#!/usr/bin/env node
/**
 * Content Analysis CLI
 * Entry point for running content analysis from command line
 *
 * Usage: npx content-analyze <page-path> [options]
 *
 * Options:
 *   --report    Generate markdown report
 *   --issues    Create GitHub issues (dry-run by default)
 *   --cms       Submit to CMS
 *   --worker    Which worker analysis (brand|sales|product|legal|all)
 *   --output    Output directory
 *   --live      Disable dry-run mode (actually create issues/submit to CMS)
 *   --high-only Only process high-priority items
 *   --max       Maximum issues to create (default: 10)
 */

import * as fs from 'node:fs';
import * as path from 'node:path';
import { parsePageFile } from './lib/parser.js';
import { analyzePageFull, type AnalysisConfig } from './lib/analyze.js';
import { generateSuggestions } from './lib/recommendations.js';
import {
  processAnalysisOutput,
  formatOutputResultJSON,
  type OutputConfig,
} from './lib/output.js';

// ============================================
// CLI Argument Parsing
// ============================================

interface CLIArgs {
  pagePath: string;
  report: boolean;
  issues: boolean;
  cms: boolean;
  worker: 'brand' | 'sales' | 'product' | 'legal' | 'all';
  output: string;
  live: boolean;
  highOnly: boolean;
  max: number;
  help: boolean;
  version: boolean;
}

function parseArgs(args: string[]): CLIArgs {
  const result: CLIArgs = {
    pagePath: '',
    report: true,
    issues: false,
    cms: false,
    worker: 'all',
    output: 'workspace/reports/content',
    live: false,
    highOnly: false,
    max: 10,
    help: false,
    version: false,
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];

    if (arg === '--help' || arg === '-h') {
      result.help = true;
    } else if (arg === '--version' || arg === '-v') {
      result.version = true;
    } else if (arg === '--report') {
      result.report = true;
    } else if (arg === '--issues') {
      result.issues = true;
    } else if (arg === '--cms') {
      result.cms = true;
    } else if (arg === '--live') {
      result.live = true;
    } else if (arg === '--high-only') {
      result.highOnly = true;
    } else if (arg === '--worker' && args[i + 1]) {
      const worker = args[++i] as CLIArgs['worker'];
      if (['brand', 'sales', 'product', 'legal', 'all'].includes(worker)) {
        result.worker = worker;
      }
    } else if (arg === '--output' && args[i + 1]) {
      result.output = args[++i];
    } else if (arg === '--max' && args[i + 1]) {
      result.max = parseInt(args[++i], 10) || 10;
    } else if (!arg.startsWith('-') && !result.pagePath) {
      result.pagePath = arg;
    }
  }

  return result;
}

function printHelp(): void {
  console.log(`
Content Analysis CLI

Usage:
  npx content-analyze <page-path> [options]
  content-analyze <page-path> [options]

Arguments:
  page-path     Path to page JSON file (from content extraction)

Options:
  --report      Generate markdown report (default: true)
  --issues      Create GitHub issues (dry-run by default)
  --cms         Submit to CMS
  --worker      Which analysis to run: brand|sales|product|legal|all (default: all)
  --output      Output directory (default: workspace/reports/content)
  --live        Disable dry-run mode (actually create issues/submit)
  --high-only   Only process high-priority items
  --max N       Maximum issues to create (default: 10)
  --help, -h    Show this help message
  --version, -v Show version

Examples:
  # Analyze a page and generate report
  npx content-analyze ./pages/home.json

  # Analyze with GitHub issues (dry run)
  npx content-analyze ./pages/pricing.json --issues

  # Full analysis with CMS submission (live)
  npx content-analyze ./pages/about.json --issues --cms --live

  # Brand-only analysis
  npx content-analyze ./pages/home.json --worker brand

  # High priority only with custom output
  npx content-analyze ./pages/home.json --high-only --output ./reports
`);
}

function printVersion(): void {
  console.log('@hq/content-shared v1.0.0');
}

// ============================================
// Main CLI Entry Point
// ============================================

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));

  if (args.help) {
    printHelp();
    process.exit(0);
  }

  if (args.version) {
    printVersion();
    process.exit(0);
  }

  if (!args.pagePath) {
    console.error('Error: Page path is required');
    console.error('Run with --help for usage information');
    process.exit(1);
  }

  // Resolve and validate page path
  const pagePath = path.resolve(args.pagePath);
  if (!fs.existsSync(pagePath)) {
    console.error(`Error: File not found: ${pagePath}`);
    process.exit(1);
  }

  console.log(`[CLI] Analyzing: ${pagePath}`);
  console.log(`[CLI] Worker: ${args.worker}`);
  console.log(`[CLI] Mode: ${args.live ? 'LIVE' : 'dry-run'}`);
  console.log('');

  try {
    // 1. Parse page content
    console.log('[1/4] Parsing page content...');
    const pageContent = await parsePageFile(pagePath);

    // 2. Configure analysis based on worker type
    const analysisConfig: AnalysisConfig = {
      enableBrand: args.worker === 'all' || args.worker === 'brand',
      enableConversion: args.worker === 'all' || args.worker === 'sales',
      enableAccuracy: args.worker === 'all' || args.worker === 'product',
      enableCompliance: args.worker === 'all' || args.worker === 'legal',
    };

    console.log('[2/4] Running analysis...');
    const analysis = analyzePageFull(pageContent, analysisConfig);

    // 3. Generate suggestions
    console.log('[3/4] Generating suggestions...');
    const suggestions = generateSuggestions(analysis);
    console.log(`      Found ${suggestions.length} suggestions`);

    // 4. Process outputs
    console.log('[4/4] Processing outputs...');
    const outputConfig: Partial<OutputConfig> = {
      reportPath: args.output,
      workerName: `content-${args.worker}`,
      enableGitHub: args.issues,
      enableCMS: args.cms,
      maxIssues: args.max,
      highPriorityOnly: args.highOnly,
      dryRun: !args.live,
    };

    const result = await processAnalysisOutput(analysis, outputConfig);

    // Print results
    console.log('');
    console.log('=== Results ===');
    console.log(`Report: ${result.reportPath || 'Not generated'}`);
    console.log(`GitHub Issues: ${result.issuesCreated}`);
    console.log(`CMS Submissions: ${result.suggestionsSubmitted}`);

    if (result.errors.length > 0) {
      console.log('');
      console.log('Errors:');
      for (const error of result.errors) {
        console.log(`  - ${error}`);
      }
    }

    // Output JSON for worker integration
    console.log('');
    console.log('=== JSON Output ===');
    console.log(JSON.stringify(formatOutputResultJSON(result), null, 2));

  } catch (error) {
    console.error('Error:', error instanceof Error ? error.message : 'Unknown error');
    process.exit(1);
  }
}

// Run if executed directly
main().catch(error => {
  console.error('Fatal error:', error);
  process.exit(1);
});
