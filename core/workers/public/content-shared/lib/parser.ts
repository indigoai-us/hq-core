/**
 * Parser utilities for content analysis workers
 * Handles parsing page content from various formats
 */

import { readFileSync } from 'node:fs';
import type { PageContent, ContentSection, CTA, ImageAsset, PageMeta, AnalysisInput, SectionAnalysis } from './types.js';

/**
 * Parse page content from JSON file
 */
export function parsePageContent(json: unknown): PageContent {
  if (!isValidPageContent(json)) {
    throw new Error('Invalid page content structure');
  }
  return json as PageContent;
}

/**
 * Type guard for PageContent
 */
function isValidPageContent(obj: unknown): obj is PageContent {
  if (typeof obj !== 'object' || obj === null) return false;
  const content = obj as Record<string, unknown>;
  return (
    typeof content.url === 'string' &&
    typeof content.title === 'string' &&
    Array.isArray(content.sections)
  );
}

/**
 * Extract all text content from a page
 */
export function extractAllText(page: PageContent): string[] {
  const texts: string[] = [];

  // Title and meta
  texts.push(page.title);
  if (page.meta.description) texts.push(page.meta.description);

  // Section content
  for (const section of page.sections) {
    if (section.heading) texts.push(section.heading);
    if (section.subheading) texts.push(section.subheading);
    texts.push(...section.paragraphs);
    if (section.bulletPoints) texts.push(...section.bulletPoints);
  }

  // CTAs
  for (const cta of page.ctas) {
    texts.push(cta.text);
  }

  return texts.filter(t => t && t.trim().length > 0);
}

/**
 * Extract headings from page content
 */
export function extractHeadings(page: PageContent): string[] {
  const headings: string[] = [page.title];

  for (const section of page.sections) {
    if (section.heading) headings.push(section.heading);
    if (section.subheading) headings.push(section.subheading);
  }

  return headings.filter(h => h && h.trim().length > 0);
}

/**
 * Extract all CTAs from page
 */
export function extractCTAs(page: PageContent): CTA[] {
  return page.ctas || [];
}

/**
 * Extract paragraphs by section type
 */
export function extractParagraphsBySection(
  page: PageContent,
  sectionType: ContentSection['type']
): string[] {
  return page.sections
    .filter(s => s.type === sectionType)
    .flatMap(s => s.paragraphs);
}

/**
 * Find sections containing specific keywords
 */
export function findSectionsWithKeywords(
  page: PageContent,
  keywords: string[]
): ContentSection[] {
  const lowerKeywords = keywords.map(k => k.toLowerCase());

  return page.sections.filter(section => {
    const allText = [
      section.heading || '',
      section.subheading || '',
      ...section.paragraphs,
      ...(section.bulletPoints || [])
    ].join(' ').toLowerCase();

    return lowerKeywords.some(keyword => allText.includes(keyword));
  });
}

/**
 * Count words in content
 */
export function countWords(texts: string[]): number {
  return texts.join(' ').split(/\s+/).filter(w => w.length > 0).length;
}

/**
 * Extract sentences from text array
 */
export function extractSentences(texts: string[]): string[] {
  const combined = texts.join(' ');
  return combined.split(/[.!?]+/).map(s => s.trim()).filter(s => s.length > 0);
}

// ============================================
// File Parsing Functions (US-006)
// ============================================

/**
 * Read and parse page content from JSON file
 * Supports multiple formats: standard PageContent, CMS format, or site audit format
 */
export function parsePageFile(filePath: string): PageContent {
  const content = readFileSync(filePath, 'utf-8');
  const json = JSON.parse(content);

  // Try standard format first
  if (isValidPageContent(json)) {
    return json as PageContent;
  }

  // Try site audit format (has meta.url, content.headings/paragraphs)
  if (isSiteAuditFormat(json)) {
    return parseSiteAuditContent(json);
  }

  // Try CMS format
  return parseCMSContent(json);
}

/**
 * Check if JSON is site audit format
 */
function isSiteAuditFormat(obj: unknown): boolean {
  if (typeof obj !== 'object' || obj === null) return false;
  const data = obj as Record<string, unknown>;
  return (
    typeof data.meta === 'object' &&
    data.meta !== null &&
    typeof data.content === 'object' &&
    data.content !== null
  );
}

/**
 * Parse site audit format into PageContent
 * Site audit format: { meta: { url, title, description }, content: { headings, paragraphs, lists, ctas } }
 */
