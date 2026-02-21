#!/usr/bin/env node

/**
 * Autoissue 2.0 - Main Entry Point
 *
 * Turn your GitHub backlog into pull requests, overnight.
 */

import { parseArgs, validateCliOptions, type ParsedCliOptions } from './cli.js';
import { loadConfig, discoverConfig, generateDefaultConfig } from './lib/config.js';
import { executeIssues, executePlannerMode, resumeExecution } from './core/executor.js';
import { loadState, listSessions } from './core/state.js';
import { logger } from './lib/logger.js';
import type { AutoissueConfig } from './lib/types.js';

let shutdownRequested = false;
const activeControllers = new Set<AbortController>();

// Graceful shutdown handlers
process.on('SIGINT', async () => {
  if (shutdownRequested) {
    console.log('\n🔴 Force quit');
    process.exit(1);
  }

  shutdownRequested = true;
  console.log('\n🛑 Shutting down gracefully... (Ctrl+C again to force)');

  // Abort all active operations
  for (const controller of activeControllers) {
    controller.abort();
  }

  // Wait for cleanup
  await new Promise(resolve => setTimeout(resolve, 2000));
  console.log('✅ Shutdown complete');
  process.exit(0);
});

process.on('SIGTERM', () => process.kill(process.pid, 'SIGINT'));

async function main(): Promise<void> {
  try {
    // Parse CLI arguments
    const cliOptions = parseArgs(process.argv);

    // Set log level based on mode
    if (cliOptions.verbose) {
      logger.setLevel('debug');
    } else if (!cliOptions.headless) {
      // UI mode: suppress logs, TUI shows status
      logger.setLevel('error');
    }

    // Validate CLI options
    validateCliOptions(cliOptions);

    // Route to subcommand handler
    switch (cliOptions.subcommand) {
      case 'exec':
        await handleExecCommand(cliOptions);
        break;
      case 'plan':
        await handlePlanCommand(cliOptions);
        break;
      case 'resume':
        await handleResumeCommand(cliOptions);
        break;
      case 'status':
        await handleStatusCommand(cliOptions);
        break;
      case 'metrics':
        await handleMetricsCommand(cliOptions);
        break;
      default:
        throw new Error('No valid subcommand specified. Use: exec, plan, resume, status, or metrics');
    }
  } catch (err) {
    logger.error('Fatal error', {
      error: err instanceof Error ? err.message : String(err),
    });
    console.error(`\n❌ Error: ${err instanceof Error ? err.message : String(err)}\n`);
    process.exit(1);
  }
}

/**
 * Handle `autoissue exec <label>` command.
 */
async function handleExecCommand(cliOptions: ParsedCliOptions): Promise<void> {
  if (!cliOptions.issues) {
    throw new Error('Label is required for exec command');
  }

  const config = await loadConfigWithFallback(cliOptions);

  console.log(`\n🚀 Autoissue 2.0 - Executing issues labeled "${cliOptions.issues}"\n`);

  const session = await executeIssues(cliOptions.issues, config, {
    headless: cliOptions.headless,
    dashboard: cliOptions.dashboard,
  });

  printSessionSummary(session);
}

/**
 * Handle `autoissue plan <directive>` command.
 */
async function handlePlanCommand(cliOptions: ParsedCliOptions): Promise<void> {
  if (!cliOptions.directive) {
    throw new Error('Directive is required for plan command');
  }

  const config = await loadConfigWithFallback(cliOptions);

  console.log(`\n🚀 Autoissue 2.0 - Planning and executing\n`);
  console.log(`   "${cliOptions.directive}"\n`);

  const session = await executePlannerMode(cliOptions.directive, config, {
    headless: cliOptions.headless,
    dryRun: cliOptions.dryRun,
    dashboard: cliOptions.dashboard,
  });

  printSessionSummary(session);
}

/**
 * Handle `autoissue resume [session-id]` command.
 */
async function handleResumeCommand(cliOptions: ParsedCliOptions): Promise<void> {
  console.log('\n🚀 Autoissue 2.0 - Resume Mode\n');

  const sessions = listSessions();
  if (sessions.length === 0) {
    console.error('❌ No saved sessions found.');
    process.exit(1);
  }

  // Use explicit session ID or most recent
  const sessionId = cliOptions.sessionId || sessions[0];
  const session = loadState(sessionId);

  if (!session) {
    console.error(`❌ Session not found: ${sessionId}`);
    console.log('\nAvailable sessions:');
    sessions.slice(0, 10).forEach(id => console.log(`  - ${id}`));
    process.exit(1);
  }

  console.log(`📂 Resuming session: ${sessionId}`);
  console.log(`   Started: ${session.startedAt}`);
  console.log(`   Tasks: ${session.tasks.length}`);

  // Find incomplete tasks
  const incompleteTasks = session.tasks.filter(t =>
    t.status === 'pending' || t.status === 'running'
  );

  if (incompleteTasks.length === 0) {
    console.log('✅ Session already complete!');
    process.exit(0);
  }

  console.log(`   Resuming ${incompleteTasks.length} incomplete tasks...\n`);

  // Resume execution
  const resumedSession = await resumeExecution(session, incompleteTasks, {
    headless: cliOptions.headless,
    dashboard: cliOptions.dashboard,
  });

  printSessionSummary(resumedSession);
}

/**
 * Handle `autoissue status` command.
 */
