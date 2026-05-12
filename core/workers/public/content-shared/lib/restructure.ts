/**
 * Section Restructuring Analyzer (US-014)
 * Suggests page structure improvements based on templates and best practices
 */

import type { PageContent, ContentSection } from './types.js';

// ============================================
// Types
// ============================================

export type SectionAction = 'add' | 'remove' | 'move' | 'merge' | 'split';

export interface SectionRecommendation {
  action: SectionAction;
  sectionId?: string;
  newPosition?: number;
  rationale: string;
  suggestedContent?: PageSection;
  priority: 'high' | 'medium' | 'low';
}

export interface PageSection {
  id: string;
  type: ContentSection['type'];
  heading?: string;
  description?: string;
  purpose: string;
}

export interface StructureAnalysis {
  pageSlug: string;
  templateUsed: string;
  currentSections: string[];
  missingSections: string[];
  redundantSections: string[];
  orderIssues: string[];
  recommendations: SectionRecommendation[];
  structureScore: number;
}

export type PageTemplate = 'product' | 'solution' | 'landing' | 'about' | 'pricing' | 'blog' | 'case-study';

// ============================================
// Page Templates
// ============================================

/**
 * Standard page templates defining optimal section order
 */
export const PAGE_TEMPLATES: Record<PageTemplate, string[]> = {
  product: ['hero', 'problem', 'solution', 'features', 'proof', 'pricing', 'faq', 'cta'],
  solution: ['hero', 'pain-points', 'how-it-works', 'benefits', 'features', 'case-study', 'cta'],
  landing: ['hero', 'value-prop', 'features', 'testimonials', 'social-proof', 'faq', 'cta'],
  about: ['hero', 'mission', 'story', 'team', 'values', 'contact'],
  pricing: ['hero', 'plans', 'comparison', 'features', 'faq', 'cta'],
  blog: ['header', 'content', 'author', 'related', 'cta'],
  'case-study': ['hero', 'challenge', 'solution', 'results', 'testimonial', 'cta'],
};

/**
 * Section type to template section mapping
 */
const SECTION_TYPE_MAP: Record<ContentSection['type'], string[]> = {
  hero: ['hero'],
  features: ['features', 'benefits', 'value-prop'],
  testimonials: ['testimonials', 'proof', 'social-proof', 'case-study'],
  pricing: ['pricing', 'plans', 'comparison'],
  cta: ['cta'],
  content: ['content', 'story', 'mission', 'values', 'how-it-works', 'solution', 'problem', 'pain-points', 'challenge', 'results'],
  footer: ['footer', 'contact'],
  header: ['header'],
  other: [],
};

/**
 * Recommended section content for common section types
 */
export const SECTION_TEMPLATES: Record<string, PageSection> = {
  hero: {
    id: 'hero',
    type: 'hero',
    heading: 'Headline that captures your unique value proposition',
    description: 'Supporting text that expands on the headline with specific benefits',
    purpose: 'Immediately communicate what you offer and why it matters',
  },
  problem: {
    id: 'problem',
    type: 'content',
    heading: 'The Challenge You Face',
    description: 'Describe the pain points your target audience experiences',
    purpose: 'Create resonance by articulating the problem better than the reader can',
  },
  solution: {
    id: 'solution',
    type: 'content',
    heading: 'How We Help',
    description: 'Explain your approach to solving the problem',
    purpose: 'Position your product/service as the answer to their challenge',
  },
  features: {
    id: 'features',
    type: 'features',
    heading: 'Key Features',
    description: 'List of 3-6 core features with brief descriptions',
    purpose: 'Show the specific capabilities that deliver value',
  },
  benefits: {
    id: 'benefits',
    type: 'features',
    heading: 'Benefits',
    description: 'Outcomes and results customers achieve',
    purpose: 'Translate features into tangible value for the customer',
  },
  proof: {
    id: 'proof',
    type: 'testimonials',
    heading: 'Trusted By',
    description: 'Customer testimonials, logos, case study snippets',
    purpose: 'Build credibility through social proof and third-party validation',
  },
  testimonials: {
    id: 'testimonials',
    type: 'testimonials',
    heading: 'What Our Customers Say',
    description: 'Direct quotes from satisfied customers',
    purpose: 'Let customers tell your story in their own words',
  },
  faq: {
    id: 'faq',
    type: 'content',
    heading: 'Frequently Asked Questions',
    description: 'Common questions and clear answers',
    purpose: 'Address objections and provide additional information',
  },
  cta: {
    id: 'cta',
    type: 'cta',
    heading: 'Ready to Get Started?',
    description: 'Clear call to action with next steps',
    purpose: 'Convert interest into action with a compelling offer',
  },
  pricing: {
    id: 'pricing',
    type: 'pricing',
    heading: 'Simple, Transparent Pricing',
    description: 'Clear pricing tiers with feature breakdown',
    purpose: 'Make the purchase decision easy with clear options',
  },
  'how-it-works': {
    id: 'how-it-works',
    type: 'content',
    heading: 'How It Works',
    description: '3-5 step process explaining the customer journey',
    purpose: 'Demystify the product/service and reduce perceived complexity',
  },
  'case-study': {
    id: 'case-study',
    type: 'content',
    heading: 'Success Story',
    description: 'Detailed customer success narrative',
    purpose: 'Demonstrate real-world results and build credibility',
  },
};