export function parseSiteAuditContent(json: unknown): PageContent {
  if (typeof json !== 'object' || json === null) {
    throw new Error('Invalid site audit content: expected object');
  }

  const data = json as Record<string, unknown>;
  const meta = data.meta as Record<string, unknown> | undefined;
  const content = data.content as Record<string, unknown> | undefined;
  const navigation = data.navigation as Record<string, unknown> | undefined;
  const media = data.media as Record<string, unknown> | undefined;

  if (!meta || !content) {
    throw new Error('Invalid site audit content: missing meta or content');
  }

  // Extract URL and title from meta
  const url = (meta.url ?? meta.path ?? '/') as string;
  const title = (meta.title ?? 'Untitled') as string;

  // Build page meta
  const pageMeta: PageMeta = {
    description: meta.description as string | undefined,
    ogTitle: meta.ogTags && typeof meta.ogTags === 'object'
      ? (meta.ogTags as Record<string, unknown>).title as string | undefined
      : undefined,
    ogDescription: meta.ogTags && typeof meta.ogTags === 'object'
      ? (meta.ogTags as Record<string, unknown>).description as string | undefined
      : undefined,
    ogImage: meta.ogTags && typeof meta.ogTags === 'object'
      ? (meta.ogTags as Record<string, unknown>).image as string | undefined
      : undefined,
  };

  // Group headings and paragraphs into sections
  const headings = Array.isArray(content.headings) ? content.headings : [];
  const paragraphs = Array.isArray(content.paragraphs) ? content.paragraphs : [];
  const lists = Array.isArray(content.lists) ? content.lists : [];

  // Build sections from headings
  const sections: ContentSection[] = [];
  let currentSection: ContentSection | null = null;
  let paragraphIndex = 0;

  for (const heading of headings) {
    if (typeof heading !== 'object' || heading === null) continue;
    const h = heading as Record<string, unknown>;
    const level = h.level as number;
    const text = h.text as string;

    if (level === 1 || level === 2) {
      // Start a new section
      if (currentSection) {
        sections.push(currentSection);
      }

      // Determine section type from heading
      const type = inferSectionType(text);

      currentSection = {
        id: `section-${sections.length}`,
        type,
        heading: text,
        paragraphs: [],
      };
    } else if (level === 3 && currentSection) {
      // Add as subheading or bullet point
      if (!currentSection.bulletPoints) {
        currentSection.bulletPoints = [];
      }
      currentSection.bulletPoints.push(text);
    }
  }

  // Push last section
  if (currentSection) {
    sections.push(currentSection);
  }

  // Distribute paragraphs across sections
  const paragraphsPerSection = Math.ceil(paragraphs.length / Math.max(sections.length, 1));
  for (let i = 0; i < sections.length; i++) {
    const start = i * paragraphsPerSection;
    const end = Math.min(start + paragraphsPerSection, paragraphs.length);
    sections[i].paragraphs = paragraphs.slice(start, end).filter(
      (p): p is string => typeof p === 'string'
    );
  }

  // If no sections created, create one with all paragraphs
  if (sections.length === 0) {
    sections.push({
      id: 'section-0',
      type: 'content',
      heading: title,
      paragraphs: paragraphs.filter((p): p is string => typeof p === 'string'),
    });
  }

  // Add bullet points from lists
  for (const list of lists) {
    if (typeof list !== 'object' || list === null) continue;
    const l = list as Record<string, unknown>;
    const items = Array.isArray(l.items) ? l.items : [];

    // Add to the last section or create one
    const targetSection = sections[sections.length - 1];
    if (targetSection) {
      if (!targetSection.bulletPoints) {
        targetSection.bulletPoints = [];
      }
      targetSection.bulletPoints.push(
        ...items.filter((i): i is string => typeof i === 'string')
      );
    }
  }

  // Extract CTAs
  const ctaData = Array.isArray(content.ctas) ? content.ctas : [];
  const ctas: CTA[] = ctaData
    .filter((c): c is Record<string, unknown> => typeof c === 'object' && c !== null)
    .map((c, index) => ({
      text: (c.text ?? 'Click here') as string,
      href: c.href as string | undefined,
      type: 'primary' as const,
      location: `cta-${index}`,
    }))
    .filter(c => c.text && c.text !== 'Manage Preferences' && c.text !== 'Accept All');

  // Extract images
  const imageData = media && Array.isArray(media.images) ? media.images : [];
  const images: ImageAsset[] = imageData
    .filter((i): i is Record<string, unknown> => typeof i === 'object' && i !== null)
    .map(i => ({
      src: (i.src ?? '') as string,
      alt: i.alt as string | undefined,
      context: '',
    }));

  return {
    url,
    title,
    meta: pageMeta,
    sections,
    ctas,
    images,
    extractedAt: (meta.capturedAt as string) ?? new Date().toISOString(),
  };
}

