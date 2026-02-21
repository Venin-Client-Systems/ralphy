/**
 * Autoissue 2.0 - Type System
 *
 * Simplified from Echelon - removed layer hierarchy, kept the good parts:
 * - Agent validation schemas
 * - Config schemas
 * - Issue schemas
 * - Error types
 */

import { z } from 'zod';

// --- Constants ---

/**
 * Default maximum turns by model.
 *
 * Haiku needs more turns (produces less output per turn) compared to Opus/Sonnet.
 */
export const DEFAULT_MAX_TURNS: Record<string, number> = {
  opus: 5,
  sonnet: 8,
  haiku: 12,
};

// --- Agent Spawn/Resume Schemas (from Echelon - kept as-is) ---

/**
 * Zod schema for validating SpawnOptions.
 *
 * Validates all input parameters for spawning a new Claude agent.
 */
export const SpawnOptionsSchema = z.object({
  model: z.enum(['opus', 'sonnet', 'haiku'], {
    errorMap: () => ({ message: 'Model must be one of: opus, sonnet, haiku' }),
  }),
  maxBudgetUsd: z.number().min(0.01, {
    message: 'Budget must be at least 0.01 USD (minimum realistic API call cost)',
  }),
  systemPrompt: z
    .string()
    .min(1, { message: 'System prompt cannot be empty' })
    .max(100_000, { message: 'System prompt exceeds 100,000 characters' })
    .refine((s) => s.trim().length > 0, {
      message: 'System prompt cannot be whitespace-only',
    }),
  maxTurns: z.number().int().positive().optional(),
  timeoutMs: z
    .number()
    .min(5_000, { message: 'Timeout must be at least 5,000ms (5 seconds)' })
    .max(3_600_000, { message: 'Timeout must be at most 3_600_000ms (1 hour)' })
    .optional(),
  cwd: z
    .string()
    .refine((path) => path.startsWith('/'), {
      message: 'Working directory must be an absolute path (starting with /)',
    })
    .optional(),
  yolo: z.boolean().optional(),
});

/**
 * Zod schema for validating ResumeOptions.
 */
export const ResumeOptionsSchema = z.object({
  sessionId: z
    .string()
    .min(5, { message: 'Session ID must be at least 5 characters' })
    .regex(/^[a-zA-Z0-9_-]+$/, {
      message:
        'Session ID contains invalid characters (only alphanumeric, hyphens, and underscores allowed)',
    })
    .refine((s) => s.trim().length > 0, {
      message: 'Session ID cannot be empty or whitespace-only',
    }),
  prompt: z
    .string()
    .min(1, { message: 'Prompt cannot be empty' })
    .max(100_000, { message: 'Prompt exceeds 100,000 characters' })
    .refine((s) => s.trim().length > 0, {
      message: 'Prompt cannot be whitespace-only',
    }),
  maxTurns: z.number().int().positive().optional(),
  maxBudgetUsd: z
    .number()
    .min(0.01, { message: 'Budget must be at least 0.01 USD' })
    .optional(),
  timeoutMs: z
    .number()
    .min(5_000, { message: 'Timeout must be at least 5,000ms (5 seconds)' })
    .max(3_600_000, { message: 'Timeout must be at most 3_600_000ms (1 hour)' })
    .optional(),
  cwd: z
    .string()
    .refine((path) => path.startsWith('/'), {
      message: 'Working directory must be an absolute path (starting with /)',
    })
    .optional(),
  yolo: z.boolean().optional(),
});

export type ValidatedSpawnOptions = z.infer<typeof SpawnOptionsSchema>;
export type ValidatedResumeOptions = z.infer<typeof ResumeOptionsSchema>;

// --- Config Schemas (simplified from Echelon) ---

/**
 * Project configuration - target repository and base branch.
 */
export const ProjectConfigSchema = z.object({
  repo: z.string().regex(/^[^/]+\/[^/]+$/, 'Must be owner/repo format'),
  path: z.string(),
  baseBranch: z.string().default('main'),
});

/**
 * Executor configuration - parallel execution settings.
 */
export const ExecutorConfigSchema = z.object({
  maxParallel: z.number().int().min(1).max(10).default(3),
  timeoutMinutes: z.number().int().min(5).max(120).default(30),
  createPr: z.boolean().default(true),
  prDraft: z.boolean().default(false),
});

/**
 * Planner configuration - smart directive → issues.
 */
export const PlannerConfigSchema = z.object({
  enabled: z.boolean().default(true),
  model: z.enum(['opus', 'sonnet', 'haiku']).default('sonnet'),
  maxBudgetUsd: z.number().min(0.01).default(2.0),
  maxTurns: z.number().int().positive().optional(),
});

/**
 * Agent configuration - settings for worker agents.
 */
export const AgentConfigSchema = z.object({
  model: z.enum(['opus', 'sonnet', 'haiku']).default('sonnet'),
  maxBudgetUsd: z.number().min(0.01).default(5.0),
  yolo: z.boolean().default(true),
  maxTurns: z.number().int().positive().optional(),
});

/**
 * Telegram bot configuration (optional).
 */
export const TelegramConfigSchema = z.object({
  enabled: z.boolean().default(false),
  token: z.string().optional(),
  allowedUserIds: z.array(z.number().int()).default([]),
  health: z.object({
    enabled: z.boolean().default(false),
    port: z.number().int().min(1).max(65535).default(3000),
    bindAddress: z.string().default('0.0.0.0'),
  }).optional(),
});

/**
 * Dashboard server configuration (optional).
 */
export const DashboardConfigSchema = z.object({
  enabled: z.boolean().default(false),
  port: z.number().int().min(1).max(65535).default(3030),
});

