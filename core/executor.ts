/**
 * Executor - Main Task Execution Loop
 *
 * Orchestrates the full pipeline:
 * 1. Fetch issues from GitHub
 * 2. Classify domains
 * 3. Build task queue
 * 4. Schedule with sliding window
 * 5. Execute in parallel worktrees
 * 6. Create PRs
 * 7. Cleanup
 */

import { nanoid } from 'nanoid';
import { logger } from '../lib/logger.js';
import { githubClient } from '../lib/github-client.js';
import type {
  RalphyConfig,
  Task,
  SessionState,
  SessionStatus,
  GitHubIssue,
} from '../lib/types.js';
import { classifyIssue } from '../lib/domain-classifier.js';
import {
  createScheduler,
  enqueueTasks,
  fillSlots,
  completeTask,
  hasWork,
  getSummary,
  getSchedulerStatus,
  type SchedulerState,
} from './scheduler.js';
import { createWorktree, cleanupWorktree } from './worktree.js';
import { spawnAgent } from './agent.js';

/**
 * Execute issues with the given label.
 *
 * Main entry point for direct mode: `ralphy --issues ralphy-1`
 */
export async function executeIssues(
  label: string,
  config: RalphyConfig
): Promise<SessionState> {
  const sessionId = nanoid();
  logger.info('Starting execution session', { sessionId, label });

  // Initialize session state
  const session: SessionState = {
    sessionId,
    status: 'running',
    label,
    tasks: [],
    totalCost: 0,
    startedAt: new Date().toISOString(),
    config,
  };

  try {
    // Step 1: Fetch issues from GitHub
    const issues = await fetchIssuesByLabel(config.project.repo, label);
    logger.info('Fetched issues', { count: issues.length, label });

    if (issues.length === 0) {
      logger.warn('No issues found', { label });
      session.status = 'completed';
      session.completedAt = new Date().toISOString();
      return session;
    }

    // Step 2: Classify domains and create tasks
    const tasks = issues.map((issue) => {
      const classification = classifyIssue(issue);
      const task: Task = {
        issueNumber: issue.number,
        title: issue.title,
        body: issue.body,
        labels: issue.labels,
        domain: classification.domain,
        status: 'pending',
      };
      return task;
    });

    session.tasks = tasks;
    logger.info('Tasks classified', {
      tasks: tasks.map((t) => ({
        issue: t.issueNumber,
        domain: t.domain,
      })),
    });

    // Step 3: Create scheduler
    const scheduler = createScheduler(config.executor.maxParallel);
    enqueueTasks(scheduler, tasks);

    // Step 4: Execute with sliding window
    await executeSlidingWindow(scheduler, session, config);

    // Mark session complete
    session.status = 'completed';
    session.completedAt = new Date().toISOString();

    const summary = getSummary(scheduler);
    logger.info('Execution complete', {
      sessionId,
      ...summary,
      totalCost: session.totalCost,
    });

    return session;
  } catch (err) {
    logger.error('Execution failed', {
      sessionId,
      error: err instanceof Error ? err.message : String(err),
    });
    session.status = 'failed';
    session.completedAt = new Date().toISOString();
    throw err;
  }
}

/**
 * Fetch issues from GitHub by label.
 */
async function fetchIssuesByLabel(repo: string, label: string): Promise<GitHubIssue[]> {
  logger.debug('Fetching issues', { repo, label });

  const { exec } = await import('node:child_process');
  const { promisify } = await import('node:util');
  const execAsync = promisify(exec);

  try {
    // Use gh CLI to fetch issues
    const { stdout } = await execAsync(
      `gh issue list --repo ${repo} --label "${label}" --state open --json number,title,body,labels,state,assignees,createdAt,updatedAt,url --limit 100`
    );

    const rawIssues = JSON.parse(stdout);

    // Transform to GitHubIssue format
    const issues: GitHubIssue[] = rawIssues.map((issue: any) => ({
      number: issue.number,
      title: issue.title,
      body: issue.body || '',
      labels: issue.labels?.map((l: any) => l.name) || [],
      state: issue.state,
      assignee: issue.assignees?.[0]?.login,
      created_at: issue.createdAt,
      updated_at: issue.updatedAt,
      html_url: issue.url,
    }));

    logger.info('Fetched issues from GitHub', {
      repo,
      label,
      count: issues.length,
    });

    return issues;
  } catch (err) {
    logger.error('Failed to fetch issues', {
      repo,
      label,
      error: err instanceof Error ? err.message : String(err),
    });
    throw new Error(`Failed to fetch issues: ${err instanceof Error ? err.message : String(err)}`);
  }
}

/**
 * Execute tasks using the sliding window scheduler.
 */
async function executeSlidingWindow(
  scheduler: SchedulerState,
  session: SessionState,
  config: RalphyConfig
): Promise<void> {
  logger.info('Starting sliding window execution', {
    maxSlots: scheduler.maxSlots,
    totalTasks: scheduler.queue.length,
  });

  // Initial fill
  const initialTasks = fillSlots(scheduler);
  for (const task of initialTasks) {
    executeTask(task, config, scheduler, session).catch((err) => {
      logger.error('Task execution failed', {
        issueNumber: task.issueNumber,
        error: err instanceof Error ? err.message : String(err),
      });
    });
  }

  // Main loop: wait for tasks to complete, then fill slots
  while (hasWork(scheduler)) {
    await sleep(1000); // Poll every second

    // Log status periodically
    const status = getSchedulerStatus(scheduler);
    logger.debug('Scheduler status', status);

    // Try to fill any free slots
    const newTasks = fillSlots(scheduler);
    for (const task of newTasks) {
      executeTask(task, config, scheduler, session).catch((err) => {
        logger.error('Task execution failed', {
          issueNumber: task.issueNumber,
          error: err instanceof Error ? err.message : String(err),
        });
      });
    }
  }

  logger.info('Sliding window complete');
}

