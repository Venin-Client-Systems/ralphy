# Autoissue 2.0

**Turn your GitHub backlog into pull requests, overnight.**

Autoissue is a parallel AI code execution engine that processes GitHub issues with domain-aware scheduling.

## Quick Start

```bash
# Install dependencies
npm install

# Build
npm run build

# Link globally
npm link

# Run
autoissue --issues autoissue-1
```

## Architecture

```
Issue Fetching
    ↓
Domain Classification (backend, frontend, database, etc.)
    ↓
Sliding Window Scheduler (3 parallel slots by default)
    ↓
Parallel Execution (isolated git worktrees)
    ↓
Pull Requests
```

## Features

- ✅ **Parallel execution** - 3 tasks run concurrently by default
- ✅ **Domain-aware scheduling** - Backend + Frontend run together, Backend + Backend don't
- ✅ **Isolated worktrees** - Each task gets its own directory and branch
- ✅ **Automatic PRs** - Creates pull requests for completed tasks
- ✅ **Error recovery** - Circuit breakers, retry logic, automatic cleanup
- ✅ **Cost tracking** - Tracks spending across all tasks
- ✅ **Session persistence** - Resume failed runs

## Usage

### Direct Mode (Process Issues by Label)

```bash
autoissue --issues autoissue-1
```

Fetches all open issues labeled `autoissue-1`, classifies their domains, and processes them in parallel.

### Planner Mode (Directive → Issues)

```bash
autoissue --directive "Build JWT authentication with refresh tokens"
```

Uses AI to break the directive into GitHub issues, then processes them.

*(Coming soon)*

## Configuration

Create `autoissue.config.json`:

```json
{
  "project": {
    "repo": "owner/repo",
    "path": "/path/to/repo",
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
  "maxTotalBudgetUsd": 50.0
}
```

Or run without config - Autoissue auto-detects your git repository and uses sensible defaults.

## Development

```bash
# Type check
npm run typecheck

# Build
npm run build

# Dev mode
npm run dev -- --issues test
```

## License

MIT
