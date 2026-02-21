import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  CircuitBreaker,
  ExponentialBackoff,
  AgentErrorClassifier,
  withErrorBoundary,
  ErrorBoundaryObserver,
} from '../core/error-boundaries.js';
import { AgentValidationError } from '../core/agent-errors.js';

describe('CircuitBreaker', () => {
  let breaker: CircuitBreaker;

  beforeEach(() => {
    breaker = new CircuitBreaker(3, 1000); // 3 failures, 1s reset
  });

  it('starts in closed state', () => {
    expect(breaker.isOpen()).toBe(false);
    const state = breaker.getState();
    expect(state.state).toBe('closed');
    expect(state.failureCount).toBe(0);
    expect(state.threshold).toBe(3);
  });

  it('opens after threshold failures', () => {
    breaker.recordFailure();
    breaker.recordFailure();
    expect(breaker.isOpen()).toBe(false);

    breaker.recordFailure(); // Third failure
    expect(breaker.isOpen()).toBe(true);

    const state = breaker.getState();
    expect(state.state).toBe('open');
    expect(state.failureCount).toBe(3);
  });

  it('transitions to half-open after timeout', async () => {
    breaker.recordFailure();
    breaker.recordFailure();
    breaker.recordFailure();
    expect(breaker.isOpen()).toBe(true);

    // Wait for reset timeout
    await new Promise((resolve) => setTimeout(resolve, 1100));

    expect(breaker.isOpen()).toBe(false);
    const state = breaker.getState();
    expect(state.state).toBe('half_open');
  });

  it('resets on successful operation in half-open state', async () => {
    breaker.recordFailure();
    breaker.recordFailure();
    breaker.recordFailure();
    expect(breaker.isOpen()).toBe(true);

    // Wait for half-open transition
    await new Promise((resolve) => setTimeout(resolve, 1100));
    // Call isOpen() to trigger state transition
    expect(breaker.isOpen()).toBe(false);
    expect(breaker.getState().state).toBe('half_open');

    // Success in half-open should reset to closed
    breaker.recordSuccess();
    expect(breaker.isOpen()).toBe(false);
    const state = breaker.getState();
    expect(state.state).toBe('closed');
    expect(state.failureCount).toBe(0);
  });

  it('re-opens on failure in half-open state', async () => {
    breaker.recordFailure();
    breaker.recordFailure();
    breaker.recordFailure();
    expect(breaker.isOpen()).toBe(true);

    // Wait for half-open transition
    await new Promise((resolve) => setTimeout(resolve, 1100));
    // Call isOpen() to trigger state transition
    expect(breaker.isOpen()).toBe(false);
    expect(breaker.getState().state).toBe('half_open');

    // Failure in half-open should re-open
    breaker.recordFailure();
    expect(breaker.isOpen()).toBe(true);
    expect(breaker.getState().state).toBe('open');
  });

  it('can be manually reset', () => {
    breaker.recordFailure();
    breaker.recordFailure();
    breaker.recordFailure();
    expect(breaker.isOpen()).toBe(true);

    breaker.reset();
    expect(breaker.isOpen()).toBe(false);
    const state = breaker.getState();
    expect(state.state).toBe('closed');
    expect(state.failureCount).toBe(0);
  });
});

describe('ExponentialBackoff', () => {
  it('calculates exponential delay with jitter', () => {
    const backoff = new ExponentialBackoff(3, 1000, 32000);

    const delay1 = backoff.getNextDelay();
    expect(delay1).toBeGreaterThanOrEqual(1000); // 1000 * 2^0 = 1000
    expect(delay1).toBeLessThanOrEqual(1250); // 1000 + 25% jitter

    const delay2 = backoff.getNextDelay();
    expect(delay2).toBeGreaterThanOrEqual(2000); // 1000 * 2^1 = 2000
    expect(delay2).toBeLessThanOrEqual(2500); // 2000 + 25% jitter

    const delay3 = backoff.getNextDelay();
    expect(delay3).toBeGreaterThanOrEqual(4000); // 1000 * 2^2 = 4000
    expect(delay3).toBeLessThanOrEqual(5000); // 4000 + 25% jitter
  });

  it('returns null after max retries', () => {
    const backoff = new ExponentialBackoff(2, 1000, 32000);

    expect(backoff.getNextDelay()).not.toBeNull();
    expect(backoff.getNextDelay()).not.toBeNull();
    expect(backoff.getNextDelay()).toBeNull(); // Exceeded
  });

  it('respects max delay cap', () => {
    const backoff = new ExponentialBackoff(10, 1000, 5000);

    // After enough attempts, delay should be capped at 5000
    backoff.getNextDelay();
    backoff.getNextDelay();
    backoff.getNextDelay();
    const delay = backoff.getNextDelay();
    expect(delay).toBeLessThanOrEqual(6250); // 5000 + 25% jitter
  });

  it('can be reset', () => {
    const backoff = new ExponentialBackoff(3, 1000, 32000);

    backoff.getNextDelay();
    backoff.getNextDelay();
    expect(backoff.currentAttempt).toBe(2);

    backoff.reset();
    expect(backoff.currentAttempt).toBe(0);
    expect(backoff.attemptsRemaining).toBe(3);
  });
});

