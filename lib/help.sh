# ============================================
# HELP & VERSION
# ============================================

show_help() {
  cat << EOF
${BOLD}Ralphy${RESET} - Autonomous AI Coding Loop (v${VERSION})

${BOLD}USAGE:${RESET}
  ./ralphy.sh [options]

${BOLD}AI ENGINE OPTIONS:${RESET}
  --claude            Use Claude Code (default)
  --opencode          Use OpenCode
  --cursor            Use Cursor agent
  --codex             Use Codex CLI
  --qwen              Use Qwen-Code
  --fallback ENGINE[,ENGINE...]   Fallback engines when primary hits rate limits

${BOLD}WORKFLOW OPTIONS:${RESET}
  --no-tests          Skip writing and running tests
  --no-lint           Skip linting
  --fast              Skip both tests and linting

${BOLD}EXECUTION OPTIONS:${RESET}
  --max-iterations N  Stop after N iterations (0 = unlimited)
  --max-retries N     Max retries per task on failure (default: 3)
  --retry-delay N     Seconds between retries (default: 5)
  --dry-run           Show what would be done without executing

${BOLD}PARALLEL EXECUTION:${RESET}
  --parallel          Run independent tasks in parallel (explicit mode)
  --max-parallel N    Max concurrent tasks (default: 3)
  --no-auto-parallel  Disable smart auto-parallelism (default: enabled)

  By default, Ralphy runs up to 3 issues at once when all pairs are detected
  as safe (e.g., [Backend] + [Frontend] + [Tests]). Use --no-auto-parallel
  to force sequential.

${BOLD}MULTI-INSTANCE:${RESET}
  Multiple Ralphy instances can run simultaneously on the same repo.
  Instances automatically coordinate to avoid working on the same issues.
  Run 'ralphy ralphy-1' in one terminal and 'ralphy ralphy-2' in another.

${BOLD}GIT BRANCH OPTIONS:${RESET}
  --branch-per-task   Create a new git branch for each task
  --base-branch NAME  Base branch to create task branches from (default: current)
  --create-pr         Create a pull request after each task (requires gh CLI)
  --draft-pr          Create PRs as drafts

${BOLD}PRD SOURCE OPTIONS:${RESET}
  --prd FILE          PRD file path (default: PRD.md)
  --yaml FILE         Use YAML task file instead of markdown
  --github REPO       Fetch tasks from GitHub issues (e.g., owner/repo)
  --github-label TAG  Filter GitHub issues by label
  --project OWNER/NUM Link to a GitHub Project board (e.g., Venin-Client-Systems/2)

${BOLD}OTHER OPTIONS:${RESET}
  -v, --verbose       Show debug output
  -h, --help          Show this help
  --version           Show version number

${BOLD}EXAMPLES:${RESET}
  ./ralphy.sh                                   # Run with Claude Code (default)
  ./ralphy.sh --claude                          # Run with Claude Code
  ./ralphy.sh --codex                           # Run with Codex CLI
  ./ralphy.sh --opencode                        # Run with OpenCode
  ./ralphy.sh --cursor                          # Run with Cursor agent
  ./ralphy.sh --branch-per-task --create-pr     # Feature branch workflow
  ./ralphy.sh --parallel --max-parallel 4  # Run 4 tasks concurrently
  ./ralphy.sh --yaml tasks.yaml            # Use YAML task file
  ./ralphy.sh --github owner/repo          # Fetch from GitHub issues

${BOLD}PRD FORMATS:${RESET}
  Markdown (PRD.md):
    - [ ] Task description

  YAML (tasks.yaml):
    tasks:
      - title: Task description
        completed: false
        parallel_group: 1  # Optional: tasks with same group run in parallel

  GitHub Issues:
    Uses open issues from the specified repository

    Special labels (allow closing without code changes):
      no-code-required, decision, documentation, docs, chore,
      wontfix, won't fix, duplicate, invalid, question

EOF
}

show_version() {
  echo "Ralphy v${VERSION}"
}