// ============================================
// Template Detection
// ============================================

/**
 * Infer the most likely template for a page based on its sections
 */
export function inferTemplate(page: PageContent): PageTemplate {
  const sectionTypes = page.sections.map(s => s.type);
  const sectionHeadings = page.sections.map(s => (s.heading ?? '').toLowerCase());

  // Check for pricing page indicators
  if (sectionTypes.includes('pricing') || sectionHeadings.some(h => h.includes('pricing') || h.includes('plans'))) {
    return 'pricing';
  }

  // Check for about page indicators
  if (sectionHeadings.some(h => h.includes('mission') || h.includes('team') || h.includes('story') || h.includes('about'))) {
    return 'about';
  }

  // Check for case study indicators
  if (sectionHeadings.some(h => h.includes('challenge') || h.includes('results') || h.includes('case study'))) {
    return 'case-study';
  }

  // Check for blog indicators
  if (sectionHeadings.some(h => h.includes('author') || h.includes('related posts'))) {
    return 'blog';
  }

  // Check for solution vs product page
  if (sectionHeadings.some(h => h.includes('pain') || h.includes('how it works') || h.includes('benefits'))) {
    return 'solution';
  }

  // Check for testimonials heavy pages (landing)
  if (sectionTypes.filter(t => t === 'testimonials').length >= 2) {
    return 'landing';
  }

  // Default to product page
  return 'product';
}

// ============================================
// Structure Analysis
// ============================================

/**
 * Analyze page structure against templates
 */
export function analyzeStructure(page: PageContent, template?: PageTemplate): StructureAnalysis {
  const inferredTemplate = template ?? inferTemplate(page);
  const templateSections = PAGE_TEMPLATES[inferredTemplate];
  const currentSections = extractSectionIdentifiers(page);

  // Find missing sections
  const missingSections = findMissingSections(currentSections, templateSections);

  // Find redundant sections
  const redundantSections = findRedundantSections(page, templateSections);

  // Check section ordering
  const orderIssues = checkSectionOrder(currentSections, templateSections);

  // Generate recommendations
  const recommendations = generateStructureRecommendations(
    page,
    inferredTemplate,
    missingSections,
    redundantSections,
    orderIssues
  );

  // Calculate structure score
  const structureScore = calculateStructureScore(
    currentSections.length,
    templateSections.length,
    missingSections.length,
    redundantSections.length,
    orderIssues.length
  );

  return {
    pageSlug: extractSlug(page.url),
    templateUsed: inferredTemplate,
    currentSections,
    missingSections,
    redundantSections,
    orderIssues,
    recommendations,
    structureScore,
  };
}

/**
 * Extract section identifiers from page
 */
function extractSectionIdentifiers(page: PageContent): string[] {
  return page.sections.map(section => {
    // First, try to match section type to template sections
    const mappedSections = SECTION_TYPE_MAP[section.type];
    if (mappedSections.length > 0) {
      // Check if heading gives more specific info
      const headingLower = (section.heading ?? '').toLowerCase();
      for (const mapped of mappedSections) {
        if (headingLower.includes(mapped.replace('-', ' '))) {
          return mapped;
        }
      }
      return mappedSections[0];
    }

    // Fall back to section type
    return section.type;
  });
}

/**
 * Find sections that should be present but aren't
 */
function findMissingSections(current: string[], template: string[]): string[] {
  const missing: string[] = [];

  for (const templateSection of template) {
    // Check if any current section matches this template section
    const hasMatch = current.some(c => sectionMatches(c, templateSection));
    if (!hasMatch) {
      missing.push(templateSection);
    }
  }

  return missing;
}

/**
 * Check if a current section matches a template section
 */
function sectionMatches(current: string, template: string): boolean {
  // Direct match
  if (current === template) return true;

  // Check type mappings
  for (const [type, mappings] of Object.entries(SECTION_TYPE_MAP)) {
    if (mappings.includes(current) && mappings.includes(template)) {
      return true;
    }
  }

  // Related sections
  const relatedPairs: [string, string][] = [
    ['features', 'benefits'],
    ['proof', 'testimonials'],
    ['solution', 'how-it-works'],
    ['problem', 'pain-points'],
  ];

  for (const [a, b] of relatedPairs) {
    if ((current === a && template === b) || (current === b && template === a)) {
      return true;
    }
  }

  return false;
}