describe('AgentErrorClassifier', () => {
  it('classifies validation errors', () => {
    const error = new AgentValidationError(
      'Invalid model',
      'Use opus, sonnet, or haiku'
    );

    const classified = AgentErrorClassifier.classify(error);
    expect(classified.type).toBe('validation');
    expect(classified.retryable).toBe(false);
    expect(classified.recoveryHint).toBe('Use opus, sonnet, or haiku');
  });

  it('classifies rate limit errors', () => {
    const error = new Error('HTTP 429: Too many requests');
    const classified = AgentErrorClassifier.classify(error);

    expect(classified.type).toBe('rate_limit');
    expect(classified.retryable).toBe(true);
    expect(classified.recoveryHint).toContain('rate limit');
  });

  it('classifies quota exceeded errors', () => {
    const error = new Error('HTTP 403: Insufficient quota');
    const classified = AgentErrorClassifier.classify(error);

    expect(classified.type).toBe('quota_exceeded');
    expect(classified.retryable).toBe(false);
    expect(classified.recoveryHint).toContain('quota exceeded');
  });

  it('classifies timeout errors', () => {
    const error = new Error('Operation timed out after 30000ms');
    const classified = AgentErrorClassifier.classify(error);

    expect(classified.type).toBe('timeout');
    expect(classified.retryable).toBe(true);
    expect(classified.recoveryHint).toContain('timeout');
  });

  it('classifies network errors', () => {
    const error = new Error('ECONNREFUSED: Connection refused');
    const classified = AgentErrorClassifier.classify(error);

    expect(classified.type).toBe('network');
    expect(classified.retryable).toBe(true);
    expect(classified.recoveryHint).toContain('Network connectivity');
  });

  it('classifies crash errors', () => {
    const error = new Error('Process exited with code 1');
    const classified = AgentErrorClassifier.classify(error);

    expect(classified.type).toBe('crash');
    expect(classified.retryable).toBe(true);
    expect(classified.recoveryHint).toContain('crashed');
  });

  it('classifies unknown errors as retryable', () => {
    const error = new Error('Something weird happened');
    const classified = AgentErrorClassifier.classify(error);

    expect(classified.type).toBe('unknown');
    expect(classified.retryable).toBe(true);
  });
});