/**
 * Execute a single task (async, fire-and-forget).
 *
 * Creates worktree, spawns agent, creates PR, cleans up.
 */
async function executeTask(
  task: Task,
  config: RalphyConfig,
  scheduler: SchedulerState,
  session: SessionState
): Promise<void> {
  const startTime = Date.now();
  task.status = 'running';
  task.startedAt = new Date();

  logger.info('Task started', { issueNumber: task.issueNumber });

  let worktreeCleanup: (() => Promise<void>) | null = null;

  try {
    // Step 1: Create isolated worktree
    const branchName = `ralphy/issue-${task.issueNumber}`;
    const { worktree, cleanup } = await createWorktree(branchName, {
      baseBranch: config.project.baseBranch,
      prefix: 'ralphy-',
      force: true,
    });

    worktreeCleanup = cleanup;
    task.worktreePath = worktree.path;

    logger.info('Worktree created', {
      issueNumber: task.issueNumber,
      path: worktree.path,
      branch: worktree.branch,
    });

    // Step 2: Build prompt for agent
    const prompt = buildTaskPrompt(task);

    // Step 3: Spawn agent in worktree
    const response = await spawnAgent(prompt, {
      model: config.agent.model,
      maxBudgetUsd: config.agent.maxBudgetUsd,
      systemPrompt: buildSystemPrompt(task),
      cwd: worktree.path,
      yolo: config.agent.yolo,
      maxTurns: config.agent.maxTurns,
      timeoutMs: config.executor.timeoutMinutes * 60 * 1000,
    });

    task.agentSessionId = response.sessionId;
    task.costUsd = response.costUsd;
    session.totalCost += response.costUsd;

    logger.info('Agent completed', {
      issueNumber: task.issueNumber,
      sessionId: response.sessionId,
      cost: response.costUsd,
      duration: response.durationMs,
    });

    // Step 4: Create PR (if configured)
    if (config.executor.createPr) {
      const prNumber = await createPullRequest(task, worktree.branch, config);
      task.prNumber = prNumber;
      logger.info('PR created', { issueNumber: task.issueNumber, prNumber });
    }

    // Mark as completed
    task.status = 'completed';
    task.completedAt = new Date();
    completeTask(scheduler, task.issueNumber, true);

    logger.info('Task completed successfully', {
      issueNumber: task.issueNumber,
      duration: Date.now() - startTime,
    });
  } catch (err) {
    logger.error('Task failed', {
      issueNumber: task.issueNumber,
      error: err instanceof Error ? err.message : String(err),
    });

    task.status = 'failed';
    task.error = err instanceof Error ? err.message : String(err);
    task.completedAt = new Date();
    completeTask(scheduler, task.issueNumber, false);
  } finally {
    // Cleanup worktree
    if (worktreeCleanup) {
      try {
        await worktreeCleanup();
        logger.debug('Worktree cleaned up', { issueNumber: task.issueNumber });
      } catch (err) {
        logger.warn('Worktree cleanup failed', {
          issueNumber: task.issueNumber,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }
  }
}

/**
 * Build the prompt for the agent.
 */
function buildTaskPrompt(task: Task): string {
  return `You are working on a specific task. Focus ONLY on this task:

TASK: #${task.issueNumber} - ${task.title}

${task.body}

Instructions:
1. Implement this task completely
2. Write tests if appropriate
3. Commit your changes with a descriptive message
4. IMPORTANT: You MUST use tools to read and edit files in this repo

SCOPE RULES (MANDATORY):
- ONLY modify files directly required by this task
- Do NOT refactor, rename, delete, or 'clean up' code outside the task scope
- Do NOT remove imports, files, or utilities used by other parts of the codebase
- Other agents are working on other tasks in parallel. Their work must not be disrupted.

Focus only on implementing: ${task.title}`;
}

/**
 * Build the system prompt for the agent.
 */
function buildSystemPrompt(task: Task): string {
  return `You are a software engineer working on issue #${task.issueNumber}.
Your goal is to implement the requested changes, write tests, and commit your work.
Stay focused on the task scope and avoid unnecessary changes.`;
}

/**
 * Create a pull request for the completed task.
 */
async function createPullRequest(
  task: Task,
  branch: string,
  config: RalphyConfig
): Promise<number> {
  logger.debug('Creating PR', { issueNumber: task.issueNumber, branch });

  const { exec } = await import('node:child_process');
  const { promisify } = await import('node:util');
  const execAsync = promisify(exec);

  try {
    // Build PR title and body
    const title = `${task.title}`;
    const body = `Closes #${task.issueNumber}

${task.body}

---
🤖 Generated by Ralphy`;

    // Create PR via gh CLI
    const draftFlag = config.executor.prDraft ? '--draft' : '';
    const { stdout } = await execAsync(
      `gh pr create --repo ${config.project.repo} --base ${config.project.baseBranch} --head ${branch} --title "${title}" --body "${body}" ${draftFlag}`
    );

    // Extract PR number from output (gh returns URL)
    const match = stdout.match(/\/pull\/(\d+)/);
    const prNumber = match ? parseInt(match[1], 10) : 0;

    logger.info('PR created', {
      issueNumber: task.issueNumber,
      prNumber,
      branch,
      draft: config.executor.prDraft,
    });

    return prNumber;
  } catch (err) {
    logger.error('Failed to create PR', {
      issueNumber: task.issueNumber,
      branch,
      error: err instanceof Error ? err.message : String(err),
    });
    throw new Error(`Failed to create PR: ${err instanceof Error ? err.message : String(err)}`);
  }
}

/**
 * Sleep for the given number of milliseconds.
 */
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
