/**
 * Report generation utilities for content analysis workers
 * Enhanced for US-015: Full markdown report generation
 */

import * as fs from 'node:fs';
import * as path from 'node:path';
import type {
  AnalysisResult,
  Finding,
  Recommendation,
  ScoreCategory,
  ReportMeta,
  FullAnalysis,
} from './types.js';
import { getGrade, getScoreLabel, countBySeverity, sortBySeverity } from './scorer.js';
import type { Suggestion } from './recommendations.js';
import type { VariantSet } from './variants.js';
import type { StructureAnalysis } from './restructure.js';

// ============================================
// Report Configuration
// ============================================

export interface ReportConfig {
  includeScores: boolean;
  includeFindings: boolean;
  includeRecommendations: boolean;
  includeVariants: boolean;
  includeStructure: boolean;
  maxRecommendations: number;
  outputPath: string;
}

export const DEFAULT_REPORT_CONFIG: ReportConfig = {
  includeScores: true,
  includeFindings: true,
  includeRecommendations: true,
  includeVariants: false,
  includeStructure: false,
  maxRecommendations: 20,
  outputPath: 'workspace/reports/content',
};

/**
 * Generate markdown report from analysis result
 */
export function generateMarkdownReport(result: AnalysisResult): string {
  const lines: string[] = [];

  // Header
  lines.push(`# Content Analysis Report`);
  lines.push('');
  lines.push(`**Page:** ${result.pageUrl}`);
  lines.push(`**Analyzed:** ${result.analyzedAt}`);
  lines.push(`**Worker:** ${result.workerId}`);
  lines.push('');

  // Overall Score
  lines.push('## Overall Score');
  lines.push('');
  lines.push(`**${result.overallScore}/100** (${getGrade(result.overallScore)}) - ${getScoreLabel(result.overallScore)}`);
  lines.push('');

  // Score breakdown
  lines.push('### Score Breakdown');
  lines.push('');
  lines.push('| Category | Score | Grade |');
  lines.push('|----------|-------|-------|');
  for (const cat of result.categories) {
    const pct = Math.round((cat.score / cat.maxScore) * 100);
    lines.push(`| ${cat.name} | ${cat.score}/${cat.maxScore} (${pct}%) | ${getGrade(pct)} |`);
  }
  lines.push('');

  // Findings summary
  const counts = countBySeverity(result.findings);
  lines.push('## Findings Summary');
  lines.push('');
  lines.push(`- **Critical:** ${counts.critical}`);
  lines.push(`- **Warnings:** ${counts.warning}`);
  lines.push(`- **Info:** ${counts.info}`);
  lines.push(`- **Passed:** ${counts.pass}`);
  lines.push('');

  // Detailed findings
  if (result.findings.length > 0) {
    lines.push('## Detailed Findings');
    lines.push('');

    const sorted = sortBySeverity(result.findings);
    for (const finding of sorted) {
      const icon = getSeverityIcon(finding.severity);
      lines.push(`### ${icon} ${finding.category}`);
      lines.push('');
      lines.push(finding.message);
      if (finding.location) {
        lines.push(`- **Location:** ${finding.location}`);
      }
      if (finding.evidence) {
        lines.push(`- **Evidence:** "${finding.evidence}"`);
      }
      lines.push('');
    }
  }

  // Recommendations
  if (result.recommendations.length > 0) {
    lines.push('## Recommendations');
    lines.push('');

    const byPriority = groupByPriority(result.recommendations);

    if (byPriority.high.length > 0) {
      lines.push('### High Priority');
      lines.push('');
      for (const rec of byPriority.high) {
        lines.push(formatRecommendation(rec));
      }
    }

    if (byPriority.medium.length > 0) {
      lines.push('### Medium Priority');
      lines.push('');
      for (const rec of byPriority.medium) {
        lines.push(formatRecommendation(rec));
      }
    }

    if (byPriority.low.length > 0) {
      lines.push('### Low Priority');
      lines.push('');
      for (const rec of byPriority.low) {
        lines.push(formatRecommendation(rec));
      }
    }
  }

  return lines.join('\n');
}

