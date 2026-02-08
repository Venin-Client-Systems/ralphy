#!/usr/bin/env bash

# ============================================
# Ralphy - Autonomous AI Coding Loop
# Supports Claude Code, OpenCode, Codex, and Cursor
# Runs until PRD is complete
# ============================================

set -euo pipefail


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
  BOLD=$(tput bold)
  DIM=$(tput dim)
  RESET=$(tput sgr0)
else
  RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN="" BOLD="" DIM="" RESET=""
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

# Loop detection - prevent infinite retries on same issue
declare -a recent_failed_tasks=() # Rolling window of recently failed task IDs
MAX_CONSECUTIVE_FAILURES=3        # After this many failures on same task, take action
WORKTREE_BASE=""  # Base directory for parallel agent worktrees
ORIGINAL_DIR=""   # Original working directory (for worktree operations)

# Multi-instance coordination
RALPHY_LOCK_DIR="${HOME}/.ralphy/instances"
RALPHY_LOCK_FILE=""
declare -a CLAIMED_ISSUES=()      # Issues claimed by THIS instance
AUTO_PARALLEL=true                # Enable smart auto-parallelism
AUTO_PARALLEL_MAX=2               # Max parallel when auto-detecting safe pairs

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

# ============================================
# UTILITY FUNCTIONS
# ============================================

log_info() {
  echo "${BLUE}[INFO]${RESET} $*"
}

log_success() {
  echo "${GREEN}[OK]${RESET} $*"
}

log_warn() {
  echo "${YELLOW}[WARN]${RESET} $*"
}

log_error() {
  echo "${RED}[ERROR]${RESET} $*" >&2
}

log_debug() {
  if [[ "$VERBOSE" == true ]]; then
    echo "${DIM}[DEBUG] $*${RESET}"
  fi
}

# Slugify text for branch names
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-|-$//g' | cut -c1-50
}

# Check for non-trivial file changes between two refs (exclude progress/docs/README/CHANGELOG)
has_code_changes_between() {
  local base_ref="$1"
  local head_ref="$2"
  local repo_dir="${3:-}"

  if [[ -z "$base_ref" || -z "$head_ref" ]]; then
    return 1
  fi

  local diff_files
  if [[ -n "$repo_dir" ]]; then
    diff_files=$(git -C "$repo_dir" diff --name-only "$base_ref".."$head_ref" 2>/dev/null || true)
  else
    diff_files=$(git diff --name-only "$base_ref".."$head_ref" 2>/dev/null || true)
  fi
  local skip_regex='^(progress\.txt|README(\.[^/]+)?|CHANGELOG(\.[^/]+)?|docs/|doc/)'
  diff_files=$(echo "$diff_files" | grep -Ev "$skip_regex" | sed '/^$/d' || true)

  [[ -n "$diff_files" ]]
}

# ============================================
# GITHUB PROJECT BOARD INTEGRATION
# ============================================

# Initialize project board: resolve IDs for fields and options
project_board_init() {
  if [[ -z "$PROJECT_BOARD_NUM" ]] || [[ -z "$PROJECT_BOARD_OWNER" ]]; then
    log_warn "No project board configured (use --project OWNER/NUM or add to ~/.ralphy/config)"
    return 0
  fi

  log_info "Connecting to GitHub Project #${PROJECT_BOARD_NUM}..."

  # Get project node ID and all fields in one query
  local result
  result=$(gh api graphql -f query='
    query($owner: String!, $num: Int!) {
      organization(login: $owner) {
        projectV2(number: $num) {
          id
          title
          fields(first: 30) {
            nodes {
              ... on ProjectV2Field { id name }
              ... on ProjectV2SingleSelectField {
                id name
                options { id name }
              }
              ... on ProjectV2IterationField { id name }
            }
          }
        }
      }
    }' -f owner="$PROJECT_BOARD_OWNER" -F num="$PROJECT_BOARD_NUM" 2>/dev/null) || {
    log_warn "Could not connect to project board (will continue without board updates)"
    PROJECT_BOARD_NUM=""
    return 0
  }

  PROJECT_NODE_ID=$(echo "$result" | jq -r '.data.organization.projectV2.id // empty')
  if [[ -z "$PROJECT_NODE_ID" ]]; then
    log_warn "Project board not found (will continue without board updates)"
    PROJECT_BOARD_NUM=""
    return 0
  fi

  local board_title
  board_title=$(echo "$result" | jq -r '.data.organization.projectV2.title')
  log_info "Connected to project: ${CYAN}${board_title}${RESET}"

  # Extract field IDs
  PROJECT_STATUS_FIELD_ID=$(echo "$result" | jq -r '.data.organization.projectV2.fields.nodes[] | select(.name == "Status") | .id // empty')
  PROJECT_BATCH_FIELD_ID=$(echo "$result" | jq -r '.data.organization.projectV2.fields.nodes[] | select(.name == "Ralphy Batch") | .id // empty')
  PROJECT_BRANCH_FIELD_ID=$(echo "$result" | jq -r '.data.organization.projectV2.fields.nodes[] | select(.name == "Branch") | .id // empty')

  # Extract status options
  local status_options
  status_options=$(echo "$result" | jq -r '.data.organization.projectV2.fields.nodes[] | select(.name == "Status") | .options[]? | "\(.name)=\(.id)"')
  while IFS='=' read -r name id; do
    [[ -n "$name" ]] && PROJECT_STATUS_OPTIONS["$name"]="$id"
  done <<< "$status_options"

  # Extract batch options (key by label prefix like "ralphy-0")
  local batch_options
  batch_options=$(echo "$result" | jq -r '.data.organization.projectV2.fields.nodes[] | select(.name == "Ralphy Batch") | .options[]? | "\(.name)=\(.id)"')
  while IFS='=' read -r name id; do
    if [[ -n "$name" ]]; then
      # Extract prefix like "ralphy-0" from "ralphy-0 (critical)"
      local prefix="${name%% *}"
      PROJECT_BATCH_OPTIONS["$prefix"]="$id"
    fi
  done <<< "$batch_options"

  log_debug "Project fields: status=${PROJECT_STATUS_FIELD_ID:-none} batch=${PROJECT_BATCH_FIELD_ID:-none} branch=${PROJECT_BRANCH_FIELD_ID:-none}"
  log_debug "Status options: ${!PROJECT_STATUS_OPTIONS[*]}"
  log_debug "Batch options: ${!PROJECT_BATCH_OPTIONS[*]}"
}

# Add an issue to the project board and return the item ID
# Usage: project_board_add_issue <issue_number>
project_board_add_issue() {
  local issue_num="$1"
  if [[ -z "$PROJECT_NODE_ID" ]]; then return 0; fi

  # Check cache first
  if [[ -n "${PROJECT_ITEM_CACHE[$issue_num]:-}" ]]; then
    echo "${PROJECT_ITEM_CACHE[$issue_num]}"
    return 0
  fi

  # Get the issue's node ID
  local issue_node_id
  issue_node_id=$(gh api graphql -f query='
    query($owner: String!, $repo: String!, $num: Int!) {
      repository(owner: $owner, name: $repo) {
        issue(number: $num) { id }
      }
    }' -f owner="${GITHUB_REPO%%/*}" -f repo="${GITHUB_REPO##*/}" -F num="$issue_num" \
    --jq '.data.repository.issue.id' 2>/dev/null) || return 1

  if [[ -z "$issue_node_id" ]]; then return 1; fi

  # Add to project
  local item_id
  item_id=$(gh api graphql -f query='
    mutation($projectId: ID!, $contentId: ID!) {
      addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
        item { id }
      }
    }' -f projectId="$PROJECT_NODE_ID" -f contentId="$issue_node_id" \
    --jq '.data.addProjectV2ItemById.item.id' 2>/dev/null) || {
    log_debug "Failed to add issue #$issue_num to project board"
    return 1
  }

  if [[ -n "$item_id" ]]; then
    PROJECT_ITEM_CACHE[$issue_num]="$item_id"
    log_debug "Added issue #$issue_num to project board (item: ${item_id:0:20}...)"
    echo "$item_id"
  fi
}

# Update a single-select field on a project item
# Usage: project_board_update_select <item_id> <field_id> <option_id>
project_board_update_select() {
  local item_id="$1" field_id="$2" option_id="$3"
  if [[ -z "$PROJECT_NODE_ID" ]] || [[ -z "$item_id" ]] || [[ -z "$field_id" ]] || [[ -z "$option_id" ]]; then
    return 0
  fi

  gh api graphql -f query='
    mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $projectId
        itemId: $itemId
        fieldId: $fieldId
        value: {singleSelectOptionId: $optionId}
      }) {
        projectV2Item { id }
      }
    }' -f projectId="$PROJECT_NODE_ID" -f itemId="$item_id" \
       -f fieldId="$field_id" -f optionId="$option_id" >/dev/null 2>&1 || {
    log_debug "Failed to update select field on item $item_id"
    return 1
  }
}

# Update a text field on a project item
# Usage: project_board_update_text <item_id> <field_id> <value>
project_board_update_text() {
  local item_id="$1" field_id="$2" value="$3"
  if [[ -z "$PROJECT_NODE_ID" ]] || [[ -z "$item_id" ]] || [[ -z "$field_id" ]]; then
    return 0
  fi

  gh api graphql -f query='
    mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $text: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $projectId
        itemId: $itemId
        fieldId: $fieldId
        value: {text: $text}
      }) {
        projectV2Item { id }
      }
    }' -f projectId="$PROJECT_NODE_ID" -f itemId="$item_id" \
       -f fieldId="$field_id" -f text="$value" >/dev/null 2>&1 || {
    log_debug "Failed to update text field on item $item_id"
    return 1
  }
}

# Set the status of an issue on the project board
# Usage: project_board_set_status <issue_number> <status_name>
# status_name: "Todo", "Queued", "In Progress", "In Review", "Done"
project_board_set_status() {
  local issue_num="$1" status_name="$2"
  if [[ -z "$PROJECT_NODE_ID" ]] || [[ -z "$PROJECT_STATUS_FIELD_ID" ]]; then return 0; fi

  local option_id="${PROJECT_STATUS_OPTIONS[$status_name]:-}"
  if [[ -z "$option_id" ]]; then
    log_debug "Unknown project status: $status_name"
    return 1
  fi

  # Ensure issue is on the board
  local item_id
  item_id=$(project_board_add_issue "$issue_num") || return 1
  if [[ -z "$item_id" ]]; then return 1; fi

  project_board_update_select "$item_id" "$PROJECT_STATUS_FIELD_ID" "$option_id"
}

# Set the Ralphy Batch field for an issue
# Usage: project_board_set_batch <issue_number> <label>  (e.g., "ralphy-1")
project_board_set_batch() {
  local issue_num="$1" label="$2"
  if [[ -z "$PROJECT_NODE_ID" ]] || [[ -z "$PROJECT_BATCH_FIELD_ID" ]]; then return 0; fi

  local option_id="${PROJECT_BATCH_OPTIONS[$label]:-}"
  if [[ -z "$option_id" ]]; then
    log_debug "No batch option for label: $label"
    return 0
  fi

  local item_id
  item_id=$(project_board_add_issue "$issue_num") || return 1
  if [[ -z "$item_id" ]]; then return 1; fi

  project_board_update_select "$item_id" "$PROJECT_BATCH_FIELD_ID" "$option_id"
}

# Set the Branch field for an issue
# Usage: project_board_set_branch <issue_number> <branch_name>
project_board_set_branch() {
  local issue_num="$1" branch_name="$2"
  if [[ -z "$PROJECT_NODE_ID" ]] || [[ -z "$PROJECT_BRANCH_FIELD_ID" ]]; then return 0; fi

  local item_id
  item_id=$(project_board_add_issue "$issue_num") || return 1
  if [[ -z "$item_id" ]]; then return 1; fi

  project_board_update_text "$item_id" "$PROJECT_BRANCH_FIELD_ID" "$branch_name"
}

# Convenience: set up a task on the board when processing starts
# Usage: project_board_task_started <task>  (format: "number:title")
project_board_task_started() {
  local task="$1"
  local issue_num="${task%%:*}"
  if [[ -z "$PROJECT_NODE_ID" ]]; then return 0; fi

  # Add to board, set status, set batch label
  project_board_set_status "$issue_num" "In Progress" &
  if [[ -n "$GITHUB_LABEL" ]]; then
    project_board_set_batch "$issue_num" "$GITHUB_LABEL" &
  fi
  wait
}

# Convenience: mark a task done on the board
# Usage: project_board_task_completed <task> [branch_name]
project_board_task_completed() {
  local task="$1"
  local branch_name="${2:-}"
  local issue_num="${task%%:*}"
  if [[ -z "$PROJECT_NODE_ID" ]]; then return 0; fi

  project_board_set_status "$issue_num" "Done" &
  if [[ -n "$branch_name" ]]; then
    project_board_set_branch "$issue_num" "$branch_name" &
  fi
  wait
}

# Convenience: mark a task as in review on the board
# Usage: project_board_task_in_review <task> [branch_name]
project_board_task_in_review() {
  local task="$1"
  local branch_name="${2:-}"
  local issue_num="${task%%:*}"
  if [[ -z "$PROJECT_NODE_ID" ]]; then return 0; fi

  project_board_set_status "$issue_num" "In Review" &
  if [[ -n "$branch_name" ]]; then
    project_board_set_branch "$issue_num" "$branch_name" &
  fi
  wait
}

# Convenience: mark a task as queued on the board
# Usage: project_board_task_queued <task>
project_board_task_queued() {
  local task="$1"
  local issue_num="${task%%:*}"
  if [[ -z "$PROJECT_NODE_ID" ]]; then return 0; fi

  project_board_set_status "$issue_num" "Queued"
  if [[ -n "$GITHUB_LABEL" ]]; then
    project_board_set_batch "$issue_num" "$GITHUB_LABEL"
  fi
}

# ============================================
# MULTI-INSTANCE COORDINATION
# ============================================

# Get a hash of the current repo for lock file namespacing
get_repo_hash() {
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  echo "$repo_root" | md5sum 2>/dev/null | cut -c1-12 || echo "$repo_root" | shasum | cut -c1-12
}

# Initialize lock file for this instance
init_instance_lock() {
  local repo_hash
  repo_hash=$(get_repo_hash)
  local lock_dir="${RALPHY_LOCK_DIR}/${repo_hash}"
  mkdir -p "$lock_dir"

  RALPHY_LOCK_FILE="${lock_dir}/${RALPHY_PID}.json"

  # Write initial lock file
  cat > "$RALPHY_LOCK_FILE" << EOF
{
  "pid": $RALPHY_PID,
  "label": "${GITHUB_LABEL:-}",
  "repo": "${GITHUB_REPO:-}",
  "prd_source": "${PRD_SOURCE}",
  "started": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "current_issues": [],
  "cwd": "$(pwd)"
}
EOF
  log_debug "Created instance lock: $RALPHY_LOCK_FILE"
}

# Cleanup lock file on exit
cleanup_instance_lock() {
  if [[ -n "$RALPHY_LOCK_FILE" ]] && [[ -f "$RALPHY_LOCK_FILE" ]]; then
    rm -f "$RALPHY_LOCK_FILE"
    log_debug "Removed instance lock: $RALPHY_LOCK_FILE"
  fi
}

