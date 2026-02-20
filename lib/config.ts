/**
 * Config Loader (simplified from Echelon)
 *
 * Loads and validates Ralphy configuration from:
 * 1. Explicit path (--config)
 * 2. Auto-discovery (./ralphy.config.json, git root, ~/.ralphy/)
 * 3. Generate defaults (if in git repo)
 */

import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import type { RalphyConfig } from './types.js';
import { RalphyConfigSchema } from './types.js';
import { logger } from './logger.js';

/**
 * Load config from a specific path.
 */
export function loadConfig(path: string): RalphyConfig {
  logger.debug('Loading config', { path });

  if (!existsSync(path)) {
    throw new Error(`Config file not found: ${path}`);
  }

  try {
    const raw = readFileSync(path, 'utf-8');
    const json = JSON.parse(raw);
    const config = RalphyConfigSchema.parse(json);

    logger.info('Config loaded', { path });
    return config;
  } catch (err) {
    throw new Error(`Invalid config: ${err instanceof Error ? err.message : String(err)}`);
  }
}

/**
 * Auto-discover config file.
 *
 * Searches in order:
 * 1. ./ralphy.config.json (current directory)
 * 2. <git-root>/ralphy.config.json
 * 3. ~/.ralphy/configs/<repo-name>.json
 *
 * Returns path if found, null otherwise.
 */
export function discoverConfig(cwd: string = process.cwd()): string | null {
  // 1. Current directory
  const localPath = join(cwd, 'ralphy.config.json');
  if (existsSync(localPath)) {
    logger.debug('Config found in current directory', { path: localPath });
    return localPath;
  }

  // 2. Git root
  try {
    const gitRoot = getGitRoot(cwd);
    if (gitRoot) {
      const gitRootPath = join(gitRoot, 'ralphy.config.json');
      if (existsSync(gitRootPath)) {
        logger.debug('Config found in git root', { path: gitRootPath });
        return gitRootPath;
      }
    }
  } catch {
    // Not in a git repo
  }

  // 3. Global config
  try {
    const repoName = getRepoName(cwd);
    if (repoName) {
      const globalPath = join(process.env.HOME || '~', '.ralphy', 'configs', `${repoName}.json`);
      if (existsSync(globalPath)) {
        logger.debug('Config found in global directory', { path: globalPath });
        return globalPath;
      }
    }
  } catch {
    // Can't determine repo name
  }

  return null;
}

/**
 * Generate default config for a git repository.
 */
export function generateDefaultConfig(cwd: string = process.cwd()): RalphyConfig {
  const gitRoot = getGitRoot(cwd);
  if (!gitRoot) {
    throw new Error('Not in a git repository');
  }

  const remote = getGitRemote(gitRoot);
  if (!remote) {
    throw new Error('No git remote found');
  }

  const repo = parseGitRemote(remote);
  if (!repo) {
    throw new Error(`Invalid git remote: ${remote}`);
  }

  const config: RalphyConfig = {
    project: {
      repo,
      path: gitRoot,
      baseBranch: 'main',
    },
    executor: {
      maxParallel: 3,
      timeoutMinutes: 30,
      createPr: true,
      prDraft: false,
    },
    planner: {
      enabled: true,
      model: 'sonnet',
      maxBudgetUsd: 2.0,
    },
    agent: {
      model: 'sonnet',
      maxBudgetUsd: 5.0,
      yolo: true,
    },
    maxTotalBudgetUsd: 50.0,
  };

  logger.info('Generated default config', { repo });
  return config;
}

/**
 * Get git root directory.
 */
function getGitRoot(cwd: string): string | null {
  try {
    const { execSync } = require('node:child_process');
    const root = execSync('git rev-parse --show-toplevel', {
      cwd,
      encoding: 'utf-8',
    }).trim();
    return root;
  } catch {
    return null;
  }
}

/**
 * Get git remote URL.
 */
function getGitRemote(gitRoot: string): string | null {
  try {
    const { execSync } = require('node:child_process');
    const remote = execSync('git remote get-url origin', {
      cwd: gitRoot,
      encoding: 'utf-8',
    }).trim();
    return remote;
  } catch {
    return null;
  }
}

/**
 * Parse git remote URL to owner/repo format.
 *
 * Handles:
 * - https://github.com/owner/repo.git
 * - git@github.com:owner/repo.git
 * - https://github.com/owner/repo
 */
function parseGitRemote(remote: string): string | null {
  // HTTPS format
  let match = remote.match(/github\.com\/([^\/]+\/[^\/\.]+)/);
  if (match) return match[1];

  // SSH format
  match = remote.match(/git@github\.com:([^\/]+\/[^\/\.]+)/);
  if (match) return match[1];

  return null;
}

/**
 * Get repository name from git remote.
 */
function getRepoName(cwd: string): string | null {
  const gitRoot = getGitRoot(cwd);
  if (!gitRoot) return null;

  const remote = getGitRemote(gitRoot);
  if (!remote) return null;

  const repo = parseGitRemote(remote);
  if (!repo) return null;

  return repo.replace('/', '-');
}
