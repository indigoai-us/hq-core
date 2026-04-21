/**
 * CMS API Integration (US-018)
 * Submit suggestions to CMS review queue
 */

import type { Suggestion } from './recommendations.js';

// ============================================
// Types
// ============================================

export interface CMSSuggestion {
  pageSlug: string;
  sectionId?: string;
  original: string;
  suggested: string;
  rationale: string;
  source: string;
  priority: 'high' | 'medium' | 'low';
}

export interface CMSClientConfig {
  baseUrl: string;
  apiKey?: string;
  timeout?: number;
}

export interface CMSClientInstance {
  config: CMSClientConfig;
  submitSuggestion: (suggestion: CMSSuggestion) => Promise<CMSSubmitResult>;
  submitSuggestions: (suggestions: CMSSuggestion[]) => Promise<CMSBatchResult>;
  getSuggestionStatus: (suggestionId: string) => Promise<CMSSuggestionStatus>;
  listPendingSuggestions: (pageSlug?: string) => Promise<CMSSuggestion[]>;
}

export interface CMSSubmitResult {
  success: boolean;
  suggestionId?: string;
  message?: string;
  error?: string;
}

export interface CMSBatchResult {
  submitted: number;
  failed: number;
  results: CMSSubmitResult[];
}

export interface CMSSuggestionStatus {
  id: string;
  status: 'pending' | 'approved' | 'rejected' | 'applied';
  reviewedBy?: string;
  reviewedAt?: string;
  comments?: string;
}

export const DEFAULT_CMS_CONFIG: CMSClientConfig = {
  baseUrl: '',
  apiKey: undefined,
  timeout: 30000,
};

// ============================================
// CMS Client Factory
// ============================================

/**
 * Create CMS client instance
 */
export function createCMSClient(config: CMSClientConfig): CMSClientInstance {
  const cfg = { ...DEFAULT_CMS_CONFIG, ...config };

  return {
    config: cfg,
    submitSuggestion: (suggestion) => submitSuggestion(cfg, suggestion),
    submitSuggestions: (suggestions) => submitSuggestions(cfg, suggestions),
    getSuggestionStatus: (id) => getSuggestionStatus(cfg, id),
    listPendingSuggestions: (pageSlug) => listPendingSuggestions(cfg, pageSlug),
  };
}

// ============================================
// CMS API Functions
// ============================================

/**
 * Submit a single suggestion to CMS review queue
 */
async function submitSuggestion(
  config: CMSClientConfig,
  suggestion: CMSSuggestion
): Promise<CMSSubmitResult> {
  if (!config.baseUrl) {
    return {
      success: false,
      error: 'CMS base URL not configured',
    };
  }

  try {
    const response = await fetch(`${config.baseUrl}/api/suggestions`, {
      method: 'POST',
      headers: buildHeaders(config),
      body: JSON.stringify(suggestion),
      signal: AbortSignal.timeout(config.timeout ?? 30000),
    });

    if (!response.ok) {
      const errorText = await response.text();
      return {
        success: false,
        error: `HTTP ${response.status}: ${errorText}`,
      };
    }

    const data = await response.json() as { id?: string; message?: string };
    return {
      success: true,
      suggestionId: data.id,
      message: data.message ?? 'Suggestion submitted successfully',
    };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error',
    };
  }
}

/**
 * Submit batch of suggestions to CMS
 */
async function submitSuggestions(
  config: CMSClientConfig,
  suggestions: CMSSuggestion[]
): Promise<CMSBatchResult> {
  const results: CMSSubmitResult[] = [];
  let submitted = 0;
  let failed = 0;

  // Process in batches of 10 to avoid overwhelming the API
  const batchSize = 10;
  for (let i = 0; i < suggestions.length; i += batchSize) {
    const batch = suggestions.slice(i, i + batchSize);

    // Submit batch in parallel
    const batchResults = await Promise.all(
      batch.map(s => submitSuggestion(config, s))
    );

    for (const result of batchResults) {
      results.push(result);
      if (result.success) {
        submitted++;
      } else {
        failed++;
      }
    }
  }

  return { submitted, failed, results };
}

/**
 * Get suggestion status from CMS
 */
async function getSuggestionStatus(
  config: CMSClientConfig,
  suggestionId: string
): Promise<CMSSuggestionStatus> {
  if (!config.baseUrl) {
    throw new Error('CMS base URL not configured');
  }

  const response = await fetch(
    `${config.baseUrl}/api/suggestions/${suggestionId}`,
    {
      method: 'GET',
      headers: buildHeaders(config),
      signal: AbortSignal.timeout(config.timeout ?? 30000),
    }
  );

  if (!response.ok) {
    throw new Error(`Failed to get suggestion status: HTTP ${response.status}`);
  }

  return response.json() as Promise<CMSSuggestionStatus>;
}

/**
 * List pending suggestions from CMS
 */
async function listPendingSuggestions(
  config: CMSClientConfig,
  pageSlug?: string
): Promise<CMSSuggestion[]> {
  if (!config.baseUrl) {
    throw new Error('CMS base URL not configured');
  }

  const url = new URL(`${config.baseUrl}/api/suggestions`);
  url.searchParams.set('status', 'pending');
  if (pageSlug) {
    url.searchParams.set('pageSlug', pageSlug);
  }

  const response = await fetch(url.toString(), {
    method: 'GET',
    headers: buildHeaders(config),
    signal: AbortSignal.timeout(config.timeout ?? 30000),
  });

  if (!response.ok) {
    throw new Error(`Failed to list suggestions: HTTP ${response.status}`);
  }

  const data = await response.json() as { suggestions: CMSSuggestion[] };
  return data.suggestions;
}

/**
 * Build request headers
 */
