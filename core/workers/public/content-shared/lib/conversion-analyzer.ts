/**
 * Conversion Analyzer (US-008)
 * Analyzes content for conversion optimization opportunities
 */

import type {
  AnalysisInput,
  ConversionAnalysis,
  Finding,
  Recommendation,
} from './types.js';

// ============================================
// Conversion Elements to Check
// ============================================

export const CONVERSION_ELEMENTS = {
  // Strong CTA verbs and phrases
  ctaStrength: {
    strong: ['get started', 'start free', 'request demo', 'schedule call', 'book demo', 'try free', 'sign up free'],
    moderate: ['learn more', 'see how', 'explore', 'discover', 'find out', 'contact us', 'talk to sales'],
    weak: ['click here', 'submit', 'continue', 'next', 'read more'],
  },

  // Value indicators
  valueIndicators: ['save', 'reduce', 'increase', 'improve', 'boost', 'grow', 'eliminate', 'cut', 'accelerate', 'streamline'],

  // Quantified value (percentages, dollars, time)
  quantifiedValue: [
    /save\s+(?:\$[\d,]+|\d+%)/gi,
    /reduce\s+(?:by\s+)?\d+%/gi,
    /increase\s+(?:by\s+)?\d+%/gi,
    /\d+x\s+(?:faster|more|better)/gi,
    /in\s+(?:just\s+)?\d+\s+(?:minutes?|hours?|days?)/gi,
  ],

  // Urgency words
  urgencyWords: ['now', 'today', 'limited', 'exclusive', 'while', 'before', 'last chance', 'ending soon', 'hurry'],

  // Social proof elements
  proofElements: ['customers', 'clients', 'companies', 'teams', 'trusted by', 'used by', 'join', 'chosen by', 'preferred by'],

  // Trust indicators
  trustIndicators: ['secure', 'guaranteed', 'certified', 'compliant', 'protected', 'verified', 'trusted', 'enterprise-grade'],
};

// ============================================
// Scoring Weights
// ============================================

const WEIGHTS = {
  cta: 0.30,
  valueProp: 0.30,
  urgency: 0.15,
  socialProof: 0.25,
};

// ============================================
// Main Analysis Function
// ============================================

/**
 * Analyze content for conversion optimization
 */
export function analyzeConversion(content: AnalysisInput): ConversionAnalysis {
  const findings: Finding[] = [];
  const recommendations: Recommendation[] = [];

  // Analyze CTAs
  const ctaResult = analyzeCTAs(content, findings, recommendations);

  // Analyze value proposition
  const valueResult = analyzeValueProp(content, findings, recommendations);

  // Analyze urgency
  const urgencyResult = analyzeUrgency(content, findings, recommendations);

  // Analyze social proof
  const socialProofResult = analyzeSocialProof(content, findings, recommendations);

  // Calculate overall score
  const overallScore = Math.round(
    ctaResult.score * WEIGHTS.cta +
    valueResult.score * WEIGHTS.valueProp +
    urgencyResult.score * WEIGHTS.urgency +
    socialProofResult.score * WEIGHTS.socialProof
  );

  return {
    overallScore,
    ctaScore: ctaResult.score,
    valuePropScore: valueResult.score,
    urgencyScore: urgencyResult.score,
    socialProofScore: socialProofResult.score,
    findings,
    recommendations,
  };
}

// ============================================
// CTA Analysis
// ============================================

interface ScoreResult {
  score: number;
}

