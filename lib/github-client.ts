import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash } from 'node:crypto';
import { LRUCache } from 'lru-cache';
import { logger } from './logger.js';
import type { RateLimitState } from './types.js';
import { CircuitBreaker, withErrorBoundary } from '../core/error-boundaries.js';

const execFileAsync = promisify(execFile);

interface CacheStats {
  hits: number;
  misses: number;
}

interface CachedResponse {
  stdout: string;
  stderr: string;
  timestamp: number;
}

/**
 * Exponential backoff retry with jitter.
 * @deprecated Use withErrorBoundary from core/error-boundaries.ts instead
 *
 * maxRetries = total number of attempts (e.g., maxRetries=3 means try up to 3 times)
 */
async function retryWithBackoff<T>(
  fn: () => Promise<T>,
  maxRetries = 3,
  baseDelayMs = 2000,
  maxDelayMs = 60000,
): Promise<T> {
  let lastError: Error | undefined;

  // Attempt 0 to maxRetries-1 (e.g., 0, 1, 2 for maxRetries=3)
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastError = err instanceof Error ? err : new Error(String(err));

      // Check if it's a rate limit error (429)
      const is429 = lastError.message.includes('429') ||
                    lastError.message.toLowerCase().includes('rate limit');

      // On last attempt or non-rate-limit error, throw
      if (!is429 || attempt >= maxRetries - 1) {
        throw lastError;
      }

      // Calculate exponential backoff with jitter
      const exponentialDelay = Math.min(baseDelayMs * Math.pow(2, attempt), maxDelayMs);
      const jitter = Math.random() * 0.3 * exponentialDelay; // ±30% jitter
      const delay = exponentialDelay + jitter;

      logger.warn(`GitHub API rate limit hit, retrying in ${Math.round(delay)}ms (attempt ${attempt + 1}/${maxRetries})`, {
        error: lastError.message,
      });

      await new Promise(resolve => setTimeout(resolve, delay));
    }
  }

  // Unreachable (TypeScript needs it)
  throw lastError ?? new Error('Retry logic error');
}

/**
 * GitHub CLI client with rate limiting awareness and response caching.
 */
export class GitHubClient {
  private cache: LRUCache<string, CachedResponse>;
  private cacheStats: CacheStats = { hits: 0, misses: 0 };
  private rateLimitState: RateLimitState | null = null;
  private pausedUntil: number | null = null;
  private circuitBreaker = new CircuitBreaker(5, 60000); // 5 failures, 60s reset

  constructor(
    maxCacheEntries = 500,
    cacheTtlMs = 5 * 60 * 1000, // 5 minutes
  ) {
    this.cache = new LRUCache<string, CachedResponse>({
      max: maxCacheEntries,
      ttl: cacheTtlMs,
    });
  }

  /**
   * Get circuit breaker state.
   */
  getCircuitBreakerState(): {
    state: 'closed' | 'open' | 'half_open';
    failureCount: number;
    threshold: number;
  } {
    return this.circuitBreaker.getState();
  }

  /**
   * Get current rate limit status.
   */
  getRateLimitStatus(): RateLimitState | null {
    return this.rateLimitState;
  }

  /**
   * Get cache hit/miss statistics.
   */
  getCacheStats(): CacheStats {
    return { ...this.cacheStats };
  }

  /**
   * Parse rate limit headers from gh CLI error output.
   */
  private parseRateLimitFromError(stderr: string): void {
    // gh CLI includes rate limit info in errors like:
    // "HTTP 403: API rate limit exceeded for user ID xxx. (https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting)"
    // or in X-RateLimit-* headers if we can extract them

    // Try to extract from header-like patterns
    const remainingMatch = stderr.match(/X-RateLimit-Remaining:\s*(\d+)/i);
    const limitMatch = stderr.match(/X-RateLimit-Limit:\s*(\d+)/i);
    const resetMatch = stderr.match(/X-RateLimit-Reset:\s*(\d+)/i);

    if (remainingMatch && limitMatch && resetMatch) {
      this.rateLimitState = {
        remaining: parseInt(remainingMatch[1], 10),
        limit: parseInt(limitMatch[1], 10),
        reset: parseInt(resetMatch[1], 10),
      };

      this.checkRateLimitThresholds();
    }
  }

