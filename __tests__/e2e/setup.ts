/**
 * E2E Test Setup
 *
 * Provides utilities for end-to-end testing of the full executor pipeline.
 */

import { vi } from 'vitest';
import type { AutoissueConfig } from '../../lib/types.js';

/**
 * Create a test configuration for E2E tests.
 */
export function createTestConfig(overrides?: Partial<AutoissueConfig>): AutoissueConfig {
  return {
    project: {
      repo: 'test-org/test-repo',
      path: process.cwd(),
      baseBranch: 'main',
    },
    executor: {
      maxParallel: 2,
      timeoutMinutes: 5,
      createPr: false, // Don't create PRs in tests
      prDraft: false,
    },
    agent: {
      model: 'haiku',
      maxBudgetUsd: 1.0,
      yolo: true,
      maxTurns: 3,
    },
    maxTotalBudgetUsd: 5.0,
    dashboard: {
      enabled: false,
      port: 3030,
    },
    ...overrides,
  };
}

/**
 * Mock GitHub issue for testing.
 */
export function createMockIssue(number: number, title: string, labels: string[] = []) {
  return {
    number,
    title,
    body: `Test issue body for #${number}`,
    labels,
    state: 'open' as const,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    html_url: `https://github.com/test-org/test-repo/issues/${number}`,
  };
}

/**
 * Mock agent spawn for testing (returns immediately).
 */
export function createMockAgentSpawn(costUsd: number = 0.5, shouldFail: boolean = false) {
  return vi.fn(async () => {
    if (shouldFail) {
      throw new Error('Mock agent failure');
    }
    return {
      sessionId: `mock-session-${Date.now()}`,
      content: 'Mock agent response',
      costUsd,
      durationMs: 1000,
    };
  });
}

/**
 * Mock GitHub API client for testing.
 */
export function createMockGitHubApi(issues: any[] = []) {
  return {
    listIssues: vi.fn(async () => issues),
    getIssue: vi.fn(async (repo: string, issueNumber: number) =>
      issues.find(i => i.number === issueNumber)
    ),
    createPullRequest: vi.fn(async () => 123),
    closePullRequest: vi.fn(async () => {}),
  };
}

/**
 * Wait for a condition to be true (with timeout).
 */
export async function waitFor(
  condition: () => boolean | Promise<boolean>,
  timeoutMs: number = 5000,
  checkIntervalMs: number = 100
): Promise<void> {
  const startTime = Date.now();

  while (Date.now() - startTime < timeoutMs) {
    if (await condition()) {
      return;
    }
    await new Promise(resolve => setTimeout(resolve, checkIntervalMs));
  }

  throw new Error(`Condition not met within ${timeoutMs}ms`);
}

/**
 * Clean up test artifacts.
 */
export async function cleanupTestArtifacts() {
  // Could clean up any test files, worktrees, etc.
  // For now, just a placeholder
}
