import { nanoid } from 'nanoid';

type LogLevel = 'debug' | 'info' | 'warn' | 'error';

const LOG_LEVELS: Record<LogLevel, number> = { debug: 0, info: 1, warn: 2, error: 3 };

/** Context fields for structured logging */
export interface LogContext {
  sessionId?: string;
  correlationId?: string;
  component?: string;
  role?: string;
  issueNumber?: number;
  slot?: number;
  [key: string]: unknown;
}

/** Structured log entry for JSON output */
interface LogEntry {
  timestamp: string;
  level: LogLevel;
  message: string;
  context?: LogContext;
  error?: {
    type?: string;
    message?: string;
    stack?: string;
    sessionId?: string;
  };
}

/** Error types for structured error logging */
export type ErrorType = 'rate_limit' | 'timeout' | 'crash' | 'validation' | 'network' | 'quota_exceeded' | 'unknown';

/** Sensitive patterns to redact from logs */
const SENSITIVE_PATTERNS = [
  // API keys and tokens
  /ANTHROPIC_API_KEY[=:]\s*[^\s]+/gi,
  /sk-ant-[a-zA-Z0-9-_]+/gi,
  /ghp_[a-zA-Z0-9]{36,}/gi,
  /gho_[a-zA-Z0-9]{36,}/gi,
  /github_pat_[a-zA-Z0-9_]+/gi,
  // Generic tokens
  /\b[Tt]oken[=:]\s*[a-zA-Z0-9_-]{20,}/g,
  /\b[Aa]pi[Kk]ey[=:]\s*[a-zA-Z0-9_-]{20,}/g,
  // Authorization headers
  /[Aa]uthorization:\s*Bearer\s+[a-zA-Z0-9_-]+/g,
];

/** Sanitize potentially sensitive data from log messages and data objects */
function sanitizeForLog(input: string | Record<string, unknown>): string | Record<string, unknown> {
  if (typeof input === 'string') {
    let sanitized = input;
    for (const pattern of SENSITIVE_PATTERNS) {
      sanitized = sanitized.replace(pattern, '[REDACTED]');
    }
    return sanitized;
  }

  if (typeof input === 'object' && input !== null) {
    const sanitized: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(input)) {
      // Redact keys that likely contain sensitive data
      if (/api[_-]?key|token|secret|password|credential/i.test(key)) {
        sanitized[key] = '[REDACTED]';
      } else if (typeof value === 'string') {
        sanitized[key] = sanitizeForLog(value);
      } else if (typeof value === 'object' && value !== null) {
        sanitized[key] = sanitizeForLog(value as Record<string, unknown>);
      } else {
        sanitized[key] = value;
      }
    }
    return sanitized;
  }

  return input;
}

/** Validate and parse LOG_LEVEL env var */
function getInitialLogLevel(): number {
  const envLevel = process.env.LOG_LEVEL?.toLowerCase();
  if (envLevel && envLevel in LOG_LEVELS) {
    return LOG_LEVELS[envLevel as LogLevel];
  }
  return LOG_LEVELS.info;
}

/** Check if JSON format is enabled */
function isJsonFormat(): boolean {
  return process.env.LOG_FORMAT === 'json';
}

let minLevel = getInitialLogLevel();
let quiet = false;

/** Format log entry as human-readable text */
function formatText(level: LogLevel, msg: string, context?: LogContext, data?: Record<string, unknown>): string {
  const ts = new Date().toISOString().slice(11, 23);
  const prefix = `[${ts}] ${level.toUpperCase().padEnd(5)}`;

  // Build context prefix if present
  let contextStr = '';
  if (context) {
    const parts: string[] = [];
    if (context.component) parts.push(context.component);
    if (context.role) parts.push(context.role);
    if (context.issueNumber) parts.push(`#${context.issueNumber}`);
    if (context.slot !== undefined) parts.push(`slot:${context.slot}`);
    if (parts.length > 0) contextStr = `[${parts.join('|')}] `;
  }

  // Sanitize message and data
  const sanitizedMsg = sanitizeForLog(msg) as string;
  if (data) {
    const sanitizedData = sanitizeForLog(data) as Record<string, unknown>;
    return `${prefix} ${contextStr}${sanitizedMsg} ${JSON.stringify(sanitizedData)}`;
  }
  return `${prefix} ${contextStr}${sanitizedMsg}`;
}

