/**
 * Recommendations Generator (US-011)
 * Creates improvement recommendations with rationale from analysis findings
 */

import type {
  FullAnalysis,
  Finding,
  Recommendation,
  ContentSection,
  AnalysisInput,
} from './types.js';

// ============================================
// Types
// ============================================

export interface Suggestion {
  id: string;
  type: 'text' | 'structure' | 'cta' | 'stat' | 'claim';
  pageSlug: string;
  sectionId?: string;
  original: string;
  suggested: string;
  rationale: string;
  source: 'brand' | 'sales' | 'product' | 'legal';
  impact: 'high' | 'medium' | 'low';
  effort: 'quick' | 'moderate' | 'significant';
  priority: number; // Calculated from impact/effort
}

export interface SuggestionContext {
  pageSlug: string;
  sectionId?: string;
  contentType?: ContentSection['type'];
}

// ============================================
// Impact/Effort Scoring
// ============================================

const IMPACT_SCORES: Record<Suggestion['impact'], number> = {
  high: 3,
  medium: 2,
  low: 1,
};

const EFFORT_SCORES: Record<Suggestion['effort'], number> = {
  quick: 3,      // Lower effort = higher score (easier to do)
  moderate: 2,
  significant: 1,
};

/**
 * Calculate priority score from impact and effort
 * Higher score = do first (high impact + quick effort = best)
 */
function calculateSuggestionPriority(impact: Suggestion['impact'], effort: Suggestion['effort']): number {
  return IMPACT_SCORES[impact] * EFFORT_SCORES[effort];
}

// ============================================
// Suggestion Generation
// ============================================

let suggestionCounter = 0;

function generateSuggestionId(): string {
  suggestionCounter++;
  return `sug-${Date.now()}-${suggestionCounter}`;
}

/**
 * Generate suggestions from full analysis results
 */
export function generateSuggestions(analysis: FullAnalysis): Suggestion[] {
  const suggestions: Suggestion[] = [];
  const pageSlug = analysis.page;

  // Process brand findings
  if (analysis.brand) {
    suggestions.push(...convertFindingsToSuggestions(
      analysis.brand.findings,
      analysis.brand.recommendations,
      pageSlug,
      'brand'
    ));
  }

  // Process conversion findings
  if (analysis.conversion) {
    suggestions.push(...convertFindingsToSuggestions(
      analysis.conversion.findings,
      analysis.conversion.recommendations,
      pageSlug,
      'sales'
    ));
  }

  // Process accuracy findings
  if (analysis.accuracy) {
    suggestions.push(...convertFindingsToSuggestions(
      analysis.accuracy.findings,
      analysis.accuracy.recommendations,
      pageSlug,
      'product'
    ));
  }

  // Process compliance findings
  if (analysis.compliance) {
    suggestions.push(...convertFindingsToSuggestions(
      analysis.compliance.findings,
      analysis.compliance.recommendations,
      pageSlug,
      'legal'
    ));
  }

  // Sort by priority (highest first)
  suggestions.sort((a, b) => b.priority - a.priority);

  return suggestions;
}

/**
 * Convert findings and recommendations to suggestions
 */
function convertFindingsToSuggestions(
  findings: Finding[],
  recommendations: Recommendation[],
  pageSlug: string,
  source: Suggestion['source']
): Suggestion[] {
  const suggestions: Suggestion[] = [];

  // Create suggestions from recommendations (these have current/suggested pairs)
  for (const rec of recommendations) {
    const impact = mapPriorityToImpact(rec.priority);
    const effort = estimateEffort(rec.current, rec.suggested);
    const type = inferSuggestionType(rec.category, rec.current);

    suggestions.push({
      id: generateSuggestionId(),
      type,
      pageSlug,
      sectionId: extractSectionId(rec.current),
      original: rec.current,
      suggested: rec.suggested,
      rationale: rec.rationale,
      source,
      impact,
      effort,
      priority: calculateSuggestionPriority(impact, effort),
    });
  }

  // Create suggestions from critical/warning findings without recommendations
  const recommendedOriginals = new Set(recommendations.map(r => r.current));

  for (const finding of findings) {
    if (finding.severity === 'pass' || finding.severity === 'info') continue;
    if (finding.evidence && recommendedOriginals.has(finding.evidence)) continue;

    const impact = finding.severity === 'critical' ? 'high' : 'medium';
    const effort = estimateEffortFromMessage(finding.message);
    const type = inferSuggestionTypeFromCategory(finding.category);

    suggestions.push({
      id: generateSuggestionId(),
      type,
      pageSlug,
      sectionId: finding.location,
      original: finding.evidence ?? finding.message,
      suggested: generateSuggestedFix(finding),
      rationale: finding.message,
      source,
      impact,
      effort,
      priority: calculateSuggestionPriority(impact, effort),
    });
  }

  return suggestions;
}

// ============================================
// Suggestion Enhancement
// ============================================

/**
 * Enhance a suggestion with AI-generated alternatives
 * This provides a richer suggested text based on the type and context
 */
