import {
  Codex,
  type CodexOptions,
  type Thread,
  type ThreadItem,
  type FileChangeItem,
  type RunResult,
  type TurnOptions,
  type Input,
} from '@openai/codex-sdk';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** Structured result returned by CodexClient.runTask(). */
export interface CodexResult {
  /** The agent's final natural-language (or JSON) response. */
  response: string;
  /** Thread identifier — use to resume the conversation later. */
  threadId: string;
  /**
   * Files changed during the turn.
   * Populated from SDK file_change items when available; empty array otherwise
   * (callers can fall back to git-diff for accuracy).
   */
  filesChanged: string[];
  /** Short human-readable summary of what the turn did. */
  summary: string;
}

/** Structured error emitted by CodexClient operations. */
export interface CodexError {
  /** Machine-readable error code. */
  code: string;
  /** Human-readable description. */
  message: string;
  /** Whether the caller should retry the operation. */
  retryable: boolean;
}

/** Options accepted by the CodexClient constructor. */
export interface CodexClientOptions {
  /** Model identifier. Defaults to env CODEX_MODEL or 'gpt-5.1-codex-max'. */
  model?: string;
}

/** Options forwarded to thread.run(). */
export interface RunTaskOptions {
  /** JSON schema for structured output. */
  outputSchema?: TurnOptions['outputSchema'];
  /** AbortSignal to cancel the turn. */
  signal?: AbortSignal;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Type guard: is this ThreadItem a file_change item? */
function isFileChangeItem(item: ThreadItem): item is FileChangeItem {
  return item.type === 'file_change';
}

/**
 * Classify an unknown error into a CodexError.
 * Maps common failure modes to machine-readable codes.
 */
function toCodexError(err: unknown): CodexError {
  const message = err instanceof Error ? err.message : String(err);

  // Auth failures — provide actionable instructions
  if (
    message.includes('401') ||
    message.includes('Unauthorized') ||
    message.includes('auth') ||
    message.includes('API key')
  ) {
    return {
      code: 'AUTH_FAILED',
      message: 'Codex auth expired. Run: codex login (or export CODEX_API_KEY="sk-...")',
      retryable: false,
    };
  }

  // Rate limits
  if (message.includes('429') || message.includes('rate limit')) {
    return { code: 'RATE_LIMITED', message, retryable: true };
  }

  // Server errors (500, 503) — retryable
  if (message.includes('500') || message.includes('503') || message.includes('Internal Server Error') || message.includes('Service Unavailable')) {
    return { code: 'SERVER_ERROR', message, retryable: true };
  }

  // Timeout / network
  if (
    message.includes('timeout') ||
    message.includes('ETIMEDOUT') ||
    message.includes('ECONNREFUSED') ||
    message.includes('aborted')
  ) {
    return { code: 'NETWORK_ERROR', message, retryable: true };
  }

  // Thread not found (resume)
  if (message.includes('not found') || message.includes('no such thread')) {
    return { code: 'THREAD_NOT_FOUND', message, retryable: false };
  }

  // Fallback
  return { code: 'UNKNOWN', message, retryable: false };
}

/**
 * Log an error with structured context for observability.
 */
function logError(context: {
  timestamp: string;
  toolName?: string;
  errorCode: string;
  threadId?: string;
  message: string;
  attempt?: number;
}): void {
  const parts = [
    `[${context.timestamp}]`,
    `[${context.errorCode}]`,
  ];
  if (context.toolName) parts.push(`tool=${context.toolName}`);
  if (context.threadId) parts.push(`thread=${context.threadId}`);
  if (context.attempt !== undefined) parts.push(`attempt=${context.attempt}`);
  parts.push(context.message);
  console.error(parts.join(' '));
}

/** Options for the retry wrapper. */
interface RetryOptions {
  maxRetries?: number;
  baseDelay?: number;
  threadId?: string;
  toolName?: string;
}

/**
 * Generic retry wrapper with exponential backoff.
 *
 * - Max 3 retries for retryable errors (RATE_LIMITED, NETWORK_ERROR, SERVER_ERROR)
 * - Backoff: 1s, 3s, 9s (multiply by 3 each attempt)
 * - For RATE_LIMITED: respects Retry-After hint if found in error message
 * - Non-retryable errors (AUTH_FAILED, THREAD_NOT_FOUND) fail immediately
 */
async function withRetry<T>(
  fn: () => Promise<T>,
  options?: RetryOptions,
): Promise<T> {
  const maxRetries = options?.maxRetries ?? 3;
  const baseDelay = options?.baseDelay ?? 1000;
  const threadId = options?.threadId;
  const toolName = options?.toolName;

  let lastError: unknown;

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (err: unknown) {
      lastError = err;
      const codexErr = toCodexError(err);

      // Log every error occurrence
      logError({
        timestamp: new Date().toISOString(),
        toolName,
        errorCode: codexErr.code,
        threadId,
        message: codexErr.message,
        attempt: attempt + 1,
      });

      // Non-retryable → fail immediately
      if (!codexErr.retryable) {
        throw err;
      }

      // Exhausted retries
      if (attempt >= maxRetries) {
        break;
      }

      // Calculate delay — exponential backoff (base * 3^attempt)
      let delay = baseDelay * Math.pow(3, attempt);

      // For rate limits, try to parse Retry-After from the error message
      if (codexErr.code === 'RATE_LIMITED') {
        const rawMessage = err instanceof Error ? err.message : String(err);
        const retryAfterMatch = rawMessage.match(/retry[- ]?after[:\s]*(\d+)/i);
        if (retryAfterMatch?.[1]) {
          const retryAfterSecs = parseInt(retryAfterMatch[1], 10);
          if (!isNaN(retryAfterSecs) && retryAfterSecs > 0) {
            delay = retryAfterSecs * 1000;
          }
        }
      }

      // Log retry attempt
      logError({
        timestamp: new Date().toISOString(),
        toolName,
        errorCode: codexErr.code,
        threadId,
        message: `Retrying in ${delay}ms (attempt ${attempt + 1}/${maxRetries})`,
        attempt: attempt + 1,
      });

      await new Promise((resolve) => setTimeout(resolve, delay));
    }
  }