function analyzeCTAs(
  content: AnalysisInput,
  findings: Finding[],
  recommendations: Recommendation[]
): ScoreResult {
  let score = 100;
  const { ctaStrength } = CONVERSION_ELEMENTS;

  // Check if CTAs exist
  if (content.ctas.length === 0) {
    findings.push({
      severity: 'critical',
      category: 'Conversion - CTA',
      message: 'No calls-to-action found on page',
    });
    recommendations.push({
      priority: 'high',
      category: 'CTA',
      current: 'No CTAs present',
      suggested: 'Add primary CTA (e.g., "Get Started Free", "Request Demo")',
      rationale: 'Every page should guide visitors toward conversion',
    });
    return { score: 0 };
  }

  // Analyze CTA strength
  let strongCTAs = 0;
  let moderateCTAs = 0;
  let weakCTAs = 0;

  for (const cta of content.ctas) {
    const ctaLower = cta.text.toLowerCase();

    if (ctaStrength.strong.some(phrase => ctaLower.includes(phrase))) {
      strongCTAs++;
    } else if (ctaStrength.moderate.some(phrase => ctaLower.includes(phrase))) {
      moderateCTAs++;
    } else if (ctaStrength.weak.some(phrase => ctaLower.includes(phrase))) {
      weakCTAs++;
    } else {
      moderateCTAs++; // Assume moderate if not categorized
    }
  }

  // Score based on CTA quality mix
  if (strongCTAs === 0) {
    findings.push({
      severity: 'warning',
      category: 'Conversion - CTA',
      message: 'No strong CTAs found',
      evidence: `Found ${moderateCTAs} moderate and ${weakCTAs} weak CTAs`,
    });
    score -= 20;
    recommendations.push({
      priority: 'high',
      category: 'CTA',
      current: content.ctas[0]?.text ?? 'No strong CTA',
      suggested: 'Use action-oriented CTAs: "Get Started Free", "Request Demo", "Start Trial"',
      rationale: 'Strong CTAs drive higher conversion rates',
    });
  } else {
    findings.push({
      severity: 'pass',
      category: 'Conversion - CTA',
      message: `Found ${strongCTAs} strong CTA(s)`,
      evidence: content.ctas.slice(0, 3).map(c => c.text).join(', '),
    });
  }

  if (weakCTAs > 0) {
    findings.push({
      severity: 'info',
      category: 'Conversion - CTA',
      message: `${weakCTAs} weak CTA(s) could be strengthened`,
    });
    score -= weakCTAs * 5;
  }

  // Check CTA variety (primary vs secondary)
  const hasPrimary = content.ctas.some(c => ctaStrength.strong.some(phrase =>
    c.text.toLowerCase().includes(phrase)
  ));
  const hasSecondary = content.ctas.some(c => ctaStrength.moderate.some(phrase =>
    c.text.toLowerCase().includes(phrase)
  ));

  if (hasPrimary && hasSecondary) {
    findings.push({
      severity: 'pass',
      category: 'Conversion - CTA',
      message: 'Good CTA hierarchy with primary and secondary options',
    });
  } else if (!hasSecondary && content.ctas.length < 2) {
    findings.push({
      severity: 'info',
      category: 'Conversion - CTA',
      message: 'Consider adding secondary CTA for visitors not ready to commit',
    });
    score -= 5;
    recommendations.push({
      priority: 'low',
      category: 'CTA',
      current: 'Only one type of CTA',
      suggested: 'Add secondary option like "Learn More" or "See How It Works"',
      rationale: 'Multiple CTAs accommodate different buyer stages',
    });
  }

  // Check for above-the-fold CTA
  const heroSection = content.sections.find(s => s.type === 'hero');
  if (heroSection) {
    const heroCTA = content.ctas.find(c => c.link && (c.link.includes('#') || c.link.startsWith('/')));
    if (!heroCTA) {
      findings.push({
        severity: 'info',
        category: 'Conversion - CTA',
        message: 'Ensure primary CTA is visible above the fold',
      });
      score -= 5;
    }
  }

  return { score: Math.max(0, Math.min(100, score)) };
}

// ============================================
// Value Proposition Analysis
// ============================================