export function enhanceSuggestion(suggestion: Suggestion): Suggestion {
  const enhanced = { ...suggestion };

  // Generate improved suggestion based on type
  switch (suggestion.type) {
    case 'cta':
      enhanced.suggested = enhanceCTA(suggestion.original, suggestion.source);
      break;
    case 'claim':
      enhanced.suggested = enhanceClaim(suggestion.original, suggestion.source);
      break;
    case 'stat':
      enhanced.suggested = enhanceStat(suggestion.original);
      break;
    case 'text':
      enhanced.suggested = enhanceText(suggestion.original, suggestion.source);
      break;
    case 'structure':
      // Structure suggestions typically come pre-formed
      break;
  }

  // Add additional rationale if enhanced
  if (enhanced.suggested !== suggestion.suggested) {
    enhanced.rationale = `${suggestion.rationale} Enhanced for ${suggestion.source} optimization.`;
  }

  return enhanced;
}

/**
 * Enhance CTA text
 */
function enhanceCTA(original: string, source: Suggestion['source']): string {
  const lowerOriginal = original.toLowerCase();

  // Generic CTAs to improve
  if (lowerOriginal === 'learn more' || lowerOriginal === 'click here') {
    if (source === 'sales') return 'See How It Works';
    if (source === 'brand') return 'Discover Our Approach';
    return 'Explore the Details';
  }

  if (lowerOriginal === 'contact us') {
    if (source === 'sales') return 'Talk to an Expert';
    return 'Get in Touch';
  }

  if (lowerOriginal === 'submit') {
    return 'Send Message';
  }

  if (lowerOriginal === 'sign up') {
    if (source === 'sales') return 'Start Free Trial';
    return 'Create Your Account';
  }

  return original;
}

/**
 * Enhance claim text for better substantiation
 */
function enhanceClaim(original: string, source: Suggestion['source']): string {
  // Add specificity indicators
  if (original.includes('best') && !original.includes('one of')) {
    return original.replace(/\bbest\b/gi, 'one of the best');
  }

  if (original.includes('leading') && !original.includes('industry')) {
    return original.replace(/\bleading\b/gi, 'industry-leading');
  }

  // Add hedging for absolute claims
  if (original.includes('always') || original.includes('never')) {
    return `In most cases, ${original.toLowerCase().replace(/\balways\b/gi, 'typically').replace(/\bnever\b/gi, 'rarely')}`;
  }

  return original;
}

/**
 * Enhance stat text with context
 */
function enhanceStat(original: string): string {
  // Add "up to" for unqualified percentages
  if (/\d+%/.test(original) && !original.includes('up to') && !original.includes('over')) {
    return original.replace(/(\d+%)/, 'up to $1');
  }

  return original;
}

/**
 * Enhance general text
 */
function enhanceText(original: string, source: Suggestion['source']): string {
  // Add brand voice elements
  if (source === 'brand' && original.length > 50) {
    // Break up long sentences
    const sentences = original.split(/[.!?]+/).filter(s => s.trim());
    if (sentences.length === 1 && sentences[0].split(' ').length > 25) {
      // Suggest breaking into two sentences
      const words = sentences[0].split(' ');
      const midpoint = Math.floor(words.length / 2);
      return words.slice(0, midpoint).join(' ') + '. ' + words.slice(midpoint).join(' ');
    }
  }

  return original;
}

// ============================================
// Helper Functions
// ============================================

function mapPriorityToImpact(priority: Recommendation['priority']): Suggestion['impact'] {
  return priority; // They use the same values
}

function estimateEffort(original: string, suggested: string): Suggestion['effort'] {
  const originalWords = original.split(/\s+/).length;
  const suggestedWords = suggested.split(/\s+/).length;
  const wordDiff = Math.abs(originalWords - suggestedWords);

  // Small text changes are quick
  if (wordDiff <= 5 && originalWords <= 20) return 'quick';

  // Medium changes
  if (wordDiff <= 15 && originalWords <= 50) return 'moderate';

  // Large changes
  return 'significant';
}

function estimateEffortFromMessage(message: string): Suggestion['effort'] {
  const lowerMessage = message.toLowerCase();

  // Quick fixes
  if (lowerMessage.includes('missing') || lowerMessage.includes('add')) return 'quick';
  if (lowerMessage.includes('update') || lowerMessage.includes('change')) return 'moderate';

  // Significant work
  if (lowerMessage.includes('restructure') || lowerMessage.includes('rewrite')) return 'significant';

  return 'moderate';
}

function inferSuggestionType(category: string, content: string): Suggestion['type'] {
  const lowerCategory = category.toLowerCase();
  const lowerContent = content.toLowerCase();

  if (lowerCategory.includes('cta') || lowerCategory.includes('button')) return 'cta';
  if (lowerCategory.includes('stat') || /\d+[%x]/.test(content)) return 'stat';
  if (lowerCategory.includes('claim') || lowerCategory.includes('compliance')) return 'claim';
  if (lowerCategory.includes('structure') || lowerCategory.includes('section')) return 'structure';

  return 'text';
}

