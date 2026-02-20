import { logger } from '../lib/logger.js';
import { AgentValidationError } from './agent-errors.js';

/**
 * Error classification for agent spawn/resume operations.
 * Categorizes errors to determine retry strategy and recovery hints.
 */
export type AgentErrorType =
  | 'validation'    // Input validation failure (non-retryable)
  | 'rate_limit'    // API rate limit (429)
  | 'quota_exceeded' // API quota exceeded (403, over_quota)
  | 'timeout'       // Operation timeout
  | 'crash'         // Agent process crash or unexpected failure
  | 'network'       // Network connectivity issue
  | 'unknown';      // Unknown error type

export interface ClassifiedError {
  type: AgentErrorType;
  message: string;
  retryable: boolean;
  recoveryHint: string;
  originalError: Error;
}

/**
 * Classify an error to determine appropriate handling strategy.
 */
export class AgentErrorClassifier {
  static classify(error: Error): ClassifiedError {
    const msg = error.message.toLowerCase();

    // Validation errors (non-retryable)
    if (error instanceof AgentValidationError) {
      return {
        type: 'validation',
        message: error.message,
        retryable: false,
        recoveryHint: error.recoveryHint,
        originalError: error,
      };
    }

    // Rate limit detection (HTTP 429 or rate_limit_error)
    if (msg.includes('429') || msg.includes('rate limit') || msg.includes('too many requests')) {
      return {
        type: 'rate_limit',
        message: error.message,
        retryable: true,
        recoveryHint: 'API rate limit reached. Waiting before retry. Consider reducing maxTurns or spacing out requests.',
        originalError: error,
      };
    }

    // Quota exceeded (HTTP 403, over_quota)
    if (msg.includes('403') || msg.includes('quota') || msg.includes('insufficient_quota')) {
      return {
        type: 'quota_exceeded',
        message: error.message,
        retryable: false,
        recoveryHint: 'API quota exceeded. Check your API key limits at console.anthropic.com/settings/limits',
        originalError: error,
      };
    }

    // Timeout detection
    if (msg.includes('timeout') || msg.includes('timed out') || msg.includes('504')) {
      return {
        type: 'timeout',
        message: error.message,
        retryable: true,
        recoveryHint: 'Agent operation timed out. Increase timeoutMs in layer config or reduce task complexity.',
        originalError: error,
      };
    }

    // Network errors (connection refused, network unreachable, etc.)
    if (
      msg.includes('econnrefused') ||
      msg.includes('enotfound') ||
      msg.includes('econnreset') ||
      msg.includes('enetunreach') ||
      msg.includes('network unreachable') ||
      msg.includes('connection refused') ||
      msg.includes('connection reset')
    ) {
      return {
        type: 'network',
        message: error.message,
        retryable: true,
        recoveryHint: 'Network connectivity issue. Check internet connection and API endpoint availability.',
        originalError: error,
      };
    }

    // Process crash (exit code, killed, etc.)
    if (msg.includes('exited') || msg.includes('crashed') || msg.includes('killed') || msg.includes('signal')) {
      return {
        type: 'crash',
        message: error.message,
        retryable: true,
        recoveryHint: 'Agent process crashed unexpectedly. This may indicate a bug or resource constraint.',
        originalError: error,
      };
    }

    // Unknown error type
    return {
      type: 'unknown',
      message: error.message,
      retryable: true,
      recoveryHint: 'Unexpected error occurred. Check logs for details.',
      originalError: error,
    };
  }
}

/**
 * Exponential backoff with jitter for retries.
 */
export class ExponentialBackoff {
  private attempt: number = 0;

  constructor(
    private readonly maxRetries: number = 3,
    private readonly baseDelayMs: number = 1000,
    private readonly maxDelayMs: number = 32000,
  ) {}

  /**
   * Get the next delay duration with jitter.
   * Returns null if max retries exceeded.
   */
  getNextDelay(): number | null {
    if (this.attempt >= this.maxRetries) {
      return null;
    }

    // Exponential: baseDelay * 2^attempt
    const exponentialDelay = this.baseDelayMs * Math.pow(2, this.attempt);
    const cappedDelay = Math.min(exponentialDelay, this.maxDelayMs);

    // Add 0-25% jitter to prevent thundering herd
    const jitter = cappedDelay * 0.25 * Math.random();
    const delay = cappedDelay + jitter;

    this.attempt++;
    return Math.floor(delay);
  }

  reset(): void {
    this.attempt = 0;
  }

  get attemptsRemaining(): number {
    return Math.max(0, this.maxRetries - this.attempt);
  }

  get currentAttempt(): number {
    return this.attempt;
  }
}

/**
 * Circuit breaker to prevent cascading failures.
 * Opens (fails fast) after N consecutive failures, resets after timeout.
 */