/** Format log entry as JSON */
function formatJson(level: LogLevel, msg: string, context?: LogContext, data?: Record<string, unknown>): string {
  const entry: LogEntry = {
    timestamp: new Date().toISOString(),
    level,
    message: sanitizeForLog(msg) as string,
  };

  if (context) {
    entry.context = context;
  }

  // Merge additional data into the entry (sanitized)
  if (data) {
    const sanitizedData = sanitizeForLog(data) as Record<string, unknown>;
    Object.assign(entry, sanitizedData);
  }

  return JSON.stringify(entry);
}

/** Core log function with context support */
function log(level: LogLevel, msg: string, context?: LogContext, data?: Record<string, unknown>): void {
  if (quiet || LOG_LEVELS[level] < minLevel) return;

  const output = isJsonFormat()
    ? formatJson(level, msg, context, data)
    : formatText(level, msg, context, data);

  if (level === 'error') console.error(output);
  else if (level === 'warn') console.warn(output);
  else console.log(output);
}

/** Logger interface with context propagation */
export interface Logger {
  debug: (msg: string, data?: Record<string, unknown>) => void;
  info: (msg: string, data?: Record<string, unknown>) => void;
  warn: (msg: string, data?: Record<string, unknown>) => void;
  error: (msg: string, data?: Record<string, unknown>) => void;
  errorWithType: (msg: string, errorType: ErrorType, error: Error, additionalContext?: Record<string, unknown>) => void;
  child: (childContext: LogContext) => Logger;
  setLevel: (level: LogLevel) => void;
  setQuiet: (q: boolean) => void;
}

/** Sample log events based on rate (returns true if should log) */
function shouldSample(sampleRate: number): boolean {
  return Math.random() < sampleRate;
}

/** Create a logger instance with optional context */
function createLogger(context?: LogContext): Logger {
  return {
    debug: (msg: string, data?: Record<string, unknown>) => log('debug', msg, context, data),
    info: (msg: string, data?: Record<string, unknown>) => log('info', msg, context, data),
    warn: (msg: string, data?: Record<string, unknown>) => log('warn', msg, context, data),
    error: (msg: string, data?: Record<string, unknown>) => log('error', msg, context, data),

    /** Log structured error with type and stack trace */
    errorWithType: (msg: string, errorType: ErrorType, error: Error, additionalContext?: Record<string, unknown>) => {
      const errorData = {
        error: {
          type: errorType,
          message: error.message,
          stack: error.stack,
          ...additionalContext,
        },
      };
      log('error', msg, context, errorData);
    },

    /** Create a child logger with additional context */
    child: (childContext: LogContext) => {
      return createLogger({ ...context, ...childContext });
    },

    setLevel: (level: LogLevel) => {
      minLevel = LOG_LEVELS[level] ?? LOG_LEVELS.info;
    },

    setQuiet: (q: boolean) => {
      quiet = q;
    },
  };
}

/** Root logger instance */
export const logger = createLogger();

/** Generate a correlation ID for tracing across layers */
export function generateCorrelationId(): string {
  return nanoid(12);
}

/** Sample high-volume events (e.g., 1/10 in production) */
export function shouldLogSampledEvent(eventType: string, defaultRate = 0.1): boolean {
  // Always log in development
  if (process.env.NODE_ENV !== 'production') return true;

  // Custom sample rates for specific events
  const sampleRates: Record<string, number> = {
    'cheenoski_slot_done': 0.1,  // 1 in 10
    'cheenoski_progress': 0.05,   // 1 in 20
  };

  const rate = sampleRates[eventType] ?? defaultRate;
  return shouldSample(rate);
}
