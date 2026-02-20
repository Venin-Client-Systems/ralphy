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
  AutoissueConfig,
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
import { saveState } from './state.js';
import { startUI, updateUI, stopUI } from '../ui/cli-ui.js';
import { selectOptimalModel } from '../lib/model-selector.js';
import { analyzeError, enhancePrompt, calculateBackoff, sleep } from '../lib/smart-retry.js';
import { detectConflicts } from '../lib/conflict-detector.js';
import { decomposeDirective } from './planner.js';
import { DependencyGraph } from '../lib/dependency-graph.js';

/**
 * Execute issues with the given label.
 *
 * Main entry point for direct mode: `autoissue --issues autoissue-1`
 */
export async function executeIssues(
  label: string,
  config: AutoissueConfig,
  options?: { headless?: boolean }
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

    // Step 2.1: Detect file conflicts between tasks
    const conflicts = detectConflicts(tasks);
    if (conflicts.size > 0) {
      logger.warn('File conflicts detected between tasks', {
        conflictCount: conflicts.size,
        details: Array.from(conflicts.entries()),
      });
    }
    logger.info('Tasks classified', {
      tasks: tasks.map((t) => ({
        issue: t.issueNumber,
        domain: t.domain,
      })),
    });

    // Step 2.5: Predict total cost
    const estimatedCost = tasks.length * config.agent.maxBudgetUsd;
    if (config.maxTotalBudgetUsd && estimatedCost > config.maxTotalBudgetUsd) {
      const error = `Estimated cost ($${estimatedCost.toFixed(2)}) exceeds budget ($${config.maxTotalBudgetUsd.toFixed(2)})`;
      logger.error('Budget exceeded', { estimatedCost, budget: config.maxTotalBudgetUsd });
      throw new Error(error);
    }
    logger.info('Cost prediction', {
      tasks: tasks.length,
      estimatedCost: `$${estimatedCost.toFixed(2)}`,
      budget: config.maxTotalBudgetUsd ? `$${config.maxTotalBudgetUsd.toFixed(2)}` : 'unlimited',
      remaining: config.maxTotalBudgetUsd ? `$${(config.maxTotalBudgetUsd - estimatedCost).toFixed(2)}` : 'N/A',
    });

    // Step 3: Create scheduler
    const scheduler = createScheduler(config.executor.maxParallel);
    enqueueTasks(scheduler, tasks);

    // Step 3.5: Start TUI if not headless
    const isHeadless = options?.headless ?? true;
    if (!isHeadless) {
      startUI(session);
    }

    // Step 4: Execute with sliding window
    await executeSlidingWindow(scheduler, session, config, isHeadless);

    // Mark session complete
    session.status = 'completed';
    session.completedAt = new Date().toISOString();

    // Stop TUI
    if (!isHeadless) {
      stopUI();
    }

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
 * Execute in planner mode: directive → AI decomposition → GitHub issues → execution.
 *
 * Main entry point for planner mode: `autoissue --directive "Build user auth system"`
 */
export async function executePlannerMode(
  directive: string,
  config: AutoissueConfig,
  options?: { headless?: boolean; dryRun?: boolean }
): Promise<SessionState> {
  if (!config.planner?.enabled) {
    throw new Error('Planner mode not enabled in config');
  }

  const sessionId = nanoid();
  logger.info('Starting planner mode', { sessionId, directive });

  // Initialize session state
  const session: SessionState = {
    sessionId,
    status: 'running',
    directive,
    tasks: [],
    totalCost: 0,
    startedAt: new Date().toISOString(),
    config,
  };

  try {
    // Step 1: Decompose directive into issues using AI
    logger.info('Decomposing directive with AI', { directive });
    const plannerResult = await decomposeDirective(directive, config.planner, config.project.repo);

    session.totalCost += plannerResult.cost;

    logger.info('Directive decomposed', {
      issueCount: plannerResult.issues.length,
      plannerCost: plannerResult.cost,
      duration: plannerResult.durationMs,
    });

    if (options?.dryRun) {
      console.log('\n📋 Dry-run: Issues to be created:\n');
      plannerResult.issues.forEach((issue, index) => {
        console.log(`${index + 1}. ${issue.title}`);
        console.log(`   Labels: ${issue.labels.join(', ')}`);
        console.log(
          `   Complexity: ${issue.metadata?.complexity || 'medium'}`
        );
        if (issue.metadata?.depends_on && issue.metadata.depends_on.length > 0) {
          console.log(`   Depends on: ${issue.metadata.depends_on.map((d) => `#${d}`).join(', ')}`);
        }
        console.log();
      });
      console.log(`\nPlanner cost: $${plannerResult.cost.toFixed(2)}`);
      session.status = 'completed';
      session.completedAt = new Date().toISOString();
      return session;
    }

    // Step 2: Create GitHub issues
    logger.info('Creating GitHub issues', { count: plannerResult.issues.length });

    const { execFile } = await import('node:child_process');
    const { promisify } = await import('node:util');
    const execFileAsync = promisify(execFile);

    const createdIssues: number[] = [];
    const issueIndexToNumber = new Map<number, number>(); // Map array index to actual issue number

    for (let i = 0; i < plannerResult.issues.length; i++) {
      const payload = plannerResult.issues[i];

      // Build labels argument
      const labels = [...payload.labels];
      const labelsArg = labels.map((l) => ['--label', l]).flat();

      // Create issue
      const { stdout } = await execFileAsync(
        'gh',
        [
          'issue',
          'create',
          '--repo',
          config.project.repo,
          '--title',
          payload.title,
          '--body',
          payload.body,
          ...labelsArg,
        ],
        { encoding: 'utf-8' }
      );

      // Extract issue number from output
      const match = stdout.match(/\/issues\/(\d+)/);
      if (match) {
        const issueNumber = parseInt(match[1], 10);
        createdIssues.push(issueNumber);
        issueIndexToNumber.set(i + 1, issueNumber); // Map 1-indexed to actual number

        logger.info('Issue created', {
          number: issueNumber,
          title: payload.title,
          labels: payload.labels,
        });
      }
    }

    if (createdIssues.length === 0) {
      throw new Error('Failed to create any issues');
    }

    logger.info('All issues created', { count: createdIssues.length });

    // Step 3: Build dependency graph
    const depGraph = new DependencyGraph();
    const tasks: Task[] = [];

    for (let i = 0; i < plannerResult.issues.length; i++) {
      const payload = plannerResult.issues[i];
      const issueNumber = createdIssues[i];

      // Map depends_on indices to actual issue numbers
      const dependsOn =
        payload.metadata?.depends_on?.map((idx) => issueIndexToNumber.get(idx) || 0).filter((n) => n > 0) || [];

      // Classify domain
      const classification = classifyIssue({
        number: issueNumber,
        title: payload.title,
        body: payload.body,
        labels: payload.labels,
        state: 'open',
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        html_url: '',
      });

      const task: Task = {
        issueNumber,
        title: payload.title,
        body: payload.body,
        labels: payload.labels,
        domain: classification.domain,
        status: 'pending',
        metadata: {
          depends_on: dependsOn,
          complexity: payload.metadata?.complexity || 'medium',
        },
      };

      tasks.push(task);
      depGraph.addTask(task, dependsOn);
    }

    // Check for cycles
    if (depGraph.hasCycles()) {
      throw new Error('Dependency graph has cycles - cannot execute');
    }

    session.tasks = tasks;

    // Step 4: Execute with dependency-aware scheduling
    logger.info('Starting dependency-aware execution', {
      totalTasks: tasks.length,
      maxParallel: config.executor.maxParallel,
    });

    // Create scheduler
    const scheduler = createScheduler(config.executor.maxParallel);

    // Start TUI if not headless
    const isHeadless = options?.headless ?? true;
    if (!isHeadless) {
      startUI(session);
    }

    // Execute with dependency awareness
    await executeDependencyAware(scheduler, session, config, depGraph, isHeadless);

    // Mark session complete
    session.status = 'completed';
    session.completedAt = new Date().toISOString();

    // Stop TUI
    if (!isHeadless) {
      stopUI();
    }

    const summary = getSummary(scheduler);
    logger.info('Planner mode execution complete', {
      sessionId,
      ...summary,
      totalCost: session.totalCost,
    });

    return session;
  } catch (err) {
    logger.error('Planner mode execution failed', {
      sessionId,
      error: err instanceof Error ? err.message : String(err),
    });
    session.status = 'failed';
    session.completedAt = new Date().toISOString();
    throw err;
  }
}

/**
 * Execute tasks with dependency awareness using the dependency graph.
 */
async function executeDependencyAware(
  scheduler: SchedulerState,
  session: SessionState,
  config: AutoissueConfig,
  depGraph: DependencyGraph,
  isHeadless: boolean
): Promise<void> {
  logger.info('Starting dependency-aware execution');

  const runningTasks = new Map<number, Promise<void>>();
  const completedIssues = new Set<number>();

  const scheduleNext = () => {
    // Get ready tasks (all dependencies met)
    const readyIssues = depGraph.getReadyTasks(completedIssues);

    // Filter to tasks that are pending and not already running
    const availableTasks = session.tasks.filter(
      (t) =>
        readyIssues.includes(t.issueNumber) &&
        t.status === 'pending' &&
        !runningTasks.has(t.issueNumber)
    );

    // Fill available slots
    const occupiedSlots = scheduler.slots.filter((s) => s.task !== null).length;
    const slotsAvailable = scheduler.maxSlots - occupiedSlots;
    const tasksToStart = availableTasks.slice(0, slotsAvailable);

    for (const task of tasksToStart) {
      logger.info('Starting task (dependencies met)', {
        issueNumber: task.issueNumber,
        dependsOn: task.metadata?.depends_on || [],
      });

      // Find an empty slot
      const emptySlot = scheduler.slots.find((s) => s.task === null);
      if (emptySlot) {
        emptySlot.task = task;
        emptySlot.startedAt = new Date();
      }

      const promise = executeTask(task, config, scheduler, session, isHeadless)
        .then(() => {
          completedIssues.add(task.issueNumber);
        })
        .catch((err) => {
          logger.error('Task execution failed', {
            issueNumber: task.issueNumber,
            error: err instanceof Error ? err.message : String(err),
          });
        })
        .finally(() => {
          // Clear the slot
          const slot = scheduler.slots.find((s) => s.task?.issueNumber === task.issueNumber);
          if (slot) {
            slot.task = null;
            slot.startedAt = null;
          }

          runningTasks.delete(task.issueNumber);
          scheduleNext(); // Immediately try to fill the slot
        });

      runningTasks.set(task.issueNumber, promise);
    }
  };

  // Initial scheduling
  scheduleNext();

  // Wait for all tasks to complete
  while (runningTasks.size > 0 || completedIssues.size < session.tasks.length) {
    if (runningTasks.size > 0) {
      await Promise.race([...runningTasks.values(), new Promise((resolve) => setTimeout(resolve, 100))]);
    } else {
      // Check if we're stuck (tasks pending but none ready)
      const pendingTasks = session.tasks.filter((t) => t.status === 'pending');
      if (pendingTasks.length > 0) {
        const blockedTasks = depGraph.getBlockedTasks();
        logger.error('Execution stuck - tasks pending but blocked', {
          pending: pendingTasks.map((t) => t.issueNumber),
          blocked: Array.from(blockedTasks.entries()),
        });
        throw new Error('Execution stuck: tasks are blocked by incomplete dependencies');
      }
      break;
    }
  }

  logger.info('Dependency-aware execution complete');
}

/**
 * Fetch issues from GitHub by label.
 */
async function fetchIssuesByLabel(repo: string, label: string): Promise<GitHubIssue[]> {
  logger.debug('Fetching issues', { repo, label });

  const { execFile } = await import('node:child_process');
  const { promisify } = await import('node:util');
  const execFileAsync = promisify(execFile);

  try {
    // Use gh CLI to fetch issues
    const { stdout } = await execFileAsync('gh', [
      'issue', 'list',
      '--repo', repo,
      '--label', label,
      '--state', 'open',
      '--json', 'number,title,body,labels,state,assignees,createdAt,updatedAt,url',
      '--limit', '100'
    ], { encoding: 'utf-8' });

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
 * Execute tasks using the sliding window scheduler with event-driven execution.
 */
async function executeSlidingWindow(
  scheduler: SchedulerState,
  session: SessionState,
  config: AutoissueConfig,
  isHeadless: boolean
): Promise<void> {
  logger.info('Starting sliding window execution', {
    maxSlots: scheduler.maxSlots,
    totalTasks: scheduler.queue.length,
  });

  const runningTasks = new Map<number, Promise<void>>();

  const scheduleNext = () => {
    const available = fillSlots(scheduler);
    for (const task of available) {
      const promise = executeTask(task, config, scheduler, session, isHeadless)
        .catch((err) => {
          logger.error('Task execution failed', {
            issueNumber: task.issueNumber,
            error: err instanceof Error ? err.message : String(err),
          });
        })
        .finally(() => {
          runningTasks.delete(task.issueNumber);
          scheduleNext(); // Immediately try to fill the slot
        });

      runningTasks.set(task.issueNumber, promise);
    }
  };

  // Initial scheduling
  scheduleNext();

  // Wait for all tasks to complete
  while (runningTasks.size > 0 || hasWork(scheduler)) {
    if (runningTasks.size > 0) {
      await Promise.race([
        ...runningTasks.values(),
        new Promise(resolve => setTimeout(resolve, 100))
      ]);
    } else {
      // No tasks running but queue has work - should not happen, but safeguard
      await new Promise(resolve => setTimeout(resolve, 100));
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
  config: AutoissueConfig,
  scheduler: SchedulerState,
  session: SessionState,
  isHeadless: boolean
): Promise<void> {
  const startTime = Date.now();
  task.status = 'running';
  task.startedAt = new Date();

  logger.info('Task started', { issueNumber: task.issueNumber });

  let worktreeCleanup: (() => Promise<void>) | null = null;

  try {
    // Step 1: Create isolated worktree
    const branchName = `autoissue/issue-${task.issueNumber}`;
    const { worktree, cleanup } = await createWorktree(branchName, {
      baseBranch: config.project.baseBranch,
      prefix: 'autoissue-',
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
    let currentPrompt = buildTaskPrompt(task);

    // Step 2.5: Select optimal model based on task complexity
    const selectedModel = selectOptimalModel(task, config.agent);
    logger.info('Model selected', {
      issueNumber: task.issueNumber,
      model: selectedModel,
      configuredModel: config.agent.model,
    });

    // Step 3: Spawn agent in worktree with smart retry
    const MAX_RETRIES = 2;
    let retries = 0;
    let lastError: Error | null = null;

    while (retries <= MAX_RETRIES) {
      try {
        const response = await spawnAgent(currentPrompt, {
          model: selectedModel,
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
          attempts: retries + 1,
        });

        // Update UI after agent completion
        if (!isHeadless) {
          updateUI(session);
        }

        // Success! Break out of retry loop
        break;
      } catch (err) {
        lastError = err instanceof Error ? err : new Error(String(err));

        if (retries === MAX_RETRIES) {
          // Out of retries, throw the error
          throw lastError;
        }

        // Analyze error to determine if retryable
        const analysis = analyzeError(lastError.message);

        if (!analysis.retryable) {
          // Non-retryable error, throw immediately
          logger.error('Non-retryable error', {
            issueNumber: task.issueNumber,
            category: analysis.category,
            error: lastError.message,
          });
          throw lastError;
        }

        // Retryable error
        logger.warn('Task failed, retrying with enhanced prompt', {
          issueNumber: task.issueNumber,
          attempt: retries + 1,
          category: analysis.category,
          error: lastError.message,
        });

        // Enhance prompt with error context
        currentPrompt = enhancePrompt(currentPrompt, analysis, retries + 1);

        // Exponential backoff
        const backoffMs = calculateBackoff(retries);
        logger.debug('Waiting before retry', {
          issueNumber: task.issueNumber,
          backoffMs,
        });
        await sleep(backoffMs);

        retries++;
      }
    }

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

    // Update UI
    if (!isHeadless) {
      updateUI(session);
    }

    // Save state after completion
    await saveState(session);

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

    // Update UI
    if (!isHeadless) {
      updateUI(session);
    }

    // Save state after failure
    await saveState(session);
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
  config: AutoissueConfig
): Promise<number> {
  logger.debug('Creating PR', { issueNumber: task.issueNumber, branch });

  const { execFile } = await import('node:child_process');
  const { promisify } = await import('node:util');
  const execFileAsync = promisify(execFile);

  try {
    // Build PR title and body
    const title = `${task.title}`;
    const body = `Closes #${task.issueNumber}

${task.body}

---
🤖 Generated by Autoissue`;

    // Create PR via gh CLI
    const args = [
      'pr', 'create',
      '--repo', config.project.repo,
      '--base', config.project.baseBranch,
      '--head', branch,
      '--title', title,
      '--body', body
    ];

    if (config.executor.prDraft) {
      args.push('--draft');
    }

    const { stdout } = await execFileAsync('gh', args, { encoding: 'utf-8' });

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

