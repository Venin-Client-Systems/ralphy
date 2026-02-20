/**
 * AI-Powered Issue Decomposition
 *
 * Takes a high-level directive and uses Claude to break it down into
 * concrete, actionable GitHub issues with proper domain labeling,
 * dependency tracking, and complexity estimates.
 */

import { spawnAgent } from './agent.js';
import { logger } from '../lib/logger.js';
import type { IssuePayload, PlannerConfig } from '../lib/types.js';

export interface PlannerResult {
  issues: IssuePayload[];
  cost: number;
  durationMs: number;
}

/**
 * Decompose a high-level directive into concrete GitHub issues using AI.
 */
export async function decomposeDirective(
  directive: string,
  config: PlannerConfig,
  repo: string
): Promise<PlannerResult> {
  logger.info('Decomposing directive into issues', { directive, repo });

  const systemPrompt = `You are a software architect breaking down high-level directives into concrete, actionable GitHub issues.

RULES:
1. Create 3-15 issues (optimal for parallel execution)
2. Each issue must be:
   - Focused on ONE specific task
   - Completable in 30-60 minutes
   - Testable and verifiable
   - Independently executable (minimal dependencies)
3. Use domain tags: [Backend], [Frontend], [Database], [Infra], [Testing], [Docs]
4. Add appropriate labels: backend, frontend, database, infrastructure, testing, documentation
5. Identify dependencies (which issues must complete before others)
6. Estimate complexity: simple, medium, complex

OUTPUT FORMAT (JSON array):
\`\`\`json
[
  {
    "title": "[Backend] Create User model with Drizzle ORM",
    "body": "## Overview\\nImplement User model with validation and migrations\\n\\n## Requirements\\n- [ ] Define User schema in src/db/schema/\\n- [ ] Create migration file\\n- [ ] Add type exports\\n\\n## Acceptance Criteria\\n- Schema compiles without errors\\n- Migration runs successfully\\n- Types are exported correctly",
    "labels": ["backend", "simple"],
    "metadata": {
      "depends_on": [],
      "complexity": "simple"
    }
  },
  {
    "title": "[Backend] Implement user authentication endpoints",
    "body": "## Overview\\nCreate login/logout endpoints using JWT\\n\\n## Requirements\\n- [ ] POST /api/auth/login\\n- [ ] POST /api/auth/logout\\n- [ ] JWT token generation\\n- [ ] Middleware for auth validation\\n\\n## Acceptance Criteria\\n- Endpoints return 200 on success\\n- Invalid credentials return 401\\n- JWT tokens are validated correctly",
    "labels": ["backend", "medium"],
    "metadata": {
      "depends_on": [1],
      "complexity": "medium"
    }
  }
]
\`\`\`

IMPORTANT:
- Output ONLY the JSON array, no other text
- Use proper JSON escaping for newlines (\\n)
- Issue numbers in depends_on will be assigned sequentially (1, 2, 3, ...)
- Keep dependencies minimal to maximize parallel execution`;

  const prompt = `Break down this directive into concrete GitHub issues:

DIRECTIVE: ${directive}

REPOSITORY: ${repo}

Analyze the directive and create a well-structured set of issues with:
1. Clear domain tags (exactly one per issue)
2. Detailed requirements with checkboxes
3. Acceptance criteria
4. Dependency information (use array indices: [1] for first issue, [2] for second, etc.)
5. Complexity estimates

Output ONLY the JSON array, no other text.`;

  const response = await spawnAgent(prompt, {
    model: config.model,
    maxBudgetUsd: config.maxBudgetUsd,
    systemPrompt,
    maxTurns: config.maxTurns || 5,
  });

  // Parse JSON response
  const jsonMatch = response.content.match(/```json\s*([\s\S]*?)\s*```/);
  if (!jsonMatch) {
    logger.error('Failed to extract JSON from AI response', {
      content: response.content.slice(0, 500),
    });
    throw new Error('Failed to parse issue decomposition from AI response: no JSON block found');
  }

  let rawIssues: any[];
  try {
    rawIssues = JSON.parse(jsonMatch[1]);
  } catch (err) {
    logger.error('Failed to parse JSON', {
      json: jsonMatch[1].slice(0, 500),
      error: err instanceof Error ? err.message : String(err),
    });
    throw new Error(`Failed to parse JSON: ${err instanceof Error ? err.message : String(err)}`);
  }

  if (!Array.isArray(rawIssues)) {
    throw new Error('AI response is not an array');
  }

  // Transform and validate
  const issues: IssuePayload[] = rawIssues.map((issue: any, index: number) => {
    if (!issue.title || typeof issue.title !== 'string') {
      throw new Error(`Issue ${index + 1} missing title`);
    }
    if (!issue.body || typeof issue.body !== 'string') {
      throw new Error(`Issue ${index + 1} missing body`);
    }

    return {
      title: issue.title,
      body: issue.body,
      labels: Array.isArray(issue.labels) ? issue.labels : [],
      metadata: {
        depends_on: Array.isArray(issue.metadata?.depends_on) ? issue.metadata.depends_on : [],
        complexity: ['simple', 'medium', 'complex'].includes(issue.metadata?.complexity)
          ? issue.metadata.complexity
          : 'medium',
      },
    };
  });

  logger.info('Directive decomposed', {
    directive,
    issueCount: issues.length,
    domains: [
      ...new Set(
        issues.map((i) => {
          const match = i.title.match(/\[([^\]]+)\]/);
          return match ? match[1] : 'unknown';
        })
      ),
    ],
    totalDependencies: issues.reduce(
      (sum, i) => sum + (i.metadata?.depends_on?.length || 0),
      0
    ),
  });

  return {
    issues,
    cost: response.costUsd,
    durationMs: response.durationMs,
  };
}

/**
 * Legacy function for backwards compatibility.
 */
export async function planDirective(
  directive: string,
  repo: string,
  opts: { model: string; maxBudgetUsd: number }
): Promise<PlannerResult> {
  const result = await decomposeDirective(
    directive,
    {
      enabled: true,
      model: opts.model as 'opus' | 'sonnet' | 'haiku',
      maxBudgetUsd: opts.maxBudgetUsd,
    },
    repo
  );

  return {
    issues: result.issues,
    cost: result.cost,
    durationMs: result.durationMs,
  };
}