export class CircuitBreaker {
  private failureCount: number = 0;
  private state: 'closed' | 'open' | 'half_open' = 'closed';
  private openedAt: number | null = null;

  constructor(
    private readonly threshold: number = 5,
    private readonly resetTimeMs: number = 60000,
  ) {}

  /**
   * Check if the circuit is open (failing fast).
   */
  isOpen(): boolean {
    // Auto-transition from open to half-open after reset time
    if (this.state === 'open' && this.openedAt) {
      const elapsed = Date.now() - this.openedAt;
      if (elapsed >= this.resetTimeMs) {
        logger.info('Circuit breaker transitioning to half-open state');
        this.state = 'half_open';
        this.openedAt = null;
      }
    }

    return this.state === 'open';
  }

  /**
   * Record a successful operation.
   */
  recordSuccess(): void {
    this.failureCount = 0;
    if (this.state === 'half_open') {
      logger.info('Circuit breaker reset to closed state after successful operation');
      this.state = 'closed';
    }
  }

  /**
   * Record a failed operation.
   * Opens the circuit if threshold is reached.
   */
  recordFailure(): void {
    this.failureCount++;

    if (this.state === 'half_open') {
      // A failure in half-open state means the problem persists — re-open
      logger.warn('Circuit breaker re-opened after half-open probe failure');
      this.state = 'open';
      this.openedAt = Date.now();
    } else if (this.failureCount >= this.threshold && this.state === 'closed') {
      logger.warn(`Circuit breaker opened after ${this.failureCount} consecutive failures`);
      this.state = 'open';
      this.openedAt = Date.now();
    }
  }

  /**
   * Get current circuit state info.
   */
  getState(): {
    state: 'closed' | 'open' | 'half_open';
    failureCount: number;
    threshold: number;
  } {
    return {
      state: this.state,
      failureCount: this.failureCount,
      threshold: this.threshold,
    };
  }

  /**
   * Force reset the circuit breaker (for testing or manual intervention).
   */
  reset(): void {
    this.failureCount = 0;
    this.state = 'closed';
    this.openedAt = null;
  }
}

/**
 * Sleep for a given number of milliseconds.
 */
function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * Enhanced retry wrapper with error classification, exponential backoff, and circuit breaker.
 *
 * @param fn - The async function to execute
 * @param label - Human-readable label for logging
 * @param options - Retry configuration
 * @param circuitBreaker - Optional circuit breaker instance
 * @returns The result of the function
 * @throws The last error if all retries are exhausted or circuit is open
 */
export async function withErrorBoundary<T>(
  fn: () => Promise<T>,
  label: string,
  options: {
    maxRetries?: number;
    baseDelayMs?: number;
    maxDelayMs?: number;
  } = {},
  circuitBreaker?: CircuitBreaker,
): Promise<T> {
  const backoff = new ExponentialBackoff(
    options.maxRetries ?? 3,
    options.baseDelayMs ?? 1000,
    options.maxDelayMs ?? 32000,
  );

  while (true) {
    // Check circuit breaker
    if (circuitBreaker?.isOpen()) {
      const state = circuitBreaker.getState();
      const error = new Error(
        `Circuit breaker open after ${state.failureCount} consecutive failures. Failing fast to prevent cascading failures.`
      );
      logger.error(`${label}: circuit breaker open, failing fast`, { state });
      throw error;
    }

    try {
      const result = await fn();

      // Success! Reset backoff and record in circuit breaker
      backoff.reset();
      circuitBreaker?.recordSuccess();

      return result;
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      const classified = AgentErrorClassifier.classify(error);

      // Log classified error with recovery hint
      logger.warn(`${label}: operation failed`, {
        errorType: classified.type,
        retryable: classified.retryable,
        attempt: backoff.currentAttempt + 1,
        attemptsRemaining: backoff.attemptsRemaining,
        message: classified.message,
        recoveryHint: classified.recoveryHint,
      });

      // Check if we should retry
      if (!classified.retryable) {
        logger.error(`${label}: non-retryable error`, {
          errorType: classified.type,
          recoveryHint: classified.recoveryHint,
        });
        circuitBreaker?.recordFailure();
        throw error;
      }

      // Get next delay
      const delay = backoff.getNextDelay();
      if (delay === null) {
        // Max retries exhausted
        logger.error(`${label}: max retries exhausted`, {
          errorType: classified.type,
          attempts: backoff.currentAttempt,
          recoveryHint: classified.recoveryHint,
        });
        circuitBreaker?.recordFailure();
        throw error;
      }

      // Wait and retry
      logger.info(`${label}: retrying after ${(delay / 1000).toFixed(1)}s`, {
        errorType: classified.type,
        attempt: backoff.currentAttempt + 1,
        maxRetries: options.maxRetries ?? 3,
        recoveryHint: classified.recoveryHint,
      });

      await sleep(delay);
    }
  }
}
