/**
 * Tests for smart model selection
 */

import { describe, it, expect } from 'vitest';
import { selectOptimalModel } from '../lib/model-selector.js';
import type { Task, AgentConfig } from '../lib/types.js';

describe('selectOptimalModel', () => {
  const baseConfig: AgentConfig = {
    model: 'sonnet',
    maxBudgetUsd: 5.0,
    yolo: true,
  };

  it('should return haiku for simple documentation tasks', () => {
    const task: Task = {
      issueNumber: 1,
      title: 'Update README documentation',
      body: 'Add installation instructions to the README',
      labels: ['docs'],
      domain: 'documentation',
      status: 'pending',
    };

    const model = selectOptimalModel(task, baseConfig);
    expect(model).toBe('haiku');
  });

  it('should return haiku for typo fixes', () => {
    const task: Task = {
      issueNumber: 2,
      title: 'Fix typo in error message',
      body: 'Simple typo fix',
      labels: [],
      domain: 'backend',
      status: 'pending',
    };

    const model = selectOptimalModel(task, baseConfig);
    expect(model).toBe('haiku');
  });

  it('should return opus for complex architecture tasks', () => {
    const task: Task = {
      issueNumber: 3,
      title: 'Refactor authentication architecture',
      body: 'Complete redesign of auth system with OAuth2',
      labels: ['complex', 'architecture'],
      domain: 'backend',
      status: 'pending',
    };

    const model = selectOptimalModel(task, baseConfig);
    expect(model).toBe('opus');
  });

  it('should return opus for performance optimization', () => {
    const task: Task = {
      issueNumber: 4,
      title: 'Optimize database query performance',
      body: 'Analyze and optimize slow queries',
      labels: [],
      domain: 'database',
      status: 'pending',
    };

    const model = selectOptimalModel(task, baseConfig);
    expect(model).toBe('opus');
  });

  it('should return sonnet for regular tasks', () => {
    const task: Task = {
      issueNumber: 5,
      title: 'Add user profile endpoint',
      body: 'Create a new API endpoint for user profiles',
      labels: [],
      domain: 'backend',
      status: 'pending',
    };

    const model = selectOptimalModel(task, baseConfig);
    expect(model).toBe('sonnet');
  });

  it('should respect user override (opus)', () => {
    const config: AgentConfig = {
      model: 'opus',
      maxBudgetUsd: 5.0,
      yolo: true,
    };

    const task: Task = {
      issueNumber: 6,
      title: 'Update README',
      body: 'Simple doc update',
      labels: ['docs'],
      domain: 'documentation',
      status: 'pending',
    };

    const model = selectOptimalModel(task, config);
    expect(model).toBe('opus'); // User override, not haiku
  });

  it('should respect user override (haiku)', () => {
    const config: AgentConfig = {
      model: 'haiku',
      maxBudgetUsd: 5.0,
      yolo: true,
    };

    const task: Task = {
      issueNumber: 7,
      title: 'Refactor architecture',
      body: 'Complex refactoring',
      labels: ['complex'],
      domain: 'backend',
      status: 'pending',
    };

    const model = selectOptimalModel(task, config);
    expect(model).toBe('haiku'); // User override, not opus
  });

  it('should detect complexity from labels', () => {
    const task: Task = {
      issueNumber: 8,
      title: 'Some task',
      body: 'Regular task',
      labels: ['complex'],
      domain: 'backend',
      status: 'pending',
    };

    const model = selectOptimalModel(task, baseConfig);
    expect(model).toBe('opus');
  });

  it('should detect simplicity from labels', () => {
    const task: Task = {
      issueNumber: 9,
      title: 'Some task',
      body: 'Regular task',
      labels: ['simple'],
      domain: 'backend',
      status: 'pending',
    };

    const model = selectOptimalModel(task, baseConfig);
    expect(model).toBe('haiku');
  });
});
