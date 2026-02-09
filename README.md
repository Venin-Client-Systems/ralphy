# Ralphy

![Ralphy](assets/ralphy.jpeg)

An autonomous AI coding loop that processes GitHub issues (or PRD files) by spawning AI agents — Claude Code, OpenCode, Codex, Cursor, or Qwen — in isolated git worktrees until everything is done.

## Why Ralphy?

You label GitHub issues. Ralphy processes them — in parallel, with domain-aware scheduling, multi-instance coordination, and automatic merge-back. No babysitting.

**What makes it different from a shell loop:**
- **Sliding window parallelism** — agents start immediately as slots free up, not in fixed batches
- **Domain-aware scheduling** — backend + frontend run together; two backend tasks don't (they'd conflict)
- **Isolated worktrees** — each agent gets its own directory and branch, zero interference
- **Process tree cleanup** — timeouts kill the entire process tree, not just the shell
- **Multi-instance safe** — run multiple `ralphy` invocations on the same repo without double-work
- **Guardrails** — atomic worktree creation with rollback, merge verification, branch ledger audit trail

---

## Quick Start

### Install

```bash
# Clone to Claude Code plugins directory
git clone https://github.com/Venin-Client-Systems/ralphy.git ~/.claude/plugins/ralphy
chmod +x ~/.claude/plugins/ralphy/ralphy.sh

# Add shell function to ~/.zshrc (or ~/.bashrc)
cat >> ~/.zshrc << 'EOF'

# Ralphy - autonomous AI coding loop
ralphy() {
  local repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
  if [ -z "$repo" ]; then
    echo "Not in a git repo with GitHub remote"
    return 1
  fi
  if [ -z "$1" ]; then
    echo "Usage: ralphy <label> [options]"
    echo "       ralphy ralphy-1"
    echo "       ralphy ralphy-1 --parallel --max-parallel 3"
    return 1
  fi
  local label="$1"
  shift
  echo "Ralphy: Processing '$label' issues from $repo"
  ~/.claude/plugins/ralphy/ralphy.sh --claude --github "$repo" --github-label "$label" "$@"
}
EOF

source ~/.zshrc
```

### Run

```bash
ralphy code-review                         # Process issues labeled "code-review"
ralphy ralphy-1 --parallel                 # Parallel agents for "ralphy-1" issues
ralphy ralphy-1 --parallel --max-parallel 5 --create-pr  # 5 agents, auto-create PRs
```

### Requirements

