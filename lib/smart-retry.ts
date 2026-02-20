import { logger } from './logger.js';

/**
 * Error analysis result.
 */
export interface ErrorAnalysis {
  retryable: boolean;
  suggestedFix?: string;
  category?: string;
}

/**
 * Analyze an error to determine if it's retryable and provide suggestions.
 *
 * This uses heuristics to classify common error patterns:
 * - Module not found → Install dependencies
 * - Syntax errors → Fix syntax
 * - Type errors → Verify types
 * - File not found → Create missing files
 * - Rate limits → Wait and retry
 * - Timeouts → Retry
 */
export function analyzeError(error: string): ErrorAnalysis {
  const errorLower = error.toLowerCase();

  // Module not found errors
  if (
    errorLower.includes('cannot find module') ||
    errorLower.includes('module not found') ||
    errorLower.includes('could not find a declaration file')
  ) {
    return {
      retryable: true,
      category: 'missing_dependency',
      suggestedFix:
        'IMPORTANT: Install missing dependencies first with npm install or yarn add. Check package.json and verify all imports are correct.',
    };
  }

  // Syntax errors
  if (errorLower.includes('syntaxerror') || errorLower.includes('unexpected token')) {
    return {
      retryable: true,
      category: 'syntax_error',
      suggestedFix:
        'IMPORTANT: Fix syntax errors. Use a linter to validate code. Check for missing brackets, parentheses, or semicolons.',
    };
  }

  // Type errors
  if (
    errorLower.includes('typeerror') ||
    errorLower.includes('is not a function') ||
    errorLower.includes('undefined is not an object')
  ) {
    return {
      retryable: true,
      category: 'type_error',
      suggestedFix:
        'IMPORTANT: Verify type definitions and function signatures. Check that variables are defined before use.',
    };
  }

  // File not found
  if (errorLower.includes('enoent') || errorLower.includes('no such file')) {
    return {
      retryable: true,
      category: 'file_not_found',
      suggestedFix:
        'IMPORTANT: Create missing files or verify file paths. Check that directories exist and paths are correct.',
    };
  }

  // Permission errors
  if (errorLower.includes('eacces') || errorLower.includes('permission denied')) {
    return {
      retryable: true,
      category: 'permission_error',
      suggestedFix:
        'IMPORTANT: Check file permissions. You may need to create files in a different location or use sudo (if appropriate).',
    };
  }

  // Rate limits
  if (errorLower.includes('rate limit') || errorLower.includes('429')) {
    return {
      retryable: true,
      category: 'rate_limit',
      suggestedFix: 'Rate limit hit. Waiting before retry.',
    };
  }

  // Timeouts
  if (errorLower.includes('timeout') || errorLower.includes('etimedout')) {
    return {
      retryable: true,
      category: 'timeout',
      suggestedFix: 'Operation timed out. Retrying with potentially simpler approach.',
    };
  }

  // Build/compile errors
  if (errorLower.includes('compilation failed') || errorLower.includes('build failed')) {
    return {
      retryable: true,
      category: 'build_error',
      suggestedFix:
        'IMPORTANT: Fix compilation errors. Run the build command locally to see detailed error messages.',
    };
  }

  // Test failures
  if (errorLower.includes('test failed') || errorLower.includes('assertion failed')) {
    return {
      retryable: true,
      category: 'test_failure',
      suggestedFix:
        'IMPORTANT: Tests are failing. Review the test output and fix the implementation or update the tests.',
    };
  }

  // Non-retryable (authentication, authorization, etc.)
  if (
    errorLower.includes('unauthorized') ||
    errorLower.includes('forbidden') ||
    errorLower.includes('authentication')
  ) {
    return {
      retryable: false,
      category: 'auth_error',
    };
  }

  // Default: not retryable (unknown error)
  return {
    retryable: false,
    category: 'unknown',
  };
}

/**
 * Enhance a prompt with error context and suggested fixes.
 */
export function enhancePrompt(
  originalPrompt: string,
  errorAnalysis: ErrorAnalysis,
  attempt: number
): string {
  if (!errorAnalysis.suggestedFix) {
    return originalPrompt;
  }

  return `${originalPrompt}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⚠️  PREVIOUS ATTEMPT FAILED (Attempt ${attempt})
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Error Category: ${errorAnalysis.category || 'unknown'}

${errorAnalysis.suggestedFix}

Please address this specific issue before proceeding with the rest of the task.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`;
}

/**
 * Calculate exponential backoff delay.
 */
export function calculateBackoff(attempt: number, baseDelayMs: number = 2000): number {
  return baseDelayMs * Math.pow(2, attempt);
}

/**
 * Sleep for a given duration.
 */
export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
