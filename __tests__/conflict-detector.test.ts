/**
 * Tests for conflict detection
 */

import { describe, it, expect } from 'vitest';
import { extractFilePaths, detectConflicts, hasConflict } from '../lib/conflict-detector.js';
import type { Task } from '../lib/types.js';

describe('extractFilePaths', () => {
  it('should extract file paths from text', () => {
    const text = 'Edit src/lib/foo.ts and src/core/bar.ts';
    const paths = extractFilePaths(text);
    expect(paths.sort()).toEqual(['src/core/bar.ts', 'src/lib/foo.ts']);
  });

  it('should extract backtick-quoted paths', () => {
    const text = 'Update `src/lib/config.ts` and `lib/types.ts`';
    const paths = extractFilePaths(text);
    expect(paths.sort()).toEqual(['lib/types.ts', 'src/lib/config.ts']);
  });

  it('should extract double-quoted paths', () => {
    const text = 'Modify "src/core/agent.ts" and "lib/logger.ts"';
    const paths = extractFilePaths(text);
    expect(paths.sort()).toEqual(['lib/logger.ts', 'src/core/agent.ts']);
  });

  it('should handle multiple file types', () => {
    const text = 'Edit src/foo.ts, lib/bar.js, core/config.json, and tests/README.md';
    const paths = extractFilePaths(text);
    expect(paths).toContain('src/foo.ts');
    expect(paths).toContain('lib/bar.js');
    expect(paths).toContain('core/config.json');
    expect(paths).toContain('tests/README.md');
  });

  it('should return empty array for no matches', () => {
    const text = 'No files mentioned here';
    const paths = extractFilePaths(text);
    expect(paths).toEqual([]);
  });

  it('should deduplicate paths', () => {
    const text = 'Edit src/foo.ts and src/foo.ts again';
    const paths = extractFilePaths(text);
    expect(paths).toEqual(['src/foo.ts']);
  });

  it('should handle paths in different directories', () => {
    const text = 'Modify src/lib/foo.ts, core/bar.ts, tests/baz.test.ts';
    const paths = extractFilePaths(text);
    expect(paths).toContain('src/lib/foo.ts');
    expect(paths).toContain('core/bar.ts');
    expect(paths).toContain('tests/baz.test.ts');
  });
});

describe('detectConflicts', () => {
  it('should detect file conflicts between tasks', () => {
    const tasks: Task[] = [
      {
        issueNumber: 1,
        title: 'Task 1',
        body: 'Edit src/lib/config.ts',
        labels: [],
        domain: 'backend',
        status: 'pending',
      },
      {
        issueNumber: 2,
        title: 'Task 2',
        body: 'Modify src/lib/config.ts',
        labels: [],
        domain: 'backend',
        status: 'pending',
      },
    ];

    const conflicts = detectConflicts(tasks);
    expect(conflicts.size).toBe(2);
    expect(conflicts.get(1)).toEqual([2]);
    expect(conflicts.get(2)).toEqual([1]);
  });

  it('should not detect conflicts for different files', () => {
    const tasks: Task[] = [
      {
        issueNumber: 1,
        title: 'Task 1',
        body: 'Edit src/lib/foo.ts',
        labels: [],
        domain: 'backend',
        status: 'pending',
      },
      {
        issueNumber: 2,
        title: 'Task 2',
        body: 'Modify src/lib/bar.ts',
        labels: [],
        domain: 'backend',
        status: 'pending',
      },
    ];

    const conflicts = detectConflicts(tasks);
    expect(conflicts.size).toBe(0);
  });

  it('should detect multi-way conflicts', () => {
    const tasks: Task[] = [
      {
        issueNumber: 1,
        title: 'Task 1',
        body: 'Edit src/lib/config.ts',
        labels: [],
        domain: 'backend',
        status: 'pending',
      },
      {
        issueNumber: 2,
        title: 'Task 2',
        body: 'Modify src/lib/config.ts',
        labels: [],
        domain: 'backend',
        status: 'pending',
      },
      {
        issueNumber: 3,
        title: 'Task 3',
        body: 'Update src/lib/config.ts',
        labels: [],
        domain: 'backend',
        status: 'pending',
      },
    ];

    const conflicts = detectConflicts(tasks);
    expect(conflicts.size).toBe(3);
    expect(conflicts.get(1)?.sort()).toEqual([2, 3]);
    expect(conflicts.get(2)?.sort()).toEqual([1, 3]);
    expect(conflicts.get(3)?.sort()).toEqual([1, 2]);
  });

  it('should extract files from title and body', () => {
    const tasks: Task[] = [
      {
        issueNumber: 1,
        title: 'Fix src/lib/config.ts',
        body: 'Minor fix',
        labels: [],
        domain: 'backend',
        status: 'pending',
      },
      {
        issueNumber: 2,
        title: 'Task 2',
        body: 'Edit src/lib/config.ts',
        labels: [],
        domain: 'backend',
        status: 'pending',
      },
    ];

    const conflicts = detectConflicts(tasks);
    expect(conflicts.size).toBe(2);
  });
});

describe('hasConflict', () => {
  it('should return true for overlapping files', () => {
    const task1: Task = {
      issueNumber: 1,
      title: 'Task 1',
      body: 'Edit src/lib/config.ts',
      labels: [],
      domain: 'backend',
      status: 'pending',
    };

    const task2: Task = {
      issueNumber: 2,
      title: 'Task 2',
      body: 'Modify src/lib/config.ts',
      labels: [],
      domain: 'backend',
      status: 'pending',
    };

    expect(hasConflict(task1, task2)).toBe(true);
  });

  it('should return false for different files', () => {
    const task1: Task = {
      issueNumber: 1,
      title: 'Task 1',
      body: 'Edit src/lib/foo.ts',
      labels: [],
      domain: 'backend',
      status: 'pending',
    };

    const task2: Task = {
      issueNumber: 2,
      title: 'Task 2',
      body: 'Modify src/lib/bar.ts',
      labels: [],
      domain: 'backend',
      status: 'pending',
    };

    expect(hasConflict(task1, task2)).toBe(false);
  });

  it('should return false for tasks without file references', () => {
    const task1: Task = {
      issueNumber: 1,
      title: 'Task 1',
      body: 'Do something',
      labels: [],
      domain: 'backend',
      status: 'pending',
    };

    const task2: Task = {
      issueNumber: 2,
      title: 'Task 2',
      body: 'Do something else',
      labels: [],
      domain: 'backend',
      status: 'pending',
    };

    expect(hasConflict(task1, task2)).toBe(false);
  });
});