# Get list of other running ralphy instances (returns JSON lines)
get_other_instances() {
  local repo_hash
  repo_hash=$(get_repo_hash)
  local lock_dir="${RALPHY_LOCK_DIR}/${repo_hash}"

  [[ ! -d "$lock_dir" ]] && return

  for lock_file in "$lock_dir"/*.json; do
    [[ ! -f "$lock_file" ]] && continue

    local pid
    pid=$(jq -r '.pid' "$lock_file" 2>/dev/null || echo "")
    [[ -z "$pid" ]] && continue

    # Skip our own instance
    [[ "$pid" == "$RALPHY_PID" ]] && continue

    # Check if process is still alive
    if kill -0 "$pid" 2>/dev/null; then
      cat "$lock_file"
    else
      # Stale lock file, remove it
      rm -f "$lock_file" 2>/dev/null || true
    fi
  done
}

# Show status of other running instances
show_instance_status() {
  local instances
  instances=$(get_other_instances)

  [[ -z "$instances" ]] && return 0

  echo ""
  echo "${BOLD}>>> Other Ralphy Instances Running${RESET}"

  local count=0
  while IFS= read -r instance; do
    [[ -z "$instance" ]] && continue
    ((count++))

    local pid label issues started
    pid=$(echo "$instance" | jq -r '.pid')
    label=$(echo "$instance" | jq -r '.label // "none"')
    issues=$(echo "$instance" | jq -r '.current_issues | if length > 0 then map(tostring) | join(", ") else "idle" end')
    started=$(echo "$instance" | jq -r '.started // "unknown"')

    echo "  ${CYAN}◉${RESET} PID $pid: ${YELLOW}$label${RESET} (issues: $issues)"
  done <<< "$instances"

  if [[ $count -gt 0 ]]; then
    echo ""
    echo "${DIM}Issue claiming is active - instances will coordinate automatically${RESET}"
  fi

  return 0
}

# Claim an issue (mark as being worked on by this instance)
claim_issue() {
  local issue_num="$1"
  [[ -z "$issue_num" ]] && return 1

  # Add to local tracking
  CLAIMED_ISSUES+=("$issue_num")

  # Update lock file
  if [[ -n "$RALPHY_LOCK_FILE" ]] && [[ -f "$RALPHY_LOCK_FILE" ]]; then
    local issues_json
    issues_json=$(printf '%s\n' "${CLAIMED_ISSUES[@]}" | jq -R . | jq -s .)
    jq --argjson issues "$issues_json" '.current_issues = $issues' "$RALPHY_LOCK_FILE" > "${RALPHY_LOCK_FILE}.tmp" && \
      mv "${RALPHY_LOCK_FILE}.tmp" "$RALPHY_LOCK_FILE"
  fi

  log_debug "Claimed issue: $issue_num"
}

# Release an issue (unmark when done)
release_issue() {
  local issue_num="$1"
  [[ -z "$issue_num" ]] && return

  # Remove from local tracking
  local new_claimed=()
  for i in "${CLAIMED_ISSUES[@]}"; do
    [[ "$i" != "$issue_num" ]] && new_claimed+=("$i")
  done
  CLAIMED_ISSUES=("${new_claimed[@]}")

  # Update lock file
  if [[ -n "$RALPHY_LOCK_FILE" ]] && [[ -f "$RALPHY_LOCK_FILE" ]]; then
    local issues_json
    if [[ ${#CLAIMED_ISSUES[@]} -gt 0 ]]; then
      issues_json=$(printf '%s\n' "${CLAIMED_ISSUES[@]}" | jq -R . | jq -s .)
    else
      issues_json="[]"
    fi
    jq --argjson issues "$issues_json" '.current_issues = $issues' "$RALPHY_LOCK_FILE" > "${RALPHY_LOCK_FILE}.tmp" && \
      mv "${RALPHY_LOCK_FILE}.tmp" "$RALPHY_LOCK_FILE"
  fi

  log_debug "Released issue: $issue_num"
}

# Check if an issue is claimed by another instance
is_issue_claimed() {
  local issue_num="$1"
  [[ -z "$issue_num" ]] && return 1

  local instances
  instances=$(get_other_instances)
  [[ -z "$instances" ]] && return 1

  while IFS= read -r instance; do
    [[ -z "$instance" ]] && continue

    local claimed
    claimed=$(echo "$instance" | jq -r ".current_issues[]" 2>/dev/null || true)

    for claimed_num in $claimed; do
      if [[ "$claimed_num" == "$issue_num" ]]; then
        return 0  # Issue is claimed
      fi
    done
  done <<< "$instances"

  return 1  # Issue is not claimed
}

# Extract domain hints from issue title/body/labels
# Returns: backend, frontend, database, tests, docs, infra, security, billing, unknown
# Detection tiers (highest confidence first):
#   1. Explicit [Tag] in issue title
#   2. GitHub issue labels
#   3. File path patterns in title+body
#   4. Keyword matching (most specific domains first to avoid misclassification)
get_issue_domain() {
  local title="$1"
  local body="${2:-}"
  local labels="${3:-}"
  local combined
  combined=$(echo "$title $body" | tr '[:upper:]' '[:lower:]')
  local labels_lower
  labels_lower=$(echo "$labels" | tr '[:upper:]' '[:lower:]')

  # === TIER 1: Explicit tags in title (highest confidence) ===
  if echo "$title" | grep -qiE '^\[(backend|api|server)\]'; then
    echo "backend"; return
  elif echo "$title" | grep -qiE '^\[(frontend|ui|client|component|ux)\]'; then
    echo "frontend"; return
  elif echo "$title" | grep -qiE '^\[(database|db|schema|migration)\]'; then
    echo "database"; return
  elif echo "$title" | grep -qiE '^\[(test|testing|e2e|qa)\]'; then
    echo "tests"; return
  elif echo "$title" | grep -qiE '^\[(docs?|documentation)\]'; then
    echo "docs"; return
  elif echo "$title" | grep -qiE '^\[(infra|ci|deploy|docker|devops)\]'; then
    echo "infra"; return
  elif echo "$title" | grep -qiE '^\[(security|vuln|cve)\]'; then
    echo "security"; return
  elif echo "$title" | grep -qiE '^\[(billing|payments?|stripe)\]'; then
    echo "billing"; return
  fi

  # === TIER 2: GitHub issue labels ===
  if [[ -n "$labels_lower" ]]; then
    if echo "$labels_lower" | grep -qE '(backend|api|server)'; then
      echo "backend"; return
    elif echo "$labels_lower" | grep -qE '(frontend|ui|ux|component)'; then
      echo "frontend"; return
    elif echo "$labels_lower" | grep -qE '(database|db|schema|migration)'; then
      echo "database"; return
    elif echo "$labels_lower" | grep -qE '(test|testing|e2e|qa)'; then
      echo "tests"; return
    elif echo "$labels_lower" | grep -qE '(documentation|docs)'; then
      echo "docs"; return
    elif echo "$labels_lower" | grep -qE '(infra|ci|deploy|docker|devops)'; then
      echo "infra"; return
    elif echo "$labels_lower" | grep -qE '(security|vuln|cve)'; then
      echo "security"; return
    elif echo "$labels_lower" | grep -qE '(billing|payment|stripe)'; then
      echo "billing"; return
    fi
  fi

  # === TIER 3: File path patterns in title+body ===
  if echo "$combined" | grep -qE 'src/(api|server|backend|routers?|services?|middleware|lib/(api|auth|trpc))'; then
    echo "backend"; return
  elif echo "$combined" | grep -qE 'src/(components?|pages?|app/\(|ui/|hooks?/)'; then
    echo "frontend"; return
  elif echo "$combined" | grep -qE '(src/db/|drizzle/|\.schema\.ts|drizzle\.config)'; then
    echo "database"; return
  elif echo "$combined" | grep -qE '(tests?/|\.test\.|\.spec\.|__tests__|playwright)'; then
    echo "tests"; return
  elif echo "$combined" | grep -qE '(\.github/|docker|Dockerfile|Caddyfile)'; then
    echo "infra"; return
  fi

  # === TIER 4: Keyword matching (most specific domains checked first) ===

  # Security - highly specific terms, checked first to catch security fixes
  if echo "$combined" | grep -qE 'vulnerabilit|cve-[0-9]|xss|csrf|sql.injection|sanitiz(e|ation)|prototype.pollution|owasp|content.security.policy|hsts|security.header|security.fix|security.patch|security.audit|secret.leak|credential.leak|privilege.escalat|access.control|brute.force|password.hash'; then
    echo "security"; return
  fi

  # Billing - highly specific terms
  if echo "$combined" | grep -qE 'stripe|subscription|invoice|payment|billing|pricing.page|checkout|coupon|discount|refund|metered|usage.based|plan.limit|free.trial|paywall'; then
    echo "billing"; return
  fi

  # Database - specific to schema/data layer
  if echo "$combined" | grep -qE 'drizzle|neon.postgres|database.migration|schema.change|add.column|drop.column|create.table|alter.table|foreign.key|db.constraint|seed.data|db.connection|db.index'; then
    echo "database"; return
  fi

  # Docs - checked before infra/tests to avoid "deploy" in "deployment docs" matching infra
  if echo "$combined" | grep -qE 'readme|documentation|changelog|contributing|api.doc|swagger|openapi.spec|jsdoc|typedoc|storybook'; then
    echo "docs"; return
  fi

  # Tests - testing-specific terms
  if echo "$combined" | grep -qE 'playwright|jest|vitest|test.coverage|test.fixture|e2e.test|integration.test|unit.test|snapshot.test|regression.test|flaky.test|test.suite|test.helper|test.util'; then
    echo "tests"; return
  fi

  # Infra - CI/CD, deployment, build tooling
  if echo "$combined" | grep -qE 'docker|container|github.action|deploy|caddy|nginx|ssl.cert|dns|cloudflare|aws|lightsail|ci.cd|pipeline|health.check|monitoring|sentry|build.fail|bundle.size|turbopack|dockerfile|env.var|environment.variable|github.workflow|docker.compose'; then
    echo "infra"; return
  fi

  # Backend - broader terms (checked after more specific domains)
  if echo "$combined" | grep -qE 'trpc|router|endpoint|mutation|middleware|webhook|cron.job|auth|session|jwt|oauth|cors|rate.limit|cache|redis|queue|worker|email.send|notification|server.action|server.component|api.route|api.handler|request.handler|upload|download'; then
    echo "backend"; return
  fi

  # Frontend - broadest terms (checked last)
  if echo "$combined" | grep -qE 'component|usestate|useeffect|usecallback|usememo|useref|usecontext|jsx|tsx|react|button|modal|dialog|form.input|form.valid|data.table|chart|layout|sidebar|navbar|tooltip|dropdown|menu|panel|card|skeleton|loading|spinner|toast|alert|badge|icon|theme|dark.mode|responsive|css|tailwind|classname|shadcn|radix|dashboard|onboarding|wizard|stepper|animation|transition|popover|combobox|checkbox|radio|toggle|switch|accordion|breadcrumb|pagination|avatar|progress.bar|slider|tab.component|landing.page'; then
    echo "frontend"; return
  fi

  echo "unknown"
}

# Determine if two issues can safely run in parallel
# Returns 0 if safe, 1 if not safe
# Sets LAST_DOMAIN1 and LAST_DOMAIN2 for callers to reuse (avoids duplicate API calls)
can_issues_run_parallel() {
  local task1="$1"
  local task2="$2"

  [[ -z "$task1" || -z "$task2" ]] && return 1

  # Extract issue numbers and titles
  local num1="${task1%%:*}"
  local title1="${task1#*:}"
  local num2="${task2%%:*}"
  local title2="${task2#*:}"

  # Get issue bodies and labels for more context
  local body1="" body2="" labels1="" labels2=""
  if [[ "$PRD_SOURCE" == "github" ]]; then
    body1=$(get_github_issue_body "$task1" 2>/dev/null || echo "")
    body2=$(get_github_issue_body "$task2" 2>/dev/null || echo "")
    labels1=$(get_github_issue_labels "$task1" 2>/dev/null || echo "")
    labels2=$(get_github_issue_labels "$task2" 2>/dev/null || echo "")
  fi

  # Get domains (passing labels for better classification)
  local domain1 domain2
  domain1=$(get_issue_domain "$title1" "$body1" "$labels1")
  domain2=$(get_issue_domain "$title2" "$body2" "$labels2")

  # Cache for callers (e.g., run_auto_parallel_batch display)
  LAST_DOMAIN1="$domain1"
  LAST_DOMAIN2="$domain2"

  log_debug "Issue $num1 domain: $domain1"
  log_debug "Issue $num2 domain: $domain2"

  # If either is unknown, don't parallelize (be safe)
  [[ "$domain1" == "unknown" || "$domain2" == "unknown" ]] && return 1

  # Same domain = likely to conflict
  [[ "$domain1" == "$domain2" ]] && return 1

  # Database changes should never run in parallel with anything
  [[ "$domain1" == "database" || "$domain2" == "database" ]] && return 1

  # Security touches multiple layers - only safe with docs, tests, infra
  # (security fixes often span backend+frontend, e.g., XSS, CORS, sanitization)

  # These domain pairs are safe to parallelize
  case "$domain1:$domain2" in
    # Original safe pairs
    backend:frontend|frontend:backend) return 0 ;;
    backend:docs|docs:backend) return 0 ;;
    frontend:docs|docs:frontend) return 0 ;;
    backend:tests|tests:backend) return 0 ;;
    frontend:tests|tests:frontend) return 0 ;;
    backend:infra|infra:backend) return 0 ;;
    frontend:infra|infra:frontend) return 0 ;;
    docs:tests|tests:docs) return 0 ;;
    docs:infra|infra:docs) return 0 ;;
    tests:infra|infra:tests) return 0 ;;
    # Security - conservative: only with docs, tests, infra (no app code overlap)
    security:docs|docs:security) return 0 ;;
    security:tests|tests:security) return 0 ;;
    security:infra|infra:security) return 0 ;;
    # Billing - safe with frontend, docs, tests, infra (billing logic is backend-side)
    billing:frontend|frontend:billing) return 0 ;;
    billing:docs|docs:billing) return 0 ;;
    billing:tests|tests:billing) return 0 ;;
    billing:infra|infra:billing) return 0 ;;
    *) return 1 ;;  # Default to not safe
  esac
}

# Get next unclaimed task (skips issues claimed by other instances)
get_next_unclaimed_task() {
  local all_tasks
  all_tasks=$(get_all_tasks)

  while IFS= read -r task; do
    [[ -z "$task" ]] && continue

    local issue_num="${task%%:*}"

    # Skip if claimed by another instance
    if is_issue_claimed "$issue_num"; then
      log_debug "Skipping issue $issue_num (claimed by another instance)"
      continue
    fi

    echo "$task"
    return 0
  done <<< "$all_tasks"

  echo ""
}

# Get a pair of tasks that can safely run in parallel
# Returns two tasks separated by newline, or single task if no safe pair found
get_parallel_safe_pair() {
  local all_tasks=()

  while IFS= read -r task; do
    [[ -z "$task" ]] && continue

    local issue_num="${task%%:*}"

    # Skip if claimed by another instance
    if is_issue_claimed "$issue_num"; then
      log_debug "Skipping issue $issue_num (claimed by another instance)"
      continue
    fi

    all_tasks+=("$task")
  done < <(get_all_tasks)

  local count=${#all_tasks[@]}
  [[ $count -eq 0 ]] && return 1

  # If only one task, return it
  if [[ $count -eq 1 ]]; then
    echo "${all_tasks[0]}"
    return 0
  fi

  # Try to find a safe pair starting from the first task
  local first_task="${all_tasks[0]}"

  for ((i = 1; i < count && i < 10; i++)); do  # Check up to 10 tasks for a pair
    local second_task="${all_tasks[$i]}"

    if can_issues_run_parallel "$first_task" "$second_task"; then
      echo "$first_task"
      echo "$second_task"
      return 0
    fi
  done

  # No safe pair found, return just the first task
  echo "$first_task"
  return 0
}

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

  By default, Ralphy runs 2 issues at once when they're detected as safe
  (e.g., [Backend] + [Frontend]). Use --no-auto-parallel to force sequential.

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

# ============================================
# ARGUMENT PARSING
# ============================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --no-tests|--skip-tests)
        SKIP_TESTS=true
        shift
        ;;
      --no-lint|--skip-lint)
        SKIP_LINT=true
        shift
        ;;
      --fast)
        SKIP_TESTS=true
        SKIP_LINT=true
        shift
        ;;
      --opencode)
        AI_ENGINE="opencode"
        shift
        ;;
      --claude)
        AI_ENGINE="claude"
        shift
        ;;
      --cursor|--agent)
        AI_ENGINE="cursor"
        shift
        ;;
      --codex)
        AI_ENGINE="codex"
        shift
        ;;
      --qwen)
        AI_ENGINE="qwen"
        shift
        ;;
      --fallback)
        local fallback_value="${2:-claude}"
        if [[ -z "$FALLBACK_ENGINE" ]]; then
          FALLBACK_ENGINE="$fallback_value"
        else
          FALLBACK_ENGINE="${FALLBACK_ENGINE},${fallback_value}"
        fi
        shift 2
        ;;
      --test-fallback)
        # Simulate rate limit on first attempt to test fallback mechanism
        TEST_FALLBACK=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --max-iterations)
        MAX_ITERATIONS="${2:-0}"
        shift 2
        ;;
      --max-retries)
        MAX_RETRIES="${2:-3}"
        shift 2
        ;;
      --retry-delay)
        RETRY_DELAY="${2:-5}"
        shift 2
        ;;
      --parallel)
        PARALLEL=true
        shift
        ;;
      --max-parallel)
        MAX_PARALLEL="${2:-3}"
        shift 2
        ;;
      --no-auto-parallel)
        AUTO_PARALLEL=false
        shift
        ;;
      --branch-per-task)
        BRANCH_PER_TASK=true
        shift
        ;;
      --base-branch)
        BASE_BRANCH="${2:-}"
        shift 2
        ;;
      --create-pr)
        CREATE_PR=true
        shift
        ;;
      --draft-pr)
        PR_DRAFT=true
        shift
        ;;
      --prd)
        PRD_FILE="${2:-PRD.md}"
        PRD_SOURCE="markdown"
        shift 2
        ;;
      --yaml)
        PRD_FILE="${2:-tasks.yaml}"
        PRD_SOURCE="yaml"
        shift 2
        ;;
      --github)
        GITHUB_REPO="${2:-}"
        PRD_SOURCE="github"
        shift 2
        ;;
      --github-label)
        GITHUB_LABEL="${2:-}"
        shift 2
        ;;
      --project)
        # Format: --project OWNER/NUM (e.g., Venin-Client-Systems/2)
        local project_val="${2:-}"
        PROJECT_BOARD_OWNER="${project_val%%/*}"
        PROJECT_BOARD_NUM="${project_val##*/}"
        shift 2
        ;;
      -v|--verbose)
        VERBOSE=true
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      --version)
        show_version
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        echo "Use --help for usage"
        exit 1
        ;;
    esac
  done
}