/**
 * Root Autoissue configuration schema.
 */
export const AutoissueConfigSchema = z.object({
  project: ProjectConfigSchema,
  executor: ExecutorConfigSchema.default({}),
  planner: PlannerConfigSchema.optional(),
  agent: AgentConfigSchema.default({}),
  maxTotalBudgetUsd: z.number().min(0.01).default(50.0),
  telegram: TelegramConfigSchema.optional(),
  dashboard: DashboardConfigSchema.optional(),
});

export type AutoissueConfig = z.infer<typeof AutoissueConfigSchema>;
export type ProjectConfig = z.infer<typeof ProjectConfigSchema>;
export type ExecutorConfig = z.infer<typeof ExecutorConfigSchema>;
export type PlannerConfig = z.infer<typeof PlannerConfigSchema>;
export type AgentConfig = z.infer<typeof AgentConfigSchema>;
export type TelegramConfig = z.infer<typeof TelegramConfigSchema>;
export type DashboardConfig = z.infer<typeof DashboardConfigSchema>;

// --- GitHub Issue Schemas ---

/**
 * Complexity estimate for a task.
 */
export type TaskComplexity = 'simple' | 'medium' | 'complex';

/**
 * Schema for a GitHub issue payload.
 */
export const IssuePayloadSchema = z.object({
  title: z.string(),
  body: z.string(),
  labels: z.array(z.string()).default([]),
  assignee: z.string().optional(),
  metadata: z.object({
    depends_on: z.array(z.number()).default([]),
    complexity: z.enum(['simple', 'medium', 'complex']).default('medium'),
  }).optional(),
});

export type IssuePayload = z.infer<typeof IssuePayloadSchema>;

/**
 * Fetched GitHub issue (from gh API).
 */
export interface GitHubIssue {
  number: number;
  title: string;
  body: string;
  labels: string[];
  state: 'open' | 'closed';
  assignee?: string;
  created_at: string;
  updated_at: string;
  html_url: string;
}

// --- Domain Classification ---

/**
 * Task domain for parallel scheduling.
 */
export type Domain =
  | 'backend'
  | 'frontend'
  | 'database'
  | 'infrastructure'
  | 'security'
  | 'testing'
  | 'documentation'
  | 'unknown';

/**
 * Domain classification result.
 */
export interface ClassificationResult {
  domain: Domain;
  confidence: number; // 0-1
  reasons: string[]; // Why this classification?
}

// --- Task Execution ---

/**
 * Status of a task in the executor.
 */
export type TaskStatus = 'pending' | 'running' | 'completed' | 'failed';

/**
 * A tracked task (issue being processed).
 */
export interface Task {
  issueNumber: number;
  title: string;
  body: string;
  labels: string[];
  domain: Domain;
  status: TaskStatus;
  currentAction?: string; // What the agent is currently doing
  agentSessionId?: string;
  worktreePath?: string;
  prNumber?: number;
  costUsd?: number;
  startedAt?: Date;
  completedAt?: Date;
  error?: string;
  metadata?: {
    depends_on?: number[];
    complexity?: TaskComplexity;
    linesAdded?: number;
    linesRemoved?: number;
    filesChanged?: number;
  };
}

// --- Session State ---

/**
 * Session status.
 */
export type SessionStatus = 'running' | 'paused' | 'completed' | 'failed';

/**
 * Autoissue session state (persisted to disk).
 */
export interface SessionState {
  sessionId: string;
  status: SessionStatus;
  directive?: string; // User directive (if using planner mode)
  label?: string; // GitHub label (if using direct mode)
  tasks: Task[];
  totalCost: number;
  startedAt: string;
  completedAt?: string;
  config: AutoissueConfig;
}

// --- Agent Response ---

/**
 * Raw JSON output from Claude CLI.
 */
export interface ClaudeJsonOutput {
  result: string;
  session_id: string;
  total_cost_usd: number;
  duration_ms: number;
  is_error?: boolean;
}

/**
 * Response from spawning or resuming an agent.
 */
export interface AgentResponse {
  sessionId: string;
  content: string;
  costUsd: number;
  durationMs: number;
}

// --- CLI Options ---

/**
 * CLI command-line options.
 */
export interface CliOptions {
  config?: string;
  directive?: string;
  issues?: string; // Label for direct mode
  headless: boolean;
  dryRun: boolean;
  ui: boolean;
  telegram: boolean;
  dashboard: boolean;
  resume: boolean;
  verbose: boolean;
  yolo: boolean;
}

// --- Error Types ---

/**
 * Base error class for validation errors.
 */
export class ValidationError extends Error {
  constructor(
    message: string,
    public readonly recoveryHint: string,
  ) {
    super(message);
    this.name = 'ValidationError';
  }
}

/**
 * Agent operation failed (timeout, API error, etc.).
 */
export class AgentError extends Error {
  constructor(
    message: string,
    public readonly recoveryHint: string,
  ) {
    super(message);
    this.name = 'AgentError';
  }
}

/**
 * Worktree operation failed.
 */
export class WorktreeError extends Error {
  constructor(
    message: string,
    public readonly path?: string,
  ) {
    super(message);
    this.name = 'WorktreeError';
  }
}

/**
 * GitHub API error.
 */
export class GitHubError extends Error {
  constructor(
    message: string,
    public readonly statusCode?: number,
  ) {
    super(message);
    this.name = 'GitHubError';
  }
}

// --- Rate Limiting ---

export const RateLimitStateSchema = z.object({
  remaining: z.number().int(),
  limit: z.number().int(),
  reset: z.number().int(), // Unix timestamp
});

export type RateLimitState = z.infer<typeof RateLimitStateSchema>;