/**
 * Get severity icon for markdown
 */
function getSeverityIcon(severity: Finding['severity']): string {
  switch (severity) {
    case 'critical': return '[CRITICAL]';
    case 'warning': return '[WARNING]';
    case 'info': return '[INFO]';
    case 'pass': return '[PASS]';
  }
}

/**
 * Format recommendation for markdown
 */
function formatRecommendation(rec: Recommendation): string {
  return [
    `**${rec.category}**`,
    `- Current: ${rec.current}`,
    `- Suggested: ${rec.suggested}`,
    `- Rationale: ${rec.rationale}`,
    ''
  ].join('\n');
}

/**
 * Group recommendations by priority
 */
function groupByPriority(recs: Recommendation[]): Record<Recommendation['priority'], Recommendation[]> {
  return {
    high: recs.filter(r => r.priority === 'high'),
    medium: recs.filter(r => r.priority === 'medium'),
    low: recs.filter(r => r.priority === 'low')
  };
}

/**
 * Generate report filename
 */
export function generateReportFilename(
  workerId: string,
  pageSlug: string
): string {
  const date = new Date().toISOString().split('T')[0];
  return `${date}-${workerId}-${pageSlug}.md`;
}

/**
 * Create report metadata
 */
export function createReportMeta(
  workerId: string,
  pageUrl: string,
  version: string
): ReportMeta {
  return {
    generatedAt: new Date().toISOString(),
    workerId,
    pageAnalyzed: pageUrl,
    version
  };
}

/**
 * Format date for reports
 */
export function formatReportDate(date: Date = new Date()): string {
  return date.toISOString().replace('T', ' ').split('.')[0] + ' UTC';
}

// ============================================
// Full Analysis Reports (US-015)
// ============================================

/**
 * Generate full analysis report from FullAnalysis
 */
