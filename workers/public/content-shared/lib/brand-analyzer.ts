/**
 * Brand Voice Analyzer (US-007)
 * Analyzes content against brand guidelines for tone, messaging, and clarity
 */

import type {
  AnalysisInput,
  BrandGuidelines,
  BrandAnalysis,
  Finding,
  Recommendation,
} from './types.js';

// ============================================
// Default Brand Attributes
// ============================================

/**
 * Brand voice characteristics to check
 */
export const BRAND_ATTRIBUTES = {
  professional: ['enterprise', 'secure', 'compliance', 'trusted', 'reliable', 'proven', 'robust'],
  confident: ['leading', 'proven', 'powerful', 'best-in-class', 'premier', 'industry-leading', 'world-class'],
  approachable: ['simple', 'easy', 'seamless', 'intuitive', 'straightforward', 'effortless', 'user-friendly'],
  avoid: ['cheap', 'basic', 'try', 'maybe', 'kind of', 'sort of', 'hopefully', 'might', 'possibly'],
};

/**
 * Default brand guidelines when none provided
 */
export const DEFAULT_BRAND_GUIDELINES: BrandGuidelines = {
  voiceAttributes: ['professional', 'confident', 'approachable'],
  toneDescriptors: ['authoritative', 'helpful', 'clear'],
  approvedTerms: [
    ...BRAND_ATTRIBUTES.professional,
    ...BRAND_ATTRIBUTES.confident,
    ...BRAND_ATTRIBUTES.approachable,
  ],
  avoidTerms: BRAND_ATTRIBUTES.avoid,
  messagingPillars: ['security', 'efficiency', 'innovation', 'trust'],
};

// ============================================
// Scoring Weights
// ============================================

const WEIGHTS = {
  tone: 0.30,
  messaging: 0.35,
  clarity: 0.35,
};

// ============================================
// Main Analysis Function
// ============================================

/**
 * Analyze content for brand voice alignment
 */
export function analyzeBrandVoice(
  content: AnalysisInput,
  guidelines: BrandGuidelines = DEFAULT_BRAND_GUIDELINES
): BrandAnalysis {
  const findings: Finding[] = [];
  const recommendations: Recommendation[] = [];

  // Analyze tone
  const toneResult = analyzeTone(content, guidelines, findings, recommendations);

  // Analyze messaging alignment
  const messagingResult = analyzeMessaging(content, guidelines, findings, recommendations);

  // Analyze clarity
  const clarityResult = analyzeClarity(content, findings, recommendations);

  // Calculate overall score
  const overallScore = Math.round(
    toneResult.score * WEIGHTS.tone +
    messagingResult.score * WEIGHTS.messaging +
    clarityResult.score * WEIGHTS.clarity
  );

  return {
    overallScore,
    toneScore: toneResult.score,
    messagingScore: messagingResult.score,
    clarityScore: clarityResult.score,
    findings,
    recommendations,
  };
}

// ============================================
// Tone Analysis
// ============================================

interface AnalysisScoreResult {
  score: number;
}

