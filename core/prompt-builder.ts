import type { Task } from '../lib/types.js';

/**
 * Build the user prompt for a task.
 *
 * Simple and direct - like working Ralphy.
 */
export function buildTaskPrompt(task: Task): string {
  return `You are working on a specific task. Focus ONLY on this task:

TASK: #${task.issueNumber} - ${task.title}

${task.body}

Rules (you MUST follow these):
- Keep changes focused and minimal. Do not refactor unrelated code.
- One logical change per commit. If task is too large, break it into subtasks.
- Write concise code. Avoid over-engineering.
- Don't leave dead code. Delete unused code completely.
- Quality over speed. Small steps compound into big progress.

Boundaries - Do NOT modify:
- Files unrelated to this task
- Other agents are working in parallel. Don't disrupt their work.

Instructions:
1. Implement this specific task completely
2. Write tests if appropriate
3. Run tests and ensure they pass
4. Run linting if needed
5. Commit your changes with a descriptive message

Focus only on implementing: ${task.title}`;
}

/**
 * Build the system prompt for the agent.
 *
 * Keep it simple - no massive directives.
 */
export function buildSystemPrompt(task: Task): string {
  return `You are a software engineer implementing issue #${task.issueNumber}. Use your tools (Read, Edit, Write, Bash) to make the required code changes.`;
}

/**
 * Build a prompt for planner mode.
 */
export function buildPlannerPrompt(directive: string, repo: string): string {
  return `You are a technical project planner. Break down this directive into actionable GitHub issues.

DIRECTIVE:
${directive}

REPOSITORY: ${repo}

Your task:
1. Analyze the directive and break it down into 3-10 specific, actionable tasks
2. For each task, create a clear issue with:
   - A descriptive title (max 80 chars)
   - A detailed description of what needs to be implemented
   - Labels (e.g., feature, bug, enhancement, docs, testing)
   - Domain classification (backend, frontend, database, infrastructure, etc.)
   - Dependencies (if task depends on another task being completed first)

Output Format:
Provide a JSON array of issues following this schema:
\`\`\`json
[
  {
    "title": "Short descriptive title",
    "body": "Detailed description of what to implement...",
    "labels": ["feature", "backend"],
    "metadata": {
      "complexity": "simple" | "medium" | "complex",
      "depends_on": [issue_number] // Optional
    }
  }
]
\`\`\`

Guidelines:
- Keep tasks focused and independent when possible
- Make dependencies explicit in metadata.depends_on
- Classify complexity realistically (simple=<1h, medium=1-4h, complex=>4h)
- Add appropriate domain labels for parallel scheduling
- Be specific about acceptance criteria in the body`;
}
