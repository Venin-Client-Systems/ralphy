#!/usr/bin/env node

/**
 * Autoissue 2.0 - Main Entry Point
 *
 * Turn your GitHub backlog into pull requests, overnight.
 */

import { parseArgs, validateCliOptions } from './cli.js';
import { loadConfig, discoverConfig, generateDefaultConfig } from './lib/config.js';
import { executeIssues, executePlannerMode } from './core/executor.js';
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
      } else {
        // Generate default config
        console.log('No config found. Generating defaults from git repository...');
        config = generateDefaultConfig();
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
      });

      console.log('\n✅ Execution complete!');
      console.log(`   Total tasks: ${session.tasks.length}`);
      console.log(`   Completed: ${session.tasks.filter((t) => t.status === 'completed').length}`);
      console.log(`   Failed: ${session.tasks.filter((t) => t.status === 'failed').length}`);
      console.log(`   Total cost: $${session.totalCost.toFixed(2)}`);
      console.log();
    } else if (cliOptions.resume) {
      // Resume mode
      console.error('Resume mode not yet implemented.');
      process.exit(1);
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
