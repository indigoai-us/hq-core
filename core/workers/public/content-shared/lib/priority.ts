/**
 * Priority Scoring System (US-012)
 * Ranks suggestions by impact and effort for optimal prioritization
 */

import type { Suggestion } from './recommendations.js';

// ============================================
// Types
// ============================================

export interface PriorityConfig {
  impactWeights: { high: number; medium: number; low: number };
  effortWeights: { quick: number; moderate: number; significant: number };
}

export interface PrioritizedSuggestion extends Suggestion {
  priorityLabel: string;
  priorityRank: number;
}

export interface PriorityBreakdown {
  quickWins: Suggestion[];
  highValue: Suggestion[];
  strategic: Suggestion[];
  backlog: Suggestion[];
}

// ============================================
// Configuration
// ============================================

export const DEFAULT_PRIORITY_CONFIG: PriorityConfig = {
  impactWeights: { high: 3, medium: 2, low: 1 },
  effortWeights: { quick: 3, moderate: 2, significant: 1 },
};

// Alternative configs for different strategies
export const URGENCY_FOCUSED_CONFIG: PriorityConfig = {
  impactWeights: { high: 4, medium: 2, low: 1 },
  effortWeights: { quick: 2, moderate: 2, significant: 2 },
};

export const EFFICIENCY_FOCUSED_CONFIG: PriorityConfig = {
  impactWeights: { high: 2, medium: 2, low: 2 },
  effortWeights: { quick: 4, moderate: 2, significant: 1 },
};

// ============================================
// Priority Calculation
// ============================================

/**
 * Calculate priority score (higher = do first)
 * Score = impact weight * effort weight
 */
export function calculatePriority(
  impact: Suggestion['impact'],
  effort: Suggestion['effort'],
  config: PriorityConfig = DEFAULT_PRIORITY_CONFIG
): number {
  const impactScore = config.impactWeights[impact];
  const effortScore = config.effortWeights[effort];
  return impactScore * effortScore;
}

/**
 * Get the maximum possible priority score for a config
 */
export function getMaxPriority(config: PriorityConfig = DEFAULT_PRIORITY_CONFIG): number {
  return Math.max(...Object.values(config.impactWeights)) *
         Math.max(...Object.values(config.effortWeights));
}

/**
 * Normalize priority to 0-100 scale
 */
export function normalizePriority(
  priority: number,
  config: PriorityConfig = DEFAULT_PRIORITY_CONFIG
): number {
  const max = getMaxPriority(config);
  return Math.round((priority / max) * 100);
}

/**
 * Get priority label based on score
 */
export function getPriorityLabel(priority: number, config: PriorityConfig = DEFAULT_PRIORITY_CONFIG): string {
  const normalized = normalizePriority(priority, config);

  if (normalized >= 75) return 'Critical';
  if (normalized >= 50) return 'High';
  if (normalized >= 25) return 'Medium';
  return 'Low';
}

// ============================================
// Sorting and Ranking
// ============================================

/**
 * Sort suggestions by priority (highest first)
 */
export function sortByPriority(
  suggestions: Suggestion[],
  config: PriorityConfig = DEFAULT_PRIORITY_CONFIG
): Suggestion[] {
  return [...suggestions].sort((a, b) => {
    const priorityA = calculatePriority(a.impact, a.effort, config);
    const priorityB = calculatePriority(b.impact, b.effort, config);
    return priorityB - priorityA;
  });
}

/**
 * Sort and add rank/label to suggestions
 */
export function rankSuggestions(
  suggestions: Suggestion[],
  config: PriorityConfig = DEFAULT_PRIORITY_CONFIG
): PrioritizedSuggestion[] {
  const sorted = sortByPriority(suggestions, config);

  return sorted.map((suggestion, index) => ({
    ...suggestion,
    priorityLabel: getPriorityLabel(suggestion.priority, config),
    priorityRank: index + 1,
  }));
}

// ============================================
// Grouping Functions
// ============================================

/**
 * Group suggestions by effort level
 */
export function groupByEffort(suggestions: Suggestion[]): Record<string, Suggestion[]> {
  return {
    quick: suggestions.filter(s => s.effort === 'quick'),
    moderate: suggestions.filter(s => s.effort === 'moderate'),
    significant: suggestions.filter(s => s.effort === 'significant'),
  };
}

/**
 * Group suggestions by impact level
 */