function analyzeTone(
  content: AnalysisInput,
  guidelines: BrandGuidelines,
  findings: Finding[],
  recommendations: Recommendation[]
): AnalysisScoreResult {
  let score = 100;
  const allText = getAllText(content).toLowerCase();

  // Check for approved terms (positive)
  const approvedTermsFound = guidelines.approvedTerms.filter(term =>
    allText.includes(term.toLowerCase())
  );

  if (approvedTermsFound.length > 0) {
    findings.push({
      severity: 'pass',
      category: 'Brand Voice - Tone',
      message: `Found ${approvedTermsFound.length} approved brand terms`,
      evidence: approvedTermsFound.slice(0, 5).join(', '),
    });
  } else {
    findings.push({
      severity: 'warning',
      category: 'Brand Voice - Tone',
      message: 'No approved brand terms found in content',
    });
    score -= 15;
  }

  // Check for terms to avoid (negative)
  const avoidTermsFound = guidelines.avoidTerms.filter(term =>
    allText.includes(term.toLowerCase())
  );

  if (avoidTermsFound.length > 0) {
    findings.push({
      severity: 'warning',
      category: 'Brand Voice - Tone',
      message: `Found ${avoidTermsFound.length} terms that should be avoided`,
      evidence: avoidTermsFound.join(', '),
    });
    score -= avoidTermsFound.length * 10;

    for (const term of avoidTermsFound) {
      const suggestion = getSuggestionForAvoidTerm(term);
      recommendations.push({
        priority: 'medium',
        category: 'Tone',
        current: `Uses "${term}"`,
        suggested: suggestion,
        rationale: 'This term undermines confidence and authority in messaging',
      });
    }
  }

  // Check for passive voice (weakens tone)
  const passiveCount = countPassiveVoice(allText);
  if (passiveCount > 3) {
    findings.push({
      severity: 'info',
      category: 'Brand Voice - Tone',
      message: `Detected ${passiveCount} instances of passive voice`,
    });
    score -= Math.min(passiveCount * 2, 10);
    recommendations.push({
      priority: 'low',
      category: 'Tone',
      current: 'Multiple passive voice constructions',
      suggested: 'Convert to active voice for stronger messaging',
      rationale: 'Active voice is more direct and confident',
    });
  }

  // Check for hedging language
  const hedgingTerms = ['possibly', 'perhaps', 'might', 'could be', 'tends to', 'generally'];
  const hedgingFound = hedgingTerms.filter(term => allText.includes(term));
  if (hedgingFound.length > 0) {
    findings.push({
      severity: 'info',
      category: 'Brand Voice - Tone',
      message: 'Hedging language detected',
      evidence: hedgingFound.join(', '),
    });
    score -= hedgingFound.length * 3;
  }

  return { score: Math.max(0, Math.min(100, score)) };
}

// ============================================
// Messaging Analysis
// ============================================

function analyzeMessaging(
  content: AnalysisInput,
  guidelines: BrandGuidelines,
  findings: Finding[],
  recommendations: Recommendation[]
): AnalysisScoreResult {
  let score = 100;
  const allText = getAllText(content).toLowerCase();

  // Check messaging pillar coverage
  const pillarsFound = guidelines.messagingPillars.filter(pillar =>
    allText.includes(pillar.toLowerCase())
  );

  const pillarCoverage = pillarsFound.length / guidelines.messagingPillars.length;

  if (pillarCoverage >= 0.75) {
    findings.push({
      severity: 'pass',
      category: 'Brand Voice - Messaging',
      message: `Strong messaging pillar coverage: ${Math.round(pillarCoverage * 100)}%`,
      evidence: pillarsFound.join(', '),
    });
  } else if (pillarCoverage >= 0.5) {
    findings.push({
      severity: 'info',
      category: 'Brand Voice - Messaging',
      message: `Moderate messaging pillar coverage: ${Math.round(pillarCoverage * 100)}%`,
      evidence: pillarsFound.join(', '),
    });
    score -= 10;
  } else {
    const missingPillars = guidelines.messagingPillars.filter(p =>
      !pillarsFound.includes(p)
    );
    findings.push({
      severity: 'warning',
      category: 'Brand Voice - Messaging',
      message: `Low messaging pillar coverage: ${Math.round(pillarCoverage * 100)}%`,
      evidence: `Missing: ${missingPillars.join(', ')}`,
    });
    score -= 25;

    recommendations.push({
      priority: 'high',
      category: 'Messaging',
      current: `Only covers ${pillarsFound.length} of ${guidelines.messagingPillars.length} messaging pillars`,
      suggested: `Incorporate messaging around: ${missingPillars.join(', ')}`,
      rationale: 'Core messaging pillars should be represented for brand consistency',
    });
  }

  // Check for value proposition clarity
  const valueIndicators = ['save', 'reduce', 'increase', 'improve', 'boost', 'grow', 'eliminate', 'streamline'];
  const valueTermsFound = valueIndicators.filter(term => allText.includes(term));

  if (valueTermsFound.length === 0) {
    findings.push({
      severity: 'warning',
      category: 'Brand Voice - Messaging',
      message: 'No clear value proposition language found',
    });
    score -= 15;
    recommendations.push({
      priority: 'high',
      category: 'Messaging',
      current: 'Value proposition unclear',
      suggested: 'Add specific benefits using action verbs (save, reduce, improve, etc.)',
      rationale: 'Clear value propositions drive engagement and conversion',
    });
  } else {
    findings.push({
      severity: 'pass',
      category: 'Brand Voice - Messaging',
      message: `Value proposition language present: ${valueTermsFound.length} indicators`,
      evidence: valueTermsFound.join(', '),
    });
  }

  // Check for consistent terminology
  const inconsistencies = checkTerminologyConsistency(content);
  if (inconsistencies.length > 0) {
    findings.push({
      severity: 'info',
      category: 'Brand Voice - Messaging',
      message: 'Potential terminology inconsistencies detected',
      evidence: inconsistencies.join('; '),
    });
    score -= inconsistencies.length * 3;
  }

  return { score: Math.max(0, Math.min(100, score)) };
}

