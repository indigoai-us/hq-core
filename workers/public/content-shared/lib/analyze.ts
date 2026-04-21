/**
 * Unified Content Analyzer
 * Entry point for running full page analysis across all dimensions
 */

import type {
  PageContent,
  AnalysisInput,
  AnalysisConfig,
  FullAnalysis,
  BrandAnalysis,
  ConversionAnalysis,
  AccuracyAnalysis,
  ComplianceAnalysis,
  Recommendation,
  BrandGuidelines,
  ProductData,
} from './types.js';
import { extractAnalysisInput } from './parser.js';
import { analyzeBrandVoice, DEFAULT_BRAND_GUIDELINES } from './brand-analyzer.js';
import { analyzeConversion } from './conversion-analyzer.js';
import { analyzeAccuracy, DEFAULT_PRODUCT_DATA } from './accuracy-analyzer.js';
import { analyzeCompliance } from './compliance-analyzer.js';

// ============================================
// Default Configuration
// ============================================

const DEFAULT_CONFIG: Required<AnalysisConfig> = {
  brandGuidelines: DEFAULT_BRAND_GUIDELINES,
  productData: DEFAULT_PRODUCT_DATA,
  enableBrand: true,
  enableConversion: true,
  enableAccuracy: true,
  enableCompliance: true,
};

// ============================================
// Main Analysis Functions
// ============================================

/**
 * Run full analysis on a single page
 */
export function analyzePageFull(
  page: PageContent,
  config: AnalysisConfig = {}
): FullAnalysis {
  const mergedConfig = { ...DEFAULT_CONFIG, ...config };
  const analysisInput = extractAnalysisInput(page);

  return runAnalysis(analysisInput, mergedConfig);
}

/**
 * Run full analysis on multiple pages
 */
export function analyzePages(
  pages: PageContent[],
  config: AnalysisConfig = {}
): FullAnalysis[] {
  return pages.map(page => analyzePageFull(page, config));
}

/**
 * Run full analysis on pre-extracted analysis input
 */
export function analyzeFromInput(
  input: AnalysisInput,
  config: AnalysisConfig = {}
): FullAnalysis {
  const mergedConfig = { ...DEFAULT_CONFIG, ...config };
  return runAnalysis(input, mergedConfig);
}

// ============================================
// Internal Analysis Runner
// ============================================

function runAnalysis(
  input: AnalysisInput,
  config: Required<AnalysisConfig>
): FullAnalysis {
  const timestamp = new Date().toISOString();

  // Run enabled analyzers
  let brand: BrandAnalysis | undefined;
  let conversion: ConversionAnalysis | undefined;
  let accuracy: AccuracyAnalysis | undefined;
  let compliance: ComplianceAnalysis | undefined;

  if (config.enableBrand) {
    brand = analyzeBrandVoice(input, config.brandGuidelines);
  }

  if (config.enableConversion) {
    conversion = analyzeConversion(input);
  }

  if (config.enableAccuracy) {
    accuracy = analyzeAccuracy(input, config.productData);
  }

  if (config.enableCompliance) {
    compliance = analyzeCompliance(input);
  }

  // Calculate overall health score
  const overallHealth = calculateOverallHealth(brand, conversion, accuracy, compliance);

  // Collect and prioritize recommendations
  const topPriorities = collectTopPriorities(brand, conversion, accuracy, compliance);

  return {
    page: input.pageSlug,
    timestamp,
    brand,
    conversion,
    accuracy,
    compliance,
    overallHealth,
    topPriorities,
  };
}

// ============================================
// Score Calculation
// ============================================

/**
 * Calculate overall health score from individual analyses
 */
function calculateOverallHealth(
  brand?: BrandAnalysis,
  conversion?: ConversionAnalysis,
  accuracy?: AccuracyAnalysis,
  compliance?: ComplianceAnalysis
): number {
  const scores: { score: number; weight: number }[] = [];

  if (brand) {
    scores.push({ score: brand.overallScore, weight: 0.25 });
  }

  if (conversion) {
    scores.push({ score: conversion.overallScore, weight: 0.30 });
  }

  if (accuracy) {
    scores.push({ score: accuracy.overallScore, weight: 0.20 });
  }

  if (compliance) {
    scores.push({ score: compliance.overallScore, weight: 0.25 });
  }

  if (scores.length === 0) {
    return 0;
  }

  // Normalize weights if not all analyzers ran
  const totalWeight = scores.reduce((sum, s) => sum + s.weight, 0);
  const weightedSum = scores.reduce((sum, s) => sum + (s.score * s.weight), 0);

  return Math.round(weightedSum / totalWeight);
}

/**
 * Collect and prioritize top recommendations across all analyses
 */