/**
 * Infer section type from heading text
 */
function inferSectionType(heading: string): ContentSection['type'] {
  const lower = heading.toLowerCase();

  if (lower.includes('hero') || lower.includes('welcome') || lower.includes('enterprise ai')) {
    return 'hero';
  }
  if (lower.includes('feature') || lower.includes('why') || lower.includes('benefit')) {
    return 'features';
  }
  if (lower.includes('testimonial') || lower.includes('customer') || lower.includes('review')) {
    return 'testimonials';
  }
  if (lower.includes('pricing') || lower.includes('plan') || lower.includes('package')) {
    return 'pricing';
  }
  if (lower.includes('start') || lower.includes('contact') || lower.includes('demo') || lower.includes('ready')) {
    return 'cta';
  }
  if (lower.includes('security') || lower.includes('compliance') || lower.includes('certification')) {
    return 'features';
  }
  if (lower.includes('technical') || lower.includes('specification') || lower.includes('spec')) {
    return 'content';
  }

  return 'content';
}

/**
 * Parse content from CMS JSON format (matches example-company-cms schema)
 * Handles the structure: { page: { slug, title, sections, ... } }
 */
export function parseCMSContent(json: unknown): PageContent {
  if (typeof json !== 'object' || json === null) {
    throw new Error('Invalid CMS content: expected object');
  }

  const data = json as Record<string, unknown>;

  // Handle nested page structure from CMS
  const pageData = data.page ?? data;

  if (typeof pageData !== 'object' || pageData === null) {
    throw new Error('Invalid CMS content: missing page data');
  }

  const page = pageData as Record<string, unknown>;

  // Extract URL/slug
  const slug = (page.slug ?? page.url ?? 'unknown') as string;
  const url = slug.startsWith('http') ? slug : `/${slug}`;

  // Extract title
  const title = (page.title ?? page.name ?? 'Untitled') as string;

  // Extract meta
  const meta: PageMeta = {
    description: page.description as string | undefined,
    keywords: page.keywords as string[] | undefined,
    ogTitle: page.ogTitle as string | undefined,
    ogDescription: page.ogDescription as string | undefined,
    ogImage: page.ogImage as string | undefined,
  };

  // Parse sections
  const rawSections = Array.isArray(page.sections) ? page.sections : [];
  const sections: ContentSection[] = rawSections.map((s: unknown, index: number) =>
    parseCMSSection(s, index)
  );

  // Parse CTAs
  const ctas: CTA[] = extractCTAsFromCMS(page);

  // Parse images
  const images: ImageAsset[] = extractImagesFromCMS(page);

  return {
    url,
    title,
    meta,
    sections,
    ctas,
    images,
    extractedAt: new Date().toISOString(),
  };
}

/**
 * Parse a single section from CMS format
 */
function parseCMSSection(section: unknown, index: number): ContentSection {
  if (typeof section !== 'object' || section === null) {
    return {
      id: `section-${index}`,
      type: 'other',
      paragraphs: [],
    };
  }

  const s = section as Record<string, unknown>;

  // Determine section type
  const type = mapSectionType(s.type as string | undefined, s);

  // Extract paragraphs from various possible fields
  const paragraphs: string[] = [];

  if (typeof s.content === 'string') {
    paragraphs.push(s.content);
  } else if (Array.isArray(s.content)) {
    paragraphs.push(...s.content.filter((c): c is string => typeof c === 'string'));
  }

  if (typeof s.body === 'string') {
    paragraphs.push(s.body);
  }

  if (typeof s.text === 'string') {
    paragraphs.push(s.text);
  }

  if (typeof s.description === 'string') {
    paragraphs.push(s.description);
  }

  // Extract bullet points
  const bulletPoints: string[] = [];
  if (Array.isArray(s.bullets)) {
    bulletPoints.push(...s.bullets.filter((b): b is string => typeof b === 'string'));
  }
  if (Array.isArray(s.items)) {
    for (const item of s.items) {
      if (typeof item === 'string') {
        bulletPoints.push(item);
      } else if (typeof item === 'object' && item !== null) {
        const obj = item as Record<string, unknown>;
        if (typeof obj.text === 'string') bulletPoints.push(obj.text);
        if (typeof obj.title === 'string') bulletPoints.push(obj.title);
      }
    }
  }

  return {
    id: (s.id ?? s.key ?? `section-${index}`) as string,
    type,
    heading: s.heading as string | undefined ?? s.title as string | undefined,
    subheading: s.subheading as string | undefined ?? s.subtitle as string | undefined,
    paragraphs,
    bulletPoints: bulletPoints.length > 0 ? bulletPoints : undefined,
  };
}

