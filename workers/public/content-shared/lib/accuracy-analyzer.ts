/**
 * Technical Accuracy Analyzer (US-009)
 * Verifies product claims and features against known product data
 */

import type {
  AnalysisInput,
  ProductData,
  AccuracyAnalysis,
  Finding,
  Recommendation,
} from './types.js';

// ============================================
// Default Product Data Template
// ============================================

export const DEFAULT_PRODUCT_DATA: ProductData = {
  productName: 'Product',
  features: [],
  stats: {},
  certifications: [],
  integrations: [],
  lastUpdated: new Date().toISOString(),
};

// ============================================
// Scoring Weights
// ============================================

const WEIGHTS = {
  claimsVerification: 0.40,
  statsAccuracy: 0.35,
  featureConsistency: 0.25,
};

// ============================================
// Main Analysis Function
// ============================================

/**
 * Analyze content for technical accuracy against known product data
 */
export function analyzeAccuracy(
  content: AnalysisInput,
  productData: ProductData = DEFAULT_PRODUCT_DATA
): AccuracyAnalysis {
  const findings: Finding[] = [];
  const recommendations: Recommendation[] = [];

  // Verify claims
  const claimsResult = verifyClaims(content, productData, findings, recommendations);

  // Check stats accuracy
  const statsResult = checkStatsAccuracy(content, productData, findings, recommendations);

  // Check feature consistency
  const featureResult = checkFeatureConsistency(content, productData, findings, recommendations);

  // Calculate overall score
  const overallScore = Math.round(
    claimsResult.score * WEIGHTS.claimsVerification +
    statsResult.score * WEIGHTS.statsAccuracy +
    featureResult.score * WEIGHTS.featureConsistency
  );

  return {
    overallScore,
    claimsVerified: claimsResult.verified,
    claimsUnverified: claimsResult.unverified,
    statsFound: statsResult.found,
    statsOutdated: statsResult.outdated,
    findings,
    recommendations,
  };
}

// ============================================
// Claims Verification
// ============================================

interface ClaimsResult {
  score: number;
  verified: number;
  unverified: number;
}

function verifyClaims(
  content: AnalysisInput,
  productData: ProductData,
  findings: Finding[],
  recommendations: Recommendation[]
): ClaimsResult {
  let verified = 0;
  let unverified = 0;

  if (content.claims.length === 0) {
    findings.push({
      severity: 'info',
      category: 'Accuracy - Claims',
      message: 'No verifiable claims detected in content',
    });
    return { score: 100, verified: 0, unverified: 0 };
  }

  // Categorize claims
  const claimCategories = categorizeClaims(content.claims);

  // Check superlative claims (highest risk)
  for (const claim of claimCategories.superlatives) {
    const isSubstantiated = checkSuperlativeClaim(claim, productData);
    if (isSubstantiated) {
      verified++;
      findings.push({
        severity: 'pass',
        category: 'Accuracy - Claims',
        message: 'Superlative claim may be supported by data',
        evidence: truncate(claim, 100),
      });
    } else {
      unverified++;
      findings.push({
        severity: 'warning',
        category: 'Accuracy - Claims',
        message: 'Superlative claim lacks verification',
        evidence: truncate(claim, 100),
      });
      recommendations.push({
        priority: 'high',
        category: 'Claims',
        current: truncate(claim, 80),
        suggested: 'Add supporting data or soften to "one of the leading" or similar',
        rationale: 'Unsubstantiated superlatives can damage credibility and raise legal concerns',
      });
    }
  }

  // Check quantitative claims
  for (const claim of claimCategories.quantitative) {
    const isVerifiable = checkQuantitativeClaim(claim, productData);
    if (isVerifiable.verified) {
      verified++;
      findings.push({
        severity: 'pass',
        category: 'Accuracy - Claims',
        message: 'Quantitative claim appears verifiable',
        evidence: truncate(claim, 100),
      });
    } else {
      unverified++;
      findings.push({
        severity: isVerifiable.severity,
        category: 'Accuracy - Claims',
        message: isVerifiable.reason,
        evidence: truncate(claim, 100),
      });
      if (isVerifiable.suggestion) {
        recommendations.push({
          priority: 'medium',
          category: 'Claims',
          current: truncate(claim, 80),
          suggested: isVerifiable.suggestion,
          rationale: 'Quantitative claims should be verifiable and up-to-date',
        });
      }
    }
  }

  // Check certification/compliance claims
  for (const claim of claimCategories.certifications) {
    const certFound = productData.certifications.some(cert =>
      claim.toLowerCase().includes(cert.toLowerCase())
    );
    if (certFound) {
      verified++;
      findings.push({
        severity: 'pass',
        category: 'Accuracy - Claims',
        message: 'Certification claim matches known certifications',
        evidence: truncate(claim, 100),
      });
    } else {
      unverified++;
      findings.push({
        severity: 'warning',
        category: 'Accuracy - Claims',
        message: 'Certification claim not found in product data',
        evidence: truncate(claim, 100),
      });
      recommendations.push({
        priority: 'high',
        category: 'Claims',
        current: truncate(claim, 80),
        suggested: 'Verify certification status and update product data',
        rationale: 'False certification claims can have serious legal consequences',
      });
    }
  }

  // Count general claims (lower priority)
  verified += claimCategories.general.length;

  const total = verified + unverified;
  const verificationRate = total > 0 ? verified / total : 1;
  const score = Math.round(verificationRate * 100);

  return { score, verified, unverified };
}

