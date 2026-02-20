/**
 * Agent input validation functions.
 *
 * Validates parameters for spawnAgent() and resumeAgent() before spawning
 * Claude CLI processes. All validators throw specific error types with
 * recovery hints for remediation.
 *
 * @module agent-validation
 */

import {
  AgentValidationError,
  ModelValidationError,
  BudgetValidationError,
  PromptValidationError,
  SessionValidationError,
  TimeoutValidationError,
  WorkingDirectoryValidationError,
} from './agent-errors.js';

const MIN_TIMEOUT_MS = 5_000; // 5 seconds
const MAX_TIMEOUT_MS = 3_600_000; // 1 hour
const MAX_PROMPT_LENGTH = 100_000;
const MIN_BUDGET_USD = 0.01;
const MIN_SESSION_ID_LENGTH = 5;

/**
 * Validate model name.
 *
 * @throws {ModelValidationError} If model is not 'opus', 'sonnet', or 'haiku'
 */
export function validateModel(model: string): void {
  const validModels = ['opus', 'sonnet', 'haiku'];
  if (!validModels.includes(model)) {
    throw new ModelValidationError(model);
  }
}

/**
 * Validate budget amount.
 *
 * Budget must be at least 0.01 USD to cover realistic API call costs.
 *
 * @throws {BudgetValidationError} If budget is negative, zero, or below minimum
 */
export function validateBudget(budget: number): void {
  if (budget <= 0 || budget < MIN_BUDGET_USD) {
    throw new BudgetValidationError(budget);
  }
}

/**
 * Validate prompt string.
 *
 * Prompts must be non-empty, non-whitespace strings with max 100k characters.
 *
 * @param prompt - The prompt to validate
 * @param label - Label for error messages (e.g., 'prompt', 'systemPrompt')
 * @throws {PromptValidationError} If prompt is empty, whitespace-only, or too long
 */
export function validatePrompt(prompt: string, label = 'prompt'): void {
  if (!prompt || prompt.trim().length === 0) {
    throw new PromptValidationError(`${label} is empty or whitespace-only`);
  }
  if (prompt.length > MAX_PROMPT_LENGTH) {
    throw new PromptValidationError(
      `${label} exceeds ${MAX_PROMPT_LENGTH.toLocaleString()} characters (got ${prompt.length.toLocaleString()})`,
    );
  }
}

/**
 * Validate session ID format.
 *
 * Session IDs must be:
 * - Non-empty and trimmed
 * - At least 5 characters long
 * - Contain only alphanumeric characters, hyphens, and underscores
 *
 * @throws {SessionValidationError} If session ID is malformed
 */
export function validateSessionId(sessionId: string): void {
  if (!sessionId || sessionId.trim().length === 0) {
    throw new SessionValidationError(sessionId, 'empty or whitespace-only');
  }
  if (sessionId.length < MIN_SESSION_ID_LENGTH) {
    throw new SessionValidationError(
      sessionId,
      `too short (minimum ${MIN_SESSION_ID_LENGTH} characters)`,
    );
  }
  // Check for valid characters (alphanumeric, hyphens, underscores)
  if (!/^[a-zA-Z0-9_-]+$/.test(sessionId)) {
    throw new SessionValidationError(
      sessionId,
      'contains invalid characters (only alphanumeric, hyphens, and underscores allowed)',
    );
  }
}

/**
 * Validate timeout bounds.
 *
 * Timeouts must be between 5 seconds and 1 hour to prevent instant
 * timeouts or runaway processes.
 *
 * @throws {TimeoutValidationError} If timeout is too short or too long
 */
export function validateTimeout(timeoutMs: number): void {
  if (timeoutMs < MIN_TIMEOUT_MS) {
    throw new TimeoutValidationError(
      timeoutMs,
      'too short',
      `Timeout must be at least ${MIN_TIMEOUT_MS}ms (5 seconds)`,
    );
  }
  if (timeoutMs > MAX_TIMEOUT_MS) {
    throw new TimeoutValidationError(
      timeoutMs,
      'too long',
      `Timeout must be at most ${MAX_TIMEOUT_MS}ms (1 hour)`,
    );
  }
}

/**
 * Validate working directory path.
 *
 * The cwd must be an absolute path (starting with '/').
 * Relative paths like './current' or '../parent' are not allowed.
 *
 * @throws {WorkingDirectoryValidationError} If path is relative
 */
export function validateCwd(cwd: string): void {
  if (!cwd.startsWith('/')) {
    throw new WorkingDirectoryValidationError(cwd);
  }
}