/**
 * Map CMS section type to our standard types
 */
function mapSectionType(
  type: string | undefined,
  section: Record<string, unknown>
): ContentSection['type'] {
  if (!type) {
    // Infer from content
    if (section.hero || section.headline) return 'hero';
    if (section.features || section.featureList) return 'features';
    if (section.testimonials || section.quotes) return 'testimonials';
    if (section.pricing || section.plans) return 'pricing';
    return 'content';
  }

  const normalized = type.toLowerCase();

  if (normalized.includes('hero')) return 'hero';
  if (normalized.includes('feature')) return 'features';
  if (normalized.includes('testimonial') || normalized.includes('quote')) return 'testimonials';
  if (normalized.includes('pricing') || normalized.includes('plan')) return 'pricing';
  if (normalized.includes('cta') || normalized.includes('action')) return 'cta';
  if (normalized.includes('footer')) return 'footer';
  if (normalized.includes('header') || normalized.includes('nav')) return 'header';

  return 'content';
}

/**
 * Extract CTAs from CMS page data
 */
function extractCTAsFromCMS(page: Record<string, unknown>): CTA[] {
  const ctas: CTA[] = [];

  // Check for explicit CTAs array
  if (Array.isArray(page.ctas)) {
    for (const cta of page.ctas) {
      if (typeof cta === 'object' && cta !== null) {
        const c = cta as Record<string, unknown>;
        ctas.push({
          text: (c.text ?? c.label ?? 'Click here') as string,
          href: c.href as string | undefined ?? c.url as string | undefined ?? c.link as string | undefined,
          type: mapCTAType(c.type as string | undefined, c.variant as string | undefined),
          location: (c.location ?? c.section ?? 'unknown') as string,
        });
      }
    }
  }

  // Extract CTAs from sections
  if (Array.isArray(page.sections)) {
    for (const section of page.sections) {
      if (typeof section !== 'object' || section === null) continue;
      const s = section as Record<string, unknown>;

      // Check for CTA in section
      if (s.cta && typeof s.cta === 'object') {
        const c = s.cta as Record<string, unknown>;
        ctas.push({
          text: (c.text ?? c.label ?? 'Click here') as string,
          href: c.href as string | undefined ?? c.url as string | undefined,
          type: mapCTAType(c.type as string | undefined, c.variant as string | undefined),
          location: (s.id ?? s.type ?? 'section') as string,
        });
      }

      // Check for buttons array
      if (Array.isArray(s.buttons)) {
        for (const btn of s.buttons) {
          if (typeof btn === 'object' && btn !== null) {
            const b = btn as Record<string, unknown>;
            ctas.push({
              text: (b.text ?? b.label ?? 'Click here') as string,
              href: b.href as string | undefined ?? b.url as string | undefined,
              type: mapCTAType(b.type as string | undefined, b.variant as string | undefined),
              location: (s.id ?? s.type ?? 'section') as string,
            });
          }
        }
      }
    }
  }

  return ctas;
}

/**
 * Map CTA type from various formats
 */
function mapCTAType(type?: string, variant?: string): CTA['type'] {
  const t = (type ?? variant ?? '').toLowerCase();
  if (t.includes('primary') || t.includes('main')) return 'primary';
  if (t.includes('secondary') || t.includes('outline')) return 'secondary';
  if (t.includes('link') || t.includes('text')) return 'link';
  return 'primary'; // Default to primary
}

/**
 * Extract images from CMS page data
 */
function extractImagesFromCMS(page: Record<string, unknown>): ImageAsset[] {
  const images: ImageAsset[] = [];

  // Check for explicit images array
  if (Array.isArray(page.images)) {
    for (const img of page.images) {
      if (typeof img === 'object' && img !== null) {
        const i = img as Record<string, unknown>;
        images.push({
          src: (i.src ?? i.url ?? '') as string,
          alt: i.alt as string | undefined,
          context: (i.context ?? i.caption ?? '') as string,
        });
      }
    }
  }

  // Extract images from sections
  if (Array.isArray(page.sections)) {
    for (const section of page.sections) {
      if (typeof section !== 'object' || section === null) continue;
      const s = section as Record<string, unknown>;

      if (s.image && typeof s.image === 'object') {
        const i = s.image as Record<string, unknown>;
        images.push({
          src: (i.src ?? i.url ?? '') as string,
          alt: i.alt as string | undefined,
          context: (s.heading ?? s.title ?? s.type ?? 'section') as string,
        });
      }

      if (typeof s.backgroundImage === 'string') {
        images.push({
          src: s.backgroundImage,
          alt: undefined,
          context: `background: ${(s.type ?? 'section') as string}`,
        });
      }
    }
  }

  return images;
}