/**
 * Find sections that may be redundant
 */
function findRedundantSections(page: PageContent, template: string[]): string[] {
  const redundant: string[] = [];
  const sectionCounts: Record<string, number> = {};

  for (const section of page.sections) {
    const type = section.type;
    sectionCounts[type] = (sectionCounts[type] ?? 0) + 1;

    // Multiple sections of same type (except content)
    if (sectionCounts[type] > 1 && type !== 'content') {
      redundant.push(`${type} (duplicate #${sectionCounts[type]})`);
    }
  }

  // Check for sections not in template
  for (const section of page.sections) {
    const identifiers = [section.type, section.id, (section.heading ?? '').toLowerCase()];
    const inTemplate = identifiers.some(id =>
      template.some(t => sectionMatches(id, t))
    );

    if (!inTemplate && section.type !== 'content' && section.type !== 'other') {
      if (!redundant.includes(section.id)) {
        redundant.push(section.id);
      }
    }
  }

  return redundant;
}

/**
 * Check if sections are in optimal order
 */
function checkSectionOrder(current: string[], template: string[]): string[] {
  const issues: string[] = [];

  // Map current sections to their template positions
  const positions: { section: string; currentPos: number; templatePos: number }[] = [];

  for (let i = 0; i < current.length; i++) {
    const templateIndex = template.findIndex(t => sectionMatches(current[i], t));
    if (templateIndex !== -1) {
      positions.push({
        section: current[i],
        currentPos: i,
        templatePos: templateIndex,
      });
    }
  }

  // Check for out-of-order sections
  for (let i = 0; i < positions.length - 1; i++) {
    if (positions[i].templatePos > positions[i + 1].templatePos) {
      issues.push(`"${positions[i].section}" should come after "${positions[i + 1].section}"`);
    }
  }

  // Check for hero not being first
  const heroIndex = current.findIndex(s => sectionMatches(s, 'hero'));
  if (heroIndex > 0) {
    issues.push('Hero section should be at the top of the page');
  }

  // Check for CTA not being last (for pages that should end with CTA)
  const ctaIndex = current.findIndex(s => sectionMatches(s, 'cta'));
  if (ctaIndex !== -1 && ctaIndex < current.length - 2) {
    issues.push('CTA section should be near the bottom of the page');
  }

  return issues;
}

// ============================================
// Recommendation Generation
// ============================================

/**
 * Generate structure recommendations
 */
function generateStructureRecommendations(
  page: PageContent,
  template: PageTemplate,
  missing: string[],
  redundant: string[],
  orderIssues: string[]
): SectionRecommendation[] {
  const recommendations: SectionRecommendation[] = [];
  const templateSections = PAGE_TEMPLATES[template];

  // Recommendations for missing sections
  for (const section of missing) {
    const sectionTemplate = SECTION_TEMPLATES[section];
    const priority = getMissingSectionPriority(section);

    recommendations.push({
      action: 'add',
      newPosition: templateSections.indexOf(section),
      rationale: `Add a "${section}" section to follow ${template} page best practices`,
      suggestedContent: sectionTemplate,
      priority,
    });
  }

  // Recommendations for redundant sections
  for (const section of redundant) {
    // Only suggest removal for truly redundant (not just extra content)
    if (section.includes('duplicate')) {
      recommendations.push({
        action: 'merge',
        sectionId: section.split(' ')[0],
        rationale: `Consider merging duplicate ${section.split(' ')[0]} sections for clarity`,
        priority: 'low',
      });
    } else {
      recommendations.push({
        action: 'remove',
        sectionId: section,
        rationale: `Section "${section}" may not be needed for this page type`,
        priority: 'low',
      });
    }
  }

  // Recommendations for order issues
  for (const issue of orderIssues) {
    recommendations.push({
      action: 'move',
      rationale: issue,
      priority: 'medium',
    });
  }

  // Sort by priority
  const priorityOrder: Record<SectionRecommendation['priority'], number> = {
    high: 0,
    medium: 1,
    low: 2,
  };
  recommendations.sort((a, b) => priorityOrder[a.priority] - priorityOrder[b.priority]);

  return recommendations;
}

/**
 * Determine priority for missing section
 */
function getMissingSectionPriority(section: string): 'high' | 'medium' | 'low' {
  // Critical sections
  if (['hero', 'cta', 'value-prop'].includes(section)) {
    return 'high';
  }

  // Important sections
  if (['features', 'benefits', 'proof', 'how-it-works'].includes(section)) {
    return 'medium';
  }

  // Nice to have
  return 'low';
}

/**
 * Suggest new sections to add
 */