describe('withErrorBoundary', () => {
  it('succeeds on first attempt', async () => {
    const fn = vi.fn().mockResolvedValue('success');

    const result = await withErrorBoundary(fn, 'test-operation');

    expect(result).toBe('success');
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it('retries on retryable errors', async () => {
    const fn = vi
      .fn()
      .mockRejectedValueOnce(new Error('timeout'))
      .mockRejectedValueOnce(new Error('timeout'))
      .mockResolvedValueOnce('success');

    const result = await withErrorBoundary(fn, 'test-operation', {
      maxRetries: 3,
      baseDelayMs: 10, // Fast for testing
    });

    expect(result).toBe('success');
    expect(fn).toHaveBeenCalledTimes(3);
  });

  it('fails fast on non-retryable errors', async () => {
    const validationError = new AgentValidationError(
      'Invalid input',
      'Fix your input'
    );
    const fn = vi.fn().mockRejectedValue(validationError);

    await expect(
      withErrorBoundary(fn, 'test-operation', { maxRetries: 3 })
    ).rejects.toThrow('Invalid input');

    expect(fn).toHaveBeenCalledTimes(1); // Should not retry
  });

  it('throws after max retries exhausted', async () => {
    const fn = vi.fn().mockRejectedValue(new Error('timeout'));

    await expect(
      withErrorBoundary(fn, 'test-operation', {
        maxRetries: 2,
        baseDelayMs: 10,
      })
    ).rejects.toThrow('timeout');

    // With maxRetries=2, we get 1 initial attempt + 2 retries = 3 total calls
    expect(fn).toHaveBeenCalledTimes(3);
  });

  it('respects circuit breaker state', async () => {
    const breaker = new CircuitBreaker(2, 1000);
    const fn = vi.fn().mockRejectedValue(new Error('network error'));

    // First call: exhaust retries → 1 failure recorded in circuit breaker
    await expect(
      withErrorBoundary(fn, 'test-op', { maxRetries: 2, baseDelayMs: 10 }, breaker)
    ).rejects.toThrow();

    // Second call: exhaust retries → 2 failures recorded, circuit opens
    await expect(
      withErrorBoundary(fn, 'test-op', { maxRetries: 2, baseDelayMs: 10 }, breaker)
    ).rejects.toThrow();

    // Circuit should be open now
    expect(breaker.isOpen()).toBe(true);

    // Next call should fail fast without even trying
    const fn2 = vi.fn().mockResolvedValue('success');
    await expect(
      withErrorBoundary(fn2, 'test-op', { maxRetries: 2 }, breaker)
    ).rejects.toThrow('Circuit breaker open');

    expect(fn2).toHaveBeenCalledTimes(0); // Should not even try
  });

  it('records metrics with observer', async () => {
    const observer = new ErrorBoundaryObserver();
    const fn = vi
      .fn()
      .mockRejectedValueOnce(new Error('timeout'))
      .mockResolvedValueOnce('success');

    await withErrorBoundary(
      fn,
      'test-operation',
      { maxRetries: 2, observer, baseDelayMs: 10 },
    );

    const metrics = observer.getMetrics();
    expect(metrics).toHaveLength(1);
    expect(metrics[0].operation).toBe('test-operation');
    expect(metrics[0].attempts).toBe(2); // 1 failure + 1 success
    expect(metrics[0].successes).toBe(1);
    expect(metrics[0].failures).toBe(1);
  });
});

describe('ErrorBoundaryObserver', () => {
  let observer: ErrorBoundaryObserver;

  beforeEach(() => {
    observer = new ErrorBoundaryObserver();
  });

  it('records successful attempts', () => {
    observer.recordAttempt('operation-1');
    observer.recordAttempt('operation-1');

    const metrics = observer.getMetric('operation-1');
    expect(metrics?.attempts).toBe(2);
    expect(metrics?.successes).toBe(2);
    expect(metrics?.failures).toBe(0);
  });

  it('records failed attempts with error type', () => {
    const classified = AgentErrorClassifier.classify(new Error('timeout'));

    observer.recordAttempt('operation-1', classified);
    observer.recordAttempt('operation-1', classified);

    const metrics = observer.getMetric('operation-1');
    expect(metrics?.attempts).toBe(2);
    expect(metrics?.successes).toBe(0);
    expect(metrics?.failures).toBe(2);
    expect(metrics?.errorsByType['timeout']).toBe(2);
    expect(metrics?.lastError?.type).toBe('timeout');
  });

  it('tracks multiple operations independently', () => {
    observer.recordAttempt('op-1');
    observer.recordAttempt('op-2');
    observer.recordAttempt('op-1');

    const metrics = observer.getMetrics();
    expect(metrics).toHaveLength(2);

    const op1 = observer.getMetric('op-1');
    const op2 = observer.getMetric('op-2');

    expect(op1?.attempts).toBe(2);
    expect(op2?.attempts).toBe(1);
  });

  it('can be cleared', () => {
    observer.recordAttempt('operation-1');
    observer.recordAttempt('operation-2');

    expect(observer.getMetrics()).toHaveLength(2);

    observer.clear();
    expect(observer.getMetrics()).toHaveLength(0);
  });

  it('provides circuit breaker state', () => {
    const breaker = new CircuitBreaker(3, 1000);
    const state = observer.getCircuitBreakerState(breaker);

    expect(state.state).toBe('closed');
    expect(state.threshold).toBe(3);
    expect(state.failureCount).toBe(0);
  });
});