  // All retries exhausted — rethrow last error
  throw lastError;
}

/**
 * Extract changed file paths from the items produced during a turn.
 * The SDK emits `file_change` items with a `changes` array; we flatten
 * those into a deduplicated list of paths.
 */
function extractFilesChanged(items: ThreadItem[]): string[] {
  const paths = new Set<string>();
  for (const item of items) {
    if (isFileChangeItem(item)) {
      for (const change of item.changes) {
        paths.add(change.path);
      }
    }
  }
  return Array.from(paths);
}

/**
 * Derive a short summary from the final response.
 * Takes the first sentence (up to 200 chars) as a pragmatic default.
 */
function deriveSummary(response: string): string {
  const maxLen = 200;
  const firstSentence = response.split(/(?<=[.!?])\s/)[0] ?? response;
  if (firstSentence.length <= maxLen) {
    return firstSentence;
  }
  return firstSentence.slice(0, maxLen - 3) + '...';
}

// ---------------------------------------------------------------------------
// CodexClient
// ---------------------------------------------------------------------------

/**
 * High-level wrapper around `@openai/codex-sdk`.
 *
 * Handles auth validation, thread lifecycle, error classification, and
 * result normalisation so that MCP tool handlers stay thin.
 */
export class CodexClient {
  private readonly codex: Codex;
  private readonly model: string;

  constructor(options: CodexClientOptions = {}) {
    // Resolve model — explicit option > env var > default
    this.model =
      options.model ??
      process.env['CODEX_MODEL'] ??
      'gpt-5.4-mini';

    // Auth gate: CODEX_API_KEY must be set
    const apiKey = process.env['CODEX_API_KEY'];
    if (!apiKey) {
      throw new Error(
        'CODEX_API_KEY environment variable is not set. ' +
          'Set it to your OpenAI API key: export CODEX_API_KEY="sk-..."',
      );
    }

    // Instantiate the SDK
    const sdkOptions: CodexOptions = {
      apiKey,
    };

    this.codex = new Codex(sdkOptions);
  }

  // -----------------------------------------------------------------------
  // Thread management
  // -----------------------------------------------------------------------