// ============================================
// Stats Accuracy Check
// ============================================

interface StatsResult {
  score: number;
  found: number;
  outdated: number;
}

function checkStatsAccuracy(
  content: AnalysisInput,
  productData: ProductData,
  findings: Finding[],
  recommendations: Recommendation[]
): StatsResult {
  let found = content.stats.length;
  let outdated = 0;
  let score = 100;

  if (content.stats.length === 0) {
    findings.push({
      severity: 'info',
      category: 'Accuracy - Statistics',
      message: 'No statistics found in content',
    });
    return { score: 100, found: 0, outdated: 0 };
  }

  // Check stats against known product data
  for (const stat of content.stats) {
    const validity = checkStatValidity(stat.value, productData.stats);

    if (validity.status === 'verified') {
      findings.push({
        severity: 'pass',
        category: 'Accuracy - Statistics',
        message: `Statistic verified: ${stat.value}`,
        evidence: stat.label,
      });
    } else if (validity.status === 'outdated') {
      outdated++;
      findings.push({
        severity: 'warning',
        category: 'Accuracy - Statistics',
        message: `Statistic may be outdated: ${stat.value}`,
        evidence: `Current value: ${validity.currentValue}`,
      });
      score -= 15;
      recommendations.push({
        priority: 'high',
        category: 'Statistics',
        current: `${stat.value} (${stat.label})`,
        suggested: `Update to ${validity.currentValue}`,
        rationale: 'Outdated statistics undermine credibility',
      });
    } else if (validity.status === 'unverified') {
      findings.push({
        severity: 'info',
        category: 'Accuracy - Statistics',
        message: `Statistic not in known data: ${stat.value}`,
        evidence: stat.label,
      });
      // Minor deduction for unverified stats
      score -= 5;
    }
  }

  // Check for stale data indicators
  const lastUpdated = new Date(productData.lastUpdated);
  const monthsOld = (Date.now() - lastUpdated.getTime()) / (1000 * 60 * 60 * 24 * 30);

  if (monthsOld > 6) {
    findings.push({
      severity: 'warning',
      category: 'Accuracy - Statistics',
      message: `Product data is ${Math.round(monthsOld)} months old`,
    });
    score -= 10;
    recommendations.push({
      priority: 'medium',
      category: 'Statistics',
      current: `Product data last updated ${Math.round(monthsOld)} months ago`,
      suggested: 'Review and update product statistics',
      rationale: 'Regular data updates ensure accuracy',
    });
  }

  // Check for missing source attribution
  const statsWithoutSource = content.stats.filter(s =>
    !s.label.toLowerCase().includes('source') &&
    !s.label.toLowerCase().includes('study') &&
    !s.label.toLowerCase().includes('report')
  );

  if (statsWithoutSource.length > content.stats.length * 0.5) {
    findings.push({
      severity: 'info',
      category: 'Accuracy - Statistics',
      message: 'Most statistics lack source attribution',
    });
    recommendations.push({
      priority: 'low',
      category: 'Statistics',
      current: 'Statistics without sources',
      suggested: 'Add source attribution for third-party statistics',
      rationale: 'Cited sources increase credibility',
    });
  }

  return { score: Math.max(0, score), found, outdated };
}

/**
 * Check if a statistic is valid against known product stats
 */
export function checkStatValidity(
  stat: string,
  knownStats: Record<string, string>
): { status: 'verified' | 'outdated' | 'unverified'; currentValue?: string } {
  // Extract numeric value from stat
  const numericMatch = stat.match(/[\d,.]+/);
  if (!numericMatch) {
    return { status: 'unverified' };
  }

  const statValue = numericMatch[0];

  // Check against known stats
  for (const [key, knownValue] of Object.entries(knownStats)) {
    // Check if the stat matches this category
    if (stat.toLowerCase().includes(key.toLowerCase())) {
      if (knownValue === statValue || knownValue.includes(statValue)) {
        return { status: 'verified' };
      } else {
        return { status: 'outdated', currentValue: knownValue };
      }
    }
  }

  return { status: 'unverified' };
}