function analyzeValueProp(
  content: AnalysisInput,
  findings: Finding[],
  recommendations: Recommendation[]
): ScoreResult {
  let score = 100;
  const allText = getAllText(content).toLowerCase();

  // Check for value indicators
  const valueTermsFound = CONVERSION_ELEMENTS.valueIndicators.filter(term =>
    allText.includes(term)
  );

  if (valueTermsFound.length === 0) {
    findings.push({
      severity: 'warning',
      category: 'Conversion - Value Proposition',
      message: 'No clear value indicators found',
    });
    score -= 25;
    recommendations.push({
      priority: 'high',
      category: 'Value Proposition',
      current: 'Value proposition unclear',
      suggested: 'Explicitly state benefits: "Save 50% on...", "Reduce X by..."',
      rationale: 'Clear value propositions are essential for conversion',
    });
  } else {
    findings.push({
      severity: 'pass',
      category: 'Conversion - Value Proposition',
      message: `${valueTermsFound.length} value indicator(s) found`,
      evidence: valueTermsFound.join(', '),
    });
  }

  // Check for quantified value (numbers, percentages)
  let quantifiedCount = 0;
  for (const pattern of CONVERSION_ELEMENTS.quantifiedValue) {
    const matches = allText.match(pattern);
    if (matches) quantifiedCount += matches.length;
  }

  if (quantifiedCount === 0) {
    findings.push({
      severity: 'warning',
      category: 'Conversion - Value Proposition',
      message: 'No quantified benefits found',
    });
    score -= 20;
    recommendations.push({
      priority: 'high',
      category: 'Value Proposition',
      current: 'Benefits are not quantified',
      suggested: 'Add specific metrics: "Save 40%", "10x faster", "In just 5 minutes"',
      rationale: 'Specific numbers are more persuasive than vague claims',
    });
  } else {
    findings.push({
      severity: 'pass',
      category: 'Conversion - Value Proposition',
      message: `Found ${quantifiedCount} quantified benefit(s)`,
    });
  }

  // Check stats coverage
  if (content.stats.length > 0) {
    findings.push({
      severity: 'pass',
      category: 'Conversion - Value Proposition',
      message: `${content.stats.length} statistics/metrics displayed`,
      evidence: content.stats.slice(0, 3).map(s => s.value).join(', '),
    });
  } else {
    findings.push({
      severity: 'info',
      category: 'Conversion - Value Proposition',
      message: 'Consider adding key statistics or metrics',
    });
    score -= 10;
  }

  // Check hero section for value prop
  const heroSection = content.sections.find(s => s.type === 'hero');
  if (heroSection) {
    const heroText = heroSection.content.join(' ').toLowerCase();
    const hasValueInHero = CONVERSION_ELEMENTS.valueIndicators.some(term =>
      heroText.includes(term)
    );

    if (!hasValueInHero) {
      findings.push({
        severity: 'warning',
        category: 'Conversion - Value Proposition',
        message: 'Hero section lacks clear value proposition',
        location: 'Hero section',
      });
      score -= 15;
      recommendations.push({
        priority: 'high',
        category: 'Value Proposition',
        current: 'Hero section missing value prop',
        suggested: 'Lead with primary benefit in hero headline or subheadline',
        rationale: 'Visitors should understand value within seconds',
      });
    }
  }

  return { score: Math.max(0, Math.min(100, score)) };
}

// ============================================
// Urgency Analysis
// ============================================

function analyzeUrgency(
  content: AnalysisInput,
  findings: Finding[],
  recommendations: Recommendation[]
): ScoreResult {
  let score = 70; // Start at 70 since urgency isn't always appropriate
  const allText = getAllText(content).toLowerCase();

  // Check for urgency words
  const urgencyFound = CONVERSION_ELEMENTS.urgencyWords.filter(term =>
    allText.includes(term)
  );

  if (urgencyFound.length > 0) {
    findings.push({
      severity: 'pass',
      category: 'Conversion - Urgency',
      message: `Urgency elements present: ${urgencyFound.length} indicator(s)`,
      evidence: urgencyFound.join(', '),
    });
    score += 20;

    // Check for authentic vs artificial urgency
    const artificialUrgency = ['limited time', 'act now', 'hurry', 'last chance'];
    const hasArtificial = artificialUrgency.some(phrase => allText.includes(phrase));

    if (hasArtificial && !allText.includes('offer') && !allText.includes('promo')) {
      findings.push({
        severity: 'info',
        category: 'Conversion - Urgency',
        message: 'Urgency language may feel artificial without context',
      });
      score -= 10;
      recommendations.push({
        priority: 'low',
        category: 'Urgency',
        current: 'Generic urgency language',
        suggested: 'Tie urgency to specific context (limited seats, trial ending, etc.)',
        rationale: 'Authentic urgency is more effective than manufactured scarcity',
      });
    }
  } else {
    findings.push({
      severity: 'info',
      category: 'Conversion - Urgency',
      message: 'No urgency elements found',
    });
    recommendations.push({
      priority: 'low',
      category: 'Urgency',
      current: 'No urgency drivers',
      suggested: 'Consider adding contextual urgency (limited beta spots, early pricing, etc.)',
      rationale: 'Appropriate urgency can accelerate decision-making',
    });
  }

  // Check CTAs for urgency
  const ctasWithUrgency = content.ctas.filter(cta => {
    const ctaLower = cta.text.toLowerCase();
    return CONVERSION_ELEMENTS.urgencyWords.some(word => ctaLower.includes(word));
  });

  if (ctasWithUrgency.length > 0) {
    findings.push({
      severity: 'pass',
      category: 'Conversion - Urgency',
      message: 'CTA includes urgency element',
      evidence: ctasWithUrgency[0].text,
    });
    score += 10;
  }

  return { score: Math.max(0, Math.min(100, score)) };
}