export function generateFullReport(
  analysis: FullAnalysis,
  config: Partial<ReportConfig> = {}
): string {
  const cfg = { ...DEFAULT_REPORT_CONFIG, ...config };
  const lines: string[] = [];

  // Header
  lines.push(`# Content Analysis Report`);
  lines.push('');
  lines.push(`**Page:** ${analysis.page}`);
  lines.push(`**Analyzed:** ${formatReportDate(new Date(analysis.timestamp))}`);
  lines.push('');

  // Overall Health Score
  lines.push('## Overall Health Score');
  lines.push('');
  lines.push(`**${analysis.overallHealth}/100** (${getGrade(analysis.overallHealth)}) - ${getScoreLabel(analysis.overallHealth)}`);
  lines.push('');

  // Score Breakdown
  if (cfg.includeScores) {
    lines.push('### Score Breakdown');
    lines.push('');
    lines.push('| Dimension | Score | Grade |');
    lines.push('|-----------|-------|-------|');

    if (analysis.brand) {
      lines.push(`| Brand Voice | ${analysis.brand.overallScore}/100 | ${getGrade(analysis.brand.overallScore)} |`);
    }
    if (analysis.conversion) {
      lines.push(`| Conversion | ${analysis.conversion.overallScore}/100 | ${getGrade(analysis.conversion.overallScore)} |`);
    }
    if (analysis.accuracy) {
      lines.push(`| Accuracy | ${analysis.accuracy.overallScore}/100 | ${getGrade(analysis.accuracy.overallScore)} |`);
    }
    if (analysis.compliance) {
      lines.push(`| Compliance | ${analysis.compliance.overallScore}/100 | ${getGrade(analysis.compliance.overallScore)} |`);
    }
    lines.push('');
  }

  // Findings Summary
  if (cfg.includeFindings) {
    const allFindings: Finding[] = [
      ...(analysis.brand?.findings ?? []),
      ...(analysis.conversion?.findings ?? []),
      ...(analysis.accuracy?.findings ?? []),
      ...(analysis.compliance?.findings ?? []),
    ];

    const counts = countBySeverity(allFindings);
    lines.push('## Findings Summary');
    lines.push('');
    lines.push(`- **Critical:** ${counts.critical}`);
    lines.push(`- **Warnings:** ${counts.warning}`);
    lines.push(`- **Info:** ${counts.info}`);
    lines.push(`- **Passed:** ${counts.pass}`);
    lines.push('');

    // Detailed findings by dimension
    if (allFindings.length > 0) {
      lines.push('### Detailed Findings');
      lines.push('');

      if (analysis.brand && analysis.brand.findings.length > 0) {
        lines.push('#### Brand Voice');
        for (const finding of sortBySeverity(analysis.brand.findings)) {
          lines.push(formatFindingLine(finding));
        }
        lines.push('');
      }

      if (analysis.conversion && analysis.conversion.findings.length > 0) {
        lines.push('#### Conversion');
        for (const finding of sortBySeverity(analysis.conversion.findings)) {
          lines.push(formatFindingLine(finding));
        }
        lines.push('');
      }

      if (analysis.accuracy && analysis.accuracy.findings.length > 0) {
        lines.push('#### Accuracy');
        for (const finding of sortBySeverity(analysis.accuracy.findings)) {
          lines.push(formatFindingLine(finding));
        }
        lines.push('');
      }

      if (analysis.compliance && analysis.compliance.findings.length > 0) {
        lines.push('#### Compliance');
        for (const finding of sortBySeverity(analysis.compliance.findings)) {
          lines.push(formatFindingLine(finding));
        }
        lines.push('');
      }
    }
  }

  // Top Priorities / Recommendations
  if (cfg.includeRecommendations && analysis.topPriorities.length > 0) {
    lines.push('## Top Priorities');
    lines.push('');

    const priorities = analysis.topPriorities.slice(0, cfg.maxRecommendations);
    const byPriority = groupByPriority(priorities);

    if (byPriority.high.length > 0) {
      lines.push('### High Priority');
      lines.push('');
      for (const rec of byPriority.high) {
        lines.push(formatRecommendation(rec));
      }
    }

    if (byPriority.medium.length > 0) {
      lines.push('### Medium Priority');
      lines.push('');
      for (const rec of byPriority.medium) {
        lines.push(formatRecommendation(rec));
      }
    }

    if (byPriority.low.length > 0) {
      lines.push('### Low Priority');
      lines.push('');
      for (const rec of byPriority.low) {
        lines.push(formatRecommendation(rec));
      }
    }
  }

  return lines.join('\n');
}

/**
 * Format a single finding as a line
 */
function formatFindingLine(finding: Finding): string {
  const icon = getSeverityIcon(finding.severity);
  let line = `- ${icon} **${finding.category}**: ${finding.message}`;
  if (finding.evidence) {
    line += ` ("${truncateText(finding.evidence, 60)}")`;
  }
  return line;
}

/**
 * Truncate text with ellipsis
 */
function truncateText(text: string, maxLen: number): string {
  if (text.length <= maxLen) return text;
  return text.slice(0, maxLen - 3) + '...';
}

/**
 * Generate executive summary for multiple pages (1 page max)
 */