  /**
   * Start a new Codex thread rooted at `cwd`.
   * Skips the git-repo check so the engine can operate in any directory.
   */
  createThread(cwd: string): Thread {
    try {
      return this.codex.startThread({
        model: this.model,
        workingDirectory: cwd,
        skipGitRepoCheck: true,
      });
    } catch (err: unknown) {
      const codexErr = toCodexError(err);
      logError({
        timestamp: new Date().toISOString(),
        toolName: 'createThread',
        errorCode: codexErr.code,
        message: `Failed to create thread: ${codexErr.message}`,
      });
      throw new Error(
        `[${codexErr.code}] Failed to create thread: ${codexErr.message}`,
      );
    }
  }

  /**
   * Resume a previously-started thread by its ID.
   */
  resumeThread(threadId: string): Thread {
    try {
      return this.codex.resumeThread(threadId, {
        model: this.model,
      });
    } catch (err: unknown) {
      const codexErr = toCodexError(err);
      logError({
        timestamp: new Date().toISOString(),
        toolName: 'resumeThread',
        errorCode: codexErr.code,
        threadId,
        message: `Failed to resume thread: ${codexErr.message}`,
      });
      throw new Error(
        `[${codexErr.code}] Failed to resume thread "${threadId}": ${codexErr.message}`,
      );
    }
  }

  // -----------------------------------------------------------------------
  // Task execution
  // -----------------------------------------------------------------------

  /**
   * Run a prompt on a thread and return a normalised CodexResult.
   *
   * Internally adds:
   * - **Retry logic**: up to 3 retries with exponential backoff for transient errors
   * - **5-minute timeout**: AbortController enforced; on timeout the error includes
   *   the threadId so callers can resume
   *
   * @param thread  - Thread obtained from `createThread` or `resumeThread`.
   * @param prompt  - Natural-language (or structured) input.
   * @param options - Optional turn-level settings (outputSchema, signal).
   */
  async runTask(
    thread: Thread,
    prompt: Input,
    options?: RunTaskOptions,
  ): Promise<CodexResult> {
    const threadId = thread.id ?? '';
    const TIMEOUT_MS = 5 * 60 * 1000; // 5 minutes

    const turn = await withRetry<RunResult>(
      async () => {
        // Build turn options, layering in a timeout AbortController
        const turnOptions: TurnOptions = {};
        if (options?.outputSchema !== undefined) {
          turnOptions.outputSchema = options.outputSchema;
        }

        // Timeout: create an AbortController that fires after 5 min.
        // If the caller already supplied a signal, we link both so either can abort.
        const timeoutController = new AbortController();
        const timer = setTimeout(() => timeoutController.abort(), TIMEOUT_MS);

        // If caller provided a signal, propagate its abort to our controller
        if (options?.signal) {
          if (options.signal.aborted) {
            clearTimeout(timer);
            timeoutController.abort();
          } else {
            options.signal.addEventListener(
              'abort',
              () => {
                clearTimeout(timer);
                timeoutController.abort();
              },
              { once: true },
            );
          }
        }

        turnOptions.signal = timeoutController.signal;

        try {
          const result = await thread.run(prompt, turnOptions);
          return result;
        } catch (err: unknown) {
          // Re-classify timeout aborts with thread context for resume
          if (timeoutController.signal.aborted && !(options?.signal?.aborted)) {
            throw new Error(
              `Codex run timed out after ${TIMEOUT_MS / 1000}s. ` +
              `Resume with threadId="${threadId}"`,
            );
          }
          throw err;
        } finally {
          clearTimeout(timer);
        }
      },
      { maxRetries: 3, threadId, toolName: 'runTask' },
    ).catch((err: unknown) => {
      const codexErr = toCodexError(err);

      // Log the final failure with full context
      logError({
        timestamp: new Date().toISOString(),
        toolName: 'runTask',
        errorCode: codexErr.code,
        threadId,
        message: `Task execution failed: ${codexErr.message}`,
      });

      const threadSuffix = threadId ? ` (threadId="${threadId}")` : '';
      throw new Error(
        `[${codexErr.code}] Task execution failed${threadSuffix}: ${codexErr.message}`,
      );
    });

    const filesChanged = extractFilesChanged(turn.items);
    const response = turn.finalResponse;

    return {
      response,
      threadId,
      filesChanged,
      summary: deriveSummary(response),
    };
  }
}