// ============================================
// Analysis Input Extraction (US-006)
// ============================================

/**
 * Extract structured content for analysis from PageContent
 */
export function extractAnalysisInput(page: PageContent): AnalysisInput {
  const headings = extractHeadings(page);
  const paragraphs = extractAllParagraphs(page);
  const stats = extractStats(page);
  const claims = extractClaims(page);
  const sections = extractSectionAnalyses(page);

  // Extract slug from URL
  const pageSlug = extractSlug(page.url);

  return {
    pageSlug,
    title: page.title,
    headings,
    paragraphs,
    ctas: page.ctas.map(cta => ({
      text: cta.text,
      link: cta.href ?? '',
    })),
    stats,
    claims,
    sections,
  };
}

/**
 * Extract all paragraphs from page content
 */
function extractAllParagraphs(page: PageContent): string[] {
  const paragraphs: string[] = [];

  for (const section of page.sections) {
    paragraphs.push(...section.paragraphs);
    if (section.bulletPoints) {
      paragraphs.push(...section.bulletPoints);
    }
  }

  return paragraphs.filter(p => p.trim().length > 0);
}

/**
 * Extract statistics from page content
 * Looks for patterns like "50%", "$1M", "100+", "10x", etc.
 */
function extractStats(page: PageContent): { value: string; label: string }[] {
  const stats: { value: string; label: string }[] = [];
  const statPatterns = [
    // Percentages: 50%, 99.9%
    /(\d+(?:\.\d+)?%)/g,
    // Dollar amounts: $1M, $500K, $1,000
    /(\$[\d,.]+[KMB]?)/gi,
    // Multipliers: 10x, 2.5x
    /(\d+(?:\.\d+)?x)/gi,
    // Large numbers with suffixes: 100+, 1000+, 50K+
    /(\d+(?:,\d{3})*[KMB]?\+?)/g,
    // Time-based: 24/7, 99.9% uptime
    /(24\/7|\d+(?:\.\d+)?%\s*uptime)/gi,
  ];

  const allText = extractAllText(page);

  for (const text of allText) {
    for (const pattern of statPatterns) {
      const matches = text.matchAll(pattern);
      for (const match of matches) {
        const value = match[1];
        // Extract surrounding context as label
        const startIdx = Math.max(0, match.index! - 30);
        const endIdx = Math.min(text.length, match.index! + match[0].length + 30);
        const context = text.slice(startIdx, endIdx).trim();

        // Avoid duplicates
        if (!stats.some(s => s.value === value)) {
          stats.push({ value, label: context });
        }
      }
    }
  }

  return stats;
}

/**
 * Extract claims from page content
 * Looks for assertive statements, superlatives, comparisons
 */
function extractClaims(page: PageContent): string[] {
  const claims: string[] = [];
  const sentences = extractSentences(extractAllText(page));

  // Patterns that indicate claims
  const claimIndicators = [
    /\b(best|leading|top|#1|number one|premier|fastest|most|only|first)\b/i,
    /\b(guaranteed|proven|certified|trusted|secure|compliant)\b/i,
    /\b(save|reduce|increase|improve|boost|grow|eliminate)\b/i,
    /\b(never|always|every|all|100%)\b/i,
    /\b(award-winning|industry-leading|world-class|enterprise-grade)\b/i,
    /\b(more than|over|up to|\d+[x%])\b/i,
  ];

  for (const sentence of sentences) {
    const isClaimLike = claimIndicators.some(pattern => pattern.test(sentence));
    if (isClaimLike && sentence.length > 20 && sentence.length < 500) {
      claims.push(sentence);
    }
  }

  return claims;
}

/**
 * Extract section analyses from page content
 */
function extractSectionAnalyses(page: PageContent): SectionAnalysis[] {
  return page.sections.map(section => {
    const content = [
      ...section.paragraphs,
      ...(section.bulletPoints ?? []),
    ];

    const wordCount = countWords(content);

    return {
      id: section.id,
      type: section.type,
      heading: section.heading ?? '',
      content,
      wordCount,
    };
  });
}

/**
 * Extract slug from URL
 */
function extractSlug(url: string): string {
  // Remove protocol and domain if present
  let slug = url.replace(/^https?:\/\/[^\/]+/, '');
  // Remove leading/trailing slashes
  slug = slug.replace(/^\/+|\/+$/g, '');
  // Use 'home' for empty slugs
  return slug || 'home';
}
