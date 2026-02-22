import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { logger } from '../lib/logger.js';
import type { ClaudeJsonOutput } from '../lib/types.js';
import { DEFAULT_MAX_TURNS } from '../lib/types.js';
import { withErrorBoundary, CircuitBreaker } from './error-boundaries.js';
import {
  validateModel,
  validateBudget,
  validatePrompt,
  validateSessionId,
  validateTimeout,
  validateCwd,
} from './agent-validation.js';

const execFileAsync = promisify(execFile);
const DEFAULT_TIMEOUT_MS = 600_000; // 10 min — management agents may think long
const SIGKILL_DELAY_MS = 5_000; // 5s grace after SIGTERM before SIGKILL

// Resolve claude binary path once at startup
let claudeBin: string | null = null;

// Global circuit breaker for agent spawn/resume operations
// Shared across all agents to prevent cascading failures
const agentCircuitBreaker = new CircuitBreaker(5, 60000);

async function getClaudeBin(): Promise<string> {
  if (claudeBin) return claudeBin;
  try {
    const { stdout } = await execFileAsync('which', ['claude'], { encoding: 'utf-8' });
    claudeBin = stdout.trim();
    return claudeBin;
  } catch {
    throw new Error('claude CLI not found. Install from https://claude.ai/cli');
  }
}

/**
 * Validated options for spawning a new Claude agent.
 *
 * All parameters are validated at runtime:
 * - model: must be 'opus', 'sonnet', or 'haiku' (validated by Claude CLI)
 * - maxBudgetUsd: minimum 0.01 USD (realistic API call cost)
 * - systemPrompt: non-empty string, max 100k characters
 * - timeoutMs: 5s to 1 hour (prevents instant timeout or runaway)
 * - cwd: must be absolute path if provided
 *
 * Invalid values will cause errors at spawn time with descriptive messages.
 *
 * @category Agent
 *
 * @example
 * ```typescript
 * // Valid configuration
 * const opts: SpawnOptions = {
 *   model: 'sonnet',
 *   maxBudgetUsd: 5.0,
 *   systemPrompt: 'You are a helpful coding assistant.',
 *   maxTurns: 10,
 *   timeoutMs: 300_000, // 5 minutes
 *   cwd: '/absolute/path/to/project',
 *   yolo: false
 * };
 *
 * // Invalid configurations (will error)
 * const bad1 = { model: 'gpt-4', ... };        // Invalid model
 * const bad2 = { maxBudgetUsd: -1, ... };       // Negative budget
 * const bad3 = { systemPrompt: '', ... };       // Empty prompt
 * const bad4 = { timeoutMs: 1000, ... };        // Too short (< 5s)
 * const bad5 = { cwd: './relative', ... };      // Relative path
 * ```
 */
export interface SpawnOptions {
  model: string;
  maxBudgetUsd: number;
  systemPrompt: string;
  maxTurns?: number;
  timeoutMs?: number;
  cwd?: string;
  yolo?: boolean;
}

/**
 * Response object returned by spawnAgent() and resumeAgent().
 *
 * Contains the agent's response content, session information for resumption,
 * and cost/duration metrics for tracking.
 *
 * @category Agent
 *
 * @example
 * ```typescript
 * const response = await spawnAgent('Hello', opts);
 * console.log(response.content);      // "Hello! How can I help?"
 * console.log(response.sessionId);    // "claude-session-abc123"
 * console.log(response.costUsd);      // 0.0023
 * console.log(response.durationMs);   // 1243
 *
 * // Resume the session later
 * await resumeAgent(response.sessionId, 'Continue', opts);
 * ```
 */
export interface AgentResponse {
  content: string;
  sessionId: string;
  costUsd: number;
  durationMs: number;
}

