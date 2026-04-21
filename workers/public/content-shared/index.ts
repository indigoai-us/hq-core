/**
 * @hq/content-shared
 * Shared utilities for content analysis workers
 */

// Types
export * from './lib/types.js';

// Parser utilities
export {
  parsePageContent,
  parsePageFile,
  parseCMSContent,
  extractAllText,
  extractHeadings,
  extractCTAs,
  extractParagraphsBySection,
  findSectionsWithKeywords,
  countWords,
  extractSentences,
  extractAnalysisInput,
} from './lib/parser.js';

// Scorer utilities
export {
  calculateOverallScore,
  createCategory,
  scoreFromFindings,
  getGrade,
  getScoreLabel,
  countBySeverity,
  sortBySeverity,
  calculateMatchPercentage,
  normalizeScore
} from './lib/scorer.js';

// Reporter utilities
export {
  generateMarkdownReport,
  generateReportFilename,
  createReportMeta,
  formatReportDate
} from './lib/reporter.js';

// Brand Analyzer (US-007)
export {
  analyzeBrandVoice,
  BRAND_ATTRIBUTES,
  DEFAULT_BRAND_GUIDELINES,
} from './lib/brand-analyzer.js';

// Conversion Analyzer (US-008)
export {
  analyzeConversion,
  CONVERSION_ELEMENTS,
} from './lib/conversion-analyzer.js';

// Accuracy Analyzer (US-009)
export {
  analyzeAccuracy,
  checkStatValidity,
  DEFAULT_PRODUCT_DATA,
} from './lib/accuracy-analyzer.js';

// Compliance Analyzer (US-010)
export {
  analyzeCompliance,
  REGULATED_TERMS,
} from './lib/compliance-analyzer.js';

// Unified Analyzer
export {
  analyzePageFull,
  analyzePages,
  analyzeFromInput,
  summarizeAnalysis,
  compareAnalyses,
  generateActionItems,
} from './lib/analyze.js';

// Recommendations (US-011)
export {
  generateSuggestions,
  enhanceSuggestion,
  generateSuggestionsForPages,
  getAllSuggestionsSorted,
  formatSuggestion,
  formatSuggestionsMarkdown,
} from './lib/recommendations.js';
export type { Suggestion, SuggestionContext } from './lib/recommendations.js';

// Priority Scoring (US-012)
export {
  calculatePriority,
  sortByPriority,
  rankSuggestions,
  groupByEffort,
  groupByImpact,
  groupBySource,
  groupByType,
  groupByPage,
  getQuickWins,
  getHighValue,
  getEasyFixes,
  getStrategicItems,
  getBacklogItems,
  getPriorityBreakdown,
  filterByMinPriority,
  filterBySource,
  filterByPage,
  getTopSuggestions,
  calculatePriorityStats,
  formatPriorityBreakdownMarkdown,
  formatPriorityStats,
  DEFAULT_PRIORITY_CONFIG,
  URGENCY_FOCUSED_CONFIG,
  EFFICIENCY_FOCUSED_CONFIG,
} from './lib/priority.js';
export type { PriorityConfig, PrioritizedSuggestion, PriorityBreakdown } from './lib/priority.js';

// A/B Copy Variants (US-013)
export {
  generateVariants,
  generateVariantForApproach,
  generateEmotionalVariant,
  generateLogicalVariant,
  generateUrgentVariant,
  generateSocialProofVariant,
  generateBenefitFocusedVariant,
  generateCTAVariants,
  formatVariantComparison,
  formatAllVariantsMarkdown,
  formatVariantTable,
  generateVariantsForTexts,
  getAllVariantTexts,
  filterVariantsByApproach,
} from './lib/variants.js';
export type { CopyVariant, VariantContext, VariantSet, VariantApproach } from './lib/variants.js';

// Section Restructuring (US-014)
export {
  analyzeStructure,
  inferTemplate,
  suggestNewSections,
  suggestReorder,
  formatStructureAnalysisMarkdown,
  formatStructureSummary,
  analyzeStructureForPages,
  sortByStructureScore,
  getPagesNeedingWork,
  PAGE_TEMPLATES,
  SECTION_TEMPLATES,
} from './lib/restructure.js';
export type {
  SectionAction,
  SectionRecommendation,
  PageSection,
  StructureAnalysis,
  PageTemplate,
} from './lib/restructure.js';

// Full Report Generation (US-015)
export {
  generateFullReport,
  generateExecutiveSummary,
  generatePageReport,
  generateComparisonReport,
  writeReport,
  generateReportPath,
  saveFullReport,
  saveExecutiveSummary,
  saveComparisonReport,
  DEFAULT_REPORT_CONFIG,
} from './lib/reporter.js';
export type { ReportConfig } from './lib/reporter.js';

// GitHub Integration (US-016, US-017)
export {
  createIssueFromSuggestion,
  createIssuesFromAnalysis,
  formatIssueBody,
  createPRFromSuggestions,
  applySuggestionToContent,
  generateCommitMessage,
  generateGitHubIssueCommand,
  generateGitHubPRCommand,
  createHighImpactIssues,
  createIssuesByPage,
  DEFAULT_GITHUB_CONFIG,
} from './lib/github-integration.js';
export type {
  GitHubIssue,
  GitHubPR,
  GitHubConfig,
} from './lib/github-integration.js';

// CMS Integration (US-018)
export {
  createCMSClient,
  createDryRunCMSClient,
  toCMSSuggestion,
  toCMSSuggestions,
  syncSuggestionStatus,
  syncSuggestionStatuses,
  formatCMSSuggestionForReview,
  formatSuggestionsForReview,
  DEFAULT_CMS_CONFIG,
} from './lib/cms-integration.js';
export type {
  CMSSuggestion,
  CMSClientConfig,
  CMSClientInstance,
  CMSSubmitResult,
  CMSBatchResult,
  CMSSuggestionStatus,
} from './lib/cms-integration.js';

// Unified Output Manager
export {
  processAnalysisOutput,
  processMultiplePages,
  generatePRFromApprovedSuggestions,
  summarizeOutputResults,
  formatOutputResultJSON,
  reportOnly,
  issuesOnly,
  cmsOnly,
  runFullPipeline,
  DEFAULT_OUTPUT_CONFIG,
} from './lib/output.js';
export type {
  OutputConfig,
  OutputResult,
} from './lib/output.js';