// ============================================
// Feature Consistency Check
// ============================================

interface FeatureResult {
  score: number;
}

function checkFeatureConsistency(
  content: AnalysisInput,
  productData: ProductData,
  findings: Finding[],
  recommendations: Recommendation[]
): FeatureResult {
  let score = 100;

  if (productData.features.length === 0) {
    findings.push({
      severity: 'info',
      category: 'Accuracy - Features',
      message: 'No product features defined for verification',
    });
    return { score: 100 };
  }

  const allText = [
    content.title,
    ...content.headings,
    ...content.paragraphs,
  ].join(' ').toLowerCase();

  // Check for mentioned features
  const mentionedFeatures: string[] = [];
  const unmentionedFeatures: string[] = [];

  for (const feature of productData.features) {
    // Create variations of the feature name for matching
    const variations = [
      feature.toLowerCase(),
      feature.toLowerCase().replace(/-/g, ' '),
      feature.toLowerCase().replace(/_/g, ' '),
    ];

    const isMentioned = variations.some(v => allText.includes(v));

    if (isMentioned) {
      mentionedFeatures.push(feature);
    } else {
      unmentionedFeatures.push(feature);
    }
  }

  // Report findings
  const coverage = mentionedFeatures.length / productData.features.length;

  if (coverage >= 0.7) {
    findings.push({
      severity: 'pass',
      category: 'Accuracy - Features',
      message: `Good feature coverage: ${Math.round(coverage * 100)}%`,
      evidence: `${mentionedFeatures.length}/${productData.features.length} features mentioned`,
    });
  } else if (coverage >= 0.4) {
    findings.push({
      severity: 'info',
      category: 'Accuracy - Features',
      message: `Moderate feature coverage: ${Math.round(coverage * 100)}%`,
      evidence: `Missing: ${unmentionedFeatures.slice(0, 3).join(', ')}`,
    });
    score -= 15;
  } else {
    findings.push({
      severity: 'warning',
      category: 'Accuracy - Features',
      message: `Low feature coverage: ${Math.round(coverage * 100)}%`,
      evidence: `Many key features not mentioned`,
    });
    score -= 30;
    recommendations.push({
      priority: 'medium',
      category: 'Features',
      current: `Only ${mentionedFeatures.length} of ${productData.features.length} features mentioned`,
      suggested: `Consider adding content about: ${unmentionedFeatures.slice(0, 3).join(', ')}`,
      rationale: 'Comprehensive feature coverage improves page value',
    });
  }

  // Check for potentially incorrect feature claims
  const featureClaims = extractFeatureClaims(content);
  const invalidClaims = featureClaims.filter(claim => {
    const normalized = claim.toLowerCase();
    return !productData.features.some(f =>
      normalized.includes(f.toLowerCase()) ||
      f.toLowerCase().includes(normalized)
    ) && !productData.integrations.some(i =>
      normalized.includes(i.toLowerCase())
    );
  });

  if (invalidClaims.length > 0) {
    findings.push({
      severity: 'warning',
      category: 'Accuracy - Features',
      message: `${invalidClaims.length} feature claim(s) not in product data`,
      evidence: invalidClaims.slice(0, 2).join('; '),
    });
    score -= invalidClaims.length * 5;
    recommendations.push({
      priority: 'medium',
      category: 'Features',
      current: `Claims about: ${invalidClaims.slice(0, 2).join(', ')}`,
      suggested: 'Verify these features exist or update product data',
      rationale: 'Feature claims should match actual product capabilities',
    });
  }

  // Check integrations mentions
  if (productData.integrations.length > 0) {
    const integrationsMatch = productData.integrations.filter(integration =>
      allText.includes(integration.toLowerCase())
    );

    if (integrationsMatch.length > 0) {
      findings.push({
        severity: 'pass',
        category: 'Accuracy - Features',
        message: `Integrations mentioned: ${integrationsMatch.length}`,
        evidence: integrationsMatch.slice(0, 5).join(', '),
      });
    }
  }

  return { score: Math.max(0, score) };
}

// ============================================
// Helper Functions
// ============================================

interface CategorizedClaims {
  superlatives: string[];
  quantitative: string[];
  certifications: string[];
  general: string[];
}

