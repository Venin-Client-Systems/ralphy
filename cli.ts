/**
 * CLI Argument Parser with Subcommands
 *
 * Explicit subcommands for clarity - no auto-detection.
 */

import { Command } from 'commander';
import type { CliOptions } from './lib/types.js';

/**
 * Subcommand type for routing.
 */
export type Subcommand = 'exec' | 'plan' | 'resume' | 'status' | 'metrics' | null;

/**
 * Extended CLI options with subcommand.
 */
export interface ParsedCliOptions extends CliOptions {
  subcommand: Subcommand;
  sessionId?: string; // For resume command
}

const KNOWN_SUBCOMMANDS = ['exec', 'plan', 'resume', 'status', 'metrics'];

/**
 * Parse command-line arguments with subcommands.
 */
export function parseArgs(argv: string[]): ParsedCliOptions {
  // Check if using legacy syntax (no subcommand)
  const firstArg = argv[2];
  const isLegacySyntax = firstArg && !firstArg.startsWith('-') && !KNOWN_SUBCOMMANDS.includes(firstArg);

  if (isLegacySyntax) {
    return parseLegacyArgs(argv);
  }

  const program = new Command();

  program
    .name('autoissue')
    .description('Turn your GitHub backlog into pull requests, overnight')
    .version('2.0.0')
    .allowUnknownOption(false);

  // Global options
  program
    .option('-c, --config <path>', 'Path to autoissue.config.json')
    .option('--headless', 'Run without TUI (logs only)', false)
    .option('--dashboard', 'Enable dashboard server', false)
    .option('-v, --verbose', 'Enable debug logging', false)
    .option('--yolo', 'Skip all permission prompts', false);

  // Subcommand: exec
  program
    .command('exec <label>')
    .description('Execute issues by GitHub label')
    .action(() => {}); // Handled after parse

  // Subcommand: plan
  program
    .command('plan <directive>')
    .description('Plan and execute from natural language directive')
    .option('--dry-run', 'Show plan without executing', false)
    .action(() => {}); // Handled after parse

  // Subcommand: resume
  program
    .command('resume [session-id]')
    .description('Resume a previous session (uses most recent if no ID provided)')
    .action(() => {}); // Handled after parse

  // Subcommand: status
  program
    .command('status')
    .description('Show status of recent sessions')
    .action(() => {}); // Handled after parse

  // Subcommand: metrics
  program
    .command('metrics')
    .description('Show metrics and performance data')
    .action(() => {}); // Handled after parse

  program.parse(argv);

  const opts = program.opts();
  const args = program.args;

  // Detect subcommand
  let subcommand: Subcommand = null;
  let directive: string | undefined;
  let issues: string | undefined;
  let resume = false;
  let sessionId: string | undefined;
  let dryRun = false;

  if (args.length > 0) {
    const cmd = args[0];
    if (cmd === 'exec' && args[1]) {
      subcommand = 'exec';
      issues = args[1];
    } else if (cmd === 'plan' && args[1]) {
      subcommand = 'plan';
      directive = args[1];
      const planCmd = program.commands.find(c => c.name() === 'plan');
      if (planCmd) {
        dryRun = planCmd.opts().dryRun || false;
      }
    } else if (cmd === 'resume') {
      subcommand = 'resume';
      resume = true;
      sessionId = args[1];
    } else if (cmd === 'status') {
      subcommand = 'status';
    } else if (cmd === 'metrics') {
      subcommand = 'metrics';
    }
  }

  // Default to resume if no subcommand
  if (!subcommand && args.length === 0) {
    subcommand = 'resume';
    resume = true;
  }

  const cliOptions: ParsedCliOptions = {
    subcommand,
    config: opts.config,
    directive,
    issues,
    sessionId,
    headless: opts.headless || false,
    dryRun,
    ui: !opts.headless,
    telegram: false,
    dashboard: opts.dashboard || false,
    resume,
    verbose: opts.verbose || false,
    yolo: opts.yolo || false,
  };

  return cliOptions;
}

/**
 * Parse legacy CLI arguments (backward compatibility).
 */