function buildHeaders(config: CMSClientConfig): Record<string, string> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };

  if (config.apiKey) {
    headers['Authorization'] = `Bearer ${config.apiKey}`;
  }

  return headers;
}

// ============================================
// Suggestion Conversion
// ============================================

/**
 * Convert internal suggestion to CMS format
 */
export function toCMSSuggestion(suggestion: Suggestion): CMSSuggestion {
  return {
    pageSlug: suggestion.pageSlug,
    sectionId: suggestion.sectionId,
    original: suggestion.original,
    suggested: suggestion.suggested,
    rationale: suggestion.rationale,
    source: formatSource(suggestion.source),
    priority: suggestion.impact,
  };
}

/**
 * Convert batch of suggestions to CMS format
 */
export function toCMSSuggestions(suggestions: Suggestion[]): CMSSuggestion[] {
  return suggestions.map(toCMSSuggestion);
}

/**
 * Format source for CMS
 */
function formatSource(source: Suggestion['source']): string {
  const sourceMap: Record<Suggestion['source'], string> = {
    brand: 'Brand Voice Analysis',
    sales: 'Conversion Analysis',
    product: 'Product Accuracy Check',
    legal: 'Compliance Review',
  };
  return sourceMap[source] ?? source;
}

// ============================================
// Status Sync
// ============================================

/**
 * Sync suggestion status from CMS
 */
export async function syncSuggestionStatus(
  client: CMSClientInstance,
  suggestionId: string
): Promise<string> {
  const status = await client.getSuggestionStatus(suggestionId);
  return status.status;
}

/**
 * Sync multiple suggestion statuses
 */
export async function syncSuggestionStatuses(
  client: CMSClientInstance,
  suggestionIds: string[]
): Promise<Map<string, string>> {
  const statuses = new Map<string, string>();

  // Fetch in parallel with rate limiting
  const batchSize = 5;
  for (let i = 0; i < suggestionIds.length; i += batchSize) {
    const batch = suggestionIds.slice(i, i + batchSize);
    const results = await Promise.all(
      batch.map(async (id) => {
        try {
          const status = await syncSuggestionStatus(client, id);
          return { id, status };
        } catch {
          return { id, status: 'unknown' };
        }
      })
    );

    for (const { id, status } of results) {
      statuses.set(id, status);
    }
  }

  return statuses;
}

// ============================================
// Dry Run / Preview Mode
// ============================================

/**
 * Create a dry-run CMS client that logs instead of submitting
 */
export function createDryRunCMSClient(): CMSClientInstance {
  const dryRunResults: CMSSuggestion[] = [];

  return {
    config: { baseUrl: 'dry-run://localhost' },

    async submitSuggestion(suggestion: CMSSuggestion): Promise<CMSSubmitResult> {
      dryRunResults.push(suggestion);
      console.log('[DRY RUN] Would submit suggestion:', suggestion.pageSlug);
      return {
        success: true,
        suggestionId: `dry-run-${Date.now()}`,
        message: 'Dry run - not actually submitted',
      };
    },

    async submitSuggestions(suggestions: CMSSuggestion[]): Promise<CMSBatchResult> {
      const results: CMSSubmitResult[] = [];
      for (const s of suggestions) {
        const result = await this.submitSuggestion(s);
        results.push(result);
      }
      return {
        submitted: suggestions.length,
        failed: 0,
        results,
      };
    },

    async getSuggestionStatus(id: string): Promise<CMSSuggestionStatus> {
      return {
        id,
        status: 'pending',
        comments: 'Dry run mode - no actual status available',
      };
    },

    async listPendingSuggestions(): Promise<CMSSuggestion[]> {
      return dryRunResults;
    },
  };
}

// ============================================
// Formatting for Review
// ============================================

/**
 * Format CMS suggestion for human review
 */
export function formatCMSSuggestionForReview(suggestion: CMSSuggestion): string {
  const lines: string[] = [];

  lines.push(`## ${suggestion.pageSlug}${suggestion.sectionId ? ` > ${suggestion.sectionId}` : ''}`);
  lines.push('');
  lines.push(`**Priority:** ${suggestion.priority}`);
  lines.push(`**Source:** ${suggestion.source}`);
  lines.push('');
  lines.push('### Current');
  lines.push('```');
  lines.push(suggestion.original);
  lines.push('```');
  lines.push('');
  lines.push('### Suggested');
  lines.push('```');
  lines.push(suggestion.suggested);
  lines.push('```');
  lines.push('');
  lines.push(`**Rationale:** ${suggestion.rationale}`);
  lines.push('');

  return lines.join('\n');
}

/**
 * Format batch of suggestions as review document
 */
export function formatSuggestionsForReview(suggestions: CMSSuggestion[]): string {
  const lines: string[] = [];

  lines.push('# CMS Suggestions Review');
  lines.push('');
  lines.push(`**Total Suggestions:** ${suggestions.length}`);
  lines.push(`**Generated:** ${new Date().toISOString()}`);
  lines.push('');

  // Group by priority
  const high = suggestions.filter(s => s.priority === 'high');
  const medium = suggestions.filter(s => s.priority === 'medium');
  const low = suggestions.filter(s => s.priority === 'low');

  if (high.length > 0) {
    lines.push('# High Priority');
    lines.push('');
    for (const s of high) {
      lines.push(formatCMSSuggestionForReview(s));
    }
  }

  if (medium.length > 0) {
    lines.push('# Medium Priority');
    lines.push('');
    for (const s of medium) {
      lines.push(formatCMSSuggestionForReview(s));
    }
  }

  if (low.length > 0) {
    lines.push('# Low Priority');
    lines.push('');
    for (const s of low) {
      lines.push(formatCMSSuggestionForReview(s));
    }
  }

  return lines.join('\n');
}