// ============================================
// Clarity Analysis
// ============================================

function analyzeClarity(
  content: AnalysisInput,
  findings: Finding[],
  recommendations: Recommendation[]
): AnalysisScoreResult {
  let score = 100;

  // Analyze readability
  const readabilityResult = analyzeReadability(content);

  if (readabilityResult.grade > 12) {
    findings.push({
      severity: 'warning',
      category: 'Brand Voice - Clarity',
      message: `Content reading level too high: Grade ${readabilityResult.grade}`,
      evidence: `Average sentence length: ${readabilityResult.avgSentenceLength} words`,
    });
    score -= 20;
    recommendations.push({
      priority: 'medium',
      category: 'Clarity',
      current: `Grade ${readabilityResult.grade} reading level`,
      suggested: 'Simplify sentences to Grade 8-10 level for broader accessibility',
      rationale: 'B2B content should be professional but accessible',
    });
  } else if (readabilityResult.grade >= 8) {
    findings.push({
      severity: 'pass',
      category: 'Brand Voice - Clarity',
      message: `Appropriate reading level: Grade ${readabilityResult.grade}`,
    });
  } else {
    findings.push({
      severity: 'info',
      category: 'Brand Voice - Clarity',
      message: `Reading level may be too simple: Grade ${readabilityResult.grade}`,
    });
    score -= 5;
  }

  // Check for jargon overuse
  const jargonTerms = [
    'synergy', 'leverage', 'paradigm', 'bandwidth', 'circle back',
    'low-hanging fruit', 'move the needle', 'drill down', 'holistic',
  ];
  const allText = getAllText(content).toLowerCase();
  const jargonFound = jargonTerms.filter(term => allText.includes(term));

  if (jargonFound.length > 2) {
    findings.push({
      severity: 'warning',
      category: 'Brand Voice - Clarity',
      message: 'Excessive business jargon detected',
      evidence: jargonFound.join(', '),
    });
    score -= jargonFound.length * 5;
    recommendations.push({
      priority: 'medium',
      category: 'Clarity',
      current: `Uses jargon: ${jargonFound.join(', ')}`,
      suggested: 'Replace with clearer, more specific language',
      rationale: 'Jargon reduces clarity and can alienate readers',
    });
  }

  // Check for long paragraphs
  const longParagraphs = content.paragraphs.filter(p => p.split(/\s+/).length > 100);
  if (longParagraphs.length > 0) {
    findings.push({
      severity: 'info',
      category: 'Brand Voice - Clarity',
      message: `${longParagraphs.length} paragraph(s) exceed 100 words`,
    });
    score -= longParagraphs.length * 3;
    recommendations.push({
      priority: 'low',
      category: 'Clarity',
      current: 'Long paragraphs reduce scanability',
      suggested: 'Break into shorter paragraphs (3-5 sentences max)',
      rationale: 'Shorter paragraphs improve readability on screens',
    });
  }

  // Check heading clarity
  const unclearHeadings = content.headings.filter(h => {
    const words = h.split(/\s+/);
    return words.length < 2 || words.length > 12;
  });

  if (unclearHeadings.length > 0) {
    findings.push({
      severity: 'info',
      category: 'Brand Voice - Clarity',
      message: `${unclearHeadings.length} heading(s) may need refinement`,
      evidence: unclearHeadings.slice(0, 3).join(', '),
    });
    score -= unclearHeadings.length * 2;
  }

  return { score: Math.max(0, Math.min(100, score)) };
}

