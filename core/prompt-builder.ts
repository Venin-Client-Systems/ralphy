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

CRITICAL: You MUST use tools (Read, Edit, Write, Bash) to modify files in this repo.
Do NOT respond with only a plan or explanation - you must ACTUALLY use tools to make changes.
If you cannot access tools or files, respond with 'TOOL_ACCESS_FAILED' and stop.

Instructions:
1. Use Read tool to examine relevant files
2. Use Edit or Write tools to make the requested code changes
3. Write tests if appropriate (use Write tool to create test files)
4. Use Bash tool to run tests/linting if needed
5. IMPORTANT: You MUST make file changes before completing:
   - PREFERRED: Make the code changes requested in the task above
   - FALLBACK (only if code changes are impossible): Create ANALYSIS-${task.issueNumber}.md explaining why
6. NEVER complete without making file modifications

SCOPE RULES (MANDATORY):
- ONLY modify files directly required by this task
- Do NOT refactor, rename, delete, or 'clean up' code outside the task scope
- Do NOT remove imports, files, or utilities used by other parts of the codebase
- Other agents are working on other tasks in parallel. Their work must not be disrupted.

Focus on implementing the solution described in: ${task.title}`;
}

/**
 * Build the system prompt for the agent.
 *
 * This sets the overall context and critical requirements.
 */
export function buildSystemPrompt(task: Task): string {
  return `You are a software engineer with full access to tools (Read, Edit, Write, Bash, etc.).
You MUST use these tools to implement issue #${task.issueNumber}.

TOOL USAGE IS MANDATORY:
- You have Read, Edit, Write, Bash, Glob, and Grep tools available
- You MUST use these tools to read and modify files
- Do NOT just describe what you would do - ACTUALLY DO IT using tools
- If tools are not working, respond with 'TOOL_ACCESS_FAILED'

CRITICAL REQUIREMENTS:
1. Read the issue body carefully and implement ALL requested changes
2. Use Read tool to examine existing code
3. Use Edit/Write tools to make necessary code modifications
4. Use Bash tool to run tests if needed
5. IMPORTANT: You MUST make file changes. There are TWO acceptable outcomes:

   OUTCOME A (PREFERRED): Code Changes
   - Use Edit/Write tools to implement the requested solution
   - Make all necessary code modifications
   - Changes will be auto-committed after you complete

   OUTCOME B (ONLY if NO code changes are possible): Analysis Report
   - ONLY use this if you determine code changes are genuinely not needed/possible
   - Use Write tool to create ANALYSIS-${task.issueNumber}.md in the root directory
   - Document your findings and explain WHY no code changes are needed

6. Stay focused on the issue scope. Avoid unrelated changes.

NEVER complete without using tools to make file modifications. Either implement code changes (preferred) OR create an analysis report file.`;
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
