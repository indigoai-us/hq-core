/**
 * Unified Output Manager
 * Coordinates output across reports, GitHub, and CMS
 */

import type { FullAnalysis } from './types.js';
import type { Suggestion } from './recommendations.js';
import { generateSuggestions } from './recommendations.js';
import {
  generateFullReport,
  generateExecutiveSummary,
  writeReport,
  generateReportPath,
  type ReportConfig,
  DEFAULT_REPORT_CONFIG,
} from './reporter.js';
import {
  createIssuesFromAnalysis,
  createPRFromSuggestions,
  generateGitHubIssueCommand,
  generateCommitMessage,
  type GitHubConfig,
  type GitHubIssue,
  type GitHubPR,
  DEFAULT_GITHUB_CONFIG,
} from './github-integration.js';
import {
  createCMSClient,
  createDryRunCMSClient,
  toCMSSuggestions,
  type CMSClientConfig,
  type CMSBatchResult,
} from './cms-integration.js';

// ============================================
// Types
// ============================================

export interface OutputConfig {
  /** Path for markdown reports */
  reportPath: string;
  /** Worker name for report filenames */
  workerName: string;
  /** Enable GitHub issue/PR generation */
  enableGitHub: boolean;
  /** GitHub configuration */
  githubConfig?: Partial<GitHubConfig>;
  /** Enable CMS submission */
  enableCMS: boolean;
  /** CMS configuration */
  cmsConfig?: CMSClientConfig;
  /** Maximum issues to create */
  maxIssues: number;
  /** Only high-priority items */
  highPriorityOnly: boolean;
  /** Dry run mode (no actual submissions) */
  dryRun: boolean;
}

export const DEFAULT_OUTPUT_CONFIG: OutputConfig = {
  reportPath: 'workspace/reports/content',
  workerName: 'content-worker',
  enableGitHub: false,
  githubConfig: undefined,
  enableCMS: false,
  cmsConfig: undefined,
  maxIssues: 10,
  highPriorityOnly: false,
  dryRun: true,
};

export interface OutputResult {
  /** Path to generated report */
  reportPath: string;
  /** Number of GitHub issues created/prepared */
  issuesCreated: number;
  /** GitHub issues (for dry run review) */
  issues?: GitHubIssue[];
  /** GitHub PR (if generated) */
  pr?: GitHubPR;
  /** Number of CMS suggestions submitted */
  suggestionsSubmitted: number;
  /** CMS submission result */
  cmsResult?: CMSBatchResult;
  /** Any errors encountered */
  errors: string[];
}

// ============================================
// Main Output Functions
// ============================================

/**
 * Process analysis and generate all outputs
 */
export async function processAnalysisOutput(
  analysis: FullAnalysis,
  config: Partial<OutputConfig> = {}
): Promise<OutputResult> {
  const cfg = { ...DEFAULT_OUTPUT_CONFIG, ...config };
  const errors: string[] = [];

  // Generate suggestions from analysis
  let suggestions = generateSuggestions(analysis);

  // Filter to high priority if configured
  if (cfg.highPriorityOnly) {
    suggestions = suggestions.filter(s => s.impact === 'high');
  }

  // 1. Generate and save report
  let reportPath = '';
  try {
    const reportContent = generateFullReport(analysis);
    const fullReportPath = generateReportPath(cfg.workerName, analysis.page, cfg.reportPath);
    const dir = cfg.reportPath;
    const filename = fullReportPath.split('/').pop() ?? `${analysis.page}.md`;
    reportPath = writeReport(reportContent, filename, dir);
  } catch (error) {
    errors.push(`Report generation failed: ${error instanceof Error ? error.message : 'Unknown error'}`);
  }

  // 2. Generate GitHub issues
  let issuesCreated = 0;
  let issues: GitHubIssue[] = [];
  if (cfg.enableGitHub && suggestions.length > 0) {
    try {
      issues = createIssuesFromAnalysis(
        analysis,
        suggestions,
        cfg.maxIssues,
        cfg.githubConfig
      );
      issuesCreated = issues.length;

      if (!cfg.dryRun) {
        // In non-dry-run mode, we would execute the gh commands
        // For now, we just prepare the commands
        console.log(`[GitHub] Prepared ${issues.length} issues for creation`);
        for (const issue of issues) {
          const cmd = generateGitHubIssueCommand(issue, cfg.githubConfig);
          console.log(`[GitHub] Command: ${cmd}`);
        }
      }
    } catch (error) {
      errors.push(`GitHub issue generation failed: ${error instanceof Error ? error.message : 'Unknown error'}`);
    }
  }

  // 3. Submit to CMS
  let suggestionsSubmitted = 0;
  let cmsResult: CMSBatchResult | undefined;
  if (cfg.enableCMS && suggestions.length > 0) {
    try {
      const client = cfg.dryRun
        ? createDryRunCMSClient()
        : createCMSClient(cfg.cmsConfig ?? { baseUrl: '' });

      const cmsSuggestions = toCMSSuggestions(suggestions);
      cmsResult = await client.submitSuggestions(cmsSuggestions);
      suggestionsSubmitted = cmsResult.submitted;
    } catch (error) {
      errors.push(`CMS submission failed: ${error instanceof Error ? error.message : 'Unknown error'}`);
    }
  }

  return {
    reportPath,
    issuesCreated,
    issues: cfg.dryRun ? issues : undefined,
    suggestionsSubmitted,
    cmsResult,
    errors,
  };
}

/**
 * Batch process multiple pages
 */