function parseLegacyArgs(argv: string[]): ParsedCliOptions {
  const program = new Command();

  program
    .name('autoissue')
    .version('2.0.0')
    .argument('[input]', 'Label or directive')
    .option('-c, --config <path>', 'Path to autoissue.config.json')
    .option('-d, --directive <text>', 'Directive to execute (planner mode)')
    .option('-i, --issues <label>', 'GitHub label to process (direct mode)')
    .option('--headless', 'Run without TUI (logs only)', false)
    .option('--dry-run', 'Show plan without executing', false)
    .option('--dashboard', 'Enable dashboard server', false)
    .option('--resume', 'Resume last session', false)
    .option('-v, --verbose', 'Enable debug logging', false)
    .option('--yolo', 'Skip all permission prompts', false);

  program.parse(argv);

  const opts = program.opts();
  const args = program.args;

  let directive: string | undefined = opts.directive;
  let issues: string | undefined = opts.issues;
  let resume: boolean = opts.resume || false;
  let subcommand: Subcommand = null;

  // Show deprecation warning
  console.warn('\n⚠️  LEGACY USAGE DETECTED - Please migrate to explicit subcommands:\n');
  console.warn('  autoissue exec <label>       - Execute issues by label');
  console.warn('  autoissue plan "<directive>" - Plan and execute from directive');
  console.warn('  autoissue resume             - Resume last session');
  console.warn('  autoissue status             - Show session status');
  console.warn('  autoissue metrics            - Show metrics\n');

  // Auto-detect mode if using positional argument
  if (!directive && !issues && !resume && args.length > 0) {
    const detected = detectModeLegacy(args[0]);
    if (detected.mode === 'directive') {
      subcommand = 'plan';
      directive = detected.value;
    } else if (detected.mode === 'issues') {
      subcommand = 'exec';
      issues = detected.value;
    } else if (detected.mode === 'resume') {
      subcommand = 'resume';
      resume = true;
    }
  } else if (opts.directive) {
    subcommand = 'plan';
    directive = opts.directive;
  } else if (opts.issues) {
    subcommand = 'exec';
    issues = opts.issues;
  } else if (opts.resume) {
    subcommand = 'resume';
    resume = true;
  } else if (!directive && !issues && !resume) {
    // Default to resume
    subcommand = 'resume';
    resume = true;
  }

  return {
    subcommand,
    config: opts.config,
    directive,
    issues,
    sessionId: undefined,
    headless: opts.headless || false,
    dryRun: opts.dryRun || false,
    ui: !opts.headless,
    telegram: false,
    dashboard: opts.dashboard || false,
    resume,
    verbose: opts.verbose || false,
    yolo: opts.yolo || false,
  };
}

/**
 * Legacy auto-detect mode (for backward compatibility).
 */
function detectModeLegacy(arg: string | undefined): {
  mode: 'resume' | 'issues' | 'directive';
  value?: string;
} {
  if (!arg) {
    return { mode: 'resume' };
  }

  // Label pattern (e.g., "ralphy-1", "autoissue-2", "batch-3")
  if (/^[a-z]+-\d+$/i.test(arg)) {
    return { mode: 'issues', value: arg };
  }

  // Single word without spaces (could be a custom label)
  if (!/\s/.test(arg)) {
    return { mode: 'issues', value: arg };
  }

  // Multi-word or sentence → directive mode
  return { mode: 'directive', value: arg };
}

/**
 * Validate CLI options.
 */
export function validateCliOptions(opts: ParsedCliOptions): void {
  // Must have a subcommand
  if (!opts.subcommand) {
    throw new Error('No subcommand specified. Use: exec, plan, resume, status, or metrics');
  }

  // Can't have both directive and issues
  if (opts.directive && opts.issues) {
    throw new Error('Cannot use both directive and issue label. Choose one mode.');
  }

  // Can't have multiple modes
  if ((opts.directive || opts.issues) && opts.resume) {
    throw new Error('Cannot use multiple modes simultaneously.');
  }

  // Dry-run only works with plan
  if (opts.dryRun && opts.subcommand !== 'plan') {
    throw new Error('--dry-run only works with "plan" subcommand');
  }
}
