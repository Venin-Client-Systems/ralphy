/**
 * Tests for smart retry logic
 */

import { describe, it, expect } from 'vitest';
import { analyzeError, enhancePrompt, calculateBackoff } from '../lib/smart-retry.js';

describe('analyzeError', () => {
  it('should detect module not found errors', () => {
    const result = analyzeError('Cannot find module "foo"');
    expect(result.retryable).toBe(true);
    expect(result.category).toBe('missing_dependency');
    expect(result.suggestedFix).toContain('npm install');
  });

  it('should detect syntax errors', () => {
    const result = analyzeError('SyntaxError: Unexpected token }');
    expect(result.retryable).toBe(true);
    expect(result.category).toBe('syntax_error');
    expect(result.suggestedFix).toContain('syntax');
  });

  it('should detect type errors', () => {
    const result = analyzeError('TypeError: foo is not a function');
    expect(result.retryable).toBe(true);
    expect(result.category).toBe('type_error');
    expect(result.suggestedFix).toContain('type');
  });

  it('should detect file not found errors', () => {
    const result = analyzeError('ENOENT: no such file or directory');
    expect(result.retryable).toBe(true);
    expect(result.category).toBe('file_not_found');
    expect(result.suggestedFix).toContain('file');
  });

  it('should detect permission errors', () => {
    const result = analyzeError('EACCES: permission denied');
    expect(result.retryable).toBe(true);
    expect(result.category).toBe('permission_error');
    expect(result.suggestedFix).toContain('permission');
  });

  it('should detect rate limits', () => {
    const result = analyzeError('Rate limit exceeded');
    expect(result.retryable).toBe(true);
    expect(result.category).toBe('rate_limit');
  });

  it('should detect timeouts', () => {
    const result = analyzeError('Error: timeout exceeded');
    expect(result.retryable).toBe(true);
    expect(result.category).toBe('timeout');
  });

  it('should detect build failures', () => {
    const result = analyzeError('Compilation failed with 3 errors');
    expect(result.retryable).toBe(true);
    expect(result.category).toBe('build_error');
  });

  it('should detect test failures', () => {
    const result = analyzeError('Test failed: expected 1 to equal 2');
    expect(result.retryable).toBe(true);
    expect(result.category).toBe('test_failure');
  });

  it('should mark auth errors as non-retryable', () => {
    const result = analyzeError('Unauthorized: invalid credentials');
    expect(result.retryable).toBe(false);
    expect(result.category).toBe('auth_error');
  });

  it('should mark unknown errors as non-retryable', () => {
    const result = analyzeError('Something went wrong');
    expect(result.retryable).toBe(false);
    expect(result.category).toBe('unknown');
  });
});

describe('enhancePrompt', () => {
  it('should add error context to prompt', () => {
    const original = 'Do the task';
    const analysis = {
      retryable: true,
      category: 'syntax_error',
      suggestedFix: 'Fix syntax errors',
    };

    const enhanced = enhancePrompt(original, analysis, 1);
    expect(enhanced).toContain(original);
    expect(enhanced).toContain('PREVIOUS ATTEMPT FAILED');
    expect(enhanced).toContain('Fix syntax errors');
    expect(enhanced).toContain('Attempt 1');
  });

  it('should not modify prompt if no suggested fix', () => {
    const original = 'Do the task';
    const analysis = {
      retryable: true,
      category: 'unknown',
    };

    const enhanced = enhancePrompt(original, analysis, 1);
    expect(enhanced).toBe(original);
  });
});

describe('calculateBackoff', () => {
  it('should calculate exponential backoff', () => {
    expect(calculateBackoff(0)).toBe(2000);
    expect(calculateBackoff(1)).toBe(4000);
    expect(calculateBackoff(2)).toBe(8000);
    expect(calculateBackoff(3)).toBe(16000);
  });

  it('should use custom base delay', () => {
    expect(calculateBackoff(0, 1000)).toBe(1000);
    expect(calculateBackoff(1, 1000)).toBe(2000);
    expect(calculateBackoff(2, 1000)).toBe(4000);
  });
});