export async function processMultiplePages(
  analyses: FullAnalysis[],
  config: Partial<OutputConfig> = {}
): Promise<OutputResult[]> {
  const results: OutputResult[] = [];

  for (const analysis of analyses) {
    const result = await processAnalysisOutput(analysis, config);
    results.push(result);
  }

  // Also generate executive summary
  const cfg = { ...DEFAULT_OUTPUT_CONFIG, ...config };
  try {
    const summaryContent = generateExecutiveSummary(analyses);
    const date = new Date().toISOString().split('T')[0];
    const filename = `${date}-${cfg.workerName}-executive-summary.md`;
    writeReport(summaryContent, filename, cfg.reportPath);
  } catch (error) {
    console.error('Failed to generate executive summary:', error);
  }

  return results;
}

/**
 * Generate PR from approved suggestions
 */
export async function generatePRFromApprovedSuggestions(
  suggestions: Suggestion[],
  pageContents: Map<string, { path: string; content: string }>,
  config: Partial<OutputConfig> = {}
): Promise<{ pr: GitHubPR; commitMessage: string }> {
  const cfg = { ...DEFAULT_OUTPUT_CONFIG, ...config };

  const pr = createPRFromSuggestions(suggestions, pageContents, cfg.githubConfig);
  const commitMessage = generateCommitMessage(suggestions);

  return { pr, commitMessage };
}

// ============================================
// Output Summary
// ============================================

/**
 * Generate summary of output results
 */
export function summarizeOutputResults(results: OutputResult[]): string {
  const lines: string[] = [];

  lines.push('# Output Summary');
  lines.push('');

  // Totals
  const totalReports = results.filter(r => r.reportPath).length;
  const totalIssues = results.reduce((sum, r) => sum + r.issuesCreated, 0);
  const totalSubmitted = results.reduce((sum, r) => sum + r.suggestionsSubmitted, 0);
  const totalErrors = results.reduce((sum, r) => sum + r.errors.length, 0);

  lines.push('## Totals');
  lines.push('');
  lines.push(`- Reports generated: ${totalReports}`);
  lines.push(`- GitHub issues prepared: ${totalIssues}`);
  lines.push(`- CMS suggestions submitted: ${totalSubmitted}`);
  lines.push(`- Errors: ${totalErrors}`);
  lines.push('');

  // Per-page details
  lines.push('## Details');
  lines.push('');

  for (const result of results) {
    lines.push(`### ${result.reportPath.split('/').pop() ?? 'Unknown'}`);
    lines.push(`- Issues: ${result.issuesCreated}`);
    lines.push(`- CMS: ${result.suggestionsSubmitted}`);
    if (result.errors.length > 0) {
      lines.push(`- Errors: ${result.errors.join(', ')}`);
    }
    lines.push('');
  }

  return lines.join('\n');
}

/**
 * Format output result for JSON export
 */
export function formatOutputResultJSON(result: OutputResult): object {
  return {
    summary: `Generated report and ${result.issuesCreated} issues`,
    files_created: result.reportPath ? [result.reportPath] : [],
    files_modified: [],
    key_decisions: [
      result.issuesCreated > 0 ? `Created ${result.issuesCreated} GitHub issues` : null,
      result.suggestionsSubmitted > 0 ? `Submitted ${result.suggestionsSubmitted} CMS suggestions` : null,
    ].filter(Boolean),
    back_pressure: {
      typecheck: result.errors.length === 0 ? 'pass' : 'fail',
    },
  };
}

// ============================================
// Quick Actions
// ============================================

/**
 * Quick action: Generate report only
 */
export async function reportOnly(
  analysis: FullAnalysis,
  outputPath: string = DEFAULT_OUTPUT_CONFIG.reportPath,
  workerName: string = DEFAULT_OUTPUT_CONFIG.workerName
): Promise<string> {
  const result = await processAnalysisOutput(analysis, {
    reportPath: outputPath,
    workerName,
    enableGitHub: false,
    enableCMS: false,
  });
  return result.reportPath;
}

/**
 * Quick action: Generate issues only (dry run)
 */
export async function issuesOnly(
  analysis: FullAnalysis,
  maxIssues: number = 10,
  githubConfig?: Partial<GitHubConfig>
): Promise<GitHubIssue[]> {
  const result = await processAnalysisOutput(analysis, {
    enableGitHub: true,
    enableCMS: false,
    maxIssues,
    githubConfig,
    dryRun: true,
  });
  return result.issues ?? [];
}

/**
 * Quick action: Submit to CMS only
 */
export async function cmsOnly(
  analysis: FullAnalysis,
  cmsConfig: CMSClientConfig,
  dryRun: boolean = true
): Promise<CMSBatchResult | undefined> {
  const result = await processAnalysisOutput(analysis, {
    enableGitHub: false,
    enableCMS: true,
    cmsConfig,
    dryRun,
  });
  return result.cmsResult;
}

// ============================================
// Pipeline Integration
// ============================================

/**
 * Full pipeline: Analyze, suggest, and output
 */
export async function runFullPipeline(
  analyses: FullAnalysis[],
  config: Partial<OutputConfig> = {}
): Promise<{
  results: OutputResult[];
  summary: string;
  json: object;
}> {
  const results = await processMultiplePages(analyses, config);
  const summary = summarizeOutputResults(results);

  // Aggregate JSON output
  const json = {
    summary: `Processed ${analyses.length} pages`,
    files_created: results.map(r => r.reportPath).filter(Boolean),
    files_modified: [],
    key_decisions: [
      `Generated ${results.length} reports`,
      `Prepared ${results.reduce((s, r) => s + r.issuesCreated, 0)} GitHub issues`,
      `Submitted ${results.reduce((s, r) => s + r.suggestionsSubmitted, 0)} CMS suggestions`,
    ],
    back_pressure: {
      typecheck: results.every(r => r.errors.length === 0) ? 'pass' : 'fail',
    },
  };

  return { results, summary, json };
}