// ============================================
// Social Proof Analysis
// ============================================

function analyzeSocialProof(
  content: AnalysisInput,
  findings: Finding[],
  recommendations: Recommendation[]
): ScoreResult {
  let score = 100;
  const allText = getAllText(content).toLowerCase();

  // Check for social proof elements
  const proofFound = CONVERSION_ELEMENTS.proofElements.filter(term =>
    allText.includes(term)
  );

  if (proofFound.length === 0) {
    findings.push({
      severity: 'warning',
      category: 'Conversion - Social Proof',
      message: 'No social proof elements found',
    });
    score -= 30;
    recommendations.push({
      priority: 'high',
      category: 'Social Proof',
      current: 'Missing social proof',
      suggested: 'Add customer count, logos, testimonials, or case study references',
      rationale: 'Social proof significantly increases conversion rates',
    });
  } else {
    findings.push({
      severity: 'pass',
      category: 'Conversion - Social Proof',
      message: `Social proof present: ${proofFound.length} indicator(s)`,
      evidence: proofFound.join(', '),
    });
  }

  // Check for testimonials section
  const hasTestimonials = content.sections.some(s => s.type === 'testimonials');
  if (hasTestimonials) {
    findings.push({
      severity: 'pass',
      category: 'Conversion - Social Proof',
      message: 'Testimonials section present',
    });
  } else {
    findings.push({
      severity: 'info',
      category: 'Conversion - Social Proof',
      message: 'No dedicated testimonials section found',
    });
    score -= 10;
    recommendations.push({
      priority: 'medium',
      category: 'Social Proof',
      current: 'No testimonials section',
      suggested: 'Add customer testimonials with names, titles, and companies',
      rationale: 'Named testimonials build credibility and trust',
    });
  }

  // Check for trust indicators
  const trustFound = CONVERSION_ELEMENTS.trustIndicators.filter(term =>
    allText.includes(term)
  );

  if (trustFound.length > 0) {
    findings.push({
      severity: 'pass',
      category: 'Conversion - Social Proof',
      message: `Trust indicators present: ${trustFound.length}`,
      evidence: trustFound.join(', '),
    });
  } else {
    findings.push({
      severity: 'info',
      category: 'Conversion - Social Proof',
      message: 'No explicit trust indicators found',
    });
    score -= 10;
  }

  // Check for specific numbers (more credible)
  const specificNumbers = allText.match(/(?:over\s+)?\d{1,3}(?:,\d{3})*\+?\s+(?:customers?|clients?|companies?|teams?)/gi);
  if (specificNumbers && specificNumbers.length > 0) {
    findings.push({
      severity: 'pass',
      category: 'Conversion - Social Proof',
      message: 'Specific customer count mentioned',
      evidence: specificNumbers[0],
    });
  } else {
    findings.push({
      severity: 'info',
      category: 'Conversion - Social Proof',
      message: 'Consider adding specific customer count',
    });
    score -= 5;
    recommendations.push({
      priority: 'low',
      category: 'Social Proof',
      current: 'Generic social proof',
      suggested: 'Add specific number: "Trusted by 10,000+ companies"',
      rationale: 'Specific numbers are more credible than vague claims',
    });
  }

  return { score: Math.max(0, Math.min(100, score)) };
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