async function handleStatusCommand(cliOptions: ParsedCliOptions): Promise<void> {
  console.log('\n📊 Autoissue Status\n');

  const sessions = listSessions();
  if (sessions.length === 0) {
    console.log('No sessions found.');
    return;
  }

  console.log(`Recent sessions (showing last 10):\n`);

  for (const sessionId of sessions.slice(0, 10)) {
    const session = loadState(sessionId);
    if (!session) continue;

    const status = session.status === 'completed' ? '✅' :
                   session.status === 'failed' ? '❌' :
                   session.status === 'running' ? '🔄' : '⏸️';

    const completed = session.tasks.filter(t => t.status === 'completed').length;
    const failed = session.tasks.filter(t => t.status === 'failed').length;
    const total = session.tasks.length;

    console.log(`${status} ${sessionId}`);
    console.log(`   Started: ${session.startedAt}`);
    console.log(`   Tasks: ${completed}/${total} completed, ${failed} failed`);
    console.log(`   Cost: $${session.totalCost.toFixed(2)}`);
    if (session.label) {
      console.log(`   Label: ${session.label}`);
    }
    if (session.directive) {
      console.log(`   Directive: ${session.directive.slice(0, 60)}...`);
    }
    console.log();
  }
}

/**
 * Handle `autoissue metrics` command.
 */
async function handleMetricsCommand(cliOptions: ParsedCliOptions): Promise<void> {
  console.log('\n📈 Autoissue Metrics\n');

  const sessions = listSessions();
  if (sessions.length === 0) {
    console.log('No sessions found.');
    return;
  }

  // Aggregate metrics
  let totalSessions = 0;
  let totalTasks = 0;
  let completedTasks = 0;
  let failedTasks = 0;
  let totalCost = 0;
  let totalLinesAdded = 0;
  let totalLinesRemoved = 0;
  let totalFilesChanged = 0;

  for (const sessionId of sessions) {
    const session = loadState(sessionId);
    if (!session) continue;

    totalSessions++;
    totalTasks += session.tasks.length;
    completedTasks += session.tasks.filter(t => t.status === 'completed').length;
    failedTasks += session.tasks.filter(t => t.status === 'failed').length;
    totalCost += session.totalCost;

    for (const task of session.tasks) {
      if (task.metadata) {
        totalLinesAdded += task.metadata.linesAdded || 0;
        totalLinesRemoved += task.metadata.linesRemoved || 0;
        totalFilesChanged += task.metadata.filesChanged || 0;
      }
    }
  }

  console.log('Overall Statistics:');
  console.log(`  Sessions: ${totalSessions}`);
  console.log(`  Tasks: ${totalTasks} (${completedTasks} completed, ${failedTasks} failed)`);
  console.log(`  Success rate: ${totalTasks > 0 ? ((completedTasks / totalTasks) * 100).toFixed(1) : 0}%`);
  console.log(`  Total cost: $${totalCost.toFixed(2)}`);
  console.log(`  Avg cost/task: $${totalTasks > 0 ? (totalCost / totalTasks).toFixed(2) : '0.00'}`);
  console.log();

  console.log('Code Impact:');
  console.log(`  Lines added: ${totalLinesAdded.toLocaleString()}`);
  console.log(`  Lines removed: ${totalLinesRemoved.toLocaleString()}`);
  console.log(`  Files changed: ${totalFilesChanged.toLocaleString()}`);
  console.log(`  Avg lines/task: ${completedTasks > 0 ? Math.round((totalLinesAdded + totalLinesRemoved) / completedTasks) : 0}`);
  console.log();
}

/**
 * Load config with auto-discovery fallback.
 */
async function loadConfigWithFallback(cliOptions: ParsedCliOptions): Promise<AutoissueConfig> {
  let config: AutoissueConfig;

  if (cliOptions.config) {
    // Explicit config path
    config = loadConfig(cliOptions.config);
  } else {
    // Auto-discover or generate
    const discoveredPath = discoverConfig();
    if (discoveredPath) {
      config = loadConfig(discoveredPath);
      logger.debug('Config loaded from', { path: discoveredPath });
    } else {
      // Generate default config
      logger.debug('No config file found, generating defaults...');
      config = generateDefaultConfig();
      console.log(`✅ Auto-detected: ${config.project.repo} (${config.project.path})`);
    }
  }

  // Override with CLI options
  if (cliOptions.yolo) {
    config.agent.yolo = true;
  }

  return config;
}

/**
 * Print session summary.
 */
function printSessionSummary(session: any): void {
  const completed = session.tasks.filter((t: any) => t.status === 'completed').length;
  const failed = session.tasks.filter((t: any) => t.status === 'failed').length;
  const total = session.tasks.length;

  // Show success/failure based on actual results
  if (completed === 0 && failed > 0) {
    console.log('\n❌ Execution failed - all tasks unsuccessful!');
  } else if (completed === total) {
    console.log('\n✅ Execution complete - all tasks successful!');
  } else if (completed > 0) {
    console.log('\n⚠️  Execution complete with failures!');
  } else {
    console.log('\n✅ Execution complete!');
  }

  console.log(`   Total tasks: ${total}`);
  console.log(`   Completed: ${completed}`);
  console.log(`   Failed: ${failed}`);
  console.log(`   Total cost: $${session.totalCost.toFixed(2)}`);
  console.log();
}

main();