function collectTopPriorities(
  brand?: BrandAnalysis,
  conversion?: ConversionAnalysis,
  accuracy?: AccuracyAnalysis,
  compliance?: ComplianceAnalysis
): Recommendation[] {
  const allRecommendations: Recommendation[] = [];

  if (brand) {
    allRecommendations.push(...brand.recommendations);
  }

  if (conversion) {
    allRecommendations.push(...conversion.recommendations);
  }

  if (accuracy) {
    allRecommendations.push(...accuracy.recommendations);
  }

  if (compliance) {
    allRecommendations.push(...compliance.recommendations);
  }

  // Sort by priority
  const priorityOrder: Record<Recommendation['priority'], number> = {
    high: 0,
    medium: 1,
    low: 2,
  };

  allRecommendations.sort((a, b) =>
    priorityOrder[a.priority] - priorityOrder[b.priority]
  );

  // Return top recommendations (max 10)
  return allRecommendations.slice(0, 10);
}

// ============================================
// Utility Functions
// ============================================

/**
 * Create a quick summary from full analysis
 */
export function summarizeAnalysis(analysis: FullAnalysis): {
  page: string;
  health: number;
  grade: string;
  criticalIssues: number;
  warnings: number;
  topIssue: string | null;
} {
  const grade = getGrade(analysis.overallHealth);

  // Count issues across all findings
  let criticalIssues = 0;
  let warnings = 0;

  const allFindings = [
    ...(analysis.brand?.findings ?? []),
    ...(analysis.conversion?.findings ?? []),
    ...(analysis.accuracy?.findings ?? []),
    ...(analysis.compliance?.findings ?? []),
  ];

  for (const finding of allFindings) {
    if (finding.severity === 'critical') criticalIssues++;
    if (finding.severity === 'warning') warnings++;
  }

  const topIssue = analysis.topPriorities.length > 0
    ? analysis.topPriorities[0].current
    : null;

  return {
    page: analysis.page,
    health: analysis.overallHealth,
    grade,
    criticalIssues,
    warnings,
    topIssue,
  };
}

/**
 * Get letter grade from score
 */
function getGrade(score: number): string {
  if (score >= 90) return 'A';
  if (score >= 80) return 'B';
  if (score >= 70) return 'C';
  if (score >= 60) return 'D';
  return 'F';
}

/**
 * Compare two analyses to show improvements/regressions
 */
export function compareAnalyses(
  before: FullAnalysis,
  after: FullAnalysis
): {
  healthDelta: number;
  brandDelta: number;
  conversionDelta: number;
  accuracyDelta: number;
  complianceDelta: number;
  improved: string[];
  regressed: string[];
} {
  const healthDelta = after.overallHealth - before.overallHealth;
  const brandDelta = (after.brand?.overallScore ?? 0) - (before.brand?.overallScore ?? 0);
  const conversionDelta = (after.conversion?.overallScore ?? 0) - (before.conversion?.overallScore ?? 0);
  const accuracyDelta = (after.accuracy?.overallScore ?? 0) - (before.accuracy?.overallScore ?? 0);
  const complianceDelta = (after.compliance?.overallScore ?? 0) - (before.compliance?.overallScore ?? 0);

  const improved: string[] = [];
  const regressed: string[] = [];

  if (brandDelta > 5) improved.push('Brand Voice');
  else if (brandDelta < -5) regressed.push('Brand Voice');

  if (conversionDelta > 5) improved.push('Conversion');
  else if (conversionDelta < -5) regressed.push('Conversion');

  if (accuracyDelta > 5) improved.push('Accuracy');
  else if (accuracyDelta < -5) regressed.push('Accuracy');

  if (complianceDelta > 5) improved.push('Compliance');
  else if (complianceDelta < -5) regressed.push('Compliance');

  return {
    healthDelta,
    brandDelta,
    conversionDelta,
    accuracyDelta,
    complianceDelta,
    improved,
    regressed,
  };
}

/**
 * Generate action items from analysis
 */
export function generateActionItems(
  analysis: FullAnalysis,
  maxItems: number = 5
): Array<{
  priority: 'high' | 'medium' | 'low';
  area: string;
  action: string;
  impact: string;
}> {
  const items: Array<{
    priority: 'high' | 'medium' | 'low';
    area: string;
    action: string;
    impact: string;
  }> = [];

  for (const rec of analysis.topPriorities.slice(0, maxItems)) {
    items.push({
      priority: rec.priority,
      area: rec.category,
      action: rec.suggested,
      impact: rec.rationale,
    });
  }

  return items;
}

// ============================================
// Exports for Convenience
// ============================================

export {
  analyzeBrandVoice,
  analyzeConversion,
  analyzeAccuracy,
  analyzeCompliance,
  extractAnalysisInput,
  DEFAULT_BRAND_GUIDELINES,
  DEFAULT_PRODUCT_DATA,
};

export type {
  FullAnalysis,
  BrandAnalysis,
  ConversionAnalysis,
  AccuracyAnalysis,
  ComplianceAnalysis,
  AnalysisConfig,
  AnalysisInput,
  BrandGuidelines,
  ProductData,
};
