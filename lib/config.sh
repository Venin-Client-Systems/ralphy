# ============================================
# CONFIGURATION & DEFAULTS
# ============================================

VERSION="3.3.0"

# Track this ralphy instance PID for targeted cleanup
RALPHY_PID=$$

# Runtime options
SKIP_TESTS=false
SKIP_LINT=false
AI_ENGINE="claude"  # claude, opencode, cursor, codex, or qwen
FALLBACK_ENGINE=""  # Comma-separated fallback engines (empty = no fallback)
FALLBACK_ENGINES=()
FALLBACK_INDEX=0
ORIGINAL_ENGINE=""  # Track original engine for logging
FALLBACK_USED=false  # Track if we've switched to any fallback
TEST_FALLBACK=false  # Simulate rate limit to test fallback mechanism
DRY_RUN=false
MAX_ITERATIONS=0  # 0 = unlimited
MAX_RETRIES=3
RETRY_DELAY=5
VERBOSE=false

# Git branch options
BRANCH_PER_TASK=false
CREATE_PR=false
BASE_BRANCH=""
PR_DRAFT=false

# Parallel execution
PARALLEL=false
MAX_PARALLEL=3

# PRD source options
PRD_SOURCE="markdown"  # markdown, yaml, github
PRD_FILE="PRD.md"
GITHUB_REPO=""
GITHUB_LABEL=""

# Colors (detect if terminal supports colors)
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4)
  MAGENTA=$(tput setaf 5)
  CYAN=$(tput setaf 6)
  WHITE=$(tput setaf 7)
  BOLD=$(tput bold)
  DIM=$(tput dim)
  RESET=$(tput sgr0)
else
  RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN="" WHITE="" BOLD="" DIM="" RESET=""
fi

# Global state
ai_pid=""
monitor_pid=""
tmpfile=""
CODEX_LAST_MESSAGE_FILE=""
current_step="Thinking"
total_input_tokens=0
total_output_tokens=0
total_actual_cost="0"  # OpenCode provides actual cost
total_duration_ms=0    # Cursor provides duration
iteration=0
retry_count=0
declare -a parallel_pids=()
declare -a task_branches=()
declare -a blocked_issues=()      # Track issues that failed validation
declare -a blocked_reasons=()     # Track why each issue was blocked
LAST_ATTEMPTED_TASK=""            # Track last task for blocked issue handling
session_processed=0               # Track successfully processed tasks this session
declare -a completed_task_details=()  # "status|agent|issue|task_title|branch|elapsed_secs"

# Loop detection - prevent infinite retries on same issue
declare -a recent_failed_tasks=() # Rolling window of recently failed task IDs
MAX_CONSECUTIVE_FAILURES=3        # After this many failures on same task, take action
WORKTREE_BASE=""  # Base directory for parallel agent worktrees
ORIGINAL_DIR=""   # Original working directory (for worktree operations)
RALPHY_BRANCH_LEDGER=""  # Append-only branch ledger file path

# Multi-instance coordination
RALPHY_LOCK_DIR="${HOME}/.ralphy/instances"
RALPHY_LOCK_FILE=""
declare -a CLAIMED_ISSUES=()      # Issues claimed by THIS instance
AUTO_PARALLEL=true                # Enable smart auto-parallelism
AUTO_PARALLEL_MAX=3               # Max parallel when auto-detecting safe pairs

# GitHub Project Board integration
PROJECT_BOARD_NUM=""              # Project board number (e.g., 2)
PROJECT_BOARD_OWNER=""            # Project board owner (org or user)
PROJECT_NODE_ID=""                # GraphQL node ID for the project (resolved at runtime)
PROJECT_STATUS_FIELD_ID=""        # Status field ID
PROJECT_BATCH_FIELD_ID=""         # Ralphy Batch field ID
PROJECT_BRANCH_FIELD_ID=""        # Branch text field ID
declare -A PROJECT_STATUS_OPTIONS # Status option IDs (keyed by name)
declare -A PROJECT_BATCH_OPTIONS  # Ralphy Batch option IDs (keyed by label prefix)
declare -A PROJECT_ITEM_CACHE     # Maps issue_number -> project item ID