# ============================================
# ENGINE HELPERS
# ============================================

init_fallback_engines() {
  FALLBACK_ENGINES=()
  FALLBACK_INDEX=0
  FALLBACK_USED=false

  if [[ -z "$FALLBACK_ENGINE" ]]; then
    return
  fi

  local raw
  raw=$(echo "$FALLBACK_ENGINE" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  IFS=',' read -r -a FALLBACK_ENGINES <<< "$raw"
}

engine_display_name() {
  local engine="$1"
  case "$engine" in
    opencode) echo "${CYAN}OpenCode${RESET}" ;;
    cursor) echo "${YELLOW}Cursor Agent${RESET}" ;;
    codex) echo "${BLUE}Codex${RESET}" ;;
    qwen) echo "${GREEN}Qwen-Code${RESET}" ;;
    claude|"") echo "${MAGENTA}Claude Code${RESET}" ;;
    *) echo "${MAGENTA}${engine}${RESET}" ;;
  esac
}

require_engine_cli() {
  local engine="$1"
  case "$engine" in
    opencode)
      if ! command -v opencode &>/dev/null; then
        log_error "OpenCode CLI not found. Install from https://opencode.ai/docs/"
        exit 1
      fi
      ;;
    codex)
      if ! command -v codex &>/dev/null; then
        log_error "Codex CLI not found. Make sure 'codex' is in your PATH."
        exit 1
      fi
      ;;
    cursor)
      if ! command -v agent &>/dev/null; then
        log_error "Cursor agent CLI not found. Make sure Cursor is installed and 'agent' is in your PATH."
        exit 1
      fi
      ;;
    qwen)
      if ! command -v qwen &>/dev/null; then
        log_error "Qwen-Code CLI not found. Make sure 'qwen' is in your PATH."
        exit 1
      fi
      ;;
    claude|"")
      if ! command -v claude &>/dev/null; then
        log_error "Claude Code CLI not found. Install from https://github.com/anthropics/claude-code"
        exit 1
      fi
      ;;
    *)
      log_error "Unknown AI engine: $engine"
      exit 1
      ;;
  esac
}

# ============================================
# PRE-FLIGHT CHECKS
# ============================================