export function generateExecutiveSummary(analyses: FullAnalysis[]): string {
  const lines: string[] = [];

  lines.push('# Executive Summary: Content Health');
  lines.push('');
  lines.push(`**Report Date:** ${formatReportDate()}`);
  lines.push(`**Pages Analyzed:** ${analyses.length}`);
  lines.push('');

  // Overall statistics
  const avgHealth = Math.round(
    analyses.reduce((sum, a) => sum + a.overallHealth, 0) / analyses.length
  );

  // Count total issues
  let totalCritical = 0;
  let totalWarnings = 0;
  for (const analysis of analyses) {
    const allFindings = [
      ...(analysis.brand?.findings ?? []),
      ...(analysis.conversion?.findings ?? []),
      ...(analysis.accuracy?.findings ?? []),
      ...(analysis.compliance?.findings ?? []),
    ];
    for (const f of allFindings) {
      if (f.severity === 'critical') totalCritical++;
      if (f.severity === 'warning') totalWarnings++;
    }
  }

  lines.push('## Overall Health');
  lines.push('');
  lines.push(`- **Average Score:** ${avgHealth}/100 (${getGrade(avgHealth)})`);
  lines.push(`- **Critical Issues:** ${totalCritical}`);
  lines.push(`- **Warnings:** ${totalWarnings}`);
  lines.push('');

  // Page summary table
  lines.push('## Page Summary');
  lines.push('');
  lines.push('| Page | Health | Brand | Conversion | Accuracy | Compliance |');
  lines.push('|------|--------|-------|------------|----------|------------|');

  for (const analysis of analyses) {
    const row = [
      analysis.page,
      `${analysis.overallHealth}`,
      analysis.brand ? `${analysis.brand.overallScore}` : '-',
      analysis.conversion ? `${analysis.conversion.overallScore}` : '-',
      analysis.accuracy ? `${analysis.accuracy.overallScore}` : '-',
      analysis.compliance ? `${analysis.compliance.overallScore}` : '-',
    ];
    lines.push(`| ${row.join(' | ')} |`);
  }
  lines.push('');

  // Top 5 priorities across all pages
  lines.push('## Top Priorities');
  lines.push('');

  const allPriorities: Array<Recommendation & { page: string }> = [];
  for (const analysis of analyses) {
    for (const rec of analysis.topPriorities) {
      allPriorities.push({ ...rec, page: analysis.page });
    }
  }

  // Sort by priority and take top 5
  const priorityOrder: Record<string, number> = { high: 0, medium: 1, low: 2 };
  allPriorities.sort((a, b) => priorityOrder[a.priority] - priorityOrder[b.priority]);

  for (const rec of allPriorities.slice(0, 5)) {
    lines.push(`1. **[${rec.page}]** ${rec.category}: ${rec.suggested}`);
  }
  lines.push('');

  return lines.join('\n');
}

/**
 * Generate detailed report for a single page
 */
export function generatePageReport(
  analysis: FullAnalysis,
  suggestions?: Suggestion[],
  variants?: VariantSet[],
  structure?: StructureAnalysis
): string {
  const lines: string[] = [];

  // Base report
  lines.push(generateFullReport(analysis, {
    includeVariants: !!variants,
    includeStructure: !!structure,
  }));

  // Add suggestions section
  if (suggestions && suggestions.length > 0) {
    lines.push('');
    lines.push('## Improvement Suggestions');
    lines.push('');

    for (const s of suggestions.slice(0, 10)) {
      const effortBadge = s.effort === 'quick' ? 'Quick' : s.effort === 'moderate' ? 'Moderate' : 'Major';
      lines.push(`### ${s.type.toUpperCase()}: ${s.sectionId ?? 'Page-level'}`);
      lines.push(`**Impact:** ${s.impact} | **Effort:** ${effortBadge} | **Source:** ${s.source}`);
      lines.push('');
      lines.push('**Current:**');
      lines.push(`> ${s.original}`);
      lines.push('');
      lines.push('**Suggested:**');
      lines.push(`> ${s.suggested}`);
      lines.push('');
      lines.push(`_${s.rationale}_`);
      lines.push('');
    }
  }

  // Add variants section
  if (variants && variants.length > 0) {
    lines.push('');
    lines.push('## A/B Copy Variants');
    lines.push('');

    for (const vs of variants.slice(0, 5)) {
      lines.push(`### ${vs.sectionId ?? 'Content'}`);
      lines.push('');
      lines.push('**Original:**');
      lines.push(`> ${vs.original}`);
      lines.push('');

      for (const v of vs.variants) {
        lines.push(`**${formatApproachLabel(v.approach)}:**`);
        lines.push(`> ${v.text}`);
        lines.push('');
      }
    }
  }

  // Add structure section
  if (structure) {
    lines.push('');
    lines.push('## Structure Analysis');
    lines.push('');
    lines.push(`**Template:** ${structure.templateUsed}`);
    lines.push(`**Score:** ${structure.structureScore}/100`);
    lines.push('');

    if (structure.missingSections.length > 0) {
      lines.push('**Missing Sections:**');
      for (const s of structure.missingSections) {
        lines.push(`- ${s}`);
      }
      lines.push('');
    }

    if (structure.orderIssues.length > 0) {
      lines.push('**Order Issues:**');
      for (const i of structure.orderIssues) {
        lines.push(`- ${i}`);
      }
      lines.push('');
    }
  }

  return lines.join('\n');
}