export function groupByImpact(suggestions: Suggestion[]): Record<string, Suggestion[]> {
  return {
    high: suggestions.filter(s => s.impact === 'high'),
    medium: suggestions.filter(s => s.impact === 'medium'),
    low: suggestions.filter(s => s.impact === 'low'),
  };
}

/**
 * Group suggestions by source
 */
export function groupBySource(suggestions: Suggestion[]): Record<string, Suggestion[]> {
  return {
    brand: suggestions.filter(s => s.source === 'brand'),
    sales: suggestions.filter(s => s.source === 'sales'),
    product: suggestions.filter(s => s.source === 'product'),
    legal: suggestions.filter(s => s.source === 'legal'),
  };
}

/**
 * Group suggestions by type
 */
export function groupByType(suggestions: Suggestion[]): Record<string, Suggestion[]> {
  return {
    text: suggestions.filter(s => s.type === 'text'),
    structure: suggestions.filter(s => s.type === 'structure'),
    cta: suggestions.filter(s => s.type === 'cta'),
    stat: suggestions.filter(s => s.type === 'stat'),
    claim: suggestions.filter(s => s.type === 'claim'),
  };
}

/**
 * Group suggestions by page
 */
export function groupByPage(suggestions: Suggestion[]): Record<string, Suggestion[]> {
  const byPage: Record<string, Suggestion[]> = {};

  for (const suggestion of suggestions) {
    if (!byPage[suggestion.pageSlug]) {
      byPage[suggestion.pageSlug] = [];
    }
    byPage[suggestion.pageSlug].push(suggestion);
  }

  return byPage;
}

// ============================================
// Quick Wins and Strategic Breakdown
// ============================================

/**
 * Get quick wins (high impact, quick effort)
 */
export function getQuickWins(suggestions: Suggestion[]): Suggestion[] {
  return suggestions
    .filter(s => s.impact === 'high' && s.effort === 'quick')
    .sort((a, b) => b.priority - a.priority);
}

/**
 * Get high-value items (high impact, any effort)
 */
export function getHighValue(suggestions: Suggestion[]): Suggestion[] {
  return suggestions
    .filter(s => s.impact === 'high')
    .sort((a, b) => b.priority - a.priority);
}

/**
 * Get easy fixes (any impact, quick effort)
 */
export function getEasyFixes(suggestions: Suggestion[]): Suggestion[] {
  return suggestions
    .filter(s => s.effort === 'quick')
    .sort((a, b) => b.priority - a.priority);
}

/**
 * Get strategic items (high impact, significant effort)
 * These require planning but deliver big results
 */
export function getStrategicItems(suggestions: Suggestion[]): Suggestion[] {
  return suggestions
    .filter(s => s.impact === 'high' && s.effort === 'significant')
    .sort((a, b) => b.priority - a.priority);
}

/**
 * Get backlog items (low impact, significant effort)
 * These should be deprioritized
 */
export function getBacklogItems(suggestions: Suggestion[]): Suggestion[] {
  return suggestions
    .filter(s => s.impact === 'low' && s.effort === 'significant')
    .sort((a, b) => b.priority - a.priority);
}

/**
 * Get full priority breakdown
 */
export function getPriorityBreakdown(suggestions: Suggestion[]): PriorityBreakdown {
  return {
    quickWins: getQuickWins(suggestions),
    highValue: getHighValue(suggestions).filter(s => s.effort !== 'quick'), // Exclude already in quick wins
    strategic: getStrategicItems(suggestions),
    backlog: getBacklogItems(suggestions),
  };
}

// ============================================
// Filtering
// ============================================

/**
 * Filter suggestions by minimum priority
 */
export function filterByMinPriority(
  suggestions: Suggestion[],
  minPriority: number
): Suggestion[] {
  return suggestions.filter(s => s.priority >= minPriority);
}

/**
 * Filter suggestions by source
 */
export function filterBySource(
  suggestions: Suggestion[],
  sources: Suggestion['source'][]
): Suggestion[] {
  return suggestions.filter(s => sources.includes(s.source));
}

/**
 * Filter suggestions by page
 */
export function filterByPage(
  suggestions: Suggestion[],
  pageSlugs: string[]
): Suggestion[] {
  return suggestions.filter(s => pageSlugs.includes(s.pageSlug));
}

/**
 * Get top N suggestions
 */
