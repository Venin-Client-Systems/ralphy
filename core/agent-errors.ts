/**
 * Custom error types for agent validation and runtime failures.
 *
 * These errors provide structured information about what went wrong and how to fix it.
 * All validation errors include a `recoveryHint` field with remediation steps.
 *
 * @module agent-errors
 */

/**
 * Base class for agent validation errors.
 *
 * Thrown when agent input parameters fail validation. All validation errors
 * extend this class and include a recovery hint for remediation.
 *
 * @category Errors
 *
 * @example
 * ```typescript
 * throw new AgentValidationError(
 *   'Invalid timeout',
 *   'Timeout must be between 5s and 1 hour'
 * );
 * ```
 */
export class AgentValidationError extends Error {
  constructor(
    message: string,
    public readonly recoveryHint: string,
  ) {
    super(message);
    this.name = 'AgentValidationError';
  }
}

/**
 * Thrown when model name validation fails.
 *
 * The model parameter must be one of the supported Claude models: 'opus', 'sonnet', or 'haiku'.
 * This error is thrown when an invalid model name is provided.
 *
 * @category Errors
 *
 * @example
 * ```typescript
 * // Invalid model
 * try {
 *   await spawnAgent('Hello', {
 *     model: 'gpt-4',  // Invalid!
 *     maxBudgetUsd: 1.0,
 *     systemPrompt: '',
 *   });
 * } catch (err) {
 *   if (err instanceof ModelValidationError) {
 *     console.error(err.message);      // "Invalid model: gpt-4"
 *     console.error(err.recoveryHint); // "Must be one of: opus, sonnet, haiku"
 *   }
 * }
 * ```
 */
export class ModelValidationError extends AgentValidationError {
  constructor(model: string) {
    super(
      `Invalid model: ${model}`,
      'Must be one of: opus, sonnet, haiku',
    );
    this.name = 'ModelValidationError';
  }
}

/**
 * Thrown when budget validation fails.
 *
 * The maxBudgetUsd parameter must be at least 0.01 USD to cover the minimum cost
 * of a realistic API call. This error is thrown for negative, zero, or too-small budgets.
 *
 * @category Errors
 *
 * @example
 * ```typescript
 * // Negative budget
 * try {
 *   await spawnAgent('Hello', {
 *     model: 'sonnet',
 *     maxBudgetUsd: -1.0,  // Invalid!
 *     systemPrompt: '',
 *   });
 * } catch (err) {
 *   if (err instanceof BudgetValidationError) {
 *     console.error(err.message);      // "Invalid budget: -1"
 *     console.error(err.recoveryHint); // "Budget must be at least 0.01 USD"
 *   }
 * }
 * ```
 */
export class BudgetValidationError extends AgentValidationError {
  constructor(budget: number) {
    super(
      `Invalid budget: ${budget}`,
      'Budget must be at least 0.01 USD',
    );
    this.name = 'BudgetValidationError';
  }
}

/**
 * Thrown when session ID validation fails.
 *
 * Session IDs must be non-empty strings of at least 5 characters, containing only
 * alphanumeric characters, hyphens, and underscores. This error is thrown when
 * resuming an agent with an invalid session ID.
 *
 * @category Errors
 *
 * @example
 * ```typescript
 * // Invalid session ID
 * try {
 *   await resumeAgent(
 *     'abc',  // Too short!
 *     'Continue task',
 *     { maxTurns: 5 }
 *   );
 * } catch (err) {
 *   if (err instanceof SessionValidationError) {
 *     console.error(err.message);      // "Invalid session ID: too short"
 *     console.error(err.recoveryHint); // "Session ID must be a non-empty string from a previous agent session"
 *   }
 * }
 * ```
 */
export class SessionValidationError extends AgentValidationError {
  constructor(sessionId: string, reason: string) {
    super(
      `Invalid session ID: ${reason}`,
      'Session ID must be a non-empty string from a previous agent session',
    );
    this.name = 'SessionValidationError';
  }
}

/**
 * Thrown when prompt validation fails.
 *
 * Prompts must be non-empty, non-whitespace strings with a maximum length of 100,000 characters.
 * This error is thrown for empty, whitespace-only, or oversized prompts.
 *
 * @category Errors
 *
 * @example
 * ```typescript
 * // Empty prompt
 * try {
 *   await spawnAgent('', {  // Invalid!
 *     model: 'sonnet',
 *     maxBudgetUsd: 1.0,
 *     systemPrompt: 'Test',
 *   });
 * } catch (err) {
 *   if (err instanceof PromptValidationError) {
 *     console.error(err.message);      // "Invalid prompt: prompt is empty or whitespace-only"
 *     console.error(err.recoveryHint); // "Prompt must be a non-empty string (max 100,000 characters)"
 *   }
 * }
 * ```
 */
export class PromptValidationError extends AgentValidationError {
  constructor(reason: string) {
    super(
      `Invalid prompt: ${reason}`,
      'Prompt must be a non-empty string (max 100,000 characters)',
    );
    this.name = 'PromptValidationError';
  }
}

/**
 * Thrown when timeout validation fails.
 *
 * Timeouts must be between 5 seconds (5,000ms) and 1 hour (3,600,000ms) to prevent
 * instant timeouts or runaway processes. This error is thrown for timeouts outside
 * this range.
 *
 * @category Errors
 *
 * @example
 * ```typescript
 * // Timeout too short
 * try {
 *   await spawnAgent('Hello', {
 *     model: 'sonnet',
 *     maxBudgetUsd: 1.0,
 *     systemPrompt: '',
 *     timeoutMs: 1000,  // Too short!
 *   });
 * } catch (err) {
 *   if (err instanceof AgentValidationError) {
 *     console.error(err.message);      // "Timeout too short: 1000ms"
 *     console.error(err.recoveryHint); // "Timeout must be at least 5000ms (5 seconds)"
 *   }
 * }
 * ```
 */
export class TimeoutValidationError extends AgentValidationError {
  constructor(timeoutMs: number, reason: string, hint: string) {
    super(
      `Timeout ${reason}: ${timeoutMs}ms`,
      hint,
    );
    this.name = 'TimeoutValidationError';
  }
}

/**
 * Thrown when working directory validation fails.
 *
 * The cwd parameter must be an absolute path (starting with '/') if provided.
 * Relative paths like './current' or '../parent' are not allowed. This error
 * is thrown when a relative path is provided.
 *
 * @category Errors
 *
 * @example
 * ```typescript
 * // Relative path
 * try {
 *   await spawnAgent('Hello', {
 *     model: 'sonnet',
 *     maxBudgetUsd: 1.0,
 *     systemPrompt: '',
 *     cwd: './relative/path',  // Invalid!
 *   });
 * } catch (err) {
 *   if (err instanceof AgentValidationError) {
 *     console.error(err.message);      // "Invalid cwd: ./relative/path"
 *     console.error(err.recoveryHint); // "Working directory must be an absolute path"
 *   }
 * }
 * ```
 */
export class WorkingDirectoryValidationError extends AgentValidationError {
  constructor(cwd: string) {
    super(
      `Invalid cwd: ${cwd}`,
      'Working directory must be an absolute path',
    );
    this.name = 'WorkingDirectoryValidationError';
  }
}
