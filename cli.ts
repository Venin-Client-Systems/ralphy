/**
 * CLI Argument Parser
 *
 * Uses Commander to parse command-line arguments for Ralphy 2.0.
 */

import { Command } from 'commander';
import type { CliOptions } from './lib/types.js';

/**
 * Parse command-line arguments.
 */
export function parseArgs(argv: string[]): CliOptions {
  const program = new Command();

  program
    .name('ralphy')
    .description('Turn your GitHub backlog into pull requests, overnight')
    .version('2.0.0');

  // Options
  program
    .option('-c, --config <path>', 'Path to ralphy.config.json')
    .option('-d, --directive <text>', 'Directive to execute (planner mode)')
    .option('-i, --issues <label>', 'GitHub label to process (direct mode)')
    .option('--headless', 'Run without TUI', false)
    .option('--dry-run', 'Show plan without executing', false)
    .option('--ui', 'Launch TUI (default: headless)', false)
    .option('--telegram', 'Start Telegram bot', false)
    .option('--dashboard', 'Enable dashboard server', false)
    .option('--resume', 'Resume last session', false)
    .option('-v, --verbose', 'Enable debug logging', false)
    .option('--yolo', 'Skip all permission prompts', false);

  program.parse(argv);

  const opts = program.opts();

  // Build CliOptions
  const cliOptions: CliOptions = {
    config: opts.config,
    directive: opts.directive,
    issues: opts.issues,
    headless: opts.headless || !opts.ui,
    dryRun: opts.dryRun || false,
    ui: opts.ui || false,
    telegram: opts.telegram || false,
    dashboard: opts.dashboard || false,
    resume: opts.resume || false,
    verbose: opts.verbose || false,
    yolo: opts.yolo || false,
  };

  return cliOptions;
}

/**
 * Validate CLI options.
 *
 * Ensures required options are present and combinations make sense.
 */
export function validateCliOptions(opts: CliOptions): void {
  // Must have either directive or issues (or resume)
  if (!opts.directive && !opts.issues && !opts.resume) {
    throw new Error('Must provide --directive, --issues, or --resume');
  }

  // Can't have both directive and issues
  if (opts.directive && opts.issues) {
    throw new Error('Cannot use both --directive and --issues. Choose one mode.');
  }

  // Telegram mode requires config
  if (opts.telegram && !opts.config) {
    throw new Error('Telegram mode requires --config with telegram settings');
  }

  // Dry-run only works with directive
  if (opts.dryRun && !opts.directive) {
    throw new Error('--dry-run only works with --directive');
  }
}
