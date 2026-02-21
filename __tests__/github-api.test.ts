import { describe, it, expect, beforeEach, vi } from 'vitest';
import { GitHubAPI } from '../lib/github-api.js';

describe('GitHubAPI', () => {
  describe('parseRepo', () => {
    it('parses valid repo format', () => {
      const api = new GitHubAPI();
      const result = (api as any).parseRepo('owner/repo');

      expect(result).toEqual({ owner: 'owner', repo: 'repo' });
    });

    it('throws on invalid repo format', () => {
      const api = new GitHubAPI();

      expect(() => (api as any).parseRepo('invalid')).toThrow('Invalid repo format');
      expect(() => (api as any).parseRepo('too/many/slashes')).toThrow('Invalid repo format');
    });
  });

  describe('cache key generation', () => {
    it('generates unique cache keys', () => {
      const api = new GitHubAPI();

      const key1 = (api as any).getCacheKey('issues.list', { repo: 'foo', labels: ['bug'] });
      const key2 = (api as any).getCacheKey('issues.list', { repo: 'bar', labels: ['bug'] });
      const key3 = (api as any).getCacheKey('issues.list', { repo: 'foo', labels: ['feature'] });

      expect(key1).not.toBe(key2);
      expect(key1).not.toBe(key3);
      expect(key2).not.toBe(key3);
    });

    it('generates consistent cache keys for same parameters', () => {
      const api = new GitHubAPI();

      const key1 = (api as any).getCacheKey('issues.list', { repo: 'foo', labels: ['bug'] });
      const key2 = (api as any).getCacheKey('issues.list', { repo: 'foo', labels: ['bug'] });

      expect(key1).toBe(key2);
    });
  });

  describe('cache statistics', () => {
    it('tracks cache hits and misses', () => {
      const api = new GitHubAPI();

      const initialStats = api.getCacheStats();
      expect(initialStats.hits).toBe(0);
      expect(initialStats.misses).toBe(0);
    });

    it('clears cache', () => {
      const api = new GitHubAPI();

      api.clearCache();

      const stats = api.getCacheStats();
      expect(stats.hits).toBe(0);
      expect(stats.misses).toBe(0);
    });
  });

  describe('circuit breaker', () => {
    it('exposes circuit breaker state', () => {
      const api = new GitHubAPI();

      const state = api.getCircuitBreakerState();

      expect(state).toHaveProperty('state');
      expect(state).toHaveProperty('failureCount');
      expect(state).toHaveProperty('threshold');
      expect(state.state).toBe('closed');
      expect(state.failureCount).toBe(0);
      expect(state.threshold).toBe(5);
    });
  });

  describe('hit rate calculation', () => {
    it('calculates 0% hit rate with no requests', () => {
      const api = new GitHubAPI();
      const hitRate = (api as any).getHitRate();

      expect(hitRate).toBe('0%');
    });
  });
});