/**
 * Format approach label
 */
function formatApproachLabel(approach: string): string {
  const labels: Record<string, string> = {
    'emotional': 'Emotional',
    'logical': 'Logical',
    'urgent': 'Urgency',
    'social-proof': 'Social Proof',
    'benefit-focused': 'Benefit-Focused',
  };
  return labels[approach] ?? approach;
}

/**
 * Generate comparison report (before/after)
 */
export function generateComparisonReport(
  before: FullAnalysis,
  after: FullAnalysis
): string {
  const lines: string[] = [];

  lines.push('# Content Analysis Comparison');
  lines.push('');
  lines.push(`**Page:** ${before.page}`);
  lines.push(`**Before:** ${formatReportDate(new Date(before.timestamp))}`);
  lines.push(`**After:** ${formatReportDate(new Date(after.timestamp))}`);
  lines.push('');

  // Health delta
  const healthDelta = after.overallHealth - before.overallHealth;
  const deltaIcon = healthDelta > 0 ? '+' : healthDelta < 0 ? '' : '';
  lines.push('## Overall Health');
  lines.push('');
  lines.push(`| Metric | Before | After | Change |`);
  lines.push(`|--------|--------|-------|--------|`);
  lines.push(`| Health Score | ${before.overallHealth} | ${after.overallHealth} | ${deltaIcon}${healthDelta} |`);

  // Dimension deltas
  if (before.brand && after.brand) {
    const delta = after.brand.overallScore - before.brand.overallScore;
    lines.push(`| Brand | ${before.brand.overallScore} | ${after.brand.overallScore} | ${delta >= 0 ? '+' : ''}${delta} |`);
  }
  if (before.conversion && after.conversion) {
    const delta = after.conversion.overallScore - before.conversion.overallScore;
    lines.push(`| Conversion | ${before.conversion.overallScore} | ${after.conversion.overallScore} | ${delta >= 0 ? '+' : ''}${delta} |`);
  }
  if (before.accuracy && after.accuracy) {
    const delta = after.accuracy.overallScore - before.accuracy.overallScore;
    lines.push(`| Accuracy | ${before.accuracy.overallScore} | ${after.accuracy.overallScore} | ${delta >= 0 ? '+' : ''}${delta} |`);
  }
  if (before.compliance && after.compliance) {
    const delta = after.compliance.overallScore - before.compliance.overallScore;
    lines.push(`| Compliance | ${before.compliance.overallScore} | ${after.compliance.overallScore} | ${delta >= 0 ? '+' : ''}${delta} |`);
  }
  lines.push('');

  // Findings comparison
  const beforeFindings = countAllFindings(before);
  const afterFindings = countAllFindings(after);

  lines.push('## Findings Comparison');
  lines.push('');
  lines.push('| Severity | Before | After | Change |');
  lines.push('|----------|--------|-------|--------|');
  lines.push(`| Critical | ${beforeFindings.critical} | ${afterFindings.critical} | ${formatDelta(afterFindings.critical - beforeFindings.critical, true)} |`);
  lines.push(`| Warning | ${beforeFindings.warning} | ${afterFindings.warning} | ${formatDelta(afterFindings.warning - beforeFindings.warning, true)} |`);
  lines.push('');

  // Summary
  lines.push('## Summary');
  lines.push('');
  if (healthDelta > 0) {
    lines.push(`Content health improved by **${healthDelta} points**.`);
  } else if (healthDelta < 0) {
    lines.push(`Content health decreased by **${Math.abs(healthDelta)} points**.`);
  } else {
    lines.push('Content health remained unchanged.');
  }

  const criticalDelta = afterFindings.critical - beforeFindings.critical;
  if (criticalDelta < 0) {
    lines.push(`Resolved **${Math.abs(criticalDelta)} critical** issues.`);
  } else if (criticalDelta > 0) {
    lines.push(`**${criticalDelta} new critical** issues detected.`);
  }
  lines.push('');

  return lines.join('\n');
}

