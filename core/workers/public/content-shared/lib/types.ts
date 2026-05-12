/**
 * Shared types for content analysis workers
 */

// Page content structure from JSON extraction
export interface PageContent {
  url: string;
  title: string;
  meta: PageMeta;
  sections: ContentSection[];
  ctas: CTA[];
  images: ImageAsset[];
  extractedAt: string;
}

export interface PageMeta {
  description?: string;
  keywords?: string[];
  ogTitle?: string;
  ogDescription?: string;
  ogImage?: string;
}

export interface ContentSection {
  id: string;
  type: 'hero' | 'features' | 'testimonials' | 'pricing' | 'cta' | 'content' | 'footer' | 'header' | 'other';
  heading?: string;
  subheading?: string;
  paragraphs: string[];
  bulletPoints?: string[];
}

export interface CTA {
  text: string;
  href?: string;
  type: 'primary' | 'secondary' | 'link';
  location: string; // section id or description
}

export interface ImageAsset {
  src: string;
  alt?: string;
  context: string; // surrounding text or section
}

// Analysis result types
export interface AnalysisResult {
  workerId: string;
  pageUrl: string;
  analyzedAt: string;
  overallScore: number;
  categories: ScoreCategory[];
  findings: Finding[];
  recommendations: Recommendation[];
}

export interface ScoreCategory {
  name: string;
  score: number;
  maxScore: number;
  weight: number;
  details?: string;
}

export interface Finding {
  severity: 'critical' | 'warning' | 'info' | 'pass';
  category: string;
  message: string;
  location?: string;
  evidence?: string;
}

export interface Recommendation {
  priority: 'high' | 'medium' | 'low';
  category: string;
  current: string;
  suggested: string;
  rationale: string;
}

// Worker configuration
export interface WorkerConfig {
  id: string;
  name: string;
  type: 'ContentWorker';
  version: string;
  knowledgePaths: string[];
  outputDestination: string;
}

// Report metadata
export interface ReportMeta {
  generatedAt: string;
  workerId: string;
  pageAnalyzed: string;
  version: string;
}

// ============================================
// Analysis Input Types (US-006)
// ============================================

/**
 * Structured input for analysis modules
 */
export interface AnalysisInput {
  pageSlug: string;
  title: string;
  headings: string[];
  paragraphs: string[];
  ctas: { text: string; link: string }[];
  stats: { value: string; label: string }[];
  claims: string[];
  sections: SectionAnalysis[];
}

export interface SectionAnalysis {
  id: string;
  type: ContentSection['type'];
  heading: string;
  content: string[];
  wordCount: number;
}

// ============================================
// Brand Analysis Types (US-007)
// ============================================

export interface BrandGuidelines {
  voiceAttributes: string[];
  toneDescriptors: string[];
  approvedTerms: string[];
  avoidTerms: string[];
  messagingPillars: string[];
}

export interface BrandAnalysis {
  overallScore: number;
  toneScore: number;
  messagingScore: number;
  clarityScore: number;
  findings: Finding[];
  recommendations: Recommendation[];
}

// ============================================
// Conversion Analysis Types (US-008)
// ============================================

export interface ConversionAnalysis {
  overallScore: number;
  ctaScore: number;
  valuePropScore: number;
  urgencyScore: number;
  socialProofScore: number;
  findings: Finding[];
  recommendations: Recommendation[];
}

// ============================================
// Accuracy Analysis Types (US-009)
// ============================================

export interface ProductData {
  productName: string;
  features: string[];
  stats: Record<string, string>;
  certifications: string[];
  integrations: string[];
  lastUpdated: string;
}

export interface AccuracyAnalysis {
  overallScore: number;
  claimsVerified: number;
  claimsUnverified: number;
  statsFound: number;
  statsOutdated: number;
  findings: Finding[];
  recommendations: Recommendation[];
}

// ============================================
// Compliance Analysis Types (US-010)
// ============================================

export interface RegulatedTerm {
  term: string;
  location: string;
  requiresProof: boolean;
  hasProof: boolean;
  disclaimer?: string;
  risk: 'high' | 'medium' | 'low';
}

export interface ComplianceAnalysis {
  overallScore: number;
  regulatedTermsFound: RegulatedTerm[];
  missingDisclaimers: string[];
  unsubstantiatedClaims: string[];
  findings: Finding[];
  recommendations: Recommendation[];
}

// ============================================
// Full Analysis Types
// ============================================

export interface AnalysisConfig {
  brandGuidelines?: BrandGuidelines;
  productData?: ProductData;
  enableBrand?: boolean;
  enableConversion?: boolean;
  enableAccuracy?: boolean;
  enableCompliance?: boolean;
}

export interface FullAnalysis {
  page: string;
  timestamp: string;
  brand?: BrandAnalysis;
  conversion?: ConversionAnalysis;
  accuracy?: AccuracyAnalysis;
  compliance?: ComplianceAnalysis;
  overallHealth: number;
  topPriorities: Recommendation[];
}
