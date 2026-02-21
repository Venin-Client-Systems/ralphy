/**
 * E2E Tests for Executor
 *
 * Tests the full execution pipeline with mocked external dependencies.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { executeIssues } from '../../core/executor.js';
import { createTestConfig, createMockIssue, createMockAgentSpawn, createMockGitHubApi } from './setup.js';
import * as githubApiModule from '../../lib/github-api.js';
import * as agentModule from '../../core/agent.js';

describe('Executor E2E', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('executeIssues', () => {
    it('should execute a single issue successfully', async () => {
      const mockIssues = [createMockIssue(1, '[Backend] Fix login bug', ['test-label', 'backend'])];
      const mockAgent = createMockAgentSpawn(0.5);

      // Mock GitHub API
      vi.spyOn(githubApiModule.githubApi, 'listIssues').mockResolvedValue(mockIssues);

      // Mock agent spawn
      vi.spyOn(agentModule, 'spawnAgent').mockImplementation(mockAgent);

      const config = createTestConfig({ maxTotalBudgetUsd: 10.0 });
      const session = await executeIssues('test-label', config, { headless: true });

      expect(session.status).toBe('completed');
      expect(session.tasks).toHaveLength(1);
      expect(session.tasks[0].status).toBe('completed');
      expect(session.tasks[0].issueNumber).toBe(1);
      expect(session.tasks[0].domain).toBe('backend');
      expect(session.totalCost).toBeCloseTo(0.5);
      expect(mockAgent).toHaveBeenCalledTimes(1);
    });

    it('should execute multiple issues in parallel', async () => {
      const mockIssues = [
        createMockIssue(1, '[Backend] Task 1', ['test-label', 'backend']),
        createMockIssue(2, '[Frontend] Task 2', ['test-label', 'frontend']),
        createMockIssue(3, '[Database] Task 3', ['test-label', 'database']),
      ];
      const mockAgent = createMockAgentSpawn(0.3);

      vi.spyOn(githubApiModule.githubApi, 'listIssues').mockResolvedValue(mockIssues);
      vi.spyOn(agentModule, 'spawnAgent').mockImplementation(mockAgent);

      const config = createTestConfig({
        executor: { maxParallel: 3, timeoutMinutes: 5, createPr: false, prDraft: false },
        maxTotalBudgetUsd: 10.0, // Enough budget for 3 tasks
      });
      const session = await executeIssues('test-label', config, { headless: true });

      expect(session.status).toBe('completed');
      expect(session.tasks).toHaveLength(3);
      expect(session.tasks.filter(t => t.status === 'completed')).toHaveLength(3);
      expect(session.totalCost).toBeCloseTo(0.9);
      expect(mockAgent).toHaveBeenCalledTimes(3);
    });

    it('should handle task failures gracefully', async () => {
      const mockIssues = [
        createMockIssue(1, '[Backend] Success', ['test-label', 'backend']),
        createMockIssue(2, '[Frontend] Failure', ['test-label', 'frontend']),
        createMockIssue(3, '[Database] Success', ['test-label', 'database']),
      ];

      let callCount = 0;
      const mockAgent = vi.fn(async () => {
        callCount++;
        if (callCount === 2) {
          throw new Error('Mock failure for task 2');
        }
        return {
          sessionId: `mock-session-${callCount}`,
          content: 'Success',
          costUsd: 0.4,
          durationMs: 1000,
        };
      });

      vi.spyOn(githubApiModule.githubApi, 'listIssues').mockResolvedValue(mockIssues);
      vi.spyOn(agentModule, 'spawnAgent').mockImplementation(mockAgent);

      const config = createTestConfig({ maxTotalBudgetUsd: 10.0 });
      const session = await executeIssues('test-label', config, { headless: true });

      expect(session.status).toBe('completed');
      expect(session.tasks).toHaveLength(3);
      expect(session.tasks.filter(t => t.status === 'completed')).toHaveLength(2);
      expect(session.tasks.filter(t => t.status === 'failed')).toHaveLength(1);
      expect(session.tasks[1].status).toBe('failed');
      expect(session.tasks[1].error).toContain('Mock failure');
    });

    it('should enforce budget limits', async () => {
      const mockIssues = [
        createMockIssue(1, '[Backend] Task 1', ['test-label', 'backend']),
        createMockIssue(2, '[Frontend] Task 2', ['test-label', 'frontend']),
        createMockIssue(3, '[Database] Task 3', ['test-label', 'database']),
      ];
      const mockAgent = createMockAgentSpawn(2.0); // High cost

      vi.spyOn(githubApiModule.githubApi, 'listIssues').mockResolvedValue(mockIssues);
      vi.spyOn(agentModule, 'spawnAgent').mockImplementation(mockAgent);

      const config = createTestConfig({
        maxTotalBudgetUsd: 3.0, // Only enough for 1-2 tasks
        agent: { model: 'haiku', maxBudgetUsd: 2.0, yolo: true },
      });

      // Should throw because estimated cost exceeds budget
      await expect(
        executeIssues('test-label', config, { headless: true })
      ).rejects.toThrow(/Cannot afford/);
    });

    it('should handle empty issue list', async () => {
      vi.spyOn(githubApiModule.githubApi, 'listIssues').mockResolvedValue([]);

      const config = createTestConfig({ maxTotalBudgetUsd: 10.0 });
      const session = await executeIssues('test-label', config, { headless: true });

      expect(session.status).toBe('completed');
      expect(session.tasks).toHaveLength(0);
      expect(session.totalCost).toBe(0);
    });

    it('should classify issues by domain correctly', async () => {
      const mockIssues = [
        createMockIssue(1, '[Backend] API fix', ['test-label', 'backend']),
        createMockIssue(2, '[Frontend] UI update', ['test-label', 'frontend']),
        createMockIssue(3, '[Database] Migration', ['test-label', 'database']),
        createMockIssue(4, 'Unknown task', ['test-label']), // No domain label
      ];
      const mockAgent = createMockAgentSpawn(0.3);

      vi.spyOn(githubApiModule.githubApi, 'listIssues').mockResolvedValue(mockIssues);
      vi.spyOn(agentModule, 'spawnAgent').mockImplementation(mockAgent);

      const config = createTestConfig({ maxTotalBudgetUsd: 10.0 });
      const session = await executeIssues('test-label', config, { headless: true });

      expect(session.tasks[0].domain).toBe('backend');
      expect(session.tasks[1].domain).toBe('frontend');
      expect(session.tasks[2].domain).toBe('database');
      expect(session.tasks[3].domain).toBe('unknown');
    });

    it('should track costs accurately', async () => {
      const mockIssues = [
        createMockIssue(1, '[Backend] Task 1', ['test-label', 'backend']),
        createMockIssue(2, '[Frontend] Task 2', ['test-label', 'frontend']),
      ];

      let callCount = 0;
      const mockAgent = vi.fn(async () => {
        callCount++;
        return {
          sessionId: `mock-session-${callCount}`,
          content: 'Success',
          costUsd: callCount === 1 ? 0.25 : 0.75, // Different costs
          durationMs: 1000,
        };
      });

      vi.spyOn(githubApiModule.githubApi, 'listIssues').mockResolvedValue(mockIssues);
      vi.spyOn(agentModule, 'spawnAgent').mockImplementation(mockAgent);

      const config = createTestConfig({ maxTotalBudgetUsd: 10.0 });
      const session = await executeIssues('test-label', config, { headless: true });

      expect(session.tasks[0].costUsd).toBeCloseTo(0.25);
      expect(session.tasks[1].costUsd).toBeCloseTo(0.75);
      expect(session.totalCost).toBeCloseTo(1.0);
    });

    it('should respect maxParallel setting', async () => {
      const mockIssues = [
        createMockIssue(1, '[Backend] Task 1', ['test-label']),
        createMockIssue(2, '[Backend] Task 2', ['test-label']),
        createMockIssue(3, '[Backend] Task 3', ['test-label']),
        createMockIssue(4, '[Backend] Task 4', ['test-label']),
      ];

      let concurrentCalls = 0;
      let maxConcurrent = 0;
      const mockAgent = vi.fn(async () => {
        concurrentCalls++;
        maxConcurrent = Math.max(maxConcurrent, concurrentCalls);

        // Simulate work
        await new Promise(resolve => setTimeout(resolve, 100));

        concurrentCalls--;
        return {
          sessionId: `mock-session-${Date.now()}`,
          content: 'Success',
          costUsd: 0.2,
          durationMs: 100,
        };
      });

      vi.spyOn(githubApiModule.githubApi, 'listIssues').mockResolvedValue(mockIssues);
      vi.spyOn(agentModule, 'spawnAgent').mockImplementation(mockAgent);

      const config = createTestConfig({
        executor: { maxParallel: 2, timeoutMinutes: 5, createPr: false, prDraft: false },
      });
      await executeIssues('test-label', config, { headless: true });

      // Should never exceed maxParallel
      expect(maxConcurrent).toBeLessThanOrEqual(2);
    });
  });
});
