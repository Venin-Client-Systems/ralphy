# AI-Powered Issue Decomposition and Dependency Management

Autoissue 2.0 now includes intelligent issue decomposition using Claude AI to break down high-level directives into concrete, actionable GitHub issues with automatic dependency tracking.

## Features

### 1. AI-Powered Issue Decomposition

The `decomposeDirective()` function uses Claude to analyze a high-level directive and create:

- **3-15 optimally-sized issues** (30-60 minute tasks)
- **Domain-tagged titles** ([Backend], [Frontend], [Database], etc.)
- **Detailed requirements** with checkboxes
- **Acceptance criteria** for verification
- **Dependency information** (which tasks must complete first)
- **Complexity estimates** (simple, medium, complex)

### 2. Dependency Graph Management

The `DependencyGraph` class tracks task dependencies and ensures correct execution order:

- **Dependency tracking**: Which tasks depend on which others
- **Cycle detection**: Prevents circular dependencies
- **Topological sorting**: Determines optimal execution order
- **Ready task identification**: Finds tasks whose dependencies are met
- **Blocked task analysis**: Shows which tasks are waiting and why

### 3. Dependency-Aware Execution

Tasks are executed respecting dependencies while maximizing parallelism:

- **Parallel execution**: Independent tasks run concurrently
- **Sequential dependencies**: Dependent tasks wait for prerequisites
- **Dynamic scheduling**: As tasks complete, blocked tasks become ready
- **Conflict prevention**: Domain-aware scheduling prevents file conflicts

## Usage

### Planner Mode (New)

Use Claude to decompose a directive into issues and execute them:

```bash
# Decompose + execute
autoissue --directive "Build user authentication system with JWT" --config autoissue.config.json

# Dry-run: see the plan without executing
autoissue --directive "Add password reset flow" --config autoissue.config.json --dry-run
```

### Direct Mode (Original)

Execute existing GitHub issues by label:

```bash
autoissue --issues autoissue-1 --config autoissue.config.json
```

## Configuration

Enable planner mode in `autoissue.config.json`:

```json
{
  "planner": {
    "enabled": true,
    "model": "sonnet",
    "maxBudgetUsd": 2.0,
    "maxTurns": 5
  },
  "agent": {
    "model": "sonnet",
    "maxBudgetUsd": 5.0,
    "yolo": true
  }
}
```

## Example Workflow

### Input Directive

```
Build user authentication system with JWT tokens, login/logout endpoints,
and password reset functionality
```

### AI-Generated Issues

```json
[
  {
    "title": "[Database] Create User model with Drizzle ORM",
    "body": "## Overview\nImplement User model...",
    "labels": ["database", "simple"],
    "metadata": {
      "depends_on": [],
      "complexity": "simple"
    }
  },
  {
    "title": "[Backend] Implement JWT authentication middleware",
    "body": "## Overview\nCreate JWT token generation and validation...",
    "labels": ["backend", "medium"],
    "metadata": {
      "depends_on": [1],
      "complexity": "medium"
    }
  },
  {
    "title": "[Backend] Create login/logout endpoints",
    "body": "## Overview\nImplement POST /api/auth/login and /api/auth/logout...",
    "labels": ["backend", "medium"],
    "metadata": {
      "depends_on": [1, 2],
      "complexity": "medium"
    }
  },
  {
    "title": "[Backend] Add password reset flow",
    "body": "## Overview\nImplement reset token generation and email sending...",
    "labels": ["backend", "complex"],
    "metadata": {
      "depends_on": [1],
      "complexity": "complex"
    }
  },
  {
    "title": "[Testing] Add auth endpoint integration tests",
    "body": "## Overview\nWrite tests for login, logout, and password reset...",
    "labels": ["testing", "medium"],
    "metadata": {
      "depends_on": [3, 4],
      "complexity": "medium"
    }
  }
]
```

### Execution Flow

1. **Issue 1** (User model) starts immediately (no dependencies)
2. **Issue 2** (JWT middleware) and **Issue 4** (password reset) start after Issue 1 completes (parallel execution)
3. **Issue 3** (login/logout) starts after Issues 1 and 2 complete
4. **Issue 5** (tests) starts after Issues 3 and 4 complete
5. All tasks create PRs automatically

## Implementation Details

### File Structure

```
core/
├── planner.ts              # AI-powered issue decomposition
├── executor.ts             # Main execution loop + dependency-aware scheduling
└── scheduler.ts            # Sliding window scheduler

lib/
├── dependency-graph.ts     # Dependency tracking and topological sorting
└── types.ts                # Type definitions with metadata support

__tests__/
└── dependency-graph.test.ts  # Comprehensive dependency graph tests
```

### Key Functions

#### `decomposeDirective(directive, config, repo)`

Spawns a Claude agent to analyze the directive and generate structured issues.

**Returns:**
```typescript
{
  issues: IssuePayload[];  // Array of GitHub issue payloads
  cost: number;            // AI planner cost in USD
  durationMs: number;      // Time taken to decompose
}
```

#### `executePlannerMode(directive, config, options)`

Full pipeline: directive → AI decomposition → GitHub issues → execution.

**Steps:**
1. Decompose directive with AI
2. Create GitHub issues
3. Build dependency graph
4. Check for cycles
5. Execute with dependency-aware scheduling

#### `DependencyGraph` Class

**Methods:**
- `addTask(task, dependsOn)` — Add task with dependencies
- `getReadyTasks(completed)` — Get tasks ready to execute
- `hasCycles()` — Detect circular dependencies
- `getExecutionOrder()` — Get topological sort
- `canStart(issue, completed)` — Check if task can start

### Type Extensions

**IssuePayload** now includes metadata:

```typescript
{
  title: string;
  body: string;
  labels: string[];
  metadata?: {
    depends_on?: number[];      // Issue numbers this depends on
    complexity?: TaskComplexity; // 'simple' | 'medium' | 'complex'
  };
}
```

**Task** now includes metadata:

```typescript
{
  issueNumber: number;
  // ... other fields ...
  metadata?: {
    depends_on?: number[];
    complexity?: TaskComplexity;
  };
}
```

## Testing

Run dependency graph tests:

```bash
npm test -- __tests__/dependency-graph.test.ts
```

**Test coverage:**
- Adding tasks with/without dependencies
- Ready task identification
- Blocked task analysis
- Cycle detection (simple and complex)
- Topological sorting
- Dependency queries

## Benefits

1. **Faster development**: Break down complex features in seconds instead of hours
2. **Better task granularity**: AI creates optimally-sized tasks (30-60 min)
3. **Automatic dependencies**: No manual dependency tracking needed
4. **Parallel execution**: Maximize throughput while respecting constraints
5. **Domain awareness**: Prevents file conflicts through intelligent scheduling
6. **Cost tracking**: Monitor AI costs for decomposition

## Limitations

1. **AI accuracy**: Decomposition quality depends on directive clarity
2. **Dependency complexity**: Very complex dependency graphs may be hard to decompose
3. **Cost overhead**: AI decomposition adds ~$0.10-0.50 per directive
4. **Manual review**: Dry-run recommended before executing on critical projects

## Future Enhancements

- [ ] Issue refinement: Allow AI to refine issues based on feedback
- [ ] Cost prediction: Estimate total cost before execution
- [ ] Interactive mode: Review and edit issues before creation
- [ ] Dependency visualization: Graph visualization in dashboard
- [ ] Learning from history: Use past issues to improve decomposition