/**
 * Categorize claims by type
 */
function categorizeClaims(claims: string[]): CategorizedClaims {
  const result: CategorizedClaims = {
    superlatives: [],
    quantitative: [],
    certifications: [],
    general: [],
  };

  const superlativePatterns = [
    /\b(best|leading|top|#1|number one|premier|fastest|only|first|most|largest)\b/i,
    /\b(award-winning|industry-leading|world-class|best-in-class)\b/i,
  ];

  const quantitativePatterns = [
    /\d+(?:\.\d+)?%/,
    /\$[\d,]+/,
    /\d+x/i,
    /\d+(?:,\d{3})+/,
  ];

  const certificationPatterns = [
    /\b(SOC\s*2|HIPAA|GDPR|ISO\s*\d+|PCI|FedRAMP|CCPA)\b/i,
    /\b(certified|compliant|accredited)\b/i,
  ];

  for (const claim of claims) {
    if (superlativePatterns.some(p => p.test(claim))) {
      result.superlatives.push(claim);
    } else if (quantitativePatterns.some(p => p.test(claim))) {
      result.quantitative.push(claim);
    } else if (certificationPatterns.some(p => p.test(claim))) {
      result.certifications.push(claim);
    } else {
      result.general.push(claim);
    }
  }

  return result;
}

/**
 * Check if a superlative claim is substantiated
 */
function checkSuperlativeClaim(claim: string, productData: ProductData): boolean {
  // Check if there's supporting data for the claim
  const claimLower = claim.toLowerCase();

  // If we have relevant stats, it might be substantiated
  for (const [key, value] of Object.entries(productData.stats)) {
    if (claimLower.includes(key.toLowerCase())) {
      return true;
    }
  }

  // Check certifications
  for (const cert of productData.certifications) {
    if (claimLower.includes(cert.toLowerCase())) {
      return true;
    }
  }

  return false;
}

interface QuantitativeCheckResult {
  verified: boolean;
  severity: 'warning' | 'info';
  reason: string;
  suggestion?: string;
}

/**
 * Check if a quantitative claim is verifiable
 */
function checkQuantitativeClaim(
  claim: string,
  productData: ProductData
): QuantitativeCheckResult {
  // Extract the number from the claim
  const numbers = claim.match(/[\d,.]+(?:%|x|K|M|B)?/gi);

  if (!numbers || numbers.length === 0) {
    return {
      verified: false,
      severity: 'info',
      reason: 'No quantitative value found in claim',
    };
  }

  // Check against known stats
  for (const [key, value] of Object.entries(productData.stats)) {
    if (claim.toLowerCase().includes(key.toLowerCase())) {
      // Check if values match
      if (numbers.some(n => value.includes(n) || n.includes(value.replace(/[^\d.]/g, '')))) {
        return { verified: true, severity: 'info', reason: 'Verified' };
      } else {
        return {
          verified: false,
          severity: 'warning',
          reason: `Value ${numbers[0]} doesn't match known value: ${value}`,
          suggestion: `Update to current value: ${value}`,
        };
      }
    }
  }

  // Check if it's a round number (potentially fabricated)
  const roundNumberPattern = /^(10|25|50|100|1000)0*$/;
  if (numbers.some(n => roundNumberPattern.test(n.replace(/[^0-9]/g, '')))) {
    return {
      verified: false,
      severity: 'info',
      reason: 'Round number may appear less credible',
      suggestion: 'Use specific numbers when available for more credibility',
    };
  }

  return {
    verified: false,
    severity: 'info',
    reason: 'Quantitative claim not found in product data',
  };
}

/**
 * Extract feature-related claims from content
 */
function extractFeatureClaims(content: AnalysisInput): string[] {
  const featureClaims: string[] = [];

  // Look for "integrates with", "supports", "works with", etc.
  const featurePatterns = [
    /integrates?\s+with\s+([^.]+)/gi,
    /supports?\s+([^.]+)/gi,
    /works?\s+with\s+([^.]+)/gi,
    /compatible\s+with\s+([^.]+)/gi,
    /connects?\s+to\s+([^.]+)/gi,
  ];

  const allText = content.paragraphs.join(' ');

  for (const pattern of featurePatterns) {
    const matches = allText.matchAll(pattern);
    for (const match of matches) {
      if (match[1] && match[1].length < 100) {
        featureClaims.push(match[1].trim());
      }
    }
  }

  return featureClaims;
}

/**
 * Truncate string with ellipsis
 */
function truncate(str: string, maxLength: number): string {
  if (str.length <= maxLength) return str;
  return str.slice(0, maxLength - 3) + '...';
}
