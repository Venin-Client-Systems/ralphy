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
import { githubApi } from '../lib/github-api.js';
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
import { withErrorBoundary, CircuitBreaker, ErrorBoundaryObserver } from './error-boundaries.js';
import { FeatureFlags } from '../lib/feature-flags.js';
import { detectConflicts } from '../lib/conflict-detector.js';
import { BudgetTracker } from './budget-tracker.js';
import { buildTaskPrompt, buildSystemPrompt } from './prompt-builder.js';
import { createPullRequest as createPR, gatherTaskMetrics } from './pr-manager.js';
import { decomposeDirective } from './planner.js';
import { DependencyGraph } from '../lib/dependency-graph.js';
import { startDashboardServer, broadcastUpdate } from '../server/dashboard.js';
import { homedir } from 'os';
import { join } from 'path';

/**
 * Shared circuit breaker for agent operations.
 * Persists across sessions to prevent cascading failures.
 */
const agentCircuitBreaker = new CircuitBreaker(5, 60000); // 5 failures, 60s reset

/**
 * Error boundary observer for metrics collection.
 */
const errorObserver = new ErrorBoundaryObserver();

/**
 * Resume execution from a previous session.
 *
 * Main entry point for resume mode: `autoissue --resume`
 */
export async function resumeExecution(
  session: SessionState,
  incompleteTasks: Task[],
  options?: { headless?: boolean; dashboard?: boolean }
): Promise<SessionState> {
  logger.info('Resuming execution session', {
    sessionId: session.sessionId,
    incompleteTasks: incompleteTasks.length
  });

  // Initialize budget tracker with remaining budget
  const remainingBudget = Math.max(0, session.config.maxTotalBudgetUsd - session.totalCost);
  const budgetTracker = new BudgetTracker(remainingBudget);

  logger.info('Budget tracker initialized for resume', {
    totalBudget: session.config.maxTotalBudgetUsd,
    alreadySpent: session.totalCost,
    remaining: remainingBudget,
  });

  session.status = 'running';

  // Start dashboard server if enabled
  let stopDashboard: (() => void) | null = null;
  if (options?.dashboard || session.config.dashboard?.enabled) {
    stopDashboard = startDashboardServer(session.config.dashboard?.port || 3030, {
      budgetTracker,
      circuitBreaker: agentCircuitBreaker,
      errorObserver,
      config: session.config.dashboard,
    });
  }

  try {
    // Create scheduler
    const scheduler = createScheduler(session.config.executor.maxParallel);

    // Enqueue only incomplete tasks
    enqueueTasks(scheduler, incompleteTasks);

    // Start TUI if not headless
    const isHeadless = options?.headless ?? true;
    if (!isHeadless) {
      startUI(session);
    }

    // Execute with sliding window
    await executeSlidingWindow(scheduler, session, session.config, budgetTracker, isHeadless, stopDashboard);

    // Mark session complete
    session.status = 'completed';
    session.completedAt = new Date().toISOString();

    // Broadcast final state
    if (stopDashboard) {
      broadcastUpdate(session);
    }

    // Stop TUI
    if (!isHeadless) {
      stopUI();
    }

    const summary = getSummary(scheduler);
    logger.info('Resume complete', {
      sessionId: session.sessionId,
      ...summary,
      totalCost: session.totalCost,
    });

    // Print execution summary
    printExecutionSummary(session);

    return session;
  } catch (err) {
    logger.error('Resume failed', {
      sessionId: session.sessionId,
      error: err instanceof Error ? err.message : String(err),
    });
    session.status = 'failed';
    session.completedAt = new Date().toISOString();
    throw err;
  } finally {
    // Keep dashboard open for 5s to show final state
    if (stopDashboard) {
      setTimeout(() => stopDashboard!(), 5000);
    }
  }
}

/**
 * Execute issues with the given label.
 *
 * Main entry point for direct mode: `autoissue --issues autoissue-1`
 */