export function suggestNewSections(page: PageContent, template: PageTemplate): SectionRecommendation[] {
  const analysis = analyzeStructure(page, template);
  return analysis.recommendations.filter(r => r.action === 'add');
}

/**
 * Suggest section reordering
 */
export function suggestReorder(page: PageContent, template: PageTemplate): SectionRecommendation[] {
  const analysis = analyzeStructure(page, template);
  return analysis.recommendations.filter(r => r.action === 'move');
}

// ============================================
// Score Calculation
// ============================================

/**
 * Calculate structure score (0-100)
 */
function calculateStructureScore(
  currentCount: number,
  templateCount: number,
  missingCount: number,
  redundantCount: number,
  orderIssueCount: number
): number {
  let score = 100;

  // Deduct for missing sections (more impact for critical ones)
  score -= missingCount * 10;

  // Deduct for redundant sections (minor impact)
  score -= redundantCount * 5;

  // Deduct for ordering issues
  score -= orderIssueCount * 8;

  // Bonus for comprehensive coverage
  if (currentCount >= templateCount * 0.8) {
    score += 5;
  }

  return Math.max(0, Math.min(100, score));
}

// ============================================
// Utility Functions
// ============================================

function extractSlug(url: string): string {
  let slug = url.replace(/^https?:\/\/[^\/]+/, '');
  slug = slug.replace(/^\/+|\/+$/g, '');
  return slug || 'home';
}

// ============================================
// Formatting
// ============================================

/**
 * Format structure analysis as markdown
 */
export function formatStructureAnalysisMarkdown(analysis: StructureAnalysis): string {
  const lines: string[] = [
    `# Structure Analysis: ${analysis.pageSlug}`,
    '',
    `**Template Used:** ${analysis.templateUsed}`,
    `**Structure Score:** ${analysis.structureScore}/100`,
    '',
  ];

  // Current sections
  lines.push('## Current Sections');
  lines.push(analysis.currentSections.map((s, i) => `${i + 1}. ${s}`).join('\n'));
  lines.push('');

  // Missing sections
  if (analysis.missingSections.length > 0) {
    lines.push('## Missing Sections');
    lines.push(analysis.missingSections.map(s => `- ${s}`).join('\n'));
    lines.push('');
  }

  // Redundant sections
  if (analysis.redundantSections.length > 0) {
    lines.push('## Potentially Redundant');
    lines.push(analysis.redundantSections.map(s => `- ${s}`).join('\n'));
    lines.push('');
  }

  // Order issues
  if (analysis.orderIssues.length > 0) {
    lines.push('## Ordering Issues');
    lines.push(analysis.orderIssues.map(s => `- ${s}`).join('\n'));
    lines.push('');
  }

  // Recommendations
  if (analysis.recommendations.length > 0) {
    lines.push('## Recommendations');
    lines.push('');

    for (const rec of analysis.recommendations) {
      const priorityBadge = rec.priority === 'high' ? '[!]' : rec.priority === 'medium' ? '[*]' : '[-]';
      lines.push(`${priorityBadge} **${rec.action.toUpperCase()}**${rec.sectionId ? ` (${rec.sectionId})` : ''}`);
      lines.push(`   ${rec.rationale}`);

      if (rec.suggestedContent) {
        lines.push(`   - Purpose: ${rec.suggestedContent.purpose}`);
        if (rec.suggestedContent.heading) {
          lines.push(`   - Suggested heading: "${rec.suggestedContent.heading}"`);
        }
      }
      lines.push('');
    }
  }

  return lines.join('\n');
}

/**
 * Format as brief summary
 */
export function formatStructureSummary(analysis: StructureAnalysis): string {
  const status = analysis.structureScore >= 80 ? 'Good' :
                 analysis.structureScore >= 60 ? 'Needs Work' : 'Poor';

  return `${analysis.pageSlug}: ${status} (${analysis.structureScore}/100) - ${analysis.recommendations.length} recommendations`;
}

// ============================================
// Batch Processing
// ============================================

/**
 * Analyze structure for multiple pages
 */
export function analyzeStructureForPages(
  pages: PageContent[],
  templates?: Record<string, PageTemplate>
): StructureAnalysis[] {
  return pages.map(page => {
    const slug = extractSlug(page.url);
    const template = templates?.[slug];
    return analyzeStructure(page, template);
  });
}

/**
 * Get pages sorted by structure score
 */
export function sortByStructureScore(analyses: StructureAnalysis[], ascending = true): StructureAnalysis[] {
  return [...analyses].sort((a, b) =>
    ascending ? a.structureScore - b.structureScore : b.structureScore - a.structureScore
  );
}

/**
 * Get pages needing structure improvements
 */
export function getPagesNeedingWork(analyses: StructureAnalysis[], threshold = 70): StructureAnalysis[] {
  return analyses.filter(a => a.structureScore < threshold);
}