/**
 * Count all findings across dimensions
 */
function countAllFindings(analysis: FullAnalysis): Record<Finding['severity'], number> {
  const allFindings: Finding[] = [
    ...(analysis.brand?.findings ?? []),
    ...(analysis.conversion?.findings ?? []),
    ...(analysis.accuracy?.findings ?? []),
    ...(analysis.compliance?.findings ?? []),
  ];
  return countBySeverity(allFindings);
}

/**
 * Format delta with appropriate sign (inverse for issues where less is better)
 */
function formatDelta(delta: number, inverse = false): string {
  if (delta === 0) return '0';
  if (inverse) {
    // For issues, negative delta is good (fewer issues)
    return delta < 0 ? `${delta} (improved)` : `+${delta} (worse)`;
  }
  return delta > 0 ? `+${delta}` : `${delta}`;
}

// ============================================
// File Output Functions
// ============================================

/**
 * Write report to file
 */
export function writeReport(
  content: string,
  filename: string,
  outputPath: string
): string {
  // Ensure output directory exists
  const fullPath = path.resolve(outputPath);
  if (!fs.existsSync(fullPath)) {
    fs.mkdirSync(fullPath, { recursive: true });
  }

  const filePath = path.join(fullPath, filename);
  fs.writeFileSync(filePath, content, 'utf-8');

  return filePath;
}

/**
 * Generate report file path with standard naming
 * Format: {YYYY-MM-DD}-{worker}-{page-slug}.md
 */
export function generateReportPath(
  worker: string,
  page: string,
  outputPath: string
): string {
  const date = new Date().toISOString().split('T')[0];
  const pageSlug = page.replace(/[^a-z0-9]+/gi, '-').toLowerCase().replace(/^-|-$/g, '');
  const filename = `${date}-${worker}-${pageSlug}.md`;

  return path.join(outputPath, filename);
}

/**
 * Save full analysis report to file
 */
export function saveFullReport(
  analysis: FullAnalysis,
  worker: string,
  outputPath: string = DEFAULT_REPORT_CONFIG.outputPath,
  config?: Partial<ReportConfig>
): string {
  const content = generateFullReport(analysis, config);
  const reportPath = generateReportPath(worker, analysis.page, outputPath);
  const dir = path.dirname(reportPath);
  const filename = path.basename(reportPath);

  return writeReport(content, filename, dir);
}

/**
 * Save executive summary to file
 */
export function saveExecutiveSummary(
  analyses: FullAnalysis[],
  worker: string,
  outputPath: string = DEFAULT_REPORT_CONFIG.outputPath
): string {
  const content = generateExecutiveSummary(analyses);
  const date = new Date().toISOString().split('T')[0];
  const filename = `${date}-${worker}-executive-summary.md`;

  return writeReport(content, filename, outputPath);
}

/**
 * Save comparison report to file
 */
export function saveComparisonReport(
  before: FullAnalysis,
  after: FullAnalysis,
  worker: string,
  outputPath: string = DEFAULT_REPORT_CONFIG.outputPath
): string {
  const content = generateComparisonReport(before, after);
  const date = new Date().toISOString().split('T')[0];
  const pageSlug = before.page.replace(/[^a-z0-9]+/gi, '-').toLowerCase();
  const filename = `${date}-${worker}-${pageSlug}-comparison.md`;

  return writeReport(content, filename, outputPath);
}
