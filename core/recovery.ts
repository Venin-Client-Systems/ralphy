import { logger } from '../lib/logger.js';
import type { RalphyConfig, SessionState } from '../lib/types.js';

export interface RetryOptions {
  maxRetries: number;
  baseDelayMs: number;
  maxDelayMs: number;
}

const DEFAULT_RETRY: RetryOptions = {
  maxRetries: 3,
  baseDelayMs: 2_000,
  maxDelayMs: 30_000,
};

/** Exponential backoff with jitter */
function backoffDelay(attempt: number, opts: RetryOptions): number {
  const delay = Math.min(
    opts.baseDelayMs * Math.pow(2, attempt),
    opts.maxDelayMs,
  );
  // Add 0-25% jitter
  return delay + Math.random() * delay * 0.25;
}

/** Sleep for a given number of ms */
function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/** Retry an async function with exponential backoff */
export async function withRetry<T>(
  fn: () => Promise<T>,
  label: string,
  opts: Partial<RetryOptions> = {},
): Promise<T> {
  const config = { ...DEFAULT_RETRY, ...opts };

  // maxRetries = total number of attempts (not additional retries)
  // Attempt 1..maxRetries (inclusive), so maxRetries total attempts
  for (let attempt = 1; attempt <= config.maxRetries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);

      if (attempt >= config.maxRetries) {
        logger.error(`${label}: all ${config.maxRetries} attempts exhausted`, { error: msg });
        throw err;
      }

      const delay = backoffDelay(attempt - 1, config);
      logger.warn(`${label}: attempt ${attempt}/${config.maxRetries} failed, retrying in ${(delay / 1000).toFixed(1)}s`, {
        error: msg,
        attempt,
        maxRetries: config.maxRetries,
      });
      await sleep(delay);
    }
  }

  // Unreachable, but TypeScript needs it
  throw new Error(`${label}: retry logic error`);
}

/** Check total budget */
export function checkTotalBudget(
  state: SessionState,
  config: RalphyConfig,
): { ok: boolean; remaining: number; spent: number; limit: number } {
  return {
    ok: state.totalCost < config.maxTotalBudgetUsd,
    remaining: Math.max(0, config.maxTotalBudgetUsd - state.totalCost),
    spent: state.totalCost,
    limit: config.maxTotalBudgetUsd,
  };
}

/** Get a budget summary string */
export function budgetSummary(state: SessionState, config: RalphyConfig): string {
  const { spent, limit, remaining } = checkTotalBudget(state, config);
  const pct = limit > 0 ? ((spent / limit) * 100).toFixed(1) : 0;
  return `Budget: $${spent.toFixed(2)}/$${limit.toFixed(2)} (${pct}% used, $${remaining.toFixed(2)} remaining)`;
}
