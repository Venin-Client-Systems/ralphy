/**
 * Worktree Management Tests
 *
 * Tests git worktree operations with mocked exec.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { WorktreeError } from '../lib/types.js';
import * as worktree from '../core/worktree.js';

// Mock node:child_process
vi.mock('node:child_process', () => ({
  execFile: vi.fn((file, args, opts, callback) => {
    // Handle different callback signatures
    if (typeof opts === 'function') {
      callback = opts;
    }

    // Simulate different git command responses based on args array
    const argsStr = args.join(' ');

    if (args[0] === 'branch' && args.length === 3) {
      // git branch <name> <baseBranch>
      callback?.(null, { stdout: '', stderr: '' });
    } else if (args[0] === 'worktree' && args[1] === 'add') {
      // git worktree add <path> <branch>
      callback?.(null, { stdout: 'Preparing worktree', stderr: '' });
    } else if (args[0] === '-C' && args.includes('rev-parse') && args.includes('HEAD')) {
      // git -C <path> rev-parse HEAD
      callback?.(null, { stdout: 'abc123\n', stderr: '' });
    } else if (args[0] === 'worktree' && args[1] === 'remove') {
      // git worktree remove <path> --force
      callback?.(null, { stdout: '', stderr: '' });
    } else if (args[0] === 'worktree' && args[1] === 'list' && args[2] === '--porcelain') {
      // git worktree list --porcelain
      const output = `worktree /path/to/main
HEAD abc123
branch refs/heads/main

worktree .worktrees/autoissue-test
HEAD def456
branch refs/heads/test-branch
`;
      callback?.(null, { stdout: output, stderr: '' });
    } else if (args[0] === 'rev-parse' && args[1] === '--verify') {
      // git rev-parse --verify <branch>
      callback?.(new Error('fatal: not a valid ref'), { stdout: '', stderr: '' });
    } else if (args[0] === 'worktree' && args[1] === 'prune') {
      // git worktree prune
      callback?.(null, { stdout: '', stderr: '' });
    } else {
      callback?.(null, { stdout: '', stderr: '' });
    }
  }),
}));

// Mock fs for existsSync
vi.mock('node:fs', () => ({
  existsSync: vi.fn(() => false), // Default: path doesn't exist
}));

describe('createWorktree', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('should reject empty branch name', async () => {
    await expect(worktree.createWorktree('')).rejects.toThrow(WorktreeError);
    await expect(worktree.createWorktree('   ')).rejects.toThrow(WorktreeError);
  });

  it('should reject branch names with whitespace', async () => {
    await expect(worktree.createWorktree('feature branch')).rejects.toThrow(WorktreeError);
    await expect(worktree.createWorktree('branch\nname')).rejects.toThrow(WorktreeError);
  });

  it('should sanitize branch names for paths', async () => {
    const { worktree: wt } = await worktree.createWorktree('feature/auth-123');
    expect(wt.path).toBe('.worktrees/autoissue-feature-auth-123');
  });

  it('should use custom prefix', async () => {
    const { worktree: wt } = await worktree.createWorktree('test', { prefix: 'custom-' });
    expect(wt.path).toBe('.worktrees/custom-test');
  });

  it('should return cleanup function', async () => {
    const { cleanup } = await worktree.createWorktree('test');
    expect(cleanup).toBeInstanceOf(Function);
  });

  it('should set correct branch and commit', async () => {
    const { worktree: wt } = await worktree.createWorktree('test-branch');
    expect(wt.branch).toBe('test-branch');
    expect(wt.commit).toBe('abc123');
    expect(wt.isMain).toBe(false);
  });
});

describe('listWorktrees', () => {
  it('should parse worktree list output', async () => {
    const worktrees = await worktree.listWorktrees();

    expect(worktrees).toHaveLength(2);
    expect(worktrees[0].path).toBe('/path/to/main');
    expect(worktrees[0].branch).toBe('main');
    expect(worktrees[0].commit).toBe('abc123');
    expect(worktrees[1].path).toBe('.worktrees/autoissue-test');
    expect(worktrees[1].branch).toBe('test-branch');
  });
});

describe('findWorktreeByBranch', () => {
  it('should find worktree by branch name', async () => {
    const result = await worktree.findWorktreeByBranch('test-branch');

    expect(result).not.toBeNull();
    expect(result?.branch).toBe('test-branch');
    expect(result?.path).toBe('.worktrees/autoissue-test');
  });

  it('should return null if branch not found', async () => {
    const result = await worktree.findWorktreeByBranch('nonexistent');
    expect(result).toBeNull();
  });
});

describe('cleanupWorktree', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('should be idempotent when worktree does not exist', async () => {
    const fs = await import('node:fs');
    vi.mocked(fs.existsSync).mockReturnValue(false);

    await expect(worktree.cleanupWorktree('.worktrees/test')).resolves.not.toThrow();
  });

  it('should remove existing worktree', async () => {
    const fs = await import('node:fs');
    vi.mocked(fs.existsSync).mockReturnValue(true);

    await expect(worktree.cleanupWorktree('.worktrees/test')).resolves.not.toThrow();
  });
});

describe('pruneWorktrees', () => {
  it('should call git worktree prune', async () => {
    await expect(worktree.pruneWorktrees()).resolves.not.toThrow();
  });
});
