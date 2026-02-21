import type { Task } from '../lib/types.js';

/**
 * Build the user prompt for a task.
 *
 * This is the main instruction given to the agent about what to implement.
 */
export function buildTaskPrompt(task: Task): string {
  return `You are working on a specific task. Focus ONLY on this task:

TASK: #${task.issueNumber} - ${task.title}

${task.body}

Instructions:
1. Implement this task completely
2. Write tests if appropriate
3. IMPORTANT: You MUST commit changes - either:
   - Code changes implementing the task, OR
   - If this is analysis/audit work with no code changes needed:
     Create a file named ANALYSIS-${task.issueNumber}.md with your findings
4. IMPORTANT: You MUST use tools to read and edit files in this repo

SCOPE RULES (MANDATORY):
- ONLY modify files directly required by this task
- Do NOT refactor, rename, delete, or 'clean up' code outside the task scope
- Do NOT remove imports, files, or utilities used by other parts of the codebase
- Other agents are working on other tasks in parallel. Their work must not be disrupted.

Focus only on implementing: ${task.title}`;
}

/**
 * Build the system prompt for the agent.
 *
 * This sets the overall context and critical requirements.
 */
export function buildSystemPrompt(task: Task): string {
  return `You are a software engineer tasked with implementing issue #${task.issueNumber}.

CRITICAL REQUIREMENTS:
1. Read the issue body carefully and implement ALL requested changes
2. Make the necessary code changes to fix/implement the issue
3. Test your changes to ensure they work
4. IMPORTANT: You MUST commit changes. If this is an analysis/audit task where no code changes are needed:
   - Create a file named ANALYSIS-${task.issueNumber}.md in the root directory
   - Document your findings, recommendations, or explanation of why no changes are needed
   - Commit this file so there is a record of your work
5. Stay focused on the issue scope. Avoid unrelated changes.

You MUST create commits - either code changes OR an analysis report file.
DO NOT complete a task with zero commits.`;
}

/**
 * Build a prompt for planner mode.
 *
 * This asks the agent to decompose a high-level directive into specific issues.
 */
export function buildPlannerPrompt(directive: string, repo: string): string {
  return `You are a technical project planner. Your job is to break down a high-level directive into actionable GitHub issues.

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
      "depends_on": [issue_number] // Optional, if depends on another task
    }
  }
]
\`\`\`

Guidelines:
- Keep tasks focused and independent when possible
- If tasks have dependencies, make them explicit in metadata.depends_on
- Classify complexity realistically (simple=<1h, medium=1-4h, complex=>4h)
- Add appropriate domain labels for parallel scheduling
- Be specific about acceptance criteria in the body`;
}