export function getTopSuggestions(
  suggestions: Suggestion[],
  n: number,
  config: PriorityConfig = DEFAULT_PRIORITY_CONFIG
): Suggestion[] {
  return sortByPriority(suggestions, config).slice(0, n);
}

// ============================================
// Statistics
// ============================================

/**
 * Calculate priority statistics for a set of suggestions
 */
export function calculatePriorityStats(suggestions: Suggestion[]): {
  total: number;
  avgPriority: number;
  byImpact: Record<string, number>;
  byEffort: Record<string, number>;
  quickWinCount: number;
  estimatedHours: number;
} {
  if (suggestions.length === 0) {
    return {
      total: 0,
      avgPriority: 0,
      byImpact: { high: 0, medium: 0, low: 0 },
      byEffort: { quick: 0, moderate: 0, significant: 0 },
      quickWinCount: 0,
      estimatedHours: 0,
    };
  }

  const byImpact = { high: 0, medium: 0, low: 0 };
  const byEffort = { quick: 0, moderate: 0, significant: 0 };
  let totalPriority = 0;
  let quickWinCount = 0;

  for (const s of suggestions) {
    totalPriority += s.priority;
    byImpact[s.impact]++;
    byEffort[s.effort]++;
    if (s.impact === 'high' && s.effort === 'quick') quickWinCount++;
  }

  // Rough hour estimates
  const effortHours = {
    quick: 0.5,
    moderate: 2,
    significant: 8,
  };

  const estimatedHours = suggestions.reduce((sum, s) => sum + effortHours[s.effort], 0);

  return {
    total: suggestions.length,
    avgPriority: Math.round(totalPriority / suggestions.length),
    byImpact,
    byEffort,
    quickWinCount,
    estimatedHours,
  };
}

// ============================================
// Formatting
// ============================================

/**
 * Format priority breakdown as markdown
 */
export function formatPriorityBreakdownMarkdown(breakdown: PriorityBreakdown): string {
  const lines: string[] = ['# Priority Breakdown\n'];

  if (breakdown.quickWins.length > 0) {
    lines.push(`## Quick Wins (${breakdown.quickWins.length})`);
    lines.push('High impact, low effort - do these first!\n');
    for (const s of breakdown.quickWins) {
      lines.push(`- **${s.pageSlug}**: ${truncate(s.original, 60)} -> ${truncate(s.suggested, 60)}`);
    }
    lines.push('');
  }

  if (breakdown.highValue.length > 0) {
    lines.push(`## High Value (${breakdown.highValue.length})`);
    lines.push('High impact, moderate effort - schedule these\n');
    for (const s of breakdown.highValue) {
      lines.push(`- **${s.pageSlug}**: ${truncate(s.original, 60)}`);
    }
    lines.push('');
  }

  if (breakdown.strategic.length > 0) {
    lines.push(`## Strategic (${breakdown.strategic.length})`);
    lines.push('High impact, significant effort - plan these carefully\n');
    for (const s of breakdown.strategic) {
      lines.push(`- **${s.pageSlug}**: ${truncate(s.original, 60)}`);
    }
    lines.push('');
  }

  if (breakdown.backlog.length > 0) {
    lines.push(`## Backlog (${breakdown.backlog.length})`);
    lines.push('Low priority - consider deprioritizing\n');
    for (const s of breakdown.backlog) {
      lines.push(`- **${s.pageSlug}**: ${truncate(s.original, 60)}`);
    }
  }

  return lines.join('\n');
}

function truncate(text: string, maxLength: number): string {
  if (text.length <= maxLength) return text;
  return text.slice(0, maxLength - 3) + '...';
}

/**
 * Format priority stats as text
 */
export function formatPriorityStats(stats: ReturnType<typeof calculatePriorityStats>): string {
  return `
Priority Statistics
-------------------
Total Suggestions: ${stats.total}
Average Priority: ${stats.avgPriority}
Quick Wins: ${stats.quickWinCount}
Estimated Hours: ${stats.estimatedHours}

By Impact:
  High: ${stats.byImpact.high}
  Medium: ${stats.byImpact.medium}
  Low: ${stats.byImpact.low}

By Effort:
  Quick: ${stats.byEffort.quick}
  Moderate: ${stats.byEffort.moderate}
  Significant: ${stats.byEffort.significant}
`.trim();
}