// ============================================
// Helper Functions
// ============================================

/**
 * Get all text from content as single string
 */
function getAllText(content: AnalysisInput): string {
  return [
    content.title,
    ...content.headings,
    ...content.paragraphs,
    ...content.ctas.map(c => c.text),
  ].join(' ');
}

/**
 * Count passive voice instances
 */
function countPassiveVoice(text: string): number {
  // Simplified passive voice detection
  const passivePatterns = [
    /\b(is|are|was|were|been|being)\s+\w+ed\b/gi,
    /\b(is|are|was|were|been|being)\s+\w+en\b/gi,
  ];

  let count = 0;
  for (const pattern of passivePatterns) {
    const matches = text.match(pattern);
    if (matches) count += matches.length;
  }
  return count;
}

/**
 * Get suggestion for avoided term
 */
function getSuggestionForAvoidTerm(term: string): string {
  const suggestions: Record<string, string> = {
    'cheap': 'Use "cost-effective" or "affordable"',
    'basic': 'Use "essential" or "foundational"',
    'try': 'Use "experience" or "discover"',
    'maybe': 'Remove hedging or state confidently',
    'kind of': 'Be specific or remove qualifier',
    'sort of': 'Be specific or remove qualifier',
    'hopefully': 'State with confidence or specify conditions',
    'might': 'Use "will" or "can" when appropriate',
    'possibly': 'Be specific about conditions or remove',
  };
  return suggestions[term.toLowerCase()] ?? 'Replace with more confident language';
}

/**
 * Check for terminology consistency
 */
function checkTerminologyConsistency(content: AnalysisInput): string[] {
  const inconsistencies: string[] = [];
  const allText = getAllText(content).toLowerCase();

  // Check for inconsistent product/feature naming
  const termPairs = [
    ['customer', 'client'],
    ['user', 'member'],
    ['platform', 'solution'],
    ['dashboard', 'portal'],
  ];

  for (const [term1, term2] of termPairs) {
    const has1 = allText.includes(term1);
    const has2 = allText.includes(term2);
    if (has1 && has2) {
      inconsistencies.push(`Mixed usage: "${term1}" and "${term2}"`);
    }
  }

  return inconsistencies;
}

/**
 * Analyze readability metrics
 */
function analyzeReadability(content: AnalysisInput): {
  grade: number;
  avgSentenceLength: number;
  avgWordLength: number;
} {
  const allText = getAllText(content);
  const sentences = allText.split(/[.!?]+/).filter(s => s.trim().length > 0);
  const words = allText.split(/\s+/).filter(w => w.length > 0);

  const avgSentenceLength = sentences.length > 0 ? words.length / sentences.length : 0;
  const avgWordLength = words.length > 0
    ? words.reduce((sum, w) => sum + w.length, 0) / words.length
    : 0;

  // Simplified Flesch-Kincaid grade level approximation
  const syllables = words.reduce((sum, w) => sum + countSyllables(w), 0);
  const avgSyllablesPerWord = words.length > 0 ? syllables / words.length : 0;

  // Flesch-Kincaid Grade Level formula (simplified)
  const grade = Math.round(
    0.39 * avgSentenceLength + 11.8 * avgSyllablesPerWord - 15.59
  );

  return {
    grade: Math.max(1, Math.min(20, grade)),
    avgSentenceLength: Math.round(avgSentenceLength * 10) / 10,
    avgWordLength: Math.round(avgWordLength * 10) / 10,
  };
}

/**
 * Count syllables in a word (approximation)
 */
function countSyllables(word: string): number {
  word = word.toLowerCase().replace(/[^a-z]/g, '');
  if (word.length <= 3) return 1;

  // Count vowel groups
  const matches = word.match(/[aeiouy]+/g);
  let count = matches ? matches.length : 1;

  // Adjust for silent e
  if (word.endsWith('e')) count--;

  // Adjust for -le endings
  if (word.endsWith('le') && word.length > 2 && !/[aeiouy]/.test(word[word.length - 3])) {
    count++;
  }

  return Math.max(1, count);
}
