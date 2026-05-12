/**
 * Regulatory Compliance Analyzer (US-010)
 * Checks content for compliance issues, regulated terms, and missing disclaimers
 */

import type {
  AnalysisInput,
  ComplianceAnalysis,
  RegulatedTerm,
  Finding,
  Recommendation,
} from './types.js';

// ============================================
// Regulated Terms Database
// ============================================

/**
 * Terms that require proof, disclaimers, or carry legal risk
 */
export const REGULATED_TERMS: Array<{
  term: string;
  patterns: RegExp[];
  requiresProof: boolean;
  disclaimer?: string;
  risk: 'high' | 'medium' | 'low';
  category: string;
  alternative?: string;
}> = [
  // Compliance/Security Claims
  {
    term: 'SOC 2',
    patterns: [/\bSOC\s*2\b/gi, /\bSOC\s*II\b/gi, /\bSOC2\b/gi],
    requiresProof: true,
    disclaimer: 'SOC 2 Type I/II certification details available upon request',
    risk: 'high',
    category: 'Compliance',
  },
  {
    term: 'HIPAA',
    patterns: [/\bHIPAA\b/gi],
    requiresProof: true,
    disclaimer: 'HIPAA compliance applies when used with covered entities under a BAA',
    risk: 'high',
    category: 'Compliance',
  },
  {
    term: 'GDPR',
    patterns: [/\bGDPR\b/gi],
    requiresProof: true,
    disclaimer: 'GDPR compliance details available in our Data Processing Agreement',
    risk: 'high',
    category: 'Compliance',
  },
  {
    term: 'PCI DSS',
    patterns: [/\bPCI\s*(?:DSS)?\b/gi, /\bPCI\s*compliant\b/gi],
    requiresProof: true,
    disclaimer: 'PCI DSS compliance level documentation available upon request',
    risk: 'high',
    category: 'Compliance',
  },
  {
    term: 'ISO 27001',
    patterns: [/\bISO\s*27001\b/gi, /\bISO\s*certification\b/gi],
    requiresProof: true,
    disclaimer: 'ISO 27001 certification documentation available upon request',
    risk: 'high',
    category: 'Compliance',
  },
  {
    term: 'FedRAMP',
    patterns: [/\bFedRAMP\b/gi],
    requiresProof: true,
    disclaimer: 'FedRAMP authorization status available on marketplace.fedramp.gov',
    risk: 'high',
    category: 'Compliance',
  },
  {
    term: 'CCPA',
    patterns: [/\bCCPA\b/gi],
    requiresProof: true,
    disclaimer: 'CCPA compliance details available in our Privacy Policy',
    risk: 'medium',
    category: 'Compliance',
  },

  // Absolute Claims
  {
    term: 'guaranteed',
    patterns: [/\bguarantee[ds]?\b/gi, /\bguaranty\b/gi],
    requiresProof: false,
    risk: 'high',
    category: 'Claims',
    alternative: 'designed to help',
    disclaimer: 'Results may vary. See terms for guarantee conditions.',
  },
  {
    term: '100%',
    patterns: [/\b100\s*%/gi, /\bhundred\s*percent\b/gi],
    requiresProof: false,
    risk: 'high',
    category: 'Claims',
    alternative: 'up to 100%',
  },
  {
    term: 'always',
    patterns: [/\balways\b/gi],
    requiresProof: false,
    risk: 'medium',
    category: 'Claims',
    alternative: 'consistently',
  },
  {
    term: 'never',
    patterns: [/\bnever\b/gi],
    requiresProof: false,
    risk: 'medium',
    category: 'Claims',
    alternative: 'designed to prevent',
  },
  {
    term: 'zero',
    patterns: [/\bzero\s+(?:downtime|errors?|bugs?|issues?|risk)\b/gi],
    requiresProof: false,
    risk: 'medium',
    category: 'Claims',
    alternative: 'minimal',
  },
  {
    term: 'unlimited',
    patterns: [/\bunlimited\b/gi],
    requiresProof: false,
    risk: 'medium',
    category: 'Claims',
    disclaimer: 'Subject to fair use policy',
  },

  // Superlative Claims
  {
    term: 'best',
    patterns: [/\bbest\b/gi, /\b#1\b/gi, /\bnumber\s*one\b/gi],
    requiresProof: true,
    risk: 'medium',
    category: 'Claims',
    alternative: 'leading',
  },
  {
    term: 'only',
    patterns: [/\bonly\s+(?:solution|platform|provider|option)\b/gi],
    requiresProof: true,
    risk: 'medium',
    category: 'Claims',
    alternative: 'one of few',
  },
  {
    term: 'fastest',
    patterns: [/\bfastest\b/gi],
    requiresProof: true,
    risk: 'medium',
    category: 'Claims',
    alternative: 'fast',
  },
  {
    term: 'most',
    patterns: [/\bmost\s+(?:trusted|secure|reliable|advanced|popular)\b/gi],
    requiresProof: true,
    risk: 'medium',
    category: 'Claims',
    alternative: 'highly',
  },

  // Financial/ROI Claims
  {
    term: 'ROI',
    patterns: [/\bROI\b/gi, /\breturn\s+on\s+investment\b/gi],
    requiresProof: true,
    risk: 'medium',
    category: 'Financial',
    disclaimer: 'Individual results may vary based on implementation',
  },
  {
    term: 'save money',
    patterns: [/\bsave\s+\$[\d,]+/gi, /\bsave\s+\d+%/gi, /\bcost\s+savings?\b/gi],
    requiresProof: true,
    risk: 'medium',
    category: 'Financial',
    disclaimer: 'Savings based on average customer data',
  },

  // Industry-Specific
  {
    term: 'medical',
    patterns: [/\bmedical\s*(?:grade|device|approved)\b/gi],
    requiresProof: true,
    risk: 'high',
    category: 'Industry',
    disclaimer: 'For informational purposes only. Not a medical device.',
  },
  {
    term: 'FDA',
    patterns: [/\bFDA\s*(?:approved|cleared|registered)\b/gi],
    requiresProof: true,
    risk: 'high',
    category: 'Industry',
  },
  {
    term: 'bank-level',
    patterns: [/\bbank[-\s]*level\b/gi, /\bbanking[-\s]*grade\b/gi],
    requiresProof: false,
    risk: 'low',
    category: 'Security',
    disclaimer: 'Refers to AES-256 encryption standard',
  },
];

// ============================================
// Required Disclaimers by Context
// ============================================

const CONTEXT_DISCLAIMERS: Record<string, { patterns: RegExp[]; disclaimer: string }> = {
  testimonials: {
    patterns: [/testimonial/gi, /customer\s+(?:story|review|quote)/gi],
    disclaimer: 'Individual results may vary',
  },
  pricing: {
    patterns: [/pricing/gi, /\$/gi, /cost/gi, /fee/gi],
    disclaimer: 'Pricing subject to change. Additional fees may apply.',
  },
  trials: {
    patterns: [/free\s+trial/gi, /try\s+free/gi, /\d+[-\s]*day\s+trial/gi],
    disclaimer: 'Credit card may be required. Cancel anytime.',
  },
  results: {
    patterns: [/result[s]?/gi, /outcome[s]?/gi, /case\s+study/gi],
    disclaimer: 'Results shown are representative examples. Individual results may vary.',
  },
};

// ============================================
// Scoring Weights
// ============================================

const WEIGHTS = {
  regulatedTerms: 0.40,
  disclaimers: 0.30,
  substantiation: 0.30,
};

// ============================================
// Main Analysis Function
// ============================================

/**
 * Analyze content for regulatory compliance issues
 */
export function analyzeCompliance(content: AnalysisInput): ComplianceAnalysis {
  const findings: Finding[] = [];
  const recommendations: Recommendation[] = [];
  const regulatedTermsFound: RegulatedTerm[] = [];
  const missingDisclaimers: string[] = [];
  const unsubstantiatedClaims: string[] = [];

  // Check regulated terms
  const termsResult = checkRegulatedTerms(
    content,
    findings,
    recommendations,
    regulatedTermsFound
  );

  // Check disclaimers
  const disclaimerResult = checkDisclaimers(
    content,
    findings,
    recommendations,
    missingDisclaimers
  );

  // Check claim substantiation
  const substantiationResult = checkSubstantiation(
    content,
    findings,
    recommendations,
    unsubstantiatedClaims
  );

  // Calculate overall score
  const overallScore = Math.round(
    termsResult.score * WEIGHTS.regulatedTerms +
    disclaimerResult.score * WEIGHTS.disclaimers +
    substantiationResult.score * WEIGHTS.substantiation
  );

  return {
    overallScore,
    regulatedTermsFound,
    missingDisclaimers,
    unsubstantiatedClaims,
    findings,
    recommendations,
  };
}

// ============================================
// Regulated Terms Check
// ============================================

interface TermsResult {
  score: number;
}

function checkRegulatedTerms(
  content: AnalysisInput,
  findings: Finding[],
  recommendations: Recommendation[],
  regulatedTermsFound: RegulatedTerm[]
): TermsResult {
  let score = 100;
  const allText = getAllText(content);

  for (const termDef of REGULATED_TERMS) {
    for (const pattern of termDef.patterns) {
      const matches = allText.matchAll(pattern);
      const matchArray = [...matches];

      if (matchArray.length > 0) {
        // Find location of match
        const location = findTermLocation(content, pattern);

        const regulatedTerm: RegulatedTerm = {
          term: termDef.term,
          location,
          requiresProof: termDef.requiresProof,
          hasProof: false, // Would need external verification
          disclaimer: termDef.disclaimer,
          risk: termDef.risk,
        };

        regulatedTermsFound.push(regulatedTerm);

        // Score based on risk level
        const riskPenalty = termDef.risk === 'high' ? 15 : termDef.risk === 'medium' ? 8 : 3;

        if (termDef.requiresProof) {
          findings.push({
            severity: termDef.risk === 'high' ? 'warning' : 'info',
            category: `Compliance - ${termDef.category}`,
            message: `Regulated term "${termDef.term}" requires substantiation`,
            location,
            evidence: matchArray[0][0],
          });
          score -= riskPenalty;

          if (termDef.disclaimer) {
            recommendations.push({
              priority: termDef.risk === 'high' ? 'high' : 'medium',
              category: 'Compliance',
              current: `Uses "${termDef.term}" without disclaimer`,
              suggested: `Add disclaimer: "${termDef.disclaimer}"`,
              rationale: 'Regulated claims require proper disclaimers',
            });
          }
        }

        if (termDef.alternative) {
          recommendations.push({
            priority: termDef.risk === 'high' ? 'high' : 'medium',
            category: 'Compliance',
            current: `Uses "${termDef.term}"`,
            suggested: `Consider using "${termDef.alternative}" instead`,
            rationale: 'Reduces legal risk while maintaining message',
          });
        }

        break; // Only count each term once
      }
    }
  }

  // Report summary
  const highRiskCount = regulatedTermsFound.filter(t => t.risk === 'high').length;
  const mediumRiskCount = regulatedTermsFound.filter(t => t.risk === 'medium').length;

  if (highRiskCount > 0) {
    findings.push({
      severity: 'warning',
      category: 'Compliance Summary',
      message: `Found ${highRiskCount} high-risk regulated term(s)`,
    });
  }

  if (mediumRiskCount > 0) {
    findings.push({
      severity: 'info',
      category: 'Compliance Summary',
      message: `Found ${mediumRiskCount} medium-risk regulated term(s)`,
    });
  }

  if (regulatedTermsFound.length === 0) {
    findings.push({
      severity: 'pass',
      category: 'Compliance Summary',
      message: 'No high-risk regulated terms found',
    });
  }

  return { score: Math.max(0, score) };
}

// ============================================
// Disclaimer Check
// ============================================

interface DisclaimerResult {
  score: number;
}

function checkDisclaimers(
  content: AnalysisInput,
  findings: Finding[],
  recommendations: Recommendation[],
  missingDisclaimers: string[]
): DisclaimerResult {
  let score = 100;
  const allText = getAllText(content).toLowerCase();

  // Check for context-specific disclaimers
  for (const [context, config] of Object.entries(CONTEXT_DISCLAIMERS)) {
    const hasContext = config.patterns.some(pattern => pattern.test(allText));

    if (hasContext) {
      // Check if corresponding disclaimer exists
      const hasDisclaimer = allText.includes('results may vary') ||
        allText.includes('individual results') ||
        allText.includes('subject to') ||
        allText.includes('terms apply') ||
        allText.includes('disclaimer');

      if (!hasDisclaimer) {
        missingDisclaimers.push(config.disclaimer);
        findings.push({
          severity: 'info',
          category: 'Compliance - Disclaimers',
          message: `${context.charAt(0).toUpperCase() + context.slice(1)} content may need disclaimer`,
        });
        score -= 10;
        recommendations.push({
          priority: 'medium',
          category: 'Disclaimers',
          current: `${context} content without disclaimer`,
          suggested: `Add: "${config.disclaimer}"`,
          rationale: 'Disclaimers protect against legal claims',
        });
      }
    }
  }

  // Check for financial projections
  const financialPatterns = [
    /\bwill\s+save\b/gi,
    /\bwill\s+(?:increase|boost|grow)\b/gi,
    /\bexpect\s+to\b/gi,
  ];

  const hasFinancialProjections = financialPatterns.some(pattern => pattern.test(allText));
  if (hasFinancialProjections) {
    const hasForwardDisclaimer = allText.includes('forward-looking') ||
      allText.includes('no guarantee') ||
      allText.includes('may vary');

    if (!hasForwardDisclaimer) {
      missingDisclaimers.push('Projections are estimates and actual results may vary');
      findings.push({
        severity: 'warning',
        category: 'Compliance - Disclaimers',
        message: 'Financial projections may need disclaimer',
      });
      score -= 15;
      recommendations.push({
        priority: 'high',
        category: 'Disclaimers',
        current: 'Financial projections without disclaimer',
        suggested: 'Add: "Projections are estimates and actual results may vary"',
        rationale: 'Forward-looking statements require appropriate disclaimers',
      });
    }
  }

  // Report findings
  if (missingDisclaimers.length === 0) {
    findings.push({
      severity: 'pass',
      category: 'Compliance - Disclaimers',
      message: 'No obvious missing disclaimers detected',
    });
  }

  return { score: Math.max(0, score) };
}

// ============================================
// Claim Substantiation Check
// ============================================

interface SubstantiationResult {
  score: number;
}

function checkSubstantiation(
  content: AnalysisInput,
  findings: Finding[],
  recommendations: Recommendation[],
  unsubstantiatedClaims: string[]
): SubstantiationResult {
  let score = 100;

  // Check claims for substantiation
  for (const claim of content.claims) {
    const claimLower = claim.toLowerCase();

    // Check if claim has supporting evidence patterns
    const hasEvidence =
      /\bstudy\b/i.test(claim) ||
      /\bresearch\b/i.test(claim) ||
      /\bdata\b/i.test(claim) ||
      /\bsurvey\b/i.test(claim) ||
      /\breport\b/i.test(claim) ||
      /according to/i.test(claim) ||
      /based on/i.test(claim);

    // Check if it's a risky claim type
    const isRiskyClaim =
      /\b(always|never|guaranteed|100%|best|only|most|fastest)\b/i.test(claimLower);

    if (isRiskyClaim && !hasEvidence) {
      unsubstantiatedClaims.push(claim);
      findings.push({
        severity: 'warning',
        category: 'Compliance - Substantiation',
        message: 'Claim may need substantiation',
        evidence: truncate(claim, 100),
      });
      score -= 10;
    }
  }

  // Check stats for sources
  const statsWithoutSources = content.stats.filter(stat => {
    const labelLower = stat.label.toLowerCase();
    return !labelLower.includes('source') &&
      !labelLower.includes('based on') &&
      !labelLower.includes('according') &&
      !labelLower.includes('study') &&
      !labelLower.includes('report');
  });

  if (statsWithoutSources.length > 0 && content.stats.length > 0) {
    const percentage = Math.round((statsWithoutSources.length / content.stats.length) * 100);
    if (percentage > 50) {
      findings.push({
        severity: 'info',
        category: 'Compliance - Substantiation',
        message: `${percentage}% of statistics lack source attribution`,
      });
      score -= 5;
      recommendations.push({
        priority: 'low',
        category: 'Substantiation',
        current: 'Statistics without sources',
        suggested: 'Add source attribution for third-party statistics',
        rationale: 'Sourced statistics are more defensible',
      });
    }
  }

  // Report findings
  if (unsubstantiatedClaims.length === 0) {
    findings.push({
      severity: 'pass',
      category: 'Compliance - Substantiation',
      message: 'No obviously unsubstantiated claims detected',
    });
  } else {
    recommendations.push({
      priority: 'high',
      category: 'Substantiation',
      current: `${unsubstantiatedClaims.length} claim(s) lack substantiation`,
      suggested: 'Add supporting data, sources, or soften language',
      rationale: 'Unsubstantiated claims can lead to legal challenges',
    });
  }

  return { score: Math.max(0, score) };
}

// ============================================
// Helper Functions
// ============================================

/**
 * Get all text from content
 */
function getAllText(content: AnalysisInput): string {
  return [
    content.title,
    ...content.headings,
    ...content.paragraphs,
    ...content.ctas.map(c => c.text),
    ...content.claims,
  ].join(' ');
}

/**
 * Find the location of a term in content
 */
function findTermLocation(content: AnalysisInput, pattern: RegExp): string {
  // Check title
  if (pattern.test(content.title)) {
    return 'Page title';
  }

  // Check headings
  for (let i = 0; i < content.headings.length; i++) {
    if (pattern.test(content.headings[i])) {
      return `Heading: ${truncate(content.headings[i], 50)}`;
    }
  }

  // Check sections
  for (const section of content.sections) {
    const sectionText = section.content.join(' ');
    if (pattern.test(sectionText)) {
      return `Section: ${section.type} (${section.heading || section.id})`;
    }
  }

  // Check CTAs
  for (const cta of content.ctas) {
    if (pattern.test(cta.text)) {
      return `CTA: ${cta.text}`;
    }
  }

  return 'Body content';
}

/**
 * Truncate string with ellipsis
 */
function truncate(str: string, maxLength: number): string {
  if (str.length <= maxLength) return str;
  return str.slice(0, maxLength - 3) + '...';
}
