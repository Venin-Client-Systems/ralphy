#!/usr/bin/env node

/**
 * Autoissue 2.0 - Main Entry Point
 *
 * Turn your GitHub backlog into pull requests, overnight.
 */

import { parseArgs, validateCliOptions } from './cli.js';
import { loadConfig, discoverConfig, generateDefaultConfig } from './lib/config.js';
import { executeIssues, executePlannerMode, resumeExecution } from './core/executor.js';
import { loadState, listSessions } from './core/state.js';
import { logger } from './lib/logger.js';

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

    // Enable verbose logging if requested
    if (cliOptions.verbose) {
      logger.setLevel('debug');
    }

    // Validate CLI options
    validateCliOptions(cliOptions);

    // Load or generate config
    let config;
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

    // Execute based on mode
    if (cliOptions.issues) {
      // Direct mode: process issues by label
      console.log(`\n🚀 Autoissue 2.0 - Processing issues labeled "${cliOptions.issues}"\n`);

      const session = await executeIssues(cliOptions.issues, config, {
        headless: cliOptions.headless,
        dashboard: cliOptions.dashboard,
      });

      console.log('\n✅ Execution complete!');
      console.log(`   Total tasks: ${session.tasks.length}`);
      console.log(`   Completed: ${session.tasks.filter((t) => t.status === 'completed').length}`);
      console.log(`   Failed: ${session.tasks.filter((t) => t.status === 'failed').length}`);
      console.log(`   Total cost: $${session.totalCost.toFixed(2)}`);
      console.log();
    } else if (cliOptions.directive) {
      // Planner mode: directive → issues → execution
      console.log(`\n🚀 Autoissue 2.0 - Processing directive\n`);
      console.log(`   "${cliOptions.directive}"\n`);

      const session = await executePlannerMode(cliOptions.directive, config, {
        headless: cliOptions.headless,
        dryRun: cliOptions.dryRun,
        dashboard: cliOptions.dashboard,
      });

      console.log('\n✅ Execution complete!');
      console.log(`   Total tasks: ${session.tasks.length}`);
      console.log(`   Completed: ${session.tasks.filter((t) => t.status === 'completed').length}`);
      console.log(`   Failed: ${session.tasks.filter((t) => t.status === 'failed').length}`);
      console.log(`   Total cost: $${session.totalCost.toFixed(2)}`);
      console.log();
    } else if (cliOptions.resume) {
      // Resume mode - find most recent session or use explicit session ID
      console.log('\n🚀 Autoissue 2.0 - Resume Mode\n');

      const sessions = listSessions();
      if (sessions.length === 0) {
        console.error('❌ No saved sessions found.');
        process.exit(1);
      }

      // Use most recent session
      const sessionId = sessions[0];
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

      console.log('\n✅ Resume complete!');
      console.log(`   Total tasks: ${resumedSession.tasks.length}`);
      console.log(`   Completed: ${resumedSession.tasks.filter((t) => t.status === 'completed').length}`);
      console.log(`   Failed: ${resumedSession.tasks.filter((t) => t.status === 'failed').length}`);
      console.log(`   Total cost: $${resumedSession.totalCost.toFixed(2)}`);
      console.log();
    }
  } catch (err) {
    logger.error('Fatal error', {
      error: err instanceof Error ? err.message : String(err),
    });
    console.error(`\n❌ Error: ${err instanceof Error ? err.message : String(err)}\n`);
    process.exit(1);
  }
}

main();