  /**
   * Fetch current rate limit status from GitHub API.
   */
  private async fetchRateLimitStatus(): Promise<void> {
    try {
      const { stdout } = await execFileAsync('gh', [
        'api', 'rate_limit',
        '--jq', '.rate.remaining, .rate.limit, .rate.reset',
      ], { encoding: 'utf-8' });

      const lines = stdout.trim().split('\n');
      if (lines.length === 3) {
        this.rateLimitState = {
          remaining: parseInt(lines[0], 10),
          limit: parseInt(lines[1], 10),
          reset: parseInt(lines[2], 10),
        };

        this.checkRateLimitThresholds();
      }
    } catch (err) {
      // Silent fail — rate limit check is best-effort
      logger.debug('Failed to fetch rate limit status', {
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  /**
   * Check rate limit thresholds and log warnings/errors.
   */
  private checkRateLimitThresholds(): void {
    if (!this.rateLimitState) return;

    const { remaining, reset } = this.rateLimitState;
    const resetAt = new Date(reset * 1000).toISOString();

    if (remaining < 10) {
      // Pause operations until reset
      this.pausedUntil = reset * 1000;
      logger.error('GitHub rate limit exhausted, pausing until reset', {
        remaining,
        resetAt,
      });

      // Log rate limit exceeded
      logger.warn('GitHub rate limit exceeded, pausing requests', {
        resetAt,
        pausedUntil: this.pausedUntil,
      });
    } else if (remaining < 100) {
      logger.warn('GitHub rate limit low', {
        remaining,
        resetAt,
      });
    }
  }

  /**
   * Wait if we're currently paused due to rate limiting.
   */
  private async waitIfPaused(): Promise<void> {
    if (!this.pausedUntil) return;

    const now = Date.now();
    if (now < this.pausedUntil) {
      const waitMs = this.pausedUntil - now;
      logger.info(`Waiting ${Math.round(waitMs / 1000)}s for rate limit reset`, {
        resetAt: new Date(this.pausedUntil).toISOString(),
      });
      await new Promise(resolve => setTimeout(resolve, waitMs));
      this.pausedUntil = null;
    } else {
      // Reset window has passed
      this.pausedUntil = null;
    }
  }

  /**
   * Determine if a gh command is a read operation (cacheable).
   */
  private isReadOperation(args: string[]): boolean {
    if (args.length === 0) return false;

    // Read operations: issue view, pr view, api GET, etc.
    const readCommands = new Set([
      'view', 'list', 'status', 'diff', 'checks', 'api',
    ]);

    // Check if it's a read command
    const subcommand = args[1]; // args[0] is the resource (issue, pr, etc.)
    if (readCommands.has(subcommand)) return true;

    // 'api' commands with GET method
    if (args[0] === 'api' && !args.includes('--method')) {
      return true; // Default is GET
    }
    if (args[0] === 'api' && args.includes('--method')) {
      const methodIdx = args.indexOf('--method');
      const method = args[methodIdx + 1];
      return method?.toUpperCase() === 'GET';
    }

    return false;
  }

  /**
   * Generate cache key from gh command arguments.
   */
  private getCacheKey(args: string[]): string {
    // Normalize command for consistent caching
    const normalized = args.join(' ');
    return createHash('sha256').update(normalized).digest('hex');
  }

  /**
   * Execute a gh CLI command with rate limiting and caching.
   */
  async exec(args: string[]): Promise<{ stdout: string; stderr: string }> {
    // Wait if we're paused due to rate limiting
    await this.waitIfPaused();

    // Check cache for read operations
    const isRead = this.isReadOperation(args);
    const cacheKey = isRead ? this.getCacheKey(args) : null;

    if (cacheKey) {
      const cached = this.cache.get(cacheKey);
      if (cached) {
        this.cacheStats.hits++;
        logger.debug('GitHub cache hit', {
          command: args.slice(0, 3).join(' '),
          hitRate: (this.cacheStats.hits / (this.cacheStats.hits + this.cacheStats.misses) * 100).toFixed(1) + '%',
        });
        return { stdout: cached.stdout, stderr: cached.stderr };
      }
      this.cacheStats.misses++;
    }

    // Execute with retry logic using error boundary
    const result = await withErrorBoundary(
      async () => {
        try {
          const { stdout, stderr } = await execFileAsync('gh', args, { encoding: 'utf-8' });
          return { stdout, stderr };
        } catch (err) {
          // Parse rate limit info from error if available
          if (err && typeof err === 'object' && 'stderr' in err && typeof err.stderr === 'string') {
            this.parseRateLimitFromError(err.stderr);
          }
          throw err;
        }
      },
      `GitHub CLI: ${args.slice(0, 3).join(' ')}`,
      { maxRetries: 3, baseDelayMs: 2000, maxDelayMs: 60000 },
      this.circuitBreaker
    );

    // Cache read operations
    if (cacheKey) {
      this.cache.set(cacheKey, {
        stdout: result.stdout,
        stderr: result.stderr,
        timestamp: Date.now(),
      });
    }

    // Periodically refresh rate limit status (every 10 requests)
    if ((this.cacheStats.hits + this.cacheStats.misses) % 10 === 0) {
      // Fire and forget
      this.fetchRateLimitStatus().catch(() => {});
    }

    return result;
  }

  /**
   * Convenience method for commands that only need stdout.
   */
  async execForStdout(args: string[]): Promise<string> {
    const { stdout } = await this.exec(args);
    return stdout;
  }
}

/**
 * Singleton GitHub client instance.
 */
export const githubClient = new GitHubClient();
