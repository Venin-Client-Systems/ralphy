/**
 * CLI Argument Parser
 *
 * Uses Commander to parse command-line arguments for Autoissue 2.0.
 */

import { Command } from 'commander';
import type { CliOptions } from './lib/types.js';

/**
 * Auto-detect mode based on argument.
 */
function detectMode(arg: string | undefined): {
  mode: 'resume' | 'issues' | 'directive';
  value?: string;
} {
  // No argument → resume mode
  if (!arg) {
    return { mode: 'resume' };
  }

  // Label pattern (e.g., "ralphy-1", "autoissue-2", "batch-3") → issue mode
  if (/^[a-z]+-\d+$/i.test(arg)) {
    return { mode: 'issues', value: arg };
  }

  // Single word without spaces (could be a custom label) → issue mode
  if (!/\s/.test(arg)) {
    return { mode: 'issues', value: arg };
  }

  // Multi-word or sentence → directive mode
  return { mode: 'directive', value: arg };
}

/**
 * Parse command-line arguments.
 */
export function parseArgs(argv: string[]): CliOptions {
  const program = new Command();

  program
    .name('autoissue')
    .description('Turn your GitHub backlog into pull requests, overnight')
    .version('2.0.0')
    .argument('[input]', 'Label, directive, or omit for resume')
    .option('-c, --config <path>', 'Path to autoissue.config.json')
    .option('-d, --directive <text>', 'Directive to execute (planner mode, explicit)')
    .option('-i, --issues <label>', 'GitHub label to process (direct mode, explicit)')
    .option('--headless', 'Run without TUI', false)
    .option('--dry-run', 'Show plan without executing', false)
    .option('--ui', 'Launch TUI (default: headless)', false)
    .option('--telegram', 'Start Telegram bot', false)
    .option('--dashboard', 'Enable dashboard server', false)
    .option('--resume', 'Resume last session (explicit)', false)
    .option('-v, --verbose', 'Enable debug logging', false)
    .option('--yolo', 'Skip all permission prompts', false);

  program.parse(argv);

  const opts = program.opts();
  const args = program.args;

  // Auto-detect mode from positional argument (if no explicit flags)
  let directive: string | undefined = opts.directive;
  let issues: string | undefined = opts.issues;
  let resume: boolean = opts.resume || false;

  // Only auto-detect if no explicit mode flags are provided
  if (!directive && !issues && !resume && args.length > 0) {
    const detected = detectMode(args[0]);
    if (detected.mode === 'directive') {
      directive = detected.value;
    } else if (detected.mode === 'issues') {
      issues = detected.value;
    } else if (detected.mode === 'resume') {
      resume = true;
    }
  } else if (!directive && !issues && !resume && args.length === 0) {
    // No args and no flags → default to resume
    resume = true;
  }

  // Build CliOptions
  const cliOptions: CliOptions = {
    config: opts.config,
    directive,
    issues,
    headless: opts.headless || !opts.ui,
    dryRun: opts.dryRun || false,
    ui: opts.ui || false,
    telegram: opts.telegram || false,
    dashboard: opts.dashboard || false,
    resume,
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
  // Can't have both directive and issues
  if (opts.directive && opts.issues) {
    throw new Error('Cannot use both directive and issue label. Choose one mode.');
  }

  // Can't have multiple modes
  if ((opts.directive || opts.issues) && opts.resume) {
    throw new Error('Cannot use --resume with directive or issue label.');
  }

  // Telegram mode requires config
  if (opts.telegram && !opts.config) {
    throw new Error('Telegram mode requires --config with telegram settings');
  }

  // Dry-run only works with directive
  if (opts.dryRun && !opts.directive) {
    throw new Error('--dry-run only works with directive mode');
  }
}