export async function executeIssues(
  label: string,
  config: AutoissueConfig,
  options?: { headless?: boolean; dashboard?: boolean }
): Promise<SessionState> {
  const sessionId = nanoid();
  logger.info('Starting execution session', { sessionId, label });

  // Initialize budget tracker
  const budgetTracker = new BudgetTracker(config.maxTotalBudgetUsd);

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

  // Start dashboard server if enabled
  let stopDashboard: (() => void) | null = null;
  if (options?.dashboard || config.dashboard?.enabled) {
    stopDashboard = startDashboardServer(config.dashboard?.port || 3030, {
      budgetTracker,
      circuitBreaker: agentCircuitBreaker,
      errorObserver,
      config: config.dashboard,
    });
  }

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

    // Budget tracking is optional - no enforcement
    const state = budgetTracker.getState();
    logger.debug('Budget state (informational only)', {
      tasks: tasks.length,
      estimatedCost: `$${(budgetTracker.estimateNextTaskCost() * tasks.length).toFixed(2)}`,
      budget: `$${config.maxTotalBudgetUsd.toFixed(2)}`,
      remaining: `$${state.remainingUsd.toFixed(2)}`,
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
    await executeSlidingWindow(scheduler, session, config, budgetTracker, isHeadless, stopDashboard);

    // Mark session complete
    session.status = 'completed';
    session.completedAt = new Date().toISOString();

    // Broadcast final state
    if (stopDashboard) {
      broadcastUpdate(session);
    }

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

    // Print execution summary
    printExecutionSummary(session);

    return session;
  } catch (err) {
    logger.error('Execution failed', {
      sessionId,
      error: err instanceof Error ? err.message : String(err),
    });
    session.status = 'failed';
    session.completedAt = new Date().toISOString();
    throw err;
  } finally {
    // Keep dashboard open for 5s to show final state
    if (stopDashboard) {
      setTimeout(() => stopDashboard!(), 5000);
    }
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
  options?: { headless?: boolean; dryRun?: boolean; dashboard?: boolean }
): Promise<SessionState> {
  if (!config.planner?.enabled) {
    throw new Error('Planner mode not enabled in config');
  }

  const sessionId = nanoid();
  logger.info('Starting planner mode', { sessionId, directive });

  // Initialize budget tracker
  const budgetTracker = new BudgetTracker(config.maxTotalBudgetUsd);

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

  // Start dashboard server if enabled
  let stopDashboard: (() => void) | null = null;
  if (options?.dashboard || config.dashboard?.enabled) {
    stopDashboard = startDashboardServer(config.dashboard?.port || 3030, {
      budgetTracker,
      circuitBreaker: agentCircuitBreaker,
      errorObserver,
      config: config.dashboard,
    });
  }

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

    // Step 3.5: Display and save dependency graph
    if (depGraph && tasks.length > 0) {
      console.log(depGraph.visualize());

      // Save Mermaid diagram
      const outputPath = join(homedir(), '.autoissue', `dep-graph-${sessionId}.html`);
      depGraph.saveMermaidDiagram(outputPath);
      console.log(`📊 Dependency graph saved: ${outputPath}\n`);
    }

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
    await executeDependencyAware(scheduler, session, config, depGraph, budgetTracker, isHeadless, stopDashboard);

    // Mark session complete
    session.status = 'completed';
    session.completedAt = new Date().toISOString();

    // Broadcast final state
    if (stopDashboard) {
      broadcastUpdate(session);
    }

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

    // Print execution summary
    printExecutionSummary(session);

    return session;
  } catch (err) {
    logger.error('Planner mode execution failed', {
      sessionId,
      error: err instanceof Error ? err.message : String(err),
    });
    session.status = 'failed';
    session.completedAt = new Date().toISOString();
    throw err;
  } finally {
    // Keep dashboard open for 5s to show final state
    if (stopDashboard) {
      setTimeout(() => stopDashboard!(), 5000);
    }
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
  budgetTracker: BudgetTracker,
  isHeadless: boolean,
  stopDashboard?: (() => void) | null
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

      const promise = executeTask(task, config, scheduler, session, budgetTracker, isHeadless, stopDashboard)
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
 *
 * Uses @octokit/rest for 10x performance improvement over gh CLI.
 */
async function fetchIssuesByLabel(repo: string, label: string): Promise<GitHubIssue[]> {
  logger.debug('Fetching issues via Octokit', { repo, label });

  try {
    // Use Octokit API (10x faster than gh CLI)
    const issues = await githubApi.listIssues(repo, [label]);

    logger.info('Fetched issues from GitHub via Octokit', {
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
  budgetTracker: BudgetTracker,
  isHeadless: boolean,
  stopDashboard?: (() => void) | null
): Promise<void> {
  logger.info('Starting sliding window execution', {
    maxSlots: scheduler.maxSlots,
    totalTasks: scheduler.queue.length,
  });

  const runningTasks = new Map<number, Promise<void>>();

  const scheduleNext = () => {
    const available = fillSlots(scheduler);
    for (const task of available) {
      const promise = executeTask(task, config, scheduler, session, budgetTracker, isHeadless, stopDashboard)
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
  budgetTracker: BudgetTracker,
  isHeadless: boolean,
  stopDashboard?: (() => void) | null
): Promise<void> {
  const startTime = Date.now();
  task.status = 'running';
  task.startedAt = new Date();
  task.currentAction = 'Initializing...';

  // Broadcast status update
  if (stopDashboard) {
    broadcastUpdate(session);
  }

  logger.info('Task started', { issueNumber: task.issueNumber });

  let worktreeCleanup: (() => Promise<void>) | null = null;

  try {
    // Step 1: Create isolated worktree
    task.currentAction = 'Creating worktree...';
    if (!isHeadless) updateUI(session);

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

    // Step 3: Spawn agent in worktree with error boundary
    task.currentAction = `Running ${selectedModel} agent...`;
    if (!isHeadless) updateUI(session);

    // Execute with error boundary and circuit breaker
    const response = await withErrorBoundary(
      async () => {
        return await spawnAgent(currentPrompt, {
          model: selectedModel,
          maxBudgetUsd: config.agent.maxBudgetUsd,
          systemPrompt: buildSystemPrompt(task),
          cwd: worktree.path,
          yolo: config.agent.yolo,
          maxTurns: config.agent.maxTurns,
          timeoutMs: config.executor.timeoutMinutes * 60 * 1000,
        });
      },
      `Task #${task.issueNumber} (${selectedModel})`,
      {
        maxRetries: 2,
        observer: FeatureFlags.ENABLE_METRICS ? errorObserver : undefined,
      },
      agentCircuitBreaker
    );

    logger.info('Agent completed', {
      issueNumber: task.issueNumber,
      sessionId: response.sessionId,
      cost: response.costUsd,
      duration: response.durationMs,
    });

    task.agentSessionId = response.sessionId;
    task.costUsd = response.costUsd;
    session.totalCost += response.costUsd;

    task.currentAction = 'Agent completed, committing changes...';
    if (!isHeadless) updateUI(session);

    // Step 3.5: Commit agent's changes (required for PR creation)
    try {
      const { execFile } = await import('node:child_process');
      const { promisify } = await import('node:util');
      const execFileAsync = promisify(execFile);

      // Check if there are changes to commit
      const { stdout: statusOutput } = await execFileAsync('git', ['status', '--porcelain'], {
        cwd: worktree.path,
      });

      if (statusOutput.trim()) {
        // Stage all changes
        await execFileAsync('git', ['add', '-A'], { cwd: worktree.path });

        // Commit with descriptive message
        const commitMessage = `fix: ${task.title}

Resolves #${task.issueNumber}

${task.body.split('\n').slice(0, 3).join('\n')}

Co-authored-by: Claude AI <noreply@anthropic.com>`;

        await execFileAsync('git', ['commit', '-m', commitMessage], {
          cwd: worktree.path,
        });

        logger.info('Changes committed', { issueNumber: task.issueNumber });
      } else {
        logger.warn('No changes to commit', { issueNumber: task.issueNumber });
        throw new Error('Agent completed but made no changes to commit');
      }
    } catch (err) {
      logger.error('Failed to commit changes', {
        issueNumber: task.issueNumber,
        error: err instanceof Error ? err.message : String(err),
      });
      throw err;
    }

    task.currentAction = 'Changes committed, gathering metrics...';
    if (!isHeadless) updateUI(session);

    // Step 4: Gather task metrics
    try {
      const metrics = await gatherTaskMetrics(worktree.path);
      task.metadata = {
        ...task.metadata,
        linesAdded: metrics.linesAdded,
        linesRemoved: metrics.linesRemoved,
        filesChanged: metrics.filesChanged,
      };

      logger.info('Task metrics', {
        issueNumber: task.issueNumber,
        ...metrics
      });
    } catch (err) {
      logger.warn('Failed to gather metrics', { issueNumber: task.issueNumber });
    }

    // Step 5: Create PR (if configured)
    if (config.executor.createPr) {
      const prNumber = await createPR(task, worktree.branch, config, worktree.path);
      task.prNumber = prNumber;
      logger.info('PR created', { issueNumber: task.issueNumber, prNumber });
    }

    // Mark as completed
    task.status = 'completed';
    task.completedAt = new Date();
    completeTask(scheduler, task.issueNumber, true);

    // Broadcast status update
    if (stopDashboard) {
      broadcastUpdate(session);
    }

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

    // Broadcast status update
    if (stopDashboard) {
      broadcastUpdate(session);
    }

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
 * Print execution summary with PR links and metrics.
 */
function printExecutionSummary(session: SessionState): void {
  const completed = session.tasks.filter(t => t.status === 'completed');
  const failed = session.tasks.filter(t => t.status === 'failed');

  console.log('\n' + '='.repeat(60));
  console.log('📊 EXECUTION SUMMARY');
  console.log('='.repeat(60));

  console.log(`\n✅ Completed: ${completed.length} tasks`);
  console.log(`❌ Failed: ${failed.length} tasks`);
  console.log(`💰 Total cost: $${session.totalCost.toFixed(2)}`);
  console.log(`⏱️  Duration: ${getDuration(session)}`);

  if (completed.length > 0) {
    console.log('\n✅ Successful PRs:');
    completed.forEach(t => {
      const prUrl = `https://github.com/${session.config.project.repo}/pull/${t.prNumber}`;
      console.log(`  #${t.issueNumber}: ${t.title}`);
      console.log(`    → PR #${t.prNumber}: ${prUrl}`);
      console.log(`    💰 Cost: $${(t.costUsd || 0).toFixed(2)}`);
      if (t.metadata?.linesAdded || t.metadata?.linesRemoved) {
        console.log(`    📝 Changes: +${t.metadata.linesAdded || 0} -${t.metadata.linesRemoved || 0} lines, ${t.metadata.filesChanged || 0} files`);
      }
    });
  }

  if (failed.length > 0) {
    console.log('\n❌ Failed Tasks:');
    failed.forEach(t => {
      console.log(`  #${t.issueNumber}: ${t.title}`);
      console.log(`    Error: ${t.error?.slice(0, 100)}`);
    });
  }

  // Cost breakdown by domain
  const costByDomain = new Map<string, number>();
  for (const task of session.tasks) {
    const current = costByDomain.get(task.domain) || 0;
    costByDomain.set(task.domain, current + (task.costUsd || 0));
  }

  console.log('\n💰 Cost Breakdown by Domain:');
  for (const [domain, cost] of costByDomain) {
    const count = session.tasks.filter(t => t.domain === domain).length;
    console.log(`  ${domain}: $${cost.toFixed(2)} (${count} tasks, avg $${(cost/count).toFixed(2)}/task)`);
  }

  // Code impact metrics
  if (completed.length > 0) {
    const totalLines = completed.reduce((sum, t) =>
      sum + (t.metadata?.linesAdded || 0) + (t.metadata?.linesRemoved || 0), 0);
    const totalFiles = completed.reduce((sum, t) =>
      sum + (t.metadata?.filesChanged || 0), 0);

    if (totalLines > 0) {
      console.log('\n📈 Code Impact:');
      console.log(`  Total lines changed: ${totalLines.toLocaleString()}`);
      console.log(`  Total files modified: ${totalFiles}`);
      console.log(`  Avg lines/task: ${Math.round(totalLines / completed.length)}`);
    }
  }

  console.log('\n' + '='.repeat(60));
}

/**
 * Get duration string from session.
 */
function getDuration(session: SessionState): string {
  const start = new Date(session.startedAt).getTime();
  const end = session.completedAt
    ? new Date(session.completedAt).getTime()
    : Date.now();
  const durationMs = end - start;
  const minutes = Math.floor(durationMs / 60000);
  const seconds = Math.floor((durationMs % 60000) / 1000);
  return `${minutes}m ${seconds}s`;
}