check_requirements() {
  local missing=()

  # Check for PRD source
  case "$PRD_SOURCE" in
    markdown)
      if [[ ! -f "$PRD_FILE" ]]; then
        log_error "$PRD_FILE not found in current directory"
        exit 1
      fi
      ;;
    yaml)
      if [[ ! -f "$PRD_FILE" ]]; then
        log_error "$PRD_FILE not found in current directory"
        exit 1
      fi
      if ! command -v yq &>/dev/null; then
        log_error "yq is required for YAML parsing. Install from https://github.com/mikefarah/yq"
        exit 1
      fi
      ;;
    github)
      if [[ -z "$GITHUB_REPO" ]]; then
        log_error "GitHub repository not specified. Use --github owner/repo"
        exit 1
      fi
      if ! command -v gh &>/dev/null; then
        log_error "GitHub CLI (gh) is required. Install from https://cli.github.com/"
        exit 1
      fi
      ;;
  esac

  # Warn if --github-label used without --github
  if [[ -n "$GITHUB_LABEL" ]] && [[ "$PRD_SOURCE" != "github" ]]; then
    log_warn "--github-label has no effect without --github"
  fi

  # Check for AI CLI
  require_engine_cli "$AI_ENGINE"
  if [[ ${#FALLBACK_ENGINES[@]} -gt 0 ]]; then
    local fallback_engine
    for fallback_engine in "${FALLBACK_ENGINES[@]}"; do
      require_engine_cli "$fallback_engine"
    done
  fi

  # Check for jq
  if ! command -v jq &>/dev/null; then
    missing+=("jq")
  fi

  # Check for gh if PR creation is requested
  if [[ "$CREATE_PR" == true ]] && ! command -v gh &>/dev/null; then
    log_error "GitHub CLI (gh) is required for --create-pr. Install from https://cli.github.com/"
    exit 1
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_warn "Missing optional dependencies: ${missing[*]}"
    log_warn "Token tracking and multi-instance coordination may not work properly"
  fi

  # Create progress.txt if missing
  if [[ ! -f "progress.txt" ]]; then
    log_warn "progress.txt not found, creating it..."
    touch progress.txt
  fi

  # Set base branch if not specified
  if [[ "$BRANCH_PER_TASK" == true ]] && [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    log_debug "Using base branch: $BASE_BRANCH"
  fi

  # Auto-detect project board from per-repo config if --project not specified
  if [[ -z "$PROJECT_BOARD_NUM" ]] && [[ "$PRD_SOURCE" == "github" ]] && [[ -n "$GITHUB_REPO" ]]; then
    local config_file="${HOME}/.ralphy/config"
    if [[ -f "$config_file" ]]; then
      # Look up repo-specific mapping: project.<owner/repo>=<owner/project-number>
      local config_project
      config_project=$(grep -E "^project\\.${GITHUB_REPO}=" "$config_file" 2>/dev/null | head -1 | cut -d= -f2-)
      if [[ -n "$config_project" ]]; then
        PROJECT_BOARD_OWNER="${config_project%%/*}"
        PROJECT_BOARD_NUM="${config_project##*/}"
        log_debug "Auto-detected project board for ${GITHUB_REPO}: $PROJECT_BOARD_OWNER/$PROJECT_BOARD_NUM"
      fi
    fi
  fi
}

# ============================================
# CLEANUP HANDLER
# ============================================

# Helper: Get all descendant PIDs recursively
get_all_descendants() {
  local pid=$1
  local descendants=$(pgrep -P "$pid" 2>/dev/null || true)

  if [[ -n "$descendants" ]]; then
    echo "$descendants"
    for child_pid in $descendants; do
      get_all_descendants "$child_pid"
    done
  fi
}

cleanup() {
  local exit_code=$?

  # Kill background processes and their entire process trees
  if [[ -n "$monitor_pid" ]]; then
    pkill -P "$monitor_pid" 2>/dev/null || true
    kill "$monitor_pid" 2>/dev/null || true
  fi
  if [[ -n "$ai_pid" ]]; then
    # Kill entire process tree rooted at ai_pid (claude → npm exec → node)
    pkill -P "$ai_pid" 2>/dev/null || true
    kill "$ai_pid" 2>/dev/null || true
  fi

  # Kill parallel processes and their trees
  for pid in "${parallel_pids[@]+"${parallel_pids[@]}"}"; do
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done

  # Kill any remaining child processes
  pkill -P $$ 2>/dev/null || true

  # Kill orphaned Claude Code processes spawned by agents
  # Only kill descendants of THIS ralphy instance, not all Claude Code instances
  if [[ -n "$RALPHY_PID" ]]; then
    local all_descendants=$(get_all_descendants "$RALPHY_PID")
    if [[ -n "$all_descendants" ]]; then
      # Kill any Claude Code processes that are descendants of this ralphy
      for pid in $all_descendants; do
        local cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
        if [[ "$cmdline" == *"claude-code"* ]] || [[ "$cmdline" == *"npm exec"* ]]; then
          kill -TERM "$pid" 2>/dev/null || true
        fi
      done
    fi
  fi

  # Kill orphaned tsc/eslint processes spawned by agents
  # Only kill those from this ralphy instance's working directory
  if [[ -n "$ORIGINAL_DIR" ]]; then
    if [[ -n "$RALPHY_PID" ]]; then
      local all_descendants=$(get_all_descendants "$RALPHY_PID")
      if [[ -n "$all_descendants" ]]; then
        for pid in $all_descendants; do
          local cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
          if [[ "$cmdline" == *"tsc"*"${ORIGINAL_DIR}"* ]] || [[ "$cmdline" == *"eslint"*"${ORIGINAL_DIR}"* ]]; then
            kill -TERM "$pid" 2>/dev/null || true
          fi
        done
      fi
    fi
  fi

  # Remove temp file
  [[ -n "$tmpfile" ]] && rm -f "$tmpfile"
  [[ -n "$CODEX_LAST_MESSAGE_FILE" ]] && rm -f "$CODEX_LAST_MESSAGE_FILE"

  # Cleanup instance lock file
  cleanup_instance_lock

  # Cleanup parallel worktrees
  if [[ -n "$WORKTREE_BASE" ]] && [[ -d "$WORKTREE_BASE" ]]; then
    # Remove all worktrees we created
    for dir in "$WORKTREE_BASE"/agent-*; do
      if [[ -d "$dir" ]]; then
        if git -C "$dir" status --porcelain 2>/dev/null | grep -q .; then
          log_warn "Preserving dirty worktree: $dir"
          continue
        fi
        git worktree remove "$dir" 2>/dev/null || true
      fi
    done
    if ! find "$WORKTREE_BASE" -maxdepth 1 -type d -name 'agent-*' -print -quit 2>/dev/null | grep -q .; then
      rm -rf "$WORKTREE_BASE" 2>/dev/null || true
    else
      log_warn "Preserving worktree base with dirty agents: $WORKTREE_BASE"
    fi
  fi
  
  # Show message on interrupt
  if [[ $exit_code -eq 130 ]]; then
    printf "\n"
    log_warn "Interrupted! Cleaned up."
    
    # Show branches created if any
    if [[ -n "${task_branches[*]+"${task_branches[*]}"}" ]]; then
      log_info "Branches created: ${task_branches[*]}"
    fi
  fi
}

# ============================================
# TASK SOURCES - MARKDOWN
# ============================================

get_tasks_markdown() {
  grep '^\- \[ \]' "$PRD_FILE" 2>/dev/null | sed 's/^- \[ \] //' || true
}

get_next_task_markdown() {
  grep -m1 '^\- \[ \]' "$PRD_FILE" 2>/dev/null | sed 's/^- \[ \] //' || echo ""
}

count_remaining_markdown() {
  grep -c '^\- \[ \]' "$PRD_FILE" 2>/dev/null || echo "0"
}

count_completed_markdown() {
  grep -c '^\- \[x\]' "$PRD_FILE" 2>/dev/null || echo "0"
}

mark_task_complete_markdown() {
  local task=$1
  # For macOS sed (BRE), we need to:
  # - Escape: [ ] \ . * ^ $ /
  # - NOT escape: { } ( ) + ? | (these are literal in BRE)
  local escaped_task
  escaped_task=$(printf '%s\n' "$task" | sed 's/[[\.*^$/]/\\&/g')
  sed -i.bak "s/^- \[ \] ${escaped_task}/- [x] ${escaped_task}/" "$PRD_FILE"
  rm -f "${PRD_FILE}.bak"
}

# ============================================
# TASK SOURCES - YAML
# ============================================

get_tasks_yaml() {
  yq -r '.tasks[] | select(.completed != true) | .title' "$PRD_FILE" 2>/dev/null || true
}

get_next_task_yaml() {
  yq -r '.tasks[] | select(.completed != true) | .title' "$PRD_FILE" 2>/dev/null | head -1 || echo ""
}

count_remaining_yaml() {
  yq -r '[.tasks[] | select(.completed != true)] | length' "$PRD_FILE" 2>/dev/null || echo "0"
}

count_completed_yaml() {
  yq -r '[.tasks[] | select(.completed == true)] | length' "$PRD_FILE" 2>/dev/null || echo "0"
}

mark_task_complete_yaml() {
  local task=$1
  yq -i "(.tasks[] | select(.title == \"$task\")).completed = true" "$PRD_FILE"
}

get_parallel_group_yaml() {
  local task=$1
  yq -r ".tasks[] | select(.title == \"$task\") | .parallel_group // 0" "$PRD_FILE" 2>/dev/null || echo "0"
}

get_tasks_in_group_yaml() {
  local group=$1
  yq -r ".tasks[] | select(.completed != true and (.parallel_group // 0) == $group) | .title" "$PRD_FILE" 2>/dev/null || true
}

# ============================================
# TASK SOURCES - GITHUB ISSUES
# ============================================

get_tasks_github() {
  local args=(--repo "$GITHUB_REPO" --state open --limit 500 --json number,title --search "sort:created-asc")
  [[ -n "$GITHUB_LABEL" ]] && args+=(--label "$GITHUB_LABEL")

  gh issue list "${args[@]}" \
    --jq '.[] | "\(.number):\(.title)"' 2>/dev/null || true
}

get_next_task_github() {
  local args=(--repo "$GITHUB_REPO" --state open --limit 1 --json number,title --search "sort:created-asc")
  [[ -n "$GITHUB_LABEL" ]] && args+=(--label "$GITHUB_LABEL")

  gh issue list "${args[@]}" \
    --jq 'if length == 0 then "" else .[0] | "\(.number):\(.title)" end' 2>/dev/null || echo ""
}

count_remaining_github() {
  local args=(--repo "$GITHUB_REPO" --state open --limit 500 --json number)
  [[ -n "$GITHUB_LABEL" ]] && args+=(--label "$GITHUB_LABEL")

  gh issue list "${args[@]}" \
    --jq 'length' 2>/dev/null || echo "0"
}

count_completed_github() {
  local args=(--repo "$GITHUB_REPO" --state closed --limit 500 --json number)
  [[ -n "$GITHUB_LABEL" ]] && args+=(--label "$GITHUB_LABEL")

  gh issue list "${args[@]}" \
    --jq 'length' 2>/dev/null || echo "0"
}

mark_task_complete_github() {
  local task=$1
  local comment="${2:-}"
  # Extract issue number from "number:title" format
  local issue_num="${task%%:*}"

  # Add completion comment before closing (required)
  if [[ -n "$comment" ]]; then
    gh issue comment "$issue_num" --repo "$GITHUB_REPO" --body "$comment" 2>/dev/null || true
  else
    # Default comment if none provided
    gh issue comment "$issue_num" --repo "$GITHUB_REPO" --body "Task completed by Ralphy automated workflow." 2>/dev/null || true
  fi

  # Now close the issue
  gh issue close "$issue_num" --repo "$GITHUB_REPO" 2>/dev/null || true
}

# Check if a GitHub issue has a label that allows closing without code changes
# Labels: no-code-required, decision, documentation, chore, wontfix, duplicate, invalid
issue_allows_no_code() {
  local task=$1
  local issue_num="${task%%:*}"

  local labels
  labels=$(gh issue view "$issue_num" --repo "$GITHUB_REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")

  # Check for any label that indicates no code is required
  local no_code_labels="no-code-required|decision|documentation|docs|chore|wontfix|won't fix|duplicate|invalid|question"
  if echo "$labels" | grep -qiE "^($no_code_labels)$"; then
    return 0  # true - no code required
  fi

  return 1  # false - code is required
}

# Mark a GitHub issue as blocked (add label and track for summary)
mark_issue_blocked() {
  local task="$1"
  local reason="$2"
  local issue_num="${task%%:*}"

  # Add to tracking arrays
  blocked_issues+=("$task")
  blocked_reasons+=("$reason")

  # Add ralphy-blocked label to the issue
  if [[ "$PRD_SOURCE" == "github" ]] && [[ -n "$GITHUB_REPO" ]]; then
    gh issue edit "$issue_num" --repo "$GITHUB_REPO" --add-label "ralphy-blocked" 2>/dev/null || true
    gh issue comment "$issue_num" --repo "$GITHUB_REPO" --body "## Ralphy Blocked

**Reason:** $reason

This issue was skipped by Ralphy and needs manual review.

**To unblock:**
- If no code changes are needed, add one of these labels: \`chore\`, \`documentation\`, \`decision\`, \`no-code-required\`
- Remove the \`ralphy-blocked\` label
- Re-run ralphy" 2>/dev/null || true
  fi

  # Update project board status to Blocked
  project_board_set_status "$issue_num" "Blocked"

  log_warn "Issue $issue_num blocked: $reason"
}

# Check if a task title indicates it's a docs/chore issue that shouldn't require code
is_docs_or_chore_task() {
  local title="$1"
  # Match [Docs], [Documentation], [Chore], [Decision], etc. at start of title
  if echo "$title" | grep -qiE '^\[docs\]|^\[documentation\]|^\[chore\]|^\[decision\]|^\[planning\]|^\[rfc\]'; then
    return 0  # true
  fi
  return 1  # false
}

# Auto-add documentation label to docs issues so they can close without code changes
auto_label_docs_issue() {
  local task="$1"
  local issue_num="${task%%:*}"
  local title="${task#*:}"

  if [[ "$PRD_SOURCE" != "github" ]] || [[ -z "$GITHUB_REPO" ]]; then
    return 1
  fi

  # Check if it's a docs/chore task by title
  if is_docs_or_chore_task "$title"; then
    # Check if it already has a no-code-required label
    if ! issue_allows_no_code "$task"; then
      log_info "Auto-adding 'documentation' label to docs issue #$issue_num"
      gh issue edit "$issue_num" --repo "$GITHUB_REPO" --add-label "documentation" 2>/dev/null || true
      return 0
    fi
  fi
  return 1
}

# Track a failed task and check for loops
# Returns 0 if loop detected (same task failed too many times), 1 otherwise
track_failed_task() {
  local task="$1"
  local issue_num="${task%%:*}"

  # Add to recent failures
  recent_failed_tasks+=("$issue_num")

  # Keep only last N*2 entries (enough to detect patterns)
  local max_entries=$((MAX_CONSECUTIVE_FAILURES * 2))
  if [[ ${#recent_failed_tasks[@]} -gt $max_entries ]]; then
    recent_failed_tasks=("${recent_failed_tasks[@]: -$max_entries}")
  fi

  # Count consecutive failures of this specific issue
  local consecutive=0
  for ((i=${#recent_failed_tasks[@]}-1; i>=0; i--)); do
    if [[ "${recent_failed_tasks[$i]}" == "$issue_num" ]]; then
      ((consecutive++))
    else
      break  # Different issue, stop counting
    fi
  done

  if [[ $consecutive -ge $MAX_CONSECUTIVE_FAILURES ]]; then
    return 0  # Loop detected
  fi
  return 1  # No loop
}

# Handle a detected loop - try to fix or exit gracefully
handle_task_loop() {
  local task="$1"
  local issue_num="${task%%:*}"
  local title="${task#*:}"

  echo ""
  echo "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo "${RED}LOOP DETECTED${RESET}: Issue #$issue_num failed $MAX_CONSECUTIVE_FAILURES+ times consecutively"
  echo "${DIM}$title${RESET}"
  echo "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""

  # Try to auto-fix if it's a docs issue
  if is_docs_or_chore_task "$title"; then
    echo "${YELLOW}This appears to be a documentation/chore issue.${RESET}"
    echo "${YELLOW}Attempting auto-fix: adding 'documentation' label...${RESET}"

    if gh issue edit "$issue_num" --repo "$GITHUB_REPO" --add-label "documentation" 2>/dev/null; then
      echo "${GREEN}✓ Added 'documentation' label to issue #$issue_num${RESET}"
      echo "${GREEN}The issue should now close on the next attempt.${RESET}"
      echo ""
      # Clear the failure tracking for this issue so it gets another chance
      recent_failed_tasks=()
      return 0  # Continue running
    else
      echo "${RED}✗ Failed to add label. Manual intervention required.${RESET}"
    fi
  fi

  # Can't auto-fix - block and exit
  echo ""
  echo "${YELLOW}Ralphy is stopping to prevent infinite loop.${RESET}"
  echo ""
  echo "${BOLD}To fix this issue:${RESET}"
  echo "  1. Add one of these labels: ${CYAN}documentation${RESET}, ${CYAN}chore${RESET}, ${CYAN}no-code-required${RESET}, ${CYAN}decision${RESET}"
  echo "  2. Re-run: ${CYAN}ralphy $GITHUB_LABEL${RESET}"
  echo ""

  # Mark blocked so it shows in summary
  mark_issue_blocked "$task" "Loop detected - task failed $MAX_CONSECUTIVE_FAILURES+ times"

  return 1  # Signal to exit
}

get_github_issue_body() {
  local task=$1
  local issue_num="${task%%:*}"
  gh issue view "$issue_num" --repo "$GITHUB_REPO" --json body --jq '.body' 2>/dev/null || echo ""
}

get_github_issue_labels() {
  local task=$1
  local issue_num="${task%%:*}"
  gh issue view "$issue_num" --repo "$GITHUB_REPO" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo ""
}

# ============================================
# UNIFIED TASK INTERFACE
# ============================================

get_next_task() {
  case "$PRD_SOURCE" in
    markdown) get_next_task_markdown ;;
    yaml) get_next_task_yaml ;;
    github) get_next_task_github ;;
  esac
}

get_all_tasks() {
  case "$PRD_SOURCE" in
    markdown) get_tasks_markdown ;;
    yaml) get_tasks_yaml ;;
    github) get_tasks_github ;;
  esac
}

count_remaining_tasks() {
  case "$PRD_SOURCE" in
    markdown) count_remaining_markdown ;;
    yaml) count_remaining_yaml ;;
    github) count_remaining_github ;;
  esac
}

count_completed_tasks() {
  case "$PRD_SOURCE" in
    markdown) count_completed_markdown ;;
    yaml) count_completed_yaml ;;
    github) count_completed_github ;;
  esac
}

mark_task_complete() {
  local task=$1
  local comment="${2:-}"
  case "$PRD_SOURCE" in
    markdown) mark_task_complete_markdown "$task" ;;
    yaml) mark_task_complete_yaml "$task" ;;
    github) mark_task_complete_github "$task" "$comment" ;;
  esac
}

# ============================================
# GIT BRANCH MANAGEMENT
# ============================================

create_task_branch() {
  local task=$1
  local branch_name="ralphy/$(slugify "$task")"
  
  log_debug "Creating branch: $branch_name from $BASE_BRANCH"
  
  # Stash any changes (only pop if a new stash was created)
  local stash_before stash_after stashed=false
  stash_before=$(git stash list -1 --format='%gd %s' 2>/dev/null || true)
  git stash push -m "ralphy-autostash" >/dev/null 2>&1 || true
  stash_after=$(git stash list -1 --format='%gd %s' 2>/dev/null || true)
  if [[ -n "$stash_after" ]] && [[ "$stash_after" != "$stash_before" ]] && [[ "$stash_after" == *"ralphy-autostash"* ]]; then
    stashed=true
  fi
  
  # Create and checkout new branch
  git checkout "$BASE_BRANCH" 2>/dev/null || true
  git pull origin "$BASE_BRANCH" 2>/dev/null || true
  git checkout -b "$branch_name" 2>/dev/null || {
    # Branch might already exist
    git checkout "$branch_name" 2>/dev/null || true
  }
  
  # Pop stash if we stashed
  if [[ "$stashed" == true ]]; then
    git stash pop >/dev/null 2>&1 || true
  fi
  
  task_branches+=("$branch_name")
  echo "$branch_name"
}

create_pull_request() {
  local branch=$1
  local task=$2
  local body="${3:-Automated PR created by Ralphy}"
  
  local draft_flag=""
  [[ "$PR_DRAFT" == true ]] && draft_flag="--draft"
  
  log_info "Creating pull request for $branch..."
  
  # Push branch first
  git push -u origin "$branch" 2>/dev/null || {
    log_warn "Failed to push branch $branch"
    return 1
  }
  
  # Create PR
  local pr_url
  pr_url=$(gh pr create \
    --base "$BASE_BRANCH" \
    --head "$branch" \
    --title "$task" \
    --body "$body" \
    $draft_flag 2>/dev/null) || {
    log_warn "Failed to create PR for $branch"
    return 1
  }
  
  log_success "PR created: $pr_url"
  echo "$pr_url"
}

return_to_base_branch() {
  if [[ "$BRANCH_PER_TASK" == true ]]; then
    git checkout "$BASE_BRANCH" 2>/dev/null || true
  fi
}

# ============================================
# PROGRESS MONITOR
# ============================================

monitor_progress() {
  local file=$1
  local task=$2
  local start_time
  start_time=$(date +%s)
  local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local spin_idx=0

  task="${task:0:40}"

  while true; do
    local elapsed=$(($(date +%s) - start_time))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))

    # Check latest output for step indicators
    if [[ -f "$file" ]] && [[ -s "$file" ]]; then
      local content
      content=$(tail -c 5000 "$file" 2>/dev/null || true)

      if echo "$content" | grep -qE 'git commit|"command":"git commit'; then
        current_step="Committing"
      elif echo "$content" | grep -qE 'git add|"command":"git add'; then
        current_step="Staging"
      elif echo "$content" | grep -qE 'progress\.txt'; then
        current_step="Logging"
      elif echo "$content" | grep -qE 'PRD\.md|tasks\.yaml'; then
        current_step="Updating PRD"
      elif echo "$content" | grep -qE 'lint|eslint|biome|prettier'; then
        current_step="Linting"
      elif echo "$content" | grep -qE 'vitest|jest|bun test|npm test|pytest|go test'; then
        current_step="Testing"
      elif echo "$content" | grep -qE '\.test\.|\.spec\.|__tests__|_test\.go'; then
        current_step="Writing tests"
      elif echo "$content" | grep -qE '"tool":"[Ww]rite"|"tool":"[Ee]dit"|"name":"write"|"name":"edit"'; then
        current_step="Implementing"
      elif echo "$content" | grep -qE '"tool":"[Rr]ead"|"tool":"[Gg]lob"|"tool":"[Gg]rep"|"name":"read"|"name":"glob"|"name":"grep"'; then
        current_step="Reading code"
      fi
    fi

    local spinner_char="${spinstr:$spin_idx:1}"
    local step_color=""
    
    # Color-code steps
    case "$current_step" in
      "Thinking"|"Reading code") step_color="$CYAN" ;;
      "Implementing"|"Writing tests") step_color="$MAGENTA" ;;
      "Testing"|"Linting") step_color="$YELLOW" ;;
      "Staging"|"Committing") step_color="$GREEN" ;;
      *) step_color="$BLUE" ;;
    esac

    # Use tput for cleaner line clearing
    tput cr 2>/dev/null || printf "\r"
    tput el 2>/dev/null || true
    printf "  %s ${step_color}%-16s${RESET} │ %s ${DIM}[%02d:%02d]${RESET}" "$spinner_char" "$current_step" "$task" "$mins" "$secs"

    spin_idx=$(( (spin_idx + 1) % ${#spinstr} ))
    sleep 0.12
  done
}

# ============================================
# NOTIFICATION (Cross-platform)
# ============================================

notify_done() {
  local message="${1:-Ralphy has completed all tasks!}"

  # Clean up orphaned tsc/eslint processes from this batch
  # Only kill those that are descendants of this ralphy instance
  if [[ -n "$ORIGINAL_DIR" ]] && [[ -n "$RALPHY_PID" ]]; then
    local all_descendants=$(get_all_descendants "$RALPHY_PID")
    if [[ -n "$all_descendants" ]]; then
      for pid in $all_descendants; do
        local cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
        if [[ "$cmdline" == *"tsc"*"${ORIGINAL_DIR}"* ]] || [[ "$cmdline" == *"eslint"*"${ORIGINAL_DIR}"* ]]; then
          kill -TERM "$pid" 2>/dev/null || true
        fi
      done
    fi
  fi

  # macOS
  if command -v afplay &>/dev/null; then
    afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &
  fi
  
  # macOS notification
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"$message\" with title \"Ralphy\"" 2>/dev/null || true
  fi
  
  # Linux (notify-send)
  if command -v notify-send &>/dev/null; then
    notify-send "Ralphy" "$message" 2>/dev/null || true
  fi
  
  # Linux (paplay for sound)
  if command -v paplay &>/dev/null; then
    paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null &
  fi
  
  # Windows (powershell)
  if command -v powershell.exe &>/dev/null; then
    powershell.exe -Command "[System.Media.SystemSounds]::Asterisk.Play()" 2>/dev/null || true
  fi
}

notify_error() {
  local message="${1:-Ralphy encountered an error}"
  
  # macOS
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"$message\" with title \"Ralphy - Error\"" 2>/dev/null || true
  fi
  
  # Linux
  if command -v notify-send &>/dev/null; then
    notify-send -u critical "Ralphy - Error" "$message" 2>/dev/null || true
  fi
}

# ============================================
# PROMPT BUILDER
# ============================================

build_prompt() {
  local task_override="${1:-}"
  local prompt=""
  
  # Add context based on PRD source
  case "$PRD_SOURCE" in
    markdown)
      prompt="@${PRD_FILE} @progress.txt"
      ;;
    yaml)
      prompt="@${PRD_FILE} @progress.txt"
      ;;
    github)
      # For GitHub issues, we include the issue body
      local issue_body=""
      if [[ -n "$task_override" ]]; then
        issue_body=$(get_github_issue_body "$task_override")
      fi
      prompt="Task from GitHub Issue: $task_override

Issue Description:
$issue_body

@progress.txt"
      ;;
  esac
  
  prompt="$prompt
IMPORTANT: You MUST use tools to read and edit files in this repo. Do not respond with a plan only.
If you cannot access tools or the repo, respond exactly with 'TOOL_ACCESS_FAILED'.
1. Find the highest-priority incomplete task and implement it."

  local step=2
  
  if [[ "$SKIP_TESTS" == false ]]; then
    prompt="$prompt
$step. Write tests for the feature.
$((step+1)). Run tests and ensure they pass before proceeding."
    step=$((step+2))
  fi

  if [[ "$SKIP_LINT" == false ]]; then
    prompt="$prompt
$step. Run linting and ensure it passes before proceeding."
    step=$((step+1))
  fi

  # Adjust completion step based on PRD source
  case "$PRD_SOURCE" in
    markdown)
      prompt="$prompt
$step. Update the PRD to mark the task as complete (change '- [ ]' to '- [x]')."
      ;;
    yaml)
      prompt="$prompt
$step. Update ${PRD_FILE} to mark the task as completed (set completed: true)."
      ;;
    github)
      prompt="$prompt
$step. The task will be marked complete automatically. Just note the completion in progress.txt."
      ;;
  esac
  
  step=$((step+1))
  
  prompt="$prompt
$step. Append your progress to progress.txt.
$((step+1)). Commit your changes with a descriptive message.
ONLY WORK ON A SINGLE TASK."

  if [[ "$SKIP_TESTS" == false ]]; then
    prompt="$prompt Do not proceed if tests fail."
  fi
  if [[ "$SKIP_LINT" == false ]]; then
    prompt="$prompt Do not proceed if linting fails."
  fi

  prompt="$prompt
If ALL tasks in the PRD are complete, output <promise>COMPLETE</promise>."

  echo "$prompt"
}

# ============================================
# AI ENGINE ABSTRACTION
# ============================================

run_ai_command() {
  local prompt=$1
  local output_file=$2
  
  case "$AI_ENGINE" in
    opencode)
      # OpenCode: use 'run' command with JSON format and permissive settings
      OPENCODE_PERMISSION='{"*":"allow"}' opencode run \
        --format json \
        "$prompt" > "$output_file" 2>&1 &
      ;;
    cursor)
      # Cursor agent: use --print for non-interactive, --force to allow all commands
      agent --print --force \
        --output-format stream-json \
        "$prompt" > "$output_file" 2>&1 &
      ;;
    qwen)
      # Qwen-Code: use CLI with JSON format and auto-approve tools
      qwen --output-format stream-json \
        --approval-mode yolo \
        -p "$prompt" > "$output_file" 2>&1 &
      ;;
    codex)
      CODEX_LAST_MESSAGE_FILE="${output_file}.last"
      rm -f "$CODEX_LAST_MESSAGE_FILE"
      codex exec --full-auto \
        --json \
        --output-last-message "$CODEX_LAST_MESSAGE_FILE" \
        "$prompt" > "$output_file" 2>&1 &
      ;;
    *)
      # Claude Code: use existing approach
      claude --dangerously-skip-permissions \
        --verbose \
        --output-format stream-json \
        -p "$prompt" > "$output_file" 2>&1 &
      ;;
  esac
  
  ai_pid=$!
}

parse_ai_result() {
  local result=$1
  local response=""
  local input_tokens=0
  local output_tokens=0
  local actual_cost="0"
  
  case "$AI_ENGINE" in
    opencode)
      # OpenCode JSON format: uses step_finish for tokens and text events for response
      local step_finish
      step_finish=$(echo "$result" | grep '"type":"step_finish"' | tail -1 || echo "")
      
      if [[ -n "$step_finish" ]]; then
        input_tokens=$(echo "$step_finish" | jq -r '.part.tokens.input // 0' 2>/dev/null || echo "0")
        output_tokens=$(echo "$step_finish" | jq -r '.part.tokens.output // 0' 2>/dev/null || echo "0")
        # OpenCode provides actual cost directly
        actual_cost=$(echo "$step_finish" | jq -r '.part.cost // 0' 2>/dev/null || echo "0")
      fi
      
      # Get text response from text events
      response=$(echo "$result" | grep '"type":"text"' | jq -rs 'map(.part.text // "") | join("")' 2>/dev/null || echo "")
      
      # If no text found, indicate task completed
      if [[ -z "$response" ]]; then
        response="Task completed"
      fi
      ;;
    cursor)
      # Cursor agent: parse stream-json output
      # Cursor doesn't provide token counts, but does provide duration_ms
      
      local result_line
      result_line=$(echo "$result" | grep '"type":"result"' | tail -1)
      
      if [[ -n "$result_line" ]]; then
        response=$(echo "$result_line" | jq -r '.result // "Task completed"' 2>/dev/null || echo "Task completed")
        # Cursor provides duration instead of tokens
        local duration_ms
        duration_ms=$(echo "$result_line" | jq -r '.duration_ms // 0' 2>/dev/null || echo "0")
        # Store duration in output_tokens field for now (we'll handle it specially)
        # Use negative value as marker that this is duration, not tokens
        if [[ "$duration_ms" =~ ^[0-9]+$ ]] && [[ "$duration_ms" -gt 0 ]]; then
          # Encode duration: store as-is, we track separately
          actual_cost="duration:$duration_ms"
        fi
      fi
      
      # Get response from assistant message if result is empty
      if [[ -z "$response" ]] || [[ "$response" == "Task completed" ]]; then
        local assistant_msg
        assistant_msg=$(echo "$result" | grep '"type":"assistant"' | tail -1)
        if [[ -n "$assistant_msg" ]]; then
          response=$(echo "$assistant_msg" | jq -r '.message.content[0].text // .message.content // "Task completed"' 2>/dev/null || echo "Task completed")
        fi
      fi
      
      # Tokens remain 0 for Cursor (not available)
      input_tokens=0
      output_tokens=0
      ;;
    qwen)
      # Qwen-Code stream-json parsing (similar to Claude Code)
      local result_line
      result_line=$(echo "$result" | grep '"type":"result"' | tail -1)

      if [[ -n "$result_line" ]]; then
        response=$(echo "$result_line" | jq -r '.result // "No result text"' 2>/dev/null || echo "Could not parse result")
        input_tokens=$(echo "$result_line" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo "0")
        output_tokens=$(echo "$result_line" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo "0")
      fi

      # Fallback when no response text was parsed, similar to OpenCode behavior
      if [[ -z "$response" ]]; then
        response="Task completed"
      fi
      ;;
    codex)
      if [[ -n "$CODEX_LAST_MESSAGE_FILE" ]] && [[ -f "$CODEX_LAST_MESSAGE_FILE" ]]; then
        response=$(cat "$CODEX_LAST_MESSAGE_FILE" 2>/dev/null || echo "")
        # Codex sometimes prefixes a generic completion line; drop it for readability.
        response=$(printf '%s' "$response" | sed '1{/^Task completed successfully\.[[:space:]]*$/d;}')
      fi
      input_tokens=0
      output_tokens=0
      ;;
    *)
      # Claude Code stream-json parsing
      local result_line
      result_line=$(echo "$result" | grep '"type":"result"' | tail -1)
      
      if [[ -n "$result_line" ]]; then
        response=$(echo "$result_line" | jq -r '.result // "No result text"' 2>/dev/null || echo "Could not parse result")
        input_tokens=$(echo "$result_line" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo "0")
        output_tokens=$(echo "$result_line" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo "0")
      fi
      ;;
  esac
  
  # Sanitize token counts
  [[ "$input_tokens" =~ ^[0-9]+$ ]] || input_tokens=0
  [[ "$output_tokens" =~ ^[0-9]+$ ]] || output_tokens=0
  
  echo "$response"
  echo "---TOKENS---"
  echo "$input_tokens"
  echo "$output_tokens"
  echo "$actual_cost"
}

check_for_errors() {
  local result=$1

  if echo "$result" | grep -q '"type":"error"'; then
    local error_msg
    error_msg=$(echo "$result" | grep '"type":"error"' | head -1 | jq -r '.error.message // .message // .' 2>/dev/null || echo "Unknown error")
    echo "$error_msg"
    return 1
  fi

  return 0
}

has_tool_usage() {
  local result=$1

  if echo "$result" | grep -qE '"type":"tool_use"'; then
    return 0
  fi
  if echo "$result" | grep -qE '"tool":"[A-Za-z_]+"' ; then
    return 0
  fi
  if echo "$result" | grep -qE '"tool_name":"[A-Za-z_]+"' ; then
    return 0
  fi
  if echo "$result" | grep -qE '"name":"(read|glob|grep|write|edit|patch|apply_patch|run_shell_command|shell|exec|bash|cmd)"'; then
    return 0
  fi

  return 1
}

has_repo_changes_since() {
  local start_head="$1"
  local start_status="$2"
  local repo_dir="${3:-}"
  local head_now=""
  local status_now=""

  if [[ -n "$repo_dir" ]]; then
    head_now=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "")
    status_now=$(git -C "$repo_dir" status --porcelain 2>/dev/null || echo "")
  else
    head_now=$(git rev-parse HEAD 2>/dev/null || echo "")
    status_now=$(git status --porcelain 2>/dev/null || echo "")
  fi

  if [[ -n "$start_head" && -n "$head_now" && "$head_now" != "$start_head" ]]; then
    return 0
  fi
  if [[ "$status_now" != "$start_status" ]]; then
    return 0
  fi

  return 1
}

# Check if error is a rate limit / quota exceeded error
is_rate_limit_error() {
  local error_msg=$1

  # Common rate limit / quota error patterns across providers
  local patterns=(
    "rate.?limit"
    "quota.?exceeded"
    "too.?many.?requests"
    "429"
    "resource.?exhausted"
    "capacity"
    "overloaded"
    "usage.?limit"
    "billing"
    "insufficient.?quota"
    "free.?tier"
    "RPM"
    "TPM"
    "tokens?.?per.?minute"
    "requests?.?per.?minute"
  )

  local lower_msg
  lower_msg=$(echo "$error_msg" | tr '[:upper:]' '[:lower:]')

  for pattern in "${patterns[@]}"; do
    if echo "$lower_msg" | grep -qiE "$pattern"; then
      return 0  # Is a rate limit error
    fi
  done

  return 1  # Not a rate limit error
}

# Switch to fallback engine
switch_to_fallback() {
  if [[ ${#FALLBACK_ENGINES[@]} -eq 0 ]]; then
    return 1  # No fallback configured
  fi

  local next_engine=""

  while [[ $FALLBACK_INDEX -lt ${#FALLBACK_ENGINES[@]} ]]; do
    next_engine="${FALLBACK_ENGINES[$FALLBACK_INDEX]}"
    FALLBACK_INDEX=$((FALLBACK_INDEX + 1))

    if [[ -z "$next_engine" ]] || [[ "$next_engine" == "$AI_ENGINE" ]]; then
      continue
    fi

    ORIGINAL_ENGINE="$AI_ENGINE"
    AI_ENGINE="$next_engine"
    FALLBACK_USED=true

    log_warn "Switching from $ORIGINAL_ENGINE to $AI_ENGINE due to rate limit"
    return 0
  done

  return 1
}

# ============================================
# COST CALCULATION
# ============================================

calculate_cost() {
  local input=$1
  local output=$2
  
  if command -v bc &>/dev/null; then
    echo "scale=4; ($input * 0.000003) + ($output * 0.000015)" | bc
  else
    echo "N/A"
  fi
}

# ============================================
# SINGLE TASK EXECUTION
# ============================================

run_single_task() {
  local task_name="${1:-}"
  local task_num="${2:-$iteration}"
  
  retry_count=0
  
  echo ""
  echo "${BOLD}>>> Task $task_num${RESET}"
  
  local remaining
  remaining=$(count_remaining_tasks | tr -d '[:space:]')
  remaining=${remaining:-0}
  local blocked_count=${#blocked_issues[@]}
  echo "${DIM}    Processed: $session_processed | Blocked: $blocked_count | Remaining: $remaining${RESET}"
  echo "--------------------------------------------"

  # Get current task for display
  local current_task
  if [[ -n "$task_name" ]]; then
    current_task="$task_name"
  else
    # Use unclaimed task finder to coordinate with other instances
    current_task=$(get_next_unclaimed_task)
  fi

  if [[ -z "$current_task" ]]; then
    log_info "No more tasks found"
    return 2
  fi

  # Track for blocked issue handling in main loop
  LAST_ATTEMPTED_TASK="$current_task"

  current_step="Thinking"

  # Update project board: task starting
  if [[ "$PRD_SOURCE" == "github" ]]; then
    project_board_task_started "$current_task"
  fi

  # Create branch if needed
  local branch_name=""
  if [[ "$BRANCH_PER_TASK" == true ]]; then
    branch_name=$(create_task_branch "$current_task")
    log_info "Working on branch: $branch_name"
  fi

  local task_start_head=""
  task_start_head=$(git rev-parse HEAD 2>/dev/null || echo "")
  local task_start_status=""
  task_start_status=$(git status --porcelain 2>/dev/null || echo "")

  # Temp file for AI output
  tmpfile=$(mktemp)

  # Build the prompt
  local prompt
  prompt=$(build_prompt "$current_task")

  if [[ "$DRY_RUN" == true ]]; then
    log_info "DRY RUN - Would execute:"
    echo "${DIM}$prompt${RESET}"
    rm -f "$tmpfile"
    tmpfile=""
    return_to_base_branch
    return 0
  fi

  # Run with retry logic
  while [[ $retry_count -lt $MAX_RETRIES ]]; do
    # TEST MODE: Skip AI call and inject fake error immediately
    if [[ "$TEST_FALLBACK" == true ]] && [[ "$FALLBACK_USED" == false ]]; then
      log_warn "TEST MODE: Skipping $AI_ENGINE, simulating rate limit"
      echo '{"type":"error","error":{"message":"Resource exhausted: quota exceeded"}}' > "$tmpfile"
      sleep 1  # Brief pause for realism
    else
      # Start AI command
      run_ai_command "$prompt" "$tmpfile"

      # Start progress monitor in background
      monitor_progress "$tmpfile" "${current_task:0:40}" &
      monitor_pid=$!

      # Wait for AI to finish
      wait "$ai_pid" 2>/dev/null || true

      # Stop the monitor
      kill "$monitor_pid" 2>/dev/null || true
      wait "$monitor_pid" 2>/dev/null || true
      monitor_pid=""

      # Show completion
      tput cr 2>/dev/null || printf "\r"
      tput el 2>/dev/null || true
    fi

    # Read result
    local result
    result=$(cat "$tmpfile" 2>/dev/null || echo "")

    # Check for empty response
    if [[ -z "$result" ]]; then
      ((retry_count++))
      log_error "Empty response (attempt $retry_count/$MAX_RETRIES)"

      # Empty responses after multiple retries may indicate rate limiting
      if [[ $retry_count -ge $MAX_RETRIES ]]; then
        if switch_to_fallback; then
          retry_count=0
          log_info "Continuing with ${AI_ENGINE}..."
          sleep 2
          continue
        fi
      fi

      if [[ $retry_count -lt $MAX_RETRIES ]]; then
        log_info "Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
        continue
      fi
      rm -f "$tmpfile"
      tmpfile=""
      return_to_base_branch
      return 1
    fi

    # Check for API errors
    local error_msg
    if ! error_msg=$(check_for_errors "$result"); then
      ((retry_count++))
      log_error "API error: $error_msg (attempt $retry_count/$MAX_RETRIES)"

      # Check if this is a rate limit error and we have a fallback
      if is_rate_limit_error "$error_msg"; then
        if switch_to_fallback; then
          # Successfully switched to fallback - reset retry count and continue
          retry_count=0
          log_info "Continuing with ${AI_ENGINE}..."
          sleep 2  # Brief pause before trying new engine
          continue
        fi
      fi

      if [[ $retry_count -lt $MAX_RETRIES ]]; then
        log_info "Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
        continue
      fi
      rm -f "$tmpfile"
      tmpfile=""
      return_to_base_branch
      return 1
    fi

    local repo_changed=false
    if has_repo_changes_since "$task_start_head" "$task_start_status"; then
      repo_changed=true
    fi

    if [[ "$result" == *"TOOL_ACCESS_FAILED"* ]]; then
      log_error "Tool access failed; stopping."
      rm -f "$tmpfile"
      tmpfile=""
      if [[ "$AI_ENGINE" == "codex" ]] && [[ -n "$CODEX_LAST_MESSAGE_FILE" ]]; then
        rm -f "$CODEX_LAST_MESSAGE_FILE"
        CODEX_LAST_MESSAGE_FILE=""
      fi
      return_to_base_branch
      return 4
    fi

    if ! has_tool_usage "$result" && [[ "$repo_changed" != true ]]; then
      log_error "No tool usage detected; failing task."
      rm -f "$tmpfile"
      tmpfile=""
      if [[ "$AI_ENGINE" == "codex" ]] && [[ -n "$CODEX_LAST_MESSAGE_FILE" ]]; then
        rm -f "$CODEX_LAST_MESSAGE_FILE"
        CODEX_LAST_MESSAGE_FILE=""
      fi
      return_to_base_branch
      return 4
    fi

    # Parse the result
    local parsed
    parsed=$(parse_ai_result "$result")
    local response
    response=$(echo "$parsed" | sed '/^---TOKENS---$/,$d')
    local token_data
    token_data=$(echo "$parsed" | sed -n '/^---TOKENS---$/,$p' | tail -3)
    local input_tokens
    input_tokens=$(echo "$token_data" | sed -n '1p')
    local output_tokens
    output_tokens=$(echo "$token_data" | sed -n '2p')
    local actual_cost
    actual_cost=$(echo "$token_data" | sed -n '3p')

    printf "  ${GREEN}✓${RESET} %-16s │ %s\n" "Done" "${current_task:0:40}"
    
    if [[ -n "$response" ]]; then
      echo ""
      echo "$response"
    fi

    # Sanitize values
    [[ "$input_tokens" =~ ^[0-9]+$ ]] || input_tokens=0
    [[ "$output_tokens" =~ ^[0-9]+$ ]] || output_tokens=0

    # Update totals
    total_input_tokens=$((total_input_tokens + input_tokens))
    total_output_tokens=$((total_output_tokens + output_tokens))
    
    # Track actual cost for OpenCode, or duration for Cursor
    if [[ -n "$actual_cost" ]]; then
      if [[ "$actual_cost" == duration:* ]]; then
        # Cursor duration tracking
        local dur_ms="${actual_cost#duration:}"
        [[ "$dur_ms" =~ ^[0-9]+$ ]] && total_duration_ms=$((total_duration_ms + dur_ms))
      elif [[ "$actual_cost" != "0" ]] && command -v bc &>/dev/null; then
        # OpenCode cost tracking
        total_actual_cost=$(echo "scale=6; $total_actual_cost + $actual_cost" | bc 2>/dev/null || echo "$total_actual_cost")
      fi
    fi

    rm -f "$tmpfile"
    tmpfile=""
    if [[ "$AI_ENGINE" == "codex" ]] && [[ -n "$CODEX_LAST_MESSAGE_FILE" ]]; then
      rm -f "$CODEX_LAST_MESSAGE_FILE"
      CODEX_LAST_MESSAGE_FILE=""
    fi

    # Mark task complete for GitHub issues (since AI can't do it)
    if [[ "$PRD_SOURCE" == "github" ]]; then
      local head_after
      head_after=$(git rev-parse HEAD 2>/dev/null || echo "")
      local has_commits=false
      local has_code=false

      if [[ -n "$task_start_head" && -n "$head_after" && "$task_start_head" != "$head_after" ]]; then
        has_commits=true
        if has_code_changes_between "$task_start_head" "$head_after"; then
          has_code=true
        fi
      fi

      # Check if this issue type allows closing without code changes
      local no_code_ok=false
      if issue_allows_no_code "$current_task"; then
        no_code_ok=true
        log_info "Issue has no-code-required label; documentation/decision changes are acceptable"
      fi

      if [[ "$has_code" == true ]]; then
        # Normal case: code changes detected
        local completion_comment="## Task Completed by Ralphy

**Summary:**
${response:-Task implementation completed successfully.}

**Commits:** \`${task_start_head:0:7}\`..\`${head_after:0:7}\`
**Engine:** ${AI_ENGINE}"
        mark_task_complete "$current_task" "$completion_comment"
        project_board_task_completed "$current_task" "${branch_name:-}"
        ((session_processed++))
      elif [[ "$no_code_ok" == true ]]; then
        # No code changes but issue allows it (decision/docs/chore)
        local completion_comment="## Task Completed by Ralphy

**Summary:**
${response:-Task completed (no code changes required).}

**Type:** Documentation/Decision/Chore
**Engine:** ${AI_ENGINE}"
        mark_task_complete "$current_task" "$completion_comment"
        project_board_task_completed "$current_task" "${branch_name:-}"
        ((session_processed++))
      elif [[ "$has_commits" == false ]]; then
        log_error "No new commit created; failing task and leaving issue open: $current_task"
        return_to_base_branch
        return 3
      else
        log_error "No code changes detected (docs/progress only); failing task and leaving issue open: $current_task"
        log_info "Tip: Add 'no-code-required', 'chore', 'documentation', or 'decision' label to allow closing without code"
        return_to_base_branch
        return 3
      fi
    else
      # For markdown/yaml, the AI marks the task complete directly
      # We just need to track the session counter
      ((session_processed++))
    fi

    # Create PR if requested
    if [[ "$CREATE_PR" == true ]] && [[ -n "$branch_name" ]]; then
      create_pull_request "$branch_name" "$current_task" "Automated implementation by Ralphy"
      # Update project board to "In Review" (overrides "Done" since PR needs review)
      if [[ "$PRD_SOURCE" == "github" ]]; then
        project_board_task_in_review "$current_task" "$branch_name"
      fi
    fi

    # Return to base branch
    return_to_base_branch

    # Check for completion - verify by actually counting remaining tasks
    local remaining_count
    remaining_count=$(count_remaining_tasks | tr -d '[:space:]')
    remaining_count=${remaining_count:-0}
    [[ "$remaining_count" =~ ^[0-9]+$ ]] || remaining_count=0
    
    if [[ "$remaining_count" -eq 0 ]]; then
      return 2  # All tasks actually complete
    fi
    
    # AI might claim completion but tasks remain - continue anyway
    if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
      log_debug "AI claimed completion but $remaining_count tasks remain, continuing..."
    fi

    return 0
  done

  return_to_base_branch
  return 1
}

# ============================================
# PARALLEL TASK EXECUTION
# ============================================

# Create an isolated worktree for a parallel agent
create_agent_worktree() {
  local task_name="$1"
  local agent_num="$2"
  local branch_name="ralphy/agent-${agent_num}-$(slugify "$task_name")"
  local worktree_dir="${WORKTREE_BASE}/agent-${agent_num}"
  
  # Run git commands from original directory
  # All git output goes to stderr so it doesn't interfere with our return value
  (
    cd "$ORIGINAL_DIR" || { echo "Failed to cd to $ORIGINAL_DIR" >&2; exit 1; }
    
    # Prune any stale worktrees first
    git worktree prune >&2
    
    # Delete branch if it exists (force)
    git branch -D "$branch_name" >&2 2>/dev/null || true
    
    # Create branch from base
    git branch "$branch_name" "$BASE_BRANCH" >&2 || { echo "Failed to create branch $branch_name from $BASE_BRANCH" >&2; exit 1; }
    
    # Remove existing worktree dir if any
    rm -rf "$worktree_dir" 2>/dev/null || true
    
    # Create worktree
    git worktree add "$worktree_dir" "$branch_name" >&2 || { echo "Failed to create worktree at $worktree_dir" >&2; exit 1; }
  )
  
  # Only output the result - git commands above send their output to stderr
  echo "$worktree_dir|$branch_name"
}

# Cleanup worktree after agent completes
cleanup_agent_worktree() {
  local worktree_dir="$1"
  local branch_name="$2"
  local log_file="${3:-}"
  local dirty=false

  if [[ -d "$worktree_dir" ]]; then
    if git -C "$worktree_dir" status --porcelain 2>/dev/null | grep -q .; then
      dirty=true
    fi
  fi

  if [[ "$dirty" == true ]]; then
    if [[ -n "$log_file" ]]; then
      echo "Worktree left in place due to uncommitted changes: $worktree_dir" >> "$log_file"
    fi
    return 0
  fi
  
  # Run from original directory
  (
    cd "$ORIGINAL_DIR" || exit 1
    git worktree remove -f "$worktree_dir" 2>/dev/null || true
  )

  # Kill orphaned tsc/eslint processes from this agent's worktree
  # Only kill those that are descendants of this ralphy instance
  if [[ -n "$worktree_dir" ]] && [[ -n "$RALPHY_PID" ]]; then
    local all_descendants=$(get_all_descendants "$RALPHY_PID")
    if [[ -n "$all_descendants" ]]; then
      for pid in $all_descendants; do
        local cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
        if [[ "$cmdline" == *"tsc"*"${worktree_dir}"* ]] || [[ "$cmdline" == *"eslint"*"${worktree_dir}"* ]]; then
          kill -TERM "$pid" 2>/dev/null || true
        fi
      done
    fi
  fi

  # Don't delete branch - it may have commits we want to keep/PR
}

# Run a single agent in its own isolated worktree
run_parallel_agent() {
  local task_name="$1"
  local agent_num="$2"
  local output_file="$3"
  local status_file="$4"
  local log_file="$5"
  
  echo "setting up" > "$status_file"

  # Update project board: task starting (parallel agent)
  if [[ "$PRD_SOURCE" == "github" ]]; then
    project_board_task_started "$task_name"
  fi

  # Log setup info
  echo "Agent $agent_num starting for task: $task_name" >> "$log_file"
  echo "ORIGINAL_DIR=$ORIGINAL_DIR" >> "$log_file"
  echo "WORKTREE_BASE=$WORKTREE_BASE" >> "$log_file"
  echo "BASE_BRANCH=$BASE_BRANCH" >> "$log_file"
  
  # Create isolated worktree for this agent
  local worktree_info
  worktree_info=$(create_agent_worktree "$task_name" "$agent_num" 2>>"$log_file")
  local worktree_dir="${worktree_info%%|*}"
  local branch_name="${worktree_info##*|}"
  
  echo "Worktree dir: $worktree_dir" >> "$log_file"
  echo "Branch name: $branch_name" >> "$log_file"
  
  if [[ ! -d "$worktree_dir" ]]; then
    echo "failed" > "$status_file"
    echo "ERROR: Worktree directory does not exist: $worktree_dir" >> "$log_file"
    echo "0 0" > "$output_file"
    return 1
  fi

  local worktree_start_head=""
  worktree_start_head=$(git -C "$worktree_dir" rev-parse HEAD 2>/dev/null || echo "")
  local worktree_start_status=""
  worktree_start_status=$(git -C "$worktree_dir" status --porcelain 2>/dev/null || echo "")

  echo "running" > "$status_file"
  
  # Copy PRD file to worktree from original directory
  if [[ "$PRD_SOURCE" == "markdown" ]] || [[ "$PRD_SOURCE" == "yaml" ]]; then
    cp "$ORIGINAL_DIR/$PRD_FILE" "$worktree_dir/" 2>/dev/null || true
  fi
  
  # Ensure progress.txt exists in worktree
  touch "$worktree_dir/progress.txt"
  
  # Build prompt for this specific task
  local prompt="You are working on a specific task. Focus ONLY on this task:

TASK: $task_name

Instructions:
1. Implement this specific task completely
2. Write tests if appropriate
3. Update progress.txt with what you did
4. Commit your changes with a descriptive message
5. IMPORTANT: You MUST use tools to read and edit files in this repo. Do not respond with a plan only.
   If you cannot access tools or the repo, respond exactly with 'TOOL_ACCESS_FAILED'.

Do NOT modify PRD.md or mark tasks complete - that will be handled separately.
Focus only on implementing: $task_name"

  # Temp file for AI output
  local tmpfile
  tmpfile=$(mktemp)
  
  # Run AI agent in the worktree directory
  local result=""
  local success=false
  local retry=0
  
  while [[ $retry -lt $MAX_RETRIES ]]; do
    case "$AI_ENGINE" in
      opencode)
        (
          cd "$worktree_dir"
          OPENCODE_PERMISSION='{"*":"allow"}' opencode run \
            --format json \
            "$prompt"
        ) > "$tmpfile" 2>>"$log_file"
        ;;
      cursor)
        (
          cd "$worktree_dir"
          agent --print --force \
            --output-format stream-json \
            "$prompt"
        ) > "$tmpfile" 2>>"$log_file"
        ;;
      qwen)
        (
          cd "$worktree_dir"
          qwen --output-format stream-json \
            --approval-mode yolo \
            -p "$prompt"
        ) > "$tmpfile" 2>>"$log_file"
        ;;
      codex)
        (
          cd "$worktree_dir"
          CODEX_LAST_MESSAGE_FILE="$tmpfile.last"
          rm -f "$CODEX_LAST_MESSAGE_FILE"
          codex exec --full-auto \
            --json \
            --output-last-message "$CODEX_LAST_MESSAGE_FILE" \
            "$prompt"
        ) > "$tmpfile" 2>>"$log_file"
        ;;
      *)
        (
          cd "$worktree_dir"
          claude --dangerously-skip-permissions \
            --verbose \
            -p "$prompt" \
            --output-format stream-json
        ) > "$tmpfile" 2>>"$log_file"
        ;;
    esac
    
    result=$(cat "$tmpfile" 2>/dev/null || echo "")
    
    if [[ -n "$result" ]]; then
      local error_msg
      if ! error_msg=$(check_for_errors "$result"); then
        ((retry++))
        echo "API error: $error_msg (attempt $retry/$MAX_RETRIES)" >> "$log_file"
        sleep "$RETRY_DELAY"
        continue
      fi
      local repo_changed=false
      if has_repo_changes_since "$worktree_start_head" "$worktree_start_status" "$worktree_dir"; then
        repo_changed=true
      fi
      if [[ "$result" == *"TOOL_ACCESS_FAILED"* ]]; then
        echo "ERROR: Tool access failed; no tools available." >> "$log_file"
        break
      fi
      if ! has_tool_usage "$result" && [[ "$repo_changed" != true ]]; then
        echo "ERROR: No tool usage detected; treating task as failed." >> "$log_file"
        break
      fi
      success=true
      break
    fi
    
    ((retry++))
    echo "Retry $retry/$MAX_RETRIES after empty response" >> "$log_file"
    sleep "$RETRY_DELAY"
  done
  
  rm -f "$tmpfile"
  
  if [[ "$success" == true ]]; then
    # Parse tokens
    local parsed input_tokens output_tokens
    local CODEX_LAST_MESSAGE_FILE="${tmpfile}.last"
    parsed=$(parse_ai_result "$result")
    local token_data
    token_data=$(echo "$parsed" | sed -n '/^---TOKENS---$/,$p' | tail -3)
    input_tokens=$(echo "$token_data" | sed -n '1p')
    output_tokens=$(echo "$token_data" | sed -n '2p')
    [[ "$input_tokens" =~ ^[0-9]+$ ]] || input_tokens=0
    [[ "$output_tokens" =~ ^[0-9]+$ ]] || output_tokens=0
    rm -f "${tmpfile}.last"

    # Check if this issue allows closing without code changes
    local no_code_ok=false
    if [[ "$PRD_SOURCE" == "github" ]] && issue_allows_no_code "$task_name"; then
      no_code_ok=true
      echo "Issue has no-code-required label; documentation/decision changes are acceptable" >> "$log_file"
    fi

    # Ensure at least one commit exists before marking success
    local commit_count
    commit_count=$(git -C "$worktree_dir" rev-list --count "$BASE_BRANCH"..HEAD 2>/dev/null || echo "0")
    [[ "$commit_count" =~ ^[0-9]+$ ]] || commit_count=0
    if [[ "$commit_count" -eq 0 ]] && [[ "$no_code_ok" != true ]]; then
      echo "ERROR: No new commits created; treating task as failed." >> "$log_file"
      echo "blocked:No commits created" > "$status_file"
      echo "0 0" > "$output_file"
      cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"
      return 1
    fi
    if ! has_code_changes_between "$BASE_BRANCH" "HEAD" "$worktree_dir"; then
      if [[ "$no_code_ok" == true ]]; then
        echo "No code changes but issue allows it (decision/docs/chore)" >> "$log_file"
      else
        echo "ERROR: No code changes detected (only progress.txt); treating task as failed." >> "$log_file"
        echo "Tip: Add 'no-code-required', 'chore', 'documentation', or 'decision' label to allow closing without code" >> "$log_file"
        echo "blocked:No code changes detected" > "$status_file"
        echo "0 0" > "$output_file"
        cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"
        return 1
      fi
    fi
    
    # Create PR if requested
    if [[ "$CREATE_PR" == true ]]; then
      (
        cd "$worktree_dir"
        git push -u origin "$branch_name" 2>>"$log_file" || true
        gh pr create \
          --base "$BASE_BRANCH" \
          --head "$branch_name" \
          --title "$task_name" \
          --body "Automated implementation by Ralphy (Agent $agent_num)" \
          ${PR_DRAFT:+--draft} 2>>"$log_file" || true
      )
      # Update project board to "In Review"
      if [[ "$PRD_SOURCE" == "github" ]]; then
        project_board_task_in_review "$task_name" "$branch_name"
      fi
    fi

    # Capture summary info before cleanup
    local commits_summary=""
    commits_summary=$(git -C "$worktree_dir" log --oneline "$BASE_BRANCH"..HEAD 2>/dev/null | head -10)
    local files_changed=""
    files_changed=$(git -C "$worktree_dir" diff --stat "$BASE_BRANCH"..HEAD 2>/dev/null | tail -10)

    # Write success output with summary
    echo "done" > "$status_file"
    {
      echo "$input_tokens $output_tokens $branch_name"
      echo "---COMMITS---"
      echo "$commits_summary"
      echo "---FILES---"
      echo "$files_changed"
    } > "$output_file"

    # Cleanup worktree (but keep branch)
    cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"
    
    return 0
  else
    echo "failed" > "$status_file"
    echo "0 0" > "$output_file"
    cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"
    return 1
  fi
}

# ============================================
# AUTO-PARALLEL EXECUTION (Smart 2-at-a-time)
# ============================================

# Run 1-2 tasks based on domain detection
# Returns: 0=success, 1=error, 2=no tasks
run_auto_parallel_batch() {
  # Get safe pair (returns 1 or 2 tasks)
  local tasks=()
  while IFS= read -r task; do
    [[ -n "$task" ]] && tasks+=("$task")
  done < <(get_parallel_safe_pair)

  local task_count=${#tasks[@]}

  if [[ $task_count -eq 0 ]]; then
    return 2  # No tasks
  fi

  # Claim the issues and auto-label docs issues
  for task in "${tasks[@]}"; do
    local issue_num="${task%%:*}"
    claim_issue "$issue_num"
    # Pre-emptively label docs issues so they can close without code changes
    auto_label_docs_issue "$task"
  done

  if [[ $task_count -eq 1 ]]; then
    # Single task - run normally
    local task="${tasks[0]}"
    echo ""
    echo "${BOLD}>>> Task $iteration${RESET} ${DIM}(sequential - no safe parallel pair found)${RESET}"
    local result_code=0
    run_single_task "$task" "$iteration" || result_code=$?

    # Release the issue
    local issue_num="${task%%:*}"
    release_issue "$issue_num"

    return $result_code
  fi

  # Two tasks - run in mini-parallel
  local task1="${tasks[0]}"
  local task2="${tasks[1]}"
  # Reuse domains cached by can_issues_run_parallel (avoids re-detecting without body/labels)
  local domain1="${LAST_DOMAIN1:-unknown}"
  local domain2="${LAST_DOMAIN2:-unknown}"

  echo ""
  echo "${BOLD}>>> Tasks $iteration-$((iteration+1))${RESET} ${GREEN}(auto-parallel: $domain1 + $domain2)${RESET}"
  echo "  ${CYAN}◉${RESET} ${task1:0:60}"
  echo "  ${CYAN}◉${RESET} ${task2:0:60}"
  echo ""

  # Store original directory
  ORIGINAL_DIR=$(pwd)
  export ORIGINAL_DIR

  # Set up worktree base
  WORKTREE_BASE=$(mktemp -d)
  export WORKTREE_BASE

  # Ensure base branch
  if [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  fi
  export BASE_BRANCH

  # Export needed vars
  export AI_ENGINE MAX_RETRIES RETRY_DELAY PRD_SOURCE PRD_FILE CREATE_PR PR_DRAFT GITHUB_REPO GITHUB_LABEL

  # Setup for both tasks
  local status_files=() output_files=() log_files=()
  local pids=()

  for idx in "${!tasks[@]}"; do
    local task="${tasks[$idx]}"
    local agent_num=$((iteration + idx))
    local status_file=$(mktemp)
    local output_file=$(mktemp)
    local log_file=$(mktemp)

    status_files+=("$status_file")
    output_files+=("$output_file")
    log_files+=("$log_file")

    echo "waiting" > "$status_file"

    # Run agent in background
    (
      run_parallel_agent "$task" "$agent_num" "$output_file" "$status_file" "$log_file"
    ) &
    pids+=($!)
  done

  # Wait with spinner
  local spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local spin_idx=0
  local start_time=$SECONDS

  while true; do
    local all_done=true
    local running=0 done_count=0 failed=0

    for idx in "${!status_files[@]}"; do
      local status=$(cat "${status_files[$idx]}" 2>/dev/null || echo "waiting")
      case "$status" in
        done) ((done_count++)) ;;
        failed|blocked:*) ((failed++)) ;;
        *)
          if kill -0 "${pids[$idx]}" 2>/dev/null; then
            all_done=false
            ((running++))
          fi
          ;;
      esac
    done

    [[ "$all_done" == true ]] && break

    local elapsed=$((SECONDS - start_time))
    local spin_char="${spinner_chars:$spin_idx:1}"
    spin_idx=$(( (spin_idx + 1) % ${#spinner_chars} ))

    printf "\r  ${CYAN}%s${RESET} Running: %d | Done: %d | Failed: %d | %02d:%02d " \
      "$spin_char" "$running" "$done_count" "$failed" $((elapsed / 60)) $((elapsed % 60))

    sleep 0.3
  done

  printf "\r%80s\r" ""  # Clear line

  # Wait for processes
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Process results
  local any_failed=false
  local tasks_succeeded=0

  for idx in "${!status_files[@]}"; do
    local task="${tasks[$idx]}"
    local issue_num="${task%%:*}"
    local status=$(cat "${status_files[$idx]}" 2>/dev/null || echo "unknown")
    local agent_num=$((iteration + idx))

    local icon color
    case "$status" in
      done)
        icon="✓" color="$GREEN"
        ((tasks_succeeded++))
        ((session_processed++))

        # Get tokens and summary from output file
        local output_content=$(cat "${output_files[$idx]}" 2>/dev/null || echo "0 0 unknown")
        local first_line=$(echo "$output_content" | head -1)
        local in_tok=$(echo "$first_line" | awk '{print $1}')
        local out_tok=$(echo "$first_line" | awk '{print $2}')
        local branch=$(echo "$first_line" | awk '{print $3}')

        # Extract commits and files summary
        local commits_section=$(echo "$output_content" | sed -n '/---COMMITS---/,/---FILES---/p' | grep -v '^---')
        local files_section=$(echo "$output_content" | sed -n '/---FILES---/,$ p' | grep -v '^---')
        [[ "$in_tok" =~ ^[0-9]+$ ]] || in_tok=0
        [[ "$out_tok" =~ ^[0-9]+$ ]] || out_tok=0
        total_input_tokens=$((total_input_tokens + in_tok))
        total_output_tokens=$((total_output_tokens + out_tok))

        # Mark complete
        if [[ "$PRD_SOURCE" == "markdown" ]]; then
          mark_task_complete_markdown "$task"
        elif [[ "$PRD_SOURCE" == "yaml" ]]; then
          mark_task_complete_yaml "$task"
        elif [[ "$PRD_SOURCE" == "github" ]]; then
          local comment="## ✅ Task Completed by Ralphy (Agent $agent_num)

**Branch:** \`$branch\`
**Engine:** ${AI_ENGINE}

### Commits
\`\`\`
${commits_section:-No commits captured}
\`\`\`

### Files Changed
\`\`\`
${files_section:-No file changes captured}
\`\`\`"
          mark_task_complete_github "$task" "$comment"
          project_board_task_completed "$task" "$branch"
        fi
        ;;
      blocked:*)
        icon="⊘" color="$YELLOW"
        local reason="${status#blocked:}"
        mark_issue_blocked "$task" "$reason"
        ;;
      failed)
        icon="✗" color="$RED"
        any_failed=true
        ;;
      *)
        icon="?" color="$YELLOW"
        ;;
    esac

    printf "  ${color}%s${RESET} Agent %d: %s\n" "$icon" "$agent_num" "${task:0:55}"

    # Show log for failures
    if [[ "$status" == "failed" ]] && [[ -s "${log_files[$idx]}" ]]; then
      echo "${DIM}    └─ $(tail -1 "${log_files[$idx]}")${RESET}"
    fi

    # Release the issue
    release_issue "$issue_num"

    # Cleanup temp files
    rm -f "${status_files[$idx]}" "${output_files[$idx]}" "${log_files[$idx]}"
  done

  # Cleanup worktree base
  if [[ -d "$WORKTREE_BASE" ]]; then
    rm -rf "$WORKTREE_BASE" 2>/dev/null || true
  fi

  # Increment iteration for the second task
  ((iteration++))

  # Check remaining tasks
  local remaining
  remaining=$(count_remaining_tasks | tr -d '[:space:]')
  remaining=${remaining:-0}
  [[ "$remaining" =~ ^[0-9]+$ ]] || remaining=0

  if [[ "$remaining" -eq 0 ]]; then
    return 2  # All complete
  fi

  [[ "$any_failed" == true ]] && return 1
  return 0
}

run_parallel_tasks() {
  log_info "Running ${BOLD}$MAX_PARALLEL parallel agents${RESET} (each in isolated worktree)..."
  
  local all_tasks=()
  
  # Get all pending tasks
  while IFS= read -r task; do
    [[ -n "$task" ]] && all_tasks+=("$task")
  done < <(get_all_tasks)
  
  if [[ ${#all_tasks[@]} -eq 0 ]]; then
    log_info "No tasks to run"
    return 2
  fi
  
  local total_tasks=${#all_tasks[@]}
  log_info "Found $total_tasks tasks to process"
  
  # Store original directory for git operations from subshells
  ORIGINAL_DIR=$(pwd)
  export ORIGINAL_DIR
  
  # Set up worktree base directory
  WORKTREE_BASE=$(mktemp -d)
  export WORKTREE_BASE
  log_debug "Worktree base: $WORKTREE_BASE"
  
  # Ensure we have a base branch set
  if [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  fi
  export BASE_BRANCH
  log_info "Base branch: $BASE_BRANCH"
  
  # Export variables needed by subshell agents
  export AI_ENGINE MAX_RETRIES RETRY_DELAY PRD_SOURCE PRD_FILE CREATE_PR PR_DRAFT
  
  local batch_num=0
  local completed_branches=()
  local any_failed=false
  local groups=("all")

  if [[ "$PRD_SOURCE" == "yaml" ]]; then
    groups=()
    while IFS= read -r group; do
      [[ -n "$group" ]] && groups+=("$group")
    done < <(yq -r '.tasks[] | select(.completed != true) | (.parallel_group // 0)' "$PRD_FILE" 2>/dev/null | sort -n | uniq)
  fi

  for group in "${groups[@]}"; do
    local tasks=()
    local group_label=""

    if [[ "$PRD_SOURCE" == "yaml" ]]; then
      while IFS= read -r task; do
        [[ -n "$task" ]] && tasks+=("$task")
      done < <(get_tasks_in_group_yaml "$group")
      [[ ${#tasks[@]} -eq 0 ]] && continue
      group_label=" (group $group)"
    else
      tasks=("${all_tasks[@]}")
    fi

    local batch_start=0
    local total_group_tasks=${#tasks[@]}

    while [[ $batch_start -lt $total_group_tasks ]]; do
      ((batch_num++))
      local batch_end=$((batch_start + MAX_PARALLEL))
      [[ $batch_end -gt $total_group_tasks ]] && batch_end=$total_group_tasks
      local batch_size=$((batch_end - batch_start))

      echo ""
      echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
      echo "${BOLD}Batch $batch_num${group_label}: Spawning $batch_size parallel agents${RESET}"
      echo "${DIM}Each agent runs in its own git worktree with isolated workspace${RESET}"
      echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
      echo ""

      # Setup arrays for this batch
      parallel_pids=()
      local batch_tasks=()
      local status_files=()
      local output_files=()
      local log_files=()

      # Start all agents in the batch
      for ((i = batch_start; i < batch_end; i++)); do
        local task="${tasks[$i]}"
        local agent_num=$((iteration + 1))
        ((iteration++))

        local status_file=$(mktemp)
        local output_file=$(mktemp)
        local log_file=$(mktemp)

        batch_tasks+=("$task")
        status_files+=("$status_file")
        output_files+=("$output_file")
        log_files+=("$log_file")

        echo "waiting" > "$status_file"

        # Show initial status
        printf "  ${CYAN}◉${RESET} Agent %d: %s
" "$agent_num" "${task:0:50}"

        # Run agent in background
        (
          run_parallel_agent "$task" "$agent_num" "$output_file" "$status_file" "$log_file"
        ) &
        parallel_pids+=($!)
      done

      echo ""

      # Monitor progress with a spinner
      local spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
      local spin_idx=0
      local start_time=$SECONDS

      while true; do
        # Check if all processes are done
        local all_done=true
        local setting_up=0
        local running=0
        local done_count=0
        local failed_count=0

        for ((j = 0; j < batch_size; j++)); do
          local pid="${parallel_pids[$j]}"
          local status_file="${status_files[$j]}"
          local status=$(cat "$status_file" 2>/dev/null || echo "waiting")

          case "$status" in
            "setting up")
              all_done=false
              ((setting_up++))
              ;;
            running)
              all_done=false
              ((running++))
              ;;
            done)
              ((done_count++))
              ;;
            failed)
              ((failed_count++))
              ;;
            *)
              # Check if process is still running
              if kill -0 "$pid" 2>/dev/null; then
                all_done=false
              fi
              ;;
          esac
        done

        [[ "$all_done" == true ]] && break

        # Update spinner
        local elapsed=$((SECONDS - start_time))
        local spin_char="${spinner_chars:$spin_idx:1}"
        spin_idx=$(( (spin_idx + 1) % ${#spinner_chars} ))

        printf "  ${CYAN}%s${RESET} Agents: ${BLUE}%d setup${RESET} | ${YELLOW}%d running${RESET} | ${GREEN}%d done${RESET} | ${RED}%d failed${RESET} | %02d:%02d " \
          "$spin_char" "$setting_up" "$running" "$done_count" "$failed_count" $((elapsed / 60)) $((elapsed % 60))

        sleep 0.3
      done

      # Clear the spinner line
      printf "%100s" ""

      # Wait for all processes to fully complete
      for pid in "${parallel_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
      done

      # Show final status for this batch
      echo ""
      echo "${BOLD}Batch $batch_num Results:${RESET}"
      for ((j = 0; j < batch_size; j++)); do
        local task="${batch_tasks[$j]}"
        local status_file="${status_files[$j]}"
        local output_file="${output_files[$j]}"
        local log_file="${log_files[$j]}"
        local status=$(cat "$status_file" 2>/dev/null || echo "unknown")
        local agent_num=$((iteration - batch_size + j + 1))

        local icon color branch_info=""
        case "$status" in
          done)
            icon="✓"
            color="$GREEN"
            ((session_processed++))
            # Collect tokens and branch name
            local output_data=$(cat "$output_file" 2>/dev/null || echo "0 0")
            local in_tok=$(echo "$output_data" | awk '{print $1}')
            local out_tok=$(echo "$output_data" | awk '{print $2}')
            local branch=$(echo "$output_data" | awk '{print $3}')
            [[ "$in_tok" =~ ^[0-9]+$ ]] || in_tok=0
            [[ "$out_tok" =~ ^[0-9]+$ ]] || out_tok=0
            total_input_tokens=$((total_input_tokens + in_tok))
            total_output_tokens=$((total_output_tokens + out_tok))
            if [[ -n "$branch" ]]; then
              completed_branches+=("$branch")
              branch_info=" → ${CYAN}$branch${RESET}"
            fi

            # Mark task complete in PRD
            if [[ "$PRD_SOURCE" == "markdown" ]]; then
              mark_task_complete_markdown "$task"
            elif [[ "$PRD_SOURCE" == "yaml" ]]; then
              mark_task_complete_yaml "$task"
            elif [[ "$PRD_SOURCE" == "github" ]]; then
              # Build completion comment for parallel agent
              local parallel_comment="## Task Completed by Ralphy (Parallel Agent $agent_num)

**Branch:** \`$branch\`
**Engine:** ${AI_ENGINE}

Implementation completed successfully. See branch for commit details."
              mark_task_complete_github "$task" "$parallel_comment"
              project_board_task_completed "$task" "$branch"
            fi
            ;;
          blocked:*)
            icon="⊘"
            color="$YELLOW"
            local block_reason="${status#blocked:}"
            mark_issue_blocked "$task" "$block_reason"
            branch_info=" ${DIM}(blocked)${RESET}"
            ;;
          failed)
            icon="✗"
            color="$RED"
            any_failed=true
            if [[ -s "$log_file" ]]; then
              branch_info=" ${DIM}(error below)${RESET}"
            fi
            ;;
          *)
            icon="?"
            color="$YELLOW"
            ;;
        esac

        printf "  ${color}%s${RESET} Agent %d: %s%s
" "$icon" "$agent_num" "${task:0:45}" "$branch_info"

        # Show log for failed agents
        if [[ "$status" == "failed" ]] && [[ -s "$log_file" ]]; then
          echo "${DIM}    ┌─ Agent $agent_num log:${RESET}"
          sed 's/^/    │ /' "$log_file" | head -20
          local log_lines=$(wc -l < "$log_file")
          if [[ $log_lines -gt 20 ]]; then
            echo "${DIM}    │ ... ($((log_lines - 20)) more lines)${RESET}"
          fi
          echo "${DIM}    └─${RESET}"
        fi

        # Cleanup temp files
        rm -f "$status_file" "$output_file" "$log_file"
      done

      batch_start=$batch_end

      # Check if we've hit max iterations
      if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $iteration -ge $MAX_ITERATIONS ]]; then
        log_warn "Reached max iterations ($MAX_ITERATIONS)"
        break
      fi
    done

    if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $iteration -ge $MAX_ITERATIONS ]]; then
      break
    fi
  done
  
  # Cleanup worktree base
  if ! find "$WORKTREE_BASE" -maxdepth 1 -type d -name 'agent-*' -print -quit 2>/dev/null | grep -q .; then
    rm -rf "$WORKTREE_BASE" 2>/dev/null || true
  else
    log_warn "Preserving worktree base with dirty agents: $WORKTREE_BASE"
  fi
  
  # Handle completed branches
  if [[ ${#completed_branches[@]} -gt 0 ]]; then
    echo ""
    echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    
    if [[ "$CREATE_PR" == true ]]; then
      # PRs were created, just show the branches
      echo "${BOLD}Branches created by agents:${RESET}"
      for branch in "${completed_branches[@]}"; do
        echo "  ${CYAN}•${RESET} $branch"
      done
    else
      # Auto-merge branches back to main
      echo "${BOLD}Merging agent branches into ${BASE_BRANCH}...${RESET}"
      echo ""

      if ! git checkout "$BASE_BRANCH" >/dev/null 2>&1; then
        log_warn "Could not checkout $BASE_BRANCH; leaving agent branches unmerged."
        echo "${BOLD}Branches created by agents:${RESET}"
        for branch in "${completed_branches[@]}"; do
          echo "  ${CYAN}•${RESET} $branch"
        done
        return 0
      fi
      
      local merge_failed=()
      
      for branch in "${completed_branches[@]}"; do
        printf "  Merging ${CYAN}%s${RESET}..." "$branch"
        
        # Attempt to merge
        if git merge --no-edit "$branch" >/dev/null 2>&1; then
          printf " ${GREEN}✓${RESET}
"
          # Delete the branch after successful merge
          git branch -d "$branch" >/dev/null 2>&1 || true
        else
          printf " ${YELLOW}conflict${RESET}"
          merge_failed+=("$branch")
          # Don't abort yet - try AI resolution
        fi
      done
      
      # Use AI to resolve merge conflicts
      if [[ ${#merge_failed[@]} -gt 0 ]]; then
        echo ""
        echo "${BOLD}Using AI to resolve ${#merge_failed[@]} merge conflict(s)...${RESET}"
        echo ""
        
        local still_failed=()
        
        for branch in "${merge_failed[@]}"; do
          printf "  Resolving ${CYAN}%s${RESET}..." "$branch"
          
          # Get list of conflicted files
          local conflicted_files
          conflicted_files=$(git diff --name-only --diff-filter=U 2>/dev/null)
          
          if [[ -z "$conflicted_files" ]]; then
            # No conflicts found (maybe already resolved or aborted)
            git merge --abort 2>/dev/null || true
            git merge --no-edit "$branch" >/dev/null 2>&1 || {
              printf " ${RED}✗${RESET}
"
              still_failed+=("$branch")
              git merge --abort 2>/dev/null || true
              continue
            }
            printf " ${GREEN}✓${RESET}
"
            git branch -d "$branch" >/dev/null 2>&1 || true
            continue
          fi
          
          # Build prompt for AI to resolve conflicts
          local resolve_prompt="You are resolving a git merge conflict. The following files have conflicts:

$conflicted_files

For each conflicted file:
1. Read the file to see the conflict markers (<<<<<<< HEAD, =======, >>>>>>> branch)
2. Understand what both versions are trying to do
3. Edit the file to resolve the conflict by combining both changes intelligently
4. Remove all conflict markers
5. Make sure the resulting code is valid and compiles

After resolving all conflicts:
1. Run 'git add' on each resolved file
2. Run 'git commit --no-edit' to complete the merge

Be careful to preserve functionality from BOTH branches. The goal is to integrate all features."

          # Run AI to resolve conflicts
          local resolve_tmpfile
          resolve_tmpfile=$(mktemp)
          
          case "$AI_ENGINE" in
            opencode)
              OPENCODE_PERMISSION='{"*":"allow"}' opencode run \
                --format json \
                "$resolve_prompt" > "$resolve_tmpfile" 2>&1
              ;;
            cursor)
              agent --print --force \
                --output-format stream-json \
                "$resolve_prompt" > "$resolve_tmpfile" 2>&1
              ;;
            qwen)
              qwen --output-format stream-json \
                --approval-mode yolo \
                -p "$resolve_prompt" > "$resolve_tmpfile" 2>&1
              ;;
            codex)
              codex exec --full-auto \
                --json \
                "$resolve_prompt" > "$resolve_tmpfile" 2>&1
              ;;
            *)
              claude --dangerously-skip-permissions \
                -p "$resolve_prompt" \
                --output-format stream-json > "$resolve_tmpfile" 2>&1
              ;;
          esac
          
          rm -f "$resolve_tmpfile"
          
          # Check if merge was completed
          if ! git diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
            # No more conflicts - merge succeeded
            printf " ${GREEN}✓ (AI resolved)${RESET}
"
            git branch -d "$branch" >/dev/null 2>&1 || true
          else
            # Still has conflicts
            printf " ${RED}✗ (AI couldn't resolve)${RESET}
"
            still_failed+=("$branch")
            git merge --abort 2>/dev/null || true
          fi
        done
        
        if [[ ${#still_failed[@]} -gt 0 ]]; then
          echo ""
          echo "${YELLOW}Some conflicts could not be resolved automatically:${RESET}"
          for branch in "${still_failed[@]}"; do
            echo "  ${YELLOW}•${RESET} $branch"
          done
          echo ""
          echo "${DIM}Resolve conflicts manually: git merge <branch>${RESET}"
        else
          echo ""
          echo "${GREEN}All branches merged successfully!${RESET}"
        fi
      else
        echo ""
        echo "${GREEN}All branches merged successfully!${RESET}"
      fi
    fi
  fi
  

  if [[ "$any_failed" == true ]]; then
    return 1
  fi

  return 0
}

# ============================================
# SUMMARY
# ============================================

show_summary() {
  echo ""
  echo "${BOLD}============================================${RESET}"
  local blocked_count=${#blocked_issues[@]}
  if [[ $blocked_count -gt 0 ]]; then
    echo "${GREEN}PRD complete!${RESET} Finished $iteration task(s), ${YELLOW}$blocked_count blocked${RESET}."
  else
    echo "${GREEN}PRD complete!${RESET} Finished $iteration task(s)."
  fi
  echo "${BOLD}============================================${RESET}"
  echo ""
  echo "${BOLD}>>> Usage Summary${RESET}"

  # Cursor doesn't provide token usage, but does provide duration
  if [[ "$AI_ENGINE" == "cursor" ]]; then
    echo "${DIM}Token usage not available (Cursor CLI doesn't expose this data)${RESET}"
    if [[ "$total_duration_ms" -gt 0 ]]; then
      local dur_sec=$((total_duration_ms / 1000))
      local dur_min=$((dur_sec / 60))
      local dur_sec_rem=$((dur_sec % 60))
      if [[ "$dur_min" -gt 0 ]]; then
        echo "Total API time: ${dur_min}m ${dur_sec_rem}s"
      else
        echo "Total API time: ${dur_sec}s"
      fi
    fi
  else
    echo "Input tokens:  $total_input_tokens"
    echo "Output tokens: $total_output_tokens"
    echo "Total tokens:  $((total_input_tokens + total_output_tokens))"

    # Show actual cost only for OpenCode (API-based, not subscription)
    if [[ "$AI_ENGINE" == "opencode" ]] && command -v bc &>/dev/null; then
      local has_actual_cost
      has_actual_cost=$(echo "$total_actual_cost > 0" | bc 2>/dev/null || echo "0")
      if [[ "$has_actual_cost" == "1" ]]; then
        echo "Actual cost:   \$${total_actual_cost}"
      fi
    fi
    # Claude Code is subscription-based, no per-token cost to display
  fi
  
  # Show branches if created
  if [[ -n "${task_branches[*]+"${task_branches[*]}"}" ]]; then
    echo ""
    echo "${BOLD}>>> Branches Created${RESET}"
    for branch in "${task_branches[@]}"; do
      echo "  - $branch"
    done
  fi

  # Show blocked issues if any
  if [[ ${#blocked_issues[@]} -gt 0 ]]; then
    echo ""
    echo "${BOLD}>>> Blocked Issues (${#blocked_issues[@]})${RESET}"
    echo "${YELLOW}These issues need manual review:${RESET}"
    for i in "${!blocked_issues[@]}"; do
      local issue="${blocked_issues[$i]}"
      local reason="${blocked_reasons[$i]:-unknown}"
      echo "  ${RED}✗${RESET} $issue"
      echo "    ${DIM}Reason: $reason${RESET}"
    done
    echo ""
    echo "${DIM}To fix: Add 'chore', 'documentation', or 'no-code-required' label, then remove 'ralphy-blocked'${RESET}"
  fi

  echo "${BOLD}============================================${RESET}"
}

# ============================================
# MAIN
# ============================================

main() {
  parse_args "$@"
  init_fallback_engines

  if [[ "$DRY_RUN" == true ]] && [[ "$MAX_ITERATIONS" -eq 0 ]]; then
    MAX_ITERATIONS=1
  fi
  
  # Set up cleanup trap
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP
  
  # Check requirements
  check_requirements

  # Initialize multi-instance coordination
  init_instance_lock

  # Initialize project board connection
  project_board_init

  # Show banner
  echo "${BOLD}============================================${RESET}"
  echo "${BOLD}Ralphy${RESET} - Running until PRD is complete"
  local engine_display
  engine_display=$(engine_display_name "$AI_ENGINE")
  echo "Engine: $engine_display"
  if [[ ${#FALLBACK_ENGINES[@]} -gt 0 ]]; then
    local fallback_display=""
    local fallback_engine
    for fallback_engine in "${FALLBACK_ENGINES[@]}"; do
      local label
      label=$(engine_display_name "$fallback_engine")
      if [[ -z "$fallback_display" ]]; then
        fallback_display="$label"
      else
        fallback_display="$fallback_display -> $label"
      fi
    done
    echo "Fallback: $fallback_display (on rate limit)"
  fi
  echo "Source: ${CYAN}$PRD_SOURCE${RESET} (${PRD_FILE:-$GITHUB_REPO})"

  local mode_parts=()
  [[ "$SKIP_TESTS" == true ]] && mode_parts+=("no-tests")
  [[ "$SKIP_LINT" == true ]] && mode_parts+=("no-lint")
  [[ "$DRY_RUN" == true ]] && mode_parts+=("dry-run")
  [[ "$PARALLEL" == true ]] && mode_parts+=("parallel:$MAX_PARALLEL")
  [[ "$AUTO_PARALLEL" == true ]] && [[ "$PARALLEL" != true ]] && mode_parts+=("auto-parallel:$AUTO_PARALLEL_MAX")
  [[ "$BRANCH_PER_TASK" == true ]] && mode_parts+=("branch-per-task")
  [[ "$CREATE_PR" == true ]] && mode_parts+=("create-pr")
  [[ -n "$PROJECT_NODE_ID" ]] && mode_parts+=("project-board")
  [[ $MAX_ITERATIONS -gt 0 ]] && mode_parts+=("max:$MAX_ITERATIONS")

  if [[ ${#mode_parts[@]} -gt 0 ]]; then
    echo "Mode: ${YELLOW}${mode_parts[*]}${RESET}"
  fi
  echo "${BOLD}============================================${RESET}"

  # Show other running instances
  show_instance_status

  # Run in parallel or sequential mode
  if [[ "$PARALLEL" == true ]]; then
    local parallel_code=0
    run_parallel_tasks || parallel_code=$?
    if [[ $parallel_code -eq 2 ]]; then
      show_summary
      notify_done
      exit 0
    fi
    if [[ $parallel_code -ne 0 ]]; then
      log_error "Parallel run failed; exiting."
      exit 1
    fi
    show_summary
    notify_done
    exit 0
  fi

  # Main loop - auto-parallel or sequential
  while true; do
    ((++iteration))
    local result_code=0

    if [[ "$AUTO_PARALLEL" == true ]]; then
      # Smart auto-parallel: run 1-2 tasks based on domain detection
      run_auto_parallel_batch || result_code=$?

      case $result_code in
        0)
          # Success, continue
          ;;
        1)
          # Some tasks failed, but continue
          log_warn "Some tasks failed, continuing..."
          ;;
        2)
          # All tasks complete
          show_summary
          notify_done
          exit 0
          ;;
        3)
          # No real code changes detected - check for loop, then mark blocked
          if [[ -n "$LAST_ATTEMPTED_TASK" ]]; then
            if track_failed_task "$LAST_ATTEMPTED_TASK"; then
              # Loop detected - try to fix or exit
              if ! handle_task_loop "$LAST_ATTEMPTED_TASK"; then
                show_summary
                notify_done "Ralphy stopped due to loop detection"
                exit 1
              fi
              # Loop was auto-fixed, continue
            else
              # Not a loop yet - mark blocked and continue
              mark_issue_blocked "$LAST_ATTEMPTED_TASK" "No code changes detected (docs/progress only)"
              log_info "Continuing to next issue..."
            fi
          fi
          ;;
        4)
          # Tool usage required but missing - check for loop, then mark blocked
          if [[ -n "$LAST_ATTEMPTED_TASK" ]]; then
            if track_failed_task "$LAST_ATTEMPTED_TASK"; then
              if ! handle_task_loop "$LAST_ATTEMPTED_TASK"; then
                show_summary
                notify_done "Ralphy stopped due to loop detection"
                exit 1
              fi
            else
              mark_issue_blocked "$LAST_ATTEMPTED_TASK" "No tool usage detected"
              log_info "Continuing to next issue..."
            fi
          fi
          ;;
      esac
    else
      # Pure sequential mode - claim issue before starting
      local next_task
      next_task=$(get_next_unclaimed_task)

      if [[ -n "$next_task" ]]; then
        local issue_num="${next_task%%:*}"
        claim_issue "$issue_num"
        # Pre-emptively label docs issues so they can close without code changes
        auto_label_docs_issue "$next_task"
      fi

      run_single_task "$next_task" "$iteration" || result_code=$?

      # Release the issue after completion
      if [[ -n "$LAST_ATTEMPTED_TASK" ]]; then
        local issue_num="${LAST_ATTEMPTED_TASK%%:*}"
        release_issue "$issue_num"
      fi

      case $result_code in
        0)
          # Success, continue
          ;;
        1)
          # Error, but continue to next task
          log_warn "Task failed after $MAX_RETRIES attempts, continuing..."
          ;;
        2)
          # All tasks complete
          show_summary
          notify_done
          exit 0
          ;;
        3)
          # No real code changes detected - check for loop, then mark blocked
          if track_failed_task "$LAST_ATTEMPTED_TASK"; then
            # Loop detected - try to fix or exit
            if ! handle_task_loop "$LAST_ATTEMPTED_TASK"; then
              show_summary
              notify_done "Ralphy stopped due to loop detection"
              exit 1
            fi
            # Loop was auto-fixed, continue
          else
            # Not a loop yet - mark blocked and continue
            mark_issue_blocked "$LAST_ATTEMPTED_TASK" "No code changes detected (docs/progress only)"
            log_info "Continuing to next issue..."
          fi
          ;;
        4)
          # Tool usage required but missing - check for loop, then mark blocked
          if track_failed_task "$LAST_ATTEMPTED_TASK"; then
            if ! handle_task_loop "$LAST_ATTEMPTED_TASK"; then
              show_summary
              notify_done "Ralphy stopped due to loop detection"
              exit 1
            fi
          else
            mark_issue_blocked "$LAST_ATTEMPTED_TASK" "No tool usage detected"
            log_info "Continuing to next issue..."
          fi
          ;;
      esac
    fi

    # Check max iterations
    if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $iteration -ge $MAX_ITERATIONS ]]; then
      log_warn "Reached max iterations ($MAX_ITERATIONS)"
      show_summary
      notify_done "Ralphy stopped after $MAX_ITERATIONS iterations"
      exit 0
    fi

    # Small delay between iterations
    sleep 1
  done
}

# Run main
main "$@"
