/**
 * Scoring utilities for content analysis workers
 */

import type { ScoreCategory, Finding, AnalysisResult } from './types.js';

/**
 * Calculate weighted overall score from categories
 */
export function calculateOverallScore(categories: ScoreCategory[]): number {
  const totalWeight = categories.reduce((sum, cat) => sum + cat.weight, 0);
  if (totalWeight === 0) return 0;

  const weightedSum = categories.reduce((sum, cat) => {
    const normalizedScore = (cat.score / cat.maxScore) * 100;
    return sum + (normalizedScore * cat.weight);
  }, 0);

  return Math.round(weightedSum / totalWeight);
}

/**
 * Create a score category
 */
export function createCategory(
  name: string,
  score: number,
  maxScore: number,
  weight: number,
  details?: string
): ScoreCategory {
  return {
    name,
    score: Math.max(0, Math.min(score, maxScore)),
    maxScore,
    weight,
    details
  };
}

/**
 * Calculate category score from findings
 */
export function scoreFromFindings(
  findings: Finding[],
  categoryName: string,
  maxScore: number
): number {
  const categoryFindings = findings.filter(f => f.category === categoryName);

  let deductions = 0;
  for (const finding of categoryFindings) {
    switch (finding.severity) {
      case 'critical':
        deductions += 25;
        break;
      case 'warning':
        deductions += 10;
        break;
      case 'info':
        deductions += 2;
        break;
      case 'pass':
        // No deduction
        break;
    }
  }

  return Math.max(0, maxScore - deductions);
}

/**
 * Get score grade from percentage
 */
export function getGrade(score: number): string {
  if (score >= 90) return 'A';
  if (score >= 80) return 'B';
  if (score >= 70) return 'C';
  if (score >= 60) return 'D';
  return 'F';
}

/**
 * Get score label from percentage
 */
export function getScoreLabel(score: number): string {
  if (score >= 90) return 'Excellent';
  if (score >= 80) return 'Good';
  if (score >= 70) return 'Acceptable';
  if (score >= 60) return 'Needs Improvement';
  return 'Critical Issues';
}

/**
 * Count findings by severity
 */
export function countBySeverity(findings: Finding[]): Record<Finding['severity'], number> {
  return {
    critical: findings.filter(f => f.severity === 'critical').length,
    warning: findings.filter(f => f.severity === 'warning').length,
    info: findings.filter(f => f.severity === 'info').length,
    pass: findings.filter(f => f.severity === 'pass').length
  };
}

/**
 * Sort findings by severity (critical first)
 */
export function sortBySeverity(findings: Finding[]): Finding[] {
  const severityOrder: Record<Finding['severity'], number> = {
    critical: 0,
    warning: 1,
    info: 2,
    pass: 3
  };

  return [...findings].sort((a, b) =>
    severityOrder[a.severity] - severityOrder[b.severity]
  );
}

/**
 * Calculate percentage match
 */
export function calculateMatchPercentage(
  matches: number,
  total: number
): number {
  if (total === 0) return 100;
  return Math.round((matches / total) * 100);
}

/**
 * Normalize score to 0-100 range
 */
export function normalizeScore(score: number, min: number, max: number): number {
  if (max === min) return 100;
  const normalized = ((score - min) / (max - min)) * 100;
  return Math.round(Math.max(0, Math.min(100, normalized)));
}
