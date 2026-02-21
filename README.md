# Autoissue 2.0

[![npm version](https://img.shields.io/npm/v/@venin/autoissue.svg)](https://www.npmjs.com/package/@venin/autoissue)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![TypeScript](https://img.shields.io/badge/TypeScript-5.7-blue.svg)](https://www.typescriptlang.org/)

> **Turn your GitHub backlog into pull requests, overnight.**

Autoissue is a parallel AI code execution engine that transforms GitHub issues into production-ready pull requests. It intelligently classifies tasks by domain, schedules them for parallel execution, and runs each in an isolated git worktree to prevent conflicts.

## ✨ Key Features

- **⚡ 10x Faster** - Direct GitHub API via Octokit (no shell overhead)
- **🔄 Parallel Execution** - Run up to 10 tasks concurrently with smart scheduling
- **🎯 Domain-Aware** - Backend + Frontend run together, Backend + Backend don't
- **🔒 Isolated Worktrees** - Each task gets its own directory and branch (zero conflicts)
- **🤖 Automatic PRs** - Creates pull requests with issue links and descriptions
- **💰 Budget Tracking** - Proactive budget enforcement (checks BEFORE execution)
- **🛡️ Circuit Breakers** - Prevents cascading failures with automatic recovery
- **📊 Real-Time Dashboard** - Monitor progress, costs, and metrics via web UI
- **🔐 Secure** - Optional authentication for dashboard (Basic Auth + Token)
- **📝 Structured Logging** - JSON logs with daily rotation for production

## 🚀 Quick Start

### Installation

```bash
npm install -g @venin/autoissue
```

Or run directly with `npx`:

```bash
npx @venin/autoissue exec autoissue-1
```

### Basic Usage

Label your GitHub issues with `autoissue-1`, then run:

```bash
autoissue exec autoissue-1
```

Autoissue will:
1. Fetch all open issues labeled `autoissue-1`
2. Classify each by domain (backend, frontend, database, etc.)
3. Check budget before execution
4. Schedule compatible tasks in parallel (3 concurrent by default)
5. Execute each in an isolated git worktree with circuit breaker protection
6. Create pull requests for completed tasks
7. Track costs and provide detailed summary

## 📖 CLI Commands

### Execute Issues by Label

```bash
autoissue exec <label> [options]
```

Process all GitHub issues with the specified label.

**Examples:**
```bash
# Execute all issues labeled 'autoissue-1'
autoissue exec autoissue-1

# Execute with dashboard enabled
autoissue exec autoissue-1 --dashboard

# Execute with custom config
autoissue exec autoissue-1 --config ./my-config.json
```

### Plan and Execute from Directive

```bash
autoissue plan "<directive>" [options]
```

Use AI to decompose a high-level directive into GitHub issues, then execute them.

**Examples:**
```bash
# Plan and execute
autoissue plan "Build user authentication system"

# Dry-run (show plan without executing)
autoissue plan "Add rate limiting to API" --dry-run

# Execute with custom config
autoissue plan "Implement caching layer" --config ./config.json
```

### Resume Previous Session

```bash
autoissue resume [session-id] [options]
```

Resume a previously interrupted session.

**Examples:**
```bash
# Resume most recent session
autoissue resume

# Resume specific session
autoissue resume abc123xyz

# Resume with dashboard
autoissue resume --dashboard
```

### Show Session Status

```bash
autoissue status
```

Display status of recent execution sessions.

### Show Metrics

```bash
autoissue metrics
```

Display aggregated metrics across all sessions (total cost, success rate, code impact).

## ⚙️ Configuration

Create `autoissue.config.json` in your project root:

```json
{
  "project": {
    "repo": "owner/repo-name",
    "path": "/path/to/project",
    "baseBranch": "main"
  },
  "executor": {
    "maxParallel": 3,
    "timeoutMinutes": 30,
    "createPr": true,
    "prDraft": false
  },
  "agent": {
    "model": "sonnet",
    "maxBudgetUsd": 5.0,
    "yolo": true
  },
  "maxTotalBudgetUsd": 50.0,
  "dashboard": {
    "enabled": true,
    "port": 3030,
    "auth": {
      "enabled": false
    }
  },
  "planner": {
    "enabled": true,
    "model": "sonnet",
    "maxBudgetUsd": 2.0
  }
}
```

**See [`autoissue.config.example.json`](./autoissue.config.example.json) for a complete example with authentication.**

### Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `project.repo` | GitHub repository (owner/name) | Auto-detected |
| `project.baseBranch` | Base branch for PRs | `main` |
| `executor.maxParallel` | Max concurrent tasks | `3` |
| `executor.timeoutMinutes` | Task timeout | `30` |
| `agent.model` | AI model (`opus`, `sonnet`, `haiku`) | `sonnet` |
| `agent.maxBudgetUsd` | Budget per task | `5.0` |
| `maxTotalBudgetUsd` | Total session budget | `50.0` |
| `dashboard.enabled` | Enable web dashboard | `false` |
| `planner.enabled` | Enable planner mode | `true` |

## 📊 Dashboard & Metrics API

Enable the real-time dashboard to monitor execution:

```bash
autoissue exec autoissue-1 --dashboard
```

Then open **http://localhost:3030** in your browser to see:
- Running, completed, and failed tasks
- Real-time cost tracking
- Task status with PR links
- Budget remaining

### API Endpoints

The dashboard exposes REST API endpoints:

```bash
# Get all metrics
curl http://localhost:3030/api/metrics

# Get budget state
curl http://localhost:3030/api/metrics/budget

# Get circuit breaker state
curl http://localhost:3030/api/metrics/circuit-breaker

# Reset circuit breaker (requires auth if enabled)
curl -X POST http://localhost:3030/api/circuit-breaker/reset
```

**See [`server/API.md`](./server/API.md) for complete API documentation.**

### Dashboard Authentication

For production deployments, enable authentication:

```json
{
  "dashboard": {
    "enabled": true,
    "port": 3030,
    "auth": {
      "enabled": true,
      "type": "both",
      "username": "admin",
      "password": "your-secure-password",
      "token": "your-secure-token"
    }
  }
}
```

Then access the API with credentials:

```bash
# Basic auth
curl -u admin:password http://localhost:3030/api/metrics

# Token auth
curl -H "Authorization: Bearer your-token" http://localhost:3030/api/metrics
```

## 🎯 Domain Classification

Autoissue automatically classifies issues by domain for intelligent parallel scheduling:

### Classification Methods (Priority Order)

1. **Title Tags** - `[Backend] Fix login bug` → `backend`
2. **Domain Labels** - `backend`, `frontend`, `database`, etc.
3. **File Paths** - Inferred from issue body mentions
4. **Keywords** - "API endpoint", "UI component", "SQL query"

### Supported Domains

- `backend` - APIs, services, business logic
- `frontend` - UI components, pages, styling
- `database` - Schemas, migrations, queries
- `infrastructure` - DevOps, CI/CD, deployment
- `security` - Auth, permissions, vulnerabilities
- `testing` - Test suites, fixtures
- `documentation` - Docs, comments, guides
- `unknown` - Unclassified (runs sequentially)

### Parallel Scheduling Rules

- Different domains run in parallel
- Same domain runs sequentially (prevents file conflicts)
- Conflict detection for explicit file mentions

## 💰 Budget Management

Autoissue 2.0 enforces budgets **BEFORE** task execution:

### How It Works

1. **Estimation** - Uses P90 of historical costs, or maxBudgetUsd if no history
2. **Pre-check** - Validates budget BEFORE spawning agent
3. **Tracking** - Records actual costs after execution
4. **Enforcement** - Throws BudgetExceededError if limit reached

### Configuration

```json
{
  "agent": {
    "maxBudgetUsd": 5.0  // Per-task budget
  },
  "maxTotalBudgetUsd": 50.0  // Session budget
}
```

### Example

```bash
# Set budget via environment variable
export AUTOISSUE_MAX_BUDGET=25.00
autoissue exec autoissue-1
```

If estimated cost exceeds budget, execution stops immediately:

```
❌ Error: Cannot afford 10 tasks: estimated $60.00 exceeds budget $25.00
```

## 🔄 Planner Mode

Use AI to decompose high-level directives into actionable GitHub issues:

```bash
autoissue plan "Build user authentication system with JWT and refresh tokens"
```

The planner will:
1. Analyze the directive
2. Generate GitHub issues with:
   - Detailed descriptions
   - Domain labels
   - Complexity estimates
   - Dependency relationships
3. Create issues in your repo
4. Execute them in dependency order

### Dry Run

Preview the plan without creating issues:

```bash
autoissue plan "Add Redis caching layer" --dry-run
```

## 🛡️ Error Handling

### Circuit Breaker

Autoissue uses circuit breakers to prevent cascading failures:

- **Closed** - Normal operation
- **Open** - Fails fast after 5 consecutive failures
- **Half-Open** - Testing recovery after 60s

Reset manually via API:

```bash
curl -X POST http://localhost:3030/api/circuit-breaker/reset
```

### Retry Logic

Failed tasks automatically retry with:
- Exponential backoff (1s → 2s → 4s)
- Error classification (retryable vs. non-retryable)
- Circuit breaker integration
- Max 2 retries per task

### Error Types

- `validation` - Input validation (non-retryable)
- `rate_limit` - API rate limit (retryable)
- `timeout` - Operation timeout (retryable)
- `crash` - Agent crash (retryable)
- `network` - Network issue (retryable)

## 📁 Project Structure

```
autoissue/
├── core/
│   ├── executor.ts          # Main execution loop
│   ├── scheduler.ts          # Sliding window scheduler
│   ├── agent.ts              # Claude agent interface
│   ├── worktree.ts           # Git worktree management
│   ├── planner.ts            # Directive decomposition
│   ├── budget-tracker.ts     # Budget enforcement
│   ├── error-boundaries.ts   # Error handling & circuit breaker
│   └── pr-manager.ts         # Pull request creation
├── lib/
│   ├── github-api.ts         # GitHub API client (Octokit)
│   ├── github-client.ts      # Legacy GitHub client
│   ├── domain-classifier.ts  # Domain classification
│   ├── conflict-detector.ts  # File conflict detection
│   ├── model-selector.ts     # AI model selection
│   └── types.ts              # TypeScript types
├── server/
│   ├── dashboard.ts          # Real-time dashboard server
│   └── API.md                # API documentation
├── ui/
│   └── cli-ui.tsx            # Terminal UI (React Ink)
└── __tests__/
    ├── e2e/                  # End-to-end tests
    └── *.test.ts             # Unit tests
```

## 🧪 Testing

```bash
# Run all tests
npm test

# Run specific test suite
npm test -- budget-tracker

# Run with coverage
npm test -- --coverage

# E2E tests (partial - some require real GitHub)
npm test -- e2e
```

## 🚢 Performance

### v2.0 Improvements Over v1.x

| Metric | v1.x | v2.0 | Improvement |
|--------|------|------|-------------|
| GitHub API | `gh` CLI (shell) | Octokit (REST) | **10x faster** |
| Conflict Detection | Naive O(n²) | LRU cached | **50-70% faster** |
| Error Handling | Manual retry | Circuit breaker | **<1% cascading** |
| Budget Checks | After execution | Before execution | **100% prevention** |

### Benchmarks

On a typical workload (10 issues, mixed domains):

```
GitHub API calls:    85ms (vs 850ms in v1.x)
Conflict detection:  12ms (vs 40ms in v1.x)
Budget validation:   <1ms (vs N/A in v1.x)
Total overhead:      ~100ms (vs ~900ms in v1.x)
```

## 🔧 Troubleshooting

### Budget Exceeded Immediately

If you see "Cannot afford X tasks" right away:

```bash
# Increase total budget
autoissue exec label --config config.json
# config.json: { "maxTotalBudgetUsd": 100.0 }

# Or reduce per-task budget (better estimates)
# config.json: { "agent": { "maxBudgetUsd": 3.0 } }
```

### Circuit Breaker Open

If all tasks fail immediately:

```bash
# Check circuit breaker state
curl http://localhost:3030/api/metrics/circuit-breaker

# Reset if needed
curl -X POST http://localhost:3030/api/circuit-breaker/reset
```

### Worktree Conflicts

If you see "worktree already exists":

```bash
# Clean up stale worktrees
git worktree prune

# Remove specific worktree
git worktree remove .worktrees/autoissue-issue-123
```

### Authentication Issues (Dashboard)

```bash
# Verify health endpoint works (no auth required)
curl http://localhost:3030/api/health

# Check auth configuration
curl -u username:password http://localhost:3030/api/metrics
```

## 📚 Documentation

- [API Reference](./server/API.md) - Complete REST API documentation
- [COMPLETION_PLAN.md](./COMPLETION_PLAN.md) - Development roadmap and progress
- [autoissue.config.example.json](./autoissue.config.example.json) - Example configuration

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'feat: add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📄 License

MIT License - see [LICENSE](./LICENSE) for details.

## 🙏 Acknowledgments

- Built with [Claude Code](https://claude.com/claude-code)
- Powered by [Anthropic Claude API](https://www.anthropic.com/)
- GitHub API via [@octokit/rest](https://github.com/octokit/rest.js)
- Terminal UI with [React Ink](https://github.com/vadimdemedes/ink)

---

**Made with ⚡ by [Venin Client Systems](https://github.com/Venin-Client-Systems)**