function inferSuggestionTypeFromCategory(category: string): Suggestion['type'] {
  const lowerCategory = category.toLowerCase();

  if (lowerCategory.includes('cta')) return 'cta';
  if (lowerCategory.includes('stat') || lowerCategory.includes('accuracy')) return 'stat';
  if (lowerCategory.includes('claim') || lowerCategory.includes('compliance')) return 'claim';
  if (lowerCategory.includes('structure')) return 'structure';

  return 'text';
}

function extractSectionId(content: string): string | undefined {
  // Try to extract section reference from content
  const sectionMatch = content.match(/section[:\s]+([a-z0-9-]+)/i);
  if (sectionMatch) return sectionMatch[1];

  const inMatch = content.match(/in\s+([a-z0-9-]+)\s+section/i);
  if (inMatch) return inMatch[1];

  return undefined;
}

function generateSuggestedFix(finding: Finding): string {
  const { message, evidence, category } = finding;

  // Generate context-appropriate suggestions
  if (category.toLowerCase().includes('cta')) {
    return 'Consider using action-oriented language with clear value proposition';
  }

  if (category.toLowerCase().includes('compliance')) {
    return evidence
      ? `Add appropriate disclaimer or substantiation for: "${evidence}"`
      : 'Review and add required disclaimers';
  }

  if (category.toLowerCase().includes('accuracy')) {
    return evidence
      ? `Verify and update: "${evidence}"`
      : 'Verify claims against current product data';
  }

  if (category.toLowerCase().includes('brand')) {
    return 'Align with brand voice guidelines and approved terminology';
  }

  return `Address: ${message}`;
}

// ============================================
// Batch Processing
// ============================================

/**
 * Generate suggestions for multiple pages
 */
export function generateSuggestionsForPages(analyses: FullAnalysis[]): Map<string, Suggestion[]> {
  const suggestionsByPage = new Map<string, Suggestion[]>();

  for (const analysis of analyses) {
    const suggestions = generateSuggestions(analysis);
    suggestionsByPage.set(analysis.page, suggestions);
  }

  return suggestionsByPage;
}

/**
 * Get all suggestions sorted by priority across all pages
 */
export function getAllSuggestionsSorted(suggestionsByPage: Map<string, Suggestion[]>): Suggestion[] {
  const all: Suggestion[] = [];

  for (const suggestions of suggestionsByPage.values()) {
    all.push(...suggestions);
  }

  return all.sort((a, b) => b.priority - a.priority);
}

// ============================================
// Formatting
// ============================================

/**
 * Format a suggestion for display
 */
export function formatSuggestion(suggestion: Suggestion): string {
  const impactEmoji = suggestion.impact === 'high' ? '[!]' : suggestion.impact === 'medium' ? '[*]' : '[-]';
  const effortLabel = suggestion.effort === 'quick' ? 'Quick fix' : suggestion.effort === 'moderate' ? 'Moderate' : 'Significant';

  return `${impactEmoji} [${suggestion.type.toUpperCase()}] ${suggestion.pageSlug}${suggestion.sectionId ? `#${suggestion.sectionId}` : ''}
  Original: "${truncate(suggestion.original, 80)}"
  Suggested: "${truncate(suggestion.suggested, 80)}"
  Rationale: ${suggestion.rationale}
  Impact: ${suggestion.impact} | Effort: ${effortLabel} | Priority: ${suggestion.priority}
  Source: ${suggestion.source}`;
}

function truncate(text: string, maxLength: number): string {
  if (text.length <= maxLength) return text;
  return text.slice(0, maxLength - 3) + '...';
}

/**
 * Format suggestions as markdown
 */
export function formatSuggestionsMarkdown(suggestions: Suggestion[]): string {
  const lines: string[] = ['# Content Improvement Suggestions\n'];

  // Group by impact
  const highImpact = suggestions.filter(s => s.impact === 'high');
  const mediumImpact = suggestions.filter(s => s.impact === 'medium');
  const lowImpact = suggestions.filter(s => s.impact === 'low');

  if (highImpact.length > 0) {
    lines.push('## High Impact\n');
    for (const s of highImpact) {
      lines.push(formatSuggestionMarkdownItem(s));
    }
  }

  if (mediumImpact.length > 0) {
    lines.push('\n## Medium Impact\n');
    for (const s of mediumImpact) {
      lines.push(formatSuggestionMarkdownItem(s));
    }
  }

  if (lowImpact.length > 0) {
    lines.push('\n## Low Impact\n');
    for (const s of lowImpact) {
      lines.push(formatSuggestionMarkdownItem(s));
    }
  }

  return lines.join('\n');
}

function formatSuggestionMarkdownItem(s: Suggestion): string {
  const effortBadge = s.effort === 'quick' ? 'Quick Win' : s.effort === 'moderate' ? 'Moderate Effort' : 'Major Change';

  return `### ${s.type.charAt(0).toUpperCase() + s.type.slice(1)}: ${s.pageSlug}
- **Location**: ${s.sectionId ?? 'Page-level'}
- **Effort**: ${effortBadge}
- **Source**: ${s.source}

**Current:**
> ${s.original}

**Suggested:**
> ${s.suggested}

**Rationale:** ${s.rationale}

---
`;
}