async function runClaude(args: string[], timeoutMs: number, cwd?: string): Promise<string> {
  const bin = await getClaudeBin();
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    const errChunks: Buffer[] = [];
    let settled = false; // Guard against double resolve/reject

    // Unset CLAUDECODE to prevent nested Claude Code sessions from interfering
    const env = { ...process.env };
    delete env.CLAUDECODE;

    const proc = spawn(bin, args, {
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
      cwd,
    });

    proc.stdout.on('data', (chunk: Buffer) => {
      chunks.push(chunk);
      // Stream to console in real-time
      if (process.env.AUTOISSUE_STREAM !== 'false') {
        process.stdout.write(chunk);
      }
    });
    proc.stderr.on('data', (chunk: Buffer) => errChunks.push(chunk));

    let killTimer: ReturnType<typeof setTimeout> | null = null;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      proc.kill('SIGTERM');
      // Follow up with SIGKILL if SIGTERM doesn't work
      killTimer = setTimeout(() => {
        try { proc.kill('SIGKILL'); } catch { /* already dead */ }
      }, SIGKILL_DELAY_MS);
      reject(new Error(`Claude timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    proc.on('close', (code) => {
      clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      if (settled) return; // already rejected by timeout or error
      settled = true;
      const stdout = Buffer.concat(chunks).toString('utf-8');
      const stderr = Buffer.concat(errChunks).toString('utf-8');

      if (code !== 0) {
        logger.error('Claude process failed', { code: code ?? -1, stderr: stderr.slice(0, 500) });
        reject(new Error(`Claude exited ${code}: ${stderr.slice(0, 500)}`));
        return;
      }
      resolve(stdout);
    });

    proc.on('error', (err) => {
      clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      if (settled) return;
      settled = true;
      reject(new Error(`Failed to spawn claude: ${err.message}`));
    });
  });
}

function parseOutput(stdout: string): ClaudeJsonOutput {
  const lines = stdout.trim().split('\n');
  // Search from the end for the JSON envelope with --output-format json
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      const parsed = JSON.parse(lines[i]);
      if (typeof parsed.result === 'string') return parsed;
      // Handle error_max_turns or other cases where result is missing
      if (parsed.type === 'result' && parsed.session_id) {
        return {
          result: parsed.result ?? `[Agent stopped: ${parsed.subtype ?? 'unknown'}]`,
          session_id: parsed.session_id,
          total_cost_usd: parsed.total_cost_usd,
          duration_ms: parsed.duration_ms,
          is_error: parsed.is_error ?? true,
        };
      }
    } catch { /* not JSON, keep looking */ }
  }
  // Last resort: try parsing the whole thing
  try {
    const parsed = JSON.parse(stdout);
    if (typeof parsed.result === 'string') return parsed;
    if (parsed.type === 'result' && parsed.session_id) {
      return {
        result: parsed.result ?? `[Agent stopped: ${parsed.subtype ?? 'unknown'}]`,
        session_id: parsed.session_id,
        total_cost_usd: parsed.total_cost_usd,
        duration_ms: parsed.duration_ms,
        is_error: parsed.is_error ?? true,
      };
    }
  } catch { /* not JSON */ }

  const preview = stdout.slice(0, 300).replace(/\n/g, '\\n');
  throw new Error(`Failed to parse Claude JSON output (expected {result: string}). Got: ${preview}`);
}

/** Spawn a new Claude session */
export async function spawnAgent(
  prompt: string,
  opts: SpawnOptions,
): Promise<AgentResponse> {
  return withErrorBoundary(
    async () => {
      // Validate all inputs before spawning
      validatePrompt(prompt, 'prompt');
      validateModel(opts.model);
      validateBudget(opts.maxBudgetUsd);
      // Only validate system prompt if it's not empty (allows combining into user prompt)
      if (opts.systemPrompt && opts.systemPrompt.trim()) {
        validatePrompt(opts.systemPrompt, 'systemPrompt');
      }

      if (opts.timeoutMs !== undefined) {
        validateTimeout(opts.timeoutMs);
      }

      if (opts.cwd !== undefined) {
        validateCwd(opts.cwd);
      }

      const start = Date.now();
      const maxTurns = opts.maxTurns ?? DEFAULT_MAX_TURNS[opts.model] ?? 8;
      const args = [
        '-p', prompt,
        '--output-format', 'json',
        '--model', opts.model,
        '--max-turns', String(maxTurns),
      ];

      // Only add system prompt if not empty
      if (opts.systemPrompt && opts.systemPrompt.trim()) {
        args.push('--append-system-prompt', opts.systemPrompt);
      }

      if (opts.maxBudgetUsd > 0) {
        args.push('--max-budget-usd', opts.maxBudgetUsd.toString());
      }

      if (opts.yolo) {
        args.push('--dangerously-skip-permissions');
      }

      logger.debug('Spawning agent', { model: opts.model, maxTurns });
      logger.info('Claude CLI command', { command: `claude ${args.join(' ')}`, cwd: opts.cwd });
      const stdout = await runClaude(args, opts.timeoutMs ?? DEFAULT_TIMEOUT_MS, opts.cwd);
      const output = parseOutput(stdout);

      if (output.is_error === true) {
        throw new Error(`Claude agent error: ${output.result}`);
      }

      return {
        content: output.result,
        sessionId: output.session_id,
        costUsd: output.total_cost_usd ?? 0,
        durationMs: Date.now() - start,
      };
    },
    `spawnAgent(${opts.model})`,
    {
      maxRetries: 3,
      baseDelayMs: 1000,
      maxDelayMs: 32000,
    },
    agentCircuitBreaker,
  );
}

/** Resume an existing Claude session */
export async function resumeAgent(
  sessionId: string,
  prompt: string,
  opts: { maxTurns?: number; timeoutMs?: number; cwd?: string; maxBudgetUsd?: number; yolo?: boolean },
): Promise<AgentResponse> {
  return withErrorBoundary(
    async () => {
      // Validate all inputs before resuming
      validateSessionId(sessionId);
      validatePrompt(prompt, 'prompt');

      if (opts.maxBudgetUsd !== undefined) {
        validateBudget(opts.maxBudgetUsd);
      }

      if (opts.timeoutMs !== undefined) {
        validateTimeout(opts.timeoutMs);
      }

      if (opts.cwd !== undefined) {
        validateCwd(opts.cwd);
      }

      const start = Date.now();
      const maxTurns = opts.maxTurns ?? 8;
      const args = [
        '-r', sessionId,
        '-p', prompt,
        '--output-format', 'json',
        '--max-turns', String(maxTurns),
      ];

      if (opts.maxBudgetUsd != null && opts.maxBudgetUsd > 0) {
        args.push('--max-budget-usd', String(opts.maxBudgetUsd));
      }

      if (opts.yolo) {
        args.push('--dangerously-skip-permissions');
      }

      logger.debug('Resuming agent', { sessionId: sessionId.slice(0, 8), maxTurns });
      const stdout = await runClaude(args, opts.timeoutMs ?? DEFAULT_TIMEOUT_MS, opts.cwd);
      const output = parseOutput(stdout);

      if (output.is_error === true) {
        throw new Error(`Claude agent error: ${output.result}`);
      }

      return {
        content: output.result,
        sessionId: output.session_id,
        costUsd: output.total_cost_usd ?? 0,
        durationMs: Date.now() - start,
      };
    },
    `resumeAgent(${sessionId.slice(0, 8)})`,
    {
      maxRetries: 3,
      baseDelayMs: 1000,
      maxDelayMs: 32000,
    },
    agentCircuitBreaker,
  );
}