- One of: [Claude Code](https://github.com/anthropics/claude-code), [OpenCode](https://opencode.ai/docs/), [Codex](https://github.com/openai/codex), [Cursor](https://cursor.com), or [Qwen-Code](https://github.com/QwenLM/qwen-code)
- [GitHub CLI](https://cli.github.com/) (`gh`) — for GitHub Issues mode
- `jq` — for JSON parsing

---

## How It Works

```
                    ┌─────────────────────────────────────────┐
                    │           RALPHY ORCHESTRATOR            │
                    │                                         │
                    │  1. Fetch tasks (GitHub/PRD/YAML)       │
                    │  2. Classify domains (backend/frontend) │
                    │  3. Schedule compatible tasks            │
                    │  4. Monitor + timeout + cleanup          │
                    └────────────┬────────────────────────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              ▼                  ▼                   ▼
     ┌─────────────┐   ┌─────────────┐    ┌─────────────┐
     │   Slot 1    │   │   Slot 2    │    │   Slot 3    │
     │  (backend)  │   │ (frontend)  │    │   (infra)   │
     │             │   │             │    │             │
     │  worktree/  │   │  worktree/  │    │  worktree/  │
     │  agent-1/   │   │  agent-2/   │    │  agent-3/   │
     │             │   │             │    │             │
     │  branch:    │   │  branch:    │    │  branch:    │
     │  ralphy/    │   │  ralphy/    │    │  ralphy/    │
     │  ...-api    │   │  ...-ui     │    │  ...-docker │
     └─────────────┘   └─────────────┘    └─────────────┘
```

1. **Fetch** — reads tasks from GitHub Issues, Markdown PRD, or YAML
2. **Classify** — detects each task's domain (backend, frontend, security, etc.) from title, labels, body, and file paths
3. **Schedule** — fills slots with domain-compatible tasks (backend + frontend = safe; backend + backend = wait)
4. **Execute** — each agent runs in an isolated git worktree with its own branch
5. **Complete** — merge branch back (or create PR), update project board, close issue
6. **Repeat** — as each slot frees, immediately start the next compatible task

---

## Task Sources

### GitHub Issues (recommended)

```bash
./ralphy.sh --github owner/repo --github-label "ready"
./ralphy.sh --github owner/repo --github-label "ralphy-1" --parallel
```

Issues are closed automatically on completion. Blocked issues get a comment explaining why.

### Markdown PRD

```bash
./ralphy.sh --prd PRD.md
```

```markdown
## Tasks
- [ ] Create user authentication
- [ ] Add dashboard page
- [x] Completed task (skipped)
```

### YAML

```bash
./ralphy.sh --yaml tasks.yaml
```

```yaml
tasks:
  - title: Create User model
    parallel_group: 1
  - title: Create Post model
    parallel_group: 1    # Runs alongside User model
  - title: Add relationships
    parallel_group: 2    # Waits for group 1
```

---

## Parallel Execution

### Sliding Window

Ralphy doesn't wait for a full batch to finish. As soon as any agent completes, the next compatible task starts immediately:

```
Time ──────────────────────────────────────►
Slot 1: [Task A (backend)    ] [Task D (backend)     ]
Slot 2: [Task B (frontend)         ] [Task E (security)]
Slot 3: [Task C (infra) ] [Task F (tests)  ] [Task G (docs)]
```

```bash
./ralphy.sh --parallel                     # 3 concurrent agents (default)
./ralphy.sh --parallel --max-parallel 5    # 5 concurrent agents
```

### Domain-Aware Scheduling

Ralphy classifies each task into a domain and only runs compatible tasks together:

| Domain | Detected from |
|--------|---------------|
| `backend` | `[Backend]` tag, `backend` label, `src/api/` paths, tRPC/router/middleware keywords |
| `frontend` | `[Frontend]` tag, `frontend` label, `src/components/` paths, React/component keywords |
| `database` | `[Database]` tag, `database` label, `src/db/` paths, Drizzle/migration keywords |
| `security` | `[Security]` tag, `security` label, CVE/XSS/CSRF/OWASP keywords |
| `billing` | `[Billing]` tag, `billing` label, Stripe/subscription/invoice keywords |
| `infra` | `[Infra]` tag, `infra` label, Docker/GitHub Actions/deploy keywords |
| `tests` | `[Tests]` tag, `testing` label, Playwright/Jest/E2E keywords |
| `docs` | `[Docs]` tag, `documentation` label, README/changelog keywords |

**Compatibility rules:**
- Different domains run in parallel (backend + frontend + infra = 3 agents)
- Same domain runs serially (two backend tasks would conflict on the same files)
- Database blocks everything (schema changes affect all layers)
- Unknown domain runs alone (can't determine safety)

### Isolated Worktrees

Each agent gets its own git worktree and PID-namespaced branch:

```
Agent 1 → /tmp/xxx/agent-1/ → ralphy/12345-agent-1-create-user-model
Agent 2 → /tmp/xxx/agent-2/ → ralphy/12345-agent-2-add-api-endpoints
Agent 3 → /tmp/xxx/agent-3/ → ralphy/12345-agent-3-setup-docker
```

No agent can interfere with another. Branches auto-merge back on completion (or create PRs with `--create-pr`).

---

## Multi-Instance Coordination

Run multiple `ralphy` invocations on the same repo simultaneously. Each instance:

- Claims issues via lock files (`~/.ralphy/locks/`)
- Skips issues already claimed by another instance
- Detects other active instances targeting the same branch
- Cleans up locks on exit

```bash
# Terminal 1                         # Terminal 2
ralphy ralphy-1 --parallel           ralphy ralphy-2 --parallel
# Works on ralphy-1 issues           # Works on ralphy-2 issues
# No overlap, no conflicts           # Independent worktrees
```

---

## Guardrails

Ralphy has safety mechanisms to prevent data loss:

- **Preflight checks** — refuses to run with dirty working tree, in-progress merges, or detached HEAD
- **Atomic worktree creation** — branch is rolled back if worktree setup fails
- **Branch ledger** — append-only log of every branch created, for audit and recovery
- **Merge verification** — confirms branch HEAD is ancestor of current HEAD after merge
- **Process tree kill** — timeouts kill the entire process tree (claude + all children), not just the shell
- **Cleanup re-entry guard** — double Ctrl+C doesn't corrupt state
- **Orphaned process cleanup** — kills stray tsc/eslint/node processes on exit
- **Post-run audit** — detects unmerged branches created by the current instance

---

## GitHub Project Board Integration

If your repo has a GitHub Project (V2), Ralphy updates it automatically:

```bash
./ralphy.sh --github owner/repo --github-label "ralphy-1" --project "owner/2"
```

- Issues move to **In Progress** when an agent starts
- Issues move to **In Review** when a PR is created
- Issues move to **Done** on completion
- Branch name is recorded in the project's Branch field

---

## AI Engines

```bash
./ralphy.sh --claude                           # Claude Code (default)
./ralphy.sh --opencode                         # OpenCode
./ralphy.sh --codex                            # Codex CLI
./ralphy.sh --cursor                           # Cursor agent
./ralphy.sh --qwen                             # Qwen-Code
./ralphy.sh --claude --fallback codex,opencode # Fallback chain on rate limits
```

| Engine | CLI | Permissions | Token Tracking |
|--------|-----|-------------|----------------|
| Claude Code | `claude` | `--dangerously-skip-permissions` | Input/output tokens + cost |
| OpenCode | `opencode` | `OPENCODE_PERMISSION='{"*":"allow"}'` | Input/output tokens + actual cost |
| Codex | `codex` | `--full-auto` | Input/output tokens |
| Cursor | `agent` | `--print --force` | API duration (tokens N/A) |
| Qwen-Code | `qwen` | `--approval-mode yolo` | Input/output tokens |

**Fallback chains:** If the primary engine hits rate limits, Ralphy automatically switches to the next engine in the chain.

---

## Agent Lessons

Agents learn from each other. When an agent discovers a repo-specific pattern or pitfall, it appends to `RALPHY_LESSONS.md`. This file is copied into every subsequent agent's worktree, so later agents avoid the same mistakes.

---

## All Options

### AI Engine
| Flag | Description |
|------|-------------|
| `--claude` | Claude Code (default) |
| `--opencode` | OpenCode |
| `--codex` | Codex CLI |
| `--cursor`, `--agent` | Cursor agent |
| `--qwen` | Qwen-Code |
| `--fallback ENGINE[,...]` | Fallback engines on rate limits |

### Task Source
| Flag | Description |
|------|-------------|
| `--prd FILE` | Markdown PRD (default: PRD.md) |
| `--yaml FILE` | YAML task file |
| `--github REPO` | GitHub Issues (owner/repo) |
| `--github-label TAG` | Filter issues by label |
| `--project OWNER/NUM` | GitHub Project board |

### Parallel Execution
| Flag | Description |
|------|-------------|
| `--parallel` | Enable parallel agents |
| `--max-parallel N` | Max concurrent agents (default: 3) |
| `--no-auto-parallel` | Disable auto-parallel in sequential mode |

### Git & PRs
| Flag | Description |
|------|-------------|
| `--branch-per-task` | Create branch per task |
| `--base-branch NAME` | Base branch (default: current) |
| `--create-pr` | Create pull requests |
| `--draft-pr` | Create as draft PRs |

### Workflow
| Flag | Description |
|------|-------------|
| `--no-tests` | Skip tests |
| `--no-lint` | Skip linting |
| `--fast` | Skip both |

### Execution Control
| Flag | Description |
|------|-------------|
| `--max-iterations N` | Stop after N tasks (0 = unlimited) |
| `--max-retries N` | Retries per task (default: 3) |
| `--retry-delay N` | Seconds between retries (default: 5) |
| `--dry-run` | Preview without executing |

### Other
| Flag | Description |
|------|-------------|
| `-v, --verbose` | Debug output |
| `-h, --help` | Show help |
| `--version` | Show version |

---

## Examples

```bash
# Process all "code-review" issues sequentially
ralphy code-review

# Parallel with 4 agents, create draft PRs
ralphy ralphy-1 --parallel --max-parallel 4 --create-pr --draft-pr

# Use OpenCode with Codex fallback, update project board
./ralphy.sh --opencode --fallback codex --github org/repo --github-label "ready" --project "org/2"

# Markdown PRD with parallel agents
./ralphy.sh --prd PRD.md --parallel --max-parallel 3

# YAML with branch-per-task and auto-PRs
./ralphy.sh --yaml tasks.yaml --branch-per-task --create-pr --base-branch main

# Dry run to preview
./ralphy.sh --github org/repo --github-label "ralphy-1" --dry-run --verbose
```

---

## Progress Display

**Sequential mode:** spinner with current step (Thinking, Reading, Implementing, Testing, Committing), task name, and elapsed time.

**Parallel mode:**
```
>>> Sliding window (up to 3 concurrent, 11 tasks queued)

  ▶ Slot 1 [1/11]: Fix API rate limiting (backend)
  ▶ Slot 2 [2/11]: Update dashboard charts (frontend)
  ▶ Slot 3 [3/11]: Add Docker health check (infra)
  ✓ Slot 1: Fix API rate limiting → ralphy/12345-agent-1-fix-api (3 files, 4m32s)
  ▶ Slot 1 [4/11]: Add webhook retry logic (backend)
    Progress: 1 done · 0 blocked · 3 active · 7 queued · 11 total

━━━ Round complete (12m45s) ━━━
  ✓ 8 done  ·  ⊘ 2 blocked  ·  11 total
```

**Notifications:** native OS notifications + sounds on macOS/Linux for task completion, errors, and stuck agents.

---

## Changelog

### v4.0.0
- Sliding window parallel execution replaces batch mode
- Domain-aware task scheduling (8 domains, 4-tier detection)
- Multi-instance coordination with lock files and issue claiming
- Guardrails: atomic worktrees, merge verification, branch ledger, preflight checks
- Process tree kill on timeout (kills claude + all children)
- Per-slot timeout precision (sub-second, not per-iteration)
- GitHub Project Board integration (In Progress / In Review / Done)
- Agent lessons system (RALPHY_LESSONS.md shared between agents)
- Fallback engine chains on rate limits
- Orphaned process cleanup (tsc/eslint/node children)
- Native OS notifications + sounds (macOS/Linux)
- Post-run audit for unmerged branches

### v3.2.0
- Added Qwen-Code support

### v3.1.0
- Added Cursor agent support
- Improved task completion verification

### v3.0.0
- Parallel task execution with git worktrees
- Multiple PRD formats (Markdown, YAML, GitHub Issues)
- AI-powered merge conflict resolution
- Branch per task with auto-PR creation

### v2.0.0
- Added OpenCode support
- Retry logic, `--max-iterations`, `--dry-run`
- Cross-platform notifications

### v1.0.0
- Initial release

## License

MIT
